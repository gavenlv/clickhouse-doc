-- ================================================
-- 02_columns_schema_examples.sql
-- 从 02_columns_schema.md 提取的 SQL 示例
-- 提取时间: 2026-01-23 14:40:17
-- ================================================


-- ========================================
-- 基本查询
-- ========================================

-- 查看表的所有列
-- SKIPPED: Problematic statement (contains non-existent fields/tables)
-- SELECT
--     database,
--     table,
--     name AS column_name,
--     position,
--     type,
--     default_kind,
--     default_expression,
--     comment,
--     is_subcolumn
-- FROM system.columns
-- WHERE database = 'your_database'
--   AND table = 'your_table'
-- ORDER BY position;
-- 

-- ========================================
-- 基本查询
-- ========================================

-- 查看表的完整结构（包括默认值、压缩等）
-- SKIPPED: Problematic statement (contains non-existent fields/tables)
-- SELECT
--     database,
--     table,
--     name AS column_name,
--     position,
--     type,
--     default_kind,
--     default_expression,
--     data_compressed_bytes,
--     data_uncompressed_bytes,
--     marks_bytes,
--     comment
-- FROM system.columns
-- WHERE database = 'your_database'
--   AND table = 'your_table'
-- ORDER BY position;
-- 

-- ========================================
-- 基本查询
-- ========================================

-- 按数据类型统计列的数量
-- SKIPPED: Problematic statement (contains non-existent fields/tables)
-- SELECT
--     type,
--     count() AS column_count,
--     countIf(database = 'your_database') AS your_db_count
-- FROM system.columns
-- WHERE database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
-- GROUP BY type
-- ORDER BY column_count DESC;
-- 

-- ========================================
-- 基本查询
-- ========================================

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

-- ========================================
-- 基本查询
-- ========================================

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

-- ========================================
-- 基本查询
-- ========================================

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

-- ========================================
-- 基本查询
-- ========================================

-- 分析列的压缩率
-- SKIPPED: Problematic statement (contains non-existent fields/tables)
-- SELECT
--     database,
--     table,
--     name AS column_name,
--     type,
--     data_uncompressed_bytes,
--     data_compressed_bytes,
--     ROUND(data_compressed_bytes * 100.0 / NULLIF(data_uncompressed_bytes, 0), 2) AS compression_ratio,
--     marks_bytes
-- FROM system.columns
-- WHERE database = 'your_database'
--   AND table = 'your_table'
--   AND data_uncompressed_bytes > 0
-- ORDER BY compression_ratio;
-- 

-- ========================================
-- 基本查询
-- ========================================

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

-- ========================================
-- 基本查询
-- ========================================

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

-- ========================================
-- 基本查询
-- ========================================

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

-- ========================================
-- 基本查询
-- ========================================

-- 统计默认值类型
SELECT
    default_kind,
    count() AS column_count
FROM system.columns
WHERE default_kind != ''
GROUP BY default_kind
ORDER BY column_count DESC;

-- ========================================
-- 基本查询
-- ========================================

-- 生成表的 CREATE TABLE 语句
-- SKIPPED: Problematic statement (contains non-existent fields/tables)
-- SELECT 
--     concat(
--         'CREATE TABLE ', database, '.', table, ' (\n',
--         arrayStringConcat(
--             arrayMap(
--                 x -> concat('    ', x),
--                 groupArray(
--                     concat(
--                         name, ' ', type,
--                         CASE 
--                             WHEN default_kind != '' THEN concat(' ', default_kind, ' ', default_expression)
--                             ELSE ''
--                         END,
--                         CASE 
--                             WHEN comment != '' THEN concat(' COMMENT ''', comment, '''')
--                             ELSE ''
--                         END
--                     )
--                 )
--             ),
--             ',\n'
--         ),
--         '\n) ENGINE = ', engine
--     ) AS create_table_sql
-- FROM (
--     SELECT 
--         c.database,
--         c.table,
--         c.name,
--         c.type,
--         c.default_kind,
--         c.default_expression,
--         c.comment,
--         t.engine
--     FROM system.columns AS c
--     JOIN system.tables AS t ON c.database = t.database AND c.table = t.name
--     WHERE c.database = 'your_database'
--       AND c.table = 'your_table'
--     ORDER BY c.position
-- )
-- GROUP BY database, table, engine;
-- 

-- ========================================
-- 基本查询
-- ========================================

-- 查找可能有重复列名的表（考虑大小写）
SELECT
    database,
    table,
    lower(name) AS name,
    count() AS duplicate_count
FROM system.columns
WHERE database != 'system'
GROUP BY database, table, lower(name)
HAVING count() > 1
ORDER BY database, table;

-- ========================================
-- 基本查询
-- ========================================

-- 查找重要表中没有注释的列
-- SKIPPED: Problematic statement (contains non-existent fields/tables)
-- SELECT
--     database,
--     table,
--     name AS column_name,
--     type,
--     position
-- FROM system.columns
-- WHERE database IN ('your_database')
--   AND table IN ('important_table1', 'important_table2')
--   AND (comment = '' OR comment IS NULL)
-- ORDER BY database, table, position;
-- 

-- ========================================
-- 基本查询
-- ========================================

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

-- ========================================
-- 基本查询
-- ========================================

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

-- ========================================
-- 基本查询
-- ========================================

-- 比较表 A 和表 B 的结构差异
-- SKIPPED: Problematic statement (contains non-existent fields/tables)
-- SELECT
--     'Only in table_a' AS difference_type,
--     name AS column_name,
--     type,
--     position
-- FROM system.columns
-- WHERE database = 'your_database' AND table = 'table_a'
-- 
-- UNION ALL
-- 
-- SELECT
--     'Only in table_b',
--     name,
--     type,
--     position
-- FROM system.columns
-- WHERE database = 'your_database' AND table = 'table_b'
-- 
-- UNION ALL
-- 
-- SELECT
--     'Different type',
--     a.name,
--     concat(a.type, ' -> ', b.type),
--     a.position
-- FROM system.columns AS a
-- INNER JOIN system.columns AS b ON 
--     a.database = b.database 
--     AND a.name = b.name
--     AND a.type != b.type
-- WHERE a.database = 'your_database'
--   AND a.table = 'table_a'
--   AND b.table = 'table_b'
-- 
-- ORDER BY difference_type, position;
-- 
