-- ============================================================
-- 文件: 01-base/02_replicated_tables.sql
-- 学习目标: 掌握 ReplicatedMergeTree 的复制日志机制、Keeper 协调流程、复制监控
-- 深度标准: 原理 + 场景 + 对比 + 可运行
-- 集群: treasurycluster (CH 25.12.1.649, 1分片2副本)
-- 前置: 无（自包含测试数据，按顺序执行）
-- ============================================================
--
-- 本文件章节:
--   1.  复制架构与 Keeper 协调原理
--   2.  Macros 宏变量与默认复制路径
--   3.  创建复制表（ReplicatedMergeTree 简化语法）
--   4.  插入数据与复制验证
--   5.  复制状态监控（system.replicas）
--   6.  复制队列分析（system.replication_queue）
--   7.  Keeper 路径与节点结构
--   8.  分区复制表与 Part 管理
--   9.  ReplacingMergeTree 复制版（去重更新）
--   10. CollapsingMergeTree 复制版（增量更新）
--   11. 复制延迟监控与告警
--   12. 清理
-- ============================================================

CREATE DATABASE IF NOT EXISTS base_test ON CLUSTER 'treasurycluster';
USE base_test;


-- ============================================================
-- 1. 复制架构与 Keeper 协调原理
-- ============================================================
-- 【原理】ReplicatedMergeTree 复制机制:
--
--   数据不在副本间直接传输，而是通过 Keeper 的"复制日志"异步同步:
--
--   1. Client → INSERT 到 Replica 1
--   2. Replica 1 写入本地 Part，向 Keeper log/ 追加 INSERT 记录
--   3. Replica 2 轮询发现 log_pointer 落后，读取 log 新记录
--   4. Replica 2 从 Replica 1 拉取对应 Part（HTTP :9000 inter-server）
--   5. Replica 2 本地写入 Part，更新 log_pointer
--   6. 两副本最终一致（异步，通常延迟 <1s）
--
--   Leader 选举: 每个分片选一个 Leader，只有 Leader 可发起 MERGE
--   → 避免多副本各自合并产生不一致的 Part
--
--   Keeper 路径结构:
--   /clickhouse/tables/{shard}/{table}/
--     ├── log/            ← 复制日志（有序操作队列）
--     ├── replicas/       ← 副本注册
--     │   ├── clickhouse1
--     │   └── clickhouse2
--     ├── columns         ← 列结构
--     └── minmax          ← Part 元数据
--
-- 【场景】需要高可用、数据冗余的生产环境
-- 【对比】MergeTree vs ReplicatedMergeTree:
--   MergeTree: 单节点，无高可用，MERGE 各自独立
--   ReplicatedMergeTree: 多副本，Keeper 协调，Leader 统一 MERGE
-- 【坑】依赖 Keeper 集群，Keeper 故障会导致复制暂停（但不影响本地读写）


-- ============================================================
-- 2. Macros 宏变量与默认复制路径
-- ============================================================
-- 【原理】Macros 简化复制表创建:
--   - {cluster} → treasurycluster
--   - {shard} → 1
--   - {replica} → clickhouse1 / clickhouse2
--   - 已配置 default_replica_path 和 default_replica_name
--   → 可用 ENGINE = ReplicatedMergeTree() 简化创建（无需手动指定 ZK 路径）

-- 查看当前节点的 Macros
SELECT * FROM system.macros;

-- 【结果解读】clickhouse1 显示 shard=1, replica=1
--   clickhouse2 显示 shard=1, replica=2（同一分片两个副本）


-- ============================================================
-- 3. 创建复制表（ReplicatedMergeTree 简化语法）
-- ============================================================
-- 【原理】ReplicatedMergeTree() 无参数版本:
--   自动使用 default_replica_path → /clickhouse/tables/{shard}/{table}
--   自动使用 default_replica_name → {replica}
--   无需手动指定 ZooKeeper 路径和副本名

