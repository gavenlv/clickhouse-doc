# 外部集成与数据管道

ClickHouse 不是一座孤岛。生产环境中，数据从 Kafka 流入、经 Flink 清洗、通过 DBT 转换、从 S3 批量导入、在 Superset 上可视化，整个过程中 ClickHouse 需要和多种外部系统打交道。本章覆盖 ClickHouse 与外部生态的全链路集成，从引擎到管道，从实时到批量，从开源到云。

## 本章解决什么问题

| 痛点 | 对应专题 | 一句话解答 |
|------|---------|-----------|
| **数据怎么进 ClickHouse？** | [01 集成引擎](./01_integration_engines.sql) | File/S3/HDFS/MySQL/PG/JDBC 等 9 种集成引擎，引擎 vs 表函数选型决策 |
| **Kafka 数据怎么稳定摄入？** | [02 Kafka 引擎](./02_kafka_engine.md) | Kafka Engine + MV 标准模式、consumer group/offset 管理、exactly-once 去重、多 topic 消费 |
| **Flink 实时计算怎么对接？** | [04 架构](./04_flink_architecture.md) → [10 SLA](./10_flink_realtime_sla.md) | Flink CDC → Kafka → CH 的全链路七层架构 + 秒/分/小时 SLA 分级 |
| **看板怎么做？** | [07 Superset](./07_superset_dashboard.sql) | Flink 版实时看板 + 预测案例版分析看板，两种场景的最佳实践 |
| **TB 级 Parquet 怎么快速导入？** | [11 批量导入](./11_bulk_import_guide.md) → [14 错误恢复](./14_bulk_import_error_recovery.md) | 单分片 8-12 分钟 vs 多分片 2-3 分钟方案对比 + 错误恢复 SOP |
| **SQL 转换逻辑怎么工程化？** | [17 DBT](./17_dbt_integration.md) | DBT 管理 CH 表/视图/MV，6 种物化策略对比 + CI/CD 集成 |
| **数据湖能直接查吗？** | [18 Iceberg](./18_iceberg_lakehouse.md) | Iceberg 表引擎直查数据湖，无需 ETL 导入，schema evolution 自动适配 |
| **不想装服务，能分析文件吗？** | [19 CH Local](./19_clickhouse_local.md) | clickhouse-local 零配置直接分析 CSV/Parquet/JSON，管道模式 |
| **不想管运维，有没有托管服务？** | [20 Cloud](./20_clickhouse_cloud.md) | ClickHouse Cloud vs 自管理对比 + 迁移方案 + 成本优化 |

## 集成体系全景图

```
┌──────────────────────────────────────────────────────────────────────┐
│                      ClickHouse 外部集成全景                          │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  数据摄入层                                                          │
│  ┌─────────┐  ┌─────────┐  ┌──────────┐  ┌──────────┐  ┌─────────┐ │
│  │ Kafka   │  │ Flink   │  │ S3/GCS   │  │ MySQL    │  │ HTTP    │ │
│  │ (实时)  │  │ (CDC)   │  │ (批量)   │  │ (联邦)   │  │ (API)   │ │
│  └────┬────┘  └────┬────┘  └────┬─────┘  └────┬─────┘  └────┬────┘ │
│       │            │            │              │              │      │
│       ▼            ▼            ▼              ▼              ▼      │
│  ┌────────────────────────────────────────────────────────────────┐ │
│  │              ClickHouse 集成引擎层（01_integration_engines）     │ │
│  │  Kafka · File · S3 · HDFS · MySQL · PostgreSQL · JDBC · URL   │ │
│  └────────────────────────────────────────────────────────────────┘ │
│       │                                                              │
│       ▼                                                              │
│  转换与建模层                                                        │
│  ┌──────────────┐  ┌──────────────────┐  ┌─────────────────────┐    │
│  │ DBT (17)     │  │ Flink 建模 (06)   │  │ 物化视图 (CH 内建)  │    │
│  │ T+1 批处理   │  │ 实时 ETL 管道     │  │ 毫秒级预聚合       │    │
│  └──────────────┘  └──────────────────┘  └─────────────────────┘    │
│       │                                                              │
│       ▼                                                              │
│  查询与可视化层                                                      │
│  ┌──────────┐  ┌──────────┐  ┌─────────────────────────────────┐    │
│  │ Superset │  │ Metabase │  │ ClickHouse Local (19)           │    │
│  │ (07)     │  │          │  │ 命令行 Ad-hoc 分析              │    │
│  └──────────┘  └──────────┘  └─────────────────────────────────┘    │
│                                                                      │
│  托管服务                                                            │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │  ClickHouse Cloud (20)                                       │   │
│  │  SharedMergeTree · ClickPipes · 自动扩缩容 · 零运维          │   │
│  └──────────────────────────────────────────────────────────────┘   │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
```

