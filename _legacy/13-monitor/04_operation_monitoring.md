# 操作监控

操作监控关注 ClickHouse 的各种操作，如 ALTER、MUTATION、DELETE、INSERT 等，帮助识别频繁操作和潜在问题。

## 📊 ALTER 操作监控

### 1. 频繁 ALTER 检测

#### ALTER 操作统计

```sql
-- ALTER 操作统计（最近 24 小时）
SELECT
    user,
    database,
    count() AS alter_count,
    sum(query_duration_ms) / 1000 AS total_duration_sec,
    avg(query_duration_ms) / 1000 AS avg_duration_sec,
    max(query_duration_ms) / 1000 AS max_duration_sec
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today()
  AND query ILIKE 'ALTER%'
GROUP BY user, database
HAVING alter_count > 5  -- 超过 5 次
ORDER BY alter_count DESC;

-- ALTER 操作趋势（最近 7 天）
SELECT
    toDate(event_time) AS date,
    count() AS alter_count,
    sum(query_duration_ms) / 1000 AS total_duration_sec,
    avg(query_duration_ms) / 1000 AS avg_duration_sec
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today() - INTERVAL 7 DAY
  AND query ILIKE 'ALTER%'
GROUP BY date
ORDER BY date;

-- ALTER 操作类型统计
SELECT
    CASE
        WHEN query ILIKE 'ALTER TABLE%ADD%' THEN 'ADD'
        WHEN query ILIKE 'ALTER TABLE%DROP%' THEN 'DROP'
        WHEN query ILIKE 'ALTER TABLE%MODIFY%' THEN 'MODIFY'
        WHEN query ILIKE 'ALTER TABLE%RENAME%' THEN 'RENAME'
        WHEN query ILIKE 'ALTER TABLE%OPTIMIZE%' THEN 'OPTIMIZE'
        WHEN query ILIKE 'ALTER TABLE%DETACH%' THEN 'DETACH'
        WHEN query ILIKE 'ALTER TABLE%ATTACH%' THEN 'ATTACH'
        ELSE 'OTHER'
    END AS alter_type,
    count() AS alter_count,
    avg(query_duration_ms) / 1000 AS avg_duration_sec
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today() - INTERVAL 7 DAY
  AND query ILIKE 'ALTER%'
GROUP BY alter_type
ORDER BY alter_count DESC;
```

#### 高频率 ALTER 检测

```sql
-- 检测同一表的频繁 ALTER 操作
SELECT
    database,
    table,
    user,
    count() AS alter_count,
    sum(query_duration_ms) / 1000 AS total_duration_sec,
    any(substring(query, 1, 200)) AS example_query
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today()
  AND query ILIKE 'ALTER TABLE%'
GROUP BY database, table, user
HAVING alter_count > 10  -- 超过 10 次
ORDER BY alter_count DESC;

-- 检测短时间内的频繁 ALTER
SELECT
    user,
    database,
    count() AS alter_count,
    min(event_time) AS first_time,
    max(event_time) AS last_time,
    dateDiff('minute', first_time, last_time) AS duration_minutes
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_time >= now() - INTERVAL 1 HOUR
  AND query ILIKE 'ALTER%'
GROUP BY user, database
HAVING alter_count > 5  -- 1 小时内超过 5 次
ORDER BY alter_count DESC;
```

### 2. ALTER 影响分析

#### ALTER 持续时间分析

```sql
-- 长时间运行的 ALTER 操作
SELECT
    query_id,
    user,
    query_duration_ms / 1000 AS duration_sec,
    substring(query, 1, 500) AS query
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today()
  AND query ILIKE 'ALTER%'
  AND query_duration_ms > 60000  -- 超过 1 分钟
ORDER BY query_duration_ms DESC
LIMIT 20;

-- ALTER 操作影响分析
SELECT
    user,
    database,
    count() AS alter_count,
    sum(query_duration_ms) / 1000 AS total_duration_sec,
    avg(read_rows) AS avg_read_rows,
    avg(written_rows) AS avg_written_rows,
    avg(memory_usage) AS avg_memory_usage
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today()
  AND query ILIKE 'ALTER%'
GROUP BY user, database
ORDER BY total_duration_sec DESC;
```

## 📊 MUTATION 操作监控

### 1. MUTATION 操作统计

