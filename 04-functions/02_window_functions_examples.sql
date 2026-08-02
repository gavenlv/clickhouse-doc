-- ============================================================
-- 文件: 04-functions/02_window_functions_examples.sql
-- 学习目标: 掌握窗口函数原理、窗口帧(ROWS vs RANGE)、实战应用
-- 深度标准: 原理 + 场景 + 对比 + 可运行
-- 集群: treasurycluster (CH 25.12.1.649, 2 副本)
-- 前置: 无（自包含测试数据，按顺序执行）
-- ============================================================
--
-- 本文件章节:
--   1.  窗口函数 vs 聚合函数（原理图）
--   2.  排名函数 row_number / rank / dense_rank / ntile
--   3.  聚合窗口函数（累计求和、移动平均）
--   4.  导航函数 lag / lead / first_value / last_value
--   5.  ★ 窗口帧 ROWS vs RANGE（核心难点，含原理图）
--   6.  实战场景（Top-N、环比、滚动汇总）
--   7.  性能对比（窗口函数 vs 自连接）
--   8.  常见误区演示
--   9.  清理
-- ============================================================

CREATE DATABASE IF NOT EXISTS window_functions_test ON CLUSTER 'treasurycluster';
USE window_functions_test;


-- ============================================================
-- 1. 窗口函数 vs 聚合函数（原理）
-- ============================================================
-- 【原理】
--   聚合函数 (GROUP BY): 多行 → 1 行，折叠行数
--     [A:10, A:20, A:30] --GROUP BY A--> [A: sum=60]  (1 行)
--
--   窗口函数 (OVER): 多行 → 多行，不折叠，每行带窗口结果
--     [A:10, A:20, A:30] --OVER(ORDER BY...)-->
--       [A:10 +running=10]
--       [A:20 +running=30]
--       [A:30 +running=60]  (仍 3 行)
--
-- 【场景】排名、累计、环比、移动平均、Top-N、间隔检测
-- 【对比】窗口函数通常比"自连接"实现快（见 §7）

-- ┌─────────────────────────────────────────────────────────────┐
-- │                   窗口函数分类                                │
-- ├─────────────────────────────────────────────────────────────┤
-- │  1. 排名: row_number / rank / dense_rank / ntile             │
-- │  2. 导航: lag / lead / first_value / last_value / nth_value  │
-- │  3. 聚合窗口: sum/avg/count/min/max OVER (...)               │
-- └─────────────────────────────────────────────────────────────┘
--
-- OVER 子句三要素:
--   OVER (
--     [PARTITION BY 列]    -- 分区边界
--     [ORDER BY 列]        -- 决定"前后"语义
--     [frame_clause]       -- 当前行的计算范围
--   )


-- ============================================================
-- 2. 准备测试数据
-- ============================================================
DROP TABLE IF EXISTS sales_window ON CLUSTER 'treasurycluster' SYNC;

CREATE TABLE sales_window ON CLUSTER 'treasurycluster' (
    id UInt64,
    sale_date Date,
    product_id UInt32,
    product_name String,
    category String,
    quantity UInt32,
    price Decimal(10, 2),
    region String,
    salesperson String
) ENGINE = ReplicatedMergeTree()
PARTITION BY toYYYYMM(sale_date)
ORDER BY (product_id, sale_date);

