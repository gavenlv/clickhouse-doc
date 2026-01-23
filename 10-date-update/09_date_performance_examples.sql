-- ================================================
-- 09_date_performance_examples.sql
-- 从 09_date_performance.md 提取的 SQL 示例
-- 提取时间: 2026-01-23 14:40:17
-- ================================================


-- ========================================
-- 存储效率
-- ========================================

-- 比较不同日期类型的存储效率
SELECT
    'Date' AS type,
    formatReadableSize(sum(data_compressed_bytes)) AS compressed,
    formatReadableSize(sum(data_uncompressed_bytes)) AS uncompressed,
    (sum(data_compressed_bytes) * 100.0 / NULLIF(sum(data_uncompressed_bytes), 0)) AS compression_ratio
FROM system.parts_columns
WHERE table = 'test_table' AND column = 'date_col'

UNION ALL

SELECT
    'DateTime',
    formatReadableSize(sum(data_compressed_bytes)),
    formatReadableSize(sum(data_uncompressed_bytes)),
    (sum(data_compressed_bytes) * 100.0 / NULLIF(sum(data_uncompressed_bytes), 0))
FROM system.parts_columns
WHERE table = 'test_table' AND column = 'datetime_col'

UNION ALL

SELECT
    'DateTime64(3)',
    formatReadableSize(sum(data_compressed_bytes)),
    formatReadableSize(sum(data_uncompressed_bytes)),
    (sum(data_compressed_bytes) * 100.0 / NULLIF(sum(data_uncompressed_bytes), 0))
FROM system.parts_columns
WHERE table = 'test_table' AND column = 'datetime64_col';

-- ========================================
-- 存储效率
-- ========================================

-- 比较不同查询方式的性能
SELECT 
    'Date comparison' AS query_type,
    count() AS result
FROM test_table
WHERE date_col = '2024-01-20'

UNION ALL

SELECT
    'DateTime comparison',
    count()
FROM test_table
WHERE datetime_col >= toDateTime('2024-01-20 00:00:00')
  AND datetime_col < toDateTime('2024-01-21 00:00:00')

UNION ALL

SELECT
    'Date function',
    count()
FROM test_table
WHERE toDate(datetime_col) = '2024-01-20';

-- ========================================
-- 存储效率
-- ========================================

-- ✅ 优化：只存储日期时使用 Date 类型
CREATE TABLE events_optimized (
    id UInt64,
    event_date Date,  -- 只需要日期
    event_data String
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_date)
ORDER BY event_date;

-- 查询性能更好
SELECT * FROM events_optimized
WHERE event_date = '2024-01-20';

-- ========================================
-- 存储效率
-- ========================================

-- ✅ 优化：物化常用的时间列
CREATE TABLE events (
    id UInt64,
    event_time DateTime,
    event_date Date MATERIALIZED toDate(event_time),
    event_year UInt16 MATERIALIZED toYear(event_time),
    event_month UInt8 MATERIALIZED toMonth(event_time),
    event_hour UInt8 MATERIALIZED toHour(event_time),
    event_data String
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_date, id);

-- 查询时使用物化列（更快）
SELECT
    event_date,
    event_year,
    event_month,
    count() AS event_count
FROM events
WHERE event_date >= today() - INTERVAL 30 DAY
GROUP BY event_date, event_year, event_month
ORDER BY event_date;

-- ========================================
-- 存储效率
-- ========================================

-- ✅ 优化：使用时间作为分区键
CREATE TABLE events_partitioned (
    id UInt64,
    event_time DateTime,
    event_data String
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)  -- 按月分区
ORDER BY (event_time, id);

-- 查询自动使用分区裁剪
SELECT * FROM events_partitioned
WHERE event_time >= '2024-01-01'
  AND event_time < '2024-02-01';  -- 只扫描 1 个分区

-- ========================================
-- 存储效率
-- ========================================

