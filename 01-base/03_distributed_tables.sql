-- ================================================
-- 03_distributed_tables.sql
-- ClickHouse 分布式表示例
-- ================================================

-- ========================================
-- 1. 查看集群配置
-- ========================================
SELECT
    cluster,
    shard_num,
    replica_num,
    host_name,
    port,
    user
FROM system.clusters
WHERE cluster = 'treasurycluster'
ORDER BY shard_num, replica_num;

-- ========================================
-- 2. 创建复制表（本地表，生产环境：使用复制引擎 + ON CLUSTER）
-- ========================================
-- 注意：先在每个节点上创建本地表

CREATE TABLE IF NOT EXISTS test_local_orders ON CLUSTER 'treasurycluster' (
    order_id UInt64,
    user_id UInt64,
    product_id UInt32,
    amount Decimal(10, 2),
    status String,
    order_date DateTime DEFAULT now()
) ENGINE = ReplicatedMergeTree
PARTITION BY toYYYYMM(order_date)
ORDER BY (user_id, order_id);

-- 验证本地表在两个副本上都创建成功
SELECT
    database,
    table,
    engine,
    replica_name,
    zookeeper_path
FROM system.replicas
WHERE table = 'test_local_orders';

-- ========================================
-- 3. 创建分布式表
-- ========================================
-- 分布式表本身不存储数据，只是提供统一访问接口

CREATE TABLE IF NOT EXISTS test_distributed_orders AS test_local_orders
ENGINE = Distributed(treasurycluster, default, test_local_orders, user_id);

-- 查看分布式表结构
SHOW CREATE test_distributed_orders;

-- ========================================
-- 4. 插入测试数据（通过分布式表）
-- ========================================
-- 数据会根据 sharding key (user_id) 自动分发到不同节点
INSERT INTO test_distributed_orders (order_id, user_id, product_id, amount, status, order_date) VALUES
(1, 101, 1001, 99.99, 'pending', '2024-01-01 10:00:00'),
(2, 102, 1002, 49.99, 'completed', '2024-01-01 11:00:00'),
(3, 103, 1003, 199.99, 'pending', '2024-01-01 12:00:00'),
(4, 104, 1001, 99.99, 'cancelled', '2024-01-01 13:00:00'),
(5, 105, 1004, 149.99, 'completed', '2024-01-01 14:00:00'),
(6, 106, 1005, 79.99, 'pending', '2024-01-02 09:00:00'),
(7, 107, 1002, 49.99, 'completed', '2024-01-02 10:00:00'),
(8, 108, 1006, 299.99, 'pending', '2024-01-02 11:00:00'),
(9, 109, 1003, 199.99, 'cancelled', '2024-01-02 12:00:00'),
(10, 110, 1004, 149.99, 'completed', '2024-01-02 13:00:00');

-- ========================================
-- 5. 查询数据（通过分布式表）
-- ========================================
-- 查询所有订单
SELECT * FROM test_distributed_orders ORDER BY order_id;

-- 统计订单总数
SELECT count() as total_orders FROM test_distributed_orders;

-- 按状态分组统计
SELECT
    status,
    count() as order_count,
    sum(amount) as total_amount,
    avg(amount) as avg_amount
FROM test_distributed_orders
GROUP BY status
ORDER BY order_count DESC;

-- ========================================
-- 6. 对比分布式表和本地表
-- ========================================
-- 从分布式表查询
SELECT 'Distributed table count:' as source, count() as count FROM test_distributed_orders

UNION ALL

-- 从本地表查询（只返回当前节点的数据）
SELECT 'Local table count:' as source, count() as count FROM test_local_orders;

-- 查看数据分布
SELECT
    shard_num,
    replica_num,
    host_name,
    count() as row_count
FROM cluster(treasurycluster, default, test_local_orders, count())
GROUP BY shard_num, replica_num, host_name
ORDER BY shard_num, replica_num;

-- ========================================
-- 7. 测试负载均衡
-- ========================================
-- 查看当前连接的节点
SELECT
    hostName() as current_host,
    version() as version
UNION ALL
-- 连接到另一个节点执行相同查询
SELECT 'ClickHouse2' as current_host, 'N/A' as version;

-- 查询特定用户的数据
-- ClickHouse 会自动路由到数据所在的节点
SELECT
    order_id,
    user_id,
    amount,
    status,
    hostName() as data_from_host
FROM test_distributed_orders
WHERE user_id = 101;

-- ========================================
-- 8. 测试跨分片聚合
-- ========================================
-- 这个查询会在所有分片上执行，然后汇总结果
SELECT
    toDate(order_date) as order_day,
    count() as order_count,
    sum(amount) as total_amount,
    avg(amount) as avg_amount,
    max(amount) as max_amount,
    min(amount) as min_amount
FROM test_distributed_orders
GROUP BY order_day
ORDER BY order_day;

-- ========================================
-- 9. 测试 JOIN 操作
-- ========================================
-- 创建用户表（生产环境：使用复制引擎 + ON CLUSTER）
CREATE TABLE IF NOT EXISTS test_local_users ON CLUSTER 'treasurycluster' (
    user_id UInt64,
    name String,
    email String,
    register_date DateTime
) ENGINE = ReplicatedMergeTree
ORDER BY user_id;

-- 创建分布式用户表
CREATE TABLE IF NOT EXISTS test_distributed_users AS test_local_users
ENGINE = Distributed(treasurycluster, default, test_local_users, user_id);

