-- =====================================================
-- 02 - 复制决策
-- =====================================================
-- ReplicatedMergeTree 复制机制深度解析
-- 复制队列监控、Quorum 强一致配置、选型决策
-- 集群: treasurycluster (2 副本 × 1 分片)
-- =====================================================

DROP DATABASE IF EXISTS distributed_test;
CREATE DATABASE distributed_test;
USE distributed_test;

-- ========================================
-- 【原理】ReplicatedMergeTree 复制机制
-- ========================================
-- ReplicatedMergeTree 不是直接在节点间复制数据文件
-- 而是通过 Keeper 协调，异步复制 Part 元数据
--
-- INSERT 复制流程:
--   1. 写入接收副本 → 本地写入 Part 文件
--   2. 接收副本在 Keeper 创建 log 条目
--   3. 返回 Client 成功（不等其他副本）
--   4. 其他副本监听到 log 变化 → 拉取 Part 文件
--   5. 校验 Part 哈希 → 注册到本地表
--
-- Merge 协调流程:
--   1. 任一副本发现需要 Merge → 在 Keeper 写 Merge 任务
--   2. 所有副本读取任务 → 各自本地执行相同 Merge
--   3. 结果: 所有副本产生相同的新 Part

-- -----------------------------------------------------
-- 1. 创建复制表
-- -----------------------------------------------------
-- 【原理】ReplicatedMergeTree 需要两个参数:
--   1. Keeper 路径: 所有副本使用相同路径
--   2. 副本名: 每个副本必须唯一
--
-- 使用宏 {shard}/{replica} 自动替换:
--   clickhouse1: shard=1, replica=1
--   clickhouse2: shard=1, replica=2

CREATE TABLE IF NOT EXISTS replication_test ON CLUSTER treasurycluster
(
    id UInt64,
    user_id UInt32,
    event_time DateTime,
    amount Float64,
    status String
)
ENGINE = ReplicatedMergeTree
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_time, id);

-- 查看副本注册信息
-- 【原理】system.replicas 显示每个副本在 Keeper 中的状态
SELECT 
    database,
    table,
    replica_name,
    zookeeper_path,
    replica_path,
    is_leader,
    can_become_leader,
    is_readonly,
    is_session_expired,
    total_replicas,
    active_replicas
FROM system.replicas
WHERE table = 'replication_test';

-- -----------------------------------------------------
-- 2. 复制队列监控
-- -----------------------------------------------------
-- 【原理】system.replication_queue 显示每个副本的待处理任务
-- 任务类型:
--   - INSERT: 从其他副本拉取新 Part
--   - MERGE: 本地合并 Part
--   - MUTATION: 执行 ALTER 操作

-- 插入测试数据
INSERT INTO replication_test VALUES
(1, 101, '2024-01-15 10:00:00', 99.99, 'pending'),
(2, 102, '2024-01-15 10:05:00', 49.99, 'completed'),
(3, 103, '2024-01-15 10:10:00', 199.99, 'pending'),
(4, 104, '2024-01-15 10:15:00', 299.99, 'completed'),
(5, 105, '2024-01-15 10:20:00', 149.99, 'cancelled');

-- 查看复制队列
-- 【坑】队列通常很短，大部分时间为空
-- 如果队列持续不为空，说明复制延迟
SELECT 
    database,
    table,
    replica_name,
    type,
    create_time,
    num_tries,
    last_exception,
    is_currently_executing
FROM system.replication_queue
WHERE table = 'replication_test'
ORDER BY create_time;

-- 查看复制延迟
-- 【原理】absolute_delay 是核心健康指标
--   0 = 已同步
--   > 0 = 落后秒数
SELECT 
    database,
    table,
    replica_name,
    absolute_delay,
    queue_size,
    inserts_in_queue,
    merges_in_queue,
    part_mutations_in_queue,
    last_queue_update
FROM system.replicas
WHERE table = 'replication_test';