-- ✅ 优化：创建预聚合物化视图
CREATE MATERIALIZED VIEW daily_events_mv
ENGINE = AggregatingMergeTree()
PARTITION BY toYYYYMM(event_date)
ORDER BY (event_date, event_type)
AS SELECT
    toDate(event_time) AS event_date,
    event_type,
    countState() AS event_count_state,
    avgState(value) AS avg_value_state,
    sumState(value) AS total_value_state
FROM events
GROUP BY event_date, event_type;

-- 查询物化视图（极快）
SELECT
    event_date,
    event_type,
    countMerge(event_count_state) AS event_count,
    avgMerge(avg_value_state) AS avg_value,
    sumMerge(total_value_state) AS total_value
FROM daily_events_mv
WHERE event_date >= today() - INTERVAL 30 DAY
GROUP BY event_date, event_type
ORDER BY event_date, event_type;

-- ========================================
-- 存储效率
-- ========================================

-- ✅ 优化：为时间列创建跳数索引
CREATE TABLE events (
    id UInt64,
    event_time DateTime,
    event_date Date MATERIALIZED toDate(event_time),
    event_type String,
    user_id String
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_time, user_id)
SETTINGS
    index_granularity = 8192;

-- 添加跳数索引
ALTER TABLE events 
ADD INDEX idx_event_date event_date TYPE minmax GRANULARITY 4;

ALTER TABLE events 
ADD INDEX idx_event_type event_type TYPE set(0) GRANULARITY 4;

-- 查询时自动使用索引
SELECT * FROM events
WHERE event_date >= '2024-01-01'
  AND event_date < '2024-02-01'
  AND event_type = 'login';

-- ========================================
-- 存储效率
-- ========================================

-- ❌ 慢：在 WHERE 子句中使用函数
SELECT * FROM events
WHERE toDate(event_time) = '2024-01-20';

-- ✅ 快：使用物化列或预计算值
SELECT * FROM events
WHERE event_date = '2024-01-20';  -- 使用物化列

-- ========================================
-- 存储效率
-- ========================================

-- ❌ 慢：使用等值查询
SELECT * FROM events
WHERE event_time = toDateTime('2024-01-20 12:00:00');

-- ✅ 快：使用时间范围
SELECT * FROM events
WHERE event_time >= toDateTime('2024-01-20 12:00:00')
  AND event_time < toDateTime('2024-01-20 12:01:00');

-- ========================================
-- 存储效率
-- ========================================

-- ✅ 优化：利用分区裁剪
SELECT * FROM events
WHERE event_time >= '2024-01-01'
  AND event_time < '2024-02-01';  -- 只扫描 1 个分区

-- ❌ 慢：跨多个分区查询
SELECT * FROM events
WHERE event_time >= '2024-01-15'
  AND event_time < '2024-02-15';  -- 扫描 2 个分区

-- ========================================
-- 存储效率
-- ========================================

-- 查看查询执行计划
EXPLAIN PIPELINE
SELECT
    event_date,
    count() AS event_count
FROM events
WHERE event_date >= '2024-01-01'
GROUP BY event_date;

-- ========================================
-- 存储效率
-- ========================================

-- 查看查询扫描的数据量
SELECT
    read_rows AS rows_read,
    read_bytes AS bytes_read,
    result_rows AS rows_returned,
    read_bytes / NULLIF(result_rows, 0) AS bytes_per_row
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query ILIKE '%event_date%'
  AND event_date = today()
ORDER BY event_time DESC
LIMIT 10;

-- ========================================
-- 存储效率
-- ========================================

-- 优化的时间序列表设计
CREATE TABLE time_series_optimized (
    metric_name String,
    timestamp DateTime64(3),
    value Float64,
    -- 物化常用的时间维度
    date Date MATERIALIZED toDate(timestamp),
    hour UInt8 MATERIALIZED toHour(timestamp),
    day UInt8 MATERIALIZED toDayOfMonth(timestamp),
    month UInt8 MATERIALIZED toMonth(timestamp),
    year UInt16 MATERIALIZED toYear(timestamp),
    tags Map(String, String)
) ENGINE = MergeTree()
PARTITION BY (metric_name, toYYYYMM(timestamp))
ORDER BY (metric_name, timestamp, tags)
SETTINGS
    index_granularity = 8192;

