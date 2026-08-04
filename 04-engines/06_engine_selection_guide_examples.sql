-- ============================================================
-- 文件: 04-engines/06_engine_selection_guide_examples.sql
-- 学习目标: 掌握 7 大业务场景的引擎选择 + DDL 最佳实践
-- 深度标准: 原理 + 场景 + 对比 + 可运行
-- 集群: treasurycluster (CH 25.12.1.649, 单分片 2 副本)
-- 前置: 无（自包含测试数据，按顺序执行）
-- ============================================================
--
-- 本文件章节:
--   1.  生产环境标配：ReplicatedMergeTree（高可用基线）
--   2.  分区策略对比（按天 vs 按月 vs 按年）
--   3.  排序键设计（前缀匹配原则）
--   4.  跳数索引（minmax / bloom_filter 选择）
--   5.  物化视图预聚合（AggregatingMergeTree + *State）
--   6.  去重策略（ReplacingMergeTree + argMax 查询模式）
--   7.  增量更新（CollapsingMergeTree 正确的 sign 镜像写法）
--   8.  分布式表分片键设计
--   9.  TTL 数据生命周期（DELETE + 冷热分层）
--   10. 清理
-- ============================================================

CREATE DATABASE IF NOT EXISTS engine_guide ON CLUSTER 'treasurycluster';
USE engine_guide;


-- ============================================================
-- 1. 生产环境标配：ReplicatedMergeTree（高可用基线）
-- ============================================================
-- 【原理】ReplicatedMergeTree 通过 Keeper 协调多副本，单节点宕机不丢数据
-- 【场景】所有生产表的默认选择；非复制 MergeTree 无高可用
-- 【对比】
--   MergeTree           —— 单副本，磁盘损坏数据丢失，仅测试用
--   ReplicatedMergeTree —— 多副本 + Keeper 协调，生产标配
-- 【坑】必须配合 ON CLUSTER 才能在所有节点建表
-- 【坑★】ReplicatedMergeTree 的 ZK 路径若不含库名（如 /clickhouse/tables/{shard}/events），
--   不同库的同名表会 ZK 路径冲突 → "Missing columns" 报错。解决：用不同表名或显式指定 ZK 路径

DROP TABLE IF EXISTS events_log ON CLUSTER 'treasurycluster' SYNC;

-- 推荐（生产环境：复制引擎 + ON CLUSTER）
CREATE TABLE events_log ON CLUSTER 'treasurycluster' (
    id UInt64,
    user_id UInt64,
    event_type String,
    event_data String,
    timestamp DateTime
) ENGINE = ReplicatedMergeTree()
PARTITION BY toYYYYMM(timestamp)
ORDER BY (user_id, timestamp);

-- 避免（单节点，无复制，磁盘损坏数据丢失）
-- CREATE TABLE events_log (
--     id UInt64, data String, timestamp DateTime
-- ) ENGINE = MergeTree()
-- PARTITION BY toYYYYMM(timestamp)
-- ORDER BY (id, timestamp);

INSERT INTO events_log VALUES
    (1, 101, 'click',  '{"page":"home"}',     '2024-01-01 10:00:00'),
    (2, 102, 'view',   '{"page":"products"}', '2024-01-01 10:05:00'),
    (3, 101, 'purchase','{"product_id":101}',  '2024-01-01 12:00:00');

SELECT count(), min(timestamp), max(timestamp) FROM events_log;


-- ============================================================
-- 2. 分区策略对比（按天 vs 按月 vs 按年）
-- ============================================================
-- 【原理】分区是物理目录隔离，只在分区内 merge + 剪枝
-- 【决策】
--   按天 toDate(ts)     —— 高频查询特定天，但分区数易爆炸(>1000 崩溃)
--   按月 toYYYYMM(ts)   —— 90% 场景最佳粒度，单表分区数可控
--   按年 toYYYY(ts)     —— 归档/低频查询，分区数少但单分区数据大
-- 【坑】分区数 > 1000 时 merge 调度崩溃；单分区 > 150GB 不再合并
-- 【对比】分区 vs 排序键：分区是物理隔离(粗剪枝)，排序键是分区内稀疏索引(细定位)

