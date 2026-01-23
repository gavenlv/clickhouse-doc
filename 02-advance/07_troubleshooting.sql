-- ================================================
-- 07_troubleshooting.sql
-- ClickHouse 故障排查示例
-- ================================================

-- ========================================
-- 1. 系统健康检查
-- ========================================

-- 检查服务状态
SELECT version() as version, uptime() as uptime_seconds;

-- 检查集群状态
SELECT
    cluster,
    shard_num,
    replica_num,
    host_name,
    errors_count,
    estimated_recovery_time
FROM system.clusters
WHERE cluster = 'treasurycluster'
ORDER BY shard_num, replica_num;

-- 检查复制状态
SELECT
    database,
    table,
    is_leader,
    is_readonly,
    is_session_expired,
    queue_size,
    absolute_delay,
    total_replicas,
    active_replicas
FROM system.replicas
ORDER BY database, table, replica_name;

-- 检查表状态
SELECT
    database,
    table,
    engine,
    total_rows,
    total_bytes,
    create_table_query
FROM system.tables
WHERE database != 'system'
ORDER BY database, table;

-- ========================================
-- 2. 性能问题诊断
-- ========================================

-- 查看慢查询（超过 5 秒）- 需要启用query_log
/*
SELECT
    query_id,
    user,
    query,
    query_start_time,
    query_duration_ms,
    read_rows,
    read_bytes,
    memory_usage,
    formatReadableSize(read_bytes) as readable_bytes,
    formatReadableSize(memory_usage) as readable_memory
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query_duration_ms > 5000
  AND event_date >= today()
ORDER BY query_duration_ms DESC
LIMIT 20;
*/

-- 查看当前运行的查询
SELECT
    query_id,
    user,
    query,
    elapsed,
    read_rows,
    read_bytes,
    memory_usage
FROM system.processes
ORDER BY query_id DESC;

-- 查看高内存使用的查询
SELECT
    query_id,
    user,
    query,
    memory_usage,
    formatReadableSize(memory_usage) as readable_memory,
    elapsed
FROM system.processes
ORDER BY memory_usage DESC
LIMIT 10;

-- 查看大量读取的查询
SELECT
    query_id,
    user,
    query,
    read_rows,
    read_bytes,
    formatReadableSize(read_bytes) as readable_bytes,
    elapsed
FROM system.processes
ORDER BY read_bytes DESC
LIMIT 10;

-- ========================================
-- 3. 复制问题诊断
-- ========================================

-- 检查复制延迟
SELECT
    database,
    table,
    replica_name,
    absolute_delay,
    queue_size,
    is_session_expired,
    is_readonly,
    formatReadableTimeDelta(absolute_delay) as delay_readable
FROM system.replicas
WHERE absolute_delay > 10 OR queue_size > 50
ORDER BY absolute_delay DESC;

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
ORDER BY table, replica_name, position
LIMIT 50;

-- 检查没有 leader 的表
SELECT
    database,
    table,
    replica_name,
    is_leader,
    can_become_leader
FROM system.replicas
WHERE database IN (
    SELECT database
    FROM system.replicas
    GROUP BY database, table
    HAVING sum(if(is_leader, 1, 0)) = 0
)
ORDER BY database, table;

-- 检查过期的会话
SELECT
    database,
    table,
    replica_name,
    is_session_expired,
    is_readonly,
    queue_size
FROM system.replicas
WHERE is_session_expired = 1;

-- ========================================
-- 4. 磁盘空间问题
-- ========================================

-- 检查磁盘使用情况
SELECT
    name,
    path,
    total_space,
    unreserved_space,
    keep_free_space,
    formatReadableSize(total_space) as total_readable,
    formatReadableSize(unreserved_space) as unreserved_readable,
    formatReadableSize(keep_free_space) as keep_free_readable,
    (unreserved_space * 100.0 / total_space) as free_percent
FROM system.disks
ORDER BY free_percent;

-- 查找占用空间最大的表
SELECT
    database,
    table,
    sum(bytes_on_disk) as total_bytes,
    formatReadableSize(sum(bytes_on_disk)) as readable_size,
    sum(rows) as total_rows
FROM system.parts
WHERE active = 1
GROUP BY database, table
ORDER BY total_bytes DESC
LIMIT 20;

-- 查找占用空间最大的分区
SELECT
    database,
    table,
    partition,
    sum(bytes_on_disk) as total_bytes,
    formatReadableSize(sum(bytes_on_disk)) as readable_size,
    sum(rows) as total_rows
FROM system.parts
WHERE active = 1
GROUP BY database, table, partition
ORDER BY total_bytes DESC
LIMIT 30;

-- 查看未合并的数据（占用额外空间）
SELECT
    database,
    table,
    partition,
    count(*) as unmerged_parts,
    sum(rows) as total_rows,
    sum(bytes_on_disk) as total_bytes,
    formatReadableSize(sum(bytes_on_disk)) as readable_size
FROM system.parts
WHERE active = 1
  AND level = 0
