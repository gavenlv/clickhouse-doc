-- ================================================
-- 07_asynchronous_operations_examples.sql
-- 从 07_asynchronous_operations.md 提取的 SQL 示例
-- 提取时间: 2026-01-23 14:40:17
-- ================================================


-- ========================================
-- 配置异步插入
-- ========================================

-- 全局配置（在 config.xml 中）
<clickhouse>
    <async_insert>1</async_insert>
    <async_insert_max_data_size>100000000</async_insert_max_data_size>
    <async_insert_busy_timeout_ms>5000</async_insert_busy_timeout_ms>
    <async_insert_max_wait_time_ms>10000</async_insert_max_wait_time_ms>
</clickhouse>

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
<clickhouse>
    <mutations_sync>0</mutations_sync>
    <background_pool_size>16</background_pool_size>
</clickhouse>

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
