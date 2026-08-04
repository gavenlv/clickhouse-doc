# 07 - 数据层间流转：ODS → DWD → DWS → ADS

> **本章定位**：02 章定义了"四层长什么样",本章回答"**数据怎么从这一层流到下一层**"。重点讲清三种流转模式(Flink Job / 物化视图 / 调度任务)、每种模式的取舍、代码模板,以及常见的数据异常处理。

## 7.1 层间流转全景

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         四层数据流转全景                                      │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   源系统        ┌─────┐      ┌─────┐      ┌─────┐      ┌─────┐    看板    │
│  ┌────────┐    │ ODS │      │ DWD │      │ DWS │      │ ADS │   ┌──────┐ │
│  │ MySQL  │    │ 原始 │─────►│ 明细 │─────►│ 汇总 │─────►│ 应用 │──►│Spset│ │
│  │ Binlog │───►│     │      │     │      │     │      │     │   └──────┘ │
│  └────────┘    └──┬──┘      └──┬──┘      └──┬──┘      └──┬──┘           │
│                  │            │            │            │                 │
│                  ▼            ▼            ▼            ▼                 │
│              [模式A]      [模式A/B]     [模式B/C]     [模式C/D]             │
│              Flink CDC    Flink Job    物化视图      普通视图               │
│                                                                             │
│   流转模式分布:                                                           │
│   模式A (Flink Job)    : ODS → DWD  (必须 Flink)                          │
│   模式B (物化视图)     : DWD → DWS  (ClickHouse 内部完成)                  │
│   模式C (Flink Job)    : DWD → DWS  (复杂聚合用 Flink)                    │
│   模式D (普通视图)     : DWS → ADS  (ClickHouse 视图)                      │
│   模式E (Flink Job)    : DWS → ADS  (跨域聚合用 Flink)                    │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

## 7.2 三种流转模式选型

| 流转模式 | 实现机制 | 延迟 | 适用场景 | 优点 | 缺点 |
|---------|---------|------|---------|------|------|
| **Flink Job** | Flink 实时消费 + 写入 | 秒级 | 复杂清洗、跨域 JOIN、自定义逻辑 | 灵活、Exactly-Once | 运维复杂、需维护作业 |
| **ClickHouse 物化视图** | 写入时自动触发 | < 1s | 简单聚合、固定维度 | 零运维、自动增量 | 灵活性差、改定义难 |
| **普通视图** | 查询时计算 | 实时 | 看板数据量小、维度灵活 | 灵活、零成本 | 大数据量下慢 |
| **调度任务** | Airflow 定时跑 | 分钟~小时 | 离线补数、T+1 报表 | 简单、可靠 | 不实时 |

**选型决策树**：

```
需要从 X 层流转到 Y 层?
│
├─ 是否需要复杂业务逻辑(清洗/关联/计算)?
│   ├─ 是 → Flink Job
│   └─ 否 → 是否高频聚合(>10 QPS)?
│       ├─ 是 → ClickHouse 物化视图
│       └─ 否 → 普通视图
│
└─ 跨层(DWS→ADS)的看板,数据量大?
    ├─ 是 → 物化视图(预聚合到 ADS)
    └─ 否 → 普通视图(直接 DWS)
```

## 7.3 模式 A: ODS → DWD (Flink Job)

### 7.3.1 流转内容

```
┌──────────────────────────────────────────────────────────┐
│              ODS → DWD 流转任务                              │
├──────────────────────────────────────────────────────────┤
│                                                          │
│  源: ods_order (原始 Binlog)                              │
│  目标: dwd_order (清洗后的明细)                            │
│                                                          │
│  流转内容:                                               │
│    1. 数据清洗                                              │
│       - 过滤空值/无效记录                                    │
│       - 字段标准化(状态枚举、时间格式)                        │
│       - 异常值处理(amount < 0 → 0)                          │
│                                                          │
│    2. 维表关联                                              │
│       - 关联 dim_user → user_tier, user_age_group         │
│       - 关联 dim_product → product_category, product_brand │
│       - 关联 dim_region → region_name                      │
│                                                          │
│    3. 字段重命名                                            │
│       - ods_order_id → order_id                            │
│       - ods_amount → order_amount                          │
│                                                          │
│    4. 业务字段补充                                          │
│       - 计算是否新用户                                       │
│       - 计算是否首单                                         │
│       - 补充业务标签                                         │
│                                                          │
└──────────────────────────────────────────────────────────┘
```

### 7.3.2 Flink Job 完整代码

