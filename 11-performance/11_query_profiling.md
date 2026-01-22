# 查询分析和 Profiling

查询分析和 Profiling 是 ClickHouse 性能优化的关键工具，帮助识别查询瓶颈和优化机会。

## 查询分析工具

### 1. EXPLAIN

```sql
-- 查看查询计划
EXPLAIN PLAN
SELECT 
    user_id,
    count() as event_count
FROM events
WHERE event_time >= now() - INTERVAL 7 DAY
GROUP BY user_id;

-- 查看查询管道
EXPLAIN PIPELINE
SELECT 
    user_id,
    count() as event_count
FROM events
WHERE event_time >= now() - INTERVAL 7 DAY
GROUP BY user_id;

-- 查看查询预估
EXPLAIN ESTIMATE
SELECT 
    user_id,
    count() as event_count
FROM events
WHERE event_time >= now() - INTERVAL 7 DAY
GROUP BY user_id;
```

### 2. 查询日志

```sql
-- 查看查询日志
SELECT 
    query,
    query_duration_ms,
    read_rows,
    read_bytes,
    written_rows,
    written_bytes,
    memory_usage,
    exception_text
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_time >= now() - INTERVAL 1 HOUR
ORDER BY query_duration_ms DESC
LIMIT 20;
```

### 3. 查询 Profiling

```sql
-- 启用 Profiling
CLICKHOUSE_SETTINGS_PROFILE='profiling'

-- 查看性能统计
SELECT 
    ProfileEvents['NetworkReceiveBytes'] as bytes_received,
    ProfileEvents['NetworkSendBytes'] as bytes_sent,
    ProfileEvents['RealTimeMicroseconds'] as real_time_us,
    ProfileEvents['CPUTimeMicroseconds'] as cpu_time_us,
    ProfileEvents['MemoryTrackingPeak'] as peak_memory_bytes
FROM system.query_log
WHERE query_id = 'current_query_id';
```

## 性能分析指标

### 关键指标

| 指标 | 说明 | 优化目标 |
|------|------|---------|
| read_rows | 读取的行数 | 最小化 |
| read_bytes | 读取的字节数 | 最小化 |
| result_rows | 返回的行数 | 匹配需求 |
| query_duration_ms | 查询执行时间 | 最小化 |
| memory_usage | 内存使用量 | 控制在合理范围 |
| CPU time | CPU 使用时间 | 最小化 |

### 性能比率

```sql
-- 计算性能比率
SELECT 
    query,
    read_rows,
    result_rows,
    read_rows / result_rows as filter_ratio,
    read_bytes,
    result_bytes,
    read_bytes / result_bytes as bytes_filter_ratio,
    query_duration_ms,
    memory_usage
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_time >= now() - INTERVAL 24 HOUR
ORDER BY query_duration_ms DESC
LIMIT 20;
```

## 慢查询分析

### 识别慢查询

```sql
-- 查看慢查询
SELECT 
    query,
    query_duration_ms,
    read_rows,
    read_bytes,
    result_rows,
    memory_usage,
    formatReadableSize(read_bytes) as read_size,
    formatReadableSize(memory_usage) as memory_size
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query_duration_ms > 1000  -- 超过 1 秒
  AND event_time >= now() - INTERVAL 24 HOUR
ORDER BY query_duration_ms DESC
LIMIT 20;
```

### 分析慢查询原因

```sql
-- 分析慢查询的特征
SELECT 
    substring(query, 1, 100) as query_sample,
    count() as slow_query_count,
    avg(query_duration_ms) as avg_duration,
    max(query_duration_ms) as max_duration,
    avg(read_rows) as avg_rows_read,
    avg(memory_usage) as avg_memory
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query_duration_ms > 1000
  AND event_time >= now() - INTERVAL 24 HOUR
GROUP BY query_sample
ORDER BY avg_duration DESC
LIMIT 10;
```

## 查询优化建议

### 1. 减少读取数据量

```sql
-- 优化前
SELECT * FROM events
WHERE event_time >= now() - INTERVAL 30 DAY;

-- 优化后（使用 PREWHERE）
SELECT 
    event_id,
    user_id,
    event_type
FROM events
PREWHERE event_time >= now() - INTERVAL 30 DAY
WHERE user_id = 123;
```

### 2. 使用分区裁剪

```sql
-- 优化前
SELECT * FROM events
WHERE toDate(event_time) >= '2024-01-01';

-- 优化后
SELECT * FROM events
WHERE event_time >= '2024-01-01'
  AND event_time < '2024-02-01';
```

### 3. 使用索引

```sql
-- 优化前
SELECT * FROM events
WHERE event_type = 'click';

-- 优化后（使用跳数索引）
-- 首先创建索引
ALTER TABLE events
ADD INDEX idx_event_type event_type
TYPE set(2)
GRANULARITY 4;

-- 查询
SELECT * FROM events
WHERE event_type = 'click';
```

## 性能检查清单

- [ ] 是否分析查询计划？
  - [ ] 使用 EXPLAIN PLAN
  - [ ] 使用 EXPLAIN PIPELINE

- [ ] 是否查看查询日志？
  - [ ] 分析慢查询
  - [ ] 识别性能瓶颈

- [ ] 是否监控性能指标？
  - [ ] read_rows vs result_rows
  - [ ] query_duration_ms
  - [ ] memory_usage

- [ ] 是否优化查询？
  - [ ] 减少读取数据量
  - [ ] 使用分区裁剪
  - [ ] 使用索引

## 相关文档

- [01_query_optimization.md](./01_query_optimization.md) - 查询优化基础
- [02_primary_indexes.md](./02_primary_indexes.md) - 主键索引优化
- [04_skipping_indexes.md](./04_skipping_indexes.md) - 数据跳数索引
