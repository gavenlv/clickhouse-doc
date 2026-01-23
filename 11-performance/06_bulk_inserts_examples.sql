-- ================================================
-- 06_bulk_inserts_examples.sql
-- 从 06_bulk_inserts.md 提取的 SQL 示例
-- 提取时间: 2026-01-23 14:40:17
-- ================================================


-- ========================================
-- 1. 使用 INSERT VALUES
-- ========================================

-- ✅ 批量插入
INSERT INTO events
VALUES
(1, 100, 'click', now(), '{"page":"/home"}'),
(2, 100, 'view', now(), '{"product":"laptop"}'),
(3, 101, 'click', now(), '{"page":"/about"}'),
(4, 102, 'click', now(), '{"page":"/products"}'),
(5, 103, 'click', now(), '{"page":"/cart"}');

-- ❌ 单条插入（避免）
INSERT INTO events
VALUES (1, 100, 'click', now(), '{"page":"/home"}');
INSERT INTO events
VALUES (2, 100, 'view', now(), '{"product":"laptop"}');

-- ========================================
-- 1. 使用 INSERT VALUES
-- ========================================

-- ✅ 批量插入（从其他表）
INSERT INTO events
SELECT 
    number as event_id,
    number % 1000 as user_id,
    'click' as event_type,
    now() as event_time,
    '{}' as event_data
FROM numbers(100000);  -- 10 万行

-- ✅ 批量插入（从外部数据）
INSERT INTO events
FROM file('events.csv', 'CSV')
SETTINGS input_format_skip_first_lines = 1,
        input_format_allow_errors_num = 100;

-- ========================================
-- 1. 使用 INSERT VALUES
-- ========================================

-- ✅ 异步插入
INSERT INTO events
SETTINGS async_insert = 1,
        wait_for_async_insert = 0,
        async_insert_max_data_size = 100000000,  -- 100 MB
        async_insert_busy_timeout_ms = 5000,
        async_insert_max_wait_time_ms = 10000
VALUES
(1, 100, 'click', now(), '{"page":"/home"}'),
(2, 100, 'view', now(), '{"product":"laptop"}');

-- ✅ 异步插入不等待结果
INSERT INTO events
SETTINGS async_insert = 1,
        wait_for_async_insert = 0
VALUES (3, 101, 'click', now(), '{"page":"/about"}');

-- ========================================
-- 1. 使用 INSERT VALUES
-- ========================================

-- ✅ 并行插入（多个客户端）
-- 客户端 1
INSERT INTO events
VALUES (1, 100, 'click', now(), '{}');

-- 客户端 2
INSERT INTO events
VALUES (2, 100, 'view', now(), '{}');

-- 客户端 3
INSERT INTO events
VALUES (3, 101, 'click', now(), '{}');

-- 或使用分布式表
INSERT INTO distributed_events
VALUES (4, 102, 'click', now(), '{}');

-- ========================================
-- 1. 使用 INSERT VALUES
-- ========================================

-- ✅ 使用压缩插入
INSERT INTO events
SETTINGS max_insert_threads = 4,
        min_insert_block_size_rows = 65536,
        min_insert_block_size_bytes = 268435456
FORMAT Native
FROM file('events.native', 'Native')
SETTINGS compression = 'lz4';

-- ✅ 使用压缩协议
clickhouse-client --query="INSERT INTO events FORMAT Native" \
  --format=Native \
  --compression=lz4 \
  < data.bin

-- ========================================
-- 1. 使用 INSERT VALUES
-- ========================================

-- 设置插入线程数
INSERT INTO events
SETTINGS max_insert_threads = 4
VALUES (1, 100, 'click', now(), '{}');

-- ========================================
-- 1. 使用 INSERT VALUES
-- ========================================

-- 设置块大小
INSERT INTO events
SETTINGS min_insert_block_size_rows = 65536,
        min_insert_block_size_bytes = 268435456
VALUES (1, 100, 'click', now(), '{}');

-- ========================================
-- 1. 使用 INSERT VALUES
-- ========================================

