# 系统表详解

本文档详细介绍 ClickHouse 的系统表（System Tables）及其用途。

## 📚 系统表分类

### 1. 元数据表

#### system.databases
```sql
-- 查看所有数据库
SELECT * FROM system.databases;
```

#### system.tables
```sql
-- 查看所有表
SELECT database, name, engine, total_rows, total_bytes
FROM system.tables
WHERE database != 'system';
```

#### system.columns
```sql
-- 查看列定义
SELECT database, table, name, type, position
FROM system.columns
WHERE database = 'your_database'
ORDER BY table, position;
```

#### system.functions
```sql
-- 查看所有函数
SELECT name, alias, is_aggregate, is_nullable
FROM system.functions
WHERE name LIKE 'date%'
ORDER BY name;
```

### 2. 数据表

#### system.parts
```sql
-- 查看数据块
SELECT database, table, partition, name, rows, bytes_on_disk, level
FROM system.parts
WHERE active = 1
ORDER BY database, table, partition;
```

#### system.parts_columns
```sql
-- 查看数据块的列统计
SELECT database, table, partition, column, sum(rows) AS total_rows
FROM system.parts_columns
WHERE active = 1
GROUP BY database, table, partition, column;
```

#### system.detached_parts
```sql
-- 查看分离的数据块
SELECT database, table, partition, name, bytes_on_disk
FROM system.detached_parts
ORDER BY database, table;
```

### 3. 副本和复制

#### system.replicas
```sql
-- 查看副本状态
SELECT database, table, is_leader, queue_size, absolute_delay
FROM system.replicas
WHERE database != 'system';
```

#### system.replication_queue
```sql
-- 查看复制队列
SELECT database, table, replica_name, position, type
FROM system.replication_queue
ORDER BY position;
```

#### system.zookeeper
```sql
-- 查看 ZooKeeper 连接状态
SELECT name, value
FROM system.zookeeper
WHERE path = '/';
```

### 4. 查询和进程

#### system.processes
```sql
-- 查看运行中的查询
SELECT query_id, user, query, elapsed, read_rows, memory_usage
FROM system.processes
ORDER BY elapsed DESC;
```

#### system.query_log
```sql
-- 查看查询日志
SELECT event_time, user, query, type, elapsed
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today()
ORDER BY event_time DESC
LIMIT 100;
```

#### system.query_thread_log
```sql
-- 查看查询线程日志
SELECT event_time, query_id, thread_id, cpu_time_ns, memory_usage
FROM system.query_thread_log
ORDER BY event_time DESC
LIMIT 100;
```

#### system.sessions
```sql
-- 查看活跃会话
SELECT user, client_hostname, connect_time, query_start_time, query
FROM system.sessions
ORDER BY connect_time DESC;
```

### 5. 性能监控

#### system.metrics
```sql
-- 查看指标快照
SELECT metric, value, description
FROM system.metrics
WHERE metric LIKE '%ClickHouse%'
ORDER BY metric;
```

#### system.events
```sql
-- 查看事件计数器
SELECT event, value, description
FROM system.events
WHERE event LIKE 'Read%'
ORDER BY value DESC;
```

#### system.asynchronous_metrics
```sql
-- 查看异步指标
SELECT metric, value, description
FROM system.asynchronous_metrics
ORDER BY metric;
```

#### system.profiles
```sql
-- 查看性能配置文件
SELECT name, settings, readonly
FROM system.profiles
ORDER BY name;
```

### 6. 存储和文件

#### system.disks
```sql
-- 查看磁盘配置
SELECT name, path, free_space, total_space, keep_free_space_bytes
FROM system.disks;
```

#### system.data_skipping_indices
```sql
-- 查看跳数索引
SELECT database, table, name, type, expr, granularity
FROM system.data_skipping_indices
WHERE database != 'system';
```

#### system.projection_parts
```sql
-- 查看投影数据块
SELECT database, table, projection, partition, rows, bytes_on_disk
FROM system.projection_parts
WHERE active = 1;
```

### 7. 权限和安全

#### system.users
```sql
-- 查看所有用户
SELECT name, auth_type, profile, quota
FROM system.users
ORDER BY name;
```

#### system.roles
```sql
-- 查看所有角色
SELECT name, is_default, grants
FROM system.roles
ORDER BY name;
```

#### system.grants
```sql
-- 查看权限授予情况
SELECT user_name, role_name, grant_type, database, table, access_type
FROM system.grants
WHERE database != 'system';
```

#### system.row_policies
```sql
-- 查看行级策略
SELECT database, table, name, filter
FROM system.row_policies
WHERE database != 'system';
```

#### system.quotas
```sql
-- 查看配额设置
SELECT name, keys, durations
FROM system.quotas
ORDER BY name;
```

#### system.settings_profiles
```sql
-- 查看配置文件
SELECT name, is_default, settings, readonly
FROM system.settings_profiles
ORDER BY name;
```

