-- =====================================================
-- 05 - 集群基础概念
-- =====================================================
-- 本文件介绍 ClickHouse 集群的核心概念
-- 帮助理解分片、副本、分布式表等概念
-- =====================================================

-- -----------------------------------------------------
-- 1. 查看当前集群配置
-- -----------------------------------------------------
-- 首先，让我们了解当前连接的集群环境

-- 查看集群列表
SELECT * FROM system.clusters;

-- 查看当前集群的详细配置
SELECT 
    cluster,
    shard_num,
    shard_weight,
    replica_num,
    host_name,
    host_address,
    port,
    is_local
FROM system.clusters
WHERE cluster = 'treasurycluster'
ORDER BY shard_num, replica_num;

-- -----------------------------------------------------
-- 2. 理解分片（Shard）
-- -----------------------------------------------------
-- 分片是数据水平划分的单位，不同分片存储不同数据

-- 查看 Macros 配置（每个节点的配置可能不同）
SELECT * FROM system.macros;

-- 解释：
-- {cluster} = treasurycluster  - 集群名称
-- {shard} = 1 或 2              - 分片编号
-- {replica} = clickhouse1 或 clickhouse2  - 副本名称
-- {layer} = 01                  - 层级
-- {table_prefix} = test         - 表前缀

-- -----------------------------------------------------
-- 3. 本地表 vs 分布式表
-- -----------------------------------------------------

-- 本地表：只存在于当前节点
-- 创建本地表（使用 ON CLUSTER 会在所有节点创建）
CREATE TABLE IF NOT EXISTS tutorial.local_users ON CLUSTER treasurycluster
(
    user_id UInt32,
    user_name String,
    age UInt8,
    city String
)
ENGINE = MergeTree()
ORDER BY user_id;

-- 查看表在哪些节点上创建
SELECT 
    hostName() AS host,
    database,
    name,
    engine
FROM clusterAllReplicas(treasurycluster, system.tables)
WHERE database = 'tutorial' AND name = 'local_users';

-- -----------------------------------------------------
-- 4. 创建分布式表
-- -----------------------------------------------------
-- 分布式表本身不存储数据，只是查询路由

CREATE TABLE IF NOT EXISTS tutorial.distributed_users ON CLUSTER treasurycluster
AS tutorial.local_users
ENGINE = Distributed(treasurycluster, tutorial, local_users, rand());

-- 分布式表参数说明：
-- 1. treasurycluster - 集群名称
-- 2. tutorial - 数据库名称
-- 3. local_users - 本地表名称
-- 4. rand() - 分片键，决定数据路由到哪个分片

-- -----------------------------------------------------
-- 5. 分布式表的数据写入
-- -----------------------------------------------------

-- 方法 1: 通过分布式表写入（数据自动分发）
INSERT INTO tutorial.distributed_users VALUES
(1, 'Alice', 25, 'Beijing'),
(2, 'Bob', 30, 'Shanghai'),
(3, 'Charlie', 35, 'Guangzhou'),
(4, 'David', 28, 'Shenzhen'),
(5, 'Eve', 32, 'Hangzhou');

-- 方法 2: 直接写入本地表（需要手动控制数据分布）
-- INSERT INTO tutorial.local_users VALUES (...)

-- -----------------------------------------------------
-- 6. 分布式表的查询
-- -----------------------------------------------------

-- 查询分布式表（自动聚合所有分片的结果）
SELECT * FROM tutorial.distributed_users ORDER BY user_id;

-- 查询本地表（只查询当前节点的数据）
SELECT hostName() AS node, * FROM tutorial.local_users ORDER BY user_id;

-- 使用 clusterAllReplicas 查询所有副本
SELECT hostName() AS node, * 
FROM clusterAllReplicas(treasurycluster, tutorial.local_users)
ORDER BY node, user_id;

-- -----------------------------------------------------
-- 7. 理解副本（Replica）
-- -----------------------------------------------------
-- 副本是数据的冗余拷贝，用于高可用

-- 查看复制状态
SELECT 
    database,
    table,
    is_leader,
    can_become_leader,
    is_readonly,
    is_session_expired,
    future_parts,
    parts_to_check,
    zookeeper_path,
    replica_name,
    replica_path,
    columns_version,
    queue_size,
    inserts_in_queue,
    merges_in_queue,
    part_mutations_in_queue,
    absolute_delay
FROM system.replicas
WHERE database = 'tutorial';

