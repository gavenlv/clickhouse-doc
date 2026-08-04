-- =====================================================
-- 07 - GLOBAL JOIN 原理
-- =====================================================
-- 普通 JOIN vs GLOBAL JOIN 对比
-- GLOBAL IN 替代方案
-- 分布式 JOIN 最佳实践
-- 集群: treasurycluster
-- =====================================================

-- 注意: 集群建库必须加 ON CLUSTER，否则 clickhouse-server-2 上数据库不存在，
-- 后续 ON CLUSTER 建表会报 Code 81 (UNKNOWN_DATABASE)
DROP DATABASE IF EXISTS distributed_test ON CLUSTER treasurycluster;
CREATE DATABASE IF NOT EXISTS distributed_test ON CLUSTER treasurycluster;
USE distributed_test;

-- ========================================
-- 【原理】普通 JOIN 在分布式下的问题
-- ========================================
-- 在分布式表上执行普通 JOIN 时:
--   1. 协调节点将查询发往所有分片
--   2. 每个分片用本地右表执行 JOIN
--   3. 每个分片只看到本地右表数据
--   4. 结果缺失（右表数据分散在各分片）
--
-- 示例:
--   SELECT * FROM dist_orders
--   JOIN dist_users ON orders.user_id = users.user_id
--
--   分片1: 有 user 1,2,3 → 只 JOIN 到 user 1,2,3
--   分片2: 有 user 4,5,6 → 只 JOIN 到 user 4,5,6
--   结果: 正确 ✅（因为 user_id 也是分片键，相同用户在同一分片）
--
--   但如果右表不是按相同字段分片:
--   分片1: 有 user 1,2,3 → 但右表只有 user 1 → 结果缺失 ❌
--   分片2: 有 user 4,5,6 → 但右表只有 user 4 → 结果缺失 ❌
--
-- GLOBAL JOIN 解决这个问题:
--   1. 协调节点从所有分片收集右表完整数据
--   2. 将完整右表广播到所有分片（临时表）
--   3. 每个分片用完整右表 JOIN → 结果正确 ✅

-- -----------------------------------------------------
-- 1. 创建测试表
-- -----------------------------------------------------
-- 创建订单表（按 user_id 分片）
CREATE TABLE IF NOT EXISTS orders_local ON CLUSTER treasurycluster
(
    order_id UInt64,
    user_id UInt32,
    amount Float64,
    order_date Date
)
ENGINE = ReplicatedMergeTree
PARTITION BY toYYYYMM(order_date)
ORDER BY (order_date, order_id);

CREATE TABLE IF NOT EXISTS dist_orders ON CLUSTER treasurycluster
AS orders_local
ENGINE = Distributed(treasurycluster, distributed_test, orders_local, cityHash64(user_id));

-- 创建用户表（按 user_id 分片）
CREATE TABLE IF NOT EXISTS users_local ON CLUSTER treasurycluster
(
    user_id UInt32,
    name String,
    city String,
    register_date Date
)
ENGINE = ReplicatedMergeTree
ORDER BY user_id;

CREATE TABLE IF NOT EXISTS dist_users ON CLUSTER treasurycluster
AS users_local
ENGINE = Distributed(treasurycluster, distributed_test, users_local, cityHash64(user_id));

-- 创建产品表（不按 user_id 分片，用于演示 JOIN 问题）
CREATE TABLE IF NOT EXISTS products_local ON CLUSTER treasurycluster
(
    product_id UInt32,
    product_name String,
    category String,
    price Float64
)
ENGINE = ReplicatedMergeTree
ORDER BY product_id;

CREATE TABLE IF NOT EXISTS dist_products ON CLUSTER treasurycluster
AS products_local
ENGINE = Distributed(treasurycluster, distributed_test, products_local, rand());

-- 插入订单数据
INSERT INTO dist_orders VALUES
(1001, 1, 99.99, '2024-01-15'),
(1002, 1, 199.99, '2024-01-16'),
(1003, 2, 49.99, '2024-01-15'),
(1004, 3, 299.99, '2024-01-17'),
(1005, 4, 149.99, '2024-01-15'),
(1006, 5, 79.99, '2024-01-16');

