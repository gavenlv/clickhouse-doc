-- ============================================================
-- 文件: 02-principles/03_mergetree.sql
-- 学习目标: 深入理解 MergeTree 引擎的 Part 生命周期、合并算法、5 种变体
-- 深度标准: 原理 + 场景 + 对比 + 可运行
-- 集群: treasurycluster (CH 25.12.1.649, 2 副本 × 1 分片, 3 Keeper)
-- 前置: 无（自包含测试数据，按顺序执行）
-- ============================================================
--
-- 本文件章节:
--   1.  MergeTree 存储结构（Part 文件组织）
--   2.  Part 生命周期（INSERT → Merge → TTL）
--   3.  Part 命名规则（partition_min_max_level_mutation）
--   4.  小写入导致 Part 爆炸演示（诊断 + 修复）
--   5.  强制合并 OPTIMIZE FINAL（生产慎用）
--   6.  主键稀疏索引验证（mark 二分查找）
--   7.  分区剪枝（PARTITION BY 工作机制）
--   8.  5 种 MergeTree 变体对比（Replacing/Summing/Aggregating/Collapsing/Versioned）
--   9.  TTL 自动过期（数据生命周期）
--  10.  读写流程分析（EXPLAIN）
--  11.  清理
--
-- 关联文档: README.md §3.2 Part 生命周期 / §5 存储结构
-- ============================================================

CREATE DATABASE IF NOT EXISTS tutorial;
USE tutorial;

-- ============================================================
-- 1. MergeTree 存储结构
-- ============================================================
-- 【原理】MergeTree 物理目录结构:
--   /var/lib/clickhouse/data/<db>/<table>/<partition>_<min_block>_<max_block>_<level>_<mutation>/
--     ├── primary.idx          # 主键稀疏索引 (每 8192 行一个 mark)
--     ├── <col>.bin            # 列数据 (LZ4/ZSTD 压缩)
--     ├── <col>.mrk2           # 列 mark 文件 (列在 .bin 中的偏移)
--     ├── count.txt            # Part 行数
--     ├── columns.txt          # 列定义
--     ├── checksums.txt        # 校验和
--     ├── minmax_<col>.idx     # 分区列 minmax (剪枝用)
--     └── [default_compression_codec.txt]
--   小 Part (< min_bytes_for_wide_part=10MB) 用 Compact: 单个 data.bin 文件
--   大 Part 用 Wide: 每列独立文件
-- 【场景】理解目录结构后能直接 ls 查看表状态, 排查磁盘问题

-- 1.1 创建基础 MergeTree 表
DROP TABLE IF EXISTS tutorial.mergetree_demo;

CREATE TABLE tutorial.mergetree_demo (
    id UInt64,
    user_id UInt32,
    event_type LowCardinality(String),
    event_date Date,
    value Float64,
    created_at DateTime DEFAULT now()
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_date)
ORDER BY (event_date, user_id, id)
SETTINGS index_granularity = 8192;

-- 1.2 三次小批量插入 —— 每次生成 1 个 Part
-- 【原理】每次 INSERT 创建 1 个新 Part, Part 不可变, 后台异步合并
-- 【对比】vs MySQL: MySQL INSERT 直接写入 B+Tree 页, 不产生"Part"; CH 是 LSM-like 设计
INSERT INTO tutorial.mergetree_demo (id, user_id, event_type, event_date, value)
SELECT number, number % 1000, 'click', toDate('2024-01-01'), rand() / 100.0
FROM numbers(10000);

INSERT INTO tutorial.mergetree_demo (id, user_id, event_type, event_date, value)
SELECT number + 10000, number % 1000, 'view', toDate('2024-01-02'), rand() / 100.0
FROM numbers(10000);

INSERT INTO tutorial.mergetree_demo (id, user_id, event_type, event_date, value)
SELECT number + 20000, number % 1000, 'purchase', toDate('2024-01-03'), rand() / 100.0
FROM numbers(10000);

