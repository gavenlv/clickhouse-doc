-- ================================================
-- 02_replicated_tables.sql
-- ClickHouse 复制表示例
-- ================================================

-- ========================================
-- 1. 查看当前配置的 Macros
-- ========================================
SELECT * FROM system.macros;

-- 预期输出（clickhouse1）:
-- macro        substitution
-- cluster      treasurycluster
-- layer        01
-- shard        1
-- replica      clickhouse1
-- table_prefix test

-- 预期输出（clickhouse2）:
-- macro        substitution
-- cluster      treasurycluster
-- layer        01
-- shard        2
-- replica      clickhouse2
-- table_prefix test

-- ========================================
-- 2. 查看默认路径配置
-- ========================================
SELECT
    name,
    value,
    changed
FROM system.settings
WHERE name LIKE '%default_replica%'
ORDER BY name;

-- ========================================
-- 3. 创建复制表（使用默认路径配置）
-- ========================================
-- 注意：不需要手动指定 ZooKeeper 路径
-- 系统会自动使用 {default_replica_path} 和 {default_replica_name}

CREATE TABLE IF NOT EXISTS test_replicated_events (
    event_id UInt64,
    user_id UInt64,
    event_type String,
    event_data String,
    timestamp DateTime DEFAULT now()
) ENGINE = ReplicatedMergeTree
ORDER BY (user_id, timestamp);

-- 验证表是否创建成功
SHOW CREATE test_replicated_events;

-- ========================================
-- 4. 检查表在两个副本上的状态
-- ========================================
-- 在 clickhouse1 上查询
SELECT
    database,
    table,
    engine,
    partition_key,
    sorting_key,
    primary_key
FROM system.tables
WHERE table = 'test_replicated_events';

-- 查看表是否存在
SELECT count() > 0 as table_exists FROM system.tables WHERE database = 'default' AND name = 'test_replicated_events';

-- ========================================
-- 5. 插入测试数据
-- ========================================
INSERT INTO test_replicated_events (event_id, user_id, event_type, event_data) VALUES
(1, 1, 'login', '{"ip":"192.168.1.1","device":"mobile"}'),
(2, 1, 'view_page', '{"page":"/home"}'),
(3, 2, 'login', '{"ip":"192.168.1.2","device":"desktop"}'),
(4, 2, 'purchase', '{"product_id":101,"amount":99.99}'),
(5, 1, 'logout', '{"duration":1800}'),
(6, 3, 'login', '{"ip":"192.168.1.3","device":"tablet"}'),
(7, 3, 'search', '{"query":"laptop"}'),
(8, 4, 'login', '{"ip":"192.168.1.4","device":"desktop"}');

-- 查询数据
SELECT * FROM test_replicated_events ORDER BY event_id;

-- 统计数据量
SELECT count() as total_events FROM test_replicated_events;

-- ========================================
-- 6. 检查复制状态
-- ========================================
-- 查看 system.replicas 表
SELECT
    database,
    table,
    is_leader,
    can_become_leader,
    is_readonly,
    is_session_expired,
    replica_name,
    replica_path,
    queue_size,
    absolute_delay,
    total_replicas,
    active_replicas
FROM system.replicas
WHERE table = 'test_replicated_events';

-- 查看 ZooKeeper 路径
SELECT
    database,
    table,
    zookeeper_path,
    replica_name
FROM system.replicas
WHERE table = 'test_replicated_events';

-- 验证 ZooKeeper 路径是否使用了默认配置
-- 预期路径格式: /clickhouse/tables/{shard}/{table}
-- clickhouse1 应该是: /clickhouse/tables/1/test_replicated_events
-- clickhouse2 应该是: /clickhouse/tables/2/test_replicated_events

-- ========================================
-- 7. 测试数据复制
-- ========================================
-- 在第一个副本上插入数据
INSERT INTO test_replicated_events (event_id, user_id, event_type, event_data) VALUES
(100, 100, 'test_event', '{"test":"data"}');

-- 等待几秒后查询
-- SELECT sleep(2);

-- 在两个副本上验证数据
SELECT 'Replica 1 - Total events:' as info, count() as count FROM test_replicated_events;

-- 连接到 clickhouse2 执行: SELECT 'Replica 2 - Total events:' as info, count() as count FROM test_replicated_events;

-- ========================================
-- 8. 创建另一个复制表（使用分区）
-- ========================================
CREATE TABLE IF NOT EXISTS test_replicated_logs (
    log_id UInt64,
    level String,
    message String,
    service String,
    timestamp DateTime
) ENGINE = ReplicatedMergeTree
PARTITION BY toYYYYMM(timestamp)
ORDER BY (service, timestamp);

-- 插入测试数据（跨越多个月份）
INSERT INTO test_replicated_logs (log_id, level, message, service, timestamp) VALUES
(1, 'INFO', 'Service started', 'api', '2024-01-01 10:00:00'),
(2, 'DEBUG', 'Processing request', 'api', '2024-01-01 10:05:00'),
(3, 'WARNING', 'High latency', 'api', '2024-01-15 14:30:00'),
(4, 'ERROR', 'Connection failed', 'db', '2024-02-01 09:00:00'),
(5, 'INFO', 'Connection restored', 'db', '2024-02-01 09:05:00'),
(6, 'DEBUG', 'Query executed', 'db', '2024-02-20 16:45:00');

