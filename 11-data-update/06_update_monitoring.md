# 更新监控

本文档介绍如何监控 ClickHouse 数据更新操作，包括性能指标、监控查询和告警配置。

## 监控维度

### 1. 更新操作监控

监控各类更新操作的执行情况。

```sql
-- 查看 Mutation 列表
SELECT 
    database,
    table,
    mutation_id,
    command,
    is_done,
    parts_to_do,
    parts_to_do_names,
    progress,
    exception_text,
    created_at,
    done_at
FROM system.mutations
WHERE database IN ('test_info_schema', 'test_data_deletion', 'test_date_time')
ORDER BY created DESC;
```

### 2. 系统资源监控

监控更新操作对系统资源的影响。

```sql
-- 查看 CPU 和内存使用
SELECT 
    query_id,
    user,
    query,
    thread_id,
    cpu_time_nanoseconds,
    memory_usage,
    peak_memory_usage,
    read_rows,
    read_bytes,
    written_rows,
    written_bytes,
    elapsed
FROM system.processes
WHERE query LIKE '%UPDATE%'
  OR query LIKE '%ALTER TABLE%'
ORDER BY cpu_time_nanoseconds DESC
LIMIT 10;
```

### 3. 磁盘 IO 监控

监控磁盘读写性能。

```sql
-- 查看磁盘 IO 统计
SELECT 
    event_time,
    metric,
    value
FROM system.asynchronous_metrics
WHERE metric LIKE '%Disk%'
   OR metric LIKE '%IO%'
ORDER BY event_time DESC
LIMIT 20;
```

### 4. 队列状态监控

监控后台任务队列。

```sql
-- 查看后台任务队列
SELECT 
    type,
    database,
    table,
    elapsed,
    progress,
    num_parts,
    bytes_read_uncompressed,
    rows_read,
    bytes_written_uncompressed,
    rows_written,
    result_part_names
FROM system.replication_queue
ORDER BY event_time DESC
LIMIT 20;
```

### 5. 性能指标监控

监控关键性能指标。

```sql
-- 查看性能指标
SELECT 
    event_time,
    metric,
    value,
    description
FROM system.metrics
WHERE metric LIKE '%Mutation%'
   OR metric LIKE '%Background%'
ORDER BY metric;
```

## 监控查询

### 查询 1: 更新操作统计

```sql
-- 统计更新操作
SELECT 
    database,
    table,
    count() as mutation_count,
    sum(if(is_done = 1, 1, 0)) as completed_count,
    sum(if(is_done = 0, 1, 0)) as in_progress_count,
    avg(progress) as avg_progress,
    max(progress) as max_progress
FROM system.mutations
WHERE database LIKE 'test_%'
GROUP BY database, table
ORDER BY mutation_count DESC;
```

### 查询 2: 影响分析

```sql
-- 分析更新操作的影响
SELECT 
    database,
    table,
    mutation_id,
    command,
    parts_to_do,
    sum(rows) as total_rows,
    formatReadableSize(sum(bytes_on_disk)) as total_size,
    progress,
    elapsed
FROM system.mutations
LEFT JOIN system.parts
USING (database, table)
WHERE database LIKE 'test_%'
  AND active = 1
GROUP BY database, table, mutation_id, command, parts_to_do, progress, elapsed
ORDER BY elapsed DESC;
```

### 查询 3: 错误监控

```sql
-- 监控更新操作错误
SELECT 
    database,
    table,
    mutation_id,
    command,
    is_done,
    latest_failed_part,
    latest_fail_reason,
    latest_fail_time,
    exception_text
FROM system.mutations
WHERE database LIKE 'test_%'
  AND (exception_text != '' OR is_done = 0)
ORDER BY latest_fail_time DESC;
```

### 查询 4: TTL 监控

```sql
-- 监控 TTL 删除/更新操作
-- 注意：system.ttl_tables 在某些配置中可能不可用
-- 替代方案：使用 SHOW CREATE TABLE 或查询 system.parts 查看分区变化
SELECT
    database,
    table,
    partition,
    sum(rows) AS total_rows,
    formatReadableSize(sum(bytes_on_disk)) AS total_size,
    min(modification_time) AS oldest_part_time,
    max(modification_time) AS newest_part_time
FROM system.parts
WHERE database LIKE 'test_%'
  AND active = 1
GROUP BY database, table, partition
ORDER BY database, table, partition;
```

