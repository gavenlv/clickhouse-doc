
-- ================================================================================
-- ClickHouse 异步操作优化示例
-- ================================================================================
-- 
-- 集群: treasurycluster (2 副本)
-- 预计学习时间: 15 分钟
-- 
-- 本文件涵盖:
--   1. 异步插入 - async_insert 配置与使用
--   2. 异步查询 - HTTP 异步查询接口
--   3. 异步物化视图 - 后台数据聚合
--   4. 异步 Mutation - mutations_sync 设置
--   5. 异步操作监控 - 查看状态与性能
-- 
-- 异步操作架构:
-- 
--   ┌─────────────────────────────────────────────────────────────────────────┐
--   │                    ClickHouse 异步操作概览                              │
--   └─────────────────────────────────────────────────────────────────────────┘
--   
--   ┌─────────────────────────────────────────────────────────────────────────┐
--   │                           同步 vs 异步                                  │
--   └─────────────────────────────────────────────────────────────────────────┘
--   
--   同步操作:
--   客户端 ──INSERT──> ClickHouse ──写入──> 磁盘 ──确认──> 客户端
--          │                                              │
--          └──────────── 阻塞等待 ────────────────────────┘
--   
--   异步操作:
--   客户端 ──INSERT──> ClickHouse ──立即返回──> 客户端
--          │                │
--          │                └── 后台异步写入 ──> 磁盘
--          └──────────────── 不阻塞 ────────────┘
-- 
-- 异步插入配置:
-- 
--   ┌─────────────────────────────────────────────────────────────────────────┐
--   │                     async_insert 关键参数                               │
--   └─────────────────────────────────────────────────────────────────────────┘
--   
--   async_insert = 1                启用异步插入
--   wait_for_async_insert = 0/1     是否等待插入完成
--   async_insert_max_data_size      触发写入的数据量阈值
--   async_insert_busy_timeout_ms    等待更多数据的超时
--   async_insert_max_wait_time_ms   最大等待时间
--   
--   触发条件:
--   ┌─────────────────────────────────────────────────────────────────────────┐
--   │                                                                         │
--   │    数据量达到 async_insert_max_data_size                                │
--   │           OR                                                            │
--   │    时间达到 async_insert_busy_timeout_ms                                │
--   │           OR                                                            │
--   │    等待时间达到 async_insert_max_wait_time_ms                           │
--   │                                                                         │
--   │    ─────────────────────────────────────────────────────────────────    │
--   │                         ↓                                               │
--   │                    执行批量写入                                          │
--   │                                                                         │
--   └─────────────────────────────────────────────────────────────────────────┘
-- 
-- Mutation 同步级别:
-- 
--   ┌─────────────────────────────────────────────────────────────────────────┐
--   │                    mutations_sync 级别说明                              │
--   └─────────────────────────────────────────────────────────────────────────┘
--   
--   mutations_sync = 0  (异步, 默认)
--   ┌──────────┐    ┌──────────┐
--   │ 发起     │───>│ 立即返回 │
--   │ Mutation │    │          │
--   └──────────┘    └──────────┘
--                        │
--                        └──> 后台执行
--   
--   mutations_sync = 1  (等待当前分片)
--   ┌──────────┐    ┌──────────┐    ┌──────────┐
--   │ 发起     │───>│ 等待当前 │───>│ 返回     │
--   │ Mutation │    │ 分片完成 │    │          │
--   └──────────┘    └──────────┘    └──────────┘
--   
--   mutations_sync = 2  (等待所有副本)
--   ┌──────────┐    ┌──────────┐    ┌──────────┐
--   │ 发起     │───>│ 等待所有 │───>│ 返回     │
--   │ Mutation │    │ 副本完成 │    │          │
--   └──────────┘    └──────────┘    └──────────┘
-- 
-- ================================================================================
-- §0. 准备演示数据
-- ================================================================================
-- 本文件依赖 events / users 两张表，先自建并填充，保证可独立重复运行
DROP TABLE IF EXISTS user_stats_mv_async;
DROP TABLE IF EXISTS users;
CREATE TABLE users
(
    user_id UInt64,
    username String,
    email String,
    status String,
    created_at DateTime
)
ENGINE = MergeTree()
ORDER BY user_id;

