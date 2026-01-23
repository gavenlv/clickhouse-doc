-- ================================================
-- 08_system_tables_examples.sql
-- 从 08_system_tables.md 提取的 SQL 示例
-- 提取时间: 2026-01-23 14:40:17
-- ================================================


-- ========================================
-- system.databases
-- ========================================

-- 查看所有数据库
SELECT * FROM system.databases;

-- ========================================
-- system.databases
-- ========================================

-- 查看所有表
SELECT database, name, engine, total_rows, total_bytes
FROM system.tables
WHERE database != 'system';

-- ========================================
-- system.databases
-- ========================================

-- 查看列定义
SELECT database, table, name, type, position
FROM system.columns
WHERE database = 'your_database'
ORDER BY table, position;

-- ========================================
-- system.databases
-- ========================================

-- 查看所有函数
SELECT name, alias, is_aggregate, is_nullable
FROM system.functions
WHERE name LIKE 'date%'
ORDER BY name;

-- ========================================
-- system.databases
-- ========================================

-- 查看数据块
SELECT database, table, partition, name, rows, bytes_on_disk, level
FROM system.parts
WHERE active = 1
ORDER BY database, table, partition;

-- ========================================
-- system.databases
-- ========================================

-- 查看数据块的列统计
SELECT database, table, partition, column, sum(rows) AS total_rows
FROM system.parts_columns
WHERE active = 1
GROUP BY database, table, partition, column;

-- ========================================
-- system.databases
-- ========================================

-- 查看分离的数据块
SELECT database, table, partition, name, bytes_on_disk
FROM system.detached_parts
ORDER BY database, table;

-- ========================================
-- system.databases
-- ========================================

-- 查看副本状态
SELECT database, table, is_leader, queue_size, absolute_delay
FROM system.replicas
WHERE database != 'system';

-- ========================================
-- system.databases
-- ========================================

-- 查看复制队列
SELECT database, table, replica_name, position, type
FROM system.replication_queue
ORDER BY position;

-- ========================================
-- system.databases
-- ========================================

-- 查看 ZooKeeper 连接状态
-- 注意：system.zookeeper 在某些配置中可能不可用或返回 400 错误
-- 替代方案：使用 system.replicas 查看复制状态
SELECT database, table, replica_name, is_leader, queue_size, absolute_delay
FROM system.replicas
WHERE database != 'system';

-- ========================================
-- system.databases
-- ========================================

-- 查看运行中的查询
SELECT query_id, user, query, elapsed, read_rows, memory_usage
FROM system.processes
ORDER BY elapsed DESC;

-- ========================================
-- system.databases
-- ========================================

-- 查看查询日志
SELECT event_time, user, query, type, elapsed
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today()
ORDER BY event_time DESC
LIMIT 100;

-- ========================================
-- system.databases
-- ========================================

-- 查看查询线程日志
SELECT event_time, query_id, thread_id, cpu_time_ns, memory_usage
FROM system.query_thread_log
ORDER BY event_time DESC
LIMIT 100;

-- ========================================
-- system.databases
-- ========================================

-- 查看活跃会话
SELECT user, client_hostname, connect_time, query_start_time, query
FROM system.sessions
ORDER BY connect_time DESC;

-- ========================================
-- system.databases
-- ========================================

-- 查看指标快照
SELECT metric, value, description
FROM system.metrics
WHERE metric LIKE '%ClickHouse%'
ORDER BY metric;

-- ========================================
-- system.databases
-- ========================================

-- 查看事件计数器
SELECT event, value, description
FROM system.events
WHERE event LIKE 'Read%'
ORDER BY value DESC;

-- ========================================
-- system.databases
-- ========================================

-- 查看异步指标
SELECT metric, value, description
FROM system.asynchronous_metrics
ORDER BY metric;

-- ========================================
-- system.databases
-- ========================================

-- 查看性能配置文件
SELECT name, settings, readonly
FROM system.profiles
ORDER BY name;

-- ========================================
-- system.databases
-- ========================================

-- 查看磁盘配置
SELECT name, path, free_space, total_space, keep_free_space_bytes
FROM system.disks;

-- ========================================
-- system.databases
-- ========================================

-- 查看跳数索引
SELECT database, table, name, type, expr, granularity
FROM system.data_skipping_indices
WHERE database != 'system';

-- ========================================
-- system.databases
-- ========================================

-- 查看投影数据块
SELECT database, table, projection, partition, rows, bytes_on_disk
FROM system.projection_parts
WHERE active = 1;

-- ========================================
-- system.databases
-- ========================================

-- 查看所有用户
SELECT name, auth_type, profile, quota
FROM system.users
ORDER BY name;

-- ========================================
-- system.databases
-- ========================================

