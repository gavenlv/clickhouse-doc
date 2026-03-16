-- =====================================================
-- 02 - ClickHouse 表设计最佳实践
-- =====================================================
-- 本文件深入讲解 ClickHouse 表设计的最佳实践
-- 包括主键设计、分区策略、数据类型选择等
-- =====================================================

-- -----------------------------------------------------
-- 1. 主键设计原则
-- -----------------------------------------------------

-- 
-- ┌─────────────────────────────────────────────────────────────┐
-- │              主键设计核心原则                                   │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                              │
-- │  原则 1: 高选择性列放前面                                      │
-- │  ┌─────────────────────────────────────────────────────┐   │
-- │  │                                                      │   │
-- │  │  选择性 = 不同值数量 / 总行数                        │   │
-- │  │                                                      │   │
-- │  │  例:                                                │   │
-- │  │  • user_id: 1,000,000 / 1,000,000,000 = 0.1%   │   │
-- │  │    → 高选择性 ✓                                     │   │
-- │  │                                                      │   │
-- │  │  • event_type: 10 / 1,000,000,000 = 0.000001%  │   │
-- │  │    → 低选择性                                       │   │
-- │  │                                                      │   │
-- │  │  • event_date: 365 / 1,000,000,000 = 0.00004%   │   │
-- │  │    → 低选择性                                       │   │
-- │  │                                                      │   │
-- │  └─────────────────────────────────────────────────────┘   │
-- │                                                              │
-- │  原则 2: 匹配查询模式                                         │
-- │  ┌─────────────────────────────────────────────────────┐   │
-- │  │                                                      │   │
-- │  │  常见 WHERE 条件: date = ? AND user_id = ?         │   │
-- │  │                                                      │   │
-- │  │  ✓ ORDER BY (date, user_id)  匹配等值查询         │   │
-- │  │  ✗ ORDER BY (user_id, date)  不匹配               │   │
-- │  │                                                      │   │
-- │  └─────────────────────────────────────────────────────┘   │
-- │                                                              │
-- │  原则 3: 避免主键过长                                         │
-- │  ┌─────────────────────────────────────────────────────┐   │
-- │  │                                                      │   │
-- │  │  ✗ ORDER BY (col1, col2, col3, col4, col5)       │   │
-- │  │  ✓ ORDER BY (col1, col2)  建议不超过 3-4 列     │   │
-- │  │                                                      │   │
-- │  └─────────────────────────────────────────────────────┘   │
-- │                                                              │
-- └─────────────────────────────────────────────────────────────┘

-- -----------------------------------------------------
-- 2. 主键设计演示
-- -----------------------------------------------------

-- 使用 playground 数据库
CREATE DATABASE IF NOT EXISTS playground ON CLUSTER treasurycluster;
USE playground;

-- 2.1 Good vs Bad 主键对比
--
-- Bad Practice: 低选择性列放前面
DROP TABLE IF EXISTS bad_primary_key ON CLUSTER treasurycluster SYNC;

CREATE TABLE bad_primary_key ON CLUSTER treasurycluster (
    event_type String,
    event_date Date,
    user_id UInt32,
    id UInt64
) ENGINE = ReplicatedMergeTree()
ORDER BY (event_type, event_date, user_id);

-- Good Practice: 高选择性列放前面
DROP TABLE IF EXISTS good_primary_key ON CLUSTER treasurycluster SYNC;

CREATE TABLE good_primary_key ON CLUSTER treasurycluster (
    event_type String,
    event_date Date,
    user_id UInt32,
    id UInt64
) ENGINE = ReplicatedMergeTree()
ORDER BY (user_id, event_date, event_type);

-- 插入测试数据
INSERT INTO bad_primary_key
SELECT 
    ['click', 'view', 'purchase', 'login'][number % 4 + 1],
    toDate('2024-01-01') + (number % 365),
    number % 100000,
    number
FROM numbers(1000000);

