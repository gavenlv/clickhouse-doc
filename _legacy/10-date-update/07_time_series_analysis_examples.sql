-- ================================================================================
-- ClickHouse 时间序列分析详解
-- ================================================================================
-- 
-- 集群: treasurycluster (2 副本)
-- 预计学习时间: 35 分钟
-- 
-- 本文件涵盖:
--   1. 时间序列表设计 - 按指标和时间排序
--   2. 多粒度聚合 - 分钟/小时/天级别聚合
--   3. 滚动窗口统计 - 移动平均、滚动标准差
--   4. 变化率计算 - 环比、同比分析
--   5. 异常检测 - 基于统计的异常检测
--   6. 降采样 - 高频数据转低频
--   7. 季节性分析 - 日/周模式识别
-- 
-- ================================================================================
-- 时间序列数据模型
-- ================================================================================
-- 
--   ┌─────────────────────────────────────────────────────────────────────────┐
--   │                      时间序列数据特点                                   │
--   └─────────────────────────────────────────────────────────────────────────┘
--   
--   ┌──────────────────────────────────────────────────────────────────────┐
--   │                         时间轴                                        │
--   │  ─────●────────●────────●────────●────────●────────●────────●────→  │
--   │       t1       t2       t3       t4       t5       t6       t7       │
--   │       v1       v2       v3       v4       v5       v6       v7       │
--   └──────────────────────────────────────────────────────────────────────┘
--   
--   特征:
--   1. 时间有序: 数据按时间顺序写入和查询
--   2. 高写入量: 每秒可能写入数百万数据点
--   3. 聚合查询: 大多是时间范围聚合查询
--   4. 压缩友好: 相邻数据点通常相似, 压缩率高
-- 
-- ================================================================================
-- 多粒度聚合原理
-- ================================================================================
-- 
--   ┌─────────────────────────────────────────────────────────────────────────┐
--   │                       时间粒度层级                                      │
--   └─────────────────────────────────────────────────────────────────────────┘
--   
--   原始数据 (秒级):
--   ─┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──→
--    │  │  │  │  │  │  │  │  │  │  │  │  │  │  │  │  │  │  │  │  │
--   
--   ↓ toStartOfMinute()
--   
--   分钟聚合:
--   ┌────────────┬────────────┬────────────┬────────────┬────────────┐
--   │  1分钟聚合 │  1分钟聚合 │  1分钟聚合 │  1分钟聚合 │  1分钟聚合 │
--   └────────────┴────────────┴────────────┴────────────┴────────────┘
--   
--   ↓ toStartOfHour()
--   
--   小时聚合:
--   ┌────────────────────────────────────┬────────────────────────────────────┐
--   │            1小时聚合               │            1小时聚合               │
--   └────────────────────────────────────┴────────────────────────────────────┘
--   
--   ↓ toDate()
--   
--   日聚合:
--   ┌─────────────────────────────────────────────────────────────────────────┐
--   │                            1天聚合                                      │
--   └─────────────────────────────────────────────────────────────────────────┘
--   
--   数据量: 秒级(86400) → 分钟(1440) → 小时(24) → 天(1)
-- 
-- ================================================================================
-- 滚动窗口计算原理
-- ================================================================================
-- 
--   ┌─────────────────────────────────────────────────────────────────────────┐
--   │                      滚动窗口 (Rolling Window)                          │
--   └─────────────────────────────────────────────────────────────────────────┘
--   
--   数据: v1   v2   v3   v4   v5   v6   v7   v8   v9   v10
--        ─┬────┬────┬────┬────┬────┬────┬────┬────┬────┬──→ 时间
--   
--   5分钟滚动平均:
--        ┌────┴────┴────┴────┴────┐
--        │   5分钟时间范围窗口    │
--        └────┴────┴────┴────┴────┘
--              ↓ 计算平均
--              avg(v1..v5)
--             ┌────┴────┴────┴────┴────┐
--             │   向前滑动 1 分钟      │
--             └────┴────┴────┴────┴────┘
--                   ↓ 计算平均
--                   avg(v2..v6)
--   
--   SQL 实现:
--   avg(value) OVER (
--       ORDER BY timestamp
--       RANGE BETWEEN INTERVAL 5 MINUTE PRECEDING AND CURRENT ROW
--   )
-- 
-- ================================================================================
-- 异常检测原理
-- ================================================================================
-- 
--   ┌─────────────────────────────────────────────────────────────────────────┐
--   │                    统计异常检测 (3σ 原则)                               │
--   └─────────────────────────────────────────────────────────────────────────┘
--   
--   数据分布:
--   
--              μ-3σ    μ-2σ    μ-1σ     μ      μ+1σ    μ+2σ    μ+3σ
--                │       │       │       │       │       │       │
--   ─────────────┼───────┼───────┼───────┼───────┼───────┼───────┼─────────→
--                │   99.7% 数据在此范围   │       │       │       │
--                │       │       │       │       │       │       │
--   正常: ████████████████████████████████████████████████
--   异常: ●                                                        ●
--         ↑                                                        ↑
--    低于 μ-3σ                                                高于 μ+3σ
--   
--   检测逻辑:
--   abs(value - avg_value) > 3 * stddev_value  → 异常
-- 
-- ================================================================================
-- 降采样原理
-- ================================================================================
-- 
--   ┌─────────────────────────────────────────────────────────────────────────┐
--   │                    降采样 (Downsampling)                                │
--   └─────────────────────────────────────────────────────────────────────────┘
--   
--   目的: 减少历史数据存储量, 提高查询性能
--   
--   原始数据 (1秒精度, 1天 = 86400 点):
--   ─●─●─●─●─●─●─●─●─●─●─●─●─●─●─●─●─●─●─●─●─●─●─●─●─●─●─●─●─●─●─●─→
--   
--   降采样到 1分钟 (1天 = 1440 点):
--   ┌───┐ ┌───┐ ┌───┐ ┌───┐ ┌───┐ ┌───┐ ┌───┐ ┌───┐
--   │avg│ │avg│ │avg│ │avg│ │avg│ │avg│ │avg│ │avg│ ...
--   └───┘ └───┘ └───┘ └───┘ └───┘ └───┘ └───┘ └───┘
--   
--   降采样到 1小时 (1天 = 24 点):
--   ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐
--   │   avg   │ │   avg   │ │   avg   │ │   avg   │ ...
--   └─────────┘ └─────────┘ └─────────┘ └─────────┘
--   
--   聚合策略:
--   - avg: 平均值
--   - min: 最小值
--   - max: 最大值
--   - sum: 总和
--   - count: 计数
-- 
-- ================================================================================
-- 季节性分析原理
-- ================================================================================
-- 
--   ┌─────────────────────────────────────────────────────────────────────────┐
--   │                       时间序列季节性                                    │
--   └─────────────────────────────────────────────────────────────────────────┘
--   
--   日季节性 (按小时):
--   ┌────────────────────────────────────────────────────────────────────────┐
--   │  0  2  4  6  8  10 12 14 16 18 20 22 24                               │
--   │  低 低 低 中 高 高 高 高 高 中 低 低                                    │
--   │  ▁  ▁  ▁  ▃  ▆  ▇  ▇  ▇  ▇  ▅  ▂  ▁                                   │
--   └────────────────────────────────────────────────────────────────────────┘
--   
--   周季节性 (按星期):
--   ┌────────────────────────────────────────────────────────────────────────┐
--   │  Mon  Tue  Wed  Thu  Fri  Sat  Sun                                    │
--   │  高   高   高   高   高   低   低                                      │
--   │  ▇    ▇    ▇    ▇    ▇    ▃    ▃                                      │
--   └────────────────────────────────────────────────────────────────────────┘
--   
--   应用:
--   - 容量规划: 根据季节性预测峰值
--   - 异常检测: 基于季节性的动态阈值
--   - 资源调度: 根据模式优化资源分配
-- 
-- ================================================================================

CREATE TABLE IF NOT EXISTS time_series (
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
