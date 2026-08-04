-- ================================================================================
-- 20 - ClickHouse 分层建模（ODS/DWD/DWS/ADS）
-- ================================================================================
-- 
-- 集群: treasurycluster (2 副本)
-- 预计学习时间: 60 分钟
-- 
-- 本文件涵盖:
--   1. 分层建模理论 - 为什么需要 ODS/DWD/DWS/ADS 四层
--   2. ODS 原始层 - Flink CDC 直入,Schema-on-Read
--   3. DWD 明细层 - 清洗去重,业务过程清晰
--   4. DWS 汇总层 - 物化视图预聚合,跨域复用
--   5. ADS 应用层 - 面向看板的高度聚合
--   6. 字典表设计 - 维表关联优化
--   7. 物化视图 vs AggregatingMergeTree 选择
--   8. 分区键 / 排序键 / 主键设计原则
-- 
-- ┌─────────────────────────────────────────────────────────────────────────────┐
-- │                    ClickHouse 分层建模全景                                    │
-- ├─────────────────────────────────────────────────────────────────────────────┤
-- │                                                                             │
-- │   Flink CDC        Flink 实时           ClickHouse (存储)        Superset    │
-- │  ┌─────────┐     ┌──────────┐         ┌──────────────┐       ┌──────────┐  │
-- │  │ MySQL   │     │  Flink   │         │ ODS (原始)   │       │          │  │
-- │  │ Binlog  │────►│  Job     │────────►│ Replicated   │       │          │  │
-- │  └─────────┘     │          │         │ MergeTree    │       │          │  │
-- │                  │  清洗    │         └──────┬───────┘       │          │  │
-- │                  │  关联    │                │               │          │  │
-- │                  │  聚合    │                ▼               │          │  │
-- │                  │          │         ┌──────────────┐       │          │  │
-- │                  │          │         │ DWD (明细)   │       │  Dataset │  │
-- │                  │          │         │ Replicated   │       │  Chart   │  │
-- │                  │          │         │ MergeTree    │       │  Dashbrd │  │
-- │                  │          │         └──────┬───────┘       │          │  │
-- │                  │          │                │               │          │  │
-- │                  │          │                ▼               │          │  │
-- │                  │          │         ┌──────────────┐       │          │  │
-- │                  │          │         │ DWS (汇总)   │       │          │  │
-- │                  │          │         │ Aggregating  │       │          │  │
-- │                  │          │         │ MergeTree    │       │          │  │
-- │                  │          │         └──────┬───────┘       │          │  │
-- │                  │          │                │               │          │  │
-- │                  │          │                ▼               │          │  │
-- │                  │          │         ┌──────────────┐       │          │  │
-- │                  │          │         │ ADS (应用)   │       │          │  │
-- │                  │          │         │ Materialized │       │          │  │
-- │                  │          │         │ View         │       │          │  │
-- │                  │          │         └──────────────┘       └──────────┘  │
-- │                  └──────────┘                                              │
-- │                                                                             │
-- │   写入频率: 持续          查询频率: 看板触发                                  │
-- │   写入量: 100w/s        查询量: 100-1000 QPS                                │
-- │   延迟: 3-10s           响应: P99 < 2s                                     │
-- │                                                                             │
-- └─────────────────────────────────────────────────────────────────────────────┘
-- 
-- ⚠️ 重要原则:
--   1. 所有表必须使用 Replicated* 引擎 + ON CLUSTER
--   2. 所有表必须按时间分区 (PARTITION BY toYYYYMM(...) 或 toDate(...))
--   3. 排序键 (ORDER BY) 决定查询性能,必须按"高基数+高频过滤"原则
--   4. ODS 层 Schema 保持与上游一致,不要清洗(保留可回溯)
--   5. DWD 层是核心,所有下游都依赖它
-- 
-- 📌 进阶阅读:
--   本章定义"四层长什么样",但没讲"数据怎么流"。关于层间流转的细节:
--     - 07_data_flow_transition.md  - ODS/DWD/DWS/ADS 之间的流转模式(Flink Job / 物化视图 / 视图)
--     - 08_realtime_sla.md          - 实时性 SLA、监控告警、故障恢复
-- ================================================================================

