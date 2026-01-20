-- ================================================
-- 05_advanced_features.sql
-- ClickHouse 高级特性示例
-- ================================================

-- ========================================
-- 1. 物化视图 (Materialized View)
-- ========================================

-- 创建源表（生产环境：使用复制引擎 + ON CLUSTER）
CREATE TABLE IF NOT EXISTS test_source_events ON CLUSTER 'treasurycluster' (
    event_id UInt64,
    user_id UInt64,
    event_type String,
    event_value Float64,
    timestamp DateTime
) ENGINE = ReplicatedMergeTree
PARTITION BY toYYYYMM(timestamp)
ORDER BY (user_id, timestamp);

-- 插入一些测试数据
INSERT INTO test_source_events (event_id, user_id, event_type, event_value, timestamp) VALUES
(1, 1, 'click', 10.5, '2024-01-01 10:00:00'),
(2, 1, 'view', 5.0, '2024-01-01 10:05:00'),
(3, 2, 'click', 15.0, '2024-01-01 11:00:00'),
(4, 3, 'purchase', 99.99, '2024-01-01 12:00:00'),
(5, 1, 'click', 20.0, '2024-01-02 09:00:00'),
(6, 2, 'view', 8.5, '2024-01-02 10:00:00'),
(7, 4, 'click', 12.5, '2024-01-02 11:00:00'),
(8, 3, 'purchase', 149.99, '2024-01-03 14:00:00');

-- 创建物化视图：按用户统计事件（生产环境：使用复制聚合引擎 + ON CLUSTER）
CREATE MATERIALIZED VIEW IF NOT EXISTS test_user_event_stats_mv ON CLUSTER 'treasurycluster'
ENGINE = ReplicatedAggregatingMergeTree
ORDER BY (user_id, event_type, date)
AS SELECT
    user_id,
    event_type,
    toDate(timestamp) as date,
    sumState(event_value) as total_value_state,
    countState() as event_count_state
FROM test_source_events
GROUP BY user_id, event_type, date;

-- 查询物化视图数据
SELECT
    user_id,
    event_type,
    date,
    sumMerge(total_value_state) as total_value,
    countMerge(event_count_state) as event_count
FROM test_user_event_stats_mv
GROUP BY user_id, event_type, date
ORDER BY user_id, date, event_type;

-- 插入新数据，物化视图会自动更新
INSERT INTO test_source_events (event_id, user_id, event_type, event_value, timestamp) VALUES
(9, 5, 'click', 18.0, now()),
(10, 5, 'view', 7.5, now()),
(11, 5, 'purchase', 199.99, now());

-- 再次查询物化视图
SELECT
    user_id,
    countMerge(event_count_state) as event_count
FROM test_user_event_stats_mv
WHERE user_id = 5
GROUP BY user_id;

-- ========================================
-- 2. 聚合函数
-- ========================================

-- 创建测试表（生产环境：使用复制引擎 + ON CLUSTER）
CREATE TABLE IF NOT EXISTS test_aggregation_data ON CLUSTER 'treasurycluster' (
    id UInt64,
    group_id UInt32,
    value Float64,
    category String
) ENGINE = ReplicatedMergeTree
PARTITION BY group_id
ORDER BY (group_id, id);

-- 插入测试数据
INSERT INTO test_aggregation_data SELECT
    number as id,
    number % 10 as group_id,
    rand() * 100 as value,
    concat('cat_', toString(number % 5)) as category
FROM numbers(1000);

-- 基础聚合
SELECT
    group_id,
    count() as cnt,
    sum(value) as total,
    avg(value) as avg_val,
    min(value) as min_val,
    max(value) as max_val,
    stddevSamp(value) as stddev,
    varianceSamp(value) as variance
FROM test_aggregation_data
GROUP BY group_id
ORDER BY group_id;

-- 使用 State 函数进行增量聚合（生产环境：使用复制聚合引擎 + ON CLUSTER）
CREATE TABLE IF NOT EXISTS test_aggregated_states ON CLUSTER 'treasurycluster' (
    group_id UInt32,
    category String,
    sum_state AggregateFunction(sum, Float64),
    count_state AggregateFunction(count),
    date Date DEFAULT today()
) ENGINE = ReplicatedAggregatingMergeTree
ORDER BY (group_id, category, date);

