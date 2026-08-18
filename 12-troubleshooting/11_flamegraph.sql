-- =====================================================
-- 11 - 火焰图与性能诊断
-- =====================================================
-- 集群: treasurycluster (2副本)
-- 时间: 15-20分钟
-- =====================================================

-- -----------------------------------------------------
-- 准备环境
-- -----------------------------------------------------

DROP DATABASE IF EXISTS troubleshooting_test;
CREATE DATABASE troubleshooting_test;
USE troubleshooting_test;

-- -----------------------------------------------------
-- 1. trace_log 与系统表
-- -----------------------------------------------------

--
-- 【原理】ClickHouse 内置了系统级的性能诊断工具，主要通过 system.trace_log
-- 和 system.query_profiler 实现。trace_log 记录了查询执行时的详细追踪信息，
-- 包括 CPU 时间、内存分配、锁等待、IO 操作等。火焰图通过采样（sampling）
-- 获取函数调用栈的快照，可视化展示 CPU 时间在不同函数间的分布，帮助定位
-- 性能瓶颈。
--
-- 关键系统表:
--   system.trace_log:        CPU 采样和内存分配追踪
--   system.query_log:        查询级别日志（含性能指标）
--   system.query_thread_log: 线程级别执行日志
--   system.query_views_log:  物化视图执行日志
--   system.processes:        当前正在执行的查询
--   system.asynchronous_metrics: 异步采集的系统指标
--   system.metrics:          实时指标
--   system.events:           累计事件计数器
--
-- 【对比】
--   - v20.x: 基础 trace_log，仅支持 CPU 采样
--   - v21.x: 新增 query_thread_log，支持内存采样
--   - v22.x: 新增 trace_log 的多种 trace_type
--   - v23.x: 支持增量采样、自定义采样间隔
--   - v24.x: 支持实时查询分析、自动采样控制
--

-- 诊断：检查 trace_log 是否启用
SELECT
    name,
    value,
    description
FROM system.settings
WHERE name IN (
    'query_profiler_cpu_time_period_ns',
    'query_profiler_real_time_period_ns',
    'memory_profiler_step',
    'trace_profile_events',
    'opentelemetry_start_trace_probability'
);

-- 诊断：查看 trace_log 表结构
-- 【坑】演示集群未在 config.xml 启用 <trace_log>，故 system.trace_log 表不存在。
--       启用方法（config.xml 添加 <trace_log> 配置段并重启）：
--         <trace_log>
--             <database>system</database>
--             <table>trace_log</table>
--             <flush_interval_milliseconds>7500</flush_interval_milliseconds>
--         </trace_log>
--       本环境改用 system.query_thread_log 做线程级诊断（已启用）：
SELECT
    name,
    type,
    comment
FROM system.columns
WHERE database = 'system'
  AND table = 'query_thread_log'
ORDER BY position
LIMIT 10;

-- 诊断：查看 query_thread_log 中的线程执行数据（替代 trace_log）
-- 【说明】trace_log 记录 CPU/内存采样的调用栈；query_thread_log 记录每个查询线程的
--         执行耗时、读写行数、内存峰值，可用于定位"哪个查询哪个线程慢"
SELECT
    query_id,
    thread_name,
    query_duration_ms,
    read_rows,
    read_bytes,
    peak_memory_usage
FROM system.query_thread_log
WHERE event_time > now() - INTERVAL 1 DAY
ORDER BY query_duration_ms DESC
LIMIT 10;

-- 【说明】trace_log 中的采样数据查询（CPU/MemorySample）在启用 <trace_log> 后可用：
-- SELECT trace_type, count() AS sample_count, min(timestamp) AS first_sample, max(timestamp) AS last_sample
-- FROM system.trace_log
-- WHERE event_time > now() - INTERVAL 1 HOUR
-- GROUP BY trace_type ORDER BY sample_count DESC;
--
-- 【说明】内存分配追踪（MemorySample）：
-- SELECT arrayStringConcat(arrayMap(x -> demangle(addressToSymbol(x)), trace), '; ') AS stack_trace,
--        size, count() AS allocation_count
-- FROM system.trace_log
-- WHERE trace_type = 'MemorySample' AND event_time > now() - INTERVAL 1 HOUR
-- GROUP BY trace, size ORDER BY size DESC LIMIT 20;
--
-- 【说明】CPU 采样热点（trace_type = 'CPU'）：
-- SELECT arrayStringConcat(arrayMap(x -> demangle(addressToSymbol(x)), trace), '; ') AS stack_trace,
--        count() AS sample_count
-- FROM system.trace_log
-- WHERE trace_type = 'CPU' AND event_time > now() - INTERVAL 1 HOUR
-- GROUP BY trace ORDER BY sample_count DESC LIMIT 20;

