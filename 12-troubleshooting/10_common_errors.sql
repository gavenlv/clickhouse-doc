-- =====================================================
-- 10 - 常见错误码排查
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
-- 1. 连接与协议错误
-- -----------------------------------------------------

--
-- 【原理】ClickHouse 使用自定义 TCP 协议进行客户端-服务器通信，同时支持
-- HTTP、MySQL 和 PostgreSQL 协议。连接和协议错误通常由网络问题、版本不
-- 兼容、协议配置错误引起。常见的错误码包括网络错误、认证错误、协议版本
-- 不匹配等。
--

-- 错误码 40: "Checksum doesn't match"
-- 【原理】数据读取时校验和验证失败，表明数据文件可能已损坏。校验和在
-- 写入时计算并存储在 checksums.txt 中，读取时重新计算比对。
-- 【场景】SELECT 时报错，写入时报错，重启后 ATTACH 表时报错
-- 【修复】DETACH PARTITION + ATTACH PARTITION，从副本 FETCH，或重建表
SELECT
    'Error 40: Checksum mismatch' AS error_code,
    'Data corruption detected' AS description,
    'DETACH + ATTACH partition, or fetch from replica' AS solution;

-- 错误码 60: "Table is read-only"
-- 【原理】副本标记为只读状态，通常由 ZK/Keeper 会话过期、磁盘空间不足、
-- 或数据目录权限问题引起。
-- 【场景】写入失败，报错表为只读，副本状态 is_readonly = 1
-- 【修复】恢复 ZK 连接、清理磁盘空间、修复权限后重启复制
SELECT
    'Error 60: Table is read-only' AS error_code,
    'Replica is in read-only mode' AS description,
    'Check ZK connection, disk space, and permissions' AS solution;

-- 错误码 117: "Unknown user"
-- 【原理】尝试使用不存在的用户连接 ClickHouse。
-- 【场景】连接时认证失败，users.xml 中未配置相应用户
-- 【修复】在 users.xml 中添加用户，或使用正确用户名连接
SELECT
    'Error 117: Unknown user' AS error_code,
    'User does not exist' AS description,
    'Create user or check credentials' AS solution;

-- 错误码 218: "Unknown packet from server"
-- 【原理】客户端和服务器之间的协议版本不匹配，通常发生在跨版本通信时。
-- 【场景】使用旧版本客户端连接新版本服务器，或反之
-- 【修复】升级客户端版本至与服务器一致
SELECT
    'Error 218: Unknown packet' AS error_code,
    'Protocol version mismatch' AS description,
    'Upgrade client to match server version' AS solution;

-- 错误码 226: "No such table"
-- 【原理】查询的表不存在，或表名大小写不匹配。
-- 【场景】SELECT/INSERT 时报错，表名拼写错误
-- 【修复】检查表名拼写，确认表是否存在
SELECT
    'Error 226: No such table' AS error_code,
    'Table does not exist' AS description,
    'Check table name spelling and database' AS solution;

-- 错误码 242: "Too many simultaneous queries"
-- 【原理】并发查询数超过 max_concurrent_queries 限制。
-- 【场景】新查询被拒绝，现有查询正常
-- 【修复】增加 max_concurrent_queries，或等待现有查询完成
SELECT
    'Error 242: Too many queries' AS error_code,
    'Concurrent query limit exceeded' AS description,
    'Increase max_concurrent_queries or wait' AS solution;

-- 错误码 279: "No such column"
-- 【原理】查询的列在表中不存在。
-- 【场景】SELECT 时报错，列名拼写错误或列已被删除
-- 【修复】检查列名拼写，确认列是否存在
SELECT
    'Error 279: No such column' AS error_code,
    'Column does not exist' AS description,
    'Check column name spelling' AS solution;

-- 错误码 319: "Unknown function"
-- 【原理】使用的函数名不存在，或函数在当前版本中不可用。
-- 【场景】查询中使用拼写错误的函数名，或使用了旧版本不支持的函数
-- 【修复】检查函数名拼写，确认版本的函数支持列表
SELECT
    'Error 319: Unknown function' AS error_code,
    'Function does not exist' AS description,
    'Check function name spelling and version support' AS solution;

-- 错误码 359: "Authentication failed"
-- 【原理】用户认证失败，密码错误或 IP 白名单限制。
-- 【场景】连接时报错，使用错误密码或从非授权 IP 连接
-- 【修复】检查密码，确认 IP 白名单配置
SELECT
    'Error 359: Authentication failed' AS error_code,
    'Invalid credentials or IP restriction' AS description,
    'Check password and IP whitelist' AS solution;

