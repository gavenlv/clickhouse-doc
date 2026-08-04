-- ============================================================
-- 06 - 综合案例：从 0 到 1 设计电商数据平台
-- 描述：完整的数据建模流程，含需求分析、设计、DDL、查询
-- 适用版本：ClickHouse 25.12+
-- ============================================================

-- 【场景】某电商平台需要构建数据分析平台
-- 需求：
-- 1. 实时订单统计（销售额、订单量、客单价）
-- 2. 商品分析（TOP 商品、类目销售、库存预警）
-- 3. 用户分析（用户画像、复购率、流失分析）
-- 4. 渠道分析（来源渠道、转化率、获客成本）
-- 5. 大促活动分析（实时大屏、同比环比）

DROP DATABASE IF EXISTS modeling_test;
CREATE DATABASE modeling_test;
USE modeling_test;

-- ============================================================
-- 第一步：需求分析 → 数据模型设计
-- ============================================================

-- 【原理】建模步骤
-- 1. 分析查询模式：哪些查询最频繁？过滤条件是什么？
-- 2. 选择表结构：宽表优先（< 200 列）
-- 3. 设计 ORDER BY：按查询频率高的列排序
-- 4. 选择分区策略：按时间分区
-- 5. 设计物化视图：预聚合常用查询
-- 6. 设计字典：维度数据用字典
-- 7. 设计 TTL：数据保留策略

-- ============================================================
-- 第二步：宽表设计（核心订单宽表）
-- ============================================================

-- 核心订单宽表（包含常用维度字段）
CREATE TABLE orders
(
    -- 订单信息
    order_id          UInt64,
    order_time        DateTime,
    order_status      LowCardinality(String),  -- Pending/Paid/Shipped/Completed/Cancelled
    payment_method    LowCardinality(String),
    payment_time      DateTime,
    shipping_fee      Decimal(10, 2),

    -- 用户信息（维度嵌入）
    user_id           UInt32,
    user_name         LowCardinality(String),
    user_level        LowCardinality(String),  -- Normal/VIP/Platinum
    user_register_date Date,

    -- 商品信息（维度嵌入）
    product_id        UInt32,
    product_name      LowCardinality(String),
    product_category  LowCardinality(String),
    product_brand     LowCardinality(String),
    product_price     Decimal(10, 2),

    -- 订单明细
    quantity          UInt16,
    unit_price        Decimal(10, 2),
    total_amount      Decimal(10, 2),
    discount_amount   Decimal(10, 2),
    actual_amount     Decimal(10, 2),

    -- 渠道信息
    channel           LowCardinality(String),  -- App/Web/WeChat/Miniprogram
    source            LowCardinality(String),  -- Organic/Paid/Referral/Social
    campaign_id       UInt32,

    -- 地址信息
    province          LowCardinality(String),
    city              LowCardinality(String),
    district          LowCardinality(String)
)
ENGINE = MergeTree
-- ORDER BY 设计：按查询频率排序
-- 查询频率：user_id > order_time > product_category > order_status
ORDER BY (user_id, order_time, product_category, order_status)
PARTITION BY toYYYYMM(order_time)
-- 数据保留 2 年
TTL toDate(order_time) + INTERVAL 2 YEAR DELETE;

-- ============================================================
-- 第三步：插入模拟数据
-- ============================================================

-- 插入 100 万条订单数据
INSERT INTO orders SELECT
    number AS order_id,
    toDateTime('2024-01-01 00:00:00') + number % 63072000 AS order_time,
    ['Pending', 'Paid', 'Shipped', 'Completed', 'Cancelled'][(number % 5) + 1] AS order_status,
    ['Credit Card', 'Alipay', 'WeChat Pay', 'Cash'][(number % 4) + 1] AS payment_method,
    toDateTime('2024-01-01 00:00:00') + number % 63072000 + 300 AS payment_time,
    toDecimal32(10 + rand() % 30, 2) AS shipping_fee,
    number % 50000 AS user_id,
    concat('user_', toString(number % 50000)) AS user_name,
    ['Normal', 'VIP', 'Platinum'][(number % 3) + 1] AS user_level,
    toDate('2023-01-01') + (number % 50000) % 365 AS user_register_date,
    number % 10000 AS product_id,
    concat('product_', toString(number % 10000)) AS product_name,
    ['Electronics', 'Clothing', 'Food', 'Books', 'Home', 'Sports', 'Beauty', 'Toys'][(number % 8) + 1] AS product_category,
    ['BrandA', 'BrandB', 'BrandC', 'BrandD'][(number % 4) + 1] AS product_brand,
    toDecimal32(50 + rand() % 5000, 2) AS product_price,
    toUInt16((rand() % 10) + 1) AS quantity,
    toDecimal32(50 + rand() % 5000, 2) AS unit_price,
    toDecimal32((rand() % 50000) + 1, 2) AS total_amount,
    toDecimal32(rand() % 5000, 2) AS discount_amount,
    toDecimal32((rand() % 50000) + 1, 2) AS actual_amount,
    ['App', 'Web', 'WeChat', 'Miniprogram'][(number % 4) + 1] AS channel,
    ['Organic', 'Paid', 'Referral', 'Social'][(number % 4) + 1] AS source,
    number % 100 AS campaign_id,
    ['Beijing', 'Shanghai', 'Guangdong', 'Zhejiang', 'Jiangsu', 'Sichuan'][(number % 6) + 1] AS province,
    ['CityA', 'CityB', 'CityC', 'CityD'][(number % 4) + 1] AS city,
    ['District1', 'District2', 'District3'][(number % 3) + 1] AS district
