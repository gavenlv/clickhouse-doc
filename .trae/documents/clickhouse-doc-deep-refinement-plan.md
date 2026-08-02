# ClickHouse 文档与 SQL 深度细化方案

## Context（背景）

### 问题
当前 `clickhouse-doc` 项目（21 个章节、约 130 个文件）的文档质量参差不齐：
- **README.md 偏目录介绍**：以 [01-base/README.md](file:///d:/workspace/big-data/clickhouse-doc/01-base/README.md) 为例，主要是"文件列表 + 主题罗列"，缺少原理性深度
- **SQL 文件偏示例罗列**：以 [04-functions/01_basic_functions_examples.sql](file:///d:/workspace/big-data/clickhouse-doc/04-functions/01_basic_functions_examples.sql) 为例，有分类图和示例，但缺少"为什么这样设计、什么场景用、与替代方案对比"
- **关键进阶内容缺失**：用户举例的 `sumState`/`sumMerge`（聚合状态函数）在 04-functions 中**完全不存在**，这类"分阶段聚合/物化视图预聚合"的核心原理未覆盖
- [16-principle/README.md](file:///d:/workspace/big-data/clickhouse-doc/16-principle/README.md) 虽有架构图但仍偏概述，未达专家级深度

### 目标
把所有 README.md 和 SQL 文件细化到"读完可成为专家"的程度，标准为**原理+场景+对比**：
- **原理**：讲清底层机制（如聚合状态的二进制结构、MergeTree 的 Part 合并算法、稀疏索引的 mark 定位）
- **场景**：明确什么业务场景用、为什么用
- **对比**：与替代方案对比（如 sumState vs sum、ReplacingMergeTree vs CollapsingMergeTree、Mutation vs Lightweight Update），含性能权衡
- **可运行**：每个 SQL 文件在已启动的集群（CH 25.12.1.649，clickhouse-server-1）上验证零错误

### 约束
- 集群已启动：clickhouse-server-1（HTTP 8123 / Native 9000）、clickhouse-server-2（8124/9001）、3 Keeper
- 集群名 `treasurycluster`，已配置默认复制路径宏
- 单轮对话无法完成全部 130 个文件，需分多轮交付，建立进度追踪

---

## 深度标准模板（以 sumState/sumMerge 为标杆）

### README.md 标准结构
```
1. 本章解决什么问题（Why）—— 业务痛点 + 学习目标
2. 核心原理详解 —— 含 ASCII 图/流程图，讲底层机制
3. 关键概念逐个讲透（原理 + 场景 + 对比 + 决策表）
4. 知识图谱：本章文件导航 + 与其他章节关联
5. 常见误区与最佳实践
6. 自测题（理解检查点）
```

### SQL 文件标准结构
```sql
-- ============================================================
-- 文件: 04-functions/01_basic_functions_examples.sql
-- 学习目标: 掌握聚合函数及 *State/*Merge 状态函数的原理与应用
-- 前置: 无（自包含测试数据）
-- ============================================================

-- ------------------------------------------------------------
-- 1.1 聚合函数基础
-- ------------------------------------------------------------
-- 【原理】聚合函数在 ClickHouse 中如何执行？
--   向量化 + 分组聚合管道，详见 16-principle/06_query_execution.md
-- 【场景】统计报表、监控指标
-- 【对比】sum vs sumState —— 见下方 1.2 节

CREATE TABLE ... ;
INSERT ... ;

-- 【结果解读】观察 xxx 列 ...

-- ------------------------------------------------------------
-- 1.2 聚合状态函数 sumState / sumMerge（核心进阶）
-- ------------------------------------------------------------
-- 【原理】
--   sumState(expr) 不返回数值，返回 AggregateFunction(Sum, T) 类型的
--   "中间状态"（二进制序列化）。sumMerge(state) 将多个状态合并后
--   产出最终值。这就是"两阶段聚合"的本质。
-- 【为什么需要】
--   1. 物化视图预聚合：原始表 INSERT 时，MV 用 sumState 物化中间态
--   2. 分布式聚合：各分片本地聚合（sumState）→ 协调节点合并（sumMerge）
--   3. 跨时段汇总：日表 → 月表 → 年表，逐级 merge 不丢精度
-- 【对比】
--   方案A: SELECT sum(x) FROM 日表 GROUP BY k   ← 重算，慢
--   方案B: SELECT sumMerge(s) FROM 日表_mv      ← 复用状态，快 10x+
-- 【场景】海量明细的实时聚合报表、漏斗/留存计算
-- 【坑】
--   - sumState 结果不能直接 SELECT 看数值（是二进制），需 sumMerge
--   - 状态类型必须配 AggregatingMergeTree 引擎才自动 merge

CREATE TABLE ... ENGINE = AggregatingMergeTree ...;
-- 完整可运行示例 ...
```

---

## 执行策略：分批次交付 + 进度追踪

### 进度追踪文件
新建 [PROGRESS.md](file:///d:/workspace/big-data/clickhouse-doc/PROGRESS.md)（根目录），记录每批次完成情况，每轮对话开头先读取确认续接点。

### 批次划分（按依赖与重要性排序）

| 批次 | 章节 | 文件数 | 重点内容 | 验证方式 |
|------|------|--------|----------|----------|
| **批次 1（样板）** | 04-functions | 2 sql + 1 readme | sumState/sumMerge、窗口函数帧、arrayJoin 展开、JSONExtract | 全部集群验证 |
| 批次 2 | 16-principle | 8 文件 + readme | 列存压缩、稀疏索引、Merge 算法、复制/分片原理 | sql 验证 + md 校对 |
| 批次 3 | 03-engines | 6 文件 + readme | MergeTree 家族对比、引擎选择决策树、Replicated vs Distributed | 全部集群验证 |
| 批次 4 | 11-performance | 14 文件 + readme | 主键索引、跳数索引、PREWHERE、查询 profiling | 全部集群验证 |
| 批次 5 | 01-base | 9 sql + readme | 基础操作、复制/分布式表、数据建模 | 全部集群验证 |
| 批次 6 | 01-understanding-clickhouse | 6 sql + readme | 入门概念衔接 | 全部集群验证 |
| 批次 7 | 02-advance | 7 sql + readme | 性能/备份/监控/安全/高可用/迁移/排障 | 全部集群验证 |
| 批次 8 | 05-data-type | 4 文件 + readme | 数值/字符串类型原理与选型 | 全部集群验证 |
| 批次 9 | 09-data-deletion | 14 文件 + readme | 4 种删除方式对比、TTL、Mutation、轻量删除 | 全部集群验证 |
| 批次 10 | 11-data-update | 16 文件 + readme | Mutation vs 轻量更新、分区更新、批量更新 | 全部集群验证 |
| 批次 11 | 10-date-update | 18 文件 + readme | 日期类型、时区、时间序列、窗口函数 | 全部集群验证 |
| 批次 12 | 12-security-authentication | 18 文件 + readme | 认证、RBAC、行级安全、加密、审计 | 全部集群验证 |
| 批次 13 | 13-monitor | 17 文件 + readme | 系统表监控、查询监控、滥用检测、告警 | 全部集群验证 |
| 批次 14 | 06-admin | 10 文件 + readme | 集群管理、备份恢复、维护、排障 | 全部集群验证 |
| 批次 15 | 07-troubleshooting | 4 文件 + readme | 连接/性能问题诊断 | 全部集群验证 |
| 批次 16 | 08-information-schema | 16 文件 + readme | 系统表元数据查询大全 | 全部集群验证 |
| 批次 17 | 17-best-practices | 6 文件 + readme | schema 设计、查询优化、常见错误、DoDont | sql 验证 |
| 批次 18 | 15-high-performance-bulk-import | 9 文件 + readme | GCS 导入、单/多分片、资源优化、错误恢复 | sql 验证 |
| 批次 19 | 14-use-case | 6 sql + readme | schema DDL、样本数据、预测视图、Superset 集成 | 全部集群验证 |
| 批次 20 | 20-flink-clickhouse-superset | 9 文件 + readme | Flink sink、Superset、数据流、SLA | sql 验证 |
| 批次 21 | 18/19-introduction + 00-infra + blogs | 约 20 文件 | 入门介绍、基础设施、博客文章校对 | sql 验证 |
| **收尾** | 根 README + TRAINING_PLAN | 2 文件 | 更新导航、修正错误（如 system.zookeeper 字段名错误） | — |

### 单批次工作流（每轮对话执行一个批次）
1. 读取 PROGRESS.md 确认当前批次
2. 读取该批次所有现有文件
3. 按深度标准重写 README.md
4. 按深度标准重写每个 SQL/MD 文件（增加原理注释、场景说明、对比演示）
5. 在集群上执行每个 SQL 文件验证：`docker exec -i clickhouse-server-1 clickhouse-client --queries-file -` 或分语句执行
6. 修复验证中发现的错误
7. 更新 PROGRESS.md 标记完成
8. 汇报本批次成果与下批次计划

### 批次 1（样板）的具体执行清单
**目标文件**：
- [04-functions/README.md](file:///d:/workspace/big-data/clickhouse-doc/04-functions/README.md)（重写）
- [04-functions/01_basic_functions_examples.sql](file:///d:/workspace/big-data/clickhouse-doc/04-functions/01_basic_functions_examples.sql)（深化，新增 sumState/sumMerge/quantileState 等聚合状态函数章节）
- [04-functions/02_window_functions_examples.sql](file:///d:/workspace/big-data/clickhouse-doc/04-functions/02_window_functions_examples.sql)（深化窗口帧原理、ROWS vs RANGE、运行总计/移动平均实战）

**新增核心内容**（4-functions 缺失的进阶函数）：
- 聚合状态函数：`sumState`/`sumMerge`、`quantileState`/`quantileMerge`、`uniqState`/`uniqMerge`、`groupArrayState`
- `AggregatingMergeTree` 引擎配合物化视图预聚合（完整可运行示例）
- `arrayJoin` 的展开原理（1 行变 N 行）
- `JSONExtract*` 系列 vs 新 `JSON` 类型的对比
- `mapApply`/`mapPopulateSeries` 等 Map 函数
- 窗口函数 frame 子句的物理行 vs 逻辑值范围

**验证命令**：
```powershell
# 将 SQL 文件复制进容器后执行（避免 Windows 换行问题）
docker cp "d:\workspace\big-data\clickhouse-doc\04-functions\01_basic_functions_examples.sql" clickhouse-server-1:/tmp/01.sql
docker exec clickhouse-server-1 clickhouse-client --queries-file /tmp/01.sql
```
对报错的语句逐条修正，直到全文件零错误执行。

---

## 关键文件清单（批次 1 立即修改）

| 文件 | 操作 | 说明 |
|------|------|------|
| [04-functions/README.md](file:///d:/workspace/big-data/clickhouse-doc/04-functions/README.md) | 重写 | 按新标准结构，加聚合状态函数原理章节 |
| [04-functions/01_basic_functions_examples.sql](file:///d:/workspace/big-data/clickhouse-doc/04-functions/01_basic_functions_examples.sql) | 深化+扩充 | 新增聚合状态函数、Map 函数、JSON 函数对比 |
| [04-functions/02_window_functions_examples.sql](file:///d:/workspace/big-data/clickhouse-doc/04-functions/02_window_functions_examples.sql) | 深化 | 加窗口帧原理图、ROWS/RANGE 对比、实战案例 |
| [PROGRESS.md](file:///d:/workspace/big-data/clickhouse-doc/PROGRESS.md) | 新建 | 进度追踪 |

---

## 验证方案（端到端）

1. **SQL 可运行性验证**：每个 SQL 文件用 `clickhouse-client --queries-file` 在 clickhouse-server-1 执行，零错误
2. **跨副本验证**：复制表相关 SQL 在 server-2 验证数据已同步
3. **结果正确性**：关键查询对比预期结果（注释中标注预期输出）
4. **README 一致性**：README 中引用的文件名/锚点与实际文件一致
5. **批次 1 完成后**：请用户确认深度标准，再按此标准推进后续 20 个批次

---

## 风险与缓解

| 风险 | 缓解 |
|------|------|
| 单批次工作量过大导致上下文溢出 | 每批次严格控制文件数，必要时拆分为子轮次 |
| SQL 在集群报错（语法/权限/版本） | 逐条执行定位，参考 CH 25.12 文档修正 |
| 文档重复内容多 | 跨章节共用原理只详述一次，其他章节链接引用 |
| 根 README 导航过时（指向不存在的文件如 test_all_topics.sql） | 收尾批次统一修正导航 |
| Windows 换行符导致 SQL 执行失败 | 用 `docker cp` + 容器内执行，避免 PowerShell 管道 |

---

## 首轮交付承诺

本轮（批次 1）交付：04-functions 章节完整深化（README + 2 个 SQL 全部集群验证通过）+ PROGRESS.md 建档。完成后请用户确认深度标准，确认后我按批次表自动推进后续章节。
