# 批量插入优化

批量插入是 ClickHouse 写入性能优化的核心，通过合理的批量插入策略可以显著提升写入性能。

## 基本概念

### 批量插入特性

- **高吞吐量**：单次插入大量数据
- **减少开销**：减少网络和解析开销
- **顺序写入**：利用 MergeTree 的顺序写入优势
- **并行写入**：多个客户端并行写入

### 写入模式对比

| 模式 | 批量大小 | 吞吐量 | 延迟 | 适用场景 |
|------|---------|--------|------|---------|
| 单条插入 | 1 行 | 低 | 高 | 避免 |
| 小批量插入 | 100-1000 行 | 中 | 中 | 实时数据 |
| 大批量插入 | 10000-100000 行 | 高 | 低 | 离线数据 |
| 超大批量插入 | > 100000 行 | 很高 | 很高 | 定期导入 |

## 批量插入优化

### 1. 使用 INSERT VALUES

```sql
-- ✅ 批量插入
INSERT INTO events
VALUES
(1, 100, 'click', now(), '{"page":"/home"}'),
(2, 100, 'view', now(), '{"product":"laptop"}'),
(3, 101, 'click', now(), '{"page":"/about"}'),
(4, 102, 'click', now(), '{"page":"/products"}'),
(5, 103, 'click', now(), '{"page":"/cart"}');

-- ❌ 单条插入（避免）
INSERT INTO events
VALUES (1, 100, 'click', now(), '{"page":"/home"}');
INSERT INTO events
VALUES (2, 100, 'view', now(), '{"product":"laptop"}');
```

**性能提升**: 10-100x

### 2. 使用 INSERT SELECT

```sql
-- ✅ 批量插入（从其他表）
INSERT INTO events
SELECT 
    number as event_id,
    number % 1000 as user_id,
    'click' as event_type,
    now() as event_time,
    '{}' as event_data
FROM numbers(100000);  -- 10 万行

-- ✅ 批量插入（从外部数据）
INSERT INTO events
FROM file('events.csv', 'CSV')
SETTINGS input_format_skip_first_lines = 1,
        input_format_allow_errors_num = 100;
```

**性能提升**: 5-50x

### 3. 使用异步插入

```sql
-- ✅ 异步插入
INSERT INTO events
SETTINGS async_insert = 1,
        wait_for_async_insert = 0,
        async_insert_max_data_size = 100000000,  -- 100 MB
        async_insert_busy_timeout_ms = 5000,
        async_insert_max_wait_time_ms = 10000
VALUES
(1, 100, 'click', now(), '{"page":"/home"}'),
(2, 100, 'view', now(), '{"product":"laptop"}');

-- ✅ 异步插入不等待结果
INSERT INTO events
SETTINGS async_insert = 1,
        wait_for_async_insert = 0
VALUES (3, 101, 'click', now(), '{"page":"/about"}');
```

**性能提升**: 2-10x

### 4. 使用并行插入

```sql
-- ✅ 并行插入（多个客户端）
-- 客户端 1
INSERT INTO events
VALUES (1, 100, 'click', now(), '{}');

-- 客户端 2
INSERT INTO events
VALUES (2, 100, 'view', now(), '{}');

-- 客户端 3
INSERT INTO events
VALUES (3, 101, 'click', now(), '{}');

-- 或使用分布式表
INSERT INTO distributed_events
VALUES (4, 102, 'click', now(), '{}');
```

**性能提升**: 2-8x

### 5. 使用压缩

```sql
-- ✅ 使用压缩插入
INSERT INTO events
SETTINGS max_insert_threads = 4,
        min_insert_block_size_rows = 65536,
        min_insert_block_size_bytes = 268435456
FORMAT Native
FROM file('events.native', 'Native')
SETTINGS compression = 'lz4';

-- ✅ 使用压缩协议
clickhouse-client --query="INSERT INTO events FORMAT Native" \
  --format=Native \
  --compression=lz4 \
  < data.bin
```

**性能提升**: 1.5-3x

## 批量插入参数

### 插入线程数

```sql
-- 设置插入线程数
INSERT INTO events
SETTINGS max_insert_threads = 4
VALUES (1, 100, 'click', now(), '{}');
```

### 块大小

```sql
-- 设置块大小
INSERT INTO events
SETTINGS min_insert_block_size_rows = 65536,
        min_insert_block_size_bytes = 268435456
VALUES (1, 100, 'click', now(), '{}');
```

### 并发控制

```sql
-- 设置最大并发插入数
INSERT INTO events
SETTINGS max_concurrent_inserts = 10
VALUES (1, 100, 'click', now(), '{}');
```

### 等待完成

```sql
-- 等待插入完成
INSERT INTO events
SETTINGS wait_for_async_insert = 1
VALUES (1, 100, 'click', now(), '{}');
```

## 批量插入优化示例

### 示例 1: 日志数据批量插入

