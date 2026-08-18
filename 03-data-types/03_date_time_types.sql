/*
 * 03_date_time_types.sql — 时间类型详解
 *
 * 【本章解决什么问题】
 *   - Date / DateTime / DateTime64 内部怎么存？为什么省空间？
 *   - 时区怎么处理？建表指定时区 vs 查询时转换？
 *   - DateTime64(N) 的 N 到底决定了什么精度？
 *   - 时间函数（toStartOfMonth、dateDiff、date_add）怎么用？
 *
 * 【使用场景】时间类型的选择 = 业务精度要求
 *   - 只需日期（报表分区、归档表）→ Date（2B 最省）
 *   - 秒级（电商订单、埋点事件、物联网采集）→ DateTime（4B）
 *   - 毫秒级（日志、APM 延迟分析、广告竞价）→ DateTime64(3)
 *   - 微秒级（金融交易排序、精确对账）→ DateTime64(6)
 *   同一张表可混用：业务发生时间 event_time 用 DateTime，
 *   数据写入时间 ingest_time 用 DateTime64(3)（毫秒定位写入批次）。
 *   注意：Date 分区粒度是"天"，日志按小时查必须用 DateTime 分区到小时。
 *
 * 【原理】
 *   时间类型本质是整数存储，函数是对整数的算术运算：
 *   - Date: UInt16（从 1970-01-01 的天数）
 *   - DateTime: UInt32（Unix 秒数）
 *   - DateTime64(N): Int64（10^-N 秒的 tick 数）
 *
 * 【运行环境】
 *   - 集群：treasurycluster（CH 25.12.1.649）
 *   - 数据库：data_type_test
 */

-- ============================================================================
-- §0. 准备
-- ============================================================================
DROP DATABASE IF EXISTS data_type_test;
CREATE DATABASE data_type_test;
USE data_type_test;

-- ============================================================================
-- §1. 时间类型内部表示
-- ============================================================================
-- 【原理】Date 只占 2 字节，存储从 1970-01-01 的天数（UInt16）
--         DateTime 占 4 字节，存储 Unix 秒数（UInt32）
--         DateTime64 占 8 字节，存储 tick 数（Int64）

CREATE TABLE time_internal
(
    event_time DateTime,
    event_date Date,
    event_precise DateTime64(3),  -- 毫秒精度
    -- 查看内部整数值
    time_int UInt32 MATERIALIZED toUnixTimestamp(event_time),
    date_int UInt16 MATERIALIZED toUInt16(event_date)
) ENGINE = MergeTree()
ORDER BY event_time;

INSERT INTO time_internal (event_time, event_date, event_precise) VALUES
    ('2024-01-15 10:30:45', '2024-01-15', '2024-01-15 10:30:45.123'),
    ('2024-06-15 23:59:59', '2024-06-15', '2024-06-15 23:59:59.999'),
    ('2025-01-01 00:00:00', '2025-01-01', '2025-01-01 00:00:00.000');

-- 查看内部存储值
SELECT
    event_time,
    time_int AS unix_seconds,         -- DateTime 内部值（UInt32）
    date_int AS days_since_epoch,     -- Date 内部值（UInt16）
    event_precise,
    toUnixTimestamp64Milli(event_precise) AS millis_since_epoch
FROM time_internal;

-- 【关键】Date 范围：1970 ~ 2149（UInt16 最大 65535 天 ≈ 179 年）
--         DateTime 范围：1970 ~ 2106（UInt32 最大 42 亿秒 ≈ 136 年）
--         DateTime64 范围：更广（Int64）

-- ============================================================================
-- §2. 时区处理
-- ============================================================================
-- 【原理】DateTime 存的是 UTC 秒，查询时按列时区或会话时区转换
-- 【场景】多时区业务：统一存 UTC，查询时按用户时区展示

-- 2.1 建表时指定时区
CREATE TABLE events_with_timezone
(
    event_time DateTime('Asia/Shanghai'),       -- 查询时默认转东八区
    event_utc DateTime('UTC'),                  -- 查询时默认 UTC
    event_date Date,
    description String
) ENGINE = MergeTree()
ORDER BY event_time;

INSERT INTO events_with_timezone VALUES
    ('2024-01-15 18:30:00', '2024-01-15 10:30:00', '2024-01-15', '上海时间 18:30 = UTC 10:30'),
    ('2024-06-15 08:00:00', '2024-06-15 00:00:00', '2024-06-15', '北京时间 08:00 = UTC 00:00');

-- 2.2 查看时区影响
SELECT
    event_time,           -- 显示为 Asia/Shanghai 时间
    event_utc,            -- 显示为 UTC 时间
    -- 实际上是同一个时间点
    toUnixTimestamp(event_time) AS ts_shanghai,
    toUnixTimestamp(event_utc) AS ts_utc,
    ts_shanghai = ts_utc AS same_instant  -- TRUE
FROM events_with_timezone;

