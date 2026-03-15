-- =====================================================
-- 01 - ClickHouse Introduction & Core Advantages
-- =====================================================
-- Cluster: treasurycluster (2 replicas)
-- Time: 0-20 minutes
-- =====================================================

-- -----------------------------------------------------
-- 1. What is ClickHouse?
-- -----------------------------------------------------

-- ClickHouse is a columnar storage database for OLAP scenarios
-- Features: Vectorized execution, Columnar storage, Distributed architecture

SELECT 
    'ClickHouse' AS product,
    'Columnar Database' AS type,
    'Apache 2.0' AS license,
    '2016' AS open_source_year;

-- -----------------------------------------------------
-- 2. Why is ClickHouse so fast?
-- -----------------------------------------------------

-- Core advantages comparison diagram:
-- 
-- ┌─────────────────────────────────────────────────────────────┐
-- │              ClickHouse Performance Advantages                │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                              │
-- │  1. Columnar Storage                                         │
-- │     ┌─────────────────────────────────────────────────────┐ │
-- │     │  id:  [1,2,3,4,5]     name: [A,B,C,D,E]            │ │
-- │     │  age: [10,20,30...]  Only read needed columns        │ │
-- │     └─────────────────────────────────────────────────────┘ │
-- │     Advantage: Less I/O, higher compression ratio           │
-- │                                                              │
-- │  2. Vectorized Execution                                     │
-- │     ┌─────────────────────────────────────────────────────┐ │
-- │     │  SIMD instructions process entire column at once     │ │
-- │     │  10-100x faster than row-based execution            │ │
-- │     └─────────────────────────────────────────────────────┘ │
-- │                                                              │
-- │  3. Sparse Index                                             │
-- │     ┌─────────────────────────────────────────────────────┐ │
-- │     │  One index mark every 8192 rows for fast data       │ │
-- │     │  location                                           │ │
-- │     └─────────────────────────────────────────────────────┘ │
-- │                                                              │
-- │  4. Background Merge                                        │
-- │     ┌─────────────────────────────────────────────────────┐ │
-- │     │  Small files automatically merged into large files  │ │
-- │     │  to optimize query performance                      │ │
-- │     └─────────────────────────────────────────────────────┘ │
-- │                                                              │
-- └─────────────────────────────────────────────────────────────┘

-- -----------------------------------------------------
-- 3. ClickHouse vs Traditional Databases
-- -----------------------------------------------------

-- Performance comparison (from official benchmark)
-- 
-- ┌─────────────────────────────────────────────────────────────┐
-- │              ClickHouse vs MySQL vs PostgreSQL              │
-- ├─────────────────────────────────────────────────────────────┤
-- │  Scenario: 1B row data aggregation query                     │
-- │                                                              │
-- │  MySQL:      ████████████████████████████████  ~30s         │
-- │  PostgreSQL: ████████████████████████████████  ~25s         │
-- │  ClickHouse: █ 0.02s (1000-1500x faster)                   │
-- │                                                              │
-- │  Compression ratio comparison:                               │
-- │  MySQL:      1x (original)                                  │
-- │  ClickHouse: 10-20x (columnar compression)                  │
-- │                                                              │
-- └─────────────────────────────────────────────────────────────┘

-- View current ClickHouse version
SELECT version();

-- View build information
SELECT 
    name,
    value
FROM system.build_options
WHERE name = 'VersionInteger';

-- -----------------------------------------------------
-- 4. ClickHouse Use Cases
-- -----------------------------------------------------

-- 
-- ┌─────────────────────────────────────────────────────────────┐
-- │              ClickHouse Use Cases                           │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                              │
-- │  ✓ Real-time Dashboards                                     │
-- │    - User behavior analysis, traffic monitoring, real-time  │
-- │      BI                                                      │
-- │                                                              │
-- │  ✓ Log Analytics                                           │
-- │    - Server logs, application tracking, ClickStream          │
-- │                                                              │
-- │  ✓ Business Intelligence                                    │
-- │    - Ad-hoc queries, multi-dimensional analysis, TTA/TTD    │
-- │      optimization                                            │
-- │                                                              │
-- │  ✓ Geospatial Data                                          │
-- │    - Location tracking, geofencing, path analysis           │
-- │                                                              │
-- │  ✓ Time Series Data                                         │
-- │    - Monitoring metrics, IoT sensors, financial data        │
-- │                                                              │
-- │  ✗ Not suitable: Transaction processing, frequent updates,  │
-- │    point queries                                             │
-- │                                                              │
-- └─────────────────────────────────────────────────────────────┘

