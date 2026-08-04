# 分区更新

分区更新是 ClickHouse 中最快、最高效的数据更新方式，通过操作整个分区来实现大批量数据的快速更新。

## 基本概念

### 分区更新特性

- **最快速度**：直接操作分区，无需逐行更新
- **立即生效**：更新操作立即可见
- **低资源消耗**：不重写数据，只是元数据操作
- **适用大数据量**：适合更新大量数据（> 30% 表大小）
- **所有版本支持**：支持所有 ClickHouse 版本

### 适用场景

- 更新整个分区或大部分分区数据
- 数据归档和历史数据更新
- 大批量数据修正
- 重建分区数据
- 需要立即看到更新结果

### 更新方式

1. **REPLACE PARTITION** - 替换分区
2. **EXCHANGE PARTITIONS** - 交换分区
3. **DROP PARTITION** + 重新插入 - 删除后重新插入
4. **ATTACH PARTITION** - 附加分区

## 基本语法

### REPLACE PARTITION

```sql
-- 从另一个表替换分区
ALTER TABLE table_name
REPLACE PARTITION partition_expr
FROM source_table;

-- 替换多个分区
ALTER TABLE table_name
REPLACE PARTITION partition_expr1, partition_expr2, ...
FROM source_table;
```

### EXCHANGE PARTITIONS

```sql
-- 交换分区
ALTER TABLE table1
EXCHANGE PARTITIONS partition_expr
WITH table2;

-- 交换特定分区
ALTER TABLE table1
EXCHANGE PARTITION '202401'
WITH table2;
```

### DROP + INSERT

```sql
-- 删除分区
ALTER TABLE table_name
DROP PARTITION partition_expr;

-- 重新插入数据
INSERT INTO table_name
SELECT * FROM source_table
WHERE partition_condition;
```

## 实战示例

### 示例 1: 使用 REPLACE PARTITION 更新

```sql
-- 准备测试表
CREATE TABLE test_partition.users (
    user_id UInt64,
    username String,
    email String,
    status String,
    created_at DateTime,
    updated_at DateTime
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(created_at)
ORDER BY user_id;

-- 插入原始数据
INSERT INTO test_partition.users VALUES
(1, 'user1', 'user1@example.com', 'pending', '2024-01-15 08:00:00', '2024-01-15 08:00:00'),
(2, 'user2', 'user2@example.com', 'pending', '2024-01-15 09:00:00', '2024-01-15 09:00:00'),
(3, 'user3', 'user3@example.com', 'active', '2024-02-01 10:00:00', '2024-02-01 10:00:00'),
(4, 'user4', 'user4@example.com', 'pending', '2024-02-15 11:00:00', '2024-02-15 11:00:00'),
(5, 'user5', 'user5@example.com', 'pending', '2024-02-20 12:00:00', '2024-02-20 12:00:00');

-- 创建临时表
CREATE TABLE test_partition.users_temp AS test_partition.users;

-- 更新数据（将 status 改为 active）
INSERT INTO test_partition.users_temp
SELECT 
    user_id,
    username,
    email,
    'active' as status,
    created_at,
    now() as updated_at
FROM test_partition.users
WHERE toYYYYMM(created_at) = '202401';

-- 替换分区
ALTER TABLE test_partition.users
REPLACE PARTITION '202401'
FROM test_partition.users_temp;

-- 验证结果
SELECT user_id, username, status, updated_at 
FROM test_partition.users
WHERE toYYYYMM(created_at) = '202401';

-- 清理临时表
DROP TABLE test_partition.users_temp;
```

### 示例 2: 使用 EXCHANGE PARTITIONS 交换分区

```sql
-- 创建两个表
CREATE TABLE test_partition.table1 (
    id UInt64,
    value String,
    created_at DateTime
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(created_at)
ORDER BY id;

CREATE TABLE test_partition.table2 (
    id UInt64,
    value String,
    created_at DateTime
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(created_at)
ORDER BY id;

-- 向 table1 插入数据
INSERT INTO test_partition.table1 VALUES
(1, 'value1', '2024-01-15 08:00:00'),
(2, 'value2', '2024-01-16 09:00:00'),
(3, 'value3', '2024-02-01 10:00:00');

-- 向 table2 插入数据
INSERT INTO test_partition.table2 VALUES
(11, 'value11', '2024-01-15 08:00:00'),
(12, 'value12', '2024-01-16 09:00:00'),
(13, 'value13', '2024-02-01 10:00:00');

-- 交换分区（交换 2024-01 分区）
ALTER TABLE test_partition.table1
EXCHANGE PARTITION '202401'
WITH test_partition.table2;

-- 验证交换结果
SELECT * FROM test_partition.table1 WHERE toYYYYMM(created_at) = '202401';
SELECT * FROM test_partition.table2 WHERE toYYYYMM(created_at) = '202401';
```

