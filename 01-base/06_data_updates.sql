-- ========================================
-- ClickHouse 数据更新和实时场景示例
-- ========================================
-- 说明：ClickHouse 不支持传统的 UPDATE 操作
-- 但提供了多种替代方案来实现数据更新和删除
--
-- ⚠️ 重要提示：生产环境必须使用复制引擎 + ON CLUSTER
--    - 使用 ReplicatedMergeTree 系列引擎（非复制引擎的复制版本）
--    - 添加 ON CLUSTER 'treasurycluster'
--    - 这保证 2 个副本都有数据，实现高可用
-- ========================================

-- ========================================
-- 1. ReplicatedReplacingMergeTree - 数据去重更新
-- ========================================

-- 场景：用户信息实时更新，保留最新的记录
CREATE DATABASE IF NOT EXISTS update_examples;

-- 创建用户信息表（ReplicatedReplacingMergeTree - 生产环境：使用复制引擎 + ON CLUSTER）
CREATE TABLE IF NOT EXISTS update_examples.user_profile_replacing ON CLUSTER 'treasurycluster' (
    user_id UInt64,
    name String,
    email String,
    status UInt8,  -- 0: inactive, 1: active
    updated_at DateTime DEFAULT now(),
    version UInt64 DEFAULT 1
) ENGINE = ReplicatedReplacingMergeTree(updated_at, version)
ORDER BY user_id;

-- 插入初始数据
INSERT INTO update_examples.user_profile_replacing VALUES
(1, 'Alice', 'alice@example.com', 1, '2024-01-01 10:00:00', 1),
(2, 'Bob', 'bob@example.com', 1, '2024-01-01 10:00:00', 1),
(3, 'Charlie', 'charlie@example.com', 1, '2024-01-01 10:00:00', 1);

-- 查询数据
SELECT * FROM update_examples.user_profile_replacing ORDER BY user_id;

-- 更新 Alice 的信息（插入新记录）
INSERT INTO update_examples.user_profile_replacing VALUES
(1, 'Alice Smith', 'alice.new@example.com', 1, '2024-01-01 11:00:00', 2);

-- 不带 FINAL 查询 - 可以看到重复数据
SELECT * FROM update_examples.user_profile_replacing WHERE user_id = 1;

-- 带 FINAL 查询 - 自动去重，保留最新记录
SELECT * FROM update_examples.user_profile_replacing FINAL WHERE user_id = 1;

-- 优化建议：使用 OPTIMIZE TABLE 触发合并
OPTIMIZE TABLE update_examples.user_profile_replacing FINAL;

-- ========================================
-- 2. ReplicatedCollapsingMergeTree - 增量更新和软删除
-- ========================================

-- 场景：电商订单状态变化（新增/修改/删除，生产环境：使用复制引擎 + ON CLUSTER）
CREATE TABLE IF NOT EXISTS update_examples.order_collapsing ON CLUSTER 'treasurycluster' (
    order_id UInt64,
    product_name String,
    quantity UInt32,
    price Decimal(10, 2),
    sign Int8,  -- +1: 新增/更新, -1: 删除
    created_at DateTime DEFAULT now()
) ENGINE = ReplicatedCollapsingMergeTree(sign)
ORDER BY order_id;

-- 订单 1: 下单
INSERT INTO update_examples.order_collapsing (order_id, product_name, quantity, price, sign, created_at)
VALUES (1, 'Laptop', 1, 999.99, 1, '2024-01-01 10:00:00');

-- 订单 2: 下单
INSERT INTO update_examples.order_collapsing (order_id, product_name, quantity, price, sign, created_at)
VALUES (2, 'Mouse', 2, 25.50, 1, '2024-01-01 10:05:00');

-- 查看原始数据
SELECT * FROM update_examples.order_collapsing ORDER BY order_id;

