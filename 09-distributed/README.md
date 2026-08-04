# 分布式架构深度教程

> 本章回答 ClickHouse 分布式架构中的核心难题：**分片怎么分才均匀？副本怎么配才高可用？Keeper Raft 如何协调？两阶段聚合如何工作？GLOBAL JOIN 为什么慢？分布式 DDL 为什么部分失败？** 读完本章，你应能：设计合理分片键、部署高可用复制集群、排查分布式查询性能瓶颈、诊断跨集群 DDL 故障。
>
> 配套可运行 SQL：7 个文件（01_keeper_internals ~ 07_global_join）。集群：`treasurycluster`（CH 25.12.1.649，2 副本 × 1 分片，3 Keeper）。

---

## 本章解决什么问题（10+ 痛点）

| 痛点 | 本章如何解答 |
|------|-------------|
| 分布式表的分片键到底怎么选？rand() / cityHash64 / xxHash64 有什么区别？ | 05_sharding_key_design.sql — 均匀性实验对比 |
| 副本怎么配？ReplicatedMergeTree 复制机制是什么？ | 02_replication_decisions.sql — 复制队列与 quorum |
| Keeper Raft 怎么工作？Leader 选举、日志复制、快照是什么？ | 01_keeper_internals.sql — Raft 状态机全解析 |
| 两阶段聚合（sumState / sumMerge）是什么原理？为什么 avg 需要特殊处理？ | 06_two_phase_aggregation.sql — 两阶段聚合手把手实验 |
| GLOBAL JOIN 为什么慢？什么时候该用？ | 07_global_join.sql — 广播 vs 本地 JOIN 对比 |
| ON CLUSTER DDL 部分节点失败怎么办？ | 04_cross_cluster_ddl.sql — DDL 队列监控与故障处理 |
| 分布式表查询时 WHERE 条件能裁剪到单个分片吗？ | 03_distributed_table.sql — 分片键路由与查询裁剪 |
| 分片数越多越好吗？怎么规划？ | 05_sharding_key_design.sql — 分片数规划误区 |
| 跨地域复制有什么挑战？ | 02_replication_decisions.sql — 跨地域复制限制 |
| 分布式 JOIN 中的 IN 子查询为什么慢？ | 07_global_join.sql — GLOBAL IN 替代方案 |
| 分布式表写入时数据会直接写到远程节点吗？ | 03_distributed_table.sql — 本地写入 vs 远程写入 |
| 如何诊断分布式查询性能瓶颈？ | 06_two_phase_aggregation.sql — 优化器与谓词下推 |

---

## 分布式架构全景图

```
┌─────────────────────────────────────────────────────────────────────┐
│                          Client                                      │
│                            │                                          │
│                            ▼                                          │
│              ┌──────────────────────────────┐                       │
│              │      Distributed Table       │                       │
│              │     (查询路由层，不存数据)     │                       │
│              │  分片键: cityHash64(x) % N   │                       │
│              └──────────┬───────────────────┘                       │
│                         │                                             │
│         ┌───────────────┼───────────────┐                             │
│         ▼               ▼               ▼                             │
│   ┌──────────┐    ┌──────────┐    ┌──────────┐                      │
│   │ Shard 1  │    │ Shard 2  │    │ Shard N  │  ← 水平分片           │
│   │ 数据子集  │    │ 数据子集  │    │ 数据子集  │                      │
│   └────┬─────┘    └────┬─────┘    └────┬─────┘                      │
│        │               │               │                              │
│        ▼               ▼               ▼                              │
│   ┌──────────┐    ┌──────────┐    ┌──────────┐                      │
│   │ Replica1 │    │ Replica1 │    │ Replica1 │  ← 副本（数据冗余）    │
│   │ Replica2 │    │ Replica2 │    │ Replica2 │                       │
│   └──────────┘    └──────────┘    └──────────┘                      │
│        │               │               │                              │
│        └───────────────┼───────────────┘                              │
│                        │                                              │
│                        ▼                                              │
│              ┌──────────────────────┐                                │
│              │  Keeper Ensemble     │                                │
│              │  (Raft 共识集群)      │                                │
│              │  ┌───┐ ┌───┐ ┌───┐  │                                │
│              │  │K1 │ │K2 │ │K3 │  │  ← 3 节点多数派                 │
│              │  └───┘ └───┘ └───┘  │                                │
│              └──────────────────────┘                                │
└─────────────────────────────────────────────────────────────────────┘

数据流:
  INSERT → Distributed Table → Sharding Key Hash → 目标分片
                                                      → ReplicatedMergeTree 写入本地 Part
                                                      → Keeper 写 log → 副本异步拉取

查询流:
  SELECT → Distributed Table → 并行发往所有分片
                                 → 各分片两阶段聚合（sumState / sumMerge）
                                 → 协调节点合并结果 → 返回 Client
```

