-- =====================================================
-- 05 - 查询故障排查
-- =====================================================
-- 集群: treasurycluster (2副本)
-- 时间: 10-15分钟
-- =====================================================

-- -----------------------------------------------------
-- 准备环境
-- -----------------------------------------------------

DROP DATABASE IF EXISTS troubleshooting_test;
CREATE DATABASE troubleshooting_test;
USE troubleshooting_test;

-- -----------------------------------------------------
-- 1. 语法错误
-- -----------------------------------------------------

--
-- 【原理】ClickHouse SQL 语法与标准 SQL 有差异，尤其在数据类型、聚合函数、
-- 窗口函数、子查询等方面。常见语法错误包括：关键字拼写错误、类型转换不匹配、
-- 聚合与非聚合列混用、JOIN 语法差异、特殊的 INSERT 格式要求等。
--
-- 【场景】
--   - 报错 "Syntax error: failed at position N"
--   - 报错 "Unknown expression identifier"
--   - 报错 "Not enough columns"
--   - 报错 "Expression in FROM must be a table"
--   - 查询在 MySQL/PostgreSQL 中正常，但在 ClickHouse 中报错
--

-- 诊断：查看错误详情
-- 错误信息通常包含：
-- 1. 错误位置（行号、列号）
-- 2. 期望的语法
-- 3. 上下文信息

-- 常见语法错误示例：

-- ❌ 错误：ClickHouse 不允许无别名的子查询
-- SELECT * FROM (SELECT * FROM system.tables)  -- 报错

-- ✅ 正确：子查询必须加别名
SELECT * FROM (SELECT * FROM system.tables) AS t;

-- ❌ 错误：聚合列与非聚合列混用（无 GROUP BY）
-- SELECT name, count() FROM system.tables  -- 报错

-- ✅ 正确：使用 any() 包装非聚合列
SELECT any(name) AS name, count() FROM system.tables;

-- ❌ 错误：ClickHouse 不支持某些窗口函数语法
-- SELECT row_number() OVER () FROM system.tables  -- 需使用专用语法

-- ✅ 正确：使用合适的窗口函数语法
-- 注意：ClickHouse 从 v21.x 开始支持标准窗口函数

-- ❌ 错误：INSERT 格式错误
-- INSERT INTO table VALUES (1, 'a')  -- 如果表不存在会报错

-- 修复：使用 ClickHouse 原生 SQL 模式
-- 启用 MySQL 兼容模式（需配置）
-- SET dialect = 'mysql';  -- 从 v22.7+ 开始支持

-- 修复：使用 DESCRIBE 确认表结构
DESC TABLE system.tables;
DESC TABLE system.columns;

-- 修复：使用 EXPLAIN 查看查询计划
EXPLAIN SYNTAX SELECT * FROM system.tables;
EXPLAIN PIPELINE SELECT count() FROM system.tables;

-- -----------------------------------------------------
-- 2. 查询超时
-- -----------------------------------------------------

--
-- 【原理】ClickHouse 为查询设置了多种超时保护机制，防止长时间运行的查询
-- 耗尽资源。超时可发生在不同阶段：连接超时、接收超时、发送超时、全局查询
-- 超时。超时设置过小会导致大查询被中断，设置过大则可能导致资源无法释放。
--
-- 【场景】
--   - 查询执行一段时间后报错 "Timeout exceeded"
--   - 报错 "Received timeout exceeded"
--   - 报错 "Max query timeout exceeded"
--   - 大查询总是被中断，小查询正常
--   - 报错 "Timeout: lock was not acquired"
--

-- 诊断：检查当前超时配置
SELECT
    name,
    value,
    changed,
    description
FROM system.settings
WHERE name IN (
    'max_execution_time',
    'receive_timeout',
    'send_timeout',
    'connect_timeout',
    'lock_acquire_timeout',
    'max_query_timeout',
    'partial_result_on_timeout'
);

