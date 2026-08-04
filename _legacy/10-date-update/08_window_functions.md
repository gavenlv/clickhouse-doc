# 窗口函数和时间窗口

本文档介绍 ClickHouse 中的窗口函数及其在时间序列分析中的应用。

## 📋 窗口函数基础

### 基本语法

```sql
-- 窗口函数基本语法
SELECT
    column1,
    window_function(column2) OVER (
        PARTITION BY partition_column
        ORDER BY order_column
        [ROWS/RANGE BETWEEN ... AND ...]
    ) AS window_result
FROM table_name;
```

### 窗口函数分类

| 类别 | 函数 | 说明 |
|------|------|------|
| 聚合函数 | avg, sum, min, max, count | 窗口内聚合 |
| 排序函数 | row_number, rank, dense_rank | 窗口内排序 |
| 位移函数 | lag, lead | 访问前后行 |
| 偏移函数 | first_value, last_value | 窗口首尾值 |

## 🎯 聚合窗口函数

### 滚动平均

```sql
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
```

### 滚动求和

```sql
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
```

### 时间范围窗口

```sql
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
```

## 🎯 位移函数

### LAG 和 LEAD

```sql
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
```

### 计算时间间隔

```sql
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
```

## 🎯 排序函数

### 排名函数

```sql
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
```

### 分位数计算

```sql
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
```

## 🎯 应用场景

### 场景 1: 累计求和

```sql
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
```

### 场景 2: 移动最大值

```sql
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
```

### 场景 3: 会话分析

```sql
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
```

### 场景 4: 同比分析

```sql
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
```

### 场景 5: 异常检测

```sql
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
```

## 🎯 高级窗口函数

### 帧窗口

```sql
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
```

### 自定义窗口

```sql
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
```

## 💡 性能优化

### 使用物化视图

```sql
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
```

## ⚠️ 注意事项

1. **性能影响**：窗口函数可能消耗大量内存
2. **排序键**：确保 ORDER BY 字段在排序键中
3. **分区键**：合理使用 PARTITION BY 减少数据量
4. **窗口大小**：避免过大的窗口影响性能
5. **数据量**：大数据集上使用窗口函数时注意资源使用

## 💡 最佳实践

1. **合理分区**：按时间或维度分区提高性能
2. **限制窗口**：使用合理的窗口大小
3. **物化计算**：预计算常用的窗口函数结果
4. **索引优化**：确保 ORDER BY 和 PARTITION BY 字段在索引中
5. **监控性能**：监控窗口函数查询的执行时间和资源使用

## 📝 相关文档

- [07_time_series_analysis.md](./07_time_series_analysis.md) - 时间序列分析
- [05_time_range_queries.md](./05_time_range_queries.md) - 时间范围查询
- [09_date_performance.md](./09_date_performance.md) - 日期时间性能优化