-- -----------------------------------------------------
-- 3. 查看副本间的数据一致性
-- -----------------------------------------------------
-- 【原理】在分布式环境下，不同副本的数据可能短暂不一致
-- 使用 clusterAllReplicas 可以查看所有副本的数据

-- 查看各副本的数据量
SELECT 
    hostName() AS host,
    count() AS row_count,
    sum(amount) AS total_amount
FROM clusterAllReplicas(treasurycluster, distributed_test.replication_test)
GROUP BY host
ORDER BY host;

-- 查看各副本的数据差异
-- 【坑】如果副本间数据不一致，说明存在复制延迟
SELECT 
    hostName() AS host,
    id,
    user_id,
    amount,
    status
FROM clusterAllReplicas(treasurycluster, distributed_test.replication_test)
ORDER BY id, host;

-- -----------------------------------------------------
-- 【原理】Quorum 强一致配置
-- -----------------------------------------------------
-- 默认异步复制: 写入 1 副本即返回成功
-- Quorum 写入: 要求写入到 N 个副本后才返回成功
--
-- insert_quorum = N:
--   - 写入必须等 N 个副本确认
--   - 代价: 延迟增加（等最慢副本）
--   - 收益: 防单副本故障丢数据
--
-- select_sequential_consistency = 1:
--   - 查询前检查副本是否已同步到最新
--   - 代价: 每次 SELECT 多一次 Keeper 查询
--   - 收益: 保证读到最新已确认写入

-- 设置 Quorum 写入
-- 【场景】对一致性要求高的场景（如金融对账）
SET insert_quorum = 2;
SET insert_quorum_timeout = 60000;

-- 插入数据（需要等两个副本都确认）
INSERT INTO replication_test VALUES
(6, 106, '2024-01-16 10:00:00', 399.99, 'pending'),
(7, 107, '2024-01-16 10:05:00', 59.99, 'completed');

-- 设置强一致读
SET select_sequential_consistency = 1;

-- 查询（确保读到最新已确认数据）
SELECT count() AS total_rows FROM replication_test;

-- 恢复默认设置
SET insert_quorum = 0;
SET select_sequential_consistency = 0;

-- -----------------------------------------------------
-- 【对比】Quorum 配置的代价对比
-- -----------------------------------------------------
-- +-------------------+------------------+------------------+
-- | 维度               | 默认异步          | Quorum=2         |
-- +-------------------+------------------+------------------+
-- | 写入延迟           | 低（毫秒级）      | 高（受最慢副本影响）|
-- | 写入吞吐           | 高                | 中-低             |
-- | 一致性             | 最终一致          | 写入多数派一致    |
-- | 可用性             | 高（单副本可写）  | 中（需多数副本在线）|
-- | 适用场景           | 90% 场景          | 金融对账、审计    |
-- +-------------------+------------------+------------------+
--
-- 【坑】insert_quorum = 副本数 并非最安全
-- 例如 2 副本集群设 insert_quorum = 2:
--   任一副本宕机 → 所有写入失败
-- 更合理的做法: insert_quorum = 副本数 - 1

-- -----------------------------------------------------
-- 【对比】复制表 vs 非复制表选型决策
-- -----------------------------------------------------
-- +------------------+------------------+------------------+
-- | 决策因素          | 复制表           | 非复制表         |
-- +------------------+------------------+------------------+
-- | 高可用要求        | 必选              | 不可接受数据丢失  |
-- | 数据重要性        | 核心业务数据      | 临时/测试数据     |
-- | 写入性能          | 稍慢（Keeper 开销）| 更快              |
-- | 查询性能          | 相同              | 相同              |
-- | 存储成本          | 更高（N 副本 × N）| 更低              |
-- | 运维复杂度        | 更高              | 更低              |
-- | Keeper 依赖       | 必须              | 不需要            |
-- +------------------+------------------+------------------+
--
-- 选型规则:
--   1. 生产环境: 所有核心表用 ReplicatedMergeTree
--   2. 测试/临时表: 可以用 MergeTree（但注意单点故障风险）
--   3. 日志/可重算数据: 可选 MergeTree + 定期备份
--   4. 必须保证不丢数据: 只用 ReplicatedMergeTree