FROM system.numbers
LIMIT 1000000;

-- ============================================================
-- 第四步：字典设计（维度数据加速）
-- ============================================================

-- 商品类目字典
CREATE TABLE dim_category
(
    category_id   UInt64,
    category_name String,
    parent_id     UInt64,
    level         UInt8
)
ENGINE = MergeTree
ORDER BY category_id;

INSERT INTO dim_category VALUES
    (1, 'Electronics', 0, 1), (2, 'Clothing', 0, 1), (3, 'Food', 0, 1),
    (4, 'Books', 0, 1), (5, 'Home', 0, 1), (6, 'Sports', 0, 1),
    (7, 'Beauty', 0, 1), (8, 'Toys', 0, 1),
    (11, 'Smartphones', 1, 2), (12, 'Laptops', 1, 2),
    (21, 'Men', 2, 2), (22, 'Women', 2, 2);

CREATE DICTIONARY dict_category
(
    category_id   UInt64,
    category_name String,
    parent_id     UInt64,
    level         UInt8
)
PRIMARY KEY category_id
SOURCE(CLICKHOUSE(TABLE 'dim_category'))
LAYOUT(HASHED())
LIFETIME(MIN 3600 MAX 7200);

-- 渠道映射字典
CREATE TABLE dim_channel
(
    channel_code String,
    channel_name String,
    channel_group String
)
ENGINE = MergeTree
ORDER BY channel_code;

INSERT INTO dim_channel VALUES
    ('App', 'Mobile App', 'Online'),
    ('Web', 'Website', 'Online'),
    ('WeChat', 'WeChat Mini Program', 'Social'),
    ('Miniprogram', 'Mini Program', 'Social');

CREATE DICTIONARY dict_channel
(
    channel_code String,
    channel_name String,
    channel_group String
)
PRIMARY KEY channel_code
SOURCE(CLICKHOUSE(TABLE 'dim_channel'))
LAYOUT(HASHED())
LIFETIME(MIN 3600 MAX 7200);

-- ============================================================
-- 第五步：物化视图设计（预聚合加速）
-- ============================================================

-- 1. 每日销售统计
CREATE MATERIALIZED VIEW mv_daily_sales
ENGINE = SummingMergeTree
ORDER BY (report_date, product_category, channel)
PARTITION BY toYYYYMM(report_date)
AS SELECT
    toDate(order_time) AS report_date,
    product_category,
    channel,
    count() AS order_count,
    sum(actual_amount) AS sales_amount,
    sum(quantity) AS total_quantity,
    sum(discount_amount) AS total_discount,
    uniqExact(user_id) AS unique_users,
    uniqExact(product_id) AS unique_products
FROM orders
GROUP BY toDate(order_time), product_category, channel;

-- 2. 用户级别销售统计
CREATE MATERIALIZED VIEW mv_user_level_sales
ENGINE = SummingMergeTree
ORDER BY (report_date, user_level)
PARTITION BY toYYYYMM(report_date)
AS SELECT
    toDate(order_time) AS report_date,
    user_level,
    count() AS order_count,
    sum(actual_amount) AS sales_amount,
    uniqExact(user_id) AS unique_users,
    avg(actual_amount) AS avg_order_amount
FROM orders
GROUP BY toDate(order_time), user_level;

