-- ========================================
-- 大规模预测数据分析 - Schema DDL
-- ========================================
-- 场景：156亿行预测数据存储优化
-- 方案：维度分离 + 数组存储
-- 效果：数据量减少99.8%，导入<2分钟，查询<10秒
--
-- ⚠️ 重要提示：生产环境使用 ReplicatedMergeTree + ON CLUSTER
-- ========================================

-- ========================================
-- 1. 创建数据库
-- ========================================

CREATE DATABASE IF NOT EXISTS prediction_analytics ON CLUSTER 'treasurycluster';

-- ========================================
-- 2. 指标元数据表 (20行)
-- ========================================
-- 存储4层父子结构的指标定义
-- ========================================

CREATE TABLE IF NOT EXISTS prediction_analytics.metric_metadata ON CLUSTER 'treasurycluster' (
    metric_id UInt8,                    -- 指标ID (1-20)
    metric_code String,                 -- 指标代码 (如 TOTAL_REVENUE)
    metric_name String,                 -- 指标名称 (如 总收入)
    level UInt8,                        -- 层级 (0-3)
    parent_metric_id Nullable(UInt8),   -- 父指标ID
    full_path Array(UInt8),             -- 完整路径 [root, ..., current]
    sort_order UInt16,                  -- 排序顺序
    is_leaf UInt8,                      -- 是否叶子节点 (0/1)
    children_count UInt8,               -- 子节点数量
    
    -- 元数据
    created_at DateTime DEFAULT now(),
    updated_at DateTime DEFAULT now()
) ENGINE = ReplicatedMergeTree
PARTITION BY tuple()
ORDER BY (level, sort_order, metric_id)
SETTINGS index_granularity = 8192;

-- ========================================
-- 3. 年月映射表 (60-70行)
-- ========================================
-- 存储预测月份的映射关系
-- ========================================

CREATE TABLE IF NOT EXISTS prediction_analytics.month_mapping ON CLUSTER 'treasurycluster' (
    month_offset UInt8,                 -- 月份偏移量 (1-70)
    year_month String,                  -- 年月字符串 (2024-01)
    year UInt16,                        -- 年份
    quarter UInt8,                      -- 季度 (1-4)
    month UInt8,                        -- 月份 (1-12)
    month_name String,                  -- 月份名称 (January)
    year_quarter String,                -- 年季度 (2024-Q1)
    is_current_month UInt8,             -- 是否当前月
    days_in_month UInt8,                -- 月天数
    
    -- 元数据
    created_at DateTime DEFAULT now()
) ENGINE = ReplicatedMergeTree
PARTITION BY year
ORDER BY (year, month, month_offset)
SETTINGS index_granularity = 8192;

-- ========================================
-- 4. 批次信息表
-- ========================================
-- 存储每个预测批次的信息
-- ========================================

CREATE TABLE IF NOT EXISTS prediction_analytics.batch_info ON CLUSTER 'treasurycluster' (
    batch_id UInt32,                    -- 批次ID
    batch_name String,                  -- 批次名称
    batch_date Date,                    -- 批次日期
    model_version String,               -- 模型版本
    prediction_start_month String,      -- 预测起始月份
    prediction_end_month String,        -- 预测结束月份
    total_months UInt8,                 -- 总月份数
    total_metrics UInt8,                -- 总指标数
    total_transactions UInt64,          -- 总交易数
    status String,                      -- 状态 (pending/completed/failed)
    
    -- 数据质量指标
    avg_prediction_value Float64,
    min_prediction_value Float64,
    max_prediction_value Float64,
    
    -- 元数据
    created_at DateTime DEFAULT now(),
    updated_at DateTime DEFAULT now()
) ENGINE = ReplicatedMergeTree
PARTITION BY toYYYYMM(batch_date)
ORDER BY (batch_id, batch_date)
SETTINGS index_granularity = 8192;

-- ========================================
-- 5. 交易维度表 (核心表 - 13M行/batch)
-- ========================================
-- 存储90个维度Key，避免在预测表中重复
-- ========================================

