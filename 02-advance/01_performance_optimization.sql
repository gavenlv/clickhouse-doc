-- ============================================================
-- 文件: 02-advance/01_performance_optimization.sql
-- 学习目标: 掌握 ClickHouse 查询 Profiling、索引优化、分区策略、
--           PREWHERE、跳数索引、投影、资源控制的全套性能优化技能
-- 深度标准: 原理 + 场景 + 对比 + 可运行
-- 集群: treasurycluster (CH 25.12.1.649, 1 分片 2 副本)
-- 前置: 无（自包含测试数据，按顺序执行）
-- ============================================================
--
-- 本文件章节:
--   1.  查询执行原理与 EXPLAIN 三件套
--   2.  排序键（ORDER BY）优化原理
--   3.  分区剪枝（Partition Pruning）
--   4.  跳数索引（SKIP INDEX）四类型对比
--   5.  投影（Projection）预聚合优化
--   6.  PREWHERE 优化原理
--   7.  采样（SAMPLE）快速估算
--   8.  物化视图预聚合
--   9.  资源控制（max_threads/max_memory_usage/readonly）
--   10. 表维护（OPTIMIZE/分区管理）
--   11. 清理
-- ============================================================

CREATE DATABASE IF NOT EXISTS advance_test ON CLUSTER 'treasurycluster';
USE advance_test;


-- ============================================================
-- 1. 查询执行原理与 EXPLAIN 三件套
-- ============================================================
-- 【原理】ClickHouse 查询执行四阶段：
--   ① Parser:   SQL 文本 → AST（语法错误在此暴露）
--   ② Analyzer: 类型推导 + 权限检查 + 列解析（"Unknown column" 在此报错）
--   ③ Planner:  选择索引 + 谓词下推 + 代价估算（决定扫多少 part）
--   ④ Executor: 向量化 SIMD + 多线程流水线（实际执行，最耗时）
--
-- 【场景】SQL 上线前先 EXPLAIN 确认走索引、有分区剪枝；查询慢时用
--        EXPLAIN PIPELINE 看物理管道，定位瓶颈算子。
-- 【对比】
--   EXPLAIN          → 逻辑计划（读哪个表、什么索引、扫多少分区）
--   EXPLAIN PIPELINE → 物理管道（线程数、算子链、数据流向）
--   EXPLAIN indexes=1→ 标记索引使用位置

-- 1.1 EXPLAIN 逻辑计划
-- 【结果解读】输出显示 ReadFromMergeTree（读取的表）、Where（过滤）、
--            Aggregating（聚合）等算子，确认走了 MergeTree 索引
DROP TABLE IF EXISTS perf_events ON CLUSTER 'treasurycluster' SYNC;

CREATE TABLE perf_events ON CLUSTER 'treasurycluster' (
    event_id UInt64,
    user_id UInt64,
    event_type String,
    timestamp DateTime,
    event_value Float64
) ENGINE = ReplicatedMergeTree()
PARTITION BY toYYYYMM(timestamp)
ORDER BY (user_id, event_type, timestamp)
SETTINGS index_granularity = 8192;

-- 插入 10 万行测试数据
INSERT INTO perf_events SELECT
    number AS event_id,
    number % 1000 AS user_id,
    concat('type_', toString(number % 10)) AS event_type,
    now() - INTERVAL (rand() % 30) DAY AS timestamp,
    rand() * 1000 AS event_value
FROM numbers(100000);

EXPLAIN SELECT count(), avg(event_value)
FROM perf_events
WHERE user_id = 100
  AND timestamp >= now() - INTERVAL 7 DAY;

-- 1.2 EXPLAIN PIPELINE 物理管道
-- 【结果解读】可以看到线程数（如 Thread 0/N）、读取算子、聚合算子，
--            帮助理解并行度
EXPLAIN PIPELINE SELECT count(), avg(event_value)
FROM perf_events
WHERE user_id = 100
  AND timestamp >= now() - INTERVAL 7 DAY;

-- 1.3 EXPLAIN indexes=1 查看索引使用
-- 【结果解读】标记中会显示 PrimaryKey/Partition 使用的位置
EXPLAIN indexes = 1
SELECT count() FROM perf_events WHERE user_id = 100;