-- ============================================================
-- 2. 查看 Parts 结构 —— Part 生命周期
-- ============================================================
-- 【原理】system.parts 每行=一个 Part
--   - active=1: 当前可见的 Part (查询用)
--   - active=0: 已被合并替换, 等待清理
--   - level: 合并层级, 0=原始, 越大合并次数越多
-- 【结果解读】应看到 3 个 active Part (3 次 INSERT), 名字类似 202401_1_1_0, 202401_2_2_0, 202401_3_3_0
SELECT
    partition,
    name AS part_name,
    rows,
    formatReadableSize(bytes) AS size,
    level,
    active,
    min_date,
    max_date,
    min_block_number,
    max_block_number
FROM system.parts
WHERE database = 'tutorial' AND table = 'mergetree_demo'
ORDER BY active DESC, partition, name;

-- ============================================================
-- 3. Part 命名规则解读
-- ============================================================
-- 【原理】Part 名: {partition}_{min_block}_{max_block}_{level}_{mutation_version}
--   例: 202401_1_3_1_0
--     ├── partition: 202401 (按月分区的分区键值)
--     ├── min_block: 1 (合并前最小 block 编号)
--     ├── max_block: 3 (合并前最大 block 编号)
--     ├── level: 1 (合并层级, 0=未合并, 1=合并一次, 2=合并两次...)
--     └── mutation_version: 0 (mutation 版本号, 对应 system.parts.data_version,
--         0=无 ALTER UPDATE/DELETE。CH 25.x 已将该列改名为 data_version)
--   无分区表 partition 固定为 "all", 例: all_5_5_0
-- 【场景】看 Part 名能立刻知道:
--   - 数据属于哪个分区
--   - 由几个原始 block 合并而成
--   - 合并了多少次
--   - 是否做过 mutation

-- 3.1 查看当前所有 Part 的命名解读
SELECT
    name,
    partition,
    min_block_number,
    max_block_number,
    level,
    data_version,                                   -- CH 25.x: 原 mutation_version 已改名
    rows
FROM system.parts
WHERE database = 'tutorial' AND table = 'mergetree_demo' AND active = 1
ORDER BY name;

-- ============================================================
-- 4. 后台合并机制
-- ============================================================
-- 【原理】合并触发条件:
--   ① 后台任务每 ~15 秒检查一次
--   ② 同分区内 active Part 数 > 1 (有可合并的)
--   ③ 不超过 max_parts_to_merge_at_once (默认 100)
--   ④ 不在 TTL merge_with_ttl_timeout 内 (默认 14400 秒)
-- 合并算法:
--   ① 选择同分区内相邻 block 号的小 Part
--   ② 多线程读取所有 Part 数据
--   ③ 按 ORDER BY 排序合并 (流式归并)
--   ④ 写入新 Part (新的 block 号范围)
--   ⑤ 原子替换: 旧 Part active=0, 新 Part active=1
--   ⑥ 后台清理旧 Part (10 分钟后物理删除)
-- 【场景】查看合并进度: system.merges; 强制合并: OPTIMIZE TABLE ... FINAL

-- 4.1 查看当前合并任务
SELECT
    database,
    table,
    elapsed,
    progress,
    num_parts,
    result_part_name,
    formatReadableSize(total_size_bytes_compressed) AS total_size
FROM system.merges
WHERE database = 'tutorial' AND table = 'mergetree_demo';

-- 4.2 强制合并 —— OPTIMIZE FINAL
-- 【原理】OPTIMIZE 触发一次合并; FINAL 强制合并到单一 Part
-- 【坑】生产慎用!
--   - 会重写整个分区的所有 Part, I/O 巨大
--   - 阻塞写入(短暂)
--   - 占用合并线程池, 影响其他表合并
--   - 仅适合: 数据写入完成后的批处理, 或排查 Part 爆炸时
OPTIMIZE TABLE tutorial.mergetree_demo FINAL;