-- ========================================
-- 0. 创建数据库
-- ========================================

CREATE DATABASE IF NOT EXISTS realtime_olap ON CLUSTER 'treasurycluster';

-- ========================================
-- 1. ODS 层 - 原始数据层
-- ========================================
-- 
-- 设计原则:
--   - Schema 与上游业务表完全一致(Schema-on-Read)
--   - 不做任何清洗、转换、过滤
--   - 保留原始时间戳(可回溯)
--   - 字段名加前缀 ods_ 避免与 DWD 冲突
-- 
-- 引擎选择: ReplicatedMergeTree
--   - 支持复制(2 副本)
--   - 支持 Merge(后台合并,提升压缩)
--   - Why 不用 Replacing: ODS 保留所有版本,包括更新
-- 
-- ========================================

-- 1.1 ODS 订单表 (Flink CDC 写入)
CREATE TABLE IF NOT EXISTS realtime_olap.ods_order ON CLUSTER 'treasurycluster' (
    -- 业务字段 (与 MySQL 一致)
    ods_id                UInt64,         -- 自增主键
    ods_order_id          String,         -- 订单号
    ods_user_id           UInt64,         -- 用户ID
    ods_product_id        UInt64,         -- 商品ID
    ods_amount            Decimal(18, 2), -- 金额
    ods_status            LowCardinality(String),  -- 订单状态
    ods_pay_method        LowCardinality(String),  -- 支付方式
    
    -- 维度字段(冗余存储,避免后续 JOIN)
    ods_user_tier         LowCardinality(String),  -- 用户等级
    ods_product_category  LowCardinality(String),  -- 商品类目
    ods_region            LowCardinality(String),  -- 地区
    
    -- CDC 元数据 (Flink 写入时填充)
    ods_op_type           LowCardinality(String),  -- c: insert, u: update, d: delete
    ods_db                String,                   -- 源库名
    ods_table             String,                   -- 源表名
    ods_ts_ms            Int64,                     -- 源库变更时间(ms)
    ods_ingest_time      DateTime DEFAULT now(),    -- 入库时间
    
    -- 索引版本(供 ReplacingMergeTree 去重)
    ods_sign              Int8 DEFAULT 1,           -- 1=有效, -1=删除
    ods_version           UInt64                    -- 递增版本号
) ENGINE = ReplicatedMergeTree(
    '/clickhouse/tables/{shard}/realtime_olap/ods_order',
    '{replica}'
)
PARTITION BY toYYYYMM(ods_ingest_time)
ORDER BY (ods_ingest_time, ods_order_id)
TTL toDate(ods_ingest_time) + INTERVAL 90 DAY  -- ODS 只保留 90 天
SETTINGS index_granularity = 8192;

-- Why 这套 ORDER BY?
--   1. ods_ingest_time 在前: 时间范围查询走分区裁剪
--   2. ods_order_id 在后: 单订单查询命中主键索引
--   3. 都不放 ods_user_id: 因为订单按订单号查询比按用户频繁 10x

-- ========================================
-- 2. DWD 层 - 数据明细层
-- ========================================
-- 
-- 设计原则:
--   - 一次清洗,永久受益
--   - 业务过程清晰(一个 DWD 表 = 一个业务实体)
--   - 字段标准化(命名规范、类型统一)
--   - 使用 ReplacingMergeTree 去重(基于版本号)
--   - 维度冗余(用户/商品/地区等常用维度直接拉平)
-- 
-- 引擎选择: ReplicatedReplacingMergeTree
--   - 支持 Upsert(去重 + 保留最新版本)
--   - Why 不用 Collapsing: Collapsing 需要严格配对 sign,易出错
--   - Why 不用 VersionedCollapsing: 已过时
-- 
-- ========================================

