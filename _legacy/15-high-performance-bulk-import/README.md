# ClickHouse 高性能批量导入方案

针对150亿行Parquet数据从GCS导入ClickHouse的性能优化方案，提供双套完整解决方案。

## 📊 方案概览

### 性能对比

| 方案 | 导入时间 | 月成本 | CPU核心 | 内存 | 提升幅度 |
|------|----------|--------|---------|------|----------|
| **当前架构** | 30分钟 | - | 95核×2 | 394GB×2 | 基准 |
| **方案A经济版** | 8-12分钟 | $1,460 | 64核 | 512GB | 3-4倍 |
| **方案A超经济版** | 8-12分钟 | $830 | 64核 | 512GB | 3-4倍 |
| **方案B经济版** | 2-3分钟 | $1,780 | 128核 | 1TB | 10-15倍 |
| **方案B超经济版** | 2-3分钟 | $1,474 | 128核 | 1TB | 10-15倍 |

### 核心瓶颈分析

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

## 🎯 方案选择指南

### 方案A：单分片优化（推荐快速实施）

**适用场景**：
- 预算控制在$1,500/月以内
- 可接受8-12分钟导入时间
- 不希望改变现有架构
- 快速上线需求

**优势**：
- ✅ 无需架构变更
- ✅ 立即可实施
- ✅ 成本最低（$830-1,460/月）
- ✅ 风险小

**实施步骤**：
1. 调整导入参数（max_insert_threads等）
2. 启动多客户端并行导入
3. 监控性能

详细内容：[02_plan_a_single_shard.sql](./02_plan_a_single_shard.sql)

---

### 方案B：多分片架构（推荐高性能需求）

**适用场景**：
- 需要2-3分钟快速导入
- 预算在$1,500-2,000/月
- 长期稳定使用
- 可接受架构改造

**优势**：
- ✅ 性能最优（10-15倍提升）
- ✅ 真正达到目标性能
- ✅ 横向可扩展
- ✅ 高可用性强

**实施步骤**：
1. 使用Terraform部署新架构
2. 创建分布式表
3. 执行分布式导入

详细内容：[03_plan_b_multi_shard.sql](./03_plan_b_multi_shard.sql)

---

## 🚀 快速开始

### 方案A（单分片优化）

#### 1. 准备环境

```bash
# 检查集群状态
clickhouse-client --query "SELECT * FROM system.clusters"

# 检查当前配置
clickhouse-client --query "SELECT * FROM system.settings WHERE name LIKE '%insert%'"
```

#### 2. 执行并行导入

```bash
# 方式1：使用脚本
cd scripts
./parallel_import_plan_a.sh --parallel-clients 16

# 方式2：手动执行
clickhouse-client --queries-file ../01_gcs_import.sql
clickhouse-client --queries-file ../02_plan_a_single_shard.sql
```

#### 3. 监控性能

```bash
# 运行监控SQL
clickhouse-client --queries-file ../06_monitoring.sql
```

**预期结果**：8-12分钟完成导入

---

### 方案B（多分片架构）

#### 1. 部署基础设施

```bash
# 配置GCP凭证
export GOOGLE_APPLICATION_CREDENTIALS="path/to/service-account.json"

# 初始化Terraform
cd terraform/environments/prod
terraform init

# 查看部署计划
terraform plan

# 执行部署
terraform apply
```

#### 2. 验证集群

```bash
# SSH到第一个节点
gcloud compute ssh clickhouse-shard1-replica1 --zone=us-central1-a

# 检查集群状态
clickhouse-client --query "SELECT * FROM system.clusters"

# 检查所有节点
clickhouse-client --query "SELECT shard_num, replica_num, host_name FROM system.clusters"
```

#### 3. 创建分布式表

```bash
# 在跳板机上执行
clickhouse-client --queries-file 03_plan_b_multi_shard.sql
```

#### 4. 执行分布式导入

