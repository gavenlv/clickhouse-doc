-- ================================================================================
-- ClickHouse 系统监控查询示例
-- ================================================================================
-- 
-- 集群: treasurycluster (2 副本)
-- 预计学习时间: 20 分钟
-- 
-- 本文件涵盖:
--   1. CPU 监控查询 - 实时CPU、CPU趋势
--   2. 内存监控查询 - 内存使用、内存趋势
--   3. 磁盘监控查询 - 磁盘空间、磁盘IO
--   4. 网络监控查询 - 网络流量、连接数
--   5. 系统事件监控 - 关键事件统计
--   6. 异步指标监控 - 周期性指标
-- 
-- 监控查询使用指南:
-- 
--   ┌─────────────────────────────────────────────────────────────────────────┐
--   │                    监控查询使用场景                                     │
--   └─────────────────────────────────────────────────────────────────────────┘
--   
--   1. 实时监控: 使用 system.metrics
--   ┌────────────────────────────────────────────────────────────────────────┐
--   │ SELECT * FROM system.metrics WHERE metric = 'Query';                   │
--   │ -- 查看当前正在执行的查询数                                             │
--   └────────────────────────────────────────────────────────────────────────┘
--   
--   2. 历史趋势: 使用 system.asynchronous_metrics_log
--   ┌────────────────────────────────────────────────────────────────────────┐
--   │ SELECT event_time, value FROM system.asynchronous_metrics_log          │
--   │ WHERE metric = 'OSCPUVirtualTimeMicroseconds'                          │
--   │ AND event_time >= now() - INTERVAL 1 HOUR;                             │
--   │ -- 查看最近1小时的CPU使用趋势                                           │
--   └────────────────────────────────────────────────────────────────────────┘
--   
--   3. 累计统计: 使用 system.events
--   ┌────────────────────────────────────────────────────────────────────────┐
--   │ SELECT event, value FROM system.events                                 │
--   │ WHERE event LIKE '%Query%';                                            │
--   │ -- 查看查询相关的累计事件                                               │
--   └────────────────────────────────────────────────────────────────────────┘
-- 
-- ================================================================================

-- ================================================
-- 系统资源监控查询示例
-- 从 01_system_monitoring.md 提取的监控查询
-- ================================================

-- ========================================
-- 1. CPU 监控
-- ========================================

-- 实时 CPU 使用情况
SELECT
    metric,
    formatReadableQuantity(value) AS cpu_usage
FROM system.asynchronous_metrics
WHERE metric LIKE 'OSCPU%'
ORDER BY metric;

-- CPU 使用趋势（最近 1 小时）
-- 注意：asynchronous_metrics_log 可能不可用，使用异步指标
SELECT
    metric,
    avg(value) AS avg_cpu_usage,
    max(value) AS max_cpu_usage,
    min(value) AS min_cpu_usage
FROM system.asynchronous_metrics
WHERE metric = 'OSCPUVirtualTimeMicroseconds'
GROUP BY metric
ORDER BY metric;

-- ========================================
-- 2. 内存监控
-- ========================================

-- 当前内存使用情况
SELECT
    metric,
    formatReadableQuantity(value) AS readable_value
FROM system.asynchronous_metrics
WHERE metric IN (
    'OSMemoryActive',
    'OSMemoryCached',
    'OSMemoryFree',
    'OSMemoryInactive',
    'OSMemoryTotal',
    'OSMemoryWired'
)
ORDER BY metric;

-- 内存使用趋势
-- 注意：system.asynchronous_metrics_log 可能不可用
-- 替代方案：使用 system.query_log 分析内存使用趋势
SELECT
    toHour(event_time) AS hour,
    avg(memory_usage) AS avg_memory_usage,
    max(memory_usage) AS max_memory_usage,
    count() AS query_count
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today()
GROUP BY hour
ORDER BY hour;

-- ========================================
-- 3. 磁盘监控
-- ========================================

-- 磁盘空间使用
SELECT
    name AS disk_name,
    formatReadableSize(total_space) AS total_space,
    formatReadableSize(available_space) AS available_space,
    available_space * 100.0 / total_space AS available_percent,
    formatReadableSize(keep_free_space) AS keep_free_space
FROM system.disks
ORDER BY name;

-- 表空间使用 Top 10
SELECT
    database,
    table,
    formatReadableSize(sum(bytes_on_disk)) AS total_size,
    count() AS part_count
FROM system.parts
WHERE active = 1
GROUP BY database, table
ORDER BY sum(bytes_on_disk) DESC
LIMIT 10;

-- 数据库空间使用
SELECT
    database,
    formatReadableSize(sum(bytes_on_disk)) AS total_size,
    count() AS table_count,
    count(DISTINCT table) AS distinct_tables
FROM system.parts
WHERE active = 1
GROUP BY database
ORDER BY sum(bytes_on_disk) DESC;

-- ========================================
-- 4. 集群健康监控
-- ========================================

-- 查看集群状态
SELECT
    cluster,
    shard_num,
    replica_num,
    host_name,
    port,
    user,
    errors_count,
    slowdowns_count
FROM system.clusters
ORDER BY cluster, shard_num, replica_num;

-- 查看副本状态
SELECT
    database,
    table,
    is_leader,
    can_become_leader,
    is_readonly,
    is_session_expired,
    queue_size,
    absolute_delay
FROM system.replicas
WHERE database NOT IN ('system', 'information_schema', 'default')
ORDER BY database, table;

-- ========================================
-- 5. 查询性能监控
-- ========================================

-- 慢查询 Top 10
SELECT
    user,
    query_id,
    formatReadableSize(read_bytes) AS read_bytes,
    formatReadableSize(written_bytes) AS written_bytes,
    query_duration_ms / 1000.0 AS duration_sec,
    substring(query, 1, 200) AS query
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today()
  AND query_duration_ms > 1000
ORDER BY query_duration_ms DESC
LIMIT 10;

-- 高内存使用查询 Top 10
SELECT
    user,
    query_id,
    formatReadableSize(memory_usage) AS memory_usage,
    query_duration_ms / 1000.0 AS duration_sec,
    substring(query, 1, 200) AS query
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today()
ORDER BY memory_usage DESC
LIMIT 10;
