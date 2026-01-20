# Information Schema - 数据库元数据

本目录介绍如何查询和理解 ClickHouse 数据库的元数据信息。

## 📚 文档目录

### 基础元数据
- [01_databases_tables.md](./01_databases_tables.md) - 数据库和表信息
- [02_columns_schema.md](./02_columns_schema.md) - 列定义和表结构
- [03_partitions_parts.md](./03_partitions_parts.md) - 分区和数据块

### 高级元数据
- [04_indexes_projections.md](./04_indexes_projections.md) - 索引和投影
- [05_clusters_replicas.md](./05_clusters_replicas.md) - 集群和副本信息
- [06_users_roles.md](./06_users_roles.md) - 用户和权限管理

### 运行时信息
- [07_queries_processes.md](./07_queries_processes.md) - 查询和进程
- [08_system_tables.md](./08_system_tables.md) - 系统表详解

## 🎯 快速开始

### 1. 查看所有数据库

```sql
-- 列出所有数据库
SELECT name, engine, data_path 
FROM system.databases 
ORDER BY name;
```

### 2. 查看所有表

```sql
-- 列出所有表
SELECT database, name, engine, total_rows, total_bytes
FROM system.tables
WHERE database != 'system'
ORDER BY database, name;
```

### 3. 查看表结构

```sql
-- 查看表的列定义
SELECT name, type, default_type, default_expression
FROM system.columns
WHERE database = 'your_database' AND table = 'your_table'
ORDER BY position;
```

### 4. 查看分区信息

```sql
-- 查看表的分区
SELECT 
    partition,
    sum(rows) as total_rows,
    sum(bytes_on_disk) as total_bytes,
    count() as parts_count
FROM system.parts
WHERE database = 'your_database' 
  AND table = 'your_table'
  AND active = 1
GROUP BY partition
ORDER BY partition;
```

### 5. 查看集群信息

```sql
-- 查看集群配置
SELECT cluster, shard_num, replica_num, host_name, port
FROM system.clusters
WHERE cluster = 'treasurycluster'
ORDER BY shard_num, replica_num;
```

## 📊 元数据查询场景

### 场景 1: 日常巡检

```sql
-- 一键获取数据库概览
SELECT
    'Databases' as category,
    count() as count
FROM system.databases
WHERE name != 'system'

UNION ALL

SELECT
    'Tables',
    count()
FROM system.tables
WHERE database != 'system'

UNION ALL

SELECT
    'Active Parts',
    count()
FROM system.parts
WHERE active = 1

UNION ALL

SELECT
    'Running Queries',
    count()
FROM system.processes;
```

### 场景 2: 存储空间分析

```sql
-- 分析各表占用的存储空间
SELECT
    database,
    table,
    formatReadableSize(sum(bytes_on_disk)) as size,
    formatReadableQuantity(sum(rows)) as rows,
    count() as parts
FROM system.parts
WHERE active = 1
GROUP BY database, table
ORDER BY sum(bytes_on_disk) DESC
LIMIT 20;
```

### 场景 3: 表结构对比

```sql
-- 查看所有表的主键和排序键
SELECT
    database,
    table,
    engine,
    sorting_key,
    primary_key,
    partition_key
FROM system.tables
WHERE database != 'system'
ORDER BY database, table;
```

### 场景 4: 副本状态检查

```sql
-- 检查所有复制表的副本状态
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
ORDER BY database, table, replica_name;
```

### 场景 5: 查询性能分析

```sql
-- 查看当前运行的查询
SELECT
    query_id,
    user,
    query,
    elapsed,
    read_rows,
    read_bytes,
    memory_usage,
    thread_ids
FROM system.processes
ORDER BY elapsed DESC
LIMIT 10;
```

## 🔍 系统表分类

### 元数据表
| 表名 | 用途 |
|------|------|
| `system.databases` | 数据库列表 |
| `system.tables` | 表列表和配置 |
| `system.columns` | 列定义 |
| `system.functions` | 函数列表 |
| `system.formats` | 支持的格式 |

### 数据表
| 表名 | 用途 |
|------|------|
| `system.parts` | 数据块信息 |
| `system.parts_columns` | 数据块列统计 |
| `system.detached_parts` | 分离的数据块 |
| `system.mutations` | 变更操作 |

### 副本和复制
| 表名 | 用途 |
|------|------|
| `system.replicas` | 副本状态 |
| `system.replication_queue` | 复制队列 |
| `system.zookeeper` | ZooKeeper 状态 |

### 查询和进程
| 表名 | 用途 |
|------|------|
| `system.processes` | 当前运行的查询 |
| `system.query_log` | 查询历史日志 |
| `system.query_thread_log` | 查询线程日志 |
| `system.sessions` | 会话信息 |

### 性能监控
| 表名 | 用途 |
|------|------|
| `system.metrics` | 指标快照 |
| `system.events` | 事件计数器 |
| `system.asynchronous_metrics` | 异步指标 |
| `system.profiles` | 性能配置 |

### 存储和文件
| 表名 | 用途 |
|------|------|
| `system.disks` | 磁盘配置 |
| `system.data_skipping_indices` | 跳数索引 |
| `system.projection_parts` | 投影数据块 |

### 权限和安全
| 表名 | 用途 |
|------|------|
| `system.users` | 用户列表 |
| `system.roles` | 角色列表 |
| `system.row_policies` | 行级策略 |
| `system.quotas` | 配额限制 |

## 💡 最佳实践

### 1. 定期查询元数据

```sql
-- 创建定期监控视图
CREATE VIEW IF NOT EXISTS metadata_daily_snapshot AS
SELECT
    now() as snapshot_time,
    (SELECT count() FROM system.databases WHERE name != 'system') as databases_count,
    (SELECT count() FROM system.tables WHERE database != 'system') as tables_count,
    (SELECT sum(rows) FROM system.parts WHERE active = 1) as total_rows,
    (SELECT sum(bytes_on_disk) FROM system.parts WHERE active = 1) as total_bytes;
```

### 2. 监控表结构变化

```sql
-- 跟踪表结构变更
SELECT
    database,
    table,
    name as column_name,
    type,
    position
FROM system.columns
WHERE database != 'system'
ORDER BY database, table, position;
```

### 3. 分析查询模式

```sql
-- 统计最常查询的表
SELECT 
    query_database,
    query_table,
    count() as query_count
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today() - INTERVAL 7 DAY
  AND query_database != 'system'
GROUP BY query_database, query_table
ORDER BY query_count DESC
LIMIT 20;
```

## ⚠️ 注意事项

1. **性能考虑**：查询大型 system 表可能会影响性能，建议添加适当的过滤条件

2. **权限要求**：部分 system 表需要特定权限才能访问

3. **实时性**：某些表（如 `system.asynchronous_metrics`）的数据可能有延迟

4. **数据一致性**：在执行 DDL 操作时查询元数据可能看到不一致的状态

5. **日志表大小**：`system.query_log` 等日志表需要定期清理

## 📖 参考资源

- [ClickHouse System Tables Documentation](https://clickhouse.com/docs/en/operations/system-tables)
- [Information Schema Standard](https://en.wikipedia.org/wiki/Information_schema)
