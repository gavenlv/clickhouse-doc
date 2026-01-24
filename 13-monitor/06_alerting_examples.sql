SELECT
    'CPU' AS resource_type,
    'High Usage' AS alert_type,
    'CRITICAL' AS level,
    avg(value) AS current_value,
    80 AS threshold,
    formatReadableQuantity(avg(value)) AS readable_value
FROM system.asynchronous_metrics
WHERE metric = 'OSCPUVirtualTimeMicroseconds'
HAVING avg(value) > 80;

-- 持续高 CPU 告警
SELECT
    now() AS timestamp,
    'CPU' AS resource_type,
    'Sustained High Usage' AS alert_type,
    'CRITICAL' AS level,
    avg(value) AS current_value,
    80 AS threshold
FROM system.asynchronous_metrics_log
WHERE metric = 'OSCPUVirtualTimeMicroseconds'
  AND event_time >= now() - INTERVAL 10 MINUTE
GROUP BY resource_type, alert_type, level, threshold
HAVING avg(value) > 80;

-- ========================================
-- CPU 告警
-- ========================================

-- 内存使用率告警
SELECT
    'Memory' AS resource_type,
    'High Usage' AS alert_type,
    'CRITICAL' AS level,
    (SELECT value FROM system.asynchronous_metrics WHERE metric = 'OSMemoryActive') * 100.0 /
    (SELECT value FROM system.asynchronous_metrics WHERE metric = 'OSMemoryTotal') AS current_percent,
    85 AS threshold
HAVING current_percent > 85;

-- OOM 风险告警
SELECT
    now() AS timestamp,
    'Memory' AS resource_type,
    'OOM Risk' AS alert_type,
    'CRITICAL' AS level,
    (SELECT value FROM system.asynchronous_metrics WHERE metric = 'OSMemoryActive') * 100.0 /
    (SELECT value FROM system.asynchronous_metrics WHERE metric = 'OSMemoryTotal') AS current_percent,
    90 AS threshold
HAVING current_percent > 90;

-- ========================================
-- CPU 告警
-- ========================================

-- 磁盘空间告警
SELECT
    name AS disk_name,
    'Disk' AS resource_type,
    'Low Space' AS alert_type,
    CASE
        WHEN available_space * 100.0 / total_space < 10 THEN 'CRITICAL'
        WHEN available_space * 100.0 / total_space < 20 THEN 'WARNING'
        ELSE 'OK'
    END AS level,
    available_space * 100.0 / total_space AS current_percent,
    20 AS threshold
FROM system.disks
WHERE available_space * 100.0 / total_space < 20;

-- 磁盘空间不足告警
SELECT
    now() AS timestamp,
    name AS disk_name,
    'Disk' AS resource_type,
    'Critical Low Space' AS alert_type,
    'CRITICAL' AS level,
    available_space * 100.0 / total_space AS current_percent,
    10 AS threshold
FROM system.disks
WHERE available_space * 100.0 / total_space < 10;

-- ========================================
-- CPU 告警
-- ========================================

-- 副本延迟告警
SELECT
    database,
    table,
    replica_name,
    'Replication' AS resource_type,
    'Replica Lag' AS alert_type,
    'WARNING' AS level,
    absolute_delay AS current_seconds,
    3600 AS threshold_seconds
FROM system.replication_queue
WHERE absolute_delay > 3600  -- 延迟超过 1 小时
GROUP BY database, table, replica_name, absolute_delay;

-- 副本同步失败告警
SELECT
    database,
    table,
    replica_name,
    'Replication' AS resource_type,
    'Sync Failure' AS alert_type,
    'CRITICAL' AS level,
    queue_size AS queue_size,
    errors_count AS errors_count
FROM system.replication_queue
WHERE queue_size > 0
  AND errors_count > 0
GROUP BY database, table, replica_name, queue_size, errors_count;

-- ========================================
-- CPU 告警
-- ========================================

-- ZooKeeper 连接失败告警
SELECT
    host,
    port,
    'ZooKeeper' AS resource_type,
    'Connection Lost' AS alert_type,
    'CRITICAL' AS level,
    connected AS connected
FROM system.zookeeper
WHERE connected = 0;

-- ========================================
-- CPU 告警
-- ========================================

-- 慢查询告警
SELECT
    now() AS timestamp,
    user,
    query_id,
    'Query' AS resource_type,
    'Slow Query' AS alert_type,
    'WARNING' AS level,
    query_duration_ms / 1000 AS duration_seconds,
    30 AS threshold_seconds
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_time >= now() - INTERVAL 5 MINUTE
  AND query_duration_ms > 30000  -- 超过 30 秒
ORDER BY query_duration_ms DESC
LIMIT 10;

