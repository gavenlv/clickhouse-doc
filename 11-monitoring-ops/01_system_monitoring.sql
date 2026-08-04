-- ============================================================================
-- 01 - 系统监控核心
-- ============================================================================
-- 场景: 集群健康检查、Part 级别监控、副本监控、慢查询、Mutation 进度
-- 集群: treasurycluster (2副本)
-- 耗时: 10-20秒
-- 注意: system.query_log 在本集群已禁用，统一用 system.query_thread_log
--       + SET log_query_threads = 1
-- ============================================================================

DROP DATABASE IF EXISTS ops_test;
CREATE DATABASE ops_test;
USE ops_test;

-- ============================================================================
-- 【原理】系统监控体系
--
-- ClickHouse 的监控数据源分为三个层次：
--   1. 实时指标层 (system.metrics / system.events / system.asynchronous_metrics)
--      - 当前的查询数、连接数、合并任务数等
--      - 累计事件计数（从启动开始）
--      - CPU、内存、网络等异步采集指标
--   2. 数据持久化层 (system.parts / system.replicas / system.merges / system.mutations)
--      - 所有表的所有 Part 元数据
--      - 副本状态、合并进度、Mutation 进度
--   3. 历史日志层 (system.query_thread_log / system.text_log / system.metric_log)
--      - 查询线程级日志（需要 SET log_query_threads=1）
--      - 错误/警告日志
--      - 历史指标数据
-- ============================================================================

-- ============================================================================
-- 【坑】重要注意事项
--   1. system.query_log 在本集群已禁用，使用 system.query_thread_log 替代
--      使用前必须执行: SET log_query_threads = 1
--   2. system.asynchronous_metrics_log 可能未开启，需在 config.xml 中配置
--   3. system.text_log 表可能很大，查询时务必限制时间和级别
--   4. system.replicas 中的 absolute_delay 在刚启动时可能短暂偏高
--   5. system.zookeeper 表可能因权限不可用，建议用 system.replicas 替代
-- ============================================================================

-- ==========================================
-- 1. 集群拓扑监控 (system.clusters)
-- ==========================================

-- 1.1 查看集群节点配置
-- 【场景】快速了解集群的节点拓扑、分片和副本分布
-- 【原理】system.clusters 存储了服务器配置中的所有集群信息
SELECT
    cluster,
    shard_num,
    replica_num,
    host_name,
    port,
    user,
    connections,
    errors_count,
    estimated_recovery_time
FROM system.clusters
WHERE cluster = 'treasurycluster'
ORDER BY shard_num, replica_num;

-- 1.2 查看当前节点信息
-- 【场景】确认当前节点身份、版本和运行时长
SELECT
    host_name() AS current_host,
    version() AS version,
    uptime() AS uptime_seconds,
    now() AS current_time;

-- 1.3 集群节点健康检查
-- 【场景】检查各节点的连接错误数，发现不稳定的节点
SELECT
    cluster,
    shard_num,
    host_name,
    errors_count,
    estimated_recovery_time,
    CASE
        WHEN errors_count > 10 THEN 'CRITICAL'
        WHEN errors_count > 0 THEN 'WARNING'
        ELSE 'OK'
    END AS status
FROM system.clusters
WHERE cluster = 'treasurycluster'
ORDER BY errors_count DESC;

-- ==========================================
-- 2. Part 级别监控 (system.parts)
-- ==========================================

-- 2.1 活跃 Part 分布
-- 【场景】查看各表的活跃 Part 数量，识别碎片化严重的表
-- 【原理】Part 数量过多（> 500）说明合并压力大，需要调整合并参数
-- 【坑】Part 数量还包括副本的信息，单副本的 Part 会重复计数
SELECT
    database,
    table,
    count(*) AS part_count,
    countIf(level = 0) AS level0_parts,
    countIf(level > 1) AS high_level_parts,
    sum(rows) AS total_rows,
    formatReadableSize(sum(bytes_on_disk)) AS total_size
FROM system.parts
WHERE active = 1
  AND database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
GROUP BY database, table
HAVING part_count > 100
ORDER BY part_count DESC;

