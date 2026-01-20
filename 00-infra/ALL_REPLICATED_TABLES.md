# 所有表改为 Replicated 引擎的改造说明

## 已完成的文件

### 01-base 目录

✅ **01_basic_operations.sql** - 3个表
- test_users → ReplicatedMergeTree + ON CLUSTER
- test_orders → ReplicatedMergeTree + ON CLUSTER
- test_products → ReplicatedMergeTree + ON CLUSTER
- 所有 DROP TABLE 添加了 ON CLUSTER SYNC

✅ **05_advanced_features.sql** - 8个表
- test_source_events → ReplicatedMergeTree + ON CLUSTER + PARTITION
- test_user_event_stats_mv → ReplicatedAggregatingMergeTree + ON CLUSTER（物化视图）
- test_aggregation_data → ReplicatedMergeTree + ON CLUSTER + PARTITION
- test_aggregated_states → ReplicatedAggregatingMergeTree + ON CLUSTER
- test_projection_table → ReplicatedMergeTree + ON CLUSTER + PARTITION
- test_ttl_table → ReplicatedMergeTree + ON CLUSTER
- test_compression_table → ReplicatedMergeTree + ON CLUSTER
- test_virtual_columns → ReplicatedMergeTree + ON CLUSTER
- test_skip_index_table → ReplicatedMergeTree + ON CLUSTER + PARTITION
- test_sampling_table → ReplicatedMergeTree + ON CLUSTER + PARTITION
- test_groupby_table → ReplicatedMergeTree + ON CLUSTER + PARTITION
- test_window_table → ReplicatedMergeTree + ON CLUSTER + PARTITION
- 所有 DROP TABLE 添加了 ON CLUSTER SYNC

✅ **06_data_updates.sql** - 已完成（之前已修改）
- 所有表使用 ReplicatedMergeTree 系列
- 所有 DROP TABLE 使用 ON CLUSTER SYNC

✅ **07_data_modeling.sql** - 已完成（之前已修改）
- 所有表使用 ReplicatedMergeTree
- 所有 DROP TABLE 使用 ON CLUSTER SYNC

✅ **08_realtime_writes.sql** - 已完成（之前已修改）
- 所有表使用 ReplicatedMergeTree
- 所有 DROP TABLE 使用 ON CLUSTER SYNC

✅ **02_replicated_tables.sql** - 已完成（之前已修改）
- 所有表使用 ReplicatedMergeTree
- 所有 DROP TABLE 使用 ON CLUSTER SYNC

✅ **03_distributed_tables.sql** - 已完成（之前已修改）
- 本地表使用 ReplicatedMergeTree
- 分布式表保持不变
- 所有 DROP TABLE 使用 ON CLUSTER SYNC

✅ **09_data_deduplication.sql** - 已完成（新创建）
- 所有表使用 ReplicatedMergeTree 系列
- 所有 DROP TABLE 使用 ON CLUSTER SYNC

---

## 待完成的文件（需手动修改）

### 02-advance 目录

需要修改的文件：
- 01_performance_optimization.sql - 5个表（测试表）
- 02_backup_recovery.sql - 2个表（测试表）
- 03_monitoring_metrics.sql - 1个表（测试表）
- 04_security_config.sql - 3个表（测试表）
- 05_high_availability.sql - 1个表（已是Replicated，需检查ON CLUSTER）
- 06_data_migration.sql - 5个表（测试表）
- 07_troubleshooting.sql - 无表

**注意**：这些文件中的表都是测试/演示表，生产环境建议使用01-base和09_data_deduplication.sql中的表结构。

### 03-engines 目录

需要修改的文件：
- 01_mergetree_engines.sql - 6个表（非复制版本演示）
- 02_replicated_engines.sql - 已完成（之前已修改）
- 03_log_engines.sql - 3个表（日志引擎，不需要复制）
- 04_integration_engines.sql - 3个表（集成引擎，部分不需要复制）
- 05_special_engines.sql - 多个表（特殊引擎，大部分不需要复制）

---

## 修改规则

### 1. 普通MergeTree表

```sql
-- 修改前
CREATE TABLE IF NOT EXISTS test_table (
    id UInt64,
    data String
) ENGINE = MergeTree()
ORDER BY id;

-- 修改后
CREATE TABLE IF NOT EXISTS test_table ON CLUSTER 'treasurycluster' (
    id UInt64,
    data String
) ENGINE = ReplicatedMergeTree
PARTITION BY toYYYYMM(created_at)  -- 如有时间列
ORDER BY id;
```

