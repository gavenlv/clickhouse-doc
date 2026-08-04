-- =====================================================
-- 01 - Keeper 内部原理
-- =====================================================
-- Keeper 是 ClickHouse 的分布式协调服务（替代 ZooKeeper）
-- 基于 Raft 共识协议实现高可用协调
-- 集群: treasurycluster (3 Keeper)
-- =====================================================

DROP DATABASE IF EXISTS distributed_test ON CLUSTER treasurycluster;
CREATE DATABASE IF NOT EXISTS distributed_test ON CLUSTER treasurycluster;
USE distributed_test;

-- ========================================
-- 【原理】Keeper 是什么
-- ========================================
-- Keeper 是 ClickHouse 内置的分布式协调服务，用 C++ 实现
-- 替代 ZooKeeper，使用 Raft 共识协议
--
-- Keeper 的职责:
--   - 管理 ReplicatedMergeTree 的复制日志
--   - 协调副本间的 Leader 选举
--   - 存储表元数据（schema、分区信息）
--   - 管理分布式 DDL 执行
--
-- Raft 协议三个角色:
--   - Leader: 处理所有写请求，管理日志复制
--   - Follower: 被动复制日志，处理读请求
--   - Candidate: 选举时的临时角色
--
-- Raft 写流程:
--   1. Client → Leader 提交写请求
--   2. Leader 追加日志条目 → 并行复制到 Followers
--   3. 多数 Followers 确认写入 → Leader 提交（commit）
--   4. Leader 响应 Client → 通知 Followers 提交
--
-- 为什么需要 3 个 Keeper 节点？
--   Raft 需要多数派（quorum = N/2 + 1）
--   3 节点: quorum = 2，可容忍 1 节点故障
--   5 节点: quorum = 3，可容忍 2 节点故障

-- -----------------------------------------------------
-- 1. 查看 Keeper 连接状态
-- -----------------------------------------------------
-- 【原理】system.zookeeper 表可以查询 Keeper 中的节点数据
-- 注意：虽然表名是 zookeeper，实际查询的是 Keeper（兼容 ZooKeeper API）

-- 查看 Keeper 根路径下的所有节点
SELECT * FROM system.zookeeper WHERE path = '/';

-- 查看 ClickHouse 在 Keeper 中注册的路径
SELECT * FROM system.zookeeper WHERE path = '/clickhouse';

-- 查看各表的 Keeper 路径
-- 如果存在复制表，会看到 /clickhouse/tables/{shard}/{table} 路径
-- 【兼容性】ClickHouse 25.12 起 system.zookeeper 查询必须带 path = / path IN 精确条件，否则 Code 36
SELECT * FROM system.zookeeper WHERE path IN ('/clickhouse/tables');

-- -----------------------------------------------------
-- 【原理】Raft Leader 选举
-- -----------------------------------------------------
-- Keeper 节点间通过 Raft 选举 Leader
-- 选举触发条件:
--   1. Follower 超过 election_timeout 未收到 Leader 心跳
--   2. 节点启动时
--   3. Leader 宕机
--
-- 选举过程:
--   1. Follower → Candidate（增加 term，发起投票）
--   2. Candidate 请求其他节点投票
--   3. 获得多数票（quorum）→ 成为 Leader
--   4. 新 Leader 发送心跳确立权威

-- 查看 Keeper 系统状态（通过 system.zookeeper 查询 Keeper 自身信息）
-- 【坑】Keeper 自身的状态信息不通过 system.zookeeper 暴露
-- 需要直接在 Keeper 节点上执行 clickhouse-keeper-client 命令
-- 例如: docker exec clickhouse-keeper-1 clickhouse-keeper-client -q "mntr"

-- 查看 Keeper 连接配置
SELECT 
    name,
    host,
    port
    -- 25.12 已移除 get_server_type() 函数，故不再输出服务端类型
FROM system.zookeeper_connection;

-- -----------------------------------------------------
-- 【原理】日志复制与日志压缩
-- -----------------------------------------------------
-- Raft 日志复制:
--   Leader 将 Client 请求追加到自己的日志中
--   然后将日志条目发送到所有 Follower
--   当多数节点确认写入后，Leader 提交该条目
--
-- 日志压缩:
--   Raft 日志会不断增长，Keeper 定期创建快照（snapshot）
--   快照包含当前状态机状态，压缩旧日志
--   新节点加入时，先拉取快照再追增量日志

