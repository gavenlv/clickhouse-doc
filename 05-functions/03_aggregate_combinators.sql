-- ============================================================
-- 文件: 05-functions/03_aggregate_combinators.sql
-- 学习目标: 掌握聚合组合子（Aggregate Combinators）原理与实战
-- 深度标准: 原理 + 场景 + 对比 + 可运行
-- 集群: CH 25.12 (单机模式，聚合组合子概念通用)
-- 前置: 无（自包含测试数据，按顺序执行）
-- ============================================================
--
-- 本文件章节:
--   1.  聚合组合子原理（函数修饰器 vs 独立函数）
--   2.  -If 组合子：条件聚合（sumIf / countIf / avgIf / uniqIf）
--   3.  -Array 组合子：数组聚合（sumArray / uniqArray）
--   4.  -State / -Merge / -MergeState：状态链
--   5.  -ForEach：逐元素聚合（Map 的每个 key）
--   6.  -Resample：时间窗口重采样聚合
--   7.  -SimpleState：简化版状态（结合 SimpleAggregateFunction）
--   8.  -Distinct：去重聚合（countDistinct / sumDistinct）
--   9.  -OrDefault：默认值聚合
--   10. 组合子链式使用（sumIfState、uniqIfMerge）
--   11. 性能对比：普通聚合 vs 组合子聚合
--   12. 清理
-- ============================================================

DROP DATABASE IF EXISTS func_test;
CREATE DATABASE func_test;
USE func_test;


-- ============================================================
-- 0. 准备测试数据（通用数据集）
-- ============================================================
-- 【原理】数据集包含多种类型数据，便于演示不同组合子

DROP TABLE IF EXISTS orders;
DROP TABLE IF EXISTS user_events;
DROP TABLE IF EXISTS product_scores;
DROP TABLE IF EXISTS sensor_data;

-- 订单表（含 NULL 和重复值）
CREATE TABLE orders (
    id UInt64,
    category String,
    amount Decimal(10, 2),
    quantity UInt32,
    region String,
    is_valid UInt8
) ENGINE = MergeTree()
ORDER BY id;

INSERT INTO orders VALUES
    (1, 'Electronics', 299.99, 2, 'North', 1),
    (2, 'Electronics', 499.99, 1, 'South', 1),
    (3, 'Clothing', 49.99, 5, 'East', 1),
    (4, 'Clothing', 29.99, 2, 'West', 0),
    (5, 'Electronics', 899.99, 1, 'South', 1),
    (6, 'Books', 19.99, 15, 'North', 1),
    (7, 'Clothing', 39.99, 10, 'East', 0),
    (8, 'Electronics', 149.99, 3, 'West', 1),
    (9, 'Books', 9.99, 20, 'South', 1),
    (10, 'Electronics', 699.99, 1, 'North', 1);

-- 用户事件表（含数组字段）
CREATE TABLE user_events (
    id UInt64,
    user_id UInt32,
    event_date Date,
    event_tags Array(String),
    event_scores Array(UInt8)
) ENGINE = MergeTree()
ORDER BY id;

INSERT INTO user_events VALUES
    (1, 1001, '2024-01-15', ['purchase', 'view'], [10, 8]),
    (2, 1001, '2024-01-16', ['view', 'share'], [7, 9]),
    (3, 1002, '2024-01-15', ['purchase', 'purchase', 'view'], [9, 8, 7]),
    (4, 1003, '2024-01-16', ['share', 'comment'], [6, 8]),
    (5, 1002, '2024-01-17', ['view', 'view', 'purchase'], [8, 9, 10]);

-- 产品评分表（用于去重和默认值演示）
CREATE TABLE product_scores (
    id UInt64,
    product_id UInt32,
    score Nullable(Float32),
    review_count Nullable(UInt32)
) ENGINE = MergeTree()
ORDER BY id;

