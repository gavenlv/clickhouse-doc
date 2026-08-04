# 查询监控和反模式

查询监控是 ClickHouse 监控的核心，需要识别和预防各种查询反模式，如全表扫描、低效 JOIN、错误使用索引等。

## 📊 查询性能监控

### 1. 慢查询监控

#### 基础慢查询检测

```sql
-- 查询最慢的查询（最近 1 小时）
SELECT
    query_id,
    user,
    query_duration_ms / 1000 AS duration_sec,
    read_rows,
    read_bytes,
    written_rows,
    written_bytes,
    memory_usage,
    substring(query, 1, 500) AS query
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_time >= now() - INTERVAL 1 HOUR
  AND query_duration_ms > 5000  -- 超过 5 秒
ORDER BY query_duration_ms DESC
LIMIT 20;

-- 慢查询统计（按用户）
SELECT
    user,
    count() AS slow_query_count,
    avg(query_duration_ms) / 1000 AS avg_duration_sec,
    max(query_duration_ms) / 1000 AS max_duration_sec,
    sum(query_duration_ms) / 60000 AS total_minutes
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today()
  AND query_duration_ms > 3000  -- 超过 3 秒
GROUP BY user
ORDER BY slow_query_count DESC;

-- 慢查询趋势（每小时）
SELECT
    toStartOfHour(event_time) AS hour,
    count() AS query_count,
    countIf(query_duration_ms > 5000) AS slow_query_count,
    countIf(query_duration_ms > 30000) AS very_slow_query_count,
    avg(query_duration_ms) / 1000 AS avg_duration_sec
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today() - INTERVAL 7 DAY
GROUP BY hour
ORDER BY hour;
```

#### 慢查询详细分析

```sql
-- 慢查询资源消耗分析
SELECT
    user,
    query_id,
    query_duration_ms / 1000 AS duration_sec,
    read_rows,
    formatReadableSize(read_bytes) AS read_bytes,
    written_rows,
    formatReadableSize(written_bytes) AS written_bytes,
    formatReadableSize(memory_usage) AS memory_usage,
    formatReadableSize(peaks.memory_usage) AS peak_memory_usage,
    substring(query, 1, 300) AS query
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today()
  AND query_duration_ms > 10000  -- 超过 10 秒
ORDER BY query_duration_ms DESC
LIMIT 10;

-- 慢查询特征分析
SELECT
    user,
    substring(query, 1, 100) AS query_pattern,
    count() AS slow_count,
    avg(query_duration_ms) / 1000 AS avg_duration_sec,
    avg(read_rows) AS avg_read_rows,
    avg(read_bytes) AS avg_read_bytes
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today()
  AND query_duration_ms > 5000
GROUP BY user, query_pattern
ORDER BY slow_count DESC
LIMIT 20;
```

### 2. 全表扫描检测

#### 全表扫描识别

```sql
-- 全表扫描查询
SELECT
    query_id,
    user,
    query_duration_ms,
    read_rows,
    result_rows,
    read_rows / greatest(result_rows, 1) AS read_ratio,
    substring(query, 1, 500) AS query
FROM system.query_log
WHERE type = 'QueryFinish'
  AND read_rows > 100000  -- 读取超过 10 万行
  AND result_rows < 1000  -- 返回少于 1000 行
  AND read_rows / result_rows > 100  -- 读取行数是返回行数的 100 倍
  AND event_date >= today()
ORDER BY read_ratio DESC
LIMIT 20;

-- 全表扫描频率统计
SELECT
    user,
    count() AS full_scan_count,
    sum(read_rows) AS total_read_rows,
    sum(read_bytes) AS total_read_bytes
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today()
  AND read_rows > 100000
  AND result_rows < 1000
  AND read_rows / result_rows > 100
GROUP BY user
ORDER BY full_scan_count DESC;

-- 高吞吐量全表扫描
SELECT
    query_id,
    user,
    read_rows,
    read_bytes,
    query_duration_ms,
    read_rows / (query_duration_ms / 1000) AS rows_per_second,
    substring(query, 1, 300) AS query
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today()
  AND read_rows > 1000000  -- 读取超过 100 万行
ORDER BY rows_per_second DESC
LIMIT 10;
```

### 3. 低效 JOIN 检测

#### JOIN 性能分析

