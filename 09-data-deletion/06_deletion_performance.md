# 删除性能优化

本文档介绍如何优化数据删除操作的性能，减少对系统的影响。

## 📊 性能基准

### 删除方法性能对比

```sql
-- 创建测试表
CREATE TABLE performance_test (
    id UInt64,
    event_time DateTime,
    data String
) ENGINE = MergeTree
PARTITION BY toYYYYMM(event_time)
ORDER BY id;

-- 插入 1 亿行测试数据
INSERT INTO performance_test
SELECT 
    number,
    toDateTime('2023-01-01 00:00:00') + toIntervalMinute(number),
    repeat('data', 10)
FROM numbers(100000000);

-- 测试不同删除方法的性能
```

### 基准测试结果

| 方法 | 删除 10% | 删除 30% | 删除 50% | CPU 使用 | I/O 使用 |
|------|----------|----------|----------|---------|---------|
| 分区删除 | <1 秒 | <1 秒 | <1 秒 | ⭐ 低 | ⭐⭐ 中 |
| 轻量级删除 | 10-30 秒 | 30-90 秒 | 60-180 秒 | ⭐⭐ 中 | ⭐⭐ 中 |
| Mutation 删除 | 60-180 秒 | 180-540 秒 | 300-900 秒 | ⭐⭐⭐⭐ 高 | ⭐⭐⭐⭐ 高 |

## 🎯 优化策略

### 策略 1: 使用分区删除

```sql
-- 最快的删除方法

-- 查看分区信息
SELECT
    partition,
    formatReadableSize(sum(bytes_on_disk)) AS size,
    sum(rows) AS rows
FROM system.parts
WHERE table = 'performance_test' AND active = 1
GROUP BY partition
ORDER BY partition;

-- 删除整个分区
ALTER TABLE performance_test
DROP PARTITION '202301';

-- 性能：⭐⭐⭐⭐⭐ 极快
```

### 策略 2: 小批次处理

```sql
-- 将大删除拆分为多个小批次

-- 查看要删除的数据量
SELECT
    count() AS total_rows,
    count() / 10 AS rows_per_batch
FROM performance_test
WHERE event_time < '2023-03-01';

-- 分 10 批次删除
-- 批次 1
ALTER TABLE performance_test
DELETE WHERE 
    event_time >= '2023-01-01' 
    AND event_time < '2023-01-15'
SETTINGS max_threads = 4;

-- 等待完成
-- SELECT is_done FROM system.mutations WHERE ...

-- 批次 2
ALTER TABLE performance_test
DELETE WHERE 
    event_time >= '2023-01-15' 
    AND event_time < '2023-02-01'
SETTINGS max_threads = 4;

-- 性能提升：减少单次操作的 I/O 和 CPU 峰值
```

### 策略 3: 控制并发线程

```sql
-- 限制并发线程数以减少系统负载

-- 使用较少的线程
ALTER TABLE performance_test
DELETE WHERE event_time < '2023-03-01'
SETTINGS max_threads = 2;

-- 使用更多线程（如果系统负载低）
ALTER TABLE performance_test
DELETE WHERE event_time < '2023-03-01'
SETTINGS max_threads = 8;

-- 建议：根据系统负载动态调整
```

### 策略 4: 调整合并策略

```sql
-- 调整合并策略以优化删除后的性能

-- 查看当前合并设置
SELECT
    name,
    value,
    changed
FROM system.settings
WHERE name LIKE '%merge%';

-- 调整合并参数
SET max_bytes_to_merge_at_once = 10737418240;  -- 10GB
SET max_rows_to_merge_at_once = 1000000;         -- 100 万行

-- 删除后触发合并
OPTIMIZE TABLE performance_test FINAL;
```

### 策略 5: 在低峰期执行

```sql
-- 在业务低峰期执行删除操作

-- 查看当前系统负载
SELECT
    metric,
    value,
    description
FROM system.asynchronous_metrics
WHERE metric IN (
    'OSUsers',
    'OSNiceTime',
    'OSIdleTime',
    'OSSystemTime'
);

-- 建议在以下时间执行：
-- - 凌晨 2-6 点（业务低峰）
-- - 周末
-- - 节假日
```

## 📈 性能监控

### 监控删除操作

```sql
-- 实时监控删除操作
SELECT
    query_id,
    user,
    query,
    elapsed,
    read_rows,
    read_bytes,
    memory_usage,
    thread_ids
FROM system.processes
WHERE query ILIKE '%DELETE%'
  OR query ILIKE '%DROP%'
ORDER BY elapsed DESC;
```

### 监控系统资源

```sql
-- 监控删除期间的系统资源使用
SELECT
    'CPU' as metric,
    (sum(OSUserTime) + sum(OSSystemTime)) / sum(OSIdleTime) as value
FROM system.asynchronous_metrics
WHERE metric LIKE 'OS%'

UNION ALL

SELECT
    'Memory (GB)',
    formatReadableSize(MemoryTracking) as value
FROM system.metrics

UNION ALL

SELECT
    'Disk Read (MB/s)',
    formatReadableSize(ReadBufferFromFileDescriptorBytes / 1e6)
FROM system.metrics;
```