-- 订单 1: 修改（先删除旧记录，再插入新记录）
INSERT INTO update_examples.order_collapsing (order_id, product_name, quantity, price, sign, created_at)
VALUES (1, 'Laptop', 1, 899.99, -1, '2024-01-01 10:10:00'),  -- 删除旧价格
       (1, 'Laptop Pro', 1, 899.99, 1, '2024-01-01 10:10:00'); -- 插入新产品和价格

-- 查看原始数据（包含删除记录）
SELECT * FROM update_examples.order_collapsing WHERE order_id = 1 ORDER BY created_at;

-- 查询有效订单（使用 FINAL 自动折叠）
SELECT * FROM update_examples.order_collapsing FINAL ORDER BY order_id;

-- 订单 2: 取消
INSERT INTO update_examples.order_collapsing (order_id, product_name, quantity, price, sign, created_at)
VALUES (2, 'Mouse', 2, 25.50, -1, '2024-01-01 10:15:00');

-- 查询所有有效订单（订单 2 应该消失）
SELECT * FROM update_examples.order_collapsing FINAL ORDER BY order_id;

-- ========================================
-- 3. ReplicatedVersionedCollapsingMergeTree - 带版本控制的更新
-- ========================================

-- 场景：需要精确控制版本的库存管理（生产环境：使用复制引擎 + ON CLUSTER）
CREATE TABLE IF NOT EXISTS update_examples.inventory_versioned ON CLUSTER 'treasurycluster' (
    product_id UInt64,
    product_name String,
    quantity UInt32,
    version UInt64,
    sign Int8,
    updated_at DateTime DEFAULT now()
) ENGINE = ReplicatedVersionedCollapsingMergeTree(sign, version)
ORDER BY (product_id, version);

-- 插入产品 100，数量 50
INSERT INTO update_examples.inventory_versioned VALUES
(100, 'Product A', 50, 1, 1, '2024-01-01 10:00:00');

-- 查看数据
SELECT * FROM update_examples.inventory_versioned FINAL;

-- 更新产品 100，数量改为 60
INSERT INTO update_examples.inventory_versioned VALUES
(100, 'Product A', 50, 1, -1, '2024-01-01 11:00:00'),  -- 删除版本 1
       (100, 'Product A', 60, 2, 1, '2024-01-01 11:00:00');  -- 插入版本 2

-- 查询当前有效数据（应该是数量 60）
SELECT * FROM update_examples.inventory_versioned FINAL WHERE product_id = 100;

-- 再次更新到数量 55
INSERT INTO update_examples.inventory_versioned VALUES
(100, 'Product A', 60, 2, -1, '2024-01-01 12:00:00'),
       (100, 'Product A', 55, 3, 1, '2024-01-01 12:00:00');

-- 查询最终数据（应该是数量 55）
SELECT * FROM update_examples.inventory_versioned FINAL WHERE product_id = 100;

-- ========================================
-- 4. Mutation - 直接更新和删除
-- ========================================

-- 创建测试表（生产环境：使用复制引擎 + ON CLUSTER）
CREATE TABLE IF NOT EXISTS update_examples.products ON CLUSTER 'treasurycluster' (
    product_id UInt64,
    product_name String,
    price Decimal(10, 2),
    stock UInt32,
    category String
) ENGINE = ReplicatedMergeTree
PARTITION BY category
ORDER BY product_id;

-- 插入测试数据
INSERT INTO update_examples.products VALUES
(1, 'Product 1', 10.00, 100, 'Category A'),
(2, 'Product 2', 20.00, 200, 'Category A'),
(3, 'Product 3', 30.00, 300, 'Category B'),
(4, 'Product 4', 40.00, 400, 'Category B'),
(5, 'Product 5', 50.00, 500, 'Category C');

-- 查看原始数据
SELECT * FROM update_examples.products ORDER BY product_id;

-- 场景 1: 批量更新价格（Mutation 操作）
ALTER TABLE update_examples.products UPDATE price = price * 1.1 WHERE category = 'Category A';

-- 注意：Mutation 是异步执行的，不会立即生效
-- 可以查看 Mutation 队列
SELECT * FROM system.mutations WHERE table = 'products' AND database = 'update_examples';

