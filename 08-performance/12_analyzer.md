# 查询分析器

ClickHouse 查询分析器提供查询优化和性能分析的高级功能。

## 查询分析器功能

### 1. 查询优化

```sql
-- 启用查询优化
SET enable_optimizer = 1;
SET optimize_move_to_prewhere = 1;
SET optimize_where_to_prewhere = 1;

-- 查询
SELECT 
    user_id,
    event_type
FROM events
WHERE event_time >= now() - INTERVAL 7 DAY;
```

### 2. 查询重写

```sql
-- 查看查询重写
EXPLAIN OPTIMIZE
SELECT 
    user_id,
    count() as event_count
FROM events
WHERE event_time >= now() - INTERVAL 7 DAY
GROUP BY user_id;
```

### 3. 查询并行化

```sql
-- 设置并行化
SET parallel_replicas_count = 2;
SET max_threads = 8;
SET max_concurrent_queries = 4;

-- 查询
SELECT * FROM events
WHERE event_time >= now() - INTERVAL 7 DAY;
```

## 分析器参数

### 优化参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| enable_optimizer | 1 | 是否启用查询优化器 |
| optimize_move_to_prewhere | 1 | 是否将 WHERE 移到 PREWHERE |
| optimize_where_to_prewhere | 1 | 是否优化 WHERE 到 PREWHERE |
| optimize_group_by | 1 | 是否优化 GROUP BY |
| optimize_distinct_in_order_by | 1 | 是否优化 DISTINCT 与 ORDER BY |

### 并行化参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| max_threads | CPU 核数 | 最大查询线程数 |
| parallel_replicas_count | 1 | 并行副本数 |
| max_concurrent_queries | 100 | 最大并发查询数 |
| max_concurrent_inserts | 10 | 最大并发插入数 |

## 分析器示例

### 示例 1: 查询重写

```sql
-- 查看重写后的查询
EXPLAIN OPTIMIZE
SELECT DISTINCT user_id
FROM events
WHERE event_time >= now() - INTERVAL 7 DAY;
```

### 示例 2: 并行化查询

```sql
-- 并行化查询
SELECT * FROM events
SETTINGS max_threads = 8,
        parallel_replicas_count = 2
WHERE event_time >= now() - INTERVAL 7 DAY;
```

### 示例 3: 分布式查询优化

```sql
-- 分布式查询优化
SELECT * FROM distributed_events
SETTINGS 
    distributed_product_mode = 'global',
    parallel_replicas_count = 2
WHERE event_time >= now() - INTERVAL 7 DAY;
```

## 分析器最佳实践

1. **启用查询优化**：`enable_optimizer = 1`
2. **使用 PREWHERE**：`optimize_move_to_prewhere = 1`
3. **合理并行化**：根据硬件设置线程数
4. **分布式优化**：使用 GLOBAL JOIN
5. **分析执行计划**：使用 EXPLAIN 查看

## 相关文档

- [01_query_optimization.md](./01_query_optimization.md) - 查询优化基础
- [11_query_profiling.md](./11_query_profiling.md) - 查询分析和 Profiling
