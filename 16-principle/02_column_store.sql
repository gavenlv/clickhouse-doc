-- ================================================================================
-- 02 - 列式存储原理
-- ================================================================================
-- 
-- 集群: treasurycluster (2 副本)
-- 预计学习时间: 25 分钟
-- 
-- 本文件涵盖:
--   1. 列式vs行式存储 - 存储结构对比与适用场景
--   2. 压缩机制原理 - 同类型数据高效压缩
--   3. LowCardinality优化 - 低基数列字典编码
--   4. index_granularity - 稀疏索引粒度控制
--   5. 压缩算法对比 - LZ4/ZSTD/Delta性能差异
--   6. 向量化执行 - SIMD指令批量处理
--   7. 数据类型选择 - 存储大小与性能权衡
--   8. PREWHERE优化 - 过滤前置减少IO
-- 
-- 本文件帮助你理解 ClickHouse 的列式存储机制
-- 展示列式存储的优势和工作原理
-- 
-- ================================================================================

-- -----------------------------------------------------
-- 1. 创建测试数据
-- -----------------------------------------------------

CREATE DATABASE IF NOT EXISTS tutorial;

-- 创建演示表
DROP TABLE IF EXISTS tutorial.column_store_demo;

CREATE TABLE IF NOT EXISTS tutorial.column_store_demo (
    id UInt64,
    user_id UInt32,
    event_type LowCardinality(String),
    event_date Date,
    value Float64,
    description String
) ENGINE = MergeTree()
ORDER BY (event_date, user_id)
PARTITION BY toYYYYMM(event_date);

-- 插入 100 万行测试数据
INSERT INTO tutorial.column_store_demo
SELECT 
    number AS id,
    number % 10000 AS user_id,
    ['click', 'view', 'purchase', 'login', 'logout', 'signup'][number % 6 + 1] AS event_type,
    toDate('2024-01-01') + (number % 365) AS event_date,
    (rand() % 10000) / 100.0 AS value,
    repeat('description_', 10) AS description
FROM numbers(1000000);

-- -----------------------------------------------------
-- 2. 列式存储 vs 行式存储对比
-- -----------------------------------------------------

-- 查看列式存储的文件结构
-- 每个列都有独立的 .bin 文件

SELECT 
    column,
    formatReadableSize(sum(compressed_bytes)) AS compressed_size,
    formatReadableSize(sum(data_uncompressed_bytes)) AS uncompressed_size,
    round(sum(data_uncompressed_bytes) / sum(compressed_bytes), 2) AS compression_ratio,
    sum(rows) AS rows
FROM system.parts_columns
WHERE database = 'tutorial' AND table = 'column_store_demo' AND active = 1
GROUP BY column
ORDER BY column;

-- 对比不同数据类型的压缩率
-- 低基数列 (LowCardinality) vs 普通字符串

DROP TABLE IF EXISTS tutorial.compression_comparison;

CREATE TABLE IF NOT EXISTS tutorial.compression_comparison (
    id UInt64,
    event_type_string String,
    event_type_lowcard LowCardinality(String),
    value Float64
) ENGINE = MergeTree()
ORDER BY id;

INSERT INTO tutorial.compression_comparison
SELECT 
    number AS id,
    ['click', 'view', 'purchase', 'login', 'logout'][number % 5 + 1] AS event_type_string,
    ['click', 'view', 'purchase', 'login', 'logout'][number % 5 + 1] AS event_type_lowcard,
    rand() / 100.0 AS value
FROM numbers(1000000);

SELECT 
    '普通 String' AS column_type,
    formatReadableSize(sum(compressed_bytes)) AS compressed,
    formatReadableSize(sum(data_uncompressed_bytes)) AS uncompressed,
    round(sum(data_uncompressed_bytes) / sum(compressed_bytes), 2) AS ratio
FROM system.parts_columns
WHERE database = 'tutorial' AND table = 'compression_comparison' AND column = 'event_type_string' AND active = 1
UNION ALL
SELECT 
    'LowCardinality' AS column_type,
    formatReadableSize(sum(compressed_bytes)) AS compressed,
    formatReadableSize(sum(data_uncompressed_bytes)) AS uncompressed,
    round(sum(data_uncompressed_bytes) / sum(compressed_bytes), 2) AS ratio
