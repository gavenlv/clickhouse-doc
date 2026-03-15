-- =====================================================
-- 05 - Best Practices & Common Issues
-- =====================================================
-- Cluster: treasurycluster (2 replicas)
-- Time: 55-60 minutes
-- =====================================================

-- -----------------------------------------------------
-- 1. Table Design Best Practices
-- -----------------------------------------------------

-- 
-- ┌─────────────────────────────────────────────────────────────┐
-- │              Table Design Best Practices                     │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                             │
-- │  1. Choose the right table engine                           │
-- │     - 95%+ scenarios use MergeTree                          │
-- │     - High availability requirements use ReplicatedMergeTree│
-- │                                                             │
-- │  2. Design primary keys properly                            │
-- │     - High cardinality fields first                         │
-- │     - Frequently filtered fields first                      │
-- │     - Avoid using random values                            │
-- │                                                             │
-- │  3. Choose appropriate partition strategy                   │
-- │     - Log/time series: toYYYYMMDD                          │
-- │     - Historical data: toYYYYMM                            │
-- │     - Small tables: No partition                            │
-- │                                                             │
-- │  4. Use appropriate data types                              │
-- │     - Integers: UInt8/16/32/64                             │
-- │     - Strings: String / FixedString                       │
-- │     - Enums: Enum8/16                                      │
-- │     - Repeated strings: LowCardinality(String)             │
-- │                                                             │
-- │  5. Avoid NULL                                              │
-- │     - Nullable increases storage and compute overhead        │
-- │     - Use default values instead of NULL                   │
-- │                                                             │
-- └─────────────────────────────────────────────────────────────┘

-- -----------------------------------------------------
-- 2. Data Type Optimization
-- -----------------------------------------------------

-- Low cardinality string optimization: LowCardinality (Replicated)
-- DROP TABLE IF EXISTS users ON CLUSTER treasurycluster SYNC;

-- Clean up any existing replicas
-- DROP TABLE IF EXISTS users ON CLUSTER treasurycluster SYNC;

CREATE TABLE users ON CLUSTER treasurycluster (
    user_id UInt32,
    username LowCardinality(String),
    country LowCardinality(String),
    status Enum8('active' = 1, 'inactive' = 2, 'pending' = 3)
) ENGINE = ReplicatedMergeTree()
ORDER BY user_id;

-- Insert test data
INSERT INTO users
SELECT 
    number AS user_id,
    'user_' || toString(number) AS username,
    ['US', 'CN', 'UK', 'JP', 'DE'][number % 5 + 1] AS country,
    CAST(number % 3 + 1 AS Enum8('active' = 1, 'inactive' = 2, 'pending' = 3)) AS status
FROM numbers(1000000);

-- View storage comparison
SELECT 
    'LowCardinality' AS type,
    formatReadableSize(sum(data_compressed_bytes)) AS compressed,
    formatReadableSize(sum(data_uncompressed_bytes)) AS uncompressed
FROM system.parts_columns
WHERE database = 'playground' AND table = 'users' AND column IN ('username', 'country');

-- 
-- ┌─────────────────────────────────────────────────────────────┐
-- │              LowCardinality Optimization Effect             │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                             │
-- │  Regular String:                                            │
-- │  ┌─────────────────────────────────────────────────────┐   │
-- │  │  1M rows × 20 bytes = 20MB (uncompressed)           │   │
-- │  │  Actual storage: ~15MB                              │   │
-- │  └─────────────────────────────────────────────────────┘   │
-- │                                                             │
-- │  LowCardinality(String):                                    │
-- │  ┌─────────────────────────────────────────────────────┐   │
-- │  │  Dictionary: 1M unique values × 20 bytes = 20MB     │   │
-- │  │  Data: 1M rows × 4 bytes = 4MB                     │   │
-- │  │  Actual storage: ~8MB (includes dictionary)         │   │
-- │  └─────────────────────────────────────────────────────┘   │
-- │                                                             │
-- │  Performance improvement: 30-50% faster queries            │
-- │                                                             │
-- └─────────────────────────────────────────────────────────────┘

-- -----------------------------------------------------
-- 3. Sharding Key Selection
-- -----------------------------------------------------

