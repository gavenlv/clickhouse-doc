# 日期时间操作专题

本专题介绍 ClickHouse 中的日期时间类型、函数、操作和最佳实践。

## 📚 文档目录

### 基础知识
- [01_date_time_types.md](./01_date_time_types.md) - 日期时间类型详解
- [02_date_time_functions.md](./02_date_time_functions.md) - 日期时间函数大全
- [03_time_zones.md](./03_time_zones.md) - 时区处理

### 操作和查询
- [04_date_arithmetic.md](./04_date_arithmetic.md) - 日期算术运算
- [05_time_range_queries.md](./05_time_range_queries.md) - 时间范围查询
- [06_date_formatting.md](./06_date_formatting.md) - 日期格式化和解析

### 高级应用
- [07_time_series_analysis.md](./07_time_series_analysis.md) - 时间序列分析
- [08_window_functions.md](./08_window_functions.md) - 窗口函数和时间窗口
- [09_date_performance.md](./09_date_performance.md) - 日期时间性能优化

## 🎯 快速开始

### 获取当前时间

```sql
-- 获取当前日期时间
SELECT now();

-- 获取当前日期
SELECT today();

-- 获取昨天日期
SELECT yesterday();

-- 获取当前时间戳
SELECT toUnixTimestamp(now());
```

### 日期时间类型

```sql
-- DateTime
SELECT now() AS dt, toTypeName(dt) AS type;

-- DateTime64（带微秒精度）
SELECT now64(6) AS dt64, toTypeName(dt64) AS type;

-- Date
SELECT today() AS d, toTypeName(d) AS type;

-- Date32
SELECT toDate32('2024-01-20') AS d32, toTypeName(d32) AS type;
```

### 日期转换

```sql
-- 字符串转 DateTime
SELECT toDateTime('2024-01-20 12:34:56');

-- DateTime 转字符串
SELECT formatDateTime(now(), '%Y-%m-%d %H:%M:%S');

-- Unix 时间戳转换
SELECT toDateTime(toUnixTimestamp(now()));

-- 日期时间转 Date
SELECT toDate(now());
```

### 时间范围查询

```sql
-- 查询今天的数据
SELECT * FROM events
WHERE toYYYYMMDD(event_time) = toYYYYMMDD(today());

-- 查询最近 7 天的数据
SELECT * FROM events
WHERE event_time >= now() - INTERVAL 7 DAY;

-- 查询特定月份的数据
SELECT * FROM events
WHERE toYYYYMM(event_time) = '202401';

-- 使用 toStartOfDay 查询
SELECT * FROM events
WHERE event_time >= toStartOfDay(now());
```

## 📊 日期时间类型对比

| 类型 | 大小 | 精度 | 范围 | 时区 | 适用场景 |
|------|------|------|------|------|---------|
| `Date` | 2 字节 | 1 天 | 1970-2100 | 无 | 日期（无时间） |
| `Date32` | 4 字节 | 1 天 | 1900-2299 | 无 | 扩展日期范围 |
| `DateTime` | 4 字节 | 1 秒 | 1970-2106 | 有 | 日期时间 |
| `DateTime64` | 8 字节 | 可配置 | 1900-2300 | 有 | 高精度时间戳 |

## 🎯 常用场景

### 场景 1: 时间范围过滤

```sql
-- 查询最近 N 天的数据
SELECT 
    toStartOfDay(event_time) AS day,
    count() AS events
FROM events
WHERE event_time >= now() - INTERVAL 30 DAY
GROUP BY day
ORDER BY day;
```

### 场景 2: 时区转换

```sql
-- 转换时区
SELECT 
    event_time AS utc_time,
    toTimezone(event_time, 'Asia/Shanghai') AS beijing_time,
    toTimezone(event_time, 'America/New_York') AS ny_time
FROM events
LIMIT 10;
```

### 场景 3: 日期格式化

```sql
-- 自定义日期格式
SELECT 
    event_time,
    formatDateTime(event_time, '%Y-%m-%d %H:%M:%S') AS formatted,
    formatDateTime(event_time, '%A, %B %d, %Y') AS full_format
FROM events
LIMIT 10;
```

### 场景 4: 时间差计算

```sql
-- 计算时间差
SELECT 
    event_time,
    created_at,
    dateDiff('second', created_at, event_time) AS diff_seconds,
    dateDiff('minute', created_at, event_time) AS diff_minutes,
    dateDiff('hour', created_at, event_time) AS diff_hours
FROM events
LIMIT 10;
```

### 场景 5: 时间序列分析

```sql
-- 按小时聚合
SELECT 
    toStartOfHour(event_time) AS hour,
    count() AS event_count,
    avg(value) AS avg_value
FROM metrics
WHERE event_time >= now() - INTERVAL 7 DAY
GROUP BY hour
ORDER BY hour;
```

## 💡 最佳实践

1. **使用合适的类型**：根据需求选择 Date、DateTime 或 DateTime64
2. **分区键设计**：使用日期作为分区键提高查询性能
3. **时区一致性**：在整个系统中使用一致的时区
4. **时间范围查询**：使用时间范围而非具体时间点
5. **函数选择**：优先使用 toStartOfX 系列函数

## ⚠️ 注意事项

1. **时区影响**：DateTime 类型受时区影响，注意配置
2. **精度损失**：DateTime64 的精度需要在创建表时指定
3. **性能考虑**：复杂的日期计算可能影响性能
4. **字符串解析**：使用 toDateTime 或 parseDateTime 解析日期字符串
5. **时间范围**：注意 Date 和 DateTime 的范围限制

## 📖 相关文档

- [05-data-type/03_date_time_types.md](../05-data-type/03_date_time_types.md) - 数据类型详解
- [01-base/01_basic_operations.sql](../01-base/01_basic_operations.sql) - 基础操作
- [00-infra/REALTIME_PERFORMANCE_GUIDE.md](../00-infra/REALTIME_PERFORMANCE_GUIDE.md) - 实时性能优化