```sql
-- 低效 JOIN 查询
SELECT
    query_id,
    user,
    query_duration_ms,
    read_rows,
    read_bytes,
    substring(query, 1, 500) AS query
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query ILIKE '%JOIN%'
  AND query_duration_ms > 3000  -- 超过 3 秒
  AND event_date >= today()
ORDER BY query_duration_ms DESC
LIMIT 20;

-- JOIN 查询统计（按类型）
SELECT
    CASE
        WHEN query ILIKE '%INNER JOIN%' THEN 'INNER JOIN'
        WHEN query ILIKE '%LEFT JOIN%' THEN 'LEFT JOIN'
        WHEN query ILIKE '%RIGHT JOIN%' THEN 'RIGHT JOIN'
        WHEN query ILIKE '%FULL JOIN%' THEN 'FULL JOIN'
        ELSE 'OTHER JOIN'
    END AS join_type,
    count() AS join_count,
    avg(query_duration_ms) / 1000 AS avg_duration_sec,
    sum(read_rows) AS total_read_rows
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today()
  AND query ILIKE '%JOIN%'
GROUP BY join_type
ORDER BY join_count DESC;

-- 大表 JOIN 检测
SELECT
    query_id,
    user,
    substring(query, 1, 300) AS query,
    query_duration_ms,
    read_rows,
    read_bytes
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query ILIKE '%JOIN%'
  AND read_rows > 1000000  -- 读取超过 100 万行
  AND event_date >= today()
ORDER BY read_rows DESC
LIMIT 10;
```

#### JOIN 反模式检测

```sql
-- 检测不使用分布式表的 JOIN
SELECT
    query_id,
    user,
    query_duration_ms,
    read_rows,
    substring(query, 1, 500) AS query
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query ILIKE '%JOIN%'
  AND query NOT ILIKE '%\_dist%'
  AND query_duration_ms > 3000
  AND event_date >= today()
ORDER BY query_duration_ms DESC
LIMIT 10;

-- 检测跨库 JOIN
SELECT
    query_id,
    user,
    query_duration_ms,
    substring(query, 1, 500) AS query
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query ILIKE '%JOIN%'
  AND query_duration_ms > 3000
  AND event_date >= today()
GROUP BY query_id, user, query_duration_ms, query
HAVING count(DISTINCT extractDatabases(query)) > 1
ORDER BY query_duration_ms DESC
LIMIT 10;
```

### 4. 错误查询检测

#### 失败查询统计

```sql
-- 失败查询统计（最近 24 小时）
SELECT
    exception_code,
    exception_text,
    count() AS error_count,
    any(substring(query, 1, 200)) AS example_query
FROM system.query_log
WHERE type = 'ExceptionWhileProcessing'
  AND event_date >= today()
GROUP BY exception_code, exception_text
ORDER BY error_count DESC
LIMIT 20;

-- 失败查询趋势
SELECT
    toStartOfHour(event_time) AS hour,
    count() AS error_count,
    countIf(exception_code = 0) AS timeout_count,
    countIf(exception_code != 0) AS other_error_count
FROM system.query_log
WHERE type = 'ExceptionWhileProcessing'
  AND event_date >= today() - INTERVAL 7 DAY
GROUP BY hour
ORDER BY hour;

-- 用户错误查询统计
SELECT
    user,
    exception_text,
    count() AS error_count
FROM system.query_log
WHERE type = 'ExceptionWhileProcessing'
  AND event_date >= today()
GROUP BY user, exception_text
ORDER BY error_count DESC
LIMIT 20;
```

#### 查询超时检测

```sql
-- 超时查询统计
SELECT
    user,
    count() AS timeout_count,
    max(query_duration_ms) / 1000 AS max_timeout_sec
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today()
  AND exception_code = 159  -- 超时错误码
GROUP BY user
ORDER BY timeout_count DESC;

-- 超时查询模式
SELECT
    user,
    substring(query, 1, 200) AS query_pattern,
    count() AS timeout_count
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today()
  AND exception_code = 159
GROUP BY user, query_pattern
ORDER BY timeout_count DESC
LIMIT 10;
```

## 🔍 反模式检测

### 1. Transaction 表 JOIN

**问题描述**: 对 Transaction 类型的表进行 JOIN 操作

#### 检测方法

