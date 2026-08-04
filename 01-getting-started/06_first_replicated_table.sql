-- =====================================================
-- 06 - 第一个复制表（高可用实战）
-- =====================================================
-- 本文件带你创建一个完整的复制表
-- 验证高可用特性，理解故障转移
-- =====================================================

-- -----------------------------------------------------
-- 1. 准备工作：确认集群环境
-- -----------------------------------------------------

-- 确认集群配置
SELECT 
    cluster,
    host_name,
    port,
    is_local
FROM system.clusters
WHERE cluster = 'treasurycluster'
ORDER BY host_name;

-- 确认当前节点的 Macros
SELECT * FROM system.macros;

-- -----------------------------------------------------
-- 2. 创建复制表
-- -----------------------------------------------------
-- 使用 ON CLUSTER 在所有节点上创建表

CREATE TABLE IF NOT EXISTS tutorial.my_first_replicated_table ON CLUSTER treasurycluster
(
    -- 主键列
    event_id UInt64,
    
    -- 时间戳，用于分区
    event_time DateTime,
    event_date Date,
    
    -- 业务数据
    user_id UInt32,
    username String,
    action String,
    
    -- 数值数据
    value Float64,
    
    -- 额外信息
    metadata String
)
ENGINE = ReplicatedMergeTree(
    '/clickhouse/tables/{shard}/my_first_replicated_table',  -- ZooKeeper 路径
    '{replica}'                                               -- 副本名称
)
ORDER BY (event_date, user_id, event_id)  -- 排序键
PARTITION BY toYYYYMM(event_date);         -- 按月分区

-- 查看表是否在所有节点创建成功
SELECT 
    hostName() AS node,
    database,
    name,
    engine,
    create_table_query
FROM clusterAllReplicas(treasurycluster, system.tables)
WHERE database = 'tutorial' AND name = 'my_first_replicated_table';

-- -----------------------------------------------------
-- 3. 查看复制表状态
-- -----------------------------------------------------

-- 查看复制状态
SELECT 
    hostName() AS node,
    database,
    table,
    is_leader,
    can_become_leader,
    is_readonly,
    absolute_delay,
    queue_size,
    inserts_in_queue,
    total_replicas,
    active_replicas
FROM clusterAllReplicas(treasurycluster, system.replicas)
WHERE database = 'tutorial' AND table = 'my_first_replicated_table';

-- 解释字段：
-- is_leader: 是否是主副本（只有主副本可以执行合并操作）
-- is_readonly: 是否只读（通常是 Keeper 连接问题）
-- absolute_delay: 复制延迟（秒）
-- queue_size: 待处理的操作队列大小
-- total_replicas: 总副本数
-- active_replicas: 活跃副本数

-- -----------------------------------------------------
-- 4. 插入数据并观察复制
-- -----------------------------------------------------

-- 插入第一批数据（在本地节点）
INSERT INTO tutorial.my_first_replicated_table VALUES
(1, '2024-01-15 10:00:00', '2024-01-15', 1001, 'user_1001', 'login', 0.0, 'First login'),
(2, '2024-01-15 10:05:00', '2024-01-15', 1002, 'user_1002', 'click', 1.0, 'Button click'),
(3, '2024-01-15 10:10:00', '2024-01-15', 1001, 'user_1001', 'purchase', 99.99, 'Buy product');

-- 等待几秒让数据复制
SELECT '等待数据复制...' AS status;

-- 在两个副本上查询数据
SELECT 
    hostName() AS node,
    count() AS row_count,
    min(event_time) AS earliest_event,
    max(event_time) AS latest_event
FROM clusterAllReplicas(treasurycluster, tutorial.my_first_replicated_table)
GROUP BY node
ORDER BY node;

-- -----------------------------------------------------
-- 5. 批量插入数据
-- -----------------------------------------------------

-- 生成更多测试数据
INSERT INTO tutorial.my_first_replicated_table
SELECT 
    number + 1000 AS event_id,
    toDateTime('2024-01-15 00:00:00') + (number * 60) AS event_time,
    toDate('2024-01-15') + (number * 60 / 86400) AS event_date,
    (number % 1000) + 1 AS user_id,
    'user_' || toString((number % 1000) + 1) AS username,
    ['login', 'logout', 'click', 'view', 'purchase'][(number % 5) + 1] AS action,
    rand() % 1000 / 10.0 AS value,
    'Generated event ' || toString(number) AS metadata
FROM numbers(10000);

