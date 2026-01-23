-- ================================================
-- 03_partitions_parts_examples.sql
-- 从 03_partitions_parts.md 提取的 SQL 示例
-- 提取时间: 2026-01-23 14:40:17
-- ================================================


-- ========================================
-- 基本查询
-- ========================================

-- 查看表的所有数据块
SELECT
    database,
    table,
    partition,
    name AS part_name,
    active,
    rows,
    bytes_on_disk,
    marks,
    level,
    modification_time
FROM system.parts
WHERE database = 'your_database'
  AND table = 'your_table'
ORDER BY partition, name;

-- ========================================
-- 基本查询
-- ========================================

-- 查看表的活动分区（不包括合并中的部分）
SELECT
    partition,
    sum(rows) AS total_rows,
    formatReadableSize(sum(bytes_on_disk)) AS total_size,
    count() AS part_count,
    min(modification_time) AS oldest_part,
    max(modification_time) AS newest_part
FROM system.parts
WHERE database = 'your_database'
  AND table = 'your_table'
  AND active = 1
GROUP BY partition
ORDER BY partition DESC;

-- ========================================
-- 基本查询
-- ========================================

-- 查看表的分区概览
SELECT
    partition,
    sum(rows) AS total_rows,
    formatReadableSize(sum(bytes_on_disk)) AS total_size,
    count() AS part_count,
    avg(rows) AS avg_rows_per_part,
    avg(bytes_on_disk) AS avg_bytes_per_part
FROM system.parts
WHERE database = 'your_database'
  AND table = 'your_table'
  AND active = 1
GROUP BY partition
ORDER BY partition DESC;

-- ========================================
-- 基本查询
-- ========================================

-- 删除指定分区（谨慎操作！）
ALTER TABLE your_database.your_table
DROP PARTITION '2023-01';

-- 查看被删除的分区（非活动块）
SELECT
    partition,
    name AS part_name,
    rows,
    bytes_on_disk,
    remove_time
FROM system.parts
WHERE database = 'your_database'
  AND table = 'your_table'
  AND active = 0
  AND remove_time IS NOT NULL
ORDER BY remove_time DESC;

-- ========================================
-- 基本查询
-- ========================================

-- 查看分区大小分布
SELECT
    partition,
    formatReadableSize(sum(bytes_on_disk)) AS size,
    formatReadableQuantity(sum(rows)) AS rows,
    count() AS parts
FROM system.parts
WHERE database = 'your_database'
  AND table = 'your_table'
  AND active = 1
GROUP BY partition
ORDER BY sum(bytes_on_disk) DESC;

-- ========================================
-- 基本查询
-- ========================================

-- 检查数据块的碎片化程度
SELECT
    database,
    table,
    partition,
    count() AS part_count,
    avg(rows) AS avg_rows_per_part,
    min(rows) AS min_rows,
    max(rows) AS max_rows,
    avg(bytes_on_disk) AS avg_size,
    sum(bytes_on_disk) AS total_size,
    (count() - 1.0) / NULLIF(count(), 0) AS fragmentation_ratio
FROM system.parts
WHERE database = 'your_database'
  AND table = 'your_table'
  AND active = 1
GROUP BY database, table, partition
HAVING count() > 5  -- 只关注有多个数据块的分区
ORDER BY fragmentation_ratio DESC;

-- ========================================
-- 基本查询
-- ========================================

-- 查看数据块的合并层级分布
SELECT
    database,
    table,
    partition,
    level,
    count() AS part_count,
    sum(rows) AS total_rows,
    formatReadableSize(sum(bytes_on_disk)) AS total_size
FROM system.parts
WHERE database = 'your_database'
  AND table = 'your_table'
  AND active = 1
GROUP BY database, table, partition, level
ORDER BY database, table, partition, level;

-- ========================================
-- 基本查询
-- ========================================

-- 查看等待合并的数据块
SELECT
    database,
    table,
    partition,
    name AS part_name,
    rows,
    bytes_on_disk,
    level,
    modification_time
FROM system.parts
WHERE database = 'your_database'
  AND table = 'your_table'
  AND active = 1
  AND level > 0
ORDER BY level, rows DESC;

-- ========================================
-- 基本查询
-- ========================================

-- 按月统计分区（假设分区键是日期）
SELECT
    toYYYYMM(toDate(partition)) AS month,
    count() AS partition_count,
    sum(rows) AS total_rows,
    formatReadableSize(sum(bytes_on_disk)) AS total_size
FROM system.parts
WHERE database = 'your_database'
  AND table = 'your_table'
  AND active = 1
GROUP BY month
ORDER BY month DESC;

-- ========================================
-- 基本查询
-- ========================================

-- 分析分区的写入时间
SELECT
    partition,
    min(modification_time) AS first_write,
    max(modification_time) AS last_write,
    dateDiff('minute', min(modification_time), max(modification_time)) AS write_duration_minutes,
    count() AS part_count
