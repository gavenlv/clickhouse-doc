# 数据压缩和编码

本文档介绍 ClickHouse 的数据压缩和编码机制。

## 概述

ClickHouse 的高性能很大程度上得益于其高效的数据压缩。列式存储使得同一列的数据类型一致，可以采用高效的压缩算法。

## 压缩原理

```
┌─────────────────────────────────────────────────────────────┐
│                    ClickHouse 压缩原理                        │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  列式存储:                                                    │
│  ┌─────────────────────────────────────────────────────┐   │
│  │ id:    [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, ...]      │   │
│  │        ↓ 相同类型，连续存储                           │   │
│  │        ↓ 适合压缩                                    │   │
│  │ 压缩后: [1-10 的增量序列]                            │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                              │
│  行式存储:                                                    │
│  ┌─────────────────────────────────────────────────────┐   │
│  │ [1, Alice, 25], [2, Bob, 30], [3, ...]            │   │
│  │  不同类型混合，难以有效压缩                           │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

## 压缩算法

### 常用压缩算法

| 算法 | 压缩比 | 速度 | 适用场景 |
|------|--------|------|----------|
| LZ4 | 中等 | 极快 | 通用场景，默认选择 |
| ZSTD | 高 | 快 | 追求高压缩比 |
| Delta | 极高 | 快 | 数值型数据 |
| Gorilla | 极高 | 中 | 时间戳数据 |
| None | 1:1 | 极快 | 无需压缩的数据 |

### LZ4 算法

- **默认算法**
- 压缩速度极快
- 解压速度也快
- 压缩比适中 (约 2-4x)

```sql
-- 使用默认 LZ4 压缩
CREATE TABLE t1 (
    id UInt64,
    data String
) ENGINE = MergeTree()
ORDER BY id
-- 默认就是 LZ4
SETTINGS compression_codec = 'LZ4';
```

### ZSTD 算法

- **高压缩比**
- 速度比 LZ4 稍慢
- 压缩比更高 (约 3-6x)

```sql
-- 使用 ZSTD 压缩
CREATE TABLE t2 (
    id UInt64,
    data String
) ENGINE = MergeTree()
ORDER BY id
SETTINGS compression_codec = 'ZSTD(3)';  -- 1-22，数值越高压缩比越高
```

### Delta 编码

- **数值型数据专用**
- 存储差值而非绝对值
- 适合递增/递减序列

```sql
-- 使用 Delta 编码
CREATE TABLE t3 (
    id UInt64,
    timestamp DateTime,
    value Float64
) ENGINE = MergeTree()
ORDER BY id
SETTINGS compression_codec = 'Delta,t64';
```

### Gorilla 编码

- **时间序列数据专用**
- 专门针对时间戳优化
- 极高的压缩比

```sql
-- 使用 Gorilla 编码
CREATE TABLE t4 (
    id UInt64,
    event_time DateTime64
) ENGINE = MergeTree()
ORDER BY id
SETTINGS compression_codec = 'Gorilla';
```

## 压缩编码实战

### 创建测试表

```sql
CREATE DATABASE IF NOT EXISTS tutorial;

-- 创建多个表对比压缩效果
CREATE TABLE tutorial.compress_lz4 (
    id UInt64,
    value Float64,
    data String
) ENGINE = MergeTree()
ORDER BY id
SETTINGS compression_codec = 'LZ4';

CREATE TABLE tutorial.compress_zstd (
    id UInt64,
    value Float64,
    data String
) ENGINE = MergeTree()
ORDER BY id
SETTINGS compression_codec = 'ZSTD(3)';

CREATE TABLE tutorial.compress_delta (
    id UInt64,
    value Float64,
    data String
) ENGINE = MergeTree()
ORDER BY id
SETTINGS compression_codec = 'Delta';
```

### 插入测试数据

```sql
INSERT INTO tutorial.compress_lz4
SELECT number, rand() / 100.0, repeat('x', 50)
FROM numbers(1000000);

INSERT INTO tutorial.compress_zstd SELECT * FROM tutorial.compress_lz4;
INSERT INTO tutorial.compress_delta SELECT * FROM tutorial.compress_lz4;
```

### 对比压缩效果

```sql
SELECT 
    table,
    formatReadableSize(sum(bytes)) AS compressed_size,
    formatReadableSize(sum(data_uncompressed_bytes)) AS raw_size,
    round(sum(data_uncompressed_bytes) / sum(bytes), 2) AS ratio
