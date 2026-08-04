-- ============================================================
-- 文件: 05-functions/01_basic_functions_examples.sql
-- 学习目标: 掌握 ClickHouse 标量/聚合/状态函数的原理与应用
-- 深度标准: 原理 + 场景 + 对比 + 可运行
-- 集群: treasurycluster (CH 25.12.1.649, 2 副本)
-- 前置: 无（自包含测试数据，按顺序执行）
-- ============================================================
--
-- 本文件章节:
--   1.  聚合函数基础
--   2.  字符串函数
--   3.  日期时间函数
--   4.  数学函数
--   5.  条件函数
--   6.  数组函数（含 arrayJoin 展开原理）
--   7.  类型转换函数
--   8.  哈希函数
--   9.  IP 地址函数
--   10. JSON 函数（JSONExtract vs JSON 类型对比）
--   11. 聚合状态函数 sumState/sumMerge（核心进阶，配合 AggregatingMergeTree）
--   12. Map 函数
--   13. 清理
-- ============================================================

CREATE DATABASE IF NOT EXISTS functions_test ON CLUSTER 'treasurycluster';
USE functions_test;


-- ============================================================
-- 1. 聚合函数基础
-- ============================================================
-- 【原理】聚合函数在 ClickHouse 中走"分组聚合管道"：
--   1) 读取阶段：按 ORDER BY/分区键流式读取列数据
--   2) 聚合阶段：用向量化(SIMD)计算每个分组的累加器
--   3) 输出阶段：每个分组输出一行
-- 详见 02-principles/06_query_execution.md
-- 【场景】统计报表、监控指标、去重计数
-- 【对比】聚合 vs 窗口：聚合折叠行数，窗口不折叠（见 02 文件）

DROP TABLE IF EXISTS sales_data ON CLUSTER 'treasurycluster' SYNC;

CREATE TABLE sales_data ON CLUSTER 'treasurycluster' (
    id UInt64,
    product_id UInt32,
    category String,
    quantity UInt32,
    price Decimal(10, 2),
    sale_date Date,
    region String
) ENGINE = ReplicatedMergeTree()
PARTITION BY toYYYYMM(sale_date)
ORDER BY (product_id, sale_date);

INSERT INTO sales_data VALUES
    (1, 101, 'Electronics', 2, 299.99, '2024-01-15', 'North'),
    (2, 101, 'Electronics', 1, 299.99, '2024-01-16', 'South'),
    (3, 102, 'Electronics', 3, 499.99, '2024-01-15', 'East'),
    (4, 103, 'Clothing', 5, 49.99, '2024-01-15', 'West'),
    (5, 103, 'Clothing', 2, 49.99, '2024-01-17', 'North'),
    (6, 104, 'Electronics', 1, 899.99, '2024-01-16', 'South'),
    (7, 105, 'Clothing', 10, 29.99, '2024-01-17', 'East'),
    (8, 101, 'Electronics', 4, 299.99, '2024-01-18', 'West'),
    (9, 102, 'Electronics', 2, 499.99, '2024-01-18', 'North'),
    (10, 106, 'Books', 15, 19.99, '2024-01-18', 'South');

-- 1.1 基础聚合（全表）
-- 【结果解读】count()=10, sum(quantity*price) 为总 GMV
SELECT
    count() AS total_records,
    count(DISTINCT product_id) AS unique_products,
    count(DISTINCT category) AS unique_categories,
    sum(quantity) AS total_quantity,
    sum(quantity * price) AS total_revenue,
    avg(price) AS avg_price,
    min(price) AS min_price,
    max(price) AS max_price
FROM sales_data;

-- 1.2 分组聚合
-- 【结果解读】按 category 分组，Electronics 的 GMV 最高
SELECT
    category,
    count() AS sales_count,
    sum(quantity) AS total_quantity,
    sum(quantity * price) AS total_revenue,
    avg(price) AS avg_price,
    min(price) AS min_price,
    max(price) AS max_price
FROM sales_data
GROUP BY category
ORDER BY total_revenue DESC;

-- 1.3 多维分组
SELECT
    category,
    region,
    count() AS sales_count,
    sum(quantity) AS total_quantity,
    round(sum(quantity * price), 2) AS total_revenue
FROM sales_data
GROUP BY category, region
ORDER BY category, total_revenue DESC;