INSERT INTO users
SELECT
    number + 1 AS user_id,
    concat('user_', toString(number + 1)) AS username,
    concat('user_', toString(number + 1), '@example.com') AS email,
    'active' AS status,
    now() AS created_at
FROM numbers(1000);

DROP TABLE IF EXISTS events;
CREATE TABLE events
(
    event_id UInt64,
    user_id UInt32,
    event_type String,
    event_time DateTime,
    event_data String
)
ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (user_id, event_time);

INSERT INTO events
SELECT
    number + 1 AS event_id,
    (number % 1000) + 1 AS user_id,
    ['click', 'view', 'purchase'][number % 3 + 1] AS event_type,
    toDateTime('2024-01-10 00:00:00') + INTERVAL number MINUTE AS event_time,
    concat('{"page":"/p', toString(number % 10), '"}') AS event_data
FROM numbers(10000);

-- ================================================================================

-- 查询级别配置
INSERT INTO events
SETTINGS async_insert = 1,
        wait_for_async_insert = 0,
        async_insert_max_data_size = 100000000,
        async_insert_busy_timeout_ms = 5000,
        async_insert_stale_timeout_ms = 10000
VALUES (1, 100, 'click', now(), '{}');

-- ========================================
-- 配置异步插入
-- ========================================

-- 示例 1: 不等待插入完成
INSERT INTO events
SETTINGS async_insert = 1,
        wait_for_async_insert = 0
VALUES (1, 100, 'click', now(), '{}');

-- 示例 2: 等待插入完成
INSERT INTO events
SETTINGS async_insert = 1,
        wait_for_async_insert = 1,
        async_insert_stale_timeout_ms = 5000
VALUES (2, 100, 'view', now(), '{}');

-- 示例 3: 批量异步插入
INSERT INTO events
SETTINGS async_insert = 1,
        wait_for_async_insert = 0,
        async_insert_max_data_size = 100000000
VALUES (3, 101, 'click', now(), '{}'),
       (4, 102, 'click', now(), '{}'),
       (5, 103, 'click', now(), '{}'),
       -- ... 10000 行
       (10000, 1100, 'click', now(), '{}');

-- ========================================
-- 配置异步插入
-- ========================================

-- 示例 1: 使用 HTTP 接口异步查询
-- （shell 命令示例，SQL 文件中仅作说明，不可直接执行）
-- curl 'http://localhost:8123/?query=SELECT+sleep(1)&wait_end_of_query=0&query_id=async_query_1'

-- 示例 2: 检查查询状态
-- curl 'http://localhost:8123/?query=SELECT+*+FROM+system.query_log+WHERE+query_id+=+async_query_1'

-- 示例 3: 获取查询结果
-- curl 'http://localhost:8123/?query=SELECT+*+FROM+system.query_log+WHERE+query_id+=+async_query_1+AND+type+=+QueryFinish'

-- ========================================
-- 配置异步插入
-- ========================================

-- 创建异步 Materialize 视图
CREATE MATERIALIZED VIEW user_stats_mv_async
ENGINE = AggregatingMergeTree()
ORDER BY (user_id, date)
POPULATE
AS SELECT
    user_id,
    toDate(event_time) as date,
    countState() as event_count,
    sumState(event_id) as total_event_id  -- 演示用：events 无金额列，对 event_id 求和
FROM events
GROUP BY user_id, date
SETTINGS max_insert_threads = 2;  -- 并行写入物化视图（mv_insert_thread 不是有效设置）

-- ========================================
-- 配置异步插入
-- ========================================

-- 全局配置（在 config.xml 中）

