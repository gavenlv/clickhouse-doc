-- ================================================
-- 06_data_migration.sql
-- ClickHouse 数据迁移示例
-- ================================================

-- ========================================
-- 0. 创建测试数据库和表
-- ========================================
CREATE DATABASE IF NOT EXISTS migration_test ON CLUSTER 'treasurycluster';

CREATE TABLE IF NOT EXISTS migration_test.users ON CLUSTER 'treasurycluster' (
    user_id UInt64,
    name String,
    email String,
    created_at DateTime DEFAULT now()
) ENGINE = ReplicatedMergeTree
PARTITION BY toYYYYMM(created_at)
ORDER BY user_id;

CREATE TABLE IF NOT EXISTS migration_test.users_new ON CLUSTER 'treasurycluster' (
    user_id UInt64,
    name String,
    email String,
    created_at DateTime DEFAULT now(),
    updated_at DateTime DEFAULT now()
) ENGINE = ReplicatedMergeTree
PARTITION BY toYYYYMM(created_at)
ORDER BY user_id;

-- ========================================
-- 1. 导出数据
-- ========================================

-- 导出为 TSV (Tab-Separated Values)
SELECT
    user_id,
    name,
    email,
    created_at
FROM migration_test.users
FORMAT TabSeparated;

/*
在宿主机执行导出:
curl -s "http://localhost:8123/?query=SELECT+user_id,name,email,created_at+FROM+migration_test.users+FORMAT+TabSeparated" \
  > users_export.tsv
*/

-- 导出为 CSV
SELECT
    user_id,
    name,
    email,
    created_at
FROM migration_test.users
FORMAT CSVWithNames;

/*
在宿主机执行导出:
curl -s "http://localhost:8123/?query=SELECT+user_id,name,email,created_at+FROM+migration_test.users+FORMAT+CSVWithNames" \
  > users_export.csv
*/

-- 导出为 JSON
SELECT
    user_id,
    name,
    email,
    created_at
FROM migration_test.users
FORMAT JSONEachRow;

/*
在宿主机执行导出:
curl -s "http://localhost:8123/?query=SELECT+user_id,name,email,created_at+FROM+migration_test.users+FORMAT+JSONEachRow" \
  > users_export.json
*/

-- 导出为 SQL INSERT 语句
SELECT
    user_id,
    name,
    email,
    created_at
FROM migration_test.users
FORMAT SQLInsert;

-- ========================================
-- 2. 导入数据
-- ========================================

-- 从 TSV 导入
/*
在宿主机执行导入:
curl -XPOST http://localhost:8123 --data-binary @users_export.tsv \
  --data "INSERT INTO migration_test.users FORMAT TabSeparated"
*/

-- 从 CSV 导入（需要跳过标题行）
/*
在宿主机执行导入:
cat users_export.csv | tail -n +2 | \
curl -XPOST http://localhost:8123 --data-binary @- \
  --data "INSERT INTO migration_test.users FORMAT CSV"
*/

-- 从 JSON 导入
/*
在宿主机执行导入:
curl -XPOST http://localhost:8123 --data-binary @users_export.json \
  --data "INSERT INTO migration_test.users FORMAT JSONEachRow"
*/

-- 从 SQL 导入
/*
在宿主机执行导入:
curl -XPOST http://localhost:8123 --data-binary @users_export.sql
*/

-- ========================================
-- 3. 使用远程表函数迁移
-- ========================================

-- 从另一个 ClickHouse 实例导入数据
/*
语法:
remote('host:port', database, table, 'user', 'password')

示例:
INSERT INTO target_db.users
SELECT * FROM remote('source-server:9000', source_db, users, 'default', '');
*/

-- 从多个源表合并数据
/*
INSERT INTO merged_db.users
SELECT * FROM remote('server1:9000', db1, users, 'default', '')
UNION ALL
SELECT * FROM remote('server2:9000', db2, users, 'default', '')
UNION ALL
SELECT * FROM remote('server3:9000', db3, users, 'default', '');
*/