### 监控 Mutation 进度

```sql
-- 监控 Mutation 执行进度
SELECT
    mutation_id,
    command,
    is_done,
    parts_to_do,
    parts_done,
    (parts_done * 100.0 / NULLIF(parts_to_do, 0)) as progress_percent,
    create_time,
    elapsed_seconds
FROM system.mutations
WHERE database = 'your_database'
ORDER BY create_time DESC;
```

## 🎯 优化配置

### 全局配置优化

```xml
<!-- config.xml -->

<!-- 合并优化 -->
<merge_tree>
    <!-- 增加合并的最小块大小 -->
    <min_bytes_for_compact_part>1048576</min_bytes_for_compact_part>
    
    <!-- 控制并发合并数 -->
    <max_number_of_merges_with_ttl_in_pool>2</max_number_of_merges_with_ttl_in_pool>
    
    <!-- 增加合并间隔 -->
    <async_insert_busy_timeout_ms>1000</async_insert_busy_timeout_ms>
</merge_tree>

<!-- 限制资源使用 -->
<max_threads>8</max_threads>
<max_memory_usage>10000000000</max_memory_usage>  <!-- 10GB -->
```

### 表级别配置

```sql
-- 创建表时设置优化参数
CREATE TABLE optimized_table (
    id UInt64,
    event_time DateTime,
    data String
) ENGINE = MergeTree
PARTITION BY toYYYYMM(event_time)
ORDER BY id
SETTINGS
    -- 合并优化
    max_bytes_to_merge_at_once = 10737418240,      -- 10GB
    max_rows_to_merge_at_once = 1000000,          -- 100 万行
    min_bytes_for_compact_part = 1048576,         -- 1MB
    -- 资源限制
    max_threads = 4,
    max_memory_usage = 2000000000;               -- 2GB
```

### 查询级别设置

```sql
-- 在查询中设置优化参数
ALTER TABLE performance_test
DELETE WHERE event_time < '2023-03-01'
SETTINGS
    max_threads = 4,
    max_memory_usage = 2000000000,
    max_insert_threads = 2;
```

## 🎯 实战优化

### 优化 1: 批量删除脚本

```bash
#!/bin/bash
# optimized_batch_delete.sh

CLICKHOUSE_HOST="localhost"
CLICKHOUSE_PORT="9000"
DATABASE="your_database"
TABLE="your_table"
BATCH_SIZE="10000000"  -- 1000 万行/批次

# 计算总批次
TOTAL_ROWS=$(clickhouse-client --host=$CLICKHOUSE_HOST --port=$CLICKHOUSE_PORT --query="
    SELECT count() FROM $DATABASE.$TABLE WHERE event_time < '2023-03-01'
")

BATCH_COUNT=$((TOTAL_ROWS / BATCH_SIZE + 1))

echo "Total rows: $TOTAL_ROWS, Batch size: $BATCH_SIZE, Batches: $BATCH_COUNT"

# 分批删除
for ((i=0; i<$BATCH_COUNT; i++)); do
    OFFSET=$((i * BATCH_SIZE))
    echo "Processing batch $((i+1))/$BATCH_COUNT (offset: $OFFSET)"
    
    clickhouse-client --host=$CLICKHOUSE_HOST --port=$CLICKHOUSE_PORT --query="
        ALTER TABLE $DATABASE.$TABLE 
        DELETE WHERE 
            event_time < '2023-03-01'
            AND row_number_in_all_blocks() > $OFFSET
            AND row_number_in_all_blocks() <= $((OFFSET + BATCH_SIZE))
        SETTINGS max_threads = 4, max_memory_usage = 2000000000
    "
    
    # 等待完成
    while [ $(clickhouse-client --host=$CLICKHOUSE_HOST --port=$CLICKHOUSE_PORT --query="
        SELECT count() FROM system.mutations 
        WHERE database = '$DATABASE' 
          AND table = '$TABLE' 
          AND is_done = 0
    ") -gt 0 ]; do
        echo "Waiting for batch to complete..."
        sleep 10
    done
done

echo "All batches completed!"
```

### 优化 2: 分区删除 + Mutation 组合

```sql
-- 1. 先删除大部分数据（使用分区删除）
ALTER TABLE events
DROP PARTITION '2022-12';

-- 2. 再删除少量数据（使用 Mutation）
ALTER TABLE events
DELETE WHERE 
    event_time >= '2023-01-01'
    AND event_time < '2023-01-15'
    AND user_id = 'deleted_user'
SETTINGS max_threads = 2;

-- 性能：分区删除 + 少量 Mutation = 最优性能
```

### 优化 3: 轻量级删除 + 定期 OPTIMIZE

```sql
-- 1. 使用轻量级删除标记数据
ALTER TABLE events
DELETE WHERE event_time < '2023-01-01'
SETTINGS lightweight_delete = 1;

-- 2. 定期触发合并清理已标记的数据
-- 可以通过 cron 每天执行
OPTIMIZE TABLE events PARTITION '2022-12' FINAL
SETTINGS max_threads = 4;

-- 性能：轻量级删除（快速）+ 定期 OPTIMIZE（后台清理）
```