-- 4.3 合并后查看 —— 应只剩 1 个 active Part
-- 【结果解读】level 升高(从 0 到 1+), block 号范围合并(1-3)
SELECT
    partition,
    name AS part_name,
    rows,
    formatReadableSize(bytes) AS size,
    level,
    active
FROM system.parts
WHERE database = 'tutorial' AND table = 'mergetree_demo' AND active = 1
ORDER BY partition, name;

-- ============================================================
-- 5. Part 爆炸演示 (诊断 + 修复)
-- ============================================================
-- 【原理】Part 爆炸 = 单表 active Part 数过多, 通常因小批量高频写入
--   症状:
--     ① SELECT count() FROM system.parts WHERE table='x' AND active=1 持续上涨
--     ② 写入延迟变高 (parts_to_delay_insert 触发)
--     ③ Too many parts 错误 (parts_to_throw_insert 触发)
--   修复:
--     ① 合并写入批次 (>=1万行/次)
--     ② 用 Buffer 表或 Kafka 引擎攒批
--     ③ 改粗分区 (按月代替按天)
--     ④ 必要时 OPTIMIZE FINAL 强制合并

-- 5.1 模拟 Part 爆炸 —— 10 次小写入
DROP TABLE IF EXISTS tutorial.part_explosion;

CREATE TABLE tutorial.part_explosion (
    id UInt64,
    event_date Date,
    value Float64
) ENGINE = MergeTree()
PARTITION BY toYYYYMMDD(event_date)  -- 【反例】按天分区 + 小写入 = Part 爆炸
ORDER BY id;

-- 5.2 10 次写入, 每次 100 行, 不同日期 → 10 个分区 × 1 Part = 10 个 Part
INSERT INTO tutorial.part_explosion SELECT number, toDate('2024-01-01'), rand() FROM numbers(100);
INSERT INTO tutorial.part_explosion SELECT number, toDate('2024-01-02'), rand() FROM numbers(100);
INSERT INTO tutorial.part_explosion SELECT number, toDate('2024-01-03'), rand() FROM numbers(100);
INSERT INTO tutorial.part_explosion SELECT number, toDate('2024-01-04'), rand() FROM numbers(100);
INSERT INTO tutorial.part_explosion SELECT number, toDate('2024-01-05'), rand() FROM numbers(100);

-- 5.3 查看 Part 数量
-- 【结果解读】5 个分区, 每个分区 1 个 Part, 共 5 个 active Part
SELECT
    partition,
    count() AS part_count,
    sum(rows) AS total_rows
FROM system.parts
WHERE database = 'tutorial' AND table = 'part_explosion' AND active = 1
GROUP BY partition
ORDER BY partition;

-- 5.4 查看相关阈值设置
SELECT
    name,
    value,
    description
FROM system.merge_tree_settings
WHERE name IN ('max_parts_in_total', 'parts_to_delay_insert', 'parts_to_throw_insert',
               'max_parts_to_merge_at_once');

DROP TABLE IF EXISTS tutorial.part_explosion;

-- ============================================================
-- 6. 主键稀疏索引验证
-- ============================================================
-- 【原理】主键 = ORDER BY 列, 不保证唯一性, 只定义物理排序
--   primary.idx 文件: 每 8192 行记录一个 mark (排序键值)
--   .mrk2 文件: 每列每 mark 在 .bin 中的偏移
--   查询 WHERE user_id=100:
--     ① 二分查找 primary.idx → 定位 mark N (mark N 的 user_id <= 100 < mark N+1)
--     ② 查 user_id.mrk2 → 找到该 mark 在 user_id.bin 的偏移
--     ③ 只读取该 granule 的 8192 行
--     ④ 在 8192 行中线性扫描(SIMD)找到 user_id=100 的行
-- 【对比】vs MySQL B+Tree:
--   - B+Tree 每行一个索引项 → 1亿行索引约 1GB, 常驻内存难
--   - 稀疏索引 8192 行一个 mark → 1亿行仅 12K mark, 几 KB, 常驻内存
--   - 代价: 不能高效点查(要读 8192 行), OLAP 不需要