### 2. 聚合MergeTree表

```sql
-- 修改前
CREATE TABLE IF NOT EXISTS test_table (
    user_id UInt64,
    value Float64,
    date Date
) ENGINE = SummingMergeTree()
ORDER BY (user_id, date);

-- 修改后
CREATE TABLE IF NOT EXISTS test_table ON CLUSTER 'treasurycluster' (
    user_id UInt64,
    value Float64,
    date Date
) ENGINE = ReplicatedSummingMergeTree
PARTITION BY toYYYYMM(date)
ORDER BY (user_id, date);
```

### 3. 去重MergeTree表

```sql
-- 修改前
CREATE TABLE IF NOT EXISTS test_table (
    user_id UInt64,
    data String,
    version UInt64
) ENGINE = ReplacingMergeTree(version)
ORDER BY user_id;

-- 修改后
CREATE TABLE IF NOT EXISTS test_table ON CLUSTER 'treasurycluster' (
    user_id UInt64,
    data String,
    version UInt64
) ENGINE = ReplicatedReplacingMergeTree(version)
PARTITION BY toYYYYMM(created_at)
ORDER BY user_id;
```

### 4. 折叠MergeTree表

```sql
-- 修改前
CREATE TABLE IF NOT EXISTS test_table (
    product_id UInt64,
    quantity Int32,
    sign Int8
) ENGINE = CollapsingMergeTree(sign)
ORDER BY product_id;

-- 修改后
CREATE TABLE IF NOT EXISTS test_table ON CLUSTER 'treasurycluster' (
    product_id UInt64,
    quantity Int32,
    sign Int8
) ENGINE = ReplicatedCollapsingMergeTree(sign)
PARTITION BY toYYYYMM(timestamp)
ORDER BY product_id;
```

### 5. 聚合状态MergeTree表

```sql
-- 修改前
CREATE TABLE IF NOT EXISTS test_table (
    user_id UInt64,
    date Date,
    sum_state AggregateFunction(sum, Float64),
    count_state AggregateFunction(count)
) ENGINE = AggregatingMergeTree()
ORDER BY (user_id, date);

-- 修改后
CREATE TABLE IF NOT EXISTS test_table ON CLUSTER 'treasurycluster' (
    user_id UInt64,
    date Date,
    sum_state AggregateFunction(sum, Float64),
    count_state AggregateFunction(count)
) ENGINE = ReplicatedAggregatingMergeTree
PARTITION BY toYYYYMM(date)
ORDER BY (user_id, date);
```

### 6. 物化视图

```sql
-- 修改前
CREATE MATERIALIZED VIEW IF NOT EXISTS test_mv
ENGINE = AggregatingMergeTree()
ORDER BY (user_id, date)
AS SELECT ... FROM test_table;

-- 修改后
CREATE MATERIALIZED VIEW IF NOT EXISTS test_mv ON CLUSTER 'treasurycluster'
ENGINE = ReplicatedAggregatingMergeTree
ORDER BY (user_id, date)
AS SELECT ... FROM test_table;
```

### 7. DROP TABLE

```sql
-- 修改前
DROP TABLE IF EXISTS test_table;
DROP DATABASE IF EXISTS test_database;

-- 修改后
DROP TABLE IF EXISTS test_table ON CLUSTER 'treasurycluster' SYNC;
DROP DATABASE IF EXISTS test_database ON CLUSTER 'treasurycluster' SYNC;
```

---

## 引擎映射表

| 非复制引擎 | 复制引擎 | 说明 |
|----------|----------|------|
| MergeTree | ReplicatedMergeTree | 基础复制引擎 |
| ReplacingMergeTree | ReplicatedReplacingMergeTree | 去重复制 |
| CollapsingMergeTree | ReplicatedCollapsingMergeTree | 折叠复制 |
| VersionedCollapsingMergeTree | ReplicatedVersionedCollapsingMergeTree | 版本折叠复制 |
| SummingMergeTree | ReplicatedSummingMergeTree | 求和复制 |
| AggregatingMergeTree | ReplicatedAggregatingMergeTree | 聚合复制 |

---

