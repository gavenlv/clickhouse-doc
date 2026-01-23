-- ================================================
-- 02_ttl_deletion_examples.sql
-- 从 02_ttl_deletion.md 提取的 SQL 示例
-- 提取时间: 2026-01-23 14:40:17
-- ================================================


-- ========================================
-- 📋 基本语法
-- ========================================

-- 创建表时设置 TTL
CREATE TABLE table_name (
    id UInt64,
    event_time DateTime,
    data String
) ENGINE = MergeTree
PARTITION BY toYYYYMM(event_time)
ORDER BY id
TTL event_time + INTERVAL 90 DAY;

-- 为现有表添加 TTL
ALTER TABLE table_name
MODIFY TTL event_time + INTERVAL 90 DAY;

-- 删除 TTL
ALTER TABLE table_name
REMOVE TTL;

-- ========================================
-- 📋 基本语法
-- ========================================

-- 数据过期后自动删除
CREATE TABLE events (
    id UInt64,
    event_time DateTime,
    data String
) ENGINE = MergeTree
ORDER BY id
TTL event_time + INTERVAL 30 DAY
DELETE;

-- ========================================
-- 📋 基本语法
-- ========================================

-- 数据过期后移动到归档表
CREATE TABLE events (
    id UInt64,
    event_time DateTime,
    data String
) ENGINE = MergeTree
ORDER BY id
TTL event_time + INTERVAL 30 DAY TO DISK 'archive';

-- ========================================
-- 📋 基本语法
-- ========================================

-- 数据过期后重新聚合
CREATE TABLE events (
    id UInt64,
    event_time DateTime,
    user_id UInt64,
    value Float64
) ENGINE = AggregatingMergeTree()
ORDER BY (user_id, event_time)
TTL event_time + INTERVAL 7 DAY
GROUP BY user_id
SET value = sum(value);

-- ========================================
-- 📋 基本语法
-- ========================================

-- 列数据过期后删除或重新计算
CREATE TABLE events (
    id UInt64,
    event_time DateTime,
    temporary_data String TTL event_time + INTERVAL 1 DAY,
    computed_data UInt64
) ENGINE = MergeTree
ORDER BY id;

-- 修改列 TTL
ALTER TABLE events
MODIFY COLUMN temporary_data String TTL event_time + INTERVAL 3 DAY;

-- ========================================
-- 📋 基本语法
-- ========================================

-- 简单的时间到期删除
CREATE TABLE logs (
    event_time DateTime,
    level String,
    message String
) ENGINE = MergeTree
PARTITION BY toYYYYMM(event_time)
ORDER BY event_time
TTL event_time + INTERVAL 30 DAY;

-- ========================================
-- 📋 基本语法
-- ========================================

-- 多个 TTL 规则
CREATE TABLE events (
    event_time DateTime,
    event_type String,
    data String,
    priority UInt8
) ENGINE = MergeTree
ORDER BY event_time
TTL
    event_time + INTERVAL 30 DAY,
    event_time + INTERVAL 7 DAY TO VOLUME 'fast_storage'
    WHERE priority = 1;

-- ========================================
-- 📋 基本语法
-- ========================================

-- 表和列同时设置 TTL
CREATE TABLE events (
    event_time DateTime,
    data String TTL event_time + INTERVAL 1 DAY,
    permanent_data String
) ENGINE = MergeTree
PARTITION BY toYYYYMM(event_time)
ORDER BY event_time
TTL event_time + INTERVAL 90 DAY;

-- ========================================
-- 📋 基本语法
-- ========================================

-- 创建日志表
CREATE TABLE application_logs (
    timestamp DateTime,
    level String,
    service String,
    message String
) ENGINE = MergeTree
PARTITION BY toYYYYMM(timestamp)
ORDER BY (service, timestamp)
TTL timestamp + INTERVAL 30 DAY;

