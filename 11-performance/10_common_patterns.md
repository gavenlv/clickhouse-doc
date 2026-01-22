# 常见性能模式

本文档总结了 ClickHouse 中的常见性能问题和优化模式。

## 模式 1: 避免 SELECT *

### 问题描述

使用 `SELECT *` 查询表的所有列，导致读取不必要的数据。

### 解决方案

```sql
-- ❌ 避免
SELECT * FROM events
WHERE event_time >= now() - INTERVAL 7 DAY;

-- ✅ 推荐
SELECT 
    event_id,
    user_id,
    event_type,
    event_time
FROM events
WHERE event_time >= now() - INTERVAL 7 DAY;
```

**性能提升**: 2-10x

## 模式 2: 避免 JOIN 子查询

### 问题描述

在 WHERE 子句中使用子查询，导致性能下降。

### 解决方案

```sql
-- ❌ 避免
SELECT * FROM orders
WHERE user_id IN (SELECT user_id FROM active_users);

-- ✅ 推荐
SELECT o.*
FROM orders o
INNER JOIN active_users u ON o.user_id = u.user_id;
```

**性能提升**: 2-5x

## 模式 3: 避免 WHERE 中的函数

### 问题描述

在 WHERE 子句中对列使用函数，导致无法使用索引。

### 解决方案

```sql
-- ❌ 避免
SELECT * FROM events
WHERE toYYYYMM(event_time) = '202401';

-- ✅ 推荐
SELECT * FROM events
WHERE event_time >= '2024-01-01'
  AND event_time < '2024-02-01';
```

**性能提升**: 5-50x

## 模式 4: 避免 ORDER BY 上的函数

### 问题描述

在 ORDER BY 子句中对列使用函数，导致性能下降。

### 解决方案

```sql
-- ❌ 避免
SELECT * FROM events
ORDER BY toDate(event_time);

-- ✅ 推荐
SELECT 
    event_id,
    user_id,
    event_type,
    event_time,
    toDate(event_time) as date
FROM events
ORDER BY event_time;
```

**性能提升**: 2-10x

## 模式 5: 避免 GROUP BY 上的函数

### 问题描述

在 GROUP BY 子句中对列使用函数，导致性能下降。

### 解决方案

```sql
-- ❌ 避免
SELECT 
    toDate(event_time) as date,
    count() as event_count
FROM events
GROUP BY toDate(event_time);

-- ✅ 推荐
-- 方法 1: 使用物化列
CREATE TABLE events (
    event_id UInt64,
    user_id UInt32,
    event_time DateTime,
    event_date Date MATERIALIZED toDate(event_time)
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (user_id, event_time);

-- 查询
SELECT 
    event_date,
    count() as event_count
FROM events
GROUP BY event_date;

-- 方法 2: 使用物化视图
CREATE MATERIALIZED VIEW event_daily_stats_mv
ENGINE = AggregatingMergeTree()
ORDER BY (event_date)
AS SELECT
    toDate(event_time) as event_date,
    countState() as event_count
FROM events
GROUP BY event_date;

-- 查询
SELECT 
    event_date,
    sumMerge(event_count) as event_count
FROM event_daily_stats_mv
GROUP BY event_date;
```

**性能提升**: 5-20x

## 模式 6: 避免 DISTINCT 上的函数

### 问题描述

在 DISTINCT 中对列使用函数，导致性能下降。

### 解决方案

```sql
-- ❌ 避免
SELECT DISTINCT toDate(event_time) as date
FROM events;

-- ✅ 推荐
SELECT DISTINCT event_time
FROM events;
```

**性能提升**: 2-5x

## 模式 7: 避免 LIMIT OFFSET

### 问题描述

使用 LIMIT OFFSET 进行分页，导致性能随 OFFSET 增加而下降。

### 解决方案

```sql
-- ❌ 避免
SELECT * FROM events
ORDER BY event_time
LIMIT 100 OFFSET 1000;

-- ✅ 推荐
-- 方法 1: 使用游标分页
SELECT * FROM events
WHERE event_time > '2024-01-20 10:00:00'  -- 上一次的最后一条记录的时间
ORDER BY event_time
LIMIT 100;

-- 方法 2: 使用物化视图
CREATE MATERIALIZED VIEW event_ids_mv
ENGINE = MergeTree()
ORDER BY (event_time, event_id)
AS SELECT 
    event_time,
    event_id
FROM events;

-- 分页查询
SELECT e.*
FROM events e
INNER JOIN event_ids_mv m ON e.event_id = m.event_id
WHERE m.event_time >= '2024-01-20 10:00:00'
ORDER BY e.event_time, e.event_id
LIMIT 100;
```

**性能提升**: 5-20x

## 模式 8: 避免 COUNT(DISTINCT)

### 问题描述

使用 COUNT(DISTINCT) 进行聚合，导致性能下降。

### 解决方案

