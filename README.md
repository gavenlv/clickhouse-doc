# ClickHouse 从 0 到专家培养教程

> 基于 Docker Compose 部署的 2 副本 + 3 Keeper ClickHouse 集群，通过 14 章系统化学习，从零基础到生产级专家。
> 集群版本：CH 25.12.1.649 ｜ 集群名：`treasurycluster`

## 重整进行中（2026-08-02）

本教程正在从"21 个章节、内容重叠、文件缺失"重整为"**14 主干章 + 2 附录**、文件完整、职责清晰、深度统一到专家级"。

- **重整计划**：[.trae/documents/clickhouse-tutorial-reorg-plan.md](./.trae/documents/clickhouse-tutorial-reorg-plan.md)
- **进度追踪**：[PROGRESS.md](./PROGRESS.md)
- **当前状态**：R0（根 README + TRAINING_PLAN 重写）执行中；旧批次 1-3（04-functions/16-principle/03-engines）已细化完成

### 旧→新章节映射表

| 旧章节 | 新章节 | 处理方式 | 重整批次 |
|--------|--------|----------|----------|
| 00-infra | 00-infra | 保留补全 | R15 |
| 01-base + 01-understanding-clickhouse | 01-getting-started | 合并补全 | R1 |
| 16-principle ✅ | 02-principles | 重命名扩充 | R14 |
| 05-data-type | 03-data-types | 重命名补全 | R2 |
| 03-engines ✅ | 04-engines | 重命名（分布式/集成抽取） | R6/R11 |
| 04-functions ✅ + 10-date-update 函数部分 | 05-functions | 重命名扩充 | R8 |
| 新建 + 14-use-case schema + 20-flink 建模 | 06-modeling | 新建 | R5 |
| 09-data-deletion + 11-data-update | 07-data-mutation | 合并 | R3 |
| 11-performance + 02-advance/01 + 17-best-practices | 08-performance | 重命名深化 | R7 |
| 新建 + 03-engines 分布式深度 + 16-principle/08 | 09-distributed | 新建 | R6 |
| 12-security-authentication + 02-advance/04 | 10-security | 重命名深化 | R10 |
| 06-admin + 13-monitor + 02-advance 运维 | 11-monitoring-ops | 合并补全 | R9 |
| 07-troubleshooting + 02-advance/07 | 12-troubleshooting | 补全 | R4 |
| 08-information-schema | 13-system-tables | 重命名深化 | R13 |
| 03-engines/04 + 14-use-case + 20-flink + 15-bulk-import | 14-integration | 合并补全 | R11 |
| 17-best-practices | 15-best-practices | 重命名扩充 | R12 |
| 18/19-introduction | 附录 A | 降级 | R15 |
| blogs | 附录 B | 降级 | R15 |
| 02-advance | 拆分到各专题章 + 导航页 | 拆分 | R9-R12 |
| 10-date-update | 拆到 03/05/06 章 | 拆分 | R2/R5 |

> **注**：重整期间目录仍为旧编号，重命名在对应 R 批次执行（用 `git mv` 保留历史）。编号冲突 `11-data-update` vs `11-performance` 将在 R3 彻底解决（11-data-update 并入 07-data-mutation）。

---

## 当前目录结构（实际文件）

