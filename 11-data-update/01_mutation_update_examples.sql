-- ================================================
-- 01_mutation_update_examples.sql
-- 从 01_mutation_update.md 提取的 SQL 示例
-- 提取时间: 2026-01-23 14:40:17
-- ================================================


-- ========================================
-- 更新单个字段
-- ========================================

ALTER TABLE table_name
UPDATE column = value
WHERE condition;

-- ========================================
-- 更新单个字段
-- ========================================

ALTER TABLE table_name
UPDATE 
    column1 = value1,
    column2 = value2,
    column3 = value3
WHERE condition;

-- ========================================
-- 更新单个字段
-- ========================================

ALTER TABLE users
UPDATE 
    age = age + 1,
    last_updated = now()
WHERE status = 'active';

-- ========================================
-- 更新单个字段
-- ========================================

-- 准备测试表
CREATE TABLE test_mutations.users (
    user_id UInt64,
    username String,
    email String,
    status String DEFAULT 'pending',
    created_at DateTime,
    last_login DateTime
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(created_at)
ORDER BY user_id;

-- 插入测试数据
INSERT INTO test_mutations.users (user_id, username, email, status, created_at, last_login) VALUES
(1, 'user1', 'user1@example.com', 'pending', '2024-01-15 08:00:00', '2024-01-15 08:00:00'),
(2, 'user2', 'user2@example.com', 'pending', '2024-01-15 09:00:00', '2024-01-15 09:00:00'),
(3, 'user3', 'user3@example.com', 'active', '2024-01-16 10:00:00', '2024-01-16 10:00:00'),
(4, 'user4', 'user4@example.com', 'pending', '2024-02-01 11:00:00', '2024-02-01 11:00:00'),
(5, 'user5', 'user5@example.com', 'pending', '2024-02-15 12:00:00', '2024-02-15 12:00:00');

-- 更新用户状态
ALTER TABLE test_mutations.users
UPDATE status = 'active'
WHERE user_id IN (1, 2, 4, 5);

-- 验证更新结果
SELECT user_id, username, status FROM test_mutations.users;

-- ========================================
-- 更新单个字段
-- ========================================

-- 更新订单金额（10% 涨价）
ALTER TABLE test_mutations.orders
UPDATE amount = amount * 1.1
WHERE order_date >= '2024-01-01'
  AND status = 'pending';

-- ========================================
-- 更新单个字段
-- ========================================

-- 更新用户等级
ALTER TABLE test_mutations.users
UPDATE level = CASE
    WHEN total_spent >= 10000 THEN 'gold'
    WHEN total_spent >= 5000 THEN 'silver'
    WHEN total_spent >= 1000 THEN 'bronze'
    ELSE 'normal'
END
WHERE created_at >= toDateTime('2024-01-01');

-- ========================================
-- 更新单个字段
-- ========================================

-- 更新用户的最后登录时间
ALTER TABLE test_mutations.users
UPDATE last_login = (
    SELECT max(event_time)
    FROM test_mutations.user_events
    WHERE user_events.user_id = users.user_id
)
WHERE user_id IN (
    SELECT DISTINCT user_id
    FROM test_mutations.user_events
    WHERE event_time >= now() - INTERVAL 7 DAY
);

-- ========================================
-- 更新单个字段
-- ========================================

-- 分批更新以减少性能影响
ALTER TABLE test_mutations.large_table
UPDATE status = 'processed'
WHERE event_time >= '2024-01-01'
  AND event_time < '2024-02-01'
SETTINGS max_threads = 4,
        mutations_sync = 0;  -- 0: 异步, 1: 等待当前分片, 2: 等待所有分片

-- ========================================
-- 更新单个字段
-- ========================================

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
WHERE database = 'test_mutations'
ORDER BY created DESC;

-- ========================================
-- 更新单个字段
-- ========================================

-- 查看特定 Mutation 的详细信息
SELECT 
    mutation_id,
    command,
    is_done,
    parts_to_do,
    parts_to_do_names,
    progress,
    latest_failed_part,
    latest_fail_reason,
    latest_fail_time
FROM system.mutations
WHERE mutation_id = 'mutation_123.txt';

-- ========================================
-- 更新单个字段
-- ========================================

-- 实时监控所有正在进行的 Mutation
SELECT 
    database,
    table,
    mutation_id,
    command,
    is_done,
    parts_to_do,
    sum(rows) as total_rows,
    formatReadableSize(sum(bytes_on_disk)) as total_size,
    progress
FROM system.mutations
LEFT JOIN system.parts
USING (database, table)
WHERE is_done = 0
GROUP BY database, table, mutation_id, command, is_done, parts_to_do, progress
ORDER BY progress;

-- ========================================
-- 更新单个字段
-- ========================================

-- 查看最近完成的 Mutation
SELECT 
    database,
    table,
    mutation_id,
    command,
    is_done,
    parts_to_do,
    parts_to_do_names,
    created_at,
    done_at,
    exception_text
FROM system.mutations
WHERE is_done = 1
ORDER BY done_at DESC
LIMIT 10;

-- ========================================
-- 更新单个字段
-- ========================================

-- 异步执行（默认）
ALTER TABLE users
UPDATE status = 'active'
WHERE user_id = 123
SETTINGS mutations_sync = 0;

-- 等待当前分片完成
ALTER TABLE users
UPDATE status = 'active'
WHERE user_id = 123
SETTINGS mutations_sync = 1;

-- 等待所有分片完成
ALTER TABLE users
UPDATE status = 'active'
WHERE user_id = 123
SETTINGS mutations_sync = 2;

-- ========================================
-- 更新单个字段
-- ========================================

-- 限制并发线程数
ALTER TABLE users
UPDATE status = 'active'
WHERE user_id IN (1, 2, 3)
SETTINGS max_threads = 2;

-- 限制内存使用
ALTER TABLE users
UPDATE status = 'active'
WHERE user_id IN (1, 2, 3)
SETTINGS max_memory_usage = 10000000000;  -- 10GB

-- ========================================
-- 更新单个字段
-- ========================================

-- 设置 Mutation 优先级（1-10，默认 5）
ALTER TABLE users
UPDATE status = 'active'
WHERE user_id = 123
SETTINGS priority = 8;

-- ========================================
-- 更新单个字段
-- ========================================

-- 使用字符串函数
ALTER TABLE users
UPDATE email = lower(email)
WHERE status = 'active';

-- 使用日期函数
ALTER TABLE users
UPDATE last_login = toDateTime(toStartOfDay(last_login))
WHERE last_login >= now() - INTERVAL 30 DAY;

-- 使用数学函数
ALTER TABLE orders
UPDATE amount = round(amount * 1.1, 2)
WHERE order_date >= '2024-01-01';

-- ========================================
-- 更新单个字段
-- ========================================

-- 使用 CASE WHEN
ALTER TABLE users
UPDATE status = CASE
    WHEN last_login < now() - INTERVAL 90 DAY THEN 'inactive'
    WHEN last_login < now() - INTERVAL 30 DAY THEN 'away'
    ELSE 'active'
END
WHERE created_at >= '2024-01-01';

-- 使用多条件
ALTER TABLE users
UPDATE level = 'premium'
WHERE total_spent > 10000
  AND registration_date > '2023-01-01'
  AND status = 'active';

-- ========================================
-- 更新单个字段
-- ========================================

-- 使用 JOIN 更新
ALTER TABLE users
UPDATE orders_count = (
    SELECT count()
    FROM orders
    WHERE orders.user_id = users.user_id
),
total_spent = (
    SELECT sum(amount)
    FROM orders
    WHERE orders.user_id = users.user_id
)
WHERE user_id IN (
    SELECT DISTINCT user_id FROM orders
);

-- ========================================
-- 更新单个字段
-- ========================================

-- 使用合理的分区键
CREATE TABLE users (
    user_id UInt64,
    created_at DateTime,
    -- 其他字段
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(created_at)  -- 按月分区
ORDER BY user_id;

-- ========================================
-- 更新单个字段
-- ========================================

-- 只更新特定分区
ALTER TABLE users
UPDATE status = 'active'
WHERE user_id IN (1, 2, 3)
  AND created_at >= '2024-01-01'
  AND created_at < '2024-02-01';

-- ========================================
-- 更新单个字段
-- ========================================

-- 使用主键
ALTER TABLE users
UPDATE status = 'active'
WHERE user_id = 123;  -- 快速

-- 避免低选择性条件
ALTER TABLE users
UPDATE status = 'active'
WHERE email LIKE '%@example.com';  -- 慢速

-- ========================================
-- 更新单个字段
-- ========================================

-- 将大更新拆分为小批次
-- 批次 1
ALTER TABLE users
UPDATE status = 'active'
WHERE user_id BETWEEN 1 AND 1000;

-- 批次 2
ALTER TABLE users
UPDATE status = 'active'
WHERE user_id BETWEEN 1001 AND 2000;

-- 继续分批...

-- ========================================
-- 更新单个字段
-- ========================================

-- 检查 Mutation 状态
SELECT * FROM system.mutations
WHERE is_done = 0;

-- 检查是否有锁
SELECT * FROM system.replication_queue
WHERE type = 'Mutation';

-- 检查错误信息
SELECT exception_text FROM system.mutations
WHERE is_done = 0;

-- ========================================
-- 更新单个字段
-- ========================================

-- 查看失败原因
SELECT 
    mutation_id,
    command,
    latest_failed_part,
    latest_fail_reason,
    latest_fail_time
FROM system.mutations
WHERE is_done = 1
  AND exception_text != '';

-- 修复后重新执行 Mutation
ALTER TABLE users
UPDATE status = 'active'
WHERE user_id IN (1, 2, 3);

-- ========================================
-- 更新单个字段
-- ========================================

-- 1. 检查分区大小
SELECT 
    partition,
    sum(rows) as rows,
    formatReadableSize(sum(bytes_on_disk)) as size
FROM system.parts
WHERE table = 'users'
  AND active = 1
GROUP BY partition
ORDER BY size DESC;

-- 2. 使用更具体的 WHERE 条件
ALTER TABLE users
UPDATE status = 'active'
WHERE user_id IN (1, 2, 3)
  AND created_at >= '2024-01-01';

-- 3. 分批处理
ALTER TABLE users
UPDATE status = 'active'
WHERE user_id IN (1, 2, 3)
SETTINGS max_threads = 2;
