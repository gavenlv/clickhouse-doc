# 查询和进程

本文档介绍如何查询和管理 ClickHouse 的查询（Queries）和进程（Processes）。

## 🔍 system.processes

### 查看当前运行的查询

```sql
-- 查看所有正在运行的查询
SELECT
    query_id,
    user,
    query,
    elapsed,
    read_rows,
    read_bytes,
    total_rows_approx,
    memory_usage,
    thread_ids,
    profile_events,
    settings
FROM system.processes
ORDER BY elapsed DESC;
```

### 查看查询进度

```sql
-- 查看查询的详细进度
SELECT
    query_id,
    user,
    query,
    elapsed,
    elapsed / max_execution_time * 100 AS progress_percent,
    read_rows,
    read_bytes,
    written_rows,
    written_bytes,
    result_rows,
    result_bytes,
    memory_usage,
    thread_ids
FROM system.processes
WHERE elapsed > 0
ORDER BY elapsed DESC;
```

### 常用字段说明

| 字段 | 类型 | 说明 |
|------|------|------|
| `query_id` | String | 查询 ID |
| `user` | String | 用户名 |
| `query` | String | 查询语句 |
| `elapsed` | Float64 | 已执行时间（秒） |
| `read_rows` | UInt64 | 读取行数 |
| `read_bytes` | UInt64 | 读取字节数 |
| `memory_usage` | UInt64 | 内存使用量（字节） |
| `thread_ids` | Array(UInt64) | 线程 ID |
| `settings` | String | 查询设置 |

## 📊 system.query_log

### 查看最近的查询

```sql
-- 查看最近完成的查询
SELECT
    event_time,
    event_date,
    query_id,
    user,
    query,
    query_kind,
    type,
    elapsed,
    read_rows,
    read_bytes,
    result_rows,
    result_bytes,
    memory_usage
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today()
ORDER BY event_time DESC
LIMIT 100;
```

### 查看慢查询

```sql
-- 查看执行时间超过 10 秒的查询
SELECT
    event_time,
    user,
    query,
    elapsed,
    read_rows,
    read_bytes,
    result_rows,
    memory_usage
FROM system.query_log
WHERE type = 'QueryFinish'
  AND elapsed > 10
  AND event_date >= today()
ORDER BY elapsed DESC;
```

### 查询类型统计

```sql
-- 统计不同类型查询的数量
SELECT
    type,
    query_kind,
    count() AS query_count,
    avg(elapsed) AS avg_elapsed,
    max(elapsed) AS max_elapsed,
    sum(read_bytes) AS total_read_bytes,
    sum(result_bytes) AS total_result_bytes
FROM system.query_log
WHERE event_date >= today()
GROUP BY type, query_kind
ORDER BY query_count DESC;
```

## 📈 性能分析

### 查询性能排名

```sql
-- 查看最慢的查询
SELECT
    event_time,
    user,
    query,
    elapsed,
    read_rows,
    read_bytes,
    result_rows,
    memory_usage
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today()
  AND query NOT ILIKE '%system%'
ORDER BY elapsed DESC
LIMIT 20;
```

### 资源使用分析

```sql
-- 分析资源使用最多的查询
SELECT
    user,
    query,
    elapsed,
    read_bytes,
    result_bytes,
    memory_usage,
    read_bytes / elapsed AS read_bytes_per_sec
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today()
  AND query NOT ILIKE '%system%'
ORDER BY memory_usage DESC
LIMIT 20;
```

### 查看查询频率

```sql
-- 统计最常执行的查询
SELECT
    query,
    count() AS execution_count,
    avg(elapsed) AS avg_elapsed,
    sum(elapsed) AS total_elapsed
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today()
  AND query NOT ILIKE '%system%'
  AND length(query) > 10
GROUP BY query
HAVING count() > 5
ORDER BY execution_count DESC
LIMIT 20;
```

## 🎯 实战场景

### 场景 1: 查找长时间运行的查询

```sql
-- 查找运行时间超过阈值的查询
SELECT
    query_id,
    user,
    query,
    elapsed,
    read_rows,
    read_bytes,
    memory_usage,
    thread_ids,
    concat('KILL QUERY WHERE query_id = ''', query_id, ''';') AS kill_sql
FROM system.processes
WHERE elapsed > 300  -- 5 分钟
ORDER BY elapsed DESC;
```

### 场景 2: 终止查询

```sql
-- 终止特定查询（谨慎使用！）
KILL QUERY WHERE query_id = 'query_id_here';

-- 查看终止的查询
SELECT
    event_time,
    user,
    query,
    elapsed,
    exception_code,
    exception_text
FROM system.query_log
WHERE type = 'ExceptionWhileProcessing'
  AND event_date >= today()
  AND query_id = 'query_id_here';
```