-- -----------------------------------------------------
-- 2. query_profiler 配置
-- -----------------------------------------------------

--
-- 【原理】query_profiler 是 ClickHouse 的实时采样分析器，通过定时采样线程
-- 的堆栈信息来生成性能分析数据。采样间隔由 query_profiler_cpu_time_period_ns
-- （CPU 时间采样间隔）和 query_profiler_real_time_period_ns（实际时间采样
-- 间隔）控制。默认值为 10000000ns（10ms），采样频率 100Hz。
--
-- 采样类型:
--   CPU:       只统计 CPU 正在执行的时间
--   Real:      统计实际经过的时间（含 IO 等待）
--   Memory:    统计内存分配调用栈
--   Network:   统计网络传输调用栈
--
-- 配置建议:
--   生产环境: 100ms 间隔（10Hz），性能开销 < 1%
--   诊断模式: 1ms 间隔（1000Hz），性能开销 ~5%
--   开发环境: 0.1ms 间隔（10000Hz），性能开销 ~20%
--

-- 诊断：查看当前分析器配置
SELECT
    name,
    value,
    changed,
    description
FROM system.settings
WHERE name LIKE '%profiler%'
   OR name LIKE '%profiler%'
ORDER BY name;

-- 修复：启用实时分析器（每秒采样 100 次）
SET query_profiler_cpu_time_period_ns = 10000000;   -- 10ms
SET query_profiler_real_time_period_ns = 10000000;  -- 10ms

-- 修复：启用内存分析器
SET memory_profiler_step = 4194304;  -- 每 4MB 采样一次

-- 修复：启用详细追踪事件
SET trace_profile_events = 1;

-- 修复：为特定查询启用分析器
-- 在查询前设置:
-- SET query_profiler_cpu_time_period_ns = 1000000;  -- 1ms 高精度采样
-- SELECT ...  -- 慢查询

-- 修复：查询完成后查看分析结果
-- 【坑】演示集群禁用了 system.query_log，改用 system.query_thread_log
--       （线程级日志，含 read_rows/read_bytes/peak_memory_usage 等指标）
SELECT
    query_id,
    query,
    query_duration_ms,
    read_rows,
    read_bytes,
    written_rows,
    peak_memory_usage
FROM system.query_thread_log
WHERE event_time > now() - INTERVAL 1 DAY
  AND query_duration_ms > 1000
ORDER BY query_duration_ms DESC
LIMIT 20;

-- -----------------------------------------------------
-- 3. 采样与分析
-- -----------------------------------------------------

--
-- 【原理】采样分析是通过定期收集系统状态来推断性能瓶颈的方法。ClickHouse
-- 的采样分析包括：CPU 采样（分析 CPU 热点）、内存采样（分析内存分配热点）、
-- 锁采样（分析锁竞争）、IO 采样（分析 IO 等待）。采样数据存储在 trace_log
-- 中，可以通过 demangle 函数将地址转换为函数名。
--
-- 采样分析流程:
--   1. 启用采样（设置采样间隔）
--   2. 执行目标查询
--   3. 从 trace_log 提取采样数据
--   4. 使用 demangle 解析函数名
--   5. 生成火焰图或分析报告
--

-- 诊断：使用 demangle 解析堆栈
-- 【坑】依赖 system.trace_log（本环境未启用），以下查询在启用 <trace_log> 后可用：
-- SELECT
--     arrayStringConcat(arrayMap(x -> demangle(addressToSymbol(x)), trace), '; ') AS readable_stack,
--     count() AS samples
-- FROM system.trace_log
-- WHERE trace_type = 'CPU' AND event_time > now() - INTERVAL 1 HOUR
-- GROUP BY trace ORDER BY samples DESC LIMIT 30;