```sql
-- MUTATION 操作统计
SELECT
    command,
    status,
    count() AS mutation_count,
    sum(failures) AS total_failures,
    avg(mutate_part_rows) AS avg_mutate_rows
FROM system.mutations
WHERE event_date >= today()
GROUP BY command, status
ORDER BY mutation_count DESC;

-- 活跃的 MUTATION 操作
SELECT
    database,
    table,
    command,
    mutation_id,
    status,
    created_at,
    progress * 100 AS progress_percent,
    parts_to_do,
    parts_to_do_names
FROM system.mutations
WHERE is_done = 0
ORDER BY created_at;

-- MUTATION 操作历史
SELECT
    toDate(created_at) AS date,
    command,
    count() AS mutation_count,
    avg(mutate_part_rows) AS avg_mutate_rows,
    sum(failures) AS total_failures
FROM system.mutations
WHERE created_at >= today() - INTERVAL 30 DAY
GROUP BY date, command
ORDER BY date, command;
```

### 2. 长时间运行的 MUTATION

```sql
-- 长时间运行的 MUTATION
SELECT
    database,
    table,
    command,
    mutation_id,
    created_at,
    now() - created_at AS running_time,
    progress * 100 AS progress_percent,
    parts_to_do,
    parts_to_do_names,
    formatReadableSize(bytes_read) AS bytes_read,
    formatReadableSize(bytes_written) AS bytes_written
FROM system.mutations
WHERE is_done = 0
  AND now() - created_time > INTERVAL 1 HOUR
ORDER BY created_at;

-- 影响 MUTATION 性能的因素分析
SELECT
    database,
    table,
    sum(mutate_part_rows) AS total_mutate_rows,
    avg(mutate_part_rows) AS avg_mutate_rows,
    sum(failures) AS total_failures,
    count() AS mutation_count
FROM system.mutations
WHERE event_date >= today()
GROUP BY database, table
HAVING sum(mutate_part_rows) > 10000000  -- 超过 1000 万行
ORDER BY total_mutate_rows DESC;
```

## 📊 DELETE 操作监控

### 1. DELETE 操作统计

```sql
-- DELETE 操作统计（通过 MUTATION）
SELECT
    database,
    table,
    command,
    count() AS delete_count,
    sum(mutate_part_rows) AS total_deleted_rows,
    avg(mutate_part_rows) AS avg_deleted_rows,
    sum(failures) AS total_failures
FROM system.mutations
WHERE event_date >= today()
  AND command ILIKE '%DELETE%'
GROUP BY database, table, command
ORDER BY total_deleted_rows DESC;

-- DELETE 操作趋势
SELECT
    toDate(created_at) AS date,
    database,
    count() AS delete_count,
    sum(mutate_part_rows) AS total_deleted_rows
FROM system.mutations
WHERE created_at >= today() - INTERVAL 30 DAY
  AND command ILIKE '%DELETE%'
GROUP BY date, database
ORDER BY date, delete_count DESC;

-- 高频 DELETE 检测
SELECT
    database,
    table,
    user,
    count() AS delete_count,
    sum(mutate_part_rows) AS total_deleted_rows
FROM system.mutations AS m
JOIN system.query_log AS q
    ON m.database = extractDatabases(q.query)
    AND m.table = extractTables(q.query)
WHERE m.created_at >= today()
  AND m.command ILIKE '%DELETE%'
  AND q.type = 'QueryFinish'
  AND q.query ILIKE 'DELETE%'
GROUP BY database, table, user
HAVING delete_count > 10  -- 超过 10 次
ORDER BY delete_count DESC;
```

### 2. 大规模 DELETE 监控

```sql
-- 大规模 DELETE 操作
SELECT
    database,
    table,
    command,
    mutation_id,
    mutate_part_rows,
    created_at,
    progress * 100 AS progress_percent
FROM system.mutations
WHERE created_at >= today()
  AND command ILIKE '%DELETE%'
  AND mutate_part_rows > 1000000  -- 删除超过 100 万行
ORDER BY mutate_part_rows DESC;

-- DELETE 影响分析
SELECT
    database,
    table,
    count() AS delete_count,
    sum(mutate_part_rows) AS total_deleted_rows,
    formatReadableSize(sum(mutate_part_rows * avg_row_size)) AS estimated_size
FROM (
    SELECT
        database,
        table,
        mutate_part_rows,
        command,
        created_at
    FROM system.mutations
    WHERE created_at >= today()
      AND command ILIKE '%DELETE%'
) AS m
LEFT JOIN (
    SELECT
        database,
        table,
        avg(bytes_on_disk / greatest(rows, 1)) AS avg_row_size
    FROM system.parts
    WHERE active
    GROUP BY database, table
) AS p ON m.database = p.database AND m.table = p.table
GROUP BY database, table
ORDER BY total_deleted_rows DESC;
```

