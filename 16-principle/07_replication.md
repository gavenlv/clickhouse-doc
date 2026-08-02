# 复制原理（专家级详解）

> 本章回答 ClickHouse 高可用与数据安全的基石：**ReplicatedMergeTree 如何基于 Keeper 实现异步复制、副本间为何可能不一致、quorum 写入何时该用、故障恢复怎么发生**。读完本章，你应能：画出 INSERT 的复制全流程、判断该不该用 `insert_quorum`、读懂 `system.replicas` 诊断副本健康。
>
> 配套可运行 SQL：[08_sharding.sql](./08_sharding.sql)（含 ReplicatedMergeTree 创建、副本状态查询）。集群：`treasurycluster`（CH 25.12.1.649，2 副本 × 1 分片，3 Keeper）。

---

## 1. 本章解决什么问题（Why）

| 痛点 | 本章如何解答 |
|------|--------------|
| 为什么 ClickHouse 副本间可能短暂不一致？是 bug 吗？ | §2 异步复制语义（非 bug，是设计权衡） |
| `ReplicatedMergeTree` 的两个参数 `/path` 和 `replica` 到底什么意思？ | §3.1 ZooKeeper 路径模型 |
| INSERT 后立刻在另一个副本查不到数据，正常吗？ | §4.1 复制延迟与 `absolute_delay` |
| `insert_quorum = 2` 和 `select_sequential_consistency = 1` 该开吗？ | §5 quorum 写入与强一致读的代价 |
| Keeper 挂了一个，复制还能继续吗？挂两个呢？ | §6.2 Keeper 容错（Raft 多数派） |
| 副本故障恢复后，怎么追上落后数据？ | §7 故障恢复全流程 |
| `system.replicas` 里 `is_readonly` / `is_stale` / `absolute_delay` 怎么读？ | §8 副本健康诊断 |

---

## 2. 核心原理：异步复制的设计权衡

### 2.1 为什么是异步而非同步

ClickHouse 的 `ReplicatedMergeTree` 采用**异步复制**：写入主副本后立即返回成功，其他副本从 Keeper 拉取日志异步同步。

```
同步复制（如 MySQL 半同步）:
Client → Replica1 → (等 Replica2 ACK) → 返回成功
优点: 强一致    缺点: Replica2 慢则写入阻塞，吞吐低

异步复制（ClickHouse）:
Client → Replica1 → 返回成功（不等其他副本）
         Replica1 → Keeper 写日志
         Replica2 ← Keeper 拉日志 → 同步
优点: 高吞吐、低延迟    缺点: 短暂不一致（Replica2 落后）
```

**为什么这样选**：ClickHouse 面向 OLAP 海量写入场景，同步复制会让写入吞吐被最慢的副本拖累。异步换吞吐是合理的架构权衡。短暂不一致对 OLAP 报表通常可接受（报表容忍秒级延迟）。

### 2.2 异步复制的语义保证

| 保证 | 说明 |
|------|------|
| **最终一致性** | 只要副本最终在线，数据最终会一致 |
| **不保证读后写一致** | 写到 Replica1，立刻从 Replica2 读可能读不到 |
| **不保证顺序一致** | 两个并发 INSERT 在不同副本的可见顺序可能不同 |
| **保证不丢数据** | 只要不删 Keeper 日志，副本恢复后能追上所有写入 |

**如果需要强一致**：用 quorum 写入 + sequential 读（§5），但有性能代价。

---

## 3. ReplicatedMergeTree 的 Keeper 路径模型

### 3.1 两个关键参数

```sql
CREATE TABLE repl_table (
    ...
) ENGINE = ReplicatedMergeTree(
    '/clickhouse/tables/{shard}/tutorial/repl_table',  -- ① ZooKeeper 路径
    '{replica}'                                         -- ② 副本名
);
```

| 参数 | 含义 | 示例 |
|------|------|------|
| `/path` | Keeper 中该表的协调节点根路径。**同一表的所有副本必须用相同 path** | `/clickhouse/tables/1/tutorial/repl_table` |
| `replica` | 本副本的标识，**同一 path 下各副本必须唯一** | `replica1`、`replica2` |

**`{shard}` / `{replica}` 是宏**，在 config.xml 的 `<macros>` 中定义，让每台节点自动替换：

```xml
<!-- clickhouse-server-1 -->
<macros>
    <shard>1</shard>
    <replica>replica1</replica>
</macros>
<!-- clickhouse-server-2 -->
<macros>
    <shard>1</shard>
    <replica>replica2</replica>
</macros>
```

### 3.2 Keeper 路径树结构

