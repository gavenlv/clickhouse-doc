-- ================================================
-- MONITORING_ALERTING_GUIDE_examples.sql
-- 从 MONITORING_ALERTING_GUIDE.md 提取的 SQL 示例
-- 提取时间: 2026-01-23 14:40:17
-- ================================================


-- ========================================
-- 1. 可用性指标
-- ========================================

-- 1.1 节点在线状态
SELECT
    host_name() as host,
    uptime() as uptime_seconds,
    version() as version,
    now() as current_time;

-- 1.2 集群节点状态
SELECT
    cluster,
    shard_num,
    replica_num,
    host_name,
    port,
    connections,
    errors_count
FROM system.clusters
WHERE cluster = 'treasurycluster'
ORDER BY shard_num, replica_num;

-- ========================================
-- 1. 可用性指标
-- ========================================

-- 2.1 查询性能
SELECT
    event,
    value,
    description
FROM system.events
WHERE event LIKE 'Query%'
  OR event LIKE 'Select%'
ORDER BY value DESC;

-- 2.2 慢查询统计
SELECT
    countIf(query_duration_ms < 100) as fast_queries,
    countIf(query_duration_ms BETWEEN 100 AND 1000) as medium_queries,
    countIf(query_duration_ms > 1000) as slow_queries,
    avg(query_duration_ms) as avg_duration_ms,
    max(query_duration_ms) as max_duration_ms
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_time > now() - INTERVAL 1 HOUR;

-- ========================================
-- 1. 可用性指标
-- ========================================

-- 3.1 内存使用
SELECT
    formatReadableSize(total_memory) as total_memory,
    formatReadableSize(free_memory) as free_memory,
    formatReadableSize(untracked_memory) as untracked,
    formatReadableSize(total_memory - free_memory) as used,
    (total_memory - free_memory) / total_memory * 100 as used_percent
FROM system.memory;

-- 3.2 磁盘使用
SELECT
    name,
    path,
    formatReadableSize(free_space) as free,
    formatReadableSize(total_space) as total,
    formatReadableSize(total_space - free_space) as used,
    (total_space - free_space) / total_space * 100 as used_percent
FROM system.disks;

-- 3.3 CPU 使用（通过 OS 监控）
-- Linux: top, htop
-- Docker: docker stats

-- ========================================
-- 1. 可用性指标
-- ========================================

-- 4.1 副本状态
SELECT
    database,
    table,
    replica_name,
    is_leader,
    is_readonly,
    absolute_delay,
    queue_size
FROM system.replicas
ORDER BY absolute_delay DESC;

-- 4.2 复制队列
SELECT
    database,
    table,
    count(*) as queue_size,
    sum(parts_to_do) as total_parts,
    max(absolute_delay) as max_delay
FROM system.replication_queue
GROUP BY database, table
ORDER BY queue_size DESC;

-- ========================================
-- 1. 可用性指标
-- ========================================

-- 5.1 表大小统计
SELECT
    database,
    name,
    engine,
    formatReadableSize(total_rows) as rows,
    formatReadableSize(total_bytes) as size,
    formatReadableSize(total_bytes_on_disk) as disk_size
FROM system.tables
WHERE database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
ORDER BY total_bytes DESC;

-- 5.2 分区统计
SELECT
    database,
    table,
    count(DISTINCT partition) as partition_count,
    count(*) as part_count,
    formatReadableSize(sum(bytes_on_disk)) as total_size
FROM system.parts
WHERE active = 1
GROUP BY database, table
ORDER BY total_size DESC;

-- ========================================
-- 1. 可用性指标
-- ========================================

-- 查询错误日志
SELECT
    event_time,
    level,
    logger_name,
    message
FROM system.text_log
WHERE level = 'Error'
  AND event_time > now() - INTERVAL 1 HOUR
ORDER BY event_time DESC;