-- 插入用户数据
INSERT INTO test_distributed_users (user_id, name, email, register_date) VALUES
(101, 'Alice', 'alice@example.com', '2023-12-01 10:00:00'),
(102, 'Bob', 'bob@example.com', '2023-12-02 10:00:00'),
(103, 'Charlie', 'charlie@example.com', '2023-12-03 10:00:00'),
(104, 'David', 'david@example.com', '2023-12-04 10:00:00'),
(105, 'Eve', 'eve@example.com', '2023-12-05 10:00:00'),
(106, 'Frank', 'frank@example.com', '2023-12-06 10:00:00'),
(107, 'Grace', 'grace@example.com', '2023-12-07 10:00:00'),
(108, 'Henry', 'henry@example.com', '2023-12-08 10:00:00'),
(109, 'Ivy', 'ivy@example.com', '2023-12-09 10:00:00'),
(110, 'Jack', 'jack@example.com', '2023-12-10 10:00:00');

-- 执行分布式 JOIN
SELECT
    u.name,
    u.email,
    o.order_id,
    o.amount,
    o.status,
    hostName() as data_from_host
FROM test_distributed_orders o
INNER JOIN test_distributed_users u ON o.user_id = u.user_id
ORDER BY o.order_id;

-- 用户订单统计
SELECT
    u.name,
    u.email,
    count(o.order_id) as order_count,
    sum(o.amount) as total_spent,
    avg(o.amount) as avg_order_amount,
    max(o.amount) as max_order_amount
FROM test_distributed_users u
LEFT JOIN test_distributed_orders o ON u.user_id = o.user_id
GROUP BY u.user_id, u.name, u.email
ORDER BY total_spent DESC;

-- ========================================
-- 10. 测试子查询
-- ========================================
-- 查找订单金额超过平均值的用户
SELECT
    u.name,
    u.email,
    o.amount,
    o.status
FROM test_distributed_orders o
INNER JOIN test_distributed_users u ON o.user_id = u.user_id
WHERE o.amount > (
    SELECT avg(amount)
    FROM test_distributed_orders
)
ORDER BY o.amount DESC;

-- ========================================
-- 11. 测试窗口函数（分布式）
-- ========================================
SELECT
    user_id,
    order_id,
    amount,
    order_date,
    ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY order_date) as user_order_rank,
    SUM(amount) OVER (PARTITION BY user_id ORDER BY order_date) as running_total,
    AVG(amount) OVER (PARTITION BY user_id) as user_avg_amount
FROM test_distributed_orders
ORDER BY user_id, order_date;

-- ========================================
-- 12. 测试分布式 IN 操作
-- ========================================
-- 查找特定用户的订单
SELECT
    user_id,
    order_id,
    amount,
    status
FROM test_distributed_orders
WHERE user_id IN (101, 102, 103)
ORDER BY user_id, order_id;

-- 使用子查询
SELECT
    order_id,
    amount,
    status,
    hostName() as data_from_host
FROM test_distributed_orders
WHERE user_id IN (
    SELECT user_id
    FROM test_distributed_users
    WHERE name LIKE 'A%'
)
ORDER BY order_id;

-- ========================================
-- 13. 查看分布式表统计
-- ========================================
-- 查看分布式表的总行数
SELECT
    sum(rows) as total_rows,
    sum(bytes_on_disk) as total_bytes,
    uniqExact(table) as table_count
FROM system.parts
WHERE table IN ('test_local_orders', 'test_local_users')
  AND active = 1;

-- 查看每个分区的数据量
SELECT
    partition,
    table,
    sum(rows) as total_rows,
    sum(bytes_on_disk) as total_bytes
FROM system.parts
WHERE table IN ('test_local_orders', 'test_local_users')
  AND active = 1
GROUP BY partition, table
ORDER BY table, partition;

-- ========================================
-- 14. 测试分布式表性能
-- ========================================
-- 插入大量测试数据
INSERT INTO test_distributed_orders (order_id, user_id, product_id, amount, status, order_date)
SELECT
    number + 100 as order_id,
    (number % 100) + 100 as user_id,
    (number % 10) + 1000 as product_id,
    round(rand() * 1000, 2) as amount,
    if(rand() > 0.2, 'completed', if(rand() > 0.5, 'pending', 'cancelled')) as status,
    now() - INTERVAL rand() * 30 DAY as order_date
FROM numbers(1000);

-- 验证插入的数据量
SELECT count() as total_orders FROM test_distributed_orders;

-- 性能测试：聚合查询
SELECT
    status,
    count() as count,
    sum(amount) as total,
    avg(amount) as avg,
    quantile(0.5)(amount) as median,
    quantile(0.95)(amount) as p95,
    quantile(0.99)(amount) as p99
FROM test_distributed_orders
GROUP BY status;

-- ========================================
-- 15. 清理测试表（生产环境：使用 ON CLUSTER SYNC 确保集群范围删除）
-- ========================================
-- 注意：先删除分布式表，再删除本地表
DROP TABLE IF EXISTS test_distributed_orders ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS test_distributed_users ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS test_local_orders ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS test_local_users ON CLUSTER 'treasurycluster' SYNC;

-- ========================================
-- 16. 验证清理
-- ================================================
SELECT name FROM system.tables WHERE name LIKE 'test_%';