-- 6.1 查看主键索引大小
SELECT
    name AS part_name,
    rows,
    formatReadableSize(marks_size) AS marks_size,
    formatReadableSize(primary_key_bytes_in_memory) AS pk_in_memory,
    rows / 8192 AS approx_marks
FROM system.parts
WHERE database = 'tutorial' AND table = 'mergetree_demo' AND active = 1;

-- 6.2 查询特定范围 —— 稀疏索引生效
-- 【原理】WHERE user_id=100 AND event_date>=... 会先用主键索引定位 mark
-- 【结果解读】read_rows 应远小于表总行数, 因为只读取了命中 mark 的 granule
SELECT
    user_id,
    event_date,
    count() AS cnt,
    round(sum(value), 2) AS total_value
FROM tutorial.mergetree_demo
WHERE user_id = 100 AND event_date >= '2024-01-01'
GROUP BY user_id, event_date;

-- 6.3 用 EXPLAIN ESTIMATE 看估算
EXPLAIN ESTIMATE
SELECT count() FROM tutorial.mergetree_demo
WHERE user_id = 100 AND event_date >= '2024-01-01';

-- ============================================================
-- 7. 分区剪枝 (Partition Pruning)
-- ============================================================
-- 【原理】查询 WHERE event_date >= '2024-02-01' AND event_date < '2024-03-01':
--   ① 解析分区键 toYYYYMM(event_date) = 202402
--   ② 跳过 partition != 202402 的所有 Part
--   ③ 只扫描 partition = 202402 的 Part
--   分区剪枝是 O(分区数), 比主键索引更早执行
-- 【场景】按时间范围查询是 OLAP 最常见场景, 按月/按日分区大幅省 I/O
-- 【坑】WHERE toYYYYMM(event_date)=202402 不一定剪枝, 要用 event_date 范围比较才稳

DROP TABLE IF EXISTS tutorial.partition_demo;

CREATE TABLE tutorial.partition_demo (
    id UInt64,
    event_date Date,
    event_type String,
    value Float64
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_date)
ORDER BY (event_date, id);

INSERT INTO tutorial.partition_demo VALUES (1, '2024-01-15', 'click', 10.0);
INSERT INTO tutorial.partition_demo VALUES (2, '2024-02-15', 'view', 20.0);
INSERT INTO tutorial.partition_demo VALUES (3, '2024-03-15', 'purchase', 30.0);
INSERT INTO tutorial.partition_demo VALUES (4, '2024-04-15', 'click', 40.0);
INSERT INTO tutorial.partition_demo VALUES (5, '2024-05-15', 'view', 50.0);

-- 7.1 查看分区
SELECT
    partition,
    name AS part_name,
    rows,
    min_date,
    max_date,
    active
FROM system.parts
WHERE database = 'tutorial' AND table = 'partition_demo' AND active = 1
ORDER BY partition;

-- 7.2 分区剪枝测试 —— 只查 2024-02
-- 【结果解读】只扫描 partition=202402 的 Part, 跳过其他 4 个分区
SELECT * FROM tutorial.partition_demo
WHERE event_date >= '2024-02-01' AND event_date < '2024-03-01';

-- 7.3 用 EXPLAIN 查看分区剪枝
EXPLAIN PLAN
SELECT * FROM tutorial.partition_demo
WHERE event_date >= '2024-02-01' AND event_date < '2024-03-01';

DROP TABLE IF EXISTS tutorial.partition_demo;

