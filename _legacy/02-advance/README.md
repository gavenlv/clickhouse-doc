# ClickHouse 进阶（生产环境运维与优化专家指南）

> 本章是 ClickHouse 从"会用"到"能在生产环境独当一面"的跨越。读完本章，你应能：定位查询性能瓶颈并给出优化方案、设计可靠的备份恢复策略、构建监控告警体系、实施 RBAC 与行级安全、理解副本高可用机制、完成跨集群数据迁移、系统化排查故障。
>
> 配套可运行 SQL（均已在集群验证零错误，CH 25.12.1.649，`treasurycluster` 1 分片 2 副本）：
> [01_performance_optimization.sql](./01_performance_optimization.sql)、[02_backup_recovery.sql](./02_backup_recovery.sql)、[03_monitoring_metrics.sql](./03_monitoring_metrics.sql)、[04_security_config.sql](./04_security_config.sql)、[05_high_availability.sql](./05_high_availability.sql)、[06_data_migration.sql](./06_data_migration.sql)、[07_troubleshooting.sql](./07_troubleshooting.sql)

---

## 1. 本章解决什么问题（Why）

ClickHouse 在"单机百万行/s 写入、百亿行秒级聚合"上极具优势，但生产环境真正棘手的不是"跑得快"，而是"持续稳定地跑得快"。本章解决 7 类生产痛点：

| 痛点 | 典型表现 | 本章如何解答 |
|------|----------|--------------|
| 查询偶发变慢，不知道瓶颈在哪 | "同样 SQL 有时 0.1s 有时 30s" | §3.1 查询 Profiling 全链路（EXPLAIN → query_log → 瓶颈定位） |
| 数据越积越多，磁盘和查询都在恶化 | part 数爆炸、合并跟不上 | §3.2 分区/排序键/跳数索引/投影的取舍决策表 |
| 没有备份，出了事故无法恢复 | 误删表、磁盘损坏 | §4 备份恢复四层体系（BACKUP/RESTORE、FREEZE、文件系统快照、副本） |
| 监控只有"CPU/内存"，看不到业务层 | 出了问题不知道根因 | §5 监控指标三层体系（metrics / events / query_log）+ 告警阈值 |
| 谁都能连、谁都能删，无安全边界 | 误操作 DROP、数据泄露 | §6 安全模型（RBAC + 行级安全 + 配额 + 审计） |
| 单节点宕机就停服 | 无副本、无故障转移 | §7 高可用架构（副本 + Keeper + 分布式表 + 负载均衡） |
| 要换集群/改表结构，不敢动 | 怕丢数据、怕停服 | §8 数据迁移（INSERT SELECT / copier / BACKUP / ATTACH PARTITION） |

---

## 2. 进阶知识全景图

