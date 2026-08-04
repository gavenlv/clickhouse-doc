-- ============================================================
-- 04 - 字典深度
-- 描述：字典是内存中的键值对，比 JOIN 快 100x
-- 适用版本：ClickHouse 25.12+
-- ============================================================

-- 【原理】字典的核心概念
-- ============================================================
-- 1. 字典是内存中的键值对存储结构
-- 2. 查询时通过 dictGet() 函数直接获取，无需 JOIN
-- 3. 比 JOIN 快 100 倍以上（内存访问 vs 磁盘 I/O）
-- 4. 支持自动刷新（LIFETIME 机制）
-- 5. 支持 6 种布局（HASHED, COMPLEX_KEY_HASHED, RANGE_HASHED, CACHE, COMPLEX_KEY_CACHE, SSD_CACHE）
-- 6. 适合存储维度数据（用户信息、商品信息、地理信息等）
-- ============================================================

DROP DATABASE IF EXISTS modeling_test;
CREATE DATABASE modeling_test;
USE modeling_test;

-- ============================================================
-- 实验一：6 种字典布局详解
-- ============================================================

-- 【场景】创建不同类型的字典，对比使用方式

-- -----------------------------------------------------------
-- 1. HASHED 布局（默认）
-- 【原理】将整个字典加载到内存中的哈希表
-- 【适用】数据量 < 1000 万行，单键场景
-- 键类型：UInt64
-- -----------------------------------------------------------

-- 先创建数据源表
CREATE TABLE dim_city
(
    city_id   UInt64,
    city_name String,
    province  String,
    country   String,
    population UInt64
)
ENGINE = MergeTree
ORDER BY city_id;

INSERT INTO dim_city VALUES
    (1, 'Beijing', 'Beijing', 'China', 21540000),
    (2, 'Shanghai', 'Shanghai', 'China', 24870000),
    (3, 'Guangzhou', 'Guangdong', 'China', 18680000),
    (4, 'Shenzhen', 'Guangdong', 'China', 17560000),
    (5, 'Hangzhou', 'Zhejiang', 'China', 11940000);

-- 在 ClickHouse 中创建字典（需要在配置文件中定义，或使用 DDL 创建）
-- CH 25.12 支持通过 DDL 创建字典（需要 allow_experimental_ddl_dictionaries = 1）

-- 使用 DDL 创建 HASHED 字典
CREATE DICTIONARY dict_city_hashed
(
    city_id   UInt64,
    city_name String,
    province  String,
    country   String,
    population UInt64
)
PRIMARY KEY city_id
SOURCE(CLICKHOUSE(TABLE 'dim_city'))
LAYOUT(HASHED())
LIFETIME(MIN 300 MAX 600);

-- 查询字典
SELECT '【HASHED 字典】查询城市信息:';
SELECT dictGet('modeling_test.dict_city_hashed', 'city_name', toUInt64(1));
SELECT dictGet('modeling_test.dict_city_hashed', 'province', toUInt64(2));
SELECT dictGet('modeling_test.dict_city_hashed', 'population', toUInt64(3));

-- 批量查询
SELECT '【HASHED 字典】批量查询:';
SELECT
    city_id,
    dictGet('modeling_test.dict_city_hashed', 'city_name', city_id) AS city_name,
    dictGet('modeling_test.dict_city_hashed', 'province', city_id) AS province
FROM system.numbers
WHERE city_id IN (1, 2, 3, 4, 5)
LIMIT 5;

-- -----------------------------------------------------------
-- 2. COMPLEX_KEY_HASHED 布局
-- 【原理】支持复合键（多个字段组合作为键）
-- 【适用】复合键场景
-- 键类型：Tuple(key1, key2, ...)
-- -----------------------------------------------------------

-- 创建复合键数据源
CREATE TABLE dim_product_complex
(
    product_id  UInt64,
    sku_code    String,
    product_name String,
    category    String,
    price       Decimal(10, 2)
)
ENGINE = MergeTree
ORDER BY (product_id, sku_code);

