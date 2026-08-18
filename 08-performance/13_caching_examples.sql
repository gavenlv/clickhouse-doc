-- ================================================================================
-- ClickHouse 查询缓存优化示例
-- ================================================================================
-- 
-- 集群: treasurycluster (2 副本)
-- 预计学习时间: 15 分钟
-- 
-- 本文件涵盖:
--   1. 查询缓存 - use_query_cache
--   2. 缓存配置 - 最大大小、过期时间
--   3. 页缓存 - use_page_cache_in_prefetched
--   4. 缓存命中率监控 - 统计分析
--   5. 物化视图替代 - 更稳定的缓存方案
-- 
-- 缓存层次结构:
-- 
--   ┌─────────────────────────────────────────────────────────────────────────┐
--   │                    ClickHouse 缓存体系                                  │
--   └─────────────────────────────────────────────────────────────────────────┘
--   
--   Level 1: 操作系统页缓存 (Page Cache)
--   ┌─────────────────────────────────────────────────────────────────────────┐
--   │ 文件系统缓存, 自动管理, 对 ClickHouse 透明                              │
--   │ 热数据文件自动缓存在内存中                                              │
--   └─────────────────────────────────────────────────────────────────────────┘
--   
--   Level 2: ClickHouse 标记缓存 (Mark Cache)
--   ┌─────────────────────────────────────────────────────────────────────────┐
--   │ 缓存 .mrk 文件内容, 加速数据定位                                        │
--   │ mark_cache_size 控制大小                                                │
--   └─────────────────────────────────────────────────────────────────────────┘
--   
--   Level 3: ClickHouse 查询缓存 (Query Cache)
--   ┌─────────────────────────────────────────────────────────────────────────┐
--   │ 缓存完整查询结果, 相同查询直接返回                                       │
--   │ use_query_cache = 1 启用                                                │
--   └─────────────────────────────────────────────────────────────────────────┘
-- 
-- 查询缓存工作流程:
-- 
--   ┌─────────────────────────────────────────────────────────────────────────┐
--   │                    查询缓存流程                                         │
--   └─────────────────────────────────────────────────────────────────────────┘
--   
--   第一次查询:
--   ┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐
--   │ 接收查询 │───>│ 检查缓存 │───>│ 执行查询 │───>│ 存入缓存 │
--   │          │    │  未命中   │    │          │    │          │
--   └──────────┘    └──────────┘    └──────────┘    └──────────┘
--                                          │
--                                          ▼
--                                    ┌──────────┐
--                                    │ 返回结果 │
--                                    └──────────┘
--   
--   第二次相同查询:
--   ┌──────────┐    ┌──────────┐    ┌──────────┐
--   │ 接收查询 │───>│ 检查缓存 │───>│ 返回缓存 │
--   │          │    │  命中    │    │  结果    │
--   └──────────┘    └──────────┘    └──────────┘
--                         │
--                         ▼
--                  响应时间: 0.1ms (vs 原始 1000ms)
-- 
-- 缓存 vs 物化视图:
-- 
--   ┌─────────────────────────────────────────────────────────────────────────┐
--   │                    缓存 vs 物化视图 选择                                │
--   └─────────────────────────────────────────────────────────────────────────┘
--   
--   查询缓存:
--   ✅ 适合: 相同查询频繁执行, 结果变化频繁
--   ❌ 不适合: 查询参数经常变化, 结果需要持久化
--   
--   物化视图:
--   ✅ 适合: 聚合查询, 结果需要持久化, 实时更新
--   ❌ 不适合: 查询条件多样, 不需要实时更新
-- 
-- ================================================================================

SET use_query_cache = 1;
SET query_cache_max_size_in_bytes = 10737418240;  -- 10 GB（25.12 设置名为 query_cache_max_size_in_bytes）
-- 查询中含 now() 等非确定性函数时默认拒绝缓存，需显式允许才能演示命中
SET query_cache_nondeterministic_function_handling = 'save';

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
-- 说明: enable_query_cache 设置已移除，条件缓存由 use_query_cache + 查询特征自动控制
SET use_query_cache = 1;

-- 查询（条件被缓存）
SELECT * FROM events
WHERE event_time >= now() - INTERVAL 7 DAY
  AND user_id = 123;

-- ========================================
-- 1. 查询缓存
-- ========================================

-- 配置用户空间页缓存（在 config.xml 中）

-- 使用用户空间页缓存
-- 25.12 起 use_page_cache_in_prefetched 设置已移除，页缓存由配置文件 <page_cache> 开启
SELECT 
    user_id,
    event_type,
    event_time
FROM events
WHERE event_time >= now() - INTERVAL 7 DAY;

-- ========================================
-- 1. 查询缓存
-- ========================================

-- 启用查询缓存
SET use_query_cache = 1;

-- 查询（会被缓存）
SELECT 
    toDate(event_time) as date,
    count() as event_count,
    sum(event_id) as total_ids
FROM events
WHERE event_time >= now() - INTERVAL 7 DAY
GROUP BY date;

-- 再次查询（使用缓存）
SELECT 
    toDate(event_time) as date,
    count() as event_count,
    sum(event_id) as total_ids
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
DROP TABLE IF EXISTS daily_stats_mv SYNC;
CREATE MATERIALIZED VIEW daily_stats_mv
ENGINE = AggregatingMergeTree()
ORDER BY (date)
AS SELECT
    toDate(event_time) as date,
    countState() as event_count,
    sumState(event_id) as total_ids
FROM events
GROUP BY date;

-- 查询物化视图（比缓存更稳定）
SELECT 
    date,
    countMerge(event_count) as event_count,
    sumMerge(total_ids) as total_ids
FROM daily_stats_mv
WHERE date >= toDate(now() - INTERVAL 30 DAY)
GROUP BY date;

-- ========================================
-- 1. 查询缓存
-- ========================================

-- 查看查询缓存统计
-- 系统表查询不参与缓存，先关闭 use_query_cache
SET use_query_cache = 0;
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

-- 查看缓存命中统计（需启用 query_log）
-- SELECT 
--     sum(ProfileEvents['QueryCacheHits']) as cache_hits,
--     sum(ProfileEvents['QueryCacheMisses']) as cache_misses,
--     cache_hits / (cache_hits + cache_misses) as cache_hit_ratio
-- FROM system.query_log
-- WHERE type = 'QueryFinish'
--   AND event_time >= now() - INTERVAL 24 HOUR;
