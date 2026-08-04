-- =====================================================
-- 故障排查指南示例
-- =====================================================
-- 集群: treasurycluster (2副本)
-- 时间: 15-25分钟
-- =====================================================

-- -----------------------------------------------------
-- 1. 故障排查方法论
-- -----------------------------------------------------

-- 
-- ┌─────────────────────────────────────────────────────────────┐
-- │              ClickHouse 故障排查方法论                       │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                              │
-- │  故障排查流程:                                              │
-- │                                                              │
-- │  ┌─────────────────────────────────────────────────────────┐│
-- │  │                                                          ││
-- │  │  ┌─────────┐    ┌─────────┐    ┌─────────┐             ││
-- │  │  │ 发现问题 │ → │ 定位原因 │ → │ 解决问题 │             ││
-- │  │  └─────────┘    └─────────┘    └─────────┘             ││
-- │  │       │              │              │                   ││
-- │  │       ↓              ↓              ↓                   ││
-- │  │  ┌─────────┐    ┌─────────┐    ┌─────────┐             ││
-- │  │  │ 监控告警 │    │ 日志分析 │    │ 验证修复 │             ││
-- │  │  │ 用户反馈 │    │ 指标分析 │    │ 文档记录 │             ││
-- │  │  └─────────┘    └─────────┘    └─────────┘             ││
-- │  │                                                          ││
-- │  └─────────────────────────────────────────────────────────┘│
-- │                                                              │
-- │  常见故障分类:                                              │
-- │                                                              │
-- │  ┌──────────────┬──────────────────────────────────────┐   │
-- │  │    类别      │              常见问题                 │   │
-- │  ├──────────────┼──────────────────────────────────────┤   │
-- │  │ 连接问题     │ 无法连接、连接超时、认证失败         │   │
-- │  ├──────────────┼──────────────────────────────────────┤   │
-- │  │ 性能问题     │ 查询慢、写入慢、资源耗尽             │   │
-- │  ├──────────────┼──────────────────────────────────────┤   │
-- │  │ 复制问题     │ 副本延迟、会话过期、数据不一致       │   │
-- │  ├──────────────┼──────────────────────────────────────┤   │
-- │  │ 存储问题     │ 磁盘满、Part损坏、TTL异常           │   │
-- │  ├──────────────┼──────────────────────────────────────┤   │
-- │  │ 内存问题     │ OOM、内存泄漏、内存配置不当         │   │
-- │  └──────────────┴──────────────────────────────────────┘   │
-- │                                                              │
-- │  关键系统表:                                                │
-- │  - system.replicas: 副本状态                                │
-- │  - system.replication_queue: 复制队列                       │
-- │  - system.merges: 合并任务                                  │
-- │  - system.processes: 运行中查询                             │
-- │  - system.query_log: 查询历史                               │
-- │  - system.text_log: 错误日志                                │
-- │  - system.disks: 磁盘状态                                   │
-- │  - system.memory: 内存状态                                  │
-- │  - system.zookeeper: ZK连接状态                             │
-- │                                                              │
-- │  排查工具:                                                  │
-- │  - EXPLAIN: 查询计划分析                                    │
-- │  - EXPLAIN PIPELINE: 执行管道分析                           │
-- │  - SYSTEM FLUSH LOGS: 刷新日志                              │
-- │  - clickhouse-client --debug: 调试模式                     │
-- │                                                              │
-- └─────────────────────────────────────────────────────────────┘

-- ================================================
-- TROUBLESHOOTING_GUIDE_examples.sql
-- 从 TROUBLESHOOTING_GUIDE.md 提取的 SQL 示例
-- 提取时间: 2026-01-23 14:40:17
-- ================================================


-- ========================================
-- 第一步：执行健康检查
-- ========================================

-- 执行系统健康检查
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
FROM system.zookeeper;

-- ========================================
-- 第一步：执行健康检查
-- ========================================

-- 1. 检查节点是否在线
SELECT host_name(), port, version(), uptime() FROM system.one;

-- 2. 检查端口是否开放
-- Linux/Mac:
-- lsof -i :9000
-- lsof -i :8123

-- Windows:
-- netstat -ano | findstr :9000
-- netstat -ano | findstr :8123

-- 3. 检查防火墙规则
-- Linux:
-- sudo iptables -L -n | grep 9000
-- sudo iptables -L -n | grep 8123

-- Windows:
-- netsh advfirewall firewall show rule name=all

-- ========================================
-- 第一步：执行健康检查
-- ========================================

-- 检查 Keeper 连接状态
SELECT
    name,
    host,
    port,
    connected,
    latency_avg,
    requests_per_second
FROM system.zookeeper
ORDER BY index;

-- 检查副本是否连接到 Keeper
SELECT
    database,
    table,
    replica_name,
    is_session_expired,
    zookeeper_path
FROM system.replicas
WHERE is_session_expired = 1;