-- ============================================================
-- 2. 排序键（ORDER BY）优化原理
-- ============================================================
-- 【原理】ClickHouse 用"稀疏主键"：每 index_granularity（默认 8192）行
--   存一个 mark（主键值），查询时二分定位 mark，跳过无关数据块。
--   这与 MySQL 的 B+Tree 聚簇索引不同——CH 不存每行，只存"每块的边界"。
--
-- 【场景】等值/范围查询频繁的列放前面；高基数列放前面过滤更多数据。
-- 【对比】
--   稀疏主键（CH）: 每 8192 行一个 mark，省内存，但单值查询要扫一个块
--   B+Tree（MySQL）: 每行一个索引项，精确但内存大、写放大严重
-- 【决策】排序键选 3-4 列：过滤性最强 → 次强 → 时间（分区键通常就是时间）
--
-- 【坑】排序键列数过多 → mark 文件膨胀、写入变慢；排序键无法覆盖的
--      过滤列用跳数索引（见 §4）。

-- 2.1 利用排序键加速查询（user_id 在前，二分定位）
-- 【结果解读】走主键索引，只读相关 mark，read_rows 远小于全表
SELECT
    user_id,
    count() AS event_count,
    avg(event_value) AS avg_value
FROM perf_events
WHERE user_id = 100
  AND timestamp >= now() - INTERVAL 7 DAY
GROUP BY user_id;

-- 2.2 查询分区扫描情况
-- 【结果解读】显示每个分区有多少 part、多少行，确认分区剪枝生效
SELECT
    partition,
    sum(rows) AS total_rows,
    count() AS part_count
FROM system.parts
WHERE table = 'perf_events'
  AND database = 'advance_test'
  AND active = 1
GROUP BY partition
ORDER BY partition;


-- ============================================================
-- 3. 分区剪枝（Partition Pruning）
-- ============================================================
-- 【原理】PARTITION BY 将数据按分区键物理隔离到不同目录。查询带分区
--   条件时，Planner 只扫描相关分区，跳过其余分区（零 I/O）。
-- 【场景】时间范围查询（按月分区是最通用方案）。
-- 【对比】
--   分区剪枝: 跳过整个分区目录，零读取
--   主键索引: 在分区内二分定位 mark，跳过块
--   跳数索引: 在 mark 内进一步过滤
--   三者叠加效果最佳
-- 【坑】分区粒度太细（按天）→ part 数爆炸、合并跟不上；太粗（按年）
--      → 单分区过大、DROP PARTITION 不灵活。按月是通用最优解。

-- 3.1 带分区条件的查询（只扫最近分区）
-- 【结果解读】通过 WHERE timestamp 限制范围，触发分区剪枝
SELECT
    toDate(timestamp) AS event_day,
    count() AS event_count
FROM perf_events
WHERE timestamp >= now() - INTERVAL 7 DAY
GROUP BY event_day
ORDER BY event_day;

-- 3.2 对比：不带分区条件（全表扫描，慢）
-- 【结果解读】无分区条件，扫描所有分区，read_rows 接近全表
SELECT count() AS total FROM perf_events;


-- ============================================================
-- 4. 跳数索引（SKIP INDEX）四类型对比
-- ============================================================
-- 【原理】跳数索引在每个 granularity 块上存储"摘要信息"。查询时先
--   检查摘要，若块内不可能含目标值则跳过整个块。
--   - minmax:  块内 min/max，范围查询精确跳过
--   - set(N):  块内值集合（最多 N 个），等值查询精确跳过
--   - bloom_filter(p): 布隆过滤器，有误判（可能误报"有"）但不漏报
--   - tokenbf_v1/ngrambf_v1: 字符串搜索用布隆过滤器
-- 【场景】排序键无法覆盖的过滤列加跳数索引。
-- 【对比】见 README §3.3 跳数索引类型对比表
-- 【坑】选择性低的列（如 90% 行满足条件）加索引反而增加写入开销；
--      bloom 有误判，不适合需要精确结果的场景。

