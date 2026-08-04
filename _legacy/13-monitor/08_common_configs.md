# 常见监控配置

本文档提供了 ClickHouse 监控的常见配置示例，涵盖基础监控、企业级监控和高可用监控。

## 🔧 基础监控配置

### 1. 查询日志配置

#### 启用查询日志

```xml
<!-- config.xml -->
<clickhouse>
    <!-- 查询日志配置 -->
    <query_log>
        <database>system</database>
        <table>query_log</table>
        <!-- 按日期分区 -->
        <partition_by>toYYYYMM(event_date)</partition_by>
        <!-- TTL: 保留 30 天 -->
        <ttl>event_date + INTERVAL 30 DAY DELETE</ttl>
        <!-- 记录所有查询类型 -->
        <type>1</type>
        <!-- 记录间隔：0 表示记录所有查询 -->
        <interval_milliseconds>0</interval_milliseconds>
    </query_log>

    <!-- 慢查询日志配置 -->
    <query_thread_log>
        <database>system</database>
        <table>query_thread_log</table>
        <partition_by>toYYYYMM(event_date)</partition_by>
        <ttl>event_date + INTERVAL 30 DAY DELETE</ttl>
    </query_thread_log>

    <!-- 错误日志配置 -->
    <text_log>
        <level>warning</level>
        <database>system</database>
        <table>text_log</table>
        <partition_by>toYYYYMM(event_date)</partition_by>
        <ttl>event_date + INTERVAL 90 DAY DELETE</ttl>
    </text_log>
</clickhouse>
```

#### 查询日志优化

```xml
<!-- 性能优化：减少日志记录量 -->
<clickhouse>
    <!-- 只记录慢查询（超过 1 秒） -->
    <query_log>
        <database>system</database>
        <table>query_log</table>
        <partition_by>toYYYYMM(event_date)</partition_by>
        <ttl>event_date + INTERVAL 30 DAY DELETE</ttl>
        <!-- 只记录 QueryFinish -->
        <type>2</type>
        <!-- 不记录内部查询 -->
        <remove_unnecessary_records>true</remove_unnecessary_records>
    </query_log>

    <!-- 采样记录：记录 10% 的查询 -->
    <trace_log>
        <database>system</database>
        <table>trace_log</table>
        <partition_by>toYYYYMM(event_date)</partition_by>
        <ttl>event_date + INTERVAL 7 DAY DELETE</ttl>
        <sampling>0.1</sampling>
    </trace_log>
</clickhouse>
```

### 2. 异步指标配置

```xml
<!-- 异步指标配置 -->
<clickhouse>
    <!-- 异步指标收集间隔：默认 1 秒 -->
    <asynchronous_metrics_log>
        <database>system</database>
        <table>asynchronous_metrics_log</table>
        <partition_by>toYYYYMM(event_date)</partition_by>
        <ttl>event_date + INTERVAL 30 DAY DELETE</ttl>
        <collect_interval_milliseconds>1000</collect_interval_milliseconds>
    </asynchronous_metrics_log>

    <!-- 异步指标历史：仅保留最近数据 -->
    <asynchronous_metric_history>
        <database>system</database>
        <table>asynchronous_metric_history</table>
        <partition_by>toYYYYMM(event_date)</partition_by>
        <ttl>event_date + INTERVAL 7 DAY DELETE</ttl>
    </asynchronous_metric_history>
</clickhouse>
```

### 3. 基础监控视图

```sql
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
```

## 🔧 企业级监控配置

### 1. 完整日志配置

