-- ================================================
-- 06_data_encryption_examples.sql
-- 从 06_data_encryption.md 提取的 SQL 示例
-- 提取时间: 2026-01-23 14:40:17
-- ================================================


-- ========================================
-- 使用 AES 加密函数
-- ========================================

-- 创建加密表
CREATE TABLE IF NOT EXISTS secure.encrypted_users
ON CLUSTER 'treasurycluster'
(
    user_id UInt64,
    username String,
    -- 加密敏感字段
    encrypted_email String,
    -- 加密使用 GCM 模式（需自定义函数）
    encrypted_phone String,
    created_at DateTime
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/encrypted_users', '{replica}')
PARTITION BY toYYYYMM(created_at)
ORDER BY (user_id, created_at);

-- 插入加密数据
INSERT INTO secure.encrypted_users
VALUES
(1, 'alice', encrypt('alice@example.com', 'MySecretKey123!', 'AES'), '...', now()),
(2, 'bob', encrypt('bob@example.com', 'MySecretKey123!', 'AES'), '...', now());

-- 查询时解密
SELECT 
    user_id,
    username,
    decrypt(encrypted_email, 'MySecretKey123!', 'AES') as email,
    decrypt(encrypted_phone, 'MySecretKey123!', 'AES') as phone
FROM secure.encrypted_users
WHERE user_id = 1;

-- ========================================
-- 使用 AES 加密函数
-- ========================================

-- 创建自定义加密函数（需要 ClickHouse 支持 UDF）
-- 注意：ClickHouse 社区版不支持 UDF，企业版支持

-- 替代方案：使用应用层加密
-- 1. 应用层使用 AES-256-GCM 加密数据
-- 2. 将加密后的数据存储为 String 或 Binary 类型
-- 3. 查询时在应用层解密

-- 示例：存储加密的 JSON 数据
CREATE TABLE IF NOT EXISTS secure.encrypted_events
ON CLUSTER 'treasurycluster'
(
    event_id UInt64,
    user_id String,
    encrypted_data String,  -- 存储应用层加密的数据
    event_time DateTime
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/encrypted_events', '{replica}')
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_id, event_time);

-- 插入加密数据（应用层加密后）
INSERT INTO secure.encrypted_events
VALUES
(1, 'alice', '{"email":"encrypted_email","phone":"encrypted_phone"}', now());

-- 查询数据（应用层解密）
SELECT 
    event_id,
    user_id,
    encrypted_data  -- 应用层解密
FROM secure.encrypted_events;

-- ========================================
-- 使用 AES 加密函数
-- ========================================

-- 1. 只加密必要列
CREATE TABLE IF NOT EXISTS secure.optimized_users
ON CLUSTER 'treasurycluster'
(
    user_id UInt64,
    username String,
    -- 只加密敏感列
    encrypted_email String,  -- 加密
    encrypted_phone String,  -- 加密
    -- 非敏感列不加密
    status String,
    created_at DateTime
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/optimized_users', '{replica}')
PARTITION BY toYYYYMM(created_at)
ORDER BY (user_id, created_at);

-- 2. 使用物化视图加速查询
CREATE MATERIALIZED VIEW IF NOT EXISTS secure.users_email_view
ENGINE = ReplicatedAggregatingMergeTree()
AS SELECT
    user_id,
    decrypt(encrypted_email, 'MySecretKey123!', 'AES') as email,
    count() as count
FROM secure.encrypted_users
GROUP BY user_id, email;

-- 3. 使用缓存
SET use_query_cache = 1;

SELECT 
    user_id,
    decrypt(encrypted_email, 'MySecretKey123!', 'AES') as email
FROM secure.encrypted_users
WHERE user_id = 1;

-- ========================================
-- 使用 AES 加密函数
-- ========================================

-- 第 1 层：公开数据（无加密）
CREATE TABLE IF NOT EXISTS secure.public_data
ON CLUSTER 'treasurycluster'
(
    event_id UInt64,
    event_type String,
    event_time DateTime
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/public_data', '{replica}')
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_id, event_time);

-- 第 2 层：内部数据（传输加密）
CREATE TABLE IF NOT EXISTS secure.internal_data
ON CLUSTER 'treasurycluster'
(
    event_id UInt64,
    user_id String,
    event_data String,
    event_time DateTime
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/internal_data', '{replica}')
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_id, event_time);

-- 第 3 层：敏感数据（列级加密）
CREATE TABLE IF NOT EXISTS secure.sensitive_data
ON CLUSTER 'treasurycluster'
(
    event_id UInt64,
    user_id String,
    encrypted_data String,  -- 应用层加密
    event_time DateTime
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/sensitive_data', '{replica}')
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_id, event_time);

-- 第 4 层：绝密数据（磁盘加密 + 列级加密）
-- 表存储在加密的磁盘上
CREATE TABLE IF NOT EXISTS secure.top_secret_data
ON CLUSTER 'treasurycluster'
(
    event_id UInt64,
    user_id String,
    encrypted_data String,  -- 应用层加密
    event_time DateTime
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/top_secret_data', '{replica}')
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_id, event_time)
SETTINGS storage_policy = 'encrypted_policy';
