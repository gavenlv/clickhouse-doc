-- ========================================
-- 大规模预测数据分析 - 模拟数据生成
-- ========================================
-- 生成测试数据：1000行维度数据 + 预测数据
-- 用于验证模型设计和查询性能
-- ========================================

-- ========================================
-- 1. 插入指标元数据 (20个指标)
-- ========================================

INSERT INTO prediction_analytics.metric_metadata VALUES
-- Level 0: 根节点
(1, 'TOTAL_REVENUE', '总收入', 0, NULL, [1], 1, 0, 3),

-- Level 1: 一级指标
(2, 'PRODUCT_REVENUE', '产品收入', 1, 1, [1, 2], 10, 0, 2),
(3, 'SERVICE_REVENUE', '服务收入', 1, 1, [1, 3], 20, 0, 2),
(4, 'OTHER_REVENUE', '其他收入', 1, 1, [1, 4], 30, 0, 2),

-- Level 2: 二级指标 - 产品收入
(5, 'ONLINE_REVENUE', '线上收入', 2, 2, [1, 2, 5], 101, 0, 3),
(6, 'OFFLINE_REVENUE', '线下收入', 2, 2, [1, 2, 6], 102, 0, 2),

-- Level 2: 二级指标 - 服务收入
(7, 'CONSULTING_REVENUE', '咨询收入', 2, 3, [1, 3, 7], 201, 0, 2),
(8, 'SUPPORT_REVENUE', '支持收入', 2, 3, [1, 3, 8], 202, 0, 2),

-- Level 2: 二级指标 - 其他收入
(9, 'LICENSING_REVENUE', '许可收入', 2, 4, [1, 4, 9], 301, 0, 0),
(10, 'SUBSCRIPTION_REVENUE', '订阅收入', 2, 4, [1, 4, 10], 302, 0, 0),

-- Level 3: 三级指标 - 线上收入
(11, 'MOBILE_REVENUE', '移动端收入', 3, 5, [1, 2, 5, 11], 1011, 1, 0),
(12, 'WEB_REVENUE', '网页端收入', 3, 5, [1, 2, 5, 12], 1012, 1, 0),
(13, 'APP_REVENUE', 'APP收入', 3, 5, [1, 2, 5, 13], 1013, 1, 0),

-- Level 3: 三级指标 - 线下收入
(14, 'STORE_REVENUE', '门店收入', 3, 6, [1, 2, 6, 14], 1021, 1, 0),
(15, 'PARTNER_REVENUE', '合作伙伴收入', 3, 6, [1, 2, 6, 15], 1022, 1, 0),

-- Level 3: 三级指标 - 咨询收入
(16, 'ENTERPRISE_CONSULTING', '企业咨询', 3, 7, [1, 3, 7, 16], 2011, 1, 0),
(17, 'SMB_CONSULTING', '中小企业咨询', 3, 7, [1, 3, 7, 17], 2012, 1, 0),

-- Level 3: 三级指标 - 支持收入
(18, 'PREMIUM_SUPPORT', '高级支持', 3, 8, [1, 3, 8, 18], 2021, 1, 0),
(19, 'BASIC_SUPPORT', '基础支持', 3, 8, [1, 3, 8, 19], 2022, 1, 0),

-- 扩展指标
(20, 'PROJECTED_GROWTH', '预测增长率', 0, NULL, [20], 1000, 1, 0);

-- 验证指标层级
SELECT 
    metric_id,
    metric_code,
    metric_name,
    level,
    parent_metric_id,
    full_path,
    is_leaf
FROM prediction_analytics.metric_metadata
ORDER BY level, sort_order;

-- ========================================
-- 2. 生成年月映射数据 (60个月份)
-- ========================================

INSERT INTO prediction_analytics.month_mapping
SELECT 
    row_number() OVER () AS month_offset,
    formatDateTime(addMonths(toDate('2024-01-01'), number), '%Y-%m') AS year_month,
    toYear(addMonths(toDate('2024-01-01'), number)) AS year,
    toQuarter(addMonths(toDate('2024-01-01'), number)) AS quarter,
    toMonth(addMonths(toDate('2024-01-01'), number)) AS month,
    formatDateTime(addMonths(toDate('2024-01-01'), number), '%M') AS month_name,
    concat(toString(toYear(addMonths(toDate('2024-01-01'), number))), '-Q', toString(toQuarter(addMonths(toDate('2024-01-01'), number)))) AS year_quarter,
    if(addMonths(toDate('2024-01-01'), number) = toStartOfMonth(now()), 1, 0) AS is_current_month,
    toDayOfMonth(lastDay(addMonths(toDate('2024-01-01'), number))) AS days_in_month,
    now() AS created_at
