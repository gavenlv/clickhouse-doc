-- =====================================================
-- 03 - MergeTree 引擎核心原理
-- =====================================================
-- 集群: treasurycluster (2副本)
-- 时间: 35-45分钟
-- =====================================================

-- -----------------------------------------------------
-- 1. MergeTree 家族概览
-- -----------------------------------------------------

-- 
-- ┌─────────────────────────────────────────────────────────────┐
-- │              MergeTree 引擎家族                              │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                             │
-- │  【MergeTree 系列】不支持副本 (单节点)                       │
-- │  ├── MergeTree (核心基础)                                   │
-- │  ├── SummingMergeTree - 自动聚合相同键                      │
-- │  ├── AggregatingMergeTree - 预聚合                          │
-- │  ├── CollapsingMergeTree - 删除标记折叠                    │
-- │  ├── VersionedCollapsingMergeTree - 版本控制折叠            │
-- │  ├── ReplacingMergeTree - 版本号替换                        │
-- │  ├── VersionedReplacingMergeTree - 版本替换                 │
-- │  └── GraphiteMergeTree - Graphite 数据优化                │
-- │                                                             │
-- │  【ReplicatedMergeTree 系列】支持副本 (集群环境)              │
-- │  ├── ReplicatedMergeTree - 支持副本复制                     │
-- │  ├── ReplicatedSummingMergeTree - 副本+自动聚合              │
-- │  ├── ReplicatedAggregatingMergeTree - 副本+预聚合           │
-- │  ├── ReplicatedCollapsingMergeTree - 副本+删除标记折叠      │
-- │  ├── ReplicatedVersionedCollapsingMergeTree - 副本+版本折叠 │
-- │  ├── ReplicatedReplacingMergeTree - 副本+版本替换           │
-- │  ├── ReplicatedVersionedReplacingMergeTree - 副本+版本替换  │
-- │  └── ReplicatedGraphiteMergeTree - 副本+Graphite 优化       │
-- │                                                             │
-- │  区别:                                                       │
-- │  - Replicated* 系列需要 ZooKeeper                          │
-- │  - Replicated* 系列支持多副本高可用                          │
-- │  - Replicated* 系列用于生产环境集群                          │
-- │                                                             │
-- └─────────────────────────────────────────────────────────────┘

-- 查看 MergeTree 系列引擎
SELECT name FROM system.table_engines 
WHERE name LIKE '%MergeTree%';

-- -----------------------------------------------------
-- 2. MergeTree 核心概念
-- -----------------------------------------------------

-- 
-- ┌─────────────────────────────────────────────────────────────┐
-- │              MergeTree 核心概念                              │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                             │
-- │  ORDER BY (必须):                                           │
-- │  - 决定数据物理存储顺序                                      │
-- │  - 影响索引结构                                              │
-- │  - 建议: 将高频过滤列放前面                                  │
-- │                                                             │
-- │  PARTITION BY (可选):                                        │
-- │  - 数据分区粒度                                              │
-- │  - 常用: toYYYYMM, toYYYYMMDD, toYYYYMMDDhhmmss           │
-- │  - 影响分区裁剪效率                                          │
-- │                                                             │
-- │  PRIMARY KEY (可选):                                        │
-- │  - 默认等于 ORDER BY                                         │
-- │  - 可以独立设置不同顺序                                      │
-- │                                                             │
-- │  SAMPLE BY (可选):                                          │
-- │  - 数据采样键                                                │
-- │  - 支持 SAMPLE 1000000 查询                                 │
-- │                                                             │
-- │  SETTINGS:                                                  │
-- │  - index_granularity: 8192 (默认)                          │
-- │  - min_bytes_for_wide_part: 需设置启用 wide 格式          │
-- │                                                             │
-- └─────────────────────────────────────────────────────────────┘

-- -----------------------------------------------------
-- 3. 数据写入与 Part 文件
-- -----------------------------------------------------

-- 使用 playground 数据库
USE playground;

-- 创建演示表 (Replicated)
DROP TABLE IF EXISTS events ON CLUSTER treasurycluster SYNC;

CREATE TABLE events ON CLUSTER treasurycluster (
    event_id UInt64,
    user_id UInt32,
    event_time DateTime,
    event_type String,
    payload String
) ENGINE = ReplicatedMergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_type, user_id, event_time)
SETTINGS index_granularity = 8192;

