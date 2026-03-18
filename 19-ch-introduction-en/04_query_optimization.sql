-- =====================================================
-- 04 - Query Optimization Techniques & Practices
-- =====================================================
-- 
-- Cluster: treasurycluster (2 replicas)
-- Estimated Learning Time: 30 minutes
-- 
-- This file covers:
--   1. Query Optimization Principles - Reduce Data Read Volume
--   2. PREWHERE Optimization - Filter Ahead to Reduce IO
--   3. Index Utilization Techniques - Primary Index/Skip Index/Projection
--   4. Partition Pruning Optimization - Quick Location by Time Range
--   5. Aggregation Query Optimization - GROUP BY/Window Functions
--   6. JOIN Query Optimization - JOIN Order and Type Selection
--   7. Query Analysis Tools - EXPLAIN and Performance Diagnosis
--   8. Common Anti-Patterns - Performance Killers and Avoidance Methods
-- 
-- =====================================================

-- -----------------------------------------------------
-- 1. Query Optimization Core Principles
-- -----------------------------------------------------

-- 
-- ┌─────────────────────────────────────────────────────────────┐
-- │              ClickHouse Query Optimization Core Principles │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                             │
-- │  1. Column Pruning                                         │
-- │     - Only SELECT needed columns                           │
-- │     - Avoid SELECT *                                        │
-- │                                                             │
-- │  2. Predicate Pushdown                                    │
-- │     - WHERE conditions as close to data source as possible │
-- │     - Reduce data read volume                              │
-- │                                                             │
-- │  3. Partition Pruning                                     │
-- │     - Use PARTITION BY to filter                           │
-- │     - Avoid full table scan                               │
-- │                                                             │
-- │  4. Index Utilization                                     │
-- │     - Use primary key index for fast location              │
-- │     - Use skip index                                      │
-- │                                                             │
-- │  5. Data Sampling                                         │
-- │     - Use SAMPLE for large data volumes                   │
-- │     - Fast understanding of data distribution             │
-- │                                                             │
-- └─────────────────────────────────────────────────────────────┘

-- Use playground database
USE playground;

-- Create test table (Replicated)
DROP TABLE IF EXISTS opt_events ON CLUSTER treasurycluster SYNC;

CREATE TABLE opt_events ON CLUSTER treasurycluster (
    event_id UInt64,
    user_id UInt32,
    event_time DateTime,
    event_type Enum8('click' = 1, 'view' = 2, 'purchase' = 3),
    category String,
    country String,
    revenue Float64,
    payload String
) ENGINE = ReplicatedMergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_type, user_id, event_time);

-- Insert 1M rows of test data
INSERT INTO opt_events
SELECT 
    number AS event_id,
    number % 50000 AS user_id,
    toDateTime('2024-01-01 00:00:00') + number * 60 AS event_time,
    CAST(number % 3 + 1 AS Enum8('click' = 1, 'view' = 2, 'purchase' = 3)) AS event_type,
    ['Electronics', 'Clothing', 'Food', 'Books', 'Sports'][number % 5 + 1] AS category,
    ['US', 'CN', 'UK', 'JP', 'DE', 'FR'][number % 6 + 1] AS country,
    if(number % 10 = 0, rand() % 500, 0) AS revenue,
    repeat('x', 100) AS payload
FROM numbers(1000000);

-- -----------------------------------------------------
-- 2. Column Pruning Optimization
-- -----------------------------------------------------

-- Bad practice: SELECT *
SELECT count() FROM opt_events;

-- Good practice: Only select needed columns
SELECT 
    user_id,
    event_type,
    revenue
FROM opt_events
LIMIT 10;

-- Compare performance
SET max_threads = 1;

-- Not recommended
EXPLAIN ESTIMATE SELECT * FROM opt_events WHERE event_type = 'purchase';

-- Recommended
EXPLAIN ESTIMATE SELECT event_type, revenue FROM opt_events WHERE event_type = 'purchase';

-- 
-- ┌─────────────────────────────────────────────────────────────┐
-- │              Column Pruning Effect Comparison               │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                             │
-- │  SELECT * FROM events WHERE event_type = 'purchase'        │
-- │  ┌─────────────────────────────────────────────────────┐   │
-- │  │  Read all columns + payload (100 bytes)             │   │
-- │  │  Estimated read: ~150 MB                             │   │
-- │  └─────────────────────────────────────────────────────┘   │
-- │                                                             │
-- │  SELECT event_type, revenue FROM events WHERE event_type  │
-- │  ┌─────────────────────────────────────────────────────┐   │
-- │  │  Only read 2 columns (~12 bytes)                     │   │
-- │  │  Estimated read: ~15 MB                              │   │
-- │  └─────────────────────────────────────────────────────┘   │
-- │                                                             │
-- │  Improvement: 10x                                           │
-- │                                                             │
-- └─────────────────────────────────────────────────────────────┘

-- -----------------------------------------------------
-- 3. PREWHERE Optimization
-- -----------------------------------------------------

-- PREWHERE: Read filter column first, then read target columns
-- Suitable when: filter column and target column are different