-- 插入用户数据
INSERT INTO dist_users VALUES
(1, 'Alice', 'Beijing', '2024-01-01'),
(2, 'Bob', 'Shanghai', '2024-01-02'),
(3, 'Charlie', 'Guangzhou', '2024-01-03'),
(4, 'David', 'Shenzhen', '2024-01-04'),
(5, 'Eve', 'Hangzhou', '2024-01-05');

-- 插入产品数据
INSERT INTO dist_products VALUES
(101, 'Laptop', 'Electronics', 999.99),
(102, 'Mouse', 'Electronics', 29.99),
(103, 'Book', 'Education', 19.99),
(104, 'Desk', 'Furniture', 299.99),
(105, 'Chair', 'Furniture', 199.99);

-- -----------------------------------------------------
-- 2. 普通 JOIN（同分片键）
-- -----------------------------------------------------
-- 【场景】orders 和 users 都按 user_id 分片
-- 相同 user_id 的数据在同一分片 → 普通 JOIN 结果正确
SELECT 
    o.order_id,
    u.name,
    u.city,
    o.amount,
    o.order_date
FROM dist_orders o
JOIN dist_users u ON o.user_id = u.user_id
ORDER BY o.order_id;

-- 查看 JOIN 的执行计划
-- 【原理】普通 JOIN 在各分片独立执行
EXPLAIN PLAN
SELECT 
    o.order_id,
    u.name,
    u.city,
    o.amount
FROM dist_orders o
JOIN dist_users u ON o.user_id = u.user_id;

-- -----------------------------------------------------
-- 3. 普通 JOIN（不同分片键 — 问题场景）
-- -----------------------------------------------------
-- 【场景】orders 和 products 的分片键不同
-- products 用 rand() 分片，数据随机分布
-- 普通 JOIN 结果可能缺失
-- 
-- 【坑】products 表用 rand() 分片，数据分散在各分片
-- 每个分片只有部分产品数据，JOIN 会缺失数据

-- 尝试普通 JOIN（可能缺失数据）
SELECT 
    o.order_id,
    o.amount,
    p.product_name,
    p.category
FROM dist_orders o
JOIN dist_products p ON o.order_id = p.product_id
ORDER BY o.order_id;

-- 查看各分片的产品数据
-- 【原理】验证产品数据分散在各分片
SELECT 
    hostName() AS host,
    count() AS product_count
FROM clusterAllReplicas(treasurycluster, distributed_test.products_local)
GROUP BY host;

-- -----------------------------------------------------
-- 4. GLOBAL JOIN
-- -----------------------------------------------------
-- 【原理】GLOBAL JOIN 解决跨分片 JOIN 问题
-- 执行流程:
--   1. 协调节点从所有分片查询右表，获取完整数据
--   2. 将完整右表创建为临时表
--   3. 将临时表广播到所有分片
--   4. 每个分片用完整右表 JOIN
--   5. 结果正确

-- 使用 GLOBAL JOIN（数据完整）
SELECT 
    o.order_id,
    o.amount,
    p.product_name,
    p.category
FROM dist_orders o
GLOBAL JOIN dist_products p ON o.order_id = p.product_id
ORDER BY o.order_id;

-- 查看 GLOBAL JOIN 的执行计划
-- 【原理】GLOBAL JOIN 先收集右表再广播
EXPLAIN PLAN
SELECT 
    o.order_id,
    o.amount,
    p.product_name
FROM dist_orders o
GLOBAL JOIN dist_products p ON o.order_id = p.product_id;

-- -----------------------------------------------------
-- 【原理】GLOBAL JOIN 的性能影响
-- -----------------------------------------------------
-- GLOBAL JOIN 的性能开销:
--   1. 右表收集: 从所有分片收集右表数据到协调节点
--      → 网络传输量 = 右表大小
--   2. 右表广播: 从协调节点广播到所有分片
--      → 网络传输量 = 右表大小 × 分片数
--   3. 临时表创建: 每个分片创建临时表
--      → 内存占用 = 右表大小 × 分片数
--
-- 总网络传输量 = 右表大小 × (1 + 分片数)
-- 如果右表很大，网络开销会非常大！
--
-- 【坑】GLOBAL JOIN 在右表大时性能很差
-- 建议: 右表小（< 100 万行）时用 GLOBAL JOIN
--       右表大时用字典或物化视图替代