```
clickhouse-doc/
├── .trae/documents/                    # 重整计划文档
│   ├── clickhouse-doc-deep-refinement-plan.md      # 旧细化计划
│   └── clickhouse-tutorial-reorg-plan.md          # 重整计划（升级版）
│
├── 00-infra/                           # 基础设施（→ 00-infra）
│   ├── README.md
│   ├── docker-compose.yml
│   ├── config/                         # 7 个 xml 配置文件
│   └── scripts/                        # 入口脚本
│
├── 01-base/                            # 基础使用（→ 01-getting-started）
│   ├── README.md
│   ├── 01_basic_operations.sql
│   ├── 02_replicated_tables.sql
│   └── 03_distributed_tables.sql
│
├── 01-understanding-clickhouse/        # 入门概念（并入 01-getting-started）
│   ├── README.md
│   └── 01-06 *.sql（6 个入门示例）
│
├── 02-advance/                         # 高级使用（拆分到各专题章）
│   ├── README.md
│   └── 01-07 *.sql（性能/备份/监控/安全/HA/迁移/排障）
│
├── 03-engines/                         # 表引擎 ✅（→ 04-engines）
│   ├── README.md
│   ├── 01_mergetree_engines.sql
│   ├── 02_replicated_engines.sql
│   ├── 03_log_engines.sql
│   ├── 04_integration_engines.sql
│   ├── 05_special_engines.sql
│   ├── 06_engine_selection_guide.md
│   └── 06_engine_selection_guide_examples.sql
│
├── 04-functions/                       # 函数 ✅（→ 05-functions）
│   ├── README.md
│   ├── 01_basic_functions_examples.sql
│   └── 02_window_functions_examples.sql
│
├── 05-data-type/                       # 数据类型（→ 03-data-types，需补全 03-11）
│   ├── README.md
│   ├── 01_numeric_types.md + _examples.sql
│   └── 02_string_types.md + _examples.sql
│
├── 06-admin/                           # 运维管理（并入 11-monitoring-ops）
│   ├── README.md
│   ├── BACKUP_RECOVERY_GUIDE.md + _examples.sql
│   ├── MONITORING_ALERTING_GUIDE.md + _examples.sql
│   ├── ROUTINE_MAINTENANCE_GUIDE.md + _examples.sql
│   ├── TROUBLESHOOTING_GUIDE.md + _examples.sql
│   └── cluster_admin.sql
│
├── 07-troubleshooting/                 # 故障排查（→ 12-troubleshooting，需补全 03-10）
│   ├── README.md
│   ├── 01_connection_issues.md + _examples.sql
│   └── 02_performance_issues.md + _examples.sql
│
├── 08-information-schema/              # 系统表（→ 13-system-tables）
│   ├── README.md
│   └── 01-08 各 .md + _examples.sql（8 对）
│
├── 09-data-deletion/                   # 数据删除（并入 07-data-mutation）
│   ├── README.md
│   └── 01-07 各 .md + _examples.sql（7 对）
│
├── 10-date-update/                     # 日期时间（拆分到 03/05/06）
│   ├── README.md
│   └── 01-09 各 .md + _examples.sql（9 对）
│
├── 11-data-update/                     # 数据更新（并入 07-data-mutation）
│   ├── README.md
│   └── 01-08 各 .md + _examples.sql（8 对）
│
├── 11-performance/                     # 性能优化（→ 08-performance）
│   ├── README.md
│   └── 01-14 各 .md + _examples.sql（14 对）
│
├── 12-security-authentication/         # 安全认证（→ 10-security）
│   ├── README.md
│   └── 01-09 各 .md + _examples.sql（9 对）
│
├── 13-monitor/                         # 监控（并入 11-monitoring-ops）
│   ├── README.md
│   ├── 01-08 各 .md + _examples.sql（8 对）
│   └── top_cpu_queries.md + _examples.sql
│
├── 14-use-case/                        # 用例（拆分到 06/14）
│   ├── README.md
│   └── 01-06 *.sql（schema/样本/视图/导入/查询/Superset）
│
├── 15-high-performance-bulk-import/    # 批量导入（并入 14-integration）
│   ├── README.md
│   ├── 01-07 *.sql/.md
│   ├── configs/
│   ├── scripts/
│   └── terraform/
│
├── 16-principle/                       # 核心原理 ✅（→ 02-principles）
│   ├── README.md
│   ├── 01-03 *.sql
│   ├── 04-07 *.md
│   └── 08_sharding.sql
│
├── 17-best-practices/                  # 最佳实践（→ 15-best-practices）
│   ├── README.md
│   ├── 01-04 *.sql
│   └── 05-06 *.md
│
├── 18-ch-introduction-cn/              # 技术分享中文（→ 附录 A）
│   ├── README.md
│   └── 01-06 *.sql
│
├── 19-ch-introduction-en/              # 技术分享英文（→ 附录 A）
│   ├── README.md
│   └── 01-06 *.sql
│
├── 20-flink-clickhouse-superset/       # Flink+CH+Superset（拆分到 06/14）
│   ├── README.md
│   └── 01-09 *.md/.sql
│
├── blogs/                              # 博客（→ 附录 B）
│   ├── clickhouse-mergetree-deep-dive.md
│   └── clickhouse-mergetree-deep-dive-en.md
│
├── PROGRESS.md                         # 进度追踪
├── README.md                           # 本文件
├── TRAINING_PLAN.md                    # 培训计划（12 周）
└── test.sql                            # 测试 SQL
```

---

## 目标章节结构（14 主干章 + 2 附录）

