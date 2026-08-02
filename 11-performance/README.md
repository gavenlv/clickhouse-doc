# 性能优化专题

> **⚠️ 重整标注（2026-08-02）**
> 本章节编号 `11-performance` 与 `11-data-update` 冲突。按重整计划，本章节将在 **R7 批次** 重命名为 `08-performance`（合并 `02-advance/01_performance_optimization.sql` 与 `17-best-practices/03_query_optimization.sql`，并补充 Projections/JOIN 策略）。
> 当前内容保留可用，详见 [重整计划](../.trae/documents/clickhouse-tutorial-reorg-plan.md)。

本专题介绍 ClickHouse 的性能优化技术，包括查询优化、索引优化、分区优化、缓存优化等。

## 📚 文档目录

### 基础优化
- [01_query_optimization.md](./01_query_optimization.md) - 查询优化基础
- [02_primary_indexes.md](./02_primary_indexes.md) - 主键索引优化
- [03_partitioning.md](./03_partitioning.md) - 分区键优化
- [04_skipping_indexes.md](./04_skipping_indexes.md) - 数据跳数索引

### 高级优化
- [05_prewhere_optimization.md](./05_prewhere_optimization.md) - PREWHERE 优化
- [06_bulk_inserts.md](./06_bulk_inserts.md) - 批量插入优化
- [07_asynchronous_operations.md](./07_asynchronous_operations.md) - 异步操作优化
- [08_mutation_optimization.md](./08_mutation_optimization.md) - Mutation 优化

### 数据类型优化
- [09_data_types.md](./09_data_types.md) - 数据类型优化（避免 Nullable）
- [10_common_patterns.md](./10_common_patterns.md) - 常见性能模式

### 查询分析
- [11_query_profiling.md](./11_query_profiling.md) - 查询分析和 Profiling
- [12_analyzer.md](./12_analyzer.md) - 查询分析器

### 缓存优化
- [13_caching.md](./13_caching.md) - 缓存优化（查询缓存、条件缓存、页缓存）

### 硬件优化
- [14_hardware_tuning.md](./14_hardware_tuning.md) - 硬件调优和测试

## 🎯 快速开始

### 查询优化

```sql
-- 使用 PREWHERE 优化
SELECT 
    user_id,
    event_type,
    event_time
FROM events
WHERE event_time >= now() - INTERVAL 7 DAY
  AND user_id = 123;

-- 避免在 WHERE 中使用函数
SELECT * FROM users
WHERE toYYYYMM(created_at) = '202401';  -- ❌ 慢

SELECT * FROM users
WHERE created_at >= '2024-01-01'  -- ✅ 快
  AND created_at < '2024-02-01';
```

### 主键优化

```sql
-- 使用合适的主键
CREATE TABLE events (
    event_id UInt64,
    user_id UInt64,
    event_time DateTime,
    event_data String
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (user_id, event_time);  -- ✅ 合理
```

### 跳数索引

```sql
-- 创建跳数索引
CREATE TABLE events (
    event_id UInt64,
    user_id UInt64,
    event_type String,
    event_time DateTime,
    event_data String
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (user_id, event_time)
SETTINGS index_granularity = 8192;

-- 添加跳数索引
ALTER TABLE events
ADD INDEX idx_event_type event_type
TYPE set(0)
GRANULARITY 4;
```

### 批量插入

```sql
-- 使用批量插入
INSERT INTO events
VALUES
(1, 100, 'click', now(), '{"page":"/home"}'),
(2, 100, 'view', now(), '{"product":"laptop"}'),
(3, 101, 'click', now(), '{"page":"/about"}');

-- 使用异步插入
INSERT INTO events
SETTINGS async_insert = 1, wait_for_async_insert = 0
VALUES (4, 102, 'click', now(), '{"page":"/products"}');
```

## 📊 性能优化层次

| 层次 | 优化内容 | 性能提升 |
|------|---------|---------|
| **硬件层** | CPU、内存、磁盘、网络 | 2-5x |
| **配置层** | 系统配置、表配置 | 1.5-3x |
| **索引层** | 主键、跳数索引、分区 | 2-10x |
| **查询层** | 查询优化、PREWHERE | 3-20x |
| **数据层** | 数据类型、列存储 | 1.5-5x |
| **缓存层** | 查询缓存、页缓存 | 2-10x |

## 🎯 常见性能问题

### 问题 1: 查询慢

**原因**：
- 没有使用主键
- 在 WHERE 中使用函数
- 没有使用分区裁剪
- 扫描了过多数据

**解决方案**：
```sql
-- 1. 使用主键
SELECT * FROM users WHERE user_id = 123;

-- 2. 避免在 WHERE 中使用函数
-- ❌ 慢
SELECT * FROM users WHERE toYYYYMM(created_at) = '202401';

-- ✅ 快
SELECT * FROM users 
WHERE created_at >= '2024-01-01' 
  AND created_at < '2024-02-01';

-- 3. 使用分区裁剪
SELECT * FROM events
WHERE event_time >= now() - INTERVAL 7 DAY;
```

### 问题 2: 插入慢

**原因**：
- 单条插入
- 没有使用批量插入
- 没有使用异步插入

