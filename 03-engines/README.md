# ClickHouse Table Engines Guide

本目录包含 ClickHouse 各种表引擎的详细介绍、使用场景和最佳实践。

## 文件说明

### 01_mergetree_engines.sql
MergeTree 系列表引擎：
- MergeTree（基础引擎）
- ReplacingMergeTree（去重）
- SummingMergeTree（求和）
- AggregatingMergeTree（聚合）
- CollapsingMergeTree（折叠）
- VersionedCollapsingMergeTree（版本折叠）
- GraphiteMergeTree（Graphite 数据）

### 02_replicated_engines.sql
复制系列引擎：
- ReplicatedMergeTree（复制基础）
- ReplicatedReplacingMergeTree（复制去重）
- ReplicatedSummingMergeTree（复制求和）
- ReplicatedAggregatingMergeTree（复制聚合）
- ReplicatedCollapsingMergeTree（复制折叠）

### 03_log_engines.sql
Log 系列简单引擎：
- TinyLog（最简单的日志）
- StripeLog（条带日志）
- Log（普通日志）

### 04_integration_engines.sql
集成系列引擎：
- URL（远程数据）
- File（本地文件）
- HDFS（Hadoop 集成）
- S3（AWS S3）
- MySQL（数据库集成）
- PostgreSQL（数据库集成）
- Redis（缓存集成）

### 05_special_engines.sql
特殊引擎：
- Distributed（分布式表）
- MaterializedView（物化视图）
- View（视图）
- Dictionary（字典）
- Buffer（缓冲表）
- Merge（合并表）
- Null（空表）
- Set（集合）
- Join（连接表）

### 06_engine_selection_guide.md
引擎选择指南：
- 引擎对比表
- 选择决策树
- 性能基准测试
- 最佳实践总结

## 表引擎分类

### 1. MergeTree 系列（最常用）
适用于大多数 OLAP 场景，支持索引、分区、数据排序。

**使用场景：**
- 时序数据
- 事件日志
- 用户行为数据
- 分析报表
- 实时监控

### 2. ReplicatedMergeTree 系列
支持数据复制的 MergeTree 引擎，用于高可用场景。

**使用场景：**
- 生产环境
- 高可用部署
- 数据备份
- 集群部署

### 3. Log 系列
简单的日志引擎，适用于临时数据和小数据量。

**使用场景：**
- 临时表
- 测试数据
- 小规模日志
- 数据暂存

### 4. Integration 系列
与外部系统集成的引擎。

**使用场景：**
- 数据导入导出
- 外部数据访问
- 跨系统集成
- 数据湖架构

### 5. 特殊引擎
用于特定用途的引擎。

**使用场景：**
- 分布式查询
- 数据预聚合
- 视图和抽象
- 缓存加速

## 如何使用

### 1. 使用 Play UI
访问 http://localhost:8123/play，复制 SQL 文件内容执行。

### 2. 使用 clickhouse-client
```bash
# 连接到集群
docker exec -it clickhouse-server-1 clickhouse-client --host clickhouse-server-1 --port 9000

# 执行 SQL 文件
docker exec -it clickhouse-server-1 clickhouse-client --queries-file /path/to/01_mergetree_engines.sql
```

## 表引擎对比

| 引擎 | 用途 | 性能 | 支持索引 | 支持分区 | 支持复制 | 主要特性 |
|------|------|------|----------|----------|----------|----------|
| MergeTree | 通用 OLAP | 高 | ✅ | ✅ | ❌ | 基础引擎 |
| ReplacingMergeTree | 去重 | 高 | ✅ | ✅ | ❌ | 自动去重 |
| SummingMergeTree | 预聚合 | 高 | ✅ | ✅ | ❌ | 自动求和 |
| AggregatingMergeTree | 高级聚合 | 高 | ✅ | ✅ | ❌ | 自定义聚合 |
| CollapsingMergeTree | 增量更新 | 中 | ✅ | ✅ | ❌ | 增量折叠 |
| ReplicatedMergeTree | 复制 | 高 | ✅ | ✅ | ✅ | 数据复制 |
| Distributed | 分布式 | 中高 | N/A | N/A | N/A | 数据分发 |
| TinyLog | 简单日志 | 低 | ❌ | ❌ | ❌ | 简单快速 |
| Log | 日志 | 中 | ❌ | ❌ | ❌ | 压缩存储 |

## 引擎选择决策树

```
开始
  │
  ├─ 需要高可用/复制？
  │   ├─ 是 → ReplicatedMergeTree 系列
  │   └─ 否 → 继续判断
  │
  ├─ 需要数据去重？
  │   ├─ 是 → ReplacingMergeTree
  │   └─ 否 → 继续判断
  │
  ├─ 需要预聚合？
  │   ├─ 简单求和 → SummingMergeTree
  │   ├─ 复杂聚合 → AggregatingMergeTree
  │   └─ 否 → 继续判断
  │
  ├─ 需要增量更新？
  │   ├─ 是 → CollapsingMergeTree
  │   └─ 否 → 继续判断
  │
  ├─ 临时/测试数据？
  │   ├─ 是 → TinyLog/Log
  │   └─ 否 → MergeTree
  │
  └─ 默认选择 → MergeTree
```

## 最佳实践

### 1. 生产环境
- **始终使用 ReplicatedMergeTree 系列**
- 配置合理的分区键
- 优化 ORDER BY 排序键
- 定期执行 OPTIMIZE TABLE

### 2. 性能优化
- 选择合适的分区粒度
- 优化排序键设计
- 使用跳数索引
- 配置合理的压缩算法

### 3. 数据管理
- 定期删除旧分区
- 控制分区数量
- 监控磁盘使用
- 合理配置 TTL

### 4. 查询优化
- 利用分区剪枝
- 使用 PREWHERE
- 避免 SELECT *
- 合理使用 LIMIT

## 常见问题

### Q: 什么时候用 MergeTree，什么时候用 ReplicatedMergeTree？
A: 生产环境建议始终使用 ReplicatedMergeTree，测试环境可以使用 MergeTree。

### Q: 如何选择分区键？
A: 选择查询中常用的过滤条件，通常按时间（月/日）分区。

### Q: ReplacingMergeTree 真的去重吗？
A: 不立即去重，需要在查询时使用 FINAL 或手动 OPTIMIZE。

### Q: Distributed 表存储数据吗？
A: Distributed 表本身不存储数据，只是查询路由层。

### Q: Log 系列和 MergeTree 系列的区别？
A: Log 系列简单快速但不支持索引和分区，适合小数据量。

## 相关资源

- 官方文档: https://clickhouse.com/docs/en/engines/table-engines
- MergeTree 家族: https://clickhouse.com/docs/en/engines/table-engines/mergetree-family
- 日志引擎: https://clickhouse.com/docs/en/engines/table-engines/log-family
- 集成引擎: https://clickhouse.com/docs/en/engines/table-engines/integrations
