# ClickHouse 文档深度细化进度追踪

> 目标：把所有 README.md 和 SQL/MD 文件细化到"读完可成为专家"的程度（原理+场景+对比+可运行）。
> 方案详见 [.trae/documents/clickhouse-doc-deep-refinement-plan.md](./.trae/documents/clickhouse-doc-deep-refinement-plan.md)
> 集群：treasurycluster（CH 25.12.1.649，clickhouse-server-1: 8123/9000，clickhouse-server-2: 8124/9001）

## 验证状态图例
- ✅ 已验证：SQL 在 clickhouse-server-1 零错误执行，功能正确
- ⚠️ 部分验证：SQL 执行通过，但跨副本同步受 Windows Docker 环境限制（非文档问题）
- ⬜ 待处理

---

## 批次进度总览

| 批次 | 章节 | 状态 | 完成日期 | 说明 |
|------|------|------|----------|------|
| 1 | 04-functions | ✅ | 2026-08-02 | 样板章节，确立深度标准 |
| 2 | 16-principle | ⬜ | — | 列存压缩、稀疏索引、Merge 算法 |
| 3 | 03-engines | ⬜ | — | MergeTree 家族对比、引擎选择决策树 |
| 4 | 11-performance | ⬜ | — | 主键索引、跳数索引、PREWHERE |
| 5 | 01-base | ⬜ | — | 基础操作、复制/分布式表、数据建模 |
| 6 | 01-understanding-clickhouse | ⬜ | — | 入门概念衔接 |
| 7 | 02-advance | ⬜ | — | 性能/备份/监控/安全/高可用 |
| 8 | 05-data-type | ⬜ | — | 数值/字符串类型原理与选型 |
| 9 | 09-data-deletion | ⬜ | — | 4 种删除方式对比 |
| 10 | 11-data-update | ⬜ | — | Mutation vs 轻量更新 |
| 11 | 10-date-update | ⬜ | — | 日期类型、时区、时间序列 |
| 12 | 12-security-authentication | ⬜ | — | 认证、RBAC、行级安全 |
| 13 | 13-monitor | ⬜ | — | 系统表监控、查询监控、告警 |
| 14 | 06-admin | ⬜ | — | 集群管理、备份恢复、维护 |
| 15 | 07-troubleshooting | ⬜ | — | 连接/性能问题诊断 |
| 16 | 08-information-schema | ⬜ | — | 系统表元数据查询大全 |
| 17 | 17-best-practices | ⬜ | — | schema 设计、查询优化 |
| 18 | 15-high-performance-bulk-import | ⬜ | — | GCS 导入、单/多分片 |
| 19 | 14-use-case | ⬜ | — | schema DDL、样本数据、Superset |
| 20 | 20-flink-clickhouse-superset | ⬜ | — | Flink sink、Superset、SLA |
| 21 | 18/19-introduction + 00-infra + blogs | ⬜ | — | 入门介绍、基础设施、博客 |
| 收尾 | 根 README + TRAINING_PLAN | ⬜ | — | 修正导航与错误 |

---

## 批次 1：04-functions（样板）✅

### 完成内容

