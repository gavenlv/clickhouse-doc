-- ================================================================================
-- ClickHouse 分区更新详解
-- ================================================================================
-- 
-- 集群: treasurycluster (2 副本)
-- 预计学习时间: 25 分钟
-- 
-- 本文件涵盖:
--   1. REPLACE PARTITION - 替换分区数据
--   2. EXCHANGE PARTITIONS - 交换分区
--   3. DROP + INSERT - 删除后插入
--   4. ATTACH PARTITION - 附加分区
--   5. 分区更新最佳实践 - 适用场景
-- 
-- ================================================================================
-- 分区更新原理
-- ================================================================================
-- 
--   ┌─────────────────────────────────────────────────────────────────────────┐
--   │                      分区更新 vs Mutation                               │
--   └─────────────────────────────────────────────────────────────────────────┘
--   
--   Mutation 更新:
--   ┌────────────────────────────────────────────────────────────────────────┐
--   │  扫描所有数据 → 匹配条件 → 重写匹配的数据                               │
--   │  适合: 小范围精确更新                                                   │
--   │  不适合: 大范围批量更新 (重写开销大)                                     │
--   └────────────────────────────────────────────────────────────────────────┘
--   
--   分区更新:
--   ┌────────────────────────────────────────────────────────────────────────┐
--   │  直接替换整个分区 → 不需要扫描原数据                                    │
--   │  适合: 按分区的大批量更新                                               │
--   │  性能: 元数据操作, 几乎瞬间完成                                         │
--   └────────────────────────────────────────────────────────────────────────┘
-- 
-- ================================================================================
-- REPLACE PARTITION 工作流程
-- ================================================================================
-- 
--   ┌─────────────────────────────────────────────────────────────────────────┐
--   │                    REPLACE PARTITION 执行流程                           │
--   └─────────────────────────────────────────────────────────────────────────┘
--   
--   步骤 1: 准备新数据
--   ┌────────────────────────────────────────────────────────────────────────┐
--   │  CREATE TABLE users_temp AS users;                                     │
--   │  INSERT INTO users_temp SELECT ... (修改后的数据) ...;                  │
--   └────────────────────────────────────────────────────────────────────────┘
--                    │
--                    ▼
--   步骤 2: 替换分区
--   ┌────────────────────────────────────────────────────────────────────────┐
--   │  ALTER TABLE users REPLACE PARTITION '202401' FROM users_temp;         │
--   │                                                                         │
--   │  原分区:                        新分区:                                 │
--   │  ┌───────────────┐             ┌───────────────┐                       │
--   │  │ Partition     │             │ Partition     │                       │
--   │  │ '202401'      │ ──替换──→   │ '202401'      │                       │
--   │  │ (旧数据)      │             │ (新数据)      │                       │
--   │  └───────────────┘             └───────────────┘                       │
--   │                                                                         │
--   │  这是元数据操作, 几乎瞬间完成!                                          │
--   └────────────────────────────────────────────────────────────────────────┘
--                    │
--                    ▼
--   步骤 3: 清理
--   ┌────────────────────────────────────────────────────────────────────────┐
--   │  DROP TABLE users_temp;                                                │
--   └────────────────────────────────────────────────────────────────────────┘
-- 
-- ================================================================================
-- EXCHANGE PARTITIONS 工作流程
-- ================================================================================
-- 
--   ┌─────────────────────────────────────────────────────────────────────────┐
--   │                    EXCHANGE PARTITIONS 执行流程                         │
--   └─────────────────────────────────────────────────────────────────────────┘
--   
--   场景: 在生产表和测试表之间交换数据
--   
--   交换前:
--   ┌────────────────────────────────────────────────────────────────────────┐
--   │  表 A (生产)                      表 B (测试)                          │
--   │  ┌───────────────┐               ┌───────────────┐                    │
--   │  │ Partition     │               │ Partition     │                    │
--   │  │ '202401'      │               │ '202401'      │                    │
--   │  │ (生产数据)    │               │ (测试数据)    │                    │
--   │  └───────────────┘               └───────────────┘                    │
--   └────────────────────────────────────────────────────────────────────────┘
--                    │
--                    │ ALTER TABLE A EXCHANGE PARTITION '202401' WITH B
--                    ▼
--   交换后:
--   ┌────────────────────────────────────────────────────────────────────────┐
--   │  表 A (生产)                      表 B (测试)                          │
--   │  ┌───────────────┐               ┌───────────────┐                    │
--   │  │ Partition     │               │ Partition     │                    │
--   │  │ '202401'      │               │ '202401'      │                    │
--   │  │ (测试数据)    │               │ (生产数据)    │                    │
--   │  └───────────────┘               └───────────────┘                    │
--   │                                                                         │
--   │  原子操作, 零停机!                                                      │
--   └────────────────────────────────────────────────────────────────────────┘
-- 
-- ================================================================================
-- 分区更新适用场景
-- ================================================================================
-- 
--   ┌─────────────────────────────────────────────────────────────────────────┐
--   │                      分区更新最佳场景                                   │
--   └─────────────────────────────────────────────────────────────────────────┘
--   
--   ✅ 适用:
--   ┌────────────────────────────────────────────────────────────────────────┐
--   │  1. 数据修正: 修正某个月份的所有数据                                    │
--   │  2. 数据回填: 重新加载历史数据                                          │
--   │  3. 数据迁移: 将数据从旧表迁移到新表                                    │
--   │  4. 数据归档: 将旧数据移动到归档表                                      │
--   │  5. 测试部署: 在测试表验证后交换到生产表                                │
--   └────────────────────────────────────────────────────────────────────────┘
--   
--   ❌ 不适用:
--   ┌────────────────────────────────────────────────────────────────────────┐
--   │  1. 跨分区更新: 需要更新多个分散的分区                                  │
--   │  2. 精确更新: 只需要更新少量行                                          │
--   │  3. 实时更新: 需要立即看到更新结果                                      │
--   └────────────────────────────────────────────────────────────────────────┘
-- 
-- ================================================================================
-- 性能对比
-- ================================================================================
-- 
--   更新 2024年1月全部数据 (假设 100GB):
--   
--   方法                执行时间    磁盘 I/O     适用场景
--   ────────────────────────────────────────────────────────────────
--   Mutation            ~10分钟     读+写 200GB  少量行更新
--   REPLACE PARTITION   <1秒       元数据操作   整月数据替换
--   EXCHANGE PARTITION  <1秒       元数据操作   表间数据交换
--   
--   关键洞察:
--   ┌────────────────────────────────────────────────────────────────────────┐
--   │  当更新数据量 > 分区数据的 30% 时, 分区更新更高效                       │
--   │  分区更新是 O(1) 元数据操作, 不需要读写数据                            │
--   └────────────────────────────────────────────────────────────────────────┘
-- 
-- ================================================================================

