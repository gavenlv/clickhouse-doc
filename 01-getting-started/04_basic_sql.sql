-- =====================================================
-- 04 - 基础 SQL 操作
-- =====================================================
-- 本文件介绍 ClickHouse 的基础 SQL 语法
-- 适合有 SQL 基础但需要了解 ClickHouse 特性的用户
-- =====================================================

CREATE DATABASE IF NOT EXISTS tutorial;

-- -----------------------------------------------------
-- 1. 数据类型概览
-- -----------------------------------------------------

-- ClickHouse 有丰富的数据类型，这是基础中的基础
CREATE TABLE IF NOT EXISTS tutorial.data_types_demo
(
    -- 整数类型
    tiny_int Int8,           -- -128 到 127
    small_int Int16,         -- -32768 到 32767
    normal_int Int32,        -- -21亿 到 21亿
    big_int Int64,           -- 更大范围
    
    -- 无符号整数（只存储正数，范围更大）
    pos_tiny UInt8,          -- 0 到 255
    pos_small UInt16,        -- 0 到 65535
    pos_normal UInt32,       -- 0 到 42亿
    pos_big UInt64,          -- 0 到 非常大
    
    -- 浮点数
    float_val Float32,       -- 单精度
    double_val Float64,      -- 双精度（推荐）
    
    -- 定点数（精确小数，适合金额）
    decimal_val Decimal(10, 2),  -- 共10位，小数点后2位
    
    -- 字符串
    str String,              -- 任意长度字符串
    fixed_str FixedString(10), -- 固定长度10字节
    
    -- 日期时间
    date_val Date,           -- 日期，如 '2024-01-15'
    datetime_val DateTime,   -- 日期时间，精确到秒
    datetime64_val DateTime64(3), -- 毫秒精度
    
    -- 枚举类型
    enum8_val Enum8('hello' = 1, 'world' = 2),
    
    -- 低基数字符串（适合重复值）
    lowcard LowCardinality(String),
    
    -- 数组
    arr_int Array(UInt32),
    arr_str Array(String),
    
    -- 可为空
    nullable_str Nullable(String),
    
    -- UUID
    uuid UUID,
    
    -- IP 地址
    ipv4 IPv4,
    ipv6 IPv6
)
ENGINE = MergeTree()
ORDER BY pos_normal;

-- 插入示例数据
INSERT INTO tutorial.data_types_demo VALUES
(
    100, 1000, 100000, 10000000000,
    200, 2000, 200000, 20000000000,
    3.14, 2.71828,
    1234.56,
    'Hello, ClickHouse!', 'fixed     ',
    '2024-01-15', '2024-01-15 10:30:00', '2024-01-15 10:30:00.123',
    'hello',
    'category_a',
    [1, 2, 3], ['a', 'b', 'c'],
    'I can be null',
    generateUUIDv4(),
    '192.168.1.1', '2001:db8::1'
);

-- 查看数据
SELECT * FROM tutorial.data_types_demo;

-- -----------------------------------------------------
-- 2. 创建表的各种方式
-- -----------------------------------------------------

-- 方式 1: 基础创建
CREATE TABLE IF NOT EXISTS tutorial.basic_table
(
    id UInt32,
    name String,
    created_at DateTime DEFAULT now()
)
ENGINE = MergeTree()
ORDER BY id;

-- 方式 2: 带注释和默认值
CREATE TABLE IF NOT EXISTS tutorial.with_defaults
(
    id UInt32 COMMENT '主键ID',
    name String COMMENT '用户名',
    status UInt8 DEFAULT 1 COMMENT '状态: 1=活跃, 0=禁用',
    score Float64 DEFAULT 0.0 COMMENT '分数',
    tags Array(String) DEFAULT [] COMMENT '标签',
    created_at DateTime DEFAULT now() COMMENT '创建时间',
    updated_at DateTime DEFAULT now() COMMENT '更新时间'
)
ENGINE = MergeTree()
ORDER BY id
COMMENT '带默认值的表示例';

-- 方式 3: 从其他表复制结构
CREATE TABLE IF NOT EXISTS tutorial.copy_structure AS tutorial.basic_table;

-- 方式 4: 使用 LIKE 复制结构（不复制数据）
CREATE TABLE IF NOT EXISTS tutorial.like_table
(
    id UInt32,
    extra_field String
)
ENGINE = MergeTree()
ORDER BY id;

-- -----------------------------------------------------
-- 3. INSERT 操作详解
-- -----------------------------------------------------

-- 方式 1: VALUES 插入（适合少量数据）
INSERT INTO tutorial.basic_table VALUES (1, 'Alice', '2024-01-15 10:00:00');
INSERT INTO tutorial.basic_table VALUES (2, 'Bob', '2024-01-15 11:00:00'), (3, 'Charlie', '2024-01-15 12:00:00');

