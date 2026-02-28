# ClickHouse 集群基础设施

本目录包含 ClickHouse 集群的 Docker Compose 配置和相关配置文件，用于快速部署一个高可用的 ClickHouse 集群环境。

## 架构概览

### 集群架构

```
┌─────────────────────────────────────────────────────────┐
│                  ClickHouse 集群                         │
│                  treasurycluster                        │
├─────────────────────────────────────────────────────────┤
│                                                         │
│  ┌──────────────┐         ┌──────────────┐            │
│  │ ClickHouse 1 │◄───────►│ ClickHouse 2 │            │
│  │  (Replica 1) │         │  (Replica 2) │            │
│  │  Port: 8123  │         │  Port: 8124  │            │
│  │        9000  │         │        9001  │            │
│  └──────┬───────┘         └──────┬───────┘            │
│         │                        │                      │
└─────────┼────────────────────────┼──────────────────────┘
          │                        │
          └────────┬───────────────┘
                   │
          ┌────────▼────────┐
          │ ClickHouse      │
          │ Keeper Ensemble │
          │  (Raft Quorum)  │
          └─────────────────┘
          ┌────────┬────────┐
          │        │        │
    ┌─────▼───┐ ┌──▼───┐ ┌──▼────┐
    │Keeper 1 │ │Keeper│ │Keeper3│
    │  (9181) │ │  2   │ │ (9181)│
    └─────────┘ └──────┘ └───────┘
```

### 组件说明

| 组件 | 数量 | 说明 |
|------|------|------|
| **ClickHouse Server** | 2 个节点 | 单分片双副本架构，提供数据存储和查询服务 |
| **ClickHouse Keeper** | 3 个节点 | 分布式协调服务，替代 ZooKeeper，管理复制和元数据 |

### 关键特性

- **高可用**: 双副本架构，任一节点故障不影响服务
- **数据复制**: 自动同步数据到所有副本
- **负载均衡**: 可通过分布式表实现查询负载均衡
- **简化配置**: 使用默认复制路径，无需手动指定 ZooKeeper 路径

## 快速开始

### 前置要求

- Docker Engine 20.10+
- Docker Compose V2
- 至少 4GB 可用内存（推荐 8GB）

### 启动集群

```bash
# 进入基础设施目录
cd 00-infra

# 启动所有服务
docker compose up -d

# 查看服务状态
docker compose ps

# 查看日志
docker compose logs -f
```

### 停止集群

```bash
# 停止服务（保留数据）
docker compose down

# 停止服务并删除数据卷
docker compose down -v

# 完全清理（包括本地数据目录）
docker compose down -v
rm -rf ./data/
```

## 访问集群

### HTTP 接口

| 服务 | 地址 | 说明 |
|------|------|------|
| ClickHouse1 HTTP | `http://localhost:8123` | HTTP API 和 Play UI |
| ClickHouse2 HTTP | `http://localhost:8124` | HTTP API |
| Play UI | `http://localhost:8123/play` | Web 查询界面 |

### Native TCP 接口

| 服务 | 地址 | 说明 |
|------|------|------|
| ClickHouse1 | `localhost:9000` | Native 协议端口 |
| ClickHouse2 | `localhost:9001` | Native 协议端口 |

### 使用 clickhouse-client 连接

```bash
# 连接到节点 1
docker exec -it clickhouse-server-1 clickhouse-client

# 连接到节点 2
docker exec -it clickhouse-server-2 clickhouse-client

# 从外部连接（需要安装 clickhouse-client）
clickhouse-client --host localhost --port 9000
```

### HTTP API 示例

```bash
# 简单查询
curl "http://localhost:8123/?query=SELECT%20version()"

# 创建数据库
curl "http://localhost:8123/" --data "CREATE DATABASE IF NOT EXISTS test"

# 执行查询
curl "http://localhost:8123/" --data "SELECT * FROM system.clusters"
```

## 目录结构