```sql
-- 检测 Transaction 表 JOIN
SELECT
    query_id,
    user,
    query_duration_ms,
    read_rows,
    read_bytes,
    substring(query, 1, 500) AS query
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query ILIKE '%JOIN%'
  AND (
    query ILIKE '%transactions%'
    OR query ILIKE '%transaction%'
  )
  AND event_date >= today()
ORDER BY query_duration_ms DESC
LIMIT 10;

-- Transaction 表 JOIN 统计
SELECT
    user,
    count() AS transaction_join_count,
    avg(query_duration_ms) / 1000 AS avg_duration_sec,
    sum(read_rows) AS total_read_rows
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today()
  AND query ILIKE '%JOIN%'
  AND (
    query ILIKE '%transactions%'
    OR query ILIKE '%transaction%'
  )
GROUP BY user
ORDER BY transaction_join_count DESC;
```

#### 解决方案

```sql
-- ✅ 正确做法：使用子查询代替 JOIN
-- ❌ 错误做法
SELECT t1.*, t2.*
FROM transactions t1
JOIN events t2 ON t1.id = t2.transaction_id;

-- ✅ 正确做法：使用分布式表或物化视图
-- ❌ 错误做法
SELECT *
FROM transactions t1
LEFT JOIN transactions t2 ON t1.parent_id = t2.id;
```

### 2. 未使用索引

**问题描述**: 查询未使用排序键或数据跳数索引

#### 检测方法

```sql
-- 检测未使用排序键的 WHERE 条件
SELECT
    query_id,
    user,
    database,
    table,
    query_duration_ms,
    read_rows,
    result_rows,
    substring(query, 1, 500) AS query
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query ILIKE '%WHERE%'
  AND NOT query ILIKE '%PREWHERE%'
  AND read_rows > 10000
  AND result_rows < 1000
  AND event_date >= today()
ORDER BY read_rows DESC
LIMIT 20;

-- 检测全表扫描查询
SELECT
    query_id,
    user,
    read_rows,
    read_bytes,
    query_duration_ms,
    substring(query, 1, 300) AS query
FROM system.query_log
WHERE type = 'QueryFinish'
  AND read_rows > 1000000  -- 读取超过 100 万行
  AND query_duration_ms > 1000
  AND event_date >= today()
ORDER BY read_rows DESC
LIMIT 10;

-- 索引使用效率分析
SELECT
    database,
    table,
    sorting_key,
    partition_key,
    primary_key,
    total_rows,
    total_bytes
FROM system.tables
WHERE database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
  AND total_bytes > 1000000000  -- 大于 1GB
ORDER BY total_bytes DESC;
```

### 3. 高基数 DISTINCT

**问题描述**: 对高基数列执行 DISTINCT 操作

#### 检测方法

```sql
-- 高基数 DISTINCT 查询
SELECT
    query_id,
    user,
    query_duration_ms,
    read_rows,
    result_rows,
    substring(query, 1, 500) AS query
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query ILIKE '%DISTINCT%'
  AND query_duration_ms > 3000
  AND event_date >= today()
ORDER BY query_duration_ms DESC
LIMIT 20;

-- DISTINCT 查询统计
SELECT
    user,
    count() AS distinct_count,
    avg(query_duration_ms) / 1000 AS avg_duration_sec,
    avg(read_rows) AS avg_read_rows
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today()
  AND query ILIKE '%DISTINCT%'
  AND query_duration_ms > 1000
GROUP BY user
ORDER BY distinct_count DESC;
```

#### 解决方案

```sql
-- ✅ 正确做法：使用 groupBitmap 代替 COUNT(DISTINCT)
-- ❌ 错误做法
SELECT COUNT(DISTINCT user_id) AS unique_users
FROM events;

-- ✅ 正确做法
SELECT uniqExact(user_id) AS unique_users
FROM events;

-- ✅ 更好的做法：使用 groupBitmap
SELECT uniqHLL12(user_id) AS unique_users
FROM events;
```

### 4. 子查询优化

**问题描述**: 子查询性能低下

#### 检测方法

```sql
-- 低效子查询检测
SELECT
    query_id,
    user,
    query_duration_ms,
    substring(query, 1, 500) AS query
FROM system.query_log
WHERE type = 'QueryFinish'
  AND (query ILIKE '%SELECT% FROM (%'
       OR query ILIKE '%WHERE% (%SELECT%')
  AND query_duration_ms > 5000
  AND event_date >= today()
ORDER BY query_duration_ms DESC
LIMIT 20;

-- 嵌套子查询检测
SELECT
    query_id,
    user,
    query_duration_ms,
    length(query) AS query_length,
    substring(query, 1, 300) AS query
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query_duration_ms > 5000
  AND event_date >= today()
  AND (query LIKE '%SELECT%SELECT%SELECT%'
       OR query LIKE '%WHERE%WHERE%WHERE%')
ORDER BY query_duration_ms DESC
LIMIT 10;
```

