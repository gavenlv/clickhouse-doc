-- ============================================================
-- ClickHouse Kafka Engine 深度示例
-- 集群：treasurycluster（CH 25.12.1.649）
-- 说明：本文件包含 Kafka Engine 的完整配置和操作示例
-- 前置条件：需要运行中的 Kafka 集群（本文件为配置参考，部分命令需要 Kafka 环境）
-- 学习目标：掌握 Kafka Engine + MV 的标准摄入模式、offset 管理、去重策略和性能调优
-- ============================================================

-- 注意：本文件中涉及 Kafka 连接的 DDL 语句需要实际的 Kafka 集群支持。
-- setup/teardown 部分的 SQL 可以直接执行（不依赖 Kafka）。

-- ============================================================
-- 第一部分：Kafka Engine 基础 — 标准摄入模式
-- ============================================================

-- 【原理】Kafka Engine 表本身不存储数据，仅提供对 Kafka Topic 的实时消费接口。
-- 数据持久化的唯一方式是：Kafka Engine 表 → 物化视图 → MergeTree 表。
-- 这是 ClickHouse 中 Kafka 摄入的"标准答案"。

-- Step 1: 创建目标表（数据落地的 MergeTree 表）
CREATE TABLE IF NOT EXISTS integration_kafka.events_target
(
    event_time DateTime,
    user_id UInt64,
    event_type String,
    properties String,
    ingest_time DateTime DEFAULT now()
)
ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_type, event_time, user_id);

-- Step 2: 创建 Kafka Engine 表（消费接口）
-- SETTINGS 说明：
--   kafka_broker_list: Kafka broker 地址列表
--   kafka_topic_list: 要消费的 topic（支持逗号分隔多个 topic）
--   kafka_group_name: consumer group 名称（同一 group 的多个实例自动负载均衡）
--   kafka_format: 消息反序列化格式
--   kafka_num_consumers: 消费者线程数（建议 ≤ topic 分区数）
--   kafka_max_block_size: 每批拉取的最大行数
CREATE TABLE IF NOT EXISTS integration_kafka.events_queue
(
    event_time DateTime,
    user_id UInt64,
    event_type String,
    properties String
)
ENGINE = Kafka
SETTINGS
    kafka_broker_list = 'kafka1:9092,kafka2:9092,kafka3:9092',
    kafka_topic_list = 'user_events',
    kafka_group_name = 'ch_user_events_consumer',
    kafka_format = 'JSONEachRow',
    kafka_num_consumers = 4,
    kafka_max_block_size = 1048576;

-- Step 3: 创建物化视图（将 Kafka 数据实时写入目标表）
CREATE MATERIALIZED VIEW IF NOT EXISTS integration_kafka.events_mv
TO integration_kafka.events_target
AS SELECT
    event_time,
    user_id,
    event_type,
    properties,
    now() AS ingest_time
FROM integration_kafka.events_queue;

-- ============================================================
-- 第二部分：Kafka 虚拟列 — _topic/_offset/_partition 实战
-- ============================================================

-- 【原理】Kafka Engine 提供 5 个虚拟列，不需要在表结构声明。
-- 虚拟列对 MV 可见，常用于多 topic 区分、去重和监控。

-- 多 Topic 消费 + 虚拟列去重
CREATE TABLE IF NOT EXISTS integration_kafka.events_dedup
(
    topic String,
    partition UInt64,
    offset UInt64,
    event_time DateTime,
    user_id UInt64,
    event_type String,
    ingest_time DateTime DEFAULT now()
)
ENGINE = ReplacingMergeTree(ingest_time)  -- 用时间戳做版本，保留最新的
ORDER BY (topic, partition, offset);      -- 用 Kafka 坐标做唯一标识

-- 多 Topic 消费表（JSONAsString 将整条消息存为 payload）
CREATE TABLE IF NOT EXISTS integration_kafka.multi_topic_queue
(
    _topic String,
    _offset UInt64,
    _partition UInt64,
    payload String
)
ENGINE = Kafka
SETTINGS
    kafka_broker_list = 'kafka1:9092,kafka2:9092',
    kafka_topic_list = 'events_web,events_app,events_api',
    kafka_group_name = 'ch_multi_topic_consumer',
    kafka_format = 'JSONAsString',
    kafka_num_consumers = 3;

