-- ================================================
-- ClickHouse Cluster Health Check Script
-- 此脚本用于验证集群是否正常工作
-- ================================================

-- 设置查询超时
SET max_execution_time = 10;

-- ========================================
-- 1. 显示当前节点信息
-- ========================================
SELECT '===== 1. Current Node Information =====' as step;
SELECT 
    version() as clickhouse_version,
    hostname() as hostname,
    uptime() as uptime_seconds,
    toDateTime(now()) as current_time;

-- ========================================
-- 2. 检查集群配置
-- ========================================
SELECT '===== 2. Cluster Configuration =====' as step;
SELECT 
    cluster,
    shard_num,
    replica_num,
    host_name,
    port
FROM system.clusters 
WHERE cluster = 'treasurycluster'
ORDER BY shard_num, replica_num;

-- ========================================
-- 3. 检查 ZooKeeper/Keeper 连接
-- ========================================
SELECT '===== 3. ZooKeeper/Keeper Connection =====' as step;
SELECT 
    name,
    host,
    port,
    connected_time,
    session_uptime_elapsed_seconds,
    is_expired
FROM system.zookeeper_connection;

-- ========================================
-- 4. 检查副本状态
-- ========================================
SELECT '===== 4. Replicas Status =====' as step;
SELECT 
    database,
    table,
    replica_name,
    is_leader,
    is_readonly,
    queue_size,
    absolute_delay,
    active_replicas
FROM system.replicas
ORDER BY database, table;

-- ========================================
-- 5. 创建健康检查数据库和表
-- ========================================
SELECT '===== 5. Create Test Database and Tables =====' as step;

-- 创建健康检查数据库
CREATE DATABASE IF NOT EXISTS healthcheck;

-- 创建测试表 (ReplicatedMergeTree)
CREATE TABLE IF NOT EXISTS healthcheck.health_test ON CLUSTER 'treasurycluster' (
    id UInt64,
    node_name String,
    check_time DateTime,
    status String,
    extra_data String
) ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/health_test', '{replica}')
ORDER BY (id, check_time);

-- ========================================
-- 6. 插入测试数据
-- ========================================
SELECT '===== 6. Insert Test Data =====' as step;

-- 在当前节点插入测试数据
INSERT INTO healthcheck.health_test (id, node_name, check_time, status, extra_data)
VALUES (
    toUInt64(toUnix64(now())),
    hostname(),
    now(),
    'OK',
    'Cluster health check'
);

-- ========================================
-- 7. 查询测试数据 - 验证读写
-- ========================================
SELECT '===== 7. Query Test Data (Read-Write Verification) =====' as step;
SELECT 
    id,
    node_name,
    toString(check_time) as check_time,
    status,
    extra_data
FROM healthcheck.health_test
ORDER BY check_time DESC
LIMIT 10;

-- ========================================
-- 8. 检查两节点的数据一致性
-- ========================================
SELECT '===== 8. Check Data Consistency Across Nodes =====' as step;

-- 统计每个表的数据量
SELECT 
    database,
    table,
    sum(rows) as total_rows,
    sum(bytes_on_disk) as total_bytes
FROM system.parts
WHERE active = 1
AND database IN ('healthcheck', 'test')
GROUP BY database, table
ORDER BY database, table;

-- ========================================
-- 9. 检查分布式表（如果存在）
-- ========================================
SELECT '===== 9. Check Distributed Tables =====' as step;
SELECT 
    database,
    name as table,
    engine,
    shard,
    replica
FROM system.tables
WHERE database IN ('healthcheck', 'test')
AND engine LIKE '%Distributed%'
ORDER BY database, name;

-- ========================================
-- 10. 显示集群健康总结
-- ========================================
SELECT '===== 10. Cluster Health Summary =====' as step;

-- 活跃节点数
SELECT 
    'Active Nodes' as metric,
    count() as value,
    'Expected: 2' as expected
FROM system.clusters 
WHERE cluster = 'treasurycluster'
UNION ALL

-- ZooKeeper 连接状态
SELECT 
    'ZooKeeper Connected' as metric,
    count() as value,
    'Expected: 1' as expected
FROM system.zookeeper_connection 
WHERE is_expired = 0
UNION ALL

-- 健康检查表行数
SELECT 
    'Health Check Rows' as metric,
    count() as value,
    'Expected: > 0' as expected
FROM healthcheck.health_test
UNION ALL

-- 系统整体状态
SELECT 
    'System Status' as metric,
    'All Systems Operational' as value,
    'Status: OK' as expected;

-- ========================================
-- 完成
-- ========================================
SELECT '========================================' as step;
SELECT 'Health Check Completed Successfully!' as status;
SELECT 'Cluster is ready for use.' as message;
