-- 创建测试表
CREATE TABLE IF NOT EXISTS events (
    id UInt64,
    event_time DateTime,
    data String,
    level String
) ENGINE = MergeTree
PARTITION BY toYYYYMM(event_time)
ORDER BY id;

-- 插入测试数据
INSERT INTO events VALUES
    (1, toDateTime('2022-12-01 00:00:00'), 'test data 1', 'info'),
    (2, toDateTime('2023-01-15 00:00:00'), 'test data 2', 'info'),
    (3, toDateTime('2023-06-01 00:00:00'), 'test data 3', 'debug');

-- ========================================
-- 📋 基本语法
-- ========================================

-- Mutation 是异步执行的
ALTER TABLE events
DELETE WHERE event_time < toDateTime('2023-01-01');

-- 查看执行状态
SELECT
    database,
    table,
    command,
    create_time
FROM system.mutations
WHERE database = 'default' AND table = 'events'
ORDER BY create_time DESC
LIMIT 10;

-- ========================================
-- 📋 查看Mutation信息
-- ========================================

-- Mutation 是重操作，会触发数据重写
-- 查看受影响的行数
SELECT
    database,
    table,
    command,
    create_time
FROM system.mutations
WHERE database = 'default'
ORDER BY create_time DESC
LIMIT 10;

-- ========================================
-- 📋 删除数据
-- ========================================

-- 删除特定条件的数据
ALTER TABLE events
DELETE WHERE event_time < toDateTime('2023-01-01');

-- 删除多个条件
ALTER TABLE events
DELETE WHERE level = 'debug';

-- 使用子查询（需要先创建deleted_users表）
CREATE TABLE IF NOT EXISTS deleted_users (
    user_id UInt64
) ENGINE = MergeTree
ORDER BY user_id;

INSERT INTO deleted_users VALUES (1);

-- ALTER TABLE events
-- DELETE WHERE id IN (
--     SELECT user_id FROM deleted_users
-- );

-- ========================================
-- 📋 基本语法
-- ========================================

-- 将大删除拆分为多个小批次
-- 批次 1
ALTER TABLE events
DELETE WHERE event_time >= '2022-01-01' AND event_time < '2022-03-01';

-- 批次 2
ALTER TABLE events
DELETE WHERE event_time >= '2022-03-01' AND event_time < '2022-05-01';

-- 批次 3
ALTER TABLE events
DELETE WHERE event_time >= '2022-05-01' AND event_time < '2022-07-01';

-- ========================================
-- 📋 更新数据
-- ========================================

-- 创建带status列的测试表
CREATE TABLE IF NOT EXISTS test_events (
    id UInt64,
    event_time DateTime,
    status String,
    data String
) ENGINE = MergeTree
ORDER BY id;

INSERT INTO test_events VALUES
    (1, toDateTime('2022-12-01 00:00:00'), 'active', 'data1'),
    (2, toDateTime('2023-01-15 00:00:00'), 'active', 'data2'),
    (3, toDateTime('2023-06-01 00:00:00'), 'active', 'data3');

-- 更新单列
ALTER TABLE test_events
UPDATE status = 'archived' WHERE event_time < toDateTime('2023-01-01');

-- 使用表达式更新
ALTER TABLE test_events
UPDATE status = CASE
    WHEN event_time < toDateTime('2023-01-01') THEN 'archived'
    WHEN event_time < toDateTime('2023-06-01') THEN 'old'
    ELSE 'current'
END;

-- ========================================
-- 📋 多列更新
-- ========================================

-- 创建users测试表
CREATE TABLE IF NOT EXISTS users (
    user_id UInt64,
    last_login DateTime,
    login_count UInt64
) ENGINE = MergeTree
ORDER BY user_id;

INSERT INTO users VALUES
    (1, now(), 5),
    (2, now(), 10);

-- 更新多列
ALTER TABLE users
UPDATE
    last_login = now(),
    login_count = login_count + 1
WHERE user_id = 1;

-- 创建带tags列的events表
CREATE TABLE IF NOT EXISTS tagged_events (
    id UInt64,
    event_time DateTime,
    tags Map(String, String)
) ENGINE = MergeTree
ORDER BY id;

INSERT INTO tagged_events VALUES
    (1, now(), {'status': 'new', 'type': 'test'});