-- 1.4 条件聚合 *If 组合子
-- 【原理】sumIf(expr, cond) = sum(expr) 只累加满足 cond 的行
-- 【对比】等价于 sum(if(cond, expr, 0))，但 *If 更高效（少一次 if 计算）
-- 【场景】报表的"分列对比"（同一查询出北/南/东/西各自指标）
SELECT
    category,
    sumIf(quantity, region = 'North') AS north_quantity,
    sumIf(quantity, region = 'South') AS south_quantity,
    avgIf(price, category = 'Electronics') AS electronics_avg_price,
    countIf(price > 100) AS expensive_items_count
FROM sales_data
GROUP BY category;

-- 1.5 统计聚合：分位数
-- 【原理】quantile(p)(x) 用 reservoir sampling 近似，内存恒定
-- 【对比】quantileExact 精确但耗内存；quantileTDigest 更快但误差略大
-- 【场景】P50/P90/P99 延迟监控
SELECT
    category,
    quantile(0.5)(price) AS median_price,
    quantile(0.9)(price) AS p90_price,
    quantileExact(0.5)(price) AS exact_median
FROM sales_data
GROUP BY category;


-- ============================================================
-- 2. 字符串函数
-- ============================================================
-- 【原理】ClickHouse 字符串是字节序列，length() 返回字节数（非字符数）；
--   char_length() 才是字符数。对纯 ASCII 二者相等，对中文不同。
-- 【场景】日志解析、JSON 文本处理、URL 拆解

DROP TABLE IF EXISTS users_data ON CLUSTER 'treasurycluster' SYNC;

CREATE TABLE users_data ON CLUSTER 'treasurycluster' (
    id UInt64,
    username String,
    email String,
    full_name String,
    bio String,
    signup_date Date
) ENGINE = ReplicatedMergeTree()
ORDER BY id;

INSERT INTO users_data VALUES
    (1, 'john_doe', 'john.doe@example.com', 'John Doe', 'Software Engineer at Tech Corp', '2024-01-15'),
    (2, 'jane_smith', 'jane.smith@example.com', 'Jane Smith', 'Data Scientist working with Big Data', '2024-01-16'),
    (3, 'bob_wilson', 'bob.wilson@company.com', 'Bob Wilson', 'DevOps Engineer', '2024-01-17'),
    (4, 'alice_brown', 'alice.brown@work.com', 'Alice Brown', 'Full Stack Developer', '2024-01-18'),
    (5, 'charlie_davis', 'charlie.davis@example.com', 'Charlie Davis', 'Backend Engineer', '2024-01-19');

-- 2.1 基础字符串操作
SELECT
    id,
    username,
    length(username) AS username_length,
    upper(username) AS username_upper,
    lower(email) AS email_lower,
    concat('User: ', username, ' - ', email) AS user_info,
    substring(username, 1, 4) AS username_prefix,
    -- 截取 @ 前的本地名
    substring(email, 1, position(email, '@') - 1) AS email_local_part
FROM users_data;

-- 2.2 分割与连接
-- 【原理】splitByChar 返回 Array(String)，arrayElement(arr, n) 取第 n 个元素（1-based）
SELECT
    id,
    email,
    splitByChar('@', email) AS email_parts,
    arrayElement(splitByChar('@', email), 1) AS email_local,
    arrayElement(splitByChar('@', email), 2) AS email_domain,
    trim(LEADING 'Software' FROM bio) AS bio_trimmed,
    replaceRegexpOne(username, '_', ' ') AS username_readable
FROM users_data;

-- 2.3 模式匹配
SELECT
    id,
    username,
    email,
    multiIf(
        endsWith(email, '@example.com'), 'Standard domain',
        endsWith(email, '@company.com'), 'Company domain',
        endsWith(email, '@work.com'), 'Work domain',
        'Other domain'
    ) AS domain_type,
    multiIf(
        length(username) < 8, 'Short',
        length(username) < 12, 'Medium',
        'Long'
    ) AS username_length_category
FROM users_data;

-- 2.4 搜索与正则
-- 【原理】extractAll 返回所有匹配的数组；countMatches 返回匹配次数
SELECT
    id,
    username,
    bio,
    positionCaseInsensitive(bio, 'Engineer') AS engineer_position,
    countMatches(bio, 'Engineer') AS engineer_count,
    extractAll(bio, '[A-Z][a-z]+') AS words_in_bio
FROM users_data;


-- ============================================================
-- 3. 日期时间函数
-- ============================================================
-- 【原理】Date 是天数(UInt16)，DateTime 是秒级 Unix 时间戳(UInt32)，
--   DateTime64 支持亚秒。所有日期函数本质是对时间戳的算术运算。
-- 【场景】时间分区、按时间聚合、留存/漏斗
-- 【对比】详见 10-date-update 章节