-- 错误码 395: "Cannot allocate memory"
-- 【原理】系统内存不足，无法分配查询所需内存。
-- 【场景】查询时内存不足，服务器内存耗尽
-- 【修复】减少查询内存使用，增加服务器内存，或调整 max_memory_usage
SELECT
    'Error 395: Cannot allocate memory' AS error_code,
    'System out of memory' AS description,
    'Reduce memory usage or increase server memory' AS solution;

-- 错误码 396: "Memory limit exceeded"
-- 【原理】查询超过 max_memory_usage 限制。
-- 【场景】查询被中断报错，提示内存超限
-- 【修复】增加 max_memory_usage，优化查询，或启用磁盘溢出
SELECT
    'Error 396: Memory limit exceeded' AS error_code,
    'Query exceeded memory limit' AS description,
    'Increase max_memory_usage or optimize query' AS solution;

-- 错误码 441: "No space left on device"
-- 【原理】磁盘空间不足，无法写入数据。
-- 【场景】INSERT 时报错，合并任务失败
-- 【修复】清理过期数据、扩容磁盘、配置分层存储
SELECT
    'Error 441: No space left' AS error_code,
    'Disk space exhausted' AS description,
    'Clean up data or expand disk' AS solution;

-- 错误码 517: "Unknown table engine"
-- 【原理】指定的表引擎不存在或拼写错误。
-- 【场景】CREATE TABLE 时报错
-- 【修复】检查引擎名称拼写，确认版本支持
SELECT
    'Error 517: Unknown engine' AS error_code,
    'Table engine does not exist' AS description,
    'Check engine name spelling' AS solution;

-- 错误码 519: "Table already exists"
-- 【原理】创建表时表已存在。
-- 【场景】CREATE TABLE 时报错
-- 【修复】使用 IF NOT EXISTS，或先 DROP 再创建
SELECT
    'Error 519: Table already exists' AS error_code,
    'Table with same name exists' AS description,
    'Use IF NOT EXISTS or DROP first' AS solution;

-- 错误码 621: "Duplicate column name"
-- 【原理】表定义中出现重复的列名。
-- 【场景】CREATE TABLE 或 ALTER TABLE ADD COLUMN 时报错
-- 【修复】检查列名是否重复，修改列名
SELECT
    'Error 621: Duplicate column' AS error_code,
    'Column name already exists' AS description,
    'Rename or remove duplicate column' AS solution;

-- 错误码 628: "Unknown cluster"
-- 【原理】指定的集群名称不存在。
-- 【场景】使用 ON CLUSTER 时集群名错误
-- 【修复】检查集群名，确认 system.clusters 中存在
SELECT
    'Error 628: Unknown cluster' AS error_code,
    'Cluster does not exist' AS description,
    'Check cluster name in system.clusters' AS solution;

-- 错误码 632: "Too many partitions"
-- 【原理】单个表的分区数量超过限制（默认 100-1000 取决于版本）。
-- 【场景】INSERT 时创建了新分区，总分区数超过限制
-- 【修复】调整 max_partitions_to_write，优化分区策略
SELECT
    'Error 632: Too many partitions' AS error_code,
    'Partition count exceeded limit' AS description,
    'Increase max_partitions_to_write or optimize partitioning' AS solution;

-- 错误码 642: "Illegal type of argument"
-- 【原理】函数参数类型不符合预期。
-- 【场景】查询时函数参数类型错误
-- 【修复】使用 CAST 转换参数类型
SELECT
    'Error 642: Illegal argument type' AS error_code,
    'Function argument type mismatch' AS description,
    'Use CAST to convert argument types' AS solution;

-- 错误码 651: "Unknown setting"
-- 【原理】配置项名称不存在或已被移除。
-- 【场景】SET 或 config.xml 中使用不存在的配置项
-- 【修复】检查配置项名称，查阅版本兼容性说明
SELECT
    'Error 651: Unknown setting' AS error_code,
    'Configuration parameter does not exist' AS description,
    'Check setting name and version compatibility' AS solution;

-- 错误码 652: "Cannot parse"
-- 【原理】SQL 解析失败，语法错误。
-- 【场景】查询时 SQL 语法错误
-- 【修复】检查 SQL 语法，使用 EXPLAIN SYNTAX 验证
SELECT
    'Error 652: Cannot parse' AS error_code,
    'SQL syntax error' AS description,
    'Check SQL syntax, use EXPLAIN SYNTAX' AS solution;

-- 错误码 653: "Unknown identifier"
-- 【原理】标识符（列名、表名、别名）无法识别。
-- 【场景】查询中引用不存在的标识符
-- 【修复】检查标识符拼写和可见性
SELECT
    'Error 653: Unknown identifier' AS error_code,
    'Identifier not found' AS description,
    'Check identifier spelling and scope' AS solution;

-- 错误码 681: "Timeout exceeded"
-- 【原理】查询执行时间超过 max_execution_time 限制。
-- 【场景】长时间运行的查询被中断
-- 【修复】增加 max_execution_time，优化查询性能
SELECT
    'Error 681: Timeout exceeded' AS error_code,
    'Query execution time limit exceeded' AS description,
    'Increase max_execution_time or optimize query' AS solution;

