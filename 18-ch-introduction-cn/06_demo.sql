-- =====================================================
-- 06 - 现场演示案例
-- =====================================================
-- 集群: treasurycluster (2副本)
-- 本文件包含现场演示的 SQL 代码
-- =====================================================

-- -----------------------------------------------------
-- 演示 1: 实时分析仪表板
-- -----------------------------------------------------

-- 使用 playground 数据库
USE playground;

-- 创建电商分析表 (Replicated)
DROP TABLE IF EXISTS orders ON CLUSTER treasurycluster SYNC;

CREATE TABLE orders ON CLUSTER treasurycluster (
    order_id UInt64,
    user_id UInt32,
    order_time DateTime,
    order_date Date DEFAULT toDate(order_time),
    product_id UInt32,
    category LowCardinality(String),
    product_name String,
    quantity UInt32,
    unit_price Decimal(10, 2),
    total_amount Decimal(10, 2),
    status Enum8('pending' = 1, 'paid' = 2, 'shipped' = 3, 'completed' = 4, 'cancelled' = 5)
) ENGINE = ReplicatedMergeTree()
PARTITION BY toYYYYMM(order_date)
ORDER BY (order_date, user_id, order_time);

-- 生成模拟数据 (30天 × 10万订单 = 300万行)
INSERT INTO orders
SELECT 
    number AS order_id,
    number % 50000 AS user_id,
    toDateTime('2024-01-01 00:00:00') + (number % (30 * 24 * 3600)) AS order_time,
    toDate(toDateTime('2024-01-01 00:00:00') + (number % (30 * 24 * 3600))) AS order_date,
    number % 10000 AS product_id,
    ['Electronics', 'Clothing', 'Food', 'Books', 'Sports', 'Home', 'Beauty'][number % 7 + 1] AS category,
    'Product_' || toString(number % 10000) AS product_name,
    (number % 5) + 1 AS quantity,
    (rand() % 10000) / 100 AS unit_price,
    ((rand() % 10000) / 100) * ((number % 5) + 1) AS total_amount,
    CAST(number % 5 + 1 AS Enum8('pending' = 1, 'paid' = 2, 'shipped' = 3, 'completed' = 4, 'cancelled' = 5)) AS status
FROM numbers(3000000);

-- 演示查询
-- 1. 今日订单统计
SELECT 
    count() AS today_orders,
    sum(total_amount) AS today_revenue,
    uniqExact(user_id) AS today_users
FROM orders
WHERE order_date = today();

-- 2. 过去7天趋势
SELECT 
    order_date,
    count() AS orders,
    sum(total_amount) AS revenue,
    uniqExact(user_id) AS users
FROM orders
WHERE order_date >= today() - 7
GROUP BY order_date
ORDER BY order_date;

-- 3. 品类销售排行
SELECT 
    category,
    count() AS orders,
    sum(total_amount) AS revenue,
    sum(quantity) AS products_sold
FROM orders
WHERE order_date >= today() - 30
GROUP BY category
ORDER BY revenue DESC;

-- 4. 小时分布
SELECT 
    toHour(order_time) AS hour,
    count() AS orders,
    sum(total_amount) AS revenue
FROM orders
WHERE order_date = today() - 1
GROUP BY hour
ORDER BY hour;

-- 5. 用户留存分析
WITH 
    toDate('2024-01-01') AS day1,
    toDate('2024-01-02') AS day2,
    toDate('2024-01-03') AS day3
SELECT 
    'Day1->Day2' AS period,
    (SELECT uniqExact(user_id) FROM orders WHERE order_date = day1) AS day1_users,
    (SELECT uniqExact(user_id) FROM orders WHERE order_date = day2 AND user_id IN (SELECT user_id FROM orders WHERE order_date = day1)) AS retained_users,
    round((SELECT retained_users) / (SELECT day1_users) * 100, 2) AS retention_rate
UNION ALL
SELECT 
    'Day2->Day3' AS period,
    (SELECT uniqExact(user_id) FROM orders WHERE order_date = day2) AS day1_users,
    (SELECT uniqExact(user_id) FROM orders WHERE order_date = day3 AND user_id IN (SELECT user_id FROM orders WHERE order_date = day2)) AS retained_users,
    round((SELECT retained_users) / (SELECT day1_users) * 100, 2) AS retention_rate;

-- -----------------------------------------------------
-- 演示 2: 实时数据管道
-- -----------------------------------------------------

