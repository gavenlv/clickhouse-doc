-- ================================================================================
-- ClickHouse 窗口函数详解
-- ================================================================================
-- 
-- 集群: treasurycluster (2 副本)
-- 预计学习时间: 30 分钟
-- 
-- 本文件涵盖:
--   1. 窗口函数语法 - OVER(), PARTITION BY, ORDER BY
--   2. 聚合窗口函数 - avg(), sum(), count(), max(), min()
--   3. 排名窗口函数 - row_number(), rank(), dense_rank()
--   4. 偏移窗口函数 - lagInFrame(), leadInFrame()
--   5. ROWS vs RANGE - 行窗口 vs 值窗口
--   6. 实际应用场景 - 滚动平均、排名、会话分析
-- 
-- ================================================================================
-- 窗口函数核心概念
-- ================================================================================
-- 
--   ┌─────────────────────────────────────────────────────────────────────────┐
--   │                        窗口函数执行模型                                 │
--   └─────────────────────────────────────────────────────────────────────────┘
--   
--   原始数据集:
--   ┌─────┬─────┬───────┐
--   │ id  │ grp │ value │
--   ├─────┼─────┼───────┤
--   │  1  │  A  │  10   │
--   │  2  │  A  │  20   │
--   │  3  │  A  │  30   │
--   │  4  │  B  │  40   │
--   │  5  │  B  │  50   │
--   └─────┴─────┴───────┘
--   
--   PARTITION BY grp 后:
--   ┌─────────────────┐    ┌─────────────────┐
--   │   Partition A   │    │   Partition B   │
--   ├─────┬─────┬─────┤    ├─────┬─────┬─────┤
--   │ id  │ grp │value │    │ id  │ grp │value │
--   │  1  │  A  │  10  │    │  4  │  B  │  40  │
--   │  2  │  A  │  20  │    │  5  │  B  │  50  │
--   │  3  │  A  │  30  │    └─────┴─────┴─────┘
--   └─────┴─────┴─────┘
--   
--   窗口函数在每个分区内独立计算!
-- 
-- ================================================================================
-- ROWS vs RANGE 窗口
-- ================================================================================
-- 
--   ┌─────────────────────────────────────────────────────────────────────────┐
--   │                    窗口框架类型对比                                     │
--   └─────────────────────────────────────────────────────────────────────────┘
--   
--   ROWS: 基于物理行数
--   ┌─────────────────────────────────────────────────────────────────────────┐
--   │  Row 1  Row 2  Row 3  Row 4  Row 5  Row 6  Row 7  Row 8  Row 9  Row 10 │
--   │    │      │      │      │      │      │      │      │      │      │    │
--   │    └──────┴──────┴──────┴──────┴──────┘                                 │
--   │              ROWS BETWEEN 4 PRECEDING AND CURRENT ROW                  │
--   │              (固定 5 行窗口)                                             │
--   └─────────────────────────────────────────────────────────────────────────┘
--   
--   RANGE: 基于值范围
--   ┌─────────────────────────────────────────────────────────────────────────┐
--   │   t1    t2    t3    t4    t5    t6    t7    t8    t9    t10            │
--   │  10:00 10:01 10:02 10:03 10:04 10:05 10:06 10:07 10:08 10:09           │
--   │    │                            │                                      │
--   │    └────────────────────────────┘                                      │
--   │    RANGE BETWEEN INTERVAL 5 MINUTE PRECEDING AND CURRENT ROW           │
--   │    (时间范围窗口, 行数可变)                                             │
--   └─────────────────────────────────────────────────────────────────────────┘
--   
--   关键区别:
--   - ROWS: 窗口大小固定 (行数)
--   - RANGE: 窗口大小可变 (基于值)
-- 
-- ================================================================================
-- 滚动计算原理
-- ================================================================================
-- 
--   ┌─────────────────────────────────────────────────────────────────────────┐
--   │                       滚动平均计算                                      │
--   └─────────────────────────────────────────────────────────────────────────┘
--   
--   数据:  v1   v2   v3   v4   v5   v6   v7   v8   v9   v10
--         ─┬────┬────┬────┬────┬────┬────┬────┬────┬────┬──→
--   
--   3行滚动平均 (ROWS BETWEEN 2 PRECEDING AND CURRENT ROW):
--   
--   位置 1: ┌────┴────┐
--           │ v1  v2  │  avg = (v1+v2)/2 (边界处理)
--           └────┴────┘
--   
--   位置 2: ┌────┴────┴────┐
--           │ v1  v2  v3  │  avg = (v1+v2+v3)/3
--           └────┴────┴────┘
--   
--   位置 3:      ┌────┴────┴────┐
--                │ v2  v3  v4  │  avg = (v2+v3+v4)/3
--                └────┴────┴────┘
--   
--   位置 4:           ┌────┴────┴────┐
--                     │ v3  v4  v5  │  avg = (v3+v4+v5)/3
--                     └────┴────┴────┘
-- 
-- ================================================================================
-- LAG/LEAD 偏移函数
-- ================================================================================
-- 
--   ┌─────────────────────────────────────────────────────────────────────────┐
--   │                      LAG/LEAD 偏移访问                                  │
--   └─────────────────────────────────────────────────────────────────────────┘
--   
--   数据:  v1   v2   v3   v4   v5   v6   v7   v8   v9   v10
--         ─┬────┬────┬────┬────┬────┬────┬────┬────┬────┬──→
--          │    │    │    │    │    │    │    │    │    │
--          │    │    │    │    ▼    │    │    │    │    │
--          │    │    │    │   当前行 │    │    │    │    │
--          │    │    │    │    │    │    │    │    │    │
--   lagInFrame(value, 1) ←┘    │    │    │    │    │    │
--          │    │    │    │    │    │    │    │    │    │
--   lagInFrame(value, 2) ←─────┘    │    │    │    │    │
--          │    │    │    │    │    │    │    │    │    │
--   leadInFrame(value, 1) ──────────→┘    │    │    │
--          │    │    │    │    │    │    │    │    │    │
--   leadInFrame(value, 2) ───────────────→┘    │    │
--   
--   应用:
--   - 计算环比: (value - lagInFrame(value, 1)) / lagInFrame(value, 1)
--   - 检测变化: value != lagInFrame(value, 1)
--   - 填充缺失: if(value IS NULL, lagInFrame(value, 1), value)
-- 
-- ================================================================================
-- 排名函数对比
-- ================================================================================
-- 
--   ┌─────────────────────────────────────────────────────────────────────────┐
--   │                     排名函数区别                                        │
--   └─────────────────────────────────────────────────────────────────────────┘
--   
--   数据: score = [100, 100, 90, 80, 80, 70]
--   
--   row_number():   1, 2, 3, 4, 5, 6  (连续编号, 不考虑重复)
--   rank():         1, 1, 3, 4, 4, 6  (考虑重复, 跳过排名)
--   dense_rank():   1, 1, 2, 3, 3, 4  (考虑重复, 不跳过排名)
--   
--   使用场景:
--   - row_number: 唯一编号, 分页
--   - rank: 排行榜 (体育比赛)
--   - dense_rank: 分组排名 (考试成绩)
-- 
-- ================================================================================

