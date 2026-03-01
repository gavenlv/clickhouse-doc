-- ========================================
-- GCS Parquet 导入基础示例
-- ========================================
-- 说明：展示如何从 GCS Bucket 导入 Parquet 文件到 ClickHouse
-- 包含：表创建、权限配置、基础导入语法、性能优化
-- ========================================

-- ========================================
-- 1. 准备工作：配置 GCS 访问权限
-- ========================================

-- 方法1：使用 GCS HMAC 密钥（推荐）
-- 需要先在 GCP Console 创建 HMAC 密钥
-- 位置：GCP Console -> Cloud Storage -> Settings -> Interoperability

-- 配置访问密钥（在 users.xml 或通过 SQL）
/*
<users>
    <default>
        <access_key_id>YOUR_ACCESS_KEY</access_key_id>
        <secret_access_key>YOUR_SECRET_KEY</secret_access_key>
    </default>
</users>
*/

-- 方法2：使用 GCP Service Account（生产环境推荐）
-- 需要配置 Workload Identity 或挂载服务账号密钥

-- 方法3：使用 Storage Integration（ClickHouse 23.8+）
-- 更安全的方式，支持 IAM 权限

-- ========================================
-- 2. 创建目标表
-- ========================================

-- 示例表：用户行为事件表（90列示例）
CREATE DATABASE IF NOT EXISTS gcs_import_examples;

CREATE TABLE IF NOT EXISTS gcs_import_examples.user_events (
    -- 基础字段（10列）
    event_id String,
    event_type String,
    event_time DateTime,
    user_id UInt64,
    session_id String,
    
    -- 设备信息（10列）
    device_id String,
    device_type String,
    os_name String,
    os_version String,
    browser_name String,
    browser_version String,
    screen_resolution String,
    language String,
    timezone String,
    ip_address String,
    
    -- 地理信息（10列）
    country String,
    country_code String,
    region String,
    city String,
    latitude Float64,
    longitude Float64,
    postal_code String,
    metro_code String,
    area_code String,
    isp String,
    
    -- 页面信息（10列）
    page_url String,
    page_title String,
    page_category String,
    referrer_url String,
    referrer_domain String,
    landing_page String,
    exit_page String,
    page_depth UInt32,
    scroll_depth Float32,
    time_on_page UInt32,
    
    -- 营销信息（10列）
    campaign_source String,
    campaign_medium String,
    campaign_name String,
    campaign_term String,
    campaign_content String,
    utm_source String,
    utm_medium String,
    utm_campaign String,
    utm_term String,
    utm_content String,
    
    -- 电商信息（15列）
    product_id String,
    product_name String,
    product_category String,
    product_price Float64,
    product_quantity UInt32,
    product_brand String,
    product_sku String,
    cart_value Float64,
    order_id String,
    order_value Float64,
    payment_method String,
    shipping_method String,
    coupon_code String,
    discount_amount Float64,
    tax_amount Float64,
    
    -- 自定义字段（15列）
    custom_field1 String,
    custom_field2 String,
    custom_field3 String,
    custom_field4 String,
    custom_field5 String,
    custom_field6 Float64,
    custom_field7 Float64,
    custom_field8 UInt64,
    custom_field9 UInt64,
    custom_field10 DateTime,
    custom_field11 String,
    custom_field12 String,
    custom_field13 String,
    custom_field14 String,
    custom_field15 String,
    
    -- 元数据（10列）
    app_version String,
    sdk_version String,
    platform String,
    environment String,
    event_name String,
    event_category String,
    event_action String,
    event_label String,
    event_value Float64,
    processing_time DateTime DEFAULT now()
)
ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_time, user_id, event_id)
SETTINGS index_granularity = 8192;

-- ========================================
-- 3. 基础导入方式
-- ========================================

-- 方式1：使用 gcs() 函数（最简单）
-- 自动检测 Parquet schema
INSERT INTO gcs_import_examples.user_events
SELECT * FROM gcs(
    'https://storage.googleapis.com/your-bucket-name/path/to/data/*.parquet',
    'Parquet'
);

-- 方式2：指定 schema（推荐，避免自动检测开销）
INSERT INTO gcs_import_examples.user_events
SELECT * FROM gcs(
    'https://storage.googleapis.com/your-bucket-name/path/to/data/*.parquet',
    'Parquet',
    'event_id String, 
     event_type String, 
     event_time DateTime,
     user_id UInt64,
     session_id String,
     -- ... 其他字段
     processing_time DateTime'
);

