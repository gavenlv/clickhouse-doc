-- ========================================
-- ClickHouse 数据去重与幂等性实战
-- ========================================
-- 目标：解决上游写入一半程序崩溃时，如何保证 ClickHouse 数据不重复
-- ========================================

-- ========================================
-- 场景 1：ReplacingMergeTree - 保留最新版本
-- ========================================
-- 适用场景：用户资料更新、配置信息、状态变更

CREATE DATABASE IF NOT EXISTS dedup_examples ON CLUSTER 'treasurycluster';

-- 创建表（生产环境：使用复制版本 + ON CLUSTER）
CREATE TABLE IF NOT EXISTS dedup_examples.user_profiles ON CLUSTER 'treasurycluster' (
    user_id UInt64,
    profile_id String,       -- 业务唯一ID
    name String,
    email String,
    phone String,
    updated_at DateTime,
    version UInt64,           -- 版本号（必需）
    inserted_at DateTime DEFAULT now()
) ENGINE = ReplicatedReplacingMergeTree(version)  -- version 指定去重字段
PARTITION BY toYYYYMM(updated_at)
ORDER BY (user_id, profile_id)  -- 唯一键
SETTINGS index_granularity = 8192;

-- 插入初始数据（version 1）
INSERT INTO dedup_examples.user_profiles VALUES
(1001, 'prof-001', '张三', 'zhangsan@example.com', '13800000001', '2024-01-01 10:00:00', 1, now()),
(1002, 'prof-002', '李四', 'lisi@example.com', '13800000002', '2024-01-01 10:00:00', 1, now()),
(1003, 'prof-003', '王五', 'wangwu@example.com', '13800000003', '2024-01-01 10:00:00', 1, now());

-- 模拟程序崩溃：重复插入相同的数据
-- 即使重复插入，也不会产生重复数据（相同的 profile_id + version）
INSERT INTO dedup_examples.user_profiles VALUES
(1001, 'prof-001', '张三', 'zhangsan@example.com', '13800000001', '2024-01-01 10:00:00', 1, now()),
(1002, 'prof-002', '李四', 'lisi@example.com', '13800000002', '2024-01-01 10:00:00', 1, now()),
(1003, 'prof-003', '王五', 'wangwu@example.com', '13800000003', '2024-01-01 10:00:00', 1, now());

-- 查询原始数据（可能看到重复）
SELECT * FROM dedup_examples.user_profiles
ORDER BY user_id, profile_id, version;

-- 查询去重后的数据（使用 argMax 手动去重 - 推荐）
SELECT
    user_id,
    profile_id,
    argMax(name, version) as name,
    argMax(email, version) as email,
    argMax(phone, version) as phone,
    argMax(updated_at, version) as updated_at,
    max(version) as latest_version
FROM dedup_examples.user_profiles
GROUP BY user_id, profile_id
ORDER BY user_id;

-- 更新用户资料（version 2）
INSERT INTO dedup_examples.user_profiles VALUES
(1001, 'prof-001', '张三丰', 'zhangsanfeng@example.com', '13800000011', '2024-01-01 11:00:00', 2, now()),
(1002, 'prof-002', '李四光', 'lisiguang@example.com', '13800000012', '2024-01-01 11:00:00', 2, now());

-- 再次查询去重后的数据（应该看到更新的资料）
SELECT
    user_id,
    profile_id,
    argMax(name, version) as name,
    argMax(email, version) as email,
    max(version) as latest_version
FROM dedup_examples.user_profiles
GROUP BY user_id, profile_id
ORDER BY user_id;

-- 使用 FINAL 关键字查询（自动去重，但性能较差）
SELECT * FROM dedup_examples.user_profiles FINAL
ORDER BY user_id;

-- 手动触发合并
OPTIMIZE TABLE dedup_examples.user_profiles FINAL;

-- 再次查询（已合并，无重复）
SELECT * FROM dedup_examples.user_profiles
ORDER BY user_id, version;

-- ========================================
-- 场景 2：CollapsingMergeTree - 增量更新
-- ========================================
-- 适用场景：库存管理、订单状态、增量计数器

