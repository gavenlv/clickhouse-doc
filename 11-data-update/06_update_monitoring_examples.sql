-- ================================================================================
-- ClickHouse 更新操作监控详解
-- ================================================================================
-- 
-- 集群: treasurycluster (2 副本)
-- 预计学习时间: 25 分钟
-- 
-- 本文件涵盖:
--   1. Mutation 状态监控 - system.mutations
--   2. 执行过程监控 - system.processes
--   3. 系统资源监控 - CPU、内存、磁盘
--   4. 后台任务监控 - system.replication_queue
--   5. 分区操作监控 - system.part_log
--   6. 健康检查 - 综合监控视图
-- 
-- ================================================================================
-- 更新监控体系
-- ================================================================================
-- 
--   ┌─────────────────────────────────────────────────────────────────────────┐
--   │                      ClickHouse 更新监控体系                            │
--   └─────────────────────────────────────────────────────────────────────────┘
--   
--   ┌─────────────────────────────────────────────────────────────────────────┐
--   │                          监控层级                                       │
--   └─────────────────────────────────────────────────────────────────────────┘
--   
--   Level 1: 操作状态
--   ┌────────────────────────────────────────────────────────────────────────┐
--   │  system.mutations          → Mutation 进度和状态                       │
--   │  system.processes          → 正在执行的更新操作                        │
--   └────────────────────────────────────────────────────────────────────────┘
--                          │
--                          ▼
--   Level 2: 资源消耗
--   ┌────────────────────────────────────────────────────────────────────────┐
--   │  system.metrics            → CPU、内存使用率                           │
--   │  system.asynchronous_metrics → 磁盘 I/O 统计                           │
--   │  system.processes          → 查询级资源消耗                            │
--   └────────────────────────────────────────────────────────────────────────┘
--                          │
--                          ▼
--   Level 3: 后台任务
--   ┌────────────────────────────────────────────────────────────────────────┐
--   │  system.replication_queue  → 复制队列状态                              │
--   │  system.part_log           → 分区操作日志                              │
--   │  system.background_tasks   → 后台任务队列                              │
--   └────────────────────────────────────────────────────────────────────────┘
-- 
-- ================================================================================
-- Mutation 状态监控
-- ================================================================================
-- 
--   ┌─────────────────────────────────────────────────────────────────────────┐
--   │                    system.mutations 关键字段                            │
--   └─────────────────────────────────────────────────────────────────────────┘
--   
--   字段                说明                    示例值
--   ───────────────────────────────────────────────────────────────
--   database           数据库名                'default'
--   table              表名                    'users'
--   mutation_id        Mutation ID             'mutation_123.txt'
--   command            更新命令                'UPDATE status = ...'
--   is_done            是否完成                0=进行中, 1=已完成
--   parts_to_do        待处理 Part 数量        5
--   parts_to_do_names  待处理 Part 名称        ['part_1', 'part_2']
--   progress           进度                    0.75
--   created_at         创建时间                '2024-01-20 10:00:00'
--   done_at            完成时间                '2024-01-20 10:05:00'
--   exception_text     异常信息                '' 或错误信息
--   
--   状态判断:
--   ┌────────────────────────────────────────────────────────────────────────┐
--   │  is_done = 0, parts_to_do > 0  → 进行中                                │
--   │  is_done = 0, parts_to_do = 0  → 等待资源                              │
--   │  is_done = 1, exception = ''   → 成功完成                              │
--   │  is_done = 1, exception != ''  → 失败                                  │
--   └────────────────────────────────────────────────────────────────────────┘
-- 
-- ================================================================================
-- 性能诊断指标
-- ================================================================================
-- 
--   ┌─────────────────────────────────────────────────────────────────────────┐
--   │                      更新性能诊断指标                                   │
--   └─────────────────────────────────────────────────────────────────────────┘
--   
--   指标                健康值            警告值            危险值
--   ───────────────────────────────────────────────────────────────
--   进行中 Mutation     < 5              5-10             > 10
--   平均完成时间        < 60秒           60-300秒         > 300秒
--   CPU 使用率          < 60%            60-80%           > 80%
--   内存使用率          < 70%            70-85%           > 85%
--   磁盘队列深度        < 10             10-50            > 50
--   失败 Mutation 数    0                1-5              > 5
--   
--   告警规则:
--   ┌────────────────────────────────────────────────────────────────────────┐
--   │  1. 进行中 Mutation > 10 → 可能阻塞后续更新                            │
--   │  2. Mutation 执行 > 5分钟 → 检查数据量或条件                           │
--   │  3. 失败 Mutation > 0 → 检查错误日志并重试                             │
--   │  4. CPU/内存 > 80% → 减少并发更新                                      │
--   └────────────────────────────────────────────────────────────────────────┘
-- 
-- ================================================================================
-- 监控视图设计
-- ================================================================================
-- 
--   ┌─────────────────────────────────────────────────────────────────────────┐
--   │                      综合监控视图结构                                   │
--   └─────────────────────────────────────────────────────────────────────────┘
--   
--   视图名称                    用途
--   ───────────────────────────────────────────────────────────────
--   update_overview            更新操作概览
--   partition_operations       分区操作统计
--   mutation_progress          Mutation 进度跟踪
--   system_health              系统健康状态
--   
--   查询频率建议:
--   - 实时监控: 每 10 秒
--   - 日常监控: 每 1 分钟
--   - 报表统计: 每 1 小时
-- 
-- ================================================================================