DROP TABLE IF EXISTS test_replicated_events ON CLUSTER 'treasurycluster' SYNC;

CREATE TABLE test_replicated_events ON CLUSTER 'treasurycluster' (
    event_id UInt64,
    user_id UInt64,
    event_type String,
    event_data String,
    timestamp DateTime DEFAULT now()
) ENGINE = ReplicatedMergeTree()
PARTITION BY toYYYYMM(timestamp)
ORDER BY (user_id, timestamp);

-- 验证表创建
SHOW CREATE test_replicated_events;

-- 查看表的引擎和复制信息
SELECT
    database,
    table,
    engine,
    partition_key,
    sorting_key
FROM system.tables
WHERE database = 'base_test' AND table = 'test_replicated_events';


-- ============================================================
-- 4. 插入数据与复制验证
-- ============================================================
-- 【原理】INSERT 到复制表:
--   1. 写入本地 Part
--   2. 记录 Keeper 日志
--   3. 副本异步拉取同步
--   → 插入返回后数据已在本副本，另一副本异步同步（通常 <1s）

INSERT INTO test_replicated_events (event_id, user_id, event_type, event_data) VALUES
(1, 1, 'login', '{"ip":"192.168.1.1","device":"mobile"}'),
(2, 1, 'view_page', '{"page":"/home"}'),
(3, 2, 'login', '{"ip":"192.168.1.2","device":"desktop"}'),
(4, 2, 'purchase', '{"product_id":101,"amount":99.99}'),
(5, 1, 'logout', '{"duration":1800}'),
(6, 3, 'login', '{"ip":"192.168.1.3","device":"tablet"}'),
(7, 3, 'search', '{"query":"laptop"}'),
(8, 4, 'login', '{"ip":"192.168.1.4","device":"desktop"}');

-- 查询数据
SELECT * FROM test_replicated_events ORDER BY event_id;

SELECT count() AS total_events FROM test_replicated_events;

-- 验证两副本数据一致（在 clickhouse2 上执行相同查询）
SELECT
    hostName() AS current_host,
    count() AS event_count
FROM test_replicated_events;


-- ============================================================
-- 5. 复制状态监控（system.replicas）
-- ============================================================
-- 【原理】system.replicas 关键字段:
--   - is_leader: 是否为主副本（负责发起 MERGE）
--   - is_readonly: 是否只读模式（Keeper 连接断开时为 true）
--   - is_session_expired: Keeper 会话是否过期
--   - queue_size: 复制队列待处理操作数
--   - absolute_delay: 复制延迟（秒）
--   - total_replicas: 总副本数
--   - active_replicas: 活跃副本数
--
-- 【告警阈值】
--   absolute_delay > 60s → 警告
--   absolute_delay > 300s → 严重
--   active_replicas < total_replicas → 副本离线

SELECT
    database,
    table,
    is_leader,
    can_become_leader,
    is_readonly,
    is_session_expired,
    replica_name,
    replica_path,
    zookeeper_path,
    queue_size,
    absolute_delay,
    total_replicas,
    active_replicas
FROM system.replicas
WHERE table = 'test_replicated_events';

-- 【结果解读】
--   is_leader=1 的副本负责 MERGE
--   queue_size=0 表示无积压
--   absolute_delay=0 表示复制无延迟
--   active_replicas=total_replicas 表示所有副本在线


-- ============================================================
-- 6. 复制队列分析（system.replication_queue）
-- ============================================================
-- 【原理】复制队列记录待执行的操作:
--   - GET_PART: 拉取 Part（从其他副本同步数据）
--   - MERGE: 合并 Part
--   - ALTER: 表结构变更
--   - DELETE/MUTATION: 数据删除/修改
--
--   队列按顺序执行，失败会重试

SELECT
    database,
    table,
    type,
    replica_name,
    position,
    node_name,
    num_parts,
    is_permanently_failed,
    last_exception
FROM system.replication_queue
WHERE table = 'test_replicated_events'
ORDER BY position
LIMIT 10;