---

## 核心原理详解

### 1. 两阶段聚合（Two-Phase Aggregation）

分布式聚合查询不是简单地在各分片执行相同 SQL，而是拆分为两阶段：

```
第一阶段（Partial）: 每个分片执行 sumState / countState / uniqState 等
  → 产生中间聚合状态（不返回原始数据）
第二阶段（Merge）: 协调节点执行 sumMerge / countMerge / uniqMerge
  → 合并各分片的状态，输出最终结果

为什么需要 State 函数？
  - sum(amount) 可以拆分为 sumState → sumMerge，因为和是可交换可结合的
  - avg(amount) 不能直接拆，因为 avg(avg) ≠ 全局 avg
  - 解决方案：avgState 返回 {sum, count} 二元组，avgMerge 计算 sum/count

为什么 uniq 需要特殊处理？
  - uniq 使用 HyperLogLog 算法，状态是一组哈希桶
  - uniqState 产生 HLL 状态，uniqMerge 合并 HLL 状态
  - 而不是简单地对各分片 uniq 结果求和（会重复计算）
```

### 2. GLOBAL JOIN 广播原理

普通 JOIN 在分布式表上执行时，每个分片只看到本地数据，导致数据缺失：

```
普通 JOIN（错误）:
  1. 协调节点把查询发到所有分片
  2. 每个分片用本地右表 JOIN → 只看到本地右表数据
  3. 结果缺失（右表数据分散在各分片）

GLOBAL JOIN（正确）:
  1. 协调节点查询右表，获取完整数据
  2. 将完整右表广播到所有分片（临时表）
  3. 每个分片用完整右表 JOIN → 结果正确

为什么慢？
  - 右表数据要从各分片收集到协调节点
  - 再从协调节点广播到所有分片
  - 网络传输量 = 右表大小 × 分片数
  - 右表越大，性能越差
```

### 3. 分片键 Hash 路由

```
Distributed 表的分片键路由:
  目标分片 = cityHash64(sharding_key) % 分片总数

  - 返回值范围: 0 到 分片总数-1
  - 每个分片在 system.clusters 中有 shard_num
  - 路由映射: hash % N → 按 shard_num 排序后的第 N 个分片

常见分片键:
  - rand(): 随机路由，均匀但无本地性
  - cityHash64(user_id): 按用户哈希，均匀且相同用户在同一分片
  - xxHash64(event_id): 高性能哈希，适合高吞吐
  - 直接取模: intHash64(user_id) % N，人为控制分布

重要：分片键在 INSERT 时计算，决定了数据在哪个分片落地
      查询时 WHERE 条件若包含分片键，可裁剪到单个分片
```

### 4. Keeper Raft 原理

ClickHouse Keeper 用 Raft 共识协议替代 ZooKeeper：

```
Raft 三个角色:
  - Leader: 处理所有写请求，管理日志复制
  - Follower: 被动复制日志，处理读请求
  - Candidate: Leader 选举时的临时角色

Raft 工作流程（写请求）:
  1. Client → Leader 提交写请求
  2. Leader 追加日志条目 → 并行复制到所有 Follower
  3. 多数 Follower 确认写入 → Leader 提交（commit）
  4. Leader 响应 Client → 通知 Follower 提交

日志压缩与快照:
  - 日志无限增长会占用大量空间
  - Keeper 定期创建快照（snapshot），压缩旧日志
  - 新节点加入时，先拉取快照再追增量日志
```

---

## 常见误区（10+ 条）

1. **"分片越多性能越好"** → 错。分片增加跨节点网络开销，协调节点聚合压力增大。建议分片数不超过节点数，2-8 分片适合大多数场景。

2. **"随机分片（rand()）数据最均匀"** → 不一定。rand() 在单次 INSERT 批量数据时可能扎堆到同一分片。推荐用高基数字段哈希。