```
┌─────────────────────────────────────────────────────────────────────┐
│                  ClickHouse 生产环境运维体系                          │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  ① 性能优化（01）                                                    │
│     ├─ 查询执行：Parser → Analyzer → Planner → Executor(向量化)      │
│     ├─ 优化手段：分区剪枝 / 稀疏主键 / 跳数索引 / 投影 / PREWHERE    │
│     ├─ 资源控制：max_threads / max_memory_usage / workload pools     │
│     └─ 诊断工具：EXPLAIN / system.query_log / system.processes       │
│                                                                      │
│  ② 备份恢复（02）                                                    │
│     ├─ 逻辑备份：BACKUP/RESTORE（官方推荐，支持增量）                 │
│     ├─ 物理快照：ALTER TABLE FREEZE（硬链接，零拷贝）                │
│     ├─ 文件系统级：LVM/ZFS 快照（需停写）                            │
│     └─ 副本即备份：ReplicatedMergeTree 跨副本同步                    │
│                                                                      │
│  ③ 监控指标（03）                                                    │
│     ├─ 实时指标：system.metrics（瞬态值，如当前连接数）              │
│     ├─ 异步指标：system.asynchronous_metrics（周期采样，如内存）      │
│     ├─ 累计事件：system.events（自启动累计，如 Query 数）             │
│     ├─ 日志表：system.text_log / part_log / error_log                │
│     └─ 查询日志：system.query_log（本环境未启用，用 processes 替代）  │
│                                                                      │
│  ④ 安全模型（04）                                                    │
│     ├─ 认证：plaintext / sha256 / double_sha1 / bcrypt / LDAP       │
│     ├─ 授权：RBAC（USER → ROLE → GRANT）+ SETTINGS PROFILE           │
│     ├─ 行级安全：CREATE POLICY ... USING expr（过滤可见行）          │
│     ├─ 配额：CREATE QUOTA（限速/限资源，防"大查询拖垮集群"）         │
│     └─ 审计：query_log + 自建审计表                                  │
│                                                                      │
│  ⑤ 高可用（05）                                                      │
│     ├─ 数据冗余：ReplicatedMergeTree + Keeper 协调                   │
│     ├─ 故障转移：Leader 选举 + 副本自动接管                           │
│     ├─ 负载均衡：Distributed 表副本轮询 + 外部 LB                    │
│     └─ 一致性：最终一致（异步复制），强一致需 SELECT ... FOR          │
│                                                                      │
│  ⑥ 数据迁移（06）                                                    │
│     ├─ 同集群：INSERT SELECT + ATTACH PARTITION                     │
│     ├─ 跨集群：clickhouse-copier（官方，支持分片重分布）             │
│     ├─ 远程拉取：remote() / s3() / url() / file() 表函数            │
│     └─ 格式转换：CSV / TSV / JSON / Parquet / Arrow                  │
│                                                                      │
│  ⑦ 故障排查（07）                                                    │
│     ├─ 方法论：症状 → 初诊 → 深入 → 定位 → 修复                      │
│     ├─ 性能瓶颈：EXPLAIN / query_log / part 数 / 合并队列            │
│     ├─ 复制故障：replicas / replication_queue / zookeeper            │
│     └─ 数据损坏：system.parts.exception → DETACH → 恢复             │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 3. 性能优化体系（对应 01 SQL）

### 3.1 查询执行全链路与 Profiling

ClickHouse 一条查询从提交到返回，经过四个阶段：

```
SQL 文本
  │
  ▼
① Parser（词法+语法分析 → AST）          ← 语法错误在此暴露
  │
  ▼
② Analyzer（类型推导 + 权限检查 + 列解析） ← "Unknown column" 在此报错
  │
  ▼
③ Planner（选择索引 + 谓词下推 + 代价估算） ← 决定扫多少 part、用哪个索引
  │
  ▼
④ Executor（向量化 SIMD + 多线程 + 流水线） ← 实际执行，最耗时
  │
  ▼
结果集
```

**Profiling 三件套**：

| 工具 | 看什么 | 何时用 |
|------|--------|--------|
| `EXPLAIN` | 逻辑计划：读哪个表、用什么索引、扫多少分区 | SQL 写好后先看计划，确认走了索引 |
| `EXPLAIN PIPELINE` | 物理管道：多少线程、什么算子 | 查询慢但不知道卡哪一步时 |
| `EXPLAIN PLAN` + `actions=1` | 每步的具体操作（过滤、聚合、排序） | 确认谓词是否下推、列是否裁剪 |
| `system.processes` | 实时运行查询的 elapsed/read_rows/memory | 查询正在跑、要看实时资源 |
| `system.query_log` | 查询完成后的完整统计 | 查询已结束、要做历史分析（本环境用模拟表） |

### 3.2 优化手段决策表（最易混淆的取舍）

ClickHouse 的优化手段有 6 大类，它们不是"全用上最好"，而是根据查询模式取舍：

| 优化手段 | 原理 | 适用查询 | 代价 | 何时别用 |
|----------|------|----------|------|----------|
| **分区剪枝** | 按分区键只扫相关分区 | 时间范围查询 | 分区太多 → part 爆炸 | 非时间维度查询 |
| **稀疏主键（ORDER BY）** | 每 8192 行存一个 mark，二分定位 | 等值/范围查询排序列 | 排序列太多 → mark 膨胀 | 全表扫描型分析 |
| **跳数索引（SKIP INDEX）** | 每个 granularity 块存摘要（minmax/set/bloom） | 非排序列的过滤 | 写入时维护索引、无效时反而慢 | 选择性低的列 |
| **投影（Projection）** | 预计算另一组排序键/聚合结果 | 同表多查询模式 | 存储翻倍、写入变慢 | 写多读少 |
| **物化视图（MV）** | INSERT 触发预聚合到新表 | 固定聚合查询 | 多一张表要维护 | 查询模式频繁变 |
| **PREWHERE** | 先读过滤列，过滤后再读其余列 | 过滤性强的大宽表 | 只对 MergeTree 有效 | 过滤性弱或窄表 |

**稀疏主键 vs 跳数索引（最常混淆）**：

```
ORDER BY (user_id, timestamp)   ← 稀疏主键：全局有序，每 8192 行一个 mark
                                   查 user_id=100 → 二分定位 mark，跳过 99% 数据

