# 日期时间类型详解

本文档详细介绍 ClickHouse 中的日期时间类型。

## 📋 类型概览

### Date 类型

```sql
-- Date 类型：精确到天，2 字节
CREATE TABLE date_demo (
    id UInt64,
    date_col Date
) ENGINE = MergeTree()
ORDER BY id;

-- 插入数据
INSERT INTO date_demo VALUES
    (1, toDate('2024-01-20')),
    (2, toDate('2024-01-21'));

-- 查询
SELECT 
    date_col,
    toTypeName(date_col) AS type,
    toUnixTimestamp(date_col) AS unix_timestamp
FROM date_demo;
```

**特性**：
- 大小：2 字节
- 精度：1 天
- 范围：1970-01-01 到 2106-02-03
- 无时区

### Date32 类型

```sql
-- Date32 类型：扩展范围，4 字节
CREATE TABLE date32_demo (
    id UInt64,
    date_col Date32
) ENGINE = MergeTree()
ORDER BY id;

-- 插入数据
INSERT INTO date32_demo VALUES
    (1, toDate32('2024-01-20')),
    (2, toDate32('1900-01-01')),
    (3, toDate32('2299-12-31'));

-- 查询
SELECT 
    date_col,
    toTypeName(date_col) AS type
FROM date32_demo;
```

**特性**：
- 大小：4 字节
- 精度：1 天
- 范围：1900-01-01 到 2299-12-31
- 无时区

### DateTime 类型

```sql
-- DateTime 类型：精确到秒，4 字节
CREATE TABLE datetime_demo (
    id UInt64,
    datetime_col DateTime
) ENGINE = MergeTree()
ORDER BY id;

-- 插入数据
INSERT INTO datetime_demo VALUES
    (1, toDateTime('2024-01-20 12:34:56')),
    (2, toDateTime('2024-01-21 15:30:00'));

-- 查询
SELECT 
    datetime_col,
    toTypeName(datetime_col) AS type,
    toUnixTimestamp(datetime_col) AS unix_timestamp
FROM datetime_demo;
```

**特性**：
- 大小：4 字节
- 精度：1 秒
- 范围：1970-01-01 00:00:00 到 2106-02-03 06:28:15
- 有时区（默认服务器时区）

### DateTime64 类型

```sql
-- DateTime64 类型：可配置精度，8 字节
CREATE TABLE datetime64_demo (
    id UInt64,
    datetime_col DateTime64(3)  -- 毫秒精度
) ENGINE = MergeTree()
ORDER BY id;

-- 插入数据
INSERT INTO datetime64_demo VALUES
    (1, toDateTime64('2024-01-20 12:34:56.789', 3)),
    (2, now64(6));  -- 微秒精度

-- 查询
SELECT 
    datetime_col,
    toTypeName(datetime_col) AS type,
    toUnixTimestamp64Milli(datetime_col) AS unix_timestamp_ms
FROM datetime64_demo;
```

**精度选项**：
- `DateTime64(0)` - 秒
- `DateTime64(3)` - 毫秒
- `DateTime64(6)` - 微秒
- `DateTime64(9)` - 纳秒

## 🎯 类型对比

| 类型 | 字节 | 精度 | 最小值 | 最大值 | 时区 | 存储效率 |
|------|------|------|--------|--------|------|---------|
| `Date` | 2 | 1 天 | 1970-01-01 | 2106-02-03 | 无 | ⭐⭐⭐⭐⭐ |
| `Date32` | 4 | 1 天 | 1900-01-01 | 2299-12-31 | 无 | ⭐⭐⭐⭐ |
| `DateTime` | 4 | 1 秒 | 1970-01-01 | 2106-02-03 | 有 | ⭐⭐⭐⭐⭐ |
| `DateTime64(0)` | 8 | 1 秒 | 1900-01-01 | 2300-01-01 | 有 | ⭐⭐⭐ |
| `DateTime64(3)` | 8 | 1 毫秒 | 1900-01-01 | 2300-01-01 | 有 | ⭐⭐⭐ |
| `DateTime64(6)` | 8 | 1 微秒 | 1900-01-01 | 2300-01-01 | 有 | ⭐⭐⭐ |

## 🎯 使用场景

### 场景 1: 只需要日期

```sql
-- 使用 Date 类型存储生日
CREATE TABLE users (
    id UInt64,
    name String,
    birth_date Date
) ENGINE = MergeTree()
ORDER BY id;

-- 查询今天过生日的用户
SELECT * FROM users
WHERE 
    toMonth(birth_date) = toMonth(today())
    AND toDayOfMonth(birth_date) = toDayOfMonth(today());
```

### 场景 2: 事件日志（秒级精度）

```sql
-- 使用 DateTime 存储事件时间
CREATE TABLE events (
    id UInt64,
    event_time DateTime,
    event_type String,
    data String
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY event_time;

-- 查询最近 1 小时的事件
SELECT * FROM events
WHERE event_time >= now() - INTERVAL 1 HOUR;
```

### 场景 3: 高精度时间戳

```sql
-- 使用 DateTime64 存储微秒级时间
CREATE TABLE sensor_data (
    sensor_id UInt64,
    reading_time DateTime64(6),
    value Float64
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(reading_time)
ORDER BY (sensor_id, reading_time);

-- 插入高精度数据
INSERT INTO sensor_data VALUES
    (1, now64(6), 25.6),
    (2, toDateTime64('2024-01-20 12:34:56.789012', 6), 23.4);
```

