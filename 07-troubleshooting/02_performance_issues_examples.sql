-- ================================================
-- 02_performance_issues_examples.sql
-- 从 02_performance_issues.md 提取的 SQL 示例
-- 提取时间: 2026-01-23 14:39:51
-- ================================================


-- ========================================
-- 诊断
-- ========================================

-- 查看当前正在执行的查询
SELECT
    query_id,
    user,
    query,
    elapsed,
    read_rows,
    formatReadableSize(read_bytes) as bytes_read,
    formatReadableSize(memory_usage) as memory
FROM system.processes
ORDER BY elapsed DESC;

-- 查看慢查询历史
SELECT
    query_duration_ms / 1000 as duration_seconds,
    query,
    read_rows,
    formatReadableSize(read_bytes) as bytes_read
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query_duration_ms > 1000
  AND event_time > now() - INTERVAL 1 DAY
ORDER BY query_duration_ms DESC
LIMIT 20;

-- ========================================
-- 诊断
-- ========================================

-- 查看内存使用
SELECT
    formatReadableSize(total_memory) as total,
    formatReadableSize(free_memory) as free,
    formatReadableSize(total_memory - free_memory) as used
FROM system.memory;

-- 查看查询内存使用
SELECT
    query_id,
    query,
    formatReadableSize(memory_usage) as memory
FROM system.processes
ORDER BY memory_usage DESC;