```
00-infra/
├── README.md                    # 本文档
├── docker-compose.yml           # Docker Compose 配置
├── config/                      # 配置文件目录
│   ├── clickhouse1.xml         # ClickHouse 节点 1 配置
│   ├── clickhouse2.xml         # ClickHouse 节点 2 配置
│   ├── keeper1.xml             # Keeper 节点 1 配置
│   ├── keeper2.xml             # Keeper 节点 2 配置
│   ├── keeper3.xml             # Keeper 节点 3 配置
│   ├── server-common.xml       # 服务器通用配置（如使用）
│   └── users.xml               # 用户配置
├── scripts/                     # 启动脚本
│   ├── keeper-entrypoint.sh    # Keeper 启动入口脚本
│   └── server-entrypoint.sh    # Server 启动入口脚本
└── data/                        # 数据持久化目录（自动生成）
    ├── clickhouse1/            # ClickHouse 节点 1 数据
    ├── clickhouse2/            # ClickHouse 节点 2 数据
    ├── keeper1/                # Keeper 节点 1 数据
    ├── keeper2/                # Keeper 节点 2 数据
    └── keeper3/                # Keeper 节点 3 数据
```

## 配置说明

### 集群配置

集群名称：`treasurycluster`

**分片与副本配置：**
- 分片数：1
- 副本数：2（每个分片）
- 内部复制：启用（`internal_replication: true`）

### 端口映射

#### ClickHouse Server

| 容器端口 | 主机端口 (节点1) | 主机端口 (节点2) | 说明 |
|---------|----------------|----------------|------|
| 8123 | 8123 | 8124 | HTTP API |
| 9000 | 9000 | 9001 | Native TCP |
| 9009 | - | - | 集群间通信 |

#### ClickHouse Keeper

| 容器端口 | 说明 |
|---------|------|
| 9181 | 客户端连接端口 |
| 9444 | Raft 内部通信端口 |

### Macros 配置

每个 ClickHouse 节点配置了以下宏：

| 宏名称 | 节点1 | 节点2 | 说明 |
|--------|-------|-------|------|
| `cluster` | treasurycluster | treasurycluster | 集群名称 |
| `shard` | 1 | 1 | 分片编号 |
| `replica` | 1 | 2 | 副本编号 |
| `layer` | 1 | 1 | 层级标识 |
| `table_prefix` | tables | tables | 表路径前缀 |

### 默认复制路径

简化表创建的默认配置：

```xml
<default_replica_path>/clickhouse/tables/{shard}/{table}</default_replica_path>
<default_replica_name>{replica}</default_replica_name>
```

这意味着您可以使用最简化的语法创建复制表：

```sql
-- 最简方式（推荐）
CREATE TABLE test_table (
    id UInt64,
    data String
) ENGINE = ReplicatedMergeTree
ORDER BY id;

-- 等价于完整语法
CREATE TABLE test_table (
    id UInt64,
    data String
) ENGINE = ReplicatedMergeTree('/clickhouse/tables/1/test_table', '1')
ORDER BY id;
```

### 关键配置参数

#### 权限配置

为解决 Docker 环境权限问题，所有配置文件中启用了：

```xml
<skip_user_check>true</skip_user_check>
```

#### 网络配置

使用 IPv4 绑定避免连接问题：

```xml
<listen_host>0.0.0.0</listen_host>
```

#### 日志配置

为减少资源占用，禁用了部分系统日志：

```xml
<metric_log remove="1"/>
<asynchronous_metric_log remove="1"/>
<trace_log remove="1"/>
<query_log remove="1"/>
<session_log remove="1"/>
<crash_log remove="1"/>
```

## 使用示例

### 创建复制表

```sql
-- 创建数据库
CREATE DATABASE IF NOT EXISTS test;

-- 创建本地复制表
CREATE TABLE test.events (
    event_id UInt64,
    event_type String,
    event_time DateTime,
    event_data String
) ENGINE = ReplicatedMergeTree
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_time, event_id);

-- 创建分布式表
CREATE TABLE test.events_all AS test.events
ENGINE = Distributed(treasurycluster, test, events);
```

