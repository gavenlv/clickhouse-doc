# ClickHouse Docker 集群

使用 Docker Compose 部署 ClickHouse 集群，包含 2 个副本和 3 个 ClickHouse Keeper 节点。

## 目录结构

```
clickhouse-doc/
├── 00-infra/                   # 基础设施文件
│   ├── docker-compose.yml            # Docker Compose 配置
│   ├── config/                   # ClickHouse 和 Keeper 配置
│   ├── data/                     # 数据持久化目录
│   ├── healthcheck/              # 健康检查脚本
│   ├── scripts/                  # 辅助脚本
│   ├── troubleshooting.md        # 故障排查指南（旧版）
│   ├── HIGH_AVAILABILITY_GUIDE.md      # 高可用配置指南
│   ├── DATA_DEDUP_GUIDE.md           # 数据去重与幂等性指南
│   ├── REALTIME_PERFORMANCE_GUIDE.md  # 实时性能优化指南
│   ├── ALL_REPLICATED_TABLES.md      # 复制表总结
│   └── play.html / play2.html / test.html / test2.html
│
├── 01-base/                    # 基础使用
│   ├── README.md
│   ├── 01_basic_operations.sql    # 基础操作示例
│   ├── 02_replicated_tables.sql  # 复制表示例
│   ├── 03_distributed_tables.sql # 分布式表示例
│   ├── 04_system_queries.sql    # 系统表查询
│   ├── 05_advanced_features.sql # 高级特性
│   ├── 06_data_updates.sql     # 数据更新和删除
│   ├── 07_data_modeling.sql   # 数据建模最佳实践
│   ├── 08_realtime_writes.sql  # 实时数据写入
│   └── 09_data_deduplication.sql # 数据去重实战
│
├── 02-advance/                 # 高级使用
│   ├── README.md
│   └── *.sql                   # 高级场景示例
│
├── 03-engines/                  # 表引擎
│   ├── README.md
│   └── *.sql / *.md            # 表引擎详解
│
├── 05-data-type/               # 数据类型
│   ├── README.md                  # 数据类型总览
│   ├── 01_numeric_types.md       # 数值类型
│   ├── 02_string_types.md        # 字符串类型
│   ├── 03_date_time_types.md     # 日期时间类型
│   ├── 04_array_types.md         # 数组类型
│   ├── 05_tuple_types.md         # 元组类型
│   ├── 06_map_types.md           # Map 类型
│   ├── 07_nested_types.md        # Nested 类型
│   ├── 08_enum_types.md          # Enum 类型
│   ├── 09_nullable_types.md       # Nullable 类型
│   ├── 10_special_types.md       # 特殊类型（UUID、JSON、IP 等）
│   └── 11_type_conversion.md     # 类型转换
│
├── 06-admin/                   # 运维管理
│   ├── README.md                  # 运维管理总览
│   ├── CLUSTER_ADMIN_GUIDE.md     # 集群管理指南
│   ├── TROUBLESHOOTING_GUIDE.md   # 故障排查指南
│   ├── MONITORING_ALERTING_GUIDE.md # 监控告警指南
│   ├── BACKUP_RECOVERY_GUIDE.md   # 备份恢复指南
│   ├── ROUTINE_MAINTENANCE_GUIDE.md # 日常维护指南
│   ├── cluster_admin.sql          # 集群管理 SQL
│   ├── monitoring.sql             # 监控指标 SQL
│   ├── maintenance.sql            # 维护操作 SQL
│   └── diagnostics.sql           # 诊断检查 SQL
│
└── 07-troubleshooting/          # 故障排查
    ├── README.md                  # 故障排查总览
    ├── 01_connection_issues.md    # 连接问题
    ├── 02_performance_issues.md   # 性能问题
    ├── 03_storage_issues.md      # 存储问题
    ├── 04_replication_issues.md  # 复制问题
    ├── 05_query_issues.md        # 查询问题
    ├── 06_startup_issues.md      # 启动问题
    ├── 07_upgrade_issues.md      # 升级问题
    ├── 08_data_consistency.md    # 数据一致性问题
    ├── 09_resource_issues.md     # 资源问题
    └── 10_common_errors.md      # 常见错误码
│
└── 08-information-schema/       # 数据库元数据
    ├── README.md                  # 元数据查询总览
    ├── 01_databases_tables.md    # 数据库和表信息
    ├── 02_columns_schema.md       # 列定义和表结构
    ├── 03_partitions_parts.md     # 分区和数据块
    ├── 04_indexes_projections.md  # 索引和投影
    ├── 05_clusters_replicas.md    # 集群和副本信息
    ├── 06_users_roles.md          # 用户和权限管理
    ├── 07_queries_processes.md    # 查询和进程
    └── 08_system_tables.md        # 系统表详解
│
└── 09-data-deletion/           # 数据删除专题
    ├── README.md                  # 删除方法总览
    ├── 01_partition_deletion.md  # 分区删除（推荐）
    ├── 02_ttl_deletion.md        # TTL 自动删除
    ├── 03_mutation_deletion.md   # Mutation 删除
    ├── 04_lightweight_deletion.md # 轻量级删除
    ├── 05_deletion_strategies.md # 删除策略选择
    ├── 06_deletion_performance.md # 删除性能优化
    └── 07_deletion_monitoring.md # 删除监控
│
└── 10-date-update/             # 日期时间操作专题
    ├── README.md                  # 日期时间操作总览
    ├── 01_date_time_types.md    # 日期时间类型详解
    ├── 02_date_time_functions.md # 日期时间函数大全
    ├── 03_time_zones.md         # 时区处理
    ├── 04_date_arithmetic.md     # 日期算术运算
    ├── 05_time_range_queries.md # 时间范围查询
    ├── 06_date_formatting.md   # 日期格式化和解析
    ├── 07_time_series_analysis.md # 时间序列分析
    ├── 08_window_functions.md   # 窗口函数和时间窗口
    └── 09_date_performance.md # 日期时间性能优化
│
└── 11-data-update/            # 数据更新专题
    ├── README.md                  # 数据更新方法总览
    ├── 01_mutation_update.md   # Mutation 更新
    ├── 02_lightweight_update.md # 轻量级更新
    ├── 03_partition_update.md   # 分区更新（推荐）
    ├── 04_update_strategies.md # 更新策略选择
    ├── 05_update_performance.md # 更新性能优化
    ├── 06_update_monitoring.md # 更新监控
    ├── 07_batch_updates.md     # 批量更新实战
    └── 08_case_studies.md     # 实战案例分析
│
└── 11-performance/           # 性能优化专题
    ├── README.md                      # 性能优化总览
    ├── 01_query_optimization.md       # 查询优化基础
    ├── 02_primary_indexes.md         # 主键索引优化
    ├── 03_partitioning.md           # 分区键优化
    ├── 04_skipping_indexes.md       # 数据跳数索引
    ├── 05_prewhere_optimization.md # PREWHERE 优化
    ├── 06_bulk_inserts.md          # 批量插入优化
    ├── 07_asynchronous_operations.md # 异步操作优化
    ├── 08_mutation_optimization.md # Mutation 优化
    ├── 09_data_types.md           # 数据类型优化
    ├── 10_common_patterns.md      # 常见性能模式
    ├── 11_query_profiling.md      # 查询分析和 Profiling
    ├── 12_analyzer.md             # 查询分析器
    ├── 13_caching.md              # 缓存优化
    └── 14_hardware_tuning.md      # 硬件调优和测试
│
└── 12-security-authentication/  # 安全认证专题
    ├── README.md                      # 安全认证总览
    ├── 01_authentication.md           # 用户认证方法
    ├── 02_user_role_management.md     # 用户和角色管理
    ├── 03_permissions.md              # 权限控制
    ├── 04_row_level_security.md       # 行级安全
    ├── 05_network_security.md         # 网络安全
    ├── 06_data_encryption.md          # 数据加密
    ├── 07_audit_log.md                # 审计日志
    ├── 08_best_practices.md           # 安全最佳实践
    └── 09_common_configs.md           # 常见安全配置
│
└── 13-monitor/                 # 监控专题
    ├── README.md                      # 监控总览
    ├── 01_system_monitoring.md       # 系统资源监控
    ├── 02_query_monitoring.md        # 查询监控和反模式
    ├── 03_data_quality_monitoring.md # 数据质量监控
    ├── 04_operation_monitoring.md     # 操作监控
    ├── 05_abuse_detection.md         # 滥用检测
    ├── 06_alerting.md                # 告警机制
    ├── 07_best_practices.md          # 监控最佳实践
    └── 08_common_configs.md          # 常见监控配置
│
└── test_all_topics.sql         # 综合测试文件
    ├── 08-information-schema 测试   # 数据库元数据查询测试
    ├── 09-data-deletion 测试         # 数据删除方法测试
    └── 10-date-update 测试           # 日期时间操作测试
```

