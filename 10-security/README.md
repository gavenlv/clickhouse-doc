# 安全与权限控制

ClickHouse 安全体系不是一堵墙，而是一座多层城堡——从最外层的网络隔离，到中间层的认证授权，直到最内层的数据加密和审计追溯。本章将带你从"能用"到"安全可控"，覆盖认证、RBAC、行级安全、Quota/Workload、多租户隔离五大安全支柱。

## 本章解决什么问题

| 痛点 | 对应专题 | 一句话解答 |
|------|---------|-----------|
| **谁在用？** 用户身份不明，密码泄露风险 | [01 用户认证](./01_authentication.md) | SHA-256/LDAP/Kerberos/SSL 多种认证，推荐 SHA-256 + 角色组合 |
| **能干什么？** 权限混乱，开发能看到生产表 | [02 用户角色管理](./02_user_role_management.md) + [03 权限控制](./03_permissions.md) | RBAC 模型：用户 → 角色 → 权限，最小权限原则 |
| **看了不该看的？** 同一张表，A 用户能看到 B 用户数据 | [04 行级安全](./04_row_level_security.md) | ROW POLICY 自动注入 WHERE 条件，客户端不可绕过 |
| **传输被截获？** HTTP 明文密码在网络上裸奔 | [05 网络安全](./05_network_security.md) | SSL/TLS 双向认证 + IP 白名单 + 防火墙 |
| **磁盘丢了？** 硬盘送修，数据被读取 | [06 数据加密](./06_data_encryption.md) | 全盘加密 + 列级加密 + 传输加密三件套 |
| **谁删了表？** 出事了追溯不到操作人 | [07 审计日志](./07_audit_log.md) | query_log / session_log / mutation_log 完整审计链 |
| **怎么做最安全？** 配置项太多不知如何取舍 | [08 安全最佳实践](./08_best_practices.md) | 纵深防御 + 最小权限 + 定期审计 + 合规配置 |
| **配置太乱？** XML 和 SQL 混着用，不知道哪个生效 | [09 常见安全配置](./09_common_configs.md) | users.xml + config.xml + SQL RBAC 三层配置对照 |
| **资源被抢光？** 一个人查慢查询，所有人跟着慢 | [10 Quota 与 Workload](./10_quota_workload.md) | Quota 限制"用量"，Workload Group 调度"优先级" |
| **租户看串了？** SaaS 多客户共享集群，数据隔离怎么做 | [11 多租户隔离](./11_multi_tenancy.md) | 数据库级/表级/行级/混合四种策略，按规模选型 |

## ClickHouse 安全体系全景

```
┌──────────────────────────────────────────────────────────────────┐
│                    ClickHouse 安全五层防御                        │
├──────────────────────────────────────────────────────────────────┤
│                                                                  │
│  第 1 层：网络安全（05_network_security）                         │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │  SSL/TLS 双向认证 · IP 白名单 · 防火墙 · HTTP 头校验      │   │
│  │  → 决定"能不能连"                                        │   │
│  └──────────────────────────────────────────────────────────┘   │
│                            ↓                                     │
│  第 2 层：认证（01_authentication）                               │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │  SHA-256 · LDAP · Kerberos · SSL 证书 · PAM             │   │
│  │  → 决定"你是谁"                                          │   │
│  └──────────────────────────────────────────────────────────┘   │
│                            ↓                                     │
│  第 3 层：授权（02_user_role_management + 03_permissions）        │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │  RBAC：用户 → 角色 → 权限    行级安全：ROW POLICY         │   │
│  │  → 决定"你能干什么"         → 决定"你能看哪些行"         │   │
│  └──────────────────────────────────────────────────────────┘   │
│                            ↓                                     │
│  第 4 层：资源管控（10_quota_workload + 11_multi_tenancy）        │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │  Quota：限制用量    Workload：调度优先级    多租户：隔离   │   │
│  │  → 决定"能用多少"                                    │   │
│  └──────────────────────────────────────────────────────────┘   │
│                            ↓                                     │
│  第 5 层：审计与加密（06_data_encryption + 07_audit_log）         │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │  数据加密：磁盘/列级/传输    审计日志：query_log/session  │   │
│  │  → 决定"出事了能不能追溯"                               │   │
│  └──────────────────────────────────────────────────────────┘   │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

## 核心概念深度

### RBAC 模型：用户、角色、权限的三角关系

ClickHouse 从 **22.x** 版本开始，RBAC 能力达到生产级。理解三者关系是安全配置的基础：

```
用户（User）
  └─ 属于多个 ──→ 角色（Role）
                    ├─ 拥有 ──→ 权限（Grant）
                    │            ├─ 全局：SELECT ON *.*
                    │            ├─ 数据库：SELECT ON db.*
                    │            ├─ 表级：SELECT ON db.table
                    │            ├─ 列级：SELECT(col1, col2) ON db.table
                    │            └─ 行级：ROW POLICY ON table
                    └─ 绑定 ──→ SETTINGS（max_memory_usage 等）
