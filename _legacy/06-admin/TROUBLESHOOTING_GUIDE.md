# ClickHouse 故障排查指南

本文档提供了 ClickHouse 集群常见问题的诊断和解决方案。

## 目录

- [快速诊断流程](#快速诊断流程)
- [网络连接问题](#网络连接问题)
- [Keeper/ZooKeeper 问题](#keeperzookeeper-问题)
- [复制表问题](#复制表问题)
- [性能问题](#性能问题)
- [资源问题](#资源问题)
- [数据一致性问题](#数据一致性问题)
- [启动失败](#启动失败)
- [查询失败](#查询失败)
- [数据恢复](#数据恢复)
- [诊断工具和脚本](#诊断工具和脚本)

---

## 快速诊断流程

```
发现问题
    ↓
执行健康检查 (diagnostics.sql)
    ↓
确定问题类别
    ↓
执行相应诊断 SQL
    ↓
应用解决方案
    ↓
验证恢复
```

### 第一步：执行健康检查

```sql
-- 执行系统健康检查
SELECT
    'Replica Delay' as check_type,
    max(absolute_delay) as value,
    CASE
        WHEN max(absolute_delay) > 300 THEN 'CRITICAL'
        WHEN max(absolute_delay) > 60 THEN 'WARNING'
        ELSE 'OK'
    END as status
FROM system.replicas
UNION ALL
SELECT
    'Disk Free',
    min(free_space / total_space * 100),
    CASE
        WHEN min(free_space / total_space) < 0.1 THEN 'CRITICAL'
        WHEN min(free_space / total_space) < 0.2 THEN 'WARNING'
        ELSE 'OK'
    END
FROM system.disks
UNION ALL
SELECT
    'Merge Backlog',
    count(*),
    CASE
        WHEN count(*) > 50 THEN 'CRITICAL'
        WHEN count(*) > 20 THEN 'WARNING'
        ELSE 'OK'
    END
FROM system.merges
UNION ALL
SELECT
    'ZooKeeper Connected',
    sum(connected),
    CASE
        WHEN sum(connected) = 0 THEN 'CRITICAL'
        WHEN sum(connected) < 3 THEN 'WARNING'
        ELSE 'OK'
    END
FROM system.zookeeper;
```

---

## 网络连接问题

### 问题 1: 无法连接到 ClickHouse 节点

**现象：**
```
Connection refused
Connection timeout
```

**诊断步骤：**

```sql
-- 1. 检查节点是否在线
SELECT host_name(), port, version(), uptime() FROM system.one;

-- 2. 检查端口是否开放
-- Linux/Mac:
-- lsof -i :9000
-- lsof -i :8123

-- Windows:
-- netstat -ano | findstr :9000
-- netstat -ano | findstr :8123

-- 3. 检查防火墙规则
-- Linux:
-- sudo iptables -L -n | grep 9000
-- sudo iptables -L -n | grep 8123

-- Windows:
-- netsh advfirewall firewall show rule name=all
```

**解决方案：**

1. **检查配置文件：**
   - 确认 `<listen_host>` 设置为 `0.0.0.0`
   - 检查 `<tcp_port>` 和 `<http_port>` 是否正确

2. **检查防火墙：**
   - 允许端口 9000 (Native TCP) 和 8123 (HTTP)
   - 允许端口 9234 (ClickHouse Keeper)
   - 允许端口 9444 (Raft 通信)

3. **检查 Docker 网络：**
   ```bash
   docker network inspect clickhouse-doc_clickhouse_net
   docker exec clickhouse-server-1 ping keeper1
   docker exec clickhouse-server-1 ping keeper2
   ```

### 问题 2: IPv6 连接失败

**现象：**
```
Connection refused to IPv6 address
Timeout connecting to keeper nodes
```

**原因：**
- ClickHouse 尝试使用 IPv6 地址
- Docker 网络仅支持 IPv4

**解决方案：**

1. **使用 IPv4 地址：**
   在配置文件中使用 `<host>` 而非 `<hostname>`：
   ```xml
   <zookeeper>
       <node>
           <host>keeper1</host>  <!-- 使用 IPv4 主机名 -->
           <port>9181</port>
       </node>
   </zookeeper>
   ```

2. **强制 IPv4：**
   ```xml
   <listen_host>0.0.0.0</listen_host>
   ```

3. **禁用 IPv6：**
   在操作系统层面禁用 IPv6（不推荐）

---

## Keeper/ZooKeeper 问题

### 问题 3: Keeper 选举超时

**现象：**
```
Keeper election timeout
Cannot establish connection to Keeper ensemble
```

**诊断：**

```sql
-- 检查 Keeper 连接状态
SELECT
    name,
    host,
    port,
    connected,
    latency_avg,
    requests_per_second
FROM system.zookeeper
ORDER BY index;

-- 检查副本是否连接到 Keeper
SELECT
    database,
    table,
    replica_name,
    is_session_expired,
    zookeeper_path
FROM system.replicas
WHERE is_session_expired = 1;
```

**解决方案：**

1. **增加超时时间：**
   ```xml
   <coordination_settings>
       <operation_timeout_ms>30000</operation_timeout_ms>  -- 30秒
       <session_timeout_ms>60000</session_timeout_ms>     -- 60秒
   </coordination_settings>
   ```

2. **检查 Keeper 集群健康：**
   ```bash
   docker-compose logs keeper1 keeper2 keeper3 | grep -i "leader\|follower"
   ```

3. **重启 Keeper 节点：**
   ```bash
   docker-compose restart keeper1
   docker-compose restart keeper2
   docker-compose restart keeper3
   ```

### 问题 4: Keeper 集群未形成多数派

**现象：**
- ClickHouse 无法连接到 Keeper
- 只有 1 个 Keeper 节点正常
- Raft 选举失败

**诊断：**

```bash
# 查看 Keeper 日志
docker-compose logs keeper1 keeper2 keeper3 | tail -100

# 检查 Keeper 节点通信
docker exec clickhouse-keeper-1 ping keeper2
docker exec clickhouse-keeper-1 ping keeper3

# 检查 Raft 状态
docker exec clickhouse-keeper-1 clickhouse-keeper-client \
    --host localhost --port 9181 --query "SHOW QUORUM"
```

**解决方案：**

1. **确保至少 2 个节点运行：**
   ```bash
   docker-compose up -d keeper1 keeper2
   ```

2. **检查配置唯一性：**
   - 每个 Keeper 节点的 `server_id` 必须唯一
   - Raft 配置中的所有节点必须正确

3. **清理损坏的数据：**
   ```bash
   docker-compose down
   rm -rf ./data/keeper*
   docker-compose up -d
   ```

### 问题 5: Keeper 连接断开

**现象：**
```
Keeper connection loss
Session expired
```

**诊断：**

```sql
-- 查看会话过期的副本
SELECT
    database,
    table,
    replica_name,
    is_session_expired,
    queue_size,
    absolute_delay,
    last_queue_update
FROM system.replicas
WHERE is_session_expired = 1
ORDER BY queue_size DESC;
```

**解决方案：**

1. **检查网络稳定性：**
   ```bash
   # 持续 ping 测试
   ping -i 0.2 keeper1
   ```

2. **调整超时配置：**
   - 增大 `session_timeout_ms`
   - 增大 `operation_timeout_ms`

3. **重启 ClickHouse 节点：**
   ```bash
   docker-compose restart clickhouse1
   docker-compose restart clickhouse2
   ```

---

## 复制表问题

### 问题 6: 副本同步延迟

**现象：**
- 数据在不同节点上不一致
- 查询结果不一致

**诊断：**

```sql
-- 查看有延迟的副本
SELECT
    database,
    table,
    replica_name,
    is_leader,
    is_readonly,
    absolute_delay,
    queue_size,
    (log_max_index - log_pointer) as pending_logs
FROM system.replicas
WHERE absolute_delay > 0
ORDER BY absolute_delay DESC;

-- 查看复制队列
SELECT
    database,
    table,
    replica_name,
    type,
    source_replica,
    parts_to_do,
    exception_text
FROM system.replication_queue
WHERE parts_to_do > 0
ORDER BY parts_to_do DESC;
```

**解决方案：**

1. **等待自动恢复：**
   - 通常延迟会在几分钟内自动恢复
   - 避免频繁重启

2. **检查网络带宽：**
   ```bash
   # 查看网络使用
   docker stats clickhouse-server-1 clickhouse-server-2
   ```

3. **减少写入负载：**
   - 降低写入频率
   - 批量插入代替单条插入

4. **手动触发复制：**
   ```sql
   SYSTEM SYNC REPLICA database.table;
   ```

### 问题 7: 复制失败

**现象：**
```
Replication failed
Duplicate key error
```

**诊断：**

```sql
-- 查看复制错误
SELECT
    database,
    table,
    replica_name,
    source_replica,
    result_part_name,
    exception_text,
    exception_code,
    num_tries
FROM system.replication_queue
WHERE exception_code != 0
ORDER BY event_time DESC
LIMIT 20;

-- 查看最近的错误日志
SELECT
    event_time,
    level,
    logger_name,
    message
FROM system.text_log
WHERE level = 'Error'
  AND message LIKE '%replicat%'
  AND event_time > now() - INTERVAL 1 HOUR
ORDER BY event_time DESC;
```

**解决方案：**

1. **重复键错误：**
   - 使用 `ReplicatedReplacingMergeTree` 替代 `ReplicatedMergeTree`
   - 添加版本列进行去重

2. **数据不一致：**
   ```sql
   -- 重新同步副本
   SYSTEM SYNC REPLICA database.table;
   
   -- 如果仍然失败，删除并重建
   DROP TABLE database.table ON CLUSTER 'treasurycluster' SYNC;
   ```

3. **ZooKeeper 路径冲突：**
   ```bash
   # 连接到 Keeper
   docker exec -it clickhouse-keeper-1 clickhouse-keeper-client \
       --host localhost --port 9181
   
   # 删除冲突的路径
   rmr /clickhouse/tables/1/conflict_table
   ```

### 问题 8: 表创建失败

**现象：**
```
Table already exists on another replica
ZooKeeper path already exists
```

**诊断：**

```sql
-- 查看已存在的表
SELECT
    database,
    table,
    zookeeper_path,
    replica_name
FROM system.replicas
WHERE table = 'your_table';
```

**解决方案：**

1. **删除 ZooKeeper 元数据：**
   ```bash
   # 连接到 Keeper
   docker exec -it clickhouse-keeper-1 clickhouse-keeper-client \
       --host localhost --port 9181
   
   # 删除表路径
   rmr /clickhouse/tables/1/your_table
   ```

2. **清理本地数据：**
   ```bash
   docker-compose down
   rm -rf ./data/clickhouse*
   docker-compose up -d
   ```

---

## 性能问题

### 问题 9: 查询缓慢

**现象：**
- 查询响应时间过长
- CPU 使用率持续 100%

**诊断：**

```sql
-- 查看当前正在执行的查询
SELECT
    query_id,
    user,
    query,
    elapsed,
    read_rows,
    formatReadableSize(read_bytes) as bytes_read,
    formatReadableSize(memory_usage) as memory,
    thread_ids
FROM system.processes
ORDER BY elapsed DESC;

-- 查看慢查询历史
SELECT
    event_time,
    query_duration_ms / 1000 as duration_seconds,
    query,
    read_rows,
    formatReadableSize(read_bytes) as bytes_read,
    memory_usage
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query_duration_ms > 1000
  AND event_time > now() - INTERVAL 1 DAY
ORDER BY query_duration_ms DESC
LIMIT 20;
```

**解决方案：**

1. **优化查询：**
   - 添加适当的 WHERE 条件
   - 使用 LIMIT 限制结果
   - 避免全表扫描

2. **创建索引：**
   ```sql
   -- 添加跳数索引
   ALTER TABLE database.table ON CLUSTER 'treasurycluster'
   ADD INDEX idx_name (column) TYPE minmax GRANULARITY 1;
   ```

3. **使用 Projection：**
   ```sql
   -- 创建投影
   ALTER TABLE database.table ON CLUSTER 'treasurycluster'
   ADD PROJECTION projection_name
   (SELECT column1, column2 ORDER BY column1);
   ```

4. **调整配置：**
   ```xml
   <max_threads>8</max_threads>
   <max_memory_usage>8000000000</max_memory_usage>
   ```

### 问题 10: 写入缓慢

**现象：**
- 数据插入延迟高
- 批量插入阻塞

**诊断：**

```sql
-- 查看插入统计
SELECT
    event,
    value,
    description
FROM system.events
WHERE event LIKE '%Insert%'
ORDER BY value DESC;

-- 查看合并任务
SELECT
    database,
    table,
    count(*) as merge_count,
    sum(progress) as total_progress
FROM system.merges
GROUP BY database, table
ORDER BY merge_count DESC;
```

**解决方案：**

1. **使用批量插入：**
   ```sql
   -- 批量插入
   INSERT INTO database.table VALUES
       (1, 'data1'),
       (2, 'data2'),
       (3, 'data3');
   ```

2. **使用异步插入：**
   ```xml
   <async_insert>1</async_insert>
   <wait_for_async_insert>0</wait_for_async_insert>
   <async_insert_max_data_size>1048576</async_insert_max_data_size>
   ```

3. **使用 Buffer 表：**
   ```sql
   CREATE TABLE buffer_table ON CLUSTER 'treasurycluster'
   AS target_table
   ENGINE = Buffer(database, target_table,
       16, 10, 100, 10000000, 10, 100, 2);
   ```

4. **调整合并参数：**
   ```xml
   <max_bytes_to_merge_at_max_space_in_pool>10737418240</max_bytes_to_merge_at_max_space_in_pool>
   <background_pool_size>16</background_pool_size>
   ```

### 问题 11: 合并积压

**现象：**
- 分区数量持续增长
- 查询性能下降

**诊断：**

```sql
-- 查看合并任务
SELECT
    database,
    table,
    partition_id,
    result_part_name,
    progress,
    num_parts,
    formatReadableSize(total_size_bytes_compressed) as size,
    elapsed
FROM system.merges
ORDER BY total_size_bytes_compressed DESC;

-- 查看分区数量
SELECT
    database,
    table,
    count(*) as part_count
FROM system.parts
WHERE active = 1
GROUP BY database, table
HAVING count(*) > 50
ORDER BY part_count DESC;
```

**解决方案：**

1. **手动触发合并：**
   ```sql
   OPTIMIZE TABLE database.table ON CLUSTER 'treasurycluster' PARTITION '202401' FINAL;
   ```

2. **调整合并参数：**
   ```sql
   SET GLOBAL max_bytes_to_merge_at_once = 1073741824;  -- 1GB
   SET GLOBAL max_bytes_to_merge_at_max_space_in_pool = 10737418240;  -- 10GB
   ```

3. **限制写入频率：**
   - 减少批量插入的大小
   - 增加插入间隔

---

## 资源问题

### 问题 12: 内存不足

**现象：**
```
Memory limit exceeded
OutOfMemory
```

**诊断：**

```sql
-- 查看内存使用
SELECT
    formatReadableSize(total_memory) as total_memory,
    formatReadableSize(free_memory) as free_memory,
    formatReadableSize(untracked_memory) as untracked,
    formatReadableSize(total_memory - free_memory) as used
FROM system.memory;

-- 查看查询内存使用
SELECT
    query_id,
    query,
    formatReadableSize(memory_usage) as memory,
    formatReadableSize(memory_usage_for_all_queries) as total_memory,
    thread_ids
FROM system.processes
WHERE query != ''
ORDER BY memory_usage DESC;
```

**解决方案：**

1. **限制查询内存：**
   ```sql
   SET max_memory_usage = 4000000000;  -- 4GB
   ```

2. **使用物化视图：**
   ```sql
   CREATE MATERIALIZED VIEW mv_table ON CLUSTER 'treasurycluster'
   ENGINE = AggregatingMergeTree()
   ORDER BY group_key
   AS SELECT
       group_key,
       sumState(metric) as metric
   FROM source_table
   GROUP BY group_key;
   ```

3. **优化查询：**
   - 添加 WHERE 条件
   - 使用 LIMIT
   - 避免 JOIN 大表

4. **增加 Docker 内存：**
   - 在 Docker Desktop 中增加内存限制
   - 或调整容器内存限制

### 问题 13: 磁盘空间不足

**现象：**
```
Disk space is low
Cannot write to disk
```

**诊断：**

```sql
-- 查看磁盘使用
SELECT
    name,
    path,
    formatReadableSize(free_space) as free,
    formatReadableSize(total_space) as total,
    formatReadableSize(total_space - free_space) as used,
    (total_space - free_space) / total_space * 100 as used_percent
FROM system.disks;

-- 查看各表大小
SELECT
    database,
    name,
    formatReadableSize(total_bytes) as size,
    engine
FROM system.tables
WHERE database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
ORDER BY total_bytes DESC;
```

**解决方案：**

1. **清理旧数据：**
   ```sql
   -- 删除旧分区
   ALTER TABLE database.table ON CLUSTER 'treasurycluster'
   DROP PARTITION '202401';
   
   -- 使用 TTL
   ALTER TABLE database.table ON CLUSTER 'treasurycluster'
   MODIFY TTL event_time TO DELETE + INTERVAL 90 DAY;
   ```

2. **压缩数据：**
   ```sql
   -- 使用更高效的压缩算法
   ALTER TABLE database.table ON CLUSTER 'treasurycluster'
   MODIFY SETTING compress_marks = 1;
   ```

3. **删除无用数据：**
   ```sql
   -- 删除测试数据
   DROP TABLE IF EXISTS test_table ON CLUSTER 'treasurycluster';
   ```

### 问题 14: CPU 使用率高

**现象：**
- CPU 持续 100%
- 系统响应缓慢

**诊断：**

```sql
-- 查看当前查询
SELECT
    query_id,
    query,
    elapsed,
    thread_ids
FROM system.processes
WHERE query != ''
ORDER BY elapsed DESC;

-- 查看 CPU 事件
SELECT
    event,
    value,
    description
FROM system.events
WHERE event LIKE 'CPU%'
ORDER BY value DESC;
```

**解决方案：**

1. **限制并发查询：**
   ```xml
   <max_concurrent_queries>100</max_concurrent_queries>
   <max_concurrent_queries_for_user>10</max_concurrent_queries_for_user>
   ```

2. **优化查询：**
   - 添加索引
   - 使用 Projection
   - 避免全表扫描

3. **调整线程数：**
   ```xml
   <max_threads>8</max_threads>
   <background_pool_size>16</background_pool_size>
   ```

---

## 数据一致性问题

### 问题 15: 数据不一致

**现象：**
- 不同节点查询结果不同
- 副本数据不同步

**诊断：**

```sql
-- 比较两个副本的数据
SELECT
    replica_name,
    sum(rows) as total_rows,
    count(*) as part_count
FROM system.parts
WHERE active = 1
  AND database = 'your_database'
  AND table = 'your_table'
GROUP BY replica_name;

-- 查看副本同步状态
SELECT
    database,
    table,
    replica_name,
    is_leader,
    absolute_delay,
    queue_size
FROM system.replicas
WHERE database = 'your_database'
  AND table = 'your_table';
```

**解决方案：**

1. **等待自动同步：**
   - 通常数据会自动同步
   - 检查网络和 Keeper 状态

2. **手动触发同步：**
   ```sql
   SYSTEM SYNC REPLICA database.table;
   ```

3. **使用 ReplacingMergeTree：**
   ```sql
   CREATE TABLE database.table ON CLUSTER 'treasurycluster' (
       id UInt64,
       data String,
       version UInt64  -- 版本列
   ) ENGINE = ReplicatedReplacingMergeTree
   ORDER BY id;
   ```

### 问题 16: 重复数据

**现象：**
- 查询结果有重复
- COUNT 与实际不符

**诊断：**

```sql
-- 检查重复数据
SELECT
    key_column,
    count(*) as cnt
FROM database.table
GROUP BY key_column
HAVING count(*) > 1
ORDER BY cnt DESC
LIMIT 10;
```

**解决方案：**

1. **使用 ReplacingMergeTree：**
   ```sql
   CREATE TABLE database.table ON CLUSTER 'treasurycluster' (
       id UInt64,
       data String,
       updated_at DateTime  -- 版本列
   ) ENGINE = ReplicatedReplacingMergeTree(updated_at)
   ORDER BY id;
   ```

2. **使用 CollapsingMergeTree：**
   ```sql
   CREATE TABLE database.table ON CLUSTER 'treasurycluster' (
       id UInt64,
       data String,
       sign Int8  -- 1: 插入, -1: 删除
   ) ENGINE = ReplicatedCollapsingMergeTree(sign)
   ORDER BY id;
   ```

3. **使用 FINAL 查询：**
   ```sql
   SELECT * FROM database.table FINAL;
   ```

---

## 启动失败

### 问题 17: ClickHouse 无法启动

**现象：**
- 容器启动后立即退出
- 日志显示启动错误

**诊断：**

```bash
# 查看启动日志
docker-compose logs clickhouse1 --tail=100

# 查看容器状态
docker-compose ps
docker inspect clickhouse-server-1
```

**解决方案：**

1. **检查配置文件：**
   ```bash
   # 验证配置文件语法
   docker exec clickhouse-server-1 clickhouse-server --config-file=/etc/clickhouse-server/config.xml --test
   ```

2. **检查端口占用：**
   ```bash
   # Linux/Mac
   lsof -i :9000
   lsof -i :8123
   
   # Windows
   netstat -ano | findstr :9000
   netstat -ano | findstr :8123
   ```

3. **检查权限：**
   ```xml
   <skip_user_check>true</skip_user_check>
   ```

4. **清理数据目录：**
   ```bash
   docker-compose down
   rm -rf ./data/clickhouse*
   docker-compose up -d
   ```

---

## 查询失败

### 问题 18: 查询超时

**现象：**
```
Query timeout
Query execution exceeded time limit
```

**解决方案：**

1. **增加超时时间：**
   ```sql
   SET max_execution_time = 3600;  -- 1小时
   ```

2. **优化查询：**
   - 添加 WHERE 条件
   - 使用 LIMIT
   - 添加索引

3. **使用异步查询：**
   ```sql
   INSERT INTO query_log (query_id, query, status)
   VALUES ('query_id', 'SELECT ...', 'pending');
   ```

### 问题 19: 列不存在

**现象：**
```
Column not found
Missing columns
```

**解决方案：**

1. **检查表结构：**
   ```sql
   DESCRIBE TABLE database.table;
   ```

2. **使用 ALIAS：**
   ```sql
   SELECT 
       column1 AS column2
   FROM database.table;
   ```

3. **添加缺失的列：**
   ```sql
   ALTER TABLE database.table ON CLUSTER 'treasurycluster'
   ADD COLUMN new_column String DEFAULT '';
   ```

---

## 数据恢复

### 问题 20: 误删分区

**解决方案：**

```sql
-- 1. 查看最近的删除操作
SELECT
    event_time,
    query,
    exception_code
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query LIKE '%DROP PARTITION%'
  AND event_time > now() - INTERVAL 1 DAY
ORDER BY event_time DESC;

-- 2. 从备份恢复（如果有）
clickhouse-backup restore backup_name

-- 3. 从其他副本恢复
SYSTEM SYNC REPLICA database.table;
```

### 问题 21: 数据损坏

**解决方案：**

1. **检查数据完整性：**
   ```sql
   CHECK TABLE database.table;
   ```

2. **修复损坏的分区：**
   ```sql
   OPTIMIZE TABLE database.table ON CLUSTER 'treasurycluster' FINAL;
   ```

3. **从备份恢复：**
   ```bash
   clickhouse-backup restore backup_name
   ```

---

## 诊断工具和脚本

### 健康检查脚本

```sql
-- 完整的健康检查
SELECT
    'Health Check' as check_type,
    'Replica Status' as category,
    countIf(absolute_delay = 0) as healthy_replicas,
    countIf(absolute_delay > 0) as delayed_replicas,
    countIf(is_session_expired = 1) as expired_replicas
FROM system.replicas
UNION ALL
SELECT
    'Health Check',
    'Disk Status',
    countIf(free_space / total_space > 0.2),
    countIf(free_space / total_space BETWEEN 0.1 AND 0.2),
    countIf(free_space / total_space < 0.1)
FROM system.disks
UNION ALL
SELECT
    'Health Check',
    'Merge Status',
    countIf(num_parts < 10),
    countIf(num_parts BETWEEN 10 AND 50),
    countIf(num_parts > 50)
FROM (
    SELECT count(*) as num_parts
    FROM system.parts
    WHERE active = 1
    GROUP BY database, table
)
UNION ALL
SELECT
    'Health Check',
    'Query Status',
    countIf(query_duration_ms < 1000),
    countIf(query_duration_ms BETWEEN 1000 AND 10000),
    countIf(query_duration_ms > 10000)
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_time > now() - INTERVAL 1 HOUR;
```

### 系统状态摘要

```sql
-- 系统状态摘要
SELECT
    'System Status' as category,
    metric,
    value
FROM (
    SELECT 'Uptime', formatReadableSize(uptime()) as metric, uptime() as value
    UNION ALL
    SELECT 'Memory Usage', formatReadableSize(used_memory), used_memory
    FROM (
        SELECT total_memory - free_memory as used_memory
        FROM system.memory
    )
    UNION ALL
    SELECT 'Disk Free', formatReadableSize(free_space), free_space
    FROM system.disks
    LIMIT 1
    UNION ALL
    SELECT 'Active Merges', toString(count(*)), count(*)
    FROM system.merges
    UNION ALL
    SELECT 'Replication Queue', toString(sum(queue_size)), sum(queue_size)
    FROM system.replicas
);
```

---

## 获取帮助

如果以上方案都无法解决问题：

1. **收集日志：**
   ```bash
   docker-compose logs > logs.txt
   ```

2. **检查系统资源：**
   ```bash
   docker stats
   ```

3. **查看官方文档：**
   - [ClickHouse 文档](https://clickhouse.com/docs)
   - [故障排查指南](https://clickhouse.com/docs/en/operations/troubleshooting)

4. **社区支持：**
   - [GitHub Issues](https://github.com/ClickHouse/ClickHouse/issues)
   - [Slack 社区](https://clickhouse.com/slack)

---

**最后更新：** 2026-01-19
**适用版本：** ClickHouse 23.x+
**集群名称：** treasurycluster
