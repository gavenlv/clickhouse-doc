# 日期时间函数大全

本文档介绍 ClickHouse 中常用的日期时间函数。

## 📋 函数分类

### 获取当前时间

```sql
-- 当前时间
SELECT now();                    -- DateTime
SELECT now64(6);                -- DateTime64(6)

-- 当前日期
SELECT today();                   -- Date
SELECT yesterday();               -- Date
SELECT tomorrow();                -- Date

-- 当前 Unix 时间戳
SELECT toUnixTimestamp(now());    -- UInt32
SELECT toUnixTimestamp64Milli(now());  -- UInt64
SELECT toUnixTimestamp64Micro(now());  -- UInt64
SELECT toUnixTimestamp64Nano(now());   -- UInt64
```

### 日期时间转换

```sql
-- 转换为 DateTime
SELECT toDateTime('2024-01-20 12:34:56');
SELECT toDateTime(1705757696);  -- Unix 时间戳
SELECT toDateTime64('2024-01-20 12:34:56.789', 3);

-- 转换为 Date
SELECT toDate('2024-01-20');
SELECT toDate('2024-01-20 12:34:56');  -- 时间部分被忽略
SELECT toDate32('2024-01-20');

-- 转换为字符串
SELECT formatDateTime(now(), '%Y-%m-%d %H:%M:%S');
SELECT formatDateTime(now(), '%Y年%m月%d日 %H时%M分%S秒');
SELECT toISOYear(now());
SELECT toISOWeek(now());
```

### 提取时间部分

```sql
-- 提取年
SELECT toYear(now());                     -- UInt16
SELECT toYear('2024-01-20');            -- 2024

-- 提取季度
SELECT toQuarter(now());                  -- UInt8 (1-4)
SELECT toQuarter('2024-01-20');         -- 1

-- 提取月
SELECT toMonth(now());                    -- UInt8 (1-12)
SELECT toMonth('2024-01-20');           -- 1

-- 提取日
SELECT toDayOfMonth(now());               -- UInt8 (1-31)
SELECT toDayOfMonth('2024-01-20');      -- 20

-- 提取星期
SELECT toDayOfWeek(now());                -- UInt8 (0-6, 0=周一)
SELECT toDayOfWeek('2024-01-20');       -- 6 (周六)

-- 提取小时
SELECT toHour(now());                    -- UInt8 (0-23)
SELECT toMinute(now());                   -- UInt8 (0-59)
SELECT toSecond(now());                   -- UInt8 (0-59)

-- 提取年中的第几天
SELECT toDayOfYear(now());                -- UInt16 (1-366)

-- 提取周中的第几天
SELECT toISOWeek(now());                 -- UInt16 (1-53)
```

### 时间戳转换

```sql
-- DateTime 转 Unix 时间戳
SELECT toUnixTimestamp(now());            -- 秒
SELECT toUnixTimestamp64Milli(now());    -- 毫秒
SELECT toUnixTimestamp64Micro(now());    -- 微秒
SELECT toUnixTimestamp64Nano(now());     -- 纳秒

-- Unix 时间戳转 DateTime
SELECT toDateTime(1705757696);
SELECT toDateTime64(1705757696000, 3);  -- 毫秒
SELECT toDateTime64(1705757696000000, 6);  -- 微秒
```

### 时间范围函数

```sql
-- 时间对齐到开始
SELECT toStartOfDay(now());              -- 当天 00:00:00
SELECT toStartOfHour(now());             -- 当前小时 00:00
SELECT toStartOfMinute(now());           -- 当前分钟 00:00
SELECT toStartOfMonth(now());            -- 当月 1 日 00:00:00
SELECT toStartOfQuarter(now());          -- 当前季度第一天
SELECT toStartOfYear(now());             -- 当年 1 月 1 日
SELECT toStartOfWeek(now());             -- 周一 00:00:00
SELECT toStartOfISOWeek(now());         -- ISO 周一
SELECT toStartOfInterval(now(), INTERVAL 1 DAY);

-- 时间对齐到结束
SELECT toEndOfDay(now());                -- 当天 23:59:59
SELECT toEndOfMonth(now());              -- 当月最后一天 23:59:59
SELECT toEndOfQuarter(now());           -- 当前季度最后一天
SELECT toEndOfYear(now());              -- 当年 12 月 31 日
```

