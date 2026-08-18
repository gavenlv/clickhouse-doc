-- =====================================================
-- 08 - 数据一致性排查
-- =====================================================
-- 集群: treasurycluster (2副本)
-- 时间: 20-30分钟
-- =====================================================

-- -----------------------------------------------------
-- 准备环境
-- -----------------------------------------------------

DROP DATABASE IF EXISTS troubleshooting_test;
CREATE DATABASE troubleshooting_test;
USE troubleshooting_test;

-- 创建演示表（用于 CHECK TABLE 校验和检查与分区修复演示）
-- 【注意】PARTITION BY toYYYYMM(event_date) 的分区 ID 是 '202401' 形式
DROP TABLE IF EXISTS troubleshooting_test.sample_table;
CREATE TABLE troubleshooting_test.sample_table
(
    id UInt32,
    event_date Date,
    value String
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_date)
ORDER BY id;

INSERT INTO troubleshooting_test.sample_table
SELECT number, toDate('2024-01-01') + number % 90, concat('data', toString(number))
FROM numbers(1000);

-- -----------------------------------------------------
-- 1. 主从数据不一致
-- -----------------------------------------------------

--
-- 【原理】ClickHouse 的 ReplicatedMergeTree 使用最终一致性模型，数据在副本
-- 间异步复制。主从数据不一致可能由以下原因引起：网络分区导致部分复制操作
-- 失败、ZK 事务冲突、数据写入时部分副本不可用、异步插入未同步、手动操作
-- 部分副本（如直接 DETACH/ATTACH）等。不一致的表现包括：不同副本查询返回
-- 不同行数、同一条记录的聚合值不同、分区数量不一致。
--
-- 【场景】
--   - 不同副本查询相同 SQL 返回不同结果
--   - 各副本 system.replicas 中 parts_to_check > 0
--   - 副本间分区数量不一致
--   - 报错 "Part ... from ... is not intersecting with ..."
--   - 报错 "Part ... already exists but with different checksums"
--

-- 诊断：检查各副本的数据行数
-- 在集群中每个副本上执行:
SELECT
    database,
    table,
    count() AS row_count,
    formatReadableSize(sum(bytes_on_disk)) AS total_size
FROM system.parts
WHERE active = 1
  AND database NOT IN ('system', 'INFORMATION_SCHEMA')
GROUP BY database, table
ORDER BY database, table;

-- 诊断：检查各副本的分区数量
SELECT
    database,
    table,
    partition_id,
    count() AS part_count,
    sum(rows) AS total_rows
FROM system.parts
WHERE active = 1
  AND database NOT IN ('system', 'INFORMATION_SCHEMA')
GROUP BY database, table, partition_id
ORDER BY database, table, partition_id;

-- 诊断：检查需要校验的 part
SELECT
    database,
    table,
    replica_name,
    parts_to_check
FROM system.replicas
WHERE parts_to_check > 0;

-- 诊断：检查副本间差异
-- 使用 system.replicas 对比各副本状态
-- 【坑】25.12 的 system.replicas 没有 zombie_parts 列（该列已在旧版本移除），
--       差异判断改用 parts_to_check + log_lag
SELECT
    database,
    table,
    replica_name,
    is_leader,
    is_readonly,
    absolute_delay,
    queue_size,
    parts_to_check,
    log_max_index,
    log_pointer,
    (log_max_index - log_pointer) AS log_lag
FROM system.replicas
ORDER BY database, table, replica_name;

-- -----------------------------------------------------
-- 2. 校验 Checksum
-- -----------------------------------------------------