-- 创建复制表来观察 Keeper 中的日志结构
CREATE TABLE IF NOT EXISTS keeper_demo_table ON CLUSTER treasurycluster
(
    event_id UInt64,
    event_time DateTime,
    event_type String,
    value Float64
)
ENGINE = ReplicatedMergeTree
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_time, event_id);

-- 插入一些数据触发 Keeper 日志写入
INSERT INTO keeper_demo_table VALUES
(1, '2024-01-15 10:00:00', 'click', 1.0),
(2, '2024-01-15 10:05:00', 'view', 0.5),
(3, '2024-01-15 10:10:00', 'purchase', 100.0),
(4, '2024-01-15 10:15:00', 'click', 2.0),
(5, '2024-01-15 10:20:00', 'view', 0.8);

-- 查看复制状态（依赖 Keeper 协调）
-- 【原理】system.replicas 的信息来自 Keeper 中的元数据
SELECT 
    database,
    table,
    replica_name,
    is_leader,
    can_become_leader,
    is_readonly,
    is_session_expired,
    absolute_delay,
    queue_size,
    inserts_in_queue,
    merges_in_queue,
    log_max_index,
    log_pointer
FROM system.replicas
WHERE table = 'keeper_demo_table';

-- 查看 keeper_demo_table 在 Keeper 中的实际节点（25.12 需精确 path）
SELECT * FROM system.zookeeper WHERE path IN ('/clickhouse/tables/1/keeper_demo_table');

-- -----------------------------------------------------
-- 【原理】Keeper 中复制表的路径结构
-- -----------------------------------------------------
-- 对于 ReplicatedMergeTree 表，Keeper 中的路径结构:
--
-- /clickhouse/tables/{shard}/{table}/
-- ├── replicas/
-- │   ├── {replica1}/
-- │   │   ├── host           ← 副本 host:port
-- │   │   ├── pointer        ← 当前消费到的 log 位置
-- │   │   ├── min_unprocessed_insert_time
-- │   │   └── queue/         ← 待处理任务
-- │   └── {replica2}/
-- ├── log/                    ← 操作日志序列
-- │   ├── log-0000000000
-- │   ├── log-0000000001
-- │   └── ...
-- ├── mutations/              ← Mutation 任务
-- ├── columns                 ← 表结构
-- ├── metadata                ← 引擎参数
-- └── block_numbers/          ← 块编号分配

-- 查看当前表的 Keeper 路径
SELECT 
    zookeeper_path,
    replica_path
FROM system.replicas
WHERE table = 'keeper_demo_table';

-- 查看 keeper_demo_table 在 Keeper 中的实际节点（25.12 需精确 path）
SELECT * FROM system.zookeeper WHERE path IN ('/clickhouse/tables/1/keeper_demo_table');

-- -----------------------------------------------------
-- 【原理】Keeper vs ZooKeeper 对比
-- -----------------------------------------------------
-- +------------------+------------------+------------------+
-- | 特性              | ZooKeeper        | ClickHouse Keeper|
-- +------------------+------------------+------------------+
-- | 语言              | Java             | C++              |
-- | 协议              | ZAB              | Raft             |
-- | 部署方式          | 独立 Java 进程    | 内置或独立进程    |
-- | 内存占用          | 高（Java JVM）    | 低（C++ 原生）    |
-- | 启动时间          | 30-60s           | 1-3s             |
-- | 快照              | 全量快照          | 增量快照          |
-- | 读性能            | 线性一致          | 线性一致          |
-- | 写性能            | 约 10K QPS       | 约 50K+ QPS      |
-- | 配置复杂度        | 复杂              | 简单              |
-- | 监控集成          | 需额外配置        | 内置 system 表    |
-- +------------------+------------------+------------------+
--
-- 【坑】虽然 Keeper 兼容 ZooKeeper API，但并非 100% 兼容
-- 一些 ZooKeeper 的高级特性（如 ACL 细粒度控制）可能不支持

-- 查看 Keeper 快照信息
-- 【原理】Keeper 定期将内存状态写入快照文件
-- 快照文件存储在 Keeper 数据目录的 snapshots/ 子目录中
-- 快照间隔由 keeper_server.snapshot_distance 控制（默认 10000 条日志）
SELECT 
    name,
    value
FROM system.zookeeper
WHERE path = '/clickhouse' AND name = 'keeper_version';

