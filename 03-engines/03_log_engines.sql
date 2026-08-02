-- ============================================================
-- 文件: 03-engines/03_log_engines.sql
-- 学习目标: 透彻理解 Log 系列三引擎的存储结构差异与适用边界
-- 深度标准: 原理 + 场景 + 对比 + 可运行
-- 集群: treasurycluster (CH 25.12.1.649, 单分片 2 副本)
-- 前置: 无（自包含测试数据，按顺序执行）
-- ============================================================
--
-- 本文件章节:
--   1.  Log 系列总览：为什么不推荐生产用？
--   2.  TinyLog：每列独立文件，无并发读
--   3.  StripeLog：单文件条带存储，带压缩
--   4.  Log：列式 + 标记文件，支持并发读
--   5.  三引擎存储结构对比实验（同数据，对比磁盘文件/大小/查询性能）
--   6.  Log 系列适用场景与陷阱
--   7.  清理
-- ============================================================
--
-- 【核心概念】
--   Log 系列定位：小数据量、临时、无索引无分区，3 个引擎差异在存储结构
--   ① TinyLog  — 每列一个独立文件，写入一次后不可再并发读
--   ② StripeLog — 所有列打包成单文件条带流，带 lz4 压缩
--   ③ Log      — 每列独立文件 + marks 标记文件，支持并发读
--   共同点：不支持主键索引、不支持分区、不支持复制
--   适用：临时中间表、小字典、调试；生产 99% 用 MergeTree 系列
-- ============================================================

CREATE DATABASE IF NOT EXISTS engine_test ON CLUSTER 'treasurycluster';
USE engine_test;


-- ============================================================
-- 1. Log 系列总览
-- ============================================================
-- 【原理】Log 系列是「极简存储引擎」，没有 MergeTree 的 Part/索引/分区机制
--   设计目标：低开销、单文件、小数据量
-- 【对比】
--   维度        | TinyLog | StripeLog | Log    | MergeTree
--   ------------|---------|-----------|--------|----------
--   列式存储     | ✅      | ❌(条带)  | ✅     | ✅
--   压缩        | ❌      | ✅(LZ4)   | ✅     | ✅(LZ4/ZSTD)
--   并发读      | ❌      | ✅        | ✅     | ✅
--   索引        | ❌      | ❌        | ❌     | ✅(稀疏主键)
--   分区        | ❌      | ❌        | ❌     | ✅
--   复制        | ❌      | ❌        | ❌     | ✅(Replicated*)
--   append-only | ✅      | ✅        | ✅     | ✅
--   适用数据量  | < 1MB   | < 100MB   | < 1GB  | 任意
-- 【坑1】Log 系列不能 ON CLUSTER（它本就是单节点本地表）
-- 【坑2】Log 系列写入是一次性追加，不支持 ALTER UPDATE/DELETE（只支持 DROP 整表）
-- 【坑3】生产环境误用 Log 系列存大数据 → 查询全表扫描，性能极差


-- ============================================================
-- 2. TinyLog：每列独立文件，最简单
-- ============================================================
-- 【原理】每列存成 2 个文件：
--   {col}.bin  — 列数据（无压缩）
--   {col}.mrk  — 标记文件（仅记录块偏移，无索引功能）
--   sizes.json — 文件大小元数据
-- 【场景】一次性写入 + 单次查询的临时数据（< 1MB），如中间结果落盘
-- 【坑】不支持并发读取（同时多个 SELECT 会互相阻塞）
--   —— 因为没有协调机制，多读会读到不一致状态

DROP TABLE IF EXISTS tinylog_events ON CLUSTER 'treasurycluster' SYNC;

CREATE TABLE tinylog_events ON CLUSTER 'treasurycluster' (
    event_id UInt64,
    user_id UInt64,
    event_type String,
    event_data String,
    timestamp DateTime
) ENGINE = TinyLog();

