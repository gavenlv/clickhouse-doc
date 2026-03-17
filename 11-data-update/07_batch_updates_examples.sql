-- ================================================================================
-- ClickHouse 批量更新最佳实践
-- ================================================================================
-- 
-- 集群: treasurycluster (2 副本)
-- 预计学习时间: 20 分钟
-- 
-- 本文件涵盖:
--   1. 批量更新策略 - 分批更新减少压力
--   2. 更新时机选择 - 低峰期执行
--   3. 更新条件优化 - 利用索引和分区
--   4. 更新监控 - 追踪更新进度
--   5. 更新验证 - 验证更新结果
--   6. 更新清理 - 清理临时资源
-- 
-- ================================================================================
-- 批量更新原理
-- ================================================================================
-- 
--   ┌─────────────────────────────────────────────────────────────────────────┐
--   │                      批量更新设计模式                                   │
--   └─────────────────────────────────────────────────────────────────────────┘
--   
--   ┌─────────────────────────────────────────────────────────────────────────┐
--   │                    为什么需要批量更新?                                  │
--   └─────────────────────────────────────────────────────────────────────────┘
--   
--   问题:
--   ┌────────────────────────────────────────────────────────────────────────┐
--   │  大规模单次更新:                                                       │
--   │  UPDATE users SET status = 'active' WHERE last_login < now() - 90d     │
--   │                                                                         │
--   │  - 影响 1000万行数据                                                   │
--   │  - 重写数百个 Part                                                     │
--   │  - 消耗大量 CPU、内存、磁盘 I/O                                        │
--   │  - 阻塞其他查询                                                        │
--   │  - 执行时间长达数分钟                                                   │
--   └────────────────────────────────────────────────────────────────────────┘
--   
--   解决方案:
--   ┌────────────────────────────────────────────────────────────────────────┐
--   │  分批更新:                                                             │
--   │  批次 1: UPDATE ... WHERE user_id BETWEEN 1 AND 100000                 │
--   │  批次 2: UPDATE ... WHERE user_id BETWEEN 100001 AND 200000            │
--   │  批次 3: UPDATE ... WHERE user_id BETWEEN 200001 AND 300000            │
--   │  ...                                                                   │
--   │                                                                         │
--   │  优势:                                                                 │
--   │  - 每批影响小, 系统压力均匀                                            │
--   │  - 可在批间暂停, 让其他查询执行                                        │
--   │  - 失败后只需重试失败的批次                                            │
--   │  - 可并行执行多个批次 (不同分区)                                       │
--   └────────────────────────────────────────────────────────────────────────┘
-- 
-- ================================================================================
-- 批量更新策略
-- ================================================================================
-- 
--   ┌─────────────────────────────────────────────────────────────────────────┐
--   │                      批量更新策略选择                                   │
--   └─────────────────────────────────────────────────────────────────────────┘
--   
--   策略 1: 按主键范围分批
--   ┌────────────────────────────────────────────────────────────────────────┐
--   │  适用: 有递增主键 (如 user_id, order_id)                               │
--   │                                                                         │
--   │  UPDATE users SET status = 'active'                                    │
--   │  WHERE user_id BETWEEN 1 AND 100000                                    │
--   │    AND last_login < now() - INTERVAL 90 DAY;                           │
--   │                                                                         │
--   │  UPDATE users SET status = 'active'                                    │
--   │  WHERE user_id BETWEEN 100001 AND 200000                               │
--   │    AND last_login < now() - INTERVAL 90 DAY;                           │
--   └────────────────────────────────────────────────────────────────────────┘
--   
--   策略 2: 按时间分区分批
--   ┌────────────────────────────────────────────────────────────────────────┐
--   │  适用: 按时间分区表                                                    │
--   │                                                                         │
--   │  UPDATE events SET processed = 1                                       │
--   │  WHERE toYYYYMM(event_time) = '202401' AND processed = 0;              │
--   │                                                                         │
--   │  UPDATE events SET processed = 1                                       │
--   │  WHERE toYYYYMM(event_time) = '202402' AND processed = 0;              │
--   └────────────────────────────────────────────────────────────────────────┘
--   
--   策略 3: 按状态分批
--   ┌────────────────────────────────────────────────────────────────────────┐
--   │  适用: 状态更新场景                                                    │
--   │                                                                         │
--   │  UPDATE orders SET status = 'shipped'                                  │
--   │  WHERE status = 'paid' AND payment_date < today();                     │
--   │                                                                         │
--   │  等待完成后, 再更新下一个状态                                           │
--   │  UPDATE orders SET status = 'completed'                                │
--   │  WHERE status = 'shipped' AND ship_date < today();                     │
--   └────────────────────────────────────────────────────────────────────────┘
-- 
-- ================================================================================
-- 批量更新最佳实践
-- ================================================================================
-- 
--   ┌─────────────────────────────────────────────────────────────────────────┐
--   │                      批量更新最佳实践清单                               │
--   └─────────────────────────────────────────────────────────────────────────┘
--   
--   ✅ 执行前:
--   ┌────────────────────────────────────────────────────────────────────────┐
--   │  1. 评估更新范围: SELECT count() WHERE ...                             │
--   │  2. 备份数据: CREATE TABLE backup AS SELECT ...                        │
--   │  3. 选择低峰期: 夜间或凌晨                                              │
--   │  4. 测试更新: 先在测试表验证                                            │
--   │  5. 准备监控: 打开 system.mutations 监控                                │
--   └────────────────────────────────────────────────────────────────────────┘
--   
--   ✅ 执行中:
--   ┌────────────────────────────────────────────────────────────────────────┐
--   │  1. 分批执行, 每批不超过 10万行                                        │
--   │  2. 批间暂停 10-30秒, 让其他查询执行                                   │
--   │  3. 监控 Mutation 进度                                                 │
--   │  4. 监控系统资源 (CPU、内存、磁盘)                                      │
--   │  5. 出现错误立即停止, 调查原因                                          │
--   └────────────────────────────────────────────────────────────────────────┘
--   
--   ✅ 执行后:
--   ┌────────────────────────────────────────────────────────────────────────┐
--   │  1. 验证更新结果: SELECT ... GROUP BY ...                              │
--   │  2. 检查数据一致性                                                     │
--   │  3. 清理临时表和备份                                                   │
--   │  4. 记录更新日志                                                       │
--   │  5. 观察后续查询性能                                                   │
--   └────────────────────────────────────────────────────────────────────────┘
-- 
-- ================================================================================