INSERT INTO good_primary_key
SELECT * FROM bad_primary_key;

-- 对比查询性能
SET max_threads = 1;

-- 查询: WHERE user_id = 12345
EXPLAIN PLAN
SELECT count() FROM bad_primary_key
WHERE user_id = 12345;

EXPLAIN PLAN
SELECT count() FROM good_primary_key
WHERE user_id = 12345;

-- -----------------------------------------------------
-- 3. 分区策略
-- -----------------------------------------------------

-- 
-- ┌─────────────────────────────────────────────────────────────┐
-- │              分区策略选择                                       │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                              │
-- │  按时间分区:                                                  │
-- │  ┌─────────────────────────────────────────────────────┐   │
-- │  │  PARTITION BY toYYYYMM(date)                       │   │
-- │  │                                                      │   │
-- │  │  优点: 易于管理, 按时间清理方便                     │   │
-- │  │  适用: 时序数据, 日志数据                         │   │
-- │  │                                                      │   │
-- │  │  注意: 不要过细 (按天分区数据量太小时)             │   │
-- │  └─────────────────────────────────────────────────────┘   │
-- │                                                              │
-- │  按业务分区:                                                  │
-- │  ┌─────────────────────────────────────────────────────┐   │
-- │  │  PARTITION BY (tenant_id % 10)                     │   │
-- │  │                                                      │   │
-- │  │  优点: 支持多租户隔离                              │   │
-- │  │  适用: SaaS 应用, 多租户系统                      │   │
-- │  │                                                      │   │
-- │  │  注意: 避免过多分区                                │   │
-- │  └─────────────────────────────────────────────────────┘   │
-- │                                                              │
-- │  不分区:                                                     │
-- │  ┌─────────────────────────────────────────────────────┐   │
-- │  │  无 PARTITION BY                                   │   │
-- │  │                                                      │   │
-- │  │  适用: 小数据量, 无时间属性                       │   │
-- │  │                                                      │   │
-- │  └─────────────────────────────────────────────────────┘   │
-- │                                                              │
-- └─────────────────────────────────────────────────────────────┘

-- 3.1 分区演示
--
-- 过细分区 (Bad Practice)
DROP TABLE IF EXISTS over_partitioned ON CLUSTER treasurycluster SYNC;

CREATE TABLE over_partitioned ON CLUSTER treasurycluster (
    id UInt64,
    event_date DateTime,
    value Float64
) ENGINE = ReplicatedMergeTree()
PARTITION BY toYYYYMMDD(event_date)  -- 每天一个分区
ORDER BY id;

-- 适当分区 (Good Practice)
DROP TABLE IF EXISTS proper_partitioned ON CLUSTER treasurycluster SYNC;

CREATE TABLE proper_partitioned ON CLUSTER treasurycluster (
    id UInt64,
    event_date DateTime,
    value Float64
) ENGINE = ReplicatedMergeTree()
PARTITION BY toYYYYMM(event_date)  -- 每月一个分区
ORDER BY id;

-- 查看分区数量对比
INSERT INTO over_partitioned
SELECT number, toDateTime('2024-01-01') + number * 3600, rand() / 100.0
FROM numbers(100000);

INSERT INTO proper_partitioned
SELECT * FROM over_partitioned;

SELECT 
    'over_partitioned' AS table_name,
    count(DISTINCT partition) AS partition_count
FROM system.parts
WHERE database = 'playground' AND table = 'over_partitioned' AND active = 1
UNION ALL
SELECT 
    'proper_partitioned' AS table_name,
    count(DISTINCT partition) AS partition_count
FROM system.parts
WHERE database = 'playground' AND table = 'proper_partitioned' AND active = 1;

-- -----------------------------------------------------
-- 4. 数据类型选择
-- -----------------------------------------------------