-- 2.2 非活跃 Part 检查
-- 【场景】非活跃 Part 是合并后等待清理的旧数据，长期积压说明磁盘空间不足
-- 【原理】合并完成后，旧 Part 标记为非活跃，等待后台清理线程删除
SELECT
    database,
    table,
    partition,
    name,
    level,
    rows,
    bytes_on_disk,
    modification_time,
    formatReadableTimeDelta(now() - modification_time) AS age
FROM system.parts
WHERE active = 0
  AND database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
ORDER BY modification_time DESC
LIMIT 20;

-- 2.3 大表 Part 概况
-- 【场景】了解大表的 Part 组成，评估合并效率
SELECT
    database,
    table,
    count(*) AS total_parts,
    min(rows) AS min_rows_per_part,
    max(rows) AS max_rows_per_part,
    avg(rows) AS avg_rows_per_part,
    formatReadableSize(min(bytes_on_disk)) AS min_part_size,
    formatReadableSize(max(bytes_on_disk)) AS max_part_size,
    formatReadableSize(avg(bytes_on_disk)) AS avg_part_size
FROM system.parts
WHERE active = 1
  AND database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
GROUP BY database, table
ORDER BY sum(bytes_on_disk) DESC
LIMIT 20;

-- 2.4 按分区统计数据分布
-- 【场景】了解各分区的数据量，识别数据倾斜
-- 【原理】分区间的数据量差异过大说明分区键设计不合理
SELECT
    database,
    table,
    partition,
    count(*) AS part_count,
    sum(rows) AS total_rows,
    formatReadableSize(sum(bytes_on_disk)) AS total_size,
    min(min_time) AS data_start,
    max(max_time) AS data_end
FROM system.parts
WHERE active = 1
  AND database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
GROUP BY database, table, partition
ORDER BY database, table, partition;

-- ==========================================
-- 3. 合并队列监控 (system.merges)
-- ==========================================

-- 3.1 正在进行的合并任务
-- 【场景】查看当前合并进度，识别卡住的合并任务
-- 【原理】合并是 ClickHouse 的后台操作，progress 表示完成百分比
-- 【坑】合并长时间卡在 99% 可能是内存不足或数据损坏
SELECT
    database,
    table,
    partition_id,
    result_part_name,
    round(progress * 100, 2) AS progress_percent,
    num_parts,
    formatReadableSize(total_size_bytes_compressed) AS size,
    elapsed,
    formatReadableTimeDelta(elapsed) AS elapsed_readable,
    is_mutation
FROM system.merges
ORDER BY total_size_bytes_compressed DESC
LIMIT 20;

-- 3.2 合并队列积压统计
-- 【场景】统计各表的待合并任务数，识别积压严重表
SELECT
    database,
    table,
    count(*) AS pending_merges,
    sum(progress) AS total_progress,
    formatReadableTimeDelta(max(elapsed)) AS longest_running
FROM system.merges
GROUP BY database, table
ORDER BY pending_merges DESC;

-- 3.3 合并卡住检测
-- 【场景】检测长时间未完成的合并任务
-- 【对比】正常合并通常在几分钟内完成，超过 1 小时需要关注
SELECT
    database,
    table,
    result_part_name,
    round(progress * 100, 2) AS progress_percent,
    elapsed,
    num_parts,
    formatReadableSize(total_size_bytes_compressed) AS size,
    CASE
        WHEN elapsed > 3600 THEN 'CRITICAL'
        WHEN elapsed > 600 THEN 'WARNING'
        ELSE 'OK'
    END AS status
FROM system.merges
WHERE elapsed > 600  -- 运行超过 10 分钟
ORDER BY elapsed DESC;

-- ==========================================
-- 4. Mutation 进度监控 (system.mutations)
-- ==========================================

-- 4.1 正在进行的 Mutation
-- 【场景】查看所有未完成的 Mutation（UPDATE/DELETE）
-- 【原理】Mutation 是异步操作，is_done = 0 表示还在执行
-- 【坑】Mutation 执行期间会阻塞该表的合并，大范围 Mutation 会影响查询性能
SELECT
    database,
    table,
    command,
    mutation_id,
    create_time,
    parts_to_do,
    parts_done,
    is_done,
    round(progress * 100, 2) AS progress_percent,
    formatReadableSize(bytes_read) AS bytes_read,
    formatReadableSize(bytes_written) AS bytes_written,
    formatReadableTimeDelta(now() - create_time) AS elapsed
