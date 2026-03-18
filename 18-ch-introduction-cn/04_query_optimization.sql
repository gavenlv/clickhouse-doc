-- =====================================================
-- 04 - 查询优化技巧与实践
-- =====================================================
-- 
-- 集群: treasurycluster (2 副本)
-- 预计学习时间: 30 分钟
-- 
-- 本文件涵盖:
--   1. 查询优化核心原则 - 减少数据读取量
--   2. PREWHERE优化 - 过滤前置减少IO
--   3. 索引利用技巧 - 主键索引/跳数索引/Projection
--   4. 分区裁剪优化 - 按时间范围快速定位
--   5. 聚合查询优化 - GROUP BY/窗口函数
--   6. JOIN查询优化 - JOIN顺序与类型选择
--   7. 查询分析工具 - EXPLAIN与性能诊断
--   8. 常见反模式 - 性能杀手与规避方法
-- 
-- =====================================================

-- -----------------------------------------------------
-- 1. 查询优化核心原则
-- -----------------------------------------------------

-- 
-- ┌─────────────────────────────────────────────────────────────┐
-- │              ClickHouse 查询优化核心原则                     │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                             │
-- │  1. 列裁剪 (Column Pruning)                                 │
-- │     - 只 SELECT 需要的列                                     │
-- │     - 避免 SELECT *                                        │
-- │                                                             │
-- │  2. 谓词下推 (Predicate Pushdown)                          │
-- │     - WHERE 条件尽可能靠近数据源                           │
-- │     - 减少读取数据量                                       │
-- │                                                             │
-- │  3. 分区裁剪 (Partition Pruning)                           │
-- │     - 利用 PARTITION BY 过滤                               │
-- │     - 避免全表扫描                                         │
-- │                                                             │
-- │  4. 索引利用                                               │
-- │     - 利用主键索引快速定位                                 │
│  │     - 使用 skip index                                     │
-- │                                                             │
-- │  5. 数据采样 (Sampling)                                    │
-- │     - 大数据量时使用 SAMPLE                                │
-- │     - 快速了解数据分布                                     │
-- │                                                             │
-- └─────────────────────────────────────────────────────────────┘

-- 使用 playground 数据库
USE playground;

-- 创建测试表 (Replicated)
DROP TABLE IF EXISTS opt_events ON CLUSTER treasurycluster SYNC;

CREATE TABLE opt_events ON CLUSTER treasurycluster (
    event_id UInt64,
    user_id UInt32,
    event_time DateTime,
    event_type Enum8('click' = 1, 'view' = 2, 'purchase' = 3),
    category String,
    country String,
    revenue Float64,
    payload String
) ENGINE = ReplicatedMergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_type, user_id, event_time);

-- 插入100万行测试数据
INSERT INTO opt_events
SELECT 
    number AS event_id,
    number % 50000 AS user_id,
    toDateTime('2024-01-01 00:00:00') + number * 60 AS event_time,
    CAST(number % 3 + 1 AS Enum8('click' = 1, 'view' = 2, 'purchase' = 3)) AS event_type,
    ['Electronics', 'Clothing', 'Food', 'Books', 'Sports'][number % 5 + 1] AS category,
    ['US', 'CN', 'UK', 'JP', 'DE', 'FR'][number % 6 + 1] AS country,
    if(number % 10 = 0, rand() % 500, 0) AS revenue,
    repeat('x', 100) AS payload
FROM numbers(1000000);

-- -----------------------------------------------------
-- 2. 列裁剪优化
-- -----------------------------------------------------

-- 不好的写法: SELECT *
SELECT count() FROM opt_events;

-- 好的写法: 只选择需要的列
SELECT 
    user_id,
    event_type,
    revenue
FROM opt_events
LIMIT 10;

-- 对比性能
SET max_threads = 1;

-- 不推荐
EXPLAIN ESTIMATE SELECT * FROM opt_events WHERE event_type = 'purchase';

-- 推荐
EXPLAIN ESTIMATE SELECT event_type, revenue FROM opt_events WHERE event_type = 'purchase';

-- 
-- ┌─────────────────────────────────────────────────────────────┐
-- │              列裁剪效果对比                                   │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                             │
-- │  SELECT * FROM events WHERE event_type = 'purchase'        │
-- │  ┌─────────────────────────────────────────────────────┐   │
-- │  │  读取所有列 + payload (100字节)                     │   │
-- │  │  预计读取: ~150 MB                                   │   │
-- │  └─────────────────────────────────────────────────────┘   │
-- │                                                             │
-- │  SELECT event_type, revenue FROM events WHERE event_type  │
-- │  ┌─────────────────────────────────────────────────────┐   │
-- │  │  只读取 2 列 (~12 字节)                              │   │
-- │  │  预计读取: ~15 MB                                    │   │
-- │  └─────────────────────────────────────────────────────┘   │
-- │                                                             │
-- │  提升: 10x                                                 │
-- │                                                             │
-- └─────────────────────────────────────────────────────────────┘

-- -----------------------------------------------------
-- 3. PREWHERE 优化
-- -----------------------------------------------------

