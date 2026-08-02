-- ============================================================
-- 文件: 16-principle/01_overview.sql
-- 学习目标: 建立 ClickHouse 整体架构的全局观，会用 EXPLAIN 诊断查询
-- 深度标准: 原理 + 场景 + 对比 + 可运行
-- 集群: treasurycluster (CH 25.12.1.649, 2 副本 × 1 分片, 3 Keeper)
-- 前置: 无（自包含测试数据，按顺序执行）
-- ============================================================
--
-- 本文件章节:
--   1. ClickHouse 架构分层（Client / Server / Storage / Keeper）
--   2. 创建演示数据（先建表, 后续 EXPLAIN/查询才能引用）
--   3. 查询处理管道（Parser → Interpreter → Pipeline, 含 EXPLAIN 三种用法）
--   4. 表引擎家族分类（MergeTree 是核心）
--   5. 函数体系分类（标量 / 聚合 / 窗口）
--   6. 执行聚合查询并观察性能
--   7. 查询日志解读（read_rows / read_bytes / memory_usage）
--   8. 存储结构观察（Parts 与列压缩）
--   9. 分布式架构信息（treasurycluster 拓扑）
--   10. 后台任务与合并
--   11. 内存与缓存（PageCache / MarkCache / UncompressedCache）
--   12. 清理
--
-- 关联文档: README.md §2 整体架构 / §3.5 查询执行管道
-- ============================================================

CREATE DATABASE IF NOT EXISTS tutorial;
USE tutorial;

-- ============================================================
-- 1. ClickHouse 架构分层
-- ============================================================
-- 【原理】ClickHouse 分四层:
--   ① Client Layer: HTTP(8123)/Native TCP(9000)/CLI/JDBC/ODBC, 多协议接入
--   ② Server Core: Parser(词法语法→AST) → Interpreter/Analyzer(AST→Plan) → Pipeline(Plan→执行)
--   ③ Storage Engine: MergeTree 家族(主) + Log/Buffer/Memory/Distributed/Kafka 等
--   ④ Coordination: Keeper (Raft 共识, 替代 ZooKeeper), 管复制日志/选主/元数据
-- 【场景】理解分层后能定位问题: 连不上=Client层, 解析错=Parser, 慢=Pipeline, 副本滞后=Keeper
-- 【对比】vs MySQL: MySQL 有成本模型优化器, CH 是规则优化; MySQL 用 B+Tree, CH 用稀疏索引
-- 【坑】25.x 默认启用 analyzer, 某些旧 SQL 写法在新 analyzer 下行为不同, 见 12_analyzer 章节

-- 1.1 查看 ClickHouse 版本与构建信息
-- 【结果解读】25.12.1.649 表示 25 年 12 月版本, build_id 用于报 bug
SELECT
    version() AS clickhouse_version,
    timezone() AS server_timezone,
    uptime() AS uptime_seconds;

-- 1.2 查看编译选项 —— 关注 SIMD 支持情况
-- 【原理】HAVE_EMBEDDED_COMPILER=1 表示可运行时编译表达式(进一步加速)
-- 【结果解读】看是否有 AVX2/AVX-512, 决定向量化能处理几位数据
SELECT
    name,
    value
FROM system.build_options
WHERE name IN ('VERSION_INTEGER', 'VERSION_SCM', 'BUILD_TYPE', 'BUILD_OPTIONS')
ORDER BY name;

-- 1.3 查看关键全局设置
-- 【原理】max_threads 默认=CPU 核数; max_memory_usage 默认 10GB(单查询);
--        max_execution_time 默认 0=无限
-- 【场景】慢查询根因常是 max_threads 太小或 max_memory_usage 太低
SELECT
    name,
    value,
    changed,
    description
FROM system.settings
WHERE name IN ('max_threads', 'max_memory_usage', 'max_execution_time',
               'max_insert_block_size', 'optimize_move_to_prewhere')
ORDER BY name;

-- ============================================================
-- 2. 创建演示数据 (先建表, 后续 EXPLAIN/查询才能引用)
-- ============================================================
-- 【原理】用 numbers(N) 表函数生成 N 行, 配合数组下标实现随机分类
-- 【场景】快速生成测试数据验证 SQL, 不需要外部数据源
DROP TABLE IF EXISTS tutorial.pipeline_demo;

CREATE TABLE tutorial.pipeline_demo (
    id UInt64,
    user_id UInt32,
    event_type LowCardinality(String),  -- 【最佳实践】低基数字符串用 LowCardinality 省 5-10× 存储
    event_date Date,
    value Float64,
    created_at DateTime DEFAULT now()
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_date)
ORDER BY (event_date, user_id)
SETTINGS index_granularity = 8192;  -- 默认值, 显式写出便于教学

INSERT INTO tutorial.pipeline_demo
SELECT
    number AS id,
    number % 10000 AS user_id,
    ['click', 'view', 'purchase', 'login'][number % 4 + 1] AS event_type,
    toDate('2024-01-01') + (number % 365) AS event_date,
    rand() / 100.0 AS value,
    now() - INTERVAL (number % 1000) MINUTE AS created_at
FROM numbers(100000);