-- 3. 每小时销售统计（用于实时大屏）
CREATE MATERIALIZED VIEW mv_hourly_sales
ENGINE = SummingMergeTree
ORDER BY (report_hour, product_category)
PARTITION BY toYYYYMM(report_hour)
AS SELECT
    toStartOfHour(order_time) AS report_hour,
    product_category,
    count() AS order_count,
    sum(actual_amount) AS sales_amount,
    uniqExact(user_id) AS unique_users
FROM orders
GROUP BY toStartOfHour(order_time), product_category;

-- 4. 商品销售排行（物化视图 + AggregatingMergeTree）
CREATE MATERIALIZED VIEW mv_product_ranking
ENGINE = AggregatingMergeTree
ORDER BY (product_category, product_id, report_date)
PARTITION BY toYYYYMM(report_date)
AS SELECT
    product_category,
    product_id,
    product_name,
    toDate(order_time) AS report_date,
    countState() AS order_count,
    sumState(actual_amount) AS sales_amount,
    sumState(quantity) AS total_quantity,
    avgState(unit_price) AS avg_price
FROM orders
GROUP BY product_category, product_id, product_name, toDate(order_time);

-- 5. 渠道转化统计
CREATE MATERIALIZED VIEW mv_channel_stats
ENGINE = SummingMergeTree
ORDER BY (report_date, channel, source)
PARTITION BY toYYYYMM(report_date)
AS SELECT
    toDate(order_time) AS report_date,
    channel,
    source,
    count() AS order_count,
    sum(actual_amount) AS sales_amount,
    uniqExact(user_id) AS unique_users
FROM orders
GROUP BY toDate(order_time), channel, source;

-- ============================================================
-- 第六步：查询模板
-- ============================================================

-- 查询 1：实时大屏 — 今日销售概览
SELECT '【实时大屏】今日销售概览:';
SELECT
    count() AS order_count,
    sum(actual_amount) AS total_sales,
    avg(actual_amount) AS avg_order_amount,
    uniqExact(user_id) AS active_users,
    sum(quantity) AS total_items
FROM orders
WHERE toDate(order_time) = today();

-- 查询 2：类目销售排行（上周）
SELECT '【类目排行】上周各类目销售:';
SELECT
    product_category,
    count() AS order_count,
    sum(actual_amount) AS total_sales,
    round(avg(actual_amount), 2) AS avg_order,
    uniqExact(user_id) AS buyers
FROM orders
WHERE order_time >= toStartOfWeek(now()) - INTERVAL 7 DAY
  AND order_time < toStartOfWeek(now())
GROUP BY product_category
ORDER BY total_sales DESC;

-- 查询 3：用户价值分析（RFM 简化版）
SELECT '【用户分析】用户价值分层:';
SELECT
    user_level,
    count() AS order_count,
    sum(actual_amount) AS total_spent,
    round(avg(actual_amount), 2) AS avg_order,
    uniqExact(user_id) AS user_count,
    round(sum(actual_amount) / uniqExact(user_id), 2) AS arpu
FROM orders
WHERE order_time >= '2024-06-01'
GROUP BY user_level
ORDER BY total_spent DESC;

-- 查询 4：渠道来源分析（使用字典）
SELECT '【渠道分析】各渠道销售:';
SELECT
    channel,
    dictGet('modeling_test.dict_channel', 'channel_name', channel) AS channel_name,
    dictGet('modeling_test.dict_channel', 'channel_group', channel) AS channel_group,
    count() AS order_count,
    sum(actual_amount) AS total_sales,
    uniqExact(user_id) AS users
FROM orders
GROUP BY channel
ORDER BY total_sales DESC;

-- 查询 5：大促活动分析（对比活动前后）
SELECT '【活动分析】大促活动效果:';
-- 活动前 7 天
SELECT 'Before Campaign:';
SELECT count() AS orders, sum(actual_amount) AS sales
FROM orders
WHERE order_time >= '2024-06-01' AND order_time < '2024-06-08';
-- 活动期间 7 天
SELECT 'During Campaign:';
SELECT count() AS orders, sum(actual_amount) AS sales
FROM orders
WHERE order_time >= '2024-06-08' AND order_time < '2024-06-15';

-- 查询 6：复购率分析
SELECT '【复购分析】用户复购率:';
WITH user_orders AS (
    SELECT
        user_id,
        count() AS order_count
    FROM orders
    WHERE order_time >= '2024-01-01'
    GROUP BY user_id
)
SELECT
    multiIf(order_count = 1, '1次', order_count = 2, '2次', order_count >= 3 AND order_count <= 5, '3-5次', '6次+') AS purchase_frequency,
    count() AS user_count,
    round(count() * 100.0 / sum(count()) OVER (), 2) AS pct
