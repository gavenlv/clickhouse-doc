-- ============================================================
-- 03 - 物化视图深度
-- 描述：物化视图（MV）是 INSERT 时触发的触发器，不是普通视图
-- 适用版本：ClickHouse 25.12+
-- ============================================================

-- 【原理】物化视图的本质
-- ============================================================
-- 1. MV 是 INSERT 触发器：数据写入基表时，自动触发 MV 的 INSERT
-- 2. MV 存储的是预聚合结果，查询时直接读取
-- 3. MV 不是普通视图（普通视图只是保存了 SQL 定义）
-- 4. MV 的数据是物理存储的，占用磁盘空间
-- 5. MV 的数据与基表是独立存储的，不是"视图"
-- 6. MV 的 TO 关键字指定存储表，不指定则自动创建
-- 7. MV 的 POPULATE 关键字会填充历史数据（不推荐使用）
-- ============================================================

DROP DATABASE IF EXISTS modeling_test;
CREATE DATABASE modeling_test;
USE modeling_test;

-- ============================================================
-- 实验一：物化视图 vs Projection 对比
-- ============================================================

-- 【场景】订单数据预聚合，对比 MV 和 Projection 两种方案

-- 基表：订单明细
CREATE TABLE orders
(
    order_id      UInt64,
    user_id       UInt32,
    product_id    UInt32,
    category      String,
    amount        Decimal(10, 2),
    quantity      UInt16,
    order_time    DateTime
)
ENGINE = MergeTree
ORDER BY (user_id, order_time)
PARTITION BY toYYYYMM(order_time);

-- 方案 A：物化视图
CREATE MATERIALIZED VIEW mv_orders_daily
ENGINE = SummingMergeTree
ORDER BY (category, order_date)
PARTITION BY toYYYYMM(order_date)
AS SELECT
    category,
    toDate(order_time) AS order_date,
    count() AS order_count,
    sum(amount) AS total_amount,
    sum(quantity) AS total_quantity,
    avg(amount) AS avg_amount
FROM orders
GROUP BY category, toDate(order_time);

-- 方案 B：Projection（CH 25.12 支持）
-- Projection 是存储在基表内部的预聚合，查询时自动匹配
ALTER TABLE orders ADD PROJECTION prj_orders_daily
(
    SELECT
        category,
        toDate(order_time) AS order_date,
        count() AS order_count,
        sum(amount) AS total_amount,
        sum(quantity) AS total_quantity,
        avg(amount) AS avg_amount
    GROUP BY category, toDate(order_time)
);

-- 物化 Projection 需要触发
ALTER TABLE orders MATERIALIZE PROJECTION prj_orders_daily;

-- 【对比】MV vs Projection
-- ============================================================
-- MV:
--   + 独立存储，查询时直接读取
--   + 可以跨表 JOIN
--   + 可以设置不同的排序键和分区键
--   - 需要手动维护
--   - 历史数据需要手动补齐
--   - ALTER 困难，需要 DROP 重建
--
-- Projection:
--   + 自动维护，与基表数据一致
--   + 查询自动匹配，无需指定表名
--   + 基表数据变化自动同步
--   - 只能对单表做聚合
--   - 聚合函数有限制
--   - 不能指定不同的排序键
-- ============================================================

-- 插入测试数据
INSERT INTO orders SELECT
    number AS order_id,
    number % 10000 AS user_id,
    number % 500 AS product_id,
    ['Electronics', 'Clothing', 'Food', 'Books'][(number % 4) + 1] AS category,
    toDecimal32((rand() % 1000) + 1, 2) AS amount,
    toUInt16((rand() % 10) + 1) AS quantity,
    toDateTime('2024-01-01 00:00:00') + (number % 365) * 86400 + (rand() % 86400) AS order_time
FROM system.numbers
LIMIT 500000;

-- 查询物化视图（直接读取预聚合结果）
SELECT '【MV 查询】每日各类别订单统计:';
SELECT category, order_date, order_count, total_amount, total_quantity
FROM mv_orders_daily
WHERE category = 'Electronics' AND order_date >= '2024-06-01'
ORDER BY order_date
LIMIT 10;

-- 查询原始表（对比性能）
SELECT '【原始表查询】每日各类别订单统计:';
SELECT category, toDate(order_time) AS order_date,
       count() AS order_count, sum(amount) AS total_amount
FROM orders
WHERE category = 'Electronics' AND order_time >= '2024-06-01'
GROUP BY category, toDate(order_time)
ORDER BY order_date
LIMIT 10;

-- ============================================================
-- 实验二：多级聚合链（日→月→年）
-- ============================================================

-- 【场景】三级聚合：原始数据 → 日汇总 → 月汇总 → 年汇总