3. **"副本越多越安全"** → 错。副本多增加存储成本、Keeper 协调开销。2 副本 + 3 Keeper 是最小生产配置。

4. **"GLOBAL JOIN 和普通 JOIN 一样快"** → 错。GLOBAL JOIN 需要广播右表，网络开销大。右表大时可能比普通 JOIN 慢 10 倍。

5. **"ON CLUSTER 在所有节点原子执行"** → 错。ON CLUSTER 是逐个节点广播，可能部分成功部分失败。需检查 DDL 队列。

6. **"分布式表查询自动走两阶段聚合"** → 不一定。某些聚合函数（如 groupArray）无法拆分，会触发生成查询到各分片获取原始数据。

7. **"分片键选时间字段就行"** → 错。时间字段通常基数低（如按月），导致数据倾斜。时间字段应作为分区键而非分片键。

8. **"Keeper 挂了 ClickHouse 就不能查了"** → 错。Keeper 挂了只影响写入和复制，已落盘数据仍可查询。

9. **"两阶段聚合自动优化所有查询"** → 错。需要设置 `enable_optimize_predicate` 等参数，且某些查询模式无法优化。

10. **"Distributed 表写入直接写到远程节点"** → 不一定。默认先将数据写入本地，后台线程异步发送到目标分片。可通过 `insert_distributed_sync` 控制。

11. **"跨地域复制和同机房一样可靠"** → 错。跨地域网络延迟高、带宽有限，复制延迟可能达到分钟级甚至小时级。

12. **"uniq 在分布式下直接 sum(uniq) 就行"** → 错。uniq 用 HyperLogLog，直接求和会重复计算跨分片的相同值。必须用 uniqState + uniqMerge。

---

## 最佳实践（10+ 条）

1. **分片键优先选高基数字段**：如 `user_id`、`order_id`、`device_id`，用 `cityHash64()` 取哈希。

2. **分片数 = 2^n**：便于增减分片时数据迁移，常见 2/4/8。

3. **生产环境必用 ReplicatedMergeTree**：单副本的 MergeTree 在节点故障时数据不可恢复。

4. **2 副本 + 3 Keeper**：最小生产配置，容忍 1 节点 + 1 Keeper 故障。

5. **GLOBAL JOIN 只用于右表小**：右表行数 < 100 万或单表体积 < 1GB，否则用字典或物化视图替代。

6. **分布式 DDL 用 `ON CLUSTER ... SYNC`**：`SYNC` 等待所有节点执行完成，提前发现失败。

7. **监控 `system.replicas.absolute_delay`**：核心复制健康指标，持续 > 60s 需排查。

8. **两阶段聚合配套设置**：`SET enable_optimize_predicate = 1`，`SET prefer_localhost_replica = 0`。

9. **避免在分布式表上执行复杂 GROUP BY**：中间结果量大会压垮协调节点内存。用 `max_bytes_before_external_group_by` 控制。

10. **Keeper 独立部署 + SSD**：Keeper 对磁盘 I/O 敏感，不要和 ClickHouse 争抢资源。

11. **分片键均匀性实验**：正式上线前用 `SELECT cityHash64(shard_key) % N, count() FROM ... GROUP BY 1` 验证分布。

12. **分布式表命名约定**：`{db}_{table}_all` 或 `{db}_{table}_dist`，区别于本地表。

---

## 文件导航表

| 文件 | 主题 | 核心内容 |
|------|------|---------|
| [01_keeper_internals.sql](./01_keeper_internals.sql) | Keeper 内部原理 | Raft 选举、日志复制、快照、配置优化、Keeper vs ZooKeeper |
| [02_replication_decisions.sql](./02_replication_decisions.sql) | 复制决策 | 复制队列监控、Quorum 配置、选型决策、跨地域复制 |
| [03_distributed_table.sql](./03_distributed_table.sql) | 分布式表深度 | 路由原理、分片键验证、读写流程、监控、DDL 语法 |
| [04_cross_cluster_ddl.sql](./04_cross_cluster_ddl.sql) | 跨集群 DDL | ON CLUSTER 原理、失败处理、DDL 队列监控、安全实践 |
| [05_sharding_key_design.sql](./05_sharding_key_design.sql) | 分片键设计 | 选择原则、均匀性实验、热点诊断、分片数规划 |
| [06_two_phase_aggregation.sql](./06_two_phase_aggregation.sql) | 两阶段聚合 | State/Merge 函数、avg/uniq/quantile 特殊处理、优化配置 |
| [07_global_join.sql](./07_global_join.sql) | GLOBAL JOIN 原理 | 普通 JOIN vs GLOBAL JOIN、GLOBAL IN、性能对比、最佳实践 |

