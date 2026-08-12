-- ================================================================================
-- ClickHouse 主键索引优化示例
-- ================================================================================
-- 
-- 集群: treasurycluster (2 副本)
-- 预计学习时间: 25 分钟
-- 
-- 本文件涵盖:
--   1. 主键选择原则 - 高选择性、查询匹配
--   2. 主键列数量 - 2-3列最佳
--   3. 时间列位置 - 放在最后
--   4. 主键查询模式 - 范围、IN、前缀查询
--   5. 索引粒度设置 - index_granularity
--   6. 主键监控 - 扫描情况分析
-- 
-- MergeTree 主键索引原理:
-- 
--   ┌─────────────────────────────────────────────────────────────────────────┐
--   │                     MergeTree 主键索引结构                               │
--   └─────────────────────────────────────────────────────────────────────────┘
--   
--   数据文件 (按 ORDER BY 排序):
--   ┌────────────────────────────────────────────────────────────────────────┐
--   │  Granule 0    │  Granule 1    │  Granule 2    │  Granule 3    │  ...   │
--   │  8192 rows    │  8192 rows    │  8192 rows    │  8192 rows    │        │
--   └────────┬───────┴───────┬───────┴───────┬───────┴───────┬───────┴────────┘
--            │               │               │               │
--            ▼               ▼               ▼               ▼
--   主键索引 (稀疏索引):
--   ┌─────────────┬─────────────┬─────────────┬─────────────┐
--   │ Mark 0      │ Mark 1      │ Mark 2      │ Mark 3      │
--   │ (min, max)  │ (min, max)  │ (min, max)  │ (min, max)  │
--   └─────────────┴─────────────┴─────────────┴─────────────┘
--   
--   每个 Mark 记录:
--   ┌─────────────────────────────────────────┐
--   │ user_id_min, user_id_max, event_time... │
--   │ offset_in_file, offset_in_mark_file     │
--   └─────────────────────────────────────────┘
-- 
-- 主键查询过程:
-- 
--   SELECT * FROM events WHERE user_id = 123
--   
--   ┌──────────┐     ┌──────────────┐     ┌──────────────┐
--   │ 读取主键 │────>│ 二分查找Mark │────>│ 定位Granule │
--   │ 索引文件 │     │ user_id=123  │     │  跳过不相关  │
--   └──────────┘     └──────────────┘     └──────────────┘
--                                               │
--                                               ▼
--                                        ┌──────────────┐
--                                        │ 只读取匹配的 │
--                                        │   Granule    │
--                                        └──────────────┘
-- 
-- 主键选择决策树:
-- 
--                        ┌─────────────────────┐
--                        │ 选择主键第一列      │
--                        │ 最高选择性?        │
--                        └──────────┬──────────┘
--                                   │
--                    ┌──────────────┴──────────────┐
--                    │                             │
--                    ▼                             ▼
--              ┌──────────┐                 ┌──────────┐
--              │   是     │                 │   否     │
--              │ 高基数列 │                 │ 重新选择 │
--              └────┬─────┘                 └──────────┘
--                   │
--                   ▼
--         ┌─────────────────┐
--         │ 需要时间范围?   │
--         └────────┬────────┘
--                  │
--         ┌───────┴───────┐
--         │               │
--         ▼               ▼
--   ┌──────────┐    ┌──────────┐
--   │ 加时间列 │    │ 不需要   │
--   │ 放最后   │    │          │
--   └──────────┘    └──────────┘
-- 
-- ================================================================================

-- 测试数据准备（幂等：先删后建，保证文件可独立重复运行）
DROP TABLE IF EXISTS events_read;
DROP TABLE IF EXISTS events_write;
DROP TABLE IF EXISTS orders;
DROP TABLE IF EXISTS users;
DROP TABLE IF EXISTS events;