-- 等待 Mutation 完成
SYSTEM STOP MERGES update_examples.products;
SYSTEM START MERGES update_examples.products;

-- 查询更新后的数据
SELECT * FROM update_examples.products WHERE category = 'Category A' ORDER BY product_id;

-- 场景 2: 删除特定产品
ALTER TABLE update_examples.products DELETE WHERE product_id = 3;

-- 查看删除后的数据（product_id = 3 应该被删除）
SELECT * FROM update_examples.products ORDER BY product_id;

-- 场景 3: 批量更新库存
ALTER TABLE update_examples.products UPDATE stock = stock - 50 WHERE category = 'Category B';

-- 等待 Mutation 完成后查询
SELECT * FROM update_examples.products WHERE category = 'Category B' ORDER BY product_id;

-- ========================================
-- 5. Lightweight DELETE (轻量删除) - 新特性
-- ========================================

-- 创建表（使用 Lightweight DELETE，生产环境：使用复制引擎 + ON CLUSTER）
CREATE TABLE IF NOT EXISTS update_examples.events ON CLUSTER 'treasurycluster' (
    event_id UInt64,
    event_name String,
    event_time DateTime,
    user_id UInt64
) ENGINE = ReplicatedMergeTree
ORDER BY event_time
SETTINGS allow_lightweight_delete = 1;

-- 插入事件数据
INSERT INTO update_examples.events VALUES
(1, 'Login', '2024-01-01 10:00:00', 100),
(2, 'Logout', '2024-01-01 10:05:00', 100),
(3, 'Login', '2024-01-01 10:10:00', 101),
(4, 'Logout', '2024-01-01 10:15:00', 101),
(5, 'Error', '2024-01-01 10:20:00', 102);

-- 查看数据
SELECT * FROM update_examples.events ORDER BY event_id;

-- 使用 Lightweight DELETE 删除特定事件
DELETE FROM update_examples.events WHERE event_id = 3;

-- Lightweight DELETE 比 ALTER DELETE 更快，立即生效
SELECT * FROM update_examples.events ORDER BY event_id;

-- 批量删除
DELETE FROM update_examples.events WHERE user_id = 100;

-- 查询结果（user_id = 100 的记录应该被删除）
SELECT * FROM update_examples.events ORDER BY event_id;

-- ========================================
-- 6. 实时数据插入 - 异步插入
-- ========================================

-- 创建实时日志表（使用异步插入，生产环境：使用复制引擎 + ON CLUSTER）
CREATE TABLE IF NOT EXISTS update_examples.realtime_logs ON CLUSTER 'treasurycluster' (
    log_id UInt64,
    log_level String,
    message String,
    timestamp DateTime DEFAULT now(),
    service_name String
) ENGINE = ReplicatedMergeTree
PARTITION BY toYYYYMM(timestamp)
ORDER BY (service_name, timestamp)
SETTINGS async_insert = 1,          -- 启用异步插入
           async_insert_max_data_size = 1000000,
           async_insert_busy_timeout_ms = 1000,
           wait_for_async_insert = 0;    -- 不等待异步插入完成

-- 模拟实时日志插入（异步插入会更快）
INSERT INTO update_examples.realtime_logs VALUES
(1, 'INFO', 'Service started', '2024-01-01 10:00:00', 'auth-service'),
(2, 'INFO', 'User logged in', '2024-01-01 10:01:00', 'auth-service'),
(3, 'ERROR', 'Connection failed', '2024-01-01 10:02:00', 'db-service'),
(4, 'INFO', 'Connection established', '2024-01-01 10:03:00', 'db-service'),
(5, 'INFO', 'Request processed', '2024-01-01 10:04:00', 'api-service');

-- 异步插入可能不会立即返回数据
SELECT * FROM update_examples.realtime_logs ORDER BY timestamp;

-- ========================================
-- 7. TTL - 自动删除过期数据
-- ========================================