CREATE TABLE IF NOT EXISTS dedup_examples.inventory ON CLUSTER 'treasurycluster' (
    product_id UInt64,
    product_name String,
    quantity Int32,
    sign Int8,               -- 1 for insert, -1 for delete（必需）
    timestamp DateTime,
    inserted_at DateTime DEFAULT now()
) ENGINE = ReplicatedCollapsingMergeTree(sign)  -- sign 指定字段
PARTITION BY toYYYYMM(timestamp)
ORDER BY product_id
SETTINGS index_granularity = 8192;

-- 初始化库存（sign = 1）
INSERT INTO dedup_examples.inventory VALUES
(101, '产品A', 100, 1, '2024-01-01 10:00:00', now()),
(102, '产品B', 50, 1, '2024-01-01 10:00:00', now()),
(103, '产品C', 75, 1, '2024-01-01 10:00:00', now());

-- 销售商品（sign = -1）
-- 如果程序崩溃，重试时再次执行，结果也是正确的
INSERT INTO dedup_examples.inventory VALUES
(101, '产品A', 10, -1, '2024-01-01 11:00:00', now()),
(102, '产品B', 5, -1, '2024-01-01 11:00:00', now());

-- 再次销售（如果重复执行，库存会减少两次 - 需要业务层保证幂等性）
-- 解决方案：使用 VersionedCollapsingMergeTree 或应用层去重

-- 进货（sign = 1）
INSERT INTO dedup_examples.inventory VALUES
(101, '产品A', 20, 1, '2024-01-01 12:00:00', now()),
(103, '产品C', 10, 1, '2024-01-01 12:00:00', now());

-- 查询当前库存（使用 GROUP BY 抵消 sign）
SELECT
    product_id,
    argMax(product_name, timestamp) as product_name,
    sum(quantity * sign) as current_inventory,
    max(timestamp) as last_updated
FROM dedup_examples.inventory
GROUP BY product_id
ORDER BY product_id;

-- 使用 FINAL 查询
SELECT * FROM dedup_examples.inventory FINAL
ORDER BY product_id, timestamp;

-- ========================================
-- 场景 3：VersionedCollapsingMergeTree - 严格版本控制
-- ========================================
-- 适用场景：金融交易、库存精确管理、需要严格版本控制的场景

CREATE TABLE IF NOT EXISTS dedup_examples.financial_transactions ON CLUSTER 'treasurycluster' (
    transaction_id String,
    account_id UInt64,
    amount Decimal(10, 2),
    balance_before Decimal(10, 2),
    balance_after Decimal(10, 2),
    sign Int8,                -- 1 for insert, -1 for delete（必需）
    version UInt64,           -- 版本号（必需）
    timestamp DateTime,
    inserted_at DateTime DEFAULT now()
) ENGINE = ReplicatedVersionedCollapsingMergeTree(sign, version)
PARTITION BY toYYYYMM(timestamp)
ORDER BY (transaction_id, account_id)
SETTINGS index_granularity = 8192;

-- 初始化账户余额（version 1）
INSERT INTO dedup_examples.financial_transactions VALUES
('txn-001', 1001, 1000.00, 0.00, 1000.00, 1, 1, '2024-01-01 10:00:00', now()),
('txn-002', 1002, 500.00, 0.00, 500.00, 1, 1, '2024-01-01 10:00:00', now());

-- 转账（version 2）
-- 先删除旧余额（version 1），再插入新余额（version 2）
INSERT INTO dedup_examples.financial_transactions VALUES
('txn-003', 1001, 100.00, 1000.00, 900.00, 1, 2, '2024-01-01 11:00:00', now()),  -- 转出
('txn-004', 1002, 100.00, 500.00, 600.00, 1, 2, '2024-01-01 11:00:00', now());  -- 转入

-- 再次转账（version 3）
-- 即使重复执行 version 2 的操作，也不会产生影响（因为 version 2 已经被处理）
INSERT INTO dedup_examples.financial_transactions VALUES
('txn-003', 1001, 100.00, 1000.00, 900.00, 1, 2, '2024-01-01 11:00:00', now()),  -- 重复，不影响
('txn-004', 1002, 100.00, 500.00, 600.00, 1, 2, '2024-01-01 11:00:00', now());  -- 重复，不影响

