-- ================================================
-- 04_skipping_indexes_examples.sql
-- 从 04_skipping_indexes.md 提取的 SQL 示例
-- 提取时间: 2026-01-23 14:40:17
-- ================================================


-- ========================================
-- 索引粒度
-- ========================================

-- 创建表时设置索引粒度
CREATE TABLE events (
    event_id UInt64,
    user_id UInt64,
    event_type String,
    event_time DateTime,
    event_data String
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (user_id, event_time)
SETTINGS index_granularity = 8192;  -- 每个 mark 8192 行

-- 跳数索引粒度 = index_granularity / 2
-- 默认 = 4096 行

-- ========================================
-- 索引粒度
-- ========================================

-- 创建 minmax 索引
CREATE TABLE events (
    event_id UInt64,
    user_id UInt64,
    event_time DateTime,
    status UInt8
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (user_id, event_time);

-- 添加 minmax 索引
ALTER TABLE events
ADD INDEX idx_status status
TYPE minmax
GRANULARITY 4;

-- ========================================
-- 索引粒度
-- ========================================

-- 创建 set 索引
CREATE TABLE events (
    event_id UInt64,
    user_id UInt64,
    event_type String,
    event_time DateTime
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (user_id, event_time);

-- 添加 set 索引
ALTER TABLE events
ADD INDEX idx_event_type event_type
TYPE set(0)
GRANULARITY 4;

-- ========================================
-- 索引粒度
-- ========================================

-- 创建 bloom_filter 索引
CREATE TABLE events (
    event_id UInt64,
    user_id UInt64,
    user_email String,
    event_time DateTime
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (user_id, event_time);

-- 添加 bloom_filter 索引
ALTER TABLE events
ADD INDEX idx_user_email user_email
TYPE bloom_filter(0.01)
GRANULARITY 1;

-- ========================================
-- 索引粒度
-- ========================================

-- 创建 ngrambf_v1 索引
CREATE TABLE events (
    event_id UInt64,
    user_id UInt64,
    event_data String,
    event_time DateTime
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (user_id, event_time);

-- 添加 ngrambf_v1 索引
ALTER TABLE events
ADD INDEX idx_event_data event_data
TYPE ngrambf_v1(4, 256, 3, 0.01)
GRANULARITY 1;

-- ========================================
-- 索引粒度
-- ========================================

-- 创建 tokenbf_v1 索引
CREATE TABLE events (
    event_id UInt64,
    user_id UInt64,
    event_data String,
    event_time DateTime
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (user_id, event_time);

-- 添加 tokenbf_v1 索引
ALTER TABLE events
ADD INDEX idx_event_data event_data
TYPE tokenbf_v1(256, 3, 0)
GRANULARITY 1;

-- ========================================
-- 索引粒度
-- ========================================

-- 创建表时创建索引
CREATE TABLE events (
    event_id UInt64,
    user_id UInt64,
    event_type String,
    event_time DateTime,
    status UInt8
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (user_id, event_time)
SETTINGS index_granularity = 8192;

-- 添加索引
ALTER TABLE events
ADD INDEX idx_event_type event_type
TYPE set(2)
GRANULARITY 4;

ALTER TABLE events
ADD INDEX idx_status status
TYPE minmax
GRANULARITY 4;

-- ========================================
-- 索引粒度
-- ========================================

-- 查看表的索引
SELECT 
    database,
    table,
    name,
    type,
    expr,
    granularity,
    data_compressed_bytes,
    data_uncompressed_bytes,
    marks_count
FROM system.data_skipping_indices
WHERE database = 'my_database'
  AND table = 'events';

-- ========================================
-- 索引粒度
-- ========================================

-- 删除索引
ALTER TABLE events
DROP INDEX idx_event_type;

-- ========================================
-- 索引粒度
-- ========================================

-- 查询时禁用索引
SELECT * FROM events
SETTINGS force_primary_key = 1,  -- 禁用所有跳数索引
          skip_unused_shards = 1
WHERE event_type = 'click';

-- ========================================
-- 索引粒度
-- ========================================

CREATE TABLE events (
    event_id UInt64,
    user_id UInt64,
    event_type String,  -- 低基数（< 100 个值）
    event_time DateTime
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (user_id, event_time);

-- ✅ 使用 set 索引
ALTER TABLE events
ADD INDEX idx_event_type event_type
TYPE set(2)
GRANULARITY 4;

-- 查询使用索引
SELECT * FROM events
WHERE event_type = 'click'  -- ✅ 使用 set 索引
  AND event_time >= now() - INTERVAL 7 DAY;

-- ========================================
-- 索引粒度
-- ========================================

CREATE TABLE events (
    event_id UInt64,
    user_id UInt64,
    user_email String,  -- 高基数（每个用户唯一）
    event_time DateTime
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (user_id, event_time);

-- ✅ 使用 bloom_filter 索引
ALTER TABLE events
ADD INDEX idx_user_email user_email
TYPE bloom_filter(0.01)
GRANULARITY 1;

-- 查询使用索引
SELECT * FROM events
WHERE user_email = 'user@example.com'  -- ✅ 使用 bloom_filter 索引
  AND event_time >= now() - INTERVAL 7 DAY;

-- ========================================
-- 索引粒度
-- ========================================

CREATE TABLE events (
    event_id UInt64,
    user_id UInt64,
    event_data String,
    event_time DateTime
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (user_id, event_time);

-- ✅ 使用 ngrambf_v1 索引
ALTER TABLE events
ADD INDEX idx_event_data event_data
TYPE ngrambf_v1(4, 256, 3, 0.01)
GRANULARITY 1;

-- 查询使用索引
SELECT * FROM events
WHERE event_data LIKE '%laptop%'  -- ✅ 使用 ngrambf_v1 索引
  AND event_time >= now() - INTERVAL 7 DAY;

-- ========================================
-- 索引粒度
-- ========================================

CREATE TABLE events (
    event_id UInt64,
    user_id UInt64,
    event_type String,
    event_category String,
    status UInt8,
    event_time DateTime
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (user_id, event_time);

-- ✅ 创建多个索引
ALTER TABLE events
ADD INDEX idx_event_type event_type
TYPE set(2)
GRANULARITY 4;

ALTER TABLE events
ADD INDEX idx_event_category event_category
TYPE set(2)
GRANULARITY 4;

ALTER TABLE events
ADD INDEX idx_status status
TYPE minmax
GRANULARITY 4;

-- 查询使用多个索引
SELECT * FROM events
WHERE event_type = 'click'  -- ✅ 使用 set 索引
  AND event_category = 'product'  -- ✅ 使用 set 索引
  AND status = 1  -- ✅ 使用 minmax 索引
  AND event_time >= now() - INTERVAL 7 DAY;

-- ========================================
-- 索引粒度
-- ========================================

-- 查看索引使用统计
SELECT 
    index_name,
    marks,
    rows,
    bytes_on_disk,
    formatReadableSize(bytes_on_disk) as readable_size,
    type
FROM system.data_skipping_indices
WHERE database = 'my_database'
  AND table = 'events';

-- ========================================
-- 索引粒度
-- ========================================

-- 查看索引过滤效果
SELECT 
    query,
    read_rows,
    read_bytes,
    result_rows,
    result_bytes,
    formatReadableSize(read_bytes) as read_size,
    formatReadableSize(result_bytes) as result_size,
    read_rows / result_rows as filter_ratio
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_time >= now() - INTERVAL 24 HOUR
  AND read_rows > 100000
ORDER BY filter_ratio DESC
LIMIT 10;

-- ========================================
-- 索引粒度
-- ========================================

-- 低基数字符串：set
ALTER TABLE events
ADD INDEX idx_event_type event_type
TYPE set(2)
GRANULARITY 4;

-- 高基数字符串：bloom_filter
ALTER TABLE events
ADD INDEX idx_user_email user_email
TYPE bloom_filter(0.01)
GRANULARITY 1;

-- 数值范围：minmax
ALTER TABLE events
ADD INDEX idx_status status
TYPE minmax
GRANULARITY 4;

-- ========================================
-- 索引粒度
-- ========================================

-- ✅ 适量索引
CREATE TABLE events (
    event_id UInt64,
    user_id UInt64,
    event_type String,
    event_time DateTime
) ENGINE = MergeTree()
ORDER BY (user_id, event_time);

-- 只创建高频查询的索引
ALTER TABLE events ADD INDEX idx_event_type event_type TYPE set(2) GRANULARITY 4;
ALTER TABLE events ADD INDEX idx_status status TYPE minmax GRANULARITY 4;

-- ========================================
-- 索引粒度
-- ========================================

-- ✅ 适中的粒度
ALTER TABLE events
ADD INDEX idx_event_type event_type
TYPE set(2)
GRANULARITY 4;  -- 每 4 个 mark 存储索引

-- ========================================
-- 索引粒度
-- ========================================

-- 分析索引使用情况
SELECT 
    index_name,
    marks,
    type,
    bytes_on_disk
FROM system.data_skipping_indices
WHERE database = 'my_database'
  AND table = 'events'
ORDER BY bytes_on_disk DESC;