-- -----------------------------------------------------
-- 【原理】Keeper 配置优化
-- -----------------------------------------------------
-- 关键配置参数（在 keeper_config.xml 中设置）:
--
-- 1. session_timeout_ms: 会话超时（默认 10000ms）
--    如果网络不稳定，可以适当增大，避免频繁会话过期
--    建议: 30000-60000ms（生产环境）
--
-- 2. operation_timeout_ms: 操作超时（默认 10000ms）
--    Keeper 操作的超时时间
--
-- 3. snapshot_distance: 快照间隔（默认 10000）
--    每多少条日志触发一次快照
--    值越小，快照越频繁，恢复越快，但 I/O 开销越大
--    建议: 30000-50000（生产环境）
--
-- 4. dead_session_check_period_ms: 死会话检查周期（默认 500ms）
--    检查并清理过期会话
--
-- 5. raft_logs_level: Raft 日志级别
--    生产环境建议设为 warning，减少日志量
--
-- 6. auto_restart: 自动重启（默认 true）
--    遇到 fatal 错误时自动重启 Keeper 进程

-- 查看 Keeper 的 Raft 状态
-- 【原理】Keeper 用 Raft 共识协议，每个节点维护:
--   - current_term: 当前任期号
--   - voted_for: 当前任期投票给谁
--   - commit_index: 已提交的最大日志索引
--   - last_applied: 已应用到状态机的最大日志索引
SELECT 
    name,
    value
FROM system.zookeeper
WHERE path = '/clickhouse/tables/1/keeper_demo_table/replicas';

-- -----------------------------------------------------
-- 【场景】Keeper 故障对集群的影响
-- -----------------------------------------------------
-- +------------------+------------------+------------------+
-- | Keeper 状态      | 3 节点集群影响    | 5 节点集群影响    |
-- +------------------+------------------+------------------+
-- | 全部正常          | 正常              | 正常              |
-- | 1 节点宕机        | 无影响            | 无影响            |
-- | 2 节点宕机        | 写入停止          | 无影响            |
-- | 3 节点宕机        | 写入停止          | 写入停止          |
-- | 全部宕机          | 数据可查不可写    | 数据可查不可写    |
-- +------------------+------------------+------------------+
--
-- 【坑】Keeper 宕机超过多数派时，复制表变为只读
-- 但已落盘的数据仍然可查询，数据不会丢失
-- Keeper 恢复后，复制队列自动继续

-- 查看 Keeper 的可用性信息
SELECT 
    hostName() AS host,
    (SELECT count() FROM system.zookeeper_connection) AS keeper_connections;

-- -----------------------------------------------------
-- 【对比】Keeper 内置 vs 独立部署
-- -----------------------------------------------------
-- 内置部署（本集群采用）:
--   优点: 部署简单，资源共用
--   缺点: Keeper 与 ClickHouse 争抢 CPU/内存/磁盘 I/O
--
-- 独立部署:
--   优点: 资源隔离，稳定性更好
--   缺点: 需要额外维护 Keeper 集群
--
-- 生产建议:
--   - 小规模集群（< 10 节点）: 内置部署即可
--   - 大规模集群（> 10 节点）: 建议独立部署
--   - 使用 SSD: Keeper 对磁盘 I/O 延迟敏感

-- -----------------------------------------------------
-- 【坑】Keeper 常见问题
-- -----------------------------------------------------
-- 1. "Keeper 和 ZooKeeper 完全一样"
--    实际: API 兼容但实现不同，某些 ZooKeeper 特性不支持
--    （如递归 ACL、多 ephemeal 节点）
--
-- 2. "Keeper 快照越频繁越好"
--    实际: 快照频繁会增加 I/O 开销，影响写入性能
--    建议: 30000-50000 条日志一次快照
--
-- 3. "Keeper 内存不重要"
--    实际: Keeper 把所有数据加载到内存，内存不足会导致 OOM
--    建议: 每个 Keeper 节点至少 4GB 内存
--
-- 4. "Keeper 可以跨地域部署"
--    实际: Raft 对网络延迟敏感，跨地域部署会导致频繁选举
--    建议: 同机房部署，延迟 < 10ms

-- -----------------------------------------------------
-- 清理
-- -----------------------------------------------------
DROP TABLE IF EXISTS keeper_demo_table ON CLUSTER treasurycluster SYNC;

-- 与开头 ON CLUSTER 建库对应，DROP 也须 ON CLUSTER
DROP DATABASE IF EXISTS distributed_test ON CLUSTER treasurycluster;