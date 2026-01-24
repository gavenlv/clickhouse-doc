-- 创建测试表
CREATE TABLE IF NOT EXISTS events (
    event_id UInt64,
    event_time DateTime,
    data String
) ENGINE = MergeTree
PARTITION BY toYYYYMM(event_time)
ORDER BY event_id;

INSERT INTO events VALUES
    (1, toDateTime('2022-12-01 00:00:00'), 'old data'),
    (2, toDateTime('2023-01-15 00:00:00'), 'new data');

-- ========================================
-- 📋 基本语法
-- ========================================

-- 轻量级删除是异步的
ALTER TABLE events
DELETE WHERE event_time < toDateTime('2023-01-01')
SETTINGS lightweight_delete = 1;

-- 删除会立即返回，后台执行

-- ========================================
-- 📋 轻量级删除查询
-- ========================================

-- 注意：allow_experimental_lightweight_delete设置用于查询，而不是DELETE
-- 创建更多测试数据
INSERT INTO events VALUES
    (3, toDateTime('2022-11-01 00:00:00'), 'very old data'),
    (4, toDateTime('2022-12-15 00:00:00'), 'more old data');

-- 查看表中的数据（轻量级删除后）
SELECT
    event_id,
    event_time,
    data
FROM events
ORDER BY event_time;

-- ========================================
-- 📋 基本语法
-- ========================================

-- 创建user_events测试表
CREATE TABLE IF NOT EXISTS user_events (
    event_id UInt64,
    user_id UInt64,
    event_time DateTime
) ENGINE = MergeTree
ORDER BY event_id;

INSERT INTO user_events VALUES
    (1, 123, toDateTime('2023-01-01 00:00:00')),
    (2, 456, toDateTime('2023-01-01 00:00:00'));

-- 删除少量数据（<10%）
ALTER TABLE events
DELETE WHERE event_id = 1
SETTINGS lightweight_delete = 1;

-- 删除中等量数据（10-30%）
ALTER TABLE user_events
DELETE WHERE user_id = 123
SETTINGS lightweight_delete = 1;

-- ========================================
-- 📋 基本语法
-- ========================================

-- 快速删除用户数据（user_id是UInt64类型）
ALTER TABLE user_events
DELETE WHERE user_id = 123
SETTINGS lightweight_delete = 1;

ALTER TABLE user_profile
DELETE WHERE user_id = 'user123'
SETTINGS lightweight_delete = 1;

-- 记录删除操作
INSERT INTO data_deletion_log
VALUES ('user123', now(), 'lightweight_delete');

-- ========================================
-- 📋 过期数据删除
-- ========================================

-- 实时删除过期数据（创建物化视图）
-- CREATE MATERIALIZED VIEW IF NOT EXISTS expired_events_mv
-- ENGINE = MergeTree()
-- ORDER BY event_id
-- AS SELECT
--     event_id,
--     event_time
-- FROM events
-- WHERE event_time < now() - INTERVAL 90 DAY;

-- 定期执行轻量级删除
-- 可以通过外部调度器触发
ALTER TABLE events
DELETE WHERE event_time < now() - INTERVAL 90 DAY
SETTINGS lightweight_delete = 1;

-- ========================================
-- 📋 条件删除
-- ========================================

-- 创建带environment列的events表
DROP TABLE IF EXISTS events;

CREATE TABLE events (
    event_id UInt64,
    event_time DateTime,
    environment String,
    data String
) ENGINE = MergeTree
ORDER BY event_id;

INSERT INTO events VALUES
    (1, now(), 'test', 'test data 1'),
    (2, now(), 'production', 'prod data 1');

-- 创建logs表
CREATE TABLE IF NOT EXISTS logs (
    log_id UInt64,
    log_time DateTime,
    level String,
    message String
) ENGINE = MergeTree
ORDER BY log_id;

INSERT INTO logs VALUES
    (1, now(), 'debug', 'debug message 1'),
    (2, now(), 'info', 'info message 1');

-- 删除测试环境数据
ALTER TABLE events
DELETE WHERE environment = 'test'
SETTINGS lightweight_delete = 1;

-- 删除调试数据
ALTER TABLE logs
DELETE WHERE level = 'debug'
SETTINGS lightweight_delete = 1;

-- ========================================
-- 📋 监控轻量级删除
-- ========================================

-- 注意：system.processes表不存在，应该使用其他方式监控
-- 查看最近的查询
-- SELECT
--     query_id,
--     query,
--     read_rows,
--     written_rows
-- FROM system.query_log
-- WHERE type = 'QueryFinish'
--   AND query ILIKE '%lightweight%'
-- ORDER BY event_time DESC
-- LIMIT 10;

-- ========================================
-- 📋 标记删除的数据
-- ========================================

-- 注意：allow_experimental_lightweight_delete设置仅用于SELECT，不会显示标记的数据
-- 查看被标记删除的数据（实际上不会看到已删除的数据）
SELECT
    event_id,
    event_time,
    data
FROM events
WHERE event_time < toDateTime('2023-01-01')
ORDER BY event_time
LIMIT 10;