### 8. 变更操作

#### system.mutations
```sql
-- 查看变更操作
SELECT database, table, command_type, command, is_done
FROM system.mutations
WHERE database = 'your_database'
ORDER BY created_at DESC;
```

## 🎯 系统表使用场景

### 场景 1: 数据库巡检

```sql
-- 一键数据库巡检
SELECT
    'Databases' as category,
    count() as count,
    '' as status
FROM system.databases
WHERE name != 'system'

UNION ALL

SELECT
    'Tables',
    count(),
    ''
FROM system.tables
WHERE database != 'system'

UNION ALL

SELECT
    'Replicas',
    count(),
    CASE WHEN sumIf(1, queue_size > 0) > 0 THEN 'WARNING' ELSE 'OK' END
FROM system.replicas
WHERE database != 'system'

UNION ALL

SELECT
    'Running Queries',
    count(),
    CASE WHEN max(elapsed) > 300 THEN 'WARNING' ELSE 'OK' END
FROM system.processes

UNION ALL

SELECT
    'Slow Queries Today',
    count(),
    ''
FROM system.query_log
WHERE type = 'QueryFinish'
  AND elapsed > 10
  AND event_date = today();
```

### 场景 2: 存储空间分析

```sql
-- 存储空间分析
SELECT
    database,
    table,
    formatReadableSize(sum(bytes_on_disk)) AS size,
    formatReadableQuantity(sum(rows)) AS rows,
    count() AS parts
FROM system.parts
WHERE active = 1
GROUP BY database, table
ORDER BY sum(bytes_on_disk) DESC
LIMIT 20;
```

### 场景 3: 查询性能分析

```sql
-- 查询性能分析
SELECT
    user,
    count() AS query_count,
    avg(elapsed) AS avg_elapsed,
    max(elapsed) AS max_elapsed,
    sum(read_bytes) AS total_read_bytes,
    sum(result_bytes) AS total_result_bytes
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today()
GROUP BY user
ORDER BY query_count DESC;
```

### 场景 4: 副本健康检查

```sql
-- 副本健康检查
SELECT
    database,
    table,
    replica_name,
    is_leader,
    queue_size,
    absolute_delay,
    active_replicas,
    total_replicas,
    CASE
        WHEN absolute_delay > 300 THEN 'CRITICAL'
        WHEN absolute_delay > 60 THEN 'WARNING'
        ELSE 'OK'
    END AS status
FROM system.replicas
WHERE database != 'system'
ORDER BY absolute_delay DESC;
```

### 场景 5: 资源使用监控

```sql
-- 资源使用监控
SELECT
    metric,
    value,
    description
FROM system.metrics
WHERE metric IN (
    'ReadBufferFromFileDescriptorBytes',
    'WriteBufferFromFileDescriptorBytes',
    'MemoryTracking',
    'MarkCacheBytes',
    'UncompressedCacheBytes',
    'TCPConnection'
)
ORDER BY metric;
```

## 📊 系统表性能优化

### 使用物化视图

```sql
-- 创建物化视图来聚合查询日志
CREATE MATERIALIZED VIEW IF NOT EXISTS query_stats_mv
ENGINE = SummingMergeTree()
PARTITION BY toYYYYMM(event_date)
ORDER BY (event_date, query_kind)
AS SELECT
    toStartOfDay(event_time) AS event_date,
    query_kind,
    count() AS query_count,
    avg(elapsed) AS avg_elapsed,
    max(elapsed) AS max_elapsed,
    sum(read_bytes) AS total_read_bytes
FROM system.query_log
WHERE type = 'QueryFinish'
GROUP BY event_date, query_kind;
```

### 定期清理

```sql
-- 清理旧的查询日志
ALTER TABLE system.query_log
DELETE WHERE event_date < today() - INTERVAL 30 DAY;

-- 清理旧的查询线程日志
ALTER TABLE system.query_thread_log
DELETE WHERE event_date < today() - INTERVAL 30 DAY;
```

## ⚠️ 注意事项

1. **性能影响**：查询大型系统表可能会影响性能
2. **权限要求**：部分系统表需要特定权限
3. **实时性**：某些表的数据可能有延迟
4. **日志表大小**：定期清理日志表以节省空间
5. **索引限制**：系统表不支持创建索引

## 💡 最佳实践

1. **添加过滤条件**：查询系统表时始终添加适当的过滤条件
2. **使用投影**：只查询需要的列，减少数据传输
3. **定期清理**：定期清理日志表中的旧数据
4. **监控性能**：监控对系统表的查询性能
5. **使用物化视图**：为常用的系统表查询创建物化视图

## 📖 相关文档

- [01_databases_tables.md](./01_databases_tables.md) - 数据库和表信息
- [07_queries_processes.md](./07_queries_processes.md) - 查询和进程
- [ClickHouse System Tables 官方文档](https://clickhouse.com/docs/en/operations/system-tables)