```
入门阶段（章 0-2）
  00-infra              基础设施与集群部署
  01-getting-started    入门：第一个表、基础 SQL、复制表
  02-principles         核心原理：列存/向量化/稀疏索引/Merge

进阶阶段（章 3-7）
  03-data-types         数据类型：数值/字符串/日期/数组/JSON/特殊
  04-engines            表引擎：MergeTree 家族/Log/选型决策树
  05-functions          函数：标量/聚合/*State/*Merge/窗口/UDF
  06-modeling           数据建模：宽表/星型/主键/MV/字典/时间序列
  07-data-mutation      数据变更：INSERT/Mutation/轻量/TTL/异步/并发

高级阶段（章 8-11）
  08-performance        性能优化：查询/索引/PREWHERE/Projections/JOIN
  09-distributed        分布式架构：Keeper Raft/分片/两阶段聚合/DDL
  10-security           安全权限：认证/RBAC/RLS/加密/Quota/多租户
  11-monitoring-ops     监控运维：系统表/告警/Prometheus/备份/容量

专家阶段（章 12-15 + 附录）
  12-troubleshooting    故障排查：故障大全/火焰图/错误码
  13-system-tables      系统表参考：完整字段解读
  14-integration        集成生态：Kafka/Flink/Superset/DBT/Iceberg
  15-best-practices     最佳实践：反模式/容量规划/Do-Don't
  附录 A                技术分享素材（1 小时分享 PPT）
  附录 B                博客文章
```

---

## 快速开始

### 1. 启动集群

```bash
cd 00-infra
docker compose up -d
```

### 2. 验证集群

```bash
# 检查容器状态（期望 5 个容器 healthy）
docker compose ps

# 查询集群信息
docker exec -it clickhouse-server-1 clickhouse-client -q "SELECT cluster, shard_num, replica_num, host_name FROM system.clusters WHERE cluster = 'treasurycluster'"

# 查询版本
docker exec -it clickhouse-server-1 clickhouse-client -q "SELECT version()"
```

### 3. 访问集群

| 接口 | 地址 |
|------|------|
| ClickHouse1 HTTP | http://localhost:8123 |
| ClickHouse2 HTTP | http://localhost:8124 |
| Play UI | http://localhost:8123/play |
| ClickHouse1 Native | localhost:9000 |
| ClickHouse2 Native | localhost:9001 |
| Keeper 客户端 | localhost:9181 |
| Keeper Raft 内部 | localhost:9444 |

### 4. 开始学习

按 [TRAINING_PLAN.md](./TRAINING_PLAN.md) 的 12 周路径学习，或按阶段选择：

- **入门**：[01-base/README.md](./01-base/README.md) → [16-principle/README.md](./16-principle/README.md)
- **进阶**：[03-engines/README.md](./03-engines/README.md) → [04-functions/README.md](./04-functions/README.md)
- **高级**：[11-performance/README.md](./11-performance/README.md) → [12-security-authentication/README.md](./12-security-authentication/README.md)
- **专家**：[08-information-schema/README.md](./08-information-schema/README.md) → [17-best-practices/README.md](./17-best-practices/README.md)

> **已细化完成的章节**（专家级深度标杆）：[04-functions](./04-functions/README.md)、[16-principle](./16-principle/README.md)、[03-engines](./03-engines/README.md)

---

## 集群架构

- **ClickHouse Server**：2 节点（clickhouse-server-1, clickhouse-server-2），单分片双副本
- **ClickHouse Keeper**：3 节点（keeper1, keeper2, keeper3），Raft 共识，替代 ZooKeeper

### 关键配置

| 配置项 | 值 | 说明 |
|--------|-----|------|
| 集群名 | `treasurycluster` | 在 `<remote_servers>` 中定义 |
| 默认副本路径 | `/clickhouse/tables/{shard}/{table}` | 通过 Macros 自动展开 |
| 默认副本名 | `{replica}` | 通过 Macros 自动展开 |
| `skip_user_check` | `true` | 解决 Docker/K8s 权限问题 |
| `listen_host` | `0.0.0.0` | IPv4 绑定，避免 IPv6 问题 |

### 可用 Macros

`{cluster}` (treasurycluster) ｜ `{layer}` (1) ｜ `{shard}` (1) ｜ `{replica}` (1 或 2) ｜ `{table}` ｜ `{database}`

### 创建复制表（最简方式）

```sql
CREATE TABLE test_replicated (
    id UInt64,
    data String,
    created_at DateTime DEFAULT now()
) ENGINE = ReplicatedMergeTree
PARTITION BY toYYYYMM(created_at)
ORDER BY id;
```

### 创建分布式表

```sql
CREATE TABLE test_replicated_all AS test_replicated
ENGINE = Distributed(treasurycluster, currentDatabase(), test_replicated, rand());
```

---

## 学习路径（12 周 4 阶段）

