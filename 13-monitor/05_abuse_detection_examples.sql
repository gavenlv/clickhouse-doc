-- ================================================
-- 05_abuse_detection_examples.sql
-- 从 05_abuse_detection.md 提取的 SQL 示例
-- 提取时间: 2026-01-23 14:40:17
-- ================================================


-- ========================================
-- 查找所有非复制表
-- ========================================

-- 查找所有非复制表
SELECT
    database,
    table,
    engine,
    partition_key,
    sorting_key,
    primary_key,
    total_rows,
    total_bytes,
    formatReadableSize(total_bytes) AS readable_size
FROM system.tables
WHERE database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
  AND engine NOT LIKE '%Replicated%'
  AND engine NOT LIKE '%View%'
  AND engine NOT LIKE '%Dictionary%'
  AND total_bytes > 0
ORDER BY total_bytes DESC;

-- 按数据库统计非复制表
SELECT
    database,
    count() AS non_replicated_count,
    sum(total_rows) AS total_rows,
    sum(total_bytes) AS total_bytes,
    formatReadableSize(sum(total_bytes)) AS readable_size
FROM system.tables
WHERE database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
  AND engine NOT LIKE '%Replicated%'
  AND engine NOT LIKE '%View%'
  AND engine NOT LIKE '%Dictionary%'
GROUP BY database
ORDER BY total_bytes DESC;

-- 按引擎类型统计
SELECT
    engine,
    count() AS table_count,
    sum(total_rows) AS total_rows,
    sum(total_bytes) AS total_bytes,
    formatReadableSize(sum(total_bytes)) AS readable_size
FROM system.tables
WHERE database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
  AND engine NOT LIKE '%Replicated%'
  AND engine NOT LIKE '%View%'
  AND engine NOT LIKE '%Dictionary%'
  AND total_bytes > 0
GROUP BY engine
ORDER BY total_bytes DESC;

-- ========================================
-- 查找所有非复制表
-- ========================================

-- 大型非复制表（超过 10GB）
SELECT
    database,
    table,
    engine,
    total_rows,
    total_bytes,
    formatReadableSize(total_bytes) AS readable_size,
    CASE
        WHEN total_bytes > 107374182400 THEN 'CRITICAL'  -- 超过 100GB
        WHEN total_bytes > 10737418240 THEN 'WARNING'     -- 超过 10GB
        ELSE 'OK'
    END AS status
FROM system.tables
WHERE database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
  AND engine NOT LIKE '%Replicated%'
  AND engine NOT LIKE '%View%'
  AND engine NOT LIKE '%Dictionary%'
  AND total_bytes > 10737418240  -- 超过 10GB
ORDER BY total_bytes DESC;

-- 非复制表数据增长趋势（需要配合历史数据）
SELECT
    database,
    table,
    engine,
    total_bytes,
    formatReadableSize(total_bytes) AS current_size
FROM system.tables
WHERE database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
  AND engine NOT LIKE '%Replicated%'
  AND total_bytes > 1073741824  -- 超过 1GB
ORDER BY total_bytes DESC;

-- ========================================
-- 查找所有非复制表
-- ========================================

-- 查询非复制表的统计
SELECT
    query_id,
    user,
    substring(query, 1, 300) AS query,
    read_rows,
    read_bytes,
    query_duration_ms
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today()
  AND (
    -- 查询非复制表
    query ILIKE 'SELECT%FROM%'
    AND NOT query ILIKE '%system.%'
    AND EXISTS (
        SELECT 1
        FROM system.tables
        WHERE database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
          AND engine NOT LIKE '%Replicated%'
          AND engine NOT LIKE '%View%'
          AND engine NOT LIKE '%Dictionary%'
          AND query ILIKE '%' || database || '.' || table || '%'
    )
  )
ORDER BY query_duration_ms DESC
LIMIT 20;

