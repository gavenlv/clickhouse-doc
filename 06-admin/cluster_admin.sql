-- ============================================================================
-- ClickHouse 集群管理 SQL 脚本
-- 集群名称: treasurycluster
-- 用途: 日常集群运维、监控、故障排查
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. 集群概览
-- ----------------------------------------------------------------------------

-- 1.1 查看集群配置和节点信息
SELECT
    cluster,
    shard_num,
    replica_num,
    host_name,
    port,
    user,
    default_database,
    connections,
    errors_count,
    estimated_recovery_time
FROM system.clusters
WHERE cluster = 'treasurycluster'
ORDER BY shard_num, replica_num;

-- 1.2 查看集群的副本分布
SELECT
    cluster,
    shard_num,
    COUNT(DISTINCT replica_num) as replica_count,
    groupArray(host_name) as hosts,
    groupArray(port) as ports
FROM system.clusters
WHERE cluster = 'treasurycluster'
GROUP BY cluster, shard_num
ORDER BY shard_num;

-- 1.3 查看当前节点信息
SELECT
    host_name() as current_host,
    version() as version,
    uptime() as uptime_seconds,
    now() as current_time;

-- ----------------------------------------------------------------------------
-- 2. 副本状态监控
-- ----------------------------------------------------------------------------

-- 2.1 查看所有副本的详细状态
SELECT
    database,
    table,
    replica_name,
    is_leader,
    is_readonly,
    is_session_expired,
    queue_size,
    absolute_delay,
    parts_to_delay,
    log_max_index,
    log_pointer,
    log_pointer > 0 ? (log_max_index - log_pointer) : 0 as pending_log_entries
FROM system.replicas
ORDER BY database, table, replica_name;

-- 2.2 查看有延迟的副本（重点关注）
SELECT
    database,
    table,
    replica_name,
    is_leader,
    is_readonly,
    absolute_delay,
    queue_size,
    pending_log_entries
FROM (
    SELECT
        database,
        table,
        replica_name,
        is_leader,
        is_readonly,
        absolute_delay,
        queue_size,
        log_pointer > 0 ? (log_max_index - log_pointer) : 0 as pending_log_entries
    FROM system.replicas
)
WHERE absolute_delay > 0
  OR queue_size > 0
  OR pending_log_entries > 0
ORDER BY absolute_delay DESC, queue_size DESC;

-- 2.3 查看会话过期的副本
SELECT
    database,
    table,
    replica_name,
    is_session_expired,
    queue_size,
    absolute_delay,
    last_queue_update
FROM system.replicas
WHERE is_session_expired = 1
ORDER BY queue_size DESC;

-- 2.4 查看每个表的同步状态
SELECT
    database,
    table,
    groupArray(replica_name) as replicas,
    groupArray(is_leader) as leaders,
    groupArray(absolute_delay) as delays,
    max(absolute_delay) as max_delay,
    sum(queue_size) as total_queue_size
FROM system.replicas
GROUP BY database, table
HAVING max(absolute_delay) > 10 OR sum(queue_size) > 50
ORDER BY max_delay DESC, total_queue_size DESC;

-- ----------------------------------------------------------------------------
-- 3. 表和数据分布
-- ----------------------------------------------------------------------------

-- 3.1 查看所有分布式表
SELECT
    database,
    name as table_name,
    engine,
    total_rows,
    formatReadableSize(total_bytes) as total_size,
    create_table_query
FROM system.tables
WHERE database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
  AND engine = 'Distributed'
ORDER BY database, name;

-- 3.2 查看每个节点的数据量
SELECT
    host_name(),
    sum(rows) as total_rows,
    formatReadableSize(sum(bytes_on_disk)) as total_size,
    count(DISTINCT concat(database, '.', name)) as table_count,
    count(DISTINCT partition) as partition_count
FROM system.parts
WHERE active = 1
GROUP BY host_name()
ORDER BY total_rows DESC;

-- 3.3 查看数据在各分片的分布
SELECT
    database,
    table,
    shard_num,
    sum(rows) as row_count,
    formatReadableSize(sum(bytes_on_disk)) as size,
    count(DISTINCT partition) as partition_count,
    min(partition) as min_partition,
    max(partition) as max_partition
FROM system.parts
WHERE active = 1
  AND database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
GROUP BY database, table, shard_num
ORDER BY database, table, shard_num;

-- 3.4 检查数据倾斜
SELECT
    database,
    table,
    avg(rows_per_shard) as avg_rows,
    stddev(rows_per_shard) as std_dev,
    max(rows_per_shard) - min(rows_per_shard) as max_min_diff,
    (max(rows_per_shard) - min(rows_per_shard)) / avg(rows_per_shard) * 100 as diff_percent