-- 添加跳数索引
ALTER TABLE time_series_optimized
ADD INDEX idx_metric_name metric_name TYPE set(0) GRANULARITY 1;

-- 查询时使用物化列
SELECT
    metric_name,
    date,
    hour,
    avg(value) AS avg_value,
    count() AS sample_count
FROM time_series_optimized
WHERE date >= today() - INTERVAL 30 DAY
GROUP BY metric_name, date, hour
ORDER BY metric_name, date, hour;

-- ========================================
-- 存储效率
-- ========================================

-- 创建多粒度物化视图

-- 1 分钟粒度
CREATE MATERIALIZED VIEW metrics_1m_mv
ENGINE = AggregatingMergeTree()
PARTITION BY toYYYYMM(timestamp)
ORDER BY (metric_name, tags, timestamp)
AS SELECT
    metric_name,
    tags,
    toStartOfMinute(timestamp) AS timestamp,
    avgState(value) AS avg_value_state,
    minState(value) AS min_value_state,
    maxState(value) AS max_value_state,
    countState() AS count_state
FROM time_series
GROUP BY metric_name, tags, toStartOfMinute(timestamp);

-- 5 分钟粒度
CREATE MATERIALIZED VIEW metrics_5m_mv
ENGINE = AggregatingMergeTree()
PARTITION BY toYYYYMM(timestamp)
ORDER BY (metric_name, tags, timestamp)
AS SELECT
    metric_name,
    tags,
    toStartOfFiveMinutes(timestamp) AS timestamp,
    avgState(value) AS avg_value_state,
    minState(value) AS min_value_state,
    maxState(value) AS max_value_state,
    countState() AS count_state
FROM time_series
GROUP BY metric_name, tags, toStartOfFiveMinutes(timestamp);

-- 1 小时粒度
CREATE MATERIALIZED VIEW metrics_1h_mv
ENGINE = AggregatingMergeTree()
PARTITION BY toYYYYMM(timestamp)
ORDER BY (metric_name, tags, timestamp)
AS SELECT
    metric_name,
    tags,
    toStartOfHour(timestamp) AS timestamp,
    avgState(value) AS avg_value_state,
    minState(value) AS min_value_state,
    maxState(value) AS max_value_state,
    countState() AS count_state
FROM time_series
GROUP BY metric_name, tags, toStartOfHour(timestamp);

-- ========================================
-- 存储效率
-- ========================================

-- ❌ 慢：复杂的时间计算
SELECT
    toStartOfDay(event_time) AS day,
    countIf(toHour(event_time) >= 8 AND toHour(event_time) < 18) AS work_hours_count,
    countIf(toHour(event_time) < 8 OR toHour(event_time) >= 18) AS off_hours_count
FROM events
WHERE event_time >= toStartOfDay(now() - INTERVAL 30 DAY)
GROUP BY day;

-- ✅ 快：使用物化列
CREATE TABLE events_optimized (
    id UInt64,
    event_time DateTime,
    event_date Date MATERIALIZED toDate(event_time),
    event_hour UInt8 MATERIALIZED toHour(event_time),
    is_work_hour UInt8 MATERIALIZED 
        if(toHour(event_time) >= 8 AND toHour(event_time) < 18, 1, 0),
    data String
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_time, id);

-- 查询使用物化列
SELECT
    event_date AS day,
    sumIf(is_work_hour, 1, 0) AS work_hours_count,
    sumIf(is_work_hour = 0, 1, 0) AS off_hours_count
FROM events_optimized
WHERE event_date >= today() - INTERVAL 30 DAY
GROUP BY event_date
ORDER BY event_date;