INSERT INTO tinylog_events (event_id, user_id, event_type, event_data, timestamp) VALUES
    (1, 1, 'click',  '{"page":"home"}',                  '2024-01-01 10:00:00'),
    (2, 1, 'view',   '{"page":"products"}',              '2024-01-01 10:05:00'),
    (3, 2, 'click',  '{"page":"products"}',              '2024-01-01 11:00:00'),
    (4, 3, 'purchase','{"product_id":101,"amount":99.99}','2024-01-01 12:00:00'),
    (5, 1, 'logout', '{"duration":3600}',                '2024-01-02 09:00:00');

SELECT event_id, user_id, event_type, timestamp
FROM tinylog_events
ORDER BY event_id;

-- 2.1 查看 TinyLog 的物理文件结构（在容器内执行 ls 命令）
--   预期文件：event_id.bin / event_id.mrk、user_id.bin / user_id.mrk、...、sizes.json
--   docker exec clickhouse-server-1 ls /var/lib/clickhouse/data/engine_test/tinylog_events/
SELECT
    engine,
    total_rows,
    formatReadableSize(total_bytes) AS total_size
FROM system.tables
WHERE database = 'engine_test' AND name = 'tinylog_events';


-- ============================================================
-- 3. StripeLog：单文件条带存储，带压缩
-- ============================================================
-- 【原理】所有列打包到一个文件（data.bin）+ 一个索引文件（index.mrk）
--   data.bin — 每行按列顺序紧凑存储，每块带 LZ4 压缩
--   index.mrk — 记录每块的偏移，支持顺序读
-- 【场景】中等数据量(<100MB)的日志/中间结果，需要压缩
-- 【对比】vs TinyLog：压缩节省 50%+ 空间；vs Log：不支持并发读

DROP TABLE IF EXISTS stripelog_logs ON CLUSTER 'treasurycluster' SYNC;

CREATE TABLE stripelog_logs ON CLUSTER 'treasurycluster' (
    log_id UInt64,
    level String,
    message String,
    timestamp DateTime
) ENGINE = StripeLog();

INSERT INTO stripelog_logs (log_id, level, message, timestamp) VALUES
    (1, 'INFO',    'Application started',  '2024-01-01 10:00:00'),
    (2, 'DEBUG',   'Processing request',   '2024-01-01 10:01:00'),
    (3, 'INFO',    'User logged in',       '2024-01-01 10:05:00'),
    (4, 'WARNING', 'High memory usage',    '2024-01-01 10:10:00'),
    (5, 'ERROR',   'Connection failed',    '2024-01-01 10:15:00');

-- 3.1 按级别统计
-- 【结果解读】StripeLog 支持普通 GROUP BY，但无索引剪枝，全表扫描
SELECT level, count() AS log_count
FROM stripelog_logs
GROUP BY level
ORDER BY log_count DESC;

-- 3.2 查看 StripeLog 的物理文件结构（在容器内执行 ls 命令）
--   预期文件：data.bin（条带数据+LZ4压缩） + index.mrk（块偏移标记）
--   docker exec clickhouse-server-1 ls /var/lib/clickhouse/data/engine_test/stripelog_logs/
SELECT
    engine,
    total_rows,
    formatReadableSize(total_bytes) AS total_size
FROM system.tables
WHERE database = 'engine_test' AND name = 'stripelog_logs';


-- ============================================================
-- 4. Log：列式 + 标记文件，支持并发读
-- ============================================================
-- 【原理】每列独立文件 + 共享 marks 标记文件，支持多线程并发读取
--   {col}.bin  — 列数据（带 LZ4 压缩）
--   __marks.mrk — 跨列共享标记文件，记录每个块的偏移
-- 【场景】中等规模日志(<1GB)、配置字典、需要并发查询的小数据
-- 【对比】
--   vs TinyLog  — 多了并发读支持 + 压缩
--   vs StripeLog — 列式存储，分析查询（只读部分列）更快
--   vs MergeTree — 仍无索引无分区，大数据查询慢

DROP TABLE IF EXISTS log_metrics ON CLUSTER 'treasurycluster' SYNC;

