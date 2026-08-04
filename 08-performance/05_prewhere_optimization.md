# PREWHERE 优化

PREWHERE 是 ClickHouse 中用于优化大表查询的特殊语法，通过先过滤数据再处理，显著提升查询性能。

## 基本概念

### PREWHERE 特性

- **提前过滤**：在读取完整数据前先过滤
- **减少 IO**：只读取满足条件的列数据
- **自动优化**：ClickHouse 会自动将 WHERE 条件移到 PREWHERE
- **适用大表**：特别适合行数多的表

### 工作原理

```
传统查询流程：
1. 读取所有列
2. 应用 WHERE 条件
3. 返回结果

PREWHERE 查询流程：
1. 应用 PREWHERE 条件（只读取过滤列）
2. 应用 WHERE 条件（读取满足条件的所有列）
3. 返回结果
```

## PREWHERE 语法

### 基本 PREWHERE

```sql
SELECT 
    user_id,
    event_type,
    event_time
FROM events
PREWHERE event_time >= now() - INTERVAL 7 DAY
WHERE user_id = 123;
```

### 复合 PREWHERE

```sql
SELECT 
    user_id,
    event_type,
    event_time
FROM events
PREWHERE event_time >= now() - INTERVAL 7 DAY
  AND status = 1
WHERE user_id = 123
  AND event_type = 'click';
```

### 自动 PREWHERE

ClickHouse 会自动将 WHERE 条件移到 PREWHERE：

```sql
-- 编写的查询
SELECT 
    user_id,
    event_type,
    event_time
FROM events
WHERE event_time >= now() - INTERVAL 7 DAY
  AND user_id = 123;

-- ClickHouse 自动优化为
SELECT 
    user_id,
    event_type,
    event_time
FROM events
PREWHERE event_time >= now() - INTERVAL 7 DAY
WHERE user_id = 123;
```

## PREWHERE 优化场景

### 场景 1: 时间范围过滤

```sql
-- ✅ 使用 PREWHERE 过滤时间范围
SELECT 
    user_id,
    event_type,
    event_data
FROM events
PREWHERE event_time >= now() - INTERVAL 30 DAY
WHERE user_id IN (1, 2, 3, ..., 1000);

-- ❌ 不使用 PREWHERE
SELECT 
    user_id,
    event_type,
    event_data
FROM events
WHERE event_time >= now() - INTERVAL 30 DAY
  AND user_id IN (1, 2, 3, ..., 1000);
```

**性能提升**: 5-20x

### 场景 2: 大列过滤

```sql
-- ✅ 使用 PREWHERE 过滤大列
SELECT 
    user_id,
    event_type
FROM events
PREWHERE event_data LIKE '%keyword%'  -- 过滤大列
WHERE user_id IN (1, 2, 3, ..., 1000);

-- ❌ 不使用 PREWHERE
SELECT 
    user_id,
    event_type
FROM events
WHERE event_data LIKE '%keyword%'
  AND user_id IN (1, 2, 3, ..., 1000);
```

**性能提升**: 10-50x

### 场景 3: 状态过滤

```sql
-- ✅ 使用 PREWHERE 过滤状态
SELECT 
    user_id,
    event_type,
    event_time
FROM events
PREWHERE status = 1  -- 过滤状态
WHERE user_id IN (1, 2, 3, ..., 1000)
  AND event_time >= now() - INTERVAL 7 DAY;

-- ❌ 不使用 PREWHERE
SELECT 
    user_id,
    event_type,
    event_time
FROM events
WHERE status = 1
  AND user_id IN (1, 2, 3, ..., 1000)
  AND event_time >= now() - INTERVAL 7 DAY;
```

**性能提升**: 5-15x

## PREWHERE 优化技巧

### 技巧 1: 选择高选择性条件

```sql
-- ✅ 高选择性条件
SELECT * FROM events
PREWHERE event_time >= now() - INTERVAL 7 DAY  -- 高选择性
WHERE user_id = 123;

-- ❌ 低选择性条件
SELECT * FROM events
PREWHERE status = 1  -- 低选择性
WHERE user_id = 123;
```

### 技巧 2: 使用列名而非表达式

```sql
-- ✅ 使用列名
SELECT * FROM events
PREWHERE event_time >= now() - INTERVAL 7 DAY
WHERE user_id = 123;

-- ❌ 使用表达式
SELECT * FROM events
PREWHERE toDate(event_time) >= now() - INTERVAL 7 DAY
WHERE user_id = 123;
```

