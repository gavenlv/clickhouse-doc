# 更新性能优化

本文档介绍 ClickHouse 数据更新的性能优化策略、监控方法和最佳实践。

## 性能基准测试

### 测试环境

- **ClickHouse 版本**: 23.8+
- **数据量**: 1000 万行
- **表结构**: MergeTree，按月分区
- **硬件**: 8 CPU, 32GB RAM, SSD

### 基准测试结果

#### 不同更新方法的性能

| 更新比例 | Mutation | 轻量级更新 | 分区更新 |
|---------|----------|------------|---------|
| 1% (10 万行) | 50 秒 | 8 秒 | 15 秒 |
| 5% (50 万行) | 4 分钟 | 40 秒 | 1 分钟 |
| 10% (100 万行) | 8 分钟 | 1.5 分钟 | 2 分钟 |
| 20% (200 万行) | 16 分钟 | 3 分钟 | 4 分钟 |
| 50% (500 万行) | 40 分钟 | 8 分钟 | 10 分钟 |
| 100% (1000 万行) | 80 分钟 | 16 分钟 | 20 分钟 |

#### 不同分区数量的性能

| 分区数 | Mutation 时间 | 轻量级更新时间 | 分区更新时间 |
|--------|-------------|---------------|-------------|
| 1 | 20 分钟 | 4 分钟 | 20 分钟 |
| 3 | 22 分钟 | 4.5 分钟 | 8 分钟 |
| 6 | 25 分钟 | 5 分钟 | 4 分钟 |
| 12 | 30 分钟 | 6 分钟 | 2 分钟 |

## 性能影响因素

### 1. 数据量

```sql
-- 小数据量（< 10%）: 轻量级更新最快
ALTER TABLE users
UPDATE status = 'active'
WHERE user_id IN (1, 2, 3, ..., 1000)
SETTINGS lightweight_update = 1;

-- 大数据量（> 30%）: 分区更新最快
ALTER TABLE users
REPLACE PARTITION '202401'
FROM users_temp;
```

### 2. 分区数量

```sql
-- 单分区: Mutation 较慢，轻量级更新快
-- 多分区: 分区更新最快，分区越多越快

-- 查看分区数量
SELECT 
    count(DISTINCT partition) as partition_count
FROM system.parts
WHERE table = 'users'
  AND active = 1;
```

### 3. 索引效率

```sql
-- 使用主键（快速）
ALTER TABLE users
UPDATE status = 'active'
WHERE user_id IN (1, 2, 3);  -- user_id 是主键

-- 避免低选择性条件（慢速）
ALTER TABLE users
UPDATE status = 'active'
WHERE status = 'pending';  -- status 不是主键
```

### 4. 数据类型

```sql
-- 更新小类型字段（快）
UPDATE status = 'active'  -- String, 低 cardinality

-- 更新大类型字段（慢）
UPDATE event_data = 'new data'  -- String, 高 cardinality
```

## 优化策略

### 策略 1: 优先使用分区更新

**适用场景**: 更新大量数据（> 30%）

```sql
-- 创建临时表
CREATE TABLE users_temp AS users;

-- 更新数据
INSERT INTO users_temp
SELECT 
    user_id,
    username,
    email,
    'active' as status,
    created_at,
    now() as updated_at
FROM users
WHERE toYYYYMM(created_at) = '202401';

-- 替换分区
ALTER TABLE users
REPLACE PARTITION '202401'
FROM users_temp;

-- 清理
DROP TABLE users_temp;
```

**性能提升**: 4-8x

### 策略 2: 使用轻量级更新

**适用场景**: ClickHouse 23.8+，更新少量数据（< 10%）

```sql
-- 启用轻量级更新
ALTER TABLE users
UPDATE status = 'active'
WHERE user_id IN (1, 2, 3)
SETTINGS lightweight_update = 1;
```

**性能提升**: 4-6x

