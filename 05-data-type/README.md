# ClickHouse 数据类型

本目录包含 ClickHouse 数据类型的详细说明和使用示例。

## 目录结构

```
05-data-type/
├── README.md                      # 数据类型总览
├── 01_numeric_types.md           # 数值类型
├── 02_string_types.md            # 字符串类型
├── 03_date_time_types.md         # 日期时间类型
├── 04_array_types.md             # 数组类型
├── 05_tuple_types.md             # 元组类型
├── 06_map_types.md               # Map 类型
├── 07_nested_types.md            # Nested 类型
├── 08_enum_types.md              # Enum 类型
├── 09_nullable_types.md           # Nullable 类型
├── 10_special_types.md           # 特殊类型（UUID、JSON、IP 等）
└── 11_type_conversion.md         # 类型转换和兼容性
```

## 数据类型分类

### 基础类型

| 类型 | 描述 | 示例 | 大小 |
|------|------|------|------|
| **UInt8** | 无符号 8 位整数 | `0` ~ `255` | 1 字节 |
| **UInt16** | 无符号 16 位整数 | `0` ~ `65535` | 2 字节 |
| **UInt32** | 无符号 32 位整数 | `0` ~ `4294967295` | 4 字节 |
| **UInt64** | 无符号 64 位整数 | `0` ~ `18446744073709551615` | 8 字节 |
| **Int8** | 有符号 8 位整数 | `-128` ~ `127` | 1 字节 |
| **Int16** | 有符号 16 位整数 | `-32768` ~ `32767` | 2 字节 |
| **Int32** | 有符号 32 位整数 | `-2147483648` ~ `2147483647` | 4 字节 |
| **Int64** | 有符号 64 位整数 | `-9223372036854775808` ~ `9223372036854775807` | 8 字节 |
| **Float32** | 单精度浮点数 | `-3.4e38` ~ `3.4e38` | 4 字节 |
| **Float64** | 双精度浮点数 | `-1.7e308` ~ `1.7e308` | 8 字节 |

### 字符串类型

| 类型 | 描述 | 适用场景 |
|------|------|----------|
| **String** | 任意长度的字符串 | 存储文本、日志、JSON 等 |
| **FixedString(N)** | 固定长度字符串 | 存储定长数据（如 MD5、UUID） |
| **LowCardinality(String)** | 字典编码字符串 | 低基数字符串（如国家、状态） |

### 日期时间类型

| 类型 | 描述 | 范围 |
|------|------|------|
| **Date** | 日期（天） | `1970-01-01` ~ `2149-06-06` |
| **DateTime** | 日期时间（秒） | `1970-01-01 00:00:00` ~ `2106-02-07 06:28:15` |
| **DateTime64(N)** | 日期时间（亚秒） | 支持微秒、纳秒精度 |

### 复合类型

| 类型 | 描述 | 示例 |
|------|------|------|
| **Array(T)** | 数组 | `[1, 2, 3]` |
| **Tuple(T1, T2, ...)** | 元组 | `(1, 'hello', 3.14)` |
| **Map(Key, Value)** | 键值对映射 | `{'a': 1, 'b': 2}` |
| **Nested(Name1 Type1, ...)** | 嵌套结构 | `[['a', 1], ['b', 2]]` |
| **Enum8** | 枚举（8 位） | `'hello' = 1` |
| **Enum16** | 枚举（16 位） | `'hello' = 1` |

### 特殊类型

| 类型 | 描述 | 示例 |
|------|------|------|
| **Nullable(T)** | 可空类型 | `NULL` 或 `T` |
| **UUID** | 通用唯一标识符 | `'550e8400-e29b-41d4-a716-446655440000'` |
| **IPv4** | IPv4 地址 | `127.0.0.1` |
| **IPv6** | IPv6 地址 | `::1` |
| **JSON** | JSON 对象 | `{"key": "value"}` |

## 快速参考

### 数值类型选择

```sql
-- 用户 ID、订单号（无符号大整数）
CREATE TABLE users (
    id UInt64,
    user_id UInt64,
    order_id UInt64
) ENGINE = MergeTree ORDER BY id;

-- 年龄、数量（小整数）
CREATE TABLE products (
    id UInt64,
    age UInt8,        -- 0-255
    quantity UInt16,   -- 0-65535
    price UInt32       -- 0-4294967295（分为单位）
) ENGINE = MergeTree ORDER BY id;

-- 坐标、评分（浮点数）
CREATE TABLE locations (
    id UInt64,
    latitude Float32,
    longitude Float32,
    rating Float32
) ENGINE = MergeTree ORDER BY id;
```

### 字符串类型选择

```sql
-- 普通字符串
CREATE TABLE events (
    id UInt64,
    message String
) ENGINE = MergeTree ORDER BY id;

-- 定长字符串（MD5、UUID）
CREATE TABLE files (
    id UInt64,
    file_hash FixedString(32)  -- MD5 32 字符
) ENGINE = MergeTree ORDER BY id;

-- 低基数字符串（优化）
CREATE TABLE users (
    id UInt64,
    country LowCardinality(String),  -- 只有 200 个国家
    status LowCardinality(String)     -- 只有少量状态
) ENGINE = MergeTree ORDER BY id;
```

