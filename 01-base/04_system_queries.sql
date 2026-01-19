-- ================================================
-- 04_system_queries.sql
-- ClickHouse 系统表查询示例
-- ================================================

-- ========================================
-- 1. 集群信息
-- ========================================
-- 查看所有集群
SELECT * FROM system.clusters ORDER BY cluster, shard_num, replica_num;

-- 查看特定集群
SELECT
    cluster,
    shard_num,
    replica_num,
    host_name,
    port,
    user,
    errors_count,
    estimated_recovery_time
FROM system.clusters
WHERE cluster = 'treasurycluster'
ORDER BY shard_num, replica_num;

-- 统计集群信息
SELECT
    cluster,
    count(DISTINCT shard_num) as total_shards,
    count(DISTINCT replica_num) as total_replicas,
    count(*) as total_nodes,
    sum(errors_count) as total_errors
FROM system.clusters
WHERE cluster = 'treasurycluster';

-- ========================================
-- 2. Macros 配置
-- ========================================
-- 查看所有 macros
SELECT * FROM system.macros;

-- 查看特定 macro
SELECT macro, substitution FROM system.macros WHERE macro IN ('cluster', 'shard', 'replica');

-- 查看默认路径配置
SELECT
    name,
    value,
    changed
FROM system.settings
WHERE name LIKE '%default%'
  AND (name LIKE '%replica%' OR name LIKE '%zookeeper%')
ORDER BY name;

-- ========================================
-- 3. 表信息
-- ========================================
-- 查看所有表
SELECT
    database,
    name as table,
    engine,
    total_rows,
    total_bytes,
    create_table_query
FROM system.tables
WHERE database = 'default'
ORDER BY name;

-- 查看表的详细统计
SELECT
    database,
    table,
    engine,
    partition_key,
    sorting_key,
    primary_key,
    sampling_key
FROM system.tables
WHERE database = 'default'
ORDER BY table;

-- 查看表的存储信息
SELECT
    database,
    table,
    sum(rows) as total_rows,
    sum(bytes_on_disk) as total_bytes,
    count() as total_parts,
    avg(rows) as avg_rows_per_part
FROM system.parts
WHERE database = 'default'
  AND active = 1
GROUP BY database, table
ORDER BY total_rows DESC;

-- ========================================
-- 4. 分区信息
-- ========================================
-- 查看所有分区
SELECT
    database,
    table,
    partition,
    name as part_name,
    rows,
    bytes_on_disk,
    modification_time
FROM system.parts
WHERE database = 'default'
  AND active = 1
ORDER BY table, partition;

-- 统计分区信息
SELECT
    database,
    table,
    partition,
    count() as part_count,
    sum(rows) as total_rows,
    sum(bytes_on_disk) as total_bytes,
    min(modification_time) as first_created,
    max(modification_time) as last_modified
FROM system.parts
WHERE database = 'default'
  AND active = 1
GROUP BY database, table, partition
ORDER BY table, partition;

-- ========================================
-- 5. 复制状态
-- ========================================
-- 查看所有复制表的状态
SELECT
    database,
    table,
    is_leader,
    can_become_leader,
    is_readonly,
    is_session_expired,
    replica_name,
    replica_path,
    queue_size,
    absolute_delay,
    total_replicas,
    active_replicas
FROM system.replicas
ORDER BY database, table;

-- 查看复制队列
SELECT
    database,
    table,
    type,
    replica_name,
    position,
    node_name,
    processed,
    num_events,
    exceptions,
    exception_code
FROM system.replication_queue
ORDER BY table, replica_name, position;

-- 统计复制延迟
SELECT
    database,
    table,
    replica_name,
    is_leader,
    queue_size,
    absolute_delay,
    active_replicas,
    total_replicas,
    formatReadableTimeDelta(absolute_delay) as delay_readable
FROM system.replicas
ORDER BY table, replica_name;

-- ========================================
-- 6. ZooKeeper 路径
-- ========================================
-- 查看所有表的 ZooKeeper 路径
SELECT
    database,
    table,
    replica_name,
    zookeeper_path,
    replica_path,
    leader_election
