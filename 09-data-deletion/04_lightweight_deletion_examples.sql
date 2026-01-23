-- ================================================
-- 04_lightweight_deletion_examples.sql
-- 从 04_lightweight_deletion.md 提取的 SQL 示例
-- 提取时间: 2026-01-23 14:40:17
-- ================================================


-- ========================================
-- 📋 基本语法
-- ========================================

-- 轻量级删除
ALTER TABLE table_name
DELETE WHERE condition
SETTINGS lightweight_delete = 1;

-- 等价于
ALTER TABLE table_name
DELETE LIGHTWEIGHT WHERE condition;

-- ========================================
-- 📋 基本语法
-- ========================================

-- 轻量级删除是异步的
ALTER TABLE events
DELETE WHERE event_time < '2023-01-01'
SETTINGS lightweight_delete = 1;

-- 删除会立即返回，后台执行

-- ========================================
-- 📋 基本语法
-- ========================================

-- 轻量级删除使用标记机制
-- 数据不会被立即删除，而是标记为已删除

-- 查看被标记删除的数据
SELECT
    _part,
    _block_offset,
    _row_num,
    *
FROM events
WHERE event_time < '2023-01-01'
SETTINGS allow_experimental_lightweight_delete = 1;

-- ========================================
-- 📋 基本语法
-- ========================================

-- 删除少量数据（<10%）
ALTER TABLE events
DELETE WHERE event_id = 12345
SETTINGS lightweight_delete = 1;

-- 删除中等量数据（10-30%）
ALTER TABLE events
DELETE WHERE user_id = 'user123'
SETTINGS lightweight_delete = 1;

-- ========================================
-- 📋 基本语法
-- ========================================

-- 快速删除用户数据
ALTER TABLE user_events
DELETE WHERE user_id = 'user123'
SETTINGS lightweight_delete = 1;

ALTER TABLE user_profile
DELETE WHERE user_id = 'user123'
SETTINGS lightweight_delete = 1;

-- 记录删除操作
INSERT INTO data_deletion_log
VALUES ('user123', now(), 'lightweight_delete');

-- ========================================
-- 📋 基本语法
-- ========================================

-- 实时删除过期数据
CREATE MATERIALIZED VIEW expired_events_mv
ENGINE = MergeTree()
ORDER BY event_id
AS SELECT
    event_id,
    user_id,
    event_time
FROM events
WHERE event_time < now() - INTERVAL 90 DAY;

-- 定期执行轻量级删除
-- 可以通过外部调度器触发
ALTER TABLE events
DELETE WHERE event_time < now() - INTERVAL 90 DAY
SETTINGS lightweight_delete = 1;

-- ========================================
-- 📋 基本语法
-- ========================================

-- 删除测试环境数据
ALTER TABLE events
DELETE WHERE environment = 'test'
SETTINGS lightweight_delete = 1;

-- 删除调试数据
ALTER TABLE logs
DELETE WHERE level = 'debug'
SETTINGS lightweight_delete = 1;

-- ========================================
-- 📋 基本语法
-- ========================================

-- 查看活跃的轻量级删除
SELECT
    query_id,
    query,
    elapsed,
    read_rows,
    written_rows,
    memory_usage
FROM system.processes
WHERE query ILIKE '%lightweight%'
ORDER BY elapsed DESC;

-- ========================================
-- 📋 基本语法
-- ========================================

-- 查看被标记删除的数据
SELECT
    _part,
    _block_offset,
    count() as deleted_count
FROM events
WHERE event_time < '2023-01-01'
GROUP BY _part, _block_offset
SETTINGS allow_experimental_lightweight_delete = 1;

-- ========================================
-- 📋 基本语法
-- ========================================

-- 监控轻量级删除的空间占用
SELECT
    'Active Rows' as metric,
    sum(rows) as value,
    formatReadableSize(sum(bytes_on_disk)) as size
FROM system.parts
WHERE table = 'events' AND active = 1

UNION ALL

