/*
 * 11_materialized_views.sql — 物化视图入门
 *
 * 【本章解决什么问题】
 *   - 物化视图（Materialized View, MV）到底解决了什么？什么时候必须用 MV？
 *   - 为什么 MV 预聚合必须用 *State 函数而不是 sum/avg？
 *   - MV vs Projection 该选哪个？
 *   - 如何做多级聚合（日 → 月 → 年）不重复计算？
 *
 * 【原理】
 *   MV 是"INSERT 触发的自动 ETL"：源表 INSERT 时，CH 把新数据按 SELECT 逻辑
 *   转换后写入目标表（独立表）。MV 不存数据，数据在目标表。
 *
 *   关键：MV 的 SELECT 必须用聚合状态函数（sumState/avgState/quantileState），
 *   因为目标表可能被进一步聚合（日→月），状态可继续合并；普通函数（sum/avg）
 *   的结果无法安全二次聚合。
 *
 * 【运行环境】
 *   - 集群：treasurycluster（CH 25.12.1.649）
 *   - 数据库：getting_started_test
 */

-- ============================================================================
-- §0. 准备
-- ============================================================================
DROP DATABASE IF EXISTS getting_started_test;
CREATE DATABASE getting_started_test;
USE getting_started_test;

-- ============================================================================
-- §1. MV 基础：INSERT 触发的自动 ETL
-- ============================================================================
-- 【场景】原始事件表每秒数千行，但报表只需按天聚合
-- 【方案】建 MV，源表 INSERT 时自动写入按天聚合的目标表

-- 1.1 源表（明细）
CREATE TABLE events_raw
(
    event_time DateTime,
    user_id UInt64,
    amount Float64
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_time, user_id);

-- 1.2 目标表（按天预聚合，使用 SummingMergeTree）
CREATE TABLE events_daily_summing
(
    event_date Date,
    user_id UInt64,
    total_amount Float64,    -- SummingMergeTree 会自动累加同主键的数值列
    event_count UInt64
) ENGINE = SummingMergeTree()
PARTITION BY toYYYYMM(event_date)
ORDER BY (event_date, user_id);

-- 1.3 MV：从源表 INSERT 触发，转换并写入目标表
CREATE MATERIALIZED VIEW mv_events_daily_summing
TO events_daily_summing
AS
SELECT
    toDate(event_time) AS event_date,
    user_id,
    sum(amount) AS total_amount,
    count() AS event_count
FROM events_raw
GROUP BY event_date, user_id;

-- 1.4 测试：插入源表数据，目标表自动更新
INSERT INTO events_raw VALUES
    ('2024-01-01 10:00:00', 1, 100.0),
    ('2024-01-01 11:00:00', 1, 50.0),
    ('2024-01-01 12:00:00', 2, 200.0),
    ('2024-01-02 10:00:00', 1, 80.0);

-- 1.5 查询目标表（注意 SummingMergeTree 需要 GROUP BY 才能保证合并后正确）
SELECT
    event_date,
    user_id,
    sum(total_amount) AS total_amount,    -- 用 sum 防止未合并
    sum(event_count) AS event_count
FROM events_daily_summing
GROUP BY event_date, user_id
ORDER BY event_date, user_id;

-- 【对比】直接查源表 vs 查目标表
-- 源表：扫所有明细行
SELECT event_date, user_id, sum(amount), count()
FROM (SELECT toDate(event_time) AS event_date, user_id, amount FROM events_raw)
GROUP BY event_date, user_id
ORDER BY event_date, user_id;

-- 【坑】SummingMergeTree 的合并是异步的，查询时未必合并完成
-- 所以查询要用 sum() + GROUP BY，不能直接 SELECT *

-- ============================================================================
-- §2. 为什么必须用 *State 函数 —— 多级聚合场景
-- ============================================================================
-- 【场景】日报 → 月报 → 年报，多级聚合
-- 【问题】SummingMergeTree 只能 sum，不能 avg/quantile/uniq
-- 【方案】AggregatingMergeTree + *State 函数

-- 2.1 目标表（AggregatingMergeTree，存储聚合状态）
CREATE TABLE events_daily_agg
(
    event_date Date,
    user_id UInt64,
    amount_state AggregateFunction(sum, Float64),    -- sum 的状态
    avg_state AggregateFunction(avg, Float64),       -- avg 的状态
    uniq_users_state AggregateFunction(uniq, UInt64),-- uniq 的状态
    event_count_state AggregateFunction(count)       -- count 的状态
) ENGINE = AggregatingMergeTree()
PARTITION BY toYYYYMM(event_date)
ORDER BY (event_date, user_id);

