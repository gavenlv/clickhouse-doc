# ClickHouse 原理专题

本专题深入解析 ClickHouse 的核心原理，帮助你理解其高性能背后的技术机制。

## 📚 文档目录

### 核心原理
- [01_overview.sql](./01_overview.sql) - ClickHouse 架构概览 (含查询管道图)
- [02_column_store.sql](./02_column_store.sql) - 列式存储原理
- [03_mergetree.sql](./03_mergetree.sql) - MergeTree 引擎原理 (含Part结构图)

### 存储机制
- [04_compression.md](./04_compression.md) - 数据压缩和编码
- [05_indexing.md](./05_indexing.md) - 索引机制
- [06_query_execution.md](./06_query_execution.md) - 查询执行流程

### 分布式架构
- [07_replication.md](./07_replication.md) - 复制原理 (含复制流程图)
- [08_sharding.sql](./08_sharding.sql) - 分片原理 (含分布式查询/聚合/JOIN流程图)

## 🎯 快速开始

### 理解 ClickHouse 架构

```
┌─────────────────────────────────────────────────────────────────┐
│                        ClickHouse 架构                            │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│   ┌─────────────┐    ┌─────────────┐    ┌─────────────┐       │
│   │   Client    │    │   HTTP      │    │  Native     │       │
│   │   (TCP)     │    │   Server    │    │  Protocol   │       │
│   └──────┬──────┘    └──────┬──────┘    └──────┬──────┘       │
│          │                   │                   │                │
│          └───────────────────┼───────────────────┘                │
│                              │                                    │
│                      ┌───────▼───────┐                           │
│                      │  Interpreter  │                           │
│                      │    / Parser   │                           │
│                      └───────┬───────┘                           │
│                              │                                    │
│              ┌───────────────┼───────────────┐                   │
│              │               │               │                     │
│      ┌───────▼───────┐ ┌────▼────┐ ┌───────▼───────┐           │
│      │   Optimizer   │ │  Funcs  │ │  Aggregator   │           │
│      └───────┬───────┘ └─────────┘ └───────┬───────┘           │
│              │                               │                     │
│              │         ┌─────────────┐       │                    │
│              │         │ MergeTree   │       │                    │
│              │         │   Engine    │       │                    │
│              │         └──────┬──────┘       │                    │
│              │                │               │                    │
│              │        ┌──────▼──────┐        │                    │
│              │        │   Storage    │        │                    │
│              │        │   (Parts)    │        │                    │
│              │        └─────────────┘        │                    │
│              │                               │                    │
│      ┌───────▼───────────────────────────────▼───────┐           │
│      │              ClickHouse Server                  │           │
│      └───────────────────────────────────────────────┘           │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### 核心概念

```sql
-- 查看 ClickHouse 系统信息
SELECT 
    version() AS version,
    uptime() AS uptime_seconds,
    (SELECT value FROM system.metrics WHERE metric = 'MemoryTracking') / 1024 / 1024 AS memory_mb;
```

### 数据存储结构

```
┌─────────────────────────────────────────────────────────────┐
│                     MergeTree 存储结构                        │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  Table (表)                                                  │
│  ├── Partition 1 (分区)                                      │
│  │   ├── Part 1_1_20240101_20240131                        │
│  │   │   ├── data.bin       (列数据)                        │
│  │   │   ├── data.mrk2      (列标记)                        │
│  │   │   ├── primary.idx    (主键索引)                      │
│  │   │   └── ...                                          │
│  │   └── Part 1_2_20240201_20240229                        │
│  │       └── ...                                           │
│  └── Partition 2 (分区)                                     │
│      └── ...                                                │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### 列式存储优势