-- ========================================
-- 4. 批量导入优化
-- ========================================

-- 使用大批量插入（更高效）
/*
CREATE TABLE IF NOT EXISTS migration_test.batch_import (
    id UInt64,
    data String,
    timestamp DateTime
) ENGINE = MergeTree()
ORDER BY id;

-- 分批导入
cat large_data.tsv | split -l 100000 - batch_
for batch in batch_*; do
  curl -XPOST http://localhost:8123 --data-binary @$batch \
    --data "INSERT INTO migration_test.batch_import FORMAT TabSeparated"
done
*/

-- 使用 INSERT SELECT 进行数据转换
/*
CREATE TABLE IF NOT EXISTS migration_test.source_data (
    raw_id String,
    raw_data String,
    raw_timestamp String
) ENGINE = MergeTree()
ORDER BY raw_id;

CREATE TABLE IF NOT EXISTS migration_test.target_data (
    id UInt64,
    data String,
    timestamp DateTime
) ENGINE = MergeTree()
ORDER BY id;

-- 数据类型转换和清洗
INSERT INTO migration_test.target_data
SELECT
    toUInt64(raw_id) as id,
    upper(raw_data) as data,
    parseDateTimeBestEffort(raw_timestamp) as timestamp
FROM migration_test.source_data
WHERE raw_id != '' AND raw_timestamp != '';
*/

-- ========================================
-- 5. 跨集群迁移 (CLICKHOUSE-COPIER)
-- ========================================

/*
ClickHouse-Copier 配置示例:

config.xml:
<config>
    <source>
        <remote_servers>
            <source_cluster>
                <shard>
                    <replica>
                        <host>source-server-1</host>
                        <port>9000</port>
                        <user>default</user>
                        <password></password>
                    </replica>
                </shard>
            </source_cluster>
        </remote_servers>
    </source>

    <destination>
        <remote_servers>
            <dest_cluster>
                <shard>
                    <replica>
                        <host>dest-server-1</host>
                        <port>9000</port>
                        <user>default</user>
                        <password></password>
                    </replica>
                </replica>
            </source_cluster>
        </remote_servers>
    </destination>

    <data>
        <tables>
            <table_cluster>
                <cluster_name>source_cluster</cluster_name>
                <database>source_db</database>
                <table>users</table>
            </table_cluster>
        </tables>
    </data>

    <settings>
        <max_threads>8</max_threads>
    </settings>
</config>

执行迁移:
clickhouse-copier --config config.xml --task-name migration_task
*/

-- ========================================
-- 6. 格式转换
-- ========================================

-- CSV 转 TSV
/*
awk 'NR>1 {gsub(/,/,"\t"); print}' input.csv > output.tsv
*/

-- JSON 转 TSV
/*
jq -r '[.id, .name, .email] | @tsv' input.json > output.tsv
*/

-- Excel 转 CSV (使用 LibreOffice)
/*
libreoffice --headless --convert-to csv input.xlsx
*/

-- ========================================
-- 7. 数据清洗
-- ========================================

-- 创建清洗表
CREATE TABLE IF NOT EXISTS migration_test.dirty_data (
    id UInt64,
    name String,
    email String,
    age String,
    created_at String
) ENGINE = MergeTree()
ORDER BY id;

-- 插入脏数据
INSERT INTO migration_test.dirty_data VALUES
(1, '  Alice  ', 'alice@example.com', '25', '2024-01-01'),
(2, 'Bob', 'bob@example', 'unknown', '2024-01-02'),
(3, 'Charlie', 'charlie@example.com', '30', 'invalid-date'),
(4, 'David', 'david@example.com', '35', '2024-01-04'),
(5, 'Eve', 'eve@example.com', '30', '2024-01-05');

-- 清洗数据：去除空格
CREATE TABLE IF NOT EXISTS migration_test.clean_data (
    id UInt64,
    name String,
    email String,
    age UInt8,
    created_at DateTime
) ENGINE = MergeTree()
ORDER BY id;