## 核心概念深度

### 集成引擎 vs 表函数：什么时候用谁

这是 ClickHouse 集成中最基础也最容易混淆的概念：

```
引擎（ENGINE = Kafka/S3/MySQL...）
  - CREATE TABLE 持久化对象
  - 可用于物化视图
  - 持续运行，数据"拉"进来
  - 适用场景：生产 ETL 管道

表函数（kafka()/s3()/mysql()/...）
  - 临时 SELECT，用完即弃
  - 不可建物化视图
  - 每次独立连接
  - 适用场景：临时探查、数据预览、一次性导入
```

**典型组合**：表函数探查 + 引擎持久化：

```sql
-- Step 1: 用表函数探查 S3 中的 Parquet Schema
DESCRIBE TABLE s3('s3://bucket/data/*.parquet', 'ak', 'sk');

-- Step 2: 用表函数看几条数据确认格式
SELECT * FROM s3(...) LIMIT 10;

-- Step 3: 创建生产表用 S3 引擎 + 物化视图自动摄入
CREATE TABLE s3_queue ENGINE = S3(...);
CREATE MATERIALIZED VIEW s3_mv TO target AS SELECT * FROM s3_queue;
```

### Kafka → ClickHouse 的三种摄入路径

```
路径 1: Kafka Engine + MV（原生，自管理必备）
  Kafka → [Kafka Engine 表] → [物化视图] → MergeTree
  延迟：秒级    运维成本：中    适用：自管理 ClickHouse

路径 2: Flink → ClickHouse Sink（CDC/复杂 ETL）
  Kafka → [Flink 处理] → [ClickHouseSink] → MergeTree
  延迟：毫秒级  运维成本：高    适用：需要 Flink 做复杂转换

路径 3: ClickPipes（Cloud 托管）
  Kafka → [ClickPipes] → SharedMergeTree
  延迟：秒级    运维成本：无    适用：ClickHouse Cloud
```

### 实时 vs 批量的选择

```
数据延迟要求？
├── 秒级 → Kafka Engine + MV（路径 1）或 Flink Sink（路径 2）
├── 分钟级 → DBT incremental 或 Flink 窗口聚合
├── 小时级 → DBT 全量刷新 + Airflow 调度
└── 天级 → 批量导入（11-14）+ DBT（17）

数据量多大？
├── < 100 MB/h → Kafka Engine（最简方案）
├── 100 MB-10 GB/h → Kafka Engine + 性能调优
├── > 10 GB/h → Flink + 多分片批量导入（11-14）

需要复杂转换？
├── 纯管道（无转换）→ Kafka Engine + MV
├── 轻量转换（过滤/字段映射）→ Kafka Engine + MV 中的 SQL
├── 复杂转换（JOIN 维表/聚合/去重）→ Flink
└── T+1 分析（复杂业务逻辑）→ DBT
```

## 文档导航

### 集成引擎（起点）

| 编号 | 专题 | 文件 | 类型 | 学习难度 |
|------|------|------|------|---------|
| 01 | 集成引擎总览 | [01_integration_engines.sql](./01_integration_engines.sql) | SQL 示例 | 入门 |

### Kafka 深度（实时摄入核心）

| 编号 | 专题 | 文件 | 类型 | 学习难度 |
|------|------|------|------|---------|
| 02 | Kafka 引擎深度 | [02_kafka_engine.md](./02_kafka_engine.md) | 原理文档 | 进阶 |
| 03 | Kafka 引擎示例 | [03_kafka_engine_examples.sql](./03_kafka_engine_examples.sql) | SQL 示例 | 进阶 |

### Flink 实时集成