-- 方式3：使用 S3 兼容语法（GCS 支持 S3 API）
INSERT INTO gcs_import_examples.user_events
SELECT * FROM s3(
    'https://storage.googleapis.com/your-bucket-name/path/to/data/*.parquet',
    'YOUR_ACCESS_KEY',
    'YOUR_SECRET_KEY',
    'Parquet'
);

-- ========================================
-- 4. 性能优化导入方式
-- ========================================

-- 方式4：并行读取多个文件（推荐）
-- ClickHouse 会自动并行读取匹配的文件
INSERT INTO gcs_import_examples.user_events
SETTINGS 
    max_insert_threads = 16,                    -- 并行插入线程
    max_insert_block_size = 1048576,            -- 1M行块
    min_insert_block_size_rows = 1000000,       -- 最小批量
    input_format_parallel_parsing = 1,          -- 并行解析
    input_format_parquet_max_block_size = 1000000
SELECT * FROM gcs(
    'https://storage.googleapis.com/your-bucket-name/data/year=2024/month=03/*.parquet',
    'Parquet'
);

-- 方式5：按分区并行导入（最高性能）
-- 分别导入不同分区
INSERT INTO gcs_import_examples.user_events
SETTINGS max_insert_threads = 16
SELECT * FROM gcs(
    'https://storage.googleapis.com/your-bucket-name/data/year=2024/month=01/*.parquet',
    'Parquet'
);

INSERT INTO gcs_import_examples.user_events
SETTINGS max_insert_threads = 16
SELECT * FROM gcs(
    'https://storage.googleapis.com/your-bucket-name/data/year=2024/month=02/*.parquet',
    'Parquet'
);

-- ========================================
-- 5. 高级导入技巧
-- ========================================

-- 技巧1：使用 glob 模式批量导入
INSERT INTO gcs_import_examples.user_events
SELECT * FROM gcs(
    'https://storage.googleapis.com/your-bucket-name/data/**',  -- 递归匹配所有文件
    'Parquet'
);

-- 技巧2：过滤导入（只导入需要的列和行）
INSERT INTO gcs_import_examples.user_events
SELECT 
    event_id,
    event_type,
    event_time,
    user_id,
    session_id,
    -- 只导入需要的列
    page_url,
    campaign_source
FROM gcs(
    'https://storage.googleapis.com/your-bucket-name/data/*.parquet',
    'Parquet'
)
WHERE event_time >= '2024-01-01'  -- 过滤条件
  AND user_id != 0;

-- 技巧3：数据转换导入
INSERT INTO gcs_import_examples.user_events
SELECT 
    event_id,
    lower(event_type) as event_type,                    -- 转小写
    toDateTime(event_time) as event_time,               -- 类型转换
    user_id,
    md5(session_id) as session_id,                      -- 哈希处理
    -- 其他字段...
    now() as processing_time
FROM gcs(
    'https://storage.googleapis.com/your-bucket-name/data/*.parquet',
    'Parquet'
);

-- 技巧4：使用 URL 函数动态生成路径
INSERT INTO gcs_import_examples.user_events
SELECT * FROM gcs(
    concat(
        'https://storage.googleapis.com/your-bucket-name/data/',
        'year=', toString(toYear(now())),
        '/month=', toString(toMonth(now())),
        '/*.parquet'
    ),
    'Parquet'
);

-- ========================================
-- 6. 错误处理和重试
-- ========================================

-- 设置超时和重试参数
SET connect_timeout = 600;           -- 连接超时 10分钟
SET receive_timeout = 600;           -- 接收超时 10分钟
SET send_timeout = 600;              -- 发送超时 10分钟
SET max_retry_count = 3;             -- 最大重试次数

-- 使用 INSERT SELECT with SETTINGS
INSERT INTO gcs_import_examples.user_events
SETTINGS 
    max_insert_threads = 16,
    max_insert_block_size = 1048576,
    insert_quorum = 1,               -- 异步复制（提高速度）
    insert_quorum_timeout = 300000   -- 超时 5分钟
SELECT * FROM gcs(
    'https://storage.googleapis.com/your-bucket-name/data/*.parquet',
    'Parquet'
);

-- ========================================
-- 7. 检查导入进度和结果
-- ========================================

-- 检查表中的数据量
SELECT 
    count() as total_rows,
    min(event_time) as min_time,
    max(event_time) as max_time,
    uniqExact(user_id) as unique_users,
    formatReadableSize(sum(data_compressed_bytes)) as compressed_size,
    formatReadableSize(sum(data_uncompressed_bytes)) as uncompressed_size,
    sum(data_uncompressed_bytes) / sum(data_compressed_bytes) as compression_ratio
