-- ============================================================
-- 01 - 宽表 vs 星型模式
-- 描述：宽表（单表 JOIN 少）vs 星型（维度建模范式）的原理与性能对比
-- 适用版本：ClickHouse 25.12+
-- ============================================================

-- 【原理】宽表与星型模式的核心区别
-- ============================================================
-- 宽表（Wide Table）：
--   - 将所有字段放在一张表中，包括维度数据
--   - 优势：列式存储下 I/O 更少，无需 JOIN
--   - 劣势：数据冗余大，维度更新困难
--   - 适用：列数 < 200 的场景
--
-- 星型模式（Star Schema）：
--   - 事实表 + 维度表，通过 JOIN 关联
--   - 优势：维度可复用，更新方便，节省存储
--   - 劣势：JOIN 查询有性能开销
--   - 适用：维度经常变化、列数 > 200 的场景
-- ============================================================

DROP DATABASE IF EXISTS modeling_test;
CREATE DATABASE modeling_test;
USE modeling_test;

-- ============================================================
-- 实验一：宽表 vs 星型模式性能对比
-- ============================================================

-- 【场景】电商订单分析：支持按用户、商品、时间过滤

-- 方案 A：宽表设计
CREATE TABLE orders_wide
(
    order_id        UInt64,
    user_id         UInt32,
    user_name       String,
    user_level      String,
    user_region     String,
    product_id      UInt32,
    product_name    String,
    product_category String,
    product_price   Decimal(10, 2),
    order_amount    Decimal(10, 2),
    order_status    String,
    order_time      DateTime,
    payment_method  String,
    shipping_address String
)
ENGINE = MergeTree
ORDER BY (user_id, order_time, order_id)
PARTITION BY toYYYYMM(order_time);

-- 方案 B：星型模式设计
-- 事实表
CREATE TABLE orders_fact
(
    order_id        UInt64,
    user_id         UInt32,
    product_id      UInt32,
    order_amount    Decimal(10, 2),
    order_status    String,
    order_time      DateTime,
    payment_method  String,
    shipping_address String
)
ENGINE = MergeTree
ORDER BY (user_id, order_time, order_id)
PARTITION BY toYYYYMM(order_time);

-- 用户维度表
CREATE TABLE dim_user
(
    user_id         UInt32,
    user_name       String,
    user_level      String,
    user_region     String
)
ENGINE = MergeTree
ORDER BY user_id;

-- 商品维度表
CREATE TABLE dim_product
(
    product_id      UInt32,
    product_name    String,
    product_category String,
    product_price   Decimal(10, 2)
)
ENGINE = MergeTree
ORDER BY product_id;

-- 插入测试数据：100 万条订单
-- 宽表
INSERT INTO orders_wide SELECT
    number AS order_id,
    number % 100000 AS user_id,
    concat('user_', toString(number % 100000)) AS user_name,
    ['VIP', 'Normal', 'Platinum'][(number % 3) + 1] AS user_level,
    ['North', 'South', 'East', 'West'][(number % 4) + 1] AS user_region,
    number % 5000 AS product_id,
    concat('product_', toString(number % 5000)) AS product_name,
    ['Electronics', 'Clothing', 'Food', 'Books'][(number % 4) + 1] AS product_category,
    toDecimal32((rand() % 1000) + 1, 2) AS product_price,
    toDecimal32((rand() % 1000) + 1, 2) AS order_amount,
    ['Pending', 'Paid', 'Shipped', 'Completed'][(number % 4) + 1] AS order_status,
    toDateTime('2024-01-01 00:00:00') + number % 31536000 AS order_time,
    ['Credit Card', 'Alipay', 'WeChat', 'Cash'][(number % 4) + 1] AS payment_method,
    concat('address_', toString(number % 10000)) AS shipping_address
FROM system.numbers
LIMIT 1000000;

