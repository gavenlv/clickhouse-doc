-- ============================================================
-- 文件: 03-engines/04_integration_engines.sql
-- 学习目标: 透彻理解集成引擎的适用场景、性能特性与陷阱
-- 深度标准: 原理 + 场景 + 对比 + 可运行（外部源示例为注释说明）
-- 集群: treasurycluster (CH 25.12.1.649, 单分片 2 副本)
-- 前置: 无（自包含测试数据，按顺序执行）
-- ============================================================
--
-- 本文件章节:
--   1.  集成引擎总览：何时用、何时不该用
--   2.  File 引擎：本地文件读写（可运行）
--   3.  file() 表函数：无需建表的临时读取（可运行）
--   4.  url() 表函数：远程 HTTP 数据查询（公网示例注释 + 本地回环演示）
--   5.  S3 引擎与 s3() 表函数：对象存储集成（注释说明 + 配置示例）
--   6.  HDFS 引擎：Hadoop 数据湖集成（注释说明）
--   7.  MySQL 引擎与 mysql() 表函数：联邦查询（注释说明 + 配置示例）
--   8.  PostgreSQL 引擎：PG 联邦（注释说明）
--   9.  Redis 引擎：KV 缓存查询（注释说明）
--  10.  Kafka 引擎：流式消费（注释说明 + 架构图）
--  11.  JDBC/ODBC 引擎：通用驱动集成（注释说明）
--  12.  跨系统数据同步模式（ETL 模板）
--  13.  清理
-- ============================================================
--
-- 【核心概念】
--   集成引擎 = 把外部数据源「包装成 ClickHouse 表」进行 SQL 查询
--   ① 引擎（CREATE TABLE ... ENGINE=...）— 持久化定义，可复用
--   ② 表函数（SELECT * FROM s3('...')）— 临时一次性查询，不持久化
--   共同特点：查询时实时拉取外部数据，不存储到本地
--   适用：联邦查询、临时数据探查；不适合：高频查询、大数据量
-- ============================================================

CREATE DATABASE IF NOT EXISTS engine_test ON CLUSTER 'treasurycluster';
USE engine_test;


-- ============================================================
-- 1. 集成引擎总览
-- ============================================================
-- 【原理】集成引擎不存数据，每次查询都实时访问外部源
--   ① 数据在远端 → 查询经过网络 → 延迟受网络 + 远端查询性能影响
--   ② 不能用 ClickHouse 的索引/分区/压缩优化
--   ③ 适合：联邦查询、临时探查、ETL 中转；不适合：高频/大数据
--
-- 【引擎 vs 表函数对比】
--   维度          | 引擎(CREATE TABLE)        | 表函数(SELECT FROM fn())
--   --------------|---------------------------|--------------------------
--   持久化        | ✅ 元数据存 system.tables | ❌ 仅当前查询
--   复用          | ✅ 多个查询共享            | ❌ 每次重写
--   权限管理      | ✅ 可 GRANT               | ❌ 需用户级权限
--   适合场景      | 高频联邦查询               | 临时探查、ETL 一次性
--
-- 【集成引擎选型决策表】
--   | 数据源        | 推荐引擎/函数              | 关键限制              |
--   |--------------|----------------------------|----------------------|
--   | 本地文件      | File / file()              | 受 user_files_path 限制 |
--   | 远程 HTTP    | URL / url()                | 受网络延迟影响        |
--   | S3/GCS       | S3 / s3()                  | 需 access_key/secret  |
--   | HDFS         | HDFS / hdfs()              | 需 Hadoop 客户端      |
--   | MySQL        | MySQL / mysql()            | 只读，性能受限于 MySQL |
--   | PostgreSQL   | PostgreSQL / postgresql()  | 只读，PG 表必须存在    |
--   | Redis        | Redis / redis()            | 仅 KV，不支持复杂查询  |
--   | Kafka        | Kafka                      | 仅消费，需物化视图落盘 |
--   | 通用 JDBC    | JDBC                       | 性能差，仅兼容性场景   |
--
-- 【坑★】
--   ① 误用集成引擎做高频查询 → 远端性能瓶颈，CH 加速优势消失
--   ② 误以为支持写入所有源 → 多数集成引擎只读（S3/HDFS/File 可写，MySQL/PG 只读）
--   ③ 误以为支持事务 → 集成引擎无事务，写入失败可能产生半截数据
--   ④ 误用 SELECT * 大数据量 → 一次性拉全表可能 OOM，应分批或用 WHERE 过滤