-- 按用户统计非复制表查询
SELECT
    user,
    count() AS query_count,
    sum(query_duration_ms) / 1000 AS total_duration_sec,
    sum(read_bytes) AS total_read_bytes
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today()
  AND EXISTS (
      SELECT 1
      FROM system.tables
      WHERE database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
        AND engine NOT LIKE '%Replicated%'
        AND engine NOT LIKE '%View%'
        AND system.query_log.query ILIKE '%' || database || '.' || table || '%'
  )
GROUP BY user
ORDER BY query_count DESC;

-- ========================================
-- 查找所有非复制表
-- ========================================

-- 检测所有包含 Transaction 的 JOIN 查询
SELECT
    query_id,
    user,
    query_duration_ms,
    read_rows,
    read_bytes,
    written_rows,
    written_bytes,
    memory_usage,
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
LIMIT 20;

-- Transaction 表 JOIN 统计（按用户）
SELECT
    user,
    count() AS transaction_join_count,
    avg(query_duration_ms) / 1000 AS avg_duration_sec,
    max(query_duration_ms) / 1000 AS max_duration_sec,
    sum(read_rows) AS total_read_rows,
    sum(read_bytes) AS total_read_bytes
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

-- Transaction 表 JOIN 趋势（每小时）
SELECT
    toStartOfHour(event_time) AS hour,
    count() AS transaction_join_count,
    avg(query_duration_ms) / 1000 AS avg_duration_sec,
    sum(read_rows) AS total_read_rows
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today() - INTERVAL 7 DAY
  AND query ILIKE '%JOIN%'
  AND (
    query ILIKE '%transactions%'
    OR query ILIKE '%transaction%'
  )
GROUP BY hour
ORDER BY hour;

-- ========================================
-- 查找所有非复制表
-- ========================================

-- 慢速 Transaction 表 JOIN 查询
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
  AND event_date >= today()
  AND query ILIKE '%JOIN%'
  AND (
    query ILIKE '%transactions%'
    OR query ILIKE '%transaction%'
  )
  AND query_duration_ms > 10000  -- 超过 10 秒
ORDER BY query_duration_ms DESC
LIMIT 20;

-- 高资源消耗 Transaction 表 JOIN
SELECT
    query_id,
    user,
    query_duration_ms,
    read_bytes,
    memory_usage,
    formatReadableSize(read_bytes) AS readable_read_bytes,
    formatReadableSize(memory_usage) AS readable_memory_usage,
    substring(query, 1, 300) AS query
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today()
  AND query ILIKE '%JOIN%'
  AND (
    query ILIKE '%transactions%'
    OR query ILIKE '%transaction%'
  )
  AND (read_bytes > 1073741824 OR memory_usage > 1073741824)  -- 超过 1GB
ORDER BY memory_usage DESC
LIMIT 10;

-- ========================================
-- 查找所有非复制表
-- ========================================

-- 高频小查询检测
SELECT
    user,
    count() AS query_count,
    avg(read_rows) AS avg_read_rows,
    avg(query_duration_ms) AS avg_duration_ms,
    substring(any(query), 1, 200) AS example_query
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today()
  AND read_rows < 1000  -- 读取少于 1000 行
  AND query_duration_ms < 100  -- 执行时间少于 100ms
GROUP BY user
HAVING query_count > 1000  -- 超过 1000 次
ORDER BY query_count DESC;

-- QPS 过高检测
SELECT
    toStartOfMinute(event_time) AS minute,
    count() AS qps,
    countIf(query_duration_ms > 1000) AS slow_query_count,
    avg(query_duration_ms) AS avg_duration_ms
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today()
GROUP BY minute
HAVING qps > 100  -- 每分钟超过 100 个查询
ORDER BY minute DESC
LIMIT 10;

-- 按用户统计高频查询
SELECT
    user,
    toStartOfMinute(event_time) AS minute,
    count() AS query_count
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today()
GROUP BY user, minute
HAVING count() > 50  -- 每分钟超过 50 个查询
ORDER BY query_count DESC;