```
/clickhouse/tables/1/tutorial/repl_table/      ← 表的根路径
├── replicas/                                  ← 副本注册目录
│   ├── replica1/                              ← 副本1 的状态
│   │   ├── host                               ← 副本1 的 host:port
│   │   ├── pointer                            ← 当前消费到 log 的位置
│   │   ├── min_unprocessed_insert_time        ← 最早未处理 INSERT 时间
│   │   └── queue/                             ← 副本1 待处理的任务队列
│   └── replica2/                              ← 副本2 的状态
├── log/                                       ← INSERT/Merge 的日志序列
│   ├── log-0000000000                         ← 第 0 条日志
│   ├── log-0000000001
│   └── ...
├── mutations/                                 ← Mutation 任务日志
├── columns                                    ← 表结构元信息
└── metadata                                   ← 引擎参数等
```

**关键认知**：
- `log/` 是所有副本共享的"操作日志"，记录每个 INSERT 的 Part 信息和 Merge 任务
- 每个副本有独立的 `queue/`，记录自己还没处理的 log 项
- 副本从 `log/` 拉取新项到自己的 `queue/`，然后逐个执行

---

## 4. INSERT 复制全流程

### 4.1 单副本 INSERT 的完整链路

```
Client → INSERT INTO repl_table VALUES (...)
   │
   ▼ ① 接收副本（如 replica1）本地处理
   │   - 把数据写入本地 Part 文件（data.bin 等）
   │   - Part 生成成功
   │
   ▼ ② 写 Keeper log
   │   - 在 /log/ 下创建 log-0000123
   │   - 内容: {type: INSERT, source_replica: replica1, part_name: "202401_5_5_0", ...}
   │
   ▼ ③ 返回 Client 成功
   │   （不等其他副本同步！这是异步的关键点）
   │
   ▼ ④ 其他副本（replica2）异步拉取
   │   - replica2 的后台线程轮询 /log/，发现 log-0000123
   │   - 加入自己的 /replicas/replica2/queue/
   │
   ▼ ⑤ replica2 执行队列任务
   │   - 从 replica1 下载 Part 文件（HTTP 9000 端口）
   │   - 校验 Part 哈希
   │   - 注册到本地表，对查询可见
   │
   ▼ ⑥ 完成，replica2 数据与 replica1 一致
```

**复制延迟**：步骤 ④–⑥ 需要时间（通常毫秒到秒级），期间 replica2 查不到新数据。这就是 `absolute_delay`。

### 4.2 Merge 的协调

Merge（合并 Part）也需要跨副本协调，否则各副本各自合并会产生不同的 Part，导致不一致：

```
① 任一副本（如 replica1）发现需要 Merge（Part 数超过阈值）
② replica1 在 Keeper /log/ 写 Merge 任务: {type: MERGE, parts: [A, B] → C}
③ 所有副本读到此任务，各自本地执行相同 Merge
   - replica1: 本地合并 A+B → C
   - replica2: 本地合并 A+B → C
④ 结果: 两副本产生相同的新 Part C，删除旧的 A、B
```

**关键**：Merge 任务由 Keeper 协调，确保所有副本执行**相同的合并**，产生**相同的 Part**（同名同内容）。这是 `ReplicatedMergeTree` 与普通 `MergeTree` 的核心区别。

---

## 5. Quorum 写入与强一致读

### 5.1 默认行为的"漏洞"

默认 `insert_quorum = 0`（不要求 quorum）：
- 写到 Replica1 立即返回成功
- Replica1 宕机时，Replica2 可能还没同步到这条数据 → **数据丢失风险**

### 5.2 insert_quorum：写入多数派

```sql
SET insert_quorum = 2;        -- 要求至少 2 个副本确认写入
SET insert_quorum_timeout = 60000;  -- 等 quorum 超时 60s

INSERT INTO repl_table VALUES (...);
-- 流程: 写 Replica1 → 等 Replica2 同步 → 都成功才返回
-- 若 60s 内 Replica2 没同步 → INSERT 失败
```

**语义**：`insert_quorum = N` 意味着写入必须等到 N 个副本都有该数据才返回成功。

| 副本数 | insert_quorum 推荐 | 容错 |
|--------|-------------------|------|
| 2 | 2（或 1） | quorum=2 防单点丢数据；quorum=1 退化为纯异步 |
| 3 | 2 | 允许 1 个副本宕机仍能成功写入 |
| 3 | 3 | 最强一致，但任一副本宕机就写不进，可用性差 |

### 5.3 select_sequential_consistency：强一致读

```sql
SET select_sequential_consistency = 1;
SELECT * FROM repl_table WHERE ...;
-- 流程: 先查 Keeper 该副本是否已同步到最新 log
--       若落后则报错或等待，保证读到的是"最新已确认写入"
```

**配合 quorum 用**：
- `insert_quorum = 2` + `select_sequential_consistency = 1` → 实现"读已提交"语义
- 代价：每次 SELECT 多一次 Keeper 查询，性能下降

