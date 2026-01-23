-- ================================================
-- 03_partition_update_examples.sql
-- 从 03_partition_update.md 提取的 SQL 示例
-- 提取时间: 2026-01-23 14:40:17
-- ================================================


-- ========================================
-- REPLACE PARTITION
-- ========================================

-- 从另一个表替换分区
ALTER TABLE table_name
REPLACE PARTITION partition_expr
FROM source_table;

-- 替换多个分区
ALTER TABLE table_name
REPLACE PARTITION partition_expr1, partition_expr2, ...
FROM source_table;

-- ========================================
-- REPLACE PARTITION
-- ========================================

-- 交换分区
ALTER TABLE table1
EXCHANGE PARTITIONS partition_expr
WITH table2;

-- 交换特定分区
ALTER TABLE table1
EXCHANGE PARTITION '202401'
WITH table2;

-- ========================================
-- REPLACE PARTITION
-- ========================================

-- 删除分区
ALTER TABLE table_name
DROP PARTITION partition_expr;

-- 重新插入数据
INSERT INTO table_name
SELECT * FROM source_table
WHERE partition_condition;

-- ========================================
-- REPLACE PARTITION
-- ========================================

-- 准备测试表
CREATE TABLE test_partition.users (
    user_id UInt64,
    username String,
    email String,
    status String,
    created_at DateTime,
    updated_at DateTime
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(created_at)
ORDER BY user_id;

-- 插入原始数据
INSERT INTO test_partition.users VALUES
(1, 'user1', 'user1@example.com', 'pending', '2024-01-15 08:00:00', '2024-01-15 08:00:00'),
(2, 'user2', 'user2@example.com', 'pending', '2024-01-15 09:00:00', '2024-01-15 09:00:00'),
(3, 'user3', 'user3@example.com', 'active', '2024-02-01 10:00:00', '2024-02-01 10:00:00'),
(4, 'user4', 'user4@example.com', 'pending', '2024-02-15 11:00:00', '2024-02-15 11:00:00'),
(5, 'user5', 'user5@example.com', 'pending', '2024-02-20 12:00:00', '2024-02-20 12:00:00');

-- 创建临时表
CREATE TABLE test_partition.users_temp AS test_partition.users;

-- 更新数据（将 status 改为 active）
INSERT INTO test_partition.users_temp
SELECT 
    user_id,
    username,
    email,
    'active' as status,
    created_at,
    now() as updated_at
FROM test_partition.users
WHERE toYYYYMM(created_at) = '202401';

-- 替换分区
ALTER TABLE test_partition.users
REPLACE PARTITION '202401'
FROM test_partition.users_temp;

-- 验证结果
SELECT user_id, username, status, updated_at 
FROM test_partition.users
WHERE toYYYYMM(created_at) = '202401';

-- 清理临时表
DROP TABLE test_partition.users_temp;

-- ========================================
-- REPLACE PARTITION
-- ========================================

-- 创建两个表
CREATE TABLE test_partition.table1 (
    id UInt64,
    value String,
    created_at DateTime
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(created_at)
ORDER BY id;

CREATE TABLE test_partition.table2 (
    id UInt64,
    value String,
    created_at DateTime
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(created_at)
ORDER BY id;

-- 向 table1 插入数据
INSERT INTO test_partition.table1 VALUES
(1, 'value1', '2024-01-15 08:00:00'),
(2, 'value2', '2024-01-16 09:00:00'),
(3, 'value3', '2024-02-01 10:00:00');

-- 向 table2 插入数据
INSERT INTO test_partition.table2 VALUES
(11, 'value11', '2024-01-15 08:00:00'),
(12, 'value12', '2024-01-16 09:00:00'),
(13, 'value13', '2024-02-01 10:00:00');

-- 交换分区（交换 2024-01 分区）
ALTER TABLE test_partition.table1
EXCHANGE PARTITION '202401'
WITH test_partition.table2;

-- 验证交换结果
SELECT * FROM test_partition.table1 WHERE toYYYYMM(created_at) = '202401';
SELECT * FROM test_partition.table2 WHERE toYYYYMM(created_at) = '202401';

-- ========================================
-- REPLACE PARTITION
-- ========================================

-- 备份分区数据
CREATE TABLE test_partition.users_backup AS test_partition.users;

-- 删除旧分区
ALTER TABLE test_partition.users
DROP PARTITION '202401';

-- 插入更新后的数据
INSERT INTO test_partition.users
SELECT 
    user_id,
    username,
    email,
    'active' as status,
    created_at,
    now() as updated_at
FROM test_partition.users_backup
WHERE toYYYYMM(created_at) = '202401';

-- 验证结果
SELECT user_id, username, status, updated_at 
FROM test_partition.users
WHERE toYYYYMM(created_at) = '202401';

-- 清理备份
DROP TABLE test_partition.users_backup;

-- ========================================
-- REPLACE PARTITION
-- ========================================

-- 创建临时表
CREATE TABLE test_partition.users_temp AS test_partition.users;

-- 更新多个分区的数据
INSERT INTO test_partition.users_temp
SELECT 
    user_id,
    username,
    email,
    'inactive' as status,
    created_at,
    now() as updated_at
FROM test_partition.users
WHERE toYYYYMM(created_at) IN ('202311', '202312', '202401');

-- 替换多个分区
ALTER TABLE test_partition.users
REPLACE PARTITION '202311', '202312', '202401'
FROM test_partition.users_temp;

-- 验证结果
SELECT 
    toYYYYMM(created_at) as month,
    count() as count,
    countIf(status = 'inactive') as inactive_count
FROM test_partition.users
GROUP BY month;

-- ========================================
-- REPLACE PARTITION
-- ========================================

-- 创建源表和目标表
CREATE TABLE test_partition.source_table (
    id UInt64,
    value String,
    created_at DateTime
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(created_at)
ORDER BY id;

CREATE TABLE test_partition.target_table (
    id UInt64,
    value String,
    created_at DateTime
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(created_at)
ORDER BY id;

-- 向源表插入数据
INSERT INTO test_partition.source_table VALUES
(1, 'value1', '2024-01-15 08:00:00'),
(2, 'value2', '2024-01-16 09:00:00'),
(3, 'value3', '2024-02-01 10:00:00');

-- 分离分区
ALTER TABLE test_partition.source_table
DETACH PARTITION '202401';

-- 附加分区到目标表
ALTER TABLE test_partition.target_table
ATTACH PARTITION '202401'
FROM test_partition.source_table;

-- 验证结果
SELECT * FROM test_partition.target_table;

-- ========================================
-- REPLACE PARTITION
-- ========================================

-- 创建归档表
CREATE TABLE test_partition.users_archive (
    user_id UInt64,
    username String,
    email String,
    status String,
    created_at DateTime,
    updated_at DateTime
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(created_at)
ORDER BY user_id;

-- 归档旧数据（2023 年的数据）
ALTER TABLE test_partition.users_archive
REPLACE PARTITION '202301', '202302', '202303', 
                 '202304', '202305', '202306',
                 '202307', '202308', '202309',
                 '202310', '202311', '202312'
FROM test_partition.users;

-- 验证归档
SELECT 
    toYYYYMM(created_at) as month,
    count() as count
FROM test_partition.users_archive
GROUP BY month
ORDER BY month;

-- ========================================
-- REPLACE PARTITION
-- ========================================

-- 创建新表（优化结构）
CREATE TABLE test_partition.users_new (
    user_id UInt64,
    username String,
    email String,
    status String,
    created_at DateTime,
    updated_at DateTime
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(created_at)
ORDER BY (user_id, updated_at)
SETTINGS index_granularity = 8192;

-- 逐月迁移数据
ALTER TABLE test_partition.users_new
REPLACE PARTITION '202401'
FROM test_partition.users;

ALTER TABLE test_partition.users_new
REPLACE PARTITION '202402'
FROM test_partition.users;

-- 继续迁移其他月份...

-- ========================================
-- REPLACE PARTITION
-- ========================================

-- 创建修正后的数据
CREATE TABLE test_partition.orders_fixed AS test_partition.orders;

-- 修正数据（将所有订单金额增加 10%）
INSERT INTO test_partition.orders_fixed
SELECT 
    order_id,
    user_id,
    product_id,
    amount * 1.1 as amount,
    order_date,
    status
FROM test_partition.orders
WHERE toYYYYMM(order_date) = '202401'
  AND status = 'pending';

-- 替换分区
ALTER TABLE test_partition.orders
REPLACE PARTITION '202401'
FROM test_partition.orders_fixed;

-- 验证修正结果
SELECT 
    order_id,
    amount,
    status
FROM test_partition.orders
WHERE toYYYYMM(order_date) = '202401'
  AND status = 'pending';

-- ========================================
-- REPLACE PARTITION
-- ========================================

-- 创建临时表
CREATE TABLE test_partition.events_temp AS test_partition.events;

-- 更新最近 3 个月的数据
INSERT INTO test_partition.events_temp
SELECT 
    event_id,
    user_id,
    event_type,
    event_data,
    processed = 1,
    processed_at = now()
FROM test_partition.events
WHERE toYYYYMM(event_time) IN (
    toYYYYMM(now() - INTERVAL 1 MONTH),
    toYYYYMM(now() - INTERVAL 2 MONTH),
    toYYYYMM(now() - INTERVAL 3 MONTH)
);

-- 替换分区
ALTER TABLE test_partition.events
REPLACE PARTITION 
    toYYYYMM(now() - INTERVAL 1 MONTH),
    toYYYYMM(now() - INTERVAL 2 MONTH),
    toYYYYMM(now() - INTERVAL 3 MONTH)
FROM test_partition.events_temp;

-- 验证结果
SELECT 
    toYYYYMM(event_time) as month,
    count() as total,
    countIf(processed = 1) as processed,
    countIf(processed = 0) as unprocessed
FROM test_partition.events
GROUP BY month;

-- ========================================
-- REPLACE PARTITION
-- ========================================

-- 创建测试表
CREATE TABLE test_partition.users_test AS test_partition.users;

-- 在测试表上测试更新逻辑
INSERT INTO test_partition.users_test
SELECT 
    user_id,
    username,
    email,
    'active' as status,
    created_at,
    now() as updated_at
FROM test_partition.users
WHERE toYYYYMM(created_at) = '202401';

-- 验证测试结果
SELECT count() FROM test_partition.users_test WHERE status = 'active';

-- 如果测试通过，交换分区到生产表
ALTER TABLE test_partition.users
EXCHANGE PARTITION '202401'
WITH test_partition.users_test;

-- 清理测试表
DROP TABLE test_partition.users_test;

-- ========================================
-- REPLACE PARTITION
-- ========================================

-- 按月分区（推荐）
CREATE TABLE events (
    event_id UInt64,
    user_id UInt64,
    event_time DateTime,
    event_data String
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)  -- 按月分区
ORDER BY (user_id, event_time);

-- 避免过于细粒度的分区
PARTITION BY toYYYYMMDD(event_time)  -- 太多分区，影响性能

-- ========================================
-- REPLACE PARTITION
-- ========================================

-- 一次性替换多个分区（高效）
ALTER TABLE users
REPLACE PARTITION '202401', '202402', '202403'
FROM users_temp;

-- 避免逐个替换（低效）
ALTER TABLE users REPLACE PARTITION '202401' FROM users_temp;
ALTER TABLE users REPLACE PARTITION '202402' FROM users_temp;
ALTER TABLE users REPLACE PARTITION '202403' FROM users_temp;

-- ========================================
-- REPLACE PARTITION
-- ========================================

-- 使用 EXCHANGE（快速）
ALTER TABLE table1
EXCHANGE PARTITION '202401'
WITH table2;

-- 替代 DROP + INSERT（慢速）
ALTER TABLE table1 DROP PARTITION '202401';
INSERT INTO table1 SELECT * FROM table2 WHERE ...;

-- ========================================
-- REPLACE PARTITION
-- ========================================

-- 使用临时表存储更新后的数据
CREATE TABLE temp_users AS users;

-- 更新数据
INSERT INTO temp_users
SELECT * FROM users WHERE ...;

-- 替换分区
ALTER TABLE users
REPLACE PARTITION '202401'
FROM temp_users;

-- 清理临时表
DROP TABLE temp_users;

-- ========================================
-- REPLACE PARTITION
-- ========================================

-- 查看表的分区
SELECT 
    partition,
    sum(rows) as total_rows,
    sum(bytes_on_disk) as total_bytes,
    formatReadableSize(sum(bytes_on_disk)) as readable_size
FROM system.parts
WHERE database = 'test_partition' 
  AND table = 'users'
  AND active = 1
GROUP BY partition
ORDER BY partition;

-- ========================================
-- REPLACE PARTITION
-- ========================================

-- 更新前后对比
-- 更新前
SELECT 
    toYYYYMM(created_at) as month,
    status,
    count() as count
FROM users
WHERE toYYYYMM(created_at) = '202401'
GROUP BY month, status;

-- 更新后
SELECT 
    toYYYYMM(created_at) as month,
    status,
    count() as count
FROM users
WHERE toYYYYMM(created_at) = '202401'
GROUP BY month, status;

-- ========================================
-- REPLACE PARTITION
-- ========================================

-- 查看最近的分区操作
SELECT 
    type,
    partition_id,
    partition,
    part_name,
    rows,
    bytes_on_disk,
    event_time
FROM system.part_log
WHERE database = 'test_partition'
  AND table = 'users'
ORDER BY event_time DESC
LIMIT 20;

-- ========================================
-- REPLACE PARTITION
-- ========================================

-- 检查分区是否存在
SELECT distinct partition
FROM system.parts
WHERE database = 'test_partition' 
  AND table = 'users'
  AND active = 1;

-- 使用正确的分区名称

-- ========================================
-- REPLACE PARTITION
-- ========================================

-- 确保两个表的结构完全一致
DESCRIBE TABLE test_partition.users;
DESCRIBE TABLE test_partition.users_temp;

-- 如果结构不同，需要先修改表结构
ALTER TABLE test_partition.users_temp
MODIFY COLUMN new_column String;

-- ========================================
-- REPLACE PARTITION
-- ========================================

-- 确保两个表的引擎相同
SELECT engine FROM system.tables
WHERE database = 'test_partition'
  AND table IN ('users', 'users_temp');

-- 如果引擎不同，需要先修改表引擎
ALTER TABLE test_partition.users_temp
MODIFY ENGINE = MergeTree();
