-- ================================================================================
-- ClickHouse 查询优化示例
-- ================================================================================
-- 
-- 集群: treasurycluster (2 副本)
-- 预计学习时间: 30 分钟
-- 
-- 本文件涵盖:
--   1. 分区裁剪优化 - 使用分区键过滤减少扫描
--   2. 主键优化 - 利用主键加速查询
--   3. PREWHERE 优化 - 提前过滤减少IO
--   4. LIMIT 和 SAMPLE - 限制数据量
--   5. EXPLAIN 分析 - 查询计划分析
--   6. OR vs IN - 条件优化
--   7. 子查询 vs JOIN - 关联优化
--   8. 物化列 - 预计算字段
--   9. LIMIT BY - 分组TopN
--   10. DISTINCT vs GROUP BY - 去重优化
--   11. 并行设置 - 提高并发度
--   12. 查询监控 - 性能分析
-- 
-- 查询优化核心原则图:
-- 
--   ┌─────────────────────────────────────────────────────────────────────────┐
--   │                        ClickHouse 查询优化金字塔                          │
--   └─────────────────────────────────────────────────────────────────────────┘
--   
--                              ┌─────────────┐
--                              │   缓存优化   │
--                              │ Query Cache │
--                              └──────┬──────┘
--                                     │
--                            ┌────────┴────────┐
--                            │   并行处理优化    │
--                            │ Parallel/Threads │
--                            └────────┬────────┘
--                                     │
--                   ┌─────────────────┴─────────────────┐
--                   │          索引与跳数优化             │
--                   │  Primary Key / Skipping Indexes   │
--                   └─────────────────┬─────────────────┘
--                                     │
--          ┌──────────────────────────┴──────────────────────────┐
--          │                 分区与数据跳过优化                    │
--          │        Partition Pruning / PREWHERE                 │
--          └──────────────────────────┬──────────────────────────┘
--                                     │
--   ┌─────────────────────────────────┴─────────────────────────────────┐
--   │                      数据模型与表结构设计                           │
--   │              Table Schema / Data Types / Order By                 │
--   └───────────────────────────────────────────────────────────────────┘
-- 
-- 查询执行流程:
-- 
--   ┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐
--   │ 解析SQL  │───>│ 优化器   │───>│ 执行器   │───>│ 返回结果 │
--   │  Parser  │    │Optimizer │    │ Executor │    │  Result  │
--   └──────────┘    └────┬─────┘    └────┬─────┘    └──────────┘
--                        │               │
--                        ▼               ▼
--                 ┌─────────────┐  ┌─────────────┐
--                 │ 查询重写    │  │ 并行执行    │
--                 │ Rewrite     │  │ Parallel    │
--                 └─────────────┘  └─────────────┘
-- 
-- 分区裁剪示意图:
-- 
--   表: events (按月分区)
--   ┌─────────────────────────────────────────────────────────┐
--   │ Partition 202401 │ Partition 202402 │ Partition 202403 │
--   │    100GB         │    120GB         │    150GB         │
--   └────────┬─────────┴─────────────────┴───────────────────┘
--            │
--   WHERE event_time >= '2024-01-01' AND event_time < '2024-02-01'
--            │
--            ▼
--   ┌─────────────────┐
--   │ 只扫描 202401   │  ← 裁剪掉其他分区，减少IO 80%+
--   │    100GB        │
--   └─────────────────┘
-- 
-- ================================================================================

-- 创建数据库（如果存在则不创建）
CREATE DATABASE IF NOT EXISTS example;

-- ========================================
-- 测试数据准备（幂等：先删后建，保证文件可独立重复运行）
-- ========================================
SET log_query_threads = 1;

DROP TABLE IF EXISTS distributed_table;
DROP VIEW IF EXISTS user_event_count_mv;
DROP TABLE IF EXISTS orders;
DROP TABLE IF EXISTS active_users;
DROP TABLE IF EXISTS users;
DROP TABLE IF EXISTS events;

