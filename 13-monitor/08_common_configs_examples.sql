-- ================================================
-- 08_common_configs_examples.sql
-- 从 08_common_configs.md 提取的 SQL 示例
-- 提取时间: 2026-01-23 14:40:17
-- ================================================


-- ========================================
-- 3. 基础监控视图
-- ========================================

-- 创建监控数据库
CREATE DATABASE IF NOT EXISTS monitoring;

-- 创建基础监控视图
CREATE VIEW monitoring.basic_metrics AS
SELECT
    now() AS timestamp,
    'CPU' AS metric_type,
    'Usage' AS metric_name,
    (SELECT value FROM system.asynchronous_metrics WHERE metric = 'OSCPUVirtualTimeMicroseconds') AS value
UNION ALL
SELECT
    now() AS timestamp,
    'Memory' AS metric_type,
    'Active' AS metric_name,
    (SELECT value FROM system.asynchronous_metrics WHERE metric = 'OSMemoryActive') AS value
UNION ALL
SELECT
    now() AS timestamp,
    'Memory' AS metric_type,
    'Total' AS metric_name,
    (SELECT value FROM system.asynchronous_metrics WHERE metric = 'OSMemoryTotal') AS value
UNION ALL
SELECT
    now() AS timestamp,
    'Disk' AS metric_type,
    'Available' AS metric_name,
    available_space AS value
FROM system.disks;

-- ========================================
-- 3. 基础监控视图
-- ========================================

-- 创建监控数据库
CREATE DATABASE IF NOT EXISTS monitoring;

-- 系统资源监控视图
CREATE VIEW monitoring.system_resources AS
SELECT
    now() AS timestamp,
    'CPU' AS resource_type,
    'Usage' AS metric_name,
    (SELECT value FROM system.asynchronous_metrics WHERE metric = 'OSCPUVirtualTimeMicroseconds') AS value,
    '%' AS unit
UNION ALL
SELECT
    now() AS timestamp,
    'Memory' AS resource_type,
    'Usage' AS metric_name,
    (SELECT value FROM system.asynchronous_metrics WHERE metric = 'OSMemoryActive') * 100.0 /
    (SELECT value FROM system.asynchronous_metrics WHERE metric = 'OSMemoryTotal') AS value,
    '%' AS unit
UNION ALL
SELECT
    now() AS timestamp,
    'Disk' AS resource_type,
    'Usage' AS metric_name,
    (total_space - available_space) * 100.0 / total_space AS value,
    '%' AS unit
FROM system.disks;

-- 查询性能监控视图
CREATE VIEW monitoring.query_performance AS
SELECT
    toStartOfMinute(event_time) AS minute,
    count() AS total_queries,
    countIf(query_duration_ms < 100) AS very_fast_queries,
    countIf(query_duration_ms >= 100 AND query_duration_ms < 1000) AS fast_queries,
    countIf(query_duration_ms >= 1000 AND query_duration_ms < 5000) AS normal_queries,
    countIf(query_duration_ms >= 5000) AS slow_queries,
    avg(query_duration_ms) AS avg_duration_ms,
    max(query_duration_ms) AS max_duration_ms,
    sum(read_bytes) AS total_read_bytes,
    sum(memory_usage) AS total_memory_usage
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today() - INTERVAL 7 DAY
GROUP BY minute;

-- 表健康监控视图
CREATE VIEW monitoring.table_health AS
SELECT
    database,
    table,
    engine,
    total_rows,
    total_bytes,
    formatReadableSize(total_bytes) AS readable_size,
    count() AS part_count,
    avg(rows) AS avg_rows_per_part,
    avg(bytes_on_disk) AS avg_bytes_per_part,
    CASE
        WHEN engine ILIKE '%Replicated%' THEN 'YES'
        ELSE 'NO'
    END AS is_replicated,
    CASE
        WHEN engine ILIKE '%Replicated%' THEN 'OK'
        WHEN total_bytes > 10737418240 THEN 'WARNING'
        ELSE 'OK'
    END AS status
FROM system.tables AS t
LEFT JOIN (
    SELECT
        database,
        table,
        sum(rows) AS rows,
        sum(bytes_on_disk) AS bytes_on_disk
    FROM system.parts
    WHERE active
    GROUP BY database, table
) AS p ON t.database = p.database AND t.table = p.table
WHERE t.database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
GROUP BY database, table, engine, total_rows, total_bytes
ORDER BY total_bytes DESC;

-- ========================================
-- 3. 基础监控视图
-- ========================================