DROP TABLE IF EXISTS events_data ON CLUSTER 'treasurycluster' SYNC;

CREATE TABLE events_data ON CLUSTER 'treasurycluster' (
    id UInt64,
    event_name String,
    event_time DateTime,
    duration_seconds UInt32,
    user_id UInt64
) ENGINE = ReplicatedMergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (user_id, event_time);

INSERT INTO events_data VALUES
    (1, 'login', '2024-01-15 08:30:00', 120, 1001),
    (2, 'page_view', '2024-01-15 08:32:00', 45, 1001),
    (3, 'purchase', '2024-01-15 09:15:00', 300, 1002),
    (4, 'logout', '2024-01-15 09:20:00', 60, 1001),
    (5, 'login', '2024-01-15 10:00:00', 90, 1003),
    (6, 'page_view', '2024-01-16 14:30:00', 35, 1002),
    (7, 'purchase', '2024-01-16 15:00:00', 250, 1003),
    (8, 'logout', '2024-01-16 16:30:00', 50, 1003),
    (9, 'login', '2024-01-17 09:00:00', 100, 1001),
    (10, 'page_view', '2024-01-17 09:30:00', 40, 1001);

-- 3.1 日期提取
SELECT
    id,
    event_name,
    event_time,
    toYear(event_time) AS year,
    toMonth(event_time) AS month,
    toDayOfMonth(event_time) AS day,
    toHour(event_time) AS hour,
    toMinute(event_time) AS minute,
    toSecond(event_time) AS second,
    toDayOfWeek(event_time) AS day_of_week,
    toWeek(event_time) AS week_of_year,
    toQuarter(event_time) AS quarter
FROM events_data;

-- 3.2 日期计算
-- 【原理】dateDiff(unit, a, b) 返回 b-a 的 unit 数；addDays/subtractDays 不改时区
SELECT
    id,
    event_name,
    event_time,
    now() AS current_time,
    dateDiff('day', event_time, now()) AS days_ago,
    dateDiff('hour', event_time, now()) AS hours_ago,
    addDays(event_time, 7) AS week_later,
    addHours(event_time, 24) AS day_later,
    subtractDays(event_time, 1) AS day_before,
    toStartOfDay(event_time) AS day_start,
    toStartOfMonth(event_time) AS month_start,
    toStartOfWeek(event_time) AS week_start,
    toStartOfQuarter(event_time) AS quarter_start,
    toStartOfYear(event_time) AS year_start
FROM events_data
LIMIT 5;

-- 3.3 日期格式化
-- 【原理】formatDateTime 用 strftime 风格占位符
SELECT
    id,
    event_time,
    formatDateTime(event_time, '%Y-%m-%d') AS date_only,
    formatDateTime(event_time, '%H:%M:%S') AS time_only,
    formatDateTime(event_time, '%Y年%m月%d日 %H:%M') AS formatted_chinese,
    -- 注意: CH 25.12 的 formatDateTime 不支持 %A/%B (星期/月份名),
    -- 用 dateName() 函数单独获取星期/月份名
    concat(dateName('weekday', event_time), ', ', dateName('month', event_time), ' ', toString(toDayOfMonth(event_time)), ', ', toString(toYear(event_time))) AS formatted_english
FROM events_data
LIMIT 5;

-- 3.4 日期解析（容错）
-- 【原理】parseDateTimeBestEffort 容错解析多种格式，无法解析返回 0
-- 【场景】清洗脏数据时间字符串
SELECT
    '2024-01-15' AS date_str,
    parseDateTimeBestEffort('2024-01-15') AS parsed_date,
    parseDateTimeBestEffort('2024-01-15 10:30:00') AS parsed_datetime,
    parseDateTimeBestEffort('2024/01/15') AS parsed_date_slash;


-- ============================================================
-- 4. 数学函数
-- ============================================================
-- 【原理】数学函数均为向量化实现，SIMD 加速；返回类型与输入一致或提升
-- 【场景】科学计算、统计、地理距离

DROP TABLE IF EXISTS numeric_data ON CLUSTER 'treasurycluster' SYNC;

CREATE TABLE numeric_data ON CLUSTER 'treasurycluster' (
    id UInt64,
    value1 Float32,
    value2 Float32,
    value3 Int32
) ENGINE = ReplicatedMergeTree()
ORDER BY id;

