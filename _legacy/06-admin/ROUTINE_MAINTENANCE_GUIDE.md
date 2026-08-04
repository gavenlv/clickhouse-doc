# ClickHouse 日常维护指南

本文档提供 ClickHouse 集群的日常维护任务和最佳实践。

## 目录

- [每日维护任务](#每日维护任务)
- [每周维护任务](#每周维护任务)
- [每月维护任务](#每月维护任务)
- [定期清理](#定期清理)
- [性能优化](#性能优化)
- [表维护](#表维护)
- [索引维护](#索引维护)
- [配置维护](#配置维护)

---

## 每日维护任务

### 1. 健康检查

```sql
-- 执行健康检查
SELECT
    'Replica Status' as check_type,
    sum(absolute_delay > 0) as delayed_replicas,
    sum(is_session_expired = 1) as expired_replicas
FROM system.replicas
UNION ALL
SELECT
    'Disk Status',
    sum(free_space / total_space < 0.2),
    sum(free_space / total_space < 0.1)
FROM system.disks
UNION ALL
SELECT
    'Merge Status',
    sum(count(*) > 20),
    sum(count(*) > 50)
FROM (
    SELECT count(*) as cnt
    FROM system.parts
    WHERE active = 1
    GROUP BY database, table
)
UNION ALL
SELECT
    'Query Status',
    sum(query_duration_ms > 5000),
    sum(query_duration_ms > 10000)
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_time > now() - INTERVAL 1 DAY;
```

### 2. 查看错误日志

```sql
-- 查看最近的错误
SELECT
    event_time,
    level,
    logger_name,
    message
FROM system.text_log
WHERE level IN ('Error', 'Critical')
  AND event_time > now() - INTERVAL 1 HOUR
ORDER BY event_time DESC
LIMIT 50;
```

### 3. 检查慢查询

```sql
-- 查看最慢的查询
SELECT
    query_duration_ms / 1000 as duration_seconds,
    query,
    read_rows,
    formatReadableSize(read_bytes) as bytes_read,
    memory_usage
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query NOT LIKE '%system.query_log%'
  AND query_duration_ms > 1000
  AND event_time > now() - INTERVAL 1 DAY
ORDER BY query_duration_ms DESC
LIMIT 10;
```

### 4. 检查磁盘使用

```sql
-- 查看磁盘使用情况
SELECT
    name,
    path,
    formatReadableSize(free_space) as free,
    formatReadableSize(total_space) as total,
    (total_space - free_space) / total_space * 100 as used_percent
FROM system.disks;
```

### 5. 检查合并任务

```sql
-- 查看待处理的合并任务
SELECT
    database,
    table,
    count(*) as pending_merges,
    sum(progress) as total_progress
FROM system.merges
GROUP BY database, table
ORDER BY pending_merges DESC;
```

---

## 每周维护任务

### 1. 清理旧日志

```sql
-- 删除 30 天前的查询日志
ALTER TABLE system.query_log ON CLUSTER 'treasurycluster'
DELETE WHERE event_date < today() - 30;

-- 删除 7 天前的文本日志
ALTER TABLE system.text_log ON CLUSTER 'treasurycluster'
DELETE WHERE event_date < today() - 7;
```

### 2. 优化表

```sql
-- 生成 OPTIMIZE 语句
SELECT
    'OPTIMIZE TABLE ' || database || '.' || table || ' ON CLUSTER ''treasurycluster'' FINAL;' as optimize_sql
FROM system.parts
WHERE active = 1
  AND database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
  AND count() > 30
GROUP BY database, table
ORDER BY database, table;
```

### 3. 检查数据倾斜

```sql
-- 查看数据分布
SELECT
    database,
    table,
    avg(rows_per_shard) as avg_rows,
    max(rows_per_shard) - min(rows_per_shard) as max_min_diff,
    (max(rows_per_shard) - min(rows_per_shard)) / avg(rows_per_shard) * 100 as diff_percent
FROM (
    SELECT
        database,
        table,
        shard_num,
        sum(rows) as rows_per_shard
    FROM system.parts
    WHERE active = 1
      AND database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
    GROUP BY database, table, shard_num
)
GROUP BY database, table
HAVING (max(rows_per_shard) - min(rows_per_shard)) / avg(rows_per_shard) > 0.3
ORDER BY diff_percent DESC;
```

### 4. 检查碎片化

```sql
-- 查看碎片化严重的表
SELECT
    database,
    table,
    count(*) as part_count,
    countIf(level > 1) as non_level0_parts,
    sum(rows) as total_rows,
    formatReadableSize(sum(bytes_on_disk)) as total_size
FROM system.parts
WHERE active = 1
  AND database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
GROUP BY database, table
HAVING count(*) > 50
ORDER BY part_count DESC;
```

---

## 每月维护任务

### 1. 清理旧分区

```sql
-- 生成清理脚本（手动执行）
SELECT
    'ALTER TABLE ' || database || '.' || table ||
    ' DROP PARTITION ''' || partition || ''' ON CLUSTER ''treasurycluster'';' as cleanup_sql
FROM system.parts
WHERE active = 1
  AND database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
  AND partition <= toString(toYYYYMM(now() - INTERVAL 3 MONTH))
GROUP BY database, table, partition
ORDER BY database, table, partition;
```

### 2. 更新统计信息

```sql
-- 更新表统计信息
ANALYZE TABLE database.table ON CLUSTER 'treasurycluster';
```

### 3. 检查索引使用情况

```sql
-- 查看跳数索引
SELECT
    database,
    table,
    name,
    type,
    expr
FROM system.data_skipping_indices
WHERE database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
ORDER BY database, table;
```

### 4. 检查 TTL 设置

```sql
-- 查看所有 TTL 设置
SELECT
    database,
    table,
    name,
    min_bytes,
    max_bytes
FROM system.ttl_entries
WHERE database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
ORDER BY database, table;
```

---

## 定期清理

### 1. 清理测试数据

```sql
-- 删除所有测试表
SELECT
    'DROP TABLE IF EXISTS ' || database || '.' || name || ' ON CLUSTER ''treasurycluster'';' as drop_sql
FROM system.tables
WHERE database LIKE 'test%'
   OR name LIKE 'test%'
   OR database LIKE 'temp%'
   OR name LIKE 'temp%';
```

### 2. 清理临时表

```sql
-- 删除所有临时表
DROP TABLE IF EXISTS system.temp_table ON CLUSTER 'treasurycluster';
```

### 3. 清理备份文件

```bash
# 清理本地备份（保留 7 天）
find /backup/clickhouse -type f -mtime +7 -delete

# 清理远程备份（保留 30 天）
# 使用 S3 CLI
aws s3 ls s3://clickhouse-backups/ | awk '{print $4}' | while read backup; do
    if [[ $(date -d "$backup" +%s) -lt $(date -d "-30 days" +%s) ]]; then
        aws s3 rm s3://clickhouse-backups/$backup
    fi
done
```

### 4. 清理日志文件

```bash
# 清理 ClickHouse 日志（保留 7 天）
find /var/log/clickhouse-server -type f -mtime +7 -delete

# 清理 Keeper 日志（保留 7 天）
find /var/log/clickhouse-keeper -type f -mtime +7 -delete
```

---

## 性能优化

### 1. 合并调优

```sql
-- 查看合并进度
SELECT
    database,
    table,
    partition_id,
    result_part_name,
    progress,
    num_parts,
    formatReadableSize(total_size_bytes_compressed) as size
FROM system.merges
ORDER BY total_size_bytes_compressed DESC;

-- 调整合并参数（临时）
SET GLOBAL max_bytes_to_merge_at_max_space_in_pool = 10737418240;  -- 10GB
SET GLOBAL max_bytes_to_merge_at_once = 1610612736;  -- 1.5GB
```

### 2. 查询优化

```sql
-- 查看未使用索引的查询
SELECT
    query,
    read_rows,
    rows_before_limit
FROM system.query_log
WHERE type = 'QueryFinish'
  AND read_rows / rows_before_limit > 1000  -- 读取了 1000 倍的数据
  AND event_time > now() - INTERVAL 7 DAY
ORDER BY read_rows DESC
LIMIT 20;
```

### 3. 配置优化

```xml
<!-- 推荐配置 -->
<clickhouse>
    <!-- 内存配置 -->
    <max_memory_usage>8000000000</max_memory_usage>
    <max_memory_usage_for_user>4000000000</max_memory_usage_for_user>
    
    <!-- 线程配置 -->
    <max_threads>8</max_threads>
    <background_pool_size>16</background_pool_size>
    <background_merges_mutations_concurrency_ratio>2</background_merges_mutations_concurrency_ratio>
    
    <!-- 查询配置 -->
    <max_execution_time>3600</max_execution_time>
    <max_concurrent_queries>100</max_concurrent_queries>
    <max_concurrent_queries_for_user>10</max_concurrent_queries_for_user>
    
    <!-- 合并配置 -->
    <max_bytes_to_merge_at_max_space_in_pool>10737418240</max_bytes_to_merge_at_max_space_in_pool>
    <max_bytes_to_merge_at_once>1610612736</max_bytes_to_merge_at_once>
</clickhouse>
```

---

## 表维护

### 1. 表大小监控

```sql
-- 查看表大小
SELECT
    database,
    name,
    engine,
    formatReadableSize(total_rows) as rows,
    formatReadableSize(total_bytes) as size
FROM system.tables
WHERE database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
ORDER BY total_bytes DESC;
```

### 2. 表分区管理

```sql
-- 查看分区信息
SELECT
    database,
    table,
    partition,
    count(*) as part_count,
    sum(rows) as rows,
    formatReadableSize(sum(bytes_on_disk)) as size
FROM system.parts
WHERE active = 1
GROUP BY database, table, partition
ORDER BY database, table, partition;
```

### 3. 表数据清理

```sql
-- 使用 TTL 自动清理
ALTER TABLE database.table ON CLUSTER 'treasurycluster'
MODIFY TTL event_time TO DELETE + INTERVAL 90 DAY;

-- 手动删除旧数据
ALTER TABLE database.table ON CLUSTER 'treasurycluster'
DELETE WHERE event_time < now() - INTERVAL 90 DAY;
```

---

## 索引维护

### 1. 跳数索引

```sql
-- 查看所有跳数索引
SELECT
    database,
    table,
    name,
    type,
    expr,
    granularity
FROM system.data_skipping_indices
WHERE database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
ORDER BY database, table;

-- 添加跳数索引
ALTER TABLE database.table ON CLUSTER 'treasurycluster'
ADD INDEX idx_column (column) TYPE minmax GRANULARITY 1;

-- 删除跳数索引
ALTER TABLE database.table ON CLUSTER 'treasurycluster'
DROP INDEX idx_column;
```

### 2. Projection

```sql
-- 查看所有 Projection
SELECT
    database,
    table,
    name,
    formatReadableSize(data_compressed_bytes) as compressed_size
FROM system.projection_parts
WHERE active = 1
ORDER BY database, table, name;

-- 创建 Projection
ALTER TABLE database.table ON CLUSTER 'treasurycluster'
ADD PROJECTION projection_name
(SELECT column1, column2 ORDER BY column1);

-- 删除 Projection
ALTER TABLE database.table ON CLUSTER 'treasurycluster'
DROP PROJECTION projection_name;
```

---

## 配置维护

### 1. 配置文件备份

```bash
# 备份配置文件
tar -czf /backup/config_$(date +%Y%m%d).tar.gz \
    /etc/clickhouse-server/ \
    /etc/clickhouse-backup/
```

### 2. 配置更新

```xml
<!-- 添加新配置时，先备份 -->
<!-- 然后使用 SYSTEM RELOAD CONFIG 重载配置 -->

<clickhouse>
    <!-- 新配置 -->
    <max_memory_usage>10000000000</max_memory_usage>
</clickhouse>

<!-- 重载配置 -->
<!-- SYSTEM RELOAD CONFIG; -->
```

### 3. 配置验证

```bash
# 验证配置文件语法
clickhouse-server --config-file=/etc/clickhouse-server/config.xml --test
```

---

## 维护自动化脚本

### 每日维护脚本

```bash
#!/bin/bash
# daily_maintenance.sh

LOG_FILE="/var/log/clickhouse-maintenance.log"
DATE=$(date +%Y-%m-%d)

echo "[$DATE] Starting daily maintenance" >> $LOG_FILE

# 1. 健康检查
echo "[$DATE] Running health check..." >> $LOG_FILE
clickhouse-client --multiquery < daily_health_check.sql >> $LOG_FILE 2>&1

# 2. 清理旧日志
echo "[$DATE] Cleaning old logs..." >> $LOG_FILE
clickhouse-client --query="
    ALTER TABLE system.query_log
    DELETE WHERE event_date < today() - 30
" >> $LOG_FILE 2>&1

# 3. 检查磁盘使用
echo "[$DATE] Checking disk usage..." >> $LOG_FILE
clickhouse-client --query="
    SELECT
        name,
        (total_space - free_space) / total_space * 100 as used_percent
    FROM system.disks
" >> $LOG_FILE 2>&1

# 4. 发送报告（如果需要）
# mail -s "ClickHouse Daily Maintenance Report" admin@example.com < $LOG_FILE

echo "[$DATE] Daily maintenance completed" >> $LOG_FILE
```

### 每周维护脚本

```bash
#!/bin/bash
# weekly_maintenance.sh

LOG_FILE="/var/log/clickhouse-maintenance.log"
DATE=$(date +%Y-%m-%d)

echo "[$DATE] Starting weekly maintenance" >> $LOG_FILE

# 1. 优化表
echo "[$DATE] Optimizing tables..." >> $LOG_FILE
clickhouse-client --multiquery < weekly_optimize.sql >> $LOG_FILE 2>&1

# 2. 检查数据倾斜
echo "[$DATE] Checking data skew..." >> $LOG_FILE
clickhouse-client --query="
    SELECT
        database,
        table,
        (max(rows_per_shard) - min(rows_per_shard)) / avg(rows_per_shard) * 100 as diff_percent
    FROM (
        SELECT
            database,
            table,
            sum(rows) as rows_per_shard
        FROM system.parts
        WHERE active = 1
        GROUP BY database, table, shard_num
    )
    GROUP BY database, table
    HAVING (max(rows_per_shard) - min(rows_per_shard)) / avg(rows_per_shard) > 0.3
" >> $LOG_FILE 2>&1

# 3. 清理备份
echo "[$DATE] Cleaning old backups..." >> $LOG_FILE
find /backup/clickhouse -type f -mtime +7 -delete >> $LOG_FILE 2>&1

echo "[$DATE] Weekly maintenance completed" >> $LOG_FILE
```

---

## 维护检查清单

### 每日检查

- [ ] 集群节点状态正常
- [ ] 副本同步无延迟
- [ ] 磁盘空间充足（>20%）
- [ ] 无报错日志
- [ ] 查询性能正常

### 每周检查

- [ ] 执行表优化
- [ ] 检查数据倾斜
- [ ] 清理旧日志
- [ ] 检查合并任务
- [ ] 验证备份

### 每月检查

- [ ] 清理旧分区
- [ ] 更新统计信息
- [ ] 检查索引使用
- [ ] 审查 TTL 设置
- [ ] 性能基准测试

---

**最后更新：** 2026-01-19
**适用版本：** ClickHouse 23.x+
**集群名称：** treasurycluster
