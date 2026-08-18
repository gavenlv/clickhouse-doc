-- ================================================================================
-- ClickHouse 查询性能分析示例
-- ================================================================================
-- 
-- 集群: treasurycluster (2 副本)
-- 预计学习时间: 15 分钟
-- 
-- 本文件涵盖:
--   1. EXPLAIN 计划 - 查询执行计划分析
--   2. EXPLAIN PIPELINE - 查询管道分析
--   3. EXPLAIN ESTIMATE - 预估资源使用
--   4. 查询日志 - system.query_log
--   5. 性能统计 - ProfileEvents
--   6. 慢查询分析 - 识别与优化
-- 
-- 查询分析工具:
-- 
--   ┌─────────────────────────────────────────────────────────────────────────┐
--   │                    ClickHouse 查询分析工具链                            │
--   └─────────────────────────────────────────────────────────────────────────┘
--   
--   ┌─────────────────────────────────────────────────────────────────────────┐
--   │                          分析层级                                       │
--   └─────────────────────────────────────────────────────────────────────────┘
--   
--   Level 1: EXPLAIN (执行前)
--   ┌──────────┐    ┌──────────┐    ┌──────────┐
--   │ PLAN     │    │ PIPELINE │    │ ESTIMATE │
--   │ 执行计划 │    │ 执行管道 │    │ 资源预估 │
--   └──────────┘    └──────────┘    └──────────┘
--   
--   Level 2: Query Log (执行后)
--   ┌──────────────────────────────────────────────────────────────────────┐
--   │ system.query_log                                                     │
--   │ - query_duration_ms: 执行时间                                        │
--   │ - read_rows/read_bytes: 读取数据量                                   │
--   │ - memory_usage: 内存使用                                             │
--   │ - ProfileEvents: 详细性能事件                                        │
--   └──────────────────────────────────────────────────────────────────────┘
--   
--   Level 3: System Tables (运行时)
--   ┌────────────────────┬────────────────────┐
--   │ system.processes   │ system.metrics     │
--   │ 当前运行的查询     │ 系统级指标         │
--   └────────────────────┴────────────────────┘
-- 
-- 查询性能指标:
-- 
--   ┌─────────────────────────────────────────────────────────────────────────┐
--   │                     关键性能指标解读                                    │
--   └─────────────────────────────────────────────────────────────────────────┘
--   
--   query_duration_ms    查询总耗时 (毫秒)
--   read_rows           读取的行数
--   read_bytes          读取的字节数
--   result_rows         返回的行数
--   result_bytes        返回的字节数
--   memory_usage        内存使用峰值
--   
--   性能比率:
--   filter_ratio = read_rows / result_rows   (过滤效率)
--   bytes_ratio = read_bytes / result_bytes  (数据压缩效果)
--   
--   ┌────────────────────────────────────────────────────────────────────────┐
--   │                         慢查询阈值建议                                 │
--   ├────────────────────────────────────────────────────────────────────────┤
--   │ 查询类型       │ 警告阈值    │ 严重阈值    │ 说明                     │
--   ├────────────────┼─────────────┼─────────────┼──────────────────────────┤
--   │ 简单查询       │ > 1秒       │ > 5秒       │ 单表查询/简单聚合        │
--   │ 复杂查询       │ > 10秒      │ > 60秒      │ 多表JOIN/大范围扫描      │
--   │ 内存使用       │ > 1GB       │ > 10GB      │ 单次查询内存峰值         │
--   │ 扫描数据量     │ > 1亿行     │ > 10亿行    │ 一次扫描的行数           │
--   └────────────────┴─────────────┴─────────────┴──────────────────────────┘
-- 
-- ================================================================================

EXPLAIN PLAN
SELECT 
    user_id,
    count() as event_count
FROM events
WHERE event_time >= now() - INTERVAL 7 DAY
GROUP BY user_id;

-- 查看查询管道
EXPLAIN PIPELINE
SELECT 
    user_id,
    count() as event_count
FROM events
WHERE event_time >= now() - INTERVAL 7 DAY
GROUP BY user_id;

-- 查看查询预估
EXPLAIN ESTIMATE
SELECT 
    user_id,
    count() as event_count
FROM events
WHERE event_time >= now() - INTERVAL 7 DAY
GROUP BY user_id;

-- ========================================
-- 1. EXPLAIN
-- ========================================

