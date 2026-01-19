-- ========================================
-- ClickHouse 实时数据写入和集成（Flink + Kafka）
-- ========================================
-- 说明：展示 ClickHouse 与 Apache Flink 和 Apache Kafka 的集成
-- 以及实时数据写入的最佳实践和性能优化
-- ========================================

-- ========================================
-- 1. Kafka 集成 - Kafka 表引擎
-- ========================================

-- 场景 1：消费 Kafka 事件数据
CREATE DATABASE IF NOT EXISTS realtime_examples;

-- 创建 Kafka 引擎表（作为数据消费者）
CREATE TABLE IF NOT EXISTS realtime_examples.kafka_events (
    -- 事件标识
    event_id String,
    event_type String,
    event_time DateTime DEFAULT now(),
    
    -- 用户信息
    user_id UInt64,
    session_id String,
    
    -- 设备信息
    device_type String,
    os_name String,
    browser_name String,
    
    -- 业务数据
    page_url String,
    referrer_url String,
    campaign_source String,
    medium String,
    
    -- 数值指标
    duration_sec UInt32,
    scroll_depth Float32,
    interaction_count UInt16,
    
    -- 元数据
    topic String DEFAULT 'user_events',
    partition Int64,
    offset Int64
) ENGINE = Kafka
SETTINGS 
    -- Kafka 配置
    kafka_broker_list = 'kafka-broker:9092',      -- Kafka broker 地址
    kafka_topic_list = 'user_events',                -- 主题名称
    kafka_group_name = 'clickhouse_consumer',         -- 消费者组
    kafka_format = 'JSONEachRow',                   -- 数据格式
    -- 性能配置
    kafka_num_consumers = 2,                       -- 消费者数量
    kafka_max_block_size = 65536,                  -- 最大块大小
    kafka_skip_broken_messages = 1,                 -- 跳过损坏的消息
    kafka_row_delimiter = '\n',                    -- 行分隔符
    -- 可选：认证配置
    -- kafka_security_protocol = 'SASL_SSL',
    -- kafka_sasl_mechanism = 'PLAIN',
    -- kafka_sasl_username = 'username',
    -- kafka_sasl_password = 'password';

-- 创建目标表（存储消费的数据，生产环境：使用复制引擎 + ON CLUSTER）
CREATE TABLE IF NOT EXISTS realtime_examples.events ON CLUSTER 'treasurycluster' (
    event_id String,
    event_type String,
    event_time DateTime,
    user_id UInt64,
    session_id String,
    device_type String,
    os_name String,
    browser_name String,
    page_url String,
    referrer_url String,
    campaign_source String,
    medium String,
    duration_sec UInt32,
    scroll_depth Float32,
    interaction_count UInt16
) ENGINE = ReplicatedMergeTree
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_time, user_id, event_id)
SETTINGS index_granularity = 8192;

-- 创建物化视图，自动从 Kafka 消费数据到目标表（生产环境：使用复制引擎 + ON CLUSTER）
CREATE MATERIALIZED VIEW IF NOT EXISTS realtime_examples.events_consumer ON CLUSTER 'treasurycluster'
ENGINE = ReplicatedMergeTree
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_time, user_id, event_id)
AS SELECT
    event_id,
    event_type,
    event_time,
    user_id,
    session_id,
    device_type,
    os_name,
    browser_name,
    page_url,
    referrer_url,
    campaign_source,
    medium,
    duration_sec,
    scroll_depth,
    interaction_count
FROM realtime_examples.kafka_events;

-- 查看 Kafka 消费状态
SELECT
    topic,
    partition,
    max_offset as consumed_offset,
    rows as total_rows,
    formatReadableSize(bytes_on_disk) as disk_size
FROM system.kafka_consumers
WHERE database = 'realtime_examples'
  AND table = 'kafka_events'
ORDER BY partition;

-- 查询已消费的数据
SELECT
    count() as event_count,
    countDistinct(user_id) as unique_users,
    countDistinct(session_id) as sessions,
    min(event_time) as first_event,
    max(event_time) as last_event
FROM realtime_examples.events;