```xml
<!-- 完整的企业级日志配置 -->
<clickhouse>
    <!-- 查询日志 -->
    <query_log>
        <database>system</database>
        <table>query_log</table>
        <partition_by>toYYYYMM(event_date)</partition_by>
        <ttl>event_date + INTERVAL 30 DAY DELETE</ttl>
        <type>1,2,4</type>
        <remove_unnecessary_records>true</remove_unnecessary_records>
    </query_log>

    <!-- 查询线程日志 -->
    <query_thread_log>
        <database>system</database>
        <table>query_thread_log</table>
        <partition_by>toYYYYMM(event_date)</partition_by>
        <ttl>event_date + INTERVAL 30 DAY DELETE</ttl>
    </query_thread_log>

    <!-- 异步指标日志 -->
    <asynchronous_metrics_log>
        <database>system</database>
        <table>asynchronous_metrics_log</table>
        <partition_by>toYYYYMM(event_date)</partition_by>
        <ttl>event_date + INTERVAL 30 DAY DELETE</ttl>
        <collect_interval_milliseconds>1000</collect_interval_milliseconds>
    </asynchronous_metrics_log>

    <!-- 事件日志 -->
    <event_log>
        <database>system</database>
        <table>event_log</table>
        <partition_by>toYYYYMM(event_date)</partition_by>
        <ttl>event_date + INTERVAL 30 DAY DELETE</ttl>
    </event_log>

    <!-- 系统日志 -->
    <text_log>
        <level>information</level>
        <database>system</database>
        <table>text_log</table>
        <partition_by>toYYYYMM(event_date)</partition_by>
        <ttl>event_date + INTERVAL 90 DAY DELETE</ttl>
    </text_log>

    <!-- Mutation 日志 -->
    <mutation_log>
        <database>system</database>
        <table>mutation_log</table>
        <partition_by>toYYYYMM(event_date)</partition_by>
        <ttl>event_date + INTERVAL 90 DAY DELETE</ttl>
    </mutation_log>

    <!-- 会话日志 -->
    <session_log>
        <database>system</database>
        <table>session_log</table>
        <partition_by>toYYYYMM(event_date)</partition_by>
        <ttl>event_date + INTERVAL 30 DAY DELETE</ttl>
    </session_log>

    <!-- ZooKeeper 日志 -->
    <zookeeper_log>
        <database>system</database>
        <table>zookeeper_log</table>
        <partition_by>toYYYYMM(event_date)</partition_by>
        <ttl>event_date + INTERVAL 30 DAY DELETE</ttl>
    </zookeeper_log>
</clickhouse>
```

### 2. 企业级监控视图

```sql
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
```

### 3. 告警配置表

```sql
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
```

## 🔧 高可用监控配置

### 1. Prometheus 配置

```yaml
# prometheus.yml
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  # ClickHouse 主节点监控
  - job_name: 'clickhouse-primary'
    static_configs:
      - targets: ['clickhouse-primary:9363']
        labels:
          cluster: 'treasurycluster'
          role: 'primary'

  # ClickHouse 副本节点监控
  - job_name: 'clickhouse-replica'
    static_configs:
      - targets:
          - 'clickhouse-replica1:9363'
          - 'clickhouse-replica2:9363'
        labels:
          cluster: 'treasurycluster'
          role: 'replica'

  # ClickHouse ZooKeeper 监控
  - job_name: 'zookeeper'
    static_configs:
      - targets:
          - 'zookeeper1:9363'
          - 'zookeeper2:9363'
          - 'zookeeper3:9363'
        labels:
          cluster: 'treasurycluster'
          component: 'zookeeper'
```

### 2. Grafana 仪表板配置

```json
{
  "dashboard": {
    "title": "ClickHouse Cluster Monitoring",
    "panels": [
      {
        "title": "CPU Usage",
        "type": "graph",
        "targets": [
          {
            "expr": "rate(OSCPUVirtualTimeMicroseconds[5m])",
            "legendFormat": "{{instance}}"
          }
        ]
      },
      {
        "title": "Memory Usage",
        "type": "graph",
        "targets": [
          {
            "expr": "OSMemoryActive / OSMemoryTotal * 100",
            "legendFormat": "{{instance}}"
          }
        ]
      },
      {
        "title": "Query Duration",
        "type": "graph",
        "targets": [
          {
            "expr": "histogram_quantile(0.95, rate(QueryDurationMs_bucket[5m]))",
            "legendFormat": "P95"
          },
          {
            "expr": "histogram_quantile(0.99, rate(QueryDurationMs_bucket[5m]))",
            "legendFormat": "P99"
          }
        ]
      },
      {
        "title": "Replication Lag",
        "type": "graph",
        "targets": [
          {
            "expr": "ReplicaQueueAbsoluteDelay",
            "legendFormat": "{{database}}.{{table}}"
          }
        ]
      }
    ]
  }
}
```

