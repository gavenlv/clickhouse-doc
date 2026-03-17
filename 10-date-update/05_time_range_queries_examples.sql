-- ================================================================================
-- ClickHouse 时间范围查询详解
-- ================================================================================
-- 
-- 集群: treasurycluster (2 副本)
-- 预计学习时间: 25 分钟
-- 
-- 本文件涵盖:
--   1. 简单范围查询 - 指定开始和结束时间
--   2. 相对时间查询 - 最近 N 天/小时/分钟
--   3. 周期时间查询 - 本周/本月/本季度/本年
--   4. 分区裁剪优化 - 利用时间分区加速查询
--   5. 时间分桶查询 - 按时间粒度分组
--   6. 物化视图优化 - 预聚合时间数据
-- 
-- ================================================================================
-- 时间范围查询原理
-- ================================================================================
-- 
--   ┌─────────────────────────────────────────────────────────────────────────┐
--   │                     时间范围查询类型                                    │
--   └─────────────────────────────────────────────────────────────────────────┘
--   
--   时间线: ─────────────────────────────────────────────────────→
--   
--   1. 固定范围查询:
--      ┌─────────────────────────────────┐
--      │        指定开始和结束           │
--      └─────────────────────────────────┘
--      WHERE event_time >= '2024-01-20 00:00:00'
--        AND event_time <  '2024-01-21 00:00:00'
--   
--   2. 相对时间查询:
--                              ┌─── 相对时间 ───┐
--      ────────────────────────┴────────────────┴───→
--                              now() - INTERVAL 7 DAY
--      WHERE event_time >= now() - INTERVAL 7 DAY
--   
--   3. 周期时间查询:
--      ┌───── 本周 ─────┐
--      └────────────────┘
--      WHERE event_time >= toStartOfWeek(now())
--        AND event_time <  toStartOfWeek(now()) + INTERVAL 7 DAY
-- 
-- ================================================================================
-- 分区裁剪优化原理
-- ================================================================================
-- 
--   ┌─────────────────────────────────────────────────────────────────────────┐
--   │                     分区裁剪 (Partition Pruning)                        │
--   └─────────────────────────────────────────────────────────────────────────┘
--   
--   表定义: PARTITION BY toYYYYMM(event_time)
--   
--   分区布局:
--   ┌─────────────┬─────────────┬─────────────┬─────────────┬─────────────┐
--   │  202401     │  202402     │  202403     │  202404     │  202405     │
--   │ (2024年1月) │ (2024年2月) │ (2024年3月) │ (2024年4月) │ (2024年5月) │
--   └─────────────┴─────────────┴─────────────┴─────────────┴─────────────┘
--         ▲                          ▲
--         │      查询范围:           │
--         │  2024-01-01 ~ 2024-03-31│
--         └──────────────────────────┘
--   
--   只扫描 3 个分区, 跳过 202404 和 202405!
--   
--   查询条件:
--   WHERE event_time >= '2024-01-01'
--     AND event_time <  '2024-04-01'
--   
--   性能提升: 如果表有 24 个分区(2年数据), 只扫描 3/24 = 12.5% 数据
-- 
-- ================================================================================
-- 时间分桶查询原理
-- ================================================================================
-- 
--   ┌─────────────────────────────────────────────────────────────────────────┐
--   │                        时间分桶 (Time Bucketing)                        │
--   └─────────────────────────────────────────────────────────────────────────┘
--   
--   原始数据: 每秒多条记录
--   ─┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──→ 时间
--    │  │  │  │  │  │  │  │  │  │  │  │  │  │  │  │  │  │  │  │  │
--   
--   分桶到小时:
--   ┌────────────────────────────────────┐
--   │           Hour 1 (聚合)            │
--   └────────────────────────────────────┘
--   ┌────────────────────────────────────┐
--   │           Hour 2 (聚合)            │
--   └────────────────────────────────────┘
--   ┌────────────────────────────────────┐
--   │           Hour 3 (聚合)            │
--   └────────────────────────────────────┘
--   
--   SQL:
--   SELECT toStartOfHour(event_time) AS hour,
--          count() AS cnt,
--          avg(value) AS avg_value
--   FROM events
--   GROUP BY hour
-- 
-- ================================================================================
-- 物化视图预聚合原理
-- ================================================================================
-- 
--   ┌─────────────────────────────────────────────────────────────────────────┐
--   │                      物化视图数据流                                     │
--   └─────────────────────────────────────────────────────────────────────────┘
--   
--   写入流程:
--   ┌─────────────┐     ┌─────────────┐     ┌─────────────┐
--   │ INSERT 原始 │ ──→ │ 自动触发    │ ──→ │ 写入物化视图│
--   │ 数据        │     │ 物化视图    │     │ (聚合后)    │
--   └─────────────┘     └─────────────┘     └─────────────┘
--   
--   查询优化:
--   ┌───────────────────────────────────────────────────────────────────┐
--   │                      原始表查询                                    │
--   │  扫描 10亿行 → 聚合 → 返回结果 (耗时: 30秒)                        │
--   └───────────────────────────────────────────────────────────────────┘
--                          ↓ 改用物化视图
--   ┌───────────────────────────────────────────────────────────────────┐
--   │                      物化视图查询                                  │
--   │  扫描 100万行 → 返回结果 (耗时: 0.5秒)                             │
--   └───────────────────────────────────────────────────────────────────┘
--   
--   性能提升: 60倍!
-- 
-- ================================================================================

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