```java
/**
 * ODS → DWD 实时清洗任务
 * 
 * 数据流:
 *   Kafka(ods_topic) → Flink → 清洗 → 维表关联 → ClickHouse(dwd_order)
 * 
 * Exactly-Once 保证:
 *   1. Kafka Source: 开启 Checkpoint,自动管理 offset
 *   2. 维表关联: 使用 Async IO + 缓存,失败重试
 *   3. ClickHouse Sink: 批量 + 两阶段提交
 */
public class OdsToDwdOrderJob {

    public static void main(String[] args) throws Exception {
        StreamExecutionEnvironment env = StreamExecutionEnvironment.getExecutionEnvironment();
        env.enableCheckpointing(60000);  // 60 秒 Checkpoint
        env.setParallelism(8);

        // ============ 1. Kafka 源 (ODS 原始数据) ============
        KafkaSource<String> kafkaSource = KafkaSource.<String>builder()
            .setBootstrapServers("kafka:9092")
            .setGroupId("flink-ods-to-dwd-order")
            .setTopics("ods_order_cdc")
            .setStartingOffsets(OffsetsInitializer.committedOffsets())
            .setValueOnlyDeserializer(new SimpleStringSchema())
            .build();

        DataStream<String> rawStream = env.fromSource(kafkaSource,
            WatermarkStrategy.<String>forBoundedOutOfOrderness(Duration.ofSeconds(5))
                .withTimestampAssigner((json, ts) -> extractTs(json)),
            "Kafka ODS Source");

        // ============ 2. 解析 + 清洗 ============
        DataStream<OdsOrderEvent> parsedStream = rawStream
            .map(json -> parseOdsEvent(json))  // JSON → OdsOrderEvent
            .name("Parse JSON")
            .filter(Objects::nonNull)
            .name("Filter Null");

        // 3. 数据质量过滤
        DataStream<OdsOrderEvent> cleanStream = parsedStream
            .filter(event -> isValid(event))  // 业务校验
            .name("Data Quality Filter");

        // ============ 4. 维表关联(异步 IO) ============
        DataStream<DwdOrderEvent> enrichedStream = AsyncDataStream.unorderedWait(
            cleanStream,
            new UserDimensionAsyncFunction(),      // 关联 dim_user
            5000, TimeUnit.MILLISECONDS,            // 超时 5 秒
            1000                                    // 并发请求数
        ).name("Async Join dim_user");

        // ============ 5. 写入 DWD (ClickHouse) ============
        enrichedStream.addSink(buildDwdSink())
            .setParallelism(8)
            .name("ClickHouse DWD Sink");

        env.execute("ODS to DWD Order Job");
    }

    /**
     * 维表异步关联(用 HBase 存维表)
     */
    public static class UserDimensionAsyncFunction 
        extends RichAsyncFunction<OdsOrderEvent, DwdOrderEvent> {
        
        private transient Connection hbaseConn;
        private transient Cache<Long, UserDim> cache;  // 缓存热点用户

        @Override
        public void open(Configuration parameters) {
            // 初始化 HBase 连接 + Caffeine 缓存
            cache = Caffeine.newBuilder()
                .maximumSize(100_000)
                .expireAfterWrite(10, TimeUnit.MINUTES)
                .build();
        }

        @Override
        public void asyncInvoke(OdsOrderEvent event, 
                                ResultFuture<DwdOrderEvent> resultFuture) {
            // 1. 先查缓存
            UserDim user = cache.getIfPresent(event.getUserId());
            if (user == null) {
                // 2. 缓存未命中,异步查 HBase
                CompletableFuture.supplyAsync(() -> queryHbase(event.getUserId()))
                    .thenAccept(userFromHbase -> {
                        if (userFromHbase != null) {
                            cache.put(event.getUserId(), userFromHbase);
                        }
                        resultFuture.complete(Collections.singleton(
                            enrich(event, userFromHbase)
                        ));
                    });
            } else {
                resultFuture.complete(Collections.singleton(
                    enrich(event, user)
                ));
            }
        }
    }

    /**
     * DWD ClickHouse Sink (批量 + 重试)
     */
    private static SinkFunction<DwdOrderEvent> buildDwdSink() {
        return ClickHouseSink.<DwdOrderEvent>builder()
            .setUrls(new String[]{"jdbc:clickhouse://clickhouse1:8123,clickhouse2:8123/realtime_olap"})
            .setUsername("default")
            .setPassword("password")
            .setBatchSize(5000)
            .setFlushInterval(Duration.ofMillis(1000))
            .setMapper((event, stmt) -> {
                stmt.setString(1, event.getOrderId());
                stmt.setLong(2, event.getUserId());
                stmt.setBigDecimal(3, event.getOrderAmount());
                // ... 其他字段
                stmt.setTimestamp(4, Timestamp.valueOf(event.getOrderTime()));
            })
            .build();
    }
}
```

