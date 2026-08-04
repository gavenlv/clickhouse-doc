# 系统资源监控

系统资源监控是 ClickHouse 运维的基础，需要持续监控 CPU、内存、磁盘、网络等关键指标。

## 📊 监控指标

### 1. CPU 监控

#### CPU 使用率

```sql
-- 实时 CPU 使用情况
SELECT
    formatReadableQuantity(value) AS cpu_usage,
    profile_type
FROM system.asynchronous_metrics
WHERE metric LIKE 'OSCPU%';

-- CPU 使用趋势（最近 1 小时）
SELECT
    toStartOfMinute(event_time) AS minute,
    avg(value) AS avg_cpu_usage,
    max(value) AS max_cpu_usage,
    min(value) AS min_cpu_usage
FROM system.asynchronous_metrics_log
WHERE metric = 'OSCPUVirtualTimeMicroseconds'
  AND event_time >= now() - INTERVAL 1 HOUR
GROUP BY minute
ORDER BY minute;

-- 查询 CPU 消耗 Top 10
SELECT
    user,
    query_id,
    formatReadableSize(read_bytes) AS read_bytes,
    formatReadableSize(written_bytes) AS written_bytes,
    query_duration_ms / 1000 AS duration_sec,
    substring(query, 1, 200) AS query
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today()
GROUP BY user, query_id, read_bytes, written_bytes, query_duration_ms, query
ORDER BY duration_sec DESC
LIMIT 10;
```

#### CPU 使用告警

```sql
-- 高 CPU 使用率查询
SELECT
    user,
    count() AS query_count,
    sum(query_duration_ms) / 1000 AS total_duration_sec,
    avg(query_duration_ms) / 1000 AS avg_duration_sec
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today()
  AND query_duration_ms > 30000  -- 超过 30 秒
GROUP BY user
HAVING total_duration_sec > 3600  -- 总耗时超过 1 小时
ORDER BY total_duration_sec DESC;
```

### 2. 内存监控

#### 内存使用情况

```sql
-- 当前内存使用情况
SELECT
    metric,
    formatReadableQuantity(value) AS readable_value
FROM system.asynchronous_metrics
WHERE metric IN (
    'OSMemoryActive',
    'OSMemoryCached',
    'OSMemoryFree',
    'OSMemoryInactive',
    'OSMemoryTotal',
    'OSMemoryWired'
)
ORDER BY metric;

-- 内存使用趋势
SELECT
    toStartOfMinute(event_time) AS minute,
    avg(value) AS avg_memory_usage,
    max(value) AS max_memory_usage
FROM system.asynchronous_metrics_log
WHERE metric = 'OSMemoryActive'
  AND event_time >= now() - INTERVAL 1 HOUR
GROUP BY minute
ORDER BY minute;

-- 查询内存消耗 Top 10
SELECT
    user,
    query_id,
    formatReadableSize(memory_usage) AS memory_usage,
    query_duration_ms / 1000 AS duration_sec,
    substring(query, 1, 200) AS query
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today()
ORDER BY memory_usage DESC
LIMIT 10;
```

#### 内存使用告警

```sql
-- 高内存使用查询
SELECT
    user,
    count() AS query_count,
    sum(memory_usage) AS total_memory_usage,
    avg(memory_usage) AS avg_memory_usage
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today()
  AND memory_usage > 1073741824  -- 超过 1GB
GROUP BY user
ORDER BY total_memory_usage DESC;

-- 内存泄漏检测
SELECT
    user,
    query_id,
    memory_usage,
    query_duration_ms,
    substring(query, 1, 300) AS query
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today()
  AND memory_usage > 1073741824
  AND query_duration_ms > 600000  -- 超过 10 分钟
ORDER BY memory_usage DESC;
```

### 3. 磁盘监控

#### 磁盘使用情况