-- ============================================================
-- 8. 5 种 MergeTree 变体对比
-- ============================================================
-- 【原理】MergeTree 家族 5 个核心变体, 用"合并时的特殊行为"区分:
--   ① MergeTree: 基础, 不去重不聚合, 数据全部保留
--   ② ReplacingMergeTree(version): 合并时按 ORDER BY 去重, 保留 version 最大的
--   ③ SummingMergeTree(columns): 合并时按 ORDER BY 求和指定列
--   ④ AggregatingMergeTree: 配合 *State 函数, 合并时聚合状态
--   ⑤ CollapsingMergeTree(sign): 用 sign=+1/-1 实现"折叠", 适合增量更新
--   ⑥ VersionedCollapsingMergeTree: Collapsing + version, 保证折叠顺序
-- 【关键认知】所有变体的"特殊行为"只在合并时发生, 不保证查询时已生效
--   → 查询时要么 FINAL(慢), 要么 GROUP BY + 聚合函数(推荐)

-- 8.1 ReplacingMergeTree —— 自动去重(按 ORDER BY 去重, 保留 version 最大)
-- 【场景】用户表更新: 同一 user_id 多次写入, 查询要最新状态
-- 【坑】合并是异步的, 查询时未必去重; 用 FINAL 或 GROUP BY 兜底
DROP TABLE IF EXISTS tutorial.replacing_demo;

CREATE TABLE tutorial.replacing_demo (
    id UInt64,
    user_id UInt32,
    value Float64,
    version UInt8,
    updated_at DateTime DEFAULT now()
) ENGINE = ReplacingMergeTree(version)  -- version 大的覆盖小的
ORDER BY id;

-- 3 行同 id=1, version 递增; 合并后保留 version 最大的(=3, value=30.0)
INSERT INTO tutorial.replacing_demo VALUES (1, 100, 10.0, 1, now());
INSERT INTO tutorial.replacing_demo VALUES (1, 100, 20.0, 2, now());
INSERT INTO tutorial.replacing_demo VALUES (1, 100, 30.0, 3, now());

-- 8.1.1 合并前 —— 3 行都在
SELECT * FROM tutorial.replacing_demo ORDER BY id, version;

-- 8.1.2 强制合并
OPTIMIZE TABLE tutorial.replacing_demo FINAL;

-- 8.1.3 合并后 —— 只剩 version=3 的那行
SELECT * FROM tutorial.replacing_demo ORDER BY id;

-- 8.2 SummingMergeTree —— 自动求和(按 ORDER BY 求和非 key 列)
-- 【场景】订单按 (date, category, product) 汇总数量金额
-- 【坑】只对数值列求和, String 列取任意一行; 合并是异步的
DROP TABLE IF EXISTS tutorial.summing_demo;

CREATE TABLE tutorial.summing_demo (
    event_date Date,
    category String,
    product_id UInt32,
    quantity UInt32,
    amount Float64
) ENGINE = SummingMergeTree()
PARTITION BY toYYYYMM(event_date)
ORDER BY (event_date, category, product_id);  -- 这三列是 key, 不求和

-- 【注意】VALUES 块内不能有行内注释(CH 解析器限制), 注释写在 INSERT 前
-- 下列第 2 行与第 1 行 key 相同(event_date+category+product_id), 合并时 quantity+amount 求和
INSERT INTO tutorial.summing_demo VALUES
    ('2024-01-01', 'electronics', 1, 10, 1000.0),
    ('2024-01-01', 'electronics', 1, 5, 500.0),
    ('2024-01-01', 'books', 2, 3, 60.0);

-- 8.2.1 合并前 —— 3 行
SELECT * FROM tutorial.summing_demo ORDER BY event_date, category;

-- 8.2.2 强制合并
OPTIMIZE TABLE tutorial.summing_demo FINAL;

-- 8.2.3 合并后 —— electronics 行的 quantity=15, amount=1500.0
SELECT * FROM tutorial.summing_demo ORDER BY event_date, category;