-- 插入聚合状态
INSERT INTO test_aggregated_states
SELECT
    group_id,
    category,
    sumState(value),
    countState(),
    today()
FROM test_aggregation_data
GROUP BY group_id, category;

-- 合并聚合状态
SELECT
    group_id,
    category,
    sumMerge(sum_state) as total_value,
    countMerge(count_state) as record_count
FROM test_aggregated_states
GROUP BY group_id, category
ORDER BY group_id, category;

-- ========================================
-- 3. 投影 (Projection)
-- ========================================

-- 创建带投影的表（生产环境：使用复制引擎 + ON CLUSTER）
CREATE TABLE IF NOT EXISTS test_projection_table ON CLUSTER 'treasurycluster' (
    id UInt64,
    user_id UInt64,
    product_id UInt32,
    quantity UInt32,
    price Decimal(10, 2),
    timestamp DateTime
)
ENGINE = ReplicatedMergeTree
PARTITION BY toYYYYMM(timestamp)
ORDER BY (user_id, timestamp)
SETTINGS
    allow_experimental_projection_optimization = 1;

-- 创建投影：按用户和产品聚合
ALTER TABLE test_projection_table ADD PROJECTION projection_user_product
(
    SELECT
        user_id,
        product_id,
        sum(quantity) as total_quantity,
        sum(price * quantity) as total_revenue
    GROUP BY user_id, product_id
);

-- 插入测试数据
INSERT INTO test_projection_table (id, user_id, product_id, quantity, price, timestamp) VALUES
(1, 1, 101, 2, 99.99, now()),
(2, 1, 102, 1, 49.99, now()),
(3, 1, 101, 3, 99.99, now()),
(4, 2, 103, 1, 199.99, now()),
(5, 2, 101, 1, 99.99, now()),
(6, 3, 104, 2, 149.99, now());

-- 使用投影查询（会自动使用投影加速）
SELECT
    user_id,
    product_id,
    total_quantity,
    total_revenue
FROM test_projection_table
GROUP BY user_id, product_id
ORDER BY user_id, product_id;

-- ========================================
-- 4. TTL 设置
-- ========================================

-- 创建带 TTL 的表（生产环境：使用复制引擎 + ON CLUSTER）
CREATE TABLE IF NOT EXISTS test_ttl_table ON CLUSTER 'treasurycluster' (
    id UInt64,
    data String,
    created_at DateTime,
    updated_at DateTime DEFAULT now()
)
ENGINE = ReplicatedMergeTree
ORDER BY id
TTL
    created_at + INTERVAL 30 DAY DELETE,
    updated_at + INTERVAL 7 DAY TO DISK 'default';

-- 插入测试数据
INSERT INTO test_ttl_table (id, data, created_at) VALUES
(1, 'Old data 1', now() - INTERVAL 35 DAY),
(2, 'Old data 2', now() - INTERVAL 25 DAY),
(3, 'Recent data 1', now() - INTERVAL 5 DAY),
(4, 'Recent data 2', now());

-- 查看数据
SELECT
    id,
    data,
    created_at,
    dateDiff('day', created_at, now()) as days_old
FROM test_ttl_table
ORDER BY created_at;

-- 查看表 TTL 信息
SELECT
    table,
    ttl_expression,
    min_ttl_datetime,
    max_ttl_datetime,
    is_participating_in_ttl_move
FROM system.parts
WHERE table = 'test_ttl_table'
  AND active = 1;

-- ========================================
-- 5. 数据压缩
-- ========================================

-- 创建带压缩设置的表（生产环境：使用复制引擎 + ON CLUSTER）
CREATE TABLE IF NOT EXISTS test_compression_table ON CLUSTER 'treasurycluster' (
    id UInt64,
    text_data String,
    json_data String,
    created_at DateTime
)
ENGINE = ReplicatedMergeTree
ORDER BY id
SETTINGS
    compress_marks = 1,
    compress_primary_key = 1,
    min_bytes_for_wide_part = 0;

-- 设置压缩 codec
ALTER TABLE test_compression_table MODIFY SETTING
    compress_marks = 1,
    compress_primary_key = 1;

-- 插入测试数据
INSERT INTO test_compression_table SELECT
    number as id,
    repeat('test data string ', 10) as text_data,
    concat('{"key":', toString(number), ',"value":"', repeat('data', 5), '"}') as json_data,
    now() as created_at
