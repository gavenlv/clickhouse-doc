-- ================================================================================
-- ClickHouse 跳数索引优化示例
-- ================================================================================
-- 
-- 集群: treasurycluster (2 副本)
-- 预计学习时间: 25 分钟
-- 
-- 本文件涵盖:
--   1. 索引粒度概念 - index_granularity 与跳数索引粒度
--   2. minmax 索引 - 数值范围过滤
--   3. set 索引 - 低基数枚举
--   4. bloom_filter 索引 - 高基数精确匹配
--   5. ngrambf_v1 索引 - 文本 n-gram 搜索
--   6. tokenbf_v1 索引 - 分词文本搜索
--   7. 索引创建与管理 - ADD/DROP INDEX
--   8. 索引选择策略 - 按数据类型选择
-- 
-- 跳数索引工作原理:
-- 
--   ┌─────────────────────────────────────────────────────────────────────────┐
--   │                       跳数索引 (Data Skipping Index)                    │
--   └─────────────────────────────────────────────────────────────────────────┘
--   
--   数据块 (Granules):
--   ┌─────────────────────────────────────────────────────────────────────────┐
--   │ Granule 0      │ Granule 1      │ Granule 2      │ Granule 3           │
--   │ status: 1,2,3  │ status: 1,2    │ status: 3,4    │ status: 1,5         │
--   │ 8192 rows      │ 8192 rows      │ 8192 rows      │ 8192 rows           │
--   └────────────────┴────────────────┴────────────────┴─────────────────────┘
--          │                │                │                │
--          ▼                ▼                ▼                ▼
--   跳数索引 (每 4 个 Granule 一个索引块):
--   ┌─────────────────────────────────────────────────────────────────────────┐
--   │ Index Block 0              │ Index Block 1                              │
--   │ status: min=1, max=3       │ status: min=1, max=5                       │
--   │ 或 set(1,2,3)              │ 或 set(1,3,4,5)                            │
--   └────────────────────────────┴────────────────────────────────────────────┘
-- 
-- 查询: WHERE status = 5
-- 
--   ┌─────────────────────────────────────────────────────────────────────────┐
--   │ Index Block 0: status 范围 [1,3], 5 不在范围 → 跳过 Granule 0-3        │
--   │ Index Block 1: status 范围 [1,5], 5 可能在 → 读取 Granule 4-7          │
--   └─────────────────────────────────────────────────────────────────────────┘
-- 
-- 索引类型选择指南:
-- 
--   ┌─────────────────────────────────────────────────────────────────────────┐
--   │                         索引类型选择决策树                              │
--   └─────────────────────────────────────────────────────────────────────────┘
--   
--                        ┌─────────────────────┐
--                        │ 数据类型是什么?     │
--                        └──────────┬──────────┘
--                                   │
--         ┌─────────────┬───────────┼───────────┬─────────────┐
--         │             │           │           │             │
--         ▼             ▼           ▼           ▼             ▼
--      数值范围      低基数字符串  高基数字符串  文本搜索     文本分词
--         │             │           │           │             │
--         ▼             ▼           ▼           ▼             ▼
--    ┌─────────┐   ┌─────────┐ ┌─────────┐ ┌─────────┐  ┌─────────┐
--    │ minmax  │   │  set    │ │bloom_   │ │ngrambf_ │  │tokenbf_ │
--    │         │   │         │ │ filter  │ │   v1    │  │   v1    │
--    └─────────┘   └─────────┘ └─────────┘ └─────────┘  └─────────┘
-- 
-- 索引粒度示意图:
-- 
--   index_granularity = 8192 (每个 Granule 的行数)
--   跳数索引 GRANULARITY = 4 (每 4 个 Granule 建一个索引块)
--   
--   ┌────────────────────────────────────────────────────────────────────────┐
--   │ Granule │ Granule │ Granule │ Granule │ Granule │ Granule │ ...       │
--   │   0     │    1    │    2    │    3    │    4    │    5    │           │
--   │ 8192行  │ 8192行  │ 8192行  │ 8192行  │ 8192行  │ 8192行  │           │
--   └─────────┴─────────┴─────────┴─────────┴─────────┴─────────┴───────────┘
--   │                                                    │
--   └────────────────────┬───────────────────────────────┘
--                        │
--                        ▼
--             ┌─────────────────────┐
--             │ 一个跳数索引块       │
--             │ 覆盖 4个Granule     │
--             │ = 32768 行          │
--             └─────────────────────┘
-- 
-- ================================================================================

-- 创建数据库（如果存在则不创建）
CREATE DATABASE IF NOT EXISTS example;

