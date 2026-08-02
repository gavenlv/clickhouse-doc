# ClickHouse 文档深度细化进度追踪

> 目标：把所有 README.md 和 SQL/MD 文件细化到"读完可成为专家"的程度（原理+场景+对比+可运行）。
> **重整计划**：[.trae/documents/clickhouse-tutorial-reorg-plan.md](./.trae/documents/clickhouse-tutorial-reorg-plan.md)（升级版，含去重/补缺失/重编号）
> **旧计划**：[.trae/documents/clickhouse-doc-deep-refinement-plan.md](./.trae/documents/clickhouse-doc-deep-refinement-plan.md)
> 集群：treasurycluster（CH 25.12.1.649，clickhouse-server-1: 8123/9000，clickhouse-server-2: 8124/9001）

## 验证状态图例
- ✅ 已验证：SQL 在 clickhouse-server-1 零错误执行，功能正确
- ⚠️ 部分验证：SQL 执行通过，但跨副本同步受 Windows Docker 环境限制（非文档问题）
- ⬜ 待处理

---

## 当前阶段：R0 已完成，下一批次 R1（01-getting-started 合并 + 补全）

### 重整计划核心结论（2026-08-02 诊断）

**3 类系统性问题**：
1. **目录树过时**（极高）：根 README 声称的 01-base 04-09、05-data-type 03-11、07-troubleshooting 03-10 共 23 个文件 **全部不存在**
2. **章节编号冲突**（高）：`01-base` 与 `01-understanding-clickhouse` 都用 01；`11-data-update` 与 `11-performance` 都用 11
3. **内容大面积重叠**（高）：复制/分布式原理在 5 章重复；运维主题在 4 章重复

**重整方向**：21 章 → 14 主干章 + 2 附录，详见重整计划文档第三节"新章节结构"。

**补缺失清单**：44 个专家级主题（Projections/Dictionaries/Keeper Raft/向量化 SIMD/BACKUP-RESTORE/Prometheus/Iceberg/ClickHouse Local/UDF 等），详见重整计划第四节。

---

## 重整批次进度总览（R0-R16，按阻塞性优先重排）

| 批次 | 内容 | 优先级 | 状态 | 完成日期 | 说明 |
|------|------|--------|------|----------|------|
| **R0** | 根 README + TRAINING_PLAN 重写 + 编号冲突标注 | P0 阻塞 | ✅ | 2026-08-02 | 根 README 目录树与实际一致；TRAINING_PLAN 引用真实文件；编号冲突已标注 |
| **R1** | 01-getting-started 合并 + 补全（01-base + 01-understanding） | P0 阻塞 | ⬜ | — | TRAINING_PLAN 引用的 6 个文件缺失 |
| **R2** | 03-data-types 补全（原 05-data-type） | P1 完整性 | ⬜ | — | README 声称 11 实际 5 |
| **R3** | 07-data-mutation 合并（原 09-data-deletion + 11-data-update） | P1 完整性 | ⬜ | — | 消除最大重叠组，解决 11-vs-11 编号冲突 |
| **R4** | 12-troubleshooting 补全（原 07-troubleshooting） | P1 完整性 | ⬜ | — | README 声称 10 实际 2 |
| **R5** | 06-modeling 新建 | P1 完整性 | ⬜ | — | 教程核心，当前完全缺失 |
| **R6** | 09-distributed 新建 | P1 完整性 | ⬜ | — | 分布式深度，当前散落 |
| **R7** | 08-performance 深化 + 补 Projections/JOIN（原 11-performance） | P2 深化 | ⬜ | — | 旧批次 4，性能是专家核心 |
| **R8** | 05-functions 扩充（原 04-functions，聚合组合子/UDF/JSON） | P2 深化 | ⬜ | — | 已细化，补缺失专题 |
| **R9** | 11-monitoring-ops 合并 + 补 Prometheus/容量 | P2 深化 | ⬜ | — | 合并 06-admin + 13-monitor + 02-advance 运维 |
| **R10** | 10-security 深化 + 补 Quota/多租户（原 12-security-authentication） | P2 深化 | ⬜ | — | 已有 9 节，补 2 节 |
| **R11** | 14-integration 合并 + 补 Kafka/Flink/DBT/Iceberg | P2 深化 | ⬜ | — | 合并 03-engines/04 + 14-use-case + 20-flink + 15-bulk-import |
| **R12** | 15-best-practices 扩充（原 17-best-practices） | P3 优化 | ⬜ | — | 反模式案例库 |
| **R13** | 13-system-tables 深化（原 08-information-schema） | P3 优化 | ⬜ | — | query_log 字段解读 |
| **R14** | 02-principles 扩充（原 16-principle，向量化 SIMD/Pipeline） | P3 优化 | ⬜ | — | 已细化，补汇编级 |
| **R15** | 附录 A/B + 00-infra 修正 | P3 收尾 | ⬜ | — | 分享素材定位 + infra 修正 |
| **R16** | 收尾：全项目一致性校验 + 跨章链接修复 | P3 收尾 | ⬜ | — | 确保导航无断链 |

