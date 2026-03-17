-- ================================================================================
-- ClickHouse 分区策略优化示例
-- ================================================================================
-- 
-- 集群: treasurycluster (2 副本)
-- 预计学习时间: 20 分钟
-- 
-- 本文件涵盖:
--   1. 分区类型 - 时间、哈希、枚举分区
--   2. 分区大小控制 - 1-10 GB 最佳
--   3. 分区数量控制 - 避免过多分区
--   4. 分区裁剪 - 利用分区过滤
--   5. 分区操作 - 查询、删除、复制、交换
--   6. TTL 分区 - 自动过期
-- 
-- 分区 vs 主键索引:
-- 
--   ┌─────────────────────────────────────────────────────────────────────────┐
--   │                      分区与主键索引的区别                                │
--   └─────────────────────────────────────────────────────────────────────────┘
--   
--   ┌───────────────────────────────────────────────────────────────────────┐
--   │                            分区 (PARTITION)                           │
--   │  ┌─────────────────────────────────────────────────────────────────┐  │
--   │  │ - 物理分隔：每个分区是独立的目录                                 │  │
--   │  │ - 粗粒度过滤：适合大范围删除、归档                               │  │
--   │  │ - 操作级别：DROP PARTITION 是瞬间操作                           │  │
--   │  │ - 分区数量：建议 < 1000 个活跃分区                               │  │
--   │  └─────────────────────────────────────────────────────────────────┘  │
--   └───────────────────────────────────────────────────────────────────────┘
--   
--   ┌───────────────────────────────────────────────────────────────────────┐
--   │                          主键索引 (ORDER BY)                          │
--   │  ┌─────────────────────────────────────────────────────────────────┐  │
--   │  │ - 逻辑排序：数据按 ORDER BY 排序存储                             │  │
--   │  │ - 细粒度过滤：适合精确查询和范围查询                             │  │
--   │  │ - 查询优化：稀疏索引快速定位数据                                 │  │
--   │  │ - 列数量：建议 2-3 列                                            │  │
--   │  └─────────────────────────────────────────────────────────────────┘  │
--   └───────────────────────────────────────────────────────────────────────┘
-- 
-- 分区策略选择:
-- 
--   ┌─────────────────┐
--   │ 数据量/天       │
--   └────────┬────────┘
--            │
--   ┌───────┴────────┐
--   │                │
--   ▼                ▼
--   < 1GB          > 1GB
--   按月分区       按日分区
--   │                │
--   │                ▼
--   │         ┌─────────────┐
--   │         │ TTL < 30天? │
--   │         └──────┬──────┘
--   │                │
--   │        ┌───────┴───────┐
--   │        │               │
--   │        ▼               ▼
--   │      是(按日)       否(按月)
--   │
--   └────────────────────────────────────> 分区策略
-- 
-- 分区裁剪效果:
-- 
--   表: events (按月分区 toYYYYMM)
--   查询: WHERE event_time >= '2024-01-01' AND event_time < '2024-02-01'
--   
--   分区列表:
--   ┌───────────────────────────────────────────────────────────────────────┐
--   │ 202301 │ 202302 │ ... │ 202312 │ 202401 │ 202402 │ 202403 │ 202404 │
--   │  跳过  │  跳过  │     │  跳过  │ 读取   │  跳过  │  跳过  │  跳过  │
--   └───────────────────────────────────────────────────────────────────────┘
--                                            ▲
--                                            │
--                                   只扫描这个分区
-- 
-- ================================================================================

-- 分区类型示例
PARTITION BY toYYYYMM(event_time)

-- 按月份分区
PARTITION BY toMonth(event_time)

-- 按天分区
PARTITION BY toDate(event_time)

-- 按值分区
PARTITION BY user_id % 100

-- 按枚举分区
PARTITION BY status

-- ========================================
-- 分区类型
-- ========================================