### 查询 5: 分区删除监控

```sql
-- 监控分区操作
SELECT 
    type,
    partition_id,
    partition,
    part_name,
    rows,
    bytes_on_disk,
    event_time,
    exception_text
FROM system.part_log
WHERE database LIKE 'test_%'
  AND type IN ('DROP_PART', 'REPLACE_PART', 'EXCHANGE_PART')
ORDER BY event_time DESC
LIMIT 20;
```

## Grafana 仪表盘

### 仪表盘配置

```json
{
  "dashboard": {
    "title": "ClickHouse Update Monitoring",
    "panels": [
      {
        "title": "Mutation Progress",
        "targets": [
          {
            "query": "SELECT mutation_id, progress FROM system.mutations WHERE database LIKE 'test_%' ORDER BY created DESC LIMIT 10"
          }
        ]
      },
      {
        "title": "CPU Usage",
        "targets": [
          {
            "query": "SELECT metric, value FROM system.metrics WHERE metric = 'CPU'"
          }
        ]
      },
      {
        "title": "Memory Usage",
        "targets": [
          {
            "query": "SELECT metric, value FROM system.metrics WHERE metric = 'Memory'"
          }
        ]
      },
      {
        "title": "Disk IO",
        "targets": [
          {
            "query": "SELECT metric, value FROM system.metrics WHERE metric LIKE '%Disk%'"
          }
        ]
      },
      {
        "title": "Background Pool",
        "targets": [
          {
            "query": "SELECT metric, value FROM system.metrics WHERE metric LIKE 'BackgroundPoolSize'"
          }
        ]
      }
    ]
  }
}
```

### Prometheus 导出配置

```yaml
# prometheus.yml
global:
  scrape_interval: 15s

scrape_configs:
  - job_name: 'clickhouse'
    static_configs:
      - targets: ['localhost:9363']
```

## 告警规则

### 告警 1: 更新操作耗时过长

```yaml
# alertmanager.yml
groups:
  - name: clickhouse_updates
    rules:
      - alert: UpdateOperationTakingTooLong
        expr: clickhouse_mutation_duration_seconds > 3600
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Update operation taking too long"
          description: "Update operation {{ $labels.mutation_id }} has been running for more than 1 hour"
```

### 告警 2: 更新操作积压

```yaml
  - alert: UpdateOperationsBacklog
    expr: clickhouse_mutations_in_progress > 5
    for: 10m
    labels:
      severity: warning
    annotations:
      summary: "Too many update operations in progress"
      description: "{{ $value }} update operations are currently running"
```

### 告警 3: 更新操作错误率高

```yaml
  - alert: UpdateOperationHighErrorRate
    expr: rate(clickhouse_mutation_errors_total[5m]) > 0.1
    for: 10m
    labels:
      severity: critical
    annotations:
      summary: "High update operation error rate"
      description: "Update operation error rate is {{ $value }} errors per second"
```

### 告警 4: 空间未释放

```yaml
  - alert: DiskSpaceNotReleased
    expr: clickhouse_disk_usage_percent > 80
    for: 1h
    labels:
      severity: warning
    annotations:
      summary: "Disk space not released after update"
      description: "Disk usage is {{ $value }}% after update operations"
```

## 诊断查询

### 查询 1: 检查 Mutation 状态

```sql
-- 检查所有 Mutation 的状态
SELECT 
    database,
    table,
    mutation_id,
    command,
    is_done,
    parts_to_do,
    parts_to_do_names,
    progress,
    created_at,
    done_at,
    exception_text
FROM system.mutations
WHERE database LIKE 'test_%'
ORDER BY created DESC;
```

### 查询 2: 检查系统负载

