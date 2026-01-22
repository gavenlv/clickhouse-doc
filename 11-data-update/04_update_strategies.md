# 更新策略选择

本文档提供 ClickHouse 数据更新方法的详细对比和选择指南，帮助您根据不同场景选择最合适的更新策略。

## 更新方法对比

### 详细对比表

| 特性 | Mutation 更新 | 轻量级更新 | 分区更新 |
|------|-------------|------------|---------|
| **执行方式** | 异步重写 | 标记删除 | 元数据操作 |
| **执行速度** | ⭐⭐ | ⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ |
| **资源消耗** | ⭐⭐⭐ 高 | ⭐⭐ 低 | ⭐ 低 |
| **数据量** | 中等 | 小量 | 大量 |
| **立即生效** | ⚠️ 异步 | ⚠️ 异步 | ✅ 立即 |
| **可回滚** | ❌ 不可 | ❌ 不可 | ❌ 不可 |
| **版本要求** | 所有版本 | 23.8+ | 所有版本 |
| **适用场景** | 中等量更新 | 少量更新 | 大量更新 |
| **CPU 消耗** | 高 | 中 | 低 |
| **IO 消耗** | 高 | 中 | 低 |
| **内存消耗** | 中 | 低 | 低 |
| **网络开销** | 高 | 中 | 低 |

### 性能基准

#### 小数据量更新（1% 表大小）

| 方法 | 100 万行 | 1000 万行 | 1 亿行 |
|------|---------|----------|--------|
| Mutation | 30 秒 | 5 分钟 | 50 分钟 |
| 轻量级更新 | 5 秒 | 1 分钟 | 10 分钟 |
| 分区更新 | 10 秒 | 2 分钟 | 20 分钟 |

#### 中等数据量更新（10% 表大小）

| 方法 | 100 万行 | 1000 万行 | 1 亿行 |
|------|---------|----------|--------|
| Mutation | 2 分钟 | 20 分钟 | 200 分钟 |
| 轻量级更新 | 30 秒 | 5 分钟 | 50 分钟 |
| 分区更新 | 15 秒 | 3 分钟 | 30 分钟 |

#### 大数据量更新（50% 表大小）

| 方法 | 100 万行 | 1000 万行 | 1 亿行 |
|------|---------|----------|--------|
| Mutation | 10 分钟 | 100 分钟 | 1000 分钟 |
| 轻量级更新 | 3 分钟 | 30 分钟 | 300 分钟 |
| 分区更新 | 30 秒 | 5 分钟 | 50 分钟 |

## 完整决策树

```
需要更新数据
│
├─ 1. 数据量占总表比例？
│   ├─ > 30% → 使用分区更新
│   │   ├─ 能重建整个分区？ → REPLACE PARTITION
│   │   └─ 需要临时交换？ → EXCHANGE PARTITIONS
│   │
│   ├─ 10-30% → 继续判断
│   │   ├─ ClickHouse 版本 >= 23.8？ → 使用轻量级更新
│   │   └─ ClickHouse 版本 < 23.8 → 使用 Mutation
│   │
│   └─ < 10% → 继续判断
│       ├─ ClickHouse 版本 >= 23.8？ → 使用轻量级更新
│       ├─ 系统负载较高？ → 使用轻量级更新
│       └─ 需要立即生效？ → 使用 Mutation + OPTIMIZE
│
├─ 2. 是否需要立即看到更新结果？
│   ├─ 是 → 使用分区更新或 Mutation + OPTIMIZE
│   └─ 否 → 继续判断
│
├─ 3. 系统负载如何？
│   ├─ 高 → 使用轻量级更新或分区更新
│   └─ 低 → 使用 Mutation
│
├─ 4. 更新频率？
│   ├─ 高频（每分钟） → 重新设计表结构，使用追加模式
│   ├─ 中频（每小时） → 使用轻量级更新
│   └─ 低频（每天/周） → 使用分区更新或 Mutation
│
└─ 5. 数据一致性要求？
    ├─ 强一致性 → 使用分区更新
    └─ 最终一致性 → 使用 Mutation 或轻量级更新
```

## 场景指南

### 场景 1: 日志数据更新

**场景描述**：需要更新日志表中特定时间段的数据状态。

**推荐策略**：分区更新

**理由**：
- 日志数据通常按时间分区
- 更新通常针对特定时间段
- 数据量可能很大

**示例**：

```sql
-- 创建临时表
CREATE TABLE logs_temp AS logs;

-- 更新数据
INSERT INTO logs_temp
SELECT 
    event_id,
    user_id,
    event_type,
    'processed' as status,
    event_time
FROM logs
WHERE event_time >= '2024-01-01'
  AND event_time < '2024-02-01';

-- 替换分区
ALTER TABLE logs
REPLACE PARTITION '202401'
FROM logs_temp;

-- 清理
DROP TABLE logs_temp;
```

