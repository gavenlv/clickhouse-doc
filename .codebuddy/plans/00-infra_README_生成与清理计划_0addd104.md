---
name: 00-infra README 生成与清理计划
overview: 为 00-infra 目录生成 README.md 文档，验证集群功能，并清理已删除的文件
todos:
  - id: generate-readme
    content: 生成 00-infra/README.md 文档，描述集群架构、配置说明和使用指南
    status: completed
  - id: validate-compose
    content: 验证 docker-compose.yml 配置语法和结构正确性
    status: completed
    dependencies:
      - generate-readme
  - id: start-cluster
    content: 启动 Docker Compose 集群并检查容器状态
    status: completed
    dependencies:
      - validate-compose
  - id: health-check
    content: 执行健康检查查询验证集群功能
    status: completed
    dependencies:
      - start-cluster
  - id: cleanup-files
    content: 提交 git 中已删除的文件，完成清理
    status: completed
    dependencies:
      - health-check
---

## 用户需求

### 产品概述

为 ClickHouse 集群基础设施目录 (00-infra/) 生成完整的 README.md 文档，并执行本地验证和文件清理。

### 核心功能

1. **生成 README.md**：基于当前实际存在的文件和配置，为 00-infra/ 目录生成准确的说明文档
2. **本地验证**：

- 验证 docker-compose.yml 配置的正确性
- 验证 README.md 文档格式和链接正确性
- 启动集群并执行健康检查

3. **清理不必要的文件**：提交 git 状态中已删除但未提交的旧文件（healthcheck 目录、旧文档、临时文件等）

## 技术栈

### 现有技术栈

- **容器编排**: Docker Compose
- **数据库**: ClickHouse Server (latest)
- **协调服务**: ClickHouse Keeper (latest)
- **配置格式**: XML

### 实施方案

#### 1. README.md 生成策略

基于实际探索的配置文件内容生成文档，确保：

- 准确描述集群架构（2 个 ClickHouse 副本 + 3 个 Keeper 节点）
- 正确记录配置文件的作用和关键参数
- 提供清晰的使用指南（启动、停止、访问、故障排查）
- 包含实际的 Macros 配置和端口映射

#### 2. 验证策略

- **配置验证**: 使用 `docker compose config` 验证 YAML 语法
- **启动验证**: 执行 `docker compose up -d` 启动集群
- **健康检查**: 使用 ClickHouse 客户端执行基础查询验证集群功能
- **文档验证**: 检查 README.md 中的命令和链接是否正确

#### 3. 清理策略

- 提交 git 中已删除的文件（删除操作）
- 保留必要的配置文件和脚本

### 目录结构

```
00-infra/
├── README.md              # [NEW] 基础设施说明文档
├── docker-compose.yml     # [KEEP] Docker Compose 配置
├── config/
│   ├── clickhouse1.xml    # [KEEP] ClickHouse 节点1配置
│   ├── clickhouse2.xml    # [KEEP] ClickHouse 节点2配置
│   ├── keeper1.xml        # [KEEP] Keeper 节点1配置
│   ├── keeper2.xml        # [KEEP] Keeper 节点2配置
│   ├── keeper3.xml        # [KEEP] Keeper 节点3配置
│   ├── server-common.xml  # [KEEP] 服务器通用配置
│   └── users.xml          # [KEEP] 用户配置
├── scripts/
│   ├── keeper-entrypoint.sh  # [KEEP] Keeper 启动脚本
│   └── server-entrypoint.sh  # [KEEP] Server 启动脚本
└── data/                  # [KEEP] 数据持久化目录
```

### 关键配置信息

- **集群名称**: treasurycluster
- **架构**: 单分片双副本 (Shard 1, Replica 1/2)
- **Keeper 端口**: 9181 (客户端), 9444 (Raft 内部通信)
- **ClickHouse 端口**: HTTP 8123/8124, Native 9000/9001
- **Macros**: cluster, shard, replica, layer, table_prefix

## Agent Extensions

### SubAgent

- **code-explorer**
- Purpose: 探索项目结构和相关文件，确保 README.md 内容准确完整
- Expected outcome: 确认所有配置参数和文件路径正确，无遗漏