FROM system.parts_columns
WHERE database = 'tutorial' AND table = 'compression_comparison' AND column = 'event_type_lowcard' AND active = 1;

-- -----------------------------------------------------
-- 3. 列式存储的优势演示
-- -----------------------------------------------------

-- 场景 1: 只查询某一列 (列式存储优势明显)

-- 查询只涉及 value 列
SELECT sum(value), avg(value), max(value), min(value)
FROM tutorial.column_store_demo;

-- 场景 2: 查询涉及多列

SELECT 
    event_type,
    count() AS cnt,
    sum(value) AS total
FROM tutorial.column_store_demo
WHERE event_date >= '2024-03-01'
GROUP BY event_type;

-- 场景 3: 分析查询 (列式存储优势)

SELECT 
    event_date,
    event_type,
    count() AS event_count,
    uniqExact(user_id) AS unique_users,
    sum(value) AS total_value
FROM tutorial.column_store_demo
WHERE event_date BETWEEN '2024-01-01' AND '2024-03-31'
GROUP BY event_date, event_type
ORDER BY event_date, event_count DESC
LIMIT 20;

-- 查看查询性能统计
SELECT 
    query,
    read_rows,
    read_bytes,
    query_duration_ms
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query LIKE '%column_store_demo%'
ORDER BY event_time DESC
LIMIT 5;

-- -----------------------------------------------------
-- 4. 列式存储内部结构
-- -----------------------------------------------------

-- 查看数据文件分布
SELECT 
    name AS part_name,
    rows,
    formatReadableSize(bytes) AS size,
    formatReadableSize(marks_size) AS marks_size
FROM system.parts
WHERE database = 'tutorial' AND table = 'column_store_demo' AND active = 1
ORDER BY name;

-- 理解 index_granularity
-- 每个 .mrk2 文件对应列数据，每 8192 行为一个 Granule

-- 查看 MergeTree 设置
SELECT 
    name,
    value,
    description
FROM system.merge_tree_settings
WHERE name = 'index_granularity';

-- 模拟不同 index_granularity 的效果

DROP TABLE IF EXISTS tutorial.granularity_test;

CREATE TABLE tutorial.granularity_test (
    id UInt64,
    value Float64
) ENGINE = MergeTree()
ORDER BY id
SETTINGS index_granularity = 4096;  -- 默认 8192

INSERT INTO tutorial.granularity_test
SELECT number, rand() / 100.0
FROM numbers(100000);

-- 查看生成的 mark 数量
SELECT 
    name AS part_name,
    rows,
    rows / index_granularity AS marks_count,
    formatReadableSize(bytes) AS size
FROM system.parts
WHERE database = 'tutorial' AND table = 'granularity_test' AND active = 1;

-- -----------------------------------------------------
-- 5. 压缩算法对比
-- -----------------------------------------------------

-- 创建不同压缩算法的表
DROP TABLE IF EXISTS tutorial.compression_lz4;
DROP TABLE IF EXISTS tutorial.compression_zstd;
DROP TABLE IF EXISTS tutorial.compression_delta;

CREATE TABLE tutorial.compression_lz4 (
    id UInt64,
    value Float64,
    date Date,
    data String
) ENGINE = MergeTree()
ORDER BY id
SETTINGS compression_codec = 'LZ4';

CREATE TABLE tutorial.compression_zstd (
    id UInt64,
    value Float64,
    date Date,
    data String
) ENGINE = MergeTree()
ORDER BY id
SETTINGS compression_codec = 'ZSTD';

CREATE TABLE tutorial.compression_delta (
    id UInt64,
    value Float64,
    date Date,
    data String
) ENGINE = MergeTree()
ORDER BY id
SETTINGS compression_codec = 'Delta';

-- 插入相同数据
INSERT INTO tutorial.compression_lz4
SELECT number, rand() / 100.0, toDate('2024-01-01') + (number % 30), repeat('data_', 20)
FROM numbers(100000);

INSERT INTO tutorial.compression_zstd
SELECT * FROM tutorial.compression_lz4;

INSERT INTO tutorial.compression_delta
SELECT * FROM tutorial.compression_lz4;

-- 对比压缩效果
SELECT 
    table,
    formatReadableSize(sum(bytes)) AS total_size,
    formatReadableSize(sum(data_uncompressed_bytes)) AS uncompressed_size,
    round(sum(data_uncompressed_bytes) / sum(bytes), 2) AS compression_ratio
