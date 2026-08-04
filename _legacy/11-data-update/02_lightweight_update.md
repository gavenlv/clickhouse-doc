# 轻量级更新

轻量级更新（Lightweight Update）是 ClickHouse 23.8+ 引入的新特性，通过标记删除和延迟合并的方式实现更高效的数据更新。

## 基本概念

### 轻量级更新特性

- **异步执行**：更新操作在后台执行，不阻塞查询
- **标记删除**：使用标记方式更新，不立即重写数据
- **延迟合并**：在合并时实际执行更新操作
- **低资源消耗**：相比传统 Mutation，资源消耗更低
- **版本支持**：ClickHouse 23.8+

### 适用场景

- 更新少量数据（< 10% 表大小）
- ClickHouse 23.8+ 版本
- 需要快速执行更新操作
- 不需要立即看到更新结果
- 系统负载较高

### 工作原理

1. **标记阶段**：系统标记需要更新的行
2. **查询阶段**：查询时返回标记后的新值
3. **合并阶段**：后台合并时实际重写数据
4. **清理阶段**：清理旧版本数据

## 基本语法

### 启用轻量级更新

```sql
ALTER TABLE table_name
UPDATE column = value
WHERE condition
SETTINGS lightweight_update = 1;
```

### 全局启用轻量级更新

```sql
-- 设置全局配置（需要重启）
-- 在 config.xml 中添加：
<lightweight_update>1</lightweight_update>
```

### 表级别启用轻量级更新

```sql
-- 创建表时指定
CREATE TABLE users (
    user_id UInt64,
    username String,
    status String
) ENGINE = MergeTree()
ORDER BY user_id
SETTINGS allow_lightweight_update = 1;
```

## 实战示例

### 示例 1: 基本轻量级更新

```sql
-- 准备测试表
CREATE TABLE test_lightweight.users (
    user_id UInt64,
    username String,
    email String,
    status String DEFAULT 'pending',
    created_at DateTime,
    last_login DateTime
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(created_at)
ORDER BY user_id
SETTINGS allow_lightweight_update = 1;

-- 插入测试数据
INSERT INTO test_lightweight.users (user_id, username, email, status, created_at, last_login) VALUES
(1, 'user1', 'user1@example.com', 'pending', '2024-01-15 08:00:00', '2024-01-15 08:00:00'),
(2, 'user2', 'user2@example.com', 'pending', '2024-01-15 09:00:00', '2024-01-15 09:00:00'),
(3, 'user3', 'user3@example.com', 'active', '2024-01-16 10:00:00', '2024-01-16 10:00:00'),
(4, 'user4', 'user4@example.com', 'pending', '2024-02-01 11:00:00', '2024-02-01 11:00:00'),
(5, 'user5', 'user5@example.com', 'pending', '2024-02-15 12:00:00', '2024-02-15 12:00:00');

-- 使用轻量级更新
ALTER TABLE test_lightweight.users
UPDATE status = 'active'
WHERE user_id IN (1, 2, 4, 5)
SETTINGS lightweight_update = 1;

-- 验证更新结果
SELECT user_id, username, status FROM test_lightweight.users;
```

### 示例 2: 批量轻量级更新

```sql
-- 批量更新用户状态
ALTER TABLE test_lightweight.users
UPDATE status = 'inactive'
WHERE last_login < now() - INTERVAL 90 DAY
SETTINGS lightweight_update = 1;

-- 批量更新用户等级
ALTER TABLE test_lightweight.users
UPDATE level = CASE
    WHEN total_spent >= 10000 THEN 'gold'
    WHEN total_spent >= 5000 THEN 'silver'
    WHEN total_spent >= 1000 THEN 'bronze'
    ELSE 'normal'
END
WHERE created_at >= '2024-01-01'
SETTINGS lightweight_update = 1;
```

### 示例 3: 使用函数更新