```sql
-- 磁盘空间使用
SELECT
    name AS disk_name,
    formatReadableSize(total_space) AS total_space,
    formatReadableSize(available_space) AS available_space,
    available_space * 100.0 / total_space AS available_percent,
    formatReadableSize(keep_free_space) AS keep_free_space
FROM system.disks
ORDER BY available_percent;

-- 表空间使用 Top 10
SELECT
    database,
    table,
    formatReadableSize(sum(bytes_on_disk)) AS total_size,
    count() AS part_count
FROM system.parts
WHERE active
GROUP BY database, table
ORDER BY sum(bytes_on_disk) DESC
LIMIT 10;

-- 数据库空间使用
SELECT
    database,
    formatReadableSize(sum(bytes_on_disk)) AS total_size,
    count() AS table_count,
    count(DISTINCT table) AS distinct_tables
FROM system.parts
WHERE active
GROUP BY database
ORDER BY sum(bytes_on_disk) DESC;
```

#### 磁盘 I/O 监控

```sql
-- 磁盘读写统计
SELECT
    metric,
    sum(value) AS total_value,
    formatReadableQuantity(sum(value)) AS readable_value
FROM system.events
WHERE metric IN (
    'OSReadBytes',
    'OSWriteBytes',
    'OSReadChars',
    'OSWriteChars',
    'DiskReadElapsedMicroseconds',
    'DiskWriteElapsedMicroseconds'
)
GROUP BY metric
ORDER BY metric;

-- 磁盘 I/O 趋势
SELECT
    toStartOfMinute(event_time) AS minute,
    sumIf(value, metric = 'OSReadBytes') AS read_bytes,
    sumIf(value, metric = 'OSWriteBytes') AS write_bytes
FROM system.events_log
WHERE metric IN ('OSReadBytes', 'OSWriteBytes')
  AND event_time >= now() - INTERVAL 1 HOUR
GROUP BY minute
ORDER BY minute;
```

#### 磁盘使用告警

```sql
-- 磁盘空间不足告警
SELECT
    name AS disk_name,
    available_space * 100.0 / total_space AS available_percent,
    CASE
        WHEN available_space * 100.0 / total_space < 10 THEN 'CRITICAL'
        WHEN available_space * 100.0 / total_space < 20 THEN 'WARNING'
        ELSE 'OK'
    END AS status
FROM system.disks
WHERE available_space * 100.0 / total_space < 20;

-- 大表检测
SELECT
    database,
    table,
    formatReadableSize(sum(bytes_on_disk)) AS total_size,
    sum(rows) AS total_rows,
    count() AS part_count
FROM system.parts
WHERE active
  AND bytes_on_disk > 10737418240  -- 大于 10GB
GROUP BY database, table
ORDER BY sum(bytes_on_disk) DESC;
```

### 4. 网络监控

#### 网络流量监控

```sql
-- 网络流量统计
SELECT
    metric,
    formatReadableQuantity(sum(value)) AS total_value
FROM system.events
WHERE metric IN (
    'NetworkReceiveBytes',
    'NetworkSendBytes',
    'NetworkReceiveElapsedMicroseconds',
    'NetworkSendElapsedMicroseconds'
)
GROUP BY metric
ORDER BY metric;

-- 网络流量趋势
SELECT
    toStartOfMinute(event_time) AS minute,
    sumIf(value, metric = 'NetworkReceiveBytes') AS receive_bytes,
    sumIf(value, metric = 'NetworkSendBytes') AS send_bytes
FROM system.events_log
WHERE metric IN ('NetworkReceiveBytes', 'NetworkSendBytes')
  AND event_time >= now() - INTERVAL 1 HOUR
GROUP BY minute
ORDER BY minute;

-- 远程查询统计
SELECT
    remote_address,
    count() AS query_count,
    sum(read_bytes) AS total_read_bytes,
    sum(written_bytes) AS total_written_bytes,
    avg(query_duration_ms) AS avg_duration_ms
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today()
  AND remote_address != ''
GROUP BY remote_address
ORDER BY query_count DESC;
```

### 5. 集群健康监控

#### 集群状态