## 快速开始

1. **启动集群**
   ```bash
   cd 00-infra
   docker compose up -d
   ```

2. **健康检查**
   ```bash
   cd 00-infra/healthcheck
   # Windows
   .\run_check.bat
   # Linux/Mac
   ./quick_test.sh
   ```

3. **开始学习**
   - 基础操作：查看 [01-base/README.md](./01-base/README.md)
   - 高级功能：查看 [02-advance/README.md](./02-advance/README.md)
   - 表引擎：查看 [03-engines/README.md](./03-engines/README.md)

4. **运行测试**
   ```bash
   # Linux/Mac: 使用测试脚本
   ./run_tests.sh --all

   # Windows: 使用测试脚本
   run_tests.bat --all

   # 或者直接使用 clickhouse-client
   docker exec -it clickhouse1 clickhouse-client --queries-file /var/lib/clickhouse/user_files/test_all_topics.sql
   ```

详细测试指南请查看：[TEST_GUIDE.md](./TEST_GUIDE.md)

## 测试脚本

项目提供了便捷的测试脚本：

### Linux/Mac
```bash
# 运行完整测试
./run_tests.sh --all

# 显示测试结果
./run_tests.sh --results

# 显示分区信息
./run_tests.sh --partitions

# 清理测试数据
./run_tests.sh --cleanup

# 显示帮助
./run_tests.sh --help
```

