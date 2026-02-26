-- ========================================
-- 大规模预测数据分析 - Superset集成
-- ========================================
-- Superset数据源配置和分析模板
-- 支持：Pivot Table、图表、仪表板
-- ========================================

-- ========================================
-- 1. Superset数据源视图
-- ========================================

-- 主分析视图（Superset直接使用）
CREATE VIEW IF NOT EXISTS prediction_analytics.superset_dataset ON CLUSTER 'treasurycluster' AS
SELECT 
    -- 维度列
    pv.batch_id,
    bi.batch_name,
    bi.model_version,
    
    -- 时间维度
    mm.year_month,
    mm.year,
    mm.quarter,
    mm.month,
    mm.year_quarter,
    mm.month_name,
    
    -- 指标维度
    m.metric_id,
    m.metric_code,
    m.metric_name,
    m.level AS metric_level,
    m.parent_metric_id,
    m.is_leaf,
    
    -- 地理维度
    td.region_code,
    td.country_code,
    td.state_code,
    td.city_code,
    
    -- 产品维度
    td.product_category,
    td.product_subcategory,
    td.product_id,
    td.product_name,
    td.sku,
    
    -- 客户维度
    td.customer_segment,
    td.customer_type,
    td.customer_id,
    td.customer_name,
    td.customer_tier,
    
    -- 渠道维度
    td.sales_channel,
    td.distribution_channel,
    td.marketing_channel,
    
    -- 组织维度
    td.business_unit,
    td.department,
    td.team,
    td.sales_rep,
    
    -- 财务维度
    td.cost_center,
    td.profit_center,
    td.currency_code,
    
    -- 预测值（度量）
    pv.metrics_values[m.metric_id][mm.month_offset] AS prediction_value,
    
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
WHERE m.metric_id BETWEEN 1 AND 20
  AND mm.month_offset BETWEEN 1 AND 60;

-- ========================================
-- 2. 指标层级分析专用视图
-- ========================================

CREATE VIEW IF NOT EXISTS prediction_analytics.superset_metric_hierarchy ON CLUSTER 'treasurycluster' AS
SELECT 
    batch_id,
    batch_name,
    year_month,
    year,
    quarter,
    
    -- 指标完整路径
    metric_id,
    metric_code,
    metric_name,
    metric_level,
    parent_metric_id,
    full_path,
    
    -- 层级展开
    full_path[1] AS level_0_metric_id,
    if(length(full_path) > 1, full_path[2], 0) AS level_1_metric_id,
    if(length(full_path) > 2, full_path[3], 0) AS level_2_metric_id,
    if(length(full_path) > 3, full_path[4], 0) AS level_3_metric_id,
    
    -- 维度
    region_code,
    product_category,
    customer_segment,
    
    -- 值
    sum(prediction_value) AS total_value,
    avg(prediction_value) AS avg_value,
    count() AS record_count
    
FROM prediction_analytics.prediction_full_view pv
INNER JOIN prediction_analytics.metric_metadata m 
    ON pv.metric_id = m.metric_id
GROUP BY 
    batch_id, batch_name, year_month, year, quarter,
    metric_id, metric_code, metric_name, metric_level, parent_metric_id, full_path,
    region_code, product_category, customer_segment;

-- ========================================
-- 3. 时间序列分析视图
-- ========================================

CREATE VIEW IF NOT EXISTS prediction_analytics.superset_time_series ON CLUSTER 'treasurycluster' AS
SELECT 
    batch_id,
    year_month,
    year,
    quarter,
    month,
    
    metric_id,
    metric_name,
    
    region_code,
    product_category,
    customer_segment,
    
    -- 聚合值
    sum(prediction_value) AS total_value,
    avg(prediction_value) AS avg_value,
    
    -- 时间序列计算
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
    batch_id, year_month, year, quarter, month,
    metric_id, metric_name,
    region_code, product_category, customer_segment;

-- ========================================
-- 4. Superset Virtual Dataset配置
-- ========================================

-- 在Superset中创建Virtual Dataset时使用的SQL

-- 模板1: 基础Pivot分析
/*
SELECT 
    year_month,
    metric_name,
    region_code,
    product_category,
    customer_segment,
    sum(prediction_value) AS total_value
FROM prediction_analytics.superset_dataset
WHERE batch_id = {{ batch_id }}
  AND metric_id IN ({{ metric_ids }})
GROUP BY year_month, metric_name, region_code, product_category, customer_segment
ORDER BY year_month
*/

-- 模板2: 指标层级分析
/*
SELECT 
    year_month,
    metric_level,
    metric_name,
    sum(total_value) AS total_value
FROM prediction_analytics.superset_metric_hierarchy
WHERE batch_id = {{ batch_id }}
  AND year_month BETWEEN '{{ start_month }}' AND '{{ end_month }}'
GROUP BY year_month, metric_level, metric_name
ORDER BY year_month, metric_level
*/