**何时用**：仅对一致性要求极高的场景（如金融对账）。普通报表别开，性能损失大。

### 5.4 quorum 的代价

| 维度 | 默认（quorum=0） | quorum=2 |
|------|------------------|----------|
| 写入延迟 | 低（不等其他副本） | 高（等最慢副本） |
| 写入吞吐 | 高 | 低（被最慢副本限制） |
| 一致性 | 最终一致 | 写入多数派一致 |
| 可用性 | 高（单副本可写） | 中（需多数副本在线） |

**生产建议**：90% 场景用默认异步即可。只有"写丢一条数据就出大事"的场景才开 quorum。

---

## 6. Keeper 容错与 Raft

### 6.1 Keeper 的角色

ClickHouse Keeper（或 ZooKeeper）是复制的"协调中枢"：
- 存储 `log/`（操作日志）
- 存储副本状态（`/replicas/`）
- 分配 Merge 任务
- **不存储实际数据**（数据在 ClickHouse 节点间直接传输）

### 6.2 Raft 多数派容错

Keeper 集群用 Raft 协议，需要**多数派**（majority）在线才能工作：

| Keeper 节点数 | 容错 | 可用 Keeper 数 |
|---------------|------|----------------|
| 1 | 0（单点） | 1 |
| 3 | **1**（推荐最小） | 2 |
| 5 | 2 | 3 |
| 7 | 3 | 4 |

**`treasurycluster` 配置 3 个 Keeper** → 可容忍 1 个 Keeper 宕机。

**Keeper 挂 1 个（3 节点集群）**：剩余 2 个构成多数派，继续工作，复制正常。
**Keeper 挂 2 个（3 节点集群）**：只剩 1 个，无法构成多数派，复制**停止**（INSERT 会失败或阻塞，但已写入数据仍可读）。

### 6.3 Keeper 故障的影响

| Keeper 状态 | ClickHouse 影响 |
|-------------|----------------|
| 全部在线 | 正常 |
| 少数派宕机（如 3 中挂 1） | 无影响，复制继续 |
| 多数派宕机（如 3 中挂 2） | 新 INSERT 失败；已有数据查询正常；Merge 停止 |
| 全部宕机 | 新 INSERT 失败；ReplicatedMergeTree 表变为 readonly；普通 MergeTree 表不受影响 |

**关键**：Keeper 全挂时，**已落盘的数据不丢、可查**，只是不能写新数据。这是因为数据在 ClickHouse 本地磁盘，Keeper 只管协调。

---

## 7. 故障恢复全流程

### 7.1 副本故障恢复

```
① replica2 宕机
   - replica1 继续接收 INSERT，写 Keeper log
   - replica2 的 queue 在 Keeper 中累积（不消失）

② replica2 恢复上线
   - 读取 Keeper 中自己的 queue
   - 发现落后 N 条 log
   - 逐条执行:
     a. INSERT log → 从 replica1 下载对应 Part
     b. MERGE log → 本地执行合并
   - 追上 replica1 的 pointer

③ 恢复完成，两副本一致
```

**追赶速度**：取决于落后量和网络带宽。大量落后时，下载 Part 可能占用较多带宽和磁盘 I/O。

### 7.2 Keeper 故障恢复

```
① 3 个 Keeper 挂了 2 个 → 复制停止
② 修复并重启 1 个 Keeper → 现有 2 个在线，构成多数派
③ Keeper 集群自动重新选主，恢复服务
④ ClickHouse 检测到 Keeper 恢复，复制队列继续处理
```

### 7.3 副本数据损坏修复

如果某副本磁盘损坏，数据丢失：
```sql
-- 1. 删除损坏的副本表
DROP TABLE repl_table;  -- 只删本地，不影响 Keeper 元数据

-- 2. 重新创建（用相同 path 和新 replica 名，或相同名）
CREATE TABLE repl_table (...) ENGINE = ReplicatedMergeTree('/path', 'replica2') ...;

-- 3. ClickHouse 自动从其他副本同步全量数据
--    （通过 Keeper 发现本地无数据，触发全量拉取）
```

---

## 8. 副本健康诊断

### 8.1 system.replicas 关键字段

```sql
SELECT
    database, table, replica_name,
    is_readonly,           -- 1 = 只读（Keeper 不可用或手动设置）
    is_stale,              -- 1 = 落后于其他副本（absolute_delay 大）
    absolute_delay,        -- 落后秒数（关键监控指标！）
    queue_size,            -- 待处理任务数
    inserts_in_queue,      -- 待同步 INSERT 数
    merges_in_queue,       -- 待执行 Merge 数
    total_replicas,        -- 集群配置的副本总数
    active_replicas,       -- 在线副本数
    last_queue_update      -- 最后一次队列更新时间
FROM system.replicas
WHERE database = 'tutorial';
```