-- 查看所有角色
SELECT name, is_default, grants
FROM system.roles
ORDER BY name;

-- ========================================
-- system.databases
-- ========================================

-- 查看权限授予情况
SELECT user_name, role_name, grant_type, database, table, access_type
FROM system.grants
WHERE database != 'system';

-- ========================================
-- system.databases
-- ========================================

-- 查看行级策略
SELECT database, table, name, filter
FROM system.row_policies
WHERE database != 'system';

-- ========================================
-- system.databases
-- ========================================

-- 查看配额设置
SELECT name, keys, durations
FROM system.quotas
ORDER BY name;

-- ========================================
-- system.databases
-- ========================================

-- 查看配置文件
SELECT name, is_default, settings, readonly
FROM system.settings_profiles
ORDER BY name;

-- ========================================
-- system.databases
-- ========================================

-- 查看变更操作
SELECT database, table, command_type, command, is_done
FROM system.mutations
WHERE database = 'your_database'
ORDER BY created_at DESC;

-- ========================================
-- system.databases
-- ========================================

-- 一键数据库巡检
SELECT
    'Databases' as category,
    count() as count,
    '' as status
FROM system.databases
WHERE name != 'system'

UNION ALL

SELECT
    'Tables',
    count(),
    ''
FROM system.tables
WHERE database != 'system'

UNION ALL

SELECT
    'Replicas',
    count(),
    CASE WHEN sumIf(1, queue_size > 0) > 0 THEN 'WARNING' ELSE 'OK' END
FROM system.replicas
WHERE database != 'system'

UNION ALL

SELECT
    'Running Queries',
    count(),
    CASE WHEN max(elapsed) > 300 THEN 'WARNING' ELSE 'OK' END
FROM system.processes

UNION ALL

SELECT
    'Slow Queries Today',
    count(),
    ''
FROM system.query_log
WHERE type = 'QueryFinish'
  AND elapsed > 10
  AND event_date = today();

-- ========================================
-- system.databases
-- ========================================

-- 存储空间分析
SELECT
    database,
    table,
    formatReadableSize(sum(bytes_on_disk)) AS size,
    formatReadableQuantity(sum(rows)) AS rows,
    count() AS parts
FROM system.parts
WHERE active = 1
GROUP BY database, table
ORDER BY sum(bytes_on_disk) DESC
LIMIT 20;

-- ========================================
-- system.databases
-- ========================================

-- 查询性能分析
SELECT
    user,
    count() AS query_count,
    avg(elapsed) AS avg_elapsed,
    max(elapsed) AS max_elapsed,
    sum(read_bytes) AS total_read_bytes,
    sum(result_bytes) AS total_result_bytes
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today()
GROUP BY user
ORDER BY query_count DESC;

-- ========================================
-- system.databases
-- ========================================

-- 副本健康检查
SELECT
    database,
    table,
    replica_name,
    is_leader,
    queue_size,
    absolute_delay,
    active_replicas,
    total_replicas,
    CASE
        WHEN absolute_delay > 300 THEN 'CRITICAL'
        WHEN absolute_delay > 60 THEN 'WARNING'
        ELSE 'OK'
    END AS status
FROM system.replicas
WHERE database != 'system'
ORDER BY absolute_delay DESC;

-- ========================================
-- system.databases
-- ========================================

-- 资源使用监控
SELECT
    metric,
    value,
    description
FROM system.metrics
WHERE metric IN (
    'ReadBufferFromFileDescriptorBytes',
    'WriteBufferFromFileDescriptorBytes',
    'MemoryTracking',
    'MarkCacheBytes',
    'UncompressedCacheBytes',
    'TCPConnection'
)
ORDER BY metric;

-- ========================================
-- system.databases
-- ========================================

-- 创建物化视图来聚合查询日志
CREATE MATERIALIZED VIEW IF NOT EXISTS query_stats_mv
ENGINE = SummingMergeTree()
PARTITION BY toYYYYMM(event_date)
ORDER BY (event_date, query_kind)
AS SELECT
    toStartOfDay(event_time) AS event_date,
    query_kind,
    count() AS query_count,
    avg(elapsed) AS avg_elapsed,
    max(elapsed) AS max_elapsed,
    sum(read_bytes) AS total_read_bytes
FROM system.query_log
WHERE type = 'QueryFinish'
GROUP BY event_date, query_kind;

-- ========================================
-- system.databases
-- ========================================

-- 清理旧的查询日志
ALTER TABLE system.query_log
DELETE WHERE event_date < today() - INTERVAL 30 DAY;

-- 清理旧的查询线程日志
ALTER TABLE system.query_thread_log
DELETE WHERE event_date < today() - INTERVAL 30 DAY;