-- 创建带 TTL 的会话表（生产环境：使用复制引擎 + ON CLUSTER）
CREATE TABLE IF NOT EXISTS update_examples.sessions ON CLUSTER 'treasurycluster' (
    session_id String,
    user_id UInt64,
    login_time DateTime,
    last_activity DateTime DEFAULT now(),
    data String
) ENGINE = ReplicatedMergeTree
PARTITION BY user_id
ORDER BY (user_id, session_id)
TTL last_activity + INTERVAL 30 DAY  -- 30 天后自动删除

-- 注意：如果未配置卷，TTL 只会删除数据

-- 插入会话数据
INSERT INTO update_examples.sessions VALUES
('session-001', 1, '2024-01-01 10:00:00', '2024-01-01 10:00:00', 'data1'),
('session-002', 2, '2024-01-01 10:00:00', '2024-01-01 10:00:00', 'data2');

-- 查看数据
SELECT * FROM update_examples.sessions;

-- 查看表的 TTL 信息
SELECT
    name,
    engine,
    ttl_table.table as ttl_target,
    ttl_table.min,
    ttl_table.max
FROM system.tables
CROSS JOIN system.ttl_table
WHERE system.tables.database = 'update_examples'
  AND system.tables.name = 'sessions';

-- ========================================
-- 8. 分区级删除和更新
-- ========================================

-- 创建按月分区的订单表（生产环境：使用复制引擎 + ON CLUSTER）
CREATE TABLE IF NOT EXISTS update_examples.orders_partitioned ON CLUSTER 'treasurycluster' (
    order_id UInt64,
    user_id UInt64,
    amount Decimal(10, 2),
    order_date Date,
    status String
) ENGINE = ReplicatedMergeTree
PARTITION BY toYYYYMM(order_date)
ORDER BY order_id;

-- 插入多个月的数据
INSERT INTO update_examples.orders_partitioned VALUES
(1, 1, 100.00, '2024-01-15', 'completed'),
(2, 2, 200.00, '2024-01-20', 'completed'),
(3, 3, 300.00, '2024-02-10', 'completed'),
(4, 4, 400.00, '2024-02-15', 'completed'),
(5, 5, 500.00, '2024-03-10', 'completed');

-- 查看分区信息
SELECT
    partition,
    name,
    rows,
    bytes_on_disk
FROM system.parts
WHERE table = 'orders_partitioned'
  AND database = 'update_examples'
  AND active
ORDER BY partition;

-- 删除特定分区（2024年1月的数据）
ALTER TABLE update_examples.orders_partitioned DROP PARTITION '202401';

-- 查看删除后的数据（1月数据应该消失）
SELECT * FROM update_examples.orders_partitioned ORDER BY order_date;

-- 替换分区（需要先创建另一个表，生产环境：使用复制引擎 + ON CLUSTER）
CREATE TABLE IF NOT EXISTS update_examples.orders_partitioned_new ON CLUSTER 'treasurycluster' AS update_examples.orders_partitioned
ENGINE = ReplicatedMergeTree
PARTITION BY toYYYYMM(order_date)
ORDER BY order_id;

INSERT INTO update_examples.orders_partitioned_new VALUES
(6, 6, 600.00, '2024-04-01', 'pending'),
(7, 7, 700.00, '2024-04-02', 'pending');

-- 使用 ATTACH PARTITION 交换分区
ALTER TABLE update_examples.orders_partitioned ATTACH PARTITION '202404' 
FROM update_examples.orders_partitioned_new;

-- ========================================
-- 9. 实时聚合 - 物化视图
-- ========================================

-- 创建原始事件表（生产环境：使用复制引擎 + ON CLUSTER）
CREATE TABLE IF NOT EXISTS update_examples.events_raw ON CLUSTER 'treasurycluster' (
    event_id UInt64,
    user_id UInt64,
    event_type String,
    event_value UInt32,
    event_time DateTime DEFAULT now()
) ENGINE = ReplicatedMergeTree
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_time, event_id);