| 阶段 | 周数 | 章节 | 里程碑 |
|------|------|------|--------|
| 入门 | 1-2 | 00-02 | 能独立部署集群、建表、解释列存原理 |
| 进阶 | 3-6 | 03-07 | 能选型引擎、设计 schema、用 MV/字典、做数据变更 |
| 高级 | 7-10 | 08-11 | 能优化慢查询、设计分布式架构、配置安全、监控运维 |
| 专家 | 11-12 | 12-15 | 能排查疑难故障、设计端到端方案、做容量规划 |

详细计划见 [TRAINING_PLAN.md](./TRAINING_PLAN.md)。

---

## 配置说明

### ClickHouse 节点配置

- `00-infra/config/clickhouse1.xml` — 副本 1（shard=1, replica=1）
- `00-infra/config/clickhouse2.xml` — 副本 2（shard=1, replica=2）
- `00-infra/config/server-common.xml` — 公共配置
- `00-infra/config/users.xml` — 用户配置

### Keeper 节点配置

- `00-infra/config/keeper1.xml` — server_id=1
- `00-infra/config/keeper2.xml` — server_id=2
- `00-infra/config/keeper3.xml` — server_id=3

> **重要**：`<raft_configuration>` 中使用 `<host>` 标签而非 `<hostname>`。

### 数据持久化

```
00-infra/data/
├── clickhouse1/    # ClickHouse 节点 1 数据
├── clickhouse2/    # ClickHouse 节点 2 数据
├── keeper1/        # Keeper 节点 1 数据
├── keeper2/        # Keeper 节点 2 数据
└── keeper3/        # Keeper 节点 3 数据
```

---

## 使用示例

### 通过 Play UI 查询

访问 http://localhost:8123/play，在浏览器中执行 SQL。

### 通过 HTTP API 查询

```bash
curl "http://localhost:8123/?query=SELECT+*+FROM+system.clusters"
```

### 插入与查询

```sql
-- 插入本地表（自动复制到副本）
INSERT INTO test_replicated VALUES (1, 'data1'), (2, 'data2');

-- 查询本地表（当前副本）
SELECT * FROM test_replicated;

-- 查询分布式表（路由到所有副本）
SELECT * FROM test_replicated_all;

-- 查询副本状态
SELECT database, table, replica_name, total_replicas, active_replicas, queue_size
FROM system.replicas WHERE table = 'test_replicated';
```

---

## 故障排除

常见问题：

1. **Keeper 节点未启动**
   ```bash
   cd 00-infra && docker compose logs keeper1
   ```

2. **ClickHouse 无法连接 Keeper**
   - 确保 Keeper 集群已形成多数（至少 2 个节点运行）
   - 检查 9181 端口可达

3. **内存不足**
   - 调整 Docker 资源限制（建议 8GB+）
   - 减少 `max_memory_usage` 等配置

4. **`system.query_log` 不存在**
   - 当前配置禁用了 `query_log`（`<query_log remove="1"/>`）
   - 改用 `system.query_thread_log`：`SET log_query_threads = 1;`
   - 或在 `server-common.xml` 恢复 `<query_log>` 配置

---

## 健康检查

### 快速检查

```bash
# 服务可用性
curl http://localhost:8123
curl http://localhost:8124

# 版本一致性
curl "http://localhost:8123/?query=SELECT+version()"
curl "http://localhost:8124/?query=SELECT+version()"
```

### 集群状态查询

```sql
-- 集群节点
SELECT cluster, shard_num, replica_num, host_name, host_address, port, is_local
FROM system.clusters WHERE cluster = 'treasurycluster';

-- 副本状态
SELECT database, table, replica_name, total_replicas, active_replicas, queue_size, absolute_delay
FROM system.replicas;

-- Keeper 连接
SELECT * FROM system.zookeeper_connection FORMAT Vertical;

-- 磁盘使用
SELECT name, path, formatReadableSize(free_space) AS free, formatReadableSize(total_space) AS total, free_space / total_space * 100 AS free_pct FROM system.disks;
```

---

## 清理

### 停止并删除容器（保留数据）

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

---

## 参考资源

- [ClickHouse 官方文档](https://clickhouse.com/docs)
- [ClickHouse GitHub](https://github.com/ClickHouse/ClickHouse)
- [ClickHouse 博客](https://clickhouse.com/blog)
- [重整计划文档](./.trae/documents/clickhouse-tutorial-reorg-plan.md)
- [进度追踪](./PROGRESS.md)
- [培训计划](./TRAINING_PLAN.md)

## 许可证

MIT