| 编号 | 专题 | 文件 | 类型 | 学习难度 |
|------|------|------|------|---------|
| 04 | Flink+CH 架构 | [04_flink_architecture.md](./04_flink_architecture.md) | 架构文档 | 进阶 |
| 05 | Flink Sink | [05_flink_clickhouse_sink.sql](./05_flink_clickhouse_sink.sql) | SQL 示例 | 进阶 |
| 06 | CH 建模 | [06_flink_clickhouse_modeling.sql](./06_flink_clickhouse_modeling.sql) | SQL 示例 | 进阶 |
| 08 | 全链路优化 | [08_flink_optimization.md](./08_flink_optimization.md) | 最佳实践 | 高级 |
| 09 | 最佳实践 | [09_flink_best_practices.md](./09_flink_best_practices.md) | 最佳实践 | 进阶 |
| 09 | 数据流转 | [09_flink_data_flow.md](./09_flink_data_flow.md) | 架构文档 | 进阶 |
| 10 | 实时 SLA | [10_flink_realtime_sla.md](./10_flink_realtime_sla.md) | 运维文档 | 高级 |

### 可视化（Superset）

| 编号 | 专题 | 文件 | 类型 | 学习难度 |
|------|------|------|------|---------|
| 07 | Superset 看板 | [07_superset_dashboard.sql](./07_superset_dashboard.sql) | SQL 示例 | 入门 |
| 07 | 下钻明细 | [07_superset_drill_down.md](./07_superset_drill_down.md) | 原理文档 | 进阶 |

### 批量导入

| 编号 | 专题 | 文件 | 类型 | 学习难度 |
|------|------|------|------|---------|
| 11 | 批量导入指南 | [11_bulk_import_guide.md](./11_bulk_import_guide.md) | 方案文档 | 进阶 |
| 12 | GCS 导入 | [12_bulk_import_gcs.sql](./12_bulk_import_gcs.sql) | SQL 示例 | 进阶 |
| 12 | 方案 A（单分片） | [12_bulk_import_plan_a.sql](./12_bulk_import_plan_a.sql) | SQL 示例 | 进阶 |
| 12 | 方案 B（多分片） | [12_bulk_import_plan_b.sql](./12_bulk_import_plan_b.sql) | SQL 示例 | 高级 |
| 13 | 导入监控 | [13_bulk_import_monitoring.sql](./13_bulk_import_monitoring.sql) | SQL 示例 | 进阶 |
| 14 | 错误恢复 | [14_bulk_import_error_recovery.md](./14_bulk_import_error_recovery.md) | 运维文档 | 进阶 |

### 业务案例

| 编号 | 专题 | 文件 | 类型 | 学习难度 |
|------|------|------|------|---------|
| 15 | 预测数据库案例 | [15_prediction_case_study.md](./15_prediction_case_study.md) | 案例文档 | 进阶 |
| 16 | DDL + 查询优化 | [16_prediction_ddl.sql](./16_prediction_ddl.sql) 等 3 个文件 | SQL 示例 | 进阶 |

### 工具与生态（新建专题）

| 编号 | 专题 | 文件 | 类型 | 学习难度 |
|------|------|------|------|---------|
| 17 | DBT 集成 | [17_dbt_integration.md](./17_dbt_integration.md) | 工具指南 | 进阶 |
| 18 | Iceberg & Lakehouse | [18_iceberg_lakehouse.md](./18_iceberg_lakehouse.md) | 架构文档 | 高级 |
| 19 | ClickHouse Local | [19_clickhouse_local.md](./19_clickhouse_local.md) | 工具指南 | 入门 |
| 20 | ClickHouse Cloud | [20_clickhouse_cloud.md](./20_clickhouse_cloud.md) | 服务对比 | 入门 |

## 快速上手：根据你的场景选入口

### 场景 A：我要从 Kafka 实时摄入数据

```
第 1 步：读 02_kafka_engine.md（理解 Kafka Engine 原理）
第 2 步：读 03_kafka_engine_examples.sql（跟着 SQL 搭建摄入管道）
第 3 步：如果消息需要复杂转换 → 跳转 04_flink_architecture.md
```

### 场景 B：我要把 Parquet/CSV 批量导入 ClickHouse

```
第 1 步：读 11_bulk_import_guide.md（方案 A vs B 选型）
第 2 步：读 12_bulk_import_gcs.sql + plan_a/b（操作 SQL）
第 3 步：读 06_flink_clickhouse_modeling.sql（导入后的建模）
```

### 场景 C：我要搭建 Flink + ClickHouse 实时数仓

```
第 1 步：读 04_flink_architecture.md（理解七层架构）
第 2 步：读 05_flink_clickhouse_sink.sql（Flink 写入 CH）
第 3 步：读 06_flink_clickhouse_modeling.sql（CH 侧分层建模）
第 4 步：读 07_superset_dashboard.sql（看板呈现）
```

