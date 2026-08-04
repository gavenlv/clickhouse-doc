-- =====================================================
-- 07 - 升级故障排查
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

-- -----------------------------------------------------
-- 1. 版本兼容
-- -----------------------------------------------------

--
-- 【原理】ClickHouse 采用滚动升级策略，但跨大版本升级（如从 v21.x 到 v23.x）
-- 可能存在元数据格式、数据存储格式、网络协议、SQL 语法等方面的不兼容变更。
-- 每个版本发布时会在 CHANGELOG 中标注 Backward Incompatible Change。升级前
-- 未检查兼容性说明可能导致升级后服务无法启动或查询报错。
--
-- 【场景】
--   - 升级后部分节点无法启动
--   - 升级后集群间通信失败（协议版本不匹配）
--   - 升级后某些查询报错 "Unknown function"
--   - 升级后某些表无法读取（数据格式变更）
--   - 升级后配置项报 "Unknown configuration parameter"
--
-- 版本兼容性建议:
--   v20.x -> v21.x: 需要迁移 ZK 路径
--   v21.x -> v22.x: 存储格式变更（需验证）
--   v22.x -> v23.x: 配置项大量废弃
--   v23.x -> v24.x: 主要兼容，部分默认值变更
--

-- 诊断：检查当前版本
SELECT
    version() AS current_version,
    uptime() AS uptime_seconds,
    timezone() AS server_timezone;

-- 诊断：检查集群中所有节点的版本
SELECT
    hostname,
    version(),
    uptime()
FROM system.clusters
WHERE cluster = 'treasurycluster';

-- 诊断：检查当前版本的关键配置
SELECT
    name,
    value,
    default,
    changed,
    description
FROM system.settings
WHERE changed = 1
ORDER BY name;

-- 修复：升级前记录当前配置
-- SELECT * FROM system.settings WHERE changed = 1
-- INTO OUTFILE '/tmp/current_settings_before_upgrade.tsv';

-- 修复：升级前检查不兼容变更
-- 1. 查阅 CHANGELOG 中的 Backward Incompatible Change 部分
-- 2. 检查废弃的配置项
-- 3. 检查 SQL 语法变更
-- 4. 检查数据格式变更

-- 修复：升级策略
-- 1. 先升级非关键节点进行验证
-- 2. 每次升级一个节点，观察运行状态
-- 3. 使用 SYSTEM RELOAD CONFIG 热加载配置变更
-- 4. 确认无误后再升级其他节点

-- -----------------------------------------------------
-- 2. 数据格式变更
-- -----------------------------------------------------

--
-- 【原理】ClickHouse 在版本升级时可能引入新的数据存储格式，包括主键索引格式、
-- 列式存储格式、标记文件格式、校验和算法等。当新版本读取旧版本写入的数据时，
-- 可能触发格式不兼容错误。ClickHouse 通常提供向后兼容的读取能力，但写入
-- 格式会立即采用新版本格式。
--
-- 【场景】
--   - 升级后读取旧数据报错 "Cannot read compressed data"
--   - 升级后报错 "Unknown data format version"
--   - 升级后报错 "Checksum mismatch"（校验算法变更）
--   - 升级后部分表无法 ATTACH
--   - 旧备份无法恢复到新版本
--

-- 诊断：检查表的存储格式版本
SELECT
    database,
    table,
    engine,
    metadata_version,
    format_version
FROM system.tables
WHERE database NOT IN ('system', 'INFORMATION_SCHEMA');

-- 诊断：检查数据格式相关事件
SELECT
    event,
    value,
    description
FROM system.events
WHERE event LIKE '%Format%'
   OR event LIKE '%Version%'
ORDER BY event;

-- 修复：使用 OPTIMIZE TABLE 升级数据格式
-- 新版本读取旧数据时，通过 OPTIMIZE 可以触发数据重写
OPTIMIZE TABLE troubleshooting_test.sample_table FINAL;

-- 修复：使用 ALTER TABLE MODIFY 迁移数据格式
-- ALTER TABLE troubleshooting_test.sample_table
--     MODIFY COLUMN column_name NEW_TYPE;

