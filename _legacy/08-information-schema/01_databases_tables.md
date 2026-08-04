# 数据库和表信息

本文档介绍如何查询和管理 ClickHouse 的数据库和表元数据。

## 📊 system.databases

### 基本查询

```sql
-- 查看所有数据库
SELECT
    name,
    engine,
    data_path,
    metadata_path,
    uuid
FROM system.databases
ORDER BY name;
```

### 常用字段说明

| 字段 | 类型 | 说明 |
|------|------|------|
| `name` | String | 数据库名称 |
| `engine` | String | 数据库引擎（通常为 Atomic） |
| `data_path` | String | 数据存储路径 |
| `metadata_path` | String | 元数据存储路径 |
| `uuid` | UUID | 数据库唯一标识 |

### 创建数据库

```sql
-- 创建数据库
CREATE DATABASE IF NOT EXISTS analytics
ENGINE = Atomic;

-- 带注释的数据库
CREATE DATABASE IF NOT EXISTS analytics
ENGINE = Atomic
COMMENT 'Analytics database';

-- 创建后查看
SELECT
    name,
    engine,
    comment
FROM system.databases
WHERE name = 'analytics';
```

### 删除数据库

```sql
-- 删除数据库（Atomic 引擎支持延迟删除）
DROP DATABASE IF EXISTS analytics;

-- 查看延迟删除的数据库
SELECT
    name,
    engine,
    drop_time
FROM system.databases
WHERE is_temporary OR drop_time IS NOT NULL;
```

## 📋 system.tables

### 基本查询

```sql
-- 查看所有表
SELECT
    database,
    name AS table,
    engine,
    engine_full,
    partition_key,
    sorting_key,
    primary_key,
    sampling_key,
    total_rows,
    total_bytes,
    create_table_query,
    engine
FROM system.tables
WHERE database != 'system'
ORDER BY database, name
LIMIT 100;
```

### 按引擎统计表数量

```sql
-- 统计各引擎的表数量
SELECT
    engine,
    count() AS table_count,
    sum(total_rows) AS total_rows,
    formatReadableSize(sum(total_bytes)) AS total_size
FROM system.tables
WHERE database != 'system'
GROUP BY engine
ORDER BY table_count DESC;
```

### 查看表存储大小

```sql
-- 查看占用空间最大的表
SELECT
    database,
    table,
    engine,
    formatReadableSize(total_bytes) AS size,
    formatReadableQuantity(total_rows) AS rows,
    formatReadableSize(total_bytes / NULLIF(total_rows, 0)) AS avg_row_size
FROM system.tables
WHERE database != 'system'
  AND total_bytes > 0
ORDER BY total_bytes DESC
LIMIT 20;
```

### 查看表的分区和排序键

```sql
-- 查看表的分区和排序键信息
SELECT
    database,
    name AS table,
    engine,
    partition_key,
    sorting_key,
    primary_key,
    has_own_data AS has_data,
    is_temporary
FROM system.tables
WHERE database != 'system'
ORDER BY database, name;
```

### 常用字段说明

| 字段 | 类型 | 说明 |
|------|------|------|
| `database` | String | 数据库名称 |
| `name` | String | 表名称 |
| `engine` | String | 表引擎 |
| `partition_key` | String | 分区键表达式 |
| `sorting_key` | String | 排序键表达式 |
| `primary_key` | String | 主键表达式 |
| `sampling_key` | String | 采样键表达式 |
| `total_rows` | UInt64 | 总行数 |
| `total_bytes` | UInt64 | 总字节数 |
| `create_table_query` | String | CREATE TABLE 语句 |
| `is_temporary` | UInt8 | 是否为临时表 |

## 🔍 表关系查询

### 查看依赖表

```sql
-- 查看所有视图和依赖的表
SELECT
    database,
    name AS view_name,
    dependencies_table AS depends_on
FROM system.tables
ARRAY JOIN dependencies_table
WHERE database != 'system'
  AND engine = 'View'
ORDER BY database, name;
```

### 查看数据库表分布

```sql
-- 查看每个数据库的表分布
SELECT
    database,
    count() AS table_count,
    countIf(engine = 'MergeTree') AS mergetree_count,
    countIf(engine = 'ReplicatedMergeTree') AS replicated_count,
    countIf(engine = 'Distributed') AS distributed_count,
    countIf(engine = 'View') AS view_count
FROM system.tables
GROUP BY database
ORDER BY table_count DESC;
```

## 📈 表统计信息

### 聚合统计

```sql
-- 数据库级别的统计
SELECT
    database,
    count() AS table_count,
    sum(total_rows) AS total_rows,
    formatReadableSize(sum(total_bytes)) AS total_size,
    formatReadableQuantity(avg(total_bytes / NULLIF(total_rows, 0))) AS avg_row_size,
    max(total_bytes) AS max_table_size
FROM system.tables
WHERE database != 'system'
GROUP BY database
ORDER BY total_size DESC;
```