FROM system.mutations
WHERE is_done = 0
ORDER BY create_time;

-- 4.2 Mutation 卡住检测
-- 【场景】检测长时间未完成的 Mutation
-- 【对比】小表 Mutation 应在秒级完成，大表通常在分钟级
SELECT
    database,
    table,
    command,
    create_time,
    parts_to_do,
    parts_done,
    formatReadableTimeDelta(now() - create_time) AS elapsed,
    latest_failed_part,
    latest_fail_time,
    latest_fail_reason
FROM system.mutations
WHERE is_done = 0
  AND create_time < now() - INTERVAL 1 HOUR  -- 超过 1 小时
ORDER BY create_time;

-- 4.3 Mutation 历史
-- 【场景】查看最近 1 天的 Mutation 操作记录
SELECT
    database,
    table,
    command,
    create_time,
    done_time,
    parts_to_do,
    elapsed,
    exception_code,
    exception_text
FROM system.mutations
WHERE done_time >= now() - INTERVAL 1 DAY
ORDER BY create_time DESC;

-- ==========================================
-- 5. 副本健康监控 (system.replicas)
-- ==========================================

-- 5.1 副本状态概览
-- 【场景】查看所有副本的详细状态
-- 【原理】absolute_delay 表示该副本落后主副本的秒数
-- 【坑】absolute_delay > 0 不一定表示异常，需要结合 queue_size 判断
SELECT
    database,
    table,
    replica_name,
    is_leader,
    is_readonly,
    is_session_expired,
    queue_size,
    absolute_delay,
    formatReadableTimeDelta(absolute_delay) AS delay_readable,
    total_replicas,
    active_replicas,
    last_queue_update
FROM system.replicas
ORDER BY absolute_delay DESC;

-- 5.2 有延迟的副本
-- 【场景】重点关注有延迟或队列积压的副本
SELECT
    database,
    table,
    replica_name,
    is_leader,
    is_readonly,
    absolute_delay,
    queue_size,
    CASE
        WHEN absolute_delay > 300 THEN 'CRITICAL'
        WHEN absolute_delay > 60 THEN 'WARNING'
        ELSE 'OK'
    END AS status
FROM system.replicas
WHERE absolute_delay > 0
   OR queue_size > 0
ORDER BY absolute_delay DESC;

-- 5.3 会话过期副本
-- 【场景】会话过期的副本无法接收复制数据，需要立即处理
-- 【原理】is_session_expired = 1 表示副本与 Keeper/ZooKeeper 的会话断开
SELECT
    database,
    table,
    replica_name,
    queue_size,
    absolute_delay,
    last_queue_update,
    zookeeper_path
FROM system.replicas
WHERE is_session_expired = 1
ORDER BY queue_size DESC;

-- 5.4 副本健康评分
-- 【场景】按表聚合副本同步状态，生成健康评分
SELECT
    database,
    table,
    countIf(is_leader = 1) AS leader_count,
    countIf(is_session_expired = 1) AS expired_count,
    countIf(is_readonly = 1) AS readonly_count,
    avg(queue_size) AS avg_queue_size,
    max(absolute_delay) AS max_delay_seconds,
    formatReadableTimeDelta(max(absolute_delay)) AS max_delay_readable,
    CASE
        WHEN countIf(is_session_expired = 1) > 0 THEN 'CRITICAL'
        WHEN countIf(is_readonly = 1) > 0 THEN 'WARNING'
        WHEN max(absolute_delay) > 300 THEN 'WARNING'
        ELSE 'OK'
    END AS overall_status
FROM system.replicas
GROUP BY database, table
ORDER BY max_delay_seconds DESC;

-- ==========================================
-- 6. 复制队列监控 (system.replication_queue)
-- ==========================================

-- 6.1 复制队列待处理任务
-- 【场景】查看复制队列中的待处理任务
-- 【原理】复制队列中的任务需要按顺序执行，积压会导致数据不一致
SELECT
    database,
    table,
    type,
    replica_name,
    parts_to_do,
    exception_text,
    num_tries,
    last_attempt_time,
    last_exception_time