```sql
-- 检查系统整体负载
SELECT 
    'CPU Usage' as metric,
    formatReadableSize(value) as value
FROM system.metrics
WHERE metric = 'CPU'

UNION ALL

SELECT 
    'Memory Usage' as metric,
    formatReadableSize(value) as value
FROM system.metrics
WHERE metric = 'Memory'

UNION ALL

SELECT 
    'Disk Read' as metric,
    formatReadableSize(value) as value
FROM system.asynchronous_metrics
WHERE metric = 'DiskReadBytes'

UNION ALL

SELECT 
    'Disk Write' as metric,
    formatReadableSize(value) as value
FROM system.asynchronous_metrics
WHERE metric = 'DiskWriteBytes';
```

### 查询 3: 检查队列状态

```sql
-- 检查后台任务队列
SELECT 
    type,
    database,
    table,
    elapsed,
    progress,
    num_parts,
    bytes_read_uncompressed,
    rows_read,
    bytes_written_uncompressed,
    rows_written,
    exception_text
FROM system.replication_queue
ORDER BY elapsed DESC
LIMIT 10;
```

### 查询 4: 检查分区状态

```sql
-- 检查分区状态
SELECT 
    database,
    table,
    partition,
    sum(rows) as total_rows,
    sum(bytes_on_disk) as total_bytes,
    formatReadableSize(sum(bytes_on_disk)) as readable_size,
    count() as part_count
FROM system.parts
WHERE database LIKE 'test_%'
  AND active = 1
GROUP BY database, table, partition
ORDER BY database, table, partition;
```

### 查询 5: 检查更新历史

```sql
-- 查看更新历史
SELECT 
    mutation_id,
    database,
    table,
    command,
    is_done,
    parts_to_do,
    created_at,
    done_at,
    if(done_at > created_at, 
        dateDiff('second', created_at, done_at), 
        NULL) as duration_seconds
FROM system.mutations
WHERE database LIKE 'test_%'
  AND is_done = 1
ORDER BY done_at DESC
LIMIT 20;
```

## 实战监控场景

### 场景 1: 批量更新监控

```sql
-- 监控批量更新进度
SELECT 
    database,
    table,
    mutation_id,
    command,
    is_done,
    parts_to_do,
    parts_to_do_names,
    progress,
    sum(rows) as total_rows,
    formatReadableSize(sum(bytes_on_disk)) as total_size
FROM system.mutations
LEFT JOIN system.parts
USING (database, table)
WHERE database = 'test_data_deletion'
  AND active = 1
  AND is_done = 0
GROUP BY database, table, mutation_id, command, is_done, parts_to_do, parts_to_do_names, progress
ORDER BY created DESC;
```

### 场景 2: TTL 监控

```sql
-- 监控 TTL 执行情况
-- 注意：system.ttl_tables 在某些配置中可能不可用
-- 替代方案：使用 SHOW CREATE TABLE 查看配置，使用 system.parts 查看分区
SHOW CREATE TABLE test_data_deletion.test_events_ttl;

-- 查看分区变化来推断 TTL 执行情况
SELECT
    table,
    partition,
    sum(rows) AS total_rows,
    formatReadableSize(sum(bytes_on_disk)) AS total_size,
    min(modification_time) AS oldest_part,
    max(modification_time) AS newest_part,
    dateDiff('day', max(modification_time), now()) AS days_since_last_modified
FROM system.parts
WHERE database = 'test_data_deletion'
  AND active = 1
  AND table = 'test_events_ttl'
GROUP BY table, partition
ORDER BY partition;
```

### 场景 3: 系统健康监控

```sql
-- 综合系统健康检查
SELECT 
    'Mutation Queue' as metric,
    count() as value,
    if(count() < 10, 'OK', 'WARNING') as status
FROM system.mutations
WHERE is_done = 0

UNION ALL

SELECT 
    'Failed Mutations' as metric,
    count() as value,
    if(count() = 0, 'OK', 'CRITICAL') as status
FROM system.mutations
WHERE is_done = 1 AND exception_text != ''

UNION ALL

SELECT 
    'CPU Usage %' as metric,
    value as value,
    if(value < 80, 'OK', 'WARNING') as status
FROM system.metrics
WHERE metric = 'CPU'

UNION ALL

SELECT 
    'Memory Usage %' as metric,
    value as value,
    if(value < 80, 'OK', 'WARNING') as status
FROM system.metrics
WHERE metric = 'Memory'

UNION ALL

SELECT 
    'Disk Usage %' as metric,
    value as value,
    if(value < 80, 'OK', 'WARNING') as status
FROM system.metrics
WHERE metric = 'Disk';
```