SELECT
    column1,
    window_function(column2) OVER (
        PARTITION BY partition_column
        ORDER BY order_column
        [ROWS/RANGE BETWEEN ... AND ...]
    ) AS window_result
FROM table_name;

-- ========================================
-- 基本语法
-- ========================================

-- 简单滚动平均
SELECT
    event_time,
    value,
    avg(value) OVER (
        ORDER BY event_time
        ROWS BETWEEN 4 PRECEDING AND CURRENT ROW
    ) AS rolling_avg_5,
    avg(value) OVER (
        ORDER BY event_time
        ROWS BETWEEN 9 PRECEDING AND CURRENT ROW
    ) AS rolling_avg_10,
    avg(value) OVER (
        ORDER BY event_time
        ROWS BETWEEN 29 PRECEDING AND CURRENT ROW
    ) AS rolling_avg_30
FROM sensor_data
ORDER BY event_time
LIMIT 100;

-- ========================================
-- 基本语法
-- ========================================

-- 滚动求和
SELECT
    event_time,
    value,
    sum(value) OVER (
        ORDER BY event_time
        ROWS BETWEEN 9 PRECEDING AND CURRENT ROW
    ) AS rolling_sum_10,
    sum(value) OVER (
        ORDER BY event_time
        ROWS BETWEEN 59 PRECEDING AND CURRENT ROW
    ) AS rolling_sum_60
FROM sensor_data
ORDER BY event_time
LIMIT 100;

-- ========================================
-- 基本语法
-- ========================================

-- 时间范围窗口（秒）
SELECT
    event_time,
    value,
    avg(value) OVER (
        ORDER BY event_time
        RANGE BETWEEN INTERVAL 5 MINUTE PRECEDING AND CURRENT ROW
    ) AS rolling_avg_5m,
    avg(value) OVER (
        ORDER BY event_time
        RANGE BETWEEN INTERVAL 1 HOUR PRECEDING AND CURRENT ROW
    ) AS rolling_avg_1h,
    avg(value) OVER (
        ORDER BY event_time
        RANGE BETWEEN INTERVAL 24 HOUR PRECEDING AND CURRENT ROW
    ) AS rolling_avg_24h