-- ========================================
-- 2. Kafka 集成 - 复杂 JSON 数据处理
-- ========================================

-- 场景 2：消费嵌套 JSON 数据
CREATE TABLE IF NOT EXISTS realtime_examples.kafka_orders (
    -- 原始 JSON 数据
    json_data String,
    
    -- 解析后的字段
    order_id String,
    user_id UInt64,
    product_id UInt64,
    quantity UInt32,
    price Decimal(10, 2),
    order_date Date,
    created_at DateTime,
    
    -- Kafka 元数据
    _topic String,
    _partition Int64,
    _offset Int64,
    _timestamp UInt64
) ENGINE = Kafka
SETTINGS
    kafka_broker_list = 'kafka-broker:9092',
    kafka_topic_list = 'orders',
    kafka_group_name = 'clickhouse_consumer_orders',
    kafka_format = 'JSONEachRow',
    kafka_num_consumers = 2;

-- 创建目标表（订单数据，生产环境：使用复制引擎 + ON CLUSTER）
CREATE TABLE IF NOT EXISTS realtime_examples.orders ON CLUSTER 'treasurycluster' (
    order_id String,
    user_id UInt64,
    product_id UInt64,
    quantity UInt32,
    price Decimal(10, 2),
    total_amount Decimal(10, 2),
    order_date Date,
    created_at DateTime
) ENGINE = ReplicatedMergeTree
PARTITION BY toYYYYMM(order_date)
ORDER BY (order_id, order_date)
SETTINGS index_granularity = 8192;

-- 使用物化视图处理 JSON 数据并插入目标表（生产环境：使用复制引擎 + ON CLUSTER）
CREATE MATERIALIZED VIEW IF NOT EXISTS realtime_examples.orders_consumer ON CLUSTER 'treasurycluster'
ENGINE = ReplicatedMergeTree
PARTITION BY toYYYYMM(order_date)
ORDER BY (order_id, order_date)
AS SELECT
    JSONExtractString(json_data, 'order_id') as order_id,
    JSONExtractUInt64(json_data, 'user_id') as user_id,
    JSONExtractUInt64(json_data, 'product_id') as product_id,
    JSONExtractUInt32(json_data, 'quantity') as quantity,
    JSONExtractFloat(json_data, 'price') as price,
    JSONExtractUInt32(json_data, 'quantity') * JSONExtractFloat(json_data, 'price') as total_amount,
    JSONExtractString(json_data, 'order_date') as order_date,
    JSONExtractString(json_data, 'created_at') as created_at
FROM realtime_examples.kafka_orders;

-- 查询订单数据
SELECT
    order_date,
    count() as order_count,
    sum(quantity) as total_quantity,
    sum(total_amount) as total_revenue,
    avg(total_amount) as avg_order_value
FROM realtime_examples.orders
WHERE order_date >= today() - INTERVAL 7 DAY
GROUP BY order_date
ORDER BY order_date DESC;

-- ========================================
-- 3. Kafka 集成 - 多主题消费
-- ========================================

-- 场景 3：使用正则表达式匹配多个主题
CREATE TABLE IF NOT EXISTS realtime_examples.kafka_multi_topics (
    event_id String,
    event_type String,
    event_data String,
    event_time DateTime DEFAULT now(),
    topic String
) ENGINE = Kafka
SETTINGS
    kafka_broker_list = 'kafka-broker:9092',
    kafka_topic_list = 'events_.*',                    -- 正则匹配：events_*
    kafka_group_name = 'clickhouse_consumer_multi',
    kafka_format = 'JSONEachRow',
    kafka_num_consumers = 4;                          -- 增加消费者数量

-- 查看匹配的主题
SELECT
    topic,
    partition,
    max_offset,
    rows
FROM system.kafka_consumers
WHERE database = 'realtime_examples'
  AND table = 'kafka_multi_topics';

-- ========================================
-- 4. Flink 集成 - 通过 HTTP 接口
-- ========================================