### 场景 3: 分析查询失败

```sql
-- 查看失败的查询
SELECT
    event_time,
    user,
    query,
    exception_code,
    exception_text,
    elapsed,
    read_rows,
    memory_usage
FROM system.query_log
WHERE type IN ('ExceptionBeforeStart', 'ExceptionWhileProcessing')
  AND event_date >= today()
ORDER BY event_time DESC;
```

### 场景 4: 按用户分析查询

```sql
-- 分析用户的查询行为
SELECT
    user,
    count() AS total_queries,
    sumIf(1, elapsed > 10) AS slow_queries,
    avg(elapsed) AS avg_elapsed,
    max(elapsed) AS max_elapsed,
    sum(read_bytes) AS total_read_bytes,
    sum(memory_usage) AS total_memory_usage
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today()
  AND user != 'default'
GROUP BY user
ORDER BY total_queries DESC;
```

### 场景 5: 查找查询模式

```sql
-- 查找查询模式（使用正则表达式）
SELECT
    extractGroups(query, 'SELECT .* FROM ([^ ]+)')[1] AS table_accessed,
    count() AS access_count,
    avg(elapsed) AS avg_elapsed
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today()
  AND query ILIKE 'SELECT%'
  AND query_database != 'system'
GROUP BY table_accessed
ORDER BY access_count DESC
LIMIT 20;
```

## 🔄 线程分析

### system.query_thread_log

```sql
-- 查看查询线程日志
SELECT
    event_time,
    query_id,
    thread_id,
    thread_name,
    elapsed,
    cpu_time_ns,
    memory_usage,
    read_rows,
    read_bytes
FROM system.query_thread_log
WHERE event_date >= today()
ORDER BY event_time DESC
LIMIT 100;
```

### 查看线程分布

```sql
-- 分析查询的线程使用情况
SELECT
    query_id,
    thread_id,
    count() AS thread_count,
    avg(elapsed) AS avg_elapsed,
    max(cpu_time_ns) AS max_cpu_time
FROM system.query_thread_log
WHERE event_date >= today()
GROUP BY query_id, thread_id
ORDER BY thread_count DESC;
```

## 📊 仪表盘查询

### 实时查询监控

```sql
-- 实时查询监控仪表盘
SELECT
    'Running Queries' as metric,
    count() as value
FROM system.processes

UNION ALL

SELECT
    'Total Memory Usage (MB)',
    sum(memory_usage) / 1024 / 1024
FROM system.processes

UNION ALL

SELECT
    'Max Elapsed (seconds)',
    max(elapsed)
FROM system.processes

UNION ALL

SELECT
    'Total Read Rows',
    sum(read_rows)
FROM system.processes;
```

### 今日查询统计

```sql
-- 今日查询统计
SELECT
    'Total Queries' as metric,
    count() as value
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date = today()

UNION ALL

SELECT
    'Slow Queries (>10s)',
    count()
FROM system.query_log
WHERE type = 'QueryFinish'
  AND elapsed > 10
  AND event_date = today()

UNION ALL

SELECT
    'Failed Queries',
    count()
FROM system.query_log
WHERE type IN ('ExceptionBeforeStart', 'ExceptionWhileProcessing')
  AND event_date = today()

UNION ALL

SELECT
    'Avg Elapsed (seconds)',
    avg(elapsed)
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date = today();
```

### 资源使用趋势

```sql
-- 按小时统计资源使用
SELECT
    toHour(event_time) AS hour,
    count() AS query_count,
    avg(elapsed) AS avg_elapsed,
    sum(read_bytes) AS total_read_bytes,
    sum(memory_usage) AS total_memory_usage
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date = today()
GROUP BY hour
ORDER BY hour;
```

## 💡 最佳实践

1. **定期清理日志**：定期清理 `system.query_log` 以节省空间
2. **监控慢查询**：监控慢查询并及时优化
3. **资源限制**：为用户设置合理的资源限制
4. **终止长时间查询**：及时终止异常长时间运行的查询
5. **分析查询模式**：分析查询模式，优化表设计和索引

## 📝 相关文档

- [02_performance_issues.md](../07-troubleshooting/02_performance_issues.md) - 性能问题排查
- [06-admin/MONITORING_ALERTING_GUIDE.md](../06-admin/MONITORING_ALERTING_GUIDE.md) - 监控告警
- [00-infra/REALTIME_PERFORMANCE_GUIDE.md](../00-infra/REALTIME_PERFORMANCE_GUIDE.md) - 实时性能优化
