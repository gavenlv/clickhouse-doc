# 时间范围查询

本文档介绍如何在 ClickHouse 中高效地查询时间范围数据。

## 📋 基本时间范围查询

### 简单范围查询

```sql
-- 查询特定日期的数据
SELECT * FROM events
WHERE event_time >= '2024-01-20 00:00:00'
  AND event_time < '2024-01-21 00:00:00';

-- 使用 INTERVAL
SELECT * FROM events
WHERE event_time >= now() - INTERVAL 7 DAY
  AND event_time < now();

-- 使用函数
SELECT * FROM events
WHERE event_time >= toStartOfDay(now())
  AND event_time < toStartOfDay(now()) + INTERVAL 1 DAY;
```

### 函数辅助查询

```sql
-- 使用 toStartOfDay
SELECT * FROM events
WHERE event_time >= toStartOfDay(now() - INTERVAL 7 DAY)
  AND event_time < toStartOfDay(now());

-- 使用 toStartOfMonth
SELECT * FROM events
WHERE event_time >= toStartOfMonth(now())
  AND event_time < toEndOfMonth(now());

-- 使用 toStartOfYear
SELECT * FROM events
WHERE event_time >= toStartOfYear(now())
  AND event_time < toStartOfYear(now()) + INTERVAL 1 YEAR;
```

## 🎯 常用时间范围

### 相对时间范围

```sql
-- 最近 N 天
SELECT * FROM events
WHERE event_time >= now() - INTERVAL 1 DAY;    -- 最近 1 天
SELECT * FROM events
WHERE event_time >= now() - INTERVAL 7 DAY;    -- 最近 7 天
SELECT * FROM events
WHERE event_time >= now() - INTERVAL 30 DAY;   -- 最近 30 天

-- 最近 N 小时
SELECT * FROM events
WHERE event_time >= now() - INTERVAL 1 HOUR;    -- 最近 1 小时
SELECT * FROM events
WHERE event_time >= now() - INTERVAL 24 HOUR;   -- 最近 24 小时

-- 最近 N 分钟
SELECT * FROM events
WHERE event_time >= now() - INTERVAL 5 MINUTE;  -- 最近 5 分钟
SELECT * FROM events
WHERE event_time >= now() - INTERVAL 60 MINUTE; -- 最近 60 分钟
```

### 固定时间范围

```sql
-- 本周
SELECT * FROM events
WHERE event_time >= toStartOfWeek(now())
  AND event_time < toStartOfWeek(now()) + INTERVAL 7 DAY;

-- 本月
SELECT * FROM events
WHERE event_time >= toStartOfMonth(now())
  AND event_time < toEndOfMonth(now());

-- 本季度
SELECT * FROM events
WHERE event_time >= toStartOfQuarter(now())
  AND event_time < toEndOfQuarter(now());

-- 本年
SELECT * FROM events
WHERE event_time >= toStartOfYear(now())
  AND event_time < toEndOfYear(now());
```

## 📊 分区裁剪优化

### 利用分区键

```sql
-- 假设表按月分区
-- PARTITION BY toYYYYMM(event_time)

-- 查询会自动使用分区裁剪
SELECT * FROM events
WHERE event_time >= '2024-01-01'
  AND event_time < '2024-02-01';

-- 只扫描 2024-01 分区
```

### 分区键设计

```sql
-- 好的分区键设计
CREATE TABLE events (
    id UInt64,
    event_time DateTime,
    data String
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)  -- 按月分区
ORDER BY (event_time, id);

-- 查询时自动裁剪
SELECT * FROM events
WHERE event_time >= '2024-01-01'
  AND event_time < '2024-02-01';  -- 只扫描 1 个分区
```

## 🎯 查询场景

### 场景 1: 每日统计

```sql
-- 按天聚合
SELECT
    toStartOfDay(event_time) AS day,
    count() AS event_count,
    avg(value) AS avg_value,
    sum(value) AS total_value
FROM events
WHERE event_time >= toStartOfDay(now() - INTERVAL 30 DAY)
GROUP BY day
ORDER BY day;
```

### 场景 2: 每小时统计

```sql
-- 按小时聚合
SELECT
    toStartOfHour(event_time) AS hour,
    count() AS event_count,
    avg(value) AS avg_value
FROM events
WHERE event_time >= toStartOfDay(now())
GROUP BY hour
ORDER BY hour;
```

### 场景 3: 对比分析

```sql
-- 对比本周和上周
SELECT
    'This Week' AS period,
    count() AS event_count
FROM events
WHERE event_time >= toStartOfWeek(now())
  AND event_time < toStartOfWeek(now()) + INTERVAL 7 DAY

UNION ALL

SELECT
    'Last Week',
    count()
FROM events
WHERE event_time >= toStartOfWeek(now()) - INTERVAL 7 DAY
  AND event_time < toStartOfWeek(now());
```

### 场景 4: 时间序列分析

```sql
-- 生成完整的时间序列
SELECT
    time_series.day,
    countIf(event_time >= time_series.day 
            AND event_time < time_series.day + INTERVAL 1 DAY) AS event_count
FROM (
    SELECT toDate(now() - INTERVAL n DAY) AS day
    FROM numbers(30)
    WHERE toDate(now() - INTERVAL n DAY) >= now() - INTERVAL 30 DAY
) AS time_series
LEFT JOIN events 
    ON events.event_time >= time_series.day 
    AND events.event_time < time_series.day + INTERVAL 1 DAY
GROUP BY time_series.day
ORDER BY time_series.day;
```