-- 注意: INSERT VALUES 语句内部不能有行内注释，否则解析失败
INSERT INTO sales_window VALUES
    (1, '2024-01-15', 101, 'Laptop', 'Electronics', 2, 999.99, 'North', 'Alice'),
    (2, '2024-01-16', 101, 'Laptop', 'Electronics', 1, 999.99, 'North', 'Alice'),
    (3, '2024-01-17', 102, 'Mouse', 'Electronics', 5, 19.99, 'North', 'Bob'),
    (4, '2024-01-18', 103, 'Monitor', 'Electronics', 3, 299.99, 'North', 'Alice'),
    (5, '2024-01-19', 104, 'Keyboard', 'Electronics', 4, 49.99, 'North', 'Bob'),
    (6, '2024-01-15', 101, 'Laptop', 'Electronics', 1, 999.99, 'South', 'Charlie'),
    (7, '2024-01-16', 105, 'Headphones', 'Electronics', 3, 79.99, 'South', 'Charlie'),
    (8, '2024-01-17', 102, 'Mouse', 'Electronics', 2, 19.99, 'South', 'David'),
    (9, '2024-01-18', 106, 'USB Cable', 'Accessories', 10, 9.99, 'South', 'Charlie'),
    (10, '2024-01-19', 107, 'Webcam', 'Electronics', 2, 59.99, 'South', 'David'),
    (11, '2024-01-15', 103, 'Monitor', 'Electronics', 2, 299.99, 'East', 'Eve'),
    (12, '2024-01-16', 104, 'Keyboard', 'Electronics', 3, 49.99, 'East', 'Frank'),
    (13, '2024-01-17', 105, 'Headphones', 'Electronics', 4, 79.99, 'East', 'Eve'),
    (14, '2024-01-18', 108, 'Power Adapter', 'Accessories', 5, 29.99, 'East', 'Frank'),
    (15, '2024-01-19', 101, 'Laptop', 'Electronics', 1, 999.99, 'East', 'Eve'),
    (16, '2024-02-15', 101, 'Laptop', 'Electronics', 3, 999.99, 'North', 'Alice'),
    (17, '2024-02-16', 102, 'Mouse', 'Electronics', 6, 19.99, 'North', 'Bob'),
    (18, '2024-02-17', 103, 'Monitor', 'Electronics', 2, 299.99, 'North', 'Alice'),
    (19, '2024-02-18', 104, 'Keyboard', 'Electronics', 5, 49.99, 'North', 'Bob'),
    (20, '2024-02-19', 105, 'Headphones', 'Electronics', 4, 79.99, 'North', 'Alice');


-- ============================================================
-- 3. 排名函数 row_number / rank / dense_rank
-- ============================================================
-- 【原理对比】对并列值的处理：
--   row_number: 永远递增，无并列          1, 2, 3, 4
--   rank:       并列同号，跳过后续号        1, 2, 2, 4
--   dense_rank: 并列同号，不跳号           1, 2, 2, 3
-- 【场景】
--   row_number: 分页、取 Top-N、唯一编号
--   rank:       允许跳号的排名（如"第 1/1/3 名"）
--   dense_rank: 连续排名（如"第 1/1/2 名"）

-- 3.1 row_number：唯一编号
SELECT
    sale_date,
    product_name,
    category,
    quantity,
    price,
    salesperson,
    row_number() OVER () AS global_row_num,
    row_number() OVER (PARTITION BY salesperson) AS salesperson_row_num,
    row_number() OVER (PARTITION BY salesperson ORDER BY sale_date) AS salesperson_ordered_row_num
FROM sales_window
ORDER BY salesperson, sale_date;

-- 3.2 rank vs dense_rank（价格并列时行为不同）
SELECT
    category,
    product_name,
    price,
    rank() OVER (PARTITION BY category ORDER BY price DESC) AS rank_price,
    dense_rank() OVER (PARTITION BY category ORDER BY price DESC) AS dense_rank_price,
    row_number() OVER (PARTITION BY category ORDER BY price DESC) AS row_num_price
FROM sales_window
ORDER BY category, price DESC;


-- ============================================================
-- 4. 聚合窗口函数（累计求和、移动平均）
-- ============================================================
-- 【原理】聚合函数 + OVER = 不折叠行，每行得到"窗口内的聚合值"
-- 【关键】ORDER BY 决定累计方向；frame 决定窗口范围（见 §5）