-- 
-- ┌─────────────────────────────────────────────────────────────┐
-- │              Sharding Key Selection Principles               │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                             │
-- │  Selection criteria:                                         │
-- │  1. Even distribution: Avoid data skew                     │
-- │  2. Often queried together: Reduce cross-shard JOIN       │
-- │  3. Often filtered: Use shard pruning                     │
-- │                                                             │
-- │  Common sharding keys:                                      │
-- │  - user_id: User behavior analysis                         │
-- │  - date/time: Time series data                             │
-- │  - region/country: Geographic analysis                     │
-- │  - tenant_id: Multi-tenant scenarios                       │
-- │                                                             │
-- │  Avoid:                                                     │
-- │  - Random values (sharding_key = rand())                  │
-- │  - Low cardinality values (causes data skew)               │
-- │                                                             │
-- └─────────────────────────────────────────────────────────────┘

-- -----------------------------------------------------
-- 4. Write Optimization
-- -----------------------------------------------------

-- 
-- ┌─────────────────────────────────────────────────────────────┐
-- │              Write Best Practices                           │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                             │
-- │  1. Batch writes                                            │
-- │     - 1000-10000 rows per batch                            │
-- │     - Avoid single row INSERT                              │
-- │                                                             │
-- │  2. Asynchronous writes                                     │
-- │     - Use Buffer table + background flush                  │
-- │     - Reduce synchronous wait                               │
-- │                                                             │
-- │  3. Avoid small files                                      │
-- │     - Part files < 10MB affect performance                │
-- │     - Use max_insert_block_size to control                 │
-- │                                                             │
-- │  4. Write timing                                            │
-- │     - Avoid massive writes during peak business hours      │
-- │     - Use TTL to clean up historical data                 │
-- │                                                             │
-- └─────────────────────────────────────────────────────────────┘

-- Create Buffer table demo (Replicated)
DROP TABLE IF EXISTS bp_events ON CLUSTER treasurycluster SYNC;
DROP TABLE IF EXISTS bp_events_buffer SYNC;

CREATE TABLE bp_events (
    event_id UInt64,
    event_time DateTime,
    event_type String
) ENGINE = ReplicatedMergeTree()
ORDER BY event_time;

CREATE TABLE bp_events_buffer AS bp_events
ENGINE = Buffer(playground, 4, 10, 100, 10000, 1000000, 10000000, 100000000);

-- Write to Buffer table
INSERT INTO bp_events_buffer 
SELECT number, now(), 'click' FROM numbers(10000);

-- View Buffer status
SELECT 
    database,
    table,
    num_layers,
    is_stale
FROM system.buffers
WHERE database = 'playground';

-- Flush Buffer
SYSTEM FLUSH TABLES bp_events_buffer;

SELECT count() FROM bp_events;

-- -----------------------------------------------------
-- 5. Common Errors & Solutions
-- -----------------------------------------------------

-- 
-- ┌─────────────────────────────────────────────────────────────┐
-- │              Common Errors & Solutions                      │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                             │
-- │  Error 1: Too many parts                                   │
-- │  ┌─────────────────────────────────────────────────────┐   │
-- │  │ Cause: Writing too fast, background merge can't    │   │
-- │  │        keep up                                       │   │
-- │  │ Solution: Batch writes, adjust                      │   │
-- │  │   max_parts_to_merge_at_once                          │   │
-- │  └─────────────────────────────────────────────────────┘   │
-- │                                                             │
-- │  Error 2: Memory limit exceeded                            │
-- │  ┌─────────────────────────────────────────────────────┐   │
-- │  │ Cause: Single query data volume too large           │   │
-- │  │ Solution: Use LIMIT, partition pruning, PREWHERE     │   │
-- │  └─────────────────────────────────────────────────────┘   │
-- │                                                             │
-- │  Error 3: Block ... has wrong column                      │
-- │  ┌─────────────────────────────────────────────────────┐   │
-- │  │ Cause: Write data type mismatch                     │   │
-- │  │ Solution: Ensure field order and type are correct   │   │
-- │  └─────────────────────────────────────────────────────┘   │
-- │                                                             │
-- │  Error 4: Part is committed twice                         │
-- │  ┌─────────────────────────────────────────────────────┐   │
-- │  │ Cause: Duplicate write of same primary key data    │   │
-- │  │ Solution: Use ReplacingMergeTree or deduplication  │   │
-- │  └─────────────────────────────────────────────────────┘   │
-- │                                                             │
-- └─────────────────────────────────────────────────────────────┘

-- -----------------------------------------------------
-- 6. Monitoring & Tuning
-- -----------------------------------------------------

-- View system health status
SELECT 
    'Parts' AS metric,
    (SELECT count() FROM system.parts WHERE active = 1) AS active_parts,
    (SELECT count() FROM system.parts WHERE active = 0) AS inactive_parts
