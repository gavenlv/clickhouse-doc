# ClickHouse 教程重整计划：从 0 培养专家

> 本计划是对 [clickhouse-doc-deep-refinement-plan.md](./clickhouse-doc-deep-refinement-plan.md) 的升级。
> 旧计划聚焦"细化现有文件"，本计划聚焦"重整整个教程的结构与覆盖度"。
> 集群：treasurycluster（CH 25.12.1.649，clickhouse-server-1: 8123/9000，clickhouse-server-2: 8124/9001）

---

## 一、现状诊断（核心问题）

### 1.1 三类系统性问题

| 问题类别 | 严重度 | 典型案例 |
|----------|--------|----------|
| **目录树过时** | 极高 | 根 README 声称 01-base 含 04-09 共 6 个 sql、05-data-type 含 03-11 共 9 个 md、07-troubleshooting 含 03-10 共 8 个 md —— **全部不存在** |
| **章节编号冲突** | 高 | `01-base/` 与 `01-understanding-clickhouse/` 都用 01；`11-data-update/` 与 `11-performance/` 都用 11 |
| **内容大面积重叠** | 高 | 复制/分布式原理在 5 个章节重复；运维主题在 02-advance/06-admin/13-monitor/07-troubleshooting 4 个章节重复 |

### 1.2 重叠矩阵（去重依据）

| 重叠组 | 涉及章节 | 处理策略 |
|--------|----------|----------|
| 基础入门 | 01-base / 01-understanding-clickhouse / 18-introduction-cn / 19-introduction-en | 01-understanding 并入 01-base；18/19 降级为"分享素材"附录 |
| 原理介绍 | 16-principle / 01-understanding / 18/19-introduction | 16-principle 为唯一深度原理章，其余交叉引用 |
| 复制/分布式 | 01-base/02_03 / 03-engines/02 / 16-principle/07_08 | 03-engines 为主，01-base 仅留入门示例，16-principle 留原理 |
| 运维大杂烩 | 02-advance / 06-admin / 13-monitor / 07-troubleshooting | 02-advance 拆分合并到对应专题章，定位为"运维导航页" |
| 性能优化 | 02-advance/01 / 11-performance / 17-best-practices/03 | 统一到 11-performance，其他交叉引用 |
| Mutation/轻量操作 | 09-data-deletion / 11-data-update | **合并为单一数据变更章**（同一机制的两个方向） |
| 日期函数 | 10-date-update / 04-functions / 05-data-type | 类型归 05-data-type，函数归 04-functions，时间序列分析独立 |
| 监控 | 02-advance/03 / 06-admin/MONITORING / 13-monitor / 08-info-schema/07 | 13-monitor 为主，其他交叉引用 |
| 故障排查 | 02-advance/07 / 06-admin/TROUBLESHOOTING / 07-troubleshooting | 07-troubleshooting 为主（需补全 03-10 文件） |

### 1.3 专家级内容缺失（30+ 主题）

按重要性分组，详见第四节"补缺失清单"。

---

## 二、重整目标

### 2.1 总目标
把项目从"21 个章节、文件缺失、内容重叠、深度不一"重整为"**14 个主干章节 + 2 个附录**、文件完整、职责清晰、深度统一到专家级"的 0→专家培养教程。

### 2.2 深度标准（沿用已细化章节的标杆）
每个文件须满足 **原理+场景+对比+可运行** 四要素：
- **原理**：底层机制（如聚合状态二进制结构、稀疏索引 mark 定位、Keeper Raft 状态机）
- **场景**：什么业务场景用、为什么用
- **对比**：与替代方案对比（如 sumState vs sum、BACKUP vs FREEZE、Mutation vs 轻量删除）
- **可运行**：每个 SQL 在 clickhouse-server-1 验证零错误（CH 25.12 兼容）