-- 4.1 累计求和（running total）
-- 【关键】显式写 ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
--   避免默认 RANGE 在并列值时跳变（见 §5 误区）
SELECT
    sale_date,
    salesperson,
    product_name,
    quantity,
    price,
    quantity * price AS sale_revenue,
    sum(quantity * price) OVER (
        PARTITION BY salesperson ORDER BY sale_date
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS running_revenue,
    sum(quantity * price) OVER (
        ORDER BY sale_date
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS global_running_revenue
FROM sales_window
ORDER BY salesperson, sale_date;

-- 4.2 移动平均
-- 【原理】ROWS BETWEEN N PRECEDING AND CURRENT ROW = 包含当前行的 N+1 行窗口
SELECT
    sale_date,
    product_name,
    price,
    -- 3 日中心移动平均（前 1 + 当前 + 后 1）
    avg(price) OVER (ORDER BY sale_date ROWS BETWEEN 1 PRECEDING AND 1 FOLLOWING) AS ma_3day_centered,
    -- 3 日尾部移动平均（前 2 + 当前）
    avg(price) OVER (ORDER BY sale_date ROWS BETWEEN 2 PRECEDING AND CURRENT ROW) AS ma_3day_trailing,
    -- 5 日尾部移动平均
    avg(price) OVER (ORDER BY sale_date ROWS BETWEEN 4 PRECEDING AND CURRENT ROW) AS ma_5day_trailing
FROM sales_window
ORDER BY sale_date;

-- 4.3 分区聚合（每行附加该分区的汇总值）
SELECT
    sale_date,
    category,
    product_name,
    price,
    avg(price) OVER (PARTITION BY category) AS category_avg_price,
    min(price) OVER (PARTITION BY category) AS category_min_price,
    max(price) OVER (PARTITION BY category) AS category_max_price,
    count() OVER (PARTITION BY category) AS category_count
FROM sales_window
ORDER BY category, price DESC;


-- ============================================================
-- 5. ★ 窗口帧 ROWS vs RANGE（核心难点）
-- ============================================================
-- 【原理】frame 定义"当前行的计算范围"，有两种单位：
--
--   ROWS: 按物理行位置定位
--     ROWS BETWEEN 1 PRECEDING AND CURRENT ROW
--     → 当前行的前 1 行 + 当前行（共 2 行，不管值是什么）
--
--   RANGE: 按 ORDER BY 列的值范围定位
--     RANGE BETWEEN 100 PRECEDING AND CURRENT ROW
--     → 值在 [当前值-100, 当前值] 范围内的所有行（可能多于 2 行）
--
-- 【最隐蔽的坑】
--   写 ORDER BY 但不写 frame 时，默认 frame 是
--     RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
--   注意是 RANGE 不是 ROWS！当 ORDER BY 列有重复值时，
--   同值的行会被一起算进同一帧，导致"累计值跳变"。
--   做累计求和应显式写 ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW。
--
-- 【对比表】
--   ROWS:  物理行 | 每行独立 | 快 | 移动平均(N 行)
--   RANGE: 值范围 | 同值同帧 | 慢 | 累计到当前"值"

-- 5.1 ROWS vs RANGE 对比演示
-- 【结果解读】注意 rows_2_preceding 按物理行计算，
--   range_default 是默认 RANGE frame（同值同帧），二者在并列值时结果不同
SELECT
    sale_date,
    price,
    -- ROWS: 物理前 2 行 + 当前行
    avg(price) OVER (ORDER BY sale_date ROWS BETWEEN 2 PRECEDING AND CURRENT ROW) AS rows_2_preceding,
    -- 默认 frame (ORDER BY 时 = RANGE UNBOUNDED PRECEDING TO CURRENT ROW)
    -- 注意: RANGE 要求 ORDER BY 列支持偏移计算，Date/数值类型可行，Decimal 受限
    avg(price) OVER (ORDER BY sale_date) AS range_default_cumulative,
    -- 整个分区
    avg(price) OVER (PARTITION BY category ORDER BY sale_date ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) AS category_avg
FROM sales_window
ORDER BY sale_date;

-- 5.2 默认 frame 的"跳变"陷阱演示
-- 【原理】当 sale_date 有重复时，默认 RANGE 会把同日期行一起算进帧
--   对比：ROWS 版本逐行累加，RANGE 版本同日期一起跳
DROP TABLE IF EXISTS frame_trap_demo ON CLUSTER 'treasurycluster' SYNC;

CREATE TABLE frame_trap_demo ON CLUSTER 'treasurycluster' (
    d Date,
    v UInt32
) ENGINE = ReplicatedMergeTree ORDER BY d;

-- 注意: 下方有两行同日期('2024-01-01')用于演示 RANGE 跳变
INSERT INTO frame_trap_demo VALUES
    ('2024-01-01', 10),
    ('2024-01-01', 20),
    ('2024-01-02', 30),
    ('2024-01-02', 40);

SELECT
    d,
    v,
    -- ROWS: 逐行累加 10, 30, 60, 100
    sum(v) OVER (ORDER BY d ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS rows_cumsum,
    -- RANGE(默认): 同日期一起算 30, 30, 100, 100 ← 注意跳变！
    sum(v) OVER (ORDER BY d RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS range_cumsum
FROM frame_trap_demo
ORDER BY d, v;


-- ============================================================
-- 6. 导航函数 lag / lead / first_value / last_value
-- ============================================================
-- 【原理】lag/lead 访问"相对当前行的偏移行"，用于环比/趋势

-- 6.1 lag / lead：前 N 行 / 后 N 行
SELECT
    sale_date,
    salesperson,
    product_name,
    quantity,
    price,
    lag(price) OVER (PARTITION BY salesperson ORDER BY sale_date) AS prev_price,
    lag(quantity, 2) OVER (PARTITION BY salesperson ORDER BY sale_date) AS prev_2_quantity,
    lead(price) OVER (PARTITION BY salesperson ORDER BY sale_date) AS next_price,
    lead(quantity, 2) OVER (PARTITION BY salesperson ORDER BY sale_date) AS next_2_quantity,
    price - lag(price) OVER (PARTITION BY salesperson ORDER BY sale_date) AS price_change
FROM sales_window
ORDER BY salesperson, sale_date;

-- 6.2 first_value / last_value（注意 frame 陷阱！）
-- 【坑】last_value 默认 frame = RANGE UNBOUNDED PRECEDING TO CURRENT ROW
--   即"到当前行为止的最后一行"= 当前行本身！
--   要得到分区真正的末值，必须显式写 ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
SELECT
    sale_date,
    salesperson,
    product_name,
    price,
    -- 分区第一个值（需显式全帧）
    first_value(price) OVER (
        PARTITION BY salesperson ORDER BY sale_date
        ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
    ) AS first_price,
    -- 到当前行为止的最后一个值（默认 frame，= 当前行 price）
    first_value(price) OVER (
        PARTITION BY salesperson ORDER BY sale_date
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS last_price_so_far,
    -- 分区真正的末值（必须显式 UNBOUNDED FOLLOWING）
    last_value(price) OVER (
        PARTITION BY salesperson ORDER BY sale_date
        ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
    ) AS last_price
FROM sales_window
ORDER BY salesperson, sale_date;


-- ============================================================
-- 7. 实战场景
-- ============================================================

-- 7.1 Top-N + 占比
WITH sales_by_person AS (
    SELECT
        salesperson,
        sum(quantity * price) AS total_sales
    FROM sales_window
    GROUP BY salesperson
),
total_sales AS (
    SELECT sum(total_sales) AS grand_total FROM sales_by_person
)
SELECT
    sp.salesperson,
    sp.total_sales,
    round(sp.total_sales / ts.grand_total * 100, 2) AS pct_of_total,
    rank() OVER (ORDER BY sp.total_sales DESC) AS sales_rank,
    multiIf(
        rank() OVER (ORDER BY sp.total_sales DESC) <= 1, 'Top Performer',
        rank() OVER (ORDER BY sp.total_sales DESC) <= 2, 'Second Place',
        rank() OVER (ORDER BY sp.total_sales DESC) <= 3, 'Third Place',
        ''
    ) AS award
FROM sales_by_person sp
CROSS JOIN total_sales ts
ORDER BY sp.total_sales DESC;

-- 7.2 当前销售 vs 个人最佳/均值
SELECT
    sale_date,
    salesperson,
    product_name,
    quantity * price AS sale_revenue,
    max(quantity * price) OVER (PARTITION BY salesperson) AS best_sale,
    avg(quantity * price) OVER (PARTITION BY salesperson) AS avg_sale,
    round(quantity * price / max(quantity * price) OVER (PARTITION BY salesperson) * 100, 2) AS pct_of_best,
    round(quantity * price / avg(quantity * price) OVER (PARTITION BY salesperson) * 100, 2) AS pct_of_avg,
    multiIf(
        quantity * price = max(quantity * price) OVER (PARTITION BY salesperson), 'Best Sale!',
        quantity * price >= avg(quantity * price) OVER (PARTITION BY salesperson), 'Above Average',
        'Below Average'
    ) AS performance
FROM sales_window
ORDER BY salesperson, sale_date;

-- 7.3 滚动 N 日总额
WITH daily_totals AS (
    SELECT
        sale_date,
        sum(quantity * price) AS daily_revenue
    FROM sales_window
    GROUP BY sale_date
)
SELECT
    sale_date,
    daily_revenue,
    sum(daily_revenue) OVER (ORDER BY sale_date ROWS BETWEEN 2 PRECEDING AND CURRENT ROW) AS rolling_3day,
    sum(daily_revenue) OVER (ORDER BY sale_date ROWS BETWEEN 4 PRECEDING AND CURRENT ROW) AS rolling_5day,
    sum(daily_revenue) OVER (ORDER BY sale_date ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS cumulative_total
FROM daily_totals
ORDER BY sale_date;

-- 7.4 间隔检测（gap detection）
-- 【场景】检测销售间隔异常（如 >2 天无销售）
SELECT
    sale_date,
    salesperson,
    product_name,
    lag(sale_date) OVER (PARTITION BY salesperson ORDER BY sale_date) AS prev_date,
    dateDiff('day', lag(sale_date) OVER (PARTITION BY salesperson ORDER BY sale_date), sale_date) AS days_since_prev_sale,
    multiIf(
        lag(sale_date) OVER (PARTITION BY salesperson ORDER BY sale_date) IS NULL, 'First Sale',
        dateDiff('day', lag(sale_date) OVER (PARTITION BY salesperson ORDER BY sale_date), sale_date) > 2, 'Gap > 2 days',
        'Regular'
    ) AS sale_pattern
FROM sales_window
ORDER BY salesperson, sale_date;

-- 7.5 ntile 分桶（四分位）
SELECT
    category,
    product_name,
    price,
    ntile(4) OVER (PARTITION BY category ORDER BY price DESC) AS price_quartile,
    ntile(2) OVER (PARTITION BY category ORDER BY price DESC) AS price_half,
    multiIf(
        ntile(4) OVER (PARTITION BY category ORDER BY price DESC) = 1, 'Top 25%',
        ntile(4) OVER (PARTITION BY category ORDER BY price DESC) = 2, '25-50%',
        ntile(4) OVER (PARTITION BY category ORDER BY price DESC) = 3, '50-75%',
        'Bottom 25%'
    ) AS price_tier
FROM sales_window
ORDER BY category, price DESC;

-- 7.6 百分位排名
SELECT
    category,
    product_name,
    price,
    round(100 * (rank() OVER (PARTITION BY category ORDER BY price) - 1) /
         nullIf(count() OVER (PARTITION BY category) - 1, 0), 2) AS percentile_rank,
    round(price / avg(price) OVER (PARTITION BY category) * 100, 2) AS price_pct_of_avg
FROM sales_window
ORDER BY category, price;


-- ============================================================
-- 8. 窗口函数 + GROUP BY（嵌套聚合）
-- ============================================================
-- 【原理】先 GROUP BY 聚合，再对聚合结果套窗口函数
--   注意：窗口函数在 GROUP BY 之后执行
SELECT
    category,
    sale_date,
    sum(quantity * price) AS daily_revenue,
    avg(sum(quantity * price)) OVER (PARTITION BY category ORDER BY sale_date ROWS BETWEEN 2 PRECEDING AND CURRENT ROW) AS ma_3day,
    sum(sum(quantity * price)) OVER (PARTITION BY category ORDER BY sale_date ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS cumulative,
    round(sum(quantity * price) / sum(sum(quantity * price)) OVER (PARTITION BY category) * 100, 2) AS pct_of_category_total
FROM sales_window
GROUP BY category, sale_date
ORDER BY category, sale_date;


-- ============================================================
-- 9. 性能对比：窗口函数 vs 自连接
-- ============================================================
-- 【原理】窗口函数一次排序即可计算所有窗口；自连接是 O(N²) 笛卡尔积
-- 【结果】窗口函数通常快 10x+（数据量大时更明显）

-- 9.1 窗口函数（高效）
SELECT
    sale_date,
    salesperson,
    product_name,
    quantity * price AS sale_revenue,
    sum(quantity * price) OVER (PARTITION BY salesperson ORDER BY sale_date
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS running_total
FROM sales_window
ORDER BY salesperson, sale_date
LIMIT 10;

-- 9.2 自连接实现（低效，仅作对比）
SELECT
    s1.sale_date,
    s1.salesperson,
    s1.product_name,
    s1.quantity * s1.price AS sale_revenue,
    sum(s2.quantity * s2.price) AS running_total
FROM sales_window s1
JOIN sales_window s2 ON s1.salesperson = s2.salesperson AND s2.sale_date <= s1.sale_date
GROUP BY s1.sale_date, s1.salesperson, s1.product_name, s1.quantity, s1.price
ORDER BY s1.salesperson, s1.sale_date
LIMIT 10;


-- ============================================================
-- 10. 常见误区演示
-- ============================================================

-- 误区1: 窗口函数不能用在 WHERE 中
-- 错误: SELECT * FROM sales_window WHERE rank() OVER (...) <= 10
-- 正确: 用子查询
SELECT *
FROM (
    SELECT
        salesperson,
        product_name,
        quantity * price AS revenue,
        rank() OVER (PARTITION BY salesperson ORDER BY quantity * price DESC) AS rnk
    FROM sales_window
)
WHERE rnk <= 2
ORDER BY salesperson, rnk;

-- 误区2: 忘记 PARTITION BY 导致全表单分区（性能灾难）
-- 不好: rank() OVER (ORDER BY revenue DESC)  -- 全表排名
-- 推荐: rank() OVER (PARTITION BY salesperson ORDER BY revenue DESC)  -- 分区内排名


-- ============================================================
-- 11. 清理（如需）
-- ============================================================
-- DROP DATABASE IF EXISTS window_functions_test ON CLUSTER 'treasurycluster';