-- 创建实时订单表 (Buffer 演示, Replicated)
DROP TABLE IF EXISTS orders_realtime ON CLUSTER treasurycluster SYNC;
DROP TABLE IF EXISTS orders_realtime_buffer ON CLUSTER treasurycluster SYNC;

CREATE TABLE orders_realtime ON CLUSTER treasurycluster (
    order_id UInt64,
    user_id UInt32,
    event_time DateTime,
    event_type String,
    data String
) ENGINE = ReplicatedMergeTree()
ORDER BY event_time;

CREATE TABLE orders_realtime_buffer ON CLUSTER treasurycluster AS orders_realtime
ENGINE = Buffer('playground', 'orders_realtime', 16, 10, 100, 10000, 1000000, 10000000, 100000000);

-- 模拟实时写入
INSERT INTO orders_realtime_buffer 
SELECT 
    number + 10000000 AS order_id,
    number % 10000 AS user_id,
    now() AS event_time,
    ['order_created', 'order_paid', 'order_shipped'][number % 3 + 1] AS event_type,
    '{"key": "value"}' AS data
FROM numbers(1000);

-- 查看 Buffer 状态
-- SELECT 
--     database,
--     table,
--     num_layers,
--     is_stale,
--     bytes
-- FROM system.buffers
-- WHERE database = 'playground';

-- 刷新到主表
-- SYSTEM FLUSH TABLES orders_realtime_buffer;

SELECT count() FROM orders_realtime;

-- -----------------------------------------------------
-- 演示 3: 物化视图预聚合
-- -----------------------------------------------------

-- 创建日统计物化视图 (Replicated)
DROP TABLE IF EXISTS daily_category_stats ON CLUSTER treasurycluster SYNC;
CREATE TABLE daily_category_stats ON CLUSTER treasurycluster (
    date Date,
    category String,
    order_count UInt64,
    user_count UInt64,
    total_revenue Decimal(20, 2)
) ENGINE = ReplicatedSummingMergeTree()
PARTITION BY toYYYYMM(date)
ORDER BY (date, category);

-- DROP MATERIALIZED VIEW IF EXISTS daily_category_stats_mv ON CLUSTER treasurycluster SYNC;
CREATE MATERIALIZED VIEW daily_category_stats_mv ON CLUSTER treasurycluster
ENGINE = ReplicatedSummingMergeTree()
PARTITION BY toYYYYMM(date)
ORDER BY (date, category) AS
SELECT 
    order_date AS date,
    category,
    count() AS order_count,
    uniqExact(user_id) AS user_count,
    sum(total_amount) AS total_revenue
FROM orders
WHERE status IN ('paid', 'shipped', 'completed')
GROUP BY 
    order_date,
    category;

-- 查询预聚合结果 (毫秒级)
SELECT 
    date,
    category,
    order_count,
    user_count,
    total_revenue
FROM daily_category_stats
WHERE date >= today() - 7
ORDER BY date DESC, total_revenue DESC;

-- 对比直接查询性能
SET max_threads = 1;

-- 直接查询
SELECT 
    order_date,
    category,
    count() AS order_count,
    uniqExact(user_id) AS user_count,
    sum(total_amount) AS total_revenue
FROM orders
WHERE order_date >= today() - 7
  AND status IN ('paid', 'shipped', 'completed')
GROUP BY order_date, category;

-- -----------------------------------------------------
-- 演示 4: 用户行为漏斗分析
-- -----------------------------------------------------

-- 创建用户行为日志 (Replicated)
DROP TABLE IF EXISTS user_funnel ON CLUSTER treasurycluster SYNC;
CREATE TABLE user_funnel ON CLUSTER treasurycluster (
    user_id UInt32,
    event_time DateTime,
    event_type LowCardinality(String),
    page LowCardinality(String)
) ENGINE = ReplicatedMergeTree()
PARTITION BY toYYYYMMDD(event_time)
ORDER BY (user_id, event_time);

-- 生成漏斗数据
INSERT INTO user_funnel
SELECT 
    number % 10000 AS user_id,
    toDateTime('2024-01-01') + (number % (7 * 24 * 3600)) + (number % 1000) AS event_time,
    ['page_view', 'add_to_cart', 'checkout', 'purchase'][number % 4 + 1] AS event_type,
    ['home', 'product', 'cart', 'payment'][number % 4 + 1] AS page
FROM numbers(500000);

