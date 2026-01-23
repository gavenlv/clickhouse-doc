-- ================================================
-- 07_batch_updates_examples.sql
-- 从 07_batch_updates.md 提取的 SQL 示例
-- 提取时间: 2026-01-23 14:40:17
-- ================================================


-- ========================================
-- 解决方案
-- ========================================

-- 方案 1: 使用轻量级更新（推荐，ClickHouse 23.8+）
ALTER TABLE users
UPDATE status = 'active',
    status_updated_at = now()
WHERE user_id IN (
    SELECT DISTINCT user_id
    FROM user_logins
    WHERE login_time >= now() - INTERVAL 30 DAY
)
SETTINGS lightweight_update = 1;

-- 方案 2: 使用 Mutation（ClickHouse < 23.8）
ALTER TABLE users
UPDATE status = 'active',
    status_updated_at = now()
WHERE user_id IN (
    SELECT DISTINCT user_id
    FROM user_logins
    WHERE login_time >= now() - INTERVAL 30 DAY
);

-- 方案 3: 分区更新（如果更新量 > 30%）
-- 创建临时表
CREATE TABLE users_temp AS users;

-- 更新数据
INSERT INTO users_temp
SELECT 
    user_id,
    username,
    email,
    'active' as status,
    status_updated_at,
    created_at,
    last_login
FROM users
WHERE user_id IN (
    SELECT DISTINCT user_id
    FROM user_logins
    WHERE login_time >= now() - INTERVAL 30 DAY
);

-- 替换分区
ALTER TABLE users
REPLACE PARTITION '202401', '202402'
FROM users_temp;

-- 清理
DROP TABLE users_temp;

-- ========================================
-- 解决方案
-- ========================================

-- 监控更新进度
SELECT 
    mutation_id,
    command,
    is_done,
    parts_to_do,
    progress,
    created_at
FROM system.mutations
WHERE database = 'current_db'
  AND table = 'users'
ORDER BY created DESC
LIMIT 1;

-- ========================================
-- 解决方案
-- ========================================

-- 方案 1: 直接更新（适用于小批量）
ALTER TABLE orders
UPDATE amount = amount * 1.1,
    adjusted_at = now()
WHERE status = 'pending'
  AND order_date >= '2024-01-01';

-- 方案 2: 分批更新（适用于大批量）
-- 批次 1: 2024年1月
ALTER TABLE orders
UPDATE amount = amount * 1.1,
    adjusted_at = now()
WHERE status = 'pending'
  AND toYYYYMM(order_date) = '202401'
SETTINGS max_threads = 4;

-- 等待完成后执行下一批次
-- 批次 2: 2024年2月
ALTER TABLE orders
UPDATE amount = amount * 1.1,
    adjusted_at = now()
WHERE status = 'pending'
  AND toYYYYMM(order_date) = '202402'
SETTINGS max_threads = 4;

-- 继续分批...

-- 方案 3: 分区更新（最快速）
-- 创建临时表
CREATE TABLE orders_temp AS orders;

-- 更新数据
INSERT INTO orders_temp
SELECT 
    order_id,
    user_id,
    product_id,
    amount * 1.1 as amount,
    order_date,
    'pending' as status,
    adjusted_at,
    created_at
FROM orders
WHERE toYYYYMM(order_date) IN ('202401', '202402', '202403')
  AND status = 'pending';

-- 替换分区
ALTER TABLE orders
REPLACE PARTITION '202401', '202402', '202403'
FROM orders_temp;

-- 清理
DROP TABLE orders_temp;

-- ========================================
-- 解决方案
-- ========================================

-- 验证更新结果
SELECT 
    toYYYYMM(order_date) as month,
    count() as order_count,
    sum(amount) as total_amount,
    avg(amount) as avg_amount,
    min(adjusted_at) as first_adjustment,
    max(adjusted_at) as last_adjustment
FROM orders
WHERE status = 'pending'
  AND adjusted_at >= now() - INTERVAL 1 HOUR
GROUP BY month
ORDER BY month;

-- ========================================
-- 解决方案
-- ========================================

-- 创建修正表
CREATE TABLE events_fixed AS events;

