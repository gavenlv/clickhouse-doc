# 集群和副本信息

本文档介绍如何查询和管理 ClickHouse 的集群（Clusters）和副本（Replicas）。

## 📊 system.clusters

### 查看集群配置

```sql
-- 查看所有集群
SELECT
    cluster,
    shard_num,
    replica_num,
    host_name,
    port,
    user,
    default_database,
    errors_count,
    slowdowns_count,
    estimated_recovery_time
FROM system.clusters
ORDER BY cluster, shard_num, replica_num;
```

### 查看特定集群

```sql
-- 查看 treasurycluster 集群详情
SELECT
    cluster,
    shard_num,
    replica_num,
    host_name,
    port,
    user,
    default_database,
    errors_count,
    slowdowns_count,
    estimated_recovery_time
FROM system.clusters
WHERE cluster = 'treasurycluster'
ORDER BY shard_num, replica_num;
```

### 常用字段说明

| 字段 | 类型 | 说明 |
|------|------|------|
| `cluster` | String | 集群名称 |
| `shard_num` | UInt32 | 分片编号 |
| `replica_num` | UInt32 | 副本编号 |
| `host_name` | String | 主机名 |
| `port` | UInt16 | 端口号 |
| `user` | String | 用户名 |
| `default_database` | String | 默认数据库 |
| `errors_count` | UInt32 | 错误计数 |
| `slowdowns_count` | UInt32 | 减速计数 |
| `estimated_recovery_time` | UInt32 | 预计恢复时间（秒） |

## 🔄 system.replicas

### 查看所有副本状态

```sql
-- 查看所有复制表的副本状态
SELECT
    database,
    table,
    replica_name,
    is_leader,
    is_readonly,
    is_session_expired,
    queue_size,
    absolute_delay,
    relative_delay,
    last_queue_update,
    active_replicas,
    total_replicas
FROM system.replicas
WHERE database != 'system'
ORDER BY database, table, replica_name;
```

### 查看有延迟的副本

```sql
-- 查看有复制延迟的副本
SELECT
    database,
    table,
    replica_name,
    absolute_delay,
    relative_delay,
    queue_size,
    is_leader,
    is_readonly,
    is_session_expired
FROM system.replicas
WHERE absolute_delay > 0 OR queue_size > 0
ORDER BY absolute_delay DESC, queue_size DESC;
```

### 常用字段说明

| 字段 | 类型 | 说明 |
|------|------|------|
| `database` | String | 数据库名称 |
| `table` | String | 表名称 |
| `replica_name` | String | 副本名称 |
| `is_leader` | UInt8 | 是否为主节点 |
| `is_readonly` | UInt8 | 是否为只读 |
| `is_session_expired` | UInt8 | 会话是否过期 |
| `queue_size` | UInt64 | 复制队列大小 |
| `absolute_delay` | UInt64 | 绝对延迟（秒） |
| `relative_delay` | UInt64 | 相对延迟（秒） |
| `active_replicas` | UInt32 | 活动副本数 |
| `total_replicas` | UInt32 | 总副本数 |

## 📈 复制队列

### 查看复制队列

```sql
-- 查看复制队列中的任务
SELECT
    database,
    table,
    replica_name,
    position,
    node_name,
    type,
    event_type,
    exception_code,
    exception_text
FROM system.replication_queue
WHERE database = 'your_database'
  AND table = 'your_table'
ORDER BY position;
```

### 查看阻塞的复制任务

```sql
-- 查看有异常的复制任务
SELECT
    database,
    table,
    replica_name,
    type,
    event_type,
    exception_code,
    exception_text,
    num_tries,
    num_failures
FROM system.replication_queue
WHERE exception_code != 0
ORDER BY database, table, replica_name, position;
```

## 🎯 集群健康检查

### 整体健康状态

```sql
-- 集群健康检查
SELECT
    'Cluster Health' AS check_type,
    count() AS total_nodes,
    sumIf(1, errors_count = 0) AS healthy_nodes,
    sumIf(1, errors_count > 0) AS unhealthy_nodes,
    max(errors_count) AS max_errors,
    avg(slowdowns_count) AS avg_slowdowns
FROM system.clusters
WHERE cluster = 'treasurycluster';
```

