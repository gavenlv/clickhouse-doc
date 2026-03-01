-- =====================================================
-- 01 - 什么是 ClickHouse？
-- =====================================================
-- 本文件帮助你理解 ClickHouse 的定位、特点和适用场景
-- 适合完全零基础的初学者
-- =====================================================

-- -----------------------------------------------------
-- 1. 验证 ClickHouse 版本和基本信息
-- -----------------------------------------------------
-- 首先，让我们确认我们连接的是 ClickHouse
SELECT 
    version() AS clickhouse_version,
    uptime() AS server_uptime_seconds
FROM system.asynchronous_metrics
WHERE metric IN ('Uptime', 'TotalBytesOfMergeTreeTables')
LIMIT 1;


-- -----------------------------------------------------
-- 2. ClickHouse 的核心特点展示
-- -----------------------------------------------------
-- 让我们用一个简单的例子展示 ClickHouse 的性能
-- 生成 1000 万行测试数据并计算聚合

-- 创建测试数据库
CREATE DATABASE IF NOT EXISTS tutorial;

-- 创建测试表
CREATE TABLE IF NOT EXISTS tutorial.performance_demo
(
    id UInt64,
    user_id UInt32,
    event_type LowCardinality(String),
    event_date Date,
    event_time DateTime,
    value Float64,
    properties String
)
ENGINE = MergeTree()
ORDER BY (event_date, event_time)
PARTITION BY toYYYYMM(event_date);

-- 插入 1000 万行测试数据
INSERT INTO tutorial.performance_demo
SELECT 
    number AS id,
    rand() % 1000000 AS user_id,
    ['click', 'view', 'purchase', 'login', 'logout'][rand() % 5 + 1] AS event_type,
    toDate('2024-01-01') + (rand() % 365) AS event_date,
    toDateTime('2024-01-01 00:00:00') + (rand() % 31536000) AS event_time,
    rand() / 1000000.0 AS value,
    'some random properties data for testing' AS properties
FROM numbers(10000000);

-- -----------------------------------------------------
-- 3. 体验 ClickHouse 的查询性能
-- -----------------------------------------------------
-- 聚合查询：统计每日事件数（在千万级数据上）
-- 注意：在普通笔记本上，这个查询通常在 100ms 内完成

SELECT 
    event_date,
    count() AS event_count,
    count(DISTINCT user_id) AS unique_users,
    sum(value) AS total_value,
    avg(value) AS avg_value
FROM tutorial.performance_demo
WHERE event_date >= '2024-01-01' AND event_date <= '2024-01-31'
GROUP BY event_date
ORDER BY event_date
LIMIT 10;

-- -----------------------------------------------------
-- 4. ClickHouse 的列式存储优势展示
-- -----------------------------------------------------
-- 只查询需要的列，ClickHouse 会自动优化
-- 对比以下两个查询：

-- 查询 A: 只查询需要的列（快）
SELECT event_date, count() 
FROM tutorial.performance_demo 
GROUP BY event_date;

-- 查询 B: 查询所有列（慢）
-- 注意：这展示了为什么不要 SELECT *
-- SELECT * FROM tutorial.performance_demo LIMIT 100;

-- -----------------------------------------------------
-- 5. 数据压缩效果展示
-- -----------------------------------------------------
-- 查看表的存储信息
SELECT 
    table,
    formatReadableSize(sum(bytes)) AS disk_size,
    formatReadableSize(sum(data_uncompressed_bytes)) AS uncompressed_size,
    round(sum(data_uncompressed_bytes) / sum(bytes), 2) AS compression_ratio,
    sum(rows) AS total_rows
FROM system.parts
WHERE database = 'tutorial' AND table = 'performance_demo'
GROUP BY table;

-- -----------------------------------------------------
-- 6. 适用场景 vs 不适用场景
-- -----------------------------------------------------
-- 创建一个对比表帮助理解
CREATE TABLE IF NOT EXISTS tutorial.use_case_comparison
(
    scenario String,
    clickhouse_suitable UInt8,
    reason String,
    alternative String
)
ENGINE = MergeTree()
ORDER BY scenario;

