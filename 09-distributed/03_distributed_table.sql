-- =====================================================
-- 03 - 分布式表深度
-- =====================================================
-- Distributed 表引擎路由原理、读写流程、监控
-- 集群: treasurycluster
-- =====================================================

-- 注意: 集群建库必须加 ON CLUSTER，否则 clickhouse-server-2 上数据库不存在，
-- 后续 ON CLUSTER 建表会报 Code 81 (UNKNOWN_DATABASE)
-- DROP DATABASE 必须带 SYNC: 否则已存在副本在 ZK 中的元数据不会同步删除，
-- 再次建同名的 ReplicatedMergeTree 表会报 REPLICA_ALREADY_EXISTS (Code 253)
DROP DATABASE IF EXISTS distributed_test ON CLUSTER treasurycluster SYNC;
CREATE DATABASE IF NOT EXISTS distributed_test ON CLUSTER treasurycluster;
USE distributed_test;

-- ========================================
-- 【原理】Distributed 表引擎路由原理
-- ========================================
-- Distributed 表本身不存储数据，只是查询路由层
-- 分片键在 INSERT 时计算，决定数据写入哪个分片
--
-- 路由公式:
--   目标分片编号 = cityHash64(sharding_key) % 分片总数
--
-- 分片编号对应 system.clusters 中按 shard_num 排序的分片
-- 每个分片可能有多个副本，Distributed 表随机或按负载均衡策略选择

-- -----------------------------------------------------
-- 1. 查看集群配置
-- -----------------------------------------------------
-- 【原理】system.clusters 显示集群中的分片和副本配置
SELECT 
    cluster,
    shard_num,
    shard_weight,
    replica_num,
    host_name,
    host_address,
    port,
    is_local,
    user
FROM system.clusters
WHERE cluster = 'treasurycluster'
ORDER BY shard_num, replica_num;

-- -----------------------------------------------------
-- 2. 创建本地表和分布式表
-- -----------------------------------------------------
-- 【原理】先在每个节点创建本地复制表
-- 再用 Distributed 表包装，提供统一访问接口

-- 创建本地复制表（用 ON CLUSTER 在所有节点创建）
CREATE TABLE IF NOT EXISTS local_events ON CLUSTER treasurycluster
(
    event_id UInt64,
    user_id UInt32,
    event_time DateTime,
    event_type String,
    value Float64
)
ENGINE = ReplicatedMergeTree
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_time, event_id);

-- 创建分布式表
-- 【原理】Distributed 表参数:
--   1. cluster: 集群名
--   2. database: 目标数据库
--   3. table: 目标本地表
--   4. sharding_key: 分片键（可选，不指定则随机路由）
CREATE TABLE IF NOT EXISTS dist_events ON CLUSTER treasurycluster
AS local_events
ENGINE = Distributed(treasurycluster, distributed_test, local_events, cityHash64(user_id));

-- 查看分布式表结构
SHOW CREATE dist_events;

-- -----------------------------------------------------
-- 【原理】分片键路由验证
-- -----------------------------------------------------
-- 验证 cityHash64(user_id) 的分布均匀性
-- 对于 1 分片集群，所有数据路由到同一分片
-- 对于多分片集群，user_id 哈希值决定数据去向

-- 验证 cityHash64 的分布
-- 【场景】上线前验证分片键均匀性
SELECT 
    cityHash64(user_id) % 4 AS shard,
    count() AS cnt,
    round(count() / sum(count()) OVER (), 4) AS ratio
FROM (
    SELECT number AS user_id FROM numbers(100000)
)
GROUP BY shard
ORDER BY shard;

-- 对比不同分片键的均匀性
-- 【对比】rand() 每次调用返回不同值，不适合作为分片键
SELECT 
    'cityHash64(user_id)' AS method,
    cityHash64(number) % 4 AS shard,
    count() AS cnt
FROM numbers(100000)
GROUP BY shard
ORDER BY shard;

SELECT 
    'intHash64(user_id)' AS method,
    intHash64(number) % 4 AS shard,
    count() AS cnt
FROM numbers(100000)
GROUP BY shard
ORDER BY shard;

SELECT 
    'rand()' AS method,
    rand() % 4 AS shard,
    count() AS cnt
FROM numbers(100000)
GROUP BY shard
ORDER BY shard;

