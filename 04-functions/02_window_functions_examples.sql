-- ============================================================================
-- ClickHouse Window Functions Examples
-- ============================================================================
-- This file demonstrates window functions in ClickHouse, which are powerful
-- tools for performing calculations across a set of table rows that are somehow
-- related to the current row.
-- ============================================================================

-- ============================================================================
-- 1. PREPARATION - CREATE TEST DATA
-- ============================================================================

CREATE DATABASE IF NOT EXISTS window_functions_test;
USE window_functions_test;

-- Sales table for window function demonstrations
DROP TABLE IF EXISTS sales_window;

CREATE TABLE sales_window (
    id UInt64,
    sale_date Date,
    product_id UInt32,
    product_name String,
    category String,
    quantity UInt32,
    price Decimal(10, 2),
    region String,
    salesperson String
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(sale_date)
ORDER BY (product_id, sale_date);

-- Insert comprehensive test data
INSERT INTO sales_window VALUES
    -- January 2024 - North Region
    (1, '2024-01-15', 101, 'Laptop', 'Electronics', 2, 999.99, 'North', 'Alice'),
    (2, '2024-01-16', 101, 'Laptop', 'Electronics', 1, 999.99, 'North', 'Alice'),
    (3, '2024-01-17', 102, 'Mouse', 'Electronics', 5, 19.99, 'North', 'Bob'),
    (4, '2024-01-18', 103, 'Monitor', 'Electronics', 3, 299.99, 'North', 'Alice'),
    (5, '2024-01-19', 104, 'Keyboard', 'Electronics', 4, 49.99, 'North', 'Bob'),
    -- January 2024 - South Region
    (6, '2024-01-15', 101, 'Laptop', 'Electronics', 1, 999.99, 'South', 'Charlie'),
    (7, '2024-01-16', 105, 'Headphones', 'Electronics', 3, 79.99, 'South', 'Charlie'),
    (8, '2024-01-17', 102, 'Mouse', 'Electronics', 2, 19.99, 'South', 'David'),
    (9, '2024-01-18', 106, 'USB Cable', 'Accessories', 10, 9.99, 'South', 'Charlie'),
    (10, '2024-01-19', 107, 'Webcam', 'Electronics', 2, 59.99, 'South', 'David'),
    -- January 2024 - East Region
    (11, '2024-01-15', 103, 'Monitor', 'Electronics', 2, 299.99, 'East', 'Eve'),
    (12, '2024-01-16', 104, 'Keyboard', 'Electronics', 3, 49.99, 'East', 'Frank'),
    (13, '2024-01-17', 105, 'Headphones', 'Electronics', 4, 79.99, 'East', 'Eve'),
    (14, '2024-01-18', 108, 'Power Adapter', 'Accessories', 5, 29.99, 'East', 'Frank'),
    (15, '2024-01-19', 101, 'Laptop', 'Electronics', 1, 999.99, 'East', 'Eve'),
    -- February 2024 - North Region
    (16, '2024-02-15', 101, 'Laptop', 'Electronics', 3, 999.99, 'North', 'Alice'),
    (17, '2024-02-16', 102, 'Mouse', 'Electronics', 6, 19.99, 'North', 'Bob'),
    (18, '2024-02-17', 103, 'Monitor', 'Electronics', 2, 299.99, 'North', 'Alice'),
    (19, '2024-02-18', 104, 'Keyboard', 'Electronics', 5, 49.99, 'North', 'Bob'),
    (20, '2024-02-19', 105, 'Headphones', 'Electronics', 4, 79.99, 'North', 'Alice');

-- ============================================================================
-- 2. BASIC WINDOW FUNCTION SYNTAX
-- ============================================================================

-- Basic structure: function OVER ([PARTITION BY ...] [ORDER BY ...] [FRAME ...])

-- Example 1: ROW_NUMBER() - Assign unique sequential numbers to rows
SELECT 
    sale_date,
    product_name,
    category,
    quantity,
    price,
    salesperson,
    -- Simple row number over all rows
    row_number() OVER () as global_row_num,
    -- Row number per salesperson
    row_number() OVER (PARTITION BY salesperson) as salesperson_row_num,
    -- Row number per salesperson, ordered by sale_date
    row_number() OVER (PARTITION BY salesperson ORDER BY sale_date) as salesperson_ordered_row_num
FROM sales_window
ORDER BY salesperson, sale_date;

-- Example 2: RANK() and DENSE_RANK() - Ranking with ties
SELECT 
    category,
    product_name,
    price,
    -- Standard RANK - skips numbers after ties
    rank() OVER (PARTITION BY category ORDER BY price DESC) as rank_price,
    -- DENSE_RANK - no gaps after ties
    dense_rank() OVER (PARTITION BY category ORDER BY price DESC) as dense_rank_price,
    -- ROW_NUMBER - always sequential
    row_number() OVER (PARTITION BY category ORDER BY price DESC) as row_num_price
FROM sales_window
ORDER BY category, price DESC;

-- ============================================================================
-- 3. AGGREGATE WINDOW FUNCTIONS
-- ============================================================================

-- Example 3: Running totals (cumulative sum)
SELECT 
    sale_date,
    salesperson,
    product_name,
    quantity,
    price,
    -- Revenue per sale
    quantity * price as sale_revenue,
    -- Running total of revenue per salesperson
    sum(quantity * price) OVER (PARTITION BY salesperson ORDER BY sale_date ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) as running_revenue,
    -- Grand total running
    sum(quantity * price) OVER (ORDER BY sale_date ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) as global_running_revenue
FROM sales_window
ORDER BY salesperson, sale_date;

-- Example 4: Moving averages
SELECT 
    sale_date,
    product_name,
    price,
    -- 3-day moving average (centered)
    avg(price) OVER (ORDER BY sale_date ROWS BETWEEN 1 PRECEDING AND 1 FOLLOWING) as ma_3day_centered,
    -- 3-day moving average (trailing)
    avg(price) OVER (ORDER BY sale_date ROWS BETWEEN 2 PRECEDING AND CURRENT ROW) as ma_3day_trailing,
    -- 5-day moving average
    avg(price) OVER (ORDER BY sale_date ROWS BETWEEN 4 PRECEDING AND CURRENT ROW) as ma_5day_trailing
FROM sales_window
ORDER BY sale_date;

-- Example 5: Aggregates per partition
SELECT 
    sale_date,
    category,
    product_name,
    price,
    -- Category average price
    avg(price) OVER (PARTITION BY category) as category_avg_price,
    -- Category min/max
    min(price) OVER (PARTITION BY category) as category_min_price,
    max(price) OVER (PARTITION BY category) as category_max_price,
    -- Count in category
    count(*) OVER (PARTITION BY category) as category_count
FROM sales_window
ORDER BY category, price DESC;

-- ============================================================================
-- 4. POSITIONAL WINDOW FUNCTIONS
-- ============================================================================

-- Example 6: LEAD and LAG - Access rows before/after current row
SELECT 
    sale_date,
    salesperson,
    product_name,
    quantity,
    price,
    -- Previous sale by same salesperson
    lag(price) OVER (PARTITION BY salesperson ORDER BY sale_date) as prev_price,
    lag(quantity, 2) OVER (PARTITION BY salesperson ORDER BY sale_date) as prev_2_quantity,
    -- Next sale by same salesperson
    lead(price) OVER (PARTITION BY salesperson ORDER BY sale_date) as next_price,
    lead(quantity, 2) OVER (PARTITION BY salesperson ORDER BY sale_date) as next_2_quantity,
    -- Difference from previous sale
    price - lag(price) OVER (PARTITION BY salesperson ORDER BY sale_date) as price_change
FROM sales_window
ORDER BY salesperson, sale_date;

-- Example 7: FIRST_VALUE and LAST_VALUE - First/last values in partition
SELECT 
    sale_date,
    salesperson,
    product_name,
    price,
    -- First price in salesperson's history
    first_value(price) OVER (PARTITION BY salesperson ORDER BY sale_date ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) as first_price,
    -- Last price (so far)
    first_value(price) OVER (PARTITION BY salesperson ORDER BY sale_date ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) as last_price_so_far,
    -- Last price in partition
    last_value(price) OVER (PARTITION BY salesperson ORDER BY sale_date ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) as last_price
FROM sales_window
ORDER BY salesperson, sale_date;

-- ============================================================================
-- 5. ADVANCED WINDOW FUNCTION APPLICATIONS
-- ============================================================================

-- Example 8: Percentiles and quartiles using window functions
SELECT 
    category,
    product_name,
    price,
    -- Percentile rank within category
    round(100 * (rank() OVER (PARTITION BY category ORDER BY price) - 1) / 
         nullif(count(*) OVER (PARTITION BY category) - 1, 0), 2) as percentile_rank,
    -- Price relative to category average
    round(price / avg(price) OVER (PARTITION BY category) * 100, 2) as price_pct_of_avg
FROM sales_window
ORDER BY category, price;

-- Example 9: Ntile - Divide rows into groups
SELECT 
    category,
    product_name,
    price,
    -- Divide into 4 groups (quartiles) based on price
    ntile(4) OVER (PARTITION BY category ORDER BY price DESC) as price_quartile,
    -- Divide into 2 groups (top/bottom half)
    ntile(2) OVER (PARTITION BY category ORDER BY price DESC) as price_half,
    CASE 
        WHEN ntile(4) OVER (PARTITION BY category ORDER BY price DESC) = 1 THEN 'Top 25%'
        WHEN ntile(4) OVER (PARTITION BY category ORDER BY price DESC) = 2 THEN '25-50%'
        WHEN ntile(4) OVER (PARTITION BY category ORDER BY price DESC) = 3 THEN '50-75%'
        ELSE 'Bottom 25%'
    END as price_tier
FROM sales_window
ORDER BY category, price DESC;

-- Example 10: Gap detection with LAG
SELECT 
    sale_date,
    salesperson,
    product_name,
    lag(sale_date) OVER (PARTITION BY salesperson ORDER BY sale_date) as prev_date,
    dateDiff('day', lag(sale_date) OVER (PARTITION BY salesperson ORDER BY sale_date), sale_date) as days_since_prev_sale,
    CASE 
        WHEN lag(sale_date) OVER (PARTITION BY salesperson ORDER BY sale_date) IS NULL THEN 'First Sale'
        WHEN dateDiff('day', lag(sale_date) OVER (PARTITION BY salesperson ORDER BY sale_date), sale_date) > 2 THEN 'Gap > 2 days'
        ELSE 'Regular'
    END as sale_pattern
FROM sales_window
ORDER BY salesperson, sale_date;

-- ============================================================================
-- 6. MULTI-LEVEL ANALYSIS WITH WINDOW FUNCTIONS
-- ============================================================================

-- Example 11: Combined window functions for comprehensive analysis
SELECT 
    sale_date,
    salesperson,
    product_name,
    category,
    quantity,
    price,
    quantity * price as total_revenue,
    -- Ranking within salesperson by revenue
    rank() OVER (PARTITION BY salesperson ORDER BY quantity * price DESC) as salesperson_revenue_rank,
    -- Percentile within salesperson
    round(100 * (row_number() OVER (PARTITION BY salesperson ORDER BY quantity * price) - 1) / 
         nullif(count(*) OVER (PARTITION BY salesperson) - 1, 0), 2) as revenue_percentile,
    -- Running contribution to salesperson total
    round(quantity * price / sum(quantity * price) OVER (PARTITION BY salesperson ORDER BY sale_date ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) * 100, 2) as running_pct_of_total,
    -- Salesperson's average price vs current
    avg(price) OVER (PARTITION BY salesperson) as salesperson_avg_price,
    price - avg(price) OVER (PARTITION BY salesperson) as price_vs_avg
FROM sales_window
ORDER BY salesperson, sale_date;

-- ============================================================================
-- 7. WINDOW FRAMES (ROW, RANGE, GROUPS)
-- ============================================================================

-- Example 12: Different frame specifications
SELECT 
    sale_date,
    price,
    -- ROWS frame: based on physical row position
    avg(price) OVER (ORDER BY sale_date ROWS BETWEEN 2 PRECEDING AND CURRENT ROW) as rows_2_preceding,
    -- RANGE frame: based on value range
    avg(price) OVER (ORDER BY price RANGE BETWEEN 100 PRECEDING AND CURRENT ROW) as range_100_preceding,
    -- Default frame when using ORDER BY: RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    avg(price) OVER (ORDER BY sale_date) as default_cumulative,
    -- No frame specified: entire partition
    avg(price) OVER (PARTITION BY category ORDER BY sale_date ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) as category_avg
FROM sales_window
ORDER BY sale_date;

-- ============================================================================
-- 8. REAL-WORLD BUSINESS SCENARIOS
-- ============================================================================

-- Scenario 1: Identify top performers with percentage of total
WITH sales_by_person AS (
    SELECT 
        salesperson,
        sum(quantity * price) as total_sales
    FROM sales_window
    GROUP BY salesperson
),
total_sales AS (
    SELECT sum(total_sales) as grand_total FROM sales_by_person
)
SELECT 
    sp.salesperson,
    sp.total_sales,
    round(sp.total_sales / ts.grand_total * 100, 2) as pct_of_total,
    rank() OVER (ORDER BY sp.total_sales DESC) as sales_rank,
    CASE 
        WHEN rank() OVER (ORDER BY sp.total_sales DESC) <= 1 THEN '🏆 Top Performer'
        WHEN rank() OVER (ORDER BY sp.total_sales DESC) <= 2 THEN '🥈 Second Place'
        WHEN rank() OVER (ORDER BY sp.total_sales DESC) <= 3 THEN '🥉 Third Place'
        ELSE ''
    END as award
FROM sales_by_person sp
CROSS JOIN total_sales ts
ORDER BY sp.total_sales DESC;

-- Scenario 2: Compare current sale to salesperson's best and average
SELECT 
    sale_date,
    salesperson,
    product_name,
    quantity * price as sale_revenue,
    -- Salesperson's best sale
    max(quantity * price) OVER (PARTITION BY salesperson) as best_sale,
    -- Salesperson's average sale
    avg(quantity * price) OVER (PARTITION BY salesperson) as avg_sale,
    -- Performance vs best
    round(quantity * price / max(quantity * price) OVER (PARTITION BY salesperson) * 100, 2) as pct_of_best,
    -- Performance vs average
    round(quantity * price / avg(quantity * price) OVER (PARTITION BY salesperson) * 100, 2) as pct_of_avg,
    CASE 
        WHEN quantity * price = max(quantity * price) OVER (PARTITION BY salesperson) THEN '🎯 Best Sale!'
        WHEN quantity * price >= avg(quantity * price) OVER (PARTITION BY salesperson) THEN '✅ Above Average'
        ELSE '⬇️ Below Average'
    END as performance
FROM sales_window
ORDER BY salesperson, sale_date;

-- Scenario 3: Rolling 7-day totals
WITH daily_totals AS (
    SELECT 
        sale_date,
        sum(quantity * price) as daily_revenue
    FROM sales_window
    GROUP BY sale_date
)
SELECT 
    sale_date,
    daily_revenue,
    -- 3-day rolling total
    sum(daily_revenue) OVER (ORDER BY sale_date ROWS BETWEEN 2 PRECEDING AND CURRENT ROW) as rolling_3day,
    -- 5-day rolling total
    sum(daily_revenue) OVER (ORDER BY sale_date ROWS BETWEEN 4 PRECEDING AND CURRENT ROW) as rolling_5day,
    -- Grand total
    sum(daily_revenue) OVER (ORDER BY sale_date ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) as cumulative_total
FROM daily_totals
ORDER BY sale_date;

-- Scenario 4: Product category performance trends
SELECT 
    category,
    sale_date,
    sum(quantity * price) as daily_revenue,
    -- 3-day moving average per category
    avg(sum(quantity * price)) OVER (PARTITION BY category ORDER BY sale_date ROWS BETWEEN 2 PRECEDING AND CURRENT ROW) as ma_3day,
    -- Category total so far
    sum(sum(quantity * price)) OVER (PARTITION BY category ORDER BY sale_date ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) as cumulative,
    -- Percent of category total
    round(sum(quantity * price) / sum(sum(quantity * price)) OVER (PARTITION BY category) * 100, 2) as pct_of_category_total
FROM sales_window
GROUP BY category, sale_date
ORDER BY category, sale_date;

-- ============================================================================
-- 9. ADVANCED TECHNIQUES
-- ============================================================================

-- Example 13: Self-join using window functions for comparison
WITH sales_with_rank AS (
    SELECT 
        *,
        rank() OVER (PARTITION BY salesperson ORDER BY quantity * price DESC) as revenue_rank
    FROM sales_window
),
top_sales AS (
    SELECT 
        salesperson,
        argMax(product_name, quantity * price) as best_product,
        max(quantity * price) as best_revenue
    FROM sales_window
    GROUP BY salesperson
)
SELECT 
    sw.*,
    ts.best_product as salesperson_best,
    ts.best_revenue as best_revenue_amount,
    CASE 
        WHEN sw.product_name = ts.best_product THEN '✅ Best Product'
        ELSE ''
    END as is_best_product
FROM sales_window sw
LEFT JOIN top_sales ts ON sw.salesperson = ts.salesperson
ORDER BY sw.salesperson, sw.sale_date;

-- Example 14: Window functions with GROUP BY
SELECT 
    category,
    product_name,
    avg(price) as avg_price,
    count(*) as sale_count,
    -- Window function over aggregated results
    rank() OVER (ORDER BY avg(price) DESC) as avg_price_rank,
    -- Percentile of average price
    round(100 * (row_number() OVER (ORDER BY avg(price)) - 1) / 
         nullif(count(*) OVER () - 1, 0), 2) as avg_price_percentile
FROM sales_window
GROUP BY category, product_name
ORDER BY avg_price DESC;

-- ============================================================================
-- 10. PERFORMANCE COMPARISON
-- ============================================================================

-- Using window functions vs traditional subquery approach
-- Window functions (more efficient)
SELECT 
    sale_date,
    salesperson,
    product_name,
    quantity * price as sale_revenue,
    sum(quantity * price) OVER (PARTITION BY salesperson ORDER BY sale_date) as running_total
FROM sales_window
ORDER BY salesperson, sale_date
LIMIT 10;

-- Traditional approach (less efficient, for comparison)
SELECT 
    s1.sale_date,
    s1.salesperson,
    s1.product_name,
    s1.quantity * s1.price as sale_revenue,
    sum(s2.quantity * s2.price) as running_total
FROM sales_window s1
JOIN sales_window s2 ON s1.salesperson = s2.salesperson AND s2.sale_date <= s1.sale_date
GROUP BY s1.sale_date, s1.salesperson, s1.product_name, s1.quantity, s1.price
ORDER BY s1.salesperson, s1.sale_date
LIMIT 10;

-- ============================================================================
-- CLEANUP
-- ============================================================================

-- Uncomment to drop test database
-- DROP DATABASE IF EXISTS window_functions_test;
