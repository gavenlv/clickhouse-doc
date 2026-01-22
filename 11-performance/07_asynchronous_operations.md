# 异步操作优化

异步操作是 ClickHouse 提升写入和查询性能的重要手段，通过异步处理减少等待时间，提升吞吐量。

## 异步插入

### 基本概念

异步插入允许客户端立即返回，数据在后台异步写入，显著提升写入性能。

### 配置异步插入

```sql
-- 全局配置（在 config.xml 中）
<clickhouse>
    <async_insert>1</async_insert>
    <async_insert_max_data_size>100000000</async_insert_max_data_size>
    <async_insert_busy_timeout_ms>5000</async_insert_busy_timeout_ms>
    <async_insert_max_wait_time_ms>10000</async_insert_max_wait_time_ms>
</clickhouse>

-- 查询级别配置
INSERT INTO events
SETTINGS async_insert = 1,
        wait_for_async_insert = 0,
        async_insert_max_data_size = 100000000,
        async_insert_busy_timeout_ms = 5000,
        async_insert_max_wait_time_ms = 10000
VALUES (1, 100, 'click', now(), '{}');
```

### 异步插入参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| async_insert | 0 | 是否启用异步插入 |
| wait_for_async_insert | 1 | 是否等待异步插入完成 |
| async_insert_max_data_size | 1000000 | 异步插入最大数据大小（字节）|
| async_insert_busy_timeout_ms | 5000 | 繁忙超时时间（毫秒）|
| async_insert_max_wait_time_ms | 10000 | 最大等待时间（毫秒）|

### 异步插入示例

```sql
-- 示例 1: 不等待插入完成
INSERT INTO events
SETTINGS async_insert = 1,
        wait_for_async_insert = 0
VALUES (1, 100, 'click', now(), '{}');

-- 示例 2: 等待插入完成
INSERT INTO events
SETTINGS async_insert = 1,
        wait_for_async_insert = 1,
        async_insert_max_wait_time_ms = 5000
VALUES (2, 100, 'view', now(), '{}');

-- 示例 3: 批量异步插入
INSERT INTO events
SETTINGS async_insert = 1,
        wait_for_async_insert = 0,
        async_insert_max_data_size = 100000000
VALUES (3, 101, 'click', now(), '{}'),
       (4, 102, 'click', now(), '{}'),
       (5, 103, 'click', now(), '{}'),
       -- ... 10000 行
       (10000, 1100, 'click', now(), '{}');
```

## 异步查询

### 基本概念

异步查询允许客户端立即返回查询 ID，查询在后台执行，客户端可以稍后查询结果。

### 使用异步查询

```bash
# 1. 发起异步查询
clickhouse-client --query="SELECT sleep(1)" --query_id="async_query_1" --async=1

# 2. 查询异步查询状态
clickhouse-client --query="SELECT * FROM system.query_log WHERE query_id = 'async_query_1'"

# 3. 获取查询结果
clickhouse-client --query="SELECT * FROM system.query_log WHERE query_id = 'async_query_1' AND type = 'QueryFinish'"
```

### 异步查询示例

```sql
-- 示例 1: 使用 HTTP 接口异步查询
curl 'http://localhost:8123/?query=SELECT+sleep(1)&wait_end_of_query=0&query_id=async_query_1'

-- 示例 2: 检查查询状态
curl 'http://localhost:8123/?query=SELECT+*+FROM+system.query_log+WHERE+query_id+=+async_query_1'

-- 示例 3: 获取查询结果
curl 'http://localhost:8123/?query=SELECT+*+FROM+system.query_log+WHERE+query_id+=+async_query_1+AND+type+=+QueryFinish'
```

## 异步 Materialize 视图

### 基本概念

异步 Materialize 视图允许在后台执行复杂的聚合查询，提升查询性能。

### 创建异步 Materialize 视图

```sql
-- 创建异步 Materialize 视图
CREATE MATERIALIZED VIEW user_stats_mv_async
ENGINE = AggregatingMergeTree()
ORDER BY (user_id, date)
POPULATE
AS SELECT
    user_id,
    toDate(event_time) as date,
    countState() as event_count,
    sumState(amount) as total_amount
FROM events
GROUP BY user_id, date
SETTINGS mv_insert_thread = 2;  -- 异步插入
```

### 异步 Materialize 视图参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| mv_insert_thread | 1 | Materialize 视图插入线程数 |
| mv_pending_rows_max | 10000 | 最大待处理行数 |

## 异步 Mutation

### 基本概念

异步 Mutation 允许 Mutation 操作在后台执行，减少对查询的影响。

### 配置异步 Mutation

```sql
-- 全局配置（在 config.xml 中）
<clickhouse>
    <mutations_sync>0</mutations_sync>
    <background_pool_size>16</background_pool_size>
</clickhouse>

-- 查询级别配置
ALTER TABLE users
UPDATE status = 'active'
WHERE user_id IN (1, 2, 3)
SETTINGS mutations_sync = 0;  -- 0: 异步, 1: 等待当前分片, 2: 等待所有分片
```