-- ============================================================
-- 2. File 引擎：本地文件读写（可运行）
-- ============================================================
-- 【原理】File 引擎把本地文件包装成表，可指定格式与（可选）路径
--   ① 不带 path 参数：文件落在 store/<uuid>/data.<ext>（按 UUID 隔离）
--      —— 这种模式 SELECT * FROM <table> 能查到，但 file() 表函数读不到
--   ② 带 path 参数（路径以 user_files_path 为根）：文件落在 user_files_path/<path>
--      —— 这种模式 file() 表函数也能读到，便于跨系统共享
--   本集群 user_files_path = /var/lib/clickhouse/user_files/
-- 【场景】
--   ① 数据导入导出中转：CSV/JSON/Parquet ↔ MergeTree
--   ② 与外部系统交换数据：通过共享文件系统
--   ③ 临时数据落盘：测试结果、ETL 中间态
-- 【支持的格式】CSV/TSV/JSONEachRow/Parquet/Native/Arrow/ORC 等 70+ 种
-- 【坑1】不带 path 写入时文件名固定为 data.<ext>，覆盖式写入（不追加）
-- 【坑2】DROP TABLE 不删数据文件，只删表定义
-- 【坑3】并发写入同表会冲突，需用 File 引擎 + Buffer 表模式
-- 【坑4】File 引擎表是本地表，不能用 ON CLUSTER（否则文件存到 UUID 路径）

DROP TABLE IF EXISTS integ_file_csv;
DROP TABLE IF EXISTS integ_file_json;
DROP TABLE IF EXISTS integ_file_parquet;

-- 2.1 CSV 格式（带 path，便于 file() 后续读取）
--   【关键】路径以 user_files_path 为根：integ_files/csv/data.csv
CREATE TABLE integ_file_csv (
    id UInt64,
    name String,
    value Float64,
    created_at DateTime DEFAULT now()
) ENGINE = File('CSV', 'integ_files/csv/data.csv');

INSERT INTO integ_file_csv (id, name, value) VALUES
    (1, 'Alice',   99.99),
    (2, 'Bob',     49.99),
    (3, 'Charlie', 149.99);

SELECT * FROM integ_file_csv ORDER BY id;

-- 2.2 JSONEachRow 格式（更灵活，支持嵌套）
CREATE TABLE integ_file_json (
    id UInt64,
    name String,
    value Float64
) ENGINE = File('JSONEachRow', 'integ_files/json/data.json');

INSERT INTO integ_file_json VALUES
    (1, 'Alice',   99.99),
    (2, 'Bob',     49.99);

SELECT * FROM integ_file_json ORDER BY id;

-- 2.3 Parquet 格式（列式+压缩，推荐大数据中转）
-- 【对比】
--   CSV          — 通用、文本、无压缩、行式 → 小数据交换
--   JSONEachRow  — 灵活、文本、无压缩、行式 → 半结构化数据
--   Parquet      — 列式、二进制、带压缩 → 大数据高效中转（推荐）
--   Native       — CH 专有二进制、列式 → CH→CH 最快
CREATE TABLE integ_file_parquet (
    id UInt64,
    name String,
    value Float64
) ENGINE = File('Parquet', 'integ_files/parquet/data.parquet');

INSERT INTO integ_file_parquet
SELECT number AS id, concat('name_', toString(number)), rand() * 1000
FROM numbers(1000);

