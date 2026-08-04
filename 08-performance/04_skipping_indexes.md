# 数据跳数索引

数据跳数索引（Skipping Index）是 ClickHouse 中用于加速查询的二级索引，可以显著提升非主键列的查询性能。

## 基本概念

### 跳数索引特性

- **二级索引**：基于主键的二级索引
- **粒度控制**：每隔 N 个 mark 存储索引数据
- **跳过数据块**：查询时跳过不满足条件的数据块
- **索引类型**：支持多种索引类型（minmax、set、bloom_filter 等）

### 索引粒度

```sql
-- 创建表时设置索引粒度
CREATE TABLE events (
    event_id UInt64,
    user_id UInt64,
    event_type String,
    event_time DateTime,
    event_data String
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (user_id, event_time)
SETTINGS index_granularity = 8192;  -- 每个 mark 8192 行

-- 跳数索引粒度 = index_granularity / 2
-- 默认 = 4096 行
```

## 索引类型

### 1. minmax 索引

存储每个数据块的最小值和最大值。

```sql
-- 创建 minmax 索引
CREATE TABLE events (
    event_id UInt64,
    user_id UInt64,
    event_time DateTime,
    status UInt8
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (user_id, event_time);

-- 添加 minmax 索引
ALTER TABLE events
ADD INDEX idx_status status
TYPE minmax
GRANULARITY 4;
```

**适用场景**：数值类型、日期时间类型的范围查询

### 2. set 索引

存储每个数据块的唯一值集合。

```sql
-- 创建 set 索引
CREATE TABLE events (
    event_id UInt64,
    user_id UInt64,
    event_type String,
    event_time DateTime
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (user_id, event_time);

-- 添加 set 索引
ALTER TABLE events
ADD INDEX idx_event_type event_type
TYPE set(0)
GRANULARITY 4;
```

**适用场景**：低基数（< 10000 个唯一值）的字符串或枚举类型

### 3. bloom_filter 索引

使用布隆过滤器快速判断值是否可能存在。

```sql
-- 创建 bloom_filter 索引
CREATE TABLE events (
    event_id UInt64,
    user_id UInt64,
    user_email String,
    event_time DateTime
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (user_id, event_time);

-- 添加 bloom_filter 索引
ALTER TABLE events
ADD INDEX idx_user_email user_email
TYPE bloom_filter(0.01)
GRANULARITY 1;
```

**适用场景**：高基数字符串的相等性查询

**参数**：bloom_filter(误报率)，默认 0.025（2.5%）

### 4. ngrambf_v1 索引

使用 n-gram 布隆过滤器支持字符串匹配。

```sql
-- 创建 ngrambf_v1 索引
CREATE TABLE events (
    event_id UInt64,
    user_id UInt64,
    event_data String,
    event_time DateTime
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (user_id, event_time);

-- 添加 ngrambf_v1 索引
ALTER TABLE events
ADD INDEX idx_event_data event_data
TYPE ngrambf_v1(4, 256, 3, 0.01)
GRANULARITY 1;
```

**参数**：
- 4: n-gram 的大小（token 大小）
- 256: 布隆过滤器大小（字节）
- 3: 哈希函数数量
- 0.01: 误报率

**适用场景**：字符串的 LIKE、hasToken 匹配

### 5. tokenbf_v1 索引

使用 token 布隆过滤器支持字符串匹配。

```sql
-- 创建 tokenbf_v1 索引
CREATE TABLE events (
    event_id UInt64,
    user_id UInt64,
    event_data String,
    event_time DateTime
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (user_id, event_time);

-- 添加 tokenbf_v1 索引
ALTER TABLE events
ADD INDEX idx_event_data event_data
TYPE tokenbf_v1(256, 3, 0)
GRANULARITY 1;
```

**参数**：
- 256: 布隆过滤器大小（字节）
- 3: 哈希函数数量
- 0: 种子（随机）

**适用场景**：字符串的 LIKE、hasToken 匹配

## 索引创建和管理

### 创建索引