-- 诊断：分析特定函数的调用频率（启用 <trace_log> 后可用）
-- SELECT
--     demangle(addressToSymbol(trace[1])) AS top_function,
--     count() AS call_count
-- FROM system.trace_log
-- WHERE trace_type = 'CPU' AND event_time > now() - INTERVAL 1 HOUR
-- GROUP BY top_function ORDER BY call_count DESC LIMIT 20;

-- 诊断：分析 MergeTree 读取热点（启用 <trace_log> 后可用）
-- SELECT
--     demangle(addressToSymbol(trace[1])) AS top_function,
--     count() AS samples
-- FROM system.trace_log
-- WHERE trace_type = 'CPU' AND event_time > now() - INTERVAL 1 HOUR
--   AND arrayExists(x -> addressToSymbol(x) LIKE '%MergeTree%', trace)
-- GROUP BY top_function ORDER BY samples DESC LIMIT 20;

-- 诊断：分析内存分配热点（启用 <trace_log> 后可用）
-- SELECT
--     demangle(addressToSymbol(trace[1])) AS top_function,
--     sum(size) AS total_bytes,
--     formatReadableSize(sum(size)) AS total_readable,
--     count() AS allocation_count
-- FROM system.trace_log
-- WHERE trace_type = 'MemorySample' AND event_time > now() - INTERVAL 1 HOUR
-- GROUP BY top_function ORDER BY total_bytes DESC LIMIT 20;

-- 修复：生成火焰图数据
-- 在 shell 中执行:
-- 1. 导出采样数据
--    clickhouse-client --query "
--        SELECT arrayStringConcat(arrayMap(x -> demangle(addressToSymbol(x)), trace), ';')
--        FROM system.trace_log
--        WHERE trace_type = 'CPU'
--          AND event_time > now() - INTERVAL 1 HOUR
--        FORMAT TabSeparated
--    " > /tmp/traces.txt
--
-- 2. 使用 FlameGraph 工具生成 SVG
--    git clone https://github.com/brendangregg/FlameGraph
--    cd FlameGraph
--    ./stackcollapse.pl /tmp/traces.txt > /tmp/traces.folded
--    ./flamegraph.pl /tmp/traces.folded > /tmp/flamegraph.svg

-- 修复：使用内置的 SYSTEM 命令进行性能分析
-- 以下命令在 clickhouse-client 中执行:
-- 1. 启用实时追踪
--    SET query_profiler_cpu_time_period_ns = 10000000;
--
-- 2. 启用内存追踪
--    SET memory_profiler_step = 4194304;
--
-- 3. 执行查询
--    SELECT count() FROM large_table WHERE condition;
--
-- 4. 查看分析结果
--    SELECT
--        arrayStringConcat(arrayMap(x -> demangle(addressToSymbol(x)), trace), ' -> ') AS stack,
--        count() AS samples
--    FROM system.trace_log
--    WHERE trace_type = 'CPU'
--      AND event_time > now() - INTERVAL 5 MINUTE
--    GROUP BY trace
--    ORDER BY samples DESC
--    LIMIT 50;

-- -----------------------------------------------------
-- 4. 高级性能诊断
-- -----------------------------------------------------

--
-- 【原理】除了火焰图，ClickHouse 还提供了多种高级性能诊断工具，包括：
-- 查询计划分析（EXPLAIN）、异步指标监控（system.asynchronous_metrics）、
-- 详细事件计数（system.events）、查询分析（system.query_log）、
-- 线程状态分析（system.query_thread_log）等。
--

-- 诊断：使用 EXPLAIN 分析查询计划
EXPLAIN PIPELINE
SELECT count()
FROM system.tables
WHERE database = 'system';

-- 诊断：查看查询级别的详细事件
-- 【坑】演示集群 config.xml 禁用了 system.query_log（<query_log remove="1"/>），
--       改用 system.query_thread_log（线程级，含 read_rows/read_bytes/peak_memory_usage）
SELECT
    query_id,
    query,
    query_duration_ms,
    read_rows,
    read_bytes,
    written_rows,
    peak_memory_usage
FROM system.query_thread_log
WHERE event_time > now() - INTERVAL 1 DAY
  AND query_duration_ms > 1000
ORDER BY query_duration_ms DESC
LIMIT 20;