-- 
-- ┌─────────────────────────────────────────────────────────────┐
-- │              数据类型最佳实践                                    │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                              │
-- │  数值类型:                                                   │
-- │  ┌─────────────────────────────────────────────────────┐   │
-- │  │  ✗ 使用 String 存储数值                            │   │
-- │  │  ✓ 使用 Int32/Int64/Float64                       │   │
-- │  │                                                      │   │
-- │  │  String: 8+ 字节/值                               │   │
-- │  │  Int32: 4 字节/值                                 │   │
-- │  │  Int64: 8 字节/值                                 │   │
-- │  └─────────────────────────────────────────────────────┘   │
-- │                                                              │
-- │  日期时间:                                                   │
-- │  ┌─────────────────────────────────────────────────────┐   │
-- │  │  ✗ 使用 String 存储日期                           │   │
-- │  │  ✓ 使用 Date/DateTime/DateTime64                 │   │
-- │  │                                                      │   │
-- │  │  String: 10+ 字节                                 │   │
-- │  │  Date: 2 字节                                      │   │
-- │  │  DateTime: 4 字节                                 │   │
-- │  │  DateTime64: 8 字节                               │   │
-- │  └─────────────────────────────────────────────────────┘   │
-- │                                                              │
-- │  枚举类型:                                                   │
-- │  ┌─────────────────────────────────────────────────────┐   │
-- │  │  ✗ 使用 String 存储固定枚举值                     │   │
-- │  │  ✓ 使用 Enum8/Enum16                             │   │
-- │  │                                                      │   │
-- │  │  String: 可变长度                                  │   │
-- │  │  Enum8: 1 字节                                    │   │
-- │  └─────────────────────────────────────────────────────┘   │
-- │                                                              │
-- │  低基数:                                                     │
-- │  ┌─────────────────────────────────────────────────────┐   │
-- │  │  ✗ String 列基数 < 10000                         │   │
-- │  │  ✓ 使用 LowCardinality(String)                   │   │
-- │  │                                                      │   │
-- │  │  内存节省: 5-10x                                  │   │
-- │  │  查询性能提升: 2-3x                               │   │
-- │  └─────────────────────────────────────────────────────┘   │
-- │                                                              │
-- └─────────────────────────────────────────────────────────────┘

-- 4.1 数据类型演示
--
-- Bad: 使用 String 存储日期
DROP TABLE IF EXISTS bad_date_type ON CLUSTER treasurycluster SYNC;

CREATE TABLE bad_date_type ON CLUSTER treasurycluster (
    id UInt64,
    event_date String,  -- String 类型
    value Float64
) ENGINE = ReplicatedMergeTree()
ORDER BY id;

-- Good: 使用 Date 类型
DROP TABLE IF EXISTS good_date_type ON CLUSTER treasurycluster SYNC;

CREATE TABLE good_date_type ON CLUSTER treasurycluster (
    id UInt64,
    event_date Date,  -- Date 类型
    value Float64
) ENGINE = ReplicatedMergeTree()
ORDER BY id;

-- 插入测试数据
INSERT INTO bad_date_type
SELECT number, toString(toDate('2024-01-01') + (number % 365)), rand() / 100.0
FROM numbers(100000);

INSERT INTO good_date_type
SELECT number, toDate('2024-01-01') + (number % 365), rand() / 100.0
FROM numbers(100000);

-- 对比存储大小
SELECT 
    'String' AS type,
    formatReadableSize(sum(compressed_size)) AS compressed
FROM system.parts_columns
WHERE database = 'playground' AND table = 'bad_date_type' AND column = 'event_date' AND active = 1
UNION ALL
SELECT 
    'Date' AS type,
    formatReadableSize(sum(compressed_size)) AS compressed
FROM system.parts_columns
WHERE database = 'playground' AND table = 'good_date_type' AND column = 'event_date' AND active = 1;

-- 4.2 LowCardinality 演示
--
-- 普通 String
DROP TABLE IF EXISTS normal_string ON CLUSTER treasurycluster SYNC;

