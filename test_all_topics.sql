-- ================================================
-- test_all_topics.sql
-- 综合测试文件：08-information-schema, 09-data-deletion, 10-date-update
-- 所有表使用 Replicated 引擎
-- ================================================

-- ========================================
-- 08-information-schema 测试
-- ========================================

-- ========================================
-- 1. 测试数据库和表信息查询
-- ========================================
-- 创建测试数据库
CREATE DATABASE IF NOT EXISTS test_info_schema ON CLUSTER 'treasurycluster';

-- 创建测试表
CREATE TABLE IF NOT EXISTS test_info_schema.test_events ON CLUSTER 'treasurycluster' (
    event_id UInt64,
    user_id UInt64,
    event_type String,
    event_time DateTime,
    event_data String
) ENGINE = ReplicatedMergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (user_id, event_time);

CREATE TABLE IF NOT EXISTS test_info_schema.test_users ON CLUSTER 'treasurycluster' (
    user_id UInt64,
    username String,
    email String,
    created_at DateTime,
    last_login DateTime
) ENGINE = ReplicatedMergeTree()
PARTITION BY toYYYYMM(created_at)
ORDER BY user_id;

CREATE TABLE IF NOT EXISTS test_info_schema.test_metrics ON CLUSTER 'treasurycluster' (
    metric_id UInt64,
    metric_name String,
    metric_value Float64,
    timestamp DateTime64(3)
) ENGINE = ReplicatedMergeTree()
PARTITION BY toYYYYMM(timestamp)
ORDER BY (metric_name, timestamp);

-- 插入测试数据
INSERT INTO test_info_schema.test_events (event_id, user_id, event_type, event_time, event_data) VALUES
(1, 1, 'login', '2024-01-15 08:00:00', '{"ip":"192.168.1.1"}'),
(2, 1, 'view_page', '2024-01-15 08:05:00', '{"page":"/home"}'),
(3, 2, 'login', '2024-01-15 09:00:00', '{"ip":"192.168.1.2"}'),
(4, 2, 'purchase', '2024-01-15 09:30:00', '{"amount":99.99}'),
(5, 3, 'login', '2024-01-16 10:00:00', '{"ip":"192.168.1.3"}'),
(6, 3, 'search', '2024-01-16 10:15:00', '{"query":"laptop"}'),
(7, 4, 'login', '2024-02-01 11:00:00', '{"ip":"192.168.1.4"}'),
(8, 4, 'view_page', '2024-02-01 11:05:00', '{"page":"/products"}'),
(9, 5, 'login', '2024-02-15 12:00:00', '{"ip":"192.168.1.5"}'),
(10, 5, 'purchase', '2024-02-15 12:30:00', '{"amount":199.99}');

INSERT INTO test_info_schema.test_users (user_id, username, email, created_at, last_login) VALUES
(1, 'user1', 'user1@example.com', '2024-01-01 00:00:00', '2024-01-15 08:00:00'),
(2, 'user2', 'user2@example.com', '2024-01-01 00:00:00', '2024-01-15 09:00:00'),
(3, 'user3', 'user3@example.com', '2024-01-01 00:00:00', '2024-01-16 10:00:00'),
(4, 'user4', 'user4@example.com', '2024-01-20 00:00:00', '2024-02-01 11:00:00'),
(5, 'user5', 'user5@example.com', '2024-02-01 00:00:00', '2024-02-15 12:00:00');

INSERT INTO test_info_schema.test_metrics (metric_id, metric_name, metric_value, timestamp) VALUES
(1, 'cpu_usage', 45.5, '2024-01-15 08:00:00.123'),
(2, 'memory_usage', 60.2, '2024-01-15 08:00:00.456'),
(3, 'disk_usage', 70.1, '2024-01-15 08:00:00.789'),
(4, 'network_in', 1024.5, '2024-01-15 09:00:00.123'),
(5, 'network_out', 512.3, '2024-01-15 09:00:00.456');

