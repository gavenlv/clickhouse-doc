-- ================================================
-- 05_high_availability.sql
-- ClickHouse 高可用配置示例
-- ================================================

-- ========================================
-- 1. 集群架构概览
-- ========================================

-- 查看当前集群配置
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

-- 查看集群统计信息
SELECT
    cluster,
    count(DISTINCT shard_num) as total_shards,
    count(DISTINCT replica_num) as total_replicas_per_shard,
    count(*) as total_nodes
FROM system.clusters
WHERE cluster = 'treasurycluster'
GROUP BY cluster;

-- 查看分布式表
SELECT
    database,
    name,
    engine,
    engine_full
FROM system.tables
WHERE engine = 'Distributed';

-- ========================================
-- 2. 复制配置检查
-- ========================================

-- 查看所有复制表
SELECT
    database,
    table,
    engine,
    engine_full,
    total_replicas,
    active_replicas
FROM system.replicas
ORDER BY database, table;

-- 查看复制状态详情
SELECT
    database,
    table,
    is_leader,
    can_become_leader,
    is_readonly,
    is_session_expired,
    replica_name,
    replica_path,
    zookeeper_path,
    queue_size,
    absolute_delay,
    total_replicas,
    active_replicas
FROM system.replicas
ORDER BY database, table, replica_name;

-- 查看复制健康状态
SELECT
    database,
    table,
    sum(if(is_leader, 1, 0)) as leader_count,
    sum(if(is_session_expired, 1, 0)) as expired_count,
    avg(queue_size) as avg_queue_size,
    max(absolute_delay) as max_delay_seconds,
    formatReadableTimeDelta(max(absolute_delay)) as max_delay_readable
FROM system.replicas
GROUP BY database, table
ORDER BY database, table;

-- ========================================
-- 3. 故障转移测试
-- ========================================

-- 查看当前 leader
SELECT
    database,
    table,
    replica_name,
    is_leader,
    is_readonly,
    queue_size
FROM system.replicas
WHERE is_leader = 1;

-- 查看副本同步状态
SELECT
    database,
    table,
    replica_name,
    absolute_delay,
    queue_size,
    is_session_expired
FROM system.replicas
ORDER BY database, table, absolute_delay DESC;

-- 创建测试表用于故障转移
CREATE TABLE IF NOT EXISTS ha_test.events (
    event_id UInt64,
    user_id UInt64,
    event_data String,
    timestamp DateTime DEFAULT now()
) ENGINE = ReplicatedMergeTree()
ORDER BY (user_id, timestamp);

-- 插入测试数据
INSERT INTO ha_test.events (event_id, user_id, event_data) VALUES
(1, 1, 'test data 1'),
(2, 2, 'test data 2'),
(3, 3, 'test data 3');

-- 查看表在两个副本上的数据
-- 连接到 clickhouse1: SELECT count() FROM ha_test.events;
-- 连接到 clickhouse2: SELECT count() FROM ha_test.events;

-- ========================================
-- 4. 负载均衡配置
-- ========================================

-- 查看分布式表的负载均衡设置
SHOW CREATE TABLE;

-- 使用 cluster() 函数查询集群数据
SELECT
    shard_num,
    replica_num,
    host_name,
    count() as table_count
FROM cluster(treasurycluster, system, tables)
GROUP BY shard_num, replica_num, host_name
ORDER BY shard_num, replica_num;

-- 测试分布式查询性能
SELECT
    sum(rows) as total_rows,
    count(DISTINCT replica_num) as replicas_used
FROM cluster(treasurycluster, system, parts)
WHERE active = 1;

-- ========================================
-- 5. 数据一致性检查
-- ========================================

-- 创建一致性检查表
CREATE TABLE IF NOT EXISTS ha_test.consistency_test (
    id UInt64,
    data String,
    checksum UInt32,
    created_at DateTime DEFAULT now()
) ENGINE = ReplicatedMergeTree()
ORDER BY id;

