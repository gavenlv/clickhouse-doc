# 测试指南

本指南介绍如何使用 `test_all_topics.sql` 文件来测试 ClickHouse 的三大专题功能。

## 📋 测试文件概览

`test_all_topics.sql` 是一个综合测试文件，包含以下三个专题的测试用例：

1. **08-information-schema** - 数据库元数据查询测试
2. **09-data-deletion** - 数据删除方法测试
3. **10-date-update** - 日期时间操作测试

所有测试表都使用 `ReplicatedMergeTree` 引擎，确保在集群中正常工作。

## 🚀 快速开始

### 1. 启动集群

```bash
cd 00-infra
docker compose up -d
```

### 2. 运行测试

```bash
# 在项目根目录运行
docker exec -it clickhouse1 clickhouse-client --queries-file test_all_topics.sql
```

### 3. 查看测试结果

测试完成后，可以通过以下查询查看测试结果：

```bash
docker exec -it clickhouse1 clickhouse-client --query "
SELECT 
    database,
    table,
    engine,
    total_rows,
    formatReadableSize(total_bytes) as size
FROM system.tables
WHERE database LIKE 'test_%'
ORDER BY database, table
"
```

## 📊 测试内容详解

### 08-information-schema 测试

#### 创建的测试表

1. **test_events** - 事件日志表
   - 字段：event_id, user_id, event_type, event_time, event_data
   - 分区：按月（toYYYYMM(event_time)）
   - 排序：user_id, event_time

2. **test_users** - 用户表
   - 字段：user_id, username, email, created_at, last_login
   - 分区：按月（toYYYYMM(created_at)）
   - 排序：user_id

3. **test_metrics** - 指标表
   - 字段：metric_id, metric_name, metric_value, timestamp（DateTime64）
   - 分区：按月（toYYYYMM(timestamp)）
   - 排序：metric_name, timestamp

#### 测试的查询

- 数据库信息查询：`system.databases`
- 表信息查询：`system.tables`
- 列信息查询：`system.columns`
- 分区信息查询：`system.parts`
- 集群信息查询：`system.clusters`
- 副本信息查询：`system.replicas`
- 进程信息查询：`system.processes`

### 09-data-deletion 测试

#### 创建的测试表

1. **test_logs** - 日志表（测试分区删除）
   - 字段：event_id, event_type, event_time, event_data, created_at
   - 分区：按月（toYYYYMM(event_time)）
   - 排序：event_time, event_id

2. **test_events_ttl** - 事件表（测试 TTL 删除）
   - 字段：event_id, event_type, event_time, event_data
   - 分区：按月（toYYYYMM(event_time)）
   - 排序：event_time, event_id
   - TTL：event_time + INTERVAL 90 DAY

3. **test_user_events** - 用户事件表（测试 Mutation 删除）
   - 字段：event_id, user_id, event_type, event_time, event_data
   - 分区：按月（toYYYYMM(event_time)）
   - 排序：user_id, event_time

4. **test_transactions** - 交易表（测试轻量级删除）
   - 字段：transaction_id, user_id, amount, transaction_time, status
   - 分区：按月（toYYYYMM(transaction_time)）
   - 排序：transaction_id

#### 测试的删除方法

1. **分区删除**（最快）
   ```sql
   ALTER TABLE test_data_deletion.test_logs ON CLUSTER 'treasurycluster'
   DROP PARTITION '202311';
   ```

2. **TTL 自动删除**（自动）
   - 表已配置 TTL：`TTL event_time + INTERVAL 90 DAY`
   - 手动触发：`OPTIMIZE TABLE test_data_deletion.test_events_ttl ON CLUSTER 'treasurycluster' FINAL;`

3. **Mutation 删除**（异步）
   ```sql
   ALTER TABLE test_data_deletion.test_user_events ON CLUSTER 'treasurycluster'
   DELETE WHERE user_id = 1;
   ```

