# Mutation 更新

Mutation 是 ClickHouse 中用于更新和删除数据的传统方法。虽然性能较慢，但它是最通用和最灵活的更新方式。

## 基本概念

### Mutation 特性

- **异步执行**：更新操作在后台执行，不会阻塞查询
- **重操作**：需要重写整个数据分区，资源消耗大
- **版本控制**：每次更新都会产生新版本的数据
- **不可回滚**：一旦提交，无法回滚

### 适用场景

- 更新少量或中等量数据（< 30% 表大小）
- 需要复杂的更新逻辑
- 不需要立即看到更新结果
- ClickHouse 版本 < 23.8

## 基本语法

### 更新单个字段

```sql
ALTER TABLE table_name
UPDATE column = value
WHERE condition;
```

### 更新多个字段

```sql
ALTER TABLE table_name
UPDATE 
    column1 = value1,
    column2 = value2,
    column3 = value3
WHERE condition;
```

### 使用表达式更新

```sql
ALTER TABLE users
UPDATE 
    age = age + 1,
    last_updated = now()
WHERE status = 'active';
```

## 实战示例

### 示例 1: 更新用户状态

```sql
-- 准备测试表
CREATE TABLE test_mutations.users (
    user_id UInt64,
    username String,
    email String,
    status String DEFAULT 'pending',
    created_at DateTime,
    last_login DateTime
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(created_at)
ORDER BY user_id;

-- 插入测试数据
INSERT INTO test_mutations.users (user_id, username, email, status, created_at, last_login) VALUES
(1, 'user1', 'user1@example.com', 'pending', '2024-01-15 08:00:00', '2024-01-15 08:00:00'),
(2, 'user2', 'user2@example.com', 'pending', '2024-01-15 09:00:00', '2024-01-15 09:00:00'),
(3, 'user3', 'user3@example.com', 'active', '2024-01-16 10:00:00', '2024-01-16 10:00:00'),
(4, 'user4', 'user4@example.com', 'pending', '2024-02-01 11:00:00', '2024-02-01 11:00:00'),
(5, 'user5', 'user5@example.com', 'pending', '2024-02-15 12:00:00', '2024-02-15 12:00:00');

-- 更新用户状态
ALTER TABLE test_mutations.users
UPDATE status = 'active'
WHERE user_id IN (1, 2, 4, 5);

-- 验证更新结果
SELECT user_id, username, status FROM test_mutations.users;
```

### 示例 2: 数据修正

```sql
-- 更新订单金额（10% 涨价）
ALTER TABLE test_mutations.orders
UPDATE amount = amount * 1.1
WHERE order_date >= '2024-01-01'
  AND status = 'pending';
```

### 示例 3: 复杂条件更新

```sql
-- 更新用户等级
ALTER TABLE test_mutations.users
UPDATE level = CASE
    WHEN total_spent >= 10000 THEN 'gold'
    WHEN total_spent >= 5000 THEN 'silver'
    WHEN total_spent >= 1000 THEN 'bronze'
    ELSE 'normal'
END
WHERE created_at >= toDateTime('2024-01-01');
```

### 示例 4: 使用子查询更新

```sql
-- 更新用户的最后登录时间
ALTER TABLE test_mutations.users
UPDATE last_login = (
    SELECT max(event_time)
    FROM test_mutations.user_events
    WHERE user_events.user_id = users.user_id
)
WHERE user_id IN (
    SELECT DISTINCT user_id
    FROM test_mutations.user_events
    WHERE event_time >= now() - INTERVAL 7 DAY
);
```

### 示例 5: 批量更新

```sql
-- 分批更新以减少性能影响
ALTER TABLE test_mutations.large_table
UPDATE status = 'processed'
WHERE event_time >= '2024-01-01'
  AND event_time < '2024-02-01'
SETTINGS max_threads = 4,
        mutations_sync = 0;  -- 0: 异步, 1: 等待当前分片, 2: 等待所有分片
```

## Mutation 监控

### 查看 Mutation 列表

```sql
SELECT 
    database,
    table,
    mutation_id,
    command,
    is_done,
    parts_to_do,
    parts_to_do_names,
    progress,
    exception_text
FROM system.mutations
WHERE database = 'test_mutations'
ORDER BY created DESC;
```