-- PREWHERE: 先读取过滤列，再读取目标列
-- 适用于: 过滤列和目标列不同时

-- 使用 PREWHERE
SELECT event_id, event_type
FROM opt_events
PREWHERE event_type = 'purchase'
WHERE revenue > 100
LIMIT 100;

-- ClickHouse 自动使用 PREWHERE
SELECT event_id, event_type, revenue
FROM opt_events
WHERE event_type = 'purchase' AND revenue > 100
LIMIT 100;

-- -----------------------------------------------------
-- 4. 分区裁剪
-- -----------------------------------------------------

-- 查看分区
SELECT 
    partition,
    sum(rows) AS total_rows,
    formatReadableSize(sum(bytes)) AS size
FROM system.parts
WHERE database = 'playground' AND table = 'opt_events' AND active = 1
GROUP BY partition
ORDER BY partition;

-- 好的查询: 利用分区裁剪
SELECT count(), sum(revenue)
FROM opt_events
WHERE event_time >= '2024-01-01' AND event_time < '2024-01-02';

-- 不好的查询: 无法利用分区裁剪
SELECT count(), sum(revenue)
FROM opt_events
WHERE toDayOfWeek(event_time) = 1;

-- 
-- ┌─────────────────────────────────────────────────────────────┐
-- │              分区裁剪效果对比                                 │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                             │
-- │  WHERE event_time >= '2024-01-01'                         │
-- │  ┌─────────────────────────────────────────────────────┐   │
-- │  │  只扫描 1 月 1 日的分区                              │   │
-- │  │  预计读取: ~50 MB                                    │   │
-- │  └─────────────────────────────────────────────────────┘   │
-- │                                                             │
-- │  WHERE toDayOfWeek(event_time) = 1                         │
-- │  ┌─────────────────────────────────────────────────────┐   │
-- │  │  需要扫描所有分区                                   │   │
-- │  │  预计读取: ~1 GB                                    │   │
-- │  └─────────────────────────────────────────────────────┘   │
-- │                                                             │
-- │  提升: 20x                                                  │
-- │                                                             │
-- └─────────────────────────────────────────────────────────────┘

-- -----------------------------------------------------
-- 5. 使用 Skipping Index
-- -----------------------------------------------------

-- 创建带 skip index 的表 (Replicated)
DROP TABLE IF EXISTS events_with_skip_idx ON CLUSTER treasurycluster SYNC;

CREATE TABLE events_with_skip_idx ON CLUSTER treasurycluster (
    event_id UInt64,
    user_id UInt32,
    event_time DateTime,
    event_type Enum8('click' = 1, 'view' = 2, 'purchase' = 3),
    category String,
    country String,
    revenue Float64
) ENGINE = ReplicatedMergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_type, user_id, event_time)
SETTINGS index_granularity = 8192;

-- 添加 skip index
ALTER TABLE events_with_skip_idx 
ADD INDEX idx_category category TYPE set(100) GRANULARITY 4;

ALTER TABLE events_with_skip_idx 
ADD INDEX idx_country country TYPE bloom_filter GRANULARITY 1;

-- 插入数据
INSERT INTO events_with_skip_idx
SELECT * FROM opt_events LIMIT 100000;

-- 查看 skip index
SELECT 
    name,
    type,
    granularity
FROM system.data_skipping_indices
WHERE database = 'playground' AND table = 'events_with_skip_idx';

-- -----------------------------------------------------
-- 6. 数据采样
-- -----------------------------------------------------

-- 创建支持采样的表 (Replicated)
DROP TABLE IF EXISTS events_sampled ON CLUSTER treasurycluster SYNC;

CREATE TABLE events_sampled ON CLUSTER treasurycluster (
    event_id UInt64,
    user_id UInt32,
    event_time DateTime,
    event_type Enum8('click' = 1, 'view' = 2, 'purchase' = 3)
) ENGINE = ReplicatedMergeTree()
ORDER BY event_id
SAMPLE BY event_id;

INSERT INTO events_sampled SELECT * FROM opt_events LIMIT 100000;

-- 使用 SAMPLE (需要 SAMPLE BY)
-- SAMPLE 1000000: 采样约 100 万行
-- SAMPLE 0.1: 采样 10% 数据
-- SAMPLE 1/10: 采样 1/10 数据

-- 正常查询
SELECT count(), uniqExact(user_id) FROM events_sampled;

-- 采样查询 (使用 SAMPLE BY)
-- SELECT count(), uniqExact(user_id) FROM events_sampled SAMPLE 1000000;

-- 
-- ┌─────────────────────────────────────────────────────────────┐
-- │              采样查询使用场景                                 │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                             │
-- │  ✓ 快速了解数据分布                                          │
-- │  ✓ 开发调试时快速返回结果                                    │
-- │  ✓ 近似计算 (使用 SAMPLE + 乘法因子)                       │
-- │                                                             │
-- │  ✗ 精确 COUNT 需要除以采样比例                              │
-- │  ✗ 部分聚合函数不支持采样                                  │
-- │                                                             │
-- │  示例:                                                      │
-- │  SELECT sum(col) * 10 FROM table SAMPLE 0.1                │
-- │                                                             │
-- └─────────────────────────────────────────────────────────────┘