-- 修正数据
INSERT INTO events_fixed
SELECT 
    event_id,
    user_id,
    event_type,
    -- 修正 event_type 的拼写错误
    multiIf(
        event_type = 'vew_page', 'view_page',
        event_type = 'prchase', 'purchase',
        event_type
    ) as event_type,
    event_data,
    event_time,
    processed,
    processed_at
FROM events
WHERE toYYYYMM(event_time) BETWEEN '202401' AND '202403';

-- 替换分区
ALTER TABLE events
REPLACE PARTITION '202401', '202402', '202403'
FROM events_fixed;

-- 验证修正结果
SELECT 
    event_type,
    count() as count
FROM events
WHERE toYYYYMM(event_time) BETWEEN '202401' AND '202403'
GROUP BY event_type
ORDER BY count DESC;

-- 清理
DROP TABLE events_fixed;

-- ========================================
-- 解决方案
-- ========================================

-- 方案 1: 使用 CASE WHEN 更新
ALTER TABLE users
UPDATE level = CASE
    WHEN total_spent >= 100000 THEN 'platinum'
    WHEN total_spent >= 50000 THEN 'gold'
    WHEN total_spent >= 10000 THEN 'silver'
    WHEN total_spent >= 1000 THEN 'bronze'
    ELSE 'normal'
END,
    level_updated_at = now()
WHERE total_spent >= 1000
SETTINGS lightweight_update = 1;

-- 方案 2: 使用临时表
-- 创建临时表
CREATE TABLE users_temp AS users;

-- 更新等级
INSERT INTO users_temp
SELECT 
    user_id,
    username,
    email,
    status,
    total_spent,
    CASE
        WHEN total_spent >= 100000 THEN 'platinum'
        WHEN total_spent >= 50000 THEN 'gold'
        WHEN total_spent >= 10000 THEN 'silver'
        WHEN total_spent >= 1000 THEN 'bronze'
        ELSE 'normal'
    END as level,
    level_updated_at,
    created_at,
    last_login
FROM users
WHERE total_spent >= 1000;

-- 替换分区
ALTER TABLE users
REPLACE PARTITION '202401', '202402'
FROM users_temp;

-- 清理
DROP TABLE users_temp;

-- ========================================
-- 解决方案
-- ========================================

-- 验证等级升级
SELECT 
    level,
    count() as user_count,
    min(total_spent) as min_spent,
    max(total_spent) as max_spent,
    avg(total_spent) as avg_spent
FROM users
WHERE level_updated_at >= now() - INTERVAL 1 HOUR
GROUP BY level
ORDER BY 
    CASE level
        WHEN 'platinum' THEN 1
        WHEN 'gold' THEN 2
        WHEN 'silver' THEN 3
        WHEN 'bronze' THEN 4
        ELSE 5
    END;

-- ========================================
-- 解决方案
-- ========================================