FROM numbers(1000);

-- 查看压缩信息
SELECT
    table,
    name as part_name,
    rows,
    bytes_on_disk,
    marks_bytes,
    primary_key_bytes_in_memory,
    formatReadableSize(bytes_on_disk) as readable_size,
    formatReadableSize(marks_bytes) as marks_readable
FROM system.parts
WHERE table = 'test_compression_table'
  AND active = 1;

-- ========================================
-- 6. 虚拟列
-- ========================================

-- 创建测试表（生产环境：使用复制引擎 + ON CLUSTER）
CREATE TABLE IF NOT EXISTS test_virtual_columns ON CLUSTER 'treasurycluster' (
    id UInt64,
    data String
) ENGINE = ReplicatedMergeTree
ORDER BY id;

-- 插入测试数据
INSERT INTO test_virtual_columns VALUES
(1, 'test data 1'),
(2, 'test data 2'),
(3, 'test data 3');

-- 查询包含虚拟列
SELECT
    id,
    data,
    _part as part_name,
    _partition_id as partition,
    _part_offset as offset,
    _row_num as row_number
FROM test_virtual_columns
LIMIT 5;

-- ========================================
-- 7. SKIP 索引
-- ========================================

-- 创建带 SKIP 索引的表（生产环境：使用复制引擎 + ON CLUSTER）
CREATE TABLE IF NOT EXISTS test_skip_index_table ON CLUSTER 'treasurycluster' (
    id UInt64,
    user_id UInt64,
    timestamp DateTime,
    value Float64,
    status String
)
ENGINE = ReplicatedMergeTree
PARTITION BY toYYYYMM(timestamp)
ORDER BY (user_id, timestamp)
SETTINGS
    index_granularity = 8192;

-- 添加 minmax 索引
ALTER TABLE test_skip_index_table
ADD INDEX idx_status_minmax status TYPE minmax GRANULARITY 4;

-- 添加 set 索引
ALTER TABLE test_skip_index_table
ADD INDEX idx_status_set status TYPE set(10) GRANULARITY 4;

-- 添加 bloom_filter 索引
ALTER TABLE test_skip_index_table
ADD INDEX idx_user_bloom user_id TYPE bloom_filter(0.01) GRANULARITY 8;

-- 插入测试数据
INSERT INTO test_skip_index_table SELECT
    number as id,
    number % 100 as user_id,
    now() - INTERVAL rand() * 30 DAY as timestamp,
    rand() * 1000 as value,
    if(rand() > 0.5, 'active', 'inactive') as status
FROM numbers(10000);

-- 使用索引查询
SELECT
    count() as cnt,
    avg(value) as avg_val
FROM test_skip_index_table
WHERE status = 'active';

-- 查看索引信息
SELECT
    table,
    name as index_name,
    type,
    expr,
    granularity,
    data_files
FROM system.data_skipping_indices
WHERE table = 'test_skip_index_table';

-- ========================================
-- 8. 数据采样
-- ========================================

-- 创建支持采样的表（生产环境：使用复制引擎 + ON CLUSTER）
CREATE TABLE IF NOT EXISTS test_sampling_table ON CLUSTER 'treasurycluster' (
    id UInt64,
    user_id UInt64,
    event_type String,
    value Float64,
    timestamp DateTime
)
ENGINE = ReplicatedMergeTree
PARTITION BY toYYYYMM(timestamp)
ORDER BY (user_id, intHash32(user_id))
SETTINGS
    index_granularity = 8192,
    sampling_granularity = 8192;

-- 插入测试数据
INSERT INTO test_sampling_table SELECT
    number as id,
    number % 1000 as user_id,
    concat('event_', toString(number % 10)) as event_type,
    rand() * 1000 as value,
    now() - INTERVAL rand() * 30 DAY as timestamp
FROM numbers(100000);

-- 使用采样查询
-- 采样 1% 的数据
SELECT
    count() as estimated_count,
    count() * 100 as estimated_total,
    avg(value) as estimated_avg_value
FROM test_sampling_table
SAMPLE 0.01;

-- 对比实际总数
SELECT
    count() as actual_count,
    avg(value) as actual_avg_value
FROM test_sampling_table;

-- ========================================
-- 9. 外部字典（示例）
-- ========================================

-- 创建简单的文件字典（实际使用时需要创建字典文件）
-- 这里只展示字典配置结构