### 插入数据

```sql
-- 插入到本地表（自动复制）
INSERT INTO test.events VALUES
    (1, 'click', now(), 'button_a'),
    (2, 'view', now(), 'page_home');

-- 插入到分布式表（自动路由）
INSERT INTO test.events_all VALUES
    (3, 'purchase', now(), 'item_123');
```

### 查询数据

```sql
-- 查询本地表（单节点数据）
SELECT * FROM test.events;

-- 查询分布式表（聚合所有节点）
SELECT * FROM test.events_all;

-- 查询副本信息
SELECT 
    database,
    table,
    replica_name,
    replica_path,
    zookeeper_path
FROM system.replicas
WHERE table = 'events';
```

### 查看集群状态

```sql
-- 查看集群配置
SELECT * FROM system.clusters WHERE cluster = 'treasurycluster';

-- 查看 ZooKeeper/Keeper 连接
SELECT * FROM system.zookeeper WHERE path = '/';

-- 查看副本状态
SELECT 
    database,
    table,
    replica_name,
    replica_path,
    total_replicas,
    active_replicas
FROM system.replicas;
```

## 健康检查

### 基础健康检查

```bash
# 检查服务是否运行
curl http://localhost:8123
curl http://localhost:8124

# 检查版本
curl "http://localhost:8123/?query=SELECT%20version()"

# 检查集群状态
curl "http://localhost:8123/" --data "SELECT * FROM system.clusters"
```

### 完整健康检查

```sql
-- 1. 检查 ClickHouse 版本
SELECT version();

-- 2. 检查集群配置
SELECT 
    cluster,
    shard_num,
    replica_num,
    host_name,
    port
FROM system.clusters
WHERE cluster = 'treasurycluster';

-- 3. 检查 Keeper 连接
SELECT 
    name,
    host,
    port,
    is_leader
FROM system.zookeeper
WHERE path = '/clickhouse';

-- 4. 检查 Macros 配置
SELECT * FROM system.macros;

-- 5. 测试复制表创建
CREATE TABLE IF NOT EXISTS test.health_check (
    id UInt64,
    timestamp DateTime DEFAULT now()
) ENGINE = ReplicatedMergeTree
ORDER BY id;

INSERT INTO test.health_check VALUES (1);

SELECT * FROM test.health_check;

-- 清理测试表
DROP TABLE IF EXISTS test.health_check;
```

## 故障排查

### 常见问题

#### 1. 容器无法启动

**症状**: `docker compose up -d` 失败或容器立即退出

**排查步骤**:
```bash
# 查看容器日志
docker compose logs clickhouse1
docker compose logs keeper1

# 检查容器状态
docker compose ps

# 检查端口占用
netstat -an | grep 8123
netstat -an | grep 9000
```

#### 2. Keeper 节点无法形成集群

**症状**: ClickHouse 日志显示无法连接到 Keeper

**排查步骤**:
```bash
# 检查 Keeper 节点状态
docker exec -it clickhouse-keeper-1 clickhouse-keeper-client --host localhost --port 9181

# 检查 Raft 状态
docker exec -it clickhouse-keeper-1 clickhouse-keeper-client -q "ruok"

# 查看 Keeper 日志
docker compose logs keeper1
```

**解决方案**:
- 确保至少 2 个 Keeper 节点在运行（需要多数节点）
- 检查网络连接：`docker network ls`
- 重启 Keeper 服务：`docker compose restart keeper1 keeper2 keeper3`

#### 3. 复制表创建失败

**症状**: `ReplicatedMergeTree` 表创建报错

**可能原因**:
- Keeper 未启动或不可访问
- 路径冲突（已存在同名表）

**解决方案**:
```sql
-- 检查 Keeper 连接
SELECT * FROM system.zookeeper WHERE path = '/';

-- 检查已存在的表
SELECT * FROM system.replicas;

-- 手动指定路径
CREATE TABLE test.new_table (
    id UInt64
) ENGINE = ReplicatedMergeTree('/clickhouse/tables/1/new_table', '1')
ORDER BY id;
```