### 2.3 学习路径目标
读者按章节顺序学完，达到：
- **入门（章 0-3）**：能部署集群、建表、写基础 SQL
- **进阶（章 4-7）**：能选型引擎、设计 schema、用函数/物化视图/字典
- **高级（章 8-11）**：能优化性能、设计分布式架构、保障安全、监控运维
- **专家（章 12-14 + 附录）**：能排查疑难故障、做容量规划、设计端到端方案

---

## 三、新章节结构（重编号，解决冲突）

### 3.1 主干 14 章 + 2 附录

| 新编号 | 新名称 | 旧章节来源 | 性质 | 0→专家阶段 |
|--------|--------|-----------|------|-----------|
| **00** | `00-infra` 基础设施 | 00-infra（补全） | 入门 | 入门 |
| **01** | `01-getting-started` 入门 | 01-base + 01-understanding-clickhouse（合并） | 入门 | 入门 |
| **02** | `02-principles` 核心原理 | 16-principle ✅ | 原理 | 入门 |
| **03** | `03-data-types` 数据类型 | 05-data-type（补全 03-11） | 基础 | 进阶 |
| **04** | `04-engines` 表引擎 | 03-engines ✅ | 基础 | 进阶 |
| **05** | `05-functions` 函数与查询 | 04-functions ✅ + 10-date-update 函数部分 | 基础 | 进阶 |
| **06** | `06-modeling` 数据建模 | 新建（从 TRAINING_PLAN 抽取）+ 14-use-case schema 部分 | 进阶 | 进阶 |
| **07** | `07-data-mutation` 数据变更 | 09-data-deletion + 11-data-update（合并） | 进阶 | 进阶 |
| **08** | `08-performance` 性能优化 | 11-performance + 02-advance/01 + 17-best-practices | 高级 | 高级 |
| **09** | `09-distributed` 分布式架构 | 新建 + 从 03-engines 抽取分布式深度 + 16-principle/08 | 高级 | 高级 |
| **10** | `10-security` 安全与权限 | 12-security-authentication + 02-advance/04 | 高级 | 高级 |
| **11** | `11-monitoring-ops` 监控运维 | 06-admin + 13-monitor + 02-advance/02_03_05_06 | 高级 | 高级 |
| **12** | `12-troubleshooting` 故障排查 | 07-troubleshooting（补全 03-10）+ 02-advance/07 | 专家 | 专家 |
| **13** | `13-system-tables` 系统表参考 | 08-information-schema | 专家 | 专家 |
| **14** | `14-integration` 集成与生态 | 03-engines/04_integration + 14-use-case + 20-flink + 15-bulk-import | 专家 | 专家 |
| **15** | `15-best-practices` 最佳实践与反模式 | 17-best-practices | 专家 | 专家 |
| 附录 A | `appendix-tech-sharing` 技术分享 | 18-introduction-cn + 19-introduction-en | 附录 | — |
| 附录 B | `appendix-blogs` 博客文章 | blogs | 附录 | — |

### 3.2 编号冲突解决方案

| 冲突 | 解决 |
|------|------|
| `01-base` 与 `01-understanding-clickhouse` 都用 01 | 合并为 `01-getting-started`，01-understanding 内容并入 |
| `11-data-update` 与 `11-performance` 都用 11 | 11-data-update 并入 `07-data-mutation`；11-performance 改为 `08-performance` |
| `10-date-update` 与 05-data-type 日期主题分散 | 10-date-update 拆分：类型归 03-data-types，函数归 05-functions，时间序列分析归 06-modeling |

### 3.3 不破坏已完成批次
- **04-functions（批次 1）** → 改名 `05-functions`，内容保留扩充
- **16-principle（批次 2）** → 改名 `02-principles`，内容保留扩充
- **03-engines（批次 3）** → 改名 `04-engines`，内容保留扩充；分布式深度部分抽取到 `09-distributed`，集成部分抽取到 `14-integration`

> **注**：重命名用 `git mv` 保留历史。若用户不希望大规模重命名，本计划可降级为"保留旧编号 + 在根 README 加映射表"，但编号冲突（11-vs-11）必须解决。

---

## 四、补缺失清单（专家级主题）