FROM sensor_data
ORDER BY event_time
LIMIT 100;

-- ========================================
-- 基本语法
-- ========================================

-- LAG：访问前一行的值
SELECT
    event_time,
    value,
    lagInFrame(value, 1) OVER (ORDER BY event_time) AS prev_value,
    lagInFrame(value, 2) OVER (ORDER BY event_time) AS prev_value_2,
    lagInFrame(value, 10) OVER (ORDER BY event_time) AS prev_value_10,
    value - lagInFrame(value, 1) OVER (ORDER BY event_time) AS value_change
FROM sensor_data
ORDER BY event_time
LIMIT 100;

-- LEAD：访问后一行的值
SELECT
    event_time,
    value,
    leadInFrame(value, 1) OVER (ORDER BY event_time) AS next_value,
    leadInFrame(value, 5) OVER (ORDER BY event_time) AS next_value_5,
    leadInFrame(value, 1) OVER (ORDER BY event_time) - value AS future_change
FROM sensor_data
ORDER BY event_time
LIMIT 100;

-- ========================================
-- 基本语法
-- ========================================

-- 计算事件间隔
SELECT
    event_time,
    lagInFrame(event_time, 1) OVER (
        PARTITION BY user_id
        ORDER BY event_time
    ) AS prev_event_time,
    event_time - lagInFrame(event_time, 1) OVER (
        PARTITION BY user_id
        ORDER BY event_time
    ) AS time_since_prev_event
FROM user_events
ORDER BY user_id, event_time
LIMIT 100;

-- ========================================
-- 基本语法
-- ========================================

-- 行编号
SELECT
    user_id,
    score,
    row_number() OVER (
        PARTITION BY user_id
        ORDER BY score DESC
    ) AS row_num,
    rank() OVER (
        PARTITION BY user_id
        ORDER BY score DESC
    ) AS rank,
    dense_rank() OVER (
        PARTITION BY user_id
        ORDER BY score DESC
    ) AS dense_rank
FROM game_scores
ORDER BY user_id, score DESC
LIMIT 100;

-- ========================================
-- 基本语法
-- ========================================