-- 分批插入数据，模拟生成多个 parts
INSERT INTO events 
SELECT 
    number AS event_id,
    number % 1000 AS user_id,
    toDateTime('2024-01-01 00:00:00') + number * 60 AS event_time,
    ['click', 'view', 'purchase'][number % 3 + 1] AS event_type,
    repeat('data_', 100)
FROM numbers(10000);

INSERT INTO events 
SELECT 
    number + 10000 AS event_id,
    number % 1000 AS user_id,
    toDateTime('2024-01-01 00:00:00') + number * 60 AS event_time,
    ['click', 'view', 'purchase'][number % 3 + 1] AS event_type,
    repeat('data_', 100)
FROM numbers(10000);

INSERT INTO events 
SELECT 
    number + 20000 AS event_id,
    number % 1000 AS user_id,
    toDateTime('2024-01-01 00:00:00') + number * 60 AS event_time,
    ['click', 'view', 'purchase'][number % 3 + 1] AS event_type,
    repeat('data_', 100)
FROM numbers(10000);

-- 查看生成的 parts
SELECT 
    partition,
    name AS part_name,
    rows,
    formatReadableSize(bytes) AS size,
    level,
    active
FROM system.parts
WHERE database = 'playground' AND table = 'events' AND active = 1
ORDER BY partition, name;

-- 
-- ┌─────────────────────────────────────────────────────────────┐
-- │              Part 文件结构                                   │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                             │
-- │  part_1_3_0/                                                │
-- │  ├── checksums.txt      ← 校验和                            │
-- │  ├── columns.txt        ← 列信息                            │
-- │  ├── count.txt          ← 行数                              │
-- │  ├── primary.idx        ← 主键索引                          │
-- │  ├── event_id.bin      ← 数据文件                          │
-- │  ├── event_id.mrk2      ← 标记文件                          │
-- │  ├── user_id.bin                                            │
-- │  ├── user_id.mrk2                                           │
-- │  ├── event_time.bin                                        │
-- │  ├── event_time.mrk2                                        │
-- │  ├── event_type.bin                                        │
-- │  ├── event_type.mrk2                                       │
-- │  ├── payload.bin                                           │
-- │  └── payload.mrk2                                          │
-- │                                                             │
-- │  .bin = 压缩的列数据                                        │
-- │  .mrk2 = 索引标记文件 (映射到 .bin 的位置)                  │
-- │                                                             │
-- └─────────────────────────────────────────────────────────────┘

-- -----------------------------------------------------
-- 4. 后台合并演示
-- -----------------------------------------------------

-- 手动触发合并
OPTIMIZE TABLE events FINAL;

-- 再次查看 parts
SELECT 
    partition,
    name AS part_name,
    rows,
    formatReadableSize(bytes) AS size,
    level,
    active
FROM system.parts
WHERE database = 'playground' AND table = 'events'
ORDER BY partition, name;

-- 
-- ┌─────────────────────────────────────────────────────────────┐
-- │              合并前后对比                                     │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                             │
-- │  合并前 (3个 parts):                                        │
-- │  ┌─────────────────────────────────────────────────────┐   │
-- │  │ Part_1_1_0  (10K rows)                              │   │
-- │  │ Part_2_1_0  (10K rows)                              │   │
-- │  │ Part_3_1_0  (10K rows)                              │   │
-- │  └─────────────────────────────────────────────────────┘   │
-- │                                                             │
-- │  合并后 (1个 part):                                         │
-- │  ┌─────────────────────────────────────────────────────┐   │
-- │  │ Part_1_3_1  (30K rows)                              │   │
-- │  └─────────────────────────────────────────────────────┘   │
-- │                                                             │
-- │  好处:                                                      │
-- │  - 减少文件数量                                             │
-- │  - 提升扫描效率                                             │
-- │  - 释放磁盘空间                                             │
-- │                                                             │
-- └─────────────────────────────────────────────────────────────┘

-- -----------------------------------------------------
-- 5. 主键选择原则
-- -----------------------------------------------------