SELECT 
    database,
    table,
    mutation_id,
    command,
    is_done,
    parts_to_do,
    parts_to_do_names,
    progress,
    exception_text,
    created_at,
    done_at
FROM system.mutations
WHERE database IN ('test_info_schema', 'test_data_deletion', 'test_date_time')
ORDER BY created DESC;

-- ========================================
-- 1. 更新操作监控
-- ========================================

-- 查看 CPU 和内存使用
SELECT 
    query_id,
    user,
    query,
    thread_id,
    cpu_time_nanoseconds,
    memory_usage,
    peak_memory_usage,
    read_rows,
    read_bytes,
    written_rows,
    written_bytes,
    elapsed
FROM system.processes
WHERE query LIKE '%UPDATE%'
  OR query LIKE '%ALTER TABLE%'
ORDER BY cpu_time_nanoseconds DESC
LIMIT 10;

-- ========================================
-- 1. 更新操作监控
-- ========================================

-- 查看磁盘 IO 统计
SELECT 
    event_time,
    metric,
    value
FROM system.asynchronous_metrics
WHERE metric LIKE '%Disk%'
   OR metric LIKE '%IO%'
ORDER BY event_time DESC
LIMIT 20;

-- ========================================
-- 1. 更新操作监控
-- ========================================

-- 查看后台任务队列
SELECT 
    type,
    database,
    table,
    elapsed,
    progress,
    num_parts,
    bytes_read_uncompressed,
    rows_read,
    bytes_written_uncompressed,
    rows_written,
    result_part_names
FROM system.replication_queue
ORDER BY event_time DESC
LIMIT 20;

-- ========================================
-- 1. 更新操作监控
-- ========================================

-- 查看性能指标
SELECT 
    event_time,
    metric,
    value,
    description
FROM system.metrics
WHERE metric LIKE '%Mutation%'
   OR metric LIKE '%Background%'
ORDER BY metric;

-- ========================================
-- 1. 更新操作监控
-- ========================================

-- 统计更新操作
SELECT 
    database,
    table,
    count() as mutation_count,
    sum(if(is_done = 1, 1, 0)) as completed_count,
    sum(if(is_done = 0, 1, 0)) as in_progress_count,
    avg(progress) as avg_progress,
    max(progress) as max_progress
FROM system.mutations
WHERE database LIKE 'test_%'
GROUP BY database, table
ORDER BY mutation_count DESC;

-- ========================================
-- 1. 更新操作监控
-- ========================================

-- 分析更新操作的影响
SELECT 
    database,
    table,
    mutation_id,
    command,
    parts_to_do,
    sum(rows) as total_rows,
    formatReadableSize(sum(bytes_on_disk)) as total_size,
    progress,
    elapsed
FROM system.mutations
LEFT JOIN system.parts
USING (database, table)
WHERE database LIKE 'test_%'
  AND active = 1
GROUP BY database, table, mutation_id, command, parts_to_do, progress, elapsed
ORDER BY elapsed DESC;