INSERT INTO dedup_examples.financial_transactions VALUES
('txn-005', 1001, 50.00, 900.00, 850.00, 1, 3, '2024-01-01 12:00:00', now()),  -- 转出
('txn-006', 1002, 50.00, 600.00, 650.00, 1, 3, '2024-01-01 12:00:00', now());  -- 转入

-- 查询当前余额（使用 sum 抵消 sign，按 version 分组）
SELECT
    account_id,
    sum(balance_after * sign) as current_balance,
    max(version) as latest_version,
    max(timestamp) as last_updated
FROM dedup_examples.financial_transactions
WHERE sign = 1  -- 只看插入记录（sign = 1）
GROUP BY account_id
ORDER BY account_id;

-- 查询所有交易（使用 FINAL）
SELECT * FROM dedup_examples.financial_transactions FINAL
ORDER BY account_id, version, timestamp;

-- ========================================
-- 场景 4：应用层去重 - INSERT SELECT DISTINCT
-- ========================================
-- 适用场景：临时去重、批量导入

CREATE TABLE IF NOT EXISTS dedup_examples.raw_events ON CLUSTER 'treasurycluster' (
    event_id String,
    user_id UInt64,
    event_type String,
    event_data String,
    event_time DateTime
) ENGINE = ReplicatedMergeTree
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_id, event_time)
SETTINGS index_granularity = 8192;

-- 目标表
CREATE TABLE IF NOT EXISTS dedup_examples.events ON CLUSTER 'treasurycluster' (
    event_id String,
    user_id UInt64,
    event_type String,
    event_data String,
    event_time DateTime,
    inserted_at DateTime DEFAULT now()
) ENGINE = ReplicatedMergeTree
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_id, event_time)
SETTINGS index_granularity = 8192;

-- 插入原始数据（可能包含重复）
INSERT INTO dedup_examples.raw_events VALUES
('evt-001', 1001, 'click', '{"page":"/home"}', '2024-01-01 10:00:00'),
('evt-002', 1001, 'view', '{"page":"/about"}', '2024-01-01 10:01:00'),
('evt-001', 1001, 'click', '{"page":"/home"}', '2024-01-01 10:00:00'),  -- 重复
('evt-003', 1002, 'click', '{"page":"/home"}', '2024-01-01 10:02:00'),
('evt-002', 1001, 'view', '{"page":"/about"}', '2024-01-01 10:01:00');  -- 重复

-- 查询原始数据（包含重复）
SELECT count() as total_rows FROM dedup_examples.raw_events;
SELECT count(DISTINCT event_id) as unique_events FROM dedup_examples.raw_events;

-- 去重后插入目标表
INSERT INTO dedup_examples.events
SELECT DISTINCT * FROM dedup_examples.raw_events;

-- 验证目标表（无重复）
SELECT count() as total_rows FROM dedup_examples.events;
SELECT count(DISTINCT event_id) as unique_events FROM dedup_examples.events;

-- 查询结果
SELECT * FROM dedup_examples.events ORDER BY event_time;

-- ========================================
-- 场景 5：应用层去重 - 临时表
-- ========================================

-- 创建临时表
CREATE TEMPORARY TABLE temp_events AS dedup_examples.events;

-- 插入数据（可能包含重复）
INSERT INTO temp_events VALUES
('evt-004', 1001, 'purchase', '{"product_id":101}', '2024-01-01 10:03:00'),
('evt-005', 1002, 'purchase', '{"product_id":102}', '2024-01-01 10:04:00'),
('evt-004', 1001, 'purchase', '{"product_id":101}', '2024-01-01 10:03:00');  -- 重复

-- 去重后插入目标表
INSERT INTO dedup_examples.events
SELECT DISTINCT * FROM temp_events;

-- 验证
SELECT * FROM dedup_examples.events WHERE event_id IN ('evt-004', 'evt-005');

-- ========================================
-- 场景 6：幂等性写入 - 电商订单
-- ========================================
-- 场景：订单创建时，如果写到一半程序崩溃，重试时不会产生重复订单

