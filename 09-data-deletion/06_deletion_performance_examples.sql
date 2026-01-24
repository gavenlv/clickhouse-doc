CREATE TABLE IF NOT EXISTS performance_test (
    id UInt64,
    event_time DateTime,
    data String
) ENGINE = MergeTree
PARTITION BY toYYYYMM(event_time)
ORDER BY id;

-- 插入 1 亿行测试数据
INSERT INTO performance_test
SELECT 
    number,
    toDateTime('2023-01-01 00:00:00') + toIntervalMinute(number),
    repeat('data', 10)
FROM numbers(100000000);

-- 测试不同删除方法的性能

-- ========================================
-- 删除方法性能对比
-- ========================================

-- 最快的删除方法

-- 查看分区信息
SELECT
    '',
    formatReadableSize(sum(bytes_on_disk)) AS size,
    sum(rows) AS rows
FROM system.parts
WHERE table = 'performance_test' AND active = 1
GROUP BY partition
ORDER BY partition;

-- 删除整个分区
ALTER TABLE performance_test
DROP PARTITION '202301';

-- 性能：⭐⭐⭐⭐⭐ 极快

-- ========================================
-- 删除方法性能对比
-- ========================================

-- 将大删除拆分为多个小批次

-- 查看要删除的数据量
SELECT
    count() AS total_rows,
    count() / 10 AS rows_per_batch
FROM performance_test
WHERE event_time < '2023-03-01';

-- 分 10 批次删除
-- 批次 1
ALTER TABLE performance_test
DELETE WHERE 
    event_time >= '2023-01-01' 
    AND event_time < '2023-01-15'
-- REMOVED SET max_threads (not supported) 4;

-- 等待完成
-- SELECT is_done FROM system.mutations WHERE ...

-- 批次 2
ALTER TABLE performance_test
DELETE WHERE 
    event_time >= '2023-01-15' 
    AND event_time < '2023-02-01'
-- REMOVED SET max_threads (not supported) 4;

-- 性能提升：减少单次操作的 I/O 和 CPU 峰值

-- ========================================
-- 删除方法性能对比
-- ========================================

-- 限制并发线程数以减少系统负载

-- 使用较少的线程
ALTER TABLE performance_test
DELETE WHERE event_time < '2023-03-01'
-- REMOVED SET max_threads (not supported) 2;

-- 使用更多线程（如果系统负载低）
ALTER TABLE performance_test
DELETE WHERE event_time < '2023-03-01'
-- REMOVED SET max_threads (not supported) 8;

-- 建议：根据系统负载动态调整

-- ========================================
-- 删除方法性能对比
-- ========================================

-- 调整合并策略以优化删除后的性能

-- 查看当前合并设置
SELECT
    name,
    value,
    changed
FROM system.settings
WHERE name LIKE '%merge%';

-- 调整合并参数
SET max_bytes_to_merge_at_once = 10737418240;  -- 10GB
SET max_rows_to_merge_at_once = 1000000;         -- 100 万行

-- 删除后触发合并
OPTIMIZE TABLE performance_test FINAL;

-- ========================================
-- 删除方法性能对比
-- ========================================

-- 在业务低峰期执行删除操作

-- 查看当前系统负载
SELECT
    metric,
    value,
    description
FROM system.asynchronous_metrics
WHERE metric IN (
    'OSUsers',
    'OSNiceTime',
    'OSIdleTime',
    'OSSystemTime'
);

-- 建议在以下时间执行：
-- - 凌晨 2-6 点（业务低峰）
-- - 周末
-- - 节假日

-- ========================================
-- 删除方法性能对比
-- ========================================

-- 实时监控删除操作
SELECT
    query_id,
    user,
    query,
    elapsed,
    read_rows,
    read_bytes,
    memory_usage,
    thread_ids
FROM system.processes
WHERE query ILIKE '%DELETE%'
  OR query ILIKE '%DROP%'
ORDER BY elapsed DESC;

-- ========================================
-- 删除方法性能对比
-- ========================================

-- 监控删除期间的系统资源使用
SELECT
    'CPU' as metric,
    (sum(OSUserTime) + sum(OSSystemTime)) / sum(OSIdleTime) as value
FROM system.asynchronous_metrics
WHERE metric LIKE 'OS%'

UNION ALL

SELECT
    'Memory (GB)',
    formatReadableSize(MemoryTracking) as value
FROM system.metrics

UNION ALL

SELECT
    'Disk Read (MB/s)',
    formatReadableSize(ReadBufferFromFileDescriptorBytes / 1e6)
FROM system.metrics;

-- ========================================
-- 删除方法性能对比
-- ========================================

-- 监控 Mutation 执行进度
SELECT
    mutation_id,
    command,
    is_done,
    parts_to_do,
    parts_done,
    (parts_done * 100.0 / NULLIF(parts_to_do, 0)) as progress_percent,
    create_time,
    elapsed_seconds
FROM system.mutations
WHERE database = 'your_database'
ORDER BY create_time DESC;

-- ========================================
-- 删除方法性能对比
-- ========================================

