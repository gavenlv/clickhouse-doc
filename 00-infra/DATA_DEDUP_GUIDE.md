# ClickHouse 数据去重与幂等性指南

## 问题背景

**场景**：上游数据写入 ClickHouse 时，如果写到一半程序崩溃或网络中断，如何保证数据不重复？

**核心问题**：
1. **幂等性**：同一条数据重复写入多次，最终结果应该只保留一份
2. **原子性**：部分写入不应该导致数据不一致
3. **重试安全**：程序可以安全地重试写入操作，而不会产生重复数据

## 解决方案总览

| 方案 | 适用场景 | 引擎 | 难度 | 性能 |
|------|----------|------|------|------|
| **ReplacingMergeTree** | 需要保留最新版本 | ReplicatedReplacingMergeTree | ⭐⭐ | ⭐⭐⭐⭐ |
| **CollapsingMergeTree** | 增量更新（增删改） | ReplicatedCollapsingMergeTree | ⭐⭐⭐ | ⭐⭐⭐⭐ |
| **VersionedCollapsingMergeTree** | 严格版本控制 | ReplicatedVersionedCollapsingMergeTree | ⭐⭐⭐⭐ | ⭐⭐⭐ |
| **INSERT SELECT DISTINCT** | 临时去重 | 任意引擎 | ⭐ | ⭐⭐ |
| **应用层去重** | 可控写入 | 任意引擎 | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ |

---

## 方案 1：ReplacingMergeTree（推荐用于大多数场景）

### 原理

ReplacingMergeTree 会保留相同 ORDER BY 键中版本号最大的记录。在合并时自动去重。

### 表结构

```sql
-- 生产环境：使用复制版本 + ON CLUSTER
CREATE TABLE IF NOT EXISTS production.user_events ON CLUSTER 'treasurycluster' (
    user_id UInt64,
    event_id UInt64,           -- 业务唯一ID
    event_type String,
    event_data String,
    event_time DateTime,
    version UInt64,            -- 版本号（必需）
    inserted_at DateTime DEFAULT now()
) ENGINE = ReplicatedReplacingMergeTree(version)  -- version 指定去重字段
PARTITION BY toYYYYMM(event_time)
ORDER BY (user_id, event_id)  -- 唯一键
SETTINGS index_granularity = 8192;
```

### 写入方式

```sql
-- 方式1：直接插入（推荐）
-- 使用唯一ID + version 保证幂等性
INSERT INTO production.user_events VALUES
(1001, 'evt-001', 'click', '{"page":"/home"}', '2024-01-01 10:00:00', 1, now());

-- 如果程序崩溃，重试时使用相同的 event_id + version
INSERT INTO production.user_events VALUES
(1001, 'evt-001', 'click', '{"page":"/home"}', '2024-01-01 10:00:00', 1, now());
-- 重复数据会被自动去重

-- 方式2：使用 INSERT SELECT DISTINCT（临时表）
CREATE TEMPORARY TABLE temp_events AS production.user_events;

INSERT INTO temp_events VALUES
(1001, 'evt-001', 'click', '{"page":"/home"}', '2024-01-01 10:00:00', 1, now()),
(1001, 'evt-001', 'click', '{"page":"/home"}', '2024-01-01 10:00:00', 1, now());  -- 重复
(1001, 'evt-002', 'view', '{"page":"/about"}', '2024-01-01 10:01:00', 1, now());

-- 去重后再插入目标表
INSERT INTO production.user_events
SELECT DISTINCT * FROM temp_events;
```

### 查询方式

```sql
-- 方式1：使用 FINAL 关键字（实时去重，但性能较差）
SELECT * FROM production.user_events
WHERE user_id = 1001
FINAL  -- 强制在查询时合并去重
ORDER BY event_time;

-- 方式2：手动触发合并（推荐用于批量场景）
OPTIMIZE TABLE production.user_events FINAL;

-- 然后正常查询
SELECT * FROM production.user_events
WHERE user_id = 1001
ORDER BY event_time;

-- 方式3：使用 GROUP BY 手动去重（性能最佳）
SELECT
    user_id,
    argMax(event_id, version) as event_id,
    argMax(event_type, version) as event_type,
    argMax(event_data, version) as event_data,
    argMax(event_time, version) as event_time,
    max(version) as version,
    argMax(inserted_at, version) as inserted_at
FROM production.user_events
WHERE user_id = 1001
GROUP BY user_id
ORDER BY event_time;
```

