# 列定义和表结构

本文档介绍如何查询和理解 ClickHouse 表的列定义和结构信息。

## 📊 system.columns

### 基本查询

```sql
-- 查看表的所有列
SELECT
    database,
    table,
    name AS column_name,
    position,
    type,
    default_kind,
    default_expression,
    comment,
    is_subcolumn
FROM system.columns
WHERE database = 'your_database'
  AND table = 'your_table'
ORDER BY position;
```

### 查看表的完整结构

```sql
-- 查看表的完整结构（包括默认值、压缩等）
SELECT
    database,
    table,
    name AS column_name,
    position,
    type,
    default_kind,
    default_expression,
    data_compressed_bytes,
    data_uncompressed_bytes,
    marks_bytes,
    comment
FROM system.columns
WHERE database = 'your_database'
  AND table = 'your_table'
ORDER BY position;
```

### 常用字段说明

| 字段 | 类型 | 说明 |
|------|------|------|
| `database` | String | 数据库名称 |
| `table` | String | 表名称 |
| `name` | String | 列名称 |
| `position` | UInt64 | 列位置 |
| `type` | String | 列类型 |
| `default_kind` | String | 默认值类型 |
| `default_expression` | String | 默认值表达式 |
| `comment` | String | 列注释 |
| `is_subcolumn` | UInt8 | 是否为子列（如 Tuple、Map 的元素） |
| `data_compressed_bytes` | UInt64 | 压缩后字节数 |
| `data_uncompressed_bytes` | UInt64 | 未压缩字节数 |
| `marks_bytes` | UInt64 | 标记字节数 |

## 🔍 列类型分析

### 按数据类型统计列

```sql
-- 按数据类型统计列的数量
SELECT
    type,
    count() AS column_count,
    countIf(database = 'your_database') AS your_db_count
FROM system.columns
WHERE database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
GROUP BY type
ORDER BY column_count DESC;
```

### 查找 Nullable 列

```sql
-- 查找所有 Nullable 类型的列
SELECT
    database,
    table,
    name AS column_name,
    type,
    default_kind,
    default_expression,
    position
FROM system.columns
WHERE type LIKE 'Nullable%'
ORDER BY database, table, position;
```

### 查找低基数列（LowCardinality）

```sql
-- 查找 LowCardinality 列
SELECT
    database,
    table,
    name AS column_name,
    type,
    default_kind,
    comment
FROM system.columns
WHERE type LIKE 'LowCardinality%'
ORDER BY database, table, position;
```

### 查找复杂类型列

```sql
-- 查找 Array, Map, Tuple 等复杂类型列
SELECT
    database,
    table,
    name AS column_name,
    type,
    position
FROM system.columns
WHERE type LIKE 'Array%'
   OR type LIKE 'Map%'
   OR type LIKE 'Tuple%'
   OR type LIKE 'Nested%'
ORDER BY database, table, position;
```

## 📈 列统计信息

### 列压缩率分析

```sql
-- 分析列的压缩率
SELECT
    database,
    table,
    name AS column_name,
    type,
    data_uncompressed_bytes,
    data_compressed_bytes,
    ROUND(data_compressed_bytes * 100.0 / NULLIF(data_uncompressed_bytes, 0), 2) AS compression_ratio,
    marks_bytes
FROM system.columns
WHERE database = 'your_database'
  AND table = 'your_table'
  AND data_uncompressed_bytes > 0
ORDER BY compression_ratio;
```

### 列大小排名

```sql
-- 查找占用空间最大的列
SELECT
    database,
    table,
    name AS column_name,
    type,
    formatReadableSize(data_compressed_bytes) AS compressed_size,
    formatReadableSize(data_uncompressed_bytes) AS uncompressed_size,
    ROUND(data_compressed_bytes * 100.0 / NULLIF(data_uncompressed_bytes, 0), 2) AS compression_ratio
FROM system.columns
WHERE database != 'system'
  AND data_compressed_bytes > 0
ORDER BY data_compressed_bytes DESC
LIMIT 50;
```

### 特定类型的列分析

```sql
-- 分析 String 类型列的大小
SELECT
    database,
    table,
    name AS column_name,
    type,
    formatReadableSize(data_compressed_bytes) AS compressed_size,
    formatReadableSize(data_uncompressed_bytes) AS uncompressed_size,
    compression_ratio
FROM (
    SELECT
        database,
        table,
        name,
        type,
        data_compressed_bytes,
        data_uncompressed_bytes,
        ROUND(data_compressed_bytes * 100.0 / NULLIF(data_uncompressed_bytes, 0), 2) AS compression_ratio
    FROM system.columns
    WHERE type = 'String'
      AND database != 'system'
      AND data_compressed_bytes > 0
)
ORDER BY data_compressed_bytes DESC
LIMIT 20;
```

## 🎯 默认值分析

### 查看有默认值的列

```sql
-- 查看所有有默认值的列
SELECT
    database,
    table,
    name AS column_name,
    type,
    default_kind,
    default_expression,
    position
FROM system.columns
WHERE default_kind != ''
ORDER BY database, table, position;
```

### 默认值类型统计

```sql
-- 统计默认值类型
SELECT
    default_kind,
    count() AS column_count
FROM system.columns
WHERE default_kind != ''
GROUP BY default_kind
ORDER BY column_count DESC;
```

### 默认值类型说明

