# 数据更新专题（已合并 → 07-data-mutation）

> **⚠️ 本目录已合并到 [07-data-mutation](../07-data-mutation/)**
>
> 按重整计划（R3 批次），11-data-update（数据更新）与 09-data-deletion（数据删除）已合并为统一的 `07-data-mutation` 章节。
>
> 合并后的章节覆盖：Mutation 原理、分区操作、TTL、轻量操作、异步插入、并发隔离、实战案例。
>
> 旧文件保留用于参考，新内容请访问 [07-data-mutation/README.md](../07-data-mutation/README.md)。

## 📚 文档目录

### 更新方法
- [01_mutation_update.md](./01_mutation_update.md) - Mutation 更新
- [02_lightweight_update.md](./02_lightweight_update.md) - 轻量级更新
- [03_partition_update.md](./03_partition_update.md) - 分区更新（推荐）

### 更新策略
- [04_update_strategies.md](./04_update_strategies.md) - 更新策略选择
- [05_update_performance.md](./05_update_performance.md) - 更新性能优化
- [06_update_monitoring.md](./06_update_monitoring.md) - 更新监控

### 高级应用
- [07_batch_updates.md](./07_batch_updates.md) - 批量更新实战
- [08_case_studies.md](./08_case_studies.md) - 实战案例分析

## 🎯 快速开始

### Mutation 更新

```sql
-- 更新单个字段
ALTER TABLE users
UPDATE status = 'active'
WHERE user_id = 123;

-- 更新多个字段
ALTER TABLE users
UPDATE 
    status = 'inactive',
    last_login = now()
WHERE user_id = 123;
```

### 轻量级更新（ClickHouse 23.8+）

```sql
-- 轻量级更新
ALTER TABLE users
UPDATE status = 'active'
WHERE user_id = 123
SETTINGS lightweight_update = 1;
```

### 分区更新（最快）

```sql
-- 交换分区
ALTER TABLE users_new
EXCHANGE PARTITIONS '202401' WITH users;

-- 替换分区
ALTER TABLE users
REPLACE PARTITION '202401' FROM users_new;
```

## 📊 更新方法对比

| 方法 | 速度 | 资源占用 | 适用场景 | 立即生效 | ClickHouse 版本 |
|------|------|---------|---------|---------|--------------|
| 分区更新 | ⭐⭐⭐⭐⭐ | ⭐ 低 | 按分区更新大量数据 | ✅ 是 | 所有版本 |
| 轻量级更新 | ⭐⭐⭐⭐ | ⭐⭐ 低 | ClickHouse 23.8+，少量更新 | ⚠️ 异步 | 23.8+ |
| Mutation 更新 | ⭐⭐ | ⭐⭐⭐ 高 | 更新少量或中等量数据 | ⚠️ 异步 | 所有版本 |

## 🎯 常用场景

### 场景 1: 用户状态更新

```sql
-- 更新用户状态
ALTER TABLE users
UPDATE status = 'active'
WHERE user_id IN (1, 2, 3);
```

### 场景 2: 数据修正

```sql
-- 修正错误数据
ALTER TABLE orders
UPDATE amount = amount * 1.1
WHERE order_date >= '2024-01-01';
```

### 场景 3: 批量更新

```sql
-- 批量更新
ALTER TABLE events
UPDATE processed = 1
WHERE event_time < now() - INTERVAL 30 DAY
SETTINGS max_threads = 4;
```

### 场景 4: 分区更新

```sql
-- 使用临时表更新分区
CREATE TABLE users_temp AS users;
INSERT INTO users_temp SELECT * FROM users;
-- 修改数据
ALTER TABLE users
REPLACE PARTITION '202401' FROM users_temp;
```

## 💡 最佳实践

1. **优先分区更新**：最快、最高效的更新方式
2. **小批次处理**：将大更新拆分为多个小批次
3. **监控执行**：使用 `system.mutations` 监控更新进度
4. **低峰执行**：在业务低峰期执行更新操作
5. **使用轻量级更新**：ClickHouse 23.8+ 优先使用轻量级更新
6. **备份优先**：执行更新操作前务必备份数据
7. **合理分区**：使用时间作为分区键提高更新性能
8. **避免高频更新**：ClickHouse 不适合高频更新场景

## ⚠️ 注意事项

1. **异步执行**：Mutation 和轻量级更新都是异步的
2. **资源消耗**：大规模更新会消耗大量系统资源
3. **数据重复**：更新会产生新版本的数据
4. **索引影响**：更新操作可能影响跳数索引
5. **物化视图**：更新操作不会自动更新物化视图
6. **分布式表**：分布式表上的更新会广播到所有分片
7. **事务性**：ClickHouse 不支持传统的事务，更新操作不可回滚

## 🔗 相关文档

- [09-data-deletion/](../09-data-deletion/) - 数据删除专题
- [10-date-update/](../10-date-update/) - 日期时间操作专题
- [06-admin/](../06-admin/) - 运维管理
- [08-information-schema/](../08-information-schema/) - 数据库元数据

## 📖 更多资源

- [ClickHouse ALTER UPDATE 文档](https://clickhouse.com/docs/en/sql-reference/statements/alter/update)
- [ClickHouse Mutation 文档](https://clickhouse.com/docs/en/sql-reference/statements/alter/mutation)
- [ClickHouse 轻量级更新文档](https://clickhouse.com/docs/en/sql-reference/statements/alter/lightweight-update)
