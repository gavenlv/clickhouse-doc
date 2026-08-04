# ClickHouse MergeTree Deep Dive: Column-Oriented Storage and the Secrets of High Performance

## Introduction

ClickHouse is one of the fastest OLAP databases in the industry. Its core secrets lie in the **MergeTree storage engine** and **column-oriented storage architecture**. This article provides an in-depth analysis of:

1. Fundamental differences between column-oriented and row-oriented storage
2. Why ClickHouse is so fast
3. How MergeTree works
4. How to use MergeTree correctly

---

## 1. Column-Oriented vs Row-Oriented Storage

### 1.1 Storage Mode Comparison

```
┌─────────────────────────────────────────────────────────────────┐
│                   Row-Oriented Storage                          │
├─────────────────────────────────────────────────────────────────┤
│  ┌─────────────────────────────────────────────────────────┐    │
│  │ Row 1: [id:1, name:Alice, age:25, city:Beijing]         │    │
│  │ Row 2: [id:2, name:Bob,   age:30, city:Shanghai]        │    │
│  │ Row 3: [id:3, name:Carol, age:28, city:Guangzhou]       │    │
│  └─────────────────────────────────────────────────────────┘    │
│                                                                 │
│  Characteristics: Each row stored contiguously                  │
│  Best for: OLTP transactions, full-row read/write               │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│                 Column-Oriented Storage                         │
├─────────────────────────────────────────────────────────────────┤
│  ┌─────────────────────────────────────────────────────────┐    │
│  │ id:    [1, 2, 3, ...]                                   │    │
│  │ name:  [Alice, Bob, Carol, ...]                         │    │
│  │ age:   [25, 30, 28, ...]                                │    │
│  │ city:  [Beijing, Shanghai, Guangzhou, ...]              │    │
│  └─────────────────────────────────────────────────────────┘    │
│                                                                 │
│  Characteristics: Each column stored contiguously               │
│  Best for: OLAP analytics, reading only needed columns          │
└─────────────────────────────────────────────────────────────────┘
```

### 1.2 Why Column-Oriented is Better for Analytics

**Scenario: Calculate average age of all users**

```sql
-- Only read the age column
SELECT avg(age) FROM users;
```

| Storage Type | Data Read | I/O Operations |
|-------------|-----------|----------------|
| Row-oriented | Full rows (id+name+age+city) | 4 fields read, need only 1 |
| Column-oriented | Only age column | 1 field read, 75% less I/O |

### 1.3 Advantages of Column-Oriented Storage

```
┌─────────────────────────────────────────────────────────────────┐
│              Column-Oriented Storage Key Advantages             │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  1️⃣ Higher Compression Efficiency per Column                  │
│     ────────────────────────────────                            │
│     • Same data type in each column (age all Int32)           │
│     • Adjacent values are similar → higher compression        │
│     • Typical compression ratio: 10-30x                       │
│                                                                 │
│  2️⃣ Read Only Needed Columns                                  │
│     ─────────────────────────                                  │
│     • SELECT avg(age) → read only age column                   │
│     • Skip id, name, city columns                              │
│     • Dramatically reduced I/O                                 │
│                                                                 │
│  3️⃣ Vectorized Execution                                      │
│     ────────────────────                                       │
│     • Column data contiguous → CPU SIMD batch processing      │
│     • Process thousands of rows per loop                       │
│     • 10-100x performance improvement                          │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## 2. Why is ClickHouse So Fast?

### 2.1 Six Pillars of High Performance

```
┌─────────────────────────────────────────────────────────────────┐
│              ClickHouse High Performance - Six Pillars          │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│    ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐     │
│    │ Columnar │  │Vectorized│  │  Sparse  │  │Background│     │
│    │ Storage  │→ │ Execution│→ │  Index   │→ │  Merging │     │
│    └──────────┘  └──────────┘  └──────────┘  └──────────┘     │
│         │                        │                        │      │
│         │              ┌──────────┐  ┌──────────┐        │      │
│         └─────────────→│  Data    │→ │  Query   │←───────┘      │
│                        │Compression│  │ Optimizer│               │
│                        └──────────┘  └──────────┘               │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 2.2 Detailed Analysis