### 查看 Mutation 详情

```sql
-- 查看特定 Mutation 的详细信息
SELECT 
    mutation_id,
    command,
    is_done,
    parts_to_do,
    parts_to_do_names,
    progress,
    latest_failed_part,
    latest_fail_reason,
    latest_fail_time
FROM system.mutations
WHERE mutation_id = 'mutation_123.txt';
```

### 监控 Mutation 进度

```sql
-- 实时监控所有正在进行的 Mutation
SELECT 
    database,
    table,
    mutation_id,
    command,
    is_done,
    parts_to_do,
    sum(rows) as total_rows,
    formatReadableSize(sum(bytes_on_disk)) as total_size,
    progress
FROM system.mutations
LEFT JOIN system.parts
USING (database, table)
WHERE is_done = 0
GROUP BY database, table, mutation_id, command, is_done, parts_to_do, progress
ORDER BY progress;
```

### 查看 Mutation 历史

```sql
-- 查看最近完成的 Mutation
SELECT 
    database,
    table,
    mutation_id,
    command,
    is_done,
    parts_to_do,
    parts_to_do_names,
    created_at,
    done_at,
    exception_text
FROM system.mutations
WHERE is_done = 1
ORDER BY done_at DESC
LIMIT 10;
```

## Mutation 设置

### 同步设置

```sql
-- 异步执行（默认）
ALTER TABLE users
UPDATE status = 'active'
WHERE user_id = 123
SETTINGS mutations_sync = 0;

-- 等待当前分片完成
ALTER TABLE users
UPDATE status = 'active'
WHERE user_id = 123
SETTINGS mutations_sync = 1;

-- 等待所有分片完成
ALTER TABLE users
UPDATE status = 'active'
WHERE user_id = 123
SETTINGS mutations_sync = 2;
```

### 并发控制

```sql
-- 限制并发线程数
ALTER TABLE users
UPDATE status = 'active'
WHERE user_id IN (1, 2, 3)
SETTINGS max_threads = 2;

-- 限制内存使用
ALTER TABLE users
UPDATE status = 'active'
WHERE user_id IN (1, 2, 3)
SETTINGS max_memory_usage = 10000000000;  -- 10GB
```

### 优先级设置

```sql
-- 设置 Mutation 优先级（1-10，默认 5）
ALTER TABLE users
UPDATE status = 'active'
WHERE user_id = 123
SETTINGS priority = 8;
```

## 高级用法

### 使用函数更新

```sql
-- 使用字符串函数
ALTER TABLE users
UPDATE email = lower(email)
WHERE status = 'active';

-- 使用日期函数
ALTER TABLE users
UPDATE last_login = toDateTime(toStartOfDay(last_login))
WHERE last_login >= now() - INTERVAL 30 DAY;

-- 使用数学函数
ALTER TABLE orders
UPDATE amount = round(amount * 1.1, 2)
WHERE order_date >= '2024-01-01';
```

### 条件更新

```sql
-- 使用 CASE WHEN
ALTER TABLE users
UPDATE status = CASE
    WHEN last_login < now() - INTERVAL 90 DAY THEN 'inactive'
    WHEN last_login < now() - INTERVAL 30 DAY THEN 'away'
    ELSE 'active'
END
WHERE created_at >= '2024-01-01';

-- 使用多条件
ALTER TABLE users
UPDATE level = 'premium'
WHERE total_spent > 10000
  AND registration_date > '2023-01-01'
  AND status = 'active';
```

### 关联更新

```sql
-- 使用 JOIN 更新
ALTER TABLE users
UPDATE orders_count = (
    SELECT count()
    FROM orders
    WHERE orders.user_id = users.user_id
),
total_spent = (
    SELECT sum(amount)
    FROM orders
    WHERE orders.user_id = users.user_id
)
WHERE user_id IN (
    SELECT DISTINCT user_id FROM orders
);
```

## 性能优化

### 1. 优化分区策略

```sql
-- 使用合理的分区键
CREATE TABLE users (
    user_id UInt64,
    created_at DateTime,
    -- 其他字段
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(created_at)  -- 按月分区
ORDER BY user_id;
```

