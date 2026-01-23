-- ================================================
-- 14_hardware_tuning_examples.sql
-- 从 14_hardware_tuning.md 提取的 SQL 示例
-- 提取时间: 2026-01-23 14:40:17
-- ================================================


-- ========================================
-- 性能基准测试
-- ========================================

-- 测试插入性能
INSERT INTO events
SELECT 
    number as event_id,
    number % 10000 as user_id,
    'click' as event_type,
    now() as event_time,
    '{}' as event_data
FROM numbers(1000000);

-- 测试查询性能
SELECT count() FROM events;

-- 测试聚合性能
SELECT 
    user_id,
    count() as event_count
FROM events
GROUP BY user_id;

-- 测试 JOIN 性能
SELECT 
    o.order_id,
    u.username
FROM orders o
INNER JOIN users u ON o.user_id = u.user_id;

-- ========================================
-- 性能基准测试
-- ========================================

-- 查看 CPU 使用率
SELECT 
    metric,
    value,
    description
FROM system.metrics
WHERE metric LIKE '%CPU%';

-- ========================================
-- 性能基准测试
-- ========================================

-- 查看内存使用
SELECT 
    metric,
    value,
    description
FROM system.metrics
WHERE metric LIKE '%Memory%';

-- ========================================
-- 性能基准测试
-- ========================================

-- 查看磁盘使用
SELECT 
    metric,
    value,
    description
FROM system.metrics
WHERE metric LIKE '%Disk%';
