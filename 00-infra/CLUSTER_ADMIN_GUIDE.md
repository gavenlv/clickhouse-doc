# ClickHouse 集群管理指南 (treasurycluster)

## 集群概览

**集群名称**: `treasurycluster`

**引擎类型**: ReplicatedMergeTree 系列引擎（支持高可用和自动故障转移）

**部署模式**: 多副本分布式架构

---

## 1. 集群信息查询

### 1.1 查看集群配置

```sql
-- 查看所有集群
SELECT cluster, shard_num, replica_num, host_name, port
FROM system.clusters
WHERE cluster = 'treasurycluster'
ORDER BY shard_num, replica_num;

-- 查看集群的副本分布
SELECT
    cluster,
    shard_num,
    COUNT(DISTINCT replica_num) as replica_count,
    groupArray(host_name) as hosts
FROM system.clusters
WHERE cluster = 'treasurycluster'
GROUP BY cluster, shard_num
ORDER BY shard_num;
```

### 1.2 查看节点状态

```sql
-- 查看所有节点的连接状态
SELECT
    host_name,
    port,
    user,
    default_database,
    connections,
    version,
    uptime
FROM system.clusters
WHERE cluster = 'treasurycluster';

-- 查看节点运行时间
SELECT
    host_name() as current_host,
    uptime() as uptime_seconds,
    version() as version,
    now() as current_time;
```

### 1.3 查看副本状态

```sql
-- 查看所有副本表的状态
SELECT
    database,
    table,
    replica_name,
    is_leader,
    is_readonly,
    is_session_expired,
    queue_size,
    absolute_delay,
    parts_to_delay,
    log_max_index,
    log_pointer
FROM system.replicas
ORDER BY database, table, replica_name;

-- 查看副本同步延迟（重点关注 absolute_delay）
SELECT
    database,
    table,
    replica_name,
    is_leader,
    absolute_delay,
    queue_size
FROM system.replicas
WHERE absolute_delay > 0  -- 有延迟的副本
ORDER BY absolute_delay DESC;
```

---

## 2. 表和分片管理

### 2.1 查看分布式表

```sql
-- 查看所有分布式表
SELECT
    database,
    name,
    engine,
    total_rows,
    total_bytes,
    create_table_query
FROM system.tables
WHERE database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
  AND engine = 'Distributed'
ORDER BY database, name;

-- 查看某个分布式表的分片分布
SELECT
    database,
    table,
    shard_num,
    replica_num,
    host_name,
    port,
    local_table,
    errors_count,
    lag
FROM system.distributed_queue
WHERE database = 'your_database'
  AND table = 'your_table'
ORDER BY shard_num, replica_num;
```

### 2.2 查看数据分布

```sql
-- 查看每个节点的数据量
SELECT
    host_name,
    sum(rows) as total_rows,
    formatReadableSize(sum(bytes_on_disk)) as total_size,
    count(DISTINCT concat(database, '.', name)) as table_count
FROM system.parts
WHERE active = 1
GROUP BY host_name
ORDER BY total_rows DESC;

-- 查看每个分片的数据分布
SELECT
    shard_num,
    sum(rows) as total_rows,
    formatReadableSize(sum(bytes_on_disk)) as total_size,
    count(DISTINCT concat(database, '.', name)) as table_count
FROM system.parts
WHERE active = 1
GROUP BY shard_num
ORDER BY shard_num;
```

### 2.3 查看数据倾斜

```sql
-- 检查数据分布是否均匀（标准差）
SELECT
    table,
    avg(rows) as avg_rows_per_shard,
    stddev(rows) as std_dev,
    max(rows) - min(rows) as max_min_diff
FROM (
    SELECT
        substring(partition, 1, 10) as table,
        shard_num,
        sum(rows) as rows
    FROM system.parts
    WHERE active = 1
    GROUP BY table, shard_num
)
GROUP BY table
HAVING max_min_diff > avg_rows * 0.5  -- 差异超过50%认为存在倾斜
ORDER BY max_min_diff DESC;
```

---

## 3. ZooKeeper/ClickHouse Keeper 状态

### 3.1 查看连接状态

