-- ================================================
-- top_cpu_queries_examples.sql
-- 从 top_cpu_queries.md 提取的 SQL 示例
-- 提取时间: 2026-01-23 14:40:17
-- ================================================


-- ========================================
-- 方法 1: 使用 query_duration_ms 估算（简单）
-- ========================================

-- 方法 1: 使用查询执行时间估算 CPU 使用
-- 这是最简单的方法，假设查询时间越长，CPU 使用越高
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
  AND event_time >= now() - INTERVAL 24 HOUR
ORDER BY query_duration_ms DESC
LIMIT 20;

-- ========================================
-- 方法 1: 使用 query_duration_ms 估算（简单）
-- ========================================

-- 方法 2: 使用 query_thread_log 获取线程级别的 CPU 时间
-- 这个方法更准确，因为它记录了实际 CPU 使用时间
SELECT
    q.query_id,
    q.user,
    sum(qt.cpu_time_ns) / 1000000000 AS total_cpu_seconds,
    sum(qt.cpu_time_ns) / 1000000 AS total_cpu_ms,
    q.query_duration_ms / 1000 AS duration_sec,
    sum(qt.cpu_time_ns) / 1000000000 / (q.query_duration_ms / 1000) AS cpu_utilization_percent,
    q.read_rows,
    q.read_bytes,
    q.memory_usage,
    substring(q.query, 1, 500) AS query
FROM system.query_log AS q
INNER JOIN system.query_thread_log AS qt
    ON q.query_id = qt.query_id
WHERE q.type = 'QueryFinish'
  AND q.event_time >= now() - INTERVAL 24 HOUR
GROUP BY q.query_id, q.user, q.query_duration_ms, q.read_rows, q.read_bytes, q.memory_usage, q.query
ORDER BY total_cpu_seconds DESC
LIMIT 20;

-- ========================================
-- 方法 1: 使用 query_duration_ms 估算（简单）
-- ========================================

-- 方法 3: 综合考虑 CPU 时间、查询时间、读取行数等多个指标
SELECT
    query_id,
    user,
    sum(cpu_time_ns) / 1000000000 AS total_cpu_seconds,
    query_duration_ms / 1000 AS duration_sec,
    sum(cpu_time_ns) / 1000000000 / (query_duration_ms / 1000) AS cpu_utilization_percent,
    read_rows,
    read_bytes,
    memory_usage,
    formatReadableSize(read_bytes) AS readable_read_bytes,
    formatReadableSize(memory_usage) AS readable_memory,
    substring(query, 1, 500) AS query
FROM (
    SELECT
        query_id,
        event_time,
        user,
        query_duration_ms,
        read_rows,
        read_bytes,
        memory_usage,
        query
    FROM system.query_log
    WHERE type = 'QueryFinish'
      AND event_time >= now() - INTERVAL 24 HOUR
) AS q
LEFT JOIN (
    SELECT
        query_id,
        sum(cpu_time_ns) AS cpu_time_ns
    FROM system.query_thread_log
    WHERE event_time >= now() - INTERVAL 24 HOUR
    GROUP BY query_id
) AS qt ON q.query_id = qt.query_id
ORDER BY total_cpu_seconds DESC
LIMIT 20;

-- ========================================
-- 方法 1: 使用 query_duration_ms 估算（简单）
-- ========================================

-- 方法 4: 按用户统计 CPU 使用情况
SELECT
    user,
    count() AS query_count,
    sum(cpu_time_ns) / 1000000000 AS total_cpu_seconds,
    sum(cpu_time_ns) / 1000000000 / 3600 AS total_cpu_hours,
    avg(cpu_time_ns) / 1000000 AS avg_cpu_ms,
    sum(query_duration_ms) / 1000 / 3600 AS total_duration_hours,
    max(query_duration_ms) / 1000 AS max_duration_sec,
    any(substring(query, 1, 200)) AS example_query
FROM (
    SELECT
        q.query_id,
        q.user,
        q.query_duration_ms,
        q.query,
        qt.cpu_time_ns
    FROM system.query_log AS q
    LEFT JOIN system.query_thread_log AS qt
        ON q.query_id = qt.query_id
    WHERE q.type = 'QueryFinish'
      AND q.event_time >= now() - INTERVAL 24 HOUR
)
GROUP BY user
ORDER BY total_cpu_seconds DESC;

-- ========================================
-- 方法 1: 使用 query_duration_ms 估算（简单）
-- ========================================

-- 方法 5: 识别重复的高 CPU 查询（可优化为缓存）
SELECT
    normalized_query,
    count() AS query_count,
    sum(cpu_time_ns) / 1000000000 AS total_cpu_seconds,
    avg(cpu_time_ns) / 1000 AS avg_cpu_ms,
    sum(query_duration_ms) / 1000 AS total_duration_sec,
    any(user) AS example_user,
    any(substring(query, 1, 300)) AS example_query
