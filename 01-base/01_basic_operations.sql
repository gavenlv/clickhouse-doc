-- ================================================
-- 01_basic_operations.sql
-- ClickHouse 基础操作示例
-- ================================================

-- ========================================
-- 1. 创建普通 MergeTree 表（生产环境：使用复制引擎 + ON CLUSTER）
-- ========================================
create database if not exists test;
use test;

drop TABLE if EXISTS test_users ON CLUSTER treasurycluster SYNC;
CREATE TABLE IF NOT EXISTS test_users ON CLUSTER 'treasurycluster' (
    id UInt64,
    name String,
    email String,
    age UInt8,
    created_at DateTime DEFAULT now(),
    updated_at DateTime DEFAULT now()
) ENGINE = ReplicatedMergeTree
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
-- 利用mergetree 本身的特性去重 deduplicating-inserts-on-retries

SELECT * FROM test_users;



-- 批量插入（使用 VALUES）
INSERT INTO test_users  (id, name, email, age)  VALUES
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
CREATE TABLE IF NOT EXISTS test_orders ON CLUSTER 'treasurycluster' (
    order_id UInt64,
    user_id UInt64,
    product_id UInt32,
    amount Decimal(10, 2),
    order_date DateTime DEFAULT now()
) ENGINE = ReplicatedMergeTree
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
CREATE TABLE IF NOT EXISTS test_products ON CLUSTER 'treasurycluster' (
    id UInt64,
    name String,
    tags Array(String),
    prices Array(Decimal(10, 2))
) ENGINE = ReplicatedMergeTree
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
    arrayJoin(tags) as tag_expanded
FROM test_products
ORDER BY id;

-- 数组聚合操作
SELECT
    name,
    max(prices) as max_price,
    min(prices) as min_price,
    avg(arrayJoin(prices)) as avg_price
FROM test_products
GROUP BY name
ORDER BY name;

-- ========================================
-- 12. 清理测试表（生产环境：使用 ON CLUSTER SYNC 确保集群范围删除）
-- ========================================
DROP TABLE IF EXISTS test_users ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS test_orders ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS test_products ON CLUSTER 'treasurycluster' SYNC;

-- ========================================
-- 13. 查看所有表
-- ========================================
SHOW TABLES;

-- ========================================
-- 14. 数据去重与幂等性测试
-- ========================================
-- 说明：解决上游写入一半程序崩溃时，如何保证 ClickHouse 数据不重复

-- ========================================
-- 场景 1：ReplacingMergeTree - 保留最新版本
-- ========================================
-- 适用场景：用户资料更新、配置信息、状态变更

DROP TABLE IF EXISTS dedup_user_profiles;

CREATE TABLE dedup_user_profiles (
    user_id UInt64,
    profile_id String,       -- 业务唯一ID
    name String,
    email String,
    phone String,
    updated_at DateTime,
    version UInt64,           -- 版本号（必需）
    inserted_at DateTime DEFAULT now()
) ENGINE = ReplacingMergeTree(version)  -- version 指定去重字段
PARTITION BY toYYYYMM(updated_at)
ORDER BY (user_id, profile_id)  -- 唯一键
SETTINGS index_granularity = 8192;

-- 插入初始数据（version 1）
INSERT INTO dedup_user_profiles VALUES
(1001, 'prof-001', '张三', 'zhangsan@example.com', '13800000001', '2024-01-01 10:00:00', 1, now()),
(1002, 'prof-002', '李四', 'lisi@example.com', '13800000002', '2024-01-01 10:00:00', 1, now()),
(1003, 'prof-003', '王五', 'wangwu@example.com', '13800000003', '2024-01-01 10:00:00', 1, now());