-- 创建 Flink 写入的目标表（生产环境：使用复制引擎 + ON CLUSTER）
CREATE TABLE IF NOT EXISTS realtime_examples.flink_sink_table ON CLUSTER 'treasurycluster' (
    -- 主键和时间
    event_id UInt64,
    event_time DateTime,
    
    -- 用户信息
    user_id UInt64,
    user_name String,
    user_email String,
    
    -- 事件数据
    event_type String,
    event_category String,
    event_value Float64,
    
    -- 位置信息
    country String,
    city String,
    
    -- 设备信息
    device_type String,
    os_name String,
    
    -- 元数据
    flink_job_id String,
    flink_timestamp DateTime
) ENGINE = ReplicatedMergeTree
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_time, user_id, event_id)
SETTINGS 
    index_granularity = 8192,
    max_insert_block_size = 1048576,           -- Flink 批量写入优化
    min_insert_block_size_rows = 1048576,      -- 最小行数
    max_partitions_per_insert_block = 100;    -- 最大分区数

-- Flink 写入示例（通过 HTTP 接口）
-- 在 Flink 中使用 ClickHouseSink
/*
Flink 示例代码：

import org.apache.flink.streaming.api.functions.sink.SinkFunction;
import org.apache.flink.table.data.RowData;

public class ClickHouseSink implements SinkFunction<RowData> {
    
    private String clickHouseUrl;
    private HttpClient httpClient;
    
    public ClickHouseSink(String url) {
        this.clickHouseUrl = url;
        this.httpClient = HttpClient.newHttpClient();
    }
    
    @Override
    public void invoke(RowData value, Context context) {
        String query = buildInsertQuery(value);
        HttpRequest request = HttpRequest.newBuilder()
            .uri(URI.create(clickHouseUrl))
            .header("Content-Type", "text/plain")
            .POST(HttpRequest.BodyPublishers.ofString(query))
            .build();
        
        httpClient.send(request, HttpResponse.BodyHandlers.ofString());
    }
}
*/

-- Flink 通过 HTTP 写入的性能优化
-- 1. 使用批量插入（max_insert_block_size）
-- 2. 异步写入，不等待响应
-- 3. 使用 Connection Pool
-- 4. 配置合理的超时时间

-- ========================================
-- 5. Flink 集成 - 通过 JDBC 接口
-- ========================================

-- 创建适合 Flink JDBC 写入的表（生产环境：使用复制引擎 + ON CLUSTER）
CREATE TABLE IF NOT EXISTS realtime_examples.flink_jdbc_sink ON CLUSTER 'treasurycluster' (
    -- 主键
    id UInt64,
    
    -- 业务字段
    name String,
    value Decimal(10, 2),
    category String,
    status String,
    
    -- 时间字段
    created_at DateTime,
    updated_at DateTime,
    
    -- Flink 元数据
    flink_task_name String,
    flink_subtask_index UInt32
) ENGINE = ReplicatedMergeTree
PARTITION BY toYYYYMM(created_at)
ORDER BY (id, created_at)
SETTINGS 
    index_granularity = 8192,
    max_bytes_to_merge_at_once = 1610612736,    -- 1.5GB
    max_rows_to_merge_at_once = 1638400;         -- 批量合并优化

-- Flink JDBC 配置示例
/*
Flink SQL 示例：

-- 创建 Flink 表（源）
CREATE TABLE flink_source (
    id BIGINT,
    name STRING,
    value DECIMAL(10, 2),
    category STRING,
    created_at TIMESTAMP(3)
) WITH (
    'connector' = 'kafka',
    'topic' = 'flink_source',
    'properties.bootstrap.servers' = 'kafka-broker:9092',
    'properties.group.id' = 'flink_consumer',
    'format' = 'json'
);

-- 创建 Flink 表（ClickHouse sink）
CREATE TABLE clickhouse_sink (
    id BIGINT,
    name STRING,
    value DECIMAL(10, 2),
    category STRING,
    status STRING,
    created_at TIMESTAMP(3),
    updated_at TIMESTAMP(3),
    flink_task_name STRING,
    flink_subtask_index INT
) WITH (
    'connector' = 'jdbc',
    'url' = 'jdbc:clickhouse://clickhouse-server-1:8123/default',
    'table-name' = 'flink_jdbc_sink',
    'driver' = 'com.clickhouse.jdbc.ClickHouseDriver',
    'batch-size' = '1000',           -- 批量插入大小
    'batch-interval-ms' = '1000',       -- 批量间隔
    'max-retries' = '3'                -- 最大重试次数
);

-- 执行数据流
INSERT INTO clickhouse_sink
SELECT 
    id,
    name,
    value,
    category,
    'active' as status,
    created_at,
    CURRENT_TIMESTAMP as updated_at,
    CURRENT_TASK_NAME() as flink_task_name,
    CURRENT_SUBTASK_INDEX() as flink_subtask_index
FROM flink_source;
*/