-- 查询慢查询
SELECT
    event_time,
    query_duration_ms / 1000 as duration_seconds,
    query,
    read_rows,
    written_rows,
    memory_usage
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query_duration_ms > 1000
  AND event_time > now() - INTERVAL 1 DAY
ORDER BY query_duration_ms DESC;

-- 查询异常查询
SELECT
    event_time,
    query,
    exception_code,
    exception_text
FROM system.query_log
WHERE type = 'Exception'
  AND event_time > now() - INTERVAL 1 DAY
ORDER BY event_time DESC;

-- ========================================
-- 1. 可用性指标
-- ========================================

-- 创建测试表
CREATE TABLE IF NOT EXISTS benchmark.test_table ON CLUSTER 'treasurycluster' (
    id UInt64,
    user_id UInt64,
    event_date Date,
    event_time DateTime,
    event_type String,
    event_data String,
    metric1 Float32,
    metric2 Float64,
    created_at DateTime DEFAULT now()
) ENGINE = ReplicatedMergeTree
PARTITION BY toYYYYMM(event_date)
ORDER BY (user_id, event_time, id)
SETTINGS index_granularity = 8192;

-- 插入测试数据
INSERT INTO benchmark.test_table
SELECT
    number as id,
    number % 1000000 as user_id,
    toDate(now() - rand() % 365) as event_date,
    toDateTime(now() - rand() % 31536000) as event_time,
    ['click', 'view', 'purchase', 'search'][rand() % 4 + 1] as event_type,
    concat('data_', toString(rand())) as event_data,
    rand() % 1000 as metric1,
    rand() / 1000000.0 as metric2,
    now() as created_at
FROM numbers(10000000);

-- 查询性能测试
-- 测试 1: 简单查询
EXPLAIN PIPELINE
SELECT count() FROM benchmark.test_table
WHERE event_date = today();

-- 测试 2: 聚合查询
EXPLAIN PIPELINE
SELECT
    event_type,
    count() as cnt,
    avg(metric1) as avg_metric,
    sum(metric2) as sum_metric
FROM benchmark.test_table
WHERE event_date >= today() - INTERVAL 7 DAY
GROUP BY event_type;

-- 测试 3: JOIN 查询
CREATE TABLE benchmark.users ON CLUSTER 'treasurycluster' (
    user_id UInt64,
    name String,
    age UInt8,
    created_at DateTime DEFAULT now()
) ENGINE = ReplicatedMergeTree
ORDER BY user_id;

INSERT INTO benchmark.users
SELECT
    number as user_id,
    concat('user_', toString(number)) as name,
    (number % 80) + 18 as age,
    now() as created_at
FROM numbers(1000000);

EXPLAIN PIPELINE
SELECT
    t.event_type,
    u.age,
    count(*) as cnt
FROM benchmark.test_table t
INNER JOIN benchmark.users u ON t.user_id = u.user_id
WHERE t.event_date = today()
GROUP BY t.event_type, u.age;

-- ========================================
-- 1. 可用性指标
-- ========================================

-- 创建性能监控表
CREATE TABLE IF NOT EXISTS monitoring.performance_metrics ON CLUSTER 'treasurycluster' (
    test_name String,
    metric_name String,
    metric_value Float64,
    timestamp DateTime DEFAULT now()
) ENGINE = MergeTree
ORDER BY (test_name, timestamp);

-- 插入性能指标
INSERT INTO monitoring.performance_metrics
VALUES
    ('query_test_1', 'execution_time_ms', 123.45, now()),
    ('query_test_1', 'rows_read', 1000000, now()),
    ('query_test_2', 'execution_time_ms', 234.56, now()),
    ('query_test_2', 'memory_bytes', 123456789, now());

-- 分析性能趋势
SELECT
    test_name,
    metric_name,
    avg(metric_value) as avg_value,
    max(metric_value) as max_value,
    min(metric_value) as min_value
FROM monitoring.performance_metrics
WHERE timestamp > now() - INTERVAL 7 DAY
GROUP BY test_name, metric_name
ORDER BY test_name, metric_name;