-- 设置最大并发插入数
INSERT INTO events
SETTINGS max_concurrent_inserts = 10
VALUES (1, 100, 'click', now(), '{}');

-- ========================================
-- 1. 使用 INSERT VALUES
-- ========================================

-- 等待插入完成
INSERT INTO events
SETTINGS wait_for_async_insert = 1
VALUES (1, 100, 'click', now(), '{}');

-- ========================================
-- 1. 使用 INSERT VALUES
-- ========================================

-- ✅ 批量插入日志数据
INSERT INTO logs
SETTINGS max_insert_threads = 8,
        min_insert_block_size_rows = 100000,
        min_insert_block_size_bytes = 100000000
VALUES
(1, 'user1', 'INFO', '2024-01-20 10:00:00', 'Message 1'),
(2, 'user1', 'INFO', '2024-01-20 10:00:01', 'Message 2'),
(3, 'user2', 'INFO', '2024-01-20 10:00:02', 'Message 3'),
-- ... 100000 行
(100000, 'user100', 'INFO', '2024-01-20 12:00:00', 'Message 100000');

-- ========================================
-- 1. 使用 INSERT VALUES
-- ========================================

-- ✅ 使用 INSERT SELECT
INSERT INTO events
SETTINGS max_insert_threads = 8,
        min_insert_block_size_rows = 100000
SELECT 
    rowNumberInAllBlocks() as event_id,
    number % 1000 as user_id,
    ['click', 'view', 'purchase'][number % 3] as event_type,
    now() - INTERVAL (number % 86400) SECOND as event_time,
    '{}' as event_data
FROM numbers(1000000);  -- 100 万行

-- ========================================
-- 1. 使用 INSERT VALUES
-- ========================================

-- ✅ 异步批量插入
INSERT INTO events
SETTINGS async_insert = 1,
        wait_for_async_insert = 0,
        async_insert_max_data_size = 100000000,
        async_insert_busy_timeout_ms = 5000,
        max_insert_threads = 4
VALUES
(1, 100, 'click', now(), '{}'),
(2, 100, 'view', now(), '{}'),
(3, 101, 'click', now(), '{}'),
-- ... 10000 行
(10000, 103, 'click', now(), '{}');

-- ========================================
-- 1. 使用 INSERT VALUES
-- ========================================

-- ✅ 并行插入（使用分布式表）
INSERT INTO distributed_events
SETTINGS max_insert_threads = 4
SELECT 
    event_id,
    user_id,
    event_type,
    event_time,
    event_data
FROM events_temp
WHERE shard % 4 = 0;  -- 第一个分片

INSERT INTO distributed_events
SETTINGS max_insert_threads = 4
SELECT 
    event_id,
    user_id,
    event_type,
    event_time,
    event_data
FROM events_temp
WHERE shard % 4 = 1;  -- 第二个分片

-- ========================================
-- 1. 使用 INSERT VALUES
-- ========================================

-- ✅ Native 格式（最快）
INSERT INTO events
FORMAT Native
FROM file('events.native', 'Native');

-- ✅ CSV 格式（通用）
INSERT INTO events
FORMAT CSVWithNames
FROM file('events.csv', 'CSV');

-- ✅ JSONEachRow 格式（JSON 数据）
INSERT INTO events
FORMAT JSONEachRow
FROM file('events.jsonl', 'JSONEachRow');

-- ========================================
-- 1. 使用 INSERT VALUES
-- ========================================

-- ✅ 合理的线程数
INSERT INTO events
SETTINGS max_insert_threads = min(8, CPU核数)
VALUES (...);

-- ========================================
-- 1. 使用 INSERT VALUES
-- ========================================

-- 查看插入统计
SELECT 
    query,
    write_rows,
    write_bytes,
    query_duration_ms,
    write_rows / query_duration_ms as rows_per_second,
    formatReadableSize(write_bytes) as write_size
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query LIKE '%INSERT%'
  AND event_time >= now() - INTERVAL 1 HOUR
ORDER BY query_duration_ms DESC
LIMIT 10;
