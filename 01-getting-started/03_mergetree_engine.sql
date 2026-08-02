-- =====================================================
-- 03 - MergeTree 引擎家族
-- =====================================================
-- MergeTree 是 ClickHouse 最核心的表引擎
-- 本文件帮助你理解 MergeTree 的工作原理和关键概念
-- =====================================================

CREATE DATABASE IF NOT EXISTS tutorial;

-- -----------------------------------------------------
-- 1. 创建第一个 MergeTree 表
-- -----------------------------------------------------
-- MergeTree 是最基础的引擎，理解它是理解其他引擎的基础

CREATE TABLE IF NOT EXISTS tutorial.my_first_mergetree
(
    user_id UInt32,
    event_time DateTime,
    event_date Date,
    action String,
    value Float64
)
ENGINE = MergeTree()
-- ORDER BY: 排序键，决定数据在磁盘上的物理存储顺序
-- 也是默认的主键（primary key）
ORDER BY (event_date, user_id);

-- 插入一些测试数据
INSERT INTO tutorial.my_first_mergetree VALUES
(1, '2024-01-15 10:30:00', '2024-01-15', 'login', 1.0),
(2, '2024-01-15 11:00:00', '2024-01-15', 'click', 0.5),
(3, '2024-01-16 09:00:00', '2024-01-16', 'purchase', 100.0),
(4, '2024-01-16 14:30:00', '2024-01-16', 'logout', 0.0),
(5, '2024-01-17 08:00:00', '2024-01-17', 'login', 1.0);

-- 查询数据
SELECT * FROM tutorial.my_first_mergetree ORDER BY event_date, user_id;

-- -----------------------------------------------------
-- 2. 理解排序键（ORDER BY）
-- -----------------------------------------------------
-- 排序键是 MergeTree 最重要的概念

-- 排序键决定了：
-- 1. 数据在磁盘上的存储顺序
-- 2. 默认的主键（用于数据去重和索引）
-- 3. 查询时的数据裁剪能力

-- 创建不同排序键的表进行对比
CREATE TABLE IF NOT EXISTS tutorial.sort_key_demo
(
    user_id UInt32,
    event_time DateTime,
    event_type LowCardinality(String),
    page_url String,
    duration UInt32
)
ENGINE = MergeTree()
-- 好的排序键设计：最常用的过滤条件放在前面
ORDER BY (event_time, user_id);

-- 插入测试数据
INSERT INTO tutorial.sort_key_demo
SELECT 
    rand() % 10000 AS user_id,
    toDateTime('2024-01-01 00:00:00') + (rand() % 86400 * 30) AS event_time,
    ['page_view', 'click', 'scroll'][rand() % 3 + 1] AS event_type,
    '/page/' || toString(rand() % 100) AS page_url,
    rand() % 300 AS duration
FROM numbers(100000);

-- 查看排序键的效果
-- 这个查询会非常快，因为数据按 event_time 排序存储
SELECT 
    toStartOfHour(event_time) AS hour,
    count() AS events,
    avg(duration) AS avg_duration
FROM tutorial.sort_key_demo
WHERE event_time >= '2024-01-10 00:00:00' AND event_time < '2024-01-11 00:00:00'
GROUP BY hour
ORDER BY hour;

-- -----------------------------------------------------
-- 3. 理解分区（PARTITION BY）
-- -----------------------------------------------------
-- 分区是数据的逻辑分组，用于数据管理和查询优化

CREATE TABLE IF NOT EXISTS tutorial.partition_demo
(
    user_id UInt32,
    event_time DateTime,
    event_date Date,
    action String,
    value Float64
)
ENGINE = MergeTree()
ORDER BY (user_id, event_time)
-- PARTITION BY: 按月分区
PARTITION BY toYYYYMM(event_date);

-- 插入跨多个月份的数据
INSERT INTO tutorial.partition_demo
SELECT 
    rand() % 10000 AS user_id,
    toDateTime('2024-01-01 00:00:00') + (number * 3600) AS event_time,
    toDate('2024-01-01') + (number * 3600 / 86400) AS event_date,
    ['click', 'view', 'purchase'][rand() % 3 + 1] AS action,
    rand() % 1000 / 10.0 AS value
FROM numbers(10000);

-- 查看分区信息
SELECT 
    partition,
    name AS part_name,
    formatReadableSize(bytes_on_disk) AS size,
    rows,
    min_date,
    max_date
FROM system.parts
WHERE database = 'tutorial' AND table = 'partition_demo'
ORDER BY partition;

-- 分区裁剪效果
-- 这个查询只会扫描 2024-01 分区
EXPLAIN indexes=1
SELECT count()
FROM tutorial.partition_demo
WHERE event_date >= '2024-01-15' AND event_date < '2024-01-16';

-- -----------------------------------------------------
-- 4. 理解合并（Merge）机制
-- -----------------------------------------------------
-- MergeTree 会后台自动合并小的数据片段