-- -----------------------------------------------------
-- 7. 近似聚合
-- -----------------------------------------------------

-- uniqExact → uniq
SELECT 
    'uniqExact' AS method,
    uniqExact(user_id) AS result
FROM opt_events
WHERE event_type = 'purchase';

-- uniq (近似，内存消耗小)
SELECT 
    'uniq' AS method,
    uniq(user_id) AS result
FROM opt_events
WHERE event_type = 'purchase';

-- quantile → quantileExact
SELECT 
    quantile(0.5)(revenue) AS median_revenue,
    quantile(0.95)(revenue) AS p95_revenue
FROM opt_events;

-- 
-- ┌─────────────────────────────────────────────────────────────┐
-- │              近似聚合函数对比                                 │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                             │
-- │  函数         │ 准确性   │  内存   │  速度   │            │
-- │  ────────────┼──────────┼─────────┼─────────┤            │
-- │  uniqExact   │  100%    │  高     │  慢     │            │
-- │  uniq        │  ~99%    │  低     │  快     │            │
-- │  quantileExact │ 100%  │  高     │  慢     │            │
-- │  quantile    │  ~99%    │  低     │  快     │            │
-- │                                                             │
-- └─────────────────────────────────────────────────────────────┘

-- -----------------------------------------------------
-- 8. 物化视图优化
-- -----------------------------------------------------

-- 创建聚合物化视图 (Replicated)
DROP TABLE IF EXISTS mv_daily_stats ON CLUSTER treasurycluster SYNC;
CREATE TABLE mv_daily_stats ON CLUSTER treasurycluster (
    date Date,
    event_type Enum8('click' = 1, 'view' = 2, 'purchase' = 3),
    category String,
    event_count UInt64,
    unique_users UInt64,
    total_revenue Float64
) ENGINE = ReplicatedSummingMergeTree()
PARTITION BY toYYYYMM(date)
ORDER BY (date, event_type, category);

DROP MATERIALIZED VIEW IF EXISTS mv_daily_stats_mv ON CLUSTER treasurycluster SYNC;
CREATE MATERIALIZED VIEW mv_daily_stats_mv ON CLUSTER treasurycluster
ENGINE = ReplicatedSummingMergeTree()
PARTITION BY toYYYYMM(date)
ORDER BY (date, event_type, category) AS
SELECT 
    toDate(event_time) AS date,
    event_type,
    category,
    count() AS event_count,
    uniqExact(user_id) AS unique_users,
    sum(revenue) AS total_revenue
FROM opt_events
GROUP BY 
    toDate(event_time),
    event_type,
    category;

-- 查看物化视图数据
SELECT * FROM mv_daily_stats ORDER BY date DESC LIMIT 10;

-- 对比查询性能
SET max_threads = 1;

-- 直接查询
SELECT 
    event_type,
    count() AS cnt,
    sum(revenue) AS revenue
FROM opt_events
WHERE event_type = 'purchase'
GROUP BY event_type;

-- 查询物化视图
SELECT 
    event_type,
    event_count AS cnt,
    total_revenue AS revenue
FROM mv_daily_stats
WHERE event_type = 'purchase';

-- 
-- ┌─────────────────────────────────────────────────────────────┐
-- │              物化视图 vs 直接查询                             │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                             │
-- │  直接查询:                                                  │
-- │  - 每次全表扫描                                            │
-- │  - 100万行 → 慢                                           │
-- │                                                             │
-- │  物化视图:                                                  │
-- │  - 预聚合结果                                              │
-- │  - 几千行 → 快                                            │
-- │                                                             │
-- │  适用场景:                                                  │
-- │  ✓ 重复的聚合查询                                          │
-- │  ✓ 实时性要求不高的报表                                    │
-- │  ✓ 多维度分析                                              │
-- │                                                             │
-- └─────────────────────────────────────────────────────────────┘

-- -----------------------------------------------------
-- 9. 本章小结
-- -----------------------------------------------------

-- 
-- ┌─────────────────────────────────────────────────────────────┐
-- │              本章要点                                       │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                             │
-- │  1. 列裁剪: 只选需要的列，避免 SELECT *                    │
-- │  2. PREWHERE: 先过滤再读取其他列                           │
-- │  3. 分区裁剪: 利用 WHERE 条件跳过不相关分区                │
-- │  4. Skip Index: 用于过滤条件列                             │
-- │  5. 数据采样: SAMPLE 加速开发调试                         │
-- │  6. 近似聚合: uniq, quantile 减少内存消耗                  │
-- │  7. 物化视图: 预聚合重复查询                               │
-- │                                                             │
-- │  下一步: 05_best_practices.sql - 最佳实践与常见问题       │
-- │                                                             │
-- └─────────────────────────────────────────────────────────────┘

SELECT 
    'optimization' AS chapter,
    (SELECT sum(rows) FROM system.parts WHERE database = 'playground' AND table = 'opt_events' AND active = 1) AS total_rows;