-- 方式 2: 从 SELECT 插入（适合数据转换）
INSERT INTO tutorial.copy_structure
SELECT id, name, created_at FROM tutorial.basic_table WHERE id < 3;

-- 方式 3: 从表插入
INSERT INTO tutorial.with_defaults (id, name)
SELECT number, 'User_' || toString(number)
FROM numbers(100);

-- 方式 4: 使用 FORMAT（适合批量导入）
-- INSERT INTO table FORMAT CSV
-- 1,"Alice","2024-01-15 10:00:00"
-- 2,"Bob","2024-01-15 11:00:00"

-- -----------------------------------------------------
-- 4. SELECT 查询基础
-- -----------------------------------------------------

-- 基础查询
SELECT * FROM tutorial.basic_table;

-- 选择特定列
SELECT id, name FROM tutorial.basic_table;

-- 带条件查询
SELECT * FROM tutorial.basic_table WHERE id > 1;

-- 排序
SELECT * FROM tutorial.basic_table ORDER BY created_at DESC;

-- 限制结果数量
SELECT * FROM tutorial.basic_table LIMIT 2;

-- 分页
SELECT * FROM tutorial.basic_table ORDER BY id LIMIT 2 OFFSET 1;

-- -----------------------------------------------------
-- 5. 聚合查询
-- -----------------------------------------------------

-- 准备测试数据
INSERT INTO tutorial.with_defaults (id, name, status, score)
SELECT 
    number + 100,
    'User_' || toString(number % 10),
    number % 3,
    rand() % 1000 / 10.0
FROM numbers(1000);

-- 基础聚合函数
SELECT 
    count() AS total_count,
    count(DISTINCT name) AS unique_names,
    sum(score) AS total_score,
    avg(score) AS avg_score,
    min(score) AS min_score,
    max(score) AS max_score,
    stddevPop(score) AS std_dev
FROM tutorial.with_defaults;

-- 分组聚合
SELECT 
    status,
    count() AS user_count,
    round(avg(score), 2) AS avg_score,
    round(sum(score), 2) AS total_score
FROM tutorial.with_defaults
GROUP BY status
ORDER BY status;

-- 多字段分组
SELECT 
    status,
    name,
    count() AS count,
    round(avg(score), 2) AS avg_score
FROM tutorial.with_defaults
GROUP BY status, name
ORDER BY status, count DESC
LIMIT 20;

-- -----------------------------------------------------
-- 6. 条件查询和过滤
-- -----------------------------------------------------

-- WHERE 子句
SELECT * FROM tutorial.with_defaults WHERE status = 1 AND score > 50;

-- IN 操作符
SELECT * FROM tutorial.with_defaults WHERE status IN (0, 1);

-- LIKE 模糊匹配
SELECT * FROM tutorial.with_defaults WHERE name LIKE 'User_1%';

-- BETWEEN 范围
SELECT * FROM tutorial.with_defaults WHERE score BETWEEN 30 AND 70;

-- NULL 检查
SELECT * FROM tutorial.with_defaults WHERE tags IS NULL OR empty(tags);

-- 数组包含
SELECT * FROM tutorial.with_defaults WHERE has(tags, 'vip');

-- -----------------------------------------------------
-- 7. JOIN 操作（简化版）
-- -----------------------------------------------------
-- 注意：ClickHouse 的 JOIN 与传统数据库有所不同

-- 创建两个关联表
CREATE TABLE IF NOT EXISTS tutorial.users
(
    user_id UInt32,
    user_name String,
    age UInt8
)
ENGINE = MergeTree()
ORDER BY user_id;

CREATE TABLE IF NOT EXISTS tutorial.orders
(
    order_id UInt32,
    user_id UInt32,
    amount Float64,
    order_date Date
)
ENGINE = MergeTree()
ORDER BY order_id;

-- 插入数据
INSERT INTO tutorial.users VALUES (1, 'Alice', 25), (2, 'Bob', 30), (3, 'Charlie', 35);
INSERT INTO tutorial.orders VALUES (101, 1, 100.0, '2024-01-15'), (102, 1, 200.0, '2024-01-16'), (103, 2, 150.0, '2024-01-15');

-- JOIN 查询
SELECT 
    u.user_id,
    u.user_name,
    o.order_id,
    o.amount
FROM tutorial.users u
JOIN tutorial.orders o ON u.user_id = o.user_id;

-- LEFT JOIN
SELECT 
    u.user_id,
    u.user_name,
    count(o.order_id) AS order_count,
    sum(o.amount) AS total_amount
FROM tutorial.users u
LEFT JOIN tutorial.orders o ON u.user_id = o.user_id
GROUP BY u.user_id, u.user_name;