-- -----------------------------------------------------
-- 3. 分布式表写入流程
-- -----------------------------------------------------
-- 【原理】写入 Distributed 表有两种模式:
--   1. 本地写入（默认）: 数据先写入当前节点，后台线程异步发送到目标分片
--   2. 远程写入: 直接写入目标分片，绕过本地磁盘
--
-- 本地写入流程:
--   INSERT INTO dist_events VALUES (...)
--   → 计算 cityHash64(user_id) % 分片数
--   → 确定目标分片
--   → 数据写入本地存储（暂存）
--   → 后台线程异步发送到目标分片
--   → 目标分片写入本地表
--
-- 远程写入:
--   SET insert_distributed_sync = 1;
--   INSERT INTO dist_events VALUES (...)
--   → 直接发送到目标分片
--   → 同步等待写入完成

-- 插入测试数据（本地写入模式）
INSERT INTO dist_events VALUES
(1, 101, '2024-01-15 10:00:00', 'click', 1.0),
(2, 102, '2024-01-15 10:05:00', 'view', 0.5),
(3, 103, '2024-01-15 10:10:00', 'purchase', 100.0),
(4, 104, '2024-01-15 10:15:00', 'click', 2.0),
(5, 105, '2024-01-15 10:20:00', 'view', 0.8),
(6, 101, '2024-01-15 10:25:00', 'purchase', 200.0),
(7, 102, '2024-01-15 10:30:00', 'click', 1.5),
(8, 106, '2024-01-15 10:35:00', 'view', 0.3),
(9, 107, '2024-01-15 10:40:00', 'purchase', 150.0),
(10, 108, '2024-01-15 10:45:00', 'click', 3.0);

-- 查看分布式表数据（自动聚合所有分片）
SELECT * FROM dist_events ORDER BY event_id;

-- 查看本地表数据（只显示当前节点数据）
SELECT hostName() AS host, * FROM local_events ORDER BY event_id;

-- 查看各副本的数据分布
-- 【原理】clusterAllReplicas 查询所有副本的数据
SELECT 
    hostName() AS host,
    _shard_num,
    count() AS row_count,
    countDistinct(user_id) AS unique_users
FROM clusterAllReplicas(treasurycluster, distributed_test.local_events)
GROUP BY host, _shard_num
ORDER BY host;

-- -----------------------------------------------------
-- 4. 分布式表查询流程
-- -----------------------------------------------------
-- 【原理】SELECT 查询流程:
--   1. 协调节点解析查询
--   2. 将查询发往所有分片（并行）
--   3. 各分片本地执行，返回部分结果
--   4. 协调节点合并结果，返回 Client
--
-- 查询裁剪:
--   如果 WHERE 条件包含分片键，可以只查询相关分片
--   例如: WHERE user_id = 101 → 只查 cityHash64(101) % N 所在分片

-- 查询所有数据（走全部分片）
SELECT 
    count() AS total_events,
    sum(value) AS total_value,
    uniqExact(user_id) AS unique_users
FROM dist_events;

-- 查看各分片数据分布
-- 【原理】_shard_num 虚拟列显示数据来源分片
SELECT 
    _shard_num,
    count() AS row_count,
    sum(value) AS total_value
FROM dist_events
GROUP BY _shard_num
ORDER BY _shard_num;

-- -----------------------------------------------------
-- 5. 分布式表监控
-- -----------------------------------------------------
-- 【原理】system.distributed_ddl_queue 显示分布式 DDL 执行状态
-- system.clusters 显示集群配置

-- 查看分布式 DDL 队列
-- 【坑】system.clusters 没有 database/table 列（那是 system.distributed_ddl_queue），
--       查看 DDL 队列需用 system.distributed_ddl_queue
SELECT 
    cluster,
    query,
    host,
    port,
    status,
    query_create_time
FROM system.distributed_ddl_queue
WHERE cluster = 'treasurycluster'
ORDER BY query_create_time DESC
LIMIT 20;

-- 查看分布式表的分片信息
-- 【场景】排查分布式表配置
-- 【坑】system.clusters 没有 database/table 列（那是 system.distributed_ddl_queue 的），
--       查看 Distributed 表发送队列要用 system.distribution_queue
SELECT 
    database AS db,
    table AS tbl,
    data_path,
    is_blocked,
    data_files,
    data_compressed_bytes,
    error_count,
    last_exception
FROM system.distribution_queue
WHERE database = 'distributed_test'
ORDER BY db, tbl;