CREATE TABLE normal_string ON CLUSTER treasurycluster (
    id UInt64,
    category String
) ENGINE = ReplicatedMergeTree()
ORDER BY id;

-- LowCardinality
DROP TABLE IF EXISTS low_cardinality ON CLUSTER treasurycluster SYNC;

CREATE TABLE low_cardinality ON CLUSTER treasurycluster (
    id UInt64,
    category LowCardinality(String)
) ENGINE = ReplicatedMergeTree()
ORDER BY id;

-- 插入数据 (重复的 category)
INSERT INTO normal_string
SELECT number, ['Electronics', 'Books', 'Clothing', 'Food', 'Home'][number % 5 + 1]
FROM numbers(1000000);

INSERT INTO low_cardinality
SELECT * FROM normal_string;

-- 对比存储
SELECT 
    table,
    column,
    formatReadableSize(sum(compressed_size)) AS compressed,
    formatReadableSize(sum(data_uncompressed_bytes)) AS uncompressed
FROM system.parts_columns
WHERE database = 'playground' 
  AND table IN ('normal_string', 'low_cardinality')
  AND column = 'category'
  AND active = 1
GROUP BY table, column;

-- -----------------------------------------------------
-- 5. 排序键 vs 主键
-- -----------------------------------------------------

-- 
-- ┌─────────────────────────────────────────────────────────────┐
-- │              ORDER BY vs PRIMARY KEY                           │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                              │
-- │  ClickHouse 中:                                              │
-- │  ┌─────────────────────────────────────────────────────┐   │
-- │  │  ORDER BY = 主键 (在 MergeTree 中)                 │   │
-- │  │                                                      │   │
-- │  │  物理存储: 数据按 ORDER BY 顺序排列                 │   │
-- │  │  索引: primary.idx 基于 ORDER BY 列构建            │   │
-- │  │                                                      │   │
-- │  └─────────────────────────────────────────────────────┘   │
-- │                                                              │
-- │  与 MySQL/PostgreSQL 的区别:                                │
-- │  ┌─────────────────────────────────────────────────────┐   │
-- │  │  MySQL: PRIMARY KEY 是索引, InnoDB 组织数据       │   │
-- │  │  ClickHouse: ORDER BY 定义数据物理顺序             │   │
-- │  │                                                      │   │
-- │  │  ✓ ClickHouse 不需要单独的主键索引                │   │
-- │  │  ✓ 索引和存储一体                                 │   │
-- │  └─────────────────────────────────────────────────────┘   │
-- │                                                              │
-- └─────────────────────────────────────────────────────────────┘

-- -----------------------------------------------------
-- 6. 表引擎选择
-- -----------------------------------------------------

-- 
-- ┌─────────────────────────────────────────────────────────────┐
-- │              表引擎选择指南                                      │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                              │
-- │  MergeTree 系列 (默认选择):                                   │
-- │  ┌─────────────────────────────────────────────────────┐   │
-- │  │  • MergeTree: 标准表引擎, 适用于大多数场景          │   │
-- │  │  • ReplicatedMergeTree: 支持复制                    │   │
-- │  │  • ReplacingMergeTree: 自动去重                     │   │
-- │  │  • SummingMergeTree: 自动聚合                      │   │
-- │  │  • AggregatingMergeTree: 物化视图                  │   │
-- │  │  • CollapsingMergeTree: 增量更新                  │   │
-- │  └─────────────────────────────────────────────────────┘   │
-- │                                                              │
-- │  其他引擎:                                                    │
-- │  ┌─────────────────────────────────────────────────────┐   │
-- │  │  • Distributed: 分布式表                             │   │
-- │  │  • MaterializedView: 物化视图                       │   │
-- │  │  • Buffer: 写入缓冲                                │   │
-- │  │  • Memory: 内存表                                  │   │
-- │  │  • Null: 空表                                       │   │
-- │  └─────────────────────────────────────────────────────┘   │
-- │                                                              │
-- └─────────────────────────────────────────────────────────────┘