-- ========================================
-- 1. 更新操作监控
-- ========================================

-- 监控更新操作错误
SELECT 
    database,
    table,
    mutation_id,
    command,
    is_done,
    latest_failed_part,
    latest_fail_reason,
    latest_fail_time,
    exception_text
FROM system.mutations
WHERE database LIKE 'test_%'
  AND (exception_text != '' OR is_done = 0)
ORDER BY latest_fail_time DESC;

-- ========================================
-- 1. 更新操作监控
-- ========================================

-- 监控 TTL 删除/更新操作
-- 注意：system.ttl_tables 在某些配置中可能不可用
-- 替代方案：使用 SHOW CREATE TABLE IF NOT EXISTS 或查询 system.parts 查看分区变化
SELECT
    database,
    table,
    '',
    sum(rows) AS total_rows,
    formatReadableSize(sum(bytes_on_disk)) AS total_size,
    min(modification_time) AS oldest_part_time,
    max(modification_time) AS newest_part_time
FROM system.parts
WHERE database LIKE 'test_%'
  AND active = 1
GROUP BY database, table, partition
ORDER BY database, table, partition;

-- ========================================
-- 1. 更新操作监控
-- ========================================

-- 监控分区操作
SELECT 
    type,
    partition_id,
    '',
    part_name,
    rows,
    bytes_on_disk,
    event_time,
    exception_text
FROM system.part_log
WHERE database LIKE 'test_%'
  AND type IN ('DROP_PART', 'REPLACE_PART', 'EXCHANGE_PART')
ORDER BY event_time DESC
LIMIT 20;

-- ========================================
-- 1. 更新操作监控
-- ========================================

-- 检查所有 Mutation 的状态
SELECT 
    database,
    table,
    mutation_id,
    command,
    is_done,
    parts_to_do,
    parts_to_do_names,
    progress,
    created_at,
    done_at,
    exception_text
FROM system.mutations
WHERE database LIKE 'test_%'
ORDER BY created DESC;

-- ========================================
-- 1. 更新操作监控
-- ========================================

-- 检查系统整体负载
SELECT 
    'CPU Usage' as metric,
    formatReadableSize(value) as value
FROM system.metrics
WHERE metric = 'CPU'

UNION ALL

SELECT 
    'Memory Usage' as metric,
    formatReadableSize(value) as value
FROM system.metrics
WHERE metric = 'Memory'

UNION ALL

SELECT 
    'Disk Read' as metric,
    formatReadableSize(value) as value
FROM system.asynchronous_metrics
WHERE metric = 'DiskReadBytes'

UNION ALL

SELECT 
    'Disk Write' as metric,
    formatReadableSize(value) as value
FROM system.asynchronous_metrics
WHERE metric = 'DiskWriteBytes';

-- ========================================
-- 1. 更新操作监控
-- ========================================

-- 检查后台任务队列
SELECT 
    type,
    database,
    table,
    elapsed,
    progress,
    num_parts,
    bytes_read_uncompressed,
    rows_read,
    bytes_written_uncompressed,
    rows_written,
    exception_text
FROM system.replication_queue
ORDER BY elapsed DESC
LIMIT 10;

-- ========================================
-- 1. 更新操作监控
-- ========================================

-- 检查分区状态
SELECT 
    database,
    table,
    '',
    sum(rows) as total_rows,
    sum(bytes_on_disk) as total_bytes,
    formatReadableSize(sum(bytes_on_disk)) as readable_size,
    count() as part_count
FROM system.parts
WHERE database LIKE 'test_%'
  AND active = 1
GROUP BY database, table, partition
ORDER BY database, table, partition;

-- ========================================
-- 1. 更新操作监控
-- ========================================

-- 查看更新历史
SELECT 
    mutation_id,
    database,
    table,
    command,
    is_done,
    parts_to_do,
    created_at,
    done_at,
    if(done_at > created_at, 
        dateDiff('second', created_at, done_at), 
        NULL) as duration_seconds
FROM system.mutations
WHERE database LIKE 'test_%'
  AND is_done = 1
ORDER BY done_at DESC
LIMIT 20;

-- ========================================
-- 1. 更新操作监控
-- ========================================