-- Use PREWHERE
SELECT event_id, event_type
FROM opt_events
PREWHERE event_type = 'purchase'
WHERE revenue > 100
LIMIT 100;

-- ClickHouse automatically uses PREWHERE
SELECT event_id, event_type, revenue
FROM opt_events
WHERE event_type = 'purchase' AND revenue > 100
LIMIT 100;

-- -----------------------------------------------------
-- 4. Partition Pruning
-- -----------------------------------------------------

-- View partitions
SELECT 
    partition,
    sum(rows) AS total_rows,
    formatReadableSize(sum(bytes)) AS size
FROM system.parts
WHERE database = 'playground' AND table = 'opt_events' AND active = 1
GROUP BY partition
ORDER BY partition;

-- Good query: Use partition pruning
SELECT count(), sum(revenue)
FROM opt_events
WHERE event_time >= '2024-01-01' AND event_time < '2024-01-02';

-- Bad query: Cannot use partition pruning
SELECT count(), sum(revenue)
FROM opt_events
WHERE toDayOfWeek(event_time) = 1;

-- 
-- ┌─────────────────────────────────────────────────────────────┐
-- │              Partition Pruning Effect Comparison             │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                             │
-- │  WHERE event_time >= '2024-01-01'                         │
-- │  ┌─────────────────────────────────────────────────────┐   │
-- │  │  Only scan Jan 1st partition                        │   │
-- │  │  Estimated read: ~50 MB                             │   │
-- │  └─────────────────────────────────────────────────────┘   │
-- │                                                             │
-- │  WHERE toDayOfWeek(event_time) = 1                         │
-- │  ┌─────────────────────────────────────────────────────┐   │
-- │  │  Need to scan all partitions                        │   │
-- │  │  Estimated read: ~1 GB                              │   │
-- │  └─────────────────────────────────────────────────────┘   │
-- │                                                             │
-- │  Improvement: 20x                                          │
-- │                                                             │
-- └─────────────────────────────────────────────────────────────┘

-- -----------------------------------------------------
-- 5. Using Skipping Index
-- -----------------------------------------------------

-- Create table with skip index (Replicated)
DROP TABLE IF EXISTS events_with_skip_idx ON CLUSTER treasurycluster SYNC;

CREATE TABLE events_with_skip_idx ON CLUSTER treasurycluster (
    event_id UInt64,
    user_id UInt32,
    event_time DateTime,
    event_type Enum8('click' = 1, 'view' = 2, 'purchase' = 3),
    category String,
    country String,
    revenue Float64
) ENGINE = ReplicatedMergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_type, user_id, event_time)
SETTINGS index_granularity = 8192;

-- Add skip index
ALTER TABLE events_with_skip_idx 
ADD INDEX idx_category category TYPE set(100) GRANULARITY 4;

ALTER TABLE events_with_skip_idx 
ADD INDEX idx_country country TYPE bloom_filter GRANULARITY 1;

-- Insert data
INSERT INTO events_with_skip_idx
SELECT 
    event_id, user_id, event_time, event_type, category, country, revenue
FROM opt_events LIMIT 100000;

-- View skip index
SELECT 
    name,
    type,
    granularity
FROM system.data_skipping_indices
WHERE database = 'playground' AND table = 'events_with_skip_idx';

-- -----------------------------------------------------
-- 6. Data Sampling
-- -----------------------------------------------------

-- Create table that supports sampling (Replicated)
DROP TABLE IF EXISTS events_sampled ON CLUSTER treasurycluster SYNC;

CREATE TABLE events_sampled ON CLUSTER treasurycluster (
    event_id UInt64,
    user_id UInt32,
    event_time DateTime,
    event_type Enum8('click' = 1, 'view' = 2, 'purchase' = 3)
) ENGINE = ReplicatedMergeTree()
ORDER BY event_id
SAMPLE BY event_id;

INSERT INTO events_sampled 
SELECT event_id, user_id, event_time, event_type
FROM opt_events LIMIT 100000;

-- Use SAMPLE (requires SAMPLE BY)
-- SAMPLE 1000000: Sample approximately 1M rows
-- SAMPLE 0.1: Sample 10% of data
-- SAMPLE 1/10: Sample 1/10 of data

-- Normal query
SELECT count(), uniqExact(user_id) FROM events_sampled;

-- Sample query (use SAMPLE BY)
-- SELECT count(), uniqExact(user_id) FROM events_sampled SAMPLE 1000000;

-- 
-- ┌─────────────────────────────────────────────────────────────┐
-- │              Sample Query Use Cases                         │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                             │
-- │  ✓ Fast understanding of data distribution                  │
-- │  ✓ Fast return results during development debugging          │
-- │  ✓ Approximate computation (use SAMPLE + multiplication)    │
-- │     factor                                                 │
-- │                                                             │
-- │  ✗ Exact COUNT needs to be divided by sampling ratio       │
-- │  ✗ Some aggregate functions don't support sampling          │
-- │                                                             │
-- │  Example:                                                   │
-- │  SELECT sum(col) * 10 FROM table SAMPLE 0.1                │
-- │                                                             │
-- └─────────────────────────────────────────────────────────────┘