### 副本状态检查

```sql
-- 副本状态检查
SELECT
    'Replica Status' AS check_type,
    count() AS total_replicas,
    sumIf(1, is_leader = 1) AS leaders,
    sumIf(1, is_readonly = 1) AS readonly_replicas,
    sumIf(1, is_session_expired = 1) AS expired_sessions,
    sumIf(1, absolute_delay > 10) AS delayed_replicas,
    max(absolute_delay) AS max_delay_seconds
FROM system.replicas
WHERE database != 'system';
```

### 数据一致性检查

```sql
-- 检查副本数据一致性
SELECT
    database,
    table,
    active_replicas,
    total_replicas,
    (total_replicas - active_replicas) AS inactive_replicas,
    CASE
        WHEN active_replicas = total_replicas THEN 'OK'
        ELSE 'WARNING'
    END AS status
FROM system.replicas
WHERE database != 'system'
  AND total_replicas > 1
ORDER BY status DESC, (total_replicas - active_replicas) DESC;
```

## 🔍 分布式表分析

### 查看分布式表

```sql
-- 查看所有分布式表
SELECT
    database,
    name AS table,
    cluster,
    sharding_key,
    distributed_table,
    formatReadableSize(total_bytes) AS size
FROM system.tables
WHERE engine = 'Distributed'
  AND database != 'system'
ORDER BY database, name;
```

### 查看分布式表的本地表

```sql
-- 查看分布式表对应的本地表
SELECT
    dt.database,
    dt.name AS distributed_table,
    dt.cluster,
    dt.sharding_key,
    lt.name AS local_table,
    lt.total_rows AS local_rows,
    formatReadableSize(lt.total_bytes) AS local_size
FROM system.tables AS dt
JOIN system.tables AS lt ON 
    dt.database = lt.database 
    AND lt.name = dt.distributed_table
WHERE dt.engine = 'Distributed'
  AND dt.database != 'system'
ORDER BY dt.database, dt.name;
```

## 🎯 实战场景

### 场景 1: 监控复制延迟

```sql
-- 实时监控复制延迟
SELECT
    database,
    table,
    replica_name,
    absolute_delay,
    relative_delay,
    queue_size,
    last_queue_update,
    now() - last_queue_update AS seconds_since_update,
    CASE
        WHEN absolute_delay > 300 THEN 'CRITICAL'
        WHEN absolute_delay > 60 THEN 'WARNING'
        ELSE 'OK'
    END AS status
FROM system.replicas
WHERE database != 'system'
ORDER BY absolute_delay DESC;
```

### 场景 2: 查找只读副本

```sql
-- 查找只读副本
SELECT
    database,
    table,
    replica_name,
    is_leader,
    is_readonly,
    is_session_expired,
    absolute_delay,
    queue_size
FROM system.replicas
WHERE database != 'system'
  AND (is_readonly = 1 OR is_session_expired = 1)
ORDER BY database, table, replica_name;
```

### 场景 3: 分析集群负载

```sql
-- 分析集群各节点的负载
SELECT
    cluster,
    shard_num,
    replica_num,
    host_name,
    errors_count,
    slowdowns_count,
    estimated_recovery_time,
    CASE
        WHEN errors_count > 0 OR slowdowns_count > 100 THEN 'HIGH LOAD'
        WHEN slowdowns_count > 10 THEN 'MEDIUM LOAD'
        ELSE 'NORMAL'
    END AS load_status
FROM system.clusters
WHERE cluster = 'treasurycluster'
ORDER BY errors_count DESC, slowdowns_count DESC;
```

### 场景 4: 检查副本数量

```sql
-- 检查表的副本数量
SELECT
    database,
    table,
    active_replicas,
    total_replicas,
    (total_replicas - active_replicas) AS missing_replicas,
    CASE
        WHEN active_replicas < total_replicas THEN 'INSUFFICIENT REPLICAS'
        ELSE 'OK'
    END AS status
FROM system.replicas
WHERE database != 'system'
  AND total_replicas > 1
ORDER BY missing_replicas DESC;
```