-- 测试查询：数据库信息
SELECT * FROM system.databases WHERE name = 'test_info_schema';

-- 测试查询：表信息
SELECT 
    database,
    name,
    engine,
    partition_key,
    sorting_key,
    total_rows,
    total_bytes,
    formatReadableSize(total_bytes) as readable_size
FROM system.tables
WHERE database = 'test_info_schema';

-- 测试查询：列信息
SELECT 
    database,
    table,
    name,
    type,
    position,
    default_kind,
    default_expression
FROM system.columns
WHERE database = 'test_info_schema'
ORDER BY table, position;

-- ========================================
-- 2. 测试分区信息查询
-- ========================================

-- 测试查询：分区信息
SELECT 
    database,
    table,
    partition,
    sum(rows) as total_rows,
    sum(bytes_on_disk) as total_bytes,
    formatReadableSize(sum(bytes_on_disk)) as readable_size
FROM system.parts
WHERE database = 'test_info_schema' 
  AND active = 1
GROUP BY database, table, partition
ORDER BY table, partition;

-- ========================================
-- 3. 测试集群和副本信息
-- ========================================

-- 测试查询：集群信息
SELECT * FROM system.clusters WHERE cluster = 'treasurycluster';

-- 测试查询：副本信息
SELECT 
    database,
    table,
    is_leader,
    can_become_leader,
    is_readonly,
    is_session_expired,
    queue_size,
    absolute_delay
FROM system.replicas
WHERE database = 'test_info_schema';

-- ========================================
-- 4. 测试查询和进程
-- ========================================

-- 测试查询：运行中的进程
SELECT 
    query_id,
    user,
    query,
    elapsed,
    rows_read,
    bytes_read
FROM system.processes
ORDER BY elapsed DESC
LIMIT 10;

-- ========================================
-- 09-data-deletion 测试
-- ========================================

-- ========================================
-- 1. 创建测试表
-- ========================================
CREATE DATABASE IF NOT EXISTS test_data_deletion ON CLUSTER 'treasurycluster';

-- 测试分区删除
CREATE TABLE IF NOT EXISTS test_data_deletion.test_logs ON CLUSTER 'treasurycluster' (
    event_id UInt64,
    event_type String,
    event_time DateTime,
    event_data String,
    created_at DateTime DEFAULT now()
) ENGINE = ReplicatedMergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_time, event_id);

-- 测试 TTL 删除
CREATE TABLE IF NOT EXISTS test_data_deletion.test_events_ttl ON CLUSTER 'treasurycluster' (
    event_id UInt64,
    event_type String,
    event_time DateTime,
    event_data String
) ENGINE = ReplicatedMergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_time, event_id)
TTL event_time + INTERVAL 90 DAY;

-- 测试 Mutation 删除
CREATE TABLE IF NOT EXISTS test_data_deletion.test_user_events ON CLUSTER 'treasurycluster' (
    event_id UInt64,
    user_id UInt64,
    event_type String,
    event_time DateTime,
    event_data String
) ENGINE = ReplicatedMergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (user_id, event_time);

-- 测试轻量级删除
CREATE TABLE IF NOT EXISTS test_data_deletion.test_transactions ON CLUSTER 'treasurycluster' (
    transaction_id UInt64,
    user_id UInt64,
    amount Float64,
    transaction_time DateTime,
    status String
) ENGINE = ReplicatedMergeTree()
PARTITION BY toYYYYMM(transaction_time)
ORDER BY (transaction_id);

-- ========================================
-- 2. 插入测试数据（用于各种删除测试）
-- ========================================

