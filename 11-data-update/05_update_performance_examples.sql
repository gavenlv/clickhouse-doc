-- 创建数据库（如果存在则不创建）
CREATE DATABASE IF NOT EXISTS example;


ALTER TABLE users
UPDATE status = 'active'
WHERE user_id IN (1, 2, 3, ..., 1000)
-- REMOVED SET lightweight_update (not supported) 1;

-- 大数据量（> 30%）: 分区更新最快
ALTER TABLE users
REPLACE PARTITION '202401'
FROM users_temp;

-- ========================================
-- 1. 数据量
-- ========================================

-- 单分区: Mutation 较慢，轻量级更新快
-- 多分区: 分区更新最快，分区越多越快

-- 查看分区数量
SELECT 
    count(DISTINCT '') as partition_count
FROM system.parts
WHERE table = 'users'
  AND active = 1;

-- ========================================
-- 1. 数据量
-- ========================================

-- 使用主键（快速）
ALTER TABLE users
UPDATE status = 'active'
WHERE user_id IN (1, 2, 3);  -- user_id 是主键

-- 避免低选择性条件（慢速）
ALTER TABLE users
UPDATE status = 'active'
WHERE status = 'pending';  -- status 不是主键

-- ========================================
-- 1. 数据量
-- ========================================

-- 更新小类型字段（快）
UPDATE status = 'active'  -- String, 低 cardinality

-- 更新大类型字段（慢）
UPDATE event_data = 'new data'  -- String, 高 cardinality

-- ========================================
-- 1. 数据量
-- ========================================

-- 创建临时表
CREATE TABLE IF NOT EXISTS users_temp AS users;

-- 更新数据
INSERT INTO users_temp
SELECT 
    user_id,
    username,
    email,
    'active' as status,
    created_at,
    now() as updated_at
FROM users
WHERE toYYYYMM(created_at) = '202401';

-- 替换分区
ALTER TABLE users
REPLACE PARTITION '202401'
FROM users_temp;

-- 清理
DROP TABLE users_temp;

-- ========================================
-- 1. 数据量
-- ========================================

-- 启用轻量级更新
ALTER TABLE users
UPDATE status = 'active'
WHERE user_id IN (1, 2, 3)
-- REMOVED SET lightweight_update (not supported) 1;

-- ========================================
-- 1. 数据量
-- ========================================

-- 分批更新，每次 10 万行
-- 批次 1
ALTER TABLE users
UPDATE status = 'active'
WHERE user_id BETWEEN 1 AND 100000;

-- 批次 2
ALTER TABLE users
UPDATE status = 'active'
WHERE user_id BETWEEN 100001 AND 200000;

-- 继续分批...

-- ========================================
-- 1. 数据量
-- ========================================

-- 限制并发线程数
ALTER TABLE users
UPDATE status = 'active'
WHERE user_id IN (1, 2, 3)
-- REMOVED SET lightweight_update (not supported) 1,
    max_threads = 2;  -- 限制为 2 个线程

-- 限制内存使用
ALTER TABLE users
UPDATE status = 'active'
WHERE user_id IN (1, 2, 3)
-- REMOVED SET lightweight_update (not supported) 1,
    max_memory_usage = 10000000000;  -- 10GB

-- ========================================
-- 1. 数据量
-- ========================================

-- 使用定时任务在低峰期执行
-- 例如：每天凌晨 2 点执行
ALTER TABLE users
UPDATE status = 'inactive'
WHERE last_login < now() - INTERVAL 90 DAY;

-- ========================================
-- 1. 数据量
-- ========================================

-- ❌ 低效：低选择性条件
ALTER TABLE users
UPDATE status = 'active'
WHERE email LIKE '%@example.com';

-- ✅ 高效：高选择性条件
ALTER TABLE users
UPDATE status = 'active'
WHERE user_id IN (1, 2, 3, 4, 5);

-- ========================================
-- 1. 数据量
-- ========================================

-- ❌ 低效：不使用分区
ALTER TABLE users
UPDATE status = 'active'
WHERE created_at >= '2024-01-01';

-- ✅ 高效：使用分区裁剪
ALTER TABLE users
UPDATE status = 'active'
WHERE toYYYYMM(created_at) = '202401';

-- ========================================
-- 1. 数据量
-- ========================================

-- ❌ 低效：更新整个表
ALTER TABLE users
UPDATE status = 'active';

-- ✅ 高效：只更新必要的数据
ALTER TABLE users
UPDATE status = 'active'
WHERE created_at >= '2024-01-01'
  AND created_at < '2024-02-01'
  AND user_id IN (SELECT user_id FROM active_users);

