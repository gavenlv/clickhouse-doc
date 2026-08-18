-- =====================================================
-- 06 - 启动故障排查
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

-- -----------------------------------------------------
-- 1. 配置错误
-- -----------------------------------------------------

--
-- 【原理】ClickHouse 启动时会加载 config.xml 和 users.xml 等配置文件。配置
-- 错误是启动失败的最常见原因，包括：XML 格式错误、关键配置项缺失、配置值
-- 类型错误、配置路径错误、引用了不存在的文件或目录等。ClickHouse 在配置
-- 加载阶段会进行语法校验和配置项检查，任何错误都会导致启动中止。
--
-- 【场景】
--   - 启动后进程立即退出
--   - 日志报错 "Cannot parse XML" / "Config error"
--   - 日志报错 "Unknown configuration parameter"
--   - 日志报错 "No <yandex> or <clickhouse> tag"
--   - 配置热加载后服务异常
--

-- 诊断：检查配置加载状态
SELECT
    name,
    value,
    changed,
    description,
    min,
    max,
    type
FROM system.settings
WHERE changed = 1
ORDER BY name;

-- 诊断：检查配置文件的合并结果
-- 在 shell 中执行:
-- clickhouse-server --config-file /etc/clickhouse-server/config.xml --check
-- clickhouse-server --config-file /etc/clickhouse-server/users.xml --check

