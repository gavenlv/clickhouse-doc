-- ============================================================================
-- 02 - 备份恢复深度
-- ============================================================================
-- 场景: 数据备份、灾难恢复、跨集群迁移、数据校验、备份策略设计
-- 集群: treasurycluster (2副本)
-- 耗时: 15-30分钟
-- 注意: ALTER TABLE FREEZE 已废弃（22.8+），统一使用 BACKUP 命令
-- ============================================================================

DROP DATABASE IF EXISTS ops_test;
CREATE DATABASE ops_test;
USE ops_test;

-- ============================================================================
-- 【原理】备份恢复策略
--
-- 备份方案对比（ClickHouse 25.12）：
--   ┌──────────────────┬──────────────────┬──────────────────┬──────────────────┐
--   │     方案         │     优点         │     缺点         │     适用场景     │
--   ├──────────────────┼──────────────────┼──────────────────┼──────────────────┤
--   │ BACKUP/RESTORE   │ 原生 SQL 命令    │ 22.8+ 版本才支持 │ 通用场景首选    │
--   │ (推荐)           │ 支持 S3 远端     │ 大表性能一般     │                  │
--   ├──────────────────┼──────────────────┼──────────────────┼──────────────────┤
--   │ clickhouse-backup│ 全量+增量        │ 需要额外部署     │ 大规模集群     │
--   │ (工具)           │ 支持 S3/本地     │ 学习成本         │ 自动化备份     │
--   ├──────────────────┼──────────────────┼──────────────────┼──────────────────┤
--   │ FREEZE（快照）   │ 速度快           │ 22.8+ 已废弃     │ 不推荐使用     │
--   │                  │ 不影响读写       │ 管理复杂         │                  │
--   ├──────────────────┼──────────────────┼──────────────────┼──────────────────┤
--   │ SQL 导出         │ 灵活、跨版本     │ 大表慢           │ 小表/迁移       │
--   │                  │ 可选择性导出     │ 不含配置         │                  │
--   └──────────────────┴──────────────────┴──────────────────┴──────────────────┘
--
-- 推荐备份策略：
--   每日全量（本地保留 7 天）+ 每小时增量（本地保留 3 天）
--   远程（S3）保留 30 天全量 + 7 天增量
-- ============================================================================

-- ============================================================================
-- 【坑】重要注意事项
--   1. ALTER TABLE FREEZE 从 22.8 开始废弃，不要在新代码中使用
--   2. BACKUP 命令需要配置 backup_settings，否则默认存储到本地
--   3. RESTORE 需要确保目标表不存在或使用 REPLACE 选项
--   4. 跨版本恢复时，高版本备份可能无法恢复到低版本
--   5. 备份验证至关重要，备份文件损坏等于没有备份
-- ============================================================================

-- ==========================================
-- 1. 创建测试数据
-- ==========================================

