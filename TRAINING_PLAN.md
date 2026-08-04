# ClickHouse 从 0 到专家培训计划（12 周）

> 本培训计划配合 [ClickHouse 从 0 到专家培养教程](./README.md)，按 4 阶段 14 章系统化培养生产级 ClickHouse 专家。
> 集群：treasurycluster（CH 25.12.1.649，clickhouse-server-1: 8123/9000，clickhouse-server-2: 8124/9001）

## 重整说明（2026-08-04）

本教程已完成重整（R0-R16，详见 [重整计划](./.trae/documents/clickhouse-tutorial-reorg-plan.md) 与 [进度追踪](./PROGRESS.md)）。目录已全部重命名为新编号（`git mv` 保留历史），旧内容归档至 `_legacy/`。本培训计划按**目标 14 章结构**组织学习路径，每个学习单元标注：

- **目标章节**：重整后的新章节名（如 `02-principles`）
- **当前文件**：当前实际存在的文件路径（新编号为准）
- **状态**：✅ 已完成 / ⬜ 待集群验证（文件已就位，SQL 待 Docker 恢复后执行）

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
| Day 1 | 集群架构与部署 | 00-infra | [00-infra/README.md](./00-infra/README.md) | ✅ |
| Day 2 | Keeper 原理与 Raft 共识 | 00-infra | [00-infra/README.md](./00-infra/README.md) | ✅ |
| Day 3 | 基础 SQL 操作 | 01-getting-started | [01-getting-started/04_basic_sql.sql](./01-getting-started/04_basic_sql.sql) | ⬜ |
| Day 4 | 什么是 ClickHouse / OLAP 定位 | 01-getting-started | [01-getting-started/01_what_is_clickhouse.sql](./01-getting-started/01_what_is_clickhouse.sql) | ⬜ |
| Day 5 | 列式存储基础 | 01-getting-started | [01-getting-started/02_column_oriented.sql](./01-getting-started/02_column_oriented.sql) | ⬜ |

**实操任务**：
1. 启动集群，验证 5 个容器 healthy
2. 通过 Play UI 执行 `SELECT version()`
3. 创建一张 `MergeTree` 表并插入 100 行数据

### 第 2 周：复制表与核心原理

**学习目标**：理解复制表机制、列存压缩、稀疏索引、向量化执行。

| 天 | 主题 | 目标章节 | 当前文件 | 状态 |
|----|------|----------|----------|------|
| Day 6-7 | 复制表（ReplicatedMergeTree） | 01-getting-started | [01-getting-started/06_first_replicated_table.sql](./01-getting-started/06_first_replicated_table.sql) + [01-getting-started/08_replicated_tables.sql](./01-getting-started/08_replicated_tables.sql) | ⬜ |
| Day 8 | 分布式表入门 | 01-getting-started | [01-getting-started/09_distributed_tables.sql](./01-getting-started/09_distributed_tables.sql) | ⬜ |
| Day 9 | 列存与压缩原理 | 02-principles | [02-principles/README.md](./02-principles/README.md) + [02-principles/04_compression.md](./02-principles/04_compression.md) | ✅ |
| Day 10 | 稀疏索引与 mark 机制 | 02-principles | [02-principles/05_indexing.md](./02-principles/05_indexing.md) | ✅ |
| Day 11 | 向量化执行与查询管道 | 02-principles | [02-principles/06_query_execution.md](./02-principles/06_query_execution.md) | ✅ |
| Day 12 | MergeTree 与 Part 生命周期 | 02-principles | [02-principles/03_mergetree.sql](./02-principles/03_mergetree.sql) | ✅ |
| Day 13 | 复制与分片原理 | 02-principles | [02-principles/07_replication.md](./02-principles/07_replication.md) + [02-principles/08_sharding.sql](./02-principles/08_sharding.sql) | ✅ |
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
| Day 15 | 数值类型与 Decimal | 03-data-types | [03-data-types/01_numeric_types.md](./03-data-types/01_numeric_types.md) | ✅ |
| Day 16 | 字符串与 LowCardinality | 03-data-types | [03-data-types/02_string_types.md](./03-data-types/02_string_types.md) | ✅ |
| Day 17 | 日期时间类型与函数 | 03-data-types | [03-data-types/03_date_time_types.sql](./03-data-types/03_date_time_types.sql) | ⬜ |
| Day 18-19 | MergeTree 家族 6 变体 | 04-engines | [04-engines/01_mergetree_engines.sql](./04-engines/01_mergetree_engines.sql) | ✅ |
| Day 20 | 复制引擎与 Keeper 路径 | 04-engines | [04-engines/02_replicated_engines.sql](./04-engines/02_replicated_engines.sql) | ✅ |
| Day 21 | Log 家族与特殊引擎 | 04-engines | [04-engines/03_log_engines.sql](./04-engines/03_log_engines.sql) + [04-engines/05_special_engines.sql](./04-engines/05_special_engines.sql) | ✅ |