CREATE TABLE IF NOT EXISTS dedup_examples.orders ON CLUSTER 'treasurycluster' (
    order_id String,          -- 业务唯一ID
    user_id UInt64,
    order_status Enum8('pending' = 0, 'paid' = 1, 'shipped' = 2, 'completed' = 3, 'cancelled' = 4),
    amount Decimal(10, 2),
    created_at DateTime,
    version UInt64,           -- 版本号
    inserted_at DateTime DEFAULT now()
) ENGINE = ReplicatedReplacingMergeTree(version)
PARTITION BY toYYYYMM(created_at)
ORDER BY (order_id, user_id)
SETTINGS index_granularity = 8192;

CREATE TABLE IF NOT EXISTS dedup_examples.order_items ON CLUSTER 'treasurycluster' (
    order_id String,
    product_id UInt64,
    quantity Int32,
    price Decimal(10, 2),
    sign Int8,
    version UInt64,
    timestamp DateTime,
    inserted_at DateTime DEFAULT now()
) ENGINE = ReplicatedVersionedCollapsingMergeTree(sign, version)
PARTITION BY toYYYYMM(timestamp)
ORDER BY (order_id, product_id)
SETTINGS index_granularity = 8192;

-- 去重表
CREATE TABLE IF NOT EXISTS dedup_examples.order_dedup ON CLUSTER 'treasurycluster' (
    order_id String,
    processed_at DateTime DEFAULT now()
) ENGINE = ReplicatedMergeTree
ORDER BY order_id
TTL processed_at + INTERVAL 7 DAY  -- 7天后自动删除
SETTINGS index_granularity = 8192;

-- 场景 1：首次创建订单
-- Step 1: 检查订单是否已存在（使用去重表）
SELECT count() FROM dedup_examples.order_dedup WHERE order_id = 'ORD-001';

-- Step 2: 插入订单主表
INSERT INTO dedup_examples.orders VALUES
('ORD-001', 1001, 'paid', 299.99, '2024-01-01 10:00:00', 1, now());

-- Step 3: 插入订单明细
INSERT INTO dedup_examples.order_items VALUES
('ORD-001', 101, 1, 199.99, 1, 1, '2024-01-01 10:00:00', now()),
('ORD-001', 102, 2, 50.00, 1, 1, '2024-01-01 10:00:00', now());

-- Step 4: 插入去重表
INSERT INTO dedup_examples.order_dedup VALUES ('ORD-001', now());

-- 查询订单
SELECT * FROM dedup_examples.orders WHERE order_id = 'ORD-001';

-- 场景 2：重试创建订单（幂等性）
-- Step 1: 检查订单是否已存在
SELECT count() FROM dedup_examples.order_dedup WHERE order_id = 'ORD-001';

-- Step 2: 再次插入订单主表（version 相同，会被去重）
INSERT INTO dedup_examples.orders VALUES
('ORD-001', 1001, 'paid', 299.99, '2024-01-01 10:00:00', 1, now());

-- Step 3: 再次插入订单明细（version 相同，会被抵消）
INSERT INTO dedup_examples.order_items VALUES
('ORD-001', 101, 1, 199.99, 1, 1, '2024-01-01 10:00:00', now()),
('ORD-001', 102, 2, 50.00, 1, 1, '2024-01-01 10:00:00', now());

-- Step 4: 再次插入去重表（已存在，重复插入）
INSERT INTO dedup_examples.order_dedup VALUES ('ORD-001', now());

-- 查询订单（仍然只有一份）
SELECT
    order_id,
    user_id,
    argMax(order_status, version) as order_status,
    argMax(amount, version) as amount,
    max(version) as latest_version
FROM dedup_examples.orders
WHERE order_id = 'ORD-001'
GROUP BY order_id, user_id;

-- 查询订单明细（使用 sum 抵消 sign）
SELECT
    order_id,
    product_id,
    sum(quantity * sign) as quantity,
    argMax(price, version) as price
FROM dedup_examples.order_items
WHERE order_id = 'ORD-001'
GROUP BY order_id, product_id;