INSERT INTO dim_product_complex VALUES
    (1, 'SKU-001', 'iPhone 15', 'Electronics', 6999.00),
    (1, 'SKU-002', 'iPhone 15 Pro', 'Electronics', 8999.00),
    (2, 'SKU-003', 'MacBook Air', 'Electronics', 9499.00);

-- 创建 COMPLEX_KEY_HASHED 字典
CREATE DICTIONARY dict_product_complex
(
    product_id  UInt64,
    sku_code    String,
    product_name String,
    category    String,
    price       Decimal(10, 2)
)
PRIMARY KEY product_id, sku_code
SOURCE(CLICKHOUSE(TABLE 'dim_product_complex'))
LAYOUT(COMPLEX_KEY_HASHED())
LIFETIME(MIN 300 MAX 600);

-- 查询复合键字典
SELECT '【COMPLEX_KEY_HASHED 字典】复合键查询:';
SELECT dictGet('modeling_test.dict_product_complex', 'product_name',
               tuple(toUInt64(1), 'SKU-001'));
SELECT dictGet('modeling_test.dict_product_complex', 'price',
               tuple(toUInt64(1), 'SKU-002'));

-- -----------------------------------------------------------
-- 3. RANGE_HASHED 布局
-- 【原理】支持时间范围查询的字典
-- 【适用】价格区间、汇率、税率等按时间有效的数据
-- 需要包含 start_date 和 end_date 字段
-- -----------------------------------------------------------

-- 创建汇率数据源
CREATE TABLE dim_exchange_rate
(
    currency_id   UInt64,
    currency_code String,
    rate          Float64,
    start_date    Date,
    end_date      Date
)
ENGINE = MergeTree
ORDER BY (currency_id, start_date);

INSERT INTO dim_exchange_rate VALUES
    (1, 'USD', 7.24, '2024-01-01', '2024-03-31'),
    (1, 'USD', 7.20, '2024-04-01', '2024-06-30'),
    (1, 'USD', 7.15, '2024-07-01', '2024-12-31'),
    (2, 'EUR', 7.85, '2024-01-01', '2024-06-30'),
    (2, 'EUR', 7.78, '2024-07-01', '2024-12-31');

-- 创建 RANGE_HASHED 字典
CREATE DICTIONARY dict_exchange_rate
(
    currency_id   UInt64,
    currency_code String,
    rate          Float64,
    start_date    Date,
    end_date      Date
)
PRIMARY KEY currency_id
SOURCE(CLICKHOUSE(TABLE 'dim_exchange_rate'))
LAYOUT(RANGE_HASHED())
RANGE(MIN start_date MAX end_date)
LIFETIME(MIN 300 MAX 600);

-- 查询汇率字典（带时间参数）
SELECT '【RANGE_HASHED 字典】按时间查询汇率:';
SELECT dictGet('modeling_test.dict_exchange_rate', 'rate',
               toUInt64(1), toDate('2024-02-15'));  -- 返回 7.24
SELECT dictGet('modeling_test.dict_exchange_rate', 'rate',
               toUInt64(1), toDate('2024-05-15'));  -- 返回 7.20
SELECT dictGet('modeling_test.dict_exchange_rate', 'rate',
               toUInt64(1), toDate('2024-10-15'));  -- 返回 7.15

-- -----------------------------------------------------------
-- 4. CACHE 布局
-- 【原理】只在内存中缓存部分数据，未命中时从数据源加载
-- 【适用】数据量很大（> 1000 万行），但查询是局部性的场景
-- 需要设置 cache_size 和 max_bytes_size
-- -----------------------------------------------------------

-- 创建 CACHE 字典（需要设置缓存大小）
-- 注意：CACHE 字典对查询模式有要求，适合有局部性的查询
-- 如果查询完全是随机的，CACHE 命中率很低，性能反而更差