-- 错误码 700: "Invalid identifier"
-- 【原理】标识符格式不正确（如包含非法字符）。
-- 【场景】使用带引号的标识符格式错误
-- 【修复】使用反引号或双引号包裹标识符
SELECT
    'Error 700: Invalid identifier' AS error_code,
    'Identifier format is invalid' AS description,
    'Use backticks or double quotes for identifiers' AS solution;

-- 错误码 1000: "Network error"
-- 【原理】网络通信错误，连接中断。
-- 【场景】网络不稳定，连接被重置
-- 【修复】检查网络连通性，增加超时时间
SELECT
    'Error 1000: Network error' AS error_code,
    'Network communication failed' AS description,
    'Check network connectivity' AS solution;

-- 错误码 1001: "Cannot connect to server"
-- 【原理】无法连接到 ClickHouse 服务器。
-- 【场景】服务未启动、端口错误、防火墙阻止
-- 【修复】检查服务状态、端口和防火墙配置
SELECT
    'Error 1001: Cannot connect' AS error_code,
    'Server connection failed' AS description,
    'Check server status, port, and firewall' AS solution;

-- 错误码 1002: "Connection was refused"
-- 【原理】连接被服务器拒绝。
-- 【场景】服务器拒绝连接，可能负载过高或配置限制
-- 【修复】检查服务器负载，确认连接数限制
SELECT
    'Error 1002: Connection refused' AS error_code,
    'Server refused connection' AS description,
    'Check server load and connection limits' AS solution;

-- 错误码 1003: "Connection was lost"
-- 【原理】已建立的连接在通信过程中中断。
-- 【场景】查询执行过程中连接断开
-- 【修复】检查网络稳定性，调整超时时间
SELECT
    'Error 1003: Connection lost' AS error_code,
    'Connection interrupted during communication' AS description,
    'Check network stability and timeout settings' AS solution;

-- 错误码 1005: "Session not found"
-- 【原理】HTTP 会话已过期或不存在。
-- 【场景】使用 HTTP 接口时 session_id 无效
-- 【修复】重新获取 session_id 或创建新会话
SELECT
    'Error 1005: Session not found' AS error_code,
    'HTTP session expired or invalid' AS description,
    'Recreate session' AS solution;

-- 错误码 1006: "Session is expired"
-- 【原理】HTTP 会话已过期，需要重新认证。
-- 【场景】长时间未操作后会话过期
-- 【修复】重新认证获取新会话
SELECT
    'Error 1006: Session expired' AS error_code,
    'HTTP session has expired' AS description,
    'Re-authenticate to get new session' AS solution;

-- 错误码 1010: "ZK/Keeper error"
-- 【原理】ZooKeeper 或 ClickHouse Keeper 操作失败。
-- 【场景】复制表操作失败，ZK 会话超时
-- 【修复】检查 ZK/Keeper 状态，恢复连接
SELECT
    'Error 1010: ZK/Keeper error' AS error_code,
    'ZooKeeper or Keeper operation failed' AS description,
    'Check ZK/Keeper cluster status' AS solution;

-- -----------------------------------------------------
-- 2. 错误码诊断查询
-- -----------------------------------------------------

-- 诊断：从日志中查看最近的错误码
SELECT
    event_time,
    level,
    logger_name,
    message
FROM system.text_log
WHERE level IN ('Error', 'Critical')
  AND event_time > now() - INTERVAL 1 DAY
ORDER BY event_time DESC
LIMIT 50;

-- 诊断：查询最近的查询错误
-- 【坑】演示集群禁用了 system.query_log（config.xml <query_log remove="1"/>），
--       改用 system.text_log（服务器日志，含异常文本）+ system.query_thread_log
SELECT
    event_time,
    level,
    logger_name,
    message
FROM system.text_log
WHERE (level = 'Error' OR level = 'Fatal')
  AND message LIKE '%Code:%'
  AND event_time > now() - INTERVAL 1 DAY
ORDER BY event_time DESC
LIMIT 50;

-- 诊断：按错误码分组统计
-- 从 text_log 的异常文本提取错误码（格式 "Code: 47"）
SELECT
    extractAllGroups(message, 'Code: (\\d+)')[1][1] AS error_code,
    count() AS occurrences,
    any(message) AS sample_error
FROM system.text_log
WHERE message LIKE '%Code: %'
  AND event_time > now() - INTERVAL 7 DAY
GROUP BY error_code
ORDER BY occurrences DESC;

-- 诊断：查看致命错误
SELECT
    event_time,
    level,
    logger_name,
    message
FROM system.text_log
WHERE level = 'Fatal'
  AND event_time > now() - INTERVAL 7 DAY
