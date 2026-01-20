# ClickHouse 实时性能优化指南

## 问题背景

**场景**：数据写入和查询都需要极高的实时性（延迟 < 100ms）

**核心挑战**：
1. **写入延迟**：大批量数据写入需要快速完成
2. **查询延迟**：实时查询需要立即返回结果
3. **去重性能**：实时去重不能影响写入性能
4. **并发压力**：高并发读写下的性能保证

## 解决方案总览

| 方案 | 写入延迟 | 查询延迟 | 去重 | 适用场景 |
|------|----------|----------|------|----------|
| **Buffer 表** | ⭐⭐⭐⭐⭐ | ⭐⭐⭐ | ❌ | 超高频小批量写入 |
| **异步插入** | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐ | ⭐⭐⭐⭐ | 高并发写入 |
| **物化视图** | ⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ | ⭐⭐ | 实时聚合 |
| **Projection** | ⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ | ❌ | 查询加速 |
| **分布式表** | ⭐⭐⭐ | ⭐⭐⭐⭐ | ⭐⭐ | 大数据量查询 |
| **跳数索引** | ⭐⭐⭐ | ⭐⭐⭐⭐⭐ | ❌ | 高基数字段过滤 |

---

## 方案 1：Buffer 表（极速写入）

### 原理

Buffer 表作为写入缓冲，达到阈值后自动刷新到目标表，减少磁盘 I/O。

### 表结构

```sql
-- 生产环境：使用复制版本 + ON CLUSTER
-- 目标表
CREATE TABLE IF NOT EXISTS realtime.events ON CLUSTER 'treasurycluster' (
    event_id String,
    user_id UInt64,
    event_type String,
    event_data String,
    event_time DateTime,
    inserted_at DateTime DEFAULT now()
) ENGINE = ReplicatedMergeTree
PARTITION BY toYYYYMM(event_time)
ORDER BY (user_id, event_time, event_id)
SETTINGS index_granularity = 8192;

-- Buffer 表（写入缓冲）
CREATE TABLE IF NOT EXISTS realtime.buffer_events ON CLUSTER 'treasurycluster'
AS realtime.events
ENGINE = Buffer(realtime, events,
    16,   -- num_buckets：缓冲区数量（建议 = CPU 核心数）
    10,   -- max_times：每个缓冲区最多刷新次数
    100,  -- max_rows：每个缓冲区最多行数
    10000000,  -- max_bytes：每个缓冲区最大字节数
    10,   -- min_time：最小刷新间隔（秒）
    100,  -- max_time：最大刷新间隔（秒）
    2     -- min_rows：最小刷新行数
);

-- 去重表（可选，用于应用层去重）
CREATE TABLE IF NOT EXISTS realtime.event_dedup ON CLUSTER 'treasurycluster' (
    event_id String,
    processed_at DateTime DEFAULT now()
) ENGINE = ReplicatedMergeTree
ORDER BY event_id
TTL processed_at + INTERVAL 1 HOUR  -- 1小时后自动删除
SETTINGS index_granularity = 8192;
```

### 写入方式

```python
# Python 示例：超高频写入
import time
import clickhouse_driver
from concurrent.futures import ThreadPoolExecutor

class RealtimeWriter:
    def __init__(self):
        self.client = clickhouse_driver.Client(host='localhost', port=9000)

    def write_event(self, event_data):
        """
        写入单个事件（通过 Buffer 表）
        延迟：< 10ms
        """
        try:
            # 写入 Buffer 表（极快，几乎无延迟）
            self.client.execute(
                'INSERT INTO realtime.buffer_events VALUES',
                [(
                    event_data['event_id'],
                    event_data['user_id'],
                    event_data['event_type'],
                    event_data['event_data'],
                    event_data['event_time'],
                    event_data.get('inserted_at', time.time())
                )]
            )
            return True
        except Exception as e:
            print(f"Failed to write event: {e}")
            return False

    def batch_write_events(self, events):
        """
        批量写入事件
        """
        try:
            self.client.execute(
                'INSERT INTO realtime.buffer_events VALUES',
                events
            )
            return True
        except Exception as e:
            print(f"Failed to batch write events: {e}")
            return False

# 使用示例
writer = RealtimeWriter()

# 场景 1：单条高频写入（延迟 < 10ms）
for i in range(1000):
    event = {
        'event_id': f'evt-{int(time.time() * 1000000)}-{i}',
        'user_id': 1001,
        'event_type': 'click',
        'event_data': f'{{"page":"/page-{i}"}}',
        'event_time': time.time()
    }
    writer.write_event(event)

# 场景 2：并发写入
def write_worker(worker_id, count=100):
    for i in range(count):
        event = {
            'event_id': f'evt-{worker_id}-{int(time.time() * 1000000)}-{i}',
            'user_id': worker_id,
            'event_type': 'click',
            'event_data': f'{{"page":"/page-{i}"}}',
            'event_time': time.time()
        }
        writer.write_event(event)

# 启动 10 个并发写入线程
with ThreadPoolExecutor(max_workers=10) as executor:
    for i in range(10):
        executor.submit(write_worker, i, 1000)
```

