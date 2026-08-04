# 分区键优化

分区是 ClickHouse 中最重要的优化手段之一，合理的分区设计可以显著提升查询性能。

## 基本概念

### 分区特性

- **数据物理隔离**：每个分区是独立的文件
- **查询优化**：支持分区裁剪（Pruning）
- **管理便捷**：可以独立操作每个分区
- **并行处理**：不同分区可以并行处理

### 分区类型

```sql
-- 按日期分区
PARTITION BY toYYYYMM(event_time)

-- 按月份分区
PARTITION BY toMonth(event_time)

-- 按天分区
PARTITION BY toDate(event_time)

-- 按值分区
PARTITION BY user_id % 100

-- 按枚举分区
PARTITION BY status
```

## 分区设计原则

### 原则 1: 按时间分区（推荐）

```sql
-- ✅ 按月分区（推荐）
CREATE TABLE events (
    event_id UInt64,
    user_id UInt64,
    event_time DateTime,
    event_data String
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)  -- ✅ 按月
ORDER BY (user_id, event_time);

-- ❌ 按天分区（分区过多）
CREATE TABLE events (
    event_id UInt64,
    user_id UInt64,
    event_time DateTime,
    event_data String
) ENGINE = MergeTree()
PARTITION BY toDate(event_time)  -- ❌ 按天（分区过多）
ORDER BY (user_id, event_time);
```

### 原则 2: 分区大小适中

| 分区大小 | 数据量 | 分区数 | 适用场景 |
|---------|--------|--------|---------|
| 1-10 GB | 100 万 - 1000 万 | 10-100 | 通用场景（推荐）|
| 10-50 GB | 1000 万 - 5000 万 | 5-50 | 读取密集型 |
| 50-100 GB | 5000 万 - 1 亿 | 1-10 | 写入密集型 |

```sql
-- ✅ 适中的分区大小（1-10 GB）
PARTITION BY toYYYYMM(event_time)  -- 按月，通常 1-10 GB

-- ❌ 过小的分区
PARTITION BY toYYYYMMDD(event_time)  -- 按天，可能 < 100 MB

-- ❌ 过大的分区
PARTITION BY toYYYY(event_time)  -- 按年，可能 > 100 GB
```

### 原则 3: 分区数量适中

| 分区数量 | 性能影响 | 适用场景 |
|---------|---------|---------|
| < 100 | 最佳性能 | 推荐 |
| 100-1000 | 性能下降 10-30% | 可接受 |
| > 1000 | 性能下降 > 50% | 避免 |

```sql
-- ✅ 适中的分区数量
PARTITION BY toYYYYMM(event_time)  -- 12 个月/年

-- ❌ 过多的分区
PARTITION BY toYYYYMMDD(event_time)  -- 365 天/年
```

### 原则 4: 匹配查询模式

```sql
-- 如果查询主要按时间范围
CREATE TABLE events (
    event_id UInt64,
    user_id UInt64,
    event_time DateTime
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)  -- ✅ 匹配查询模式
ORDER BY (user_id, event_time);

-- 如果查询主要按用户
CREATE TABLE user_events (
    event_id UInt64,
    user_id UInt64,
    event_time DateTime
) ENGINE = MergeTree()
PARTITION BY user_id % 100  -- ✅ 匹配查询模式
ORDER BY (event_time);
```

## 分区查询优化

### 使用分区裁剪

```sql
-- ✅ 使用分区裁剪（快速）
SELECT * FROM events
WHERE event_time >= '2024-01-01'
  AND event_time < '2024-02-01';

-- ❌ 不使用分区裁剪（慢速）
SELECT * FROM events
WHERE toYYYYMM(event_time) = '202401';
```

### 指定分区查询

```sql
-- 查询特定分区
SELECT * FROM events
PARTITION '202401'
WHERE user_id = 123;

-- 查询多个分区
SELECT * FROM events
WHERE event_time >= '2024-01-01'
  AND event_time < '2024-03-01';
```

### 虚拟列

```sql
-- 使用虚拟列 `_partition_id`
SELECT 
    _partition_id,
    count() as row_count
FROM events
GROUP BY _partition_id;
```

## 分区管理

### 查看分区信息

```sql
-- 查看表的分区
SELECT 
    partition,
    name,
    sum(rows) as total_rows,
    sum(bytes_on_disk) as total_bytes,
    formatReadableSize(sum(bytes_on_disk)) as readable_size
FROM system.parts
WHERE database = 'my_database'
  AND table = 'events'
  AND active = 1
GROUP BY partition, name
ORDER BY partition;
```

### 删除分区

```sql
-- 删除单个分区
ALTER TABLE events
DROP PARTITION '202401';

-- 删除多个分区
ALTER TABLE events
DROP PARTITION '202301', '202302', '202303';

-- 删除旧分区
ALTER TABLE events
DROP PARTITION '202301', '202302', '202303', '202304', '202305';
```

### 复制分区

```sql
-- 复制分区到另一个表
CREATE TABLE events_new AS events;

ALTER TABLE events_new
REPLACE PARTITION '202401'
FROM events;
```

### 交换分区

```sql
-- 交换分区
ALTER TABLE events_archive
EXCHANGE PARTITION '202401'
WITH events;
```