FROM system.replicas
ORDER BY database, table;

-- 查看 ZooKeeper 节点（如果权限允许）
-- 注意：在 Windows Docker 环境下可能返回 400 错误
SELECT
    name,
    value,
    ctime,
    mtime,
    version,
    dataLength
FROM system.zookeeper
WHERE path = '/'
LIMIT 10;

-- ========================================
-- 7. 进程和查询
-- ========================================
-- 查看当前运行的查询
SELECT
    query_id,
    user,
    query,
    query_start_time,
    elapsed,
    rows_read,
    bytes_read,
    memory_usage,
    thread_ids
FROM system.processes
ORDER BY query_start_time DESC;

-- 查看最近的查询
SELECT
    type,
    query_id,
    user,
    query,
    query_start_time,
    query_duration_ms,
    exception_code
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today()
ORDER BY event_time DESC
LIMIT 20;

-- 统计查询性能
SELECT
    query_kind,
    count() as query_count,
    avg(query_duration_ms) as avg_duration_ms,
    max(query_duration_ms) as max_duration_ms,
    sum(rows_read) as total_rows_read,
    sum(bytes_read) as total_bytes_read
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today()
GROUP BY query_kind
ORDER BY query_count DESC;

-- ========================================
-- 8. 系统负载
-- ========================================
-- 查看 ClickHouse 进程信息
SELECT
    uptime,
    version,
    revision,
    dns_cache_hits,
    dns_cache_misses
FROM system.build_options;

-- 查看内存使用
SELECT
    formatReadableSize(value) as readable_value,
    name,
    description
FROM system.settings
WHERE name LIKE '%memory%';

-- 查看系统指标
SELECT
    event,
    value,
    description
FROM system.events
WHERE event LIKE '%Read%'
  OR event LIKE '%Write%'
  OR event LIKE '%Query%'
ORDER BY value DESC
LIMIT 20;

-- ========================================
-- 9. 异步指标
-- ========================================
-- 查看系统指标（异步）
SELECT
    name,
    value,
    description
FROM system.asynchronous_metrics
WHERE name LIKE '%memory%'
  OR name LIKE '%cpu%'
  OR name LIKE '%disk%'
ORDER BY name;

-- 查看表统计指标
SELECT
    metric,
    value
FROM system.metric_log
WHERE event_date >= today()
ORDER BY event_time DESC
LIMIT 10;

-- ========================================
-- 10. 连接信息
-- ========================================
-- 查看当前连接
SELECT
    user,
    initial_address as remote_host,
    initial_port as remote_port,
    connection_id,
    connected_at,
    query_start_time,
    elapsed,
    is_cancelled
FROM system.connections
ORDER BY connected_at DESC;

-- 查看所有用户
SELECT
    name,
    storage,
    auth_type,
    default_roles
FROM system.users;

-- ========================================
-- 11. 字典信息
-- ========================================
-- 查看所有字典
SELECT
    name,
    database,
    status,
    origin,
    type,
    key,
    attribute_names,
    bytes_allocated,
    query_count
FROM system.dictionaries
ORDER BY name;

-- ========================================
-- 12. 函数信息
-- ========================================
-- 查看所有函数
SELECT
    name,
    case_sensitive,
    is_aggregate
FROM system.functions
WHERE name LIKE 'array%'
ORDER BY name
LIMIT 20;

-- 搜索特定函数
SELECT
    name,
    is_aggregate,
    case_sensitive
FROM system.functions
WHERE name LIKE '%date%'
ORDER BY name
LIMIT 20;

-- ========================================
-- 13. 数据类型信息
-- ========================================
-- 查看所有数据类型
SELECT
    name,
    alias_to
FROM system.data_type_families
ORDER BY name
LIMIT 30;

