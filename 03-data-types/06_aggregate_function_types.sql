/*
 * 06_aggregate_function_types.sql — 聚合状态类型详解
 *
 * 【本章解决什么问题】
 *   - AggregateFunction(func, T) 到底是什么？存的是二进制状态？
 *   - SimpleAggregateFunction 和 AggregateFunction 有什么区别？
 *   - 什么时候用 AggregateFunction？什么时候用普通列？
 *   - *State/*Merge 函数和 AggregateFunction 类型的关系？
 *
 * 【原理】
 *   AggregateFunction(func, T) 存储的是"聚合函数的中间状态"，不是最终值。
 *   这个状态可以被合并（*Merge），所以多级聚合（日→月→年）不需要重新扫描原始数据。
 *
 *   SimpleAggregateFunction 是简化版，只支持"可交换 + 可结合"的聚合函数
 *   （如 sum, min, max, any, anyLast），不支持 avg, uniq, quantile 等复杂函数。
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
-- §1. AggregateFunction —— 聚合状态存储
-- ============================================================================
-- 【原理】AggregateFunction(sum, Float64) 存的是 sum 的中间状态，
--         不是最终的总和值。多个状态可以合并。

-- 1.1 创建使用 AggregateFunction 的表
CREATE TABLE daily_agg
(
    event_date Date,
    user_id UInt64,
    amount_state AggregateFunction(sum, Float64),        -- sum 的聚合状态
    avg_state AggregateFunction(avg, Float64),           -- avg 的聚合状态
    uniq_users_state AggregateFunction(uniq, UInt64),    -- uniq 的聚合状态
    count_state AggregateFunction(count)                 -- count 的聚合状态
) ENGINE = AggregatingMergeTree()
PARTITION BY toYYYYMM(event_date)
ORDER BY (event_date, user_id);

-- 1.2 写入聚合状态（必须用 *State 函数）
INSERT INTO daily_agg
SELECT
    toDate('2024-01-15') AS event_date,
    1 AS user_id,
    sumState(100.0) AS amount_state,       -- 单行的 sum 状态
    avgState(100.0) AS avg_state,          -- 单行的 avg 状态
    uniqState(1) AS uniq_users_state,      -- 单行的 uniq 状态
    countState() AS count_state            -- 单行的 count 状态
;

-- 也可以批量
INSERT INTO daily_agg
SELECT
    toDate('2024-01-15') AS event_date,
    user_id,
    sumState(amount) AS amount_state,
    avgState(amount) AS avg_state,
    uniqState(user_id) AS uniq_users_state,
    countState() AS count_state
FROM
(
    SELECT 1 AS user_id, 50.0 AS amount
    UNION ALL
    SELECT 1, 150.0
    UNION ALL
    SELECT 2, 200.0
)
GROUP BY user_id;

-- 1.3 查询聚合状态（必须用 *Merge 函数还原）
SELECT
    event_date,
    user_id,
    sumMerge(amount_state) AS total_amount,          -- 还原 sum
    avgMerge(avg_state) AS avg_amount,               -- 还原 avg
    uniqMerge(uniq_users_state) AS unique_users,     -- 还原 uniq
    countMerge(count_state) AS event_count           -- 还原 count
FROM daily_agg
GROUP BY event_date, user_id
ORDER BY event_date, user_id;

-- 1.4 多级聚合（日→月）
-- 【关键】状态可以继续合并，不需要重新扫描原始数据
SELECT
    toStartOfMonth(event_date) AS month,
    sumMerge(amount_state) AS month_total,
    uniqMerge(uniq_users_state) AS month_unique_users
FROM daily_agg
GROUP BY month
ORDER BY month;

-- ============================================================================
-- §2. SimpleAggregateFunction —— 简化版聚合状态
-- ============================================================================
-- 【原理】SimpleAggregateFunction 只支持"可交换+可结合"的聚合函数
--         不需要 *State/*Merge 函数，直接写聚合函数名
--         存储的是最终值，不是中间状态

-- 2.1 支持的函数列表
-- sum, min, max, any, anyLast, anyHeavy, first_value, last_value
-- 不支持：avg, uniq, quantile, groupArray 等

-- 2.2 创建 SimpleAggregateFunction 表
-- 【场景】实时统计，需要自动合并但不需复杂聚合（如 avg）
CREATE TABLE simple_daily_agg
(
    event_date Date,
    user_id UInt64,
    total_amount SimpleAggregateFunction(sum, Float64),  -- 直接存最终值
    min_amount SimpleAggregateFunction(min, Float64),
    max_amount SimpleAggregateFunction(max, Float64),
    event_count SimpleAggregateFunction(sum, UInt64)     -- 用 sum 模拟 count
) ENGINE = AggregatingMergeTree()
PARTITION BY toYYYYMM(event_date)
ORDER BY (event_date, user_id);

-- 2.3 写入（直接用普通聚合函数）
INSERT INTO simple_daily_agg
SELECT
    toDate('2024-01-15') AS event_date,
    1 AS user_id,
    sum(100.0) AS total_amount,     -- 普通 sum，不是 sumState
    min(100.0) AS min_amount,
    max(100.0) AS max_amount,
    count() AS event_count
FROM numbers(1);

-- 再插入更多数据
INSERT INTO simple_daily_agg
SELECT
    toDate('2024-01-15') AS event_date,
    user_id,
    sum(amount) AS total_amount,
    min(amount) AS min_amount,
    max(amount) AS max_amount,
    count() AS event_count
FROM
(
    SELECT 1 AS user_id, 50.0 AS amount
    UNION ALL
    SELECT 1, 150.0
    UNION ALL
    SELECT 2, 200.0
)
GROUP BY user_id;

-- 2.4 查询（直接用普通聚合函数）
SELECT
    event_date,
    user_id,
    sum(total_amount) AS total_amount,      -- 注意：SimpleAggregateFunction 也需要聚合
    min(min_amount) AS min_amount,
    max(max_amount) AS max_amount,
    sum(event_count) AS event_count
FROM simple_daily_agg
GROUP BY event_date, user_id
ORDER BY event_date, user_id;

-- ============================================================================
-- §3. AggregateFunction vs SimpleAggregateFunction 对比
-- ============================================================================
-- | 维度 | AggregateFunction | SimpleAggregateFunction |
-- |------|------------------|------------------------|
-- | 存储内容 | 二进制中间状态 | 最终值 |
-- | 写入函数 | 必须 *State（如 sumState） | 普通聚合（如 sum） |
-- | 查询函数 | 必须 *Merge（如 sumMerge） | 普通聚合（如 sum） |
-- | 支持 avg | ✅ | ❌ |
-- | 支持 uniq | ✅ | ❌ |
-- | 支持 quantile | ✅ | ❌ |
-- | 支持 sum/min/max | ✅ | ✅ |
-- | 存储空间 | 更大（存状态） | 更小（存最终值） |
-- | 多级聚合 | ✅ 状态可合并 | ⚠️ 需重新计算 |
-- | 适用场景 | 复杂聚合、多级聚合 | 简单聚合、实时统计 |

-- 推荐：简单场景用 SimpleAggregateFunction，复杂/多级聚合用 AggregateFunction

-- ============================================================================
-- §4. 实战：实时大屏聚合
-- ============================================================================
-- 【场景】实时大屏需要 PV/UV/平均耗时，要求毫秒级响应

-- 4.1 明细表
CREATE TABLE page_views_raw
(
    event_time DateTime,
    user_id UInt64,
    page_id String,
    duration_ms UInt32
) ENGINE = MergeTree()
PARTITION BY toYYYYMMDD(event_time)
ORDER BY (event_time, user_id);

-- 4.2 聚合表（使用 AggregateFunction 支持 UV 和 avg）
CREATE TABLE page_views_hourly_agg
(
    hour DateTime,
    page_id String,
    pv_state AggregateFunction(count),
    uv_state AggregateFunction(uniq, UInt64),
    duration_state AggregateFunction(avg, UInt32),
    max_duration SimpleAggregateFunction(max, UInt32)
) ENGINE = AggregatingMergeTree()
PARTITION BY toYYYYMMDD(hour)
ORDER BY (hour, page_id);

-- 4.3 物化视图：自动聚合
CREATE MATERIALIZED VIEW mv_page_views_hourly
TO page_views_hourly_agg
AS
SELECT
    toStartOfHour(event_time) AS hour,
    page_id,
    countState() AS pv_state,
    uniqState(user_id) AS uv_state,
    avgState(duration_ms) AS duration_state,
    max(duration_ms) AS max_duration
FROM page_views_raw
GROUP BY hour, page_id;

-- 4.4 插入测试数据
INSERT INTO page_views_raw VALUES
    ('2024-01-15 10:00:00', 1, '/home', 100),
    ('2024-01-15 10:05:00', 2, '/home', 150),
    ('2024-01-15 10:10:00', 1, '/product', 200),
    ('2024-01-15 10:15:00', 3, '/home', 80),
    ('2024-01-15 11:00:00', 1, '/home', 120);

-- 4.5 实时大屏查询（毫秒级）
SELECT
    hour,
    page_id,
    countMerge(pv_state) AS pv,
    uniqMerge(uv_state) AS uv,
    avgMerge(duration_state) AS avg_duration,
    max(max_duration) AS max_duration
FROM page_views_hourly_agg
GROUP BY hour, page_id
ORDER BY hour, page_id;

-- 4.6 对比：直接查明细表（随数据量增长变慢）
SELECT
    toStartOfHour(event_time) AS hour,
    page_id,
    count() AS pv,
    uniq(user_id) AS uv,
    avg(duration_ms) AS avg_duration,
    max(duration_ms) AS max_duration
FROM page_views_raw
GROUP BY hour, page_id
ORDER BY hour, page_id;

-- ============================================================================
-- §5. 清理
-- ============================================================================
DROP TABLE IF EXISTS daily_agg;
DROP TABLE IF EXISTS simple_daily_agg;
DROP TABLE IF EXISTS page_views_hourly_agg;
DROP TABLE IF EXISTS mv_page_views_hourly;
DROP TABLE IF EXISTS page_views_raw;
DROP DATABASE IF EXISTS data_type_test;

-- ============================================================================
-- §6. 自测题
-- ============================================================================
-- 1. AggregateFunction(sum, Float64) 存储的是什么？为什么不是最终值？
-- 2. SimpleAggregateFunction 和 AggregateFunction 的核心区别是什么？
-- 3. SimpleAggregateFunction 为什么不支持 avg 和 uniq？
-- 4. 多级聚合（日→月→年）为什么必须用 AggregateFunction？
-- 5. 实时大屏场景中，聚合表查询比直接查明细表快多少？为什么？