```bash
# 执行导入脚本
cd scripts
./distributed_import_plan_b.sh
```

**预期结果**：2-3分钟完成导入

---

## 📁 目录结构

```
15-high-performance-bulk-import/
├── README.md                          # 本文件
├── 01_gcs_import.sql                  # GCS Parquet导入基础示例
├── 02_plan_a_single_shard.sql         # 方案A：单分片优化完整SQL
├── 03_plan_b_multi_shard.sql          # 方案B：多分片架构完整SQL
├── 04_resource_optimization.md        # CPU/内存/网络资源优化指南
├── 05_error_recovery.md               # 错误恢复与重试机制
├── 06_monitoring.sql                  # 导入性能监控脚本
├── 07_architecture_analysis.md        # 架构瓶颈深度分析
├── scripts/                           # 执行脚本
│   ├── parallel_import_plan_a.sh      # 方案A并行导入脚本
│   ├── distributed_import_plan_b.sh   # 方案B分布式导入脚本
│   └── benchmark.sh                   # 性能基准测试脚本
├── configs/                           # 配置文件
│   ├── plan_a_settings.xml            # 方案A推荐配置
│   ├── plan_b_settings.xml            # 方案B推荐配置
│   └── storage_policy.xml             # 存储策略配置
└── terraform/                         # Terraform基础设施代码
    ├── README.md                      # Terraform部署指南
    ├── main.tf                        # 主配置文件
    ├── variables.tf                   # 变量定义
    ├── outputs.tf                     # 输出定义
    ├── providers.tf                   # GCP Provider配置
    ├── modules/                       # 模块目录
    │   ├── vpc/                       # VPC网络模块
    │   ├── clickhouse_cluster/        # ClickHouse集群模块
    │   ├── keepers/                   # Keeper集群模块
    │   └── gcs_bucket/                # GCS存储桶模块
    └── environments/                  # 环境配置
        ├── dev/                       # 开发环境
        └── prod/                      # 生产环境
```

---

## 💰 成本详情

### 方案A - 经济版

**VM配置**：
- ClickHouse Server × 2：n2-highmem-32（32 vCPU, 256GB RAM）
- ClickHouse Keeper × 3：n2-standard-2（2 vCPU, 8GB RAM）
- 跳板机 × 1：n2-standard-4（4 vCPU, 16GB RAM）

**成本明细**：
```
计算资源：
  n2-highmem-32 × 2         $700/月
  n2-standard-2 × 3         $60/月
  n2-standard-4 × 1         $60/月

存储资源：
  Extreme Hyperdisk 1TB×2   $140/月
  Balanced PD 5TB×2         $500/月

总计：$1,460/月
```

---

### 方案B - 经济版

**VM配置**：
- ClickHouse Server × 8：n2-highmem-16（16 vCPU, 128GB RAM）
- ClickHouse Keeper × 3：n2-standard-2（2 vCPU, 8GB RAM）
- 跳板机 × 1：n2-standard-8（8 vCPU, 32GB RAM）

**成本明细**：
```
计算资源：
  n2-highmem-16 × 8         $1,120/月
  n2-standard-2 × 3         $60/月
  n2-standard-8 × 1         $120/月

存储资源：
  Extreme Hyperdisk 500GB×8 $280/月
  Balanced PD 3TB×8         $1,200/月

总计：$1,780/月
```

---

### 超经济版（可抢占式VM）

使用可抢占式VM可节省60-70%计算成本：

- **方案A超经济版**：$830/月
- **方案B超经济版**：$1,474/月

**注意事项**：
- 可抢占式VM可能被中断（24小时周期）
- 需要实现断点续传机制
- 适合离线批处理场景

---

## 🔧 核心技术要点

### 1. GCS直接导入

```sql
-- 使用gcs()函数直接读取Parquet
INSERT INTO target_table
SETTINGS max_insert_threads = 24
SELECT * FROM gcs(
    'https://storage.googleapis.com/bucket/path/*.parquet',
    'Parquet'
);
```