-- 
-- ┌─────────────────────────────────────────────────────────────┐
-- │              主键选择最佳实践                                 │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                             │
-- │  原则 1: 高基数字段放前面                                    │
-- │  ┌─────────────────────────────────────────────────────┐   │
-- │  │  低基数: [A,A,A,B,B,B] → 筛选效果差                 │   │
-- │  │  高基数: [1,2,3,4,5,6] → 筛选效果好                │   │
-- │  └─────────────────────────────────────────────────────┘   │
-- │                                                             │
-- │  原则 2: 过滤频率高的列放前面                               │
-- │  - WHERE 子句中常用的列                                      │
-- │                                                             │
-- │  原则 3: 避免使用随机值作为主键                             │
-- │  - 会导致写入时大量 merge                                   │
-- │                                                             │
-- │  原则 4: 复合主键不要超过 3-4 个                            │
-- │  - 索引文件会变大                                           │
-- │                                                             │
-- └─────────────────────────────────────────────────────────────┘

-- 创建不同主键的表进行对比 (Replicated)
DROP TABLE IF EXISTS good_key ON CLUSTER treasurycluster SYNC;

CREATE TABLE good_key (
    event_time DateTime,
    user_id UInt32,
    event_type String,
    value Float64
) ENGINE = ReplicatedMergeTree()
ORDER BY (event_type, user_id, event_time);

DROP TABLE IF EXISTS bad_key ON CLUSTER treasurycluster SYNC;

CREATE TABLE bad_key (
    event_time DateTime,
    user_id UInt32,
    event_type String,
    value Float64
) ENGINE = ReplicatedMergeTree()
ORDER BY (event_time, value, user_id);

-- 插入相同数据
INSERT INTO good_key
SELECT 
    now() + number * 60 AS event_time,
    number % 10000 AS user_id,
    ['A', 'B', 'C'][number % 3 + 1] AS event_type,
    rand() AS value
FROM numbers(100000);

INSERT INTO bad_key
SELECT 
    now() + number * 60 AS event_time,
    number % 10000 AS user_id,
    ['A', 'B', 'C'][number % 3 + 1] AS event_type,
    rand() AS value
FROM numbers(100000);

-- 对比查询性能
SET max_threads = 1;

SELECT count() FROM good_key WHERE event_type = 'A';
SELECT count() FROM bad_key WHERE event_type = 'A';

-- 查看执行计划
EXPLAIN PLAN SELECT count() FROM good_key WHERE event_type = 'A';
EXPLAIN PLAN SELECT count() FROM bad_key WHERE event_type = 'A';

-- -----------------------------------------------------
-- 6. 分区策略
-- -----------------------------------------------------

-- 
-- ┌─────────────────────────────────────────────────────────────┐
-- │              分区策略选择                                     │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                             │
-- │  按天分区: toYYYYMMDD                                      │
-- │  ✓ 数据量大、需快速定位                                     │
-- │  ✓ 支持 DELETE 操作                                         │
-- │  ✗ Part 数量多                                             │
-- │                                                             │
-- │  按月分区: toYYYYMM                                        │
-- │  ✓ Part 数量适中                                           │
-- │  ✓ 适合历史数据分析                                         │
-- │  ✗ 粒度较粗                                                │
-- │                                                             │
-- │  不分区:                                                    │
-- │  ✓ 数据量小                                                 │
-- │  ✓ 避免跨分区查询                                           │
-- │  ✗ 无法分区裁剪                                             │
-- │                                                             │
-- │  建议:                                                      │
-- │  - 日志/时序数据: toYYYYMMDD                               │
-- │  - 历史归档数据: toYYYYMM                                   │
-- │  - 小表: 不分区                                            │
-- │                                                             │
-- └─────────────────────────────────────────────────────────────┘

-- 创建不同分区策略的表 (Replicated)
DROP TABLE IF EXISTS partition_by_day ON CLUSTER treasurycluster SYNC;
CREATE TABLE partition_by_day ON CLUSTER treasurycluster (
    id UInt64,
    created_at DateTime,
    data String
) ENGINE = ReplicatedMergeTree()
PARTITION BY toYYYYMMDD(created_at)
ORDER BY id;

DROP TABLE IF EXISTS partition_by_month ON CLUSTER treasurycluster SYNC;
CREATE TABLE partition_by_month ON CLUSTER treasurycluster (
    id UInt64,
    created_at DateTime,
    data String
) ENGINE = ReplicatedMergeTree()
PARTITION BY toYYYYMM(created_at)
ORDER BY id;

DROP TABLE IF EXISTS no_partition ON CLUSTER treasurycluster SYNC;
CREATE TABLE no_partition ON CLUSTER treasurycluster (
    id UInt64,
    created_at DateTime,
    data String
) ENGINE = ReplicatedMergeTree()
ORDER BY id;