```

**为什么用角色而不是直接给用户授权？**

直接授权（`GRANT SELECT ON *.* TO alice`）的问题是：
1. 用户多了后，每个人的权限需要逐一检查和修改
2. 新人入职需要重复配置
3. 离职时要逐条回收

而用角色（`GRANT reader_role TO alice`）：
1. Alice 入职 → `GRANT reader_role TO alice`，一行搞定
2. reader 角色的权限变更 → 所有 reader 用户自动生效
3. Alice 离职 → `REVOKE reader_role FROM alice`，一行撤完
4. 权限审计 → `SHOW GRANTS FOR reader_role`，一目了然

### 行级安全（RLS）原理

行级安全不是"在查询上加 WHERE 过滤"，而是 **SQL 解析器层面注入过滤条件**：

```
客户端发送：SELECT * FROM orders
                ↓
    解析器检查：用户是否有 ROW POLICY？
                ↓
        注入条件：tenant_id = current_user_settings['tenant_id']
                ↓
        实际执行：SELECT * FROM orders WHERE tenant_id = 'xxx'
```

这意味着：
- **客户端无法绕过**——过滤发生在服务器端，SQL 层面
- **性能不降反升**——如果 `tenant_id` 是排序键首列，ClickHouse 直接走稀疏索引
- **管理员例外**——拥有 `ACCESS_MANAGEMENT` 权限的用户不受行策略约束（可用来做全局报表）
- **INSERT 不受影响**——行策略只作用于 SELECT，插入数据时 `tenant_id` 需要应用层传入

### Quota vs Workload Group vs Settings：三层资源管控

很多人在学 ClickHouse 安全时把这三个概念混淆，这里给出本质区别：

```
┌─────────────┬──────────────────┬──────────────────┬─────────────────┐
│   机制       │  Quota           │  Workload Group  │  Settings        │
├─────────────┼──────────────────┼──────────────────┼─────────────────┤
│ 管控维度    │ 使用量（累计）     │ 调度（实时）      │ 单次查询边界     │
│ 时间窗口    │ PER DAY/WEEK/     │ 实时持续          │ 无时间概念      │
│             │ MONTH 累计重置    │                   │                │
│ 核心约束    │ 查了多少秒/多少行  │ 并发数/优先级/内存 │ 本查询内存/时间  │
│ 超出行为    │ 拒绝新查询        │ 排队等待          │ 查询中止 OOM    │
│ 典型配置    │ QUERY_TIME=3600  │ priority=1        │ max_memory=10GB │
│             │ PER DAY           │ max_concurrent=10 │                 │
│ 谁的时间线  │ 累加型（今天到现在）│ 瞬时型（此刻）    │ 瞬时型（本查询） │
└─────────────┴──────────────────┴──────────────────┴─────────────────┘
```

**一张图理解三者如何配合**：

```
用户发起查询
    ↓
Settings 检查：这个查询内存/时间会不会超？ → 超了直接中止
    ↓
Quota 检查：今天已经查了多久/多少数据？ → 超了拒绝执行
    ↓
Workload Group：当前队列有多少查询？优先级多少？ → 排队或立即执行
    ↓
查询执行中……
```

### 多租户隔离四种策略的本质

```
策略           tenant_id 在哪？      删除租户怎么做？          跨租户查询怎么查？
─────────────────────────────────────────────────────────────────────────────
数据库级       数据库名 = tenant      DROP DATABASE               UNION ALL 各库
表级           表名 = db.orders_001   DROP TABLE                  UNION ALL 各表  
行级（RLS）    表中 tenant_id 列      ALTER TABLE DELETE WHERE   WHERE tenant_id IN (...)
混合           大租户专属库+小租户      分别处理                    UNION ALL + WHERE
```

**选型决策**：

```
租户数量？
├── < 30（每个数据量大） → 数据库级隔离（最安全，独立备份恢复）
├── 30-300（中等数据量） → 表级隔离（管理友好，升级容易）
├── > 300（每个数据量小）→ 行级 RLS（管理成本最低，一张表搞定）
└── 混合 → 大租户独享库 + 小租户共享 RLS 表

