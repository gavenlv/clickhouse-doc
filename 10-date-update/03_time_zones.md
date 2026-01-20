# 时区处理

本文档介绍 ClickHouse 中的时区处理方法。

## 📋 时区基础

### 获取和设置时区

```sql
-- 获取当前时区
SELECT timezone();  -- 例如：Asia/Shanghai

-- 查看所有可用时区
SELECT * FROM system.time_zones 
ORDER BY name
LIMIT 100;

-- 搜索特定时区
SELECT name, offset 
FROM system.time_zones
WHERE name LIKE 'Asia/%'
ORDER BY name;
```

### 时区转换

```sql
-- 转换时间到不同时区
SELECT
    now() AS utc_time,
    toTimezone(now(), 'Asia/Shanghai') AS beijing_time,
    toTimezone(now(), 'America/New_York') AS ny_time,
    toTimezone(now(), 'Europe/London') AS london_time,
    toTimezone(now(), 'Asia/Tokyo') AS tokyo_time;
```

## 🎯 时区转换

### 转换为本地时区

```sql
-- 假设数据库存储 UTC 时间
-- 创建表时指定 UTC 时区
CREATE TABLE events (
    id UInt64,
    event_time DateTime('UTC'),  -- 明确指定 UTC
    event_data String
) ENGINE = MergeTree()
ORDER BY event_time;

-- 查询时转换为本地时区
SELECT
    event_time AS utc_time,
    toTimezone(event_time, 'Asia/Shanghai') AS beijing_time,
    event_data
FROM events
LIMIT 10;
```

### 在查询中使用时区

```sql
-- 查询特定时区的时间范围
SELECT *
FROM events
WHERE toTimezone(event_time, 'Asia/Shanghai') 
    >= toDateTime('2024-01-20 00:00:00', 'Asia/Shanghai')
  AND toTimezone(event_time, 'Asia/Shanghai') 
    < toDateTime('2024-01-21 00:00:00', 'Asia/Shanghai');

-- 按本地时区分组
SELECT
    toStartOfDay(toTimezone(event_time, 'Asia/Shanghai')) AS beijing_day,
    count() AS event_count
FROM events
GROUP BY beijing_day
ORDER BY beijing_day;
```

## 📊 时区处理场景

### 场景 1: 全球用户系统

```sql
-- 存储用户时区
CREATE TABLE users (
    id UInt64,
    name String,
    timezone String,  -- 用户时区，如 'Asia/Shanghai'
    created_at DateTime('UTC')
) ENGINE = MergeTree()
ORDER BY id;

-- 插入用户
INSERT INTO users VALUES
    (1, '张三', 'Asia/Shanghai', now('UTC')),
    (2, '李四', 'America/New_York', now('UTC')),
    (3, '王五', 'Europe/London', now('UTC'));

-- 按用户时区显示
SELECT
    name,
    timezone,
    toTimezone(created_at, timezone) AS local_created_at
FROM users;
```

### 场景 2: 多时区事件

```sql
-- 记录事件和时区
CREATE TABLE global_events (
    id UInt64,
    event_time DateTime('UTC'),
    event_timezone String,
    description String
) ENGINE = MergeTree()
ORDER BY event_time;

-- 插入事件
INSERT INTO global_events VALUES
    (1, now('UTC'), 'Asia/Shanghai', '上海事件'),
    (2, now('UTC'), 'America/New_York', '纽约事件'),
    (3, now('UTC'), 'Europe/London', '伦敦事件');

-- 查询并转换为所有时区
SELECT
    event_time AS utc_time,
    toTimezone(event_time, 'Asia/Shanghai') AS shanghai_time,
    toTimezone(event_time, 'America/New_York') AS ny_time,
    toTimezone(event_time, 'Europe/London') AS london_time,
    description
FROM global_events;
```

### 场景 3: 跨时区报告

```sql
-- 按用户时区生成每日报告
SELECT
    user_id,
    user_timezone,
    toStartOfDay(toTimezone(event_time, user_timezone)) AS local_day,
    count() AS event_count
FROM user_events
CROSS JOIN (
    SELECT DISTINCT id AS user_id, timezone AS user_timezone
    FROM users
) AS tz_info
ON user_events.user_id = tz_info.user_id
WHERE event_time >= now('UTC') - INTERVAL 7 DAY
GROUP BY user_id, user_timezone, local_day
ORDER BY local_day;
```

### 场景 4: 夏令时处理

```sql
-- 夏令时地区的事件
CREATE TABLE dst_events (
    id UInt64,
    event_time DateTime('UTC'),
    location_timezone String,
    event_type String
) ENGINE = MergeTree()
ORDER BY event_time;

-- 插入数据
INSERT INTO dst_events VALUES
    (1, toDateTime('2024-03-10 12:00:00', 'UTC'), 'America/New_York', 'DST start'),
    (2, toDateTime('2024-11-03 12:00:00', 'UTC'), 'America/New_York', 'DST end');

-- 查询并显示 UTC 和本地时间
SELECT
    event_time AS utc_time,
    toTimezone(event_time, location_timezone) AS local_time,
    event_type
FROM dst_events;
```