### 场景 4: 时区敏感的应用

```sql
-- 使用 DateTime 处理多时区数据
CREATE TABLE global_events (
    id UInt64,
    event_time DateTime,  -- UTC 时间
    event_timezone String,
    description String
) ENGINE = MergeTree()
ORDER BY event_time;

-- 查询并转换为本地时区
SELECT 
    event_time AS utc_time,
    toTimezone(event_time, 'Asia/Shanghai') AS beijing_time,
    toTimezone(event_time, 'America/New_York') AS ny_time,
    description
FROM global_events;
```

## 🔄 类型转换

### 显式转换

```sql
-- 字符串转 Date
SELECT toDate('2024-01-20');
SELECT toDate32('2024-01-20');

-- 字符串转 DateTime
SELECT toDateTime('2024-01-20 12:34:56');
SELECT toDateTime('2024-01-20T12:34:56');  -- ISO 格式

-- Unix 时间戳转 DateTime
SELECT toDateTime(1705757696);

-- Date 转 DateTime
SELECT toDateTime(toDate('2024-01-20'));

-- DateTime 转 Date
SELECT toDate(now());

-- DateTime64 转 DateTime
SELECT toDateTime(toDateTime64('2024-01-20 12:34:56.789', 3));
```

### 隐式转换

```sql
-- ClickHouse 会在某些情况下自动转换
SELECT '2024-01-20'::Date AS date_val;

-- 比较时的自动转换
SELECT now() > '2024-01-20';  -- 字符串自动转 DateTime
```

## 📊 性能考虑

### 存储效率

```sql
-- 比较不同类型的存储效率
CREATE TABLE storage_test (
    id UInt64,
    date_col Date,
    datetime_col DateTime,
    datetime64_col DateTime64(3)
) ENGINE = MergeTree()
ORDER BY id;

-- 插入 1000 万行测试数据
-- 分析存储占用
SELECT
    'Date' as type,
    formatReadableSize(sum(data_compressed_bytes)) as compressed,
    formatReadableSize(sum(data_uncompressed_bytes)) as uncompressed
FROM system.parts_columns
WHERE table = 'storage_test' AND column = 'date_col'

UNION ALL

SELECT
    'DateTime',
    formatReadableSize(sum(data_compressed_bytes)),
    formatReadableSize(sum(data_uncompressed_bytes))
FROM system.parts_columns
WHERE table = 'storage_test' AND column = 'datetime_col'

UNION ALL

SELECT
    'DateTime64(3)',
    formatReadableSize(sum(data_compressed_bytes)),
    formatReadableSize(sum(data_uncompressed_bytes))
FROM system.parts_columns
WHERE table = 'storage_test' AND column = 'datetime64_col';
```

### 查询性能

```sql
-- 不同类型的查询性能
-- Date 类型查询（最快）
SELECT count() FROM storage_test
WHERE date_col = '2024-01-20';

-- DateTime 类型查询（快）
SELECT count() FROM storage_test
WHERE datetime_col = toDateTime('2024-01-20 00:00:00');

-- DateTime64 类型查询（较慢）
SELECT count() FROM storage_test
WHERE datetime64_col = toDateTime64('2024-01-20 00:00:00.000', 3);
```

## 💡 最佳实践

1. **优先使用 Date**：如果只需要日期，使用 Date 类型
2. **合理选择精度**：DateTime64 的精度根据实际需求选择
3. **使用 UTC 时间**：存储使用 UTC，显示时转换为本地时区
4. **分区键设计**：使用日期作为分区键提高查询性能
5. **避免隐式转换**：显式指定类型转换以提高性能

## ⚠️ 常见陷阱

### 陷阱 1: 时区混淆

```sql
-- ❌ 错误：假设所有时间都是本地时间
SELECT * FROM events
WHERE event_time = '2024-01-20 12:00:00';

-- ✅ 正确：使用 UTC 时间
SELECT * FROM events
WHERE event_time = toDateTime('2024-01-20 12:00:00', 'UTC');
```

### 陷阱 2: 精度丢失

```sql
-- ❌ 错误：使用 DateTime 丢失微秒精度
-- 存储时：2024-01-20 12:34:56.789
-- 读取时：2024-01-20 12:34:56

-- ✅ 正确：使用 DateTime64
CREATE TABLE events (
    event_time DateTime64(3)
) ENGINE = MergeTree()
ORDER BY event_time;
```

### 陷阱 3: 范围超出

```sql
-- ❌ 错误：Date 类型范围超出
INSERT INTO date_demo VALUES (1, toDate('1800-01-01'));  -- 失败

-- ✅ 正确：使用 Date32
CREATE TABLE wide_date_range (
    date_col Date32
) ENGINE = MergeTree()
ORDER BY date_col;
```

## 📝 相关文档

- [02_date_time_functions.md](./02_date_time_functions.md) - 日期时间函数
- [04_date_arithmetic.md](./04_date_arithmetic.md) - 日期算术运算
- [05_time_range_queries.md](./05_time_range_queries.md) - 时间范围查询
