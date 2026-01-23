-- ================================================
-- 02_lightweight_update_examples.sql
-- 从 02_lightweight_update.md 提取的 SQL 示例
-- 提取时间: 2026-01-23 14:40:17
-- ================================================


-- ========================================
-- 启用轻量级更新
-- ========================================

ALTER TABLE table_name
UPDATE column = value
WHERE condition
SETTINGS lightweight_update = 1;

-- ========================================
-- 启用轻量级更新
-- ========================================

-- 设置全局配置（需要重启）
-- 在 config.xml 中添加：
<lightweight_update>1</lightweight_update>

-- ========================================
-- 启用轻量级更新
-- ========================================

-- 创建表时指定
CREATE TABLE users (
    user_id UInt64,
    username String,
    status String
) ENGINE = MergeTree()
ORDER BY user_id
SETTINGS allow_lightweight_update = 1;

-- ========================================
-- 启用轻量级更新
-- ========================================

-- 准备测试表
CREATE TABLE test_lightweight.users (
    user_id UInt64,
    username String,
    email String,
    status String DEFAULT 'pending',
    created_at DateTime,
    last_login DateTime
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(created_at)
ORDER BY user_id
SETTINGS allow_lightweight_update = 1;

-- 插入测试数据
INSERT INTO test_lightweight.users (user_id, username, email, status, created_at, last_login) VALUES
(1, 'user1', 'user1@example.com', 'pending', '2024-01-15 08:00:00', '2024-01-15 08:00:00'),
(2, 'user2', 'user2@example.com', 'pending', '2024-01-15 09:00:00', '2024-01-15 09:00:00'),
(3, 'user3', 'user3@example.com', 'active', '2024-01-16 10:00:00', '2024-01-16 10:00:00'),
(4, 'user4', 'user4@example.com', 'pending', '2024-02-01 11:00:00', '2024-02-01 11:00:00'),
(5, 'user5', 'user5@example.com', 'pending', '2024-02-15 12:00:00', '2024-02-15 12:00:00');

-- 使用轻量级更新
ALTER TABLE test_lightweight.users
UPDATE status = 'active'
WHERE user_id IN (1, 2, 4, 5)
SETTINGS lightweight_update = 1;

-- 验证更新结果
SELECT user_id, username, status FROM test_lightweight.users;

-- ========================================
-- 启用轻量级更新
-- ========================================

-- 批量更新用户状态
ALTER TABLE test_lightweight.users
UPDATE status = 'inactive'
WHERE last_login < now() - INTERVAL 90 DAY
SETTINGS lightweight_update = 1;

-- 批量更新用户等级
ALTER TABLE test_lightweight.users
UPDATE level = CASE
    WHEN total_spent >= 10000 THEN 'gold'
    WHEN total_spent >= 5000 THEN 'silver'
    WHEN total_spent >= 1000 THEN 'bronze'
    ELSE 'normal'
END
WHERE created_at >= '2024-01-01'
SETTINGS lightweight_update = 1;

-- ========================================
-- 启用轻量级更新
-- ========================================

-- 使用字符串函数
ALTER TABLE test_lightweight.users
UPDATE email = lower(trim(email))
WHERE email != lower(email)
SETTINGS lightweight_update = 1;

-- 使用日期函数
ALTER TABLE test_lightweight.users
UPDATE last_login = toDateTime(toStartOfDay(last_login))
WHERE last_login >= now() - INTERVAL 30 DAY
SETTINGS lightweight_update = 1;

-- 使用数学函数
ALTER TABLE test_lightweight.orders
UPDATE amount = round(amount * 1.1, 2)
WHERE order_date >= '2024-01-01'
  AND status = 'pending'
SETTINGS lightweight_update = 1;

-- ========================================
-- 启用轻量级更新
-- ========================================

-- 同时更新多个字段
ALTER TABLE test_lightweight.users
UPDATE 
    status = 'active',
    last_login = now(),
    login_count = login_count + 1
WHERE user_id = 123
SETTINGS lightweight_update = 1;

-- ========================================
-- 启用轻量级更新
-- ========================================

-- 使用复杂条件
ALTER TABLE test_lightweight.users
UPDATE premium_status = CASE
    WHEN total_spent > 10000 AND registration_date > '2023-01-01' THEN 'premium'
    WHEN total_spent > 5000 THEN 'standard'
    ELSE 'basic'
END
WHERE status = 'active'
  AND total_spent > 0
SETTINGS lightweight_update = 1;

-- ========================================
-- 启用轻量级更新
-- ========================================

-- 创建测试表
CREATE TABLE test_lightweight.compare_table (
    id UInt64,
    value String,
    status String,
    created_at DateTime
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(created_at)
ORDER BY id
SETTINGS allow_lightweight_update = 1;

-- 插入 100 万条测试数据
INSERT INTO test_lightweight.compare_table
SELECT 
    number as id,
    toString(number) as value,
    'pending' as status,
    now() - INTERVAL (rand() % 365) DAY as created_at
FROM numbers(1000000);

-- 测试 1: 传统 Mutation
-- 记录开始时间
SELECT now() as start_time;

ALTER TABLE test_lightweight.compare_table
UPDATE status = 'active'
WHERE id % 10 = 0;

-- 记录结束时间
SELECT now() as end_time;

-- 测试 2: 轻量级更新
-- 记录开始时间
SELECT now() as start_time;

ALTER TABLE test_lightweight.compare_table
UPDATE status = 'processed'
WHERE id % 10 = 1
SETTINGS lightweight_update = 1;

-- 记录结束时间
SELECT now() as end_time;

-- ========================================
-- 启用轻量级更新
-- ========================================

-- 查看 Mutation 列表（包含轻量级更新）
SELECT 
    database,
    table,
    mutation_id,
    command,
    is_done,
    parts_to_do,
    parts_to_do_names,
    progress,
    exception_text
FROM system.mutations
WHERE database = 'test_lightweight'
ORDER BY created DESC;

-- 查看轻量级更新统计
SELECT 
    database,
    table,
    sum(rows) as total_rows,
    formatReadableSize(sum(bytes_on_disk)) as total_size,
    count() as mutation_count
FROM system.mutations
WHERE database = 'test_lightweight'
GROUP BY database, table;

-- ========================================
-- 启用轻量级更新
-- ========================================

-- 查看特定 Mutation 的状态
SELECT 
    mutation_id,
    command,
    is_done,
    parts_to_do,
    parts_to_do_names,
    progress,
    created_at,
    done_at,
    exception_text
FROM system.mutations
WHERE mutation_id = 'mutation_123.txt';

-- ========================================
-- 启用轻量级更新
-- ========================================

-- 强制合并以应用轻量级更新
OPTIMIZE TABLE test_lightweight.users
FINAL
SETTINGS mutations_sync = 1;

-- ========================================
-- 启用轻量级更新
-- ========================================

-- 创建表时指定设置
CREATE TABLE users (
    user_id UInt64,
    username String,
    status String
) ENGINE = MergeTree()
ORDER BY user_id
SETTINGS 
    allow_lightweight_update = 1,
    lightweight_update_min_rows_to_delay = 100000,
    lightweight_update_max_delay_in_seconds = 3600;

-- ========================================
-- 启用轻量级更新
-- ========================================

-- 启用轻量级更新
ALTER TABLE users
UPDATE status = 'active'
WHERE user_id = 123
SETTINGS lightweight_update = 1;

-- 禁用轻量级更新（使用传统 Mutation）
ALTER TABLE users
UPDATE status = 'active'
WHERE user_id = 123
SETTINGS lightweight_update = 0;

-- ========================================
-- 启用轻量级更新
-- ========================================

-- 更新用户的订单数量
ALTER TABLE test_lightweight.users
UPDATE orders_count = (
    SELECT count()
    FROM test_lightweight.orders
    WHERE orders.user_id = users.user_id
)
SETTINGS lightweight_update = 1;

-- ========================================
-- 启用轻量级更新
-- ========================================

-- 关联更新
ALTER TABLE test_lightweight.users
UPDATE last_order_amount = (
    SELECT max(amount)
    FROM test_lightweight.orders
    WHERE orders.user_id = users.user_id
),
last_order_date = (
    SELECT max(order_date)
    FROM test_lightweight.orders
    WHERE orders.user_id = users.user_id
)
WHERE user_id IN (
    SELECT DISTINCT user_id
    FROM test_lightweight.orders
)
SETTINGS lightweight_update = 1;

-- ========================================
-- 启用轻量级更新
-- ========================================

-- 使用复杂表达式更新
ALTER TABLE test_lightweight.users
UPDATE score = (
    0.3 * login_score +
    0.4 * purchase_score +
    0.3 * engagement_score
),
rank = CASE
    WHEN score >= 90 THEN 'S'
    WHEN score >= 80 THEN 'A'
    WHEN score >= 70 THEN 'B'
    WHEN score >= 60 THEN 'C'
    ELSE 'D'
END
WHERE updated_at >= now() - INTERVAL 7 DAY
SETTINGS lightweight_update = 1;

-- ========================================
-- 启用轻量级更新
-- ========================================

-- 分批执行轻量级更新
-- 批次 1: 更新 ID 1-1000
ALTER TABLE test_lightweight.users
UPDATE status = 'active'
WHERE user_id BETWEEN 1 AND 1000
SETTINGS lightweight_update = 1;

-- 批次 2: 更新 ID 1001-2000
ALTER TABLE test_lightweight.users
UPDATE status = 'active'
WHERE user_id BETWEEN 1001 AND 2000
SETTINGS lightweight_update = 1;

-- 继续分批...

-- ========================================
-- 启用轻量级更新
-- ========================================

-- 使用合适的分区键
CREATE TABLE users (
    user_id UInt64,
    created_at DateTime,
    -- 其他字段
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(created_at)  -- 按月分区
ORDER BY user_id
SETTINGS allow_lightweight_update = 1;

-- ========================================
-- 启用轻量级更新
-- ========================================

-- 只更新特定分区
ALTER TABLE users
UPDATE status = 'active'
WHERE user_id IN (1, 2, 3)
  AND created_at >= '2024-01-01'
  AND created_at < '2024-02-01'
SETTINGS lightweight_update = 1;

-- ========================================
-- 启用轻量级更新
-- ========================================

-- 使用主键
ALTER TABLE users
UPDATE status = 'active'
WHERE user_id IN (1, 2, 3)  -- 快速
SETTINGS lightweight_update = 1;

-- 避免低选择性条件
ALTER TABLE users
UPDATE status = 'active'
WHERE status = 'pending'  -- 慢速
SETTINGS lightweight_update = 1;

-- ========================================
-- 启用轻量级更新
-- ========================================

-- 限制并发线程数
ALTER TABLE users
UPDATE status = 'active'
WHERE user_id IN (1, 2, 3)
SETTINGS 
    lightweight_update = 1,
    max_threads = 2;

-- ========================================
-- 启用轻量级更新
-- ========================================

-- 强制合并
OPTIMIZE TABLE users
FINAL
SETTINGS mutations_sync = 1;

-- 或等待后台合并完成

-- ========================================
-- 启用轻量级更新
-- ========================================

-- 1. 检查配置
SELECT 
    name,
    value,
    changed
FROM system.settings
WHERE name LIKE '%lightweight%';

-- 2. 使用更具体的 WHERE 条件
ALTER TABLE users
UPDATE status = 'active'
WHERE user_id IN (1, 2, 3)
  AND created_at >= '2024-01-01'
SETTINGS lightweight_update = 1;

-- 3. 分批处理
-- 将大更新拆分为多个小批次
