# 删除策略选择

本文档提供数据删除策略的决策指南和最佳实践。

## 📊 策略对比

### 四种删除方法对比

| 方法 | 速度 | 资源占用 | 适用场景 | 立即生效 | 可恢复性 |
|------|------|---------|---------|---------|---------|
| **分区删除** | ⭐⭐⭐⭐⭐ | ⭐ 低 | 按分区删除大量数据 | ✅ 是 | ❌ 否 |
| **TTL 自动删除** | ⭐⭐⭐ | ⭐ 低 | 定期清理旧数据 | ⚠️ 延迟 | ❌ 否 |
| **Mutation 删除** | ⭐⭐ | ⭐⭐⭐ 高 | 删除少量或中等量数据 | ⚠️ 异步 | ❌ 否 |
| **轻量级删除** | ⭐⭐⭐⭐ | ⭐⭐ 低 | ClickHouse 23.8+，少量删除 | ⚠️ 异步 | ❌ 否 |

## 🎯 决策树

### 完整决策树

```
需要删除数据
├─ 1. 能否按分区删除？
│  ├─ 是 → 使用分区删除（最快）
│  └─ 否 → 继续
├─ 2. 是否需要定期自动删除？
│  ├─ 是 → 使用 TTL 自动删除
│  └─ 否 → 继续
├─ 3. 数据量占总表比例？
│  ├─ < 10%
│  │  ├─ ClickHouse 23.8+? → 使用轻量级删除
│  │  └─ 否 → 使用 Mutation 删除
│  ├─ 10-30%
│  │  └─ 使用 Mutation 删除
│  └─ > 30%
│     ├─ 能重新分区？ → 重新分区后使用分区删除
│     └─ 不能 → 使用 Mutation 删除（小批次）
├─ 4. 是否需要立即释放空间？
│  ├─ 是
│  │  ├─ 能分区删除？ → 使用分区删除
│  │  └─ 不能 → 使用 Mutation + OPTIMIZE
│  └─ 否 → 使用轻量级删除或 TTL
└─ 5. 系统负载如何？
   ├─ 低 → 使用 Mutation 删除
   └─ 高 → 使用轻量级删除
```

## 🎯 场景指南

### 场景 1: 日志数据清理

**需求**: 定期清理超过 30 天的日志数据

**推荐策略**: TTL 自动删除

```sql
-- 创建表时设置 TTL
CREATE TABLE application_logs (
    timestamp DateTime,
    level String,
    service String,
    message String
) ENGINE = MergeTree
PARTITION BY toYYYYMM(timestamp)
ORDER BY (service, timestamp)
TTL timestamp + INTERVAL 30 DAY;

-- 优点：自动化，无需手动操作
-- 缺点：删除有延迟
```

**备选策略**: 分区删除（如果需要更精确的控制）

```sql
-- 每月执行一次
ALTER TABLE application_logs
DROP PARTITION '202301';

-- 优点：立即生效，完全控制
-- 缺点：需要手动执行
```

### 场景 2: GDPR 合规删除

**需求**: 根据用户请求删除特定用户的所有数据

**推荐策略**: 轻量级删除

```sql
-- 快速删除用户数据
ALTER TABLE user_events
DELETE WHERE user_id = 'user123'
SETTINGS lightweight_delete = 1;

ALTER TABLE user_profile
DELETE WHERE user_id = 'user123'
SETTINGS lightweight_delete = 1;

-- 优点：快速，性能影响小
-- 缺点：需要 ClickHouse 23.8+
```

**备选策略**: Mutation 删除（如果使用旧版本）

```sql
ALTER TABLE user_events
DELETE WHERE user_id = 'user123';

ALTER TABLE user_profile
DELETE WHERE user_id = 'user123';

-- 优点：兼容所有版本
-- 缺点：性能影响大
```

### 场景 3: 数据归档

**需求**: 将旧数据移动到低成本存储，不删除

**推荐策略**: TTL 移动数据

```sql
-- 配置分层存储
CREATE TABLE events (
    event_time DateTime,
    data String
) ENGINE = MergeTree
PARTITION BY toYYYYMM(event_time)
ORDER BY event_time
TTL event_time + INTERVAL 30 DAY TO DISK 'archive'
SETTINGS storage_policy = 'tiered_storage';

-- 优点：自动移动，数据保留
-- 缺点：需要配置存储策略
```

**备选策略**: 手动导出+删除

```sql
-- 1. 导出数据到归档表
INSERT INTO events_archive
SELECT * FROM events
WHERE event_time < '2023-01-01';

-- 2. 删除原表数据
ALTER TABLE events
DROP PARTITION '2022-12';

-- 优点：灵活，完全控制
-- 缺点：需要手动操作
```