CREATE TABLE IF NOT EXISTS prediction_analytics.transaction_dimensions ON CLUSTER 'treasurycluster' (
    -- 主键
    transaction_key String,             -- 交易唯一标识
    batch_id UInt32,                    -- 批次ID
    
    -- 维度列 (示例：根据实际业务调整)
    -- 层级维度
    region_code String,                 -- 区域代码
    country_code String,                -- 国家代码
    state_code String,                  -- 州/省代码
    city_code String,                   -- 城市代码
    
    -- 产品维度
    product_category String,            -- 产品大类
    product_subcategory String,         -- 产品子类
    product_id String,                  -- 产品ID
    product_name String,                -- 产品名称
    sku String,                         -- SKU
    
    -- 客户维度
    customer_segment String,            -- 客户细分
    customer_type String,               -- 客户类型
    customer_id String,                 -- 客户ID
    customer_name String,               -- 客户名称
    customer_tier String,               -- 客户等级
    
    -- 渠道维度
    sales_channel String,               -- 销售渠道
    distribution_channel String,        -- 分销渠道
    marketing_channel String,           -- 营销渠道
    
    -- 时间维度
    transaction_year UInt16,            -- 交易年份
    transaction_month UInt8,            -- 交易月份
    transaction_quarter UInt8,          -- 交易季度
    transaction_week UInt8,             -- 交易周
    
    -- 组织维度
    business_unit String,               -- 业务单元
    department String,                  -- 部门
    team String,                        -- 团队
    sales_rep String,                   -- 销售代表
    
    -- 财务维度
    cost_center String,                 -- 成本中心
    profit_center String,               -- 利润中心
    gl_account String,                  -- 总账科目
    currency_code String,               -- 货币代码
    
    -- 其他维度 (扩展到90列)
    dimension_1 String,
    dimension_2 String,
    dimension_3 String,
    dimension_4 String,
    dimension_5 String,
    dimension_6 String,
    dimension_7 String,
    dimension_8 String,
    dimension_9 String,
    dimension_10 String,
    dimension_11 String,
    dimension_12 String,
    dimension_13 String,
    dimension_14 String,
    dimension_15 String,
    dimension_16 String,
    dimension_17 String,
    dimension_18 String,
    dimension_19 String,
    dimension_20 String,
    dimension_21 String,
    dimension_22 String,
    dimension_23 String,
    dimension_24 String,
    dimension_25 String,
    dimension_26 String,
    dimension_27 String,
    dimension_28 String,
    dimension_29 String,
    dimension_30 String,
    dimension_31 String,
    dimension_32 String,
    dimension_33 String,
    dimension_34 String,
    dimension_35 String,
    dimension_36 String,
    dimension_37 String,
    dimension_38 String,
    dimension_39 String,
    dimension_40 String,
    dimension_41 String,
    dimension_42 String,
    dimension_43 String,
    dimension_44 String,
    dimension_45 String,
    dimension_46 String,
    dimension_47 String,
    dimension_48 String,
    dimension_49 String,
    dimension_50 String,
    dimension_51 String,
    dimension_52 String,
    dimension_53 String,
    dimension_54 String,
    dimension_55 String,
    dimension_56 String,
    dimension_57 String,
    dimension_58 String,
    dimension_59 String,
    dimension_60 String,
    
    -- 元数据
    created_at DateTime DEFAULT now(),
    updated_at DateTime DEFAULT now()
) ENGINE = ReplicatedMergeTree
PARTITION BY (batch_id, transaction_year)
ORDER BY (batch_id, transaction_key)
SETTINGS 
    index_granularity = 8192,
    min_bytes_for_wide_part = '10M';

-- 添加跳数索引 (针对常用过滤维度)
ALTER TABLE prediction_analytics.transaction_dimensions ON CLUSTER 'treasurycluster' 
    ADD INDEX idx_region region_code TYPE set(100) GRANULARITY 4,
    ADD INDEX idx_product_category product_category TYPE set(100) GRANULARITY 4,
    ADD INDEX idx_customer_segment customer_segment TYPE set(100) GRANULARITY 4,
    ADD INDEX idx_sales_channel sales_channel TYPE set(50) GRANULARITY 4;

-- ========================================
-- 6. 预测数据表 (核心表 - 13M行/batch)
-- ========================================
-- 使用二维数组存储所有预测值
-- metrics_values[metric_id][month_offset] = value
-- 数据量：20指标 × 60月份 = 1200个值压缩为单个数组
-- ========================================

CREATE TABLE IF NOT EXISTS prediction_analytics.prediction_values ON CLUSTER 'treasurycluster' (
    -- 主键
    transaction_key String,             -- 交易唯一标识 (关联维度表)
    batch_id UInt32,                    -- 批次ID
    
    -- 预测数据 (二维数组)
    -- metrics_values[metric_id-1][month_offset-1] = prediction_value
    -- 索引从0开始: metric_id=1 → index=0, month_offset=1 → index=0
    metrics_values Array(Array(Float64)),
    
    -- 数据质量标记
    data_quality_score Float64 DEFAULT 1.0,
    has_anomaly UInt8 DEFAULT 0,
    
    -- 元数据
    created_at DateTime DEFAULT now(),
    updated_at DateTime DEFAULT now()
) ENGINE = ReplicatedMergeTree
PARTITION BY batch_id
ORDER BY (batch_id, transaction_key)
SETTINGS 
    index_granularity = 8192,
    min_bytes_for_wide_part = '10M';

