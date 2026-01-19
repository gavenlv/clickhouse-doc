-- ================================================
-- 01_performance_optimization.sql
-- ClickHouse 性能优化示例
-- ================================================

-- ========================================
-- 1. 查询性能分析
-- ========================================

-- 启用查询日志
SET log_queries = 1;
SET log_queries_min_type = 'QueryFinish';
SET log_queries_min_query_duration_ms = 0;

-- 执行测试查询并查看执行计划
-- 使用 EXPLAIN 查看查询执行计划
EXPLAIN SELECT count() FROM system.parts WHERE active = 1;

-- 使用 EXPLAIN PIPELINE 查看查询管道
EXPLAIN PIPELINE SELECT count() FROM system.parts WHERE active = 1;

-- 查看查询统计信息
SELECT
    query_id,
    type,
    query_start_time,
    query_duration_ms,
    read_rows,
    read_bytes,
    written_rows,
    written_bytes,
    memory_usage,
    peak_memory_usage,
    thread_ids
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query NOT LIKE 'SELECT%'
  AND event_date >= today()
ORDER BY query_start_time DESC
LIMIT 10;

-- 分析慢查询（超过 1 秒）
SELECT
    query_id,
    user,
    query,
    query_duration_ms,
    read_rows,
    read_bytes,
    memory_usage,
    formatReadableSize(read_bytes) as readable_read_bytes
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query_duration_ms > 1000
  AND event_date >= today()
ORDER BY query_duration_ms DESC
LIMIT 10;

-- ========================================
-- 2. 索引和排序键优化
-- ========================================