-- ============================================================
-- 3. 查询处理管道: Parser → Interpreter → Pipeline
-- ============================================================
-- 【原理】SQL 处理三阶段:
--   ① Parser: 词法+语法解析 → AST (抽象语法树)
--   ② Interpreter/Analyzer: AST → 逻辑计划 + 优化(谓词下推/列裁剪/常量折叠)
--   ③ Pipeline: 逻辑计划 → 物理执行图 (Pull 模型, 下游拉上游)
-- 【对比】EXPLAIN PLAN 看逻辑计划, EXPLAIN PIPELINE 看物理管道, EXPLAIN ESTIMATE 看成本估算

-- 3.1 EXPLAIN PLAN —— 看逻辑执行计划
-- 【结果解读】从下到上读: Reading → Filter → Aggregating → Sorting → Limit
EXPLAIN PLAN
SELECT
    event_date,
    count() AS event_count,
    uniqExact(user_id) AS unique_users,
    sum(value) AS total_value
FROM tutorial.pipeline_demo
WHERE event_date >= '2024-01-01' AND event_date < '2024-02-01'
GROUP BY event_date
ORDER BY event_date
LIMIT 10;

-- 3.2 EXPLAIN PIPELINE —— 看物理执行管道(线程级)
-- 【原理】Pull 模型: Source → Filter → Aggregate → Sink
-- 【结果解读】看到 "Threads" 表示并行度, "Aggregating" 后跟着合并步骤
EXPLAIN PIPELINE
SELECT count() FROM tutorial.pipeline_demo
WHERE event_type = 'purchase';

-- 3.3 EXPLAIN ESTIMATE —— 估算查询成本
-- 【结果解读】parts=扫描的 Part 数, rows=预计行数, bytes=预计字节数
EXPLAIN ESTIMATE
SELECT count() FROM tutorial.pipeline_demo
WHERE user_id = 123;

-- ============================================================
-- 4. 表引擎家族分类
-- ============================================================
-- 【原理】MergeTree 家族是核心, 其他引擎(Log/Buffer/Memory/Integration)是辅助
-- 【场景】90% 的表用 MergeTree 家族; 临时表用 Memory; 摄入用 Kafka; 跨集群用 Distributed
-- 【对比】MergeTree vs ReplacingMergeTree vs SummingMergeTree vs AggregatingMergeTree
--        详见 03_mergetree.sql §6 和 03-engines/01_mergetree_engines.sql

SELECT
    name AS engine_name,
    multiIf(
        name LIKE '%MergeTree%', 'MergeTree 家族 (核心)',
        name LIKE '%Log%', 'Log 系列 (小数据临时)',
        name LIKE '%Distributed%', 'Distributed (分布式路由)',
        name LIKE '%Memory%', 'Memory (内存表)',
        name LIKE '%Buffer%', 'Buffer (写入缓冲)',
        name LIKE '%Kafka%', 'Kafka (消息摄入)',
        name LIKE '%File%', 'File (文件)',
        name LIKE '%URL%', 'URL (HTTP 拉取)',
        name LIKE '%JDBC%', 'JDBC (外部数据库)',
        '其他'
    ) AS engine_category
FROM system.table_engines
WHERE name NOT LIKE '%Old%'
ORDER BY engine_category, name;

-- ============================================================
-- 5. 函数体系分类
-- ============================================================
-- 【原理】函数分三类:
--   ① 标量函数: 一行进一行出, 任意位置可用
--   ② 聚合函数: 多行进一行出, 配合 GROUP BY
--   ③ 窗口函数: 多行进一行出, 但不折叠行数 (OVER 子句)
-- 详见 04-functions/README.md
SELECT
    if(is_aggregate = 1, '聚合函数', '标量/窗口函数') AS function_type,
    count() AS function_count
FROM system.functions
GROUP BY function_type
ORDER BY function_type;

-- ============================================================
-- 6. 执行聚合查询并观察性能
-- ============================================================
-- 【原理】聚合走两阶段: 各线程本地聚合 → 合并
-- 【结果解读】event_count 应=25000 (100000/4)
SELECT
    event_type,
    count() AS event_count,
    uniqExact(user_id) AS unique_users,
    round(sum(value), 2) AS total_value,
    round(avg(value), 2) AS avg_value
FROM tutorial.pipeline_demo
GROUP BY event_type
ORDER BY event_count DESC;

-- ============================================================
-- 7. 查询日志解读
-- ============================================================
-- 【原理】system.query_log 记录每条查询的完整执行信息, 性能诊断核心表
-- 【场景】慢查询排查: WHERE query_duration_ms > 1000
-- 【坑】
--   - query_log 是异步写入, 刚执行的查询可能要等 1-2 秒才出现
--   - system.query_log 需在 config.xml 启用 <query_log>(本测试环境已用
--     <query_log remove="1"/> 禁用以省 CPU)。此处用 system.query_thread_log
--     替代(需 SET log_query_threads = 1)，生产环境建议开启 query_log
SET log_query_threads = 1;

-- 触发一条查询以便被记录
SELECT count(), avg(value) FROM tutorial.pipeline_demo WHERE event_type = 'click';