### 优缺点

**优点**：
- ✅ 简单易用，只需添加 version 字段
- ✅ 自动去重，无需应用层处理
- ✅ 保留最新版本
- ✅ 支持定期合并，查询性能好

**缺点**：
- ❌ 合并是异步的，查询时可能看到重复数据
- ❌ 使用 FINAL 查询性能较差
- ❌ 需要定期 OPTIMIZE

**适用场景**：
- ✅ 用户资料更新
- ✅ 配置信息更新
- ✅ 状态变更日志
- ✅ 事件数据（可容忍短时间重复）

---

## 方案 2：CollapsingMergeTree（适合增量更新）

### 原理

使用 sign 字段标记记录的增删：+1 表示新增，-1 表示删除。相同 ORDER BY 键的记录会相互抵消。

### 表结构

```sql
-- 生产环境：使用复制版本 + ON CLUSTER
CREATE TABLE IF NOT EXISTS production.user_states ON CLUSTER 'treasurycluster' (
    user_id UInt64,
    state String,
    sign Int8,           -- 1 for insert, -1 for delete（必需）
    timestamp DateTime,
    inserted_at DateTime DEFAULT now()
) ENGINE = ReplicatedCollapsingMergeTree(sign)  -- sign 指定字段
PARTITION BY toYYYYMM(timestamp)
ORDER BY user_id
SETTINGS index_granularity = 8192;
```

### 写入方式

```sql
-- 插入用户状态
INSERT INTO production.user_states VALUES
(1001, 'online', 1, '2024-01-01 10:00:00', now()),
(1002, 'offline', 1, '2024-01-01 10:00:00', now());

-- 更新用户状态（先删除旧状态，再插入新状态）
-- 方式1：事务式写入（推荐）
-- 如果程序崩溃，重试时重新执行整个操作
BEGIN TRANSACTION;

-- 删除旧状态
INSERT INTO production.user_states VALUES
(1001, 'online', -1, '2024-01-01 10:00:00', now());

-- 插入新状态
INSERT INTO production.user_states VALUES
(1001, 'busy', 1, '2024-01-01 10:30:00', now());

COMMIT;

-- 方式2：幂等性写入
-- 每次更新都使用新的时间戳
INSERT INTO production.user_states VALUES
(1001, 'online', -1, '2024-01-01 10:00:00', now()),
(1001, 'busy', 1, '2024-01-01 10:30:00', now());

-- 即使重复执行多次，结果也正确
-- 因为相同时间戳的记录会被抵消
```

### 查询方式

```sql
-- 查询当前状态（使用 GROUP BY 抵消 sign）
SELECT
    user_id,
    argMax(state, timestamp) as current_state,
    max(timestamp) as last_updated
FROM production.user_states
WHERE user_id = 1001
GROUP BY user_id;

-- 或者使用 FINAL（性能较差）
SELECT * FROM production.user_states
WHERE user_id = 1001
FINAL;

-- 手动触发合并后查询
OPTIMIZE TABLE production.user_states FINAL;
SELECT * FROM production.user_states
WHERE user_id = 1001;
```

### 优缺点

**优点**：
- ✅ 支持增量更新（增删改）
- ✅ 适合库存管理、订单状态等场景
- ✅ 可以精确控制数据的增删

**缺点**：
- ❌ 需要正确管理 sign 字段
- ❌ 应用层逻辑复杂
- ❌ 合并是异步的

**适用场景**：
- ✅ 库存管理
- ✅ 订单状态跟踪
- ✅ 增量计数器
- ✅ 需要精确控制增删的场景

---

## 方案 3：VersionedCollapsingMergeTree（严格版本控制）

### 原理

在 CollapsingMergeTree 基础上增加 version 字段，只有相同 version 的记录才会相互抵消。

### 表结构

```sql
-- 生产环境：使用复制版本 + ON CLUSTER
CREATE TABLE IF NOT EXISTS production.inventory ON CLUSTER 'treasurycluster' (
    product_id UInt64,
    quantity Int32,
    sign Int8,            -- 1 for insert, -1 for delete（必需）
    version UInt64,       -- 版本号（必需）
    timestamp DateTime,
    inserted_at DateTime DEFAULT now()
) ENGINE = ReplicatedVersionedCollapsingMergeTree(sign, version)
PARTITION BY toYYYYMM(timestamp)
ORDER BY product_id
SETTINGS index_granularity = 8192;
```

