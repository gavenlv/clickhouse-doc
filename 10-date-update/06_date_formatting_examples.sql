-- ================================================================================
-- ClickHouse 日期格式化详解
-- ================================================================================
-- 
-- 集群: treasurycluster (2 副本)
-- 预计学习时间: 20 分钟
-- 
-- 本文件涵盖:
--   1. formatDateTime() - 日期时间格式化
--   2. 占位符详解 - %Y, %m, %d, %H, %M, %S 等
--   3. parseDateTime() - 字符串解析为日期
--   4. parseDateTimeBestEffort() - 智能解析
--   5. 自定义格式化函数 - 创建可复用函数
--   6. 多语言日期显示 - 中文、英文格式
-- 
-- ================================================================================
-- 日期格式化原理
-- ================================================================================
-- 
--   ┌─────────────────────────────────────────────────────────────────────────┐
--   │                    formatDateTime() 格式化流程                          │
--   └─────────────────────────────────────────────────────────────────────────┘
--   
--   输入: DateTime + 格式字符串
--         now(), '%Y-%m-%d %H:%M:%S'
--         │            │
--         ▼            ▼
--   ┌─────────────────────────────────────────────────────────────┐
--   │                      格式化引擎                              │
--   │  ┌─────────┐   ┌─────────┐   ┌─────────┐   ┌─────────┐    │
--   │  │  %Y     │ + │  %m     │ + │  %d     │ + │  %H...  │    │
--   │  │  2024   │   │  01     │   │  20     │   │  14...  │    │
--   │  └─────────┘   └─────────┘   └─────────┘   └─────────┘    │
--   └─────────────────────────────────────────────────────────────┘
--         │
--         ▼
--   输出: '2024-01-20 14:30:45'
-- 
-- ================================================================================
-- 格式占位符速查表
-- ================================================================================
-- 
--   ┌─────────────────────────────────────────────────────────────────────────┐
--   │                       formatDateTime 占位符                             │
--   └─────────────────────────────────────────────────────────────────────────┘
--   
--   年份:
--   %Y  → 4位年    2024
--   %y  → 2位年    24
--   
--   月份:
--   %m  → 2位月    01-12
--   %B  → 月全名   January
--   %b  → 月缩写   Jan
--   
--   日期:
--   %d  → 2位日    01-31
--   %j  → 年中第几天 001-366
--   
--   星期:
--   %A  → 周全名   Monday
--   %a  → 周缩写   Mon
--   %w  → 周几     0-6 (0=周一)
--   %W  → 周数     01-53
--   
--   时间:
--   %H  → 24小时   00-23
--   %I  → 12小时   01-12
--   %M  → 分钟     00-59
--   %S  → 秒       00-59
--   %p  → AM/PM    AM/PM
--   
--   时区:
--   %z  → 时区偏移 +0800
--   %:z → 时区偏移 +08:00
-- 
-- ================================================================================
-- 解析流程对比
-- ================================================================================
-- 
--   ┌─────────────────────────────────────────────────────────────────────────┐
--   │                    parseDateTime vs parseDateTimeBestEffort             │
--   └─────────────────────────────────────────────────────────────────────────┘
--   
--   parseDateTime('2024-01-20', '%Y-%m-%d'):
--   ┌─────────────┐     ┌─────────────┐     ┌─────────────┐
--   │ 输入字符串  │ ──→ │ 严格匹配    │ ──→ │ DateTime    │
--   │ 格式必须    │     │ 格式模板    │     │ 或 NULL     │
--   └─────────────┘     └─────────────┘     └─────────────┘
--   
--   parseDateTimeBestEffort('2024-01-20'):
--   ┌─────────────┐     ┌─────────────┐     ┌─────────────┐
--   │ 输入字符串  │ ──→ │ 智能识别    │ ──→ │ DateTime    │
--   │ 任意格式    │     │ 多种格式    │     │             │
--   └─────────────┘     └─────────────┘     └─────────────┘
--   
--   支持的格式:
--   '2024-01-20'              → 2024-01-20 00:00:00
--   '2024/01/20'              → 2024-01-20 00:00:00
--   '2024-01-20 14:30:45'     → 2024-01-20 14:30:45
--   '2024-01-20T14:30:45Z'    → 2024-01-20 14:30:45
--   '20 Jan 2024'             → 2024-01-20 00:00:00
--   '1705757696' (Unix时间戳) → 2024-01-20 14:34:56
-- 
-- ================================================================================
-- 常用格式模板
-- ================================================================================
-- 
--   ┌─────────────────────────────────────────────────────────────────────────┐
--   │                        常用格式模板                                     │
--   └─────────────────────────────────────────────────────────────────────────┘
--   
--   ISO 8601:
--   '%Y-%m-%dT%H:%M:%S'           → 2024-01-20T14:30:45
--   '%Y-%m-%dT%H:%M:%SZ'          → 2024-01-20T14:30:45Z
--   
--   中文格式:
--   '%Y年%m月%d日'                → 2024年01月20日
--   '%Y年%m月%d日 %H时%M分%S秒'   → 2024年01月20日 14时30分45秒
--   
--   美式格式:
--   '%B %d, %Y'                   → January 20, 2024
--   '%m/%d/%Y'                    → 01/20/2024
--   
--   欧式格式:
--   '%d/%m/%Y'                    → 20/01/2024
--   '%d %B %Y'                    → 20 January 2024
--   
--   日志格式:
--   '%Y-%m-%d %H:%M:%S'           → 2024-01-20 14:30:45
--   '%Y%m%d_%H%M%S'               → 20240120_143045
-- 
-- ================================================================================

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

