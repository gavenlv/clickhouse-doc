-- =====================================================
-- 01 - ClickHouse 架构概览
-- =====================================================
-- 本文件帮助你理解 ClickHouse 的整体架构和核心组件
-- 适合想深入了解 ClickHouse 内部原理的开发者
-- =====================================================

-- -----------------------------------------------------
-- 1. ClickHouse 整体架构图解
-- -----------------------------------------------------
-- 
-- ┌─────────────────────────────────────────────────────────────┐
-- │                 ClickHouse 架构                              │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                              │
-- │  ┌─────────────────────────────────────────────────────┐   │
-- │  │                   Client Layer                       │   │
-- │  │  ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌────────┐ │   │
-- │  │  │ HTTP    │  │ Native  │  │  CLI    │  │ ODBC/  │ │   │
-- │  │  │ Client  │  │ TCP     │  │ Client  │  │ JDBC   │ │   │
-- │  │  └────┬────┘  └────┬────┘  └────┬────┘  └───┬────┘ │   │
-- │  └───────┼────────────┼────────────┼───────────┼──────┘   │
-- │          │             │            │           │          │
-- │          └─────────────┼────────────┼───────────┘          │
-- │                        ▼            ▼                        │
-- │  ┌─────────────────────────────────────────────────────┐   │
-- │  │               Server Core                            │   │
-- │  │  ┌─────────────────────────────────────────────┐   │   │
-- │  │  │              Query Pipeline                   │   │   │
-- │  │  │                                             │   │   │
-- │  │  │  Parser ──► Interpreter ──► Handler        │   │   │
-- │  │  │     │              │              │          │   │   │
-- │  │  │     ▼              ▼              ▼          │   │   │
-- │  │  │  ┌────────────────────────────────────────┐ │   │   │
-- │  │  │  │        Execution Pipeline               │ │   │   │
-- │  │  │  │  ┌─────┐ ┌─────┐ ┌─────┐ ┌─────┐    │ │   │   │
-- │  │  │  │  │Read │ │Filtr│ │Aggr │ │Sort │    │ │   │   │
-- │  │  │  │  │ Data│ │e    │ │e    │ │     │    │ │   │   │
-- │  │  │  │  └──┬──┘ └──┬──┘ └──┬──┘ └──┬──┘    │ │   │   │
-- │  │  │  │     └────────┴───────┴───────┘        │ │   │   │
-- │  │  │  └────────────────────────────────────────┘ │   │   │
-- │  │  └─────────────────────────────────────────────┘   │   │
-- │  │                         │                           │   │
-- │  └─────────────────────────┼───────────────────────────┘   │
-- │                            ▼                               │
-- │  ┌─────────────────────────────────────────────────────┐   │
-- │  │              Storage Engine Layer                    │   │
-- │  │  ┌─────────────┐ ┌─────────────┐ ┌─────────────┐  │   │
-- │  │  │ MergeTree   │ │ Distributed │ │  Memory    │  │   │
-- │  │  │   Family    │ │             │ │             │  │   │
-- │  │  └─────────────┘ └─────────────┘ └─────────────┘  │   │
-- │  └─────────────────────────────────────────────────────┘   │
-- │                                                              │
-- └─────────────────────────────────────────────────────────────┘

