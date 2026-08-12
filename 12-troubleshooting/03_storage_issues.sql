-- =====================================================
-- 03 - 存储故障排查
-- =====================================================
-- 集群: treasurycluster (2副本)
-- 时间: 10-15分钟
-- =====================================================

-- -----------------------------------------------------
-- 准备环境
-- -----------------------------------------------------

DROP DATABASE IF EXISTS troubleshooting_test;
CREATE DATABASE troubleshooting_test;
USE troubleshooting_test;

-- 前置：创建示例表（幂等，保证文件可独立运行）
CREATE TABLE troubleshooting_test.sample_table
(
    event_date Date,
    event_time DateTime,
    user_id UInt32,
    amount Decimal(18, 2),
    raw_text String
)
ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_date)
ORDER BY (event_date, user_id);

INSERT INTO troubleshooting_test.sample_table
SELECT
    toDate('2024-01-15'),
    toDateTime('2024-01-15 10:00:00'),
    number,
    number / 100,
    concat('text_', toString(number))
FROM numbers(1000);

-- 前置：备份表（用于演示从备份表恢复分区）
CREATE TABLE troubleshooting_test.sample_table_archive
(
    event_date Date,
    event_time DateTime,
    user_id UInt32,
    amount Decimal(18, 2),
    raw_text String
)
ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_date)
ORDER BY (event_date, user_id);

INSERT INTO troubleshooting_test.sample_table_archive
SELECT
    toDate('2024-01-20'),
    toDateTime('2024-01-20 10:00:00'),
    number,
    number / 100,
    concat('archive_', toString(number))
FROM numbers(1000);

-- -----------------------------------------------------
-- 1. 磁盘空间不足
-- -----------------------------------------------------

--
-- 【原理】ClickHouse 写入采用追加写 + 后台合并模式，数据先写入临时目录再合并到
-- 正式分区目录。磁盘空间不足时，写入操作会失败，合并任务也会中止。默认配置下，
-- 磁盘使用率超过 90% 时 ClickHouse 会主动暂停后台合并和写入。
--
-- 【场景】
--   - INSERT 报错 "No space left on device"
--   - 后台日志出现 "Cannot reserve enough disk space"
--   - 查询性能莫名下降（因合并停滞导致 part 数膨胀）
--   - 系统表 system.disks 显示 free_space 接近 0
--
-- 关键配置参数:
--   max_volume_space_ratio: 磁盘空间使用率上限（默认 0.9）
--   move_factor: 自动迁移阈值（默认 0.1）
--   storage_policy: 多卷存储策略
--

-- 诊断：检查磁盘使用情况
SELECT
    name,
    path,
    formatReadableSize(total_space) AS total,
    formatReadableSize(free_space) AS free,
    formatReadableSize(total_space - free_space) AS used,
    round(100 - (free_space / total_space) * 100, 2) AS used_pct,
    keep_free_space,
    type
FROM system.disks;

-- 诊断：检查各表的存储分布
SELECT
    database,
    table,
    count() AS part_count,
    formatReadableSize(sum(bytes_on_disk)) AS total_size,
    formatReadableSize(min(bytes_on_disk)) AS min_part_size,
    formatReadableSize(max(bytes_on_disk)) AS max_part_size
FROM system.parts
WHERE active = 1
GROUP BY database, table
ORDER BY sum(bytes_on_disk) DESC;

-- 诊断：检查存储策略配置
SELECT
    policy_name,
    volume_name,
    disks,
    max_data_part_size,
    move_factor,
    prefer_not_to_merge
FROM system.storage_policies;

-- 修复：清理过期数据（TTL）
-- [需外部依赖] 分层存储需在 config.xml 中配置 cold_disk，此处演示 TTL 到期自动清理语法
ALTER TABLE troubleshooting_test.sample_table
    MODIFY TTL event_date + INTERVAL 30 DAY;

-- 修复：清理孤立分区文件
SELECT
    database,
    table,
    count() AS orphan_parts
FROM system.parts
WHERE active = 0
  AND modification_time < now() - INTERVAL 7 DAY
GROUP BY database, table;

-- 修复：强制合并以释放空间
OPTIMIZE TABLE troubleshooting_test.sample_table FINAL;

-- 修复：对过期分区执行 DROP
-- 注意：toYYYYMM 产生的分区名形如 '202401'，而非 '2024-01'
ALTER TABLE troubleshooting_test.sample_table
    DROP PARTITION '202401';

-- 修复：使用 FREEZE 备份后清理
ALTER TABLE troubleshooting_test.sample_table
    FREEZE WITH NAME 'backup_2024';

-- 修复：删除 detached 分区中的残留
-- 注：FREEZE 生成的 shadow/backup_2024 备份需手工复制回 detached/ 后才能 ATTACH；
-- ATTACH PARTITION FROM 仅支持从表恢复，此处用备份表演示
ALTER TABLE troubleshooting_test.sample_table
    ATTACH PARTITION '202401' FROM troubleshooting_test.sample_table_archive;

