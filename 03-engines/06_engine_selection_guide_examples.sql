-- ================================================
-- 06_engine_selection_guide_examples.sql
-- 从 06_engine_selection_guide.md 提取的 SQL 示例
-- 提取时间: 2026-01-23 14:35:39
-- ================================================


-- ========================================
-- 1. 生产环境配置
-- ========================================

-- 推荐
CREATE TABLE production.events (
    id UInt64,
    data String,
    timestamp DateTime
) ENGINE = ReplicatedMergeTree()
PARTITION BY toYYYYMM(timestamp)
ORDER BY (id, timestamp);

-- 避免
CREATE TABLE production.events (
    id UInt64,
    data String,
    timestamp DateTime
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(timestamp)
ORDER BY (id, timestamp);

-- ========================================
-- 1. 生产环境配置
-- ========================================

-- 按天分区（高频查询）
PARTITION BY toDate(timestamp)

-- 按月分区（推荐）
PARTITION BY toYYYYMM(timestamp)

-- 按年分区（归档）
PARTITION BY toYYYY(timestamp)

-- ========================================
-- 1. 生产环境配置
-- ========================================

-- 常见查询：WHERE user_id = ?
ORDER BY (user_id, timestamp)

-- 常见查询：WHERE user_id = ? AND event_type = ?
ORDER BY (user_id, event_type, timestamp)

-- 时间序列查询：WHERE timestamp > ?
ORDER BY (timestamp, user_id)

-- ========================================
-- 1. 生产环境配置
-- ========================================

-- 添加 minmax 索引
ALTER TABLE events
ADD INDEX idx_timestamp_minmax timestamp TYPE minmax GRANULARITY 4;

-- 添加 bloom_filter 索引
ALTER TABLE events
ADD INDEX idx_user_bloom user_id TYPE bloom_filter(0.01) GRANULARITY 8;

-- ========================================
-- 1. 生产环境配置
-- ========================================

-- 创建源表
CREATE TABLE events (
    user_id UInt64,
    event_type String,
    timestamp DateTime
) ENGINE = ReplicatedMergeTree()
ORDER BY (user_id, timestamp);

-- 创建物化视图
CREATE MATERIALIZED VIEW events_stats_mv
ENGINE = AggregatingMergeTree()
ORDER BY (user_id, toDate(timestamp))
AS SELECT
    user_id,
    toDate(timestamp) as date,
    countState() as event_count_state
FROM events
GROUP BY user_id, toDate(timestamp);

-- 查询物化视图（快速）
SELECT
    user_id,
    date,
    countMerge(event_count_state) as event_count
FROM events_stats_mv
GROUP BY user_id, date;

-- ========================================
-- 1. 生产环境配置
-- ========================================

-- 确保唯一性（业务逻辑去重）
CREATE TABLE unique_events (
    event_id UInt64,
    data String
) ENGINE = ReplacingMergeTree(event_id)
ORDER BY event_id;

-- 查询去重数据
SELECT * FROM unique_events FINAL;

-- 或手动 OPTIMIZE
OPTIMIZE TABLE unique_events FINAL;

-- ========================================
-- 1. 生产环境配置
-- ========================================

-- 创建表
CREATE TABLE inventory (
    product_id UInt64,
    quantity Int32,
    sign Int8,  -- 1 for insert, -1 for delete
    timestamp DateTime
) ENGINE = CollapsingMergeTree(sign)
ORDER BY product_id;

-- 插入库存
INSERT INTO inventory VALUES (101, 100, 1, now());

-- 减少库存
INSERT INTO inventory VALUES (101, 10, -1, now());

-- 查询当前库存
SELECT
    product_id,
    sum(quantity * sign) as current_inventory
FROM inventory
GROUP BY product_id;

-- ========================================
-- 1. 生产环境配置
-- ========================================

-- 常见查询：WHERE user_id = ?
-- 分片键：user_id
CREATE TABLE distributed_events AS local_events
ENGINE = Distributed(cluster, db, local_events, user_id);

-- 常见查询：WHERE timestamp > ?
-- 分片键：intHash32(timestamp)
CREATE TABLE distributed_events AS local_events
ENGINE = Distributed(cluster, db, local_events, intHash32(timestamp));

-- 常见查询：WHERE user_id = ? AND timestamp > ?
-- 分片键：user_id

-- ========================================
-- 1. 生产环境配置
-- ========================================

-- 30 天后删除数据
CREATE TABLE events (
    id UInt64,
    data String,
    timestamp DateTime
) ENGINE = ReplicatedMergeTree()
ORDER BY timestamp
TTL timestamp + INTERVAL 30 DAY;

-- 7 天后移到冷存储
CREATE TABLE events (
    id UInt64,
    data String,
    timestamp DateTime
) ENGINE = ReplicatedMergeTree()
ORDER BY timestamp
TTL timestamp + INTERVAL 7 DAY TO DISK 'cold';

-- 7 天后删除，30 天后归档
CREATE TABLE events (
    id UInt64,
    data String,
    timestamp DateTime
) ENGINE = ReplicatedMergeTree()
ORDER BY timestamp
TTL
    timestamp + INTERVAL 7 DAY DELETE,
    timestamp + INTERVAL 30 DAY TO VOLUME 'archive';