-- 8.3 AggregatingMergeTree —— 配合 *State 函数预聚合
-- 【场景】实时报表预聚合: 原始表 INSERT 时, 物化视图用 *State 函数物化中间态
-- 【对比】详见 04-functions §11 聚合状态函数
-- 【坑】AggregateFunction 列不能用普通 INSERT, 必须用 *State 函数; 查询用 *Merge
DROP TABLE IF EXISTS tutorial.aggregating_demo;

CREATE TABLE tutorial.aggregating_demo (
    event_date Date,
    user_id UInt32,
    event_type String,
    pv UInt64,
    uv AggregateFunction(uniq, UInt32)  -- 必须用 *State 函数写入
) ENGINE = AggregatingMergeTree()
PARTITION BY toYYYYMM(event_date)
ORDER BY (event_date, user_id, event_type);

-- 【注意】AggregateFunction 列不能用 INSERT VALUES(解析器不支持函数表达式),
--   必须用 INSERT ... SELECT 让 *State 函数先求值再写入
--   第 2 行与第 1 行 key 相同(event_date+user_id+event_type), 状态会合并
INSERT INTO tutorial.aggregating_demo
SELECT * FROM (
    SELECT toDate('2024-01-01') AS event_date, toUInt32(1) AS user_id, 'click' AS event_type,
           toUInt64(10) AS pv, uniqState(toUInt32(100)) AS uv
    UNION ALL
    SELECT toDate('2024-01-01'), toUInt32(1), 'click', toUInt64(5), uniqState(toUInt32(100))
    UNION ALL
    SELECT toDate('2024-01-01'), toUInt32(2), 'view', toUInt64(8), uniqState(toUInt32(200))
);

-- 8.3.1 查询必须用 *Merge 函数
SELECT
    event_date,
    user_id,
    event_type,
    sum(pv) AS total_pv,
    uniqMerge(uv) AS total_uv  -- 用 uniqMerge 合并状态
FROM tutorial.aggregating_demo
GROUP BY event_date, user_id, event_type
ORDER BY event_date, user_id;

-- 8.4 CollapsingMergeTree —— 用 sign 折叠, 适合"增量更新"
-- 【场景】购物车: 加入商品 sign=+1, 移除商品 sign=-1, 合并时互相抵消
-- 【坑】要求同一 key 的 +1/-1 必须成对, 顺序不能错; 不确定时用 VersionedCollapsingMergeTree
DROP TABLE IF EXISTS tutorial.collapsing_demo;

CREATE TABLE tutorial.collapsing_demo (
    id UInt64,
    user_id UInt32,
    value Float64,
    sign Int8,    -- +1: 新增, -1: 取消
    version UInt8
) ENGINE = CollapsingMergeTree(sign)
ORDER BY id;

-- sign=+1 新增, sign=-1 取消; 同 version 的 +1/-1 抵消, 只剩 version=2 的 +1 行
INSERT INTO tutorial.collapsing_demo VALUES (1, 100, 10.0, 1, 1);
INSERT INTO tutorial.collapsing_demo VALUES (1, 100, 10.0, -1, 1);
INSERT INTO tutorial.collapsing_demo VALUES (1, 100, 20.0, 1, 2);

-- 8.4.1 合并前 —— 3 行
SELECT * FROM tutorial.collapsing_demo ORDER BY id, version;

-- 8.4.2 强制合并
OPTIMIZE TABLE tutorial.collapsing_demo FINAL;

-- 8.4.3 合并后 —— 前两行抵消, 只剩 version=2 的 +1 行
SELECT * FROM tutorial.collapsing_demo ORDER BY id;

-- ============================================================
-- 9. TTL (Time To Live) 自动过期
-- ============================================================
-- 【原理】TTL 表达式: TTL <date_column> + INTERVAL N DAY
--   后台 merge_with_ttl_timeout (默认 14400 秒=4小时) 检查一次
--   过期的 Part 整体删除或移动到 cold disk
-- 【场景】日志保留 30 天, 行为数据保留 90 天, 不用手动 DELETE
-- 【坑】TTL 是合并触发的, 不是实时; 紧急删除用 ALTER TABLE ... DELETE (Mutation)
--   MATERIALIZE TTL 强制重写 Part 应用 TTL (慎用)