### 示例 3: 删除分区后重新插入

```sql
-- 备份分区数据
CREATE TABLE test_partition.users_backup AS test_partition.users;

-- 删除旧分区
ALTER TABLE test_partition.users
DROP PARTITION '202401';

-- 插入更新后的数据
INSERT INTO test_partition.users
SELECT 
    user_id,
    username,
    email,
    'active' as status,
    created_at,
    now() as updated_at
FROM test_partition.users_backup
WHERE toYYYYMM(created_at) = '202401';

-- 验证结果
SELECT user_id, username, status, updated_at 
FROM test_partition.users
WHERE toYYYYMM(created_at) = '202401';

-- 清理备份
DROP TABLE test_partition.users_backup;
```

### 示例 4: 批量更新多个分区

```sql
-- 创建临时表
CREATE TABLE test_partition.users_temp AS test_partition.users;

-- 更新多个分区的数据
INSERT INTO test_partition.users_temp
SELECT 
    user_id,
    username,
    email,
    'inactive' as status,
    created_at,
    now() as updated_at
FROM test_partition.users
WHERE toYYYYMM(created_at) IN ('202311', '202312', '202401');

-- 替换多个分区
ALTER TABLE test_partition.users
REPLACE PARTITION '202311', '202312', '202401'
FROM test_partition.users_temp;

-- 验证结果
SELECT 
    toYYYYMM(created_at) as month,
    count() as count,
    countIf(status = 'inactive') as inactive_count
FROM test_partition.users
GROUP BY month;
```

### 示例 5: 使用 ATTACH PARTITION 附加分区

```sql
-- 创建源表和目标表
CREATE TABLE test_partition.source_table (
    id UInt64,
    value String,
    created_at DateTime
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(created_at)
ORDER BY id;

CREATE TABLE test_partition.target_table (
    id UInt64,
    value String,
    created_at DateTime
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(created_at)
ORDER BY id;

-- 向源表插入数据
INSERT INTO test_partition.source_table VALUES
(1, 'value1', '2024-01-15 08:00:00'),
(2, 'value2', '2024-01-16 09:00:00'),
(3, 'value3', '2024-02-01 10:00:00');

-- 分离分区
ALTER TABLE test_partition.source_table
DETACH PARTITION '202401';

-- 附加分区到目标表
ALTER TABLE test_partition.target_table
ATTACH PARTITION '202401'
FROM test_partition.source_table;

-- 验证结果
SELECT * FROM test_partition.target_table;
```

## 高级应用

### 示例 1: 数据归档

```sql
-- 创建归档表
CREATE TABLE test_partition.users_archive (
    user_id UInt64,
    username String,
    email String,
    status String,
    created_at DateTime,
    updated_at DateTime
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(created_at)
ORDER BY user_id;

-- 归档旧数据（2023 年的数据）
ALTER TABLE test_partition.users_archive
REPLACE PARTITION '202301', '202302', '202303', 
                 '202304', '202305', '202306',
                 '202307', '202308', '202309',
                 '202310', '202311', '202312'
FROM test_partition.users;

-- 验证归档
SELECT 
    toYYYYMM(created_at) as month,
    count() as count
FROM test_partition.users_archive
GROUP BY month
ORDER BY month;
```

### 示例 2: 数据迁移

```sql
-- 创建新表（优化结构）
CREATE TABLE test_partition.users_new (
    user_id UInt64,
    username String,
    email String,
    status String,
    created_at DateTime,
    updated_at DateTime
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(created_at)
ORDER BY (user_id, updated_at)
SETTINGS index_granularity = 8192;

-- 逐月迁移数据
ALTER TABLE test_partition.users_new
REPLACE PARTITION '202401'
FROM test_partition.users;

ALTER TABLE test_partition.users_new
REPLACE PARTITION '202402'
FROM test_partition.users;

-- 继续迁移其他月份...
```

