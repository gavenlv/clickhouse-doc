-- ============================================================
-- 01 - 什么是 ClickHouse？
-- ============================================================
-- 学习目标:
--   1. 验证 ClickHouse 服务版本与基本信息
--   2. 体验单机千万级聚合的"秒级"性能
--   3. 直观观测列式存储的压缩率
--   4. 掌握 OLAP vs OLTP 场景决策
--   5. 理解 ClickHouse 的四大加速原理
--
-- 深度标准: 本章是入门篇，配套 README 第 2 节"为什么快"原理
--          每个 SQL 都标注【原理】【场景】【对比】【坑】
--
-- 章节索引:
--   README.md            - 本章总览与原理
--   01_what_is_clickhouse.sql ← 你在这里
--   02_column_oriented  - 列式存储深入
--   03_mergeTree_engine - MergeTree 引擎
--   04_basic_sql        - 基础 SQL
--   05_cluster_concepts - 集群概念
--   06_first_replicated_table - 复制表
--
-- 集群信息: treasurycluster (CH 25.12.1.649), 1分片×2副本
--          clickhouse-server-1 / clickhouse-server-2
-- 数据库  : understanding_test (独立数据库，避免冲突)
-- ============================================================


-- ------------------------------------------------------------
-- 0. 准备：独立数据库，避免与其他章节冲突
-- ------------------------------------------------------------
-- 【原理】ClickHouse 的数据库是命名空间，不影响存储
-- 【场景】多章节共用同一集群时，用独立 DB 防止表名冲突
DROP DATABASE IF EXISTS understanding_test;
CREATE DATABASE understanding_test;

USE understanding_test;


-- ------------------------------------------------------------
-- 1. 验证 ClickHouse 版本和基本信息
-- ------------------------------------------------------------
-- 【原理】version() 返回服务器版本；uptime() 返回运行时长
-- 【场景】每次连接新集群时，先确认版本和健康度
-- 【对比】CH 25.12 与旧版语法有差异（如 system.macros 字段名）

SELECT
    version() AS clickhouse_version,
    hostName() AS host,
    uptime() AS uptime_seconds,
    formatReadableTimeDelta(uptime()) AS uptime_human;

-- 结果解读: 显示 CH 25.12.1.649，主机名 clickhouse1，运行时长
-- 注意: version() 来自当前连接的服务器，不反映整个集群


-- ------------------------------------------------------------
-- 2. ClickHouse 核心能力概览
-- ------------------------------------------------------------
-- 【原理】system.functions 是函数注册表；is_aggregate 区分标量/聚合
-- 【场景】估算"能力天花板"，决定能否在 SQL 层完成业务
-- 【对比】PostgreSQL 内置 ~300 个函数；CH 有 1500+，远超 OLTP 库

SELECT
    count() AS total_functions,
    countIf(is_aggregate = 1) AS aggregate_functions,
    countIf(is_aggregate = 0) AS scalar_functions
FROM system.functions;

-- 结果解读: 总函数 1500+，聚合 200+，标量 1300+
-- 这意味着 90% 的业务逻辑都能在 SQL 层完成，无需 UDF


-- ------------------------------------------------------------
-- 3. 千万行性能演示：体验"秒扫亿行"的奥秘
-- ------------------------------------------------------------

-- 3.1 创建一张能模拟真实业务的明细表
-- 【原理】MergeTree 是 CH 最核心引擎；ORDER BY 决定物理排序和裁剪能力
-- 【场景】日志/事件/埋点表的典型结构
-- 【坑】不要用 event_date 单列排序，"按 user 查询某天"会扫整张表
CREATE TABLE IF NOT EXISTS performance_demo
(
    id            UInt64,
    user_id       UInt32,
    event_type    LowCardinality(String),  -- 【原理】枚举值用 LowCardinality，体积缩小 10x
    event_date    Date,
    event_time    DateTime,
    value         Float64,
    properties    String
)
ENGINE = MergeTree()
ORDER BY (event_date, user_id, event_time)  -- 【原理】排序键: 时间+用户+时间戳
PARTITION BY toYYYYMM(event_date);           -- 【原理】按月分区，便于生命周期管理

-- 3.2 生成 1000 万行测试数据
-- 【原理】numbers(N) 是表函数，生成 0..N-1 的虚拟表，配合 INSERT 即可造数
-- 【场景】快速生成大量测试数据评估性能
-- 【对比】MySQL 生成 1000 万行需存储过程或脚本，CH 一条 SQL 搞定
INSERT INTO performance_demo
SELECT
    number AS id,
    rand() % 1000000 AS user_id,
    ['click', 'view', 'purchase', 'login', 'logout'][rand() % 5 + 1] AS event_type,
    toDate('2024-01-01') + (rand() % 365) AS event_date,
    toDateTime('2024-01-01 00:00:00') + (rand() % 31536000) AS event_time,
    rand() / 1000000.0 AS value,
    'some random properties data for testing' AS properties