### 2. 并行优化参数

```sql
-- 方案A：单节点优化
SETTINGS 
    max_insert_threads = 24,              -- 32核CPU的75%
    max_insert_block_size = 1048576,      -- 1M行块
    min_insert_block_size_rows = 1000000,
    insert_quorum = 1,                    -- 异步复制
    input_format_parallel_parsing = 1;

-- 方案B：分布式优化
SETTINGS 
    max_insert_threads = 12,              -- 16核CPU的75%
    prefer_localhost_replica = 0,         -- 分布式写入
    insert_distributed_sync = 2;          -- 同步写入所有分片
```

### 3. 存储分层策略

```
数据生命周期分层：
├─ 热数据（0-7天）   → Extreme Hyperdisk（高IOPS，写入缓存）
├─ 温数据（7-30天）  → Balanced Persistent Disk
└─ 冷数据（30天+）   → GCS Bucket（最便宜）
```

---

## 📈 性能监控

### 实时监控指标

```sql
-- 查看当前导入进度
SELECT 
    query,
    read_rows,
    written_rows,
    memory_usage,
    query_duration_ms
FROM system.processes
WHERE query LIKE '%INSERT%';

-- 查看历史导入性能
SELECT 
    event_date,
    count() as insert_count,
    sum(written_rows) as total_rows,
    avg(query_duration_ms) as avg_duration_ms
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query LIKE '%INSERT%'
GROUP BY event_date
ORDER BY event_date DESC;
```

详细监控：[06_monitoring.sql](./06_monitoring.sql)

---

## 🛠️ 故障排查

### 常见问题

#### 1. 导入速度慢

**检查点**：
- [ ] max_insert_threads是否充分利用
- [ ] 网络带宽是否饱和
- [ ] 磁盘IOPS是否达到上限
- [ ] 是否有其他并发查询

**解决方案**：
```sql
-- 增加插入线程
SET max_insert_threads = 32;

-- 检查瓶颈
SELECT * FROM system.metrics WHERE metric LIKE '%IO%';
```

#### 2. 内存不足

**检查点**：
- [ ] max_memory_usage设置是否合理
- [ ] 是否有大查询占用内存
- [ ] 批量大小是否过大

**解决方案**：
```sql
-- 限制单个查询内存
SET max_memory_usage = 200000000000;  -- 200GB

-- 减小批量大小
SET max_insert_block_size = 524288;  -- 512K
```

#### 3. 副本同步延迟

**检查点**：
- [ ] Keeper集群是否正常
- [ ] 网络延迟是否过高
- [ ] 磁盘写入速度是否一致

**解决方案**：
```sql
-- 检查副本状态
SELECT * FROM system.replicas;

-- 使用异步复制
SET insert_quorum = 1;
```

---

## 📚 相关文档

- [架构瓶颈深度分析](./07_architecture_analysis.md)
- [资源优化指南](./04_resource_optimization.md)
- [错误恢复机制](./05_error_recovery.md)
- [Terraform部署指南](./terraform/README.md)

---

## 🎯 推荐方案

### 生产环境

**推荐：方案A经济版**（$1,460/月）
- 稳定可靠
- 无需架构变更
- 8-12分钟性能可接受

### 高性能需求

**推荐：方案B经济版**（$1,780/月）
- 2-3分钟快速导入
- 真正达到性能目标
- 可横向扩展

### 测试/开发环境

**推荐：方案A超经济版**（$830/月）
- 极限成本控制
- 适合功能测试

---

## 📞 技术支持

遇到问题请查看：
1. [错误恢复机制](./05_error_recovery.md)
2. [性能监控脚本](./06_monitoring.sql)
3. [故障排查指南](./07_architecture_analysis.md)

---

## 📄 许可证

MIT