```sql
-- 查看 ZooKeeper 连接信息
SELECT
    name,
    host,
    port,
    index,
    connected,
    version,
    latency_avg
FROM system.zookeeper
ORDER BY index;

-- 查看 Keeper 连接（如果使用 ClickHouse Keeper）
SELECT
    name,
    host,
    port,
    index,
    connected,
    uptime,
    requests_per_second,
    read_bytes_per_second
FROM systemKeeper.keeper
ORDER BY index;
```

### 3.2 查看任务队列

```sql
-- 查看副本队列任务
SELECT
    database,
    table,
    replica_name,
    type,
    source_replica,
    parts_to_do,
    parts_to_do_insert,
    result_part_name,
    result_part_uuid,
    exception_text
FROM system.replication_queue
WHERE parts_to_do > 0
ORDER BY parts_to_do DESC
LIMIT 20;

-- 查看合并任务
SELECT
    database,
    table,
    partition_id,
    result_part_name,
    progress,
    num_parts,
    total_size_bytes_compressed,
    elapsed,
    type
FROM system.merges
ORDER BY total_size_bytes_compressed DESC;
```

### 3.3 查看队列深度

```sql
-- 查看所有副本的队列深度
SELECT
    database,
    table,
    replica_name,
    queue_size,
    absolute_delay,
    log_pointer,
    log_max_index
FROM system.replicas
ORDER BY queue_size DESC;
```

---

## 4. 性能监控

### 4.1 查询性能

```sql
-- 当前正在执行的查询
SELECT
    query_id,
    user,
    query,
    elapsed,
    read_rows,
    read_bytes,
    memory_usage,
    thread_ids
FROM system.processes
ORDER BY elapsed DESC
LIMIT 20;

-- 慢查询历史（需要开启 log_queries = 1）
SELECT
    event_date,
    event_time,
    query_duration_ms,
    query,
    user,
    read_rows,
    read_bytes,
    memory_usage,
    exception_code
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query_duration_ms > 1000  -- 超过1秒
ORDER BY event_time DESC
LIMIT 50;
```

### 4.2 资源使用情况

```sql
-- 系统资源使用
SELECT
    formatReadableSize(total_memory) as total_memory,
    formatReadableSize(free_memory) as free_memory,
    formatReadableSize(buffer_allocated_memory) as buffer_allocated_memory,
    formatReadableSize(buffer_allocated_bytes) as buffer_allocated_bytes,
    formatReadableSize(untracked_memory) as untracked_memory
FROM system.memory;

-- 磁盘使用情况
SELECT
    name,
    path,
    formatReadableSize(free_space) as free_space,
    formatReadableSize(total_space) as total_space,
    formatReadableSize(keep_free_space) as keep_free_space,
    total_space - free_space as used_space
FROM system.disks
ORDER BY name;
```

### 4.3 网络和连接

```sql
-- 查看客户端连接
SELECT
    user,
    address,
    port,
    query_start_time,
    elapsed,
    is_cancelled
FROM system.processes
WHERE query != ''
ORDER BY query_start_time;

-- 查看网络传输统计
SELECT
    name,
    bytes_sent,
    bytes_received,
    packets_sent,
    packets_received
FROM system.asynchronous_metrics
WHERE name LIKE 'Network%'
ORDER BY name DESC;
```

---

## 5. 表维护操作

### 5.1 数据分布检查

```sql
-- 检查每个表在各分片的数据分布
SELECT
    database,
    table,
    shard_num,
    sum(rows) as row_count,
    formatReadableSize(sum(bytes_on_disk)) as size
FROM system.parts
WHERE active = 1
GROUP BY database, table, shard_num
ORDER BY database, table, shard_num;
```

### 5.2 副本同步状态

```sql
-- 查看副本是否同步
SELECT
    database,
    table,
    groupArray(replica_name) as replicas,
    groupArray(is_leader) as leaders,
    groupArray(absolute_delay) as delays,
    max(absolute_delay) as max_delay
FROM system.replicas
GROUP BY database, table
HAVING max(absolute_delay) > 10  -- 延迟超过10秒
ORDER BY max_delay DESC;
```

### 5.3 手动触发合并

```sql
-- 触发某个表的合并
OPTIMIZE TABLE database.table ON CLUSTER 'treasurycluster' PARTITION partition_id FINAL;

-- 触发所有分区的合并
OPTIMIZE TABLE database.table ON CLUSTER 'treasurycluster' FINAL;
```

### 5.4 清理旧数据