### Windows
```cmd
# 运行完整测试
run_tests.bat --all

# 显示测试结果
run_tests.bat --results

# 显示分区信息
run_tests.bat --partitions

# 清理测试数据
run_tests.bat --cleanup

# 显示帮助
run_tests.bat --help
```

## 架构

- **ClickHouse Server**: 2 个节点（clickhouse1, clickhouse2），配置为单分片双副本集群。
- **ClickHouse Keeper**: 3 个节点（keeper1, keeper2, keeper3），用于分布式协调和元数据存储，替代 ZooKeeper。

镜像源: `zlsmshoqvwt6q1.xuanyuan.run`

## 先决条件

- Docker 和 Docker Compose 已安装
- 至少 4 GB 内存（建议 8 GB）

## 快速启动

1. 克隆或进入本目录
2. 进入基础设施目录：
   ```bash
   cd 00-infra
   ```
3. 启动集群：
   ```bash
   docker compose up -d
   ```
4. 查看日志：
   ```bash
   docker compose logs -f
   ```
5. 停止集群：
   ```bash
   docker compose down
   ```

## 访问集群

### HTTP 接口
- **ClickHouse1 HTTP**: http://localhost:8123 (默认用户 `default`，空密码)
- **ClickHouse2 HTTP**: http://localhost:8124
- **Play UI**: http://localhost:8123/play

### Native TCP
- **ClickHouse1 Native**: localhost:9000
- **ClickHouse2 Native**: localhost:9001

### Keeper
- **客户端连接端口**: 9181
- **Raft 内部通信端口**: 9444

## 配置说明

### 关键配置项

#### Skip User Check
所有配置文件中都启用了 `skip_user_check`，这是为了解决 Docker/K8s 环境下的权限问题：
```xml
<skip_user_check>true</skip_user_check>
```

