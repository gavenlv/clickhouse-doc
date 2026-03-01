-- ========================================
-- 导入性能监控 SQL 脚本
-- ========================================
-- 说明：提供完整的性能监控SQL，用于实时监控导入进度和性能
-- ========================================

-- ========================================
-- 1. 实时监控导入进度
-- ========================================

-- 1.1 查看当前正在执行的导入任务
SELECT 
    query_id,
    query,
    read_rows,
    written_rows,
    formatReadableSize(read_bytes) as read_size,
    formatReadableSize(written_bytes) as written_size,
    memory_usage,
    formatReadableSize(memory_usage) as memory,
    query_duration_ms / 1000 as duration_sec,
    round(written_rows / (query_duration_ms / 1000), 0) as rows_per_sec
FROM system.processes
WHERE query LIKE '%INSERT%'
ORDER BY query_duration_ms DESC;

-- 1.2 监控资源使用
SELECT 
    metric,
    value,
    description
FROM system.metrics
WHERE metric IN (
    'MemoryTracking',
    'TotalThreads',
    'TotalQueries',
    'CPUUsage',
    'ReadonlyReplica',
    'ReplicasQueue'
);

-- 1.3 监控磁盘IO
SELECT 
    filesystem,
    sum(read_bytes) as read_bytes,
    sum(write_bytes) as write_bytes,
    formatReadableSize(sum(read_bytes)) as read_size,
    formatReadableSize(sum(write_bytes)) as write_size
FROM system.filesystem
GROUP BY filesystem;

-- ========================================
-- 2. 历史性能分析
-- ========================================

-- 2.1 查看最近的导入性能
SELECT 
    event_time,
    query_duration_ms / 1000 as duration_sec,
    written_rows,
    formatReadableSize(written_bytes) as size,
    round(written_rows / (query_duration_ms / 1000), 0) as rows_per_sec,
    memory_usage,
    formatReadableSize(memory_usage) as memory,
    substring(query, 1, 100) as query_preview
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query LIKE '%INSERT%'
  AND event_time >= now() - INTERVAL 24 HOUR
ORDER BY event_time DESC
LIMIT 20;

-- 2.2 按小时统计导入性能
SELECT 
    toStartOfHour(event_time) as hour,
    count() as insert_count,
    sum(written_rows) as total_rows,
    formatReadableSize(sum(written_bytes)) as total_size,
    avg(query_duration_ms) / 1000 as avg_duration_sec,
    max(query_duration_ms) / 1000 as max_duration_sec,
    sum(written_rows) / sum(query_duration_ms / 1000) as avg_rows_per_sec
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query LIKE '%INSERT%'
  AND event_time >= now() - INTERVAL 7 DAY
GROUP BY hour
ORDER BY hour DESC;

-- 2.3 性能趋势分析
SELECT 
    event_date,
    count() as insert_count,
    sum(written_rows) as total_rows,
    avg(query_duration_ms) / 1000 as avg_duration_sec,
    sum(written_rows) / sum(query_duration_ms / 1000) as rows_per_sec
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query LIKE '%INSERT%'
GROUP BY event_date
ORDER BY event_date DESC
LIMIT 30;

-- ========================================
-- 3. 表和分区监控
-- ========================================

-- 3.1 查看表的数据量
SELECT 
    database,
    table,
    count() as parts,
    sum(rows) as rows,
    formatReadableSize(sum(data_compressed_bytes)) as compressed_size,
    formatReadableSize(sum(data_uncompressed_bytes)) as uncompressed_size,
    sum(data_uncompressed_bytes) / sum(data_compressed_bytes) as compression_ratio
FROM system.parts
WHERE active = 1
GROUP BY database, table
ORDER BY sum(data_compressed_bytes) DESC;

-- 3.2 查看分区详情
SELECT 
    database,
    table,
    partition,
    count() as parts,
    sum(rows) as rows,
    formatReadableSize(sum(data_compressed_bytes)) as size
FROM system.parts
WHERE active = 1
GROUP BY database, table, partition
ORDER BY partition DESC
LIMIT 20;

-- 3.3 查看列统计
SELECT 
    database,
    table,
    name as column_name,
    type,
    sum(rows) as rows,
    formatReadableSize(sum(column_data_compressed_bytes)) as compressed,
    formatReadableSize(sum(column_data_uncompressed_bytes)) as uncompressed,
    sum(column_data_uncompressed_bytes) / sum(column_data_compressed_bytes) as compression_ratio
FROM system.parts_columns
WHERE active = 1
GROUP BY database, table, name, type
ORDER BY sum(column_data_compressed_bytes) DESC
LIMIT 20;

-- ========================================
-- 4. 副本状态监控
-- ========================================

-- 4.1 查看所有副本状态
SELECT 
    database,
    table,
    engine,
    replica_name,
    replica_path,
    total_replicas,
    active_replicas,
    queue_size,
    inserts_in_queue,
    merges_in_queue
FROM system.replicas
ORDER BY database, table;

-- 4.2 查看副本队列
SELECT 
    database,
    table,
    replica_name,
    queue_size,
    inserts_in_queue,
    merges_in_queue,
    parts_to_check,
    queue_oldest_time
FROM system.replicas
WHERE queue_size > 0
ORDER BY queue_size DESC;

-- ========================================
-- 5. 性能瓶颈分析
-- ========================================