合规要求？
├── 金融/医疗/GDPR → 数据库级（可证明的物理隔离）
├── 一般业务 SaaS → 行级 RLS（足够，审计补充）
└── 不清楚 → 从数据库级开始（可以降级到行级，反之需要迁移）
```

## 文档导航

### 基础安全（必读）

| 编号 | 专题 | 文件 | 配套 SQL | 学习难度 |
|------|------|------|----------|---------|
| 01 | 用户认证 | [01_authentication.md](./01_authentication.md) | [sql](./01_authentication_examples.sql) | 入门 |
| 02 | 用户和角色管理 | [02_user_role_management.md](./02_user_role_management.md) | [sql](./02_user_role_management_examples.sql) | 入门 |
| 03 | 权限控制 | [03_permissions.md](./03_permissions.md) | [sql](./03_permissions_examples.sql) | 入门 |
| 04 | 行级安全 | [04_row_level_security.md](./04_row_level_security.md) | [sql](./04_row_level_security_examples.sql) | 进阶 |
| 09 | 常见安全配置 | [09_common_configs.md](./09_common_configs.md) | [sql](./09_common_configs_examples.sql) | 入门 |

### 网络安全与加密

| 编号 | 专题 | 文件 | 配套 SQL | 学习难度 |
|------|------|------|----------|---------|
| 05 | 网络安全 | [05_network_security.md](./05_network_security.md) | [sql](./05_network_security_examples.sql) | 进阶 |
| 06 | 数据加密 | [06_data_encryption.md](./06_data_encryption.md) | [sql](./06_data_encryption_examples.sql) | 进阶 |

### 运维安全（进阶）

| 编号 | 专题 | 文件 | 配套 SQL | 学习难度 |
|------|------|------|----------|---------|
| 07 | 审计日志 | [07_audit_log.md](./07_audit_log.md) | [sql](./07_audit_log_examples.sql) | 进阶 |
| 08 | 安全最佳实践 | [08_best_practices.md](./08_best_practices.md) | [sql](./08_best_practices_examples.sql) | 进阶 |

### 资源管控与多租户（高级）

| 编号 | 专题 | 文件 | 配套 SQL | 学习难度 |
|------|------|------|----------|---------|
| 10 | Quota 与 Workload Management | [10_quota_workload.md](./10_quota_workload.md) | [sql](./10_quota_workload_examples.sql) | 高级 |
| 11 | 多租户隔离 | [11_multi_tenancy.md](./11_multi_tenancy.md) | [sql](./11_multi_tenancy_examples.sql) | 高级 |

## 快速上手：5 步搭建最小安全体系

如果你是第一次给 ClickHouse 配置安全，按以下顺序操作：

### 第 1 步：启用 SQL 方式管理访问控制

```xml
<!-- config.xml -->
<access_control_path>/var/lib/clickhouse/access/</access_control_path>
```

### 第 2 步：创建管理员

```sql
CREATE USER IF NOT EXISTS admin
IDENTIFIED WITH sha256_password BY 'YourStrongPassword123!'
SETTINGS access_management = 1;
```

### 第 3 步：创建角色体系

```sql
-- 三种内置角色，覆盖生产常见场景
CREATE ROLE IF NOT EXISTS reader;
GRANT SELECT ON *.* TO reader;

CREATE ROLE IF NOT EXISTS writer;
GRANT SELECT, INSERT ON *.* TO writer;

CREATE ROLE IF NOT EXISTS analyst;
GRANT SELECT ON *.* TO analyst
SETTINGS
    max_memory_usage = 10000000000,     -- 10 GB
    max_execution_time = 600,           -- 10 分钟
    readonly = 2;                       -- 只允许 SELECT
```

### 第 4 步：创建用户并分配角色

```sql
CREATE USER IF NOT EXISTS bob
IDENTIFIED WITH sha256_password BY 'BobPass123!';
GRANT analyst TO bob;
```

### 第 5 步：最小化 default 用户

```sql
-- default 用户有全局权限，必须限制
ALTER USER default
SETTINGS max_memory_usage = 100000000,   -- 100 MB
    max_execution_time = 10;             -- 10 秒