--
-- 【原理】ClickHouse 的每个数据 part 都包含校验和文件（checksums.txt），
-- 记录所有列数据文件、索引文件、标记文件的哈希值。校验和机制用于检测数据
-- 在存储或传输过程中是否损坏。CHECK TABLE 语句会扫描表的所有 part，重新
-- 计算校验和并与存储的校验和进行比对。自动校验机制在后台定期执行，也可
-- 手动触发。
--
-- 【场景】
--   - 需要验证主从副本数据一致性
--   - 怀疑磁盘静默数据损坏
--   - 迁移数据后需要验证完整性
--   - 备份恢复后需要确认数据无误
--   - 定期巡检需要数据一致性报告
--
-- 校验方式说明:
--   CHECK TABLE: 快速校验，检查文件校验和
--   CHECK TABLE ... PARTITION: 指定分区校验
--   CHECK TABLE ... AS OF: 检查某个时间点的快照
--   system.checksums: 全局校验和视图
--

-- 诊断：使用 CHECK TABLE 进行数据完整性检查
CHECK TABLE troubleshooting_test.sample_table;

-- 诊断：校验指定分区
CHECK TABLE troubleshooting_test.sample_table
    PARTITION '202401';

-- 诊断：使用 system.checksums 查看全局校验和
-- 【坑】CH 25.x 已移除 system.checksums 系统表，
--       校验和检查统一使用 CHECK TABLE（见上）与 system.parts（file_checksum 等）
SELECT
    database,
    table,
    partition_id,
    rows,
    bytes_on_disk
FROM system.parts
WHERE database = 'troubleshooting_test'
  AND active = 1
LIMIT 20;

-- 诊断：使用 RAID 级别的校验
-- 在 shell 中执行:
-- 1. 计算数据目录的 MD5 快照
--    find /var/lib/clickhouse/data -type f -name "*.bin" | xargs md5sum > /tmp/checksums_before.txt
-- 2. 在另一个副本上执行相同操作
-- 3. 对比两个校验和文件
--    diff /tmp/checksums_before.txt /tmp/checksums_after.txt

-- 修复：手动触发数据校验和一致性检查
-- 【坑】SYSTEM SYNC REPLICA 仅对 ReplicatedMergeTree 生效，非复制表（MergeTree）会报
--       "Table is not replicated"（BAD_ARGUMENTS）。以下命令在复制表上执行：
-- SYSTEM SYNC REPLICA <replicated_table>;

-- 修复：重建校验和文件
-- 通过 DETACH + ATTACH 触发校验和重建
ALTER TABLE troubleshooting_test.sample_table
    DETACH PARTITION '202401';

ALTER TABLE troubleshooting_test.sample_table
    ATTACH PARTITION '202401';

-- 修复：使用 REPAIR TABLE 修复损坏
-- REPAIR TABLE troubleshooting_test.sample_table;

-- 修复：使用 FETCH PARTITION 从正确副本拉取
-- 在需要修复的副本上执行:
-- ALTER TABLE troubleshooting_test.sample_table
--     FETCH PARTITION '2024-01' FROM '/clickhouse/tables/...';

-- -----------------------------------------------------
-- 3. 修复手段
-- -----------------------------------------------------

--
-- 【原理】数据一致性修复需要根据不一致的严重程度和影响范围选择合适手段。
-- 修复方法从轻到重包括：同步复制队列、重新拉取分区、重建校验和、手动
-- 创建删除分区、重建表。修复过程中应避免写入操作，防止不一致扩大。
--
-- 【场景】
--   - 副本间数据差异较小（少量分区不一致）
--   - 副本间数据差异较大（大量分区不一致）
--   - 部分副本完全损坏需要重建
--   - 修复后需要验证一致性
--   - 修复过程中需要最小化业务影响
--

-- 修复方法 1：同步复制队列（轻度不一致）
-- 仅 ReplicatedMergeTree 可用，非复制表（本演示 MergeTree）无需同步：
-- SYSTEM SYNC REPLICA <replicated_table>;

-- 修复方法 2：重启复制
-- 仅 ReplicatedMergeTree 可用（本演示表为 MergeTree，注释说明）：
-- SYSTEM RESTART REPLICA <replicated_table>;