-- 查看当前表的片段（parts）
SELECT 
    name,
    active,
    formatReadableSize(bytes_on_disk) AS size,
    rows,
    modification_time
FROM system.parts
WHERE database = 'tutorial' AND table = 'my_first_mergetree'
ORDER BY modification_time DESC;

-- 手动触发优化（可选，通常不需要）
-- OPTIMIZE TABLE tutorial.my_first_mergetree;

-- -----------------------------------------------------
-- 5. 主键索引原理
-- -----------------------------------------------------
-- 主键索引是稀疏索引，不是每一行都索引

-- 创建表并插入数据
CREATE TABLE IF NOT EXISTS tutorial.index_demo
(
    id UInt32,
    timestamp DateTime,
    value Float64,
    description String
)
ENGINE = MergeTree()
ORDER BY id;

-- 插入 100 万行数据
INSERT INTO tutorial.index_demo
SELECT 
    number AS id,
    now() - (rand() % 86400) AS timestamp,
    rand() / 1000000.0 AS value,
    'Description for record ' || toString(number) AS description
FROM numbers(1000000);

-- 查看索引粒度
-- index_granularity 默认是 8192，即每 8192 行创建一个索引标记
SELECT 
    name,
    marks,
    rows,
    marks * 8192 AS approx_index_coverage
FROM system.parts
WHERE database = 'tutorial' AND table = 'index_demo';

-- 使用主键查询
-- 这个查询会使用主键索引
EXPLAIN indexes=1
SELECT * FROM tutorial.index_demo WHERE id = 500000;

-- 范围查询
EXPLAIN indexes=1
SELECT count() FROM tutorial.index_demo WHERE id BETWEEN 100000 AND 200000;

-- -----------------------------------------------------
-- 6. MergeTree 家族其他引擎简介
-- -----------------------------------------------------

-- 6.1 ReplacingMergeTree - 自动去重
CREATE TABLE IF NOT EXISTS tutorial.replacing_demo
(
    user_id UInt32,
    event_time DateTime,
    status String,
    -- 版本字段，用于确定哪条记录是最新的
    version UInt32
)
ENGINE = ReplacingMergeTree(version)
ORDER BY user_id;

-- 插入重复数据
INSERT INTO tutorial.replacing_demo VALUES
(1, '2024-01-15 10:00:00', 'active', 1),
(1, '2024-01-15 11:00:00', 'inactive', 2),  -- 同一个 user_id，更新的版本
(2, '2024-01-15 10:00:00', 'active', 1);

-- 查询（注意：ReplacingMergeTree 只在合并时去重）
SELECT * FROM tutorial.replacing_demo ORDER BY user_id;

-- 使用 FINAL 关键字强制去重
SELECT * FROM tutorial.replacing_demo FINAL ORDER BY user_id;

-- 6.2 SummingMergeTree - 自动汇总
CREATE TABLE IF NOT EXISTS tutorial.summing_demo
(
    user_id UInt32,
    event_date Date,
    clicks UInt32,
    revenue Float64
)
ENGINE = SummingMergeTree()
ORDER BY (user_id, event_date);

-- 插入多条记录
INSERT INTO tutorial.summing_demo VALUES
(1, '2024-01-15', 5, 100.0),
(1, '2024-01-15', 3, 50.0),  -- 相同 (user_id, event_date)，会合并
(1, '2024-01-16', 2, 30.0),
(2, '2024-01-15', 10, 200.0);

-- 使用 FINAL 查看汇总结果
SELECT * FROM tutorial.summing_demo FINAL ORDER BY user_id, event_date;

-- 6.3 AggregatingMergeTree - 聚合状态存储
-- 用于物化视图，存储中间聚合状态
CREATE TABLE IF NOT EXISTS tutorial.aggregating_demo
(
    user_id UInt32,
    event_date Date,
    -- 使用 AggregateFunction 类型
    total_clicks AggregateFunction(sum, UInt32),
    avg_value AggregateFunction(avg, Float64)
)
ENGINE = AggregatingMergeTree()
ORDER BY (user_id, event_date);

-- -----------------------------------------------------
-- 7. 排序键设计最佳实践
-- -----------------------------------------------------

-- 创建最佳实践对比表
CREATE TABLE IF NOT EXISTS tutorial.orderby_best_practices
(
    principle String,
    description String,
    example String
)
ENGINE = MergeTree()
ORDER BY principle;

INSERT INTO tutorial.orderby_best_practices VALUES
('最常用的过滤条件放前面', '排序键字段的顺序很重要', 'ORDER BY (date, user_id) > ORDER BY (user_id, date) 当常用 date 过滤'),
('基数高的字段放前面', '区分度高的字段放在排序键前面', 'ORDER BY (user_id, status) > ORDER BY (status, user_id)'),
('避免过长的排序键', '排序键会存储多份，过长浪费空间', '通常 2-4 个字段足够'),
('考虑查询模式', '根据实际查询设计排序键', '如果按时间范围查询多，时间字段放前面'),
('时间字段通常放最后', '时间通常是范围查询，不需要精确匹配', 'ORDER BY (user_id, event_time)'),
('主键和排序键可以不同', '通过 PRIMARY KEY 指定不同的主键', 'ORDER BY (a, b, c) PRIMARY KEY (a, b)');