-- 【结果解读】队列应为空或很少（正常状态）


-- ============================================================
-- 7. Keeper 路径与节点结构
-- ============================================================
-- 【原理】查看 Keeper 中的复制表元数据
--   system.zookeeper 查询 Keeper 节点
--   注意: CH 25.12 的 system.zookeeper 使用 name/value/numChildren 等字段

-- 查看复制表的 Keeper 路径
SELECT
    database,
    table,
    replica_name,
    zookeeper_path,
    replica_path,
    leader_election
FROM system.replicas
WHERE table = 'test_replicated_events';

-- 查看 Keeper 根节点
SELECT
    name,
    value,
    ctime,
    mtime,
    version,
    numChildren
FROM system.zookeeper
WHERE path = '/'
LIMIT 10;

-- 查看复制表的 Keeper 节点结构
SELECT
    name,
    value,
    numChildren
FROM system.zookeeper
WHERE path = '/clickhouse/tables/1/test_replicated_events'
LIMIT 20;


-- ============================================================
-- 8. 分区复制表与 Part 管理
-- ============================================================
-- 【原理】分区在复制表中的行为:
--   - 每个 Part 属于一个分区
--   - MERGE 在分区内进行（不跨分区合并）
--   - DROP PARTITION 在所有副本上生效

DROP TABLE IF EXISTS test_replicated_logs ON CLUSTER 'treasurycluster' SYNC;

CREATE TABLE test_replicated_logs ON CLUSTER 'treasurycluster' (
    log_id UInt64,
    level String,
    message String,
    service String,
    timestamp DateTime
) ENGINE = ReplicatedMergeTree()
PARTITION BY toYYYYMM(timestamp)
ORDER BY (service, timestamp);

-- 插入跨月数据
INSERT INTO test_replicated_logs (log_id, level, message, service, timestamp) VALUES
(1, 'INFO', 'Service started', 'api', '2024-01-01 10:00:00'),
(2, 'DEBUG', 'Processing request', 'api', '2024-01-01 10:05:00'),
(3, 'WARNING', 'High latency', 'api', '2024-01-15 14:30:00'),
(4, 'ERROR', 'Connection failed', 'db', '2024-02-01 09:00:00'),
(5, 'INFO', 'Connection restored', 'db', '2024-02-01 09:05:00'),
(6, 'DEBUG', 'Query executed', 'db', '2024-02-20 16:45:00');

-- 【结果解读】查看分区和 Part 信息
SELECT
    partition,
    name AS part_name,
    rows,
    bytes_on_disk,
    level,
    formatReadableSize(bytes_on_disk) AS readable_size
FROM system.parts
WHERE database = 'base_test' AND table = 'test_replicated_logs' AND active = 1
ORDER BY partition, name;

-- 按分区查询统计
SELECT
    toYYYYMM(timestamp) AS partition,
    count() AS log_count,
    level,
    service
FROM test_replicated_logs
GROUP BY toYYYYMM(timestamp), level, service
ORDER BY toYYYYMM(timestamp), log_count DESC;


-- ============================================================
-- 9. ReplacingMergeTree 复制版（去重更新）
-- ============================================================
-- 【原理】ReplicatedReplacingMergeTree(version):
--   - 相同 ORDER BY 键保留 version 最大的行
--   - 合并时去重（异步），查询用 FINAL 或 argMax
--   - 复制版确保两副本去重行为一致
-- 【场景】用户资料更新、配置信息

DROP TABLE IF EXISTS test_replicated_user_state ON CLUSTER 'treasurycluster' SYNC;

CREATE TABLE test_replicated_user_state ON CLUSTER 'treasurycluster' (
    user_id UInt64,
    state String,
    last_updated DateTime,
    version UInt64
) ENGINE = ReplicatedReplacingMergeTree(version)
ORDER BY user_id;

