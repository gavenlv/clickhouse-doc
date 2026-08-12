-- ================================================================================
-- ClickHouse 批量插入优化示例
-- ================================================================================
-- 
-- 集群: treasurycluster (2 副本)
-- 预计学习时间: 20 分钟
-- 
-- 本文件涵盖:
--   1. 批量插入原则 - 避免 INSERT VALUES 单条插入
--   2. INSERT SELECT - 从查询结果插入
--   3. 异步插入 - async_insert 配置
--   4. 并行插入 - 多客户端并发写入
--   5. 压缩插入 - 格式选择与压缩
--   6. 插入参数调优 - 线程数、块大小
-- 
-- 批量插入原理:
-- 
--   ┌─────────────────────────────────────────────────────────────────────────┐
--   │                    ClickHouse 写入流程                                  │
--   └─────────────────────────────────────────────────────────────────────────┘
--   
--   写入请求:
--   ┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐
--   │ 接收数据 │───>│ 排序     │───>│ 压缩     │───>│ 写入磁盘 │
--   │          │    │ ORDER BY │    │ LZ4/ZSTD │    │ 新Part   │
--   └──────────┘    └──────────┘    └──────────┘    └──────────┘
--        ↑
--        │
--   写入性能取决于:
--   - 批量大小 (越大越好)
--   - 排序键复杂度 (越简单越快)
--   - 压缩算法 (LZ4 > ZSTD)
-- 
-- 单条 vs 批量插入:
-- 
--   ❌ 单条插入 (避免):
--   ┌─────────┐    ┌─────────┐    ┌─────────┐
--   │ INSERT  │───>│ INSERT  │───>│ INSERT  │    ... 1000次
--   │ 1 row   │    │ 1 row   │    │ 1 row   │
--   └─────────┘    └─────────┘    └─────────┘
--        │              │              │
--        ▼              ▼              ▼
--   ┌─────────┐    ┌─────────┐    ┌─────────┐
--   │ Part 1  │    │ Part 2  │    │ Part 3  │    ... 1000个Part
--   │   1KB   │    │   1KB   │    │   1KB   │
--   └─────────┘    └─────────┘    └─────────┘
--   
--   问题: 大量小Part → 合并压力 → 性能下降
--   
--   ✅ 批量插入 (推荐):
--   ┌────────────────────────────────────────────┐
--   │ INSERT ... VALUES (1000 rows)             │
--   └────────────────────────────────────────────┘
--                         │
--                         ▼
--                   ┌─────────┐
--                   │ Part 1  │
--                   │   1MB   │
--                   └─────────┘
--   
--   优势: 少量大Part → 合并压力小 → 性能稳定
-- 
-- 异步插入流程:
-- 
--   ┌─────────────────────────────────────────────────────────────────────────┐
--   │                      异步插入 (async_insert)                            │
--   └─────────────────────────────────────────────────────────────────────────┘
--   
--   客户端 1          客户端 2          客户端 3
--      │                 │                 │
--      ▼                 ▼                 ▼
--   ┌─────┐           ┌─────┐           ┌─────┐
--   │INSERT│           │INSERT│           │INSERT│
--   │100行 │           │200行 │           │150行 │
--   └──┬──┘           └──┬──┘           └──┬──┘
--      │                 │                 │
--      └─────────────────┼─────────────────┘
--                        │
--                        ▼
--              ┌─────────────────┐
--              │   异步缓冲区    │
--              │  等待条件:      │
--              │  - 数据量达标   │
--              │  - 超时到达     │
--              └────────┬────────┘
--                       │
--                       ▼
--              ┌─────────────────┐
--              │  合并后批量写入  │
--              │  450 行 → 1 Part │
--              └─────────────────┘
-- 
-- 插入块大小建议:
-- 
--   数据量/天       块大小建议       线程数
--   ────────────────────────────────────────
--   < 10 GB         50,000-100,000   2-4
--   10-100 GB       100,000-500,000  4-8
--   > 100 GB        500,000-1,000,000 8-16
-- 
-- ================================================================================

-- 测试数据准备（幂等：先删后建，保证文件可独立重复运行）
DROP TABLE IF EXISTS distributed_events;
DROP TABLE IF EXISTS events_temp;
DROP TABLE IF EXISTS logs;
DROP TABLE IF EXISTS events;

-- 事件表（5 列：event_id, user_id, event_type, event_time, event_data）
CREATE TABLE events (
    event_id UInt64,
    user_id UInt64,
    event_type String,
    event_time DateTime,
    event_data String
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_time, event_id);

-- 分布式表（并行插入演示，指向本机 events）
CREATE TABLE distributed_events
AS events
ENGINE = Distributed('treasurycluster', 'default', 'events', rand());

-- 临时源表（INSERT SELECT 分片演示，含 shard 列）
CREATE TABLE events_temp (
    event_id UInt64,
    user_id UInt64,
    event_type String,
    event_time DateTime,
    event_data String,
    shard UInt8
) ENGINE = Memory;

-- 日志表（批量插入演示）
CREATE TABLE logs (
    id UInt64,
    username String,
    level String,
    ts DateTime,
    message String
) ENGINE = MergeTree()
ORDER BY ts;

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
-- [需外部依赖] 需在 /var/lib/clickhouse/user_files/ 提供 events.csv（首行为列名）
INSERT INTO events
SELECT * FROM file('events.csv', 'CSV')
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
-- 说明: 原写法 FORMAT Native FROM file(...) 组合非法（双 SETTINGS），且依赖外部文件；
--       教学示意保留为注释，等价的可运行写法见下方"Native 格式（最快）"一节
-- INSERT INTO events
-- SETTINGS max_insert_threads = 4,
--         min_insert_block_size_rows = 65536,
--         min_insert_block_size_bytes = 268435456
-- FORMAT Native
-- FROM file('events.native', 'Native')
-- SETTINGS compression = 'lz4';

-- ✅ 使用压缩协议
-- 说明: 以下为 shell 命令示意（clickhouse-client 命令行），非 SQL，注释保留
-- clickhouse-client --query="INSERT INTO events FORMAT Native" \
--   --format=Native \
--   --compression=lz4 \
--   < data.bin

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
-- 说明: 原教学伪代码 min(8, CPU核数) 与 VALUES (...) 非法，改为可运行写法
INSERT INTO events
SETTINGS max_insert_threads = 4
VALUES (1, 100, 'click', now(), '{}');

-- ========================================
-- 1. 使用 INSERT VALUES
-- ========================================

-- 查看插入统计
-- 说明: 25.12 集群 system.query_log 未启用，改用 system.query_thread_log（需先 SET log_query_threads = 1）；
--       query_thread_log 中写入列名为 written_rows/written_bytes
SET log_query_threads = 1;

SELECT 
    query,
    written_rows,
    written_bytes,
    query_duration_ms,
    written_rows / greatest(query_duration_ms, 1) as rows_per_second,
    formatReadableSize(written_bytes) as write_size
FROM system.query_thread_log
WHERE query LIKE '%INSERT%'
  AND event_time >= now() - INTERVAL 1 HOUR
ORDER BY query_duration_ms DESC
LIMIT 10;
