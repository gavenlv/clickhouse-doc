-- ================================================
-- 07_queries_processes_examples.sql
-- 从 07_queries_processes.md 提取的 SQL 示例
-- 提取时间: 2026-01-23 14:40:17
-- ================================================


-- ========================================
-- 查看当前运行的查询
-- ========================================

-- 查看所有正在运行的查询
-- SKIPPED: Problematic statement (elapsed field does not exist)
-- SELECT
--     query_id,
--     user,
--     query,
--     elapsed,
--     read_rows,
--     read_bytes,
--     total_rows_approx,
--     memory_usage,
--     thread_ids,
--     profile_events,
--     settings
-- FROM system.processes
-- ORDER BY elapsed DESC;
-- 

-- ========================================
-- 查看当前运行的查询
-- ========================================

-- 查看查询的详细进度
-- SKIPPED: Problematic statement (contains non-existent fields/tables)
-- SELECT
--     query_id,
--     user,
--     query,
--     elapsed,
--     elapsed / max_execution_time * 100 AS progress_percent,
--     read_rows,
--     read_bytes,
--     written_rows,
--     written_bytes,
--     result_rows,
--     result_bytes,
--     memory_usage,
--     thread_ids
-- FROM system.processes
-- WHERE elapsed > 0
-- ORDER BY elapsed DESC;
-- 

-- ========================================
-- 查看当前运行的查询
-- ========================================

-- 查看最近完成的查询
-- SKIPPED: Problematic statement (contains non-existent fields/tables)
-- SELECT
--     event_time,
--     event_date,
--     query_id,
--     user,
--     query,
--     query_kind,
--     type,
--     elapsed,
--     read_rows,
--     read_bytes,
--     result_rows,
--     result_bytes,
--     memory_usage
-- FROM system.query_log
-- WHERE type = 'QueryFinish'
--   AND event_date >= today()
-- ORDER BY event_time DESC
-- LIMIT 100;
-- 

-- ========================================
-- 查看当前运行的查询
-- ========================================

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

-- ========================================
-- 查看当前运行的查询
-- ========================================

-- 统计不同类型查询的数量
-- SKIPPED: Problematic statement (contains non-existent fields/tables)
-- SELECT
--     type,
--     query_kind,
--     count() AS query_count,
--     avg(elapsed) AS avg_elapsed,
--     max(elapsed) AS max_elapsed,
--     sum(read_bytes) AS total_read_bytes,
--     sum(result_bytes) AS total_result_bytes
-- FROM system.query_log
-- WHERE event_date >= today()
-- GROUP BY type, query_kind
-- ORDER BY query_count DESC;
-- 

-- ========================================
-- 查看当前运行的查询
-- ========================================

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

-- ========================================
-- 查看当前运行的查询
-- ========================================

-- 分析资源使用最多的查询
-- SKIPPED: Problematic statement (contains non-existent fields/tables)
-- SELECT
--     user,
--     query,
--     elapsed,
--     read_bytes,
--     result_bytes,
--     memory_usage,
--     read_bytes / elapsed AS read_bytes_per_sec
-- FROM system.query_log
-- WHERE type = 'QueryFinish'
--   AND event_date >= today()
--   AND query NOT ILIKE '%system%'
-- ORDER BY memory_usage DESC
-- LIMIT 20;
-- 

-- ========================================
-- 查看当前运行的查询
-- ========================================

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

-- ========================================
-- 查看当前运行的查询
-- ========================================

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

-- ========================================
-- 查看当前运行的查询
-- ========================================

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

-- ========================================
-- 查看当前运行的查询
-- ========================================

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

-- ========================================
-- 查看当前运行的查询
-- ========================================

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

-- ========================================
-- 查看当前运行的查询
-- ========================================

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

-- ========================================
-- 查看当前运行的查询
-- ========================================

-- 查看查询线程日志
-- SKIPPED: Problematic statement (contains non-existent fields/tables)
-- SELECT
--     event_time,
--     query_id,
--     thread_id,
--     thread_name,
--     elapsed,
--     cpu_time_ns,
--     memory_usage,
--     read_rows,
--     read_bytes
-- FROM system.query_thread_log
-- WHERE event_date >= today()
-- ORDER BY event_time DESC
-- LIMIT 100;
-- 

-- ========================================
-- 查看当前运行的查询
-- ========================================

-- 分析查询的线程使用情况
-- SKIPPED: Problematic statement (contains non-existent fields/tables)
-- SELECT
--     query_id,
--     thread_id,
--     count() AS thread_count,
--     avg(elapsed) AS avg_elapsed,
--     max(cpu_time_ns) AS max_cpu_time
-- FROM system.query_thread_log
-- WHERE event_date >= today()
-- GROUP BY query_id, thread_id
-- ORDER BY thread_count DESC;
-- 

-- ========================================
-- 查看当前运行的查询
-- ========================================

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

-- ========================================
-- 查看当前运行的查询
-- ========================================

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

-- ========================================
-- 查看当前运行的查询
-- ========================================

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
