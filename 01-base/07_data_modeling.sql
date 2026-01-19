-- ========================================
-- ClickHouse 数据建模最佳实践
-- ========================================
-- 说明：ClickHouse 的数据建模与传统关系数据库有很大不同
-- 本文件涵盖宽表、星型模型、雪花模型、时序数据等场景
--
-- ⚠️ 重要提示：生产环境必须使用复制引擎 + ON CLUSTER
--    - 使用 ReplicatedMergeTree 系列引擎
--    - 添加 ON CLUSTER 'treasurycluster'
--    - 这保证 2 个副本都有数据，实现高可用
-- ========================================

-- ========================================
-- 1. 宽表模型（Wide Table）- ClickHouse 推荐
-- ========================================

-- 场景：用户行为分析，将多个指标存储在同一行
CREATE DATABASE IF NOT EXISTS modeling_examples;

-- 宽表：用户行为事件表（生产环境：使用复制引擎 + ON CLUSTER）
CREATE TABLE IF NOT EXISTS modeling_examples.user_events_wide ON CLUSTER 'treasurycluster' (
    event_id UInt64,
    user_id UInt64,
    session_id String,
    event_time DateTime,
    event_type String,
    
    -- 设备信息
    device_type String,      -- mobile, desktop, tablet
    os_name String,          -- iOS, Android, Windows, macOS
    browser_name String,      -- Chrome, Firefox, Safari
    screen_width UInt16,
    screen_height UInt16,
    
    -- 位置信息
    country_code String,
    city_name String,
    ip_address String,
    
    -- 业务指标
    page_url String,
    referrer_url String,
    campaign_source String,
    medium String,
    
    -- 数值指标
    duration_sec UInt32,
    scroll_depth Float32,
    interaction_count UInt16,
    
    -- 元数据
    created_at DateTime DEFAULT now(),
    data_version UInt64 DEFAULT 1
) ENGINE = ReplicatedMergeTree
PARTITION BY toYYYYMM(event_time)
ORDER BY (user_id, event_time, event_id)
SETTINGS index_granularity = 8192;

-- 插入示例数据
INSERT INTO modeling_examples.user_events_wide VALUES
(1, 100, 'session-001', '2024-01-01 10:00:00', 'page_view',
 'mobile', 'iOS', 'Safari', 375, 667,
 'US', 'New York', '192.168.1.1',
 'https://example.com/page1', 'https://google.com', 'google', 'organic',
 30, 0.5, 3, '2024-01-01 10:00:00', 1),
(2, 100, 'session-001', '2024-01-01 10:01:00', 'click',
 'mobile', 'iOS', 'Safari', 375, 667,
 'US', 'New York', '192.168.1.1',
 'https://example.com/page1', 'https://google.com', 'google', 'organic',
 0, 0.5, 1, '2024-01-01 10:01:00', 1),
(3, 101, 'session-002', '2024-01-01 10:00:00', 'page_view',
 'desktop', 'Windows', 'Chrome', 1920, 1080,
 'UK', 'London', '192.168.1.2',
 'https://example.com/page2', 'https://twitter.com', 'twitter', 'social',
 45, 0.8, 5, '2024-01-01 10:00:00', 1);

-- 查询示例：分析用户行为
SELECT
    user_id,
    count() as event_count,
    countDistinct(session_id) as session_count,
    sum(duration_sec) as total_duration,
    avg(duration_sec) as avg_duration,
    max(scroll_depth) as max_scroll_depth
FROM modeling_examples.user_events_wide
WHERE event_time >= '2024-01-01'
  AND event_time < '2024-02-01'
GROUP BY user_id
ORDER BY event_count DESC
LIMIT 10;

-- 宽表的优势：
-- 1. 查询性能高，无需 JOIN
-- 2. 减少数据冗余的负面影响
-- 3. 简化查询逻辑
-- 4. 适合列式存储

-- ========================================
-- 2. 星型模型（Star Schema）- 传统 OLAP 方案
-- ========================================

-- 事实表：订单事实表（生产环境：使用复制引擎 + ON CLUSTER）
CREATE TABLE IF NOT EXISTS modeling_examples.orders_fact ON CLUSTER 'treasurycluster' (
    order_id UInt64,
    user_id UInt64,
    product_id UInt64,
    quantity UInt32,
    unit_price Decimal(10, 2),
    total_amount Decimal(10, 2),
    discount_amount Decimal(10, 2),
    order_date Date,
    order_time DateTime,
    order_status String,  -- pending, completed, cancelled
    payment_method String,
    
    -- 外键（可选，ClickHouse 不强制外键约束）
    store_id UInt16,
    promotion_id UInt64,
    
    created_at DateTime DEFAULT now()
) ENGINE = ReplicatedMergeTree
PARTITION BY toYYYYMM(order_date)
ORDER BY (order_id, order_date)
SETTINGS index_granularity = 8192;

-- 维度表：用户维度（生产环境：使用复制引擎 + ON CLUSTER）
CREATE TABLE IF NOT EXISTS modeling_examples.users_dim ON CLUSTER 'treasurycluster' (
    user_id UInt64,
    user_name String,
    email String,
    country_code String,
    city_name String,
    age UInt8,
    gender String,  -- M, F, O
    user_segment String,  -- VIP, regular, new
    registration_date Date,
    last_login_date Date,
    
    updated_at DateTime DEFAULT now()
) ENGINE = ReplicatedMergeTree
ORDER BY user_id;

-- 维度表：产品维度（生产环境：使用复制引擎 + ON CLUSTER）
CREATE TABLE IF NOT EXISTS modeling_examples.products_dim ON CLUSTER 'treasurycluster' (
    product_id UInt64,
    product_name String,
    category String,
    subcategory String,
    brand String,
    price Decimal(10, 2),
    cost Decimal(10, 2),
    weight_kg Decimal(5, 2),
    description String,
    
    created_at DateTime DEFAULT now(),
    updated_at DateTime DEFAULT now()
) ENGINE = ReplicatedMergeTree
ORDER BY product_id;

