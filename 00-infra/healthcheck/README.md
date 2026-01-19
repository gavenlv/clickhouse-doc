# ClickHouse Cluster Health Check

本目录包含 ClickHouse 集群的健康检查测试脚本。

## 测试内容

### check.ps1 (PowerShell - 推荐)

完整的集群健康检查脚本（英文版本，避免编码问题），测试以下功能：

- **服务可用性测试**
  - ClickHouse1 HTTP 服务是否可访问
  - ClickHouse2 HTTP 服务是否可访问

- **版本信息测试**
  - 验证两个节点版本一致
  - 显示版本信息

- **Keeper 连接测试**
  - 验证与 Keeper 的连接
  - 检查 Keeper 节点数量
  - **注意**：Windows Docker 环境下此测试可能失败（已知限制）

- **集群配置测试**
  - 验证集群配置正确
  - 检查副本数量

- **Macros 配置测试**
  - 验证默认复制路径配置
  - 检查每个节点的 macros
  - 应该有 5 个 macros：cluster, layer, shard, replica, table_prefix

- **复制表创建测试**
  - 使用简化的 CREATE TABLE 语法（无需手动指定 ZooKeeper 路径）
  - 验证表在两个副本上都创建
  - 检查 ZooKeeper 路径使用默认配置

- **数据插入和复制测试**
  - 插入测试数据
  - 验证数据自动复制到第二个副本
  - 检查两个副本数据一致性

- **复制状态测试**
  - 检查复制状态
  - 验证存在一个 leader
  - 显示每个副本的详细信息

- **ZooKeeper 路径测试**
  - 验证 ZooKeeper 路径使用默认配置
  - 检查路径格式: `/clickhouse/tables/1/{table}`

- **清理测试数据**
  - 清理测试表
  - 验证清理成功

### quick_test.sh (Bash)

快速测试脚本，覆盖核心功能。

## 使用方法

### Windows (推荐)
```powershell
# 使用批处理文件（最简单）
cd 00-infra/healthcheck
.\run_check.bat

# 直接运行 PowerShell 脚本
cd 00-infra/healthcheck
powershell -ExecutionPolicy Bypass -File check.ps1
```

### Linux/Mac/WSL
```bash
cd 00-infra/healthcheck
chmod +x quick_test.sh
./quick_test.sh

# 或使用完整检查脚本（如果可用）
chmod +x check_cluster.sh
./check_cluster.sh
```

## 预期输出

```
========================================
1. Service Availability Test
========================================
OK ClickHouse1 HTTP service
OK ClickHouse2 HTTP service

========================================
2. Version Test
========================================
ClickHouse1 Version: 25.12.3.21
ClickHouse2 Version: 25.12.3.21
OK Both nodes have same version

========================================
5. Macros Config Test
========================================
ClickHouse1 Macros count: 5
ClickHouse2 Macros count: 5
OK ClickHouse1 has 5 macros
OK ClickHouse2 has 5 macros

========================================
Test Summary
========================================
Total tests: 9
Passed: 7
Failed: 2
2 tests failed
```

## 已知限制

在 Windows Docker 环境下，以下测试可能会失败（这是预期的）：

1. **Keeper 连接测试**
   - system.zookeeper 查询可能返回 400 错误
   - 这不影响复制功能，因为 ClickHouse 可以在后台连接 Keeper

2. **表复制到第二个副本**
   - 可能由于文件权限问题导致延迟
   - 表在第一个副本上创建成功，但复制到第二个副本可能需要更长时间

3. **数据插入和复制**
   - 如果第二个副本存在权限问题，数据插入在第一个副本可能成功，但复制会失败
   - 这不会导致脚本错误，只是复制状态检查会失败

## 测试失败排查

如果测试失败，请检查：

1. **服务未运行**
   ```bash
   cd 00-infra
   docker compose ps
   ```

2. **查看日志**
   ```bash
   cd 00-infra
   docker compose logs clickhouse1
   docker compose logs clickhouse2
   docker compose logs keeper1
   ```

3. **文件权限问题（Windows）**
   - 参考 `../troubleshooting.md` 中的权限解决方案
   - 可能需要重启 Docker Desktop
   - 在 Linux/Mac/WSL 环境下测试会更好

4. **默认路径配置问题**
   - 检查 `../config/clickhouse*.xml` 中的 default_replica_path 配置
   - 查看系统 macros: `SELECT * FROM system.macros`

## 自定义测试

可以根据需要修改脚本中的参数：

```powershell
# 修改端口
$CH1_HTTP = "http://localhost:8123"
$CH2_HTTP = "http://localhost:8124"

# 修改集群名称
$CLUSTER_NAME = "treasurycluster"
```

## Play UI 访问

访问 http://localhost:8123/play 使用 Web 界面执行 SQL 查询。
