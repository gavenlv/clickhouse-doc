-- =====================================================
-- 04 - 跨集群 DDL
-- =====================================================
-- ON CLUSTER 语法原理、DDL 队列监控、失败处理
-- 集群: treasurycluster
-- =====================================================

DROP DATABASE IF EXISTS distributed_test ON CLUSTER treasurycluster;
CREATE DATABASE IF NOT EXISTS distributed_test ON CLUSTER treasurycluster;
USE distributed_test;

-- ========================================
-- 【原理】ON CLUSTER 语法原理
-- ========================================
-- ON CLUSTER 不是原子操作，而是逐个节点广播执行
-- 执行流程:
--   1. 发起节点在 Keeper 创建 DDL 任务
--   2. 所有节点监听 Keeper 的 /ddl/ 路径
--   3. 发现新任务 → 拉取 → 本地执行
--   4. 执行结果写回 Keeper
--
-- DDL 在 Keeper 中的路径:
--   /clickhouse/task_queue/ddl/
--   ├── query-0001  ← DDL 任务
--   │   ├── host-name-1  ← 节点1 执行结果
--   │   └── host-name-2  ← 节点2 执行结果
--   └── query-0002
--       ├── host-name-1
--       └── host-name-2

-- -----------------------------------------------------
-- 1. 基本 ON CLUSTER 操作
-- -----------------------------------------------------
-- 【场景】在集群所有节点上创建表

-- 创建数据库（ON CLUSTER 在所有节点创建）
CREATE DATABASE IF NOT EXISTS ddl_test ON CLUSTER treasurycluster;

-- 创建表（ON CLUSTER 在所有节点创建）
CREATE TABLE IF NOT EXISTS ddl_test.sample_table ON CLUSTER treasurycluster
(
    id UInt64,
    name String,
    created_at DateTime DEFAULT now()
)
ENGINE = ReplicatedMergeTree
ORDER BY id;

-- 验证所有节点都创建了表
SELECT 
    hostName() AS host,
    database,
    name,
    engine
FROM clusterAllReplicas(treasurycluster, system.tables)
WHERE database = 'ddl_test' AND name = 'sample_table';

-- 修改表结构（ON CLUSTER 添加列）
ALTER TABLE ddl_test.sample_table ON CLUSTER treasurycluster
ADD COLUMN IF NOT EXISTS description String;

-- 验证所有节点都添加了列
SELECT 
    hostName() AS host,
    database,
    table,
    name,
    type
FROM clusterAllReplicas(treasurycluster, system.columns)
WHERE database = 'ddl_test' AND table = 'sample_table' AND name = 'description';

-- -----------------------------------------------------
-- 2. 查看 DDL 队列状态
-- -----------------------------------------------------
-- 【原理】system.distributed_ddl_queue 显示 DDL 执行状态
-- 关键字段:
--   - query: DDL 语句
--   - status: 执行状态 Enum8('Inactive'/'Active'/'Finished'/'Removing'/'Unknown')，不能用 'OK' 比较（Code 691）
--   - initiator_host: 发起节点
--   - query_create_time: 创建时间（25.12 已无 clock_time 列）

-- 查看 DDL 队列
-- 【场景】排查 DDL 是否执行成功
-- 【兼容性】25.12 的 distributed_ddl_queue 无 clock_time/host_name/host_address/is_local/database 列，
-- 改用 query_create_time/host，并按 cluster 过滤
SELECT 
    query,
    status,
    initiator_host,
    query_create_time,
    host,
    port
FROM system.distributed_ddl_queue
WHERE cluster = 'treasurycluster'
ORDER BY query_create_time DESC
LIMIT 10;

-- 查看 DDL 任务的详细执行状态
-- 【原理】每个 DDL 任务在各节点的执行状态
SELECT 
    query,
    status,
    initiator_host,
    query_create_time
FROM system.distributed_ddl_queue
WHERE status != 'Finished'
ORDER BY query_create_time DESC;

-- -----------------------------------------------------
-- 【场景】安全地执行 DDL
-- -----------------------------------------------------
-- 【坑】ON CLUSTER 可能部分节点成功部分节点失败
-- 失败原因:
--   1. 目标节点宕机
--   2. 版本不一致（某些语法旧版本不支持）
--   3. 表已存在/不存在
--   4. 权限不足
--   5. Keeper 不可用

-- 安全做法 1: 使用 IF NOT EXISTS / IF EXISTS
-- 【最佳实践】避免因表存在/不存在导致 DDL 失败
CREATE TABLE IF NOT EXISTS ddl_test.safe_table ON CLUSTER treasurycluster
(
    id UInt64,
    data String
)
ENGINE = ReplicatedMergeTree
ORDER BY id;

-- 安全做法 2: 使用 SYNC 等待所有节点完成
-- 【原理】SYNC 让 DDL 等待所有节点执行完成再返回
-- 默认 ON CLUSTER 是异步的，返回后可能仍有节点未执行
-- SYNC 会阻塞直到所有节点都完成（或超时）
ALTER TABLE ddl_test.safe_table ON CLUSTER treasurycluster
ADD COLUMN IF NOT EXISTS new_column String;