```sql
-- 集群节点状态
SELECT
    cluster,
    shard_num,
    replica_num,
    host_name,
    port,
    errors_count,
    active_replicas,
    uptime_seconds / 86400 AS uptime_days
FROM system.clusters
ORDER BY cluster, shard_num, replica_num;

-- 副本同步状态
SELECT
    database,
    table,
    replica_name,
    is_leader,
    is_readonly,
    absolute_delay,
    queue_size,
    total_replicated_bytes,
    total_replication_lag_bytes
FROM system.replication_queue
GROUP BY database, table, replica_name, is_leader, is_readonly, absolute_delay, queue_size, total_replicated_bytes, total_replication_lag_bytes
HAVING absolute_delay > 3600  -- 延迟超过 1 小时
ORDER BY absolute_delay DESC;

-- ZooKeeper 连接状态
SELECT
    host,
    port,
    index,
    connected,
    operation_mode,
    avg_latency_ms,
    version
FROM system.zookeeper
WHERE connected = 0;
```

#### 分布式表状态

```sql
-- 分布式表状态
SELECT
    database,
    table,
    cluster,
    shard_num,
    replica_num,
    host_name,
    local_table,
    error_count,
    bytes_read,
    rows_read
FROM system.distributed_cache
GROUP BY database, table, cluster, shard_num, replica_num, host_name, local_table, error_count, bytes_read, rows_read
HAVING error_count > 0
ORDER BY error_count DESC;

-- 分布式查询性能
SELECT
    cluster,
    count() AS query_count,
    avg(query_duration_ms) AS avg_duration_ms,
    max(query_duration_ms) AS max_duration_ms,
    sum(read_bytes) AS total_read_bytes
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today()
  AND cluster != ''
GROUP BY cluster
ORDER BY query_count DESC;
```

## 🛠️ 监控视图

### 综合系统健康视图

```sql
-- 创建系统健康视图
CREATE VIEW monitoring.system_health AS
SELECT
    now() AS timestamp,
    'CPU' AS metric,
    'Current Usage' AS submetric,
    avgProfile(cpu) AS value,
    '%' AS unit
UNION ALL
SELECT
    now() AS timestamp,
    'Memory' AS metric,
    'Active' AS submetric,
    (SELECT value FROM system.asynchronous_metrics WHERE metric = 'OSMemoryActive') /
    (SELECT value FROM system.asynchronous_metrics WHERE metric = 'OSMemoryTotal') * 100 AS value,
    '%' AS unit
UNION ALL
SELECT
    now() AS timestamp,
    'Disk' AS metric,
    'Available' AS submetric,
    available_space * 100.0 / total_space AS value,
    '%' AS unit
FROM system.disks
UNION ALL
SELECT
    now() AS timestamp,
    'Query' AS metric,
    'Running' AS submetric,
    count() AS value,
    'count' AS unit
FROM system.processes;
```

### 系统资源趋势视图

```sql
-- 创建资源趋势视图
CREATE VIEW monitoring.resource_trends AS
SELECT
    toStartOfMinute(event_time) AS minute,
    avgIf(value, metric = 'OSCPUVirtualTimeMicroseconds') AS avg_cpu,
    avgIf(value, metric = 'OSMemoryActive') AS avg_memory,
    sumIf(value, metric = 'OSReadBytes') AS read_bytes,
    sumIf(value, metric = 'OSWriteBytes') AS write_bytes
FROM system.asynchronous_metrics_log
WHERE event_time >= now() - INTERVAL 1 HOUR
  AND metric IN ('OSCPUVirtualTimeMicroseconds', 'OSMemoryActive')
GROUP BY minute;
```

## ⚠️ 重要注意事项

1. **监控频率**: 不要过于频繁地查询系统表，避免影响性能
2. **历史数据**: 定期清理历史监控数据，避免占用过多空间
3. **告警阈值**: 合理设置告警阈值，避免误报和漏报
4. **监控开销**: 监控本身会消耗资源，需要权衡监控粒度
5. **分布式监控**: 在分布式环境中，需要监控所有节点
6. **数据保留**: 设置合理的日志保留时间，自动清理过期数据
7. **权限控制**: 监控系统应该有严格的访问控制
8. **自动化**: 尽可能实现自动化的监控和告警

## 📚 相关文档

- [02_query_monitoring.md](./02_query_monitoring.md) - 查询监控
- [06_admin/](../06-admin/) - 运维管理
- [11-performance/](../11-performance/) - 性能优化
