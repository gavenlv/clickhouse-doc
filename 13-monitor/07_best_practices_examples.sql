-- ================================================
-- 07_best_practices_examples.sql
-- 从 07_best_practices.md 提取的 SQL 示例
-- 提取时间: 2026-01-23 14:40:17
-- ================================================


-- ========================================
-- CPU 监控
-- ========================================

-- ✅ 最佳实践：监控 CPU 使用率趋势
CREATE TABLE monitoring.cpu_metrics (
    timestamp DateTime,
    hostname String,
    cpu_usage_percent Float64,
    cpu_load_avg Float64
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(timestamp)
ORDER BY (timestamp, hostname);

-- ✅ 最佳实践：使用异步指标减少查询开销
SELECT
    toStartOfMinute(event_time) AS minute,
    avg(value) AS avg_cpu_usage,
    max(value) AS max_cpu_usage,
    min(value) AS min_cpu_usage
FROM system.asynchronous_metrics_log
WHERE metric = 'OSCPUVirtualTimeMicroseconds'
  AND event_time >= now() - INTERVAL 1 HOUR
GROUP BY minute;

-- ========================================
-- CPU 监控
-- ========================================

-- ✅ 最佳实践：监控内存使用率和 OOM 风险
CREATE VIEW monitoring.memory_health AS
SELECT
    now() AS timestamp,
    'Memory' AS resource,
    (SELECT value FROM system.asynchronous_metrics WHERE metric = 'OSMemoryActive') * 100.0 /
    (SELECT value FROM system.asynchronous_metrics WHERE metric = 'OSMemoryTotal') AS usage_percent,
    CASE
        WHEN (SELECT value FROM system.asynchronous_metrics WHERE metric = 'OSMemoryActive') * 100.0 /
             (SELECT value FROM system.asynchronous_metrics WHERE metric = 'OSMemoryTotal') > 90 THEN 'CRITICAL'
        WHEN (SELECT value FROM system.asynchronous_metrics WHERE metric = 'OSMemoryActive') * 100.0 /
             (SELECT value FROM system.asynchronous_metrics WHERE metric = 'OSMemoryTotal') > 80 THEN 'WARNING'
        ELSE 'OK'
    END AS status;

-- ✅ 最佳实践：监控查询内存消耗
SELECT
    user,
    count() AS high_memory_count,
    sum(memory_usage) AS total_memory_usage,
    formatReadableSize(sum(memory_usage)) AS readable_total_memory
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today()
  AND memory_usage > 1073741824  -- 超过 1GB
GROUP BY user;

-- ========================================
-- CPU 监控
-- ========================================

-- ✅ 最佳实践：监控磁盘空间和增长趋势
CREATE VIEW monitoring.disk_health AS
SELECT
    now() AS timestamp,
    name AS disk_name,
    total_space,
    available_space,
    available_space * 100.0 / total_space AS usage_percent,
    keep_free_space,
    CASE
        WHEN available_space * 100.0 / total_space < 10 THEN 'CRITICAL'
        WHEN available_space * 100.0 / total_space < 20 THEN 'WARNING'
        ELSE 'OK'
    END AS status,
    formatReadableSize(available_space) AS readable_available
FROM system.disks;

-- ✅ 最佳实践：预测磁盘空间耗尽时间
SELECT
    name AS disk_name,
    available_space,
    -- 假设每天增长 1GB
    available_space / (1024 * 1024 * 1024) AS days_until_full,
    toDateTime(now() + INTERVAL (available_space / (1024 * 1024 * 1024)) DAY) AS estimated_full_date
FROM system.disks
WHERE available_space < 107374182400  -- 小于 100GB
ORDER BY days_until_full;

-- ========================================
-- CPU 监控
-- ========================================

-- ✅ 最佳实践：监控集群健康状态
CREATE VIEW monitoring.cluster_health AS
SELECT
    cluster,
    shard_num,
    replica_num,
    host_name,
    port,
    uptime_seconds,
    errors_count,
    CASE
        WHEN errors_count > 0 THEN 'CRITICAL'
        WHEN uptime_seconds < 3600 THEN 'WARNING'
        ELSE 'OK'
    END AS status
FROM system.clusters;

-- ✅ 最佳实践：监控副本同步状态
CREATE VIEW monitoring.replication_health AS
SELECT
    database,
    table,
    replica_name,
    is_leader,
    is_readonly,
    absolute_delay,
    queue_size,
    CASE
        WHEN absolute_delay > 3600 THEN 'CRITICAL'
        WHEN absolute_delay > 1800 THEN 'WARNING'
        ELSE 'OK'
    END AS status
FROM system.replication_queue
WHERE database NOT IN ('system')
GROUP BY database, table, replica_name, is_leader, is_readonly, absolute_delay, queue_size;

-- ========================================
-- CPU 监控
-- ========================================

-- ✅ 最佳实践：使用分位数统计慢查询分布
SELECT
    user,
    count() AS total_queries,
    quantile(0.5)(query_duration_ms) / 1000 AS p50_duration_sec,
    quantile(0.9)(query_duration_ms) / 1000 AS p90_duration_sec,
    quantile(0.95)(query_duration_ms) / 1000 AS p95_duration_sec,
    quantile(0.99)(query_duration_ms) / 1000 AS p99_duration_sec
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today()
GROUP BY user;

-- ✅ 最佳实践：监控慢查询趋势
CREATE TABLE monitoring.slow_query_stats (
    date Date,
    hour UInt8,
    total_queries UInt64,
    slow_queries UInt64,
    avg_duration_ms Float64,
    p95_duration_ms Float64
) ENGINE = SummingMergeTree()
PARTITION BY toYYYYMM(date)
ORDER BY (date, hour);

-- ========================================
-- CPU 监控
-- ========================================

-- ✅ 最佳实践：识别重复查询（可优化为缓存）
SELECT
    normalized_query,
    count() AS query_count,
    sum(query_duration_ms) AS total_duration_ms,
    avg(query_duration_ms) AS avg_duration_ms
FROM (
    SELECT
        -- 简化查询以识别模式
        replaceRegexpOne(
            replaceRegexpOne(query, '\\d+', '?'),
            '\'[^\']*\'', '?'
        ) AS normalized_query,
        query_duration_ms
    FROM system.query_log
    WHERE type = 'QueryFinish'
      AND event_date >= today()
)
GROUP BY normalized_query
HAVING query_count > 100  -- 执行超过 100 次
ORDER BY query_count DESC;

-- ========================================
-- CPU 监控
-- ========================================

-- ✅ 最佳实践：监控分区均衡性
CREATE VIEW monitoring.partition_balance AS
SELECT
    database,
    table,
    partition_key,
    count() AS partition_count,
    max(partition_rows) AS max_rows,
    min(partition_rows) AS min_rows,
    avg(partition_rows) AS avg_rows,
    max(partition_rows) / greatest(min_rows, 1) AS skew_ratio,
    CASE
        WHEN max(partition_rows) / greatest(min_rows, 1) > 10 THEN 'CRITICAL'
        WHEN max(partition_rows) / greatest(min_rows, 1) > 5 THEN 'WARNING'
        ELSE 'OK'
    END AS status
FROM (
    SELECT
        database,
        table,
        partition,
        sum(rows) AS partition_rows
    FROM system.parts
    WHERE active
      AND database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
    GROUP BY database, table, partition
) AS partition_stats
JOIN system.tables USING (database, table)
GROUP BY database, table, partition_key;

-- ========================================
-- CPU 监控
-- ========================================

-- ✅ 最佳实践：监控复制表覆盖率
CREATE VIEW monitoring.replication_coverage AS
SELECT
    database,
    count() AS total_tables,
    countIf(engine ILIKE '%Replicated%') AS replicated_tables,
    (countIf(engine ILIKE '%Replicated%') * 100.0) / count() AS coverage_percent,
    CASE
        WHEN (countIf(engine ILIKE '%Replicated%') * 100.0) / count() < 90 THEN 'WARNING'
        WHEN (countIf(engine ILIKE '%Replicated%') * 100.0) / count() < 100 THEN 'INFO'
        ELSE 'OK'
    END AS status
FROM system.tables
WHERE database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
  AND total_bytes > 0
GROUP BY database;

-- ========================================
-- CPU 监控
-- ========================================

-- ✅ 最佳实践：使用多级告警阈值
CREATE TABLE monitoring.alert_thresholds (
    category String,
    resource String,
    metric String,
    warning_threshold Float64,
    critical_threshold Float64,
    duration_interval UInt32  -- 持续时间（秒）
) ENGINE = MergeTree()
ORDER BY (category, resource, metric);

-- 插入告警阈值
INSERT INTO monitoring.alert_thresholds VALUES
('System', 'CPU', 'usage_percent', 80, 90, 600),       -- 持续 10 分钟
('System', 'Memory', 'usage_percent', 85, 95, 300),    -- 持续 5 分钟
('System', 'Disk', 'usage_percent', 80, 90, 3600),    -- 持续 1 小时
('Query', 'Duration', 'seconds', 30, 300, 60),          -- 持续 1 分钟
('Replication', 'Lag', 'seconds', 1800, 3600, 300);    -- 持续 5 分钟

-- ========================================
-- CPU 监控
-- ========================================

-- ✅ 最佳实践：实现告警抑制机制
CREATE VIEW monitoring.suppressed_alerts AS
SELECT
    a.*,
    'Suppressed' AS status,
    'Maintenance mode' AS reason
FROM monitoring.alerts AS a
JOIN monitoring.maintenance_schedule AS m
    ON a.resource = m.resource
WHERE m.start_time <= now()
  AND m.end_time >= now();

-- ========================================
-- CPU 监控
-- ========================================

-- ✅ 最佳实践：根据告警级别配置不同的通知策略
CREATE TABLE monitoring.notification_policies (
    level String,
    channels Array(String),  -- email, slack, pagerduty, sms
    delay_seconds UInt32,     -- 延迟通知时间
    escalation_level UInt8    -- 升级级别
) ENGINE = MergeTree()
ORDER BY level;

-- 插入通知策略
INSERT INTO monitoring.notification_policies VALUES
('CRITICAL', ['pagerduty', 'sms', 'slack', 'email'], 0, 3),
('WARNING', ['slack', 'email'], 300, 1),  -- 延迟 5 分钟
('INFO', ['email'], 3600, 0);              -- 延迟 1 小时

-- ========================================
-- CPU 监控
-- ========================================

-- ❌ 错误做法：频繁查询 system.query_log
SELECT
    user,
    count() AS query_count
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= now() - INTERVAL 1 MINUTE  -- 每分钟查询
GROUP BY user;

-- ✅ 正确做法：使用物化视图预聚合
CREATE MATERIALIZED VIEW monitoring.query_stats_mv
ENGINE = SummingMergeTree()
PARTITION BY toYYYYMM(event_date)
ORDER BY (event_date, user)
AS SELECT
    event_date,
    user,
    count() AS query_count,
    sum(query_duration_ms) AS total_duration_ms
FROM system.query_log
WHERE type = 'QueryFinish'
GROUP BY event_date, user;

-- ✅ 正确做法：查询预聚合的数据
SELECT
    user,
    sum(query_count) AS query_count
FROM monitoring.query_stats_mv
WHERE event_date >= today()
GROUP BY user;

-- ========================================
-- CPU 监控
-- ========================================

-- ✅ 最佳实践：为查询日志设置 TTL
CREATE TABLE IF NOT EXISTS system.query_log (
    type Enum8('QueryStart' = 1, 'QueryFinish' = 2, 'ExceptionBeforeStart' = 3, 'ExceptionWhileProcessing' = 4),
    event_date Date,
    event_time DateTime,
    query_start_time DateTime,
    query_duration_ms UInt32,
    read_rows UInt64,
    read_bytes UInt64,
    written_rows UInt64,
    written_bytes UInt64,
    memory_usage UInt64,
    user String,
    query String,
    exception_code String,
    exception_text String
)
ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_date)
ORDER BY (event_date, event_time)
TTL event_date + INTERVAL 30 DAY;  -- 保留 30 天

