# ClickHouse Technical Presentation

This directory contains all SQL demonstration files for ClickHouse technical presentation.

## Directory Structure

```
presentation-1hour-en/
├── README.md                    # This file - Presentation outline
├── [01_intro.sql](01_intro.sql)                 # ClickHouse Introduction & Core Advantages
├── [02_architecture.sql](02_architecture.sql)    # Architecture Analysis: Columnar, Vectorized, Distributed
├── [03_mergetree.sql](03_mergetree.sql)         # MergeTree Engine Core Principles
├── [04_query_optimization.sql](04_query_optimization.sql)  # Query Optimization Techniques
├── [05_best_practices.sql](05_best_practices.sql) # Best Practices & Common Issues
└── [06_demo.sql](06_demo.sql)                    # Live Demo Cases
```

## Quick Navigation

| File | Content |
|------|---------|
| [01_intro.sql](01_intro.sql) | ClickHouse Introduction & Core Advantages |
| [02_architecture.sql](02_architecture.sql) | Architecture: Columnar, Vectorized, Distributed |
| [03_mergetree.sql](03_mergetree.sql) | MergeTree Engine Core Principles |
| [04_query_optimization.sql](04_query_optimization.sql) | Query Optimization Techniques |
| [05_best_practices.sql](05_best_practices.sql) | Best Practices & Common Issues |
| [06_demo.sql](06_demo.sql) | Live Demo Cases |

## Requirements

- ClickHouse cluster: treasurycluster (2 replicas)
- Database: playground (pre-created)
- Engine: ReplicatedMergeTree family (using default macro configuration)
- Execution: All SQL includes `ON CLUSTER treasurycluster`

## Content Overview

### 01 - ClickHouse Introduction & Core Advantages

**File**: [01_intro.sql](01_intro.sql)

**Key Topics**:
- What is ClickHouse?
- Why is ClickHouse so fast?
  - Columnar storage
  - Vectorized execution
  - Sparse index
  - Background merge
- ClickHouse vs Traditional Databases
- ClickHouse Use Cases
- Quick Start Example
- Core Concepts Overview

### 02 - ClickHouse Core Architecture

**File**: [02_architecture.sql](02_architecture.sql)

**Key Topics**:
- ClickHouse Overall Architecture
- Columnar vs Row Storage
  - Storage file structure
  - Compression ratio comparison
- Vectorized Execution Engine
  - SIMD instruction advantages
  - Performance comparison
- Sparse Index Mechanism
  - Index granularity
  - Index lookup principles
- Query Processing Pipeline
  - Parser → Interpreter → Execution
- Distributed Architecture
  - Shards and replicas
  - Data distribution strategy
- Background Tasks and Merging

### 03 - MergeTree Engine Core Principles

**File**: [03_mergetree.sql](03_mergetree.sql)

**Key Topics**:

#### MergeTree Engine Family Details

ClickHouse's MergeTree is the core storage engine family, divided into two series:

---

##### [MergeTree Series] - No Replication (Single Node)

| Engine | Description | Use Case |
|--------|-------------|----------|
| **MergeTree** | Core base engine, most commonly used | General scenarios, high-performance writes |
| **SummingMergeTree** | Auto-aggregate numeric columns with same keys | Pre-aggregation, metrics summary |
| **AggregatingMergeTree** | Pre-aggregation, requires materialized views | Complex pre-aggregation, high-cardinality dimensions |
| **CollapsingMergeTree** | Delete marker collapse | Soft delete support |
| **VersionedCollapsingMergeTree** | Version-controlled collapse | Incremental updates with versions |
| **ReplacingMergeTree** | Version number replacement | Deduplication, keep latest version |
| **VersionedReplacingMergeTree** | Versioned replacement | Fine-grained version control |
| **GraphiteMergeTree** | Graphite data optimization | Monitoring metrics storage |

---

##### [ReplicatedMergeTree Series] - With Replication (Cluster)

| Engine | Description | Use Case |
|--------|-------------|----------|
| **ReplicatedMergeTree** | Supports replica replication | Production clusters, HA |
| **ReplicatedSummingMergeTree** | Replica + auto-aggregate | Distributed pre-aggregation |
| **ReplicatedAggregatingMergeTree** | Replica + pre-aggregation | Distributed complex aggregation |
| **ReplicatedCollapsingMergeTree** | Replica + delete marker collapse | Distributed soft delete |
| **ReplicatedVersionedCollapsingMergeTree** | Replica + version collapse | Distributed incremental updates |
| **ReplicatedReplacingMergeTree** | Replica + version replacement | Distributed deduplication |
| **ReplicatedVersionedReplacingMergeTree** | Replica + versioned replacement | Distributed version control |
| **ReplicatedGraphiteMergeTree** | Replica + Graphite optimization | Distributed monitoring storage |

---

##### Key Differences

| Feature | MergeTree Series | ReplicatedMergeTree Series |
|---------|-----------------|---------------------------|
| Replica Support | ❌ No | ✅ Yes |
| ZooKeeper | ❌ Not required | ✅ Required |
| High Availability | ❌ Single node | ✅ Multi-replica |
| Data Sync | Local only | Automatic cross-node |
| Environment | Dev/Test | Production |

---

##### MergeTree Core Concepts