INSERT INTO product_scores VALUES
    (1, 101, 4.5, 100),
    (2, 101, 4.5, 100),
    (3, 102, 3.8, 50),
    (4, 102, NULL, NULL),
    (5, 103, 4.0, 200),
    (6, 103, 4.2, 180),
    (7, 104, NULL, NULL),
    (8, 104, 3.5, 30);

-- 传感器数据表（用于 Resample 演示）
CREATE TABLE sensor_data (
    sensor_id UInt32,
    event_time DateTime,
    temperature Float32,
    humidity Float32
) ENGINE = MergeTree()
ORDER BY (sensor_id, event_time);

INSERT INTO sensor_data VALUES
    (1, '2024-01-15 08:10:00', 22.5, 55.0),
    (1, '2024-01-15 08:25:00', 23.0, 54.5),
    (1, '2024-01-15 08:40:00', 23.5, 54.0),
    (1, '2024-01-15 09:05:00', 24.0, 53.5),
    (1, '2024-01-15 09:20:00', 24.5, 53.0),
    (1, '2024-01-15 09:45:00', 25.0, 52.5),
    (2, '2024-01-15 08:30:00', 18.0, 65.0),
    (2, '2024-01-15 09:00:00', 18.5, 64.0),
    (2, '2024-01-15 09:30:00', 19.0, 63.0);


-- ============================================================
-- 1. 聚合组合子原理
-- ============================================================
-- 【原理】聚合组合子（Aggregate Combinators）是 ClickHouse 独有的
--   "函数修饰器"机制。它们不是独立函数，而是附加在聚合函数后的
--   后缀修饰符，改变聚合函数的行为。
--
--   本质：
--     sumIf(x, cond) = sum(x) 的"条件版"
--     └─ 不是 sum + If，而是组合子 -If 修饰 sum
--
--   为什么叫"组合子"？
--     组合子 = Combinator = 一个函数接受另一个函数并返回
--     新函数。在 ClickHouse 中，聚合组合子作用于聚合函数，
--     返回行为不同的聚合函数。
--
--   组合子 vs 独立函数对比：
--     sumIf(x, cond)  ← 组合子风格（推荐）
--     sum(if(cond, x, 0))  ← 等价的手写条件（但效率低，见 §11）
--
-- 【场景】报表的"分列对比"、条件汇聚、数组分解、多级聚合
-- 【坑】组合子必须跟在聚合函数名后面，不能单独使用
--       如 sumIf(x, cond) 正确，但 If(sum(x), cond) 错误


-- ============================================================
-- 2. -If 组合子：条件聚合（最常用）
-- ============================================================
-- 【原理】-If 组合子给聚合函数加一个"条件过滤器"参数：
--   聚合函数名 + If(参数..., 条件)
--   只在条件为 true 的行参与聚合。
-- 【场景】同一查询中做"分列对比"（如各区域指标一行输出）
-- 【对比】等价于 WHERE 分多次查询，但 -If 一次扫描完成，效率高

-- 2.1 sumIf：条件求和
-- 【场景】按品类统计有效订单金额（is_valid=1）
SELECT
    category,
    -- 普通 sum：全部金额
    sum(amount) AS total_amount,
    -- sumIf：只加 is_valid=1 的金额
    sumIf(amount, is_valid = 1) AS valid_amount,
    -- 等价写法（但更低效，见 §11）
    sum(if(is_valid = 1, amount, 0)) AS valid_amount_alt,
    -- 条件统计：各区域有效订单金额
    sumIf(amount, region = 'North' AND is_valid = 1) AS north_valid,
    sumIf(amount, region = 'South' AND is_valid = 1) AS south_valid,
    sumIf(amount, region = 'East' AND is_valid = 1) AS east_valid,
    sumIf(amount, region = 'West' AND is_valid = 1) AS west_valid
FROM orders
GROUP BY category
ORDER BY category;