---

## 自测题（10+ 道）

1. **分片键**：`cityHash64(user_id)` 和 `rand()` 作为分片键有什么区别？在什么场景下 `rand()` 更好？

2. **两阶段聚合**：为什么 `avg(amount)` 在分布式下不能直接对各分片结果求平均？ClickHouse 如何解决？

3. **GLOBAL JOIN**：一个 10 分片集群，右表 1000 万行，用 GLOBAL JOIN 会有什么问题？怎么优化？

4. **Keeper Raft**：3 节点 Keeper 集群，如果 1 个节点宕机后恢复，恢复过程中 ClickHouse 复制会中断吗？

5. **复制**：`insert_quorum = 2` 在 2 副本集群中，如果 1 副本宕机，INSERT 会怎样？`insert_quorum_timeout` 过期后呢？

6. **分布式 DDL**：`ON CLUSTER` 执行 `DROP TABLE`，如果 1 个节点失败，数据会怎样？如何修复？

7. **分片数规划**：一个 10 节点集群，数据量 100TB，分片数设多少合适？为什么？

8. **查询裁剪**：分片键为 `cityHash64(user_id)`，查询 `WHERE user_id = 123` 能裁剪到单个分片吗？`WHERE user_id IN (1,2,3)` 呢？

9. **uniq 分布式**：`SELECT uniq(user_id) FROM distributed_table` 在分布式下如何执行？如果直接 `SELECT sum(uniq(user_id))` 会有什么问题？

10. **两阶段聚合优化**：`SET enable_optimize_predicate = 1` 对分布式查询有什么影响？什么情况下这个设置无效？

11. **Keeper vs ZooKeeper**：ClickHouse 为什么从 ZooKeeper 迁移到 Keeper？Keeper 有哪些优势？

12. **跨地域复制**：北京和上海两个机房，各部署 ClickHouse 集群，如何实现跨地域数据同步？ReplicatedMergeTree 直接跨地域用有什么问题？

---

## 如何阅读本章

1. **初学者**：按编号顺序阅读（01 → 07），每个 SQL 文件都包含可运行的实验
2. **有经验者**：直接跳到感兴趣的主题，每个文件独立可运行
3. **DBA/运维**：重点关注 01_keeper_internals、02_replication_decisions、04_cross_cluster_ddl
4. **架构师**：重点关注 05_sharding_key_design、06_two_phase_aggregation、07_global_join

所有 SQL 文件以 `DROP DATABASE IF EXISTS distributed_test; CREATE DATABASE distributed_test; USE distributed_test;` 开头，以 `DROP DATABASE IF EXISTS distributed_test;` 结尾，可独立运行。

---

## 关联章节

- [00-infra/README.md](../00-infra/README.md) — 集群基础设施与 Docker Compose 部署
- [16-principle/07_replication.md](../16-principle/07_replication.md) — 复制原理（专家级详解）
- [16-principle/08_sharding.sql](../16-principle/08_sharding.sql) — 分片实战 SQL
- [01-getting-started/05_cluster_concepts.sql](../01-getting-started/05_cluster_concepts.sql) — 集群基础概念
- [01-getting-started/09_distributed_tables.sql](../01-getting-started/09_distributed_tables.sql) — 分布式表入门

---

## 参考资源

- [ClickHouse Distributed Table](https://clickhouse.com/docs/en/engines/table-engines/special/distributed)
- [ClickHouse Keeper](https://clickhouse.com/docs/en/operations/clickhouse-keeper)
- [ReplicatedMergeTree](https://clickhouse.com/docs/en/engines/table-engines/mergetree-family/replication)
- [GLOBAL JOIN](https://clickhouse.com/docs/en/sql-reference/statements/select/join#global-join)
- [两阶段聚合](https://clickhouse.com/docs/en/engines/table-engines/mergetree-family/aggregatingmergetree)
- [system.clusters](https://clickhouse.com/docs/en/operations/system-tables/clusters)