4. **轻量级删除**（ClickHouse 23.8+）
   ```sql
   ALTER TABLE test_data_deletion.test_transactions ON CLUSTER 'treasurycluster'
   DELETE WHERE status = 'failed'
   SETTINGS lightweight_delete = 1;
   ```

#### 监控 Mutation 进度

```sql
SELECT 
    database,
    table,
    mutation_id,
    command,
    is_done,
    parts_to_do,
    progress
FROM system.mutations
WHERE database = 'test_data_deletion';
```

### 10-date-update 测试

#### 创建的测试表

1. **test_types** - 日期时间类型测试表
   - 字段：id, date_col, date32_col, datetime_col, datetime64_col, timestamp_col
   - 分区：按月（toYYYYMM(datetime_col)）
   - 排序：id

2. **test_timezones** - 时区测试表
   - 字段：id, event_name, event_time_utc, event_time_local, event_time_ny
   - 分区：按月（toYYYYMM(event_time_utc)）
   - 排序：id

3. **test_timeseries** - 时间序列测试表
   - 字段：metric_id, metric_name, metric_value, timestamp, hour_key, day_key, month_key
   - 分区：按月（toYYYYMM(timestamp)）
   - 排序：metric_name, timestamp

#### 测试的功能

1. **日期时间类型**
   - Date, Date32, DateTime, DateTime64 类型
   - 时间戳转换
   - 类型转换

2. **日期时间函数**
   - 当前时间：now(), today(), yesterday()
   - 日期格式化：formatDateTime()
   - 时间提取：toYear(), toMonth(), toDayOfMonth()
   - 时间转换：toDateTime(), toDate()

3. **时区处理**
   - 时区转换：toTimezone()
   - 时差计算：dateDiff()
   - 多时区数据存储

4. **日期算术**
   - 基本运算：+ INTERVAL, - INTERVAL
   - 专用函数：addDays(), addMonths(), addYears()
   - 时间差：dateDiff()

5. **时间范围查询**
   - 相对时间：now() - INTERVAL N DAY
   - 固定时间：toStartOfMonth(), toEndOfMonth()
   - 分区裁剪优化

6. **时间序列分析**
   - 按小时/天聚合
   - 滚动平均
   - 累计求和
   - 窗口函数

## 🧪 运行特定测试

### 只测试 08-information-schema

```bash
docker exec -it clickhouse1 clickhouse-client --queries-file <(sed -n '/^-- ========================================$/,/^-- 09-data-deletion 测试$/p' test_all_topics.sql | head -n -1)
```

### 只测试 09-data-deletion

```bash
docker exec -it clickhouse1 clickhouse-client --queries-file <(sed -n '/^-- 09-data-deletion 测试$/,/^-- 10-date-update 测试$/p' test_all_topics.sql | head -n -1)
```

### 只测试 10-date-update

```bash
docker exec -it clickhouse1 clickhouse-client --queries-file <(sed -n '/^-- 10-date-update 测试$/,/^-- ========================================$/p' test_all_topics.sql | head -n -1)
```

## 🧹 清理测试数据

### 清理所有测试数据库

```bash
docker exec -it clickhouse1 clickhouse-client --query "
DROP DATABASE IF EXISTS test_info_schema ON CLUSTER 'treasurycluster' SYNC;
DROP DATABASE IF EXISTS test_data_deletion ON CLUSTER 'treasurycluster' SYNC;
DROP DATABASE IF EXISTS test_date_time ON CLUSTER 'treasurycluster' SYNC;
"
```

### 清理单个测试数据库

```bash
docker exec -it clickhouse1 clickhouse-client --query "DROP DATABASE IF EXISTS test_info_schema ON CLUSTER 'treasurycluster' SYNC"
docker exec -it clickhouse1 clickhouse-client --query "DROP DATABASE IF EXISTS test_data_deletion ON CLUSTER 'treasurycluster' SYNC"
docker exec -it clickhouse1 clickhouse-client --query "DROP DATABASE IF EXISTS test_date_time ON CLUSTER 'treasurycluster' SYNC"
```