-- 为日志表插入多个月的数据
INSERT INTO test_data_deletion.test_logs (event_id, event_type, event_time, event_data) VALUES
(1, 'info', '2023-11-01 08:00:00', '{"message":"Application started"}'),
(2, 'info', '2023-11-02 08:00:00', '{"message":"User logged in"}'),
(3, 'warning', '2023-11-03 08:00:00', '{"message":"High memory usage"}'),
(4, 'info', '2023-12-01 08:00:00', '{"message":"Daily backup completed"}'),
(5, 'error', '2023-12-02 08:00:00', '{"message":"Database connection failed"}'),
(6, 'info', '2023-12-03 08:00:00', '{"message":"Connection restored"}'),
(7, 'info', '2024-01-01 08:00:00', '{"message":"New year celebration"}'),
(8, 'info', '2024-01-15 08:00:00', '{"message":"Performance improved"}'),
(9, 'info', '2024-02-01 08:00:00', '{"message":"Monthly report generated"}'),
(10, 'info', '2024-02-20 08:00:00', '{"message":"System health check passed"}');

-- 为 TTL 表插入数据（部分应该会被删除）
INSERT INTO test_data_deletion.test_events_ttl (event_id, event_type, event_time, event_data) VALUES
(1, 'click', '2023-10-01 08:00:00', '{"page":"/home"}'),
(2, 'click', '2023-11-01 08:00:00', '{"page":"/about"}'),
(3, 'click', '2023-12-01 08:00:00', '{"page":"/products"}'),
(4, 'click', '2024-01-01 08:00:00', '{"page":"/contact"}'),
(5, 'click', '2024-02-01 08:00:00', '{"page":"/blog"}'),
(6, 'click', now() - INTERVAL 30 DAY, '{"page":"/news"}'),
(7, 'click', now() - INTERVAL 60 DAY, '{"page":"/features"}');

-- 为用户事件表插入数据（用于 Mutation 删除）
INSERT INTO test_data_deletion.test_user_events (event_id, user_id, event_type, event_time, event_data) VALUES
(1, 1, 'login', '2024-01-15 08:00:00', '{"ip":"192.168.1.1"}'),
(2, 1, 'view_page', '2024-01-15 08:05:00', '{"page":"/home"}'),
(3, 1, 'purchase', '2024-01-15 09:00:00', '{"amount":99.99}'),
(4, 2, 'login', '2024-01-16 10:00:00', '{"ip":"192.168.1.2"}'),
(5, 2, 'view_page', '2024-01-16 10:05:00', '{"page":"/products"}'),
(6, 3, 'login', '2024-01-17 11:00:00', '{"ip":"192.168.1.3"}'),
(7, 3, 'search', '2024-01-17 11:15:00', '{"query":"laptop"}'),
(8, 4, 'login', '2024-02-01 12:00:00', '{"ip":"192.168.1.4"}'),
(9, 5, 'login', '2024-02-15 13:00:00', '{"ip":"192.168.1.5"}'),
(10, 1, 'logout', '2024-02-20 14:00:00', '{"duration":3600}');

-- 为交易表插入数据（用于轻量级删除）
INSERT INTO test_data_deletion.test_transactions (transaction_id, user_id, amount, transaction_time, status) VALUES
(1, 1, 100.00, '2024-01-15 08:00:00', 'completed'),
(2, 1, 200.00, '2024-01-15 09:00:00', 'completed'),
(3, 2, 50.00, '2024-01-16 10:00:00', 'pending'),
(4, 3, 150.00, '2024-01-17 11:00:00', 'completed'),
(5, 4, 75.00, '2024-02-01 12:00:00', 'failed'),
(6, 5, 300.00, '2024-02-15 13:00:00', 'completed'),
(7, 1, 25.00, '2024-02-20 14:00:00', 'pending'),
(8, 2, 175.00, '2024-02-20 15:00:00', 'completed'),
(9, 3, 125.00, '2024-02-20 16:00:00', 'pending'),
(10, 4, 50.00, '2024-02-20 17:00:00', 'failed');

-- ========================================
-- 3. 测试分区删除
-- ========================================

-- 查看当前分区
SELECT 
    table,
    partition,
    sum(rows) as rows,
    formatReadableSize(sum(bytes_on_disk)) as size
FROM system.parts
WHERE database = 'test_data_deletion' 
  AND table = 'test_logs'
  AND active = 1