```sql
-- 删除过期分区（基于 TTL）
-- TTL 在建表时设置，会自动执行

-- 手动删除分区（谨慎操作）
ALTER TABLE database.table ON CLUSTER 'treasurycluster' DROP PARTITION '202401';

-- 删除旧数据
ALTER TABLE database.table ON CLUSTER 'treasurycluster' DELETE WHERE event_time < now() - INTERVAL 30 DAY;
```

---

## 6. 节点管理

### 6.1 添加节点

```sql
-- 1. 在新节点上启动 ClickHouse
-- 2. 更新集群配置 /etc/clickhouse-server/config.d/cluster.xml

<!-- 新节点配置 -->
<remote_servers>
    <treasurycluster>
        <!-- 现有分片 -->
        <shard>
            <replica>
                <host>node1.example.com</host>
                <port>9000</port>
            </replica>
        </shard>

        <!-- 新增分片 -->
        <shard>
            <replica>
                <host>new-node.example.com</host>
                <port>9000</port>
            </replica>
        </shard>
    </treasurycluster>
</remote_servers>

-- 3. 重新加载配置（无需重启）
SYSTEM RELOAD CONFIG;
```

### 6.2 移除节点

```sql
-- 1. 先将节点设为只读（安全第一）
SYSTEM STOP REPLICATED SENDS database.table;  -- 停止向该副本发送数据
SYSTEM STOP MERGES database.table;  -- 停止合并操作

-- 2. 等待现有任务完成
SELECT
    database,
    table,
    queue_size,
    absolute_delay
FROM system.replicas
WHERE replica_name = 'node_to_remove';

-- 3. 从集群配置中移除节点
-- 4. 重启其他节点
-- 5. 关闭待移除节点

-- 6. 清理 ZooKeeper 中的副本元数据（谨慎操作！）
-- SYSTEM DROP REPLICA 'replica_name' FROM ZKPATH '/path/to/table';
```

### 6.3 重新平衡数据

```sql
-- 方案1：等待自动重新分布（推荐）
-- 数据会自动重新分布

-- 方案2：手动重新分布（如果需要）
-- 创建新的分布式表，然后重命名
CREATE TABLE new_distributed_table ON CLUSTER 'treasurycluster'
AS database.table
ENGINE = Distributed('treasurycluster', database, 'table', sharding_key);

-- 等待数据复制完成

-- 切换表名（原子操作）
RENAME TABLE database.table TO database.table_old,
             new_distributed_table TO database.table
ON CLUSTER 'treasurycluster';
```

---

## 7. 故障排查

### 7.1 副本不一致

```sql
-- 检查哪些副本不一致
SELECT
    database,
    table,
    replica_name,
    absolute_delay,
    queue_size,
    is_readonly,
    is_session_expired
FROM system.replicas
WHERE absolute_delay > 0
  OR queue_size > 100
ORDER BY absolute_delay DESC;

-- 查看同步失败的详细信息
SELECT
    database,
    table,
    replica_name,
    source_replica,
    result_part_name,
    exception_text,
    exception_code
FROM system.replication_queue
WHERE exception_code != 0
ORDER BY event_time DESC
LIMIT 20;
```

### 7.2 重复键错误

```sql
-- 查看重复键冲突（如果启用）
SELECT
    database,
    table,
    merge_tree_bytes_in_use,
    merge_tree_rows_read,
    merge_tree_bytes_read
FROM system.events
WHERE merge_tree_rows_read > 0
ORDER BY merge_tree_rows_read DESC;
```

### 7.3 ZooKeeper 问题

```sql
-- 检查 ZooKeeper 连接
SELECT
    name,
    connected,
    index,
    latency_avg,
    requests_per_second
FROM system.zookeeper
ORDER BY index;

-- 检查会话是否过期
SELECT
    database,
    table,
    replica_name,
    is_session_expired,
    log_pointer,
    log_max_index
FROM system.replicas
WHERE is_session_expired = 1;
```

### 7.4 查看日志

```sql
-- 查看服务器日志
-- 文件位置：/var/log/clickhouse-server/clickhouse-server.log

-- 通过 SQL 查看错误日志
SELECT
    event_date,
    event_time,
    level,
    logger_name,
    message,
    thread_id
FROM system.text_log
WHERE level = 'Error'
  AND event_time > now() - INTERVAL 1 HOUR
ORDER BY event_time DESC
LIMIT 50;
```