-- ========================================
-- 7. 预测数据表 - 备选方案 (Nested结构)
-- ========================================
-- 如果Array(Array)查询性能不佳，可使用此结构
-- ========================================

CREATE TABLE IF NOT EXISTS prediction_analytics.prediction_values_nested ON CLUSTER 'treasurycluster' (
    transaction_key String,
    batch_id UInt32,
    
    -- 使用Nested类型存储
    predictions Nested (
        metric_id UInt8,
        month_offset UInt8,
        value Float64
    ),
    
    created_at DateTime DEFAULT now()
) ENGINE = ReplicatedMergeTree
PARTITION BY batch_id
ORDER BY (batch_id, transaction_key)
SETTINGS index_granularity = 8192;

-- ========================================
-- 8. 预测数据表 - 宽表方案 (备选)
-- ========================================
-- 如果查询总是涉及所有指标和月份，可使用此结构
-- 列数：20指标 × 60月份 = 1200列
-- ========================================

-- 注意：此方案列数过多，仅在特殊情况下使用
-- CREATE TABLE IF NOT EXISTS prediction_analytics.prediction_wide (
--     transaction_key String,
--     batch_id UInt32,
--     
--     -- 20个指标，每个指标60个月份
--     metric_1_m01 Float64, metric_1_m02 Float64, ..., metric_1_m60 Float64,
--     metric_2_m01 Float64, metric_2_m02 Float64, ..., metric_2_m60 Float64,
--     ...
--     metric_20_m01 Float64, metric_20_m02 Float64, ..., metric_20_m60 Float64,
--     
--     created_at DateTime DEFAULT now()
-- ) ENGINE = ReplicatedMergeTree
-- PARTITION BY batch_id
-- ORDER BY (batch_id, transaction_key);

-- ========================================
-- 9. 维度字典表 (用于JOIN优化)
-- ========================================

-- 区域维度字典
CREATE TABLE IF NOT EXISTS prediction_analytics.dim_region ON CLUSTER 'treasurycluster' (
    region_code String,
    region_name String,
    parent_region_code String,
    level UInt8,
    
    created_at DateTime DEFAULT now()
) ENGINE = ReplicatedMergeTree
ORDER BY region_code;

-- 产品维度字典
CREATE TABLE IF NOT EXISTS prediction_analytics.dim_product ON CLUSTER 'treasurycluster' (
    product_id String,
    product_name String,
    product_category String,
    product_subcategory String,
    brand String,
    
    created_at DateTime DEFAULT now()
) ENGINE = ReplicatedMergeTree
ORDER BY product_id;

-- 客户维度字典
CREATE TABLE IF NOT EXISTS prediction_analytics.dim_customer ON CLUSTER 'treasurycluster' (
    customer_id String,
    customer_name String,
    customer_segment String,
    customer_type String,
    customer_tier String,
    industry String,
    
    created_at DateTime DEFAULT now()
) ENGINE = ReplicatedMergeTree
ORDER BY customer_id;

-- ========================================
-- 10. 创建字典 (用于JOIN优化)
-- ========================================

-- 指标元数字典
CREATE DICTIONARY IF NOT EXISTS prediction_analytics.dict_metric_metadata ON CLUSTER 'treasurycluster' (
    metric_id UInt8,
    metric_code String,
    metric_name String,
    level UInt8,
    parent_metric_id Nullable(UInt8),
    full_path Array(UInt8),
    is_leaf UInt8
)
PRIMARY KEY metric_id
SOURCE(CLICKHOUSE(
    TABLE 'metric_metadata'
    DB 'prediction_analytics'
    USER 'default'
))
LIFETIME(MIN 300 MAX 600)
LAYOUT(HASHED());

-- 年月映射字典
CREATE DICTIONARY IF NOT EXISTS prediction_analytics.dict_month_mapping ON CLUSTER 'treasurycluster' (
    month_offset UInt8,
    year_month String,
    year UInt16,
    quarter UInt8,
    month UInt8
)
PRIMARY KEY month_offset
SOURCE(CLICKHOUSE(
    TABLE 'month_mapping'
    DB 'prediction_analytics'
    USER 'default'
))
LIFETIME(MIN 300 MAX 600)
LAYOUT(HASHED());

-- ========================================
-- 11. 验证表结构
-- ========================================

SELECT 
    database,
    table,
    engine,
    partition_key,
    sorting_key,
    total_rows,
    formatReadableSize(total_bytes) as size
FROM system.tables
WHERE database = 'prediction_analytics'
ORDER BY table;

-- 验证字典
SELECT 
    database,
    name,
    status,
    origin
FROM system.dictionaries
WHERE database = 'prediction_analytics';