UNION ALL
SELECT 
    'Queries' AS metric,
    (SELECT count() FROM system.query_log WHERE type = 'QueryFinish' AND event_time > now() - INTERVAL 1 HOUR) AS queries_1h,
    NULL
UNION ALL
SELECT 
    'Errors' AS metric,
    (SELECT count() FROM system.query_log WHERE type = 'Exception' AND event_time > now() - INTERVAL 1 HOUR) AS errors_1h,
    NULL;

-- View slow queries
SELECT 
    query,
    formatReadableSize(read_bytes) AS read_size,
    read_rows,
    query_duration_ms / 1000 AS duration_sec
FROM system.query_log
WHERE type = 'QueryFinish' 
  AND event_time > now() - INTERVAL 1 HOUR
  AND query_duration_ms > 1000
ORDER BY query_duration_ms DESC
LIMIT 10;

-- View memory usage
SELECT 
    metric,
    formatReadableSize(value) AS size
FROM system.metrics
WHERE metric LIKE '%Memory%'
ORDER BY metric;

-- 
-- ┌─────────────────────────────────────────────────────────────┐
-- │              Key Monitoring Metrics                         │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                             │
-- │  System health:                                             │
-- │  - active_parts: Number of active Parts                    │
-- │  - total_rows: Total data rows                             │
-- │  - query_count: Query count                                │
-- │                                                             │
-- │  Performance metrics:                                        │
-- │  - query_duration_ms: Query duration                        │
-- │  - read_rows: Number of rows read                          │
-- │  - memory_usage: Memory usage                              │
-- │                                                             │
-- │  Alert thresholds:                                          │
-- │  - Parts > 300: Writing too fast                           │
-- │  - Query > 10s: Needs optimization                         │
-- │  - Memory > 80%: Insufficient resources                    │
-- │                                                             │
-- └─────────────────────────────────────────────────────────────┘

-- -----------------------------------------------------
-- 7. ETL vs ClickHouse Responsibility Division
-- -----------------------------------------------------

-- 
-- ┌─────────────────────────────────────────────────────────────┐
-- │              ETL vs ClickHouse Responsibilities             │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                             │
-- │  ETL should do:                                             │
-- │  ✓ Data cleaning: NULL handling, format conversion        │
-- │  ✓ Data transformation: Encoding, normalization             │
-- │  ✓ Data aggregation: Pre-aggregation, dimension tables     │
-- │  ✓ Data layering: ODS → DWD → DWS                          │
-- │  ✓ Historical data: Regular archival and cleanup           │
-- │                                                             │
-- │  ClickHouse should do:                                      │
-- │  ✓ High-speed analysis: Ad-hoc queries                    │
-- │  ✓ Large data aggregation: COUNT/SUM/AVG                  │
-- │  ✓ Real-time computation: Latest data real-time analysis  │
-- │  ✓ Multi-dimensional analysis: Any dimension combination   │
-- │                                                             │
-- │  ✗ Avoid: Frequent small updates, transaction processing,  │
-- │    JOIN large tables                                        │
-- │                                                             │
-- └─────────────────────────────────────────────────────────────┘

-- -----------------------------------------------------
-- 8. Chapter Summary
-- -----------------------------------------------------

-- 
-- ┌─────────────────────────────────────────────────────────────┐
-- │              Summary: ClickHouse Best Practices             │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                             │
-- │  Table design:                                              │
-- │  - Use MergeTree engine                                    │
-- │  - Properly design primary keys and partitions             │
-- │  - Use LowCardinality to optimize strings                 │
-- │                                                             │
-- │  Query optimization:                                        │
-- │  - Avoid SELECT *                                          │
-- │  - Use partition pruning                                   │
-- │  - Reasonably use materialized views                       │
-- │                                                             │
-- │  Write optimization:                                        │
-- │  - Batch writes (1000-10000 rows/batch)                    │
-- │  - Avoid massive writes during peak hours                  │
-- │                                                             │
-- │  Operations monitoring:                                     │
-- │  - Focus on Parts count                                    │
-- │  - Regularly analyze slow queries                          │
-- │  - Monitor memory usage                                    │
-- │                                                             │
-- └─────────────────────────────────────────────────────────────┘

-- Verify completion
SELECT 
    'ClickHouse 1-hour presentation' AS topic,
    'Completed' AS status,
    now() AS completed_at;