-- 第一级：原始数据 → 日汇总
CREATE MATERIALIZED VIEW mv_daily_summary
ENGINE = SummingMergeTree
ORDER BY (category, report_date)
PARTITION BY toYYYYMM(report_date)
AS SELECT
    category,
    toDate(order_time) AS report_date,
    count() AS order_count,
    sum(amount) AS total_amount,
    sum(quantity) AS total_quantity
FROM orders
GROUP BY category, toDate(order_time);

-- 第二级：日汇总 → 月汇总
CREATE MATERIALIZED VIEW mv_monthly_summary
ENGINE = SummingMergeTree
ORDER BY (category, report_month)
PARTITION BY toYYYYMM(report_month)
AS SELECT
    category,
    toStartOfMonth(report_date) AS report_month,
    sum(order_count) AS order_count,
    sum(total_amount) AS total_amount,
    sum(total_quantity) AS total_quantity
FROM mv_daily_summary
GROUP BY category, toStartOfMonth(report_date);

-- 第三级：月汇总 → 年汇总
CREATE MATERIALIZED VIEW mv_yearly_summary
ENGINE = SummingMergeTree
ORDER BY (category, report_year)
PARTITION BY toYYYYMM(report_year)
AS SELECT
    category,
    toStartOfYear(report_month) AS report_year,
    sum(order_count) AS order_count,
    sum(total_amount) AS total_amount,
    sum(total_quantity) AS total_quantity
FROM mv_monthly_summary
GROUP BY category, toStartOfYear(report_month);

-- 查询三级聚合结果
SELECT '【三级聚合】日汇总:';
SELECT report_date, category, order_count, total_amount
FROM mv_daily_summary
WHERE category = 'Electronics' AND report_date >= '2024-06-01'
ORDER BY report_date
LIMIT 5;

SELECT '【三级聚合】月汇总:';
SELECT report_month, category, order_count, total_amount
FROM mv_monthly_summary
WHERE category = 'Electronics'
ORDER BY report_month;

SELECT '【三级聚合】年汇总:';
SELECT report_year, category, order_count, total_amount
FROM mv_yearly_summary
WHERE category = 'Electronics'
ORDER BY report_year;

-- 【坑】多级聚合链的延迟问题
-- 下级 MV 依赖上级 MV 的数据，数据需要逐级传递
-- 写入基表后，数据需要经过多级 MV 处理，才能到达最下层
-- 实时性要求高的场景不适合长链

-- ============================================================
-- 实验三：State / Merge 函数在 MV 中的使用
-- ============================================================

-- 【场景】使用 *State 和 *Merge 函数实现灵活聚合

-- 【原理】*State 和 *Merge 函数
-- *State：将聚合状态存储为二进制数据（AggregateFunction 类型）
-- *Merge：将聚合状态合并为最终结果
-- 适用于需要多层聚合或自定义聚合的场景

-- 基表：网页访问日志
CREATE TABLE page_views
(
    page_url    String,
    user_id     UInt32,
    duration_ms UInt32,
    view_time   DateTime
)
ENGINE = MergeTree
ORDER BY (user_id, view_time);

-- 使用 AggregateFunction 类型存储聚合状态
CREATE MATERIALIZED VIEW mv_page_stats
ENGINE = MergeTree
ORDER BY (page_url, view_date)
AS SELECT
    page_url,
    toDate(view_time) AS view_date,
    countState() AS view_count,           -- count() 的聚合状态
    sumState(duration_ms) AS total_duration,  -- sum() 的聚合状态
    avgState(duration_ms) AS avg_duration,    -- avg() 的聚合状态
    minState(duration_ms) AS min_duration,    -- min() 的聚合状态
    maxState(duration_ms) AS max_duration,    -- max() 的聚合状态
    uniqState(user_id) AS unique_users        -- 精确去重的聚合状态
FROM page_views
GROUP BY page_url, toDate(view_time);

-- 插入数据
INSERT INTO page_views SELECT
    concat('/page_', toString(number % 50)) AS page_url,
    number % 10000 AS user_id,
    rand() % 30000 AS duration_ms,
    toDateTime('2024-01-01 00:00:00') + (number % 365) * 86400 + (rand() % 86400) AS view_time
FROM system.numbers
LIMIT 200000;

-- 查询时使用 *Merge 函数还原聚合结果
SELECT '【State/Merge 查询】聚合结果:';
SELECT
    page_url,
    view_date,
    countMerge(view_count) AS view_count,
    sumMerge(total_duration) AS total_duration_ms,
    avgMerge(avg_duration) AS avg_duration_ms,
    minMerge(min_duration) AS min_duration_ms,
    maxMerge(max_duration) AS max_duration_ms,
    uniqMerge(unique_users) AS unique_users
FROM mv_page_stats
GROUP BY page_url, view_date
ORDER BY view_count DESC
LIMIT 10;

-- 【优势】State/Merge 模式的优势
-- 1. 可以灵活组合多种聚合函数
-- 2. 支持精确去重（uniq）
-- 3. 可以进一步做二次聚合
-- 例如：从日汇总再聚合到月汇总