### 2. 限制更新范围

```sql
-- 只更新特定分区
ALTER TABLE users
UPDATE status = 'active'
WHERE user_id IN (1, 2, 3)
  AND created_at >= '2024-01-01'
  AND created_at < '2024-02-01';
```

### 3. 使用更具体的条件

```sql
-- 使用主键
ALTER TABLE users
UPDATE status = 'active'
WHERE user_id = 123;  -- 快速

-- 避免低选择性条件
ALTER TABLE users
UPDATE status = 'active'
WHERE email LIKE '%@example.com';  -- 慢速
```

### 4. 分批处理

```sql
-- 将大更新拆分为小批次
-- 批次 1
ALTER TABLE users
UPDATE status = 'active'
WHERE user_id BETWEEN 1 AND 1000;

-- 批次 2
ALTER TABLE users
UPDATE status = 'active'
WHERE user_id BETWEEN 1001 AND 2000;

-- 继续分批...
```

## 常见问题

### 1. Mutation 卡住不执行

**问题**：Mutation 状态一直显示 `is_done = 0`

**解决方案**：

```sql
-- 检查 Mutation 状态
SELECT * FROM system.mutations
WHERE is_done = 0;

-- 检查是否有锁
SELECT * FROM system.replication_queue
WHERE type = 'Mutation';

-- 检查错误信息
SELECT exception_text FROM system.mutations
WHERE is_done = 0;
```

### 2. Mutation 失败

**问题**：Mutation 执行失败

**解决方案**：

```sql
-- 查看失败原因
SELECT 
    mutation_id,
    command,
    latest_failed_part,
    latest_fail_reason,
    latest_fail_time
FROM system.mutations
WHERE is_done = 1
  AND exception_text != '';

-- 修复后重新执行 Mutation
ALTER TABLE users
UPDATE status = 'active'
WHERE user_id IN (1, 2, 3);
```

### 3. 性能问题

**问题**：Mutation 执行时间过长

**解决方案**：

```sql
-- 1. 检查分区大小
SELECT 
    partition,
    sum(rows) as rows,
    formatReadableSize(sum(bytes_on_disk)) as size
FROM system.parts
WHERE table = 'users'
  AND active = 1
GROUP BY partition
ORDER BY size DESC;

-- 2. 使用更具体的 WHERE 条件
ALTER TABLE users
UPDATE status = 'active'
WHERE user_id IN (1, 2, 3)
  AND created_at >= '2024-01-01';

-- 3. 分批处理
ALTER TABLE users
UPDATE status = 'active'
WHERE user_id IN (1, 2, 3)
SETTINGS max_threads = 2;
```

## 最佳实践

1. **小批量处理**：将大更新拆分为多个小批次
2. **低峰执行**：在业务低峰期执行更新操作
3. **监控进度**：使用 `system.mutations` 监控更新进度
4. **使用合适的分区键**：减少需要重写的分区数量
5. **避免高频更新**：ClickHouse 不适合高频更新场景
6. **备份重要数据**：执行更新前务必备份
7. **测试先行**：在测试环境验证更新逻辑
8. **使用轻量级更新**：ClickHouse 23.8+ 优先使用轻量级更新

## 注意事项

1. **异步执行**：Mutation 是异步的，不会立即看到结果
2. **资源消耗**：大规模更新会消耗大量 CPU 和 IO
3. **数据重复**：更新会产生新版本的数据，直到合并
4. **索引影响**：更新操作会重写数据，影响跳数索引
5. **物化视图**：更新操作不会自动更新物化视图
6. **分布式表**：分布式表上的更新会广播到所有分片
7. **版本控制**：每次更新都会创建新版本，增加存储

## 相关文档

- [02_lightweight_update.md](./02_lightweight_update.md) - 轻量级更新
- [03_partition_update.md](./03_partition_update.md) - 分区更新
- [04_update_strategies.md](./04_update_strategies.md) - 更新策略选择
- [05_update_performance.md](./05_update_performance.md) - 更新性能优化
- [06_update_monitoring.md](./06_update_monitoring.md) - 更新监控