```

## 常见误区

| 误区 | 现实 |
|------|------|
| **"default 用户不影响我，我不用就行了"** | CH 服务启动时默认开放 8123 端口，不带密码的 HTTP 请求以 `default` 用户执行。必须限制 default 用户 |
| **"RBAC 就是创建用户再给权限"** | 直接给用户授权无法批量管理。必须经过角色层（User → Role → Grant） |
| **"行策略（ROW POLICY）会影响性能"** | 如果 `tenant_id` 作为排序键首列，行策略的 WHERE 条件会走稀疏索引，几乎没有额外开销 |
| **"Workload Group 高优查询会中断低优查询"** | CH 的调度是非抢占式，高优查询到达时只会优先排队，不会杀掉正在执行的低优查询 |
| **"多租户隔离用 RLS 就够了"** | RLS 过滤在查询层面，管理员不受约束。高合规要求场景（金融/医疗）必须数据库级隔离 |
| **"Quota 限制的是并发数"** | Quota 限制的是累计使用量（今天查了多少秒），并发控制在 Workload Group 中管理 |
| **"SSL 配了就行，不用管证书过期"** | 证书过期后集群所有节点间通信都会中断（包括复制和分布式查询），需要证书轮换脚本 |
| **"权限只要设好了就不管了"** | 业务发展、人员变动、新表创建都会产生权限缺口，建议每月做权限审计 |

## 安全配置检查清单

### 基础安全（上线前必检）

- [ ] 已替换或限制 `default` 用户权限
- [ ] 已创建管理员用户（`access_management = 1`）
- [ ] 已启用 `access_control_path`（SQL 方式管理安全）
- [ ] 所有用户使用 SHA-256 密码（而非明文）
- [ ] 采用角色管理权限（User → Role → Grant）
- [ ] `system` 库只读对非管理员关闭

### 网络安全

- [ ] HTTP 端口（8123）仅内网可访问
- [ ] 已配置 SSL/TLS 加密传输
- [ ] 已配置 IP 白名单（`<ip_filter>` 或 `users.xml` 中 `ip` 限制）
- [ ] 9000 原生端口不暴露到公网
- [ ] Keeper 端口（9181）仅集群节点可访问

### 数据保护

- [ ] 敏感数据（PII、密码 Hash）已列级加密
- [ ] 已启用磁盘加密（生产环境）
- [ ] 备份文件存储在加密存储中
- [ ] TTL 策略已配置（自动清理过期数据）

### 访问控制

- [ ] 权限分配遵循最小权限原则
- [ ] 行级安全策略已配置（多租户/多部门场景）
- [ ] 列级权限已限制敏感列（如身份证、密码）
- [ ] 管理员权限仅分配给 DBA

### 资源管控

- [ ] 每个角色/用户配置了 Quota（每日查询量限制）
- [ ] 生产/ETL/Ad-hoc 查询分配了不同 Workload Group
- [ ] 内存限制（`max_memory_usage`）已按角色设置
- [ ] 查询超时限制（`max_execution_time`）已配置

### 审计与监控

- [ ] 查询日志（`query_log` 或 `query_thread_log`）已启用
- [ ] 审计日志已配置（包含 DDL / DCL / 权限变更）
- [ ] 审计日志设置了 TTL（避免磁盘写满）
- [ ] 异常登录/权限变更已配置告警
- [ ] 按月进行权限审计

### 多租户（如果适用）

- [ ] 已根据租户规模选择隔离策略
- [ ] `tenant_id` 作为排序键首列
- [ ] RL S 场景下所有租户用户通过角色管理行策略
- [ ] 按租户配置了 Workload Group 和 Quota
- [ ] 按租户维度监控资源消耗
- [ ] 租户创建/删除已自动化

## 学习路径建议

```
第一天：1 → 2 → 3（认证 + 角色 + 权限）→ 动手配置一套 RBAC 体系
第二天：4 → 5 → 6（行级安全 + 网络 + 加密）→ 实现一个多部门数据隔离场景
第三天：7 → 8 → 9（审计 + 最佳实践 + 配置速查）
第四天：10（Quota + Workload Group）→ 实现铂金/黄金/银牌三级 SLA
第五天：11（多租户）→ 从行级到混合策略的完整演进
```

## 相关章节

- [点击前往 08-performance（性能优化）](../08-performance/README.md) —— 安全配置也可能影响性能
- [点击前往 11-monitoring-ops（监控运维）](../11-monitoring-ops/README.md) —— 审计日志与 Prometheus 集成
- [点击前往 09-distributed（分布式架构）](../09-distributed/README.md) —— Keeper 安全配置
- [ClickHouse 官方安全文档](https://clickhouse.com/docs/en/operations/access-rights)

---
**注意**：本章所有 SQL 示例针对 `treasurycluster` 集群（CH 25.12.1.649）优化，密码均为示例，生产环境请替换为高强度密码。