-- -----------------------------------------------------
-- 6.1 分片键选择原则
-- -----------------------------------------------------

-- 
-- ┌─────────────────────────────────────────────────────────────┐
-- │              分片键选择核心原则                                   │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                              │
-- │  什么是分片键?                                               │
-- ┌─────────────────────────────────────────────────────────────┐   │
-- │  分片键决定数据写入哪个分片                                    │
-- │                                                              │
-- │  sharding_key = hash(列值) % 分片数量                         │
-- │                                                              │
-- │  例: 3 个分片, user_id=1 → hash%3=1 → Shard 2              │
-- │                                                              │
-- └─────────────────────────────────────────────────────────────┘
-- │                                                              │
-- │  原则 1: 查询局部性                                            │
-- │  ┌─────────────────────────────────────────────────────┐   │
-- │  │  相同查询条件的数据应在同一分片                       │   │
-- │  │                                                      │   │
-- │  │  ✓ SELECT * FROM table WHERE user_id = 123        │   │
-- │  │    → user_id=123 都在 Shard X                     │   │
-- │  │    → 只查一个分片                                   │   │
-- │  │                                                      │   │
-- │  │  ✗ SELECT * FROM table WHERE date = '2024-01-01' │   │
-- │  │    → 可能分布在所有分片                             │   │
-- │  └─────────────────────────────────────────────────────┘   │
-- │                                                              │
-- │  原则 2: 数据均匀分布                                          │
-- │  ┌─────────────────────────────────────────────────────┐   │
-- │  │  避免数据倾斜                                        │   │
-- │  │                                                      │   │
-- │  │  ✗ 按省份分片: 80%数据在北上广                     │   │
-- │  │  ✓ 哈希分片: 均匀分布                              │   │
-- │  │                                                      │   │
-- │  │  ✓ 复合分片: intHash64(user_id % 100)             │   │
-- │  └─────────────────────────────────────────────────────┘   │
-- │                                                              │
-- │  原则 3: 避免跨分片 JOIN                                       │
-- │  ┌─────────────────────────────────────────────────────┐   │
-- │  │  JOIN 的表应使用相同的分片键                         │   │
-- │  │                                                      │   │
-- │  │  ✓ users 和 orders 使用相同分片键                  │   │
-- │  │    → JOIN 在分片内完成                             │   │
-- │  │                                                      │   │
-- │  │  ✗ users 按 user_id, orders 按 order_id           │   │
-- │  │    → 跨分片 JOIN,性能差                           │   │
-- │  └─────────────────────────────────────────────────────┘   │
-- │                                                              │
-- └─────────────────────────────────────────────────────────────┘

-- 6.2 分片键类型对比
--
-- ┌─────────────────────────────────────────────────────────────┐
-- │              分片键类型对比                                       │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                              │
-- │  随机分片:                                                   │
-- │  ┌─────────────────────────────────────────────────────┐   │
-- │  │  ENGINE = Distributed(cluster, db, table, rand()) │   │
-- │  │                                                      │   │
-- │  │  优点: 数据绝对均匀                                 │   │
-- │  │  缺点: 无法局部查询,所有分片都要扫描              │   │
-- │  │  适用: 全表聚合查询,无特定查询模式                │   │
-- │  └─────────────────────────────────────────────────────┘   │
-- │                                                              │
-- │  哈希分片:                                                   │
-- │  ┌─────────────────────────────────────────────────────┐   │
-- │  │  ENGINE = Distributed(cluster, db, table,         │   │
-- │  │                              sipHash64(user_id))  │   │
-- │  │                                                      │   │
-- │  │  优点: 支持局部查询                                 │   │
-- │  │  缺点: 可能热点(热点用户)                          │   │
-- │  │  适用: 用户行为分析,按用户查询                    │   │
-- │  └─────────────────────────────────────────────────────┘   │
-- │                                                              │
-- │  日期分片:                                                   │
-- │  ┌─────────────────────────────────────────────────────┐   │
-- │  │  ENGINE = Distributed(cluster, db, table,         │   │
-- │  │                              toYYYYMM(event_date))│   │
-- │  │                                                      │   │
-- │  │  优点: 时间范围查询局部化                          │   │
-- │  │  缺点: 数据倾斜(近期数据多)                       │   │
-- │  │  适用: 时序数据,按时间范围查询                   │   │
-- │  └─────────────────────────────────────────────────────┘   │
-- │                                                              │
-- │  复合分片:                                                   │
-- │  ┌─────────────────────────────────────────────────────┐   │
-- │  │  ENGINE = Distributed(cluster, db, table,         │   │
-- │  │        sipHash64(tenant_id, user_id))            │   │
-- │  │                                                      │   │
-- │  │  优点: 平衡分布和局部性                           │   │
-- │  │  缺点: 配置复杂                                   │   │
-- │  │  适用: 多租户应用                                 │   │
-- │  └─────────────────────────────────────────────────────┘   │
-- │                                                              │
-- └─────────────────────────────────────────────────────────────┘