-- ✅ 按月分区（推荐）
CREATE TABLE IF NOT EXISTS events (
    event_id UInt64,
    user_id UInt64,
    event_time DateTime,
    event_data String
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)  -- ✅ 按月
ORDER BY (user_id, event_time);

-- ❌ 按天分区（分区过多）
CREATE TABLE IF NOT EXISTS events (
    event_id UInt64,
    user_id UInt64,
    event_time DateTime,
    event_data String
) ENGINE = MergeTree()
PARTITION BY toDate(event_time)  -- ❌ 按天（分区过多）
ORDER BY (user_id, event_time);

-- ========================================
-- 分区类型
-- ========================================

-- ✅ 适中的分区大小（1-10 GB）
PARTITION BY toYYYYMM(event_time)  -- 按月，通常 1-10 GB

-- ❌ 过小的分区
PARTITION BY toYYYYMMDD(event_time)  -- 按天，可能 < 100 MB

-- ❌ 过大的分区
PARTITION BY toYYYY(event_time)  -- 按年，可能 > 100 GB

-- ========================================
-- 分区类型
-- ========================================

-- ✅ 适中的分区数量
PARTITION BY toYYYYMM(event_time)  -- 12 个月/年

-- ❌ 过多的分区
PARTITION BY toYYYYMMDD(event_time)  -- 365 天/年

-- ========================================
-- 分区类型
-- ========================================

-- 如果查询主要按时间范围
CREATE TABLE IF NOT EXISTS events (
    event_id UInt64,
    user_id UInt64,
    event_time DateTime
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)  -- ✅ 匹配查询模式
ORDER BY (user_id, event_time);

-- 如果查询主要按用户
CREATE TABLE IF NOT EXISTS user_events (
    event_id UInt64,
    user_id UInt64,
    event_time DateTime
) ENGINE = MergeTree()
PARTITION BY user_id % 100  -- ✅ 匹配查询模式
ORDER BY (event_time);

-- ========================================
-- 分区类型
-- ========================================

-- ✅ 使用分区裁剪（快速）
SELECT * FROM events
WHERE event_time >= '2024-01-01'
  AND event_time < '2024-02-01';

-- ❌ 不使用分区裁剪（慢速）
SELECT * FROM events
WHERE toYYYYMM(event_time) = '202401';

-- ========================================
-- 分区类型
-- ========================================

-- 查询特定分区
SELECT * FROM events
PARTITION '202401'
WHERE user_id = 123;

-- 查询多个分区
SELECT * FROM events
WHERE event_time >= '2024-01-01'
  AND event_time < '2024-03-01';

-- ========================================
-- 分区类型
-- ========================================

-- 使用虚拟列 `_partition_id`
SELECT 
    _partition_id,
    count() as row_count
FROM events
GROUP BY _partition_id;

-- ========================================
-- 分区类型
-- ========================================

-- 查看表的分区
SELECT 
    '',
    name,
    sum(rows) as total_rows,
    sum(bytes_on_disk) as total_bytes,
    formatReadableSize(sum(bytes_on_disk)) as readable_size
FROM system.parts
WHERE database = 'my_database'
  AND table = 'events'
  AND active = 1
GROUP BY partition, name
ORDER BY partition;

-- ========================================
-- 分区类型
-- ========================================

-- 删除单个分区
ALTER TABLE events
DROP PARTITION '202401';

-- 删除多个分区
ALTER TABLE events
DROP PARTITION '202301', '202302', '202303';

-- 删除旧分区
ALTER TABLE events
DROP PARTITION '202301', '202302', '202303', '202304', '202305';

-- ========================================
-- 分区类型
-- ========================================

-- 复制分区到另一个表
CREATE TABLE IF NOT EXISTS events_new AS events;

ALTER TABLE events_new
REPLACE PARTITION '202401'
FROM events;

-- ========================================
-- 分区类型
-- ========================================

-- 交换分区
ALTER TABLE events_archive
EXCHANGE PARTITION '202401'
WITH events;

