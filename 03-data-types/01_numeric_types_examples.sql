-- =====================================================
-- 01 - ClickHouse 数值类型示例
-- =====================================================
-- 集群: treasurycluster (2副本)
-- =====================================================

-- -----------------------------------------------------
-- 1. 数值类型概述
-- -----------------------------------------------------

-- 
-- ┌─────────────────────────────────────────────────────────────┐
-- │              ClickHouse 数值类型体系                          │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                              │
-- │  整数类型:                                                   │
-- │                                                              │
-- │  有符号:     Int8, Int16, Int32, Int64, Int128, Int256    │
-- │  无符号:    UInt8, UInt16, UInt32, UInt64, UInt128, UInt256│
-- │                                                              │
-- │  选择原则:                                                   │
-- │  - 使用最小范围类型 (UInt8 vs UInt64)                      │
-- │  - 节省存储空间                                              │
-- │  - 提高查询性能                                              │
-- │                                                              │
-- │  浮点类型:                                                   │
-- │                                                              │
-- │  - Float32: 单精度 (7位有效数字)                            │
-- │  - Float64: 双精度 (15位有效数字)                           │
-- │                                                              │
-- │  注意:                                                      │
-- │  - 浮点比较使用 round() 或 epsilon                        │
-- │                                                              │
-- │  精确类型:                                                   │
-- │                                                              │
-- │  - Decimal(P, S): 精确小数                                 │
-- │    P: 总位数, S: 小数位数                                   │
-- │    例如: Decimal(10, 2) = 99999999.99                      │
-- │                                                              │
-- │  使用场景:                                                  │
-- │  - 金额: Decimal(18, 4)                                    │
-- │  - 百分比: Decimal(5, 2)                                  │
-- │  - 数量: Decimal(10, 3)                                   │
-- │                                                              │
-- └─────────────────────────────────────────────────────────────┘

-- 创建数据库（如果存在则不创建）
CREATE DATABASE IF NOT EXISTS datatype_test ON CLUSTER 'treasurycluster';


DROP TABLE IF EXISTS datatype_test.numeric_types ON CLUSTER 'treasurycluster' SYNC;
CREATE TABLE IF NOT EXISTS datatype_test.numeric_types ON CLUSTER 'treasurycluster' (
    id UInt64,
    user_id UInt32,
    age UInt8,
    balance Int64,
    temperature Float32,
    price Float64
) ENGINE = MergeTree() ORDER BY id;

-- 插入数据
INSERT INTO datatype_test.numeric_types VALUES
    (1, 1001, 25, 1000, 36.5, 99.99),
    (2, 1002, 30, -500, 37.2, 199.99);

-- 查询数据
SELECT * FROM datatype_test.numeric_types;

-- ========================================
-- 基础使用
-- ========================================

-- 基础运算
SELECT
    10 + 5 as add,          -- 15
    10 - 5 as subtract,     -- 5
    10 * 5 as multiply,     -- 50
    10 / 3 as divide,       -- 3.333...
    10 % 3 as modulo;       -- 1

-- 取整
SELECT
    floor(3.7) as floor_down,   -- 3
    ceil(3.2) as ceil_up,      -- 4
    round(3.5) as round_nearest, -- 4
    trunc(3.9) as truncate;     -- 3

-- 绝对值
SELECT
    abs(-10) as abs_positive,   -- 10
    abs(10) as abs_original;    -- 10

-- ========================================
-- 基础使用
-- ========================================

-- 创建测试表
DROP TABLE IF EXISTS datatype_test.sales ON CLUSTER 'treasurycluster' SYNC;
CREATE TABLE IF NOT EXISTS datatype_test.sales ON CLUSTER 'treasurycluster' (
    id UInt64,
    product_id UInt32,
    quantity UInt16,
    price UInt32,
    total_price UInt64,
    rating Float32
) ENGINE = MergeTree() ORDER BY id;

-- 插入数据
INSERT INTO datatype_test.sales VALUES
    (1, 100, 5, 100, 500, 4.5),
    (2, 101, 3, 200, 600, 4.8),
    (3, 100, 2, 100, 200, 4.2),
    (4, 102, 1, 300, 300, 4.9);

-- 聚合函数
SELECT
    sum(quantity) as total_quantity,
    avg(price) as avg_price,
    min(rating) as min_rating,
    max(rating) as max_rating,
    count() as total_rows
FROM datatype_test.sales;

-- GROUP BY 聚合
SELECT
    product_id,
    sum(quantity) as total_quantity,
    sum(total_price) as total_sales,
    avg(rating) as avg_rating
FROM datatype_test.sales
GROUP BY product_id
ORDER BY product_id;

-- ========================================
-- 基础使用
-- ========================================

-- ❌ 不好：使用 UInt64 存储年龄（示例，已注释）
-- CREATE TABLE IF NOT EXISTS users_bad ON CLUSTER 'treasurycluster' (
--     id UInt64,
--     age UInt64      -- 浪费空间
-- ) ENGINE = ReplicatedMergeTree() ORDER BY id;

-- ✅ 好：使用 UInt8 存储年龄
CREATE TABLE IF NOT EXISTS datatype_test.users_good ON CLUSTER 'treasurycluster' (
    id UInt64,
    age UInt8       -- 0-255，足够
) ENGINE = MergeTree() ORDER BY id;

-- ========================================
-- 基础使用
-- ========================================

-- ✅ 推荐：主键使用 UInt64
CREATE TABLE IF NOT EXISTS datatype_test.events ON CLUSTER 'treasurycluster' (
    id UInt64,
    user_id UInt64,
    event_time DateTime
) ENGINE = MergeTree() ORDER BY (id, event_time);

-- ========================================
-- 基础使用
-- ========================================

-- 检查溢出: toInt8 范围是 -128~127, 200 会溢出抛错
-- 演示: 用 toInt16 容纳 200, 避免溢出
SELECT toInt16(200) AS no_overflow;  -- 200, 正常

-- 对比: toInt8(200) 会抛 OVERFLOW 错误 (取消注释可验证)
-- SELECT toInt8(200);  -- ERROR: 溢出
