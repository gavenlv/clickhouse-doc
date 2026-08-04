# 系统表与元数据

ClickHouse 的 `system` 数据库是它的"驾驶舱仪表盘"——70+ 张表记录了集群的每一寸运行状态：查询性能、数据分布、合并进度、副本同步、用户权限、磁盘空间。本章从元数据入门到 query_log 专家，教你**遇到问题查哪张表、怎么查、怎么解读**。

## 本章解决什么问题

| 痛点 | 对应专题 | 一句话解答 |
|------|---------|-----------|
| **有哪些库/表/列？** | [01 数据库和表](./01_databases_tables.md) | system.databases / tables / columns 元数据三件套 |
| **表结构怎么设计的？** | [02 列与 Schema](./02_columns_schema.md) | system.columns 查看列类型/默认值/压缩 |
| **数据存在哪、分了多少块？** | [03 分区与数据块](./03_partitions_parts.md) | system.parts 是存储健康的核心 |
| **索引/投影生效了吗？** | [04 索引与投影](./04_indexes_projections.md) | EXPLAIN + system.data_skipping_indices |
| **集群节点健康吗？** | [05 集群与副本](./05_clusters_replicas.md) | system.clusters / replicas / replication_queue |
| **谁有权限？** | [06 用户与角色](./06_users_roles.md) | system.users / roles / grants / quotas |
| **现在在跑什么？** | [07 查询与进程](./07_queries_processes.md) | system.processes 实时监控 |
| **哪些 system 表可用？** | [08 系统表详解](./08_system_tables.md) | 70+ 表分类速查 |
| **查询为什么慢？** | [09 query_log 深度](./09_query_log_deep_dive.md) | **每查询的执行档案，60+ 字段解读** |
| **怎么快速诊断问题？** | [10 诊断查询库](./10_diagnostics_queries.sql) | **30+ 开箱即用的生产诊断 SQL** |

## system 表全景图

```
┌────────────────────────────────────────────────────────────────────┐
│                    ClickHouse system 表全景                        │
├────────────────────────────────────────────────────────────────────┤
│                                                                    │
│  元数据层（表结构是什么）                                           │
│  databases · tables · columns · functions · formats               │
│                                                                    │
│  数据层（数据怎么存的）                                             │
│  parts · parts_columns · detached_parts · mutations · merges      │
│                                                                    │
│  复制层（数据怎么同步的）                                           │
│  replicas · replication_queue · zookeeper · distributed_ddl_queue │
│                                                                    │
│  查询层（查询怎么执行的）                                           │
│  processes · query_log · query_thread_log · query_views_log       │
│                                                                    │
│  性能层（资源用了多少）                                             │
│  metrics · events · asynchronous_metrics · metrics_log            │
│                                                                    │
│  安全层（谁有权限）                                                 │
│  users · roles · grants · row_policies · quotas · settings_profiles│
│                                                                    │
│  存储层（磁盘够不够）                                               │
│  disks · data_skipping_indices · projection_parts · parts          │
│                                                                    │
└────────────────────────────────────────────────────────────────────┘
```

## 核心概念深度：system.parts —— 存储健康的核心

`system.parts` 是诊断**写入方式**和**存储健康**的第一张表。理解它，就理解了 ClickHouse 的存储模型：

```
一次 INSERT → 生成一个 Part（不可变数据块）
    ↓
Part 登记在 system.parts（active = 1）
    ↓
后台合并 → 小 Part 合并成大 Part
    ↓
Part 生命周期结束（active = 0，进入 .inactive 等待清理）
```

**三个关键判断**：

```sql
-- 1. active Part 数 > 300 = 写入方式有问题（单行/小批量写入）
SELECT count() FROM system.parts WHERE active = 1;

-- 2. 某个分区 Part 数 > 50 = 该分区写入太频繁
SELECT partition, count() FROM system.parts
WHERE active = 1 GROUP BY partition HAVING count() > 50;

-- 3. detached_parts 有数据 = 发生过异常分离（需要 ATTACH）
SELECT * FROM system.detached_parts;
```

## 核心概念深度：query_log —— 性能分析的唯一权威

query_log 是 R13 的核心新增（[09 全字段解读](./09_query_log_deep_dive.md)）。核心思维模型：

```
一条查询执行后，query_log 记录：

  谁查的？      user, client_hostname, client_name
  查了什么？    query, tables, columns, normalized_query_hash
  花了多久？    query_duration_ms, event_time
  读了多少？    read_rows, read_bytes
  用了多少内存？ peak_memory_usage
  怎么执行的？  thread_ids, settings, ProfileEvents
  成功了吗？    type, exception_code, exception
```

**专家技巧：`normalized_query_hash`** —— 把"字面量不同但结构相同"的查询归为一类（如 `WHERE id = 1` 和 `WHERE id = 2` 是同一条），用于发现"某个模式被高频执行"：

```sql
SELECT count() AS qty, round(sum(query_duration_ms)/1000, 2) AS total_sec, left(any(query), 150)
FROM system.query_log
WHERE type = 'QueryFinish' AND event_date = today()
GROUP BY normalized_query_hash
ORDER BY total_sec DESC LIMIT 10;
```

## 诊断方法论：问题 → 表 → 查询

```
查询慢？
  ├── system.query_log → 慢查询 Top N（耗时/读行/内存）
  ├── system.processes → 正在跑的查询（实时）
  └── EXPLAIN → 索引是否命中

写入慢/卡？
  ├── system.parts → active Part 数是否 > 300
  ├── system.merges → 合并是否排队
  ├── system.mutations → mutation 是否积压
  └── system.replicas → 副本是否落后

集群不稳定？
  ├── system.disks → 磁盘是否满
  ├── system.metrics → MemoryTracking / ReadonlyReplicas
  ├── system.replicas → is_readonly / is_session_expired
  └── system.events → 关键事件计数（Error 类）

数据不一致？
  ├── system.replicas → absolute_delay / queue_size
  ├── system.replication_queue → 复制队列
  └── system.detached_parts → 异常分离的 Part
```

