/*
 * 04_compound_types.sql — 复合类型详解（Array / Tuple / Map / Nested）
 *
 * 【本章解决什么问题】
 *   - Array(T) 和普通表的 JOIN 展开哪个快？为什么？
 *   - Map(K,V) 和 JSON 列有什么区别？什么时候用 Map？
 *   - Tuple 和 Nested 分别解决什么场景？
 *   - 复合类型的列式存储如何工作？
 *
 * 【使用场景】四类复合类型各管一类问题：
 *   - Array(T)：多值属性（商品标签、功能开关、权限列表、人群包）
 *   - Map(K,V)：动态/稀疏键值对（订单扩展属性、Prometheus 标签、事件自定义属性）
 *   - Tuple：固定结构小数据（GPS 坐标 (lat,lng)、版本号 (major,minor)）
 *   - Nested：子表结构（订单行项目、购物车明细），本质是等长 Array 列
 *   选型判断：值集合同质→Array；键不固定→Map；字段少且固定→Tuple；
 *   需要按子项过滤/聚合→Nested（可用 ARRAY JOIN 展开）。
 *
 * 【原理】
 *   复合类型是 ClickHouse 列式存储的"递归"应用：
 *   - Array(T): 列中嵌套列，每行是一个数组，但列式存储保证数组元素连续存放
 *   - Tuple: 命名字段的多列集合，本质上是一个微型行
 *   - Map: 键值对的动态集合，适合稀疏属性
 *   - Nested: 结构化的子表，本质是多个同长度的 Array 列
 *
 * 【运行环境】
 *   - 集群：treasurycluster（CH 25.12.1.649）
 *   - 数据库：data_type_test
 */

-- ============================================================================
-- §0. 准备
-- ============================================================================
DROP DATABASE IF EXISTS data_type_test;
CREATE DATABASE data_type_test;
USE data_type_test;

-- ============================================================================
-- §1. Array(T) —— 列中的列
-- ============================================================================
-- 【原理】Array(T) 是"列中列"：主表每行含一个数组，但数组元素在列式存储中
--         连续存放，压缩率高。不需要 JOIN 展开，比范式化快 10-100x。

-- 1.1 创建带 Array 的表
CREATE TABLE events_with_array
(
    event_time DateTime,
    user_id UInt32,
    tags Array(String),             -- 标签数组
    prices Array(Float64),          -- 商品价格数组
    product_ids Array(UInt32)       -- 商品 ID 数组
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_time, user_id);

INSERT INTO events_with_array VALUES
    ('2024-01-15 10:00:00', 1001, ['hot', 'new', 'promo'], [99.9, 199.9, 299.9], [101, 102, 103]),
    ('2024-01-15 11:00:00', 1002, ['sale', 'clearance'], [49.9, 89.9], [201, 202]),
    ('2024-01-15 12:00:00', 1003, ['hot', 'flash'], [999.0, 888.0], [301, 302]),
    ('2024-01-15 13:00:00', 1004, [], [], []);  -- 空数组

-- 1.2 数组长度与空值判断
SELECT
    user_id,
    length(tags) AS tag_count,
    empty(tags) AS no_tags,
    notEmpty(tags) AS has_tags
FROM events_with_array;

-- 1.3 ARRAY JOIN —— 数组展开为多行（最常用操作）
-- 【场景】每个标签单独统计
SELECT
    user_id,
    tag,
    price
FROM events_with_array
ARRAY JOIN
    tags AS tag,
    prices AS price
ORDER BY user_id, tag;

-- 1.4 数组元素访问（1-indexed）
SELECT
    user_id,
    tags[1] AS first_tag,        -- 第一个元素
    tags[-1] AS last_tag,        -- 最后一个元素
    tags[length(tags)] AS also_last
FROM events_with_array;

-- 1.5 数组条件判断
SELECT
    user_id,
    has(tags, 'hot') AS is_hot,
    hasAny(tags, ['hot', 'sale']) AS hot_or_sale,
    hasAll(tags, ['hot', 'new']) AS hot_and_new,
    indexOf(tags, 'promo') AS promo_pos  -- 0 = 不存在
FROM events_with_array;

-- 1.6 数组操作函数
SELECT
    user_id,
    arrayConcat(tags, ['recommended']) AS with_recommended,
    arrayPushFront(tags, 'top') AS front_tag,
    arrayPushBack(tags, 'bottom') AS back_tag,
    arrayPopFront(tags) AS without_first,
    arrayPopBack(tags) AS without_last
FROM events_with_array
WHERE notEmpty(tags);

-- 1.7 数组元素操作
SELECT
    user_id,
    arraySort(prices) AS sorted_prices,
    arrayReverse(arraySort(prices)) AS desc_prices,
    arrayDistinct(tags) AS unique_tags,
    arrayFilter(x -> x > 100, prices) AS expensive_items,
    arrayMap(x -> x * 0.9, prices) AS discounted_prices