-- events 事件表：按月分区，主键 (user_id, event_time)
CREATE TABLE events (
    event_id UInt64,
    user_id UInt64,
    event_type String,
    event_time DateTime,
    event_date Date MATERIALIZED toDate(event_time),
    event_month String MATERIALIZED formatDateTime(event_time, '%Y-%m')
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (user_id, event_time)
SAMPLE BY user_id;

INSERT INTO events (event_id, user_id, event_type, event_time)
VALUES
    (1, 1, 'click',    now() - INTERVAL 1 DAY),
    (2, 2, 'view',     now() - INTERVAL 2 DAY),
    (3, 3, 'click',    now() - INTERVAL 3 DAY),
    (4, 1, 'view',     now() - INTERVAL 5 DAY),
    (5, 2, 'purchase', now() - INTERVAL 6 DAY),
    (6, 1, 'click',    '2024-01-05 10:00:00'),
    (7, 2, 'view',     '2024-01-15 12:00:00'),
    (8, 3, 'click',    '2024-01-25 14:00:00');

-- users 用户表
CREATE TABLE users (
    user_id UInt64,
    username String,
    email String,
    created_at DateTime
) ENGINE = MergeTree()
ORDER BY user_id;

INSERT INTO users VALUES
    (1, 'alice', 'alice@example.com', '2024-01-10 00:00:00'),
    (2, 'bob',   'bob@example.com',   '2024-01-20 00:00:00'),
    (3, 'carol', 'carol@example.com', '2024-02-05 00:00:00'),
    (123, 'dev', 'user@example.com',  '2024-03-01 00:00:00');

-- orders 订单表
CREATE TABLE orders (
    order_id UInt64,
    user_id UInt64,
    product_id UInt32,
    amount Float64,
    order_date DateTime
) ENGINE = MergeTree()
ORDER BY order_id;

INSERT INTO orders VALUES
    (1001, 1, 1, 99.9,  now() - INTERVAL 1 DAY),
    (1002, 2, 2, 199.9, now() - INTERVAL 2 DAY),
    (1003, 3, 3, 299.9, now() - INTERVAL 3 DAY);

-- active_users 活跃用户表（预计算结果）
CREATE TABLE active_users (
    user_id UInt64
) ENGINE = MergeTree()
ORDER BY user_id;

INSERT INTO active_users VALUES (1), (2), (3);

-- distributed_table 分布式表（用于演示 max_parallel_replicas）
CREATE TABLE distributed_table (
    event_id UInt64,
    user_id UInt64,
    event_type String,
    event_time DateTime
) ENGINE = Distributed('treasurycluster', 'default', 'events', rand());


SELECT * FROM events
WHERE event_time >= now() - INTERVAL 7 DAY;

-- ❌ 不使用分区裁剪（慢速）
SELECT * FROM events
WHERE toYYYYMM(event_time) >= toYYYYMM(now() - INTERVAL 7 DAY);

-- ========================================
-- 1. 使用分区裁剪
-- ========================================

-- ✅ 使用主键（快速）
SELECT * FROM users
WHERE user_id = 123;

-- ❌ 不使用主键（慢速）
SELECT * FROM users
WHERE email = 'user@example.com';

-- ========================================
-- 1. 使用分区裁剪
-- ========================================

-- ❌ 在 WHERE 中使用函数（慢速）
SELECT * FROM users
WHERE toYYYYMM(created_at) = '202401';

-- ✅ 使用常量范围（快速）
SELECT * FROM users
WHERE created_at >= '2024-01-01'
  AND created_at < '2024-02-01';

-- ========================================
-- 1. 使用分区裁剪
-- ========================================

-- 使用 PREWHERE 过滤大列
SELECT 
    user_id,
    event_type,
    event_time
FROM events
PREWHERE event_time >= now() - INTERVAL 7 DAY
WHERE user_id = 123;

-- ========================================
-- 1. 使用分区裁剪
-- ========================================

-- 使用 LIMIT
SELECT * FROM events
WHERE event_time >= now() - INTERVAL 7 DAY
LIMIT 1000;

-- 使用 SAMPLE 采样
SELECT * FROM events
SAMPLE 0.1  -- 10% 的数据
WHERE event_time >= now() - INTERVAL 7 DAY;

-- ========================================
-- 1. 使用分区裁剪
-- ========================================

-- 查看查询执行计划
EXPLAIN PLAN
SELECT 
    user_id,
    count() as event_count
FROM events
WHERE event_time >= now() - INTERVAL 7 DAY
GROUP BY user_id;

-- ========================================
-- 1. 使用分区裁剪
-- ========================================

-- 查看查询管道
EXPLAIN PIPELINE
SELECT 
    user_id,
    count() as event_count
FROM events
WHERE event_time >= now() - INTERVAL 7 DAY
GROUP BY user_id;

-- ========================================
-- 1. 使用分区裁剪
-- ========================================

-- 查看查询预估
EXPLAIN ESTIMATE
SELECT 
    user_id,
    count() as event_count
FROM events
WHERE event_time >= now() - INTERVAL 7 DAY
GROUP BY user_id;

-- ========================================
-- 1. 使用分区裁剪
-- ========================================

-- ❌ 使用 OR（慢速）
SELECT * FROM users
WHERE user_id = 1 
   OR user_id = 2 
   OR user_id = 3;

-- ✅ 使用 IN（快速）
SELECT * FROM users
WHERE user_id IN (1, 2, 3);

-- ========================================
-- 1. 使用分区裁剪
-- ========================================

-- ❌ 使用子查询（慢速）
SELECT * FROM orders
WHERE user_id IN (SELECT user_id FROM active_users);

-- ✅ 使用 JOIN（快速）
SELECT o.*
FROM orders o
INNER JOIN active_users u ON o.user_id = u.user_id;

-- ========================================
-- 1. 使用分区裁剪
-- ========================================

-- 创建物化列
CREATE TABLE IF NOT EXISTS events (
    event_id UInt64,
    user_id UInt64,
    event_type String,
    event_time DateTime,
    event_date Date MATERIALIZED toDate(event_time),
    event_month String MATERIALIZED formatDateTime(event_time, '%Y-%m')
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (user_id, event_time);

-- 查询时使用物化列
SELECT 
    user_id,
    count() as event_count
FROM events
WHERE event_month = '2024-01'
GROUP BY user_id;

-- ========================================
-- 1. 使用分区裁剪
-- ========================================

-- 获取每个用户的最新事件
SELECT *
FROM events
WHERE event_time >= now() - INTERVAL 7 DAY
ORDER BY user_id, event_time DESC
LIMIT 1 BY user_id;

-- ========================================
-- 1. 使用分区裁剪
-- ========================================

-- ❌ 使用 GROUP BY（慢速）
SELECT user_id FROM events GROUP BY user_id;

-- ✅ 使用 DISTINCT（快速）
SELECT DISTINCT user_id FROM events;

-- ========================================
-- 1. 使用分区裁剪
-- ========================================

-- 设置并行线程数
SELECT * FROM events
-- REMOVED SET max_threads (not supported) 8
WHERE event_time >= now() - INTERVAL 7 DAY;

-- 设置并发读取
SELECT * FROM events
-- REMOVED SET max_concurrent_queries (not supported) 4
WHERE event_time >= now() - INTERVAL 7 DAY;

-- ========================================
-- 1. 使用分区裁剪
-- ========================================

-- 设置分布式查询并行
SELECT * FROM distributed_table
WHERE event_time >= now() - INTERVAL 7 DAY
SETTINGS max_parallel_replicas = 2;

-- ========================================
-- 1. 使用分区裁剪
-- ========================================

-- 查看最近的查询
-- 说明: 本集群禁用 system.query_log（UNKNOWN_TABLE），此处改用 system.query_thread_log 演示
--（原写法: FROM system.query_log WHERE type = 'QueryFinish' AND ...）
SELECT 
    query,
    query_duration_ms,
    read_rows,
    read_bytes,
    written_rows,
    memory_usage,
    event_time
FROM system.query_thread_log
WHERE event_time >= now() - INTERVAL 1 HOUR
ORDER BY event_time DESC
LIMIT 10;

-- ========================================
-- 1. 使用分区裁剪
-- ========================================

-- 查看慢查询
-- 说明: 本集群禁用 system.query_log，改用 system.query_thread_log 演示（原条件 type = 'QueryFinish' 省略）
SELECT 
    query,
    query_duration_ms,
    read_rows,
    read_bytes,
    memory_usage,
    formatReadableSize(read_bytes) as readable_bytes
FROM system.query_thread_log
WHERE query_duration_ms > 1000
ORDER BY query_duration_ms DESC
LIMIT 20;

-- ========================================
-- 1. 使用分区裁剪
-- ========================================

-- 查看查询统计
-- 说明: 本集群禁用 system.query_log，改用 system.query_thread_log 演示（原条件 type = 'QueryFinish' 省略）
SELECT 
    substring(query, 1, 50) as query_sample,
    count() as query_count,
    avg(query_duration_ms) as avg_duration,
    max(query_duration_ms) as max_duration,
    sum(read_rows) as total_rows_read,
    sum(read_bytes) as total_bytes_read
FROM system.query_thread_log
WHERE event_time >= now() - INTERVAL 24 HOUR
GROUP BY query_sample
ORDER BY query_count DESC
LIMIT 10;

-- ========================================
-- 1. 使用分区裁剪
-- ========================================

-- ❌ 优化前
SELECT * FROM events
WHERE toYYYYMMDD(event_time) >= '20240101'
  AND toYYYYMMDD(event_time) < '20240201';

-- ✅ 优化后
SELECT * FROM events
WHERE event_time >= '2024-01-01'
  AND event_time < '2024-02-01';

-- ========================================
-- 1. 使用分区裁剪
-- ========================================

-- ❌ 优化前
SELECT 
    user_id,
    count() as event_count
FROM events
WHERE event_time >= now() - INTERVAL 30 DAY
GROUP BY user_id
HAVING count() > 100;

-- ✅ 优化后（使用物化视图）
CREATE MATERIALIZED VIEW user_event_count_mv
ENGINE = AggregatingMergeTree()
ORDER BY (user_id, date)
AS SELECT
    user_id,
    toStartOfDay(event_time) as date,
    countState() as event_count
FROM events
GROUP BY user_id, date;

-- 查询物化视图
SELECT 
    user_id,
    countMerge(event_count) as total_events
FROM user_event_count_mv
WHERE date >= now() - INTERVAL 30 DAY
GROUP BY user_id
HAVING countMerge(event_count) > 100;

-- ========================================
-- 1. 使用分区裁剪
-- ========================================

-- ❌ 优化前
SELECT 
    o.order_id,
    o.amount,
    u.username
FROM orders o
LEFT JOIN users u ON o.user_id = u.user_id
WHERE o.order_date >= now() - INTERVAL 30 DAY;

-- ✅ 优化后（使用分布式 JOIN）
SELECT 
    o.order_id,
    o.amount,
    u.username
FROM orders o
GLOBAL LEFT JOIN users u ON o.user_id = u.user_id
WHERE o.order_date >= now() - INTERVAL 30 DAY
SETTINGS distributed_product_mode = 'global';