-- ========================================
-- 查找所有非复制表
-- ========================================

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
  AND event_date >= today()
  AND read_rows > 100000  -- 读取超过 10 万行
  AND result_rows < 1000  -- 返回少于 1000 行
  AND read_rows / result_rows > 100  -- 读取行数是返回行数的 100 倍
ORDER BY read_ratio DESC
LIMIT 20;

-- 全表扫描用户统计
SELECT
    user,
    count() AS full_scan_count,
    sum(read_rows) AS total_read_rows,
    avg(query_duration_ms) AS avg_duration_ms
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today()
  AND read_rows > 100000
  AND result_rows < 1000
  AND read_rows / result_rows > 100
GROUP BY user
ORDER BY full_scan_count DESC;

-- 全表扫描趋势
SELECT
    toStartOfHour(event_time) AS hour,
    count() AS full_scan_count,
    sum(read_rows) AS total_read_rows
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today() - INTERVAL 7 DAY
  AND read_rows > 100000
  AND result_rows < 1000
  AND read_rows / result_rows > 100
GROUP BY hour
ORDER BY hour;

-- ========================================
-- 查找所有非复制表
-- ========================================

-- 高内存消耗查询
SELECT
    query_id,
    user,
    query_duration_ms,
    memory_usage,
    formatReadableSize(memory_usage) AS readable_memory_usage,
    read_rows,
    substring(query, 1, 300) AS query
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today()
  AND memory_usage > 1073741824  -- 超过 1GB
ORDER BY memory_usage DESC
LIMIT 20;

-- 高内存用户统计
SELECT
    user,
    count() AS high_memory_count,
    sum(memory_usage) AS total_memory_usage,
    formatReadableSize(sum(memory_usage)) AS readable_total_memory,
    avg(query_duration_ms) AS avg_duration_ms
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today()
  AND memory_usage > 1073741824  -- 超过 1GB
GROUP BY user
ORDER BY total_memory_usage DESC;

-- 内存泄漏检测（长时间运行且高内存）
SELECT
    query_id,
    user,
    query_duration_ms,
    memory_usage,
    query_duration_ms / 1000 AS duration_sec,
    substring(query, 1, 300) AS query
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today()
  AND memory_usage > 1073741824  -- 超过 1GB
  AND query_duration_ms > 600000  -- 超过 10 分钟
ORDER BY query_duration_ms DESC;

-- ========================================
-- 查找所有非复制表
-- ========================================

-- 高 CPU 消耗查询（长时间运行）
SELECT
    query_id,
    user,
    query_duration_ms,
    read_rows,
    written_rows,
    read_bytes,
    written_bytes,
    substring(query, 1, 300) AS query
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today()
  AND query_duration_ms > 60000  -- 超过 1 分钟
ORDER BY query_duration_ms DESC
LIMIT 20;

-- 高 CPU 用户统计
SELECT
    user,
    count() AS high_cpu_count,
    sum(query_duration_ms) / 1000 AS total_duration_sec,
    avg(query_duration_ms) AS avg_duration_ms
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today()
  AND query_duration_ms > 60000  -- 超过 1 分钟
GROUP BY user
ORDER BY total_duration_sec DESC;

-- ========================================
-- 查找所有非复制表
-- ========================================

-- 非工作时间查询（周末或晚上 10 点到早上 8 点）
SELECT
    user,
    count() AS off_hour_query_count,
    avg(query_duration_ms) AS avg_duration_ms,
    any(substring(query, 1, 200)) AS example_query
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today() - INTERVAL 7 DAY
  AND (
    -- 周末
    toDayOfWeek(event_time) IN (6, 7)
    OR
    -- 晚上 10 点到早上 8 点
    toHour(event_time) >= 22 OR toHour(event_time) < 8
  )
GROUP BY user
HAVING off_hour_query_count > 100  -- 超过 100 次
ORDER BY off_hour_query_count DESC;