### 写入方式

```sql
-- 初始化库存（version 1）
INSERT INTO production.inventory VALUES
(101, 100, 1, 1, '2024-01-01 10:00:00', now()),
(102, 50, 1, 1, '2024-01-01 10:00:00', now());

-- 更新库存（version 2）
-- 删除旧版本（version 1），插入新版本（version 2）
INSERT INTO production.inventory VALUES
(101, -100, -1, 1, '2024-01-01 10:00:00', now()),  -- 删除 version 1
(101, 95, 1, 2, '2024-01-01 11:00:00', now());     -- 插入 version 2

-- 即使重复执行整个操作，结果也正确
-- 因为 version 1 已经被删除，再次删除不会产生影响
```

### 查询方式

```sql
-- 查询当前库存
SELECT
    product_id,
    sum(quantity * sign) as current_inventory,
    max(version) as latest_version,
    max(timestamp) as last_updated
FROM production.inventory
GROUP BY product_id;

-- 使用 FINAL
SELECT * FROM production.inventory FINAL;

-- 手动合并
OPTIMIZE TABLE production.inventory FINAL;
```

### 优缺点

**优点**：
- ✅ 严格版本控制，不会误删除
- ✅ 支持并发更新
- ✅ 数据一致性最强

**缺点**：
- ❌ 实现最复杂
- ❌ 需要管理 version
- ❌ 合并是异步的

**适用场景**：
- ✅ 金融交易记录
- ✅ 库存精确管理
- ✅ 需要严格版本控制的场景

---

## 方案 4：应用层去重（最灵活）

### 原理

在应用层使用唯一ID或数据库（如 MySQL/PostgreSQL）维护去重表。

### 表结构

```sql
-- ClickHouse 目标表
CREATE TABLE IF NOT EXISTS production.events ON CLUSTER 'treasurycluster' (
    event_id String,        -- 唯一ID（应用层保证）
    user_id UInt64,
    event_type String,
    event_data String,
    event_time DateTime
) ENGINE = ReplicatedMergeTree
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_id, event_time)
SETTINGS index_granularity = 8192;

-- ClickHouse 去重表（可选）
CREATE TABLE IF NOT EXISTS production.event_dedup ON CLUSTER 'treasurycluster' (
    event_id String,
    processed_at DateTime DEFAULT now()
) ENGINE = ReplicatedMergeTree
ORDER BY event_id
SETTINGS index_granularity = 8192;
```

### 写入流程

```python
# Python 示例：使用 Redis 去重
import redis
import clickhouse_driver

# 连接 Redis（去重缓存）
redis_client = redis.Redis(host='localhost', port=6379, db=0)

# 连接 ClickHouse
clickhouse_client = clickhouse_driver.Client(host='localhost', port=9000)

def insert_event_with_dedup(event_data):
    """
    带去重的事件插入
    """
    event_id = event_data['event_id']
    dedup_key = f"event:{event_id}"

    # 1. 检查是否已处理
    if redis_client.exists(dedup_key):
        print(f"Event {event_id} already processed, skipping")
        return

    # 2. 使用 Redis SET NX 实现原子性去重
    acquired = redis_client.set(dedup_key, '1', nx=True, ex=86400)  # 1天过期

    if not acquired:
        print(f"Event {event_id} is being processed by another process")
        return

    try:
        # 3. 插入 ClickHouse
        clickhouse_client.execute(
            'INSERT INTO production.events VALUES',
            [(
                event_data['event_id'],
                event_data['user_id'],
                event_data['event_type'],
                event_data['event_data'],
                event_data['event_time']
            )]
        )

        print(f"Event {event_id} inserted successfully")

    except Exception as e:
        # 4. 发生错误，删除 Redis 标记（允许重试）
        redis_client.delete(dedup_key)
        print(f"Failed to insert event {event_id}: {e}")
        raise

# 使用示例
events = [
    {
        'event_id': 'evt-001',
        'user_id': 1001,
        'event_type': 'click',
        'event_data': '{"page":"/home"}',
        'event_time': '2024-01-01 10:00:00'
    },
    {
        'event_id': 'evt-002',
        'user_id': 1001,
        'event_type': 'view',
        'event_data': '{"page":"/about"}',
        'event_time': '2024-01-01 10:01:00'
    }
]

for event in events:
    insert_event_with_dedup(event)

# 即使重复执行，也不会产生重复数据
for event in events:
    insert_event_with_dedup(event)
```