FROM (
    SELECT
        database,
        table,
        shard_num,
        sum(rows) as rows_per_shard
    FROM system.parts
    WHERE active = 1
      AND database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
    GROUP BY database, table, shard_num
)
GROUP BY database, table
HAVING (max(rows_per_shard) - min(rows_per_shard)) / avg(rows_per_shard) > 0.3  -- 差异超过30%
ORDER BY diff_percent DESC;

-- ----------------------------------------------------------------------------
-- 4. ZooKeeper/ClickHouse Keeper 状态
-- ----------------------------------------------------------------------------

-- 4.1 查看 ZooKeeper 连接信息
SELECT
    name,
    host,
    port,
    index,
    connected,
    version,
    latency_avg,
    latency_min,
    latency_max
FROM system.zookeeper
ORDER BY index;

-- 4.2 查看副本队列任务
SELECT
    database,
    table,
    replica_name,
    type,
    source_replica,
    parts_to_do,
    parts_to_do_insert,
    result_part_name,
    result_part_uuid,
    exception_text,
    num_tries,
    last_attempt_time
FROM system.replication_queue
WHERE parts_to_do > 0
ORDER BY parts_to_do DESC
LIMIT 20;

-- 4.3 查看合并任务
SELECT
    database,
    table,
    partition_id,
    result_part_name,
    progress,
    num_parts,
    total_size_bytes_compressed,
    formatReadableSize(total_size_bytes_compressed) as size,
    elapsed,
    is_mutation
FROM system.merges
ORDER BY total_size_bytes_compressed DESC
LIMIT 20;

-- 4.4 查看队列深度
SELECT
    database,
    table,
    replica_name,
    queue_size,
    absolute_delay,
    log_pointer,
    log_max_index,
    (log_max_index - log_pointer) as pending_log_entries,
    parts_to_delay
FROM system.replicas
ORDER BY queue_size DESC;

-- ----------------------------------------------------------------------------
-- 5. 性能监控
-- ----------------------------------------------------------------------------

-- 5.1 当前正在执行的查询
SELECT
    query_id,
    user,
    query,
    elapsed,
    formatReadableSize(read_rows) as read_rows,
    formatReadableSize(read_bytes) as read_bytes,
    formatReadableSize(memory_usage) as memory_usage,
    thread_ids,
    address,
    port
FROM system.processes
WHERE query != ''
ORDER BY elapsed DESC
LIMIT 20;

-- 5.2 慢查询历史（最近24小时，超过1秒的查询）
SELECT
    event_date,
    event_time,
    query_duration_ms / 1000 as duration_seconds,
    query,
    user,
    read_rows,
    formatReadableSize(read_bytes) as bytes_read,
    formatReadableSize(memory_usage) as memory_usage,
    exception_code
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query NOT LIKE '%system.query_log%'
  AND query_duration_ms > 1000
  AND event_time > now() - INTERVAL 1 DAY
ORDER BY event_time DESC
LIMIT 50;

-- 5.3 系统内存使用
SELECT
    formatReadableSize(total_memory) as total_memory,
    formatReadableSize(free_memory) as free_memory,
    formatReadableSize(buffer_allocated_memory) as buffer_allocated,
    formatReadableSize(buffer_allocated_bytes) as buffer_bytes,
    formatReadableSize(untracked_memory) as untracked_memory,
    formatReadableSize(total_memory - free_memory) as used_memory
FROM system.memory;

-- 5.4 磁盘使用情况
SELECT
    name,
    path,
    formatReadableSize(free_space) as free_space,
    formatReadableSize(total_space) as total_space,
    formatReadableSize(keep_free_space) as keep_free,
    formatReadableSize(total_space - free_space) as used_space,
    (total_space - free_space) / total_space * 100 as used_percent
FROM system.disks
ORDER BY name;

-- 5.5 网络传输统计
SELECT
    name,
    formatReadableSize(value) as value
FROM system.asynchronous_metrics
WHERE name LIKE 'Network%'
ORDER BY name DESC;

-- ----------------------------------------------------------------------------
-- 6. 表维护操作
-- ----------------------------------------------------------------------------

-- 6.1 查看表的分区信息
SELECT
    database,
    table,
    partition,
    count(*) as part_count,
    sum(rows) as rows,
    formatReadableSize(sum(bytes_on_disk)) as size,
    formatReadableSize(sum(data_uncompressed_bytes)) as uncompressed_size,
    min(min_date) as min_date,
    max(max_date) as max_date
FROM system.parts
WHERE active = 1
  AND database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
GROUP BY database, table, partition
ORDER BY database, table, partition;