## 监控仪表盘示例

### 仪表盘 1: 更新操作概览

```sql
-- 创建综合监控视图
CREATE VIEW test_monitoring.update_overview AS
SELECT 
    'Active Mutations' as metric,
    count() as value
FROM system.mutations
WHERE is_done = 0

UNION ALL

SELECT 
    'Completed Mutations (Last 24h)' as metric,
    count() as value
FROM system.mutations
WHERE is_done = 1 
  AND done_at >= now() - INTERVAL 24 HOUR

UNION ALL

SELECT 
    'Failed Mutations (Last 24h)' as metric,
    count() as value
FROM system.mutations
WHERE is_done = 1 
  AND done_at >= now() - INTERVAL 24 HOUR
  AND exception_text != ''

UNION ALL

SELECT 
    'Average Mutation Duration (Last 24h)' as metric,
    avg(dateDiff('second', created_at, done_at)) as value
FROM system.mutations
WHERE is_done = 1 
  AND done_at >= now() - INTERVAL 24 HOUR;
```

### 仪表盘 2: 分区操作监控

```sql
-- 创建分区操作监控视图
CREATE VIEW test_monitoring.partition_operations AS
SELECT 
    type,
    count() as operation_count,
    sum(rows) as total_rows,
    formatReadableSize(sum(bytes_on_disk)) as total_size,
    min(event_time) as first_operation,
    max(event_time) as last_operation
FROM system.part_log
WHERE database LIKE 'test_%'
  AND event_time >= now() - INTERVAL 24 HOUR
GROUP BY type
ORDER BY operation_count DESC;
```

## 告警通知脚本

### 脚本 1: Mutation 进度告警

```bash
#!/bin/bash
# mutation_alert.sh

# 检查长时间运行的 Mutation
LONG_RUNNING=$(docker exec clickhouse1 clickhouse-client --query "
SELECT count()
FROM system.mutations
WHERE is_done = 0
  AND created_at < now() - INTERVAL 1 HOUR
")

if [ "$LONG_RUNNING" -gt 0 ]; then
    echo "WARNING: $LONG_RUNNING mutation(s) have been running for more than 1 hour"
    # 发送告警通知
    # curl -X POST "https://api.slack.com/..." -d "..."
fi
```

### 脚本 2: 磁盘空间告警

```bash
#!/bin/bash
# disk_alert.sh

# 检查磁盘使用率
DISK_USAGE=$(docker exec clickhouse1 clickhouse-client --query "
SELECT value
FROM system.metrics
WHERE metric = 'Disk'
")

if [ "$DISK_USAGE" -gt 80 ]; then
    echo "WARNING: Disk usage is ${DISK_USAGE}%"
    # 发送告警通知
    # curl -X POST "https://api.slack.com/..." -d "..."
fi
```

## 监控最佳实践

### 1. 分层监控

- **系统级**: CPU、内存、磁盘 IO
- **集群级**: Mutation 队列、复制状态
- **应用级**: 更新操作、查询性能

### 2. 设置合理的阈值

- **CPU 使用率**: < 80% 警告，> 90% 严重
- **内存使用率**: < 80% 警告，> 90% 严重
- **磁盘使用率**: < 80% 警告，> 90% 严重
- **Mutation 数量**: < 10 警告，> 20 严重

### 3. 定期检查

- **每日**: 检查更新操作状态
- **每周**: 分析更新性能趋势
- **每月**: 优化更新策略

### 4. 保留历史数据

- 保留至少 30 天的监控数据
- 定期归档历史数据
- 建立性能基线

### 5. 自动化响应

- 自动化告警通知
- 自动化故障恢复
- 定期自动化巡检

## 相关文档

- [01_mutation_update.md](./01_mutation_update.md) - Mutation 更新
- [02_lightweight_update.md](./02_lightweight_update.md) - 轻量级更新
- [03_partition_update.md](./03_partition_update.md) - 分区更新
- [05_update_performance.md](./05_update_performance.md) - 更新性能优化
- [07_batch_updates.md](./07_batch_updates.md) - 批量更新实战
