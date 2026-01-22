# 监控最佳实践

本文档总结了 ClickHouse 监控的最佳实践，帮助建立有效的监控体系。

## 🎯 监控设计原则

### 1. 可观测性三大支柱

#### Metrics（指标）
- **数值**: 系统性能的量化指标
- **示例**: CPU 使用率、查询延迟、磁盘空间
- **特点**: 适合告警和趋势分析

#### Logs（日志）
- **事件**: 系统发生的事件记录
- **示例**: 查询日志、错误日志、操作日志
- **特点**: 适合问题排查和审计

#### Traces（链路追踪）
- **路径**: 请求的完整执行路径
- **示例**: 分布式查询的执行过程
- **特点**: 适合性能分析和优化

### 2. 监控核心原则

| 原则 | 说明 | 实践 |
|------|------|------|
| **可度量** | 监控指标必须可量化 | 选择数值型指标 |
| **可操作** | 监控结果必须能指导行动 | 设置明确的告警阈值 |
| **可解释** | 监控数据必须能被理解 | 提供清晰的指标说明 |
| **及时性** | 监控数据必须及时更新 | 合理设置采样频率 |
| **完整性** | 监控覆盖必须全面 | 覆盖所有关键组件 |

## 📊 系统监控最佳实践

### 1. 资源监控

#### CPU 监控

```sql
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
```

#### 内存监控

```sql
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
```

#### 磁盘监控

```sql
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
```

### 2. 集群监控

```sql
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
```

## 📊 查询监控最佳实践

### 1. 慢查询监控

```sql
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
```

### 2. 查询模式分析

```sql
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
```

## 📊 数据质量监控最佳实践

### 1. 分区监控

```sql
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
```

### 2. 表结构监控

```sql
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
```

## 📊 告警最佳实践

### 1. 告警规则设计

#### 告警阈值设置

```sql
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
```

#### 告警抑制

```sql
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
```

### 2. 告警通知策略

#### 告警分级通知

```sql
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
```

## 📊 性能优化最佳实践

### 1. 监控查询优化

```sql
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
```

### 2. 日志管理

```sql
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
```

## 📊 安全监控最佳实践

### 1. 访问审计

```sql
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
```

### 2. 敏感数据访问

```sql
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
```

## 📊 运维最佳实践

### 1. 自动化监控部署

```bash
#!/bin/bash
# 自动化部署监控脚本

# 1. 创建监控数据库
clickhouse-client --query="CREATE DATABASE IF NOT EXISTS monitoring"

# 2. 创建监控视图
clickhouse-client --query="
CREATE VIEW IF NOT EXISTS monitoring.system_health AS
SELECT
    now() AS timestamp,
    'CPU' AS metric,
    (SELECT value FROM system.asynchronous_metrics WHERE metric = 'OSCPUVirtualTimeMicroseconds') AS value
UNION ALL
SELECT
    now() AS timestamp,
    'Memory' AS metric,
    (SELECT value FROM system.asynchronous_metrics WHERE metric = 'OSMemoryActive') /
    (SELECT value FROM system.asynchronous_metrics WHERE metric = 'OSMemoryTotal') * 100 AS value;
"

# 3. 创建告警视图
clickhouse-client --query="
CREATE VIEW IF NOT EXISTS monitoring.alerts AS
SELECT * FROM monitoring.alert_config WHERE enabled = 1;
"

echo "Monitoring views created successfully"
```

### 2. 定期维护任务

```sql
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
```

## ⚠️ 重要注意事项

1. **性能开销**: 监控本身会消耗资源，需要权衡监控粒度
2. **数据保留**: 合理设置日志保留时间，避免占用过多空间
3. **告警疲劳**: 合理设置告警阈值，避免频繁误报
4. **监控覆盖**: 确保监控覆盖所有关键组件
5. **定期审查**: 定期审查和优化监控配置
6. **文档更新**: 及时更新监控文档和配置
7. **培训教育**: 对运维人员进行监控培训
8. **持续改进**: 持续改进监控体系

## 📚 相关文档

- [01_system_monitoring.md](./01_system_monitoring.md) - 系统监控
- [02_query_monitoring.md](./02_query_monitoring.md) - 查询监控
- [03_data_quality_monitoring.md](./03_data_quality_monitoring.md) - 数据质量监控
- [06_alerting.md](./06_alerting.md) - 告警机制