**实操任务**：
1. 为"用户行为日志"场景选型数据类型（含 LowCardinality 优化）
2. 为"订单去重"场景选型引擎（ReplacingMergeTree vs CollapsingMergeTree）
3. 阅读 [04-engines/06_engine_selection_guide.md](./04-engines/06_engine_selection_guide.md) 完成选型决策练习 ✅

### 第 4 周：函数与查询

**学习目标**：掌握标量/聚合/聚合状态函数，理解 sumState/sumMerge 原理，能用窗口函数做时序分析。

| 天 | 主题 | 目标章节 | 当前文件 | 状态 |
|----|------|----------|----------|------|
| Day 22 | 标量函数全集 | 05-functions | [05-functions/01_basic_functions_examples.sql](./05-functions/01_basic_functions_examples.sql) | ✅ |
| Day 23 | 聚合函数与聚合状态（sumState/sumMerge） | 05-functions | [05-functions/README.md](./05-functions/README.md) §3 | ✅ |
| Day 24 | AggregatingMergeTree 配合 *State/*Merge | 05-functions | [05-functions/03_aggregate_combinators.sql](./05-functions/03_aggregate_combinators.sql) | ✅ |
| Day 25 | 窗口函数与窗口帧 | 05-functions | [05-functions/02_window_functions_examples.sql](./05-functions/02_window_functions_examples.sql) | ✅ |
| Day 26 | 日期时间函数与转换 | 05-functions | [05-functions/01_basic_functions_examples.sql](./05-functions/01_basic_functions_examples.sql) §5（日期时间函数） | ✅ |
| Day 27 | 时区处理与 DateTime64 | 03-data-types | [03-data-types/03_date_time_types.sql](./03-data-types/03_date_time_types.sql) §4（时区） | ⬜ |
| Day 28 | 复习 + 阶段测验 | — | — | — |

### 第 5 周：数据建模

**学习目标**：掌握宽表 vs 星型 schema 取舍，能用物化视图与字典加速查询。

| 天 | 主题 | 目标章节 | 当前文件 | 状态 |
|----|------|----------|----------|------|
| Day 29 | 宽表 vs 星型 schema | 06-modeling | [06-modeling/01_wide_vs_star.sql](./06-modeling/01_wide_vs_star.sql) | ✅ |
| Day 30 | 主键设计与 ORDER BY | 06-modeling | [06-modeling/02_primary_key_design.sql](./06-modeling/02_primary_key_design.sql) | ✅ |
| Day 31 | 物化视图（MaterializedView） | 06-modeling | [06-modeling/03_materialized_views.sql](./06-modeling/03_materialized_views.sql) | ✅ |
| Day 32 | 字典（Dictionary） | 06-modeling | [06-modeling/04_dictionaries.sql](./06-modeling/04_dictionaries.sql) | ✅ |
| Day 33 | 时间序列建模 | 06-modeling | [06-modeling/05_time_series.sql](./06-modeling/05_time_series.sql) | ✅ |
| Day 34 | 实时数仓分层（ODS/DWD/DWS/ADS） | 06-modeling | [06-modeling/07_realtime_modeling.sql](./06-modeling/07_realtime_modeling.sql) + [14-integration/06_flink_clickhouse_modeling.sql](./14-integration/06_flink_clickhouse_modeling.sql) | ✅ |
| Day 35 | 复习 + 建模实战 | — | — | — |

### 第 6 周：数据变更

**学习目标**：掌握 INSERT 优化、Mutation、轻量删除、TTL、异步插入。

> **注**：`07-data-mutation` 为重整计划 R3 合并章节（09-data-deletion + 11-data-update），已统一为一个完整 SQL 文件覆盖全部变更手段。

| 天 | 主题 | 目标章节 | 当前文件 | 状态 |
|----|------|----------|----------|------|
| Day 36 | INSERT 优化与批量插入 | 07-data-mutation | [07-data-mutation/01_all_data_mutation.sql](./07-data-mutation/01_all_data_mutation.sql) §1-2 | ✅ |
| Day 37 | Mutation（ALTER UPDATE/DELETE） | 07-data-mutation | [07-data-mutation/01_all_data_mutation.sql](./07-data-mutation/01_all_data_mutation.sql) §3 | ✅ |
| Day 38 | 轻量级 DELETE/UPDATE | 07-data-mutation | [07-data-mutation/01_all_data_mutation.sql](./07-data-mutation/01_all_data_mutation.sql) §4 | ✅ |
| Day 39 | 分区操作（DROP/ATTACH/DETACH） | 07-data-mutation | [07-data-mutation/01_all_data_mutation.sql](./07-data-mutation/01_all_data_mutation.sql) §5 | ✅ |
| Day 40 | TTL 自动过期 | 07-data-mutation | [07-data-mutation/01_all_data_mutation.sql](./07-data-mutation/01_all_data_mutation.sql) §6 | ✅ |
| Day 41 | 异步插入（async_insert） | 07-data-mutation | [07-data-mutation/01_all_data_mutation.sql](./07-data-mutation/01_all_data_mutation.sql) §7 | ✅ |
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
| Day 43 | 查询优化总览 | 08-performance | [08-performance/01_query_optimization.md](./08-performance/01_query_optimization.md) | ✅ |
| Day 44 | 主键索引与 mark 机制 | 08-performance | [08-performance/02_primary_indexes.md](./08-performance/02_primary_indexes.md) | ✅ |
| Day 45 | 分区策略 | 08-performance | [08-performance/03_partitioning.md](./08-performance/03_partitioning.md) | ✅ |
| Day 46 | 跳数索引（5 种类型） | 08-performance | [08-performance/04_skipping_indexes.md](./08-performance/04_skipping_indexes.md) | ✅ |
| Day 47 | PREWHERE 优化 | 08-performance | [08-performance/05_prewhere_optimization.md](./08-performance/05_prewhere_optimization.md) | ✅ |
| Day 48 | 数据类型与 Schema 优化 | 08-performance | [08-performance/09_data_types.md](./08-performance/09_data_types.md) | ✅ |
| Day 49 | Profiling 与 Analyzer | 08-performance | [08-performance/12_analyzer.md](./08-performance/12_analyzer.md) + [08-performance/11_query_profiling.md](./08-performance/11_query_profiling.md) | ✅ |

### 第 8 周：分布式架构与安全

**学习目标**：理解 Keeper Raft、分片键设计、两阶段聚合、认证授权、行级安全。

| 天 | 主题 | 目标章节 | 当前文件 | 状态 |
|----|------|----------|----------|------|
| Day 50 | Keeper 内部与 Raft 共识 | 09-distributed | [09-distributed/01_keeper_internals.sql](./09-distributed/01_keeper_internals.sql) | ✅ |
| Day 51 | 分片与分布式表 | 09-distributed | [09-distributed/03_distributed_table.sql](./09-distributed/03_distributed_table.sql) + [09-distributed/05_sharding_key_design.sql](./09-distributed/05_sharding_key_design.sql) | ✅ |
| Day 52 | 两阶段聚合（sumState/sumMerge） | 09-distributed | [09-distributed/06_two_phase_aggregation.sql](./09-distributed/06_two_phase_aggregation.sql) + [09-distributed/07_global_join.sql](./09-distributed/07_global_join.sql) | ✅ |
| Day 53 | 认证方法（密码/SSL/LDAP） | 10-security | [10-security/01_authentication.md](./10-security/01_authentication.md) | ✅ |
| Day 54 | RBAC（用户/角色/权限） | 10-security | [10-security/02_user_role_management.md](./10-security/02_user_role_management.md) | ✅ |
| Day 55 | 行级安全（RLS） | 10-security | [10-security/04_row_level_security.md](./10-security/04_row_level_security.md) | ✅ |
| Day 56 | 复习 + 实操 | — | — | — |

### 第 9 周：监控与备份

**学习目标**：掌握系统表监控、告警、Prometheus 集成、BACKUP/RESTORE。

> **重要变更**：备份方案从旧 `ALTER TABLE ... FREEZE` 升级为 `BACKUP/RESTORE` SQL 命令（CH 22.x+ 推荐）；`system.query_log` 在本集群被禁用，改用 `system.query_thread_log`（`SET log_query_threads = 1`）。

| 天 | 主题 | 目标章节 | 当前文件 | 状态 |
|----|------|----------|----------|------|
| Day 57 | 系统表监控总览 | 11-monitoring-ops | [11-monitoring-ops/01_system_monitoring.sql](./11-monitoring-ops/01_system_monitoring.sql) + [13-system-tables/README.md](./13-system-tables/README.md) | ✅ |
| Day 58 | 查询监控与 query_thread_log | 11-monitoring-ops | [13-system-tables/07_queries_processes.md](./13-system-tables/07_queries_processes.md) + [13-system-tables/09_query_log_deep_dive.md](./13-system-tables/09_query_log_deep_dive.md) | ✅ |
| Day 59 | 副本与 Merge 监控 | 11-monitoring-ops | [13-system-tables/05_clusters_replicas.md](./13-system-tables/05_clusters_replicas.md) + [13-system-tables/03_partitions_parts.md](./13-system-tables/03_partitions_parts.md) | ✅ |
| Day 60 | 告警配置 | 11-monitoring-ops | [11-monitoring-ops/03_alerting.sql](./11-monitoring-ops/03_alerting.sql) | ✅ |
| Day 61 | BACKUP/RESTORE 备份恢复 | 11-monitoring-ops | [11-monitoring-ops/02_backup_recovery.sql](./11-monitoring-ops/02_backup_recovery.sql) | ✅ |
| Day 62 | 日常维护 | 11-monitoring-ops | [11-monitoring-ops/07_routine_maintenance.sql](./11-monitoring-ops/07_routine_maintenance.sql) | ✅ |
| Day 63 | 复习 + 实操 | — | — | — |

**实操任务**：
1. 配置 `SET log_query_threads = 1`，用 `system.query_thread_log` 分析慢查询
2. 执行 `BACKUP TABLE ... TO Disk('backups', '...')` 并验证恢复
3. 设置 TTL 自动过期并监控

### 第 10 周：阶段三考核

| 天 | 主题 | 目标章节 | 当前文件 | 状态 |
|----|------|----------|----------|------|
| Day 64 | 硬件调优与缓存 | 08-performance | [08-performance/14_hardware_tuning.md](./08-performance/14_hardware_tuning.md) + [08-performance/13_caching.md](./08-performance/13_caching.md) | ✅ |
| Day 65 | 常见查询模式优化 | 08-performance | [08-performance/10_common_patterns.md](./08-performance/10_common_patterns.md) | ✅ |
| Day 66 | 集群管理 | 11-monitoring-ops | [11-monitoring-ops/README.md](./11-monitoring-ops/README.md) | ✅ |
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
| Day 71 | 连接问题诊断 | 12-troubleshooting | [12-troubleshooting/01_connection_issues.md](./12-troubleshooting/01_connection_issues.md) | ✅ |
| Day 72 | 性能问题诊断 | 12-troubleshooting | [12-troubleshooting/02_performance_issues.md](./12-troubleshooting/02_performance_issues.md) | ✅ |
| Day 73 | 故障排查指南（全场景索引） | 12-troubleshooting | [12-troubleshooting/README.md](./12-troubleshooting/README.md) | ✅ |
| Day 74 | Kafka 集成 | 14-integration | [14-integration/02_kafka_engine.md](./14-integration/02_kafka_engine.md) + [14-integration/03_kafka_engine_examples.sql](./14-integration/03_kafka_engine_examples.sql) | ✅ |
| Day 75 | Flink + ClickHouse | 14-integration | [14-integration/04_flink_architecture.md](./14-integration/04_flink_architecture.md) + [14-integration/05_flink_clickhouse_sink.sql](./14-integration/05_flink_clickhouse_sink.sql) | ✅ |
| Day 76 | Superset 集成 | 14-integration | [14-integration/07_superset_dashboard.sql](./14-integration/07_superset_dashboard.sql) | ✅ |
| Day 77 | 大规模批量导入 | 14-integration | [14-integration/11_bulk_import_guide.md](./14-integration/11_bulk_import_guide.md) | ✅ |

### 第 12 周：最佳实践与专家考核

| 天 | 主题 | 目标章节 | 当前文件 | 状态 |
|----|------|----------|----------|------|
| Day 78 | Schema 设计最佳实践 | 15-best-practices | [15-best-practices/02_schema_design.sql](./15-best-practices/02_schema_design.sql) | ✅ |
| Day 79 | 查询优化最佳实践 | 15-best-practices | [15-best-practices/03_query_optimization.sql](./15-best-practices/03_query_optimization.sql) | ✅ |
| Day 80 | 常见错误与反模式 | 15-best-practices | [15-best-practices/04_common_mistakes.sql](./15-best-practices/04_common_mistakes.sql) + [15-best-practices/07_anti_patterns.md](./15-best-practices/07_anti_patterns.md) | ✅ |
| Day 81 | 端到端方案设计（开始） | — | [14-integration/15_prediction_case_study.md](./14-integration/15_prediction_case_study.md) | ✅ |
| Day 82-83 | 端到端方案设计（进行） | — | — | — |
| Day 84 | 专家考核：架构答辩 | — | — | — |

**阶段四考核（专家级）**：
1. **架构答辩** 1 小时：设计一个日均 10 亿行的实时分析系统（含容量规划、容灾、监控）
2. **故障注入演练**：模拟 Keeper 脑裂、副本宕机、磁盘满，演练恢复
3. **端到端方案设计** 3 天：Flink → ClickHouse → Superset 完整方案，含 schema/优化/监控/SLA

---

## 学习资源

### 已细化章节（全部 14 章 + 2 附录均为专家级，优先阅读）
- ✅ [01-getting-started/README.md](./01-getting-started/README.md) — 入门 13 个 SQL 全集群验证
- ✅ [02-principles/README.md](./02-principles/README.md) — 核心原理（含汇编级 SIMD/Pipeline）
- ✅ [03-data-types/README.md](./03-data-types/README.md) — 数据类型全体系
- ✅ [04-engines/README.md](./04-engines/README.md) — 表引擎与选型
- ✅ [05-functions/README.md](./05-functions/README.md) — 函数与聚合状态
- ✅ [06-modeling/README.md](./06-modeling/README.md) — 数据建模
- ✅ [07-data-mutation/README.md](./07-data-mutation/README.md) — 数据变更
- ✅ [08-performance/README.md](./08-performance/README.md) — 性能优化
- ✅ [09-distributed/README.md](./09-distributed/README.md) — 分布式架构
- ✅ [10-security/README.md](./10-security/README.md) — 安全权限
- ✅ [11-monitoring-ops/README.md](./11-monitoring-ops/README.md) — 监控运维
- ✅ [12-troubleshooting/README.md](./12-troubleshooting/README.md) — 故障排查
- ✅ [13-system-tables/README.md](./13-system-tables/README.md) — 系统表参考
- ✅ [14-integration/README.md](./14-integration/README.md) — 集成生态
- ✅ [15-best-practices/README.md](./15-best-practices/README.md) — 最佳实践
- ✅ [appendix-tech-sharing/README.md](./appendix-tech-sharing/README.md) — 附录 A 技术分享
- ✅ [appendix-blogs/README.md](./appendix-blogs/README.md) — 附录 B 博客

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
2. **重点读标杆章**：05-functions / 02-principles / 04-engines 已达专家深度
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

> 培训中遇到以下问题时的应对方案（基于批次 1-13 的验证经验）：

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
| `compressed_bytes` 列不存在 | 25.x 改名 | `column_data_compressed_bytes` |
| 函数名大小写敏感 | md5/sha1 等小写未定义 | 改为大写 MD5/SHA1/SHA256 |
| `formatDateTime('%A')` 报错 | 25.12 不支持 %A/%B | 用 dateName() 函数 |
