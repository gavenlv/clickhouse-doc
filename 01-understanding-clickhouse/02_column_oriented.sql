-- =====================================================
-- 02 - 列式存储原理
-- =====================================================
-- 本文件帮助你深入理解列式存储的优势和原理
-- 通过对比展示为什么 ClickHouse 这么快
-- =====================================================

-- -----------------------------------------------------
-- 1. 创建对比实验环境
-- -----------------------------------------------------
-- 我们创建两张结构相同的表，但使用不同的存储方式
-- ClickHouse 会自动使用列式存储

CREATE DATABASE IF NOT EXISTS tutorial;

-- 创建一个包含多种数据类型的表
CREATE TABLE IF NOT EXISTS tutorial.column_store_demo
(
    id UInt64,
    user_id UInt32,
    age UInt8,
    gender LowCardinality(String),
    city LowCardinality(String),
    salary Float64,
    department LowCardinality(String),
    join_date Date,
    last_login DateTime,
    tags Array(String),
    profile String
)
ENGINE = MergeTree()
ORDER BY (department, join_date, id)
PARTITION BY toYYYYMM(join_date);

-- -----------------------------------------------------
-- 2. 插入测试数据
-- -----------------------------------------------------
-- 插入 500 万行员工数据

INSERT INTO tutorial.column_store_demo
SELECT 
    number AS id,
    rand() % 100000 AS user_id,
    18 + (rand() % 50) AS age,
    ['Male', 'Female'][rand() % 2 + 1] AS gender,
    ['Beijing', 'Shanghai', 'Guangzhou', 'Shenzhen', 'Hangzhou'][rand() % 5 + 1] AS city,
    5000 + (rand() % 50000) AS salary,
    ['Engineering', 'Sales', 'Marketing', 'HR', 'Finance'][rand() % 5 + 1] AS department,
    toDate('2020-01-01') + (rand() % 1460) AS join_date,
    now() - (rand() % 86400 * 30) AS last_login,
    [['developer', 'backend'], ['sales', 'enterprise'], ['marketing', 'digital']][rand() % 3 + 1] AS tags,
    repeat('Profile information for employee ', 10) AS profile
FROM numbers(5000000);

-- -----------------------------------------------------
-- 3. 列式存储的空间效率展示
-- -----------------------------------------------------

-- 查看每个列的压缩情况
SELECT 
    column,
    type,
    formatReadableSize(sum(column_data_compressed_bytes)) AS compressed_size,
    formatReadableSize(sum(column_data_uncompressed_bytes)) AS uncompressed_size,
    round(sum(column_data_uncompressed_bytes) / sum(column_data_compressed_bytes), 2) AS compression_ratio,
    formatReadableSize(sum(column_data_uncompressed_bytes) / count(DISTINCT part_name)) AS avg_column_size_per_part
FROM system.parts_columns
WHERE database = 'tutorial' AND table = 'column_store_demo'
GROUP BY column, type
ORDER BY sum(column_data_compressed_bytes) DESC;

-- -----------------------------------------------------
-- 4. 查询性能对比实验
-- -----------------------------------------------------

-- 实验 1: 只查询一个列（高效）
-- 列式存储只需读取这一个列的数据
SELECT 
    department, 
    count() AS employee_count,
    avg(salary) AS avg_salary
FROM tutorial.column_store_demo
GROUP BY department
ORDER BY employee_count DESC;

-- 实验 2: 查询多个列（仍然高效）
SELECT 
    city,
    gender,
    count() AS count,
    avg(age) AS avg_age,
    avg(salary) AS avg_salary
FROM tutorial.column_store_demo
WHERE join_date >= '2022-01-01'
GROUP BY city, gender
ORDER BY count DESC;

-- 实验 3: 查询大字段（profile 是长字符串）
-- 注意：这个查询会比较慢，因为需要读取大量数据
-- SELECT profile FROM tutorial.column_store_demo LIMIT 10;

-- -----------------------------------------------------
-- 5. 向量化执行展示
-- -----------------------------------------------------
-- ClickHouse 使用向量化执行，一次处理一批数据

-- 查看查询执行计划
EXPLAIN actions=1
SELECT department, avg(salary)
FROM tutorial.column_store_demo
GROUP BY department;

-- 查看更详细的执行计划
EXPLAIN PIPELINE
SELECT department, avg(salary)
FROM tutorial.column_store_demo
GROUP BY department;

-- -----------------------------------------------------
-- 6. 数据局部性优势
-- -----------------------------------------------------
-- 相同类型的数据存储在一起，CPU 缓存友好

-- 测试数值计算性能
SELECT 
    count(),
    sum(salary),
    avg(salary),
    min(salary),
    max(salary),
    stddevPop(salary)
FROM tutorial.column_store_demo
WHERE age BETWEEN 25 AND 45;

-- -----------------------------------------------------
-- 7. 编码和压缩效果
-- -----------------------------------------------------

-- LowCardinality 类型的高效性展示
-- LowCardinality 适合重复值较多的列（如性别、城市、部门）

-- 对比：使用普通 String vs LowCardinality
CREATE TABLE IF NOT EXISTS tutorial.comparison_normal
(
    id UInt64,
    category String  -- 普通字符串
)
ENGINE = MergeTree()
ORDER BY id;

CREATE TABLE IF NOT EXISTS tutorial.comparison_lowcard
(
    id UInt64,
    category LowCardinality(String)  -- 低基数字符串
)
ENGINE = MergeTree()
ORDER BY id;