-- 星型模式：事实表
INSERT INTO orders_fact SELECT
    number AS order_id,
    number % 100000 AS user_id,
    number % 5000 AS product_id,
    toDecimal32((rand() % 1000) + 1, 2) AS order_amount,
    ['Pending', 'Paid', 'Shipped', 'Completed'][(number % 4) + 1] AS order_status,
    toDateTime('2024-01-01 00:00:00') + number % 31536000 AS order_time,
    ['Credit Card', 'Alipay', 'WeChat', 'Cash'][(number % 4) + 1] AS payment_method,
    concat('address_', toString(number % 10000)) AS shipping_address
FROM system.numbers
LIMIT 1000000;

-- 维度表：用户
INSERT INTO dim_user SELECT
    number AS user_id,
    concat('user_', toString(number)) AS user_name,
    ['VIP', 'Normal', 'Platinum'][(number % 3) + 1] AS user_level,
    ['North', 'South', 'East', 'West'][(number % 4) + 1] AS user_region
FROM system.numbers
LIMIT 100000;

-- 维度表：商品
INSERT INTO dim_product SELECT
    number AS product_id,
    concat('product_', toString(number)) AS product_name,
    ['Electronics', 'Clothing', 'Food', 'Books'][(number % 4) + 1] AS product_category,
    toDecimal32((rand() % 1000) + 1, 2) AS product_price
FROM system.numbers
LIMIT 5000;

-- 【对比】性能对比实验
-- 1. 查询某个用户的所有订单（宽表，无需 JOIN）
SELECT '【宽表】查询用户 100 的订单:';
SELECT count() AS order_count, sum(order_amount) AS total_amount
FROM orders_wide
WHERE user_id = 100;

-- 2. 星型模式查询（需要 JOIN 两张维度表）
SELECT '【星型】查询用户 100 的订单:';
SELECT count() AS order_count, sum(o.order_amount) AS total_amount
FROM orders_fact o
INNER JOIN dim_user u ON o.user_id = u.user_id
WHERE o.user_id = 100;

-- 【坑】宽表虽然查询更快，但维度数据更新非常麻烦
-- 例如：用户 100 的等级从 VIP 变为 Platinum
-- 宽表需要 UPDATE 所有相关行（ALTER TABLE 异步操作）
-- 星型模式只需更新维度表的一行

-- 【坑】宽表数据冗余导致存储膨胀
-- 查询存储对比
SELECT '【存储对比】宽表大小:';
SELECT table, formatReadableSize(sum(bytes_on_disk))
FROM system.parts
WHERE database = 'modeling_test' AND table = 'orders_wide'
GROUP BY table;

SELECT '【存储对比】星型模式总大小:';
SELECT table, formatReadableSize(sum(bytes_on_disk))
FROM system.parts
WHERE database = 'modeling_test' AND table IN ('orders_fact', 'dim_user', 'dim_product')
GROUP BY table;

-- ============================================================
-- 实验二：ARRAY JOIN 宽表 vs 多表 JOIN
-- ============================================================

-- 【场景】商品标签分析：一件商品多个标签，宽表用 Array 存储

-- 宽表：使用 Array 列存储标签
CREATE TABLE products_wide
(
    product_id    UInt32,
    product_name  String,
    category      String,
    tags          Array(String),
    tag_weights   Array(Float32)
)
ENGINE = MergeTree
ORDER BY product_id;

-- 星型：商品 + 标签维度
CREATE TABLE products_fact
(
    product_id    UInt32,
    product_name  String,
    category      String
)
ENGINE = MergeTree
ORDER BY product_id;

CREATE TABLE product_tags
(
    product_id    UInt32,
    tag           String,
    weight        Float32
)
ENGINE = MergeTree
ORDER BY (product_id, tag);

-- 插入数据
INSERT INTO products_wide VALUES
    (1, 'iPhone 15', 'Electronics', ['smartphone', 'apple', '5g', 'premium'], [1.0, 0.9, 0.8, 0.7]),
    (2, 'MacBook Pro', 'Electronics', ['laptop', 'apple', 'pro', 'm3'], [1.0, 0.9, 0.9, 0.8]),
    (3, 'Nike Shoes', 'Clothing', ['sports', 'running', 'shoes'], [1.0, 0.9, 0.8]);

