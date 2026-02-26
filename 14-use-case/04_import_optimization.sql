-- ========================================
-- 大规模预测数据分析 - 导入优化
-- ========================================
-- 针对156亿行等效数据的导入优化配置
-- 目标：导入时间 < 2分钟
-- ========================================

-- ========================================
-- 1. 导入性能关键配置
-- ========================================

-- 查看当前配置
SELECT 
    name,
    value,
    changed,
    description
FROM system.settings
WHERE name IN (
    'max_insert_threads',
    'max_insert_block_size',
    'min_insert_block_size_rows',
    'min_insert_block_size_bytes',
    'async_insert',
    'async_insert_max_data_size',
    'async_insert_busy_timeout_ms',
    'insert_deduplication_token',
    'insert_quorum',
    'insert_quorum_timeout'
);

-- ========================================
-- 2. 高性能导入配置函数
-- ========================================

-- 配置1: 并行插入 (多线程)
-- 使用方法: INSERT INTO ... SETTINGS max_insert_threads = 8
SELECT 'max_insert_threads = 8  -- 并行写入线程数' AS recommendation;

-- 配置2: 批量大小优化
SELECT 'min_insert_block_size_rows = 1000000  -- 最小批量行数' AS recommendation;
SELECT 'min_insert_block_size_bytes = 104857600  -- 最小批量字节数 (100MB)' AS recommendation;

-- 配置3: 异步插入 (高吞吐)
SELECT 'async_insert = 1  -- 启用异步插入' AS recommendation;
SELECT 'async_insert_max_data_size = 104857600  -- 异步插入最大数据量' AS recommendation;
SELECT 'async_insert_busy_timeout_ms = 10000  -- 异步插入超时' AS recommendation;

-- ========================================
-- 3. 从GCS导入的优化方案
-- ========================================

-- 方案A: 使用GCS表函数 + 并行导入
-- 适用场景：数据已在GCS Parquet格式

INSERT INTO prediction_analytics.prediction_values
SETTINGS 
    max_insert_threads = 8,
    max_insert_block_size = 1000000,
    input_format_parallel_parsing = 1
SELECT 
    transaction_key,
    batch_id,
    metrics_values,
    data_quality_score,
    has_anomaly,
    now() AS created_at,
    now() AS updated_at
FROM gcs(
    'https://storage.googleapis.com/bucket/predictions/*.parquet',
    'Parquet',
    'transaction_key String, batch_id UInt32, metrics_values Array(Array(Float64)), data_quality_score Float64, has_anomaly UInt8'
);

-- 方案B: 分片并行导入
-- 适用场景：大文件分片导入

-- 创建临时导入表
CREATE TABLE IF NOT EXISTS prediction_analytics.prediction_values_staging ON CLUSTER 'treasurycluster' (
    transaction_key String,
    batch_id UInt32,
    metrics_values Array(Array(Float64)),
    data_quality_score Float64 DEFAULT 1.0,
    has_anomaly UInt8 DEFAULT 0,
    created_at DateTime DEFAULT now()
) ENGINE = ReplicatedMergeTree
PARTITION BY batch_id
ORDER BY (batch_id, transaction_key)
SETTINGS index_granularity = 8192;

-- 从多个分片并行导入
INSERT INTO prediction_analytics.prediction_values_staging
SETTINGS max_insert_threads = 8
SELECT * FROM gcs('https://storage.googleapis.com/bucket/shard_*.parquet', 'Parquet');

-- 从staging表导入到正式表
INSERT INTO prediction_analytics.prediction_values
SELECT * FROM prediction_analytics.prediction_values_staging;

-- ========================================
-- 4. Native格式导入 (最快方式)
-- ========================================

-- Native格式是ClickHouse原生格式，导入速度最快
-- 使用方法: 通过clickhouse-client导入

/*
-- 命令行导入 (推荐)
clickhouse-client --host clickhouse1 \
    --query "INSERT INTO prediction_analytics.prediction_values FORMAT Native" \
    < predictions.native

-- 或使用HTTP接口
curl 'http://clickhouse1:8123/?query=INSERT%20INTO%20prediction_analytics.prediction_values%20FORMAT%20Native' \
    --data-binary @predictions.native
*/

