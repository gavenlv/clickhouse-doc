-- ================================================================================
-- ClickHouse 日期时间性能优化详解
-- ================================================================================
-- 
-- 集群: treasurycluster (2 副本)
-- 预计学习时间: 30 分钟
-- 
-- 本文件涵盖:
--   1. 存储效率优化 - 选择合适的日期类型
--   2. 物化列优化 - MATERIALIZED 列
--   3. 分区裁剪优化 - 按时间分区
--   4. 跳数索引优化 - minmax, set 索引
--   5. 物化视图优化 - 预聚合时间数据
--   6. 查询优化技巧 - 避免函数在 WHERE 中
-- 
-- ================================================================================
-- 性能优化层级
-- ================================================================================
-- 
--   ┌─────────────────────────────────────────────────────────────────────────┐
--   │                      ClickHouse 性能优化金字塔                          │
--   └─────────────────────────────────────────────────────────────────────────┘
--   
--                            ▲
--                           /│\
--                          / │ \
--                         /  │  \    查询优化 (避免函数、使用范围查询)
--                        /   │   \   
--                       /────┼────\  
--                      /     │     \  索引优化 (主键、跳数索引)
--                     /      │      \ 
--                    /───────┼───────\ 物化视图 (预聚合)
--                   /        │        \
--                  /         │         \ 分区优化 (分区裁剪)
--                 /──────────┼──────────\
--                /           │           \ 存储优化 (类型选择、物化列)
--               /────────────┼────────────\
--   
--   优化顺序: 从底层到顶层, 逐步优化
-- 
-- ================================================================================
-- 存储效率优化
-- ================================================================================
-- 
--   ┌─────────────────────────────────────────────────────────────────────────┐
--   │                     日期类型存储对比                                    │
--   └─────────────────────────────────────────────────────────────────────────┘
--   
--   类型          原始大小    压缩后      压缩比     查询性能
--   ────────────────────────────────────────────────────────────────────
--   Date          2 bytes     ~1 byte     50%       ★★★★★ 最快
--   Date32        4 bytes     ~2 bytes    50%       ★★★★★
--   DateTime      4 bytes     ~2 bytes    50%       ★★★★☆
--   DateTime64(3) 8 bytes     ~4 bytes    50%       ★★★☆☆
--   DateTime64(6) 8 bytes     ~5 bytes    62%       ★★☆☆☆ 最慢
--   
--   选择原则:
--   ┌──────────────────────────────────────────────────────────────────────┐
--   │  只需要日期?         → Date (2字节)                                   │
--   │  需要扩展日期范围?   → Date32 (4字节, 1900-2299年)                    │
--   │  需要秒级精度?       → DateTime (4字节)                               │
--   │  需要毫秒/微秒?      → DateTime64(3或6) (8字节)                       │
--   └──────────────────────────────────────────────────────────────────────┘
-- 
-- ================================================================================
-- 物化列优化原理
-- ================================================================================
-- 
--   ┌─────────────────────────────────────────────────────────────────────────┐
--   │                     MATERIALIZED 列工作原理                             │
--   └─────────────────────────────────────────────────────────────────────────┘
--   
--   无物化列:
--   ┌──────────────────────────────────────────────────────────────────────┐
--   │  INSERT: event_time (DateTime)                                       │
--   │      │                                                                │
--   │      ▼                                                                │
--   │  存储: event_time (DateTime)                                          │
--   │      │                                                                │
--   │      ▼                                                                │
--   │  查询: toDate(event_time) (每次计算)                                  │
--   └──────────────────────────────────────────────────────────────────────┘
--   
--   有物化列:
--   ┌──────────────────────────────────────────────────────────────────────┐
--   │  INSERT: event_time (DateTime)                                       │
--   │      │                                                                │
--   │      ├──────────────────────────────┐                                │
--   │      ▼                              ▼                                │
--   │  存储: event_time (DateTime)    event_date (Date MATERIALIZED)       │
--   │      │                              │                                │
--   │      ▼                              ▼                                │
--   │  查询: toDate(event_time)       event_date (直接读取, 无需计算)       │
--   └──────────────────────────────────────────────────────────────────────┘
--   
--   性能提升: 避免每次查询都计算 toDate()
-- 
-- ================================================================================
-- 分区裁剪原理
-- ================================================================================
-- 
--   ┌─────────────────────────────────────────────────────────────────────────┐
--   │                     分区裁剪 (Partition Pruning)                        │
--   └─────────────────────────────────────────────────────────────────────────┘
--   
--   表定义: PARTITION BY toYYYYMM(event_time)
--   
--   分区布局:
--   ┌───────────┬───────────┬───────────┬───────────┬───────────┐
--   │  202401   │  202402   │  202403   │  202404   │  202405   │
--   │ (2024-01) │ (2024-02) │ (2024-03) │ (2024-04) │ (2024-05) │
--   │  10GB     │  12GB     │  11GB     │  13GB     │  10GB     │
--   └───────────┴───────────┴───────────┴───────────┴───────────┘
--         ▲                          ▲
--         │      查询条件:           │
--         │  event_time >= '2024-01-01' AND
--         │  event_time <  '2024-04-01'
--         └──────────────────────────┘
--   
--   结果: 只扫描 202401, 202402, 202403
--         跳过 202404, 202405
--         扫描数据量: 33GB / 56GB = 59%
--   
--   关键: 查询条件必须基于分区键表达式!
-- 
-- ================================================================================
-- 跳数索引原理
-- ================================================================================
-- 
--   ┌─────────────────────────────────────────────────────────────────────────┐
--   │                      跳数索引工作原理                                   │
--   └─────────────────────────────────────────────────────────────────────────┘
--   
--   数据按 granule (颗粒) 组织, 每个 granule 约 8192 行
--   
--   ┌────────────────────────────────────────────────────────────────────────┐
--   │ Granule 1    │ Granule 2    │ Granule 3    │ Granule 4    │ ...      │
--   │ date: 01-05  │ date: 06-10  │ date: 11-15  │ date: 16-20  │          │
--   └────────────────────────────────────────────────────────────────────────┘
--   
--   minmax 索引存储每个 granule 的最小/最大值:
--   ┌────────────────────────────────────────────────────────────────────────┐
--   │ Granule 1: min=01-05, max=01-05                                        │
--   │ Granule 2: min=01-06, max=01-10                                        │
--   │ Granule 3: min=01-11, max=01-15                                        │
--   │ Granule 4: min=01-16, max=01-20                                        │
--   └────────────────────────────────────────────────────────────────────────┘
--   
--   查询: WHERE event_date = '2024-01-08'
--   
--   跳过 Granule 1 (08 > 05)
--   读取 Granule 2 (06 <= 08 <= 10) ✓
--   跳过 Granule 3 (08 < 11)
--   跳过 Granule 4 (08 < 16)
--   
--   结果: 只读取 1 个 granule, 跳过 75% 数据!
-- 
-- ================================================================================
-- 查询优化技巧
-- ================================================================================
-- 
--   ┌─────────────────────────────────────────────────────────────────────────┐
--   │                      慢查询 vs 快查询                                   │
--   └─────────────────────────────────────────────────────────────────────────┘
--   
--   ❌ 慢: 在 WHERE 中使用函数
--   ┌──────────────────────────────────────────────────────────────────────┐
--   │  WHERE toDate(event_time) = '2024-01-20'                             │
--   │        ^^^^^^^^^^^^^^^^                                              │
--   │        每行都要计算函数, 无法使用索引                                  │
--   └──────────────────────────────────────────────────────────────────────┘
--   
--   ✅ 快: 使用物化列或范围查询
--   ┌──────────────────────────────────────────────────────────────────────┐
--   │  WHERE event_date = '2024-01-20'                                     │
--   │        ^^^^^^^^^^^ 直接使用列, 可以用索引                             │
--   └──────────────────────────────────────────────────────────────────────┘
--   
--   ❌ 慢: 等值查询 DateTime
--   ┌──────────────────────────────────────────────────────────────────────┐
--   │  WHERE event_time = '2024-01-20 12:00:00'                            │
--   │        精确匹配, 很少命中                                              │
--   └──────────────────────────────────────────────────────────────────────┘
--   
--   ✅ 快: 范围查询
--   ┌──────────────────────────────────────────────────────────────────────┐
--   │  WHERE event_time >= '2024-01-20 12:00:00'                           │
--   │    AND event_time <  '2024-01-20 12:01:00'                           │
--   │        范围查询, 可以利用分区裁剪和索引                                │
--   └──────────────────────────────────────────────────────────────────────┘
-- 
-- ================================================================================

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
CREATE TABLE IF NOT EXISTS events_optimized (
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
CREATE TABLE IF NOT EXISTS events (
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
CREATE TABLE IF NOT EXISTS events_partitioned (
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
CREATE TABLE IF NOT EXISTS events (
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
CREATE TABLE IF NOT EXISTS time_series_optimized (
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
CREATE TABLE IF NOT EXISTS events_optimized (
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