SELECT count(), avg(value) FROM integ_file_parquet;

-- 2.4 文件存储大小对比（system.tables 的 total_bytes 反映文件大小）
SELECT
    name,
    engine,
    total_rows,
    formatReadableSize(total_bytes) AS file_size
FROM system.tables
WHERE database = 'engine_test' AND name LIKE 'integ_file_%'
ORDER BY total_bytes;

-- 2.5 查看物理文件路径（在容器内执行）
--   docker exec clickhouse-server-1 ls -la /var/lib/clickhouse/user_files/integ_files/csv/
--   docker exec clickhouse-server-1 ls -la /var/lib/clickhouse/user_files/integ_files/parquet/
--   预期：data.csv、data.json、data.parquet 三个文件


-- ============================================================
-- 3. file() 表函数：无需建表的临时读取（可运行）
-- ============================================================
-- 【原理】file('path', 'format', 'structure') 直接读取 user_files_path 下的文件
--   优点：无需 CREATE TABLE，一次性查询
--   缺点：每次查询都要解析格式，无元数据缓存
-- 【场景】临时探查文件内容、ETL 一次性导入
-- 【关键】路径必须以 user_files_path 为根；与 §2 File 引擎带 path 参数写入的文件位置一致

-- 3.1 读取刚才 File 引擎写入的 CSV 文件
SELECT * FROM file('integ_files/csv/data.csv', 'CSV', 'id UInt64, name String, value Float64, created_at DateTime')
ORDER BY id;

-- 3.2 读取 Parquet 文件（列式+压缩，更高效）
SELECT count(), min(value), max(value), avg(value)
FROM file('integ_files/parquet/data.parquet', 'Parquet', 'id UInt64, name String, value Float64');

-- 3.3 用 file() 把文件数据导入 MergeTree（典型 ETL 模式）
DROP TABLE IF EXISTS integ_imported ON CLUSTER 'treasurycluster' SYNC;

CREATE TABLE integ_imported ON CLUSTER 'treasurycluster' (
    id UInt64,
    name String,
    value Float64
) ENGINE = MergeTree()
ORDER BY id;

INSERT INTO integ_imported
SELECT id, name, value FROM file('integ_files/parquet/data.parquet', 'Parquet', 'id UInt64, name String, value Float64');

SELECT count(), avg(value) FROM integ_imported;


-- ============================================================
-- 4. url() 表函数：远程 HTTP 数据查询
-- ============================================================
-- 【原理】url('http://...', 'format', 'structure') 把 HTTP 响应包装成表
--   适合读取公开 API/RESTful 服务的数据
-- 【场景】
--   ① 拉取公开数据集（GitHub API、公开 CSV）
--   ② 探查 RESTful 服务返回的 JSON
--   ③ 定期 ETL：INSERT INTO ... SELECT * FROM url(...)
-- 【坑】
--   ① 网络延迟：每次查询都重新拉取，无缓存
--   ② 大响应体：可能 OOM，应限制大小或分页
--   ③ 认证：复杂认证（OAuth）需用 URL 引擎 + headers 配置
--   ④ 网络限制：本集群容器无公网访问，公网示例为注释，不能直接执行

-- 4.1 读取公开 CSV（注释示例，需公网访问）
-- SELECT count(), avg(value)
-- FROM url(
--     'https://example.com/data.csv',
--     'CSV',
--     'id UInt64, name String, value Float64'
-- );
--
-- -- 4.2 读取 JSON API（注释示例）
-- SELECT id, name
-- FROM url(
--     'https://api.example.com/users?page=1',
--     'JSONEachRow',
--     'id UInt64, name String'
-- );
--
-- -- 4.3 把 URL 数据导入 MergeTree（典型 ETL 模式）
-- INSERT INTO local_table
-- SELECT * FROM url('https://example.com/data.csv', 'CSV', '...');

