-- 删除分区（语法示例）
-- ALTER TABLE table_name
-- DROP PARTITION partition_value;

-- 删除多个分区（语法示例）
-- ALTER TABLE table_name
-- DROP PARTITION partition_value1, partition_value2, ...;

-- 使用 DETACH 后再删除（更安全，语法示例）
-- ALTER TABLE table_name
-- DETACH PARTITION partition_value;

-- ========================================
-- 📋 基本语法
-- ========================================

-- 删除 2023 年 1 月的所有数据（需要在MergeTree表上执行）
-- ALTER TABLE events
-- DROP PARTITION '2023-01';

-- 删除多个月份的数据（需要在MergeTree表上执行）
-- ALTER TABLE events
-- DROP PARTITION '2023-01', '2023-02', '2023-03';

-- ========================================
-- 📋 查看分区
-- ========================================

-- 查看当前分区
SELECT 
    partition,
    formatReadableSize(sum(bytes_on_disk)) AS size,
    sum(rows) AS rows
FROM system.parts
WHERE table = 'events' AND active = 1
GROUP BY partition
ORDER BY partition;

-- ========================================
-- 📋 分区操作
-- ========================================

-- 删除测试分区的数据（需要在MergeTree表上执行）
-- ALTER TABLE events
-- DROP PARTITION 'test_2023-01';

-- 或使用 DETACH（保留数据文件，需要在MergeTree表上执行）
-- ALTER TABLE events
-- DETACH PARTITION 'test_2023-01';

-- 重新附加分区（恢复数据，需要在MergeTree表上执行）
-- ALTER TABLE events
-- ATTACH PARTITION 'test_2023-01';

-- ========================================
-- 📋 分区值格式说明
-- ========================================

-- 按月分区
-- PARTITION BY toYYYYMM(event_time)
-- 分区值: '202301'

-- 按日期分区
-- PARTITION BY toDate(event_time)
-- 分区值: '2023-01-01'

-- 按年分区
-- PARTITION BY toYYYY(event_time)
-- 分区值: '2023'

-- 按自定义字段分区
-- PARTITION BY toUInt32(user_id) / 10000
-- 分区值: '1', '2', '3', ...

-- 复合分区
-- PARTITION BY (event_date, type)
-- 分区值: ('2023-01-01', 'type1')

-- ========================================
-- 📋 分区查询
-- ========================================

-- 查看表的分区详情（需要替换数据库名和表名）
-- SELECT
--     partition,
--     sum(rows) AS total_rows,
--     formatReadableSize(sum(bytes_on_disk)) AS total_size,
--     count() AS parts_count,
--     min(modification_time) AS oldest_part,
--     max(modification_time) AS newest_part
-- FROM system.parts
-- WHERE database = 'your_database'
--   AND table = 'your_table'
--   AND active = 1
-- GROUP BY partition
-- ORDER BY partition DESC;

-- ========================================
-- 📋 分区分析
-- ========================================

-- 分析分区大小分布（需要替换数据库名和表名）
-- SELECT
--     partition,
--     formatReadableSize(sum(bytes_on_disk)) AS size,
--     formatReadableQuantity(sum(rows)) AS rows,
--     sum(rows) / NULLIF(sum(bytes_on_disk), 0) AS rows_per_byte
-- FROM system.parts
-- WHERE database = 'your_database'
--   AND table = 'your_table'
--   AND active = 1
-- GROUP BY partition
-- ORDER BY sum(bytes_on_disk) DESC;

-- ========================================
-- 📋 旧分区识别
-- ========================================