**为什么这样设计？**

| 设计点 | 选择 | 原因 |
|--------|------|------|
| 维表存储 | HBase / Redis | 千万级维表,Flink 端 O(1) 查询,避免全量加载到内存 |
| 关联方式 | Async IO | 同步查询 RT 100ms × 100 万 = 几小时;异步 1000 并发 = 几秒 |
| 维表缓存 | Caffeine 10 分钟 | 80% 查询命中缓存(热点用户),大幅降低 HBase 压力 |
| ClickHouse 写入 | 批量 5000 | 写入性能与 batch 强相关(见 03 章) |
| Checkpoint | 60 秒 | 保证 Exactly-Once,失败可恢复 |

### 7.3.3 ODS → DWD 的关键细节

**细节 1: 幂等写入(Exactly-Once)**

```
场景: Flink 作业重启,可能重写已处理的数据

解决方案: 
  - DWD 表用 ReplacingMergeTree(version_column)
  - Flink 写入时携带 etl_time 作为版本
  - 重复数据靠 ClickHouse 后台合并去重
```

**细节 2: 乱序处理**

```
场景: Kafka 分区数据可能乱序到达

解决:
  - 设置 Watermark(容忍 5 秒乱序)
  - 维表关联用最新数据(非时间窗口)
  - DWD 表按 order_time 分区,允许后到的数据补写
```

**细节 3: 维表变更感知**

```
场景: 用户等级变更,需要同步到 DWD

解决:
  - 维表变更发 Kafka 消息(CDC)
  - Flink 消费维表变更,广播到所有 TaskManager
  - 触发对应 DWD 记录的更新(ReplacingMergeTree 自动去重)
```

## 7.4 模式 B: DWD → DWS (物化视图 + Flink 二选一)

### 7.4.1 方案 1: ClickHouse 物化视图(推荐)

**适用**：简单聚合(无跨域、无复杂逻辑)

**原理**：

```
┌──────────────────────────────────────────────────────────┐
│                  物化视图原理                                │
├──────────────────────────────────────────────────────────┤
│                                                          │
│  写入 dwd_order                                           │
│      │                                                   │
│      ▼                                                   │
│  ClickHouse 内部触发                                       │
│      │                                                   │
│      ▼                                                   │
│  按物化视图 SQL 增量计算                                    │
│      │                                                   │
│      ▼                                                   │
│  写入 dws_user_order_day                                  │
│                                                          │
│  Why 不用 Flink 写 DWS?                                   │
│    - 简单聚合(订单数、GMV)ClickHouse 自己就行              │
│    - 写入即计算,延迟 < 1 秒                                │
│    - 省一个 Flink 作业,降低运维成本                        │
│                                                          │
│  何时必须用 Flink?                                        │
│    - 跨域 JOIN(如订单 + 用户画像)                          │
│    - 复杂窗口(滚动 24h、滑动窗口)                          │
│    - 自定义 UDF                                            │
│                                                          │
└──────────────────────────────────────────────────────────┘
```

**完整 DDL 模板**：

```sql
-- 1. DWS 目标表
CREATE TABLE IF NOT EXISTS realtime_olap.dws_user_order_1d ON CLUSTER 'treasurycluster' (
    dt                 Date,
    user_id            UInt64,
    user_tier          LowCardinality(String),
    
    order_cnt          SimpleAggregateFunction(sum,  UInt32),
    pay_cnt            SimpleAggregateFunction(sum,  UInt32),
    gmv                SimpleAggregateFunction(sum,  Decimal(18, 2)),
    pay_amount         SimpleAggregateFunction(sum,  Decimal(18, 2))
) ENGINE = ReplicatedAggregatingMergeTree(
    '/clickhouse/tables/{shard}/realtime_olap/dws_user_order_1d', '{replica}'
)
PARTITION BY toYYYYMM(dt)
ORDER BY (dt, user_tier, user_id);

-- 2. 物化视图(从 DWD 自动聚合)
CREATE MATERIALIZED VIEW IF NOT EXISTS realtime_olap.mv_dws_user_order_1d
ON CLUSTER 'treasurycluster'
TO realtime_olap.dws_user_order_1d AS
SELECT
    toDate(order_time)                          AS dt,
    user_id,
    user_tier,
    
    sumSimpleState(1)                            AS order_cnt,
    sumSimpleState(if(order_status IN ('paid','shipped','completed'), 1, 0)) AS pay_cnt,
    sumSimpleState(order_amount)                 AS gmv,
    sumSimpleState(pay_amount)                   AS pay_amount
FROM realtime_olap.dwd_order
WHERE is_valid = 1
GROUP BY dt, user_id, user_tier;

-- 3. 查询时(自动用最新状态)
SELECT
    user_tier,
    sum(order_cnt) AS total_orders,
    sum(gmv) AS total_gmv
FROM realtime_olap.dws_user_order_1d
WHERE dt >= today() - INTERVAL 7 DAY
GROUP BY user_tier;
```

