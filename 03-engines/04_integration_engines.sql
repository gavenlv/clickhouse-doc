-- ================================================
-- 04_integration_engines.sql
-- ClickHouse 集成系列引擎示例
-- ================================================

-- ========================================
-- 0. 创建测试数据库
-- ========================================
CREATE DATABASE IF NOT EXISTS engine_test ON CLUSTER 'treasurycluster';

-- ========================================
-- 1. URL（远程数据引擎）
-- ========================================

-- 使用 URL 引擎读取远程文件
-- 注意：这需要外部可访问的 URL

-- 示例：读取远程 CSV 文件
/*
CREATE TABLE IF NOT EXISTS engine_test.url_data (
    id UInt64,
    name String,
    value Float64
) ENGINE = URL('https://example.com/data.csv', CSV);

-- 查询远程数据
SELECT * FROM engine_test.url_data;

-- 示例：读取远程 JSON 文件
CREATE TABLE IF NOT EXISTS engine_test.url_json (
    id UInt64,
    data String
) ENGINE = URL('https://example.com/data.json', JSONEachRow);

-- 示例：使用用户认证
CREATE TABLE IF NOT EXISTS engine_test.url_auth (
    id UInt64,
    data String
) ENGINE = URL(
    'https://example.com/secure_data.csv',
    CSV,
    'username',
    'password'
);
*/

-- ========================================
-- 2. File（本地文件引擎）
-- ========================================

-- 创建 File 引擎表
CREATE TABLE IF NOT EXISTS engine_test.file_data (
    id UInt64,
    name String,
    value Float64,
    created_at DateTime DEFAULT now()
) ENGINE = File('CSV');

-- 插入数据（会写入到 /var/lib/clickhouse/user_files/engine_test/file_data.csv）
INSERT INTO engine_test.file_data (id, name, value) VALUES
(1, 'Alice', 99.99),
(2, 'Bob', 49.99),
(3, 'Charlie', 149.99);

-- 查询数据
SELECT * FROM engine_test.file_data;

-- 创建不同格式的 File 表
CREATE TABLE IF NOT EXISTS engine_test.file_json (
    id UInt64,
    name String,
    value Float64
) ENGINE = File('JSONEachRow');

INSERT INTO engine_test.file_json VALUES
(1, 'Alice', 99.99),
(2, 'Bob', 49.99);

SELECT * FROM engine_test.file_json;

-- ========================================
-- 3. HDFS（Hadoop 集成引擎）
-- ========================================

/*
注意：使用 HDFS 引擎需要配置 Hadoop 客户端

创建 HDFS 表:
CREATE TABLE IF NOT EXISTS engine_test.hdfs_data (
    id UInt64,
    data String,
    timestamp DateTime
) ENGINE = HDFS('hdfs://namenode:9000/path/to/data.csv', 'CSV');

-- 查询 HDFS 数据
SELECT * FROM engine_test.hdfs_data WHERE id > 100;

-- 写入 HDFS
INSERT INTO engine_test.hdfs_data
SELECT number, concat('data_', toString(number)), now()
FROM numbers(1000);

-- 使用 Kerberos 认证
CREATE TABLE IF NOT EXISTS engine_test.hdfs_kerberos (
    id UInt64,
    data String
) ENGINE = HDFS(
    'hdfs://namenode:9000/path/to/data',
    'CSV',
    'hdfs_user'
);

-- 使用 ZooKeeper 认证
CREATE TABLE IF NOT EXISTS engine_test.hdfs_zk (
    id UInt64,
    data String
) ENGINE = HDFS(
    'hdfs://namenode:9000/path/to/data',
    'CSV'
)
SETTINGS(
    'hdfs_kerberos_keytab' = '/path/to/keytab',
    'hdfs_kerberos_principal' = 'user@REALM'
);
*/

-- ========================================
-- 4. S3（AWS S3 集成引擎）
-- ========================================

/*
注意：使用 S3 引擎需要配置 AWS 凭证

创建 S3 表:
CREATE TABLE IF NOT EXISTS engine_test.s3_data (
    id UInt64,
    data String,
    timestamp DateTime
) ENGINE = S3(
    'https://bucket-name.s3.region.amazonaws.com/data.csv',
    'AWS_ACCESS_KEY_ID',
    'AWS_SECRET_ACCESS_KEY'
);

-- 查询 S3 数据
SELECT * FROM engine_test.s3_data WHERE id > 100;

-- 使用 IAM 角色
CREATE TABLE IF NOT EXISTS engine_test.s3_iam (
    id UInt64,
    data String
) ENGINE = S3(
    'https://bucket-name.s3.region.amazonaws.com/data.csv'
);

-- 查询特定对象
CREATE TABLE IF NOT EXISTS engine_test.s3_object (
    id UInt64,
    data String
) ENGINE = S3(
    'https://bucket-name.s3.region.amazonaws.com/path/to/object.csv'
);

-- 查询多个文件（通配符）
CREATE TABLE IF NOT EXISTS engine_test.s3_glob (
    id UInt64,
    data String
) ENGINE = S3(
    'https://bucket-name.s3.region.amazonaws.com/data/*.csv'
);

-- 写入 S3
INSERT INTO engine_test.s3_data
SELECT number, concat('data_', toString(number)), now()
FROM numbers(1000);
*/