-- CREATE DICTIONARY test_dict (
--     id UInt64,
--     name String,
--     value Float64
-- )
-- PRIMARY KEY id
-- SOURCE(FILE(PATH '/etc/clickhouse-server/dictionaries/test_dict.json' FORMAT 'JSON'))
-- LAYOUT(HASHED())
-- LIFETIME(MIN 300 MAX 3600);

-- ========================================
-- 10. GROUP BY 优化
-- ========================================

-- 创建测试表（生产环境：使用复制引擎 + ON CLUSTER）
CREATE TABLE IF NOT EXISTS test_groupby_table ON CLUSTER 'treasurycluster' (
    id UInt64,
    group_id UInt32,
    sub_group_id UInt32,
    value Float64,
    category String
) ENGINE = ReplicatedMergeTree
PARTITION BY group_id
ORDER BY (group_id, sub_group_id, id);

-- 插入测试数据
INSERT INTO test_groupby_table SELECT
    number as id,
    number % 100 as group_id,
    number % 10 as sub_group_id,
    rand() * 1000 as value,
    concat('cat_', toString(number % 5)) as category
FROM numbers(100000);

-- 使用 GROUP BY WITH ROLLUP
SELECT
    group_id,
    sub_group_id,
    count() as cnt,
    sum(value) as total
FROM test_groupby_table
GROUP BY ROLLUP(group_id, sub_group_id)
ORDER BY group_id, sub_group_id;

-- 使用 GROUP BY WITH CUBE
SELECT
    category,
    count() as cnt,
    avg(value) as avg_val
FROM test_groupby_table
GROUP BY CUBE(category)
ORDER BY category;

-- 使用 GROUP BY WITH TOTALS
SELECT
    group_id,
    category,
    count() as cnt,
    sum(value) as total
FROM test_groupby_table
GROUP BY group_id, category
WITH TOTALS
ORDER BY group_id, category;

-- ========================================
-- 11. 窗口函数
-- ========================================

-- 创建测试表（生产环境：使用复制引擎 + ON CLUSTER）
CREATE TABLE IF NOT EXISTS test_window_table ON CLUSTER 'treasurycluster' (
    id UInt64,
    user_id UInt64,
    amount Float64,
    transaction_date DateTime
) ENGINE = ReplicatedMergeTree
PARTITION BY toYYYYMM(transaction_date)
ORDER BY (user_id, transaction_date);

-- 插入测试数据
INSERT INTO test_window_table SELECT
    number as id,
    number % 100 as user_id,
    rand() * 1000 as amount,
    now() - INTERVAL rand() * 30 DAY as transaction_date
FROM numbers(1000);

-- 使用窗口函数
SELECT
    user_id,
    id,
    amount,
    transaction_date,
    ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY transaction_date) as row_num,
    RANK() OVER (PARTITION BY user_id ORDER BY amount DESC) as amount_rank,
    SUM(amount) OVER (PARTITION BY user_id ORDER BY transaction_date) as running_total,
    AVG(amount) OVER (PARTITION BY user_id) as user_avg,
    LAG(amount) OVER (PARTITION BY user_id ORDER BY transaction_date) as prev_amount,
    LEAD(amount) OVER (PARTITION BY user_id ORDER BY transaction_date) as next_amount,
    FIRST_VALUE(amount) OVER (PARTITION BY user_id ORDER BY transaction_date) as first_amount,
    LAST_VALUE(amount) OVER (PARTITION BY user_id ORDER BY transaction_date) as last_amount
FROM test_window_table
WHERE user_id IN (1, 2, 3)
ORDER BY user_id, transaction_date;

-- ========================================
-- 12. 清理测试表（生产环境：使用 ON CLUSTER SYNC 确保集群范围删除）
-- ========================================
DROP TABLE IF EXISTS test_source_events ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS test_user_event_stats_mv ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS test_aggregation_data ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS test_aggregated_states ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS test_projection_table ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS test_ttl_table ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS test_compression_table ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS test_virtual_columns ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS test_skip_index_table ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS test_sampling_table ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS test_groupby_table ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS test_window_table ON CLUSTER 'treasurycluster' SYNC;

-- ========================================
-- 13. 验证清理
-- ========================================
SELECT name FROM system.tables WHERE name LIKE 'test_%';