-- 2.1 DWD 订单明细表 (Flink 清洗后写入)
CREATE TABLE IF NOT EXISTS realtime_olap.dwd_order ON CLUSTER 'treasurycluster' (
    -- 主键
    order_id          String,
    
    -- 业务字段
    user_id           UInt64,
    product_id        UInt64,
    sku_id            String,
    order_amount      Decimal(18, 2),
    pay_amount        Decimal(18, 2),
    discount_amount   Decimal(18, 2),
    
    -- 订单状态(标准化)
    order_status      Enum8(
        'unknown'    = 0,
        'created'    = 1,
        'paid'       = 2,
        'shipped'    = 3,
        'completed'  = 4,
        'cancelled'  = 5,
        'refunded'   = 6
    ),
    pay_method        LowCardinality(String),
    
    -- 时间字段(标准化)
    order_time        DateTime,           -- 下单时间
    pay_time          Nullable(DateTime), -- 支付时间(可能为空)
    complete_time     Nullable(DateTime), -- 完成时间(可能为空)
    
    -- 维度冗余(避免后续 JOIN)
    user_tier         LowCardinality(String),
    user_age_group    LowCardinality(String),   -- 18-24, 25-30, ...
    product_category  LowCardinality(String),
    product_brand     LowCardinality(String),
    region_code       LowCardinality(String),
    channel           LowCardinality(String),  -- 渠道: APP/Web/小程序
    
    -- 数据质量
    is_valid          UInt8 DEFAULT 1,         -- 是否有效数据
    etl_time          DateTime DEFAULT now()
) ENGINE = ReplicatedReplacingMergeTree(
    '/clickhouse/tables/{shard}/realtime_olap/dwd_order',
    '{replica}',
    etl_time           -- 版本列,自动取最新
)
PARTITION BY toYYYYMM(order_time)
ORDER BY (order_time, user_id, order_id)
SETTINGS index_granularity = 8192;

-- Why 这套 ORDER BY?
--   1. order_time 在前: 99% 查询是"最近 7 天订单"等时间范围
--   2. user_id 在其次: 用户行为分析是高频场景
--   3. order_id 最后: 唯一键,保证唯一性

-- 2.2 DWD 订单明细表 - 配套字典
-- 
-- Why 字典表?
--   - 用户/商品等维表数据量大(千万级),不适合主表冗余
--   - 但 Superset 查询时经常需要 "用户昵称"、"商品名称"
--   - 方案: ClickHouse 字典 + dictGet 函数,O(1) 内存查询
-- 
CREATE TABLE IF NOT EXISTS realtime_olap.dict_user ON CLUSTER 'treasurycluster' (
    user_id        UInt64,
    user_name      String,
    user_tier      LowCardinality(String),
    user_age_group LowCardinality(String),
    register_time  DateTime,
    is_active      UInt8
) ENGINE = ReplicatedMergeTree(
    '/clickhouse/tables/{shard}/realtime_olap/dict_user',
    '{replica}'
)
ORDER BY user_id
SETTINGS index_granularity = 8192;

-- 创建字典(内存加速)
CREATE DICTIONARY IF NOT EXISTS realtime_olap.dict_user_dict ON CLUSTER 'treasurycluster' (
    user_id        UInt64,
    user_name      String DEFAULT '',
    user_tier      String DEFAULT 'unknown',
    user_age_group String DEFAULT 'unknown'
) PRIMARY KEY user_id
SOURCE(CLICKHOUSE(DB 'realtime_olap' TABLE 'dict_user'))
LIFETIME(MIN 300 MAX 600)  -- 5-10 分钟刷新
LAYOUT(HASHED());

-- 使用方式:
-- SELECT order_id, dictGet('realtime_olap.dict_user_dict', 'user_name', user_id) AS user_name
-- FROM dwd_order;
-- 性能: 千万级维表查询 < 10ms (HASHED 字典)

-- ========================================
-- 3. DWS 层 - 数据汇总层
-- ========================================
-- 
-- 设计原则:
--   - 面向"分析主题"而非业务过程
--   - 预聚合(分钟/小时/天)
--   - 跨业务域复用(订单+用户+商品维度)
--   - 使用 AggregatingMergeTree 存储 -State 状态
--   - 配合物化视图自动滚动
-- 
-- 引擎选择: ReplicatedAggregatingMergeTree
--   - 存储 -State(可合并的中间态)
--   - 查询时用 -Merge 合并器
--   - Why 不用普通 MergeTree + 物化视图: AMT 性能高 5-10x
-- 
-- ========================================