FROM events_with_array
WHERE notEmpty(prices);

-- 1.8 数组聚合函数
SELECT
    user_id,
    arraySum(prices) AS total,
    arrayAvg(prices) AS avg_price,
    arrayMax(prices) AS max_price,
    arrayMin(prices) AS min_price,
    arrayExists(x -> x > 200, prices) AS has_expensive,
    arrayAll(x -> x > 0, prices) AS all_positive
FROM events_with_array
WHERE notEmpty(prices);

-- 1.9 数组创建与转换
SELECT
    [1, 2, 3] AS literal_array,
    range(1, 10) AS range_array,               -- [1,2,3,4,5,6,7,8,9]
    arrayWithConstant(5, 'x') AS repeated,     -- ['x','x','x','x','x']
    array(1, 2, 3) AS array_from_args;         -- [1,2,3]

-- 1.10 数组嵌套（二维数组）
CREATE TABLE nested_arrays
(
    id UInt32,
    matrix Array(Array(UInt8))  -- 二维数组
) ENGINE = MergeTree()
ORDER BY id;

INSERT INTO nested_arrays VALUES
    (1, [[1,2,3], [4,5,6], [7,8,9]]),
    (2, [[10,20], [30,40]]);

SELECT
    id,
    matrix[1] AS first_row,
    matrix[1][2] AS first_row_second_col
FROM nested_arrays;

-- ============================================================================
-- §2. Tuple(T1, T2, ...) —— 异构元组
-- ============================================================================
-- 【原理】Tuple 是异构字段的集合，每个元素可以不同类型
-- 【场景】临时组合多个值、CTE 中返回多列、复杂函数返回值

-- 2.1 创建带 Tuple 的表
CREATE TABLE events_with_tuple
(
    event_time DateTime,
    user_id UInt32,
    location Tuple(city String, country String, lat Float64, lng Float64),
    metadata Tuple(version UInt8, source String)
) ENGINE = MergeTree()
ORDER BY (event_time, user_id);

INSERT INTO events_with_tuple VALUES
    ('2024-01-15 10:00:00', 1001, ('Beijing', 'China', 39.9, 116.4), (1, 'web')),
    ('2024-01-15 11:00:00', 1002, ('New York', 'USA', 40.7, -74.0), (2, 'mobile')),
    ('2024-01-15 12:00:00', 1003, ('Tokyo', 'Japan', 35.7, 139.7), (1, 'api'));

-- 2.2 Tuple 元素访问
SELECT
    user_id,
    location.1 AS city,            -- 第一个元素
    location.2 AS country,         -- 第二个元素
    location.3 AS latitude,        -- 第三个元素
    metadata.1 AS version,         -- 元组第一个元素
    metadata.2 AS source           -- 元组第二个元素
FROM events_with_tuple;

-- 2.3 Tuple 作为函数参数
SELECT
    user_id,
    tuple(location.1, location.2) AS city_country,
    tupleElement(location, 1) AS city_alt
FROM events_with_tuple;

-- 2.4 Tuple 与 GROUP BY
-- 【场景】按多个字段分组时，Tuple 可以简化 GROUP BY
SELECT
    (location.1, location.2) AS city_country,
    count() AS visits,
    uniq(user_id) AS unique_users
FROM events_with_tuple
GROUP BY city_country
ORDER BY visits DESC;

-- ============================================================================
-- §3. Map(K, V) —— 动态键值对
-- ============================================================================
-- 【原理】Map 是 ClickHouse 22.6+ 的原生键值对类型，比 Tuple 更灵活
-- 【场景】稀疏属性、动态标签、用户自定义属性

-- 3.1 创建带 Map 的表
CREATE TABLE events_with_map
(
    event_time DateTime,
    user_id UInt32,
    properties Map(String, String),   -- 动态属性
    metrics Map(String, Float64)       -- 动态指标
) ENGINE = MergeTree()
ORDER BY (event_time, user_id);

INSERT INTO events_with_map VALUES
    ('2024-01-15 10:00:00', 1001, {'browser': 'Chrome', 'os': 'Windows', 'screen': '1920x1080'}, {'load_time': 1.2, 'ttfb': 0.3}),
    ('2024-01-15 11:00:00', 1002, {'browser': 'Safari', 'os': 'iOS', 'screen': '1170x2532'}, {'load_time': 2.1, 'ttfb': 0.5}),
    ('2024-01-15 12:00:00', 1003, {'browser': 'Firefox', 'os': 'Linux'}, {'load_time': 0.8});

-- 3.2 Map 访问
SELECT
    user_id,
    properties['browser'] AS browser,
    properties['os'] AS os,
    metrics['load_time'] AS load_time
FROM events_with_map;

-- 3.3 Map 键值枚举
SELECT
    user_id,
    mapKeys(properties) AS keys,
    mapValues(properties) AS values
FROM events_with_map;

-- 3.4 Map 条件判断
SELECT
    user_id,
    mapContains(properties, 'screen') AS has_screen,
    properties['screen'] AS screen_size
