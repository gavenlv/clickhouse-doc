# 日期格式化和解析

本文档介绍 ClickHouse 中的日期时间格式化和解析方法。

## 📋 格式化函数

### formatDateTime

```sql
-- 基本格式化
SELECT 
    formatDateTime(now(), '%Y-%m-%d %H:%M:%S') AS format1,
    formatDateTime(now(), '%Y年%m月%d日') AS format2,
    formatDateTime(now(), '%A, %B %d, %Y') AS format3;

-- 常用格式
SELECT
    formatDateTime(now(), '%Y-%m-%d') AS date_only,
    formatDateTime(now(), '%H:%M:%S') AS time_only,
    formatDateTime(now(), '%Y-%m-%d %H:%M') AS datetime_minute,
    formatDateTime(now(), '%Y-%m-%dT%H:%M:%S') AS iso_format;
```

### 格式化占位符

```sql
-- 所有可用的占位符
SELECT
    formatDateTime(now(), '%Y') AS year,              -- 4 位年：2024
    formatDateTime(now(), '%y') AS year2,             -- 2 位年：24
    formatDateTime(now(), '%m') AS month,             -- 2 位月：01
    formatDateTime(now(), '%d') AS day,               -- 2 位日：20
    formatDateTime(now(), '%H') AS hour,              -- 24 小时：14
    formatDateTime(now(), '%I') AS hour12,            -- 12 小时：02
    formatDateTime(now(), '%M') AS minute,            -- 2 位分：30
    formatDateTime(now(), '%S') AS second,            -- 2 位秒：45
    formatDateTime(now(), '%p') AS ampm,              -- AM/PM：PM
    formatDateTime(now(), '%A') AS weekday_full,       -- 星期全名：Saturday
    formatDateTime(now(), '%a') AS weekday_abbr,       -- 星期缩写：Sat
    formatDateTime(now(), '%B') AS month_full,         -- 月份全名：January
    formatDateTime(now(), '%b') AS month_abbr,         -- 月份缩写：Jan
    formatDateTime(now(), '%j') AS day_of_year,        -- 年中第几天：020
    formatDateTime(now(), '%w') AS week_day,           -- 周几（0-6）：6
    formatDateTime(now(), '%W') AS week_number;        -- 周数（1-53）：03
```

## 🎯 常用格式

### ISO 8601 格式

```sql
-- ISO 8601 日期时间
SELECT
    formatDateTime(now(), '%Y-%m-%dT%H:%M:%S') AS iso_basic,
    formatDateTime(now(), '%Y-%m-%dT%H:%M:%SZ') AS iso_utc,
    formatDateTime(now(), '%Y-%m-%dT%H:%M:%S%:z') AS iso_timezone;
```

### 地方化格式

```sql
-- 中文格式
SELECT
    formatDateTime(now(), '%Y年%m月%d日') AS chinese_date,
    formatDateTime(now(), '%Y年%m月%d日 %H时%M分%S秒') AS chinese_full;

-- 英文格式
SELECT
    formatDateTime(now(), '%B %d, %Y') AS us_date,
    formatDateTime(now(), '%d %B %Y') AS uk_date,
    formatDateTime(now(), '%A, %B %d, %Y') AS full_text;

-- 短格式
SELECT
    formatDateTime(now(), '%Y/%m/%d') AS short_date,
    formatDateTime(now(), '%m/%d/%Y') AS us_short_date;
```

### 时间格式

```sql
-- 24 小时制
SELECT
    formatDateTime(now(), '%H:%M') AS time_hm,
    formatDateTime(now(), '%H:%M:%S') AS time_hms,
    formatDateTime(now(), '%H:%M:%S.%f') AS time_hms_ms;

-- 12 小时制
SELECT
    formatDateTime(now(), '%I:%M %p') AS time12,
    formatDateTime(now(), '%I:%M:%S %p') AS time12_full;
```

## 🔄 解析函数

### parseDateTime

```sql
-- 解析基本格式
SELECT
    parseDateTime('2024-01-20') AS date,
    parseDateTime('2024-01-20 14:30:45') AS datetime,
    parseDateTime('2024/01/20', '%Y/%m/%d') AS custom_format;

-- 解析不同格式
SELECT
    parseDateTime('2024-01-20', '%Y-%m-%d') AS format1,
    parseDateTime('01/20/2024', '%m/%d/%Y') AS format2,
    parseDateTime('20-Jan-2024', '%d-%b-%Y') AS format3;
```

### parseDateTimeBestEffort

```sql
-- 智能解析（支持多种格式）
SELECT
    parseDateTimeBestEffort('2024-01-20') AS parsed1,
    parseDateTimeBestEffort('2024-01-20 14:30:45') AS parsed2,
    parseDateTimeBestEffort('2024/01/20 14:30') AS parsed3,
    parseDateTimeBestEffort('20 Jan 2024') AS parsed4,
    parseDateTimeBestEffort('20240120') AS parsed5;

-- 解析 Unix 时间戳
SELECT
    parseDateTimeBestEffort('1705757696') AS parsed_ts;
```

## 🎯 格式化场景