DROP TABLE IF EXISTS tutorial.ttl_demo;

CREATE TABLE tutorial.ttl_demo (
    id UInt64,
    event_date DateTime,
    value Float64,
    expired_data String
) ENGINE = MergeTree()
ORDER BY id
TTL event_date + INTERVAL 1 DAY;  -- 1 天后过期

-- 3 行: 第1行已过期(2天前 > 1天TTL), 第2/3行未过期
INSERT INTO tutorial.ttl_demo VALUES
    (1, now() - INTERVAL 2 DAY, 10.0, 'expired'),
    (2, now() - INTERVAL 12 HOUR, 20.0, 'recent'),
    (3, now(), 30.0, 'new');

-- 9.1 查看 Part 的 TTL 信息
-- 【注意】CH 25.x system.parts 无 ttl_info 列, 改用 delete_ttl_info_min/max
--   (TTL DELETE 类型用 delete_ttl_info_*; TTL MOVE 用 move_ttl_info.*)
SELECT
    name AS part_name,
    rows,
    delete_ttl_info_min,                            -- 该 Part 中最早会被 TTL 删除的时间
    delete_ttl_info_max                             -- 该 Part 中最晚会被 TTL 删除的时间
FROM system.parts
WHERE database = 'tutorial' AND table = 'ttl_demo' AND active = 1;

-- 9.2 手动触发 TTL 清理 (生产一般等后台自动)
ALTER TABLE tutorial.ttl_demo MATERIALIZE TTL;

-- 9.3 查看过期数据是否被删除
-- 【结果解读】2 天前的数据应已被清理
SELECT * FROM tutorial.ttl_demo ORDER BY id;

-- ============================================================
-- 10. 读写流程分析 (EXPLAIN)
-- ============================================================
-- 【原理】读取流程:
--   ① 解析查询条件
--   ② 分区剪枝 (跳过无关分区)
--   ③ 主键索引二分查找 (定位 mark)
--   ④ 读取命中 granule 的列数据
--   ⑤ 谓词过滤 (WHERE)
--   ⑥ 聚合/排序
--   ⑦ 返回结果

EXPLAIN PLAN
SELECT
    event_date,
    count() AS cnt
FROM tutorial.mergetree_demo
WHERE user_id = 100 AND event_date >= '2024-01-01'
GROUP BY event_date;

-- ============================================================
-- 11. 清理
-- ============================================================
DROP TABLE IF EXISTS tutorial.mergetree_demo;
DROP TABLE IF EXISTS tutorial.replacing_demo;
DROP TABLE IF EXISTS tutorial.summing_demo;
DROP TABLE IF EXISTS tutorial.aggregating_demo;
DROP TABLE IF EXISTS tutorial.collapsing_demo;
DROP TABLE IF EXISTS tutorial.ttl_demo;

-- =====================================================
-- 本章小结
-- =====================================================
-- 1. MergeTree 数据按 Part 存储, Part 不可变, 后台合并
-- 2. Part 名: partition_min_block_max_block_level_mutation
-- 3. Part 爆炸根因: 小写入 + 细分区; 修复: 攒批 + 改粗分区
-- 4. OPTIMIZE FINAL 强制合并, 生产慎用
-- 5. 主键 = ORDER BY, 稀疏索引每 8192 行一个 mark, 不保证唯一
-- 6. 分区剪枝跳过无关分区, 比主键索引更早执行
-- 7. 5 种变体: Replacing(去重)/Summing(求和)/Aggregating(预聚合)/Collapsing(折叠)/Versioned
-- 8. 所有变体的特殊行为只在合并时发生, 查询时未必生效
-- 9. TTL 自动过期, 后台合并触发, 非实时
--
-- 下一步: 04_compression.md - 数据压缩和编码
-- =====================================================