## 📊 INSERT 操作监控

### 1. INSERT 性能监控

```sql
-- INSERT 操作统计
SELECT
    user,
    database,
    count() AS insert_count,
    sum(written_rows) AS total_written_rows,
    sum(written_bytes) AS total_written_bytes,
    avg(query_duration_ms) / 1000 AS avg_duration_sec,
    avg(written_rows / greatest(query_duration_ms / 1000, 1)) AS rows_per_second
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today()
  AND query ILIKE 'INSERT%'
GROUP BY user, database
ORDER BY insert_count DESC;

-- 慢 INSERT 操作
SELECT
    query_id,
    user,
    database,
    written_rows,
    written_bytes,
    query_duration_ms / 1000 AS duration_sec,
    written_rows / (query_duration_ms / 1000) AS rows_per_second,
    substring(query, 1, 300) AS query
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today()
  AND query ILIKE 'INSERT%'
  AND query_duration_ms > 10000  -- 超过 10 秒
ORDER BY query_duration_ms DESC
LIMIT 20;

-- INSERT 批次大小分析
SELECT
    user,
    count() AS insert_count,
    avg(written_rows) AS avg_batch_size,
    min(written_rows) AS min_batch_size,
    max(written_rows) AS max_batch_size,
    quantile(0.5)(written_rows) AS median_batch_size,
    quantile(0.9)(written_rows) AS p90_batch_size,
    quantile(0.95)(written_rows) AS p95_batch_size
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today()
  AND query ILIKE 'INSERT%'
GROUP BY user
ORDER BY insert_count DESC;
```

### 2. 小批次 INSERT 检测

```sql
-- 检测小批次 INSERT
SELECT
    user,
    database,
    count() AS small_batch_count,
    avg(written_rows) AS avg_batch_size,
    sum(query_duration_ms) / 1000 AS total_duration_sec
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today()
  AND query ILIKE 'INSERT%'
  AND written_rows < 1000  -- 小于 1000 行
GROUP BY user, database
HAVING small_batch_count > 100  -- 超过 100 次
ORDER BY small_batch_count DESC;

-- INSERT 频率分析
SELECT
    user,
    toStartOfMinute(event_time) AS minute,
    count() AS insert_count,
    sum(written_rows) AS total_written_rows
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today()
  AND query ILIKE 'INSERT%'
GROUP BY user, minute
HAVING count() > 100  -- 每分钟超过 100 次
ORDER BY insert_count DESC;
```

## 📊 其他操作监控

### 1. OPTIMIZE 操作监控

```sql
-- OPTIMIZE 操作统计
SELECT
    user,
    database,
    count() AS optimize_count,
    sum(query_duration_ms) / 1000 AS total_duration_sec,
    avg(query_duration_ms) / 1000 AS avg_duration_sec
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today()
  AND query ILIKE 'OPTIMIZE%'
GROUP BY user, database
ORDER BY optimize_count DESC;

-- 频繁 OPTIMIZE 检测
SELECT
    database,
    table,
    count() AS optimize_count,
    avg(query_duration_ms) / 1000 AS avg_duration_sec,
    any(substring(query, 1, 200)) AS example_query
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today()
  AND query ILIKE 'OPTIMIZE TABLE%'
GROUP BY database, table
HAVING optimize_count > 5  -- 超过 5 次
ORDER BY optimize_count DESC;
```

### 2. TRUNCATE 操作监控

```sql
-- TRUNCATE 操作统计
SELECT
    user,
    database,
    count() AS truncate_count,
    avg(query_duration_ms) / 1000 AS avg_duration_sec
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today()
  AND query ILIKE 'TRUNCATE%'
GROUP BY user, database
ORDER BY truncate_count DESC;

-- TRUNCATE 操作历史
SELECT
    toDate(event_time) AS date,
    user,
    count() AS truncate_count
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today() - INTERVAL 30 DAY
  AND query ILIKE 'TRUNCATE%'
GROUP BY date, user
ORDER BY date, truncate_count DESC;
```

