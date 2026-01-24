-- ================================================
-- 05_clusters_replicas_examples.sql
-- 从 05_clusters_replicas.md 提取的 SQL 示例
-- 提取时间: 2026-01-23 14:40:17
-- ================================================


-- ========================================
-- 查看集群配置
-- ========================================

-- 查看所有集群
SELECT
    cluster,
    shard_num,
    replica_num,
    host_name,
    port,
    user,
    default_database,
    errors_count,
    slowdowns_count,
    estimated_recovery_time
FROM system.clusters
ORDER BY cluster, shard_num, replica_num;

-- ========================================
-- 查看集群配置
-- ========================================

-- 查看 treasurycluster 集群详情
SELECT
    cluster,
    shard_num,
    replica_num,
    host_name,
    port,
    user,
    default_database,
    errors_count,
    slowdowns_count,
    estimated_recovery_time
FROM system.clusters
WHERE cluster = 'treasurycluster'
ORDER BY shard_num, replica_num;

-- ========================================
-- 查看集群配置
-- ========================================

-- 查看所有复制表的副本状态
-- SKIPPED: Problematic statement (contains non-existent fields/tables)
-- SELECT
--     database,
--     table,
--     replica_name,
--     is_leader,
--     is_readonly,
--     is_session_expired,
--     queue_size,
--     absolute_delay,
--     relative_delay,
--     last_queue_update,
--     active_replicas,
--     total_replicas
-- FROM system.replicas
-- WHERE database != 'system'
-- ORDER BY database, table, replica_name;
-- 

-- ========================================
-- 查看集群配置
-- ========================================

-- 查看有复制延迟的副本
-- SKIPPED: Problematic statement (contains non-existent fields/tables)
-- SELECT
--     database,
--     table,
--     replica_name,
--     absolute_delay,
--     relative_delay,
--     queue_size,
--     is_leader,
--     is_readonly,
--     is_session_expired
-- FROM system.replicas
-- WHERE absolute_delay > 0 OR queue_size > 0
-- ORDER BY absolute_delay DESC, queue_size DESC;
-- 

-- ========================================
-- 查看集群配置
-- ========================================

-- 查看复制队列中的任务
-- SKIPPED: Problematic statement (contains non-existent fields/tables)
-- SELECT
--     database,
--     table,
--     replica_name,
--     position,
--     node_name,
--     type,
--     event_type,
--     exception_code,
--     exception_text
-- FROM system.replication_queue
-- WHERE database = 'your_database'
--   AND table = 'your_table'
-- ORDER BY position;
-- 

-- ========================================
-- 查看集群配置
-- ========================================

-- 查看有异常的复制任务
-- SKIPPED: Problematic statement (event_type field does not exist)
-- SELECT
--     database,
--     table,
--     replica_name,
--     type,
--     event_type,
--     exception_code,
--     exception_text,
--     num_tries,
--     num_failures
-- FROM system.replication_queue
-- WHERE exception_code != 0
-- ORDER BY database, table, replica_name, position

-- ========================================
-- 查看集群配置
-- ========================================

-- 集群健康检查
SELECT
    'Cluster Health' AS check_type,
    count() AS total_nodes,
    sumIf(1, errors_count = 0) AS healthy_nodes,
    sumIf(1, errors_count > 0) AS unhealthy_nodes,
    max(errors_count) AS max_errors,
    avg(slowdowns_count) AS avg_slowdowns
FROM system.clusters
WHERE cluster = 'treasurycluster';

-- ========================================
-- 查看集群配置
-- ========================================

-- 副本状态检查
-- SKIPPED: Problematic statement (contains non-existent fields/tables)
-- SELECT
--     'Replica Status' AS check_type,
--     count() AS total_replicas,
--     sumIf(1, is_leader = 1) AS leaders,
--     sumIf(1, is_readonly = 1) AS readonly_replicas,
--     sumIf(1, is_session_expired = 1) AS expired_sessions,
--     sumIf(1, absolute_delay > 10) AS delayed_replicas,
--     max(absolute_delay) AS max_delay_seconds
-- FROM system.replicas
-- WHERE database != 'system';
-- 