-- 创建优化后的表：选择正确的排序键
CREATE TABLE IF NOT EXISTS test_optimized_events (
    event_id UInt64,
    user_id UInt64,
    event_type String,
    timestamp DateTime,
    event_value Float64
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(timestamp)
ORDER BY (user_id, event_type, timestamp)
SETTINGS
    index_granularity = 8192;

-- 插入测试数据
INSERT INTO test_optimized_events SELECT
    number as event_id,
    number % 1000 as user_id,
    concat('type_', toString(number % 10)) as event_type,
    now() - INTERVAL rand() * 30 DAY as timestamp,
    rand() * 1000 as event_value
FROM numbers(100000);

-- 查询性能对比：使用排序键
SELECT
    user_id,
    count() as event_count,
    avg(event_value) as avg_value
FROM test_optimized_events
WHERE user_id = 100
  AND timestamp >= now() - INTERVAL 7 DAY
GROUP BY user_id;

-- 查看分区扫描情况
SELECT
    partition,
    sum(rows) as total_rows,
    count() as part_count
FROM system.parts
WHERE table = 'test_optimized_events'
  AND active = 1
GROUP BY partition
ORDER BY partition;

-- 使用分区剪枝优化查询
-- 这个查询只会扫描最近的分区
SELECT
    toDate(timestamp) as event_day,
    count() as event_count
FROM test_optimized_events
WHERE timestamp >= now() - INTERVAL 7 DAY
GROUP BY event_day
ORDER BY event_day;

-- ========================================
-- 3. SKIP 索引优化
-- ========================================

-- 创建带多种 SKIP 索引的表
CREATE TABLE IF NOT EXISTS test_skip_optimized (
    id UInt64,
    user_id UInt64,
    timestamp DateTime,
    status String,
    category String,
    value Float64
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(timestamp)
ORDER BY (user_id, timestamp)
SETTINGS
    index_granularity = 8192;

-- 添加 minmax 索引（用于范围查询）
ALTER TABLE test_skip_optimized
ADD INDEX idx_timestamp_minmax timestamp TYPE minmax GRANULARITY 4;

-- 添加 set 索引（用于等值查询）
ALTER TABLE test_skip_optimized
ADD INDEX idx_status_set status TYPE set(10) GRANULARITY 4;

-- 添加 bloom_filter 索引（用于快速查找）
ALTER TABLE test_skip_optimized
ADD INDEX idx_user_bloom user_id TYPE bloom_filter(0.01) GRANULARITY 8;

-- 添加 tokenbf_v1 索引（用于字符串搜索）
ALTER TABLE test_skip_optimized
ADD INDEX idx_category_bf category TYPE tokenbf_v1(512, 3, 0) GRANULARITY 4;

-- 插入测试数据
INSERT INTO test_skip_optimized SELECT
    number as id,
    number % 1000 as user_id,
    now() - INTERVAL rand() * 30 DAY as timestamp,
    if(rand() > 0.5, 'active', 'inactive') as status,
    concat('cat_', toString(number % 5)) as category,
    rand() * 1000 as value
FROM numbers(100000);

-- 查询索引使用情况
SELECT
    table,
    name as index_name,
    type,
    expr,
    granularity,
    parts,
    marks,
    bytes,
    formatReadableSize(bytes) as readable_size
FROM system.data_skipping_indices
WHERE table = 'test_skip_optimized'
ORDER BY index_name;

-- 测试索引效果
-- 这个查询会使用 idx_status_set 索引
SELECT
    status,
    count() as cnt,
    avg(value) as avg_val
FROM test_skip_optimized
WHERE status = 'active'
GROUP BY status;

-- 这个查询会使用 idx_user_bloom 索引
SELECT
    user_id,
    count() as cnt
FROM test_skip_optimized
WHERE user_id IN (100, 200, 300, 400, 500)
GROUP BY user_id;

-- ========================================
-- 4. 投影 (Projection) 优化
-- ========================================

-- 创建带投影的表
CREATE TABLE IF NOT EXISTS test_projection_optimized (
    order_id UInt64,
    user_id UInt64,
    product_id UInt32,
    quantity UInt32,
    price Decimal(10, 2),
    order_date DateTime
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(order_date)
ORDER BY (user_id, order_date)
SETTINGS
    allow_experimental_projection_optimization = 1;

-- 创建投影：按用户聚合
ALTER TABLE test_projection_optimized ADD PROJECTION projection_user_stats
(
    SELECT
        user_id,
        toDate(order_date) as order_day,
        count() as order_count,
        sum(quantity) as total_quantity,
        sum(price * quantity) as total_revenue
    GROUP BY user_id, order_day
);

-- 创建投影：按产品聚合
ALTER TABLE test_projection_optimized ADD PROJECTION projection_product_stats
(
    SELECT
        product_id,
        count() as order_count,
        sum(quantity) as total_quantity,
        avg(price) as avg_price
    GROUP BY product_id
);

-- 插入测试数据
INSERT INTO test_projection_optimized SELECT
    number as order_id,
    number % 100 as user_id,
    number % 20 as product_id,
    (number % 10) + 1 as quantity,
    rand() * 1000 as price,
    now() - INTERVAL rand() * 30 DAY as order_date
FROM numbers(50000);

-- 查询投影信息
SELECT
    table,
    name as projection_name,
    formatReadableSize(bytes_on_disk) as size,
    rows
FROM system.projections
WHERE table = 'test_projection_optimized';

-- 使用投影加速查询
SELECT
    user_id,
    order_day,
    order_count,
    total_quantity,
    total_revenue
FROM test_projection_optimized
GROUP BY user_id, order_day
ORDER BY user_id, order_day
LIMIT 100;

-- ========================================
-- 5. 并发控制
-- ========================================

-- 设置并发查询限制
SET max_concurrent_queries = 10;
SET max_concurrent_queries_for_user = 5;

-- 查看当前运行的查询
SELECT
    query_id,
    user,
    query,
    query_start_time,
    elapsed,
    read_rows,
    read_bytes,
    memory_usage
FROM system.processes
ORDER BY query_start_time DESC;

-- 查看等待执行的查询
SELECT
    query_id,
    user,
    query,
    query_start_time
FROM system.waits
ORDER BY query_start_time;

-- ========================================
-- 6. 资源管理
-- ========================================

-- 设置内存限制
SET max_memory_usage = 10000000000; -- 10GB
SET max_memory_usage_for_user = 5000000000; -- 5GB per user

-- 查看当前内存使用情况
SELECT
    name,
    value,
    formatReadableSize(value) as readable_value
FROM system.asynchronous_metrics
WHERE name LIKE '%memory%'
ORDER BY name;

-- 查看表内存使用
SELECT
    database,
    table,
    sum(bytes_on_disk) as total_bytes,
    formatReadableSize(sum(bytes_on_disk)) as readable_size,
    sum(rows) as total_rows
FROM system.parts
WHERE active = 1
GROUP BY database, table
ORDER BY total_bytes DESC
LIMIT 10;

-- ========================================
-- 7. 查询优化技巧
-- ========================================

-- 使用 PREWHERE 优化
-- PREWHERE 在 WHERE 之前执行，减少数据扫描量
SELECT
    count()
FROM test_optimized_events
WHERE user_id = 100
  AND event_value > 500;

-- 使用 LIMIT 限制结果集
SELECT
    user_id,
    event_type,
    count() as event_count
FROM test_optimized_events
WHERE event_type = 'type_1'
GROUP BY user_id, event_type
ORDER BY event_count DESC
LIMIT 10;

-- 使用子查询优化
SELECT
    u.user_id,
    u.event_count,
    v.total_value
FROM (
    SELECT
        user_id,
        count() as event_count
    FROM test_optimized_events
    WHERE event_type = 'type_1'
    GROUP BY user_id
) u
INNER JOIN (
    SELECT
        user_id,
        sum(event_value) as total_value
    FROM test_optimized_events
    WHERE event_type = 'type_2'
    GROUP BY user_id
) v ON u.user_id = v.user_id;

-- ========================================
-- 8. 数据采样优化
-- ========================================

-- 创建支持采样的表
CREATE TABLE IF NOT EXISTS test_sampling_optimized (
    id UInt64,
    user_id UInt64,
    event_type String,
    event_value Float64,
    timestamp DateTime
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(timestamp)
ORDER BY (user_id, intHash32(user_id))
SETTINGS
    index_granularity = 8192,
    sampling_granularity = 8192;

-- 插入测试数据
INSERT INTO test_sampling_optimized SELECT
    number as id,
    number % 1000 as user_id,
    concat('type_', toString(number % 10)) as event_type,
    rand() * 1000 as event_value,
    now() - INTERVAL rand() * 30 DAY as timestamp
FROM numbers(100000);

-- 使用采样快速估计
-- 采样 0.1% 的数据
SELECT
    count() as estimated_count,
    count() * 1000 as estimated_total,
    avg(event_value) as estimated_avg
FROM test_sampling_optimized
SAMPLE 0.001;

-- 对比实际值
SELECT
    count() as actual_count,
    avg(event_value) as actual_avg
FROM test_sampling_optimized;

-- ========================================
-- 9. 物化视图优化
-- ========================================

-- 创建源表
CREATE TABLE IF NOT EXISTS test_source_raw (
    event_id UInt64,
    user_id UInt64,
    event_data String,
    timestamp DateTime
) ENGINE = MergeTree()
ORDER BY (user_id, timestamp);

-- 创建预聚合物化视图
CREATE MATERIALIZED VIEW IF NOT EXISTS test_preagg_mv
ENGINE = AggregatingMergeTree()
ORDER BY (user_id, toDate(timestamp))
AS SELECT
    user_id,
    toDate(timestamp) as event_date,
    sumState(length(event_data)) as total_data_size_state,
    countState() as event_count_state
FROM test_source_raw
GROUP BY user_id, toDate(timestamp);

-- 插入数据
INSERT INTO test_source_raw (event_id, user_id, event_data, timestamp) VALUES
(1, 1, repeat('data', 100), now()),
(2, 1, repeat('data', 50), now()),
(3, 2, repeat('data', 75), now());

-- 从物化视图查询预聚合数据（快速）
SELECT
    user_id,
    event_date,
    sumMerge(total_data_size_state) as total_data_size,
    countMerge(event_count_state) as event_count
FROM test_preagg_mv
GROUP BY user_id, event_date;

-- ========================================
-- 10. 表维护优化
-- ========================================

-- 执行 OPTIMIZE 合并数据分片
OPTIMIZE TABLE test_optimized_events FINAL;

-- 查看 OPTIMIZE 执行情况
SELECT
    table,
    partition,
    name,
    rows,
    bytes_on_disk,
    modification_time
FROM system.parts
WHERE table = 'test_optimized_events'
  AND active = 1
ORDER BY partition, name;

-- 删除旧分区
-- ALTER TABLE test_optimized_events DROP PARTITION '202312';

-- 查看未合并的数据
SELECT
    table,
    partition,
    count() as unmerged_parts,
    sum(rows) as total_rows,
    sum(bytes_on_disk) as total_bytes
FROM system.parts
WHERE table = 'test_optimized_events'
  AND active = 1
  AND level = 0
GROUP BY table, partition;

-- ========================================
-- 11. 性能基准测试
-- ========================================

-- 创建基准测试表
CREATE TABLE IF NOT EXISTS test_benchmark (
    id UInt64,
    group_id UInt32,
    value1 Float64,
    value2 Float64,
    timestamp DateTime
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(timestamp)
ORDER BY (group_id, timestamp);

-- 插入大量测试数据
INSERT INTO test_benchmark SELECT
    number as id,
    number % 100 as group_id,
    rand() * 1000 as value1,
    rand() * 2000 as value2,
    now() - INTERVAL rand() * 30 DAY as timestamp
FROM numbers(1000000);

-- 执行基准查询并记录时间
SELECT
    group_id,
    count() as cnt,
    sum(value1) as total1,
    avg(value2) as avg2
FROM test_benchmark
WHERE timestamp >= now() - INTERVAL 7 DAY
GROUP BY group_id;

-- ========================================
-- 12. 清理测试表
-- ========================================
DROP TABLE IF EXISTS test_optimized_events;
DROP TABLE IF EXISTS test_skip_optimized;
DROP TABLE IF EXISTS test_projection_optimized;
DROP TABLE IF EXISTS test_sampling_optimized;
DROP TABLE IF EXISTS test_source_raw;
DROP TABLE IF EXISTS test_preagg_mv;
DROP TABLE IF EXISTS test_benchmark;

-- ========================================
-- 13. 性能优化总结
-- ========================================
/*
性能优化最佳实践：

1. 合理设计表结构
   - 选择合适的分区键
   - 优化 ORDER BY 排序键
   - 使用正确的数据类型

2. 使用索引和投影
   - 添加 SKIP 索引加速查询
   - 使用投影预聚合常用查询
   - 选择合适的索引粒度

3. 优化查询语句
   - 使用 PREWHERE 减少数据扫描
   - 合理使用 LIMIT
   - 避免全表扫描

4. 并发和资源管理
   - 设置合理的并发限制
   - 控制内存使用
   - 监控资源使用情况

5. 定期维护
   - 执行 OPTIMIZE TABLE 合并数据
   - 删除旧分区释放空间
   - 监控表性能指标

6. 使用物化视图
   - 预聚合常用查询
   - 减少实时计算压力
   - 提高查询响应速度
*/