FROM user_orders
GROUP BY purchase_frequency
ORDER BY purchase_frequency;

-- 查询 7：地理分布分析
SELECT '【地理分析】各省份销售:';
SELECT
    province,
    count() AS order_count,
    sum(actual_amount) AS total_sales,
    uniqExact(user_id) AS users,
    round(avg(actual_amount), 2) AS avg_order
FROM orders
GROUP BY province
ORDER BY total_sales DESC;

-- 查询 8：实时大屏 — 每小时刷新
SELECT '【实时大屏】过去 24 小时销售:';
SELECT
    toStartOfHour(order_time) AS hour,
    count() AS orders,
    sum(actual_amount) AS sales,
    uniqExact(user_id) AS users
FROM orders
WHERE order_time >= now() - INTERVAL 24 HOUR
GROUP BY toStartOfHour(order_time)
ORDER BY hour;

-- 查询 9：类目同比环比
SELECT '【同比环比】类目销售对比:';
-- 本月 vs 上月
SELECT
    product_category,
    countIf(toMonth(order_time) = toMonth(now())) AS this_month_orders,
    countIf(toMonth(order_time) = toMonth(now() - INTERVAL 1 MONTH)) AS last_month_orders
FROM orders
WHERE toMonth(order_time) >= toMonth(now() - INTERVAL 1 MONTH)
GROUP BY product_category
ORDER BY this_month_orders DESC;

-- 查询 10：商品关联分析（简单版）
SELECT '【商品关联】常一起购买的商品:';
SELECT
    a.product_category AS category_a,
    b.product_category AS category_b,
    count() AS co_purchase_count
FROM orders a
INNER JOIN orders b ON a.user_id = b.user_id
    AND a.order_time = b.order_time
    AND a.product_category < b.product_category
WHERE a.order_time >= '2024-06-01'
GROUP BY a.product_category, b.product_category
ORDER BY co_purchase_count DESC
LIMIT 10;

-- ============================================================
-- 第七步：数据维护与监控
-- ============================================================

-- 查看表大小
SELECT '【存储监控】各表大小:';
SELECT table, formatReadableSize(sum(bytes_on_disk)) AS size, count() AS parts
FROM system.parts
WHERE database = 'modeling_test' AND active = 1
GROUP BY table
ORDER BY table;

-- 查看物化视图状态
SELECT '【MV 监控】物化视图状态:';
SELECT
    name,
    engine,
    data_paths
FROM system.tables
WHERE database = 'modeling_test' AND engine LIKE '%MaterializedView%';

-- 查看字典状态
SELECT '【字典监控】字典状态:';
SELECT
    name,
    status,
    formatReadableSize(bytes_allocated) AS memory,
    element_count,
    last_successful_update_time
FROM system.dictionaries
WHERE database = 'modeling_test';

-- 查看分区信息
SELECT '【分区监控】分区信息:';
SELECT
    table,
    partition_id,
    count() AS parts,
    rows,
    formatReadableSize(bytes_on_disk) AS size,
    min_time,
    max_time
FROM system.parts
WHERE database = 'modeling_test' AND table = 'orders' AND active = 1
GROUP BY table, partition_id, rows, bytes_on_disk, min_time, max_time
ORDER BY partition_id;

-- 数据质量检查
SELECT '【数据质量】检查数据完整性:';
SELECT
    'order_count' AS metric, count() AS value FROM orders
UNION ALL
SELECT 'null_user_id', count() FROM orders WHERE user_id IS NULL
UNION ALL
SELECT 'negative_amount', count() FROM orders WHERE actual_amount < 0
UNION ALL
SELECT 'future_orders', count() FROM orders WHERE order_time > now();

-- ============================================================
-- 总结：电商数据平台建模要点
-- ============================================================
-- 1. 宽表设计：200 列以内，将常用维度嵌入
-- 2. ORDER BY：(user_id, order_time, product_category, order_status)
-- 3. 分区：按月分区，数据量大按天
-- 4. 物化视图：5 个 MV 覆盖常用查询场景
-- 5. 字典：类目、渠道等维度使用字典
-- 6. TTL：2 年数据保留策略
-- 7. 查询优化：利用物化视图 + 字典 + 主键过滤

SELECT 'DONE - 电商数据平台综合案例完成';

DROP DATABASE IF EXISTS modeling_test;