GROUP BY database, table, partition
ORDER BY total_bytes DESC
LIMIT 20;

-- ========================================
-- 5. 内存问题诊断
-- ========================================

-- 查看内存使用情况
SELECT
    name,
    value,
    formatReadableSize(value) as readable_value,
    description
FROM system.asynchronous_metrics
WHERE name LIKE '%memory%'
ORDER BY value DESC;

-- 查看当前内存使用最高的查询
SELECT
    query_id,
    user,
    query,
    memory_usage,
    formatReadableSize(memory_usage) as readable_memory,
    elapsed
FROM system.processes
ORDER BY memory_usage DESC
LIMIT 10;

-- 查看内存使用历史
SELECT
    toHour(event_time) as hour,
    avg(memory_usage) as avg_memory,
    max(memory_usage) as max_memory,
    formatReadableSize(avg(memory_usage)) as avg_readable,
    formatReadableSize(max(memory_usage)) as max_readable
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today()
GROUP BY hour
ORDER BY hour;

-- ========================================
-- 6. 合并问题诊断
-- ========================================

-- 查看正在进行的合并
SELECT
    database,
    table,
    partition,
    parts_to_do,
    progress,
    is_mutation,
    rows_read,
    rows_written,
    bytes_read_uncompressed,
    bytes_written_uncompressed,
    thread_id,
    elapsed
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
    avg(elapsed) as avg_elapsed_seconds,
    max(elapsed) as max_elapsed_seconds
FROM system.merges
WHERE started >= now() - INTERVAL 1 HOUR
GROUP BY database, table
ORDER BY merge_count DESC;

-- 查看等待合并的数据
SELECT
    database,
    table,
    partition,
    count(*) as part_count,
    sum(rows) as total_rows,
    max(level) as max_level
FROM system.parts
WHERE active = 1
  AND level > 0
GROUP BY database, table, partition
ORDER BY max_level DESC, part_count DESC
LIMIT 20;

-- ========================================
-- 7. Mutation 问题诊断
-- ========================================

-- 查看正在进行的 mutation
SELECT
    database,
    table,
    command,
    create_time,
    parts_to_do,
    is_done,
    formatDateTime(create_time, '%Y-%m-%d %H:%M:%S') as formatted_time
FROM system.mutations
WHERE is_done = 0
ORDER BY create_time;

-- 查看失败的 mutation
SELECT
    database,
    table,
    command,
    create_time,
    done_time,
    exception_code,
    exception_text
FROM system.mutations
WHERE exception_code != 0
  AND done_time >= now() - INTERVAL 7 DAY
ORDER BY done_time DESC;

-- 查看 mutation 历史
SELECT
    database,
    table,
    command,
    count() as mutation_count,
    avg(parts_to_do) as avg_parts,
    max(parts_to_do) as max_parts
FROM system.mutations
WHERE done_time >= now() - INTERVAL 1 DAY
GROUP BY database, table
ORDER BY mutation_count DESC;

-- ========================================
-- 8. 错误日志分析
-- ========================================

-- 查看最近的错误
SELECT
    event_date,
    event_time,
    host_name,
    level,
    query_id,
    exception_code,
    message
FROM system.text_log
WHERE level IN ('Error', 'Fatal', 'Critical')
  AND event_date >= today()
ORDER BY event_time DESC
LIMIT 50;

-- 按错误类型统计
SELECT
    exception_code,
    count() as error_count,
    max(event_time) as last_occurred,
    substring(exception_text, 1, 100) as error_message
FROM system.query_log
WHERE type IN ('ExceptionWhileProcessing', 'ExceptionBeforeStart')
  AND event_date >= today()
GROUP BY exception_code, exception_text
ORDER BY error_count DESC
LIMIT 20;

-- 查看最常见的错误查询
SELECT
    substring(query, 1, 100) as query_snippet,
    count() as error_count,
    avg(query_duration_ms) as avg_duration,
    exception_code
FROM system.query_log
WHERE type = 'ExceptionWhileProcessing'
  AND event_date >= today()
GROUP BY query_snippet, exception_code
ORDER BY error_count DESC
LIMIT 10;

-- ========================================
-- 9. 连接问题诊断
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
ORDER BY query_start_time;

-- 统计连接数
SELECT
    user,
    count() as connection_count,
    count(DISTINCT initial_address) as unique_ips
FROM system.connections
GROUP BY user
ORDER BY connection_count DESC;

-- ========================================
-- 10. 性能瓶颈分析
-- ========================================

-- 分析查询性能分布
SELECT
    quantile(0.50)(query_duration_ms) as p50,
    quantile(0.75)(query_duration_ms) as p75,
    quantile(0.90)(query_duration_ms) as p90,
    quantile(0.95)(query_duration_ms) as p95,
    quantile(0.99)(query_duration_ms) as p99
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today();

-- 分析最耗时的查询类型
SELECT
    replaceRegexpOne(query, ' .*', '') as query_type,
    count() as query_count,
    avg(query_duration_ms) as avg_duration,
    max(query_duration_ms) as max_duration,
    sum(read_bytes) as total_bytes_read
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today()
GROUP BY query_type
ORDER BY avg_duration DESC
LIMIT 20;