DROP TABLE IF EXISTS perf_skip ON CLUSTER 'treasurycluster' SYNC;

CREATE TABLE perf_skip ON CLUSTER 'treasurycluster' (
    id UInt64,
    user_id UInt64,
    timestamp DateTime,
    status String,
    category String,
    value Float64,
    -- 跳数索引在表定义内声明
    INDEX idx_ts_minmax timestamp TYPE minmax GRANULARITY 4,
    INDEX idx_status_set status TYPE set(10) GRANULARITY 4,
    INDEX idx_user_bloom user_id TYPE bloom_filter(0.01) GRANULARITY 8,
    INDEX idx_cat_tokenbf category TYPE tokenbf_v1(512, 3, 0) GRANULARITY 4
) ENGINE = ReplicatedMergeTree()
PARTITION BY toYYYYMM(timestamp)
ORDER BY (user_id, timestamp)
SETTINGS index_granularity = 8192;

INSERT INTO perf_skip SELECT
    number AS id,
    number % 1000 AS user_id,
    now() - INTERVAL (rand() % 30) DAY AS timestamp,
    if(rand() > 0.5, 'active', 'inactive') AS status,
    concat('cat_', toString(number % 5)) AS category,
    rand() * 1000 AS value
FROM numbers(100000);

-- 4.1 查看跳数索引信息
-- 【结果解读】注意 25.12 的 data_skipping_indices 表字段：
--            data_compressed_bytes / marks_bytes（非旧的 parts/marks/bytes）
SELECT
    database,
    table,
    name AS index_name,
    type,
    expr,
    granularity,
    formatReadableSize(data_compressed_bytes) AS index_size,
    formatReadableSize(marks_bytes) AS marks_size
FROM system.data_skipping_indices
WHERE table = 'perf_skip'
  AND database = 'advance_test'
ORDER BY index_name;

-- 4.2 利用 set 索引加速等值查询
-- 【结果解读】status='active' 利用 idx_status_set 跳过不含此值的块
SELECT status, count() AS cnt, avg(value) AS avg_val
FROM perf_skip
WHERE status = 'active'
GROUP BY status;

-- 4.3 利用 bloom_filter 加速 IN 查询
-- 【结果解读】user_id IN (...) 利用 idx_user_bloom 过滤
SELECT user_id, count() AS cnt
FROM perf_skip
WHERE user_id IN (100, 200, 300, 400, 500)
GROUP BY user_id;


-- ============================================================
-- 5. 投影（Projection）预聚合优化
-- ============================================================
-- 【原理】投影是"同表的另一份排序/聚合数据"。INSERT 时自动维护，
--   查询时优化器自动选择最优投影（无需改 SQL）。
--   与物化视图的区别：投影是表内数据，MV 是另一张表。
-- 【场景】同一张宽表有多种查询模式（按用户查/按商品查），排序键无法同时满足。
-- 【对比】
--   投影:  同表多排序键，查询自动路由，存储翻倍
--   物化视图: 另一张表，需手动查或路由，灵活但维护成本高
-- 【坑】投影使存储翻倍、写入变慢；CH 25.12 投影优化已 GA，
--      无需 allow_experimental_projection_optimization（默认开启）。

DROP TABLE IF EXISTS perf_projection ON CLUSTER 'treasurycluster' SYNC;

CREATE TABLE perf_projection ON CLUSTER 'treasurycluster' (
    order_id UInt64,
    user_id UInt64,
    product_id UInt32,
    quantity UInt32,
    price Decimal(10, 2),
    order_date DateTime
) ENGINE = ReplicatedMergeTree()
PARTITION BY toYYYYMM(order_date)
ORDER BY (user_id, order_date);

-- 5.1 创建按用户聚合的投影
ALTER TABLE perf_projection ON CLUSTER 'treasurycluster'
ADD PROJECTION projection_user_stats
(
    SELECT
        user_id,
        toDate(order_date) AS order_day,
        count() AS order_count,
        sum(quantity) AS total_quantity,
        sum(price * quantity) AS total_revenue
    GROUP BY user_id, order_day
);