### 场景 4: 测试数据清理

**需求**: 删除测试环境生成的临时数据

**推荐策略**: 轻量级删除

```sql
-- 删除测试数据
ALTER TABLE events
DELETE WHERE environment = 'test'
SETTINGS lightweight_delete = 1;

-- 优点：快速，不影响生产数据
-- 缺点：需要 ClickHouse 23.8+
```

**备选策略**: Mutation 删除

```sql
ALTER TABLE events
DELETE WHERE environment = 'test';

-- 优点：兼容所有版本
-- 缺点：性能影响大
```

### 场景 5: 大规模数据清理

**需求**: 删除过去一年的数据（表总量的 50%）

**推荐策略**: 分区删除

```sql
-- 批量删除分区
ALTER TABLE events
DROP PARTITION '2022-01', '2022-02', '2022-03';

-- 优点：最快，效率最高
-- 缺点：只能按分区删除
```

**备选策略**: 重新分区 + 分区删除

```sql
-- 1. 重新分区以支持按日期删除
ALTER TABLE events
MODIFY PARTITION BY toYYYYMM(event_time);

-- 2. 等待合并完成
OPTIMIZE TABLE events FINAL;

-- 3. 删除旧分区
ALTER TABLE events
DROP PARTITION '2022-01';

-- 优点：可以精确控制
-- 缺点：重新分区需要时间
```

## 📈 性能评估

### 评估删除操作的性能影响

```sql
-- 估算删除的影响
SELECT
    '总行数' as metric,
    count() as value
FROM events

UNION ALL

SELECT
    '要删除的行数',
    count()
FROM events
WHERE event_time < '2023-01-01'

UNION ALL

SELECT
    '删除比例 (%)',
    round(count() * 100.0 / (SELECT count() FROM events), 2)
FROM events
WHERE event_time < '2023-01-01'

UNION ALL

SELECT
    '预估执行时间（秒）',
    round(count() * 0.001)  -- 粗略估算
FROM events
WHERE event_time < '2023-01-01';
```

### 选择最佳方法

```sql
-- 根据删除比例推荐方法
SELECT
    CASE 
        WHEN delete_percentage < 10 THEN '轻量级删除'
        WHEN delete_percentage < 30 THEN 'Mutation 删除'
        WHEN partition_based THEN '分区删除'
        ELSE '重新分区 + 分区删除'
    END AS recommended_method,
    delete_percentage,
    total_rows,
    rows_to_delete
FROM (
    SELECT
        count() AS total_rows,
        countIf(event_time < '2023-01-01') AS rows_to_delete,
        rows_to_delete * 100.0 / NULLIF(total_rows, 0) AS delete_percentage,
        -- 检查能否按分区删除
        count(DISTINCT toDate(event_time)) <= 12 AS partition_based
    FROM events
);
```

## 🎯 策略组合

### 组合策略 1: TTL + 手动清理

```sql
-- 使用 TTL 自动删除，但手动控制关键数据

-- 创建表
CREATE TABLE events (
    event_time DateTime,
    event_type String,
    data String,
    is_critical UInt8 DEFAULT 0
) ENGINE = MergeTree
PARTITION BY toYYYYMM(event_time)
ORDER BY event_time
TTL event_time + INTERVAL 30 DAY
WHERE is_critical = 0;  -- 只删除非关键数据

-- 定期手动清理关键数据
ALTER TABLE events
DELETE WHERE 
    is_critical = 1 
    AND event_time < '2023-01-01';
```

### 组合策略 2: 分区删除 + Mutation

```sql
-- 使用分区删除删除大部分数据，用 Mutation 删除少量数据

-- 1. 删除整个旧分区
ALTER TABLE events
DROP PARTITION '2022-12';

-- 2. 对最近分区进行精确删除
ALTER TABLE events
DELETE WHERE 
    event_time >= '2023-01-01'
    AND event_time < '2023-01-15'
    AND user_id = 'deleted_user';
```

### 组合策略 3: 轻量级删除 + OPTIMIZE

```sql
-- 使用轻量级删除标记数据，定期 OPTIMIZE 清理

-- 1. 标记删除
ALTER TABLE events
DELETE WHERE event_time < '2023-01-01'
SETTINGS lightweight_delete = 1;

-- 2. 定期触发合并清理已标记的数据
-- 可以通过调度器每天执行一次
OPTIMIZE TABLE events PARTITION '2022-12' FINAL;
```