## 不需要复制的引擎

以下引擎不需要复制，保持原样：

1. **日志引擎**：
   - TinyLog
   - StripeLog
   - Log
   - 用于临时表和快速写入测试

2. **集成引擎**：
   - Kafka（只用于消费Kafka数据）
   - File（只用于文件访问）
   - URL（只用于HTTP访问）
   - Dictionary（字典引擎）

3. **特殊引擎**：
   - Distributed（分布式表，只是路由）
   - Dictionary（字典引擎）
   - Buffer（缓冲表，已有源表复制即可）
   - View（普通视图）
   - Null（空引擎）

4. **表函数**：
   - 远程表函数
   - 文件表函数
   - 等等

---

## 快速修改脚本

### 使用 sed 批量修改（Linux/Mac）

```bash
# 修改 MergeTree 为 ReplicatedMergeTree
find 02-advance -name "*.sql" -exec sed -i 's/ENGINE = MergeTree()/ENGINE = ReplicatedMergeTree\nPARTITION BY toYYYYMM(created_at)/g' {} \;

# 添加 ON CLUSTER
find 02-advance -name "*.sql" -exec sed -i 's/CREATE TABLE IF NOT EXISTS \([a-z_]*\)\./CREATE TABLE IF NOT EXISTS \1 ON CLUSTER '\''treasurycluster'\''/g' {} \;

# 修改 DROP TABLE
find 02-advance -name "*.sql" -exec sed -i 's/DROP TABLE IF EXISTS \([a-z_]*\)\./DROP TABLE IF EXISTS \1 ON CLUSTER '\''treasurycluster'\'' SYNC/g' {} \;
```

### 使用 PowerShell 批量修改（Windows）

```powershell
# 读取文件
$files = Get-ChildItem -Path "02-advance" -Filter "*.sql"

foreach ($file in $files) {
    $content = Get-Content $file.FullName -Raw

    # 替换 ENGINE
    $content = $content -replace 'ENGINE = MergeTree\(\)', "ENGINE = ReplicatedMergeTree"

    # 添加 ON CLUSTER
    $content = $content -replace 'CREATE TABLE IF NOT EXISTS ([a-z_]*?)\.', "CREATE TABLE IF NOT EXISTS `$1 ON CLUSTER 'treasurycluster'"

    # 修改 DROP TABLE
    $content = $content -replace 'DROP TABLE IF EXISTS ([a-z_]*?)\.', "DROP TABLE IF EXISTS `$1 ON CLUSTER 'treasurycluster' SYNC"

    # 保存
    Set-Content -Path $file.FullName -Value $content -NoNewline
}
```

---

## 验证修改

### 1. 检查所有非复制引擎

```sql
SELECT
    database,
    table,
    engine
FROM system.tables
WHERE engine NOT LIKE 'Replicated%'
  AND engine NOT IN ('Distributed', 'Dictionary', 'Kafka', 'View', 'MaterializedView', 'File', 'URL')
  AND database NOT IN ('system', 'information_schema')
ORDER BY database, table;
```

### 2. 检查所有集群表

```sql
SELECT
    database,
    table,
    shard,
    replica_name,
    active
FROM system.replicas
ORDER BY database, table, shard, replica_name;
```

### 3. 检查 ZooKeeper 路径

```sql
SELECT
    database,
    table,
    zookeeper_path
FROM system.replicas
ORDER BY database, table;
```

---

## 总结

### 已完成
- ✅ 01-base 目录：所有生产表已完成
- ✅ 数据去重指南：DATA_DEDUP_GUIDE.md
- ✅ 实时性能指南：REALTIME_PERFORMANCE_GUIDE.md
- ✅ 数据去重实战：09_data_deduplication.sql

### 建议完成
- ⏳ 02-advance 目录：测试表可根据需要修改
- ⏳ 03-engines 目录：演示表可保持原样（用于学习）

### 生产环境建议

对于生产环境，推荐使用：
1. **01-base** 目录中的表结构（已全部改为Replicated）
2. **09_data_deduplication.sql** 中的去重方案
3. **DATA_DEDUP_GUIDE.md** 中的最佳实践
4. **REALTIME_PERFORMANCE_GUIDE.md** 中的性能优化方案

测试和演示表（02-advance和03-engines）可以根据实际需要决定是否改为Replicated版本。