INDEX idx_status status TYPE set(10)  ← 跳数索引：每个 granularity 块存值集合
                                        查 status='active' → 检查每个块是否含此值
```

- 主键是"全局有序定位"，跳数索引是"分块过滤"
- 主键列查询最快，但只能选少数列（影响排序和写入）
- 跳数索引用于主键没覆盖但需要过滤的列
- **两者可叠加**：主键定位到 mark，跳数索引在 mark 内进一步过滤

### 3.3 跳数索引类型对比

| 类型 | 存储内容 | 适用场景 | 误判率 |
|------|----------|----------|--------|
| `minmax` | 块内 min/max | 数值/日期范围查询 | 0（精确） |
| `set(N)` | 块内值集合（最多 N 个） | 低基数等值查询 | 0（精确） |
| `bloom_filter(p)` | 布隆过滤器 | 等值/IN 查询，高基数列 | p 为误判率 |
| `tokenbf_v1` | token 级布隆 | 字符串 token 搜索 | 有误判 |
| `ngrambf_v1` | ngram 布隆 | 字符串子串搜索 | 有误判 |

**关键**：bloom_filter 有误判（可能说"有"但实际没有，不会漏报），所以用于"加速"而非"精确过滤"。GRANULARITY 表示每多少个 mark 建一个索引条目。

### 3.4 PREWHERE 原理

```
普通 WHERE:
  读全部列 → 过滤 → 返回     （读了 100 列，过滤掉 99%，浪费）

PREWHERE:
  只读过滤列 → 过滤 → 按存活行读其余列  （只读了 1 列就过滤掉 99%）
```

- PREWHERE 是 ClickHouse 独有的 MergeTree 优化
- `SET optimize_move_to_prewhere=1` 时，ClickHouse 会自动把 WHERE 中过滤性强的条件移到 PREWHERE（默认开启）
- 手动指定 PREWHERE 用于：自动移动判断错误、或多个条件想精细控制读取顺序
- **坑**：PREWHERE 列如果过滤性弱（如 90% 行满足），反而比 WHERE 多读一次该列

---

## 4. 备份恢复策略（对应 02 SQL）

### 4.1 四层备份体系对比

| 层级 | 方案 | 原理 | RPO | RTO | 适用场景 |
|------|------|------|-----|-----|----------|
| L1 | BACKUP/RESTORE | 逻辑备份，复制 part 到备份目录 | 上次备份 | 分钟级 | 官方推荐，支持增量、S3 |
| L2 | ALTER FREEZE | 硬链接 part 到 shadow/ | 实时 | 秒级 | 零拷贝快照，配合文件系统 |
| L3 | 文件系统快照 | LVM/ZFS snapshot | 实时 | 秒级 | 停写后秒级快照 |
| L4 | 副本同步 | ReplicatedMergeTree | 秒级延迟 | 自动 | 故障自动切换，非"备份" |

**RPO（数据丢失容忍）vs RTO（恢复时间）**：L4 副本 RPO 最低但不防误删（DROP 会同步到副本），所以副本不能替代备份。

### 4.2 BACKUP/RESTORE 命令详解（CH 22.8+，25.12 已 GA）

```sql
-- 全量备份（需先配置 backup disk）
BACKUP TABLE advance_test.users TO Disk('backups', 'users_20260802.zip');

-- 增量备份（基于上次全量的 delta）
BACKUP TABLE advance_test.users TO Disk('backups', 'users_inc.zip')
SETTINGS base_backup = Disk('backups', 'users_20260802.zip');

-- 恢复
RESTORE TABLE advance_test.users FROM Disk('backups', 'users_20260802.zip');
```

**增量备份原理**：ClickHouse 的数据以 part 为单位。全量备份记录所有 part 的元数据；增量备份只复制"全量后新增/变更的 part"。所以增量备份的粒度是 part 级，非常高效。

**本环境限制**：Docker 镜像未配置 backup disk，02 SQL 文件中会用 `File('/tmp/')` 演示，并给出生产配置方法。

### 4.3 FREEZE 的硬链接原理

```
ALTER TABLE t FREEZE;
  ↓
对每个 active part 创建硬链接到 /var/lib/clickhouse/shadow/N/...
  ↓
