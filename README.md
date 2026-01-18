# ClickHouse Docker 集群

使用 Docker Compose 部署 ClickHouse 集群，包含 2 个副本和 3 个 ClickHouse Keeper 节点。

## 架构

- **ClickHouse Server**: 2 个节点（clickhouse1, clickhouse2），配置为单分片双副本集群。
- **ClickHouse Keeper**: 3 个节点（keeper1, keeper2, keeper3），用于分布式协调和元数据存储，替代 ZooKeeper。

镜像源: `zlsmshoqvwt6q1.xuanyuan.run`

## 先决条件

- Docker 和 Docker Compose 已安装
- 至少 4 GB 内存（建议 8 GB）

## 快速启动

1. 克隆或进入本目录
2. 启动集群：
   ```bash
   docker-compose up -d
   ```
3. 查看日志：
   ```bash
   docker-compose logs -f
   ```
4. 停止集群：
   ```bash
   docker-compose down
   ```

## 访问集群

- **ClickHouse1 HTTP**: http://localhost:8123 (默认用户 `default`，密码 `password`)
- **ClickHouse2 HTTP**: http://localhost:8124
- **ClickHouse Native TCP**: localhost:9000 (clickhouse1), localhost:9001 (clickhouse2)
- **ClickHouse Keeper**: 内部端口 9181 (用于客户端连接), 9444 (用于 Raft 内部通信)

## 配置说明

### ClickHouse 配置

每个 ClickHouse 节点有自己的配置文件：

- `config/clickhouse1.xml` – 第一个副本配置，宏：shard=1, replica=1
- `config/clickhouse2.xml` – 第二个副本配置，宏：shard=1, replica=2

集群定义在 `<remote_servers>` 中，名为 `treasurycluster`。

### Keeper 配置

每个 Keeper 节点有自己的配置文件：

- `config/keeper1.xml` – server_id=1
- `config/keeper2.xml` – server_id=2
- `config/keeper3.xml` – server_id=3

Keeper 使用 Raft 协议，端口 9444 用于内部通信，9181 用于客户端连接。

### 数据持久化

数据持久化到本地目录 `./data/`：

- `./data/clickhouse1`, `./data/clickhouse2` – ClickHouse 数据
- `./data/keeper1`, `./data/keeper2`, `./data/keeper3` – Keeper 数据

## 使用示例

连接到 clickhouse1 并创建复制表：

```sql
CREATE TABLE test_replicated (
    id UInt64,
    data String
) ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/test_replicated', '{replica}')
ORDER BY id;
```

在两个副本上数据会自动同步。

## 故障排除

1. **Keeper 节点未启动**：检查日志 `docker-compose logs keeper1`
2. **ClickHouse 无法连接 Keeper**：确保 Keeper 集群已形成多数（至少 2 个节点运行）
3. **内存不足**：调整 Docker 资源限制或减少 `buffer_pool` 等配置

## 清理

停止并删除所有容器、网络（保留本地数据）：

```bash
docker-compose down
```

如需删除本地数据目录，请手动删除 `./data/` 文件夹。

## 许可证

MIT