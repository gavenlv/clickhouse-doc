---
name: 高性能批量导入完整方案集（含Terraform）
overview: 提供双套方案+完整的GCP Terraform基础设施代码，实现一键部署4分片×2副本架构，包含VM规格、网络配置、存储策略、ClickHouse集群配置
todos:
  - id: create-directory
    content: 创建 15-high-performance-bulk-import 目录和 README.md 总览文档
    status: completed
  - id: gcs-import-sql
    content: 编写 GCS Parquet 导入 SQL 示例（01_gcs_import.sql）
    status: completed
    dependencies:
      - create-directory
  - id: plan-a-solution
    content: 编写方案A：单分片优化方案（02_plan_a_single_shard.sql）
    status: completed
    dependencies:
      - create-directory
  - id: plan-b-solution
    content: 编写方案B：多分片架构方案（03_plan_b_multi_shard.sql）
    status: completed
    dependencies:
      - create-directory
  - id: resource-optimization
    content: 编写资源优化指南文档（04_resource_optimization.md）
    status: completed
    dependencies:
      - create-directory
  - id: error-recovery
    content: 编写错误恢复机制文档（05_error_recovery.md）
    status: completed
    dependencies:
      - create-directory
  - id: monitoring-sql
    content: 编写性能监控 SQL 脚本（06_monitoring.sql）
    status: completed
    dependencies:
      - create-directory
  - id: architecture-analysis
    content: 编写架构瓶颈分析文档（07_architecture_analysis.md）
    status: completed
    dependencies:
      - create-directory
  - id: shell-scripts
    content: 创建 Shell 执行脚本（scripts/目录）
    status: completed
    dependencies:
      - gcs-import-sql
      - plan-a-solution
  - id: config-xml
    content: 创建推荐的导入配置文件（configs/目录）
    status: completed
    dependencies:
      - create-directory
---

## 产品概述

为ClickHouse集群创建高性能批量导入方案，解决从GCS导入150亿行Parquet数据（90列）的性能问题。

## 核心功能

- 提供方案A（单分片优化）和方案B（多分片架构）两套完整解决方案
- **完整的GCP Terraform基础设施代码**（一键部署新架构）
- GCS Parquet文件并行导入策略
- 多线程批量写入优化配置
- 错误恢复与重试机制
- 导入性能监控与调优
- 详细的架构瓶颈分析和解决方案对比
- VM规格设计和存储策略配置

## Tech Stack

- ClickHouse集群（方案B：4分片×2副本 = 8节点 + 3 Keepers）
- **GCP Compute Engine**（高配置VM实例）
- **GCS存储**（数据源和存储策略）
- **Terraform**（基础设施即代码）
- Parquet格式数据导入
- SQL脚本 + Shell脚本

## 实施方案

### 方案A：单分片极致优化（快速实施）

**目标性能**：5-10分钟导入（提升3-6倍）

**核心策略**：

1. 多客户端并行导入（8-16个客户端同时导入不同文件）
2. 最大化插入线程（max_insert_threads = 48，利用95核CPU）
3. 异步复制（insert_quorum = 1，降低副本同步延迟）
4. 批量参数优化（block_size = 1M行）

**关键参数**：

```sql
SETTINGS 
    max_insert_threads = 48,
    max_insert_block_size = 1048576,
    min_insert_block_size_rows = 1000000,
    insert_quorum = 1,
    input_format_parallel_parsing = 1
```

### 方案B：多分片架构改造（性能最优）

**目标性能**：1-2分钟导入（提升15-30倍）

**架构变更**：

- 当前：1分片 × 2副本 = 2节点
- 改造：4分片 × 2副本 = 8节点

**核心策略**：

1. 数据分片：按分区键分布到4个分片
2. 并行写入：4个分片同时处理数据
3. 分布式表：通过Distributed表自动路由

**性能提升来源**：

- 并行度提升：4倍（4个分片同时处理）
- CPU利用率提升：从单节点95核到8节点760核
- 网络带宽提升：GCS到多节点的并行传输

## 性能瓶颈分析

### 瓶颈占比

```
总性能差距：30倍

瓶颈分解：
┌─────────────────────────────────────┐
│ 单分片架构限制      15x  (50%)     │ ← 最大瓶颈
├─────────────────────────────────────┤
│ 双副本同步开销      2x   (15%)     │
├─────────────────────────────────────┤
│ 单节点资源限制      3x   (20%)     │
├─────────────────────────────────────┤
│ 导入参数未优化      2x   (15%)     │
└─────────────────────────────────────┘
```

