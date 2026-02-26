-- ========================================
-- 大规模预测数据分析 - 展开视图
-- ========================================
-- 创建支持Superset Pivot Table的分析视图
-- 核心功能：将数组存储的预测数据展开为长格式
-- ========================================

-- ========================================
-- 1. 基础展开视图 (核心视图)
-- ========================================
-- 将二维数组展开为长格式，供Superset分析
-- ========================================

CREATE VIEW IF NOT EXISTS prediction_analytics.prediction_analysis_view ON CLUSTER 'treasurycluster' AS
SELECT 
    -- 主键
    pv.transaction_key,
    pv.batch_id,
    
    -- 展开的指标和月份
    m.metric_id,
    m.metric_code,
    m.metric_name,
    m.level AS metric_level,
    m.parent_metric_id,
    m.is_leaf,
    
    mm.month_offset,
    mm.year_month,
    mm.year,
    mm.quarter,
    mm.month,
    mm.year_quarter,
    
    -- 预测值
    pv.metrics_values[m.metric_id][mm.month_offset] AS prediction_value,
    
    -- 数据质量
    pv.data_quality_score,
    pv.has_anomaly
    
FROM prediction_analytics.prediction_values pv
CROSS JOIN prediction_analytics.metric_metadata m
CROSS JOIN prediction_analytics.month_mapping mm
WHERE m.metric_id > 0 
  AND mm.month_offset > 0
  AND m.metric_id <= 20
  AND mm.month_offset <= 60;

-- ========================================
-- 2. 带维度的完整分析视图
-- ========================================
-- JOIN维度表，提供完整的分析维度
-- ========================================

CREATE VIEW IF NOT EXISTS prediction_analytics.prediction_full_view ON CLUSTER 'treasurycluster' AS
SELECT 
    -- 主键
    td.transaction_key,
    pv.batch_id,
    bi.batch_name,
    
    -- 指标维度
    m.metric_id,
    m.metric_code,
    m.metric_name,
    m.level AS metric_level,
    m.parent_metric_id,
    m.is_leaf,
    
    -- 时间维度
    mm.month_offset,
    mm.year_month,
    mm.year,
    mm.quarter,
    mm.month,
    mm.year_quarter,
    
    -- 预测值
    pv.metrics_values[m.metric_id][mm.month_offset] AS prediction_value,
    
    -- 维度列 (从维度表)
    td.region_code,
    td.country_code,
    td.state_code,
    td.city_code,
    
    td.product_category,
    td.product_subcategory,
    td.product_id,
    td.product_name,
    td.sku,
    
    td.customer_segment,
    td.customer_type,
    td.customer_id,
    td.customer_name,
    td.customer_tier,
    
    td.sales_channel,
    td.distribution_channel,
    td.marketing_channel,
    
    td.transaction_year,
    td.transaction_month,
    td.transaction_quarter,
    td.transaction_week,
    
    td.business_unit,
    td.department,
    td.team,
    td.sales_rep,
    
    td.cost_center,
    td.profit_center,
    td.gl_account,
    td.currency_code,
    
    -- 扩展维度
    td.dimension_1,
    td.dimension_2,
    td.dimension_3,
    td.dimension_4,
    td.dimension_5,
    td.dimension_6,
    td.dimension_7,
    td.dimension_8,
    td.dimension_9,
    td.dimension_10,
    td.dimension_11,
    td.dimension_12,
    td.dimension_13,
    td.dimension_14,
    td.dimension_15,
    td.dimension_16,
    td.dimension_17,
    td.dimension_18,
    td.dimension_19,
    td.dimension_20,
    td.dimension_21,
    td.dimension_22,
    td.dimension_23,
    td.dimension_24,
    td.dimension_25,
    td.dimension_26,
    td.dimension_27,
    td.dimension_28,
    td.dimension_29,
    td.dimension_30,
    td.dimension_31,
    td.dimension_32,
    td.dimension_33,
    td.dimension_34,
    td.dimension_35,
    td.dimension_36,
    td.dimension_37,
    td.dimension_38,
    td.dimension_39,
    td.dimension_40,
    td.dimension_41,
    td.dimension_42,
    td.dimension_43,
    td.dimension_44,
    td.dimension_45,
    td.dimension_46,
    td.dimension_47,
    td.dimension_48,
    td.dimension_49,
    td.dimension_50,
    td.dimension_51,
    td.dimension_52,
    td.dimension_53,
    td.dimension_54,
    td.dimension_55,
    td.dimension_56,
    td.dimension_57,
    td.dimension_58,
    td.dimension_59,
    td.dimension_60,
    
    -- 数据质量
    pv.data_quality_score,
    pv.has_anomaly
    