硬链接 = 同一个 inode，两个文件名，不占额外空间（零拷贝）
  ↓
可安全复制 shadow/ 到异地，原表继续读写不受影响
```

- FREEZE 不锁定表、不阻塞读写
- 多次 FREEZE 生成 shadow/1, shadow/2, ...
- `ALTER TABLE t FREEZE WITH NAME 'tag'` → shadow/tag/，便于管理
- 清理：`ALTER TABLE t UNFREEZE WITH NAME 'tag'`

### 4.4 灾难恢复决策表

| 灾难场景 | 恢复方案 | 步骤 |
|----------|----------|------|
| 误删表（DROP） | RESTORE from backup | `RESTORE TABLE ... FROM Disk(...)` |
| 误删分区 | 副本同步或 RESTORE | 先看副本是否有，无则 RESTORE PARTITION |
| 数据损坏（part exception） | DETACH 损坏 part + 副本重同步 | `DETACH PART` → 等副本同步 → `ATTACH PART` |
| 整盘故障 | 副本接管 + 重建节点 | 换盘 → 重启节点 → ReplicatedMergeTree 自动拉取 |
| 整集群故障 | 异地备份恢复 | 从 S3/GCS 拉备份 → RESTORE → 重放增量 |

---

## 5. 监控指标体系（对应 03 SQL）

### 5.1 system 表三层体系

```
┌─────────────────────────────────────────────────────────┐
│  system.metrics         ← 瞬态值（当前连接数、活跃 part） │
│  (实时，随查询变化)        SELECT * → 一个 name/value 表    │
├─────────────────────────────────────────────────────────┤
│  system.asynchronous_metrics ← 周期采样（60s 一次）        │
│  (后台异步)                    CPU、内存、磁盘、网络        │
├─────────────────────────────────────────────────────────┤
│  system.events          ← 自启动累计值                     │
│  (只增不减)               Query、SelectQuery、FailedQuery  │
└─────────────────────────────────────────────────────────┘

日志表（按时间分区，可查询历史）：
  system.text_log     ← server 日志（Error/Fatal/Warning）
  system.part_log     ← part 操作（INSERT/MERGE/MUTATE）
  system.error_log    ← 错误聚合
  system.query_log    ← 查询完整统计（本环境未启用）
```

**关键区别**：
- `metrics` 是"当前状态"（仪表盘指针），`events` 是"累计计数"（里程表）
- 想知道"现在有多少查询在跑" → `metrics` / `processes`
- 想知道"今天总共跑了多少查询" → `events`（`Query` 事件计数）
- 想知道"某条查询的执行详情" → `query_log`（本环境用 `text_log` + `processes` 替代）

### 5.2 核心监控指标与告警阈值

| 指标类别 | 指标 | 来源 | 告警阈值 | 含义 |
|----------|------|------|----------|------|
| 查询 | 慢查询数 | query_log / processes | >5s 持续 1min | 查询性能退化 |
| 查询 | 失败查询数 | events.FailedQuery | >0 | 查询异常 |
| 内存 | OOM 风险 | asynchronous_metrics | >80% 物理内存 | 即将 OOM |
| 磁盘 | 可用空间 | disks.unreserved_space | <20% | 即将写满 |
| 复制 | absolute_delay | replicas | >60s | 副本同步滞后 |
| 复制 | queue_size | replicas | >100 | 复制堆积 |
| 合并 | 未合并 part 数 | parts WHERE level=0 | >10/分区 | 合并跟不上写入 |
| 合并 | 异常 part | parts.exception | !='' | 数据损坏 |

### 5.3 本环境的 query_log 替代方案

本 Docker 镜像未启用 `system.query_log`（配置存在但表未创建）。03 SQL 文件采用以下替代：
- 实时查询监控 → `system.processes`（正在运行的查询）
- 历史日志 → `system.text_log`（server 日志，含 Error/Fatal）
- 错误统计 → `system.error_log`
- 慢查询分析演示 → 自建 `advance_test.query_history` 模拟表（注释说明生产应用 query_log）

---

## 6. 安全模型（对应 04 SQL）

### 6.1 认证方式对比

| 认证方式 | 配置 | 安全性 | 适用场景 |
|----------|------|--------|----------|
| `plaintext_password` | 明文存储 | 低 | 仅开发/测试 |
| `sha256_password` | 存 SHA256 哈希 | 中 | 通用推荐 |
| `double_sha1_password` | 存双重 SHA1 | 中低 | 兼容 MySQL 客户端 |
| `bcrypt_password` | 存 bcrypt 哈希 | 高 | 生产推荐（抗暴力破解） |
| `ldap` | 外部 LDAP/AD | 高 | 企业集成 |
| `kerberos` | Kerberos 票据 | 高 | Hadoop 生态集成 |

### 6.2 RBAC 模型：USER → ROLE → GRANT

```
┌─────────┐    GRANT ROLE    ┌─────────┐    GRANT PRIVILEGE    ┌──────────────┐
│  USER   │ ──────────────→  │  ROLE   │ ──────────────────→   │  PRIVILEGE   │
│ (who)   │                  │ (group) │                       │ (what)       │
└─────────┘                  └─────────┘                       └──────────────┘
     │                                                             │
     │  用户可有多角色，角色可继承                                  │
     │  权限粒度：*.* / db.* / db.table / db.table.col             │
     │  GRANT OPTION：允许被授权者再授权                            │
     └─────────────────────────────────────────────────────────────┘