### 查询方式

```sql
-- 查询实时数据（Buffer 表数据可能未完全刷新）
-- 方式 1：查询目标表（推荐）
SELECT * FROM realtime.events
WHERE user_id = 1001
  AND event_time >= now() - INTERVAL 1 HOUR
ORDER BY event_time;

-- 方式 2：强制刷新 Buffer 表后查询
-- 注意：会触发所有缓冲区立即刷新，可能影响性能
SYSTEM FLUSH DISTRIBUTED realtime.buffer_events;

SELECT * FROM realtime.events
WHERE user_id = 1001
ORDER BY event_time;

-- 查看 Buffer 表状态
SELECT
    database,
    table,
    formatReadableSize(bytes) as size,
    rows,
    formatReadableSize(min_rows * size_of_row) as min_flush_size
FROM system.buffers
WHERE database = 'realtime';
```

### 优缺点

**优点**：
- ✅ 极低写入延迟（< 10ms）
- ✅ 自动批量写入到目标表
- ✅ 减少磁盘 I/O
- ✅ 提高写入吞吐量

**缺点**：
- ❌ Buffer 表数据查询延迟
- ❌ 内存占用较高
- ❌ 需要合理配置缓冲区参数

**适用场景**：
- ✅ 超高频小批量写入
- ✅ 日志收集
- ✅ 实时监控指标
- ✅ IoT 设备数据

---

## 方案 2：异步插入

### 原理

ClickHouse 支持异步插入，数据先写入内存缓冲区，后台异步刷新到磁盘。

### 表结构

```sql
-- 启用异步插入的表
CREATE TABLE IF NOT EXISTS realtime.async_events ON CLUSTER 'treasurycluster' (
    event_id String,
    user_id UInt64,
    event_type String,
    event_data String,
    event_time DateTime,
    inserted_at DateTime DEFAULT now()
) ENGINE = ReplicatedMergeTree
PARTITION BY toYYYYMM(event_time)
ORDER BY (user_id, event_time, event_id)
SETTINGS index_granularity = 8192,
           -- 异步插入配置
           async_insert = 1,                        -- 启用异步插入
           async_insert_max_data_size = 1048576,       -- 最大缓冲区大小（1MB）
           async_insert_busy_timeout_ms = 100,         -- 忙碌超时（100ms）
           async_insert_stalled_timeout_ms = 1000,     -- 停滞超时（1s）
           wait_for_async_insert = 0;                 -- 不等待异步插入完成
```

### 写入方式

```python
import time
import clickhouse_driver

class AsyncWriter:
    def __init__(self):
        self.client = clickhouse_driver.Client(
            host='localhost',
            port=9000,
            settings={'wait_for_async_insert': 0}  -- 不等待异步插入
        )

    def write_async(self, event_data):
        """
        异步写入（立即返回）
        延迟：< 5ms
        """
        try:
            # 启用异步插入设置
            self.client.execute(
                'INSERT INTO realtime.async_events SETTINGS wait_for_async_insert=0 VALUES',
                [(
                    event_data['event_id'],
                    event_data['user_id'],
                    event_data['event_type'],
                    event_data['event_data'],
                    event_data['event_time'],
                    event_data.get('inserted_at', time.time())
                )],
                settings={'wait_for_async_insert': 0}
            )
            return True
        except Exception as e:
            print(f"Failed to async write: {e}")
            return False

    def batch_write_async(self, events):
        """
        批量异步写入
        """
        try:
            self.client.execute(
                'INSERT INTO realtime.async_events SETTINGS wait_for_async_insert=0 VALUES',
                events,
                settings={'wait_for_async_insert': 0}
            )
            return True
        except Exception as e:
            print(f"Failed to batch async write: {e}")
            return False

# 使用示例
writer = AsyncWriter()

# 高频写入（立即返回）
for i in range(10000):
    event = {
        'event_id': f'async-evt-{int(time.time() * 1000000)}-{i}',
        'user_id': 1001,
        'event_type': 'click',
        'event_data': f'{{"page":"/page-{i}"}}',
        'event_time': time.time()
    }
    writer.write_async(event)
```

### 查询方式