```sql
-- ✅ 批量插入日志数据
INSERT INTO logs
SETTINGS max_insert_threads = 8,
        min_insert_block_size_rows = 100000,
        min_insert_block_size_bytes = 100000000
VALUES
(1, 'user1', 'INFO', '2024-01-20 10:00:00', 'Message 1'),
(2, 'user1', 'INFO', '2024-01-20 10:00:01', 'Message 2'),
(3, 'user2', 'INFO', '2024-01-20 10:00:02', 'Message 3'),
-- ... 100000 行
(100000, 'user100', 'INFO', '2024-01-20 12:00:00', 'Message 100000');
```

**性能提升**: 20-100x（相对于单条插入）

### 示例 2: 事件数据批量插入

```sql
-- ✅ 使用 INSERT SELECT
INSERT INTO events
SETTINGS max_insert_threads = 8,
        min_insert_block_size_rows = 100000
SELECT 
    rowNumberInAllBlocks() as event_id,
    number % 1000 as user_id,
    ['click', 'view', 'purchase'][number % 3] as event_type,
    now() - INTERVAL (number % 86400) SECOND as event_time,
    '{}' as event_data
FROM numbers(1000000);  -- 100 万行
```

**性能提升**: 10-50x（相对于小批量插入）

### 示例 3: 异步批量插入

```sql
-- ✅ 异步批量插入
INSERT INTO events
SETTINGS async_insert = 1,
        wait_for_async_insert = 0,
        async_insert_max_data_size = 100000000,
        async_insert_busy_timeout_ms = 5000,
        max_insert_threads = 4
VALUES
(1, 100, 'click', now(), '{}'),
(2, 100, 'view', now(), '{}'),
(3, 101, 'click', now(), '{}'),
-- ... 10000 行
(10000, 103, 'click', now(), '{}');
```

**性能提升**: 3-10x（相对于同步插入）

### 示例 4: 并行批量插入

```sql
-- ✅ 并行插入（使用分布式表）
INSERT INTO distributed_events
SETTINGS max_insert_threads = 4
SELECT 
    event_id,
    user_id,
    event_type,
    event_time,
    event_data
FROM events_temp
WHERE shard % 4 = 0;  -- 第一个分片

INSERT INTO distributed_events
SETTINGS max_insert_threads = 4
SELECT 
    event_id,
    user_id,
    event_type,
    event_time,
    event_data
FROM events_temp
WHERE shard % 4 = 1;  -- 第二个分片
```

**性能提升**: 2-4x（相对于单线程插入）

## 批量插入最佳实践

### 1. 选择合适的批量大小

| 场景 | 推荐批量大小 | 说明 |
|------|------------|------|
| 实时数据 | 1000-10000 行 | 平衡延迟和吞吐量 |
| 离线数据 | 10000-100000 行 | 最大化吞吐量 |
| 大数据导入 | 100000-1000000 行 | 最快导入速度 |

### 2. 使用合适的插入格式

```sql
-- ✅ Native 格式（最快）
INSERT INTO events
FORMAT Native
FROM file('events.native', 'Native');

-- ✅ CSV 格式（通用）
INSERT INTO events
FORMAT CSVWithNames
FROM file('events.csv', 'CSV');

-- ✅ JSONEachRow 格式（JSON 数据）
INSERT INTO events
FORMAT JSONEachRow
FROM file('events.jsonl', 'JSONEachRow');
```

### 3. 合理设置线程数

```sql
-- ✅ 合理的线程数
INSERT INTO events
SETTINGS max_insert_threads = min(8, CPU核数)
VALUES (...);
```

### 4. 监控插入性能

```sql
-- 查看插入统计
SELECT 
    query,
    write_rows,
    write_bytes,
    query_duration_ms,
    write_rows / query_duration_ms as rows_per_second,
    formatReadableSize(write_bytes) as write_size
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query LIKE '%INSERT%'
  AND event_time >= now() - INTERVAL 1 HOUR
ORDER BY query_duration_ms DESC
LIMIT 10;
```

## 批量插入检查清单

- [ ] 是否使用批量插入？
  - [ ] 每批 > 1000 行
  - [ ] 使用 INSERT VALUES 或 SELECT

- [ ] 批量大小是否合理？
  - [ ] 实时数据：1000-10000 行
  - [ ] 离线数据：10000-100000 行

- [ ] 是否使用并行插入？
  - [ ] 多客户端并行
  - [ ] 合理设置线程数

- [ ] 是否使用异步插入？
  - [ ] 高频插入使用异步
  - [ ] 配置合理的异步参数

- [ ] 是否使用压缩？
  - [ ] 使用压缩格式
  - [ ] 使用压缩协议

## 性能提升

| 优化方法 | 性能提升 |
|---------|---------|
| 批量插入（相对于单条）| 10-100x |
| 并行插入 | 2-8x |
| 异步插入 | 2-10x |
| 使用压缩 | 1.5-3x |
| 合理参数 | 1.5-5x |

## 相关文档

- [09_data_types.md](./09_data_types.md) - 数据类型优化
- [11_query_profiling.md](./11_query_profiling.md) - 查询分析和 Profiling
- [14_hardware_tuning.md](./14_hardware_tuning.md) - 硬件调优和测试