-- 插入测试数据
INSERT INTO ha_test.consistency_test (id, data) VALUES
(1, 'row 1'),
(2, 'row 2'),
(3, 'row 3');

-- 计算校验和
-- 连接到 clickhouse1:
-- SELECT id, sipHash64(concat(data, toString(created_at))) as checksum FROM ha_test.consistency_test;

-- 连接到 clickhouse2:
-- SELECT id, sipHash64(concat(data, toString(created_at))) as checksum FROM ha_test.consistency_test;

-- 对比结果应该相同

-- ========================================
-- 6. 分片和副本管理
-- ========================================

-- 查看表的分片信息
SELECT
    database,
    table,
    partition,
    name as part_name,
    rows,
    bytes_on_disk,
    modification_time
FROM system.parts
WHERE table = 'consistency_test'
  AND database = 'ha_test'
  AND active = 1
ORDER BY partition, modification_time;

-- 查看分片统计
SELECT
    database,
    table,
    partition,
    count(*) as part_count,
    sum(rows) as total_rows,
    formatReadableSize(sum(bytes_on_disk)) as total_size
FROM system.parts
WHERE database = 'ha_test'
  AND active = 1
GROUP BY database, table, partition
ORDER BY partition;

-- 查看未合并的数据
SELECT
    database,
    table,
    partition,
    count(*) as unmerged_parts,
    sum(rows) as total_rows
FROM system.parts
WHERE database = 'ha_test'
  AND active = 1
  AND level = 0
GROUP BY database, table, partition;

-- ========================================
-- 7. 自动故障恢复
-- ========================================

-- 查看复制队列（显示待处理任务）
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
    thread_id
FROM system.merges
ORDER BY started
LIMIT 10;

-- 查看正在进行的 mutation
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

-- ========================================
-- 8. 性能监控
-- ========================================

-- 查看副本性能
SELECT
    database,
    table,
    replica_name,
    queue_size,
    absolute_delay,
    total_replicas,
    active_replicas,
    elapsed / 1000 as uptime_hours
FROM system.replicas
ORDER by database, table;

-- 查看查询在集群上的分布
SELECT
    host_name,
    count() as query_count
FROM system.distributed_query_log
WHERE type = 'QueryFinish'
  AND event_date >= today()
GROUP BY host_name
ORDER BY query_count DESC;

-- ========================================
-- 9. 容灾测试
-- ========================================

-- 创建备份表（用于容灾）
CREATE TABLE IF NOT EXISTS ha_test.backup_events AS ha_test.events
ENGINE = MergeTree()
ORDER BY (user_id, timestamp);

-- 备份数据
INSERT INTO ha_test.backup_events SELECT * FROM ha_test.events;

-- 验证备份
SELECT count() as backup_count FROM ha_test.backup_events;

-- 模拟故障：停止一个副本
-- 在宿主机执行: docker stop clickhouse-server-1

-- 测试查询（应该自动切换到另一个副本）
-- SELECT count() FROM ha_test.events;

-- 恢复副本
-- 在宿主机执行: docker start clickhouse-server-1

-- 查看同步状态
-- SELECT replica_name, queue_size, absolute_delay FROM system.replicas WHERE table = 'events';

-- ========================================
-- 10. 读写分离配置
-- ========================================

-- 创建用户专门用于读操作
/*
CREATE USER IF NOT EXISTS readonly_user
IDENTIFIED WITH sha256_password BY 'ReadOnlyPassword123'
HOST ANY;

GRANT SELECT ON *.* TO readonly_user;
*/

-- 创建用户专门用于写操作
/*
CREATE USER IF NOT EXISTS write_user
IDENTIFIED WITH sha256_password BY 'WritePassword123'
HOST LOCAL;

GRANT INSERT, ALTER ON *.* TO write_user;
*/

-- 查看当前连接
SELECT
    user,
    initial_address as remote_host,
    query_start_time,
    query