-- 修复：配置存储策略实现分层存储
-- 示例存储策略（需在 config.xml 中配置）:
-- <storage_policies>
--     <hot_cold>
--         <volumes>
--             <hot>
--                 <disk>hot_disk</disk>
--                 <max_data_part_size>1073741824</max_data_part_size>
--             </hot>
--             <cold>
--                 <disk>cold_disk</disk>
--             </cold>
--         </volumes>
--         <move_factor>0.1</move_factor>
--     </hot_cold>
-- </storage_policies>

-- -----------------------------------------------------
-- 2. Part 损坏
-- -----------------------------------------------------

--
-- 【原理】ClickHouse 的 part 是数据存储的最小单元，每个 part 包含主键索引、
-- 列数据文件（.bin）、标记文件（.mrk）和校验和文件。当写入过程中节点宕机、
-- 磁盘故障或文件系统异常时，可能导致 part 文件损坏。损坏的 part 在读取时会
-- 触发校验和错误（Code: 40）。
--
-- 【场景】
--   - SELECT 报错 "Checksum mismatch" 或 "Checksum doesn't match"
--   - SELECT 报错 "Cannot read compressed data"
--   - 系统表 system.parts 中某 part 的 path 指向不存在的文件
--   - 后台日志出现 "Bad checksum" 或 "Corrupted partition"
--
-- 【对比】
--   - v21.x: 校验和错误仅记录日志，需手动修复
--   - v22.3+: 引入自动检测和部分修复能力
--   - v23.8+: 新增 CHECK TABLE 语句主动校验
--   - v24.x: 支持在线修复损坏 part（无需停服）
--

-- 诊断：检查是否有损坏的 part
SELECT
    database,
    table,
    name AS part_name,
    partition_id,
    rows,
    bytes_on_disk,
    modification_time,
    path
FROM system.parts
WHERE active = 1
  AND bytes_on_disk = 0;

-- 诊断：使用 CHECK TABLE 检查数据完整性
CHECK TABLE troubleshooting_test.sample_table;

-- 诊断：检查校验和错误日志
SELECT
    event_time,
    level,
    logger_name,
    message
FROM system.text_log
WHERE message LIKE '%checksum%'
   OR message LIKE '%Checksum%'
   OR message LIKE '%corrupted%'
   OR message LIKE '%Corrupted%'
ORDER BY event_time DESC
LIMIT 20;

-- 修复：DETACH 损坏的 part
ALTER TABLE troubleshooting_test.sample_table
    DETACH PARTITION '202401';

-- 修复：从副本恢复（如果有 ReplicatedMergeTree）
-- 在副本节点上执行:
-- ALTER TABLE troubleshooting_test.sample_table
--     FETCH PARTITION '202401' FROM 'zookeeper_path';

-- 修复：如果无副本，尝试 ATTACH 回 detached 的 part
ALTER TABLE troubleshooting_test.sample_table
    ATTACH PARTITION '202401';

-- 修复：重建表（最后手段）
-- 1. 创建新表
-- CREATE TABLE sample_table_new AS sample_table;
-- 2. 迁移数据
-- INSERT INTO sample_table_new SELECT * FROM sample_table;
-- 3. 替换表
-- RENAME TABLE sample_table TO sample_table_bak,
--              sample_table_new TO sample_table;
-- 4. 验证数据
-- SELECT count() FROM sample_table;

-- -----------------------------------------------------
-- 3. 压缩问题
-- -----------------------------------------------------

--
-- 【原理】ClickHouse 支持多种压缩算法（LZ4、ZSTD、Delta、DoubleDelta、Gorilla）。
-- 压缩在列级别进行，每列可独立设置压缩算法。压缩问题通常表现为空间膨胀比不
-- 达标（压缩比低于预期），或压缩/解压性能异常。
--
-- 【场景】
--   - 数据量远大于预期（压缩比 < 2）
--   - 写入时 CPU 高（ZSTD 压缩级别过高）
--   - 读取时延迟高（解压成为瓶颈）
--   - 压缩比与其他节点差异大
--
-- 常见压缩算法对比:
--   LZ4:        速度快，压缩比 2-4x，适合 OLAP 高频读取
--   ZSTD:       压缩比高 3-8x，CPU 开销大，适合冷数据
--   Delta:      适合数值型递增序列（时间戳、ID）
--   DoubleDelta:适合慢变化数值序列
--   Gorilla:    适合浮点型时序数据
--
-- 【对比】
--   - v20.x: 默认 LZ4，不支持列级压缩配置
--   - v21.3+: 支持列级 CODEC 配置
--   - v22.8+: 新增 ZSTD 压缩级别动态调整
--   - v23.7+: 支持自适应压缩算法选择
--

-- 诊断：检查各表的压缩算法和压缩比
SELECT
    database,
    table,
    name AS column_name,
    type,
    compression_codec,
    formatReadableSize(data_compressed_bytes) AS compressed,
    formatReadableSize(data_uncompressed_bytes) AS uncompressed,
    round(data_uncompressed_bytes / data_compressed_bytes, 2) AS ratio
FROM system.columns
WHERE database NOT IN ('system', 'INFORMATION_SCHEMA')
  AND data_compressed_bytes > 0