-- ========================================
-- 6. 实时数据写入性能优化
-- ========================================

-- 创建高性能实时写入表（生产环境：使用复制引擎 + ON CLUSTER）
CREATE TABLE IF NOT EXISTS realtime_examples.high_performance_stream ON CLUSTER 'treasurycluster' (
    -- 主键
    stream_id UInt64,
    user_id UInt64,
    event_time DateTime,
    
    -- 业务数据
    event_type String,
    event_data String,
    metric_value Float64,
    
    -- 优化字段：使用 LowCardinality
    country LowCardinality(String),
    device_type LowCardinality(String),
    status LowCardinality(String),
    
    -- 优化字段：使用合适的类型
    duration_ms UInt32,           -- 不是 UInt64
    bytes_processed UInt32,        -- 不是 UInt64
    
    -- 元数据
    source_system String,
    created_at DateTime DEFAULT now()
) ENGINE = ReplicatedMergeTree
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_time, user_id, stream_id)
SETTINGS 
    -- 写入性能优化
    max_insert_block_size = 1048576,              -- 1MB 块大小
    min_insert_block_size_rows = 65536,           -- 64K 行
    min_insert_block_size_bytes = 268435456,       -- 256MB
    
    -- 合并性能优化
    max_bytes_to_merge_at_once = 1610612736,    -- 1.5GB
    max_rows_to_merge_at_once = 1638400,          -- 1.6M 行
    background_pool_size = 16,                    -- 后台线程池
    max_bytes_to_merge_at_minimal_time = 134217728, -- 128MB
    
    -- 索引优化
    index_granularity = 8192,
    write_final_mark = 0;                        -- 不写入 final mark

-- 模拟实时批量插入（Flink/Kafka 批量写入）
INSERT INTO realtime_examples.high_performance_stream SELECT
    number as stream_id,
    number % 1000 as user_id,
    now() - toIntervalMinute(number) as event_time,
    ['click', 'view', 'purchase', 'error'][number % 4] as event_type,
    concat('data-', toString(number)) as event_data,
    rand() * 100 as metric_value,
    ['US', 'UK', 'DE', 'CN'][number % 4] as country,
    ['mobile', 'desktop', 'tablet'][number % 3] as device_type,
    ['active', 'inactive'][number % 2] as status,
    rand() * 60000 as duration_ms,
    rand() * 1048576 as bytes_processed,
    'kafka' as source_system,
    now() as created_at
FROM numbers(100000);

-- 查询写入性能统计
SELECT
    count() as total_rows,
    countDistinct(user_id) as unique_users,
    formatReadableSize(sum(bytes_on_disk)) as disk_size,
    avg(duration_ms) as avg_duration,
    max(duration_ms) as max_duration
FROM realtime_examples.high_performance_stream;

-- 查看合并操作状态
SELECT
    table,
    parts,
    rows,
    bytes_on_disk,
    bytes_on_disk_uncompressed,
    is_frozen,
    is_in_memory
FROM system.parts
WHERE table = 'high_performance_stream'
  AND database = 'realtime_examples'
  AND active
ORDER BY partition DESC, name
LIMIT 20;

-- ========================================
-- 7. Buffer 表 - 写入缓冲
-- ========================================

