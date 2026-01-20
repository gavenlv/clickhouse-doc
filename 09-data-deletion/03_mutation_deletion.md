# Mutation 删除

Mutation 是 ClickHouse 中通用的数据修改机制，可以删除、更新或重新计算数据。

## 📋 基本语法

```sql
-- 删除数据
ALTER TABLE table_name
DELETE WHERE condition;

-- 更新数据
ALTER TABLE table_name
UPDATE column = expression WHERE condition;

-- 立即执行 Mutation
ALTER TABLE table_name
DELETE WHERE condition
SETTINGS mutations_sync = 1;
```

## 🎯 Mutation 特性

### 异步执行

```sql
-- Mutation 是异步执行的
ALTER TABLE events
DELETE WHERE event_time < '2023-01-01';

-- 查看执行状态
SELECT
    mutation_id,
    command,
    is_done,
    create_time,
    done_time,
    exception_code
FROM system.mutations
WHERE database = 'your_database' AND table = 'your_table'
ORDER BY create_time DESC;
```

### 重操作

```sql
-- Mutation 是重操作，会触发数据重写
-- 查看受影响的行数
SELECT
    mutation_id,
    command,
    parts_to_do_names,
    parts_to_do,
    is_done
FROM system.mutations
WHERE database = 'your_database' AND table = 'your_table';
```

## 📊 删除操作

### 基本删除

```sql
-- 删除特定条件的数据
ALTER TABLE events
DELETE WHERE event_time < '2023-01-01';

-- 删除多个条件
ALTER TABLE events
DELETE WHERE 
    event_time < '2023-01-01'
    OR level = 'debug';

-- 使用子查询
ALTER TABLE events
DELETE WHERE user_id IN (
    SELECT user_id FROM deleted_users
);
```

### 批量删除

```sql
-- 将大删除拆分为多个小批次
-- 批次 1
ALTER TABLE events
DELETE WHERE event_time >= '2022-01-01' AND event_time < '2022-03-01';

-- 批次 2
ALTER TABLE events
DELETE WHERE event_time >= '2022-03-01' AND event_time < '2022-05-01';

-- 批次 3
ALTER TABLE events
DELETE WHERE event_time >= '2022-05-01' AND event_time < '2022-07-01';
```

## 🔄 更新操作

### 单列更新

```sql
-- 更新单列
ALTER TABLE events
UPDATE status = 'archived' WHERE event_time < '2023-01-01';

-- 使用表达式更新
ALTER TABLE events
UPDATE status = CASE 
    WHEN event_time < '2023-01-01' THEN 'archived'
    WHEN event_time < '2023-06-01' THEN 'old'
    ELSE 'current'
END;
```

### 多列更新

```sql
-- 更新多列
ALTER TABLE users
UPDATE 
    last_login = now(),
    login_count = login_count + 1
WHERE user_id = '123';

-- 使用 Map 更新
ALTER TABLE events
UPDATE tags = mapInsert(tags, 'processed', 'true') WHERE id = 123;
```

### 条件更新

```sql
-- 复杂条件更新
ALTER TABLE orders
UPDATE 
    status = 'cancelled',
    cancelled_at = now()
WHERE 
    status = 'pending'
    AND created_at < now() - INTERVAL 7 DAY
    AND payment_status = 'failed';
```

## 🎯 使用场景

### 场景 1: GDPR 数据删除

```sql
-- 删除用户的所有数据
ALTER TABLE user_events
DELETE WHERE user_id = 'user123';

-- 删除用户的敏感信息（保留统计）
ALTER TABLE users
UPDATE 
    email = 'deleted@deleted.com',
    phone = 'deleted',
    address = 'deleted'
WHERE user_id = 'user123';

-- 记录删除操作
INSERT INTO data_deletion_log
SELECT
    user_id,
    'delete' as action,
    now() as timestamp
FROM users
WHERE user_id = 'user123';
```

### 场景 2: 数据修正