### 表大小分布

```sql
-- 表大小分布统计
SELECT
    CASE
        WHEN total_bytes < 1024 * 1024 THEN 'Small (<1MB)'
        WHEN total_bytes < 1024 * 1024 * 100 THEN 'Medium (1-100MB)'
        WHEN total_bytes < 1024 * 1024 * 1024 THEN 'Large (100MB-1GB)'
        WHEN total_bytes < 1024 * 1024 * 1024 * 10 THEN 'X-Large (1-10GB)'
        ELSE 'XX-Large (>10GB)'
    END AS size_category,
    count() AS table_count,
    formatReadableSize(sum(total_bytes)) AS total_size
FROM system.tables
WHERE database != 'system'
GROUP BY size_category
ORDER BY total_size DESC;
```

## 🎯 实战场景

### 场景 1: 发现未使用的表

```sql
-- 查找长时间未访问的表
SELECT
    t.database,
    t.table,
    t.engine,
    t.total_rows,
    formatReadableSize(t.total_bytes) AS size,
    max(q.event_time) AS last_access_time
FROM system.tables AS t
LEFT JOIN (
    SELECT 
        query_database AS database,
        query_table AS table,
        max(event_time) AS event_time
    FROM system.query_log
    WHERE type = 'QueryFinish'
      AND event_date >= today() - INTERVAL 30 DAY
    GROUP BY database, table
) AS q ON t.database = q.database AND t.name = q.table
WHERE t.database != 'system'
  AND t.total_bytes > 1024 * 1024 * 100  -- 大于 100MB
  AND (q.event_time IS NULL OR q.event_time < today() - INTERVAL 30 DAY)
ORDER BY t.total_bytes DESC;
```

### 场景 2: 查找空表

```sql
-- 查找空表
SELECT
    database,
    name AS table,
    engine,
    create_table_query
FROM system.tables
WHERE database != 'system'
  AND total_rows = 0
ORDER BY database, name;
```

### 场景 3: 查找临时表

```sql
-- 查找临时表
SELECT
    name,
    engine,
    total_rows,
    formatReadableSize(total_bytes) AS size
FROM system.tables
WHERE is_temporary = 1
ORDER BY total_bytes DESC;
```

### 场景 4: 查找没有分区的表

```sql
-- 查找没有分区的 MergeTree 系列表
SELECT
    database,
    name AS table,
    engine,
    total_rows,
    formatReadableSize(total_bytes) AS size
FROM system.tables
WHERE database != 'system'
  AND engine LIKE '%MergeTree%'
  AND (partition_key = '' OR partition_key IS NULL)
ORDER BY total_bytes DESC;
```

### 场景 5: 查找分布式表和本地表

```sql
-- 查找分布式表和对应的本地表
SELECT
    t1.database,
    t1.name AS distributed_table,
    t1.total_rows AS dist_rows,
    formatReadableSize(t1.total_bytes) AS dist_size,
    t2.name AS local_table,
    t2.total_rows AS local_rows,
    formatReadableSize(t2.total_bytes) AS local_size,
    sharding_key,
    distributed_table
FROM system.tables AS t1
JOIN system.tables AS t2 ON 
    t1.database = t2.database 
    AND t1.sharding_key != ''
    AND t2.name = t1.distributed_table
WHERE t1.engine = 'Distributed'
  AND t1.database != 'system'
ORDER BY t1.database, t1.name;
```

## 🔧 管理操作

### 批量删除空表

```sql
-- 生成删除空表的 SQL（谨慎使用！）
SELECT 
    concat('DROP TABLE IF EXISTS ', database, '.', name, ';') AS drop_sql
FROM system.tables
WHERE database = 'your_database'
  AND name LIKE 'temp_%'
  AND total_rows = 0;
```

### 生成表结构文档

```sql
-- 生成表的完整定义
SELECT
    create_table_query
FROM system.tables
WHERE database = 'your_database'
  AND name = 'your_table'\G
```

### 查看表修改历史

```sql
-- 查看表的变更操作
SELECT
    database,
    table,
    command_type,
    command
FROM system.mutations
WHERE database = 'your_database'
  AND table = 'your_table'
ORDER BY created_at DESC;
```

## 💡 最佳实践

1. **定期监控**：定期查询表大小分布，识别异常增长的表
2. **清理未使用表**：定期清理空表或长时间未访问的表
3. **优化表结构**：对于大型表，检查分区键和排序键是否合理
4. **监控引擎分布**：确保使用了合适的表引擎
5. **避免临时表**：及时清理不再需要的临时表

## 📝 相关文档

- [02_columns_schema.md](./02_columns_schema.md) - 列定义和表结构
- [03_partitions_parts.md](./03_partitions_parts.md) - 分区和数据块
- [07_queries_processes.md](./07_queries_processes.md) - 查询和进程