-- 诊断：检查被中断的查询
SELECT
    query_id,
    query,
    query_duration_ms / 1000 AS duration_sec,
    read_rows,
    formatReadableSize(read_bytes) AS bytes_read,
    formatReadableSize(memory_usage) AS memory,
    exception,
    type
FROM system.query_log
WHERE type = 'ExceptionBeforeFinish'
  AND event_time > now() - INTERVAL 1 DAY
  AND exception LIKE '%timeout%'
ORDER BY event_time DESC
LIMIT 20;

-- 修复：为当前会话设置超时
SET max_execution_time = 60;  -- 60 秒
SET receive_timeout = 300;     -- 5 分钟
SET send_timeout = 300;

-- 修复：设置带中断的超时（查询超时后自动终止）
SET timeout_overflow_mode = 'break';

-- 修复：使用 partial_result_on_timeout 获取部分结果
SET partial_result_on_timeout = 1;

-- 修复：设置锁等待超时
SET lock_acquire_timeout = 60;

-- 修复：设置空闲超时
SET idle_connection_timeout = 3600;

-- 修复：优化查询以减少执行时间
-- 1. 使用分区裁剪
-- 2. 使用主键过滤
-- 3. 使用 LIMIT
-- 4. 使用 PREWHERE 优化

-- -----------------------------------------------------
-- 3. OOM（内存溢出）
-- -----------------------------------------------------

--
-- 【原理】ClickHouse 是内存敏感型数据库，查询需要在内存中完成排序、聚合、
-- JOIN 等操作。当查询所需内存超过 max_memory_usage 限制或系统可用内存时，
-- 进程会触发 OOM Killer 或被 ClickHouse 内存限制机制中断。OOM 通常由以下
-- 原因引起：无限制的 GROUP BY 产生过多聚合键、大表 JOIN 无过滤条件、
-- 未合理使用 LIMIT、ORDER BY 大数据量、高基数聚合等。
--
-- 【场景】
--   - 报错 "Memory limit (for query) exceeded"
--   - 报错 "Memory limit (total) exceeded"
--   - 进程被系统 OOM Killer 杀死（dmesg 可见）
--   - 查询在数据量小时正常，数据量大时崩溃
--   - 多并发查询同时使用大量内存
--

-- 诊断：查看当前查询的内存使用
SELECT
    query_id,
    user,
    query,
    elapsed,
    formatReadableSize(memory_usage) AS memory,
    formatReadableSize(peak_memory_usage) AS peak_memory,
    formatReadableSize(read_bytes) AS bytes_read,
    read_rows
FROM system.processes
ORDER BY memory_usage DESC;

-- 诊断：查看历史 OOM 查询
SELECT
    query_id,
    query,
    query_duration_ms / 1000 AS duration_sec,
    formatReadableSize(memory_usage) AS memory,
    formatReadableSize(peak_memory_usage) AS peak_memory,
    exception
FROM system.query_log
WHERE type = 'ExceptionBeforeFinish'
  AND event_time > now() - INTERVAL 1 DAY
  AND exception LIKE '%Memory limit%'
ORDER BY peak_memory_usage DESC
LIMIT 20;

-- 诊断：查看系统内存使用
SELECT
    formatReadableSize(total_memory) AS total,
    formatReadableSize(free_memory) AS free,
    formatReadableSize(total_memory - free_memory) AS used,
    round((total_memory - free_memory) / total_memory * 100, 2) AS used_pct
FROM system.memory;

-- 修复：调整内存限制
SET max_memory_usage = 8000000000;  -- 8GB
SET max_bytes_before_external_group_by = 4000000000;  -- 4GB 后启用磁盘归并
SET max_bytes_before_external_sort = 4000000000;       -- 4GB 后启用磁盘排序

-- 修复：优化聚合查询
-- ❌ 不好：高基数聚合可能导致 OOM
-- SELECT user_id, count() FROM events GROUP BY user_id

-- ✅ 好：使用近似计数减少内存
SELECT uniq(user_id) FROM events;  -- 使用 HyperLogLog