### 3. DROP 操作监控

```sql
-- DROP 操作统计
SELECT
    user,
    count() AS drop_count,
    countIf(query ILIKE '%DROP TABLE%') AS drop_table_count,
    countIf(query ILIKE '%DROP DATABASE%') AS drop_database_count,
    countIf(query ILIKE '%DROP VIEW%') AS drop_view_count
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today()
  AND query ILIKE 'DROP%'
GROUP BY user
ORDER BY drop_count DESC;

-- DROP 操作详细记录
SELECT
    user,
    event_time,
    substring(query, 1, 300) AS query
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today()
  AND query ILIKE 'DROP%'
ORDER BY event_time DESC;
```

## 📊 监控视图

### 操作汇总视图

```sql
-- 创建操作汇总视图
CREATE VIEW monitoring.operation_summary AS
SELECT
    now() AS timestamp,
    'ALTER' AS operation_type,
    count() AS operation_count,
    sum(query_duration_ms) / 1000 AS total_duration_sec,
    avg(query_duration_ms) / 1000 AS avg_duration_sec
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today()
  AND query ILIKE 'ALTER%'

UNION ALL
SELECT
    now() AS timestamp,
    'INSERT' AS operation_type,
    count() AS operation_count,
    sum(query_duration_ms) / 1000 AS total_duration_sec,
    avg(query_duration_ms) / 1000 AS avg_duration_sec
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today()
  AND query ILIKE 'INSERT%'

UNION ALL
SELECT
    now() AS timestamp,
    'OPTIMIZE' AS operation_type,
    count() AS operation_count,
    sum(query_duration_ms) / 1000 AS total_duration_sec,
    avg(query_duration_ms) / 1000 AS avg_duration_sec
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today()
  AND query ILIKE 'OPTIMIZE%'

UNION ALL
SELECT
    now() AS timestamp,
    'TRUNCATE' AS operation_type,
    count() AS operation_count,
    sum(query_duration_ms) / 1000 AS total_duration_sec,
    avg(query_duration_ms) / 1000 AS avg_duration_sec
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today()
  AND query ILIKE 'TRUNCATE%'

UNION ALL
SELECT
    now() AS timestamp,
    'DROP' AS operation_type,
    count() AS operation_count,
    sum(query_duration_ms) / 1000 AS total_duration_sec,
    avg(query_duration_ms) / 1000 AS avg_duration_sec
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today()
  AND query ILIKE 'DROP%';

-- 创建高频操作告警视图
CREATE VIEW monitoring.high_frequency_operations AS
SELECT
    user,
    database,
    operation_type,
    count() AS operation_count,
    sum(query_duration_ms) / 1000 AS total_duration_sec
FROM (
    SELECT
        user,
        extractDatabases(query) AS database,
        CASE
            WHEN query ILIKE 'ALTER%' THEN 'ALTER'
            WHEN query ILIKE 'INSERT%' THEN 'INSERT'
            WHEN query ILIKE 'OPTIMIZE%' THEN 'OPTIMIZE'
            WHEN query ILIKE 'TRUNCATE%' THEN 'TRUNCATE'
            WHEN query ILIKE 'DROP%' THEN 'DROP'
            ELSE 'OTHER'
        END AS operation_type,
        query_duration_ms
    FROM system.query_log
    WHERE type = 'QueryFinish'
      AND event_date >= today()
)
GROUP BY user, database, operation_type
HAVING operation_count > 50  -- 超过 50 次
ORDER BY operation_count DESC;
```

## ⚠️ 重要注意事项

1. **性能影响**: 操作监控查询本身会消耗资源
2. **历史数据**: 操作日志会占用大量存储空间
3. **实时性**: 操作日志有一定延迟
4. **权限控制**: 操作日志应该有严格的访问控制
5. **数据清理**: 定期清理历史操作日志数据
6. **误报控制**: 合理设置告警阈值，避免误报
7. **上下文信息**: 某些操作可能需要额外的上下文信息
8. **监控频率**: 不要过于频繁地查询操作日志

## 📚 相关文档

- [01_system_monitoring.md](./01_system_monitoring.md) - 系统监控
- [02_query_monitoring.md](./02_query_monitoring.md) - 查询监控
- [05_abuse_detection.md](./05_abuse_detection.md) - 滥用检测