-- 5.2 创建按商品聚合的投影
ALTER TABLE perf_projection ON CLUSTER 'treasurycluster'
ADD PROJECTION projection_product_stats
(
    SELECT
        product_id,
        count() AS order_count,
        sum(quantity) AS total_quantity,
        avg(price) AS avg_price
    GROUP BY product_id
);

-- 插入数据（投影自动物化）
INSERT INTO perf_projection SELECT
    number AS order_id,
    number % 100 AS user_id,
    number % 20 AS product_id,
    (number % 10) + 1 AS quantity,
    round(toFloat64(rand() % 100000) / 100, 2) AS price,
    now() - INTERVAL (rand() % 30) DAY AS order_date
FROM numbers(50000);

-- 5.3 查看投影信息
-- 【结果解读】25.12 的 projections 表字段：database/table/name/type/query
SELECT
    database,
    table,
    name AS projection_name,
    type
FROM system.projections
WHERE table = 'perf_projection'
  AND database = 'advance_test';

-- 5.4 查询自动使用投影（无需改 SQL）
-- 【结果解读】优化器自动选择 projection_user_stats 投影，跳过明细行
SELECT
    user_id,
    toDate(order_date) AS order_day,
    count() AS order_count,
    sum(quantity) AS total_quantity,
    sum(price * quantity) AS total_revenue
FROM perf_projection
GROUP BY user_id, order_day
ORDER BY user_id, order_day
LIMIT 10;


-- ============================================================
-- 6. PREWHERE 优化原理
-- ============================================================
-- 【原理】PREWHERE 先只读"过滤列"，过滤掉不满足条件的行后，
--   再读取其余列。对"过滤性强的大宽表"可减少 90%+ 的列读取。
-- 【场景】宽表（几十上百列）+ 强过滤条件（如 user_id 精确定位）。
-- 【对比】
--   WHERE:     读全部列 → 过滤 → 返回（读了很多无用列）
--   PREWHERE:  读过滤列 → 过滤 → 按存活行读其余列（省 I/O）
-- 【坑】
--   - 过滤性弱（90% 行满足）时，PREWHERE 反而多读一次过滤列
--   - SET optimize_move_to_prewhere=1（默认）会自动把 WHERE 中
--     过滤性强的条件移到 PREWHERE，通常无需手动写
--   - PREWHERE 只对 MergeTree 族有效

-- 6.1 PREWHERE 示例
-- 【结果解读】先读 user_id 过滤，再读 event_value，减少 I/O
SELECT count(), avg(event_value)
FROM perf_events
PREWHERE user_id = 100
WHERE event_value > 500;

-- 6.2 普通 WHERE（对比，实际由优化器自动优化）
SELECT count(), avg(event_value)
FROM perf_events
WHERE user_id = 100
  AND event_value > 500;


-- ============================================================
-- 7. 采样（SAMPLE）快速估算
-- ============================================================
-- 【原理】SAMPLE 基于 ORDER BY 中的哈希列做概率采样。要求 ORDER BY
--   包含 intHash32(col) 之类的列，采样时按哈希值取模选行。
-- 【场景】大数据集快速估算（如"大概多少行满足条件"），不需精确值。
-- 【对比】
--   SAMPLE 0.001:  采样 0.1% 行，快 1000 倍，结果近似
--   全量查询:       精确但慢
-- 【坑】采样要求 ORDER BY 含哈希列；SAMPLE 不能与 FINAL 同时用。

DROP TABLE IF EXISTS perf_sample ON CLUSTER 'treasurycluster' SYNC;

CREATE TABLE perf_sample ON CLUSTER 'treasurycluster' (
    id UInt64,
    user_id UInt64,
    event_type String,
    event_value Float64,
    timestamp DateTime
) ENGINE = ReplicatedMergeTree()
PARTITION BY toYYYYMM(timestamp)
ORDER BY (user_id, intHash32(user_id))
SETTINGS index_granularity = 8192;

INSERT INTO perf_sample SELECT
    number AS id,
    number % 1000 AS user_id,
    concat('type_', toString(number % 10)) AS event_type,
    rand() * 1000 AS event_value,
    now() - INTERVAL (rand() % 30) DAY AS timestamp
