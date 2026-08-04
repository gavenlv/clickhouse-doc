-- ============================================================
-- system 表诊断查询库
-- 集群：treasurycluster（CH 25.12.1.649）
-- 说明：本项目最有价值的 system 表诊断查询集合
--       覆盖：query_log 分析 / parts 健康 / 合并状态 / 副本状态 /
--             用户与权限审计 / 存储与磁盘 / 配置审计
-- 前置条件：system 表默认可用；query_log 需开启日志
-- 学习目标：掌握"遇到问题查哪个 system 表"的专家直觉
-- ============================================================

-- ============================================================
-- 第一部分：query_log 查询分析（性能诊断核心）
-- ============================================================

-- 1.1 慢查询 Top 20（最常用）
SELECT
    event_time,
    user,
    query_duration_ms / 1000 AS duration_sec,
    formatReadableQuantity(read_rows) AS read_rows,
    formatReadableSize(read_bytes) AS read_bytes,
    formatReadableSize(peak_memory_usage) AS peak_memory,
    left(query, 150) AS query_preview
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date = today()
  AND query_duration_ms > 1000
ORDER BY query_duration_ms DESC
LIMIT 20;

-- 1.2 按用户统计查询画像
SELECT
    user,
    count() AS query_count,
    round(avg(query_duration_ms) / 1000, 2) AS avg_sec,
    round(quantile(0.95)(query_duration_ms) / 1000, 2) AS p95_sec,
    formatReadableSize(sum(read_bytes)) AS total_read,
    formatReadableSize(max(peak_memory_usage)) AS max_mem
FROM system.query_log
WHERE type = 'QueryFinish' AND event_date = today()
GROUP BY user
ORDER BY avg_sec DESC;

-- 1.3 最热的表
SELECT
    database,
    table,
    count() AS query_count,
    round(sum(query_duration_ms) / 1000, 2) AS total_sec
FROM system.query_log
ARRAY JOIN tables AS t
WHERE type = 'QueryFinish' AND event_date = today()
GROUP BY database, table
ORDER BY query_count DESC
LIMIT 20;

-- 1.4 同类查询聚合（normalized_query_hash）
SELECT
    count() AS query_count,
    round(sum(query_duration_ms) / 1000, 2) AS total_sec,
    round(avg(query_duration_ms), 1) AS avg_ms,
    formatReadableSize(sum(read_bytes)) AS total_read,
    left(any(query), 150) AS query_sample
FROM system.query_log
WHERE type = 'QueryFinish' AND event_date = today()
GROUP BY normalized_query_hash
ORDER BY total_sec DESC
LIMIT 20;

-- 1.5 错误查询
SELECT
    toStartOfHour(event_time) AS hour,
    exception_code,
    exception,
    count() AS error_count
FROM system.query_log
WHERE type IN ('ExceptionBeforeStart', 'ExceptionWhileProcessing')
GROUP BY hour, exception_code, exception
ORDER BY hour DESC, error_count DESC
LIMIT 20;

-- 1.6 内存大户（OOM 前兆）
SELECT
    event_time,
    user,
    formatReadableSize(peak_memory_usage) AS peak_mem,
    round(query_duration_ms / 1000, 2) AS duration_sec,
    left(query, 150) AS query_preview
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date = today()
  AND peak_memory_usage > 10000000000
ORDER BY peak_memory_usage DESC
LIMIT 20;

-- 1.7 小时级负载
SELECT
    toStartOfHour(event_time) AS hour,
    count() AS queries,
    round(sum(query_duration_ms) / 1000, 2) AS busy_sec,
    formatReadableSize(sum(read_bytes)) AS total_read
FROM system.query_log
WHERE type = 'QueryFinish' AND event_date = today()
GROUP BY hour ORDER BY hour;

-- ============================================================
-- 第二部分：parts 健康检查（写入/合并健康）
-- ============================================================

-- 2.1 Part 数量健康检查（active > 300 需要关注）
SELECT
    database,
    table,
    count() AS active_parts,
    sum(rows) AS total_rows,
    formatReadableSize(sum(bytes_on_disk)) AS size,
    sum(bytes_on_disk) / sum(rows) AS bytes_per_row
FROM system.parts
WHERE active = 1
GROUP BY database, table
HAVING active_parts > 100
ORDER BY active_parts DESC
LIMIT 20;

-- 2.2 不健康分区（每个分区 Part 过多）
SELECT
    database,
    table,
    partition,
    count() AS parts_in_partition,
    sum(rows) AS rows
FROM system.parts
WHERE active = 1
GROUP BY database, table, partition
HAVING parts_in_partition > 50
ORDER BY parts_in_partition DESC
LIMIT 20;

-- 2.3 detached parts（异常分离的 Part）
SELECT
    database,
    table,
    reason,
    count() AS detach_count
FROM system.detached_parts
GROUP BY database, table, reason
ORDER BY detach_count DESC;

-- ============================================================
-- 第三部分：合并状态（merge 健康）
-- ============================================================

-- 3.1 当前合并队列
SELECT
    database,
    table,
    count() AS merging_parts,
    sum(rows_read) AS rows_being_merged,
    round(avg(elapsed), 2) AS avg_elapsed_sec
FROM system.merges
GROUP BY database, table
ORDER BY merging_parts DESC;

-- 3.2 合并历史（过去 1 小时）
SELECT
    table,
    count() AS merge_count,
    round(avg(duration_ms) / 1000, 2) AS avg_duration_sec,
    round(sum(rows_read), 0) AS total_rows_merged
FROM system.merge_log
WHERE event_date = today() AND event_time >= now() - 3600
GROUP BY table
ORDER BY merge_count DESC
LIMIT 20;