### 已完成批次（旧计划，重整后保留为已完成基础）

| 旧批次 | 旧章节 | 新章节（重整后） | 状态 | 完成日期 | 说明 |
|--------|--------|------------------|------|----------|------|
| 1 | 04-functions | 05-functions | ✅ | 2026-08-02 | 样板章节，确立深度标准；R8 将扩充 |
| 2 | 16-principle | 02-principles | ✅ | 2026-08-02 | 列存压缩、稀疏索引、Merge 算法、复制/分片原理；R14 将扩充 |
| 3 | 03-engines | 04-engines | ✅ | 2026-08-02 | MergeTree 家族对比、引擎选择决策树、6 个 SQL 全集群验证；R6/R11 将抽取分布式/集成深度 |

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

## 批次 2：16-principle ✅

### 完成内容

#### README.md（重写）
- 新增"本章解决什么问题"章节，对标 10 个核心痛点
- 新增 ClickHouse 整体架构图（Client/Server/Storage/Keeper 四层）
- **核心原理详解六大支柱**：列式存储、向量化执行、数据压缩、稀疏索引、分区剪枝、并行处理
- MergeTree Part 生命周期（INSERT→Merge→TTL→复制传播）+ 物理结构
- 稀疏索引 mark 机制（8192 由来、二分查找流程、跳数索引 5 种类型）
- 向量化执行原理（逐行 vs 批量、SIMD、列存依赖）
- 查询执行管道（Parser→Analyzer→Interpreter→Pipeline Pull 模型）
- 复制原理（异步语义、Keeper 路径模型、quorum、故障恢复）
- 分片与分布式查询（两阶段聚合 sumState/sumMerge、GLOBAL JOIN）
- 列式 vs 行式对比表、分区 vs 主键排序决策表
- 常见误区 8 条 + 最佳实践 9 条 + 自测题 12 道

#### [01_overview.sql](./16-principle/01_overview.sql)（深化）
- 文件头增加学习目标、深度标准、章节索引
- 每节增加【原理】【场景】【对比】【坑】注释结构
- 修复 `system.query_log` 不存在 → 改用 `query_thread_log` + 说明
- 修复 `compressed_bytes` → `column_data_compressed_bytes`

#### [02_column_store.sql](./16-principle/02_column_store.sql)（深化）
- 列式 vs 行式对比、LowCardinality 字典编码、index_granularity 实验
- 修复 `compressed_bytes`/`data_uncompressed_bytes` → `column_data_compressed_bytes`/`column_data_uncompressed_bytes`
- 修复 `index_granularity` 列不存在 → 改用 `marks` 列反推
- 修复 `compression_codec` 表级设置不存在 → 改用列级 `CODEC()` 语法定义
- 修复 `system.query_log` → `query_thread_log`

#### [03_mergetree.sql](./16-principle/03_mergetree.sql)（深化）
- Part 生命周期、命名规则、合并机制、5 种 MergeTree 变体对比
- 修复 `mutation_version` → `data_version`（CH 25.x 改名）
- 修复 `ttl_info` → `delete_ttl_info_min`/`delete_ttl_info_max`
- 修复 INSERT VALUES 块内行内注释（解析器不支持）→ 移到 INSERT 前
- 修复 AggregatingMergeTree 的 `uniqState()` 不能用 INSERT VALUES → 改用 INSERT SELECT

#### [04_compression.md](./16-principle/04_compression.md)（深化）
- 压缩原理（LZ4/ZSTD/Delta/Gorilla）、codec 选择决策树、LowCardinality 适用边界
- 修复 `compressed_bytes` → `column_data_compressed_bytes`

#### [05_indexing.md](./16-principle/05_indexing.md)（深化）
- 稀疏索引 mark 定位流程、主键列顺序原则、index_granularity 权衡
- 跳数索引选择矩阵（minmax/set/bloom_filter/tokenbf/ngrambf）
- 添加 query_log 前置条件说明