-- 维度表：商店维度（生产环境：使用复制引擎 + ON CLUSTER）
CREATE TABLE IF NOT EXISTS modeling_examples.stores_dim ON CLUSTER 'treasurycluster' (
    store_id UInt16,
    store_name String,
    country_code String,
    city_name String,
    address String,
    store_type String,  -- online, offline
    open_date Date,
    
    updated_at DateTime DEFAULT now()
) ENGINE = ReplicatedMergeTree
ORDER BY store_id;

-- 插入维度数据
INSERT INTO modeling_examples.users_dim VALUES
(1, 'Alice', 'alice@example.com', 'US', 'New York', 28, 'F', 'VIP', '2023-01-01', '2024-01-01'),
(2, 'Bob', 'bob@example.com', 'UK', 'London', 35, 'M', 'regular', '2023-06-01', '2024-01-02'),
(3, 'Charlie', 'charlie@example.com', 'US', 'Los Angeles', 22, 'M', 'new', '2024-01-01', '2024-01-01');

INSERT INTO modeling_examples.products_dim VALUES
(1, 'Laptop Pro', 'Electronics', 'Computers', 'Apple', 1299.99, 1000.00, 2.1, 'High-performance laptop'),
(2, 'Wireless Mouse', 'Electronics', 'Accessories', 'Logitech', 29.99, 15.00, 0.1, 'Ergonomic mouse'),
(3, 'Office Chair', 'Furniture', 'Chairs', 'Herman Miller', 899.99, 600.00, 18.5, 'Ergonomic chair');

INSERT INTO modeling_examples.stores_dim VALUES
(1, 'New York Store', 'US', 'New York', '123 Main St', 'offline', '2020-01-01'),
(2, 'Online Store', 'US', 'New York', 'online', 'online', '2019-01-01');

-- 插入事实数据
INSERT INTO modeling_examples.orders_fact VALUES
(1, 1, 1, 2, 1299.99, 2599.98, 0.00, '2024-01-01', '2024-01-01 10:00:00', 'completed', 'credit_card', 1, 0),
(2, 2, 2, 3, 29.99, 89.97, 10.00, '2024-01-02', '2024-01-02 11:00:00', 'completed', 'paypal', 2, 1),
(3, 1, 3, 1, 899.99, 899.99, 50.00, '2024-01-03', '2024-01-03 12:00:00', 'pending', 'debit_card', 1, 0);

-- 星型模型查询：关联多个维度
SELECT
    o.order_id,
    o.order_date,
    o.total_amount,
    u.user_name,
    u.country_code as user_country,
    u.user_segment,
    p.product_name,
    p.category,
    p.brand,
    s.store_name,
    s.store_type
FROM modeling_examples.orders_fact o
LEFT JOIN modeling_examples.users_dim u ON o.user_id = u.user_id
LEFT JOIN modeling_examples.products_dim p ON o.product_id = p.product_id
LEFT JOIN modeling_examples.stores_dim s ON o.store_id = s.store_id
WHERE o.order_status = 'completed'
ORDER BY o.order_date DESC, o.order_time DESC
LIMIT 10;

-- 星型模型的优势：
-- 1. 结构清晰，易于理解
-- 2. 适合传统 BI 工具
-- 3. 维度数据独立维护
-- 4. 适合多维度分析

-- 注意：在 ClickHouse 中，可以考虑将维度数据直接去规范化到事实表中

-- ========================================
-- 3. 雪花模型（Snowflake Schema）
-- ========================================

-- 维度表：产品类别（生产环境：使用复制引擎 + ON CLUSTER）
CREATE TABLE IF NOT EXISTS modeling_examples.product_categories_dim ON CLUSTER 'treasurycluster' (
    category_id UInt32,
    category_name String,
    department String,  -- Electronics, Furniture, Clothing
    created_at DateTime DEFAULT now()
) ENGINE = ReplicatedMergeTree
ORDER BY category_id;

-- 维度表：产品子类别（生产环境：使用复制引擎 + ON CLUSTER）
CREATE TABLE IF NOT EXISTS modeling_examples.product_subcategories_dim ON CLUSTER 'treasurycluster' (
    subcategory_id UInt32,
    subcategory_name String,
    category_id UInt32,
    created_at DateTime DEFAULT now()
) ENGINE = ReplicatedMergeTree
ORDER BY subcategory_id;

-- 插入维度数据
INSERT INTO modeling_examples.product_categories_dim VALUES
(1, 'Computers', 'Electronics'),
(2, 'Accessories', 'Electronics'),
(3, 'Chairs', 'Furniture');

INSERT INTO modeling_examples.product_subcategories_dim VALUES
(1, 'Laptops', 1),
(2, 'Keyboards', 2),
(3, 'Ergonomic Chairs', 3);

-- 雪花模型查询：多层维度关联
SELECT
    o.order_id,
    p.product_name,
    sc.subcategory_name,
    c.category_name,
    c.department,
    o.total_amount
FROM modeling_examples.orders_fact o
LEFT JOIN modeling_examples.products_dim p ON o.product_id = p.product_id
LEFT JOIN modeling_examples.product_subcategories_dim sc ON p.subcategory = sc.subcategory_name
LEFT JOIN modeling_examples.product_categories_dim c ON sc.category_id = c.category_id
WHERE o.order_status = 'completed'
ORDER BY o.order_date DESC
LIMIT 10;

-- 雪花模型的优势：
-- 1. 减少数据冗余
-- 2. 维度数据易于维护
-- 3. 适合维度有层次结构的场景

-- 雪花模型的劣势：
-- 1. 需要多次 JOIN
-- 2. 查询性能较低
-- 3. 不适合高频查询场景

-- ========================================
-- 4. 时序数据模型（Time Series）
-- ========================================