-- 插入同一用户的多次状态更新
INSERT INTO test_replicated_user_state VALUES
(1, 'online', now() - INTERVAL 10 MINUTE, 1),
(2, 'offline', now() - INTERVAL 8 MINUTE, 1),
(3, 'online', now() - INTERVAL 6 MINUTE, 1);

INSERT INTO test_replicated_user_state VALUES
(1, 'busy', now() - INTERVAL 5 MINUTE, 2),
(2, 'online', now() - INTERVAL 4 MINUTE, 2),
(4, 'offline', now() - INTERVAL 2 MINUTE, 1);

-- 【结果解读】原始数据有重复（version 1 和 2 共存）
SELECT user_id, state, version FROM test_replicated_user_state
ORDER BY user_id, version;

-- FINAL 去重查询
SELECT user_id, state, version FROM test_replicated_user_state FINAL
ORDER BY user_id;


-- ============================================================
-- 10. CollapsingMergeTree 复制版（增量更新）
-- ============================================================
-- 【原理】ReplicatedCollapsingMergeTree(sign):
--   - sign=+1 和 sign=-1 相互抵消
--   - 查询时用 sum(quantity * sign) 计算当前值
--   - 复制版确保两副本折叠行为一致
-- 【场景】库存管理、订单状态流转

DROP TABLE IF EXISTS test_replicated_inventory ON CLUSTER 'treasurycluster' SYNC;

CREATE TABLE test_replicated_inventory ON CLUSTER 'treasurycluster' (
    product_id UInt64,
    quantity_change Int32,
    sign Int8,
    timestamp DateTime
) ENGINE = ReplicatedCollapsingMergeTree(sign)
ORDER BY product_id;

-- 初始库存（sign = 1）
INSERT INTO test_replicated_inventory VALUES
(1, 100, 1, now() - INTERVAL 1 DAY),
(2, 50, 1, now() - INTERVAL 1 DAY),
(3, 75, 1, now() - INTERVAL 1 DAY);

-- 卖出商品（sign = -1）
INSERT INTO test_replicated_inventory VALUES
(1, 10, -1, now() - INTERVAL 12 HOUR),
(2, 5, -1, now() - INTERVAL 12 HOUR);

-- 进货（sign = 1）
INSERT INTO test_replicated_inventory VALUES
(1, 20, 1, now() - INTERVAL 6 HOUR),
(3, 10, 1, now() - INTERVAL 6 HOUR);

-- 【结果解读】用 sum(quantity * sign) 计算当前库存
SELECT
    product_id,
    sum(quantity_change * sign) AS current_stock
FROM test_replicated_inventory
GROUP BY product_id
ORDER BY product_id;


-- ============================================================
-- 11. 复制延迟监控与告警
-- ============================================================
-- 【原理】复制延迟监控:
--   - absolute_delay: 当前副本落后 Leader 的秒数
--   - queue_size: 待处理操作数
--   - 延迟原因: 网络问题、Keeper 故障、大 Part 同步慢

-- 综合复制健康检查
SELECT
    database,
    table,
    replica_name,
    is_leader,
    queue_size,
    absolute_delay,
    active_replicas,
    total_replicas,
    formatReadableTimeDelta(absolute_delay) AS delay_readable,
    if(absolute_delay > 300, 'CRITICAL',
       if(absolute_delay > 60, 'WARNING', 'OK')) AS status
FROM system.replicas
WHERE database = 'base_test'
ORDER BY table, replica_name;

-- 查看合并操作状态
SELECT
    database,
    table,
    is_currently_running,
    elapsed_time,
    progress,
    num_parts,
    total_size_bytes_compressed,
    result_part_name
FROM system.merges
WHERE database = 'base_test'
ORDER BY table
LIMIT 10;


-- ============================================================
-- 12. 清理
-- ============================================================
DROP TABLE IF EXISTS test_replicated_events ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS test_replicated_logs ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS test_replicated_user_state ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS test_replicated_inventory ON CLUSTER 'treasurycluster' SYNC;

-- 验证清理
SELECT name FROM system.tables WHERE database = 'base_test';