-- 查找可以删除的旧分区（超过 90 天，需要替换数据库名和表名）
-- SELECT
--     partition,
--     toDate(replaceRegexpOne(partition, '^(\\d{4})(\\d{2})', '\\1-\\2-01')) AS partition_date,
--     formatReadableSize(sum(bytes_on_disk)) AS size,
--     formatReadableQuantity(sum(rows)) AS rows,
--     dateDiff('day', 
--         toDate(replaceRegexpOne(partition, '^(\\d{4})(\\d{2})', '\\1-\\2-01')),
--         today()
--     ) AS days_ago
-- FROM system.parts
-- WHERE database = 'your_database'
--   AND table = 'your_table'
--   AND active = 1
--   AND toDate(replaceRegexpOne(partition, '^(\\d{4})(\\d{2})', '\\1-\\2-01')) < today() - INTERVAL 90 DAY
-- GROUP BY partition
-- HAVING sum(bytes_on_disk) > 0
-- ORDER BY partition;

-- ========================================
-- 📋 数据归档策略
-- ========================================

-- 1. 创建归档表（使用不同的存储策略，示例）
-- CREATE TABLE IF NOT EXISTS events_archive AS events
-- ENGINE = MergeTree
-- PARTITION BY toYYYYMM(event_time)
-- ORDER BY (event_time, user_id)
-- SETTINGS storage_policy = 'archive_policy';

-- 2. 将旧数据移动到归档表（示例）
-- INSERT INTO events_archive
-- SELECT * FROM events
-- WHERE event_time < '2023-01-01';

-- 3. 验证数据已复制（示例）
-- SELECT 
--     'events' as table_name,
--     partition,
--     sum(rows) as rows
-- FROM system.parts
-- WHERE database = 'default' AND table = 'events' AND active = 1
-- GROUP BY partition
-- 
-- UNION ALL
-- 
-- SELECT 
--     'events_archive' as table_name,
--     partition,
--     sum(rows)
-- FROM system.parts
-- WHERE database = 'default' AND table = 'events_archive' AND active = 1
-- GROUP BY partition;

-- 4. 删除原表中的旧分区（示例）
-- ALTER TABLE events
-- DROP PARTITION '2022-12';

-- ========================================
-- 📋 分区交换删除
-- ========================================

-- 使用分区交换快速删除数据（适用于临时表，示例）

-- 1. 创建临时表
-- CREATE TEMPORARY TABLE temp_delete AS events;

-- 2. 插入要保留的数据
-- INSERT INTO temp_delete
-- SELECT * FROM events
-- WHERE event_time >= '2023-01-01';

-- 3. 替换分区
-- ALTER TABLE events
-- REPLACE PARTITION '2023-01' FROM temp_delete;

-- 4. 验证数据
-- SELECT count() FROM events;

-- ========================================
-- 📋 重新分区删除
-- ========================================

-- 将数据重新分区后删除（示例）

-- 1. 添加临时分区列
-- ALTER TABLE events
-- ADD COLUMN temp_partition String;

-- 2. 标记要删除的数据
-- ALTER TABLE events
-- UPDATE temp_partition = 'delete' WHERE event_time < '2023-01-01';

-- 3. 强制合并
-- OPTIMIZE TABLE events FINAL;

-- 4. 删除标记的分区
-- ALTER TABLE events
-- DROP PARTITION 'delete';

-- 5. 清理临时列
-- ALTER TABLE events
-- DROP COLUMN temp_partition;

-- ========================================
-- 📋 监控 ALTER 操作
-- ========================================

-- 查看正在执行的 ALTER 操作（需要使用正确的字段名）
-- SELECT
--     database,
--     table,
--     command,
--     create_time
-- FROM system.mutations
-- WHERE command LIKE '%DROP PARTITION%'
-- ORDER BY create_time DESC;

-- ========================================
-- 📋 基本语法
-- ========================================


-- 检查分区是否已删除（示例）
SELECT
    partition,
    sum(rows) AS rows,
    sum(bytes_on_disk) AS bytes
FROM system.parts
WHERE database = 'your_database'
  AND table = 'your_table'
  AND active = 1
GROUP BY partition
ORDER BY partition;

-- 检查非活动数据块（等待清理，示例）
SELECT
    partition,
    name AS part_name,
    bytes_on_disk,
    remove_time
FROM system.parts
WHERE database = 'your_database'
  AND table = 'your_table'
  AND active = 0
ORDER BY partition;