-- ========================================
-- 查看集群配置
-- ========================================

-- 检查副本数据一致性
SELECT
    database,
    table,
    active_replicas,
    total_replicas,
    (total_replicas - active_replicas) AS inactive_replicas,
    CASE
        WHEN active_replicas = total_replicas THEN 'OK'
        ELSE 'WARNING'
    END AS status
FROM system.replicas
WHERE database != 'system'
  AND total_replicas > 1
ORDER BY status DESC, (total_replicas - active_replicas) DESC;

-- ========================================
-- 查看集群配置
-- ========================================

-- 查看所有分布式表
-- SKIPPED: Problematic statement (contains non-existent fields/tables)
-- SELECT
--     database,
--     name AS table,
--     cluster,
--     sharding_key,
--     distributed_table,
--     formatReadableSize(total_bytes) AS size
-- FROM system.tables
-- WHERE engine = 'Distributed'
--   AND database != 'system'
-- ORDER BY database, name;
-- 

-- ========================================
-- 查看集群配置
-- ========================================

-- 查看分布式表对应的本地表
-- SKIPPED: Problematic statement (contains non-existent fields/tables)
-- SELECT
--     dt.database,
--     dt.name AS distributed_table,
--     dt.cluster,
--     dt.sharding_key,
--     lt.name AS local_table,
--     lt.total_rows AS local_rows,
--     formatReadableSize(lt.total_bytes) AS local_size
-- FROM system.tables AS dt
-- JOIN system.tables AS lt ON 
--     dt.database = lt.database 
--     AND lt.name = dt.distributed_table
-- WHERE dt.engine = 'Distributed'
--   AND dt.database != 'system'
-- ORDER BY dt.database, dt.name;
-- 

-- ========================================
-- 查看集群配置
-- ========================================

-- 实时监控复制延迟
-- SKIPPED: Problematic statement (relative_delay field does not exist)
-- SELECT
--     database,
--     table,
--     replica_name,
--     absolute_delay,
--     relative_delay,
--     queue_size,
--     last_queue_update,
--     now() - last_queue_update AS seconds_since_update,
--     CASE
--         WHEN absolute_delay > 300 THEN 'CRITICAL'
--         WHEN absolute_delay > 60 THEN 'WARNING'
--         ELSE 'OK'
--     END AS status
-- FROM system.replicas
-- WHERE database != 'system'
-- ORDER BY absolute_delay DESC

-- ========================================
-- 查看集群配置
-- ========================================

-- 查找只读副本
-- SKIPPED: Problematic statement (contains non-existent fields/tables)
-- SELECT
--     database,
--     table,
--     replica_name,
--     is_leader,
--     is_readonly,
--     is_session_expired,
--     absolute_delay,
--     queue_size
-- FROM system.replicas
-- WHERE database != 'system'
--   AND (is_readonly = 1 OR is_session_expired = 1)
-- ORDER BY database, table, replica_name;
-- 

-- ========================================
-- 查看集群配置
-- ========================================

-- 分析集群各节点的负载
SELECT
    cluster,
    shard_num,
    replica_num,
    host_name,
    errors_count,
    slowdowns_count,
    estimated_recovery_time,
    CASE
        WHEN errors_count > 0 OR slowdowns_count > 100 THEN 'HIGH LOAD'
        WHEN slowdowns_count > 10 THEN 'MEDIUM LOAD'
        ELSE 'NORMAL'
    END AS load_status
FROM system.clusters
WHERE cluster = 'treasurycluster'
ORDER BY errors_count DESC, slowdowns_count DESC;

-- ========================================
-- 查看集群配置
-- ========================================

-- 检查表的副本数量
SELECT
    database,
    table,
    active_replicas,
    total_replicas,
    (total_replicas - active_replicas) AS missing_replicas,
    CASE
        WHEN active_replicas < total_replicas THEN 'INSUFFICIENT REPLICAS'
        ELSE 'OK'
    END AS status
FROM system.replicas
WHERE database != 'system'
  AND total_replicas > 1