-- 漏斗分析
-- 步骤1: 访问首页
-- 步骤2: 加入购物车  
-- 步骤3: 结账
-- 步骤4: 购买

WITH 
    -- 步骤1: 首页访问
    (SELECT uniqExact(user_id) FROM user_funnel WHERE event_type = 'page_view' AND event_time >= '2024-01-01') AS step1,
    -- 步骤2: 加入购物车
    (SELECT uniqExact(user_id) FROM user_funnel WHERE event_type = 'add_to_cart' AND event_time >= '2024-01-01') AS step2,
    -- 步骤3: 结账
    (SELECT uniqExact(user_id) FROM user_funnel WHERE event_type = 'checkout' AND event_time >= '2024-01-01') AS step3,
    -- 步骤4: 购买
    (SELECT uniqExact(user_id) FROM user_funnel WHERE event_type = 'purchase' AND event_time >= '2024-01-01') AS step4
SELECT 
    step1 AS page_view,
    step2 AS add_to_cart,
    step3 AS checkout,
    step4 AS purchase,
    round(step2 / step1 * 100, 2) AS step1_to_step2_rate,
    round(step3 / step2 * 100, 2) AS step2_to_step3_rate,
    round(step4 / step3 * 100, 2) AS step3_to_step4_rate,
    round(step4 / step1 * 100, 2) AS overall_conversion_rate;

-- 
-- ┌─────────────────────────────────────────────────────────────┐
-- │              漏斗分析结果示例                                 │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                             │
-- │  步骤              │ 用户数    │ 转化率                      │
-- │  ─────────────────┼───────────┼─────────                   │
-- │  访问首页         │  10,000   │  100%                      │
-- │  加入购物车       │  6,500    │  65%                       │
-- │  结账             │  3,200    │  49%                       │
-- │  购买             │  2,800    │  88%                       │
-- │                                                             │
-- │  整体转化率: 28%                                          │
-- │                                                             │
-- └─────────────────────────────────────────────────────────────┘

-- -----------------------------------------------------
-- 演示 5: 地理分布分析
-- -----------------------------------------------------

-- 创建带地理位置的订单表 (Replicated)
DROP TABLE IF EXISTS orders_geo ON CLUSTER treasurycluster SYNC;
CREATE TABLE orders_geo ON CLUSTER treasurycluster (
    order_id UInt64,
    user_id UInt32,
    order_time DateTime,
    country String,
    city String,
    latitude Float32,
    longitude Float32,
    amount Float64
) ENGINE = ReplicatedMergeTree()
ORDER BY order_time;

-- 生成带地理坐标的订单
INSERT INTO orders_geo
SELECT 
    number AS order_id,
    number % 50000 AS user_id,
    toDateTime('2024-01-01') + (number % (30 * 24 * 3600)) AS order_time,
    ['US', 'CN', 'UK', 'JP', 'DE', 'FR', 'BR', 'IN'][number % 8 + 1] AS country,
    'City_' || toString(number % 100) AS city,
    (rand() % 18000) / 100.0 - 90 AS latitude,
    (rand() % 36000) / 100.0 - 180 AS longitude,
    rand() % 1000 AS amount
FROM numbers(1000000);

-- 按国家统计
SELECT 
    country,
    count() AS orders,
    sum(amount) AS revenue,
    avg(amount) AS avg_amount
FROM orders_geo
GROUP BY country
ORDER BY revenue DESC;

-- 
-- ┌─────────────────────────────────────────────────────────────┐
-- │              演示总结                                         │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                             │
-- │  本次演示展示了 ClickHouse 的核心能力:                       │
-- │                                                             │
-- │  1. 实时分析 - 毫秒级响应                                   │
-- │  2. 高吞吐写入 - Buffer 表缓冲                              │
-- │  3. 预聚合优化 - 物化视图                                   │
│  │  4. 漏斗分析 - 用户转化分析                                 │
-- │  5. 地理分析 - 多维度统计                                   │
-- │                                                             │
-- │  性能数据:                                                  │
│  │  - 3000万行聚合查询: < 1秒                                 │
-- │  - 单表每秒写入: > 10万行                                  │
-- │  - 压缩率: 10-20x                                         │
-- │                                                             │
-- └─────────────────────────────────────────────────────────────┘

-- 清理演示数据
-- DROP DATABASE demo;

SELECT 
    '演示完成!' AS message,
    version() AS clickhouse_version;