CREATE MATERIALIZED VIEW mv_page_monthly_stats
ENGINE = MergeTree
ORDER BY (page_url, view_month)
AS SELECT
    page_url,
    toStartOfMonth(view_date) AS view_month,
    countMerge(view_count) AS view_count,
    sumMerge(total_duration) AS total_duration,
    avgMerge(avg_duration) AS avg_duration,
    uniqMerge(unique_users) AS unique_users
FROM mv_page_stats
GROUP BY page_url, toStartOfMonth(view_date);

-- 【坑】AggregateFunction 类型的列不能直接查询
-- 必须要用对应的 *Merge 函数解析
-- 如果直接 SELECT 会看到二进制数据

-- ============================================================
-- 实验四：物化视图的局限与坑
-- ============================================================

-- 【坑 1】MV 无法直接 ALTER
-- 物化视图的 SELECT 定义无法修改
-- 如果需要修改，只能 DROP 后重建
-- DROP VIEW mv_orders_daily;
-- CREATE MATERIALIZED VIEW mv_orders_daily_new ...

-- 【坑 2】MV 数据与基表可能不一致
-- 1. 如果基表数据被 ALTER TABLE UPDATE 修改，MV 不会同步
-- 2. 如果基表数据被 DELETE，MV 不会同步
-- 3. 如果 MV 的底层表被手动修改，可能导致不一致

-- 演示：修改基表数据，MV 不会同步
-- 假设我们更新基表数据
-- ALTER TABLE orders UPDATE amount = 0 WHERE category = 'Food';
-- 此时 MV mv_orders_daily 中的数据仍然保持旧值

-- 【坑 3】POPULATE 可能导致数据丢失
-- 使用 POPULATE 关键字创建 MV 时，如果在创建过程中有新数据写入
-- 这些新数据可能被跳过，导致数据丢失
-- 推荐做法：先创建 MV（不带 POPULATE），再手动插入历史数据

-- 正确的 MV 创建流程
-- 1. 创建 MV（不带 POPULATE）
-- 2. 手动 INSERT 历史数据到 MV
-- 3. 后续新数据自动通过 MV 触发器同步

-- 【坑 4】MV 的存储空间
-- MV 物理存储数据，会占用额外的磁盘空间
-- 需要评估 MV 的存储成本

-- 查看 MV 存储大小
SELECT '【MV 存储大小】:';
SELECT table, formatReadableSize(sum(bytes_on_disk)) AS size
FROM system.parts
WHERE database = 'modeling_test' AND table LIKE 'mv_%'
GROUP BY table
ORDER BY table;

-- ============================================================
-- 实验五：TO 关键字指定存储表
-- ============================================================

-- 【场景】使用 TO 关键字手动指定 MV 的存储表

-- 先创建存储表
CREATE TABLE mv_storage_daily
(
    category      String,
    report_date   Date,
    order_count   UInt64,
    total_amount  Decimal(18, 2),
    total_quantity UInt64
)
ENGINE = SummingMergeTree
ORDER BY (category, report_date);

-- 创建 MV 并指定 TO 存储表
CREATE MATERIALIZED VIEW mv_with_to TO mv_storage_daily
AS SELECT
    category,
    toDate(order_time) AS report_date,
    count() AS order_count,
    sum(amount) AS total_amount,
    sum(quantity) AS total_quantity
FROM orders
GROUP BY category, toDate(order_time);

-- 【优势】使用 TO 的 MV
-- 1. 可以手动管理存储表的结构
-- 2. 可以给存储表加索引
-- 3. 可以修改存储表的 TTL 和分区策略
-- 4. 可以手动插入数据到存储表

-- 手动插入数据到存储表（MV 之外的补充数据）
INSERT INTO mv_storage_daily VALUES
    ('Electronics', '2024-12-25', 100, 50000.00, 200);

-- 查询存储表（包含 MV 自动写入和手动插入的数据）
SELECT '【TO 存储表】查询结果:';
SELECT category, report_date, order_count, total_amount
FROM mv_storage_daily
WHERE category = 'Electronics' AND report_date >= '2024-06-01'
ORDER BY report_date
LIMIT 10;

-- ============================================================
-- 结论：物化视图使用指南
-- ============================================================
-- 1. MV 本质是 INSERT 触发器，不是"视图"
-- 2. MV 适合做预聚合，不适合做复杂 ETL
-- 3. 多级聚合链可逐层减少数据量，但有延迟
-- 4. *State/*Merge 函数提供灵活的聚合能力
-- 5. 使用 TO 关键字指定存储表，便于管理
-- 6. 避免使用 POPULATE，手动填充历史数据更安全
-- 7. MV 无法同步基表的 UPDATE/DELETE 操作
-- 8. MV 的 ALTER 只能 DROP 重建

SELECT 'DONE - 物化视图深度实验完成';

DROP DATABASE IF EXISTS modeling_test;