### 场景 5: 时区感知的聚合

```sql
-- 按本地时区聚合
SELECT
    user_timezone,
    toStartOfDay(toTimezone(event_time, user_timezone)) AS local_day,
    count() AS daily_count
FROM user_events
WHERE event_time >= now('UTC') - INTERVAL 30 DAY
GROUP BY user_timezone, local_day
ORDER BY local_day;

-- 计算每个时区的活动小时
SELECT
    user_timezone,
    toHour(toTimezone(event_time, user_timezone)) AS local_hour,
    count() AS event_count
FROM user_events
WHERE event_time >= now('UTC') - INTERVAL 7 DAY
GROUP BY user_timezone, local_hour
ORDER BY user_timezone, local_hour;
```

## 🔧 时区配置

### 服务器时区配置

```xml
<!-- config.xml -->
<clickhouse>
    <!-- 设置服务器时区 -->
    <timezone>Asia/Shanghai</timezone>
</clickhouse>
```

### 表级时区

```sql
-- 创建表时指定时区
CREATE TABLE events_beijing (
    id UInt64,
    event_time DateTime('Asia/Shanghai'),  -- 北京时区
    event_data String
) ENGINE = MergeTree()
ORDER BY event_time;

-- 查询时自动使用表的时区
SELECT event_time FROM events_beijing;

-- 仍可转换为其他时区
SELECT
    event_time AS beijing_time,
    toTimezone(event_time, 'UTC') AS utc_time
FROM events_beijing;
```

### 查询级时区

```sql
-- 在查询中临时转换时区
SELECT
    event_time AS original_time,
    toTimezone(event_time, 'Asia/Shanghai') AS converted_time
FROM events
WHERE event_time >= toDateTime('2024-01-01', 'UTC');
```

## 📊 时区相关函数

### 获取时区信息

```sql
-- 获取当前时区偏移
SELECT
    timezone() AS current_timezone,
    toTimezone(now(), timezone()) - now() AS offset_seconds,
    (toTimezone(now(), timezone()) - now()) / 3600 AS offset_hours;

-- 获取时区名称
SELECT timezone() AS timezone_name;

-- 获取时区缩写
SELECT timezone() AS timezone,
       timezones['Asia/Shanghai'] AS timezone_info;
```

### 时区偏移计算

```sql
-- 计算时区偏移
SELECT
    'UTC' AS timezone,
    now() AS time;

SELECT
    'Asia/Shanghai' AS timezone,
    toTimezone(now(), 'Asia/Shanghai') AS time,
    toTimezone(now(), 'Asia/Shanghai') - now() AS offset_seconds;

SELECT
    'America/New_York' AS timezone,
    toTimezone(now(), 'America/New_York') AS time,
    toTimezone(now(), 'America/New_York') - now() AS offset_seconds;
```

## 💡 最佳实践

1. **存储 UTC 时间**：始终在数据库中存储 UTC 时间
2. **显示本地时间**：在查询时转换为用户的本地时区
3. **明确指定时区**：在创建表时明确指定时区
4. **处理夏令时**：使用标准时区名称（如 'America/New_York'）
5. **避免时区缩写**：不要使用 EST、PST 等缩写

## ⚠️ 常见陷阱

### 陷阱 1: 混淆存储和显示时区

```sql
-- ❌ 错误：直接存储本地时间
CREATE TABLE events (
    event_time DateTime  -- 使用服务器时区，可能是错误的
) ENGINE = MergeTree()
ORDER BY event_time;

-- ✅ 正确：存储 UTC 时间
CREATE TABLE events (
    event_time DateTime('UTC')  -- 明确指定 UTC
) ENGINE = MergeTree()
ORDER BY event_time;
```

### 陷阱 2: 忽略夏令时

```sql
-- ❌ 错误：使用固定偏移
SELECT 
    event_time,
    event_time + INTERVAL 8 HOUR AS beijing_time  -- 错误，没有考虑夏令时
FROM events;

-- ✅ 正确：使用时区转换
SELECT 
    event_time,
    toTimezone(event_time, 'Asia/Shanghai') AS beijing_time
FROM events;
```

### 陷阱 3: 时区不一致

```sql
-- ❌ 错误：不同表使用不同时区
CREATE TABLE events_utc (
    event_time DateTime('UTC')
) ENGINE = MergeTree()
ORDER BY event_time;

CREATE TABLE events_local (
    event_time DateTime  -- 服务器时区
) ENGINE = MergeTree()
ORDER BY event_time;

-- ✅ 正确：所有表使用统一时区（UTC）
CREATE TABLE events (
    event_time DateTime('UTC')
) ENGINE = MergeTree()
ORDER BY event_time;
```

## 📝 相关文档

- [01_date_time_types.md](./01_date_time_types.md) - 日期时间类型
- [02_date_time_functions.md](./02_date_time_functions.md) - 日期时间函数
- [06_date_formatting.md](./06_date_formatting.md) - 日期格式化