-- -----------------------------------------------------
-- 7. Approximate Aggregation
-- -----------------------------------------------------

-- uniqExact → uniq
SELECT 
    'uniqExact' AS method,
    uniqExact(user_id) AS result
FROM opt_events
WHERE event_type = 'purchase';

-- uniq (approximate, low memory)
SELECT 
    'uniq' AS method,
    uniq(user_id) AS result
FROM opt_events
WHERE event_type = 'purchase';

-- quantile → quantileExact
SELECT 
    quantile(0.5)(revenue) AS median_revenue,
    quantile(0.95)(revenue) AS p95_revenue
FROM opt_events;

-- 
-- ┌─────────────────────────────────────────────────────────────┐
-- │              Approximate Aggregate Function Comparison      │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                             │
-- │  Function       │ Accuracy │ Memory │ Speed               │
-- │  ───────────────┼──────────┼─────────┼───────────────      │
-- │  uniqExact     │  100%    │  High   │  Slow               │
-- │  uniq          │  ~99%    │  Low    │  Fast               │
-- │  quantileExact │ 100%     │  High   │  Slow               │
-- │  quantile      │  ~99%    │  Low    │  Fast               │
-- │                                                             │
-- └─────────────────────────────────────────────────────────────┘

-- -----------------------------------------------------
-- 8. Materialized View Optimization
-- -----------------------------------------------------

-- Create aggregated materialized view (Replicated)
DROP TABLE IF EXISTS mv_daily_stats ON CLUSTER treasurycluster SYNC;
CREATE TABLE mv_daily_stats ON CLUSTER treasurycluster (
    date Date,
    event_type Enum8('click' = 1, 'view' = 2, 'purchase' = 3),
    category String,
    event_count UInt64,
    unique_users UInt64,
    total_revenue Float64
) ENGINE = ReplicatedSummingMergeTree()
PARTITION BY toYYYYMM(date)
ORDER BY (date, event_type, category);

-- DROP MATERIALIZED VIEW IF EXISTS mv_daily_stats_mv ON CLUSTER treasurycluster SYNC;
CREATE MATERIALIZED VIEW mv_daily_stats_mv
ENGINE = ReplicatedSummingMergeTree()
PARTITION BY toYYYYMM(date)
ORDER BY (date, event_type, category) AS
SELECT 
    toDate(event_time) AS date,
    event_type,
    category,
    count() AS event_count,
    uniqExact(user_id) AS unique_users,
    sum(revenue) AS total_revenue
FROM opt_events
GROUP BY 
    toDate(event_time),
    event_type,
    category;

-- View materialized view data
SELECT * FROM mv_daily_stats ORDER BY date DESC LIMIT 10;

-- Compare query performance
SET max_threads = 1;

-- Direct query
SELECT 
    event_type,
    count() AS cnt,
    sum(revenue) AS revenue
FROM opt_events
WHERE event_type = 'purchase'
GROUP BY event_type;

-- Query materialized view
SELECT 
    event_type,
    event_count AS cnt,
    total_revenue AS revenue
FROM mv_daily_stats
WHERE event_type = 'purchase';

-- 
-- ┌─────────────────────────────────────────────────────────────┐
-- │              Materialized View vs Direct Query               │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                             │
-- │  Direct query:                                              │
-- │  - Full table scan every time                               │
-- │  - 1M rows → Slow                                          │
-- │                                                             │
-- │  Materialized view:                                         │
-- │  - Pre-aggregated results                                  │
-- │  - Thousands of rows → Fast                                │
-- │                                                             │
-- │  Use cases:                                                 │
-- │  ✓ Repeated aggregate queries                               │
-- │  ✓ Real-time requirements not high for reports              │
-- │  ✓ Multi-dimensional analysis                               │
-- │                                                             │
-- └─────────────────────────────────────────────────────────────┘

-- -----------------------------------------------------
-- 9. Chapter Summary
-- -----------------------------------------------------

-- 
-- ┌─────────────────────────────────────────────────────────────┐
-- │              Chapter Key Points                             │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                             │
-- │  1. Column pruning: Only select needed columns, avoid      │
-- │     SELECT *                                                │
-- │  2. PREWHERE: Filter first, then read other columns         │
-- │  3. Partition pruning: Use WHERE conditions to skip        │
-- │     irrelevant partitions                                    │
-- │  4. Skip Index: For filter condition columns               │
-- │  5. Data sampling: SAMPLE accelerates development          │
-- │     debugging                                               │
-- │  6. Approximate aggregation: uniq, quantile reduce memory   │
-- │  7. Materialized view: Pre-aggregate repeated queries       │
-- │                                                             │
-- │  Next: 05_best_practices.sql - Best practices & common      │
-- │     issues                                                 │
-- │                                                             │
-- └─────────────────────────────────────────────────────────────┘

SELECT 
    'optimization' AS chapter,
    (SELECT sum(rows) FROM system.parts WHERE database = 'playground' AND table = 'opt_events' AND active = 1) AS total_rows;