```

**最佳实践**：
- 给"角色"授权，而非直接给"用户"授权 → 人员变动只需改角色绑定
- 最小权限：只读用户绝不给 ALTER/DROP
- 用 `SETTINGS PROFILE` 限制资源（max_memory_usage、max_threads、readonly）
- `readonly=1` 设置可让用户物理上无法写

### 6.3 行级安全（Row Policy）

```sql
-- 只让用户看到自己部门的数据
CREATE POLICY dept_filter ON advance_test.users
    USING department = currentUser()  -- 每行过滤
    TO analyst_role;
```

- `USING expr` 是行级过滤条件，对 SELECT 自动追加
- `AS RESTRICTIVE` 表示与其他 policy 取交集（默认是 UNION）
- 一个用户可有多个 policy，默认 OR（取并集），RESTRICTIVE 则 AND
- **比视图更安全**：用户无法绕过 policy 直接查原表

### 6.4 配额（Quota）vs 设置（Settings Profile）

| 机制 | 限制维度 | 场景 | 示例 |
|------|----------|------|------|
| SETTINGS PROFILE | 单查询资源 | 限制单查询内存/时间 | `max_memory_usage=10GB` |
| QUOTA | 时间窗口内累计 | 限制用户总查询量 | `1 小时内最多 1000 次查询` |
| 同时用 | 单查 + 累计 | 防止"大查询"和"刷接口" | profile 限单次，quota 限总量 |

---

## 7. 高可用架构（对应 05 SQL）

### 7.1 副本机制：ReplicatedMergeTree + Keeper

```
                ┌─────────────────────────────┐
                │       Keeper (ZooKeeper)     │
                │   存复制日志、选举 Leader      │
                └──────┬──────────────┬────────┘
                       │              │
            ┌──────────▼──┐    ┌──────▼──────────┐
            │  Replica 1   │    │   Replica 2      │
            │  (Leader)    │    │   (Follower)     │
            │  INSERT →    │    │   ← 拉取 log     │
            │  写 log 到 ZK │    │   执行 INSERT    │
            └──────────────┘    └─────────────────┘

写入流程：
  1. 客户端写 Replica 1
  2. Replica 1 写 part + 在 ZK 记录 log entry
  3. Replica 2 监听 ZK，拉取 log，执行相同 INSERT
  4. 完成后更新 ZK 中的版本号

读取流程：
  Distributed 表自动选一个副本读（负载均衡）