### 5. ORDER BY 性能

**问题描述**: 大量数据排序

#### 检测方法

```sql
-- 高成本 ORDER BY 查询
SELECT
    query_id,
    user,
    query_duration_ms,
    read_rows,
    substring(query, 1, 500) AS query
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query ILIKE '%ORDER BY%'
  AND query_duration_ms > 3000
  AND event_date >= today()
ORDER BY query_duration_ms DESC
LIMIT 20;

-- ORDER BY 内存使用
SELECT
    query_id,
    user,
    query_duration_ms,
    memory_usage,
    formatReadableSize(memory_usage) AS readable_memory_usage,
    substring(query, 1, 300) AS query
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query ILIKE '%ORDER BY%'
  AND memory_usage > 104857600  -- 超过 100MB
  AND event_date >= today()
ORDER BY memory_usage DESC
LIMIT 10;
```

## 📊 查询性能视图

### 查询性能汇总视图

```sql
-- 创建查询性能汇总视图
CREATE VIEW monitoring.query_performance_summary AS
SELECT
    toStartOfHour(event_time) AS hour,
    count() AS total_queries,
    countIf(query_duration_ms < 100) AS very_fast_queries,
    countIf(query_duration_ms >= 100 AND query_duration_ms < 1000) AS fast_queries,
    countIf(query_duration_ms >= 1000 AND query_duration_ms < 5000) AS normal_queries,
    countIf(query_duration_ms >= 5000 AND query_duration_ms < 30000) AS slow_queries,
    countIf(query_duration_ms >= 30000) AS very_slow_queries,
    avg(query_duration_ms) / 1000 AS avg_duration_sec,
    max(query_duration_ms) / 1000 AS max_duration_sec,
    sum(read_bytes) AS total_read_bytes,
    sum(memory_usage) AS total_memory_usage
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today() - INTERVAL 7 DAY
GROUP BY hour;
```

### 反模式检测视图

```sql
-- 创建反模式检测视图
CREATE VIEW monitoring.query_anti_patterns AS
SELECT
    'Full table scan' AS pattern_type,
    count() AS count,
    avg(query_duration_ms) / 1000 AS avg_duration_sec
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today()
  AND read_rows > 100000
  AND result_rows < 1000
  AND read_rows / result_rows > 100

UNION ALL
SELECT
    'Inefficient JOIN' AS pattern_type,
    count() AS count,
    avg(query_duration_ms) / 1000 AS avg_duration_sec
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today()
  AND query ILIKE '%JOIN%'
  AND query_duration_ms > 5000

UNION ALL
SELECT
    'High memory usage' AS pattern_type,
    count() AS count,
    avg(query_duration_ms) / 1000 AS avg_duration_sec
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today()
  AND memory_usage > 1073741824

UNION ALL
SELECT
    'No PREWHERE' AS pattern_type,
    count() AS count,
    avg(query_duration_ms) / 1000 AS avg_duration_sec
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today()
  AND query ILIKE '%WHERE%'
  AND NOT query ILIKE '%PREWHERE%'
  AND read_rows > 10000;
```

## ⚠️ 重要注意事项

1. **查询分析开销**: 复杂的查询分析查询本身会消耗大量资源
2. **日志保留**: 查询日志会占用大量存储空间，需要合理设置保留时间
3. **实时性**: 查询日志有延迟，不是完全实时的
4. **隐私保护**: 查询日志可能包含敏感信息，需要脱敏处理
5. **性能影响**: 开启详细的查询日志会影响性能
6. **权限控制**: 查询日志应该有严格的访问控制
7. **数据清理**: 定期清理历史查询日志数据
8. **监控频率**: 不要过于频繁地查询 system.query_log

## 📚 相关文档

- [01_system_monitoring.md](./01_system_monitoring.md) - 系统监控
- [03_data_quality_monitoring.md](./03_data_quality_monitoring.md) - 数据质量监控
- [11-performance/](../11-performance/) - 性能优化
