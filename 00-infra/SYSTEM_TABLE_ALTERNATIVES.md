# 系统表替代方案文档

本文档记录了在某些配置中不可用的系统表及其替代方案。

## 不可用系统表清单

### 1. system.ttl_tables

**状态**: 在某些 ClickHouse 配置中不可用

**原用途**:
- 查看表的 TTL (Time-To-Live) 配置
- 监控 TTL 删除/更新操作
- 查看受影响的分区和执行状态

**替代方案**:

#### 方案 1: SHOW CREATE TABLE
```sql
-- 查看表的 TTL 定义
SHOW CREATE TABLE your_database.your_table;
```
通过 `SHOW CREATE TABLE` 可以查看表的完整 DDL，包括 TTL 配置。

#### 方案 2: 使用 system.parts 监控分区变化
```sql
-- 查看分区变化来推断 TTL 执行情况
SELECT
    table,
    partition,
    sum(rows) AS total_rows,
    formatReadableSize(sum(bytes_on_disk)) AS total_size,
    min(modification_time) AS oldest_part_time,
    max(modification_time) AS newest_part_time,
    dateDiff('day', max(modification_time), now()) AS days_since_last_modified
FROM system.parts
WHERE database = 'your_database'
  AND active = 1
  AND table = 'your_table'
GROUP BY table, partition
ORDER BY partition;
```
通过监控分区的修改时间和数据量，可以推断 TTL 是否正在执行。

**相关文件**:
- `test_all_topics.sql` - 第301-311行已替换
- `11-data-update/06_update_monitoring.md` - 已更新

---

### 2. system.asynchronous_metrics_log

**状态**: 需要额外配置，默认可能不可用

**原用途**:
- 查看异步指标的历史数据（如内存使用趋势、CPU 使用趋势）
- 分析性能趋势和异常
- 创建性能基线

**替代方案**:

#### 方案 1: 使用 system.asynchronous_metrics 查看当前状态
```sql
-- 查看当前内存使用情况
SELECT
    metric,
    value,
    formatReadableSize(value) AS readable_value
FROM system.asynchronous_metrics
WHERE metric LIKE '%Memory%'
ORDER BY metric;
```
只能查看当前状态，无法查看历史趋势。

#### 方案 2: 使用 system.query_log 分析查询性能
```sql
-- 按小时分析内存使用趋势
SELECT
    toHour(event_time) AS hour,
    avg(memory_usage) AS avg_memory_usage,
    max(memory_usage) AS max_memory_usage,
    count() AS query_count
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today()
GROUP BY hour
ORDER BY hour;
```
通过分析查询日志中的内存使用情况，可以获得趋势信息。

#### 方案 3: 创建自定义日志表（高级）
```sql
-- 创建自定义的异步指标日志表
CREATE TABLE IF NOT EXISTS monitoring.async_metrics_history (
    event_time DateTime,
    metric String,
    value Float64
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (metric, event_time);

-- 定期插入数据（通过外部脚本或调度任务）
-- INSERT INTO monitoring.async_metrics_history
-- SELECT now(), metric, value FROM system.asynchronous_metrics;
```

**相关文件**:
- `13-monitor/01_system_monitoring_queries.sql` - 第54-58行已替换

---

### 3. system.zookeeper

**状态**: 可能返回 400 错误，需要特定权限或配置

**原用途**:
- 查看 ZooKeeper/Keeper 连接状态
- 监控分布式协调服务
- 检查集群健康状态

**替代方案**:

#### 方案 1: 使用 system.replicas 查看复制状态
```sql
-- 查看副本状态，间接反映分布式协调状态
SELECT
    database,
    table,
    replica_name,
    is_leader,
    can_become_leader,
    is_readonly,
    queue_size,
    absolute_delay,
    formatReadableTimeDelta(absolute_delay) AS delay_readable
FROM system.replicas
WHERE database NOT IN ('system', 'information_schema', 'default')
ORDER BY database, table;
```
通过副本状态可以间接了解分布式协调是否正常。

#### 方案 2: 使用 system.clusters 查看集群状态
```sql
-- 查看集群状态
SELECT
    cluster,
    shard_num,
    replica_num,
    host_name,
    port,
    user,
    errors_count,
    slowdowns_count
FROM system.clusters
WHERE cluster = 'your_cluster_name'
ORDER BY shard_num, replica_num;
```
查看集群节点的连接状态。

#### 方案 3: 使用 system.zookeeper_connection（如果可用）
```sql
-- 查看 Keeper 连接状态（某些版本可用）
SELECT *
FROM system.zookeeper_connection;
```

**相关文件**:
- `02-advance/03_monitoring_metrics.sql` - 已更新
- `08-information-schema/08_system_tables.md` - 已更新

---

## 其他需要注意的问题

### 列名差异

不同 ClickHouse 版本的系统表列名可能有所不同：

#### system.processes
- 旧版本: `rows_read`, `bytes_read`
- 新版本: `read_rows`, `read_bytes`
- 解决方案: 使用 `read_rows`, `read_bytes`

