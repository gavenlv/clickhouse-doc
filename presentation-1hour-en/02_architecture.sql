-- =====================================================
-- 02 - ClickHouse Core Architecture
-- =====================================================
-- Cluster: treasurycluster (2 replicas)
-- Time: 20-35 minutes
-- =====================================================

-- -----------------------------------------------------
-- 1. ClickHouse Overall Architecture
-- -----------------------------------------------------

-- 
-- ┌─────────────────────────────────────────────────────────────┐
-- │                 ClickHouse Complete Architecture            │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                             │
-- │  ┌─────────────────────────────────────────────────────┐   │
-- │  │              Client Layer (客户端层)                  │   │
-- │  │   HTTP    Native TCP    CLI    ODBC/JDBC           │   │
-- │  └─────────────────────┬───────────────────────────────┘   │
-- │                        │                                     │
-- │  ┌─────────────────────▼───────────────────────────────┐   │
-- │  │           Query Pipeline (查询管道)                   │   │
-- │  │                                                     │   │
-- │  │   Parser → Interpreter → Handler → Storage          │   │
-- │  │      │         │           │          │              │   │
-- │  │      ▼         ▼           ▼          ▼              │   │
-- │  │   AST    Optimization   Plan     Data               │   │
-- │  │                                                     │   │
-- │  └─────────────────────┬───────────────────────────────┘   │
-- │                        │                                     │
-- │  ┌─────────────────────▼───────────────────────────────┐   │
-- │  │         Storage Engine Layer (存储引擎层)             │   │
-- │  │                                                     │   │
-- │  │   MergeTree  Distributed  Memory  Buffer            │   │
-- │  │                                                     │   │
-- │  └─────────────────────────────────────────────────────┘   │
-- │                                                             │
-- └─────────────────────────────────────────────────────────────┘

-- -----------------------------------------------------
-- 2. Columnar vs Row Storage
-- -----------------------------------------------------

-- Use playground database
USE playground;

-- Create columnar storage example table (Replicated)
DROP TABLE IF EXISTS col_store ON CLUSTER treasurycluster SYNC;

CREATE TABLE col_store (
    id UInt32,
    name String,
    age UInt8,
    city String
) ENGINE = ReplicatedMergeTree()
ORDER BY id;

INSERT INTO col_store VALUES 
    (1, 'Alice', 25, 'Beijing'),
    (2, 'Bob', 30, 'Shanghai'),
    (3, 'Charlie', 28, 'Beijing');

-- View storage files
-- 
-- Columnar storage file structure:
-- 
-- ┌─────────────────────────────────────────────────────────────┐
-- │              ClickHouse Data File Structure                  │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                             │
-- │  Data directory: /var/lib/clickhouse/data/database/table/   │
-- │                                                             │
-- │  ├── all_1_1_0/              ← Part directory               │
-- │  │   ├── checksums.txt       ← File checksums               │
-- │  │   ├── columns.txt        ← Column information           │
-- │  │   ├── count.txt          ← Row count                     │
-- │  │   ├── id.bin              ← id column data (compressed)  │
-- │  │   ├── id.mrk2             ← id column marks              │
-- │  │   ├── name.bin            ← name column data             │
-- │  │   ├── name.mrk2           ← name column marks            │
-- │  │   ├── age.bin             ← age column data              │
-- │  │   ├── age.mrk2            ← age column marks              │
-- │  │   ├── city.bin            ← city column data             │
-- │  │   └── city.mrk2           ← city column marks            │
-- │  │                                                     │
-- │  └── primary.idx              ← Primary key index           │
-- │                                                             │
-- └─────────────────────────────────────────────────────────────┘

-- View column data files
-- SELECT 
--     column,
--     formatReadableSize(sum(compressed_bytes)) AS compressed_size,
--     formatReadableSize(sum(data_uncompressed_bytes)) AS raw_size,
--     round(sum(data_uncompressed_bytes) / sum(compressed_bytes), 1) AS compression_ratio
-- FROM system.parts_columns
-- WHERE database = 'playground' AND table = 'col_store' AND active = 1
-- GROUP BY column;

-- -----------------------------------------------------
-- 3. Vectorized Execution Engine
-- -----------------------------------------------------

-- 
-- ┌─────────────────────────────────────────────────────────────┐
-- │              Vectorized Execution Principle                  │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                             │
-- │  Row-by-row execution:                                     │
-- │  ┌───┬───┬───┬───┬───┐                                     │
-- │  │1  │2  │3  │4  │5  │  → 5 iterations                     │
-- │  └───┴───┴───┴───┴───┘                                     │
-- │   for i in rows:                                           │
-- │       result[i] = func(row[i])                             │
-- │                                                             │
-- │  Vectorized execution:                                     │
-- │  ┌─────────────────────────────────────────────────────┐   │
-- │  │  [1, 2, 3, 4, 5]     ← Column data (SIMD)         │   │
-- │  └─────────────────────────────────────────────────────┘   │
-- │       │                                                    │
-- │       ▼                                                    │
-- │  result = func([1,2,3,4,5])  ← Process entire column      │
-- │                                                             │
-- │  Performance boost: 10-100x                                │
-- │                                                             │
-- └─────────────────────────────────────────────────────────────┘

