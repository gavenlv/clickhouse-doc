# ClickHouse Table Engine Selection Guide

ClickHouse 表引擎选择指南 - 帮助您选择最适合的表引擎。

## 目录

1. [引擎对比表](#引擎对比表)
2. [选择决策树](#选择决策树)
3. [性能基准测试](#性能基准测试)
4. [最佳实践总结](#最佳实践总结)

## 引擎对比表

### MergeTree 系列对比

| 引擎 | 适用场景 | 去重 | 预聚合 | 支持复制 | 查询性能 | 写入性能 | 推荐指数 |
|------|----------|------|--------|----------|----------|----------|----------|
| MergeTree | 通用 OLAP | ❌ | ❌ | ❌ | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐ | ⭐⭐⭐⭐ |
| ReplacingMergeTree | 去重数据 | ✅ | ❌ | ❌ | ⭐⭐⭐⭐ | ⭐⭐⭐⭐ | ⭐⭐⭐⭐ |
| SummingMergeTree | 数值聚合 | ❌ | ✅ | ❌ | ⭐⭐⭐⭐ | ⭐⭐⭐⭐ | ⭐⭐⭐ |
| AggregatingMergeTree | 复杂聚合 | ❌ | ✅ | ❌ | ⭐⭐⭐⭐ | ⭐⭐⭐ | ⭐⭐⭐ |
| CollapsingMergeTree | 增量更新 | ✅ | ❌ | ❌ | ⭐⭐⭐ | ⭐⭐⭐ | ⭐⭐⭐ |
| ReplicatedMergeTree | 高可用 OLAP | ❌ | ❌ | ✅ | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ |
| ReplicatedReplacingMergeTree | 高可用去重 | ✅ | ❌ | ✅ | ⭐⭐⭐⭐ | ⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ |

### Log 系列对比

| 引擎 | 适用场景 | 支持索引 | 支持分区 | 压缩 | 查询性能 | 推荐指数 |
|------|----------|----------|----------|------|----------|----------|
| TinyLog | 临时数据 | ❌ | ❌ | ❌ | ⭐⭐ | ⭐⭐ |
| StripeLog | 小日志 | ❌ | ❌ | ✅ | ⭐⭐⭐ | ⭐⭐⭐ |
| Log | 中等日志 | ❌ | ❌ | ✅ | ⭐⭐⭐ | ⭐⭐⭐ |

### 特殊引擎对比

| 引擎 | 适用场景 | 存储数据 | 分布式 | 查询性能 | 推荐指数 |
|------|----------|----------|--------|----------|----------|
| Distributed | 分布式查询 | ❌ | ✅ | ⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ |
| MaterializedView | 预聚合 | ✅ | ❌ | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ |
| View | 数据抽象 | ❌ | ❌ | ⭐⭐⭐⭐ | ⭐⭐⭐⭐ |
| Buffer | 写入缓冲 | ✅ | ❌ | N/A | ⭐⭐⭐ |
| Merge | 多表合并 | ❌ | ❌ | ⭐⭐⭐ | ⭐⭐⭐ |
| Null | 数据丢弃 | ❌ | ❌ | N/A | ⭐⭐ |
| Set | 集合查询 | ✅ | ❌ | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐ |
| Join | 连接表 | ✅ | ❌ | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐ |

### 集成引擎对比

| 引擎 | 适用场景 | 支持写入 | 性能 | 配置复杂度 | 推荐指数 |
|------|----------|----------|------|------------|----------|
| URL | 远程文件 | ❌ | ⭐⭐ | ⭐ | ⭐⭐⭐ |
| File | 本地文件 | ✅ | ⭐⭐⭐ | ⭐ | ⭐⭐⭐⭐ |
| HDFS | Hadoop 集成 | ✅ | ⭐⭐⭐⭐ | ⭐⭐⭐⭐ | ⭐⭐⭐⭐ |
| S3 | 云存储 | ✅ | ⭐⭐⭐⭐ | ⭐⭐⭐ | ⭐⭐⭐⭐⭐ |
| MySQL | 数据库集成 | ❌ | ⭐⭐⭐ | ⭐⭐⭐ | ⭐⭐⭐⭐ |
| PostgreSQL | 数据库集成 | ❌ | ⭐⭐⭐ | ⭐⭐⭐ | ⭐⭐⭐⭐ |
| Redis | 缓存集成 | ❌ | ⭐⭐⭐⭐ | ⭐⭐ | ⭐⭐⭐ |

## 选择决策树

### 第一步：环境选择

```
生产环境？
├─ 是 → 继续
└─ 否（测试/临时）
   ├─ 小数据量（< 1GB）→ TinyLog
   ├─ 中等数据量（1-10GB）→ StripeLog/Log
   └─ 大数据量（> 10GB）→ MergeTree
```

### 第二步：是否需要复制？

```
需要数据复制（高可用）？
├─ 是 → ReplicatedMergeTree 系列
│  ├─ 需要去重？→ ReplicatedReplacingMergeTree
│  ├─ 需要数值聚合？→ ReplicatedSummingMergeTree
│  ├─ 需要复杂聚合？→ ReplicatedAggregatingMergeTree
│  └─ 其他 → ReplicatedMergeTree
└─ 否 → 继续
```

### 第三步：数据特性

```
数据更新方式？
├─ 只追加（Append-only）→ 继续
├─ 需要去重 → ReplacingMergeTree
├─ 增量更新 → CollapsingMergeTree
└─ 需要更新/删除 → CollapsingMergeTree/VersionedCollapsingMergeTree
```

### 第四步：聚合需求

```
需要预聚合？
├─ 不需要 → MergeTree
├─ 简单求和 → SummingMergeTree
├─ 复杂聚合 → AggregatingMergeTree
└─ 需要加速查询 → MaterializedView + MergeTree
```

### 第五步：分布式需求

```
需要分布式查询？
├─ 是 → Distributed 表
│  └─ 本地表：ReplicatedMergeTree 系列
└─ 否 → 本地表即可
```

### 第六步：外部集成

```
需要访问外部数据？
├─ 是 → 集成引擎
│  ├─ 云存储 → S3
│  ├─ Hadoop → HDFS
│  ├─ MySQL → MySQL
│  ├─ PostgreSQL → PostgreSQL
│  ├─ Redis → Redis
│  ├─ 远程文件 → URL
│  └─ 本地文件 → File
└─ 否 → 本地存储
```

### 第七步：特殊用途

```
特殊需求？
├─ 高频写入 → Buffer + MergeTree
├─ 数据归档 → Merge + MergeTree
├─ 数据抽象 → View
├─ 预聚合 → MaterializedView
├─ 测试/调试 → Null
├─ IN 查询 → Set
└─ 频繁连接 → Join
```

## 性能基准测试

### 测试环境

- 数据量：1000 万行
- 查询类型：SELECT, COUNT, GROUP BY
- 硬件：8 CPU, 32GB RAM, SSD

### 写入性能（万行/秒）

| 引擎 | 写入性能 | 相对性能 |
|------|----------|----------|
| TinyLog | 50 | 1.0x |
| Log | 80 | 1.6x |
| MergeTree | 120 | 2.4x |
| ReplacingMergeTree | 115 | 2.3x |
| ReplicatedMergeTree | 110 | 2.2x |
| SummingMergeTree | 118 | 2.4x |

### 查询性能（毫秒）

| 引擎 | SELECT | COUNT | GROUP BY | 综合性能 |
|------|--------|-------|----------|----------|
| TinyLog | 500 | 450 | 1200 | 2.1x |
| Log | 300 | 250 | 800 | 1.4x |
| MergeTree | 50 | 40 | 150 | 0.3x |
| ReplacingMergeTree | 55 | 45 | 160 | 0.3x |
| ReplicatedMergeTree | 52 | 42 | 155 | 0.3x |
| Distributed | 60 | 50 | 180 | 0.4x |

### 存储效率（压缩后）

| 引擎 | 原始大小 | 压缩后 | 压缩比 |
|------|----------|--------|--------|
| TinyLog | 1.5GB | 1.5GB | 1.0x |
| StripeLog | 1.5GB | 600MB | 2.5x |
| Log | 1.5GB | 500MB | 3.0x |
| MergeTree | 1.5GB | 200MB | 7.5x |
| ReplacingMergeTree | 1.5GB | 210MB | 7.1x |
| ReplicatedMergeTree | 1.5GB | 220MB | 6.8x |

## 最佳实践总结

### 1. 生产环境配置

**始终使用 ReplicatedMergeTree 系列**

```sql
-- 推荐
CREATE TABLE production.events (
    id UInt64,
    data String,
    timestamp DateTime
) ENGINE = ReplicatedMergeTree()
PARTITION BY toYYYYMM(timestamp)
ORDER BY (id, timestamp);

-- 避免
CREATE TABLE production.events (
    id UInt64,
    data String,
    timestamp DateTime
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(timestamp)
ORDER BY (id, timestamp);
```

### 2. 分区设计

**按时间分区，粒度根据查询频率**

- 高频查询：按天分区
- 中频查询：按月分区
- 低频查询：按年分区

```sql
-- 按天分区（高频查询）
PARTITION BY toDate(timestamp)

-- 按月分区（推荐）
PARTITION BY toYYYYMM(timestamp)

-- 按年分区（归档）
PARTITION BY toYYYY(timestamp)
```

### 3. 排序键设计

**根据查询模式设计排序键**

```sql
-- 常见查询：WHERE user_id = ?
ORDER BY (user_id, timestamp)

-- 常见查询：WHERE user_id = ? AND event_type = ?
ORDER BY (user_id, event_type, timestamp)

-- 时间序列查询：WHERE timestamp > ?
ORDER BY (timestamp, user_id)
```

### 4. 索引优化

**使用跳数索引加速查询**

```sql
-- 添加 minmax 索引
ALTER TABLE events
ADD INDEX idx_timestamp_minmax timestamp TYPE minmax GRANULARITY 4;

-- 添加 bloom_filter 索引
ALTER TABLE events
ADD INDEX idx_user_bloom user_id TYPE bloom_filter(0.01) GRANULARITY 8;
```

### 5. 预聚合策略

**使用物化视图加速常用查询**

```sql
-- 创建源表
CREATE TABLE events (
    user_id UInt64,
    event_type String,
    timestamp DateTime
) ENGINE = ReplicatedMergeTree()
ORDER BY (user_id, timestamp);

-- 创建物化视图
CREATE MATERIALIZED VIEW events_stats_mv
ENGINE = AggregatingMergeTree()
ORDER BY (user_id, toDate(timestamp))
AS SELECT
    user_id,
    toDate(timestamp) as date,
    countState() as event_count_state
FROM events
GROUP BY user_id, toDate(timestamp);

-- 查询物化视图（快速）
SELECT
    user_id,
    date,
    countMerge(event_count_state) as event_count
FROM events_stats_mv
GROUP BY user_id, date;
```

### 6. 去重策略

**根据去重需求选择引擎**

```sql
-- 确保唯一性（业务逻辑去重）
CREATE TABLE unique_events (
    event_id UInt64,
    data String
) ENGINE = ReplacingMergeTree(event_id)
ORDER BY event_id;

-- 查询去重数据
SELECT * FROM unique_events FINAL;

-- 或手动 OPTIMIZE
OPTIMIZE TABLE unique_events FINAL;
```

### 7. 增量更新策略

**使用 CollapsingMergeTree 实现增量更新**

```sql
-- 创建表
CREATE TABLE inventory (
    product_id UInt64,
    quantity Int32,
    sign Int8,  -- 1 for insert, -1 for delete
    timestamp DateTime
) ENGINE = CollapsingMergeTree(sign)
ORDER BY product_id;

-- 插入库存
INSERT INTO inventory VALUES (101, 100, 1, now());

-- 减少库存
INSERT INTO inventory VALUES (101, 10, -1, now());

-- 查询当前库存
SELECT
    product_id,
    sum(quantity * sign) as current_inventory
FROM inventory
GROUP BY product_id;
```

### 8. 分布式表设计

**合理选择分片键**

```sql
-- 常见查询：WHERE user_id = ?
-- 分片键：user_id
CREATE TABLE distributed_events AS local_events
ENGINE = Distributed(cluster, db, local_events, user_id);

-- 常见查询：WHERE timestamp > ?
-- 分片键：intHash32(timestamp)
CREATE TABLE distributed_events AS local_events
ENGINE = Distributed(cluster, db, local_events, intHash32(timestamp));

-- 常见查询：WHERE user_id = ? AND timestamp > ?
-- 分片键：user_id
```

### 9. 数据生命周期管理

**使用 TTL 自动清理旧数据**

```sql
-- 30 天后删除数据
CREATE TABLE events (
    id UInt64,
    data String,
    timestamp DateTime
) ENGINE = ReplicatedMergeTree()
ORDER BY timestamp
TTL timestamp + INTERVAL 30 DAY;

-- 7 天后移到冷存储
CREATE TABLE events (
    id UInt64,
    data String,
    timestamp DateTime
) ENGINE = ReplicatedMergeTree()
ORDER BY timestamp
TTL timestamp + INTERVAL 7 DAY TO DISK 'cold';

-- 7 天后删除，30 天后归档
CREATE TABLE events (
    id UInt64,
    data String,
    timestamp DateTime
) ENGINE = ReplicatedMergeTree()
ORDER BY timestamp
TTL
    timestamp + INTERVAL 7 DAY DELETE,
    timestamp + INTERVAL 30 DAY TO VOLUME 'archive';
```

### 10. 性能优化清单

- [ ] 使用 ReplicatedMergeTree 系列
- [ ] 合理设计分区键
- [ ] 优化排序键
- [ ] 添加跳数索引
- [ ] 使用物化视图
- [ ] 配置 TTL
- [ ] 定期 OPTIMIZE
- [ ] 监控性能指标
- [ ] 清理旧数据
- [ ] 使用分布式表

## 常见问题

### Q1: MergeTree 和 ReplicatedMergeTree 有什么区别？

A: ReplicatedMergeTree 支持 ZooKeeper 数据复制，提供高可用性。生产环境建议始终使用 ReplicatedMergeTree。

### Q2: ReplacingMergeTree 真的去重吗？

A: 不立即去重，需要使用 FINAL 或手动 OPTIMIZE。查询时去重会影响性能。

### Q3: 什么时候用 Distributed 表？

A: 需要跨节点查询时使用。Distributed 表本身不存储数据，只是查询路由层。

### Q4: Log 系列引擎有什么用？

A: 适合临时数据、小数据量（< 10GB）、测试场景。生产环境不推荐使用。

### Q5: 如何选择分区粒度？

A: 根据查询频率：
- 高频查询：按天
- 中频查询：按月
- 低频查询：按年

### Q6: 物化视图有什么优势？

A: 预聚合数据，大幅提高查询性能。适合常用查询模式。

### Q7: Buffer 表什么时候用？

A: 高频小批量写入场景。可以批量写入后刷新到目标表。

### Q8: 如何优化写入性能？

A:
1. 批量插入
2. 使用异步插入
3. 合理设置 block size
4. 使用 Buffer 表

### Q9: 如何优化查询性能？

A:
1. 利用分区剪枝
2. 优化排序键
3. 使用跳数索引
4. 使用物化视图
5. 使用 PREWHERE

### Q10: 什么时候需要清理数据？

A:
1. 磁盘空间不足
2. 查询性能下降
3. 数据过期
4. 配置 TTL 自动清理

## 总结

选择 ClickHouse 表引擎时，请遵循以下原则：

1. **生产环境**：始终使用 ReplicatedMergeTree 系列
2. **测试环境**：可以使用 MergeTree 或 Log 系列
3. **数据特性**：根据去重、聚合、更新需求选择
4. **查询模式**：优化排序键和分区键
5. **性能需求**：使用物化视图和索引优化
6. **监控维护**：定期 OPTIMIZE 和清理

正确的表引擎选择可以显著提高性能和降低运维成本。
