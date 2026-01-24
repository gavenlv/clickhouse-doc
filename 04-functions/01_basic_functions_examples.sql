-- ============================================================================
-- ClickHouse Basic Functions Examples
-- ============================================================================
-- This file demonstrates various function categories in ClickHouse
-- including aggregate functions, string functions, date/time functions, etc.
-- ============================================================================

-- ============================================================================
-- 1. AGGREGATE FUNCTIONS
-- ============================================================================

-- Create test data for aggregation
CREATE DATABASE IF NOT EXISTS functions_test;
USE functions_test;

DROP TABLE IF EXISTS sales_data;

CREATE TABLE sales_data (
    id UInt64,
    product_id UInt32,
    category String,
    quantity UInt32,
    price Decimal(10, 2),
    sale_date Date,
    region String
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(sale_date)
ORDER BY (product_id, sale_date);

-- Insert test data
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

-- Basic aggregate functions
SELECT 
    count() as total_records,
    count(DISTINCT product_id) as unique_products,
    count(DISTINCT category) as unique_categories,
    sum(quantity) as total_quantity,
    sum(quantity * price) as total_revenue,
    avg(price) as avg_price,
    min(price) as min_price,
    max(price) as max_price
FROM sales_data;

-- Aggregate with GROUP BY
SELECT 
    category,
    count() as sales_count,
    sum(quantity) as total_quantity,
    sum(quantity * price) as total_revenue,
    avg(price) as avg_price,
    min(price) as min_price,
    max(price) as max_price
FROM sales_data
GROUP BY category
ORDER BY total_revenue DESC;

-- Aggregate with multiple GROUP BY
SELECT 
    category,
    region,
    count() as sales_count,
    sum(quantity) as total_quantity,
    round(sum(quantity * price), 2) as total_revenue
FROM sales_data
GROUP BY category, region
ORDER BY category, total_revenue DESC;

-- Conditional aggregation with if and multiIf
SELECT 
    category,
    sumIf(quantity, region = 'North') as north_quantity,
    sumIf(quantity, region = 'South') as south_quantity,
    avgIf(price, category = 'Electronics') as electronics_avg_price,
    countIf(price > 100) as expensive_items_count
FROM sales_data
GROUP BY category;

-- Statistical aggregate functions
SELECT 
    category,
    -- round(variance(price), 2) as price_variance,
    -- round(stddev(price), 2) as price_stddev,
    quantile(0.5)(price) as median_price,
    quantile(0.9)(price) as p90_price
FROM sales_data
GROUP BY category;

-- ============================================================================
-- 2. STRING FUNCTIONS
-- ============================================================================

DROP TABLE IF EXISTS users_data;

CREATE TABLE users_data (
    id UInt64,
    username String,
    email String,
    full_name String,
    bio String,
    signup_date Date
) ENGINE = MergeTree()
ORDER BY id;

INSERT INTO users_data VALUES
    (1, 'john_doe', 'john.doe@example.com', 'John Doe', 'Software Engineer at Tech Corp', '2024-01-15'),
    (2, 'jane_smith', 'jane.smith@example.com', 'Jane Smith', 'Data Scientist working with Big Data', '2024-01-16'),
    (3, 'bob_wilson', 'bob.wilson@company.com', 'Bob Wilson', 'DevOps Engineer', '2024-01-17'),
    (4, 'alice_brown', 'alice.brown@work.com', 'Alice Brown', 'Full Stack Developer', '2024-01-18'),
    (5, 'charlie_davis', 'charlie.davis@example.com', 'Charlie Davis', 'Backend Engineer', '2024-01-19');

-- Basic string functions
SELECT 
    id,
    username,
    length(username) as username_length,
    upper(username) as username_upper,
    lower(email) as email_lower,
    concat('User: ', username, ' - ', email) as user_info,
    substring(username, 1, 4) as username_prefix,
    substring(email, 1, position(email, '@') - 1) as email_name_part
FROM users_data;

-- String manipulation functions
SELECT 
    id,
    email,
    splitByChar('@', email) as email_parts,
    arrayElement(splitByChar('@', email), 1) as email_local,
    arrayElement(splitByChar('@', email), 2) as email_domain,
    trim(LEADING 'Software' FROM bio) as bio_trimmed,
    replaceRegexpOne(username, '_', ' ') as username_readable
FROM users_data;

-- String matching functions
SELECT 
    id,
    username,
    email,
    -- Check if email domain matches
    multiIf(
        endsWith(email, '@example.com'), 'Standard domain',
        endsWith(email, '@company.com'), 'Company domain',
        endsWith(email, '@work.com'), 'Work domain',
        'Other domain'
    ) as domain_type,
    -- Check username length category
    multiIf(
        length(username) < 8, 'Short',
        length(username) < 12, 'Medium',
        'Long'
    ) as username_length_category
FROM users_data;

-- String search functions
SELECT 
    id,
    username,
    bio,
    positionCaseInsensitive(bio, 'Engineer') as engineer_position,
    countMatches(bio, 'Engineer') as engineer_count,
    extractAll(bio, '[A-Z][a-z]+') as words_in_bio
FROM users_data;

-- ============================================================================
-- 3. DATE/TIME FUNCTIONS
-- ============================================================================

DROP TABLE IF EXISTS events_data;

CREATE TABLE events_data (
    id UInt64,
    event_name String,
    event_time DateTime,
    duration_seconds UInt32,
    user_id UInt64
) ENGINE = MergeTree()
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

-- Date/time extraction functions
SELECT 
    id,
    event_name,
    event_time,
    toYear(event_time) as year,
    toMonth(event_time) as month,
    toDayOfMonth(event_time) as day,
    toHour(event_time) as hour,
    toMinute(event_time) as minute,
    toSecond(event_time) as second,
    toDayOfWeek(event_time) as day_of_week,
    toWeek(event_time) as week_of_year,
    toQuarter(event_time) as quarter
FROM events_data;

-- Date/time calculation functions
SELECT 
    id,
    event_name,
    event_time,
    -- Current time comparisons
    now() as current_time,
    dateDiff('day', event_time, now()) as days_ago,
    dateDiff('hour', event_time, now()) as hours_ago,
    -- Time additions/subtractions
    addDays(event_time, 7) as week_later,
    addHours(event_time, 24) as day_later,
    subtractDays(event_time, 1) as day_before,
    -- Start/end of periods
    toStartOfDay(event_time) as day_start,
    toStartOfMonth(event_time) as month_start,
    toStartOfWeek(event_time) as week_start,
    toStartOfQuarter(event_time) as quarter_start,
    toStartOfYear(event_time) as year_start
FROM events_data
LIMIT 5;

-- Date/time format functions
SELECT 
    id,
    event_time,
    formatDateTime(event_time, '%Y-%m-%d') as date_only,
    formatDateTime(event_time, '%H:%M:%S') as time_only,
    formatDateTime(event_time, '%Y年%m月%d日 %H:%M') as formatted_chinese,
    formatDateTime(event_time, '%A, %B %d, %Y') as formatted_english
FROM events_data
LIMIT 5;

-- Date/time parsing functions
SELECT 
    '2024-01-15' as date_str,
    parseDateTimeBestEffort('2024-01-15') as parsed_date,
    parseDateTimeBestEffort('2024-01-15 10:30:00') as parsed_datetime,
    parseDateTimeBestEffort('2024/01/15') as parsed_date_slash;

-- ============================================================================
-- 4. MATH FUNCTIONS
-- ============================================================================

DROP TABLE IF EXISTS numeric_data;

CREATE TABLE numeric_data (
    id UInt64,
    value1 Float32,
    value2 Float32,
    value3 Int32
) ENGINE = MergeTree()
ORDER BY id;

INSERT INTO numeric_data VALUES
    (1, 10.5, 20.3, 100),
    (2, 15.2, 30.1, 200),
    (3, 8.7, 25.4, 150),
    (4, 12.3, 22.8, 180),
    (5, 9.9, 28.6, 120);

-- Basic math functions
SELECT 
    id,
    value1,
    value2,
    value3,
    -- Basic operations
    round(value1) as rounded1,
    round(value1, 1) as rounded1_decimal,
    floor(value1) as floored1,
    ceil(value2) as ceiled2,
    abs(value3 - 150) as abs_difference,
    -- Power and root
    pow(value1, 2) as value1_squared,
    sqrt(value1) as value1_sqrt,
    exp(value1 / 10) as exp_result,
    log10(value1) as log10_result,
    -- Trigonometric
    sin(toFloat32(3.14159 / 4)) as sin_45deg,
    cos(toFloat32(3.14159 / 6)) as cos_30deg,
    tan(toFloat32(3.14159 / 4)) as tan_45deg
FROM numeric_data;

-- ============================================================================
-- 5. CONDITIONAL FUNCTIONS
-- ============================================================================

DROP TABLE IF EXISTS product_inventory;

CREATE TABLE product_inventory (
    id UInt64,
    product_name String,
    stock UInt32,
    reorder_point UInt32,
    price Decimal(10, 2),
    category String
) ENGINE = MergeTree()
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

-- if function
SELECT 
    product_name,
    stock,
    reorder_point,
    if(stock >= reorder_point, 'In Stock', 'Low Stock') as stock_status
FROM product_inventory;

-- ifNull and nullIf
SELECT 
    product_name,
    stock,
    -- ifNull: return alternative if value is NULL
    ifNull(stock, 0) as safe_stock,
    -- nullIf: return NULL if values are equal
    nullIf(stock, reorder_point) as stock_if_not_equal
FROM product_inventory;

-- multiIf for multiple conditions
SELECT 
    product_name,
    stock,
    reorder_point,
    multiIf(
        stock = 0, 'Out of Stock',
        stock < reorder_point, 'Critical Stock',
        stock < reorder_point * 2, 'Normal Stock',
        'High Stock'
    ) as stock_level
FROM product_inventory;

-- ============================================================================
-- 6. ARRAY FUNCTIONS
-- ============================================================================

DROP TABLE IF EXISTS tags_data;

CREATE TABLE tags_data (
    id UInt64,
    item_name String,
    tags Array(String),
    scores Array(UInt8)
) ENGINE = MergeTree()
ORDER BY id;

INSERT INTO tags_data VALUES
    (1, 'Article 1', ['tech', 'programming', 'tutorial'], [8, 9, 7]),
    (2, 'Article 2', ['business', 'finance'], [6, 8]),
    (3, 'Article 3', ['tech', 'ai', 'machine-learning', 'data'], [9, 10, 9, 8]),
    (4, 'Article 4', ['health', 'fitness', 'nutrition'], [7, 8, 6]),
    (5, 'Article 5', ['tech', 'startup'], [8, 9]);

-- Basic array functions
SELECT 
    item_name,
    tags,
    length(tags) as tag_count,
    has(tags, 'tech') as has_tech_tag,
    indexOf(tags, 'tech') as tech_tag_position,
    arrayJoin(tags) as individual_tag,
    item_name as article_name
FROM tags_data;

-- Array manipulation
SELECT 
    item_name,
    tags,
    -- Concatenate arrays
    arrayConcat(tags, ['general']) as tags_with_general,
    // Append to array
    arrayPushBack(tags, 'featured') as tags_featured,
    arrayPushFront(tags, 'new') as tags_new,
    // Slice array
    arraySlice(tags, 1, 2) as first_two_tags
FROM tags_data;

-- Array aggregate functions
SELECT 
    item_name,
    scores,
    // Array aggregates
    arraySum(scores) as total_score,
    arrayAvg(scores) as avg_score,
    arrayMin(scores) as min_score,
    arrayMax(scores) as max_score,
    arraySort(scores) as sorted_scores
FROM tags_data;

-- ============================================================================
-- 7. TYPE CONVERSION FUNCTIONS
-- ============================================================================

DROP TABLE IF EXISTS mixed_data;

CREATE TABLE mixed_data (
    id UInt64,
    string_num String,
    date_str String,
    bool_str String
) ENGINE = MergeTree()
ORDER BY id;

INSERT INTO mixed_data VALUES
    (1, '123', '2024-01-15', 'true'),
    (2, '456.78', '2024-02-20', 'false'),
    (3, '789', '2024-03-10', '1'),
    (4, '100.5', '2024-04-05', '0');

-- Type conversions
SELECT 
    id,
    string_num,
    // String to number conversions
    toInt32(string_num) as to_int32,
    toFloat32(string_num) as to_float32,
    toDecimal128(string_num, 2) as to_decimal128,
    // String to date
    toDate(date_str) as to_date,
    toDateTime(date_str) as to_datetime,
    // String to boolean
    toInt8(bool_str) = 1 as to_bool_from_string
FROM mixed_data;

-- ============================================================================
-- 8. HASH FUNCTIONS
-- ============================================================================

DROP TABLE IF EXISTS user_sessions;

CREATE TABLE user_sessions (
    id UInt64,
    user_id UInt64,
    session_id String,
    ip_address String
) ENGINE = MergeTree()
ORDER BY id;

INSERT INTO user_sessions VALUES
    (1, 1001, 'session_abc123', '192.168.1.1'),
    (2, 1002, 'session_def456', '192.168.1.2'),
    (3, 1001, 'session_ghi789', '192.168.1.1'),
    (4, 1003, 'session_jkl012', '192.168.1.3'),
    (5, 1002, 'session_mno345', '192.168.1.2');

-- Hash functions
SELECT 
    user_id,
    session_id,
    ip_address,
    // Different hash functions
    md5(session_id) as md5_hash,
    sha1(session_id) as sha1_hash,
    sha256(session_id) as sha256_hash,
    // Consistent hashing (same input always produces same output)
    sipHash64(session_id) as siphash,
    xxHash64(session_id) as xxhash,
    // Hash for partitioning
    intHash32(user_id) as int_hash_32,
    cityHash64(session_id) as city_hash
FROM user_sessions;

-- Using hash for grouping
SELECT 
    sipHash64(ip_address) as ip_hash,
    count() as session_count
FROM user_sessions
GROUP BY ip_hash;

-- ============================================================================
-- 9. IP ADDRESS FUNCTIONS
-- ============================================================================

DROP TABLE IF EXISTS access_logs;

CREATE TABLE access_logs (
    id UInt64,
    client_ip String,
    server_ip String,
    access_time DateTime
) ENGINE = MergeTree()
ORDER BY access_time;

INSERT INTO access_logs VALUES
    (1, '192.168.1.100', '10.0.0.1', '2024-01-15 08:00:00'),
    (2, '192.168.1.101', '10.0.0.1', '2024-01-15 08:01:00'),
    (3, '172.16.0.50', '10.0.0.2', '2024-01-15 08:02:00'),
    (4, '10.0.1.200', '10.0.0.1', '2024-01-15 08:03:00'),
    (5, '192.168.1.100', '10.0.0.3', '2024-01-15 08:04:00');

-- IP address functions
SELECT 
    id,
    client_ip,
    server_ip,
    // Convert to IPv4
    toIPv4(client_ip) as client_ipv4,
    toIPv4(server_ip) as server_ipv4,
    // Convert to numeric
    IPv4NumToString(toIPv4(client_ip)) as client_back_to_string,
    // Extract network
    IPv4NumToClassC(toIPv4(client_ip)) as client_class_c,
    // Check IP type
    multiIf(
        client_ip LIKE '192.168.%', 'Private IP (192.168.x.x)',
        client_ip LIKE '10.%', 'Private IP (10.x.x.x)',
        client_ip LIKE '172.16.%', 'Private IP (172.16.x.x)',
        'Public IP'
    ) as ip_type
FROM access_logs;

-- ============================================================================
-- 10. JSON FUNCTIONS (Basic)
-- ============================================================================

DROP TABLE IF EXISTS json_data;

CREATE TABLE json_data (
    id UInt64,
    json_string String,
    user_info String
) ENGINE = MergeTree()
ORDER BY id;

INSERT INTO json_data VALUES
    (1, '{"name":"John","age":30,"city":"New York"}', '{"id":1001,"active":true,"roles":["admin","user"]}'),
    (2, '{"name":"Jane","age":25,"city":"London"}', '{"id":1002,"active":false,"roles":["user"]}'),
    (3, '{"name":"Bob","age":35,"city":"Paris"}', '{"id":1003,"active":true,"roles":["admin","editor","user"]}');

-- JSON parsing functions
SELECT 
    id,
    json_string,
    // Simple JSON extraction
    JSONExtractString(json_string, 'name') as name,
    JSONExtractUInt(json_string, 'age') as age,
    JSONExtractString(json_string, 'city') as city,
    // Nested JSON extraction
    JSONExtractString(user_info, 'roles') as roles_string,
    JSONExtractBool(user_info, 'active') as is_active
FROM json_data;

-- JSONPath extraction (more flexible)
SELECT 
    id,
    json_string,
    // Using JSONPath syntax
    JSONExtractString(json_string, '$.name') as jsonpath_name,
    JSONExtractUInt(json_string, '$.age') as jsonpath_age
FROM json_data;

-- ============================================================================
-- CLEANUP
-- ============================================================================

-- Uncomment to drop test database
-- DROP DATABASE IF EXISTS functions_test;