**Why 物化视图能实现"实时"？**

| 维度 | 物化视图 | Flink 写 DWS |
|------|---------|---------------|
| 延迟 | < 1 秒(DWD 写入后立即触发) | 1-5 秒(取决于窗口) |
| 资源消耗 | ClickHouse 内部计算 | 额外 Flink 资源 |
| 运维 | 零运维(只维护 DDL) | 需维护 Flink 作业 |
| Exactly-Once | ClickHouse 内部保证 | 需配置两阶段提交 |
| 灵活性 | 改 DDL 麻烦 | 改代码灵活 |

**结论**：**80% 场景用物化视图,20% 复杂场景用 Flink**。

### 7.4.2 方案 2: Flink 写 DWS(复杂聚合场景)

**适用**：
- 跨域 JOIN(订单 + 用户画像 + 商品标签)
- 复杂窗口(滚动、滑动、会话窗口)
- 自定义 UDF

**完整代码**：

```java
/**
 * DWD → DWS 实时聚合任务(复杂场景)
 * 
 * 场景: 用户日汇总(订单域 + 行为域 合并)
 *   - 订单域: 下单数、GMV
 *   - 行为域: 浏览数、加购数(来自另一个 Kafka topic)
 * 
 * Why 不用物化视图?
 *   - 跨 topic 合并,物化视图只能基于单表
 *   - 行为数据有去重要求(uniq user_id)
 */
public class DwdToDwsUserDayJob {

    public static void main(String[] args) throws Exception {
        StreamExecutionEnvironment env = StreamExecutionEnvironment.getExecutionEnvironment();
        env.enableCheckpointing(60000);
        env.setParallelism(4);

        // ============ 1. 订单流(来自 DWD Kafka topic) ============
        DataStream<OrderEvent> orderStream = env
            .fromSource(buildOrderSource(), buildWatermarkStrategy(), "Order Source")
            .keyBy(OrderEvent::getUserId);

        // ============ 2. 行为流(来自行为 DWD) ============
        DataStream<BehaviorEvent> behaviorStream = env
            .fromSource(buildBehaviorSource(), buildWatermarkStrategy(), "Behavior Source")
            .keyBy(BehaviorEvent::getUserId);

        // ============ 3. 双流 Connect + 窗口聚合 ============
        // 关键: 用 TumblingEventTimeWindow(天级窗口)
        DataStream<UserDayAgg> dwsStream = orderStream
            .connect(behaviorStream)
            .process(new CoProcessFunction<OrderEvent, BehaviorEvent, UserDayAgg>() {
                // 状态: 累积当天的订单和行为数据
                private transient ValueState<OrderAccumulator> orderState;
                private transient ValueState<BehaviorAccumulator> behaviorState;
                // ... 略
            })
            .keyBy(UserDayAgg::getUserId)
            .window(TumblingEventTimeWindows.of(Time.days(1)))
            .aggregate(new UserDayAggregate(), new UserDayWindowFunction())
            .name("DWS Daily Aggregate");

        // ============ 4. 写入 ClickHouse DWS 表 ============
        dwsStream.addSink(buildDwsSink())
            .setParallelism(4)
            .name("ClickHouse DWS Sink");

        env.execute("DWD to DWS User Day Job");
    }
}
```

### 7.4.3 物化视图的"隐性陷阱"

**陷阱 1：聚合状态膨胀**

```
场景: dws_user_order_1d 按 (dt, user_id, user_tier) 聚合
      1 亿用户 × 365 天 = 365 亿行

问题: 
  - 存储 365 亿行 → 10+ TB
  - 物化视图合并时 IO 巨大
  - 写入性能下降

解决:
  - 加 TTL: 超过 90 天的数据 DROP PARTITION
  - 降粒度: 改为用户 × 周(52 行/用户)
  - 抽样: 物化视图只聚合 10% 样本
```

**陷阱 2：UNIQ 不能简单聚合**