-- 6.2 查看表的碎片化情况
SELECT
    database,
    table,
    count(*) as total_parts,
    countIf(level > 1) as non_level0_parts,
    countIf(level = 0) as level0_parts,
    sum(rows) as total_rows,
    formatReadableSize(sum(bytes_on_disk)) as total_size
FROM system.parts
WHERE active = 1
  AND database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
GROUP BY database, table
HAVING count(*) > 50  -- 超过50个分区认为碎片化严重
ORDER BY total_parts DESC;

-- 6.3 生成 OPTIMIZE 语句（需要手动执行）
-- 注意：OPTIMIZE 是资源密集型操作，请在低峰期执行
SELECT
    'OPTIMIZE TABLE ' || database || '.' || table || ' ON CLUSTER ''treasurycluster'' PARTITION ''' || partition || ''' FINAL;' as optimize_sql
FROM system.parts
WHERE active = 1
  AND database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
  AND count() > 30  -- 只优化分区数超过30的
GROUP BY database, table, partition
ORDER BY database, table, partition
LIMIT 20;

-- ----------------------------------------------------------------------------
-- 7. 故障排查
-- ----------------------------------------------------------------------------

-- 7.1 查看同步失败的详细信息
SELECT
    database,
    table,
    replica_name,
    source_replica,
    result_part_name,
    exception_text,
    exception_code,
    num_tries,
    last_attempt_time,
    last_exception_time
FROM system.replication_queue
WHERE exception_code != 0
ORDER BY last_exception_time DESC
LIMIT 20;

-- 7.2 查看最近的错误日志
SELECT
    event_date,
    event_time,
    level,
    logger_name,
    message,
    thread_id
FROM system.text_log
WHERE level = 'Error'
  AND event_time > now() - INTERVAL 1 HOUR
ORDER BY event_time DESC
LIMIT 50;

-- 7.3 查看表的大小和行数统计
SELECT
    database,
    name as table_name,
    engine,
    formatReadableSize(total_rows) as rows,
    formatReadableSize(total_bytes) as size,
    create_table_query
FROM system.tables
WHERE database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
ORDER BY total_bytes DESC
LIMIT 100;

-- 7.4 查看最近删除的分区（用于故障恢复）
SELECT
    database,
    table,
    partition,
    name,
    level,
    rows,
    bytes_on_disk,
    modification_time
FROM system.parts
WHERE active = 0
  AND database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
ORDER BY modification_time DESC
LIMIT 20;

-- ----------------------------------------------------------------------------
-- 8. 系统事件统计
-- ----------------------------------------------------------------------------

-- 8.1 查看 MergeTree 相关的事件统计
SELECT
    event,
    value,
    description
FROM system.events
WHERE event LIKE '%MergeTree%'
  OR event LIKE '%Replicated%'
ORDER BY value DESC
LIMIT 20;

-- 8.2 查看网络和 I/O 统计
SELECT
    event,
    value,
    description
FROM system.events
WHERE event LIKE 'Network%'
  OR event LIKE 'Disk%'
  OR event LIKE 'File%'
ORDER BY value DESC
LIMIT 30;

-- 8.3 查看查询统计
SELECT
    event,
    value,
    description
FROM system.events
WHERE event LIKE 'Query%'
  OR event LIKE 'Select%'
  OR event LIKE 'Insert%'
ORDER BY value DESC
LIMIT 20;

-- ----------------------------------------------------------------------------
-- 9. 健康检查
-- ----------------------------------------------------------------------------

-- 9.1 整体健康检查
SELECT
    'Replica Delay' as check_type,
    max(absolute_delay) as value,
    CASE
        WHEN max(absolute_delay) > 300 THEN 'CRITICAL'
        WHEN max(absolute_delay) > 60 THEN 'WARNING'
        ELSE 'OK'
    END as status
FROM system.replicas
UNION ALL
SELECT
    'Disk Free',
    min(free_space / total_space * 100),
    CASE
        WHEN min(free_space / total_space) < 0.1 THEN 'CRITICAL'
        WHEN min(free_space / total_space) < 0.2 THEN 'WARNING'
        ELSE 'OK'
    END
FROM system.disks
UNION ALL
SELECT
    'Merge Backlog',
    count(*),
    CASE
        WHEN count(*) > 50 THEN 'CRITICAL'
        WHEN count(*) > 20 THEN 'WARNING'
        ELSE 'OK'
    END
FROM system.merges
UNION ALL
SELECT
    'ZooKeeper Connected',
    sum(connected),
    CASE
        WHEN sum(connected) = 0 THEN 'CRITICAL'
        WHEN sum(connected) < 3 THEN 'WARNING'
        ELSE 'OK'
    END
FROM system.zookeeper
UNION ALL
SELECT
    'Session Expired',
    sum(case when is_session_expired = 1 then 1 else 0 end),
    CASE
        WHEN sum(case when is_session_expired = 1 then 1 else 0 end) > 0 THEN 'CRITICAL'
        ELSE 'OK'
    END
FROM system.replicas;

-- 9.2 关键指标快照
SELECT
    'Total Tables' as metric,
    count(*) as value
FROM system.tables
WHERE database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
UNION ALL
SELECT 'Total Rows', sum(total_rows)
FROM system.tables
WHERE database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
UNION ALL
SELECT 'Total Size', formatReadableSize(sum(total_bytes))
FROM system.tables
WHERE database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
UNION ALL
SELECT 'Replicated Tables', count(*)
FROM system.replicas
UNION ALL
SELECT 'Active Merges', count(*)
FROM system.merges
UNION ALL
SELECT 'Replication Queue', sum(queue_size)
FROM system.replicas
UNION ALL
SELECT 'ZooKeeper Connections', sum(connected)
FROM system.zookeeper;

-- ----------------------------------------------------------------------------
-- 10. 数据清理和维护
-- ----------------------------------------------------------------------------

-- 10.1 生成清理旧分区的 SQL（手动执行）
-- 清理3个月前的分区
SELECT
    'ALTER TABLE ' || database || '.' || table ||
    ' DROP PARTITION ''' || partition || ''' ON CLUSTER ''treasurycluster'';' as cleanup_sql
FROM system.parts
WHERE active = 1
  AND database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
  AND partition <= toString(toYYYYMM(now() - INTERVAL 3 MONTH))
GROUP BY database, table, partition
ORDER BY database, table, partition;

-- 10.2 生成删除旧数据的 SQL（手动执行）
-- 删除30天前的数据（需要根据表的实际情况调整）
SELECT
    'ALTER TABLE ' || database || '.' || name ||
    ' DELETE WHERE event_time < now() - INTERVAL 30 DAY ON CLUSTER ''treasurycluster'';' as cleanup_sql
FROM system.tables
WHERE database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
  AND engine LIKE '%MergeTree%'
  AND name LIKE '%event%'
ORDER BY database, name;

-- 10.3 查看表的 TTL 设置
SELECT
    database,
    table,
    name,
    formatReadableSize(min_bytes) as min_bytes,
    max_bytes,
    if(min_bytes > 0, max_bytes / min_bytes * 100, 0) as compression_ratio
FROM system.ttl_entries
WHERE database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
ORDER BY database, table;

-- ----------------------------------------------------------------------------
-- 11. 用户和权限管理
-- ----------------------------------------------------------------------------

-- 11.1 查看所有用户
SELECT
    name,
    storage,
    default_roles_all,
    auth_type,
    host_ip,
    host_names
FROM system.users
ORDER BY name;

-- 11.2 查看所有角色
SELECT
    name,
    storage,
    count(DISTINCT granted_role) as role_count
FROM system.roles
LEFT JOIN system.role_grants ON system.roles.name = system.role_grants.role_name
GROUP BY name, storage
ORDER BY name;

-- 11.3 查看配额使用情况
SELECT
    quota_name,
    quota_key,
    start_time,
    duration,
    queries,
    query_selects,
    query_inserts,
    max_execution_time,
    max_concurrent_queries
FROM system.quotas_usage
WHERE current = 1
ORDER BY start_time DESC;

-- ----------------------------------------------------------------------------
-- 12. 性能优化相关
-- ----------------------------------------------------------------------------

-- 12.1 查看跳数索引
SELECT
    database,
    table,
    name,
    type,
    expr,
    granularity
FROM system.data_skipping_indices
WHERE database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
ORDER BY database, table;

-- 12.2 查看投影（Projections）
SELECT
    database,
    table,
    name,
    formatReadableSize(data_compressed_bytes) as compressed_size,
    formatReadableSize(data_uncompressed_bytes) as uncompressed_size,
    marks_count
FROM system.projection_parts
WHERE active = 1
ORDER BY database, table, name;

-- 12.3 查看表的统计信息
SELECT
    database,
    name as table_name,
    engine,
    formatReadableSize(total_rows) as rows,
    formatReadableSize(total_bytes) as size,
    create_table_query
FROM system.tables
WHERE database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
  AND engine LIKE '%MergeTree%'
ORDER BY total_bytes DESC;

-- ============================================================================
-- 使用说明
-- ============================================================================
-- 1. 查询类 SQL 可以直接执行
-- 2. DDL 类 SQL（如 DROP PARTITION、OPTIMIZE）需要手动确认后再执行
-- 3. 生产环境建议在低峰期执行维护操作
-- 4. 执行前务必备份数据
-- ============================================================================