INSERT INTO numeric_data VALUES
    (1, 10.5, 20.3, 100),
    (2, 15.2, 30.1, 200),
    (3, 8.7, 25.4, 150),
    (4, 12.3, 22.8, 180),
    (5, 9.9, 28.6, 120);

SELECT
    id,
    value1,
    value2,
    value3,
    round(value1) AS rounded1,
    round(value1, 1) AS rounded1_decimal,
    floor(value1) AS floored1,
    ceil(value2) AS ceiled2,
    abs(value3 - 150) AS abs_difference,
    pow(value1, 2) AS value1_squared,
    sqrt(value1) AS value1_sqrt,
    exp(value1 / 10) AS exp_result,
    log10(value1) AS log10_result,
    sin(toFloat32(3.14159 / 4)) AS sin_45deg,
    cos(toFloat32(3.14159 / 6)) AS cos_30deg,
    tan(toFloat32(3.14159 / 4)) AS tan_45deg
FROM numeric_data;


-- ============================================================
-- 5. 条件函数
-- ============================================================
-- 【原理】if/multiIf 是短路求值；nullIf 常用于除零保护
-- 【对比】multiIf 比嵌套 CASE WHEN 可读性更好
-- 【场景】数据分级、哨兵值过滤、NULL 兜底

DROP TABLE IF EXISTS product_inventory ON CLUSTER 'treasurycluster' SYNC;

CREATE TABLE product_inventory ON CLUSTER 'treasurycluster' (
    id UInt64,
    product_name String,
    stock UInt32,
    reorder_point UInt32,
    price Decimal(10, 2),
    category String
) ENGINE = ReplicatedMergeTree()
ORDER BY id;

INSERT INTO product_inventory VALUES
    (1, 'Laptop', 50, 20, 999.99, 'Electronics'),
    (2, 'Mouse', 150, 50, 19.99, 'Electronics'),
    (3, 'Keyboard', 5, 20, 49.99, 'Electronics'),
    (4, 'Monitor', 30, 15, 299.99, 'Electronics'),
    (5, 'Headphones', 100, 30, 79.99, 'Electronics'),
    (6, 'USB Cable', 500, 100, 9.99, 'Accessories'),
    (7, 'Webcam', 2, 10, 59.99, 'Electronics'),
    (8, 'Power Adapter', 25, 25, 29.99, 'Accessories');

-- 5.1 if 二选一
SELECT
    product_name,
    stock,
    reorder_point,
    if(stock >= reorder_point, 'In Stock', 'Low Stock') AS stock_status
FROM product_inventory;

-- 5.2 nullIf / ifNull
-- 【原理】nullIf(a,b): a=b 时返回 NULL（用于过滤哨兵值，如 0 表示"无数据"）
--         ifNull(a,b): a 为 NULL 时返回 b（兜底）
SELECT
    product_name,
    stock,
    ifNull(stock, 0) AS safe_stock,
    nullIf(stock, reorder_point) AS stock_if_not_equal
FROM product_inventory;

-- 5.3 multiIf 多分支
SELECT
    product_name,
    stock,
    reorder_point,
    multiIf(
        stock = 0, 'Out of Stock',
        stock < reorder_point, 'Critical Stock',
        stock < reorder_point * 2, 'Normal Stock',
        'High Stock'
    ) AS stock_level
FROM product_inventory;


-- ============================================================
-- 6. 数组函数（重点：arrayJoin 展开原理）
-- ============================================================
-- 【原理】数组函数分两类：
--   ① 不改行数：arrayMap/arrayFilter/arraySort/arraySum 等（变换）
--   ② 改变行数：arrayJoin（1 行 → N 行，"反聚合"）
-- 【场景】标签展开、事件拆解、多维指标存储为数组

DROP TABLE IF EXISTS tags_data ON CLUSTER 'treasurycluster' SYNC;

CREATE TABLE tags_data ON CLUSTER 'treasurycluster' (
    id UInt64,
    item_name String,
    tags Array(String),
    scores Array(UInt8)
) ENGINE = ReplicatedMergeTree()
ORDER BY id;

INSERT INTO tags_data VALUES
    (1, 'Article 1', ['tech', 'programming', 'tutorial'], [8, 9, 7]),
    (2, 'Article 2', ['business', 'finance'], [6, 8]),
    (3, 'Article 3', ['tech', 'ai', 'machine-learning', 'data'], [9, 10, 9, 8]),
    (4, 'Article 4', ['health', 'fitness', 'nutrition'], [7, 8, 6]),
    (5, 'Article 5', ['tech', 'startup'], [8, 9]);