**解决方案**：
```sql
-- 1. 使用批量插入
INSERT INTO users
VALUES
(1, 'user1', 'user1@example.com', '2024-01-01'),
(2, 'user2', 'user2@example.com', '2024-01-01'),
(3, 'user3', 'user3@example.com', '2024-01-01');

-- 2. 使用异步插入
INSERT INTO users
SETTINGS async_insert = 1, 
        wait_for_async_insert = 0,
        async_insert_max_data_size = 100000000
VALUES (4, 'user4', 'user4@example.com', '2024-01-01');
```

### 问题 3: Mutation 慢

**原因**：
- 大规模 Mutation
- 没有使用分区更新
- 高频 Mutation

**解决方案**：
```sql
-- 1. 使用分区更新
CREATE TABLE users_temp AS users;
INSERT INTO users_temp SELECT * FROM users WHERE ...;
ALTER TABLE users REPLACE PARTITION '202401' FROM users_temp;

-- 2. 使用轻量级更新（ClickHouse 23.8+）
ALTER TABLE users
UPDATE status = 'active'
WHERE user_id IN (1, 2, 3)
SETTINGS lightweight_update = 1;
```

## 💡 性能优化原则

### 1. 分区原则

- 按时间分区（推荐）
- 避免过多分区（< 1000）
- 分区大小适中（1-10 GB）

### 2. 排序键原则

- 包含常用查询条件
- 保持选择性
- 避免过多列（< 5 列）
- 将高选择性列放在前面

### 3. 索引原则

- 只为高频查询创建跳数索引
- 避免过多索引（< 10 个）
- 选择合适的索引类型
- 定期分析索引效果

### 4. 查询优化原则

- 使用 PREWHERE 过滤数据
- 避免在 WHERE 中使用函数
- 使用分区裁剪
- 限制返回的数据量

### 5. 数据类型原则

- 使用合适的数据类型
- 避免使用 Nullable
- 使用定长类型
- 避免 String 存储数字

## 📖 性能检查清单

### 表设计检查

- [ ] 分区键是否合理？
  - [ ] 按时间分区
  - [ ] 分区数量适中
  - [ ] 分区大小适中

- [ ] 排序键是否合理？
  - [ ] 包含常用查询条件
  - [ ] 保持高选择性
  - [ ] 列数适中

- [ ] 数据类型是否合适？
  - [ ] 避免使用 Nullable
  - [ ] 使用最小类型
  - [ ] 避免存储数字为 String

### 索引检查

- [ ] 主键是否被使用？
  - [ ] 查询使用主键
  - [ ] 避免在主键上使用函数

- [ ] 跳数索引是否有效？
  - [ ] 索引被使用
  - [ ] 索引过滤效果好
  - [ ] 索引数量适中

### 查询检查

- [ ] 是否使用分区裁剪？
  - [ ] 查询条件包含分区键
  - [ ] 避免在分区键上使用函数

- [ ] 是否使用 PREWHERE？
  - [ ] 大表查询使用 PREWHERE
  - [ ] PREWHERE 条件有选择性

- [ ] 是否避免函数计算？
  - [ ] WHERE 中避免函数
  - [ ] 预计算常用表达式

### 插入检查

- [ ] 是否使用批量插入？
  - [ ] 每批插入 > 1000 行
  - [ ] 使用 INSERT VALUES 或 SELECT

- [ ] 是否使用异步插入？
  - [ ] 高频插入使用异步
  - [ ] 配置合理的异步参数

## 🚀 性能优化步骤

### 步骤 1: 分析查询

```sql
-- 查看查询执行计划
EXPLAIN PLAN 
SELECT * FROM users 
WHERE user_id = 123;

-- 查看查询性能
EXPLAIN PIPELINE 
SELECT * FROM users 
WHERE user_id = 123;

-- 查看查询统计
EXPLAIN ESTIMATE
SELECT * FROM users 
WHERE user_id = 123;
```

### 步骤 2: 查看慢查询

```sql
-- 查看慢查询日志
SELECT 
    query,
    query_duration_ms,
    read_rows,
    read_bytes,
    written_rows,
    memory_usage
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query_duration_ms > 1000
ORDER BY event_time DESC
LIMIT 10;
```

### 步骤 3: 分析系统指标

```sql
-- 查看系统负载
SELECT 
    metric,
    value,
    description
FROM system.metrics
WHERE metric LIKE '%CPU%'
   OR metric LIKE '%Memory%'
   OR metric LIKE '%Disk%';
```

### 步骤 4: 优化表结构

```sql
-- 查看表统计信息
SELECT 
    database,
    table,
    total_rows,
    total_bytes,
    formatReadableSize(total_bytes) as size,
    partition_key,
    sorting_key,
    primary_key
FROM system.tables
WHERE database = 'my_database';
```

### 步骤 5: 优化查询

```sql
-- 使用优化后的查询
SELECT 
    user_id,
    username,
    email
FROM users
WHERE user_id IN (1, 2, 3, 4, 5)
  AND created_at >= '2024-01-01'
  AND created_at < '2024-02-01';
```

## 📚 相关文档

- [01-base/](../01-base/) - 基础使用
- [09-data-deletion/](../09-data-deletion/) - 数据删除专题
- [10-date-update/](../10-date-update/) - 日期时间操作专题
- [11-data-update/](../11-data-update/) - 数据更新专题

## 🔗 更多资源

- [ClickHouse 性能优化文档](https://clickhouse.com/docs/en/operations/optimization)
- [ClickHouse 查询优化指南](https://clickhouse.com/docs/en/sql-reference/ansi)
- [ClickHouse 硬件推荐](https://clickhouse.com/docs/en/operations/hardware)