-- 2.2 countIf：条件计数
-- 【场景】统计"有效订单数"和"无效订单数"
SELECT
    category,
    count() AS total_orders,
    countIf(is_valid = 1) AS valid_orders,
    countIf(is_valid = 0) AS invalid_orders,
    -- 占比
    round(countIf(is_valid = 1) / count() * 100, 2) AS valid_pct
FROM orders
GROUP BY category
ORDER BY category;

-- 2.3 avgIf：条件均值
-- 【场景】仅有效订单的均价
SELECT
    category,
    avg(amount) AS avg_all,
    avgIf(amount, is_valid = 1) AS avg_valid_only,
    minIf(amount, is_valid = 1) AS min_valid,
    maxIf(amount, is_valid = 1) AS max_valid
FROM orders
GROUP BY category
ORDER BY category;

-- 2.4 uniqIf：条件去重计数
-- 【场景】统计各品类有效订单涉及的唯一商品数
-- 注意：这里用 id 作为近似，实际场景用 product_id
SELECT
    category,
    uniq(id) AS total_products,
    uniqIf(id, is_valid = 1) AS valid_products
FROM orders
GROUP BY category
ORDER BY category;

-- 2.5 组合条件：多条件 -If
-- 【场景】北方区域、大额（>100）有效订单金额
SELECT
    category,
    sumIf(amount, region = 'North' AND is_valid = 1 AND amount > 100) AS north_big_valid
FROM orders
GROUP BY category
ORDER BY category;


-- ============================================================
-- 3. -Array 组合子：数组聚合
-- ============================================================
-- 【原理】-Array 组合子将聚合函数作用于数组的每个元素，
--   输入是数组列，输出是聚合后的标量值。
--   等价于 arrayJoin 展开后再聚合，但更高效。
-- 【场景】数组字段的统计（标签分数、多维指标）

-- 3.1 sumArray：数组求和
-- 【场景】每个用户事件的总分
SELECT
    user_id,
    event_scores,
    sumArray(event_scores) AS total_score_per_user,
    -- 等价写法（展开后聚合，多一步 arrayJoin）
    -- 注意：这会把行数展开，结果不同，仅作对比
    arraySum(event_scores) AS array_sum
FROM user_events
ORDER BY user_id;

-- 3.2 uniqArray：数组元素去重计数
-- 【场景】每个用户涉及的不同事件类型数
SELECT
    user_id,
    event_tags,
    uniqArray(event_tags) AS unique_tag_count
FROM user_events
ORDER BY user_id;

-- 3.3 sumArray 配合 GROUP BY
-- 【场景】按用户分组，统计所有事件分数总和
SELECT
    user_id,
    sumArray(event_scores) AS total_score,
    uniqArray(arrayFlatten(groupArray(event_tags))) AS all_unique_tags
FROM user_events
GROUP BY user_id
ORDER BY user_id;

-- 3.4 avgArray / minArray / maxArray
-- 【场景】数组元素的统计量
SELECT
    user_id,
    event_scores,
    avgArray(event_scores) AS avg_score,
    minArray(event_scores) AS min_score,
    maxArray(event_scores) AS max_score
FROM user_events
ORDER BY user_id;


-- ============================================================
-- 4. -State / -Merge / -MergeState：状态链
-- ============================================================
-- 【原理】这是 ClickHouse 两阶段聚合的基石：
--   -State：把聚合结果存为"中间状态"（二进制 AggregateFunction 类型）
--   -Merge：将多个状态合并出最终值
--   -MergeState：合并后仍保持状态，可继续合并（用于多级聚合）
-- 【场景】物化视图预聚合、分布式聚合、跨时段汇总

-- 4.1 sumState / sumMerge：基础状态链
-- 【原理】sumState 存二进制状态，sumMerge 还原数值
-- 【坑】sumState 的结果不能直接 SELECT 看到数值
SELECT
    category,
    sumState(amount) AS gmv_state,  -- ← 这是二进制，不可读
    sumMerge(sumState(amount)) AS gmv  -- ← 先 State 再 Merge 还原