-- ========================================
-- 1. 数据量
-- ========================================

-- 创建表时指定配置
CREATE TABLE IF NOT EXISTS users (
    user_id UInt64,
    username String,
    status String,
    created_at DateTime
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(created_at)
ORDER BY user_id
SETTINGS -- REMOVED SETTING lightweight_update (not supported) 1,
    index_granularity = 8192,
    min_bytes_for_wide_part = 10485760;

-- ========================================
-- 1. 数据量
-- ========================================

-- 设置查询级别参数
ALTER TABLE users
UPDATE status = 'active'
WHERE user_id IN (1, 2, 3)
-- REMOVED SET lightweight_update (not supported) 1,
    max_threads = 4,
    max_memory_usage = 5000000000,  -- 5GB
    priority = 8;

-- ========================================
-- 1. 数据量
-- ========================================

-- 查看 Mutation 进度
SELECT 
    mutation_id,
    command,
    is_done,
    parts_to_do,
    parts_to_do_names,
    progress,
    created_at
FROM system.mutations
WHERE database = 'current_db'
  AND table = 'users'
ORDER BY created DESC;

-- ========================================
-- 1. 数据量
-- ========================================

-- 查看 CPU 和内存使用
SELECT 
    query_id,
    thread_id,
    cpu_time_nanoseconds,
    memory_usage,
    peak_memory_usage,
    read_rows,
    read_bytes,
    written_rows,
    written_bytes
FROM system.processes
WHERE query LIKE '%UPDATE%'
ORDER BY cpu_time_nanoseconds DESC;

-- ========================================
-- 1. 数据量
-- ========================================

-- 查看磁盘读写
SELECT 
    event_time,
    read_bytes,
    write_bytes,
    read_rows,
    write_rows
FROM system.asynchronous_metrics
WHERE metric LIKE '%Disk%'
ORDER BY event_time DESC
LIMIT 10;

-- ========================================
-- 1. 数据量
-- ========================================

-- 查看后台任务队列
SELECT 
    type,
    database,
    table,
    elapsed,
    progress,
    num_parts,
    source_part_names
FROM system.replication_queue
ORDER BY event_time DESC;

-- ========================================
-- 1. 数据量
-- ========================================

-- 1. 创建临时表
CREATE TABLE IF NOT EXISTS orders_temp AS orders;

-- 2. 更新数据
INSERT INTO orders_temp
SELECT 
    order_id,
    user_id,
    product_id,
    amount * 1.1 as amount,  -- 涨价 10%
    order_date,
    status
FROM orders
WHERE toYYYYMM(order_date) IN ('202401', '202402', '202403');

-- 3. 替换分区
ALTER TABLE orders
REPLACE PARTITION '202401', '202402', '202403'
FROM orders_temp;

-- 4. 清理
DROP TABLE orders_temp;

-- ========================================
-- 1. 数据量
-- ========================================

-- 最新数据使用轻量级更新
ALTER TABLE users
UPDATE status = 'active'
WHERE last_login >= now() - INTERVAL 7 DAY
-- REMOVED SET lightweight_update (not supported) 1;

-- 旧数据使用分区更新
CREATE TABLE IF NOT EXISTS users_temp AS users;
INSERT INTO users_temp
SELECT 
    user_id,
    username,
    email,
    'inactive' as status,
    created_at,
    last_login
FROM users
WHERE last_login < now() - INTERVAL 90 DAY;

ALTER TABLE users
REPLACE PARTITION '202311', '202312'
FROM users_temp;

DROP TABLE users_temp;

-- ========================================
-- 1. 数据量
-- ========================================

-- 创建分层物化视图
-- 1. 最近 7 天数据（轻量级更新）
CREATE MATERIALIZED VIEW users_7d_mv
ENGINE = MergeTree()
ORDER BY user_id
AS SELECT * FROM users
WHERE created_at >= now() - INTERVAL 7 DAY;

-- 2. 最近 30 天数据（分区更新）
CREATE MATERIALIZED VIEW users_30d_mv
ENGINE = MergeTree()
ORDER BY user_id
AS SELECT * FROM users
WHERE created_at >= now() - INTERVAL 30 DAY;

-- 更新策略
-- 最新数据: 轻量级更新
ALTER TABLE users
UPDATE status = 'active'
WHERE created_at >= now() - INTERVAL 7 DAY
-- REMOVED SET lightweight_update (not supported) 1;

-- 历史数据: 分区更新
ALTER TABLE users
REPLACE PARTITION '202401'
FROM users_temp;

-- ========================================
-- 1. 数据量
-- ========================================

-- 原始表设计
CREATE TABLE IF NOT EXISTS events (
    event_id UInt64,
    user_id UInt64,
    event_type String,
    event_data String,
    processed UInt8 DEFAULT 0,
    event_time DateTime
) ENGINE = MergeTree()
ORDER BY event_time;

-- 优化后表设计（追加模式）
CREATE TABLE IF NOT EXISTS events_raw (
    event_id UInt64,
    user_id UInt64,
    event_type String,
    event_data String,
    event_time DateTime
) ENGINE = MergeTree()
ORDER BY (user_id, event_time);

CREATE TABLE IF NOT EXISTS event_updates (
    event_id UInt64,
    user_id UInt64,
    update_type String,
    update_data String,
    update_time DateTime
) ENGINE = MergeTree()
ORDER BY (event_id, update_time);

-- 查询时合并
SELECT 
    r.event_id,
    r.user_id,
    r.event_type,
    r.event_data,
    u.update_type,
    u.update_data
FROM events_raw r
LEFT JOIN (
    SELECT 
        event_id,
        argMax(update_type, update_time) as update_type,
        argMax(update_data, update_time) as update_data
    FROM event_updates
    GROUP BY event_id
) u ON r.event_id = u.event_id
WHERE r.event_time >= now() - INTERVAL 30 DAY;

-- ========================================
-- 1. 数据量
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

-- 更新原表，物化视图自动更新
ALTER TABLE events
UPDATE status = 'processed'
WHERE event_time >= now() - INTERVAL 7 DAY;

-- ========================================
-- 1. 数据量
-- ========================================

-- 创建带 TTL 的表
CREATE TABLE IF NOT EXISTS events (
    event_id UInt64,
    user_id UInt64,
    event_type String,
    event_data String,
    event_time DateTime
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (user_id, event_time)
TTL event_time + INTERVAL 90 DAY;

-- 更新数据，旧数据自动清理
ALTER TABLE events
UPDATE status = 'processed'
WHERE event_time >= now() - INTERVAL 7 DAY;

-- ========================================
-- 1. 数据量
-- ========================================

-- 创建跳数索引
CREATE TABLE IF NOT EXISTS events (
    event_id UInt64,
    user_id UInt64,
    event_type String,
    event_data String,
    event_time DateTime,
    status String
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (user_id, event_time)
SETTINGS index_granularity = 8192;

-- 创建跳数索引
ALTER TABLE events
ADD INDEX idx_status status
TYPE set(0)
GRANULARITY 4;

-- 更新时使用索引加速
ALTER TABLE events
UPDATE status = 'processed'
WHERE status = 'pending'
  AND event_time >= now() - INTERVAL 7 DAY;

-- ========================================
-- 1. 数据量
-- ========================================

-- 创建投影
ALTER TABLE events
ADD PROJECTION p_status (
    SELECT 
        user_id,
        event_type,
        status,
        count() as event_count
    GROUP BY user_id, event_type, status
);

-- 更新数据，投影自动更新
ALTER TABLE events
UPDATE status = 'processed'
WHERE status = 'pending';

-- ========================================
-- 1. 数据量
-- ========================================

-- 从外部数据更新
-- 1. 导出需要更新的数据到文件
-- 2. 使用外部表更新
CREATE EXTERNAL TABLE updates (
    user_id UInt64,
    status String
) ENGINE = File(CSV);

-- 执行更新
ALTER TABLE users
UPDATE status = updates.status
FROM users
JOIN updates ON users.user_id = updates.user_id;

-- ========================================
-- 1. 数据量
-- ========================================

-- ❌ 错误做法
-- 每分钟执行一次
ALTER TABLE users UPDATE status = 'active' WHERE user_id = 1;

-- ✅ 正确做法
-- 每小时批量执行一次
ALTER TABLE users
UPDATE status = 'active'
WHERE user_id IN (1, 2, 3, ..., 100);

-- ========================================
-- 1. 数据量
-- ========================================

-- ❌ 错误做法
ALTER TABLE users
UPDATE status = 'active'
WHERE email LIKE '%@example.com';

-- ✅ 正确做法
ALTER TABLE users
UPDATE status = 'active'
WHERE user_id IN (1, 2, 3, ..., 100);

-- ========================================
-- 1. 数据量
-- ========================================

-- ✅ 正确做法
ALTER TABLE users
UPDATE status = 'inactive'
WHERE last_login < now() - INTERVAL 90 DAY
-- REMOVED SET max_threads (not supported) 2;
