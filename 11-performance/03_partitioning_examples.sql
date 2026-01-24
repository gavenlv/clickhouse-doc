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