-- 场景 3：更新订单（使用新的 version）
-- Step 1: 插入新版本的订单
INSERT INTO dedup_examples.orders VALUES
('ORD-001', 1001, 'shipped', 299.99, '2024-01-01 10:00:00', 2, now());

-- Step 2: 插入新版本的订单明细
INSERT INTO dedup_examples.order_items VALUES
('ORD-001', 101, -1, 199.99, -1, 1, '2024-01-01 10:00:00', now()),  -- 删除 version 1
('ORD-001', 102, -2, 50.00, -1, 1, '2024-01-01 10:00:00', now()),  -- 删除 version 1
('ORD-001', 101, 1, 199.99, 1, 2, '2024-01-01 11:00:00', now()),   -- 插入 version 2
('ORD-001', 102, 2, 50.00, 1, 2, '2024-01-01 11:00:00', now());   -- 插入 version 2

-- 查询更新后的订单
SELECT
    order_id,
    user_id,
    argMax(order_status, version) as order_status,
    max(version) as latest_version
FROM dedup_examples.orders
WHERE order_id = 'ORD-001'
GROUP BY order_id, user_id;

-- ========================================
-- 场景 7：ClickHouse 内置去重 - insert_deduplication_token
-- ========================================
-- 注意：ClickHouse 22.3+ 支持

-- INSERT INTO dedup_examples.events
-- SETTINGS insert_deduplication_token='batch-001' VALUES
-- ('evt-006', 1001, 'click', '{"page":"/home"}', '2024-01-01 10:05:00'),
-- ('evt-007', 1001, 'view', '{"page":"/about"}', '2024-01-01 10:06:00');

-- 重试时使用相同的 token
-- INSERT INTO dedup_examples.events
-- SETTINGS insert_deduplication_token='batch-001' VALUES
-- ('evt-006', 1001, 'click', '{"page":"/home"}', '2024-01-01 10:05:00'),  -- 重复，会被去重
-- ('evt-007', 1001, 'view', '{"page":"/about"}', '2024-01-01 10:06:00');  -- 重复，会被去重

-- ========================================
-- 场景 8：监控去重效果
-- ========================================

-- 统计各表的重复情况
SELECT
    table,
    count() as total_rows,
    sum(rows_uncompressed) as total_bytes,
    formatReadableSize(sum(rows_uncompressed)) as readable_size
FROM system.parts
WHERE database = 'dedup_examples'
  AND active
GROUP BY table;

-- 查看 ReplacingMergeTree 表的未合并数据块
SELECT
    table,
    partition,
    count() as part_count,
    sum(rows) as total_rows
FROM system.parts
WHERE database = 'dedup_examples'
  AND active
  AND table IN ('user_profiles', 'orders')
  AND level > 0  -- level > 0 表示有未合并的数据块
GROUP BY table, partition;

-- 查询用户资料表的重复率
SELECT
    count() as total_rows,
    uniqExact(profile_id) as unique_profiles,
    count() - uniqExact(profile_id) as duplicate_count,
    round((count() - uniqExact(profile_id)) * 100.0 / count(), 2) as duplicate_rate_percent
FROM dedup_examples.user_profiles;

-- ========================================
-- 场景 9：性能对比
-- ========================================

-- 创建测试数据
INSERT INTO dedup_examples.user_profiles
SELECT
    number + 1004 as user_id,
    concat('prof-', toString(number + 1004)) as profile_id,
    concat('用户', toString(number + 1004)) as name,
    concat('user', toString(number + 1004), '@example.com') as email,
    concat('138', toString(number + 1004)) as phone,
    now() as updated_at,
    1 as version,
    now() as inserted_at
FROM numbers(100);

-- 插入重复数据
INSERT INTO dedup_examples.user_profiles
SELECT
    user_id,
    profile_id,
    name,
    email,
    phone,
    updated_at,
    version,
    now() as inserted_at
FROM dedup_examples.user_profiles
WHERE user_id >= 1004 AND user_id < 1104;

-- 性能对比测试
-- 方式 1: 使用 argMax 手动去重（推荐）
SELECT
    user_id,
    profile_id,
    argMax(name, version) as name