FROM system.parts
WHERE database = 'your_database'
  AND table = 'your_table'
  AND active = 1
  AND modification_time >= today() - INTERVAL 7 DAY
GROUP BY partition
ORDER BY first_write DESC;

-- ========================================
-- 基本查询
-- ========================================

-- 识别碎片化严重的分区（建议运行 OPTIMIZE）
SELECT
    database,
    table,
    partition,
    count() AS part_count,
    sum(rows) AS total_rows,
    formatReadableSize(sum(bytes_on_disk)) AS total_size,
    avg(rows) AS avg_rows_per_part,
    concat('OPTIMIZE TABLE ', database, '.', table, ' PARTITION ''', partition, ''' FINAL;') AS optimize_sql
FROM system.parts
WHERE database = 'your_database'
  AND table = 'your_table'
  AND active = 1
GROUP BY database, table, partition
HAVING count() > 10  -- 分区中有超过 10 个数据块
ORDER BY part_count DESC
LIMIT 20;

-- ========================================
-- 基本查询
-- ========================================

-- 查找可以清理的旧分区
SELECT
    database,
    table,
    partition,
    formatReadableSize(sum(bytes_on_disk)) AS size,
    formatReadableQuantity(sum(rows)) AS rows,
    concat('ALTER TABLE ', database, '.', table, ' DROP PARTITION ''', partition, ''';') AS drop_sql
FROM system.parts
WHERE database = 'your_database'
  AND table = 'your_table'
  AND active = 1
  AND toDate(partition) < today() - INTERVAL 90 DAY  -- 90 天前
GROUP BY database, table, partition
ORDER BY partition;

-- ========================================
-- 基本查询
-- ========================================

-- 按月分析数据增长
SELECT
    toStartOfMonth(modification_time) AS month,
    count() AS parts_created,
    sum(rows) AS rows_added,
    formatReadableSize(sum(bytes_on_disk)) AS bytes_added
FROM system.parts
WHERE database = 'your_database'
  AND table = 'your_table'
  AND modification_time >= today() - INTERVAL 6 MONTH
GROUP BY month
ORDER BY month DESC;

-- ========================================
-- 基本查询
-- ========================================

-- 检查重复的分区（异常情况）
SELECT
    database,
    table,
    partition,
    count() AS duplicate_parts
FROM system.parts
WHERE database = 'your_database'
  AND table = 'your_table'
  AND active = 1
GROUP BY database, table, partition
HAVING count() > 1  -- 正常情况下每个分区应该只有一个活动数据块
ORDER BY duplicate_parts DESC;

-- ========================================
-- 基本查询
-- ========================================

-- 查看数据块大小分布
SELECT
    CASE
        WHEN bytes_on_disk < 1024 * 1024 THEN 'Small (<1MB)'
        WHEN bytes_on_disk < 10 * 1024 * 1024 THEN 'Medium (1-10MB)'
        WHEN bytes_on_disk < 100 * 1024 * 1024 THEN 'Large (10-100MB)'
        WHEN bytes_on_disk < 1024 * 1024 * 1024 THEN 'X-Large (100MB-1GB)'
        ELSE 'XX-Large (>1GB)'
    END AS size_category,
    count() AS part_count,
    sum(rows) AS total_rows,
    formatReadableSize(sum(bytes_on_disk)) AS total_size
FROM system.parts
WHERE database = 'your_database'
  AND table = 'your_table'
  AND active = 1
GROUP BY size_category
ORDER BY total_size DESC;

-- ========================================
-- 基本查询
-- ========================================

-- 强制合并指定分区
OPTIMIZE TABLE your_database.your_table
PARTITION '2023-01'
FINAL;

-- 查看合并进度
SELECT
    database,
    table,
    partition,
    count() AS part_count_before,
    sum(rows) AS total_rows
FROM system.parts
WHERE database = 'your_database'
  AND table = 'your_table'
  AND partition = '2023-01'
  AND active = 1
GROUP BY database, table, partition;

-- ========================================
-- 基本查询
-- ========================================

-- 查看非活动数据块占用空间
SELECT
    database,
    table,
    count() AS inactive_parts,
    formatReadableSize(sum(bytes_on_disk)) AS total_size
FROM system.parts
WHERE database = 'your_database'
  AND active = 0
GROUP BY database, table
HAVING sum(bytes_on_disk) > 0
ORDER BY total_size DESC;

-- ========================================
-- 基本查询
-- ========================================

-- 查看正在进行的合并任务
SELECT
    database,
    table,
    partition,
    type,
    table_version,
    mutation_id,
    command,
    is_done,
    create_time,
    done_time,
    exception_code,
    exception_text
FROM system.mutations
WHERE database = 'your_database'
  AND is_done = 0
ORDER BY create_time;