### Mutation 同步模式

| 模式 | 说明 |
|------|------|
| 0 | 异步执行，不等待 |
| 1 | 等待当前分片完成 |
| 2 | 等待所有分片完成 |

### 异步 Mutation 示例

```sql
-- 示例 1: 异步 Mutation
ALTER TABLE users
UPDATE status = 'active'
WHERE user_id IN (1, 2, 3)
SETTINGS mutations_sync = 0;

-- 示例 2: 等待当前分片
ALTER TABLE users
UPDATE status = 'active'
WHERE user_id IN (1, 2, 3)
SETTINGS mutations_sync = 1;

-- 示例 3: 等待所有分片
ALTER TABLE users
UPDATE status = 'active'
WHERE user_id IN (1, 2, 3)
SETTINGS mutations_sync = 2;
```

## 异步操作监控

### 监控异步插入

```sql
-- 查看异步插入统计
SELECT 
    event_time,
    type,
    query_duration_ms,
    async_insert_wait_time_ms,
    async_insert_busy_wait_time_ms,
    async_insert_success,
    async_insert_failed
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query LIKE '%async_insert%'
  AND event_time >= now() - INTERVAL 24 HOUR
ORDER BY event_time DESC
LIMIT 20;
```

### 监控异步查询

```sql
-- 查看异步查询状态
SELECT 
    query_id,
    query,
    type,
    event_time,
    query_duration_ms,
    exception_text
FROM system.query_log
WHERE query_id LIKE 'async%'
ORDER BY event_time DESC
LIMIT 20;
```

### 监控异步 Mutation

```sql
-- 查看 Mutation 状态
SELECT 
    database,
    table,
    mutation_id,
    command,
    is_done,
    parts_to_do,
    progress,
    created_at,
    done_at
FROM system.mutations
ORDER BY created DESC
LIMIT 20;
```

## 异步操作最佳实践

### 1. 选择合适的同步模式

| 场景 | 推荐模式 |
|------|---------|
| 高频插入，不需要立即 | async_insert = 1, wait_for_async_insert = 0 |
| 高频插入，需要确认 | async_insert = 1, wait_for_async_insert = 1 |
| 低频插入，需要确认 | async_insert = 0 |

### 2. 配置合理的参数

```sql
-- ✅ 合理的异步插入配置
INSERT INTO events
SETTINGS async_insert = 1,
        wait_for_async_insert = 0,
        async_insert_max_data_size = 100000000,  -- 100 MB
        async_insert_busy_timeout_ms = 5000,
        async_insert_max_wait_time_ms = 10000
VALUES (...);
```

### 3. 监控异步操作

```sql
-- 定期监控异步操作
SELECT 
    type,
    count() as count,
    avg(query_duration_ms) as avg_duration,
    max(query_duration_ms) as max_duration
FROM system.query_log
WHERE event_time >= now() - INTERVAL 24 HOUR
  AND (query LIKE '%async%' OR type LIKE 'Mutation%')
GROUP BY type
ORDER BY count DESC;
```

### 4. 处理失败的操作

```sql
-- 查看失败的异步操作
SELECT 
    query_id,
    query,
    exception_code,
    exception_text
FROM system.query_log
WHERE type = 'ExceptionWhileProcessing'
  AND query LIKE '%async%'
  AND event_time >= now() - INTERVAL 24 HOUR
ORDER BY event_time DESC
LIMIT 20;
```

## 异步操作检查清单

- [ ] 是否需要异步操作？
  - [ ] 高频插入 → 异步插入
  - [ ] 大量更新 → 异步 Mutation
  - [ ] 复杂查询 → 异步查询

- [ ] 参数是否合理？
  - [ ] max_data_size: 10-100 MB
  - [ ] busy_timeout_ms: 5000-10000
  - [ ] max_wait_time_ms: 10000-60000

- [ ] 是否监控异步操作？
  - [ ] 监控插入性能
  - [ ] 监控查询状态
  - [ ] 监控 Mutation 进度

- [ ] 是否处理失败操作？
  - [ ] 查看异常日志
  - [ ] 重试失败操作
  - [ ] 分析失败原因

## 性能提升

| 异步操作类型 | 性能提升 |
|------------|---------|
| 异步插入 | 2-10x |
| 异步查询 | 1.5-5x（吞吐量）|
| 异步 Mutation | 2-5x（减少查询影响）|
| 异步 Materialize 视图 | 5-20x |

## 相关文档

- [06_bulk_inserts.md](./06_bulk_inserts.md) - 批量插入优化
- [08_mutation_optimization.md](./08_mutation_optimization.md) - Mutation 优化
- [11_query_profiling.md](./11_query_profiling.md) - 查询分析和 Profiling