### 示例 3: 数据修正

```sql
-- 创建修正后的数据
CREATE TABLE test_partition.orders_fixed AS test_partition.orders;

-- 修正数据（将所有订单金额增加 10%）
INSERT INTO test_partition.orders_fixed
SELECT 
    order_id,
    user_id,
    product_id,
    amount * 1.1 as amount,
    order_date,
    status
FROM test_partition.orders
WHERE toYYYYMM(order_date) = '202401'
  AND status = 'pending';

-- 替换分区
ALTER TABLE test_partition.orders
REPLACE PARTITION '202401'
FROM test_partition.orders_fixed;

-- 验证修正结果
SELECT 
    order_id,
    amount,
    status
FROM test_partition.orders
WHERE toYYYYMM(order_date) = '202401'
  AND status = 'pending';
```

### 示例 4: 分区滚动更新

```sql
-- 创建临时表
CREATE TABLE test_partition.events_temp AS test_partition.events;

-- 更新最近 3 个月的数据
INSERT INTO test_partition.events_temp
SELECT 
    event_id,
    user_id,
    event_type,
    event_data,
    processed = 1,
    processed_at = now()
FROM test_partition.events
WHERE toYYYYMM(event_time) IN (
    toYYYYMM(now() - INTERVAL 1 MONTH),
    toYYYYMM(now() - INTERVAL 2 MONTH),
    toYYYYMM(now() - INTERVAL 3 MONTH)
);

-- 替换分区
ALTER TABLE test_partition.events
REPLACE PARTITION 
    toYYYYMM(now() - INTERVAL 1 MONTH),
    toYYYYMM(now() - INTERVAL 2 MONTH),
    toYYYYMM(now() - INTERVAL 3 MONTH)
FROM test_partition.events_temp;

-- 验证结果
SELECT 
    toYYYYMM(event_time) as month,
    count() as total,
    countIf(processed = 1) as processed,
    countIf(processed = 0) as unprocessed
FROM test_partition.events
GROUP BY month;
```

### 示例 5: 分区交换进行测试

```sql
-- 创建测试表
CREATE TABLE test_partition.users_test AS test_partition.users;

-- 在测试表上测试更新逻辑
INSERT INTO test_partition.users_test
SELECT 
    user_id,
    username,
    email,
    'active' as status,
    created_at,
    now() as updated_at
FROM test_partition.users
WHERE toYYYYMM(created_at) = '202401';

-- 验证测试结果
SELECT count() FROM test_partition.users_test WHERE status = 'active';

-- 如果测试通过，交换分区到生产表
ALTER TABLE test_partition.users
EXCHANGE PARTITION '202401'
WITH test_partition.users_test;

-- 清理测试表
DROP TABLE test_partition.users_test;
```

## 性能优化

### 1. 使用合理的分区键

```sql
-- 按月分区（推荐）
CREATE TABLE events (
    event_id UInt64,
    user_id UInt64,
    event_time DateTime,
    event_data String
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)  -- 按月分区
ORDER BY (user_id, event_time);

-- 避免过于细粒度的分区
PARTITION BY toYYYYMMDD(event_time)  -- 太多分区，影响性能
```

### 2. 批量操作分区

```sql
-- 一次性替换多个分区（高效）
ALTER TABLE users
REPLACE PARTITION '202401', '202402', '202403'
FROM users_temp;

-- 避免逐个替换（低效）
ALTER TABLE users REPLACE PARTITION '202401' FROM users_temp;
ALTER TABLE users REPLACE PARTITION '202402' FROM users_temp;
ALTER TABLE users REPLACE PARTITION '202403' FROM users_temp;
```

### 3. 使用 EXCHANGE 替代 DROP + INSERT

```sql
-- 使用 EXCHANGE（快速）
ALTER TABLE table1
EXCHANGE PARTITION '202401'
WITH table2;

-- 替代 DROP + INSERT（慢速）
ALTER TABLE table1 DROP PARTITION '202401';
INSERT INTO table1 SELECT * FROM table2 WHERE ...;
```

### 4. 临时表使用

```sql
-- 使用临时表存储更新后的数据
CREATE TABLE temp_users AS users;

-- 更新数据
INSERT INTO temp_users
SELECT * FROM users WHERE ...;

-- 替换分区
ALTER TABLE users
REPLACE PARTITION '202401'
FROM temp_users;

-- 清理临时表
DROP TABLE temp_users;
```