### 优缺点

**优点**：
- ✅ 完全控制去重逻辑
- ✅ 可以实现精确的幂等性
- ✅ 查询性能最佳（无需 FINAL）
- ✅ 可以配合其他去重机制

**缺点**：
- ❌ 需要额外的去重存储（Redis/MySQL）
- ❌ 实现复杂度高
- ❌ 需要维护去重表

**适用场景**：
- ✅ 对数据准确性要求极高的场景
- ✅ 金融交易
- ✅ 需要精确控制重复的场景

---

## 方案 5：ClickHouse 内置去重（实验性）

### 使用 insert_deduplication_token

ClickHouse 22.3+ 支持 `insert_deduplication_token`：

```sql
-- 插入时指定去重令牌
INSERT INTO production.events SETTINGS insert_deduplication_token='batch-001' VALUES
('evt-001', 1001, 'click', '{"page":"/home"}', '2024-01-01 10:00:00'),
('evt-002', 1001, 'view', '{"page":"/about"}', '2024-01-01 10:01:00');

-- 如果重试时使用相同的 token，重复数据会被去重
INSERT INTO production.events SETTINGS insert_deduplication_token='batch-001' VALUES
('evt-001', 1001, 'click', '{"page":"/home"}', '2024-01-01 10:00:00'),  -- 重复
('evt-002', 1001, 'view', '{"page":"/about"}', '2024-01-01 10:01:00');  -- 重复
```

### 优缺点

**优点**：
- ✅ 无需修改表结构
- ✅ 使用简单

**缺点**：
- ❌ 较新的特性，可能不稳定
- ❌ Token 只在短时间内有效
- ❌ 不适用于所有场景

---

## 最佳实践总结

### 1. 选择合适的方案

| 场景 | 推荐方案 |
|------|----------|
| 用户资料、配置信息 | ReplacingMergeTree |
| 库存管理、订单状态 | CollapsingMergeTree |
| 金融交易、精确版本控制 | VersionedCollapsingMergeTree |
| 普通事件日志 | ReplacingMergeTree + 应用层去重 |
| 高准确性要求 | 应用层去重 + 数据库去重表 |

### 2. 写入策略

```sql
-- ✅ 推荐：批量插入 + 幂等性设计
INSERT INTO production.events VALUES
(...),
(...),
(...);

-- ✅ 推荐：使用临时表去重
CREATE TEMPORARY TABLE temp_events AS production.events;
INSERT INTO temp_events VALUES (..., ..., ...);  -- 可能包含重复
INSERT INTO production.events SELECT DISTINCT * FROM temp_events;

-- ❌ 避免：单条插入
INSERT INTO production.events VALUES (...);  -- 性能差
```

### 3. 查询策略

```sql
-- ✅ 推荐：使用 GROUP BY 手动去重
SELECT
    user_id,
    argMax(event_data, version) as latest_data
FROM production.user_events
GROUP BY user_id;

-- ⚠️  谨慎使用：FINAL（性能较差）
SELECT * FROM production.user_events FINAL;

-- ✅ 推荐：定期 OPTIMIZE
OPTIMIZE TABLE production.user_events FINAL;
-- 然后正常查询
SELECT * FROM production.user_events;
```

### 4. 监控和维护

```sql
-- 监控去重效果
SELECT
    count() as total_rows,
    uniqExact(event_id) as unique_events,
    count() - uniqExact(event_id) as duplicate_count
FROM production.user_events;

-- 定期 OPTIMIZE（低峰期执行）
OPTIMIZE TABLE production.user_events PARTITION '202401' FINAL;

-- 查看分区大小和重复率
SELECT
    partition,
    sum(rows) as total_rows,
    sum(bytes_on_disk) as total_bytes,
    formatReadableSize(sum(bytes_on_disk)) as readable_size
FROM system.parts
WHERE table = 'user_events'
  AND active
GROUP BY partition;
```

---

## 完整示例：电商平台订单处理

### 表设计