-- 6.1 arrayJoin：一行变多行（核心）
-- 【原理】arrayJoin(arr) 把数组的每个元素拆成单独一行，其余列复制
--   等价于其他数据库的 UNNEST，是 ClickHouse 独有的"反聚合"能力
-- 【场景】标签表展开后做 GROUP BY 统计每个标签出现次数
SELECT
    item_name,
    tags,
    length(tags) AS tag_count,
    has(tags, 'tech') AS has_tech_tag,
    indexOf(tags, 'tech') AS tech_tag_position,
    arrayJoin(tags) AS individual_tag
FROM tags_data;

-- 6.2 数组变换（不改行数）
SELECT
    item_name,
    tags,
    arrayConcat(tags, ['general']) AS tags_with_general,
    arrayPushBack(tags, 'featured') AS tags_featured,
    arrayPushFront(tags, 'new') AS tags_new,
    arraySlice(tags, 1, 2) AS first_two_tags
FROM tags_data;

-- 6.3 数组内聚合（不改行数，返回标量）
SELECT
    item_name,
    scores,
    arraySum(scores) AS total_score,
    arrayAvg(scores) AS avg_score,
    arrayMin(scores) AS min_score,
    arrayMax(scores) AS max_score,
    arraySort(scores) AS sorted_scores
FROM tags_data;

-- 6.4 arrayMap / arrayFilter（lambda 表达式）
-- 【原理】arrayMap(f, arr) 对每个元素套函数 f，返回新数组（1 进 1 出）
-- 【对比】arrayJoin 改变行数，arrayMap 不变
SELECT
    item_name,
    scores,
    arrayMap(x -> x * x, scores) AS squared_scores,
    arrayFilter(x -> x >= 8, scores) AS high_scores
FROM tags_data;


-- ============================================================
-- 7. 类型转换函数
-- ============================================================
-- 【原理】toInt32 等是"或抛错"转换；toInt32OrNull/toInt32OrZero 是容错版
-- 【场景】清洗脏数据、Decimal 精度控制
-- 【坑】Float → Int 会截断（非四舍五入）；超范围抛错

DROP TABLE IF EXISTS mixed_data ON CLUSTER 'treasurycluster' SYNC;

CREATE TABLE mixed_data ON CLUSTER 'treasurycluster' (
    id UInt64,
    string_num String,
    date_str String,
    bool_str String
) ENGINE = ReplicatedMergeTree()
ORDER BY id;

INSERT INTO mixed_data VALUES
    (1, '123', '2024-01-15', 'true'),
    (2, '456.78', '2024-02-20', 'false'),
    (3, '789', '2024-03-10', '1'),
    (4, '100.5', '2024-04-05', '0');

SELECT
    id,
    string_num,
    -- 注意: '456.78' 含小数点，toInt32 会抛错；先转 Float 再转 Int（截断小数）
    toInt32(toFloat64(string_num)) AS to_int32,
    toFloat32(string_num) AS to_float32,
    -- Decimal 必须用字符串构造，避免 Float 精度丢失
    toDecimal128(string_num, 2) AS to_decimal128,
    toDate(date_str) AS to_date,
    toDateTime(date_str) AS to_datetime,
    -- bool_str 可能是 'true'/'false' 或 '1'/'0'，统一用 multiIf 容错解析
    multiIf(lower(bool_str) = 'true', 1, lower(bool_str) = '1', 1, 0) = 1 AS to_bool_from_string,
    -- 容错转换（脏数据不抛错，返回 0 或 NULL）
    toInt32OrZero('abc') AS safe_int_from_bad,
    toInt32OrNull('abc') AS safe_int_null
FROM mixed_data;


-- ============================================================
-- 8. 哈希函数
-- ============================================================
-- 【原理】
--   - md5/sha1/sha256：加密哈希，慢，仅用于需要抗碰撞的场景
--   - sipHash64/xxHash64/cityHash64：非加密哈希，快，用于分片/去重
--   - intHash32：32 位整数哈希，常用于分片键
-- 【场景】分片路由、近似去重(uniq 底层用哈希)、数据脱敏

DROP TABLE IF EXISTS user_sessions ON CLUSTER 'treasurycluster' SYNC;

CREATE TABLE user_sessions ON CLUSTER 'treasurycluster' (
    id UInt64,
    user_id UInt64,
    session_id String,
    ip_address String
) ENGINE = ReplicatedMergeTree()
ORDER BY id;