-- 场景：IoT 传感器数据（生产环境：使用复制引擎 + ON CLUSTER）
CREATE TABLE IF NOT EXISTS modeling_examples.sensor_readings ON CLUSTER 'treasurycluster' (
    sensor_id UInt64,
    sensor_name String,
    sensor_type String,  -- temperature, humidity, pressure
    location String,
    
    -- 时间戳（使用 DateTime64 纳秒精度）
    reading_time DateTime64(3),
    
    -- 传感器读数
    value Float64,
    unit String,  -- Celsius, Percent, Pascal
    
    -- 质量指标
    quality_score UInt8,  -- 0-100
    is_anomalous UInt8 DEFAULT 0,  -- 0: normal, 1: anomalous
    
    -- 元数据
    battery_level UInt8,
    firmware_version String,
    
    created_at DateTime DEFAULT now()
) ENGINE = ReplicatedMergeTree
PARTITION BY toYYYYMMDD(reading_time)  -- 按天分区
ORDER BY (sensor_id, reading_time)
TTL reading_time + INTERVAL 180 DAY  -- 180 天后自动删除
SETTINGS index_granularity = 8192;

-- 插入时序数据（模拟每分钟的传感器读数）
INSERT INTO modeling_examples.sensor_readings VALUES
(1, 'Sensor-A1', 'temperature', 'Building-1-Floor-1', '2024-01-01 10:00:00.000', 23.5, 'Celsius', 95, 0, 85, 'v1.0'),
(1, 'Sensor-A1', 'temperature', 'Building-1-Floor-1', '2024-01-01 10:01:00.000', 23.6, 'Celsius', 96, 0, 85, 'v1.0'),
(1, 'Sensor-A1', 'temperature', 'Building-1-Floor-1', '2024-01-01 10:02:00.000', 23.8, 'Celsius', 97, 0, 85, 'v1.0'),
(2, 'Sensor-B1', 'humidity', 'Building-1-Floor-2', '2024-01-01 10:00:00.000', 45.2, 'Percent', 98, 0, 90, 'v1.0'),
(2, 'Sensor-B1', 'humidity', 'Building-1-Floor-2', '2024-01-01 10:01:00.000', 45.5, 'Percent', 98, 0, 90, 'v1.0'),
(2, 'Sensor-B1', 'humidity', 'Building-1-Floor-2', '2024-01-01 10:02:00.000', 45.8, 'Percent', 97, 0, 90, 'v1.0');

-- 时序查询：计算时间窗口内的统计值
SELECT
    sensor_id,
    sensor_name,
    toStartOfMinute(reading_time) as minute,
    avg(value) as avg_value,
    min(value) as min_value,
    max(value) as max_value,
    count() as reading_count,
    avg(quality_score) as avg_quality
FROM modeling_examples.sensor_readings
WHERE reading_time >= '2024-01-01 10:00:00'
  AND reading_time < '2024-01-01 10:05:00'
GROUP BY sensor_id, sensor_name, minute
ORDER BY minute, sensor_id;

-- 时序数据建模最佳实践：
-- 1. 使用 DateTime64 获取纳秒精度
-- 2. 按时间分区（天/小时）
-- 3. ORDER BY (sensor_id, reading_time)
-- 4. 设置 TTL 自动删除旧数据
-- 5. 考虑使用跳数索引加速范围查询

-- ========================================
-- 5. 日志数据模型（Log Data）
-- ========================================

-- 场景：应用日志分析（生产环境：使用复制引擎 + ON CLUSTER）
CREATE TABLE IF NOT EXISTS modeling_examples.application_logs ON CLUSTER 'treasurycluster' (
    -- 基础标识
    log_id UInt64,
    application_name String,
    service_name String,
    instance_id String,
    
    -- 日志级别和时间
    log_level String,  -- DEBUG, INFO, WARN, ERROR, FATAL
    log_time DateTime,
    
    -- 日志内容
    message String,
    exception_type String,
    exception_message String,
    stack_trace String,
    
    -- 请求信息
    request_id String,
    user_id UInt64,
    endpoint String,
    method String,  -- GET, POST, PUT, DELETE
    http_status UInt16,
    response_time_ms UInt32,
    
    -- 环境信息
    environment String,  -- dev, staging, prod
    region String,
    availability_zone String,
    
    -- 标签（JSON 格式存储）
    tags String,
    
    created_at DateTime DEFAULT now()
) ENGINE = ReplicatedMergeTree
PARTITION BY toYYYYMM(log_time)
ORDER BY (application_name, service_name, log_time, log_id)
SETTINGS index_granularity = 8192,
           min_compress_block_size = 65536,
           max_compress_block_size = 1048576;

-- 插入日志数据
INSERT INTO modeling_examples.application_logs VALUES
(1, 'order-service', 'order-api', 'instance-1', 'INFO', '2024-01-01 10:00:00',
 'Order created successfully', '', '', '', 'req-001', 100, '/api/orders', 'POST', 200, 45,
 'prod', 'us-east-1', 'us-east-1a', '{"request_source":"web"}', '2024-01-01 10:00:00'),
(2, 'order-service', 'order-api', 'instance-1', 'ERROR', '2024-01-01 10:00:05',
 'Payment processing failed', 'PaymentException', 'Insufficient funds', 'at com.example.OrderService', 'req-002', 101, '/api/orders', 'POST', 500, 120,
 'prod', 'us-east-1', 'us-east-1a', '{"payment_gateway":"stripe"}', '2024-01-01 10:00:05'),
(3, 'payment-service', 'payment-api', 'instance-1', 'INFO', '2024-01-01 10:00:10',
 'Payment initiated', '', '', '', 'req-002', 101, '/api/payments', 'POST', 202, 35,
 'prod', 'us-east-1', 'us-east-1a', '{"provider":"stripe"}', '2024-01-01 10:00:10');

-- 日志查询：错误分析
SELECT
    application_name,
    service_name,
    log_level,
    count() as error_count,
    countDistinct(exception_type) as exception_types,
    avg(response_time_ms) as avg_response_time,
    max(response_time_ms) as max_response_time