FROM dedup_examples.user_profiles
WHERE user_id >= 1004
GROUP BY user_id, profile_id;

-- 方式 2: 使用 FINAL（性能较差）
SELECT * FROM dedup_examples.user_profiles FINAL
WHERE user_id >= 1004
ORDER BY user_id;

-- 方式 3: OPTIMIZE 后查询
OPTIMIZE TABLE dedup_examples.user_profiles FINAL PARTITION '202401';

SELECT * FROM dedup_examples.user_profiles
WHERE user_id >= 1004
ORDER BY user_id;

-- ========================================
-- 场景 10：最佳实践 - 综合示例
-- ========================================

-- 标准生产表结构（推荐）
CREATE TABLE IF NOT EXISTS dedup_examples.standard_events ON CLUSTER 'treasurycluster' (
    event_id String,          -- 业务唯一ID
    user_id UInt64,
    event_type String,
    event_data String,
    event_time DateTime,
    version UInt64,           -- 版本号
    inserted_at DateTime DEFAULT now()
) ENGINE = ReplicatedReplacingMergeTree(version)
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_id, event_time)
SETTINGS index_granularity = 8192;

-- 配合应用层去重
CREATE TABLE IF NOT EXISTS dedup_examples.standard_events_dedup ON CLUSTER 'treasurycluster' (
    event_id String,
    processed_at DateTime DEFAULT now()
) ENGINE = ReplicatedMergeTree
ORDER BY event_id
TTL processed_at + INTERVAL 7 DAY
SETTINGS index_granularity = 8192;

-- 插入流程（模拟）
-- 1. 检查是否已处理
SELECT count() FROM dedup_examples.standard_events_dedup WHERE event_id = 'evt-std-001';

-- 2. 插入事件表
INSERT INTO dedup_examples.standard_events VALUES
('evt-std-001', 1001, 'click', '{"page":"/home"}', '2024-01-01 10:00:00', 1, now());

-- 3. 插入去重表
INSERT INTO dedup_examples.standard_events_dedup VALUES ('evt-std-001', now());

-- 4. 查询事件（使用 argMax 去重）
SELECT
    event_id,
    user_id,
    argMax(event_type, version) as event_type,
    argMax(event_data, version) as event_data,
    argMax(event_time, version) as event_time
FROM dedup_examples.standard_events
WHERE event_id = 'evt-std-001'
GROUP BY event_id, user_id;

-- ========================================
-- 清理测试表
-- ========================================

DROP TABLE IF EXISTS dedup_examples.standard_events_dedup ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS dedup_examples.standard_events ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS dedup_examples.order_dedup ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS dedup_examples.order_items ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS dedup_examples.orders ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS dedup_examples.events ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS dedup_examples.raw_events ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS dedup_examples.financial_transactions ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS dedup_examples.inventory ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS dedup_examples.user_profiles ON CLUSTER 'treasurycluster' SYNC;

DROP DATABASE IF EXISTS dedup_examples ON CLUSTER 'treasurycluster' SYNC;

-- ========================================
-- 总结
-- ========================================
/*
数据去重与幂等性最佳实践：

1. ReplacingMergeTree（推荐用于大多数场景）
   - 简单易用，只需添加 version 字段
   - 自动去重，保留最新版本
   - 适合：用户资料、配置信息、状态变更

2. CollapsingMergeTree（适合增量更新）
   - 使用 sign 字段标记增删
   - 适合：库存管理、订单状态、增量计数器

3. VersionedCollapsingMergeTree（严格版本控制）
   - 在 CollapsingMergeTree 基础上增加 version
   - 适合：金融交易、精确库存管理

4. 应用层去重（最灵活）
   - 配合去重表（Redis/MySQL）
   - 最高准确性
   - 适合：高准确性要求场景

5. 查询策略
   - 使用 argMax 手动去重（性能最佳）
   - 谨慎使用 FINAL（性能较差）
   - 定期 OPTIMIZE（低峰期）

6. 最佳实践
   - 引擎去重 + 应用层去重 = 双重保障
   - 设计唯一键
   - 定期监控去重效果
*/