-- 4.4 本地可运行：用 url() 读取 CH 自身的 HTTP 接口（同机回环）
--   CH 8123 端口可被 url() 表函数读取，演示联邦查询机制
SELECT count() AS rows_from_http
FROM url('http://localhost:8123/?query=SELECT%20number%20FROM%20numbers(10)%20FORMAT%20CSV', 'CSV', 'number UInt64');


-- ============================================================
-- 5. S3 引擎与 s3() 表函数：对象存储集成（注释说明 + 配置示例）
-- ============================================================
-- 【原理】S3 引擎/s3() 表函数直接读写 S3/GCS/MinIO/Azure Blob 兼容存储
--   ① 引擎持久化表定义，可复用
--   ② 表函数临时查询，灵活
--   ③ 支持 glob 模式读多个文件：s3('https://bucket/data/*.csv')
-- 【场景】
--   ① 数据湖架构：CH 查询 S3 上的 Parquet/CSV，无需导入
--   ② 冷热分层：热数据存本地 MergeTree，冷数据存 S3 + S3 引擎查询
--   ③ ETL 导入：INSERT INTO local_table SELECT * FROM s3(...)
-- 【性能】S3 是对象存储，吞吐高但延迟高（vs 本地 SSD）
--   适合大批量顺序读，不适合点查；Parquet 列式 + 谓词下推可大幅减少扫描量
-- 【坑1】每次查询都重新拉取，无本地缓存（除非配 disk_cache）
-- 【坑2】大文件可能 OOM，应分批或用 glob 分片
-- 【坑3】IAM Role / 临时凭证需要用 S3 表函数动态传入，不能硬编码

-- 5.1 S3 引擎建表（注释，需 AWS 凭证）
-- CREATE TABLE integ_s3_data ON CLUSTER 'treasurycluster' (
--     id UInt64,
--     event_type String,
--     amount Float64,
--     timestamp DateTime
-- ) ENGINE = S3(
--     'https://my-bucket.s3.us-east-1.amazonaws.com/events/data.parquet',
--     'AWS_ACCESS_KEY_ID',
--     'AWS_SECRET_ACCESS_KEY',
--     'Parquet'
-- );
--
-- -- 5.2 S3 表函数一次性查询（推荐，灵活）
-- SELECT event_type, count(), sum(amount)
-- FROM s3(
--     'https://my-bucket.s3.us-east-1.amazonaws.com/events/*.parquet',
--     'AWS_ACCESS_KEY_ID',
--     'AWS_SECRET_ACCESS_KEY',
--     'Parquet',
--     'id UInt64, event_type String, amount Float64, timestamp DateTime'
-- )
-- WHERE timestamp >= '2024-01-01'
-- GROUP BY event_type;
--
-- -- 5.3 S3 → ClickHouse 本地表 ETL（典型导入模式）
-- INSERT INTO local_events
-- SELECT * FROM s3(
--     'https://my-bucket.s3.us-east-1.amazonaws.com/events/2024-01.parquet',
--     'key', 'secret', 'Parquet',
--     'id UInt64, event_type String, amount Float64, timestamp DateTime'
-- );
--
-- -- 5.4 ClickHouse → S3 导出
-- INSERT INTO FUNCTION s3(
--     'https://my-bucket.s3.us-east-1.amazonaws.com/export/data.parquet',
--     'key', 'secret', 'Parquet'
-- )
-- SELECT * FROM local_events WHERE toDate(timestamp) = '2024-01-01';


-- ============================================================
-- 6. HDFS 引擎：Hadoop 数据湖集成（注释说明）
-- ============================================================
-- 【原理】HDFS 引擎直接读取 Hadoop HDFS 上的文件
--   ① 需要 Hadoop 客户端库（libhdfs3 或内置 Java HDFS）
--   ② 支持格式与 File/S3 相同（CSV/Parquet/ORC/...）
-- 【场景】传统 Hadoop 数据湖，已有 HDFS 数据想用 CH 查询
-- 【对比】vs S3：HDFS 是文件系统（强一致），S3 是对象存储（最终一致）
-- 【坑】需要 Hadoop 集群 + Kerberos 配置复杂；现代架构推荐用 S3/MinIO 替代