```sql
-- 创建测试表展示列式存储
CREATE TABLE IF NOT EXISTS tutorial.column_store_demo (
    id UInt64,
    user_id UInt32,
    event_type String,
    event_date Date,
    value Float64
) ENGINE = MergeTree()
ORDER BY (event_date, user_id);

-- 插入测试数据
INSERT INTO tutorial.column_store_demo
SELECT 
    number AS id,
    number % 1000 AS user_id,
    ['click', 'view', 'purchase'][number % 3 + 1] AS event_type,
    toDate('2024-01-01') + (number % 30) AS event_date,
    rand() / 100.0 AS value
FROM numbers(1000000);

-- 查看存储信息
SELECT 
    column,
    formatReadableSize(sum(compressed_bytes)) AS compressed_size,
    formatReadableSize(sum(data_uncompressed_bytes)) AS uncompressed_size,
    round(sum(data_uncompressed_bytes) / sum(compressed_bytes), 2) AS compression_ratio
FROM system.parts_columns
WHERE database = 'tutorial' AND table = 'column_store_demo' AND active = 1
GROUP BY column
ORDER BY column;
```

## 📊 原理图解

### 列式存储 vs 行式存储

```
行式存储 (Row-oriented):              列式存储 (Column-oriented):
┌─────────────────────────┐           ┌─────────────────────────┐
│ id: 1, name: Alice,    │           │ id:    [1, 2, 3, 4]   │
│ id: 2, name: Bob,      │           │ name:  [Alice, Bob,    │
│ id: 3, name: Charlie,  │    ──►    │       Charlie, David]  │
│ id: 4, name: David     │           │ age:   [25, 30, 35, 40]│
└─────────────────────────┘           └─────────────────────────┘

查询 SELECT avg(age) 时:
- 行式: 读取整行，提取 age 列
- 列式: 只读取 age 列，效率更高
```

### 主键索引工作原理

```
数据文件 (按主键排序):    索引文件 (每 8192 行一个 mark):
┌──────────────────┐     ┌──────────────────┐
│ user_id: 1       │     │ Mark 0: 1        │
│ user_id: 100     │ ──► │ Mark 1: 100      │
│ user_id: 500     │     │ Mark 2: 500      │
│ ...              │     │ ...              │
└──────────────────┘     └──────────────────┘

查询 WHERE user_id = 500:
1. 二分查找定位 mark → Mark 2
2. 读取 Mark 2 对应的数据块
```

## 🔍 核心原理

### 1. 面向列的存储

- **优势**：列式存储在分析查询中表现优异
- **原因**：只需要读取查询涉及的列，减少 I/O
- **压缩**：同一列数据类型相同，压缩效率高

### 2. 稀疏索引

- **主键索引**：不是每行一条索引，而是每 8192 行一个 mark
- **跳数索引**：在主键基础上进一步过滤数据
- **优势**：索引小，查询快

### 3. 数据压缩

- **列级压缩**：每列独立压缩
- **多种算法**：LZ4、ZSTD、Delta 等
- **压缩比**：通常 5-10 倍

### 4. Merge 机制

- **后台合并**：小文件自动合并成大文件
- **去重**：合并时删除重复数据
- **优化**：减少文件数量，提升查询性能

### 5. 向量化执行

- **SIMD 指令**：一次处理多条数据
- **CPU 缓存友好**：按列处理，充分利用缓存
- **内存连续访问**：减少内存随机访问

## 💡 理解检查点

完成本章学习后，你应该能够：

- [ ] 解释 ClickHouse 的整体架构
- [ ] 理解列式存储的优势
- [ ] 了解 MergeTree 引擎的工作原理
- [ ] 掌握主键索引的工作方式
- [ ] 理解数据压缩的原理
- [ ] 了解查询执行的基本流程

## 📚 相关文档

- [01-understanding-clickhouse/](../01-understanding-clickhouse/) - ClickHouse 入门
- [03-engines/](../03-engines/) - 表引擎详解
- [11-performance/](../11-performance/) - 性能优化

## 🔗 更多资源

- [ClickHouse 架构文档](https://clickhouse.com/docs/en/architecture/architecture-overview)
- [MergeTree 引擎原理](https://clickhouse.com/docs/en/engines/table-engines/mergetree-family/mergetree)
- [ClickHouse 存储结构](https://clickhouse.com/docs/en/development/architecture)