GROUP BY table, partition
ORDER BY partition;

-- 删除旧分区（2023-11）
ALTER TABLE test_data_deletion.test_logs ON CLUSTER 'treasurycluster' 
DROP PARTITION '202311';

-- 验证删除结果
SELECT 
    partition,
    sum(rows) as rows,
    formatReadableSize(sum(bytes_on_disk)) as size
FROM system.parts
WHERE database = 'test_data_deletion' 
  AND table = 'test_logs'
  AND active = 1
GROUP BY partition
ORDER BY partition;

-- ========================================
-- 4. 测试 TTL 删除
-- ========================================

-- 查看 TTL 配置
SELECT 
    database,
    table,
    expression,
    result_column,
    result_type,
    is_compressed
FROM system.ttl_tables
WHERE database = 'test_data_deletion' 
  AND table = 'test_events_ttl';

-- 手动触发 TTL 合并（可选）
OPTIMIZE TABLE test_data_deletion.test_events_ttl ON CLUSTER 'treasurycluster' 
FINAL;

-- 查看剩余数据
SELECT 
    event_id,
    event_type,
    event_time,
    (now() - event_time) as data_age_days
FROM test_data_deletion.test_events_ttl
ORDER BY event_time;

-- ========================================
-- 5. 测试 Mutation 删除
-- ========================================

-- 查询当前数据量
SELECT count() as total FROM test_data_deletion.test_user_events;

-- 使用 Mutation 删除特定用户的事件
ALTER TABLE test_data_deletion.test_user_events ON CLUSTER 'treasurycluster'
DELETE WHERE user_id = 1;

-- 监控 Mutation 进度
SELECT 
    database,
    table,
    mutation_id,
    command,
    is_done,
    parts_to_do,
    parts_to_do_names,
    progress
FROM system.mutations
WHERE database = 'test_data_deletion' 
  AND table = 'test_user_events'
ORDER BY mutation_id DESC
LIMIT 5;

-- 等待完成后查询剩余数据
SELECT count() as total, uniqExact(user_id) as unique_users 
FROM test_data_deletion.test_user_events;

-- ========================================
-- 6. 测试轻量级删除
-- ========================================

-- 查询当前失败的交易
SELECT count() as failed_transactions
FROM test_data_deletion.test_transactions
WHERE status = 'failed';

-- 使用轻量级删除删除失败的交易
ALTER TABLE test_data_deletion.test_transactions ON CLUSTER 'treasurycluster'
DELETE WHERE status = 'failed'
SETTINGS lightweight_delete = 1;

-- 查询删除后的数据
SELECT 
    status,
    count() as count,
    sum(amount) as total_amount
FROM test_data_deletion.test_transactions
GROUP BY status;

-- ========================================
-- 10-date-update 测试
-- ========================================

-- ========================================
-- 1. 创建测试表
-- ========================================
CREATE DATABASE IF NOT EXISTS test_date_time ON CLUSTER 'treasurycluster';

-- 测试各种日期时间类型
CREATE TABLE IF NOT EXISTS test_date_time.test_types ON CLUSTER 'treasurycluster' (
    id UInt64,
    date_col Date,
    date32_col Date32,
    datetime_col DateTime,
    datetime64_col DateTime64(3),
    timestamp_col UInt64
) ENGINE = ReplicatedMergeTree()
PARTITION BY toYYYYMM(datetime_col)
ORDER BY id;

-- 测试时区
CREATE TABLE IF NOT EXISTS test_date_time.test_timezones ON CLUSTER 'treasurycluster' (
    id UInt64,
    event_name String,
    event_time_utc DateTime,
    event_time_local DateTime('Asia/Shanghai'),
    event_time_ny DateTime('America/New_York')
) ENGINE = ReplicatedMergeTree()
PARTITION BY toYYYYMM(event_time_utc)
ORDER BY id;