-- 模拟大右表的情况
-- 计算 GLOBAL JOIN 的理论传输量
SELECT 
    'GLOBAL JOIN 传输量估算' AS metric,
    (SELECT count() FROM dist_products) AS right_table_rows,
    (SELECT count() FROM system.clusters WHERE cluster = 'treasurycluster') AS node_count,
    (SELECT count() FROM dist_products) * (1 + (SELECT count() FROM system.clusters WHERE cluster = 'treasurycluster')) AS total_transfer_rows;

-- -----------------------------------------------------
-- 5. GLOBAL IN 替代 GLOBAL JOIN
-- -----------------------------------------------------
-- 【场景】当只需要右表的某个字段做过滤时
-- GLOBAL IN 比 GLOBAL JOIN 更高效

-- 使用 GLOBAL JOIN（完整 JOIN）
SELECT 
    o.order_id,
    o.amount,
    o.order_date
FROM dist_orders o
GLOBAL JOIN dist_products p ON o.order_id = p.product_id
WHERE p.category = 'Electronics'
ORDER BY o.order_id;

-- 使用 GLOBAL IN（更高效，只传输过滤条件）
-- 【原理】GLOBAL IN 只广播右表的过滤值，而不是整个右表
-- 网络传输量大大减少
SELECT 
    o.order_id,
    o.amount,
    o.order_date
FROM dist_orders o
WHERE o.order_id IN (
    SELECT product_id
    FROM dist_products
    WHERE category = 'Electronics'
)
ORDER BY o.order_id;

-- 查看 GLOBAL IN 的执行计划
-- 【原理】GLOBAL IN 自动将 IN 子查询替换为广播
EXPLAIN PLAN
SELECT 
    o.order_id,
    o.amount
FROM dist_orders o
WHERE o.order_id IN (
    SELECT product_id
    FROM dist_products
    WHERE category = 'Electronics'
);

-- -----------------------------------------------------
-- 6. 使用字典替代 GLOBAL JOIN
-- -----------------------------------------------------
-- 【场景】右表是静态或低频更新的数据
-- 使用字典（Dictionary）比 GLOBAL JOIN 性能更好
-- 字典缓存在每个节点上，查询时本地访问，零网络开销

-- 创建字典（生产环境用 DDL 创建）
-- 这里用查询模拟字典的效果
-- 实际上，ClickHouse 支持创建分布式字典:
-- CREATE DICTIONARY dict_products ...
-- SOURCE(CLICKHOUSE(HOST 'localhost' PORT 9000 TABLE 'products_local'))
-- LAYOUT(HASHED()) LIFETIME(300);

-- 用字典查询替代 GLOBAL JOIN
-- 假设字典已创建，查询简化为:
-- SELECT dictGet('dict_products', 'product_name', product_id)
-- 但这里用子查询模拟

-- 对比: 使用物化视图预 JOIN
-- 【最佳实践】高频查询用物化视图预聚合，避免运行时 JOIN
-- 创建物化视图示例:
-- CREATE MATERIALIZED VIEW mv_orders_with_products
-- ENGINE = ReplicatedMergeTree
-- ORDER BY (order_date, order_id)
-- AS SELECT
--     o.order_id, o.user_id, o.amount, o.order_date,
--     p.product_name, p.category
-- FROM orders_local o
-- JOIN products_local p ON o.order_id = p.product_id;