-- Create large table for vectorized performance test (Replicated)
DROP TABLE IF EXISTS vector_test ON CLUSTER treasurycluster SYNC;

CREATE TABLE vector_test (
    id UInt64,
    value Float64,
    category UInt8
) ENGINE = ReplicatedMergeTree()
ORDER BY id;

-- Insert 1M rows
INSERT INTO vector_test
SELECT 
    number AS id,
    rand() * 1000 AS value,
    number % 10 AS category
FROM numbers(1000000);

-- View query execution plan
EXPLAIN PLAN SELECT count(), avg(value), sum(value) 
FROM vector_test 
WHERE category = 5;

-- View pipeline execution
EXPLAIN PIPELINE SELECT count() FROM vector_test;

-- Execute and view performance
SELECT 
    count() AS cnt,
    avg(value) AS avg_val,
    sum(value) AS total_val
FROM vector_test
WHERE category = 5;

-- -----------------------------------------------------
-- 4. Sparse Index Mechanism
-- -----------------------------------------------------

-- 
-- ┌─────────────────────────────────────────────────────────────┐
-- │              ClickHouse Sparse Index                        │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                             │
-- │  Primary key index (primary.idx):                           │
-- │  ┌─────────────────────────────────────────────────────┐   │
-- │  │  Physical storage: One index entry per 8192 rows    │   │
-- │  │                                                     │   │
-- │  │  Example (ORDER BY id):                            │   │
-- │  │  ─────────────────────────────────────────────     │   │
-- │  │  Index pos: 0    8192   16384  24576  32768 ...    │   │
-- │  │  Index val:  0    8192   16384  24576  32768 ...    │   │
-- │  │                                                     │   │
-- │  │  When querying id = 10000:                         │   │
-- │  │  - Locate index range: [8192, 16384)              │   │
-- │  │  - Only scan this data block                        │   │
-- │  └─────────────────────────────────────────────────────┘   │
-- │                                                             │
-- │  Advantage: Small index file, memory friendly               │
-- │  Limitation: Suitable for range queries, not point queries   │
-- │                                                             │
-- └─────────────────────────────────────────────────────────────┘

-- View index information
SELECT 
    name,
    value,
    description
FROM system.merge_tree_settings
WHERE name = 'index_granularity';

-- Create table with composite primary key (Replicated)
DROP TABLE IF EXISTS sparse_index_demo ON CLUSTER treasurycluster SYNC;

CREATE TABLE sparse_index_demo (
    event_date Date,
    user_id UInt32,
    event_type String,
    payload String
) ENGINE = ReplicatedMergeTree()
PARTITION BY toYYYYMM(event_date)
ORDER BY (event_date, user_id)
SETTINGS index_granularity = 8192;

-- Insert data
INSERT INTO sparse_index_demo
SELECT 
    toDate('2024-01-01') + (number % 30) AS event_date,
    number % 10000 AS user_id,
    ['click', 'view', 'purchase'][number % 3 + 1] AS event_type,
    repeat('x', 100) AS payload
FROM numbers(100000);

-- View parts and indexes
SELECT 
    partition,
    name AS part_name,
    rows,
    formatReadableSize(bytes) AS size
FROM system.parts
WHERE database = 'playground' AND table = 'sparse_index_demo' AND active = 1;

-- -----------------------------------------------------
-- 5. Query Processing Pipeline
-- -----------------------------------------------------

-- 
-- ┌─────────────────────────────────────────────────────────────┐
-- │              ClickHouse Query Processing Flow                │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                             │
-- │  1. Parser (解析)                                           │
-- │     SQL Text → AST (Abstract Syntax Tree)                   │
-- │     SELECT * FROM users WHERE age > 20                     │
-- │            ↓                                                │
-- │     SelectQuery                                            │
-- │       ├── from: users                                      │
-- │       ├── where: age > 20                                  │
-- │       └── ...                                              │
-- │                                                             │
-- │  2. Interpreter (解释)                                     │
-- │     AST → QueryPlan (Optimized query plan)                 │
-- │     - Predicate pushdown                                   │
-- │     - Column pruning                                       │
-- │     - Expression optimization                              │
-- │                                                             │
-- │  3. Execution (执行)                                       │
-- │     Pipeline → Parallel execution                          │
-- │     - Read → Filter → Aggregate → Sort → Return           │
-- │                                                             │
-- └─────────────────────────────────────────────────────────────┘

-- Use EXPLAIN to analyze query plan
EXPLAIN PLAN 
SELECT 
    user_id,
    count() AS cnt
FROM sparse_index_demo
WHERE event_date >= '2024-01-01' AND event_date < '2024-01-15'
GROUP BY user_id
ORDER BY cnt DESC
LIMIT 10;