-- -----------------------------------------------------
-- 1.1 ClickHouse 查询处理管道
-- -----------------------------------------------------
--
-- 查询执行流程详解:
--
-- ┌─────────────────────────────────────────────────────────────┐
-- │              ClickHouse 查询处理管道                          │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                              │
-- │  1. Parser (解析)                                            │
-- │     ┌─────────────────────────────────────────────────────┐ │
-- │     │  SQL Text ──► AST (抽象语法树)                      │ │
-- │     │  SELECT * FROM users WHERE id = 1                   │ │
-- │     │        ▼                                            │ │
-- │     │  SelectQuery                                         │ │
-- │     │  ├── From: users                                    │ │
-- │     │  ├── Where: id = 1                                  │ │
-- │     │  └── ...                                            │ │
-- │     └─────────────────────────────────────────────────────┘ │
-- │                            │                                 │
-- │                            ▼                                 │
-- │  2. Interpreter (解释)                                       │
-- │     ┌─────────────────────────────────────────────────────┐ │
-- │     │  AST ──► QueryPlan (查询计划)                        │ │
-- │     │        ▼                                            │ │
-- │     │  ┌─────────────────────────────────────────────┐     │ │
-- │     │  │  谓词下推 (Predicate Pushdown)              │     │ │
-- │     │  │  列裁剪 (Column Pruning)                    │     │ │
-- │     │  │  表达式优化 (Expression Optimization)       │     │ │
-- │     │  └─────────────────────────────────────────────┘     │ │
-- │     └─────────────────────────────────────────────────────┘ │
-- │                            │                                 │
-- │                            ▼                                 │
-- │  3. Execution (执行)                                         │
-- │     ┌─────────────────────────────────────────────────────┐ │
-- │     │  Pipeline ──► 并行执行                              │ │
-- │     │  ┌─────────────────────────────────────────────┐   │ │
-- │     │  │  Stage 1: 读取数据 (I/O Bound)              │   │ │
-- │     │  │  Stage 2: 过滤/转换 (CPU Bound)            │   │ │
-- │     │  │  Stage 3: 聚合/排序 (CPU Bound)             │   │ │
-- │     │  │  Stage 4: 结果返回 (Network)               │   │ │
-- │     │  └─────────────────────────────────────────────┘   │ │
-- │     └─────────────────────────────────────────────────────┘ │
-- │                                                              │
-- └─────────────────────────────────────────────────────────────┘

-- 1.2 向量化执行引擎
--
-- ┌─────────────────────────────────────────────────────────────┐
-- │              向量化执行 vs 行式执行                            │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                              │
-- │  行式执行 (Row-by-row):                                       │
-- │  ┌───┬───┬───┬───┬───┐                                     │
-- │  │1-a│2-b│3-c│4-d│5-e│  → 处理 5 次循环                      │
-- │  └───┴───┴───┴───┴───┘                                     │
-- │                                                              │
-- │  向量化执行 (Vectorized):                                     │
-- │  ┌─────────────────────────────────────────────────────┐   │
-- │  │  Column A: [1, 2, 3, 4, 5]                          │   │
-- │  │  Column B: [a, b, c, d, e]                          │   │
-- │  │         + 运算一次处理整列                           │   │
-- │  └─────────────────────────────────────────────────────┘   │
-- │                                                              │
-- │  性能提升: 10-100x 提升 (利用 CPU SIMD 指令)                │
-- │                                                              │
-- └─────────────────────────────────────────────────────────────┘

-- 1.3 列式存储结构
--
-- ┌─────────────────────────────────────────────────────────────┐
-- │              列式存储 vs 行式存储                              │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                              │
-- │  行式存储 (Row-oriented):                                    │
-- │  ┌─────────────────────────────────────────────────────┐   │
-- │  │ [id:1, name:Alice, age:25]                         │   │
-- │  │ [id:2, name:Bob, age:30]                           │   │
-- │  │ [id:3, name:Carol, age:28]                         │   │
-- │  └─────────────────────────────────────────────────────┘   │
-- │  适合: OLTP (事务更新)                                       │
-- │                                                              │
-- │  列式存储 (Column-oriented):                                 │
-- │  ┌─────────────────────────────────────────────────────┐   │
-- │  │  id:    [1, 2, 3, ...]                             │   │
-- │  │  name:  [Alice, Bob, Carol, ...]                  │   │
-- │  │  age:   [25, 30, 28, ...]                         │   │
-- │  └─────────────────────────────────────────────────────┘   │
-- │  适合: OLAP (分析查询) - 只读需要的列                         │
-- │                                                              │
-- └─────────────────────────────────────────────────────────────┘

-- -----------------------------------------------------
-- 2. 查看 ClickHouse 版本和基本信息
-- -----------------------------------------------------

-- 查看版本信息
SELECT 
    version() AS clickhouse_version,
    timezone() AS timezone;

-- 查看编译信息
SELECT 
    name,
    value