-- 创建表时设置优化参数
CREATE TABLE IF NOT EXISTS optimized_table (
    id UInt64,
    event_time DateTime,
    data String
) ENGINE = MergeTree
PARTITION BY toYYYYMM(event_time)
ORDER BY id
SETTINGS -- REMOVED SETTING max_memory_usage (not supported) 2000000000;               -- 2GB

-- ========================================
-- 删除方法性能对比
-- ========================================

-- 在查询中设置优化参数
ALTER TABLE performance_test
DELETE WHERE event_time < '2023-03-01'
-- REMOVED SET max_threads (not supported) 4,
    max_memory_usage = 2000000000,
    max_insert_threads = 2;

-- ========================================
-- 删除方法性能对比
-- ========================================

-- 1. 先删除大部分数据（使用分区删除）
ALTER TABLE events
DROP PARTITION '2022-12';

-- 2. 再删除少量数据（使用 Mutation）
ALTER TABLE events
DELETE WHERE 
    event_time >= '2023-01-01'
    AND event_time < '2023-01-15'
    AND user_id = 'deleted_user'
-- REMOVED SET max_threads (not supported) 2;

-- 性能：分区删除 + 少量 Mutation = 最优性能

-- ========================================
-- 删除方法性能对比
-- ========================================

-- 1. 使用轻量级删除标记数据
ALTER TABLE events
DELETE WHERE event_time < '2023-01-01'
SETTINGS lightweight_delete = 1;

-- 2. 定期触发合并清理已标记的数据
-- 可以通过 cron 每天执行
OPTIMIZE TABLE events PARTITION '2022-12' FINAL
-- REMOVED SET max_threads (not supported) 4;

-- 性能：轻量级删除（快速）+ 定期 OPTIMIZE（后台清理）

-- ========================================
-- 删除方法性能对比
-- ========================================

-- 1. 创建物化视图捕获删除操作
CREATE MATERIALIZED VIEW delete_operations_log
ENGINE = MergeTree()
ORDER BY timestamp
AS
SELECT
    now() AS timestamp,
    database,
    table,
    command
FROM system.mutations
WHERE command ILIKE '%DELETE%';

-- 2. 监控删除操作
SELECT
    toStartOfHour(timestamp) AS hour,
    count() AS delete_operations,
    avg(elapsed_seconds) AS avg_duration
FROM delete_operations_log
WHERE timestamp >= now() - INTERVAL 24 HOUR
GROUP BY hour
ORDER BY hour;

-- 3. 根据监控数据优化删除策略

-- ========================================
-- 删除方法性能对比
-- ========================================

-- ClickHouse 23.8+ 使用轻量级删除
ALTER TABLE events
DELETE WHERE event_time < '2023-01-01'
SETTINGS lightweight_delete = 1;

-- 性能提升：3-5 倍

-- ========================================
-- 删除方法性能对比
-- ========================================

-- 限制并发线程数
ALTER TABLE events
DELETE WHERE event_time < '2023-01-01'
-- REMOVED SET max_threads (not supported) 2;

-- 性能影响：减少 CPU 和 I/O 峰值

-- ========================================
-- 删除方法性能对比
-- ========================================

-- 确保删除条件使用索引

-- 查看表的排序键
SELECT 
    name AS table,
    sorting_key
FROM system.tables
WHERE name = 'events';

-- 优化：使删除条件与排序键匹配
ALTER TABLE events
DELETE WHERE 
    event_time < '2023-01-01'  -- event_time 是排序键
    AND user_id = 'user123';

-- 性能提升：减少扫描的数据量

-- ========================================
-- 删除方法性能对比
-- ========================================

-- ❌ 避免：全表扫描
ALTER TABLE events
DELETE WHERE data LIKE '%test%';

-- ✅ 推荐：使用分区裁剪
ALTER TABLE events
DELETE WHERE 
    partition = '202301'  -- 只扫描特定分区
    AND data LIKE '%test%';

-- 性能提升：只扫描需要的分区

-- ========================================
-- 删除方法性能对比
-- ========================================

-- 设置 TTL 自动清理
ALTER TABLE events
MODIFY TTL event_time + INTERVAL 90 DAY;

-- 性能优势：自动化，无需手动干预

-- ========================================
-- 删除方法性能对比
-- ========================================

-- ❌ 陷阱：一次性删除大量数据
ALTER TABLE events
DELETE WHERE event_time < '2023-01-01';  -- 删除 50% 的数据

-- 影响：系统负载高，查询性能下降

-- ✅ 解决：分批次删除
-- （参考上面的批次删除脚本）

-- ========================================
-- 删除方法性能对比
-- ========================================

-- ❌ 陷阱：不限制线程数
ALTER TABLE events
DELETE WHERE event_time < '2023-01-01';
-- 使用所有可用线程（可能 16+）

-- 影响：CPU 使用率 100%

-- ✅ 解决：限制线程数
ALTER TABLE events
DELETE WHERE event_time < '2023-01-01'
-- REMOVED SET max_threads (not supported) 4;

-- ========================================
-- 删除方法性能对比
-- ========================================

-- ❌ 陷阱：执行后不监控
ALTER TABLE events
DELETE WHERE event_time < '2023-01-01';
-- 不知道何时完成，无法评估影响

-- ✅ 解决：实时监控
-- （参考上面的监控查询）
