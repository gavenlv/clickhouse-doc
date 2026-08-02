/*
 * 10_system_queries.sql — 系统表查询入门
 *
 * 【本章解决什么问题】
 *   ClickHouse 把所有运行时状态都暴露在 system 库下。读完本章你应能：
 *   - 知道"哪里出问题该查哪张 system 表"（诊断地图）
 *   - 读懂集群拓扑、副本健康、part 数量、merge 进度
 *   - 用 system.query_thread_log 定位慢查询（本集群 query_log 已禁用）
 *
 * 【运行环境】
 *   - 集群：treasurycluster（CH 25.12.1.649）
 *   - 数据库：getting_started_test
 *   - 执行：clickhouse-server-1 容器内 clickhouse-client --multiquery
 *
 * 【CH 25.12 兼容性】
 *   - system.tables 的列名是 `name` 不是 `table`
 *   - mutation_version 已重命名为 data_version
 *   - ttl_info 已重命名为 delete_ttl_info_min/max
 *   - system.query_log 在本集群已禁用，改用 system.query_thread_log
 */

-- ============================================================================
-- §0. 准备：独立数据库，避免与其他章节冲突
-- ============================================================================
DROP DATABASE IF EXISTS getting_started_test;
CREATE DATABASE getting_started_test;
USE getting_started_test;

-- ============================================================================
-- §1. system.clusters —— 集群拓扑与节点健康
-- ============================================================================
-- 【原理】system.clusters 列出所有配置的集群及其分片/副本
-- 【场景】部署后验证集群拓扑；故障时检查节点是否掉线

SELECT
    cluster,          -- 集群名
    shard_num,        -- 分片编号
    replica_num,      -- 副本编号
    host_name,        -- 主机名
    host_address,    -- IP 地址
    port,             -- native 协议端口
    is_local,         -- 是否当前节点
    user              -- 用于连接的用户
FROM system.clusters
WHERE cluster = 'treasurycluster'
ORDER BY shard_num, replica_num;

-- 【对比】本地节点 vs 远程节点：is_local=1 是当前节点，其他是远程
-- 【坑】如果 host_address 是 IPv6，但 Docker 网络只支持 IPv4，会连不上

-- ============================================================================
-- §2. system.replicas —— 副本健康风向标
-- ============================================================================
-- 【原理】每张 ReplicatedMergeTree 表在 system.replicas 有一行
-- 【场景】复制延迟排查；is_readonly=1 时无法写入，需立即处理

-- 先创建一张复制表用于演示
CREATE TABLE IF NOT EXISTS replica_demo
(
    id UInt64,
    event_time DateTime DEFAULT now()
) ENGINE = ReplicatedMergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY id;

INSERT INTO replica_demo (id) VALUES (1), (2), (3);

SELECT
    database,
    table,
    replica_name,        -- 当前副本名
    is_leader,           -- 是否主副本（负责触发 merge）
    is_readonly,         -- 是否只读（Keeper 连不上时为 1）
    is_session_expired,  -- 会话是否过期
    future_parts,        -- 待生成的 part 数
    queue_size,          -- 复制队列大小（持续高 = 积压）
    active_replicas,     -- 活跃副本数
    total_replicas,      -- 总副本数
    absolute_delay       -- 复制延迟（秒）
FROM system.replicas
WHERE table = 'replica_demo';

-- 【坑】is_readonly=1 的常见原因：
--   1. Keeper 集群不可达（检查 system.zookeeper_connection）
--   2. 副本元数据损坏（极少见）
--   3. 手动设置为只读：SYSTEM STOP REPLICATED SENDS（不应在正常生产中使用）

-- ============================================================================
-- §3. system.parts —— Part 管理与监控
-- ============================================================================
-- 【原理】每个 part 一行；active=1 是活跃 part，active=0 是待清理
-- 【场景】监控 part 数量；排查 "Too many parts" 异常

SELECT
    database,
    table,
    partition,           -- 分区名
    count() AS parts,    -- part 数量
    sum(rows) AS total_rows,
    formatReadableSize(sum(bytes_on_disk)) AS disk_size,
    min(min_block_number) AS min_block,
    max(max_block_number) AS max_block