-- 模板3: 时间序列分析
/*
SELECT 
    year_month,
    metric_name,
    total_value,
    previous_value,
    mom_growth_rate
FROM prediction_analytics.superset_time_series
WHERE batch_id = {{ batch_id }}
  AND metric_id = {{ metric_id }}
ORDER BY year_month
*/

-- ========================================
-- 5. 预定义计算列 (Calculated Columns)
-- ========================================

-- 在Superset中添加计算列

-- 计算列1: 年度累计值
/*
Column Name: ytd_total
SQL Expression: SUM(prediction_value) OVER (PARTITION BY batch_id, metric_id, year ORDER BY year_month)
*/

-- 计算列2: 季度累计值
/*
Column Name: qtd_total
SQL Expression: SUM(prediction_value) OVER (PARTITION BY batch_id, metric_id, year, quarter ORDER BY year_month)
*/

-- 计算列3: 环比增长率
/*
Column Name: mom_growth
SQL Expression: (prediction_value - LAG(prediction_value) OVER (PARTITION BY batch_id, metric_id ORDER BY year_month)) / LAG(prediction_value) OVER (PARTITION BY batch_id, metric_id ORDER BY year_month) * 100
*/

-- 计算列4: 同比增长率
/*
Column Name: yoy_growth
SQL Expression: (prediction_value - LAG(prediction_value, 12) OVER (PARTITION BY batch_id, metric_id ORDER BY year_month)) / LAG(prediction_value, 12) OVER (PARTITION BY batch_id, metric_id ORDER BY year_month) * 100
*/

-- ========================================
-- 6. 指标筛选器配置
-- ========================================

-- 获取所有指标列表（用于Superset筛选器）
SELECT 
    metric_id,
    metric_code,
    metric_name,
    metric_level,
    parent_metric_id,
    is_leaf
FROM prediction_analytics.metric_metadata
ORDER BY metric_level, sort_order;

-- 获取指标树形结构（用于Superset树形筛选器）
SELECT 
    metric_id,
    metric_name,
    parent_metric_id,
    metric_level
FROM prediction_analytics.metric_metadata
ORDER BY full_path;

-- 获取指标层级选项
SELECT DISTINCT
    metric_level,
    CASE metric_level
        WHEN 0 THEN '总计'
        WHEN 1 THEN '一级指标'
        WHEN 2 THEN '二级指标'
        WHEN 3 THEN '三级指标'
    END AS level_name
FROM prediction_analytics.metric_metadata
ORDER BY metric_level;

-- ========================================
-- 7. 维度筛选器配置
-- ========================================

-- 获取区域列表
SELECT DISTINCT region_code, region_name
FROM prediction_analytics.dim_region
ORDER BY region_code;

-- 获取产品类别列表
SELECT DISTINCT product_category
FROM prediction_analytics.transaction_dimensions
ORDER BY product_category;

-- 获取客户细分列表
SELECT DISTINCT customer_segment
FROM prediction_analytics.transaction_dimensions
ORDER BY customer_segment;

-- 获取时间范围
SELECT 
    min(year_month) AS start_month,
    max(year_month) AS end_month,
    countDistinct(year_month) AS total_months
FROM prediction_analytics.superset_dataset;

-- ========================================
-- 8. Pivot Table配置示例
-- ========================================

-- Pivot Table配置：按年月、指标、区域分析
/*
Superset Pivot Table配置：

行维度：
- year_month (时间)
- metric_name (指标)

列维度：
- region_code (区域)

值：
- SUM(prediction_value) (预测值总计)

筛选器：
- batch_id (批次)
- metric_level (指标层级)
- product_category (产品类别)
*/

-- Pivot Table查询示例
SELECT 
    year_month,
    metric_name,
    region_code,
    sum(prediction_value) AS total_value
FROM prediction_analytics.superset_dataset
WHERE batch_id = 1
  AND metric_level = 3  -- 叶子指标
GROUP BY year_month, metric_name, region_code
ORDER BY year_month, metric_name
SETTINGS use_query_cache = 1;

-- ========================================
-- 9. 图表配置示例
-- ========================================

-- 图表1: 时间序列线图
SELECT 
    year_month,
    metric_name,
    sum(prediction_value) AS total_value
FROM prediction_analytics.superset_dataset
WHERE batch_id = 1
  AND metric_id IN (11, 12, 13)  -- 移动端、网页端、APP收入
GROUP BY year_month, metric_name
ORDER BY year_month
SETTINGS use_query_cache = 1;

-- 图表2: 堆叠柱状图（按季度）
SELECT 
    year_quarter,
    product_category,
    sum(prediction_value) AS total_value
FROM prediction_analytics.superset_dataset
WHERE batch_id = 1
  AND metric_id = 1  -- 总收入
GROUP BY year_quarter, product_category
ORDER BY year_quarter, product_category
SETTINGS use_query_cache = 1;