```sql
-- 订单主表（使用 ReplacingMergeTree）
CREATE TABLE IF NOT EXISTS ecommerce.orders ON CLUSTER 'treasurycluster' (
    order_id String,
    user_id UInt64,
    order_status Enum8('pending' = 0, 'paid' = 1, 'shipped' = 2, 'completed' = 3, 'cancelled' = 4),
    amount Decimal(10, 2),
    created_at DateTime,
    updated_at DateTime DEFAULT now(),
    version UInt64,
    inserted_at DateTime DEFAULT now()
) ENGINE = ReplicatedReplacingMergeTree(version)
PARTITION BY toYYYYMM(created_at)
ORDER BY (order_id)
SETTINGS index_granularity = 8192;

-- 订单明细表（使用 CollapsingMergeTree）
CREATE TABLE IF NOT EXISTS ecommerce.order_items ON CLUSTER 'treasurycluster' (
    order_id String,
    product_id UInt64,
    quantity Int32,
    price Decimal(10, 2),
    sign Int8,
    version UInt64,
    timestamp DateTime,
    inserted_at DateTime DEFAULT now()
) ENGINE = ReplicatedVersionedCollapsingMergeTree(sign, version)
PARTITION BY toYYYYMM(timestamp)
ORDER BY (order_id, product_id)
SETTINGS index_granularity = 8192;

-- 去重表（可选）
CREATE TABLE IF NOT EXISTS ecommerce.order_dedup ON CLUSTER 'treasurycluster' (
    order_id String,
    processed_at DateTime DEFAULT now()
) ENGINE = ReplicatedMergeTree
ORDER BY order_id
SETTINGS index_granularity = 8192;
```

### 写入流程（Python）

```python
import time
import uuid
from datetime import datetime
import clickhouse_driver

class OrderService:
    def __init__(self):
        self.client = clickhouse_driver.Client(host='localhost', port=9000)

    def create_order(self, order_data):
        """
        创建订单（幂等性保证）
        """
        order_id = order_data['order_id']
        version = int(time.time() * 1000000)  # 微秒级时间戳

        # 1. 检查订单是否已存在
        existing = self.client.execute(
            'SELECT count() FROM ecommerce.order_dedup WHERE order_id = %(order_id)s',
            {'order_id': order_id}
        )

        if existing[0][0] > 0:
            print(f"Order {order_id} already exists, skipping")
            return

        try:
            # 2. 插入订单主表
            self.client.execute(
                'INSERT INTO ecommerce.orders VALUES',
                [(
                    order_id,
                    order_data['user_id'],
                    order_data['order_status'],
                    order_data['amount'],
                    order_data['created_at'],
                    datetime.now(),
                    version,
                    datetime.now()
                )]
            )

            # 3. 插入订单明细（使用 CollapsingMergeTree）
            for item in order_data['items']:
                self.client.execute(
                    'INSERT INTO ecommerce.order_items VALUES',
                    [(
                        order_id,
                        item['product_id'],
                        item['quantity'],
                        item['price'],
                        1,  # sign = 1 (insert)
                        version,
                        datetime.now(),
                        datetime.now()
                    )]
                )

            # 4. 插入去重表
            self.client.execute(
                'INSERT INTO ecommerce.order_dedup VALUES',
                [(order_id, datetime.now())]
            )

            print(f"Order {order_id} created successfully")

        except Exception as e:
            # 发生错误，自动删除去重记录（允许重试）
            self.client.execute(
                'DELETE FROM ecommerce.order_dedup WHERE order_id = %(order_id)s',
                {'order_id': order_id}
            )
            print(f"Failed to create order {order_id}: {e}")
            raise

# 使用示例
service = OrderService()

# 第一次执行
order = {
    'order_id': f"ORD-{uuid.uuid4()}",
    'user_id': 1001,
    'order_status': 'paid',
    'amount': 299.99,
    'created_at': datetime.now(),
    'items': [
        {'product_id': 101, 'quantity': 1, 'price': 199.99},
        {'product_id': 102, 'quantity': 2, 'price': 50.00}
    ]
}
service.create_order(order)

# 重试执行（幂等性保证，不会产生重复数据）
service.create_order(order)
```

### 查询示例

```sql
-- 查询订单最新状态（使用 argMax）
SELECT
    order_id,
    user_id,
    argMax(order_status, version) as order_status,
    argMax(amount, version) as amount,
    max(version) as latest_version,
    argMax(updated_at, version) as updated_at
FROM ecommerce.orders
WHERE order_id = 'ORD-xxx'
GROUP BY order_id, user_id;

-- 查询订单明细（使用 sum 抵消 sign）
SELECT
    order_id,
    product_id,
    sum(quantity * sign) as quantity,
    argMax(price, version) as price,
    max(version) as latest_version
FROM ecommerce.order_items
WHERE order_id = 'ORD-xxx'
GROUP BY order_id, product_id;

-- 使用 FINAL 查询
SELECT * FROM ecommerce.orders
WHERE order_id = 'ORD-xxx'
FINAL;
```