INSERT INTO migration_test.clean_data
SELECT
    id,
    trim(name) as name,
    email,
    if(age = 'unknown', NULL, toUInt8(age)) as age,
    if(created_at = 'invalid-date', NULL, parseDateTimeBestEffort(created_at)) as created_at
FROM migration_test.dirty_data
WHERE id IS NOT NULL;

-- 验证清洗结果
SELECT * FROM migration_test.clean_data;

-- ========================================
-- 8. 增量迁移
-- ========================================

-- 使用 max(timestamp) 进行增量迁移
/*
-- 首次全量迁移
INSERT INTO dest_db.users
SELECT * FROM remote('source:9000', source_db, users, 'default', '');

-- 增量迁移（只迁移新增数据）
INSERT INTO dest_db.users
SELECT * FROM remote('source:9000', source_db, users, 'default', '')
WHERE created_at > (SELECT max(created_at) FROM dest_db.users);
*/

-- 使用标记表追踪迁移进度
/*
CREATE TABLE IF NOT EXISTS migration_test.migration_log (
    source_table String,
    dest_table String,
    last_migrated_id UInt64,
    last_migrated_time DateTime,
    migration_status String
) ENGINE = MergeTree()
ORDER BY (source_table, dest_table);

-- 记录迁移进度
INSERT INTO migration_test.migration_log VALUES
('source_db.users', 'dest_db.users', 0, now(), 'in_progress');

-- 执行增量迁移
INSERT INTO dest_db.users
SELECT * FROM remote('source:9000', source_db, users, 'default', '')
WHERE id > (SELECT last_migrated_id FROM migration_test.migration_log
           WHERE source_table = 'source_db.users' AND dest_table = 'dest_db.users');

-- 更新迁移状态
UPDATE migration.migration_log
SET last_migrated_id = max(id),
    last_migrated_time = now(),
    migration_status = 'completed'
WHERE source_table = 'source_db.users' AND dest_table = 'dest_db.users';
*/

-- ========================================
-- 9. 验证迁移
-- ========================================

-- 对比源表和目标表的行数
/*
SELECT
    'Source' as source,
    count() as row_count
FROM remote('source:9000', source_db, users, 'default', '')

UNION ALL

SELECT
    'Destination',
    count()
FROM dest_db.users;
*/

-- 对比校验和
/*
SELECT
    'Source' as source,
    groupBitXor(cityHash64(*)) as checksum
FROM remote('source:9000', source_db, users, 'default', '')

UNION ALL

SELECT
    'Destination',
    groupBitXor(cityHash64(*))
FROM dest_db.users;
*/

-- 抽样对比
/*
SELECT
    'Source' as source,
    count() as sample_count,
    sum(value) as sum_value
FROM remote('source:9000', source_db, users, 'default', '')
TABLESAMPLE 0.01

UNION ALL

SELECT
    'Destination',
    count(),
    sum(value)
FROM dest_db.users
TABLESAMPLE 0.01;
*/

-- ========================================
-- 10. 性能优化
-- ========================================

-- 使用大批量插入
SET max_insert_block_size = 1048576;
SET max_threads = 8;

-- 禁用同步插入（提高速度）
SET wait_for_async_insert = 0;

-- 使用异步插入（ClickHouse 24.0+）
/*
SET async_insert = 1;
SET wait_for_async_insert = 0;
*/

-- 并行迁移多个表
/*
# 使用 GNU parallel 并行执行
cat tables.txt | parallel -j 4 "clickhouse-client --query 'INSERT INTO dest_db.{} SELECT * FROM remote(\"source:9000\", source_db, {}, \"default\", \"\")'"
*/

-- ========================================
-- 11. 错误处理
-- ========================================

-- 记录迁移错误
CREATE TABLE IF NOT EXISTS migration_test.migration_errors (
    error_time DateTime DEFAULT now(),
    source_table String,
    dest_table String,
    error_message String,
    error_code UInt32
) ENGINE = MergeTree()
ORDER BY error_time;