-- 创建告警配置表
CREATE TABLE IF NOT EXISTS monitoring.alert_config (
    id UInt64,
    category String,        -- System, Query, DataQuality, Operation
    resource String,        -- CPU, Memory, Disk, Query, etc.
    alert_type String,      -- High Usage, Low Space, Slow Query, etc.
    level String,           -- CRITICAL, WARNING, INFO
    threshold String,        -- 告警阈值
    duration_interval UInt32, -- 持续时间（秒）
    enabled UInt8,           -- 是否启用
    description String,
    created_at DateTime DEFAULT now(),
    updated_at DateTime DEFAULT now()
)
ENGINE = MergeTree()
ORDER BY (id);

-- 插入告警配置
INSERT INTO monitoring.alert_config (id, category, resource, alert_type, level, threshold, duration_interval, enabled, description) VALUES
-- 系统告警
(1, 'System', 'CPU', 'High Usage', 'WARNING', '80%', 600, 1, 'CPU 使用率超过 80% 持续 10 分钟'),
(2, 'System', 'CPU', 'Critical Usage', 'CRITICAL', '90%', 300, 1, 'CPU 使用率超过 90% 持续 5 分钟'),
(3, 'System', 'Memory', 'High Usage', 'WARNING', '85%', 300, 1, '内存使用率超过 85% 持续 5 分钟'),
(4, 'System', 'Memory', 'Critical Usage', 'CRITICAL', '95%', 60, 1, '内存使用率超过 95% 持续 1 分钟'),
(5, 'System', 'Disk', 'Low Space', 'WARNING', '20%', 3600, 1, '磁盘可用空间低于 20%'),
(6, 'System', 'Disk', 'Critical Low Space', 'CRITICAL', '10%', 1800, 1, '磁盘可用空间低于 10%'),

-- 查询告警
(7, 'Query', 'Performance', 'Slow Query', 'WARNING', '30s', 60, 1, '查询执行时间超过 30 秒'),
(8, 'Query', 'Performance', 'Very Slow Query', 'CRITICAL', '300s', 60, 1, '查询执行时间超过 5 分钟'),
(9, 'Query', 'Memory', 'High Memory Usage', 'WARNING', '1GB', 60, 1, '查询内存使用超过 1GB'),
(10, 'Query', 'Memory', 'Very High Memory Usage', 'CRITICAL', '4GB', 60, 1, '查询内存使用超过 4GB'),

-- 数据质量告警
(11, 'DataQuality', 'Partition', 'Partition Skew', 'WARNING', '3', 3600, 1, '分区倾斜度超过 3'),
(12, 'DataQuality', 'Partition', 'Severe Partition Skew', 'CRITICAL', '10', 1800, 1, '分区倾斜度超过 10'),
(13, 'DataQuality', 'Replication', 'Non-replicated Table', 'WARNING', '10GB', 0, 1, '存在超过 10GB 的非复制表'),

-- 操作告警
(14, 'Operation', 'ALTER', 'Frequent ALTER', 'WARNING', '10/hour', 3600, 1, '1 小时内 ALTER 操作超过 10 次'),
(15, 'Operation', 'DELETE', 'Large Delete', 'WARNING', '1M rows', 0, 1, 'DELETE 操作超过 100 万行'),

-- 集群告警
(16, 'Cluster', 'Replica', 'Replica Lag', 'WARNING', '1800s', 300, 1, '副本延迟超过 30 分钟'),
(17, 'Cluster', 'Replica', 'Critical Replica Lag', 'CRITICAL', '3600s', 300, 1, '副本延迟超过 1 小时'),
(18, 'Cluster', 'ZooKeeper', 'Connection Lost', 'CRITICAL', '0', 0, 1, 'ZooKeeper 连接丢失');

-- ========================================
-- 3. 基础监控视图
-- ========================================

-- 创建预聚合物化视图
CREATE MATERIALIZED VIEW monitoring.query_stats_hourly
ENGINE = SummingMergeTree()
PARTITION BY toYYYYMM(date)
ORDER BY (date, hour, user)
AS SELECT
    toDate(event_time) AS date,
    toHour(event_time) AS hour,
    user,
    count() AS query_count,
    sum(query_duration_ms) AS total_duration_ms,
    sum(read_rows) AS total_read_rows,
    sum(read_bytes) AS total_read_bytes,
    sum(memory_usage) AS total_memory_usage
FROM system.query_log
WHERE type = 'QueryFinish'
GROUP BY date, hour, user;

-- 创建慢查询预聚合
CREATE MATERIALIZED VIEW monitoring.slow_query_stats_hourly
ENGINE = SummingMergeTree()
PARTITION BY toYYYYMM(date)
ORDER BY (date, hour, user)
AS SELECT
    toDate(event_time) AS date,
    toHour(event_time) AS hour,
    user,
    count() AS slow_query_count,
    avg(query_duration_ms) AS avg_duration_ms,
    max(query_duration_ms) AS max_duration_ms
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query_duration_ms > 5000
GROUP BY date, hour, user;