SELECT
    query,
    read_rows,
    formatReadableSize(read_bytes) AS read_bytes,
    query_duration_ms,
    formatReadableSize(peak_memory_usage) AS peak_memory
FROM system.query_thread_log
WHERE positionCaseInsensitive(query, 'pipeline_demo') > 0
  AND is_initial_query = 1
ORDER BY event_time DESC
LIMIT 5;

-- ============================================================
-- 8. 存储结构观察
-- ============================================================
-- 8.1 查看 Parts —— 每行是一个数据块
-- 【结果解读】partition=202401 等, level 越大合并次数越多
SELECT
    partition,
    name AS part_name,
    rows,
    formatReadableSize(bytes) AS size_on_disk,
    formatReadableSize(primary_key_bytes_in_memory) AS pk_in_memory,
    level,
    active
FROM system.parts
WHERE database = 'tutorial' AND table = 'pipeline_demo' AND active = 1
ORDER BY partition, name;

-- 8.2 查看列压缩效果 —— 列式存储核心优势
-- 【原理】同列同类型 → 压缩率高; value 列随机数压缩率低, event_type 列 LowCardinality 压缩率高
-- 【结果解读】ratio 列 = uncompressed/compressed, LowCardinality 列应 > 10×
SELECT
    column,
    formatReadableSize(sum(column_data_compressed_bytes)) AS compressed,
    formatReadableSize(sum(column_data_uncompressed_bytes)) AS uncompressed,
    round(sum(column_data_uncompressed_bytes) / sum(column_data_compressed_bytes), 1) AS ratio
FROM system.parts_columns
WHERE database = 'tutorial' AND table = 'pipeline_demo' AND active = 1
GROUP BY column
ORDER BY ratio DESC;

-- ============================================================
-- 9. 分布式架构信息
-- ============================================================
-- 【原理】treasurycluster = 1 分片 × 2 副本, 3 Keeper 协调
-- 【结果解读】shard_num=1 都在分片1, replica_num 1/2 是两个副本
SELECT
    cluster,
    shard_num,
    replica_num,
    host_name,
    host_address,
    port,
    is_local
FROM system.clusters
WHERE cluster = 'treasurycluster'
ORDER BY cluster, shard_num, replica_num;

-- ============================================================
-- 10. 后台任务与合并
-- ============================================================
-- 10.1 查看当前合并任务
-- 【场景】大量写入后查看合并进度; progress<1 表示合并未完成
SELECT
    database,
    table,
    elapsed,
    progress,
    num_parts,
    result_part_name,
    formatReadableSize(total_size_bytes_compressed) AS total_size
FROM system.merges
LIMIT 5;

-- 10.2 查看后台指标
-- 【原理】BackgroundMergesAndMutationsPool 是合并/mutation 线程池
SELECT
    name,
    value,
    description
FROM system.asynchronous_metrics
WHERE name LIKE '%Background%' OR name LIKE '%Merge%'
LIMIT 10;

-- 10.3 查看 MergeTree 关键设置
SELECT
    name,
    value,
    description
FROM system.merge_tree_settings
WHERE name IN ('max_parts_to_merge_at_once', 'merge_with_ttl_timeout',
               'min_bytes_for_wide_part', 'min_rows_for_wide_part',
               'parts_to_delay_insert', 'parts_to_throw_insert')
ORDER BY name;

-- ============================================================
-- 11. 内存与缓存
-- ============================================================
-- 【原理】三类缓存:
--   ① PageCache: OS 文件系统页缓存, 缓存 .bin 文件
--   ② MarkCache: CH 内部缓存, 缓存 .mrk2 mark 文件 (避免重复读索引)
--   ③ UncompressedCache: CH 内部缓存, 缓存解压后的数据块
-- 【场景】缓存命中率低 → 加大 cache size; 内存压力大 → 减小

-- 11.1 内存使用概览
SELECT
    metric,
    formatReadableSize(value) AS value
FROM system.metrics
WHERE metric LIKE '%Memory%'
ORDER BY metric;

-- 11.2 缓存指标
SELECT
    name,
    value,
    description
FROM system.asynchronous_metrics
WHERE name LIKE '%Cache%' OR name LIKE '%MarkCache%' OR name LIKE '%Uncompressed%'
ORDER BY name
LIMIT 15;

-- ============================================================
-- 12. 清理
-- ============================================================
DROP TABLE IF EXISTS tutorial.pipeline_demo;

-- =====================================================
-- 本章小结
-- =====================================================
-- 1. ClickHouse 分四层: Client / Server(Parser+Interpreter+Pipeline) / Storage / Keeper
-- 2. EXPLAIN 三种用法: PLAN(逻辑) / PIPELINE(物理) / ESTIMATE(成本估算)
-- 3. MergeTree 是核心引擎, 其他引擎是辅助
-- 4. 函数分三类: 标量/聚合/窗口
-- 5. system.query_log(需 config 启用)/query_thread_log 是性能诊断核心表
-- 6. 三类缓存: PageCache(OS) / MarkCache / UncompressedCache
--
-- 下一步: 02_column_store.sql - 深入列式存储原理
-- =====================================================