-- -----------------------------------------------------------
-- 5. COMPLEX_KEY_CACHE 布局
-- 【原理】CACHE 布局的复合键版本
-- 【适用】大数据量 + 复合键 + 局部性查询
-- -----------------------------------------------------------

-- -----------------------------------------------------------
-- 6. SSD_CACHE 布局
-- 【原理】使用 SSD 作为缓存层，内存中只存热点数据
-- 【适用】超大数据量（> 1 亿行），但内存有限
-- 需要配置 SSD 缓存路径
-- -----------------------------------------------------------

-- ============================================================
-- 实验二：字典刷新策略
-- ============================================================

-- 【原理】字典的 LIFETIME 机制
-- ============================================================
-- 1. LIFETIME(MIN N MAX M)：字典在 N 到 M 秒之间随机刷新
-- 2. 刷新时从数据源重新加载全部数据
-- 3. 查询时如果字典正在刷新，会使用旧数据
-- 4. 刷新是异步的，不会阻塞查询
-- 5. LIFETIME(0) 表示不自动刷新
-- ============================================================

-- 查看字典加载状态
SELECT '【字典状态】查看字典加载信息:';
SELECT
    name,
    status,
    type,
    lifetime_min,
    lifetime_max,
    loading_start_time,
    last_successful_update_time,
    formatReadableSize(bytes_allocated) AS memory_used,
    element_count
FROM system.dictionaries
WHERE database = 'modeling_test';

-- 主动刷新字典
-- SYSTEM RELOAD DICTIONARY modeling_test.dict_city_hashed;

-- 强制刷新所有字典
-- SYSTEM RELOAD DICTIONARIES;

-- 【坑】字典刷新时，如果数据源有大的变更，可能会影响查询
-- 建议在低峰期更新数据源，让字典在 LIFETIME 范围内自动刷新

-- ============================================================
-- 实验三：dictGet / dictHas / dictGetHierarchy 函数
-- ============================================================

-- 【场景】使用字典函数进行查询

-- 创建事实表（订单表）
CREATE TABLE orders
(
    order_id    UInt64,
    city_id     UInt64,
    product_id  UInt64,
    amount      Decimal(10, 2),
    order_time  DateTime
)
ENGINE = MergeTree
ORDER BY (order_id, order_time);

INSERT INTO orders SELECT
    number AS order_id,
    (number % 5) + 1 AS city_id,
    (number % 500) + 1 AS product_id,
    toDecimal32((rand() % 1000) + 1, 2) AS amount,
    toDateTime('2024-01-01 00:00:00') + number % 31536000 AS order_time
FROM system.numbers
LIMIT 100000;

-- 1. dictGet — 获取字典值
SELECT '【dictGet】获取城市名称:';
SELECT
    order_id,
    city_id,
    dictGet('modeling_test.dict_city_hashed', 'city_name', city_id) AS city_name,
    dictGet('modeling_test.dict_city_hashed', 'province', city_id) AS province,
    amount
FROM orders
LIMIT 10;

-- 2. dictHas — 检查键是否存在
SELECT '【dictHas】检查键是否存在:';
SELECT
    city_id,
    dictHas('modeling_test.dict_city_hashed', city_id) AS exists_in_dict
FROM orders
GROUP BY city_id
ORDER BY city_id;

-- 3. dictGetHierarchy — 获取层级关系
-- 需要创建层级字典（LAYOUT = HIERARCHICAL）
-- 实际使用中，需要先创建层级字典

-- 创建层级字典示例
-- 先创建层级数据源
CREATE TABLE dim_region_hierarchy
(
    region_id   UInt64,
    region_name String,
    parent_id   UInt64
)
ENGINE = MergeTree
ORDER BY region_id;

INSERT INTO dim_region_hierarchy VALUES
    (1, 'China', 0),
    (2, 'Beijing', 1),
    (3, 'Shanghai', 1),
    (4, 'Guangdong', 1),
    (5, 'Haiding', 2),
    (6, 'Chaoyang', 2);

