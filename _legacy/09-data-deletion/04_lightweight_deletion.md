# 轻量级删除

轻量级删除（Lightweight Deletion）是 ClickHouse 23.8 引入的新特性，提供了一种更高效的异步删除方式。

## 📋 基本语法

```sql
-- 轻量级删除
ALTER TABLE table_name
DELETE WHERE condition
SETTINGS lightweight_delete = 1;

-- 等价于
ALTER TABLE table_name
DELETE LIGHTWEIGHT WHERE condition;
```

## 🎯 特性

### 异步执行

```sql
-- 轻量级删除是异步的
ALTER TABLE events
DELETE WHERE event_time < '2023-01-01'
SETTINGS lightweight_delete = 1;

-- 删除会立即返回，后台执行
```

### 标记删除

```sql
-- 轻量级删除使用标记机制
-- 数据不会被立即删除，而是标记为已删除

-- 查看被标记删除的数据
SELECT
    _part,
    _block_offset,
    _row_num,
    *
FROM events
WHERE event_time < '2023-01-01'
SETTINGS allow_experimental_lightweight_delete = 1;
```

## 📊 与传统删除对比

| 特性 | Mutation 删除 | 轻量级删除 |
|------|-------------|------------|
| 执行方式 | 同步/异步 | 异步 |
| 数据重写 | ✅ 重写数据 | ❌ 仅标记 |
| 性能影响 | ⭐⭐ 重 | ⭐⭐⭐⭐ 轻 |
| 空间释放 | ❌ 需要合并后 | ❌ 需要合并后 |
| 支持版本 | 所有版本 | ClickHouse 23.8+ |
| 适用场景 | 批量删除 | 少量删除 |

## 🎯 使用场景

### 场景 1: 删除少量数据

```sql
-- 删除少量数据（<10%）
ALTER TABLE events
DELETE WHERE event_id = 12345
SETTINGS lightweight_delete = 1;

-- 删除中等量数据（10-30%）
ALTER TABLE events
DELETE WHERE user_id = 'user123'
SETTINGS lightweight_delete = 1;
```

### 场景 2: GDPR 合规删除

```sql
-- 快速删除用户数据
ALTER TABLE user_events
DELETE WHERE user_id = 'user123'
SETTINGS lightweight_delete = 1;

ALTER TABLE user_profile
DELETE WHERE user_id = 'user123'
SETTINGS lightweight_delete = 1;

-- 记录删除操作
INSERT INTO data_deletion_log
VALUES ('user123', now(), 'lightweight_delete');
```

### 场景 3: 实时数据清理

```sql
-- 实时删除过期数据
CREATE MATERIALIZED VIEW expired_events_mv
ENGINE = MergeTree()
ORDER BY event_id
AS SELECT
    event_id,
    user_id,
    event_time
FROM events
WHERE event_time < now() - INTERVAL 90 DAY;

-- 定期执行轻量级删除
-- 可以通过外部调度器触发
ALTER TABLE events
DELETE WHERE event_time < now() - INTERVAL 90 DAY
SETTINGS lightweight_delete = 1;
```

### 场景 4: 测试数据清理

```sql
-- 删除测试环境数据
ALTER TABLE events
DELETE WHERE environment = 'test'
SETTINGS lightweight_delete = 1;

-- 删除调试数据
ALTER TABLE logs
DELETE WHERE level = 'debug'
SETTINGS lightweight_delete = 1;
```

## 📈 监控轻量级删除

### 查看删除进度

```sql
-- 查看活跃的轻量级删除
SELECT
    query_id,
    query,
    elapsed,
    read_rows,
    written_rows,
    memory_usage
FROM system.processes
WHERE query ILIKE '%lightweight%'
ORDER BY elapsed DESC;
```

### 查看删除效果

```sql
-- 查看被标记删除的数据
SELECT
    _part,
    _block_offset,
    count() as deleted_count
FROM events
WHERE event_time < '2023-01-01'
GROUP BY _part, _block_offset
SETTINGS allow_experimental_lightweight_delete = 1;
```

### 监控存储空间

```sql
-- 监控轻量级删除的空间占用
SELECT
    'Active Rows' as metric,
    sum(rows) as value,
    formatReadableSize(sum(bytes_on_disk)) as size
FROM system.parts
WHERE table = 'events' AND active = 1

UNION ALL

SELECT
    'Marked for Deletion',
    count(),
    formatReadableSize(sum(length(data)))
FROM events
WHERE event_time < '2023-01-01'
SETTINGS allow_experimental_lightweight_delete = 1;
```

## 🎯 实战场景

### 场景 1: 批量删除用户数据

```sql
-- 从用户删除列表中读取要删除的用户 ID
-- 假设有一个表存储了要删除的用户
CREATE TABLE users_to_delete (
    user_id String
) ENGINE = MergeTree()
ORDER BY user_id;

-- 插入要删除的用户 ID
INSERT INTO users_to_delete VALUES
    ('user123'),
    ('user456'),
    ('user789');

-- 执行轻量级删除
ALTER TABLE user_events
DELETE WHERE user_id IN (
    SELECT user_id FROM users_to_delete
)
SETTINGS lightweight_delete = 1;

ALTER TABLE user_profile
DELETE WHERE user_id IN (
    SELECT user_id FROM users_to_delete
)
SETTINGS lightweight_delete = 1;

-- 清空删除列表
TRUNCATE TABLE users_to_delete;
```

