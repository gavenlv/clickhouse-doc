-- ================================================
-- 03_log_engines.sql
-- ClickHouse Log 系列简单引擎示例
-- ================================================

-- ========================================
-- 0. 创建测试数据库
-- ========================================
CREATE DATABASE IF NOT EXISTS engine_test ON CLUSTER 'treasurycluster';

-- ========================================
-- 1. TinyLog（最简单的日志引擎）
-- ========================================

-- 创建 TinyLog 表
CREATE TABLE IF NOT EXISTS engine_test.tinylog_events (
    event_id UInt64,
    user_id UInt64,
    event_type String,
    event_data String,
    timestamp DateTime
) ENGINE = TinyLog();

-- 插入测试数据
INSERT INTO engine_test.tinylog_events (event_id, user_id, event_type, event_data, timestamp) VALUES
(1, 1, 'click', '{"page":"home"}', '2024-01-01 10:00:00'),
(2, 1, 'view', '{"page":"products"}', '2024-01-01 10:05:00'),
(3, 2, 'click', '{"page":"products"}', '2024-01-01 11:00:00'),
(4, 3, 'purchase', '{"product_id":101,"amount":99.99}', '2024-01-01 12:00:00'),
(5, 1, 'logout', '{"duration":3600}', '2024-01-02 09:00:00');

-- 查询数据
SELECT * FROM engine_test.tinylog_events ORDER BY event_id;

-- ========================================
-- 2. StripeLog（条带日志引擎）
-- ========================================

-- 创建 StripeLog 表
CREATE TABLE IF NOT EXISTS engine_test.stripelog_logs (
    log_id UInt64,
    level String,
    message String,
    timestamp DateTime
) ENGINE = StripeLog();

-- 插入测试数据
INSERT INTO engine_test.stripelog_logs (log_id, level, message, timestamp) VALUES
(1, 'INFO', 'Application started', '2024-01-01 10:00:00'),
(2, 'DEBUG', 'Processing request', '2024-01-01 10:01:00'),
(3, 'INFO', 'User logged in', '2024-01-01 10:05:00'),
(4, 'WARNING', 'High memory usage', '2024-01-01 10:10:00'),
(5, 'ERROR', 'Connection failed', '2024-01-01 10:15:00');

-- 按级别统计
SELECT level, count() as log_count FROM engine_test.stripelog_logs GROUP BY level;

-- ========================================
-- 3. Log（普通日志引擎）
-- ========================================

-- 创建 Log 表
CREATE TABLE IF NOT EXISTS engine_test.log_metrics (
    metric_id UInt64,
    metric_name String,
    metric_value Float64,
    tags String,
    timestamp DateTime
) ENGINE = Log();

-- 插入测试数据
INSERT INTO engine_test.log_metrics (metric_id, metric_name, metric_value, tags, timestamp) VALUES
(1, 'cpu_usage', 45.5, '{"server":"web1"}', '2024-01-01 10:00:00'),
(2, 'memory_usage', 68.2, '{"server":"web1"}', '2024-01-01 10:01:00'),
(3, 'disk_usage', 78.9, '{"server":"web1"}', '2024-01-01 10:02:00'),
(4, 'cpu_usage', 52.3, '{"server":"web2"}', '2024-01-01 10:00:00'),
(5, 'memory_usage', 71.1, '{"server":"web2"}', '2024-01-01 10:01:00');

-- 按服务器统计
SELECT
    JSONExtractString(tags, 'server') as server,
    avg(metric_value) as avg_value,
    count() as metric_count
FROM engine_test.log_metrics
GROUP BY server
ORDER BY server;

-- ========================================
-- 4. Log 引擎对比
-- ========================================

-- 创建对比表
CREATE TABLE IF NOT EXISTS engine_test.tinylog_test (id UInt64, data String, value Float64) ENGINE = TinyLog();
CREATE TABLE IF NOT EXISTS engine_test.stripelog_test (id UInt64, data String, value Float64) ENGINE = StripeLog();
CREATE TABLE IF NOT EXISTS engine_test.log_test (id UInt64, data String, value Float64) ENGINE = Log();

-- 插入相同的数据
INSERT INTO engine_test.tinylog_test SELECT number, repeat('test data ', 5), rand() * 1000 FROM numbers(1000);
INSERT INTO engine_test.stripelog_test SELECT * FROM engine_test.tinylog_test;
INSERT INTO engine_test.log_test SELECT * FROM engine_test.tinylog_test;

-- 对比查询
SELECT 'TinyLog' as engine, count() as row_count FROM engine_test.tinylog_test
UNION ALL
SELECT 'StripeLog', count() FROM engine_test.stripelog_test
UNION ALL
SELECT 'Log', count() FROM engine_test.log_test;

-- 查看表大小
SELECT
    name,
    engine,
    total_rows,
    formatReadableSize(total_bytes) as readable_size
FROM system.tables
WHERE database = 'engine_test' AND table LIKE '%_test'
ORDER BY name;

-- ========================================
-- 5. 清理测试表
-- ========================================
DROP TABLE IF EXISTS engine_test.tinylog_events;
DROP TABLE IF EXISTS engine_test.stripelog_logs;
DROP TABLE IF EXISTS engine_test.log_metrics;
DROP TABLE IF EXISTS engine_test.tinylog_test;
DROP TABLE IF EXISTS engine_test.stripelog_test;
DROP TABLE IF EXISTS engine_test.log_test;

-- ========================================
-- 6. Log 引擎最佳实践
-- ========================================
/*
Log 系列引擎最佳实践：

1. TinyLog
   - 适用于临时数据、小数据量（< 10GB）
   - 优点：简单快速、低开销
   - 缺点：无索引、无分区、查询性能差

2. StripeLog
   - 适用于中小数据量、需要压缩
   - 优点：支持压缩、查询优于 TinyLog
   - 缺点：无索引、无分区

3. Log
   - 适用于中等规模日志、配置数据
   - 优点：每列独立文件、性能较好
   - 缺点：无索引、无分区

选择建议：
- 临时测试：TinyLog
- 小日志：StripeLog
- 中等规模：Log
- 生产环境：始终使用 MergeTree 系列
*/