| default_kind | 说明 |
|--------------|------|
| `DEFAULT` | 普通默认值 |
| `MATERIALIZED` | 物化列（存储计算结果） |
| `ALIAS` | 别名列（不存储，计算时动态计算） |
| `EPHEMERAL` | 临时列（仅用于查询） |

## 🔧 实战场景

### 场景 1: 生成 CREATE TABLE 语句

```sql
-- 生成表的 CREATE TABLE 语句
SELECT 
    concat(
        'CREATE TABLE ', database, '.', table, ' (\n',
        arrayStringConcat(
            arrayMap(
                x -> concat('    ', x),
                groupArray(
                    concat(
                        name, ' ', type,
                        CASE 
                            WHEN default_kind != '' THEN concat(' ', default_kind, ' ', default_expression)
                            ELSE ''
                        END,
                        CASE 
                            WHEN comment != '' THEN concat(' COMMENT ''', comment, '''')
                            ELSE ''
                        END
                    )
                )
            ),
            ',\n'
        ),
        '\n) ENGINE = ', engine
    ) AS create_table_sql
FROM (
    SELECT 
        c.database,
        c.table,
        c.name,
        c.type,
        c.default_kind,
        c.default_expression,
        c.comment,
        t.engine
    FROM system.columns AS c
    JOIN system.tables AS t ON c.database = t.database AND c.table = t.name
    WHERE c.database = 'your_database'
      AND c.table = 'your_table'
    ORDER BY c.position
)
GROUP BY database, table, engine;
```

### 场景 2: 查找重复列名

```sql
-- 查找可能有重复列名的表（考虑大小写）
SELECT
    database,
    table,
    name,
    count() AS duplicate_count
FROM system.columns
WHERE database != 'system'
GROUP BY database, table, lower(name)
HAVING count() > 1
ORDER BY database, table;
```

### 场景 3: 查找没有注释的列

```sql
-- 查找重要表中没有注释的列
SELECT
    database,
    table,
    name AS column_name,
    type,
    position
FROM system.columns
WHERE database IN ('your_database')
  AND table IN ('important_table1', 'important_table2')
  AND (comment = '' OR comment IS NULL)
ORDER BY database, table, position;
```

### 场景 4: 查找列类型变更建议

```sql
-- 建议将 String 类型改为 LowCardinality 的列
SELECT
    database,
    table,
    name AS column_name,
    type,
    data_compressed_bytes,
    data_uncompressed_bytes,
    marks_bytes
FROM system.columns
WHERE type = 'String'
  AND database != 'system'
  AND data_uncompressed_bytes > 100 * 1024 * 1024  -- 大于 100MB
  AND marks_bytes * 10 < data_uncompressed_bytes  -- 标记空间相对较小
ORDER BY data_uncompressed_bytes DESC
LIMIT 20;
```

### 场景 5: 查找可能过大的列

```sql
-- 查找占用空间过大且压缩率低的列
SELECT
    database,
    table,
    name AS column_name,
    type,
    formatReadableSize(data_compressed_bytes) AS compressed_size,
    formatReadableSize(data_uncompressed_bytes) AS uncompressed_size,
    ROUND(data_compressed_bytes * 100.0 / NULLIF(data_uncompressed_bytes, 0), 2) AS compression_ratio,
    CASE
        WHEN data_compressed_bytes > 1024 * 1024 * 1024 THEN '>= 1GB'
        WHEN data_compressed_bytes > 100 * 1024 * 1024 THEN '100MB-1GB'
        WHEN data_compressed_bytes > 10 * 1024 * 1024 THEN '10MB-100MB'
        ELSE '< 10MB'
    END AS size_category
FROM system.columns
WHERE database != 'system'
  AND data_uncompressed_bytes > 0
  AND data_compressed_bytes * 100.0 / data_uncompressed_bytes > 50  -- 压缩率高于 50%
ORDER BY data_compressed_bytes DESC
LIMIT 50;
```

## 📊 比较表结构

### 比较两个表的结构

```sql
-- 比较表 A 和表 B 的结构差异
SELECT
    'Only in table_a' AS difference_type,
    name AS column_name,
    type,
    position
FROM system.columns
WHERE database = 'your_database' AND table = 'table_a'

UNION ALL

SELECT
    'Only in table_b',
    name,
    type,
    position
FROM system.columns
WHERE database = 'your_database' AND table = 'table_b'

UNION ALL

SELECT
    'Different type',
    a.name,
    concat(a.type, ' -> ', b.type),
    a.position
FROM system.columns AS a
INNER JOIN system.columns AS b ON 
    a.database = b.database 
    AND a.name = b.name
    AND a.type != b.type
WHERE a.database = 'your_database'
  AND a.table = 'table_a'
  AND b.table = 'table_b'

ORDER BY difference_type, position;
```

## 💡 最佳实践

1. **添加注释**：为所有列添加有意义的注释，提高可维护性
2. **使用合适的类型**：根据数据特征选择最合适的列类型
3. **使用 LowCardinality**：对于低基数的字符串列使用 LowCardinality 优化
4. **避免过度使用 Nullable**：Nullable 列会影响查询性能
5. **定期审查**：定期审查列的类型和大小，优化存储和查询性能

## 📝 相关文档

- [01_databases_tables.md](./01_databases_tables.md) - 数据库和表信息
- [05-data-type/](../05-data-type/) - 数据类型详解
- [03_partitions_parts.md](./03_partitions_parts.md) - 分区和数据块