#### [04-functions/README.md](./04-functions/README.md)（重写）
- 新增"本章解决什么问题"章节，对标业务痛点
- 新增函数体系全景图（标量/聚合/窗口/表函数）
- **新增核心章节：聚合状态函数（*State/*Merge）原理**
  - sumState/sumMerge 的工作机制（二进制中间状态）
  - 为什么需要状态函数（物化视图预聚合、分布式聚合、跨时段汇总）
  - *State/*Merge 全家族对比表（sum/uniq/quantile/groupArray/topK）
  - AggregatingMergeTree 配合示例
- 新增窗口帧 ROWS vs RANGE 原理图解与对比表
- 新增关键函数决策表（计数函数、数组展开 vs 映射、JSON 方案、条件函数）
- 新增常见误区与最佳实践
- 新增自测题（7 道，含答案线索）

#### [04-functions/01_basic_functions_examples.sql](./04-functions/01_basic_functions_examples.sql)（深化+扩充）
- 文件头增加学习目标、深度标准、章节索引
- 每个章节增加【原理】【场景】【对比】【坑】注释结构
- **新增 §11 聚合状态函数（原文件完全缺失）**：
  - sumState/sumMerge + AggregatingMergeTree 完整示例
  - 二级聚合（日表→月表）演示状态可继续合并
  - uniqState/uniqMerge（HLL UV 跨分片合并）
  - quantileState/quantileMerge（P90 延迟监控）
- 新增 §12 Map 函数（mapApply lambda）
- 新增 arrayMap/arrayFilter（lambda 表达式）
- 新增 visitParam 系列（轻量 JSON 解析对比）
- 修复原有 `//` 非法注释（CH 只支持 `--`）
- 修复 formatDateTime 不支持 %A/%B（改用 dateName）
- 修复 toInt32('456.78') 抛错（改用 toInt32(toFloat64)）
- 修复 md5/sha1/sha256 大小写（CH 函数名大小写敏感）
- 修复 IPv4NumToClassC 已废弃（改用 splitByChar + IPv4CIDRToRange）

#### [04-functions/02_window_functions_examples.sql](./04-functions/02_window_functions_examples.sql)（深化）
- 文件头增加学习目标、章节索引
- 新增 §5 窗口帧 ROWS vs RANGE 核心难点章节（原理图 + 对比表）
- 新增 §5.2 默认 frame "跳变"陷阱演示（同值行导致 RANGE 累计跳变）
- 修复 ASCII 图中 `│--` 非法前缀
- 修复 INSERT VALUES 内行内注释导致解析失败
- 修复 RANGE BETWEEN 100 PRECEDING 在 Decimal 列未实现
- 修复 count(*) → count()（CH 惯用）
- 修复 CASE WHEN emoji 为 multiIf
- 增加每个查询的【原理】【关键】【结果解读】注释

### 验证结果
- ✅ 01_basic_functions_examples.sql：在 clickhouse-server-1 零错误执行
- ✅ 02_window_functions_examples.sql：在 clickhouse-server-1 零错误执行
- ✅ 聚合状态函数功能验证：sumMerge(gmv_state) 正确还原 GMV（2024-01-15 Electronics: 299.99+499.99=799.98）
- ✅ 二级聚合验证：日表→月表 sumMerge 正确
- ⚠️ 跨副本同步：server-2 未同步数据，属 Windows Docker 复制环境已知限制（见 00-infra/README.md 注意事项），非文档问题

### 修复的 ClickHouse 25.12 兼容性问题（供后续批次参考）
| 问题 | 原因 | 修复方式 |
|------|------|----------|
| `//` 注释报错 | CH 只支持 `--` | 全部改为 `--` |
| `formatDateTime(..., '%A')` 报错 | 25.12 不支持 %A/%B | 用 dateName() 函数 |
| `toInt32('456.78')` 抛错 | 含小数点无法直接转 Int | 先 toFloat64 再 toInt32 |
| `md5`/`sha1`/`sha256` 未定义 | CH 函数名大小写敏感 | 改为大写 MD5/SHA1/SHA256 |
| `IPv4NumToClassC` 已废弃 | 25.12 移除 | 用 splitByChar + IPv4CIDRToRange |
| INSERT VALUES 内行内注释 | 解析器不支持 | 移除 VALUES 块内注释 |
| `RANGE BETWEEN N PRECEDING` on Decimal | 未实现 | 改用 Date 排序列或 ROWS |
| `count(*)` | 非惯用 | 改为 `count()` |

---

## 下批次计划：批次 2 — 16-principle
重点：列存压缩原理、稀疏索引 mark 定位、Merge 算法、复制/分片原理。
将参照批次 1 的深度标准与修复清单执行。