-- 去重物化视图：利用 (topic, partition, offset) 做幂等写入
CREATE MATERIALIZED VIEW IF NOT EXISTS integration_kafka.multi_topic_mv
TO integration_kafka.events_dedup
AS SELECT
    _topic AS topic,
    _partition AS partition,
    _offset AS offset,
    -- 从 payload 中解析 JSON 字段
    toDateTime(JSONExtractString(payload, 'event_time')) AS event_time,
    toUInt64(JSONExtractString(payload, 'user_id')) AS user_id,
    JSONExtractString(payload, 'event_type') AS event_type,
    now() AS ingest_time
FROM integration_kafka.multi_topic_queue;

-- ============================================================
-- 第三部分：Exactly-Once 语义 — 三级去重策略
-- ============================================================

-- 【原理】Kafka + ClickHouse 的 exactly-once 是"至少一次 + 幂等写入"的组合。
-- 因为 offset 提交和 MV 写入不是原子操作，rebalance 时消息会被重复消费。
-- 解决方案：利用 (topic, partition, offset) 做幂等键。

-- 策略 1: ReplacingMergeTree 去重（最终一致）
CREATE TABLE IF NOT EXISTS integration_kafka.events_eos1
(
    topic String,
    partition_id UInt64,
    msg_offset UInt64,
    event_time DateTime,
    user_id UInt64,
    event_type String,
    version DateTime DEFAULT now()
)
ENGINE = ReplacingMergeTree(version)
ORDER BY (topic, partition_id, msg_offset);

-- 相当于: INSERT OR REPLACE INTO events_eos1 VALUES (...)
-- 同一条 Kafka 消息无论被消费多少次，合并后只保留 version 最大的行

-- 策略 2: AggregatingMergeTree 去重（聚合场景）
CREATE TABLE IF NOT EXISTS integration_kafka.events_agg
(
    event_date Date,
    event_type String,
    event_count SimpleAggregateFunction(sum, UInt64)
)
ENGINE = AggregatingMergeTree()
ORDER BY (event_date, event_type);

-- 插入物化视图
-- 每条消息独立写入，但合并时 sum 自动聚合
-- 重复写入相同日期+类型的数据会在 Merge 时自动合并

-- 策略 3: 应用层窗口去重（使用 TTL 清理旧数据）
CREATE TABLE IF NOT EXISTS integration_kafka.events_window
(
    event_time DateTime,
    user_id UInt64,
    event_type String,
    dedup_key UInt64 MATERIALIZED cityHash64(event_time, user_id, event_type)
)
ENGINE = ReplacingMergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY dedup_key
TTL event_time + INTERVAL 7 DAY;  -- 7 天后自动清理

-- ============================================================
-- 第四部分：AvroConfluent 格式 — Schema Registry 集成
-- ============================================================

-- 【原理】AvroConfluent 格式在消息头部包含 Schema ID，ClickHouse 自动从
-- Schema Registry 获取 Schema 定义并反序列化。无需手动管理 Schema 版本。
-- 这对于 Schema 频繁演进的大数据管道非常关键。

-- Schema Registry 地址在 global settings 或表级 settings 中配置

-- Kafka Engine 表（Avro 格式）—— 需要 Schema Registry 服务
-- CREATE TABLE IF NOT EXISTS integration_kafka.events_avro
-- (
--     event_time DateTime,
--     user_id UInt64,
--     event_type String
-- )
-- ENGINE = Kafka
-- SETTINGS
--     kafka_broker_list = 'kafka1:9092',
--     kafka_topic_list = 'events_avro',
--     kafka_group_name = 'ch_avro_consumer',
--     kafka_format = 'AvroConfluent',
--     kafka_num_consumers = 4;

-- ============================================================
-- 第五部分：性能调优 — 吞吐 vs 延迟
-- ============================================================

-- 【原理】Kafka 摄入性能由以下参数决定：
-- consumer 数量 × 每批行数 × poll 频率
-- 增加吞吐 = 增大 kafka_max_block_size + 增大 kafka_num_consumers
-- 降低延迟 = 减小 kafka_max_block_size + 减小 kafka_flush_interval_ms