-- 查询级别配置
ALTER TABLE users
UPDATE status = 'active'
WHERE user_id IN (1, 2, 3)
SETTINGS mutations_sync = 0;  -- 0: 异步, 1: 等待当前分片, 2: 等待所有分片

-- ========================================
-- 配置异步插入
-- ========================================

-- 示例 1: 异步 Mutation
ALTER TABLE users
UPDATE status = 'active'
WHERE user_id IN (1, 2, 3)
SETTINGS mutations_sync = 0;

-- 示例 2: 等待当前分片
ALTER TABLE users
UPDATE status = 'active'
WHERE user_id IN (1, 2, 3)
SETTINGS mutations_sync = 1;

-- 示例 3: 等待所有分片
ALTER TABLE users
UPDATE status = 'active'
WHERE user_id IN (1, 2, 3)
SETTINGS mutations_sync = 2;

-- ========================================
-- 配置异步插入
-- ========================================

-- 查看异步插入统计
-- [需启用] 本集群 config 禁用了 query_log，system.query_log 不存在；
-- 生产环境启用 query_log 后运行以下查询（保留原文）：
-- SELECT 
--     event_time,
--     type,
--     query_duration_ms,
--     async_insert_wait_time_ms,
--     async_insert_busy_wait_time_ms,
--     async_insert_success,
--     async_insert_failed
-- FROM system.query_log
-- WHERE type = 'QueryFinish'
--   AND query LIKE '%async_insert%'
--   AND event_time >= now() - INTERVAL 24 HOUR
-- ORDER BY event_time DESC
-- LIMIT 20;

-- ========================================
-- 配置异步插入
-- ========================================

-- 查看异步查询状态
-- [需启用] 本集群禁用了 query_log（同上，生产启用后运行）：
-- SELECT 
--     query_id,
--     query,
--     type,
--     event_time,
--     query_duration_ms,
--     exception_text
-- FROM system.query_log
-- WHERE query_id LIKE 'async%'
-- ORDER BY event_time DESC
-- LIMIT 20;

-- ========================================
-- 配置异步插入
-- ========================================

-- 查看 Mutation 状态
-- 说明: 25.12 的 system.mutations 列名为 create_time / latest_fail_reason（无 progress/created_at/done_at）
SELECT 
    database,
    table,
    mutation_id,
    command,
    is_done,
    parts_to_do,
    latest_fail_reason
FROM system.mutations
ORDER BY create_time DESC
LIMIT 20;

-- ========================================
-- 配置异步插入
-- ========================================

-- ✅ 合理的异步插入配置
INSERT INTO events
SETTINGS async_insert = 1,
        wait_for_async_insert = 0,
        async_insert_max_data_size = 100000000,  -- 100 MB
        async_insert_busy_timeout_ms = 5000,
        async_insert_stale_timeout_ms = 10000
VALUES (999, 100, 'click', now(), '{}');

-- ========================================
-- 配置异步插入
-- ========================================

-- 定期监控异步操作
-- [需启用] 本集群禁用了 query_log（同上，生产启用后运行）：
-- SELECT 
--     type,
--     count() as count,
--     avg(query_duration_ms) as avg_duration,
--     max(query_duration_ms) as max_duration
-- FROM system.query_log
-- WHERE event_time >= now() - INTERVAL 24 HOUR
--   AND (query LIKE '%async%' OR type LIKE 'Mutation%')
-- GROUP BY type
-- ORDER BY count DESC;

-- ========================================
-- 配置异步插入
-- ========================================

-- 查看失败的异步操作
-- [需启用] 本集群禁用了 query_log（同上，生产启用后运行）：
-- SELECT 
--     query_id,
--     query,
--     exception_code,
--     exception_text
-- FROM system.query_log
-- WHERE type = 'ExceptionWhileProcessing'
--   AND query LIKE '%async%'
--   AND event_time >= now() - INTERVAL 24 HOUR
-- ORDER BY event_time DESC
-- LIMIT 20;