-- 测试时间序列
CREATE TABLE IF NOT EXISTS test_date_time.test_timeseries ON CLUSTER 'treasurycluster' (
    metric_id UInt64,
    metric_name String,
    metric_value Float64,
    timestamp DateTime,
    hour_key String,
    day_key String,
    month_key String
) ENGINE = ReplicatedMergeTree()
PARTITION BY toYYYYMM(timestamp)
ORDER BY (metric_name, timestamp);

-- ========================================
-- 2. 插入测试数据
-- ========================================

-- 测试日期时间类型
INSERT INTO test_date_time.test_types (id, date_col, date32_col, datetime_col, datetime64_col, timestamp_col) VALUES
(1, '2024-01-15', '2024-01-15', '2024-01-15 08:30:45', '2024-01-15 08:30:45.123', 1705329045),
(2, '2024-01-16', '2024-01-16', '2024-01-16 09:15:30', '2024-01-16 09:15:30.456', 1705419330),
(3, '2024-01-17', '2024-01-17', '2024-01-17 10:00:15', '2024-01-17 10:00:15.789', 1705509615),
(4, '2024-02-01', '2024-02-01', '2024-02-01 11:30:00', '2024-02-01 11:30:00.000', 1706788200),
(5, '2024-02-15', '2024-02-15', '2024-02-15 12:45:30', '2024-02-15 12:45:30.111', 1707998730);

-- 测试时区
INSERT INTO test_date_time.test_timezones (id, event_name, event_time_utc, event_time_local, event_time_ny) VALUES
(1, 'Meeting A', '2024-01-15 00:00:00', '2024-01-15 08:00:00', '2024-01-14 19:00:00'),
(2, 'Meeting B', '2024-01-15 12:00:00', '2024-01-15 20:00:00', '2024-01-15 07:00:00'),
(3, 'Meeting C', '2024-02-01 00:00:00', '2024-02-01 08:00:00', '2024-01-31 19:00:00'),
(4, 'Meeting D', '2024-02-15 00:00:00', '2024-02-15 08:00:00', '2024-02-14 19:00:00');

-- 测试时间序列
INSERT INTO test_date_time.test_timeseries (metric_id, metric_name, metric_value, timestamp, hour_key, day_key, month_key) VALUES
(1, 'cpu_usage', 45.5, '2024-01-15 08:00:00', '2024-01-15 08', '2024-01-15', '2024-01'),
(2, 'cpu_usage', 50.2, '2024-01-15 09:00:00', '2024-01-15 09', '2024-01-15', '2024-01'),
(3, 'memory_usage', 60.1, '2024-01-15 08:00:00', '2024-01-15 08', '2024-01-15', '2024-01'),
(4, 'memory_usage', 65.3, '2024-01-15 09:00:00', '2024-01-15 09', '2024-01-15', '2024-01'),
(5, 'disk_usage', 70.0, '2024-01-15 10:00:00', '2024-01-15 10', '2024-01-15', '2024-01'),
(6, 'cpu_usage', 48.5, '2024-01-16 08:00:00', '2024-01-16 08', '2024-01-16', '2024-01'),
(7, 'memory_usage', 62.0, '2024-01-16 09:00:00', '2024-01-16 09', '2024-01-16', '2024-01'),
(8, 'disk_usage', 72.5, '2024-02-01 10:00:00', '2024-02-01 10', '2024-02-01', '2024-02'),
(9, 'cpu_usage', 52.1, '2024-02-15 11:00:00', '2024-02-15 11', '2024-02-15', '2024-02'),
(10, 'memory_usage', 68.3, '2024-02-15 12:00:00', '2024-02-15 12', '2024-02-15', '2024-02');

-- ========================================
-- 3. 测试日期时间函数
-- ========================================

-- 当前时间
SELECT 
    now() AS current_datetime,
    today() AS current_date,
    yesterday() AS yesterday_date,
    toUnixTimestamp(now()) AS current_timestamp;