```

- **Leader 选举**：每个 ReplicatedMergeTree 表有且仅有一个 Leader（负责合并/mutation 调度），Leader 宕机后自动重选
- **最终一致**：副本同步是异步的，`absolute_delay` 表示滞后秒数
- **is_readonly**：副本与 ZK 失联时变只读（防止脑裂写入不一致）

### 7.2 高可用层级

| 层级 | 机制 | 防什么故障 |
|------|------|------------|
| 表级 | ReplicatedMergeTree | 单 part 损坏、单副本宕机 |
| 节点级 | 副本在不同节点 | 节点宕机 |
| 分片级 | Distributed 表跨分片 | 单分片整体故障 |
| 机房级 | 跨机房副本 | 机房断网/断电 |
| 接入级 | LB / Keepalived / DNS | 客户端连接高可用 |

### 7.3 负载均衡策略

| 方案 | 层级 | 优缺点 |
|------|------|--------|
| Distributed 表 | 引擎层 | 自动选副本，但单点（发起节点） |
| clickhouse-lb | 代理层 | 轮询/最少连接，需额外部署 |
| HAProxy / Nginx | 代理层 | 成熟，TCP 透传，无 SQL 感知 |
| Keepalived VIP | 网络层 | 客户端无感，单 VIP |
| DNS 轮询 | DNS | 简单但无健康检查 |

**Distributed 表的副本选择**：
- `load_balance=round_robin`（默认）：轮询
- `load_balance=random`：随机
- `load_balance=nearest_hostname`：按主机名距离
- 副本不可用时自动跳过（`errors_count` 累加，超阈值后熔断）

### 7.4 一致性模型

ClickHouse 复制是**异步最终一致**，不提供强一致读：

| 一致性级别 | 方法 | 代价 |
|------------|------|------|
| 最终一致（默认） | 直接读副本 | 可读到旧数据（delay 秒内） |
| 读己所写 | 同会话读 Leader | 需识别 Leader |
| 强一致 | `SELECT ... SETTINGS select_sequential_consistency=1` | 等待所有副本同步，慢 |
| 写后立读 | 写入后 `SYSTEM SYNC REPLICA` | 阻塞等待同步完成 |

---

## 8. 数据迁移（对应 06 SQL）

### 8.1 迁移工具决策表

| 工具 | 场景 | 数据量 | 特点 |
|------|------|--------|------|
| `INSERT SELECT` + `remote()` | 跨实例拉取 | 中小（<1TB） | 简单，单线程，无断点 |
| `clickhouse-copier` | 跨集群 | 大（>1TB） | 官方，分布式，分片重分布，断点续传 |
| `BACKUP/RESTORE` | 同/跨集群 | 任意 | 快照级，支持增量 |
| `file()/s3()/url()` | 外部数据源导入 | 中小 | 直接读文件/S3/HTTP |
| 导出 + 导入（CSV/TSV） | 跨系统（如 MySQL→CH） | 任意 | 格式转换，离线 |
| `ALTER TABLE ... ATTACH PARTITION` | 同集群换表 | 大 | 零拷贝，秒级 |

### 8.2 格式选择决策表

| 格式 | 写入速度 | 压缩率 | 类型安全 | 场景 |
|------|----------|--------|----------|------|
| `TabSeparated` (TSV) | 最快 | 无 | 无（靠位置） | 内部 CH→CH，高性能 |
| `CSV` / `CSVWithNames` | 快 | 无 | 弱 | 通用交换 |
| `JSONEachRow` | 中 | 无 | 强 | API 对接、半结构化 |
| `Native` | 最快 | 无 | 强 | CH→CH 最佳（二进制） |
| `Parquet` | 中 | 高 | 强 | 大数据生态（Spark/Hive） |
| `Arrow` | 中 | 高 | 强 | 列式交换 |
| `RowBinary` | 快 | 无 | 强 | 紧凑二进制 |

**CH→CH 迁移首选 `Native` 格式**：二进制、无损、最快。CH→外部系统选 `Parquet`。

### 8.3 增量迁移模式

```
首次全量：
  INSERT INTO dest SELECT * FROM remote('src', db, table)

增量（按时间戳）：
  INSERT INTO dest
  SELECT * FROM remote('src', db, table)
  WHERE updated_at > (SELECT max(updated_at) FROM dest)

增量（按 ID）：
  INSERT INTO dest
  SELECT * FROM remote('src', db, table)
  WHERE id > (SELECT max(id) FROM dest)
```

**注意**：增量迁移要求源表有单调递增的时间戳或 ID。无此字段的表只能用 BACKUP 或 copier。

---

## 9. 故障排查方法论（对应 07 SQL）

### 9.1 排查五步法

```
① 症状识别 ─→ "查询慢"/"复制延迟"/"磁盘满"/"连接拒绝"
     │
② 初步诊断 ─→ system.clusters / replicas / processes / disks（30 秒定位大方向）
     │
③ 深入分析 ─→ text_log / replication_queue / parts / merges（找到具体表/查询）
     │
④ 根因定位 ─→ EXPLAIN / part 异常 / 配置变更回顾（找到为什么）
     │
