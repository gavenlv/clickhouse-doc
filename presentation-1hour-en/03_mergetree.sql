-- =====================================================
-- 03 - MergeTree Engine Core Principles
-- =====================================================
-- Cluster: treasurycluster (2 replicas)
-- Time: 35-45 minutes
-- =====================================================

-- -----------------------------------------------------
-- 1. MergeTree Family Overview
-- -----------------------------------------------------

-- 
-- ┌─────────────────────────────────────────────────────────────┐
-- │              MergeTree Engine Family                         │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                             │
-- │  MergeTree (Core)                                           │
-- │  ├── ReplicatedMergeTree - Supports replication            │
-- │  │   ├── ReplicatedMergeTree ZooKeeper                     │
-- │  │   └── ReplicatedMergeTreeS3 - Supports S3 storage       │
-- │  │                                                      │
-- │  ├── SummingMergeTree - Auto-aggregate same keys           │
-- │  ├── AggregatingMergeTree - Pre-aggregation                │
-- │  ├── CollapsingMergeTree - Delete marker collapse         │
-- │  ├── VersionedCollapsingMergeTree - Versioned collapse    │
-- │  │                                                      │
-- │  └── ReplacingMergeTree - Version number replacement       │
-- │                                                             │
-- └─────────────────────────────────────────────────────────────┘

-- View MergeTree family engines
SELECT name FROM system.table_engines 
WHERE name LIKE '%MergeTree%';

-- -----------------------------------------------------
-- 2. MergeTree Core Concepts
-- -----------------------------------------------------

-- 
-- ┌─────────────────────────────────────────────────────────────┐
-- │              MergeTree Core Concepts                        │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                             │
-- │  ORDER BY (Required):                                       │
-- │  - Determines physical data storage order                  │
-- │  - Affects index structure                                  │
-- │  - Recommendation: Put frequently filtered columns first   │
-- │                                                             │
-- │  PARTITION BY (Optional):                                   │
-- │  - Data partition granularity                               │
-- │  - Common: toYYYYMM, toYYYYMMDD, toYYYYMMDDhhmmss        │
-- │  - Affects partition pruning efficiency                     │
-- │                                                             │
-- │  PRIMARY KEY (Optional):                                    │
-- │  - Defaults to ORDER BY                                     │
-- │  - Can be set to different order                           │
-- │                                                             │
-- │  SAMPLE BY (Optional):                                     │
-- │  - Data sampling key                                        │
-- │  - Supports SAMPLE 1000000 queries                         │
-- │                                                             │
-- │  SETTINGS:                                                  │
-- │  - index_granularity: 8192 (default)                       │
-- │  - min_bytes_for_wide_part: Set to enable wide format      │
-- │                                                             │
-- └─────────────────────────────────────────────────────────────┘

-- -----------------------------------------------------
-- 3. Data Writing and Part Files
-- -----------------------------------------------------

-- Use playground database
USE playground;

-- Create demo table (Replicated)
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

-- Insert data in batches to simulate multiple parts
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

-- View generated parts
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
-- │              Part File Structure                            │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                             │
-- │  part_1_3_0/                                                │
-- │  ├── checksums.txt      ← Checksums                         │
-- │  ├── columns.txt        ← Column info                       │
-- │  ├── count.txt          ← Row count                         │
-- │  ├── primary.idx        ← Primary key index                 │
-- │  ├── event_id.bin      ← Data files                         │
-- │  ├── event_id.mrk2      ├── Mark files                       │
-- │  ├── user_id.bin                                           │
-- │  ├── user_id.mrk2                                          │
-- │  ├── event_time.bin                                        │
-- │  ├── event_time.mrk2                                        │
-- │  ├── event_type.bin                                        │
-- │  ├── event_type.mrk2                                       │
-- │  ├── payload.bin                                           │
-- │  └── payload.mrk2                                          │
-- │                                                             │
-- │  .bin = Compressed column data                              │
-- │  .mrk2 = Index mark files (mapping to .bin locations)       │
-- │                                                             │
-- └─────────────────────────────────────────────────────────────┘

-- -----------------------------------------------------
-- 4. Background Merge Demo
-- -----------------------------------------------------

-- Manually trigger merge
OPTIMIZE TABLE events FINAL;

-- View parts again
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
-- │              Before vs After Merge                           │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                             │
-- │  Before merge (3 parts):                                   │
-- │  ┌─────────────────────────────────────────────────────┐   │
-- │  │ Part_1_1_0  (10K rows)                              │   │
-- │  │ Part_2_1_0  (10K rows)                              │   │
-- │  │ Part_3_1_0  (10K rows)                              │   │
-- │  └─────────────────────────────────────────────────────┘   │
-- │                                                             │
-- │  After merge (1 part):                                    │
-- │  ┌─────────────────────────────────────────────────────┐   │
-- │  │ Part_1_3_1  (30K rows)                              │   │
-- │  └─────────────────────────────────────────────────────┘   │
-- │                                                             │
-- │  Benefits:                                                  │
-- │  - Reduce file count                                       │
-- │  - Improve scan efficiency                                 │
-- │  - Free up disk space                                     │
-- │                                                             │
-- └─────────────────────────────────────────────────────────────┘

-- -----------------------------------------------------
-- 5. Primary Key Selection Principles
-- -----------------------------------------------------