```sql
-- 异步插入的查询
-- 数据可能还未刷新到磁盘，但可以在内存中查询到
SELECT * FROM realtime.async_events
WHERE user_id = 1001
  AND event_time >= now() - INTERVAL 1 HOUR
ORDER BY event_time;

-- 查看异步插入统计
SELECT
    metric,
    value
FROM system.asynchronous_metrics
WHERE metric LIKE '%AsyncInsert%';

-- 查看异步插入队列
SELECT
    database,
    table,
    formatReadableSize(bytes) as size,
    rows,
    formatReadableSize(bytes / (rows + 1)) as avg_row_size
FROM system.parts
WHERE database = 'realtime'
  AND table = 'async_events'
  AND active
ORDER BY modification_time DESC
LIMIT 10;
```

### 优缺点

**优点**：
- ✅ 极低写入延迟（< 5ms）
- ✅ 支持高并发
- ✅ 自动批量合并
- ✅ 配置简单

**缺点**：
- ❌ 数据可能有短暂延迟（< 1s）
- ❌ 内存占用较高
- ❌ 需要合理配置超时参数

**适用场景**：
- ✅ 高并发写入
- ✅ 实时日志
- ✅ 监控指标
- ✅ API 请求日志

---

## 方案 3：物化视图（实时聚合）

### 原理

物化视图在数据写入时自动触发聚合，查询时直接读取聚合结果，性能极高。

### 表结构

```sql
-- 原始事件表
CREATE TABLE IF NOT EXISTS realtime.raw_events ON CLUSTER 'treasurycluster' (
    event_id String,
    user_id UInt64,
    event_type String,
    event_value UInt32,
    event_time DateTime,
    inserted_at DateTime DEFAULT now()
) ENGINE = ReplicatedMergeTree
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_time, user_id, event_id)
SETTINGS index_granularity = 8192;

-- 实时 1 分钟聚合（物化视图）
CREATE MATERIALIZED VIEW IF NOT EXISTS realtime.events_1min_mv ON CLUSTER 'treasurycluster'
ENGINE = ReplicatedSummingMergeTree
PARTITION BY toYYYYMM(toStartOfMinute(event_time))
ORDER BY (toStartOfMinute(event_time), event_type)
AS SELECT
    toStartOfMinute(event_time) as minute,
    event_type,
    sum(event_value) as total_value,
    count() as event_count
FROM realtime.raw_events
GROUP BY minute, event_type;

-- 实时 5 分钟聚合
CREATE MATERIALIZED VIEW IF NOT EXISTS realtime.events_5min_mv ON CLUSTER 'treasurycluster'
ENGINE = ReplicatedSummingMergeTree
PARTITION BY toYYYYMM(toStartOfFiveMinute(event_time))
ORDER BY (toStartOfFiveMinute(event_time), event_type)
AS SELECT
    toStartOfFiveMinute(event_time) as five_minute,
    event_type,
    sum(event_value) as total_value,
    count() as event_count
FROM realtime.raw_events
GROUP BY five_minute, event_type;

-- 实时 1 小时聚合
CREATE MATERIALIZED VIEW IF NOT EXISTS realtime.events_1hour_mv ON CLUSTER 'treasurycluster'
ENGINE = ReplicatedSummingMergeTree
PARTITION BY toYYYYMM(toStartOfHour(event_time))
ORDER BY (toStartOfHour(event_time), event_type)
AS SELECT
    toStartOfHour(event_time) as hour,
    event_type,
    sum(event_value) as total_value,
    count() as event_count
FROM realtime.raw_events
GROUP BY hour, event_type;
```

### 写入方式

```sql
-- 写入原始数据，物化视图自动聚合
INSERT INTO realtime.raw_events VALUES
('evt-001', 1001, 'click', 10, '2024-01-01 10:00:00', now()),
('evt-002', 1001, 'click', 20, '2024-01-01 10:00:01', now()),
('evt-003', 1002, 'view', 30, '2024-01-01 10:00:02', now()),
('evt-004', 1001, 'purchase', 100, '2024-01-01 10:01:00', now()),
('evt-005', 1002, 'click', 15, '2024-01-01 10:01:01', now());

-- 批量写入
INSERT INTO realtime.raw_events
SELECT
    concat('evt-', toString(number)) as event_id,
    (number % 100) + 1 as user_id,
    ['click', 'view', 'purchase'][number % 3] as event_type,
    (number % 100) + 1 as event_value,
    now() - INTERVAL (number % 3600) SECOND as event_time,
    now() as inserted_at
FROM numbers(10000);
```

### 查询方式