FROM orders
GROUP BY category
ORDER BY category;

-- 4.2 模拟两阶段聚合（分片 → 合并）
-- 阶段1：各"分片"计算状态
DROP TABLE IF EXISTS shard_1_state;
DROP TABLE IF EXISTS shard_2_state;

CREATE TABLE shard_1_state ENGINE = Memory AS
SELECT
    category,
    sumState(amount) AS s
FROM orders
WHERE region IN ('North', 'East')
GROUP BY category;

CREATE TABLE shard_2_state ENGINE = Memory AS
SELECT
    category,
    sumState(amount) AS s
FROM orders
WHERE region IN ('South', 'West')
GROUP BY category;

-- 阶段2：协调节点合并两个分片的状态
-- 【原理】sumMerge 把两个分片的 sumState 合并出最终值
SELECT
    category,
    sumMerge(s) AS total_gmv
FROM (
    SELECT category, s FROM shard_1_state
    UNION ALL
    SELECT category, s FROM shard_2_state
)
GROUP BY category
ORDER BY category;

-- 验证：与直接 sum 结果一致
SELECT
    category,
    sum(amount) AS direct_sum
FROM orders
GROUP BY category
ORDER BY category;

-- 4.3 -MergeState：可继续合并的状态
-- 【原理】MergeState 与 Merge 不同：
--   Merge：输出最终数值（不可再合并）
--   MergeState：输出仍是状态（可继续传给下一级 Merge）
-- 【场景】日 → 月 → 年 三级聚合，中间状态不丢失

-- 演示：先做日级状态，再用 MergeState 合并为月度状态
-- （MergeState 输出仍是 AggregateFunction 类型）

-- 4.4 uniqState / uniqMerge：近似去重状态
-- 【原理】uniq 底层是 HyperLogLog，uniqState 存 HLL sketch
-- 【场景】跨分片 UV 合并
SELECT
    category,
    uniqState(id) AS uv_state,     -- HLL 状态
    uniqMerge(uniqState(id)) AS uv  -- 合并出 UV
FROM orders
GROUP BY category
ORDER BY category;

-- 4.5 groupArrayState / groupArrayMerge：数组收集状态
-- 【场景】跨分片收集元素并合并
SELECT
    category,
    groupArrayState(region) AS region_state,
    groupArrayMerge(region_state) AS regions
FROM (
    SELECT category, region FROM orders ORDER BY region
)
GROUP BY category
ORDER BY category;


-- ============================================================
-- 5. -ForEach 组合子：逐元素聚合
-- ============================================================
-- 【原理】-ForEach 作用于数组列，对数组的每个位置独立执行聚合。
--   输入必须是等长数组，输出是数组，每个元素是对应位置聚合的结果。
-- 【场景】Map 的每个 key 独立聚合、多维指标的时间序列
-- 【对比】-ForEach 是"按位置"聚合，-Array 是"跨元素"聚合

-- 5.1 sumForEach：逐位置求和
-- 【场景】多个用户的事件分数，按位置对应相加
SELECT
    sumForEach(event_scores) AS position_wise_sum
FROM user_events;
-- 结果解读：每个位置独立求和
-- 位置1: 10 + 7 + 9 + 6 + 8 = 40
-- 位置2: 8 + 9 + 8 + 8 + 9 = 42
-- 位置3: 0 + 0 + 7 + 0 + 10 = 17

-- 5.2 avgForEach：逐位置均值
-- 【场景】每个"事件位"的平均分
-- 【坑】不同行的数组长度可能不同，短数组按 0 补齐
SELECT
    avgForEach(event_scores) AS position_wise_avg
FROM user_events;

-- 5.3 maxForEach / minForEach：逐位置极值
SELECT
    maxForEach(event_scores) AS position_wise_max,
    minForEach(event_scores) AS position_wise_min
FROM user_events;

