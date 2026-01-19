-- ================================================
-- 02_replicated_engines.sql
-- ClickHouse ReplicatedMergeTree 系列引擎示例
-- ================================================

-- ========================================
-- 1. ReplicatedMergeTree（复制基础引擎）
-- ========================================

-- 创建 ReplicatedMergeTree 表（使用默认路径配置）
CREATE TABLE IF NOT EXISTS engine_test.replicated_events (
    event_id UInt64,
    user_id UInt64,
    event_type String,
    event_data String,
    timestamp DateTime
) ENGINE = ReplicatedMergeTree()
PARTITION BY toYYYYMM(timestamp)
ORDER BY (user_id, event_type, timestamp);

-- 插入测试数据
INSERT INTO engine_test.replicated_events (event_id, user_id, event_type, event_data, timestamp) VALUES
(1, 1, 'click', '{"page":"home"}', '2024-01-01 10:00:00'),
(2, 1, 'view', '{"page":"products"}', '2024-01-01 10:05:00'),
(3, 2, 'click', '{"page":"products"}', '2024-01-01 11:00:00'),
(4, 3, 'purchase', '{"product_id":101,"amount":99.99}', '2024-01-01 12:00:00'),
(5, 1, 'logout', '{"duration":3600}', '2024-01-02 09:00:00');

-- 查询数据
SELECT * FROM engine_test.replicated_events ORDER BY event_id;

-- 查看复制状态
SELECT
    database,
    table,
    is_leader,
    can_become_leader,
    is_readonly,
    is_session_expired,
    replica_name,
    replica_path,
    zookeeper_path,
    queue_size,
    absolute_delay,
    total_replicas,
    active_replicas
FROM system.replicas
WHERE table = 'replicated_events'
ORDER BY replica_name;

-- 查看复制队列
SELECT
    database,
    table,
    type,
    replica_name,
    position,
    node_name,
    processed,
    num_events,
    exceptions
FROM system.replication_queue
WHERE table = 'replicated_events'
ORDER BY replica_name, position
LIMIT 20;

-- ========================================
-- 2. ReplicatedReplacingMergeTree（复制去重引擎）
-- ========================================

-- 创建 ReplicatedReplacingMergeTree 表
CREATE TABLE IF NOT EXISTS engine_test.replicated_user_state (
    user_id UInt64,
    state String,
    last_updated DateTime,
    version UInt64
) ENGINE = ReplicatedReplacingMergeTree(version)
PARTITION BY toYYYYMM(last_updated)
ORDER BY user_id;

-- 插入数据
INSERT INTO engine_test.replicated_user_state VALUES
(1, 'online', '2024-01-01 10:00:00', 1),
(2, 'offline', '2024-01-01 11:00:00', 1),
(3, 'busy', '2024-01-01 12:00:00', 1);

-- 更新用户状态（插入新版本）
INSERT INTO engine_test.replicated_user_state VALUES
(1, 'busy', '2024-01-01 10:30:00', 2),
(2, 'online', '2024-01-01 11:30:00', 2),
(4, 'away', '2024-01-01 13:00:00', 1);

-- 查询去重后的数据
SELECT * FROM engine_test.replicated_user_state FINAL ORDER BY user_id;

-- 查看复制状态
SELECT
    replica_name,
    is_leader,
    queue_size,
    absolute_delay
FROM system.replicas
WHERE table = 'replicated_user_state';

-- ========================================
-- 3. ReplicatedSummingMergeTree（复制求和引擎）
-- ========================================

-- 创建 ReplicatedSummingMergeTree 表
CREATE TABLE IF NOT EXISTS engine_test.replicated_daily_sales (
    date Date,
    product_id UInt32,
    country String,
    amount Decimal(10, 2),
    order_count UInt32
) ENGINE = ReplicatedSummingMergeTree()
PARTITION BY toYYYYMM(date)
ORDER BY (date, product_id, country);

-- 插入销售数据
INSERT INTO engine_test.replicated_daily_sales VALUES
('2024-01-01', 101, 'US', 99.99, 1),
('2024-01-01', 101, 'US', 99.99, 1),
('2024-01-01', 102, 'US', 49.99, 1),
('2024-01-01', 102, 'UK', 59.99, 1),
('2024-01-02', 101, 'US', 199.99, 1);

-- 查询聚合后的数据
SELECT * FROM engine_test.replicated_daily_sales FINAL ORDER BY date, product_id, country;

-- 按日期和产品查询
SELECT
    date,
    product_id,
    sum(amount) as total_amount,
    sum(order_count) as total_orders
FROM engine_test.replicated_daily_sales
GROUP BY date, product_id
ORDER BY date, product_id;

-- ========================================
-- 4. ReplicatedAggregatingMergeTree（复制高级聚合引擎）
-- ========================================

-- 创建 ReplicatedAggregatingMergeTree 表
CREATE TABLE IF NOT EXISTS engine_test.replicated_user_metrics (
    user_id UInt64,
    event_date Date,
    page_views AggregateFunction(count),
    distinct_pages AggregateFunction(uniq, String),
    total_time AggregateFunction(sum, UInt64)
) ENGINE = ReplicatedAggregatingMergeTree()
PARTITION BY toYYYYMM(event_date)
ORDER BY (user_id, event_date);

