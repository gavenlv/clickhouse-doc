# ClickHouse Quick Health Check

快速检查脚本，用于验证集群基本功能。

## Linux/Mac/WSL

```bash
# 检查服务状态
curl http://localhost:8123
curl http://localhost:8124

# 检查版本
curl "http://localhost:8123/?query=SELECT version()"
curl "http://localhost:8124/?query=SELECT version()"

# 检查集群
curl "http://localhost:8123/?query=SELECT * FROM system.clusters"

# 检查 replicas
curl "http://localhost:8123/?query=SELECT * FROM system.replicas"

# 检查 macros
curl "http://localhost:8123/?query=SELECT * FROM system.macros"

# 检查 keeper
curl "http://localhost:8123/?query=SELECT * FROM system.zookeeper WHERE path='/'"

# 创建测试表
curl -X POST http://localhost:8123/ --data "CREATE TABLE test (id UInt64) ENGINE = ReplicatedMergeTree ORDER BY id"

# 检查表是否在两个副本上存在
curl "http://localhost:8123/?query=EXISTS test"
curl "http://localhost:8124/?query=EXISTS test"

# 插入数据
curl -X POST http://localhost:8123/ --data-binary "INSERT INTO test FORMAT TabSeparated
1
2
3"

# 查询数据
curl "http://localhost:8123/?query=SELECT * FROM test"
curl "http://localhost:8124/?query=SELECT * FROM test"

# 删除表
curl -X POST http://localhost:8123/ --data "DROP TABLE IF EXISTS test"
```

## Windows PowerShell

```powershell
# 检查服务状态
Invoke-WebRequest -Uri http://localhost:8123 -UseBasicParsing
Invoke-WebRequest -Uri http://localhost:8124 -UseBasicParsing

# 检查版本
Invoke-WebRequest -Uri "http://localhost:8123/?query=SELECT version()" -UseBasicParsing
Invoke-WebRequest -Uri "http://localhost:8124/?query=SELECT version()" -UseBasicParsing

# 检查集群
Invoke-WebRequest -Uri "http://localhost:8123/?query=SELECT * FROM system.clusters" -UseBasicParsing

# 检查 replicas
Invoke-WebRequest -Uri "http://localhost:8123/?query=SELECT * FROM system.replicas" -UseBasicParsing

# 检查 macros
Invoke-WebRequest -Uri "http://localhost:8123/?query=SELECT * FROM system.macros" -UseBasicParsing

# 检查 keeper
Invoke-WebRequest -Uri "http://localhost:8123/?query=SELECT * FROM system.zookeeper WHERE path='/'" -UseBasicParsing

# 创建测试表
Invoke-WebRequest -Uri http://localhost:8123/ -Method POST -Body "CREATE TABLE test (id UInt64) ENGINE = ReplicatedMergeTree ORDER BY id" -UseBasicParsing

# 检查表是否在两个副本上存在
Invoke-WebRequest -Uri "http://localhost:8123/?query=EXISTS test" -UseBasicParsing
Invoke-WebRequest -Uri "http://localhost:8124/?query=EXISTS test" -UseBasicParsing

# 插入数据
Invoke-WebRequest -Uri http://localhost:8123/ -Method POST -Body "INSERT INTO test FORMAT TabSeparated`n1`n2`n3" -UseBasicParsing

# 查询数据
Invoke-WebRequest -Uri "http://localhost:8123/?query=SELECT * FROM test" -UseBasicParsing
Invoke-WebRequest -Uri "http://localhost:8124/?query=SELECT * FROM test" -UseBasicParsing

# 删除表
Invoke-WebRequest -Uri http://localhost:8123/ -Method POST -Body "DROP TABLE IF EXISTS test" -UseBasicParsing
```

## Docker 命令

```bash
# 从项目根目录，先进入基础设施目录
cd 00-infra

# 查看所有服务状态
docker compose ps

# 查看日志
docker compose logs -f clickhouse1
docker compose logs -f clickhouse2
docker compose logs -f keeper1

# 重启服务
docker compose restart clickhouse1
docker compose restart clickhouse2

# 进入容器
docker exec -it clickhouse-server-1 bash
docker exec -it clickhouse-server-2 bash

# 使用 clickhouse-client
docker exec clickhouse-server-1 clickhouse-client --query "SELECT version()"
docker exec clickhouse-server-2 clickhouse-client --query "SELECT version()"
```

## Play UI

访问 http://localhost:8123/play 使用 Web 界面执行查询。

## 常见查询

```sql
-- 查看所有表
SHOW TABLES

-- 查看集群信息
SELECT * FROM system.clusters

-- 查看副本信息
SELECT * FROM system.replicas

-- 查看 macros
SELECT * FROM system.macros

-- 查看 ZooKeeper 状态
SELECT * FROM system.zookeeper

-- 查看复制队列
SELECT * FROM system.replication_queue

-- 查看复制延迟
SELECT table, replica, absolute_delay
FROM system.replicas
```
