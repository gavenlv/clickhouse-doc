-- ================================================
-- 12_analyzer_examples.sql
-- 从 12_analyzer.md 提取的 SQL 示例
-- 提取时间: 2026-01-23 14:40:17
-- ================================================


-- ========================================
-- 1. 查询优化
-- ========================================

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

-- ========================================
-- 1. 查询优化
-- ========================================

-- 查看查询重写
EXPLAIN OPTIMIZE
SELECT 
    user_id,
    count() as event_count
FROM events
WHERE event_time >= now() - INTERVAL 7 DAY
GROUP BY user_id;

-- ========================================
-- 1. 查询优化
-- ========================================

-- 设置并行化
SET parallel_replicas_count = 2;
SET max_threads = 8;
SET max_concurrent_queries = 4;

-- 查询
SELECT * FROM events
WHERE event_time >= now() - INTERVAL 7 DAY;

-- ========================================
-- 1. 查询优化
-- ========================================

-- 查看重写后的查询
EXPLAIN OPTIMIZE
SELECT DISTINCT user_id
FROM events
WHERE event_time >= now() - INTERVAL 7 DAY;

-- ========================================
-- 1. 查询优化
-- ========================================

-- 并行化查询
SELECT * FROM events
SETTINGS max_threads = 8,
        parallel_replicas_count = 2
WHERE event_time >= now() - INTERVAL 7 DAY;

-- ========================================
-- 1. 查询优化
-- ========================================

-- 分布式查询优化
SELECT * FROM distributed_events
SETTINGS 
    distributed_product_mode = 'global',
    parallel_replicas_count = 2
WHERE event_time >= now() - INTERVAL 7 DAY;