## 📊 策略评估表

| 场景 | 数据量 | 时间敏感 | 推荐方法 | 备选方法 |
|------|--------|---------|---------|---------|
| 日志清理 | 大 | 否 | TTL 自动删除 | 分区删除 |
| GDPR 删除 | 小 | 是 | 轻量级删除 | Mutation 删除 |
| 数据归档 | 中 | 否 | TTL 移动 | 手动导出+删除 |
| 测试数据 | 中 | 否 | 轻量级删除 | Mutation 删除 |
| 大规模清理 | 大 | 是 | 分区删除 | 重新分区+分区删除 |
| 精确删除 | 小 | 是 | Mutation 删除 | 轻量级删除 |
| 定期清理 | 大 | 否 | TTL 自动删除 | 分区删除脚本 |

## 💡 最佳实践

### 1. 优先使用分区删除

```sql
-- 总是优先考虑分区删除
-- 它是最快、最高效的方法

-- 检查能否按分区删除
SELECT 
    partition,
    toDate(replaceRegexpOne(partition, '^(\\d{4})(\\d{2})', '\\1-\\2-01')) AS partition_date,
    count() AS rows
FROM system.parts
WHERE table = 'events' AND active = 1
GROUP BY partition
ORDER BY partition_date;
```

### 2. 合理使用 TTL

```sql
-- 为固定的保留策略设置 TTL
-- 但要注意删除延迟

-- 查看当前的 TTL 设置
SELECT 
    database,
    table,
    ttl_table
FROM system.tables
WHERE ttl_table != '';
```

### 3. 小批次处理

```sql
-- 将大删除拆分为多个小批次

-- 第一批次
ALTER TABLE events
DELETE WHERE 
    event_time >= '2022-01-01' 
    AND event_time < '2022-03-01';

-- 等待完成
SELECT is_done FROM system.mutations
WHERE command LIKE '%2022-01-01%' AND command LIKE '%2022-03-01%';

-- 第二批次
ALTER TABLE events
DELETE WHERE 
    event_time >= '2022-03-01' 
    AND event_time < '2022-05-01';
```

### 4. 监控执行

```sql
-- 监控删除操作的执行情况
SELECT
    mutation_id,
    command,
    is_done,
    create_time,
    done_time,
    parts_to_do,
    parts_to_do_names
FROM system.mutations
WHERE database = 'your_database'
ORDER BY create_time DESC;
```

### 5. 备份优先

```sql
-- 删除前总是备份数据

-- 1. 创建备份表
CREATE TABLE events_backup AS events;

-- 2. 备份要删除的数据
INSERT INTO events_backup
SELECT * FROM events
WHERE event_time < '2023-01-01';

-- 3. 验证备份
SELECT count() FROM events_backup;

-- 4. 执行删除
ALTER TABLE events
DROP PARTITION '2022-12';

-- 5. 删除备份（如需要）
-- DROP TABLE events_backup;
```

## ⚠️ 常见错误

### 错误 1: 使用 Mutation 删除大量数据

```sql
-- ❌ 错误：删除 50% 的数据使用 Mutation
ALTER TABLE events
DELETE WHERE event_time < '2023-01-01';

-- ✅ 正确：使用分区删除
ALTER TABLE events
DROP PARTITION '2022-12';
```

### 错误 2: 不考虑系统负载

```sql
-- ❌ 错误：在高负载时执行大删除
-- 在业务高峰期执行大删除会影响性能

-- ✅ 正确：在低峰期执行
-- 使用调度器在凌晨执行
```

### 错误 3: 不监控删除进度

```sql
-- ❌ 错误：执行删除后不检查状态
ALTER TABLE events
DELETE WHERE event_time < '2023-01-01';

-- ✅ 正确：监控删除进度
SELECT 
    is_done,
    parts_to_do,
    parts_done,
    parts_to_do - parts_done AS remaining_parts
FROM system.mutations
WHERE command LIKE '%event_time < 2023-01-01%';
```

### 错误 4: 不备份就删除

```sql
-- ❌ 错误：直接删除不备份
ALTER TABLE events
DROP PARTITION '2022-12';

-- ✅ 正确：先备份再删除
-- （参考上面的备份优先示例）
```

## 📝 相关文档

- [01_partition_deletion.md](./01_partition_deletion.md) - 分区删除
- [02_ttl_deletion.md](./02_ttl_deletion.md) - TTL 自动删除
- [03_mutation_deletion.md](./03_mutation_deletion.md) - Mutation 删除
- [04_lightweight_deletion.md](./04_lightweight_deletion.md) - 轻量级删除