```sql
-- ❌ 避免
SELECT 
    user_id,
    count(DISTINCT event_id) as unique_events
FROM events
GROUP BY user_id;

-- ✅ 推荐
-- 方法 1: 使用 uniqCombined
SELECT 
    user_id,
    uniqCombined(event_id) as unique_events
FROM events
GROUP BY user_id;

-- 方法 2: 使用物化视图
CREATE MATERIALIZED VIEW user_event_stats_mv
ENGINE = AggregatingMergeTree()
ORDER BY (user_id)
AS SELECT
    user_id,
    uniqState(event_id) as unique_events_state
FROM events
GROUP BY user_id;

-- 查询
SELECT 
    user_id,
    uniqMerge(unique_events_state) as unique_events
FROM user_event_stats_mv
GROUP BY user_id;
```

**性能提升**: 2-10x

## 模式 9: 避免 IN 子查询

### 问题描述

在 IN 中使用子查询，导致性能下降。

### 解决方案

```sql
-- ❌ 避免
SELECT * FROM events
WHERE user_id IN (SELECT user_id FROM active_users);

-- ✅ 推荐
-- 方法 1: 使用 JOIN
SELECT e.*
FROM events e
INNER JOIN active_users a ON e.user_id = a.user_id;

-- 方法 2: 使用子查询（限制返回结果）
SELECT * FROM events
WHERE user_id IN (
    SELECT user_id 
    FROM active_users 
    LIMIT 10000
);
```

**性能提升**: 2-5x

## 模式 10: 避免 LIKE 前导通配符

### 问题描述

使用 LIKE '%keyword' 进行查询，导致无法使用索引。

### 解决方案

```sql
-- ❌ 避免
SELECT * FROM events
WHERE event_data LIKE '%keyword%';

-- ✅ 推荐
-- 方法 1: 使用 hasToken
SELECT * FROM events
WHERE hasToken(event_data, 'keyword');

-- 方法 2: 使用 ngrambf_v1 索引
CREATE TABLE events (
    event_id UInt64,
    user_id UInt32,
    event_data String,
    event_time DateTime
) ENGINE = MergeTree()
ORDER BY (user_id, event_time);

ALTER TABLE events
ADD INDEX idx_event_data event_data
TYPE ngrambf_v1(4, 256, 3, 0.01)
GRANULARITY 1;

-- 查询
SELECT * FROM events
WHERE event_data LIKE '%keyword%';
```

**性能提升**: 5-50x

## 模式 11: 避免 OR 条件

### 问题描述

使用 OR 条件，导致性能下降。

### 解决方案

```sql
-- ❌ 避免
SELECT * FROM events
WHERE user_id = 1
   OR user_id = 2
   OR user_id = 3;

-- ✅ 推荐
-- 方法 1: 使用 IN
SELECT * FROM events
WHERE user_id IN (1, 2, 3);

-- 方法 2: 使用 UNION
SELECT * FROM events WHERE user_id = 1
UNION ALL
SELECT * FROM events WHERE user_id = 2
UNION ALL
SELECT * FROM events WHERE user_id = 3;
```

**性能提升**: 2-5x

## 模式 12: 避免跨分区查询

### 问题描述

查询跨越多个分区，导致性能下降。

### 解决方案

```sql
-- ❌ 避免
SELECT * FROM events
WHERE event_time >= '2023-01-01'
  AND event_time < '2024-01-01';

-- ✅ 推荐
-- 查询最近数据
SELECT * FROM events
WHERE event_time >= now() - INTERVAL 30 DAY;

-- 或使用物化视图汇总
CREATE MATERIALIZED VIEW event_daily_stats_mv
ENGINE = SummingMergeTree()
ORDER BY (date)
AS SELECT
    toDate(event_time) as date,
    count() as event_count
FROM events
GROUP BY date;

-- 查询物化视图
SELECT 
    date,
    sum(event_count) as total_events
FROM event_daily_stats_mv
WHERE date >= toDate(now() - INTERVAL 365 DAY)
  AND date <= toDate(now())
GROUP BY date;
```

**性能提升**: 5-50x

## 模式 13: 避免频繁 JOIN

### 问题描述

频繁使用 JOIN，导致性能下降。

### 解决方案

```sql
-- ❌ 避免
SELECT 
    o.order_id,
    o.amount,
    u.username,
    p.product_name
FROM orders o
LEFT JOIN users u ON o.user_id = u.user_id
LEFT JOIN products p ON o.product_id = p.product_id
WHERE o.order_date >= now() - INTERVAL 7 DAY;

-- ✅ 推荐
-- 方法 1: 使用 GLOBAL JOIN
SELECT 
    o.order_id,
    o.amount,
    u.username,
    p.product_name
FROM orders o
GLOBAL LEFT JOIN users u ON o.user_id = u.user_id
GLOBAL LEFT JOIN products p ON o.product_id = p.product_id
WHERE o.order_date >= now() - INTERVAL 7 DAY
SETTINGS distributed_product_mode = 'global';

-- 方法 2: 使用物化视图
CREATE MATERIALIZED VIEW order_user_product_mv
ENGINE = MergeTree()
ORDER BY (order_id)
AS SELECT
    o.order_id,
    o.amount,
    u.username,
    p.product_name
FROM orders o
LEFT JOIN users u ON o.user_id = u.user_id
LEFT JOIN products p ON o.product_id = p.product_id;

-- 查询物化视图
SELECT *
FROM order_user_product_mv
WHERE order_id >= last_processed_order_id
LIMIT 1000;
```