FROM prediction_analytics.prediction_values pv
INNER JOIN prediction_analytics.transaction_dimensions td 
    ON pv.transaction_key = td.transaction_key AND pv.batch_id = td.batch_id
INNER JOIN prediction_analytics.batch_info bi 
    ON pv.batch_id = bi.batch_id
CROSS JOIN prediction_analytics.metric_metadata m
CROSS JOIN prediction_analytics.month_mapping mm
WHERE m.metric_id > 0 
  AND mm.month_offset > 0
  AND m.metric_id <= 20
  AND mm.month_offset <= 60;

-- ========================================
-- 3. 指标层级聚合视图
-- ========================================
-- 支持按指标层级汇总（父指标=子指标之和）
-- ========================================

CREATE VIEW IF NOT EXISTS prediction_analytics.metric_hierarchy_view ON CLUSTER 'treasurycluster' AS
SELECT 
    batch_id,
    year_month,
    year,
    quarter,
    
    -- 维度列（示例）
    region_code,
    product_category,
    customer_segment,
    
    -- 指标信息
    metric_id,
    metric_code,
    metric_name,
    metric_level,
    parent_metric_id,
    
    -- 聚合值
    sum(prediction_value) AS prediction_value_sum,
    avg(prediction_value) AS prediction_value_avg,
    count() AS prediction_count
    
FROM prediction_analytics.prediction_full_view
GROUP BY 
    batch_id, year_month, year, quarter,
    region_code, product_category, customer_segment,
    metric_id, metric_code, metric_name, metric_level, parent_metric_id;

-- ========================================
-- 4. 年度汇总视图
-- ========================================

CREATE VIEW IF NOT EXISTS prediction_analytics.yearly_summary_view ON CLUSTER 'treasurycluster' AS
SELECT 
    batch_id,
    year,
    metric_id,
    metric_code,
    metric_name,
    
    -- 维度（可扩展）
    region_code,
    product_category,
    customer_segment,
    
    -- 年度汇总
    sum(prediction_value) AS annual_total,
    avg(prediction_value) AS annual_avg,
    min(prediction_value) AS annual_min,
    max(prediction_value) AS annual_max,
    count() AS month_count
    
FROM prediction_analytics.prediction_full_view
GROUP BY 
    batch_id, year,
    metric_id, metric_code, metric_name,
    region_code, product_category, customer_segment;

-- ========================================
-- 5. 季度汇总视图
-- ========================================

CREATE VIEW IF NOT EXISTS prediction_analytics.quarterly_summary_view ON CLUSTER 'treasurycluster' AS
SELECT 
    batch_id,
    year,
    quarter,
    year_quarter,
    metric_id,
    metric_code,
    metric_name,
    
    region_code,
    product_category,
    customer_segment,
    
    sum(prediction_value) AS quarterly_total,
    avg(prediction_value) AS quarterly_avg,
    count() AS month_count
    
FROM prediction_analytics.prediction_full_view
GROUP BY 
    batch_id, year, quarter, year_quarter,
    metric_id, metric_code, metric_name,
    region_code, product_category, customer_segment;

-- ========================================
-- 6. 指标对比视图 (不同批次对比)
-- ========================================

CREATE VIEW IF NOT EXISTS prediction_analytics.batch_comparison_view ON CLUSTER 'treasurycluster' AS
SELECT 
    year_month,
    metric_id,
    metric_code,
    metric_name,
    
    region_code,
    product_category,
    
    -- 各批次数据
    batch_id,
    batch_name,
    sum(prediction_value) AS total_value
    
FROM prediction_analytics.prediction_full_view
GROUP BY 
    year_month, metric_id, metric_code, metric_name,
    region_code, product_category,
    batch_id, batch_name;

-- ========================================
-- 7. 环比增长视图
-- ========================================

CREATE VIEW IF NOT EXISTS prediction_analytics.mom_growth_view ON CLUSTER 'treasurycluster' AS
SELECT 
    batch_id,
    year_month,
    metric_id,
    metric_code,
    metric_name,
    
    region_code,
    product_category,
    
    sum(prediction_value) AS current_value,
    lagInFrame(sum(prediction_value)) OVER (
        PARTITION BY batch_id, metric_id, region_code, product_category
        ORDER BY year_month
    ) AS previous_value,
    
    if(
        lagInFrame(sum(prediction_value)) OVER (
            PARTITION BY batch_id, metric_id, region_code, product_category
            ORDER BY year_month
        ) > 0,
        round((sum(prediction_value) - lagInFrame(sum(prediction_value)) OVER (
            PARTITION BY batch_id, metric_id, region_code, product_category
            ORDER BY year_month
        )) / lagInFrame(sum(prediction_value)) OVER (
            PARTITION BY batch_id, metric_id, region_code, product_category
            ORDER BY year_month
        ) * 100, 2),
        0
    ) AS mom_growth_rate
    
