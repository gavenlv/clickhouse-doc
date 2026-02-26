-- ========================================
-- 大规模预测数据分析 - 查询优化
-- ========================================
-- 目标：查询响应 < 10秒
-- 策略：物化视图、预聚合、跳数索引、查询缓存
-- ========================================

-- ========================================
-- 1. 物化视图 - 按维度组合预聚合
-- ========================================

-- 物化视图1: 按区域+产品+客户+年月聚合
CREATE MATERIALIZED VIEW IF NOT EXISTS prediction_analytics.mv_agg_region_product_customer
ON CLUSTER 'treasurycluster'
TO prediction_analytics.agg_region_product_customer AS
SELECT 
    batch_id,
    year_month,
    year,
    quarter,
    
    region_code,
    product_category,
    customer_segment,
    
    metric_id,
    metric_code,
    metric_name,
    
    sum(prediction_value) AS total_value,
    avg(prediction_value) AS avg_value,
    count() AS record_count,
    min(prediction_value) AS min_value,
    max(prediction_value) AS max_value
    
FROM prediction_analytics.prediction_full_view
GROUP BY 
    batch_id, year_month, year, quarter,
    region_code, product_category, customer_segment,
    metric_id, metric_code, metric_name;

-- 目标表
CREATE TABLE IF NOT EXISTS prediction_analytics.agg_region_product_customer ON CLUSTER 'treasurycluster' (
    batch_id UInt32,
    year_month String,
    year UInt16,
    quarter UInt8,
    
    region_code String,
    product_category String,
    customer_segment String,
    
    metric_id UInt8,
    metric_code String,
    metric_name String,
    
    total_value Float64,
    avg_value Float64,
    record_count UInt64,
    min_value Float64,
    max_value Float64,
    
    created_at DateTime DEFAULT now()
) ENGINE = ReplicatedSummingMergeTree
PARTITION BY (batch_id, year)
ORDER BY (batch_id, year_month, region_code, product_category, customer_segment, metric_id)
SETTINGS index_granularity = 8192;

-- ========================================
-- 2. 物化视图 - 指标层级汇总
-- ========================================

CREATE MATERIALIZED VIEW IF NOT EXISTS prediction_analytics.mv_metric_hierarchy_agg
ON CLUSTER 'treasurycluster'
TO prediction_analytics.agg_metric_hierarchy AS
SELECT 
    batch_id,
    year_month,
    
    metric_id,
    metric_code,
    metric_name,
    metric_level,
    parent_metric_id,
    
    region_code,
    product_category,
    
    sum(prediction_value) AS total_value,
    count() AS record_count
    
FROM prediction_analytics.prediction_full_view
GROUP BY 
    batch_id, year_month,
    metric_id, metric_code, metric_name, metric_level, parent_metric_id,
    region_code, product_category;

CREATE TABLE IF NOT EXISTS prediction_analytics.agg_metric_hierarchy ON CLUSTER 'treasurycluster' (
    batch_id UInt32,
    year_month String,
    
    metric_id UInt8,
    metric_code String,
    metric_name String,
    metric_level UInt8,
    parent_metric_id UInt8,
    
    region_code String,
    product_category String,
    
    total_value Float64,
    record_count UInt64,
    
    created_at DateTime DEFAULT now()
) ENGINE = ReplicatedSummingMergeTree
PARTITION BY (batch_id, toYYYYMM(parseDateTimeBestEffort(year_month)))
ORDER BY (batch_id, year_month, metric_id, region_code, product_category)
SETTINGS index_granularity = 8192;

-- ========================================
-- 3. 物化视图 - 年度汇总
-- ========================================

CREATE MATERIALIZED VIEW IF NOT EXISTS prediction_analytics.mv_yearly_agg
ON CLUSTER 'treasurycluster'
TO prediction_analytics.agg_yearly AS
SELECT 
    batch_id,
    year,
    
    metric_id,
    metric_code,
    metric_name,
    
    region_code,
    product_category,
    customer_segment,
    
    sum(prediction_value) AS annual_total,
    avg(prediction_value) AS annual_avg,
    count() AS month_count
    
FROM prediction_analytics.prediction_full_view
GROUP BY 
    batch_id, year,
    metric_id, metric_code, metric_name,
    region_code, product_category, customer_segment;

CREATE TABLE IF NOT EXISTS prediction_analytics.agg_yearly ON CLUSTER 'treasurycluster' (
    batch_id UInt32,
    year UInt16,
    
    metric_id UInt8,
    metric_code String,
    metric_name String,
    
    region_code String,
    product_category String,
    customer_segment String,
    
    annual_total Float64,
    annual_avg Float64,
    month_count UInt64,
    
    created_at DateTime DEFAULT now()
) ENGINE = ReplicatedSummingMergeTree
PARTITION BY (batch_id, year)
ORDER BY (batch_id, year, metric_id, region_code, product_category, customer_segment)
SETTINGS index_granularity = 8192;