### 3. 高可用监控脚本

```bash
#!/bin/bash
# high_availability_monitor.sh

# 配置
CLICKHOUSE_HOSTS=("clickhouse-primary:9000" "clickhouse-replica1:9000" "clickhouse-replica2:9000")
ALERT_WEBHOOK="https://your-webhook-url/alert"
CLUSTER_NAME="treasurycluster"

# 检查节点可用性
check_node_health() {
    local host=$1
    if clickhouse-client --host "$host" --query "SELECT 1" >/dev/null 2>&1; then
        echo "OK"
    else
        echo "CRITICAL"
    fi
}

# 检查副本延迟
check_replica_lag() {
    local host=$1
    local lag=$(clickhouse-client --host "$host" --query "
        SELECT max(absolute_delay)
        FROM system.replication_queue
        WHERE database NOT IN ('system')
        GROUP BY database, table
    " 2>/dev/null)

    if [ -z "$lag" ]; then
        echo "0"
    else
        echo "$lag"
    fi
}

# 主监控循环
while true; do
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    for host in "${CLICKHOUSE_HOSTS[@]}"; do
        # 检查节点健康
        health=$(check_node_health "$host")

        # 检查副本延迟
        lag=$(check_replica_lag "$host")

        # 发送告警
        if [ "$health" = "CRITICAL" ]; then
            curl -X POST "$ALERT_WEBHOOK" \
                 -H "Content-Type: application/json" \
                 -d "{
                   \"timestamp\": \"$timestamp\",
                   \"cluster\": \"$CLUSTER_NAME\",
                   \"host\": \"$host\",
                   \"alert_type\": \"NodeDown\",
                   \"level\": \"CRITICAL\"
                 }"
        fi

        if [ "$lag" -gt 3600 ]; then
            curl -X POST "$ALERT_WEBHOOK" \
                 -H "Content-Type: application/json" \
                 -d "{
                   \"timestamp\": \"$timestamp\",
                   \"cluster\": \"$CLUSTER_NAME\",
                   \"host\": \"$host\",
                   \"alert_type\": \"ReplicaLag\",
                   \"level\": \"WARNING\",
                   \"value\": \"$lag\"
                 }"
        fi
    done

    sleep 60
done
```

## 🔧 性能优化监控配置

### 1. 采样配置

```xml
<!-- 性能优化：采样配置 -->
<clickhouse>
    <!-- 查询日志采样：记录 10% 的查询 -->
    <query_log>
        <database>system</database>
        <table>query_log</table>
        <partition_by>toYYYYMM(event_date)</partition_by>
        <ttl>event_date + INTERVAL 30 DAY DELETE</ttl>
        <!-- 采样率：0.1 = 10% -->
        <sampling>0.1</sampling>
    </query_log>

    <!-- Trace 日志采样：记录 1% 的查询 -->
    <trace_log>
        <database>system</database>
        <table>trace_log</table>
        <partition_by>toYYYYMM(event_date)</partition_by>
        <ttl>event_date + INTERVAL 7 DAY DELETE</ttl>
        <sampling>0.01</sampling>
    </trace_log>
</clickhouse>
```

### 2. 预聚合配置

```sql
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
```

## ⚠️ 重要注意事项

1. **配置测试**: 在生产环境应用配置前先在测试环境验证
2. **性能影响**: 监控配置会影响性能，需要权衡监控粒度
3. **存储空间**: 日志会占用大量存储，合理设置 TTL
4. **配置备份**: 定期备份配置文件
5. **版本兼容**: 配置可能因 ClickHouse 版本而异
6. **文档更新**: 及时更新监控配置文档
7. **定期审查**: 定期审查和优化监控配置
8. **权限控制**: 监控配置应该有严格的访问控制

## 📚 相关文档

- [01_system_monitoring.md](./01_system_monitoring.md) - 系统监控
- [02_query_monitoring.md](./02_query_monitoring.md) - 查询监控
- [06_alerting.md](./06_alerting.md) - 告警机制
- [06-admin/](../06-admin/) - 运维管理