-- 6.3 分片键选择示例
--
-- ┌─────────────────────────────────────────────────────────────┐
-- │              分片键选择场景分析                                   │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                              │
-- │  场景 1: 用户行为分析                                          │
-- │  ┌─────────────────────────────────────────────────────┐   │
-- │  │  查询模式:                                          │   │
-- │  │  • SELECT * FROM events WHERE user_id = ?        │   │
-- │  │  • SELECT * FROM events WHERE session_id = ?     │   │
-- │  │                                                      │   │
-- │  │  ✓ 推荐: sipHash64(user_id)                       │   │
-- │  │  理由: user_id 查询最频繁,同一用户数据在一起     │   │
-- │  └─────────────────────────────────────────────────────┘   │
-- │                                                              │
-- │  场景 2: 电商订单分析                                          │
-- │  ┌─────────────────────────────────────────────────────┐   │
-- │  │  查询模式:                                          │   │
-- │  │  • SELECT * FROM orders WHERE date = ?           │   │
-- │  │  • SELECT * FROM orders WHERE user_id = ?        │   │
-- │  │                                                      │   │
-- │  │  ✓ 推荐: sipHash64(user_id)                       │   │
-- │  │  理由: 用户查询更普遍,避免跨分片 JOIN            │   │
-- │  └─────────────────────────────────────────────────────┘   │
-- │                                                              │
-- │  场景 3: IoT 时序数据                                          │
-- │  ┌─────────────────────────────────────────────────────┐   │
-- │  │  查询模式:                                          │   │
-- │  │  • SELECT * FROM sensor_data                      │   │
-- │  │    WHERE timestamp BETWEEN ? AND ?                │   │
-- │  │  • SELECT * FROM sensor_data WHERE device_id = ? │   │
-- │  │                                                      │   │
-- │  │  ✓ 推荐: toYYYYMM(timestamp) 或 sipHash64(device_id)│   │
-- │  │  理由: 时间范围查询普遍,但也要支持设备查询      │   │
-- │  └─────────────────────────────────────────────────────┘   │
-- │                                                              │
-- │  场景 4: 多租户 SaaS                                           │
-- │  ┌─────────────────────────────────────────────────────┐   │
-- │  │  查询模式:                                          │   │
-- │  │  • SELECT * FROM data WHERE tenant_id = ?        │   │
-- │  │  • JOIN user_tables                                │   │
-- │  │                                                      │   │
-- │  │  ✓ 推荐: sipHash64(tenant_id)                     │   │
-- │  │  理由: 租户隔离,同一租户数据在一起               │   │
-- │  └─────────────────────────────────────────────────────┘   │
-- │                                                              │
-- └─────────────────────────────────────────────────────────────┘

-- -----------------------------------------------------
-- 7. 实战案例
-- -----------------------------------------------------