-- 创建数据库（如果存在则不创建）
CREATE DATABASE IF NOT EXISTS example;


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
DROP TABLE IF EXISTS test_partition.users;
CREATE TABLE IF NOT EXISTS test_partition.users (
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
DROP TABLE IF EXISTS test_partition.users_temp;
CREATE TABLE IF NOT EXISTS test_partition.users_temp AS test_partition.users;

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
DROP TABLE IF EXISTS test_partition.table1;
CREATE TABLE IF NOT EXISTS test_partition.table1 (
    id UInt64,
    value String,
    created_at DateTime
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(created_at)
ORDER BY id;

DROP TABLE IF EXISTS test_partition.table2;
CREATE TABLE IF NOT EXISTS test_partition.table2 (
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
DROP TABLE IF EXISTS test_partition.users_backup;
CREATE TABLE IF NOT EXISTS test_partition.users_backup AS test_partition.users;

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
DROP TABLE IF EXISTS test_partition.users_temp;
CREATE TABLE IF NOT EXISTS test_partition.users_temp AS test_partition.users;

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
DROP TABLE IF EXISTS test_partition.source_table;
CREATE TABLE IF NOT EXISTS test_partition.source_table (
    id UInt64,
    value String,
    created_at DateTime
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(created_at)
ORDER BY id;

DROP TABLE IF EXISTS test_partition.target_table;
CREATE TABLE IF NOT EXISTS test_partition.target_table (
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
DROP TABLE IF EXISTS test_partition.users_archive;
CREATE TABLE IF NOT EXISTS test_partition.users_archive (
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
DROP TABLE IF EXISTS test_partition.users_new;
CREATE TABLE IF NOT EXISTS test_partition.users_new (
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
DROP TABLE IF EXISTS test_partition.orders_fixed;
CREATE TABLE IF NOT EXISTS test_partition.orders_fixed AS test_partition.orders;

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
DROP TABLE IF EXISTS test_partition.events_temp;
CREATE TABLE IF NOT EXISTS test_partition.events_temp AS test_partition.events;

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
DROP TABLE IF EXISTS test_partition.users_test;
CREATE TABLE IF NOT EXISTS test_partition.users_test AS test_partition.users;

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
CREATE TABLE IF NOT EXISTS events (
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
CREATE TABLE IF NOT EXISTS temp_users AS users;

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
    '',
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
    '',
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
SELECT distinct ''
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