-- 诊断：查看异步指标中的系统负载
-- 【坑】system.asynchronous_metrics 用 metric 列（name 是别名），指标名不带单位后缀
SELECT
    metric,
    value,
    description
FROM system.asynchronous_metrics
WHERE metric IN (
    'LoadAverage1',
    'LoadAverage5',
    'LoadAverage15',
    'OSUserTimeNormalized',
    'OSSystemTimeNormalized',
    'OSMemoryAvailable',
    'MemoryResident'
)
ORDER BY metric;

-- 诊断：分析线程池使用情况
SELECT
    metric,
    value,
    description
FROM system.metrics
WHERE metric LIKE '%Thread%'
   OR metric LIKE '%Pool%'
ORDER BY metric;

-- 诊断：查看后台任务状态
-- 【坑】system.merges 没有 create_time 列，改用 elapsed 表示合并已进行时间
SELECT
    database,
    table,
    count() AS merge_count,
    sum(rows_read) AS total_rows_read,
    sum(rows_written) AS total_rows_written,
    max(elapsed) AS longest_running_seconds
FROM system.merges
WHERE database NOT IN ('system')
GROUP BY database, table
ORDER BY merge_count DESC;

-- 修复：使用采样优化查询
-- 对于大表，可以使用采样来快速评估数据分布:
-- 【坑】SAMPLE BY 列必须出现在 ORDER BY/主键中（报 BAD_ARGUMENTS 即此原因），
--       这里把 user_id 加入 ORDER BY 作为采样键
DROP TABLE IF EXISTS troubleshooting_test.sample_table;
CREATE TABLE troubleshooting_test.sample_table
(
    user_id UInt32,
    event_time DateTime
) ENGINE = MergeTree()
ORDER BY (event_time, user_id)
SAMPLE BY user_id;

INSERT INTO troubleshooting_test.sample_table
SELECT number % 100000, toDateTime('2024-01-01') + number
FROM numbers(1000000);

SELECT
    count() AS total_rows_estimate,
    uniqCombined(user_id) AS approx_users
FROM troubleshooting_test.sample_table
SAMPLE 0.1;  -- 10% 采样

-- 修复：使用 PREWHERE 优化过滤
-- 将过滤条件中高效的列提前
-- SELECT ... FROM table PREWHERE high_selectivity_column = 'value' WHERE other_condition

-- 修复：使用物化视图预计算
-- 创建物化视图将高频查询结果预计算
-- CREATE MATERIALIZED VIEW agg_mv
-- ENGINE = AggregatingMergeTree()
-- ORDER BY (date, category)
-- AS SELECT
--     toDate(event_time) AS date,
--     category,
--     countState() AS cnt,
--     sumState(amount) AS total
-- FROM source_table
-- GROUP BY date, category;

-- 修复：使用 Projection 加速查询
-- ALTER TABLE troubleshooting_test.sample_table
--     ADD PROJECTION agg_projection
--     (
--         SELECT
--             date,
--             category,
--             count(),
--             sum(amount)
--         GROUP BY date, category
--     );

-- 修复：使用 MATERIALIZE PROJECTION 构建投影
-- ALTER TABLE troubleshooting_test.sample_table
--     MATERIALIZE PROJECTION agg_projection;

-- -----------------------------------------------------
-- 清理测试环境
-- -----------------------------------------------------

DROP DATABASE IF EXISTS troubleshooting_test;

-- =====================================================
-- 附：火焰图与性能诊断速查表
-- =====================================================
--
-- 诊断目标                | 诊断命令                  | 工具/方法
-- ------------------------|---------------------------|---------------------------
-- CPU 热点                | system.trace_log (CPU)    | FlameGraph 火焰图
-- 内存分配热点            | system.trace_log (Memory) | 分析 allocation stack
-- 查询性能瓶颈            | EXPLAIN PIPELINE          | 查询计划分析
-- 系统负载                | system.asynchronous_metrics | 监控 CPU/内存/IO/网络
-- 线程池状态              | system.metrics (Thread)   | 调整线程池配置
-- 合并任务积压            | system.merges             | 优化合并策略
-- 查询事件分析            | system.query_log (ProfileEvents) | 详细事件对比
-- 采样优化                | SELECT ... SAMPLE         | 近似查询加速
-- 预计算加速              | 物化视图 / Projection     | 空间换时间
--
-- =====================================================