FROM system.build_options
WHERE name IN ('VersionInteger', 'GitBranch', 'BuildId')
ORDER BY name;

-- 查看系统启动参数
SELECT 
    name,
    value
FROM system.settings
WHERE name IN ('max_threads', 'max_memory_usage', 'max_execution_time')
LIMIT 5;

-- -----------------------------------------------------
-- 3. 核心组件解析
-- -----------------------------------------------------

-- 查看支持的表引擎
SELECT 
    name AS engine_name,
    case 
        when name LIKE '%MergeTree%' THEN '核心存储引擎'
        when name LIKE '%Log%' THEN '日志引擎'
        when name LIKE '%Distributed%' THEN '分布式引擎'
        when name LIKE '%Memory%' THEN '内存引擎'
        when name LIKE '%Buffer%' THEN '缓冲引擎'
        else '其他引擎'
    end AS engine_category
FROM system.table_engines
WHERE name NOT LIKE '%Old%'
ORDER BY engine_category, name
LIMIT 20;

-- 查看可用的函数类型
SELECT 
    if(is_aggregate = 1, '聚合函数', '标量函数') AS function_type,
    count() AS count
FROM system.functions
GROUP BY function_type;

-- -----------------------------------------------------
-- 4. 查询处理管道演示
-- -----------------------------------------------------

-- 创建测试表
CREATE DATABASE IF NOT EXISTS tutorial;
DROP TABLE IF EXISTS tutorial.pipeline_demo;

CREATE TABLE IF NOT EXISTS tutorial.pipeline_demo (
    id UInt64,
    user_id UInt32,
    event_type String,
    event_date Date,
    value Float64,
    created_at DateTime DEFAULT now()
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_date)
ORDER BY (event_date, user_id);

-- 插入测试数据
INSERT INTO tutorial.pipeline_demo
SELECT 
    number AS id,
    number % 10000 AS user_id,
    ['click', 'view', 'purchase', 'login'][number % 4 + 1] AS event_type,
    toDate('2024-01-01') + (number % 365) AS event_date,
    rand() / 100.0 AS value,
    now() - INTERVAL (number % 1000) MINUTE AS created_at
FROM numbers(100000);

-- -----------------------------------------------------
-- 5. 查询执行流程分析
-- -----------------------------------------------------

-- 使用 EXPLAIN 查看查询执行计划
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

-- 使用 EXPLAIN PIPELINE 查看执行管道
EXPLAIN PIPELINE
SELECT count() FROM tutorial.pipeline_demo
WHERE event_type = 'purchase';

-- 使用 EXPLAIN ESTIMATE 估算查询成本
EXPLAIN ESTIMATE
SELECT count() FROM tutorial.pipeline_demo
WHERE user_id = 123;

-- -----------------------------------------------------
-- 6. 查看实际查询性能
-- -----------------------------------------------------

-- 执行聚合查询
SELECT 
    event_type,
    count() AS event_count,
    uniqExact(user_id) AS unique_users,
    sum(value) AS total_value,
    avg(value) AS avg_value
FROM tutorial.pipeline_demo
GROUP BY event_type
ORDER BY event_count DESC;

-- 查看查询日志
SELECT 
    query,
    read_rows,
    read_bytes,
    query_duration_ms,
    formatReadableSize(memory_usage) AS memory
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query LIKE '%pipeline_demo%'
ORDER BY event_time DESC
LIMIT 5;

-- -----------------------------------------------------
-- 7. 存储引擎架构
-- -----------------------------------------------------

-- 查看 MergeTree 存储结构
SELECT 
    partition,
    name AS part_name,
    rows,
    formatReadableSize(bytes) AS size,
    level,
    active
FROM system.parts
WHERE database = 'tutorial' AND table = 'pipeline_demo' AND active = 1
ORDER BY partition, name;

-- 查看列数据文件
SELECT 
    column,
    formatReadableSize(sum(compressed_bytes)) AS compressed,
    formatReadableSize(sum(data_uncompressed_bytes)) AS uncompressed,
    round(sum(data_uncompressed_bytes) / sum(compressed_bytes), 1) AS ratio