-- ========================================
-- 5. MySQL（数据库集成引擎）
-- ========================================

/*
注意：使用 MySQL 引擎需要配置 MySQL 数据库

创建 MySQL 表:
CREATE TABLE IF NOT EXISTS engine_test.mysql_data (
    id UInt64,
    name String,
    value Float64
) ENGINE = MySQL(
    'mysql-host:3306',
    'database_name',
    'table_name',
    'mysql_user',
    'mysql_password'
);

-- 查询 MySQL 数据
SELECT * FROM engine_test.mysql_data WHERE value > 100;

-- 连接查询
SELECT
    m.id,
    m.name,
    m.value,
    c.category
FROM engine_test.mysql_data m
LEFT JOIN engine_test.local_category c ON m.id = c.id;

-- 使用远程 MySQL 查询（不需要创建表）
SELECT * FROM
mysql('mysql-host:3306', 'database_name', 'table_name', 'user', 'password')
WHERE value > 100;
*/

-- ========================================
-- 6. PostgreSQL（数据库集成引擎）
-- ========================================

/*
注意：使用 PostgreSQL 引擎需要配置 PostgreSQL 数据库

创建 PostgreSQL 表:
CREATE TABLE IF NOT EXISTS engine_test.pg_data (
    id UInt64,
    name String,
    value Float64
) ENGINE = PostgreSQL(
    'postgresql-host:5432',
    'database_name',
    'table_name',
    'pg_user',
    'pg_password',
    'schema_name'
);

-- 查询 PostgreSQL 数据
SELECT * FROM engine_test.pg_data WHERE value > 100;

-- 使用远程 PostgreSQL 查询
SELECT * FROM
postgresql('postgresql-host:5432', 'database_name', 'table_name', 'user', 'password')
WHERE value > 100;
*/

-- ========================================
-- 7. Redis（缓存集成引擎）
-- ========================================

/*
注意：使用 Redis 引擎需要配置 Redis 服务器

创建 Redis 表:
CREATE TABLE IF NOT EXISTS engine_test.redis_data (
    key String,
    value String
) ENGINE = Redis(
    'redis-host:6379',
    'db_index',
    'password'
);

-- 查询 Redis 数据
SELECT * FROM engine_test.redis_data WHERE key LIKE 'user:*';

-- 使用 Redis 结构
CREATE TABLE IF NOT EXISTS engine_test.redis_hash (
    key String,
    field String,
    value String
) ENGINE = Redis(
    'redis-host:6379',
    'db_index',
    '',
    'hash_structure'
);

-- 查询 Redis Hash
SELECT * FROM engine_test.redis_hash WHERE key = 'user:1';
*/

-- ========================================
-- 8. 集成引擎性能测试
-- ========================================

-- 创建本地表作为基准
CREATE TABLE IF NOT EXISTS engine_test.local_data (
    id UInt64,
    data String,
    value Float64,
    timestamp DateTime
) ENGINE = MergeTree()
ORDER BY id;

-- 插入测试数据
INSERT INTO engine_test.local_data SELECT
    number as id,
    repeat('test data ', 5) as data,
    rand() * 1000 as value,
    now() - INTERVAL rand() * 30 DAY as timestamp
FROM numbers(10000);

-- File 引擎性能测试
CREATE TABLE IF NOT EXISTS engine_test.file_perf (
    id UInt64,
    data String,
    value Float64,
    timestamp DateTime
) ENGINE = File('CSV');

INSERT INTO engine_test.file_perf SELECT * FROM engine_test.local_data;

-- 查询性能对比
SELECT 'MergeTree' as engine, count(*) as cnt, avg(value) as avg_val FROM engine_test.local_data
UNION ALL
SELECT 'File', count(*), avg(value) FROM engine_test.file_perf;

-- ========================================
-- 9. 数据导入导出示例
-- ========================================