SELECT * FROM tutorial.orderby_best_practices;

-- -----------------------------------------------------
-- 8. 常见错误和注意事项
-- -----------------------------------------------------

-- 错误 1: 排序键字段在查询中不存在
-- 这会导致全表扫描
-- SELECT * FROM table WHERE non_orderby_column = 'value'

-- 错误 2: 分区粒度过细
-- 不要按天或小时分区，会产生太多分区
-- 推荐按月或年分区

-- 错误 3: 忽略数据类型选择
-- 使用合适的数据类型可以显著提高性能

-- -----------------------------------------------------
-- 9. 性能对比实验
-- -----------------------------------------------------

-- 创建两个表，不同的排序键设计
CREATE TABLE IF NOT EXISTS tutorial.bad_design
(
    user_id UInt32,
    event_date Date,
    event_type String,
    value Float64
)
ENGINE = MergeTree()
-- 不好的设计：常用的 event_date 不在排序键前面
ORDER BY (user_id, event_type, event_date);

CREATE TABLE IF NOT EXISTS tutorial.good_design
(
    user_id UInt32,
    event_date Date,
    event_type String,
    value Float64
)
ENGINE = MergeTree()
-- 好的设计：event_date 在前面，适合时间范围查询
ORDER BY (event_date, user_id)
PARTITION BY toYYYYMM(event_date);

-- 插入相同的数据
INSERT INTO tutorial.bad_design
SELECT 
    rand() % 100000 AS user_id,
    toDate('2024-01-01') + (rand() % 365) AS event_date,
    ['click', 'view', 'purchase'][rand() % 3 + 1] AS event_type,
    rand() % 1000 / 10.0 AS value
FROM numbers(1000000);

INSERT INTO tutorial.good_design
SELECT * FROM tutorial.bad_design;

-- 对比查询性能
-- 好的设计应该扫描更少的数据
EXPLAIN indexes=1
SELECT count() FROM tutorial.good_design WHERE event_date >= '2024-06-01' AND event_date < '2024-07-01';

EXPLAIN indexes=1
SELECT count() FROM tutorial.bad_design WHERE event_date >= '2024-06-01' AND event_date < '2024-07-01';

-- -----------------------------------------------------
-- 10. 学习检查点
-- -----------------------------------------------------

-- 问题 1: ORDER BY 和 PRIMARY KEY 的关系是什么？
-- 答案：默认情况下 ORDER BY 就是 PRIMARY KEY，但可以不同

-- 问题 2: 为什么 MergeTree 是稀疏索引？
-- 答案：每 index_granularity 行（默认 8192）创建一个索引标记，不是每行都索引

-- 问题 3: ReplacingMergeTree 什么时候去重？
-- 答案：在后台合并时，或使用 FINAL 关键字查询时

-- -----------------------------------------------------
-- 11. 清理（可选）
-- -----------------------------------------------------
-- DROP TABLE IF EXISTS tutorial.my_first_mergetree;
-- DROP TABLE IF EXISTS tutorial.sort_key_demo;
-- DROP TABLE IF EXISTS tutorial.partition_demo;
-- DROP TABLE IF EXISTS tutorial.index_demo;
-- DROP TABLE IF EXISTS tutorial.replacing_demo;
-- DROP TABLE IF EXISTS tutorial.summing_demo;
-- DROP TABLE IF EXISTS tutorial.aggregating_demo;
-- DROP TABLE IF EXISTS tutorial.orderby_best_practices;
-- DROP TABLE IF EXISTS tutorial.bad_design;
-- DROP TABLE IF EXISTS tutorial.good_design;

-- =====================================================
-- 本章小结
-- =====================================================
-- 
-- MergeTree 核心概念：
-- 1. ORDER BY: 排序键，决定数据存储顺序和主键
-- 2. PARTITION BY: 分区，用于数据管理和查询优化
-- 3. 稀疏索引: 每 8192 行一个索引标记，节省空间
-- 4. 后台合并: 自动合并小的数据片段
--
-- 引擎类型：
-- - MergeTree: 基础引擎
-- - ReplacingMergeTree: 自动去重（保留最新版本）
-- - SummingMergeTree: 自动汇总数值列
-- - AggregatingMergeTree: 存储聚合状态
--
-- 最佳实践：
-- - 常用过滤条件放排序键前面
-- - 合理使用分区（按月/年）
-- - 选择合适的数据类型
--
-- 下一步：04_basic_sql.sql - 基础 SQL 操作
-- =====================================================