### 优化 4: 使用物化视图优化删除

```sql
-- 1. 创建物化视图捕获删除操作
CREATE MATERIALIZED VIEW delete_operations_log
ENGINE = MergeTree()
ORDER BY timestamp
AS
SELECT
    now() AS timestamp,
    database,
    table,
    command
FROM system.mutations
WHERE command ILIKE '%DELETE%';

-- 2. 监控删除操作
SELECT
    toStartOfHour(timestamp) AS hour,
    count() AS delete_operations,
    avg(elapsed_seconds) AS avg_duration
FROM delete_operations_log
WHERE timestamp >= now() - INTERVAL 24 HOUR
GROUP BY hour
ORDER BY hour;

-- 3. 根据监控数据优化删除策略
```

## 📊 性能调优检查清单

### 删除前检查

- [ ] 评估删除数据量占总表的比例
- [ ] 检查当前系统负载
- [ ] 选择合适的删除方法
- [ ] 备份要删除的数据（如需要）
- [ ] 设置合理的线程数

### 删除中监控

- [ ] 监控 CPU 使用率
- [ ] 监控 I/O 使用率
- [ ] 监控内存使用
- [ ] 监控删除进度
- [ ] 检查是否有错误

### 删除后验证

- [ ] 验证数据已删除
- [ ] 检查表的健康状态
- [ ] 触发合并优化表
- [ ] 清理非活动数据块
- [ ] 更新统计信息

## 💡 性能优化技巧

### 技巧 1: 使用轻量级删除

```sql
-- ClickHouse 23.8+ 使用轻量级删除
ALTER TABLE events
DELETE WHERE event_time < '2023-01-01'
SETTINGS lightweight_delete = 1;

-- 性能提升：3-5 倍
```

### 技巧 2: 限制并发

```sql
-- 限制并发线程数
ALTER TABLE events
DELETE WHERE event_time < '2023-01-01'
SETTINGS max_threads = 2;

-- 性能影响：减少 CPU 和 I/O 峰值
```

### 技巧 3: 使用索引

```sql
-- 确保删除条件使用索引

-- 查看表的排序键
SELECT 
    name AS table,
    sorting_key
FROM system.tables
WHERE name = 'events';

-- 优化：使删除条件与排序键匹配
ALTER TABLE events
DELETE WHERE 
    event_time < '2023-01-01'  -- event_time 是排序键
    AND user_id = 'user123';

-- 性能提升：减少扫描的数据量
```

### 技巧 4: 避免全表扫描

```sql
-- ❌ 避免：全表扫描
ALTER TABLE events
DELETE WHERE data LIKE '%test%';

-- ✅ 推荐：使用分区裁剪
ALTER TABLE events
DELETE WHERE 
    partition = '202301'  -- 只扫描特定分区
    AND data LIKE '%test%';

-- 性能提升：只扫描需要的分区
```

### 技巧 5: 使用 TTL 自动清理

```sql
-- 设置 TTL 自动清理
ALTER TABLE events
MODIFY TTL event_time + INTERVAL 90 DAY;

-- 性能优势：自动化，无需手动干预
```

## ⚠️ 性能陷阱

### 陷阱 1: 大批量删除

```sql
-- ❌ 陷阱：一次性删除大量数据
ALTER TABLE events
DELETE WHERE event_time < '2023-01-01';  -- 删除 50% 的数据

-- 影响：系统负载高，查询性能下降

-- ✅ 解决：分批次删除
-- （参考上面的批次删除脚本）
```

### 陷阱 2: 高峰期删除

```sql
-- ❌ 陷阱：在业务高峰期执行删除
-- 工作日白天执行大删除

-- 影响：影响业务查询

-- ✅ 解决：在低峰期执行
-- 凌晨 2-6 点执行
```

### 陷阱 3: 不限制线程

```sql
-- ❌ 陷阱：不限制线程数
ALTER TABLE events
DELETE WHERE event_time < '2023-01-01';
-- 使用所有可用线程（可能 16+）

-- 影响：CPU 使用率 100%

-- ✅ 解决：限制线程数
ALTER TABLE events
DELETE WHERE event_time < '2023-01-01'
SETTINGS max_threads = 4;
```

### 陷阱 4: 不监控进度

```sql
-- ❌ 陷阱：执行后不监控
ALTER TABLE events
DELETE WHERE event_time < '2023-01-01';
-- 不知道何时完成，无法评估影响

-- ✅ 解决：实时监控
-- （参考上面的监控查询）
```

## 📝 相关文档

- [01_partition_deletion.md](./01_partition_deletion.md) - 分区删除
- [03_mutation_deletion.md](./03_mutation_deletion.md) - Mutation 删除
- [05_deletion_strategies.md](./05_deletion_strategies.md) - 删除策略选择
- [07_deletion_monitoring.md](./07_deletion_monitoring.md) - 删除监控