## 分区优化示例

### 示例 1: 按月分区（推荐）

```sql
CREATE TABLE events (
    event_id UInt64,
    user_id UInt64,
    event_type String,
    event_time DateTime,
    event_data String
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)  -- ✅ 按月分区
ORDER BY (user_id, event_time);

-- 查询优化
SELECT * FROM events
WHERE event_time >= '2024-01-01'
  AND event_time < '2024-02-01';  -- ✅ 使用分区裁剪
```

### 示例 2: 按用户哈希分区

```sql
CREATE TABLE user_events (
    event_id UInt64,
    user_id UInt64,
    event_time DateTime,
    event_data String
) ENGINE = MergeTree()
PARTITION BY intHash32(user_id) % 100  -- ✅ 按用户哈希
ORDER BY (user_id, event_time);

-- 查询特定用户
SELECT * FROM user_events
WHERE user_id = 123;  -- ✅ 只扫描一个分区
```

### 示例 3: 按状态分区

```sql
CREATE TABLE orders (
    order_id UInt64,
    user_id UInt64,
    amount Float64,
    order_date DateTime,
    status String
) ENGINE = MergeTree()
PARTITION BY status  -- ✅ 按状态分区
ORDER BY (order_date, order_id);

-- 查询特定状态
SELECT * FROM orders
WHERE status = 'pending';  -- ✅ 只扫描一个分区
```

### 示例 4: 复合分区

```sql
CREATE TABLE events (
    event_id UInt64,
    user_id UInt64,
    event_type String,
    event_time DateTime,
    event_data String
) ENGINE = MergeTree()
PARTITION BY (toYYYYMM(event_time), user_id % 10)  -- ✅ 时间 + 用户哈希
ORDER BY (user_id, event_time);

-- 查询优化
SELECT * FROM events
WHERE event_time >= '2024-01-01'
  AND event_time < '2024-02-01'
  AND user_id = 123;  -- ✅ 只扫描一个分区
```

## 分区优化技巧

### 技巧 1: 使用 TTL 自动清理分区

```sql
CREATE TABLE events (
    event_id UInt64,
    user_id UInt64,
    event_time DateTime,
    event_data String
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (user_id, event_time)
TTL event_time + INTERVAL 90 DAY;  -- ✅ 90 天后自动删除
```

### 技巧 2: 使用分区策略

```sql
-- 活跃数据：按天分区
CREATE TABLE events_active (
    event_id UInt64,
    user_id UInt64,
    event_time DateTime,
    event_data String
) ENGINE = MergeTree()
PARTITION BY toDate(event_time)  -- 按天
ORDER BY (user_id, event_time);

-- 历史数据：按月分区
CREATE TABLE events_history (
    event_id UInt64,
    user_id UInt64,
    event_time DateTime,
    event_data String
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)  -- 按月
ORDER BY (user_id, event_time);
```

### 技巧 3: 使用分区滚动

```sql
-- 定期归档旧分区
ALTER TABLE events
DROP PARTITION '202301', '202302', '202303';

-- 或移动到归档表
ALTER TABLE events_archive
EXCHANGE PARTITION '202301', '202302', '202303'
WITH events;
```

### 技巧 4: 监控分区大小

```sql
-- 监控分区大小
SELECT 
    partition,
    sum(rows) as total_rows,
    sum(bytes_on_disk) as total_bytes,
    formatReadableSize(sum(bytes_on_disk)) as readable_size
FROM system.parts
WHERE database = 'my_database'
  AND table = 'events'
  AND active = 1
GROUP BY partition
HAVING total_bytes > 10737418240  -- > 10 GB
ORDER BY total_bytes DESC;
```

### 技巧 5: 合并小分区

```sql
-- 手动合并小分区
OPTIMIZE TABLE events
PARTITION '202401'
FINAL;
```

## 分区检查清单

- [ ] 分区键是否合理？
  - [ ] 按时间分区（推荐）
  - [ ] 匹配查询模式
  - [ ] 分区大小适中

- [ ] 分区数量是否合理？
  - [ ] < 100 个分区（推荐）
  - [ ] 不超过 1000 个分区

- [ ] 是否使用分区裁剪？
  - [ ] 查询条件包含分区键
  - [ ] 避免在分区键上使用函数

- [ ] 是否定期清理分区？
  - [ ] 使用 TTL 自动清理
  - [ ] 定期删除旧分区

- [ ] 是否监控分区大小？
  - [ ] 监控过大的分区
  - [ ] 合并小分区

## 性能提升

| 优化方法 | 性能提升 |
|---------|---------|
| 合理分区 | 5-50x |
| 分区裁剪 | 10-100x |
| TTL 自动清理 | 2-5x |
| 分区滚动 | 2-10x |
| 监控优化 | 1.5-3x |

## 相关文档

- [01_query_optimization.md](./01_query_optimization.md) - 查询优化基础
- [02_primary_indexes.md](./02_primary_indexes.md) - 主键索引优化
- [04_skipping_indexes.md](./04_skipping_indexes.md) - 数据跳数索引
- [11_query_profiling.md](./11_query_profiling.md) - 查询分析和 Profiling