INSERT INTO tutorial.use_case_comparison VALUES
-- 适合的场景
('日志分析', 1, '海量数据，主要做聚合查询，数据追加为主', 'Elasticsearch'),
('时序数据', 1, '时间序列数据，按时间范围查询，高压缩率', 'InfluxDB, TimescaleDB'),
('数据仓库', 1, 'OLAP 分析，复杂聚合，维度分析', 'Snowflake, BigQuery'),
('实时报表', 1, '预聚合，快速查询，高并发读取', 'Druid, Pinot'),
('用户行为分析', 1, '事件流分析，漏斗分析，留存分析', '自定义解决方案');

-- 不适合的场景
INSERT INTO tutorial.use_case_comparison VALUES
('银行交易', 0, '需要 ACID 事务，行级更新频繁', 'PostgreSQL, Oracle'),
('订单处理', 0, '需要事务支持，频繁的 UPDATE/DELETE', 'MySQL, PostgreSQL'),
('用户资料管理', 0, '单条记录查询，频繁更新', 'Redis, MongoDB'),
('库存管理', 0, '需要精确的行级锁和事务', 'MySQL, PostgreSQL'),
('消息队列', 0, '需要低延迟的消息传递', 'Kafka, RabbitMQ');

-- 查看适用性对比
SELECT 
    scenario,
    if(clickhouse_suitable = 1, '✅ 适合', '❌ 不适合') AS suitability,
    reason,
    alternative
FROM tutorial.use_case_comparison
ORDER BY clickhouse_suitable DESC, scenario;

-- -----------------------------------------------------
-- 7. 性能基准测试示例
-- -----------------------------------------------------
-- 测试不同数据量的查询性能

-- 1亿行数据聚合查询（如果你的机器足够强大）
-- 注意：这可能会占用较多内存
-- 
-- INSERT INTO tutorial.performance_demo
-- SELECT 
--     number + 10000000 AS id,
--     rand() % 1000000 AS user_id,
--     ['click', 'view', 'purchase'][rand() % 3 + 1] AS event_type,
--     toDate('2024-01-01') + (rand() % 365) AS event_date,
--     toDateTime('2024-01-01 00:00:00') + (rand() % 31536000) AS event_time,
--     rand() / 1000000.0 AS value,
--     'data' AS properties
-- FROM numbers(90000000);

-- -----------------------------------------------------
-- 8. 系统能力展示
-- -----------------------------------------------------
-- 查看 ClickHouse 支持的函数数量
SELECT 
    count() AS total_functions,
    countIf(is_aggregate = 1) AS aggregate_functions,
    countIf(is_aggregate = 0) AS scalar_functions
FROM system.functions;

-- 查看支持的表引擎
SELECT 
    name AS engine_name,
    if(has_own_data = 1, '存储数据', '虚拟引擎') AS engine_type
FROM system.table_engines
WHERE name LIKE '%MergeTree%' OR name LIKE '%Log%'
ORDER BY engine_type, engine_name
LIMIT 20;

-- -----------------------------------------------------
-- 9. 学习检查点
-- -----------------------------------------------------
-- 完成以下查询，验证你的理解

-- 问题 1: 我们当前插入了多少行数据？
-- 答案：
SELECT count() FROM tutorial.performance_demo;

-- 问题 2: 数据压缩率是多少？
-- 答案：
SELECT 
    round(sum(data_uncompressed_bytes) / sum(bytes), 2) AS compression_ratio
FROM system.parts
WHERE database = 'tutorial' AND table = 'performance_demo';

-- 问题 3: ClickHouse 适合你的场景吗？
-- 思考并查看 use_case_comparison 表

-- -----------------------------------------------------
-- 10. 清理（可选）
-- -----------------------------------------------------
-- 如果你想清理测试数据，取消注释以下命令：
-- DROP TABLE IF EXISTS tutorial.performance_demo;
-- DROP TABLE IF EXISTS tutorial.use_case_comparison;

-- =====================================================
-- 本章小结
-- =====================================================
-- 
-- ClickHouse 是：
-- 1. 开源的列式 OLAP 数据库
-- 2. 专为海量数据分析设计
-- 3. 高性能的聚合查询能力
-- 4. 优秀的数据压缩率
-- 
-- 适合：日志分析、时序数据、数据仓库、实时报表
-- 不适合：事务处理、频繁更新、行级查询
--
-- 下一步：02_column_oriented.sql - 深入理解列式存储
-- =====================================================
