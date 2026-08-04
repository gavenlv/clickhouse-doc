# 告警机制

告警机制是 ClickHouse 监控的重要组成部分，需要设置合理的告警规则和通知方式，及时发现问题。

## 🚨 告警级别

### 告警级别定义

| 级别 | 说明 | 响应时间 | 示例 |
|------|------|---------|------|
| **CRITICAL** | 严重问题，立即响应 | 5 分钟 | 集群宕机、数据丢失 |
| **WARNING** | 警告，需要关注 | 1 小时 | 资源使用率过高、性能下降 |
| **INFO** | 信息，需要记录 | 24 小时 | 常规事件、统计信息 |

## 📊 系统告警

### 1. 资源告警

#### CPU 告警

```sql
-- CPU 使用率告警
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
```

#### 内存告警

```sql
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
```

#### 磁盘告警

```sql
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
```

### 2. 集群告警

#### 副本延迟告警

```sql
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
```

#### ZooKeeper 连接告警

```sql
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
```

## 📊 查询告警

### 1. 慢查询告警

```sql
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
```

### 2. 查询超时告警

```sql
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
```

### 3. 高资源消耗查询告警

```sql
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
```

## 📊 数据质量告警

### 1. 分区倾斜告警

```sql
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
            partition,
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
            partition,
            sum(rows) AS partition_rows
        FROM system.parts
        WHERE active
          AND database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
        GROUP BY database, table, partition
    )
    GROUP BY database, table
)
WHERE skew_ratio > 10;
```

### 2. 非复制表告警

```sql
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
```

## 📊 操作告警

### 1. 频繁 ALTER 告警

```sql
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
```

### 2. 异常 DELETE 告警

```sql
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
```

## 🛠️ 告警视图

### 综合告警视图

```sql
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
```

### 告警历史视图

```sql
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
```

## 🔔 告警通知

### 告警通知方式

#### 邮件通知

```bash
# 通过邮件发送告警（示例脚本）
#!/bin/bash
clickhouse-client --query="
SELECT
    category,
    resource,
    alert_type,
    level,
    current_value,
    threshold
FROM monitoring.alerts
WHERE level IN ('CRITICAL', 'WARNING')
" | mail -s "ClickHouse Alert" admin@example.com
```

#### Webhook 通知

```bash
# 通过 Webhook 发送告警（示例脚本）
#!/bin/bash
clickhouse-client --query="
SELECT
    category,
    resource,
    alert_type,
    level,
    current_value,
    threshold
FROM monitoring.alerts
WHERE level IN ('CRITICAL', 'WARNING')
FORMAT JSONEachRow
" | while read line; do
    curl -X POST https://your-webhook-url/alert \
         -H "Content-Type: application/json" \
         -d "$line"
done
```

#### Slack 通知

```bash
# 通过 Slack 发送告警（示例脚本）
#!/bin/bash
clickhouse-client --query="
SELECT
    category,
    resource,
    alert_type,
    level,
    current_value,
    threshold
FROM monitoring.alerts
WHERE level IN ('CRITICAL', 'WARNING')
" | while read category resource alert_type level current_value threshold; do
    curl -X POST https://slack.com/api/chat.postMessage \
         -H "Authorization: Bearer YOUR_SLACK_TOKEN" \
         -H "Content-Type: application/json" \
         -d "{
           \"channel\": \"#alerts\",
           \"text\": \"ClickHouse Alert: $level - $category/$resource - $alert_type\",
           \"attachments\": [
             {
               \"text\": \"Current: $current_value, Threshold: $threshold\"
             }
           ]
         }"
done
```

## 📊 告警配置

### 告警阈值配置表

```sql
-- 创建告警配置表
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
```

## ⚠️ 重要注意事项

1. **告警疲劳**: 合理设置阈值，避免频繁误报
2. **告警分组**: 相关告警应该分组发送，避免消息轰炸
3. **告警确认**: 提供告警确认和关闭机制
4. **告警升级**: 长时间未处理的告警应该升级
5. **告警历史**: 保存告警历史用于分析
6. **联系方式**: 配置多个告警联系方式
7. **测试机制**: 定期测试告警机制
8. **权限控制**: 告警配置应该有严格的访问控制

## 📚 相关文档

- [01_system_monitoring.md](./01_system_monitoring.md) - 系统监控
- [02_query_monitoring.md](./02_query_monitoring.md) - 查询监控
- [05_abuse_detection.md](./05_abuse_detection.md) - 滥用检测