### 场景 2: 用户状态更新

**场景描述**：需要更新少量用户的状态信息。

**推荐策略**：轻量级更新（23.8+）或 Mutation

**理由**：
- 更新数据量小（< 10%）
- 需要快速执行
- 对实时性要求不高

**示例**：

```sql
-- 轻量级更新（ClickHouse 23.8+）
ALTER TABLE users
UPDATE status = 'active',
    last_updated = now()
WHERE user_id IN (1, 2, 3, 4, 5)
SETTINGS lightweight_update = 1;

-- 或使用 Mutation
ALTER TABLE users
UPDATE status = 'active',
    last_updated = now()
WHERE user_id IN (1, 2, 3, 4, 5);
```

### 场景 3: 数据修正

**场景描述**：发现历史数据错误，需要修正大量数据。

**推荐策略**：分区更新

**理由**：
- 修正数据量通常很大
- 涉及多个时间分区
- 需要确保数据一致性

**示例**：

```sql
-- 创建修正表
CREATE TABLE orders_fixed AS orders;

-- 修正数据（所有金额增加 10%）
INSERT INTO orders_fixed
SELECT 
    order_id,
    user_id,
    product_id,
    amount * 1.1 as amount,
    order_date,
    status
FROM orders
WHERE toYYYYMM(order_date) IN ('202401', '202402', '202403');

-- 替换分区
ALTER TABLE orders
REPLACE PARTITION '202401', '202402', '202403'
FROM orders_fixed;

-- 清理
DROP TABLE orders_fixed;
```

### 场景 4: 实时数据更新

**场景描述**：需要实时更新少量数据（如订单状态）。

**推荐策略**：轻量级更新（23.8+）或重新设计

**理由**：
- 更新频率高
- 每次更新数据量小
- 对实时性要求高

**示例**：

```sql
-- 方案 1: 轻量级更新
ALTER TABLE orders
UPDATE status = 'completed',
    completed_at = now()
WHERE order_id = 12345
SETTINGS lightweight_update = 1;

-- 方案 2: 重新设计表结构（追加模式）
-- 原表: orders
-- 新表: order_events (事件日志)
-- 查询时取最新事件
```

### 场景 5: 数据归档

**场景描述**：需要将旧数据归档到归档表。

**推荐策略**：分区更新（EXCHANGE PARTITIONS）

**理由**：
- 需要移动整个分区
- 操作速度快
- 不影响查询

**示例**：

```sql
-- 创建归档表
CREATE TABLE orders_archive (
    order_id UInt64,
    user_id UInt64,
    amount Float64,
    order_date DateTime,
    status String
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(order_date)
ORDER BY order_id;

-- 交换分区
ALTER TABLE orders_archive
EXCHANGE PARTITION '202301'
WITH orders;

-- 继续交换其他月份...
```

## 策略组合

### 组合 1: 轻量级更新 + 分区更新

**适用场景**：需要频繁更新最新数据，同时定期归档旧数据。

**示例**：

```sql
-- 1. 最新数据使用轻量级更新
ALTER TABLE events
UPDATE status = 'processed'
WHERE event_time >= now() - INTERVAL 7 DAY
SETTINGS lightweight_update = 1;

-- 2. 旧数据使用分区更新归档
ALTER TABLE events_archive
EXCHANGE PARTITION '202312'
WITH events;
```

### 组合 2: Mutation + 物化视图

**适用场景**：需要实时统计更新数据。

**示例**：

```sql
-- 创建物化视图
CREATE MATERIALIZED VIEW user_stats_mv
ENGINE = SummingMergeTree()
ORDER BY (user_id, date)
AS SELECT
    user_id,
    toDate(event_time) as date,
    count() as event_count,
    sum(amount) as total_amount
FROM events
GROUP BY user_id, date;

-- 使用 Mutation 更新原表
ALTER TABLE events
UPDATE status = 'processed'
WHERE event_time >= now() - INTERVAL 30 DAY;
```

### 组合 3: 分区更新 + 定期合并

**适用场景**：需要批量更新并保持查询性能。

**示例**：

```sql
-- 1. 使用分区更新
ALTER TABLE users
REPLACE PARTITION '202401'
FROM users_temp;

-- 2. 定期合并
OPTIMIZE TABLE users
PARTITION '202401'
FINAL;
```

## 策略评估表

### 评估维度

| 评估维度 | 权重 | Mutation | 轻量级更新 | 分区更新 |
|---------|------|----------|------------|---------|
| **执行速度** | 30% | 6/10 | 8/10 | 10/10 |
| **资源消耗** | 25% | 4/10 | 8/10 | 10/10 |
| **数据一致性** | 20% | 8/10 | 7/10 | 10/10 |
| **易用性** | 15% | 8/10 | 9/10 | 6/10 |
| **灵活性** | 10% | 10/10 | 9/10 | 7/10 |
| **总分** | 100% | 6.9/10 | 8.25/10 | 8.9/10 |