-- 导出为Native格式示例
SELECT * FROM prediction_analytics.prediction_values
INTO OUTFILE 'predictions.native'
FORMAT Native;

-- ========================================
-- 5. Parquet格式导入优化
-- ========================================

-- Parquet格式是列式存储，适合大数据导入
INSERT INTO prediction_analytics.prediction_values
SETTINGS 
    max_insert_threads = 8,
    input_format_parallel_parsing = 1,
    input_format_parquet_max_block_size = 1000000
SELECT 
    transaction_key,
    batch_id,
    metrics_values,
    data_quality_score,
    has_anomaly,
    now() AS created_at,
    now() AS updated_at
FROM file('predictions.parquet', 'Parquet');

-- ========================================
-- 6. 异步插入配置
-- ========================================

-- 适用场景：高频小批量导入
-- 注意：不适合单次大批量导入

INSERT INTO prediction_analytics.prediction_values
SETTINGS 
    async_insert = 1,
    wait_for_async_insert = 0,  -- 不等待完成
    async_insert_max_data_size = 104857600,
    async_insert_busy_timeout_ms = 10000
VALUES 
    ('TXN_000001', 1, [[100.0, 101.0]], 0.95, 0, now(), now()),
    ('TXN_000002', 1, [[200.0, 201.0]], 0.95, 0, now(), now());

-- ========================================
-- 7. 分布式表导入优化
-- ========================================

-- 创建分布式表
CREATE TABLE IF NOT EXISTS prediction_analytics.prediction_values_distributed ON CLUSTER 'treasurycluster' (
    transaction_key String,
    batch_id UInt32,
    metrics_values Array(Array(Float64)),
    data_quality_score Float64 DEFAULT 1.0,
    has_anomaly UInt8 DEFAULT 0,
    created_at DateTime DEFAULT now()
) ENGINE = Distributed('treasurycluster', 'prediction_analytics', 'prediction_values', rand());

-- 通过分布式表并行写入
INSERT INTO prediction_analytics.prediction_values_distributed
SETTINGS 
    max_insert_threads = 8,
    prefer_localhost_replica = 0
SELECT * FROM file('predictions.parquet', 'Parquet');

-- ========================================
-- 8. 从长格式转换为宽格式的导入脚本
-- ========================================

-- 假设数据科学家提供的是长格式数据
-- 需要先聚合转换为宽格式再导入

-- 临时表存储长格式数据
CREATE TABLE IF NOT EXISTS prediction_analytics.temp_long_format (
    transaction_key String,
    batch_id UInt32,
    prediction_month UInt8,
    metric_id UInt8,
    metric_value Float64
) ENGINE = MergeTree
ORDER BY (batch_id, transaction_key, metric_id, prediction_month);

-- 导入长格式数据
INSERT INTO prediction_analytics.temp_long_format
SETTINGS max_insert_threads = 8
SELECT * FROM file('long_predictions.parquet', 'Parquet');

-- 转换为宽格式并导入
INSERT INTO prediction_analytics.prediction_values
SELECT 
    transaction_key,
    batch_id,
    arrayMap(
        m_id -> arrayMap(
            m_offset -> 
                anyIf(metric_value, metric_id = m_id AND prediction_month = m_offset),
            range(1, 61)
        ),
        range(1, 21)
    ) AS metrics_values,
    1.0 AS data_quality_score,
    0 AS has_anomaly,
    now() AS created_at,
    now() AS updated_at
FROM prediction_analytics.temp_long_format
GROUP BY transaction_key, batch_id;

-- 清理临时表
DROP TABLE prediction_analytics.temp_long_format;

-- ========================================
-- 9. 导入性能监控
-- ========================================

-- 监控导入进度
SELECT 
    query_id,
    query,
    read_rows,
    read_bytes,
    written_rows,
    written_bytes,
    memory_usage,
    query_duration_ms / 1000 AS duration_sec,
    round(written_rows / (query_duration_ms / 1000), 0) AS rows_per_sec
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query LIKE '%INSERT INTO prediction_analytics.prediction_values%'
ORDER BY event_time DESC
LIMIT 10;