-- 诊断：检查配置文件的引入链
-- ClickHouse 支持通过 <include> 引入外部配置，常见的配置引入:
--   config.xml -> config.d/*.xml
--   users.xml  -> users.d/*.xml
--   metrika.xml -> 集群配置
-- 检查每个引入文件是否存在且格式正确

-- 修复：验证配置文件语法
-- 使用 clickhouse-server 的检查模式:
-- clickhouse-server --config-file /etc/clickhouse-server/config.xml --check

-- 修复：检查配置项的正确格式
-- 常见配置错误:
-- ❌ <max_memory_usage>8G</max_memory_usage>  -- 不支持单位后缀
-- ✅ <max_memory_usage>8000000000</max_memory_usage>
--
-- ❌ <listen_host>0.0.0.0</listen_host> 在 XML 中缺少引号
-- ✅ <listen_host>0.0.0.0</listen_host>

-- 修复：使用配置模板生成配置
-- clickhouse-server --config-file /etc/clickhouse-server/config.xml --print

-- 修复：检查配置文件的权限
-- ls -la /etc/clickhouse-server/config.xml
-- 应确保 clickhouse 用户可读（通常为 644）

-- -----------------------------------------------------
-- 2. 端口冲突
-- -----------------------------------------------------

--
-- 【原理】ClickHouse 默认监听多个端口（TCP 9000, HTTP 8123, 集群间通信 9009,
-- MySQL 兼容 9004, PostgreSQL 兼容 9005, Keeper 9181 等）。当这些端口已被
-- 其他进程占用时，ClickHouse 将无法启动。端口冲突通常发生在同一主机上部署
-- 多个 ClickHouse 实例或其他服务使用相同端口的情况下。
--
-- 【场景】
--   - 日志报错 "Cannot listen on port"
--   - 日志报错 "Address already in use"
--   - 日志报错 "Cannot bind to port"
--   - 启动后部分端口监听失败
--   - 使用 docker 时端口映射冲突
--

-- 诊断：检查端口占用情况
-- 在 shell 中执行:
-- netstat -tlnp | grep -E '(9000|8123|9004|9005|9009|9181)'
-- lsof -i :9000
-- ss -tlnp | grep clickhouse

-- 诊断：检查 ClickHouse 当前监听的端口
SELECT
    name,
    value,
    description
FROM system.settings
WHERE name LIKE '%port%'
   OR name LIKE '%tcp%'
   OR name LIKE '%http%';

-- 修复：修改端口配置
-- 在 config.xml 中:
-- <tcp_port>9001</tcp_port>          -- 修改 TCP 端口
-- <http_port>8124</http_port>        -- 修改 HTTP 端口
-- <interserver_http_port>9010</interserver_http_port>  -- 修改集群通信端口
-- <mysql_port>9006</mysql_port>      -- 修改 MySQL 兼容端口
-- <postgresql_port>9007</postgresql_port>  -- 修改 PostgreSQL 兼容端口

-- 修复：设置端口重用（避免 TIME_WAIT 问题）
-- 在 config.xml 中:
-- <listen_reuse_port>1</listen_reuse_port>

-- 修复：指定监听地址
-- 在 config.xml 中:
-- <listen_host>0.0.0.0</listen_host>  -- 监听所有接口
-- <listen_host>::</listen_host>        -- 监听 IPv6
-- <listen_host>127.0.0.1</listen_host>  -- 仅本地

-- 修复：使用 docker 时映射不同端口
-- docker run -p 9001:9000 -p 8124:8123 ...

-- -----------------------------------------------------
-- 3. 数据目录权限
-- -----------------------------------------------------

--
-- 【原理】ClickHouse 运行时需要对数据目录、日志目录、临时目录等进行读写操作。
-- 数据目录权限问题通常由以下原因引起：以非 clickhouse 用户运行进程、目录
-- 所有者变更、SELinux/AppArmor 限制、文件系统只读、磁盘故障导致目录不可写。
--
-- 【场景】
--   - 日志报错 "Cannot create directory"
--   - 日志报错 "Permission denied"
--   - 日志报错 "Cannot open file"
--   - 数据目录不存在
--   - 系统启动后自动停止
--

-- 诊断：检查数据目录状态
SELECT
    name,
    path,
    formatReadableSize(total_space) AS total,
    formatReadableSize(free_space) AS free,
    type,
    keep_free_space
FROM system.disks;

-- 诊断：检查 directory_monitor 监控
SELECT
    event,
    value,
    description
FROM system.events
WHERE event LIKE '%Directory%'
   OR event LIKE '%FileOpen%';

-- 修复：设置正确的目录权限
-- 在 shell 中执行:
-- chown -R clickhouse:clickhouse /var/lib/clickhouse
-- chown -R clickhouse:clickhouse /var/log/clickhouse-server
-- chmod 755 /var/lib/clickhouse
-- chmod 755 /var/log/clickhouse-server

-- 修复：创建缺失的目录
-- mkdir -p /var/lib/clickhouse/{data,metadata,store,tmp}
-- mkdir -p /var/log/clickhouse-server
-- chown -R clickhouse:clickhouse /var/lib/clickhouse /var/log/clickhouse-server

-- 修复：检查 SELinux 状态
-- getenforce
-- 如果 SELinux 为 Enforcing，添加策略:
-- semanage fcontext -a -t clickhouse_var_lib_t '/var/lib/clickhouse(/.*)?'
-- restorecon -Rv /var/lib/clickhouse

-- 修复：检查文件系统是否只读
-- mount | grep /var/lib/clickhouse
-- 如果显示 ro，则重新挂载为读写:
-- mount -o remount,rw /var/lib/clickhouse

-- 修复：配置数据目录路径
-- 在 config.xml 中:
-- <path>/var/lib/clickhouse/</path>
-- <tmp_path>/var/lib/clickhouse/tmp/</tmp_path>
-- <user_files_path>/var/lib/clickhouse/user_files/</user_files_path>
-- <format_schema_path>/var/lib/clickhouse/format_schemas/</format_schema_path>

-- -----------------------------------------------------
-- 4. Keeper 无法启动
-- -----------------------------------------------------

--
-- 【原理】ClickHouse Keeper 是一个基于 Raft 共识算法的分布式协调服务，可替代
-- ZooKeeper。Keeper 启动失败通常由 Raft 配置错误、快照损坏、日志文件损坏、
-- 集群成员变更冲突、端口冲突、磁盘空间不足等原因引起。Keeper 在启动时会
-- 回放预写日志（WAL）并加载快照，任何文件损坏都会导致启动中止。
--
-- 【场景】
--   - Keeper 进程启动后反复重启
--   - 日志报错 "Raft protocol error"
--   - 日志报错 "Cannot read snapshot"
--   - 日志报错 "Cannot join Raft cluster"
--   - 日志报错 "Not enough voters"
--   - 集群中 Keeper 节点无法形成 quorum
--

-- 诊断：检查 Keeper 状态（通过 system.zookeeper_connection）
-- 【坑】25.12 的 system.zookeeper_connection 没有 value/description 列，
--       连接信息字段为 host/port/session_timeout_ms/is_expired 等
SELECT
    name,
    host,
    port,
    is_expired,
    session_timeout_ms,
    last_zxid_seen
FROM system.zookeeper_connection;

-- 诊断：检查 Keeper 相关事件
SELECT
    event,
    value,
    description
FROM system.events
WHERE event LIKE '%Keeper%'
ORDER BY event;

-- 修复：检查 Keeper 配置
-- 在 config.xml 中:
-- <keeper_server>
--     <tcp_port>9181</tcp_port>
--     <server_id>1</server_id>
--     <log_storage_path>/var/lib/clickhouse-keeper/log</log_storage_path>
--     <snapshot_storage_path>/var/lib/clickhouse-keeper/snapshots</snapshot_storage_path>
-- </keeper_server>

-- 修复：检查 Raft 配置
-- 确保所有 Keeper 节点的 <raft_configuration> 一致:
-- <raft_configuration>
--     <server>
--         <id>1</id>
--         <hostname>node1</hostname>
--         <port>9234</port>
--     </server>
--     <server>
--         <id>2</id>
--         <hostname>node2</hostname>
--         <port>9234</port>
--     </server>
--     <server>
--         <id>3</id>
--         <hostname>node3</hostname>
--         <port>9234</port>
--     </server>
-- </raft_configuration>

-- 修复：清理损坏的 Keeper 快照和日志（最后手段）
-- 1. 停止 Keeper 服务
--    systemctl stop clickhouse-keeper
-- 2. 备份当前的日志和快照
--    mv /var/lib/clickhouse-keeper/log /var/lib/clickhouse-keeper/log.bak
--    mv /var/lib/clickhouse-keeper/snapshots /var/lib/clickhouse-keeper/snapshots.bak
-- 3. 创建空目录
--    mkdir -p /var/lib/clickhouse-keeper/log
--    mkdir -p /var/lib/clickhouse-keeper/snapshots
-- 4. 重新启动 Keeper
--    systemctl start clickhouse-keeper
-- 注意：此操作会丢失 Keeper 中的全部元数据，需要重新同步全部复制表

-- 修复：调整 Keeper 协调参数
-- 在 config.xml 中:
-- <coordination_settings>
--     <operation_timeout_ms>10000</operation_timeout_ms>
--     <session_timeout_ms>30000</session_timeout_ms>
--     <raft_logs_level>information</raft_logs_level>
--     <snapshot_distance>100000</snapshot_distance>
--     <heart_beat_interval_ms>1000</heart_beat_interval_ms>
--     <election_timeout_lower_bound_ms>3000</election_timeout_lower_bound_ms>
--     <election_timeout_upper_bound_ms>5000</election_timeout_upper_bound_ms>
-- </coordination_settings>

-- 修复：Keeper 无法形成 quorum 的排查
-- 1. 检查网络连通性
--    telnet node2 9234
-- 2. 检查防火墙规则
-- 3. 确保 server_id 在集群中唯一
-- 4. 确保节点数量为奇数（3, 5, 7...）
-- 5. 检查磁盘空间（Keeper 需要至少 1GB 可用空间）

-- -----------------------------------------------------
-- 清理测试环境
-- -----------------------------------------------------

DROP DATABASE IF EXISTS troubleshooting_test;

-- =====================================================
-- 附：启动故障排查速查表
-- =====================================================
--
-- 症状                    | 诊断命令                  | 修复方法
-- ------------------------|---------------------------|---------------------------
-- 配置解析错误            | clickhouse --check        | 修复 XML 格式 / 配置路径
-- 端口冲突                | netstat -tlnp             | 修改端口配置 / 停止冲突进程
-- 权限不足                | ls -la /var/lib/clickhouse | chown clickhouse:clickhouse
-- 目录不存在              | system.disks              | mkdir + chown
-- Keeper 无法启动         | system.zookeeper_connection | 检查 Raft 配置 / 清理快照
-- Keeper 无 quorum        | 检查网络和防火墙          | 调整选举超时 / 恢复节点
-- SELinux 阻止            | getenforce                | 添加策略或设置为 Permissive
--
-- =====================================================