-- 事件表（统一 schema，含后续示例所需的 event_type 列）
CREATE TABLE IF NOT EXISTS events (
    event_id UInt64,
    user_id UInt64,
    event_type String,
    event_time DateTime,
    event_data String
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (user_id, event_time);  -- user_id 高选择性

INSERT INTO events (event_id, user_id, event_type, event_time, event_data)
VALUES
    (1, 123, 'click', '2024-01-15 10:00:00', '{}'),
    (2, 1, 'view',    now() - INTERVAL 1 DAY, '{}'),
    (3, 2, 'click',   now() - INTERVAL 2 DAY, '{}');

-- ❌ 低选择性主键
CREATE TABLE IF NOT EXISTS events (
    event_id UInt64,
    user_id UInt64,
    event_type String,
    event_time DateTime
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_type, event_time);  -- event_type 低选择性

-- ========================================
-- 原则 1: 高选择性
-- ========================================

-- 如果查询主要按 user_id 和 event_time
CREATE TABLE IF NOT EXISTS events (
    event_id UInt64,
    user_id UInt64,
    event_type String,
    event_time DateTime
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (user_id, event_time);  -- ✅ 匹配查询模式

-- 如果查询主要按 event_type 和 event_time
CREATE TABLE IF NOT EXISTS events (
    event_id UInt64,
    user_id UInt64,
    event_type String,
    event_time DateTime
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_type, event_time);  -- ✅ 匹配查询模式

-- ========================================
-- 原则 1: 高选择性
-- ========================================

-- ✅ 2-3 列的主键
CREATE TABLE IF NOT EXISTS events (
    event_id UInt64,
    user_id UInt64,
    event_type String,
    event_time DateTime
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (user_id, event_time);  -- ✅ 2 列

-- ❌ 过多列的主键
CREATE TABLE IF NOT EXISTS events (
    event_id UInt64,
    user_id UInt64,
    event_type String,
    event_category String,
    event_subcategory String,
    event_time DateTime
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (user_id, event_type, event_category, 
          event_subcategory, event_time);  -- ❌ 5 列

-- ========================================
-- 原则 1: 高选择性
-- ========================================

-- ✅ 时间列在最后
CREATE TABLE IF NOT EXISTS events (
    event_id UInt64,
    user_id UInt64,
    event_type String,
    event_time DateTime
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (user_id, event_type, event_time);  -- ✅ 时间在最后

-- ❌ 时间列不在最后
CREATE TABLE IF NOT EXISTS events (
    event_id UInt64,
    user_id UInt64,
    event_time DateTime,
    event_type String
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_time, user_id, event_type);  -- ❌ 时间在最前

-- ========================================
-- 原则 1: 高选择性
-- ========================================

-- ✅ 使用主键范围查询
SELECT * FROM events
WHERE user_id = 123
  AND event_time >= '2024-01-01'
  AND event_time < '2024-02-01';

-- ✅ 使用主键 IN 查询
SELECT * FROM events
WHERE user_id IN (1, 2, 3, 4, 5)
  AND event_time >= now() - INTERVAL 7 DAY;

-- ========================================
-- 原则 1: 高选择性
-- ========================================

-- ✅ 使用主键前缀查询
SELECT * FROM events
WHERE user_id = 123;  -- 只使用主键第一列

-- ✅ 使用主键前两列
SELECT * FROM events
WHERE user_id = 123
  AND event_type = 'click';

-- ========================================
-- 原则 1: 高选择性
-- ========================================

-- ❌ 在主键上使用函数（慢速）
SELECT * FROM events
WHERE toYYYYMM(event_time) = '202401';

-- ✅ 使用范围查询（快速）
SELECT * FROM events
WHERE event_time >= '2024-01-01'
  AND event_time < '2024-02-01';

-- ========================================
-- 原则 1: 高选择性
-- ========================================

-- 创建表时设置索引粒度
CREATE TABLE IF NOT EXISTS events (
    event_id UInt64,
    user_id UInt64,
    event_time DateTime,
    event_data String
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (user_id, event_time)
SETTINGS index_granularity = 8192;  -- 默认值

-- ========================================
-- 原则 1: 高选择性
-- ========================================

-- 读取密集型：较小的粒度
CREATE TABLE IF NOT EXISTS events_read (
    event_id UInt64,
    user_id UInt64,
    event_time DateTime
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (user_id, event_time)
SETTINGS index_granularity = 4096;

-- 写入密集型：较大的粒度
CREATE TABLE IF NOT EXISTS events_write (
    event_id UInt64,
    user_id UInt64,
    event_time DateTime
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (user_id, event_time)
SETTINGS index_granularity = 16384;

-- ========================================
-- 原则 1: 高选择性
-- ========================================

-- 查看表的主键
SELECT 
    database,
    table,
    primary_key,
    sorting_key
FROM system.tables
WHERE database = 'my_database';

-- ========================================
-- 原则 1: 高选择性
-- ========================================

-- 查看主键扫描情况
-- 说明: 本集群禁用 system.query_log，改用 system.query_thread_log 演示；
--       result_rows/result_bytes 为 query_log 专有列，query_thread_log 无此列，故省略
SELECT 
    query,
    read_rows,
    read_bytes,
    formatReadableSize(read_bytes) as read_size
FROM system.query_thread_log
WHERE event_time >= now() - INTERVAL 24 HOUR
  AND read_rows > 1000000
ORDER BY read_rows DESC
LIMIT 10;

-- ========================================
-- 原则 1: 高选择性
-- ========================================

-- 查看索引使用情况
-- 说明: 25.12 中 system.data_skipping_indices 的列有变化（rows/bytes_on_disk/marks_count 已移除）
SELECT 
    table,
    '',
    name,
    type,
    data_compressed_bytes,
    data_uncompressed_bytes,
    marks_bytes
FROM system.data_skipping_indices
WHERE database = 'my_database';

-- ========================================
-- 原则 1: 高选择性
-- ========================================

-- 优化前
CREATE TABLE IF NOT EXISTS events (
    event_id UInt64,
    user_id UInt64,
    event_type String,
    event_time DateTime,
    event_data String
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_time);  -- ❌ 只有时间

-- 优化后
CREATE TABLE IF NOT EXISTS events (
    event_id UInt64,
    user_id UInt64,
    event_type String,
    event_time DateTime,
    event_data String
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (user_id, event_time);  -- ✅ user_id + time

-- ========================================
-- 原则 1: 高选择性
-- ========================================

-- 优化前
CREATE TABLE IF NOT EXISTS orders (
    order_id UInt64,
    user_id UInt64,
    product_id UInt64,
    amount Float64,
    order_date DateTime,
    status String
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(order_date)
ORDER BY (order_id);  -- ❌ 只有 order_id

-- 优化后
CREATE TABLE IF NOT EXISTS orders (
    order_id UInt64,
    user_id UInt64,
    product_id UInt64,
    amount Float64,
    order_date DateTime,
    status String
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(order_date)
ORDER BY (user_id, order_date, order_id);  -- ✅ user_id + date + order_id

-- ========================================
-- 原则 1: 高选择性
-- ========================================

-- 优化前
CREATE TABLE IF NOT EXISTS users (
    user_id UInt64,
    username String,
    email String,
    created_at DateTime,
    last_login DateTime
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(created_at)
ORDER BY (created_at);  -- ❌ 只有时间

-- 优化后
CREATE TABLE IF NOT EXISTS users (
    user_id UInt64,
    username String,
    email String,
    created_at DateTime,
    last_login DateTime
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(created_at)
ORDER BY (user_id, created_at);  -- ✅ user_id + time

-- ========================================
-- 原则 1: 高选择性
-- ========================================

-- 如果经常按 user_id 查询
CREATE TABLE IF NOT EXISTS events (
    user_id UInt64,
    event_id UInt64,
    event_time DateTime
) ENGINE = MergeTree()
ORDER BY (user_id, event_time);  -- ✅ user_id 在主键中

-- ========================================
-- 原则 1: 高选择性
-- ========================================

-- ✅ 高选择性列在前
-- ORDER BY (user_id, event_type);   -- 独立片段说明，非完整语句，仅作教学示意

-- ❌ 低选择性列在前
-- ORDER BY (event_type, user_id);   -- 独立片段说明，非完整语句，仅作教学示意

-- ========================================
-- 原则 1: 高选择性
-- ========================================

-- ✅ 2-3 列
-- ORDER BY (user_id, event_time);   -- 独立片段说明，非完整语句，仅作教学示意

-- ❌ 过多列
-- ORDER BY (user_id, event_type, event_category, event_time);   -- 独立片段说明，非完整语句，仅作教学示意

-- ========================================
-- 原则 1: 高选择性
-- ========================================

-- ✅ 时间列在最后
-- ORDER BY (user_id, event_type, event_time);   -- 独立片段说明，非完整语句，仅作教学示意

-- ❌ 时间列在最前
-- ORDER BY (event_time, user_id, event_type);   -- 独立片段说明，非完整语句，仅作教学示意

-- ========================================
-- 原则 1: 高选择性
-- ========================================

-- 定期分析主键使用情况
-- 说明: 本集群禁用 system.query_log，改用 system.query_thread_log 演示（原条件 type = 'QueryFinish' 省略）
SELECT 
    query,
    count() as query_count,
    avg(read_rows) as avg_rows_read,
    avg(query_duration_ms) as avg_duration
FROM system.query_thread_log
WHERE event_time >= now() - INTERVAL 7 DAY
GROUP BY query
ORDER BY query_count DESC
LIMIT 10;
