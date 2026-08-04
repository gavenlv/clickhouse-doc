# ClickHouse 备份恢复指南

本文档提供 ClickHouse 数据备份和恢复的完整方案。

## 目录

- [备份策略](#备份策略)
- [备份工具](#备份工具)
- [全量备份](#全量备份)
- [增量备份](#增量备份)
- [数据恢复](#数据恢复)
- [灾难恢复](#灾难恢复)
- [备份验证](#备份验证)
- [备份优化](#备份优化)

---

## 备份策略

### 备份策略选择

| 策略 | 备份频率 | 保留时间 | RTO | RPO | 适用场景 |
|------|---------|---------|-----|-----|---------|
| **全量备份** | 每日 | 7天 | 2小时 | 24小时 | 小规模集群 |
| **全量+增量** | 每日+每小时 | 7天+30天 | 1小时 | 1小时 | 中规模集群 |
| **快照备份** | 实时 | 24小时 | 5分钟 | 0分钟 | 关键业务 |
| **逻辑备份** | 每周 | 30天 | 4小时 | 7天 | 非关键数据 |

### 备份分类

```
┌─────────────────────────────────────┐
│     物理备份                         │
│  - 文件系统快照                     │
│  - 数据目录复制                     │
│  - 性能：⭐⭐⭐⭐⭐                │
│  - 灵活性：⭐⭐⭐                  │
└─────────────────────────────────────┘
┌─────────────────────────────────────┐
│     逻辑备份                         │
│  - SQL 导出导入                     │
│  - 工具导出导入                     │
│  - 性能：⭐⭐⭐                    │
│  - 灵活性：⭐⭐⭐⭐⭐              │
└─────────────────────────────────────┘
```

---

## 备份工具

### 1. clickhouse-backup（推荐）

#### 安装

```bash
# Linux
curl https://clickhouse-backup.com/install.sh | bash

# Docker
docker run -d \
  --name clickhouse-backup \
  --network clickhouse-doc_clickhouse_net \
  -v /backup:/backup \
  -v /clickhouse-backup/config.yml:/etc/clickhouse-backup/config.yml \
  alexakulov/clickhouse-backup

# 或使用 Docker Compose
```

#### 配置

```yaml
# config.yml
general:
  remote_storage: s3
  backups_to_keep_local: 7
  backups_to_keep_remote: 30
  max_file_size: 1073741824  # 1GB

clickhouse:
  username: default
  password: ""
  host: clickhouse-server-1
  port: 9000
  disk_mapping:
    default: /var/lib/clickhouse

s3:
  access_key: YOUR_ACCESS_KEY
  secret_key: YOUR_SECRET_KEY
  bucket: clickhouse-backups
  endpoint: s3.amazonaws.com
  region: us-east-1
  disable_ssl: false
  force_path_style: false
  compression_level: 1
  compression_format: gzip
  disable_cert_verification: false
```

#### 基本操作

```bash
# 创建本地备份
clickhouse-backup create backup_$(date +%Y%m%d)

# 创建并上传到 S3
clickhouse-backup create upload_$(date +%Y%m%d)
clickhouse-backup upload upload_$(date +%Y%m%d)

# 列出本地备份
clickhouse-backup list local

# 列出远程备份
clickhouse-backup list remote

# 删除本地备份
clickhouse-backup delete local backup_$(date +%Y%m%d)

# 删除远程备份
clickhouse-backup delete remote backup_$(date +%Y%m%d)
```

#### 定期备份

```bash
#!/bin/bash
# daily_backup.sh

BACKUP_NAME="backup_$(date +%Y%m%d_%H%M%S)"
LOG_FILE="/var/log/clickhouse-backup.log"

echo "[$(date)] Starting backup: $BACKUP_NAME" >> $LOG_FILE

# 创建备份
clickhouse-backup create $BACKUP_NAME >> $LOG_FILE 2>&1

# 上传到远程
clickhouse-backup upload $BACKUP_NAME >> $LOG_FILE 2>&1

# 清理旧备份（保留 7 天本地，30 天远程）
clickhouse-backup delete local $(clickhouse-backup list local | awk 'NR>7') >> $LOG_FILE 2>&1
clickhouse-backup delete remote $(clickhouse-backup list remote | awk 'NR>30') >> $LOG_FILE 2>&1

echo "[$(date)] Backup completed: $BACKUP_NAME" >> $LOG_FILE

# 添加到 crontab
# 0 2 * * * /path/to/daily_backup.sh
```

### 2. 手动备份方案

#### 方案 1：数据目录复制

```bash
#!/bin/bash
# backup_data_dir.sh

BACKUP_DIR="/backup/clickhouse"
DATA_DIR="/var/lib/clickhouse"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# 停止 ClickHouse（可选，建议冻结表）
# systemctl stop clickhouse-server

# 创建备份目录
mkdir -p $BACKUP_DIR/$TIMESTAMP

# 复制数据目录
cp -r $DATA_DIR $BACKUP_DIR/$TIMESTAMP/

# 或者使用 rsync
# rsync -av --delete $DATA_DIR/ $BACKUP_DIR/$TIMESTAMP/

# 启动 ClickHouse
# systemctl start clickhouse-server

# 压缩备份
tar -czf $BACKUP_DIR/clickhouse_$TIMESTAMP.tar.gz -C $BACKUP_DIR $TIMESTAMP

# 删除临时目录
rm -rf $BACKUP_DIR/$TIMESTAMP

echo "Backup created: $BACKUP_DIR/clickhouse_$TIMESTAMP.tar.gz"
```

#### 方案 2：文件系统快照（LVM）

```bash
#!/bin/bash
# backup_lvm_snapshot.sh

VG_NAME="vg_clickhouse"
LV_NAME="lv_clickhouse"
SNAP_NAME="clickhouse_snapshot_${TIMESTAMP}"
BACKUP_DIR="/backup/snapshots"

# 创建快照
lvcreate -L 50G -s -n $SNAP_NAME /dev/$VG_NAME/$LV_NAME

# 挂载快照
mkdir -p /mnt/$SNAP_NAME
mount /dev/$VG_NAME/$SNAP_NAME /mnt/$SNAP_NAME

# 复制数据
rsync -av /mnt/$SNAP_NAME/ $BACKUP_DIR/$TIMESTAMP/

# 卸载快照
umount /mnt/$SNAP_NAME

# 删除快照
lvremove -f /dev/$VG_NAME/$SNAP_NAME

# 压缩备份
tar -czf $BACKUP_DIR/snapshot_$TIMESTAMP.tar.gz -C $BACKUP_DIR $TIMESTAMP
```

#### 方案 3：SQL 导出（逻辑备份）

```sql
-- 导出表结构
SHOW CREATE TABLE database.table;

-- 导出表数据（小表）
SELECT * FROM database.table
INTO OUTFILE '/var/lib/clickhouse/exports/table.csv'
FORMAT CSV;

-- 导出表数据（大表，使用 clickhouse-client）
clickhouse-client --query="
    SELECT * FROM database.table
    FORMAT CSVWithNames" > table.csv

-- 导出所有表
clickhouse-client --query="
    SELECT
        'CREATE TABLE ' || database || '.' || name || ' AS ' || create_table_query
    FROM system.tables
    WHERE database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
    FORMAT TSV
" > schema.sql

for table in $(clickhouse-client --query="
    SELECT concat(database, '.', name)
    FROM system.tables
    WHERE database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
    FORMAT TSV
"); do
    clickhouse-client --query="
        SELECT * FROM $table
        FORMAT CSVWithNames" > "${table//./_}.csv"
done
```

---

## 全量备份

### 使用 clickhouse-backup

```bash
# 创建全量备份
clickhouse-backup create full_backup_$(date +%Y%m%d)

# 查看备份详情
clickhouse-backup show full_backup_$(date +%Y%m%d)

# 上传到远程存储
clickhouse-backup upload full_backup_$(date +%Y%m%d)
```

### 手动全量备份

```bash
#!/bin/bash
# full_backup.sh

BACKUP_DIR="/backup/full"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# 冻结所有表（推荐）
clickhouse-client --query="SYSTEM FREEZE ALL"

# 等待冻结完成
sleep 10

# 创建快照（使用文件系统）
# LVM 快照或 ZFS 快照

# 复制数据
rsync -av /var/lib/clickhouse/shadow/ $BACKUP_DIR/$TIMESTAMP/

# 解冻表
clickhouse-client --query="SYSTEM UNFREEZE ALL"

# 压缩备份
tar -czf $BACKUP_DIR/full_$TIMESTAMP.tar.gz -C $BACKUP_DIR $TIMESTAMP
```

### 备份配置文件

```bash
# 备份配置文件
tar -czf /backup/config_$(date +%Y%m%d).tar.gz \
    /etc/clickhouse-server/ \
    /etc/clickhouse-backup/
```

---

## 增量备份

### 使用 clickhouse-backup

```bash
# clickhouse-backup 自动支持增量备份
# 只备份自上次备份以来变化的部分

# 创建增量备份
clickhouse-backup create incremental_backup_$(date +%Y%m%d)

# 上传到远程
clickhouse-backup upload incremental_backup_$(date +%Y%m%d)
```

### 手动增量备份

```bash
#!/bin/bash
# incremental_backup.sh

BACKUP_DIR="/backup/incremental"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LAST_BACKUP=$(ls -t $BACKUP_DIR | head -1)

# 使用 rsync 进行增量备份
rsync -av --link-dest=$BACKUP_DIR/$LAST_BACKUP \
    /var/lib/clickhouse/ \
    $BACKUP_DIR/$TIMESTAMP/

# 压缩备份
tar -czf $BACKUP_DIR/incremental_$TIMESTAMP.tar.gz -C $BACKUP_DIR $TIMESTAMP
```

---

## 数据恢复

### 使用 clickhouse-backup

```bash
# 下载备份
clickhouse-backup download full_backup_20240119

# 恢复数据库和表
clickhouse-backup restore full_backup_20240119

# 恢复指定数据库
clickhouse-backup restore --tables=my_database.table full_backup_20240119

# 恢复元数据
clickhouse-backup restore --schema full_backup_20240119

# 恢复数据
clickhouse-backup restore --data full_backup_20240119
```

### 手动恢复（数据目录复制）

```bash
#!/bash
# restore_data_dir.sh

BACKUP_FILE=$1
RESTORE_DIR="/var/lib/clickhouse"

# 停止 ClickHouse
systemctl stop clickhouse-server

# 解压备份
tar -xzf $BACKUP_FILE -C /tmp/

# 复制数据
cp -r /tmp/backup_*/* $RESTORE_DIR/

# 启动 ClickHouse
systemctl start clickhouse-server
```

### 手动恢复（SQL 导入）

```sql
-- 导入表结构
clickhouse-client < schema.sql

-- 导入数据
clickhouse-client --query="
    INSERT INTO database.table
    FORMAT CSVWithNames" < table.csv
```

### 部分恢复

```bash
# 只恢复特定的表
clickhouse-backup restore --tables=my_database.table backup_name

# 只恢复元数据
clickhouse-backup restore --schema backup_name

# 恢复到特定数据库
clickhouse-backup restore --database=my_database backup_name
```

---

## 灾难恢复

### 恢复流程

```
1. 评估灾难影响
    ↓
2. 选择恢复策略
    ↓
3. 准备恢复环境
    ↓
4. 执行数据恢复
    ↓
5. 验证数据完整性
    ↓
6. 切换流量
    ↓
7. 监控系统状态
```

### 场景 1：单节点故障

```bash
# 1. 确认故障节点
SELECT host_name(), uptime() FROM system.one;

# 2. 检查副本状态
SELECT * FROM system.replicas WHERE table = 'your_table';

# 3. 启动新节点
docker-compose up -d clickhouse-server-1

# 4. 数据自动恢复
# ReplicatedMergeTree 会自动从其他副本同步数据

# 5. 验证恢复
SELECT count() FROM your_table;
```

### 场景 2：整个集群故障

```bash
# 1. 准备新集群
docker-compose up -d

# 2. 下载最新备份
clickhouse-backup download latest_backup

# 3. 恢复数据
clickhouse-backup restore latest_backup

# 4. 验证数据
SELECT count() FROM your_table;
```

### 场景 3：数据损坏

```sql
-- 1. 检查数据完整性
CHECK TABLE your_database.your_table;

-- 2. 查看损坏的分区
SELECT * FROM system.parts
WHERE table = 'your_table'
  AND exception_code != 0;

-- 3. 删除损坏的分区
ALTER TABLE your_database.your_table DROP PARTITION '202401';

-- 4. 从备份恢复该分区
# 使用 clickhouse-backup 或手动恢复
```

### 场景 4：误删数据

```bash
# 1. 查看最近的删除操作
SELECT
    event_time,
    query,
    exception_code
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query LIKE '%DROP%'
  AND event_time > now() - INTERVAL 1 DAY
ORDER BY event_time DESC;

# 2. 从备份恢复
clickhouse-backup restore backup_before_drop

# 3. 验证数据
SELECT count() FROM dropped_table;
```

---

## 备份验证

### 备份完整性检查

```sql
-- 1. 创建验证表
CREATE TABLE monitoring.backup_verification ON CLUSTER 'treasurycluster' (
    backup_name String,
    backup_time DateTime,
    verification_time DateTime DEFAULT now(),
    status String,
    tables_count UInt32,
    total_rows UInt64,
    total_bytes UInt64
) ENGINE = MergeTree
ORDER BY (backup_time, backup_name);

-- 2. 执行验证
INSERT INTO monitoring.backup_verification
SELECT
    backup_name,
    backup_time,
    now() as verification_time,
    'verified' as status,
    count(*) as tables_count,
    sum(total_rows) as total_rows,
    sum(total_bytes) as total_bytes
FROM system.tables
WHERE database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA');

-- 3. 查看验证结果
SELECT * FROM monitoring.backup_verification
ORDER BY backup_time DESC;
```

### 定期恢复测试

```bash
#!/bin/bash
# test_restore.sh

TEST_DB="restore_test_$(date +%Y%m%d)"
BACKUP_NAME=$1

# 创建测试数据库
clickhouse-client --query="CREATE DATABASE $TEST_DB"

# 恢复备份到测试数据库
clickhouse-backup restore --database=$TEST_DB $BACKUP_NAME

# 验证数据
TABLE_COUNT=$(clickhouse-client --query="
    SELECT count(*)
    FROM system.tables
    WHERE database = '$TEST_DB'
")

ROW_COUNT=$(clickhouse-client --query="
    SELECT sum(total_rows)
    FROM system.tables
    WHERE database = '$TEST_DB'
")

echo "Tables: $TABLE_COUNT"
echo "Rows: $ROW_COUNT"

# 删除测试数据库
clickhouse-client --query="DROP DATABASE $TEST_DB"
```

---

## 备份优化

### 1. 压缩优化

```bash
# 使用最高压缩率
clickhouse-backup create --compression-level=9 backup_name

# 使用 zstd 压缩（更快）
clickhouse-backup create --compression-format=zstd backup_name
```

### 2. 并行备份

```bash
# 使用多个线程并行备份
clickhouse-backup create --threads=4 backup_name
```

### 3. 过滤备份

```yaml
# config.yml
clickhouse:
  tables:
    - pattern: "your_database.*"
      enabled: true
    - pattern: "system.*"
      enabled: false
    - pattern: "test_*"
      enabled: false
```

### 4. 增量优化

```bash
# 只备份变化的表
clickhouse-backup create --incremental backup_name
```

---

## 备份最佳实践

### 1. 备份策略

- **每日全量备份**：每天凌晨 2 点执行
- **每小时增量备份**：每小时执行一次
- **异地备份**：备份到至少 2 个不同位置
- **备份保留**：本地保留 7 天，远程保留 30 天

### 2. 备份验证

- **每日验证**：自动验证备份完整性
- **每周测试**：每周执行一次恢复测试
- **每月演练**：每月进行一次灾难恢复演练

### 3. 备份监控

```sql
-- 创建备份监控表
CREATE TABLE monitoring.backup_status ON CLUSTER 'treasurycluster' (
    backup_name String,
    backup_time DateTime,
    backup_type String,
    backup_size UInt64,
    backup_status String,
    upload_status String,
    verification_status String
) ENGINE = MergeTree
ORDER BY (backup_time, backup_name);

-- 查询备份状态
SELECT * FROM monitoring.backup_status
WHERE backup_time > now() - INTERVAL 7 DAY
ORDER BY backup_time DESC;
```

### 4. 告警配置

```yaml
# Prometheus 告警规则
- alert: ClickHouseBackupFailed
  expr: clickhouse_backup_status == 0
  for: 1h
  labels:
    severity: critical
  annotations:
    summary: "ClickHouse 备份失败"
    description: "备份 {{ $labels.backup_name }} 失败超过 1 小时"

- alert: ClickHouseBackupTooOld
  expr: time() - clickhouse_backup_timestamp > 86400
  labels:
    severity: warning
  annotations:
    summary: "ClickHouse 备份过期"
    description: "最近一次备份超过 24 小时"
```

---

## 常见问题

### Q1: 备份失败怎么办？

```bash
# 查看备份日志
clickhouse-backup create --debug backup_name

# 检查磁盘空间
df -h

# 检查 ClickHouse 状态
clickhouse-client --query="SELECT 1"
```

### Q2: 备份太慢怎么办？

```bash
# 增加线程数
clickhouse-backup create --threads=8 backup_name

# 使用更快的压缩算法
clickhouse-backup create --compression-format=zstd backup_name

# 增加内存限制
--max-memory-limit 10G
```

### Q3: 恢复时表已存在怎么办？

```bash
# 使用 --drop-existing
clickhouse-backup restore --drop-existing backup_name

# 或者只恢复数据
clickhouse-backup restore --data backup_name
```

### Q4: 如何恢复到特定时间点？

```bash
# 1. 列出所有备份
clickhouse-backup list remote

# 2. 选择时间点之前的备份
clickhouse-backup download backup_20240118

# 3. 恢复备份
clickhouse-backup restore backup_20240118
```

---

**最后更新：** 2026-01-19
**适用版本：** ClickHouse 23.x+
**集群名称：** treasurycluster
