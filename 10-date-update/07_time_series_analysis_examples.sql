-- ================================================
-- 07_time_series_analysis_examples.sql
-- 从 07_time_series_analysis.md 提取的 SQL 示例
-- 提取时间: 2026-01-23 14:40:17
-- ================================================


-- ========================================
-- 时间序列数据特征
-- ========================================

-- 创建时间序列表
CREATE TABLE time_series (
    timestamp DateTime,
    metric_name String,
    value Float64,
    tags Map(String, String)
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(timestamp)
ORDER BY (metric_name, timestamp);

-- ========================================
-- 时间序列数据特征
-- ========================================

-- 查询最近的数据
SELECT
    timestamp,
    metric_name,
    value
FROM time_series
WHERE timestamp >= now() - INTERVAL 24 HOUR
ORDER BY metric_name, timestamp
LIMIT 100;

-- ========================================
-- 时间序列数据特征
-- ========================================

-- 按不同时间粒度聚合
-- 按分钟聚合
SELECT
    toStartOfMinute(timestamp) AS minute,
    metric_name,
    avg(value) AS avg_value,
    min(value) AS min_value,
    max(value) AS max_value,
    sum(value) AS total_value
FROM time_series
WHERE timestamp >= now() - INTERVAL 24 HOUR
GROUP BY minute, metric_name
ORDER BY metric_name, minute;

-- 按小时聚合
SELECT
    toStartOfHour(timestamp) AS hour,
    metric_name,
    avg(value) AS avg_value,
    count() AS sample_count
FROM time_series
WHERE timestamp >= now() - INTERVAL 7 DAY
GROUP BY hour, metric_name
ORDER BY metric_name, hour;

-- 按天聚合
SELECT
    toDate(timestamp) AS day,
    metric_name,
    avg(value) AS avg_value,
    count() AS sample_count
FROM time_series
WHERE timestamp >= now() - INTERVAL 30 DAY
GROUP BY day, metric_name
ORDER BY metric_name, day;

-- ========================================
-- 时间序列数据特征
-- ========================================

-- 计算标准差
SELECT
    toStartOfHour(timestamp) AS hour,
    metric_name,
    avg(value) AS avg_value,
    stddevSamp(value) AS stddev_value,
    quantile(0.5)(value) AS median_value,
    quantile(0.95)(value) AS p95_value,
    quantile(0.99)(value) AS p99_value
FROM time_series
WHERE timestamp >= now() - INTERVAL 7 DAY
GROUP BY hour, metric_name
ORDER BY metric_name, hour;

-- 计算变化率
SELECT
    toStartOfHour(timestamp) AS hour,
    metric_name,
    avg(value) AS avg_value,
    avg(value) - lagInFrame(avg(value)) OVER (
        PARTITION BY metric_name
        ORDER BY hour
        ROWS BETWEEN 1 PRECEDING AND 1 PRECEDING
    ) AS value_change,
    (avg(value) - lagInFrame(avg(value)) OVER (
        PARTITION BY metric_name
        ORDER BY hour
        ROWS BETWEEN 1 PRECEDING AND 1 PRECEDING
    )) / NULLIF(lagInFrame(avg(value)) OVER (
        PARTITION BY metric_name
        ORDER BY hour
        ROWS BETWEEN 1 PRECEDING AND 1 PRECEDING
    ), 0) * 100 AS percent_change
FROM (
    SELECT
        toStartOfHour(timestamp) AS hour,
        metric_name,
        avg(value) AS value
    FROM time_series
    WHERE timestamp >= now() - INTERVAL 7 DAY
    GROUP BY hour, metric_name
)
ORDER BY metric_name, hour;

-- ========================================
-- 时间序列数据特征
-- ========================================

-- 滚动平均
SELECT
    timestamp,
    metric_name,
    value,
    avg(value) OVER (
        PARTITION BY metric_name
        ORDER BY timestamp
        ROWS BETWEEN 9 PRECEDING AND CURRENT ROW
    ) AS rolling_avg_10,
    avg(value) OVER (
        PARTITION BY metric_name
        ORDER BY timestamp
        ROWS BETWEEN 59 PRECEDING AND CURRENT ROW
    ) AS rolling_avg_60,
    avg(value) OVER (
        PARTITION BY metric_name
        ORDER BY timestamp
        ROWS BETWEEN 599 PRECEDING AND CURRENT ROW
    ) AS rolling_avg_600
FROM time_series
WHERE timestamp >= now() - INTERVAL 24 HOUR
  AND metric_name = 'cpu_usage'
ORDER BY timestamp
LIMIT 100;

-- ========================================
-- 时间序列数据特征
-- ========================================

-- 时间范围窗口（秒）
SELECT
    timestamp,
    metric_name,
    value,
    avg(value) OVER (
        PARTITION BY metric_name
        ORDER BY timestamp
        RANGE BETWEEN INTERVAL 5 MINUTE PRECEDING AND CURRENT ROW
    ) AS rolling_avg_5m,
    avg(value) OVER (
        PARTITION BY metric_name
        ORDER BY timestamp
        RANGE BETWEEN INTERVAL 1 HOUR PRECEDING AND CURRENT ROW
    ) AS rolling_avg_1h,
    avg(value) OVER (
        PARTITION BY metric_name
        ORDER BY timestamp
        RANGE BETWEEN INTERVAL 24 HOUR PRECEDING AND CURRENT ROW
    ) AS rolling_avg_24h
FROM time_series
WHERE timestamp >= now() - INTERVAL 7 DAY
  AND metric_name = 'cpu_usage'
ORDER BY timestamp
LIMIT 100;

-- ========================================
-- 时间序列数据特征
-- ========================================

-- 计算趋势（线性回归）
SELECT
    metric_name,
    avg(value) AS avg_value,
    min(value) AS min_value,
    max(value) AS max_value,
    -- 使用简单移动平均计算趋势
    avg(value) OVER (
        PARTITION BY metric_name
        ORDER BY timestamp
        ROWS BETWEEN 4 PRECEDING AND CURRENT ROW
    ) - avg(value) OVER (
        PARTITION BY metric_name
        ORDER BY timestamp
        ROWS BETWEEN 4 PRECEDING AND CURRENT ROW
        OFFSET 5
    ) AS trend_5points
FROM time_series
WHERE timestamp >= now() - INTERVAL 24 HOUR
ORDER BY metric_name, timestamp;

-- ========================================
-- 时间序列数据特征
-- ========================================

-- 使用统计方法检测异常
SELECT
    timestamp,
    metric_name,
    value,
    avg_value,
    stddev_value,
    abs(value - avg_value) AS deviation,
    CASE 
        WHEN abs(value - avg_value) > 3 * stddev_value THEN 'anomaly'
        ELSE 'normal'
    END AS status
FROM (
    SELECT
        timestamp,
        metric_name,
        value,
        avg(value) OVER (
            PARTITION BY metric_name
            ORDER BY timestamp
            RANGE BETWEEN INTERVAL 1 HOUR PRECEDING AND CURRENT ROW
        ) AS avg_value,
        stddevSamp(value) OVER (
            PARTITION BY metric_name
            ORDER BY timestamp
            RANGE BETWEEN INTERVAL 1 HOUR PRECEDING AND CURRENT ROW
        ) AS stddev_value
    FROM time_series
    WHERE timestamp >= now() - INTERVAL 24 HOUR
)
ORDER BY metric_name, timestamp;

-- ========================================
-- 时间序列数据特征
-- ========================================

-- 使用 arrayJoin 填充缺失的时间点
SELECT
    time_series.timestamp,
    time_series.metric_name,
    time_series.value,
    toStartOfMinute(timestamp) AS minute
FROM time_series
CROSS JOIN (
    SELECT
        toStartOfMinute(now() - INTERVAL toUInt32(number) MINUTE) AS minute
    FROM numbers(1440)  -- 24 小时 * 60 分钟
    WHERE toStartOfMinute(now() - INTERVAL toUInt32(number) MINUTE) >= 
          toStartOfMinute(now() - INTERVAL 24 HOUR)
) AS minute_series
ON minute_series.minute = toStartOfMinute(time_series.timestamp)
WHERE time_series.metric_name = 'cpu_usage'
ORDER BY minute_series.minute
LIMIT 1440;

-- ========================================
-- 时间序列数据特征
-- ========================================

-- 连接多个时间序列
SELECT
    t1.timestamp,
    t1.metric_name AS metric1,
    t1.value AS value1,
    t2.metric_name AS metric2,
    t2.value AS value2,
    value1 - value2 AS diff
FROM time_series t1
JOIN time_series t2 
    ON t1.timestamp = t2.timestamp
    AND t2.metric_name = 'memory_usage'
WHERE t1.metric_name = 'cpu_usage'
  AND t1.timestamp >= now() - INTERVAL 1 HOUR
ORDER BY t1.timestamp;

-- ========================================
-- 时间序列数据特征
-- ========================================

-- 降采样（减少数据点）
-- 按小时降采样（使用平均值）
CREATE MATERIALIZED VIEW time_series_hourly_mv
ENGINE = AggregatingMergeTree()
PARTITION BY toYYYYMM(hour_timestamp)
ORDER BY (metric_name, hour_timestamp)
AS SELECT
    toStartOfHour(timestamp) AS hour_timestamp,
    metric_name,
    avgState(value) AS avg_value_state,
    minState(value) AS min_value_state,
    maxState(value) AS max_value_state,
    countState() AS count_state
FROM time_series
GROUP BY hour_timestamp, metric_name;

-- 查询降采样数据
SELECT
    hour_timestamp,
    metric_name,
    avgMerge(avg_value_state) AS avg_value,
    minMerge(min_value_state) AS min_value,
    maxMerge(max_value_state) AS max_value,
    countMerge(count_state) AS sample_count
FROM time_series_hourly_mv
WHERE hour_timestamp >= now() - INTERVAL 30 DAY
ORDER BY metric_name, hour_timestamp;

-- ========================================
-- 时间序列数据特征
-- ========================================

-- 分析日季节性
SELECT
    toHour(timestamp) AS hour,
    avg(value) AS avg_value,
    count() AS sample_count
FROM time_series
WHERE timestamp >= now() - INTERVAL 30 DAY
GROUP BY hour
ORDER BY hour;

-- 分析周季节性
SELECT
    toDayOfWeek(timestamp) AS day_of_week,
    avg(value) AS avg_value,
    count() AS sample_count
FROM time_series
WHERE timestamp >= now() - INTERVAL 12 WEEK
GROUP BY day_of_week
ORDER BY day_of_week;

-- ========================================
-- 时间序列数据特征
-- ========================================

-- 简单的移动平均预测
SELECT
    timestamp,
    value,
    avg(value) OVER (
        PARTITION BY metric_name
        ORDER BY timestamp
        ROWS BETWEEN 9 PRECEDING AND CURRENT ROW
    ) AS ma_10,
    avg(value) OVER (
        PARTITION BY metric_name
        ORDER BY timestamp
        ROWS BETWEEN 29 PRECEDING AND CURRENT ROW
    ) AS ma_30
FROM time_series
WHERE timestamp >= now() - INTERVAL 7 DAY
  AND metric_name = 'cpu_usage'
ORDER BY timestamp
LIMIT 100;

-- ========================================
-- 时间序列数据特征
-- ========================================

-- 创建多粒度聚合物化视图

-- 1 分钟粒度
CREATE MATERIALIZED VIEW time_series_1m_mv
ENGINE = AggregatingMergeTree()
PARTITION BY toYYYYMM(minute_ts)
ORDER BY (metric_name, minute_ts)
AS SELECT
    toStartOfMinute(timestamp) AS minute_ts,
    metric_name,
    avgState(value) AS avg_value_state,
    minState(value) AS min_value_state,
    maxState(value) AS max_value_state
FROM time_series
GROUP BY minute_ts, metric_name;

-- 5 分钟粒度
CREATE MATERIALIZED VIEW time_series_5m_mv
ENGINE = AggregatingMergeTree()
PARTITION BY toYYYYMM(five_minute_ts)
ORDER BY (metric_name, five_minute_ts)
AS SELECT
    toStartOfFiveMinutes(timestamp) AS five_minute_ts,
    metric_name,
    avgState(value) AS avg_value_state,
    minState(value) AS min_value_state,
    maxState(value) AS max_value_state
FROM time_series
GROUP BY five_minute_ts, metric_name;

-- 1 小时粒度
CREATE MATERIALIZED VIEW time_series_1h_mv
ENGINE = AggregatingMergeTree()
PARTITION BY toYYYYMM(hour_ts)
ORDER BY (metric_name, hour_ts)
AS SELECT
    toStartOfHour(timestamp) AS hour_ts,
    metric_name,
    avgState(value) AS avg_value_state,
    minState(value) AS min_value_state,
    maxState(value) AS max_value_state
FROM time_series
GROUP BY hour_ts, metric_name;

-- ========================================
-- 时间序列数据特征
-- ========================================

-- ❌ 错误：不检查数据间隔
SELECT avg(value) FROM time_series
WHERE timestamp >= now() - INTERVAL 1 HOUR;

-- ✅ 正确：考虑数据间隔
SELECT 
    count() AS sample_count,
    max(timestamp) - min(timestamp) AS time_span_seconds,
    avg(value) AS avg_value
FROM time_series
WHERE timestamp >= now() - INTERVAL 1 HOUR;

-- ========================================
-- 时间序列数据特征
-- ========================================

-- ❌ 错误：不处理不对齐的时间点
SELECT t1.value - t2.value AS diff
FROM time_series t1
JOIN time_series t2 ON t1.timestamp = t2.timestamp;

-- ✅ 正确：使用时间范围窗口
SELECT 
    t1.timestamp,
    t1.value - t2.value AS diff
FROM time_series t1
ASOF LEFT JOIN time_series t2 
    ON t1.metric_name = t2.metric_name
    AND t2.timestamp >= t1.timestamp - INTERVAL 1 MINUTE
    AND t2.timestamp <= t1.timestamp + INTERVAL 1 MINUTE;