---

## 8. 性能优化

### 8.1 查看慢查询

```sql
-- 查看最慢的查询
SELECT
    query_duration_ms / 1000 as duration_seconds,
    user,
    query,
    read_rows,
    read_bytes,
    written_rows,
    memory_usage
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query NOT LIKE '%system.query_log%'
ORDER BY query_duration_ms DESC
LIMIT 10;
```

### 8.2 查看索引使用情况

```sql
-- 查看跳数索引的使用
SELECT
    database,
    table,
    name,
    type,
    expr,
    granularity
FROM system.data_skipping_indices
WHERE database NOT IN ('system', 'information_schema');

-- 查看索引过滤效果
SELECT
    query,
    rows,
    rows_before_limit,
    read_rows,
    formatReadableSize(read_bytes) as bytes_read,
    result_rows
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_time > now() - INTERVAL 1 DAY
ORDER BY read_rows DESC
LIMIT 20;
```

### 8.3 合并调优

```sql
-- 查看合并进度
SELECT
    database,
    table,
    partition_id,
    result_part_name,
    progress,
    num_parts,
    total_size_bytes_compressed,
    elapsed,
    formatReadableSize(total_size_bytes_compressed) as size
FROM system.merges
ORDER BY total_size_bytes_compressed DESC;

-- 调整合并参数（需要重启或 SET GLOBAL）
SET GLOBAL max_bytes_to_merge_at_max_space_in_pool = 10737418240;  -- 10GB
SET GLOBAL max_bytes_to_merge_at_once = 1610612736;  -- 1.5GB
```

---

## 9. 备份和恢复

### 9.1 数据备份

```sql
-- 方案1：使用 clickhouse-backup 工具（推荐）
# 安装 clickhouse-backup
curl https://clickhouse-backup.com/install.sh | bash

# 创建备份
clickhouse-backup create backup_20240119

# 备份上传到 S3
clickhouse-backup upload backup_20240119

-- 方案2：使用 EXPORT/IMPORT（ClickHouse 21.8+）
-- 导出数据
EXPORT TABLE database.table TO FILE('/var/lib/clickhouse/exports/table_export.bin') ON CLUSTER 'treasurycluster';

-- 导入数据
IMPORT TABLE database.table FROM FILE('/var/lib/clickhouse/exports/table_export.bin') ON CLUSTER 'treasurycluster';
```

### 9.2 数据恢复

```sql
-- 方案1：从 clickhouse-backup 恢复
# 从 S3 下载备份
clickhouse-backup download backup_20240119

# 恢复数据
clickhouse-backup restore backup_20240119

-- 方案2：使用 INSERT INTO SELECT
-- 从备份表恢复
CREATE TABLE database.table_backup ON CLUSTER 'treasurycluster'
AS database.table
ENGINE = ReplicatedMergeTree
ORDER BY (your_order_key);

INSERT INTO database.table ON CLUSTER 'treasurycluster'
SELECT * FROM database.table_backup;
```

---

## 10. 安全管理

### 10.1 用户管理

```sql
-- 查看所有用户
SELECT
    name,
    storage,
    default_roles_all,
    auth_type
FROM system.users
ORDER BY name;

-- 创建用户
CREATE USER IF NOT EXISTS app_user
IDENTIFIED WITH plaintext_password BY 'strong_password_here'
DEFAULT ROLE ALL
SETTINGS max_execution_time = 3600;

-- 授予权限
GRANT ALL ON *.* TO app_user;
```

### 10.2 角色管理

```sql
-- 创建角色
CREATE ROLE read_only;
GRANT SELECT ON *.* TO read_only;

-- 授予角色
GRANT read_only TO user1, user2;

-- 查看角色权限
SHOW GRANTS FOR read_only;
```

### 10.3 配额管理

```sql
-- 查看配额使用
SELECT
    quota_name,
    quota_key,
    start_time,
    duration,
    queries,
    query_selects,
    query_inserts,
    max_execution_time,
    max_concurrent_queries
FROM system.quotas_usage
WHERE current = 1;

-- 创建配额
CREATE QUOTA app_quota
KEYED BY user
FOR INTERVAL 1 HOUR
    MAX queries = 1000
    MAX query_selects = 1000
    MAX execution_time = 3600
TO app_user;
```

---

## 11. 监控告警