```sql
-- 修正错误数据
ALTER TABLE orders
UPDATE total_amount = quantity * unit_price
WHERE total_amount != quantity * unit_price;

-- 修正日期格式错误
ALTER TABLE events
UPDATE event_time = parseDateTimeBestEffort(event_date_str)
WHERE event_time = toDateTime('1970-01-01');
```

### 场景 3: 数据标记

```sql
-- 软删除（标记而非物理删除）
ALTER TABLE messages
UPDATE is_deleted = 1, deleted_at = now()
WHERE message_id IN (
    SELECT message_id FROM moderation_queue
    WHERE action = 'delete'
);

-- 查看软删除的数据
SELECT * FROM messages WHERE is_deleted = 1;

-- 恢复软删除的数据
ALTER TABLE messages
UPDATE is_deleted = 0, deleted_at = NULL
WHERE message_id = 'msg123';
```

### 场景 4: 数据聚合

```sql
-- 对数据进行聚合更新
ALTER TABLE daily_metrics
UPDATE 
    total_value = sum(value)
GROUP BY metric_name, date
WHERE date = today() - INTERVAL 1 DAY;
```

## 📈 监控 Mutation

### 查看执行进度

```sql
-- 查看所有 Mutation
SELECT
    database,
    table,
    mutation_id,
    command,
    is_done,
    parts_to_do,
    parts_to_do_names,
    create_time,
    done_time,
    exception_code,
    exception_text
FROM system.mutations
WHERE database = 'your_database'
ORDER BY create_time DESC;
```

### 监控资源使用

```sql
-- 监控 Mutation 的资源使用
SELECT
    mutation_id,
    command,
    formatReadableSize(total_bytes_read_uncompressed) AS bytes_read,
    formatReadableSize(total_bytes_written_uncompressed) AS bytes_written,
    elapsed,
    cpu_time_ns / 1e9 AS cpu_seconds
FROM system.mutations
WHERE database = 'your_database' AND table = 'your_table'
ORDER BY create_time DESC;
```

### 查看 Mutation 影响

```sql
-- 预估 Mutation 的影响
SELECT
    '预估删除行数' as metric,
    count() as value
FROM your_table
WHERE event_time < '2023-01-01'

UNION ALL

SELECT
    '预估影响的分区数',
    count(DISTINCT partition)
FROM your_table
WHERE event_time < '2023-01-01'

UNION ALL

SELECT
    '预估影响的数据量',
    formatReadableSize(sum(length(data)))
FROM your_table
WHERE event_time < '2023-01-01';
```

## 🎯 实战场景

### 场景 1: 批量删除脚本

```bash
#!/bin/bash
# batch_delete.sh

CLICKHOUSE_HOST="localhost"
CLICKHOUSE_PORT="9000"
DATABASE="your_database"
TABLE="your_table"
BATCH_SIZE="1000000"

# 获取总行数
TOTAL_ROWS=$(clickhouse-client --host=$CLICKHOUSE_HOST --port=$CLICKHOUSE_PORT --query="
    SELECT count() FROM $DATABASE.$TABLE WHERE event_time < '2023-01-01'
")

echo "Total rows to delete: $TOTAL_ROWS"

# 分批删除
OFFSET=0
while [ $OFFSET -lt $TOTAL_ROWS ]; do
    echo "Deleting batch starting at $OFFSET"
    
    clickhouse-client --host=$CLICKHOUSE_HOST --port=$CLICKHOUSE_PORT --query="
        ALTER TABLE $DATABASE.$TABLE 
        DELETE WHERE 
            event_time < '2023-01-01'
            AND row_number_in_all_blocks() > $OFFSET
            AND row_number_in_all_blocks() <= $((OFFSET + BATCH_SIZE))
    "
    
    # 等待完成
    while [ $(clickhouse-client --host=$CLICKHOUSE_HOST --port=$CLICKHOUSE_PORT --query="
        SELECT count() FROM system.mutations 
        WHERE database = '$DATABASE' 
          AND table = '$TABLE' 
          AND is_done = 0
    ") -gt 0 ]; do
        sleep 10
    done
    
    OFFSET=$((OFFSET + BATCH_SIZE))
done
```

### 场景 2: 安全删除流程