-- 创建 Buffer 表作为写入缓冲（生产环境：使用复制引擎 + ON CLUSTER）
CREATE TABLE IF NOT EXISTS realtime_examples.buffer_target ON CLUSTER 'treasurycluster' (
    id UInt64,
    user_id UInt64,
    event_type String,
    event_data String,
    event_time DateTime,
    created_at DateTime DEFAULT now()
) ENGINE = ReplicatedMergeTree
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_time, user_id, id);

-- 创建 Buffer 表
CREATE TABLE IF NOT EXISTS realtime_examples.buffer_table (
    id UInt64,
    user_id UInt64,
    event_type String,
    event_data String,
    event_time DateTime,
    created_at DateTime DEFAULT now()
) ENGINE = Buffer(
    realtime_examples,          -- 目标数据库
    buffer_target,             -- 目标表
    16,                       -- 缓冲区数量
    10,                       -- 最久时间（秒）
    10000,                    -- 最大行数
    10000000,                 -- 最大字节数（10MB）
    10000,                    -- 最小行数（触发刷新）
    1000000                   -- 最小字节数（1MB）
);

-- 向 Buffer 表写入数据
INSERT INTO realtime_examples.buffer_table VALUES
(1, 100, 'click', 'data1', now()),
(2, 101, 'view', 'data2', now()),
(3, 102, 'purchase', 'data3', now());

-- 数据会自动刷新到目标表（10秒或达到阈值后）
-- 查询 Buffer 表状态
SELECT
    bytes,
    rows,
    time,
    time_passed,
    total_rows,
    total_bytes
FROM system.buffers
WHERE database = 'realtime_examples'
  AND table = 'buffer_table';

-- 查询目标表（数据已刷新）
SELECT * FROM realtime_examples.buffer_target ORDER BY event_time DESC;

-- Buffer 表的优势：
-- 1. 减少小批量写入
-- 2. 提高写入性能
-- 3. 自动批量刷新
-- 4. 适合高频小数据写入

-- ========================================
-- 8. 实时数据质量检查
-- ========================================

-- 创建数据质量检查表（生产环境：使用复制引擎 + ON CLUSTER）
CREATE TABLE IF NOT EXISTS realtime_examples.data_quality_checks ON CLUSTER 'treasurycluster' (
    check_id UInt64,
    check_type String,          -- null_check, duplicate_check, schema_check
    table_name String,
    column_name String,
    record_count UInt64,
    error_count UInt64,
    error_rate Float64,
    check_time DateTime DEFAULT now(),
    status String               -- passed, failed, warning
) ENGINE = ReplicatedMergeTree
ORDER BY (check_time, check_id);

-- 示例 1：检查 NULL 值
INSERT INTO realtime_examples.data_quality_checks
SELECT
    1 as check_id,
    'null_check' as check_type,
    'high_performance_stream' as table_name,
    'event_type' as column_name,
    count() as record_count,
    countIf(event_type = '') as error_count,
    countIf(event_type = '') * 100.0 / count() as error_rate,
    now() as check_time,
    if(countIf(event_type = '') = 0, 'passed', 'failed') as status
FROM realtime_examples.high_performance_stream;

-- 示例 2：检查重复数据
INSERT INTO realtime_examples.data_quality_checks
SELECT
    2 as check_id,
    'duplicate_check' as check_type,
    'high_performance_stream' as table_name,
    'stream_id' as column_name,
    count() as record_count,
    count() - countDistinct(stream_id) as error_count,
    (count() - countDistinct(stream_id)) * 100.0 / count() as error_rate,
    now() as check_time,
    if(count() = countDistinct(stream_id), 'passed', 'failed') as status
FROM realtime_examples.high_performance_stream;

-- 查询数据质量检查结果
SELECT
    check_time,
    check_type,
    table_name,
    column_name,
    record_count,
    error_count,
    round(error_rate, 2) as error_rate_pct,
    status
FROM realtime_examples.data_quality_checks
ORDER BY check_time DESC;

-- ========================================
-- 9. 实时数据监控和告警
-- ========================================