-- ========================================
-- 14. 磁盘信息
-- ========================================
-- 查看磁盘使用情况
SELECT
    name,
    path,
    total_space,
    unreserved_space,
    keep_free_space,
    formatReadableSize(total_space) as total_readable,
    formatReadableSize(unreserved_space) as unreserved_readable,
    formatReadableSize(keep_free_space) as keep_free_readable
FROM system.disks;

-- 查看磁盘统计
SELECT
    disk_name,
    sum(rows) as total_rows,
    sum(bytes_on_disk) as total_bytes,
    formatReadableSize(sum(bytes_on_disk)) as total_bytes_readable
FROM system.parts
WHERE active = 1
GROUP BY disk_name
ORDER BY total_bytes DESC;

-- ========================================
-- 15. 文件系统信息
-- ========================================
-- 查看文件系统缓存
SELECT
    path,
    size,
    cache_size_bytes,
    formatReadableSize(cache_size_bytes) as cache_readable
FROM system.filesystem_cache;

-- ========================================
-- 16. 设置信息
-- ========================================
-- 查看当前会话设置
SELECT
    name,
    value,
    changed,
    is_readonly
FROM system.settings
ORDER BY name
LIMIT 50;

-- 查看所有可能的设置
SELECT
    name,
    type,
    default_value,
    description
FROM system.settings
WHERE name LIKE '%merge%'
ORDER BY name;

-- ========================================
-- 17. 复制统计
-- ========================================
-- 查看复制统计信息
SELECT
    table,
    replica_name,
    is_leader,
    queue_size,
    absolute_delay,
    parts_to_zookeeper,
    merges_running,
    fetches_running
FROM system.replication_queue
GROUP BY table, replica_name, is_leader, queue_size, absolute_delay
ORDER BY table, replica_name;

-- ========================================
-- 18. 慢查询分析
-- ========================================
-- 查找慢查询（超过 1 秒）
SELECT
    query_id,
    user,
    query_start_time,
    query_duration_ms,
    query,
    exception_text
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query_duration_ms > 1000
  AND event_date >= today()
ORDER BY query_duration_ms DESC
LIMIT 10;

-- 查找读取大量数据的查询
SELECT
    query_id,
    user,
    rows_read,
    bytes_read,
    query_duration_ms,
    substring(query, 1, 100) as query_snippet
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today()
  AND bytes_read > 1000000
ORDER BY bytes_read DESC
LIMIT 10;

-- ========================================
-- 19. 错误日志
-- ========================================
-- 查看最近的错误
SELECT
    event_date,
    event_time,
    query_id,
    exception_code,
    exception_text,
    type
FROM system.query_log
WHERE type = 'ExceptionWhileProcessing'
  AND event_date >= today()
ORDER BY event_time DESC
LIMIT 20;

-- 查看系统日志中的错误
SELECT
    event_date,
    event_time,
    host_name,
    level,
    query_id,
    exception_code,
    message
FROM system.text_log
WHERE level IN ('Error', 'Fatal')
  AND event_date >= today()
ORDER BY event_time DESC
LIMIT 20;

-- ========================================
-- 20. 综合健康检查
-- ========================================
-- 集群健康状态
SELECT
    'Cluster Health' as check_type,
    cluster,
    count(*) as node_count,
    sum(errors_count) as total_errors,
    avg(estimated_recovery_time) as avg_recovery_time
FROM system.clusters
WHERE cluster = 'treasurycluster'
GROUP BY cluster

UNION ALL

-- 复制健康状态
SELECT
    'Replication Health' as check_type,
    database,
    table,
    count(*) as replica_count,
    sum(if(queue_size > 100, 1, 0)) as lagging_replicas,
    sum(if(absolute_delay > 60, 1, 0)) as delayed_replicas
FROM system.replicas
GROUP BY database, table

UNION ALL

-- 表存储状态
SELECT
    'Storage Health' as check_type,
    database,
    table,
    count(*) as partition_count,
    sum(rows) as total_rows,
    formatReadableSize(sum(bytes_on_disk)) as total_size
FROM system.parts
WHERE active = 1
GROUP BY database, table
ORDER BY check_type, database, table;