-- ========================================
-- 简单范围查询
-- ========================================

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

-- ========================================
-- 简单范围查询
-- ========================================

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

-- ========================================
-- 简单范围查询
-- ========================================

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

-- ========================================
-- 简单范围查询
-- ========================================

-- 假设表按月分区
-- PARTITION BY toYYYYMM(event_time)

-- 查询会自动使用分区裁剪
SELECT * FROM events
WHERE event_time >= '2024-01-01'
  AND event_time < '2024-02-01';

-- 只扫描 2024-01 分区

-- ========================================
-- 简单范围查询
-- ========================================

-- 好的分区键设计
CREATE TABLE IF NOT EXISTS events (
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

-- ========================================
-- 简单范围查询
-- ========================================

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

-- ========================================
-- 简单范围查询
-- ========================================

-- 按小时聚合
SELECT
    toStartOfHour(event_time) AS hour,
    count() AS event_count,
    avg(value) AS avg_value
FROM events
WHERE event_time >= toStartOfDay(now())
GROUP BY hour
ORDER BY hour;

-- ========================================
-- 简单范围查询
-- ========================================

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

-- ========================================
-- 简单范围查询
-- ========================================

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

-- ========================================
-- 简单范围查询
-- ========================================

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

-- ========================================
-- 简单范围查询
-- ========================================

-- 创建表时物化日期列
CREATE TABLE IF NOT EXISTS events_optimized (
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

-- ========================================
-- 简单范围查询
-- ========================================

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

-- ========================================
-- 简单范围查询
-- ========================================

-- 查询多个不连续的时间范围
SELECT * FROM events
WHERE event_time IN (
    (SELECT toDateTime('2024-01-01 00:00:00') WHERE 1),
    (SELECT toDateTime('2024-01-15 00:00:00') WHERE 1),
    (SELECT toDateTime('2024-02-01 00:00:00') WHERE 1)
);

-- ========================================
-- 简单范围查询
-- ========================================

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

-- ========================================
-- 简单范围查询
-- ========================================

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

-- ========================================
-- 简单范围查询
-- ========================================

-- ❌ 错误：不使用时间函数，可能不准确
SELECT * FROM events
WHERE event_time >= '2024-01-01'
  AND event_time < '2024-01-02';

-- ✅ 正确：使用 toStartOfDay
SELECT * FROM events
WHERE event_time >= toStartOfDay(toDateTime('2024-01-01'))
  AND event_time < toStartOfDay(toDateTime('2024-01-02'));

-- ========================================
-- 简单范围查询
-- ========================================

-- ❌ 错误：格式不匹配
SELECT * FROM events
WHERE event_time >= '01/20/2024';

-- ✅ 正确：使用标准格式
SELECT * FROM events
WHERE event_time >= '2024-01-20';

-- ========================================
-- 简单范围查询
-- ========================================

-- ❌ 错误：不考虑时区
SELECT * FROM events
WHERE event_time >= '2024-01-20 00:00:00';

-- ✅ 正确：显式指定时区
SELECT * FROM events
WHERE event_time >= toDateTime('2024-01-20 00:00:00', 'UTC');
