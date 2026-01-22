# Mutation 优化

Mutation 是 ClickHouse 中用于更新和删除数据的机制，合理的 Mutation 优化可以减少对系统性能的影响。

## 基本概念

### Mutation 特性

- **异步执行**：在后台执行，不阻塞查询
- **重操作**：需要重写数据，资源消耗大
- **版本控制**：每次 Mutation 产生新版本的数据
- **不可回滚**：一旦执行，无法回滚

### Mutation 类型

1. **UPDATE** - 更新数据
2. **DELETE** - 删除数据
3. **MATERIALIZE INDEX** - 物化索引

## Mutation 优化策略

### 策略 1: 优先使用分区操作

```sql
-- ✅ 使用分区删除/替换（最快）
CREATE TABLE users_temp AS users;
INSERT INTO users_temp SELECT * FROM users WHERE ...;
ALTER TABLE users REPLACE PARTITION '202401' FROM users_temp;

-- ❌ 使用 Mutation（慢速）
ALTER TABLE users DELETE WHERE toYYYYMM(created_at) = '202401';
```

**性能提升**: 5-20x

### 策略 2: 使用轻量级 Mutation

```sql
-- ✅ 使用轻量级删除（ClickHouse 23.8+）
ALTER TABLE users
DELETE WHERE user_id IN (1, 2, 3)
SETTINGS lightweight_delete = 1;

-- ❌ 使用传统 Mutation
ALTER TABLE users DELETE WHERE user_id IN (1, 2, 3);
```

**性能提升**: 4-6x

### 策略 3: 分批处理

```sql
-- ✅ 分批处理
-- 批次 1
ALTER TABLE users
DELETE WHERE user_id BETWEEN 1 AND 10000;

-- 等待完成后执行下一批次
-- 批次 2
ALTER TABLE users
DELETE WHERE user_id BETWEEN 10001 AND 20000;

-- ❌ 单次大批量 Mutation
ALTER TABLE users DELETE WHERE user_id IN (1, 2, ..., 100000);
```

**性能提升**: 2-3x（减少峰值资源消耗）

### 策略 4: 低峰期执行

```sql
-- ✅ 低峰期执行
ALTER TABLE users
DELETE WHERE created_at < now() - INTERVAL 90 DAY;

-- 或使用定时任务
```

**性能提升**: 1.5-3x（减少对业务查询的影响）

## Mutation 参数优化

### 同步模式

```sql
-- 0: 异步执行（默认）
ALTER TABLE users
DELETE WHERE user_id IN (1, 2, 3)
SETTINGS mutations_sync = 0;

-- 1: 等待当前分片完成
ALTER TABLE users
DELETE WHERE user_id IN (1, 2, 3)
SETTINGS mutations_sync = 1;

-- 2: 等待所有分片完成
ALTER TABLE users
DELETE WHERE user_id IN (1, 2, 3)
SETTINGS mutations_sync = 2;
```

### 并发控制

```sql
-- 限制并发线程数
ALTER TABLE users
DELETE WHERE user_id IN (1, 2, 3)
SETTINGS max_threads = 2;

-- 限制内存使用
ALTER TABLE users
DELETE WHERE user_id IN (1, 2, 3)
SETTINGS max_memory_usage = 10000000000;  -- 10 GB
```

### 优先级

```sql
-- 设置 Mutation 优先级（1-10，默认 5）
ALTER TABLE users
DELETE WHERE user_id IN (1, 2, 3)
SETTINGS priority = 8;
```

### 复制相关

```sql
-- 是否等待复制完成
ALTER TABLE users
DELETE WHERE user_id IN (1, 2, 3)
SETTINGS replication_alter_partitions_sync = 2;  -- 0: 不同步, 1: 当前表, 2: 所有副本
```

## Mutation 监控

### 查看 Mutation 列表

```sql
-- 查看 Mutation 状态
SELECT 
    database,
    table,
    mutation_id,
    command,
    is_done,
    parts_to_do,
    parts_to_do_names,
    progress,
    exception_text,
    created_at,
    done_at
FROM system.mutations
WHERE database = 'my_database'
ORDER BY created DESC;
```

### 监控 Mutation 进度

```sql
-- 实时监控 Mutation 进度
SELECT 
    database,
    table,
    mutation_id,
    command,
    is_done,
    parts_to_do,
    progress,
    elapsed
FROM system.mutations
LEFT JOIN (
    SELECT mutation_id,
        dateDiff('second', created_at, now()) as elapsed
    FROM system.mutations
    WHERE is_done = 0
) USING (mutation_id)
WHERE database = 'my_database'
  AND is_done = 0
ORDER BY created DESC;
```

### 查看 Mutation 历史

```sql
-- 查看最近完成的 Mutation
SELECT 
    database,
    table,
    mutation_id,
    command,
    parts_to_do,
    created_at,
    done_at,
    dateDiff('second', created_at, done_at) as duration_seconds
FROM system.mutations
WHERE is_done = 1
  AND database = 'my_database'
ORDER BY done_at DESC
LIMIT 10;
```