```sql
-- 错误: 多个物化视图合并时,uniq 结果会重复
CREATE MATERIALIZED VIEW mv_user_visit_day AS
SELECT dt, user_id, uniqState(session_id) AS visit_cnt
FROM events GROUP BY dt, user_id;

-- 问题: 同一个 session 被分到多个 partition,uniq 重复计数

-- 解决: 用 uniqCombined 或 提前去重
CREATE MATERIALIZED VIEW mv_user_visit_day AS
SELECT dt, user_id, uniqCombinedState(session_id) AS visit_cnt
FROM (
    SELECT DISTINCT dt, user_id, session_id FROM events
) GROUP BY dt, user_id;
```

**陷阱 3：物化视图改 DDL 很麻烦**

```
错误: CREATE OR REPLACE MATERIALIZED VIEW ...
      ClickHouse 不支持修改已存在的物化视图

正确流程:
  1. DETACH MATERIALIZED VIEW mv_old
  2. 修改 DDL
  3. CREATE MATERIALIZED VIEW mv_new AS ...
  4. 测试
  5. DROP MATERIALIZED VIEW mv_old

替代方案: 直接删了重建(数据可从 DWD 重算)
```

## 7.5 模式 C/D: DWS → ADS (看板数据准备)

### 7.5.1 两种方式

**方式 1: 视图(轻量、灵活)**

```sql
-- 实时 GMV 看板(直接查 DWS)
CREATE VIEW IF NOT EXISTS realtime_olap.ads_gmv_dashboard ON CLUSTER 'treasurycluster' AS
SELECT
    toStartOfHour(dt)        AS hour,
    region_code,
    product_category,
    
    sum(order_cnt)           AS order_cnt,
    sum(pay_amount)          AS gmv,
    uniq(user_id)            AS pay_user_cnt  -- DWS 是明细,这里再聚合
FROM realtime_olap.dws_user_order_1d
WHERE dt >= today() - INTERVAL 30 DAY
GROUP BY hour, region_code, product_category;
```

**适用**：看板刷新频率低(< 1 分钟)、数据量适中

**方式 2: 物化视图(性能优先)**

```sql
-- 高频看板的 ADS 物化视图
CREATE TABLE IF NOT EXISTS realtime_olap.ads_realtime_gmv ON CLUSTER 'treasurycluster' (
    minute         DateTime,
    region_code    LowCardinality(String),
    
    gmv            SimpleAggregateFunction(sum,  Decimal(18, 2)),
    order_cnt      SimpleAggregateFunction(sum,  UInt32)
) ENGINE = ReplicatedAggregatingMergeTree(
    '/clickhouse/tables/{shard}/realtime_olap/ads_realtime_gmv', '{replica}'
)
PARTITION BY toYYYYMM(minute)
ORDER BY (minute, region_code);

CREATE MATERIALIZED VIEW IF NOT EXISTS realtime_olap.mv_ads_realtime_gmv
ON CLUSTER 'treasurycluster'
TO realtime_olap.ads_realtime_gmv AS
SELECT
    toStartOfMinute(order_time)              AS minute,
    region_code,
    
    sumSimpleState(order_amount)             AS gmv,
    sumSimpleState(1)                         AS order_cnt
FROM realtime_olap.dwd_order
WHERE order_time >= now() - INTERVAL 1 DAY  -- 滑动窗口
GROUP BY minute, region_code;
```

**适用**：实时大屏、看板刷新频率高(秒级)

### 7.5.2 关键设计原则

**原则 1: ADS 一个看板 = 一张表**

```
错误: 一个 ADS 视图服务多个看板
  - 看板 A 改 SQL,看板 B 跟着变
  - 看板 A 加字段,看板 B 查询变慢

正确: 一个看板 = 一张独立的 ADS 表/视图
  - 看板间互不影响
  - 性能单独优化
```

**原则 2: 看板数据"近详远略"**

```
最近 7 天  : 物化视图(明细)     - 供下钻分析
最近 30 天 : 物化视图(汇总)     - 供趋势分析
最近 1 年  : 物化视图(月汇总)   - 供长期分析
历史       : 离线归档            - 不服务看板
```

**原则 3: 看板不直接查 DWD**

```
错误: Superset 直接查 dwd_order
  - 数据量大(亿级)
  - 看板响应慢
  - 影响其他查询

正确: Superset 查 ADS(物化视图)
  - 预聚合后数据量小
  - 响应快
  - 不影响 DWD
```

## 7.6 跨层流转的一致性保证

### 7.6.1 三种一致性级别