-- 2.2 MV：用 *State 函数转换
CREATE MATERIALIZED VIEW mv_events_daily_agg
TO events_daily_agg
AS
SELECT
    toDate(event_time) AS event_date,
    user_id,
    sumState(amount) AS amount_state,        -- 存 sum 的状态
    avgState(amount) AS avg_state,           -- 存 avg 的状态
    uniqState(user_id) AS uniq_users_state,  -- 存 uniq 的状态
    countState() AS event_count_state        -- 存 count 的状态
FROM events_raw
GROUP BY event_date, user_id;

-- 2.3 查询时用 *Merge 还原
SELECT
    event_date,
    user_id,
    sumMerge(amount_state) AS total_amount,         -- 还原 sum
    avgMerge(avg_state) AS avg_amount,              -- 还原 avg
    uniqMerge(uniq_users_state) AS unique_users,    -- 还原 uniq
    countMerge(event_count_state) AS event_count    -- 还原 count
FROM events_daily_agg
GROUP BY event_date, user_id
ORDER BY event_date, user_id;

-- 2.4 月报：直接对日表做 *Merge（状态可继续合并！）
SELECT
    toStartOfMonth(event_date) AS month,
    sumMerge(amount_state) AS month_total,         -- 月总额
    avgMerge(avg_state) AS month_avg,              -- 月均值
    uniqMerge(uniq_users_state) AS month_unique_users,
    countMerge(event_count_state) AS month_events
FROM events_daily_agg
GROUP BY month
ORDER BY month;

-- 【原理】*State 函数返回的是"二进制聚合状态"，*Merge 可以把多个状态合并
--   sumState(100) + sumState(50) = sumState(150)  ✓ 可合并
--   avgState([100,1]) + avgState([50,1]) = avgState([100,50])  ✓ 可合并
--   直接存 sum=100 + sum=50 = 150  ✓ 但 avg=100 + avg=50 = ?  ✗ 不可合并！

-- 【对比】用 sum（错）vs sumState（对）
-- 错误：CREATE TABLE ... total_amount Float64 ENGINE=AggregatingMergeTree
--       MV: SELECT sum(amount) AS total_amount ... ← 月报时 sum(日 total) 会重复计算
-- 正确：CREATE TABLE ... amount_state AggregateFunction(sum, Float64)
--       MV: SELECT sumState(amount) AS amount_state ... ← 月报时 sumMerge(状态) 正确

-- ============================================================================
-- §3. 多级聚合链：明细 → 日 → 月 → 年
-- ============================================================================
-- 【场景】构建预聚合链，每层都从下层 MV 取数据

-- 3.1 月表
CREATE TABLE events_monthly_agg
(
    month Date,
    user_id UInt64,
    amount_state AggregateFunction(sum, Float64),
    event_count_state AggregateFunction(count)
) ENGINE = AggregatingMergeTree()
PARTITION BY toYYYY(month)
ORDER BY (month, user_id);

-- 3.2 MV：从日表触发（不是从源表！）
CREATE MATERIALIZED VIEW mv_events_monthly
TO events_monthly_agg
AS
SELECT
    toStartOfMonth(event_date) AS month,
    user_id,
    amount_state,                -- 直接传状态（已经是 *State 类型）
    event_count_state
FROM events_daily_agg
GROUP BY month, user_id;

-- 3.3 年报：从月表查询
SELECT
    toYear(month) AS year,
    sumMerge(amount_state) AS year_total,
    countMerge(event_count_state) AS year_events
FROM events_monthly_agg
GROUP BY year
ORDER BY year;

-- 【关键】聚合链的设计原则：
--   1. 每层用 AggregateFunction 类型存状态，不能用具体值
--   2. MV 的 SELECT 从下一层取数据（不是从源表）
--   3. 每层查询用 *Merge 还原
--   4. 注意：聚合链中 MV 只触发一次 INSERT（从最下层），不会级联触发
--      所以多级聚合通常需要 ETL 或 Refreshable MV

-- ============================================================================
-- §4. 实时统计：PV / UV / 留存
-- ============================================================================
-- 【场景】实时大屏：每秒更新 PV/UV，要求 100ms 响应

CREATE TABLE page_views
(
    event_time DateTime,
    user_id UInt64,
    page_id String
) ENGINE = MergeTree()
PARTITION BY toYYYYMMDD(event_time)
ORDER BY (event_time, user_id);

-- PV/UV 实时聚合表
CREATE TABLE page_views_realtime
(
    minute DateTime,    -- 精确到分钟
    page_id String,
    pv_state AggregateFunction(count),
    uv_state AggregateFunction(uniq, UInt64)
) ENGINE = AggregatingMergeTree()
PARTITION BY toYYYYMMDD(minute)
ORDER BY (minute, page_id);