-- 插入测试数据
INSERT INTO partition_by_day
SELECT number, toDateTime('2024-01-01') + number * 86400, 'data'
FROM numbers(100);

INSERT INTO partition_by_month
SELECT number, toDateTime('2024-01-01') + number * 86400, 'data'
FROM numbers(100);

INSERT INTO no_partition
SELECT number, toDateTime('2024-01-01') + number * 86400, 'data'
FROM numbers(100);

-- 对比 Part 数量
SELECT 
    'partition_by_day' AS table_name,
    count() AS parts
FROM system.parts WHERE database = 'playground' AND table = 'partition_by_day' AND active = 1
UNION ALL
SELECT 
    'partition_by_month' AS table_name,
    count() AS parts
FROM system.parts WHERE database = 'playground' AND table = 'partition_by_month' AND active = 1
UNION ALL
SELECT 
    'no_partition' AS table_name,
    count() AS parts
FROM system.parts WHERE database = 'playground' AND table = 'no_partition' AND active = 1;

-- -----------------------------------------------------
-- 7. MergeTree 变体
-- -----------------------------------------------------

-- SummingMergeTree: 自动聚合 (Replicated)
DROP TABLE IF EXISTS summing_demo ON CLUSTER treasurycluster SYNC;

CREATE TABLE summing_demo ON CLUSTER treasurycluster (
    date Date,
    user_id UInt32,
    revenue Float64,
    count UInt32
) ENGINE = ReplicatedSummingMergeTree()
PARTITION BY toYYYYMM(date)
ORDER BY (date, user_id);

INSERT INTO summing_demo VALUES 
    ('2024-01-01', 1, 100, 1),
    ('2024-01-01', 1, 200, 1),
    ('2024-01-01', 2, 150, 1);

-- 触发合并后查看结果
OPTIMIZE TABLE summing_demo FINAL;

SELECT * FROM summing_demo;

-- AggregatingMergeTree: 预聚合 (Replicated)
DROP TABLE IF EXISTS agg_demo ON CLUSTER treasurycluster SYNC;

CREATE TABLE agg_demo ON CLUSTER treasurycluster (
    date Date,
    user_id UInt32,
    revenue SimpleAggregateFunction(sum, Float64)
) ENGINE = ReplicatedAggregatingMergeTree()
PARTITION BY toYYYYMM(date)
ORDER BY (date, user_id);

INSERT INTO agg_demo VALUES 
    ('2024-01-01', 1, 100),
    ('2024-01-01', 1, 200);

-- 使用物化视图实现预聚合 (Replicated)
-- 物化视图演示（需要单独创建目标表）
-- DROP MATERIALIZED VIEW IF EXISTS agg_view ON CLUSTER treasurycluster SYNC;
-- DROP TABLE IF EXISTS agg_mv_dest ON CLUSTER treasurycluster SYNC;

-- CREATE TABLE agg_mv_dest ON CLUSTER treasurycluster
-- ENGINE = ReplicatedSummingMergeTree()
-- PARTITION BY toYYYYMM(date)
-- ORDER BY (date, user_id) AS
-- SELECT 
--     toDate(event_time) AS date,
--     user_id,
--     sum(revenue) AS revenue
-- FROM events
-- WHERE event_type = 'purchase'
-- GROUP BY toDate(event_time), user_id;

-- -----------------------------------------------------
-- 8. 本章小结
-- -----------------------------------------------------

-- 
-- ┌─────────────────────────────────────────────────────────────┐
-- │              本章要点                                       │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                             │
-- │  1. MergeTree 是 ClickHouse 的核心存储引擎                 │
-- │  2. ORDER BY 必须指定，决定数据物理顺序                    │
-- │  3. PARTITION BY 影响查询性能和数据管理                    │
-- │  4. 后台自动合并优化存储                                   │
-- │  5. 主键选择: 高基数字段放前面，避免随机值                 │
-- │  6. 变体: SummingMergeTree, AggregatingMergeTree          │
-- │                                                             │
-- │  下一步: 04_query_optimization.sql - 查询优化技巧          │
-- │                                                             │
-- └─────────────────────────────────────────────────────────────┘

SELECT 
    'mergetree' AS chapter,
    (SELECT count() FROM system.parts WHERE database = 'playground') AS total_parts;