-- 分析资源使用
SELECT
    user,
    count() as query_count,
    sum(memory_usage) as total_memory,
    avg(memory_usage) as avg_memory,
    sum(read_bytes) as total_bytes_read
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today()
GROUP BY user
ORDER BY total_memory DESC;

-- ========================================
-- 11. 常见问题解决方案
-- ========================================

-- 问题 1: 表只读
-- 原因：复制延迟或失去 leader
-- 解决：
-- 检查复制状态
SELECT
    database,
    table,
    replica_name,
    is_leader,
    is_readonly,
    is_session_expired,
    absolute_delay
FROM system.replicas
WHERE is_readonly = 1;

-- 检查 Keeper 连接
-- SELECT count() FROM system.zookeeper WHERE path = '/';

-- 问题 2: 查询超时
-- 原因：资源不足或查询复杂
-- 解决：
-- 增加超时时间
SET max_execution_time = 600;

-- 优化查询
SELECT * FROM large_table WHERE condition = 1 LIMIT 10000;

-- 问题 3: 磁盘空间不足
-- 原因：数据积累过多
-- 解决：
-- 删除旧分区
-- ALTER TABLE db.table DROP PARTITION '202312';

-- 优化合并
OPTIMIZE TABLE db.table FINAL;

-- 问题 4: 复制延迟
-- 原因：网络延迟或负载过高
-- 解决：
-- 检查复制队列
SELECT * FROM system.replication_queue LIMIT 50;

-- 调整复制设置
-- SET replicated_fetches_network_bandwidth_max = 1000000000;

-- ========================================
-- 12. 数据损坏修复
-- ========================================

-- 检查损坏的数据块
SELECT
    database,
    table,
    partition,
    name,
    rows,
    bytes_on_disk,
    exception
FROM system.parts
WHERE exception != ''
ORDER BY database, table;

-- 修复损坏的数据块
-- 删除损坏的部分
-- ALTER TABLE db.table DETACH PARTITION '202401';

-- 从备份恢复或重新同步

-- 重新附加分区（如果数据可用）
-- ALTER TABLE db.table ATTACH PARTITION '202401';

-- ========================================
-- 13. 性能优化建议
-- ========================================

-- 分析查询执行计划
EXPLAIN SELECT count() FROM large_table WHERE condition = 1;

-- 使用 EXPLAIN PIPELINE 查看详细计划
EXPLAIN PIPELINE SELECT count() FROM large_table WHERE condition = 1;

-- 检查索引使用情况
SELECT
    table,
    name as index_name,
    type,
    expr,
    granularity,
    parts,
    marks,
    bytes,
    formatReadableSize(bytes) as readable_size
FROM system.data_skipping_indices
ORDER BY table, index_name;

-- 检查分区剪枝
SELECT
    database,
    table,
    partition,
    rows,
    bytes_on_disk
FROM system.parts
WHERE active = 1
ORDER BY database, table, partition;

-- ========================================
-- 14. 监控告警规则
-- ========================================

-- 慢查询告警
SELECT
    'Slow Query Alert' as alert_type,
    count() as alert_count,
    max(query_duration_ms) as max_duration_ms
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query_duration_ms > 10000
  AND event_date >= now() - INTERVAL 1 HOUR
HAVING count() > 5;

-- 内存使用告警
SELECT
    'High Memory Usage' as alert_type,
    name,
    formatReadableSize(value) as memory_used,
    'Memory > 10GB' as threshold
FROM system.asynchronous_metrics
WHERE name = 'OSMemoryVirtual'
  AND value > 10000000000;

-- 磁盘空间告警
SELECT
    'Low Disk Space' as alert_type,
    name,
    formatReadableSize(unreserved_space) as available,
    'Space < 20GB' as threshold
FROM system.disks
WHERE unreserved_space < 20000000000;

-- ========================================
-- 15. 清理测试数据
-- ========================================

-- 如果创建了测试表，清理它们
-- DROP TABLE IF EXISTS test_table;

-- ========================================
-- 16. 故障排查最佳实践总结
-- ========================================
/*
故障排查最佳实践：

1. 系统监控
   - 定期检查系统健康状态
   - 监控关键指标（性能、资源、复制）
   - 配置合理的告警规则
   - 建立基线对比

2. 性能问题
   - 识别慢查询
   - 分析查询执行计划
   - 优化表结构和索引
   - 调整查询语句

3. 复制问题
   - 检查复制状态和延迟
   - 验证 Keeper 连接
   - 查看复制队列
   - 处理过期会话

4. 资源问题
   - 监控磁盘空间
   - 管理内存使用
   - 优化数据合并
   - 定期清理旧数据

5. 错误处理
   - 分析错误日志
   - 识别错误模式
   - 实施修复措施
   - 验证修复效果

6. 预防措施
   - 定期维护
   - 容量规划
   - 备份测试
   - 文档记录
*/