FROM system.replication_queue
WHERE parts_to_do > 0
ORDER BY parts_to_do DESC
LIMIT 20;

-- 6.2 复制队列异常
-- 【场景】检测复制队列中的异常任务
-- 【坑】num_tries 不断增长说明复制任务持续失败，需要人工介入
SELECT
    database,
    table,
    replica_name,
    type,
    num_tries,
    parts_to_do,
    exception_text,
    last_exception_time,
    last_attempt_time
FROM system.replication_queue
WHERE num_tries > 3  -- 重试超过 3 次
   OR last_exception_time > now() - INTERVAL 1 HOUR
ORDER BY num_tries DESC;

-- ==========================================
-- 7. 分离 Part 监控 (system.detached_parts)
-- ==========================================

-- 7.1 查看分离 Parts
-- 【场景】检查异常分离的 Part，决定是 ATTACH 还是清理
-- 【原理】分离 Parts 不会自动删除，需要人工处理
SELECT
    database,
    table,
    partition_id,
    name,
    reason,
    min_block_number,
    max_block_number,
    level
FROM system.detached_parts
WHERE database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
ORDER BY database, table;

-- 7.2 分离原因统计
-- 【场景】了解 Part 被分离的主要原因，排查潜在问题
SELECT
    reason,
    count(*) AS part_count,
    count(DISTINCT concat(database, '.', table)) AS affected_tables
FROM system.detached_parts
GROUP BY reason
ORDER BY part_count DESC;

-- ==========================================
-- 8. 当前查询监控 (system.processes)
-- ==========================================

-- 8.1 当前正在执行的查询
-- 【场景】查看所有正在运行的查询，识别长时间运行的查询
SELECT
    query_id,
    user,
    query,
    elapsed,
    formatReadableSize(read_rows) AS read_rows,
    formatReadableSize(read_bytes) AS read_bytes,
    formatReadableSize(memory_usage) AS memory_usage,
    thread_ids,
    is_cancelled
FROM system.processes
WHERE query != ''
ORDER BY elapsed DESC
LIMIT 20;

-- 8.2 长时间运行查询
-- 【场景】识别运行超过 60 秒的查询，考虑是否需要终止
SELECT
    query_id,
    user,
    elapsed,
    formatReadableSize(memory_usage) AS memory_usage,
    formatReadableSize(read_bytes) AS read_bytes,
    substring(query, 1, 300) AS query
FROM system.processes
WHERE elapsed > 60
ORDER BY elapsed DESC;

-- 8.3 高内存消耗查询
-- 【场景】识别内存消耗大的查询，防止 OOM
SELECT
    query_id,
    user,
    formatReadableSize(memory_usage) AS memory_usage,
    elapsed,
    substring(query, 1, 300) AS query
FROM system.processes
WHERE memory_usage > 1073741824  -- 超过 1GB
ORDER BY memory_usage DESC;

-- ==========================================
-- 9. 慢查询监控 (system.query_thread_log)
-- ==========================================

-- 注意: 使用 system.query_thread_log 替代 system.query_log
-- 使用前必须设置: SET log_query_threads = 1

-- 9.1 启用线程级日志
SET log_query_threads = 1;

-- 9.2 Top 慢查询
-- 【场景】最近 1 小时内执行最慢的查询
-- 【原理】query_thread_log 记录了每个线程的查询执行信息
-- 【对比】相比 query_log，query_thread_log 提供更细粒度的线程级信息
SELECT
    query_id,
    thread_name,
    query_duration_ms / 1000.0 AS duration_sec,
    read_rows,
    formatReadableSize(read_bytes) AS read_bytes,
    formatReadableSize(memory_usage) AS memory_usage,
    substring(query, 1, 200) AS query
FROM system.query_thread_log
WHERE event_time >= now() - INTERVAL 1 HOUR
  AND query_duration_ms > 5000
ORDER BY query_duration_ms DESC
LIMIT 10;