```
┌──────────────────────────────────────────────────────────┐
│              数据流转一致性级别                              │
├──────────────────────────────────────────────────────────┤
│                                                          │
│  级别 1: At-Most-Once(最多一次)                            │
│    - 数据可能丢(失败不重试)                                 │
│    - 适用: 日志采集、可容忍少量丢失                          │
│                                                          │
│  级别 2: At-Least-Once(至少一次)                           │
│    - 数据可能重复(失败重试)                                 │
│    - 适用: 大部分业务场景                                   │
│    - 需配合下游去重(ReplacingMergeTree)                     │
│                                                          │
│  级别 3: Exactly-Once(精确一次)                            │
│    - 数据不丢不重                                          │
│    - 实现: Flink Checkpoint + 两阶段提交                    │
│    - 适用: 金融、对账等强一致场景                            │
│                                                          │
│  90% 业务用 At-Least-Once + 下游去重 就够了                │
│                                                          │
└──────────────────────────────────────────────────────────┘
```

### 7.6.2 Exactly-Once 的实现机制

```java
/**
 * Flink → ClickHouse Exactly-Once 实现
 * 
 * 关键: 两阶段提交
 *   1. Pre-Commit: Flink 准备提交时,先在 ClickHouse 写入预提交标记
 *   2. Checkpoint 成功: 标记为已提交
 *   3. Checkpoint 失败: 丢弃预提交数据
 * 
 * 实现:
 *   - ClickHouseSink 实现 TwoPhaseCommitSinkFunction
 *   - 预提交: 写入临时 buffer
 *   - 提交: 真正写入 ClickHouse
 */
public class ExactlyOnceClickHouseSink 
    extends TwoPhaseCommitSinkFunction<DwdOrderEvent, Connection, Void> {
    
    @Override
    protected void invoke(Connection transaction, DwdOrderEvent event, Context ctx) 
        throws Exception {
        // 预提交: 写入 ClickHouse 临时表
        PreparedStatement stmt = transaction.prepareStatement(
            "INSERT INTO dwd_order_buffer VALUES (?, ?, ...)"
        );
        // ... 绑定参数
        stmt.executeUpdate();
    }
    
    @Override
    protected void preCommit(Connection transaction) throws Exception {
        // 预提交: 等待 Checkpoint 确认
        transaction.commit();
    }
    
    @Override
    protected void commit(Connection transaction) {
        // 真正提交: 把 buffer 数据移到正式表
        // 这里需要额外逻辑: ATOMIC INSERT ... SELECT
    }
    
    @Override
    protected void abort(Connection transaction) {
        // 失败回滚: 清空 buffer
        try {
            transaction.rollback();
        } catch (SQLException e) {
            // log
        }
    }
}
```

**重要：ClickHouse 的 Exactly-Once 限制**

```
⚠️ ClickHouse 原生不擅长 Exactly-Once:
   - 没有 UNDO LOG
   - 没有行级锁
   - 一旦 INSERT,数据就在

实用方案: At-Least-Once + 幂等去重
   1. DWD 表用 ReplacingMergeTree(etl_time)
   2. Flink 端给每条数据生成唯一 ID
   3. 重复数据靠 ClickHouse 后台合并去重
   4. 查询时用 FINAL 强制去重(慎用,影响性能)

99% 场景: 业务可容忍分钟级重复
   - GMV 看板多算 100 元,没人在意
   - 用 ReplacingMergeTree 已足够
```

### 7.6.3 跨层对账(发现不一致)

```sql
-- 每日对账:ODS → DWD 行数对比
SELECT
    toDate(ods_ingest_time)  AS dt,
    count()                   AS ods_count,
    countDistinct(ods_order_id) AS ods_unique
FROM realtime_olap.ods_order
WHERE ods_ingest_time >= today() - INTERVAL 1 DAY
GROUP BY dt;

-- 每日对账:DWD → DWS 聚合对比
SELECT
    dt,
    sum(order_cnt) AS dws_total_cnt,
    count()         AS dws_user_count,
    -- 对比: DWD 实际订单数
    (SELECT count() FROM realtime_olap.dwd_order 
     WHERE toDate(order_time) = dt AND is_valid = 1) AS dwd_actual_cnt
FROM realtime_olap.dws_user_order_1d
WHERE dt >= today() - INTERVAL 1 DAY
GROUP BY dt;
```

**对账机制**：
- 每日凌晨跑对账 SQL
- ODS count == DWD count(允许 ±1% 误差)
- 超过阈值 → 告警 → 人工介入

## 7.7 异常数据处理

### 7.7.1 异常数据分类