-- 按月分区（推荐）
-- PARTITION BY toYYYYMM(timestamp)

-- 按天分区（仅当每天查询独立且数据量大时用）
-- PARTITION BY toDate(timestamp)

-- 按年分区（归档场景）
-- PARTITION BY toYYYY(timestamp)

-- 查看当前分区数（监控分区爆炸）
SELECT
    database, table,
    count() AS partition_count,
    formatReadableSize(sum(bytes_on_disk)) AS total_size
FROM system.parts
WHERE database = 'engine_guide' AND table = 'events_log' AND active = 1
GROUP BY database, table;


-- ============================================================
-- 3. 排序键设计（前缀匹配原则）
-- ============================================================
-- 【原理】ORDER BY 决定 Part 内物理排序 + 稀疏主键索引
--   查询 WHERE 条件命中 ORDER BY 前缀 → 走稀疏索引快速定位
--   不命中前缀 → 全表扫描
-- 【原则】高频过滤条件放前面，时间放最后
-- 【对比】
--   WHERE user_id = ?              → ORDER BY (user_id, timestamp) ✓ 前缀命中
--   WHERE user_id = ? AND type = ? → ORDER BY (user_id, event_type, timestamp) ✓
--   WHERE timestamp > ?            → ORDER BY (user_id, timestamp) ✗ 非前缀，全扫
--   WHERE timestamp > ?            → ORDER BY (timestamp, user_id) ✓ 但牺牲 user_id 查询

-- 场景1: 常见查询 WHERE user_id = ?
-- ORDER BY (user_id, timestamp)

-- 场景2: 常见查询 WHERE user_id = ? AND event_type = ?
-- ORDER BY (user_id, event_type, timestamp)

-- 场景3: 时间序列查询 WHERE timestamp > ?
-- ORDER BY (timestamp, user_id)

-- 验证排序键前缀剪枝效果：read_rows 应远小于总行数
SET log_query_threads = 1;
SELECT count() FROM events_log WHERE user_id = 101 AND event_type = 'click';

-- 查看读取行数（评估索引剪枝效果）
SELECT
    query_duration_ms,
    read_rows,
    formatReadableSize(read_bytes) AS data_read
FROM system.query_thread_log
WHERE positionCaseInsensitive(query, 'events_log') > 0
  AND is_initial_query = 1
  AND read_rows > 0
ORDER BY event_time DESC
LIMIT 3;


-- ============================================================
-- 4. 跳数索引（minmax / bloom_filter 选择）
-- ============================================================
-- 【原理】跳数索引在稀疏主键索引之上做二次过滤，跳过不匹配的 granule
-- 【决策表】
--   minmax        —— 有序/范围列（如 timestamp、price），开销最小
--   set(max_rows) —— 低基数枚举列（如 status < 100 个值）
--   bloom_filter  —— 等值查询高基数列（如 user_id、order_id），有假阳性无假阴性
--   tokenbf       —— 空格分词字符串搜索（LIKE '%word%'）
--   ngrambf       —— CJK 无空分词搜索（中文 LIKE '%关键词%'）
-- 【坑】跳数索引不是万能的：无 WHERE 条件时索引无效；加太多会拖慢写入

DROP TABLE IF EXISTS events_idx ON CLUSTER 'treasurycluster' SYNC;

CREATE TABLE events_idx ON CLUSTER 'treasurycluster' (
    id UInt64,
    user_id UInt64,
    event_type LowCardinality(String),
    amount Decimal(10, 2),
    timestamp DateTime,
    -- minmax: 适合范围查询 WHERE timestamp > ?
    INDEX idx_ts_minmax timestamp TYPE minmax GRANULARITY 4,
    -- bloom_filter: 适合等值查询 WHERE user_id = ?
    INDEX idx_user_bloom user_id TYPE bloom_filter(0.01) GRANULARITY 4
) ENGINE = ReplicatedMergeTree()
PARTITION BY toYYYYMM(timestamp)
ORDER BY (event_type, timestamp);