-- CREATE TABLE integ_hdfs_data ON CLUSTER 'treasurycluster' (
--     id UInt64,
--     data String,
--     timestamp DateTime
-- ) ENGINE = HDFS('hdfs://namenode:9000/path/to/data.parquet', 'Parquet');
--
-- -- Kerberos 认证：
-- CREATE TABLE integ_hdfs_kerb ON CLUSTER 'treasurycluster' (
--     id UInt64, data String
-- ) ENGINE = HDFS('hdfs://namenode:9000/path/data.parquet', 'Parquet')
-- SETTINGS hdfs_kerberos_keytab = '/path/to/keytab',
--          hdfs_kerberos_principal = 'user@REALM';


-- ============================================================
-- 7. MySQL 引擎与 mysql() 表函数：联邦查询（注释说明 + 配置示例）
-- ============================================================
-- 【原理】MySQL 引擎把远程 MySQL 表包装成 CH 表，查询时下发 SQL 到 MySQL
--   ① 只读：CH 不能写回 MySQL
--   ② WHERE 条件会下推到 MySQL，减少网络传输
--   ③ JOIN 操作在 CH 端执行（需把 MySQL 表数据拉到 CH）
-- 【场景】
--   ① 联邦查询：CH 大表 + MySQL 小表 JOIN（如用户元信息）
--   ② 数据迁移：INSERT INTO ch_table SELECT * FROM mysql_table
--   ③ 实时查询：MySQL 的事务数据需要 CH 的分析能力
-- 【坑1】大数据量 JOIN 会把 MySQL 全表拉到 CH，OOM 风险
-- 【坑2】MySQL 5.x 不支持某些 SQL 语法，下推可能失败
-- 【坑3】连接数受 MySQL max_connections 限制，高并发需配连接池

-- 7.1 MySQL 引擎建表
-- CREATE TABLE integ_mysql_users ON CLUSTER 'treasurycluster' (
--     id UInt64,
--     name String,
--     email String,
--     created_at DateTime
-- ) ENGINE = MySQL(
--     'mysql-host:3306',
--     'mydb',
--     'users',
--     'mysql_user',
--     'mysql_password'
-- );
--
-- -- 7.2 简单查询（WHERE 下推到 MySQL）
-- SELECT * FROM integ_mysql_users WHERE id = 100;
--
-- -- 7.3 JOIN 查询：CH 大表 + MySQL 小表
-- SELECT
--     e.event_id,
--     e.user_id,
--     u.name AS user_name,
--     e.amount
-- FROM events e                       -- CH 大表（本地）
-- LEFT JOIN integ_mysql_users u USING (user_id)  -- MySQL 小表（联邦）
-- WHERE e.timestamp >= '2024-01-01';
--
-- -- 7.4 mysql() 表函数（一次性查询）
-- SELECT count(*) FROM mysql(
--     'mysql-host:3306', 'mydb', 'users',
--     'mysql_user', 'mysql_password'
-- ) WHERE created_at >= '2024-01-01';


-- ============================================================
-- 8. PostgreSQL 引擎：PG 联邦（注释说明）
-- ============================================================
-- 【原理】同 MySQL 引擎，但对接 PostgreSQL，支持 PG schema
-- 【场景】PG 事务数据 + CH 分析查询
-- 【对比】vs MySQL：PG 支持更复杂的类型（JSONB/Array/UUID），CH 自动映射
-- 【坑】PG 表名大小写敏感，需用引号

-- CREATE TABLE integ_pg_orders ON CLUSTER 'treasurycluster' (
--     order_id UInt64,
--     customer_id UInt64,
--     amount Decimal(10,2),
--     status String
-- ) ENGINE = PostgreSQL(
--     'pg-host:5432',
--     'mydb',
--     'orders',
--     'pg_user',
--     'pg_password',
--     'public'  -- schema_name
-- );
--
-- -- 表函数
-- SELECT * FROM postgresql(
--     'pg-host:5432', 'mydb', 'orders',
--     'pg_user', 'pg_password', 'public'
-- ) WHERE status = 'paid';