#### IPv4 绑定
配置中使用 IPv4 地址而非主机名解析，避免 IPv6 连接问题：
```xml
<listen_host>0.0.0.0</listen_host>
```

#### Keeper 协调超时
调整了 Keeper 的超时参数以适应 Docker 网络环境：
```xml
<coordination_settings>
    <operation_timeout_ms>30000</operation_timeout_ms>
    <session_timeout_ms>60000</session_timeout_ms>
</coordination_settings>
```

### ClickHouse 配置

每个 ClickHouse 节点有自己的配置文件：
- `00-infra/config/clickhouse1.xml` – 第一个副本配置，宏：shard=1, replica=1
- `00-infra/config/clickhouse2.xml` – 第二个副本配置，宏：shard=1, replica=2

集群定义在 `<remote_servers>` 中，名为 `treasurycluster`。

### Keeper 配置

每个 Keeper 节点有自己的配置文件：
- `00-infra/config/keeper1.xml` – server_id=1
- `00-infra/config/keeper2.xml` – server_id=2
- `00-infra/config/keeper3.xml` – server_id=3

Keeper 使用 Raft 协议，端口 9444 用于内部通信，9181 用于客户端连接。

**重要**：在 `<raft_configuration>` 中使用 `<host>` 标签而非 `<hostname>` 标签。

### 数据持久化

数据持久化到本地目录 `./00-infra/data/`：
- `./00-infra/data/clickhouse1`, `./00-infra/data/clickhouse2` – ClickHouse 数据
- `./00-infra/data/keeper1`, `./00-infra/data/keeper2`, `./00-infra/data/keeper3` – Keeper 数据

## 使用示例

### 通过 Play UI 查询
访问 http://localhost:8123/play，可以直接在浏览器中执行 SQL 查询。

### 通过 HTTP API 查询
```bash
curl "http://localhost:8123/?query=SELECT%20*%20FROM%20system.clusters"
```

### 创建复制表（使用默认路径）

本集群已配置默认复制路径，可以使用最简方式创建表：

**最简方式**（推荐 - 使用默认路径）：
```sql
CREATE TABLE test_replicated (
    id UInt64,
    data String,
    created_at DateTime DEFAULT now()
) ENGINE = ReplicatedMergeTree
ORDER BY id;
```

**简化方式**（只指定表名）：
```sql
CREATE TABLE test_replicated (
    id UInt64,
    data String
) ENGINE = ReplicatedMergeTree
PARTITION BY toYYYYMM(created_at)
ORDER BY id;
```

**完整方式**（自定义路径）：
```sql
CREATE TABLE test_replicated (
    id UInt64,
    data String
) ENGINE = ReplicatedMergeTree('/custom/path/{table}', '{replica}')
ORDER BY id;
```

**可用的 Macros**：
- `{cluster}` - 集群名称 (treasurycluster)
- `{layer}` - 层级 (1)
- `{shard}` - 分片号 (1)
- `{replica}` - 副本号 (1 或 2)
- `{table_prefix}` - 表前缀 (tables)
- `{table}` - 表名
- `{database}` - 数据库名

**默认配置**：
- `default_replica_path`: `/clickhouse/tables/{shard}/{table}`
- `default_replica_name`: `{replica}`

**分布式表**：
```sql
CREATE TABLE test_replicated_all AS test_replicated
ENGINE = Distributed(treasurycluster, default, test_replicated);
```

### 插入数据
```sql
INSERT INTO test_replicated VALUES (1, 'data1'), (2, 'data2');
```

### 查询数据
```sql
-- 查询本地表（只在当前副本）
SELECT * FROM test_replicated;

-- 查询分布式表（自动路由到所有副本）
SELECT * FROM test_replicated_all;

-- 查询副本信息
SELECT * FROM system.replicas WHERE table = 'test_replicated';
```

## 故障排除

详细的故障排查指南请参考 [00-infra/troubleshooting.md](./00-infra/troubleshooting.md)。