ORDER BY event_time DESC;

-- -----------------------------------------------------
-- 3. 错误码与版本对应关系
-- -----------------------------------------------------

--
-- 【对比】不同版本间错误码的变化:
--   - v20.x: 错误码 1000-1999 范围，部分错误码为内部使用
--   - v21.x: 新增错误码 500-999，细化错误分类
--   - v22.x: 错误码 1000+ 重新整理，删除了一些过时错误码
--   - v23.x: 新增错误码 632（Too many partitions）等
--   - v24.x: 错误码系统稳定，主要新增与云原生相关错误码
--
-- 错误码分类:
--   0-199:   系统级错误（内存、文件、IO）
--   200-399: 数据库对象错误（表、列、用户）
--   400-599: 数据操作错误（写入、读取、校验）
--   600-799: SQL 语法与解析错误
--   800-999: 复制与集群错误
--   1000-1999: 网络与协议错误
--   2000+:   内部错误（不应暴露给用户）
--

-- 诊断：按错误码范围统计
SELECT
    multiIf(
        toUInt16OrZero(error_code) BETWEEN 0 AND 199, 'System',
        toUInt16OrZero(error_code) BETWEEN 200 AND 399, 'Database Objects',
        toUInt16OrZero(error_code) BETWEEN 400 AND 599, 'Data Operations',
        toUInt16OrZero(error_code) BETWEEN 600 AND 799, 'SQL Parsing',
        toUInt16OrZero(error_code) BETWEEN 800 AND 999, 'Replication',
        toUInt16OrZero(error_code) BETWEEN 1000 AND 1999, 'Network',
        'Other'
    ) AS error_category,
    count() AS occurrences
FROM (
    SELECT extractAllGroups(message, 'Code: (\\d+)')[1][1] AS error_code
    FROM system.text_log
    WHERE message LIKE '%Code: %'
      AND event_time > now() - INTERVAL 7 DAY
)
WHERE error_code != ''
GROUP BY error_category
ORDER BY occurrences DESC;

-- -----------------------------------------------------
-- 清理测试环境
-- -----------------------------------------------------

DROP DATABASE IF EXISTS troubleshooting_test;

-- =====================================================
-- 附：错误码速查表
-- =====================================================
--
-- 错误码  | 含义                  | 常见原因                  | 修复方法
-- --------|-----------------------|---------------------------|---------------------------
-- 40      | Checksum mismatch     | 数据损坏                 | DETACH + ATTACH 重建
-- 60      | Table is read-only    | ZK 会话过期/磁盘满       | 恢复 ZK/清理磁盘
-- 117     | Unknown user          | 用户不存在               | 创建用户
-- 218     | Unknown packet        | 协议版本不匹配           | 升级客户端
-- 226     | No such table         | 表不存在                 | 检查表名
-- 242     | Too many queries      | 并发超限                 | 增加 max_concurrent_queries
-- 279     | No such column        | 列不存在                 | 检查列名
-- 319     | Unknown function      | 函数名错误               | 检查函数名
-- 359     | Authentication failed | 认证失败                 | 检查密码/IP
-- 395     | Cannot allocate memory| 内存不足                 | 增加内存/限流
-- 396     | Memory limit exceeded | 查询超内存               | 增加 max_memory_usage
-- 441     | No space left         | 磁盘满                   | 清理/扩容
-- 517     | Unknown engine        | 引擎名错误               | 检查引擎名
-- 519     | Table already exists  | 表已存在                 | 使用 IF NOT EXISTS
-- 621     | Duplicate column      | 列名重复                 | 修改列名
-- 628     | Unknown cluster       | 集群名错误               | 检查集群名
-- 632     | Too many partitions   | 分区数超限               | 优化分区策略
-- 642     | Illegal argument type | 参数类型错误             | 使用 CAST 转换
-- 651     | Unknown setting       | 配置项不存在             | 检查配置项
-- 652     | Cannot parse          | SQL 语法错误             | 修正 SQL
-- 653     | Unknown identifier    | 标识符无法识别           | 检查标识符
-- 681     | Timeout exceeded      | 查询超时                 | 增加超时/优化查询
-- 700     | Invalid identifier    | 标识符格式错误           | 使用引号包裹
-- 1000    | Network error         | 网络通信失败             | 检查网络
-- 1001    | Cannot connect        | 无法连接服务器           | 检查服务状态
-- 1002    | Connection refused    | 连接被拒绝               | 检查负载/限制
-- 1003    | Connection lost       | 连接中断                 | 检查网络
-- 1005    | Session not found     | 会话不存在               | 重新创建会话
-- 1006    | Session expired       | 会话过期                 | 重新认证
-- 1010    | ZK/Keeper error       | 协调服务错误             | 检查 ZK/Keeper
--
-- =====================================================