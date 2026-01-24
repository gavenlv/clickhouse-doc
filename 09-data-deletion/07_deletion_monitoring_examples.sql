SELECT
    query_id,
    user,
    query,
    elapsed,
    read_rows,
    read_bytes,
    written_rows,
    written_bytes,
    memory_usage,
    thread_ids
FROM system.processes
WHERE query ILIKE '%DELETE%'
  OR query ILIKE '%DROP%'
ORDER BY elapsed DESC;

-- ========================================
-- 1. 删除操作监控
-- ========================================

-- 查看 Mutation 执行进度
SELECT
    database,
    table,
    mutation_id,
    command,
    is_done,
    parts_to_do,
    parts_done,
    (parts_done * 100.0 / NULLIF(parts_to_do, 0)) AS progress_percent,
    create_time,
    done_time,
    elapsed_seconds,
    exception_code,
    exception_text
FROM system.mutations
WHERE database = 'your_database'
ORDER BY create_time DESC;

-- ========================================
-- 1. 删除操作监控
-- ========================================

-- 监控删除期间的系统资源
SELECT
    'CPU Usage (%)' as metric,
    round(
        (sum(OSUserTime) + sum(OSSystemTime)) * 100.0 / 
        sum(OSUserTime + OSSystemTime + OSIdleTime), 2
    ) as value
FROM system.asynchronous_metrics
WHERE metric LIKE 'OS%Time'

UNION ALL

SELECT
    'Memory Usage (GB)',
    formatReadableSize(MemoryTracking) as value
FROM system.metrics

UNION ALL

SELECT
    'Disk Read (MB/s)',
    formatReadableSize(ReadBufferFromFileDescriptorBytes / 1e6)
FROM system.metrics;

-- ========================================
-- 1. 删除操作监控
-- ========================================

-- 统计删除操作的执行情况
SELECT
    toStartOfDay(event_time) AS day,
    count() AS delete_count,
    avg(elapsed) AS avg_elapsed,
    max(elapsed) AS max_elapsed,
    sum(read_rows) AS total_rows_read,
    sum(written_rows) AS total_rows_written
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today() - INTERVAL 7 DAY
  AND (query ILIKE '%DELETE%' OR query ILIKE '%DROP%')
GROUP BY day
ORDER BY day DESC;

-- ========================================
-- 1. 删除操作监控
-- ========================================

-- 分析删除操作对表的影响
SELECT
    database,
    table,
    count() AS delete_operations,
    avg(parts_to_do) AS avg_parts_affected,
    sum(parts_to_do) AS total_parts_affected,
    sum(elapsed_seconds) AS total_elapsed,
    avg(elapsed_seconds) AS avg_elapsed
FROM system.mutations
WHERE database = 'your_database'
  AND command ILIKE '%DELETE%'
  AND create_time >= today() - INTERVAL 7 DAY
GROUP BY database, table
ORDER BY total_elapsed DESC;

-- ========================================
-- 1. 删除操作监控
-- ========================================

-- 监控删除操作中的错误
SELECT
    event_time,
    event_date,
    database,
    table,
    query,
    exception_code,
    exception_text,
    elapsed
FROM system.query_log
WHERE type = 'ExceptionWhileProcessing'
  AND event_date >= today() - INTERVAL 7 DAY
  AND (query ILIKE '%DELETE%' OR query ILIKE '%DROP%')
ORDER BY event_time DESC;

-- ========================================
-- 1. 删除操作监控
-- ========================================

-- 监控 TTL 删除执行情况
SELECT
    event_time,
    database,
    table,
    query,
    elapsed,
    read_rows,
    written_rows
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today() - INTERVAL 7 DAY
  AND query ILIKE '%TTL%'
ORDER BY event_time DESC;

-- ========================================
-- 1. 删除操作监控
-- ========================================

-- 监控分区删除操作
SELECT
    event_time,
    database,
    table,
    query,
    elapsed
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today() - INTERVAL 7 DAY
  AND query ILIKE '%DROP PARTITION%'
ORDER BY event_time DESC;

-- ========================================
-- 1. 删除操作监控
-- ========================================

-- 创建监控视图供 Grafana 查询

-- 1. 删除操作执行时间视图
CREATE MATERIALIZED VIEW deletion_metrics_mv
ENGINE = SummingMergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_date, database, table)
AS
SELECT
    toStartOfDay(event_time) AS event_date,
    database,
    table,
    count() AS operation_count,
    avg(elapsed) AS avg_elapsed,
    max(elapsed) AS max_elapsed,
    sum(elapsed) AS total_elapsed,
    sum(read_rows) AS total_rows_read
FROM system.query_log
WHERE type = 'QueryFinish'
  AND (query ILIKE '%DELETE%' OR query ILIKE '%DROP%')
GROUP BY event_date, database, table;

