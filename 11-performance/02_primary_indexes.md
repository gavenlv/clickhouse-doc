# 主键索引优化

主键是 ClickHouse 中最重要的索引，合理设计主键可以显著提升查询性能。

## 基本概念

### 主键特性

- **物理排序**：数据按主键物理排序存储
- **快速范围查询**：支持主键的范围查询
- **唯一性**：不强制唯一，但影响数据分布
- **粒度**：由 `index_granularity` 控制（默认 8192）

### 与排序键的关系

- **主键**：用于数据索引和快速查找
- **排序键**：用于数据排序（默认等于主键）
- **关系**：主键必须是排序键的前缀

## 主键设计原则

### 原则 1: 高选择性

```sql
-- ✅ 高选择性主键
CREATE TABLE events (
    event_id UInt64,
    user_id UInt64,
    event_time DateTime,
    event_data String
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (user_id, event_time);  -- user_id 高选择性

-- ❌ 低选择性主键
CREATE TABLE events (
    event_id UInt64,
    user_id UInt64,
    event_type String,
    event_time DateTime
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_type, event_time);  -- event_type 低选择性
```

### 原则 2: 查询模式匹配

```sql
-- 如果查询主要按 user_id 和 event_time
CREATE TABLE events (
    event_id UInt64,
    user_id UInt64,
    event_type String,
    event_time DateTime
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (user_id, event_time);  -- ✅ 匹配查询模式

-- 如果查询主要按 event_type 和 event_time
CREATE TABLE events (
    event_id UInt64,
    user_id UInt64,
    event_type String,
    event_time DateTime
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_type, event_time);  -- ✅ 匹配查询模式
```

### 原则 3: 列数量适中

```sql
-- ✅ 2-3 列的主键
CREATE TABLE events (
    event_id UInt64,
    user_id UInt64,
    event_type String,
    event_time DateTime
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (user_id, event_time);  -- ✅ 2 列

-- ❌ 过多列的主键
CREATE TABLE events (
    event_id UInt64,
    user_id UInt64,
    event_type String,
    event_category String,
    event_subcategory String,
    event_time DateTime
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (user_id, event_type, event_category, 
          event_subcategory, event_time);  -- ❌ 5 列
```

### 原则 4: 时间列在最后

```sql
-- ✅ 时间列在最后
CREATE TABLE events (
    event_id UInt64,
    user_id UInt64,
    event_type String,
    event_time DateTime
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (user_id, event_type, event_time);  -- ✅ 时间在最后

-- ❌ 时间列不在最后
CREATE TABLE events (
    event_id UInt64,
    user_id UInt64,
    event_time DateTime,
    event_type String
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_time, user_id, event_type);  -- ❌ 时间在最前
```

## 主键查询优化

### 范围查询

```sql
-- ✅ 使用主键范围查询
SELECT * FROM events
WHERE user_id = 123
  AND event_time >= '2024-01-01'
  AND event_time < '2024-02-01';

-- ✅ 使用主键 IN 查询
SELECT * FROM events
WHERE user_id IN (1, 2, 3, 4, 5)
  AND event_time >= now() - INTERVAL 7 DAY;
```

### 前缀查询

```sql
-- ✅ 使用主键前缀查询
SELECT * FROM events
WHERE user_id = 123;  -- 只使用主键第一列

-- ✅ 使用主键前两列
SELECT * FROM events
WHERE user_id = 123
  AND event_type = 'click';
```

### 避免函数

```sql
-- ❌ 在主键上使用函数（慢速）
SELECT * FROM events
WHERE toYYYYMM(event_time) = '202401';

-- ✅ 使用范围查询（快速）
SELECT * FROM events
WHERE event_time >= '2024-01-01'
  AND event_time < '2024-02-01';
```

## 索引粒度优化

### 设置索引粒度

```sql
-- 创建表时设置索引粒度
CREATE TABLE events (
    event_id UInt64,
    user_id UInt64,
    event_time DateTime,
    event_data String
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (user_id, event_time)
SETTINGS index_granularity = 8192;  -- 默认值
```

### 不同粒度的性能

| 索引粒度 | 读取性能 | 写入性能 | 存储空间 | 适用场景 |
|----------|---------|---------|---------|---------|
| 1024 | 高 | 低 | 大 | 读取密集型 |
| 4096 | 中高 | 中 | 中大 | 混合型 |
| 8192 | 中 | 中高 | 中 | 混合型（默认）|
| 16384 | 中低 | 高 | 中小 | 写入密集型 |
| 32768 | 低 | 很高 | 小 | 写入密集型 |

### 调整索引粒度

```sql
-- 读取密集型：较小的粒度
CREATE TABLE events_read (
    event_id UInt64,
    user_id UInt64,
    event_time DateTime
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (user_id, event_time)
SETTINGS index_granularity = 4096;

-- 写入密集型：较大的粒度
CREATE TABLE events_write (
    event_id UInt64,
    user_id UInt64,
    event_time DateTime
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (user_id, event_time)
SETTINGS index_granularity = 16384;
```

## 主键分析

### 查看主键使用情况

```sql
-- 查看表的主键
SELECT 
    database,
    table,
    primary_key,
    sorting_key
FROM system.tables
WHERE database = 'my_database';
```