FROM system.parts
WHERE database = 'tutorial' 
  AND table LIKE 'compression_%' 
  AND active = 1
GROUP BY table
ORDER BY total_size;

-- -----------------------------------------------------
-- 6. 向量化执行演示
-- -----------------------------------------------------

-- 查看是否启用向量化执行
SELECT 
    name,
    value
FROM system.settings
WHERE name = 'max_vectorized_search_depth';

-- 向量化执行的优势: 一次处理多条数据
-- 演示聚合函数性能
SELECT 
    count() AS total_rows,
    sum(value) AS total_value,
    avg(value) AS avg_value,
    stddevPop(value) AS std_dev,
    quantileExact(0.5)(value) AS median,
    quantileExact(0.95)(value) AS p95
FROM tutorial.column_store_demo;

-- -----------------------------------------------------
-- 7. 列式存储查询优化
-- -----------------------------------------------------

-- 优化: 只选择需要的列
-- 好的做法
SELECT event_type, count() 
FROM tutorial.column_store_demo 
GROUP BY event_type;

-- 不好的做法 (读取所有列)
-- SELECT * FROM tutorial.column_store_demo LIMIT 10;

-- 使用 PREWHERE 优化
-- PREWHERE 会先读取主键列进行过滤，减少 I/O

SELECT 
    user_id,
    count() AS cnt
FROM tutorial.column_store_demo
PREWHERE event_date >= '2024-03-01'
WHERE event_type = 'purchase'
GROUP BY user_id
ORDER BY cnt DESC
LIMIT 10;

-- -----------------------------------------------------
-- 8. 列式存储的数据类型选择
-- -----------------------------------------------------

-- 数值类型选择
DROP TABLE IF EXISTS tutorial.type_selection;

CREATE TABLE tutorial.type_selection (
    id UInt64,
    value_int8 Int8,
    value_int16 Int16,
    value_int32 Int32,
    value_int64 Int64,
    value_float32 Float32,
    value_float64 Float64
) ENGINE = MergeTree()
ORDER BY id;

INSERT INTO tutorial.type_selection
SELECT 
    number AS id,
    (rand() % 100) - 50 AS value_int8,
    (rand() % 10000) - 5000 AS value_int16,
    (rand() % 1000000) - 500000 AS value_int32,
    (rand() % 1000000000) - 500000000 AS value_int64,
    (rand() % 10000) / 100.0 AS value_float32,
    (rand() % 1000000) / 100.0 AS value_float64
FROM numbers(1000000);

-- 对比存储大小
SELECT 
    column,
    formatReadableSize(sum(compressed_bytes)) AS compressed,
    formatReadableSize(sum(data_uncompressed_bytes)) AS uncompressed,
    round(sum(data_uncompressed_bytes) / sum(compressed_bytes), 1) AS ratio
FROM system.parts_columns
WHERE database = 'tutorial' AND table = 'type_selection' AND active = 1
GROUP BY column
ORDER BY compressed;

-- -----------------------------------------------------
-- 9. 清理
-- -----------------------------------------------------

DROP TABLE IF EXISTS tutorial.column_store_demo;
DROP TABLE IF EXISTS tutorial.compression_comparison;
DROP TABLE IF EXISTS tutorial.granularity_test;
DROP TABLE IF EXISTS tutorial.compression_lz4;
DROP TABLE IF EXISTS tutorial.compression_zstd;
DROP TABLE IF EXISTS tutorial.compression_delta;
DROP TABLE IF EXISTS tutorial.type_selection;

-- =====================================================
-- 本章小结
-- =====================================================
-- 
-- 列式存储核心要点:
-- 1. 每个列独立存储在单独的 .bin 文件中
-- 2. 同列数据类型相同，压缩效率高
-- 3. 查询只需读取涉及的列，减少 I/O
-- 4. LowCardinality 类型可大幅减少字符串存储
-- 5. 不同的压缩算法有不同的压缩比和性能
-- 6. index_granularity 控制每个 mark 的行数
-- 7. 向量化执行提高 CPU 利用率
--
-- 最佳实践:
-- - 使用合适的数据类型
-- - 使用 LowCardinality 优化低基数字符串
-- - 只选择需要的列
-- - 使用 PREWHERE 优化
--
-- 下一步: 03_mergetree.sql - 深入理解 MergeTree 引擎
-- =====================================================