-- ============================================================
-- 9. Redis 引擎：KV 缓存查询（注释说明）
-- ============================================================
-- 【原理】Redis 引擎把 Redis 中的 key/value 包装成表查询
--   ① 只读，不能写回 Redis
--   ② 支持结构：String/Hash/List/Set/ZSet
--   ③ 查询时按 key 查找，O(1) 复杂度
-- 【场景】
--   ① 缓存数据探查：检查 Redis 中的 session/feature flag
--   ② 补充字典：用户画像、商品标签（小数据 < 1GB）
-- 【坑】大数据量扫描会拖垮 Redis；只适合小数据查询

-- CREATE TABLE integ_redis_user ON CLUSTER 'treasurycluster' (
--     key String,
--     value String
-- ) ENGINE = Redis('redis-host:6379', '0', 'password');
--
-- -- Hash 结构
-- CREATE TABLE integ_redis_hash ON CLUSTER 'treasurycluster' (
--     key String,
--     field String,
--     value String
-- ) ENGINE = Redis('redis-host:6379', '0', 'password', 'hash');
--
-- SELECT * FROM integ_redis_user WHERE key = 'user:1001';


-- ============================================================
-- 10. Kafka 引擎：流式消费（注释说明 + 架构图）
-- ============================================================
-- 【原理】Kafka 引擎消费 Kafka topic，每条消息作为一行
--   ① 只消费，不生产（生产用 kafka 表函数或 Kafka Connect）
--   ② 必须配物化视图把数据落到 MergeTree，否则数据流过即丢
--   ③ 消费组 + topic + partition 决定并行度
--
-- 【典型架构】
--   Kafka topic ──> CH Kafka 引擎表（无存储）──> 物化视图 ──> MergeTree（持久化）
--
-- 【场景】实时事件流：用户行为、IoT、CDC
-- 【坑1】Kafka 引擎表本身不存数据，必须配 MV 落盘
-- 【坑2】消费偏移量提交：默认每批提交，宕机可能重复消费
-- 【坑3】Schema 变更需重建 Kafka 表 + MV（不能 ALTER）

-- 10.1 Kafka 引擎表（消费 raw 事件）
-- CREATE TABLE integ_kafka_events ON CLUSTER 'treasurycluster' (
--     event_id UInt64,
--     user_id UInt64,
--     event_type String,
--     event_data String,
--     timestamp DateTime
-- ) ENGINE = Kafka(
--     'kafka-broker:9092',
--     'events_topic',
--     'ch_consumer_group',
--     'JSONEachRow'
-- );
--
-- -- 10.2 物化视图：Kafka → MergeTree（必须！否则数据丢失）
-- CREATE MATERIALIZED VIEW integ_kafka_mv TO integ_kafka_target AS
-- SELECT * FROM integ_kafka_events;
--
-- -- 10.3 目标表（MergeTree 持久化）
-- CREATE TABLE integ_kafka_target ON CLUSTER 'treasurycluster' (
--     event_id UInt64,
--     user_id UInt64,
--     event_type String,
--     event_data String,
--     timestamp DateTime
-- ) ENGINE = ReplicatedMergeTree()
-- PARTITION BY toYYYYMM(timestamp)
-- ORDER BY (user_id, timestamp);


-- ============================================================
-- 11. JDBC/ODBC 引擎：通用驱动集成（注释说明）
-- ============================================================
-- 【原理】通过 JDBC/ODBC 驱动连接任意支持的数据源
--   ① JDBC 需要 clickhouse-jdbc-bridge 进程（独立部署）
--   ② ODBC 需要 unixODBC + 各数据库驱动
-- 【场景】连接非主流数据库（Oracle、SQL Server、SQLite 等）
-- 【坑】性能最差（多一层驱动转换），仅兼容性场景用

