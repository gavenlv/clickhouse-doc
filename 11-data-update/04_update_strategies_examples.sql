-- ================================================
-- 04_update_strategies_examples.sql
-- 从 04_update_strategies.md 提取的 SQL 示例
-- 提取时间: 2026-01-23 14:40:17
-- ================================================


-- ========================================
-- SQL Block 1
-- ========================================

-- 创建临时表
CREATE TABLE logs_temp AS logs;

-- 更新数据
INSERT INTO logs_temp
SELECT 
    event_id,
    user_id,
    event_type,
    'processed' as status,
    event_time
FROM logs
WHERE event_time >= '2024-01-01'
  AND event_time < '2024-02-01';

-- 替换分区
ALTER TABLE logs
REPLACE PARTITION '202401'
FROM logs_temp;

-- 清理
DROP TABLE logs_temp;

-- ========================================
-- SQL Block 2
-- ========================================

-- 轻量级更新（ClickHouse 23.8+）
ALTER TABLE users
UPDATE status = 'active',
    last_updated = now()
WHERE user_id IN (1, 2, 3, 4, 5)
SETTINGS lightweight_update = 1;

-- 或使用 Mutation
ALTER TABLE users
UPDATE status = 'active',
    last_updated = now()
WHERE user_id IN (1, 2, 3, 4, 5);

-- ========================================
-- SQL Block 3
-- ========================================

-- 创建修正表
CREATE TABLE orders_fixed AS orders;

-- 修正数据（所有金额增加 10%）
INSERT INTO orders_fixed
SELECT 
    order_id,
    user_id,
    product_id,
    amount * 1.1 as amount,
    order_date,
    status
FROM orders
WHERE toYYYYMM(order_date) IN ('202401', '202402', '202403');

-- 替换分区
ALTER TABLE orders
REPLACE PARTITION '202401', '202402', '202403'
FROM orders_fixed;

-- 清理
DROP TABLE orders_fixed;

-- ========================================
-- SQL Block 4
-- ========================================

-- 方案 1: 轻量级更新
ALTER TABLE orders
UPDATE status = 'completed',
    completed_at = now()
WHERE order_id = 12345
SETTINGS lightweight_update = 1;

-- 方案 2: 重新设计表结构（追加模式）
-- 原表: orders
-- 新表: order_events (事件日志)
-- 查询时取最新事件

-- ========================================
-- SQL Block 5
-- ========================================

-- 创建归档表
CREATE TABLE orders_archive (
    order_id UInt64,
    user_id UInt64,
    amount Float64,
    order_date DateTime,
    status String
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(order_date)
ORDER BY order_id;

-- 交换分区
ALTER TABLE orders_archive
EXCHANGE PARTITION '202301'
WITH orders;

-- 继续交换其他月份...

-- ========================================
-- SQL Block 6
-- ========================================

-- 1. 最新数据使用轻量级更新
ALTER TABLE events
UPDATE status = 'processed'
WHERE event_time >= now() - INTERVAL 7 DAY
SETTINGS lightweight_update = 1;

-- 2. 旧数据使用分区更新归档
ALTER TABLE events_archive
EXCHANGE PARTITION '202312'
WITH events;

-- ========================================
-- SQL Block 7
-- ========================================

-- 创建物化视图
CREATE MATERIALIZED VIEW user_stats_mv
ENGINE = SummingMergeTree()
ORDER BY (user_id, date)
AS SELECT
    user_id,
    toDate(event_time) as date,
    count() as event_count,
    sum(amount) as total_amount
FROM events
GROUP BY user_id, date;

-- 使用 Mutation 更新原表
ALTER TABLE events
UPDATE status = 'processed'
WHERE event_time >= now() - INTERVAL 30 DAY;

-- ========================================
-- SQL Block 8
-- ========================================

-- 1. 使用分区更新
ALTER TABLE users
REPLACE PARTITION '202401'
FROM users_temp;

-- 2. 定期合并
OPTIMIZE TABLE users
PARTITION '202401'
FINAL;

-- ========================================
-- SQL Block 9
-- ========================================

-- 合理的分区策略
CREATE TABLE events (
    event_id UInt64,
    user_id UInt64,
    event_time DateTime,
    event_data String
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)  -- 按月分区
ORDER BY (user_id, event_time);

-- ========================================
-- SQL Block 10
-- ========================================

-- 1. 备份数据
CREATE TABLE users_backup AS users;

-- 2. 检查更新范围
SELECT 
    count() as total_rows,
    formatReadableSize(sum(bytes_on_disk)) as total_size
FROM system.parts
WHERE table = 'users'
  AND partition IN ('202401', '202402');

-- 3. 在测试环境验证
-- 先在测试表上执行更新

-- ========================================
-- SQL Block 11
-- ========================================

-- 监控 Mutation 进度
SELECT 
    mutation_id,
    command,
    is_done,
    parts_to_do,
    progress
FROM system.mutations
WHERE database = 'current_db'
  AND table = 'users'
ORDER BY created DESC;

-- ========================================
-- SQL Block 12
-- ========================================

-- 验证更新结果
SELECT 
    status,
    count() as count
FROM users
WHERE toYYYYMM(created_at) = '202401'
GROUP BY status;

-- ========================================
-- SQL Block 13
-- ========================================

-- 错误做法
ALTER TABLE users UPDATE status = 'active';

-- 正确做法
CREATE TABLE users_temp AS users;
INSERT INTO users_temp SELECT * FROM users WHERE ...;
ALTER TABLE users REPLACE PARTITION '202401' FROM users_temp;

-- ========================================
-- SQL Block 14
-- ========================================

-- 错误做法
-- 每分钟执行一次
ALTER TABLE orders UPDATE status = 'new' WHERE order_id = x;

-- 正确做法
-- 使用事件日志表
CREATE TABLE order_events (
    order_id UInt64,
    event_type String,
    event_time DateTime,
    event_data String
) ENGINE = MergeTree()
ORDER BY (order_id, event_time);

-- 查询时取最新事件

-- ========================================
-- SQL Block 15
-- ========================================

-- 1. 先验证数据
SELECT count() FROM users_temp WHERE status = 'active';

-- 2. 对比数据
SELECT status, count() FROM users WHERE ... GROUP BY status;
SELECT status, count() FROM users_temp WHERE ... GROUP BY status;

-- 3. 确认无误后再替换
ALTER TABLE users REPLACE PARTITION '202401' FROM users_temp;