-- ✅ 最佳实践：定期清理旧数据
OPTIMIZE TABLE system.query_log FINAL;

-- ========================================
-- CPU 监控
-- ========================================

-- ✅ 最佳实践：监控异常访问
CREATE VIEW monitoring.security_alerts AS
SELECT
    user,
    remote_address,
    count() AS query_count,
    any(substring(query, 1, 200)) AS example_query,
    CASE
        WHEN count() > 1000 AND remote_address NOT IN (SELECT remote_address FROM monitoring.allowed_ips) THEN 'SUSPICIOUS'
        WHEN remote_address = '' THEN 'UNKNOWN'
        ELSE 'OK'
    END AS risk_level
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today()
GROUP BY user, remote_address
HAVING risk_level IN ('SUSPICIOUS', 'UNKNOWN');

-- ========================================
-- CPU 监控
-- ========================================

-- ✅ 最佳实践：监控敏感表访问
CREATE VIEW monitoring.sensitive_data_access AS
SELECT
    user,
    database,
    table,
    count() AS access_count,
    any(substring(query, 1, 200)) AS example_query
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today()
  AND (
    -- 根据实际业务定义敏感表
    query ILIKE '%users%'
    OR query ILIKE '%accounts%'
    OR query ILIKE '%transactions%'
  )
GROUP BY user, database, table
ORDER BY access_count DESC;

-- ========================================
-- CPU 监控
-- ========================================

-- ✅ 最佳实践：创建定期维护表
CREATE TABLE IF NOT EXISTS monitoring.maintenance_schedule (
    id UInt64,
    resource String,
    start_time DateTime,
    end_time DateTime,
    reason String,
    created_by String
) ENGINE = MergeTree()
ORDER BY (start_time, resource);

-- ✅ 最佳实践：记录维护窗口
INSERT INTO monitoring.maintenance_schedule VALUES
(1, 'cluster', '2026-01-22 02:00:00', '2026-01-22 04:00:00', 'Scheduled maintenance', 'admin');