## 架构设计

### 方案A架构（单分片优化）

**VM规格（经济版）**：

- ClickHouse Server × 2：n2-highmem-32（32 vCPU, 256GB RAM）
- ClickHouse Keeper × 3：n2-standard-2（2 vCPU, 8GB RAM）
- 跳板机 × 1：n2-standard-4（4 vCPU, 16GB RAM）

**存储配置**：

- Extreme Hyperdisk：1TB（写入缓存，热数据）
- Balanced Persistent Disk：5TB（数据存储，温数据）
- GCS Bucket：冷数据和数据源

**总成本**：约$1,460/月

```
┌─────────────────────────────────────────────────────────────────┐
│                     GCS Bucket (Parquet Files)                   │
│    file_001.parquet | file_002.parquet | ... | file_N.parquet   │
└─────────────────────────────────────────────────────────────────┘
                              │
              ┌───────────────┼───────────────┐
              ▼               ▼               ▼
       ┌──────────┐    ┌──────────┐    ┌──────────┐
       │ Client 1 │    │ Client 2 │    │ Client N │
       │ (并行导入)│    │ (并行导入)│    │ (并行导入)│
       └──────────┘    └──────────┘    └──────────┘
              │               │               │
              └───────────────┼───────────────┘
                              ▼
              ┌───────────────────────────────────┐
              │     ClickHouse1 (Replica1)        │
              │     32 vCPU / 256GB RAM           │
              └───────────────────────────────────┘
                              │ (异步复制)
                              ▼
              ┌───────────────────────────────────┐
              │     ClickHouse2 (Replica2)        │
              └───────────────────────────────────┘
                              │
                              ▼
              ┌───────────────────────────────────┐
              │     3 ClickHouse Keepers          │
              └───────────────────────────────────┘
```

### 方案B架构（多分片）

**VM规格（经济版）**：

- ClickHouse Server × 8：n2-highmem-16（16 vCPU, 128GB RAM）
- ClickHouse Keeper × 3：n2-standard-2（2 vCPU, 8GB RAM）
- 跳板机 × 1：n2-standard-8（8 vCPU, 32GB RAM）

**存储配置（每节点）**：

- Extreme Hyperdisk：500GB（热数据，写入缓存）
- Balanced Persistent Disk：3TB（温数据）
- GCS Bucket：冷数据和数据源

**总计算资源**：

- CPU：8节点 × 16核 = 128核
- 内存：8节点 × 128GB = 1TB
- 存储：8节点 × 3.5TB = 28TB

**总成本**：约$1,780/月

```
┌─────────────────────────────────────────────────────────────────┐
│                     GCS Bucket (Parquet Files)                   │
└─────────────────────────────────────────────────────────────────┘
                              │
              ┌───────────────┼───────────────┐
              ▼               ▼               ▼
       ┌──────────┐    ┌──────────┐    ┌──────────┐
       │ Client 1 │    │ Client 2 │    │ Client N │
       └──────────┘    └──────────┘    └──────────┘
              │               │               │
              └───────────────┼───────────────┘
                              ▼
              ┌───────────────────────────────────┐
              │     Distributed Table (入口)       │
              └───────────────────────────────────┘
                              │
          ┌───────────────────┼───────────────────┐
          ▼                   ▼                   ▼
   ┌─────────────┐     ┌─────────────┐     ┌─────────────┐
   │  Shard 1    │     │  Shard 2    │     │  Shard 3/4  │
   │ R1 ◄──► R2  │     │ R1 ◄──► R2  │     │ R1 ◄──► R2  │
   └─────────────┘     └─────────────┘     └─────────────┘
          │                   │                   │
          └───────────────────┼───────────────────┘
                              ▼
              ┌───────────────────────────────────┐
              │     3 ClickHouse Keepers          │
              └───────────────────────────────────┘
```

## 目录结构

创建新目录 `15-high-performance-bulk-import/`，文件组织如下：