-- ✅ 好：使用 LIMIT 限制聚合结果
SELECT user_id, count() AS cnt
FROM events
GROUP BY user_id
ORDER BY cnt DESC
LIMIT 1000;

-- 修复：优化 JOIN 查询
-- ❌ 不好：大表 JOIN 大表
-- SELECT * FROM big_table1 AS a JOIN big_table2 AS b ON a.id = b.id

-- ✅ 好：使用 IN 替代 JOIN
SELECT * FROM big_table1 WHERE id IN (SELECT id FROM small_table);

-- ✅ 好：使用 global IN 减少网络传输
SELECT * FROM big_table1 WHERE id GLOBAL IN (SELECT id FROM small_table);

-- 修复：使用磁盘溢出
SET max_bytes_before_external_group_by = 0;  -- 0 表示使用默认值（自动选择）
SET max_bytes_before_external_sort = 0;

-- 修复：减少并发查询数
-- 在 config.xml 中:
-- <max_concurrent_queries>100</max_concurrent_queries>
-- <max_concurrent_queries_for_user>10</max_concurrent_queries_for_user>

-- 修复：使用内存表限制
-- 在 config.xml 中:
-- <max_server_memory_usage>0</max_server_memory_usage>  -- 0 = 自动
-- <max_server_memory_usage_to_ram_ratio>0.9</max_server_memory_usage_to_ram_ratio>

-- -----------------------------------------------------
-- 4. 类型不匹配
-- -----------------------------------------------------

--
-- 【原理】ClickHouse 是强类型数据库，要求列类型在查询时严格匹配。类型不匹配
-- 通常发生在：INSERT 时数据类型与表定义不一致、函数参数类型错误、隐式类型
-- 转换失败、日期/时间格式不匹配、字符串与数值类型混用等。
--
-- 【场景】
--   - 报错 "Type mismatch"
--   - 报错 "Cannot convert string to type"
--   - 报错 "There is no supertype"
--   - 报错 "Illegal type of argument"
--   - 日期比较返回错误结果
--

-- 诊断：查看表结构定义
DESC TABLE troubleshooting_test.sample_table;

-- 修复：使用 CAST 进行显式类型转换
SELECT
    CAST('123' AS Int32) AS int_val,
    CAST(123 AS String) AS str_val,
    CAST('2024-01-01' AS Date) AS date_val,
    CAST(1650000000 AS DateTime) AS datetime_val;

-- 修复：使用 toType 函数进行类型转换
SELECT
    toInt32('123'),
    toString(123),
    toDate('2024-01-01'),
    toDateTime(1650000000),
    toFloat64('3.14');

-- 修复：处理日期格式不一致
SELECT
    toDate('2024-01-01') AS date1,
    toDate('2024/01/01') AS date2,
    toDate('20240101') AS date3,
    parseDateTimeBestEffort('01/01/2024') AS date4,
    parseDateTimeBestEffort('2024-01-01 12:30:00') AS datetime1;

-- 修复：处理 NULL 值类型
SELECT
    ifNull(CAST(NULL AS Nullable(Int32)), 0) AS with_default,
    coalesce(CAST(NULL AS Nullable(String)), 'N/A') AS coalesced;

-- 修复：使用 assumeNotNull 处理非空类型
-- SELECT assumeNotNull(nullable_column) FROM table;

-- 修复：使用 accurateCastOrNull 避免转换异常
SELECT
    accurateCastOrNull('abc' AS Int32) AS safe_int,  -- 返回 NULL
    accurateCastOrNull('123' AS Int32) AS valid_int;  -- 返回 123

-- -----------------------------------------------------
-- 5. 跳数索引失效
-- -----------------------------------------------------