#### ① Columnar Storage + Compression

```sql
-- View actual compression effects
SELECT 
    column,
    formatReadableSize(sum(compressed_bytes)) AS compressed,
    formatReadableSize(sum(data_uncompressed_bytes)) AS uncompressed,
    round(sum(data_uncompressed_bytes) / sum(compressed_bytes), 1) AS ratio
FROM system.parts_columns
WHERE database = 'your_db' AND table = 'your_table'
GROUP BY column;
```

**Typical Results**:
- `UInt32` type: compression ratio ~10:1
- `String` low cardinality: compression ratio ~20:1
- `DateTime`: compression ratio ~15:1

#### ② Vectorized Execution Engine

```
Traditional Row-by-Row Execution:
┌───┬───┬───┬───┬───┐
│1  │2  │3  │4  │5  │  → 5 loops, 5 CPU instructions
└───┴───┴───┴───┴───┘

ClickHouse Vectorized Execution:
┌───────────────────────────────────────┐
│  Column A: [1, 2, 3, 4, 5, ...]       │  → Single SIMD instruction
│           + operations (batch)        │    processes thousands rows
└───────────────────────────────────────┘
```

#### ③ Sparse Index - Fast Primary Key Lookup

```sql
CREATE TABLE events (
    user_id UInt32,
    event_date Date,
    event_type String
) ENGINE = MergeTree()
ORDER BY (event_date, user_id);  -- Primary key
```

```
Data sorted by primary key, one index mark per 8192 rows:

primary.idx (sparse index):
┌─────────────────────────────────────────────────────────┐
│ Mark 0: [event_date=2024-01-01, user_id=1]              │
│ Mark 1: [event_date=2024-01-01, user_id=1025]           │
│ Mark 2: [event_date=2024-01-01, user_id=2050]           │
│ ...                                                     │
│ Mark N: [event_date=2024-01-02, user_id=500]            │
└─────────────────────────────────────────────────────────┘

Query WHERE event_date = '2024-01-01' AND user_id = 1500
  → Binary search to locate Mark 1
  → Read corresponding data block directly
  → Skip 99% of data!
```

---

## 3. How MergeTree Works

### 3.1 MergeTree Storage Structure

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         MergeTree Storage Architecture                  │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  Table                                                                  │
│  │                                                                      │
│  ├── Partition 202401 (monthly partition)                               │
│  │   │                                                                  │
│  │   ├── Part_202401_1_1_2_0                                           │
│  │   │   ├── primary.idx    (primary sparse index)                      │
│  │   │   ├── user_id.mrk2  (column mark file)                          │
│  │   │   ├── user_id.bin   (column data - compressed)                  │
│  │   │   ├── event_type.mrk2                                           │
│  │   │   ├── event_type.bin                                           │
│  │   │   └── ...                                                        │
│  │   │                                                                  │
│  │   ├── Part_202401_3_4_5_0  (new insert)                              │
│  │   │   └── ...                                                        │
│  │   │                                                                  │
│  │   └── [Background merging...]                                        │
│  │       Part_202401_1_1_2_0 + Part_202401_3_4_5_0                      │
│  │       → Part_202401_1_1_5_1  (merged new Part)                       │
│  │                                                                      │
│  └── Partition 202402                                                   │
│      └── ...                                                            │
│                                                                         │
│  Part naming: {partition}_{min_block}_{max_block}_{level}               │
│  Example: 202401_1_10_5                                                 │
│      ├── partition: 202401                                              │
│      ├── min_block: 1                                                   │
│      ├── max_block: 10                                                  │
│      └── level: 5 (0=original, higher=more merges)                      │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### 3.2 Data Insertion Flow