```
┌──────────────────────────────────────────────────────────┐
│                异常数据分类                                 │
├──────────────────────────────────────────────────────────┤
│                                                          │
│  1. 字段缺失: 必填字段为 NULL                                │
│  2. 字段超限: 金额负数、ID 超过类型范围                      │
│  3. 业务异常: 订单状态机跳转错误                             │
│  4. 时间异常: 未来时间、乱序严重                              │
│  5. 重复数据: 同一订单多次到达                               │
│  6. 数据倾斜: 某个 key 占比超过 50%                        │
│                                                          │
└──────────────────────────────────────────────────────────┘
```

### 7.7.2 处理策略

| 异常类型 | 处理策略 | 落地位置 |
|---------|---------|---------|
| 字段缺失 | 过滤掉(不进入 DWD) | ODS 写日志,丢弃 |
| 字段超限 | 修正后入库(如负数改 0) | ODS 写日志,修正后入库 DWD |
| 业务异常 | 单独存到 `dwd_order_invalid` | ODS 写日志,异常数据隔离 |
| 时间异常 | 时间超过 now() 丢弃 | ODS 写日志,丢弃 |
| 重复数据 | 依赖 ReplacingMergeTree 去重 | DWD 表自动处理 |
| 数据倾斜 | 加盐打散 | Flink 端处理 |

### 7.7.3 死信队列(DLQ)

```java
/**
 * 数据清洗时的死信处理
 * 
 * 流程:
 *   1. 正常数据 → 主流
 *   2. 异常数据 → DLQ 侧流
 *   3. 异常数据落 Kafka DLQ topic
 *   4. 人工/自动修复后回放
 */
DataStream<DwdOrderEvent> mainStream = parsedStream
    .process(new ProcessFunction<OdsOrderEvent, DwdOrderEvent>() {
        @Override
        public void processElement(OdsOrderEvent event, Context ctx, 
                                    Collector<DwdOrderEvent> out) {
            if (isValid(event)) {
                out.collect(toDwd(event));  // 主流
            } else {
                ctx.output(dlqTag, event);  // 侧流
            }
        }
    });

// 主流 → ClickHouse DWD
mainStream.addSink(buildDwdSink());

// 侧流 → Kafka DLQ
mainStream.getSideOutput(dlqTag).addSink(buildDlqSink());
```

**Why 需要 DLQ？**
- 不能直接丢弃异常数据(可能是上游 bug)
- DLQ 是"保险",出问题时可回放
- 监控 DLQ 数量,异常增长 = 上游有 bug

## 7.8 数据回溯与重算

### 7.8.1 场景

```
场景 1: 业务说"昨天的 GMV 算错了,用户等级字段映射有误"
  → 需要重算 DWS 昨天的数据

场景 2: 修复了 ETL 逻辑,需要回溯过去 7 天
  → 需要重算 DWD 近 7 天

场景 3: 上线了一个新指标,需要历史数据
  → 需要回溯 DWS/DWD 历史
```

### 7.8.2 回溯方案

```sql
-- ============ 方案 1: DROP PARTITION + 重新物化 ============

-- 1. 删除 DWS 目标分区
ALTER TABLE realtime_olap.dws_user_order_1d
DROP PARTITION '202606';

-- 2. 从 DWD 重新计算并插入
INSERT INTO realtime_olap.dws_user_order_1d
SELECT
    toDate(order_time)  AS dt,
    user_id,
    user_tier,
    sumSimpleState(1)   AS order_cnt,
    sumSimpleState(if(order_status = 'paid', 1, 0)) AS pay_cnt,
    sumSimpleState(order_amount)  AS gmv,
    sumSimpleState(pay_amount)    AS pay_amount
FROM realtime_olap.dwd_order
WHERE toDate(order_time) BETWEEN '2026-06-01' AND '2026-06-30'
  AND is_valid = 1
GROUP BY dt, user_id, user_tier;

-- ============ 方案 2: 用 INSERT SELECT + 物化视图触发 ============
-- 适用: 修改了物化视图 SQL,需要全量重算

-- 1. 删除物化视图
DROP VIEW IF EXISTS realtime_olap.mv_dws_user_order_1d ON CLUSTER 'treasurycluster';

-- 2. 重建物化视图(会自动从 DWD 增量同步)
CREATE MATERIALIZED VIEW realtime_olap.mv_dws_user_order_1d
ON CLUSTER 'treasurycluster'
TO realtime_olap.dws_user_order_1d AS
SELECT ...;
```

**回溯时的注意事项**：
- **回溯期间停止 Flink 写入**(避免并发冲突)
- **用专门的回溯作业**(避免影响生产)
- **分批回溯**(按天/按分区,避免 OOM)
- **回溯后对账**(确认数量一致)