-- ========================================
-- 4. 跳数索引优化
-- ========================================

-- 为预测值表添加跳数索引
ALTER TABLE prediction_analytics.prediction_values ON CLUSTER 'treasurycluster'
    ADD INDEX idx_data_quality data_quality_score TYPE minmax GRANULARITY 4,
    ADD INDEX idx_has_anomaly has_anomaly TYPE set(2) GRANULARITY 4;

-- 为维度表添加跳数索引
ALTER TABLE prediction_analytics.transaction_dimensions ON CLUSTER 'treasurycluster'
    ADD INDEX idx_country country_code TYPE set(200) GRANULARITY 4,
    ADD INDEX idx_product product_id TYPE bloom_filter(0.01) GRANULARITY 4,
    ADD INDEX idx_customer customer_id Type bloom_filter(0.01) GRANULARITY 4;

-- 为聚合表添加跳数索引
ALTER TABLE prediction_analytics.agg_region_product_customer ON CLUSTER 'treasurycluster'
    ADD INDEX idx_metric metric_id TYPE set(25) GRANULARITY 4,
    ADD INDEX idx_year_month year_month TYPE set(100) GRANULARITY 4;

-- ========================================
-- 5. Projection (多维索引) - ClickHouse 21.6+
-- ========================================

-- 为预测表创建Projection，加速按指标查询
ALTER TABLE prediction_analytics.prediction_values ON CLUSTER 'treasurycluster'
    ADD PROJECTION prj_by_metric (
        SELECT 
            batch_id,
            transaction_key,
            metrics_values,
            data_quality_score
        ORDER BY (batch_id, data_quality_score)
    );

-- 为维度表创建Projection
ALTER TABLE prediction_analytics.transaction_dimensions ON CLUSTER 'treasurycluster'
    ADD PROJECTION prj_by_region_product (
        SELECT *
        ORDER BY (batch_id, region_code, product_category, customer_segment)
    );

-- 物化Projection
ALTER TABLE prediction_analytics.prediction_values ON CLUSTER 'treasurycluster'
    MATERIALIZE PROJECTION prj_by_metric;

ALTER TABLE prediction_analytics.transaction_dimensions ON CLUSTER 'treasurycluster'
    MATERIALIZE PROJECTION prj_by_region_product;

-- ========================================
-- 6. 查询缓存配置
-- ========================================

-- 启用查询缓存 (ClickHouse 22.7+)
SET use_query_cache = 1;
SET query_cache_min_query_duration = 1000;  -- 最小执行时间1秒
SET query_cache_max_entries = 1000;
SET query_cache_max_size_in_bytes = 1073741824;  -- 1GB

-- 查询缓存状态
SELECT 
    name,
    value,
    description
FROM system.settings
WHERE name LIKE '%query_cache%';

-- 查看缓存内容
SELECT 
    query,
    result_size,
    stale_time,
    is_initial_query
FROM system.query_cache;

-- 清除缓存
-- SYSTEM DROP QUERY CACHE;

-- ========================================
-- 7. 优化查询示例
-- ========================================

-- 查询1: 使用聚合表 + 查询缓存
SELECT 
    year_month,
    metric_name,
    region_code,
    sum(total_value) AS total
FROM prediction_analytics.agg_region_product_customer
WHERE batch_id = 1
  AND metric_id IN (1, 2, 3)
  AND year_month BETWEEN '2024-01' AND '2024-12'
GROUP BY year_month, metric_name, region_code
ORDER BY year_month, metric_name
SETTINGS use_query_cache = 1;

-- 查询2: 使用PREWHERE优化
SELECT 
    year_month,
    metric_name,
    sum(prediction_value) AS total
FROM prediction_analytics.prediction_full_view
PREWHERE batch_id = 1
  AND metric_id = 1
WHERE year_month >= '2024-01'
GROUP BY year_month, metric_name
SETTINGS use_query_cache = 1;

-- 查询3: 使用Projection优化
SELECT 
    batch_id,
    count() AS cnt,
    avg(data_quality_score) AS avg_quality
FROM prediction_analytics.prediction_values
WHERE data_quality_score > 0.9
GROUP BY batch_id
SETTINGS force_optimize_projection = 1;

-- ========================================
-- 8. 查询性能监控
-- ========================================

-- 慢查询分析
SELECT 
    query_id,
    query_duration_ms / 1000 AS duration_sec,
    read_rows,
    read_bytes,
    memory_usage,
    substring(query, 1, 200) AS query
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query_duration_ms > 5000  -- 超过5秒
  AND query LIKE '%prediction_analytics%'
ORDER BY query_duration_ms DESC
LIMIT 10;

-- 查询缓存命中率
SELECT 
    'Query Cache Hit Rate' AS metric,
    round(
        (SELECT count() FROM system.query_log WHERE type = 'QueryFinish' AND has_query_cache = 1) * 100.0 /
        NULLIF((SELECT count() FROM system.query_log WHERE type = 'QueryFinish'), 0),
        2
    ) AS percentage;