```sql
-- 查询 1 分钟聚合结果（实时，< 10ms）
SELECT
    minute,
    event_type,
    sum(total_value) as total_value,
    sum(event_count) as total_count
FROM realtime.events_1min_mv
WHERE minute >= now() - INTERVAL 1 HOUR
GROUP BY minute, event_type
ORDER BY minute;

-- 查询 5 分钟聚合结果（实时，< 10ms）
SELECT
    five_minute,
    event_type,
    sum(total_value) as total_value,
    sum(event_count) as total_count
FROM realtime.events_5min_mv
WHERE five_minute >= now() - INTERVAL 6 HOUR
GROUP BY five_minute, event_type
ORDER BY five_minute;

-- 查询 1 小时聚合结果（实时，< 10ms）
SELECT
    hour,
    event_type,
    sum(total_value) as total_value,
    sum(event_count) as total_count
FROM realtime.events_1hour_mv
WHERE hour >= now() - INTERVAL 24 HOUR
GROUP BY hour, event_type
ORDER BY hour;

-- 查询聚合统计
SELECT
    table,
    sum(rows) as total_rows,
    formatReadableSize(sum(bytes_on_disk)) as disk_size
FROM system.parts
WHERE database = 'realtime'
  AND active
  AND table LIKE '%mv'
GROUP BY table;
```

### 优缺点

**优点**：
- ✅ 查询性能极高（< 10ms）
- ✅ 实时聚合（写入时自动触发）
- ✅ 减少原始表查询压力
- ✅ 支持多级聚合

**缺点**：
- ❌ 增加存储空间
- ❌ 写入时有一定开销
- ❌ 聚合维度固定

**适用场景**：
- ✅ 实时统计报表
- ✅ Dashboard 指标
- ✅ 实时监控
- ✅ 大数据量聚合查询

---

## 方案 4：Projection（查询加速）

### 原理

Projection 是表的预计算索引，类似于物化视图但更轻量级。

### 表结构

```sql
-- 创建带 Projection 的表
CREATE TABLE IF NOT EXISTS realtime.events_with_projection ON CLUSTER 'treasurycluster' (
    event_id String,
    user_id UInt64,
    event_type String,
    event_value UInt32,
    event_time DateTime,
    inserted_at DateTime DEFAULT now()
) ENGINE = ReplicatedMergeTree
PARTITION BY toYYYYMM(event_time)
ORDER BY (user_id, event_time, event_id)
SETTINGS index_granularity = 8192
-- Projection 1：按用户统计
PROJECTION user_stats
(
    SELECT
        user_id,
        sum(event_value) as total_value,
        count() as event_count,
        min(event_time) as first_event_time,
        max(event_time) as last_event_time
    GROUP BY user_id
)
-- Projection 2：按事件类型统计
PROJECTION type_stats
(
    SELECT
        event_type,
        sum(event_value) as total_value,
        count() as event_count
    GROUP BY event_type
)
-- Projection 3：按小时聚合
PROJECTION hourly_stats
(
    SELECT
        toStartOfHour(event_time) as hour,
        event_type,
        sum(event_value) as total_value,
        count() as event_count
    GROUP BY hour, event_type
);
```

### 写入方式

```sql
-- 正常写入（Projection 自动更新）
INSERT INTO realtime.events_with_projection VALUES
('evt-001', 1001, 'click', 10, '2024-01-01 10:00:00', now()),
('evt-002', 1001, 'click', 20, '2024-01-01 10:00:01', now()),
('evt-003', 1002, 'view', 30, '2024-01-01 10:00:02', now());

-- 批量写入
INSERT INTO realtime.events_with_projection
SELECT
    concat('evt-', toString(number)) as event_id,
    (number % 100) + 1 as user_id,
    ['click', 'view', 'purchase'][number % 3] as event_type,
    (number % 100) + 1 as event_value,
    now() - INTERVAL (number % 3600) SECOND as event_time,
    now() as inserted_at
FROM numbers(10000);
```

### 查询方式

```sql
-- 使用 Projection 查询（自动优化，< 20ms）
SELECT * FROM realtime.events_with_projection
WHERE user_id = 1001;

-- 按用户统计（使用 user_stats Projection）
SELECT
    user_id,
    total_value,
    event_count,
    first_event_time,
    last_event_time
FROM realtime.events_with_projection
WHERE user_id IN (1001, 1002, 1003);

-- 按事件类型统计（使用 type_stats Projection）
SELECT
    event_type,
    total_value,
    event_count
FROM realtime.events_with_projection
WHERE event_type IN ('click', 'view', 'purchase');

-- 按小时聚合（使用 hourly_stats Projection）
SELECT
    hour,
    event_type,
    total_value,
    event_count
FROM realtime.events_with_projection
WHERE hour >= now() - INTERVAL 24 HOUR;

-- 查看 Projection 状态
SELECT
    table,
    name,
    formatReadableSize(bytes_on_disk) as size,
    rows
FROM system.projections
WHERE database = 'realtime'
  AND table = 'events_with_projection';

-- 强制重建 Projection
ALTER TABLE realtime.events_with_projection MATERIALIZE PROJECTION user_stats;
ALTER TABLE realtime.events_with_projection MATERIALIZE PROJECTION type_stats;
ALTER TABLE realtime.events_with_projection MATERIALIZE PROJECTION hourly_stats;
```