-- 2. Mutation 状态视图
CREATE MATERIALIZED VIEW mutation_status_mv
ENGINE = ReplacingMergeTree()
ORDER BY mutation_id
AS
SELECT
    mutation_id,
    database,
    table,
    command,
    is_done,
    parts_to_do,
    parts_done,
    create_time,
    elapsed_seconds
FROM system.mutations;

-- ========================================
-- 1. 删除操作监控
-- ========================================

-- 导出删除操作的指标
SELECT
    'clickhouse_deletions_total' as metric_name,
    count() as metric_value,
    '' as labels
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date = today()
  AND query ILIKE '%DELETE%'

UNION ALL

SELECT
    'clickhouse_deletions_duration_seconds',
    avg(elapsed),
    ''
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date = today()
  AND query ILIKE '%DELETE%'

UNION ALL

SELECT
    'clickhouse_mutations_active',
    count(),
    ''
FROM system.mutations
WHERE is_done = 0;

-- ========================================
-- 1. 删除操作监控
-- ========================================

-- 检查执行时间过长的删除操作
SELECT
    'Long running deletion' as alert_type,
    query_id,
    elapsed,
    read_rows,
    query
FROM system.processes
WHERE query ILIKE '%DELETE%'
  AND elapsed > 300  -- 5 分钟
ORDER BY elapsed DESC;

-- 告警级别：WARNING
-- 处理建议：检查删除的数据量，考虑分批次处理

-- ========================================
-- 1. 删除操作监控
-- ========================================

-- 检查积压的 Mutation
SELECT
    'Mutation backlog' as alert_type,
    count() as pending_mutations,
    max(parts_to_do) as max_parts_pending,
    sum(parts_to_do) as total_parts_pending
FROM system.mutations
WHERE is_done = 0;

-- 告警级别：
-- - 1-2: INFO
-- - 3-5: WARNING
-- - >5: CRITICAL

-- ========================================
-- 1. 删除操作监控
-- ========================================

-- 检查删除操作的错误率
SELECT
    'High deletion error rate' as alert_type,
    round(
        countIf(exception_code != 0) * 100.0 / 
        NULLIF(count(), 0), 2
    ) as error_rate_percent,
    countIf(exception_code != 0) as error_count,
    count() as total_count
FROM system.query_log
WHERE type = 'ExceptionWhileProcessing'
  AND event_date >= today()
  AND query ILIKE '%DELETE%';

-- 告警级别：
-- - >1%: WARNING
-- - >5%: CRITICAL

-- ========================================
-- 1. 删除操作监控
-- ========================================

-- 检查删除后存储空间是否释放
SELECT
    'Storage not released' as alert_type,
    database,
    table,
    formatReadableSize(sum(bytes_on_disk)) AS current_size,
    formatReadableSize(sum(bytes_on_disk) * 0.7) AS expected_size,
    round(
        (1 - 0.7) * 100.0, 2
    ) AS potential_free_percent
FROM system.parts
WHERE active = 0
GROUP BY database, table
HAVING sum(bytes_on_disk) > 1073741824;  -- > 1GB

-- 告警级别：WARNING
-- 处理建议：触发 OPTIMIZE 清理非活动数据块

-- ========================================
-- 1. 删除操作监控
-- ========================================

-- 诊断删除操作的性能问题
SELECT
    query_id,
    elapsed,
    read_rows,
    read_bytes,
    written_rows,
    written_bytes,
    memory_usage,
    elapsed / NULLIF(read_rows, 0) * 1e6 AS microseconds_per_row,
    read_bytes / NULLIF(elapsed, 0) AS read_bytes_per_second
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today()
  AND query ILIKE '%DELETE%'
ORDER BY elapsed DESC
LIMIT 10;

-- ========================================
-- 1. 删除操作监控
-- ========================================

-- 查看失败的 Mutation
SELECT
    mutation_id,
    database,
    table,
    command,
    is_done,
    create_time,
    exception_code,
    exception_text
FROM system.mutations
WHERE exception_code != 0
ORDER BY create_time DESC;

-- ========================================
-- 1. 删除操作监控
-- ========================================

-- 评估删除操作的影响范围
SELECT
    database,
    table,
    mutation_id,
    command,
    parts_to_do,
    count() as affected_rows,
    formatReadableSize(sum(bytes_on_disk)) as affected_size
FROM system.mutations AS m
JOIN (
    SELECT 
        table,
        sum(rows) as rows,
        sum(bytes_on_disk) as bytes
    FROM system.parts
    WHERE active = 1
    GROUP BY table
) AS p ON m.table = p.table
WHERE m.database = 'your_database'
  AND m.create_time >= today()
ORDER BY m.create_time DESC;

-- ========================================
-- 1. 删除操作监控
-- ========================================

-- 监控批量删除的进度和性能

-- 1. 查看当前批次
SELECT
    mutation_id,
    command,
    is_done,
    parts_to_do,
    parts_done,
    (parts_done * 100.0 / NULLIF(parts_to_do, 0)) AS progress_percent