-- 模拟程序崩溃：重复插入相同的数据
-- 即使重复插入，也不会产生重复数据（相同的 profile_id + version）
INSERT INTO dedup_user_profiles VALUES
(1001, 'prof-001', '张三', 'zhangsan@example.com', '13800000001', '2024-01-01 10:00:00', 1, now()),
(1002, 'prof-002', '李四', 'lisi@example.com', '13800000002', '2024-01-01 10:00:00', 1, now()),
(1003, 'prof-003', '王五', 'wangwu@example.com', '13800000003', '2024-01-01 10:00:00', 1, now());

-- 查询原始数据（可能看到重复）
SELECT * FROM dedup_user_profiles
ORDER BY user_id, profile_id, version;

-- 查询去重后的数据（使用 argMax 手动去重 - 推荐）
SELECT
    user_id,
    profile_id,
    argMax(name, version) as name,
    argMax(email, version) as email,
    argMax(phone, version) as phone,
    argMax(updated_at, version) as updated_at,
    max(version) as latest_version
FROM dedup_user_profiles
GROUP BY user_id, profile_id
ORDER BY user_id;

-- 更新用户资料（version 2）
INSERT INTO dedup_user_profiles VALUES
(1001, 'prof-001', '张三丰', 'zhangsanfeng@example.com', '13800000011', '2024-01-01 11:00:00', 2, now()),
(1002, 'prof-002', '李四光', 'lisiguang@example.com', '13800000012', '2024-01-01 11:00:00', 2, now());

-- 再次查询去重后的数据（应该看到更新的资料）
SELECT
    user_id,
    profile_id,
    argMax(name, version) as name,
    argMax(email, version) as email,
    max(version) as latest_version
FROM dedup_user_profiles
GROUP BY user_id, profile_id
ORDER BY user_id;

-- 使用 FINAL 关键字查询（自动去重，但性能较差）
SELECT * FROM dedup_user_profiles FINAL
ORDER BY user_id;

-- 手动触发合并
OPTIMIZE TABLE dedup_user_profiles FINAL;

-- 再次查询（已合并，无重复）
SELECT * FROM dedup_user_profiles
ORDER BY user_id, version;

-- ========================================
-- 场景 2：CollapsingMergeTree - 增量更新
-- ========================================
-- 适用场景：库存管理、订单状态、增量计数器

DROP TABLE IF EXISTS dedup_inventory;

CREATE TABLE dedup_inventory (
    product_id UInt64,
    product_name String,
    quantity Int32,
    sign Int8,               -- 1 for insert, -1 for delete（必需）
    timestamp DateTime,
    inserted_at DateTime DEFAULT now()
) ENGINE = CollapsingMergeTree(sign)  -- sign 指定字段
PARTITION BY toYYYYMM(timestamp)
ORDER BY product_id
SETTINGS index_granularity = 8192;

-- 初始化库存（sign = 1）
INSERT INTO dedup_inventory VALUES
(101, '产品A', 100, 1, '2024-01-01 10:00:00', now()),
(102, '产品B', 50, 1, '2024-01-01 10:00:00', now()),
(103, '产品C', 75, 1, '2024-01-01 10:00:00', now());

-- 销售商品（sign = -1）
-- 如果程序崩溃，重试时再次执行，结果也是正确的
INSERT INTO dedup_inventory VALUES
(101, '产品A', 10, -1, '2024-01-01 11:00:00', now()),
(102, '产品B', 5, -1, '2024-01-01 11:00:00', now());

-- 进货（sign = 1）
INSERT INTO dedup_inventory VALUES
(101, '产品A', 20, 1, '2024-01-01 12:00:00', now()),
(103, '产品C', 10, 1, '2024-01-01 12:00:00', now());

-- 查询当前库存（使用 GROUP BY 抵消 sign）
SELECT
    product_id,
    argMax(product_name, timestamp) as product_name,
    sum(quantity * sign) as current_inventory,
    max(timestamp) as last_updated
FROM dedup_inventory
GROUP BY product_id
ORDER BY product_id;

-- 使用 FINAL 查询
SELECT * FROM dedup_inventory FINAL
ORDER BY product_id, timestamp;
