-- ================================================
-- 05_prewhere_optimization_examples.sql
-- 从 05_prewhere_optimization.md 提取的 SQL 示例
-- 提取时间: 2026-01-23 14:40:17
-- ================================================


-- ========================================
-- 基本 PREWHERE
-- ========================================

SELECT 
    user_id,
    event_type,
    event_time
FROM events
PREWHERE event_time >= now() - INTERVAL 7 DAY
WHERE user_id = 123;

-- ========================================
-- 基本 PREWHERE
-- ========================================

SELECT 
    user_id,
    event_type,
    event_time
FROM events
PREWHERE event_time >= now() - INTERVAL 7 DAY
  AND status = 1
WHERE user_id = 123
  AND event_type = 'click';

-- ========================================
-- 基本 PREWHERE
-- ========================================

-- 编写的查询
SELECT 
    user_id,
    event_type,
    event_time
FROM events
WHERE event_time >= now() - INTERVAL 7 DAY
  AND user_id = 123;

-- ClickHouse 自动优化为
SELECT 
    user_id,
    event_type,
    event_time
FROM events
PREWHERE event_time >= now() - INTERVAL 7 DAY
WHERE user_id = 123;

-- ========================================
-- 基本 PREWHERE
-- ========================================

-- ✅ 使用 PREWHERE 过滤时间范围
SELECT 
    user_id,
    event_type,
    event_data
FROM events
PREWHERE event_time >= now() - INTERVAL 30 DAY
WHERE user_id IN (1, 2, 3, ..., 1000);

-- ❌ 不使用 PREWHERE
SELECT 
    user_id,
    event_type,
    event_data
FROM events
WHERE event_time >= now() - INTERVAL 30 DAY
  AND user_id IN (1, 2, 3, ..., 1000);

-- ========================================
-- 基本 PREWHERE
-- ========================================

-- ✅ 使用 PREWHERE 过滤大列
SELECT 
    user_id,
    event_type
FROM events
PREWHERE event_data LIKE '%keyword%'  -- 过滤大列
WHERE user_id IN (1, 2, 3, ..., 1000);

-- ❌ 不使用 PREWHERE
SELECT 
    user_id,
    event_type
FROM events
WHERE event_data LIKE '%keyword%'
  AND user_id IN (1, 2, 3, ..., 1000);

-- ========================================
-- 基本 PREWHERE
-- ========================================

-- ✅ 使用 PREWHERE 过滤状态
SELECT 
    user_id,
    event_type,
    event_time
FROM events
PREWHERE status = 1  -- 过滤状态
WHERE user_id IN (1, 2, 3, ..., 1000)
  AND event_time >= now() - INTERVAL 7 DAY;

-- ❌ 不使用 PREWHERE
SELECT 
    user_id,
    event_type,
    event_time
FROM events
WHERE status = 1
  AND user_id IN (1, 2, 3, ..., 1000)
  AND event_time >= now() - INTERVAL 7 DAY;

-- ========================================
-- 基本 PREWHERE
-- ========================================

-- ✅ 高选择性条件
SELECT * FROM events
PREWHERE event_time >= now() - INTERVAL 7 DAY  -- 高选择性
WHERE user_id = 123;

-- ❌ 低选择性条件
SELECT * FROM events
PREWHERE status = 1  -- 低选择性
WHERE user_id = 123;

-- ========================================
-- 基本 PREWHERE
-- ========================================

-- ✅ 使用列名
SELECT * FROM events
PREWHERE event_time >= now() - INTERVAL 7 DAY
WHERE user_id = 123;

-- ❌ 使用表达式
SELECT * FROM events
PREWHERE toDate(event_time) >= now() - INTERVAL 7 DAY
WHERE user_id = 123;

-- ========================================
-- 基本 PREWHERE
-- ========================================

-- ✅ 组合多个 PREWHERE 条件
SELECT * FROM events
PREWHERE event_time >= now() - INTERVAL 7 DAY
  AND status = 1
  AND processed = 0
WHERE user_id IN (1, 2, 3, ..., 1000);

-- ========================================
-- 基本 PREWHERE
-- ========================================

-- ✅ 简单条件
SELECT * FROM events
PREWHERE event_time >= now() - INTERVAL 7 DAY
WHERE user_id = 123;

-- ❌ 复杂表达式
SELECT * FROM events
PREWHERE event_time >= now() - INTERVAL 7 DAY
  AND substring(event_data, 1, 10) = 'prefix'
WHERE user_id = 123;

-- ========================================
-- 基本 PREWHERE
-- ========================================

-- 查看是否使用了 PREWHERE
EXPLAIN PIPELINE
SELECT 
    user_id,
    event_type
FROM events
PREWHERE event_time >= now() - INTERVAL 7 DAY
WHERE user_id = 123;

-- ========================================
-- 基本 PREWHERE
-- ========================================

-- 查看过滤统计
SELECT 
    query,
    read_rows,
    read_bytes,
    result_rows,
    result_bytes,
    formatReadableSize(read_bytes) as read_size,
    formatReadableSize(result_bytes) as result_size,
    read_rows / result_rows as filter_ratio
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query LIKE '%PREWHERE%'
  AND event_time >= now() - INTERVAL 24 HOUR
ORDER BY filter_ratio DESC
LIMIT 10;

-- ========================================
-- 基本 PREWHERE
-- ========================================

-- ✅ 大表使用 PREWHERE
SELECT * FROM large_events
PREWHERE event_time >= now() - INTERVAL 7 DAY
WHERE user_id = 123;

-- ❌ 小表不需要 PREWHERE
SELECT * FROM small_events
WHERE event_time >= now() - INTERVAL 7 DAY
  AND user_id = 123;

-- ========================================
-- 基本 PREWHERE
-- ========================================

-- ✅ 高选择性条件
SELECT * FROM events
PREWHERE event_time >= now() - INTERVAL 7 DAY  -- 过滤 80% 数据
WHERE user_id = 123;

-- ❌ 低选择性条件
SELECT * FROM events
PREWHERE status = 1  -- 只过滤 10% 数据
WHERE user_id = 123;

-- ========================================
-- 基本 PREWHERE
-- ========================================

-- ✅ 大列使用 PREWHERE
SELECT 
    user_id,
    event_type
FROM events
PREWHERE event_data LIKE '%keyword%'  -- 大列（100MB+）
WHERE user_id = 123;

-- ❌ 小列不需要 PREWHERE
SELECT 
    user_id,
    event_data
FROM events
WHERE user_id = 123
  AND event_data LIKE '%keyword%';

-- ========================================
-- 基本 PREWHERE
-- ========================================

-- 分析 PREWHERE 效果
SELECT 
    substring(query, 1, 100) as query_sample,
    count() as query_count,
    avg(read_rows) as avg_rows_read,
    avg(result_rows) as avg_rows_result,
    avg(read_rows / result_rows) as avg_filter_ratio
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query LIKE '%PREWHERE%'
  AND event_time >= now() - INTERVAL 7 DAY
GROUP BY query_sample
ORDER BY query_count DESC
LIMIT 10;
