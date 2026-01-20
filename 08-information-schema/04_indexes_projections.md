# 索引和投影

本文档介绍如何查询和管理 ClickHouse 的索引（Indexes）和投影（Projections）。

## 📊 system.data_skipping_indices

### 查看所有跳数索引

```sql
-- 查看所有表的跳数索引
SELECT
    database,
    table,
    name AS index_name,
    type,
    expr,
    granularity,
    column_names
FROM system.data_skipping_indices
WHERE database != 'system'
ORDER BY database, table, name;
```

### 查看特定表的索引

```sql
-- 查看特定表的所有索引
SELECT
    name AS index_name,
    type,
    expr,
    granularity,
    column_names,
    comment
FROM system.data_skipping_indices
WHERE database = 'your_database'
  AND table = 'your_table'
ORDER BY name;
```

### 常用字段说明

| 字段 | 类型 | 说明 |
|------|------|------|
| `database` | String | 数据库名称 |
| `table` | String | 表名称 |
| `name` | String | 索引名称 |
| `type` | String | 索引类型（minmax、set、bloom_filter 等） |
| `expr` | String | 索引表达式 |
| `granularity` | UInt64 | 索引粒度 |
| `column_names` | Array(String) | 涉及的列名 |
| `comment` | String | 索引注释 |

## 🎯 索引类型

### 支持的索引类型

| 索引类型 | 说明 | 适用场景 |
|---------|------|---------|
| `minmax` | 最小/最大值 | 数值、日期列的范围查询 |
| `set` | 值集合 | 离散值的等值查询 |
| `bloom_filter` | 布隆过滤器 | 高基数列的等值查询 |
| `bloom_filter` | 布隆过滤器 | 高基数列的等值查询 |

### 查看索引类型分布

```sql
-- 统计不同索引类型的使用情况
SELECT
    type,
    count() AS index_count,
    arrayDistinct(arrayFlatten(groupArray(column_names))) AS columns_used
FROM system.data_skipping_indices
WHERE database != 'system'
GROUP BY type
ORDER BY index_count DESC;
```

## 📈 索引使用情况

### 查看索引效果

```sql
-- 查看索引的实际使用情况（需要查询日志）
SELECT
    index_name,
    type,
    expr,
    granularity,
    count() AS usage_count
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today() - INTERVAL 7 DAY
  AND query ILIKE '%your_table%'
  AND query NOT ILIKE '%system%'
GROUP BY index_name, type, expr, granularity
ORDER BY usage_count DESC;
```

### 查看未使用的索引

```sql
-- 查找可能未使用的索引
SELECT
    database,
    table,
    name AS index_name,
    type,
    expr,
    granularity,
    create_table_query
FROM system.data_skipping_indices AS i
LEFT JOIN system.tables AS t ON i.database = t.database AND i.table = t.name
WHERE i.database = 'your_database'
  AND i.table NOT LIKE 'test_%'
ORDER BY i.database, i.table, i.name;
```

## 🎨 Projections

### 查看所有投影

```sql
-- 查看所有表的投影
SELECT
    database,
    table,
    name AS projection_name,
    type,
    formatReadableSize(total_bytes) AS size,
    total_rows,
    create_time,
    modify_time,
    comment
FROM system.projections
WHERE database != 'system'
ORDER BY database, table, name;
```

### 查看特定表的投影

```sql
-- 查看特定表的投影
SELECT
    name AS projection_name,
    type,
    target_name,
    formatReadableSize(total_bytes) AS size,
    total_rows,
    create_time,
    modify_time
FROM system.projections
WHERE database = 'your_database'
  AND table = 'your_table'
ORDER BY name;
```

### 常用字段说明

| 字段 | 类型 | 说明 |
|------|------|------|
| `database` | String | 数据库名称 |
| `table` | String | 表名称 |
| `name` | String | 投影名称 |
| `type` | String | 投影类型 |
| `target_name` | String | 目标表名 |
| `total_bytes` | UInt64 | 总字节数 |
| `total_rows` | UInt64 | 总行数 |
| `create_time` | DateTime | 创建时间 |
| `modify_time` | DateTime | 修改时间 |

## 🔍 投影数据块

### 查看投影的数据块

```sql
-- 查看投影的数据块
SELECT
    database,
    table,
    projection,
    partition,
    name AS part_name,
    rows,
    bytes_on_disk,
    marks,
    active
FROM system.projection_parts
WHERE database = 'your_database'
  AND table = 'your_table'
  AND active = 1
ORDER BY projection, partition, name;
```