-- 创建写入延迟监控表（生产环境：使用复制引擎 + ON CLUSTER）
CREATE TABLE IF NOT EXISTS realtime_examples.write_latency ON CLUSTER 'treasurycluster' (
    event_time DateTime,
    source_system String,
    table_name String,
    write_duration_ms UInt32,
    batch_size UInt32,
    status String
) ENGINE = ReplicatedMergeTree
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_time, source_system);

-- 模拟写入延迟记录
INSERT INTO realtime_examples.write_latency VALUES
(now() - toIntervalSecond(60), 'kafka', 'events', 50, 1000, 'success'),
(now() - toIntervalSecond(30), 'flink', 'high_performance_stream', 120, 10000, 'success'),
(now() - toIntervalSecond(10), 'kafka', 'orders', 200, 500, 'warning'),
(now() - toIntervalSecond(5), 'flink', 'buffer_target', 80, 5000, 'success');

-- 查询写入延迟统计
SELECT
    source_system,
    table_name,
    count() as total_writes,
    avg(write_duration_ms) as avg_latency_ms,
    max(write_duration_ms) as max_latency_ms,
    quantile(0.50)(write_duration_ms) as p50_latency,
    quantile(0.95)(write_duration_ms) as p95_latency,
    quantile(0.99)(write_duration_ms) as p99_latency,
    countIf(status != 'success') as failed_count,
    round(countIf(status != 'success') * 100.0 / count(), 2) as failure_rate
FROM realtime_examples.write_latency
WHERE event_time >= now() - toIntervalMinute(10)
GROUP BY source_system, table_name
ORDER BY source_system, table_name;

-- 创建告警规则（延迟 > 100ms）
SELECT
    source_system,
    table_name,
    avg_latency_ms,
    p95_latency_ms,
    p99_latency_ms,
    'High Latency Alert' as alert_type
FROM realtime_examples.write_latency
WHERE event_time >= now() - toIntervalMinute(10)
GROUP BY source_system, table_name
HAVING p95_latency_ms > 100
ORDER BY p95_latency_ms DESC;

-- ========================================
-- 10. 实时数据管道架构
-- ========================================

/*
推荐的实时数据管道架构：

┌─────────────┐    ┌─────────────┐    ┌─────────────┐    ┌─────────────┐
│   Kafka    │───▶│   Flink     │───▶│   Buffer    │───▶│ ClickHouse   │
│   Source   │    │   Process   │    │   Buffer    │    │   Storage   │
└─────────────┘    └─────────────┘    └─────────────┘    └─────────────┘

方案 1：Kafka → ClickHouse（直接）
  - 使用 Kafka 表引擎
  - 自动消费和写入
  - 适合简单场景

方案 2：Kafka → Flink → ClickHouse（处理）
  - Flink 处理和转换数据
  - 通过 JDBC/HTTP 写入
  - 适合复杂场景

方案 3：Kafka → Flink → Buffer → ClickHouse（缓冲）
  - Buffer 表批量写入
  - 最高性能
  - 适合高频写入

性能对比：
  - 方案 1：简单，性能中等
  - 方案 2：灵活，性能高
  - 方案 3：复杂，性能最高
*/

-- ========================================
-- 11. 分布式表实时写入
-- ========================================

-- 创建本地表（在两个副本上）
CREATE TABLE IF NOT EXISTS realtime_examples.events_local ON CLUSTER 'treasurycluster' (
    event_id UInt64,
    user_id UInt64,
    event_time DateTime,
    event_type String,
    event_data String
) ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/events_local', '{replica}')
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_time, user_id, event_id);

-- 创建分布式表（写入入口）
CREATE TABLE IF NOT EXISTS realtime_examples.events_distributed ON CLUSTER 'treasurycluster' AS
realtime_examples.events_local
ENGINE = Distributed('treasurycluster', 'realtime_examples', 'events_local', rand());

-- 写入分布式表（自动分发到副本）
INSERT INTO realtime_examples.events_distributed VALUES
(1, 100, now(), 'click', 'data1'),
(2, 101, now(), 'view', 'data2'),
(3, 102, now(), 'purchase', 'data3');