### 日期时间类型选择

```sql
-- 日期（天）
CREATE TABLE events (
    id UInt64,
    event_date Date
) ENGINE = MergeTree ORDER BY event_date;

-- 日期时间（秒）
CREATE TABLE events (
    id UInt64,
    event_time DateTime
) ENGINE = MergeTree ORDER BY event_time;

-- 日期时间（毫秒）
CREATE TABLE events (
    id UInt64,
    event_time DateTime64(3)  -- 毫秒精度
) ENGINE = MergeTree ORDER BY event_time;
```

### 复合类型示例

```sql
-- 数组
CREATE TABLE users (
    id UInt64,
    tags Array(String)
) ENGINE = MergeTree ORDER BY id;

-- 元组
CREATE TABLE locations (
    id UInt64,
    coordinates Tuple(Float32, Float32)
) ENGINE = MergeTree ORDER BY id;

-- Map
CREATE TABLE settings (
    id UInt64,
    config Map(String, String)
) ENGINE = MergeTree ORDER BY id;

-- Nested
CREATE TABLE orders (
    id UInt64,
    items Nested(
        product_id UInt64,
        quantity UInt32,
        price UInt32
    )
) ENGINE = MergeTree ORDER BY id;
```

## 学习路径

### 1. 基础类型（推荐先学）
- [01_numeric_types.md](./01_numeric_types.md) - 数值类型
- [02_string_types.md](./02_string_types.md) - 字符串类型
- [03_date_time_types.md](./03_date_time_types.md) - 日期时间类型

### 2. 复合类型
- [04_array_types.md](./04_array_types.md) - 数组类型
- [05_tuple_types.md](./05_tuple_types.md) - 元组类型
- [06_map_types.md](./06_map_types.md) - Map 类型
- [07_nested_types.md](./07_nested_types.md) - Nested 类型

### 3. 高级类型
- [08_enum_types.md](./08_enum_types.md) - Enum 类型
- [09_nullable_types.md](./09_nullable_types.md) - Nullable 类型
- [10_special_types.md](./10_special_types.md) - 特殊类型

### 4. 类型转换
- [11_type_conversion.md](./11_type_conversion.md) - 类型转换和兼容性

## 类型选择指南

### 何时使用整数类型？

| 场景 | 推荐类型 | 说明 |
|------|---------|------|
| 主键、ID | `UInt64` | 避免溢出，支持大数据量 |
| 年龄、数量 | `UInt8/UInt16` | 节省存储，范围有限 |
| 计数器 | `UInt32/UInt64` | 不允许负数 |
| 温度、评分 | `Float32/Float64` | 需要小数 |

### 何时使用 LowCardinality？

| 场景 | 使用 | 不使用 |
|------|------|--------|
| 国家代码 | ✅ | ❌ |
| 用户 ID | ❌ | ✅ |
| 状态码 | ✅ | ❌ |
| UUID | ❌ | ✅ |
| 任意文本 | ❌ | ✅ |

### 何时使用 Nullable？

| 场景 | 推荐使用 | 说明 |
|------|---------|------|
| 可选字段 | ✅ | 允许 NULL 值 |
| 必填字段 | ❌ | 使用默认值 |
| 外键 | ❌ | 使用 0 或空字符串 |
| 主键 | ❌ | 禁止使用 |

## 最佳实践

### 1. 选择最小的合适类型

```sql
-- ❌ 不好
CREATE TABLE users (
    id UInt64,
    age UInt64,      -- 浪费空间
    status UInt64    -- 浪费空间
) ENGINE = MergeTree ORDER BY id;

-- ✅ 好
CREATE TABLE users (
    id UInt64,
    age UInt8,        -- 0-255
    status UInt8       -- 0-255
) ENGINE = MergeTree ORDER BY id;
```

### 2. 使用 LowCardinality 优化

```sql
-- ❌ 不好
CREATE TABLE users (
    id UInt64,
    country String,     -- 重复字符串
    status String      -- 重复字符串
) ENGINE = MergeTree ORDER BY id;

-- ✅ 好
CREATE TABLE users (
    id UInt64,
    country LowCardinality(String),  -- 字典编码
    status LowCardinality(String)    -- 字典编码
) ENGINE = MergeTree ORDER BY id;
```

### 3. 避免过度使用 Nullable

```sql
-- ❌ 不好
CREATE TABLE users (
    id UInt64,
    name Nullable(String),
    age Nullable(UInt8),
    status Nullable(UInt8)
) ENGINE = MergeTree ORDER BY id;

-- ✅ 好
CREATE TABLE users (
    id UInt64,
    name String DEFAULT '',
    age UInt8 DEFAULT 0,
    status UInt8 DEFAULT 0
) ENGINE = MergeTree ORDER BY id;
```

---

**最后更新**: 2026-01-19
**适用版本**: ClickHouse 23.x+