SELECT
    'Marked for Deletion',
    count(),
    formatReadableSize(sum(length(data)))
FROM events
WHERE event_time < '2023-01-01'
SETTINGS allow_experimental_lightweight_delete = 1;

-- ========================================
-- 📋 基本语法
-- ========================================

-- 从用户删除列表中读取要删除的用户 ID
-- 假设有一个表存储了要删除的用户
CREATE TABLE users_to_delete (
    user_id String
) ENGINE = MergeTree()
ORDER BY user_id;

-- 插入要删除的用户 ID
INSERT INTO users_to_delete VALUES
    ('user123'),
    ('user456'),
    ('user789');

-- 执行轻量级删除
ALTER TABLE user_events
DELETE WHERE user_id IN (
    SELECT user_id FROM users_to_delete
)
SETTINGS lightweight_delete = 1;

ALTER TABLE user_profile
DELETE WHERE user_id IN (
    SELECT user_id FROM users_to_delete
)
SETTINGS lightweight_delete = 1;

-- 清空删除列表
TRUNCATE TABLE users_to_delete;

-- ========================================
-- 📋 基本语法
-- ========================================

-- 创建监控视图
CREATE VIEW deletion_monitor AS
SELECT
    now() as timestamp,
    'lightweight_delete' as deletion_type,
    count() as rows_marked,
    formatReadableSize(sum(length(data))) as size_marked
FROM events
WHERE event_time < now() - INTERVAL 90 DAY
SETTINGS allow_experimental_lightweight_delete = 1;

-- 定期查询监控数据
SELECT * FROM deletion_monitor
ORDER BY timestamp DESC
LIMIT 1;

-- ========================================
-- 📋 基本语法
-- ========================================

-- 轻量级删除只是标记数据
-- 实际删除需要通过合并操作

-- 触发合并以清理已标记的数据
OPTIMIZE TABLE events FINAL;

-- 或者等待自然的合并过程
-- 可以调整合并策略加快合并

-- 查看合并进度
SELECT
    table,
    partition,
    sum(rows) as rows,
    count() as parts
FROM system.parts
WHERE table = 'events' AND active = 1
GROUP BY table, partition;

-- ========================================
-- 📋 基本语法
-- ========================================

-- 在查询中启用
SELECT * FROM events
SETTINGS allow_experimental_lightweight_delete = 1;

-- 执行轻量级删除
ALTER TABLE events
DELETE WHERE event_time < '2023-01-01'
SETTINGS lightweight_delete = 1;

-- ========================================
-- 📋 基本语法
-- ========================================

-- 检查 ClickHouse 版本
SELECT version();

-- 轻量级删除需要 ClickHouse 23.8 或更高版本
-- 如果版本过低，会回退到传统的 Mutation 删除

-- ========================================
-- 📋 基本语法
-- ========================================

-- 轻量级删除不会立即释放存储空间
-- 已标记删除的数据仍然占用空间

-- 查看实际占用的空间
SELECT
    'Total on disk' as metric,
    formatReadableSize(sum(bytes_on_disk)) as value
FROM system.parts
WHERE table = 'events' AND active = 1

UNION ALL

SELECT
    'Estimated actual after cleanup',
    formatReadableSize(sum(bytes_on_disk * (1 - 0.3)))  -- 假设 30% 被标记删除
FROM system.parts
WHERE table = 'events' AND active = 1;

-- ========================================
-- 📋 基本语法
-- ========================================

-- 轻量级删除适用于删除少量数据
-- 如果删除大量数据（>30%），应该使用分区删除

-- 判断是否应该使用轻量级删除
SELECT
    count() as total_rows,
    countIf(event_time < '2023-01-01') as rows_to_delete,
    rows_to_delete * 100.0 / total_rows as delete_percentage,
    CASE 
        WHEN rows_to_delete * 100.0 / total_rows < 30 THEN 'Use lightweight delete'
        ELSE 'Use partition deletion'
    END as recommendation
FROM events;