-- 从 CSV 文件导入
/*
方法 1：使用 File 引擎
CREATE TABLE IF NOT EXISTS engine_test.import_csv (
    id UInt64,
    name String,
    value Float64
) ENGINE = File('CSV');

-- 复制 CSV 文件到 /var/lib/clickhouse/user_files/engine_test/import_csv.csv

-- 查询数据
SELECT * FROM engine_test.import_csv;

方法 2：使用 INSERT SELECT
INSERT INTO target_table
SELECT *
FROM file('/path/to/data.csv', 'CSV');
*/

-- 导出为 CSV
/*
方法 1：使用 File 引擎
CREATE TABLE IF NOT EXISTS engine_test.export_csv AS source_table
ENGINE = File('CSV');

-- 数据会写入到 /var/lib/clickhouse/user_files/engine_test/export_csv.csv

方法 2：使用 SELECT INTO OUTFILE
SELECT * FROM source_table
INTO OUTFILE '/path/to/output.csv'
FORMAT CSVWithNames;
*/

-- ========================================
-- 10. 跨系统数据同步
-- ========================================

/*
场景 1：MySQL → ClickHouse
CREATE TABLE IF NOT EXISTS engine_test.mysql_sync AS
mysql('mysql-host:3306', 'db', 'table', 'user', 'pass');

CREATE TABLE IF NOT EXISTS engine_test.ch_data AS mysql_sync
ENGINE = MergeTree()
ORDER BY id;

-- 同步数据
INSERT INTO engine_test.ch_data
SELECT * FROM engine_test.mysql_sync;

场景 2：PostgreSQL → ClickHouse
CREATE TABLE IF NOT EXISTS engine_test.pg_sync AS
postgresql('pg-host:5432', 'db', 'table', 'user', 'pass');

INSERT INTO engine_test.ch_data
SELECT * FROM engine_test.pg_sync;

场景 3：S3 → ClickHouse
CREATE TABLE IF NOT EXISTS engine_test.s3_sync AS
s3('https://bucket.s3.region.amazonaws.com/data/*.csv');

INSERT INTO engine_test.ch_data
SELECT * FROM engine_test.s3_sync;
*/

-- ========================================
-- 11. 外部数据函数
-- ========================================

/*
使用外部数据函数（不需要创建表）

-- MySQL
SELECT * FROM
mysql('host:3306', 'db', 'table', 'user', 'pass')
WHERE condition;

-- PostgreSQL
SELECT * FROM
postgresql('host:5432', 'db', 'table', 'user', 'pass')
WHERE condition;

-- Redis
SELECT * FROM
redis('host:6379', 'db', 'password')
WHERE key LIKE 'pattern:*';

-- S3
SELECT * FROM
s3('https://bucket.s3.region.amazonaws.com/path/*.csv')
WHERE condition;

-- HDFS
SELECT * FROM
hdfs('namenode:9000/path/to/data.csv', 'CSV')
WHERE condition;

-- URL
SELECT * FROM
url('https://example.com/data.csv', 'CSV')
WHERE condition;

-- File
SELECT * FROM
file('/path/to/data.csv', 'CSV')
WHERE condition;
*/

-- ========================================
-- 12. 清理测试表
-- ========================================
DROP TABLE IF EXISTS engine_test.file_data;
DROP TABLE IF EXISTS engine_test.file_json;
DROP TABLE IF EXISTS engine_test.file_perf;
DROP TABLE IF EXISTS engine_test.local_data;

-- ========================================
-- 13. 集成引擎最佳实践总结
-- ========================================
/*
集成引擎最佳实践：

1. URL 引擎
   - 适用场景：读取公开数据文件
   - 优点：无需下载，直接查询
   - 缺点：需要网络访问，性能较差

2. File 引擎
   - 适用场景：本地文件导入导出、数据交换
   - 优点：简单易用，支持多种格式
   - 缺点：不适合频繁查询

3. HDFS 引擎
   - 适用场景：大数据湖、Hadoop 生态集成
   - 优点：直接访问 HDFS 数据
   - 缺点：需要 Hadoop 配置

4. S3 引擎
   - 适用场景：云存储、数据湖架构
   - 优点：直接访问 S3 对象
   - 缺点：需要 AWS 配置

5. MySQL/PostgreSQL 引擎
   - 适用场景：实时数据同步、跨系统查询
   - 优点：直接查询外部数据库
   - 缺点：性能受限，不适合大数据量

6. Redis 引擎
   - 适用场景：缓存数据访问
   - 优点：快速访问 Redis 数据
   - 缺点：只适合简单查询

选择建议：
- 数据导入导出：File 引擎
- 云数据：S3 引擎
- 大数据：HDFS 引擎
- 跨系统查询：MySQL/PostgreSQL 引擎
- 缓存：Redis 引擎
- 公开数据：URL 引擎

性能优化：
1. 减少跨系统查询频率
2. 使用定时任务同步数据
3. 预先加载热点数据
4. 合理使用缓存
*/