ORDER BY missing_replicas DESC;

-- ========================================
-- 查看集群配置
-- ========================================

-- 查找积压严重的复制队列
-- SKIPPED: Problematic statement (queue_size field does not exist)
-- SELECT
--     database,
--     table,
--     replica_name,
--     queue_size,
--     absolute_delay,
--     num_tries,
--     num_failures,
--     exception_code,
--     exception_text
-- FROM system.replication_queue
-- WHERE queue_size > 100 OR exception_code != 0
-- ORDER BY queue_size DESC, database, table, replica_name
-- LIMIT 20

-- ========================================
-- 查看集群配置
-- ========================================

-- 手动触发复制任务（通常不需要手动操作）
-- SKIPPED: Problematic statement (contains non-existent fields/tables)
-- SYSTEM SYNC REPLICA your_database.your_table;
-- 

-- 查看复制状态
-- SKIPPED: Problematic statement (contains non-existent fields/tables)
-- SELECT
--     replica_name,
--     queue_size,
--     absolute_delay,
--     last_queue_update
-- FROM system.replicas
-- WHERE database = 'your_database'
--   AND table = 'your_table';
-- 

-- ========================================
-- 查看集群配置
-- ========================================

-- 删除并重新创建副本（谨慎操作！）
-- 1. 先查看副本状态
-- SKIPPED: Problematic statement (contains non-existent fields/tables)
-- SELECT * FROM system.replicas
-- WHERE database = 'your_database' AND table = 'your_table';
-- 

-- 2. 在需要重新同步的节点上删除表
-- DROP TABLE IF EXISTS your_database.your_table SYNC;

-- 3. 重新创建表（使用原表的 CREATE TABLE 语句）
-- CREATE TABLE your_database.your_table ...;

-- 4. 验证复制状态
-- SKIPPED: Problematic statement (contains non-existent fields/tables)
-- SELECT * FROM system.replicas
-- WHERE database = 'your_database' AND table = 'your_table';
-- 

-- ========================================
-- 查看集群配置
-- ========================================

-- 查看当前集群配置
SELECT * FROM system.clusters
WHERE cluster = 'treasurycluster'
ORDER BY shard_num, replica_num;

-- 添加新节点需要：
-- 1. 在新节点上安装 ClickHouse
-- 2. 配置 ClickHouse Keeper
-- 3. 更新集群配置文件
-- 4. 重启 ClickHouse 服务
-- 5. 验证新节点加入集群
SELECT * FROM system.clusters
WHERE cluster = 'treasurycluster'
ORDER BY shard_num, replica_num;

-- ========================================
-- 查看集群配置
-- ========================================

-- 复制状态概览
SELECT
    'Total Replicas' as metric,
    count() as value,
    '' as status
FROM system.replicas
WHERE database != 'system'

UNION ALL

SELECT
    'Active Replicas',
    sumIf(1, active_replicas = total_replicas),
    ''
FROM system.replicas
WHERE database != 'system'

UNION ALL

SELECT
    'Delayed Replicas',
    sumIf(1, absolute_delay > 10),
    CASE WHEN sumIf(1, absolute_delay > 10) > 0 THEN 'WARNING' ELSE 'OK' END
FROM system.replicas
WHERE database != 'system'

UNION ALL

SELECT
    'Max Delay (seconds)',
    max(absolute_delay),
    CASE WHEN max(absolute_delay) > 300 THEN 'CRITICAL' 
         WHEN max(absolute_delay) > 60 THEN 'WARNING' 
         ELSE 'OK' END
FROM system.replicas
WHERE database != 'system';

-- ========================================
-- 查看集群配置
-- ========================================

-- 集群节点状态
SELECT
    cluster,
    shard_num,
    replica_num,
    host_name,
    port,
    errors_count,
    slowdowns_count,
    CASE
        WHEN errors_count > 0 THEN 'ERROR'
        WHEN slowdowns_count > 50 THEN 'SLOW'
        ELSE 'OK'
    END AS status
FROM system.clusters
WHERE cluster = 'treasurycluster'
ORDER BY shard_num, replica_num;
