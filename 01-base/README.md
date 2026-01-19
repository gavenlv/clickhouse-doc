# ClickHouse Base SQL Examples

本目录包含 ClickHouse 的基础使用示例，所有 SQL 都可以在集群环境中直接测试。

## 文件说明

### 01_basic_operations.sql
基础操作示例：
- 普通表的创建、插入、查询
- 数据类型示例
- 基本查询语法

### 02_replicated_tables.sql
复制表示例：
- 使用默认路径配置创建复制表
- 验证表在两个副本上创建
- 测试数据复制功能

### 03_distributed_tables.sql
分布式表示例：
- 创建分布式表
- 测试数据分片
- 验证查询路由

### 04_system_queries.sql
系统表查询：
- 查看集群配置
- 查看 Macros 配置
- 查看复制状态
- 查看 ZooKeeper 路径

### 05_advanced_features.sql
高级特性示例：
- 物化视图 (Materialized View)
- 投影 (Projection)
- TTL 设置
- 数据分区

### 06_data_updates.sql
数据更新和实时场景示例：
- ReplacingMergeTree 数据去重
- CollapsingMergeTree 增量更新
- VersionedCollapsingMergeTree 版本控制
- Mutation 批量更新
- Lightweight DELETE 轻量删除
- 实时数据插入
- 异步插入优化
- TTL 自动删除
- 分区级操作
- 物化视图实时聚合
- 窗口函数分析
- 批量插入优化

## 如何使用

### 方法 1: 使用 Play UI（推荐）
1. 访问 http://localhost:8123/play
2. 复制 SQL 文件内容到查询框
3. 点击 Execute 执行
4. 注意：由于文件包含多条 SQL 语句，建议逐个执行或使用 clickhouse-client

### 方法 2: 使用 clickhouse-client
```bash
# 连接到 clickhouse1
docker exec -it clickhouse-server-1 clickhouse-client

# 执行 SQL 文件（推荐，支持多条语句）
docker exec -it clickhouse-server-1 clickhouse-client --queries-file /path/to/01_basic_operations.sql

# 或者复制粘贴 SQL 内容到客户端
```

### 方法 3: 使用 curl（仅限单个查询）
```bash
# 执行单个查询
curl -XPOST http://localhost:8123 --data "SELECT 1"

# 注意：curl 默认不支持多条语句，多条语句会报错：
# Code: 62. DB::Exception: Syntax error (Multi-statements are not allowed)
```

## 测试环境说明

当前环境配置：
- **ClickHouse 节点**:
  - clickhouse1: http://localhost:8123 (native: 9000)
  - clickhouse2: http://localhost:8124 (native: 9001)
- **集群名称**: treasurycluster
- **Shard 数量**: 1
- **Replica 数量**: 2
- **Keeper 节点**: 3 个

## 默认配置

已配置的 Macros：
- `{cluster}` → treasurycluster
- `{layer}` → 01
- `{shard}` → 1 (clickhouse1) / 2 (clickhouse2)
- `{replica}` → clickhouse1 / clickhouse2
- `{table_prefix}` → test

已配置的默认路径：
- `<default_replica_path>` → /clickhouse/tables/{shard}/{table}
- `<default_replica_name>` → {replica}

这意味着创建复制表时，无需手动指定 ZooKeeper 路径，例如：
```sql
CREATE TABLE test_table (
    id UInt64,
    data String
) ENGINE = ReplicatedMergeTree
ORDER BY id;
-- 会自动使用 /clickhouse/tables/1/test_table 作为 ZooKeeper 路径
```

## 注意事项

1. **Windows Docker 限制**：在 Windows Docker 环境下，复制功能可能因文件权限问题受到影响，但不影响基本查询
2. **测试数据清理**：示例 SQL 可能创建测试表，执行完成后记得清理
3. **执行顺序**：建议按文件编号顺序执行，避免依赖问题
4. **分布式表依赖**：03_distributed_tables.sql 需要先执行 02_replicated_tables.sql
5. **数据更新特性**：ClickHouse 不支持传统的 UPDATE 操作，06_data_updates.sql 展示了多种替代方案

## 数据更新策略

ClickHouse 不支持传统关系数据库的 UPDATE 操作，但提供了多种替代方案：

| 场景 | 推荐方案 | 适用引擎 | 特点 |
|------|---------|---------|------|
| 用户信息更新 | ReplacingMergeTree | ReplacingMergeTree | 自动去重，保留最新记录 |
| 订单状态变化 | CollapsingMergeTree | CollapsingMergeTree | 支持 soft delete，增量更新 |
| 精确版本控制 | VersionedCollapsingMergeTree | VersionedCollapsingMergeTree | 保留历史版本 |
| 批量数据修正 | ALTER UPDATE | 所有引擎 | Mutation 异步执行 |
| 快速少量删除 | Lightweight DELETE | MergeTree | 立即生效 |
| 自动过期数据 | TTL | MergeTree 系列 | 定时自动清理 |
| 分区级删除 | DROP PARTITION | MergeTree 系列 | 最快的批量删除 |
| 实时统计 | 物化视图 | SummingMergeTree | 自动聚合 |

详细示例请参考 [06_data_updates.sql](./06_data_updates.sql)。