### 11.1 关键指标

```sql
-- 复制延迟告警
SELECT
    database,
    table,
    replica_name,
    absolute_delay
FROM system.replicas
WHERE absolute_delay > 300  -- 延迟超过5分钟
ORDER BY absolute_delay DESC;

-- 磁盘空间告警
SELECT
    name,
    formatReadableSize(free_space) as free_space,
    free_space / total_space * 100 as free_percent
FROM system.disks
WHERE free_space / total_space < 0.1  -- 剩余空间低于10%
ORDER BY free_space;

-- 合积压告警
SELECT
    database,
    table,
    count(*) as pending_merges
FROM system.merges
GROUP BY database, table
HAVING count(*) > 10  -- 待合并数量超过10
ORDER BY pending_merges DESC;
```

### 11.2 系统健康检查

```sql
-- 整体健康检查
SELECT
    'Replica Delay' as check_type,
    max(absolute_delay) as value,
    CASE WHEN max(absolute_delay) > 300 THEN 'WARNING' ELSE 'OK' END as status
FROM system.replicas
UNION ALL
SELECT
    'Disk Free',
    min(free_space / total_space * 100),
    CASE WHEN min(free_space / total_space) < 0.1 THEN 'CRITICAL'
         WHEN min(free_space / total_space) < 0.2 THEN 'WARNING'
         ELSE 'OK' END
FROM system.disks
UNION ALL
SELECT
    'Merge Backlog',
    count(*),
    CASE WHEN count(*) > 20 THEN 'WARNING' ELSE 'OK' END
FROM system.merges
UNION ALL
SELECT
    'ZooKeeper Connected',
    sum(connected),
    CASE WHEN sum(connected) < 3 THEN 'CRITICAL' ELSE 'OK' END
FROM system.zookeeper;
```

---

## 12. 常用管理脚本

### 12.1 批量清理旧分区

```sql
-- 清理3个月前的分区
SELECT
    'ALTER TABLE ' || database || '.' || table ||
    ' DROP PARTITION ''' || partition || ''' ON CLUSTER ''treasurycluster'';' as cleanup_sql
FROM system.parts
WHERE active = 1
  AND partition <= toString(toYYYYMM(now() - INTERVAL 3 MONTH))
GROUP BY database, table, partition
ORDER BY database, table, partition;
```

### 12.2 批表 OPTIMIZE

```sql
-- 对所有表执行 OPTIMIZE（谨慎使用）
SELECT
    'OPTIMIZE TABLE ' || database || '.' || name ||
    ' ON CLUSTER ''treasurycluster'' FINAL;' as optimize_sql
FROM system.tables
WHERE database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
  AND engine LIKE '%MergeTree%'
  AND engine NOT LIKE '%Distributed%'
ORDER BY database, name;
```

### 12.3 批表统计

```sql
-- 生成所有表的统计信息
SELECT
    database,
    name,
    engine,
    formatReadableSize(total_rows) as rows,
    formatReadableSize(total_bytes) as size,
    partitions.count as partition_count
FROM system.tables
LEFT JOIN (
    SELECT database, table, count(DISTINCT partition) as count
    FROM system.parts
    WHERE active = 1
    GROUP BY database, table
) partitions ON system.tables.database = partitions.database
  AND system.tables.name = partitions.table
WHERE system.tables.database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
ORDER BY total_bytes DESC;
```

---

## 附录：快速参考

### 常用系统表

| 表名 | 用途 |
|------|------|
| `system.clusters` | 集群配置信息 |
| `system.replicas` | 副本状态 |
| `system.distributed_queue` | 分布式队列 |
| `system.parts` | 数据分区信息 |
| `system.merges` | 合并任务 |
| `system.replication_queue` | 复制队列 |
| `system.processes` | 当前查询 |
| `system.query_log` | 查询日志 |
| `system.zookeeper` | ZK 连接信息 |

### 关键配置参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `max_replicated_mutations_in_queue` | 16 | 最大队列变更数 |
| `background_pool_size` | 16 | 后台线程池大小 |
| `background_fetches_pool_size` | 8 | 后台获取线程数 |
| `background_merges_mutations_concurrency_ratio` | 2 | 合并与变更并发比 |

---

**最后更新**: 2026-01-19
**适用版本**: ClickHouse 23.x+
**集群名称**: treasurycluster