-- 使用 Map 更新
ALTER TABLE tagged_events
UPDATE tags = mapInsert(tags, 'processed', 'true') WHERE id = 1;

-- ========================================
-- 📋 复杂更新
-- ========================================

-- 创建orders测试表
CREATE TABLE IF NOT EXISTS orders (
    order_id UInt64,
    status String,
    cancelled_at DateTime,
    created_at DateTime,
    payment_status String
) ENGINE = MergeTree
ORDER BY order_id;

INSERT INTO orders VALUES
    (1, 'pending', toDateTime('1970-01-01'), now() - INTERVAL 10 DAY, 'failed'),
    (2, 'completed', toDateTime('1970-01-01'), now(), 'success');

-- 复杂条件更新
ALTER TABLE orders
UPDATE
    status = 'cancelled',
    cancelled_at = now()
WHERE
    status = 'pending'
    AND created_at < now() - INTERVAL 7 DAY
    AND payment_status = 'failed';

-- ========================================
-- 📋 用户数据删除
-- ========================================

-- 创建user_events测试表
CREATE TABLE IF NOT EXISTS user_events (
    id UInt64,
    user_id UInt64,
    event_time DateTime,
    event_data String
) ENGINE = MergeTree
ORDER BY id;

INSERT INTO user_events VALUES
    (1, 123, now(), 'event1'),
    (2, 123, now(), 'event2'),
    (3, 456, now(), 'event3');

-- 删除用户的所有数据（注意：user_id是UInt64类型，不需要引号）
ALTER TABLE user_events
DELETE WHERE user_id = 123;

-- 扩展users表以包含更多列
DROP TABLE IF EXISTS users;

CREATE TABLE users (
    user_id UInt64,
    email String,
    phone String,
    address String
) ENGINE = MergeTree
ORDER BY user_id;

INSERT INTO users VALUES
    (123, 'test@example.com', '123456', 'address1'),
    (456, 'test2@example.com', '654321', 'address2');

-- 删除用户的敏感信息（保留统计）
ALTER TABLE users
UPDATE
    email = 'deleted@deleted.com',
    phone = 'deleted',
    address = 'deleted'
WHERE user_id = 123;

-- 创建删除日志表
CREATE TABLE IF NOT EXISTS data_deletion_log (
    user_id UInt64,
    action String,
    timestamp DateTime
) ENGINE = MergeTree
ORDER BY timestamp;

-- 记录删除操作
INSERT INTO data_deletion_log
SELECT
    user_id,
    'delete' as action,
    now() as timestamp
FROM users
WHERE user_id = 123;

-- ========================================
-- 📋 数据修正
-- ========================================

-- 重新创建orders表以包含正确的列
DROP TABLE IF EXISTS orders;

CREATE TABLE orders (
    order_id UInt64,
    quantity UInt64,
    unit_price Float64,
    total_amount Float64
) ENGINE = MergeTree
ORDER BY order_id;

INSERT INTO orders VALUES
    (1, 10, 100.0, 1000.0),
    (2, 5, 50.0, 1000.0),  -- 错误的数据
    (3, 3, 30.0, 90.0);

-- 修正错误数据
ALTER TABLE orders
UPDATE total_amount = quantity * unit_price
WHERE total_amount != quantity * unit_price;

-- 创建带event_date_str列的events表
CREATE TABLE IF NOT EXISTS events_with_date (
    id UInt64,
    event_time DateTime,
    event_date_str String
) ENGINE = MergeTree
ORDER BY id;

INSERT INTO events_with_date VALUES
    (1, toDateTime('1970-01-01'), '2023-01-15 10:30:00'),
    (2, toDateTime('1970-01-01'), '2023-06-01 14:20:00');

-- 修正日期格式错误（注意：不能更新ORDER BY列，这里会失败，仅作为示例）
-- ALTER TABLE events_with_date
-- UPDATE event_time = parseDateTimeBestEffort(event_date_str)
-- WHERE event_time = toDateTime('1970-01-01');

-- ========================================
-- 📋 软删除
-- ========================================

-- 创建messages测试表
CREATE TABLE IF NOT EXISTS messages (
    message_id UInt64,
    content String,
    is_deleted UInt8,
    deleted_at DateTime
) ENGINE = MergeTree
ORDER BY message_id;