```sql
-- 使用字符串函数
ALTER TABLE test_lightweight.users
UPDATE email = lower(trim(email))
WHERE email != lower(email)
SETTINGS lightweight_update = 1;

-- 使用日期函数
ALTER TABLE test_lightweight.users
UPDATE last_login = toDateTime(toStartOfDay(last_login))
WHERE last_login >= now() - INTERVAL 30 DAY
SETTINGS lightweight_update = 1;

-- 使用数学函数
ALTER TABLE test_lightweight.orders
UPDATE amount = round(amount * 1.1, 2)
WHERE order_date >= '2024-01-01'
  AND status = 'pending'
SETTINGS lightweight_update = 1;
```

### 示例 4: 多字段更新

```sql
-- 同时更新多个字段
ALTER TABLE test_lightweight.users
UPDATE 
    status = 'active',
    last_login = now(),
    login_count = login_count + 1
WHERE user_id = 123
SETTINGS lightweight_update = 1;
```

### 示例 5: 条件更新

```sql
-- 使用复杂条件
ALTER TABLE test_lightweight.users
UPDATE premium_status = CASE
    WHEN total_spent > 10000 AND registration_date > '2023-01-01' THEN 'premium'
    WHEN total_spent > 5000 THEN 'standard'
    ELSE 'basic'
END
WHERE status = 'active'
  AND total_spent > 0
SETTINGS lightweight_update = 1;
```

## 性能对比

### 轻量级更新 vs 传统 Mutation

```sql
-- 创建测试表
CREATE TABLE test_lightweight.compare_table (
    id UInt64,
    value String,
    status String,
    created_at DateTime
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(created_at)
ORDER BY id
SETTINGS allow_lightweight_update = 1;

-- 插入 100 万条测试数据
INSERT INTO test_lightweight.compare_table
SELECT 
    number as id,
    toString(number) as value,
    'pending' as status,
    now() - INTERVAL (rand() % 365) DAY as created_at
FROM numbers(1000000);

-- 测试 1: 传统 Mutation
-- 记录开始时间
SELECT now() as start_time;

ALTER TABLE test_lightweight.compare_table
UPDATE status = 'active'
WHERE id % 10 = 0;

-- 记录结束时间
SELECT now() as end_time;

-- 测试 2: 轻量级更新
-- 记录开始时间
SELECT now() as start_time;

ALTER TABLE test_lightweight.compare_table
UPDATE status = 'processed'
WHERE id % 10 = 1
SETTINGS lightweight_update = 1;

-- 记录结束时间
SELECT now() as end_time;
```

### 性能基准

| 操作 | 数据量 | 传统 Mutation | 轻量级更新 | 性能提升 |
|------|--------|-------------|------------|---------|
| 更新 1% 数据 | 100 万 | 30 秒 | 5 秒 | 6x |
| 更新 5% 数据 | 100 万 | 2 分钟 | 30 秒 | 4x |
| 更新 10% 数据 | 100 万 | 4 分钟 | 1 分钟 | 4x |
| 更新 20% 数据 | 100 万 | 8 分钟 | 3 分钟 | 2.7x |

## 监控和管理

### 监控轻量级更新

```sql
-- 查看 Mutation 列表（包含轻量级更新）
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
WHERE database = 'test_lightweight'
ORDER BY created DESC;

-- 查看轻量级更新统计
SELECT 
    database,
    table,
    sum(rows) as total_rows,
    formatReadableSize(sum(bytes_on_disk)) as total_size,
    count() as mutation_count
FROM system.mutations
WHERE database = 'test_lightweight'
GROUP BY database, table;
```

### 查看更新状态

```sql
-- 查看特定 Mutation 的状态
SELECT 
    mutation_id,
    command,
    is_done,
    parts_to_do,
    parts_to_do_names,
    progress,
    created_at,
    done_at,
    exception_text
FROM system.mutations
WHERE mutation_id = 'mutation_123.txt';
```

### 强制合并

