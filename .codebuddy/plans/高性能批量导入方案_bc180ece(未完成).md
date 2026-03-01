---
name: 高性能批量导入方案
overview: 为GCP VM上的ClickHouse集群设计高性能数据导入方案，解决从GCS导入150亿行Parquet数据（90列）的性能问题，目标在1分钟内完成导入
todos:
  - id: create-directory
    content: 创建 15-high-performance-bulk-import 目录和 README.md 总览文档
    status: pending
  - id: gcs-import-sql
    content: 编写 GCS Parquet 导入 SQL 示例（01_gcs_import.sql）
    status: pending
    dependencies:
      - create-directory
  - id: parallel-import-sql
    content: 编写多线程并行导入策略 SQL（02_parallel_import.sql）
    status: pending
    dependencies:
      - create-directory
  - id: distributed-import-sql
    content: 编写分布式表导入优化 SQL（03_distributed_import.sql）
    status: pending
    dependencies:
      - create-directory
  - id: resource-optimization
    content: 编写资源优化指南文档（04_resource_optimization.md）
    status: pending
    dependencies:
      - create-directory
  - id: error-recovery
    content: 编写错误恢复机制文档（05_error_recovery.md）
    status: pending
    dependencies:
      - create-directory
  - id: monitoring-sql
    content: 编写性能监控 SQL 脚本（06_monitoring.sql）
    status: pending
    dependencies:
      - create-directory
  - id: shell-scripts
    content: 创建 Shell 执行脚本（scripts/目录）
    status: pending
    dependencies:
      - gcs-import-sql
      - parallel-import-sql
  - id: config-xml
    content: 创建推荐的导入配置文件（configs/import_settings.xml）
    status: pending
    dependencies:
      - create-directory
---

## 产品概述

为 ClickHouse 创建一套高性能批量导入方案，针对 150 亿行 Parquet 数据从 GCS 导入的场景，目标将导入时间从 30 分钟压缩到 1 分钟以内。

## 核心功能

- GCS Parquet 文件并行导入策略
- 多线程批量写入优化配置
- 分片并行导入脚本
- 导入性能监控与调优
- 错误恢复与重试机制
- 2 副本架构下的写入优化
- CPU 和内存资源优化方案

## Tech Stack

- ClickHouse 集群（2 副本 + 3 Keepers）
- GCS 存储集成（S3/GCS 表函数）
- Parquet 格式数据导入
- SQL 脚本 + Shell 脚本

## Implementation Approach

基于现有项目的架构模式和命名规范，创建 `15-high-performance-bulk-import/` 新目录，包含完整的解决方案文档和示例代码。

核心策略：

1. **GCS 表函数直接读取**：使用 `gcs()` 函数直接读取 GCS 上的 Parquet 文件，避免中间存储
2. **多维度并行导入**：

- 插入线程并行（max_insert_threads = CPU核心数）
- 文件分片并行（多个客户端同时导入不同文件）
- 分布式表并行写入（prefer_localhost_replica = 0）

3. **批量参数优化**：

- min_insert_block_size_rows = 1000000
- max_insert_block_size = 1048576
- input_format_parallel_parsing = 1

4. **资源控制**：避免 CPU 过载的配置优化

性能预期：

- 150亿行 / 60秒 ≈ 2.5亿行/秒
- 需要约 8-16 个并行插入线程
- GCS 网络带宽利用率需达到 5GB/s 峰值

## Architecture Design

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
       │ (Thread) │    │ (Thread) │    │ (Thread) │
       └──────────┘    └──────────┘    └──────────┘
              │               │               │
              └───────────────┼───────────────┘
                              ▼
              ┌───────────────────────────────────┐
              │     Distributed Table (入口)       │
              └───────────────────────────────────┘
                              │
              ┌───────────────┴───────────────┐
              ▼                               ▼
       ┌─────────────┐                 ┌─────────────┐
       │ ClickHouse1 │ ◄───复制──────► │ ClickHouse2 │
       │  (Replica1) │                 │  (Replica2) │
       └─────────────┘                 └─────────────┘
              │                               │
              └───────────────┬───────────────┘
                              ▼
              ┌───────────────────────────────────┐
              │     3 ClickHouse Keepers          │
              └───────────────────────────────────┘
```

## Directory Structure

创建新目录 `15-high-performance-bulk-import/`，文件组织如下：

```
15-high-performance-bulk-import/
├── README.md                          # [NEW] 高性能批量导入总览，包含架构图、快速开始指南、性能对比
├── 01_gcs_import.sql                  # [NEW] GCS Parquet 文件导入完整示例，包含表创建、权限配置、导入脚本
├── 02_parallel_import.sql             # [NEW] 多线程并行导入策略，包含参数调优、分片导入、资源控制
├── 03_distributed_import.sql          # [NEW] 分布式表并行写入优化，包含分片策略、负载均衡
├── 04_resource_optimization.md        # [NEW] CPU/内存/网络资源优化指南，避免过载
├── 05_error_recovery.md               # [NEW] 错误恢复与重试机制，包含幂等性保证、断点续传
├── 06_monitoring.sql                  # [NEW] 导入性能监控脚本，包含实时监控、性能基准
├── scripts/
│   ├── parallel_import.sh             # [NEW] 并行导入执行脚本（多客户端并行）
│   ├── gcs_import.sh                  # [NEW] GCS 单文件导入脚本
│   └── benchmark.sh                   # [NEW] 性能基准测试脚本
└── configs/
    └── import_settings.xml            # [NEW] 推荐的 ClickHouse 导入配置参数
```

## Key Code Structures

### 核心导入参数配置

```sql
-- 高性能导入核心参数
SETTINGS 
    max_insert_threads = 16,                    -- 并行插入线程
    max_insert_block_size = 1048576,            -- 1M 行块
    min_insert_block_size_rows = 1000000,       -- 最小批量
    input_format_parallel_parsing = 1,          -- 并行解析
    input_format_parquet_max_block_size = 1000000,
    prefer_localhost_replica = 0,               -- 分布式写入
    insert_quorum = 2,                          -- 等待2副本
    insert_quorum_timeout = 300000              -- 5分钟超时
```

### GCS 导入表函数

```sql
-- 直接从 GCS 导入 Parquet
INSERT INTO target_table
SETTINGS max_insert_threads = 16
SELECT * FROM gcs(
    'https://storage.googleapis.com/bucket/path/*.parquet',
    'Parquet',
    -- schema definition
);
```

## Agent Extensions

### SubAgent

- **code-explorer**
- Purpose: 搜索现有项目中 S3/GCS 相关的配置和示例代码
- Expected outcome: 获取完整的 GCS 集成代码参考，确保新方案与现有架构一致