-- -----------------------------------------------------
-- 8. 数组和嵌套结构操作
-- -----------------------------------------------------

-- 数组函数
SELECT 
    [1, 2, 3, 4, 5] AS arr,
    arrayJoin(arr) AS element,  -- 展开数组
    length(arr) AS arr_length,
    arraySum(arr) AS arr_sum,
    arrayAvg(arr) AS arr_avg,
    arrayMin(arr) AS arr_min,
    arrayMax(arr) AS arr_max;

-- 实际应用：展开标签
SELECT 
    id,
    name,
    arrayJoin(tags) AS tag
FROM tutorial.with_defaults
WHERE length(tags) > 0
LIMIT 10;

-- -----------------------------------------------------
-- 9. 类型转换
-- -----------------------------------------------------

-- toInt32, toFloat64, toString 等
SELECT 
    toInt32(3.14) AS int_val,
    toFloat64('3.14') AS float_val,
    toString(123) AS str_val,
    toDate('2024-01-15') AS date_val,
    toDateTime('2024-01-15 10:00:00') AS datetime_val;

-- 格式化
SELECT 
    formatDateTime(now(), '%Y-%m-%d') AS today,
    formatReadableSize(1234567890) AS readable_size,
    toYYYYMMDD(now()) AS date_int;

-- -----------------------------------------------------
-- 10. 窗口函数（分析函数）
-- -----------------------------------------------------

-- 准备数据
CREATE TABLE IF NOT EXISTS tutorial.sales
(
    product String,
    month Date,
    revenue Float64
)
ENGINE = MergeTree()
ORDER BY (product, month);

INSERT INTO tutorial.sales VALUES
('Product A', '2024-01-01', 1000),
('Product A', '2024-02-01', 1200),
('Product A', '2024-03-01', 900),
('Product B', '2024-01-01', 800),
('Product B', '2024-02-01', 1100),
('Product B', '2024-03-01', 1300);

-- 窗口函数：累计和
SELECT 
    product,
    month,
    revenue,
    sum(revenue) OVER (PARTITION BY product ORDER BY month) AS cumulative_revenue,
    avg(revenue) OVER (PARTITION BY product ORDER BY month ROWS BETWEEN 2 PRECEDING AND CURRENT ROW) AS moving_avg
FROM tutorial.sales
ORDER BY product, month;

-- 排名函数
SELECT 
    product,
    month,
    revenue,
    rank() OVER (ORDER BY revenue DESC) AS revenue_rank,
    row_number() OVER (ORDER BY revenue DESC) AS row_num
FROM tutorial.sales;

-- -----------------------------------------------------
-- 11. 学习检查点
-- -----------------------------------------------------

-- 问题 1: UInt8 和 Int8 的范围分别是什么？
-- 答案：UInt8: 0-255, Int8: -128 到 127

-- 问题 2: 如何插入当前时间？
-- 答案：使用 now() 函数，或 DEFAULT now() 定义

-- 问题 3: 如何计算平均值并保留 2 位小数？
SELECT round(avg(score), 2) FROM tutorial.with_defaults;

-- 问题 4: 如何展开数组字段？
-- 答案：使用 arrayJoin() 函数

-- -----------------------------------------------------
-- 12. 清理（可选）
-- -----------------------------------------------------
-- DROP TABLE IF EXISTS tutorial.data_types_demo;
-- DROP TABLE IF EXISTS tutorial.basic_table;
-- DROP TABLE IF EXISTS tutorial.with_defaults;
-- DROP TABLE IF EXISTS tutorial.copy_structure;
-- DROP TABLE IF EXISTS tutorial.like_table;
-- DROP TABLE IF EXISTS tutorial.users;
-- DROP TABLE IF EXISTS tutorial.orders;
-- DROP TABLE IF EXISTS tutorial.sales;

-- =====================================================
-- 本章小结
-- =====================================================
-- 
-- 基础 SQL 要点：
-- 1. 数据类型：选择合适的类型很重要
-- 2. 创建表：ENGINE = MergeTree() ORDER BY (key)
-- 3. INSERT：VALUES, SELECT, FORMAT 三种方式
-- 4. SELECT：支持标准 SQL 语法
-- 5. 聚合：丰富的聚合函数
-- 6. JOIN：支持但需谨慎使用
-- 7. 数组：arrayJoin 展开数组
-- 8. 窗口函数：OVER (PARTITION BY ... ORDER BY ...)
--
-- 注意事项：
-- - ClickHouse 不支持 UPDATE/DELETE（有替代方案）
-- - JOIN 性能不如传统数据库，建议预聚合
-- - 利用列式存储优势，只查询需要的列
--
-- 下一步：05_cluster_concepts.sql - 集群基础概念
-- =====================================================