-- 创建层级字典
CREATE DICTIONARY dict_region_hierarchy
(
    region_id   UInt64,
    region_name String,
    parent_id   UInt64 HIERARCHICAL
)
PRIMARY KEY region_id
SOURCE(CLICKHOUSE(TABLE 'dim_region_hierarchy'))
LAYOUT(HASHED())
LIFETIME(MIN 300 MAX 600);

-- 查询层级关系
SELECT '【dictGetHierarchy】获取层级路径:';
SELECT dictGetHierarchy('modeling_test.dict_region_hierarchy', toUInt64(5)) AS hierarchy;

-- ============================================================
-- 实验四：字典 vs JOIN 性能对比
-- ============================================================

-- 【场景】同样的查询，对比字典和 JOIN 的性能

-- 创建一个大维表（10 万行）
CREATE TABLE dim_user_large
(
    user_id      UInt32,
    user_name    String,
    user_level   String,
    user_region  String,
    register_date Date,
    last_login   DateTime
)
ENGINE = MergeTree
ORDER BY user_id;

INSERT INTO dim_user_large SELECT
    number AS user_id,
    concat('user_', toString(number)) AS user_name,
    ['VIP', 'Normal', 'Platinum'][(number % 3) + 1] AS user_level,
    ['North', 'South', 'East', 'West'][(number % 4) + 1] AS user_region,
    toDate('2024-01-01') + number % 365 AS register_date,
    toDateTime('2024-01-01 00:00:00') + number % 31536000 AS last_login
FROM system.numbers
LIMIT 100000;

-- 创建字典
CREATE DICTIONARY dict_user_large
(
    user_id      UInt32,
    user_name    String,
    user_level   String,
    user_region  String,
    register_date Date,
    last_login   DateTime
)
PRIMARY KEY user_id
SOURCE(CLICKHOUSE(TABLE 'dim_user_large'))
LAYOUT(HASHED())
LIFETIME(MIN 300 MAX 600);

-- 创建事实表（100 万行）
CREATE TABLE user_orders
(
    order_id   UInt64,
    user_id    UInt32,
    amount     Decimal(10, 2),
    order_time DateTime
)
ENGINE = MergeTree
ORDER BY (user_id, order_time);

INSERT INTO user_orders SELECT
    number AS order_id,
    number % 100000 AS user_id,
    toDecimal32((rand() % 1000) + 1, 2) AS amount,
    toDateTime('2024-01-01 00:00:00') + number % 31536000 AS order_time
FROM system.numbers
LIMIT 1000000;

-- 方案 A：使用字典
SELECT '【字典查询】性能测试:';
SELECT
    count() AS order_count,
    sum(amount) AS total_amount,
    dictGet('modeling_test.dict_user_large', 'user_level', toUInt32(50000)) AS level
FROM user_orders
WHERE user_id = 50000;

-- 方案 B：使用 JOIN
SELECT '【JOIN 查询】性能测试:';
SELECT
    count() AS order_count,
    sum(o.amount) AS total_amount,
    u.user_level
FROM user_orders o
INNER JOIN dim_user_large u ON o.user_id = u.user_id
WHERE o.user_id = 50000
GROUP BY u.user_level;

-- 批量查询对比
SELECT '【批量查询】字典 vs JOIN:';
-- 使用字典：查询 100 个用户的订单
SELECT '-- 字典模式 --';
SELECT
    user_id,
    dictGet('modeling_test.dict_user_large', 'user_name', user_id) AS user_name,
    count() AS order_count,
    sum(amount) AS total_amount
FROM user_orders
WHERE user_id IN (100, 200, 300, 400, 500, 600, 700, 800, 900, 1000)
GROUP BY user_id
ORDER BY user_id;

-- 使用 JOIN
SELECT '-- JOIN 模式 --';
SELECT
    o.user_id,
    u.user_name,
    count() AS order_count,
    sum(o.amount) AS total_amount