INSERT INTO products_fact VALUES
    (1, 'iPhone 15', 'Electronics'),
    (2, 'MacBook Pro', 'Electronics'),
    (3, 'Nike Shoes', 'Clothing');

INSERT INTO product_tags VALUES
    (1, 'smartphone', 1.0), (1, 'apple', 0.9), (1, '5g', 0.8), (1, 'premium', 0.7),
    (2, 'laptop', 1.0), (2, 'apple', 0.9), (2, 'pro', 0.9), (2, 'm3', 0.8),
    (3, 'sports', 1.0), (3, 'running', 0.9), (3, 'shoes', 0.8);

-- ARRAY JOIN 查询（宽表，无需 JOIN）
SELECT '【ARRAY JOIN】宽表查询标签:';
SELECT p.product_id, p.product_name, t.tag, t.weight
FROM products_wide p
ARRAY JOIN tags AS t, tag_weights AS weight
WHERE p.category = 'Electronics';

-- 多表 JOIN 查询（星型）
SELECT '【多表 JOIN】星型查询标签:';
SELECT f.product_id, f.product_name, t.tag, t.weight
FROM products_fact f
INNER JOIN product_tags t ON f.product_id = t.product_id
WHERE f.category = 'Electronics';

-- 【坑】ARRAY JOIN 需要所有 Array 长度一致，否则会报错
-- 如果 tags 和 tag_weights 长度不一致，ARRAY JOIN 会静默填充或截断

-- ============================================================
-- 实验三：宽表 vs 星型 — 数据更新场景
-- ============================================================

-- 【场景】商品价格调整：需要更新所有历史订单中的商品价格

-- 宽表：需要更新所有相关行
-- 假设商品 1 的价格从 100 调整为 120
-- 以下操作在 CH 中非常慢，因为需要重写所有数据
-- ALTER TABLE orders_wide UPDATE product_price = 120 WHERE product_id = 1;

-- 星型：只需更新维度表的一行
-- 即使历史订单的价格也需要更新，但也只需更新一张小表
-- ALTER TABLE dim_product UPDATE product_price = 120 WHERE product_id = 1;

-- 【坑】宽表维度更新是异步的，不会立即生效
-- 且 ALTER TABLE UPDATE 是重写操作，对磁盘 I/O 压力大

-- ============================================================
-- 结论：生产环境的实际选择
-- ============================================================
-- 【场景】OLAP 优先宽表
-- 1. 列数 < 200 时：宽表 > 星型
-- 2. 列数 200-500：部分维度拆分（使用 LowCardinality 优化）
-- 3. 列数 > 500：必须使用星型模式
-- 4. 维度频繁更新：星型模式
-- 5. 维度数据可复用（多个事实表共享）：星型模式
-- 6. 查询性能优先：宽表 + 字典替代 JOIN

-- 【最佳实践】
-- 1. 宽表中使用 LowCardinality 类型优化低基数字段
-- 2. 使用字典替代 JOIN 处理维度数据
-- 3. 更新频繁的维度使用星型模式
-- 4. 宽表列数控制在 200 以内

-- 创建带 LowCardinality 优化的宽表
CREATE TABLE orders_wide_optimized
(
    order_id          UInt64,
    user_id           UInt32,
    user_name         LowCardinality(String),
    user_level        LowCardinality(String),
    user_region       LowCardinality(String),
    product_id        UInt32,
    product_name      LowCardinality(String),
    product_category  LowCardinality(String),
    product_price     Decimal(10, 2),
    order_amount      Decimal(10, 2),
    order_status      LowCardinality(String),
    order_time        DateTime,
    payment_method    LowCardinality(String),
    shipping_address  String
)
ENGINE = MergeTree
ORDER BY (user_id, order_time, order_id)
PARTITION BY toYYYYMM(order_time);

SELECT '【优化建议】使用 LowCardinality 类型减少存储和加速查询';
SELECT 'DONE - 宽表 vs 星型模式实验完成';

DROP DATABASE IF EXISTS modeling_test;