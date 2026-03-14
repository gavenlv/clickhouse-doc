# 索引机制

本文档深入介绍 ClickHouse 的索引机制，包括主键索引和跳数索引。

## 概述

ClickHouse 采用稀疏索引设计，这与传统数据库的稠密索引有显著区别。

## 主键索引

### 稀疏索引原理

```
┌─────────────────────────────────────────────────────────────┐
│              ClickHouse 稀疏索引 vs 稠密索引                 │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  稠密索引 (传统数据库如 MySQL):                               │
│  ┌─────────────────────────────────────────────────────┐   │
│  │ Row:    1  2  3  4  5  6  7  8  9  10            │   │
│  │ Index:  ✅ ✅ ✅ ✅ ✅ ✅ ✅ ✅ ✅ ✅             │   │
│  │ 每一行都有一个索引项                                    │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                              │
│  稀疏索引 (ClickHouse):                                      │
│  ┌─────────────────────────────────────────────────────┐   │
│  │ Row:    1  2  3 ... 8192 8193 ...                 │   │
│  │ Index:  ✅        ✅        ✅                       │   │
│  │ 每 8192 行一个索引项                                  │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                              │
│  优势:                                                       │
│  - 索引文件小                                               │
│  - 内存友好                                                 │
│  - 适合大规模数据扫描                                       │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### 主键索引工作流程

```
┌─────────────────────────────────────────────────────────────┐
│                 主键索引查询流程                              │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  查询: SELECT * FROM table WHERE id = 50000                │
│                                                              │
│  步骤 1: 读取主键索引文件                                   │
│  ┌─────────────────────────────────────────────────────┐   │
│  │ Mark 0: id = 1                                     │   │
│  │ Mark 1: id = 8193                                  │   │
│  │ Mark 2: id = 16385                                 │   │
│  │ ...                                                │   │
│  │ Mark N: id = 50000  ← 定位到这一项               │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                              │
│  步骤 2: 二分查找定位 Mark                                   │
│                                                              │
│  步骤 3: 读取对应数据块                                     │
│  ┌─────────────────────────────────────────────────────┐   │
│  │ 从 Mark 6 位置开始读取 ~8192 行数据                 │   │
│  │ 在内存中过滤出 id = 50000 的行                     │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                              │
│  优势:                                                       │
│  - 只需读取少量索引                                         │
│  - 数据读取是顺序的                                         │
│  - 利用 CPU 缓存                                            │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### 创建主键索引

```sql
CREATE TABLE tutorial.primary_key_demo (
    id UInt64,
    user_id UInt32,
    event_date Date,
    event_type String,
    value Float64
) ENGINE = MergeTree()
ORDER BY (event_date, user_id, id)
SETTINGS index_granularity = 8192;
```

### 索引列顺序原则

```sql
-- 好例子: 将高选择性列放在前面
-- 场景: 主要按 user_id 查询，其次按日期
ORDER BY (user_id, event_date, id)

-- 不好例子: 低选择性列在前
-- 如果 event_type 只有 5 个值，不应该放在前面
ORDER BY (event_type, event_date, id)
```

## 跳数索引 (Skip Index)

### 跳数索引概述

跳数索引是在主键索引基础上建立的额外索引，用于跳过不相关的数据块。

```
┌─────────────────────────────────────────────────────────────┐
│                    跳数索引工作原理                           │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  数据文件:                                                   │
│  ┌─────────────────────────────────────────────────────┐   │
│  │ Block 1: event_type = 'click' (5000行)           │   │
│  │ Block 2: event_type = 'view' (3000行)            │   │
│  │ Block 3: event_type = 'click' (2000行)           │   │
│  │ Block 4: event_type = 'purchase' (1000行)        │   │
│  │ Block 5: event_type = 'view' (4000行)            │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                              │
│  set 索引:                                                  │
│  ┌─────────────────────────────────────────────────────┐   │
│  │ Block 1: {'click', 'view'}                        │   │
│  │ Block 2: {'view'}                                 │   │
│  │ Block 3: {'click'}                                │   │
│  │ Block 4: {'purchase'}                             │   │
│  │ Block 5: {'view'}                                 │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                              │
│  查询: WHERE event_type = 'purchase'                        │
│  → 使用 set 索引，跳过 Block 1,2,3,5                      │
│  → 只读取 Block 4                                         │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### 跳数索引类型

| 类型 | 适用场景 | 示例 |
|------|----------|------|
| minmax | 数值范围 | `amount TYPE minmax` |
| set | 低基数枚举 | `status TYPE set(100)` |
| bloom_filter | 高基数字符串 | `email TYPE bloom_filter` |
| tokenbf_v1 | 字符串包含 | `description TYPE tokenbf_v1` |
| ngrambf_v1 | 字符串搜索 | `name TYPE ngrambf_v1` |

### 创建跳数索引

```sql
CREATE TABLE tutorial.skip_index_demo (
    id UInt64,
    event_date Date,
    user_id UInt32,
    event_type String,
    amount Float64,
    email String,
    description String
) ENGINE = MergeTree()
ORDER BY (event_date, user_id, id)
SETTINGS index_granularity = 8192;

-- 添加 minmax 索引 (数值范围)
ALTER TABLE tutorial.skip_index_demo
ADD INDEX idx_amount amount TYPE minmax GRANULARITY 4;