### 4.1 存储与索引深度（章 04/06/08 补充）
1. **Projections（投影）** — 章节归属：`08-performance` 新增 `15_projections.md`
2. **Materialized Views 深度** — 章节归属：`06-modeling` 新增 `03_materialized_views.md`（设计模式/级联 MV/MV vs Projection 取舍）
3. **Dictionaries（字典）深度** — 章节归属：`06-modeling` 新增 `04_dictionaries.md`（布局 HASHED/COMPLEX_KEY_CACHE/直接/SSD Cache 刷新策略/dictGet 性能）
4. **Index granularity 调优** — 章节归属：`08-performance/02_primary_indexes.md` 扩充
5. **Tiered storage / TTL MOVE TO DISK/S3** — 章节归属：`11-monitoring-ops` 新增 `09_tiered_storage.md`
6. **USI 索引等新类型** — 章节归属：`08-performance/04_skipping_indexes.md` 扩充

### 4.2 执行引擎深度（章 02/08 补充）
7. **向量化执行/SIMD 内部实现** — 章节归属：`02-principles/06_query_execution.md` 扩充（汇编级/SIMD 指令示例）
8. **查询分析器(Analyzer)与优化器** — 章节归属：`08-performance/12_analyzer.md` 扩充（新 vs 旧 analyzer、成本模型讨论）
9. **Pipeline 调度与背压** — 章节归属：`02-principles/06_query_execution.md` 扩充（Pull 模型实现细节）
10. **聚合管道与状态序列化格式** — 章节归属：`05-functions` 新增 `03_aggregate_combinators.md`
11. **JOIN 策略** — 章节归属：`08-performance` 新增 `16_join_strategies.md`（distributed JOIN/parallel hash JOIN/JOIN 算法选择）
12. **窗口函数性能影响** — 章节归属：`05-functions/02_window_functions_examples.sql` 扩充

### 4.3 分布式与复制深度（章 09 补充）
13. **Keeper 内部（Raft 状态机、日志压缩、快照）** — 章节归属：`09-distributed` 新增 `01_keeper_internals.md`
14. **Replicated vs 非 Replicated 决策（生产案例）** — 章节归属：`09-distributed/02_replication_decisions.md`
15. **Part 生命周期深度（merge_selector 算法）** — 章节归属：`02-principles/03_mergetree.sql` 扩充
16. **跨集群 DDL / ON CLUSTER 陷阱** — 章节归属：`09-distributed` 新增 `04_cross_cluster_ddl.md`
17. **分片键设计与热点分片诊断** — 章节归属：`09-distributed` 新增 `05_sharding_key_design.md`

### 4.4 数据操作深度（章 07 补充）
18. **Async inserts 深度（队列机制、与 Buffer 取舍）** — 章节归属：`07-data-mutation/08_async_inserts.md`
19. **Lightweight DELETE 物理清除时机** — 章节归属：`07-data-mutation/04_lightweight_deletion.md` 扩充
20. **TTL GROUP MOVE** — 章节归属：`07-data-mutation/03_ttl.md` 扩充
21. **DELETE/UPDATE 与 SELECT 并发隔离级别** — 章节归属：`07-data-mutation/07_concurrency.md`（新增）

