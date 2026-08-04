# Kafka 引擎深度专题

Kafka Engine 是 ClickHouse 最常用也最容易出问题的集成引擎。它不是简单的"从 Kafka 读数据"，而是一个分布式消费系统，涉及 consumer group 协调、offset 管理、数据格式解析、去重策略等多个层面。本章深入讲解 Kafka Engine 的底层原理、生产配置和常见反模式。

## 目录

- [Kafka Engine vs kafka() 表函数](#kafka-engine-vs-kafka-表函数)
- [Kafka Engine 底层原理](#kafka-engine-底层原理)
- [Consumer Group 与 Offset 管理](#consumer-group-与-offset-管理)
- [数据格式与解析](#数据格式与解析)
- [虚拟列（Virtual Columns）](#虚拟列virtual-columns)
- [Exactly-Once 语义实现](#exactly-once-语义实现)
- [多 Topic 消费](#多-topic-消费)
- [性能调优](#性能调优)
- [故障恢复与 Rebalancing](#故障恢复与-rebalancing)
- [常见反模式与排查](#常见反模式与排查)

## Kafka Engine vs kafka() 表函数

这是 ClickHouse 用户最常见的困惑来源。

| 对比维度 | Kafka Engine（表引擎） | kafka() 表函数 |
|---------|----------------------|---------------|
| **本质** | 持久化表对象，需要 CREATE TABLE | 临时查询，用完即弃 |
| **生命周期** | 持续运行直到 DROP TABLE | 每次 SELECT 独立连接 |
| **offset 管理** | 自动管理（存储在 Keeper 或 Kafka） | 每次从最新或最早开始，不追踪 |
| **适用场景** | 持续数据摄入（ETL 管道） | 临时探查 Kafka 数据、调试 |
| **物化视图配合** | 标准模式：Kafka Engine → MV → MergeTree | 不支持（临时表不能建 MV） |
| **数据存哪里** | 不存 ClickHouse 内部，实时从 Kafka 拉取 | 不存，SELECT 一次性返回 |
| **并发控制** | 通过 consumer group 自动协调 | 每次 SELECT 创建新 consumer |

**一句话总结**：
- 生产 ETL 用 **Kafka Engine + Materialized View**（持续摄入）
- 调试探查用 **kafka() 表函数**（临时查看）

### 为什么 Kafka Engine 的 MV 模式是"标准答案"？

```sql
-- Kafka Engine 表：数据不落地，仅提供查询接口
CREATE TABLE kafka_queue (
    event_time DateTime,
    user_id UInt64,
    event_type String,
    properties String
) ENGINE = Kafka
SETTINGS
    kafka_broker_list = 'kafka1:9092,kafka2:9092',
    kafka_topic_list = 'user_events',
    kafka_group_name = 'ch_consumer_group',
    kafka_format = 'JSONEachRow',
    kafka_num_consumers = 4;

-- 物化视图：将数据实时写入 MergeTree
-- 这是 Kafka 数据"落地"的唯一方式
CREATE MATERIALIZED VIEW kafka_queue_mv TO target_table
AS SELECT * FROM kafka_queue;
```

## Kafka Engine 底层原理

### 工作流程

```
Kafka Topic (多 Partition)
    │
    ├── Partition 0 ──→ Consumer 0 (ClickHouse 线程)
    ├── Partition 1 ──→ Consumer 1 (ClickHouse 线程)
    ├── Partition 2 ──→ Consumer 2 (ClickHouse 线程)
    └── Partition 3 ──→ Consumer 3 (ClickHouse 线程)
                                │
                    kafka_num_consumers = min(partitions, 设置值)
                                │
                    ┌───────────┴───────────┐
                    │   Kafka Engine 表      │  ← 内存/临时存储
                    │   (不持久化数据)        │
                    └───────────┬───────────┘
                                │
                    ┌───────────┴───────────┐
                    │   物化视图 (MV)        │  ← 数据"落地"
                    │   写入 MergeTree 表     │
                    └───────────────────────┘
```

**关键原理**：
1. Kafka Engine 表本身**不存储数据**——每次 SELECT 直接从 Kafka 拉取最新消息
2. 数据持久化的唯一方式：通过物化视图将数据写入 MergeTree 表
3. 每个 consumer 是一个独立的 ClickHouse 线程，独立拉取 Kafka 的分区数据
4. `kafka_num_consumers` 不能超过 topic 的分区数，多余设置会被忽略

### Consumer 分配机制

```
Topic: user_events (4 partitions)

kafka_num_consumers = 4 时：
  Consumer-0 ← Partition-0
  Consumer-1 ← Partition-1
  Consumer-2 ← Partition-2
  Consumer-3 ← Partition-3

kafka_num_consumers = 2 时（自动分配）：
  Consumer-0 ← Partition-0, Partition-1
  Consumer-1 ← Partition-2, Partition-3

kafka_num_consumers = 6 时（多出的被忽略）：
  Consumer-0 ← Partition-0
  Consumer-1 ← Partition-1
  Consumer-2 ← Partition-2
  Consumer-3 ← Partition-3
  Consumer-4 ← 空闲（无分区可分配）
  Consumer-5 ← 空闲（无分区可分配）
```

## Consumer Group 与 Offset 管理

### Offset 存储位置

ClickHouse Kafka Engine 的 offset 可以存储在两种位置：

| 存储位置 | 配置方式 | 优点 | 缺点 |
|---------|---------|------|------|
| **Kafka 自身** (默认) | 不配置 `kafka_commit_on_select` | 符合 Kafka 标准语义，Kafka 侧可监控 lag | 依赖 Kafka 版本 |
| **ClickHouse Keeper** | 设置 `kafka_commit_on_select=1` + Keeper 路径 | ClickHouse 自管理，不依赖 Kafka 存储 | 增加 Keeper 存储压力 |

### Offset 提交时机

```sql
-- 方式 1：每次 SELECT 后提交（默认）
-- 缺点：高频 SELECT 场景下 Kafka 压力大
SETTINGS kafka_commit_on_select = 1;

-- 方式 2：手动控制提交（通过参数控制频率）
-- kafka_max_block_size 越大，每批处理越多消息，提交频率越低
SETTINGS
    kafka_max_block_size = 1048576,   -- 每批 1M 条
    kafka_poll_timeout_ms = 100,      -- 拉取超时 100ms
    kafka_flush_interval_ms = 7500;   -- 每 7.5 秒 flush 一次

-- 手动重置 offset（从最早开始重新消费）
-- 删除 consumer group offset 后重连
-- kafka-consumer-groups --bootstrap-server kafka1:9092 \
--   --group ch_consumer_group --topic user_events --reset-offsets --to-earliest --execute
```

### Commit 与 Exactly-Once 的关系

offset 提交和消息处理不是原子操作，存在以下风险：

```
时间线：
  T1: 从 Kafka 拉取消息 1-1000
  T2: 通过 MV 写入 MergeTree（成功）
  T3: 提交 offset = 1000（成功）
  
  如果 T2 成功但 T3 失败：
  → 重启后会从旧 offset 重新消费 → 消息 1-1000 被重复写入 → **数据重复**

  如果 T2 失败但 T3 成功（极端情况）：
  → offset 提交到 1000 但数据没写入 → **数据丢失**
```

**解决方式**：详见下文"Exactly-Once 语义实现"章节。

## 数据格式与解析

### 支持的数据格式

| 格式 | 适用场景 | 性能 | Schema 要求 |
|------|---------|------|-------------|
| **JSONEachRow** | 通用日志、API 事件 | 中等 | 列名需与 Kafka 消息字段一致 |
| **CSV** | 结构化导出数据 | 高 | 顺序匹配列定义 |
| **Avro** | Schema Registry 管理、大数据生态 | 高 | 需要 Schema Registry |
| **AvroConfluent** | Confluent Schema Registry | 高 | Confluent 格式头部 |
| **Protobuf** | gRPC 生态、高性能场景 | 最高 | 需要 .proto 定义 |
| **RawBLOB** | 二进制数据 | 最高 | 单列 String |
| **TSKV** | 键值对格式 | 低 | 自动解析 |

### JSONEachRow 深度配置

```sql
-- 基础配置
CREATE TABLE kafka_json (
    event_time DateTime,
    user_id UInt64,
    event_type String,
    properties Map(String, String)  -- 动态字段
) ENGINE = Kafka
SETTINGS
    kafka_format = 'JSONEachRow',
    -- 跳过未知字段（新增字段不报错）
    input_format_skip_unknown_fields = 1,
    -- 解析嵌套 JSON
    input_format_import_nested_json = 1;
```

### Avro + Schema Registry

```sql
CREATE TABLE kafka_avro (
    event_time DateTime,
    user_id UInt64,
    event_type String
) ENGINE = Kafka
SETTINGS
    kafka_format = 'AvroConfluent',
    -- Schema Registry 地址
    format_avro_schema_registry_url = 'http://schema-registry:8081';
```

## 虚拟列（Virtual Columns）

Kafka Engine 提供了 5 个虚拟列，不需要在表结构声明，可直接查询：

| 虚拟列 | 类型 | 含义 | 典型用途 |
|--------|------|------|---------|
| `_topic` | String | 消息来源 topic | 多 topic 消费时区分来源 |
| `_key` | String | 消息 key | 用于去重、路由判断 |
| `_offset` | UInt64 | 消息在分区内的 offset | 去重主键、进度监控 |
| `_partition` | UInt64 | 消息所在分区号 | 分区级监控 |
| `_timestamp` | DateTime | 消息时间戳（可空） | 时间窗口过滤 |

```sql
-- 使用虚拟列的关键场景：多 topic 消费 + offset 去重
CREATE TABLE kafka_multi (
    _topic String,      -- 必须显式声明才能写入 MV（非 KV 存储时用 Nullable）
    _offset UInt64,
    _partition UInt64,
    payload String
) ENGINE = Kafka
SETTINGS
    kafka_broker_list = 'kafka1:9092',
    kafka_topic_list = 'events_app1,events_app2,events_app3',
    kafka_group_name = 'ch_multi_consumer',
    kafka_format = 'JSONAsString';  -- 原始 JSON 存入 payload

-- 目标表：用 _topic + _partition + _offset 做去重
CREATE TABLE events_dedup (
    topic String,
    partition UInt64,
    offset UInt64,
    payload String,
    ingest_time DateTime DEFAULT now()
) ENGINE = ReplacingMergeTree()
ORDER BY (topic, partition, offset);

CREATE MATERIALIZED VIEW kafka_multi_mv TO events_dedup
AS SELECT
    _topic AS topic,
    _partition AS partition,
    _offset AS offset,
    payload,
    now() AS ingest_time
FROM kafka_multi;
```

## Exactly-Once 语义实现

### 方法 1：ReplacingMergeTree + 虚拟列去重（推荐）

```sql
-- 利用 _topic + _partition + _offset 作为唯一标识
-- 每次重新消费时，相同 offset 的消息会被 ReplacingMergeTree 去重
CREATE TABLE events_exactly_once (
    topic String,
    partition UInt64,
    offset UInt64,
    event_time DateTime,
    user_id UInt64,
    event_type String,
    version DateTime DEFAULT now()  -- ReplacingMergeTree 的版本列
) ENGINE = ReplacingMergeTree(version)
ORDER BY (topic, partition, offset);
```

**去重原理**：
- 同一条 Kafka 消息在任何重试场景下 `(topic, partition, offset)` 不变
- `ReplacingMergeTree` 合并时保留 `version` 最大的行
- 即使消息被重复写入，最终数据只有一条

**局限性**：
- 去重发生在后台 Merge 时，不是即时去重
- 查询时必须使用 `FINAL` 或接受 `OPTIMIZE` 前的重复数据

### 方法 2：物化视图 + AggregatingMergeTree（推荐）

```sql
-- 使用 *State 函数，合并时自动去重
CREATE TABLE events_agg (
    event_date Date,
    user_id UInt64,
    event_count SimpleAggregateFunction(sum, UInt64)
) ENGINE = AggregatingMergeTree()
ORDER BY (event_date, user_id);

CREATE MATERIALIZED VIEW kafka_agg_mv TO events_agg
AS SELECT
    toDate(event_time) AS event_date,
    user_id,
    -- 每条消息计数 1，合并时 sum 自动累加
    -- 重复消息被合并为一条
    count() AS event_count
FROM kafka_queue
GROUP BY event_date, user_id;
```

### 方法 3：应用层去重

```sql
-- 在 INSERT 时使用 DISTINCT 或 GROUP BY 去重
CREATE MATERIALIZED VIEW kafka_app_dedup_mv TO target_table
AS SELECT DISTINCT  -- ClickHouse 支持 SELECT DISTINCT * 等效去重
    *
FROM kafka_queue;
```

## 多 Topic 消费

### 配置方式

```sql
-- 方式 1：逗号分隔（推荐）
kafka_topic_list = 'topic1,topic2,topic3'

-- 方式 2：通配符（Kafka 2.5+）
-- kafka_topic_list = 'events_*'

-- 方式 3：正则（需要设置 kafka_topic_list_regex）
-- kafka_topic_list_regex = 1
-- kafka_topic_list = 'events_.*'
```

### 多 Topic 的最佳实践

每个 topic 的数据结构必须相同（因为 Kafka Engine 表只有一套 schema）。如果不同 topic 数据结构不同，需要创建多个 Kafka Engine 表。

```sql
-- 正确做法：同 schema 放一个表
CREATE TABLE kafka_all_events (...) ENGINE = Kafka
SETTINGS kafka_topic_list = 'events_web,events_app,events_api';

-- 错误做法：不同 schema 放一个表
-- 不要这样！不同 topic 的 JSON 结构不同会导致解析错误
```

## 性能调优

### 核心参数

| 参数 | 默认值 | 建议值 | 说明 |
|------|--------|--------|------|
| `kafka_num_consumers` | 1 | `<= topic 分区数` | 最多等同于分区数，多了浪费 |
| `kafka_max_block_size` | 65536 | 1048576 | 每批拉取行数，大值提高吞吐 |
| `kafka_poll_timeout_ms` | 500 | 50-100 | 拉取超时，小值降低延迟 |
| `kafka_flush_interval_ms` | 7500 | 1000-3000 | Flush 间隔，小值降低延迟 |
| `kafka_max_wait_ms` | — | 100 | 等待消息的最大时间 |
| `stream_flush_interval_ms` | 7500 | 1000 | MV 写入目标表的 Flush 间隔 |
| `stream_poll_timeout_ms` | 500 | 50 | MV 拉取超时 |

### 吞吐 vs 延迟权衡

```
高吞吐配置（批处理场景，TB/天）：
  kafka_max_block_size = 4194304      -- 4M 行/批
  kafka_poll_timeout_ms = 200
  kafka_flush_interval_ms = 10000     -- 10 秒 flush
  kafka_num_consumers = partitions    -- 充分利用所有分区

低延迟配置（实时监控，秒级）：
  kafka_max_block_size = 65536        -- 小批量
  kafka_poll_timeout_ms = 10          -- 几近实时拉取
  kafka_flush_interval_ms = 100       -- 100ms flush
  stream_flush_interval_ms = 100
```

### 并行度规划

```
写入吞吐 = consumers × 每 Consumer 吞吐

场景：Topic 8 分区，单条 1KB，目标吞吐 50 MB/s
  - 每 Consumer 吞吐 ~15 MB/s（JSONEachRow 解析瓶颈）
  - 需要 consumers >= ceil(50/15) = 4
  - kafka_num_consumers = 4（< 8 分区，合理）
```

## 故障恢复与 Rebalancing

### Consumer Rebalancing 触发条件

1. 新增 ClickHouse 节点（分布式表场景）
2. Topic 分区数变更
3. Consumer 超时未发送心跳（`session.timeout.ms`）
4. DETACH/ATTACH Kafka Engine 表

### 常见故障场景与恢复

| 场景 | 症状 | 恢复方式 |
|------|------|---------|
| Consumer 宕机 | 部分分区停止消费 | Kafka 自动 rebalance，其他 consumer 接管 |
| Offset 丢失 | 从头开始重新消费（数据风暴） | 用 `auto.offset.reset=latest` 避免重新消费 |
| MV 写入失败 | 数据堆积在缓冲区 | 检查目标表（磁盘满、权限变更、列类型不匹配） |
| 数据重复 | Rebalancing 后消息重复写入 | 使用 ReplacingMergeTree + offset 虚拟列去重 |

### 监控关键指标

```sql
-- Kafka Engine 表的数据积压（缓冲区行数）
SELECT
    database, table,
    total_rows,
    total_bytes,
    formatReadableSize(total_bytes) AS size_str
FROM system.tables
WHERE engine = 'Kafka';

-- 查看当前 Kafka consumer 配置
SELECT *
FROM system.kafka_consumers
WHERE table = 'kafka_queue';
```

## 常见反模式与排查

| 反模式 | 现象 | 正确做法 |
|--------|------|---------|
| **没有物化视图** | Kafka Engine 表 SELECT 越来越慢 | 必须通过 MV 将数据写入 MergeTree |
| **kafka_num_consumers > 分区数** | 多余的 consumer 永远空闲 | 设置为分区数的 0.5-1 倍 |
| **所有 topic 放一个表** | schema 不同导致解析报错 | 不同 schema 用多个 Kafka Engine 表 |
| **频繁 DETACH/ATTACH** | 每次都触发 rebalance | 用 SYSTEM RELOAD DICTIONARY 或重启服务 |
| **忽略 JSON 字段变更** | 新增字段导致 "Unknown field" 错误 | 设置 `input_format_skip_unknown_fields=1` |
| **offset 存 Keeper 不备份** | Keeper 故障后 offset 丢失 | 定期备份 Keeper 或使用 Kafka 自身 offset 存储 |
| **不设 TTL** | Keeper 历史 offset 无限增长 | Kafka 侧设置 `offsets.retention.minutes` |

### 排查思路

```
Kafka 数据不入 ClickHouse？
  ├── 检查 consumer group lag（kafka-consumer-groups --describe）
  ├── 检查 kafka_queue 表的 total_rows（system.tables）
  ├── 检查 MV 状态：SELECT * FROM system.materialized_views
  ├── 检查 error log：SELECT * FROM system.text_log WHERE level='Error'
  └── 检查目标表是否有写入权限
```

## 相关文档

- [点击前往集成引擎基础](./01_integration_engines.sql) —— File/S3/MySQL/PostgreSQL/JDBC 等其他集成引擎
- [点击前往 Flink 实时集成](./04_flink_architecture.md) —— Flink 作为 Kafka 消费者的替代方案
- [点击前往 Flink CH Sink](./05_flink_clickhouse_sink.sql) —— Flink → Kafka → ClickHouse 完整链路
- [点击前往 08-performance（性能优化）](../08-performance/README.md) —— MERGE 性能与 Kafka 摄入速率的关系
- [ClickHouse Kafka Engine 官方文档](https://clickhouse.com/docs/en/engines/table-engines/integrations/kafka)
