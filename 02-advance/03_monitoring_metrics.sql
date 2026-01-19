-- ================================================
-- 03_monitoring_metrics.sql
-- ClickHouse 监控和指标查询
-- ================================================

-- ========================================
-- 1. 系统健康检查
-- ========================================

-- 查看集群状态
SELECT
    cluster,
    shard_num,
    replica_num,
    host_name,
    port,
    errors_count,
    estimated_recovery_time
FROM system.clusters
WHERE cluster = 'treasurycluster'
ORDER BY shard_num, replica_num;

-- 查看 ClickHouse 版本
SELECT version() as version, uptime() as uptime_seconds;

-- 查看表总数和数据量
SELECT
    count() as total_tables,
    sum(rows) as total_rows,
    formatReadableSize(sum(bytes_on_disk)) as total_size
FROM system.parts
WHERE active = 1;

-- 查看数据库统计
SELECT
    database,
    count(DISTINCT table) as table_count,
    sum(rows) as total_rows,
    formatReadableSize(sum(bytes_on_disk)) as total_size
FROM system.parts
WHERE active = 1
GROUP BY database
ORDER BY total_rows DESC;

-- ========================================
-- 2. 查询性能监控
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

-- 查看最近的查询统计
SELECT
    type,
    count() as query_count,
    sum(query_duration_ms) as total_duration_ms,
    avg(query_duration_ms) as avg_duration_ms,
    max(query_duration_ms) as max_duration_ms,
    sum(read_rows) as total_rows_read,
    sum(read_bytes) as total_bytes_read
FROM system.query_log
WHERE event_date >= today()
GROUP BY type
ORDER BY query_count DESC;

-- 慢查询分析（超过 1 秒）
SELECT
    query_id,
    user,
    substring(query, 1, 100) as query_snippet,
    query_duration_ms,
    read_rows,
    read_bytes,
    memory_usage,
    formatReadableSize(read_bytes) as readable_bytes
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query_duration_ms > 1000
  AND event_date >= today()
ORDER BY query_duration_ms DESC
LIMIT 20;

-- 查询性能趋势（按小时）
SELECT
    toHour(event_time) as hour,
    count() as query_count,
    avg(query_duration_ms) as avg_duration_ms,
    max(query_duration_ms) as max_duration_ms
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today()
GROUP BY hour
ORDER BY hour;

-- ========================================
-- 3. 资源使用监控
-- ========================================

-- 内存使用情况
SELECT
    name,
    value,
    formatReadableSize(value) as readable_value,
    description
FROM system.asynchronous_metrics
WHERE name LIKE '%memory%'
ORDER BY name;

-- CPU 使用情况
SELECT
    name,
    value
FROM system.asynchronous_metrics
WHERE name LIKE '%CPU%'
ORDER BY name;

-- 磁盘使用情况
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

-- 网络使用情况
SELECT
    name,
    value
FROM system.asynchronous_metrics
WHERE name LIKE '%Network%'
ORDER BY name;

-- ========================================
-- 4. 表性能指标
-- ========================================

-- 查看表大小排行
SELECT
    database,
    table,
    sum(rows) as total_rows,
    formatReadableSize(sum(bytes_on_disk)) as total_size,
    count() as part_count,
    avg(rows) as avg_rows_per_part
FROM system.parts
WHERE active = 1
GROUP BY database, table
ORDER BY sum(bytes_on_disk) DESC
LIMIT 20;

-- 查看分区大小
SELECT
    database,
    table,
    partition,
    sum(rows) as total_rows,
    formatReadableSize(sum(bytes_on_disk)) as total_size,
    count() as part_count
FROM system.parts
WHERE active = 1
GROUP BY database, table, partition
ORDER BY sum(bytes_on_disk) DESC
LIMIT 30;

-- 查看表的数据分布
SELECT
    database,
    table,
    min(modification_time) as first_created,
    max(modification_time) as last_modified,
    dateDiff('day', first_created, last_modified) as days_active,
    sum(rows) as total_rows