-- 监控批量更新进度
SELECT 
    database,
    table,
    mutation_id,
    command,
    is_done,
    parts_to_do,
    parts_to_do_names,
    progress,
    sum(rows) as total_rows,
    formatReadableSize(sum(bytes_on_disk)) as total_size
FROM system.mutations
LEFT JOIN system.parts
USING (database, table)
WHERE database = 'test_data_deletion'
  AND active = 1
  AND is_done = 0
GROUP BY database, table, mutation_id, command, is_done, parts_to_do, parts_to_do_names, progress
ORDER BY created DESC;

-- ========================================
-- 1. 更新操作监控
-- ========================================

-- 监控 TTL 执行情况
-- 注意：system.ttl_tables 在某些配置中可能不可用
-- 替代方案：使用 SHOW CREATE TABLE IF NOT EXISTS 查看配置，使用 system.parts 查看分区
SHOW DROP TABLE IF EXISTS test_data_deletion.test_events_ttl;
CREATE TABLE IF NOT EXISTS test_data_deletion.test_events_ttl;

-- 查看分区变化来推断 TTL 执行情况
SELECT
    table,
    '',
    sum(rows) AS total_rows,
    formatReadableSize(sum(bytes_on_disk)) AS total_size,
    min(modification_time) AS oldest_part,
    max(modification_time) AS newest_part,
    dateDiff('day', max(modification_time), now()) AS days_since_last_modified
FROM system.parts
WHERE database = 'test_data_deletion'
  AND active = 1
  AND table = 'test_events_ttl'
GROUP BY table, partition
ORDER BY partition;

-- ========================================
-- 1. 更新操作监控
-- ========================================

-- 综合系统健康检查
SELECT 
    'Mutation Queue' as metric,
    count() as value,
    if(count() < 10, 'OK', 'WARNING') as status
FROM system.mutations
WHERE is_done = 0

UNION ALL

SELECT 
    'Failed Mutations' as metric,
    count() as value,
    if(count() = 0, 'OK', 'CRITICAL') as status
FROM system.mutations
WHERE is_done = 1 AND exception_text != ''

UNION ALL

SELECT 
    'CPU Usage %' as metric,
    value as value,
    if(value < 80, 'OK', 'WARNING') as status
FROM system.metrics
WHERE metric = 'CPU'

UNION ALL

SELECT 
    'Memory Usage %' as metric,
    value as value,
    if(value < 80, 'OK', 'WARNING') as status
FROM system.metrics
WHERE metric = 'Memory'

UNION ALL

SELECT 
    'Disk Usage %' as metric,
    value as value,
    if(value < 80, 'OK', 'WARNING') as status
FROM system.metrics
WHERE metric = 'Disk';

-- ========================================
-- 1. 更新操作监控
-- ========================================

-- 创建综合监控视图
CREATE VIEW test_monitoring.update_overview AS
SELECT 
    'Active Mutations' as metric,
    count() as value
FROM system.mutations
WHERE is_done = 0

UNION ALL

SELECT 
    'Completed Mutations (Last 24h)' as metric,
    count() as value
FROM system.mutations
WHERE is_done = 1 
  AND done_at >= now() - INTERVAL 24 HOUR

UNION ALL

SELECT 
    'Failed Mutations (Last 24h)' as metric,
    count() as value
FROM system.mutations
WHERE is_done = 1 
  AND done_at >= now() - INTERVAL 24 HOUR
  AND exception_text != ''

UNION ALL

SELECT 
    'Average Mutation Duration (Last 24h)' as metric,
    avg(dateDiff('second', created_at, done_at)) as value
FROM system.mutations
WHERE is_done = 1 
  AND done_at >= now() - INTERVAL 24 HOUR;

-- ========================================
-- 1. 更新操作监控
-- ========================================

-- 创建分区操作监控视图
CREATE VIEW test_monitoring.partition_operations AS
SELECT 
    type,
    count() as operation_count,
    sum(rows) as total_rows,
    formatReadableSize(sum(bytes_on_disk)) as total_size,
    min(event_time) as first_operation,
    max(event_time) as last_operation
FROM system.part_log
WHERE database LIKE 'test_%'
  AND event_time >= now() - INTERVAL 24 HOUR
GROUP BY type
ORDER BY operation_count DESC;
