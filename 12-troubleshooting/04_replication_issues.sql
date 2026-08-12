-- =====================================================
-- 04 - 复制故障排查
-- =====================================================
-- 集群: treasurycluster (2副本)
-- 时间: 15-20分钟
-- =====================================================

-- -----------------------------------------------------
-- 准备环境
-- -----------------------------------------------------

DROP DATABASE IF EXISTS troubleshooting_test;
CREATE DATABASE troubleshooting_test;
USE troubleshooting_test;

-- 前置：创建复制表示例（幂等，保证文件可独立运行）
CREATE TABLE troubleshooting_test.sample_table
(
    event_date Date,
    user_id UInt32,
    amount Float64
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/troubleshooting_test/sample_table', '{replica}')
PARTITION BY toYYYYMM(event_date)
ORDER BY (event_date, user_id);

INSERT INTO troubleshooting_test.sample_table
SELECT toDate('2024-01-15'), number, number / 100
FROM numbers(1000);

-- -----------------------------------------------------
-- 1. 副本滞后
-- -----------------------------------------------------

--
-- 【原理】ClickHouse 复制基于 Shared-Nothing 架构，数据通过 ZooKeeper/ClickHouse
-- Keeper 协调，以日志复制方式在副本间同步。每个副本独立拉取 ZK 中的日志条目
-- 并回放。副本滞后是指从副本的同步进度落后于主副本，可能由网络延迟、磁盘 IO
-- 瓶颈、回放线程不足或大事务阻塞引起。
--
-- 【场景】
--   - 查询不同副本返回不同结果（最终一致性窗口内）
--   - system.replicas 表中 absolute_delay 持续增大
--   - 从副本查询返回陈旧数据
--   - 主副本写入正常，从副本数据不更新
--
-- 关键监控指标:
--   absolute_delay: 当前副本落后主副本的秒数
--   queue_size:     复制队列中待处理的条目数
--   inserts_in_queue: 待插入的块数
--   log_max_index / log_pointer: 日志位置差距
--
-- 【对比】
--   - v21.x: 复制基于 ZK 实现，延迟敏感
--   - v22.3+: 引入 ClickHouse Keeper（自研替代 ZK），延迟降低 50%
--   - v23.3+: 支持并行回放，提升复制吞吐量
--   - v24.x: 支持多线程复制（parallel_replicas）
--

-- 诊断：检查所有副本的延迟状态
SELECT
    database,
    table,
    replica_name,
    absolute_delay,
    queue_size,
    inserts_in_queue,
    merges_in_queue,
    log_max_index,
    log_pointer,
    is_leader,
    is_readonly,
    is_session_expired,
    future_parts,
    parts_to_check
FROM system.replicas
ORDER BY absolute_delay DESC;

-- 诊断：检查复制队列详情
-- 注：25.12 的 system.replicas 列名为 inserts_oldest_time / oldest_part_to_merge_to / oldest_part_to_mutate_to
SELECT
    database,
    table,
    replica_name,
    queue_size,
    inserts_in_queue,
    merges_in_queue,
    part_mutations_in_queue,
    queue_oldest_time,
    inserts_oldest_time,
    oldest_part_to_merge_to,
    oldest_part_to_mutate_to
FROM system.replicas
WHERE queue_size > 0
   OR inserts_in_queue > 0
ORDER BY queue_size DESC;

-- 诊断：检查复制队列趋势（过去 1 小时）
-- 注：25.12 的 system.replication_queue 无 event_time / absolute_delay 列，改用 create_time 统计
SELECT
    toStartOfMinute(create_time) AS minute,
    count() AS new_tasks,
    countIf(is_currently_executing = 1) AS running_tasks
FROM system.replication_queue
WHERE create_time > now() - INTERVAL 1 HOUR
GROUP BY minute
ORDER BY minute DESC;

-- 修复：增加后台回放线程数
-- 在 config.xml 中配置:
-- <background_schedule_pool_size>256</background_schedule_pool_size>
-- <background_fetches_pool_size>16</background_fetches_pool_size>

-- 修复：手动触发复制
SYSTEM SYNC REPLICA troubleshooting_test.sample_table;

-- 修复：重启复制队列
-- 注：25.12 语法为 STOP/START REPLICATION QUEUES（SYSTEM STOP REPLICAS 已废弃）
SYSTEM STOP REPLICATION QUEUES;
SYSTEM START REPLICATION QUEUES;

-- 修复：在从副本上重新拉取数据
SYSTEM RESTART REPLICA troubleshooting_test.sample_table;

-- 修复：如果延迟持续增大，检查网络带宽和磁盘 IO
-- 使用以下查询监控副本间的网络流量:
SELECT
    event,
    value,
    description
FROM system.events
WHERE event LIKE 'Network%'
   OR event LIKE 'RemoteRead%'
   OR event LIKE 'RemoteWrite%';

-- -----------------------------------------------------
-- 2. ZK/Keeper 连接问题
-- -----------------------------------------------------

--
-- 【原理】ClickHouse 复制依赖外部协调服务（ZooKeeper 或 ClickHouse Keeper）。
-- 当协调服务不可达或会话过期时，复制功能会暂停。ZK 连接问题通常表现为会话
-- 超时、事务超时或节点数不足。
--
-- 【场景】
--   - system.replicas 中 is_session_expired = 1
--   - 日志报错 "KeeperErrorCode = Session expired"
--   - 日志报错 "Connection loss" / "Connection refused"
--   - 写入失败，报错 "Cannot push block to ZooKeeper"
--   - 集群中部分节点标记为 readonly
--

-- 诊断：检查 ZK 连接状态
-- 注：25.12 的 system.zookeeper_connection 无 value 字段，直接展示各 keeper 连接信息
SELECT
    name,
    host,
    port,
    index AS conn_index,
    connected_time,
    session_uptime_elapsed_seconds,
    is_expired,
    keeper_api_version,
    client_id,
    xid,
    session_timeout_ms
FROM system.zookeeper_connection
ORDER BY host;

-- 诊断：检查 ZK 会话指标
SELECT
    event,
    value,
    description
FROM system.events
WHERE event LIKE '%ZooKeeper%'
   OR event LIKE '%Keeper%'
ORDER BY event;

-- 诊断：检查 ZK 读延迟
SELECT
    name,
    value
FROM system.asynchronous_metrics
WHERE name LIKE '%Keeper%'
   OR name LIKE '%ZooKeeper%'
ORDER BY name;

-- 诊断：检查 system.zookeeper 路径是否存在
SELECT
    path,
    name,
    value
FROM system.zookeeper
WHERE path = '/clickhouse/tables/{shard}/{table}'
LIMIT 10;

-- 修复：重启 ClickHouse Keeper 服务
-- systemctl restart clickhouse-keeper

-- 修复：在 config.xml 中调整 ZK 会话超时
-- <zookeeper>
--     <session_timeout_ms>30000</session_timeout_ms>
--     <operation_timeout_ms>10000</operation_timeout_ms>
--     <node>
--         <host>zk1</host>
--         <port>2181</port>
--     </node>
-- </zookeeper>

-- 修复：使用 ClickHouse Keeper 替代 ZooKeeper（推荐）
-- 配置示例:
-- <keeper_server>
--     <tcp_port>9181</tcp_port>
--     <server_id>1</server_id>
--     <log_storage_path>/var/lib/clickhouse-keeper/log</log_storage_path>
--     <snapshot_storage_path>/var/lib/clickhouse-keeper/snapshots</snapshot_storage_path>
--     <coordination_settings>
--         <operation_timeout_ms>10000</operation_timeout_ms>
--         <session_timeout_ms>30000</session_timeout_ms>
--         <raft_logs_level>information</raft_logs_level>
--     </coordination_settings>
--     <raft_configuration>
--         <server>
--             <id>1</id>
--             <hostname>node1</hostname>
--             <port>9234</port>
--         </server>
--     </raft_configuration>
-- </keeper_server>

-- -----------------------------------------------------
-- 3. 复制队列卡住
-- -----------------------------------------------------

--
-- 【原理】复制队列是每个副本上维护的任务队列，包含 INSERT、MERGE、MUTATION、
-- ALTER 等操作。当某个操作卡住（如依赖的 part 不存在、数据损坏或 ZK 节点
-- 状态异常），会导致后续任务全部阻塞，形成队列积压。
--
-- 【场景】
--   - system.replication_queue 中有大量 status = 'pending' 或 'running' 的条目
--   - 队列中最早的条目长时间未完成（> 1 小时）
--   - 副本写入和查询均正常，但数据不更新
--   - 重启副本后队列仍然卡住
--

-- 诊断：查看复制队列状态
-- 注：25.12 的 system.replication_queue 无 parts_to_detach / parts_to_active 列
SELECT
    database,
    table,
    replica_name,
    position,
    node_name,
    type,
    source_replica,
    new_part_name,
    parts_to_merge,
    is_detach,
    create_time,
    required_quorum,
    is_currently_executing,
    num_tries,
    last_exception,
    last_attempt_time,
    last_exception_time
FROM system.replication_queue
ORDER BY create_time ASC;

-- 诊断：查看卡住任务的异常信息
SELECT
    database,
    table,
    replica_name,
    type,
    create_time,
    num_tries,
    last_exception,
    last_exception_time
FROM system.replication_queue
WHERE last_exception != ''
ORDER BY last_exception_time DESC
LIMIT 20;

-- 诊断：查看复制队列统计
-- 注：25.12 的 system.replication_queue 无 status 列，用 is_currently_executing 区分执行状态
SELECT
    database,
    table,
    count() AS total_tasks,
    countIf(is_currently_executing = 1) AS running,
    countIf(is_currently_executing = 0) AS waiting,
    countIf(num_tries > 0) AS retried_tasks,
    max(create_time) AS latest_task
FROM system.replication_queue
GROUP BY database, table;

-- 修复：跳过卡住的任务（谨慎使用）
-- ALTER TABLE troubleshooting_test.sample_table
--     MODIFY SETTING replication_alter_partitions_sync = 0;

-- 修复：手动移除卡住的任务
-- SYSTEM DROP REPLICA QUEUE 'task_name' FROM ZK PATH '/clickhouse/tables/...';

-- 修复：重启复制
SYSTEM RESTART REPLICA troubleshooting_test.sample_table;

-- 修复：如果上述方法无效，尝试 DETACH TABLE 后重新 ATTACH
-- DETACH TABLE troubleshooting_test.sample_table;
-- ATTACH TABLE troubleshooting_test.sample_table;

-- 修复：最后手段 - 删除并重建复制元数据
-- 1. 在所有副本上执行 DETACH TABLE
-- 2. 在 ZK 中删除复制路径
-- 3. 在所有副本上执行 ATTACH TABLE
-- 注意：此操作会丢失未同步的数据

-- -----------------------------------------------------
-- 4. 裂脑（Split Brain）
-- -----------------------------------------------------

--
-- 【原理】裂脑是指复制组中出现多个主副本同时接受写入的情况，通常由网络分区
-- 导致。当网络恢复后，各副本的数据分歧无法自动合并，导致数据不一致。ClickHouse
-- 的 ReplicatedMergeTree 通过 ZK/Keeper 的多节点选举机制（Raft/Paxos）来防止
-- 裂脑，但配置不当（如 ZK 仲裁数不足）仍可能发生。
--
-- 【场景】
--   - 两个副本都认为自己是 leader（is_leader = 1）
--   - 同一分区的数据在副本间不一致
--   - ZK 中同一路径下出现多个冲突的节点
--   - 复制报错 "Logical error: there is no part"
--

-- 诊断：检查 leader 状态
SELECT
    database,
    table,
    replica_name,
    is_leader,
    is_readonly,
    is_session_expired,
    absolute_delay,
    zookeeper_path,
    replica_path
FROM system.replicas
ORDER BY database, table;

-- 诊断：检查 ZK 中的复制元数据
SELECT
    path,
    name,
    value
FROM system.zookeeper
WHERE path LIKE '/clickhouse/tables/%'
  AND name IN ('leader', 'lost_part_count', 'zero_copy_part_count')
ORDER BY path;

-- 修复：设置明确的 leader 优先级
-- ALTER TABLE troubleshooting_test.sample_table
--     MODIFY SETTING replication_leader_priority = 10;

-- 修复：强制指定主副本
-- 在非主副本上执行:
-- SYSTEM RESTART REPLICA troubleshooting_test.sample_table;

-- 修复：在 ZK 中手动修复裂脑
-- 1. 确定正确的副本
-- 2. 删除 ZK 中错误的副本路径
--    rmr /clickhouse/tables/{shard}/{table}/replicas/{wrong_replica}
-- 3. 在错误副本上重新创建复制条目
--    SYSTEM RESTART REPLICA troubleshooting_test.sample_table;

-- 修复：预防裂脑的最佳实践
-- 1. 确保 ZK/Keeper 集群节点数 >= 3
-- 2. 配置合理的 ZK 会话超时（30-60 秒）
-- 3. 使用 ClickHouse Keeper 内置的 Raft 共识
-- 4. 设置 max_interserver_network_traffic 限制

-- -----------------------------------------------------
-- 清理测试环境
-- -----------------------------------------------------

DROP DATABASE IF EXISTS troubleshooting_test;

-- =====================================================
-- 附：复制故障排查速查表
-- =====================================================
--
-- 症状                    | 诊断命令                  | 修复方法
-- ------------------------|---------------------------|---------------------------
-- 副本延迟高              | system.replicas           | 增加回放线程 / 优化网络
-- ZK 会话过期             | system.zookeeper_connection | 调整 session_timeout / 重启 Keeper
-- 复制队列卡住            | system.replication_queue  | SYSTEM RESTART REPLICA
-- 多 leader（裂脑）       | system.replicas.is_leader | 移除错误副本路径
-- 复制报错 no part        | system.replication_queue  | DETACH + ATTACH 重建
-- 副本只读                | system.replicas.is_readonly | 恢复 ZK 连接 / 修复磁盘
--
-- =====================================================