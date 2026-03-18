-- ================================================================================
-- 方案B：多分片架构优化方案
-- ================================================================================
-- 
-- 集群: treasurycluster_4shards (4分片×2副本 = 8节点)
-- 预计学习时间: 30 分钟
-- 
-- 本文件涵盖:
--   1. 多分片架构设计 - 数据分片策略与分布
--   2. 本地表与分布式表 - ReplicatedMergeTree + Distributed
--   3. 分布式导入策略 - 自动分片vs手动分片导入
--   4. 性能监控查询 - 分片级别进度监控
--   5. 数据分布验证 - 各分片数据均衡检查
--   6. 故障恢复方案 - 副本修复与数据同步
-- 
-- 目标: 2-3分钟完成150亿行数据导入
-- 架构: 4分片×2副本 = 8节点
-- 成本: $1,780/月（经济版）或$1,474/月（超经济版）
-- 
-- ┌─────────────────────────────────────────────────────────────────────────────┐
-- │                      多分片架构拓扑                                          │
-- ├─────────────────────────────────────────────────────────────────────────────┤
-- │                                                                             │
-- │  ┌─────────────────────────────────────────────────────────────────────┐   │
-- │  │                     Distributed Table (target_table_all)            │   │
-- │  │                              (逻辑入口)                               │   │
-- │  └──────────────────────────────┬──────────────────────────────────────┘   │
-- │                                 │ 自动路由                                  │
-- │                 ┌───────────────┼───────────────┐                          │
-- │                 │               │               │                          │
-- │                 ▼               ▼               ▼                          │
-- │  ┌─────────────────┐ ┌─────────────────┐ ┌─────────────────┐              │
-- │  │   Shard 1       │ │   Shard 2       │ │   Shard 3,4...  │              │
-- │  │  ┌─────┬─────┐  │ │  ┌─────┬─────┐  │ │  ┌─────┬─────┐  │              │
-- │  │  │Rep1 │Rep2 │  │ │  │Rep1 │Rep2 │  │ │  │Rep1 │Rep2 │  │              │
-- │  │  │     │     │  │ │  │     │     │  │ │  │     │     │  │              │
-- │  │  └─────┴─────┘  │ │  └─────┴─────┘  │ │  └─────┴─────┘  │              │
-- │  │  本地表(25%数据)│ │  本地表(25%数据)│ │  本地表(50%数据)│              │
-- │  └─────────────────┘ └─────────────────┘ └─────────────────┘              │
-- │                                                                             │
-- │  数据分布: 150亿行 / 4分片 = 37.5亿行/分片                                    │
-- │  并行写入: 4分片同时处理 = 4倍加速                                            │
-- │                                                                             │
-- └─────────────────────────────────────────────────────────────────────────────┘
-- 
-- ┌─────────────────────────────────────────────────────────────────────────────┐
-- │                      方案A vs 方案B 对比                                      │
-- ├─────────────────────────────────────────────────────────────────────────────┤
-- │                                                                             │
-- │  维度           方案A (单分片)         方案B (多分片)                        │
-- │  ────────────────────────────────────────────────────────────────────────  │
-- │  导入时间       8-12分钟               2-3分钟                              │
-- │  节点数         2节点                  8节点                                │
-- │  总CPU核心      64核                   128核                                │
-- │  月成本         $830-1,460             $1,474-1,780                        │
-- │  架构复杂度     低                     中                                   │
-- │  运维成本       低                     中                                   │
-- │  扩展性         有限                   良好                                 │
-- │  适用场景       快速上线               长期稳定使用                          │
-- │                                                                             │
-- │  推荐选择:                                                                    │
-- │  - 预算 <$1,500/月 → 方案A                                                  │
-- │  - 需要快速导入 → 方案B                                                      │
-- │  - 长期生产使用 → 方案B                                                      │
-- │                                                                             │
-- └─────────────────────────────────────────────────────────────────────────────┘
-- 
-- ================================================================================

-- ========================================
-- 1. 方案概述
-- ========================================
/*
【核心策略】
1. 数据分片：按分区键分布到4个分片
2. 并行写入：4个分片同时处理数据
3. 分布式表：通过Distributed表自动路由
4. 负载均衡：写入压力分散到4个分片

【性能提升来源】
- 并行度提升：4倍（4个分片同时处理）
- CPU利用率提升：从单节点32核到8节点128核
- 网络带宽提升：GCS到多节点的并行传输

【适用场景】
- 需要2-3分钟快速导入
- 预算在$1,500-2,000/月
- 长期稳定使用
- 可接受架构改造
*/

-- ========================================
-- 2. 集群配置验证
-- ========================================

-- 2.1 检查集群状态（4分片×2副本）
SELECT 
    cluster,
    shard_num,
    replica_num,
    host_name,
    host_address,
    port
FROM system.clusters
WHERE cluster = 'treasurycluster_4shards'  -- 新集群名称
ORDER BY shard_num, replica_num;

-- 预期输出：
-- shard_num=1, replica_num=1, clickhouse-shard1-replica1
-- shard_num=1, replica_num=2, clickhouse-shard1-replica2
-- shard_num=2, replica_num=1, clickhouse-shard2-replica1
-- shard_num=2, replica_num=2, clickhouse-shard2-replica2
-- shard_num=3, replica_num=1, clickhouse-shard3-replica1
-- shard_num=3, replica_num=2, clickhouse-shard3-replica2
-- shard_num=4, replica_num=1, clickhouse-shard4-replica1
-- shard_num=4, replica_num=2, clickhouse-shard4-replica2

-- ========================================
-- 3. 创建本地表和分布式表
-- ========================================

