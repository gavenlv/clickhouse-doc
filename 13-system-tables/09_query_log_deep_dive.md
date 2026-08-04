# system.query_log 全字段解读

`system.query_log` 是 ClickHouse 最强大的诊断工具——**每一次查询的执行档案**。它能回答"谁在什么时候查了什么、花了多久、读了多少数据、内存用了多少、为什么慢"。本章是 R13 的核心新增，逐字段解读 query_log，并给出 12 个生产诊断查询。

## 目录

- [query_log 是什么](#query_log-是什么)
- [如何开启与配置](#如何开启与配置)
- [核心字段全解读](#核心字段全解读)
- [12 个生产诊断查询](#12-个生产诊断查询)
- [query_log 与 query_thread_log / query_views_log 的区别](#query_log-与-query_thread_log--query_views_log-的区别)
- [日志表维护](#日志表维护)

## query_log 是什么

query_log 是 ClickHouse 内置的"飞行记录仪"：**每条查询**（SELECT/INSERT/DDL/DCL）在结束时写入一行记录，包含执行时间、资源消耗、错误信息等 60+ 个字段。

```
查询执行
    ↓
查询结束时触发
    ↓
写入 system.query_log（MergeTree 引擎，按天分区）
    ↓
查询日志表：SELECT * FROM system.query_log WHERE ...
```

**关键特性**：
- **按天分区**（`event_date`），自动保留
- 记录所有类型的查询（不只是 SELECT）
- 包含查询的完整设置快照（`settings` 列）
- 是性能分析的**唯一权威数据源**

## 如何开启与配置

```xml
<!-- config.xml -->
<query_log>
    <database>system</database>
    <table>query_log</table>
    <partition_by>toYYYYMM(event_date)</partition_by>
    <flush_interval_milliseconds>7500</flush_interval_milliseconds>
    <flush_on_shutdown>1</flush_on_shutdown>
    <!-- 可选：控制采样率 -->
    <not_query>0</not_query>
</query_log>
```

```sql
-- 验证是否开启
SELECT * FROM system.tables WHERE database = 'system' AND name = 'query_log';

-- 查看日志表结构（60+ 字段全貌）
SELECT name, type FROM system.columns
WHERE database = 'system' AND table = 'query_log'
ORDER BY position;
```

## 核心字段全解读

### 分组 1：查询标识（谁查的）

| 字段 | 类型 | 说明 | 诊断用途 |
|------|------|------|---------|
| `event_date` | Date | 查询日期（分区键） | 按天过滤 |
| `event_time` | DateTime | 查询开始时间 | 高峰时段分析 |
| `event_time_microseconds` | DateTime64(6) | 精确到微秒 | 精确排序 |
| `query_start_time` | DateTime | 查询开始时间（同 event_time） | — |
| `query_duration_ms` | UInt64 | 查询耗时（毫秒） | **慢查询筛选** |
| `query_id` | String | 查询唯一 ID | 关联其他日志 |
| `user` | String | 执行用户 | 用户行为分析 |
| `client_hostname` | String | 客户端主机名 | 来源定位 |
| `client_name` | String | 客户端名称（clickhouse-client/JDBC 等） | 客户端画像 |
| `query_kind` | String | 查询类型（SELECT/INSERT/DDL/DCL） | 操作分类 |

### 分组 2：查询语句（查了什么）

| 字段 | 类型 | 说明 | 诊断用途 |
|------|------|------|---------|
| `query` | String | 完整 SQL 语句 | 语句级分析 |
| `query_id` | String | 查询 ID | 定位 |
| `normalized_query_hash` | UInt64 | 规范化 SQL 哈希（去掉字面量） | **同类查询聚合** |
| `query_parameter` | String | 参数化查询的参数 | 参数化分析 |
| `databases` | Array(String) | 涉及的数据库 | 库级分析 |
| `tables` | Array(String) | 涉及的表 | **表级分析** |
| `columns` | Array(String) | 涉及的列 | 列级分析 |
| `used_aggregate_functions` | Array(String) | 使用的聚合函数 | 聚合模式分析 |
| `used_aggregate_function_combinators` | Array(String) | 聚合组合器 | 高级分析 |

### 分组 3：资源消耗（花了多少）

| 字段 | 类型 | 说明 | 诊断用途 |
|------|------|------|---------|
| `read_rows` | UInt64 | 读取行数 | **索引有效性判断** |
| `read_bytes` | UInt64 | 读取字节数 | 扫描量判断 |
| `written_rows` | UInt64 | 写入行数 | INSERT 分析 |
| `written_bytes` | UInt64 | 写入字节数 | INSERT 分析 |
| `result_rows` | UInt64 | 结果行数 | 结果集大小 |
| `result_bytes` | UInt64 | 结果字节数 | 结果集大小 |
| `memory_usage` | UInt64 | 峰值内存（字节） | **OOM 分析** |
| `peak_memory_usage` | UInt64 | 内存峰值（同 memory_usage） | — |
| `query_duration_ms` | UInt64 | 耗时（毫秒） | 性能基准 |

### 分组 4：执行详情（怎么执行的）

| 字段 | 类型 | 说明 | 诊断用途 |
|------|------|------|---------|
| `thread_ids` | Array(UInt64) | 执行线程 | 并行度判断 |
| `settings` | Map(String,String) | 查询生效的设置快照 | **设置审计** |
| `query_settings` | String | 查询级设置 JSON | 设置分析 |
| `used_aggregate_functions` | Array(String) | 聚合函数 | — |
| `query_kind` | String | 查询类型 | — |
| `exception_code` | Int32 | 异常码（0=成功） | **错误分析** |
| `exception` | String | 异常消息 | 错误详情 |
| `stack_trace` | String | 异常堆栈 | 深层次错误 |
| `is_initial_query` | UInt8 | 是否初始查询 | 分布式链路分析 |
| `query_start_time_microseconds` | DateTime64(6) | 开始时间（微秒） | — |
| `log_comment` | String | 日志注释 | 自定义标记 |
| `ProfileEvents` | Nested | 性能事件（读文件/压缩等） | 深入分析 |

### 分组 5：分布式相关（集群视角）

| 字段 | 类型 | 说明 | 诊断用途 |
|------|------|------|---------|
| `query_start_time` | DateTime | 查询开始时间 | — |
| `initial_user` | String | 发起用户（vs user 是执行节点用户） | 跨节点追踪 |
| `initial_query_id` | String | 初始查询 ID | **分布式链路关联** |
| `initial_address` | String | 发起节点地址 | 节点定位 |
| `is_initial_query` | UInt8 | 1=用户发起，0=分片内部查询 | 区分用户查询与内部查询 |
| `QueryKind` | String | 查询类型 | — |

## 12 个生产诊断查询

### 1. 慢查询 Top 20（黄金查询）

```sql
-- 过去 24 小时最慢的 20 个查询
SELECT
    event_time,
    user,
    query_id,
    query_duration_ms / 1000 AS duration_sec,
    formatReadableSize(read_bytes) AS read_size,
    formatReadableQuantity(read_rows) AS read_rows,
    formatReadableSize(peak_memory_usage) AS peak_memory,
    left(query, 200) AS query_preview
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date = today()
  AND query_duration_ms > 1000
ORDER BY query_duration_ms DESC
LIMIT 20;
```

### 2. 慢查询按用户聚合

```sql
SELECT
    user,
    count() AS query_count,
    round(avg(query_duration_ms) / 1000, 2) AS avg_duration_sec,
    round(quantile(0.95)(query_duration_ms) / 1000, 2) AS p95_duration_sec,
    round(max(query_duration_ms) / 1000, 2) AS max_duration_sec,
    formatReadableSize(sum(read_bytes)) AS total_read,
    formatReadableSize(max(peak_memory_usage)) AS max_memory
FROM system.query_log
WHERE type = 'QueryFinish' AND event_date = today()
GROUP BY user
ORDER BY avg_duration_sec DESC;
```

### 3. 最热的表（查询次数最多）

```sql
SELECT
    database,
    table,
    count() AS query_count,
    sum(query_duration_ms) / 1000 AS total_duration_sec,
    formatReadableSize(sum(read_bytes)) AS total_read
FROM (
    SELECT
        database,
        table,
        query_duration_ms,
        read_bytes
    FROM system.query_log
    ARRAY JOIN tables AS t
    WHERE type = 'QueryFinish' AND event_date = today()
)
GROUP BY database, table
ORDER BY query_count DESC
LIMIT 20;
```

### 4. 索引失效检测（读行数 ≈ 全表行数）

```sql
-- 找出 read_rows 异常大的查询（可能没用上索引）
SELECT
    event_time,
    user,
    query_duration_ms / 1000 AS duration_sec,
    formatReadableQuantity(read_rows) AS read_rows,
    left(query, 200) AS query_preview
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date = today()
  AND read_rows > 1000000000   -- 读 > 10 亿行
ORDER BY read_rows DESC
LIMIT 20;
```

### 5. OOM 前兆检测

```sql
SELECT
    event_time,
    user,
    formatReadableSize(peak_memory_usage) AS peak_memory,
    query_duration_ms / 1000 AS duration_sec,
    left(query, 200) AS query_preview
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date = today()
  AND peak_memory_usage > 10000000000  -- 峰值内存 > 10GB
ORDER BY peak_memory_usage DESC
LIMIT 20;
```

### 6. 错误查询分析

```sql
SELECT
    toStartOfHour(event_time) AS hour,
    exception_code,
    exception,
    count() AS error_count
FROM system.query_log
WHERE type = 'ExceptionBeforeStart'
   OR type = 'ExceptionWhileProcessing'
GROUP BY hour, exception_code, exception
ORDER BY hour DESC, error_count DESC
LIMIT 20;
```

### 7. 同类查询聚合（normalized_query_hash 威力）

```sql
-- 用规范化哈希找出"长得一样"的查询，按总耗时排序
SELECT
    count() AS query_count,
    round(sum(query_duration_ms) / 1000, 2) AS total_duration_sec,
    round(avg(query_duration_ms), 1) AS avg_duration_ms,
    formatReadableSize(sum(read_bytes)) AS total_read,
    left(any(query), 200) AS query_sample
FROM system.query_log
WHERE type = 'QueryFinish' AND event_date = today()
GROUP BY normalized_query_hash
ORDER BY total_duration_sec DESC
LIMIT 20;
```

### 8. 小时级负载分析

```sql
SELECT
    toStartOfHour(event_time) AS hour,
    count() AS query_count,
    round(sum(query_duration_ms) / 1000 / 3600, 2) AS busy_hours,
    formatReadableSize(sum(read_bytes)) AS total_read,
    formatReadableSize(quantile(0.9)(peak_memory_usage)) AS p90_memory
FROM system.query_log
WHERE type = 'QueryFinish' AND event_date = today()
GROUP BY hour
ORDER BY hour;
```

### 9. INSERT 性能分析

```sql
SELECT
    database,
    table,
    count() AS insert_count,
    round(avg(query_duration_ms), 1) AS avg_duration_ms,
    formatReadableQuantity(sum(written_rows)) AS total_written_rows,
    round(sum(written_rows) / sum(query_duration_ms) * 1000, 0) AS rows_per_sec
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query_kind = 'Insert'
  AND event_date = today()
GROUP BY database, table
ORDER BY total_written_rows DESC
LIMIT 20;
```

### 10. 缓存命中率分析

```sql
SELECT
    user,
    count() AS query_count,
    countIf(ProfileEvents['QueryCacheHits'] > 0) AS cache_hit_queries,
    round(countIf(ProfileEvents['QueryCacheHits'] > 0) / count() * 100, 2) AS cache_hit_rate_pct
FROM system.query_log
WHERE type = 'QueryFinish' AND event_date = today()
GROUP BY user
ORDER BY cache_hit_rate_pct DESC;
```

### 11. 查询分布（类型维度）

```sql
SELECT
    query_kind,
    count() AS query_count,
    round(avg(query_duration_ms), 1) AS avg_duration_ms,
    round(quantile(0.95)(query_duration_ms), 1) AS p95_duration_ms
FROM system.query_log
WHERE event_date = today()
GROUP BY query_kind
ORDER BY query_count DESC;
```

### 12. 分布式查询链路分析

```sql
-- 找出分布式查询的初始节点和分片执行明细
SELECT
    initial_user,
    initial_address,
    count() AS query_count,
    countIf(is_initial_query = 1) AS initial_queries,
    countIf(is_initial_query = 0) AS shard_queries,
    round(avg(query_duration_ms) / 1000, 2) AS avg_duration_sec
FROM system.query_log
WHERE event_date = today()
GROUP BY initial_user, initial_address
ORDER BY query_count DESC
LIMIT 20;
```

## query_log 与 query_thread_log / query_views_log 的区别

| 日志表 | 记录粒度 | 用途 | 何时看 |
|--------|---------|------|--------|
| `system.query_log` | **每条查询一行** | 查询整体性能（耗时/读行/内存） | 慢查询、资源分析（90% 场景） |
| `system.query_thread_log` | **每个线程一行** | 线程级并行度/耗时分布 | 并行度不足、线程瓶颈 |
| `system.query_views_log` | **每个视图一行** | 物化视图执行明细 | MV 延迟/失败排查 |
| `system.part_log` | **每个 Part 一行** | 合并/写入事件 | Part 生命周期 |
| `system.text_log` | **每条日志一行** | 服务日志（ERROR/WARNING） | 错误诊断 |

```sql
-- query_thread_log 示例：找并行度不足的查询
SELECT
    query_id,
    count() AS thread_count,
    max(thread_number) AS max_thread,
    round(avg(elapsed) ,2) AS avg_thread_elapsed
FROM system.query_thread_log
WHERE event_date = today()
GROUP BY query_id
ORDER BY thread_count DESC
LIMIT 10;
```

## 日志表维护

```sql
-- 1. 查看日志表大小
SELECT
    table,
    formatReadableSize(sum(bytes_on_disk)) AS size,
    count() AS parts
FROM system.parts
WHERE database = 'system' AND active = 1 AND table IN ('query_log', 'query_thread_log')
GROUP BY table;

-- 2. 手动清理旧日志（默认保留 30 天，可调整）
ALTER TABLE system.query_log DELETE WHERE event_date < today() - 30;

-- 3. 调整保留时间（config.xml）
-- <query_log>
--     <log_comment>...</log_comment>
--     <query_log_comment_allowlist>...</query_log_comment_allowlist>
-- </query_log>
-- 日志表 TTL 由服务端自动管理，默认 30 天

-- 4. 只保留慢查询（生产可选项）
-- 在 config.xml 中设置：
-- <query_log><log_queries>1</log_queries>
--     <log_queries_min_type>QUERY_FINISH</log_queries_min_type>
--     <log_queries_min_query_duration_ms>1000</log_queries_min_query_duration_ms>
-- </query_log>
```

## 相关文档

- [点击前往查询和进程](./07_queries_processes.md) —— system.processes 实时监控
- [点击前往系统表详解](./08_system_tables.md) —— 其他 system 表
- [点击前往诊断查询库](./10_diagnostics_queries.sql) —— 本章诊断查询的完整 SQL
- [点击前往 11-monitoring-ops（监控运维）](../11-monitoring-ops/README.md) —— Prometheus 指标采集
- [ClickHouse query_log 官方文档](https://clickhouse.com/docs/en/operations/system-tables/query_log)