### 技巧 3: 组合多个条件

```sql
-- ✅ 组合多个 PREWHERE 条件
SELECT * FROM events
PREWHERE event_time >= now() - INTERVAL 7 DAY
  AND status = 1
  AND processed = 0
WHERE user_id IN (1, 2, 3, ..., 1000);
```

### 技巧 4: 避免复杂表达式

```sql
-- ✅ 简单条件
SELECT * FROM events
PREWHERE event_time >= now() - INTERVAL 7 DAY
WHERE user_id = 123;

-- ❌ 复杂表达式
SELECT * FROM events
PREWHERE event_time >= now() - INTERVAL 7 DAY
  AND substring(event_data, 1, 10) = 'prefix'
WHERE user_id = 123;
```

## PREWHERE 性能分析

### 查看执行计划

```sql
-- 查看是否使用了 PREWHERE
EXPLAIN PIPELINE
SELECT 
    user_id,
    event_type
FROM events
PREWHERE event_time >= now() - INTERVAL 7 DAY
WHERE user_id = 123;
```

### 查看 PREWHERE 过滤效果

```sql
-- 查看过滤统计
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
  AND query LIKE '%PREWHERE%'
  AND event_time >= now() - INTERVAL 24 HOUR
ORDER BY filter_ratio DESC
LIMIT 10;
```

## PREWHERE 最佳实践

### 1. 用于大表

```sql
-- ✅ 大表使用 PREWHERE
SELECT * FROM large_events
PREWHERE event_time >= now() - INTERVAL 7 DAY
WHERE user_id = 123;

-- ❌ 小表不需要 PREWHERE
SELECT * FROM small_events
WHERE event_time >= now() - INTERVAL 7 DAY
  AND user_id = 123;
```

### 2. 用于高选择性条件

```sql
-- ✅ 高选择性条件
SELECT * FROM events
PREWHERE event_time >= now() - INTERVAL 7 DAY  -- 过滤 80% 数据
WHERE user_id = 123;

-- ❌ 低选择性条件
SELECT * FROM events
PREWHERE status = 1  -- 只过滤 10% 数据
WHERE user_id = 123;
```

### 3. 用于大列

```sql
-- ✅ 大列使用 PREWHERE
SELECT 
    user_id,
    event_type
FROM events
PREWHERE event_data LIKE '%keyword%'  -- 大列（100MB+）
WHERE user_id = 123;

-- ❌ 小列不需要 PREWHERE
SELECT 
    user_id,
    event_data
FROM events
WHERE user_id = 123
  AND event_data LIKE '%keyword%';
```

### 4. 定期分析效果

```sql
-- 分析 PREWHERE 效果
SELECT 
    substring(query, 1, 100) as query_sample,
    count() as query_count,
    avg(read_rows) as avg_rows_read,
    avg(result_rows) as avg_rows_result,
    avg(read_rows / result_rows) as avg_filter_ratio
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query LIKE '%PREWHERE%'
  AND event_time >= now() - INTERVAL 7 DAY
GROUP BY query_sample
ORDER BY query_count DESC
LIMIT 10;
```

## PREWHERE 检查清单

- [ ] 表是否足够大？
  - [ ] > 1000 万行
  - [ ] > 10 GB

- [ ] PREWHERE 条件是否有选择性？
  - [ ] 过滤 > 50% 数据
  - [ ] 使用简单条件

- [ ] PREWHERE 条件是否包含大列？
  - [ ] 大列在 PREWHERE 中
  - [ ] 减少数据读取量

- [ ] 是否定期分析效果？
  - [ ] 分析查询日志
  - [ ] 查看过滤比例
  - [ ] 调整 PREWHERE 条件

## 性能提升

| 场景 | 性能提升 |
|------|---------|
| 时间范围过滤 | 5-20x |
| 大列过滤 | 10-50x |
| 状态过滤 | 5-15x |
| 组合条件 | 10-100x |

## 相关文档

- [01_query_optimization.md](./01_query_optimization.md) - 查询优化基础
- [02_primary_indexes.md](./02_primary_indexes.md) - 主键索引优化
- [11_query_profiling.md](./11_query_profiling.md) - 查询分析和 Profiling