FROM modeling_examples.application_logs
WHERE log_time >= '2024-01-01'
  AND log_level IN ('ERROR', 'FATAL')
GROUP BY application_name, service_name, log_level
ORDER BY error_count DESC;

-- 日志查询：慢请求分析
SELECT
    endpoint,
    method,
    http_status,
    count() as request_count,
    avg(response_time_ms) as avg_response_time,
    quantile(0.50)(response_time_ms) as p50,
    quantile(0.95)(response_time_ms) as p95,
    quantile(0.99)(response_time_ms) as p99
FROM modeling_examples.application_logs
WHERE log_time >= '2024-01-01'
  AND http_status >= 200
  AND http_status < 500
GROUP BY endpoint, method, http_status
HAVING avg_response_time > 100
ORDER BY p95 DESC
LIMIT 10;

-- 日志数据建模最佳实践：
-- 1. 使用宽表存储所有字段
-- 2. 按应用和服务分区
-- 3. ORDER BY (app, service, time, id)
-- 4. 使用 TTL 自动删除旧日志
-- 5. 考虑使用物化视图进行预聚合

-- ========================================
-- 6. 用户行为分析模型（User Behavior）
-- ========================================

-- 事实表：用户行为事件（生产环境：使用复制引擎 + ON CLUSTER）
CREATE TABLE IF NOT EXISTS modeling_examples.user_behavior_events ON CLUSTER 'treasurycluster' (
    event_id UInt64,
    user_id UInt64,
    session_id String,
    event_time DateTime,
    
    -- 事件类型和子类型
    event_category String,  -- browse, search, purchase, engagement
    event_action String,    -- view, click, add_to_cart, checkout
    event_label String,
    
    -- 位置信息
    page_url String,
    referrer_url String,
    utm_source String,
    utm_medium String,
    utm_campaign String,
    
    -- 设备信息
    device_type String,
    os_name String,
    browser_name String,
    
    -- 数值指标
    value_amount Decimal(10, 2),
    quantity UInt32,
    duration_seconds UInt32,
    
    -- 元数据
    experiment_id String,
    experiment_variant String,
    
    created_at DateTime DEFAULT now()
) ENGINE = ReplicatedMergeTree
PARTITION BY toYYYYMM(event_time)
ORDER BY (user_id, event_time, event_id)
SETTINGS index_granularity = 8192;

-- 物化视图：用户每日统计（生产环境：使用复制聚合引擎 + ON CLUSTER）
CREATE MATERIALIZED VIEW IF NOT EXISTS modeling_examples.user_daily_stats ON CLUSTER 'treasurycluster'
ENGINE = ReplicatedSummingMergeTree
ORDER BY (user_id, event_date)
AS SELECT
    user_id,
    toDate(event_time) as event_date,
    count() as total_events,
    sumIf(value_amount, event_category = 'purchase') as total_revenue,
    sum(quantity) as total_quantity,
    uniqExact(session_id) as sessions,
    avg(duration_seconds) as avg_duration,
    countIf(event_action = 'add_to_cart') as add_to_cart_count,
    countIf(event_action = 'checkout') as checkout_count
FROM modeling_examples.user_behavior_events
GROUP BY user_id, toDate(event_time);

-- 插入用户行为数据
INSERT INTO modeling_examples.user_behavior_events VALUES
(1, 100, 'session-001', '2024-01-01 10:00:00',
 'browse', 'view', 'homepage', 
 'https://example.com/', '', 'google', 'organic', 'campaign-001',
 'desktop', 'Windows', 'Chrome', 0.00, 0, 5,
 'exp-001', 'variant-A', '2024-01-01 10:00:00'),
(2, 100, 'session-001', '2024-01-01 10:01:00',
 'browse', 'click', 'product-page',
 'https://example.com/product/1', 'https://example.com/', 'google', 'organic', 'campaign-001',
 'desktop', 'Windows', 'Chrome', 0.00, 0, 0,
 'exp-001', 'variant-A', '2024-01-01 10:01:00'),
(3, 100, 'session-001', '2024-01-01 10:05:00',
 'purchase', 'checkout', 'checkout-page',
 'https://example.com/checkout', 'https://example.com/product/1', 'google', 'organic', 'campaign-001',
 'desktop', 'Windows', 'Chrome', 1299.99, 1, 120,
 'exp-001', 'variant-A', '2024-01-01 10:05:00');

-- 查询用户每日统计（物化视图自动聚合）
SELECT * FROM modeling_examples.user_daily_stats 
WHERE event_date >= '2024-01-01'
ORDER BY event_date DESC, total_revenue DESC
LIMIT 10;

-- 漏斗分析：浏览 → 点击 → 购买
SELECT
    event_date,
    countDistinct(user_id) as total_users,
    countDistinctIf(user_id, event_action = 'view') as browse_users,
    countDistinctIf(user_id, event_action = 'click') as click_users,
    countDistinctIf(user_id, event_action = 'checkout') as checkout_users,
    countDistinctIf(user_id, event_category = 'purchase') as purchase_users,
    round(browse_users * 100.0 / total_users, 2) as browse_conversion,
    round(click_users * 100.0 / browse_users, 2) as click_to_browse,
    round(checkout_users * 100.0 / click_users, 2) as checkout_to_click,
    round(purchase_users * 100.0 / checkout_users, 2) as purchase_to_checkout
FROM modeling_examples.user_behavior_events
WHERE event_time >= '2024-01-01'
GROUP BY toDate(event_time) as event_date
ORDER BY event_date;

-- ========================================
-- 7. 主键和排序键设计原则
-- ========================================

-- 场景 1：高基数查询（生产环境：使用复制引擎 + ON CLUSTER）
CREATE TABLE IF NOT EXISTS modeling_examples.table_high_cardinality ON CLUSTER 'treasurycluster' (
    -- 主键：高基数列在前
    user_id UInt64,
    event_time DateTime,
    event_type String,
    event_id UInt64,
    data String
) ENGINE = ReplicatedMergeTree
PARTITION BY toYYYYMM(event_time)
ORDER BY (user_id, event_time, event_id)
-- 原则：高基数列在前，时间列在后