ORDER BY data_uncompressed_bytes / data_compressed_bytes ASC
LIMIT 50;

-- 诊断：检查压缩事件统计
SELECT
    event,
    value,
    description
FROM system.events
WHERE event LIKE '%Compress%'
   OR event LIKE '%Decompress%'
ORDER BY event;

-- 修复：创建表时指定压缩算法
CREATE TABLE troubleshooting_test.sample_compressed
(
    event_time DateTime,
    user_id UInt32,
    metric_value Float64 CODEC(Gorilla, LZ4),
    raw_text String CODEC(ZSTD(3)),
    counter Int64 CODEC(Delta(4), LZ4),
    timestamp_ns Int64 CODEC(DoubleDelta, LZ4)
)
ENGINE = MergeTree()
ORDER BY event_time;

-- 修复：修改已有列的压缩算法
ALTER TABLE troubleshooting_test.sample_table
    MODIFY COLUMN raw_text CODEC(ZSTD(5));

-- 修复：使用 ZSTD 时选择合适的压缩级别
-- 级别 1-3: 快速压缩，适合实时写入
-- 级别 4-6: 平衡模式，适合大多数场景
-- 级别 7-9: 高压缩比，适合冷数据归档
-- 级别 10-22: 极高压缩比，CPU 开销大，不推荐 OLTP 场景

-- -----------------------------------------------------
-- 4. 数据目录结构问题
-- -----------------------------------------------------

--
-- 【原理】ClickHouse 数据目录包含多个子目录，各自承担不同角色：
--   data/      - 实际数据存储
--   metadata/  - 表结构定义（*.sql）
--   store/     - 扁平化数据存储（v22.x+ 默认）
--   detached/  - 被分离的分区
--   shadow/    - ALTER FREEZE 备份目录
--   tmp/       - 临时写入缓冲区
--   tmp_<UUID>/ - 异步插入临时文件
--
-- 【场景】
--   - 启动报错 "Cannot create directory"
--   - 数据目录结构损坏导致表无法加载
--   - metadata 与 data 不一致
--   - store/ 目录下有大量临时文件
--

-- 诊断：检查 metadata 目录中的表定义
SELECT
    database,
    name,
    engine,
    metadata_modification_time,
    create_table_query
FROM system.tables
WHERE database NOT IN ('system', 'INFORMATION_SCHEMA');

-- 诊断：检查 detached 分区状态
-- 注：25.12 的 system.detached_parts 无 detach_time 字段，用 modification_time 近似
SELECT
    database,
    table,
    count() AS detached_parts,
    min(modification_time) AS earliest_detach,
    max(modification_time) AS latest_detach
FROM system.detached_parts
GROUP BY database, table
ORDER BY count() DESC;

-- 诊断：检查临时文件残留
-- 在 shell 中执行:
-- ls -la /var/lib/clickhouse/tmp/
-- find /var/lib/clickhouse/store/ -name "*.tmp" -mtime +1
-- du -sh /var/lib/clickhouse/shadow/

-- 修复：清理过期 detached 分区
ALTER TABLE troubleshooting_test.sample_table
    DROP DETACHED PARTITION '202401' SETTINGS allow_drop_detached = 1;

-- 修复：重新挂载 detached 分区
ALTER TABLE troubleshooting_test.sample_table
    ATTACH PARTITION '202401';

-- 修复：重建元数据（metadata 丢失时）
-- 1. 从 store/ 目录恢复：
--    touch /var/lib/clickhouse/metadata/<database>/<table>.sql
-- 2. 执行 DETACH TABLE / ATTACH TABLE
-- 3. 如果 metadata 完全丢失，使用 ATTACH TABLE 从 data 目录恢复

-- 修复：清理过期的 shadow 备份
-- 在 shell 中执行:
-- rm -rf /var/lib/clickhouse/shadow/backup_*

-- -----------------------------------------------------
-- 清理测试环境
-- -----------------------------------------------------

DROP DATABASE IF EXISTS troubleshooting_test;

-- =====================================================
-- 附：存储故障排查速查表
-- =====================================================
--
-- 症状                    | 诊断命令                                          | 修复方法
-- ------------------------|---------------------------------------------------|---------------------------
-- 写入失败，磁盘空间不足  | system.disks                                     | 清理 TTL / 扩容 / 分层存储
-- 查询报错 Checksum mismatch | CHECK TABLE / system.text_log                  | DETACH + ATTACH / 从副本恢复
-- 压缩比异常低            | system.columns (ratio)                           | 修改 CODEC / 重写数据
-- Part 数膨胀             | system.parts (GROUP BY table)                     | OPTIMIZE TABLE ... FINAL
-- detached 分区堆积       | system.detached_parts                            | ATTACH / DROP DETACHED
-- metadata 损坏           | system.tables (create_table_query)                | 重建 .sql 文件 + ATTACH
-- 临时文件残留            | 检查 tmp/ 和 store/ 目录                          | 清理过期临时文件
-- 存储策略配置错误        | system.storage_policies                           | 修改 config.xml 并重启
--
-- =====================================================