FROM system.parts
WHERE active = 1
GROUP BY database, table
ORDER BY days_active DESC
LIMIT 20;

-- ========================================
-- 5. 复制状态监控
-- ========================================

-- 查看复制状态
SELECT
    database,
    table,
    is_leader,
    can_become_leader,
    is_readonly,
    is_session_expired,
    replica_name,
    queue_size,
    absolute_delay,
    total_replicas,
    active_replicas,
    formatReadableTimeDelta(absolute_delay) as delay_readable
FROM system.replicas
ORDER BY database, table, replica_name;

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
    exception_code,
    exception_text
FROM system.replication_queue
ORDER BY table, replica_name, position
LIMIT 50;

-- 查看复制延迟统计
SELECT
    database,
    table,
    avg(absolute_delay) as avg_delay,
    max(absolute_delay) as max_delay,
    avg(queue_size) as avg_queue_size,
    sum(if(queue_size > 100, 1, 0)) as lagging_replicas
FROM system.replicas
GROUP BY database, table
ORDER BY max_delay DESC;

-- ========================================
-- 6. ZooKeeper 连接监控
-- ========================================

-- 查看 ZooKeeper 连接状态（如果可用）
/*
SELECT
    name,
    value
FROM system.zookeeper
WHERE path = '/';
*/

-- 查看 Keeper 节点信息
SELECT
    count() as keeper_node_count
FROM system.clusters
WHERE cluster = 'treasurykeeper';

-- ========================================
-- 7. 缓存性能
-- ========================================

-- 查看文件系统缓存
SELECT
    path,
    size,
    cache_size_bytes,
    formatReadableSize(cache_size_bytes) as cache_readable,
    read_cache_hit_ratio
FROM system.filesystem_cache;

-- 查看标记缓存
SELECT
    database,
    table,
    sum(marks_bytes) as total_marks_bytes,
    formatReadableSize(sum(marks_bytes)) as marks_readable
FROM system.parts
WHERE active = 1
GROUP BY database, table
ORDER BY total_marks_bytes DESC;

-- ========================================
-- 8. 合并操作监控
-- ========================================

-- 查看合并操作
SELECT
    database,
    table,
    elapsed,
    progress,
    is_mutation,
    num_parts,
    rows_read,
    rows_written,
    bytes_read_uncompressed,
    bytes_written_uncompressed,
    thread_id
FROM system.merges
ORDER BY started
LIMIT 20;

-- 查看合并统计
SELECT
    database,
    table,
    count() as merge_count,
    sum(rows_read) as total_rows_read,
    sum(rows_written) as total_rows_written,
    avg(elapsed) as avg_elapsed_seconds
FROM system.merges
WHERE started >= now() - INTERVAL 1 HOUR
GROUP BY database, table
ORDER BY merge_count DESC;

-- 查看需要合并的数据
SELECT
    database,
    table,
    partition,
    count(*) as unmerged_parts,
    sum(rows) as total_rows,
    sum(bytes_on_disk) as total_bytes
FROM system.parts
WHERE active = 1
  AND level = 0
GROUP BY database, table, partition
ORDER BY total_bytes DESC
LIMIT 20;

-- ========================================
-- 9. Mutation 操作监控
-- ========================================

-- 查看正在执行的 mutation
SELECT
    database,
    table,
    command,
    create_time,
    parts_to_do,
    is_done
FROM system.mutations
WHERE is_done = 0
ORDER BY create_time;

-- 查看 mutation 历史
SELECT
    database,
    table,
    command,
    create_time,
    done_time,
    parts_to_do,
    elapsed,
    exception_code
FROM system.mutations
WHERE done_time >= now() - INTERVAL 1 DAY
ORDER BY create_time DESC;

-- ========================================
-- 10. 错误和异常监控
-- ========================================

