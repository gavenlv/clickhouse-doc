# ClickHouse Cloud

ClickHouse Cloud 是 ClickHouse 官方提供的全托管数据库服务。它把运维的复杂性（扩容、备份、升级、安全）打包成了 SaaS 体验，同时保留了开源 ClickHouse 的全部 SQL 能力。本章对比 ClickHouse Cloud 与自管理的差异，帮助判断何时应该迁移。

## 目录

- [Cloud vs 自管理 ClickHouse](#cloud-vs-自管理-clickhouse)
- [Cloud 独有功能](#cloud-独有功能)
- [Cloud API 与自动化](#cloud-api-与自动化)
- [迁移到 Cloud](#迁移到-cloud)
- [成本模型与优化](#成本模型与优化)
- [与开源版的功能差异](#与开源版的功能差异)

## Cloud vs 自管理 ClickHouse

### 核心差异

| 维度 | ClickHouse Cloud | 自管理 ClickHouse |
|------|-----------------|-------------------|
| **基础设施** | 无需管理服务器、网络、磁盘 | 需要自己部署和维护 |
| **扩容** | 自动扩缩容（基于 CPU/内存/IO 使用率） | 手动调整节点配置和数量 |
| **备份恢复** | 自动连续备份，点选恢复 | 需要自己配置 BACKUP/RESTORE 脚本 |
| **版本升级** | 自动滚动升级，零停机 | 需要自己做蓝绿或滚动升级 |
| **安全** | 内建 TLS、IP 白名单、SSO、审计 | 需要自己配置（参考 10-security 章节） |
| **性能** | SharedMergeTree 云原生引擎，存算分离 | 本地 MergeTree，存算一体 |
| **物化视图** | 支持，但调度策略不同 | 支持，完全自定义 |
| **Kafka Engine** | 不直接支持（用 ClickPipes 替代） | 直接支持 |
| **Keeper** | 内建，无需管理 | 需要自己部署 Keeper 集群 |
| **数据格式** | SharedMergeTree（兼容 MergeTree 全部语法） | MergeTree 全家族 |

### 选型决策矩阵

```
你有专门的 DBA 团队吗？
├── 有（≥2 人） → 自管理（成本更低，控制力更强）
└── 没有 → Cloud（运维被托管）

你的数据量每月增长多少？
├── < 1 TB/月 → Cloud（起步快，弹性好）
├── 1-10 TB/月 → Cloud 或自管理（取决于运维能力）
└── > 10 TB/月 → 自管理（Cloud 的成本在这个量级会很高）

你需要 Kafka Engine 和 ReplicatedMergeTree 的深度控制吗？
├── 需要 → 自管理（Cloud 用 ClickPipes 替代 Kafka Engine）
└── 不需要 → Cloud

你的合规要求允许数据上云吗？
├── 允许 → Cloud
└── 不允许（金融/政府） → 自管理（私有部署）
```

## Cloud 独有功能

### SharedMergeTree — 云原生存算分离

SharedMergeTree 是 ClickHouse Cloud 的默认表引擎，它的核心思想是**存储和计算分离**：

```
自管理 ClickHouse：
  服务器 1         服务器 2
  ├── CPU/内存      ├── CPU/内存
  ├── 本地 SSD      ├── 本地 SSD
  └── 数据副本 1    └── 数据副本 2
       ↑ 数据和计算绑定，扩容 = 迁移数据

ClickHouse Cloud：
  计算节点 A        计算节点 B        计算节点 C
  ├── CPU/内存      ├── CPU/内存      ├── CPU/内存
  └── 缓存层         └── 缓存层         └── 缓存层
       │                │                │
       └────────────────┴────────────────┘
                        │
              共享对象存储（S3/GCS）
              ├── Part 数据文件
              └── 所有计算节点共享
```

**SharedMergeTree 的优势**：
- 计算节点之间**无需通信**（没有 ReplicatedMergeTree 的复制开销）
- 计算节点可以**秒级增减**（没有数据重新分布）
- 写入由一个节点完成，其他节点**即时可见**（比 ReplicatedMergeTree 快）
- 数据在对象存储中自动备份

**语法兼容性**：SharedMergeTree 完全兼容 MergeTree 的所有 SQL 语法（ORDER BY / PARTITION BY / TTL / CODEC 等），所以从自管理迁移不需要改 SQL。

### ClickPipes — 托管的 Kafka/对象存储摄入

```
ClickPipes 是 Cloud 的托管数据摄入服务，替代了自管理的 Kafka Engine：

自管理（需要自己维护）：                          Cloud（ClickPipes 托管）：
  Kafka → Kafka Engine → MV → MergeTree          Kafka → ClickPipes → SharedMergeTree
  你需要：                                         你只需要：
  ├── 创建 Kafka Engine 表                        ├── Web UI 点击"New Pipe"
  ├── 创建 MV                                     ├── 选 Kafka Topic
  ├── 监控 consumer lag                           ├── 选目标表
  ├── 处理 rebalance                              └── 点 "Create"
  └── 管理 offset

  S3/GCS → s3() 表函数 → INSERT SELECT           S3/GCS → ClickPipes → SharedMergeTree
  你需要：                                         你只需要：
  ├── 写 ETL 脚本                                 ├── Web UI 配置
  ├── 调度（Airflow/Cron）                        └── 自动增量 + Schema 推断
  └── 错误处理
```

### SQL Console — 内建查询编辑器

Cloud 提供 Web 端的 SQL Console，直接替代 clickhouse-client 的大部分操作：

```
功能对比：
  clickhouse-client 命令行     Cloud SQL Console
  ├── 交互式查询               ├── 多 Tab 查询编辑器
  ├── --format PrettyCompact   ├── 图表可视化（结果自动图表化）
  ├── -m 多行模式              ├── 语法高亮 + 自动补全
  ├── 无历史保存               ├── 查询历史自动保存
  └── 本地运行                 └── 浏览器运行 + 分享链接
```

### Integrations — 一键连接生态

Cloud 支持通过 Web UI 一键连接外部服务：

| 集成类型 | 支持的服务 |
|---------|-----------|
| **数据摄入** | Kafka / Confluent Cloud / S3 / GCS / Kinesis |
| **BI 工具** | Superset / Metabase / Tableau / Looker / Grafana |
| **ETL 工具** | DBT / Airbyte / Fivetran / Airflow |
| **编程语言** | Python / Go / Node.js / Java / Rust（官方 SDK） |

## Cloud API 与自动化

### REST API 管理服务

```bash
# 创建服务
curl -X POST https://api.clickhouse.cloud/v1/organizations/{orgId}/services \
  -H "Authorization: Bearer $CH_CLOUD_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "analytics-prod",
    "provider": "aws",
    "region": "us-east-1",
    "tier": "production",
    "idleScaling": true,
    "minTotalMemoryGb": 24,
    "maxTotalMemoryGb": 96
  }'

# 查询服务状态
curl https://api.clickhouse.cloud/v1/organizations/{orgId}/services/{serviceId} \
  -H "Authorization: Bearer $CH_CLOUD_TOKEN"

# 暂停服务（节省成本）
curl -X PATCH https://api.clickhouse.cloud/v1/organizations/{orgId}/services/{serviceId} \
  -H "Authorization: Bearer $CH_CLOUD_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"idleScaling": true, "minTotalMemoryGb": 0}'
```

### Terraform 管理

```hcl
# main.tf
resource "clickhouse_service" "analytics" {
  name         = "analytics-prod"
  cloud_provider = "aws"
  region       = "us-east-1"
  tier         = "production"
  
  idle_scaling = true
  min_memory_gb = 24
  max_memory_gb = 96
  
  ip_access_list = [
    {
      source      = "10.0.0.0/8"
      description = "Internal VPC"
    },
    {
      source      = "${var.office_ip}/32"
      description = "Office VPN"
    }
  ]
}
```

## 迁移到 Cloud

### 从自管理 ClickHouse 迁移

```
迁移流程图：

自管理 CH ──① 评估──→ Cloud Sizing Tool
   │
   ② 导出 Schema
   │  clickhouse-client -q "SHOW CREATE TABLE ..." > schema.sql
   │
   ③ 迁移数据（4 种方式选 1）
   ├── 方式 A: clickhouse-client 远程 INSERT SELECT（< 100GB）
   ├── 方式 B: BACKUP TO S3 → RESTORE（> 100GB）  
   ├── 方式 C: clickhouse-local → Parquet → S3 → ClickPipes
   └── 方式 D: 双写过渡（Flink → 同时写 CH 和 Cloud）
   │
   ④ 切流量
   │  应用 → 新的 Cloud 连接串
   │
   ⑤ 下线旧集群
```

### 迁移 SQL 示例

```sql
-- Step 1: 导出表结构
-- 在旧集群执行
SELECT create_table_query
FROM system.tables
WHERE database NOT IN ('system', 'INFORMATION_SCHEMA')
FORMAT TSV
-- → 保存为 schema.sql

-- Step 2: 在 Cloud 创建表
-- 注意：Engine 从 MergeTree/ReplicatedMergeTree 改为 SharedMergeTree
-- Cloud 上会自动处理，无需手动指定 ENGINE
-- 粘贴 schema.sql 中的 CREATE TABLE（Engine 部分 Cloud 会自动适配）

-- Step 3: 迁移数据（方式 A：远程 INSERT）
INSERT INTO FUNCTION
    remoteSecure('cloud-instance.clickhouse.cloud:9440', 'db', 'table',
                 'cloud_user', 'cloud_password')
SELECT * FROM local_db.local_table;
```

## 成本模型与优化

### Cloud 的计费模式

```
成本 = 计算单元（Compute Units）× 运行时间 + 存储量 × 存储时间 + 数据传输量

Compute Units = CPU + 内存
  ├── Production tier: 24-96 GB 内存起
  └── Development tier: 固定 8 GB 内存（适合开发/测试）

存储：按压缩后计费（ClickHouse 压缩比 5-10x，比 Redshift/BigQuery 便宜）
```

### 降成本策略

| 策略 | 效果 | 配置方式 |
|------|------|---------|
| **Idle Scaling** | 空闲时自动缩到 0，有查询时自动起 | Cloud Console → Settings → Idle Scaling |
| **TTL 自动清理** | 过期数据自动删除，减少存储费 | `TTL created_at + INTERVAL 90 DAY DELETE` |
| **物化视图预聚合** | 减少重复扫描原始数据 | SharedMergeTree + MV |
| **Dev Tier** | 开发/测试用小规格（便宜 80%） | Service → Settings → Tier |
| **休眠** | 不使用时暂停服务 | API / Console → Pause |

## 与开源版的功能差异

### 不支持或受限的功能

| 功能 | 开源 ClickHouse | ClickHouse Cloud | 替代方案 |
|------|---------------|-----------------|---------|
| **Kafka Engine** | 完整支持 | 不支持（需 ClickPipes） | ClickPipes 托管摄入 |
| **ReplicatedMergeTree** | 完整支持 | 不支持（用 SharedMergeTree） | SharedMergeTree 自动替代 |
| **自定义 Keeper 配置** | 任意配置 | 不可配置（内建） | 无需调整（自动优化） |
| **某些 SETTINGS** | 全部可用 | 部分受限（如 max_server_memory_usage） | 计费配置替代 |
| **自定义用户/角色** | 完整支持 | 支持，但通过 Cloud Console | 也可以用 SQL RBAC |
| **UDF（用户自定义函数）** | 完整支持 | 受限 | 用 SQL 逻辑替代 |
| **字典（Dictionary）** | 任意数据源 | 支持，但外部连接受网络限制 | Cloud 内的字典资源 |
| **BACKUP/RESTORE 任意路径** | 任意 S3/GCS/文件系统 | Cloud 托管备份 | Cloud Console→Backups |

### 始终可用的核心能力

以下能力在 Cloud 和自管理中完全一致，无需修改：

- ✅ 全部 SQL 语法（SELECT/JOIN/窗口函数/CTE/GROUP BY）
- ✅ 全部数据类型（含 LowCardinality、Map、Nested、JSON）
- ✅ MergeTree ORDER BY / PARTITION BY / TTL / CODEC
- ✅ 物化视图（Materialized View）
- ✅ Projections
- ✅ 跳数索引（Skip Indexes）
- ✅ RBAC（角色、用户、行级安全）
- ✅ Dictionaries（字典）
- ✅ 全部聚合函数和数组函数
- ✅ 标准驱动（JDBC/ODBC/Go/Python/Node.js/HTTP）

## 相关文档

- [点击前往 ClickHouse Local 指南](./19_clickhouse_local.md) —— Cloud 环境下的临时分析工具
- [点击前往 DBT 集成](./17_dbt_integration.md) —— DBT + Cloud 的最佳实践
- [点击前往 10-security（安全）](../10-security/README.md) —— 安全配置（Cloud 中大部分已托管）
- [点击前往 11-monitoring-ops（运维）](../11-monitoring-ops/README.md) —— 自管理的运维内容（Cloud 已自动化）
- [ClickHouse Cloud 官方文档](https://clickhouse.com/docs/en/cloud/overview)
- [Cloud API Reference](https://clickhouse.com/docs/en/cloud/manage/api)