-- 修复：显式重写数据
-- 1. 创建新表
-- CREATE TABLE sample_table_new AS sample_table
-- ENGINE = ReplicatedMergeTree(...);
-- 2. 拷贝数据
-- INSERT INTO sample_table_new SELECT * FROM sample_table;
-- 3. 替换表
-- RENAME TABLE sample_table TO sample_table_old,
--              sample_table_new TO sample_table;

-- 修复：处理旧备份恢复
-- 使用旧版本导出数据，新版本导入:
-- clickhouse-client --query "SELECT * FROM table FORMAT Native" > data.native
-- # 在新版本中导入
-- clickhouse-client --query "INSERT INTO table FORMAT Native" < data.native

-- -----------------------------------------------------
-- 3. 配置项废弃
-- -----------------------------------------------------

--
-- 【原理】ClickHouse 每个大版本都会废弃（deprecate）一些旧的配置项，并在后续
-- 版本中移除。废弃的配置项在升级后可能：被忽略（无报错）、触发警告日志、
-- 或导致启动失败。常见的配置变更包括：配置项重命名、默认值变更、配置项
-- 合并/拆分、配置项从 server 迁移到 query level。
--
-- 【场景】
--   - 启动日志报 "WARNING: Deprecated setting"
--   - 启动日志报 "Unknown setting"（配置项已被移除）
--   - 升级后行为与预期不符（默认值已变更）
--   - 配置热加载后报 "No such configuration"
--   - 某些配置项在新版本中不再生效
--

-- 诊断：检查废弃配置警告
SELECT
    event_time,
    level,
    logger_name,
    message
FROM system.text_log
WHERE message LIKE '%deprecated%'
   OR message LIKE '%Deprecated%'
   OR message LIKE '%unknown setting%'
   OR message LIKE '%removed%'
ORDER BY event_time DESC
LIMIT 20;

-- 诊断：检查当前所有已修改的配置
SELECT
    name,
    value,
    default,
    changed,
    description
FROM system.settings
WHERE changed = 1
ORDER BY name;

-- 修复：替换废弃的配置项
-- 常见配置项变更对照表:
-- 旧配置名                             | 新配置名 / 说明
-- -------------------------------------|-------------------------------
-- max_memory_usage                    | 仍有效但建议使用 max_memory_usage_for_all_queries
-- max_concurrent_queries_for_all_users | 合并为 max_concurrent_queries
-- background_pool_size                | 拆分为 background_merges_mutations_concurrency_ratio
-- max_partitions_per_insert_block     | 建议使用 max_partitions_to_write
-- compile                              | 已废弃，使用 JIT 编译
-- min_count_to_compile                | 已废弃
-- max_network_bandwidth               | 拆分为多个限速配置
-- max_network_bytes                   | 拆分为多个限速配置
-- max_query_size                      | 仍有效，但最小值和最大值有调整
-- max_parser_depth                    | 仍有效，但默认值有调整

-- 修复：使用配置检查工具
-- clickhouse-server --config-file /etc/clickhouse-server/config.xml --check

-- 修复：查看配置变更日志
-- clickhouse-server --config-file /etc/clickhouse-server/config.xml --print
-- 对比新旧版本的配置差异

-- 修复：使用新版本推荐的配置方式
-- 在 config.xml 中使用 <merge_tree> 替代旧版本中分散的合并配置
-- <merge_tree>
--     <max_bytes_to_merge_at_max_space_in_pool>10737418240</max_bytes_to_merge_at_max_space_in_pool>
--     <max_bytes_to_merge_at_min_space_in_pool>1048576</max_bytes_to_merge_at_min_space_in_pool>
--     <max_parts_in_total>100000</max_parts_in_total>
-- </merge_tree>

-- -----------------------------------------------------
-- 4. 回滚方案
-- -----------------------------------------------------