FROM user_orders o
INNER JOIN dim_user_large u ON o.user_id = u.user_id
WHERE o.user_id IN (100, 200, 300, 400, 500, 600, 700, 800, 900, 1000)
GROUP BY o.user_id, u.user_name
ORDER BY o.user_id;

-- ============================================================
-- 实验五：字典使用场景与注意事项
-- ============================================================

-- 【场景 1】数据脱敏
-- 使用字典做数据脱敏映射
CREATE TABLE dim_sensitive_data
(
    raw_id    UInt64,
    masked_value String
)
ENGINE = MergeTree
ORDER BY raw_id;

INSERT INTO dim_sensitive_data VALUES
    (1, '138****1234'),
    (2, '139****5678'),
    (3, '136****9012');

CREATE DICTIONARY dict_masked_phone
(
    raw_id    UInt64,
    masked_value String
)
PRIMARY KEY raw_id
SOURCE(CLICKHOUSE(TABLE 'dim_sensitive_data'))
LAYOUT(HASHED())
LIFETIME(MIN 300 MAX 600);

-- 查询时自动脱敏
SELECT '【数据脱敏】使用字典脱敏:';
SELECT
    dictGet('modeling_test.dict_masked_phone', 'masked_value', toUInt64(1)) AS phone;

-- 【场景 2】字典替代枚举
-- 使用字典将编码映射为可读文本
CREATE TABLE dim_status_code
(
    code        UInt8,
    description String
)
ENGINE = MergeTree
ORDER BY code;

INSERT INTO dim_status_code VALUES
    (1, 'Pending'), (2, 'Processing'), (3, 'Shipped'), (4, 'Delivered'), (5, 'Cancelled');

CREATE DICTIONARY dict_status_code
(
    code        UInt8,
    description String
)
PRIMARY KEY code
SOURCE(CLICKHOUSE(TABLE 'dim_status_code'))
LAYOUT(HASHED())
LIFETIME(MIN 3000 MAX 6000);

-- 在查询中映射状态码
SELECT '【枚举映射】字典替代 CASE WHEN:';
SELECT
    dictGet('modeling_test.dict_status_code', 'description', toUInt8(1)) AS status_1,
    dictGet('modeling_test.dict_status_code', 'description', toUInt8(3)) AS status_3;

-- 【坑】字典的注意事项
-- 1. 字典数据全部加载到内存中，注意内存占用
-- 2. 字典刷新时，如果有大量数据变更，会导致内存抖动
-- 3. 字典不适合频繁更新的数据（秒级更新），建议分钟级
-- 4. 字典键类型要与查询时传入的类型一致
-- 5. CACHE 布局的字典需要设置合适的缓存大小（cache_size）
-- 6. 字典名称是 database.dictionary_name 格式

-- 查看字典内存使用
SELECT '【字典内存使用】:';
SELECT
    name,
    status,
    formatReadableSize(bytes_allocated) AS memory,
    element_count,
    lifetime_min,
    lifetime_max
FROM system.dictionaries
WHERE database = 'modeling_test';

-- ============================================================
-- 结论：字典使用指南
-- ============================================================
-- 1. 字典比 JOIN 快 100 倍，优先使用字典替代维度表 JOIN
-- 2. HASHED 布局最常用，适合 < 1000 万行的维度数据
-- 3. COMPLEX_KEY_HASHED 用于复合键场景
-- 4. RANGE_HASHED 用于时间范围查询（汇率、税率）
-- 5. CACHE 布局用于大数据量但有局部性的场景
-- 6. 字典适合低频更新的维度数据
-- 7. 字典查询函数：dictGet / dictHas / dictGetHierarchy
-- 8. 字典刷新策略：LIFETIME 设置合适的刷新间隔

SELECT 'DONE - 字典深度实验完成';

DROP DATABASE IF EXISTS modeling_test;