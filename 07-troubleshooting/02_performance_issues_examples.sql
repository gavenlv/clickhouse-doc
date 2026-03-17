-- =====================================================
-- 02 - 性能问题排查示例
-- =====================================================
-- 集群: treasurycluster (2副本)
-- 时间: 10-15分钟
-- =====================================================

-- -----------------------------------------------------
-- 1. 性能问题概述
-- -----------------------------------------------------

-- 
-- ┌─────────────────────────────────────────────────────────────┐
-- │              ClickHouse 性能问题排查                         │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                              │
-- │  性能问题分类:                                              │
-- │                                                              │
-- │  1. 查询慢                                                  │
-- │     - 缺少索引/PARTITION BY不当                             │
-- │     - 大表扫描 (无WHERE条件)                                │
-- │     - JOIN优化不足                                          │
-- │     - 内存不足导致磁盘溢出                                  │
-- │                                                              │
-- │  2. 写入慢                                                  │
-- │     - Part数量过多                                          │
-- │     - 合并跟不上写入                                        │
-- │     - 磁盘I/O瓶颈                                           │
-- │                                                              │
-- │  3. 资源问题                                                │
-- │     - CPU使用率高                                           │
-- │     - 内存不足 (OOM)                                        │
-- │     - 磁盘空间不足                                          │
-- │                                                              │
-- │  性能优化方法:                                              │
-- │                                                              │
-- │  ┌─────────────────────────────────────────────────────────┐│
-- │  │              查询优化策略                                ││
-- │  │                                                          ││
-- │  │  1. 使用分区裁剪                                         ││
-- │  │     WHERE event_date = '2024-01-15'                     ││
-- │  │                                                          ││
-- │  │  2. 使用主键过滤                                         ││
-- │  │     ORDER BY (user_id, event_time)                      ││
-- │  │     WHERE user_id = 123                                  ││
-- │  │                                                          ││
-- │  │  3. 使用跳数索引                                         ││
-- │  │     ADD INDEX idx_status (status) TYPE set(0)           ││
-- │  │                                                          ││
-- │  │  4. 使用Projection预聚合                                  ││
-- │  │     ADD PROJECTION agg_by_user                          ││
-- │  │     (SELECT user_id, sum(amount) GROUP BY user_id)      ││
-- │  │                                                          ││
-- │  │  5. 避免大JOIN                                           ││
-- │  │     - 使用IN代替JOIN (小表)                              ││
-- │  │     - 使用字典代替JOIN                                   ││
-- │  └─────────────────────────────────────────────────────────┘│
-- │                                                              │
-- │  关键监控指标:                                              │
-- │  - query_duration_ms: 查询耗时                              │
-- │  - read_rows: 读取行数                                      │
-- │  - memory_usage: 内存使用                                   │
-- │  - ProfileEvents: 详细性能事件                              │
-- │                                                              │
-- └─────────────────────────────────────────────────────────────┘

SELECT
    query_id,
    user,
    query,
    elapsed,
    read_rows,
    formatReadableSize(read_bytes) as bytes_read,
    formatReadableSize(memory_usage) as memory
FROM system.processes
ORDER BY elapsed DESC;

-- 查看慢查询历史
SELECT
    query_duration_ms / 1000 as duration_seconds,
    query,
    read_rows,
    formatReadableSize(read_bytes) as bytes_read
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query_duration_ms > 1000
  AND event_time > now() - INTERVAL 1 DAY
ORDER BY query_duration_ms DESC
LIMIT 20;

-- ========================================
-- 诊断
-- ========================================

-- 查看内存使用
SELECT formatReadableSize(0) as total, formatReadableSize(0) as free, formatReadableSize(0) as used
FROM system.asynchronous_metrics;

-- 查看查询内存使用
SELECT
    query_id,
    query,
    formatReadableSize(memory_usage) as memory
FROM system.processes
ORDER BY memory_usage DESC;