### 场景 2: 定期清理脚本

```bash
#!/bin/bash
# daily_cleanup.sh

CLICKHOUSE_HOST="localhost"
CLICKHOUSE_PORT="8123"
DATABASE="your_database"
TABLE="events"
RETENTION_DAYS=90

# 执行轻量级删除
echo "Executing lightweight delete..."

curl -s "$CLICKHOUSE_HOST:$CLICKHOUSE_PORT/?query=$(urlencode "
    ALTER TABLE $DATABASE.$TABLE 
    DELETE WHERE event_time < now() - INTERVAL $RETENTION_DAYS DAY
    SETTINGS lightweight_delete = 1
")"

echo "Lightweight delete initiated"
```

### 场景 3: 监控和告警

```sql
-- 创建监控视图
CREATE VIEW deletion_monitor AS
SELECT
    now() as timestamp,
    'lightweight_delete' as deletion_type,
    count() as rows_marked,
    formatReadableSize(sum(length(data))) as size_marked
FROM events
WHERE event_time < now() - INTERVAL 90 DAY
SETTINGS allow_experimental_lightweight_delete = 1;

-- 定期查询监控数据
SELECT * FROM deletion_monitor
ORDER BY timestamp DESC
LIMIT 1;
```

### 场景 4: 清理已标记的数据

```sql
-- 轻量级删除只是标记数据
-- 实际删除需要通过合并操作

-- 触发合并以清理已标记的数据
OPTIMIZE TABLE events FINAL;

-- 或者等待自然的合并过程
-- 可以调整合并策略加快合并

-- 查看合并进度
SELECT
    table,
    partition,
    sum(rows) as rows,
    count() as parts
FROM system.parts
WHERE table = 'events' AND active = 1
GROUP BY table, partition;
```

## ⚙️ 配置和设置

### 启用轻量级删除

```xml
<!-- 在 config.xml 中启用 -->
<clickhouse>
    <allow_experimental_lightweight_delete>1</allow_experimental_lightweight_delete>
</clickhouse>
```

### 查询级别设置

```sql
-- 在查询中启用
SELECT * FROM events
SETTINGS allow_experimental_lightweight_delete = 1;

-- 执行轻量级删除
ALTER TABLE events
DELETE WHERE event_time < '2023-01-01'
SETTINGS lightweight_delete = 1;
```

### 调整合并策略

```xml
<!-- 调整合并策略以加快已标记数据的清理 -->
<merge_tree>
    <max_bytes_to_merge_at_once>10737418240</max_bytes_to_merge_at_once>
    <max_bytes_to_merge_at_once_space_consumption>107374182400</max_bytes_to_merge_at_once_space_consumption>
</merge_tree>
```

## ⚠️ 注意事项

### 版本限制

```sql
-- 检查 ClickHouse 版本
SELECT version();

-- 轻量级删除需要 ClickHouse 23.8 或更高版本
-- 如果版本过低，会回退到传统的 Mutation 删除
```

### 存储空间

```sql
-- 轻量级删除不会立即释放存储空间
-- 已标记删除的数据仍然占用空间

-- 查看实际占用的空间
SELECT
    'Total on disk' as metric,
    formatReadableSize(sum(bytes_on_disk)) as value
FROM system.parts
WHERE table = 'events' AND active = 1

UNION ALL

SELECT
    'Estimated actual after cleanup',
    formatReadableSize(sum(bytes_on_disk * (1 - 0.3)))  -- 假设 30% 被标记删除
FROM system.parts
WHERE table = 'events' AND active = 1;
```

### 适用范围

```sql
-- 轻量级删除适用于删除少量数据
-- 如果删除大量数据（>30%），应该使用分区删除

-- 判断是否应该使用轻量级删除
SELECT
    count() as total_rows,
    countIf(event_time < '2023-01-01') as rows_to_delete,
    rows_to_delete * 100.0 / total_rows as delete_percentage,
    CASE 
        WHEN rows_to_delete * 100.0 / total_rows < 30 THEN 'Use lightweight delete'
        ELSE 'Use partition deletion'
    END as recommendation
FROM events;
```

## 💡 最佳实践

1. **少量数据**：删除 <30% 的数据时使用轻量级删除
2. **批量删除**：将大量删除拆分为多个小批次
3. **监控空间**：定期监控被标记数据的存储占用
4. **触发合并**：必要时手动触发 OPTIMIZE 清理已标记数据
5. **版本检查**：确认 ClickHouse 版本支持轻量级删除

### 决策树

```
需要删除数据？
├─ 能按分区删除？
│  ├─ 是 → 使用分区删除（最快）
│  └─ 否 → 继续
├─ 删除数据量 < 30%？
│  ├─ 是 → 使用轻量级删除
│  └─ 否 → 继续
├─ 需要立即释放空间？
│  ├─ 是 → 使用 Mutation + OPTIMIZE
│  └─ 否 → 使用轻量级删除
└─ 可以接受删除延迟？
   ├─ 是 → 使用 TTL 自动删除
   └─ 否 → 使用轻量级删除
```

## 📝 相关文档

- [01_partition_deletion.md](./01_partition_deletion.md) - 分区删除
- [02_ttl_deletion.md](./02_ttl_deletion.md) - TTL 自动删除
- [03_mutation_deletion.md](./03_mutation_deletion.md) - Mutation 删除
- [05_deletion_strategies.md](./05_deletion_strategies.md) - 删除策略选择