-- 创建物化视图，实时聚合事件（生产环境：使用复制聚合引擎 + ON CLUSTER）
CREATE MATERIALIZED VIEW IF NOT EXISTS update_examples.events_stats ON CLUSTER 'treasurycluster'
ENGINE = ReplicatedSummingMergeTree
ORDER BY (toStartOfMinute(event_time), event_type)
AS SELECT
    toStartOfMinute(event_time) as minute,
    event_type,
    sum(event_value) as total_value,
    count() as event_count
FROM update_examples.events_raw
GROUP BY minute, event_type;

-- 插入事件数据
INSERT INTO update_examples.events_raw VALUES
(1, 1, 'click', 1, '2024-01-01 10:00:10'),
(2, 1, 'click', 1, '2024-01-01 10:00:20'),
(3, 2, 'click', 1, '2024-01-01 10:00:30'),
(4, 1, 'view', 1, '2024-01-01 10:00:40'),
(5, 2, 'view', 1, '2024-01-01 10:00:50');

-- 物化视图会自动更新
SELECT * FROM update_examples.events_stats ORDER BY minute, event_type;

-- 继续插入数据，物化视图实时更新
INSERT INTO update_examples.events_raw VALUES
(6, 3, 'click', 1, '2024-01-01 10:01:10'),
(7, 3, 'click', 1, '2024-01-01 10:01:20'),
(8, 4, 'purchase', 100, '2024-01-01 10:01:30');

-- 查看更新后的聚合数据
SELECT * FROM update_examples.events_stats ORDER BY minute, event_type;

-- ========================================
-- 10. 窗口函数 - 实时数据分析
-- ========================================

-- 创建用户活动表（生产环境：使用复制引擎 + ON CLUSTER）
CREATE TABLE IF NOT EXISTS update_examples.user_activities ON CLUSTER 'treasurycluster' (
    user_id UInt64,
    activity_type String,
    activity_time DateTime,
    duration_sec UInt32
) ENGINE = ReplicatedMergeTree
PARTITION BY toYYYYMM(activity_time)
ORDER BY (user_id, activity_time);

-- 插入用户活动数据
INSERT INTO update_examples.user_activities VALUES
(1, 'login', '2024-01-01 10:00:00', 0),
(1, 'view', '2024-01-01 10:01:00', 60),
(1, 'purchase', '2024-01-01 10:05:00', 120),
(1, 'logout', '2024-01-01 10:10:00', 0),
(2, 'login', '2024-01-01 10:00:00', 0),
(2, 'view', '2024-01-01 10:02:00', 30),
(2, 'purchase', '2024-01-01 10:04:00', 90),
(2, 'logout', '2024-01-01 10:08:00', 0);

-- 使用窗口函数计算累计活动时长
SELECT
    user_id,
    activity_type,
    activity_time,
    duration_sec,
    sum(duration_sec) OVER (
        PARTITION BY user_id
        ORDER BY activity_time
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) as cumulative_duration
FROM update_examples.user_activities
ORDER BY user_id, activity_time;

-- 使用窗口函数查找用户的第一个和最后一个活动
SELECT DISTINCT
    user_id,
    first_value(activity_type) OVER (
        PARTITION BY user_id
        ORDER BY activity_time
        ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
    ) as first_activity,
    last_value(activity_type) OVER (
        PARTITION BY user_id
        ORDER BY activity_time
        ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
    ) as last_activity,
    dateDiff('second',
        min(activity_time) OVER (PARTITION BY user_id),
        max(activity_time) OVER (PARTITION BY user_id)
    ) as total_session_seconds
FROM update_examples.user_activities
ORDER BY user_id;

-- ========================================
-- 11. 批量插入优化
-- ========================================