#### system.mutations
- 列名差异: `created` → `create_time`
- 列移除: `progress` 列在某些版本中已移除
- 解决方案: 使用 `create_time`，移除 `progress` 相关查询

#### system.asynchronous_metrics / system.disks
- 列名差异: `available_space` → `unreserved_space` 或 `keep_free_space`
- 解决方案: 使用 `unreserved_space` 和 `keep_free_space`

### 表不存在

有些系统表可能根本不存在或被移除：
- `system.ttl_tables` - 在某些配置中不存在
- `system.asynchronous_metrics_log` - 需要配置日志系统
- `system.zookeeper` - 某些版本或配置下不可用

---

## 推荐的监控系统方案

### 1. 简单监控（基于内置表）

```sql
-- 综合健康检查
SELECT
    'Replica Status' as category,
    count() as value,
    if(sumIf(1, queue_size > 0) = 0, 'OK', 'WARNING') as status
FROM system.replicas
WHERE database NOT IN ('system', 'information_schema', 'default')

UNION ALL

SELECT
    'Active Tables',
    count(),
    'OK'
FROM system.parts
WHERE active = 1

UNION ALL

SELECT
    'Running Queries',
    count(),
    if(max(elapsed) < 300, 'OK', 'WARNING')
FROM system.processes

UNION ALL

SELECT
    'Disk Space',
    formatReadableSize(unreserved_space),
    if(unreserved_space > keep_free_space * 2, 'OK', 'WARNING')
FROM system.disks
LIMIT 1;
```

### 2. 高级监控（集成外部工具）

推荐使用 Grafana + Prometheus 进行专业的监控：
- 使用 ClickHouse 的 Prometheus exporter
- 配置自定义查询和告警规则
- 创建可视化仪表板

### 3. 自定义监控表

创建自定义的监控历史表，定期记录关键指标：

```sql
-- 创建监控历史表
CREATE TABLE IF NOT EXISTS monitoring.metrics_history (
    event_time DateTime,
    metric_name String,
    metric_value Float64,
    metadata String
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (metric_name, event_time);

-- 定期插入数据（通过 crontab 或调度系统）
-- 示例：每分钟记录一次内存使用
-- INSERT INTO monitoring.metrics_history
-- SELECT
--     now() as event_time,
--     'memory_usage' as metric_name,
--     value as metric_value,
--     'system.asynchronous_metrics' as metadata
-- FROM system.asynchronous_metrics
-- WHERE metric = 'OSMemoryActive';
```

---

## 健康检查脚本

### Windows PowerShell 脚本

```powershell
# check_system_health.ps1
# ClickHouse 系统健康检查脚本

$CH_HOST = "http://localhost:8123"

# 检查副本状态
$replicaStatus = Invoke-WebRequest -Uri "$CH_HOST/?query=$( [System.Web.HttpUtility]::UrlEncode('SELECT sumIf(1, queue_size > 0) FROM system.replicas WHERE database NOT IN (''''system'''', ''''information_schema'''', ''''default'''')') )" -UseBasicParsing

if ($replicaStatus.Content -gt 0) {
    Write-Host "WARNING: Some replicas have queue backlog" -ForegroundColor Yellow
} else {
    Write-Host "OK: All replicas are in sync" -ForegroundColor Green
}

# 检查磁盘空间
$diskStatus = Invoke-WebRequest -Uri "$CH_HOST/?query=$( [System.Web.HttpUtility]::UrlEncode('SELECT unreserved_space < keep_free_space * 2 FROM system.disks LIMIT 1') )" -UseBasicParsing

if ($diskStatus.Content -eq "1") {
    Write-Host "WARNING: Disk space is low" -ForegroundColor Yellow
} else {
    Write-Host "OK: Disk space is sufficient" -ForegroundColor Green
}
```

### Bash 脚本

```bash
#!/bin/bash
# check_system_health.sh
# ClickHouse 系统健康检查脚本

CH_HOST="http://localhost:8123"

# 检查副本状态
REPLICA_BACKLOG=$(curl -s "$CH_HOST/?query=SELECT sumIf(1, queue_size > 0) FROM system.replicas WHERE database NOT IN ('system', 'information_schema', 'default')")

if [ "$REPLICA_BACKLOG" -gt 0 ]; then
    echo "WARNING: Some replicas have queue backlog"
else
    echo "OK: All replicas are in sync"
fi

# 检查磁盘空间
DISK_LOW=$(curl -s "$CH_HOST/?query=SELECT unreserved_space < keep_free_space * 2 FROM system.disks LIMIT 1")

if [ "$DISK_LOW" -eq 1 ]; then
    echo "WARNING: Disk space is low"
else
    echo "OK: Disk space is sufficient"
fi
```

---

## 总结

1. **system.ttl_tables** → 使用 `SHOW CREATE TABLE` 或 `system.parts`
2. **system.asynchronous_metrics_log** → 使用 `system.query_log` 或创建自定义日志表
3. **system.zookeeper** → 使用 `system.replicas` 或 `system.clusters`

这些替代方案可以在大多数 ClickHouse 配置中正常工作，并提供了类似的功能。