--
-- 【原理】跳数索引（Skip Index）是 ClickHouse 的二级索引机制，通过记录数据
-- 块粒度的统计信息（min/max/set/bloom_filter/ngrambf/tokenbf）来跳过不满足
-- 条件的数据块。索引失效的原因包括：查询条件与索引类型不匹配、索引粒度
-- 设置过大、数据写入后索引未及时构建、使用了不支持的查询模式等。
--
-- 【场景】
--   - 查询性能未因添加索引而提升
--   - EXPLAIN 显示索引未生效（granules 未减少）
--   - 查询条件使用函数包装后索引失效
--   - 索引已创建但 system.data_skipping_indices 中未使用
--

-- 诊断：检查跳数索引定义
SELECT
    database,
    table,
    name,
    type,
    expr,
    granularity,
    rows,
    blocks,
    formatReadableSize(data_compressed_bytes) AS compressed,
    formatReadableSize(data_uncompressed_bytes) AS uncompressed,
    round(data_uncompressed_bytes / data_compressed_bytes, 2) AS ratio
FROM system.data_skipping_indices
WHERE database NOT IN ('system', 'INFORMATION_SCHEMA');

-- 诊断：使用 EXPLAIN 检查索引是否生效
EXPLAIN indexes = 1
SELECT count()
FROM troubleshooting_test.sample_table
WHERE search_column = 'value';

-- 诊断：分析索引使用情况
SELECT
    database,
    table,
    name,
    type,
    granularity,
    formatReadableSize(data_compressed_bytes) AS size
FROM system.data_skipping_indices
WHERE database NOT IN ('system', 'INFORMATION_SCHEMA');

-- 修复：手动触发索引构建
ALTER TABLE troubleshooting_test.sample_table
    MATERIALIZE INDEX idx_name;

-- 修复：创建合适的索引类型
-- minmax: 适合范围查询（日期、数值）
CREATE TABLE troubleshooting_test.indexed_table
(
    event_date Date,
    user_id UInt32,
    status String,
    amount Float64,
    INDEX idx_date event_date TYPE minmax GRANULARITY 1,
    INDEX idx_status status TYPE set(100) GRANULARITY 2,
    INDEX idx_amount amount TYPE minmax GRANULARITY 1
)
ENGINE = MergeTree()
ORDER BY (event_date, user_id);

-- 修复：使用 bloom_filter 索引适合高基数列
-- INDEX idx_email email TYPE bloom_filter(0.05) GRANULARITY 1

-- 修复：使用 tokenbf_v1 适合全文搜索
-- INDEX idx_text text TYPE tokenbf_v1(256, 2, 0) GRANULARITY 1

-- 修复：确保查询条件与索引匹配
-- ❌ minmax 索引无法加速：WHERE toYYYYMM(event_date) = '202401'
-- ✅ minmax 索引生效：WHERE event_date BETWEEN '2024-01-01' AND '2024-01-31'

-- 修复：调整索引粒度
-- 较小的 granularity = 更精确的跳过 = 更多索引存储
-- 较大的 granularity = 更少的索引存储 = 跳过精度降低
ALTER TABLE troubleshooting_test.sample_table
    DROP INDEX IF EXISTS idx_name;

ALTER TABLE troubleshooting_test.sample_table
    ADD INDEX idx_name (column_name) TYPE minmax GRANULARITY 3;

-- -----------------------------------------------------
-- 清理测试环境
-- -----------------------------------------------------

DROP DATABASE IF EXISTS troubleshooting_test;

-- =====================================================
-- 附：查询故障排查速查表
-- =====================================================
--
-- 症状                    | 诊断命令                  | 修复方法
-- ------------------------|---------------------------|---------------------------
-- 语法错误                | EXPLAIN SYNTAX            | 修正 SQL 语法 / 使用别名
-- 查询超时                | system.settings (timeout) | 调整超时参数 / 优化查询
-- 内存溢出 OOM            | system.processes          | 设置内存限制 / 启用磁盘溢出
-- 类型不匹配              | DESC TABLE                | 使用 CAST / toType 转换
-- 索引失效                | EXPLAIN indexes=1         | 重建索引 / 匹配查询模式
-- 聚合错误                | 检查 GROUP BY             | 使用 any() 包装非聚合列
--
-- =====================================================