### 时间格式化

```sql
-- 格式化日期时间
SELECT formatDateTime(now(), '%Y-%m-%d %H:%M:%S');
-- 输出: 2024-01-20 12:34:56

-- 格式化选项
SELECT 
    formatDateTime(now(), '%Y') AS year,           -- 2024
    formatDateTime(now(), '%m') AS month,          -- 01
    formatDateTime(now(), '%d') AS day,            -- 20
    formatDateTime(now(), '%H') AS hour,           -- 12
    formatDateTime(now(), '%M') AS minute,         -- 34
    formatDateTime(now(), '%S') AS second,         -- 56
    formatDateTime(now(), '%A') AS weekday,        -- Saturday
    formatDateTime(now(), '%B') AS month_name,     -- January
    formatDateTime(now(), '%j') AS day_of_year;   -- 020

-- 自定义格式
SELECT formatDateTime(now(), '%Y年%m月%d日 %H时%M分%S秒');
-- 输出: 2024年01月20日 12时34分56秒

SELECT formatDateTime(now(), 'Today is %A, %B %d, %Y');
-- 输出: Today is Saturday, January 20, 2024
```

### 日期解析

```sql
-- 解析日期字符串
SELECT parseDateTime('2024-01-20 12:34:56');  -- DateTime
SELECT parseDateTime('2024/01/20', '%Y/%m/%d');  -- 指定格式
SELECT parseDateTimeBestEffort('2024-01-20T12:34:56');  -- 智能解析

-- 解析日期（无时间）
SELECT parseDateTimeBestEffort('2024-01-20');  -- DateTime (00:00:00)

-- 从时间戳解析
SELECT parseDateTimeBestEffort('1705757696');
```

## 🎯 常用函数示例

### 场景 1: 获取时间范围

```sql
-- 获取当前周的日期范围
SELECT
    toStartOfWeek(now()) AS week_start,
    toEndOfWeek(now()) AS week_end;

-- 获取当前月的日期范围
SELECT
    toStartOfMonth(now()) AS month_start,
    toEndOfMonth(now()) AS month_end;

-- 获取当前季度的日期范围
SELECT
    toStartOfQuarter(now()) AS quarter_start,
    toEndOfQuarter(now()) AS quarter_end;
```

### 场景 2: 计算时间差

```sql
-- 计算两个时间的差异
SELECT
    dateDiff('second', '2024-01-01', '2024-01-20') AS diff_seconds,
    dateDiff('minute', '2024-01-01', '2024-01-20') AS diff_minutes,
    dateDiff('hour', '2024-01-01', '2024-01-20') AS diff_hours,
    dateDiff('day', '2024-01-01', '2024-01-20') AS diff_days,
    dateDiff('week', '2024-01-01', '2024-01-20') AS diff_weeks,
    dateDiff('month', '2024-01-01', '2024-01-20') AS diff_months,
    dateDiff('year', '2024-01-01', '2024-01-20') AS diff_years;
```

### 场景 3: 时间聚合

```sql
-- 按天聚合
SELECT
    toStartOfDay(event_time) AS day,
    count() AS event_count
FROM events
WHERE event_time >= toStartOfDay(now() - INTERVAL 7 DAY)
GROUP BY day
ORDER BY day;

-- 按小时聚合
SELECT
    toStartOfHour(event_time) AS hour,
    count() AS event_count
FROM events
WHERE event_time >= toStartOfDay(now())
GROUP BY hour
ORDER BY hour;

-- 按月聚合
SELECT
    toStartOfMonth(event_time) AS month,
    count() AS event_count
FROM events
WHERE event_time >= toStartOfMonth(now() - INTERVAL 12 MONTH)
GROUP BY month
ORDER BY month;
```

### 场景 4: 时间窗口