---

## 常见问题 FAQ

### Q1: ReplacingMergeTree 什么时候会合并？

**A**: 合并在以下情况自动触发：
1. 后台合并任务（默认每 10 秒触发一次）
2. 手动执行 `OPTIMIZE TABLE ... FINAL`
3. 分区插入后自动合并

**建议**：低峰期定期执行 `OPTIMIZE TABLE ... FINAL`

### Q2: 为什么使用 FINAL 查询很慢？

**A**: FINAL 会：
1. 读取所有相关数据块
2. 在内存中执行合并去重
3. 返回合并后的结果

**建议**：
- 非实时场景：定期 `OPTIMIZE`，然后正常查询
- 实时场景：使用 `GROUP BY` + `argMax` 手动去重

### Q3: 如何处理并发更新？

**A**: 使用 VersionedCollapsingMergeTree：
1. 每次更新使用新的 version
2. 并发更新不会相互覆盖
3. 最终会保留所有版本

### Q4: 去重表会无限增长吗？

**A**: 不会，可以设置 TTL：

```sql
CREATE TABLE IF NOT EXISTS production.event_dedup ON CLUSTER 'treasurycluster' (
    event_id String,
    processed_at DateTime DEFAULT now()
) ENGINE = ReplicatedMergeTree
ORDER BY event_id
TTL processed_at + INTERVAL 7 DAY  -- 7天后自动删除
SETTINGS index_granularity = 8192;
```

### Q5: 如何监控去重效果？

**A**:

```sql
-- 统计重复率
SELECT
    table,
    sum(rows) as total_rows,
    sum(rows_uncompressed) as total_bytes,
    formatReadableSize(sum(rows_uncompressed)) as readable_size
FROM system.parts
WHERE active
  AND table IN ('user_events', 'order_items')
GROUP BY table;

-- 查看未合并的数据块
SELECT
    table,
    partition,
    count() as part_count,
    sum(rows) as total_rows
FROM system.parts
WHERE active
  AND level > 0  -- level > 0 表示有未合并的数据块
GROUP BY table, partition;
```

---

## 总结

### 核心原则

1. **设计唯一键**：每条数据必须有唯一标识
2. **使用合适引擎**：根据场景选择 ReplacingMergeTree、CollapsingMergeTree 等
3. **应用层去重**：对于高准确性要求，配合 Redis/MySQL 去重
4. **定期 OPTIMIZE**：低峰期触发合并，提升查询性能
5. **监控去重效果**：及时发现异常

### 方案选择速查表

| 需求 | 推荐方案 | 复杂度 | 性能 |
|------|----------|--------|------|
| 最简单去重 | ReplacingMergeTree | ⭐⭐ | ⭐⭐⭐⭐ |
| 增量更新 | CollapsingMergeTree | ⭐⭐⭐ | ⭐⭐⭐⭐ |
| 严格版本控制 | VersionedCollapsingMergeTree | ⭐⭐⭐⭐ | ⭐⭐⭐ |
| 最高准确性 | 应用层去重 + 数据库 | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ |

### 生产环境建议

```sql
-- 标准生产表结构（推荐）
CREATE TABLE IF NOT EXISTS production.events ON CLUSTER 'treasurycluster' (
    event_id String,        -- 业务唯一ID
    user_id UInt64,
    event_type String,
    event_data String,
    event_time DateTime,
    version UInt64,         -- 版本号
    inserted_at DateTime DEFAULT now()
) ENGINE = ReplicatedReplacingMergeTree(version)
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_id, event_time)
SETTINGS index_granularity = 8192;

-- 配合应用层去重
CREATE TABLE IF NOT EXISTS production.event_dedup ON CLUSTER 'treasurycluster' (
    event_id String,
    processed_at DateTime DEFAULT now()
) ENGINE = ReplicatedMergeTree
ORDER BY event_id
TTL processed_at + INTERVAL 7 DAY
SETTINGS index_granularity = 8192;
```

**最佳实践**：引擎去重 + 应用层去重 = 双重保障，确保数据不重复！