FROM numbers(10000000);

-- 结果解读: 1000 万行 INSERT 在单机几秒完成（合并是异步的，查询可见即可）

-- 3.3 体验聚合查询性能
-- 【原理】CH 聚合只读取需要的列，配合向量化执行，千万级 < 1s
-- 【场景】日报表：按天+事件类型统计
-- 【对比】同样的查询在 MySQL（行式+无并行）通常需要 5-30s
SELECT
    event_date,
    count() AS event_count,
    count(DISTINCT user_id) AS unique_users,
    round(sum(value), 2) AS total_value,
    round(avg(value), 4) AS avg_value
FROM performance_demo
WHERE event_date >= '2024-01-01' AND event_date <= '2024-01-31'
GROUP BY event_date
ORDER BY event_date
LIMIT 10;

-- 结果解读: 扫描 1 月份约 84 万行（11M/12 ≈ 92万/月），查询时间通常 < 100ms
-- 这就是"列存+向量化+并行"的威力


-- ------------------------------------------------------------
-- 4. 列式存储优势：只读需要的列
-- ------------------------------------------------------------
-- 【原理】CH 只读取 SELECT 涉及的列；不涉及的列完全不读 IO
-- 【场景】绝大多数 OLAP 查询只关心少数列
-- 【坑】SELECT * 会读所有列，性能急剧下降（违反列存初衷）

-- 4.1 查询 A: 只读 2 列（极快）
SELECT event_date, count()
FROM performance_demo
GROUP BY event_date
ORDER BY event_date
LIMIT 5;

-- 4.2 查询 B: 读 6 列（明显慢，但不至于卡）
SELECT
    event_date,
    user_id,
    event_type,
    sum(value) AS total,
    min(event_time) AS first_event,
    max(event_time) AS last_event
FROM performance_demo
WHERE event_date = '2024-06-15'
GROUP BY event_date, user_id, event_type
ORDER BY event_date, user_id, event_type
LIMIT 5;

-- 结果解读: 同样的过滤条件，查询 A 比查询 B 快 3-5x
-- 因为 A 只读 event_date 一列（外加 count），B 读 5 列


-- ------------------------------------------------------------
-- 5. 数据压缩效果观测
-- ------------------------------------------------------------
-- 【原理】system.parts 显示 part 元数据；bytes 是磁盘实际占用，data_uncompressed_bytes 是逻辑大小
-- 【场景】评估存储成本、判断压缩配置是否合理
-- 【对比】MySQL InnoDB page 压缩通常 1.5-2x；CH 列存通常 5-10x

SELECT
    table,
    formatReadableSize(sum(bytes_on_disk)) AS disk_size,
    formatReadableSize(sum(data_uncompressed_bytes)) AS uncompressed_size,
    round(sum(data_uncompressed_bytes) / sum(bytes_on_disk), 2) AS compression_ratio,
    sum(rows) AS total_rows,
    countIf(active = 1) AS active_parts
FROM system.parts
WHERE database = 'understanding_test' AND table = 'performance_demo'
GROUP BY table;

-- 结果解读:
--   disk_size: 实际磁盘占用（含压缩）
--   uncompressed_size: 逻辑数据大小
--   compression_ratio: 压缩比（通常 5-10）
--   active_parts: 活跃 part 数（多次 INSERT 会产生多个 part，合并后减少）


-- ------------------------------------------------------------
-- 6. 适用场景 vs 不适用场景
-- ------------------------------------------------------------
-- 【原理】通过对比表固化"OLAP vs OLTP"决策
-- 【场景】技术选型时直接对照
-- 【对比】CH 强在"扫描+聚合"，弱在"事务+点查"

CREATE TABLE IF NOT EXISTS use_case_comparison
(
    scenario           String,
    clickhouse_suitable UInt8,
    reason             String,
    alternative        String
)
ENGINE = MergeTree()
ORDER BY scenario;