## 监控和验证

### 查看分区信息

```sql
-- 查看表的分区
SELECT 
    partition,
    sum(rows) as total_rows,
    sum(bytes_on_disk) as total_bytes,
    formatReadableSize(sum(bytes_on_disk)) as readable_size
FROM system.parts
WHERE database = 'test_partition' 
  AND table = 'users'
  AND active = 1
GROUP BY partition
ORDER BY partition;
```

### 验证数据更新

```sql
-- 更新前后对比
-- 更新前
SELECT 
    toYYYYMM(created_at) as month,
    status,
    count() as count
FROM users
WHERE toYYYYMM(created_at) = '202401'
GROUP BY month, status;

-- 更新后
SELECT 
    toYYYYMM(created_at) as month,
    status,
    count() as count
FROM users
WHERE toYYYYMM(created_at) = '202401'
GROUP BY month, status;
```

### 监控分区操作

```sql
-- 查看最近的分区操作
SELECT 
    type,
    partition_id,
    partition,
    part_name,
    rows,
    bytes_on_disk,
    event_time
FROM system.part_log
WHERE database = 'test_partition'
  AND table = 'users'
ORDER BY event_time DESC
LIMIT 20;
```

## 常见问题

### 1. 分区不存在

**问题**：`Partition '202401' doesn't exist`

**解决方案**：

```sql
-- 检查分区是否存在
SELECT distinct partition
FROM system.parts
WHERE database = 'test_partition' 
  AND table = 'users'
  AND active = 1;

-- 使用正确的分区名称
```

### 2. 分区结构不匹配

**问题**：`Columns order or types don't match`

**解决方案**：

```sql
-- 确保两个表的结构完全一致
DESCRIBE TABLE test_partition.users;
DESCRIBE TABLE test_partition.users_temp;

-- 如果结构不同，需要先修改表结构
ALTER TABLE test_partition.users_temp
MODIFY COLUMN new_column String;
```

### 3. 分区交换失败

**问题**：`Cannot exchange partitions because engines are different`

**解决方案**：

```sql
-- 确保两个表的引擎相同
SELECT engine FROM system.tables
WHERE database = 'test_partition'
  AND table IN ('users', 'users_temp');

-- 如果引擎不同，需要先修改表引擎
ALTER TABLE test_partition.users_temp
MODIFY ENGINE = MergeTree();
```

## 最佳实践

1. **使用临时表**：使用临时表存储更新后的数据
2. **验证数据**：替换分区前先验证数据正确性
3. **备份数据**：重要操作前先备份
4. **批量操作**：一次性替换多个分区
5. **使用 EXCHANGE**：优先使用 EXCHANGE 而不是 DROP + INSERT
6. **合理分区**：使用合适的分区粒度（通常按月）
7. **低峰执行**：在业务低峰期执行分区操作
8. **监控进度**：监控分区操作的执行情况
9. **清理临时表**：操作完成后及时清理临时表
10. **测试先行**：在生产环境前先在测试环境验证

## 注意事项

1. **立即生效**：分区操作立即可见
2. **原子操作**：分区操作是原子的，不会造成数据不一致
3. **表结构一致**：交换或替换分区需要表结构完全一致
4. **引擎相同**：两个表的引擎必须相同
5. **分区键相同**：分区键的定义必须相同
6. **数据丢失**：DROP PARTITION 会永久删除数据，不可恢复
7. **锁定分区**：分区操作期间会锁定相关分区

## 性能对比

| 操作 | 100 万行 | 1000 万行 | 1 亿行 |
|------|---------|----------|--------|
| Mutation 更新 | 2 分钟 | 20 分钟 | 200 分钟 |
| 轻量级更新 | 30 秒 | 5 分钟 | 50 分钟 |
| 分区更新 | 10 秒 | 1 分钟 | 10 分钟 |

## 相关文档

- [01_mutation_update.md](./01_mutation_update.md) - Mutation 更新
- [02_lightweight_update.md](./02_lightweight_update.md) - 轻量级更新
- [04_update_strategies.md](./04_update_strategies.md) - 更新策略选择
- [05_update_performance.md](./05_update_performance.md) - 更新性能优化
- [07_batch_updates.md](./07_batch_updates.md) - 批量更新实战