FROM (
    SELECT
        -- 简化查询以识别模式（替换数字、字符串为 ?）
        replaceRegexpOne(
            replaceRegexpOne(query, '\\d+', '?'),
            '\'[^\']*\'', '?'
        ) AS normalized_query,
        query,
        user,
        query_duration_ms,
        qt.cpu_time_ns
    FROM system.query_log AS q
    LEFT JOIN system.query_thread_log AS qt
        ON q.query_id = qt.query_id
    WHERE q.type = 'QueryFinish'
      AND q.event_time >= now() - INTERVAL 24 HOUR
      AND qt.cpu_time_ns > 1000000000  -- CPU 时间超过 1 秒
)
GROUP BY normalized_query
HAVING total_cpu_seconds > 10  -- 总 CPU 时间超过 10 秒
ORDER BY total_cpu_seconds DESC
LIMIT 20;

-- ========================================
-- 方法 1: 使用 query_duration_ms 估算（简单）
-- ========================================

-- 方法 6: 找出 CPU 利用率高的查询
-- CPU 利用率 = 总 CPU 时间 / 查询执行时间
SELECT
    query_id,
    user,
    sum(cpu_time_ns) / 1000000000 AS total_cpu_seconds,
    query_duration_ms / 1000 AS duration_sec,
    (sum(cpu_time_ns) / 1000000000) / (query_duration_ms / 1000) AS cpu_utilization_percent,
    read_rows,
    read_bytes,
    memory_usage,
    substring(query, 1, 500) AS query
FROM (
    SELECT
        q.query_id,
        q.user,
        q.query_duration_ms,
        q.read_rows,
        q.read_bytes,
        q.memory_usage,
        q.query
    FROM system.query_log AS q
    WHERE q.type = 'QueryFinish'
      AND q.event_time >= now() - INTERVAL 24 HOUR
) AS q
INNER JOIN (
    SELECT
        query_id,
        sum(cpu_time_ns) AS cpu_time_ns
    FROM system.query_thread_log
    WHERE event_time >= now() - INTERVAL 24 HOUR
    GROUP BY query_id
) AS qt ON q.query_id = qt.query_id
WHERE (sum(cpu_time_ns) / 1000000000) / (query_duration_ms / 1000) > 0.5  -- CPU 利用率 > 50%
ORDER BY total_cpu_seconds DESC
LIMIT 20;

-- ========================================
-- 方法 1: 使用 query_duration_ms 估算（简单）
-- ========================================

-- 方法 7: 分析过去24小时内 CPU 使用趋势
SELECT
    toStartOfHour(event_time) AS hour,
    count() AS query_count,
    sum(cpu_time_ns) / 1000000000 AS total_cpu_seconds,
    sum(cpu_time_ns) / 1000000000 / 3600 AS total_cpu_hours,
    avg(cpu_time_ns) / 1000000 AS avg_cpu_ms,
    avg(query_duration_ms) / 1000 AS avg_duration_sec,
    sum(read_rows) AS total_read_rows,
    sum(read_bytes) AS total_read_bytes
FROM (
    SELECT
        q.event_time,
        q.query_id,
        q.query_duration_ms,
        q.read_rows,
        q.read_bytes,
        qt.cpu_time_ns
    FROM system.query_log AS q
    INNER JOIN system.query_thread_log AS qt
        ON q.query_id = qt.query_id
    WHERE q.type = 'QueryFinish'
      AND q.event_time >= now() - INTERVAL 24 HOUR
)
GROUP BY hour
ORDER BY hour;

-- ========================================
-- 方法 1: 使用 query_duration_ms 估算（简单）
-- ========================================

-- 方法 8: 找出 CPU 使用率最高的用户
SELECT
    user,
    count() AS query_count,
    sum(cpu_time_ns) / 1000000000 AS total_cpu_seconds,
    sum(cpu_time_ns) / 1000000000 / 3600 AS total_cpu_hours,
    avg(cpu_time_ns) / 1000 AS avg_cpu_ms,
    sum(query_duration_ms) / 1000 / 3600 AS total_duration_hours,
    sum(read_bytes) AS total_read_bytes,
    sum(memory_usage) AS total_memory_usage
FROM (
    SELECT
        q.user,
        q.query_duration_ms,
        q.read_bytes,
        q.memory_usage,
        qt.cpu_time_ns
    FROM system.query_log AS q
    INNER JOIN system.query_thread_log AS qt
        ON q.query_id = qt.query_id
    WHERE q.type = 'QueryFinish'
      AND q.event_time >= now() - INTERVAL 24 HOUR
)
GROUP BY user
ORDER BY total_cpu_seconds DESC;