FROM numbers(60);

-- 验证年月映射
SELECT 
    month_offset,
    year_month,
    year,
    quarter,
    month,
    year_quarter
FROM prediction_analytics.month_mapping
ORDER BY month_offset
LIMIT 12;

-- ========================================
-- 3. 插入批次信息
-- ========================================

INSERT INTO prediction_analytics.batch_info VALUES
(1, '预测批次_2024Q1', toDate('2024-01-15'), 'v2.1.0', '2024-01', '2028-12', 60, 20, 10000, 'completed', 
 1500.5, 100.0, 5000.0, now(), now()),
(2, '预测批次_2024Q2', toDate('2024-04-15'), 'v2.2.0', '2024-04', '2029-03', 60, 20, 10000, 'completed',
 1600.8, 120.0, 5500.0, now(), now());

-- ========================================
-- 4. 生成交易维度数据 (1000行测试数据)
-- ========================================

INSERT INTO prediction_analytics.transaction_dimensions
SELECT 
    concat('TXN_', lpad(toString(number + 1), 6, '0')) AS transaction_key,
    1 AS batch_id,
    
    -- 层级维度
    ['APAC', 'EMEA', 'AMER'][toInt8(number % 3) + 1] AS region_code,
    ['CN', 'US', 'UK', 'DE', 'JP', 'AU'][toInt8(number % 6) + 1] AS country_code,
    concat('STATE_', toString(number % 10 + 1)) AS state_code,
    concat('CITY_', toString(number % 50 + 1)) AS city_code,
    
    -- 产品维度
    ['Electronics', 'Clothing', 'Food', 'Home', 'Sports'][toInt8(number % 5) + 1] AS product_category,
    concat('SUBCAT_', toString(number % 20 + 1)) AS product_subcategory,
    concat('PROD_', toString(number % 100 + 1)) AS product_id,
    concat('Product ', toString(number % 100 + 1)) AS product_name,
    concat('SKU_', lpad(toString(number % 500 + 1), 4, '0')) AS sku,
    
    -- 客户维度
    ['Enterprise', 'SMB', 'Consumer'][toInt8(number % 3) + 1] AS customer_segment,
    ['B2B', 'B2C'][toInt8(number % 2) + 1] AS customer_type,
    concat('CUST_', toString(number % 200 + 1)) AS customer_id,
    concat('Customer ', toString(number % 200 + 1)) AS customer_name,
    ['Platinum', 'Gold', 'Silver', 'Bronze'][toInt8(number % 4) + 1] AS customer_tier,
    
    -- 渠道维度
    ['Online', 'Offline', 'Hybrid'][toInt8(number % 3) + 1] AS sales_channel,
    ['Direct', 'Reseller', 'Distributor'][toInt8(number % 3) + 1] AS distribution_channel,
    ['SEO', 'SEM', 'Social', 'Email', 'Referral'][toInt8(number % 5) + 1] AS marketing_channel,
    
    -- 时间维度
    2024 AS transaction_year,
    toUInt8(number % 12 + 1) AS transaction_month,
    toUInt8(ceil(number % 12 / 3.0)) AS transaction_quarter,
    toUInt8(number % 52 + 1) AS transaction_week,
    
    -- 组织维度
    ['BU_North', 'BU_South', 'BU_East', 'BU_West'][toInt8(number % 4) + 1] AS business_unit,
    concat('DEPT_', toString(number % 10 + 1)) AS department,
    concat('TEAM_', toString(number % 20 + 1)) AS team,
    concat('REP_', toString(number % 50 + 1)) AS sales_rep,
    
    -- 财务维度
    concat('CC_', toString(number % 20 + 1)) AS cost_center,
    concat('PC_', toString(number % 15 + 1)) AS profit_center,
    concat('GL_', lpad(toString(number % 30 + 1000), 4, '0')) AS gl_account,
    ['USD', 'EUR', 'GBP', 'JPY'][toInt8(number % 4) + 1] AS currency_code,
    
    -- 扩展维度 (60个)
    concat('DIM1_', toString(number % 10 + 1)) AS dimension_1,
    concat('DIM2_', toString(number % 10 + 1)) AS dimension_2,
    concat('DIM3_', toString(number % 10 + 1)) AS dimension_3,
    concat('DIM4_', toString(number % 10 + 1)) AS dimension_4,
    concat('DIM5_', toString(number % 10 + 1)) AS dimension_5,
    concat('DIM6_', toString(number % 10 + 1)) AS dimension_6,
    concat('DIM7_', toString(number % 10 + 1)) AS dimension_7,
    concat('DIM8_', toString(number % 10 + 1)) AS dimension_8,
    concat('DIM9_', toString(number % 10 + 1)) AS dimension_9,
    concat('DIM10_', toString(number % 10 + 1)) AS dimension_10,
    concat('DIM11_', toString(number % 10 + 1)) AS dimension_11,
    concat('DIM12_', toString(number % 10 + 1)) AS dimension_12,
    concat('DIM13_', toString(number % 10 + 1)) AS dimension_13,
    concat('DIM14_', toString(number % 10 + 1)) AS dimension_14,
    concat('DIM15_', toString(number % 10 + 1)) AS dimension_15,
    concat('DIM16_', toString(number % 10 + 1)) AS dimension_16,
    concat('DIM17_', toString(number % 10 + 1)) AS dimension_17,
    concat('DIM18_', toString(number % 10 + 1)) AS dimension_18,
    concat('DIM19_', toString(number % 10 + 1)) AS dimension_19,
    concat('DIM20_', toString(number % 10 + 1)) AS dimension_20,
    concat('DIM21_', toString(number % 10 + 1)) AS dimension_21,
    concat('DIM22_', toString(number % 10 + 1)) AS dimension_22,
    concat('DIM23_', toString(number % 10 + 1)) AS dimension_23,
    concat('DIM24_', toString(number % 10 + 1)) AS dimension_24,
    concat('DIM25_', toString(number % 10 + 1)) AS dimension_25,
    concat('DIM26_', toString(number % 10 + 1)) AS dimension_26,
    concat('DIM27_', toString(number % 10 + 1)) AS dimension_27,
    concat('DIM28_', toString(number % 10 + 1)) AS dimension_28,
    concat('DIM29_', toString(number % 10 + 1)) AS dimension_29,
    concat('DIM30_', toString(number % 10 + 1)) AS dimension_30,
    concat('DIM31_', toString(number % 10 + 1)) AS dimension_31,
    concat('DIM32_', toString(number % 10 + 1)) AS dimension_32,
    concat('DIM33_', toString(number % 10 + 1)) AS dimension_33,
    concat('DIM34_', toString(number % 10 + 1)) AS dimension_34,
    concat('DIM35_', toString(number % 10 + 1)) AS dimension_35,
    concat('DIM36_', toString(number % 10 + 1)) AS dimension_36,
    concat('DIM37_', toString(number % 10 + 1)) AS dimension_37,
    concat('DIM38_', toString(number % 10 + 1)) AS dimension_38,
    concat('DIM39_', toString(number % 10 + 1)) AS dimension_39,
    concat('DIM40_', toString(number % 10 + 1)) AS dimension_40,
    concat('DIM41_', toString(number % 10 + 1)) AS dimension_41,
    concat('DIM42_', toString(number % 10 + 1)) AS dimension_42,
    concat('DIM43_', toString(number % 10 + 1)) AS dimension_43,
    concat('DIM44_', toString(number % 10 + 1)) AS dimension_44,
    concat('DIM45_', toString(number % 10 + 1)) AS dimension_45,
    concat('DIM46_', toString(number % 10 + 1)) AS dimension_46,
    concat('DIM47_', toString(number % 10 + 1)) AS dimension_47,
    concat('DIM48_', toString(number % 10 + 1)) AS dimension_48,
    concat('DIM49_', toString(number % 10 + 1)) AS dimension_49,
    concat('DIM50_', toString(number % 10 + 1)) AS dimension_50,
    concat('DIM51_', toString(number % 10 + 1)) AS dimension_51,
    concat('DIM52_', toString(number % 10 + 1)) AS dimension_52,
    concat('DIM53_', toString(number % 10 + 1)) AS dimension_53,
    concat('DIM54_', toString(number % 10 + 1)) AS dimension_54,
    concat('DIM55_', toString(number % 10 + 1)) AS dimension_55,
    concat('DIM56_', toString(number % 10 + 1)) AS dimension_56,
    concat('DIM57_', toString(number % 10 + 1)) AS dimension_57,
    concat('DIM58_', toString(number % 10 + 1)) AS dimension_58,
    concat('DIM59_', toString(number % 10 + 1)) AS dimension_59,
    concat('DIM60_', toString(number % 10 + 1)) AS dimension_60,
    
    now() AS created_at,
    now() AS updated_at
