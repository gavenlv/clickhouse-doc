-- ============================================================================
-- 07 - 日常维护
-- ============================================================================
-- 场景: Merge 优化、Part 碎片清理、索引重建、元数据维护、系统表清理、自动化维护
-- 集群: treasurycluster (2副本)
-- 耗时: 20-30分钟
-- 注意: 日常维护操作应在业务低峰期执行
--       涉及 DROP/ALTER 的操作需提前确认影响范围
--       system.query_log 在本集群已禁用，统一用 system.query_thread_log
--       + SET log_query_threads = 1
-- ============================================================================

DROP DATABASE IF EXISTS ops_test;
CREATE DATABASE ops_test;
USE ops_test;

-- ============================================================================
-- 【原理】日常维护体系
--
-- ClickHouse 的日常维护围绕 MergeTree 存储引擎的核心机制展开：
--
--   ┌─────────────────────────────────────────────────────────────────────────┐
--   │                      ClickHouse 日常维护体系                              │
--   └─────────────────────────────────────────────────────────────────────────┘
--
--   维护目标:
--   1. 查询性能 — 减少 Part 数量、优化索引、保持数据紧凑
--   2. 存储效率 — 清理过期数据、回收磁盘空间、控制碎片率
--   3. 系统稳定 — 监控副本同步、清理系统日志、预防故障
--   4. 数据安全 — 定期备份验证、检查数据完整性
--
--   维护频率矩阵:
--   ┌──────────────────┬──────────────────┬──────────────────┬──────────────────┐
--   │     任务          │     频率          │     影响范围      │     执行窗口      │
--   ├──────────────────┼──────────────────┼──────────────────┼──────────────────┤
--   │ Part 碎片检查     │  每日            │  只读，无影响     │  任何时间         │
--   │ 健康检查          │  每日            │  只读，无影响     │  任何时间         │
--   │ 慢查询分析        │  每日            │  只读，无影响     │  任何时间         │
--   ├──────────────────┼──────────────────┼──────────────────┼──────────────────┤
--   │ OPTIMIZE 碎片整理  │  每周            │  消耗 I/O/CPU     │  业务低峰期       │
--   │ 系统表清理         │  每周            │  写入，中影响     │  业务低峰期       │
--   │ 过期分区清理       │  每周            │  写入，中影响     │  业务低峰期       │
--   ├──────────────────┼──────────────────┼──────────────────┼──────────────────┤
--   │ 索引重建           │  每月            │  消耗 I/O         │  业务低峰期       │
--   │ Projection 维护    │  每月            │  消耗 I/O/CPU     │  业务低峰期       │
--   │ 配置审计           │  每月            │  只读，无影响     │  任何时间         │
--   ├──────────────────┼──────────────────┼──────────────────┼──────────────────┤
--   │ 全量备份验证       │  每季度          │  消耗 I/O/网络    │  业务低峰期       │
--   │ 版本升级评估       │  每季度          │  只读，无影响     │  任何时间         │
--   │ 容量规划评审       │  每季度          │  只读，无影响     │  任何时间         │
--   └──────────────────┴──────────────────┴──────────────────┴──────────────────┘
-- ============================================================================

-- ============================================================================
-- 【坑】日常维护注意事项
--   1. OPTIMIZE TABLE FINAL 是资源密集型操作，必须在低峰期执行
--   2. 不要在生产环境对同一张表频繁执行 OPTIMIZE（超过每日 1 次）
--   3. ALTER TABLE DELETE 会生成 Mutation，可能长时间阻塞
--   4. 清理 system 表时，不要直接 DROP/TRUNCATE 系统表
--   5. 系统表日志清理后不能恢复，建议先备份再清理
--   6. 修改 Merge 参数时，需结合集群的实际写入负载评估
--   7. 索引重建需要重写整个 Part，确保有足够的磁盘空间
-- ============================================================================

-- ============================================================================
-- 【对比】Part 合并策略对比
--
-- ┌──────────────────┬──────────────────┬──────────────────┬──────────────────┐
-- │     策略          │     合并速度      │     资源消耗      │     碎片消除     │
-- ├──────────────────┼──────────────────┼──────────────────┼──────────────────┤
-- │ 自动后台合并       │  慢（持续）       │  低              │  逐步            │
-- ├──────────────────┼──────────────────┼──────────────────┼──────────────────┤
-- │ OPTIMIZE FINAL    │  快（一次性）     │  高              │  完全            │
-- ├──────────────────┼──────────────────┼──────────────────┼──────────────────┤
-- │ OPTIMIZE 分区级    │  中              │  中              │  分区级完全      │
-- ├──────────────────┼──────────────────┼──────────────────┼──────────────────┤
-- │ 调大合并参数       │  中（持续）       │  中              │  较好            │
-- └──────────────────┴──────────────────┴──────────────────┴──────────────────┘
-- ============================================================================

