-- ================================================
-- 04_indexes_projections_examples.sql
-- 从 04_indexes_projections.md 提取的 SQL 示例
-- 提取时间: 2026-01-23 14:40:17
-- ================================================


-- ========================================
-- 查看所有跳数索引
-- ========================================

-- 查看所有表的跳数索引
-- SKIPPED: Problematic statement (column_names field does not exist)
-- SELECT
--     database,
--     table,
--     name AS index_name,
--     type,
--     expr,
--     granularity,
--     column_names
-- FROM system.data_skipping_indices
-- WHERE database != 'system'
-- ORDER BY database, table, name

-- ========================================
-- 查看所有跳数索引
-- ========================================

-- 查看特定表的所有索引
-- SKIPPED: Problematic statement (contains non-existent fields/tables)
-- SELECT
--     name AS index_name,
--     type,
--     expr,
--     granularity,
--     column_names,
--     comment
-- FROM system.data_skipping_indices
-- WHERE database = 'your_database'
--   AND table = 'your_table'
-- ORDER BY name;
-- 

-- ========================================
-- 查看所有跳数索引
-- ========================================

-- 统计不同索引类型的使用情况
-- SKIPPED: Problematic statement (column_names field does not exist)
-- SELECT
--     type,
--     count() AS index_count,
--     arrayDistinct(arrayFlatten(groupArray(column_names))) AS columns_used
-- FROM system.data_skipping_indices
-- WHERE database != 'system'
-- GROUP BY type
-- ORDER BY index_count DESC

-- ========================================
-- 查看所有跳数索引
-- ========================================

-- 查看索引的实际使用情况（需要查询日志）
-- SKIPPED: Problematic statement (contains non-existent fields/tables)
-- SELECT
--     index_name,
--     type,
--     expr,
--     granularity,
--     count() AS usage_count
-- FROM system.query_log
-- WHERE type = 'QueryFinish'
--   AND event_date >= today() - INTERVAL 7 DAY
--   AND query ILIKE '%your_table%'
--   AND query NOT ILIKE '%system%'
-- GROUP BY index_name, type, expr, granularity
-- ORDER BY usage_count DESC;
-- 

-- ========================================
-- 查看所有跳数索引
-- ========================================

-- 查找可能未使用的索引
-- SKIPPED: Problematic statement (contains non-existent fields/tables)
-- SELECT
--     database,
--     table,
--     name AS index_name,
--     type,
--     expr,
--     granularity,
--     create_table_query
-- FROM system.data_skipping_indices AS i
-- LEFT JOIN system.tables AS t ON i.database = t.database AND i.table = t.name
-- WHERE i.database = 'your_database'
--   AND i.table NOT LIKE 'test_%'
-- ORDER BY i.database, i.table, i.name;
-- 

-- ========================================
-- 查看所有跳数索引
-- ========================================

-- 查看所有表的投影
-- SKIPPED: Problematic statement (total_bytes field does not exist in system.projections)
-- SELECT
--     database,
--     table,
--     name AS projection_name,
--     type,
--     formatReadableSize(total_bytes) AS size,
--     total_rows,
--     create_time,
--     modify_time,
--     comment
-- FROM system.projections
-- WHERE database != 'system'
-- ORDER BY database, table, name

-- ========================================
-- 查看所有跳数索引
-- ========================================

-- 查看特定表的投影
-- SKIPPED: Problematic statement (contains non-existent fields/tables)
-- SELECT
--     name AS projection_name,
--     type,
--     target_name,
--     formatReadableSize(total_bytes) AS size,
--     total_rows,
--     create_time,
--     modify_time
-- FROM system.projections
-- WHERE database = 'your_database'
--   AND table = 'your_table'
-- ORDER BY name;
-- 

-- ========================================
-- 查看所有跳数索引
-- ========================================

-- 查看投影的数据块
-- SKIPPED: Problematic statement (contains non-existent fields/tables)
-- SELECT
--     database,
--     table,
--     projection,
--     partition,
--     name AS part_name,
--     rows,
--     bytes_on_disk,
--     marks,
--     active
-- FROM system.projection_parts
-- WHERE database = 'your_database'
--   AND table = 'your_table'
--   AND active = 1
-- ORDER BY projection, partition, name;
-- 

-- ========================================
-- 查看所有跳数索引
-- ========================================

-- 分析投影占用的空间
-- SKIPPED: Problematic statement (contains non-existent fields/tables)
-- SELECT
--     database,
--     table,
--     projection,
--     formatReadableSize(sum(bytes_on_disk)) AS total_size,
--     sum(rows) AS total_rows,
--     count() AS parts_count
-- FROM system.projection_parts
-- WHERE database = 'your_database'
--   AND active = 1
-- GROUP BY database, table, projection
-- ORDER BY sum(bytes_on_disk) DESC;
-- 