ALTER TABLE users
UPDATE status = 'active',
    status_updated_at = now()
WHERE user_id IN (
    SELECT DISTINCT user_id
    FROM user_logins
    WHERE login_time >= now() - INTERVAL 30 DAY
)
-- REMOVED SET lightweight_update (not supported) 1;

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
CREATE TABLE IF NOT EXISTS users_temp AS users;

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
-- REMOVED SET max_threads (not supported) 4;

-- 等待完成后执行下一批次
-- 批次 2: 2024年2月
ALTER TABLE orders
UPDATE amount = amount * 1.1,
    adjusted_at = now()
WHERE status = 'pending'
  AND toYYYYMM(order_date) = '202402'
-- REMOVED SET max_threads (not supported) 4;

-- 继续分批...

-- 方案 3: 分区更新（最快速）
-- 创建临时表
CREATE TABLE IF NOT EXISTS orders_temp AS orders;

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
CREATE TABLE IF NOT EXISTS events_fixed AS events;

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
-- REMOVED SET lightweight_update (not supported) 1;

-- 方案 2: 使用临时表
-- 创建临时表
CREATE TABLE IF NOT EXISTS users_temp AS users;

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
CREATE TABLE IF NOT EXISTS orders_archive (
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
CREATE TABLE IF NOT EXISTS events_temp AS events;

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
-- REMOVED SET lightweight_update (not supported) 1;

-- 方案 2: 使用临时表（更高效）
-- 创建临时表
CREATE TABLE IF NOT EXISTS user_stats_temp AS users;

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
-- REMOVED SET lightweight_update (not supported) 1;

-- 方案 2: 分区更新
-- 创建临时表
CREATE TABLE IF NOT EXISTS events_temp AS events;

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
CREATE TABLE IF NOT EXISTS users_backup AS users;

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
