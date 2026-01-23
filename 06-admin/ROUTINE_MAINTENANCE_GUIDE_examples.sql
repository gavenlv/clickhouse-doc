-- ================================================
-- ROUTINE_MAINTENANCE_GUIDE_examples.sql
-- 从 ROUTINE_MAINTENANCE_GUIDE.md 提取的 SQL 示例
-- 提取时间: 2026-01-23 14:40:17
-- ================================================


-- ========================================
-- 1. 健康检查
-- ========================================

-- 执行健康检查
SELECT
    'Replica Status' as check_type,
    sum(absolute_delay > 0) as delayed_replicas,
    sum(is_session_expired = 1) as expired_replicas
FROM system.replicas
UNION ALL
SELECT
    'Disk Status',
    sum(free_space / total_space < 0.2),
    sum(free_space / total_space < 0.1)
FROM system.disks
UNION ALL
SELECT
    'Merge Status',
    sum(count(*) > 20),
    sum(count(*) > 50)
FROM (
    SELECT count(*) as cnt
    FROM system.parts
    WHERE active = 1
    GROUP BY database, table
)
UNION ALL
SELECT
    'Query Status',
    sum(query_duration_ms > 5000),
    sum(query_duration_ms > 10000)
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_time > now() - INTERVAL 1 DAY;

-- ========================================
-- 1. 健康检查
-- ========================================

-- 查看最近的错误
SELECT
    event_time,
    level,
    logger_name,
    message
FROM system.text_log
WHERE level IN ('Error', 'Critical')
  AND event_time > now() - INTERVAL 1 HOUR
ORDER BY event_time DESC
LIMIT 50;

-- ========================================
-- 1. 健康检查
-- ========================================

-- 查看最慢的查询
SELECT
    query_duration_ms / 1000 as duration_seconds,
    query,
    read_rows,
    formatReadableSize(read_bytes) as bytes_read,
    memory_usage
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query NOT LIKE '%system.query_log%'
  AND query_duration_ms > 1000
  AND event_time > now() - INTERVAL 1 DAY
ORDER BY query_duration_ms DESC
LIMIT 10;

-- ========================================
-- 1. 健康检查
-- ========================================

-- 查看磁盘使用情况
SELECT
    name,
    path,
    formatReadableSize(free_space) as free,
    formatReadableSize(total_space) as total,
    (total_space - free_space) / total_space * 100 as used_percent
FROM system.disks;

-- ========================================
-- 1. 健康检查
-- ========================================

-- 查看待处理的合并任务
SELECT
    database,
    table,
    count(*) as pending_merges,
    sum(progress) as total_progress
FROM system.merges
GROUP BY database, table
ORDER BY pending_merges DESC;

-- ========================================
-- 1. 健康检查
-- ========================================

-- 删除 30 天前的查询日志
ALTER TABLE system.query_log ON CLUSTER 'treasurycluster'
DELETE WHERE event_date < today() - 30;

-- 删除 7 天前的文本日志
ALTER TABLE system.text_log ON CLUSTER 'treasurycluster'
DELETE WHERE event_date < today() - 7;

-- ========================================
-- 1. 健康检查
-- ========================================

-- 生成 OPTIMIZE 语句
SELECT
    'OPTIMIZE TABLE ' || database || '.' || table || ' ON CLUSTER ''treasurycluster'' FINAL;' as optimize_sql
FROM system.parts
WHERE active = 1
  AND database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
  AND count() > 30
GROUP BY database, table
ORDER BY database, table;

-- ========================================
-- 1. 健康检查
-- ========================================

-- 查看数据分布
SELECT
    database,
    table,
    avg(rows_per_shard) as avg_rows,
    max(rows_per_shard) - min(rows_per_shard) as max_min_diff,
    (max(rows_per_shard) - min(rows_per_shard)) / avg(rows_per_shard) * 100 as diff_percent
FROM (
    SELECT
        database,
        table,
        shard_num,
        sum(rows) as rows_per_shard
    FROM system.parts
    WHERE active = 1
      AND database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
    GROUP BY database, table, shard_num
)
GROUP BY database, table
HAVING (max(rows_per_shard) - min(rows_per_shard)) / avg(rows_per_shard) > 0.3
ORDER BY diff_percent DESC;

-- ========================================
-- 1. 健康检查
-- ========================================

-- 查看碎片化严重的表
SELECT
    database,
    table,
    count(*) as part_count,
    countIf(level > 1) as non_level0_parts,
    sum(rows) as total_rows,
    formatReadableSize(sum(bytes_on_disk)) as total_size
FROM system.parts
WHERE active = 1
  AND database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
GROUP BY database, table
HAVING count(*) > 50
ORDER BY part_count DESC;

-- ========================================
-- 1. 健康检查
-- ========================================

