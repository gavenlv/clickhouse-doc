-- ================================================
-- 01_mergetree_engines.sql
-- ClickHouse MergeTree 系列表引擎示例
-- ================================================

-- ========================================
-- 1. MergeTree（基础引擎）
-- ========================================

-- 创建 MergeTree 表
CREATE TABLE IF NOT EXISTS engine_test.mergetree_events (
    event_id UInt64,
    user_id UInt64,
    event_type String,
    event_data String,
    timestamp DateTime
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(timestamp)
ORDER BY (user_id, event_type, timestamp)
SETTINGS index_granularity = 8192;

-- 插入测试数据
INSERT INTO engine_test.mergetree_events (event_id, user_id, event_type, event_data, timestamp) VALUES
(1, 1, 'click', '{"page":"home"}', '2024-01-01 10:00:00'),
(2, 1, 'view', '{"page":"products"}', '2024-01-01 10:05:00'),
(3, 2, 'click', '{"page":"products"}', '2024-01-01 11:00:00'),
(4, 3, 'purchase', '{"product_id":101,"amount":99.99}', '2024-01-01 12:00:00'),
(5, 1, 'logout', '{"duration":3600}', '2024-01-02 09:00:00'),
(6, 4, 'login', '{"ip":"192.168.1.1"}', '2024-01-02 10:00:00'),
(7, 5, 'search', '{"query":"laptop"}', '2024-01-02 11:00:00'),
(8, 2, 'add_to_cart', '{"product_id":102}', '2024-01-03 14:00:00'),
(9, 3, 'purchase', '{"product_id":103,"amount":149.99}', '2024-01-03 15:00:00'),
(10, 6, 'click', '{"page":"about"}', '2024-01-04 16:00:00');

-- 查询数据
SELECT * FROM engine_test.mergetree_events ORDER BY event_id;

-- 性能查询：利用分区剪枝
SELECT
    toDate(timestamp) as event_day,
    count() as event_count
FROM engine_test.mergetree_events
WHERE timestamp >= '2024-01-01'
  AND timestamp < '2024-01-03'
GROUP BY event_day
ORDER BY event_day;

-- 性能查询：利用排序键
SELECT
    user_id,
    event_type,
    count() as event_count
FROM engine_test.mergetree_events
WHERE user_id = 1
  AND event_type = 'click'
GROUP BY user_id, event_type;

-- 查看表结构
SHOW CREATE engine_test.mergetree_events;

-- 查看分区信息
SELECT
    partition,
    name,
    rows,
    bytes_on_disk,
    modification_time
FROM system.parts
WHERE table = 'mergetree_events'
  AND database = 'engine_test'
  AND active = 1
ORDER BY partition;

-- ========================================
-- 2. ReplacingMergeTree（去重引擎）
-- ========================================

-- 创建 ReplacingMergeTree 表
CREATE TABLE IF NOT EXISTS engine_test.replacing_user_state (
    user_id UInt64,
    state String,
    last_updated DateTime,
    version UInt64
) ENGINE = ReplacingMergeTree(version)
PARTITION BY toYYYYMM(last_updated)
ORDER BY user_id;

-- 插入数据（包含重复）
INSERT INTO engine_test.replacing_user_state VALUES
(1, 'online', '2024-01-01 10:00:00', 1),
(2, 'offline', '2024-01-01 11:00:00', 1),
(3, 'busy', '2024-01-01 12:00:00', 1);

-- 更新用户状态（插入新版本）
INSERT INTO engine_test.replacing_user_state VALUES
(1, 'busy', '2024-01-01 10:30:00', 2),
(2, 'online', '2024-01-01 11:30:00', 2),
(4, 'away', '2024-01-01 13:00:00', 1);

-- 查询原始数据（可以看到重复）
SELECT * FROM engine_test.replacing_user_state ORDER BY user_id, version;

-- 查询去重后的数据（使用 FINAL）
SELECT * FROM engine_test.replacing_user_state FINAL ORDER BY user_id;

-- 手动触发合并（强制去重）
OPTIMIZE TABLE engine_test.replacing_user_state FINAL;

-- 再次查询（已合并）
SELECT * FROM engine_test.replacing_user_state ORDER BY user_id;

-- ========================================
-- 3. SummingMergeTree（求和引擎）
-- ========================================

-- 创建 SummingMergeTree 表
CREATE TABLE IF NOT EXISTS engine_test.summing_daily_sales (
    date Date,
    product_id UInt32,
    country String,
    amount Decimal(10, 2),
    order_count UInt32
) ENGINE = SummingMergeTree()
PARTITION BY toYYYYMM(date)
ORDER BY (date, product_id, country);

-- 插入销售数据
INSERT INTO engine_test.summing_daily_sales VALUES
('2024-01-01', 101, 'US', 99.99, 1),
('2024-01-01', 101, 'US', 99.99, 1),
('2024-01-01', 101, 'US', 99.99, 1),
('2024-01-01', 102, 'US', 49.99, 1),
('2024-01-01', 102, 'UK', 59.99, 1),
('2024-01-02', 101, 'US', 199.99, 1),
('2024-01-02', 103, 'UK', 79.99, 1);

-- 查询原始数据（可以看到重复）
SELECT * FROM engine_test.summing_daily_sales ORDER BY date, product_id, country;

-- 查询聚合后的数据（使用 FINAL）
SELECT * FROM engine_test.summing_daily_sales FINAL ORDER BY date, product_id, country;

-- 手动触发合并
OPTIMIZE TABLE engine_test.summing_daily_sales FINAL;

-- 按日期和产品查询（已自动求和）
SELECT
    date,
    product_id,
    sum(amount) as total_amount,
    sum(order_count) as total_orders
FROM engine_test.summing_daily_sales
GROUP BY date, product_id
ORDER BY date, product_id;

-- ========================================
-- 4. AggregatingMergeTree（高级聚合引擎）
-- ========================================

-- 创建 AggregatingMergeTree 表
CREATE TABLE IF NOT EXISTS engine_test.aggregating_user_metrics (
    user_id UInt64,
    event_date Date,
    -- 聚合状态列
    page_views AggregateFunction(count),
    distinct_pages AggregateFunction(uniq, String),
    total_time AggregateFunction(sum, UInt64)
) ENGINE = AggregatingMergeTree()
PARTITION BY toYYYYMM(event_date)
ORDER BY (user_id, event_date);

-- 插入聚合状态数据
INSERT INTO engine_test.aggregating_user_metrics
SELECT
    user_id,
    toDate(timestamp) as event_date,
    countState() as page_views,
    uniqState(event_type) as distinct_pages,
    sumState(length(event_data)) as total_time
FROM engine_test.mergetree_events
GROUP BY user_id, toDate(timestamp);

-- 查询聚合状态
SELECT
    user_id,
    event_date,
    page_views,
    distinct_pages,
    total_time
FROM engine_test.aggregating_user_metrics
ORDER BY user_id, event_date;

-- 合并并查询聚合结果
SELECT
    user_id,
    event_date,
    countMerge(page_views) as total_page_views,
    uniqMerge(distinct_pages) as distinct_event_types,
    sumMerge(total_time) as total_data_size
FROM engine_test.aggregating_user_metrics
GROUP BY user_id, event_date
ORDER BY user_id, event_date;

-- ========================================
-- 5. CollapsingMergeTree（折叠引擎）
-- ========================================

-- 创建 CollapsingMergeTree 表
CREATE TABLE IF NOT EXISTS engine_test.collapsing_inventory (
    product_id UInt64,
    quantity_change Int32,
    sign Int8, -- 1 for insert, -1 for delete
    timestamp DateTime
) ENGINE = CollapsingMergeTree(sign)
PARTITION BY toYYYYMM(timestamp)
ORDER BY product_id;

-- 插入初始库存
INSERT INTO engine_test.collapsing_inventory VALUES
(101, 100, 1, '2024-01-01 10:00:00'),
(102, 50, 1, '2024-01-01 10:00:00'),
(103, 75, 1, '2024-01-01 10:00:00');

-- 销售商品（使用负的 sign）
INSERT INTO engine_test.collapsing_inventory VALUES
(101, 10, -1, '2024-01-01 11:00:00'),
(102, 5, -1, '2024-01-01 11:00:00');

-- 再次进货（使用正的 sign）
INSERT INTO engine_test.collapsing_inventory VALUES
(101, 20, 1, '2024-01-01 12:00:00'),
(103, 10, 1, '2024-01-01 12:00:00');

-- 查询原始数据
SELECT * FROM engine_test.collapsing_inventory ORDER BY product_id, timestamp;

-- 查询折叠后的库存（使用 GROUP BY）
SELECT
    product_id,
    sum(quantity_change * sign) as current_inventory
FROM engine_test.collapsing_inventory
GROUP BY product_id
ORDER BY product_id;

-- ========================================
-- 6. VersionedCollapsingMergeTree（版本折叠引擎）
-- ========================================

-- 创建 VersionedCollapsingMergeTree 表
CREATE TABLE IF NOT EXISTS engine_test.versioned_collapsing_user_scores (
    user_id UInt64,
    score_change Int32,
    sign Int8,
    version UInt64,
    timestamp DateTime
) ENGINE = VersionedCollapsingMergeTree(sign, version)
PARTITION BY toYYYYMM(timestamp)
ORDER BY user_id;

-- 插入初始分数
INSERT INTO engine_test.versioned_collapsing_user_scores VALUES
(1, 100, 1, 1, '2024-01-01 10:00:00'),
(2, 150, 1, 1, '2024-01-01 10:00:00'),
(3, 200, 1, 1, '2024-01-01 10:00:00');

-- 更新分数（先删除旧版本，再插入新版本）
INSERT INTO engine_test.versioned_collapsing_user_scores VALUES
(1, -100, -1, 1, '2024-01-01 11:00:00'), -- 删除版本 1
(1, 120, 1, 2, '2024-01-01 11:00:00'),   -- 插入版本 2
(2, -150, -1, 1, '2024-01-01 11:00:00'),
(2, 160, 1, 2, '2024-01-01 11:00:00');

-- 查询原始数据
SELECT * FROM engine_test.versioned_collapsing_user_scores ORDER BY user_id, version;

-- 查询最新分数
SELECT
    user_id,
    sum(score_change * sign) as current_score
FROM engine_test.versioned_collapsing_user_scores
GROUP BY user_id
ORDER BY user_id;

-- ========================================
-- 7. GraphiteMergeTree（Graphite 数据引擎）
-- ========================================

/*
GraphiteMergeTree 专为 Graphite 监控数据设计，用于存储和聚合时序指标数据。

配置示例:
CREATE TABLE IF NOT EXISTS graphite.data (
    Path String,
    Time UInt32,
    Value Float64,
    Version UInt32
) ENGINE = GraphiteMergeTree('graphite_rollup')
PARTITION BY toYYYYMM(toDateTime(Time))
ORDER BY (Path, Time);

-- graphite_rollup 配置需要在 config.xml 中定义
<graphite_rollup>
    <path_column_name>Path</path_column_name>
    <time_column_name>Time</time_column_name>
    <value_column_name>Value</value_column_name>
    <version_column_name>Version</version_column_name>

    <default>
        <function>avg</function>
        <retention>
            <age>0</age>
            <precision>60</precision>
        </retention>
        <retention>
            <age>2592000</age>
            <precision>300</precision>
        </retention>
        <retention>
            <age>7776000</age>
            <precision>3600</precision>
        </retention>
    </default>
</graphite_rollup>
*/

-- ========================================
-- 8. 引擎对比示例
-- ========================================

-- 创建相同的表，使用不同的引擎
CREATE TABLE IF NOT EXISTS engine_test.mt_events AS engine_test.mergetree_events
ENGINE = MergeTree()
PARTITION BY toYYYYMM(timestamp)
ORDER BY (user_id, timestamp);

CREATE TABLE IF NOT EXISTS engine_test.rmt_events AS engine_test.mergetree_events
ENGINE = ReplacingMergeTree(event_id)
PARTITION BY toYYYYMM(timestamp)
ORDER BY (user_id, timestamp);

-- 插入相同的测试数据
INSERT INTO engine_test.mt_events SELECT * FROM engine_test.mergetree_events;
INSERT INTO engine_test.rmt_events SELECT * FROM engine_test.mergetree_events;

-- 查询性能对比
-- MergeTree 查询
SELECT count() FROM engine_test.mt_events WHERE user_id = 1;

-- ReplacingMergeTree 查询
SELECT count() FROM engine_test.rmt_events WHERE user_id = 1;

-- ReplacingMergeTree 去重查询（使用 FINAL）
SELECT count() FROM engine_test.rmt_events FINAL WHERE user_id = 1;

-- ========================================
-- 9. 性能测试
-- ========================================

-- 创建大表用于性能测试
CREATE TABLE IF NOT EXISTS engine_test.mt_performance (
    id UInt64,
    group_id UInt32,
    value1 Float64,
    value2 Float64,
    timestamp DateTime
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(timestamp)
ORDER BY (group_id, timestamp)
SETTINGS index_granularity = 8192;

-- 插入大量测试数据
INSERT INTO engine_test.mt_performance SELECT
    number as id,
    number % 100 as group_id,
    rand() * 1000 as value1,
    rand() * 2000 as value2,
    now() - INTERVAL rand() * 30 DAY as timestamp
FROM numbers(100000);

-- 性能测试：分区剪枝
SELECT
    toDate(timestamp) as event_day,
    count() as cnt,
    avg(value1) as avg_val1
FROM engine_test.mt_performance
WHERE timestamp >= now() - INTERVAL 7 DAY
GROUP BY event_day
ORDER BY event_day;

-- 性能测试：排序键查询
SELECT
    group_id,
    count() as cnt,
    sum(value1) as total_val1
FROM engine_test.mt_performance
WHERE group_id = 50
GROUP BY group_id;

-- 性能测试：范围查询
SELECT
    id,
    value1,
    value2
FROM engine_test.mt_performance
WHERE timestamp >= now() - INTERVAL 1 DAY
  AND value1 > 500
ORDER BY value1 DESC
LIMIT 100;

-- ========================================
-- 10. 清理测试表
-- ========================================
DROP TABLE IF EXISTS engine_test.mergetree_events;
DROP TABLE IF EXISTS engine_test.replacing_user_state;
DROP TABLE IF EXISTS engine_test.summing_daily_sales;
DROP TABLE IF EXISTS engine_test.aggregating_user_metrics;
DROP TABLE IF EXISTS engine_test.collapsing_inventory;
DROP TABLE IF EXISTS engine_test.versioned_collapsing_user_scores;
DROP TABLE IF EXISTS engine_test.mt_events;
DROP TABLE IF EXISTS engine_test.rmt_events;
DROP TABLE IF EXISTS engine_test.mt_performance;

-- ========================================
-- 11. MergeTree 引擎最佳实践总结
-- ========================================
/*
MergeTree 系列引擎最佳实践：

1. MergeTree（基础引擎）
   - 适用场景：大多数 OLAP 查询
   - 优点：高性能、支持索引和分区
   - 最佳实践：
     * 合理设计分区键（通常是时间）
     * 优化 ORDER BY 排序键
     * 使用 PREWHERE 优化
     * 定期执行 OPTIMIZE

2. ReplacingMergeTree（去重引擎）
   - 适用场景：需要去重的数据
   - 优点：自动去重（需要手动触发）
   - 注意事项：
     * 去重不是实时的
     * 需要使用 FINAL 或 OPTIMIZE
     * 性能略低于 MergeTree

3. SummingMergeTree（求和引擎）
   - 适用场景：数值列的预聚合
   - 优点：自动求和减少查询计算
   - 注意事项：
     * 只能聚合数值列
     * 排序键中的非数值列保持不变
     * 需要相同的排序键

4. AggregatingMergeTree（高级聚合引擎）
   - 适用场景：复杂的预聚合
   - 优点：支持自定义聚合函数
   - 最佳实践：
     * 使用 AggregateFunction 存储
     * 查询时使用 Merge 函数
     * 与物化视图配合使用

5. CollapsingMergeTree（折叠引擎）
   - 适用场景：增量更新和删除
   - 优点：支持增删改
   - 注意事项：
     * 需要使用 sign 列
     * 查询时需要 GROUP BY
     * 数据可能不立即折叠

6. VersionedCollapsingMergeTree（版本折叠）
   - 适用场景：带版本的增量更新
   - 优点：支持版本控制
   - 注意事项：
     * 比 CollapsingMergeTree 更安全
     * 需要维护版本号
     * 写入更复杂

选择建议：
- 通用场景：MergeTree
- 需要去重：ReplacingMergeTree
- 需要求和：SummingMergeTree
- 复杂聚合：AggregatingMergeTree
- 增量更新：CollapsingMergeTree
- 版本控制：VersionedCollapsingMergeTree
*/