### 分析主键效果

```sql
-- 查看主键扫描情况
SELECT 
    query,
    read_rows,
    read_bytes,
    result_rows,
    result_bytes,
    formatReadableSize(read_bytes) as read_size,
    formatReadableSize(result_bytes) as result_size
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_time >= now() - INTERVAL 24 HOUR
  AND read_rows > 1000000
ORDER BY read_rows DESC
LIMIT 10;
```

### 查看索引使用率

```sql
-- 查看索引使用情况
SELECT 
    table,
    partition,
    name,
    type,
    rows,
    bytes_on_disk,
    marks_count
FROM system.data_skipping_indices
WHERE database = 'my_database';
```

## 主键优化示例

### 示例 1: 事件表主键优化

```sql
-- 优化前
CREATE TABLE events (
    event_id UInt64,
    user_id UInt64,
    event_type String,
    event_time DateTime,
    event_data String
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_time);  -- ❌ 只有时间

-- 优化后
CREATE TABLE events (
    event_id UInt64,
    user_id UInt64,
    event_type String,
    event_time DateTime,
    event_data String
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (user_id, event_time);  -- ✅ user_id + time
```

**性能提升**: 10-50x（按 user_id 查询时）

### 示例 2: 订单表主键优化

```sql
-- 优化前
CREATE TABLE orders (
    order_id UInt64,
    user_id UInt64,
    product_id UInt64,
    amount Float64,
    order_date DateTime,
    status String
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(order_date)
ORDER BY (order_id);  -- ❌ 只有 order_id

-- 优化后
CREATE TABLE orders (
    order_id UInt64,
    user_id UInt64,
    product_id UInt64,
    amount Float64,
    order_date DateTime,
    status String
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(order_date)
ORDER BY (user_id, order_date, order_id);  -- ✅ user_id + date + order_id
```

**性能提升**: 5-20x（按 user_id 和日期查询时）

### 示例 3: 用户表主键优化

```sql
-- 优化前
CREATE TABLE users (
    user_id UInt64,
    username String,
    email String,
    created_at DateTime,
    last_login DateTime
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(created_at)
ORDER BY (created_at);  -- ❌ 只有时间

-- 优化后
CREATE TABLE users (
    user_id UInt64,
    username String,
    email String,
    created_at DateTime,
    last_login DateTime
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(created_at)
ORDER BY (user_id, created_at);  -- ✅ user_id + time
```

**性能提升**: 100-1000x（按 user_id 查询时）

## 主键最佳实践

### 1. 包含查询条件

```sql
-- 如果经常按 user_id 查询
CREATE TABLE events (
    user_id UInt64,
    event_id UInt64,
    event_time DateTime
) ENGINE = MergeTree()
ORDER BY (user_id, event_time);  -- ✅ user_id 在主键中
```

### 2. 保持高选择性

```sql
-- ✅ 高选择性列在前
ORDER BY (user_id, event_type);

-- ❌ 低选择性列在前
ORDER BY (event_type, user_id);
```

### 3. 避免过多列

```sql
-- ✅ 2-3 列
ORDER BY (user_id, event_time);

-- ❌ 过多列
ORDER BY (user_id, event_type, event_category, event_time);
```

### 4. 时间列在最后

```sql
-- ✅ 时间列在最后
ORDER BY (user_id, event_type, event_time);

-- ❌ 时间列在最前
ORDER BY (event_time, user_id, event_type);
```

### 5. 定期分析效果

```sql
-- 定期分析主键使用情况
SELECT 
    query,
    count() as query_count,
    avg(read_rows) as avg_rows_read,
    avg(query_duration_ms) as avg_duration
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_time >= now() - INTERVAL 7 DAY
GROUP BY query
ORDER BY query_count DESC
LIMIT 10;
```

## 主键检查清单

- [ ] 主键是否包含常用查询条件？
  - [ ] 分析查询模式
  - [ ] 识别高频查询列

- [ ] 主键列顺序是否合理？
  - [ ] 高选择性列在前
  - [ ] 时间列在最后

- [ ] 主键列数量是否适中？
  - [ ] 2-3 列（推荐）
  - [ ] 不超过 5 列

- [ ] 索引粒度是否合适？
  - [ ] 读取密集型：4096-8192
  - [ ] 写入密集型：8192-16384
  - [ ] 混合型：8192（默认）

- [ ] 是否定期分析效果？
  - [ ] 分析查询日志
  - [ ] 查看索引使用率
  - [ ] 调整主键设计

## 性能提升

| 优化方法 | 性能提升 |
|---------|---------|
| 合理设计主键 | 10-100x |
| 使用主键查询 | 100-1000x |
| 调整索引粒度 | 1.5-5x |
| 避免函数计算 | 2-10x |
| 使用范围查询 | 5-20x |

## 相关文档

- [01_query_optimization.md](./01_query_optimization.md) - 查询优化基础
- [03_partitioning.md](./03_partitioning.md) - 分区键优化
- [04_skipping_indexes.md](./04_skipping_indexes.md) - 数据跳数索引
- [11_query_profiling.md](./11_query_profiling.md) - 查询分析和 Profiling