-- 验证数据量
SELECT 
    hostName() AS node,
    count() AS total_rows,
    count(DISTINCT user_id) AS unique_users,
    sum(value) AS total_value
FROM clusterAllReplicas(treasurycluster, tutorial.my_first_replicated_table)
GROUP BY node
ORDER BY node;

-- -----------------------------------------------------
-- 6. 理解分区
-- -----------------------------------------------------

-- 查看分区信息
SELECT 
    hostName() AS node,
    partition,
    name AS part_name,
    active,
    rows,
    formatReadableSize(bytes_on_disk) AS size,
    modification_time
FROM clusterAllReplicas(treasurycluster, system.parts)
WHERE database = 'tutorial' AND table = 'my_first_replicated_table'
ORDER BY node, partition, part_name;

-- -----------------------------------------------------
-- 7. 数据一致性验证
-- -----------------------------------------------------

-- 计算每个副本的校验和
SELECT 
    hostName() AS node,
    sum(cityHash64(*)) AS checksum
FROM clusterAllReplicas(treasurycluster, tutorial.my_first_replicated_table)
GROUP BY node
ORDER BY node;

-- 详细数据对比
SELECT
    hostName() AS node,
    event_id,
    user_id,
    username,
    action,
    value
FROM clusterAllReplicas(treasurycluster, tutorial.my_first_replicated_table)
WHERE event_id IN (1, 2, 3)
ORDER BY node, event_id;

-- -----------------------------------------------------
-- 8. 模拟故障场景（可选）
-- -----------------------------------------------------
-- 注意：这需要 Docker 环境权限

-- 查看当前 Keeper 连接状态
SELECT 
    hostName() AS node,
    name,
    value
FROM clusterAllReplicas(treasurycluster, system.zookeeper)
WHERE path = '/clickhouse/tables/1/my_first_replicated_table';

-- 查看 Keeper 中的副本信息
SELECT 
    hostName() AS node,
    name,
    value
FROM clusterAllReplicas(treasurycluster, system.zookeeper)
WHERE path = '/clickhouse/tables/1/my_first_replicated_table/replicas';

-- -----------------------------------------------------
-- 9. 查询示例
-- -----------------------------------------------------

-- 查询 1: 按日期统计
SELECT 
    event_date,
    count() AS event_count,
    count(DISTINCT user_id) AS unique_users,
    round(sum(value), 2) AS total_value
FROM tutorial.my_first_replicated_table
GROUP BY event_date
ORDER BY event_date;

-- 查询 2: 按动作类型统计
SELECT 
    action,
    count() AS count,
    round(avg(value), 2) AS avg_value,
    round(sum(value), 2) AS total_value
FROM tutorial.my_first_replicated_table
GROUP BY action
ORDER BY count DESC;

-- 查询 3: 用户行为分析
SELECT 
    username,
    count() AS action_count,
    groupArray(DISTINCT action) AS actions,
    round(sum(value), 2) AS total_value
FROM tutorial.my_first_replicated_table
GROUP BY username
ORDER BY action_count DESC
LIMIT 10;

-- -----------------------------------------------------
-- 10. 创建分布式视图（可选）
-- -----------------------------------------------------

-- 创建分布式表，跨分片查询
CREATE TABLE IF NOT EXISTS tutorial.distributed_replicated_events ON CLUSTER treasurycluster
AS tutorial.my_first_replicated_table
ENGINE = Distributed(treasurycluster, tutorial, my_first_replicated_table, rand());

-- 查询分布式表
SELECT 
    event_date,
    count() AS total_events
FROM tutorial.distributed_replicated_events
GROUP BY event_date
ORDER BY event_date;

-- -----------------------------------------------------
-- 11. 监控和维护
-- -----------------------------------------------------

-- 监控复制延迟
SELECT 
    hostName() AS node,
    absolute_delay,
    queue_size,
    inserts_in_queue,
    merges_in_queue
FROM clusterAllReplicas(treasurycluster, system.replicas)
WHERE database = 'tutorial' AND table = 'my_first_replicated_table';

-- 监控存储使用情况
SELECT 
    hostName() AS node,
    formatReadableSize(sum(bytes_on_disk)) AS total_size,
    sum(rows) AS total_rows,
    count() AS total_parts
FROM clusterAllReplicas(treasurycluster, system.parts)
WHERE database = 'tutorial' AND table = 'my_first_replicated_table' AND active = 1
GROUP BY node;

-- -----------------------------------------------------
-- 12. 手动触发合并（通常不需要）
-- -----------------------------------------------------

