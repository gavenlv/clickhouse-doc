-- =====================================================
-- 06 - Live Demo Cases
-- =====================================================
-- Cluster: treasurycluster (2 replicas)
-- This file contains SQL code for live demos
-- =====================================================

-- -----------------------------------------------------
-- Demo 1: Real-time Analytics Dashboard
-- -----------------------------------------------------

-- Use playground database
USE playground;

-- Create e-commerce analytics table (Replicated)
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

-- Generate sample data (30 days × 100K orders = 3M rows)
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

-- Demo queries
-- 1. Today's order statistics
SELECT 
    count() AS today_orders,
    sum(total_amount) AS today_revenue,
    uniqExact(user_id) AS today_users
FROM orders
WHERE order_date = today();

-- 2. Past 7 days trend
SELECT 
    order_date,
    count() AS orders,
    sum(total_amount) AS revenue,
    uniqExact(user_id) AS users
FROM orders
WHERE order_date >= today() - 7
GROUP BY order_date
ORDER BY order_date;

-- 3. Category sales ranking
SELECT 
    category,
    count() AS orders,
    sum(total_amount) AS revenue,
    sum(quantity) AS products_sold
FROM orders
WHERE order_date >= today() - 30
GROUP BY category
ORDER BY revenue DESC;

-- 4. Hourly distribution
SELECT 
    toHour(order_time) AS hour,
    count() AS orders,
    sum(total_amount) AS revenue
FROM orders
WHERE order_date = today() - 1
GROUP BY hour
ORDER BY hour;

-- 5. User retention analysis
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
-- Demo 2: Real-time Data Pipeline
-- -----------------------------------------------------

-- Create real-time order table (Buffer demo, Replicated)
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

-- Simulate real-time writes
INSERT INTO orders_realtime_buffer 
SELECT 
    number + 10000000 AS order_id,
    number % 10000 AS user_id,
    now() AS event_time,
    ['order_created', 'order_paid', 'order_shipped'][number % 3 + 1] AS event_type,
    '{"key": "value"}' AS data
FROM numbers(1000);

-- View Buffer status
-- SELECT 
--     database,
--     table,
--     num_layers,
--     is_stale,
--     bytes
-- FROM system.buffers
-- WHERE database = 'playground';

-- Flush to main table
SYSTEM FLUSH TABLES orders_realtime_buffer;

SELECT count() FROM orders_realtime;

-- -----------------------------------------------------
-- Demo 3: Materialized View Pre-aggregation
-- -----------------------------------------------------

-- Create daily statistics materialized view (Replicated)
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

DROP MATERIALIZED VIEW IF EXISTS daily_category_stats_mv ON CLUSTER treasurycluster SYNC;
CREATE MATERIALIZED VIEW daily_category_stats_mv
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

-- Query pre-aggregated results (millisecond-level)
SELECT 
    date,
    category,
    order_count,
    user_count,
    total_revenue
FROM daily_category_stats
WHERE date >= today() - 7
ORDER BY date DESC, total_revenue DESC;

-- Compare direct query performance
SET max_threads = 1;

-- Direct query
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
-- Demo 4: User Behavior Funnel Analysis
-- -----------------------------------------------------

-- Create user behavior log (Replicated)
DROP TABLE IF EXISTS user_funnel ON CLUSTER treasurycluster SYNC;
CREATE TABLE user_funnel ON CLUSTER treasurycluster (
    user_id UInt32,
    event_time DateTime,
    event_type LowCardinality(String),
    page LowCardinality(String)
) ENGINE = ReplicatedMergeTree()
PARTITION BY toYYYYMMDD(event_time)
ORDER BY (user_id, event_time);

-- Generate funnel data
INSERT INTO user_funnel
SELECT 
    number % 10000 AS user_id,
    toDateTime('2024-01-01') + (number % (7 * 24 * 3600)) + (number % 1000) AS event_time,
    ['page_view', 'add_to_cart', 'checkout', 'purchase'][number % 4 + 1] AS event_type,
    ['home', 'product', 'cart', 'payment'][number % 4 + 1] AS page
FROM numbers(500000);

-- Funnel analysis
-- Step 1: View homepage
-- Step 2: Add to cart  
-- Step 3: Checkout
-- Step 4: Purchase

WITH 
    -- Step 1: Homepage view
    (SELECT uniqExact(user_id) FROM user_funnel WHERE event_type = 'page_view' AND event_time >= '2024-01-01') AS step1,
    -- Step 2: Add to cart
    (SELECT uniqExact(user_id) FROM user_funnel WHERE event_type = 'add_to_cart' AND event_time >= '2024-01-01') AS step2,
    -- Step 3: Checkout
    (SELECT uniqExact(user_id) FROM user_funnel WHERE event_type = 'checkout' AND event_time >= '2024-01-01') AS step3,
    -- Step 4: Purchase
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
-- │              Funnel Analysis Result Example                  │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                             │
-- │  Step            │ Users    │ Conversion Rate              │
-- │  ─────────────────┼───────────┼─────────                     │
-- │  View homepage   │  10,000   │  100%                        │
-- │  Add to cart     │  6,500    │  65%                         │
-- │  Checkout        │  3,200    │  49%                         │
-- │  Purchase        │  2,800    │  88%                         │
-- │                                                             │
-- │  Overall conversion rate: 28%                              │
-- │                                                             │
-- └─────────────────────────────────────────────────────────────┘

-- -----------------------------------------------------
-- Demo 5: Geographic Distribution Analysis
-- -----------------------------------------------------

-- Create orders table with geographic location (Replicated)
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

-- Generate orders with geographic coordinates
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

-- Statistics by country
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
-- │              Demo Summary                                   │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                             │
-- │  This demo showcases ClickHouse's core capabilities:         │
-- │                                                             │
-- │  1. Real-time analytics - Millisecond response             │
-- │  2. High throughput writes - Buffer table buffering         │
-- │  3. Pre-aggregation optimization - Materialized views       │
-- │  4. Funnel analysis - User conversion analysis             │
-- │  5. Geographic analysis - Multi-dimensional statistics     │
-- │                                                             │
-- │  Performance data:                                          │
-- │  - 30M row aggregation query: < 1s                        │
-- │  - Single table write per second: > 100K rows             │
-- │  - Compression ratio: 10-20x                              │
-- │                                                             │
-- └─────────────────────────────────────────────────────────────┘

-- Clean up demo data
-- DROP DATABASE demo;

SELECT 
    'Demo completed!' AS message,
    version() AS clickhouse_version;