-- 修复方法 3：重新拉取特定分区
-- 在不同的副本上对比数据后，找到正确的副本，在错误副本上:
-- ALTER TABLE troubleshooting_test.sample_table
--     FETCH PARTITION '2024-01' FROM '/clickhouse/tables/...';
-- 然后 ATTACH:
-- ALTER TABLE troubleshooting_test.sample_table
--     ATTACH PARTITION '202401';

-- 修复方法 4：DROP 后重新创建分区
-- 在错误副本上:
-- ALTER TABLE troubleshooting_test.sample_table
--     DROP PARTITION '202401';
-- -- 等待复制队列自动拉取

-- 修复方法 5：DETACH + ATTACH 重建
ALTER TABLE troubleshooting_test.sample_table
    DETACH PARTITION '202401';

ALTER TABLE troubleshooting_test.sample_table
    ATTACH PARTITION '202401';

-- 修复方法 6：使用 MUTATION 修复数据
-- ALTER TABLE troubleshooting_test.sample_table
--     UPDATE column_name = correct_value
--     WHERE condition;

-- 修复方法 7：全量重建（严重不一致，最后手段）
-- 1. 在所有副本上 DETACH TABLE
-- 2. 删除 ZK 中的复制路径
-- 3. 在其中一个副本上 ATTACH TABLE（作为主副本）
-- 4. 在其他副本上 ATTACH TABLE（自动从主副本复制）
-- 注意：此操作会丢失主副本中未同步到 ZK 的数据

-- 修复方法 8：使用零拷贝复制（Zero-Copy Replication）
-- 零拷贝复制通过共享存储避免重复拷贝，减少不一致风险
-- 需要在 config.xml 中配置:
-- <zero_copy_replication>
--     <zero_copy_replication_enabled>true</zero_copy_replication_enabled>
-- </zero_copy_replication>

-- 修复方法 9：使用一致性检查工具
-- 在 shell 中编写脚本，对比两个副本的数据:
-- clickhouse-client --host replica1 --query "SELECT * FROM table ORDER BY pk" > /tmp/replica1.tsv
-- clickhouse-client --host replica2 --query "SELECT * FROM table ORDER BY pk" > /tmp/replica2.tsv
-- diff /tmp/replica1.tsv /tmp/replica2.tsv

-- 修复方法 10：使用增量校验
-- 通过对比聚合值快速发现不一致:
SELECT
    database,
    table,
    count() AS row_count,
    uniqCombined(partition_id) AS partition_count,
    sum(rows) AS total_rows
FROM system.parts
WHERE active = 1
  AND database NOT IN ('system', 'INFORMATION_SCHEMA')
GROUP BY database, table;

-- 修复后验证：检查复制状态
SELECT
    database,
    table,
    replica_name,
    absolute_delay,
    is_readonly,
    is_session_expired,
    parts_to_check,
    queue_size
FROM system.replicas
WHERE database = 'troubleshooting_test';

-- 修复后验证：检查数据行数
SELECT
    database,
    table,
    count() AS row_count
FROM system.parts
WHERE active = 1
  AND database = 'troubleshooting_test'
GROUP BY database, table;

-- 修复后验证：执行 CHECK TABLE 确认
CHECK TABLE troubleshooting_test.sample_table;

-- -----------------------------------------------------
-- 清理测试环境
-- -----------------------------------------------------

DROP DATABASE IF EXISTS troubleshooting_test;

-- =====================================================
-- 附：数据一致性排查速查表
-- =====================================================
--
-- 症状                    | 诊断命令                  | 修复方法
-- ------------------------|---------------------------|---------------------------
-- 副本间行数不一致        | system.parts (GROUP BY)   | SYSTEM SYNC REPLICA
-- 校验和不匹配            | CHECK TABLE               | DETACH + ATTACH 重建
-- 分区数量不一致          | system.replicas           | FETCH PARTITION
-- 部分副本损坏            | system.replicas.is_readonly | 重建副本 / 全量同步
-- 复制队列卡住            | system.replication_queue  | SYSTEM RESTART REPLICA
-- 需要定期验证            | 自定义校验脚本            | 对比 checksum / 行数
--
-- =====================================================