-- 注意: VALUES 内不能有行内注释（CH 25.12 限制），注释统一放在 VALUES 之前
INSERT INTO use_case_comparison VALUES
('日志分析', 1, '海量数据，主要做聚合查询，数据追加为主', 'Elasticsearch'),
('时序数据', 1, '时间序列数据，按时间范围查询，高压缩率', 'InfluxDB, TimescaleDB'),
('数据仓库', 1, 'OLAP 分析，复杂聚合，维度分析', 'Snowflake, BigQuery'),
('实时报表', 1, '预聚合，快速查询，高并发读取', 'Druid, Pinot'),
('用户行为分析', 1, '事件流分析，漏斗分析，留存分析', '自研 Spark 方案'),
('银行交易', 0, '需要 ACID 事务，行级更新频繁', 'PostgreSQL, Oracle'),
('订单处理', 0, '需要事务支持，频繁的 UPDATE/DELETE', 'MySQL, PostgreSQL'),
('用户资料管理', 0, '单条记录查询，频繁更新', 'Redis, MongoDB'),
('库存管理', 0, '需要精确的行级锁和事务', 'MySQL, PostgreSQL'),
('消息队列', 0, '需要低延迟的消息传递', 'Kafka, RabbitMQ');

SELECT
    scenario,
    if(clickhouse_suitable = 1, '适合', '不适合') AS suitability,
    reason,
    alternative
FROM use_case_comparison
ORDER BY clickhouse_suitable DESC, scenario;

-- 结果解读: 上半部分是 CH 的"主战场"，下半部分请选择对应专长系统


-- ------------------------------------------------------------
-- 7. 为什么快：四大加速原理观测
-- ------------------------------------------------------------
-- 【原理】CH 快的四大支柱: ①列存 ②向量化 ③压缩 ④并行
-- 【场景】判断"是否还能再加速"的依据
-- 【对比】OLTP 数据库通常只有 B+树索引，缺这四项

-- 7.1 观测并行度: max_threads
-- 【原理】CH 自动按 CPU 核数切分查询，并行执行
SELECT
    name,
    value,
    changed
FROM system.settings
WHERE name = 'max_threads';

-- 结果解读: 默认 = CPU 核数。值越大并行度越高（但 CPU 满负荷）

-- 7.2 观测执行计划: 看 Pipeline 并行
-- 【原理】EXPLAIN PIPELINE 显示实际执行流；多线程会有多个 Processor
-- 【场景】查询慢时定位是 IO 还是 CPU 瓶颈
EXPLAIN PIPELINE
SELECT event_date, count()
FROM performance_demo
GROUP BY event_date;

-- 结果解读: 看到 'MergingAggregated' 和 'Resize' 表示多线程并行聚合
-- 如果只有单线程，可能是数据量小没触发并行


-- ------------------------------------------------------------
-- 8. 系统表引擎概览
-- ------------------------------------------------------------
-- 【原理】system.table_engines 列出所有可用引擎
-- 【场景】选型时快速查看可用引擎

SELECT
    name AS engine_name,
    -- 【坑】system.table_engines 无 has_own_data 列，用引擎名分类
    multiIf(
        name LIKE '%MergeTree%' OR name LIKE '%Log%', '存储数据',
        '虚拟引擎'
    ) AS engine_type
FROM system.table_engines
WHERE name LIKE '%MergeTree%' OR name LIKE '%Log%'
ORDER BY engine_type, engine_name
LIMIT 20;

-- 结果解读: 看到 MergeTree 家族（基础/Replacing/Summing/Aggregating/...）
-- 和 Log 家族（TinyLog/StripeLog/Log，小表用）


-- ------------------------------------------------------------
-- 9. 学习检查点
-- ------------------------------------------------------------
-- 问题 1: 当前表插入了多少行？
SELECT count() AS total_rows FROM performance_demo;

-- 问题 2: 压缩率是多少？
SELECT
    round(sum(data_uncompressed_bytes) / sum(bytes_on_disk), 2) AS compression_ratio
FROM system.parts
WHERE database = 'understanding_test' AND table = 'performance_demo';

-- 问题 3: 哪种 event_type 数量最多？
SELECT
    event_type,
    count() AS cnt
FROM performance_demo
GROUP BY event_type
ORDER BY cnt DESC;

-- 问题 4: 一月份有多少独立用户？
SELECT count(DISTINCT user_id) AS unique_users
FROM performance_demo
WHERE event_date BETWEEN '2024-01-01' AND '2024-01-31';


-- ------------------------------------------------------------
-- 10. 本章小结
-- ------------------------------------------------------------
-- ClickHouse 是:
--   1. 开源列式 OLAP 数据库，专为海量数据分析而生
--   2. 四大加速支柱: 列存 + 向量化 + 压缩 + 并行
--   3. 千万级聚合秒级响应，百亿级数据可扩展
--   4. 适合: 日志/事件/时序/数仓/实时报表
--   5. 不适合: 事务/点查/频繁 UPDATE
--
-- 下一步: 02_column_oriented.sql - 深入列式存储原理
-- ============================================================
