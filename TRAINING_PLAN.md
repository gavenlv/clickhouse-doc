# ClickHouse 从 0 到专家培训计划（12 周）

> 本培训计划配合 [ClickHouse 从 0 到专家培养教程](./README.md)，按 4 阶段 14 章系统化培养生产级 ClickHouse 专家。
> 集群：treasurycluster（CH 25.12.1.649，clickhouse-server-1: 8123/9000，clickhouse-server-2: 8124/9001）

## 重整说明（2026-08-02）

本教程正在重整中（详见 [重整计划](./.trae/documents/clickhouse-tutorial-reorg-plan.md)）。当前目录仍为旧编号，本培训计划按**目标 14 章结构**组织学习路径，每个学习单元标注：

- **目标章节**：重整后的新章节名（如 `02-principles`）
- **当前文件**：当前实际可读的文件路径（如 `16-principle/README.md`），重命名在对应 R 批次执行
- **状态**：✅ 已细化 / ⬜ 待细化 / 🔄 重整中

---

## 培训路线图

```
入门阶段（第 1-2 周）— 章节目标 00-02
  目标：能独立部署集群、建表、解释列存原理
  考核：理论 30min + 实操（部署/建表/复制验证），正确率 > 80%

进阶阶段（第 3-6 周）— 章节目标 03-07
  目标：能选型引擎、设计 schema、用 MV/字典、做数据变更
  考核：理论 45min + 实操（选型/schema/MV/变更），正确率 > 75%

高级阶段（第 7-10 周）— 章节目标 08-11
  目标：能优化慢查询、设计分布式架构、配置安全、监控运维
  考核：理论 45min + 实操（优化/分布式/安全/监控），正确率 > 70%

专家阶段（第 11-12 周）— 章节目标 12-15
  目标：能排查疑难故障、设计端到端方案、做容量规划
  考核：架构答辩 1h + 故障注入演练 + 端到端方案设计（3 天）
```

---

## 阶段一：入门（第 1-2 周）

### 第 1 周：部署集群与第一个表

**学习目标**：部署 2 副本 + 3 Keeper 集群，理解 Keeper Raft 共识，创建第一张复制表。

| 天 | 主题 | 目标章节 | 当前文件 | 状态 |
|----|------|----------|----------|------|
| Day 1 | 集群架构与部署 | 00-infra | [00-infra/README.md](./00-infra/README.md) | ⬜ |
| Day 2 | Keeper 原理与 Raft 共识 | 00-infra | [00-infra/README.md](./00-infra/README.md) | ⬜ |
| Day 3 | 基础 SQL 操作 | 01-getting-started | [01-base/01_basic_operations.sql](./01-base/01_basic_operations.sql) | ⬜ |
| Day 4 | 什么是 ClickHouse / OLAP 定位 | 01-getting-started | [01-understanding-clickhouse/README.md](./01-understanding-clickhouse/README.md) | ⬜ |
| Day 5 | 列式存储基础 | 01-getting-started | [01-understanding-clickhouse/02_column_oriented.sql](./01-understanding-clickhouse/02_column_oriented.sql) | ⬜ |

**实操任务**：
1. 启动集群，验证 5 个容器 healthy
2. 通过 Play UI 执行 `SELECT version()`
3. 创建一张 `MergeTree` 表并插入 100 行数据

### 第 2 周：复制表与核心原理

**学习目标**：理解复制表机制、列存压缩、稀疏索引、向量化执行。