FROM numbers(1000);

-- 验证维度数据
SELECT count() AS total_rows FROM prediction_analytics.transaction_dimensions;

SELECT 
    region_code,
    count() AS cnt
FROM prediction_analytics.transaction_dimensions
GROUP BY region_code
ORDER BY cnt DESC;

-- ========================================
-- 5. 生成预测数据 (1000行)
-- ========================================
-- 使用二维数组存储：metrics_values[metric_id][month_offset]
-- 20个指标 × 60个月份 = 1200个值
-- ========================================

INSERT INTO prediction_analytics.prediction_values
SELECT 
    concat('TXN_', lpad(toString(number + 1), 6, '0')) AS transaction_key,
    1 AS batch_id,
    
    -- 生成二维数组：20个指标，每个指标60个月份的预测值
    -- 使用随机值模拟真实预测数据
    arrayMap(
        m_id -> arrayMap(
            m_offset -> 
                -- 基础值 + 季节性波动 + 随机噪声
                round(
                    1000.0 + 
                    sin(m_offset * 3.14159 / 6) * 200 +  -- 季节性
                    (m_id * 50) +                        -- 指标权重
                    (rand() % 100 - 50) * 0.1,           -- 随机噪声
                    2
                ),
            range(60)  -- 60个月份
        ),
        range(20)  -- 20个指标
    ) AS metrics_values,
    
    0.95 + (rand() % 10) / 100.0 AS data_quality_score,
    if(rand() % 100 > 95, 1, 0) AS has_anomaly,
    
    now() AS created_at,
    now() AS updated_at