**性能提升**: 2-10x

## 模式 14: 避免重复计算

### 问题描述

在查询中重复计算相同的表达式。

### 解决方案

```sql
-- ❌ 避免
SELECT 
    user_id,
    sum(amount) / count() as avg_amount,
    sum(amount) / count() * 2 as avg_amount_double
FROM orders
GROUP BY user_id;

-- ✅ 推荐
SELECT 
    user_id,
    avg_amount,
    avg_amount * 2 as avg_amount_double
FROM (
    SELECT 
        user_id,
        sum(amount) / count() as avg_amount
    FROM orders
    GROUP BY user_id
)
GROUP BY user_id, avg_amount;
```

**性能提升**: 1.5-3x

## 模式 15: 避免子查询嵌套

### 问题描述

使用多层嵌套子查询，导致性能下降。

### 解决方案

```sql
-- ❌ 避免
SELECT 
    user_id,
    event_count,
    (
        SELECT avg(event_count)
        FROM (
            SELECT 
                user_id,
                count() as event_count
            FROM events
            WHERE event_time >= now() - INTERVAL 30 DAY
            GROUP BY user_id
        )
        WHERE user_id = outer.user_id
    ) as avg_event_count
FROM (
    SELECT 
        user_id,
        count() as event_count
    FROM events
    WHERE event_time >= now() - INTERVAL 30 DAY
    GROUP BY user_id
) outer;

-- ✅ 推荐
-- 方法 1: 使用 JOIN
SELECT 
    e1.user_id,
    e1.event_count,
    e2.avg_event_count
FROM (
    SELECT 
        user_id,
        count() as event_count
    FROM events
    WHERE event_time >= now() - INTERVAL 30 DAY
    GROUP BY user_id
) e1
INNER JOIN (
    SELECT 
        user_id,
        avg(event_count) as avg_event_count
    FROM (
        SELECT 
            user_id,
            count() as event_count
        FROM events
        WHERE event_time >= now() - INTERVAL 30 DAY
        GROUP BY user_id
    )
    GROUP BY user_id
) e2 ON e1.user_id = e2.user_id;

-- 方法 2: 使用窗口函数
SELECT 
    user_id,
    event_count,
    avg(event_count) OVER (PARTITION BY user_id) as avg_event_count
FROM (
    SELECT 
        user_id,
        count() as event_count
    FROM events
    WHERE event_time >= now() - INTERVAL 30 DAY
    GROUP BY user_id
);
```

**性能提升**: 2-10x

## 性能检查清单

- [ ] 是否避免 SELECT *？
  - [ ] 只查询需要的列

- [ ] 是否避免 WHERE 中的函数？
  - [ ] 使用范围查询代替函数

- [ ] 是否避免 JOIN 子查询？
  - [ ] 使用 JOIN 代替子查询

- [ ] 是否避免 LIKE 前导通配符？
  - [ ] 使用 hasToken 或索引

- [ ] 是否避免 OR 条件？
  - [ ] 使用 IN 代替 OR

- [ ] 是否避免频繁 JOIN？
  - [ ] 使用 GLOBAL JOIN 或物化视图

- [ ] 是否避免重复计算？
  - [ ] 使用 CTE 或子查询

## 性能提升总结

| 模式 | 性能提升 |
|------|---------|
| 避免 SELECT * | 2-10x |
| 避免 JOIN 子查询 | 2-5x |
| 避免 WHERE 中的函数 | 5-50x |
| 避免 ORDER BY 上的函数 | 2-10x |
| 避免 GROUP BY 上的函数 | 5-20x |
| 避免 DISTINCT 上的函数 | 2-5x |
| 避免 LIMIT OFFSET | 5-20x |
| 避免 COUNT(DISTINCT) | 2-10x |
| 避免 IN 子查询 | 2-5x |
| 避免 LIKE 前导通配符 | 5-50x |
| 避免 OR 条件 | 2-5x |
| 避免跨分区查询 | 5-50x |
| 避免频繁 JOIN | 2-10x |
| 避免重复计算 | 1.5-3x |
| 避免子查询嵌套 | 2-10x |

## 相关文档

- [01_query_optimization.md](./01_query_optimization.md) - 查询优化基础
- [11_query_profiling.md](./11_query_profiling.md) - 查询分析和 Profiling
