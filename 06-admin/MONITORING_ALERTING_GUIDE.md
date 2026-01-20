# ClickHouse 监控告警指南

本文档提供 ClickHouse 集群的监控指标采集、告警配置和监控方案。

## 目录

- [监控体系概述](#监控体系概述)
- [核心监控指标](#核心监控指标)
- [监控系统集成](#监控系统集成)
- [告警规则配置](#告警规则配置)
- [仪表盘配置](#仪表盘配置)
- [日志监控](#日志监控)
- [性能基准测试](#性能基准测试)

---

## 监控体系概述

### 监控层次

```
┌─────────────────────────────────────┐
│     应用层监控                       │
│  - 查询性能                          │
│  - 错误率                            │
│  - 业务指标                          │
└────────────┬────────────────────────┘
             │
┌────────────▼────────────────────────┐
│     数据库层监控                     │
│  - 查询延迟                          │
│  - 连接数                            │
│  - 缓存命中率                        │
└────────────┬────────────────────────┘
             │
┌────────────▼────────────────────────┐
│     基础设施监控                     │
│  - CPU 使用率                        │
│  - 内存使用                          │
│  - 磁盘 I/O                          │
│  - 网络流量                          │
└─────────────────────────────────────┘
```

### 监控工具栈

| 工具 | 用途 | 适用场景 |
|------|------|----------|
| **ClickHouse 自带** | 系统表查询 | 基础监控 |
| **Prometheus** | 指标采集和存储 | 生产环境 |
| **Grafana** | 可视化仪表盘 | 生产环境 |
| **Alertmanager** | 告警通知 | 生产环境 |
| **VictoriaMetrics** | 轻量级时序数据库 | 轻量级监控 |
| **ClickHouse Exporter** | Prometheus 导出器 | Prometheus 集成 |

---

## 核心监控指标

### 1. 可用性指标

```sql
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
```

### 2. 性能指标

```sql
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
```

### 3. 资源指标

```sql
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
```

### 4. 复制指标

```sql
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
```

### 5. 存储指标

```sql
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
```

---

## 监控系统集成

### Prometheus 集成

#### 1. 安装 ClickHouse Exporter

```bash
# 使用 Docker
docker run -d \
  --name clickhouse-exporter \
  -p 9116:9116 \
  f1ashcracker/clickhouse-exporter \
  -scrape_uri=http://clickhouse-server-1:8123 \
  -scrape_uri=http://clickhouse-server-2:8123
```

#### 2. Prometheus 配置

```yaml
# prometheus.yml
global:
  scrape_interval: 15s

scrape_configs:
  - job_name: 'clickhouse'
    static_configs:
      - targets:
        - 'clickhouse-exporter:9116'
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_scrape_uri
      - source_labels: [__param_scrape_uri]
        target_label: instance
```

#### 3. Grafana 仪表盘

推荐使用官方仪表盘：
- [ClickHouse Dashboard](https://grafana.com/grafana/dashboards/14161-clickhouse-overview/)
- [ClickHouse Cluster Dashboard](https://grafana.com/grafana/dashboards/14432-clickhouse-cluster/)

### VictoriaMetrics 集成（轻量级替代）

```bash
# 启动 VictoriaMetrics
docker run -d \
  --name victoriametrics \
  -p 8428:8428 \
  -v /data/victoria:/victoria-data \
  victoriametrics/victoria-metrics:latest \
  -storageDataPath /victoria-data \
  -httpListenAddr :8428

# 配置 ClickHouse Exporter
# 使用相同的配置文件
```

---

## 告警规则配置

### 告警等级

| 等级 | 说明 | 响应时间 | 恢复目标 |
|------|------|----------|----------|
| **P0** | 严重故障，服务完全不可用 | 5 分钟 | 30 分钟 |
| **P1** | 功能部分不可用 | 15 分钟 | 2 小时 |
| **P2** | 性能严重下降 | 30 分钟 | 4 小时 |
| **P3** | 潜在风险 | 2 小时 | 24 小时 |

### 告警规则示例

```yaml
# alerting_rules.yml
groups:
  - name: clickhouse_alerts
    interval: 30s
    rules:
      # P0: 节点不可用
      - alert: ClickHouseNodeDown
        expr: up{job="clickhouse"} == 0
        for: 1m
        labels:
          severity: critical
          priority: P0
        annotations:
          summary: "ClickHouse 节点不可用"
          description: "节点 {{ $labels.instance }} 已经不可用超过 1 分钟"

      # P1: 副本延迟过高
      - alert: ClickHouseReplicationLag
        expr: clickhouse_replication_queue_absolute_delay > 300
        for: 5m
        labels:
          severity: warning
          priority: P1
        annotations:
          summary: "ClickHouse 副本延迟过高"
          description: "副本 {{ $labels.table }} 延迟 {{ $value }} 秒"

      # P1: 磁盘空间不足
      - alert: ClickHouseDiskSpaceLow
        expr: (clickhouse_disk_space_free_bytes / clickhouse_disk_space_total_bytes) < 0.1
        for: 5m
        labels:
          severity: critical
          priority: P1
        annotations:
          summary: "ClickHouse 磁盘空间不足"
          description: "磁盘 {{ $labels.path }} 剩余空间不足 10%"

      # P2: 查询延迟过高
      - alert: ClickHouseSlowQueries
        expr: clickhouse_query_duration_seconds > 10
        for: 10m
        labels:
          severity: warning
          priority: P2
        annotations:
          summary: "ClickHouse 慢查询过多"
          description: "过去 10 分钟有超过 10 秒的查询"

      # P2: 合并积压
      - alert: ClickHouseMergeBacklog
        expr: clickhouse_background_merges_pool_size > 20
        for: 15m
        labels:
          severity: warning
          priority: P2
        annotations:
          summary: "ClickHouse 合并积压"
          description: "合并任务积压超过 20 个"

      # P3: ZooKeeper 连接断开
      - alert: ClickHouseZooKeeperDisconnected
        expr: clickhouse_zookeeper_connected == 0
        for: 5m
        labels:
          severity: warning
          priority: P3
        annotations:
          summary: "ClickHouse ZooKeeper 连接断开"
          description: "ClickHouse 无法连接到 ZooKeeper"
```

### 告警通知配置

```yaml
# alertmanager.yml
global:
  resolve_timeout: 5m

route:
  group_by: ['alertname', 'severity']
  group_wait: 10s
  group_interval: 10s
  repeat_interval: 12h
  receiver: 'default'
  routes:
    # P0 告警：立即通知
    - match:
        priority: P0
      receiver: 'pagerduty'
      continue: false

    # P1 告警：短信 + 邮件
    - match:
        priority: P1
      receiver: 'pagerduty'
      continue: true

    # P2 告警：邮件
    - match:
        priority: P2
      receiver: 'email-notifications'

    # P3 告警：每天汇总
    - match:
        priority: P3
      receiver: 'email-digest'

receivers:
  - name: 'default'
    email_configs:
      - to: 'team@example.com'
        from: 'alertmanager@example.com'

  - name: 'pagerduty'
    pagerduty_configs:
      - service_key: '<PAGERDUTY_SERVICE_KEY>'

  - name: 'email-notifications'
    email_configs:
      - to: 'team@example.com'
        from: 'alertmanager@example.com'
        headers:
          Subject: '[ALERT] {{ .GroupLabels.alertname }}'

  - name: 'email-digest'
    email_configs:
      - to: 'team@example.com'
        from: 'alertmanager@example.com'
        headers:
          Subject: '[Digest] Daily Alert Summary'
```

---

## 仪表盘配置

### Grafana 仪表盘示例

```json
{
  "dashboard": {
    "title": "ClickHouse 集群监控",
    "panels": [
      {
        "title": "节点状态",
        "targets": [
          {
            "expr": "up{job=\"clickhouse\"}",
            "legendFormat": "{{instance}}"
          }
        ],
        "type": "stat"
      },
      {
        "title": "查询 QPS",
        "targets": [
          {
            "expr": "rate(clickhouse_query_total[1m])",
            "legendFormat": "{{type}}"
          }
        ],
        "type": "graph"
      },
      {
        "title": "查询延迟",
        "targets": [
          {
            "expr": "clickhouse_query_duration_seconds_quantile{quantile=\"0.99\"}",
            "legendFormat": "P99"
          },
          {
            "expr": "clickhouse_query_duration_seconds_quantile{quantile=\"0.95\"}",
            "legendFormat": "P95"
          },
          {
            "expr": "clickhouse_query_duration_seconds_quantile{quantile=\"0.50\"}",
            "legendFormat": "P50"
          }
        ],
        "type": "graph"
      },
      {
        "title": "副本延迟",
        "targets": [
          {
            "expr": "clickhouse_replication_queue_absolute_delay",
            "legendFormat": "{{table}}"
          }
        ],
        "type": "graph"
      },
      {
        "title": "磁盘使用率",
        "targets": [
          {
            "expr": "(clickhouse_disk_space_total_bytes - clickhouse_disk_space_free_bytes) / clickhouse_disk_space_total_bytes * 100",
            "legendFormat": "{{path}}"
          }
        ],
        "type": "graph"
      },
      {
        "title": "内存使用",
        "targets": [
          {
            "expr": "clickhouse_memory_tracked",
            "legendFormat": "{{host}}"
          }
        ],
        "type": "graph"
      }
    ]
  }
}
```

---

## 日志监控

### 日志配置

```xml
<!-- config/logging.xml -->
<logger>
    <level>information</level>
    <console>true</console>
    <log>
        <remove>1</remove>
        <size>100M</size>
        <count>10</count>
    </log>
    <errorlog>
        <remove>1</remove>
        <size>100M</size>
        <count>10</count>
    </errorlog>
</logger>

<!-- 开启查询日志 -->
<query_log>
    <database>system</database>
    <table>query_log</table>
    <partition_by>toYYYYMM(event_date)</partition_by>
    <ttl>event_date + INTERVAL 30 DAY DELETE</ttl>
</query_log>

<!-- 开启查询线程日志 -->
<query_thread_log>
    <database>system</database>
    <table>query_thread_log</table>
    <partition_by>toYYYYMM(event_date)</partition_by>
    <ttl>event_date + INTERVAL 30 DAY DELETE</ttl>
</query_thread_log>

<!-- 开启文本日志 -->
<text_log>
    <database>system</database>
    <table>text_log</table>
    <partition_by>toYYYYMM(event_date)</partition_by>
    <ttl>event_date + INTERVAL 7 DAY DELETE</ttl>
</text_log>
```

### 日志查询

```sql
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
```

---

## 性能基准测试

### 基准测试脚本

```sql
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
```

### 性能指标记录

```sql
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
```

---

## 监控最佳实践

### 1. 监控频率

| 指标类型 | 采集频率 | 保留时间 |
|---------|----------|----------|
| 系统指标（CPU、内存） | 15秒 | 30天 |
| 查询指标（QPS、延迟） | 10秒 | 7天 |
| 复制指标（延迟、队列） | 30秒 | 30天 |
| 存储指标（磁盘、表大小） | 1分钟 | 90天 |
| 业务指标（行数、查询） | 5分钟 | 365天 |

### 2. 告警策略

- **告警聚合**：相同类型的告警在 10 分钟内只发送一次
- **告警升级**：P2 告警持续 30 分钟未处理升级为 P1
- **告警静默**：维护窗口期间自动静音告警
- **告警确认**：值班人员需要手动确认告警

### 3. 监控优化

1. **减少指标数量**：只保留关键指标，避免指标爆炸
2. **使用采样**：高基数指标进行采样
3. **数据压缩**：使用降采样减少存储
4. **分库分表**：根据数据量调整存储策略

---

**最后更新：** 2026-01-19
**适用版本：** ClickHouse 23.x+
**集群名称：** treasurycluster