-- 测试数据准备（幂等：先删后建，保证文件可独立重复运行）
DROP TABLE IF EXISTS events;

-- 事件表（统一 schema，包含后续示例所需的全部列）
CREATE TABLE IF NOT EXISTS events (
    event_id UInt64,
    user_id UInt64,
    event_type String,
    event_category String,
    status UInt8,
    user_email String,
    event_data String,
    event_time DateTime
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
CREATE TABLE IF NOT EXISTS events (
    event_id UInt64,
    user_id UInt64,
    event_time DateTime,
    status UInt8
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (user_id, event_time);

-- 添加 minmax 索引
ALTER TABLE events
ADD INDEX IF NOT EXISTS idx_status status
TYPE minmax
GRANULARITY 4;

-- ========================================
-- 索引粒度
-- ========================================

-- 创建 set 索引
CREATE TABLE IF NOT EXISTS events (
    event_id UInt64,
    user_id UInt64,
    event_type String,
    event_time DateTime
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (user_id, event_time);

-- 添加 set 索引
ALTER TABLE events
ADD INDEX IF NOT EXISTS idx_event_type event_type
TYPE set(0)
GRANULARITY 4;

-- ========================================
-- 索引粒度
-- ========================================

-- 创建 bloom_filter 索引
CREATE TABLE IF NOT EXISTS events (
    event_id UInt64,
    user_id UInt64,
    user_email String,
    event_time DateTime
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (user_id, event_time);

-- 添加 bloom_filter 索引
ALTER TABLE events
ADD INDEX IF NOT EXISTS idx_user_email user_email
TYPE bloom_filter(0.01)
GRANULARITY 1;

-- ========================================
-- 索引粒度
-- ========================================

-- 创建 ngrambf_v1 索引
CREATE TABLE IF NOT EXISTS events (
    event_id UInt64,
    user_id UInt64,
    event_data String,
    event_time DateTime
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (user_id, event_time);

-- 添加 ngrambf_v1 索引
-- 说明: ngrambf_v1 必须恰好 4 个无符号整数参数（25.12 不接受浮点 false positive 参数），第 4 个参数为随机种子
ALTER TABLE events
ADD INDEX IF NOT EXISTS idx_event_data event_data
TYPE ngrambf_v1(4, 256, 3, 1)
GRANULARITY 1;

-- ========================================
-- 索引粒度
-- ========================================

-- 创建 tokenbf_v1 索引
CREATE TABLE IF NOT EXISTS events (
    event_id UInt64,
    user_id UInt64,
    event_data String,
    event_time DateTime
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (user_id, event_time);

-- 添加 tokenbf_v1 索引
-- 说明: 上方 ngrambf_v1 已占用 idx_event_data 名称，此处改用 idx_event_data_tok，使 tokenbf_v1 教学示例真实生效
ALTER TABLE events
ADD INDEX IF NOT EXISTS idx_event_data_tok event_data
TYPE tokenbf_v1(256, 3, 0)
GRANULARITY 1;

-- ========================================
-- 索引粒度
-- ========================================

-- 创建表时创建索引
CREATE TABLE IF NOT EXISTS events (
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
ADD INDEX IF NOT EXISTS idx_event_type event_type
TYPE set(2)
GRANULARITY 4;

ALTER TABLE events
ADD INDEX IF NOT EXISTS idx_status status
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
    marks_bytes
FROM system.data_skipping_indices
WHERE database = 'default'
  AND table = 'events';

-- ========================================
-- 索引粒度
-- ========================================

-- 删除索引
ALTER TABLE events
DROP INDEX IF EXISTS idx_event_type;

-- ========================================
-- 索引粒度
-- ========================================

-- 查询时禁用跳数索引
-- 说明: skip_unused_shards 在 25.12 不存在，禁用跳数索引使用 use_skip_indexes = 0
SELECT * FROM events
WHERE event_type = 'click'
SETTINGS use_skip_indexes = 0;

-- ========================================
-- 索引粒度
-- ========================================

CREATE TABLE IF NOT EXISTS events (
    event_id UInt64,
    user_id UInt64,
    event_type String,  -- 低基数（< 100 个值）
    event_time DateTime
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (user_id, event_time);

-- ✅ 使用 set 索引
ALTER TABLE events
ADD INDEX IF NOT EXISTS idx_event_type event_type
TYPE set(2)
GRANULARITY 4;

-- 查询使用索引
SELECT * FROM events
WHERE event_type = 'click'  -- ✅ 使用 set 索引
  AND event_time >= now() - INTERVAL 7 DAY;

-- ========================================
-- 索引粒度
-- ========================================

CREATE TABLE IF NOT EXISTS events (
    event_id UInt64,
    user_id UInt64,
    user_email String,  -- 高基数（每个用户唯一）
    event_time DateTime
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (user_id, event_time);

-- ✅ 使用 bloom_filter 索引
ALTER TABLE events
ADD INDEX IF NOT EXISTS idx_user_email user_email
TYPE bloom_filter(0.01)
GRANULARITY 1;

-- 查询使用索引
SELECT * FROM events
WHERE user_email = 'user@example.com'  -- ✅ 使用 bloom_filter 索引
  AND event_time >= now() - INTERVAL 7 DAY;

-- ========================================
-- 索引粒度
-- ========================================

CREATE TABLE IF NOT EXISTS events (
    event_id UInt64,
    user_id UInt64,
    event_data String,
    event_time DateTime
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (user_id, event_time);

-- ✅ 使用 ngrambf_v1 索引
ALTER TABLE events
ADD INDEX IF NOT EXISTS idx_event_data event_data
TYPE ngrambf_v1(4, 256, 3, 1)
GRANULARITY 1;

-- 查询使用索引
SELECT * FROM events
WHERE event_data LIKE '%laptop%'  -- ✅ 使用 ngrambf_v1 索引
  AND event_time >= now() - INTERVAL 7 DAY;

-- ========================================
-- 索引粒度
-- ========================================

CREATE TABLE IF NOT EXISTS events (
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
ADD INDEX IF NOT EXISTS idx_event_type event_type
TYPE set(2)
GRANULARITY 4;

ALTER TABLE events
ADD INDEX IF NOT EXISTS idx_event_category event_category
TYPE set(2)
GRANULARITY 4;

ALTER TABLE events
ADD INDEX IF NOT EXISTS idx_status status
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
-- 说明: 25.12 的 system.data_skipping_indices 无 rows/bytes_on_disk/marks 列，改用 data_compressed_bytes/data_uncompressed_bytes/marks_bytes
SELECT 
    name AS index_name,
    type,
    granularity,
    data_compressed_bytes,
    data_uncompressed_bytes,
    marks_bytes,
    formatReadableSize(data_compressed_bytes) as readable_size
FROM system.data_skipping_indices
WHERE database = 'default'
  AND table = 'events';

-- ========================================
-- 索引粒度
-- ========================================

-- 查看索引过滤效果
-- 说明: 25.12 集群 system.query_log 未启用，改用 system.query_thread_log（需先 SET log_query_threads = 1）；
--       query_thread_log 无 result_rows/result_bytes 列，故以 read_rows/read_bytes 衡量过滤效果
SET log_query_threads = 1;

SELECT 
    query,
    read_rows,
    read_bytes,
    query_duration_ms,
    formatReadableSize(read_bytes) as read_size
FROM system.query_thread_log
WHERE event_time >= now() - INTERVAL 24 HOUR
ORDER BY read_rows DESC
LIMIT 10;

-- ========================================
-- 索引粒度
-- ========================================

-- 低基数字符串：set
ALTER TABLE events
ADD INDEX IF NOT EXISTS idx_event_type event_type
TYPE set(2)
GRANULARITY 4;

-- 高基数字符串：bloom_filter
ALTER TABLE events
ADD INDEX IF NOT EXISTS idx_user_email user_email
TYPE bloom_filter(0.01)
GRANULARITY 1;

-- 数值范围：minmax
ALTER TABLE events
ADD INDEX IF NOT EXISTS idx_status status
TYPE minmax
GRANULARITY 4;

-- ========================================
-- 索引粒度
-- ========================================

-- ✅ 适量索引
CREATE TABLE IF NOT EXISTS events (
    event_id UInt64,
    user_id UInt64,
    event_type String,
    event_time DateTime
) ENGINE = MergeTree()
ORDER BY (user_id, event_time);

-- 只创建高频查询的索引
ALTER TABLE events ADD INDEX IF NOT EXISTS idx_event_type event_type TYPE set(2) GRANULARITY 4;
ALTER TABLE events ADD INDEX IF NOT EXISTS idx_status status TYPE minmax GRANULARITY 4;

-- ========================================
-- 索引粒度
-- ========================================

-- ✅ 适中的粒度
ALTER TABLE events
ADD INDEX IF NOT EXISTS idx_event_type event_type
TYPE set(2)
GRANULARITY 4;  -- 每 4 个 mark 存储索引

-- ========================================
-- 索引粒度
-- ========================================

-- 分析索引使用情况
SELECT 
    name AS index_name,
    type,
    granularity,
    data_compressed_bytes,
    marks_bytes
FROM system.data_skipping_indices
WHERE database = 'default'
  AND table = 'events'
ORDER BY data_compressed_bytes DESC;