### 优缺点

**优点**：
- ✅ 查询性能提升明显（2-10x）
- ✅ 自动维护，无需手动刷新
- ✅ 占用存储空间小
- ✅ 支持多个 Projection

**缺点**：
- ❌ 写入时有一定开销
- ❌ 查询语句必须匹配 Projection
- ❌ ClickHouse 版本要求（21.8+）

**适用场景**：
- ✅ 高频聚合查询
- ✅ Dashboard 查询
- ✅ 实时统计

---

## 方案 5：分布式表 + 去重

### 原理

使用分布式表将数据分散到多个节点，提高并发写入和查询能力。

### 表结构

```sql
-- 本地表
CREATE TABLE IF NOT EXISTS realtime.events_local ON CLUSTER 'treasurycluster' (
    event_id String,
    user_id UInt64,
    event_type String,
    event_data String,
    event_time DateTime,
    version UInt64,           -- 版本号（用于去重）
    inserted_at DateTime DEFAULT now()
) ENGINE = ReplicatedReplacingMergeTree(version)
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_id, event_time)
SETTINGS index_granularity = 8192;

-- 分布式表
CREATE TABLE IF NOT EXISTS realtime.events_distributed ON CLUSTER 'treasurycluster'
AS realtime.events_local
ENGINE = Distributed('treasurycluster', 'realtime', 'events_local', rand());

-- 去重表
CREATE TABLE IF NOT EXISTS realtime.events_dedup ON CLUSTER 'treasurycluster' (
    event_id String,
    processed_at DateTime DEFAULT now()
) ENGINE = ReplicatedMergeTree
ORDER BY event_id
TTL processed_at + INTERVAL 1 HOUR
SETTINGS index_granularity = 8192;
```

### 写入方式

```python
import time
import clickhouse_driver

class DistributedWriter:
    def __init__(self):
        self.client = clickhouse_driver.Client(host='localhost', port=9000)

    def write_with_dedup(self, event_data):
        """
        带去重的分布式写入
        """
        event_id = event_data['event_id']
        version = int(time.time() * 1000000)

        # 1. 检查是否已处理
        result = self.client.execute(
            'SELECT count() FROM realtime.events_dedup WHERE event_id = %(event_id)s',
            {'event_id': event_id}
        )

        if result[0][0] > 0:
            print(f"Event {event_id} already exists, skipping")
            return

        try:
            # 2. 写入分布式表
            self.client.execute(
                'INSERT INTO realtime.events_distributed VALUES',
                [(
                    event_id,
                    event_data['user_id'],
                    event_data['event_type'],
                    event_data['event_data'],
                    event_data['event_time'],
                    version,
                    time.time()
                )]
            )

            # 3. 插入去重表
            self.client.execute(
                'INSERT INTO realtime.events_dedup VALUES',
                [(event_id, time.time())]
            )

            print(f"Event {event_id} inserted successfully")
            return True

        except Exception as e:
            # 4. 发生错误，删除去重记录（允许重试）
            self.client.execute(
                'DELETE FROM realtime.events_dedup WHERE event_id = %(event_id)s',
                {'event_id': event_id}
            )
            print(f"Failed to insert event {event_id}: {e}")
            raise

# 使用示例
writer = DistributedWriter()

# 高频写入
for i in range(1000):
    event = {
        'event_id': f'dist-evt-{int(time.time() * 1000000)}-{i}',
        'user_id': (i % 100) + 1,
        'event_type': ['click', 'view', 'purchase'][i % 3],
        'event_data': f'{{"page":"/page-{i}"}}',
        'event_time': time.time()
    }
    writer.write_with_dedup(event)
```

### 查询方式

```sql
-- 查询分布式表（自动路由到所有节点）
SELECT
    user_id,
    event_type,
    count() as event_count,
    sum(length(event_data)) as total_data_size
FROM realtime.events_distributed
WHERE event_time >= now() - INTERVAL 1 HOUR
GROUP BY user_id, event_type
ORDER BY event_count DESC;

-- 查询本地表（直接查询特定节点）
SELECT * FROM realtime.events_local
WHERE user_id = 1001
ORDER BY event_time DESC
LIMIT 100;

-- 查看分布式表状态
SELECT
    shard,
    replica_num,
    host_name,
    port,
    user,
    errors_count,
    slowdowns_count
FROM system.clusters
WHERE cluster = 'treasurycluster';
```