CREATE MATERIALIZED VIEW mv_page_views_realtime
TO page_views_realtime
AS
SELECT
    toStartOfMinute(event_time) AS minute,
    page_id,
    countState() AS pv_state,
    uniqState(user_id) AS uv_state
FROM page_views
GROUP BY minute, page_id;

-- 测试
INSERT INTO page_views VALUES
    ('2024-01-01 10:00:00', 1, '/home'),
    ('2024-01-01 10:00:30', 2, '/home'),
    ('2024-01-01 10:00:45', 1, '/home'),    -- 同一用户多次访问
    ('2024-01-01 10:01:00', 3, '/home'),
    ('2024-01-01 10:00:00', 1, '/about');

-- 实时查询（< 100ms，因为只扫聚合表）
SELECT
    minute,
    page_id,
    countMerge(pv_state) AS pv,
    uniqMerge(uv_state) AS uv
FROM page_views_realtime
GROUP BY minute, page_id
ORDER BY minute, page_id;

-- 【对比】直接查源表 vs 查聚合表
-- 源表：随着数据增长越来越慢（亿级时秒级）
-- 聚合表：恒定快（只扫聚合后的少量行）

-- ============================================================================
-- §5. MV vs Projection 对比
-- ============================================================================
-- 【原理】Projection 是"附属于主表的备选排序 + 预聚合"，查询时优化器自动选

-- 5.1 创建带 Projection 的表
CREATE TABLE events_with_projection
(
    event_time DateTime,
    user_id UInt64,
    amount Float64,
    -- Projection：按 user_id 排序（与主表 ORDER BY 不同）
    PROJECTION p_by_user
    (
        SELECT user_id, sum(amount), count()
        GROUP BY user_id
    )
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_time, user_id);    -- 主表按时间排序

INSERT INTO events_with_projection
SELECT now() - INTERVAL number SECOND, number % 100, rand() % 1000
FROM numbers(10000);

-- 5.2 触发 projection 物化
ALTER TABLE events_with_projection MATERIALIZE PROJECTION p_by_user;

-- 5.3 查询：优化器自动选 projection
SET allow_experimental_projection_optimization = 1;
EXPLAIN PLAN
SELECT user_id, sum(amount), count()
FROM events_with_projection
GROUP BY user_id
LIMIT 5;

-- 【对比决策表】
-- | 维度          | MV                | Projection          |
-- |--------------|-------------------|---------------------|
-- | 存储位置      | 独立表             | 依附主表             |
-- | 触发时机      | INSERT 触发        | INSERT 同步写入      |
-- | 引擎可选      | 是（SummingMT 等） | 否（用主表引擎）     |
-- | 跨表查询      | 是（可 JOIN 多表） | 否（仅主表）         |
-- | 查询自动路由  | 否（需手动查 MV）  | 是（优化器自动选）   |
-- | 维护成本      | 中（独立 part 合并）| 低（随主表合并）     |
-- | 适用场景      | 多维预聚合、跨表   | 单表备选排序/聚合    |

-- 推荐：单表加速用 Projection；跨表预聚合/复杂转换用 MV

-- ============================================================================
-- §6. 清理
-- ============================================================================
DROP TABLE IF EXISTS events_with_projection;
DROP TABLE IF EXISTS page_views_realtime;
DROP TABLE IF EXISTS mv_page_views_realtime;
DROP TABLE IF EXISTS page_views;
DROP TABLE IF EXISTS events_monthly_agg;
DROP TABLE IF EXISTS mv_events_monthly;
DROP TABLE IF EXISTS events_daily_agg;
DROP TABLE IF EXISTS mv_events_daily_agg;
DROP TABLE IF EXISTS events_daily_summing;
DROP TABLE IF EXISTS mv_events_daily_summing;
DROP TABLE IF EXISTS events_raw;
DROP DATABASE IF EXISTS getting_started_test;

-- ============================================================================
-- §7. 自测题
-- ============================================================================
-- 1. MV 的数据存储在哪里？MV 本身存数据吗？
-- 2. 为什么 MV 预聚合必须用 sumState 而不是 sum？用 sum 会导致什么问题？
-- 3. AggregatingMergeTree 与 SummingMergeTree 的核心区别是什么？
-- 4. 多级聚合链（日→月→年）的设计原则有哪些？
-- 5. MV 和 Projection 该如何选择？给出 2 个各自的典型场景。
-- 6. *State 函数返回的二进制状态有什么特性？为什么能二次合并？
