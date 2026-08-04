# 日期算术运算

本文档介绍 ClickHouse 中的日期时间算术运算。

## 📋 基本运算

### 时间加减

```sql
-- 加法：添加时间间隔
SELECT 
    now() + INTERVAL 1 DAY AS tomorrow,
    now() + INTERVAL 1 WEEK AS next_week,
    now() + INTERVAL 1 MONTH AS next_month,
    now() + INTERVAL 1 YEAR AS next_year,
    now() + INTERVAL 1 HOUR AS next_hour,
    now() + INTERVAL 30 MINUTE AS in_30_minutes,
    now() + INTERVAL 90 SECOND AS in_90_seconds;

-- 减法：减去时间间隔
SELECT 
    now() - INTERVAL 1 DAY AS yesterday,
    now() - INTERVAL 1 WEEK AS last_week,
    now() - INTERVAL 1 MONTH AS last_month,
    now() - INTERVAL 1 YEAR AS last_year,
    now() - INTERVAL 1 HOUR AS one_hour_ago,
    now() - INTERVAL 30 MINUTE AS 30_minutes_ago,
    now() - INTERVAL 90 SECOND AS 90_seconds_ago;
```

### 时间间隔类型

```sql
-- 使用不同的时间间隔单位
SELECT 
    now() + INTERVAL 1 SECOND AS add_second,
    now() + INTERVAL 1 MINUTE AS add_minute,
    now() + INTERVAL 1 HOUR AS add_hour,
    now() + INTERVAL 1 DAY AS add_day,
    now() + INTERVAL 1 WEEK AS add_week,
    now() + INTERVAL 1 MONTH AS add_month,
    now() + INTERVAL 1 QUARTER AS add_quarter,
    now() + INTERVAL 1 YEAR AS add_year;

-- 组合时间间隔
SELECT 
    now() + INTERVAL 1 DAY + INTERVAL 2 HOURS AS combined,
    now() + INTERVAL 1 MONTH - INTERVAL 7 DAYS AS combined2;
```

## 🎯 日期函数

### 专用加减函数

```sql
-- 使用专用函数
SELECT 
    addDays(now(), 1) AS tomorrow,
    addDays(now(), -1) AS yesterday,
    addWeeks(now(), 1) AS next_week,
    addMonths(now(), 1) AS next_month,
    addYears(now(), 1) AS next_year;

SELECT 
    subtractDays(now(), 7) AS 7_days_ago,
    subtractMonths(now(), 1) AS last_month,
    subtractYears(now(), 1) AS last_year;
```

### 时间戳运算

```sql
-- 使用 Unix 时间戳运算
SELECT 
    toDateTime(toUnixTimestamp(now()) + 86400) AS tomorrow_seconds,  -- +24小时
    toDateTime(toUnixTimestamp(now()) - 86400) AS yesterday_seconds;

-- 毫秒级精度
SELECT 
    toDateTime64(toUnixTimestamp64Milli(now64(3)) + 86400000, 3) AS tomorrow_millis;
```

## 📊 运算场景

### 场景 1: 计算到期时间

```sql
-- 订阅到期时间
SELECT
    user_id,
    subscription_start,
    subscription_duration_months,
    addMonths(subscription_start, subscription_duration_months) AS subscription_end,
    dateDiff('day', now(), addMonths(subscription_start, subscription_duration_months)) AS days_remaining
FROM subscriptions
WHERE addMonths(subscription_start, subscription_duration_months) > now();
```

### 场景 2: 活跃用户分析

```sql
-- 计算用户活跃度
SELECT
    user_id,
    last_login,
    dateDiff('day', last_login, now()) AS days_since_last_login,
    CASE 
        WHEN dateDiff('day', last_login, now()) <= 7 THEN 'active'
        WHEN dateDiff('day', last_login, now()) <= 30 THEN 'dormant'
        ELSE 'inactive'
    END AS activity_status
FROM users
ORDER BY last_login DESC;
```

### 场景 3: 时间窗口分析

```sql
-- 7 天滚动窗口
SELECT
    toStartOfDay(event_time) AS day,
    count() AS event_count,
    sum(count()) OVER (
        ORDER BY day
        ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
    ) AS rolling_7d_count
FROM events
WHERE event_time >= now() - INTERVAL 30 DAY
GROUP BY day
ORDER BY day;
```

### 场景 4: 计算年龄

```sql
-- 计算年龄
SELECT
    user_id,
    birth_date,
    dateDiff('year', birth_date, now()) AS age,
    dateDiff('month', birth_date, now()) AS age_months
FROM users;
```

