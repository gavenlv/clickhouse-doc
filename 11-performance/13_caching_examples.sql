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

-- ========================================
-- 1. 查询缓存
-- ========================================

-- 启用条件缓存
SET enable_query_cache = 1;

-- 查询（条件被缓存）
SELECT * FROM events
WHERE event_time >= now() - INTERVAL 7 DAY
  AND user_id = 123;

-- ========================================
-- 1. 查询缓存
-- ========================================

-- 配置用户空间页缓存（在 config.xml 中）

-- 使用用户空间页缓存
SELECT 
    user_id,
    event_type,
    event_time
FROM events
WHERE event_time >= now() - INTERVAL 7 DAY
SETTINGS use_page_cache_in_prefetched = 1;

-- ========================================
-- 1. 查询缓存
-- ========================================

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

-- ========================================
-- 1. 查询缓存
-- ========================================

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

-- ========================================
-- 1. 查询缓存
-- ========================================

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

-- ========================================
-- 1. 查询缓存
-- ========================================

-- 查看查询缓存统计
SELECT 
    metric,
    value,
    description
FROM system.metrics
WHERE metric LIKE '%QueryCache%'
ORDER BY metric;

-- ========================================
-- 1. 查询缓存
-- ========================================

-- 查看缓存命中统计
SELECT 
    sum(ProfileEvents['QueryCacheHits']) as cache_hits,
    sum(ProfileEvents['QueryCacheMisses']) as cache_misses,
    cache_hits / (cache_hits + cache_misses) as cache_hit_ratio
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_time >= now() - INTERVAL 24 HOUR;