-- 时间转换
SELECT 
    date_col,
    toTypeName(date_col) AS date_type,
    datetime_col,
    toTypeName(datetime_col) AS datetime_type,
    datetime64_col,
    toTypeName(datetime64_col) AS datetime64_type
FROM test_date_time.test_types
LIMIT 5;

-- 日期格式化
SELECT 
    datetime_col,
    formatDateTime(datetime_col, '%Y-%m-%d %H:%M:%S') AS standard_format,
    formatDateTime(datetime_col, '%Y年%m月%d日 %H时%M分%S秒') AS chinese_format,
    formatDateTime(datetime_col, '%A, %B %d, %Y') AS full_format
FROM test_date_time.test_types
LIMIT 5;

-- 提取时间部分
SELECT 
    datetime_col,
    toYear(datetime_col) AS year,
    toMonth(datetime_col) AS month,
    toDayOfMonth(datetime_col) AS day,
    toHour(datetime_col) AS hour,
    toMinute(datetime_col) AS minute,
    toSecond(datetime_col) AS second,
    toDayOfWeek(datetime_col) AS day_of_week
FROM test_date_time.test_types
LIMIT 5;

-- ========================================
-- 4. 测试时区转换
-- ========================================

-- 时区转换
SELECT 
    event_name,
    event_time_utc AS utc_time,
    toTimezone(event_time_utc, 'Asia/Shanghai') AS shanghai_time,
    toTimezone(event_time_utc, 'America/New_York') AS new_york_time,
    toTimezone(event_time_utc, 'Europe/London') AS london_time
FROM test_date_time.test_timezones;

-- 计算时差
SELECT 
    event_name,
    event_time_utc,
    event_time_local,
    dateDiff('hour', event_time_utc, event_time_local) AS time_difference_hours
FROM test_date_time.test_timezones;

-- ========================================
-- 5. 测试日期算术
-- ========================================

-- 基本算术运算
SELECT 
    datetime_col,
    datetime_col + INTERVAL 1 DAY AS plus_one_day,
    datetime_col - INTERVAL 1 DAY AS minus_one_day,
    datetime_col + INTERVAL 1 WEEK AS plus_one_week,
    datetime_col + INTERVAL 1 MONTH AS plus_one_month,
    datetime_col + INTERVAL 1 YEAR AS plus_one_year
FROM test_date_time.test_types
LIMIT 3;

-- 专用函数
SELECT 
    datetime_col,
    addDays(datetime_col, 7) AS add_7_days,
    addWeeks(datetime_col, 2) AS add_2_weeks,
    addMonths(datetime_col, 3) AS add_3_months,
    addYears(datetime_col, 1) AS add_1_year,
    subtractDays(datetime_col, 7) AS subtract_7_days
FROM test_date_time.test_types
LIMIT 3;

-- 时间差计算
SELECT 
    event_time_utc,
    now() AS current_time,
    dateDiff('second', event_time_utc, now()) AS diff_seconds,
    dateDiff('minute', event_time_utc, now()) AS diff_minutes,
    dateDiff('hour', event_time_utc, now()) AS diff_hours,
    dateDiff('day', event_time_utc, now()) AS diff_days
FROM test_date_time.test_timezones
LIMIT 3;

-- ========================================
-- 6. 测试时间范围查询
-- ========================================

-- 查询最近 7 天的数据
SELECT 
    toStartOfDay(event_time) AS day,
    count() AS event_count
FROM test_data_deletion.test_events_ttl
WHERE event_time >= now() - INTERVAL 7 DAY
GROUP BY day
ORDER BY day;

-- 查询本月的数据
SELECT 
    toStartOfMonth(event_time) AS month,
    count() AS event_count
FROM test_data_deletion.test_events_ttl
WHERE event_time >= toStartOfMonth(now())
  AND event_time < toEndOfMonth(now())
GROUP BY month;

-- 使用 toStartOfDay 查询
SELECT 
    toStartOfDay(event_time) AS day,
    count() AS event_count