-- 异常时间大查询
SELECT
    user,
    event_time,
    query_duration_ms,
    read_rows,
    substring(query, 1, 300) AS query
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today() - INTERVAL 7 DAY
  AND (
    toDayOfWeek(event_time) IN (6, 7)
    OR toHour(event_time) >= 22 OR toHour(event_time) < 8
  )
  AND query_duration_ms > 10000  -- 超过 10 秒
ORDER BY event_time DESC;

-- ========================================
-- 查找所有非复制表
-- ========================================

-- 查询来自新 IP 的访问（需要历史数据对比）
SELECT
    remote_address,
    count() AS query_count,
    any(user) AS user,
    min(event_time) AS first_seen,
    max(event_time) AS last_seen,
    any(substring(query, 1, 200)) AS example_query
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today() - INTERVAL 1 DAY
  AND remote_address != ''
GROUP BY remote_address
HAVING count() < 10  -- 少量查询
ORDER BY first_seen DESC;

-- 高频访问 IP
SELECT
    remote_address,
    user,
    count() AS query_count,
    sum(query_duration_ms) / 1000 AS total_duration_sec
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today()
  AND remote_address != ''
GROUP BY remote_address, user
HAVING count() > 1000  -- 超过 1000 次查询
ORDER BY query_count DESC;

-- ========================================
-- 查找所有非复制表
-- ========================================

-- 访问敏感表的查询（需要根据实际业务定义敏感表）
SELECT
    user,
    database,
    table,
    count() AS access_count,
    avg(query_duration_ms) AS avg_duration_ms,
    sum(read_rows) AS total_read_rows
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today()
  AND (
    -- 访问敏感表（需要根据实际情况修改）
    query ILIKE '%user%'
    OR query ILIKE '%password%'
    OR query ILIKE '%credit%'
    OR query ILIKE '%transaction%'
  )
GROUP BY user, database, table
ORDER BY access_count DESC;

-- 大量数据导出检测
SELECT
    user,
    count() AS export_query_count,
    sum(written_rows) AS total_written_rows,
    sum(written_bytes) AS total_written_bytes,
    formatReadableSize(sum(written_bytes)) AS readable_total_bytes
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today()
  AND (
    query ILIKE '%INTO OUTFILE%'
    OR query ILIKE '%clickhouse-local%'
  )
GROUP BY user
HAVING total_written_bytes > 1073741824  -- 超过 1GB
ORDER BY total_written_bytes DESC;

-- ========================================
-- 查找所有非复制表
-- ========================================

-- 创建滥用检测汇总视图
CREATE VIEW monitoring.abuse_detection_summary AS
SELECT
    'Non-replicated tables' AS abuse_type,
    count() AS abuse_count,
    sum(total_bytes) AS total_bytes,
    formatReadableSize(sum(total_bytes)) AS readable_size
FROM system.tables
WHERE database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
  AND engine NOT LIKE '%Replicated%'
  AND engine NOT LIKE '%View%'
  AND engine NOT LIKE '%Dictionary%'

UNION ALL
SELECT
    'Transaction JOIN queries' AS abuse_type,
    count() AS abuse_count,
    sum(read_bytes) AS total_bytes,
    formatReadableSize(sum(read_bytes)) AS readable_size
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today()
  AND query ILIKE '%JOIN%'
  AND (
    query ILIKE '%transactions%'
    OR query ILIKE '%transaction%'
  )

UNION ALL
SELECT
    'Full table scans' AS abuse_type,
    count() AS abuse_count,
    sum(read_bytes) AS total_bytes,
    formatReadableSize(sum(read_bytes)) AS readable_size
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today()
  AND read_rows > 100000
  AND result_rows < 1000
  AND read_rows / result_rows > 100

UNION ALL
SELECT
    'High memory queries' AS abuse_type,
    count() AS abuse_count,
    sum(memory_usage) AS total_bytes,
    formatReadableSize(sum(memory_usage)) AS readable_size
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today()
  AND memory_usage > 1073741824;
