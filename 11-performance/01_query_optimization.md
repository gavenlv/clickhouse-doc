# 查询优化基础

查询优化是 ClickHouse 性能优化的核心，通过合理的查询设计可以显著提升查询性能。

## 基本原则

### 1. 使用分区裁剪

```sql
-- ✅ 使用分区裁剪（快速）
SELECT * FROM events
WHERE event_time >= now() - INTERVAL 7 DAY;

-- ❌ 不使用分区裁剪（慢速）
SELECT * FROM events
WHERE toYYYYMM(event_time) >= toYYYYMM(now() - INTERVAL 7 DAY);
```

### 2. 使用主键查询

```sql
-- ✅ 使用主键（快速）
SELECT * FROM users
WHERE user_id = 123;

-- ❌ 不使用主键（慢速）
SELECT * FROM users
WHERE email = 'user@example.com';
```

### 3. 避免在 WHERE 中使用函数

```sql
-- ❌ 在 WHERE 中使用函数（慢速）
SELECT * FROM users
WHERE toYYYYMM(created_at) = '202401';

-- ✅ 使用常量范围（快速）
SELECT * FROM users
WHERE created_at >= '2024-01-01'
  AND created_at < '2024-02-01';
```

### 4. 使用 PREWHERE 优化

```sql
-- 使用 PREWHERE 过滤大列
SELECT 
    user_id,
    event_type,
    event_time
FROM events
PREWHERE event_time >= now() - INTERVAL 7 DAY
WHERE user_id = 123;
```

### 5. 限制返回的数据量

```sql
-- 使用 LIMIT
SELECT * FROM events
WHERE event_time >= now() - INTERVAL 7 DAY
LIMIT 1000;

-- 使用 SAMPLE 采样
SELECT * FROM events
SAMPLE 0.1  -- 10% 的数据
WHERE event_time >= now() - INTERVAL 7 DAY;
```

## 查询执行计划

### EXPLAIN PLAN

```sql
-- 查看查询执行计划
EXPLAIN PLAN
SELECT 
    user_id,
    count() as event_count
FROM events
WHERE event_time >= now() - INTERVAL 7 DAY
GROUP BY user_id;
```

**输出示例**：
```
EXPLAIN PLAN
SELECT 
    user_id,
    count() as event_count
FROM events
WHERE event_time >= now() - INTERVAL 7 DAY
GROUP BY user_id

Query Pipeline
  Expression
    Expression (Projection)
      Aggregating
        Expression (Before GROUP BY)
          ReadFromMergeTree (events)
          Parts: 10/10
          Columns: user_id, event_time, event_type
```

### EXPLAIN PIPELINE

```sql
-- 查看查询管道
EXPLAIN PIPELINE
SELECT 
    user_id,
    count() as event_count
FROM events
WHERE event_time >= now() - INTERVAL 7 DAY
GROUP BY user_id;
```

### EXPLAIN ESTIMATE

```sql
-- 查看查询预估
EXPLAIN ESTIMATE
SELECT 
    user_id,
    count() as event_count
FROM events
WHERE event_time >= now() - INTERVAL 7 DAY
GROUP BY user_id;
```

## 查询优化技巧

### 技巧 1: 使用 IN 而非 OR

```sql
-- ❌ 使用 OR（慢速）
SELECT * FROM users
WHERE user_id = 1 
   OR user_id = 2 
   OR user_id = 3;

-- ✅ 使用 IN（快速）
SELECT * FROM users
WHERE user_id IN (1, 2, 3);
```

### 技巧 2: 使用 JOIN 而非子查询

```sql
-- ❌ 使用子查询（慢速）
SELECT * FROM orders
WHERE user_id IN (SELECT user_id FROM active_users);

-- ✅ 使用 JOIN（快速）
SELECT o.*
FROM orders o
INNER JOIN active_users u ON o.user_id = u.user_id;
```

### 技巧 3: 使用物化列

```sql
-- 创建物化列
CREATE TABLE events (
    event_id UInt64,
    user_id UInt64,
    event_type String,
    event_time DateTime,
    event_date Date MATERIALIZED toDate(event_time),
    event_month String MATERIALIZED formatDateTime(event_time, '%Y-%m')
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (user_id, event_time);

-- 查询时使用物化列
SELECT 
    user_id,
    count() as event_count
FROM events
WHERE event_month = '2024-01'
GROUP BY user_id;
```

### 技巧 4: 使用 LIMIT BY

```sql
-- 获取每个用户的最新事件
SELECT *
FROM events
WHERE event_time >= now() - INTERVAL 7 DAY
ORDER BY user_id, event_time DESC
LIMIT 1 BY user_id;
```

### 技巧 5: 使用 DISTINCT 替代 GROUP BY

```sql
-- ❌ 使用 GROUP BY（慢速）
SELECT user_id FROM events GROUP BY user_id;

-- ✅ 使用 DISTINCT（快速）
SELECT DISTINCT user_id FROM events;
```

## 查询并行化

### 设置并行度