-- 场景 2：范围查询（生产环境：使用复制引擎 + ON CLUSTER）
CREATE TABLE IF NOT EXISTS modeling_examples.table_range_query ON CLUSTER 'treasurycluster' (
    sensor_id UInt64,
    reading_time DateTime,
    value Float64,
    reading_id UInt64
) ENGINE = ReplicatedMergeTree
PARTITION BY toYYYYMMDD(reading_time)
ORDER BY (sensor_id, reading_time)
-- 原则：时间范围查询，时间列必须在前或第二个位置

-- 场景 3：多条件查询（生产环境：使用复制引擎 + ON CLUSTER）
CREATE TABLE IF NOT EXISTS modeling_examples.table_multi_condition ON CLUSTER 'treasurycluster' (
    user_id UInt64,
    product_id UInt64,
    order_date Date,
    order_time DateTime,
    order_id UInt64,
    amount Decimal(10, 2)
) ENGINE = ReplicatedMergeTree
PARTITION BY toYYYYMM(order_date)
ORDER BY (user_id, order_date, order_time, order_id)
-- 原则：最常用的过滤条件在前

-- 查询性能对比
-- 快速查询：WHERE user_id = ? AND order_date BETWEEN ? AND ?
-- 慢速查询：WHERE amount > ?  (amount 不在 ORDER BY 中)

-- ========================================
-- 8. 分区键设计策略
-- ========================================

-- 策略 1：按月分区（适合数据量大的场景，生产环境：使用复制引擎 + ON CLUSTER）
CREATE TABLE IF NOT EXISTS modeling_examples.partition_by_month ON CLUSTER 'treasurycluster' (
    event_id UInt64,
    user_id UInt64,
    event_time DateTime,
    data String
) ENGINE = ReplicatedMergeTree
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_time, event_id);

-- 策略 2：按日分区（适合高频查询场景，生产环境：使用复制引擎 + ON CLUSTER）
CREATE TABLE IF NOT EXISTS modeling_examples.partition_by_day ON CLUSTER 'treasurycluster' (
    event_id UInt64,
    user_id UInt64,
    event_time DateTime,
    data String
) ENGINE = ReplicatedMergeTree
PARTITION BY toYYYYMMDD(event_time)
ORDER BY (event_time, event_id);

-- 策略 3：按业务维度+时间分区（适合多维度查询，生产环境：使用复制引擎 + ON CLUSTER）
CREATE TABLE IF NOT EXISTS modeling_examples.partition_by_business ON CLUSTER 'treasurycluster' (
    event_id UInt64,
    user_id UInt64,
    event_time DateTime,
    event_type String,
    data String
) ENGINE = ReplicatedMergeTree
PARTITION BY (event_type, toYYYYMM(event_time))
ORDER BY (event_time, event_id);

-- 策略 4：自定义分区（适合特定业务需求，生产环境：使用复制引擎 + ON CLUSTER）
CREATE TABLE IF NOT EXISTS modeling_examples.partition_custom ON CLUSTER 'treasurycluster' (
    event_id UInt64,
    user_id UInt64,
    event_time DateTime,
    region String,
    data String
) ENGINE = ReplicatedMergeTree
PARTITION BY (region, toYYYYMM(event_time))
ORDER BY (event_time, event_id);

-- 分区查询：查看分区信息
SELECT
    partition,
    name,
    rows,
    bytes_on_disk,
    formatReadableSize(bytes_on_disk) as readable_size,
    min_date,
    max_date
FROM system.parts
WHERE table = 'partition_by_month'
  AND database = 'modeling_examples'
  AND active
ORDER BY partition;

-- 分区管理：删除旧分区
ALTER TABLE modeling_examples.partition_by_month DROP PARTITION '202301';

-- 分区设计原则：
-- 1. 分区大小：建议 50-100GB 每分区
-- 2. 分区数量：避免超过 100 个分区
-- 3. 按时间分区：最常用的策略
-- 4. 按业务分区：适合特定查询模式
-- 5. 避免小分区：小分区会增加元数据开销

-- ========================================
-- 9. 数据类型选择优化
-- ========================================

-- 场景 1：数值类型优化（生产环境：使用复制引擎 + ON CLUSTER）
CREATE TABLE IF NOT EXISTS modeling_examples.optimized_numeric_types ON CLUSTER 'treasurycluster' (
    -- 整数类型：根据范围选择
    tiny_int UInt8,        -- 0-255
    small_int UInt16,       -- 0-65535
    medium_int UInt32,      -- 0-4294967295
    big_int UInt64,         -- 0-18446744073709551615
    
    -- 有符号整数
    signed_int Int32,        -- -2147483648 到 2147483647
    
    -- 浮点类型
    float_value Float32,      -- 单精度，7位有效数字
    double_value Float64,     -- 双精度，15位有效数字
    
    -- Decimal 类型（精确计算）
    price Decimal(10, 2),   -- 10位数字，2位小数
    amount Decimal(18, 4)    -- 18位数字，4位小数
    
    id UInt64,
    created_at DateTime DEFAULT now()
) ENGINE = ReplicatedMergeTree
ORDER BY id;

-- 场景 2：字符串类型优化（生产环境：使用复制引擎 + ON CLUSTER）
CREATE TABLE IF NOT EXISTS modeling_examples.optimized_string_types ON CLUSTER 'treasurycluster' (
    -- String 类型
    short_text String,
    long_text String,
    
    -- FixedString 类型（长度固定）
    fixed_code FixedString(10),  -- 10字符固定长度
    
    -- LowCardinality 类型（低基数字符串）
    status LowCardinality(String),  -- 适合基数低的列
    country LowCardinality(String),
    city LowCardinality(String),
    
    -- UUID 类型
    event_uuid UUID,
    user_uuid UUID,
    
    id UInt64,
    created_at DateTime DEFAULT now()
) ENGINE = ReplicatedMergeTree
ORDER BY id;

