CREATE TABLE IF NOT EXISTS users_temp AS users;
INSERT INTO users_temp SELECT * FROM users WHERE ...;
ALTER TABLE users REPLACE PARTITION '202401' FROM users_temp;

-- ❌ 使用 Mutation（慢速）
ALTER TABLE users DELETE WHERE toYYYYMM(created_at) = '202401';

-- ========================================
-- 策略 1: 优先使用分区操作
-- ========================================

-- ✅ 使用轻量级删除（ClickHouse 23.8+）
ALTER TABLE users
DELETE WHERE user_id IN (1, 2, 3)
SETTINGS lightweight_delete = 1;

-- ❌ 使用传统 Mutation
ALTER TABLE users DELETE WHERE user_id IN (1, 2, 3);

-- ========================================
-- 策略 1: 优先使用分区操作
-- ========================================

-- ✅ 分批处理
-- 批次 1
ALTER TABLE users
DELETE WHERE user_id BETWEEN 1 AND 10000;

-- 等待完成后执行下一批次
-- 批次 2
ALTER TABLE users
DELETE WHERE user_id BETWEEN 10001 AND 20000;

-- ❌ 单次大批量 Mutation
ALTER TABLE users DELETE WHERE user_id IN (1, 2, ..., 100000);

-- ========================================
-- 策略 1: 优先使用分区操作
-- ========================================

-- ✅ 低峰期执行
ALTER TABLE users
DELETE WHERE created_at < now() - INTERVAL 90 DAY;

-- 或使用定时任务

-- ========================================
-- 策略 1: 优先使用分区操作
-- ========================================

-- 0: 异步执行（默认）
ALTER TABLE users
DELETE WHERE user_id IN (1, 2, 3)
SETTINGS mutations_sync = 0;

-- 1: 等待当前分片完成
ALTER TABLE users
DELETE WHERE user_id IN (1, 2, 3)
SETTINGS mutations_sync = 1;

-- 2: 等待所有分片完成
ALTER TABLE users
DELETE WHERE user_id IN (1, 2, 3)
SETTINGS mutations_sync = 2;

-- ========================================
-- 策略 1: 优先使用分区操作
-- ========================================

-- 限制并发线程数
ALTER TABLE users
DELETE WHERE user_id IN (1, 2, 3)
-- REMOVED SET max_threads (not supported) 2;

-- 限制内存使用
ALTER TABLE users
DELETE WHERE user_id IN (1, 2, 3)
-- REMOVED SET max_memory_usage (not supported) 10000000000;  -- 10 GB

-- ========================================
-- 策略 1: 优先使用分区操作
-- ========================================

-- 设置 Mutation 优先级（1-10，默认 5）
ALTER TABLE users
DELETE WHERE user_id IN (1, 2, 3)
SETTINGS priority = 8;

-- ========================================
-- 策略 1: 优先使用分区操作
-- ========================================

-- 是否等待复制完成
ALTER TABLE users
DELETE WHERE user_id IN (1, 2, 3)
SETTINGS replication_alter_partitions_sync = 2;  -- 0: 不同步, 1: 当前表, 2: 所有副本

-- ========================================
-- 策略 1: 优先使用分区操作
-- ========================================

-- 查看 Mutation 状态
SELECT 
    database,
    table,
    mutation_id,
    command,
    is_done,
    parts_to_do,
    parts_to_do_names,
    progress,
    exception_text,
    created_at,
    done_at
FROM system.mutations
WHERE database = 'my_database'
ORDER BY created DESC;

-- ========================================
-- 策略 1: 优先使用分区操作
-- ========================================

-- 实时监控 Mutation 进度
SELECT 
    database,
    table,
    mutation_id,
    command,
    is_done,
    parts_to_do,
    progress,
    elapsed
FROM system.mutations
LEFT JOIN (
    SELECT mutation_id,
        dateDiff('second', created_at, now()) as elapsed
    FROM system.mutations
    WHERE is_done = 0
) USING (mutation_id)
WHERE database = 'my_database'
  AND is_done = 0
ORDER BY created DESC;

-- ========================================
-- 策略 1: 优先使用分区操作
-- ========================================

-- 查看最近完成的 Mutation
SELECT 
    database,
    table,
    mutation_id,
    command,
    parts_to_do,
    created_at,
    done_at,
    dateDiff('second', created_at, done_at) as duration_seconds
FROM system.mutations
WHERE is_done = 1
  AND database = 'my_database'
ORDER BY done_at DESC
LIMIT 10;

-- ========================================
-- 策略 1: 优先使用分区操作
-- ========================================

-- ✅ 分批删除（每批 1 万行）
-- 批次 1
ALTER TABLE users
DELETE WHERE user_id BETWEEN 1 AND 10000
-- REMOVED SET max_threads (not supported) 2;

-- 等待完成后执行下一批次
-- 批次 2
ALTER TABLE users
DELETE WHERE user_id BETWEEN 10001 AND 20000
-- REMOVED SET max_threads (not supported) 2;

-- ❌ 单次大批量删除
ALTER TABLE users DELETE WHERE user_id IN (1, 2, ..., 20000);

-- ========================================
-- 策略 1: 优先使用分区操作
-- ========================================

-- ✅ 使用分区删除
-- 删除 2023 年的所有分区
ALTER TABLE users
DROP PARTITION '202301', '202302', '202303', '202304',
                '202305', '202306', '202307', '202308',
                '202309', '202310', '202311', '202312';

-- ❌ 使用 Mutation
ALTER TABLE users
DELETE WHERE toYYYYMM(created_at) IN ('202301', '202302', '202303', ..., '202312');

-- ========================================
-- 策略 1: 优先使用分区操作
-- ========================================

-- ✅ 使用轻量级删除（ClickHouse 23.8+）
ALTER TABLE users
DELETE WHERE user_id IN (1, 2, 3, ..., 1000)
SETTINGS lightweight_delete = 1;

-- ❌ 使用传统 Mutation
ALTER TABLE users DELETE WHERE user_id IN (1, 2, 3, ..., 1000);

-- ========================================
-- 策略 1: 优先使用分区操作
-- ========================================

-- ✅ 组合策略：新数据用轻量级删除，旧数据用分区删除
-- 新数据（最近 30 天）
ALTER TABLE users
DELETE WHERE created_at >= now() - INTERVAL 30 DAY
  AND user_id IN (1, 2, 3, ..., 1000)
SETTINGS lightweight_delete = 1;

-- 旧数据（30 天前）
CREATE TABLE IF NOT EXISTS users_temp AS users;
INSERT INTO users_temp
SELECT * FROM users
WHERE created_at < now() - INTERVAL 30 DAY
  AND status = 'inactive';

ALTER TABLE users
REPLACE PARTITION '202312'
FROM users_temp;

DROP TABLE users_temp;