-- 插入相同的数据
INSERT INTO tutorial.comparison_normal
SELECT number, ['A', 'B', 'C', 'D', 'E'][rand() % 5 + 1]
FROM numbers(1000000);

INSERT INTO tutorial.comparison_lowcard
SELECT number, ['A', 'B', 'C', 'D', 'E'][rand() % 5 + 1]
FROM numbers(1000000);

-- 对比存储大小
SELECT 
    'Normal String' AS type,
    formatReadableSize(sum(data_compressed_bytes)) AS compressed,
    formatReadableSize(sum(data_uncompressed_bytes)) AS uncompressed
FROM system.parts
WHERE table = 'comparison_normal'
UNION ALL
SELECT 
    'LowCardinality' AS type,
    formatReadableSize(sum(data_compressed_bytes)) AS compressed,
    formatReadableSize(sum(data_uncompressed_bytes)) AS uncompressed
FROM system.parts
WHERE table = 'comparison_lowcard';

-- -----------------------------------------------------
-- 8. 分区裁剪效果
-- -----------------------------------------------------
-- 查询特定分区时，只读取相关分区

-- 这个查询只会读取 2023 年的分区
SELECT 
    toYYYYMM(join_date) AS month,
    count() AS new_hires
FROM tutorial.column_store_demo
WHERE join_date >= '2023-01-01' AND join_date < '2024-01-01'
GROUP BY month
ORDER BY month;

-- 查看查询使用了哪些分区
EXPLAIN indexes=1
SELECT count()
FROM tutorial.column_store_demo
WHERE join_date >= '2023-06-01' AND join_date < '2023-07-01';

-- -----------------------------------------------------
-- 9. 行式存储 vs 列式存储对比
-- -----------------------------------------------------
-- 创建对比表帮助理解
CREATE TABLE IF NOT EXISTS tutorial.storage_comparison
(
    aspect String,
    row_oriented String,
    column_oriented String,
    clickhouse_choice String
)
ENGINE = MergeTree()
ORDER BY aspect;

INSERT INTO tutorial.storage_comparison VALUES
('存储布局', '按行存储所有列', '按列存储所有行', '列式'),
('读取单行', '快（连续存储）', '慢（多列查找）', '列式'),
('读取单列', '慢（跳过其他列）', '快（连续读取）', '列式'),
('数据压缩', '一般', '优秀（同类型数据）', '列式'),
('聚合查询', '慢', '快', '列式'),
('OLTP 事务', '适合', '不适合', '行式'),
('OLAP 分析', '不适合', '适合', '列式'),
('向量化执行', '难', '易', '列式'),
('CPU 缓存', '缓存未命中多', '缓存友好', '列式');

SELECT * FROM tutorial.storage_comparison;

-- -----------------------------------------------------
-- 10. 实际应用建议
-- -----------------------------------------------------

-- 数据类型选择建议
CREATE TABLE IF NOT EXISTS tutorial.datatype_best_practices
(
    scenario String,
    recommended_type String,
    reason String
)
ENGINE = MergeTree()
ORDER BY scenario;

INSERT INTO tutorial.datatype_best_practices VALUES
('状态码、类别', 'LowCardinality(String)', '枚举值，高压缩率'),
('时间戳', 'DateTime 或 DateTime64', '内置时间函数支持'),
('布尔值', 'UInt8 (0/1)', '不要用 Bool 类型'),
('IP 地址', 'IPv4 或 IPv6', '专用类型，高效存储'),
('小整数', 'Int8/Int16/UInt8/UInt16', '选择合适的范围'),
('大文本', 'String', '避免过长的字段'),
('小数金额', 'Decimal(P, S)', '精确计算'),
('数组标签', 'Array(LowCardinality(String))', '标签系统');

SELECT * FROM tutorial.datatype_best_practices;

-- -----------------------------------------------------
-- 11. 学习检查点
-- -----------------------------------------------------

-- 问题 1: 列式存储为什么压缩率更高？
-- 答案：同类型数据在一起，重复值多，压缩效果好

-- 问题 2: 为什么聚合查询在列式存储上更快？
-- 答案：只需读取需要的列，不需要跳过不相关的数据

-- 问题 3: LowCardinality 适合什么场景？
-- 答案：重复值较多的列，如状态、类别、枚举值

-- -----------------------------------------------------
-- 12. 清理（可选）
-- -----------------------------------------------------
-- DROP TABLE IF EXISTS tutorial.column_store_demo;
-- DROP TABLE IF EXISTS tutorial.comparison_normal;
-- DROP TABLE IF EXISTS tutorial.comparison_lowcard;
-- DROP TABLE IF EXISTS tutorial.storage_comparison;
-- DROP TABLE IF EXISTS tutorial.datatype_best_practices;

-- =====================================================
-- 本章小结
-- =====================================================
-- 
-- 列式存储的核心优势：
-- 1. 查询只读需要的列，IO 大幅减少
-- 2. 同类型数据在一起，压缩率极高
-- 3. CPU 缓存友好，向量化执行高效
-- 4. 适合 OLAP 聚合分析场景
--
-- 最佳实践：
-- 1. 使用 LowCardinality 存储枚举值
-- 2. 选择合适的数值类型范围
-- 3. 避免 SELECT *，只查需要的列
-- 4. 利用分区裁剪减少数据扫描
--
-- 下一步：03_mergeTree_engine.sql - 理解 MergeTree 引擎
-- =====================================================