常见问题：
1. **Keeper 节点未启动**：检查日志 `cd 00-infra && docker compose logs keeper1`
2. **ClickHouse 无法连接 Keeper**：确保 Keeper 集群已形成多数（至少 2 个节点运行）
3. **内存不足**：调整 Docker 资源限制或减少 `buffer_pool` 等配置

## 健康检查

### 快速检查

使用 00-infra/healthcheck/QUICK_CHECK.md 中的命令快速验证集群状态：

```bash
# 检查服务是否运行
curl http://localhost:8123
curl http://localhost:8124

# 检查版本
curl "http://localhost:8123/?query=SELECT version()"
```

### 完整健康检查

运行自动化健康检查脚本：

**Linux/Mac/WSL:**
```bash
cd 00-infra/healthcheck
chmod +x check_cluster.sh
./check_cluster.sh
```

**Windows PowerShell:**
```powershell
cd 00-infra/healthcheck
powershell -ExecutionPolicy Bypass -File check_cluster.ps1
```

脚本会自动测试：
- 服务可用性
- 版本一致性
- Keeper 连接
- 集群配置
- Macros 配置
- 复制表创建（使用默认路径）
- 数据插入和复制
- 复制状态
- ZooKeeper 路径验证

详细说明请参考 [00-infra/healthcheck/README.md](./00-infra/healthcheck/README.md)

### Play UI

访问 http://localhost:8123/play 使用 Web 界面执行 SQL 查询。

## 清理

### 停止并删除所有容器、网络（保留本地数据）
```bash
cd 00-infra
docker compose down
```

### 完全清理（包括数据）
```bash
cd 00-infra
docker compose down -v
rm -rf ./data/
```

## 学习路径

### 基础入门（01-base/）
从基础操作开始学习 ClickHouse：
- [基础操作](./01-base/README.md#01_basic_operationssql) - 表创建、插入、查询
- [复制表](./01-base/README.md#02_replated_tablessql) - 数据复制
- [分布式表](./01-base/README.md#03_distributed_tablessql) - 数据分片
- [系统查询](./01-base/README.md#04_system_queriessql) - 集群监控
- [高级特性](./01-base/README.md#05_advanced_featuressql) - 物化视图、TTL
- [数据更新](./01-base/README.md#06_data_updatessql) - 实时更新和 Mutation
- [数据建模](./01-base/README.md#07_data_modeling) - 宽表、星型模型、时序数据
- [实时写入](./01-base/README.md#08_realtime_writes) - Kafka、Flink 集成

### 进阶提升（02-advance/）
深入生产环境最佳实践：
- [性能优化](./02-advance/README.md#01_performance_optimizationsql) - 查询优化
- [备份恢复](./02-advance/README.md#02_backup_recoverysql) - 数据保护
- [监控指标](./02-advance/README.md#03_monitoring_metricssql) - 系统监控
- [安全配置](./02-advance/README.md#04_security_configsql) - 权限管理
- [高可用](./02-advance/README.md#05_high_availablitysql) - 集群高可用
- [数据迁移](./02-advance/README.md#06_data_migrationsql) - 数据迁移
- [故障排查](./02-advance/README.md#07_troubleshootingsql) - 问题诊断

### 表引擎精通（03-engines/）
掌握不同表引擎的适用场景：
- [MergeTree 系列](./03-engines/README.md#01_mergetree_enginessql) - OLAP 引擎
- [复制引擎](./03-engines/README.md#02_replicated_enginessql) - 高可用
- [Log 系列](./03-engines/README.md#03_log_enginessql) - 日志引擎
- [集成引擎](./03-engines/README.md#04_integration_enginessql) - 外部系统
- [特殊引擎](./03-engines/README.md#05_special_enginessql) - 分布式表
- [选择指南](./03-engines/README.md#06_engine_selection_guidemd) - 决策树

## 参考

- [ClickHouse 官方文档](https://clickhouse.com/docs)
- [GitHub Issue #39547 - K8s volume permissions](https://github.com/ClickHouse/ClickHouse/issues/39547)

## 许可证

MIT