### 场景 5: 滑动窗口

```sql
-- 7 天滑动窗口
SELECT
    event_time,
    event_type,
    count() OVER (
        PARTITION BY event_type
        ORDER BY event_time
        RANGE BETWEEN INTERVAL 7 DAY PRECEDING AND CURRENT ROW
    ) AS rolling_7d_count
FROM events
ORDER BY event_time
LIMIT 1000;
```

## 📊 性能优化

### 使用预计算列

```sql
-- 创建表时物化日期列
CREATE TABLE events_optimized (
    id UInt64,
    event_time DateTime,
    event_date Date MATERIALIZED toDate(event_time),
    event_month UInt16 MATERIALIZED toYYYYMM(event_time),
    event_year UInt16 MATERIALIZED toYear(event_time),
    data String
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_time, id);

-- 查询时使用预计算列（更快）
SELECT
    event_date,
    count() AS event_count
FROM events_optimized
WHERE event_date >= today() - INTERVAL 30 DAY
GROUP BY event_date
ORDER BY event_date;
```

### 使用物化视图

```sql
-- 创建预聚合物化视图
CREATE MATERIALIZED VIEW daily_stats_mv
ENGINE = AggregatingMergeTree()
PARTITION BY toYYYYMM(event_date)
ORDER BY (event_date, event_type)
AS SELECT
    toDate(event_time) AS event_date,
    event_type,
    countState() AS event_count_state,
    avgState(value) AS avg_value_state,
    sumState(value) AS total_value_state
FROM events
GROUP BY event_date, event_type;

-- 查询物化视图（极快）
SELECT
    event_date,
    event_type,
    countMerge(event_count_state) AS event_count,
    avgMerge(avg_value_state) AS avg_value,
    sumMerge(total_value_state) AS total_value
FROM daily_stats_mv
WHERE event_date >= today() - INTERVAL 30 DAY
GROUP BY event_date, event_type
ORDER BY event_date, event_type;
```

## 🎯 高级查询

### 时间范围 IN 子句

```sql
-- 查询多个不连续的时间范围
SELECT * FROM events
WHERE event_time IN (
    (SELECT toDateTime('2024-01-01 00:00:00') WHERE 1),
    (SELECT toDateTime('2024-01-15 00:00:00') WHERE 1),
    (SELECT toDateTime('2024-02-01 00:00:00') WHERE 1)
);
```

### 时间范围连接

```sql
-- 连接两个时间范围
SELECT
    a.event_time AS a_time,
    b.event_time AS b_time,
    dateDiff('second', a.event_time, b.event_time) AS time_diff
FROM events a
JOIN events b 
    ON b.event_time >= a.event_time 
    AND b.event_time < a.event_time + INTERVAL 1 HOUR
WHERE a.event_type = 'start'
  AND b.event_type = 'end';
```

### 时间分桶

```sql
-- 按时间分桶
SELECT
    intDiv(toUnixTimestamp(event_time), 3600) AS hour_bucket,  -- 每小时一个桶
    count() AS event_count
FROM events
WHERE event_time >= now() - INTERVAL 24 HOUR
GROUP BY hour_bucket
ORDER BY hour_bucket;

-- 按天分桶
SELECT
    toDate(event_time) AS day_bucket,
    count() AS event_count
FROM events
WHERE event_time >= now() - INTERVAL 30 DAY
GROUP BY day_bucket
ORDER BY day_bucket;
```

## 💡 最佳实践

1. **使用分区裁剪**：设计合理的分区键以利用分区裁剪
2. **使用时间函数**：使用 toStartOfX 函数简化时间范围
3. **预计算列**：物化常用的时间列以提高查询性能
4. **避免全表扫描**：始终在 WHERE 子句中包含时间条件
5. **使用物化视图**：预聚合常用的时间维度

## ⚠️ 常见陷阱

### 陷阱 1: 不使用函数

```sql
-- ❌ 错误：不使用时间函数，可能不准确
SELECT * FROM events
WHERE event_time >= '2024-01-01'
  AND event_time < '2024-01-02';

-- ✅ 正确：使用 toStartOfDay
SELECT * FROM events
WHERE event_time >= toStartOfDay(toDateTime('2024-01-01'))
  AND event_time < toStartOfDay(toDateTime('2024-01-02'));
```

### 陷阱 2: 时间格式错误

```sql
-- ❌ 错误：格式不匹配
SELECT * FROM events
WHERE event_time >= '01/20/2024';

-- ✅ 正确：使用标准格式
SELECT * FROM events
WHERE event_time >= '2024-01-20';
```

### 陷阱 3: 忽略时区

```sql
-- ❌ 错误：不考虑时区
SELECT * FROM events
WHERE event_time >= '2024-01-20 00:00:00';

-- ✅ 正确：显式指定时区
SELECT * FROM events
WHERE event_time >= toDateTime('2024-01-20 00:00:00', 'UTC');
```

## 📝 相关文档

- [02_date_time_functions.md](./02_date_time_functions.md) - 日期时间函数
- [04_date_arithmetic.md](./04_date_arithmetic.md) - 日期算术运算
- [07_time_series_analysis.md](./07_time_series_analysis.md) - 时间序列分析