INSERT INTO events_idx
SELECT
    number AS id,
    number % 1000 AS user_id,
    ['click', 'view', 'purchase'][1 + (number % 3)] AS event_type,
    round(rand() * 1000, 2) AS amount,
    toDateTime('2024-01-01 00:00:00') + number AS timestamp
FROM numbers(100000);

-- bloom_filter 加速等值查询
SELECT count() FROM events_idx WHERE user_id = 500;

-- minmax 加速范围查询
SELECT count() FROM events_idx WHERE timestamp BETWEEN '2024-01-01 12:00:00' AND '2024-01-01 18:00:00';


-- ============================================================
-- 5. 物化视图预聚合（AggregatingMergeTree + *State）
-- ============================================================
-- 【原理】MV = 触发器 + 存储表。源表 INSERT 时自动执行 SELECT 写入 MV
--   用 *State 写入聚合中间态，*Merge 查询还原最终值
-- 【场景】实时日报表：明细表 → 日聚合表（count/sum/uniq 全家族）
-- 【坑1】MV 仅 INSERT 触发，DELETE/UPDATE 不触发
-- 【坑2】MV 创建前的历史数据不回填，需手动 INSERT INTO MV SELECT
-- 【对比】vs 普通视图: MV 有存储(预聚合)，查询快；View 无存储，查询=原始SQL
-- 【关联】*State/*Merge 原理详见 05-functions/README.md §3

DROP TABLE IF EXISTS events_daily_mv ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS events_src ON CLUSTER 'treasurycluster' SYNC;

-- 源表（明细）
CREATE TABLE events_src ON CLUSTER 'treasurycluster' (
    user_id UInt64,
    event_type String,
    amount Float64,
    timestamp DateTime
) ENGINE = ReplicatedMergeTree()
PARTITION BY toYYYYMM(timestamp)
ORDER BY (user_id, timestamp);

-- 物化视图（预聚合：日维度）
-- 【关键】ORDER BY 用 MV 输出列(date)，不是源表列(timestamp)
CREATE MATERIALIZED VIEW events_daily_mv ON CLUSTER 'treasurycluster'
ENGINE = ReplicatedAggregatingMergeTree()
PARTITION BY toYYYYMM(date)
ORDER BY (user_id, date)
AS SELECT
    user_id,
    toDate(timestamp) AS date,
    countState() AS event_count_state,
    sumState(amount) AS gmv_state,
    uniqState(event_type) AS distinct_types_state
FROM events_src
GROUP BY user_id, date;

-- 写入源表（MV 自动触发预聚合）
INSERT INTO events_src VALUES
    (1, 'click',   10.5,  '2024-01-01 10:00:00'),
    (1, 'view',    5.0,   '2024-01-01 10:05:00'),
    (2, 'click',   15.0,  '2024-01-01 11:00:00'),
    (1, 'click',   20.0,  '2024-01-02 09:00:00'),
    (3, 'purchase', 99.99,'2024-01-02 12:00:00');

-- 查询 MV（用 *Merge 还原）
SELECT
    user_id,
    date,
    countMerge(event_count_state) AS event_count,
    sumMerge(gmv_state) AS gmv,
    uniqMerge(distinct_types_state) AS distinct_types
FROM events_daily_mv
GROUP BY user_id, date
ORDER BY date, user_id;

-- 二级聚合：日 → 月（状态可继续合并，不丢精度）
SELECT
    toStartOfMonth(date) AS month,
    countMerge(event_count_state) AS monthly_events,
    sumMerge(gmv_state) AS monthly_gmv,
    uniqMerge(distinct_types_state) AS monthly_distinct_types
FROM events_daily_mv
GROUP BY month
ORDER BY month;


-- ============================================================
-- 6. 去重策略（ReplacingMergeTree + argMax 查询模式）
-- ============================================================
-- 【原理】ReplacingMergeTree(version) merge 时同主键保留 version 最大
-- 【去重时机】只在后台 merge 时去重；查询时可能仍有重复
-- 【3 种去重查询写法】
--   A. FINAL             —— 查询时临时合并，简单但慢（大数据禁用）
--   B. GROUP BY + argMax —— 推荐！可并行，性能好
--   C. OPTIMIZE FINAL    —— 物理合并，影响写入，不能在线频繁用
-- 【坑】argMax(val, ver) 的别名不能与列名同名（否则 ILLEGAL_AGGREGATION）

DROP TABLE IF EXISTS user_state ON CLUSTER 'treasurycluster' SYNC;

CREATE TABLE user_state ON CLUSTER 'treasurycluster' (
    user_id UInt64,
    status String,
    version UInt64
) ENGINE = ReplicatedReplacingMergeTree(version)
ORDER BY user_id;

-- 【注意】CH 解析器不支持 VALUES 块内的行内注释，注释只能写在 INSERT 之外
-- user1 在 v2 中由 online 变为 busy；user3 首次出现
INSERT INTO user_state VALUES
    (1, 'online',  1),
    (2, 'offline', 1),
    (1, 'busy',    2),
    (3, 'online',  1);

-- 写法A: FINAL（简单但慢，大数据禁用）
SELECT user_id, status, version FROM user_state FINAL ORDER BY user_id;

-- 写法B: argMax（推荐）
-- 【坑】max(ver) 的别名不能是 ver，否则 argMax(val, ver) 中的 ver 被当成别名 → 嵌套聚合
SELECT
    user_id,
    argMax(status, version) AS status,
    max(version) AS max_ver
FROM user_state
GROUP BY user_id
ORDER BY user_id;


-- ============================================================
-- 7. 增量更新（CollapsingMergeTree 正确的 sign 镜像写法）
-- ============================================================
-- 【原理】sign(+1/-1) 标记行：merge 时同主键 +1/-1 配对抵消
-- 【关键规则★】sign=-1 行的值必须 = 被取消行(sign=+1)的值（镜像），不是差值！
--   正确: 先插 (id, old_val, +1)，更新时插 (id, old_val, -1) + (id, new_val, +1)
--   错误: 插 (id, delta, -1) —— 合并前后结果不一致！
-- 【查询】必须 sum(col * sign) + GROUP BY，不能 SELECT *
-- 【场景】流式增量计数器：库存、账户余额、积分变动
-- 【乱序写入】用 VersionedCollapsingMergeTree(sign, version)

DROP TABLE IF EXISTS inventory ON CLUSTER 'treasurycluster' SYNC;

CREATE TABLE inventory ON CLUSTER 'treasurycluster' (
    product_id UInt64,
    quantity Int32,
    sign Int8,
    timestamp DateTime
) ENGINE = ReplicatedCollapsingMergeTree(sign)
ORDER BY product_id;

-- 初始库存（sign=+1）
INSERT INTO inventory VALUES (101, 100, 1, '2024-01-01 10:00:00');

-- 更新：101 卖了 10 个（新库存 90）
-- 【正确写法】先插 sign=-1 镜像旧值(100)，再插 sign=+1 新值(90)
-- 第一行(101,100,-1) 是「镜像旧值」：值必须等于被取消行的值
-- 第二行(101,90,+1)  是「新状态」：库存调整后的最新值
INSERT INTO inventory VALUES
    (101, 100, -1, '2024-01-01 11:00:00'),
    (101, 90,   1, '2024-01-01 11:00:00');

-- 错误写法（演示坑）：
-- INSERT INTO inventory VALUES (101, 10, -1, now());  -- 把差值10当sign=-1 → 合并前后不一致

-- 正确查询：sum(quantity * sign) + GROUP BY
-- 【结果解读】101: 100*1 + 100*(-1) + 90*1 = 90（合并前/后都一致）
SELECT
    product_id,
    sum(quantity * sign) AS current_inventory
FROM inventory
GROUP BY product_id
ORDER BY product_id;

-- 验证：触发合并后结果不变
OPTIMIZE TABLE inventory FINAL;
SELECT
    product_id,
    sum(quantity * sign) AS current_inventory_after_merge
FROM inventory
GROUP BY product_id
ORDER BY product_id;


-- ============================================================
-- 8. 分布式表分片键设计
-- ============================================================
-- 【原理】Distributed 表不存数据，是查询路由层 + 写入分片器
-- 【分片键原则】
--   1. 高基数：避免数据倾斜（user_id 比 gender 好）
--   2. 查询过滤：若 WHERE user_id=?，分片键用 user_id 可做分片剪枝
--   3. 均匀分布：intHash32(user_id) 打散热点
--   4. 避免 rand()：无法做分片剪枝
-- 【注意】以下为示意语法，实际需先建 local 表
-- 【坑】写入 Distributed 表会先缓存到本机再转发，宕机会丢未转发数据
--   → 生产建议直接写本地表，Distributed 仅做查询入口

-- 场景1: 常见查询 WHERE user_id = ?
-- 分片键: user_id（可做分片剪枝）
-- CREATE TABLE distributed_events AS engine_guide.local_events
-- ENGINE = Distributed(treasurycluster, engine_guide, local_events, user_id);

-- 场景2: 常见查询 WHERE timestamp > ?（无 user_id 过滤）
-- 分片键: intHash32(timestamp)（均匀分布，但无法分片剪枝）
-- CREATE TABLE distributed_events AS engine_guide.local_events
-- ENGINE = Distributed(treasurycluster, engine_guide, local_events, intHash32(timestamp));

-- 场景3: 常见查询 WHERE user_id = ? AND timestamp > ?
-- 分片键: user_id（优先支持等值查询的分片剪枝）
-- CREATE TABLE distributed_events AS engine_guide.local_events
-- ENGINE = Distributed(treasurycluster, engine_guide, local_events, user_id);


-- ============================================================
-- 9. TTL 数据生命周期（DELETE + 冷热分层）
-- ============================================================
-- 【原理】TTL 在 merge 时自动删除/移动过期数据，比手动删分区更优雅
-- 【类型】
--   TTL ts + INTERVAL 30 DAY DELETE              —— 删除
--   TTL ts + INTERVAL 7 DAY TO DISK 'cold'       —— 移到冷存储盘
--   TTL ts + INTERVAL 30 DAY TO VOLUME 'archive' —— 移到存储卷
-- 【触发】TTL 在后台 merge 时执行，不是实时删除
-- 【监控】system.parts 的 delete_ttl_info_min/max

DROP TABLE IF EXISTS events_ttl ON CLUSTER 'treasurycluster' SYNC;

-- 30 天后自动删除
CREATE TABLE events_ttl ON CLUSTER 'treasurycluster' (
    id UInt64,
    data String,
    timestamp DateTime
) ENGINE = ReplicatedMergeTree()
PARTITION BY toYYYYMM(timestamp)
ORDER BY timestamp
TTL timestamp + INTERVAL 365 DAY;

INSERT INTO events_ttl VALUES
    (1, 'recent', now()),
    (2, 'old',    now() - INTERVAL 400 DAY);

-- 查看 TTL 信息
SELECT
    name AS part_name,
    rows,
    delete_ttl_info_min,
    delete_ttl_info_max
FROM system.parts
WHERE database = 'engine_guide' AND table = 'events_ttl' AND active = 1;

-- 冷热分层（需 config.xml 配置 storage_disk/policy，此处仅示意）
-- CREATE TABLE events_cold ON CLUSTER 'treasurycluster' (
--     id UInt64, data String, timestamp DateTime
-- ) ENGINE = ReplicatedMergeTree()
-- ORDER BY timestamp
-- TTL
--     timestamp + INTERVAL 7 DAY DELETE,
--     timestamp + INTERVAL 30 DAY TO VOLUME 'archive';


-- ============================================================
-- 10. 清理
-- ============================================================
DROP TABLE IF EXISTS events_log ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS events_idx ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS events_daily_mv ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS events_src ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS user_state ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS inventory ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS events_ttl ON CLUSTER 'treasurycluster' SYNC;