FROM system.parts
WHERE database = 'getting_started_test'
  AND table = 'replica_demo'
  AND active = 1
GROUP BY database, table, partition
ORDER BY partition;

-- 【对比】active=1 vs active=0：
--   active=1：当前查询可见
--   active=0：merge 后的旧 part，等待清理（默认保留 8 分钟）

-- 监控警报阈值（生产经验）
-- 单表活跃 part > 1000：警告
-- 单表活跃 part > 5000：危险（接近 Too many parts）
SELECT
    database, table,
    countIf(active = 1) AS active_parts,
    countIf(active = 0) AS inactive_parts
FROM system.parts
WHERE database = 'getting_started_test'
GROUP BY database, table
ORDER BY active_parts DESC;

-- ============================================================================
-- §4. system.merges —— 后台合并进度
-- ============================================================================
-- 【原理】正在执行的 merge 任务列表
-- 【场景】merge 卡住排查；预估 merge 完成时间

-- 触发一些 merge（先插入多个小批量）
INSERT INTO replica_demo (id) VALUES (4), (5);
INSERT INTO replica_demo (id) VALUES (6), (7);
INSERT INTO replica_demo (id) VALUES (8), (9);

-- 查看正在进行的 merge（可能为空，因为数据量小 merge 很快）
SELECT
    database,
    table,
    elapsed,             -- 已耗时（秒）
    progress,            -- 进度 0-1
    num_parts,           -- 合并的 part 数
    result_part_name,    -- 合并后的 part 名
    source_part_paths    -- 源 part 路径
FROM system.merges
WHERE database = 'getting_started_test'
FORMAT Vertical;

-- 【坑】merge 太慢的常见原因：
--   1. 磁盘 IO 瓶颈（用 system.disks 看 IO）
--   2. part 太多（用 OPTIMIZE FINAL 强制合并，但会锁表）
--   3. 资源不足（调大 max_server_memory_usage）

-- ============================================================================
-- §5. system.query_thread_log —— 慢查询分析（query_log 替代方案）
-- ============================================================================
-- 【原理】每条查询的每个线程记录一行，含耗时、内存、扫描行数
-- 【场景】找出最慢的查询；定位内存/CPU 消耗大户
-- 【注意】本集群 query_log 已禁用（<query_log remove="1"/>）
--        启用 query_thread_log：SET log_query_threads = 1

-- 启用线程级查询日志
SET log_query_threads = 1;

-- 执行一个测试查询
SELECT count(), avg(id) FROM replica_demo;

-- 查看最近的查询（在 system.query_thread_log 中）
-- 【坑】query_thread_log 是异步写入，需要等几秒才能查到
SELECT
    event_time,
    query_duration_ms,        -- 查询耗时（毫秒）
    read_rows,                -- 读取行数
    read_bytes,               -- 读取字节
    memory_usage,             -- 内存使用（字节）
    query_id,                 -- 查询 ID
    thread_id,                -- 线程 ID
    substring(query, 1, 80) AS query_preview
FROM system.query_thread_log
WHERE event_time > now() - INTERVAL 5 MINUTE
  AND query NOT LIKE '%system.%'
ORDER BY query_duration_ms DESC
LIMIT 10;

-- 【对比】query_log vs query_thread_log：
--   query_log：一条查询一行（聚合后）
--   query_thread_log：一条查询多行（每个线程一行）
--   生产推荐：query_thread_log 更细，能定位单线程瓶颈

-- Top 10 最慢查询（按平均耗时）
SELECT
    substring(query, 1, 60) AS query_preview,
    count() AS executions,
    avg(query_duration_ms) AS avg_ms,
    max(query_duration_ms) AS max_ms,
    sum(read_rows) AS total_rows_read
FROM system.query_thread_log
WHERE event_time > now() - INTERVAL 1 HOUR
  AND type = 'QueryStart'  -- 仅查询开始事件
GROUP BY query_preview
ORDER BY avg_ms DESC
LIMIT 10;