-- ==========================================
-- 0. 创建测试环境
-- ==========================================

-- 创建测试表模拟日常维护场景
CREATE TABLE ops_test.events (
    event_id UInt64,
    event_time DateTime,
    event_type String,
    user_id UInt64,
    event_data String
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_type, event_time)
SETTINGS index_granularity = 8192;

-- 插入测试数据
INSERT INTO ops_test.events
SELECT
    number AS event_id,
    now() - INTERVAL rand() % 365 DAY AS event_time,
    ['click', 'view', 'purchase', 'login', 'logout'][rand() % 5 + 1] AS event_type,
    rand() % 100000 AS user_id,
    toString(rand()) AS event_data
FROM system.numbers
LIMIT 500000;

-- 创建第二张测试表用于演示清理操作
CREATE TABLE ops_test.raw_logs (
    log_id UInt64,
    log_time DateTime,
    log_level String,
    message String,
    source String
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(log_time)
ORDER BY (log_time, log_id);

INSERT INTO ops_test.raw_logs
SELECT
    number AS log_id,
    now() - INTERVAL rand() % 200 DAY AS log_time,
    ['INFO', 'WARN', 'ERROR', 'DEBUG'][rand() % 4 + 1] AS log_level,
    toString(rand()) AS message,
    ['app1', 'app2', 'app3'][rand() % 3 + 1] AS source
FROM system.numbers
LIMIT 200000;

-- 创建需要定期清理的临时数据处理表
CREATE TABLE ops_test.staging_data (
    id UInt64,
    batch_id String,
    created_at DateTime DEFAULT now()
) ENGINE = MergeTree()
ORDER BY id;

-- ==========================================
-- 1. 健康检查与状态评估
-- ==========================================

-- 1.1 整体健康检查
-- 【场景】每日例行检查，快速了解集群整体健康状态
-- 【原理】通过 system.replicas、system.disks、system.merges 等系统表综合评估
SELECT
    'Replica Delay' AS check_type,
    max(absolute_delay) AS value,
    CASE
        WHEN max(absolute_delay) > 300 THEN 'CRITICAL'
        WHEN max(absolute_delay) > 60 THEN 'WARNING'
        ELSE 'OK'
    END AS status
FROM system.replicas
UNION ALL
SELECT
    'Disk Free (%)',
    min(free_space / total_space * 100),
    CASE
        WHEN min(free_space / total_space) < 0.1 THEN 'CRITICAL'
        WHEN min(free_space / total_space) < 0.2 THEN 'WARNING'
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
    'Session Expired',
    sum(CASE WHEN is_session_expired = 1 THEN 1 ELSE 0 END),
    CASE
        WHEN sum(CASE WHEN is_session_expired = 1 THEN 1 ELSE 0 END) > 0 THEN 'CRITICAL'
        ELSE 'OK'
    END
FROM system.replicas;

-- 1.2 查看最近的错误日志
-- 【场景】快速发现近期的系统错误和异常
-- 【原理】system.text_log 记录了 ClickHouse 运行时的所有日志
-- 【坑】text_log 表可能很大，需要限制查询时间和级别
SELECT
    event_time,
    level,
    logger_name,
    message,
    thread_id
FROM system.text_log
WHERE level IN ('Error', 'Critical')
  AND event_time > now() - INTERVAL 1 HOUR
ORDER BY event_time DESC
LIMIT 50;

-- 1.3 查看慢查询（使用 query_thread_log）
-- 【场景】发现执行时间超过阈值的慢查询，分析性能瓶颈
-- 【原理】system.query_thread_log 记录了每个查询线程的详细信息
-- 【坑】需要先 SET log_query_threads = 1 才能记录查询线程日志
SET log_query_threads = 1;

SELECT
    query_id,
    query_duration_ms / 1000 AS duration_seconds,
    substring(query, 1, 200) AS query_preview,
    read_rows,
    formatReadableSize(read_bytes) AS bytes_read,
    formatReadableSize(memory_usage) AS memory_usage,
    thread_id,
    thread_name,
    event_time
FROM system.query_thread_log
WHERE query_duration_ms > 5000  -- 超过 5 秒
  AND query NOT LIKE '%system.query_thread_log%'
  AND event_time > now() - INTERVAL 1 DAY
ORDER BY query_duration_ms DESC
LIMIT 20;

-- 1.4 查看当前正在执行的查询
-- 【场景】实时监控当前查询，发现长时间运行的查询
-- 【原理】system.processes 显示当前正在执行的查询列表
SELECT
    query_id,
    user,
    substring(query, 1, 100) AS query,
    elapsed,
    formatReadableSize(memory_usage) AS memory_usage,
    formatReadableSize(read_rows) AS read_rows,
    formatReadableSize(read_bytes) AS read_bytes
FROM system.processes
WHERE query != ''
ORDER BY elapsed DESC
LIMIT 20;

-- ==========================================
-- 2. Part 碎片管理与合并优化
-- ==========================================

-- 2.1 查看 Part 碎片化情况
-- 【场景】识别 Part 数量过多的表，碎片化严重会影响查询性能
-- 【原理】每个 INSERT 会产生新的 Part，后台合并线程会逐步合并
--       Part 数量过多会导致 SELECT 时需要读取大量文件头
-- 【坑】Part 数量 > 50 建议关注，> 100 需要干预
--       level=0 的 Part 是未合并的新写入数据
SELECT
    database,
    table,
    count() AS total_parts,
    countIf(level = 0) AS level0_parts,       -- 新写入未合并
    countIf(level = 1) AS level1_parts,
    countIf(level > 1) AS merged_parts,
    sum(rows) AS total_rows,
    formatReadableSize(sum(bytes_on_disk)) AS total_size,
    round(avg(bytes_on_disk)) AS avg_part_size
FROM system.parts
WHERE active = 1
  AND database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
GROUP BY database, table
HAVING count() > 30  -- Part 数超过 30 提醒关注
ORDER BY total_parts DESC;

-- 2.2 查看合并任务进度
-- 【场景】监控后台合并的执行情况，确保合并没有被阻塞
-- 【原理】system.merges 记录了所有正在进行的合并任务
-- 【坑】合并任务长时间不完成可能是由于资源不足或参数配置不当
SELECT
    database,
    table,
    partition_id,
    result_part_name,
    progress,
    num_parts,
    formatReadableSize(total_size_bytes_compressed) AS size,
    elapsed,
    is_mutation
FROM system.merges
ORDER BY total_size_bytes_compressed DESC
LIMIT 20;

-- 2.3 生成 OPTIMIZE 语句（低峰期执行）
-- 【场景】对碎片化严重的表执行 OPTIMIZE，强制合并所有 Part
-- 【原理】OPTIMIZE TABLE FINAL 会合并所有 Part 到 Level 最大级别
-- 【坑】Online 环境下 OPTIMIZE 会占用大量 I/O 和 CPU
--       建议在低峰期单表执行，不要并行执行多个 OPTIMIZE
SELECT
    'OPTIMIZE TABLE ' || database || '.' || table ||
    ' ON CLUSTER \'treasurycluster\' FINAL;' AS optimize_sql,
    count() AS current_parts,
    formatReadableSize(sum(bytes_on_disk)) AS size
FROM system.parts
WHERE active = 1
  AND database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
  AND database = 'ops_test'
GROUP BY database, table
HAVING count() > 20
ORDER BY current_parts DESC;

-- 2.4 分区级 OPTIMIZE（更轻量）
-- 【场景】只对特定分区进行合并，减少对全表的影响
-- 【原理】分区级 OPTIMIZE 只处理指定分区内的 Part
-- 【坑】分区级 OPTIMIZE 不能跨分区合并，各分区独立进行
-- OPTIMIZE TABLE ops_test.events PARTITION '202401' FINAL;
-- OPTIMIZE TABLE ops_test.events PARTITION '202402' FINAL;

-- 2.5 调整合并参数
-- 【场景】根据业务写入负载调整合并策略，加速或减慢合并频率
-- 【原理】合并参数控制后台合并线程的行为
-- 【坑】参数调整后立即生效，但不会重启服务
--       过大的合并参数可能导致内存溢出
-- · 增加合并线程（适合写入密集型场景）
-- SET GLOBAL max_merges_in_parallel = 8;
-- · 增大单次合并的最大大小（减少碎片）
-- SET GLOBAL max_bytes_to_merge_at_max_space_in_pool = 10737418240;  -- 10GB
-- · 增大单次合并的最大 Part 数
-- SET GLOBAL max_bytes_to_merge_at_once = 1610612736;  -- 1.5GB

-- 2.6 查看合并参数当前值
-- 【场景】确认当前合并参数的配置，评估是否需要调整
SELECT
    name,
    value,
    changed,
    description
FROM system.settings
WHERE name IN (
    'max_merges_in_parallel',
    'max_bytes_to_merge_at_max_space_in_pool',
    'max_bytes_to_merge_at_once',
    'merge_max_block_size',
    'max_part_loading_threads'
);

-- ==========================================
-- 3. 过期数据清理
-- ==========================================

-- 3.1 生成清理过期分区的 SQL
-- 【场景】定期清理超过保留期限的分区，释放磁盘空间
-- 【原理】DROP PARTITION 直接删除整个分区的所有数据
-- 【坑】DROP PARTITION 是 DDL 操作，立即生效不可恢复
--       执行前务必确认分区的数据范围
SELECT
    'ALTER TABLE ' || database || '.' || table ||
    ' DROP PARTITION \'' || partition || '\' ON CLUSTER \'treasurycluster\';' AS cleanup_sql,
    count() AS part_count,
    formatReadableSize(sum(bytes_on_disk)) AS freed_size,
    min(min_time) AS data_start,
    max(max_time) AS data_end
FROM system.parts
WHERE active = 1
  AND database = 'ops_test'
  AND partition <= toString(toYYYYMM(now() - INTERVAL 6 MONTH))  -- 保留 6 个月
GROUP BY database, table, partition
ORDER BY database, table, partition;

-- 3.2 使用 ALTER TABLE DELETE 清理条件数据
-- 【场景】按条件删除数据，而非整个分区
-- 【原理】ALTER TABLE DELETE 是异步 Mutation 操作
-- 【坑】DELETE 操作会生成 Mutation，需要等待后台执行完成
--       大量 DELETE 操作可能导致 Mutation 堆积
-- ALTER TABLE ops_test.raw_logs
--     DELETE WHERE log_time < now() - INTERVAL 90 DAY;

-- 3.3 查看 Mutation 进度
-- 【场景】监控 DELETE/UPDATE 等 Mutation 操作的执行进度
-- 【原理】system.mutations 记录了所有 Mutation 的状态
-- 【坑】长时间未完成的 Mutation 可能阻塞后续的 Mutation
--       如果发现 stuck Mutation，需要检查副本状态
SELECT
    database,
    table,
    mutation_id,
    command,
    create_time,
    parts_to_do,
    parts_done,
    round(parts_done / greatest(parts_to_do + parts_done, 1) * 100, 1) AS progress_percent,
    is_done,
    latest_fail_time,
    latest_fail_reason
FROM system.mutations
WHERE database = 'ops_test'
  AND is_done = 0
ORDER BY create_time;

-- 3.4 清理临时表和测试数据
-- 【场景】定期清理临时表和测试环境的数据
-- 【原理】识别名字包含 test/temp/staging 的表并生成清理语句
-- 【坑】清理前务必确认表名是否包含生产数据
SELECT
    'DROP TABLE IF EXISTS ' || database || '.' || name || ';' AS drop_sql,
    engine,
    formatReadableSize(total_bytes) AS size
FROM system.tables
WHERE database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
  AND (database LIKE '%test%'
    OR database LIKE '%temp%'
    OR database LIKE '%staging%'
    OR name LIKE '%test%'
    OR name LIKE '%temp%'
    OR name LIKE '%staging%')
ORDER BY database, name;

-- ==========================================
-- 4. 系统表维护
-- ==========================================

-- 4.1 查看系统表大小
-- 【场景】了解各系统表占用的磁盘空间，制定清理策略
-- 【原理】系统表也是 MergeTree 引擎，数据会持续累积
-- 【坑】系统表不能直接 DROP，需要谨慎使用 ALTER TABLE DELETE
SELECT
    database,
    name AS table_name,
    engine,
    formatReadableSize(total_bytes) AS size,
    formatReadableSize(total_rows) AS rows,
    min_date,
    max_date
FROM system.tables
WHERE database = 'system'
  AND engine LIKE '%MergeTree%'
ORDER BY total_bytes DESC;

-- 4.2 清理 query_thread_log（保留最近 7 天）
-- 【场景】定期清理查询日志，防止系统表无限增长
-- 【原理】ALTER TABLE DELETE 按时间条件清理
-- 【坑】清理期间会写入 Mutation 日志，影响系统性能
--       建议在低峰期执行，每次清理时间范围不宜过大
-- ALTER TABLE system.query_thread_log ON CLUSTER 'treasurycluster'
--     DELETE WHERE event_date < today() - 7;

-- 4.3 清理 text_log（保留最近 3 天）
-- ALTER TABLE system.text_log ON CLUSTER 'treasurycluster'
--     DELETE WHERE event_date < today() - 3;

-- 4.4 清理 metric_log（保留最近 7 天）
-- ALTER TABLE system.metric_log ON CLUSTER 'treasurycluster'
--     DELETE WHERE event_date < today() - 7;

-- 4.5 清理 trace_log（保留最近 3 天）
-- ALTER TABLE system.trace_log ON CLUSTER 'treasurycluster'
--     DELETE WHERE event_date < today() - 3;

-- 4.6 查看系统表清理后的空间回收情况
-- 【场景】确认清理操作是否有效回收了空间
-- 【原理】清理后需要通过 OPTIMIZE FINAL 或等待后台合并来回收空间
-- 【坑】DELETE 只是标记数据为删除状态，不立即释放空间
--       需要等待合并任务处理后才能回收磁盘空间
SELECT
    database,
    name AS table_name,
    formatReadableSize(total_bytes) AS size,
    min_date,
    max_date
FROM system.tables
WHERE database = 'system'
  AND engine LIKE '%MergeTree%'
ORDER BY total_bytes DESC;

-- ==========================================
-- 5. 索引与 Projection 维护
-- ==========================================

-- 5.1 查看所有表的跳数索引
-- 【场景】检查索引配置，发现未使用索引的表
-- 【原理】data_skipping_indices 记录了所有跳数索引的元数据
SELECT
    database,
    table,
    name,
    type,
    expr,
    granularity,
    formatReadableSize(data_compressed_bytes) AS compressed_size,
    formatReadableSize(data_uncompressed_bytes) AS uncompressed_size
FROM system.data_skipping_indices
WHERE database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
ORDER BY database, table;

-- 5.2 查看 Projection 状态
-- 【场景】检查 Projection 的存储和更新状态
-- 【原理】Projection 是物化在 Part 内的预聚合数据
-- 【坑】Projection 过大时会影响写入性能，需要评估后使用
SELECT
    database,
    table,
    name,
    formatReadableSize(data_compressed_bytes) AS compressed_size,
    formatReadableSize(data_uncompressed_bytes) AS uncompressed_size,
    marks_count,
    rows
FROM system.projection_parts
WHERE active = 1
  AND database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
ORDER BY database, table, name;

-- 5.3 添加跳数索引（示例）
-- 【场景】为高频查询字段添加跳数索引，加速查询过滤
-- 【原理】跳数索引在 Part 级别存储统计信息，跳过不匹配的粒度组
-- 【坑】索引仅对新写入的数据生效，已有数据需要 MATERIALIZE 重建
--       索引粒度（granularity）过大或过小都会影响效果
-- ALTER TABLE ops_test.events
--     ADD INDEX idx_user_id (user_id) TYPE minmax GRANULARITY 4;
-- ALTER TABLE ops_test.events
--     ADD INDEX idx_event_data (event_data) TYPE tokenbf_v1(256, 3, 0) GRANULARITY 1;

-- 5.4 物化跳数索引（重写已有数据的索引）
-- 【场景】为已有数据构建跳数索引，需要执行 MATERIALIZE
-- 【原理】MATERIALIZE INDEX 会重写包含索引的 Part
-- 【坑】大表 MATERIALIZE 会消耗大量资源，建议在低峰期执行
-- ALTER TABLE ops_test.events MATERIALIZE INDEX idx_user_id;

-- 5.5 添加 Projection（示例）
-- 【场景】为高频聚合查询创建 Projection，加速查询性能
-- 【原理】Projection 在 Part 内存储预聚合数据，查询时自动匹配
-- 【坑】Projection 会增加写入开销，评估后再使用
--       创建 Projection 后需要 MATERIALIZE 才能对已有数据生效
-- ALTER TABLE ops_test.events
--     ADD PROJECTION proj_event_type_count
--     (
--         SELECT
--             event_type,
--             toDate(event_time) AS day,
--             count() AS event_count
--         GROUP BY event_type, day
--     );

-- 5.6 查看索引使用效率
-- 【场景】评估索引是否被查询有效利用，发现未命中索引的查询
-- 【原理】通过 system.query_thread_log 分析查询读取的行数与返回行数的比值
-- 【坑】需要开启 log_query_threads = 1 才能记录
SET log_query_threads = 1;

SELECT
    query_id,
    substring(query, 1, 200) AS query,
    read_rows,
    rows_before_limit,
    round(read_rows / greatest(rows_before_limit, 1), 2) AS index_effectiveness,
    query_duration_ms / 1000 AS duration_seconds
FROM system.query_thread_log
WHERE read_rows / greatest(rows_before_limit, 1) > 1000  -- 读取了 1000 倍的有效数据
  AND query_duration_ms > 1000
  AND query NOT LIKE '%system.query_thread_log%'
  AND event_time > now() - INTERVAL 7 DAY
ORDER BY read_rows DESC
LIMIT 20;

-- ==========================================
-- 6. 元数据与数据分布维护
-- ==========================================

-- 6.1 查看表大小和数据分布
-- 【场景】了解各表的数据量分布，发现异常增长的表
-- 【原理】system.tables 和 system.parts 提供表级和 Part 级元数据
SELECT
    database,
    name AS table_name,
    engine,
    formatReadableSize(total_rows) AS rows,
    formatReadableSize(total_bytes) AS size,
    min_date,
    max_date
FROM system.tables
WHERE database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
ORDER BY total_bytes DESC
LIMIT 50;

-- 6.2 检查数据倾斜
-- 【场景】发现分片间数据分布不均的情况
-- 【原理】通过 system.parts 的 shard_num 分析各分片的数据量
-- 【坑】数据倾斜会影响查询性能，倾斜严重时需要重新分片
--       差异超过 30% 需要关注，超过 50% 需要干预
SELECT
    database,
    table,
    shard_num,
    sum(rows) AS row_count,
    formatReadableSize(sum(bytes_on_disk)) AS size,
    count(DISTINCT partition) AS partition_count
FROM system.parts
WHERE active = 1
  AND database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
GROUP BY database, table, shard_num
ORDER BY database, table, shard_num;

-- 6.3 查看数据分布趋势
-- 【场景】了解数据在时间维度上的分布，发现异常
-- 【原理】按时间维度分析数据量的变化趋势
-- 【坑】如果某个月份的数据量异常小，可能数据丢失或写入失败
SELECT
    database,
    table,
    partition,
    count() AS part_count,
    sum(rows) AS total_rows,
    formatReadableSize(sum(bytes_on_disk)) AS total_size,
    min(min_time) AS data_start,
    max(max_time) AS data_end
FROM system.parts
WHERE active = 1
  AND database = 'ops_test'
GROUP BY database, table, partition
ORDER BY database, table, partition;

-- 6.4 更新表统计信息
-- 【场景】手动触发统计信息更新，帮助优化器生成更好的执行计划
-- 【原理】ANALYZE TABLE 会重新计算表的统计信息
-- 【坑】ClickHouse 的统计信息主要用于轻量级优化，效果不如传统数据库明显
--       大表 ANALYZE 可能耗时较长
-- ANALYZE TABLE ops_test.events;

-- ==========================================
-- 7. TTL 维护
-- ==========================================

-- 7.1 查看所有表的 TTL 设置
-- 【场景】检查各表的 TTL 配置，确保数据过期策略正确
-- 【原理】system.ttl_entries 存储了所有表的 TTL 定义
SELECT
    database,
    table,
    name AS column_name,
    min_bytes,
    max_bytes,
    formatReadableSize(min_bytes) AS min_size,
    formatReadableSize(max_bytes) AS max_size,
    rows
FROM system.ttl_entries
WHERE database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
ORDER BY database, table;

-- 7.2 为测试表添加 TTL 自动清理
-- 【场景】为表配置数据自动过期策略，减少手动维护工作量
-- 【原理】TTL TO DELETE 会在后台自动删除过期数据
-- 【坑】TTL 是异步操作，数据不会在过期瞬间立即删除
--       删除操作通过 Merge 任务执行，可能有延迟
ALTER TABLE ops_test.raw_logs
    MODIFY TTL log_time + INTERVAL 90 DAY TO DELETE;

-- 7.3 查看 TTL 删除的进度
-- 【场景】监控 TTL 后台删除任务的执行情况
SELECT
    database,
    table,
    mutation_id,
    command,
    create_time,
    parts_to_do,
    parts_done,
    is_done
FROM system.mutations
WHERE database = 'ops_test'
  AND command LIKE '%TTL%'
ORDER BY create_time DESC;

-- ==========================================
-- 8. 自动化维护脚本
-- ==========================================

-- 8.1 日常健康检查脚本模板
-- 【场景】每日自动执行的健康检查，输出结构化报告
-- 【原理】汇总各系统表的健康状态指标
SELECT
    now() AS check_time,
    host_name() AS node,
    (SELECT max(absolute_delay) FROM system.replicas) AS max_replica_delay,
    (SELECT min(free_space / total_space * 100) FROM system.disks) AS min_disk_free_pct,
    (SELECT count(*) FROM system.merges) AS active_merges,
    (SELECT count(*) FROM system.mutations WHERE is_done = 0) AS pending_mutations,
    (SELECT formatReadableSize(sum(bytes_on_disk))
     FROM system.parts
     WHERE active = 1
       AND database = 'ops_test') AS total_data_size,
    (SELECT count(*) FROM system.processes WHERE query != '') AS active_queries;

-- 8.2 周常碎片整理脚本模板
-- 【场景】每周自动识别碎片化严重的表并生成 OPTIMIZE 语句
-- 【原理】Part 数量超过阈值说明碎片化严重，需要合并
SELECT
    '-- Weekly OPTIMIZE Script - ' || toString(now()) AS comment,
    '' AS separator
UNION ALL
SELECT
    'OPTIMIZE TABLE ' || database || '.' || table ||
    ' ON CLUSTER \'treasurycluster\' FINAL;'
FROM system.parts
WHERE active = 1
  AND database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
  AND database = 'ops_test'
GROUP BY database, table
HAVING count() > 20;

-- 8.3 月常索引维护脚本模板
-- 【场景】每月检查并重建索引，确保索引效率
-- 【原理】通过 system.data_skipping_indices 检查索引状态
SELECT
    '-- Monthly Index Maintenance - ' || toString(now()) AS comment
UNION ALL
SELECT
    'ALTER TABLE ' || database || '.' || table ||
    ' MATERIALIZE INDEX ' || name || ';'
FROM system.data_skipping_indices
WHERE database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
  AND database = 'ops_test';

-- 8.4 系统表清理脚本模板（每周执行）
-- 【场景】定期清理系统表日志，防止系统表过度增长
-- 【原理】通过 ALTER TABLE DELETE 清理过期日志
/*
-- 清理 query_thread_log（保留 7 天）
ALTER TABLE system.query_thread_log ON CLUSTER 'treasurycluster'
    DELETE WHERE event_date < today() - 7;

-- 清理 text_log（保留 3 天）
ALTER TABLE system.text_log ON CLUSTER 'treasurycluster'
    DELETE WHERE event_date < today() - 3;

-- 清理 metric_log（保留 7 天）
ALTER TABLE system.metric_log ON CLUSTER 'treasurycluster'
    DELETE WHERE event_date < today() - 7;

-- 清理 trace_log（保留 3 天）
ALTER TABLE system.trace_log ON CLUSTER 'treasurycluster'
    DELETE WHERE event_date < today() - 3;
*/

-- 8.5 维护日志记录表
-- 【场景】记录每次维护操作的执行时间、内容和结果
-- 【原理】通过独立的维护日志表追踪所有维护操作
CREATE TABLE IF NOT EXISTS ops_test.maintenance_log (
    exec_time DateTime DEFAULT now(),
    task_type String,
    task_name String,
    target_table String,
    affected_rows UInt64,
    duration_ms UInt64,
    status String,
    message String
) ENGINE = MergeTree()
ORDER BY exec_time;

-- 记录当前维护操作（示例）
INSERT INTO ops_test.maintenance_log (task_type, task_name, target_table, status, message)
VALUES ('DAILY', 'health_check', 'ops_test.events', 'STARTED', 'Starting daily health check');

-- 查看维护历史
SELECT
    exec_time,
    task_type,
    task_name,
    target_table,
    affected_rows,
    duration_ms,
    status,
    message
FROM ops_test.maintenance_log
ORDER BY exec_time DESC
LIMIT 20;

-- ==========================================
-- 9. 应急维护操作
-- ==========================================

-- 9.1 查看卡住的 Mutation
-- 【场景】发现长时间未完成的 Mutation，排查原因并处理
-- 【原理】Mutation 卡住通常是由于副本不可用或资源竞争
-- 【坑】KILL MUTATION 会导致数据不一致，谨慎使用
--       建议先排查副本状态，再决定是否终止
SELECT
    database,
    table,
    mutation_id,
    command,
    create_time,
    parts_to_do,
    parts_done,
    is_done,
    latest_fail_time,
    latest_fail_reason
FROM system.mutations
WHERE is_done = 0
  AND now() - create_time > INTERVAL 1 HOUR
ORDER BY create_time;

-- 9.2 终止卡住的 Mutation（紧急操作）
-- 【场景】当 Mutation 阻塞了后续操作时，需要手动终止
-- 【坑】终止 Mutation 后，该操作的效果不确定，需要手动验证数据一致性
-- KILL MUTATION WHERE database = 'ops_test' AND table = 'events';

-- 9.3 查看被阻塞的查询
-- 【场景】发现查询长时间等待锁或其他资源
-- 【原理】system.processes 中的 elapsed 字段显示查询已执行时间
-- 【坑】长时间运行的查询不一定有问题，需要结合查询内容判断
SELECT
    query_id,
    user,
    substring(query, 1, 200) AS query,
    elapsed,
    formatReadableSize(memory_usage) AS memory_usage,
    formatReadableSize(read_rows) AS read_rows,
    formatReadableSize(read_bytes) AS read_bytes,
    is_cancelled
FROM system.processes
WHERE query != ''
  AND elapsed > 300  -- 超过 5 分钟
ORDER BY elapsed DESC;

-- 9.4 终止长时间运行的查询（紧急操作）
-- 【场景】当查询消耗过多资源影响其他查询时，需要手动终止
-- 【坑】终止查询后，事务性插入可能受影响
-- KILL QUERY WHERE query_id = 'example-query-id';

-- 9.5 查看副本同步延迟详情
-- 【场景】排查副本同步延迟的具体原因
-- 【原理】system.replicas 和 system.replication_queue 提供详细信息
SELECT
    database,
    table,
    replica_name,
    queue_size,
    absolute_delay,
    parts_to_delay,
    parts_to_merge,
    log_max_index,
    log_pointer,
    (log_max_index - log_pointer) AS pending_log_entries,
    is_readonly,
    is_session_expired
FROM system.replicas
WHERE absolute_delay > 0
   OR queue_size > 0
ORDER BY absolute_delay DESC;

-- 9.6 查看副本队列中的失败任务
-- 【场景】发现复制队列中反复失败的任务
-- 【原理】system.replication_queue 记录了复制任务的执行历史
-- 【坑】某些失败任务会自动重试，需要关注重试次数
SELECT
    database,
    table,
    replica_name,
    type,
    source_replica,
    parts_to_do,
    result_part_name,
    exception_text,
    num_tries,
    last_attempt_time,
    last_exception_time
FROM system.replication_queue
WHERE exception_code != 0
ORDER BY last_exception_time DESC
LIMIT 20;

-- ==========================================
-- 10. 维护最佳实践检查
-- ==========================================

-- 10.1 检查是否有长时间未合并的表
-- 【场景】发现后台合并可能被阻塞的表
-- 【原理】通过 system.parts 中 level=0 的 Part 数量判断
SELECT
    database,
    table,
    countIf(level = 0) AS unmerged_parts,
    countIf(level = 0 AND last_modified < now() - INTERVAL 1 DAY) AS stuck_parts,
    round(countIf(level = 0) / count() * 100, 1) AS unmerged_pct
FROM system.parts
WHERE active = 1
  AND database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
GROUP BY database, table
HAVING unmerged_parts > 20
ORDER BY unmerged_parts DESC;

-- 10.2 检查磁盘使用率趋势
-- 【场景】发现磁盘使用率增长过快的节点
-- 【原理】通过 system.disks 查看各磁盘使用情况
SELECT
    name,
    path,
    formatReadableSize(free_space) AS free_space,
    formatReadableSize(total_space) AS total_space,
    round((total_space - free_space) / total_space * 100, 1) AS used_percent,
    CASE
        WHEN (total_space - free_space) / total_space > 0.9 THEN 'CRITICAL - Immediate action needed'
        WHEN (total_space - free_space) / total_space > 0.8 THEN 'WARNING - Plan cleanup'
        WHEN (total_space - free_space) / total_space > 0.7 THEN 'INFO - Monitor'
        ELSE 'OK'
    END AS recommendation
FROM system.disks
ORDER BY used_percent DESC;

-- 10.3 检查是否有无效的 DDL 操作残留
-- 【场景】发现因各种原因未完成的 DDL 操作
SELECT
    database,
    table,
    mutation_id,
    command,
    create_time,
    is_done,
    latest_fail_time,
    latest_fail_reason
FROM system.mutations
WHERE is_done = 0
   AND database = 'ops_test'
ORDER BY create_time;

-- 10.4 维护任务清单
-- 【场景】日常维护操作的完整检查清单
/*
每日维护（耗时 5 分钟）:
  1. 健康检查 → 1.1 整体健康检查
  2. 错误日志 → 1.2 查看错误日志
  3. 慢查询分析 → 1.3 慢查询分析
  4. 磁盘使用率 → 10.2 磁盘检查

每周维护（耗时 15 分钟）:
  1. Part 碎片检查 → 2.1 碎片化分析
  2. 碎片整理（低峰期）→ 2.3 OPTIMIZE
  3. 过期数据清理 → 3.1 分区清理
  4. 系统表日志清理 → 8.4 系统表清理

每月维护（耗时 30 分钟）:
  1. 索引重建 → 5.4 MATERIALIZE INDEX
  2. Projection 维护 → 5.5 添加 Projection
  3. 数据分布检查 → 6.3 数据分布趋势
  4. 合并参数评估 → 2.6 查看合并参数
  5. 维护日志审计 → 8.5 维护日志

每季度维护（耗时 1 小时）:
  1. 全量备份验证
  2. 版本升级评估
  3. 容量规划评审
  4. 存储策略优化
*/

-- ==========================================
-- 清理
-- ==========================================
DROP TABLE IF EXISTS ops_test.events;
DROP TABLE IF EXISTS ops_test.raw_logs;
DROP TABLE IF EXISTS ops_test.staging_data;
DROP TABLE IF EXISTS ops_test.maintenance_log;
DROP DATABASE IF EXISTS ops_test;