-- 2.3 查询时转换时区
SELECT
    event_utc,
    -- 转上海时间
    toTimeZone(event_utc, 'Asia/Shanghai') AS shanghai_time,
    -- 转纽约时间
    toTimeZone(event_utc, 'America/New_York') AS new_york_time
FROM events_with_timezone;

-- 2.4 时区转换常见陷阱
-- 【坑】时区名称必须是 IANA 标准名：Asia/Shanghai 合法，Asia/Beijing 不存在
SELECT
    toTimeZone(now(), 'Asia/Shanghai') AS correct
FORMAT Vertical;

-- [坑] 不存在的时区名（如 Asia/Beijing）会抛 BAD_ARGUMENTS 异常
-- 演示环境 tzdata 无法加载该时区，故此处仅注释说明，不实际执行：
-- SELECT toTimeZone(now(), 'Asia/Beijing') AS wrong;  -- 会报错

-- ============================================================================
-- §3. DateTime64 精度实验
-- ============================================================================
-- 【原理】DateTime64(N) 的 N 是小数位数（3=毫秒，6=微秒，9=纳秒）

-- 3.1 不同精度对比
CREATE TABLE datetime64_demo
(
    id UInt8,
    dt_ms DateTime64(3),    -- 毫秒
    dt_us DateTime64(6),    -- 微秒
    dt_ns DateTime64(9)     -- 纳秒
) ENGINE = MergeTree()
ORDER BY id;

INSERT INTO datetime64_demo VALUES
    (1, '2024-01-15 10:30:45.123', '2024-01-15 10:30:45.123456', '2024-01-15 10:30:45.123456789'),
    (2, '2024-06-15 23:59:59.999', '2024-06-15 23:59:59.999999', '2024-06-15 23:59:59.999999999');

SELECT
    id,
    dt_ms,
    dt_us,
    dt_ns,
    toUnixTimestamp64Milli(dt_ms) AS epoch_ms,
    toUnixTimestamp64Micro(dt_us) AS epoch_us,
    toUnixTimestamp64Nano(dt_ns) AS epoch_ns
FROM datetime64_demo;

-- 3.2 存储大小对比
SELECT
    name,
    type,
    formatReadableSize(data_compressed_bytes) AS compressed,
    formatReadableSize(data_uncompressed_bytes) AS uncompressed
FROM system.columns
WHERE database = 'data_type_test'
  AND table = 'datetime64_demo'
ORDER BY position;

-- 【结果】DateTime64(3) / (6) / (9) 都占 8 字节（Int64）
--        精度越高，压缩率可能略低（值变化更随机）

-- ============================================================================
-- §4. 常用时间函数
-- ============================================================================

-- 4.1 时间截断（最常用，用于 GROUP BY 聚合）
SELECT
    toStartOfMonth(now()) AS month_start,
    toStartOfQuarter(now()) AS quarter_start,
    toStartOfYear(now()) AS year_start,
    toStartOfWeek(now()) AS week_start,
    toStartOfDay(now()) AS day_start,
    toStartOfHour(now()) AS hour_start,
    toStartOfMinute(now()) AS minute_start;

-- 4.2 时间提取
SELECT
    toYear(now()) AS year,
    toMonth(now()) AS month,
    toDayOfMonth(now()) AS day,
    toDayOfWeek(now()) AS day_of_week,    -- 1=周一
    toHour(now()) AS hour,
    toMinute(now()) AS minute,
    toSecond(now()) AS second;

-- 4.3 时间差计算
SELECT
    dateDiff('day', toDate('2024-01-01'), toDate('2024-12-31')) AS days_diff,
    dateDiff('month', toDate('2024-01-15'), toDate('2024-06-15')) AS months_diff,
    dateDiff('year', toDate('2020-01-01'), toDate('2024-01-01')) AS years_diff,
    dateDiff('hour', toDateTime('2024-01-01 00:00:00'), toDateTime('2024-01-02 00:00:00')) AS hours_diff;

-- 4.4 时间加减
SELECT
    now() AS current,
    date_add(now(), INTERVAL 1 DAY) AS tomorrow,
    date_sub(now(), INTERVAL 1 WEEK) AS last_week,
    date_add(now(), INTERVAL 3 MONTH) AS plus_3_months;

-- 4.5 时区感知函数
SELECT
    now() AS local_time,
    now('Asia/Shanghai') AS shanghai,
    now('UTC') AS utc,
    now('America/New_York') AS new_york;

-- ============================================================================
-- §5. 时间分区与聚合实战
-- ============================================================================
-- 【场景】日志表按时间分区，按不同粒度聚合

CREATE TABLE time_series_logs
(
    event_time DateTime,
    user_id UInt32,
    amount Float64,
    duration UInt32
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)       -- 按月分区
ORDER BY (event_time, user_id);

-- 插入测试数据（每个小时一条，持续 30 天）
INSERT INTO time_series_logs
SELECT
    toDateTime('2024-01-01 00:00:00') + INTERVAL number HOUR,
    number % 100,
    rand() % 1000,
    rand() % 3600
FROM numbers(720);  -- 30天 * 24小时