## 📈 验证测试结果

### 查看测试表统计

```bash
docker exec -it clickhouse1 clickhouse-client --query "
SELECT 
    database,
    table,
    engine,
    total_rows,
    total_bytes,
    formatReadableSize(total_bytes) as size
FROM system.tables
WHERE database LIKE 'test_%'
ORDER BY database, table
"
```

### 查看分区信息

```bash
docker exec -it clickhouse1 clickhouse-client --query "
SELECT 
    database,
    table,
    partition,
    sum(rows) as rows,
    formatReadableSize(sum(bytes_on_disk)) as size
FROM system.parts
WHERE database LIKE 'test_%' AND active = 1
GROUP BY database, table, partition
ORDER BY database, table, partition
"
```

### 查看副本状态

```bash
docker exec -it clickhouse1 clickhouse-client --query "
SELECT 
    database,
    table,
    is_leader,
    can_become_leader,
    queue_size,
    absolute_delay
FROM system.replicas
WHERE database LIKE 'test_%'
"
```

## 💡 最佳实践

1. **测试前备份重要数据**：确保测试不会影响生产数据
2. **使用单独的测试数据库**：使用 `test_` 前缀的数据库
3. **监控集群状态**：测试前后检查集群健康状态
4. **分批测试**：对于大型测试，可以分批运行
5. **清理测试数据**：测试完成后及时清理
6. **查看执行计划**：使用 EXPLAIN 了解查询执行计划

## ⚠️ 注意事项

1. **集群要求**：测试需要在 `treasurycluster` 集群上运行
2. **内存占用**：测试会创建多个表和插入测试数据，需要足够的内存
3. **执行时间**：完整测试可能需要几分钟时间
4. **Mutation 异步**：Mutation 删除是异步的，需要等待完成
5. **TTL 延迟**：TTL 删除不是立即生效的，可能需要手动触发 OPTIMIZE
6. **副本同步**：数据会在副本之间同步，需要一定时间

## 🔍 故障排查

### 测试失败

如果测试失败，检查以下内容：

1. **集群状态**
   ```bash
   docker exec -it clickhouse1 clickhouse-client --query "SELECT * FROM system.clusters WHERE cluster = 'treasurycluster'"
   ```

2. **副本状态**
   ```bash
   docker exec -it clickhouse1 clickhouse-client --query "SELECT * FROM system.replicas"
   ```

3. **错误日志**
   ```bash
   docker logs clickhouse1
   ```

### Mutation 卡住

如果 Mutation 卡住，检查以下内容：

1. **查看 Mutation 状态**
   ```bash
   docker exec -it clickhouse1 clickhouse-client --query "SELECT * FROM system.mutations ORDER BY created DESC LIMIT 5"
   ```

2. **查看正在运行的查询**
   ```bash
   docker exec -it clickhouse1 clickhouse-client --query "SELECT * FROM system.processes"
   ```

3. **手动取消 Mutation**（慎用）
   ```bash
   docker exec -it clickhouse1 clickhouse-client --query "KILL MUTATION WHERE mutation_id = 'mutation_id'"
   ```

## 📚 相关文档

- [08-information-schema/README.md](./08-information-schema/README.md) - 数据库元数据查询总览
- [09-data-deletion/README.md](./09-data-deletion/README.md) - 数据删除方法总览
- [10-date-update/README.md](./10-date-update/README.md) - 日期时间操作总览
- [00-infra/CLUSTER_ADMIN_GUIDE.md](./00-infra/CLUSTER_ADMIN_GUIDE.md) - 集群管理指南
- [00-infra/ALL_REPLICATED_TABLES.md](./00-infra/ALL_REPLICATED_TABLES.md) - 复制表总结