-- 创建测试表（生产环境：使用复制引擎 + ON CLUSTER）
CREATE TABLE IF NOT EXISTS update_examples.batch_insert_test ON CLUSTER 'treasurycluster' (
    id UInt64,
    data String,
    created_at DateTime DEFAULT now()
) ENGINE = ReplicatedMergeTree
ORDER BY id
SETTINGS max_insert_block_size = 1048576,  -- 块大小
           min_insert_block_size_rows = 1048576,  -- 最小行数
           min_insert_block_size_bytes = 268435456;  -- 最小字节数

-- 批量插入测试（使用 SELECT 生成数据）
INSERT INTO update_examples.batch_insert_test
SELECT
    number as id,
    concat('data-', toString(number)) as data,
    now() as created_at
FROM numbers(100000);  -- 插入 10 万行

-- 查看插入的数据量
SELECT count() FROM update_examples.batch_insert_test;

-- 查看插入性能
SELECT
    table,
    formatReadableSize(sum(bytes_on_disk)) as disk_size,
    sum(rows) as total_rows,
    formatReadableSize(avg(data_uncompressed_bytes)) as avg_row_size
FROM system.parts
WHERE table = 'batch_insert_test'
  AND database = 'update_examples'
  AND active
GROUP BY table;

-- ========================================
-- 12. Stream 插入（使用 HTTP 流式接口）
-- ========================================

-- 创建流数据表（生产环境：使用复制引擎 + ON CLUSTER）
CREATE TABLE IF NOT EXISTS update_examples.stream_data ON CLUSTER 'treasurycluster' (
    event_id UInt64,
    event_name String,
    event_time DateTime DEFAULT now()
) ENGINE = ReplicatedMergeTree
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_time, event_id);

-- 注意：实际使用中，可以通过 HTTP 接口流式插入数据
-- 示例：curl -XPOST http://localhost:8123/?query=INSERT+INTO+stream_data+FORMAT+JSONEachRow --data-binary @data.json

-- 模拟流式插入（多次小批量）
INSERT INTO update_examples.stream_data VALUES
(1, 'event1', '2024-01-01 10:00:00'),
(2, 'event2', '2024-01-01 10:00:01');

INSERT INTO update_examples.stream_data VALUES
(3, 'event3', '2024-01-01 10:00:02'),
(4, 'event4', '2024-01-01 10:00:03');

INSERT INTO update_examples.stream_data VALUES
(5, 'event5', '2024-01-01 10:00:04'),
(6, 'event6', '2024-01-01 10:00:05');

-- 查询所有流数据
SELECT * FROM update_examples.stream_data ORDER BY event_time;

-- ========================================
-- 13. 数据更新最佳实践总结
-- ========================================

-- 总结不同场景下的更新方案：

/*
1. 实时更新用户信息
   - 使用 ReplacingMergeTree
   - ORDER BY (user_id)
   - 使用 FINAL 查询或定期 OPTIMIZE
   - 适合：用户资料、配置信息

2. 增量更新（新增/修改/删除）
   - 使用 CollapsingMergeTree
   - 需要 sign 字段（+1/-1）
   - 适合：订单状态、库存管理

3. 带版本控制的更新
   - 使用 VersionedCollapsingMergeTree
   - 需要 sign 和 version 字段
   - 适合：需要精确版本控制的场景

4. 批量更新
   - 使用 ALTER TABLE UPDATE
   - Mutation 操作是异步的
   - 适合：大批量数据修正

5. 快速删除
   - 使用 Lightweight DELETE
   - 需要设置 allow_lightweight_delete = 1
   - 适合：少量数据删除

6. 自动过期数据
   - 使用 TTL
   - 可以设置数据生命周期
   - 适合：日志、会话、临时数据

7. 分区级删除
   - 使用 ALTER TABLE DROP PARTITION
   - 最快的批量删除方式
   - 适合：按时间分区的历史数据

8. 实时聚合
   - 使用物化视图
   - 自动聚合，无需手动触发
   - 适合：实时统计、仪表板

9. 高性能插入
   - 使用异步插入（async_insert）
   - 批量插入优于单条插入
   - 适合：高频日志写入

10. 流式处理
    - 使用 Stream 接口
    - 持续小批量插入
    - 适合：实时事件流
*/