-- View detailed pipeline
EXPLAIN PIPELINE 
SELECT count() FROM sparse_index_demo 
WHERE event_type = 'purchase';

-- -----------------------------------------------------
-- 6. Distributed Architecture
-- -----------------------------------------------------

-- 
-- ┌─────────────────────────────────────────────────────────────┐
-- │              ClickHouse Distributed Architecture           │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                             │
-- │  Cluster structure:                                         │
-- │                                                             │
-- │         ┌──────────────┐                                   │
-- │         │   Client      │                                   │
-- │         └──────┬───────┘                                   │
-- │                │                                           │
-- │         ┌──────▼───────┐                                   │
-- │         │  Coordinator │ ← Query coordination node          │
-- │         │   (any node)  │                                   │
-- │         └──────┬───────┘                                   │
-- │                │                                           │
-- │      ┌────────┼────────┐                                   │
-- │      │        │        │                                   │
-- │  ┌───▼───┐ ┌───▼───┐ ┌───▼───┐                             │
-- │  │Shard 1│ │Shard 2│ │Shard 3│ ← Shards (data)           │
-- │  │Replica│ │Replica│ │Replica│ ← Replicas (HA)            │
-- │  └───────┘ └───────┘ └───────┘                             │
-- │                                                             │
-- │  Sharding strategy:                                          │
-- │  - Hash sharding: sharding_key % N                          │
-- │  - Range sharding: Partition by time/region                 │
-- │  - Consistent hashing: Balanced data distribution           │
-- │                                                             │
-- └─────────────────────────────────────────────────────────────┘

-- View cluster configuration
SELECT 
    cluster,
    shard_num,
    replica_num,
    host_name,
    is_local
FROM system.clusters
LIMIT 10;

-- -----------------------------------------------------
-- 7. Background Tasks and Merging
-- -----------------------------------------------------

-- 
-- ┌─────────────────────────────────────────────────────────────┐
-- │              ClickHouse Background Merge Mechanism          │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                             │
-- │  Write flow:                                                │
-- │  ┌─────────────────────────────────────────────────────┐   │
-- │  │  INSERT → Generate Part file → Active                │   │
-- │  │         │                                            │   │
-- │  │         ▼                                            │   │
-- │  │     Part_1_1_0   ← Initial part                     │   │
-- │  │     Part_2_1_0   ← Second part                      │   │
-- │  │     Part_3_1_0   ← Third part                       │   │
-- │  └─────────────────────────────────────────────────────┘   │
-- │                          │                                  │
-- │                          ▼                                  │
-- │  ┌─────────────────────────────────────────────────────┐   │
-- │  │              Background Merge                        │   │
-- │  │                                                    │   │
-- │  │   Part_1_1_0 + Part_2_1_0 + Part_3_1_0             │   │
-- │  │              ↓                                       │   │
-- │  │         Part_1_3_1 (merged)                         │   │
-- │  │                                                    │   │
-- │  └─────────────────────────────────────────────────────┘   │
-- │                                                             │
-- │  Merge strategy:                                            │
-- │  - Merge parts in same partition                          │
-- │  - Merge order: small → medium → large                     │
-- │  - TTL merge: Clean up expired data                        │
-- │                                                             │
-- └─────────────────────────────────────────────────────────────┘

-- View current merge tasks
SELECT 
    database,
    table,
    elapsed,
    progress,
    num_parts,
    formatReadableSize(total_size_bytes_compressed) AS size
FROM system.merges
LIMIT 5;

-- View merge configuration
SELECT 
    name,
    value
FROM system.merge_tree_settings
WHERE name IN ('max_parts_to_merge_at_once', 'merge_with_ttl_timeout');

-- Trigger a small merge manually (for demo)
OPTIMIZE TABLE sparse_index_demo FINAL;

-- -----------------------------------------------------
-- 8. Memory Management
-- -----------------------------------------------------

-- View memory usage
SELECT 
    metric,
    formatReadableSize(value) AS size
FROM system.metrics
WHERE metric LIKE '%Memory%'
LIMIT 10;

-- -----------------------------------------------------
-- 9. Chapter Summary
-- -----------------------------------------------------

-- 
-- ┌─────────────────────────────────────────────────────────────┐
-- │              Chapter Key Points                             │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                             │
-- │  1. Columnar storage: Store by column, less I/O, high      │
-- │     compression                                             │
-- │  2. Vectorized execution: SIMD instructions, 10-100x       │
-- │     performance boost                                      │
-- │  3. Sparse index: 8192 rows/index entry, memory friendly  │
-- │  4. Background merge: Auto-merge small files, optimize     │
-- │     query performance                                       │
-- │  5. Distributed: Horizontal scaling, shards + replicas      │
-- │                                                             │
-- │  Next: 03_mergetree.sql - Deep dive into MergeTree         │
-- │                                                             │
-- └─────────────────────────────────────────────────────────────┘

-- Verify learning
SELECT 
    'architecture' AS chapter,
    (SELECT count() FROM system.parts WHERE database = 'playground') AS parts_created;