CREATE TABLE log_metrics ON CLUSTER 'treasurycluster' (
    metric_id UInt64,
    metric_name String,
    metric_value Float64,
    tags String,
    timestamp DateTime
) ENGINE = Log();

INSERT INTO log_metrics (metric_id, metric_name, metric_value, tags, timestamp) VALUES
    (1, 'cpu_usage',    45.5, '{"server":"web1"}', '2024-01-01 10:00:00'),
    (2, 'memory_usage', 68.2, '{"server":"web1"}', '2024-01-01 10:01:00'),
    (3, 'disk_usage',   78.9, '{"server":"web1"}', '2024-01-01 10:02:00'),
    (4, 'cpu_usage',    52.3, '{"server":"web2"}', '2024-01-01 10:00:00'),
    (5, 'memory_usage', 71.1, '{"server":"web2"}', '2024-01-01 10:01:00');

-- 4.1 按服务器统计
-- 【结果解读】Log 引擎只读用到的列（metric_value、tags），其它列不读
SELECT
    JSONExtractString(tags, 'server') AS server,
    avg(metric_value) AS avg_value,
    count() AS metric_count
FROM log_metrics
GROUP BY server
ORDER BY server;

-- 4.2 查看 Log 的物理文件结构（在容器内执行 ls 命令）
--   预期：metric_id.bin、metric_name.bin、...、__marks.mrk（跨列共享标记）
--   docker exec clickhouse-server-1 ls /var/lib/clickhouse/data/engine_test/log_metrics/
SELECT
    engine,
    total_rows,
    formatReadableSize(total_bytes) AS total_size
FROM system.tables
WHERE database = 'engine_test' AND name = 'log_metrics';


-- ============================================================
-- 5. 三引擎存储结构对比实验
-- ============================================================
-- 【原理】同数据存入三个引擎，对比磁盘大小、查询性能、文件结构
-- 【场景】为选型提供量化依据
-- 【预期结果】
--   存储大小：TinyLog > Log ≈ StripeLog（后两者有压缩）
--   查询性能：Log > StripeLog > TinyLog（Log 列式可只读必要列）

DROP TABLE IF EXISTS tinylog_test ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS stripelog_test ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS log_test ON CLUSTER 'treasurycluster' SYNC;

CREATE TABLE tinylog_test ON CLUSTER 'treasurycluster'   (id UInt64, data String, value Float64) ENGINE = TinyLog();
CREATE TABLE stripelog_test ON CLUSTER 'treasurycluster' (id UInt64, data String, value Float64) ENGINE = StripeLog();
CREATE TABLE log_test ON CLUSTER 'treasurycluster'       (id UInt64, data String, value Float64) ENGINE = Log();

-- 5.1 写入 1000 行相同数据
INSERT INTO tinylog_test SELECT number, repeat('test data ', 5), rand() * 1000 FROM numbers(1000);
INSERT INTO stripelog_test SELECT * FROM tinylog_test;
INSERT INTO log_test SELECT * FROM tinylog_test;

-- 5.2 行数对比
SELECT 'TinyLog'   AS engine, count() AS row_count FROM tinylog_test
UNION ALL
SELECT 'StripeLog', count()                FROM stripelog_test
UNION ALL
SELECT 'Log',       count()                FROM log_test;

-- 5.3 存储大小对比（system.tables 的 total_bytes 是表级汇总）
SELECT
    name,
    engine,
    total_rows,
    formatReadableSize(total_bytes) AS readable_size
FROM system.tables
WHERE database = 'engine_test' AND name LIKE '%_test'
ORDER BY name;

-- 5.4 文件粒度对比（在容器内执行 ls 命令查看）
--   docker exec clickhouse-server-1 ls -la /var/lib/clickhouse/data/engine_test/tinylog_test/
--   docker exec clickhouse-server-1 ls -la /var/lib/clickhouse/data/engine_test/stripelog_test/
--   docker exec clickhouse-server-1 ls -la /var/lib/clickhouse/data/engine_test/log_test/
--   预期：TinyLog 每列 .bin+.mrk；StripeLog 单 data.bin+index.mrk；Log 每列 .bin+共享 __marks.mrk
SELECT
    name,
    engine,
    total_rows,
    formatReadableSize(total_bytes) AS total_size