- **ORDER BY** (required): Determines physical storage order, affects index structure
- **PARTITION BY** (optional): Data partition granularity, commonly toYYYYMM/toYYYYMMDD
- **PRIMARY KEY** (optional): Defaults to ORDER BY, can be set independently
- **SAMPLE BY** (optional): Data sampling key, supports SAMPLE queries
- **SETTINGS**: Index granularity, wide format, etc.

##### Data Writing and Part Files

- Part file structure: .bin (compressed data), .mrk2 (index marks), primary.idx (primary index)
- Write process: Memory → Temporary part → Merge to formal part
- Background merge: Auto-merge small parts, optimize storage

##### Primary Key Selection Principles

- High cardinality columns first
- Frequently filtered columns first
- Avoid using random values
- Compound primary key max 3-4 columns

##### Partition Strategy

- **Daily** (toYYYYMMDD): Large data, fast lookup
- **Monthly** (toYYYYMM): Historical data analysis
- **No partition**: Small data, avoid cross-partition queries

### 04 - Query Optimization Techniques & Practices

**File**: [04_query_optimization.sql](04_query_optimization.sql)

**Key Topics**:
- Query Optimization Core Principles
  - Column pruning
  - Predicate pushdown
  - Partition pruning
  - Index utilization
  - Data sampling
- Column Pruning Optimization
  - SELECT * vs selective columns
  - Performance comparison
- PREWHERE Optimization
  - Filter first, then read
  - Automatic optimization
- Partition Pruning
  - Use PARTITION BY
  - Avoid full table scan
- Using Skipping Index
  - set type
  - bloom_filter type
- Data Sampling
  - SAMPLE syntax
  - Approximate computation
- Approximate Aggregation
  - uniq vs uniqExact
  - quantile vs quantileExact
- Materialized View Optimization
  - Pre-aggregation
  - Performance comparison

### 05 - Best Practices & Common Issues

**File**: [05_best_practices.sql](05_best_practices.sql)

**Key Topics**:
- Table Design Best Practices
  - Table engine selection
  - Primary key design
  - Partition strategy
  - Data type optimization
  - Avoid NULL
- Data Type Optimization
  - LowCardinality(String)
  - Compression improvement
- Sharding Key Selection Principles
  - Even distribution
  - Query patterns
- Write Optimization
  - Batch writes
  - Asynchronous writes
  - Buffer table
  - Avoid small files
- Common Errors & Solutions
  - Too many parts
  - Memory limit exceeded
  - Data type errors
  - Duplicate writes
- Monitoring & Tuning
  - System health metrics
  - Slow query analysis
  - Memory usage
- ETL vs ClickHouse Responsibility Division

### 06 - Live Demo Cases

**File**: [06_demo.sql](06_demo.sql)

**Demo Contents**:
1. **Real-time Analytics Dashboard**
   - Today's order statistics
   - Past 7 days trend
   - Category sales ranking
   - Hourly distribution
   - User retention analysis

2. **Real-time Data Pipeline**
   - Buffer table demo
   - High throughput writes
   - Background flush

3. **Materialized View Pre-aggregation**
   - Daily statistics view
   - Millisecond response
   - Performance comparison

4. **User Behavior Funnel Analysis**
   - Page view → Purchase conversion
   - Step-by-step conversion rates
   - Overall conversion rate

5. **Geographic Distribution Analysis**
   - Statistics by country
   - Order volume and revenue
   - Average order amount

## Usage

### 1. Environment Setup

```bash
# Start ClickHouse cluster (using configuration from 00-infra directory)
cd 00-infra
docker-compose up -d

# Verify cluster status
docker ps
```

### 2. Run Demos

Execute SQL files in order:

```bash
# Method 1: Using clickhouse-client
clickhouse-client --host localhost --port 9000 < presentation-1hour-en/01_intro.sql

# Method 2: Using HTTP interface
curl -X POST http://localhost:8123/ --data-binary @presentation-1hour-en/01_intro.sql

# Method 3: In ClickHouse client
clickhouse-client --host localhost --port 9000
> source presentation-1hour-en/01_intro.sql
```

### 3. Database Information

All demos use the `playground` database, which is pre-created. To create it:

```sql
CREATE DATABASE IF NOT EXISTS playground;
```

### 4. Cluster Configuration

Cluster name: `treasurycluster`  
Number of replicas: 2  
All DDL statements include `ON CLUSTER treasurycluster`  
All DROP statements use `SYNC` option for synchronous execution

## Important Notes

1. **Execution Order**: Recommended to execute in file number order (01 → 06)
2. **Data Cleanup**: Tables created during demos will be dropped using `DROP ... SYNC`
3. **Performance Tests**: Some operations involve large datasets (3M rows), execution time may be longer
4. **Hardware Requirements**: Recommended to run demos on a machine with at least 4GB RAM

## Reference Resources

- [ClickHouse Official Documentation](https://clickhouse.com/docs)
- [ClickHouse GitHub](https://github.com/ClickHouse/ClickHouse)
- [ClickHouse Performance Benchmark](https://clickhouse.com/benchmark)

## Contributing

If you have questions or suggestions, please feel free to submit an Issue or Pull Request.

---

**Version**: v1.0  
**Last Updated**: 2024  
**Maintained By**: ClickHouse Technical Team