-- 超慢查询告警
SELECT
    now() AS timestamp,
    user,
    query_id,
    'Query' AS resource_type,
    'Very Slow Query' AS alert_type,
    'CRITICAL' AS level,
    query_duration_ms / 1000 AS duration_seconds,
    300 AS threshold_seconds
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_time >= now() - INTERVAL 5 MINUTE
  AND query_duration_ms > 300000  -- 超过 5 分钟
ORDER BY query_duration_ms DESC
LIMIT 10;

-- ========================================
-- CPU 告警
-- ========================================

-- 查询超时告警
SELECT
    now() AS timestamp,
    user,
    query_id,
    'Query' AS resource_type,
    'Query Timeout' AS alert_type,
    'WARNING' AS level,
    query_duration_ms / 1000 AS duration_seconds,
    exception_text
FROM system.query_log
WHERE type = 'ExceptionWhileProcessing'
  AND event_time >= now() - INTERVAL 5 MINUTE
  AND exception_code = 159  -- 超时错误码
ORDER BY event_time DESC;

-- ========================================
-- CPU 告警
-- ========================================

-- 高内存查询告警
SELECT
    now() AS timestamp,
    user,
    query_id,
    'Query' AS resource_type,
    'High Memory Usage' AS alert_type,
    'WARNING' AS level,
    formatReadableSize(memory_usage) AS memory_usage,
    1073741824 AS threshold_bytes  -- 1GB
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_time >= now() - INTERVAL 5 MINUTE
  AND memory_usage > 1073741824
ORDER BY memory_usage DESC
LIMIT 10;

-- 高 CPU 查询告警（长时间运行）
SELECT
    now() AS timestamp,
    user,
    query_id,
    'Query' AS resource_type,
    'Long Running Query' AS alert_type,
    'WARNING' AS level,
    query_duration_ms / 1000 AS duration_seconds,
    300 AS threshold_seconds  -- 5 分钟
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_time >= now() - INTERVAL 5 MINUTE
  AND query_duration_ms > 300000
ORDER BY query_duration_ms DESC
LIMIT 10;

-- ========================================
-- CPU 告警
-- ========================================

-- 分区倾斜告警
SELECT
    now() AS timestamp,
    database,
    table,
    'Data Quality' AS resource_type,
    'Partition Skew' AS alert_type,
    'WARNING' AS level,
    skew_ratio AS current_ratio,
    3 AS threshold_ratio
FROM (
    SELECT
        database,
        table,
        max(partition_rows) / avg(partition_rows) AS skew_ratio
    FROM (
        SELECT
            database,
            table,
            '',
            sum(rows) AS partition_rows
        FROM system.parts
        WHERE active
          AND database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
        GROUP BY database, table, partition
    )
    GROUP BY database, table
)
WHERE skew_ratio > 3;

-- 严重分区倾斜告警
SELECT
    now() AS timestamp,
    database,
    table,
    'Data Quality' AS resource_type,
    'Severe Partition Skew' AS alert_type,
    'CRITICAL' AS level,
    skew_ratio AS current_ratio,
    10 AS threshold_ratio
FROM (
    SELECT
        database,
        table,
        max(partition_rows) / avg(partition_rows) AS skew_ratio
    FROM (
        SELECT
            database,
            table,
            '',
            sum(rows) AS partition_rows
        FROM system.parts
        WHERE active
          AND database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
        GROUP BY database, table, partition
    )
    GROUP BY database, table
)
WHERE skew_ratio > 10;

-- ========================================
-- CPU 告警
-- ========================================

-- 大型非复制表告警
SELECT
    now() AS timestamp,
    database,
    table,
    'Data Quality' AS resource_type,
    'Non-replicated Table' AS alert_type,
    'WARNING' AS level,
    formatReadableSize(total_bytes) AS table_size,
    10737418240 AS threshold_bytes  -- 10GB
FROM system.tables
WHERE database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
  AND engine NOT LIKE '%Replicated%'
  AND engine NOT LIKE '%View%'
  AND engine NOT LIKE '%Dictionary%'
  AND total_bytes > 10737418240
ORDER BY total_bytes DESC;

-- ========================================
-- CPU 告警
-- ========================================

-- 频繁 ALTER 告警
SELECT
    now() AS timestamp,
    user,
    database,
    'Operation' AS resource_type,
    'Frequent ALTER' AS alert_type,
    'WARNING' AS level,
    count() AS alter_count,
    10 AS threshold_count
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_time >= now() - INTERVAL 1 HOUR
  AND query ILIKE 'ALTER%'
GROUP BY user, database
HAVING count() > 10
ORDER BY alter_count DESC;

-- ========================================
-- CPU 告警
-- ========================================