-- 索引使用统计
SELECT 
    table,
    index_name,
    index_type,
    count() AS usage_count
FROM system.query_log
ARRAY JOIN tables
WHERE type = 'QueryFinish'
  AND tables LIKE '%prediction_analytics%'
GROUP BY table, index_name, index_type;

-- ========================================
-- 9. 查询优化提示
-- ========================================

-- 提示1: 始终使用batch_id过滤
SELECT 'Tip 1: Always filter by batch_id for partition pruning' AS tip;

-- 提示2: 使用PREWHERE代替WHERE
SELECT 'Tip 2: Use PREWHERE for filtering columns that reduce data significantly' AS tip;

-- 提示3: 避免SELECT *
SELECT 'Tip 3: Avoid SELECT *, specify only needed columns' AS tip;

-- 提示4: 使用LIMIT
SELECT 'Tip 4: Always use LIMIT for exploratory queries' AS tip;

-- 提示5: 启用查询缓存
SELECT 'Tip 5: Enable query cache for repeated queries' AS tip;

-- ========================================
-- 10. 性能基准测试
-- ========================================

-- 测试1: 直接查询原表
SELECT 
    year_month,
    metric_name,
    sum(prediction_value) AS total
FROM prediction_analytics.prediction_full_view
WHERE batch_id = 1
  AND metric_id = 1
GROUP BY year_month, metric_name
ORDER BY year_month
SETTINGS use_query_cache = 0;

-- 测试2: 使用聚合表
SELECT 
    year_month,
    metric_name,
    sum(total_value) AS total
FROM prediction_analytics.agg_region_product_customer
WHERE batch_id = 1
  AND metric_id = 1
GROUP BY year_month, metric_name
ORDER BY year_month
SETTINGS use_query_cache = 0;

-- 测试3: 使用查询缓存
SELECT 
    year_month,
    metric_name,
    sum(total_value) AS total
FROM prediction_analytics.agg_region_product_customer
WHERE batch_id = 1
  AND metric_id = 1
GROUP BY year_month, metric_name
ORDER BY year_month
SETTINGS use_query_cache = 1;

-- 对比测试结果
SELECT 
    'Full View (No Cache)' AS query_type,
    avg(query_duration_ms) AS avg_duration_ms,
    avg(read_rows) AS avg_read_rows
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query LIKE '%prediction_full_view%'
  AND query NOT LIKE '%use_query_cache%'
UNION ALL
SELECT 
    'Aggregated Table (No Cache)' AS query_type,
    avg(query_duration_ms) AS avg_duration_ms,
    avg(read_rows) AS avg_read_rows
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query LIKE '%agg_region_product_customer%'
  AND query NOT LIKE '%use_query_cache%'
UNION ALL
SELECT 
    'Aggregated Table (With Cache)' AS query_type,
    avg(query_duration_ms) AS avg_duration_ms,
    avg(read_rows) AS avg_read_rows
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query LIKE '%agg_region_product_customer%'
  AND query LIKE '%use_query_cache%';

-- ========================================
-- 11. TTL配置 (数据生命周期)
-- ========================================

-- 为预测数据设置TTL
ALTER TABLE prediction_analytics.prediction_values ON CLUSTER 'treasurycluster'
    MODIFY TTL created_at + INTERVAL 2 YEAR DELETE;

ALTER TABLE prediction_analytics.agg_region_product_customer ON CLUSTER 'treasurycluster'
    MODIFY TTL created_at + INTERVAL 3 YEAR DELETE;

-- 查看TTL配置
SELECT 
    database,
    table,
    name,
    expression,
    min
FROM system.data_skipping_indices
WHERE database = 'prediction_analytics';

SELECT 
    database,
    table,
    engine,
    partition_key,
    sorting_key,
    ttl_expression
FROM system.tables
WHERE database = 'prediction_analytics'
  AND ttl_expression != '';

-- ========================================
-- 12. 查询优化总结
-- ========================================

/*
查询优化策略总结：

1. 使用物化视图预聚合
   - 创建常用维度组合的聚合表
   - 减少查询时的计算量

2. 使用跳数索引
   - 为高频过滤字段添加索引
   - 减少数据扫描量

3. 使用Projection
   - 为不同查询模式创建优化存储
   - 自动选择最优路径

4. 使用查询缓存
   - 缓存重复查询结果
   - 减少计算开销

5. 使用PREWHERE
   - 将过滤条件前置
   - 减少数据读取量

6. 使用分区裁剪
   - 始终使用batch_id过滤
   - 利用分区减少扫描

7. 控制返回数据量
   - 使用LIMIT
   - 避免SELECT *

8. 监控和优化
   - 定期检查慢查询
   - 分析索引使用情况
   - 调整TTL策略
*/