-- 5.1 慢查询分析
SELECT 
    event_time,
    query_duration_ms / 1000 as duration_sec,
    read_rows,
    written_rows,
    memory_usage,
    formatReadableSize(memory_usage) as memory,
    substring(query, 1, 200) as query_preview,
    exception
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query_duration_ms > 60000  -- 超过1分钟
ORDER BY query_duration_ms DESC
LIMIT 10;

-- 5.2 内存消耗大的查询
SELECT 
    event_time,
    query_duration_ms / 1000 as duration_sec,
    memory_usage,
    formatReadableSize(memory_usage) as memory,
    read_rows,
    written_rows,
    substring(query, 1, 200) as query_preview
FROM system.query_log
WHERE type = 'QueryFinish'
ORDER BY memory_usage DESC
LIMIT 10;

-- 5.3 错误查询分析
SELECT 
    event_time,
    query_duration_ms / 1000 as duration_sec,
    substring(query, 1, 200) as query_preview,
    exception
FROM system.query_log
WHERE type = 'ExceptionWhileProcessing'
ORDER BY event_time DESC
LIMIT 10;

-- ========================================
-- 6. 集群状态监控
-- ========================================

-- 6.1 查看集群节点状态
SELECT 
    cluster,
    shard_num,
    replica_num,
    host_name,
    host_address,
    port,
    errors_count
FROM system.clusters
ORDER BY cluster, shard_num, replica_num;

-- 6.2 查看分布式DDL队列
SELECT 
    entry,
    host_name,
    host_address,
    status,
    cluster,
    query,
    initiator
FROM system.distributed_ddl_queue
ORDER BY entry DESC
LIMIT 10;

-- ========================================
-- 7. 实时性能指标
-- ========================================

-- 7.1 当前系统指标
SELECT 
    metric,
    value,
    description,
    formatReadableSize(value) as readable_value
FROM system.metrics
WHERE metric NOT LIKE '%Event%'
ORDER BY metric;

-- 7.2 当前异步指标
SELECT 
    metric,
    value,
    description
FROM system.asynchronous_metrics
WHERE metric LIKE '%Memory%'
   OR metric LIKE '%CPU%'
   OR metric LIKE '%Uptime%'
ORDER BY metric;

-- 7.3 当前事件计数
SELECT 
    event,
    value,
    description
FROM system.events
WHERE value > 0
ORDER BY value DESC
LIMIT 20;

-- ========================================
-- 8. 导入进度跟踪
-- ========================================

-- 8.1 创建导入进度表（可选）
CREATE TABLE IF NOT EXISTS import_progress (
    import_id String,
    start_time DateTime,
    end_time Nullable(DateTime),
    total_files UInt32,
    completed_files UInt32,
    total_rows UInt64,
    imported_rows UInt64,
    status String,  -- 'running', 'completed', 'failed'
    error_message Nullable(String)
) ENGINE = MergeTree()
ORDER BY (import_id, start_time);

-- 8.2 更新导入进度
INSERT INTO import_progress 
VALUES ('import_001', now(), NULL, 100, 0, 15000000000, 0, 'running', NULL);

-- 8.3 查询导入进度
SELECT 
    import_id,
    start_time,
    end_time,
    total_files,
    completed_files,
    round(completed_files * 100.0 / total_files, 2) as progress_percent,
    total_rows,
    imported_rows,
    round(imported_rows * 100.0 / total_rows, 2) as rows_percent,
    status,
    error_message
FROM import_progress
ORDER BY start_time DESC;

-- ========================================
-- 9. 性能基准计算
-- ========================================

-- 9.1 计算导入速度
SELECT 
    event_time,
    written_rows,
    query_duration_ms / 1000 as duration_sec,
    round(written_rows / (query_duration_ms / 1000), 0) as rows_per_sec,
    round(written_rows / 1000000.0 / (query_duration_ms / 1000 / 60), 2) as million_rows_per_min
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query LIKE '%INSERT%'
  AND written_rows > 0
ORDER BY event_time DESC
LIMIT 10;

-- 9.2 平均性能
SELECT 
    'Average Performance' as metric,
    avg(written_rows) as avg_rows_per_import,
    avg(query_duration_ms) / 1000 as avg_duration_sec,
    sum(written_rows) / sum(query_duration_ms / 1000) as avg_rows_per_sec,
    count() as total_imports
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query LIKE '%INSERT%'
  AND event_time >= now() - INTERVAL 7 DAY;

-- ========================================
-- 10. 告警查询
-- ========================================

-- 10.1 检查失败的导入
SELECT 
    count() as failed_count,
    sum(if(exception LIKE '%Timeout%', 1, 0)) as timeout_errors,
    sum(if(exception LIKE '%Memory%', 1, 0)) as memory_errors,
    sum(if(exception LIKE '%Connection%', 1, 0)) as connection_errors
FROM system.query_log
WHERE type = 'ExceptionWhileProcessing'
  AND query LIKE '%INSERT%'
  AND event_time >= now() - INTERVAL 1 HOUR;

-- 10.2 检查副本延迟
SELECT 
    database,
    table,
    replica_name,
    queue_size,
    inserts_in_queue
FROM system.replicas
WHERE queue_size > 10
   OR inserts_in_queue > 100;

-- 10.3 检查磁盘空间
SELECT 
    name,
    free_space,
    total_space,
    formatReadableSize(free_space) as free,
    formatReadableSize(total_space) as total,
    round(free_space * 100.0 / total_space, 2) as free_percent
FROM system.disks
WHERE free_space < total_space * 0.1;  -- 空间少于10%