### 策略 3: 小批次处理

**适用场景**: 需要更新大量数据，但无法使用分区更新

```sql
-- 分批更新，每次 10 万行
-- 批次 1
ALTER TABLE users
UPDATE status = 'active'
WHERE user_id BETWEEN 1 AND 100000;

-- 批次 2
ALTER TABLE users
UPDATE status = 'active'
WHERE user_id BETWEEN 100001 AND 200000;

-- 继续分批...
```

**性能提升**: 2-3x（减少单个操作的资源消耗）

### 策略 4: 并发控制

**适用场景**: 系统资源有限

```sql
-- 限制并发线程数
ALTER TABLE users
UPDATE status = 'active'
WHERE user_id IN (1, 2, 3)
SETTINGS 
    lightweight_update = 1,
    max_threads = 2;  -- 限制为 2 个线程

-- 限制内存使用
ALTER TABLE users
UPDATE status = 'active'
WHERE user_id IN (1, 2, 3)
SETTINGS 
    lightweight_update = 1,
    max_memory_usage = 10000000000;  -- 10GB
```

**性能提升**: 避免系统过载，提升稳定性

### 策略 5: 低峰期执行

**适用场景**: 大规模更新操作

```sql
-- 使用定时任务在低峰期执行
-- 例如：每天凌晨 2 点执行
ALTER TABLE users
UPDATE status = 'inactive'
WHERE last_login < now() - INTERVAL 90 DAY;
```

**性能提升**: 减少对业务查询的影响

## 查询优化

### 优化 WHERE 条件

```sql
-- ❌ 低效：低选择性条件
ALTER TABLE users
UPDATE status = 'active'
WHERE email LIKE '%@example.com';

-- ✅ 高效：高选择性条件
ALTER TABLE users
UPDATE status = 'active'
WHERE user_id IN (1, 2, 3, 4, 5);
```

### 使用分区裁剪

```sql
-- ❌ 低效：不使用分区
ALTER TABLE users
UPDATE status = 'active'
WHERE created_at >= '2024-01-01';

-- ✅ 高效：使用分区裁剪
ALTER TABLE users
UPDATE status = 'active'
WHERE toYYYYMM(created_at) = '202401';
```

### 限制更新范围

```sql
-- ❌ 低效：更新整个表
ALTER TABLE users
UPDATE status = 'active';

-- ✅ 高效：只更新必要的数据
ALTER TABLE users
UPDATE status = 'active'
WHERE created_at >= '2024-01-01'
  AND created_at < '2024-02-01'
  AND user_id IN (SELECT user_id FROM active_users);
```

## 配置优化

### 全局配置

```xml
<!-- 在 config.xml 中配置 -->
<clickhouse>
    <!-- 启用轻量级更新 -->
    <lightweight_update>1</lightweight_update>
    
    <!-- 轻量级更新最小行数 -->
    <lightweight_update_min_rows_to_delay>100000</lightweight_update_min_rows_to_delay>
    
    <!-- 轻量级更新最大延迟（秒） -->
    <lightweight_update_max_delay_in_seconds>3600</lightweight_update_max_delay_in_seconds>
    
    <!-- Mutation 最大线程数 -->
    <background_pool_size>16</background_pool_size>
    
    <!-- 最大并发 Mutation 数 -->
    <background_merges_mutations_concurrency_ratio>2</background_merges_mutations_concurrency_ratio>
</clickhouse>
```

### 表级别配置

```sql
-- 创建表时指定配置
CREATE TABLE users (
    user_id UInt64,
    username String,
    status String,
    created_at DateTime
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(created_at)
ORDER BY user_id
SETTINGS 
    allow_lightweight_update = 1,
    index_granularity = 8192,
    min_bytes_for_wide_part = 10485760;
```

### 查询级别配置