-- 查看查询错误
SELECT
    type,
    exception_code,
    count() as error_count,
    max(query_start_time) as last_occurred
FROM system.query_log
WHERE type IN ('ExceptionWhileProcessing', 'ExceptionBeforeStart')
  AND event_date >= today()
GROUP BY type, exception_code
ORDER BY error_count DESC
LIMIT 20;

-- 查看最近的错误详情
SELECT
    event_time,
    type,
    exception_code,
    exception_text,
    query_id,
    substring(query, 1, 100) as query_snippet
FROM system.query_log
WHERE type IN ('ExceptionWhileProcessing', 'ExceptionBeforeStart')
  AND event_date >= today()
ORDER BY event_time DESC
LIMIT 10;

-- 查看系统日志错误
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
-- 11. 并发和连接监控
-- ========================================

-- 查看当前连接数
SELECT
    count() as current_connections,
    count(DISTINCT user) as distinct_users
FROM system.connections;

-- 查看连接详情
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
ORDER BY connected_at DESC
LIMIT 20;

-- 查看等待中的查询
SELECT
    query_id,
    user,
    initial_address,
    initial_port,
    query_start_time,
    elapsed,
    priority
FROM system.waits
ORDER BY query_start_time DESC;

-- ========================================
-- 12. 性能指标汇总
-- ========================================

-- 综合性能报告
SELECT
    'System Health' as category,
    cluster,
    count(*) as value,
    'nodes' as unit
FROM system.clusters
WHERE cluster = 'treasurycluster'
GROUP BY cluster

UNION ALL

SELECT
    'Active Tables',
    count(DISTINCT concat(database, '.', table)),
    'tables',
    'count'
FROM system.parts
WHERE active = 1

UNION ALL

SELECT
    'Total Rows',
    formatReadableSize(sum(rows)),
    'rows',
    'size'
FROM system.parts
WHERE active = 1

UNION ALL

SELECT
    'Total Size',
    formatReadableSize(sum(bytes_on_disk)),
    'bytes',
    'size'
FROM system.parts
WHERE active = 1

UNION ALL

SELECT
    'Queries Today',
    count(),
    'queries',
    'count'
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today()

UNION ALL

SELECT
    'Errors Today',
    count(),
    'errors',
    'count'
FROM system.query_log
WHERE type IN ('ExceptionWhileProcessing', 'ExceptionBeforeStart')
  AND event_date >= today()

UNION ALL

SELECT
    'Active Replicas',
    sum(active_replicas),
    'replicas',
    'count'
FROM system.replicas

UNION ALL

SELECT
    'Current Connections',
    count(),
    'connections',
    'count'
FROM system.connections;

-- ========================================
-- 13. 性能基线对比
-- ========================================

-- 创建性能基线表（如果不存在）
CREATE TABLE IF NOT EXISTS system_monitoring.performance_baseline (
    baseline_date Date,
    query_type String,
    avg_duration_ms Float64,
    p50_duration_ms Float64,
    p95_duration_ms Float64,
    p99_duration_ms Float64,
    query_count UInt64
) ENGINE = MergeTree()
ORDER BY (baseline_date, query_type);

-- 计算今天的性能指标
-- INSERT INTO system_monitoring.performance_baseline
-- SELECT
--     today() as baseline_date,
--     replaceRegexpOne(query, ' .+', '') as query_type,
--     avg(query_duration_ms) as avg_duration_ms,
--     quantile(0.5)(query_duration_ms) as p50_duration_ms,
--     quantile(0.95)(query_duration_ms) as p95_duration_ms,
--     quantile(0.99)(query_duration_ms) as p99_duration_ms,
--     count() as query_count
-- FROM system.query_log
-- WHERE type = 'QueryFinish'
--   AND event_date = today()
--   AND query NOT LIKE 'INSERT INTO%'
--   AND query NOT LIKE 'SELECT FROM system%'
-- GROUP BY query_type;

