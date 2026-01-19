-- ================================================
-- 01_basic_operations.sql
-- ClickHouse 基础操作示例
-- ================================================

-- ========================================
-- 1. 创建普通 MergeTree 表
-- ========================================
CREATE TABLE IF NOT EXISTS test_users (
    id UInt64,
    name String,
    email String,
    age UInt8,
    created_at DateTime DEFAULT now(),
    updated_at DateTime DEFAULT now()
) ENGINE = MergeTree()
ORDER BY id;

-- 查看表结构
DESCRIBE test_users;

-- 查看创建语句
SHOW CREATE test_users;

-- ========================================
-- 2. 插入数据
-- ========================================
INSERT INTO test_users (id, name, email, age) VALUES
(1, 'Alice', 'alice@example.com', 25),
(2, 'Bob', 'bob@example.com', 30),
(3, 'Charlie', 'charlie@example.com', 28),
(4, 'David', 'david@example.com', 35),
(5, 'Eve', 'eve@example.com', 22);

-- 批量插入（使用 VALUES）
INSERT INTO test_users VALUES
(6, 'Frank', 'frank@example.com', 40),
(7, 'Grace', 'grace@example.com', 29);

-- 批量插入（使用 SELECT）
INSERT INTO test_users (id, name, email, age)
SELECT
    number + 8 as id,
    concat('User_', toString(number)) as name,
    concat('user', toString(number), '@example.com') as email,
    20 + (number % 30) as age
FROM numbers(5);

-- ========================================
-- 3. 基本查询
-- ========================================
-- 查询所有数据
SELECT * FROM test_users;

-- 查询特定列
SELECT id, name, email FROM test_users;

-- 使用 WHERE 条件
SELECT * FROM test_users WHERE age > 30;

-- 使用 ORDER BY 排序
SELECT * FROM test_users ORDER BY age DESC LIMIT 5;

-- 使用 LIMIT 限制结果数量
SELECT * FROM test_users LIMIT 3;

-- ========================================
-- 4. 聚合查询
-- ========================================
-- COUNT 统计
SELECT count() as total_users FROM test_users;

-- SUM/AVG/MAX/MIN
SELECT
    count() as total_count,
    sum(age) as total_age,
    avg(age) as avg_age,
    min(age) as min_age,
    max(age) as max_age
FROM test_users;

-- GROUP BY 分组
SELECT age, count() as user_count FROM test_users GROUP BY age ORDER BY age;

-- HAVING 过滤分组
SELECT age, count() as user_count
FROM test_users
GROUP BY age
HAVING count() >= 2
ORDER BY age;

-- ========================================
-- 5. 高级查询
-- ========================================
-- JOIN 操作
CREATE TABLE IF NOT EXISTS test_orders (
    order_id UInt64,
    user_id UInt64,
    product_id UInt32,
    amount Decimal(10, 2),
    order_date DateTime DEFAULT now()
) ENGINE = MergeTree()
ORDER BY order_id;

INSERT INTO test_orders (order_id, user_id, product_id, amount) VALUES
(1, 1, 101, 99.99),
(2, 1, 102, 49.99),
(3, 2, 103, 199.99),
(4, 3, 101, 99.99),
(5, 4, 104, 149.99);

-- INNER JOIN
SELECT
    u.name,
    u.email,
    o.order_id,
    o.amount
FROM test_users u
INNER JOIN test_orders o ON u.id = o.user_id
ORDER BY u.id, o.order_id;

-- LEFT JOIN
SELECT
    u.name,
    count(o.order_id) as order_count,
    sum(o.amount) as total_spent
FROM test_users u
LEFT JOIN test_orders o ON u.id = o.user_id
GROUP BY u.id, u.name
ORDER BY total_spent DESC;

-- ========================================
-- 6. 窗口函数
-- ========================================
SELECT
    id,
    name,
    age,
    ROW_NUMBER() OVER (ORDER BY age DESC) as age_rank,
    RANK() OVER (ORDER BY age DESC) as age_rank_dense,
    DENSE_RANK() OVER (ORDER BY age DESC) as age_rank_dense2,
    NTILE(4) OVER (ORDER BY age DESC) as age_quartile,
    LAG(age) OVER (ORDER BY age DESC) as prev_age,
    LEAD(age) OVER (ORDER BY age DESC) as next_age
FROM test_users
ORDER BY age DESC;

-- ========================================
-- 7. CTE (Common Table Expression)
-- ========================================
WITH user_stats AS (
    SELECT
        id,
        name,
        age,
        CASE
            WHEN age < 25 THEN 'Young'
            WHEN age < 35 THEN 'Adult'
            ELSE 'Senior'
        END as age_group
    FROM test_users
)
SELECT
    age_group,
    count() as user_count,
    avg(age) as avg_age
FROM user_stats
GROUP BY age_group
ORDER BY avg_age;

-- ========================================
-- 8. 条件表达式
-- ========================================
SELECT
    id,
    name,
    age,
    CASE
        WHEN age < 25 THEN 'Young'
        WHEN age < 35 THEN 'Adult'
        WHEN age < 50 THEN 'Middle-aged'
        ELSE 'Senior'
    END as age_category,
    multiIf(age < 25, 'Young', age < 35, 'Adult', 'Senior') as age_category2
FROM test_users
ORDER BY age;

-- IF 函数
SELECT
    id,
    name,
    age,
    if(age >= 30, 'Senior Member', 'Junior Member') as membership_level
FROM test_users
ORDER BY age DESC;

-- ========================================
-- 9. 字符串操作
-- ========================================
SELECT
    id,
    name,
    email,
    length(name) as name_length,
    lower(name) as name_lower,
    upper(name) as name_upper,
    substring(name, 1, 3) as name_prefix,
    splitByChar('@', email)[1] as email_username,
    replace(email, 'example.com', 'test.com') as new_email
FROM test_users
LIMIT 5;

-- ========================================
-- 10. 日期时间操作
-- ========================================
SELECT
    id,
    name,
    created_at,
    toDate(created_at) as date_only,
    toYYYYMM(created_at) as year_month,
    toStartOfMonth(created_at) as month_start,
    dateDiff('day', created_at, now()) as days_since_creation,
    formatDateTime(created_at, '%Y-%m-%d %H:%M:%S') as formatted_date
FROM test_users
ORDER BY created_at;

-- ========================================
-- 11. 数组操作
-- ========================================
CREATE TABLE IF NOT EXISTS test_products (
    id UInt64,
    name String,
    tags Array(String),
    prices Array(Decimal(10, 2))
) ENGINE = MergeTree()
ORDER BY id;

INSERT INTO test_products VALUES
(1, 'Laptop', ['electronics', 'computer', 'work'], [999.99, 899.99]),
(2, 'Chair', ['furniture', 'office', 'ergonomic'], [199.99, 179.99]),
(3, 'Book', ['education', 'reading'], [29.99, 24.99, 19.99]);

-- 数组操作
SELECT
    name,
    tags,
    length(tags) as tag_count,
    tags[1] as first_tag,
    has(tags, 'electronics') as has_electronics,
    arrayJoin(tags) as tag_expanded,
    max(prices) as max_price,
    min(prices) as min_price,
    avg(prices) as avg_price
FROM test_products
ORDER BY id;

-- ========================================
-- 12. 清理测试表
-- ========================================
DROP TABLE IF EXISTS test_users;
DROP TABLE IF EXISTS test_orders;
DROP TABLE IF EXISTS test_products;

-- ========================================
-- 13. 查看所有表
-- ========================================
SHOW TABLES;