-- 插入测试数据
INSERT INTO modeling_examples.optimized_string_types VALUES
('Short text', 'This is a long text that contains multiple words and sentences.',
 'CODE12345', 'active', 'US', 'New York',
 generateUUIDv4(), generateUUIDv4(), 1, now()),
('Another', 'More long text here for testing purposes only.',
 'CODE67890', 'inactive', 'UK', 'London',
 generateUUIDv4(), generateUUIDv4(), 2, now());

-- 数据类型选择原则：
-- 1. 整数：使用最小范围类型（UInt8 vs UInt64）
-- 2. 浮点：根据精度要求选择（Float32 vs Float64）
-- 3. 精确计算：使用 Decimal
-- 4. 低基数：使用 LowCardinality(String)
-- 5. 固定长度：使用 FixedString
-- 6. UUID：使用专用 UUID 类型

-- ========================================
-- 10. 物化视图在数据建模中的应用
-- ========================================

-- 原始事实表：销售数据（生产环境：使用复制引擎 + ON CLUSTER）
CREATE TABLE IF NOT EXISTS modeling_examples.sales_raw ON CLUSTER 'treasurycluster' (
    sale_id UInt64,
    product_id UInt64,
    user_id UInt64,
    quantity UInt32,
    unit_price Decimal(10, 2),
    sale_date Date,
    sale_time DateTime,
    store_id UInt16,
    region String,
    category String
) ENGINE = ReplicatedMergeTree
PARTITION BY toYYYYMM(sale_date)
ORDER BY (sale_date, product_id, sale_id);

-- 物化视图 1：按产品汇总（生产环境：使用复制聚合引擎 + ON CLUSTER）
CREATE MATERIALIZED VIEW IF NOT EXISTS modeling_examples.sales_by_product ON CLUSTER 'treasurycluster'
ENGINE = ReplicatedSummingMergeTree
ORDER BY (product_id, sale_date)
AS SELECT
    product_id,
    sale_date,
    sum(quantity) as total_quantity,
    sum(unit_price * quantity) as total_revenue,
    count() as sale_count
FROM modeling_examples.sales_raw
GROUP BY product_id, sale_date;

-- 物化视图 2：按地区汇总（生产环境：使用复制聚合引擎 + ON CLUSTER）
CREATE MATERIALIZED VIEW IF NOT EXISTS modeling_examples.sales_by_region ON CLUSTER 'treasurycluster'
ENGINE = ReplicatedSummingMergeTree
ORDER BY (region, sale_date)
AS SELECT
    region,
    sale_date,
    sum(quantity) as total_quantity,
    sum(unit_price * quantity) as total_revenue,
    count() as sale_count
FROM modeling_examples.sales_raw
GROUP BY region, sale_date;

-- 物化视图 3：按类别汇总（生产环境：使用复制聚合引擎 + ON CLUSTER）
CREATE MATERIALIZED VIEW IF NOT EXISTS modeling_examples.sales_by_category ON CLUSTER 'treasurycluster'
ENGINE = ReplicatedSummingMergeTree
ORDER BY (category, sale_date)
AS SELECT
    category,
    sale_date,
    sum(quantity) as total_quantity,
    sum(unit_price * quantity) as total_revenue,
    count() as sale_count
FROM modeling_examples.sales_raw
GROUP BY category, sale_date;

-- 插入原始数据
INSERT INTO modeling_examples.sales_raw VALUES
(1, 1, 100, 2, 1299.99, '2024-01-01', '2024-01-01 10:00:00', 1, 'US', 'Electronics'),
(2, 2, 101, 5, 29.99, '2024-01-01', '2024-01-01 11:00:00', 1, 'US', 'Electronics'),
(3, 3, 100, 1, 899.99, '2024-01-01', '2024-01-01 12:00:00', 1, 'US', 'Furniture'),
(4, 1, 102, 3, 1299.99, '2024-01-02', '2024-01-02 10:00:00', 2, 'UK', 'Electronics'),
(5, 2, 103, 2, 29.99, '2024-01-02', '2024-01-02 11:00:00', 2, 'UK', 'Electronics');

-- 查询物化视图数据（自动聚合）
-- 按产品汇总
SELECT * FROM modeling_examples.sales_by_product 
ORDER BY sale_date DESC, total_revenue DESC;

-- 按地区汇总
SELECT * FROM modeling_examples.sales_by_region 
ORDER BY sale_date DESC, total_revenue DESC;

-- 按类别汇总
SELECT * FROM modeling_examples.sales_by_category 
ORDER BY sale_date DESC, total_revenue DESC;

-- 物化视图优势：
-- 1. 自动聚合，无需手动触发
-- 2. 提高查询性能
-- 3. 实时数据更新
-- 4. 适合预聚合场景

-- ========================================
-- 11. 布隆索引和跳数索引
-- ========================================

-- 创建带跳数索引的表（生产环境：使用复制引擎 + ON CLUSTER）
CREATE TABLE IF NOT EXISTS modeling_examples.table_with_skip_index ON CLUSTER 'treasurycluster' (
    user_id UInt64,
    session_id String,
    event_time DateTime,
    event_type String,
    url String,
    user_agent String,
    tags String,
    event_id UInt64
) ENGINE = ReplicatedMergeTree
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_time, event_id)

-- 跳数索引 1：minmax 索引（默认）
-- 自动为数值、日期、时间类型创建

-- 跳数索引 2：set 索引（适合枚举值）
INDEX idx_event_type event_type TYPE set(0) GRANULARITY 4

-- 跳数索引 3：bloom_filter 索引（适合高基数字符串）
INDEX idx_session_id session_id TYPE bloom_filter(0.01) GRANULARITY 1

-- 跳数索引 4：tokenbf_v1 索引（适合长文本）
INDEX idx_url url TYPE tokenbf_v1(512, 3, 0) GRANULARITY 4

