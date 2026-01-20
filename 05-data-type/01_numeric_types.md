# 数值类型

ClickHouse 支持多种数值类型，包括整数和浮点数。

## 整数类型

### 无符号整数 (UInt)

| 类型 | 大小 | 范围 |
|------|------|------|
| **UInt8** | 1 字节 | `0` ~ `255` |
| **UInt16** | 2 字节 | `0` ~ `65,535` |
| **UInt32** | 4 字节 | `0` ~ `4,294,967,295` |
| **UInt64** | 8 字节 | `0` ~ `18,446,744,073,709,551,615` |

### 有符号整数 (Int)

| 类型 | 大小 | 范围 |
|------|------|------|
| **Int8** | 1 字节 | `-128` ~ `127` |
| **Int16** | 2 字节 | `-32,768` ~ `32,767` |
| **Int32** | 4 字节 | `-2,147,483,648` ~ `2,147,483,647` |
| **Int64** | 8 字节 | `-9,223,372,036,854,775,808` ~ `9,223,372,036,854,775,807` |

## 浮点数类型

| 类型 | 大小 | 精度 |
|------|------|------|
| **Float32** | 4 字节 | 单精度（约 7 位小数） |
| **Float64** | 8 字节 | 双精度（约 16 位小数） |

## 使用示例

### 基础使用

```sql
-- 创建表
CREATE TABLE example.numeric_types (
    id UInt64,
    user_id UInt32,
    age UInt8,
    balance Int64,
    temperature Float32,
    price Float64
) ENGINE = MergeTree ORDER BY id;

-- 插入数据
INSERT INTO example.numeric_types VALUES
    (1, 1001, 25, 1000, 36.5, 99.99),
    (2, 1002, 30, -500, 37.2, 199.99);

-- 查询数据
SELECT * FROM example.numeric_types;
```

### 数值计算

```sql
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
```

### 聚合函数

```sql
-- 创建测试表
CREATE TABLE example.sales (
    id UInt64,
    product_id UInt32,
    quantity UInt16,
    price UInt32,
    total_price UInt64,
    rating Float32
) ENGINE = MergeTree ORDER BY id;

-- 插入数据
INSERT INTO example.sales VALUES
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
FROM example.sales;

-- GROUP BY 聚合
SELECT
    product_id,
    sum(quantity) as total_quantity,
    sum(total_price) as total_sales,
    avg(rating) as avg_rating
FROM example.sales
GROUP BY product_id
ORDER BY product_id;
```

## 最佳实践

### 1. 选择合适的大小

```sql
-- ❌ 不好：使用 UInt64 存储年龄
CREATE TABLE users_bad (
    id UInt64,
    age UInt64      -- 浪费空间
) ENGINE = MergeTree ORDER BY id;

-- ✅ 好：使用 UInt8 存储年龄
CREATE TABLE users_good (
    id UInt64,
    age UInt8       -- 0-255，足够
) ENGINE = MergeTree ORDER BY id;
```

### 2. 主键使用 UInt64

```sql
-- ✅ 推荐：主键使用 UInt64
CREATE TABLE events (
    id UInt64,
    user_id UInt64,
    event_time DateTime
) ENGINE = MergeTree ORDER BY (id, event_time);
```

### 3. 数值溢出处理

```sql
-- 检查溢出
SELECT
    cast(toInt8(200) as UInt8);  -- 会溢出，产生错误

-- 使用 toUInt64 避免溢出
SELECT
    cast(200 as UInt64);  -- 正常
```

---

**最后更新**: 2026-01-19