-- 高吞吐配置（批处理 / ETL 场景）
-- CREATE TABLE IF NOT EXISTS integration_kafka.events_high_throughput (...)
-- ENGINE = Kafka
-- SETTINGS
--     kafka_broker_list = 'kafka1:9092',
--     kafka_topic_list = 'events_large',
--     kafka_group_name = 'ch_high_throughput',
--     kafka_format = 'JSONEachRow',
--     kafka_num_consumers = 8,           -- 匹配 8 分区
--     kafka_max_block_size = 4194304,     -- 4M 行/批
--     kafka_poll_timeout_ms = 200,        -- 200ms 拉取
--     kafka_flush_interval_ms = 10000,    -- 10 秒 flush
--     stream_flush_interval_ms = 10000;

-- 低延迟配置（实时监控场景）
-- CREATE TABLE IF NOT EXISTS integration_kafka.events_low_latency (...)
-- ENGINE = Kafka
-- SETTINGS
--     kafka_broker_list = 'kafka1:9092',
--     kafka_topic_list = 'events_realtime',
--     kafka_group_name = 'ch_low_latency',
--     kafka_format = 'JSONEachRow',
--     kafka_num_consumers = 2,
--     kafka_max_block_size = 65536,
--     kafka_poll_timeout_ms = 10,         -- 10ms 拉取
--     kafka_flush_interval_ms = 200,      -- 200ms flush
--     stream_flush_interval_ms = 200;

-- ============================================================
-- 第六部分：监控与诊断
-- ============================================================

-- 查看 Kafka Engine 表状态
SELECT
    database,
    table,
    engine,
    total_rows,
    total_bytes,
    formatReadableSize(total_bytes) AS size_str
FROM system.tables
WHERE engine = 'Kafka';

-- 查看 Kafka consumer 配置和状态
SELECT
    database,
    table,
    consumer_id,
    topic,
    partition,
    last_offset,
    last_poll_time,
    num_messages_read,
    last_error
FROM system.kafka_consumers
ORDER BY table, partition;

-- 查看物化视图状态
SELECT
    database,
    name AS mv_name,
    target_table,
    is_refreshable,
    total_rows
FROM system.tables
WHERE engine = 'MaterializedView';

-- 检查目标表数据量
SELECT
    count() AS total_rows,
    min(event_time) AS earliest_event,
    max(event_time) AS latest_event,
    dateDiff('second', earliest_event, latest_event) AS time_span_sec
FROM integration_kafka.events_target;

-- 检查去重效果（ReplacingMergeTree 场景）
SELECT
    count() AS raw_rows,                     -- 含重复的总行数
    count(DISTINCT (topic, partition, offset)) AS unique_messages  -- 去重后
FROM integration_kafka.events_dedup;

-- ============================================================
-- 第七部分：kafka() 表函数 — 临时探查
-- ============================================================

-- 【原理】kafka() 表函数用于临时查看 Kafka 数据，不需要 CREATE TABLE。
-- 每次 SELECT 建立新的 consumer 连接，不追踪 offset。
-- 不适用于生产 ETL（无法建 MV），仅用于调试和数据探查。

-- 查看最新 10 条消息
-- SELECT *
-- FROM kafka(
--     'kafka1:9092,kafka2:9092',
--     'user_events',
--     'ch_debug',
--     'JSONEachRow'
-- )
-- SETTINGS kafka_max_block_size = 10
-- LIMIT 10;

-- 查看消息格式（确认 JSON 字段名和类型）
-- SELECT *
-- FROM kafka()
-- FORMAT JSONEachRow;

-- ============================================================
-- 第八部分：清理示例资源
-- ============================================================

-- DROP TABLE IF EXISTS integration_kafka.events_mv;
-- DROP TABLE IF EXISTS integration_kafka.events_queue;
-- DROP TABLE IF EXISTS integration_kafka.events_target;
-- DROP TABLE IF EXISTS integration_kafka.multi_topic_queue;
-- DROP TABLE IF EXISTS integration_kafka.multi_topic_mv;
-- DROP TABLE IF EXISTS integration_kafka.events_dedup;
-- DROP TABLE IF EXISTS integration_kafka.events_eos1;
-- DROP TABLE IF EXISTS integration_kafka.events_agg;
-- DROP TABLE IF EXISTS integration_kafka.events_window;
-- DROP DATABASE IF EXISTS integration_kafka;