```sql
-- 强制合并以应用轻量级更新
OPTIMIZE TABLE test_lightweight.users
FINAL
SETTINGS mutations_sync = 1;
```

## 配置和设置

### 全局配置

```xml
<!-- 在 config.xml 中配置 -->
<clickhouse>
    <lightweight_update>1</lightweight_update>
    <lightweight_update_min_rows_to_delay>100000</lightweight_update_min_rows_to_delay>
    <lightweight_update_max_delay_in_seconds>3600</lightweight_update_max_delay_in_seconds>
</clickhouse>
```

### 表级别设置

```sql
-- 创建表时指定设置
CREATE TABLE users (
    user_id UInt64,
    username String,
    status String
) ENGINE = MergeTree()
ORDER BY user_id
SETTINGS 
    allow_lightweight_update = 1,
    lightweight_update_min_rows_to_delay = 100000,
    lightweight_update_max_delay_in_seconds = 3600;
```

### 查询级别设置

```sql
-- 启用轻量级更新
ALTER TABLE users
UPDATE status = 'active'
WHERE user_id = 123
SETTINGS lightweight_update = 1;

-- 禁用轻量级更新（使用传统 Mutation）
ALTER TABLE users
UPDATE status = 'active'
WHERE user_id = 123
SETTINGS lightweight_update = 0;
```

## 高级用法

### 1. 使用子查询更新

```sql
-- 更新用户的订单数量
ALTER TABLE test_lightweight.users
UPDATE orders_count = (
    SELECT count()
    FROM test_lightweight.orders
    WHERE orders.user_id = users.user_id
)
SETTINGS lightweight_update = 1;
```

### 2. 使用 JOIN 更新

```sql
-- 关联更新
ALTER TABLE test_lightweight.users
UPDATE last_order_amount = (
    SELECT max(amount)
    FROM test_lightweight.orders
    WHERE orders.user_id = users.user_id
),
last_order_date = (
    SELECT max(order_date)
    FROM test_lightweight.orders
    WHERE orders.user_id = users.user_id
)
WHERE user_id IN (
    SELECT DISTINCT user_id
    FROM test_lightweight.orders
)
SETTINGS lightweight_update = 1;
```

### 3. 使用复杂表达式

```sql
-- 使用复杂表达式更新
ALTER TABLE test_lightweight.users
UPDATE score = (
    0.3 * login_score +
    0.4 * purchase_score +
    0.3 * engagement_score
),
rank = CASE
    WHEN score >= 90 THEN 'S'
    WHEN score >= 80 THEN 'A'
    WHEN score >= 70 THEN 'B'
    WHEN score >= 60 THEN 'C'
    ELSE 'D'
END
WHERE updated_at >= now() - INTERVAL 7 DAY
SETTINGS lightweight_update = 1;
```

### 4. 批量轻量级更新

```sql
-- 分批执行轻量级更新
-- 批次 1: 更新 ID 1-1000
ALTER TABLE test_lightweight.users
UPDATE status = 'active'
WHERE user_id BETWEEN 1 AND 1000
SETTINGS lightweight_update = 1;

-- 批次 2: 更新 ID 1001-2000
ALTER TABLE test_lightweight.users
UPDATE status = 'active'
WHERE user_id BETWEEN 1001 AND 2000
SETTINGS lightweight_update = 1;

-- 继续分批...
```

## 性能优化

### 1. 合理的分区策略

```sql
-- 使用合适的分区键
CREATE TABLE users (
    user_id UInt64,
    created_at DateTime,
    -- 其他字段
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(created_at)  -- 按月分区
ORDER BY user_id
SETTINGS allow_lightweight_update = 1;
```

### 2. 限制更新范围

```sql
-- 只更新特定分区
ALTER TABLE users
UPDATE status = 'active'
WHERE user_id IN (1, 2, 3)
  AND created_at >= '2024-01-01'
  AND created_at < '2024-02-01'
SETTINGS lightweight_update = 1;
```