-- -----------------------------------------------------
-- 5. Quick Start
-- -----------------------------------------------------

-- Use playground database
USE playground;

-- Create test table (ReplicatedMergeTree)
CREATE TABLE IF NOT EXISTS hello ON CLUSTER treasurycluster (
    id UInt32,
    name String,
    created_at DateTime DEFAULT now()
) ENGINE = ReplicatedMergeTree()
ORDER BY id;

-- Insert data
INSERT INTO hello (id, name) VALUES 
    (1, 'Alice'),
    (2, 'Bob'),
    (3, 'Charlie');

-- Query data
SELECT * FROM hello;

-- -----------------------------------------------------
-- 6. Core Concepts Overview
-- -----------------------------------------------------

-- 
-- ┌─────────────────────────────────────────────────────────────┐
-- │              ClickHouse Core Concepts                      │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                              │
-- │  Table Engine (表引擎)                                      │
-- │  ├── MergeTree - Core engine with primary key and merge   │
-- │  ├── Distributed - Distributed table engine                │
-- │  ├── ReplicatedMergeTree - Replicated table engine         │
-- │  └── Buffer - Buffer engine                                 │
-- │                                                              │
-- │  Key Concepts                                                │
-- │  ├── ORDER BY - Primary key sort order, physical storage   │
-- │  ├── PARTITION BY - Partition key, data division          │
-- │  ├── PRIMARY KEY - Primary key (optional, defaults to     │
-- │  │                ORDER BY)                                │
-- │  └── SAMPLE BY - Sample key for data sampling             │
-- │                                                              │
-- │  Data Parts                                                  │
-- │  ├── Active parts - Currently active data parts           │
-- │  ├── Merging parts - Currently merging data parts         │
-- │  └── Mutations - Async data modification operations       │
-- │                                                              │
-- └─────────────────────────────────────────────────────────────┘

-- View all table engines
SELECT name FROM system.table_engines LIMIT 10;

-- View system functions
SELECT 
    if(is_aggregate = 1, 'Aggregate function', 'Regular function') AS type,
    count() AS count
FROM system.functions
GROUP BY type;

-- -----------------------------------------------------
-- 7. Exercise: Create your first table
-- -----------------------------------------------------

-- Exercise: Create user events table (Replicated)
DROP TABLE IF EXISTS user_events ON CLUSTER treasurycluster SYNC;

CREATE TABLE IF NOT EXISTS user_events (
    event_id UInt64,
    user_id UInt32,
    event_type Enum8('click' = 1, 'view' = 2, 'purchase' = 3, 'login' = 4),
    event_time DateTime,
    page_url String,
    country String,
    revenue Float64 DEFAULT 0
) ENGINE = ReplicatedMergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_type, user_id, event_time)
SETTINGS index_granularity = 8192;

-- Insert test data
INSERT INTO user_events
SELECT 
    number AS event_id,
    number % 10000 AS user_id,
    CAST(number % 4 + 1 AS Enum8('click' = 1, 'view' = 2, 'purchase' = 3, 'login' = 4)) AS event_type,
    now() - INTERVAL (number % 10000) MINUTE AS event_time,
    concat('https://example.com/page/', toString(number % 100)) AS page_url,
    ['US', 'CN', 'UK', 'JP', 'DE'][number % 5 + 1] AS country,
    if(number % 10 = 0, rand() % 1000, 0) AS revenue
FROM numbers(10000);

-- Query verification
SELECT 
    event_type,
    count() AS cnt,
    uniqExact(user_id) AS unique_users,
    sum(revenue) AS total_revenue
FROM user_events
GROUP BY event_type
ORDER BY cnt DESC;

-- -----------------------------------------------------
-- 8. Chapter Summary
-- -----------------------------------------------------

-- 
-- ┌─────────────────────────────────────────────────────────────┐
-- │              Chapter Key Points                             │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                              │
-- │  1. ClickHouse is a columnar database for OLAP             │
-- │  2. Core advantages: Columnar storage + Vectorized         │
-- │     execution + Sparse index                               │
-- │  3. 100-1000x faster than traditional databases            │
-- │  4. Use cases: Analytic queries, reports, logs,           │
-- │     real-time BI                                            │
-- │  5. Not suitable: Transactional apps, frequent updates      │
-- │                                                              │
-- │  Next: 02_architecture.sql - Deep dive into architecture    │
-- │                                                              │
-- └─────────────────────────────────────────────────────────────┘

-- Verify learning
SELECT 
    'intro' AS chapter,
    'completed' AS status,
    now() AS completed_at;
