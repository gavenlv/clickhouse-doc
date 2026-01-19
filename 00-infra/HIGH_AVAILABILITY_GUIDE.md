# ClickHouse 高可用配置指南

## 概述

为了保证 ClickHouse 集群的高可用性，所有生产环境的表都应该：
1. **创建在集群上** - 使用 `ON CLUSTER 'treasurycluster'`
2. **使用复制引擎** - 使用 `ReplicatedMergeTree` 系列引擎
3. **使用默认 ZooKeeper 路径** - 配置文件中已配置默认路径

## 集群配置

当前集群配置：
- **集群名称**: `treasurycluster`
- **副本数量**: 2 (clickhouse1, clickhouse2)
- **Keeper 节点**: 3 个

## 默认 ZooKeeper 路径配置

配置文件中已配置默认路径：

**clickhouse1.xml & clickhouse2.xml:**
```xml
<default_replica_path>/clickhouse/tables/{shard}/{table}</default_replica_path>
<default_replica_name>{replica}</default_replica_name>
```

这意味着创建表时可以使用简化语法：
```sql
CREATE TABLE table_name ON CLUSTER 'treasurycluster' (
    ...
) ENGINE = ReplicatedMergeTree
ORDER BY ...;
```

会自动使用 ZooKeeper 路径：
- 路径: `/clickhouse/tables/1/table_name`
- 副本名: `{replica}` (clickhouse1 或 clickhouse2)

## 引擎映射

### 非复制引擎 → 复制引擎

| 非复制引擎 | 复制引擎 | 说明 |
|----------|----------|------|
| MergeTree | ReplicatedMergeTree | 基础复制引擎 |
| ReplacingMergeTree | ReplicatedReplacingMergeTree | 去重复制 |
| SummingMergeTree | ReplicatedSummingMergeTree | 求和复制 |
| AggregatingMergeTree | ReplicatedAggregatingMergeTree | 聚合复制 |
| CollapsingMergeTree | ReplicatedCollapsingMergeTree | 折叠复制 |
| VersionedCollapsingMergeTree | ReplicatedVersionedCollapsingMergeTree | 版本折叠复制 |
| GraphiteMergeTree | ReplicatedGraphiteMergeTree | Graphite 复制 |

### 不需要复制的引擎

以下引擎不需要复制：
- **Distributed** - 分布式表引擎（只是查询路由）
- **Kafka** - Kafka 表引擎（临时表）
- **Buffer** - Buffer 表引擎（临时缓冲）
- **File** - 外部文件引擎
- **URL** - 远程文件引擎
- **View** - 普通视图
- **Materialized View** - 物化视图（引擎使用被查询表的引擎）

## 表创建模式

### 模式 1：生产环境推荐（复制 + 集群）

```sql
-- 创建复制表（推荐）
CREATE TABLE IF NOT EXISTS database.table_name ON CLUSTER 'treasurycluster' (
    id UInt64,
    name String,
    created_at DateTime DEFAULT now()
) ENGINE = ReplicatedMergeTree
ORDER BY id;
```

### 模式 2：创建分布式表（可选）

```sql
-- 先创建本地复制表
CREATE TABLE IF NOT EXISTS database.table_local ON CLUSTER 'treasurycluster' (
    id UInt64,
    name String,
    created_at DateTime DEFAULT now()
) ENGINE = ReplicatedMergeTree
ORDER BY id;

-- 再创建分布式表
CREATE TABLE IF NOT EXISTS database.table_distributed ON CLUSTER 'treasurycluster'
AS database.table_local
ENGINE = Distributed('treasurycluster', 'database', 'table_local', rand());
```

### 模式 3：特殊引擎（需要版本控制）

```sql
-- ReplicatedReplacingMergeTree
CREATE TABLE IF NOT EXISTS database.users ON CLUSTER 'treasurycluster' (
    user_id UInt64,
    name String,
    version UInt64,
    updated_at DateTime DEFAULT now()
) ENGINE = ReplicatedReplacingMergeTree
ORDER BY user_id;

-- ReplicatedCollapsingMergeTree
CREATE TABLE IF NOT EXISTS database.orders ON CLUSTER 'treasurycluster' (
    order_id UInt64,
    product_id UInt64,
    quantity UInt32,
    sign Int8,
    created_at DateTime DEFAULT now()
) ENGINE = ReplicatedCollapsingMergeTree(sign)
ORDER BY order_id;
```

## 修改清单

### 需要修改的文件

#### 1. 01-base/07_data_modeling.sql
- **修改数量**: 32 个表
- **主要问题**: 所有表使用 `MergeTree`，未使用 `ON CLUSTER`
- **修改方案**: 
  - 将所有 `MergeTree` 改为 `ReplicatedMergeTree`
  - 将所有 `SummingMergeTree` 改为 `ReplicatedSummingMergeTree`
  - 添加 `ON CLUSTER 'treasurycluster'`
  - 物化视图的引擎也需要修改

#### 2. 01-base/06_data_updates.sql
- **修改数量**: 3 个表 + 14 个测试表
- **主要问题**: 使用非复制版本引擎
- **修改方案**:
  - `ReplacingMergeTree` → `ReplicatedReplacingMergeTree`
  - `CollapsingMergeTree` → `ReplicatedCollapsingMergeTree`
  - `VersionedCollapsingMergeTree` → `ReplicatedVersionedCollapsingMergeTree`
  - 添加 `ON CLUSTER 'treasurycluster'`

#### 3. 01-base/02_replicated_tables.sql
- **修改数量**: 5 个表
- **主要问题**: 已使用 `ReplicatedMergeTree` 但缺少 `ON CLUSTER`
- **修改方案**:
  - 为所有表添加 `ON CLUSTER 'treasurycluster'`
  - 已经配置了正确的 ZooKeeper 路径（无参数）