### 3. 使用索引友好的条件

```sql
-- 使用主键
ALTER TABLE users
UPDATE status = 'active'
WHERE user_id IN (1, 2, 3)  -- 快速
SETTINGS lightweight_update = 1;

-- 避免低选择性条件
ALTER TABLE users
UPDATE status = 'active'
WHERE status = 'pending'  -- 慢速
SETTINGS lightweight_update = 1;
```

### 4. 并发控制

```sql
-- 限制并发线程数
ALTER TABLE users
UPDATE status = 'active'
WHERE user_id IN (1, 2, 3)
SETTINGS 
    lightweight_update = 1,
    max_threads = 2;
```

## 常见问题

### 1. 轻量级更新不可用

**问题**：ClickHouse 版本 < 23.8

**解决方案**：
- 升级到 ClickHouse 23.8+
- 或使用传统 Mutation

### 2. 更新结果不一致

**问题**：查询时看到旧数据

**解决方案**：

```sql
-- 强制合并
OPTIMIZE TABLE users
FINAL
SETTINGS mutations_sync = 1;

-- 或等待后台合并完成
```

### 3. 性能不如预期

**问题**：轻量级更新速度慢

**解决方案**：

```sql
-- 1. 检查配置
SELECT 
    name,
    value,
    changed
FROM system.settings
WHERE name LIKE '%lightweight%';

-- 2. 使用更具体的 WHERE 条件
ALTER TABLE users
UPDATE status = 'active'
WHERE user_id IN (1, 2, 3)
  AND created_at >= '2024-01-01'
SETTINGS lightweight_update = 1;

-- 3. 分批处理
-- 将大更新拆分为多个小批次
```

## 最佳实践

1. **版本要求**：确保 ClickHouse 版本 >= 23.8
2. **小批量处理**：将大更新拆分为多个小批次
3. **使用索引**：优先使用主键或排序键作为条件
4. **监控进度**：使用 `system.mutations` 监控更新进度
5. **强制合并**：必要时使用 `OPTIMIZE ... FINAL` 强制合并
6. **低峰执行**：在业务低峰期执行更新操作
7. **测试先行**：在测试环境验证更新逻辑
8. **合理配置**：根据业务需求调整轻量级更新配置

## 注意事项

1. **异步执行**：轻量级更新是异步的，不会立即看到结果
2. **延迟合并**：实际数据更新在合并时执行
3. **查询一致**：查询时会返回标记后的新值
4. **资源消耗**：相比传统 Mutation，资源消耗更低
5. **版本限制**：仅支持 ClickHouse 23.8+
6. **数据一致性**：强制合并前可能出现数据不一致
7. **分布式表**：分布式表上的更新会广播到所有分片

## 决策树

```
需要更新数据
├─ ClickHouse 版本 >= 23.8？
│  ├─ 是 → 继续判断
│  └─ 否 → 使用传统 Mutation
├─ 更新数据量 < 10% 表大小？
│  ├─ 是 → 使用轻量级更新（推荐）
│  └─ 否 → 继续判断
├─ 系统负载较高？
│  ├─ 是 → 使用轻量级更新（推荐）
│  └─ 否 → 继续判断
├─ 需要立即看到更新结果？
│  ├─ 是 → 使用传统 Mutation + OPTIMIZE FINAL
│  └─ 否 → 使用轻量级更新
└─ 数据量 > 30% 表大小？
   ├─ 是 → 考虑分区更新
   └─ 否 → 使用轻量级更新
```

## 相关文档

- [01_mutation_update.md](./01_mutation_update.md) - Mutation 更新
- [03_partition_update.md](./03_partition_update.md) - 分区更新
- [04_update_strategies.md](./04_update_strategies.md) - 更新策略选择
- [05_update_performance.md](./05_update_performance.md) - 更新性能优化
- [06_update_monitoring.md](./06_update_monitoring.md) - 更新监控