## Mutation 优化示例

### 示例 1: 批量删除

```sql
-- ✅ 分批删除（每批 1 万行）
-- 批次 1
ALTER TABLE users
DELETE WHERE user_id BETWEEN 1 AND 10000
SETTINGS max_threads = 2;

-- 等待完成后执行下一批次
-- 批次 2
ALTER TABLE users
DELETE WHERE user_id BETWEEN 10001 AND 20000
SETTINGS max_threads = 2;

-- ❌ 单次大批量删除
ALTER TABLE users DELETE WHERE user_id IN (1, 2, ..., 20000);
```

**性能提升**: 2-3x

### 示例 2: 分区删除

```sql
-- ✅ 使用分区删除
-- 删除 2023 年的所有分区
ALTER TABLE users
DROP PARTITION '202301', '202302', '202303', '202304',
                '202305', '202306', '202307', '202308',
                '202309', '202310', '202311', '202312';

-- ❌ 使用 Mutation
ALTER TABLE users
DELETE WHERE toYYYYMM(created_at) IN ('202301', '202302', '202303', ..., '202312');
```

**性能提升**: 10-50x

### 示例 3: 轻量级删除

```sql
-- ✅ 使用轻量级删除（ClickHouse 23.8+）
ALTER TABLE users
DELETE WHERE user_id IN (1, 2, 3, ..., 1000)
SETTINGS lightweight_delete = 1;

-- ❌ 使用传统 Mutation
ALTER TABLE users DELETE WHERE user_id IN (1, 2, 3, ..., 1000);
```

**性能提升**: 4-6x

### 示例 4: 组合策略

```sql
-- ✅ 组合策略：新数据用轻量级删除，旧数据用分区删除
-- 新数据（最近 30 天）
ALTER TABLE users
DELETE WHERE created_at >= now() - INTERVAL 30 DAY
  AND user_id IN (1, 2, 3, ..., 1000)
SETTINGS lightweight_delete = 1;

-- 旧数据（30 天前）
CREATE TABLE users_temp AS users;
INSERT INTO users_temp
SELECT * FROM users
WHERE created_at < now() - INTERVAL 30 DAY
  AND status = 'inactive';

ALTER TABLE users
REPLACE PARTITION '202312'
FROM users_temp;

DROP TABLE users_temp;
```

**性能提升**: 5-30x

## Mutation 最佳实践

### 1. 优先分区操作

- **适用场景**：更新/删除 > 30% 的数据
- **方法**：REPLACE PARTITION、DROP PARTITION
- **性能提升**：5-50x

### 2. 使用轻量级 Mutation

- **适用场景**：ClickHouse 23.8+，少量更新/删除
- **方法**：lightweight_delete = 1、lightweight_update = 1
- **性能提升**：4-6x

### 3. 分批处理

- **适用场景**：中等数据量（10-30%）
- **方法**：每批 1 万-10 万行
- **性能提升**：2-3x

### 4. 低峰期执行

- **适用场景**：大规模 Mutation
- **方法**：在业务低峰期执行
- **性能提升**：1.5-3x

### 5. 监控执行

- **监控进度**：使用 `system.mutations` 查看进度
- **监控资源**：使用 `system.metrics` 查看系统负载
- **监控性能**：使用 `system.query_log` 查看执行时间

## Mutation 检查清单

- [ ] 是否优先使用分区操作？
  - [ ] 数据量 > 30%
  - [ ] 可以按分区操作
  - [ ] 使用 REPLACE/DROP PARTITION

- [ ] 是否使用轻量级 Mutation？
  - [ ] ClickHouse 版本 >= 23.8
  - [ ] 数据量 < 10%
  - [ ] 设置 lightweight_delete = 1

- [ ] 是否分批处理？
  - [ ] 每批 1 万-10 万行
  - [ ] 等待前一批完成
  - [ ] 限制并发线程数

- [ ] 是否低峰期执行？
  - [ ] 在业务低峰期执行
  - [ ] 监控系统负载
  - [ ] 限制资源使用

- [ ] 是否监控执行？
  - [ ] 查看 Mutation 进度
  - [ ] 监控系统资源
  - [ ] 检查执行时间

## 性能提升

| 优化方法 | 性能提升 |
|---------|---------|
| 分区操作 | 5-50x |
| 轻量级 Mutation | 4-6x |
| 分批处理 | 2-3x |
| 低峰期执行 | 1.5-3x |
| 并发控制 | 1.5-2x |

## 相关文档

- [09-data-deletion/](../09-data-deletion/) - 数据删除专题
- [11-data-update/](../11-data-update/) - 数据更新专题
- [11_query_profiling.md](./11_query_profiling.md) - 查询分析和 Profiling