FROM numbers(100000);

-- 7.1 采样 0.1% 估算
-- 【结果解读】estimated_total ≈ 实际值（有统计误差），速度快 1000 倍
SELECT
    count() AS sampled_count,
    count() * 1000 AS estimated_total,
    avg(event_value) AS estimated_avg
FROM perf_sample
SAMPLE 0.001;

-- 7.2 对比实际值
-- 【结果解读】actual_count 与 estimated_total 接近但不完全相等
SELECT
    count() AS actual_count,
    avg(event_value) AS actual_avg
FROM perf_sample;


-- ============================================================
-- 8. 物化视图预聚合
-- ============================================================
-- 【原理】物化视图（MV）在源表 INSERT 时自动触发，把数据预聚合到
--   目标表。查询时直接查预聚合表，跳过明细扫描。
--   配合 *State/*Merge 函数实现"两阶段聚合"（见 04-functions §11）。
-- 【场景】固定聚合查询（如"按天按用户的 GMV 报表"），高频查询。
-- 【对比】
--   物化视图:  INSERT 时预聚合，查询快，但查询模式固定
--   投影:      同表多排序键，查询自动路由，存储翻倍
--   直接查询:   无预聚合，灵活但慢

DROP TABLE IF EXISTS perf_raw ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS perf_preagg_mv ON CLUSTER 'treasurycluster' SYNC;

CREATE TABLE perf_raw ON CLUSTER 'treasurycluster' (
    event_id UInt64,
    user_id UInt64,
    event_data String,
    timestamp DateTime
) ENGINE = ReplicatedMergeTree()
PARTITION BY toYYYYMM(timestamp)
ORDER BY (user_id, timestamp);

-- 物化视图：用 AggregatingMergeTree + *State 预聚合
CREATE MATERIALIZED VIEW perf_preagg_mv ON CLUSTER 'treasurycluster'
ENGINE = AggregatingMergeTree()
PARTITION BY toYYYYMM(event_date)
ORDER BY (user_id, event_date)
AS SELECT
    user_id,
    toDate(timestamp) AS event_date,
    sumState(length(event_data)) AS total_data_size_state,
    countState() AS event_count_state
FROM perf_raw
GROUP BY user_id, event_date;

-- 插入数据（MV 自动触发预聚合）
INSERT INTO perf_raw (event_id, user_id, event_data, timestamp) VALUES
    (1, 1, 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', now()),
    (2, 1, 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', now()),
    (3, 2, 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', now());

-- 8.1 从物化视图查询预聚合数据（快）
-- 【结果解读】用 sumMerge/countMerge 还原最终值，结果与扫明细一致但快
SELECT
    user_id,
    event_date,
    sumMerge(total_data_size_state) AS total_data_size,
    countMerge(event_count_state) AS event_count
FROM perf_preagg_mv
GROUP BY user_id, event_date
ORDER BY user_id, event_date;

-- 8.2 对比：直接扫明细表（慢）
-- 【结果解读】结果一致，但物化视图扫描行数少 100x+
SELECT
    user_id,
    toDate(timestamp) AS event_date,
    sum(length(event_data)) AS total_data_size,
    count() AS event_count
FROM perf_raw
GROUP BY user_id, event_date
ORDER BY user_id, event_date;


-- ============================================================
-- 9. 资源控制（max_threads / max_memory_usage / readonly）
-- ============================================================
-- 【原理】ClickHouse 通过 SETTINGS 在会话/用户/角色级别限制资源：
--   - max_threads:        单查询并行线程数（默认 CPU 核数）
--   - max_memory_usage:   单查询最大内存（超出报 OOM）
--   - max_execution_time: 单查询最大执行时间（超时杀掉）
--   - readonly:           1=只读（防误写），2=允许改 SETTING
-- 【场景】
--   - 大查询限流：analytics 用户 max_threads=8, max_memory_usage=10GB
--   - 只读用户：readonly=1，物理上无法写
--   - 实时查询：max_execution_time=30，防慢查询拖垮集群
-- 【对比】
--   SETTINGS (会话级): 临时生效，连接断开失效
--   SETTINGS PROFILE: 持久化到用户/角色，推荐生产用

-- 9.1 会话级资源限制（临时）
SET max_threads = 4;
SET max_memory_usage = 5000000000; -- 5GB
SELECT count() FROM perf_events;
-- 恢复默认
SET max_threads = 0;

-- 9.2 查看当前会话设置
-- 【结果解读】显示当前生效的设置值
SELECT name, value, changed
FROM system.settings
WHERE name IN ('max_threads', 'max_memory_usage', 'max_execution_time', 'readonly')
ORDER BY name;

-- 9.3 查看内存使用情况
-- 【结果解读】asynchronous_metrics 周期采样（60s），显示系统级内存
SELECT
    name,
    value,
    formatReadableSize(value) AS readable
FROM system.asynchronous_metrics
WHERE name LIKE '%memory%'
ORDER BY value DESC
LIMIT 10;

-- 9.4 查看表大小排行
-- 【结果解读】按 bytes_on_disk 降序，定位最大表
SELECT
    database,
    table,
    sum(rows) AS total_rows,
    formatReadableSize(sum(bytes_on_disk)) AS total_size,
    count() AS part_count
FROM system.parts
WHERE active = 1
  AND database = 'advance_test'
GROUP BY database, table
ORDER BY sum(bytes_on_disk) DESC;


-- ============================================================
-- 10. 表维护（OPTIMIZE / 分区管理）
-- ============================================================
-- 【原理】
--   - OPTIMIZE TABLE: 强制合并 part，减少 part 数量
--   - OPTIMIZE FINAL: 强制全量合并到 1 个 part（重写所有数据，慢！）
--   - DROP PARTITION: 删除整个分区（释放空间，比 DELETE 快得多）
-- 【场景】
--   - part 数过多（>10/分区）→ OPTIMIZE 合并
--   - 旧数据清理 → DROP PARTITION（秒级释放）
-- 【坑】
--   - OPTIMIZE FINAL 重写所有数据，生产慎用（占 CPU/IO）
--   - ReplicatedMergeTree 的 OPTIMIZE 只在 Leader 执行
--   - 频繁 OPTIMIZE 干扰后台自动合并

-- 10.1 查看未合并的 part（level=0 表示未合并）
-- 【结果解读】level=0 的 part 是新写入未合并的，过多需 OPTIMIZE
SELECT
    table,
    partition,
    count() AS unmerged_parts,
    sum(rows) AS total_rows,
    formatReadableSize(sum(bytes_on_disk)) AS total_bytes
FROM system.parts
WHERE database = 'advance_test'
  AND table = 'perf_events'
  AND active = 1
  AND level = 0
GROUP BY table, partition
ORDER BY total_bytes DESC;

-- 10.2 执行 OPTIMIZE 合并（非 FINAL，较轻量）
-- 【结果解读】合并后 part 数减少，level 提升
OPTIMIZE TABLE perf_events ON CLUSTER 'treasurycluster';

-- 10.3 查看 OPTIMIZE 后的 part 状态
SELECT
    partition,
    name,
    rows,
    bytes_on_disk,
    level,
    modification_time
FROM system.parts
WHERE database = 'advance_test'
  AND table = 'perf_events'
  AND active = 1
ORDER BY partition, name;

-- 10.4 分区管理：查看所有分区
-- 【结果解读】显示每个分区的行数、大小、part 数
SELECT
    database,
    table,
    partition,
    sum(rows) AS total_rows,
    formatReadableSize(sum(bytes_on_disk)) AS total_size,
    count() AS part_count
FROM system.parts
WHERE database = 'advance_test'
  AND active = 1
GROUP BY database, table, partition
ORDER BY total_size DESC
LIMIT 20;


-- ============================================================
-- 11. 清理
-- ============================================================
DROP TABLE IF EXISTS perf_events ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS perf_skip ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS perf_projection ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS perf_sample ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS perf_raw ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS perf_preagg_mv ON CLUSTER 'treasurycluster' SYNC;
-- 如需清理数据库：DROP DATABASE IF EXISTS advance_test ON CLUSTER 'treasurycluster';