FROM system.parts
WHERE database = 'tutorial' 
  AND table LIKE 'compress_%' 
  AND active = 1
GROUP BY table;
```

## 列级压缩

ClickHouse 支持为不同列指定不同的压缩算法：

```sql
CREATE TABLE tutorial.multi_codec (
    id UInt64,
    timestamp DateTime CODEC(Delta, ZSTD),
    value Float64 CODEC(Gorilla),
    category LowCardinality(String) CODEC(ZSTD(1)),
    description String CODEC(LZ4)
) ENGINE = MergeTree()
ORDER BY id;
```

## 低基数优化

### LowCardinality 类型

对于基数较低的字符串列，使用 LowCardinality 可以大幅减少存储：

```sql
-- 普通字符串
CREATE TABLE tutorial.string_normal (
    id UInt64,
    category String
) ENGINE = MergeTree()
ORDER BY id;

-- LowCardinality 字符串
CREATE TABLE tutorial.string_lowcard (
    id UInt64,
    category LowCardinality(String)
) ENGINE = MergeTree()
ORDER BY id;
```

### 对比效果

```sql
INSERT INTO tutorial.string_normal
SELECT number, ['electronics', 'books', 'clothing', 'food'][number % 4 + 1]
FROM numbers(1000000);

INSERT INTO tutorial.string_lowcard SELECT * FROM tutorial.string_normal;

-- 对比存储大小
SELECT 
    table,
    formatReadableSize(sum(bytes)) AS size,
    round(sum(data_uncompressed_bytes) / sum(bytes), 1) AS ratio
FROM system.parts
WHERE database = 'tutorial' 
  AND table LIKE 'string_%'
  AND active = 1
GROUP BY table;
```

## 压缩配置建议

### 表级别配置

```sql
-- 通用场景 (默认 LZ4)
CREATE TABLE t1 (...) ENGINE = MergeTree() ...;

-- 高压缩需求
CREATE TABLE t2 (...) ENGINE = MergeTree()
SETTINGS compression_codec = 'ZSTD(3)';
```

### 列级别配置

```sql
-- 时间序列数据
CREATE TABLE t3 (
    id UInt64,
    ts DateTime64 CODEC(Delta, ZSTD),
    value Float64 CODEC(Gorilla),
    data String CODEC(LZ4)
) ENGINE = MergeTree()
ORDER BY id;
```

### 分区级别配置

```sql
-- 为不同分区指定不同压缩
ALTER TABLE t MODIFY COLUMN value CODEC(ZSTD(5))
WHERE partition = '202401';
```

## 常见问题

### Q1: 压缩算法如何选择？

| 数据特征 | 推荐算法 |
|----------|----------|
| 通用场景 | LZ4 (默认) |
| 追求高压缩比 | ZSTD |
| 数值/ID 序列 | Delta |
| 时间戳序列 | Gorilla |

### Q2: 如何查看当前表的压缩配置？

```sql
SELECT 
    database,
    table,
    storage_policy,
    formatReadableSize(sum(bytes)) AS size
FROM system.parts
WHERE active = 1
GROUP BY database, table, storage_policy;
```

### Q3: 压缩会影响查询性能吗？

- **读取时**: 解压缩是 CPU 密集型，现代 CPU 可以快速处理
- **写入时**: LZ4 速度极快，影响可忽略
- **整体**: 压缩带来的 I/O 减少通常远大于 CPU 解压开销

## 最佳实践

1. **使用默认 LZ4** - 适合大多数场景
2. **时间序列使用 Gorilla** - 对时间戳数据效果极佳
3. **数值序列使用 Delta** - 对连续数值效果很好
4. **低基数字符串使用 LowCardinality** - 显著减少存储
5. **混合编码** - 为不同列选择合适的编码

## 相关 SQL 示例

查看压缩效果：

```sql
-- 查看表的列压缩信息
SELECT 
    column,
    data_type,
    formatReadableSize(sum(compressed_bytes)) AS compressed,
    formatReadableSize(sum(data_uncompressed_bytes)) AS uncompressed,
    round(sum(data_uncompressed_bytes) / sum(compressed_bytes), 1) AS ratio
FROM system.parts_columns
WHERE database = 'tutorial' 
  AND table = 'your_table'
  AND active = 1
GROUP BY column, data_type
ORDER BY ratio DESC;
```

## 下一步

- [05_indexing.md](./05_indexing.md) - 索引机制
- [06_query_execution.md](./06_query_execution.md) - 查询执行流程