⑤ 修复验证 ─→ 修复 + 监控指标回归正常（确认解决）
```

### 9.2 常见故障速查表

| 症状 | 第一步查什么 | 可能根因 | 修复 |
|------|-------------|----------|------|
| 查询变慢 | `system.processes` + `parts WHERE level=0` | part 爆炸 / 合并滞后 | `OPTIMIZE FINAL` / 调合并线程 |
| 表变只读 | `system.replicas WHERE is_readonly=1` | ZK 失联 / 磁盘满 | 恢复 ZK / 清理磁盘 |
| 复制延迟 | `system.replicas.absolute_delay` | 网络 / 写入过快 / 大合并 | 限速写入 / 等合并完成 |
| OOM | `asynchronous_metrics` 内存 | 查询内存超限 | `max_memory_usage` 限流 |
| 磁盘满 | `system.disks` | part 未合并 / 旧数据 | `DROP PARTITION` / `OPTIMIZE` |
| INSERT 慢 | `system.processes` + part_log | 太多小 INSERT | 批量插入 / async_insert |
| 数据不一致 | `system.parts.exception` | part 损坏 | DETACH + 副本重同步 |

### 9.3 EXPLAIN 诊断查询计划

```sql
-- 1. 看逻辑计划：确认分区剪枝、索引使用
EXPLAIN SELECT ... ;

-- 2. 看物理管道：确认线程数、算子
EXPLAIN PIPELINE SELECT ... ;

-- 3. 看详细操作：确认谓词下推、列裁剪
EXPLAIN PLAN SELECT ... SETTINGS optimize_use_projections=1;

-- 4. 看索引使用标记
EXPLAIN indexes=1 SELECT ... ;
```

---

## 10. 文件导航

| 文件 | 内容 | 关键章节 |
|------|------|----------|
| [01_performance_optimization.sql](./01_performance_optimization.sql) | 查询 Profiling + 索引 + 分区 + 投影 + PREWHERE + 资源控制 | §2 EXPLAIN 三件套、§3 排序键优化、§4 跳数索引四类型、§5 投影、§7 PREWHERE、§9 采样 |
| [02_backup_recovery.sql](./02_backup_recovery.sql) | BACKUP/RESTORE + FREEZE + 分区级备份 + 校验 | §2 BACKUP 全量+增量、§3 FREEZE 硬链接、§5 备份表、§8 数据校验 |
| [03_monitoring_metrics.sql](./03_monitoring_metrics.sql) | system 三层指标 + 慢查询 + 资源 + 复制 + 告警 | §1 健康检查、§2 三层指标、§4 表性能、§5 复制监控、§12 性能基线、§13 告警规则 |
| [04_security_config.sql](./04_security_config.sql) | RBAC + 行级安全 + 配额 + 审计 + 数据掩码 | §1 用户角色、§3 SETTINGS PROFILE + QUOTA、§4 行级安全、§6 数据掩码、§7 审计 |
| [05_high_availability.sql](./05_high_availability.sql) | 集群架构 + 副本 + 故障转移 + 负载均衡 + 一致性 | §1 集群拓扑、§2 复制状态、§3 Leader 选举、§4 负载均衡、§5 一致性校验、§9 容灾 |
| [06_data_migration.sql](./06_data_migration.sql) | 导出导入 + 格式转换 + remote + 清洗 + 增量 | §1 格式对比、§2 导出、§3 导入、§4 remote 迁移、§5 数据清洗、§6 增量迁移、§7 校验 |
| [07_troubleshooting.sql](./07_troubleshooting.sql) | 系统诊断 + 性能瓶颈 + 复制故障 + 数据损坏 | §1 健康检查、§2 性能诊断、§3 复制诊断、§4 磁盘、§5 内存、§6 合并、§8 日志、§12 损坏修复 |

---

## 11. 常见误区与最佳实践

### 误区
1. **副本就是备份** → DROP 会同步到副本，副本不防误删，必须配 BACKUP
2. **part 越多越好并行** → part 过多导致合并跟不上、查询要扫更多文件，应控制每分区 1-10 个 part
3. **`OPTIMIZE TABLE FINAL` 随便用** → FINAL 会强制全量合并，重写所有数据，生产环境慎用
4. **跳数索引越多越好** → 无效的跳数索引增加写入开销却无法过滤，bloom 有误判
5. **`count(*)` 和 `count()` 一样** → ClickHouse 惯用 `count()`，`count(*)` 虽可用但非惯用
6. **用 `//` 注释** → ClickHouse 只支持 `--` 注释，`//` 会语法错误
7. **投影和物化视图随便加** → 投影使存储翻倍、物化视图增加写入开销，写多读少场景别用
8. **PREWHERE 一定比 WHERE 快** → 过滤性弱时反而多读一次列，让优化器自动判断更安全
9. **复制是强一致的** → 异步复制有延迟，强一致需 `select_sequential_consistency=1`（很慢）
10. **RBAC 直接给用户授权** → 应给角色授权再绑定用户，便于管理