```
┌─────────────────────────────────────────────────────────────────┐
│                   MergeTree Data Insertion Flow                   │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  1. INSERT Statement                                             │
│     │                                                            │
│     ▼                                                            │
│  2. Write to Memory Buffer                                      │
│     │ (default 64KB-2MB, configurable)                          │
│     ▼                                                            │
│  3. Flush Buffer to Disk (when full or timeout)                  │
│     │                                                            │
│     ▼                                                            │
│  4. Create Part Files                                           │
│     ├── primary.idx (primary index)                             │
│     ├── *.mrk2 (column marks)                                   │
│     └── *.bin (compressed column data)                          │
│     │                                                            │
│     ▼                                                            │
│  5. Register to ZooKeeper (for replicated tables)                │
│     │                                                            │
│     ▼                                                            │
│  6. Done ✓                                                       │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 3.3 Background Merge Mechanism

```sql
-- Observation: Each INSERT creates a new Part
INSERT INTO events VALUES (1, '2024-01-01', 'click');
INSERT INTO events VALUES (2, '2024-01-01', 'view');
INSERT INTO events VALUES (3, '2024-01-02', 'purchase');

-- View Parts
SELECT name, rows, level FROM system.parts 
WHERE table = 'events' AND active = 1;
-- Result: 3 independent Parts
```

**Background Merge Triggers**:
```
✓ Periodic background check (every 15 seconds)
✓ Part count exceeds threshold
✓ Part size meets merge condition
✓ TTL expiration trigger
```

**Merge Process**:
```
Before:  Part_202401_1_2_0  +  Part_202401_3_4_0  +  Part_202401_5_6_0
              ↓                        ↓                    ↓
         Level=0                  Level=0               Level=0

After:   Part_202401_1_6_1
              ↑
         Level=1 (level increases after merge)
```

---

## 4. The MergeTree Family

### 4.1 Family Members Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                      MergeTree Family                            │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  MergeTree (base)                                                │
│  ├── ReplacingMergeTree - Deduplication                         │
│  ├── SummingMergeTree - Sum aggregation                          │
│  ├── AggregatingMergeTree - Pre-aggregation                      │
│  ├── CollapsingMergeTree - Incremental updates                   │
│  ├── VersionedCollapsingMergeTree - Version-controlled collapse  │
│  └── GraphiteMergeTree - Time-series optimization                │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 4.2 Practical Examples

#### ReplacingMergeTree - Automatic Deduplication

```sql
CREATE TABLE sessions (
    session_id String,
    user_id UInt32,
    duration UInt32,
    version UInt8  -- version for keeping latest record
) ENGINE = ReplacingMergeTree(version)
ORDER BY (user_id, session_id);

-- Insert same session multiple times
INSERT INTO sessions VALUES ('s1', 100, 30, 1);
INSERT INTO sessions VALUES ('s1', 100, 45, 2);  -- Same session, updated
INSERT INTO sessions VALUES ('s1', 100, 60, 3);  -- Updated again

-- After merge, only version=3 record is kept
OPTIMIZE TABLE sessions FINAL;

SELECT * FROM sessions;
-- Result: s1, 100, 60, 3
```

#### SummingMergeTree - Automatic Sum

```sql
CREATE TABLE metrics (
    date Date,
    region String,
    product String,
    amount UInt64
) ENGINE = SummingMergeTree()
ORDER BY (date, region, product);

-- Same key's amount will be automatically summed
INSERT INTO metrics VALUES 
    ('2024-01-01', 'North', 'A', 100),
    ('2024-01-01', 'North', 'A', 50),   -- Same key, merged
    ('2024-01-01', 'South', 'B', 30);

OPTIMIZE TABLE metrics FINAL;