-- 生成清理脚本（手动执行）
SELECT
    'ALTER TABLE ' || database || '.' || table ||
    ' DROP PARTITION ''' || partition || ''' ON CLUSTER ''treasurycluster'';' as cleanup_sql
FROM system.parts
WHERE active = 1
  AND database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
  AND partition <= toString(toYYYYMM(now() - INTERVAL 3 MONTH))
GROUP BY database, table, partition
ORDER BY database, table, partition;

-- ========================================
-- 1. 健康检查
-- ========================================

-- 更新表统计信息
ANALYZE TABLE database.table ON CLUSTER 'treasurycluster';

-- ========================================
-- 1. 健康检查
-- ========================================

-- 查看跳数索引
SELECT
    database,
    table,
    name,
    type,
    expr
FROM system.data_skipping_indices
WHERE database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
ORDER BY database, table;

-- ========================================
-- 1. 健康检查
-- ========================================

-- 查看所有 TTL 设置
SELECT
    database,
    table,
    name,
    min_bytes,
    max_bytes
FROM system.ttl_entries
WHERE database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
ORDER BY database, table;

-- ========================================
-- 1. 健康检查
-- ========================================

-- 删除所有测试表
SELECT
    'DROP TABLE IF EXISTS ' || database || '.' || name || ' ON CLUSTER ''treasurycluster'';' as drop_sql
FROM system.tables
WHERE database LIKE 'test%'
   OR name LIKE 'test%'
   OR database LIKE 'temp%'
   OR name LIKE 'temp%';

-- ========================================
-- 1. 健康检查
-- ========================================

-- 删除所有临时表
DROP TABLE IF EXISTS system.temp_table ON CLUSTER 'treasurycluster';

-- ========================================
-- 1. 健康检查
-- ========================================

-- 查看合并进度
SELECT
    database,
    table,
    partition_id,
    result_part_name,
    progress,
    num_parts,
    formatReadableSize(total_size_bytes_compressed) as size
FROM system.merges
ORDER BY total_size_bytes_compressed DESC;

-- 调整合并参数（临时）
SET GLOBAL max_bytes_to_merge_at_max_space_in_pool = 10737418240;  -- 10GB
SET GLOBAL max_bytes_to_merge_at_once = 1610612736;  -- 1.5GB

-- ========================================
-- 1. 健康检查
-- ========================================

-- 查看未使用索引的查询
SELECT
    query,
    read_rows,
    rows_before_limit
FROM system.query_log
WHERE type = 'QueryFinish'
  AND read_rows / rows_before_limit > 1000  -- 读取了 1000 倍的数据
  AND event_time > now() - INTERVAL 7 DAY
ORDER BY read_rows DESC
LIMIT 20;

-- ========================================
-- 1. 健康检查
-- ========================================

-- 查看表大小
SELECT
    database,
    name,
    engine,
    formatReadableSize(total_rows) as rows,
    formatReadableSize(total_bytes) as size
FROM system.tables
WHERE database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
ORDER BY total_bytes DESC;

-- ========================================
-- 1. 健康检查
-- ========================================

-- 查看分区信息
SELECT
    database,
    table,
    partition,
    count(*) as part_count,
    sum(rows) as rows,
    formatReadableSize(sum(bytes_on_disk)) as size
FROM system.parts
WHERE active = 1
GROUP BY database, table, partition
ORDER BY database, table, partition;

-- ========================================
-- 1. 健康检查
-- ========================================

-- 使用 TTL 自动清理
ALTER TABLE database.table ON CLUSTER 'treasurycluster'
MODIFY TTL event_time TO DELETE + INTERVAL 90 DAY;

-- 手动删除旧数据
ALTER TABLE database.table ON CLUSTER 'treasurycluster'
DELETE WHERE event_time < now() - INTERVAL 90 DAY;

-- ========================================
-- 1. 健康检查
-- ========================================

-- 查看所有跳数索引
SELECT
    database,
    table,
    name,
    type,
    expr,
    granularity
FROM system.data_skipping_indices
WHERE database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
ORDER BY database, table;

-- 添加跳数索引
ALTER TABLE database.table ON CLUSTER 'treasurycluster'
ADD INDEX idx_column (column) TYPE minmax GRANULARITY 1;

-- 删除跳数索引
ALTER TABLE database.table ON CLUSTER 'treasurycluster'
DROP INDEX idx_column;

-- ========================================
-- 1. 健康检查
-- ========================================

-- 查看所有 Projection
SELECT
    database,
    table,
    name,
    formatReadableSize(data_compressed_bytes) as compressed_size
FROM system.projection_parts
WHERE active = 1
ORDER BY database, table, name;

-- 创建 Projection
ALTER TABLE database.table ON CLUSTER 'treasurycluster'
ADD PROJECTION projection_name
(SELECT column1, column2 ORDER BY column1);

-- 删除 Projection
ALTER TABLE database.table ON CLUSTER 'treasurycluster'
DROP PROJECTION projection_name;