#### 4. 01-base/03_distributed_tables.sql
- **修改数量**: 2 个本地表
- **主要问题**: 本地表缺少 `ON CLUSTER`
- **修改方案**:
  - 为 ReplicatedMergeTree 本地表添加 `ON CLUSTER 'treasurycluster'`
  - 分布式表已经正确配置

#### 5. 01-base/08_realtime_writes.sql
- **修改数量**: 12 个表
- **主要问题**: 生产表使用 `MergeTree`，未使用 `ON CLUSTER`
- **修改方案**:
  - 将所有 `MergeTree` 改为 `ReplicatedMergeTree`
  - 添加 `ON CLUSTER 'treasurycluster'`
  - Kafka 表和 Buffer 表不需要修改

#### 6. 01-base/05_advanced_features.sql
- **修改数量**: 12 个测试表
- **建议**: 这些是测试/演示表，可以保持 `MergeTree`，但在注释中说明
- **如果需要生产**: 将 `MergeTree` 改为 `ReplicatedMergeTree` 并添加 `ON CLUSTER`

#### 7. 01-base/01_basic_operations.sql
- **修改数量**: 3 个测试表
- **建议**: 这些是基础测试表，可以保持 `MergeTree`
- **如果需要生产**: 将 `MergeTree` 改为 `ReplicatedMergeTree` 并添加 `ON CLUSTER`

#### 8. 01-base/04_system_queries.sql
- **修改数量**: 0
- **状态**: 无需修改（仅包含查询）

## 验证方法

### 1. 检查表是否在集群上创建

```sql
-- 查看表是否在两个副本上存在
SELECT
    database,
    table,
    shard,
    replica_name,
    active
FROM system.replicas
WHERE database = 'your_database'
  AND table = 'your_table'
ORDER BY shard, replica_name;
```

预期结果（2 个副本都应该是 active）：
```
database       | table      | shard | replica_name | active
---------------|------------|-------|--------------|-------
your_database  | your_table | 1      | clickhouse1  | 1
your_database  | your_table | 1      | clickhouse2  | 1
```

### 2. 检查 ZooKeeper 路径

```sql
-- 查看表的 ZooKeeper 路径
SELECT
    database,
    table,
    replica_name,
    zookeeper_path
FROM system.replicas
WHERE database = 'your_database'
  AND table = 'your_table';
```

预期结果：
```
zookeeper_path
--------------------
/clickhouse/tables/1/your_table
```

### 3. 测试数据复制

```sql
-- 在 clickhouse1 上插入数据
INSERT INTO database.table VALUES (1, 'test', now());

-- 在 clickhouse2 上查询数据（应该能看到）
SELECT * FROM database.table;
```

## 性能影响

### 写入性能

- **单表**: 写入速度较快，但无高可用
- **复制表**: 写入速度稍慢（需要等待复制确认），但保证高可用

### 查询性能

- **单表**: 查询速度正常
- **复制表**: 
  - 两个副本都可以查询，提高并发能力
  - 如果一个副本故障，自动切换到另一个
  - 总体查询吞吐量更高

## 故障恢复

### 副本故障

如果一个副本故障：
1. ClickHouse 自动切换到另一个副本
2. 读写操作继续正常
3. 查询性能可能略微下降（只有一个副本服务）

### 恢复副本

1. 修复故障副本
2. ClickHouse 自动从其他副本复制数据
3. 数据同步完成后，两个副本都提供服务

## 最佳实践

1. **始终使用 ReplicatedMergeTree 系列引擎**
2. **在生产环境始终使用 `ON CLUSTER`**
3. **监控复制状态**（system.replicas）
4. **配置合适的副本数量**（至少 2 个）
5. **定期测试故障恢复**
6. **使用分布式表简化查询**

## 示例对比

### ❌ 不推荐（无高可用）

```sql
-- 单表，无复制
CREATE TABLE IF NOT EXISTS database.events (
    id UInt64,
    name String
) ENGINE = MergeTree()
ORDER BY id;

-- 问题：
-- - 只在一个副本上创建
-- - 副本故障时数据不可用
-- - 无数据冗余
```

### ✅ 推荐（高可用）

```sql
-- 复制表，在集群上创建
CREATE TABLE IF NOT EXISTS database.events ON CLUSTER 'treasurycluster' (
    id UInt64,
    name String
) ENGINE = ReplicatedMergeTree
ORDER BY id;

-- 优势：
-- - 在两个副本上创建
-- - 副本故障时自动切换
-- - 数据自动复制
-- - 提高查询并发能力
```

## 迁移步骤

如果已有单表，迁移到复制表：

```sql
-- 1. 创建复制表
CREATE TABLE IF NOT EXISTS database.events_replicated ON CLUSTER 'treasurycluster' AS database.events
ENGINE = ReplicatedMergeTree;

-- 2. 验证数据已复制
SELECT count() FROM database.events_replicated;

-- 3. 切换应用使用新表
-- 更新应用配置使用 events_replicated

-- 4. 删除旧表（在确认新表正常后）
DROP TABLE IF EXISTS database.events;
```

## 总结

为了保证生产环境的高可用性：

✅ **必须做**:
1. 所有生产表使用 `ReplicatedMergeTree` 系列引擎
2. 添加 `ON CLUSTER 'treasurycluster'`
3. 使用默认 ZooKeeper 路径配置

✅ **推荐做**:
1. 使用分布式表简化查询
2. 监控复制状态
3. 定期测试故障恢复
4. 配置合适的副本数量（2-3 个）

❌ **不要做**:
1. 在生产环境使用 `MergeTree`（单表）
2. 忘记添加 `ON CLUSTER`
3. 手动指定 ZooKeeper 路径（除非必要）
4. 在单个副本上创建表