-- 插入数据
INSERT INTO application_logs VALUES
    (now(), 'INFO', 'api', 'Request received'),
    (now() - INTERVAL 31 DAY, 'INFO', 'api', 'Old request');

-- 查询 TTL 信息
SELECT
    database,
    table,
    engine_full,
    ttl_table
FROM system.tables
WHERE table = 'application_logs'\G

-- ========================================
-- 📋 基本语法
-- ========================================

-- 根据 GDPR 要求自动删除用户数据
CREATE TABLE user_events (
    user_id String,
    event_time DateTime,
    event_type String,
    event_data String
) ENGINE = ReplicatedMergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (user_id, event_time)
TTL
    event_time + INTERVAL 90 DAY,          -- 默认 90 天
    event_time + INTERVAL 180 DAY           -- 用户同意时 180 天
    WHERE user_id IN (
        SELECT user_id FROM user_settings WHERE data_retention = 'extended'
    );

-- 查看用户的 TTL 设置
SELECT
    user_id,
    data_retention,
    TTL_setting
FROM user_settings;

-- ========================================
-- 📋 基本语法
-- ========================================

-- 配置存储策略
-- 在 config.xml 中定义存储策略
/*
<storage_configuration>
    <disks>
        <fast>
            <path>/mnt/fast_storage/</path>
        </fast>
        <slow>
            <path>/mnt/slow_storage/</path>
        </slow>
    </disks>
    <policies>
        <tiered_storage>
            <volumes>
                <hot>
                    <disk>fast</disk>
                </hot>
                <cold>
                    <disk>slow</disk>
                </cold>
            </volumes>
        </tiered_storage>
    </policies>
</storage_configuration>
*/

-- 创建表使用分层存储
CREATE TABLE events (
    event_time DateTime,
    data String
) ENGINE = MergeTree
ORDER BY event_time
TTL
    event_time + INTERVAL 7 DAY TO VOLUME 'cold',
    event_time + INTERVAL 90 DAY DELETE
SETTINGS storage_policy = 'tiered_storage';

-- ========================================
-- 📋 基本语法
-- ========================================

-- 时序数据聚合滚动
CREATE TABLE metrics (
    timestamp DateTime,
    metric_name String,
    value Float64,
    tags Map(String, String)
) ENGINE = SummingMergeTree()
ORDER BY (metric_name, timestamp, tags)
TTL
    timestamp + INTERVAL 1 DAY
    GROUP BY metric_name, toStartOfHour(timestamp), tags
    SET value = sum(value),
    
    timestamp + INTERVAL 7 DAY
    GROUP BY metric_name, toStartOfDay(timestamp), tags
    SET value = sum(value),
    
    timestamp + INTERVAL 30 DAY
    GROUP BY metric_name, toStartOfWeek(timestamp), tags
    SET value = sum(value);

-- ========================================
-- 📋 基本语法
-- ========================================

-- 查看表的 TTL 定义
SELECT
    database,
    table,
    ttl_table,
    ttl_definition
FROM system.tables
WHERE database = 'your_database'
  AND table = 'your_table'\G

-- 查看列的 TTL
SELECT
    database,
    table,
    name AS column_name,
    ttl
FROM system.columns
WHERE database = 'your_database'
  AND table = 'your_table'
  AND ttl != '';

-- ========================================
-- 📋 基本语法
-- ========================================

-- 查看即将过期的数据
SELECT
    event_time,
    event_time + INTERVAL 90 DAY AS expire_time,
    dateDiff('day', now(), event_time + INTERVAL 90 DAY) AS days_until_expiry,
    *
FROM events
WHERE event_time + INTERVAL 90 DAY > now()
  AND event_time + INTERVAL 90 DAY < now() + INTERVAL 7 DAY
ORDER BY expire_time
LIMIT 100;

-- ========================================
-- 📋 基本语法
-- ========================================

-- 延长 TTL
ALTER TABLE events
MODIFY TTL event_time + INTERVAL 180 DAY;