```sql
-- 步骤 1: 预估影响
SELECT
    count() AS rows_to_delete,
    formatReadableSize(sum(length(data))) AS size_to_delete,
    count(DISTINCT partition) AS partitions_affected
FROM events
WHERE event_time < '2023-01-01';

-- 步骤 2: 备份数据
INSERT INTO events_backup
SELECT * FROM events
WHERE event_time < '2023-01-01';

-- 步骤 3: 验证备份
SELECT count() FROM events_backup;

-- 步骤 4: 执行删除
ALTER TABLE events
DELETE WHERE event_time < '2023-01-01'
SETTINGS mutations_sync = 1;

-- 步骤 5: 验证删除
SELECT count() FROM events WHERE event_time < '2023-01-01';

-- 步骤 6: 清理备份（如需要）
-- ALTER TABLE events_backup DROP PARTITION '2022-12';
```

### 场景 3: 优先级删除

```sql
-- 按优先级删除数据

-- 先删除最不重要的数据
ALTER TABLE events
DELETE WHERE priority = 'low' AND event_time < '2023-01-01';

-- 等待完成
-- SELECT is_done FROM system.mutations WHERE command LIKE '%priority = low%';

-- 再删除中等重要数据
ALTER TABLE events
DELETE WHERE priority = 'medium' AND event_time < '2023-01-01';

-- 最后删除高优先级数据（如有必要）
ALTER TABLE events
DELETE WHERE priority = 'high' AND event_time < '2023-01-01';
```

### 场景 4: 增量删除

```sql
-- 增量删除策略

-- 第一天：删除最旧的数据
ALTER TABLE events
DELETE WHERE event_time < '2022-01-01'
SETTINGS max_threads = 4;

-- 第二天：删除次旧的数据
ALTER TABLE events
DELETE WHERE 
    event_time >= '2022-01-01' 
    AND event_time < '2022-03-01'
SETTINGS max_threads = 4;

-- 第三天：删除更近的数据
ALTER TABLE events
DELETE WHERE 
    event_time >= '2022-03-01' 
    AND event_time < '2022-06-01'
SETTINGS max_threads = 4;
```

## ⚙️ Mutation 设置

### 同步模式

```sql
-- 异步执行（默认）
ALTER TABLE events
DELETE WHERE event_time < '2023-01-01';

-- 同步执行（等待完成）
ALTER TABLE events
DELETE WHERE event_time < '2023-01-01'
SETTINGS mutations_sync = 1;

-- 同步执行所有之前的 Mutation
ALTER TABLE events
DELETE WHERE event_time < '2023-01-01'
SETTINGS mutations_sync = 2;
```

### 线程数控制

```sql
-- 控制并发线程数
ALTER TABLE events
DELETE WHERE event_time < '2023-01-01'
SETTINGS max_threads = 4;

-- 控制复制线程数（复制表）
ALTER TABLE events
DELETE WHERE event_time < '2023-01-01'
SETTINGS replicated_deduplication_window = 0;
```

## ⚠️ 注意事项

1. **重操作**：Mutation 会触发数据重写，性能影响大
2. **异步执行**：Mutation 是异步的，需要等待完成
3. **锁定**：执行 Mutation 时表会被锁定
4. **空间占用**：Mutation 期间会占用额外的存储空间
5. **不可取消**：Mutation 开始后无法取消

## 💡 最佳实践

1. **优先分区删除**：能用分区删除就不要用 Mutation
2. **小批次处理**：将大删除拆分为多个小批次
3. **低峰执行**：在业务低峰期执行 Mutation
4. **监控进度**：使用 `system.mutations` 监控执行进度
5. **测试先行**：在生产环境前先在测试环境验证

## 📝 相关文档

- [01_partition_deletion.md](./01_partition_deletion.md) - 分区删除
- [02_ttl_deletion.md](./02_ttl_deletion.md) - TTL 自动删除
- [04_lightweight_deletion.md](./04_lightweight_deletion.md) - 轻量级删除
- [05_deletion_strategies.md](./05_deletion_strategies.md) - 删除策略选择