#### 4. 内存不足

**症状**: 容器频繁重启或查询失败

**解决方案**:
```bash
# 检查容器资源使用
docker stats

# 调整 Docker 资源限制（在 docker-compose.yml 中）
services:
  clickhouse1:
    deploy:
      resources:
        limits:
          memory: 2G
        reservations:
          memory: 1G
```

### 日志查看

```bash
# 查看所有服务日志
docker compose logs -f

# 查看特定服务日志
docker compose logs -f clickhouse1
docker compose logs -f keeper1

# 查看最近 100 行日志
docker compose logs --tail=100 clickhouse1
```

### 重启服务

```bash
# 重启所有服务
docker compose restart

# 重启特定服务
docker compose restart clickhouse1

# 完全重建
docker compose down
docker compose up -d
```

## 性能优化建议

### 生产环境配置

在生产环境中，建议：

1. **调整内存限制**
   ```xml
   <max_memory_usage>10000000000</max_memory_usage>
   <max_bytes_before_external_group_by>20000000000</max_bytes_before_external_group_by>
   ```

2. **启用查询缓存**
   ```xml
   <use_query_cache>1</use_query_cache>
   ```

3. **优化并发设置**
   ```xml
   <max_threads>8</max_threads>
   <max_insert_threads>4</max_insert_threads>
   ```

4. **配置数据保留策略**
   ```sql
   ALTER TABLE table_name MODIFY TTL date_column + INTERVAL 30 DAY;
   ```

### 监控指标

建议监控以下系统表：

- `system.metrics` - 系统指标
- `system.events` - 系统事件
- `system.asynchronous_metrics` - 异步指标
- `system.query_log` - 查询日志（如启用）
- `system.replicas` - 副本状态

## 备份与恢复

### 数据备份

```bash
# 备份单个表
docker exec clickhouse-server-1 clickhouse-client -q \
  "BACKUP TABLE database.table TO Disk('backup', 'backup_name')"

# 备份整个数据库
docker exec clickhouse-server-1 clickhouse-client -q \
  "BACKUP DATABASE database TO Disk('backup', 'backup_name')"
```

### 数据恢复

```bash
# 从备份恢复
docker exec clickhouse-server-1 clickhouse-client -q \
  "RESTORE TABLE database.table FROM Disk('backup', 'backup_name')"
```

## 安全配置

### 用户管理

默认配置使用 `default` 用户，空密码。生产环境建议：

1. **创建专用用户**
   ```sql
   CREATE USER admin IDENTIFIED BY 'strong_password';
   GRANT ALL ON *.* TO admin WITH GRANT OPTION;
   ```

2. **限制网络访问**
   ```xml
   <profiles>
       <default>
           <readonly>0</readonly>
       </default>
   </profiles>
   ```

3. **启用 SSL/TLS**
   ```xml
   <openSSL>
       <server>
           <certificateFile>/path/to/cert.pem</certificateFile>
           <privateKeyFile>/path/to/key.pem</privateKeyFile>
       </server>
   </openSSL>
   ```

## 升级指南

### 升级步骤

```bash
# 1. 备份数据
docker exec clickhouse-server-1 clickhouse-client -q "SELECT * FROM system.tables"

# 2. 停止服务
docker compose down

# 3. 修改镜像版本（docker-compose.yml）
# image: clickhouse/clickhouse-server:24.x

# 4. 启动新版本
docker compose up -d

# 5. 验证升级
docker exec clickhouse-server-1 clickhouse-client -q "SELECT version()"
```

## 参考资料

- [ClickHouse 官方文档](https://clickhouse.com/docs)
- [ClickHouse Keeper 文档](https://clickhouse.com/docs/en/operations/clickhouse-keeper)
- [Docker Compose 文档](https://docs.docker.com/compose/)
- [复制表配置](https://clickhouse.com/docs/en/engines/table-engines/mergetree-family/replication)

## 许可证

MIT License