-- 查看分布式表写入的累计数据量
-- 【原理】system.distribution_queue 展示了 Distributed 表异步发送队列的状态：
--         data_files 待发送的本地暂存文件数、data_compressed_bytes 待发送字节数、
--         error_count 发送失败次数、last_exception 最近一次失败原因
-- （原版本用 system.query_log 的 ProfileEvents 统计，但本集群禁用了 query_log，
--   改为用 system.distribution_queue 的监控列，信息更直接）
SELECT 
    database AS db,
    table AS tbl,
    data_files,
    data_compressed_bytes,
    broken_data_files,
    broken_data_compressed_bytes,
    error_count,
    last_exception_time,
    last_exception
FROM system.distribution_queue
WHERE database = 'distributed_test'
ORDER BY db, tbl;

-- -----------------------------------------------------
-- 【对比】本地写入 vs 远程写入
-- -----------------------------------------------------
-- +------------------+------------------+------------------+
-- | 特性              | 本地写入          | 远程写入          |
-- +------------------+------------------+------------------+
-- | 写入方式          | 异步发送          | 同步写入          |
-- | 确认返回          | 本地写入即返回     | 等目标分片确认     |
-- | 安全性            | 本地暂存，有丢失风险 | 直接写入目标      |
-- | 延迟              | 低                | 高（网络开销）     |
-- | 适用场景          | 默认推荐          | 重要数据即时写入   |
-- +------------------+------------------+------------------+

-- 测试远程写入模式
-- 【场景】需要确保数据立即写入目标分片
SET insert_distributed_sync = 1;

INSERT INTO dist_events VALUES
(11, 109, '2024-01-16 10:00:00', 'click', 1.2),
(12, 110, '2024-01-16 10:05:00', 'view', 0.6);

-- 恢复默认设置
SET insert_distributed_sync = 0;

-- -----------------------------------------------------
-- 6. 分布式 DDL 和 ON CLUSTER 语法
-- -----------------------------------------------------
-- 【原理】ON CLUSTER 在集群所有节点上执行 DDL
-- 执行过程:
--   1. 当前节点在 Keeper 创建 DDL 任务
--   2. 所有节点监听 Keeper，拉取 DDL 任务
--   3. 各节点本地执行 DDL
--   4. 执行结果写入 Keeper

-- 使用 ON CLUSTER 创建表
CREATE TABLE IF NOT EXISTS cluster_wide_table ON CLUSTER treasurycluster
(
    id UInt64,
    data String
)
ENGINE = ReplicatedMergeTree
ORDER BY id;

-- 创建对应的分布式表
CREATE TABLE IF NOT EXISTS dist_cluster_wide ON CLUSTER treasurycluster
AS cluster_wide_table
ENGINE = Distributed(treasurycluster, distributed_test, cluster_wide_table, cityHash64(id));

-- 插入数据
INSERT INTO dist_cluster_wide VALUES
(1, 'data1'),
(2, 'data2'),
(3, 'data3');

-- 验证所有节点都有数据
SELECT 
    hostName() AS host,
    count() AS row_count
FROM clusterAllReplicas(treasurycluster, distributed_test.cluster_wide_table)
GROUP BY host
ORDER BY host;

-- -----------------------------------------------------
-- 【坑】分布式表常见问题
-- -----------------------------------------------------
-- 1. "分布式表查询比本地表慢很多"
--    实际: 如果只是简单查询，差异不大
--    复杂聚合需要两阶段执行，会有额外开销
--
-- 2. "写入分布式表数据会丢失"
--    实际: 异步写入时，如果节点宕机，暂存数据可能丢失
--    生产环境建议: insert_distributed_sync = 1 或直接写入本地表
--
-- 3. "分片键定好后不能改"
--    实际: 可以改，但需要重建分布式表
--    已有数据不会自动重新分片，需手动迁移
--
-- 4. "Distributed 表可以 join 任意表"
--    实际: 分布式 JOIN 有限制，跨分片 JOIN 需要用 GLOBAL JOIN
--    详见 07_global_join.sql

-- -----------------------------------------------------
-- 清理
-- -----------------------------------------------------
DROP TABLE IF EXISTS dist_events ON CLUSTER treasurycluster SYNC;
DROP TABLE IF EXISTS local_events ON CLUSTER treasurycluster SYNC;
DROP TABLE IF EXISTS dist_cluster_wide ON CLUSTER treasurycluster SYNC;
DROP TABLE IF EXISTS cluster_wide_table ON CLUSTER treasurycluster SYNC;

-- 与开头 ON CLUSTER 建库对应，DROP 也须 ON CLUSTER
-- 结尾同样带 SYNC，确保 ZK 中副本元数据一并清理
DROP DATABASE IF EXISTS distributed_test ON CLUSTER treasurycluster SYNC;