## 文档导航

### 基础元数据（入门）

| 编号 | 专题 | 文件 | 类型 | 学习难度 |
|------|------|------|------|---------|
| 01 | 数据库和表 | [01_databases_tables.md](./01_databases_tables.md) | 原理文档 | 入门 |
| 02 | 列与 Schema | [02_columns_schema.md](./02_columns_schema.md) | 原理文档 | 入门 |
| 03 | 分区与数据块 | [03_partitions_parts.md](./03_partitions_parts.md) | 原理文档 | 进阶 |

### 高级元数据（进阶）

| 编号 | 专题 | 文件 | 类型 | 学习难度 |
|------|------|------|------|---------|
| 04 | 索引与投影 | [04_indexes_projections.md](./04_indexes_projections.md) | 原理文档 | 进阶 |
| 05 | 集群与副本 | [05_clusters_replicas.md](./05_clusters_replicas.md) | 原理文档 | 进阶 |
| 06 | 用户与角色 | [06_users_roles.md](./06_users_roles.md) | 原理文档 | 进阶 |

### 运行时与诊断（核心）

| 编号 | 专题 | 文件 | 类型 | 学习难度 |
|------|------|------|------|---------|
| 07 | 查询与进程 | [07_queries_processes.md](./07_queries_processes.md) | 原理文档 | 进阶 |
| 08 | 系统表详解 | [08_system_tables.md](./08_system_tables.md) | 速查文档 | 入门 |
| 09 | **query_log 深度** | [09_query_log_deep_dive.md](./09_query_log_deep_dive.md) | **专家文档** | **高级** |
| 10 | **诊断查询库** | [10_diagnostics_queries.sql](./10_diagnostics_queries.sql) | **SQL 库** | **高级** |

## 快速上手：3 步成为 system 表专家

### 第 1 步：建立元数据直觉

运行 [10_diagnostics_queries.sql](./10_diagnostics_queries.sql) 的第八部分"一键健康巡检"，从 7 项指标了解集群全貌。

### 第 2 步：掌握 parts 和 query_log

- [03 分区与数据块](./03_partitions_parts.md)：理解 Part 生命周期
- [09 query_log 深度](./09_query_log_deep_dive.md)：理解查询档案

### 第 3 步：形成诊断方法论

对照"诊断方法论"表，遇到真实问题时不慌，按表索骥查对应 system 表。

## 常见误区

| 误区 | 现实 |
|------|------|
| **"system 表都一样，随便查"** | 大部分表是实时内存视图（metrics），部分是日志表（query_log 按天分区）。用法完全不同 |
| **"query_log 是实时的"** | query_log 每 7.5 秒 flush 一次（可配），不是逐条实时写入 |
| **"active Part 越多越健康"** | active Part > 300 是写入方式出问题的信号 |
| **"detached_parts 不用管"** | 它代表异常分离的数据，可能造成数据缺失，需要 ATTACH 恢复 |
| **"system.query_log 数据无限保存"** | 默认 30 天 TTL 自动清理，需定期归档慢查询分析 |
| **"只看 query_log 就够诊断了"** | 线程级问题看 query_thread_log，视图问题看 query_views_log，各有分工 |
| **"normalized_query_hash 没用"** | 它是发现"同类查询高频执行"的利器，比逐条看 query 高效 100 倍 |

## 生产检查清单

### 日常巡检（每天）
- [ ] 运行一键健康巡检（8.1）：库/表/Parts/查询/mutation/副本
- [ ] 磁盘使用率 < 80%（system.disks）
- [ ] 慢查询 Top 20 检查（query_log）
- [ ] 副本延迟 < 60 秒（system.replicas）

### 每周
- [ ] Parts 健康：active < 300（system.parts）
- [ ] 合并队列清空检查（system.merges）
- [ ] mutation 队列无积压（system.mutations）
- [ ] 用户权限审计（system.grants）

### 每月
- [ ] 存储增长趋势分析（system.parts 按周对比）
- [ ] 慢查询模式聚合（normalized_query_hash）
- [ ] 索引命中率评估（EXPLAIN + data_skipping_indices）
- [ ] 日志表大小与清理策略复核

## 学习路径建议

```
第一天：01+02（元数据三件套）→ 03（parts 存储模型）
第二天：04+05（索引/集群）→ 06（权限审计）
第三天：07（进程）→ 08（表速查）→ 10（诊断库全跑一遍）
第四天：09（query_log 深度）→ 12 个诊断查询逐个实践
第五天：形成自己的"问题→表→查询"方法论，跑通一键巡检
```

## 相关章节

- [点击前往 15-best-practices（最佳实践与反模式）](../15-best-practices/README.md) —— 反模式诊断也用 system 表
- [点击前往 11-monitoring-ops（监控运维）](../11-monitoring-ops/README.md) —— Prometheus 采集 system 指标
- [点击前往 09-distributed（分布式架构）](../09-distributed/README.md) —— 副本/分片与 system.replicas 的关系
- [ClickHouse System Tables 官方文档](https://clickhouse.com/docs/en/operations/system-tables/overview)

---
**注意**：本章 SQL 针对 `treasurycluster` 集群（CH 25.12.1.649）。query_log 诊断查询需日志功能开启（默认开启）。