### 综合评分

1. **分区更新**: 8.9/10 - 最适合大数据量更新
2. **轻量级更新**: 8.25/10 - 最适合中小数据量更新（23.8+）
3. **Mutation 更新**: 6.9/10 - 通用但性能较差

## 最佳实践

### 1. 设计阶段的考虑

```sql
-- 合理的分区策略
CREATE TABLE events (
    event_id UInt64,
    user_id UInt64,
    event_time DateTime,
    event_data String
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)  -- 按月分区
ORDER BY (user_id, event_time);
```

### 2. 更新前的准备

```sql
-- 1. 备份数据
CREATE TABLE users_backup AS users;

-- 2. 检查更新范围
SELECT 
    count() as total_rows,
    formatReadableSize(sum(bytes_on_disk)) as total_size
FROM system.parts
WHERE table = 'users'
  AND partition IN ('202401', '202402');

-- 3. 在测试环境验证
-- 先在测试表上执行更新
```

### 3. 更新时的监控

```sql
-- 监控 Mutation 进度
SELECT 
    mutation_id,
    command,
    is_done,
    parts_to_do,
    progress
FROM system.mutations
WHERE database = 'current_db'
  AND table = 'users'
ORDER BY created DESC;
```

### 4. 更新后的验证

```sql
-- 验证更新结果
SELECT 
    status,
    count() as count
FROM users
WHERE toYYYYMM(created_at) = '202401'
GROUP BY status;
```

## 常见错误

### 错误 1: 使用 Mutation 更新大量数据

**问题**：更新 50% 的表数据，导致集群负载过高。

**正确做法**：使用分区更新

```sql
-- 错误做法
ALTER TABLE users UPDATE status = 'active';

-- 正确做法
CREATE TABLE users_temp AS users;
INSERT INTO users_temp SELECT * FROM users WHERE ...;
ALTER TABLE users REPLACE PARTITION '202401' FROM users_temp;
```

### 错误 2: 高频使用轻量级更新

**问题**：每分钟执行一次轻量级更新，导致大量标记未合并。

**正确做法**：重新设计表结构，使用追加模式

```sql
-- 错误做法
-- 每分钟执行一次
ALTER TABLE orders UPDATE status = 'new' WHERE order_id = x;

-- 正确做法
-- 使用事件日志表
CREATE TABLE order_events (
    order_id UInt64,
    event_type String,
    event_time DateTime,
    event_data String
) ENGINE = MergeTree()
ORDER BY (order_id, event_time);

-- 查询时取最新事件
```

### 错误 3: 不验证就执行分区更新

**问题**：直接执行分区替换，导致数据错误。

**正确做法**：先验证后更新

```sql
-- 1. 先验证数据
SELECT count() FROM users_temp WHERE status = 'active';

-- 2. 对比数据
SELECT status, count() FROM users WHERE ... GROUP BY status;
SELECT status, count() FROM users_temp WHERE ... GROUP BY status;

-- 3. 确认无误后再替换
ALTER TABLE users REPLACE PARTITION '202401' FROM users_temp;
```

## 策略选择检查清单

使用以下检查清单来选择合适的更新策略：

- [ ] 数据量占总表比例？
  - [ ] < 10% → 考虑轻量级更新
  - [ ] 10-30% → 考虑轻量级更新或 Mutation
  - [ ] > 30% → 考虑分区更新

- [ ] ClickHouse 版本？
  - [ ] < 23.8 → 使用 Mutation 或分区更新
  - [ ] >= 23.8 → 优先使用轻量级更新

- [ ] 是否需要立即生效？
  - [ ] 是 → 使用分区更新
  - [ ] 否 → 使用轻量级更新或 Mutation

- [ ] 系统负载如何？
  - [ ] 高 → 使用轻量级更新或分区更新
  - [ ] 低 → 可以使用 Mutation

- [ ] 更新频率？
  - [ ] 高频 → 重新设计表结构
  - [ ] 中频 → 使用轻量级更新
  - [ ] 低频 → 使用分区更新或 Mutation

- [ ] 数据一致性要求？
  - [ ] 强一致性 → 使用分区更新
  - [ ] 最终一致性 → 使用轻量级更新或 Mutation

- [ ] 是否有备份？
  - [ ] 是 → 可以执行更新
  - [ ] 否 → 先备份再更新

## 相关文档

- [01_mutation_update.md](./01_mutation_update.md) - Mutation 更新详解
- [02_lightweight_update.md](./02_lightweight_update.md) - 轻量级更新详解
- [03_partition_update.md](./03_partition_update.md) - 分区更新详解
- [05_update_performance.md](./05_update_performance.md) - 更新性能优化
- [07_batch_updates.md](./07_batch_updates.md) - 批量更新实战