-- ============================================================================
-- §6. system.dictionaries —— 字典状态
-- ============================================================================
-- 【原理】外部/内置字典的加载状态
-- 【场景】字典未加载排查；字典内存占用监控

-- 创建一个字典演示
CREATE DICTIONARY IF NOT EXISTS user_dict
(
    user_id UInt64,
    user_name String,
    country String
)
PRIMARY KEY user_id
SOURCE(CLICKHOUSE(TABLE 'users_dim' DB 'getting_started_test'))
LAYOUT(HASHED())
LIFETIME(MIN 300 MAX 3600);

-- 查看所有字典状态
SELECT
    database,
    name,                       -- 字典名
    type,                       -- 字典类型
    origin,                     -- 来源
    lifetime_min, lifetime_max, -- 生命周期
    loading_start_time,         -- 加载开始时间
    loading_duration_ms,        -- 加载耗时
    last_successful_update_time,-- 最后成功更新时间
    status                      -- 状态：LOADED/FAILED/NOT_LOADED
FROM system.dictionaries
WHERE database = 'getting_started_test'
FORMAT Vertical;

-- 【坑】status=FAILED 的常见原因：
--   1. 源表不存在（SOURCE 配置错误）
--   2. 源表无数据
--   3. 网络问题（远程源）

-- ============================================================================
-- §7. 系统表组合诊断 —— 一图看清集群健康
-- ============================================================================
-- 综合查询：集群拓扑 + 副本状态 + part 数 + 磁盘使用

-- 7.1 集群节点 + 副本健康
SELECT
    c.host_name,
    c.shard_num,
    c.replica_num,
    c.is_local,
    (SELECT count() FROM system.replicas WHERE is_readonly = 1) AS readonly_tables,
    (SELECT count() FROM system.replicas WHERE absolute_delay > 60) AS lagged_replicas
FROM system.clusters c
WHERE c.cluster = 'treasurycluster'
ORDER BY c.shard_num, c.replica_num;

-- 7.2 各表 part 数量 + 磁盘占用
SELECT
    database,
    table,
    countIf(active = 1) AS active_parts,
    formatReadableSize(sum(bytes_on_disk)) AS total_size,
    sum(rows) AS total_rows
FROM system.parts
WHERE database = 'getting_started_test'
  AND active = 1
GROUP BY database, table
ORDER BY total_size DESC;

-- 7.3 磁盘使用率
SELECT
    name,
    path,
    formatReadableSize(free_space) AS free,
    formatReadableSize(total_space) AS total,
    formatReadableSize(keep_free_space) AS keep_free,
    round(free_space / total_space * 100, 2) AS free_pct,
    type
FROM system.disks
FORMAT Vertical;

-- 7.4 Keeper 连接状态
SELECT
    name,
    host,
    port,
    status,              -- ok/failed
    client_id,
    session_id,
    xid,
    watches_count
FROM system.zookeeper_connection
FORMAT Vertical;

-- 【场景】巡检脚本：每天跑一次，发邮件告警
-- 警报条件：
--   readonly_tables > 0
--   lagged_replicas > 0
--   任一表 active_parts > 1000
--   任一磁盘 free_pct < 10
--   Keeper status != 'ok'

-- ============================================================================
-- §8. 清理
-- ============================================================================
DROP DICTIONARY IF EXISTS user_dict;
DROP TABLE IF EXISTS replica_demo;
DROP DATABASE IF EXISTS getting_started_test;

-- ============================================================================
-- §9. 自测题
-- ============================================================================
-- 1. system.clusters 的 is_local=1 意味着什么？为什么需要这个字段？
-- 2. system.replicas 中 is_readonly=1 时会发生什么？常见原因有哪些？
-- 3. system.parts 的 active=0 是什么意思？为什么 CH 要保留这些 part？
-- 4. 单表 active_parts > 1000 意味着什么？该如何处理？
-- 5. 本集群为什么用 system.query_thread_log 而不是 system.query_log？
-- 6. system.dictionaries 的 status=FAILED 该如何排查？
-- 7. 巡检脚本应该检查哪 5 个核心指标？