-- 查看分区信息
SELECT
    partition,
    name,
    rows,
    bytes_on_disk
FROM system.parts
WHERE table = 'test_replicated_logs' AND active
ORDER BY partition;

-- 按分区查询
SELECT
    toYYYYMM(timestamp) as partition,
    count() as log_count,
    level,
    service
FROM test_replicated_logs
GROUP BY toYYYYMM(timestamp), level, service
ORDER BY toYYYYMM(timestamp), log_count DESC;

-- ========================================
-- 9. 创建带 TTL 的复制表
-- ========================================
CREATE TABLE IF NOT EXISTS test_replicated_metrics (
    metric_id UInt64,
    metric_name String,
    metric_value Float64,
    timestamp DateTime
) ENGINE = ReplicatedMergeTree
ORDER BY (metric_name, timestamp)
TTL timestamp + INTERVAL 7 DAY
SETTINGS
    index_granularity = 8192;

-- 插入测试数据
INSERT INTO test_replicated_metrics (metric_id, metric_name, metric_value, timestamp) VALUES
(1, 'cpu_usage', 45.5, now() - INTERVAL 10 DAY),
(2, 'memory_usage', 68.2, now() - INTERVAL 5 DAY),
(3, 'disk_usage', 78.9, now() - INTERVAL 3 DAY),
(4, 'cpu_usage', 52.3, now() - INTERVAL 1 DAY),
(5, 'memory_usage', 71.1, now());

-- 查询数据
SELECT
    metric_name,
    metric_value,
    timestamp,
    dateDiff('day', timestamp, now()) as days_ago
FROM test_replicated_metrics
ORDER BY timestamp DESC;

-- ========================================
-- 10. 测试 ReplacingMergeTree（复制）
-- ========================================
CREATE TABLE IF NOT EXISTS test_replicated_user_state (
    user_id UInt64,
    state String,
    last_updated DateTime,
    version UInt64
) ENGINE = ReplicatedReplacingMergeTree(version)
ORDER BY user_id;

-- 插入同一用户的多次状态更新
INSERT INTO test_replicated_user_state VALUES
(1, 'online', now() - INTERVAL 10 MINUTE, 1),
(2, 'offline', now() - INTERVAL 8 MINUTE, 1),
(3, 'online', now() - INTERVAL 6 MINUTE, 1);

INSERT INTO test_replicated_user_state VALUES
(1, 'busy', now() - INTERVAL 5 MINUTE, 2),
(2, 'online', now() - INTERVAL 4 MINUTE, 2),
(4, 'offline', now() - INTERVAL 2 MINUTE, 1);

-- 查询（可以看到重复数据）
SELECT * FROM test_replicated_user_state ORDER BY user_id, version;

-- 使用 FINAL 去重（只保留版本最大的记录）
SELECT * FROM test_replicated_user_state FINAL ORDER BY user_id;

-- ========================================
-- 11. 测试 CollapsingMergeTree（复制）
-- ========================================
CREATE TABLE IF NOT EXISTS test_replicated_inventory (
    product_id UInt64,
    quantity_change Int32,
    sign Int8, -- 1 for insert, -1 for delete
    timestamp DateTime
) ENGINE = ReplicatedCollapsingMergeTree(sign)
ORDER BY product_id;

-- 插入数据
INSERT INTO test_replicated_inventory VALUES
(1, 100, 1, now() - INTERVAL 1 DAY),  -- Initial stock: 100
(2, 50, 1, now() - INTERVAL 1 DAY),   -- Initial stock: 50
(3, 75, 1, now() - INTERVAL 1 DAY);  -- Initial stock: 75

-- 卖出商品（使用负的 sign）
INSERT INTO test_replicated_inventory VALUES
(1, 10, -1, now() - INTERVAL 12 HOUR),  -- Sold 10
(2, 5, -1, now() - INTERVAL 12 HOUR);    -- Sold 5

-- 再次进货
INSERT INTO test_replicated_inventory VALUES
(1, 20, 1, now() - INTERVAL 6 HOUR),    -- Restock 20
(3, 10, 1, now() - INTERVAL 6 HOUR);    -- Restock 10

-- 查询原始数据
SELECT * FROM test_replicated_inventory ORDER BY product_id, timestamp;

-- 使用 FINAL 查询（自动折叠）
SELECT
    product_id,
    sum(quantity_change) as current_stock
FROM test_replicated_inventory
GROUP BY product_id
ORDER BY product_id;

-- ========================================
-- 12. 查看复制队列和延迟
-- ========================================
SELECT
    database,
    table,
    type,
    replica_name,
    position,
    node_name,
    processed,
    num_events,
    exceptions,
    exception_code
FROM system.replication_queue
WHERE table IN ('test_replicated_events', 'test_replicated_logs')
ORDER BY table, replica_name, position;

-- ========================================
-- 13. 清理测试表（生产环境：使用 ON CLUSTER SYNC 确保集群范围删除）
-- ========================================
-- 注意：需要在所有副本上执行 DROP，或者只在一个副本上执行
DROP TABLE IF EXISTS test_replicated_events ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS test_replicated_logs ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS test_replicated_metrics ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS test_replicated_user_state ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS test_replicated_inventory ON CLUSTER 'treasurycluster' SYNC;

-- ========================================
-- 14. 验证清理
-- ========================================
SELECT name FROM system.tables WHERE name LIKE 'test_replicated%';