| 天 | 主题 | 目标章节 | 当前文件 | 状态 |
|----|------|----------|----------|------|
| Day 6-7 | 复制表（ReplicatedMergeTree） | 01-getting-started | [01-base/02_replicated_tables.sql](./01-base/02_replicated_tables.sql) | ⬜ |
| Day 8 | 分布式表入门 | 01-getting-started | [01-base/03_distributed_tables.sql](./01-base/03_distributed_tables.sql) | ⬜ |
| Day 9 | 列存与压缩原理 | 02-principles | [16-principle/README.md](./16-principle/README.md) | ✅ |
| Day 10 | 稀疏索引与 mark 机制 | 02-principles | [16-principle/02_storage_indexes.sql](./16-principle/02_storage_indexes.sql) | ✅ |
| Day 11 | 向量化执行与查询管道 | 02-principles | [16-principle/06_query_execution.md](./16-principle/06_query_execution.md) | ✅ |
| Day 12 | MergeTree 与 Part 生命周期 | 02-principles | [16-principle/03_mergetree.sql](./16-principle/03_mergetree.sql) | ✅ |
| Day 13 | 复制与分片原理 | 02-principles | [16-principle/07_replication.md](./16-principle/07_replication.md) + [16-principle/08_sharding.sql](./16-principle/08_sharding.sql) | ✅ |
| Day 14 | 阶段考核 + 复习 | — | — | — |

**阶段一考核**：
- 理论 30 分钟（列存原理、稀疏索引、Raft 共识、复制语义）
- 实操：部署集群 → 创建复制表 → 插入数据 → 验证副本同步 → 创建分布式表查询

---

## 阶段二：进阶（第 3-6 周）

### 第 3 周：数据类型与表引擎

**学习目标**：掌握全部数据类型选型，理解 MergeTree 家族 6 种变体的本质差异。

| 天 | 主题 | 目标章节 | 当前文件 | 状态 |
|----|------|----------|----------|------|
| Day 15 | 数值类型与 Decimal | 03-data-types | [05-data-type/01_numeric_types.md](./05-data-type/01_numeric_types.md) | ⬜ |
| Day 16 | 字符串与 LowCardinality | 03-data-types | [05-data-type/02_string_types.md](./05-data-type/02_string_types.md) | ⬜ |
| Day 17 | 日期时间类型 | 03-data-types | [10-date-update/01_date_time_types.md](./10-date-update/01_date_time_types.md) | ⬜ |
| Day 18-19 | MergeTree 家族 6 变体 | 04-engines | [03-engines/01_mergetree_engines.sql](./03-engines/01_mergetree_engines.sql) | ✅ |
| Day 20 | 复制引擎与 Keeper 路径 | 04-engines | [03-engines/02_replicated_engines.sql](./03-engines/02_replicated_engines.sql) | ✅ |
| Day 21 | Log 家族与特殊引擎 | 04-engines | [03-engines/03_log_engines.sql](./03-engines/03_log_engines.sql) + [03-engines/05_special_engines.sql](./03-engines/05_special_engines.sql) | ✅ |

**实操任务**：
1. 为"用户行为日志"场景选型数据类型（含 LowCardinality 优化）
2. 为"订单去重"场景选型引擎（ReplacingMergeTree vs CollapsingMergeTree）
3. 阅读 [03-engines/06_engine_selection_guide.md](./03-engines/06_engine_selection_guide.md) 完成选型决策练习 ✅

### 第 4 周：函数与查询

**学习目标**：掌握标量/聚合/聚合状态函数，理解 sumState/sumMerge 原理，能用窗口函数做时序分析。