-- ========================================
-- 14. 性能对比测试
-- ========================================

-- 创建三个表，使用不同的复制引擎（生产环境：使用复制引擎 + ON CLUSTER）
CREATE TABLE IF NOT EXISTS update_examples.update_test_replacing ON CLUSTER 'treasurycluster' (
    id UInt64,
    value String,
    version UInt64,
    updated_at DateTime DEFAULT now()
) ENGINE = ReplicatedReplacingMergeTree(version)
ORDER BY id;

CREATE TABLE IF NOT EXISTS update_examples.update_test_collapsing ON CLUSTER 'treasurycluster' (
    id UInt64,
    value String,
    sign Int8,
    updated_at DateTime DEFAULT now()
) ENGINE = ReplicatedCollapsingMergeTree(sign)
ORDER BY id;

CREATE TABLE IF NOT EXISTS update_examples.update_test_mutation ON CLUSTER 'treasurycluster' (
    id UInt64,
    value String,
    updated_at DateTime DEFAULT now()
) ENGINE = ReplicatedMergeTree
ORDER BY id;

-- 插入初始数据
INSERT INTO update_examples.update_test_replacing SELECT
    number as id,
    concat('value-', toString(number)) as value,
    1 as version,
    now() as updated_at
FROM numbers(1000);

INSERT INTO update_examples.update_test_collapsing SELECT
    number as id,
    concat('value-', toString(number)) as value,
    1 as sign,
    now() as updated_at
FROM numbers(1000);

INSERT INTO update_examples.update_test_mutation SELECT
    number as id,
    concat('value-', toString(number)) as value,
    now() as updated_at
FROM numbers(1000);

-- 更新前 100 行数据（不同方式）
-- ReplacingMergeTree: 插入新记录
INSERT INTO update_examples.update_test_replacing SELECT
    number as id,
    concat('updated-', toString(number)) as value,
    2 as version,
    now() as updated_at
FROM numbers(100);

-- CollapsingMergeTree: 先删除再插入
INSERT INTO update_examples.update_test_collapsing SELECT
    number as id,
    concat('value-', toString(number)) as value,
    -1 as sign,
    now() as updated_at
FROM numbers(100);

INSERT INTO update_examples.update_test_collapsing SELECT
    number as id,
    concat('updated-', toString(number)) as value,
    1 as sign,
    now() as updated_at
FROM numbers(100);

-- Mutation: ALTER UPDATE
ALTER TABLE update_examples.update_test_mutation
UPDATE value = concat('updated-', toString(id))
WHERE id < 100;

-- 查询结果对比
SELECT 'ReplacingMergeTree' as engine, count() as count, countDistinct(id) as distinct_ids
FROM update_examples.update_test_replacing FINAL

UNION ALL

SELECT 'CollapsingMergeTree', count(), countDistinct(id)
FROM update_examples.update_test_collapsing FINAL

UNION ALL

SELECT 'Mutation', count(), countDistinct(id)
FROM update_examples.update_test_mutation;

-- ========================================
-- 15. 清理测试数据（生产环境：使用 ON CLUSTER SYNC 确保集群范围删除）
-- ========================================

DROP TABLE IF EXISTS update_examples.user_profile_replacing ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS update_examples.order_collapsing ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS update_examples.inventory_versioned ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS update_examples.products ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS update_examples.events ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS update_examples.realtime_logs ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS update_examples.sessions ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS update_examples.orders_partitioned ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS update_examples.orders_partitioned_new ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS update_examples.events_raw ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS update_examples.events_stats ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS update_examples.user_activities ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS update_examples.batch_insert_test ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS update_examples.stream_data ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS update_examples.update_test_replacing ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS update_examples.update_test_collapsing ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS update_examples.update_test_mutation ON CLUSTER 'treasurycluster' SYNC;

DROP DATABASE IF EXISTS update_examples ON CLUSTER 'treasurycluster' SYNC;