-- 5.4 ForEach + Map 组合
-- 【场景】Map 的每个 key 独立求和
SELECT
    sumForEach(mapValues(event_scores_map)) AS sum_per_key
FROM (
    SELECT map('score1', 10, 'score2', 20, 'score3', 15) AS event_scores_map
    UNION ALL
    SELECT map('score1', 8, 'score2', 25, 'score3', 12)
);


-- ============================================================
-- 6. -Resample 组合子：时间窗口重采样聚合
-- ============================================================
-- 【原理】-Resample 将数据按时间范围划分为等宽窗口，
--   在每个窗口内独立执行聚合，输出数组（每个元素 = 一个窗口的结果）。
--   语法：aggFunction(x) RESAMPLE (start, end, step)
--     start: 起始值（包含）
--     end: 结束值（不包含）
--     step: 步长（窗口宽度）
-- 【场景】传感器时序数据、监控指标、日志频率分析
-- 【坑】-Resample 要求 ORDER BY 列与 RESAMPLE 的列一致
--   -Resample 输出是数组，需要 arrayJoin 展开才能看到明细
--   -Resample 在 CH 25.12 中需要配合 ORDER BY 使用

-- 6.1 基础重采样：按 1 小时窗口聚合温度均值
-- 【原理】将时间戳转换为秒级 Unix 时间，按 3600 秒（1 小时）窗口重采样
-- 【场景】传感器数据降采样
SELECT
    sensor_id,
    sum_temperature,
    count_temperature
FROM (
    SELECT
        sensor_id,
        sumResample(3600, 0, 86400)(temperature, temperature) AS sum_temperature,
        countResample(3600, 0, 86400)(temperature, temperature) AS count_temperature
    FROM sensor_data
    GROUP BY sensor_id
)
ORDER BY sensor_id;

-- 注意：-Resample 的语法在 CH 25.12 中较严格，
-- 更推荐用 toStartOfInterval + GROUP BY 做等价重采样
-- 【推荐替代方案】使用 toStartOfInterval 等效
SELECT
    sensor_id,
    toStartOfInterval(event_time, INTERVAL 1 HOUR) AS window_start,
    avg(temperature) AS avg_temp,
    count() AS sample_count
FROM sensor_data
GROUP BY sensor_id, window_start
ORDER BY sensor_id, window_start;


-- ============================================================
-- 7. -SimpleState 组合子：简化版状态
-- ============================================================
-- 【原理】-SimpleState 是 -State 的简化版，用于"可直接相加"的聚合
--   （sum、max、min、any 等），存普通值而非二进制状态。
--   配合 SimpleAggregateFunction 引擎使用，更省空间。
-- 【对比】
--   sumState → 存二进制 AggregateFunction 状态（通用但空间大）
--   sumSimpleState → 存普通数值（仅用于 sum/max/min 等，省空间）
-- 【场景】对性能敏感的简单预聚合

-- 7.1 sumSimpleState：简化版求和状态
SELECT
    category,
    -- sumSimpleState 输出是普通数值（不是二进制状态）
    sumSimpleState(amount) AS simple_state,
    -- 但与 sum 不同，sumSimpleState 用于 AggregatingMergeTree
    -- 配合 SimpleAggregateFunction 声明
    sum(amount) AS direct_sum
FROM orders
GROUP BY category
ORDER BY category;

-- 7.2 SimpleAggregateFunction 建表示例
-- 【原理】SimpleAggregateFunction(Sum, T) 列存普通值，
--   但引擎 merge 时自动 sum，省去反序列化开销
DROP TABLE IF EXISTS orders_daily_simple;

CREATE TABLE orders_daily_simple (
    d Date,
    category String,
    total_amount SimpleAggregateFunction(Sum, Decimal(10, 2)),
    max_amount SimpleAggregateFunction(Max, Decimal(10, 2)),
    min_amount SimpleAggregateFunction(Min, Decimal(10, 2))
) ENGINE = AggregatingMergeTree()
ORDER BY (category, d);