## 7.9 全链路延迟分布

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                  端到端延迟分布(从数据产生到看板可见)                          │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  数据源 ──► Kafka ──► Flink Job ──► ClickHouse ──► 物化视图 ──► Superset  │
│   0ms      50ms       200ms         500ms          100ms        200ms       │
│   ├─────────┼─────────┼─────────────┼───────────────┼────────────┼─────────┤
│                                                                             │
│   端到端总延迟: ~ 1 秒 (P99)                                                  │
│                                                                             │
│  各环节占比:                                                                │
│    Kafka 传输:        5%                                                   │
│    Flink 处理:        20%                                                  │
│    ClickHouse 写入:   50%  (主瓶颈)                                         │
│    物化视图计算:       10%                                                  │
│    Superset 查询:     15%                                                  │
│                                                                             │
│  优化重点: 减小 ClickHouse 写入延迟(批量 + 异步)                            │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

## 7.10 流转过程的可观测性

### 7.10.1 每层埋点指标

```sql
-- ODS 层: 监控写入速率和延迟
SELECT
    toStartOfMinute(ods_ingest_time) AS minute,
    count()                            AS rows,
    uniqExact(ods_order_id)            AS unique_orders,
    -- 数据延迟: 源库变更时间 vs 入库时间
    max(ods_ingest_time - toDateTime64(ods_ts_ms/1000, 3)) AS max_lag
FROM realtime_olap.ods_order
WHERE ods_ingest_time >= now() - INTERVAL 1 HOUR
GROUP BY minute
ORDER BY minute DESC;
```

```sql
-- DWD 层: 监控转换率和质量
SELECT
    toStartOfMinute(etl_time)        AS minute,
    count()                            AS dwd_rows,
    -- 转换率
    countIf(is_valid = 1)              AS valid_rows,
    -- 异常率
    100 * countIf(is_valid = 0) / count() AS invalid_pct
FROM realtime_olap.dwd_order
WHERE etl_time >= now() - INTERVAL 1 HOUR
GROUP BY minute
ORDER BY minute DESC;
```

```sql
-- DWS 层: 监控聚合一致性
SELECT
    dt,
    -- 实际订单数
    (SELECT count() FROM realtime_olap.dwd_order 
     WHERE toDate(order_time) = dt AND is_valid = 1) AS actual_orders,
    -- DWS 聚合出的订单数
    sum(order_cnt)                                    AS aggregated_orders,
    -- 差异
    abs(actual_orders - aggregated_orders)            AS diff
FROM realtime_olap.dws_user_order_1d
WHERE dt >= today() - INTERVAL 7 DAY
GROUP BY dt
HAVING diff > 100;  -- 差异 > 100 告警
```

## 7.11 最佳实践 Checklist

```
┌──────────────────────────────────────────────────────────┐
│       层间流转 12 条最佳实践                                │
├──────────────────────────────────────────────────────────┤
│                                                          │
│  [数据流]                                                  │
│  □ ODS → DWD: 必须用 Flink(清洗逻辑复杂)                  │
│  □ DWD → DWS: 优先用物化视图,复杂场景用 Flink             │
│  □ DWS → ADS: 优先用视图,性能不够用物化视图                │
│  □ 跨域 JOIN: 用 Flink + 异步 IO                          │
│                                                          │
│  [延迟]                                                    │
│  □ 端到端 P99 < 10s                                        │
│  □ 单层 P99 < 2s                                          │
│  □ 物化视图触发延迟 < 1s                                   │
│                                                          │
│  [一致性]                                                  │
│  □ At-Least-Once + 幂等去重(默认)                         │
│  □ Exactly-Only 用 ReplacingMergeTree                     │
│  □ 跨层对账每日跑一次                                      │
│                                                          │
│  [异常处理]                                                │
│  □ 异常数据走 DLQ,不静默丢弃                              │
│  □ 数据质量校验在 Flink 端完成                             │
│  □ 死信队列数量监控                                        │
│                                                          │
│  [回溯]                                                    │
│  □ 支持按分区重算                                          │
│  □ 回溯用独立作业,不影响生产                              │
│  □ 回溯后自动对账                                          │
│                                                          │
└──────────────────────────────────────────────────────────┘
```

## 7.12 下一章

- [08_realtime_sla.md](./08_realtime_sla.md) - 实时性 SLA 与监控告警
- [05_optimization.md](./05_optimization.md) - 性能优化深入
- [06_best_practices.md](./06_best_practices.md) - 最佳实践