-- 插入聚合状态数据
INSERT INTO engine_test.replicated_user_metrics
SELECT
    user_id,
    toDate(timestamp) as event_date,
    countState() as page_views,
    uniqState(event_type) as distinct_pages,
    sumState(length(event_data)) as total_time
FROM engine_test.replicated_events
GROUP BY user_id, toDate(timestamp);

-- 查询并合并聚合结果
SELECT
    user_id,
    event_date,
    countMerge(page_views) as total_page_views,
    uniqMerge(distinct_pages) as distinct_event_types,
    sumMerge(total_time) as total_data_size
FROM engine_test.replicated_user_metrics
GROUP BY user_id, event_date
ORDER BY user_id, event_date;

-- ========================================
-- 5. ReplicatedCollapsingMergeTree（复制折叠引擎）
-- ========================================

-- 创建 ReplicatedCollapsingMergeTree 表
CREATE TABLE IF NOT EXISTS engine_test.replicated_inventory (
    product_id UInt64,
    quantity_change Int32,
    sign Int8,
    timestamp DateTime
) ENGINE = ReplicatedCollapsingMergeTree(sign)
PARTITION BY toYYYYMM(timestamp)
ORDER BY product_id;

-- 插入初始库存
INSERT INTO engine_test.replicated_inventory VALUES
(101, 100, 1, '2024-01-01 10:00:00'),
(102, 50, 1, '2024-01-01 10:00:00'),
(103, 75, 1, '2024-01-01 10:00:00');

-- 销售商品
INSERT INTO engine_test.replicated_inventory VALUES
(101, 10, -1, '2024-01-01 11:00:00'),
(102, 5, -1, '2024-01-01 11:00:00');

-- 再次进货
INSERT INTO engine_test.replicated_inventory VALUES
(101, 20, 1, '2024-01-01 12:00:00'),
(103, 10, 1, '2024-01-01 12:00:00');

-- 查询当前库存
SELECT
    product_id,
    sum(quantity_change * sign) as current_inventory
FROM engine_test.replicated_inventory
GROUP BY product_id
ORDER BY product_id;

-- ========================================
-- 6. ReplicatedVersionedCollapsingMergeTree（复制版本折叠引擎）
-- ========================================

-- 创建 ReplicatedVersionedCollapsingMergeTree 表
CREATE TABLE IF NOT EXISTS engine_test.replicated_user_scores (
    user_id UInt64,
    score_change Int32,
    sign Int8,
    version UInt64,
    timestamp DateTime
) ENGINE = ReplicatedVersionedCollapsingMergeTree(sign, version)
PARTITION BY toYYYYMM(timestamp)
ORDER BY user_id;

-- 插入初始分数
INSERT INTO engine_test.replicated_user_scores VALUES
(1, 100, 1, 1, '2024-01-01 10:00:00'),
(2, 150, 1, 1, '2024-01-01 10:00:00'),
(3, 200, 1, 1, '2024-01-01 10:00:00');

-- 更新分数
INSERT INTO engine_test.replicated_user_scores VALUES
(1, -100, -1, 1, '2024-01-01 11:00:00'),
(1, 120, 1, 2, '2024-01-01 11:00:00'),
(2, -150, -1, 1, '2024-01-01 11:00:00'),
(2, 160, 1, 2, '2024-01-01 11:00:00');

-- 查询最新分数
SELECT
    user_id,
    sum(score_change * sign) as current_score
FROM engine_test.replicated_user_scores
GROUP BY user_id
ORDER BY user_id;

-- ========================================
-- 7. 复制对比测试
-- ========================================

-- 创建测试表对比普通引擎和复制引擎
CREATE TABLE IF NOT EXISTS engine_test.mt_compare (
    id UInt64,
    user_id UInt64,
    data String,
    timestamp DateTime
) ENGINE = MergeTree()
ORDER BY (user_id, timestamp);

CREATE TABLE IF NOT EXISTS engine_test.rmt_compare (
    id UInt64,
    user_id UInt64,
    data String,
    timestamp DateTime
) ENGINE = ReplicatedMergeTree()
ORDER BY (user_id, timestamp);

-- 插入相同的数据
INSERT INTO engine_test.mt_compare SELECT
    number as id,
    number % 100 as user_id,
    repeat('data', 10) as data,
    now() - INTERVAL rand() * 30 DAY as timestamp
FROM numbers(10000);

INSERT INTO engine_test.rmt_compare SELECT
    number as id,
    number % 100 as user_id,
    repeat('data', 10) as data,
    now() - INTERVAL rand() * 30 DAY as timestamp
FROM numbers(10000);

-- 对比查询性能
SELECT 'MergeTree' as engine, count() as row_count FROM engine_test.mt_compare
UNION ALL
SELECT 'ReplicatedMergeTree', count() FROM engine_test.rmt_compare;

-- 查看表的复制信息
SELECT
    name,
    engine,
    total_rows,
    total_bytes,
    replica_path,
    zookeeper_path