INSERT INTO orders_daily_simple
SELECT
    toDate('2024-01-15') AS d,
    category,
    sumSimpleState(amount) AS total_amount,
    maxSimpleState(amount) AS max_amount,
    minSimpleState(amount) AS min_amount
FROM orders
WHERE id <= 5
GROUP BY category;

-- 查询：直接 SELECT 即可，无需 sumMerge
-- 【对比】普通状态表需要 sumMerge，SimpleState 表直接出数
SELECT
    d,
    category,
    total_amount,
    max_amount,
    min_amount
FROM orders_daily_simple
ORDER BY category;

-- 7.3 SimpleState 支持的聚合函数
-- 【列表】sumSimpleState / maxSimpleState / minSimpleState /
--         anySimpleState / anyLastSimpleState / countSimpleState
-- 不支持：avgSimpleState（avg 不是简单聚合，需 sum/count 组合）
-- 不支持：uniqSimpleState（uniq 是 HLL 算法，非简单值）


-- ============================================================
-- 8. -Distinct 组合子：去重聚合
-- ============================================================
-- 【原理】-Distinct 组合子对聚合函数的输入值去重后再聚合。
--   与 DISTINCT 关键字不同，-Distinct 是聚合函数级别的去重。
-- 【场景】需要去重但不需要精确 UNIQ 的场景
-- 【对比】countDistinct = count(DISTINCT col) 的别名
--         sumDistinct = 对去重后的值求和

-- 8.1 countDistinct：去重计数
-- 【原理】等价于 count(DISTINCT col)，但更简洁
SELECT
    category,
    countDistinct(region) AS distinct_regions,
    -- 等价写法
    count(DISTINCT region) AS distinct_regions_alt,
    uniq(region) AS uniq_regions
FROM orders
GROUP BY category
ORDER BY category;

-- 8.2 sumDistinct：去重后求和
-- 【场景】对去重后的金额求和（每个唯一值只加一次）
SELECT
    category,
    sum(amount) AS sum_all,
    sumDistinct(amount) AS sum_distinct,
    -- 如果金额有重复，sumDistinct < sum_all
    count(amount) AS count_all,
    countDistinct(amount) AS count_distinct
FROM orders
GROUP BY category
ORDER BY category;

-- 8.3 avgDistinct / minDistinct / maxDistinct
SELECT
    category,
    avg(amount) AS avg_all,
    avgDistinct(amount) AS avg_distinct,
    minDistinct(amount) AS min_distinct,
    maxDistinct(amount) AS max_distinct
FROM orders
GROUP BY category
ORDER BY category;


-- ============================================================
-- 9. -OrDefault 组合子：默认值聚合
-- ============================================================
-- 【原理】-OrDefault 组合子在聚合结果为空时返回默认值
--   （0 或空字符串）而非 NULL。
--   等价于 COALESCE(agg(x), 0)，但更简洁。
-- 【场景】报表中避免 NULL 显示、"无数据"时显示 0

-- 9.1 sumOrDefault / countOrDefault
-- 【场景】某些品类无数据时返回 0 而非 NULL
SELECT
    category,
    -- 如果某品类在给定条件下无数据，返回 0
    sumOrDefault(amount) AS total_or_zero,
    countOrDefault() AS count_or_zero
FROM orders
WHERE region = 'Unknown'  -- 无匹配数据
GROUP BY category;

-- 9.2 对比：有数据时的行为（与普通聚合一致）
SELECT
    category,
    sumOrDefault(amount) AS total_or_zero,
    sum(amount) AS total
FROM orders
WHERE region = 'North'
GROUP BY category
ORDER BY category;

-- 9.3 典型场景：左侧 JOIN 后的空值兜底
-- 【场景】品类维表 JOIN 订单表，无订单的品类显示 0
SELECT
    cat.category,
    sumOrDefault(ord.amount) AS total_amount,
    countOrDefault(ord.id) AS order_count