### 场景 5: 事件间隔分析

```sql
-- 计算事件间隔
SELECT
    user_id,
    event_time,
    event_time - lagInFrame(event_time) OVER (PARTITION BY user_id ORDER BY event_time) AS time_since_last_event
FROM events
ORDER BY user_id, event_time;
```

## 🔄 高级运算

### 复杂时间表达式

```sql
-- 计算工作日
SELECT
    event_date,
    toDayOfWeek(event_date) AS day_of_week,
    CASE 
        WHEN toDayOfWeek(event_date) IN (6, 0) THEN 0  -- 周六、周日
        ELSE 1
    END AS is_workday;

-- 计算月末
SELECT
    event_date,
    toEndOfMonth(event_date) AS month_end,
    event_date = toEndOfMonth(event_date) AS is_month_end;
```

### 季度计算

```sql
-- 计算季度
SELECT
    event_date,
    toQuarter(event_date) AS quarter,
    toStartOfQuarter(event_date) AS quarter_start,
    toEndOfQuarter(event_date) AS quarter_end;
```

### 年度累计

```sql
-- 计算年初至今（YTD）
SELECT
    event_date,
    amount,
    sum(amount) OVER (
        PARTITION BY toYear(event_date)
        ORDER BY event_date
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS ytd_amount
FROM sales
ORDER BY event_date;
```

## 📊 性能优化

### 预计算时间列

```sql
-- 创建带预计算时间列的表
CREATE TABLE events (
    id UInt64,
    event_time DateTime,
    event_date Date MATERIALIZED toDate(event_time),
    event_hour UInt8 MATERIALIZED toHour(event_time),
    event_day_of_week UInt8 MATERIALIZED toDayOfWeek(event_time),
    data String
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_time, id);

-- 查询时使用预计算列
SELECT
    event_date,
    event_hour,
    count() AS event_count
FROM events
WHERE event_date >= today() - INTERVAL 30 DAY
GROUP BY event_date, event_hour
ORDER BY event_date, event_hour;
```

### 使用物化视图

```sql
-- 创建物化视图预聚合
CREATE MATERIALIZED VIEW daily_events_mv
ENGINE = SummingMergeTree()
PARTITION BY toYYYYMM(event_date)
ORDER BY (event_date, event_type)
AS SELECT
    toDate(event_time) AS event_date,
    event_type,
    count() AS event_count,
    sum(value) AS total_value
FROM events
GROUP BY event_date, event_type;

-- 查询物化视图（快速）
SELECT
    event_date,
    event_type,
    event_count
FROM daily_events_mv
WHERE event_date >= today() - INTERVAL 30 DAY
ORDER BY event_date, event_type;
```

## 💡 最佳实践

1. **使用 INTERVAL**：优先使用 INTERVAL 语法进行时间运算
2. **预计算列**：物化常用的时间列以提高查询性能
3. **索引时间列**：将时间列包含在排序键中
4. **避免重复计算**：在物化视图中预计算常用的时间聚合
5. **使用 dateDiff**：准确计算时间差异

## ⚠️ 常见陷阱

### 陷阱 1: 时区问题

```sql
-- ❌ 错误：不考虑时区
SELECT now() + INTERVAL 8 HOUR AS beijing_time;

-- ✅ 正确：显式转换时区
SELECT toTimezone(now(), 'Asia/Shanghai') AS beijing_time;
```

### 陷阱 2: 月份天数差异

```sql
-- ❌ 错误：假设所有月份都有 30 天
SELECT addDays(now(), 30) AS one_month_later;  -- 不准确

-- ✅ 正确：使用 addMonths
SELECT addMonths(now(), 1) AS one_month_later;  -- 准确
```

### 陷阱 3: 时间戳溢出

```sql
-- ❌ 错误：可能导致溢出
SELECT addYears(toDate('2100-01-01'), 10);  -- 超出范围

-- ✅ 正确：检查范围
SELECT 
    if(addYears(toDate('2100-01-01'), 10) > toDate('2106-02-03'), 
        toDate('2106-02-03'),  -- 最大值
        addYears(toDate('2100-01-01'), 10)) AS safe_date;
```

## 📝 相关文档

- [02_date_time_functions.md](./02_date_time_functions.md) - 日期时间函数
- [05_time_range_queries.md](./05_time_range_queries.md) - 时间范围查询
- [07_time_series_analysis.md](./07_time_series_analysis.md) - 时间序列分析