FROM system.parts
WHERE database = 'gcs_import_examples' 
  AND table = 'user_events'
  AND active = 1;

-- 检查分区信息
SELECT 
    partition,
    count() as parts,
    sum(rows) as rows,
    formatReadableSize(sum(data_compressed_bytes)) as size
FROM system.parts
WHERE database = 'gcs_import_examples' 
  AND table = 'user_events'
  AND active = 1
GROUP BY partition
ORDER BY partition;

-- 检查列统计信息
SELECT 
    name,
    type,
    sum(rows) as rows,
    formatReadableSize(sum(data_compressed_bytes)) as compressed_size,
    formatReadableSize(sum(column_data_compressed_bytes)) as column_compressed,
    formatReadableSize(sum(column_data_uncompressed_bytes)) as column_uncompressed,
    sum(column_data_uncompressed_bytes) / sum(column_data_compressed_bytes) as compression_ratio
FROM system.parts_columns
WHERE database = 'gcs_import_examples' 
  AND table = 'user_events'
  AND active = 1
GROUP BY name, type
ORDER BY sum(column_data_compressed_bytes) DESC;

-- ========================================
-- 8. 常见问题和解决方案
-- ========================================

-- 问题1：权限错误
-- 错误信息：Access Denied
-- 解决方案：检查 GCS 访问权限配置

-- 问题2：文件不存在
-- 错误信息：File not found
-- 解决方案：检查文件路径和 glob 模式
-- 测试文件是否可访问
SELECT count() FROM gcs(
    'https://storage.googleapis.com/your-bucket-name/test.parquet',
    'Parquet'
);

-- 问题3：schema 不匹配
-- 错误信息：Cannot parse input: expected ...
-- 解决方案：使用明确的 schema 定义
INSERT INTO gcs_import_examples.user_events
SELECT * FROM gcs(
    'https://storage.googleapis.com/your-bucket-name/data/*.parquet',
    'Parquet',
    'event_id String, event_type String, event_time DateTime'  -- 明确定义schema
)
SETTINGS input_format_skip_unknown_fields = 1;  -- 跳过未知字段

-- 问题4：内存不足
-- 错误信息：Memory limit exceeded
-- 解决方案：减小批量大小
SET max_memory_usage = 200000000000;  -- 200GB
SET max_insert_block_size = 524288;   -- 512K行块

-- 问题5：导入速度慢
-- 解决方案：检查瓶颈
SELECT 
    metric,
    value,
    description
FROM system.metrics
WHERE metric IN ('TotalThreads', 'TotalQueries', 'MemoryTracking');

-- ========================================
-- 9. 生产环境最佳实践
-- ========================================

-- 最佳实践1：使用存储策略（分层存储）
CREATE TABLE gcs_import_examples.user_events_with_policy (
    -- 字段定义同上...
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_time, user_id, event_id)
SETTINGS 
    index_granularity = 8192,
    storage_policy = 'tiered_storage';  -- 使用分层存储策略

-- 最佳实践2：创建临时表导入，验证后重命名
CREATE TABLE gcs_import_examples.user_events_temp AS gcs_import_examples.user_events;

-- 导入数据到临时表
INSERT INTO gcs_import_examples.user_events_temp
SETTINGS max_insert_threads = 16
SELECT * FROM gcs(
    'https://storage.googleapis.com/your-bucket-name/data/*.parquet',
    'Parquet'
);

-- 验证数据
SELECT count() FROM gcs_import_examples.user_events_temp;

-- 数据正确后，重命名表
RENAME TABLE gcs_import_examples.user_events TO gcs_import_examples.user_events_old;
RENAME TABLE gcs_import_examples.user_events_temp TO gcs_import_examples.user_events;

-- 最佳实践3：使用物化视图预处理数据
CREATE MATERIALIZED VIEW gcs_import_examples.user_events_mv
ENGINE = SummingMergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_time, event_type, user_id)
AS SELECT 
    event_time,
    event_type,
    user_id,
    count() as event_count,
    sum(time_on_page) as total_time
FROM gcs_import_examples.user_events
GROUP BY event_time, event_type, user_id;

-- 最佳实践4：使用 TTL 自动管理数据生命周期
ALTER TABLE gcs_import_examples.user_events 
MODIFY TTL event_time + INTERVAL 90 DAY TO DISK 'gcs';  -- 90天后移动到GCS

-- ========================================
-- 10. 清理示例
-- ========================================

-- 删除测试数据
DROP TABLE IF EXISTS gcs_import_examples.user_events;
DROP TABLE IF EXISTS gcs_import_examples.user_events_temp;
DROP DATABASE IF EXISTS gcs_import_examples;