### 4.5 类型与函数深度（章 03/05 补充）
22. **JSON 类型深度（新 JSON vs JSONExtract）** — 章节归属：`03-data-types` 新增 `10_json_type.md`
23. **AggregateFunction 类型与组合子全集** — 章节归属：`05-functions` 新增 `03_aggregate_combinators.md`（*Resample/*ForEach/*SimpleState/-If/-Array）
24. **UDF（用户定义函数）** — 章节归属：`05-functions` 新增 `04_udf.md`
25. **数组函数全集（差/交/并）** — 章节归属：`05-functions/01_basic_functions_examples.sql` 扩充
26. **字符串模糊匹配函数完整集** — 章节归属：`05-functions/01_basic_functions_examples.sql` 扩充

### 4.6 集成与生态（章 14 补充）
27. **MaterializedPostgreSQL 引擎** — 章节归属：`14-integration/06_materialized_postgresql.md`（新增）
28. **Iceberg/Delta/Hudi 集成** — 章节归属：`14-integration/07_lakehouse_formats.md`（新增）
29. **ClickHouse Local** — 章节归属：`14-integration/08_clickhouse_local.md`（新增）
30. **ClickHouse Cloud / Serverless 概念** — 章节归属：`14-integration/09_clickhouse_cloud.md`（新增）
31. **DBT 集成** — 章节归属：`14-integration/10_dbt.md`（新增）
32. **LIVE VIEW / Window VIEW / Refreshable MV** — 章节归属：`06-modeling/03_materialized_views.md` 扩充

### 4.7 备份恢复深度（章 11 补充）
33. **BACKUP/RESTORE 命令深度** — 章节归属：`11-monitoring-ops/BACKUP_RECOVERY_GUIDE.md` 扩充（替换 FREEZE 旧方案）
34. **增量备份** — 章节归属：同上
35. **跨集群恢复** — 章节归属：同上
36. **灾难恢复演练** — 章节归属：同上

### 4.8 监控与诊断深度（章 11/12 补充）
37. **Prometheus + Grafana 集成** — 章节归属：`11-monitoring-ops` 新增 `10_prometheus_grafana.md`
38. **火焰图（trace_log）** — 章节归属：`12-troubleshooting` 新增 `11_flamegraph.md`
39. **query_log 完整字段解读** — 章节归属：`13-system-tables/07_queries_processes.md` 扩充
40. **容量规划** — 章节归属：`11-monitoring-ops` 新增 `11_capacity_planning.md`

### 4.9 安全深度（章 10 补充）
41. **LDAP/Kerberos 集成** — 章节归属：`10-security/01_authentication.md` 扩充
42. **SSL/TLS 双向认证配置** — 章节归属：`10-security/05_network_security.md` 扩充
43. **Quota 与 workload management 深度** — 章节归属：`10-security` 新增 `10_quota_workload.md`
44. **多租户隔离方案** — 章节归属：`10-security` 新增 `11_multi_tenancy.md`

---

## 五、去重方案（具体动作）

### 5.1 合并类（内容融合）

| 动作 | 来源 | 目标 | 处理 |
|------|------|------|------|
| 合并基础入门 | 01-understanding-clickhouse/（6 sql + README） | 01-getting-started/（原 01-base） | 01-understanding 的"什么是 CH/列存基础/MergeTree 入门"作为前 3 节并入；删除 01-understanding 目录 |
| 合并数据变更 | 09-data-deletion/ + 11-data-update/ | 07-data-mutation/ | Mutation/轻量删除/更新是同一机制两个方向，合并为 8 节：INSERT 优化/Mutation/轻量删除/分区操作/TTL/异步插入/并发隔离/案例 |
| 合并日期主题 | 10-date-update/ | 03-data-types + 05-functions + 06-modeling | 类型部分→03-data-types/03_date_time_types；函数部分→05-functions；时间序列分析→06-modeling/05_time_series.md；删除 10-date-update 目录 |
| 合并运维监控 | 02-advance/02_03_05_06 + 06-admin + 13-monitor | 11-monitoring-ops/ | 06-admin 的 4 个 GUIDE 作为主干；13-monitor 的 8 节并入；02-advance 对应文件拆分并入 |
| 合并故障排查 | 02-advance/07 + 06-admin/TROUBLESHOOTING | 12-troubleshooting/ | 07-troubleshooting 为主干（补全 03-10）；其他内容交叉引用 |

### 5.2 拆分类（内容分离）

| 动作 | 来源 | 目标 | 处理 |
|------|------|------|------|
| 拆分 03-engines | 03-engines/02_replicated_engines（分布式深度部分） | 09-distributed/ | 复制深度留 04-engines；分布式表深度（分片键/GLOBAL JOIN/两阶段聚合）移到 09-distributed |
| 拆分 03-engines | 03-engines/04_integration_engines | 14-integration/ | 整个集成章移到 14-integration 作为第 1 节 |
| 拆分 14-use-case | 14-use-case/01_schema_ddl + 02_sample_data | 06-modeling/06_case_study.md | schema 案例归建模章 |
| 拆分 14-use-case | 14-use-case/04_import_optimization | 07-data-mutation/09_import_optimization.md | 导入优化归数据变更章 |
| 拆分 14-use-case | 14-use-case/06_superset_integration | 14-integration/04_superset.md | Superset 归集成章 |
| 拆分 20-flink | 20-flink-clickhouse-superset/02_clickhouse_modeling | 06-modeling/07_realtime_modeling.md | 实时建模归建模章 |
| 拆分 20-flink | 20-flink-clickhouse-superset/03_flink_clickhouse_sink | 14-integration/03_flink_sink.md | Flink sink 归集成章 |
| 拆分 15-bulk-import | 15-high-performance-bulk-import/ | 14-integration/05_bulk_import.md | 大规模导入归集成章（作为案例） |
| 拆分 02-advance | 02-advance/01_performance_optimization | 08-performance/（交叉引用） | 已有 11-performance 覆盖，02-advance 文件改为"运维导航页" |

### 5.3 重定向类（保留文件但改定位）

| 文件 | 旧定位 | 新定位 |
|------|--------|--------|
| 02-advance/README.md | 高级使用 | **运维导航页**：列出 08-performance/10-security/11-monitoring-ops/12-troubleshooting 的入口，自身不深入 |
| 18-ch-introduction-cn/README.md | 技术分享（中文） | **附录 A**：标注"1 小时分享素材，非教程主干，深度内容见对应主干章" |
| 19-ch-introduction-en/README.md | 技术分享（英文） | **附录 A**：同上 |
| blogs/ | 博客 | **附录 B**：根 README 加入口 |

### 5.4 补全类（缺失文件创建）

| 章节 | 缺失文件 | 优先级 |
|------|----------|--------|
| 01-getting-started | 04_system_queries.sql、05_materialized_views.sql、06_data_modeling.sql、07_realtime_writes.sql、08_data_deduplication.sql | P0（TRAINING_PLAN 引用） |
| 03-data-types | 03_date_time_types.md、04_array_types.md、05_tuple_types.md、06_map_types.md、07_nested_types.md、08_enum_types.md、09_nullable_types.md、10_special_types.md、11_type_conversion.md、12_aggregate_function_type.md、13_json_type.md | P1 |
| 06-modeling | 01_wide_vs_star.md、02_primary_key_design.md、03_materialized_views.md、04_dictionaries.md、05_time_series.md、06_case_study.md、07_realtime_modeling.md | P1 |
| 07-data-mutation | 01_insert_optimization.md、02_mutation.md、03_lightweight_delete.md、04_partition_ops.md、05_ttl.md、06_async_inserts.md、07_concurrency.md、08_case_studies.md | P1 |
| 09-distributed | 01_keeper_internals.md、02_replication_decisions.md、03_distributed_table.md、04_cross_cluster_ddl.md、05_sharding_key_design.md、06_two_phase_aggregation.md、07_global_join.md | P1 |
| 10-security | 10_quota_workload.md、11_multi_tenancy.md | P2 |
| 11-monitoring-ops | 09_tiered_storage.md、10_prometheus_grafana.md、11_capacity_planning.md | P2 |
| 12-troubleshooting | 03_storage_issues.md、04_replication_issues.md、05_query_issues.md、06_startup_issues.md、07_upgrade_issues.md、08_data_consistency.md、09_resource_issues.md、10_common_errors.md、11_flamegraph.md | P1 |
| 14-integration | 02_kafka_deep.md、03_flink_sink.md、04_superset.md、05_bulk_import.md、06_materialized_postgresql.md、07_lakehouse_formats.md、08_clickhouse_local.md、09_clickhouse_cloud.md、10_dbt.md | P2 |
| 15-best-practices | 扩充 04_anti_patterns.md、05_capacity_planning.md | P2 |

### 5.5 修正类（过时内容修正）

| 文件 | 问题 | 修正 |
|------|------|------|
| 根 README.md | 目录树大面积过时（声称的文件不存在） | 完全重写目录树、学习路径、文件引用 |
| TRAINING_PLAN.md | 引用 6-8 个不存在的 01-base 文件；教 FREEZE 旧备份方案；用已禁用的 query_log | 重写：引用新章节；备份改 BACKUP/RESTORE；query_log 改 query_thread_log 或恢复配置 |
| 00-infra/README.md | 声称的 troubleshooting.md/HIGH_AVAILABILITY_GUIDE.md 等不存在；教 query_log | 删除不存在引用；query_log 改替代方案 |
| 05-data-type/README.md | 目录树声称 11 个文件，实际 5 个 | 补全文件后同步 README |
| 07-troubleshooting/README.md | 目录树声称 10 个文件，实际 2 个 | 补全文件后同步 README |
| 全项目 | `system.query_log` 已禁用但多处引用 | 统一改 `system.query_thread_log`（SET log_query_threads=1）或在 00-infra 恢复 query_log 配置 |

---

## 六、0→专家学习路径

### 6.1 阶段划分（4 阶段 14 章）

```
┌─ 入门阶段（章 0-2）─────────────────────────────────┐
│  00-infra          部署集群、理解 Keeper             │
│  01-getting-started 第一个表、基础 SQL、复制表入门    │
│  02-principles     列存/向量化/稀疏索引/Merge 原理    │
└──────────────────────────────────────────────────────┘
                       ↓
┌─ 进阶阶段（章 3-7）─────────────────────────────────┐
│  03-data-types     数值/字符串/日期/数组/JSON/特殊    │
│  04-engines        MergeTree 家族/Log/选型决策树      │
│  05-functions      标量/聚合/*State/*Merge/窗口/UDF   │
│  06-modeling       宽表/星型/主键/MV/字典/时间序列    │
│  07-data-mutation  INSERT/Mutation/轻量/TTL/异步/并发  │
└──────────────────────────────────────────────────────┘
                       ↓
┌─ 高级阶段（章 8-11）────────────────────────────────┐
│  08-performance    查询/索引/PREWHERE/Projections/JOIN│
│  09-distributed    Keeper Raft/分片/两阶段聚合/DDL    │
│  10-security       认证/RBAC/RLS/加密/Quota/多租户    │
│  11-monitoring-ops 系统表/告警/Prometheus/备份/容量   │
└──────────────────────────────────────────────────────┘
                       ↓
┌─ 专家阶段（章 12-15 + 附录）────────────────────────┐
│  12-troubleshooting 故障大全/火焰图/错误码            │
│  13-system-tables  系统表完整参考                    │
│  14-integration    Kafka/Flink/Superset/DBT/Iceberg  │
│  15-best-practices 反模式/容量规划/Do-Don't          │
│  附录 A/B          技术分享素材 + 博客               │
└──────────────────────────────────────────────────────┘
```

### 6.2 学习时长建议（12 周）

| 阶段 | 周数 | 章节 | 里程碑 |
|------|------|------|--------|
| 入门 | 1-2 | 00-02 | 能独立部署集群、建表、解释列存原理 |
| 进阶 | 3-6 | 03-07 | 能选型引擎、设计 schema、用 MV/字典、做数据变更 |
| 高级 | 7-10 | 08-11 | 能优化慢查询、设计分布式架构、配置安全、监控运维 |
| 专家 | 11-12 | 12-15 | 能排查疑难故障、设计端到端方案、做容量规划 |

### 6.3 考核体系（升级）

| 阶段 | 考核形式 | 通过标准 |
|------|----------|----------|
| 入门 | 理论 30min + 实操（部署/建表/复制验证）| 正确率 > 80% |
| 进阶 | 理论 45min + 实操（选型/schema/MV/变更）| 正确率 > 75% |
| 高级 | 理论 45min + 实操（优化/分布式/安全/监控）| 正确率 > 70% |
| 专家 | **架构答辩** 1h + **故障注入演练** + **端到端方案设计** 3 天 | 答辩通过 + 演练恢复 + 方案可行 |

---

## 七、执行批次（重新排序）

### 7.1 批次优先级调整

> 旧计划批次 4-21 按章节顺序执行。本计划按"**阻塞性优先 + 依赖优先**"重排。

| 批次 | 内容 | 优先级 | 理由 | 预估文件数 |
|------|------|--------|------|-----------|
| **R0** | **根 README + TRAINING_PLAN 重写 + 编号冲突解决** | P0 阻塞 | 其他章节的入口与依赖；引用大量幽灵文件 | 3 文件 |
| **R1** | **01-getting-started 合并 + 补全** | P0 阻塞 | TRAINING_PLAN 引用的 6 个文件缺失 | 10 文件 |
| **R2** | 03-data-types 补全 | P1 完整性 | README 声称 11 实际 5 | 9 文件 |
| **R3** | 07-data-mutation 合并（09+11） | P1 完整性 | 消除最大重叠组 | 8 文件 |
| **R4** | 12-troubleshooting 补全 | P1 完整性 | README 声称 10 实际 2 | 9 文件 |
| **R5** | 06-modeling 新建 | P1 完整性 | 教程核心，当前完全缺失 | 7 文件 |
| **R6** | 09-distributed 新建 | P1 完整性 | 分布式深度，当前散落 | 7 文件 |
| **R7** | 08-performance 深化 + 补 Projections/JOIN | P2 深化 | 旧批次 4，性能是专家核心 | 17 文件 |
| **R8** | 05-functions 扩充（聚合组合子/UDF/JSON） | P2 深化 | 已细化，补缺失专题 | 5 文件 |
| **R9** | 11-monitoring-ops 合并 + 补 Prometheus/容量 | P2 深化 | 合并 3 章 + 补缺失 | 14 文件 |
| **R10** | 10-security 深化 + 补 Quota/多租户 | P2 深化 | 已有 9 节，补 2 节 | 11 文件 |
| **R11** | 14-integration 合并 + 补 Kafka/Flink/DBT/Iceberg | P2 深化 | 合并 3 章 + 补 8 节 | 12 文件 |
| **R12** | 15-best-practices 扩充 | P3 优化 | 反模式案例库 | 7 文件 |
| **R13** | 13-system-tables 深化 | P3 优化 | query_log 字段解读 | 17 文件 |
| **R14** | 02-principles 扩充（向量化 SIMD/Pipeline） | P3 优化 | 已细化，补汇编级 | 9 文件 |
| **R15** | 附录 A/B + 00-infra 修正 | P3 收尾 | 分享素材定位 + infra 修正 | 15 文件 |
| **R16** | 收尾：全项目一致性校验 + 跨章链接修复 | P3 收尾 | 确保导航无断链 | — |

### 7.2 单批次工作流（沿用旧计划）

1. 读取 PROGRESS.md 确认当前批次
2. 读取该批次所有现有文件
3. 按深度标准重写/补全 README.md
4. 按深度标准重写/补全每个 SQL/MD 文件
5. 在集群上执行每个 SQL 文件验证
6. 修复验证中发现的错误（参考旧计划的 CH 25.12 兼容性清单）
7. 更新 PROGRESS.md 标记完成
8. 汇报本批次成果与下批次计划

### 7.3 与已完成批次的关系

| 已完成批次 | 旧章节 | 新章节 | 处理 |
|-----------|--------|--------|------|
| 批次 1 | 04-functions | 05-functions | `git mv` 重命名，内容保留，R8 扩充 |
| 批次 2 | 16-principle | 02-principles | `git mv` 重命名，内容保留，R14 扩充 |
| 批次 3 | 03-engines | 04-engines | `git mv` 重命名，内容保留；分布式深度抽取到 09-distributed（R6）；集成抽取到 14-integration（R11） |

---

## 八、验收标准

### 8.1 单文件验收（沿用旧标准）
- README.md：含"本章解决什么问题/核心原理/概念对比/常见误区/自测题"五段式
- SQL：每个文件在 clickhouse-server-1 零错误执行，含【原理】【场景】【对比】【坑】注释
- MD：原理+场景+对比+决策表，ASCII 图/流程图说明底层机制

### 8.2 章节验收
- 目录树与实际文件一致（无幽灵文件）
- 与其他章节无大面积内容重叠（交叉引用而非重复）
- 编号无冲突
- 覆盖该主题的专家级深度（参考第四节清单）

### 8.3 全项目验收（R16 收尾）
- 根 README 目录树与实际 100% 一致
- TRAINING_PLAN 引用的文件全部存在
- 所有 `system.query_log` 引用已修正
- 所有跨章链接有效（无 404）
- 14 章 + 2 附录全部达到专家级深度
- 0→专家学习路径可连贯跟随

---

## 九、风险与缓解

| 风险 | 缓解 |
|------|------|
| 大规模重命名（git mv）破坏已有链接 | R0 阶段同步更新所有跨章链接；R16 收尾全项目校验 |
| 合并章节导致内容丢失 | 合并前先备份；合并后逐节核对内容覆盖度 |
| 补缺失文件工作量大 | 按 P0→P1→P2→P3 优先级推进；单批次控制文件数 |
| 重命名后用户旧引用失效 | 根 README 加"旧→新章节映射表"；保留 .git 历史 |
| SQL 在集群报错（CH 25.12 兼容） | 参考旧计划的兼容性修复清单（query_log/列名/codec/注释等） |
| 单轮对话上下文溢出 | 严格执行单批次工作流，每批次结束更新 PROGRESS.md |

---

## 十、首轮交付承诺

本轮交付：**本重整计划文档** + **PROGRESS.md 更新**（记录新批次 R0-R16 排序）。
用户确认计划后，按 R0（根 README + TRAINING_PLAN 重写 + 编号冲突解决）开始执行。

---

## 附：旧→新章节映射表（供根 README 引用）

| 旧章节 | 新章节 | 说明 |
|--------|--------|------|
| 00-infra | 00-infra | 保留，补全 |
| 01-base | 01-getting-started | 合并 01-understanding，补全 04-09 |
| 01-understanding-clickhouse | 01-getting-started | 并入，删除 |
| 02-advance | 02-advance（导航页）+ 各专题章 | 拆分 |
| 03-engines | 04-engines | 重命名，分布式/集成抽取 |
| 04-functions | 05-functions | 重命名，扩充 |
| 05-data-type | 03-data-types | 重命名，补全 |
| 06-admin | 11-monitoring-ops | 合并 13-monitor |
| 07-troubleshooting | 12-troubleshooting | 补全 03-10 |
| 08-information-schema | 13-system-tables | 重命名 |
| 09-data-deletion | 07-data-mutation | 合并 11-data-update |
| 10-date-update | 03-data-types + 05-functions + 06-modeling | 拆分 |
| 11-data-update | 07-data-mutation | 并入，删除 |
| 11-performance | 08-performance | 重命名，深化 |
| 12-security-authentication | 10-security | 重命名，深化 |
| 13-monitor | 11-monitoring-ops | 并入 |
| 14-use-case | 06-modeling + 14-integration | 拆分 |
| 15-high-performance-bulk-import | 14-integration | 并入 |
| 16-principle | 02-principles | 重命名，扩充 |
| 17-best-practices | 15-best-practices | 重命名，扩充 |
| 18-ch-introduction-cn | 附录 A | 降级 |
| 19-ch-introduction-en | 附录 A | 降级 |
| 20-flink-clickhouse-superset | 06-modeling + 14-integration | 拆分 |
| blogs | 附录 B | 降级 |