-- 9.3 慢查询统计分布
-- 【场景】了解查询延迟分布，评估集群性能
SELECT
    countIf(query_duration_ms < 100) AS fast_queries,
    countIf(query_duration_ms BETWEEN 100 AND 1000) AS medium_queries,
    countIf(query_duration_ms > 1000) AS slow_queries,
    avg(query_duration_ms) AS avg_duration_ms,
    max(query_duration_ms) AS max_duration_ms,
    quantile(0.5)(query_duration_ms) AS p50_ms,
    quantile(0.95)(query_duration_ms) AS p95_ms,
    quantile(0.99)(query_duration_ms) AS p99_ms
FROM system.query_thread_log
WHERE event_time > now() - INTERVAL 1 HOUR;

-- 9.4 按用户统计慢查询
-- 【场景】识别哪个用户提交了最多的慢查询
SELECT
    user,
    count() AS slow_query_count,
    avg(query_duration_ms) / 1000 AS avg_duration_sec,
    max(query_duration_ms) / 1000 AS max_duration_sec,
    sum(query_duration_ms) / 60000 AS total_minutes
FROM system.query_thread_log
WHERE event_time >= now() - INTERVAL 1 DAY
  AND query_duration_ms > 3000
  AND query NOT LIKE '%system.%'
GROUP BY user
ORDER BY slow_query_count DESC;

-- 9.5 高内存消耗查询
-- 【场景】识别内存消耗最大的查询，为资源隔离提供依据
SELECT
    user,
    query_id,
    formatReadableSize(memory_usage) AS memory_usage,
    query_duration_ms / 1000.0 AS duration_sec,
    substring(query, 1, 200) AS query
FROM system.query_thread_log
WHERE event_time >= now() - INTERVAL 1 DAY
  AND memory_usage > 0
ORDER BY memory_usage DESC
LIMIT 10;

-- 9.6 全表扫描查询检测
-- 【场景】识别没有有效利用索引的查询
-- 【原理】读取行数远大于返回行数的查询，说明没有使用索引或分区裁剪
SELECT
    query_id,
    user,
    query_duration_ms / 1000 AS duration_sec,
    read_rows,
    result_rows,
    read_rows / greatest(result_rows, 1) AS read_ratio,
    substring(query, 1, 300) AS query
FROM system.query_thread_log
WHERE event_time >= now() - INTERVAL 1 DAY
  AND read_rows > 100000
  AND result_rows < 1000
  AND read_rows / result_rows > 100
ORDER BY read_ratio DESC
LIMIT 20;

-- 9.7 查询失败分析
-- 【场景】分析最近的查询失败原因
SELECT
    exception_code,
    exception_text,
    count() AS error_count,
    any(substring(query, 1, 200)) AS example_query
FROM system.query_thread_log
WHERE type IN ('ExceptionWhileProcessing', 'ExceptionBeforeStart')
  AND event_time >= now() - INTERVAL 1 DAY
GROUP BY exception_code, exception_text
ORDER BY error_count DESC
LIMIT 20;

-- ==========================================
-- 10. 实时指标 (system.metrics + system.events)
-- ==========================================

-- 10.1 当前关键指标
-- 【场景】实时查看集群的核心指标
-- 【原理】system.metrics 是即时指标，反映当前状态
SELECT
    metric,
    value,
    description
FROM system.metrics
WHERE metric IN (
    'Query',           -- 当前查询数
    'Connection',      -- 当前连接数
    'TCPConnection',   -- TCP 连接数
    'HTTPConnection',  -- HTTP 连接数
    'MemoryTracking',  -- 查询内存跟踪
    'MaxConcurrentQueries',           -- 最大并发查询数
    'BackgroundMergesSchedulePoolSize', -- 合并调度池大小
    'BackgroundMergesSchedulePoolTask', -- 合并调度池任务数
    'BackgroundFetchesSchedulePoolTask',-- 后台拉取任务数
    'ReplicatedChecks',                -- 副本检查数
    'Parts',                           -- 活跃 Part 数
    'PartsActive',                     -- 活跃 Part 数
    'PartsTemporary',                  -- 临时 Part 数
    'PartsPreActive',                  -- 预活跃 Part 数
    'PartsDeleting',                   -- 正在删除的 Part 数
    'PartsDeleteOnDestroy'             -- 销毁时删除的 Part 数
)
ORDER BY metric;

-- 10.2 累计事件统计
-- 【场景】查看从启动以来的累计事件计数
-- 【原理】system.events 是累计计数，可用于计算每秒速率
SELECT
    event,
    value,
    description