INSERT INTO user_sessions VALUES
    (1, 1001, 'session_abc123', '192.168.1.1'),
    (2, 1002, 'session_def456', '192.168.1.2'),
    (3, 1001, 'session_ghi789', '192.168.1.1'),
    (4, 1003, 'session_jkl012', '192.168.1.3'),
    (5, 1002, 'session_mno345', '192.168.1.2');

SELECT
    user_id,
    session_id,
    ip_address,
    -- 注意: ClickHouse 函数名大小写敏感，哈希函数是大写
    MD5(session_id) AS md5_hash,
    SHA1(session_id) AS sha1_hash,
    SHA256(session_id) AS sha256_hash,
    -- 非加密哈希是小写驼峰
    sipHash64(session_id) AS siphash,
    xxHash64(session_id) AS xxhash,
    intHash32(user_id) AS int_hash_32,
    cityHash64(session_id) AS city_hash
FROM user_sessions;

-- 用哈希分组（数据脱敏/分桶）
SELECT
    sipHash64(ip_address) AS ip_hash,
    count() AS session_count
FROM user_sessions
GROUP BY ip_hash;


-- ============================================================
-- 9. IP 地址函数
-- ============================================================
-- 【原理】toIPv4 返回 IPv4 类型(等价 UInt32)，比存 String 省 4x 空间且比较快
-- 【场景】访问日志分析、风控、CDN 日志

DROP TABLE IF EXISTS access_logs ON CLUSTER 'treasurycluster' SYNC;

CREATE TABLE access_logs ON CLUSTER 'treasurycluster' (
    id UInt64,
    client_ip String,
    server_ip String,
    access_time DateTime
) ENGINE = ReplicatedMergeTree()
ORDER BY access_time;

INSERT INTO access_logs VALUES
    (1, '192.168.1.100', '10.0.0.1', '2024-01-15 08:00:00'),
    (2, '192.168.1.101', '10.0.0.1', '2024-01-15 08:01:00'),
    (3, '172.16.0.50', '10.0.0.2', '2024-01-15 08:02:00'),
    (4, '10.0.1.200', '10.0.0.1', '2024-01-15 08:03:00'),
    (5, '192.168.1.100', '10.0.0.3', '2024-01-15 08:04:00');

SELECT
    id,
    client_ip,
    server_ip,
    toIPv4(client_ip) AS client_ipv4,
    toIPv4(server_ip) AS server_ipv4,
    IPv4NumToString(toIPv4(client_ip)) AS client_back_to_string,
    -- 提取 C 类网络 (前 3 段): 用 splitByChar 取前 3 段拼接
    arrayStringConcat(arraySlice(splitByChar('.', client_ip), 1, 3), '.') AS client_class_c,
    -- IPv4CIDRToRange 返回 (start, end) tuple，可判断同网段
    IPv4CIDRToRange(toIPv4(client_ip), 24) AS client_cidr_24,
    multiIf(
        client_ip LIKE '192.168.%', 'Private IP (192.168.x.x)',
        client_ip LIKE '10.%', 'Private IP (10.x.x.x)',
        client_ip LIKE '172.16.%', 'Private IP (172.16.x.x)',
        'Public IP'
    ) AS ip_type
FROM access_logs;


-- ============================================================
-- 10. JSON 函数（JSONExtract vs JSON 类型对比）
-- ============================================================
-- 【原理】
--   - JSONExtract*(str, path)：每次查询都解析字符串，慢但灵活
--   - visitParam*(str, key)：轻量解析，仅支持扁平结构，快
--   - JSON 类型（实验）：存储时解析，查询快，支持路径索引
-- 【场景】半结构化数据；高频字段应抽成普通列
-- 【对比决策】见 README §5.3

DROP TABLE IF EXISTS json_data ON CLUSTER 'treasurycluster' SYNC;

CREATE TABLE json_data ON CLUSTER 'treasurycluster' (
    id UInt64,
    json_string String,
    user_info String
) ENGINE = ReplicatedMergeTree()
ORDER BY id;

INSERT INTO json_data VALUES
    (1, '{"name":"John","age":30,"city":"New York"}', '{"id":1001,"active":true,"roles":["admin","user"]}'),
    (2, '{"name":"Jane","age":25,"city":"London"}', '{"id":1002,"active":false,"roles":["user"]}'),
    (3, '{"name":"Bob","age":35,"city":"Paris"}', '{"id":1003,"active":true,"roles":["admin","editor","user"]}');