FROM test_data_deletion.test_logs
WHERE event_time >= toStartOfDay(now() - INTERVAL 30 DAY)
GROUP BY day
ORDER BY day;

-- ========================================
-- 7. 测试时间序列分析
-- ========================================

-- 按小时聚合
SELECT 
    hour_key,
    metric_name,
    avg(metric_value) AS avg_value,
    max(metric_value) AS max_value,
    min(metric_value) AS min_value,
    count() AS sample_count
FROM test_date_time.test_timeseries
WHERE timestamp >= now() - INTERVAL 7 DAY
GROUP BY hour_key, metric_name
ORDER BY hour_key, metric_name;

-- 按天聚合
SELECT 
    day_key,
    metric_name,
    avg(metric_value) AS avg_value,
    stddevPop(metric_value) AS std_dev,
    quantile(0.5)(metric_value) AS median,
    quantile(0.95)(metric_value) AS p95
FROM test_date_time.test_timeseries
WHERE timestamp >= now() - INTERVAL 7 DAY
GROUP BY day_key, metric_name
ORDER BY day_key, metric_name;

-- 窗口函数：滚动平均
SELECT 
    timestamp,
    metric_name,
    metric_value,
    avg(metric_value) OVER (
        PARTITION BY metric_name
        ORDER BY timestamp
        ROWS BETWEEN 2 PRECEDING AND CURRENT ROW
    ) AS rolling_avg_3
FROM test_date_time.test_timeseries
ORDER BY metric_name, timestamp;

-- 窗口函数：累计求和
SELECT 
    timestamp,
    metric_name,
    metric_value,
    sum(metric_value) OVER (
        PARTITION BY metric_name
        ORDER BY timestamp
    ) AS cumulative_sum
FROM test_date_time.test_timeseries
ORDER BY metric_name, timestamp;

-- ========================================
-- 8. 性能测试查询
-- ========================================

-- 测试分区裁剪
EXPLAIN 
SELECT count(*)
FROM test_data_deletion.test_events_ttl
WHERE event_time >= now() - INTERVAL 7 DAY;

-- 测试索引使用
EXPLAIN 
SELECT *
FROM test_info_schema.test_events
WHERE user_id = 1
  AND event_time >= now() - INTERVAL 7 DAY;

-- 测试聚合性能
SELECT 
    database,
    table,
    sum(rows) as total_rows,
    sum(bytes_on_disk) as total_bytes,
    formatReadableSize(sum(bytes_on_disk)) as readable_size
FROM system.parts
WHERE database IN ('test_info_schema', 'test_data_deletion', 'test_date_time')
  AND active = 1
GROUP BY database, table
ORDER BY total_bytes DESC;

-- ========================================
-- 清理和总结
-- ========================================

-- 查看所有测试数据库
SELECT name FROM system.databases WHERE name LIKE 'test_%';

-- 查看所有测试表的统计信息
SELECT 
    database,
    table,
    engine,
    total_rows,
    total_bytes,
    formatReadableSize(total_bytes) as readable_size
FROM system.tables
WHERE database LIKE 'test_%'
ORDER BY database, table;

-- 查看所有 Mutation 的状态
SELECT 
    database,
    table,
    mutation_id,
    command,
    is_done,
    parts_to_do,
    progress
FROM system.mutations
WHERE database LIKE 'test_%'
ORDER BY created;

-- 查看所有副本状态
SELECT 
    database,
    table,
    is_leader,
    can_become_leader,
    is_readonly,
    queue_size,
    absolute_delay
FROM system.replicas
WHERE database LIKE 'test_%';

-- ========================================
-- 可选：清理测试数据
-- ========================================

-- 取消注释以下语句以清理测试数据
-- DROP DATABASE IF EXISTS test_info_schema ON CLUSTER 'treasurycluster' SYNC;
-- DROP DATABASE IF EXISTS test_data_deletion ON CLUSTER 'treasurycluster' SYNC;
-- DROP DATABASE IF EXISTS test_date_time ON CLUSTER 'treasurycluster' SYNC;