### 最佳实践
1. **三层备份策略**：副本（L4 防硬件故障）+ BACKUP 增量（L1 防误删）+ 异地存储（防机房故障）
2. **分区按月、排序键 3-4 列**：`PARTITION BY toYYYYMM(dt)` + `ORDER BY (uid, dt)` 是通用最优解
3. **小 INSERT 批量化**：单次 INSERT < 1 次/秒，用缓冲表或 async_insert 聚合
4. **监控三指标**：`absolute_delay`（复制）、`level=0 part 数`（合并）、`unreserved_space`（磁盘）
5. **RBAC 最小权限**：应用用户只给 `SELECT, INSERT`，运维操作走专用 admin 用户
6. **慢查询加 `max_execution_time`**：防大查询拖垮集群，配合 `max_memory_usage` 双保险
7. **迁移先校验再切换**：行数 + 校验和对比，灰度切流量
8. **EXPLAIN 先行**：新 SQL 上线前先 EXPLAIN 确认走索引、有分区剪枝

---

## 12. 自测题（理解检查点）

完成本章后，应能回答：

1. `EXPLAIN` 和 `EXPLAIN PIPELINE` 分别看什么？查"查询为什么慢"该用哪个？
2. 稀疏主键（ORDER BY）和跳数索引（SKIP INDEX）的原理区别是什么？什么场景下两者都该用？
3. `bloom_filter` 跳数索引为什么有"误判"？它会不会漏报（过滤掉本该保留的行）？
4. 副本（ReplicatedMergeTree）能防"误删表"吗？为什么？应该用什么方案补足？
5. `BACKUP` 的增量备份原理是什么？粒度是行级还是 part 级？
6. `system.metrics`、`system.events`、`system.asynchronous_metrics` 三者的区别？想看"今天总查询数"用哪个？
7. `SETTINGS PROFILE` 和 `QUOTA` 都能限制资源，区别是什么？生产环境应该怎么配合使用？
8. 行级安全（CREATE POLICY）比视图安全在哪里？用户能绕过 policy 直接查原表吗？
9. ClickHouse 的复制是强一致还是最终一致？如何实现"写后立读"不读到旧数据？
10. CH→CH 跨集群迁移 10TB 数据，首选什么工具？为什么不用 INSERT SELECT + remote()？
11. 表变只读（`is_readonly=1`）通常是什么原因？第一步该查什么？
12. `OPTIMIZE TABLE FINAL` 在生产环境为什么慎用？什么场景必须用？

答案线索均在本 README 及配套 SQL 文件中。

---

## 13. 关联章节

- [04-functions](../04-functions/README.md) —— 聚合状态函数（*State/*Merge），性能优化的预聚合基础
- [03-engines](../03-engines/README.md) —— ReplicatedMergeTree / Distributed 引擎详解，高可用的引擎层
- [16-principle](../16-principle/README.md) —— 查询执行管道、向量化原理，性能优化的底层
- [11-performance](../11-performance/README.md) —— 性能调优专题（与本章 §3 互补）

---

## 14. 参考资源

- [ClickHouse 性能优化](https://clickhouse.com/docs/en/operations/optimization)
- [BACKUP 与 RESTORE](https://clickhouse.com/docs/en/operations/backup)
- [System 表监控](https://clickhouse.com/docs/en/operations/system-tables/overview)
- [访问控制与 RBAC](https://clickhouse.com/docs/en/guides/sre/user-management/index)
- [Row Policies 行级安全](https://clickhouse.com/docs/en/sql-reference/statements/create/row-policy)
- [Quotas 配额](https://clickhouse.com/docs/en/sql-reference/statements/create/quota)
- [ReplicatedMergeTree 复制](https://clickhouse.com/docs/en/engines/table-engines/mergetree-family/replication)
- [clickhouse-copier 跨集群迁移](https://clickhouse.com/docs/en/operations/utilities/clickhouse-copier)
- [clickhouse-backup 工具](https://github.com/Altinity/clickhouse-backup)
- [生产部署指南](https://clickhouse.com/docs/en/operations/deployment)