-- 3.1 DWS 用户日汇总(订单域)
-- 
-- 关键决策:
--   - 粒度: 用户 × 天 (1 亿用户 × 365 天 = 365 亿, 可接受)
--   - 聚合指标: 下单数、下单金额、支付数、支付金额
--   - 状态列: 用 SimpleAggregateFunction (无 -State 合并)
-- 
CREATE TABLE IF NOT EXISTS realtime_olap.dws_user_order_day ON CLUSTER 'treasurycluster' (
    -- 维度
    dt                 Date,                    -- 日期
    user_id            UInt64,
    user_tier          LowCardinality(String),
    user_age_group     LowCardinality(String),
    region_code        LowCardinality(String),
    
    -- 指标(使用 SimpleAggregateFunction 减少存储)
    order_cnt          SimpleAggregateFunction(sum,  UInt32),   -- 下单数
    pay_cnt            SimpleAggregateFunction(sum,  UInt32),   -- 支付数
    order_amount       SimpleAggregateFunction(sum,  Decimal(18, 2)),
    pay_amount         SimpleAggregateFunction(sum,  Decimal(18, 2)),
    discount_amount    SimpleAggregateFunction(sum,  Decimal(18, 2))
) ENGINE = ReplicatedAggregatingMergeTree(
    '/clickhouse/tables/{shard}/realtime_olap/dws_user_order_day',
    '{replica}'
)
PARTITION BY toYYYYMM(dt)
ORDER BY (dt, user_tier, user_age_group, region_code, user_id)
SETTINGS index_granularity = 8192;

-- Why 用 SimpleAggregateFunction?
--   - sum/min/max 这些函数结果与顺序无关
--   - 不需要存储 -State 状态,直接存最终值
--   - 查询时无需 -Merge 合并器,直接读
--   - 节省 50% 存储空间

-- 3.2 DWS 商家日汇总(订单域)
CREATE TABLE IF NOT EXISTS realtime_olap.dws_product_order_day ON CLUSTER 'treasurycluster' (
    dt                 Date,
    product_id         UInt64,
    product_category   LowCardinality(String),
    product_brand      LowCardinality(String),
    
    -- 指标
    order_cnt          SimpleAggregateFunction(sum, UInt32),
    pay_cnt            SimpleAggregateFunction(sum, UInt32),
    visitor_cnt        AggregateFunction(uniq, UInt64),  -- 访客数(去重)
    order_amount       SimpleAggregateFunction(sum, Decimal(18, 2)),
    pay_amount         SimpleAggregateFunction(sum, Decimal(18, 2))
) ENGINE = ReplicatedAggregatingMergeTree(
    '/clickhouse/tables/{shard}/realtime_olap/dws_product_order_day',
    '{replica}'
)
PARTITION BY toYYYYMM(dt)
ORDER BY (dt, product_category, product_brand, product_id)
SETTINGS index_granularity = 8192;

-- 访客数用 uniq 而非 SimpleAggregateFunction?
--   - uniq 是 HyperLogLog 近似去重,需要 -State 合并
--   - 用 AggregateFunction + 后续 -Merge 合并器

-- 3.3 DWS 数据写入 - 用物化视图从 DWD 自动聚合
-- 
-- Why 物化视图?
--   - 写入 DWD 时自动触发,无需 Flink 二次聚合
--   - 增量更新,延迟 < 1 秒
--   - 查询时自动选择最新状态
-- 
CREATE MATERIALIZED VIEW IF NOT EXISTS realtime_olap.mv_dws_user_order_day
ON CLUSTER 'treasurycluster'
TO realtime_olap.dws_user_order_day AS
SELECT
    toDate(order_time)           AS dt,
    user_id,
    user_tier,
    user_age_group,
    region_code,
    
    sumSimpleState(1)            AS order_cnt,
    sumSimpleState(if(order_status IN ('paid', 'shipped', 'completed', 'refunded'), 1, 0)) AS pay_cnt,
    sumSimpleState(order_amount) AS order_amount,
    sumSimpleState(pay_amount)   AS pay_amount,
    sumSimpleState(discount_amount) AS discount_amount