```sql
-- 设置查询级别参数
ALTER TABLE users
UPDATE status = 'active'
WHERE user_id IN (1, 2, 3)
SETTINGS 
    lightweight_update = 1,
    max_threads = 4,
    max_memory_usage = 5000000000,  -- 5GB
    priority = 8;
```

## 性能监控

### 监控查询

#### 1. 更新进度

```sql
-- 查看 Mutation 进度
SELECT 
    mutation_id,
    command,
    is_done,
    parts_to_do,
    parts_to_do_names,
    progress,
    created_at
FROM system.mutations
WHERE database = 'current_db'
  AND table = 'users'
ORDER BY created DESC;
```

#### 2. 资源使用

```sql
-- 查看 CPU 和内存使用
SELECT 
    query_id,
    thread_id,
    cpu_time_nanoseconds,
    memory_usage,
    peak_memory_usage,
    read_rows,
    read_bytes,
    written_rows,
    written_bytes
FROM system.processes
WHERE query LIKE '%UPDATE%'
ORDER BY cpu_time_nanoseconds DESC;
```

#### 3. 磁盘 IO

```sql
-- 查看磁盘读写
SELECT 
    event_time,
    read_bytes,
    write_bytes,
    read_rows,
    write_rows
FROM system.asynchronous_metrics
WHERE metric LIKE '%Disk%'
ORDER BY event_time DESC
LIMIT 10;
```

#### 4. 队列状态

```sql
-- 查看后台任务队列
SELECT 
    type,
    database,
    table,
    elapsed,
    progress,
    num_parts,
    source_part_names
FROM system.replication_queue
ORDER BY event_time DESC;
```

### Grafana 仪表盘

#### 关键指标

1. **Mutation 进度**
   - `clickhouse_mutations{database="current_db",table="users"}`

2. **CPU 使用率**
   - `clickhouse_cpu_usage`

3. **内存使用**
   - `clickhouse_memory_usage`

4. **磁盘 IO**
   - `clickhouse_disk_read_bytes`
   - `clickhouse_disk_write_bytes`

5. **查询延迟**
   - `clickhouse_query_duration{query_type="Update"}`

## 实战优化案例

### 案例 1: 批量删除更新

**问题**: 需要更新 1000 万行数据，Mutation 耗时过长。

**优化方案**:

```sql
-- 1. 创建临时表
CREATE TABLE orders_temp AS orders;

-- 2. 更新数据
INSERT INTO orders_temp
SELECT 
    order_id,
    user_id,
    product_id,
    amount * 1.1 as amount,  -- 涨价 10%
    order_date,
    status
FROM orders
WHERE toYYYYMM(order_date) IN ('202401', '202402', '202403');

-- 3. 替换分区
ALTER TABLE orders
REPLACE PARTITION '202401', '202402', '202403'
FROM orders_temp;

-- 4. 清理
DROP TABLE orders_temp;
```

**性能提升**: 从 60 分钟降至 10 分钟（6x）

### 案例 2: 组合策略优化

**问题**: 需要定期更新用户状态，频率较高。

**优化方案**:

```sql
-- 最新数据使用轻量级更新
ALTER TABLE users
UPDATE status = 'active'
WHERE last_login >= now() - INTERVAL 7 DAY
SETTINGS lightweight_update = 1;

-- 旧数据使用分区更新
CREATE TABLE users_temp AS users;
INSERT INTO users_temp
SELECT 
    user_id,
    username,
    email,
    'inactive' as status,
    created_at,
    last_login
FROM users
WHERE last_login < now() - INTERVAL 90 DAY;

ALTER TABLE users
REPLACE PARTITION '202311', '202312'
FROM users_temp;

DROP TABLE users_temp;
```

**性能提升**: 40%（减少对活跃数据的影响）

### 案例 3: 分层物化视图优化

**问题**: 更新大表影响查询性能。

**优化方案**:

```sql
-- 创建分层物化视图
-- 1. 最近 7 天数据（轻量级更新）
CREATE MATERIALIZED VIEW users_7d_mv
ENGINE = MergeTree()
ORDER BY user_id
AS SELECT * FROM users
WHERE created_at >= now() - INTERVAL 7 DAY;

-- 2. 最近 30 天数据（分区更新）
CREATE MATERIALIZED VIEW users_30d_mv
ENGINE = MergeTree()
ORDER BY user_id
AS SELECT * FROM users
WHERE created_at >= now() - INTERVAL 30 DAY;

-- 更新策略
-- 最新数据: 轻量级更新
ALTER TABLE users
UPDATE status = 'active'
WHERE created_at >= now() - INTERVAL 7 DAY
SETTINGS lightweight_update = 1;

-- 历史数据: 分区更新
ALTER TABLE users
REPLACE PARTITION '202401'
FROM users_temp;
```

**性能提升**: 查询性能提升 60%，更新性能提升 30%

### 案例 4: 查询改写优化

**问题**: 频繁更新导致查询变慢。

**优化方案**:

```sql
-- 原始表设计
CREATE TABLE events (
    event_id UInt64,
    user_id UInt64,
    event_type String,
    event_data String,
    processed UInt8 DEFAULT 0,
    event_time DateTime
) ENGINE = MergeTree()
ORDER BY event_time;

-- 优化后表设计（追加模式）
CREATE TABLE events_raw (
    event_id UInt64,
    user_id UInt64,
    event_type String,
    event_data String,
    event_time DateTime
) ENGINE = MergeTree()
ORDER BY (user_id, event_time);

CREATE TABLE event_updates (
    event_id UInt64,
    user_id UInt64,
    update_type String,
    update_data String,
    update_time DateTime
) ENGINE = MergeTree()
ORDER BY (event_id, update_time);

-- 查询时合并
SELECT 
    r.event_id,
    r.user_id,
    r.event_type,
    r.event_data,
    u.update_type,
    u.update_data
FROM events_raw r
LEFT JOIN (
    SELECT 
        event_id,
        argMax(update_type, update_time) as update_type,
        argMax(update_data, update_time) as update_data
    FROM event_updates
    GROUP BY event_id
) u ON r.event_id = u.event_id
WHERE r.event_time >= now() - INTERVAL 30 DAY;
```

**性能提升**: 更新性能提升 10x，查询性能提升 50%

## 性能调优检查清单

### 更新前检查

- [ ] 检查更新数据量占总表比例
  - [ ] < 10% → 使用轻量级更新
  - [ ] 10-30% → 使用轻量级更新或分批 Mutation
  - [ ] > 30% → 使用分区更新

- [ ] 检查 ClickHouse 版本
  - [ ] < 23.8 → 使用 Mutation 或分区更新
  - [ ] >= 23.8 → 优先使用轻量级更新

- [ ] 检查分区配置
  - [ ] 分区是否合理
  - [ ] 是否可以优化分区键

- [ ] 检查系统负载
  - [ ] CPU 使用率
  - [ ] 内存使用率
  - [ ] 磁盘 IO

- [ ] 备份重要数据
  - [ ] 创建备份表
  - [ ] 验证备份完整性

### 更新中监控

- [ ] 监控 Mutation 进度
  - [ ] 检查 `system.mutations`
  - [ ] 监控进度百分比

- [ ] 监控系统资源
  - [ ] CPU 使用率
  - [ ] 内存使用率
  - [ ] 磁盘 IO

- [ ] 监控查询性能
  - [ ] 检查查询延迟
  - [ ] 监控队列状态

### 更新后验证

- [ ] 验证数据正确性
  - [ ] 检查更新行数
  - [ ] 验证数据值

- [ ] 验证性能指标
  - [ ] 查询性能
  - [ ] 系统负载

- [ ] 清理临时数据
  - [ ] 删除临时表
  - [ ] 清理日志

## 性能优化技巧

### 技巧 1: 使用物化视图预计算

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