FROM numbers(1000);

-- 验证预测数据
SELECT 
    count() AS total_rows,
    count() * 20 * 60 AS equivalent_long_format_rows,
    formatReadableSize(sum(data_compressed_bytes)) AS compressed_size
FROM prediction_analytics.prediction_values
ALL INNER JOIN system.parts 
ON table = 'prediction_values' AND database = 'prediction_analytics'
WHERE active = 1;

-- ========================================
-- 6. 生成Nested格式预测数据 (备选方案)
-- ========================================

INSERT INTO prediction_analytics.prediction_values_nested
SELECT 
    concat('TXN_', lpad(toString(number + 1), 6, '0')) AS transaction_key,
    1 AS batch_id,
    
    -- 生成Nested数组
    arrayMap(
        m_id -> m_id + 1,
        range(20)
    ) AS predictions.metric_id,
    
    arrayMap(
        m_id -> arrayMap(
            m_offset -> m_offset + 1,
            range(60)
        ),
        range(20)
    ) AS predictions.month_offset,
    
    arrayMap(
        m_id -> arrayMap(
            m_offset -> round(1000.0 + sin(m_offset * 3.14159 / 6) * 200 + m_id * 50 + (rand() % 100 - 50) * 0.1, 2),
            range(60)
        ),
        range(20)
    ) AS predictions.value,
    
    now() AS created_at
FROM numbers(1000);

-- ========================================
-- 7. 插入维度字典数据
-- ========================================

-- 区域维度
INSERT INTO prediction_analytics.dim_region VALUES
('APAC', 'Asia Pacific', 'GLOBAL', 1, now()),
('EMEA', 'Europe Middle East Africa', 'GLOBAL', 1, now()),
('AMER', 'Americas', 'GLOBAL', 1, now()),
('CN', 'China', 'APAC', 2, now()),
('US', 'United States', 'AMER', 2, now()),
('UK', 'United Kingdom', 'EMEA', 2, now()),
('DE', 'Germany', 'EMEA', 2, now()),
('JP', 'Japan', 'APAC', 2, now()),
('AU', 'Australia', 'APAC', 2, now());

-- 产品维度
INSERT INTO prediction_analytics.dim_product
SELECT 
    concat('PROD_', toString(number + 1)) AS product_id,
    concat('Product ', toString(number + 1)) AS product_name,
    ['Electronics', 'Clothing', 'Food', 'Home', 'Sports'][toInt8(number % 5) + 1] AS product_category,
    concat('SUBCAT_', toString(number % 20 + 1)) AS product_subcategory,
    ['Brand_A', 'Brand_B', 'Brand_C', 'Brand_D'][toInt8(number % 4) + 1] AS brand,
    now() AS created_at
