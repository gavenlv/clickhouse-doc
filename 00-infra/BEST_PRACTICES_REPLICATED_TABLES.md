# ClickHouse 复制表最佳实践

## 使用默认路径配置简化表定义

### 配置文件设置

在 `clickhouse1.xml` 和 `clickhouse2.xml` 中已经配置了默认路径：

```xml
<!-- Default replication path configuration -->
<default_replica_path>/clickhouse/tables/{shard}/{table}</default_replica_path>
<default_replica_name>{replica}</default_replica_name>
```

### ✅ 推荐做法（使用默认配置）

```sql
-- 简洁、清晰、易维护
CREATE TABLE IF NOT EXISTS my_table ON CLUSTER 'treasurycluster' (
    id UInt64,
    data String
) ENGINE = ReplicatedMergeTree
ORDER BY id;
```

### ❌ 不推荐（手动指定路径）

```sql
-- 冗长、易错、难维护
CREATE TABLE IF NOT EXISTS my_table ON CLUSTER 'treasurycluster' (
    id UInt64,
    data String
) ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/my_table', '{replica}')
ORDER BY id;
```

### 自动路径规则

当使用 `ReplicatedMergeTree()` 不带参数时，ClickHouse 会自动使用：
- **ZooKeeper 路径**: `/clickhouse/tables/{shard}/{table}`
- **副本名称**: `{replica}`

变量说明：
- `{shard}` - 从配置的 `<shard>` 标签获取
- `{table}` - 自动使用表名
- `{replica}` - 从配置的 `<replica>` 标签获取

### 特殊场景：需要自定义路径

只有在以下特殊场景才需要手动指定路径：

#### 1. 本地表（local table）
```sql
CREATE TABLE IF NOT EXISTS events_local ON CLUSTER 'treasurycluster' (
    event_id UInt64,
    event_time DateTime
) ENGINE = ReplicatedMergeTree
PARTITION BY toYYYYMM(event_time)
ORDER BY event_time;
```

**不需要手动指定路径**，因为表名已经包含了 `_local` 后缀，会自动生成：
- 路径：`/clickhouse/tables/{shard}/events_local`

#### 2. 跨集群共享路径（高级用法）

如果需要多个集群共享同一个 ZooKeeper 路径：
```sql
ENGINE = ReplicatedMergeTree('/global/tables/{shard}/my_table', '{replica}')
```

### 验证默认配置是否生效

```sql
-- 查看表的创建语句
SHOW CREATE my_table;

-- 预期输出：
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/my_table', '{replica}')
```

如果看到完整路径，说明默认配置已生效！

### 常见问题

**Q: 什么时候必须手动指定路径？**
A: 几乎不需要！99% 的情况下使用默认配置即可。

**Q: 默认配置在哪里定义？**
A: 在 `00-infra/config/clickhouse1.xml` 和 `clickhouse2.xml` 的第 64-65 行。

**Q: 不同集群可以有不同默认路径吗？**
A: 可以。每个节点的配置文件可以独立设置 `<default_replica_path>`。

**Q: 使用默认配置会影响性能吗？**
A: 完全不会！只是省去了手动编写路径的工作，最终生成的路径完全相同。

### 最佳实践总结

1. ✅ **始终使用默认配置** - 除非有特殊需求
2. ✅ **保持表名简洁** - 路径会自动包含表名
3. ✅ **使用 ON CLUSTER** - 确保集群范围创建
4. ✅ **验证配置生效** - 用 SHOW CREATE 检查
5. ❌ **避免重复配置** - 不要在配置文件和 SQL 中重复设置