FROM system.parts_columns
WHERE database = 'tutorial' AND table = 'pipeline_demo' AND active = 1
GROUP BY column
ORDER BY column;

-- -----------------------------------------------------
-- 8. 分布式架构演示
-- -----------------------------------------------------

-- 查看集群信息
SELECT 
    cluster,
    shard_num,
    replica_num,
    host_name,
    host_address,
    port,
    is_local
FROM system.clusters
ORDER BY cluster, shard_num, replica_num;

-- 查看分布式表信息
SELECT 
    database,
    table,
    engine,
    cluster,
    formatReadableSize(bytes_on_disk) AS disk_size
FROM system.tables
WHERE database = 'tutorial' AND engine = 'Distributed';

-- -----------------------------------------------------
-- 9. 后台任务和合并
-- -----------------------------------------------------

-- 查看当前合并任务
SELECT 
    database,
    table,
    elapsed,
    progress,
    num_parts,
    formatReadableSize(total_size_bytes_compressed) AS size
FROM system.merges
LIMIT 5;

-- 查看后台任务队列
SELECT 
    name,
    value,
    description
FROM system.asynchronous_metrics
WHERE name LIKE '%Background%'
LIMIT 10;

-- 查看 MergeTree 配置
SELECT 
    name,
    value,
    description
FROM system.merge_tree_settings
WHERE name IN ('max_parts_to_merge_at_once', 'merge_with_ttl_timeout', 'min_bytes_for_wide_part')
LIMIT 10;

-- -----------------------------------------------------
-- 10. 内存管理
-- -----------------------------------------------------

-- 查看内存使用
SELECT 
    metric,
    formatReadableSize(value) AS value
FROM system.metrics
WHERE metric LIKE '%Memory%'
ORDER BY metric;

-- 查看查询内存使用排名
SELECT 
    query_id,
    user,
    formatReadableSize(memory_usage) AS memory,
    query_duration_ms AS duration_ms,
    read_rows
FROM system.processes
WHERE query NOT LIKE '%system.%'
ORDER BY memory_usage DESC
LIMIT 10;

-- -----------------------------------------------------
-- 11. I/O 和缓存
-- -----------------------------------------------------

-- 查看 PageCache
SELECT 
    name,
    value,
    description
FROM system.asynchronous_metrics
WHERE name LIKE '%Cache%'
   OR name LIKE '%PageCache%'
LIMIT 10;

-- 查看 MarkCache
SELECT 
    name,
    value,
    description
FROM system.asynchronous_metrics
WHERE name LIKE '%MarkCache%'
   OR name LIKE '%UncompressedCache%';

-- -----------------------------------------------------
-- 12. 学习检查点
-- -----------------------------------------------------

-- 问题 1: ClickHouse 有哪些核心组件？
-- 答案: Parser, Interpreter, Handler, Storage Engine

-- 问题 2: 查询处理流程是什么？
-- 答案: Client -> Parser -> Interpreter -> Handler -> Storage Engine

-- 问题 3: MergeTree 引擎的特点是什么？
-- 答案: 主键索引、稀疏索引、后台合并、列式存储

-- 验证查询
SELECT 
    'ClickHouse 架构' AS topic,
    version() AS version,
    (SELECT count() FROM system.table_engines) AS engine_count,
    (SELECT count() FROM system.functions) AS function_count;

-- -----------------------------------------------------
-- 13. 清理
-- -----------------------------------------------------

-- 清理测试数据
DROP TABLE IF EXISTS tutorial.pipeline_demo;

-- =====================================================
-- 本章小结
-- =====================================================
-- 
-- ClickHouse 架构核心要点:
-- 1. 客户端 -> Parser -> Interpreter -> Handler -> Storage Engine
-- 2. 支持多种客户端协议 (HTTP, Native, CLI)
-- 3. 核心存储引擎是 MergeTree 系列
-- 4. 分布式架构支持水平扩展
-- 5. 后台任务负责合并和优化
-- 6. 内存管理和缓存机制完善
--
-- 下一步: 02_column_store.sql - 深入理解列式存储
-- =====================================================