-- 10.1 JSONExtract 系列（按类型提取）
SELECT
    id,
    json_string,
    JSONExtractString(json_string, 'name') AS name,
    JSONExtractUInt(json_string, 'age') AS age,
    JSONExtractString(json_string, 'city') AS city,
    JSONExtractString(user_info, 'roles') AS roles_string,
    JSONExtractBool(user_info, 'active') AS is_active
FROM json_data;

-- 10.2 JSONPath 语法（更灵活，支持嵌套路径）
SELECT
    id,
    json_string,
    JSONExtractString(json_string, '$.name') AS jsonpath_name,
    JSONExtractUInt(json_string, '$.age') AS jsonpath_age
FROM json_data;

-- 10.3 visitParam 系列（仅扁平 JSON，更快）
-- 【对比】visitParam 只支持一层 key，不支持路径；JSONExtract 支持嵌套
SELECT
    id,
    visitParamExtractString(json_string, 'name') AS vp_name,
    visitParamExtractUInt(json_string, 'age') AS vp_age
FROM json_data;


-- ============================================================
-- 11. 聚合状态函数 sumState / sumMerge（核心进阶）
-- ============================================================
-- ★ 本章最重要的章节，原文件完全缺失，专门补齐
--
-- 【原理】
--   sumState(expr) 不返回数值，返回 AggregateFunction(Sum, T) 类型的
--   二进制"中间状态"。sumMerge(state) 把多个状态合并后产出最终值。
--   这就是"两阶段聚合"的本质：状态可存储、可传输、可再合并，不丢精度。
--
-- 【为什么需要】
--   1. 物化视图预聚合：明细表 INSERT 时，MV 用 *State 物化中间态
--   2. 分布式聚合：各分片 sumState → 协调节点 sumMerge
--   3. 跨时段汇总：日表 → 月表 → 年表，逐级 merge 不丢精度
--
-- 【对比】
--   方案A: SELECT sum(x) FROM 明细表 GROUP BY k   ← 每次重算 10 亿行，慢
--   方案B: SELECT sumMerge(s) FROM 日表_mv        ← 复用状态，快 10x+
--
-- 【坑】
--   - sumState 结果不能直接 SELECT 看数值（是二进制），需 sumMerge
--   - 状态列必须用 AggregatingMergeTree，INSERT 时同主键自动 merge

-- 11.1 明细表（10 条模拟订单，实际场景是 10 亿行）
DROP TABLE IF EXISTS orders_raw ON CLUSTER 'treasurycluster' SYNC;

CREATE TABLE orders_raw ON CLUSTER 'treasurycluster' (
    order_id UInt64,
    order_time DateTime,
    category String,
    amount Decimal(10, 2)
) ENGINE = ReplicatedMergeTree()
PARTITION BY toYYYYMM(order_time)
ORDER BY (category, order_time);

INSERT INTO orders_raw VALUES
    (1, '2024-01-15 08:00:00', 'Electronics', 299.99),
    (2, '2024-01-15 09:00:00', 'Electronics', 499.99),
    (3, '2024-01-15 10:00:00', 'Clothing', 49.99),
    (4, '2024-01-16 08:00:00', 'Electronics', 899.99),
    (5, '2024-01-16 09:00:00', 'Clothing', 29.99),
    (6, '2024-01-16 10:00:00', 'Books', 19.99),
    (7, '2024-02-01 08:00:00', 'Electronics', 299.99),
    (8, '2024-02-01 09:00:00', 'Clothing', 49.99),
    (9, '2024-02-02 08:00:00', 'Electronics', 499.99),
    (10, '2024-02-02 09:00:00', 'Books', 19.99);

-- 11.2 方案A：直接扫明细表（每次查询都重算）
SELECT
    toDate(order_time) AS d,
    category,
    sum(amount) AS gmv
FROM orders_raw
GROUP BY d, category
ORDER BY d, category;

-- 11.3 方案B：用 *State 建预聚合表（AggregatingMergeTree）
-- 【关键】列类型是 AggregateFunction(Sum, Decimal(10,2))，不是 Decimal！
DROP TABLE IF EXISTS orders_daily_mv ON CLUSTER 'treasurycluster' SYNC;

CREATE TABLE orders_daily_mv ON CLUSTER 'treasurycluster' (
    d Date,
    category String,
    -- 存"状态"而非"和"
    gmv_state AggregateFunction(Sum, Decimal(10, 2)),
    cnt_state AggregateFunction(Count, UInt64)
) ENGINE = AggregatingMergeTree()
PARTITION BY toYYYYMM(d)
ORDER BY (category, d);