-- 安全做法 3: 分批执行而非 ON CLUSTER
-- 【场景】大规模集群或跨地域集群，ON CLUSTER 可能超时
-- 手动在各节点逐个执行更可控

-- 安全做法 4: 先检查再执行
-- 【最佳实践】DDL 前检查集群状态
SELECT 
    hostName() AS host,
    count() AS table_count
FROM clusterAllReplicas(treasurycluster, system.tables)
WHERE database = 'ddl_test'
GROUP BY host;

-- -----------------------------------------------------
-- 【坑】跨集群 DDL 的陷阱
-- -----------------------------------------------------
-- 1. "ON CLUSTER 是原子操作"
--    实际: 逐个节点执行，可能部分成功部分失败
--    需要检查 system.distributed_ddl_queue 确认
--
-- 2. "DDL 失败后数据会自动回滚"
--    实际: ClickHouse 不支持 DDL 回滚
--    已成功的节点不会回退，需要手动修复失败的节点
--
-- 3. "SYNC 一定可靠"
--    实际: SYNC 有超时，超时后仍可能部分节点未执行
--    需要主动检查 DDL 队列状态
--
-- 4. "版本不一致不影响 DDL"
--    实际: 新版本语法在旧版本上可能执行失败
--    生产环境应确保所有节点版本一致
--
-- 5. "ON CLUSTER DROP TABLE 很安全"
--    实际: DROP TABLE 会删除所有节点数据
--    建议: 先确认集群状态，再执行 DROP

-- -----------------------------------------------------
-- 【场景】DDL 失败后的修复流程
-- -----------------------------------------------------
-- 场景: ON CLUSTER ADD COLUMN 在某节点失败
-- 修复步骤:
--   1. 检查 DDL 队列，确认失败节点
--   2. 在失败节点上单独执行 ALTER
--   3. 验证所有节点结构一致

-- 步骤 1: 检查 DDL 队列中的失败任务
-- 【兼容性】25.12 无 database 列，改用 cluster 过滤；clock_time → query_create_time
SELECT 
    query,
    status,
    initiator_host,
    query_create_time
FROM system.distributed_ddl_queue
WHERE cluster = 'treasurycluster' AND status != 'Finished';

-- 步骤 2: 在失败节点上单独执行（假设 node2 失败）
-- 连接到 node2 执行:
-- ALTER TABLE ddl_test.sample_table ADD COLUMN IF NOT EXISTS description String;

-- 步骤 3: 验证所有节点结构一致
-- 【最佳实践】DDL 后必须验证一致性
SELECT 
    hostName() AS host,
    name AS column_name,
    type,
    default_expression
FROM clusterAllReplicas(treasurycluster, system.columns)
WHERE database = 'ddl_test' AND table = 'sample_table'
ORDER BY host, column_name;

-- -----------------------------------------------------
-- 【对比】ON CLUSTER vs 手动逐节点
-- -----------------------------------------------------
-- +------------------+------------------+------------------+
-- | 特性              | ON CLUSTER       | 手动逐节点        |
-- +------------------+------------------+------------------+
-- | 便捷性            | 高，一条命令      | 低，需要连接每个节点|
-- | 一致性            | 最终一致          | 可控制执行顺序    |
-- | 错误处理          | 自动跳过失败节点   | 及时发现和处理    |
-- | 回滚              | 不支持            | 可手动控制        |
-- | 大规模集群        | 可能超时          | 更可控            |
-- +------------------+------------------+------------------+
--
-- 推荐: 日常 DDL 用 ON CLUSTER，关键 DDL 用 SYNC + 验证
-- 超大规模集群（> 50 节点）: 分批逐节点执行

-- -----------------------------------------------------
-- 3. 分布式 DDL 的权限控制
-- -----------------------------------------------------
-- 【原理】ON CLUSTER DDL 需要用户有全局权限
-- 如果没有 GRANT ON CLUSTER，DDL 可能失败

-- 查看当前用户权限
-- 注意: 需要 system.grants 表存在
SELECT 
    user_name,
    access_type,
    database,
    table
FROM system.grants
WHERE user_name = currentUser();

-- -----------------------------------------------------
-- 4. 跨集群 DDL 最佳实践总结
-- -----------------------------------------------------
-- 1. 始终用 IF NOT EXISTS / IF EXISTS
-- 2. 关键 DDL 用 SYNC 等待完成
-- 3. DDL 后检查 system.distributed_ddl_queue
-- 4. 验证所有节点结构一致
-- 5. 确保所有节点版本一致
-- 6. 大规模集群分批执行
-- 7. DROP TABLE 前确认影响范围
-- 8. 定期监控 DDL 队列积压

-- -----------------------------------------------------
-- 清理
-- -----------------------------------------------------
DROP TABLE IF EXISTS ddl_test.sample_table ON CLUSTER treasurycluster SYNC;
DROP TABLE IF EXISTS ddl_test.safe_table ON CLUSTER treasurycluster SYNC;
DROP DATABASE IF EXISTS ddl_test ON CLUSTER treasurycluster;

-- 与开头 ON CLUSTER 建库对应，DROP 也须 ON CLUSTER，避免 clickhouse2 残留
DROP DATABASE IF EXISTS distributed_test ON CLUSTER treasurycluster;