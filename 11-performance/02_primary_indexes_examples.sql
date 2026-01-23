-- ================================================
-- 02_primary_indexes_examples.sql
-- 从 02_primary_indexes.md 提取的 SQL 示例
-- 提取时间: 2026-01-23 14:40:17
-- ================================================


-- ========================================
-- 原则 1: 高选择性
-- ========================================

-- ✅ 高选择性主键
CREATE TABLE events (
    event_id UInt64,
    user_id UInt64,
    event_time DateTime,
    event_data String
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (user_id, event_time);  -- user_id 高选择性

-- ❌ 低选择性主键
CREATE TABLE events (
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
CREATE TABLE events (
    event_id UInt64,
    user_id UInt64,
    event_type String,
    event_time DateTime
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (user_id, event_time);  -- ✅ 匹配查询模式

-- 如果查询主要按 event_type 和 event_time
CREATE TABLE events (
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
CREATE TABLE events (
    event_id UInt64,
    user_id UInt64,
    event_type String,
    event_time DateTime
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (user_id, event_time);  -- ✅ 2 列

-- ❌ 过多列的主键
CREATE TABLE events (
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
CREATE TABLE events (
    event_id UInt64,
    user_id UInt64,
    event_type String,
    event_time DateTime
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (user_id, event_type, event_time);  -- ✅ 时间在最后

-- ❌ 时间列不在最后
CREATE TABLE events (
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
CREATE TABLE events (
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
CREATE TABLE events_read (
    event_id UInt64,
    user_id UInt64,
    event_time DateTime
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (user_id, event_time)
SETTINGS index_granularity = 4096;

-- 写入密集型：较大的粒度
CREATE TABLE events_write (
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
SELECT 
    query,
    read_rows,
    read_bytes,
    result_rows,
    result_bytes,
    formatReadableSize(read_bytes) as read_size,
    formatReadableSize(result_bytes) as result_size
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_time >= now() - INTERVAL 24 HOUR
  AND read_rows > 1000000
ORDER BY read_rows DESC
LIMIT 10;

-- ========================================
-- 原则 1: 高选择性
-- ========================================

-- 查看索引使用情况
SELECT 
    table,
    partition,
    name,
    type,
    rows,
    bytes_on_disk,
    marks_count
FROM system.data_skipping_indices
WHERE database = 'my_database';

-- ========================================
-- 原则 1: 高选择性
-- ========================================

-- 优化前
CREATE TABLE events (
    event_id UInt64,
    user_id UInt64,
    event_type String,
    event_time DateTime,
    event_data String
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_time);  -- ❌ 只有时间

-- 优化后
CREATE TABLE events (
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
CREATE TABLE orders (
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
CREATE TABLE orders (
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
CREATE TABLE users (
    user_id UInt64,
    username String,
    email String,
    created_at DateTime,
    last_login DateTime
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(created_at)
ORDER BY (created_at);  -- ❌ 只有时间

-- 优化后
CREATE TABLE users (
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
CREATE TABLE events (
    user_id UInt64,
    event_id UInt64,
    event_time DateTime
) ENGINE = MergeTree()
ORDER BY (user_id, event_time);  -- ✅ user_id 在主键中

-- ========================================
-- 原则 1: 高选择性
-- ========================================

-- ✅ 高选择性列在前
ORDER BY (user_id, event_type);

-- ❌ 低选择性列在前
ORDER BY (event_type, user_id);

-- ========================================
-- 原则 1: 高选择性
-- ========================================

-- ✅ 2-3 列
ORDER BY (user_id, event_time);

-- ❌ 过多列
ORDER BY (user_id, event_type, event_category, event_time);

-- ========================================
-- 原则 1: 高选择性
-- ========================================

-- ✅ 时间列在最后
ORDER BY (user_id, event_type, event_time);

-- ❌ 时间列在最前
ORDER BY (event_time, user_id, event_type);

-- ========================================
-- 原则 1: 高选择性
-- ========================================

-- 定期分析主键使用情况
SELECT 
    query,
    count() as query_count,
    avg(read_rows) as avg_rows_read,
    avg(query_duration_ms) as avg_duration
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_time >= now() - INTERVAL 7 DAY
GROUP BY query
ORDER BY query_count DESC
LIMIT 10;