### 场景 1: 报表生成

```sql
-- 生成日报表
SELECT
    formatDateTime(event_time, '%Y-%m-%d') AS report_date,
    event_type,
    count() AS event_count
FROM events
WHERE event_time >= toStartOfDay(now())
GROUP BY report_date, event_type
ORDER BY report_date, event_type;
```

### 场景 2: 日志文件命名

```sql
-- 生成日志文件名
SELECT
    concat(
        'access_', 
        formatDateTime(event_time, '%Y%m%d'), 
        '_', 
        formatDateTime(event_time, '%H%M%S'),
        '.log'
    ) AS log_filename
FROM events
LIMIT 10;
```

### 场景 3: API 响应

```sql
-- 格式化 API 响应中的时间
SELECT
    id,
    name,
    formatDateTime(created_at, '%Y-%m-%dT%H:%M:%SZ') AS created_at_iso,
    formatDateTime(updated_at, '%Y-%m-%d %H:%M:%S') AS updated_at_local
FROM users
LIMIT 10;
```

### 场景 4: 数据导出

```sql
-- 导出 CSV 格式的时间
SELECT
    id,
    event_time,
    formatDateTime(event_time, '%Y-%m-%d %H:%M:%S') AS formatted_time,
    event_type,
    data
FROM events
WHERE event_time >= toStartOfDay(now())
FORMAT CSV;
```

### 场景 5: 多语言支持

```sql
-- 多语言日期显示
SELECT
    formatDateTime(now(), '%Y年%m月%d日') AS chinese,
    formatDateTime(now(), '%B %d, %Y') AS english,
    formatDateTime(now(), '%d/%m/%Y') AS french_style;
```

## 📊 高级格式化

### 自定义函数

```sql
-- 创建自定义格式化函数
CREATE FUNCTION formatChineseDate AS (d) -> 
    formatDateTime(d, '%Y年%m月%d日');

CREATE FUNCTION formatFriendlyTime AS (dt) -> 
    if(dateDiff('day', dt, now()) < 1,
        concat(dateDiff('hour', dt, now()), ' hours ago'),
        if(dateDiff('day', dt, now()) < 7,
            concat(dateDiff('day', dt, now()), ' days ago'),
            formatDateTime(dt, '%Y-%m-%d')
        )
    );

-- 使用自定义函数
SELECT
    formatChineseDate(event_time) AS chinese_date,
    formatFriendlyTime(event_time) AS friendly_time
FROM events
LIMIT 10;
```

### 条件格式化

```sql
-- 根据时间差格式化
SELECT
    event_time,
    case
        when dateDiff('minute', event_time, now()) < 60 then 
            concat(dateDiff('minute', event_time, now()), ' 分钟前')
        when dateDiff('hour', event_time, now()) < 24 then
            concat(dateDiff('hour', event_time, now()), ' 小时前')
        when dateDiff('day', event_time, now()) < 30 then
            concat(dateDiff('day', event_time, now()), ' 天前')
        else formatDateTime(event_time, '%Y-%m-%d')
    end as friendly_time
FROM events
ORDER BY event_time DESC
LIMIT 10;
```

## 💡 最佳实践

1. **使用标准格式**：优先使用 ISO 8601 格式
2. **指定格式字符串**：解析时明确指定格式字符串
3. **使用 BestEffort**：解析不确定格式的输入时使用 parseDateTimeBestEffort
4. **预计算格式化**：物化常用的格式化结果
5. **避免重复解析**：在物化视图中预解析日期

## ⚠️ 常见陷阱

### 陷阱 1: 格式不匹配

```sql
-- ❌ 错误：格式不匹配
SELECT parseDateTime('2024/01/20', '%Y-%m-%d');  -- 失败

-- ✅ 正确：匹配格式
SELECT parseDateTime('2024/01/20', '%Y/%m/%d');  -- 成功
```

### 陷阱 2: 时区问题

```sql
-- ❌ 错误：不考虑时区
SELECT formatDateTime(now(), '%Y-%m-%d %H:%M:%S');
-- 使用服务器时区，可能不是期望的

-- ✅ 正确：转换时区后格式化
SELECT formatDateTime(toTimezone(now(), 'Asia/Shanghai'), '%Y-%m-%d %H:%M:%S');
```

### 陷阱 3: 性能问题

```sql
-- ❌ 错误：在查询中重复格式化
SELECT 
    formatDateTime(event_time, '%Y-%m-%d') AS date,
    count() AS cnt
FROM events
WHERE formatDateTime(event_time, '%Y-%m-%d') = '2024-01-20'
GROUP BY formatDateTime(event_time, '%Y-%m-%d');

-- ✅ 正确：预计算日期列
SELECT 
    event_date,
    count() AS cnt
FROM events
WHERE event_date = '2024-01-20'
GROUP BY event_date;
```

## 📝 相关文档

- [02_date_time_functions.md](./02_date_time_functions.md) - 日期时间函数
- [03_time_zones.md](./03_time_zones.md) - 时区处理
- [05_time_range_queries.md](./05_time_range_queries.md) - 时间范围查询