### 8.2 诊断决策表

| 症状 | 含义 | 处理 |
|------|------|------|
| `absolute_delay = 0` | 副本已同步 | 健康 |
| `absolute_delay` 持续增大 | 副本跟不上写入速度 | 检查网络、磁盘 I/O、Keeper 连接 |
| `is_readonly = 1` | 副本只读 | 检查 Keeper 是否可用、是否被设为 readonly |
| `is_stale = 1` | 副本落后 | 同上，看 `absolute_delay` |
| `queue_size` 持续增大 | 任务积压 | 副本处理速度慢，可能磁盘满或 CPU 不足 |
| `active_replicas < total_replicas` | 有副本离线 | 检查离线副本节点 |
| `last_queue_update` 很久没更新 | 副本与 Keeper 失联 | 检查网络、Keeper 健康 |

### 8.3 system.replication_queue

```sql
-- 查看具体积压了哪些任务
SELECT
    database, table, replica_name,
    type,                  -- INSERT / MERGE / MUTATION
    create_time,
    num_tries,             -- 重试次数（多次失败可能有问题）
    last_exception         -- 最后一次错误信息
FROM system.replication_queue
ORDER BY create_time
LIMIT 20;
```

### 8.4 监控告警建议

| 指标 | 告警阈值 |
|------|----------|
| `absolute_delay` | > 60s 警告，> 300s 严重 |
| `queue_size` | > 100 警告，> 1000 严重 |
| `is_readonly = 1` | 严重（立即） |
| `active_replicas < total_replicas` | 警告 |
| `num_tries > 10` | 警告（任务反复失败） |

---

## 9. 常见误区与最佳实践

### 误区
1. **"副本间是强一致的"** → 错。异步复制，默认最终一致。
2. **"副本越多写入越快"** → 错。副本多反而增加 Keeper 协调开销和存储成本。
3. **"Keeper 存数据"** → 错。Keeper 只存协调元数据，数据在 ClickHouse 节点。
4. **"insert_quorum = 副本数 最安全"** → 不一定。任一副本宕机就写不进，可用性差。
5. **"副本故障时数据会丢"** → 错。只要 Keeper log 在，恢复后能追回。
6. **"ReplicatedMergeTree 比 MergeTree 慢很多"** → 写入稍慢（Keeper 开销），查询一样。

### 最佳实践
1. **生产必用 ReplicatedMergeTree**：普通 MergeTree 无副本，单点故障丢数据
2. **2 副本 + 3 Keeper 是最小生产配置**：容忍 1 节点 + 1 Keeper 故障
3. **默认异步复制**：除非强一致需求，否则别开 quorum
4. **监控 `absolute_delay`**：核心健康指标
5. **Keeper 独立部署**：不要和 ClickHouse 抢资源
6. **Keeper 用 SSD**：Keeper 对磁盘 I/O 敏感
7. **副本数不超过 3**：更多副本收益递减，成本增加

---

## 10. 自测题

1. ClickHouse 为什么选异步复制而非同步？代价是什么？
2. `ReplicatedMergeTree('/path', 'replica1')` 的两个参数，同一表的不同副本各该怎么填？
3. INSERT 到 replica1 后立刻从 replica2 查，查不到，是 bug 吗？怎么解决？
4. `insert_quorum = 2` 在 2 副本集群中，如果 1 副本宕机，INSERT 会怎样？
5. 3 个 Keeper 挂了 2 个，ClickHouse 还能写吗？能查吗？为什么？
6. `absolute_delay = 300` 意味着什么？可能的原因？
7. 副本磁盘损坏数据丢失，如何从其他副本恢复？

答案线索均在本 README 及 [08_sharding.sql](./08_sharding.sql) 中。

---

## 11. 关联章节

- [08_sharding.sql](./08_sharding.sql) —— ReplicatedMergeTree 创建与副本状态查询实战
- [README.md](./README.md) —— ClickHouse 整体架构与 Keeper 角色
- [03_mergetree.sql](./03_mergetree.sql) —— MergeTree 家族（含 ReplicatedMergeTree）
- [06-admin](../06-admin/README.md) —— 集群管理与故障处理

---

## 12. 参考资源

- [ReplicatedMergeTree 文档](https://clickhouse.com/docs/en/engines/table-engines/mergetree-family/replication)
- [ClickHouse Keeper](https://clickhouse.com/docs/en/operations/clickhouse-keeper)
- [system.replicas](https://clickhouse.com/docs/en/operations/system-tables/replicas)
- [Quorum 写入](https://clickhouse.com/docs/en/operations/settings/settings#insert_quorum)
- [复制架构](https://clickhouse.com/docs/en/architecture/replication)
