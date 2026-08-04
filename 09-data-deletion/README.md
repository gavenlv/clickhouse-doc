# 数据删除专题（已合并 → 07-data-mutation）

> **⚠️ 本目录已合并到 [07-data-mutation](../07-data-mutation/)**
>
> 按重整计划（R3 批次），09-data-deletion（数据删除）与 11-data-update（数据更新）已合并为统一的 `07-data-mutation` 章节。
>
> 合并后的章节覆盖：Mutation 原理、分区操作、TTL、轻量操作、异步插入、并发隔离、实战案例。
>
> 旧文件保留用于参考，新内容请访问 [07-data-mutation/README.md](../07-data-mutation/README.md)。

## 📚 文档目录

### 删除方法
- [01_partition_deletion.md](./01_partition_deletion.md) - 分区删除（推荐）
- [02_ttl_deletion.md](./02_ttl_deletion.md) - TTL 自动删除
- [03_mutation_deletion.md](./03_mutation_deletion.md) - Mutation 删除
- [04_lightweight_deletion.md](./04_lightweight_deletion.md) - 轻量级删除

### 策略和优化
- [05_deletion_strategies.md](./05_deletion_strategies.md) - 删除策略选择
- [06_deletion_performance.md](./06_deletion_performance.md) - 删除性能优化
- [07_deletion_monitoring.md](./07_deletion_monitoring.md) - 删除监控

## 🎯 快速开始

### 方法 1: 分区删除（推荐）

```sql
-- 删除整个分区（最快）
ALTER TABLE your_table
DROP PARTITION '2023-01';
```

### 方法 2: TTL 自动删除

```sql
-- 创建表时设置 TTL
CREATE TABLE your_table (
    id UInt64,
    event_time DateTime,
    data String
) ENGINE = MergeTree
PARTITION BY toYYYYMM(event_time)
ORDER BY id
TTL event_time + INTERVAL 90 DAY;
```

### 方法 3: Mutation 删除

```sql
-- 删除特定条件的数据
ALTER TABLE your_table
DELETE WHERE event_time < '2023-01-01';
```

### 方法 4: 轻量级删除（ClickHouse 23.8+）

```sql
-- 轻量级删除（异步）
ALTER TABLE your_table
DELETE WHERE event_time < '2023-01-01'
SETTINGS lightweight_delete = 1;
```

## 📊 删除方法对比

| 方法 | 速度 | 适用场景 | 优点 | 缺点 |
|------|------|---------|------|------|
| 分区删除 | ⭐⭐⭐⭐⭐ | 删除大量历史数据 | 即时、高效、无额外开销 | 只能按分区删除 |
| TTL 自动删除 | ⭐⭐⭐⭐ | 定期清理旧数据 | 自动化、无需手动干预 | 延迟删除、需要合理配置 |
| Mutation 删除 | ⭐⭐ | 删除少量数据 | 灵活、可按条件删除 | 重操作、性能影响大 |
| 轻量级删除 | ⭐⭐⭐⭐ | ClickHouse 23.8+ | 异步、性能影响小 | 需要新版、支持有限 |

## 🎯 选择指南

### 使用分区删除当：
- 需要删除整个分区的数据
- 分区键可以覆盖删除条件
- 追求最快的删除速度
- 不需要保留部分数据

### 使用 TTL 自动删除当：
- 有固定的数据保留策略
- 需要定期自动清理
- 不想手动执行删除操作
- 可以接受删除延迟

### 使用 Mutation 删除当：
- 需要删除少量数据
- 删除条件复杂（非分区键）
- 需要精确控制删除时机
- 不在意删除期间的性能影响

### 使用轻量级删除当：
- 使用 ClickHouse 23.8 或更高版本
- 需要删除少量或中等量数据
- 希望删除操作异步执行
- 可以接受最终一致性

## 🚀 常用场景

### 场景 1: 清理日志数据

```sql
-- 按月清理旧日志（推荐）
ALTER TABLE logs
DROP PARTITION '2023-06';

-- 或使用 TTL 自动清理
ALTER TABLE logs
MODIFY TTL event_time + INTERVAL 30 DAY;
```

### 场景 2: 删除用户数据（GDPR）

```sql
-- 删除特定用户的所有数据
ALTER TABLE user_events
DELETE WHERE user_id = 'user123';

-- 使用轻量级删除（更高效）
ALTER TABLE user_events
DELETE WHERE user_id = 'user123'
SETTINGS lightweight_delete = 1;
```

### 场景 3: 删除测试数据

```sql
-- 删除测试环境数据
ALTER TABLE events
DELETE WHERE environment = 'test';
```

### 场景 4: 数据归档

```sql
-- 先导出数据到归档表
INSERT INTO events_archive
SELECT * FROM events
WHERE event_time < '2023-01-01';

-- 再删除原表数据
ALTER TABLE events
DROP PARTITION '2022-12';
```

## ⚠️ 重要注意事项

1. **备份优先**：执行删除操作前务必备份数据
2. **测试先行**：在生产环境操作前先在测试环境验证
3. **监控资源**：删除操作会消耗大量 I/O 和 CPU，需要监控
4. **时间窗口**：在低峰期执行删除操作
5. **异步执行**：Mutation 是异步操作，需要等待完成

## 💡 最佳实践

1. **优先使用分区删除**：这是最快、最安全的删除方式
2. **合理设置 TTL**：避免手动删除的繁琐
3. **批量删除**：将大量删除操作拆分为多个小批次
4. **定期维护**：定期清理非活动数据块
5. **监控删除进度**：使用 `system.mutations` 监控删除进度

## 📖 相关文档

- [00-infra/DATA_DEDUP_GUIDE.md](../00-infra/DATA_DEDUP_GUIDE.md) - 数据去重指南
- [06-admin/BACKUP_RECOVERY_GUIDE.md](../06-admin/BACKUP_RECOVERY_GUIDE.md) - 备份恢复指南
- [08-information-schema/03_partitions_parts.md](../08-information-schema/03_partitions_parts.md) - 分区和数据块
