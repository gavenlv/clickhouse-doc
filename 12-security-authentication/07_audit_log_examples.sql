SELECT 
    event_time,
    user,
    query,
    query_duration_ms,
    read_rows,
    read_bytes,
    memory_usage,
    exception_code,
    exception_text
FROM system.query_log
ORDER BY event_time DESC
LIMIT 100;

-- 查看特定用户的查询
SELECT 
    event_time,
    query,
    query_duration_ms,
    read_rows,
    read_bytes,
    memory_usage
FROM system.query_log
WHERE user = 'alice'
  AND type = 'QueryFinish'
  AND event_time >= now() - INTERVAL 1 DAY
ORDER BY event_time DESC;

-- 查看失败的查询
SELECT 
    event_time,
    user,
    query,
    exception_code,
    exception_text
FROM system.query_log
WHERE type = 'Exception'
  AND event_time >= now() - INTERVAL 7 DAY
ORDER BY event_time DESC;

-- ========================================
-- 查看所有查询
-- ========================================

-- 查看最慢的 100 条查询
SELECT 
    event_time,
    user,
    query,
    query_duration_ms / 1000 as duration_seconds,
    read_rows,
    read_bytes / 1024 / 1024 / 1024 as read_gb,
    memory_usage / 1024 / 1024 / 1024 as memory_gb
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query_duration_ms > 10000  -- 超过 10 秒
  AND event_time >= now() - INTERVAL 1 DAY
ORDER BY query_duration_ms DESC
LIMIT 100;

-- 按用户统计慢查询
SELECT 
    user,
    count() as slow_query_count,
    avg(query_duration_ms) as avg_duration_ms,
    max(query_duration_ms) as max_duration_ms,
    sum(read_rows) as total_read_rows,
    sum(read_bytes) / 1024 / 1024 / 1024 as total_read_gb
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query_duration_ms > 5000  -- 超过 5 秒
  AND event_time >= now() - INTERVAL 1 DAY
GROUP BY user
ORDER BY slow_query_count DESC;

-- ========================================
-- 查看所有查询
-- ========================================

-- 查看 Mutation 操作
SELECT 
    event_time,
    mutation_id,
    database,
    table,
    command,
    is_done,
    parts_to_do,
    parts_to_do_names
FROM system.mutation_log
ORDER BY event_time DESC;

-- 查看 Mutation 进度
SELECT 
    database,
    table,
    mutation_id,
    command,
    sum(parts_to_do - 1) as remaining_parts,
    count() as total_mutations
FROM system.mutation_log
WHERE is_done = 0
GROUP BY database, table, mutation_id, command;

-- 查看 Mutation 历史
SELECT 
    event_date,
    database,
    table,
    count() as mutation_count,
    sum(if(is_done = 1, 1, 0)) as completed_count,
    avg(dateDiff('second', event_time, now())) as avg_duration_seconds
FROM system.mutation_log
WHERE event_date >= today() - INTERVAL 30 DAY
GROUP BY event_date, database, table
ORDER BY event_date DESC;

-- ========================================
-- 查看所有查询
-- ========================================

-- 用户查询统计
SELECT 
    user,
    count() as total_queries,
    countIf(type = 'QueryFinish') as successful_queries,
    countIf(type = 'Exception') as failed_queries,
    avg(query_duration_ms) as avg_duration_ms,
    sum(read_rows) as total_read_rows,
    sum(read_bytes) / 1024 / 1024 / 1024 as total_read_gb,
    sum(memory_usage) / 1024 / 1024 / 1024 as total_memory_gb
FROM system.query_log
WHERE event_time >= now() - INTERVAL 1 DAY
GROUP BY user
ORDER BY total_queries DESC;

-- 用户访问模式
SELECT 
    user,
    countIf(position(query, 'SELECT')) as select_count,
    countIf(position(query, 'INSERT')) as insert_count,
    countIf(position(query, 'ALTER')) as alter_count,
    countIf(position(query, 'DROP')) as drop_count,
    countIf(position(query, 'CREATE')) as create_count
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_time >= now() - INTERVAL 7 DAY
GROUP BY user
ORDER BY select_count DESC;

-- 客户端 IP 统计
SELECT 
    IPv6NumToString(address) as client_ip,
    count() as query_count,
    count(DISTINCT user) as unique_users,
    avg(query_duration_ms) as avg_duration_ms
FROM system.query_log
WHERE event_time >= now() - INTERVAL 1 DAY
GROUP BY client_ip
ORDER BY query_count DESC;

-- ========================================
-- 查看所有查询
-- ========================================

-- 查看失败的登录尝试
SELECT 
    event_time,
    exception_text
FROM system.query_log
WHERE exception_code = 516  -- ACCESS_DENIED
  AND event_time >= now() - INTERVAL 1 DAY
ORDER BY event_time DESC;

-- 查看权限拒绝
SELECT 
    user,
    query,
    exception_text,
    count() as failure_count
FROM system.query_log
WHERE exception_code = 516
  AND event_time >= now() - INTERVAL 7 DAY
GROUP BY user, query, exception_text
ORDER BY failure_count DESC;

-- 查看异常查询
SELECT 
    event_time,
    user,
    query,
    exception_code,
    exception_text
FROM system.query_log
WHERE type = 'Exception'
  AND event_time >= now() - INTERVAL 1 DAY