SELECT * FROM metrics;
-- Result: ('2024-01-01', 'North', 'A', 150), ('2024-01-01', 'South', 'B', 30)
```

---

## 5. Best Practices

### 5.1 Table Design Golden Rules

```
┌─────────────────────────────────────────────────────────────────┐
│                    MergeTree Table Design Rules                  │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ✅ Rule 1: Choose the right primary key order                 │
│     ────────────────────────────────                            │
│     ORDER BY (filter_col1, filter_col2, pk_col)                 │
│     Put high-selectivity columns first                          │
│                                                                 │
│  ✅ Rule 2: Design partitions wisely                            │
│     ────────────────────────────                                │
│     PARTITION BY toYYYYMM(date)  -- monthly partition           │
│     Avoid too many or too few partitions                        │
│                                                                 │
│  ✅ Rule 3: Choose appropriate column types                     │
│     ────────────────────────────                                │
│     • Use UInt32 instead of Int64 (when range is sufficient)   │
│     • Use DateTime instead of String                           │
│     • Use LowCardinality(String) for low-cardinality strings    │
│                                                                 │
│  ❌ Rule 4: Avoid These Mistakes                                 │
│     ────────────────────────────                                │
│     • High-cardinality columns (like UUID) in primary key first │
│     • No partitioning causing too many Parts                   │
│     • Using String to store dates                               │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 5.2 Practical Example - Correct Table Design

```sql
-- Event table design
CREATE TABLE app_events (
    event_date Date,
    event_time DateTime,
    user_id UInt32,           -- Low cardinality, use UInt32
    event_type LowCardinality(String),  -- Low cardinality string optimization
    page_url String,
    duration UInt32,
    revenue Float64
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_date)
ORDER BY (event_date, user_id, event_time)  -- Filter columns first, then unique
SETTINGS index_granularity = 8192;
```

### 5.3 Query Optimization Tips

```sql
-- ✅ Correct: Only select needed columns
SELECT event_type, count() 
FROM app_events 
GROUP BY event_type;

-- ❌ Wrong: SELECT * (reads all columns)
-- SELECT * FROM app_events LIMIT 10;

-- ✅ Use PREWHERE optimization (filter first, then read)
SELECT user_id, count()
FROM app_events
PREWHERE event_date >= '2024-01-01'
WHERE event_type = 'purchase'
GROUP BY user_id;

-- ✅ Leverage partition pruning
SELECT * FROM app_events
WHERE event_date BETWEEN '2024-01-01' AND '2024-01-31';  -- Only scan January partitions
```

### 5.4 Monitoring and Maintenance

```sql
-- View Parts status
SELECT 
    partition,
    count() AS part_count,
    sum(rows) AS total_rows,
    formatReadableSize(sum(bytes)) AS size
FROM system.parts
WHERE database = 'your_db' AND table = 'your_table' AND active = 1
GROUP BY partition
ORDER BY partition;

-- View merge queue
SELECT * FROM system.merges
WHERE database = 'your_db';

-- View MergeTree settings
SELECT name, value, description
FROM system.merge_tree_settings
WHERE name IN ('max_parts_to_merge_at_once', 'index_granularity');
```

---

## 6. Summary

```
┌─────────────────────────────────────────────────────────────────┐
│                        Key Takeaways                            │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  1️⃣ Column-Oriented Storage                                     │
│     • Data stored by column, each column in separate .bin file  │
│     • Same type per column, high compression (10-30x)           │
│     • Only read needed columns, dramatically reduced I/O        │
│                                                                 │
│  2️⃣ Sources of ClickHouse High Performance                      │
│     • Columnar storage + high compression ratio                 │
│     • Vectorized execution (SIMD batch processing)              │
│     • Sparse index for fast data location                      │
│     • Background merging for data layout optimization           │
│                                                                 │
│  3️⃣ MergeTree Core Mechanisms                                   │
│     • Data stored by Part, each INSERT creates new Part         │
│     • Background automatically merges small Parts              │
│     • Primary key sparse index, one mark per 8192 rows         │
│     • Partitioning enables fast data pruning                   │
│                                                                 │
│  4️⃣ Using MergeTree Correctly                                   │
│     • Design primary key order wisely                           │
│     • Choose appropriate partition granularity                  │
│     • Use appropriate MergeTree variants                       │
│     • Leverage partition pruning and PREWHERE optimization      │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## References

- [ClickHouse Official Documentation](https://clickhouse.com/docs)
- [MergeTree Engine Details](https://clickhouse.com/docs/en/engines/table-engines/mergetree-family/mergetree)
- [system.parts Table](https://clickhouse.com/docs/en/operations/system-tables/parts)

---

*This article is based on ClickHouse documentation and practical experience*