-- 跳数索引 5：ngrambf_v1 索引（适合模糊搜索）
INDEX idx_user_agent user_agent TYPE ngrambf_v1(3, 256, 2, 0) GRANULARITY 4

SETTINGS index_granularity = 8192;

-- 插入测试数据
INSERT INTO modeling_examples.table_with_skip_index VALUES
(1, 'session-001', '2024-01-01 10:00:00', 'page_view', 'https://example.com/page1', 'Mozilla/5.0', '{"page":"home"}', 1),
(2, 'session-001', '2024-01-01 10:01:00', 'click', 'https://example.com/page1', 'Mozilla/5.0', '{"page":"home"}', 2),
(3, 'session-002', '2024-01-01 10:00:00', 'page_view', 'https://example.com/page2', 'Chrome/120.0', '{"page":"about"}', 3);

-- 查询测试：使用跳数索引加速
-- 会使用 idx_event_type 索引
SELECT count() FROM modeling_examples.table_with_skip_index 
WHERE event_time >= '2024-01-01' AND event_type = 'page_view';

-- 会使用 idx_session_id 索引
SELECT * FROM modeling_examples.table_with_skip_index 
WHERE session_id = 'session-001';

-- 会使用 idx_url 索引
SELECT * FROM modeling_examples.table_with_skip_index 
WHERE url LIKE '%example.com%';

-- 查看索引使用情况
SELECT
    table,
    name,
    type,
    expr,
    index_granularity,
    data_compressed_bytes,
    data_uncompressed_bytes,
    marks_count
FROM system.data_skipping_indices
WHERE database = 'modeling_examples'
  AND table = 'table_with_skip_index';

-- 跳数索引选择：
-- 1. set: 适合基数低的枚举值（如状态、类型）
-- 2. bloom_filter: 适合高基数字符串（如 ID）
-- 3. tokenbf_v1: 适合长文本搜索（如 URL）
-- 4. ngrambf_v1: 适合模糊搜索（如用户代理）

-- ========================================
-- 12. 分层存储策略
-- ========================================

-- 创建分层存储配置（需要在服务器配置中定义存储策略）
-- 这里展示表级别的 TTL 分层

CREATE TABLE IF NOT EXISTS modeling_examples.tiered_storage ON CLUSTER 'treasurycluster' (
    event_id UInt64,
    user_id UInt64,
    event_time DateTime,
    data String,
    created_at DateTime DEFAULT now()
) ENGINE = ReplicatedMergeTree
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_time, event_id)

-- 分层 TTL：数据自动迁移
-- 注意：需要配置不同的存储卷（default、ssd、hdd）
TTL 
    event_time + INTERVAL 7 DAY TO DISK 'default',   -- 7天后移到默认存储
    event_time + INTERVAL 30 DAY TO DISK 'ssd',      -- 30天后移到 SSD
    event_time + INTERVAL 90 DAY TO DISK 'hdd',       -- 90天后移到 HDD
    event_time + INTERVAL 365 DAY DELETE             -- 1年后删除

SETTINGS index_granularity = 8192;

-- 查看数据分布
SELECT
    partition,
    name,
    disk_name,
    rows,
    bytes_on_disk
FROM system.parts
WHERE table = 'tiered_storage'
  AND database = 'modeling_examples'
  AND active
ORDER BY event_time;

-- 分层存储优势：
-- 1. 降低成本：热数据用 SSD，冷数据用 HDD
-- 2. 优化性能：频繁访问的数据在快速存储
-- 3. 自动管理：TTL 自动迁移数据

-- ========================================
-- 13. 去规范化 vs 规范化
-- ========================================

-- 规范化模型：多个关联表（生产环境：使用复制引擎 + ON CLUSTER）
CREATE TABLE IF NOT EXISTS modeling_examples.normalized_users ON CLUSTER 'treasurycluster' (
    user_id UInt64,
    user_name String,
    email String,
    updated_at DateTime DEFAULT now()
) ENGINE = ReplicatedMergeTree
ORDER BY user_id;

CREATE TABLE IF NOT EXISTS modeling_examples.normalized_orders ON CLUSTER 'treasurycluster' (
    order_id UInt64,
    user_id UInt64,
    product_id UInt64,
    quantity UInt32,
    order_date Date,
    created_at DateTime DEFAULT now()
) ENGINE = ReplicatedMergeTree
PARTITION BY toYYYYMM(order_date)
ORDER BY order_id;

CREATE TABLE IF NOT EXISTS modeling_examples.normalized_products ON CLUSTER 'treasurycluster' (
    product_id UInt64,
    product_name String,
    category String,
    price Decimal(10, 2),
    updated_at DateTime DEFAULT now()
) ENGINE = ReplicatedMergeTree
ORDER BY product_id;

-- 去规范化模型：宽表（生产环境：使用复制引擎 + ON CLUSTER）
CREATE TABLE IF NOT EXISTS modeling_examples.denormalized_orders ON CLUSTER 'treasurycluster' (
    order_id UInt64,
    user_id UInt64,
    user_name String,
    user_email String,
    product_id UInt64,
    product_name String,
    product_category String,
    product_price Decimal(10, 2),
    quantity UInt32,
    total_amount Decimal(10, 2),
    order_date Date,
    created_at DateTime DEFAULT now()
) ENGINE = ReplicatedMergeTree
PARTITION BY toYYYYMM(order_date)
ORDER BY order_id;

-- 查询性能对比
-- 规范化：需要 JOIN
SELECT
    o.order_id,
    u.user_name,
    p.product_name,
    o.quantity
FROM modeling_examples.normalized_orders o
LEFT JOIN modeling_examples.normalized_users u ON o.user_id = u.user_id
LEFT JOIN modeling_examples.normalized_products p ON o.product_id = p.product_id
WHERE o.order_date >= '2024-01-01'
ORDER BY o.order_id;

-- 去规范化：无需 JOIN
SELECT
    order_id,
    user_name,
    product_name,
    quantity
