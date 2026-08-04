# 审计日志

审计日志是监控和记录 ClickHouse 数据库安全事件的重要工具。本节将详细介绍如何配置和管理审计日志。

## 📑 目录

- [审计日志概览](#审计日志概览)
- [配置审计日志](#配置审计日志)
- [审计日志内容](#审计日志内容)
- [查询审计日志](#查询审计日志)
- [审计日志分析](#审计日志分析)
- [审计日志告警](#审计日志告警)
- [实战示例](#实战示例)

## 审计日志概览

### 审计日志优势

1. **合规要求**：满足数据保护法规（GDPR、HIPAA 等）
2. **安全监控**：监控异常访问和操作
3. **问题诊断**：诊断数据库问题和故障
4. **性能分析**：分析查询性能和资源使用
5. **责任追溯**：追溯操作责任和时间线

### 审计日志类型

| 日志类型 | 说明 | 表名 | 用途 |
|---------|------|------|------|
| **查询日志** | 记录所有查询 | `system.query_log` | 性能分析、问题诊断 |
| **查询线程日志** | 记录查询线程 | `system.query_thread_log` | 性能分析 |
| **错误日志** | 记录错误信息 | `system.error_log` | 故障诊断 |
| **会话日志** | 记录会话信息 | `system.session_log` | 会话管理 |
| **异常日志** | 记录异常信息 | `system.exception_log` | 错误分析 |
| **部分查询日志** | 记录部分查询 | `system.part_log` | 分区管理 |
| **Mutation 日志** | 记录 Mutation 操作 | `system.mutation_log` | 数据更新监控 |
| **文件日志** | 记录文件操作 | `system.file_log` | 文件管理 |
| **崩溃日志** | 记录崩溃信息 | `system.crash_log` | 故障分析 |
| **Process 日志** | 记录当前进程 | `system.processes` | 实时监控 |

## 配置审计日志

### 配置查询日志

```xml
<!-- config.xml -->
<query_log>
    <!-- 日志表 -->
    <database>system</database>
    <table>query_log</table>
    
    <!-- 分区设置 -->
    <partition_by>toYYYYMM(event_date)</partition_by>
    
    <!-- TTL 设置：保留 30 天 -->
    <ttl>event_date + INTERVAL 30 DAY DELETE</ttl>
    
    <!-- 记录类型 -->
    <!-- 1: QueryStart, 2: QueryFinish, 4: ExceptionBeforeStart -->
    <type>1,2,4</type>
    
    <!-- 记录慢查询（超过 1 秒） -->
    <min_query_duration_ms>1000</min_query_duration_ms>
    
    <!-- 记录异常查询 -->
    <record_exception>1</record_exception>
    
    <!-- 记录失败查询 -->
    <record_failed_queries>1</record_failed_queries>
    
    <!-- 缓冲区大小 -->
    <buffer_size>1048576</buffer_size>
</query_log>
```

### 配置查询线程日志

```xml
<!-- config.xml -->
<query_thread_log>
    <database>system</database>
    <table>query_thread_log</table>
    <partition_by>toYYYYMM(event_date)</partition_by>
    <ttl>event_date + INTERVAL 30 DAY DELETE</ttl>
    <type>1,2,4</type>
</query_thread_log>
```

### 配置错误日志

```xml
<!-- config.xml -->
<error_log>
    <database>system</database>
    <table>error_log</table>
    <partition_by>toYYYYMM(event_date)</partition_by>
    <ttl>event_date + INTERVAL 90 DAY DELETE</ttl>
    <level>error,warning,information</level>
</error_log>
```

### 配置 Mutation 日志

```xml
<!-- config.xml -->
<mutation_log>
    <database>system</database>
    <table>mutation_log</table>
    <partition_by>toYYYYMM(event_date)</partition_by>
    <ttl>event_date + INTERVAL 90 DAY DELETE</ttl>
</mutation_log>
```

### 完整审计日志配置

```xml
<!-- config.xml -->
<clickhouse>
    <!-- 查询日志 -->
    <query_log>
        <database>system</database>
        <table>query_log</table>
        <partition_by>toYYYYMM(event_date)</partition_by>
        <ttl>event_date + INTERVAL 30 DAY DELETE</ttl>
        <type>1,2,4</type>
        <min_query_duration_ms>1000</min_query_duration_ms>
        <record_exception>1</record_exception>
        <record_failed_queries>1</record_exception>
        <buffer_size>1048576</buffer_size>
    </query_log>
    
    <!-- 查询线程日志 -->
    <query_thread_log>
        <database>system</database>
        <table>query_thread_log</table>
        <partition_by>toYYYYMM(event_date)</partition_by>
        <ttl>event_date + INTERVAL 30 DAY DELETE</ttl>
        <type>1,2,4</type>
    </query_thread_log>
    
    <!-- 错误日志 -->
    <error_log>
        <database>system</database>
        <table>error_log</table>
        <partition_by>toYYYYMM(event_date)</partition_by>
        <ttl>event_date + INTERVAL 90 DAY DELETE</ttl>
        <level>error,warning,information</level>
    </error_log>
    
    <!-- Mutation 日志 -->
    <mutation_log>
        <database>system</database>
        <table>mutation_log</table>
        <partition_by>toYYYYMM(event_date)</partition_by>
        <ttl>event_date + INTERVAL 90 DAY DELETE</ttl>
    </mutation_log>
    
    <!-- 会话日志 -->
    <session_log>
        <database>system</database>
        <table>session_log</table>
        <partition_by>toYYYYMM(event_date)</partition_by>
        <ttl>event_date + INTERVAL 30 DAY DELETE</ttl>
    </session_log>
</clickhouse>
```

## 审计日志内容

### 查询日志字段

| 字段 | 类型 | 说明 |
|------|------|------|
| `event_date` | Date | 事件日期 |
| `event_time` | DateTime | 事件时间 |
| `event_time_microseconds` | DateTime64 | 微秒级时间 |
| `query_start_time` | DateTime | 查询开始时间 |
| `query_duration_ms` | UInt64 | 查询持续时间（毫秒） |
| `query` | String | 查询文本 |
| `user` | String | 用户名 |
| `query_id` | String | 查询 ID |
| `address` | IPv6 | 客户端地址 |
| `port` | UInt16 | 客户端端口 |
| `is_initial_query` | UInt8 | 是否初始查询 |
| `is_final_query` | UInt8 | 是否最终查询 |
| `type` | Enum8 | 查询类型 |
| `exception_code` | Int32 | 异常代码 |
| `exception_text` | String | 异常文本 |
| `stack_trace` | String | 堆栈跟踪 |
| `read_rows` | UInt64 | 读取行数 |
| `read_bytes` | UInt64 | 读取字节数 |
| `written_rows` | UInt64 | 写入行数 |
| `written_bytes` | UInt64 | 写入字节数 |
| `result_rows` | UInt64 | 结果行数 |
| `result_bytes` | UInt64 | 结果字节数 |
| `memory_usage` | UInt64 | 内存使用（字节） |
| `thread_ids` | Array(UInt64) | 线程 ID 列表 |

### Mutation 日志字段

| 字段 | 类型 | 说明 |
|------|------|------|
| `event_date` | Date | 事件日期 |
| `event_time` | DateTime | 事件时间 |
| `mutation_id` | String | Mutation ID |
| `command` | String | Mutation 命令 |
| `database` | String | 数据库名 |
| `table` | String | 表名 |
| `is_done` | UInt8 | 是否完成 |
| `reason` | String | 原因 |
| `parts_to_do` | UInt64 | 待处理分区数 |
| `parts_to_do_names` | Array(String) | 待处理分区名 |
| `is_virtual_part` | UInt8 | 是否虚拟分区 |

## 查询审计日志

### 查看所有查询

```sql
-- 查看最近 100 条查询
SELECT 
    event_time,
    user,
    query,
    query_duration_ms,
    read_rows,
    read_bytes,
    memory_usage,
    exception_code,
    exception_text
FROM system.query_log
ORDER BY event_time DESC
LIMIT 100;

-- 查看特定用户的查询
SELECT 
    event_time,
    query,
    query_duration_ms,
    read_rows,
    read_bytes,
    memory_usage
FROM system.query_log
WHERE user = 'alice'
  AND type = 'QueryFinish'
  AND event_time >= now() - INTERVAL 1 DAY
ORDER BY event_time DESC;

-- 查看失败的查询
SELECT 
    event_time,
    user,
    query,
    exception_code,
    exception_text
FROM system.query_log
WHERE type = 'Exception'
  AND event_time >= now() - INTERVAL 7 DAY
ORDER BY event_time DESC;
```

### 查看慢查询

```sql
-- 查看最慢的 100 条查询
SELECT 
    event_time,
    user,
    query,
    query_duration_ms / 1000 as duration_seconds,
    read_rows,
    read_bytes / 1024 / 1024 / 1024 as read_gb,
    memory_usage / 1024 / 1024 / 1024 as memory_gb
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query_duration_ms > 10000  -- 超过 10 秒
  AND event_time >= now() - INTERVAL 1 DAY
ORDER BY query_duration_ms DESC
LIMIT 100;

-- 按用户统计慢查询
SELECT 
    user,
    count() as slow_query_count,
    avg(query_duration_ms) as avg_duration_ms,
    max(query_duration_ms) as max_duration_ms,
    sum(read_rows) as total_read_rows,
    sum(read_bytes) / 1024 / 1024 / 1024 as total_read_gb
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query_duration_ms > 5000  -- 超过 5 秒
  AND event_time >= now() - INTERVAL 1 DAY
GROUP BY user
ORDER BY slow_query_count DESC;
```

### 查看 Mutation 操作

```sql
-- 查看 Mutation 操作
SELECT 
    event_time,
    mutation_id,
    database,
    table,
    command,
    is_done,
    parts_to_do,
    parts_to_do_names
FROM system.mutation_log
ORDER BY event_time DESC;

-- 查看 Mutation 进度
SELECT 
    database,
    table,
    mutation_id,
    command,
    sum(parts_to_do - 1) as remaining_parts,
    count() as total_mutations
FROM system.mutation_log
WHERE is_done = 0
GROUP BY database, table, mutation_id, command;

-- 查看 Mutation 历史
SELECT 
    event_date,
    database,
    table,
    count() as mutation_count,
    sum(if(is_done = 1, 1, 0)) as completed_count,
    avg(dateDiff('second', event_time, now())) as avg_duration_seconds
FROM system.mutation_log
WHERE event_date >= today() - INTERVAL 30 DAY
GROUP BY event_date, database, table
ORDER BY event_date DESC;
```

## 审计日志分析

### 用户活动分析

```sql
-- 用户查询统计
SELECT 
    user,
    count() as total_queries,
    countIf(type = 'QueryFinish') as successful_queries,
    countIf(type = 'Exception') as failed_queries,
    avg(query_duration_ms) as avg_duration_ms,
    sum(read_rows) as total_read_rows,
    sum(read_bytes) / 1024 / 1024 / 1024 as total_read_gb,
    sum(memory_usage) / 1024 / 1024 / 1024 as total_memory_gb
FROM system.query_log
WHERE event_time >= now() - INTERVAL 1 DAY
GROUP BY user
ORDER BY total_queries DESC;

-- 用户访问模式
SELECT 
    user,
    countIf(contains(query, 'SELECT')) as select_count,
    countIf(contains(query, 'INSERT')) as insert_count,
    countIf(contains(query, 'ALTER')) as alter_count,
    countIf(contains(query, 'DROP')) as drop_count,
    countIf(contains(query, 'CREATE')) as create_count
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_time >= now() - INTERVAL 7 DAY
GROUP BY user
ORDER BY select_count DESC;

-- 客户端 IP 统计
SELECT 
    IPv6NumToString(address) as client_ip,
    count() as query_count,
    count(DISTINCT user) as unique_users,
    avg(query_duration_ms) as avg_duration_ms
FROM system.query_log
WHERE event_time >= now() - INTERVAL 1 DAY
GROUP BY client_ip
ORDER BY query_count DESC;
```

### 安全事件分析

```sql
-- 查看失败的登录尝试
SELECT 
    event_time,
    exception_text
FROM system.query_log
WHERE exception_code = 516  -- ACCESS_DENIED
  AND event_time >= now() - INTERVAL 1 DAY
ORDER BY event_time DESC;

-- 查看权限拒绝
SELECT 
    user,
    query,
    exception_text,
    count() as failure_count
FROM system.query_log
WHERE exception_code = 516
  AND event_time >= now() - INTERVAL 7 DAY
GROUP BY user, query, exception_text
ORDER BY failure_count DESC;

-- 查看异常查询
SELECT 
    event_time,
    user,
    query,
    exception_code,
    exception_text
FROM system.query_log
WHERE type = 'Exception'
  AND event_time >= now() - INTERVAL 1 DAY
ORDER BY event_time DESC;
```

### 性能分析

```sql
-- 查询性能统计
SELECT 
    event_date,
    count() as total_queries,
    avg(query_duration_ms) as avg_duration_ms,
    max(query_duration_ms) as max_duration_ms,
    quantile(0.95)(query_duration_ms) as p95_duration_ms,
    quantile(0.99)(query_duration_ms) as p99_duration_ms,
    sum(read_bytes) / 1024 / 1024 / 1024 as total_read_gb
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today() - INTERVAL 30 DAY
GROUP BY event_date
ORDER BY event_date DESC;

-- 内存使用统计
SELECT 
    user,
    avg(memory_usage) / 1024 / 1024 / 1024 as avg_memory_gb,
    max(memory_usage) / 1024 / 1024 / 1024 as max_memory_gb,
    sum(memory_usage) / 1024 / 1024 / 1024 as total_memory_gb
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_time >= now() - INTERVAL 1 DAY
GROUP BY user
ORDER BY total_memory_gb DESC;
```

## 审计日志告警

### 创建告警规则

```sql
-- 1. 创建告警表
CREATE TABLE IF NOT EXISTS security.alerts
ON CLUSTER 'treasurycluster'
(
    alert_id UUID,
    alert_type String,
    alert_level Enum8('info' = 1, 'warning' = 2, 'error' = 3, 'critical' = 4),
    message String,
    details String,
    alert_time DateTime,
    resolved UInt8 DEFAULT 0
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/alerts', '{replica}')
PARTITION BY toYYYYMM(alert_time)
ORDER BY (alert_id, alert_time);

-- 2. 创建慢查询告警视图
CREATE MATERIALIZED VIEW IF NOT EXISTS security.slow_query_alerts_mv
TO security.alerts
AS SELECT
    generateUUIDv4() as alert_id,
    'slow_query' as alert_type,
    if(query_duration_ms > 30000, 'critical', 'warning')::Enum8('info' = 1, 'warning' = 2, 'error' = 3, 'critical' = 4) as alert_level,
    format('Slow query detected: user={}, duration={}ms, query={}', user, query_duration_ms, substring(query, 1, 100)) as message,
    format('user={}, query={}, duration={}ms', user, query, query_duration_ms) as details,
    event_time as alert_time
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query_duration_ms > 10000
  AND event_time >= now() - INTERVAL 5 MINUTE;
```

### 查询告警

```sql
-- 查看所有告警
SELECT 
    alert_id,
    alert_type,
    alert_level,
    message,
    alert_time,
    resolved
FROM security.alerts
ORDER BY alert_time DESC;

-- 查看未解决的告警
SELECT 
    alert_id,
    alert_type,
    alert_level,
    message,
    alert_time
FROM security.alerts
WHERE resolved = 0
ORDER BY alert_level DESC, alert_time DESC;

-- 统计告警
SELECT 
    alert_type,
    alert_level,
    count() as alert_count
FROM security.alerts
WHERE alert_time >= now() - INTERVAL 1 DAY
GROUP BY alert_type, alert_level
ORDER BY alert_level DESC, alert_count DESC;
```

## 实战示例

### 示例 1: 完整审计日志配置

```xml
<!-- config.xml -->
<clickhouse>
    <!-- 查询日志 -->
    <query_log>
        <database>system</database>
        <table>query_log</table>
        <partition_by>toYYYYMM(event_date)</partition_by>
        <ttl>event_date + INTERVAL 30 DAY DELETE</ttl>
        <type>1,2,4</type>
        <min_query_duration_ms>0</min_query_duration_ms>
        <record_exception>1</record_exception>
        <record_failed_queries>1</record_failed_queries>
    </query_log>
    
    <!-- 查询线程日志 -->
    <query_thread_log>
        <database>system</database>
        <table>query_thread_log</table>
        <partition_by>toYYYYMM(event_date)</partition_by>
        <ttl>event_date + INTERVAL 30 DAY DELETE</ttl>
        <type>1,2,4</type>
    </query_thread_log>
    
    <!-- 错误日志 -->
    <error_log>
        <database>system</database>
        <table>error_log</table>
        <partition_by>toYYYYMM(event_date)</partition_by>
        <ttl>event_date + INTERVAL 90 DAY DELETE</ttl>
        <level>error,warning,information</level>
    </error_log>
    
    <!-- Mutation 日志 -->
    <mutation_log>
        <database>system</database>
        <table>mutation_log</table>
        <partition_by>toYYYYMM(event_date)</partition_by>
        <ttl>event_date + INTERVAL 90 DAY DELETE</ttl>
    </mutation_log>
    
    <!-- 会话日志 -->
    <session_log>
        <database>system</database>
        <table>session_log</table>
        <partition_by>toYYYYMM(event_date)</partition_by>
        <ttl>event_date + INTERVAL 30 DAY DELETE</ttl>
    </session_log>
</clickhouse>
```

### 示例 2: 审计日志分析脚本

```sql
-- 1. 用户活动报告
SELECT 
    'User Activity Report' as report_type,
    now() as report_time,
    '' as line
UNION ALL
SELECT 
    format('Total queries: {}', count()) as report_type,
    '' as report_time,
    '' as line
FROM system.query_log
WHERE event_time >= now() - INTERVAL 1 DAY
UNION ALL
SELECT 
    format('Users: {}', count(DISTINCT user)) as report_type,
    '' as report_time,
    '' as line
FROM system.query_log
WHERE event_time >= now() - INTERVAL 1 DAY
UNION ALL
SELECT 
    '' as report_type,
    '' as report_time,
    '---' as line
UNION ALL
SELECT 
    user as report_type,
    format('Queries: {}, Avg: {:.2f}s, Max: {:.2f}s', 
           count(), 
           avg(query_duration_ms) / 1000, 
           max(query_duration_ms) / 1000) as report_time,
    '' as line
FROM system.query_log
WHERE event_time >= now() - INTERVAL 1 DAY
GROUP BY user
ORDER BY count() DESC;

-- 2. 安全事件报告
SELECT 
    'Security Events Report' as report_type,
    now() as report_time,
    '' as line
UNION ALL
SELECT 
    format('Failed queries: {}', count()) as report_type,
    '' as report_time,
    '' as line
FROM system.query_log
WHERE type = 'Exception'
  AND event_time >= now() - INTERVAL 1 DAY
UNION ALL
SELECT 
    format('Access denied: {}', count()) as report_type,
    '' as report_time,
    '' as line
FROM system.query_log
WHERE exception_code = 516
  AND event_time >= now() - INTERVAL 1 DAY
UNION ALL
SELECT 
    '' as report_type,
    '' as report_time,
    '---' as line
UNION ALL
SELECT 
    format('User: {}, Error: {}', user, exception_text) as report_type,
    event_time as report_time,
    '' as line
FROM system.query_log
WHERE exception_code = 516
  AND event_time >= now() - INTERVAL 1 DAY
ORDER BY event_time DESC
LIMIT 10;
```

## 🎯 审计日志最佳实践

1. **启用所有日志**：启用所有审计日志类型
2. **设置 TTL**：合理设置日志保留期
3. **分区管理**：按时间分区便于管理
4. **定期分析**：定期分析审计日志
5. **告警规则**：设置告警规则及时发现异常
6. **备份日志**：定期备份重要日志
7. **性能监控**：监控日志对性能的影响
8. **合规要求**：确保日志满足合规要求

## ⚠️ 注意事项

1. **性能影响**：审计日志会增加 I/O 和存储开销
2. **存储管理**：合理设置 TTL 和分区策略
3. **隐私保护**：保护审计日志中的敏感信息
4. **日志完整性**：确保日志不被篡改
5. **查询优化**：避免频繁查询大范围日志
6. **备份恢复**：定期备份审计日志

## 📚 相关文档

- [用户认证](./01_authentication.md)
- [用户和角色管理](./02_user_role_management.md)
- [权限控制](./03_permissions.md)
- [安全最佳实践](./08_best_practices.md)