-- 查询分布式表（自动聚合）
SELECT
    event_time,
    count() as event_count,
    countDistinct(user_id) as unique_users,
    countIf(event_type = 'purchase') as purchase_count
FROM realtime_examples.events_distributed
GROUP BY toStartOfMinute(event_time) as event_time
ORDER BY event_time DESC
LIMIT 10;

-- ========================================
-- 12. 实时数据写入最佳实践
-- ========================================

/*
实时数据写入最佳实践：

1. 批量写入
   - 使用 max_insert_block_size
   - 避免单条插入
   - Flink/Kafka 配置合适的 batch size

2. 异步写入
   - Flink 不等待响应
   - 使用 connection pool
   - 配置合理的超时

3. 使用 Buffer 表
   - 减少小批量写入
   - 提高整体吞吐量
   - 适合高频小数据

4. 分区策略
   - 按时间分区
   - 控制分区数量
   - 优化查询剪枝

5. 数据类型优化
   - 使用 LowCardinality
   - 使用最小类型
   - 优化存储和查询

6. 索引优化
   - 合理的 ORDER BY
   - 使用跳数索引
   - 避免过多索引

7. 监控告警
   - 监控写入延迟
   - 监控错误率
   - 设置合理的阈值

8. 数据质量
   - 检查 NULL 值
   - 检查重复数据
   - 检查数据格式

9. 容错处理
   - 重试机制
   - 死信队列（DLQ）
   - 数据回放

10. 性能测试
    - 压力测试
    - 监控资源使用
    - 持续优化
*/

-- ========================================
-- 13. 故障排查和监控
-- ========================================

-- 查看实时写入性能
SELECT
    event_date,
    database,
    table,
    formatReadableSize(sum(data_uncompressed_bytes)) as uncompressed,
    formatReadableSize(sum(data_compressed_bytes)) as compressed,
    round(100.0 - data_compressed_bytes * 100.0 / data_uncompressed_bytes, 2) as compression_ratio,
    sum(rows) as total_rows,
    sum(bytes_on_disk) as disk_usage
FROM system.parts
WHERE active
  AND table LIKE '%events%'
GROUP BY event_date, database, table
ORDER BY event_date DESC;

-- 查看合并操作
SELECT
    database,
    table,
    count() as merges,
    sum(rows_merged) as total_rows_merged,
    sum(bytes_uncompressed) as total_bytes_merged,
    avg(merge_time) as avg_merge_time,
    max(merge_time) as max_merge_time
FROM system.merges
WHERE event_date >= today()
GROUP BY database, table
ORDER BY merges DESC;

-- 查看异步插入状态
SELECT
    query,
    elapsed,
    query_duration_ms,
    read_rows,
    written_rows,
    result_rows,
    formatReadableSize(memory_usage) as memory_used
FROM system.query_log
WHERE query LIKE '%INSERT%'
  AND event_date >= today()
  AND type = 'QueryFinish'
ORDER BY event_time DESC
LIMIT 10;

-- ========================================
-- 14. 清理测试数据（生产环境：使用 ON CLUSTER SYNC 确保集群范围删除）
-- ========================================

DROP TABLE IF EXISTS realtime_examples.kafka_events ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS realtime_examples.events ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS realtime_examples.events_consumer ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS realtime_examples.kafka_orders ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS realtime_examples.orders ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS realtime_examples.orders_consumer ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS realtime_examples.kafka_multi_topics ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS realtime_examples.flink_sink_table ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS realtime_examples.flink_jdbc_sink ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS realtime_examples.high_performance_stream ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS realtime_examples.buffer_target ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS realtime_examples.buffer_table ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS realtime_examples.data_quality_checks ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS realtime_examples.write_latency ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS realtime_examples.events_local ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS realtime_examples.events_distributed ON CLUSTER 'treasurycluster' SYNC;

DROP DATABASE IF EXISTS realtime_examples;

/*
清理 Kafka offset（如果需要完全重置）：
1. 停止消费
2. 删除 system.kafka_consumers 中的记录
3. 重启服务

或者使用新的 consumer group：
kafka_group_name = 'clickhouse_consumer_new'
*/