### 优缺点

**优点**：
- ✅ 高并发写入和查询
- ✅ 数据自动分布到多个节点
- ✅ 提高整体吞吐量
- ✅ 故障自动切换

**缺点**：
- ❌ 配置复杂
- ❌ 跨节点查询有一定开销
- ❌ 需要合理配置分片策略

**适用场景**：
- ✅ 大数据量写入和查询
- ✅ 高并发场景
- ✅ 多节点集群

---

## 方案 6：综合优化（推荐）

### 表结构

```sql
-- 目标表（启用异步插入 + Projection）
CREATE TABLE IF NOT EXISTS realtime.optimized_events ON CLUSTER 'treasurycluster' (
    event_id String,
    user_id UInt64,
    event_type String,
    event_data String,
    event_value UInt32,
    event_time DateTime,
    version UInt64,           -- 版本号（用于去重）
    inserted_at DateTime DEFAULT now()
) ENGINE = ReplicatedReplacingMergeTree(version)
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_id, event_time)
SETTINGS index_granularity = 8192,
           -- 异步插入配置
           async_insert = 1,
           async_insert_max_data_size = 1048576,
           async_insert_busy_timeout_ms = 100,
           wait_for_async_insert = 0
-- Projection：实时统计
PROJECTION user_stats
(
    SELECT
        user_id,
        sum(event_value) as total_value,
        count() as event_count,
        min(event_time) as first_event_time,
        max(event_time) as last_event_time
    GROUP BY user_id
)
PROJECTION type_stats
(
    SELECT
        event_type,
        sum(event_value) as total_value,
        count() as event_count
    GROUP BY event_type
)
PROJECTION hourly_stats
(
    SELECT
        toStartOfHour(event_time) as hour,
        event_type,
        sum(event_value) as total_value,
        count() as event_count
    GROUP BY hour, event_type
);

-- Buffer 表（写入缓冲）
CREATE TABLE IF NOT EXISTS realtime.buffer_optimized_events ON CLUSTER 'treasurycluster'
AS realtime.optimized_events
ENGINE = Buffer(realtime, optimized_events,
    16,   -- num_buckets
    10,   -- max_times
    100,  -- max_rows
    10000000,  -- max_bytes
    5,    -- min_time（秒）
    60,   -- max_time（秒）
    2     -- min_rows
);

-- 物化视图（实时 1 分钟聚合）
CREATE MATERIALIZED VIEW IF NOT EXISTS realtime.optimized_events_1min_mv ON CLUSTER 'treasurycluster'
ENGINE = ReplicatedSummingMergeTree
PARTITION BY toYYYYMM(toStartOfMinute(event_time))
ORDER BY (toStartOfMinute(event_time), event_type)
AS SELECT
    toStartOfMinute(event_time) as minute,
    event_type,
    sum(event_value) as total_value,
    count() as event_count
FROM realtime.optimized_events
GROUP BY minute, event_type;

-- 去重表
CREATE TABLE IF NOT EXISTS realtime.optimized_events_dedup ON CLUSTER 'treasurycluster' (
    event_id String,
    processed_at DateTime DEFAULT now()
) ENGINE = ReplicatedMergeTree
ORDER BY event_id
TTL processed_at + INTERVAL 1 HOUR
SETTINGS index_granularity = 8192;
```

### 完整写入流程（Python）