FROM (
    SELECT arrayJoin(['Electronics', 'Clothing', 'Books', 'Furniture', 'Toys']) AS category
) AS cat
LEFT JOIN orders AS ord ON cat.category = ord.category
GROUP BY cat.category
ORDER BY cat.category;
-- 【结果解读】Furniture 和 Toys 无订单数据，但显示 0 而非 NULL


-- ============================================================
-- 10. 组合子链式使用（核心进阶）
-- ============================================================
-- 【原理】组合子可以链式叠加，多个组合子同时修饰一个聚合函数。
--   语法：aggFunction + 组合子1 + 组合子2 + ...
--   执行顺序：从右到左（最右边的组合子最先应用）
-- 【场景】多级条件聚合、条件状态聚合

-- 10.1 sumIfState：条件 + 状态
-- 【原理】先应用 -If 做条件过滤，再应用 -State 存状态
-- 【场景】物化视图中只聚合有效订单的状态
SELECT
    category,
    sumIfState(amount, is_valid = 1) AS valid_gmv_state
FROM orders
GROUP BY category
ORDER BY category;

-- 10.2 uniqIfMerge：条件去重状态的合并
-- 【场景】合并多个分片的条件去重状态
SELECT
    category,
    uniqIfMerge(uv_state) AS valid_uv
FROM (
    SELECT
        category,
        uniqIfState(id, is_valid = 1) AS uv_state
    FROM orders
    GROUP BY category
)
GROUP BY category
ORDER BY category;

-- 10.3 sumIfMergeState：条件 + 状态 + 可再合并状态
-- 【原理】链式组合子：sum + If + MergeState
--   先条件过滤 → 状态化 → 合并后仍保持状态
-- 【场景】多级聚合中每层都带条件

-- 10.4 常用链式组合子组合
-- 【汇总】
--   组合子链               | 效果
--   ----------------------|-------------------------------
--   sumIf(x, cond)        | 条件求和
--   sumIfState(x, cond)   | 条件求和的状态
--   sumIfMerge(s)         | 合并条件求和状态
--   sumIfMergeState(s)    | 合并条件求和状态后仍保持状态
--   uniqIf(x, cond)       | 条件去重计数
--   uniqIfState(x, cond)  | 条件去重计数状态
--   uniqIfMerge(s)        | 合并条件去重状态
--   countDistinctIf(x, cond) | 条件去重计数（等价于 uniqIf）

-- 10.5 链式组合子完整示例：三级聚合管道
-- 级别1：明细 → 日表（条件 + 状态）
DROP TABLE IF EXISTS daily_agg;

CREATE TABLE daily_agg (
    d Date,
    category String,
    valid_gmv_state AggregateFunction(sumIf, Decimal(10, 2), UInt8),
    valid_cnt_state AggregateFunction(countIf, UInt8)
) ENGINE = AggregatingMergeTree()
ORDER BY (category, d);

INSERT INTO daily_agg
SELECT
    toDate('2024-01-15') AS d,
    category,
    sumIfState(amount, is_valid = 1) AS valid_gmv_state,
    countIfState(is_valid = 1) AS valid_cnt_state
FROM orders
GROUP BY category;

-- 查询日表
SELECT
    d,
    category,
    sumIfMerge(valid_gmv_state) AS valid_gmv,
    countIfMerge(valid_cnt_state) AS valid_cnt
FROM daily_agg
GROUP BY d, category
ORDER BY category;


-- ============================================================
-- 11. 性能对比：普通聚合 vs 组合子聚合
-- ============================================================
-- 【原理】组合子聚合（如 sumIf）比"普通聚合 + if 嵌套"更高效：
--   1. 组合子是聚合函数内置的过滤逻辑，在聚合循环内部判断
--   2. 嵌套 if 先生成中间列再聚合，多一次表达式计算
--   3. 组合子避免了 if 函数的条件判断开销（对每一行）
-- 【场景】大数据量下，sumIf 比 sum(if(...)) 快 1.5~3x