-- 图表3: 饼图（按客户细分）
SELECT 
    customer_segment,
    sum(prediction_value) AS total_value,
    round(sum(prediction_value) / sum(sum(prediction_value)) OVER () * 100, 2) AS percentage
FROM prediction_analytics.superset_dataset
WHERE batch_id = 1
  AND metric_id = 1
  AND year_month = '2024-01'
GROUP BY customer_segment
ORDER BY total_value DESC
SETTINGS use_query_cache = 1;

-- 图表4: 热力图（区域×产品类别）
SELECT 
    region_code,
    product_category,
    sum(prediction_value) AS total_value
FROM prediction_analytics.superset_dataset
WHERE batch_id = 1
  AND metric_id = 1
GROUP BY region_code, product_category
ORDER BY region_code, product_category
SETTINGS use_query_cache = 1;

-- ========================================
-- 10. 仪表板配置
-- ========================================

-- 仪表板KPI卡片
SELECT 
    metric_name,
    sum(prediction_value) AS total_value,
    countDistinct(year_month) AS month_count,
    avg(prediction_value) AS avg_value
FROM prediction_analytics.superset_dataset
WHERE batch_id = 1
  AND metric_id IN (1, 2, 3, 4)  -- 核心指标
  AND year_month = '2024-12'
GROUP BY metric_name
SETTINGS use_query_cache = 1;

-- 仪表板趋势卡片
SELECT 
    year_month,
    sum(prediction_value) AS total_value
FROM prediction_analytics.superset_dataset
WHERE batch_id = 1
  AND metric_id = 1
GROUP BY year_month
ORDER BY year_month
SETTINGS use_query_cache = 1;

-- ========================================
-- 11. 高级分析查询
-- ========================================

-- 分析1: 指标贡献度分析
SELECT 
    parent_metric_id,
    parent_metric_name,
    metric_id,
    metric_name,
    sum(prediction_value) AS total_value,
    round(sum(prediction_value) / sum(sum(prediction_value)) OVER (PARTITION BY parent_metric_id) * 100, 2) AS contribution_pct
FROM (
    SELECT 
        m.parent_metric_id,
        pm.metric_name AS parent_metric_name,
        pv.metric_id,
        m.metric_name,
        pv.prediction_value
    FROM prediction_analytics.superset_dataset pv
    INNER JOIN prediction_analytics.metric_metadata m ON pv.metric_id = m.metric_id
    INNER JOIN prediction_analytics.metric_metadata pm ON m.parent_metric_id = pm.metric_id
    WHERE pv.batch_id = 1
      AND pv.year_month = '2024-01'
) sub
GROUP BY parent_metric_id, parent_metric_name, metric_id, metric_name
ORDER BY parent_metric_id, contribution_pct DESC;

-- 分析2: 异常检测
SELECT 
    transaction_key,
    year_month,
    metric_name,
    prediction_value,
    data_quality_score,
    has_anomaly
FROM prediction_analytics.superset_dataset
WHERE batch_id = 1
  AND has_anomaly = 1
ORDER BY data_quality_score ASC
LIMIT 100;

-- 分析3: 批次对比
SELECT 
    year_month,
    metric_name,
    batch_name,
    sum(prediction_value) AS total_value
FROM prediction_analytics.superset_dataset
WHERE metric_id = 1
GROUP BY year_month, metric_name, batch_name
ORDER BY year_month, batch_name
SETTINGS use_query_cache = 1;

-- ========================================
-- 12. Superset配置建议
-- ========================================

/*
Superset配置建议：

1. 数据库连接配置
   - 连接池大小: 10
   - 查询超时: 60秒
   - 结果缓存: 启用

2. 数据集配置
   - 主键: transaction_key, metric_id, month_offset
   - 时间列: year_month
   - 缓存超时: 300秒

3. 图表配置
   - 使用查询缓存
   - 启用数据缓存
   - 限制返回行数

4. 筛选器配置
   - 批次筛选器（必需）
   - 指标层级筛选器
   - 时间范围筛选器
   - 维度筛选器

5. 性能优化
   - 使用PREWHERE
   - 启用查询缓存
   - 限制返回列数
   - 使用LIMIT
*/

-- ========================================
-- 13. 验证集成
-- ========================================

-- 验证视图可用性
SELECT 
    'superset_dataset' AS view_name,
    count() AS row_count
FROM prediction_analytics.superset_dataset
UNION ALL
SELECT 
    'superset_metric_hierarchy' AS view_name,
    count() AS row_count
FROM prediction_analytics.superset_metric_hierarchy
UNION ALL
SELECT 
    'superset_time_series' AS view_name,
    count() AS row_count
FROM prediction_analytics.superset_time_series;

-- 验证查询性能
SELECT 
    query,
    query_duration_ms,
    read_rows,
    formatReadableSize(read_bytes) AS read_size
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query LIKE '%superset_%'
ORDER BY event_time DESC
LIMIT 10;