-- ========================================
-- 第一步：执行健康检查
-- ========================================

-- 查看会话过期的副本
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

-- ========================================
-- 第一步：执行健康检查
-- ========================================

-- 查看有延迟的副本
SELECT
    database,
    table,
    replica_name,
    is_leader,
    is_readonly,
    absolute_delay,
    queue_size,
    (log_max_index - log_pointer) as pending_logs
FROM system.replicas
WHERE absolute_delay > 0
ORDER BY absolute_delay DESC;

-- 查看复制队列
SELECT
    database,
    table,
    replica_name,
    type,
    source_replica,
    parts_to_do,
    exception_text
FROM system.replication_queue
WHERE parts_to_do > 0
ORDER BY parts_to_do DESC;

-- ========================================
-- 第一步：执行健康检查
-- ========================================

-- 查看复制错误
SELECT
    database,
    table,
    replica_name,
    source_replica,
    result_part_name,
    exception_text,
    exception_code,
    num_tries
FROM system.replication_queue
WHERE exception_code != 0
ORDER BY event_time DESC
LIMIT 20;

-- 查看最近的错误日志
SELECT
    event_time,
    level,
    logger_name,
    message
FROM system.text_log
WHERE level = 'Error'
  AND message LIKE '%replicat%'
  AND event_time > now() - INTERVAL 1 HOUR
ORDER BY event_time DESC;

-- ========================================
-- 第一步：执行健康检查
-- ========================================

-- 查看已存在的表
SELECT
    database,
    table,
    zookeeper_path,
    replica_name
FROM system.replicas
WHERE table = 'your_table';

-- ========================================
-- 第一步：执行健康检查
-- ========================================

-- 查看当前正在执行的查询
SELECT
    query_id,
    user,
    query,
    elapsed,
    read_rows,
    formatReadableSize(read_bytes) as bytes_read,
    formatReadableSize(memory_usage) as memory,
    thread_ids
FROM system.processes
ORDER BY elapsed DESC;

-- 查看慢查询历史
SELECT
    event_time,
    query_duration_ms / 1000 as duration_seconds,
    query,
    read_rows,
    formatReadableSize(read_bytes) as bytes_read,
    memory_usage
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query_duration_ms > 1000
  AND event_time > now() - INTERVAL 1 DAY
ORDER BY query_duration_ms DESC
LIMIT 20;

-- ========================================
-- 第一步：执行健康检查
-- ========================================

-- 查看内存使用
SELECT
    formatReadableSize(total_memory) as total_memory,
    formatReadableSize(free_memory) as free_memory,
    formatReadableSize(untracked_memory) as untracked,
    formatReadableSize(total_memory - free_memory) as used
FROM system.memory;

-- 查看查询内存使用
SELECT
    query_id,
    query,
    formatReadableSize(memory_usage) as memory,
    formatReadableSize(memory_usage_for_all_queries) as total_memory,
    thread_ids
FROM system.processes
WHERE query != ''
ORDER BY memory_usage DESC;

-- ========================================
-- 第一步：执行健康检查
-- ========================================

-- 查看磁盘使用
SELECT
    name,
    path,
    formatReadableSize(free_space) as free,
    formatReadableSize(total_space) as total,
    formatReadableSize(total_space - free_space) as used,
    (total_space - free_space) / total_space * 100 as used_percent
FROM system.disks;

-- 查看各表大小
SELECT
    database,
    name,
    formatReadableSize(total_bytes) as size,
    engine
FROM system.tables
WHERE database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
ORDER BY total_bytes DESC;

-- ========================================
-- 第一步：执行健康检查
-- ========================================

-- 比较两个副本的数据
SELECT
    replica_name,
    sum(rows) as total_rows,
    count(*) as part_count
FROM system.parts
WHERE active = 1
  AND database = 'your_database'
  AND table = 'your_table'
GROUP BY replica_name;

-- 查看副本同步状态
SELECT
    database,
    table,
    replica_name,
    is_leader,
    absolute_delay,
    queue_size
FROM system.replicas
WHERE database = 'your_database'
  AND table = 'your_table';

-- ========================================
-- 第一步：执行健康检查
-- ========================================

-- 系统状态摘要
SELECT
    'System Status' as category,
    metric,
    value
FROM (
    SELECT 'Uptime', formatReadableSize(uptime()) as metric, uptime() as value
    UNION ALL
    SELECT 'Memory Usage', formatReadableSize(used_memory), used_memory
    FROM (
        SELECT total_memory - free_memory as used_memory
        FROM system.memory
    )
    UNION ALL
    SELECT 'Disk Free', formatReadableSize(free_space), free_space
    FROM system.disks
    LIMIT 1
    UNION ALL
    SELECT 'Active Merges', toString(count(*)), count(*)
    FROM system.merges
    UNION ALL
    SELECT 'Replication Queue', toString(sum(queue_size)), sum(queue_size)
    FROM system.replicas
);
