-- ================================================================================
-- ClickHouse 查询分析器优化示例
-- ================================================================================
-- 
-- 集群: treasurycluster (2 副本)
-- 预计学习时间: 10 分钟
-- 
-- 本文件涵盖:
--   1. enable_optimizer - 启用新优化器
--   2. 查询重写 - EXPLAIN OPTIMIZE
--   3. PREWHERE 优化 - optimize_move_to_prewhere
--   4. 并行化设置 - parallel_replicas_count
--   5. 分布式查询 - distributed_product_mode
-- 
-- 查询优化器演进:
-- 
--   ┌─────────────────────────────────────────────────────────────────────────┐
--   │                    ClickHouse 优化器版本                                │
--   └─────────────────────────────────────────────────────────────────────────┘
--   
--   旧优化器 (默认):
--   ┌──────────┐    ┌──────────┐    ┌──────────┐
--   │ 解析SQL  │───>│ 规则优化 │───>│ 执行     │
--   │          │    │ 启发式   │    │          │
--   └──────────┘    └──────────┘    └──────────┘
--   
--   新优化器 (enable_optimizer=1):
--   ┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐
--   │ 解析SQL  │───>│ 基于成本 │───>│ 查询重写 │───>│ 执行     │
--   │          │    │ 优化     │    │          │    │          │
--   └──────────┘    └──────────┘    └──────────┘    └──────────┘
--   
--   新优化器优势:
--   - 更智能的 JOIN 顺序
--   - 更好的子查询优化
--   - 基于成本的计划选择
--   - 更完善的谓词下推
-- 
-- 查询优化选项:
-- 
--   ┌─────────────────────────────────────────────────────────────────────────┐
--   │                    常用优化设置                                         │
--   └─────────────────────────────────────────────────────────────────────────┘
--   
--   enable_optimizer = 1              启用新优化器
--   optimize_move_to_prewhere = 1     自动将条件移到 PREWHERE
--   optimize_where_to_prewhere = 1    WHERE 转 PREWHERE
--   parallel_replicas_count = N       并行副本数
--   distributed_product_mode          分布式 JOIN 模式
--   
--   优化效果:
--   ┌────────────────────────────────────────────────────────────────────────┐
--   │                                                                        │
--   │  原始查询:                                                             │
--   │  SELECT * FROM events WHERE event_time >= now() - INTERVAL 7 DAY      │
--   │                                                                        │
--   │  自动优化后:                                                           │
--   │  SELECT * FROM events PREWHERE event_time >= ... WHERE ...            │
--   │                                                                        │
--   │  效果: 减少IO 50-90%                                                   │
--   │                                                                        │
--   └────────────────────────────────────────────────────────────────────────┘
-- 
-- ================================================================================

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
-- REMOVED SET max_threads (not supported) 8;
-- REMOVED SET max_concurrent_queries (not supported) 4;

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
-- REMOVED SET max_threads (not supported) 8,
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