--
-- 【原理】升级失败时需要回滚到旧版本，回滚过程需要保证数据的一致性和完整性。
-- ClickHouse 的数据格式在升级后可能被新版本修改，导致旧版本无法读取。因此
-- 回滚前必须确保数据格式兼容，或提前备份数据目录。回滚的关键步骤包括：
-- 停止新版本运行、恢复旧版本二进制文件、恢复旧版本配置文件、检查数据兼容性。
--
-- 【场景】
--   - 升级后查询报错，需要立即恢复
--   - 升级后性能大幅下降
--   - 升级后部分功能不可用
--   - 升级后集群无法形成 quorum
--   - 升级后发现内存泄漏或 CPU 异常
--

-- 修复：升级前的准备工作
-- 1. 备份配置文件
--    cp -r /etc/clickhouse-server /etc/clickhouse-server.backup-$(date +%Y%m%d)
-- 2. 备份数据目录元数据
--    clickhouse-client --query "SELECT create_table_query FROM system.tables
--        WHERE database NOT IN ('system', 'INFORMATION_SCHEMA')
--        FORMAT TabSeparated" > /tmp/table_definitions.sql
-- 3. 记录当前版本
--    clickhouse-client --query "SELECT version()" > /tmp/version_before_upgrade.txt

-- 修复：回滚步骤
-- 1. 停止 ClickHouse 服务
--    systemctl stop clickhouse-server
-- 2. 恢复旧版本二进制文件
--    dpkg -i clickhouse-server_old.deb
--    dpkg -i clickhouse-common_old.deb
-- 3. 恢复配置文件
--    cp /etc/clickhouse-server.backup-$(date +%Y%m%d)/* /etc/clickhouse-server/
-- 4. 检查数据兼容性
--    clickhouse-server --config-file /etc/clickhouse-server/config.xml --check
-- 5. 启动服务
--    systemctl start clickhouse-server
-- 6. 验证数据完整性
--    clickhouse-client --query "SELECT count() FROM system.tables"

-- 修复：数据格式不兼容时的回滚
-- 如果新版本修改了数据格式导致旧版本无法读取:
-- 1. 在新版本中导出数据
--    clickhouse-client --query "SELECT * FROM table FORMAT Native" > /tmp/table_data.native
-- 2. 回滚到旧版本
-- 3. 创建相同结构的表
-- 4. 导入数据
--    clickhouse-client --query "INSERT INTO table FORMAT Native" < /tmp/table_data.native

-- 修复：使用快照恢复
-- 如果使用 LVM/云盘快照:
-- 1. 卸载数据目录
--    umount /var/lib/clickhouse
-- 2. 恢复快照
--    lvconvert --merge /dev/snap/clickhouse
-- 3. 重新挂载
--    mount /var/lib/clickhouse
-- 4. 启动服务

-- 修复：Docker 回滚
-- docker-compose down
-- # 修改 image 标签为旧版本
-- # docker-compose.yml 中修改 image: clickhouse/clickhouse-server:旧版本
-- docker-compose up -d

-- 修复：验证回滚成功
SELECT
    version() AS current_version,
    count() AS table_count
FROM system.tables
WHERE database NOT IN ('system', 'INFORMATION_SCHEMA');

-- -----------------------------------------------------
-- 清理测试环境
-- -----------------------------------------------------

DROP DATABASE IF EXISTS troubleshooting_test;

-- =====================================================
-- 附：升级故障排查速查表
-- =====================================================
--
-- 症状                    | 诊断命令                  | 修复方法
-- ------------------------|---------------------------|---------------------------
-- 版本不兼容              | SELECT version()          | 检查 CHANGELOG / 逐版本升级
-- 数据格式不兼容          | system.tables.format_version | OPTIMIZE TABLE / 重写数据
-- 配置项废弃              | system.text_log (deprecated) | 替换为新配置项 / 删除废弃项
-- 升级后无法启动          | 查看 error log            | 回滚版本 / 恢复配置备份
-- 升级后性能下降          | system.query_log          | 检查默认值变更 / 调整配置
-- 回滚后数据不可读        | 旧版本无法启动            | 在新版本中导出再导入
--
-- =====================================================