INSERT INTO messages VALUES
    (1, 'message 1', 0, toDateTime('1970-01-01')),
    (2, 'message 2', 0, toDateTime('1970-01-01')),
    (3, 'message 3', 0, toDateTime('1970-01-01'));

-- 创建moderation_queue表
CREATE TABLE IF NOT EXISTS moderation_queue (
    message_id UInt64,
    action String
) ENGINE = MergeTree
ORDER BY message_id;

INSERT INTO moderation_queue VALUES
    (1, 'delete'),
    (3, 'delete');

-- 软删除（标记而非物理删除）
ALTER TABLE messages
UPDATE is_deleted = 1, deleted_at = now()
WHERE message_id IN (
    SELECT message_id FROM moderation_queue
    WHERE action = 'delete'
);

-- 查看软删除的数据
SELECT * FROM messages WHERE is_deleted = 1;

-- 恢复软删除的数据
ALTER TABLE messages
UPDATE is_deleted = 0, deleted_at = now()
WHERE message_id = 1;

-- ========================================
-- 📋 聚合更新
-- ========================================

-- 注意：ClickHouse的UPDATE不支持GROUP BY语法
-- 这里展示如何先聚合再更新

-- 创建daily_metrics表
CREATE TABLE IF NOT EXISTS daily_metrics (
    date Date,
    metric_name String,
    total_value Float64
) ENGINE = MergeTree
ORDER BY (date, metric_name);

INSERT INTO daily_metrics VALUES
    (today() - INTERVAL 1 DAY, 'metric1', 100.0),
    (today() - INTERVAL 1 DAY, 'metric2', 200.0);

-- 创建metrics原始数据表
CREATE TABLE IF NOT EXISTS metrics_raw (
    date Date,
    metric_name String,
    value Float64
) ENGINE = MergeTree
ORDER BY (date, metric_name);

INSERT INTO metrics_raw VALUES
    (today() - INTERVAL 1 DAY, 'metric1', 150.0),
    (today() - INTERVAL 1 DAY, 'metric1', 200.0),
    (today() - INTERVAL 1 DAY, 'metric2', 250.0);

-- 方法1：先聚合再更新
-- ALTER TABLE daily_metrics
-- UPDATE total_value = aggregated_value
-- FROM (
--     SELECT date, metric_name, sum(value) as aggregated_value
--     FROM metrics_raw
--     GROUP BY date, metric_name
-- ) AS agg
-- WHERE daily_metrics.date = agg.date AND daily_metrics.metric_name = agg.metric_name;

-- ========================================
-- 📋 查看Mutation
-- ========================================

-- 查看所有 Mutation（只使用存在的字段）
SELECT
    database,
    table,
    command,
    create_time
FROM system.mutations
WHERE database = 'default'
ORDER BY create_time DESC
LIMIT 20;

-- ========================================
-- 📋 资源监控
-- ========================================

-- 注意：system.mutations表不包含elapsed等资源使用字段
-- 监控 Mutation 的执行情况
SELECT
    database,
    table,
    command,
    create_time
FROM system.mutations
WHERE database = 'default' AND table = 'events'
ORDER BY create_time DESC
LIMIT 10;

-- ========================================
-- 📋 影响预估
-- ========================================

-- 预估 Mutation 的影响（使用events表）
SELECT
    '预估删除行数' as metric,
    count() as value
FROM events
WHERE event_time < toDateTime('2023-01-01')

UNION ALL

SELECT
    '预估影响的分区数',
    count(DISTINCT partition)
FROM system.parts
WHERE database = 'default' AND table = 'events' AND active = 1

UNION ALL

SELECT
    '预估影响的数据量',
    formatReadableSize(sum(bytes_on_disk))
FROM system.parts
WHERE database = 'default' AND table = 'events' AND active = 1;

-- ========================================
-- 📋 安全删除流程
-- ========================================

-- 重新创建events表用于演示
DROP TABLE IF EXISTS events;

CREATE TABLE events (
    id UInt64,
    event_time DateTime,
    data String,
    partition String
) ENGINE = MergeTree
PARTITION BY partition
ORDER BY id;

INSERT INTO events VALUES
    (1, toDateTime('2022-06-01 00:00:00'), 'old data 1', '202206'),
    (2, toDateTime('2022-08-01 00:00:00'), 'old data 2', '202208'),
    (3, toDateTime('2023-02-01 00:00:00'), 'new data', '202302');

