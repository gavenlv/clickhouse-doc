-- ================================================
-- BACKUP_RECOVERY_GUIDE_examples.sql
-- 从 BACKUP_RECOVERY_GUIDE.md 提取的 SQL 示例
-- 提取时间: 2026-01-23 14:40:17
-- ================================================


-- ========================================
-- 方案 3：SQL 导出（逻辑备份）
-- ========================================

-- 导出表结构
SHOW CREATE TABLE database.table;

-- 导出表数据（小表）
SELECT * FROM database.table
INTO OUTFILE '/var/lib/clickhouse/exports/table.csv'
FORMAT CSV;

-- 导出表数据（大表，使用 clickhouse-client）
clickhouse-client --query="
    SELECT * FROM database.table
    FORMAT CSVWithNames" > table.csv

-- 导出所有表
clickhouse-client --query="
    SELECT
        'CREATE TABLE ' || database || '.' || name || ' AS ' || create_table_query
    FROM system.tables
    WHERE database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
    FORMAT TSV
" > schema.sql

for table in $(clickhouse-client --query="
    SELECT concat(database, '.', name)
    FROM system.tables
    WHERE database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
    FORMAT TSV
"); do
    clickhouse-client --query="
        SELECT * FROM $table
        FORMAT CSVWithNames" > "${table//./_}.csv"
done

-- ========================================
-- 方案 3：SQL 导出（逻辑备份）
-- ========================================

-- 导入表结构
clickhouse-client < schema.sql

-- 导入数据
clickhouse-client --query="
    INSERT INTO database.table
    FORMAT CSVWithNames" < table.csv

-- ========================================
-- 方案 3：SQL 导出（逻辑备份）
-- ========================================

-- 1. 创建验证表
CREATE TABLE monitoring.backup_verification ON CLUSTER 'treasurycluster' (
    backup_name String,
    backup_time DateTime,
    verification_time DateTime DEFAULT now(),
    status String,
    tables_count UInt32,
    total_rows UInt64,
    total_bytes UInt64
) ENGINE = MergeTree
ORDER BY (backup_time, backup_name);

-- 2. 执行验证
INSERT INTO monitoring.backup_verification
SELECT
    backup_name,
    backup_time,
    now() as verification_time,
    'verified' as status,
    count(*) as tables_count,
    sum(total_rows) as total_rows,
    sum(total_bytes) as total_bytes
FROM system.tables
WHERE database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA');

-- 3. 查看验证结果
SELECT * FROM monitoring.backup_verification
ORDER BY backup_time DESC;

-- ========================================
-- 方案 3：SQL 导出（逻辑备份）
-- ========================================

-- 创建备份监控表
CREATE TABLE monitoring.backup_status ON CLUSTER 'treasurycluster' (
    backup_name String,
    backup_time DateTime,
    backup_type String,
    backup_size UInt64,
    backup_status String,
    upload_status String,
    verification_status String
) ENGINE = MergeTree
ORDER BY (backup_time, backup_name);

-- 查询备份状态
SELECT * FROM monitoring.backup_status
WHERE backup_time > now() - INTERVAL 7 DAY
ORDER BY backup_time DESC;