```sql
-- 滑动窗口
SELECT
    event_time,
    event_type,
    avg(value) OVER (
        PARTITION BY event_type
        ORDER BY event_time
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS running_avg
FROM sensor_data
ORDER BY event_time
LIMIT 100;

-- 时间范围窗口
SELECT
    event_time,
    event_type,
    avg(value) OVER (
        PARTITION BY event_type
        ORDER BY event_time
        RANGE BETWEEN INTERVAL 1 HOUR PRECEDING AND CURRENT ROW
    ) AS rolling_avg_1h
FROM sensor_data
ORDER BY event_time
LIMIT 100;
```

### 场景 5: 日期验证

```sql
-- 验证日期是否有效
SELECT
    isValidDateTime('2024-01-20 12:34:56') AS is_valid,
    isValidDateTime('2024-02-30 12:34:56') AS is_invalid,
    isValidDateTime('invalid date') AS is_error;

-- 处理无效日期
SELECT
    date_str,
    parseDateTimeBestEffort(date_str) AS parsed_date,
    isValidDateTime(parseDateTimeBestEffort(date_str)) AS is_valid
FROM (
    SELECT '2024-01-20' AS date_str
    UNION ALL SELECT '2024-02-30'
    UNION ALL SELECT 'invalid'
);
```

## 📊 高级函数

### 时间戳转换和比较

```sql
-- 转换为不同精度的时间戳
SELECT
    toUnixTimestamp(now()) AS ts_seconds,
    toUnixTimestamp64Milli(now()) AS ts_millis,
    toUnixTimestamp64Micro(now()) AS ts_micros,
    toUnixTimestamp64Nano(now()) AS ts_nanos;

-- 比较时间戳
SELECT
    now() > toDateTime(1705757696) AS is_after,
    now() < toDateTime(2100-01-01) AS is_before;

-- 时间戳差
SELECT
    toUnixTimestamp(now()) - toUnixTimestamp(toDateTime('2024-01-01')) AS seconds_since_start;
```

### 时间周期计算

```sql
-- 计算下一个周期时间
SELECT
    now() AS current_time,
    addWeeks(now(), 1) AS next_week,
    addMonths(now(), 1) AS next_month,
    addYears(now(), 1) AS next_year;

-- 计算上一个周期时间
SELECT
    now() AS current_time,
    subtractDays(now(), 7) AS last_week,
    subtractMonths(now(), 1) AS last_month,
    subtractYears(now(), 1) AS last_year;

-- 相对时间
SELECT
    now() + INTERVAL 1 DAY AS tomorrow,
    now() - INTERVAL 1 HOUR AS one_hour_ago,
    now() + INTERVAL 30 MINUTE AS in_30_minutes;
```

### 时区转换

```sql
-- 转换时区
SELECT
    now() AS utc_time,
    toTimezone(now(), 'Asia/Shanghai') AS beijing_time,
    toTimezone(now(), 'America/New_York') AS ny_time,
    toTimezone(now(), 'Europe/London') AS london_time;

-- 获取时区信息
SELECT
    timezone() AS current_timezone,
    toTimezone(now(), 'UTC') AS utc_time;
```

### 时间范围生成

```sql
-- 生成时间序列
SELECT 
    arrayJoin([
        toStartOfDay(now()) - INTERVAL n DAY
        FOR n IN (0, 1, 2, 3, 4, 5, 6)
    ]) AS date_series
ORDER BY date_series;

-- 生成更复杂的时间序列
SELECT
    toDate('2024-01-01') + INTERVAL toUInt32(number) DAY
FROM numbers(30)
WHERE toDate('2024-01-01') + INTERVAL toUInt32(number) DAY <= toDate('2024-01-30');
```

## 💡 最佳实践

1. **使用 toStartOfX**：提高时间范围查询的效率
2. **避免重复计算**：将时间计算结果存储在物化视图中
3. **使用 dateDiff**：准确计算时间差异
4. **格式化显示**：使用 formatDateTime 控制显示格式
5. **解析灵活性**：使用 parseDateTimeBestEffort 处理多种格式

## 📝 相关文档

- [01_date_time_types.md](./01_date_time_types.md) - 日期时间类型
- [04_date_arithmetic.md](./04_date_arithmetic.md) - 日期算术运算
- [05_time_range_queries.md](./05_time_range_queries.md) - 时间范围查询