-- 创建非复制表做对比
CREATE TABLE IF NOT EXISTS non_replicated_test ON CLUSTER treasurycluster
(
    id UInt64,
    event_time DateTime,
    data String
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(event_time)
ORDER BY id;

-- 插入数据到非复制表
INSERT INTO non_replicated_test VALUES
(1, '2024-01-15 10:00:00', 'data1'),
(2, '2024-01-15 10:05:00', 'data2');

-- 查看非复制表在 system.replicas 中不存在
SELECT 
    database,
    table,
    engine
FROM system.tables
WHERE database = 'distributed_test' AND engine LIKE '%MergeTree%';

-- 【坑】非复制表不在 system.replicas 中
-- 如果误用 clusterAllReplicas 查询非复制表，会得到错误结果
SELECT 
    hostName() AS host,
    count() AS row_count
FROM clusterAllReplicas(treasurycluster, distributed_test.non_replicated_test)
GROUP BY host;

-- -----------------------------------------------------
-- 【场景】跨地域复制挑战
-- -----------------------------------------------------
-- 跨地域复制面临的问题:
--   1. 网络延迟高: 跨地域 RTT 通常 30-200ms
--   2. 带宽有限: 跨地域带宽通常小于同机房
--   3. 不稳定性: 跨地域网络抖动频繁
--   4. Raft 不适用: Keeper Raft 对网络延迟敏感
--
-- 解决方案:
--   1. 同地域内用 ReplicatedMergeTree
--   2. 跨地域用分布式表 + 自定义同步（如 Kafka）
--   3. 或使用 ClickHouse 的跨集群复制功能（实验性）
--
-- 【坑】不要直接用 ReplicatedMergeTree 跨地域复制
--   高延迟会导致 Keeper 频繁选举，复制队列积压
--   单次复制延迟可能达到分钟级甚至小时级

-- 查看当前集群配置（是否跨地域）
SELECT 
    cluster,
    shard_num,
    replica_num,
    host_name,
    host_address,
    port
FROM system.clusters
WHERE cluster = 'treasurycluster';

-- -----------------------------------------------------
-- 【坑】复制常见问题
-- -----------------------------------------------------
-- 1. "副本间是强一致的"
--    实际: 异步复制，默认最终一致，短暂不一致是正常现象
--
-- 2. "副本越多写入越快"
--    实际: 副本多增加 Keeper 协调开销
--    建议: 2-3 副本足够，更多副本收益递减
--
-- 3. "insert_quorum = 副本数 最安全"
--    实际: 任一副本宕机写入就失败，可用性差
--    建议: insert_quorum = max(1, 副本数 - 1)
--
-- 4. "复制表比非复制表慢很多"
--    实际: 写入稍慢（Keeper 写入开销），查询性能相同
--    生产环境应该接受这个代价
--
-- 5. "复制延迟只影响写入"
--    实际: 复制延迟也影响查询（读不到最新数据）
--    如果对一致性要求高，用 select_sequential_consistency

-- 复制健康检查综合查询
-- 【场景】日常巡检脚本
SELECT 
    database,
    table,
    replica_name,
    multiIf(
        is_readonly = 1, '❌ READONLY',
        is_session_expired = 1, '❌ SESSION EXPIRED',
        absolute_delay > 300, '⚠️ DELAY > 5min',
        absolute_delay > 60, '⚠️ DELAY > 1min',
        '✅ HEALTHY'
    ) AS status,
    absolute_delay,
    queue_size,
    inserts_in_queue,
    merges_in_queue,
    total_replicas,
    active_replicas
FROM system.replicas
WHERE database = 'distributed_test'
ORDER BY status, absolute_delay DESC;

-- -----------------------------------------------------
-- 清理
-- -----------------------------------------------------
DROP TABLE IF EXISTS replication_test ON CLUSTER treasurycluster SYNC;
DROP TABLE IF EXISTS non_replicated_test ON CLUSTER treasurycluster SYNC;

DROP DATABASE IF EXISTS distributed_test;