#### [06_query_execution.md](./16-principle/06_query_execution.md)（深化）
- Pipeline 阶段、向量化+SIMD、PREWHERE 机制、并行执行、聚合管道
- 添加 query_log 前置条件说明（config 启用 + 替代方案）

#### [07_replication.md](./16-principle/07_replication.md)（深化）
- 异步复制语义、Keeper 路径模型、INSERT 复制全流程、quorum、故障恢复
- 副本健康诊断（system.replicas 关键字段 + 决策表 + 告警阈值）

#### [08_sharding.sql](./16-principle/08_sharding.sql)（深化）
- 分片 vs 副本、本地表+分布式表、分片键原理、两阶段聚合（sumState/sumMerge）
- 跨分片 JOIN（GLOBAL JOIN/GLOBAL IN）、分片监控
- 修复 `system.query_log` → 三种替代方案（query_thread_log/query_log 注释/processes）

### 验证结果
- ✅ 01_overview.sql：clickhouse-server-1 零错误
- ✅ 02_column_store.sql：clickhouse-server-1 零错误
- ✅ 03_mergetree.sql：clickhouse-server-1 零错误
- ✅ 08_sharding.sql：clickhouse-server-1 零错误
- ✅ 4 个 markdown 文件（04/05/06/07）同步修复列名与 query_log 说明

### 修复的 ClickHouse 25.12 兼容性问题（批次 2 新增）
| 问题 | 原因 | 修复方式 |
|------|------|----------|
| `system.query_log` 不存在 | config.xml 用 `<query_log remove="1"/>` 禁用 | 改用 `system.query_thread_log`(SET log_query_threads=1) + 注释说明 |
| `compressed_bytes` 列不存在 | CH 25.x 改名 | `column_data_compressed_bytes`(parts_columns 表) |
| `data_uncompressed_bytes` 在 parts_columns 中是整 Part 值 | 误导性列名 | 改用 `column_data_uncompressed_bytes`(每列粒度) |
| `mutation_version` 列不存在 | CH 25.x 改名 | `data_version` |
| `ttl_info` 列不存在 | CH 25.x 拆分 | `delete_ttl_info_min`/`delete_ttl_info_max` |
| `index_granularity` 不是 parts 列 | 它是表级设置 | 改用 `marks` 列反推 `rows/marks` |
| `compression_codec` 表级设置不存在 | codec 是列级属性 | 改用列定义 `CODEC(LZ4)`/`CODEC(ZSTD(3))` |
| INSERT VALUES 块内行内注释 | 解析器不支持 | 注释移到 INSERT 语句前 |
| `uniqState()` 不能用 INSERT VALUES | VALUES 不支持函数表达式 | 改用 `INSERT ... SELECT` 让函数先求值 |

---

## 批次 3：03-engines ✅

### 完成内容

#### [03-engines/README.md](./03-engines/README.md)（已为专家级，本期保持）
- "本章解决什么问题"对标 11 个核心痛点
- 引擎体系全景图（MergeTree 家族 / Log 家族 / 集成引擎 / 特殊引擎）
- 6 种 MergeTree 变体合并算法本质对比表
- "去重不实时""折叠 sign 镜像""聚合状态 *State/*Merge"等反直觉设计原理详解
- Distributed 表分片键设计 + 两阶段聚合原理
- 11 条常见误区 + 生产铁律