FROM system.events
WHERE event IN (
    'Query',              -- 总查询数
    'SelectQuery',        -- SELECT 查询数
    'InsertQuery',        -- INSERT 查询数
    'FailedQuery',        -- 失败查询数
    'FailedSelectQuery',  -- 失败 SELECT 数
    'FailedInsertQuery',  -- 失败 INSERT 数
    'Merge',              -- 合并次数
    'PartMerged',         -- 合并的 Part 数
    'MergedRows',         -- 合并的行数
    'MergedUncompressedBytes',  -- 合并的未压缩字节数
    'ReplicatedPartMerges',     -- 复制表合并次数
    'ReplicatedPartFetches',    -- 复制表拉取次数
    'ReplicatedPartFailedFetches', -- 复制表拉取失败次数
    'ReplicatedPartMutations',  -- 复制表 Mutation 次数
    'ReplicatedDataLoss',       -- 复制表数据丢失事件
    'InsertedRows',             -- 插入行数
    'InsertedBytes',            -- 插入字节数
    'SelectedRows',             -- 选择行数
    'SelectedBytes',            -- 选择字节数
    'DiskReadElapsedMicroseconds',  -- 磁盘读取耗时
    'DiskWriteElapsedMicroseconds', -- 磁盘写入耗时
    'OSCPUVirtualTimeMicroseconds',  -- CPU 使用时间
    'OSIOWaitMicroseconds'           -- IO 等待时间
)
ORDER BY event;

-- 10.3 计算每秒速率
-- 【场景】计算关键操作的每秒速率（QPS、写入速率等）
-- 【原理】通过两次采样计算差值，再除以时间间隔
-- 这里使用单次查询的近似值
SELECT
    'Queries Per Second (approx)' AS metric,
    round(value / greatest(uptime(), 1), 2) AS rate_per_sec
FROM system.events
WHERE event = 'Query'

UNION ALL

SELECT
    'Inserts Per Second (approx)',
    round(value / greatest(uptime(), 1), 2)
FROM system.events
WHERE event = 'InsertQuery'

UNION ALL

SELECT
    'Failed Queries Per Second (approx)',
    round(value / greatest(uptime(), 1), 2)
FROM system.events
WHERE event = 'FailedQuery';

-- ==========================================
-- 11. 一键健康检查（综合）
-- ==========================================

-- 11.1 综合健康检查
-- 【场景】快速了解集群整体健康状态，适合 Dashboard 首页
-- 【原理】聚合多个系统表的关键指标，生成统一的健康评分
SELECT
    'Replica Delay' AS check_type,
    max(absolute_delay) AS value,
    CASE
        WHEN max(absolute_delay) > 300 THEN 'CRITICAL'
        WHEN max(absolute_delay) > 60  THEN 'WARNING'
        ELSE 'OK'
    END AS status
FROM system.replicas
UNION ALL
SELECT
    'Disk Free Percent',
    min(free_space * 100.0 / total_space),
    CASE
        WHEN min(free_space * 100.0 / total_space) < 10 THEN 'CRITICAL'
        WHEN min(free_space * 100.0 / total_space) < 20 THEN 'WARNING'
        ELSE 'OK'
    END
FROM system.disks
UNION ALL
SELECT
    'Merge Backlog',
    count(*),
    CASE
        WHEN count(*) > 50 THEN 'CRITICAL'
        WHEN count(*) > 20 THEN 'WARNING'
        ELSE 'OK'
    END
FROM system.merges
UNION ALL
SELECT
    'Session Expired Replicas',
    countIf(is_session_expired = 1),
    CASE
        WHEN countIf(is_session_expired = 1) > 0 THEN 'CRITICAL'
        ELSE 'OK'
    END
FROM system.replicas
UNION ALL
SELECT
    'Readonly Replicas',
    countIf(is_readonly = 1),
    CASE
        WHEN countIf(is_readonly = 1) > 0 THEN 'CRITICAL'
        ELSE 'OK'
    END
FROM system.replicas
UNION ALL
SELECT
    'Pending Mutations',
    count(*),
    CASE
        WHEN count(*) > 10 THEN 'WARNING'
        ELSE 'OK'
    END