-- 11.1 对比：sumIf vs sum(if(...))
-- 【结果解读】sumIf 写法更简洁，内部执行计划更优
SELECT
    category,
    -- 推荐：组合子风格
    sumIf(amount, is_valid = 1) AS sumif_style,
    -- 等价但不推荐：嵌套 if 风格
    sum(if(is_valid = 1, amount, 0)) AS if_style,
    -- 组合子风格：countIf
    countIf(is_valid = 1) AS countif_style,
    -- 等价但不推荐
    count(if(is_valid = 1, 1, NULL)) AS count_if_style
FROM orders
GROUP BY category
ORDER BY category;

-- 【性能结论】
--   方案                    | 扫描方式        | 推荐度
--   ------------------------|-----------------|-------
--   sumIf(x, cond)          | 聚合内过滤      | ⭐⭐⭐ 推荐
--   sum(if(cond, x, 0))     | 每行 if 计算    | ⭐⭐  兜底
--   WHERE cond + 两次查询   | 两次全表扫描    | ⭐    不推荐

-- 11.2 对比：-Array vs arrayJoin + 聚合
-- 【原理】-Array 组合子在聚合函数内部处理数组，不产生中间行
--   arrayJoin + 聚合 = 先展开成多行再聚合，中间结果量大
-- 【结论】-Array 组合子对于数组聚合更高效

-- 11.3 对比：-Distinct vs uniq
-- 【原理】countDistinct 本质是 count(DISTINCT col) 的语法糖
--   uniq 是近似去重（HLL），内存恒定，大数据量推荐
-- 【结论】
--   小数据量：countDistinct / count(DISTINCT col) 精确
--   大数据量：uniq 近似（误差 <1%，内存恒定）
--   超大去重：uniqExact 精确但耗内存


-- ============================================================
-- 12. 组合子全景图
-- ============================================================
-- 【原理】所有组合子一览：
--
--   组合子          | 作用                    | 常用搭配
--   ----------------|------------------------|-------------------
--   -If             | 条件过滤                | sumIf, countIf, avgIf, uniqIf
--   -Array          | 数组元素聚合            | sumArray, uniqArray
--   -State          | 存中间状态              | sumState, countState, uniqState
--   -Merge          | 合并状态出结果          | sumMerge, countMerge, uniqMerge
--   -MergeState     | 合并后仍保持状态        | sumMergeState, uniqMergeState
--   -ForEach        | 逐位置聚合              | sumForEach, avgForEach
--   -Resample       | 时间窗口重采样          | sumResample, countResample
--   -SimpleState    | 简化版状态（普通值）    | sumSimpleState, maxSimpleState
--   -Distinct       | 去重后聚合              | countDistinct, sumDistinct
--   -OrDefault      | 空值返回默认值          | sumOrDefault, countOrDefault
--
--   链式规则：
--     -If 可以和其他组合子链式使用
--     -State 和 -Merge 互斥（不能同时用）
--     -Distinct 可以和 -If 链式（countDistinctIf）
--     -State 后的状态只能被 -Merge 或 -MergeState 消费

-- 12.1 组合子选型决策树
-- 【决策逻辑】
--   需要条件过滤？ → 是 → -If
--     还需要状态？ → 是 → -IfState
--   输入是数组？ → 是 → -Array 或 -ForEach
--     按位置聚合？ → 是 → -ForEach
--     跨元素聚合？ → 是 → -Array
--   需要预聚合？ → 是 → -State / -SimpleState
--     需要多级合并？ → 是 → -State（-MergeState 二级）
--     简单聚合（sum/max/min）？ → 是 → -SimpleState
--   需要去重？ → 是 → -Distinct 或 uniq
--   空值需兜底？ → 是 → -OrDefault
--   时间窗口重采样？ → 是 → -Resample


-- ============================================================
-- 13. 清理
-- ============================================================
DROP DATABASE IF EXISTS func_test;