-- 对比性能变化
-- SELECT
--     today.baseline_date,
--     today.query_type,
--     today.avg_duration_ms as today_avg,
--     baseline.avg_duration_ms as baseline_avg,
--     (today.avg_duration_ms - baseline.avg_duration_ms) / baseline.avg_duration_ms * 100 as change_percent,
--     today.query_count as today_count,
--     baseline.query_count as baseline_count
-- FROM system_monitoring.performance_baseline today
-- INNER JOIN system_monitoring.performance_baseline baseline
--   ON today.query_type = baseline.query_type
-- WHERE today.baseline_date = today()
--   AND baseline.baseline_date = today() - INTERVAL 1 DAY;

-- ========================================
-- 14. 告警规则查询
-- ========================================

-- 高负载告警：查询持续时间过长
SELECT
    'High Query Duration' as alert_type,
    count() as alert_count,
    max(query_duration_ms) as max_duration_ms
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query_duration_ms > 5000
  AND event_date >= today()
HAVING count() > 10;

-- 内存使用告警
SELECT
    'High Memory Usage' as alert_type,
    formatReadableSize(value) as memory_used,
    'Memory used > 10GB' as description
FROM system.asynchronous_metrics
WHERE name = 'OSMemoryVirtual'
  AND value > 10000000000;

-- 复制延迟告警
SELECT
    'Replication Lag' as alert_type,
    database,
    table,
    max(absolute_delay) as max_delay_seconds,
    formatReadableTimeDelta(max(absolute_delay)) as max_delay_readable
FROM system.replicas
WHERE absolute_delay > 60
GROUP BY database, table;

-- 磁盘空间告警
SELECT
    'Low Disk Space' as alert_type,
    name,
    formatReadableSize(unreserved_space) as available_space,
    formatReadableSize(keep_free_space) as required_space
FROM system.disks
WHERE unreserved_space < keep_free_space * 2;

-- ========================================
-- 15. 监控仪表板查询
-- ========================================

-- 仪表板：查询性能
SELECT
    toHour(event_time) as hour,
    count() as query_count,
    avg(query_duration_ms) as avg_duration_ms,
    sum(read_bytes) as total_bytes_read
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today()
GROUP BY hour
ORDER BY hour;

-- 仪表板：系统负载
SELECT
    name,
    value,
    description
FROM system.asynchronous_metrics
WHERE name IN ('CPUUsage', 'OSMemoryVirtual', 'NetworkReceiveBytes', 'NetworkSendBytes')
ORDER BY name;

-- 仪表板：表健康度
SELECT
    database,
    table,
    count() as total_parts,
    sum(if(level = 0, 1, 0)) as unmerged_parts,
    sum(rows) as total_rows,
    formatReadableSize(sum(bytes_on_disk)) as total_size
FROM system.parts
WHERE active = 1
GROUP BY database, table
ORDER BY unmerged_parts DESC
LIMIT 10;

-- ========================================
-- 16. 清理测试数据
-- ========================================
DROP TABLE IF EXISTS system_monitoring.performance_baseline;

-- ========================================
-- 17. 监控最佳实践总结
-- ========================================
/*
监控和指标最佳实践：

1. 关键指标监控
   - 查询延迟和吞吐量
   - 资源使用（CPU、内存、磁盘）
   - 复制延迟和队列
   - 错误率和异常

2. 监控工具
   - ClickHouse 内置系统表
   - Grafana + Prometheus
   - 自定义告警脚本
   - 日志分析工具

3. 告警规则
   - 查询延迟 > 5s
   - 内存使用 > 80%
   - 复制延迟 > 60s
   - 磁盘空间 < 20%
   - 错误率突增

4. 性能基线
   - 定期记录性能基线
   - 对比历史数据
   - 识别性能退化
   - 分析趋势变化

5. 可视化
   - 使用 Grafana 创建仪表板
   - 定制关键指标视图
   - 实时监控系统状态
   - 历史数据分析
*/