-- 监控当前执行的导入
SELECT 
    query_id,
    query,
    read_rows,
    read_bytes,
    written_rows,
    memory_usage,
    elapsed / 1000 AS elapsed_sec
FROM system.processes
WHERE query LIKE '%INSERT INTO prediction_analytics%';

-- ========================================
-- 10. 导入性能基准测试
-- ========================================

-- 测试1: 单线程导入
INSERT INTO prediction_analytics.prediction_values
SETTINGS max_insert_threads = 1
SELECT 
    concat('TEST_', toString(number)) AS transaction_key,
    1 AS batch_id,
    arrayMap(m -> arrayMap(x -> rand64() % 10000 / 100.0, range(60)), range(20)) AS metrics_values,
    1.0 AS data_quality_score,
    0 AS has_anomaly,
    now() AS created_at,
    now() AS updated_at
FROM numbers(1000000);

-- 测试2: 8线程并行导入
INSERT INTO prediction_analytics.prediction_values
SETTINGS max_insert_threads = 8
SELECT 
    concat('TEST_', toString(number)) AS transaction_key,
    1 AS batch_id,
    arrayMap(m -> arrayMap(x -> rand64() % 10000 / 100.0, range(60)), range(20)) AS metrics_values,
    1.0 AS data_quality_score,
    0 AS has_anomaly,
    now() AS created_at,
    now() AS updated_at
FROM numbers(1000000);

-- 对比性能
SELECT 
    'Single Thread' AS test_type,
    sum(written_rows) / sum(query_duration_ms) * 1000 AS rows_per_sec
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query LIKE '%TEST_%'
  AND query LIKE '%max_insert_threads = 1%'
UNION ALL
SELECT 
    '8 Threads' AS test_type,
    sum(written_rows) / sum(query_duration_ms) * 1000 AS rows_per_sec
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query LIKE '%TEST_%'
  AND query LIKE '%max_insert_threads = 8%';

-- ========================================
-- 11. 推荐的导入命令
-- ========================================

/*
完整的导入流程命令：

# 步骤1: 准备数据文件 (Native格式最优)
clickhouse-client --query "
    SELECT * FROM staging_table
    INTO OUTFILE 'predictions.native'
    FORMAT Native
"

# 步骤2: 并行导入
clickhouse-client \
    --host clickhouse1 \
    --max_insert_threads 8 \
    --query "INSERT INTO prediction_analytics.prediction_values FORMAT Native" \
    < predictions.native

# 步骤3: 验证导入结果
clickhouse-client --query "
    SELECT 
        count() AS rows,
        formatReadableSize(sum(data_compressed_bytes)) AS size
    FROM system.parts
    WHERE database = 'prediction_analytics' 
      AND table = 'prediction_values'
      AND active = 1
"
*/

-- ========================================
-- 12. 生产环境导入脚本
-- ========================================

-- 完整的生产环境导入存储过程 (ClickHouse 23.8+)
-- 注意：ClickHouse不支持传统存储过程，使用以下脚本代替

-- 创建导入日志表
CREATE TABLE IF NOT EXISTS prediction_analytics.import_log ON CLUSTER 'treasurycluster' (
    import_id UUID DEFAULT generateUUIDv4(),
    table_name String,
    file_path String,
    start_time DateTime,
    end_time DateTime DEFAULT now(),
    status String,
    rows_imported UInt64,
    bytes_imported UInt64,
    error_message String,
    created_at DateTime DEFAULT now()
) ENGINE = ReplicatedMergeTree
PARTITION BY toYYYYMM(start_time)
ORDER BY (start_time, import_id);

-- 记录导入开始
INSERT INTO prediction_analytics.import_log (table_name, file_path, start_time, status)
VALUES ('prediction_values', 'gcs://bucket/predictions.parquet', now(), 'running');

-- 执行导入（使用变量替换）
SET param_file_path = 'gcs://bucket/predictions.parquet';

INSERT INTO prediction_analytics.prediction_values
SETTINGS max_insert_threads = 8
SELECT 
    transaction_key, batch_id, metrics_values, 
    data_quality_score, has_anomaly, created_at, updated_at
FROM file({param_file_path:String}, 'Parquet');