-- 使用窗口函数计算分位数
SELECT
    toStartOfMinute(event_time) AS minute,
    metric_name,
    value,
    quantile(0.5)(value) OVER (
        PARTITION BY metric_name, minute
        ORDER BY value
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS rolling_median,
    quantile(0.95)(value) OVER (
        PARTITION BY metric_name, minute
        ORDER BY value
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS rolling_p95,
    quantile(0.99)(value) OVER (
        PARTITION BY metric_name, minute
        ORDER BY value
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS rolling_p99
FROM time_series
WHERE event_time >= toStartOfDay(now())
ORDER BY metric_name, event_time;

-- ========================================
-- 基本语法
-- ========================================

-- 年初至今（YTD）累计
SELECT
    event_time,
    amount,
    sum(amount) OVER (
        PARTITION BY toYear(event_time)
        ORDER BY event_time
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS ytd_amount
FROM sales
WHERE event_time >= toStartOfYear(now())
ORDER BY event_time;

-- ========================================
-- 基本语法
-- ========================================

-- 滚动最大值
SELECT
    event_time,
    value,
    max(value) OVER (
        ORDER BY event_time
        ROWS BETWEEN 59 PRECEDING AND CURRENT ROW
    ) AS rolling_max_60,
    min(value) OVER (
        ORDER BY event_time
        ROWS BETWEEN 59 PRECEDING AND CURRENT ROW
    ) AS rolling_min_60,
    max(value) - min(value) OVER (
        ORDER BY event_time
        ROWS BETWEEN 59 PRECEDING AND CURRENT ROW
    ) AS rolling_range_60
FROM sensor_data
ORDER BY event_time
LIMIT 100;

-- ========================================
-- 基本语法
-- ========================================

-- 识别用户会话（5 分钟内的事件）
SELECT
    user_id,
    event_time,
    lagInFrame(event_time, 1) OVER (
        PARTITION BY user_id
        ORDER BY event_time
    ) AS prev_event_time,
    event_time - lagInFrame(event_time, 1) OVER (
        PARTITION BY user_id
        ORDER BY event_time
    ) AS time_since_prev_event,
    CASE 
        WHEN lagInFrame(event_time, 1) OVER (
            PARTITION BY user_id
            ORDER BY event_time
        ) IS NULL OR 
             event_time - lagInFrame(event_time, 1) OVER (
                PARTITION BY user_id
                ORDER BY event_time
            ) > 300 THEN 1
        ELSE 0
    END AS is_new_session
FROM user_events
ORDER BY user_id, event_time
LIMIT 100;

-- ========================================
-- 基本语法
-- ========================================

-- 周环比
SELECT
    event_date,
    metric_name,
    value,
    lagInFrame(value, 7) OVER (
        PARTITION BY metric_name
        ORDER BY event_date
    ) AS value_7_days_ago,
    value - lagInFrame(value, 7) OVER (
        PARTITION BY metric_name
        ORDER BY event_date
    ) AS weekly_diff,
    (value - lagInFrame(value, 7) OVER (
        PARTITION BY metric_name
        ORDER BY event_date
    )) / NULLIF(lagInFrame(value, 7) OVER (
        PARTITION BY metric_name
        ORDER BY event_date
    ), 0) * 100 AS weekly_change_pct
FROM daily_metrics
WHERE event_date >= toStartOfDay(now() - INTERVAL 30 DAY)
ORDER BY metric_name, event_date;

-- ========================================
-- 基本语法
-- ========================================

-- 基于统计的异常检测
SELECT
    event_time,
    value,
    avg(value) OVER (
        ORDER BY event_time
        ROWS BETWEEN 19 PRECEDING AND CURRENT ROW
    ) AS rolling_avg_20,
    stddevSamp(value) OVER (
        ORDER BY event_time
        ROWS BETWEEN 19 PRECEDING AND CURRENT ROW
    ) AS rolling_stddev_20,
    CASE 
        WHEN abs(value - avg(value) OVER (
            ORDER BY event_time
            ROWS BETWEEN 19 PRECEDING AND CURRENT ROW
        )) > 3 * stddevSamp(value) OVER (
            ORDER BY event_time
            ROWS BETWEEN 19 PRECEDING AND CURRENT ROW
        ) THEN 'anomaly'
        ELSE 'normal'
    END AS status
FROM sensor_data
ORDER BY event_time
LIMIT 100;

-- ========================================
-- 基本语法
-- ========================================

-- 使用 FRAME 窗口函数
SELECT
    event_time,
    value,
    avg(value) OVER (
        ORDER BY event_time
        ROWS BETWEEN 4 PRECEDING AND CURRENT ROW
    ) AS avg_5_rows,
    avgInFrame(value) OVER (
        ORDER BY event_time
        ROWS BETWEEN 4 PRECEDING AND CURRENT ROW
    ) AS avg_in_frame_5,
    arrayAvg(arraySlice(
        groupArray(value) OVER (
            ORDER BY event_time
            ROWS BETWEEN 4 PRECEDING AND CURRENT ROW
        ), 1, 5
    )) AS manual_avg_5
FROM sensor_data
ORDER BY event_time
LIMIT 100;

-- ========================================
-- 基本语法
-- ========================================

-- 自定义窗口大小
SELECT
    event_time,
    value,
    avg(value) OVER (
        ORDER BY event_time
        ROWS BETWEEN 4 PRECEDING AND CURRENT ROW
    ) AS avg_5,
    avg(value) OVER (
        ORDER BY event_time
        ROWS BETWEEN 9 PRECEDING AND CURRENT ROW
    ) AS avg_10,
    avg(value) OVER (
        ORDER BY event_time
        ROWS BETWEEN 29 PRECEDING AND CURRENT ROW
    ) AS avg_30,
    avg(value) OVER (
        ORDER BY event_time
        ROWS BETWEEN 59 PRECEDING AND CURRENT ROW
    ) AS avg_60
FROM sensor_data
ORDER BY event_time
LIMIT 100;

-- ========================================
-- 基本语法
-- ========================================

-- 物化常用的窗口计算
CREATE MATERIALIZED VIEW rolling_metrics_mv
ENGINE = AggregatingMergeTree()
PARTITION BY toYYYYMM(window_time)
ORDER BY (metric_name, window_time)
AS SELECT
    toStartOfMinute(event_time) AS window_time,
    metric_name,
    avgState(value) AS avg_value_state,
    minState(value) AS min_value_state,
    maxState(value) AS max_value_state,
    countState() AS count_state
FROM time_series
GROUP BY window_time, metric_name;

-- 查询物化视图
SELECT
    window_time,
    metric_name,
    avgMerge(avg_value_state) AS avg_value,
    minMerge(min_value_state) AS min_value,
    maxMerge(max_value_state) AS max_value,
    countMerge(count_state) AS sample_count
FROM rolling_metrics_mv
WHERE window_time >= toStartOfDay(now() - INTERVAL 1 DAY)
ORDER BY metric_name, window_time;