FROM realtime_olap.dwd_order
WHERE is_valid = 1
GROUP BY dt, user_id, user_tier, user_age_group, region_code;

-- 查询时使用(自动走物化视图):
-- SELECT user_id, sum(order_cnt) AS order_cnt, sum(pay_amount) AS pay_amount
-- FROM realtime_olap.dws_user_order_day  -- 注意: 直接查 dws 表,MV 透明
-- WHERE dt = '2026-06-19'
-- GROUP BY user_id;

-- ========================================
-- 4. ADS 层 - 数据应用层
-- ========================================
-- 
-- 设计原则:
--   - 高度聚合(天/小时级)
--   - 面向具体业务场景(GMV看板、漏斗看板)
--   - 一个看板 = 一张 ADS 表(或视图)
--   - 用物化视图 + 视图组合
--   - 这是 Superset 直接消费的数据源
-- 
-- 引擎选择: 
--   - 高频看板 → AggregatingMergeTree(性能最优)
--   - 低频看板 → 视图(灵活,实时性最强)
-- 
-- ========================================

-- 4.1 ADS 实时 GMV 看板(分钟级刷新)
-- 
-- 用视图而非物化视图:
--   - 数据量小(每分钟一行)
--   - 实时性要求极高(秒级延迟)
--   - 灵活性高(可任意组合维度)
-- 
CREATE VIEW IF NOT EXISTS realtime_olap.ads_gmv_minute ON CLUSTER 'treasurycluster' AS
SELECT
    toStartOfMinute(order_time)             AS minute,
    region_code,
    product_category,
    channel,
    
    count()                                 AS order_cnt,
    countIf(order_status = 'paid')          AS pay_cnt,
    sum(order_amount)                       AS gmv,
    sum(pay_amount)                         AS pay_amount,
    uniqExact(user_id)                      AS pay_user_cnt
FROM realtime_olap.dwd_order
WHERE order_time >= now() - INTERVAL 1 HOUR
  AND is_valid = 1
GROUP BY minute, region_code, product_category, channel;

-- 4.2 ADS 漏斗分析(下单→支付→完成)
-- 
-- 漏斗分析特点:
--   - 每一步是上一步的子集
--   - 适合用 windowFunnel 函数
-- 
CREATE VIEW IF NOT EXISTS realtime_olap.ads_funnel ON CLUSTER 'treasurycluster' AS
SELECT
    toDate(order_time)                      AS dt,
    channel,
    
    -- 漏斗: 1.下单 2.支付 3.完成
    windowFunnel(86400)(                    -- 86400 秒 = 1 天窗口
        toUInt32(order_time),
        order_status = 'created',
        order_status = 'paid',
        order_status = 'completed'
    ) AS funnel_level,
    
    count() AS user_cnt
FROM realtime_olap.dwd_order
WHERE order_time >= today() - INTERVAL 7 DAY
  AND is_valid = 1
GROUP BY dt, channel;

-- 4.3 ADS 用户留存(次日/7日/30日)
CREATE TABLE IF NOT EXISTS realtime_olap.ads_user_retention ON CLUSTER 'treasurycluster' (
    register_dt      Date,
    dt               Date,                   -- 观察日
    days_since_reg   UInt16,
    
    -- 维度
    register_channel LowCardinality(String),
    user_tier        LowCardinality(String),
    
    -- 指标
    active_user_cnt  AggregateFunction(uniq, UInt64)
) ENGINE = ReplicatedAggregatingMergeTree(
    '/clickhouse/tables/{shard}/realtime_olap/ads_user_retention',
    '{replica}'
)
PARTITION BY toYYYYMM(register_dt)
ORDER BY (register_dt, register_channel, user_tier, days_since_reg)
SETTINGS index_granularity = 8192;