```python
import time
import clickhouse_driver

class OptimizedRealtimeWriter:
    def __init__(self):
        self.client = clickhouse_driver.Client(
            host='localhost',
            port=9000,
            settings={
                'async_insert': 1,
                'wait_for_async_insert': 0
            }
        )

    def write_event(self, event_data):
        """
        优化的实时事件写入
        延迟：< 10ms
        """
        event_id = event_data['event_id']
        version = int(time.time() * 1000000)

        # 1. 检查是否已处理（快速路径：缓存）
        result = self.client.execute(
            'SELECT count() FROM realtime.optimized_events_dedup WHERE event_id = %(event_id)s',
            {'event_id': event_id}
        )

        if result[0][0] > 0:
            return False

        try:
            # 2. 写入 Buffer 表（极快）
            self.client.execute(
                'INSERT INTO realtime.buffer_optimized_events VALUES',
                [(
                    event_id,
                    event_data['user_id'],
                    event_data['event_type'],
                    event_data['event_data'],
                    event_data.get('event_value', 0),
                    event_data['event_time'],
                    version,
                    time.time()
                )],
                settings={'wait_for_async_insert': 0}
            )

            # 3. 插入去重表
            self.client.execute(
                'INSERT INTO realtime.optimized_events_dedup VALUES',
                [(event_id, time.time())]
            )

            return True

        except Exception as e:
            # 4. 发生错误，删除去重记录
            self.client.execute(
                'DELETE FROM realtime.optimized_events_dedup WHERE event_id = %(event_id)s',
                {'event_id': event_id}
            )
            raise

    def batch_write_events(self, events):
        """
        批量写入（性能最佳）
        """
        version = int(time.time() * 1000000)

        # 1. 批量检查去重
        event_ids = [e['event_id'] for e in events]
        result = self.client.execute(
            f'SELECT event_id FROM realtime.optimized_events_dedup WHERE event_id IN ({",".join(["%s"] * len(event_ids))})',
            event_ids
        )

        existing_ids = {row[0] for row in result}

        # 2. 过滤已存在的事件
        new_events = [e for e in events if e['event_id'] not in existing_ids]

        if not new_events:
            return 0

        try:
            # 3. 批量写入 Buffer 表
            self.client.execute(
                'INSERT INTO realtime.buffer_optimized_events VALUES',
                [[
                    e['event_id'],
                    e['user_id'],
                    e['event_type'],
                    e['event_data'],
                    e.get('event_value', 0),
                    e['event_time'],
                    version,
                    time.time()
                ] for e in new_events],
                settings={'wait_for_async_insert': 0}
            )

            # 4. 批量插入去重表
            self.client.execute(
                'INSERT INTO realtime.optimized_events_dedup VALUES',
                [[e['event_id'], time.time()] for e in new_events]
            )

            return len(new_events)

        except Exception as e:
            # 5. 发生错误，删除去重记录
            self.client.execute(
                f'DELETE FROM realtime.optimized_events_dedup WHERE event_id IN ({",".join(["%s"] * len(event_ids))})',
                event_ids
            )
            raise

# 使用示例
writer = OptimizedRealtimeWriter()

# 场景 1：单条高频写入
for i in range(1000):
    event = {
        'event_id': f'opt-evt-{int(time.time() * 1000000)}-{i}',
        'user_id': (i % 100) + 1,
        'event_type': ['click', 'view', 'purchase'][i % 3],
        'event_data': f'{{"page":"/page-{i}"}}',
        'event_value': (i % 100) + 1,
        'event_time': time.time()
    }
    writer.write_event(event)

# 场景 2：批量写入
events = [
    {
        'event_id': f'batch-evt-{int(time.time() * 1000000)}-{i}',
        'user_id': (i % 100) + 1,
        'event_type': ['click', 'view', 'purchase'][i % 3],
        'event_data': f'{{"page":"/page-{i}"}}',
        'event_value': (i % 100) + 1,
        'event_time': time.time()
    }
    for i in range(1000)
]
writer.batch_write_events(events)
```

### 查询方式

```sql
-- 方式 1：使用 Projection 查询用户统计（< 20ms）
SELECT
    user_id,
    total_value,
    event_count,
    first_event_time,
    last_event_time
FROM realtime.optimized_events
WHERE user_id IN (1001, 1002, 1003);

-- 方式 2：使用 Projection 查询类型统计（< 20ms）
SELECT
    event_type,
    total_value,
    event_count
FROM realtime.optimized_events
WHERE event_type IN ('click', 'view', 'purchase');

-- 方式 3：查询 1 分钟聚合（< 10ms）
SELECT
    minute,
    event_type,
    total_value,
    event_count
FROM realtime.optimized_events_1min_mv
WHERE minute >= now() - INTERVAL 1 HOUR
ORDER BY minute;

-- 方式 4：查询原始数据（< 50ms）
SELECT * FROM realtime.optimized_events
WHERE user_id = 1001
  AND event_time >= now() - INTERVAL 1 HOUR
ORDER BY event_time DESC
LIMIT 100;
```

---

## 性能对比

| 场景 | 写入延迟 | 查询延迟 | 吞吐量 | 配置复杂度 |
|------|----------|----------|--------|-----------|
| **Buffer 表** | < 10ms | < 100ms | 100万/秒 | ⭐⭐ |
| **异步插入** | < 5ms | < 50ms | 200万/秒 | ⭐ |
| **物化视图** | < 50ms | < 10ms | 50万/秒 | ⭐⭐ |
| **Projection** | < 50ms | < 20ms | 80万/秒 | ⭐⭐⭐ |
| **综合方案** | < 10ms | < 20ms | 150万/秒 | ⭐⭐⭐⭐ |