-- 添加 set 索引 (枚举值)
ALTER TABLE tutorial.skip_index_demo
ADD INDEX idx_type event_type TYPE set(100) GRANULARITY 4;

-- 添加 bloom_filter 索引 (高基数字符串)
ALTER TABLE tutorial.skip_index_demo
ADD INDEX idx_email email TYPE bloom_filter(0.01) GRANULARITY 4;

-- 添加 tokenbf_v1 索引 (文本搜索)
ALTER TABLE tutorial.skip_index_demo
ADD INDEX idx_desc description TYPE tokenbf_v1(32768, 3, 0) GRANULARITY 4;
```

### 使索引生效

```sql
-- 插入数据
INSERT INTO tutorial.skip_index_demo
SELECT 
    number,
    toDate('2024-01-01') + (number % 365),
    number % 10000,
    ['click', 'view', 'purchase'][number % 3 + 1],
    rand() / 100.0,
    concat('user', toString(number % 10000), '@example.com'),
    concat('Description for event ', toString(number))
FROM numbers(1000000);

-- 强制创建索引
OPTIMIZE TABLE tutorial.skip_index_demo FINAL;
```

### 查看跳数索引

```sql
-- 查看索引信息
SELECT 
    table,
    name AS index_name,
    type,
    expr,
    granularity,
    formatReadableSize(data_compressed_bytes) AS compressed,
    formatReadableSize(data_uncompressed_bytes) AS uncompressed
FROM system.data_skipping_indices
WHERE database = 'tutorial';

-- 查看索引使用情况
SELECT 
    table,
    name AS index_name,
    granules,
    marks,
    read_rows,
    formatReadableSize(data_compressed_bytes) AS compressed
FROM system.data_skipping_indices
WHERE database = 'tutorial';
```

### 测试跳数索引效果

```sql
-- 测试 1: 使用 amount 索引
SELECT count() FROM tutorial.skip_index_demo
WHERE amount > 500;

-- 测试 2: 使用 event_type 索引
SELECT count() FROM tutorial.skip_index_demo
WHERE event_type = 'purchase';

-- 测试 3: 使用 email 索引
SELECT count() FROM tutorial.skip_index_demo
WHERE email LIKE '%1234%';
```

## 索引优化最佳实践

### 1. 主键设计原则

```sql
-- 原则 1: 将常用查询条件放在前面
ORDER BY (query_column_1, query_column_2, id)

-- 原则 2: 高选择性列优先
-- 好的: user_id (高选择性)
-- 差的: status (低选择性，只有 5 个值)

-- 原则 3: 避免过多列
-- 建议: 2-4 列
```

### 2. 跳数索引使用原则

```sql
-- 只为高频查询创建
-- 避免创建过多索引

-- 选择合适的索引类型
-- 低基数 → set 索引
-- 高基数 → bloom_filter 索引
-- 范围查询 → minmax 索引
```

### 3. 索引粒度选择

```sql
-- index_granularity: 每个 mark 包含的行数
-- 默认: 8192

-- 大数据量: 可以使用更大的粒度 (16384, 32768)
-- 小数据量: 使用更小的粒度 (4096)

CREATE TABLE t1 (...) ENGINE = MergeTree()
ORDER BY id
SETTINGS index_granularity = 16384;
```

## 索引原理详解

### 数据结构

```
┌─────────────────────────────────────────────────────────────┐
│                   ClickHouse 索引数据结构                     │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  primary.idx (主键索引):                                    │
│  ┌─────────────────────────────────────────────────────┐   │
│  │ [key1_key2_key3] → position 0                      │   │
│  │ [key1_key2_key4] → position 8192                   │   │
│  │ [key1_key3_key1] → position 16384                 │   │
│  │ ...                                                │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                              │
│  data.mrk2 (列标记文件):                                     │
│  ┌─────────────────────────────────────────────────────┐   │
│  │ 列 1: [offset1, offset2, offset3, ...]             │   │
│  │ 列 2: [offset1, offset2, offset3, ...]             │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                              │
│  data.bin (列数据文件):                                      │
│  ┌─────────────────────────────────────────────────────┐   │
│  │ [column1 data] [column1 data] ...                 │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### 查询执行中的索引使用

```sql
-- 查看查询执行计划
EXPLAIN PLAN 
SELECT count() FROM tutorial.skip_index_demo
WHERE event_type = 'purchase' AND amount > 100;

-- 查看索引使用
SELECT 
    name,
    use_count
FROM system.data_skipping_indices
WHERE database = 'tutorial';
```

## 相关 SQL

### 查看索引统计

```sql
-- 查看表的所有索引
SHOW INDEX FROM tutorial.skip_index_demo;

-- 查看索引使用情况
SELECT 
    database,
    table,
    name AS index_name,
    type,
    use_count,
    formatReadableSize(data_compressed_bytes) AS size
FROM system.data_skipping_indices
WHERE database = 'tutorial';
```

### 删除索引

```sql
ALTER TABLE tutorial.skip_index_demo
DROP INDEX idx_amount;
```

## 下一步

- [06_query_execution.md](./06_query_execution.md) - 查询执行流程
- [07_replication.md](./07_replication.md) - 复制和分片原理