```
15-high-performance-bulk-import/
├── README.md                          # [NEW] 方案总览，包含架构图、方案对比、快速开始
├── 01_gcs_import.sql                  # [NEW] GCS Parquet导入基础示例
├── 02_plan_a_single_shard.sql         # [NEW] 方案A：单分片极致优化完整SQL
├── 03_plan_b_multi_shard.sql          # [NEW] 方案B：多分片架构完整SQL
├── 04_resource_optimization.md        # [NEW] CPU/内存/网络资源优化指南
├── 05_error_recovery.md               # [NEW] 错误恢复与重试机制
├── 06_monitoring.sql                  # [NEW] 导入性能监控脚本
├── 07_architecture_analysis.md        # [NEW] 架构瓶颈深度分析
├── scripts/
│   ├── parallel_import_plan_a.sh      # [NEW] 方案A并行导入脚本
│   ├── distributed_import_plan_b.sh   # [NEW] 方案B分布式导入脚本
│   └── benchmark.sh                   # [NEW] 性能基准测试脚本
├── configs/
│   ├── plan_a_settings.xml            # [NEW] 方案A推荐配置
│   ├── plan_b_settings.xml            # [NEW] 方案B推荐配置
│   └── storage_policy.xml             # [NEW] 存储策略配置
└── terraform/                         # [NEW] Terraform基础设施代码
    ├── README.md                      # [NEW] Terraform部署指南
    ├── main.tf                        # [NEW] 主配置文件
    ├── variables.tf                   # [NEW] 变量定义
    ├── outputs.tf                     # [NEW] 输出定义
    ├── providers.tf                   # [NEW] GCP Provider配置
    ├── modules/
    │   ├── vpc/                       # [NEW] VPC网络模块
    │   │   ├── main.tf
    │   │   ├── variables.tf
    │   │   └── outputs.tf
    │   ├── clickhouse_cluster/        # [NEW] ClickHouse集群模块
    │   │   ├── main.tf                # VM实例、磁盘、网络配置
    │   │   ├── variables.tf
    │   │   ├── outputs.tf
    │   │   ├── scripts/
    │   │   │   ├── install_clickhouse.sh  # 安装脚本
    │   │   │   └── configure_cluster.sh   # 集群配置脚本
    │   │   └── templates/
    │   │       ├── clickhouse_config.xml.tpl
    │   │       └── keeper_config.xml.tpl
    │   ├── keepers/                   # [NEW] Keeper集群模块
    │   │   ├── main.tf
    │   │   ├── variables.tf
    │   │   └── outputs.tf
    │   └── gcs_bucket/                # [NEW] GCS存储桶模块
    │       ├── main.tf
    │       ├── variables.tf
    │       └── outputs.tf
    └── environments/
        ├── dev/                       # [NEW] 开发环境配置
        │   ├── main.tf
        │   ├── variables.tf
        │   └── terraform.tfvars
        └── prod/                      # [NEW] 生产环境配置
            ├── main.tf
            ├── variables.tf
            └── terraform.tfvars
```

## 关键代码结构

### Terraform主配置示例

```
# terraform/main.tf
module "vpc" {
  source = "./modules/vpc"

  project_id   = var.project_id
  region       = var.region
  network_name = "clickhouse-network"
}

module "clickhouse_cluster" {
  source = "./modules/clickhouse_cluster"

  project_id      = var.project_id
  region          = var.region
  zone            = var.zone
  network         = module.vpc.network_self_link
  subnetwork      = module.vpc.subnetwork_self_link

  # 方案B：4分片×2副本
  shard_count     = 4
  replica_count   = 2

  # 经济版VM规格
  machine_type    = "n2-highmem-16"  # 16 vCPU, 128GB RAM

  # 存储配置（经济版）
  disk_extreme_size_gb  = 500   # 500GB Extreme Hyperdisk
  disk_balanced_size_gb = 3072  # 3TB Balanced PD

  # 成本优化选项
  preemptible     = var.use_preemptible  # 是否使用可抢占式VM
}

module "keepers" {
  source = "./modules/keepers"

  project_id   = var.project_id
  region       = var.region
  network      = module.vpc.network_self_link
  subnetwork   = module.vpc.subnetwork_self_link

  keeper_count = 3
  machine_type = "n2-standard-2"  # 经济版Keeper规格
}
```

### ClickHouse VM配置示例