---

## 监控和调优

### 1. 监控写入性能

```sql
-- 查看异步插入统计
SELECT
    metric,
    value,
    description
FROM system.asynchronous_metrics
WHERE metric LIKE '%AsyncInsert%'
ORDER BY metric;

-- 查看写入延迟
SELECT
    table,
    formatReadableSize(bytes_written) as bytes_written,
    rows_written,
    write_duration_ms / rows_written as avg_write_latency_ms
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query LIKE '%INSERT%'
  AND event_date >= today() - INTERVAL 1 DAY
GROUP BY table
ORDER BY avg_write_latency_ms;

-- 查看 Buffer 表状态
SELECT
    database,
    table,
    formatReadableSize(bytes) as size,
    rows,
    min_time,
    max_time
FROM system.buffers
WHERE database = 'realtime';
```

### 2. 监控查询性能

```sql
-- 查看查询延迟分布
SELECT
    quantile(0.50)(query_duration_ms) as p50,
    quantile(0.95)(query_duration_ms) as p95,
    quantile(0.99)(query_duration_ms) as p99,
    count() as total_queries
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today() - INTERVAL 1 DAY;

-- 查看 Projection 使用情况
SELECT
    table,
    name,
    formatReadableSize(bytes_on_disk) as size,
    rows,
    used_count,
    used_count / (rows + 1) as usage_ratio
FROM system.projections
WHERE database = 'realtime'
ORDER BY usage_ratio DESC;

-- 查看物化视图状态
SELECT
    table,
    sum(rows) as total_rows,
    formatReadableSize(sum(bytes_on_disk)) as total_size
FROM system.parts
WHERE database = 'realtime'
  AND active
  AND table LIKE '%mv'
GROUP BY table;
```

### 3. 性能调优

```sql
-- 调整异步插入参数
SET SETTINGS async_insert = 1,
           async_insert_max_data_size = 2097152,  -- 增加到 2MB
           async_insert_busy_timeout_ms = 50,       -- 减少到 50ms
           wait_for_async_insert = 0;

-- 调整 Buffer 表参数
ALTER TABLE realtime.buffer_optimized_events
MODIFY SETTING num_buckets = 32,         -- 增加到 32（更多 CPU 核心）
               max_rows = 500,             -- 增加到 500
               min_time = 3,               -- 减少到 3 秒
               max_time = 30;              -- 减少到 30 秒

-- 调整索引粒度
ALTER TABLE realtime.optimized_events
MODIFY SETTING index_granularity = 4096;  -- 减少到 4096（更细粒度）
```

---

## 最佳实践总结

### 1. 写入优化

- ✅ 使用 Buffer 表或异步插入降低写入延迟
- ✅ 批量写入优于单条写入
- ✅ 合理配置去重表 TTL
- ✅ 监控写入延迟和吞吐量

### 2. 查询优化

- ✅ 使用 Projection 加速高频聚合查询
- ✅ 使用物化视图预计算常用聚合
- ✅ 避免 FINAL 查询（性能差）
- ✅ 合理设计 ORDER BY 和 PARTITION BY

### 3. 去重策略

- ✅ ReplacingMergeTree + version（简单场景）
- ✅ 应用层去重表（高准确性要求）
- ✅ 异步插入 + 去重表（实时场景）
- ✅ 定期清理去重表（设置 TTL）

### 4. 综合方案

**推荐配置**（实时性要求极高的场景）：

```sql
CREATE TABLE realtime_events (
    event_id String,
    user_id UInt64,
    event_time DateTime,
    version UInt64
) ENGINE = ReplicatedReplacingMergeTree(version)
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_id, event_time)
SETTINGS async_insert = 1,
           wait_for_async_insert = 0
PROJECTION user_stats (SELECT user_id, count() as cnt GROUP BY user_id);
```

**配合**：
- Buffer 表（写入缓冲）
- 物化视图（实时聚合）
- 去重表（幂等性保证）

---

## 总结

### 核心原则

1. **写入优化**：Buffer 表 + 异步插入
2. **查询优化**：Projection + 物化视图
3. **去重策略**：ReplacingMergeTree + 应用层去重
4. **监控调优**：持续监控延迟和吞吐量

### 方案选择

| 需求 | 推荐方案 |
|------|----------|
| 极低写入延迟 | Buffer 表 |
| 高并发写入 | 异步插入 |
| 实时聚合 | 物化视图 |
| 快速聚合查询 | Projection |
| 综合最优 | 综合方案 |

**最佳实践**：Buffer 表 + 异步插入 + Projection + 物化视图 + 去重表 = 完美组合！