-- 步骤 1: 预估影响
SELECT
    count() AS rows_to_delete,
    formatReadableSize(length(data)) AS size_to_delete,
    count(DISTINCT partition) AS partitions_affected
FROM events
WHERE event_time < toDateTime('2023-01-01');

-- 步骤 2: 备份数据
CREATE TABLE IF NOT EXISTS events_backup AS events;

INSERT INTO events_backup
SELECT * FROM events
WHERE event_time < toDateTime('2023-01-01');

-- 步骤 3: 验证备份
SELECT count() FROM events_backup;

-- 步骤 4: 执行删除
ALTER TABLE events
DELETE WHERE event_time < toDateTime('2023-01-01')
SETTINGS mutations_sync = 1;

-- 步骤 5: 验证删除
SELECT count() FROM events WHERE event_time < toDateTime('2023-01-01');

-- ========================================
-- 📋 优先级删除
-- ========================================

-- 重新创建events表以包含priority列
DROP TABLE IF EXISTS events;

CREATE TABLE events (
    id UInt64,
    event_time DateTime,
    data String,
    priority String
) ENGINE = MergeTree
ORDER BY id;

INSERT INTO events VALUES
    (1, toDateTime('2022-06-01 00:00:00'), 'low priority data', 'low'),
    (2, toDateTime('2022-08-01 00:00:00'), 'medium priority data', 'medium'),
    (3, toDateTime('2022-10-01 00:00:00'), 'high priority data', 'high');

-- 按优先级删除数据

-- 先删除最不重要的数据
ALTER TABLE events
DELETE WHERE priority = 'low' AND event_time < toDateTime('2023-01-01');

-- 再删除中等重要数据
ALTER TABLE events
DELETE WHERE priority = 'medium' AND event_time < toDateTime('2023-01-01');

-- 最后删除高优先级数据（如有必要）
-- ALTER TABLE events
-- DELETE WHERE priority = 'high' AND event_time < toDateTime('2023-01-01');

-- ========================================
-- 📋 增量删除
-- ========================================

-- 重新创建events表用于演示
DROP TABLE IF EXISTS events;

CREATE TABLE events (
    id UInt64,
    event_time DateTime,
    data String
) ENGINE = MergeTree
ORDER BY id;

INSERT INTO events VALUES
    (1, toDateTime('2021-12-01 00:00:00'), 'very old data'),
    (2, toDateTime('2022-02-01 00:00:00'), 'old data'),
    (3, toDateTime('2022-04-01 00:00:00'), 'recent data');

-- 第一天：删除最旧的数据
ALTER TABLE events
DELETE WHERE event_time < toDateTime('2022-01-01');

-- 第二天：删除次旧的数据
ALTER TABLE events
DELETE WHERE
    event_time >= toDateTime('2022-01-01')
    AND event_time < toDateTime('2022-03-01');

-- 第三天：删除更近的数据
ALTER TABLE events
DELETE WHERE
    event_time >= toDateTime('2022-03-01')
    AND event_time < toDateTime('2022-06-01');

-- ========================================
-- 📋 同步/异步控制
-- ========================================

-- 异步执行（默认）
ALTER TABLE events
DELETE WHERE event_time < toDateTime('2023-01-01');

-- 同步执行（等待完成）
ALTER TABLE events
DELETE WHERE event_time < toDateTime('2023-01-01'
SETTINGS mutations_sync = 1);

-- 同步执行所有之前的 Mutation（mutations_sync=2不支持，使用1代替）
-- ALTER TABLE events
-- DELETE WHERE event_time < toDateTime('2023-01-01')
-- SETTINGS mutations_sync = 2;

-- ========================================
-- 📋 控制参数
-- ========================================

-- 注意：max_threads设置在DELETE语句中不支持
-- 同步删除（等待完成）
ALTER TABLE events
DELETE WHERE event_time < toDateTime('2023-01-01')
SETTINGS mutations_sync = 1;

-- 复制表的去重窗口设置（仅示例，实际使用需要ReplicatedMergeTree）
-- ALTER TABLE events
-- DELETE WHERE event_time < toDateTime('2023-01-01')
-- SETTINGS replicated_deduplication_window = 0;