FROM system.mutations
WHERE is_done = 0;

-- 11.2 集群健康评分
-- 【场景】生成综合健康评分（0-100 分），用于运维 Dashboard
SELECT
    round(
        (max(absolute_delay) = 0 ? 20 : 0) +
        (min(free_space * 100.0 / total_space) >= 20 ? 20 : 0) +
        (count(*) = 0 ? 20 : 0) +  -- 无待合并
        (countIf(is_session_expired = 1) = 0 ? 20 : 0) +
        (countIf(is_readonly = 1) = 0 ? 20 : 0)
    ) AS health_score,
    CASE
        WHEN round(...) >= 80 THEN 'HEALTHY'
        WHEN round(...) >= 60 THEN 'DEGRADED'
        WHEN round(...) >= 40 THEN 'WARNING'
        ELSE 'CRITICAL'
    END AS health_status
FROM system.replicas
CROSS JOIN system.disks
CROSS JOIN system.merges;

-- 11.3 集群概览信息
-- 【场景】生成集群概览，用于运维 Dashboard
SELECT
    'Nodes' AS metric,
    count(*) AS value,
    'INFO' AS status
FROM system.clusters
WHERE cluster = 'treasurycluster'

UNION ALL

SELECT
    'Active Replicas',
    sum(active_replicas),
    CASE WHEN sum(active_replicas) = sum(total_replicas) THEN 'OK' ELSE 'WARNING' END
FROM system.replicas

UNION ALL

SELECT
    'Total Tables',
    count(*),
    'INFO'
FROM system.tables
WHERE database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')

UNION ALL

SELECT
    'Total Rows',
    sum(rows),
    'INFO'
FROM system.parts
WHERE active = 1

UNION ALL

SELECT
    'Total Size',
    formatReadableSize(sum(bytes_on_disk)),
    'INFO'
FROM system.parts
WHERE active = 1;

-- ==========================================
-- 12. 数据倾斜检测
-- ==========================================

-- 12.1 分片间数据倾斜
-- 【场景】检测各分片间的数据分布是否均匀
-- 【原理】分片间数据差异超过 30% 说明数据倾斜，需要调整分片键
SELECT
    database,
    table,
    avg(rows_per_shard) AS avg_rows,
    max(rows_per_shard) - min(rows_per_shard) AS max_min_diff,
    round((max(rows_per_shard) - min(rows_per_shard)) * 100.0 / greatest(avg(rows_per_shard), 1), 2) AS diff_percent
FROM (
    SELECT
        database,
        table,
        shard_num,
        sum(rows) AS rows_per_shard
    FROM system.parts
    WHERE active = 1
      AND database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
    GROUP BY database, table, shard_num
)
GROUP BY database, table
HAVING diff_percent > 30
ORDER BY diff_percent DESC;

-- 12.2 分区大小倾斜
-- 【场景】检测同一表内分区间的数据量差异
SELECT
    database,
    table,
    partition,
    partition_rows,
    round(partition_rows * 100.0 / sum(partition_rows) OVER (PARTITION BY database, table), 2) AS pct_of_table
FROM (
    SELECT
        database,
        table,
        partition,
        sum(rows) AS partition_rows
    FROM system.parts
    WHERE active = 1
      AND database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
    GROUP BY database, table, partition
)
ORDER BY database, table, partition_rows DESC;

-- ==========================================
-- 清理
-- ==========================================
DROP DATABASE IF EXISTS ops_test;

-- ============================================================================
-- 最佳实践：
-- 1. 将一键健康检查集成到定时任务，每 5 分钟执行一次
-- 2. 健康评分低于 60 分时触发 P0 告警
-- 3. 副本延迟超过 60 秒需要关注，超过 300 秒需要立即处理
-- 4. Part 数量超过 500 的表，考虑调整合并参数或手动 OPTIMIZE
-- 5. 磁盘使用率超过 80% 就需要扩容或清理数据
-- 6. 使用 system.query_thread_log 替代 system.query_log 前 SET log_query_threads = 1
-- 7. 定期检查 system.detached_parts，及时清理或恢复分离的 Part
-- 8. Mutation 超过 1 小时未完成需要排查原因，考虑终止或调整
-- ============================================================================