-- ========================================
-- formatDateTime
-- ========================================

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

-- ========================================
-- formatDateTime
-- ========================================

-- ISO 8601 日期时间
SELECT
    formatDateTime(now(), '%Y-%m-%dT%H:%M:%S') AS iso_basic,
    formatDateTime(now(), '%Y-%m-%dT%H:%M:%SZ') AS iso_utc,
    formatDateTime(now(), '%Y-%m-%dT%H:%M:%S%:z') AS iso_timezone;

-- ========================================
-- formatDateTime
-- ========================================

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

-- ========================================
-- formatDateTime
-- ========================================

-- 24 小时制
SELECT
    formatDateTime(now(), '%H:%M') AS time_hm,
    formatDateTime(now(), '%H:%M:%S') AS time_hms,
    formatDateTime(now(), '%H:%M:%S.%f') AS time_hms_ms;

-- 12 小时制
SELECT
    formatDateTime(now(), '%I:%M %p') AS time12,
    formatDateTime(now(), '%I:%M:%S %p') AS time12_full;

-- ========================================
-- formatDateTime
-- ========================================

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

-- ========================================
-- formatDateTime
-- ========================================

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

-- ========================================
-- formatDateTime
-- ========================================

-- 生成日报表
SELECT
    formatDateTime(event_time, '%Y-%m-%d') AS report_date,
    event_type,
    count() AS event_count
FROM events
WHERE event_time >= toStartOfDay(now())
GROUP BY report_date, event_type
ORDER BY report_date, event_type;

-- ========================================
-- formatDateTime
-- ========================================

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

-- ========================================
-- formatDateTime
-- ========================================

-- 格式化 API 响应中的时间
SELECT
    id,
    name,
    formatDateTime(created_at, '%Y-%m-%dT%H:%M:%SZ') AS created_at_iso,
    formatDateTime(updated_at, '%Y-%m-%d %H:%M:%S') AS updated_at_local
FROM users
LIMIT 10;

-- ========================================
-- formatDateTime
-- ========================================

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

-- ========================================
-- formatDateTime
-- ========================================

-- 多语言日期显示
SELECT
    formatDateTime(now(), '%Y年%m月%d日') AS chinese,
    formatDateTime(now(), '%B %d, %Y') AS english,
    formatDateTime(now(), '%d/%m/%Y') AS french_style;

-- ========================================
-- formatDateTime
-- ========================================

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

-- ========================================
-- formatDateTime
-- ========================================

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

-- ========================================
-- formatDateTime
-- ========================================

-- ❌ 错误：格式不匹配
SELECT parseDateTime('2024/01/20', '%Y-%m-%d');  -- 失败

-- ✅ 正确：匹配格式
SELECT parseDateTime('2024/01/20', '%Y/%m/%d');  -- 成功

-- ========================================
-- formatDateTime
-- ========================================

-- ❌ 错误：不考虑时区
SELECT formatDateTime(now(), '%Y-%m-%d %H:%M:%S');
-- 使用服务器时区，可能不是期望的

-- ✅ 正确：转换时区后格式化
SELECT formatDateTime(toTimezone(now(), 'Asia/Shanghai'), '%Y-%m-%d %H:%M:%S');

-- ========================================
-- formatDateTime
-- ========================================

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