-- 缩短 TTL
ALTER TABLE events
MODIFY TTL event_time + INTERVAL 30 DAY;

-- 添加新的 TTL 规则
ALTER TABLE events
MODIFY TTL
    event_time + INTERVAL 30 DAY,
    event_time + INTERVAL 7 DAY TO DISK 'archive' WHERE priority = 1;

-- ========================================
-- 📋 基本语法
-- ========================================

-- 移除表 TTL
ALTER TABLE events
REMOVE TTL;

-- 移除列 TTL
ALTER TABLE events
MODIFY COLUMN temporary_data String;

-- ========================================
-- 📋 基本语法
-- ========================================

-- 查看 TTL 处理日志
SELECT
    event_time,
    event_date,
    database,
    table,
    query,
    type,
    exception_code
FROM system.query_log
WHERE type IN ('QueryFinish', 'ExceptionWhileProcessing')
  AND query ILIKE '%TTL%'
  AND event_date >= today() - INTERVAL 7 DAY
ORDER BY event_time DESC;

-- ========================================
-- 📋 基本语法
-- ========================================

-- 监控数据清理效果
SELECT
    toStartOfDay(event_time) AS day,
    count() AS rows,
    count() / NULLIF(LAG(count()) OVER (ORDER BY day), 0) - 1 AS change_rate
FROM events
WHERE event_time >= today() - INTERVAL 30 DAY
GROUP BY day
ORDER BY day;

-- ========================================
-- 📋 基本语法
-- ========================================

-- 配置多级存储
CREATE TABLE events (
    event_time DateTime,
    data String,
    size UInt64
) ENGINE = MergeTree
PARTITION BY toYYYYMM(event_time)
ORDER BY event_time
TTL
    event_time + INTERVAL 1 DAY TO VOLUME 'hot',      -- 热数据
    event_time + INTERVAL 7 DAY TO VOLUME 'warm',    -- 温数据
    event_time + INTERVAL 30 DAY TO VOLUME 'cold',   -- 冷数据
    event_time + INTERVAL 90 DAY DELETE               -- 删除
SETTINGS storage_policy = 'multi_tier';

-- 查看数据在各层级的分布
SELECT
    CASE
        WHEN event_time >= now() - INTERVAL 1 DAY THEN 'hot'
        WHEN event_time >= now() - INTERVAL 7 DAY THEN 'warm'
        WHEN event_time >= now() - INTERVAL 30 DAY THEN 'cold'
        ELSE 'expiring'
    END AS tier,
    count() AS rows,
    formatReadableSize(sum(length(data))) AS size
FROM events
GROUP BY tier
ORDER BY tier;

-- ========================================
-- 📋 基本语法
-- ========================================

-- 根据数据优先级设置不同 TTL
CREATE TABLE notifications (
    id UInt64,
    event_time DateTime,
    priority UInt8,
    message String
) ENGINE = MergeTree
ORDER BY (priority, event_time)
TTL
    event_time + INTERVAL 1 DAY DELETE WHERE priority = 1,     -- 低优先级 1 天
    event_time + INTERVAL 7 DAY DELETE WHERE priority = 2,     -- 中优先级 7 天
    event_time + INTERVAL 30 DAY DELETE WHERE priority = 3;    -- 高优先级 30 天

-- 插入数据
INSERT INTO notifications VALUES
    (1, now(), 1, 'Low priority'),
    (2, now(), 2, 'Medium priority'),
    (3, now(), 3, 'High priority');

-- ========================================
-- 📋 基本语法
-- ========================================

-- TTL 自动触发分区删除
CREATE TABLE events (
    event_time DateTime,
    data String
) ENGINE = MergeTree
PARTITION BY toYYYYMM(event_time)
ORDER BY event_time
TTL toDateTime(partition) + INTERVAL 90 DAY;

-- TTL 会在整个分区过期时删除整个分区
-- 比单独删除每一行更高效