-- ========================================
-- 📋 空间监控
-- ========================================

-- 监控轻量级删除的空间占用（查看活跃分区）
SELECT
    'Active Rows' as metric,
    sum(rows) as value,
    formatReadableSize(sum(bytes_on_disk)) as size
FROM system.parts
WHERE database = 'default' AND table = 'events' AND active = 1

UNION ALL

SELECT
    'All Parts Count',
    count() as value,
    formatReadableSize(sum(bytes_on_disk)) as size
FROM system.parts
WHERE database = 'default' AND table = 'events' AND active = 1;

-- ========================================
-- 📋 批量删除
-- ========================================

-- 从用户删除列表中读取要删除的用户 ID
-- 假设有一个表存储了要删除的用户
CREATE TABLE IF NOT EXISTS users_to_delete (
    user_id String
) ENGINE = MergeTree
ORDER BY user_id;

-- 插入要删除的用户 ID
INSERT INTO users_to_delete VALUES
    ('user123'),
    ('user456'),
    ('user789');

-- 创建user_events表
CREATE TABLE IF NOT EXISTS user_events (
    event_id UInt64,
    user_id String,
    event_time DateTime
) ENGINE = MergeTree
ORDER BY event_id;

INSERT INTO user_events VALUES
    (1, 'user123', now()),
    (2, 'user456', now()),
    (3, 'user789', now());

-- 执行轻量级删除（子查询中的user_id是String类型）
ALTER TABLE user_events
DELETE WHERE user_id IN (
    SELECT user_id FROM users_to_delete
)
SETTINGS lightweight_delete = 1;

ALTER TABLE user_profile
DELETE WHERE user_id IN (
    SELECT user_id FROM users_to_delete
)
SETTINGS lightweight_delete = 1;

-- 清空删除列表
TRUNCATE TABLE users_to_delete;

-- ========================================
-- 📋 监控视图
-- ========================================

-- 创建监控视图（注意：allow_experimental_lightweight_delete设置不会保留已删除的数据）
-- DROP VIEW IF EXISTS deletion_monitor;

-- CREATE VIEW deletion_monitor AS
-- SELECT
--     now() as timestamp,
--     'events_count' as metric,
--     count() as rows_count
-- FROM events
-- WHERE event_time < now() - INTERVAL 90 DAY;

-- 定期查询监控数据
-- SELECT * FROM deletion_monitor
-- ORDER BY timestamp DESC
-- LIMIT 1;

-- 查看即将过期的数据
SELECT
    count() as rows_to_expire,
    min(event_time) as oldest_event_time,
    max(event_time) as newest_event_time
FROM events
WHERE event_time < now() - INTERVAL 90 DAY;

-- ========================================
-- 📋 基本语法
-- ========================================

-- 轻量级删除只是标记数据
-- 实际删除需要通过合并操作

-- 触发合并以清理已标记的数据
OPTIMIZE TABLE events FINAL;

-- 或者等待自然的合并过程
-- 可以调整合并策略加快合并

-- 查看合并进度
SELECT
    table,
    '',
    sum(rows) as rows,
    count() as parts
FROM system.parts
WHERE table = 'events' AND active = 1
GROUP BY table, partition;

-- ========================================
-- 📋 查询设置
-- ========================================

-- 在查询中启用（allow_experimental_lightweight_delete仅用于特殊标记查询）
SELECT * FROM events
ORDER BY event_time DESC
LIMIT 10;

-- 执行轻量级删除
-- ALTER TABLE events
-- DELETE WHERE event_time < toDateTime('2023-01-01'
-- SETTINGS lightweight_delete = 1;

-- ========================================
-- 📋 版本检查
-- ========================================

-- 检查 ClickHouse 版本
SELECT version();

-- 轻量级删除需要 ClickHouse 23.8 或更高版本
-- 如果版本过低，会回退到传统的 Mutation 删除

-- ========================================
-- 📋 空间统计
-- ========================================

-- 轻量级删除不会立即释放存储空间
-- 已标记删除的数据仍然占用空间

-- 查看实际占用的空间
SELECT
    'Total on disk' as metric,
    formatReadableSize(sum(bytes_on_disk)) as value
FROM system.parts
WHERE database = 'default' AND table = 'events' AND active = 1

UNION ALL

SELECT
    'Active Parts Count',
    formatReadableQuantity(count()) as value
FROM system.parts
WHERE database = 'default' AND table = 'events' AND active = 1;

-- ========================================
-- 📋 删除策略选择
-- ========================================

-- 轻量级删除适用于删除少量数据
-- 如果删除大量数据（>30%），应该使用分区删除

-- 判断是否应该使用轻量级删除
SELECT
    count() as total_rows,
    countIf(event_time < toDateTime('2023-01-01')) as rows_to_delete,
    rows_to_delete * 100.0 / total_rows as delete_percentage,
    CASE
        WHEN rows_to_delete * 100.0 / total_rows < 30 THEN 'Use lightweight delete'
        ELSE 'Use partition deletion'
    END as recommendation
FROM events;