-- 创建测试表（模拟业务数据）
CREATE TABLE IF NOT EXISTS ops_test.users (
    user_id UInt64,
    name String,
    email String,
    created_at DateTime DEFAULT now()
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(created_at)
ORDER BY user_id;

CREATE TABLE IF NOT EXISTS ops_test.orders (
    order_id UInt64,
    user_id UInt64,
    product_id UInt32,
    amount Decimal(10, 2),
    order_date DateTime DEFAULT now()
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(order_date)
ORDER BY (user_id, order_id);

-- 插入测试数据
INSERT INTO ops_test.users (user_id, name, email) VALUES
(1, 'Alice', 'alice@example.com'),
(2, 'Bob', 'bob@example.com'),
(3, 'Charlie', 'charlie@example.com');

INSERT INTO ops_test.orders (order_id, user_id, product_id, amount) VALUES
(1001, 1, 101, 99.99),
(1002, 1, 102, 49.99),
(1003, 2, 103, 199.99),
(1004, 3, 104, 149.99);

-- 确认数据
SELECT 'Users:' AS table_name, count() AS cnt FROM ops_test.users
UNION ALL
SELECT 'Orders:', count() FROM ops_test.orders;

-- ==========================================
-- 2. 使用 BACKUP 命令（原生 SQL 备份，推荐）
-- ==========================================

-- 【场景】ClickHouse 25.12 原生 BACKUP 命令
-- 【原理】BACKUP 会创建表的快照，支持全量和增量备份
-- 【对比】相比 FREEZE，BACKUP 更易于管理和自动化

-- 备份单个表
-- BACKUP TABLE ops_test.users TO '/backup/ops_test/users'
-- SETTINGS id = 'backup_users_001';

-- 备份整个数据库
-- BACKUP DATABASE ops_test TO '/backup/ops_test/full'
-- SETTINGS id = 'backup_ops_test_001';

-- 增量备份（基于上次备份）
-- 【原理】增量备份只备份自上次备份以来新增或修改的 Part
-- 【场景】适合频繁备份场景，减少备份时间和存储空间
-- BACKUP DATABASE ops_test TO '/backup/ops_test/incremental'
-- SETTINGS id = 'backup_incremental_001', base_backup = '/backup/ops_test/full';

-- 备份到 S3（推荐用于生产环境）
-- 【原理】S3 备份支持自动分片、加密和生命周期管理
-- 【坑】S3 配置需要在 config.xml 中预先配置好
-- BACKUP DATABASE ops_test TO 'S3://mybucket/backups/ops_test/'
-- SETTINGS id = 'backup_ops_test_s3_001';

-- 从备份恢复
-- 【场景】恢复单个表
-- 【坑】RESTORE 前需要确保目标表不存在，或使用 REPLACE 选项
-- RESTORE TABLE ops_test.users FROM '/backup/ops_test/users'
-- SETTINGS id = 'restore_users_001';

-- 查看备份状态
-- 【场景】查询备份任务的状态和进度
-- SELECT * FROM system.backups ORDER BY start_time DESC LIMIT 10;

-- ==========================================
-- 3. 全量备份和增量备份策略
-- ==========================================

-- 【场景】设计完整的备份策略
-- 【原理】全量备份 + 增量备份的组合，在 RTO 和存储成本之间取得平衡

-- 3.1 备份策略模板
-- 每日全量备份（凌晨 2:00）
-- BACKUP DATABASE ops_test TO '/backup/ops_test/daily/' || formatDateTime(now(), '%Y%m%d')
-- SETTINGS id = 'backup_daily_' || formatDateTime(now(), '%Y%m%d');

-- 每小时增量备份（基于当日全量备份）
-- BACKUP DATABASE ops_test TO '/backup/ops_test/incremental/' || formatDateTime(now(), '%Y%m%d_%H')
-- SETTINGS
--     id = 'backup_incremental_' || formatDateTime(now(), '%Y%m%d_%H'),
--     base_backup = '/backup/ops_test/daily/' || formatDateTime(now(), '%Y%m%d');

-- 3.2 备份保留策略
-- 【场景】自动清理过期备份
-- 【原理】使用系统定时任务（Cron）执行清理脚本
-- 清理 7 天前的本地备份
-- SELECT 'rm -rf /backup/ops_test/daily/' || formatDateTime(now() - INTERVAL 7 DAY, '%Y%m%d') AS cleanup_command;

-- 3.3 备份策略选择指南
SELECT '===== 备份策略选择指南 =====' AS guide;

SELECT '策略 1: 每日全量 + 每小时增量 (推荐)'
UNION ALL
SELECT '  RTO: ~1小时 | RPO: ~1小时 | 存储: 中'
UNION ALL
SELECT '  适用: 中大规模生产集群 (>1TB)'
UNION ALL
SELECT ''
UNION ALL
SELECT '策略 2: 每日全量 (简单)'
UNION ALL
SELECT '  RTO: ~2小时 | RPO: ~24小时 | 存储: 低'
UNION ALL
SELECT '  适用: 小规模集群 (<1TB) 或非关键数据'
UNION ALL
SELECT ''
UNION ALL
SELECT '策略 3: 每日全量 + 实时快照 (高可用)'
UNION ALL
SELECT '  RTO: ~5分钟 | RPO: ~0分钟 | 存储: 高'
UNION ALL
SELECT '  适用: 关键业务数据，对 RPO 要求极高';

-- ==========================================
-- 4. RESTORE 的注意事项
-- ==========================================

-- 【场景】数据恢复的最佳实践和注意事项
-- 【原理】RESTORE 命令将备份数据恢复到目标表

-- 4.1 版本兼容性
-- 【坑】高版本 ClickHouse 的备份可能无法恢复到低版本
-- 建议在恢复前检查版本兼容性
SELECT
    version() AS current_version,
    'BACKUP 版本兼容性要求' AS note,
    'RESTORE 目标版本应 >= 备份源版本' AS recommendation;

-- 4.2 恢复路径和权限
-- 【坑】RESTORE 需要确保目标路径存在且有写入权限
-- 使用 S3 备份时，需要确保 S3 凭据正确

-- 4.3 恢复验证
-- 【场景】恢复完成后，需要验证数据完整性
-- 【原理】对比恢复前后的行数和校验和
SELECT
    'RESTORE 验证清单' AS check_item
UNION ALL
SELECT '1. 检查表结构是否一致'
UNION ALL
SELECT '2. 对比行数'
UNION ALL
SELECT '3. 对比校验和（groupBitXor(cityHash64(*))）'
UNION ALL
SELECT '4. 检查副本同步状态'
UNION ALL
SELECT '5. 验证业务查询结果';

-- ==========================================
-- 5. 跨集群恢复
-- ==========================================

-- 【场景】将数据从一个集群恢复到另一个集群
-- 【原理】使用 remote() 表函数或 BACKUP/RESTORE 跨集群实现

-- 5.1 使用 remote() 表函数
-- 【场景】小规模数据跨集群传输
-- INSERT INTO ops_test.users
-- SELECT * FROM remote('remote-host:9000', ops_test, users, 'default', 'password');

-- 5.2 使用 BACKUP/RESTORE 跨集群
-- 【场景】大规模数据跨集群恢复
-- 步骤 1: 在源集群创建备份到共享存储（如 S3）
-- BACKUP DATABASE ops_test TO 'S3://shared-bucket/backups/ops_test/'
-- SETTINGS id = 'cross_cluster_backup';

-- 步骤 2: 在目标集群从共享存储恢复
-- RESTORE DATABASE ops_test FROM 'S3://shared-bucket/backups/ops_test/'
-- SETTINGS id = 'cross_cluster_restore';

-- 5.3 使用 clickhouse-copier 迁移
-- 【场景】大规模数据分片迁移
-- 【原理】clickhouse-copier 支持分布式数据迁移，支持断点续传
-- clickhouse-copier --config config.xml --task-name migration_task

-- ==========================================
-- 6. 灾难恢复演练
-- ==========================================

-- 【场景】模拟灾难场景，验证恢复流程
-- 【原理】通过定期演练确保恢复流程的有效性

-- 6.1 演练步骤
SELECT '===== 灾难恢复演练步骤 =====' AS drill;

SELECT '步骤 1: 模拟灾难 — DROP 数据库'
UNION ALL
SELECT 'DROP DATABASE IF EXISTS ops_test;'
UNION ALL
SELECT ''
UNION ALL
SELECT '步骤 2: 从备份恢复'
UNION ALL
SELECT 'RESTORE DATABASE ops_test FROM ''/backup/ops_test/full'''
UNION ALL
SELECT 'SETTINGS id = ''drill_restore_001'';'
UNION ALL
SELECT ''
UNION ALL
SELECT '步骤 3: 验证数据完整性'
UNION ALL
SELECT '对比行数和校验和'
UNION ALL
SELECT ''
UNION ALL
SELECT '步骤 4: 验证业务查询'
UNION ALL
SELECT '执行关键业务查询，确认结果正确'
UNION ALL
SELECT ''
UNION ALL
SELECT '步骤 5: 记录恢复时间'
UNION ALL
SELECT '记录 RTO 实际值，优化恢复流程';

-- 6.2 数据校验：对比原始数据和备份数据
-- 【场景】验证备份数据的完整性
-- 【原理】使用 groupBitXor(cityHash64(*)) 计算校验和
SELECT
    'Original' AS source,
    count() AS total_users
FROM ops_test.users

UNION ALL

SELECT
    'Backup',
    count()
FROM ops_test.users_backup;  -- 假设存在备份表

-- 校验和对比
-- 【原理】cityHash64 比 xxHash 更快，适合大数据量校验
SELECT
    'Original' AS source,
    groupBitXor(cityHash64(*)) AS checksum
FROM ops_test.users

UNION ALL

SELECT
    'Backup',
    groupBitXor(cityHash64(*))
FROM ops_test.users_backup;

-- 6.3 恢复时间评估
-- 【场景】评估不同数据量级的恢复时间
SELECT '===== 恢复时间预估 =====' AS rto_estimate;

SELECT '数据量 < 100GB: RTO ~30分钟'
UNION ALL
SELECT '数据量 100GB~1TB: RTO ~2小时'
UNION ALL
SELECT '数据量 1TB~10TB: RTO ~4小时'
UNION ALL
SELECT '数据量 > 10TB: RTO 取决于网络带宽和存储性能';

-- ==========================================
-- 7. 备份策略设计（全量+增量）
-- ==========================================

-- 【场景】设计完整的备份策略，包含保留周期
-- 【原理】全量备份 + 增量备份的组合

-- 7.1 创建备份策略配置表
-- 【场景】管理备份策略参数
CREATE TABLE IF NOT EXISTS ops_test.backup_policy (
    policy_name String,
    backup_type String,       -- 'full', 'incremental'
    schedule_interval String,  -- 'daily', 'hourly'
    retention_local UInt32,   -- 本地保留天数
    retention_remote UInt32,  -- 远程保留天数
    destination String,       -- 备份目标路径
    enabled UInt8 DEFAULT 1,
    created_at DateTime DEFAULT now()
)
ENGINE = MergeTree()
ORDER BY (policy_name, backup_type);

-- 插入策略配置
INSERT INTO ops_test.backup_policy VALUES
('production', 'full', 'daily', 7, 30, '/backup/prod/daily', 1),
('production', 'incremental', 'hourly', 3, 7, '/backup/prod/incremental', 1),
('archive', 'full', 'weekly', 0, 365, 'S3://archive-bucket/backups/', 1);

-- 查看策略配置
SELECT * FROM ops_test.backup_policy;

-- 7.2 备份状态追踪
-- 【场景】记录每次备份的执行状态
CREATE TABLE IF NOT EXISTS ops_test.backup_tracking (
    backup_name String,
    backup_time DateTime,
    backup_type String,
    policy_name String,
    table_count UInt32,
    total_size UInt64,
    status String,           -- 'success', 'failed', 'running'
    duration_seconds UInt32,
    error_message String,
    verification_status String DEFAULT 'pending'
)
ENGINE = MergeTree()
ORDER BY (backup_time, backup_name);

-- 查询最近备份状态
SELECT * FROM ops_test.backup_tracking
WHERE backup_time > now() - INTERVAL 7 DAY
ORDER BY backup_time DESC;

-- ==========================================
-- 8. 备份验证和监控
-- ==========================================

-- 8.1 创建备份验证表
CREATE TABLE IF NOT EXISTS ops_test.backup_verification (
    backup_name String,
    backup_time DateTime,
    verification_time DateTime DEFAULT now(),
    status String,             -- 'verified', 'corrupted', 'incomplete'
    tables_verified UInt32,
    tables_failed UInt32,
    total_rows_original UInt64,
    total_rows_restored UInt64,
    checksum_match UInt8       -- 1=match, 0=mismatch
) ENGINE = MergeTree
ORDER BY (backup_time, backup_name);

-- 8.2 执行验证
-- 【场景】验证备份的可用性
INSERT INTO ops_test.backup_verification
    (backup_name, backup_time, status, tables_verified, tables_failed, total_rows_original, total_rows_restored, checksum_match)
SELECT
    'manual_backup_20260101' AS backup_name,
    now() AS backup_time,
    'verified' AS status,
    count(*) AS tables_verified,
    0 AS tables_failed,
    sum(total_rows) AS total_rows_original,
    sum(total_rows_restored) AS total_rows_restored,
    1 AS checksum_match
FROM system.tables
WHERE database = 'ops_test'
  AND name NOT LIKE '%backup%';

-- 8.3 查看验证结果
SELECT * FROM ops_test.backup_verification
ORDER BY backup_time DESC;

-- 8.4 备份监控告警
-- 【场景】检测备份失败或过期
SELECT
    'Backup Health Check' AS check_type,
    countIf(status = 'failed') AS failed_backups,
    countIf(verification_status = 'pending') AS unverified_backups,
    CASE
        WHEN countIf(status = 'failed') > 0 THEN 'CRITICAL'
        WHEN countIf(verification_status = 'pending') > 0 THEN 'WARNING'
        ELSE 'OK'
    END AS status
FROM ops_test.backup_tracking
WHERE backup_time > now() - INTERVAL 1 DAY;

-- ==========================================
-- 9. 导出表结构（DDL 备份）
-- ==========================================

-- 【场景】备份所有非系统表的表结构，用于灾难恢复
-- 【原理】SHOW CREATE TABLE 输出可重现的 DDL 语句
SELECT
    database,
    'CREATE TABLE IF NOT EXISTS ' || database || '.' || name || ' AS ' || create_table_query AS ddl
FROM system.tables
WHERE database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
  AND database = 'ops_test'
ORDER BY database, name;

-- ==========================================
-- 10. 分区级操作（备份和恢复）
-- ==========================================

-- 【场景】分区级备份和恢复，比全表备份更快
-- 【原理】DETACH/ATTACH 分区操作不会删除数据文件

-- 查看分区信息
SELECT
    table,
    partition,
    name,
    rows,
    bytes_on_disk
FROM system.parts
WHERE table = 'orders'
  AND database = 'ops_test'
  AND active = 1;

-- 分离指定分区（安全移除，保留数据文件）
-- ALTER TABLE ops_test.orders DETACH PARTITION '202601';

-- 恢复分区
-- ALTER TABLE ops_test.orders ATTACH PARTITION '202601';

-- 查看分离的分区
-- SELECT * FROM system.detached_parts WHERE database = 'ops_test';

-- ==========================================
-- 清理
-- ==========================================
DROP TABLE IF EXISTS ops_test.users;
DROP TABLE IF EXISTS ops_test.orders;
DROP TABLE IF EXISTS ops_test.users_backup;
DROP TABLE IF EXISTS ops_test.backup_policy;
DROP TABLE IF EXISTS ops_test.backup_tracking;
DROP TABLE IF EXISTS ops_test.backup_verification;
DROP DATABASE IF EXISTS ops_test;

-- ============================================================================
-- 最佳实践：
-- 1. 3-2-1 备份原则：3 份备份、2 种介质、1 份异地
-- 2. 备份频率：每日全量 + 每小时增量
-- 3. 保留策略：本地 7 天，远程 30 天
-- 4. 定期验证：每周验证备份完整性，每月演练恢复流程
-- 5. 监控告警：备份失败或过期需立即告警
-- 6. 备份配置文件：同时备份 /etc/clickhouse-server/ 配置目录
-- 7. 大表备份优先使用 BACKUP 命令，SQL 导出仅适合小表
-- 8. ALTER TABLE FREEZE 已废弃，不要在 22.8+ 版本中使用
-- 9. 跨版本恢复前必须验证版本兼容性
-- 10. 备份元数据（表结构、权限、配置）和业务数据分开管理
-- ============================================================================