ORDER BY event_time DESC;

-- ========================================
-- 查看所有查询
-- ========================================

-- 查询性能统计
SELECT 
    event_date,
    count() as total_queries,
    avg(query_duration_ms) as avg_duration_ms,
    max(query_duration_ms) as max_duration_ms,
    quantile(0.95)(query_duration_ms) as p95_duration_ms,
    quantile(0.99)(query_duration_ms) as p99_duration_ms,
    sum(read_bytes) / 1024 / 1024 / 1024 as total_read_gb
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today() - INTERVAL 30 DAY
GROUP BY event_date
ORDER BY event_date DESC;

-- 内存使用统计
SELECT 
    user,
    avg(memory_usage) / 1024 / 1024 / 1024 as avg_memory_gb,
    max(memory_usage) / 1024 / 1024 / 1024 as max_memory_gb,
    sum(memory_usage) / 1024 / 1024 / 1024 as total_memory_gb
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_time >= now() - INTERVAL 1 DAY
GROUP BY user
ORDER BY total_memory_gb DESC;

-- ========================================
-- 查看所有查询
-- ========================================

-- 1. 创建告警表
DROP TABLE IF EXISTS security.alerts;
CREATE TABLE IF NOT EXISTS security.alerts
ON CLUSTER 'treasurycluster'
(
    alert_id UUID,
    alert_type String,
    alert_level Enum8('info' = 1, 'warning' = 2, 'error' = 3, 'critical' = 4),
    message String,
    details String,
    alert_time DateTime,
    resolved UInt8 DEFAULT 0
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/alerts', '{replica}')
PARTITION BY toYYYYMM(alert_time)
ORDER BY (alert_id, alert_time);

-- 2. 创建慢查询告警视图
CREATE MATERIALIZED VIEW IF NOT EXISTS security.slow_query_alerts_mv
TO security.alerts
AS SELECT
    generateUUIDv4() as alert_id,
    'slow_query' as alert_type,
    if(query_duration_ms > 30000, 'critical', 'warning')::Enum8('info' = 1, 'warning' = 2, 'error' = 3, 'critical' = 4) as alert_level,
    format('Slow query detected: user={}, duration={}ms, query={}', user, query_duration_ms, substring(query, 1, 100)) as message,
    format('user={}, query={}, duration={}ms', user, query, query_duration_ms) as details,
    event_time as alert_time
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query_duration_ms > 10000
  AND event_time >= now() - INTERVAL 5 MINUTE;

-- ========================================
-- 查看所有查询
-- ========================================

-- 查看所有告警
SELECT 
    alert_id,
    alert_type,
    alert_level,
    message,
    alert_time,
    resolved
FROM security.alerts
ORDER BY alert_time DESC;

-- 查看未解决的告警
SELECT 
    alert_id,
    alert_type,
    alert_level,
    message,
    alert_time
FROM security.alerts
WHERE resolved = 0
ORDER BY alert_level DESC, alert_time DESC;

-- 统计告警
SELECT 
    alert_type,
    alert_level,
    count() as alert_count
FROM security.alerts
WHERE alert_time >= now() - INTERVAL 1 DAY
GROUP BY alert_type, alert_level
ORDER BY alert_level DESC, alert_count DESC;

-- ========================================
-- 查看所有查询
-- ========================================

-- 1. 用户活动报告
SELECT 
    'User Activity Report' as report_type,
    now() as report_time,
    '' as line
UNION ALL
SELECT 
    format('Total queries: {}', count()) as report_type,
    '' as report_time,
    '' as line
FROM system.query_log
WHERE event_time >= now() - INTERVAL 1 DAY
UNION ALL
SELECT 
    format('Users: {}', count(DISTINCT user)) as report_type,
    '' as report_time,
    '' as line
FROM system.query_log
WHERE event_time >= now() - INTERVAL 1 DAY
UNION ALL
SELECT 
    '' as report_type,
    '' as report_time,
    '---' as line
UNION ALL
SELECT 
    user as report_type,
    format('Queries: {}, Avg: {:.2f}s, Max: {:.2f}s', 
           count(), 
           avg(query_duration_ms) / 1000, 
           max(query_duration_ms) / 1000) as report_time,
    '' as line
FROM system.query_log
WHERE event_time >= now() - INTERVAL 1 DAY
GROUP BY user
ORDER BY count() DESC;

-- 2. 安全事件报告
SELECT 
    'Security Events Report' as report_type,
    now() as report_time,
    '' as line
UNION ALL
SELECT 
    format('Failed queries: {}', count()) as report_type,
    '' as report_time,
    '' as line
FROM system.query_log
WHERE type = 'Exception'
  AND event_time >= now() - INTERVAL 1 DAY
UNION ALL
SELECT 
    format('Access denied: {}', count()) as report_type,
    '' as report_time,
    '' as line
FROM system.query_log
WHERE exception_code = 516
  AND event_time >= now() - INTERVAL 1 DAY
UNION ALL
SELECT 
    '' as report_type,
    '' as report_time,
    '---' as line
UNION ALL
SELECT 
    format('User: {}, Error: {}', user, exception_text) as report_type,
    event_time as report_time,
    '' as line
FROM system.query_log
WHERE exception_code = 516
  AND event_time >= now() - INTERVAL 1 DAY
ORDER BY event_time DESC
LIMIT 10;