| 天 | 主题 | 目标章节 | 当前文件 | 状态 |
|----|------|----------|----------|------|
| Day 22 | 标量函数全集 | 05-functions | [04-functions/01_basic_functions_examples.sql](./04-functions/01_basic_functions_examples.sql) | ✅ |
| Day 23 | 聚合函数与聚合状态（sumState/sumMerge） | 05-functions | [04-functions/README.md](./04-functions/README.md) | ✅ |
| Day 24 | AggregatingMergeTree 配合 *State/*Merge | 05-functions | [04-functions/01_basic_functions_examples.sql](./04-functions/01_basic_functions_examples.sql) | ✅ |
| Day 25 | 窗口函数与窗口帧 | 05-functions | [04-functions/02_window_functions_examples.sql](./04-functions/02_window_functions_examples.sql) | ✅ |
| Day 26 | 日期时间函数 | 05-functions | [10-date-update/02_date_time_functions.md](./10-date-update/02_date_time_functions.md) | ⬜ |
| Day 27 | 时区处理与 DateTime64 | 05-functions | [10-date-update/03_time_zones.md](./10-date-update/03_time_zones.md) | ⬜ |
| Day 28 | 复习 + 阶段测验 | — | — | — |

### 第 5 周：数据建模

**学习目标**：掌握宽表 vs 星型 schema 取舍，能用物化视图与字典加速查询。

> **注**：`06-modeling` 为重整计划 R5 新建章节，当前内容散落在多个章节。下表标注当前可读文件。

| 天 | 主题 | 目标章节 | 当前文件 | 状态 |
|----|------|----------|----------|------|
| Day 29 | 宽表 vs 星型 schema | 06-modeling | [14-use-case/01_schema_ddl.sql](./14-use-case/01_schema_ddl.sql) | ⬜ |
| Day 30 | 主键设计与 ORDER BY | 06-modeling | [11-performance/02_primary_indexes.md](./11-performance/02_primary_indexes.md) | ⬜ |
| Day 31 | 物化视图（MaterializedView） | 06-modeling | [03-engines/05_special_engines.sql](./03-engines/05_special_engines.sql)（MV 部分） | ✅ |
| Day 32 | 字典（Dictionary） | 06-modeling | [03-engines/05_special_engines.sql](./03-engines/05_special_engines.sql)（字典部分） | ✅ |
| Day 33 | 时间序列建模 | 06-modeling | [10-date-update/07_time_series.md](./10-date-update/07_time_series.md) | ⬜ |
| Day 34 | 实时数仓分层（ODS/DWD/DWS/ADS） | 06-modeling | [20-flink-clickhouse-superset/02_clickhouse_modeling.md](./20-flink-clickhouse-superset/02_clickhouse_modeling.md) | ⬜ |
| Day 35 | 复习 + 建模实战 | — | — | — |

### 第 6 周：数据变更

**学习目标**：掌握 INSERT 优化、Mutation、轻量删除、TTL、异步插入。

> **注**：`07-data-mutation` 为重整计划 R3 合并章节（09-data-deletion + 11-data-update）。当前两个章节都可读。

| 天 | 主题 | 目标章节 | 当前文件 | 状态 |
|----|------|----------|----------|------|
| Day 36 | INSERT 优化与批量插入 | 07-data-mutation | [11-performance/06_batch_inserts.md](./11-performance/06_batch_inserts.md) | ⬜ |
| Day 37 | Mutation（ALTER UPDATE/DELETE） | 07-data-mutation | [11-data-update/02_mutation_updates.md](./11-data-update/02_mutation_updates.md) | ⬜ |
| Day 38 | 轻量级 DELETE/UPDATE | 07-data-mutation | [11-data-update/03_lightweight_updates.md](./11-data-update/03_lightweight_updates.md) + [09-data-deletion/04_lightweight_deletion.md](./09-data-deletion/04_lightweight_deletion.md) | ⬜ |
| Day 39 | 分区操作（DROP/ATTACH/DETACH） | 07-data-mutation | [09-data-deletion/02_partition_deletion.md](./09-data-deletion/02_partition_deletion.md) | ⬜ |
| Day 40 | TTL 自动过期 | 07-data-mutation | [09-data-deletion/03_ttl.md](./09-data-deletion/03_ttl.md) | ⬜ |
| Day 41 | 异步插入（async_insert） | 07-data-mutation | [11-performance/07_async_inserts.md](./11-performance/07_async_inserts.md) | ⬜ |
| Day 42 | 阶段二考核 + 复习 | — | — | — |

**阶段二考核**：
- 理论 45 分钟（引擎选型、聚合状态、物化视图、Mutation 机制、TTL）
- 实操：为电商场景设计 schema → 选型引擎 → 建物化视图 → 做 Mutation 更新 → 配置 TTL

---

## 阶段三：高级（第 7-10 周）

### 第 7 周：性能优化

**学习目标**：掌握查询优化、索引、PREWHERE、Projections、JOIN 策略。

| 天 | 主题 | 目标章节 | 当前文件 | 状态 |
|----|------|----------|----------|------|
| Day 43 | 查询优化总览 | 08-performance | [11-performance/01_query_optimization.md](./11-performance/01_query_optimization.md) | ⬜ |
| Day 44 | 主键索引与 mark 机制 | 08-performance | [11-performance/02_primary_indexes.md](./11-performance/02_primary_indexes.md) | ⬜ |
| Day 45 | 分区策略 | 08-performance | [11-performance/03_partitioning.md](./11-performance/03_partitioning.md) | ⬜ |
| Day 46 | 跳数索引（5 种类型） | 08-performance | [11-performance/04_skipping_indexes.md](./11-performance/04_skipping_indexes.md) | ⬜ |
| Day 47 | PREWHERE 优化 | 08-performance | [11-performance/05_prewhere.md](./11-performance/05_prewhere.md) | ⬜ |
| Day 48 | 数据类型与 Schema 优化 | 08-performance | [11-performance/09_data_types.md](./11-performance/09_data_types.md) | ⬜ |
| Day 49 | Profiling 与 Analyzer | 08-performance | [11-performance/12_analyzer.md](./11-performance/12_analyzer.md) + [11-performance/11_profiling.md](./11-performance/11_profiling.md) | ⬜ |

### 第 8 周：分布式架构与安全

**学习目标**：理解 Keeper Raft、分片键设计、两阶段聚合、认证授权、行级安全。

| 天 | 主题 | 目标章节 | 当前文件 | 状态 |
|----|------|----------|----------|------|
| Day 50 | Keeper 内部与 Raft 共识 | 09-distributed | [00-infra/README.md](./00-infra/README.md)（Keeper 部分） | ⬜ |
| Day 51 | 分片与分布式表 | 09-distributed | [16-principle/08_sharding.sql](./16-principle/08_sharding.sql) | ✅ |
| Day 52 | 两阶段聚合（sumState/sumMerge） | 09-distributed | [16-principle/README.md](./16-principle/README.md)（分片聚合部分） | ✅ |
| Day 53 | 认证方法（密码/SSL/LDAP） | 10-security | [12-security-authentication/01_authentication_methods.md](./12-security-authentication/01_authentication_methods.md) | ⬜ |
| Day 54 | RBAC（用户/角色/权限） | 10-security | [12-security-authentication/02_rbac.md](./12-security-authentication/02_rbac.md) | ⬜ |
| Day 55 | 行级安全（RLS） | 10-security | [12-security-authentication/04_row_level_security.md](./12-security-authentication/04_row_level_security.md) | ⬜ |
| Day 56 | 复习 + 实操 | — | — | — |

### 第 9 周：监控与备份

**学习目标**：掌握系统表监控、告警、Prometheus 集成、BACKUP/RESTORE。

> **重要变更**：备份方案从旧 `ALTER TABLE ... FREEZE` 升级为 `BACKUP/RESTORE` SQL 命令（CH 22.x+ 推荐）。

| 天 | 主题 | 目标章节 | 当前文件 | 状态 |
|----|------|----------|----------|------|
| Day 57 | 系统表监控总览 | 11-monitoring-ops | [08-information-schema/README.md](./08-information-schema/README.md) | ⬜ |
| Day 58 | 查询监控与 query_thread_log | 11-monitoring-ops | [08-information-schema/07_queries_processes.md](./08-information-schema/07_queries_processes.md) | ⬜ |
| Day 59 | 副本与 Merge 监控 | 11-monitoring-ops | [08-information-schema/05_clusters_replicas.md](./08-information-schema/05_clusters_replicas.md) + [08-information-schema/06_merges_mutations.md](./08-information-schema/06_merges_mutations.md) | ⬜ |
| Day 60 | 告警配置 | 11-monitoring-ops | [13-monitor/06_alerting.md](./13-monitor/06_alerting.md) + [06-admin/MONITORING_ALERTING_GUIDE.md](./06-admin/MONITORING_ALERTING_GUIDE.md) | ⬜ |
| Day 61 | BACKUP/RESTORE 备份恢复 | 11-monitoring-ops | [06-admin/BACKUP_RECOVERY_GUIDE.md](./06-admin/BACKUP_RECOVERY_GUIDE.md) | ⬜ |
| Day 62 | 日常维护 | 11-monitoring-ops | [06-admin/ROUTINE_MAINTENANCE_GUIDE.md](./06-admin/ROUTINE_MAINTENANCE_GUIDE.md) | ⬜ |
| Day 63 | 复习 + 实操 | — | — | — |

**实操任务**：
1. 配置 `SET log_query_threads = 1`，用 `system.query_thread_log` 分析慢查询
2. 执行 `BACKUP TABLE ... TO Disk('backups', '...')` 并验证恢复
3. 设置 TTL 自动过期并监控

### 第 10 周：阶段三考核

| 天 | 主题 | 目标章节 | 当前文件 | 状态 |
|----|------|----------|----------|------|
| Day 64 | 硬件调优与缓存 | 08-performance | [11-performance/14_hardware_tuning.md](./11-performance/14_hardware_tuning.md) | ⬜ |
| Day 65 | 常见查询模式优化 | 08-performance | [11-performance/10_common_patterns.md](./11-performance/10_common_patterns.md) | ⬜ |
| Day 66 | 集群管理 | 11-monitoring-ops | [06-admin/cluster_admin.sql](./06-admin/cluster_admin.sql) | ⬜ |
| Day 67-68 | 阶段三考核 | — | — | — |
| Day 69-70 | 补漏 + 复习 | — | — | — |

**阶段三考核**：
- 理论 45 分钟（查询优化、分布式、安全、监控、备份）
- 实操：优化一个慢查询 → 设计分布式架构 → 配置 RBAC → 设置监控告警 → 执行备份恢复

---

## 阶段四：专家（第 11-12 周）

### 第 11 周：故障排查与系统集成

**学习目标**：能排查疑难故障，设计端到端实时分析方案。

| 天 | 主题 | 目标章节 | 当前文件 | 状态 |
|----|------|----------|----------|------|
| Day 71 | 连接问题诊断 | 12-troubleshooting | [07-troubleshooting/01_connection_issues.md](./07-troubleshooting/01_connection_issues.md) | ⬜ |
| Day 72 | 性能问题诊断 | 12-troubleshooting | [07-troubleshooting/02_performance_issues.md](./07-troubleshooting/02_performance_issues.md) | ⬜ |
| Day 73 | 故障排查指南 | 12-troubleshooting | [06-admin/TROUBLESHOOTING_GUIDE.md](./06-admin/TROUBLESHOOTING_GUIDE.md) | ⬜ |
| Day 74 | Kafka 集成 | 14-integration | [03-engines/04_integration_engines.sql](./03-engines/04_integration_engines.sql)（Kafka 部分） | ✅ |
| Day 75 | Flink + ClickHouse | 14-integration | [20-flink-clickhouse-superset/03_flink_clickhouse_sink.md](./20-flink-clickhouse-superset/03_flink_clickhouse_sink.md) | ⬜ |
| Day 76 | Superset 集成 | 14-integration | [14-use-case/06_superset_integration.sql](./14-use-case/06_superset_integration.sql) | ⬜ |
| Day 77 | 大规模批量导入 | 14-integration | [15-high-performance-bulk-import/README.md](./15-high-performance-bulk-import/README.md) | ⬜ |

### 第 12 周：最佳实践与专家考核

| 天 | 主题 | 目标章节 | 当前文件 | 状态 |
|----|------|----------|----------|------|
| Day 78 | Schema 设计最佳实践 | 15-best-practices | [17-best-practices/01_schema_design.sql](./17-best-practices/01_schema_design.sql) | ⬜ |
| Day 79 | 查询优化最佳实践 | 15-best-practices | [17-best-practices/03_query_optimization.sql](./17-best-practices/03_query_optimization.sql) | ⬜ |
| Day 80 | 常见错误与反模式 | 15-best-practices | [17-best-practices/02_common_mistakes.sql](./17-best-practices/02_common_mistakes.sql) | ⬜ |
| Day 81 | 端到端方案设计（开始） | — | [20-flink-clickhouse-superset/README.md](./20-flink-clickhouse-superset/README.md) | ⬜ |
| Day 82-83 | 端到端方案设计（进行） | — | — | — |
| Day 84 | 专家考核：架构答辩 | — | — | — |

**阶段四考核（专家级）**：
1. **架构答辩** 1 小时：设计一个日均 10 亿行的实时分析系统（含容量规划、容灾、监控）
2. **故障注入演练**：模拟 Keeper 脑裂、副本宕机、磁盘满，演练恢复
3. **端到端方案设计** 3 天：Flink → ClickHouse → Superset 完整方案，含 schema/优化/监控/SLA

---

## 学习资源

### 已细化章节（专家级深度标杆，优先阅读）
- ✅ [04-functions/README.md](./04-functions/README.md) — 函数与聚合状态
- ✅ [16-principle/README.md](./16-principle/README.md) — 核心原理
- ✅ [03-engines/README.md](./03-engines/README.md) — 表引擎与选型

### 重整计划与进度
- [重整计划文档](./.trae/documents/clickhouse-tutorial-reorg-plan.md)
- [进度追踪](./PROGRESS.md)

### 外部资源
- [ClickHouse 官方文档](https://clickhouse.com/docs)
- [ClickHouse GitHub](https://github.com/ClickHouse/ClickHouse)
- [ClickHouse 博客](https://clickhouse.com/blog)

---

## 学习建议

### 给初学者
1. **严格按周次推进**：不要跳章，每章建立在前一章基础上
2. **动手实操**：每个 SQL 都在集群上执行，不要只读
3. **理解原理**：遇到问题先回到 02-principles 章节找原理依据

### 给有经验者
1. **跳读入门章**：直接从 04-engines 或 08-performance 开始
2. **重点读标杆章**：04-functions/16-principle/03-engines 已达专家深度
3. **做专家考核**：直接挑战阶段四的架构答辩与故障注入

### 给培训组织者
1. **按阶段分班**：入门/进阶/高级/专家四个班次
2. **阶段考核淘汰**：每阶段末考核，未通过者重修
3. **专家考核实战**：架构答辩 + 故障注入 + 端到端方案，三选二通过

---

## 培训总结

完成本培训后，学员应能：

| 能力维度 | 入门阶段后 | 进阶阶段后 | 高级阶段后 | 专家阶段后 |
|----------|-----------|-----------|-----------|-----------|
| 集群部署 | ✅ 独立部署 | — | — | — |
| 建表查询 | ✅ 基础 SQL | ✅ 复杂 schema | — | — |
| 引擎选型 | — | ✅ 6 种 MergeTree | — | — |
| 性能优化 | — | ✅ 基础索引 | ✅ 深度优化 | — |
| 分布式架构 | — | — | ✅ 分片/副本 | — |
| 安全配置 | — | — | ✅ RBAC/RLS | — |
| 监控运维 | — | — | ✅ 告警/备份 | — |
| 故障排查 | — | — | — | ✅ 疑难故障 |
| 架构设计 | — | — | — | ✅ 端到端方案 |
| 容量规划 | — | — | — | ✅ 容量预估 |

---

## 附录：CH 25.12 兼容性注意事项

> 培训中遇到以下问题时的应对方案（基于批次 1-3 的验证经验）：

| 问题 | 原因 | 解决 |
|------|------|------|
| `system.query_log` 不存在 | 配置禁用 | 改用 `system.query_thread_log`，或恢复 `<query_log>` 配置 |
| `system.tables` 列名 `table` 报错 | 25.x 重命名 | 改用 `name` 列 |
| `mutation_version` 列不存在 | 25.x 重命名 | 改用 `data_version` |
| `ttl_info` 列不存在 | 25.x 重命名 | 改用 `delete_ttl_info_min/max` |
| INSERT 内联注释报错 | 解析器限制 | 注释移到 INSERT 语句上方 |
| CollapsingMergeTree sign 用负值 | 误解机制 | sign=-1 行用**旧值镜像**，非负值 |
| File 引擎路径找不到 | user_files_path 限制 | File 引擎加 `path` 参数 |
| Join 引擎 ON CLUSTER 报错 | 分布式类型冲突 | 移除 ON CLUSTER，用 `joinGet()` |
| ReplicatedMergeTree ZK 路径冲突 | 跨库同名表 | ZK 路径含库名或表名唯一化 |