FROM system.tables
WHERE table LIKE '%_compare'
  AND database = 'engine_test';

-- ========================================
-- 8. 复制延迟监控
-- ========================================

-- 查看所有复制表的延迟
SELECT
    database,
    table,
    replica_name,
    is_leader,
    queue_size,
    absolute_delay,
    formatReadableTimeDelta(absolute_delay) as delay_readable
FROM system.replicas
WHERE database = 'engine_test'
ORDER BY table, replica_name;

-- 查看复制队列详情
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
WHERE database = 'engine_test'
ORDER BY table, replica_name, position
LIMIT 30;

-- 统计复制健康状态
SELECT
    table,
    sum(if(is_leader, 1, 0)) as leader_count,
    sum(if(is_session_expired, 1, 0)) as expired_count,
    avg(queue_size) as avg_queue_size,
    max(absolute_delay) as max_delay_seconds
FROM system.replicas
WHERE database = 'engine_test'
GROUP BY table
ORDER BY table;

-- ========================================
-- 9. 复制性能测试
-- ========================================

-- 创建大表进行复制性能测试
CREATE TABLE IF NOT EXISTS engine_test.rmt_performance (
    id UInt64,
    user_id UInt64,
    event_type String,
    event_value Float64,
    timestamp DateTime
) ENGINE = ReplicatedMergeTree()
PARTITION BY toYYYYMM(timestamp)
ORDER BY (user_id, timestamp);

-- 插入大量数据
INSERT INTO engine_test.rmt_performance SELECT
    number as id,
    number % 1000 as user_id,
    concat('type_', toString(number % 10)) as event_type,
    rand() * 1000 as event_value,
    now() - INTERVAL rand() * 30 DAY as timestamp
FROM numbers(100000);

-- 查询性能测试
SELECT
    user_id,
    count() as event_count,
    avg(event_value) as avg_value
FROM engine_test.rmt_performance
WHERE user_id IN (100, 200, 300)
GROUP BY user_id
ORDER BY user_id;

-- 监控复制延迟
SELECT
    table,
    replica_name,
    queue_size,
    absolute_delay,
    is_leader
FROM system.replicas
WHERE table = 'rmt_performance';

-- ========================================
-- 10. 复制表维护
-- ========================================

-- 查看表的分区信息
SELECT
    database,
    table,
    partition,
    sum(rows) as total_rows,
    sum(bytes_on_disk) as total_bytes,
    formatReadableSize(sum(bytes_on_disk)) as readable_size,
    count() as part_count
FROM system.parts
WHERE database = 'engine_test'
  AND table LIKE 'replicated%'
  AND active = 1
GROUP BY database, table, partition
ORDER BY table, partition;

-- 执行 OPTIMIZE 合并数据（会触发复制）
-- OPTIMIZE TABLE engine_test.replicated_events FINAL;

-- 删除旧分区（需要所有副本同意）
-- ALTER TABLE engine_test.replicated_events DROP PARTITION '202401';

-- ========================================
-- 11. 清理测试表
-- ========================================
DROP TABLE IF EXISTS engine_test.replicated_events;
DROP TABLE IF EXISTS engine_test.replicated_user_state;
DROP TABLE IF EXISTS engine_test.replicated_daily_sales;
DROP TABLE IF EXISTS engine_test.replicated_user_metrics;
DROP TABLE IF EXISTS engine_test.replicated_inventory;
DROP TABLE IF EXISTS engine_test.replicated_user_scores;
DROP TABLE IF EXISTS engine_test.mt_compare;
DROP TABLE IF EXISTS engine_test.rmt_compare;
DROP TABLE IF EXISTS engine_test.rmt_performance;

-- ========================================
-- 12. ReplicatedMergeTree 引擎最佳实践总结
-- ========================================
/*
ReplicatedMergeTree 系列引擎最佳实践：

1. 生产环境必备
   - 所有生产表都应使用 ReplicatedMergeTree 系列
   - 确保至少 2 个副本
   - 配置合理的 Keeper 集群（至少 3 节点）

2. 性能优化
   - 使用默认路径配置简化表创建
   - 优化 ORDER BY 排序键
   - 合理设置分区粒度
   - 定期监控复制延迟

3. 数据一致性
   - 监控复制队列
   - 检查 leader 选举
   - 验证副本数据一致性
   - 处理过期会话

4. 故障处理
   - 监控副本状态
   - 自动故障转移
   - 手动恢复副本
   - 数据同步验证

5. 维护操作
   - 定期 OPTIMIZE
   - 删除旧分区
   - 监控磁盘空间
   - 备份 ZooKeeper 数据

6. 监控告警
   - 复制延迟 > 60s
   - 队列大小 > 100
   - 无 leader
   - 会话过期

选择建议：
- 生产环境：始终使用 ReplicatedMergeTree 系列
- 测试环境：可以使用 MergeTree 系列
- 需要去重：ReplicatedReplacingMergeTree
- 需要求和：ReplicatedSummingMergeTree
- 复杂聚合：ReplicatedAggregatingMergeTree
- 增量更新：ReplicatedCollapsingMergeTree
*/