-- 11.4 用 INSERT SELECT 把明细聚合进状态表
-- 【关键】这里用 sumState / countState 物化中间态
INSERT INTO orders_daily_mv
SELECT
    toDate(order_time) AS d,
    category,
    sumState(amount) AS gmv_state,
    countState() AS cnt_state
FROM orders_raw
GROUP BY d, category;

-- 11.5 查询预聚合表：用 *Merge 还原最终值
-- 【结果解读】结果与方案A 完全一致，但只扫描日表（行数少 100x+）
SELECT
    d,
    category,
    sumMerge(gmv_state) AS gmv,
    countMerge(cnt_state) AS order_cnt
FROM orders_daily_mv
GROUP BY d, category
ORDER BY d, category;

-- 11.6 二级聚合：日表 → 月表（状态可继续合并，不丢精度）
-- 【原理】这就是 *State 的威力：月表对日表的状态再做 merge
SELECT
    toStartOfMonth(d) AS month,
    category,
    sumMerge(gmv_state) AS monthly_gmv
FROM orders_daily_mv
GROUP BY month, category
ORDER BY month, category;

-- 11.7 其他 *State 家族演示：uniqState（近似去重 UV）
-- 【原理】uniq 底层是 HyperLogLog，uniqState 存 HLL 状态，
--   uniqMerge 跨分片合并 HLL，误差 <1%
-- 【场景】跨分片 UV 合并（分布式表查询时自动发生）
DROP TABLE IF EXISTS uv_demo ON CLUSTER 'treasurycluster' SYNC;

CREATE TABLE uv_demo ON CLUSTER 'treasurycluster' (
    d Date,
    uv_state AggregateFunction(uniq, UInt64)
) ENGINE = AggregatingMergeTree()
ORDER BY d;

INSERT INTO uv_demo
SELECT
    toDate(order_time) AS d,
    uniqState(toUInt64(order_id)) AS uv_state
FROM orders_raw
GROUP BY d;

SELECT
    d,
    uniqMerge(uv_state) AS uv
FROM uv_demo
GROUP BY d
ORDER BY d;

-- 11.8 quantileState：分位数监控（P50/P90 延迟）
-- 【原理】quantileState 存 reservoir sampling 状态，
--   quantileMerge 可跨时段合并分位数（普通 quantile 无法从已聚合值恢复）
DROP TABLE IF EXISTS latency_demo ON CLUSTER 'treasurycluster' SYNC;

CREATE TABLE latency_demo ON CLUSTER 'treasurycluster' (
    d Date,
    p90_state AggregateFunction(quantile(0.9), UInt32)
) ENGINE = AggregatingMergeTree()
ORDER BY d;

INSERT INTO latency_demo
SELECT
    toDate(order_time) AS d,
    quantileState(0.9)(toUInt32(toUnixTimestamp(order_time) % 1000)) AS p90_state
FROM orders_raw
GROUP BY d;

SELECT
    d,
    quantileMerge(0.9)(p90_state) AS p90_latency
FROM latency_demo
GROUP BY d
ORDER BY d;


-- ============================================================
-- 12. Map 函数
-- ============================================================
-- 【原理】Map(K,V) 是键值对类型，键有序去重；适合存储稀疏的多维指标
-- 【场景】用户画像标签、配置项、多语言文案

DROP TABLE IF EXISTS map_demo ON CLUSTER 'treasurycluster' SYNC;

CREATE TABLE map_demo ON CLUSTER 'treasurycluster' (
    id UInt64,
    profile Map(String, UInt32)
) ENGINE = ReplicatedMergeTree()
ORDER BY id;

INSERT INTO map_demo VALUES
    (1, {'age': 30, 'login_count': 100, 'order_count': 5}),
    (2, {'age': 25, 'login_count': 50, 'order_count': 2}),
    (3, {'age': 35, 'login_count': 200, 'order_count': 15});

-- 12.1 Map 读写
SELECT
    id,
    profile,
    profile['age'] AS age,
    profile['login_count'] AS login_count,
    mapKeys(profile) AS keys,
    mapValues(profile) AS values
FROM map_demo;

-- 12.2 Map 变换：mapApply（对每个 KV 套 lambda）
-- 【原理】mapApply(f, m) 返回新 Map，f 接收 tuple(key, value)
SELECT
    id,
    mapApply(k_v -> (k_v.1, k_v.2 * 2), profile) AS doubled_profile
FROM map_demo;


-- ============================================================
-- 13. 清理（如需）
-- ============================================================
-- DROP DATABASE IF EXISTS functions_test ON CLUSTER 'treasurycluster';