-- 大规模 DELETE 告警
SELECT
    now() AS timestamp,
    database,
    table,
    'Operation' AS resource_type,
    'Large Delete' AS alert_type,
    'WARNING' AS level,
    mutate_part_rows AS deleted_rows,
    1000000 AS threshold_rows  -- 100 万行
FROM system.mutations
WHERE created_at >= now() - INTERVAL 1 HOUR
  AND command ILIKE '%DELETE%'
  AND mutate_part_rows > 1000000
ORDER BY mutate_part_rows DESC;

-- ========================================
-- CPU 告警
-- ========================================

-- 创建综合告警视图
CREATE VIEW monitoring.alerts AS
SELECT
    now() AS timestamp,
    'System' AS category,
    'CPU' AS resource,
    'High Usage' AS alert_type,
    CASE
        WHEN avg(value) > 90 THEN 'CRITICAL'
        WHEN avg(value) > 80 THEN 'WARNING'
        ELSE 'OK'
    END AS level,
    formatReadableQuantity(avg(value)) AS current_value,
    '80%' AS threshold
FROM system.asynchronous_metrics
WHERE metric = 'OSCPUVirtualTimeMicroseconds'
HAVING avg(value) > 80

UNION ALL

SELECT
    now() AS timestamp,
    'System' AS category,
    'Disk' AS resource,
    'Low Space' AS alert_type,
    CASE
        WHEN available_space * 100.0 / total_space < 10 THEN 'CRITICAL'
        WHEN available_space * 100.0 / total_space < 20 THEN 'WARNING'
        ELSE 'OK'
    END AS level,
    formatReadableSize(available_space) AS current_value,
    '20%' AS threshold
FROM system.disks
WHERE available_space * 100.0 / total_space < 20

UNION ALL

SELECT
    now() AS timestamp,
    'Query' AS category,
    'Slow Query' AS resource,
    'Long Duration' AS alert_type,
    'WARNING' AS level,
    formatReadableQuantity(query_duration_ms) AS current_value,
    '30000ms' AS threshold
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_time >= now() - INTERVAL 5 MINUTE
  AND query_duration_ms > 30000
LIMIT 10

UNION ALL

SELECT
    now() AS timestamp,
    'Replication' AS category,
    'Replica' AS resource,
    'Replica Lag' AS alert_type,
    'WARNING' AS level,
    formatReadableQuantity(absolute_delay) AS current_value,
    '3600s' AS threshold
FROM system.replication_queue
WHERE absolute_delay > 3600
GROUP BY absolute_delay;

-- ========================================
-- CPU 告警
-- ========================================

-- 创建告警历史视图（需要配合历史数据表）
CREATE VIEW monitoring.alert_history AS
SELECT
    timestamp,
    category,
    resource,
    alert_type,
    level,
    current_value,
    threshold,
    current_value > threshold AS is_alert
FROM monitoring.alerts
WHERE is_alert = 1;

-- ========================================
-- CPU 告警
-- ========================================

-- 创建告警配置表
DROP TABLE IF EXISTS monitoring.alert_config;
CREATE TABLE IF NOT EXISTS monitoring.alert_config (
    category String,
    resource String,
    alert_type String,
    level String,
    threshold String,
    enabled UInt8,
    description String,
    updated_at DateTime DEFAULT now()
)
ENGINE = MergeTree()
ORDER BY (category, resource, alert_type);

-- 插入告警配置
INSERT INTO monitoring.alert_config (category, resource, alert_type, level, threshold, enabled, description) VALUES
('System', 'CPU', 'High Usage', 'WARNING', '80', 1, 'CPU 使用率超过 80%'),
('System', 'CPU', 'Critical Usage', 'CRITICAL', '90', 1, 'CPU 使用率超过 90%'),
('System', 'Memory', 'High Usage', 'WARNING', '85', 1, '内存使用率超过 85%'),
('System', 'Memory', 'Critical Usage', 'CRITICAL', '90', 1, '内存使用率超过 90%'),
('System', 'Disk', 'Low Space', 'WARNING', '20', 1, '磁盘可用空间低于 20%'),
('System', 'Disk', 'Critical Low Space', 'CRITICAL', '10', 1, '磁盘可用空间低于 10%'),
('Query', 'Performance', 'Slow Query', 'WARNING', '30', 1, '查询执行时间超过 30 秒'),
('Query', 'Performance', 'Very Slow Query', 'CRITICAL', '300', 1, '查询执行时间超过 5 分钟'),
('Replication', 'Replica', 'Replica Lag', 'WARNING', '3600', 1, '副本延迟超过 1 小时'),
('Data Quality', 'Partition', 'Partition Skew', 'WARNING', '3', 1, '分区倾斜度超过 3'),
('Operation', 'ALTER', 'Frequent ALTER', 'WARNING', '10', 1, '1 小时内 ALTER 操作超过 10 次');