### 场景 5: 查找积压的复制队列

```sql
-- 查找积压严重的复制队列
SELECT
    database,
    table,
    replica_name,
    queue_size,
    absolute_delay,
    num_tries,
    num_failures,
    exception_code,
    exception_text
FROM system.replication_queue
WHERE queue_size > 100 OR exception_code != 0
ORDER BY queue_size DESC, database, table, replica_name
LIMIT 20;
```

## 🔧 维护操作

### 手动触发复制

```sql
-- 手动触发复制任务（通常不需要手动操作）
SYSTEM SYNC REPLICA your_database.your_table;

-- 查看复制状态
SELECT
    replica_name,
    queue_size,
    absolute_delay,
    last_queue_update
FROM system.replicas
WHERE database = 'your_database'
  AND table = 'your_table';
```

### 重新同步副本

```sql
-- 删除并重新创建副本（谨慎操作！）
-- 1. 先查看副本状态
SELECT * FROM system.replicas
WHERE database = 'your_database' AND table = 'your_table';

-- 2. 在需要重新同步的节点上删除表
-- DROP TABLE IF EXISTS your_database.your_table SYNC;

-- 3. 重新创建表（使用原表的 CREATE TABLE 语句）
-- CREATE TABLE your_database.your_table ...;

-- 4. 验证复制状态
SELECT * FROM system.replicas
WHERE database = 'your_database' AND table = 'your_table';
```

### 集群扩容

```sql
-- 查看当前集群配置
SELECT * FROM system.clusters
WHERE cluster = 'treasurycluster'
ORDER BY shard_num, replica_num;

-- 添加新节点需要：
-- 1. 在新节点上安装 ClickHouse
-- 2. 配置 ClickHouse Keeper
-- 3. 更新集群配置文件
-- 4. 重启 ClickHouse 服务
-- 5. 验证新节点加入集群
SELECT * FROM system.clusters
WHERE cluster = 'treasurycluster'
ORDER BY shard_num, replica_num;
```

## 📊 监控仪表盘

### 复制状态概览

```sql
-- 复制状态概览
SELECT
    'Total Replicas' as metric,
    count() as value,
    '' as status
FROM system.replicas
WHERE database != 'system'

UNION ALL

SELECT
    'Active Replicas',
    sumIf(1, active_replicas = total_replicas),
    ''
FROM system.replicas
WHERE database != 'system'

UNION ALL

SELECT
    'Delayed Replicas',
    sumIf(1, absolute_delay > 10),
    CASE WHEN sumIf(1, absolute_delay > 10) > 0 THEN 'WARNING' ELSE 'OK' END
FROM system.replicas
WHERE database != 'system'

UNION ALL

SELECT
    'Max Delay (seconds)',
    max(absolute_delay),
    CASE WHEN max(absolute_delay) > 300 THEN 'CRITICAL' 
         WHEN max(absolute_delay) > 60 THEN 'WARNING' 
         ELSE 'OK' END
FROM system.replicas
WHERE database != 'system';
```

### 集群节点状态

```sql
-- 集群节点状态
SELECT
    cluster,
    shard_num,
    replica_num,
    host_name,
    port,
    errors_count,
    slowdowns_count,
    CASE
        WHEN errors_count > 0 THEN 'ERROR'
        WHEN slowdowns_count > 50 THEN 'SLOW'
        ELSE 'OK'
    END AS status
FROM system.clusters
WHERE cluster = 'treasurycluster'
ORDER BY shard_num, replica_num;
```

## 💡 最佳实践

1. **定期检查**：定期检查复制延迟和副本状态
2. **监控队列**：监控复制队列大小，及时发现积压
3. **处理延迟**：及时处理复制延迟，避免数据不一致
4. **节点健康**：监控节点错误和减速情况
5. **数据一致性**：定期验证副本数据一致性

## 📝 相关文档

- [06-admin/](../06-admin/) - 运维管理
- [05_replication_issues.md](../07-troubleshooting/04_replication_issues.md) - 复制问题排查
- [00-infra/HIGH_AVAILABILITY_GUIDE.md](../00-infra/HIGH_AVAILABILITY_GUIDE.md) - 高可用配置