-- 查看查询日志
-- [需启用] 本集群 config 禁用了 query_log，以下 5 组 query_log 查询改为注释保留
-- （生产环境启用 query_log 后取消注释即可运行；本集群可用 system.processes 查看正在运行的查询）
-- SELECT 
--     query,
--     query_duration_ms,
--     read_rows,
--     read_bytes,
--     written_rows,
--     written_bytes,
--     memory_usage,
--     exception_text
-- FROM system.query_log
-- WHERE type = 'QueryFinish'
--   AND event_time >= now() - INTERVAL 1 HOUR
-- ORDER BY query_duration_ms DESC
-- LIMIT 20;

-- ========================================
-- 1. EXPLAIN
-- ========================================

-- 启用 Profiling（需在 users.xml 中预先定义 settings profile）
-- CLICKHOUSE_SETTINGS_PROFILE='profiling'

-- 查看性能统计（需启用 query_log）
-- SELECT 
--     ProfileEvents['NetworkReceiveBytes'] as bytes_received,
--     ProfileEvents['NetworkSendBytes'] as bytes_sent,
--     ProfileEvents['RealTimeMicroseconds'] as real_time_us,
--     ProfileEvents['CPUTimeMicroseconds'] as cpu_time_us,
--     ProfileEvents['MemoryTrackingPeak'] as peak_memory_bytes
-- FROM system.query_log
-- WHERE query_id = 'current_query_id';

-- ========================================
-- 1. EXPLAIN
-- ========================================

-- 计算性能比率（需启用 query_log）
-- SELECT 
--     query,
--     read_rows,
--     result_rows,
--     read_rows / result_rows as filter_ratio,
--     read_bytes,
--     result_bytes,
--     read_bytes / result_bytes as bytes_filter_ratio,
--     query_duration_ms,
--     memory_usage
-- FROM system.query_log
-- WHERE type = 'QueryFinish'
--   AND event_time >= now() - INTERVAL 24 HOUR
-- ORDER BY query_duration_ms DESC
-- LIMIT 20;

-- ========================================
-- 1. EXPLAIN
-- ========================================

-- 查看慢查询（需启用 query_log）
-- SELECT 
--     query,
--     query_duration_ms,
--     read_rows,
--     read_bytes,
--     result_rows,
--     memory_usage,
--     formatReadableSize(read_bytes) as read_size,
--     formatReadableSize(memory_usage) as memory_size
-- FROM system.query_log
-- WHERE type = 'QueryFinish'
--   AND query_duration_ms > 1000  -- 超过 1 秒
--   AND event_time >= now() - INTERVAL 24 HOUR
-- ORDER BY query_duration_ms DESC
-- LIMIT 20;

-- ========================================
-- 1. EXPLAIN
-- ========================================

-- 分析慢查询的特征（需启用 query_log）
-- SELECT 
--     substring(query, 1, 100) as query_sample,
--     count() as slow_query_count,
--     avg(query_duration_ms) as avg_duration,
--     max(query_duration_ms) as max_duration,
--     avg(read_rows) as avg_rows_read,
--     avg(memory_usage) as avg_memory
-- FROM system.query_log
-- WHERE type = 'QueryFinish'
--   AND query_duration_ms > 1000
--   AND event_time >= now() - INTERVAL 24 HOUR
-- GROUP BY query_sample
-- ORDER BY avg_duration DESC
-- LIMIT 10;

-- ========================================
-- 1. EXPLAIN
-- ========================================

-- 优化前
SELECT * FROM events
WHERE event_time >= now() - INTERVAL 30 DAY;

-- 优化后（使用 PREWHERE）
SELECT 
    event_id,
    user_id,
    event_type
FROM events
PREWHERE event_time >= now() - INTERVAL 30 DAY
WHERE user_id = 123;

-- ========================================
-- 1. EXPLAIN
-- ========================================

-- 优化前
SELECT * FROM events
WHERE toDate(event_time) >= '2024-01-01';

-- 优化后
SELECT * FROM events
WHERE event_time >= '2024-01-01'
  AND event_time < '2024-02-01';

-- ========================================
-- 1. EXPLAIN
-- ========================================

-- 优化前
SELECT * FROM events
WHERE event_type = 'click';

-- 优化后（使用跳数索引）
-- 首先创建索引
ALTER TABLE events
ADD INDEX idx_event_type event_type
TYPE set(2)
GRANULARITY 4;

-- 查询
SELECT * FROM events
WHERE event_type = 'click';