```sql
-- 创建表时创建索引
CREATE TABLE events (
    event_id UInt64,
    user_id UInt64,
    event_type String,
    event_time DateTime,
    status UInt8
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (user_id, event_time)
SETTINGS index_granularity = 8192;

-- 添加索引
ALTER TABLE events
ADD INDEX idx_event_type event_type
TYPE set(2)
GRANULARITY 4;

ALTER TABLE events
ADD INDEX idx_status status
TYPE minmax
GRANULARITY 4;
```

### 查看索引

```sql
-- 查看表的索引
SELECT 
    database,
    table,
    name,
    type,
    expr,
    granularity,
    data_compressed_bytes,
    data_uncompressed_bytes,
    marks_count
FROM system.data_skipping_indices
WHERE database = 'my_database'
  AND table = 'events';
```

### 删除索引

```sql
-- 删除索引
ALTER TABLE events
DROP INDEX idx_event_type;
```

### 禁用索引

```sql
-- 查询时禁用索引
SELECT * FROM events
SETTINGS force_primary_key = 1,  -- 禁用所有跳数索引
          skip_unused_shards = 1
WHERE event_type = 'click';
```

## 索引优化示例

### 示例 1: 低基数字符串

```sql
CREATE TABLE events (
    event_id UInt64,
    user_id UInt64,
    event_type String,  -- 低基数（< 100 个值）
    event_time DateTime
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (user_id, event_time);

-- ✅ 使用 set 索引
ALTER TABLE events
ADD INDEX idx_event_type event_type
TYPE set(2)
GRANULARITY 4;

-- 查询使用索引
SELECT * FROM events
WHERE event_type = 'click'  -- ✅ 使用 set 索引
  AND event_time >= now() - INTERVAL 7 DAY;
```

**性能提升**: 10-100x

### 示例 2: 高基数字符串

```sql
CREATE TABLE events (
    event_id UInt64,
    user_id UInt64,
    user_email String,  -- 高基数（每个用户唯一）
    event_time DateTime
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (user_id, event_time);

-- ✅ 使用 bloom_filter 索引
ALTER TABLE events
ADD INDEX idx_user_email user_email
TYPE bloom_filter(0.01)
GRANULARITY 1;

-- 查询使用索引
SELECT * FROM events
WHERE user_email = 'user@example.com'  -- ✅ 使用 bloom_filter 索引
  AND event_time >= now() - INTERVAL 7 DAY;
```

**性能提升**: 5-50x

### 示例 3: 字符串匹配

```sql
CREATE TABLE events (
    event_id UInt64,
    user_id UInt64,
    event_data String,
    event_time DateTime
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (user_id, event_time);

-- ✅ 使用 ngrambf_v1 索引
ALTER TABLE events
ADD INDEX idx_event_data event_data
TYPE ngrambf_v1(4, 256, 3, 0.01)
GRANULARITY 1;

-- 查询使用索引
SELECT * FROM events
WHERE event_data LIKE '%laptop%'  -- ✅ 使用 ngrambf_v1 索引
  AND event_time >= now() - INTERVAL 7 DAY;
```

**性能提升**: 5-20x

### 示例 4: 多个索引

```sql
CREATE TABLE events (
    event_id UInt64,
    user_id UInt64,
    event_type String,
    event_category String,
    status UInt8,
    event_time DateTime
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (user_id, event_time);

-- ✅ 创建多个索引
ALTER TABLE events
ADD INDEX idx_event_type event_type
TYPE set(2)
GRANULARITY 4;

ALTER TABLE events
ADD INDEX idx_event_category event_category
TYPE set(2)
GRANULARITY 4;

ALTER TABLE events
ADD INDEX idx_status status
TYPE minmax
GRANULARITY 4;

-- 查询使用多个索引
SELECT * FROM events
WHERE event_type = 'click'  -- ✅ 使用 set 索引
  AND event_category = 'product'  -- ✅ 使用 set 索引
  AND status = 1  -- ✅ 使用 minmax 索引
  AND event_time >= now() - INTERVAL 7 DAY;
```

**性能提升**: 10-200x

## 索引性能分析

### 查看索引使用情况

