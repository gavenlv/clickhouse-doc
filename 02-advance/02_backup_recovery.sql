-- ================================================
-- 02_backup_recovery.sql
-- ClickHouse 备份和恢复示例
-- ================================================

-- ========================================
-- 0. 创建测试数据库
-- ========================================
CREATE DATABASE IF NOT EXISTS backup_test ON CLUSTER 'treasurycluster';

-- ========================================
-- 1. 创建测试数据
-- ========================================

-- 创建测试表
CREATE TABLE IF NOT EXISTS backup_test.users (
    user_id UInt64,
    name String,
    email String,
    created_at DateTime DEFAULT now()
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(created_at)
ORDER BY user_id;

-- 创建测试订单表
CREATE TABLE IF NOT EXISTS backup_test.orders (
    order_id UInt64,
    user_id UInt64,
    product_id UInt32,
    amount Decimal(10, 2),
    order_date DateTime DEFAULT now()
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(order_date)
ORDER BY (user_id, order_id);

-- 插入测试数据
INSERT INTO backup_test.users (user_id, name, email) VALUES
(1, 'Alice', 'alice@example.com'),
(2, 'Bob', 'bob@example.com'),
(3, 'Charlie', 'charlie@example.com');

INSERT INTO backup_test.orders (order_id, user_id, product_id, amount) VALUES
(1001, 1, 101, 99.99),
(1002, 1, 102, 49.99),
(1003, 2, 103, 199.99),
(1004, 3, 104, 149.99);

-- 查看数据
SELECT 'Users:' as table_name, count() as count FROM backup_test.users
UNION ALL
SELECT 'Orders:', count() FROM backup_test.orders;

-- ========================================
-- 2. 使用 CLICKHOUSE-BACKUP 工具
-- ========================================

/*
注意：以下命令需要在宿主机上执行，不是在 ClickHouse SQL 客户端中

安装 clickhouse-backup:
# Linux
curl -s https://clickhouse.com/download | sh
./clickhouse install clickhouse-backup

# 或使用 Go 安装
go install github.com/AlexAkulov/clickhouse-backup@latest

配置 clickhouse-backup:
编辑 /etc/clickhouse-backup/config.yml

主要配置项:
general:
  remote_storage: s3  # 或 none, gcs, ftp, sftp
  backups_to_keep_local: 7
  backups_to_keep_remote: 30

clickhouse:
  username: default
  password: ""
  host: localhost
  port: 9000

s3:
  access_key: "your-access-key"
  secret_key: "your-secret-key"
  bucket: "clickhouse-backups"
  path: "backups"
*/

-- ========================================
-- 3. 使用 FREEZE 备份
-- ========================================

-- FREEZE 表（创建表数据的硬链接快照）
-- 这不会锁定表，不会影响读写操作

-- 备份单个表
ALTER TABLE backup_test.users FREEZE;

-- 备份整个数据库
-- 需要为每个表执行 FREEZE
-- 或使用 clickhouse-backup 工具

-- 查看快照位置
-- 在 Linux 上，快照通常位于: /var/lib/clickhouse/shadow/
-- 在 Docker 中，快照位于: /var/lib/clickhouse/shadow/

/*
在宿主机上查看快照:
docker exec clickhouse-server-1 ls -la /var/lib/clickhouse/shadow/

复制快照到备份位置:
docker exec clickhouse-server-1 cp -r /var/lib/clickhouse/shadow/ /backup/clickhouse/

删除快照（如果不需要）:
docker exec clickhouse-server-1 rm -rf /var/lib/clickhouse/shadow/
*/

-- ========================================
-- 4. 使用数据导出备份
-- ========================================

-- 导出表数据为 TSV 格式
SELECT * FROM backup_test.users FORMAT TabSeparated;

/*
在宿主机上执行导出:
curl -s "http://localhost:8123/?query=SELECT+*+FROM+backup_test.users+FORMAT+TabSeparated" \
  > backup_users.tsv

导出为 CSV:
curl -s "http://localhost:8123/?query=SELECT+*+FROM+backup_test.users+FORMAT+CSVWithNames" \
  > backup_users.csv

导出为 JSON:
curl -s "http://localhost:8123/?query=SELECT+*+FROM+backup_test.users+FORMAT+JSONEachRow" \
  > backup_users.json
*/

-- 导出表结构
SHOW CREATE TABLE backup_test.users;

/*
在宿主机上执行:
curl -s "http://localhost:8123/?query=SHOW+CREATE+TABLE+backup_test.users" \
  > backup_users_schema.sql
*/

-- ========================================
-- 5. 使用 INSERT SELECT 备份
-- ========================================

-- 创建备份表（复制结构）
CREATE TABLE backup_test.users_backup_20240119 AS backup_test.users
ENGINE = MergeTree()
PARTITION BY toYYYYMM(created_at)
ORDER BY user_id;

-- 复制数据
INSERT INTO backup_test.users_backup_20240119
SELECT * FROM backup_test.users;

-- 验证备份数据
SELECT count() FROM backup_test.users_backup_20240119;

-- ========================================
-- 6. 分区级备份
-- ========================================

-- 备份特定分区
-- 首先查看表的分区
SELECT
    partition,
    name,
    rows,
    bytes_on_disk
FROM system.parts
WHERE table = 'backup_test.orders'
  AND database = 'backup_test'
  AND active = 1;

-- 使用 DETACH 分离分区（安全移除，保留数据）
-- ALTER TABLE backup_test.orders DETACH PARTITION '202401';

-- 在宿主机上备份分离的分区数据
/*
docker exec clickhouse-server-1 cp -r \
  /var/lib/clickhouse/data/backup_test/orders/detached/ \
  /backup/clickhouse/orders_partition_202401/
*/

-- 恢复分区
-- ALTER TABLE backup_test.orders ATTACH PARTITION '202401';

-- ========================================
-- 7. 增量备份策略
-- ========================================

/*
增量备份实现思路:

1. 基于分区：
   - 每次只备份新增的分区
   - 定期清理旧分区备份

2. 基于时间：
   - 全量备份：每月一次
   - 增量备份：每天一次
   - 日志备份：每小时一次

3. 使用 binlog:
   - 启用 query_log
   - 定期备份查询日志
   - 需要时重放查询
*/

-- 示例：按时间范围导出增量数据
/*
导出今天的新数据:
curl -s "http://localhost:8123/?query=SELECT+*+FROM+backup_test.orders+WHERE+order_date+%3E=+today()FORMAT+TabSeparated" \
  > backup_orders_incremental_$(date +%Y%m%d).tsv
*/

-- ========================================
-- 8. 数据恢复示例
-- ========================================

-- 场景 1: 从备份表恢复
-- 确保目标表结构一致或先创建表

-- 先删除表（模拟数据丢失）
-- DROP TABLE backup_test.users;

-- 从备份恢复
-- CREATE TABLE backup_test.users AS backup_test.users_backup_20240119;
-- INSERT INTO backup_test.users SELECT * FROM backup_test.users_backup_20240119;

-- 场景 2: 从导出文件恢复
/*
先恢复表结构:
curl -XPOST http://localhost:8123 --data-binary @backup_users_schema.sql

再恢复数据:
curl -XPOST http://localhost:8123 --data-binary @backup_users.tsv \
  --data "INSERT INTO backup_test.users FORMAT TabSeparated"
*/

-- 场景 3: 使用 ATTACH 恢复分离的分区
-- 假设之前 DETACH 了分区，现在需要恢复
-- ALTER TABLE backup_test.orders ATTACH PARTITION '202401';

-- ========================================
-- 9. 跨集群数据迁移
-- ========================================

/*
使用 clickhouse-copier 迁移数据:

1. 创建配置文件 (config.xml):
<clickhouse>
    <source>
        <host>source-host</host>
        <port>9000</port>
        <user>default</user>
        <password></password>
    </source>
    <destination>
        <host>dest-host</host>
        <port>9000</port>
        <user>default</user>
        <password></password>
    </destination>
    <tables>
        <table_cluster>
            <cluster_name>source_cluster</cluster_name>
            <database>backup_test</database>
            <table>users</table>
        </table_cluster>
    </tables>
</clickhouse>

2. 执行迁移:
clickhouse-copier --config config.xml --task-name task1
*/

-- 使用远程表函数迁移数据
-- INSERT INTO backup_test.users SELECT * FROM remote('source-host:9000', backup_test, users, 'default', '');

-- ========================================
-- 10. 数据校验
-- ========================================

-- 校验数据完整性
SELECT
    'Original' as source,
    count() as total_users
FROM backup_test.users

UNION ALL

SELECT
    'Backup',
    count()
FROM backup_test.users_backup_20240119;

-- 校验数据一致性
SELECT
    o.user_id,
    o.name,
    o.email,
    b.user_id as backup_id,
    b.name as backup_name,
    b.email as backup_email
FROM backup_test.users o
FULL OUTER JOIN backup_test.users_backup_20240119 b
  ON o.user_id = b.user_id
WHERE o.user_id IS NULL OR b.user_id IS NULL
  OR o.name != b.name
  OR o.email != b.email;

-- ========================================
-- 11. 定时备份脚本示例
-- ========================================

/*
#!/bin/bash
# backup_daily.sh - 每日备份脚本

BACKUP_DIR="/backup/clickhouse/daily"
DATE=$(date +%Y%m%d)
LOG_FILE="/var/log/clickhouse-backup.log"

# 创建备份目录
mkdir -p $BACKUP_DIR

# 导出表结构
for table in users orders; do
  echo "[$(date)] Backing up backup_test.$table" >> $LOG_FILE
  curl -s "http://localhost:8123/?query=SHOW+CREATE+TABLE+backup_test.$table" \
    > $BACKUP_DIR/${table}_schema_${DATE}.sql

  # 导出数据
  curl -s "http://localhost:8123/?query=SELECT+*+FROM+backup_test.$table+FORMAT+TabSeparated" \
    > $BACKUP_DIR/${table}_data_${DATE}.tsv

  echo "[$(date)] Backup completed for backup_test.$table" >> $LOG_FILE
done

# 压缩备份
cd $BACKUP_DIR
tar -czf clickhouse_backup_${DATE}.tar.gz *_schema_${DATE}.sql *_data_${DATE}.tsv

# 清理 7 天前的备份
find $BACKUP_DIR -name "*.tar.gz" -mtime +7 -delete

echo "[$(date)] Daily backup completed" >> $LOG_FILE
*/

-- ========================================
-- 12. 监控备份状态
-- ========================================

-- 查看最近的数据修改时间
SELECT
    database,
    table,
    partition,
    max(modification_time) as last_modified,
    formatReadableSize(sum(bytes_on_disk)) as total_size
FROM system.parts
WHERE database = 'backup_test'
  AND active = 1
GROUP BY database, table, partition
ORDER BY last_modified DESC;

-- 查看表的数据量
SELECT
    database,
    table,
    sum(rows) as total_rows,
    formatReadableSize(sum(bytes_on_disk)) as total_size,
    count() as part_count
FROM system.parts
WHERE database = 'backup_test'
  AND active = 1
GROUP BY database, table
ORDER BY total_rows DESC;

-- ========================================
-- 13. 清理测试数据
-- ========================================
DROP TABLE IF EXISTS backup_test.users;
DROP TABLE IF EXISTS backup_test.orders;
DROP TABLE IF EXISTS backup_test.users_backup_20240119;
DROP DATABASE IF EXISTS backup_test;

-- ========================================
-- 14. 备份策略总结
-- ========================================
/*
备份策略建议：

1. 3-2-1 备份原则
   - 至少 3 份备份
   - 2 种不同介质（本地 + 云存储）
   - 1 份异地备份

2. 备份类型
   - 全量备份：每周/每月
   - 增量备份：每天
   - 日志备份：每小时

3. 备份工具选择
   - clickhouse-backup：推荐，功能完整
   - FREEZE：适合快照备份
   - 导出导入：简单但效率低
   - clickhouse-copier：适合跨集群迁移

4. 恢复测试
   - 定期验证备份可用性
   - 测试恢复流程
   - 记录恢复时间

5. 监控告警
   - 监控备份执行状态
   - 监控存储空间
   - 设置告警规则
*/