-- 3.3 mutation 队列（不应积压）
SELECT
    database,
    table,
    command,
    count() AS mutation_count
FROM system.mutations
WHERE is_done = 0
GROUP BY database, table, command
ORDER BY mutation_count DESC;

-- ============================================================
-- 第四部分：副本与复制状态
-- ============================================================

-- 4.1 副本健康总览
SELECT
    database,
    table,
    replica_name,
    is_leader,
    is_readonly,
    is_session_expired,
    absolute_delay AS delay_sec,
    queue_size,
    inserts_in_queue,
    merges_in_queue
FROM system.replicas
ORDER BY delay_sec DESC;

-- 4.2 复制队列延迟
SELECT
    database,
    table,
    replica_name,
    queue_size,
    sum(num_tries) AS total_tries
FROM system.replication_queue
GROUP BY database, table, replica_name
ORDER BY queue_size DESC;

-- 4.3 副本是否落后（延迟 > 60 秒告警）
SELECT
    database,
    table,
    absolute_delay
FROM system.replicas
WHERE absolute_delay > 60
ORDER BY absolute_delay DESC;

-- ============================================================
-- 第五部分：用户与权限审计
-- ============================================================

-- 5.1 所有用户及其设置
SELECT
    user_name,
    auth_type,
    settings['max_memory_usage'] AS max_memory,
    settings['max_execution_time'] AS max_execution_time,
    settings['readonly'] AS readonly,
    default_roles
FROM system.users
ORDER BY user_name;

-- 5.2 用户拥有的权限（审计）
SELECT
    user_name,
    granted_role_name,
    role_application
FROM system.grants
ORDER BY user_name, granted_role_name;

-- 5.3 行级安全策略
SELECT
    database,
    table,
    policy_name,
    filter,
    is_restrictive,
    is_permissive,
    apply_to_users
FROM system.row_policies
ORDER BY database, table;

-- 5.4 Quota 使用情况
SELECT
    quota_name,
    user_name,
    queries,
    max_queries,
    formatReadableTimeDelta(query_time) AS query_time,
    formatReadableSize(read_bytes) AS read_bytes
FROM system.quota_usage
ORDER BY quota_name, user_name;

-- ============================================================
-- 第六部分：存储与磁盘
-- ============================================================

-- 6.1 磁盘使用
SELECT
    name,
    path,
    free_space,
    total_space,
    formatReadableSize(free_space) AS free_str,
    formatReadableSize(total_space) AS total_str,
    round(free_space * 100 / total_space, 1) AS free_pct
FROM system.disks
ORDER BY total_space DESC;

-- 6.2 各库各表存储 Top 20
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

-- 6.3 未压缩 vs 压缩对比（压缩率）
SELECT
    database,
    table,
    sum(data_uncompressed_bytes) AS uncompressed,
    sum(data_compressed_bytes) AS compressed,
    round(sum(data_uncompressed_bytes) / sum(data_compressed_bytes), 2) AS compression_ratio
FROM system.parts
WHERE active = 1
GROUP BY database, table
ORDER BY compression_ratio DESC
LIMIT 20;

-- ============================================================
-- 第七部分：配置与运行时审计
-- ============================================================

-- 7.1 服务端配置审计
SELECT
    name,
    value,
    changed,
    description
FROM system.settings
WHERE changed = 1
ORDER BY name;

-- 7.2 当前运行中的查询（实时）
SELECT
    query_id,
    user,
    elapsed,
    formatReadableSize(memory_usage) AS memory,
    formatReadableQuantity(read_rows) AS read_rows,
    left(query, 100) AS query_preview
FROM system.processes
ORDER BY elapsed DESC
LIMIT 20;

-- 7.3 关键指标快照
SELECT
    metric,
    value,
    formatReadableSize(value) AS value_str
FROM system.metrics
WHERE metric IN (
    'Query', 'InsertedRows', 'SelectedRows',
    'MemoryTracking', 'ReadonlyReplicas',
    'PartsTemporary', 'PartsActive'
)
ORDER BY metric;

-- 7.4 版本与集群信息
SELECT version() AS version;
SELECT * FROM system.clusters WHERE cluster = 'treasurycluster';

-- ============================================================
-- 第八部分：一键健康巡检（生产必备）
-- ============================================================

-- 8.1 集群健康总览（组合查询）
SELECT '1. 数据库数' AS item, toString(count()) AS value FROM system.databases WHERE name != 'system'
UNION ALL
SELECT '2. 表数', toString(count()) FROM system.tables WHERE database != 'system'
UNION ALL
SELECT '3. Active Parts', toString(count()) FROM system.parts WHERE active = 1
UNION ALL
SELECT '4. 运行中查询', toString(count()) FROM system.processes
UNION ALL
SELECT '5. 未完成 mutation', toString(count()) FROM system.mutations WHERE is_done = 0
UNION ALL
SELECT '6. 落后副本', toString(count()) FROM system.replicas WHERE absolute_delay > 60
UNION ALL
SELECT '7. Detached Parts', toString(count()) FROM system.detached_parts;

-- 8.2 表大小 Top 10（带列数）
SELECT
    database,
    table,
    formatReadableSize(sum(bytes_on_disk)) AS size,
    formatReadableQuantity(sum(rows)) AS rows,
    count(DISTINCT partition) AS partitions,
    count() AS parts
FROM system.parts
WHERE active = 1
GROUP BY database, table
ORDER BY sum(bytes_on_disk) DESC
LIMIT 10;

-- 8.3 按天查询量趋势（近 7 天）
SELECT
    event_date,
    count() AS queries,
    countIf(type = 'QueryFinish') AS finished,
    countIf(type != 'QueryFinish') AS failed
FROM system.query_log
WHERE event_date >= today() - 7
GROUP BY event_date
ORDER BY event_date;