-- -----------------------------------------------------
-- 8. 创建复制表（ReplicatedMergeTree）
-- -----------------------------------------------------

-- 复制表会在多个副本间自动同步数据
CREATE TABLE IF NOT EXISTS tutorial.replicated_events ON CLUSTER treasurycluster
(
    event_id UInt64,
    user_id UInt32,
    event_time DateTime,
    event_type String,
    value Float64
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/replicated_events', '{replica}')
ORDER BY (event_time, user_id)
PARTITION BY toYYYYMM(event_time);

-- 参数说明：
-- 1. '/clickhouse/tables/{shard}/replicated_events' - ZooKeeper 路径
--    {shard} 会自动替换为分片编号
-- 2. '{replica}' - 副本名称，自动替换为 replica 宏的值

-- -----------------------------------------------------
-- 9. 测试复制功能
-- -----------------------------------------------------

-- 插入数据到一个副本
INSERT INTO tutorial.replicated_events VALUES
(1, 100, '2024-01-15 10:00:00', 'click', 1.0),
(2, 101, '2024-01-15 10:05:00', 'view', 0.5),
(3, 100, '2024-01-15 10:10:00', 'purchase', 100.0);

-- 在副本 1 查询
SELECT hostName() AS node, * 
FROM clusterAllReplicas(treasurycluster, tutorial.replicated_events)
ORDER BY node, event_id;

-- -----------------------------------------------------
-- 10. 集群架构概念图
-- -----------------------------------------------------

-- 创建一个帮助理解的说明表
CREATE TABLE IF NOT EXISTS tutorial.cluster_concepts
(
    concept String,
    description String,
    analogy String
)
ENGINE = MergeTree()
ORDER BY concept;

INSERT INTO tutorial.cluster_concepts VALUES
('集群 (Cluster)', '多个 ClickHouse 节点的集合', '一家公司'),
('分片 (Shard)', '数据的水平划分，不同分片数据不同', '公司的不同部门'),
('副本 (Replica)', '数据的冗余拷贝，副本间数据相同', '部门的多个员工做相同工作'),
('分布式表 (Distributed)', '查询路由表，不存储实际数据', '前台接待，指引到正确部门'),
('本地表 (Local)', '实际存储数据的表', '部门的实际工作'),
('复制表 (Replicated)', '自动在副本间同步数据的表', '多个员工的同步工作'),
('分片键 (Sharding Key)', '决定数据路由到哪个分片的表达式', '分配工作的规则'),
('ZooKeeper/Keeper', '协调服务，管理元数据和选举', '公司的行政管理系统');

SELECT * FROM tutorial.cluster_concepts;

-- -----------------------------------------------------
-- 11. 分片策略
-- -----------------------------------------------------

-- 策略 1: 随机分片（rand()）
-- 优点：简单，数据分布均匀
-- 缺点：无法利用本地性优化
CREATE TABLE IF NOT EXISTS tutorial.dist_random AS tutorial.local_users
ENGINE = Distributed(treasurycluster, tutorial, local_users, rand());

-- 策略 2: 按用户 ID 分片（user_id）
-- 优点：相同用户的数据在同一分片，本地 JOIN 更高效
-- 缺点：可能数据分布不均（如果某些用户数据特别多）
CREATE TABLE IF NOT EXISTS tutorial.dist_user_id AS tutorial.local_users
ENGINE = Distributed(treasurycluster, tutorial, local_users, user_id);

-- 策略 3: 按城市分片（city）
-- 优点：按地理位置聚合时更高效
CREATE TABLE IF NOT EXISTS tutorial.dist_city AS tutorial.local_users
ENGINE = Distributed(treasurycluster, tutorial, local_users, city);

-- 策略 4: 取模分片（intHash64(user_id) % 2）
-- 优点：更均匀的数据分布
CREATE TABLE IF NOT EXISTS tutorial.dist_hash AS tutorial.local_users
ENGINE = Distributed(treasurycluster, tutorial, local_users, intHash64(user_id));

-- -----------------------------------------------------
-- 12. 分布式 JOIN
-- -----------------------------------------------------

-- 创建本地关联表
CREATE TABLE IF NOT EXISTS tutorial.local_orders ON CLUSTER treasurycluster
(
    order_id UInt64,
    user_id UInt32,
    amount Float64,
    order_date Date
)
ENGINE = MergeTree()
ORDER BY order_id;

CREATE TABLE IF NOT EXISTS tutorial.distributed_orders ON CLUSTER treasurycluster
AS tutorial.local_orders
ENGINE = Distributed(treasurycluster, tutorial, local_orders, user_id);

-- 插入数据
INSERT INTO tutorial.distributed_orders VALUES
(1001, 1, 100.0, '2024-01-15'),
(1002, 1, 200.0, '2024-01-16'),
(1003, 2, 150.0, '2024-01-15'),
(1004, 3, 300.0, '2024-01-17');

-- 本地 JOIN（数据在同一分片）
SELECT 
    u.user_id,
    u.user_name,
    count(o.order_id) AS order_count,
    sum(o.amount) AS total_amount
FROM tutorial.local_users u
LEFT JOIN tutorial.local_orders o ON u.user_id = o.user_id
GROUP BY u.user_id, u.user_name;

-- 分布式 JOIN（跨分片，使用 GLOBAL JOIN）
SELECT 
    u.user_id,
    u.user_name,
    count(o.order_id) AS order_count,
    sum(o.amount) AS total_amount
FROM tutorial.distributed_users u
GLOBAL LEFT JOIN tutorial.distributed_orders o ON u.user_id = o.user_id
GROUP BY u.user_id, u.user_name;

-- -----------------------------------------------------
-- 13. 监控集群状态
-- -----------------------------------------------------

-- 查看所有节点的健康状态
SELECT 
    hostName() AS node,
    count() AS total_tables
FROM clusterAllReplicas(treasurycluster, system.tables)
GROUP BY node;

-- 查看分布式表发送的数据量
SELECT 
    hostName() AS node,
    formatReadableSize(sum(ProfileEvents['DistributedSend'])) AS data_sent
FROM clusterAllReplicas(treasurycluster, system.query_log)
WHERE event_date >= today() - 1
GROUP BY node;

-- -----------------------------------------------------
-- 14. 学习检查点
-- -----------------------------------------------------

-- 问题 1: 分片和副本有什么区别？
-- 答案：分片是数据水平划分（数据不同），副本是数据冗余（数据相同）

-- 问题 2: 分布式表存储实际数据吗？
-- 答案：不存储，只是查询路由

-- 问题 3: 为什么复制表需要 ZooKeeper/Keeper？
-- 答案：用于协调副本间的元数据同步和主副本选举

-- 问题 4: GLOBAL JOIN 和普通 JOIN 的区别？
-- 答案：GLOBAL JOIN 会将右表广播到所有节点，适合跨分片 JOIN

-- -----------------------------------------------------
-- 15. 清理（可选）
-- -----------------------------------------------------
-- DROP TABLE IF EXISTS tutorial.local_users ON CLUSTER treasurycluster;
-- DROP TABLE IF EXISTS tutorial.distributed_users ON CLUSTER treasurycluster;
-- DROP TABLE IF EXISTS tutorial.replicated_events ON CLUSTER treasurycluster;
-- DROP TABLE IF EXISTS tutorial.cluster_concepts ON CLUSTER treasurycluster;
-- DROP TABLE IF EXISTS tutorial.dist_random ON CLUSTER treasurycluster;
-- DROP TABLE IF EXISTS tutorial.dist_user_id ON CLUSTER treasurycluster;
-- DROP TABLE IF EXISTS tutorial.dist_city ON CLUSTER treasurycluster;
-- DROP TABLE IF EXISTS tutorial.dist_hash ON CLUSTER treasurycluster;
-- DROP TABLE IF EXISTS tutorial.local_orders ON CLUSTER treasurycluster;
-- DROP TABLE IF EXISTS tutorial.distributed_orders ON CLUSTER treasurycluster;

-- =====================================================
-- 本章小结
-- =====================================================
-- 
-- 集群核心概念：
-- 1. 分片（Shard）：数据水平划分，不同分片数据不同
-- 2. 副本（Replica）：数据冗余拷贝，副本间数据相同
-- 3. 分布式表：查询路由，不存储数据
-- 4. 本地表：实际存储数据的表
-- 5. 复制表：ReplicatedMergeTree，自动同步
-- 6. Keeper：协调服务，管理元数据
--
-- 分片策略：
-- - rand()：随机分布
-- - user_id：按用户分布，利于本地 JOIN
-- - intHash64()：哈希分布，更均匀
--
-- 注意事项：
-- - 分布式 JOIN 使用 GLOBAL JOIN
-- - 复制表需要 ZooKeeper/Keeper
-- - 合理选择分片键
--
-- 下一步：06_first_replicated_table.sql - 创建第一个高可用表
-- =====================================================