-- 5.1 按小时聚合
SELECT
    toStartOfHour(event_time) AS hour,
    count() AS events,
    sum(amount) AS total_amount,
    avg(duration) AS avg_duration
FROM time_series_logs
GROUP BY hour
ORDER BY hour
LIMIT 10;

-- 5.2 按天聚合
SELECT
    toDate(event_time) AS day,
    count() AS events,
    sum(amount) AS total_amount
FROM time_series_logs
GROUP BY day
ORDER BY day;

-- 5.3 按周聚合（使用 toStartOfWeek）
SELECT
    toStartOfWeek(event_time) AS week_start,
    count() AS events,
    sum(amount) AS total_amount
FROM time_series_logs
GROUP BY week_start
ORDER BY week_start;

-- 5.4 时间范围查询（分区剪枝）
SELECT
    count(),
    min(event_time),
    max(event_time)
FROM time_series_logs
WHERE event_time >= '2024-01-10'
  AND event_time < '2024-01-20';

-- 5.5 时间窗口滑动（最近 7 天 vs 前 7 天）
SELECT
    if(event_time >= now() - INTERVAL 7 DAY, 'recent', 'previous') AS period,
    count() AS events,
    sum(amount) AS total
FROM time_series_logs
WHERE event_time >= now() - INTERVAL 14 DAY
GROUP BY period;

-- ============================================================================
-- §6. Date 函数与格式化
-- ============================================================================

-- 6.1 dateName 格式化（替代 formatDateTime 的 %A/%B，CH 25.x 不支持）
SELECT
    dateName('year', toDate('2024-06-15')) AS year_str,
    dateName('month', toDate('2024-06-15')) AS month_str,
    dateName('weekday', toDate('2024-06-15')) AS weekday_str;  -- 周一~周日

-- 6.2 toDayOfWeek 与周模式
-- 【对比】toDayOfWeek 默认模式：1=周一, 7=周日
SELECT
    toDayOfWeek(toDate('2024-06-17')) AS monday,            -- 1
    toDayOfWeek(toDate('2024-06-23')) AS sunday;             -- 7

-- 6.3 季度分析
SELECT
    toQuarter(toDate('2024-03-31')) AS Q1,   -- 1
    toQuarter(toDate('2024-04-01')) AS Q2,   -- 2
    toQuarter(toDate('2024-10-01')) AS Q4;   -- 4

-- 6.4 是否闰年
-- 说明：isLeapYear 函数在 25.12 中不存在（Code 46），改用 toDayOfYear 判断：
-- 闰年 12 月 31 日是第 366 天，平年是第 365 天
SELECT
    toDayOfYear(toDate('2024-12-31')) AS days_2024,  -- 366 → 闰年
    toDayOfYear(toDate('2023-12-31')) AS days_2023;  -- 365 → 平年

-- 6.5 年龄计算
SELECT
    dateDiff('year', toDate('1990-05-15'), today()) AS age_years;

-- ============================================================================
-- §7. 时间类型选型决策树
-- ============================================================================
-- 字段是什么时间?
--   │
--   ├─ 只需日期（如出生日期、财报日期） → Date（2 字节）
--   │
--   ├─ 秒级时间戳（如日志时间、订单时间）
--   │   ├─ 范围 1970-2106 → DateTime（4 字节）
--   │   └─ 超出范围 → DateTime64（8 字节）
--   │
--   ├─ 亚秒精度
--   │   ├─ 毫秒 → DateTime64(3)（8 字节）
--   │   ├─ 微秒 → DateTime64(6)（8 字节）
--   │   └─ 纳秒 → DateTime64(9)（8 字节）
--   │
--   ├─ 时区需求
--   │   ├─ 存 UTC → 列类型 'UTC'，查询时 toTimeZone 转换
--   │   └─ 固定时区 → 列类型 'Asia/Shanghai'
--   │
--   └─ 分区键
--       ├─ 月粒度 → PARTITION BY toYYYYMM(time_col)
--       └─ 日粒度 → PARTITION BY toYYYYMMDD(time_col)

-- ============================================================================
-- §8. 清理
-- ============================================================================
DROP TABLE IF EXISTS time_internal;
DROP TABLE IF EXISTS events_with_timezone;
DROP TABLE IF EXISTS datetime64_demo;
DROP TABLE IF EXISTS time_series_logs;
DROP DATABASE IF EXISTS data_type_test;

-- ============================================================================
-- §9. 自测题
-- ============================================================================
-- 1. Date 内部用 UInt16 存储，最大能表示到哪一年？为什么？
-- 2. DateTime 和 DateTime64 的核心区别是什么？各自占多少字节？
-- 3. 建表时指定 DateTime('Asia/Shanghai') 和 DateTime('UTC')，存的是同一个时间点吗？
-- 4. toStartOfMonth 和 toStartOfQuarter 分别用于什么聚合场景？
-- 5. dateDiff('month', '2024-01-15', '2024-06-15') 的结果是多少？
-- 6. 分区键选 toYYYYMM 和 toYYYYMMDD 各有什么优缺点？