-- ========================================
-- 分区类型
-- ========================================

CREATE TABLE IF NOT EXISTS events (
    event_id UInt64,
    user_id UInt64,
    event_type String,
    event_time DateTime,
    event_data String
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)  -- ✅ 按月分区
ORDER BY (user_id, event_time);

-- 查询优化
SELECT * FROM events
WHERE event_time >= '2024-01-01'
  AND event_time < '2024-02-01';  -- ✅ 使用分区裁剪

-- ========================================
-- 分区类型
-- ========================================

CREATE TABLE IF NOT EXISTS user_events (
    event_id UInt64,
    user_id UInt64,
    event_time DateTime,
    event_data String
) ENGINE = MergeTree()
PARTITION BY intHash32(user_id) % 100  -- ✅ 按用户哈希
ORDER BY (user_id, event_time);

-- 查询特定用户
SELECT * FROM user_events
WHERE user_id = 123;  -- ✅ 只扫描一个分区

-- ========================================
-- 分区类型
-- ========================================

CREATE TABLE IF NOT EXISTS orders (
    order_id UInt64,
    user_id UInt64,
    amount Float64,
    order_date DateTime,
    status String
) ENGINE = MergeTree()
PARTITION BY status  -- ✅ 按状态分区
ORDER BY (order_date, order_id);

-- 查询特定状态
SELECT * FROM orders
WHERE status = 'pending';  -- ✅ 只扫描一个分区

-- ========================================
-- 分区类型
-- ========================================

CREATE TABLE IF NOT EXISTS events (
    event_id UInt64,
    user_id UInt64,
    event_type String,
    event_time DateTime,
    event_data String
) ENGINE = MergeTree()
PARTITION BY (toYYYYMM(event_time), user_id % 10)  -- ✅ 时间 + 用户哈希
ORDER BY (user_id, event_time);

-- 查询优化
SELECT * FROM events
WHERE event_time >= '2024-01-01'
  AND event_time < '2024-02-01'
  AND user_id = 123;  -- ✅ 只扫描一个分区

-- ========================================
-- 分区类型
-- ========================================

CREATE TABLE IF NOT EXISTS events (
    event_id UInt64,
    user_id UInt64,
    event_time DateTime,
    event_data String
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (user_id, event_time)
TTL event_time + INTERVAL 90 DAY;  -- ✅ 90 天后自动删除

-- ========================================
-- 分区类型
-- ========================================

-- 活跃数据：按天分区
CREATE TABLE IF NOT EXISTS events_active (
    event_id UInt64,
    user_id UInt64,
    event_time DateTime,
    event_data String
) ENGINE = MergeTree()
PARTITION BY toDate(event_time)  -- 按天
ORDER BY (user_id, event_time);

-- 历史数据：按月分区
CREATE TABLE IF NOT EXISTS events_history (
    event_id UInt64,
    user_id UInt64,
    event_time DateTime,
    event_data String
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)  -- 按月
ORDER BY (user_id, event_time);

-- ========================================
-- 分区类型
-- ========================================

-- 定期归档旧分区
ALTER TABLE events
DROP PARTITION '202301', '202302', '202303';

-- 或移动到归档表
ALTER TABLE events_archive
EXCHANGE PARTITION '202301', '202302', '202303'
WITH events;

-- ========================================
-- 分区类型
-- ========================================

-- 监控分区大小
SELECT 
    '',
    sum(rows) as total_rows,
    sum(bytes_on_disk) as total_bytes,
    formatReadableSize(sum(bytes_on_disk)) as readable_size
FROM system.parts
WHERE database = 'my_database'
  AND table = 'events'
  AND active = 1
GROUP BY partition
HAVING total_bytes > 10737418240  -- > 10 GB
ORDER BY total_bytes DESC;

-- ========================================
-- 分区类型
-- ========================================

-- 手动合并小分区
OPTIMIZE TABLE events
PARTITION '202401'
FINAL;