-- ========================================
-- 查看所有跳数索引
-- ========================================

-- 为表创建 minmax 索引
-- SKIPPED: Problematic statement (contains non-existent fields/tables)
-- ALTER TABLE your_database.your_table
-- ADD INDEX idx_event_time_minmax event_time TYPE minmax GRANULARITY 4;
-- 

-- 为表创建 set 索引
-- SKIPPED: Problematic statement (contains non-existent fields/tables)
-- ALTER TABLE your_database.your_table
-- ADD INDEX idx_status_set status TYPE set(0) GRANULARITY 1;
-- 

-- 为表创建布隆过滤器索引
-- SKIPPED: Problematic statement (contains non-existent fields/tables)
-- ALTER TABLE your_database.your_table
-- ADD INDEX idx_user_id_bloom user_id TYPE bloom_filter(0.01) GRANULARITY 1;
-- 

-- 查看新创建的索引
-- SKIPPED: Problematic statement (contains non-existent fields/tables)
-- SELECT
--     name,
--     type,
--     expr,
--     granularity,
--     column_names
-- FROM system.data_skipping_indices
-- WHERE database = 'your_database'
--   AND table = 'your_table';
-- 

-- ========================================
-- 查看所有跳数索引
-- ========================================

-- 删除索引
-- SKIPPED: Problematic statement (contains non-existent fields/tables)
-- ALTER TABLE your_database.your_table
-- DROP INDEX idx_event_time_minmax;
-- 

-- 验证索引已删除
-- SKIPPED: Problematic statement (contains non-existent fields/tables)
-- SELECT
--     name,
--     type,
--     expr,
--     granularity
-- FROM system.data_skipping_indices
-- WHERE database = 'your_database'
--   AND table = 'your_table';
-- 

-- ========================================
-- 查看所有跳数索引
-- ========================================

-- 创建投影用于加速聚合查询
-- SKIPPED: Problematic statement (contains non-existent fields/tables)
-- ALTER TABLE your_database.your_table
-- ADD PROJECTION projection_daily_summary
-- (
--     SELECT
--         toDate(event_time) AS day,
--         count() AS cnt,
--         sum(amount) AS total_amount
--     GROUP BY day
-- );
-- 

-- 查看创建的投影
-- SKIPPED: Problematic statement (contains non-existent fields/tables)
-- SELECT
--     name,
--     type,
--     create_time
-- FROM system.projections
-- WHERE database = 'your_database'
--   AND table = 'your_table';
-- 

-- ========================================
-- 查看所有跳数索引
-- ========================================

-- 分析查询是否使用了索引
-- SKIPPED: Problematic statement (contains non-existent fields/tables)
-- SELECT
--     query,
--     read_rows,
--     read_bytes,
--     result_rows,
--     result_bytes,
--     elapsed
-- FROM system.query_log
-- WHERE type = 'QueryFinish'
--   AND event_date >= today() - INTERVAL 7 DAY
--   AND query ILIKE '%your_table%'
--   AND query ILIKE '%WHERE%'
-- ORDER BY read_bytes DESC
-- LIMIT 10;
-- 

-- ========================================
-- 查看所有跳数索引
-- ========================================

-- 强制重建索引
-- SKIPPED: Problematic statement (contains non-existent fields/tables)
-- ALTER TABLE your_database.your_table
-- MATERIALIZE INDEX idx_event_time_minmax IN PARTITION '2023-01';
-- 

-- 查看索引状态
-- SKIPPED: Problematic statement (contains non-existent fields/tables)
-- SELECT
--     name,
--     type,
--     status,
--     message
-- FROM system.dropped_indices
-- WHERE database = 'your_database'
--   AND table = 'your_table';
-- 

-- ========================================
-- 查看所有跳数索引
-- ========================================

-- 查找适合创建索引的列（高频 WHERE 条件）
-- SKIPPED: Problematic statement (contains non-existent fields/tables)
-- SELECT
--     query_database,
--     query_table,
--     extractAll(query, 'WHERE ([^ ]+)')[1]::String AS potential_column,
--     count() AS usage_count
-- FROM system.query_log
-- WHERE type = 'QueryFinish'
--   AND event_date >= today() - INTERVAL 7 DAY
--   AND query ILIKE '%WHERE%'
--   AND query_database != 'system'
-- GROUP BY query_database, query_table, potential_column
-- HAVING count() > 10
-- ORDER BY usage_count DESC
-- LIMIT 20;
-- 

-- ========================================
-- 查看所有跳数索引
-- ========================================

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