-- 创建归档表
CREATE TABLE orders_archive (
    order_id UInt64,
    user_id UInt64,
    product_id UInt64,
    amount Float64,
    order_date DateTime,
    status String,
    created_at DateTime,
    updated_at DateTime
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(order_date)
ORDER BY order_id;

-- 使用 EXCHANGE PARTITIONS 移动数据
ALTER TABLE orders_archive
EXCHANGE PARTITION '202301'
WITH orders;

ALTER TABLE orders_archive
EXCHANGE PARTITION '202302'
WITH orders;

ALTER TABLE orders_archive
EXCHANGE PARTITION '202303'
WITH orders;

-- 继续交换其他月份...

-- 验证归档
SELECT 
    toYYYYMM(order_date) as month,
    count() as order_count,
    sum(amount) as total_amount
FROM orders_archive
WHERE toYYYYMM(order_date) BETWEEN '202301' AND '202312'
GROUP BY month
ORDER BY month;

-- ========================================
-- 解决方案
-- ========================================

-- 创建临时表
CREATE TABLE events_temp AS events;

-- 更新最近 3 个月的数据
INSERT INTO events_temp
SELECT 
    event_id,
    user_id,
    event_type,
    event_data,
    1 as processed,
    now() as processed_at
FROM events
WHERE toYYYYMM(event_time) IN (
    toYYYYMM(now() - INTERVAL 1 MONTH),
    toYYYYMM(now() - INTERVAL 2 MONTH),
    toYYYYMM(now() - INTERVAL 3 MONTH)
)
  AND processed = 0;

-- 替换分区
ALTER TABLE events
REPLACE PARTITION 
    toYYYYMM(now() - INTERVAL 1 MONTH),
    toYYYYMM(now() - INTERVAL 2 MONTH),
    toYYYYMM(now() - INTERVAL 3 MONTH)
FROM events_temp;

-- 清理
DROP TABLE events_temp;

-- ========================================
-- 解决方案
-- ========================================

-- 方案 1: 使用子查询更新
ALTER TABLE users
UPDATE total_spent = (
    SELECT coalesce(sum(amount), 0)
    FROM orders
    WHERE orders.user_id = users.user_id
),
total_orders = (
    SELECT count()
    FROM orders
    WHERE orders.user_id = users.user_id
),
updated_at = now()
WHERE updated_at < now() - INTERVAL 1 DAY
SETTINGS lightweight_update = 1;

-- 方案 2: 使用临时表（更高效）
-- 创建临时表
CREATE TABLE user_stats_temp AS users;

-- 计算统计数据
INSERT INTO user_stats_temp
SELECT 
    u.user_id,
    u.username,
    u.email,
    u.status,
    coalesce(o.total_spent, 0) as total_spent,
    coalesce(o.order_count, 0) as total_orders,
    now() as updated_at,
    u.created_at,
    u.last_login
FROM users u
LEFT JOIN (
    SELECT 
        user_id,
        sum(amount) as total_spent,
        count() as order_count
    FROM orders
    WHERE order_date >= now() - INTERVAL 30 DAY
    GROUP BY user_id
) o ON u.user_id = o.user_id
WHERE u.updated_at < now() - INTERVAL 1 DAY;

-- 替换分区
ALTER TABLE users
REPLACE PARTITION '202401'
FROM user_stats_temp;

-- 清理
DROP TABLE user_stats_temp;

-- ========================================
-- 解决方案
-- ========================================

-- 方案 1: 使用轻量级更新
ALTER TABLE events
UPDATE is_deleted = 1,
    deleted_at = now()
WHERE event_time < toDateTime('2024-01-01')
  AND is_deleted = 0
SETTINGS lightweight_update = 1;

-- 方案 2: 分区更新
-- 创建临时表
CREATE TABLE events_temp AS events;

-- 标记为已删除
INSERT INTO events_temp
SELECT 
    event_id,
    user_id,
    event_type,
    event_data,
    event_time,
    1 as is_deleted,
    now() as deleted_at,
    processed,
    processed_at
FROM events
WHERE toYYYYMM(event_time) IN ('202301', '202302', '202303')
  AND is_deleted = 0;

-- 替换分区
ALTER TABLE events
REPLACE PARTITION '202301', '202302', '202303'
FROM events_temp;

-- 清理
DROP TABLE events_temp;

-- ========================================
-- 解决方案
-- ========================================

-- 批量更新前先备份
CREATE TABLE users_backup AS users;

-- 执行更新
ALTER TABLE users UPDATE ...;

-- 验证结果
-- 如果有问题，可以从备份恢复
-- DROP TABLE users;
-- RENAME TABLE users_backup TO users;

-- ========================================
-- 解决方案
-- ========================================

-- 将大批量更新拆分为小批次
-- 每批次 10 万行
ALTER TABLE users
UPDATE status = 'active'
WHERE user_id BETWEEN 1 AND 100000;

-- 等待完成后再执行下一批次
ALTER TABLE users
UPDATE status = 'active'
WHERE user_id BETWEEN 100001 AND 200000;

-- 继续分批...

-- ========================================
-- 解决方案
-- ========================================

-- 实时监控更新进度
SELECT 
    mutation_id,
    command,
    is_done,
    parts_to_do,
    progress,
    created_at
FROM system.mutations
ORDER BY created DESC;

-- ========================================
-- 解决方案
-- ========================================

-- 更新完成后验证结果
SELECT 
    status,
    count() as count,
    countIf(updated_at >= now() - INTERVAL 1 HOUR) as updated_count
FROM users
WHERE toYYYYMM(created_at) = '202401'
GROUP BY status;

-- ========================================
-- 解决方案
-- ========================================

-- 更新完成后及时清理临时表
DROP TABLE IF EXISTS users_temp;
DROP TABLE IF EXISTS orders_temp;
DROP TABLE IF EXISTS events_temp;