### 投影大小分析

```sql
-- 分析投影占用的空间
SELECT
    database,
    table,
    projection,
    formatReadableSize(sum(bytes_on_disk)) AS total_size,
    sum(rows) AS total_rows,
    count() AS parts_count
FROM system.projection_parts
WHERE database = 'your_database'
  AND active = 1
GROUP BY database, table, projection
ORDER BY sum(bytes_on_disk) DESC;
```

## 🎯 实战场景

### 场景 1: 创建索引

```sql
-- 为表创建 minmax 索引
ALTER TABLE your_database.your_table
ADD INDEX idx_event_time_minmax event_time TYPE minmax GRANULARITY 4;

-- 为表创建 set 索引
ALTER TABLE your_database.your_table
ADD INDEX idx_status_set status TYPE set(0) GRANULARITY 1;

-- 为表创建布隆过滤器索引
ALTER TABLE your_database.your_table
ADD INDEX idx_user_id_bloom user_id TYPE bloom_filter(0.01) GRANULARITY 1;

-- 查看新创建的索引
SELECT
    name,
    type,
    expr,
    granularity,
    column_names
FROM system.data_skipping_indices
WHERE database = 'your_database'
  AND table = 'your_table';
```

### 场景 2: 删除索引

```sql
-- 删除索引
ALTER TABLE your_database.your_table
DROP INDEX idx_event_time_minmax;

-- 验证索引已删除
SELECT
    name,
    type,
    expr,
    granularity
FROM system.data_skipping_indices
WHERE database = 'your_database'
  AND table = 'your_table';
```

### 场景 3: 创建投影

```sql
-- 创建投影用于加速聚合查询
ALTER TABLE your_database.your_table
ADD PROJECTION projection_daily_summary
(
    SELECT
        toDate(event_time) AS day,
        count() AS cnt,
        sum(amount) AS total_amount
    GROUP BY day
);

-- 查看创建的投影
SELECT
    name,
    type,
    create_time
FROM system.projections
WHERE database = 'your_database'
  AND table = 'your_table';
```

### 场景 4: 分析索引效果

```sql
-- 分析查询是否使用了索引
SELECT
    query,
    read_rows,
    read_bytes,
    result_rows,
    result_bytes,
    elapsed
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today() - INTERVAL 7 DAY
  AND query ILIKE '%your_table%'
  AND query ILIKE '%WHERE%'
ORDER BY read_bytes DESC
LIMIT 10;
```

### 场景 5: 索引维护

```sql
-- 强制重建索引
ALTER TABLE your_database.your_table
MATERIALIZE INDEX idx_event_time_minmax IN PARTITION '2023-01';

-- 查看索引状态
SELECT
    name,
    type,
    status,
    message
FROM system.dropped_indices
WHERE database = 'your_database'
  AND table = 'your_table';
```

## 📊 索引推荐

### 查找可以创建索引的列

```sql
-- 查找适合创建索引的列（高频 WHERE 条件）
SELECT
    query_database,
    query_table,
    extractAll(query, 'WHERE ([^ ]+)')[1]::String AS potential_column,
    count() AS usage_count
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today() - INTERVAL 7 DAY
  AND query ILIKE '%WHERE%'
  AND query_database != 'system'
GROUP BY query_database, query_table, potential_column
HAVING count() > 10
ORDER BY usage_count DESC
LIMIT 20;
```

### 查找重复的索引

```sql
-- 查找可能重复的索引（相同的表达式）
SELECT
    database,
    table,
    groupArray(name) AS index_names,
    expr,
    type,
    count() AS duplicate_count
FROM system.data_skipping_indices
WHERE database != 'system'
GROUP BY database, table, expr, type
HAVING count() > 1
ORDER BY duplicate_count DESC;
```

## 💡 最佳实践

1. **索引选择**：根据查询模式选择合适的索引类型
2. **索引粒度**：合理设置索引粒度，平衡索引大小和查询性能
3. **投影使用**：为频繁的聚合查询创建投影
4. **监控效果**：定期监控索引和投影的使用效果
5. **避免过度索引**：索引会增加写入开销，避免创建不必要的索引

## 📝 相关文档

- [03_partitions_parts.md](./03_partitions_parts.md) - 分区和数据块
- [01_databases_tables.md](./01_databases_tables.md) - 数据库和表信息
- [03-engines/](../03-engines/) - 表引擎详解