#### [03-engines/01_mergetree_engines.sql](./03-engines/01_mergetree_engines.sql)（深化）
- 6 种 MergeTree 变体（含 GraphiteMergeTree 注释）的写入/合并/查询对比
- Part 生命周期、命名规则、合并算法实验
- ReplacingMergeTree 的 argMax + GROUP BY 替代 FINAL（避免 ILLEGAL_AGGREGATION）
- SummingMergeTree 非数值列陷阱演示
- AggregatingMergeTree + *State/*Merge 完整 ETL（含日→月二级聚合）
- CollapsingMergeTree 正确 sign 镜像写法（含错误反例注释）
- VersionedCollapsingMergeTree 乱序写入实验

#### [03-engines/02_replicated_engines.sql](./03-engines/02_replicated_engines.sql)（重写）
- ReplicatedMergeTree 复制机制（Keeper 协调、Part 复制队列）
- system.replicas / system.replication_queue 关键字段解读
- 5 种 Replicated* 变体完整示例（含 sign 镜像修复）
- 复制表 vs 非复制表 存储对比实验（10w 行写入）
- 副本健康监控（is_leader / is_readonly / queue_size / absolute_delay 告警阈值）
- quorum 强一致配置说明

#### [03-engines/03_log_engines.sql](./03-engines/03_log_engines.sql)（重写）
- TinyLog / StripeLog / Log 三引擎存储结构原理对比
- 三引擎同数据存储大小 + 查询性能对比实验
- system.tables 文件大小查询（修复 `table` → `name` 列名）
- 物理文件结构说明（docker exec ls 验证）
- Log 系列适用场景与生产迁移建议

#### [03-engines/04_integration_engines.sql](./03-engines/04_integration_engines.sql)（重写）
- 集成引擎总览（引擎 vs 表函数对比 + 选型决策表）
- File 引擎三格式（CSV/JSONEachRow/Parquet）+ path 参数正确用法
  - 修复：File 引擎表带 path 参数让数据存到 user_files_path，使 file() 表函数可读
- file() 表函数临时读取实验（CSV + Parquet）
- url() 表函数本地回环演示（CH 自身 HTTP 接口）
- S3/HDFS/MySQL/PG/Redis/Kafka/JDBC 集成引擎配置示例（注释 + 架构图）
- 跨系统 ETL 5 种模式（一次性/增量/流式/全量刷新/冷热分层）
- 生产铁律 + 性能优化（Parquet/disk_cache/JOIN 前过滤/超时）

#### [03-engines/05_special_engines.sql](./03-engines/05_special_engines.sql)（深化）
- Distributed 表路由实验 + 分片键验证
- MaterializedView INSERT 触发 + 目标表落盘
- Buffer 表写入缓冲实验
- Dictionary 字典引擎 + dictGet 查询
- Merge / Set / Join / Null / View 引擎对比
- 修复：Join 表去除 ON CLUSTER，改用 joinGet() 避免 INCOMPATIBLE_TYPE_OF_JOIN
- 修复：MV 的 ORDER BY 引用已转换列名（timestamp → event_date）

#### [03-engines/06_engine_selection_guide_examples.sql](./03-engines/06_engine_selection_guide_examples.sql)（深化）
- 7 个生产场景的完整 DDL + 查询模板
- 修复：ZooKeeper 路径冲突（events → events_log）
- 修复：CollapsingMergeTree sign 镜像写法（含错误反例注释）
- 修复：INSERT VALUES 块内行内注释（移到 INSERT 语句前）
- TTL 自动过期实验 + Part 状态观察

#### [03-engines/06_engine_selection_guide.md](./03-engines/06_engine_selection_guide.md)（重写为专家级）
- 新增"选型心智模型"（三维权衡：存储/可用性/拓扑语义）
- MergeTree 家族 6 选 1 本质（合并时同主键行做什么）
- 7 条选型反例（错误选型的灾难后果 + 正确选型）
- Replicated vs 非 Replicated 决策（异步复制陷阱 + quorum 强一致）
- Distributed 表分片决策 + 分片键设计本质
- 两阶段聚合原理（为什么 avg/uniq 不能直接 sum 再 sum）
- Log 系列选型（临时表三选一 + 为什么生产不用）
- 集成引擎选型（引擎 vs 表函数 + 9 种数据源决策表 + 生产铁律）
- 特殊引擎选型（MV/Distributed/Buffer/Merge/Set/Join/Null/View）
- 完整生产版选型决策树
- 性能基准参考值（写入/查询/压缩比相对值 + 原因解释）
- 6 个生产 DDL 模板（事件日志/状态快照/加法预聚合/复杂聚合/库存/乱序库存）
- 10 道选型自测题（含答案线索）
- 10 条常见误区与纠正
- 与配套 SQL 的对应关系表

### 验证结果
- ✅ 01_mergetree_engines.sql：clickhouse-server-1 零错误
- ✅ 02_replicated_engines.sql：clickhouse-server-1 零错误
- ✅ 03_log_engines.sql：clickhouse-server-1 零错误
- ✅ 04_integration_engines.sql：clickhouse-server-1 零错误
- ✅ 05_special_engines.sql：clickhouse-server-1 零错误
- ✅ 06_engine_selection_guide_examples.sql：clickhouse-server-1 零错误
- ✅ 06_engine_selection_guide.md：重写为专家级选型手册（含心智模型/反例/自测题）

### 修复的 ClickHouse 25.12 兼容性问题（批次 3 新增）
| 问题 | 原因 | 修复方式 |
|------|------|----------|
| File 引擎表数据不在 user_files_path | 默认存到 store/&lt;uuid&gt;/ | File 引擎加 path 参数，让文件落到 user_files_path/&lt;path&gt; |
| `system.tables` 用 `table` 列名 | 应为 `name`（`table` 是别名但不规范） | 全部改为 `name` |
| Join 引擎 ON CLUSTER 导致 INCOMPATIBLE_TYPE_OF_JOIN | Join 是本地内存表，不能分布式 | 去除 ON CLUSTER，改用 `joinGet()` |
| MaterializedView ORDER BY 引用已转换列 | SELECT 中 `toDate(timestamp) AS event_date` 后 ORDER BY 不能用原列名 | ORDER BY 改用 `event_date` |
| ZooKeeper 路径冲突（不同库同名表） | 默认 ZK 路径基于表名 | 表名加后缀（events → events_log）或显式指定 ZK 路径 |
| CollapsingMergeTree sign 写成差值 | sign=-1 行必须是旧值镜像，不是差值 | sign=-1 行写旧值，sign=+1 行写新值 |
| INSERT VALUES 块内行内注释 | 解析器不支持 | 注释移到 INSERT 语句前 |

---

## R0 完成记录（2026-08-02）

### 交付物
1. **根 README.md 重写**：
   - 目录树与实际文件 100% 一致（删除 23 个幽灵文件引用）
   - 加"旧→新章节映射表"（21 旧章 → 14 新章 + 2 附录）
   - 加"目标章节结构"（4 阶段 14 章）
   - 加"重整进行中"说明与进度链接
   - 修正 `system.query_log` 为 `system.query_thread_log`
   - 删除 `test_all_topics.sql`/`run_tests.sh`/`TEST_GUIDE.md` 等不存在文件引用

2. **TRAINING_PLAN.md 重写**：
   - 按 4 阶段 14 章 12 周重新组织学习路径
   - 每个学习单元标注"目标章节/当前文件/状态"，引用全部为真实存在的文件
   - 备份方案从 `ALTER TABLE ... FREEZE` 升级为 `BACKUP/RESTORE` SQL 命令
   - `system.query_log` 改为 `system.query_thread_log`（`SET log_query_threads = 1`）
   - 加"CH 25.12 兼容性注意事项"附录（9 条，基于批次 1-3 验证经验）
   - 加"培训总结"能力维度矩阵

3. **编号冲突标注**：
   - `11-data-update/README.md` 顶部加 R3 合并标注（→ 07-data-mutation）
   - `11-performance/README.md` 顶部加 R7 重命名标注（→ 08-performance）

### 验收
- ✅ 根 README 目录树无幽灵文件
- ✅ TRAINING_PLAN 引用文件全部存在
- ✅ 编号冲突已标注（R3/R7 彻底解决）
- ✅ query_log 引用已修正
- ✅ 备份方案升级为 BACKUP/RESTORE

---

## 下批次计划：R1 — 01-getting-started 合并 + 补全

> **优先级**：P0 阻塞（TRAINING_PLAN 引用的 01-base 04-09 共 6 个文件缺失）

**R1 范围**：
1. 合并 `01-understanding-clickhouse/` 内容到 `01-base/`（6 个入门 sql 作为前 3 节）
2. 重命名 `01-base/` → `01-getting-started/`（用 `git mv` 保留历史）
3. 补全 6 个缺失文件：
   - `04_system_queries.sql` — 系统表查询入门
   - `05_materialized_views.sql` — 物化视图入门
   - `06_data_modeling.sql` — 数据建模入门
   - `07_realtime_writes.sql` — 实时写入入门
   - `08_data_deduplication.sql` — 数据去重入门
   - `09_advanced_features.sql` — 高级特性入门
4. 重写 `01-getting-started/README.md` 达专家级深度（五段式：本章解决什么问题/核心原理/概念对比/常见误区/自测题）
5. 删除 `01-understanding-clickhouse/` 目录（内容已合并）
6. 在集群上验证所有 SQL 文件零错误

**深度标准**（沿用批次 1-3 标杆）：
- 每个文件含【原理】【场景】【对比】【坑】注释
- SQL 在 clickhouse-server-1 零错误执行
- README 含决策表与 ASCII 图

**后续批次**按 R2→R16 顺序推进，详见上方"重整批次进度总览"表。