-- 查看当前片段
SELECT 
    hostName() AS node,
    partition,
    name,
    rows,
    formatReadableSize(bytes_on_disk) AS size
FROM clusterAllReplicas(treasurycluster, system.parts)
WHERE database = 'tutorial' AND table = 'my_first_replicated_table' AND active = 1
ORDER BY node, partition, name;

-- 手动优化（可选）
-- OPTIMIZE TABLE tutorial.my_first_replicated_table ON CLUSTER treasurycluster;

-- -----------------------------------------------------
-- 13. 最佳实践总结
-- -----------------------------------------------------

-- 创建总结表
CREATE TABLE IF NOT EXISTS tutorial.replication_best_practices
(
    practice String,
    description String,
    priority String
)
ENGINE = MergeTree()
ORDER BY priority;

INSERT INTO tutorial.replication_best_practices VALUES
('使用 ON CLUSTER', '在所有节点上自动创建表', '高'),
('合理设置分区和排序键', '影响查询性能和存储效率', '高'),
('监控 replication delay', '及时发现复制问题', '中'),
('定期检查 is_readonly', '发现 Keeper 连接问题', '中'),
('使用分布式表查询', '简化跨节点查询', '中'),
('避免频繁小批量插入', '使用批量插入提高效率', '高'),
('合理设置分区粒度', '按月分区通常是好的选择', '中'),
('备份元数据', '定期备份 ZooKeeper/Keeper 数据', '低');

SELECT * FROM tutorial.replication_best_practices ORDER BY priority;

-- -----------------------------------------------------
-- 14. 故障排查检查清单
-- -----------------------------------------------------

-- 检查 1: 表是否只读
SELECT 
    hostName() AS node,
    is_readonly,
    is_session_expired
FROM clusterAllReplicas(treasurycluster, system.replicas)
WHERE database = 'tutorial';

-- 检查 2: Keeper 连接
SELECT 
    hostName() AS node,
    count() AS zk_connections
FROM clusterAllReplicas(treasurycluster, system.zookeeper_connection)
GROUP BY node;

-- 检查 3: 复制队列
SELECT 
    hostName() AS node,
    database,
    table,
    queue_size,
    absolute_delay
FROM clusterAllReplicas(treasurycluster, system.replicas)
WHERE queue_size > 0;

-- -----------------------------------------------------
-- 15. 学习检查点
-- -----------------------------------------------------

-- 问题 1: ReplicatedMergeTree 的 ZooKeeper 路径中的 {shard} 和 {replica} 是什么？
-- 答案：宏变量，会自动替换为当前节点的分片号和副本名

-- 问题 2: 如何验证复制是否正常工作？
-- 答案：在两个副本上查询相同的数据，检查结果是否一致

-- 问题 3: is_readonly = 1 表示什么？
-- 答案：表处于只读模式，通常是 Keeper 连接问题

-- 问题 4: 复制延迟高怎么办？
-- 答案：检查网络、负载、队列大小，可能需要优化插入方式

-- -----------------------------------------------------
-- 16. 清理（可选）
-- -----------------------------------------------------
-- DROP TABLE IF EXISTS tutorial.my_first_replicated_table ON CLUSTER treasurycluster;
-- DROP TABLE IF EXISTS tutorial.distributed_replicated_events ON CLUSTER treasurycluster;
-- DROP TABLE IF EXISTS tutorial.replication_best_practices ON CLUSTER treasurycluster;

-- =====================================================
-- 本章小结
-- =====================================================
-- 
-- 复制表核心要点：
-- 1. ENGINE = ReplicatedMergeTree(zk_path, replica_name)
-- 2. 使用 ON CLUSTER 在所有节点创建
-- 3. 数据自动在副本间同步
-- 4. 通过 system.replicas 监控复制状态
--
-- 监控指标：
-- - is_leader: 主副本标识
-- - is_readonly: 只读状态
-- - absolute_delay: 复制延迟
-- - queue_size: 待处理队列
--
-- 故障排查：
-- - is_readonly = 1: 检查 Keeper 连接
-- - queue_size 高: 检查网络和负载
-- - 数据不一致: 检查 Keeper 路径
--
-- 恭喜！完成本章后，你已经掌握了：
-- ✅ ClickHouse 基础概念
-- ✅ 列式存储原理
-- ✅ MergeTree 引擎
-- ✅ 基础 SQL 操作
-- ✅ 集群架构
-- ✅ 复制表创建和高可用
--
-- 下一步：继续学习 01-getting-started/ 目录的进阶内容
-- =====================================================