FROM modeling_examples.denormalized_orders
WHERE order_date >= '2024-01-01'
ORDER BY order_id;

-- ClickHouse 建议：
-- 1. 优先使用去规范化（宽表）
-- 2. 减少不必要的 JOIN
-- 3. 只在必要时保留维度表
-- 4. 使用物化视图预聚合

-- ========================================
-- 14. 实时数据流模型（Real-time Data Pipeline）
-- ========================================

-- 原始事件流（生产环境：使用复制引擎 + ON CLUSTER）
CREATE TABLE IF NOT EXISTS modeling_examples.event_stream ON CLUSTER 'treasurycluster' (
    event_id UInt64,
    event_type String,
    user_id UInt64,
    payload String,
    event_time DateTime DEFAULT now()
) ENGINE = ReplicatedMergeTree
ORDER BY (event_time, event_id);

-- 实时聚合视图：5分钟窗口（生产环境：使用复制聚合引擎 + ON CLUSTER）
CREATE MATERIALIZED VIEW IF NOT EXISTS modeling_examples.realtime_5min_stats ON CLUSTER 'treasurycluster'
ENGINE = ReplicatedSummingMergeTree
ORDER BY (toStartOfFiveMinutes(event_time), event_type)
AS SELECT
    toStartOfFiveMinutes(event_time) as time_bucket,
    event_type,
    count() as event_count,
    countDistinct(user_id) as unique_users
FROM modeling_examples.event_stream
GROUP BY time_bucket, event_type;

-- 实时聚合视图：1小时窗口（生产环境：使用复制聚合引擎 + ON CLUSTER）
CREATE MATERIALIZED VIEW IF NOT EXISTS modeling_examples.realtime_1hour_stats ON CLUSTER 'treasurycluster'
ENGINE = ReplicatedSummingMergeTree
ORDER BY (toStartOfHour(event_time), event_type)
AS SELECT
    toStartOfHour(event_time) as time_bucket,
    event_type,
    sum(event_count) as total_events,
    sum(unique_users) as total_users
FROM modeling_examples.realtime_5min_stats
GROUP BY time_bucket, event_type;

-- 插入事件流
INSERT INTO modeling_examples.event_stream VALUES
(1, 'click', 100, '{"page":"home"}', '2024-01-01 10:00:00'),
(2, 'click', 101, '{"page":"home"}', '2024-01-01 10:01:00'),
(3, 'click', 102, '{"page":"home"}', '2024-01-01 10:02:00'),
(4, 'view', 100, '{"page":"product"}', '2024-01-01 10:03:00'),
(5, 'purchase', 100, '{"product_id":1}', '2024-01-01 10:04:00'),
(6, 'click', 103, '{"page":"home"}', '2024-01-01 10:05:00');

-- 查询实时统计
-- 5分钟统计
SELECT * FROM modeling_examples.realtime_5min_stats
ORDER BY time_bucket DESC;

-- 1小时统计
SELECT * FROM modeling_examples.realtime_1hour_stats
ORDER BY time_bucket DESC;

-- ========================================
-- 15. 数据建模最佳实践总结
-- ========================================

/*
ClickHouse 数据建模核心原则：

1. 宽表优先
   - 优先使用宽表而非星型/雪花模型
   - 减少 JOIN 操作
   - 提高查询性能

2. 主键和排序键设计
   - 高基数列在前
   - 常用过滤条件在前
   - 时间列通常放在中间或后面

3. 分区策略
   - 按时间分区（最常用）
   - 分区大小：50-100GB
   - 分区数量：< 100 个

4. 数据类型优化
   - 使用最小类型（UInt8 vs UInt64）
   - 低基数使用 LowCardinality
   - 精确计算使用 Decimal

5. 物化视图
   - 用于预聚合
   - 自动更新
   - 提高查询性能

6. 索引策略
   - 使用跳数索引
   - bloom_filter 适合高基数
   - set 适合枚举值

7. TTL 和分层存储
   - 自动删除过期数据
   - 热数据 SSD，冷数据 HDD
   - 降低存储成本

8. 去规范化 vs 规范化
   - 优先去规范化
   - 减少关联表
   - 简化查询逻辑

9. 实时数据处理
   - 使用物化视图
   - 多级聚合
   - 窗口函数

10. 性能测试
    - 实际查询测试
    - 监控查询性能
    - 持续优化
*/

-- ========================================
-- 16. 清理测试数据（生产环境：使用 ON CLUSTER SYNC 确保集群范围删除）
-- ========================================

DROP TABLE IF EXISTS modeling_examples.user_events_wide ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS modeling_examples.orders_fact ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS modeling_examples.users_dim ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS modeling_examples.products_dim ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS modeling_examples.stores_dim ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS modeling_examples.product_categories_dim ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS modeling_examples.product_subcategories_dim ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS modeling_examples.sensor_readings ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS modeling_examples.application_logs ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS modeling_examples.user_behavior_events ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS modeling_examples.user_daily_stats ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS modeling_examples.table_high_cardinality ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS modeling_examples.table_range_query ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS modeling_examples.table_multi_condition ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS modeling_examples.partition_by_month ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS modeling_examples.partition_by_day ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS modeling_examples.partition_by_business ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS modeling_examples.partition_custom ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS modeling_examples.optimized_numeric_types ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS modeling_examples.optimized_string_types ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS modeling_examples.sales_raw ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS modeling_examples.sales_by_product ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS modeling_examples.sales_by_region ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS modeling_examples.sales_by_category ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS modeling_examples.table_with_skip_index ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS modeling_examples.tiered_storage ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS modeling_examples.normalized_users ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS modeling_examples.normalized_orders ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS modeling_examples.normalized_products ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS modeling_examples.denormalized_orders ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS modeling_examples.event_stream ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS modeling_examples.realtime_5min_stats ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS modeling_examples.realtime_1hour_stats ON CLUSTER 'treasurycluster' SYNC;

DROP DATABASE IF EXISTS modeling_examples ON CLUSTER 'treasurycluster' SYNC;
