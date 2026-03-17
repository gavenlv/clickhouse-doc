
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


-- 查询级别配置
INSERT INTO events
SETTINGS async_insert = 1,
        wait_for_async_insert = 0,
        async_insert_max_data_size = 100000000,
        async_insert_busy_timeout_ms = 5000,
        async_insert_max_wait_time_ms = 10000
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
        async_insert_max_wait_time_ms = 5000
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
curl 'http://localhost:8123/?query=SELECT+sleep(1)&wait_end_of_query=0&query_id=async_query_1'

-- 示例 2: 检查查询状态
curl 'http://localhost:8123/?query=SELECT+*+FROM+system.query_log+WHERE+query_id+=+async_query_1'

-- 示例 3: 获取查询结果
curl 'http://localhost:8123/?query=SELECT+*+FROM+system.query_log+WHERE+query_id+=+async_query_1+AND+type+=+QueryFinish'

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
    sumState(amount) as total_amount
FROM events
GROUP BY user_id, date
SETTINGS mv_insert_thread = 2;  -- 异步插入

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
SELECT 
    event_time,
    type,
    query_duration_ms,
    async_insert_wait_time_ms,
    async_insert_busy_wait_time_ms,
    async_insert_success,
    async_insert_failed
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query LIKE '%async_insert%'
  AND event_time >= now() - INTERVAL 24 HOUR
ORDER BY event_time DESC
LIMIT 20;

-- ========================================
-- 配置异步插入
-- ========================================

-- 查看异步查询状态
SELECT 
    query_id,
    query,
    type,
    event_time,
    query_duration_ms,
    exception_text
FROM system.query_log
WHERE query_id LIKE 'async%'
ORDER BY event_time DESC
LIMIT 20;

-- ========================================
-- 配置异步插入
-- ========================================

-- 查看 Mutation 状态
SELECT 
    database,
    table,
    mutation_id,
    command,
    is_done,
    parts_to_do,
    progress,
    created_at,
    done_at
FROM system.mutations
ORDER BY created DESC
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
        async_insert_max_wait_time_ms = 10000
VALUES (...);

-- ========================================
-- 配置异步插入
-- ========================================

-- 定期监控异步操作
SELECT 
    type,
    count() as count,
    avg(query_duration_ms) as avg_duration,
    max(query_duration_ms) as max_duration
FROM system.query_log
WHERE event_time >= now() - INTERVAL 24 HOUR
  AND (query LIKE '%async%' OR type LIKE 'Mutation%')
GROUP BY type
ORDER BY count DESC;

-- ========================================
-- 配置异步插入
-- ========================================

-- 查看失败的异步操作
SELECT 
    query_id,
    query,
    exception_code,
    exception_text
FROM system.query_log
WHERE type = 'ExceptionWhileProcessing'
  AND query LIKE '%async%'
  AND event_time >= now() - INTERVAL 24 HOUR
ORDER BY event_time DESC
LIMIT 20;