-- 
-- ┌─────────────────────────────────────────────────────────────┐
-- │              Primary Key Selection Best Practices            │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                             │
-- │  Principle 1: High cardinality fields first                 │
-- │  ┌─────────────────────────────────────────────────────┐   │
-- │  │  Low cardinality: [A,A,A,B,B,B] → Poor filtering │   │
-- │  │  High cardinality: [1,2,3,4,5,6] → Good filtering│   │
-- │  └─────────────────────────────────────────────────────┘   │
-- │                                                             │
-- │  Principle 2: Frequently filtered columns first            │
-- │  - Columns often used in WHERE clause                        │
-- │                                                             │
-- │  Principle 3: Avoid using random values as primary key      │
-- │  - Causes excessive merges during writes                    │
-- │                                                             │
-- │  Principle 4: Composite keys should not exceed 3-4 fields   │
-- │  - Index file becomes larger                                │
-- │                                                             │
-- └─────────────────────────────────────────────────────────────┘

-- Create tables with different primary keys for comparison (Replicated)
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

-- Insert same data
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

-- Compare query performance
SET max_threads = 1;

SELECT count() FROM good_key WHERE event_type = 'A';
SELECT count() FROM bad_key WHERE event_type = 'A';

-- View execution plan
EXPLAIN PLAN SELECT count() FROM good_key WHERE event_type = 'A';
EXPLAIN PLAN SELECT count() FROM bad_key WHERE event_type = 'A';

-- -----------------------------------------------------
-- 6. Partition Strategy
-- -----------------------------------------------------

-- 
-- ┌─────────────────────────────────────────────────────────────┐
-- │              Partition Strategy Selection                    │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                             │
-- │  Partition by day: toYYYYMMDD                               │
-- │  ✓ Large data volume, need fast location                   │
-- │  ✓ Supports DELETE operation                                │
-- │  ✗ Many Part files                                        │
-- │                                                             │
-- │  Partition by month: toYYYYMM                              │
-- │  ✓ Moderate number of Parts                               │
-- │  ✓ Suitable for historical data analysis                   │
-- │  ✗ Coarser granularity                                    │
-- │                                                             │
-- │  No partition:                                              │
-- │  ✓ Small data volume                                        │
-- │  ✓ Avoid cross-partition queries                           │
-- │  ✗ Cannot prune partitions                                 │
-- │                                                             │
-- │  Recommendation:                                             │
-- │  - Log/time series: toYYYYMMDD                            │
-- │  - Historical archive: toYYYYMM                            │
-- │  - Small tables: No partition                              │
-- │                                                             │
-- └─────────────────────────────────────────────────────────────┘

-- Create tables with different partition strategies (Replicated)
DROP TABLE IF EXISTS partition_by_day ON CLUSTER treasurycluster SYNC;
CREATE TABLE partition_by_day (
    id UInt64,
    created_at DateTime,
    data String
) ENGINE = ReplicatedMergeTree()
PARTITION BY toYYYYMMDD(created_at)
ORDER BY id;

DROP TABLE IF EXISTS partition_by_month ON CLUSTER treasurycluster SYNC;
CREATE TABLE partition_by_month (
    id UInt64,
    created_at DateTime,
    data String
) ENGINE = ReplicatedMergeTree()
PARTITION BY toYYYYMM(created_at)
ORDER BY id;

DROP TABLE IF EXISTS no_partition ON CLUSTER treasurycluster SYNC;
CREATE TABLE no_partition (
    id UInt64,
    created_at DateTime,
    data String
) ENGINE = ReplicatedMergeTree()
ORDER BY id;

-- Insert test data
INSERT INTO partition_by_day
SELECT number, toDateTime('2024-01-01') + number * 86400, 'data'
FROM numbers(100);

INSERT INTO partition_by_month
SELECT number, toDateTime('2024-01-01') + number * 86400, 'data'
FROM numbers(100);

INSERT INTO no_partition
SELECT number, toDateTime('2024-01-01') + number * 86400, 'data'
FROM numbers(100);

-- Compare Part count
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
-- 7. MergeTree Variants
-- -----------------------------------------------------

-- SummingMergeTree: Auto-aggregate (Replicated)
DROP TABLE IF EXISTS summing_demo ON CLUSTER treasurycluster SYNC;

CREATE TABLE summing_demo (
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

-- Trigger merge and view result
OPTIMIZE TABLE summing_demo FINAL;

SELECT * FROM summing_demo;

-- AggregatingMergeTree: Pre-aggregate (Replicated)
DROP TABLE IF EXISTS agg_demo ON CLUSTER treasurycluster SYNC;

CREATE TABLE agg_demo (
    date Date,
    user_id UInt32,
    revenue SimpleAggregateFunction(sum, Float64)
) ENGINE = ReplicatedAggregatingMergeTree()
PARTITION BY toYYYYMM(date)
ORDER BY (date, user_id);

INSERT INTO agg_demo VALUES 
    ('2024-01-01', 1, 100),
    ('2024-01-01', 1, 200);

-- Use materialized view to implement pre-aggregation (Replicated)
-- DROP MATERIALIZED VIEW IF EXISTS agg_view ON CLUSTER treasurycluster SYNC;
-- CREATE MATERIALIZED VIEW agg_view
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
-- 8. Chapter Summary
-- -----------------------------------------------------

-- 
-- ┌─────────────────────────────────────────────────────────────┐
-- │              Chapter Key Points                             │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                             │
-- │  1. MergeTree is the core storage engine of ClickHouse      │
-- │  2. ORDER BY must be specified, determines physical order   │
-- │  3. PARTITION BY affects query performance and data         │
-- │     management                                               │
-- │  4. Background auto-merge optimizes storage                 │
-- │  5. Primary key selection: High cardinality first, avoid   │
-- │     random values                                           │
-- │  6. Variants: SummingMergeTree, AggregatingMergeTree        │
-- │                                                             │
-- │  Next: 04_query_optimization.sql - Query optimization      │
-- │     techniques                                              │
-- │                                                             │
-- └─────────────────────────────────────────────────────────────┘

SELECT 
    'mergetree' AS chapter,
    (SELECT count() FROM system.parts WHERE database = 'playground') AS total_parts;