FROM system.mutations
WHERE database = 'your_database'
ORDER BY create_time DESC
LIMIT 1;

-- 2. 查看历史批次统计
SELECT
    toStartOfHour(create_time) AS hour,
    count() AS batches_completed,
    avg(elapsed_seconds) AS avg_batch_duration,
    sum(elapsed_seconds) AS total_duration
FROM system.mutations
WHERE database = 'your_database'
  AND is_done = 1
  AND create_time >= today() - INTERVAL 24 HOUR
GROUP BY hour
ORDER BY hour;

-- ========================================
-- 1. 删除操作监控
-- ========================================

-- 监控 TTL 自动删除的效果

-- 1. 查看表的数据趋势
SELECT
    toStartOfDay(event_time) AS day,
    count() AS row_count
FROM events
WHERE event_time >= today() - INTERVAL 30 DAY
GROUP BY day
ORDER BY day;

-- 2. 查看分区数量变化
SELECT
    toStartOfDay(modification_time) AS day,
    count() AS partition_count
FROM system.parts
WHERE table = 'events' AND active = 1
GROUP BY day
ORDER BY day;

-- ========================================
-- 1. 删除操作监控
-- ========================================

-- 监控删除操作对系统健康的影响

-- 1. 查看当前负载
SELECT
    'CPU Usage (%)',
    round(
        (OSUserTime + OSSystemTime) * 100.0 / 
        (OSUserTime + OSSystemTime + OSIdleTime), 2
    )
FROM system.asynchronous_metrics

UNION ALL

SELECT
    'Memory Usage (GB)',
    formatReadableSize(MemoryTracking)
FROM system.metrics

UNION ALL

SELECT
    'Active Queries',
    count()
FROM system.processes

UNION ALL

SELECT
    'Pending Mutations',
    count()
FROM system.mutations
WHERE is_done = 0;

-- ========================================
-- 1. 删除操作监控
-- ========================================

-- 删除操作概览
SELECT
    'Today' as period,
    count() as total_deletions,
    avg(elapsed) as avg_duration,
    max(elapsed) as max_duration,
    sum(read_rows) as total_rows_affected
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date = today()
  AND query ILIKE '%DELETE%'

UNION ALL

SELECT
    'This Week',
    count(),
    avg(elapsed),
    max(elapsed),
    sum(read_rows)
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today() - INTERVAL 7 DAY
  AND query ILIKE '%DELETE%'

UNION ALL

SELECT
    'This Month',
    count(),
    avg(elapsed),
    max(elapsed),
    sum(read_rows)
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today() - INTERVAL 30 DAY
  AND query ILIKE '%DELETE%';

-- ========================================
-- 1. 删除操作监控
-- ========================================

-- Mutation 状态概览
SELECT
    'Active' as status,
    count() as mutation_count,
    sum(parts_to_do) as parts_pending,
    sum(elapsed_seconds) as total_elapsed_seconds
FROM system.mutations
WHERE is_done = 0

UNION ALL

SELECT
    'Completed Today',
    count(),
    0,
    sum(elapsed_seconds)
FROM system.mutations
WHERE is_done = 1
  AND done_time >= today()

UNION ALL

SELECT
    'Completed This Week',
    count(),
    0,
    sum(elapsed_seconds)
FROM system.mutations
WHERE is_done = 1
  AND done_time >= today() - INTERVAL 7 DAY;

-- ========================================
-- 1. 删除操作监控
-- ========================================

-- 实时监控删除操作
-- 使用 clickhouse-client 的 --interactive 选项

clickhouse-client --host=localhost --port=9000 --queries-file=monitor_deletions.sql

-- monitor_deletions.sql 内容：
-- SELECT query_id, elapsed, read_rows, memory_usage 
-- FROM system.processes 
-- WHERE query ILIKE '%DELETE%' 
-- ORDER BY elapsed DESC;

-- ========================================
-- 1. 删除操作监控
-- ========================================

-- 分析历史删除操作
SELECT
    toStartOfWeek(event_time) AS week,
    count() AS deletion_count,
    avg(elapsed) AS avg_duration,
    sum(read_rows) AS total_rows_deleted,
    formatReadableSize(sum(read_bytes)) AS total_bytes_read
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today() - INTERVAL 90 DAY
  AND query ILIKE '%DELETE%'
GROUP BY week
ORDER BY week;

-- ========================================
-- 1. 删除操作监控
-- ========================================

-- 预测未来的删除需求
SELECT
    'Estimated deletions next week' as metric,
    round(avg(deletion_count)) as value
FROM (
    SELECT
        toStartOfWeek(event_time) AS week,
        count() AS deletion_count
    FROM system.query_log
    WHERE type = 'QueryFinish'
      AND event_date >= today() - INTERVAL 90 DAY
      AND query ILIKE '%DELETE%'
    GROUP BY week
);