-- 7.1 事件日志表设计
--
-- ┌─────────────────────────────────────────────────────────────┐
-- │              事件日志表设计最佳实践                               │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                              │
-- │  业务需求:                                                   │
-- │  • 存储用户点击/浏览/购买事件                                │
-- │  • 按日期和用户查询                                         │
-- │  • 支持多租户                                               │
-- │  • 需要自动去重 (同一批次可能重复)                          │   │
-- │                                                              │
-- │  最佳设计:                                                   │
-- │  ┌─────────────────────────────────────────────────────┐   │
-- │  │  CREATE TABLE events (                             │   │
-- │  │      event_id UInt64,                             │   │
-- │  │      tenant_id UInt16,                            │   │
-- │  │      user_id UInt32,                              │   │
-- │  │      event_type Enum8('click'=1, 'view'=2...),  │   │
-- │  │      event_time DateTime64(3),                    │   │
-- │  │      page_url String,                              │   │
-- │  │      metadata JSON                                 │   │
-- │  │  ) ENGINE = ReplacingMergeTree(event_id)         │   │
-- │  │  PARTITION BY toYYYYMM(event_time)               │   │
-- │  │  ORDER BY (tenant_id, user_id, event_time);     │   │
-- │  └─────────────────────────────────────────────────────┘   │
-- │                                                              │
-- └─────────────────────────────────────────────────────────────┘

-- 创建事件日志表
DROP TABLE IF EXISTS events ON CLUSTER treasurycluster SYNC;

CREATE TABLE events ON CLUSTER treasurycluster (
    event_id UInt64,
    tenant_id UInt16,
    user_id UInt32,
    event_type Enum8('click' = 1, 'view' = 2, 'purchase' = 3, 'login' = 4),
    event_time DateTime64(3),
    page_url String,
    metadata String
) ENGINE = ReplicatedReplacingMergeTree(event_id)
PARTITION BY toYYYYMM(event_time)
ORDER BY (tenant_id, user_id, event_time)
SETTINGS index_granularity = 8192;

-- 插入测试数据
INSERT INTO events
SELECT 
    number,
    number % 100,
    number % 100000,
    CAST(number % 4 + 1 AS Enum8('click' = 1, 'view' = 2, 'purchase' = 3, 'login' = 4)),
    toDateTime64('2024-01-01', 3) + number * 60,
    '/page/' || (number % 1000),
    '{"ref": "direct"}'
FROM numbers(100000);

-- 查看表结构
DESCRIBE TABLE events;

-- -----------------------------------------------------
-- 8. 清理
-- -----------------------------------------------------

DROP TABLE IF EXISTS bad_primary_key ON CLUSTER treasurycluster SYNC;
DROP TABLE IF EXISTS good_primary_key ON CLUSTER treasurycluster SYNC;
DROP TABLE IF EXISTS over_partitioned ON CLUSTER treasurycluster SYNC;
DROP TABLE IF EXISTS proper_partitioned ON CLUSTER treasurycluster SYNC;
DROP TABLE IF EXISTS bad_date_type ON CLUSTER treasurycluster SYNC;
DROP TABLE IF EXISTS good_date_type ON CLUSTER treasurycluster SYNC;
DROP TABLE IF EXISTS normal_string ON CLUSTER treasurycluster SYNC;
DROP TABLE IF EXISTS low_cardinality ON CLUSTER treasurycluster SYNC;
DROP TABLE IF EXISTS events ON CLUSTER treasurycluster SYNC;

-- =====================================================
-- 本章小结
-- =====================================================
--
-- 表设计最佳实践:
-- 1. 主键: 高选择性列放前面, 匹配查询模式
-- 2. 分区: 按时间或业务分区, 避免过细
-- 3. 数据类型: 使用合适的类型, 避免 String
-- 4. LowCardinality: 基数 < 10000 时使用
-- 5. 表引擎: 根据业务需求选择合适的引擎
--
-- 下一步: 03_query_optimization.sql - 查询优化
-- =====================================================