-- CREATE TABLE integ_jdbc_oracle ON CLUSTER 'treasurycluster' (
--     id UInt64,
--     name String
-- ) ENGINE = JDBC(
--     'jdbc:oracle:thin:@//oracle-host:1521/mydb',
--     'oracle_user',
--     'oracle_password',
--     'SELECT id, name FROM my_schema.my_table'
-- );


-- ============================================================
-- 12. 跨系统数据同步模式（ETL 模板）
-- ============================================================
-- 【模式1: 一次性导入】外部 → CH 本地表
--   INSERT INTO ch_local_table
--   SELECT * FROM external_engine_table WHERE <过滤>;
--
-- 【模式2: 增量同步】基于时间戳/版本号
--   INSERT INTO ch_local_table
--   SELECT * FROM mysql('host', 'db', 'table', 'u', 'p')
--   WHERE updated_at > (SELECT max(updated_at) FROM ch_local_table);
--
-- 【模式3: 物化视图 + Kafka】流式实时同步
--   Kafka topic → CH Kafka 表 → MV → MergeTree
--
-- 【模式4: 定期全量刷新】适用于小字典表
--   TRUNCATE TABLE ch_dim_table;
--   INSERT INTO ch_dim_table SELECT * FROM mysql(...);
--
-- 【模式5: 冷热分层】
--   热数据：本地 MergeTree（SSD）
--   冷数据：S3 引擎（对象存储）+ TTL 自动迁移


-- ============================================================
-- 13. 清理
-- ============================================================
-- File 引擎表是本地表，不用 ON CLUSTER
DROP TABLE IF EXISTS integ_file_csv;
DROP TABLE IF EXISTS integ_file_json;
DROP TABLE IF EXISTS integ_file_parquet;
-- MergeTree 目标表用 ON CLUSTER
DROP TABLE IF EXISTS integ_imported ON CLUSTER 'treasurycluster' SYNC;
-- 清理遗留的旧表（兼容历史版本）
DROP TABLE IF EXISTS file_data ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS file_json ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS file_perf ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS local_data ON CLUSTER 'treasurycluster' SYNC;


-- ============================================================
-- 14. 集成引擎最佳实践总结
-- ============================================================
-- 【选型决策树】
--   ① 是否需要联邦查询？
--      否 → 用 MergeTree 本地表（性能最优）
--      是 → ②
--   ② 数据量级？
--      < 1GB → MySQL/PG/Redis 引擎（小数据联邦）
--      > 1GB → ③ 用 ETL 导入到本地 MergeTree
--   ③ 数据源类型？
--      文件 → File / file()
--      对象存储 → S3 / s3()
--      关系库 → MySQL / PostgreSQL
--      缓存 → Redis
--      流 → Kafka + 物化视图
--      其他 → JDBC（最后选择）
--
-- 【性能优化】
--   ① 大数据 ETL：用 Parquet（列式+压缩），别用 CSV（行式无压缩）
--   ② S3 查询：开启 disk_cache 缓存热文件，避免重复拉取
--   ③ MySQL 联邦：把 MySQL 表当字典用，JOIN 前先在 CH 端过滤
--   ④ Kafka 消费：调大 max_block_size（默认 65536）提升吞吐
--   ⑤ 异步 ETL：用 INSERT INTO ... SELECT 异步执行，避免阻塞查询
--
-- 【生产铁律】
--   ① 高频查询的表必须落本地 MergeTree，不要直接查外部源
--   ② S3 数据用 Parquet + 分区路径（按年月分目录）+ glob 模式查询
--   ③ Kafka 必须 MV 落盘，引擎表本身不存数据
--   ④ MySQL/PG 联邦只用于小表 JOIN，大表必须 ETL 导入
--   ⑤ 所有集成引擎查询都要加超时（settings max_execution_time）