-- 捕获并记录错误
/*
ON ERROR
INSERT INTO migration_test.migration_errors (source_table, dest_table, error_message)
VALUES ('source_db.users', 'dest_db.users', 'Migration failed');
*/

-- 重试机制
/*
# 使用 shell 脚本实现重试
for i in {1..3}; do
  clickhouse-client --query "INSERT INTO dest_db.users SELECT * FROM remote('source:9000', source_db, users, 'default', '')"
  if [ $? -eq 0 ]; then
    break
  fi
  echo "Retry $i"
  sleep 5
done
*/

-- ========================================
-- 12. 回滚机制
-- ========================================

-- 迁移前备份
/*
-- 创建备份表
CREATE TABLE dest_db.users_backup AS dest_db.users;
INSERT INTO dest_db.users_backup SELECT * FROM dest_db.users;
*/

-- 如果迁移失败，回滚
/*
-- 删除迁移的数据
TRUNCATE TABLE dest_db.users;

-- 恢复备份
INSERT INTO dest_db.users SELECT * FROM dest_db.users_backup;
*/

-- 使用事务（ClickHouse 23.0+）
/*
BEGIN TRANSACTION;
INSERT INTO dest_db.users SELECT * FROM remote('source:9000', source_db, users, 'default', '');

-- 验证数据
SELECT count() FROM dest_db.users;

-- 如果验证失败，回滚
-- ROLLBACK;

-- 如果验证成功，提交
COMMIT;
*/

-- ========================================
-- 13. 监控迁移进度
-- ========================================

-- 查看正在进行的导入
SELECT
    query_id,
    query_start_time,
    elapsed,
    read_rows,
    written_rows,
    memory_usage
FROM system.processes
WHERE query LIKE 'INSERT INTO%'
ORDER BY query_start_time DESC;

-- 查看迁移历史
SELECT
    event_time,
    type,
    query_duration_ms,
    read_rows,
    written_rows,
    exception_text
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query LIKE 'INSERT INTO%'
  AND event_date >= today()
ORDER BY event_time DESC;

-- ========================================
-- 14. 清理测试数据
-- ========================================
DROP TABLE IF EXISTS migration_test.users;
DROP TABLE IF EXISTS migration_test.batch_import;
DROP TABLE IF EXISTS migration_test.source_data;
DROP TABLE IF EXISTS migration_test.target_data;
DROP TABLE IF EXISTS migration_test.dirty_data;
DROP TABLE IF EXISTS migration_test.clean_data;
DROP TABLE IF EXISTS migration_test.migration_log;
DROP TABLE IF EXISTS migration_test.migration_errors;
DROP DATABASE IF EXISTS migration_test;

-- ========================================
-- 15. 数据迁移最佳实践总结
-- ========================================
/*
数据迁移最佳实践：

1. 迁移准备
   - 评估数据量和迁移时间
   - 制定详细的迁移计划
   - 备份源数据和目标数据
   - 准备回滚方案

2. 迁移策略
   - 全量迁移 vs 增量迁移
   - 在线迁移 vs 离线迁移
   - 大批量并行迁移
   - 分批次迁移

3. 工具选择
   - clickhouse-copier：推荐用于跨集群
   - remote() 函数：简单场景
   - 导出导入：小数据量
   - 第三方工具：特定需求

4. 性能优化
   - 使用大批量插入
   - 并行执行多个表
   - 调整插入块大小
   - 使用异步插入

5. 数据验证
   - 对比行数
   - 计算校验和
   - 抽样对比
   - 业务验证

6. 错误处理
   - 记录迁移日志
   - 实现重试机制
   - 设置告警
   - 准备应急预案

7. 监控告警
   - 监控迁移进度
   - 监控资源使用
   - 监控错误率
   - 实时反馈

8. 切换方案
   - 灰度切换
   - 双写验证
   - 快速回滚
   - 业务最小化影响
*/