-- 留存计算用 Flink 写,或者每天定时任务写

-- ========================================
-- 5. 设计原则总结
-- ========================================

/*
┌─────────────────────────────────────────────────────────────────────────┐
│                    ClickHouse 建模 8 大原则                                │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  1. 宽表优先(去规范化)                                                  │
│     - 实时分析场景: 99% 是单表聚合 + 简单过滤,无需 JOIN                   │
│     - 在 DWD 层就冗余常用维度(用户等级、商品类目、地区)                    │
│     - Why: ClickHouse JOIN 是 O(N),宽表是 O(1)                          │
│                                                                         │
│  2. 分区键 = 时间                                                       │
│     - PARTITION BY toYYYYMM(时间字段) 或 toDate(时间字段)                 │
│     - 99% 查询都带时间范围,分区裁剪性能提升 100x                          │
│     - Why: 避免按业务字段分区(导致数据倾斜)                                │
│                                                                         │
│  3. 排序键 = "高基数+高频过滤"                                           │
│     - 基数越高越好(避免压缩率低)                                         │
│     - 查询频率越高的字段越靠前                                            │
│     - 时间字段通常放最前                                                  │
│     - Why: 主键索引是稀疏索引(每 8192 行),决定查询性能                    │
│                                                                         │
│  4. 数据类型最小化                                                       │
│     - UInt8 代替 Enum, UInt32 代替 UInt64 (如果够用)                      │
│     - Decimal(18,2) 代替 Float64 (金额)                                  │
│     - LowCardinality(String) 代替 String (低基数)                        │
│     - Why: 压缩比提升 2-5x,内存减少 50%                                  │
│                                                                         │
│  5. 索引分场景选择                                                       │
│     - 主键索引: 默认有,稀疏(每 8192 行)                                 │
│     - 跳数索引: 过滤字段用(常用 in/equals/range)                         │
│     - 投影: 复杂查询(已包含在排序键中)                                   │
│     - Why: 索引不是越多越好,每个都增加写入开销                            │
│                                                                         │
│  6. 写入用批,不用单条                                                    │
│     - min_insert_block_size_rows = 1000000                              │
│     - max_insert_block_size_bytes = 104857600 (100MB)                   │
│     - Why: ClickHouse 写性能与 batch size 强相关,1000x 差异             │
│                                                                         │
│  7. 删除用分区,不用 mutation                                            │
│     - DROP PARTITION 替代 ALTER DELETE                                  │
│     - Why: DROP PARTITION 是元数据操作(<1秒), mutation 是物理重写(分钟级)│
│                                                                         │
│  8. 物化视图优先于查询时计算                                             │
│     - 高频聚合(>100 QPS) → 物化视图                                     │
│     - 低频聚合(<10 QPS) → 普通视图                                       │
│     - Why: 物化视图查询快 10x,代价是存储增加 20%                          │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
*/

-- ========================================
-- 6. 验证查询
-- ========================================

-- 6.1 检查各层数据量
SELECT
    'ODS'  AS layer, count() AS rows, formatReadableSize(sum(bytes_on_disk)) AS size
FROM system.parts WHERE database = 'realtime_olap' AND table = 'ods_order' AND active
UNION ALL
SELECT 'DWD',  count(), formatReadableSize(sum(bytes_on_disk))
FROM system.parts WHERE database = 'realtime_olap' AND table = 'dwd_order' AND active
UNION ALL
SELECT 'DWS',  count(), formatReadableSize(sum(bytes_on_disk))
FROM system.parts WHERE database = 'realtime_olap' AND table = 'dws_user_order_day' AND active;

-- 6.2 检查物化视图状态
SELECT
    name,
    engine,
    total_rows,
    formatReadableSize(total_bytes) AS size
FROM system.tables
WHERE database = 'realtime_olap' AND engine LIKE '%MaterializedView%';

-- 6.3 字典使用统计
SELECT
    dict_name,
    element_count,
    bytes_allocated,
    hit_rate
FROM system.dictionaries
WHERE database = 'realtime_olap';