```sql
-- 设置并行线程数
SELECT * FROM events
SETTINGS max_threads = 8
WHERE event_time >= now() - INTERVAL 7 DAY;

-- 设置并发读取
SELECT * FROM events
SETTINGS max_concurrent_queries = 4
WHERE event_time >= now() - INTERVAL 7 DAY;
```

### 分布式查询并行

```sql
-- 设置分布式查询并行
SELECT * FROM distributed_table
SETTINGS max_parallel_replicas = 2
WHERE event_time >= now() - INTERVAL 7 DAY;
```

## 查询性能分析

### 查看查询日志

```sql
-- 查看最近的查询
SELECT 
    query,
    query_duration_ms,
    read_rows,
    read_bytes,
    written_rows,
    memory_usage,
    event_time
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_time >= now() - INTERVAL 1 HOUR
ORDER BY event_time DESC
LIMIT 10;
```

### 分析慢查询

```sql
-- 查看慢查询
SELECT 
    query,
    query_duration_ms,
    read_rows,
    read_bytes,
    memory_usage,
    formatReadableSize(read_bytes) as readable_bytes
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query_duration_ms > 1000
ORDER BY query_duration_ms DESC
LIMIT 20;
```

### 查看查询统计

```sql
-- 查看查询统计
SELECT 
    substring(query, 1, 50) as query_sample,
    count() as query_count,
    avg(query_duration_ms) as avg_duration,
    max(query_duration_ms) as max_duration,
    sum(read_rows) as total_rows_read,
    sum(read_bytes) as total_bytes_read
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_time >= now() - INTERVAL 24 HOUR
GROUP BY query_sample
ORDER BY query_count DESC
LIMIT 10;
```

## 查询优化示例

### 示例 1: 时间范围查询优化

```sql
-- ❌ 优化前
SELECT * FROM events
WHERE toYYYYMMDD(event_time) >= '20240101'
  AND toYYYYMMDD(event_time) < '20240201';

-- ✅ 优化后
SELECT * FROM events
WHERE event_time >= '2024-01-01'
  AND event_time < '2024-02-01';
```

### 示例 2: 聚合查询优化

```sql
-- ❌ 优化前
SELECT 
    user_id,
    count() as event_count
FROM events
WHERE event_time >= now() - INTERVAL 30 DAY
GROUP BY user_id
HAVING count() > 100;

-- ✅ 优化后（使用物化视图）
CREATE MATERIALIZED VIEW user_event_count_mv
ENGINE = AggregatingMergeTree()
ORDER BY (user_id, toStartOfDay(event_time))
AS SELECT
    user_id,
    toStartOfDay(event_time) as date,
    countState() as event_count
FROM events
GROUP BY user_id, date;

-- 查询物化视图
SELECT 
    user_id,
    sumMerge(event_count) as total_events
FROM user_event_count_mv
WHERE date >= now() - INTERVAL 30 DAY
GROUP BY user_id
HAVING sumMerge(event_count) > 100;
```

### 示例 3: JOIN 查询优化

```sql
-- ❌ 优化前
SELECT 
    o.order_id,
    o.amount,
    u.username
FROM orders o
LEFT JOIN users u ON o.user_id = u.user_id
WHERE o.order_date >= now() - INTERVAL 30 DAY;

-- ✅ 优化后（使用分布式 JOIN）
SELECT 
    o.order_id,
    o.amount,
    u.username
FROM orders o
GLOBAL LEFT JOIN users u ON o.user_id = u.user_id
WHERE o.order_date >= now() - INTERVAL 30 DAY
SETTINGS distributed_product_mode = 'global';
```

## 查询优化检查清单

- [ ] 是否使用分区裁剪？
  - [ ] 查询条件包含分区键
  - [ ] 避免在分区键上使用函数

- [ ] 是否使用主键？
  - [ ] 查询条件包含主键列
  - [ ] 避免在主键上使用函数

- [ ] 是否避免函数计算？
  - [ ] WHERE 中避免函数
  - [ ] 预计算常用表达式

- [ ] 是否使用 PREWHERE？
  - [ ] 大表查询使用 PREWHERE
  - [ ] PREWHERE 条件有选择性

- [ ] 是否限制返回数据？
  - [ ] 使用 LIMIT
  - [ ] 使用 SAMPLE 采样

- [ ] 是否使用并行化？
  - [ ] 设置合适的并行度
  - [ ] 利用分布式并行

## 性能提升

| 优化方法 | 性能提升 |
|---------|---------|
| 使用分区裁剪 | 5-20x |
| 使用主键 | 10-100x |
| 避免函数计算 | 2-10x |
| 使用 PREWHERE | 2-5x |
| 使用 JOIN 替代子查询 | 2-5x |
| 使用物化列 | 5-50x |
| 查询并行化 | 2-8x |

## 相关文档

- [02_primary_indexes.md](./02_primary_indexes.md) - 主键索引优化
- [03_partitioning.md](./03_partitioning.md) - 分区键优化
- [04_skipping_indexes.md](./04_skipping_indexes.md) - 数据跳数索引
- [11_query_profiling.md](./11_query_profiling.md) - 查询分析和 Profiling