-- 3.1 创建数据库
CREATE DATABASE IF NOT EXISTS bulk_import_plan_b ON CLUSTER 'treasurycluster_4shards';

-- 3.2 创建本地表（每个分片上的物理表）
CREATE TABLE IF NOT EXISTS bulk_import_plan_b.target_table_local ON CLUSTER 'treasurycluster_4shards' (
    event_id String,
    event_type String,
    event_time DateTime,
    user_id UInt64,
    -- ... 其他86列 ...
    col87 String,
    col88 Float64,
    col89 UInt64,
    col90 DateTime
) ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/bulk_import_plan_b/target_table_local', '{replica}')
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_time, user_id, event_id)
SETTINGS 
    index_granularity = 8192,
    min_bytes_for_wide_part = '10M';

-- 3.3 创建分布式表（逻辑入口）
CREATE TABLE IF NOT EXISTS bulk_import_plan_b.target_table_all ON CLUSTER 'treasurycluster_4shards'
AS bulk_import_plan_b.target_table_local
ENGINE = Distributed('treasurycluster_4shards', 'bulk_import_plan_b', 'target_table_local', rand());

-- ========================================
-- 4. 分布式导入策略
-- ========================================

-- 4.1 策略1：直接写入分布式表（自动分片）
INSERT INTO bulk_import_plan_b.target_table_all
SETTINGS 
    max_insert_threads = 12,                    -- 每节点12线程（16核的75%）
    max_insert_block_size = 1048576,
    min_insert_block_size_rows = 1000000,
    prefer_localhost_replica = 0,               -- 分布式写入
    insert_distributed_sync = 2,                -- 同步写入所有分片
    insert_quorum = 2                           -- 等待2副本确认
SELECT * FROM gcs(
    'https://storage.googleapis.com/your-bucket/data/**/*.parquet',
    'Parquet'
);

-- 4.2 策略2：分片并行导入（推荐，最高性能）
-- 在不同节点上并行导入不同分片的数据

-- 分片1数据导入
INSERT INTO bulk_import_plan_b.target_table_local
SETTINGS max_insert_threads = 12
SELECT * FROM gcs(
    'https://storage.googleapis.com/your-bucket/data/shard=1/*.parquet',
    'Parquet'
);

-- 分片2数据导入
INSERT INTO bulk_import_plan_b.target_table_local
SETTINGS max_insert_threads = 12
SELECT * FROM gcs(
    'https://storage.googleapis.com/your-bucket/data/shard=2/*.parquet',
    'Parquet'
);

-- 分片3数据导入
INSERT INTO bulk_import_plan_b.target_table_local
SETTINGS max_insert_threads = 12
SELECT * FROM gcs(
    'https://storage.googleapis.com/your-bucket/data/shard=3/*.parquet',
    'Parquet'
);

-- 分片4数据导入
INSERT INTO bulk_import_plan_b.target_table_local
SETTINGS max_insert_threads = 12
SELECT * FROM gcs(
    'https://storage.googleapis.com/your-bucket/data/shard=4/*.parquet',
    'Parquet'
);

-- ========================================
-- 5. 性能监控
-- ========================================

-- 5.1 监控每个分片的导入进度
SELECT 
    shard_num,
    replica_num,
    host_name,
    formatReadableSize(sum(data_compressed_bytes)) as size,
    sum(rows) as rows
FROM system.clusters c
LEFT JOIN system.parts p ON p.database = 'bulk_import_plan_b' 
                         AND p.table = 'target_table_local'
                         AND p.active = 1
WHERE c.cluster = 'treasurycluster_4shards'
GROUP BY shard_num, replica_num, host_name
ORDER BY shard_num, replica_num;

-- 5.2 监控分布式写入状态
SELECT 
    query_id,
    query,
    read_rows,
    written_rows,
    memory_usage,
    query_duration_ms
FROM system.processes
WHERE query LIKE '%INSERT INTO bulk_import_plan_b%'
ORDER BY query_duration_ms DESC;

-- ========================================
-- 6. 验证数据分布
-- ========================================

-- 6.1 检查每个分片的数据量
SELECT 
    shard_num,
    count() as parts,
    sum(rows) as total_rows,
    formatReadableSize(sum(data_compressed_bytes)) as size
FROM system.parts
WHERE database = 'bulk_import_plan_b' 
  AND table = 'target_table_local'
  AND active = 1
GROUP BY shard_num
ORDER BY shard_num;

-- 6.2 通过分布式表查询总数据量
SELECT 
    count() as total_rows,
    min(event_time) as min_time,
    max(event_time) as max_time,
    uniqExact(user_id) as unique_users
FROM bulk_import_plan_b.target_table_all;

-- ========================================
-- 7. 故障恢复
-- ========================================

-- 7.1 检查副本状态
SELECT 
    database,
    table,
    replica_name,
    replica_path,
    total_replicas,
    active_replicas,
    queue_size,
    inserts_in_queue
FROM system.replicas
WHERE database = 'bulk_import_plan_b';

-- 7.2 修复副本
-- 如果某个副本数据不一致
SYSTEM RESTART REPLICA bulk_import_plan_b.target_table_local;

-- ========================================
-- 8. 清理示例
-- ========================================

-- 删除测试数据
DROP TABLE IF EXISTS bulk_import_plan_b.target_table_all ON CLUSTER 'treasurycluster_4shards';
DROP TABLE IF EXISTS bulk_import_plan_b.target_table_local ON CLUSTER 'treasurycluster_4shards';
DROP DATABASE IF EXISTS bulk_import_plan_b ON CLUSTER 'treasurycluster_4shards';