```
# terraform/modules/clickhouse_cluster/main.tf
resource "google_compute_instance" "clickhouse" {
  count = var.shard_count * var.replica_count

  name         = "clickhouse-shard${ceil((count.index + 1) / var.replica_count)}-replica${((count.index) % var.replica_count) + 1}"
  machine_type = var.machine_type
  zone         = var.zone

  # 可抢占式VM配置（可选）
  scheduling {
    preemptible = var.preemptible
    automatic_restart = !var.preemptible
  }

  boot_disk {
    initialize_params {
      image = "ubuntu-2204-lts"
      size  = 100
    }
  }

  # Extreme Hyperdisk（热数据）
  attached_disk {
    source = google_compute_disk.extreme[count.index].self_link
  }

  # Balanced PD（温数据）
  attached_disk {
    source = google_compute_disk.balanced[count.index].self_link
  }

  network_interface {
    network    = var.network
    subnetwork = var.subnetwork
    access_config {}
  }

  metadata = {
    shard-id  = ceil((count.index + 1) / var.replica_count)
    replica-id = ((count.index) % var.replica_count) + 1
  }

  metadata_startup_script = file("${path.module}/scripts/install_clickhouse.sh")
}

resource "google_compute_disk" "extreme" {
  count = var.shard_count * var.replica_count

  name  = "clickhouse-extreme-${count.index}"
  type  = "hyperdisk-extreme"
  size  = var.disk_extreme_size_gb
  zone  = var.zone

  provisioned_iops = 50000  # 50K IOPS（经济版）
}
```

### 变量配置示例

```
# terraform/variables.tf
variable "project_id" {
  description = "GCP Project ID"
  type        = string
}

variable "region" {
  description = "GCP Region"
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "GCP Zone"
  type        = string
  default     = "us-central1-a"
}

variable "use_preemptible" {
  description = "Use preemptible VMs for cost savings"
  type        = bool
  default     = false
}

# terraform/environments/prod/terraform.tfvars
project_id      = "your-project-id"
region          = "us-central1"
zone            = "us-central1-a"
use_preemptible = false  # 生产环境使用标准VM

# terraform/environments/dev/terraform.tfvars
project_id      = "your-project-id"
region          = "us-central1"
zone            = "us-central1-a"
use_preemptible = true   # 开发环境使用可抢占式VM节省成本
```

### GCS导入函数

```sql
-- 使用gcs()函数直接读取Parquet文件
INSERT INTO target_table
SETTINGS max_insert_threads = 48
SELECT * FROM gcs(
    'https://storage.googleapis.com/bucket/path/*.parquet',
    'Parquet',
    -- schema auto-detection or explicit definition
);
```

### 分布式表创建（方案B）

```sql
-- 创建分布式表，自动路由到4个分片
CREATE TABLE target_table_all ON CLUSTER 'cluster'
AS target_table_local
ENGINE = Distributed('cluster', 'db', 'target_table_local', rand());
```

## Agent Extensions

### SubAgent

- **code-explorer**
- Purpose: 搜索现有项目中S3/GCS相关的配置和示例代码
- Expected outcome: 获取完整的GCS集成代码参考，确保新方案与现有架构一致

## 实施步骤

### 阶段1：快速实施（方案A）

1. **准备环境**（使用现有集群）

```
# 检查集群状态
cd 15-high-performance-bulk-import/scripts
./check_cluster.sh
```

2. **执行并行导入**

```
# 启动16个客户端并行导入
./parallel_import_plan_a.sh --parallel-clients 16
```

3. **监控性能**

```sql
-- 运行监控SQL
source 06_monitoring.sql
```

**预期结果**：5-10分钟完成导入

### 阶段2：架构升级（方案B）

1. **部署基础设施**

```
cd terraform/environments/prod
terraform init
terraform plan
terraform apply
```

2. **验证集群**

```
# 检查所有节点
gcloud compute ssh clickhouse-shard1-replica1 --zone=us-central1-a
clickhouse-client --query "SELECT * FROM system.clusters"
```

3. **创建分布式表**

```
clickhouse-client --queries-file 03_plan_b_multi_shard.sql
```

4. **执行分布式导入**

```
./distributed_import_plan_b.sh
```

**预期结果**：1-2分钟完成导入

## 成本估算

### 📊 经济配置方案（推荐）

#### 方案A - 经济版（单分片优化）

**VM规格**：

- ClickHouse Server × 2：n2-highmem-32（32 vCPU, 256GB RAM）
- ClickHouse Keeper × 3：n2-standard-2（2 vCPU, 8GB RAM）
- 跳板机 × 1：n2-standard-4（4 vCPU, 16GB RAM）