FROM system.processes
ORDER BY query_start_time DESC;

-- ========================================
-- 11. 跨数据中心复制
-- ========================================

/*
配置示例：

1. 主数据中心配置：
   - 3 节点集群（每节点 1 分片，1 副本）
   - 用于写操作

2. 从数据中心配置：
   - 3 节点集群（每节点 1 分片，1 副本）
   - 用于读操作

3. 使用 CLICKHOUSE-COPIER 进行数据同步

配置文件示例:
<config>
    <source>
        <host>dc1-master1</host>
        <port>9000</port>
        <user>replication_user</user>
        <password>password</password>
    </source>
    <destination>
        <host>dc2-replica1</host>
        <port>9000</port>
        <user>replication_user</user>
        <password>password</password>
    </destination>
    <tables>
        <table_cluster>
            <cluster_name>dc1_cluster</cluster_name>
            <database>app</database>
            <table>events</table>
        </table_cluster>
    </tables>
</config>
*/

-- ========================================
-- 12. 监控告警规则
-- ========================================

-- 副本下线告警
SELECT
    'Replica Offline' as alert_type,
    database,
    table,
    replica_name,
    is_session_expired,
    is_readonly
FROM system.replicas
WHERE is_session_expired = 1 OR is_readonly = 1;

-- 复制延迟告警
SELECT
    'Replication Lag' as alert_type,
    database,
    table,
    replica_name,
    absolute_delay,
    queue_size
FROM system.replicas
WHERE absolute_delay > 60 OR queue_size > 100;

-- Leader 丢失告警
SELECT
    'No Leader' as alert_type,
    database,
    table,
    sum(if(is_leader, 1, 0)) as leader_count
FROM system.replicas
GROUP BY database, table
HAVING leader_count = 0;

-- ========================================
-- 13. 集群健康评分
-- ========================================

-- 计算集群健康分数
SELECT
    'Cluster Health Score' as metric,
    cluster,
    sum(errors_count) as total_errors,
    avg(estimated_recovery_time) as avg_recovery_time,
    round(
        (sum(if(errors_count = 0, 1, 0)) * 0.4 +
         sum(if(estimated_recovery_time < 10, 1, 0)) * 0.3 +
         count(*) * 0.3) * 100 / count(*, 0
    ) as health_score
FROM system.clusters
WHERE cluster = 'treasurycluster'
GROUP BY cluster;

-- ========================================
-- 14. 清理测试数据
-- ========================================
DROP TABLE IF EXISTS ha_test.events;
DROP TABLE IF EXISTS ha_test.consistency_test;
DROP TABLE IF EXISTS ha_test.backup_events;
DROP DATABASE IF EXISTS ha_test;

-- ========================================
-- 15. 高可用最佳实践总结
-- ========================================
/*
高可用配置最佳实践：

1. 集群架构
   - 至少 3 个 Keeper 节点（防止脑裂）
   - 每分片至少 2 个副本
   - 跨机房部署（防止机房故障）
   - 合理的分片和副本配置

2. 故障转移
   - 配置自动故障转移
   - 使用 Distributed 表实现负载均衡
   - 监控复制状态
   - 定期测试故障切换

3. 数据一致性
   - 使用 ReplicatedMergeTree 引擎
   - 定期检查数据一致性
   - 配置合适的复制延迟阈值
   - 使用校验和验证数据

4. 读写分离
   - 专门的读副本
   - 写操作路由到主节点
   - 读操作路由到最近副本
   - 使用连接池管理连接

5. 监控告警
   - 监控副本状态
   - 监控复制延迟
   - 监控队列大小
   - 设置合理的告警阈值

6. 容灾备份
   - 跨数据中心复制
   - 定期备份
   - 测试恢复流程
   - 制定应急响应计划

7. 性能优化
   - 合理配置网络
   - 优化查询路由
   - 使用缓存
   - 监控性能指标
*/