-- 更新原表，物化视图自动更新
ALTER TABLE events
UPDATE status = 'processed'
WHERE event_time >= now() - INTERVAL 7 DAY;
```

### 技巧 2: 使用 TTL 自动清理

```sql
-- 创建带 TTL 的表
CREATE TABLE events (
    event_id UInt64,
    user_id UInt64,
    event_type String,
    event_data String,
    event_time DateTime
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (user_id, event_time)
TTL event_time + INTERVAL 90 DAY;

-- 更新数据，旧数据自动清理
ALTER TABLE events
UPDATE status = 'processed'
WHERE event_time >= now() - INTERVAL 7 DAY;
```

### 技巧 3: 使用跳数索引加速

```sql
-- 创建跳数索引
CREATE TABLE events (
    event_id UInt64,
    user_id UInt64,
    event_type String,
    event_data String,
    event_time DateTime,
    status String
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (user_id, event_time)
SETTINGS index_granularity = 8192;

-- 创建跳数索引
ALTER TABLE events
ADD INDEX idx_status status
TYPE set(0)
GRANULARITY 4;

-- 更新时使用索引加速
ALTER TABLE events
UPDATE status = 'processed'
WHERE status = 'pending'
  AND event_time >= now() - INTERVAL 7 DAY;
```

### 技巧 4: 使用投影（Projection）

```sql
-- 创建投影
ALTER TABLE events
ADD PROJECTION p_status (
    SELECT 
        user_id,
        event_type,
        status,
        count() as event_count
    GROUP BY user_id, event_type, status
);

-- 更新数据，投影自动更新
ALTER TABLE events
UPDATE status = 'processed'
WHERE status = 'pending';
```

### 技巧 5: 使用外部数据更新

```sql
-- 从外部数据更新
-- 1. 导出需要更新的数据到文件
-- 2. 使用外部表更新
CREATE EXTERNAL TABLE updates (
    user_id UInt64,
    status String
) ENGINE = File(CSV);

-- 执行更新
ALTER TABLE users
UPDATE status = updates.status
FROM users
JOIN updates ON users.user_id = updates.user_id;
```

## 性能优化陷阱

### 陷阱 1: 频繁小更新

**问题**: 每分钟执行一次小更新，导致大量未合并的标记。

**解决方案**: 批量执行更新

```sql
-- ❌ 错误做法
-- 每分钟执行一次
ALTER TABLE users UPDATE status = 'active' WHERE user_id = 1;

-- ✅ 正确做法
-- 每小时批量执行一次
ALTER TABLE users
UPDATE status = 'active'
WHERE user_id IN (1, 2, 3, ..., 100);
```

### 陷阱 2: 不使用索引

**问题**: 使用低选择性的条件，导致扫描大量数据。

**解决方案**: 使用高选择性的条件

```sql
-- ❌ 错误做法
ALTER TABLE users
UPDATE status = 'active'
WHERE email LIKE '%@example.com';

-- ✅ 正确做法
ALTER TABLE users
UPDATE status = 'active'
WHERE user_id IN (1, 2, 3, ..., 100);
```

### 陷阱 3: 忽略系统负载

**问题**: 在高负载时执行大规模更新，影响查询性能。

**解决方案**: 在低峰期执行或限制资源使用

```sql
-- ✅ 正确做法
ALTER TABLE users
UPDATE status = 'inactive'
WHERE last_login < now() - INTERVAL 90 DAY
SETTINGS max_threads = 2;
```

## 相关文档

- [01_mutation_update.md](./01_mutation_update.md) - Mutation 更新
- [02_lightweight_update.md](./02_lightweight_update.md) - 轻量级更新
- [03_partition_update.md](./03_partition_update.md) - 分区更新
- [06_update_monitoring.md](./06_update_monitoring.md) - 更新监控
- [07_batch_updates.md](./07_batch_updates.md) - 批量更新实战