**存储配置**：

- Extreme Hyperdisk：1TB × 2节点 = $140/月
- Balanced Persistent Disk：5TB × 2节点 = $500/月
- GCS存储：数据源（免费入站）

**成本明细**：

- n2-highmem-32 × 2：$700/月
- n2-standard-2 × 3：$60/月
- n2-standard-4 × 1：$60/月
- 存储（总计12TB）：$640/月
- **总计：约$1,460/月** ✅

**性能预期**：

- 导入时间：8-12分钟
- 并行线程：max_insert_threads = 24
- 适用场景：中等规模数据导入，成本敏感

---

#### 方案A - 超经济版（可抢占式VM）

**VM规格**：

- ClickHouse Server × 2：n2-highmem-32（可抢占式）
- ClickHouse Keeper × 3：e2-standard-2（标准）
- 跳板机 × 1：e2-standard-2（标准）

**成本明细**：

- n2-highmem-32（可抢占）× 2：$210/月
- e2-standard-2 × 4：$120/月
- 存储：$500/月
- **总计：约$830/月** ✅

**注意事项**：

- 可抢占式VM可能被中断（24小时周期）
- 导入任务需支持断点续传
- 适合离线批处理场景

---

#### 方案B - 经济版（多分片架构）

**VM规格**：

- ClickHouse Server × 8：n2-highmem-16（16 vCPU, 128GB RAM）
- ClickHouse Keeper × 3：n2-standard-2（2 vCPU, 8GB RAM）
- 跳板机 × 1：n2-standard-8（8 vCPU, 32GB RAM）

**存储配置（每节点）**：

- Extreme Hyperdisk：500GB × 8节点 = $280/月
- Balanced Persistent Disk：3TB × 8节点 = $1,200/月

**成本明细**：

- n2-highmem-16 × 8：$1,120/月
- n2-standard-2 × 3：$60/月
- n2-standard-8 × 1：$120/月
- 存储（总计28TB）：$1,480/月
- **总计：约$1,780/月** ✅

**性能预期**：

- 导入时间：2-3分钟
- 并行度：4分片同时处理
- 适用场景：高性能要求，预算控制

---

#### 方案B - 超经济版（可抢占式VM）

**VM规格**：

- ClickHouse Server × 8：n2-highmem-16（可抢占式）
- ClickHouse Keeper × 3：e2-standard-2（标准）
- 跳板机 × 1：e2-standard-4（标准）

**成本明细**：

- n2-highmem-16（可抢占）× 8：$336/月
- e2-standard-2 × 3：$90/月
- e2-standard-4 × 1：$48/月
- 存储：$1,000/月
- **总计：约$1,474/月** ✅

---

### 💡 成本优化建议

#### 1. 使用可抢占式VM（Preemptible VMs）

- 节省60-70%计算成本
- 适合批处理任务，但需要容错机制

#### 2. 存储分层优化

```
热数据（最近7天）   → Extreme Hyperdisk（高IOPS）
温数据（7-30天）   → Balanced PD
冷数据（30天以上） → GCS（最便宜）
```

#### 3. 按需启停

- 非导入时段停止部分节点
- 使用实例调度器自动管理

#### 4. 承诺使用折扣（Committed Use）

- 1年承诺：节省约30%
- 3年承诺：节省约50%

---

### 📈 性能与成本对比

| 方案 | 月成本 | 导入时间 | CPU核心 | 内存 | 适用场景 |
| --- | --- | --- | --- | --- | --- |
| 方案A经济版 | $1,460 | 8-12分钟 | 64核 | 512GB | 成本敏感，中等性能 |
| 方案A超经济版 | $830 | 8-12分钟 | 64核 | 512GB | 极限成本控制，可接受中断 |
| 方案B经济版 | $1,780 | 2-3分钟 | 128核 | 1TB | 高性能，预算控制 |
| 方案B超经济版 | $1,474 | 2-3分钟 | 128核 | 1TB | 高性能+成本优化 |


---

### 🎯 推荐选择

**生产环境推荐**：

- **方案A经济版**（$1,460/月）：稳定可靠，适合大多数场景
- **方案B经济版**（$1,780/月）：高性能要求，预算在2K以内

**测试/开发环境**：

- **方案A超经济版**（$830/月）：极限成本控制

**大规模批处理**：

- **方案B超经济版**（$1,474/月）：最高性价比