FROM numbers(100);

-- 客户维度
INSERT INTO prediction_analytics.dim_customer
SELECT 
    concat('CUST_', toString(number + 1)) AS customer_id,
    concat('Customer ', toString(number + 1)) AS customer_name,
    ['Enterprise', 'SMB', 'Consumer'][toInt8(number % 3) + 1] AS customer_segment,
    ['B2B', 'B2C'][toInt8(number % 2) + 1] AS customer_type,
    ['Platinum', 'Gold', 'Silver', 'Bronze'][toInt8(number % 4) + 1] AS customer_tier,
    ['Tech', 'Finance', 'Retail', 'Healthcare', 'Manufacturing'][toInt8(number % 5) + 1] AS industry,
    now() AS created_at
FROM numbers(200);

-- ========================================
-- 8. 数据统计验证
-- ========================================

-- 各表数据量统计
SELECT 
    'metric_metadata' AS table_name, count() AS row_count FROM prediction_analytics.metric_metadata
UNION ALL
SELECT 
    'month_mapping' AS table_name, count() AS row_count FROM prediction_analytics.month_mapping
UNION ALL
SELECT 
    'batch_info' AS table_name, count() AS row_count FROM prediction_analytics.batch_info
UNION ALL
SELECT 
    'transaction_dimensions' AS table_name, count() AS row_count FROM prediction_analytics.transaction_dimensions
UNION ALL
SELECT 
    'prediction_values' AS table_name, count() AS row_count FROM prediction_analytics.prediction_values
UNION ALL
SELECT 
    'prediction_values_nested' AS table_name, count() AS row_count FROM prediction_analytics.prediction_values_nested
UNION ALL
SELECT 
    'dim_region' AS table_name, count() AS row_count FROM prediction_analytics.dim_region
UNION ALL
SELECT 
    'dim_product' AS table_name, count() AS row_count FROM prediction_analytics.dim_product
UNION ALL
SELECT 
    'dim_customer' AS table_name, count() AS row_count FROM prediction_analytics.dim_customer;

-- 存储空间统计
SELECT 
    table,
    formatReadableSize(sum(data_compressed_bytes)) AS compressed_size,
    formatReadableSize(sum(data_uncompressed_bytes)) AS uncompressed_size,
    round(sum(data_compressed_bytes) / sum(data_uncompressed_bytes) * 100, 2) AS compression_ratio
FROM system.parts
WHERE database = 'prediction_analytics' AND active = 1
GROUP BY table
ORDER BY sum(data_compressed_bytes) DESC;

-- ========================================
-- 9. 示例：从原始长格式数据转换
-- ========================================
-- 如果数据科学家提供的是长格式数据，使用此脚本转换

-- 假设原始数据格式
-- CREATE TABLE prediction_analytics.raw_predictions (
--     transaction_key String,
--     batch_id UInt32,
--     prediction_month String,
--     metric_id UInt8,
--     metric_value Float64
-- ) ENGINE = MergeTree ORDER BY (batch_id, transaction_key);

-- 转换为宽格式
-- INSERT INTO prediction_analytics.prediction_values
-- SELECT 
--     transaction_key,
--     batch_id,
--     arrayMap(
--         m_id -> arrayMap(
--             m_offset -> 
--                 any(metric_value),
--             range(60)
--         ),
--         range(20)
--     ) AS metrics_values,
--     now() AS created_at
-- FROM prediction_analytics.raw_predictions
-- GROUP BY transaction_key, batch_id;

-- ========================================
-- 10. 示例：从宽格式数组读取特定值
-- ========================================

-- 查询某个transaction的特定指标和月份的值
SELECT 
    transaction_key,
    metrics_values[1][1] AS metric_1_month_1,   -- 第1个指标第1个月
    metrics_values[1][12] AS metric_1_month_12, -- 第1个指标第12个月
    metrics_values[20][60] AS metric_20_month_60 -- 第20个指标第60个月
FROM prediction_analytics.prediction_values
LIMIT 5;

-- 查询某个指标在所有月份的值
SELECT 
    transaction_key,
    arrayJoin(metrics_values[1]) AS metric_1_all_months,
    arrayJoin(metrics_values[2]) AS metric_2_all_months
FROM prediction_analytics.prediction_values
LIMIT 5;
