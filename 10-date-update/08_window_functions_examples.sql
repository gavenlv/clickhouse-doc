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