FROM prediction_analytics.prediction_full_view
GROUP BY 
    batch_id, year_month, metric_id, metric_code, metric_name,
    region_code, product_category;

-- ========================================
-- 8. Top N 分析视图
-- ========================================

CREATE VIEW IF NOT EXISTS prediction_analytics.top_n_analysis_view ON CLUSTER 'treasurycluster' AS
SELECT 
    batch_id,
    year_month,
    metric_id,
    metric_name,
    
    -- 可按任意维度排名
    product_category,
    sum(prediction_value) AS total_value,
    rank() OVER (
        PARTITION BY batch_id, year_month, metric_id
        ORDER BY sum(prediction_value) DESC
    ) AS rank_in_month
    
FROM prediction_analytics.prediction_full_view
GROUP BY 
    batch_id, year_month, metric_id, metric_name, product_category;

-- ========================================
-- 9. 指标路径展开视图 (用于层级分析)
-- ========================================

CREATE VIEW IF NOT EXISTS prediction_analytics.metric_path_view ON CLUSTER 'treasurycluster' AS
SELECT 
    batch_id,
    year_month,
    
    -- 指标路径信息
    metric_id,
    metric_code,
    metric_name,
    metric_level,
    full_path,
    
    -- 路径展开
    full_path[1] AS level_0_metric_id,
    if(length(full_path) > 1, full_path[2], 0) AS level_1_metric_id,
    if(length(full_path) > 2, full_path[3], 0) AS level_2_metric_id,
    if(length(full_path) > 3, full_path[4], 0) AS level_3_metric_id,
    
    region_code,
    product_category,
    
    sum(prediction_value) AS total_value
    
FROM prediction_analytics.prediction_full_view pv
INNER JOIN prediction_analytics.metric_metadata m 
    ON pv.metric_id = m.metric_id
GROUP BY 
    batch_id, year_month,
    metric_id, metric_code, metric_name, metric_level, full_path,
    region_code, product_category;

-- ========================================
-- 10. Superset Pivot Table 专用视图
-- ========================================
-- 优化过的视图，减少JOIN，提升Superset查询性能
-- ========================================

CREATE VIEW IF NOT EXISTS prediction_analytics.superset_pivot_view ON CLUSTER 'treasurycluster' AS
SELECT 
    -- 关键维度
    pv.batch_id,
    bi.batch_name,
    
    -- 时间
    mm.year_month,
    mm.year,
    mm.quarter,
    mm.month,
    
    -- 指标
    m.metric_id,
    m.metric_code,
    m.metric_name,
    m.metric_level,
    
    -- 核心业务维度（高频使用）
    td.region_code,
    td.country_code,
    td.product_category,
    td.product_subcategory,
    td.customer_segment,
    td.customer_type,
    td.sales_channel,
    td.business_unit,
    
    -- 值
    pv.metrics_values[m.metric_id][mm.month_offset] AS prediction_value
    
FROM prediction_analytics.prediction_values pv
INNER JOIN prediction_analytics.transaction_dimensions td 
    ON pv.transaction_key = td.transaction_key AND pv.batch_id = td.batch_id
INNER JOIN prediction_analytics.batch_info bi 
    ON pv.batch_id = bi.batch_id
CROSS JOIN prediction_analytics.metric_metadata m
CROSS JOIN prediction_analytics.month_mapping mm
WHERE m.metric_id BETWEEN 1 AND 20
  AND mm.month_offset BETWEEN 1 AND 60;

-- ========================================
-- 11. 验证视图
-- ========================================

-- 验证基础视图
SELECT count() AS row_count FROM prediction_analytics.prediction_analysis_view;
-- 预期：1000 * 20 * 60 = 1,200,000 行

-- 验证完整视图
SELECT count() AS row_count FROM prediction_analytics.prediction_full_view;

-- 验证Superset视图（前10行）
SELECT * FROM prediction_analytics.superset_pivot_view LIMIT 10;

-- 验证指标层级
SELECT 
    metric_level,
    count() AS metric_count,
    countDistinct(metric_id) AS unique_metrics
FROM prediction_analytics.prediction_analysis_view
GROUP BY metric_level
ORDER BY metric_level;

-- 验证时间维度
SELECT 
    year,
    quarter,
    countDistinct(year_month) AS month_count
FROM prediction_analytics.prediction_analysis_view
GROUP BY year, quarter
ORDER BY year, quarter;
