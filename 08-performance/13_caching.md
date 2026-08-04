# 缓存优化

缓存是 ClickHouse 提升查询性能的重要手段，包括查询缓存、条件缓存和用户空间页缓存。

## 缓存类型

### 1. 查询缓存

```sql
-- 启用查询缓存
SET use_query_cache = 1;
SET query_cache_max_size_bytes = 10737418240;  -- 10 GB

-- 查询（会被缓存）
SELECT 
    user_id,
    count() as event_count
FROM events
WHERE event_time >= now() - INTERVAL 7 DAY
GROUP BY user_id;

-- 再次查询（使用缓存）
SELECT 
    user_id,
    count() as event_count
FROM events
WHERE event_time >= now() - INTERVAL 7 DAY
GROUP BY user_id;
```

### 查询缓存参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| use_query_cache | 0 | 是否启用查询缓存 |
| query_cache_max_size_bytes | 10737418240 | 查询缓存最大大小（10 GB）|
| query_cache_max_elements | 1048576 | 查询缓存最大元素数 |

### 2. 查询条件缓存

```sql
-- 启用条件缓存
SET enable_query_cache = 1;

-- 查询（条件被缓存）
SELECT * FROM events
WHERE event_time >= now() - INTERVAL 7 DAY
  AND user_id = 123;
```

### 3. 用户空间页缓存

```sql
-- 配置用户空间页缓存（在 config.xml 中）
<clickhouse>
    <user_defined_fetches_cache_size>5368709120</user_defined_fetches_cache_size>  <!-- 500 MB -->
    <user_defined_fetches_cache_elements_count>1024</user_defined_fetches_cache_elements_count>
</clickhouse>

-- 使用用户空间页缓存
SELECT 
    user_id,
    event_type,
    event_time
FROM events
WHERE event_time >= now() - INTERVAL 7 DAY
SETTINGS use_page_cache_in_prefetched = 1;
```

## 缓存优化示例

### 示例 1: 缓存聚合查询

```sql
-- 启用查询缓存
SET use_query_cache = 1;

-- 查询（会被缓存）
SELECT 
    toDate(event_time) as date,
    count() as event_count,
    sum(amount) as total_amount
FROM events
WHERE event_time >= now() - INTERVAL 7 DAY
GROUP BY date;

-- 再次查询（使用缓存）
SELECT 
    toDate(event_time) as date,
    count() as event_count,
    sum(amount) as total_amount
FROM events
WHERE event_time >= now() - INTERVAL 7 DAY
GROUP BY date;
```

**性能提升**: 10-100x（缓存命中时）

### 示例 2: 缓存 JOIN 查询

```sql
-- 启用查询缓存
SET use_query_cache = 1;

-- 查询（会被缓存）
SELECT 
    o.order_id,
    o.amount,
    u.username
FROM orders o
INNER JOIN users u ON o.user_id = u.user_id
WHERE o.order_date >= now() - INTERVAL 7 DAY;

-- 再次查询（使用缓存）
SELECT 
    o.order_id,
    o.amount,
    u.username
FROM orders o
INNER JOIN users u ON o.user_id = u.user_id
WHERE o.order_date >= now() - INTERVAL 7 DAY;
```

**性能提升**: 5-50x（缓存命中时）

### 示例 3: 使用物化视图替代缓存

```sql
-- 创建物化视图
CREATE MATERIALIZED VIEW daily_stats_mv
ENGINE = AggregatingMergeTree()
ORDER BY (date)
AS SELECT
    toDate(event_time) as date,
    countState() as event_count,
    sumState(amount) as total_amount
FROM events
GROUP BY date;

-- 查询物化视图（比缓存更稳定）
SELECT 
    date,
    sumMerge(event_count) as event_count,
    sumMerge(total_amount) as total_amount
FROM daily_stats_mv
WHERE date >= toDate(now() - INTERVAL 30 DAY)
GROUP BY date;
```

**性能提升**: 5-20x

## 缓存监控

### 查看缓存统计

```sql
-- 查看查询缓存统计
SELECT 
    metric,
    value,
    description
FROM system.metrics
WHERE metric LIKE '%QueryCache%'
ORDER BY metric;
```

### 查看缓存命中率

```sql
-- 查看缓存命中统计
SELECT 
    sum(ProfileEvents['QueryCacheHits']) as cache_hits,
    sum(ProfileEvents['QueryCacheMisses']) as cache_misses,
    cache_hits / (cache_hits + cache_misses) as cache_hit_ratio
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_time >= now() - INTERVAL 24 HOUR;
```

## 缓存最佳实践

1. **启用查询缓存**：`use_query_cache = 1`
2. **合理设置缓存大小**：10-20 GB
3. **缓存聚合查询**：高计算成本的查询
4. **使用物化视图**：替代缓存（更稳定）
5. **监控缓存命中率**：调整缓存策略

## 缓存检查清单

- [ ] 是否启用查询缓存？
  - [ ] use_query_cache = 1
  - [ ] 合理设置缓存大小

- [ ] 是否监控缓存效果？
  - [ ] 查看缓存统计
  - [ ] 查看缓存命中率
  - [ ] 调整缓存策略

- [ ] 是否使用物化视图？
  - [ ] 创建物化视图
  - [ ] 替代缓存（更稳定）

## 性能提升

| 缓存类型 | 性能提升 |
|---------|---------|
| 查询缓存（命中时）| 10-100x |
| 条件缓存 | 2-10x |
| 用户空间页缓存 | 1.5-5x |

## 相关文档

- [01_query_optimization.md](./01_query_optimization.md) - 查询优化基础
- [11_query_profiling.md](./11_query_profiling.md) - 查询分析和 Profiling