-- ========================================
-- 方法 1: 使用 query_duration_ms 估算（简单）
-- ========================================

-- 方法 9: 找出既慢又高 CPU 的查询（最需要优化的查询）
SELECT
    query_id,
    user,
    sum(cpu_time_ns) / 1000000000 AS total_cpu_seconds,
    query_duration_ms / 1000 AS duration_sec,
    (sum(cpu_time_ns) / 1000000000) / (query_duration_ms / 1000) AS cpu_utilization_percent,
    read_rows,
    result_rows,
    read_rows / greatest(result_rows, 1) AS read_ratio,
    substring(query, 1, 500) AS query
FROM (
    SELECT
        q.query_id,
        q.user,
        q.query_duration_ms,
        q.read_rows,
        q.result_rows,
        q.query
    FROM system.query_log AS q
    WHERE q.type = 'QueryFinish'
      AND q.event_time >= now() - INTERVAL 24 HOUR
      AND q.query_duration_ms > 30000  -- 执行时间超过 30 秒
) AS q
INNER JOIN (
    SELECT
        query_id,
        sum(cpu_time_ns) AS cpu_time_ns
    FROM system.query_thread_log
    WHERE event_time >= now() - INTERVAL 24 HOUR
    GROUP BY query_id
) AS qt ON q.query_id = qt.query_id
WHERE total_cpu_seconds > 10  -- 总 CPU 时间超过 10 秒
ORDER BY total_cpu_seconds DESC
LIMIT 20;

-- ========================================
-- 方法 1: 使用 query_duration_ms 估算（简单）
-- ========================================

-- 方法 10: 分析 CPU 使用与读取数据的比例（查询效率）
SELECT
    query_id,
    user,
    sum(cpu_time_ns) / 1000000000 AS total_cpu_seconds,
    read_rows,
    read_bytes,
    total_cpu_seconds / (read_bytes / 1024 / 1024) AS cpu_per_mb_read,  -- 每 MB 数据的 CPU 秒数
    query_duration_ms / 1000 AS duration_sec,
    substring(query, 1, 500) AS query
FROM (
    SELECT
        q.query_id,
        q.user,
        q.read_rows,
        q.read_bytes,
        q.query_duration_ms,
        q.query
    FROM system.query_log AS q
    WHERE q.type = 'QueryFinish'
      AND q.event_time >= now() - INTERVAL 24 HOUR
      AND q.read_bytes > 1048576  -- 读取超过 1MB
) AS q
INNER JOIN (
    SELECT
        query_id,
        sum(cpu_time_ns) AS cpu_time_ns
    FROM system.query_thread_log
    WHERE event_time >= now() - INTERVAL 24 HOUR
    GROUP BY query_id
) AS qt ON q.query_id = qt.query_id
ORDER BY total_cpu_seconds DESC
LIMIT 20;

-- ========================================
-- 方法 1: 使用 query_duration_ms 估算（简单）
-- ========================================

-- 推荐：使用 query_thread_log 获取准确的 CPU 时间
SELECT
    q.query_id,
    q.user,
    sum(qt.cpu_time_ns) / 1000000000 AS total_cpu_seconds,
    q.query_duration_ms / 1000 AS duration_sec,
    (sum(qt.cpu_time_ns) / 1000000000) / (q.query_duration_ms / 1000) AS cpu_utilization_percent,
    q.read_rows,
    q.read_bytes,
    formatReadableSize(q.read_bytes) AS readable_bytes,
    formatReadableSize(q.memory_usage) AS readable_memory,
    substring(q.query, 1, 500) AS query
FROM system.query_log AS q
INNER JOIN system.query_thread_log AS qt
    ON q.query_id = qt.query_id
WHERE q.type = 'QueryFinish'
  AND q.event_time >= now() - INTERVAL 24 HOUR
GROUP BY q.query_id, q.user, q.query_duration_ms, q.read_rows, q.read_bytes, q.memory_usage, q.query
ORDER BY total_cpu_seconds DESC
LIMIT 20;

-- ========================================
-- 方法 1: 使用 query_duration_ms 估算（简单）
-- ========================================

-- 简化版本：使用查询执行时间估算
SELECT
    query_id,
    user,
    query_duration_ms / 1000 AS duration_sec,
    read_rows,
    read_bytes,
    formatReadableSize(read_bytes) AS readable_bytes,
    formatReadableSize(memory_usage) AS readable_memory,
    substring(query, 1, 500) AS query
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_time >= now() - INTERVAL 24 HOUR
ORDER BY query_duration_ms DESC
LIMIT 20;