FROM system.tables
WHERE database = 'engine_test' AND name LIKE '%_test'
ORDER BY total_bytes;

-- 5.5 查询性能对比（只读 value 列，观察 read_bytes）
--   【预期】Log 最快（列式只读 value）；StripeLog 次之（条带需读所有列）
--          TinyLog 最慢（无压缩 + 单线程）
SET log_query_threads = 1;

SELECT 'TinyLog' AS engine, avg(value) AS avg_v, count() AS c FROM tinylog_test;
SELECT 'StripeLog' AS engine, avg(value) AS avg_v, count() AS c FROM stripelog_test;
SELECT 'Log' AS engine, avg(value) AS avg_v, count() AS c FROM log_test;

-- 5.6 查看查询读取的字节数（评估列式剪枝效果）
SELECT
    query_duration_ms,
    read_rows,
    formatReadableSize(read_bytes) AS data_read
FROM system.query_thread_log
WHERE positionCaseInsensitive(query, '_test') > 0
  AND query LIKE '%avg(value)%'
  AND is_initial_query = 1
ORDER BY event_time DESC
LIMIT 6;


-- ============================================================
-- 6. Log 系列适用场景与陷阱
-- ============================================================
-- 【适用场景】
--   ① 临时中间表：ETL 中转，跑完即删
--   ② 小字典表：配置表、白名单（< 1MB），频繁全表读
--   ③ 调试/教学：快速验证 SQL 语法，不需要复杂结构
--
-- 【陷阱★】
--   ① 误用存大数据 → 全表扫描，性能比 MergeTree 差 10-100 倍
--   ② 误以为支持复制 → Log 系列无 Replicated 版本，宕机丢数据
--   ③ 误以为支持索引 → 没有主键索引，没有跳数索引，没有分区
--   ④ 误以为支持 UPDATE/DELETE → 只能 DROP 重建
--   ⑤ 误用 ON CLUSTER → Log 表是本地表，每个节点独立，不自动同步
--
-- 【迁移建议】如果发现 Log 表数据量增长，立即迁移到 MergeTree：
--   CREATE TABLE new_table (...) ENGINE = MergeTree() ORDER BY ...;
--   INSERT INTO new_table SELECT * FROM old_log_table;
--   DROP TABLE old_log_table;


-- ============================================================
-- 7. 清理
-- ============================================================
DROP TABLE IF EXISTS tinylog_events ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS stripelog_logs ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS log_metrics ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS tinylog_test ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS stripelog_test ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS log_test ON CLUSTER 'treasurycluster' SYNC;


-- ============================================================
-- 8. Log 系列最佳实践总结
-- ============================================================
-- 【选型决策】
--   数据量 < 1MB 且无并发读需求     → TinyLog（最简）
--   数据量 1MB-100MB 需要压缩       → StripeLog（条带+LZ4）
--   数据量 100MB-1GB 需要并发分析   → Log（列式+marks）
--   数据量 > 1GB 或需要索引/分区/复制 → MergeTree 系列
--
-- 【生产环境铁律】
--   ① 99% 的生产表用 ReplicatedMergeTree 系列
--   ② Log 系列只用于临时表/字典表，且必须有 TTL 或定期清理机制
--   ③ 永远不要用 Log 系列存业务流水数据
--
-- 【引擎对比速查表】
--   | 引擎       | 压缩 | 并发读 | 列式 | 适用数据量 | 推荐场景 |
--   |-----------|------|--------|------|-----------|----------|
--   | TinyLog   | ❌  | ❌     | ✅   | < 1MB     | 临时中间结果 |
--   | StripeLog | LZ4 | ✅     | ❌   | < 100MB   | 小日志、需压缩 |
--   | Log       | LZ4 | ✅     | ✅   | < 1GB     | 小字典、并发分析 |
--   | MergeTree | LZ4/ZSTD | ✅ | ✅   | 任意      | 生产标配 |
