# ClickHouse Docker 集群故障排查指南

本文档记录了部署和运行 ClickHouse Docker 集群时遇到的常见问题及其解决方案。

## 目录

- [权限相关](#权限相关)
- [网络连接问题](#网络连接问题)
- [Keeper 集群问题](#keeper-集群问题)
- [ClickHouse 启动问题](#clickhouse-启动问题)
- [性能和资源问题](#性能和资源问题)
- [常见操作命令](#常见操作命令)

---

## 权限相关

### 问题 1: Permission denied - 数据目录权限不匹配

**现象：**
```
Permission denied: /var/lib/clickhouse/coordination/log
```

**原因：**
- Docker 容器内的 ClickHouse 运行用户与宿主机挂载的数据目录所有者不匹配
- 容器内的用户 ID (通常是 101) 与宿主机数据目录的所有者不一致

**解决方案：**

1. **启用 skip_user_check**（推荐）

在所有配置文件的开头添加：
```xml
<skip_user_check>true</skip_user_check>
```

需要在以下文件中添加：
- `00-infra/config/clickhouse1.xml`
- `00-infra/config/clickhouse2.xml`
- `00-infra/config/keeper1.xml`
- `00-infra/config/keeper2.xml`
- `00-infra/config/keeper3.xml`

2. **移除 docker-compose.yml 中的 UID 配置**

不要在 docker-compose.yml 中指定 `user: "1000:1000"`，让容器使用默认配置。

3. **完全清理并重新初始化**

```bash
# 停止并删除所有容器
cd 00-infra
docker compose down -v

# 删除数据目录
rm -rf ./data/

# 重新启动
docker compose up -d
```

**参考：** [GitHub Issue #39547 - K8s volume permissions](https://github.com/ClickHouse/ClickHouse/issues/39547)

---

## 网络连接问题

### 问题 2: IPv6 连接失败

**现象：**
```
Connection refused or timeout to keeper nodes
```

**原因：**
- ClickHouse 尝试使用 IPv6 地址连接，但 Docker 网络仅支持 IPv4
- 配置中使用 `<hostname>` 标签导致 IPv6 解析

**解决方案：**

1. **使用 <host> 标签而非 <hostname>**

在 Keeper 配置的 `<raft_configuration>` 部分：
```xml
<raft_configuration>
    <server>
        <id>1</id>
        <host>keeper1</host>  <!-- 使用 host 而非 hostname -->
        <port>9444</port>
    </server>
</raft_configuration>
```

同样适用于 ClickHouse 的 zookeeper 配置：
```xml
<zookeeper>
    <node>
        <host>keeper1</host>  <!-- 使用 host 而非 hostname -->
        <port>9181</port>
    </node>
</zookeeper>
```

2. **设置 listen_host 为 0.0.0.0**

在所有配置文件中确保：
```xml
<listen_host>0.0.0.0</listen_host>
```

3. **检查 Docker 网络**

确认 Docker 网络正常运行：
```bash
docker network inspect clickhouse-doc_clickhouse_net
```

---

## Keeper 集群问题

### 问题 3: Keeper 选举超时

**现象：**
```
Keeper election timeout
Cannot establish connection to Keeper ensemble
```

**原因：**
- Raft 协议操作超时时间设置过短
- Docker 网络延迟导致选举超时

**解决方案：**

增加协调超时参数：
```xml
<coordination_settings>
    <operation_timeout_ms>30000</operation_timeout_ms>
    <session_timeout_ms>60000</session_timeout_ms>
    <raft_logs_level>info</raft_logs_level>
</coordination_settings>
```

默认值：
- `operation_timeout_ms`: 10000 (10秒) → 调整为 30000 (30秒)
- `session_timeout_ms`: 30000 (30秒) → 调整为 60000 (60秒)

### 问题 4: Keeper 集群未形成多数派

**现象：**
- ClickHouse 无法连接到 Keeper
- 1 个 Keeper 节点正常，但 2 个或 3 个节点失败

**检查步骤：**

1. 查看所有 Keeper 节点状态：
```bash
docker-compose logs keeper1 keeper2 keeper3 | grep -i "leader\|follower"
```

2. 检查 Keeper 节点是否能够互相通信：
```bash
docker exec clickhouse-keeper-1 ping keeper2
docker exec clickhouse-keeper-1 ping keeper3
```

3. 确认至少 2 个节点正常运行

**解决方案：**
- 确保所有 Keeper 配置的 `server_id` 唯一
- 检查 raft_configuration 中所有节点配置正确
- 如果数据损坏，清理数据并重启：
```bash
docker-compose down
rm -rf ./data/keeper*
docker-compose up -d
```

---

## ClickHouse 启动问题

### 问题 5: ClickHouse 无法连接到 Keeper

**现象：**
```
ZooKeeper error: Connection loss
Waiting for Keeper to be ready...
```

**原因：**
- Keeper 集群未完全启动
- ClickHouse 在 Keeper 准备好之前就启动了

**解决方案：**

1. **手动启动顺序**

```bash
# 先启动 Keeper 节点
docker-compose up -d keeper1 keeper2 keeper3

# 等待 Keeper 集群形成（约 30-60 秒）
docker-compose logs -f keeper1

# 等 Keeper 日志显示 "became leader" 后，启动 ClickHouse
docker-compose up -d clickhouse1 clickhouse2
```

2. **添加健康检查**（可选）

在 docker-compose.yml 中为 Keeper 添加健康检查：
```yaml
keeper1:
  healthcheck:
    test: ["CMD", "clickhouse-keeper", "--query", "SELECT 1"]
    interval: 10s
    timeout: 5s
    retries: 5
```

### 问题 6: 复制表创建失败

**现象：**
```
Table test_replicated already exists on another replica
```

**原因：**
- 之前创建的表元数据在 Keeper 中仍然存在
- ZooKeeper 路径未清理

**解决方案：**

1. **删除 ZooKeeper 中的表元数据**

```bash
# 连接到 Keeper
docker exec -it clickhouse-keeper-1 clickhouse-keeper-client --host localhost --port 9181

# 在客户端中执行
rmr /clickhouse/tables/1/test_replicated
```

2. **清理所有节点的数据**

```bash
docker-compose down
rm -rf ./data/*
docker-compose up -d
```

---

## 性能和资源问题

### 问题 7: 内存不足

**现象：**
```
Memory limit exceeded
OutOfMemory
```

**解决方案：**

1. **增加 Docker 内存限制**

编辑 Docker Desktop 设置，为 Docker 分配更多内存（建议 8GB+）

2. **调整 ClickHouse 配置**

在配置文件中添加内存限制：
```xml
<max_memory_usage>4000000000</max_memory_usage>
<max_memory_usage_for_user>3000000000</max_memory_usage_for_user>
```

3. **优化查询**
- 使用 LIMIT 子句
- 避免全表扫描
- 使用适当的索引

---

## 常见操作命令

### 查看日志

```bash
# 查看所有服务日志
cd 00-infra
docker compose logs -f

# 查看特定服务日志
docker compose logs -f clickhouse1
docker compose logs -f keeper1

# 查看最近的日志
docker compose logs --tail=100
```

### 进入容器

```bash
# 进入 ClickHouse 容器
docker exec -it clickhouse-server-1 bash

# 进入 Keeper 容器
docker exec -it clickhouse-keeper-1 bash
```

### 执行查询

```bash
# 通过 HTTP
curl "http://localhost:8123/?query=SELECT%20version()"

# 通过 clickhouse-client
docker exec -it clickhouse-server-1 clickhouse-client --query "SELECT version()"
```

### 检查集群状态

```bash
# 检查 ClickHouse 集群
curl "http://localhost:8123/?query=SELECT%20*%20FROM%20system.clusters"

# 检查 Keeper 集群
docker exec -it clickhouse-keeper-1 clickhouse-keeper-client --host localhost --port 9181
# 然后执行: ls /
```

### 完全清理

```bash
# 停止并删除容器、网络、卷
cd 00-infra
docker compose down -v

# 删除数据目录
rm -rf ./data/

# 重启
docker compose up -d
```

---

## 调试技巧

### 1. 启用详细日志

在配置文件中调整日志级别：
```xml
<logger>
    <level>debug</level>
    <console>true</console>
</logger>
```

### 2. 检查网络连接

```bash
# 检查容器间的网络连接
docker exec clickhouse-server-1 nc -zv keeper1 9181
docker exec clickhouse-server-1 nc -zv keeper2 9181
docker exec clickhouse-server-1 nc -zv keeper3 9181
```

### 3. 检查端口占用

```bash
# Windows
netstat -ano | findstr :8123
netstat -ano | findstr :9000

# Linux/Mac
lsof -i :8123
lsof -i :9000
```

### 4. 查看 Keeper Raft 状态

```bash
docker exec clickhouse-keeper-1 clickhouse-keeper-client --host localhost --port 9181 --query "SHOW QUORUM"
```

---

## 获取帮助

如果以上方案都无法解决问题，请：

1. 收集日志信息：
   ```bash
   docker-compose logs > logs.txt
   ```

2. 检查系统资源：
   ```bash
   docker stats
   ```

3. 查阅官方文档：
   - [ClickHouse 文档](https://clickhouse.com/docs)
   - [Keeper 文档](https://clickhouse.com/docs/en/operations/clickhouse-keeper)

4. 搜索 GitHub Issues：
   - [ClickHouse GitHub Issues](https://github.com/ClickHouse/ClickHouse/issues)

---

**最后更新：** 2026-01-19