FROM events_with_map;

-- 3.5 Map 操作
SELECT
    user_id,
    mapUpdate(properties, map('language', 'zh-CN')) AS updated_props
FROM events_with_map;

-- 3.6 Map 与 ARRAY JOIN 展开
-- 【场景】将 Map 展开为键值对行
SELECT
    user_id,
    key,
    value
FROM events_with_map
ARRAY JOIN
    mapKeys(properties) AS key,
    mapValues(properties) AS value
ORDER BY user_id, key;

-- 3.7 Map 聚合
SELECT
    browser,
    count() AS user_count,
    avg(load_time) AS avg_load_time
FROM
(
    SELECT
        properties['browser'] AS browser,
        metrics['load_time'] AS load_time
    FROM events_with_map
    WHERE mapContains(properties, 'browser')
      AND mapContains(metrics, 'load_time')
)
GROUP BY browser;

-- ============================================================================
-- §4. Nested —— 结构化子表
-- ============================================================================
-- 【原理】Nested 本质是多个同长度的 Array 列，CH 将它们视为一个"子表"
-- 【场景】订单中的商品明细、日志中的事件列表

-- 4.1 创建带 Nested 的表
CREATE TABLE orders_with_items
(
    order_id UInt64,
    order_time DateTime,
    customer_id UInt32,
    -- Nested 类型：定义子表结构
    items Nested
    (
        product_id UInt32,
        product_name String,
        quantity UInt16,
        price Decimal(10, 2)
    )
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(order_time)
ORDER BY (order_id, customer_id);

INSERT INTO orders_with_items VALUES
    (1001, '2024-01-15 10:00:00', 1, [101, 102], ['Widget A', 'Widget B'], [2, 1], [19.99, 29.99]),
    (1002, '2024-01-15 11:00:00', 2, [201], ['Gadget X'], [3], [49.99]),
    (1003, '2024-01-16 10:00:00', 1, [301, 302, 303], ['Item A', 'Item B', 'Item C'], [1, 1, 2], [9.99, 14.99, 24.99]);

-- 4.2 查询 Nested 表
-- 完整查看
SELECT
    order_id,
    items.product_id,
    items.product_name,
    items.quantity,
    items.price
FROM orders_with_items
ORDER BY order_id, items.product_id;

-- 4.3 ARRAY JOIN 展开 Nested
SELECT
    order_id,
    customer_id,
    items.product_id,
    items.product_name,
    items.quantity,
    items.price,
    items.quantity * items.price AS line_total
FROM orders_with_items
ARRAY JOIN items
ORDER BY order_id, items.product_id;

-- 4.4 Nested 聚合
SELECT
    order_id,
    sum(items.quantity * items.price) AS order_total,
    count() AS item_count,
    sum(items.quantity) AS total_quantity
FROM orders_with_items
ARRAY JOIN items
GROUP BY order_id
ORDER BY order_total DESC;

-- 4.5 Nested 条件过滤
SELECT
    order_id,
    items.product_name,
    items.quantity,
    items.price
FROM orders_with_items
ARRAY JOIN items
WHERE items.price > 20.0
ORDER BY order_id, items.product_name;

-- ============================================================================
-- §5. 复合类型选型对比
-- ============================================================================
-- | 类型 | 结构 | 元素类型 | 场景 | 替代方案 |
-- |------|------|---------|------|---------|
-- | Array(T) | 同类型列表 | 同类型 | 标签、价格列表 | 范式化子表（慢 10x） |
-- | Tuple(T1,T2,...) | 异构固定字段 | 不同类型 | 坐标、版本信息 | 分开多个列（更优） |
-- | Map(K,V) | 动态键值对 | 同类型 K/V | 用户属性、动态标签 | JSON 列（查询慢） |
-- | Nested | 结构化子表 | 多列同长 | 订单明细、日志事件 | 单独子表（JOIN 慢） |

-- 推荐：能用 Array 不用 Nested，能用 Map 不用 String+JSON 解析

-- ============================================================================
-- §6. 清理
-- ============================================================================
DROP TABLE IF EXISTS events_with_array;
DROP TABLE IF EXISTS nested_arrays;
DROP TABLE IF EXISTS events_with_tuple;
DROP TABLE IF EXISTS events_with_map;
DROP TABLE IF EXISTS orders_with_items;
DROP DATABASE IF EXISTS data_type_test;

-- ============================================================================
-- §7. 自测题
-- ============================================================================
-- 1. Array(T) 和范式化子表（用 JOIN 展开）相比，查询性能差多少？为什么？
-- 2. ARRAY JOIN 和普通的 JOIN 核心区别是什么？
-- 3. Tuple 元素访问用 .1/.2 语法，Map 元素访问用 ['key'] 语法，为什么？
-- 4. Nested 和 Array(Tuple(...)) 有区别吗？
-- 5. Map 类型适合什么场景？不适合什么场景？