```sql
-- 查看索引使用统计
SELECT 
    index_name,
    marks,
    rows,
    bytes_on_disk,
    formatReadableSize(bytes_on_disk) as readable_size,
    type
FROM system.data_skipping_indices
WHERE database = 'my_database'
  AND table = 'events';
```

### 分析索引效果

```sql
-- 查看索引过滤效果
SELECT 
    query,
    read_rows,
    read_bytes,
    result_rows,
    result_bytes,
    formatReadableSize(read_bytes) as read_size,
    formatReadableSize(result_bytes) as result_size,
    read_rows / result_rows as filter_ratio
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_time >= now() - INTERVAL 24 HOUR
  AND read_rows > 100000
ORDER BY filter_ratio DESC
LIMIT 10;
```

## 索引最佳实践

### 1. 选择合适的索引类型

```sql
-- 低基数字符串：set
ALTER TABLE events
ADD INDEX idx_event_type event_type
TYPE set(2)
GRANULARITY 4;

-- 高基数字符串：bloom_filter
ALTER TABLE events
ADD INDEX idx_user_email user_email
TYPE bloom_filter(0.01)
GRANULARITY 1;

-- 数值范围：minmax
ALTER TABLE events
ADD INDEX idx_status status
TYPE minmax
GRANULARITY 4;
```

### 2. 控制索引数量

- **推荐**：< 10 个索引
- **避免**：过多索引影响写入性能

```sql
-- ✅ 适量索引
CREATE TABLE events (
    event_id UInt64,
    user_id UInt64,
    event_type String,
    event_time DateTime
) ENGINE = MergeTree()
ORDER BY (user_id, event_time);

-- 只创建高频查询的索引
ALTER TABLE events ADD INDEX idx_event_type event_type TYPE set(2) GRANULARITY 4;
ALTER TABLE events ADD INDEX idx_status status TYPE minmax GRANULARITY 4;
```

### 3. 选择合适的粒度

| 索引类型 | 推荐粒度 | 说明 |
|----------|----------|------|
| minmax | 4-8 | 适用于范围查询 |
| set | 4-8 | 适用于低基数列 |
| bloom_filter | 1-4 | 适用于高基数列 |
| ngrambf_v1 | 1-2 | 适用于字符串匹配 |
| tokenbf_v1 | 1-2 | 适用于字符串匹配 |

```sql
-- ✅ 适中的粒度
ALTER TABLE events
ADD INDEX idx_event_type event_type
TYPE set(2)
GRANULARITY 4;  -- 每 4 个 mark 存储索引
```

### 4. 定期分析索引效果

```sql
-- 分析索引使用情况
SELECT 
    index_name,
    marks,
    type,
    bytes_on_disk
FROM system.data_skipping_indices
WHERE database = 'my_database'
  AND table = 'events'
ORDER BY bytes_on_disk DESC;
```

## 索引检查清单

- [ ] 是否需要索引？
  - [ ] 分析查询模式
  - [ ] 识别高频查询列

- [ ] 索引类型是否合适？
  - [ ] 低基数：set
  - [ ] 高基数：bloom_filter
  - [ ] 范围查询：minmax

- [ ] 索引粒度是否合理？
  - [ ] set/minmax: 4-8
  - [ ] bloom_filter/ngrambf: 1-4

- [ ] 索引数量是否合理？
  - [ ] < 10 个索引
  - [ ] 只创建高频查询的索引

- [ ] 是否定期分析效果？
  - [ ] 查看索引使用情况
  - [ ] 删除无用索引

## 性能提升

| 索引类型 | 适用场景 | 性能提升 |
|---------|---------|---------|
| minmax | 数值范围查询 | 5-50x |
| set | 低基数查询 | 10-100x |
| bloom_filter | 高基数查询 | 5-50x |
| ngrambf_v1 | 字符串匹配 | 5-20x |
| tokenbf_v1 | 字符串匹配 | 5-20x |

## 相关文档

- [01_query_optimization.md](./01_query_optimization.md) - 查询优化基础
- [02_primary_indexes.md](./02_primary_indexes.md) - 主键索引优化
- [03_partitioning.md](./03_partitioning.md) - 分区键优化
- [11_query_profiling.md](./11_query_profiling.md) - 查询分析和 Profiling