### 场景 D：我要用 DBT 管理 ClickHouse 的 SQL 转换

```
第 1 步：读 17_dbt_integration.md（安装→配置→物化策略）
第 2 步：读 01_integration_engines.sql 的 JDBC/MySQL 部分（DBT 通过 JDBC 连接）
第 3 步：读 09_flink_best_practices.md（DI 最佳实践与 DBT 互补）
```

### 场景 E：我想评估是否迁移到 ClickHouse Cloud

```
第 1 步：读 20_clickhouse_cloud.md（Cloud vs 自管理对比）
第 2 步：读 11-14 批量导入和 02-03 Kafka（对比自管理的摄入方案）
第 3 步：读 10-security/README.md（Cloud 已托管的安全能力）
```

## 常见误区

| 误区 | 现实 |
|------|------|
| **"Kafka Engine 就够了，不需要物化视图"** | 没有 MV，Kafka Engine 表的数据不会持久化。每次 SELECT 直接从 Kafka 重新拉取，越来越慢 |
| **"表函数和引擎没区别"** | 表函数不能建物化视图，不能持续运行，每次独立连接。生产 ETL 必须用引擎 |
| **"批量导入就是简单的 INSERT SELECT"** | TB 级数据需要并行策略、分区规划、错误恢复，直接 INSERT SELECT 可能跑 30 分钟还失败 |
| **"DBT 能替代 ClickHouse 物化视图"** | DBT 是定时调度（T+1 等），物化视图是 INSERT 触发器（毫秒级）。实时场景必须用 MV |
| **"Iceberg 查起来和本地表一样快"** | Iceberg 数据在 S3 上，每次查询有网络延迟。高频查询需要缓存到 MergeTree |
| **"ClickHouse Cloud 就是开源版加个 UI"** | Cloud 用了 SharedMergeTree 存算分离架构，Kafka Engine 用 ClickPipes 替代，有本质差异 |
| **"clickhouse-local 只是个玩具"** | 它内嵌了完整的 CH 查询引擎，分析 GB 级文件可以秒出结果，是 ETL 和日志分析的利器 |

## 集成选型检查清单

### 数据摄入
- [ ] 确认了数据源类型（Kafka / S3 / MySQL / API）
- [ ] 选择了正确的集成方式（引擎 vs 表函数 vs ClickPipes）
- [ ] Kafka 摄入配置了 MV（非可选）
- [ ] Kafka 配置了去重策略（_topic+_partition+_offset）
- [ ] 批量导入方案选定了 A（单分片）或 B（多分片）

### 数据转换
- [ ] 实时转换走 Flink 或 MV，批处理转换走 DBT
- [ ] DBT 物化策略匹配数据量（小表 view、大表 incremental）
- [ ] 数据质量测试已配置（DBT tests 或自定义 SQL）

### 查询与可视化
- [ ] Superset 数据集分层（物理数据集 vs 虚拟数据集）
- [ ] 看板缓存策略已配置（避免重复扫全表）
- [ ] 行级权限已配置（多租户/多部门场景）

### 运维与监控
- [ ] 摄入延迟已监控（Kafka lag / Flink backlog）
- [ ] 批量导入错误恢复 SOP 已就绪
- [ ] 备份策略已配置（自管理：BACKUP/RESTORE，Cloud：自动）

## 学习路径建议

```
第一天：01（集成引擎）→ 02+03（Kafka 深度）→ 动手搭建一条 Kafka → CH 管道
第二天：04+05+06（Flink 全链路）→ 07（Superset 看板）
第三天：11+12+13+14（批量导入）→ 15+16（预测案例）
第四天：17（DBT）→ 19（CH Local）→ 20（Cloud）
第五天：18（Iceberg/Lakehouse）→ 回顾全局，形成自己的集成选型方法论
```

## 相关章节

- [点击前往 04-engines（表引擎）](../04-engines/README.md) —— MergeTree 家族详情
- [点击前往 08-performance（性能优化）](../08-performance/README.md) —— 摄入性能优化
- [点击前往 09-distributed（分布式架构）](../09-distributed/README.md) —— 分片策略与多分片导入
- [点击前往 10-security（安全）](../10-security/README.md) —— 集成场景的安全配置

---
**注意**：本章 Kafka/DBT/Superset 的配置需替换为实际环境参数。批量导入方案 A/B 的性能数据基于 `treasurycluster` 集群（CH 25.12.1.649）。
