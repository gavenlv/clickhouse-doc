/*
 * 12_data_modeling.sql — 数据建模入门
 *
 * 【本章解决什么问题】
 *   - ClickHouse 该用"宽表"还是"星型 schema"？为什么 CH 不像 MySQL 那样强范式？
 *   - ORDER BY 该选哪些列？为什么把"最常用过滤条件"放前面？
 *   - PARTITION BY 越细越好吗？为什么按月分区是最稳的选择？
 *   - 时序数据该怎样建模？标签（labels）和指标（metrics）怎么存？
 *   - 用户行为宽表长什么样？为什么"反范式 + 物化视图预聚合"是 CH 的最佳实践？
 *
 * 【原理】
 *   ClickHouse 是 OLAP 列存数据库，建模哲学与 OLTP 完全相反：
 *     - OLTP（MySQL）：范式化（避免冗余）+ JOIN 取数据
 *     - OLAP（CH）：反范式（宽表）+ 预聚合（MV）+ 字典替代 JOIN
 *   原因：列存对"宽表"友好（只读需要的列，多余列不浪费 IO），
 *        而 JOIN 是 CH 的性能短板（右表全量加载内存）。
 *
 *   建模三大决策：
 *     ① 表引擎：见 03-engines/06_engine_selection_guide.md 决策树
 *     ② ORDER BY：决定物理排序 + 主键稀疏索引 + 分区剪枝粒度
 *     ③ PARTITION BY：决定数据物理分桶 + TTL 过期粒度 + 查询剪枝粒度
 *
 * 【运行环境】
 *   - 集群：treasurycluster（CH 25.12.1.649）
 *   - 数据库：getting_started_test
 */

-- ============================================================================
-- §0. 准备
-- ============================================================================
DROP DATABASE IF EXISTS getting_started_test;
CREATE DATABASE getting_started_test;
USE getting_started_test;

-- ============================================================================
-- §1. 宽表 vs 星型 Schema —— CH 建模第一抉择
-- ============================================================================
-- 【场景】电商订单分析：订单 + 用户 + 商品 + 城市四张维度表
-- 【方案 A】星型 schema（OLTP 思路）：订单事实表 + 3 张维表 + JOIN
-- 【方案 B】宽表（OLAP 思路）：一张大表，所有维度直接冗余进来