-- -----------------------------------------------------
-- 【对比】JOIN 方式对比
-- -----------------------------------------------------
-- +------------------+------------------+------------------+------------------+
-- | 特性              | 普通 JOIN        | GLOBAL JOIN      | GLOBAL IN        | 字典             |
-- +------------------+------------------+------------------+------------------+
-- | 结果正确性        | 同分片键 ✅       | 总是正确 ✅       | 过滤条件正确 ✅   | 总是正确 ✅      |
-- |                  | 不同分片键 ❌     |                  |                  |                  |
-- | 网络传输          | 无               | 右表 × (1+N)     | 过滤值 × (1+N)   | 无               |
-- | 内存占用          | 无               | 右表 × N         | 过滤值 × N        | 字典内存         |
-- | 适用右表大小      | 无限制           | < 100 万行        | < 1000 万过滤值   | 百万级           |
-- | 实时性            | 实时             | 实时              | 实时              | 近实时（缓存）    |
-- | 推荐场景          | 同分片键 JOIN    | 小表跨分片 JOIN    | 过滤场景          | 静态/低频更新     |
-- +------------------+------------------+------------------+------------------+--

-- -----------------------------------------------------
-- 7. 分布式 JOIN 最佳实践
-- -----------------------------------------------------
-- 1. 同分片键 JOIN: 用普通 JOIN（无额外开销）
--    确保两表按相同字段分片（如都用 cityHash64(user_id)）
--
-- 2. 小表 JOIN: 用 GLOBAL JOIN（右表 < 100 万行）
--    右表小，广播开销可接受
--
-- 3. 过滤场景: 用 GLOBAL IN（比 GLOBAL JOIN 更高效）
--    只传输过滤值，减少网络开销
--
-- 4. 静态数据: 用字典（零网络开销，高性能）
--    适合低频更新的参考数据
--
-- 5. 高频查询: 用物化视图预 JOIN
--    查询时直接读取预 JOIN 结果，避免运行时 JOIN
--
-- 6. 避免分布式 JOIN 大表: 考虑数据冗余
--    将常用的 JOIN 字段冗余到主表，避免跨分片 JOIN

-- 验证同分片键 JOIN 的正确性
-- 【场景】orders 和 users 都按 user_id 分片
-- 普通 JOIN 结果 = GLOBAL JOIN 结果
SELECT 
    '普通JOIN' AS method,
    count() AS order_count,
    sum(o.amount) AS total_amount
FROM dist_orders o
JOIN dist_users u ON o.user_id = u.user_id

UNION ALL

SELECT 
    'GLOBAL JOIN' AS method,
    count() AS order_count,
    sum(o.amount) AS total_amount
FROM dist_orders o
GLOBAL JOIN dist_users u ON o.user_id = u.user_id;

-- -----------------------------------------------------
-- 【坑】分布式 JOIN 常见问题
-- -----------------------------------------------------
-- 1. "GLOBAL JOIN 和普通 JOIN 一样快"
--    实际: GLOBAL JOIN 需要广播右表，网络开销大
--    右表 100 万行、10 分片 → 传输 1000 万行数据
--
-- 2. "GLOBAL JOIN 自动优化"
--    实际: 需要手动写 GLOBAL 关键字
--    ClickHouse 不会自动将普通 JOIN 转为 GLOBAL JOIN
--
-- 3. "IN 子查询自动跨分片"
--    实际: 普通 IN 子查询在各分片独立执行
--    需要 GLOBAL IN 才能跨分片正确执行
--
-- 4. "字典一定比 GLOBAL JOIN 快"
--    实际: 字典需要预先加载到内存
--    如果字典数据量大且不常访问，内存浪费
--
-- 5. "物化视图替代所有 JOIN"
--    实际: 物化视图增加存储成本，且需要维护
--    适合高频查询，低频查询用 GLOBAL JOIN 更灵活

-- -----------------------------------------------------
-- 清理
-- -----------------------------------------------------
DROP TABLE IF EXISTS dist_orders ON CLUSTER treasurycluster SYNC;
DROP TABLE IF EXISTS orders_local ON CLUSTER treasurycluster SYNC;
DROP TABLE IF EXISTS dist_users ON CLUSTER treasurycluster SYNC;
DROP TABLE IF EXISTS users_local ON CLUSTER treasurycluster SYNC;
DROP TABLE IF EXISTS dist_products ON CLUSTER treasurycluster SYNC;
DROP TABLE IF EXISTS products_local ON CLUSTER treasurycluster SYNC;

-- 与开头 ON CLUSTER 建库对应，DROP 也须 ON CLUSTER
DROP DATABASE IF EXISTS distributed_test ON CLUSTER treasurycluster;