-- 1.1 方案 A：星型 schema（演示用，CH 不推荐）
CREATE TABLE orders_star
(
    order_id UInt64,
    user_id UInt32,
    product_id UInt32,
    city_id UInt16,
    amount Decimal(18, 2),
    order_time DateTime
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(order_time)
ORDER BY (order_time, user_id);

CREATE TABLE dim_user
(
    user_id UInt32,
    user_name String,
    age UInt8,
    gender LowCardinality(String)
) ENGINE = MergeTree()
ORDER BY user_id;

CREATE TABLE dim_product
(
    product_id UInt32,
    product_name String,
    category LowCardinality(String),
    price Decimal(18, 2)
) ENGINE = MergeTree()
ORDER BY product_id;

CREATE TABLE dim_city
(
    city_id UInt16,
    city_name String,
    province LowCardinality(String)
) ENGINE = MergeTree()
ORDER BY city_id;

-- 写入样本数据
INSERT INTO dim_user VALUES
    (1001, 'Alice', 25, 'F'),
    (1002, 'Bob', 30, 'M'),
    (1003, 'Charlie', 35, 'M');

INSERT INTO dim_product VALUES
    (5001, 'Laptop', 'Electronics', 5999.00),
    (5002, 'Phone', 'Electronics', 3999.00),
    (5003, 'Book', 'Books', 49.90);

INSERT INTO dim_city VALUES
    (10, 'Beijing', 'Beijing'),
    (20, 'Shanghai', 'Shanghai'),
    (30, 'Guangzhou', 'Guangdong');

INSERT INTO orders_star VALUES
    (1, 1001, 5001, 10, 5999.00, '2024-01-15 10:00:00'),
    (2, 1001, 5002, 10, 3999.00, '2024-01-15 11:00:00'),
    (3, 1002, 5003, 20, 49.90,  '2024-01-16 09:00:00'),
    (4, 1003, 5001, 30, 5999.00, '2024-01-16 14:00:00');

-- 1.2 方案 A 查询：需要 3 个 JOIN 才能拿到完整维度
-- 【坑】CH 的 JOIN 是右表全量加载内存，大维表 JOIN 是性能杀手
SELECT
    o.order_id,
    u.user_name,
    p.product_name,
    c.city_name,
    o.amount
FROM orders_star o
LEFT JOIN dim_user u    ON o.user_id = u.user_id
LEFT JOIN dim_product p ON o.product_id = p.product_id
LEFT JOIN dim_city c    ON o.city_id = c.city_id
ORDER BY o.order_id;

-- 1.3 方案 B：宽表（CH 推荐）—— 把维度直接冗余进事实表
CREATE TABLE orders_wide
(
    order_id UInt64,
    order_time DateTime,

    -- 用户维度（冗余）
    user_id UInt32,
    user_name String,
    age UInt8,
    gender LowCardinality(String),

    -- 商品维度（冗余）
    product_id UInt32,
    product_name String,
    category LowCardinality(String),

    -- 城市维度（冗余）
    city_id UInt16,
    city_name String,
    province LowCardinality(String),

    -- 度量
    amount Decimal(18, 2)
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(order_time)
ORDER BY (order_time, user_id, product_id);

-- 1.4 宽表查询：无 JOIN，直接 SELECT
INSERT INTO orders_wide VALUES
    (1, '2024-01-15 10:00:00', 1001, 'Alice', 25, 'F', 5001, 'Laptop', 'Electronics', 10, 'Beijing',  'Beijing',   5999.00),
    (2, '2024-01-15 11:00:00', 1001, 'Alice', 25, 'F', 5002, 'Phone',  'Electronics', 10, 'Beijing',  'Beijing',   3999.00),
    (3, '2024-01-16 09:00:00', 1002, 'Bob',   30, 'M', 5003, 'Book',   'Books',       20, 'Shanghai', 'Shanghai',  49.90),
    (4, '2024-01-16 14:00:00', 1003, 'Charlie', 35, 'M', 5001, 'Laptop', 'Electronics', 30, 'Guangzhou','Guangdong', 5999.00);

SELECT order_id, user_name, product_name, city_name, amount
FROM orders_wide
ORDER BY order_id;

-- 【对比】宽表只读需要的列，列存天然适合；JOIN 在 CH 是性能短板
-- 【何时仍用星型】维度变化频繁（如商品价格每天变）、维表极大（无法冗余）
-- 【折中方案】宽表 + 字典（dim_get 替代 JOIN，详见 §4）

-- ============================================================================
-- §2. ORDER BY 设计 —— ClickHouse 的"灵魂"
-- ============================================================================
-- 【原理】ORDER BY 三重身份：
--   ① 物理排序（数据在 part 内按此顺序存）
--   ② 默认主键（稀疏索引基于此建立）
--   ③ 裁剪键（WHERE 命中前缀时可跳过大量 granule）

-- 2.1 好的 ORDER BY：前缀匹配高频查询
CREATE TABLE events_good_order
(
    event_date Date,
    user_id UInt32,
    event_type LowCardinality(String),
    amount Float64
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_date)
ORDER BY (event_date, user_id);   -- 高频查询："某天某用户" / "某天所有用户"

INSERT INTO events_good_order
SELECT
    toDate('2024-01-01') + number % 30 AS event_date,
    number % 1000 AS user_id,
    ['click', 'view', 'purchase'][1 + (number % 3)] AS event_type,
    rand() % 1000 AS amount
FROM numbers(1000000);

-- 【快】前缀匹配：用 event_date 过滤，索引能精确裁剪
SELECT count(), sum(amount) FROM events_good_order
WHERE event_date = '2024-01-15';

-- 【快】前缀全匹配：event_date + user_id
SELECT count(), sum(amount) FROM events_good_order
WHERE event_date = '2024-01-15' AND user_id = 500;

-- 2.2 坏的 ORDER BY：低基数列在前
CREATE TABLE events_bad_order
(
    event_date Date,
    user_id UInt32,
    event_type LowCardinality(String),
    amount Float64
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_date)
ORDER BY (event_type);   -- 只有 3 个枚举值，主键裁剪几乎无效

INSERT INTO events_bad_order
SELECT
    toDate('2024-01-01') + number % 30 AS event_date,
    number % 1000 AS user_id,
    ['click', 'view', 'purchase'][1 + (number % 3)] AS event_type,
    rand() % 1000 AS amount
FROM numbers(1000000);

-- 【慢】虽然查 event_date，但主键是 event_type，无法用 event_date 裁剪
SELECT count(), sum(amount) FROM events_bad_order
WHERE event_date = '2024-01-15';

-- 2.3 用 EXPLAIN 看索引使用情况
-- 【关键】rows_to_read 越小，索引裁剪越好
EXPLAIN indexes = 1
SELECT count() FROM events_good_order
WHERE event_date = '2024-01-15';

EXPLAIN indexes = 1
SELECT count() FROM events_bad_order
WHERE event_date = '2024-01-15';

-- 【ORDER BY 设计原则】
-- ✅ 第一列：高频过滤的高基数列（通常是日期）
-- ✅ 第二列：次级过滤列（如 user_id, device_id）
-- ✅ 列数：2-4 列足够，过多浪费索引空间
-- ❌ 反例：低基数列在前（如性别、状态码）
-- ❌ 反例：列数过多（> 5 列索引膨胀）

-- ============================================================================
-- §3. 分区策略 —— PARTITION BY 的取舍
-- ============================================================================
-- 【原理】分区是物理分桶，每个分区独立存储，查询时按分区键剪枝
--   分区 vs 主键：分区是粗粒度（按月/天），主键是细粒度（每 8192 行 mark）

-- 3.1 按月分区（推荐）：单分区 50-100GB，便于 TTL 过期
CREATE TABLE events_monthly_part
(
    event_time DateTime,
    user_id UInt32,
    amount Float64
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_time, user_id);

INSERT INTO events_monthly_part
SELECT now() - INTERVAL number SECOND, number % 1000, rand() % 1000
FROM numbers(1000000);

-- 3.2 按天分区（数据量极大时用，谨慎）
CREATE TABLE events_daily_part
(
    event_time DateTime,
    user_id UInt32,
    amount Float64
) ENGINE = MergeTree()
PARTITION BY toDate(event_time)
ORDER BY (event_time, user_id);

-- 3.3 查看分区情况
-- 【关键】活跃 part 数 < 1000；过多会触发 "Too many parts" 异常
SELECT
    database,
    table,
    partition,
    count() AS part_count,
    formatReadableSize(sum(bytes_on_disk)) AS total_size,
    sum(rows) AS total_rows
FROM system.parts
WHERE database = 'getting_started_test'
  AND active = 1
GROUP BY database, table, partition
ORDER BY table, partition;

-- 3.4 分区剪枝验证
-- 【快】带分区键过滤：只扫一个分区
SELECT count() FROM events_monthly_part
WHERE event_time BETWEEN '2024-01-01' AND '2024-01-31';

-- 【慢】不带分区键过滤：扫所有分区
SELECT count() FROM events_monthly_part
WHERE user_id = 500;

-- 【分区设计原则】
-- ✅ 按月分区：toYYYYMM(event_time) —— 95% 场景的最优解
-- ✅ 单分区大小：50-100 GB（太小 part 多，太大 merge 慢）
-- ✅ 分区数 < 1000（过多易触发 "Too many parts"）
-- ✅ 配合 TTL：过期分区直接删除（无需 mutation）
-- ❌ 反例：按小时分区（一天 24 part，一年 8760 part，爆炸）
-- ❌ 反例：按 user_id 取模分区（破坏时间序列查询剪枝）

-- ============================================================================
-- §4. 反范式 vs 范式 + 字典替代 JOIN
-- ============================================================================
-- 【场景】维表不大（< 1000 万行），但 JOIN 仍是性能瓶颈
-- 【方案】字典（Dictionary）：维表常驻内存，dictGet O(1) 替代 JOIN

-- 4.1 创建字典源表（维表）
DROP TABLE IF EXISTS dim_user_dict_src;
CREATE TABLE dim_user_dict_src
(
    user_id UInt32,
    user_name String,
    age UInt8,
    gender LowCardinality(String),
    country LowCardinality(String)
) ENGINE = MergeTree()
ORDER BY user_id;

INSERT INTO dim_user_dict_src VALUES
    (1001, 'Alice',   25, 'F', 'China'),
    (1002, 'Bob',     30, 'M', 'USA'),
    (1003, 'Charlie', 35, 'M', 'UK'),
    (1004, 'David',   28, 'M', 'China'),
    (1005, 'Eve',     22, 'F', 'Japan');

-- 4.2 创建字典（HASHED layout：哈希表，O(1) 查找）
-- 【坑】字典属性不支持 LowCardinality(String)，必须用普通 String
DROP DICTIONARY IF EXISTS user_dict;
CREATE DICTIONARY user_dict
(
    user_id UInt32,
    user_name String,
    age UInt8,
    gender String,
    country String
)
PRIMARY KEY user_id
SOURCE(CLICKHOUSE(TABLE 'dim_user_dict_src' DB 'getting_started_test'))
LAYOUT(HASHED())
LIFETIME(MIN 300 MAX 3600);   -- 5 分钟后刷新，最长 1 小时

-- 4.3 字典加载与查询
SYSTEM RELOAD DICTIONARY user_dict;

-- 直接查字典：O(1)
SELECT dictGet('user_dict', 'user_name', 1001) AS name,
       dictGet('user_dict', 'country', 1001) AS country,
       dictGet('user_dict', 'age', 1001) AS age;

-- 4.4 字典替代 JOIN —— 事件表 + dictGet 取维度
CREATE TABLE events_with_dict
(
    event_time DateTime,
    user_id UInt32,
    amount Float64
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_time, user_id);

INSERT INTO events_with_dict VALUES
    ('2024-01-15 10:00:00', 1001, 100.00),
    ('2024-01-15 11:00:00', 1002, 200.00),
    ('2024-01-15 12:00:00', 1003, 300.00);

-- 【快】dictGet 替代 JOIN，比 LEFT JOIN 快 10-100x
SELECT
    e.event_time,
    e.user_id,
    dictGet('user_dict', 'user_name', e.user_id) AS user_name,
    dictGet('user_dict', 'country', e.user_id) AS country,
    e.amount
FROM events_with_dict e;

-- 4.5 字典布局选型
-- | LAYOUT       | 数据结构       | 适用                          |
-- |-------------|---------------|-------------------------------|
-- | HASHED      | 哈希表         | 通用，键值查找，键 < 1000 万  |
-- | CACHE       | LRU 缓存      | 大字典，不常全查              |
-- | FLAT        | 数组下标       | 键是连续整数（0..N），最省内存 |
-- | RANGE_HASHED| 哈希 + 区间    | IP 段、价格区间              |
-- | COMPLEX_KEYED| 复合键哈希    | 多列联合键                    |

-- 4.6 字典 vs JOIN vs 宽表对比
-- | 方案         | 写入成本 | 查询速度 | 维度更新成本 | 适用                |
-- |-------------|---------|---------|-------------|---------------------|
-- | 宽表（冗余）  | 高       | 极快     | 高（重写）   | 维度几乎不变        |
-- | 字典 + dictGet| 低       | 快       | 低（刷字典） | 维度偶尔变 < 1000万 |
-- | JOIN         | 低       | 慢       | 低           | 维度极大或频繁变    |

-- ============================================================================
-- §5. 时间序列建模 —— 监控/物联网场景
-- ============================================================================
-- 【场景】Prometheus/InfluxDB 风格的时序数据：指标名 + 标签 + 时间戳 + 值
-- 【方案 A】宽表（每个指标一列）：指标少且固定时最优
-- 【方案 B】长表（metric_name + labels + value）：指标多且变动时更灵活

-- 5.1 方案 A：宽表（指标固定）
CREATE TABLE metrics_wide
(
    metric_time DateTime,
    host LowCardinality(String),       -- 主机
    cpu_usage Float64,                  -- 指标 1
    memory_usage Float64,               -- 指标 2
    disk_usage Float64,                 -- 指标 3
    network_in Float64,                 -- 指标 4
    network_out Float64                 -- 指标 5
) ENGINE = MergeTree()
PARTITION BY toYYYYMMDD(metric_time)
ORDER BY (metric_time, host);

INSERT INTO metrics_wide
SELECT
    now() - INTERVAL number SECOND,
    ['host1', 'host2', 'host3'][1 + (number % 3)],
    rand() % 100,
    rand() % 100,
    rand() % 100,
    rand() % 10000,
    rand() % 10000
FROM numbers(100000);

-- 查询：单指标聚合极快（只读一列）
SELECT
    host,
    avg(cpu_usage) AS avg_cpu,
    max(cpu_usage) AS max_cpu
FROM metrics_wide
WHERE metric_time >= now() - INTERVAL 1 HOUR
GROUP BY host;

-- 5.2 方案 B：长表（metric_name + labels Map + value）
CREATE TABLE metrics_long
(
    metric_time DateTime,
    metric_name LowCardinality(String),
    labels Map(String, String),         -- 标签：host, region, service...
    value Float64
) ENGINE = MergeTree()
PARTITION BY toYYYYMMDD(metric_time)
ORDER BY (metric_time, metric_name);

INSERT INTO metrics_long
SELECT
    now() - INTERVAL number SECOND,
    ['cpu_usage', 'memory_usage', 'disk_usage'][1 + (number % 3)],
    map('host', ['host1', 'host2'][1 + (number % 2)], 'region', 'cn-east-1'),
    rand() % 100
FROM numbers(100000);

-- 查询：按指标名过滤 + 按标签聚合
SELECT
    labels['host'] AS host,
    avg(value) AS avg_value
FROM metrics_long
WHERE metric_name = 'cpu_usage'
  AND metric_time >= now() - INTERVAL 1 HOUR
GROUP BY host;

-- 5.3 长表 vs 宽表对比
-- | 方案 | 写入灵活 | 查询单指标 | 查询多指标 | 压缩率 | 适用           |
-- |-----|---------|----------|----------|-------|---------------|
-- | 宽表 | 差       | 极快     | 快       | 高    | 指标固定少变    |
-- | 长表 | 好       | 快       | 需 PIVOT | 中    | 指标多变、千个+ |

-- ============================================================================
-- §6. 用户行为宽表实战 —— 反范式 + MV 预聚合典型模式
-- ============================================================================
-- 【场景】电商用户行为分析：原始事件 → 用户宽表 → 每日报表

-- 6.1 原始事件表（明细）
CREATE TABLE user_events_raw
(
    event_time DateTime,
    user_id UInt32,
    event_type LowCardinality(String),   -- view / click / cart / purchase
    product_id UInt32,
    amount Float64,
    device LowCardinality(String),       -- mobile / pc / app
    channel LowCardinality(String)       -- search / direct / ads
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_time, user_id);

-- 6.2 写入样本（100 万行）
INSERT INTO user_events_raw
SELECT
    now() - INTERVAL number SECOND,
    number % 1000 AS user_id,
    ['view', 'click', 'cart', 'purchase'][1 + (number % 4)] AS event_type,
    number % 100 AS product_id,
    if(number % 4 = 3, rand() % 1000, 0) AS amount,
    ['mobile', 'pc', 'app'][1 + (number % 3)] AS device,
    ['search', 'direct', 'ads'][1 + (number % 3)] AS channel
FROM numbers(1000000);

-- 6.3 用户行为宽表（按用户维度预聚合）
CREATE TABLE user_behavior_wide
(
    user_id UInt32,
    stat_date Date,

    -- 漏斗各阶段计数
    view_count UInt64,
    click_count UInt64,
    cart_count UInt64,
    purchase_count UInt64,

    -- 转化金额
    total_amount Float64,
    avg_amount Float64,

    -- 设备 / 渠道（取最常用的）
    prefer_device LowCardinality(String),
    prefer_channel LowCardinality(String)
) ENGINE = ReplacingMergeTree()
PARTITION BY toYYYYMM(stat_date)
ORDER BY (stat_date, user_id);

-- 6.4 用 INSERT SELECT 构建宽表
INSERT INTO user_behavior_wide
SELECT
    user_id,
    toDate(event_time) AS stat_date,
    countIf(event_type = 'view') AS view_count,
    countIf(event_type = 'click') AS click_count,
    countIf(event_type = 'cart') AS cart_count,
    countIf(event_type = 'purchase') AS purchase_count,
    sum(amount) AS total_amount,
    avg(amount) AS avg_amount,
    argMax(device, event_type = 'view') AS prefer_device,    -- 简化：取浏览时设备
    argMax(channel, event_type = 'view') AS prefer_channel
FROM user_events_raw
WHERE event_time >= now() - INTERVAL 1 DAY
GROUP BY user_id, stat_date;

-- 6.5 漏斗分析：从 view 到 purchase 的转化率
SELECT
    sum(view_count) AS total_views,
    sum(click_count) AS total_clicks,
    sum(cart_count) AS total_carts,
    sum(purchase_count) AS total_purchases,
    round(total_clicks / total_views * 100, 2) AS view_to_click_pct,
    round(total_carts / total_clicks * 100, 2) AS click_to_cart_pct,
    round(total_purchases / total_carts * 100, 2) AS cart_to_purchase_pct,
    round(total_purchases / total_views * 100, 2) AS overall_conversion_pct
FROM user_behavior_wide;

-- 6.6 高价值用户分析（RFM 简化版）
SELECT
    user_id,
    total_amount,
    purchase_count,
    total_amount / purchase_count AS avg_order_value,
    ROW_NUMBER() OVER (ORDER BY total_amount DESC) AS amount_rank
FROM user_behavior_wide
WHERE purchase_count > 0
ORDER BY total_amount DESC
LIMIT 10;

-- 6.7 用 MV 自动维护报表（实时版）
CREATE TABLE daily_summary
(
    stat_date Date,
    event_type LowCardinality(String),
    device LowCardinality(String),
    event_count UInt64,
    total_amount Float64
) ENGINE = SummingMergeTree()
PARTITION BY toYYYYMM(stat_date)
ORDER BY (stat_date, event_type, device);

CREATE MATERIALIZED VIEW mv_daily_summary
TO daily_summary
AS
SELECT
    toDate(event_time) AS stat_date,
    event_type,
    device,
    count() AS event_count,
    sum(amount) AS total_amount
FROM user_events_raw
GROUP BY stat_date, event_type, device;

-- 触发 MV：再写一条数据
INSERT INTO user_events_raw
SELECT
    now() - INTERVAL number SECOND,
    number % 50 AS user_id,
    ['view', 'click', 'cart', 'purchase'][1 + (number % 4)] AS event_type,
    number % 100 AS product_id,
    if(number % 4 = 3, rand() % 1000, 0) AS amount,
    ['mobile', 'pc', 'app'][1 + (number % 3)] AS device,
    ['search', 'direct', 'ads'][1 + (number % 3)] AS channel
FROM numbers(10000);

-- 查询 MV 自动聚合的报表
SELECT
    stat_date,
    event_type,
    device,
    event_count,
    total_amount
FROM daily_summary
ORDER BY stat_date DESC, event_type, device
LIMIT 20;

-- ============================================================================
-- §7. 建模决策矩阵 —— 选型一图流
-- ============================================================================
-- 【维度 1：数据特征】
-- | 数据特征              | 推荐建模                    |
-- |---------------------|----------------------------|
-- | 事件日志（追加）       | 宽表 + 分区 + ORDER BY(时间, ID) |
-- | 用户资料（更新）       | ReplacingMergeTree + argMax 查询 |
-- | 库存/计数器（增减）     | CollapsingMergeTree + sign 抵消 |
-- | 多维报表（预聚合）      | AggregatingMergeTree + *State |
-- | 时序指标（固定）        | 宽表（每指标一列）            |
-- | 时序指标（多变）        | 长表（metric_name + labels）  |
-- | 维度补充               | 字典 + dictGet              |

-- 【维度 2：性能优化路径】
-- 1. 反范式（宽表）→ 避免 JOIN
-- 2. 字典 → 替代维表 JOIN
-- 3. MV 预聚合 → 避免实时聚合
-- 4. ORDER BY 前缀匹配 → 索引剪枝
-- 5. PARTITION BY 时间 → 分区剪枝 + TTL

-- 【维度 3：典型反模式】
-- ❌ 高频 UPDATE → 用 ReplacingMergeTree 替代
-- ❌ SELECT * → 列存致命伤
-- ❌ 大表 JOIN → 用字典或宽表
-- ❌ PARTITION BY user_id → 破坏时间剪枝
-- ❌ ORDER BY (gender) → 低基数列无法裁剪

-- ============================================================================
-- §8. 清理与小结
-- ============================================================================
-- 【本章核心结论】
-- 1. CH 建模哲学：反范式宽表 + 预聚合 MV + 字典替代 JOIN
-- 2. ORDER BY 是灵魂：前缀匹配高频查询，2-4 列足够
-- 3. PARTITION BY 按月：分区剪枝 + TTL 过期的最佳粒度
-- 4. 时序数据：指标固定用宽表，多变用长表
-- 5. 用户行为：原始事件 + MV → 宽表 + 漏斗/RFM 报表

-- 清理（保留表结构便于回看）
-- DROP DATABASE IF EXISTS getting_started_test;
