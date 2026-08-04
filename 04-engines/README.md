# ClickHouse 表引擎（专家级详解）

> 本章是 ClickHouse 的"存储层核心"。表引擎决定了数据如何写入、如何合并、如何压缩、能否去重、能否复制、查询走什么索引。读完本章，你应能：根据业务场景精准选引擎、理解 MergeTree 家族的 Part 合并算法差异、识别"去重不实时""折叠 sign""聚合状态"等反直觉设计的本质、避免常见的引擎误用陷阱。
>
> 配套可运行 SQL：[01_mergetree_engines.sql](./01_mergetree_engines.sql)、[02_replicated_engines.sql](./02_replicated_engines.sql)、[03_log_engines.sql](./03_log_engines.sql)、[04_integration_engines.sql](./04_integration_engines.sql)、[05_special_engines.sql](./05_special_engines.sql)。集群已启动（`treasurycluster`，1 分片 2 副本，CH 25.12.1.649），所有 SQL 均已集群验证零错误。

---

## 1. 本章解决什么问题（Why）

ClickHouse 的表引擎体系庞大（40+ 引擎），且有几个"反直觉"设计，是新手踩坑高发区：

| 痛点 | 本章如何解答 |
|------|--------------|
| `ReplacingMergeTree` 写完查询还是有重复行？ | §3.2 讲透"去重只在 merge 时发生，merge 是后台异步的"，必须 `FINAL` 或 `OPTIMIZE` |
| `ReplacingMergeTree` 和 `DISTINCT` 哪个去重好？ | §3.2 对比表：适用场景、性能、语义全维度对比 |
| `SummingMergeTree` 为什么非数值列"消失"了？ | §3.3 讲透"非排序键的非数值列取第一个 part 的值" |
| `AggregatingMergeTree` 为什么必须配 `*State` 函数？ | §3.4 讲透"AggregateFunction 状态合并"机制 |
| `CollapsingMergeTree` 的 `sign` 到底怎么"折叠"？为什么查出来还是没折叠？ | §3.5 讲透"+1/-1 折叠算法"，以及查询时必须 `GROUP BY sum(col*sign)` |
| `VersionedCollapsingMergeTree` 解决了 `CollapsingMergeTree` 的什么缺陷？ | §3.6 讲透"乱序写入导致 sign 无法配对"问题 |
| 生产到底用 `MergeTree` 还是 `ReplicatedMergeTree`？ | §3.7 讲透复制机制 + Keeper 协调 |
| `Distributed` 表存数据吗？分片键怎么选？ | §3.8 讲透"路由层不存数据" + 分片键设计 |
| 物化视图什么时候触发？能不能改？ | §3.9 讲透"INSERT 触发，非实时，非 UPDATE 触发" |
| Log 系列三个引擎到底差在哪？为什么生产不用？ | §3.10 讲透存储结构差异 |
| `Buffer` 表会丢数据吗？什么时候刷盘？ | §3.11 讲透"宕机会丢缓冲数据"风险 |

---

## 2. 引擎体系全景图与核心原理

### 2.1 引擎家族全景

```
┌────────────────────────────────────────────────────────────────────────┐
│                        ClickHouse 表引擎体系                              │
├────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  ① MergeTree 家族（绝对主力，95% 生产场景）                              │
│     ├─ MergeTree                  基础引擎：Part + 稀疏索引 + 后台 merge │
│     ├─ ReplacingMergeTree         去重：同主键保留 version 最大/最新      │
│     ├─ SummingMergeTree           求和：同主键数值列 SUM                  │
│     ├─ AggregatingMergeTree       聚合状态：AggregateFunction 列自动 merge│
│     ├─ CollapsingMergeTree        折叠：sign(+1/-1) 配对抵消              │
│     ├─ VersionedCollapsingMergeTree 版本折叠：解决乱序写入                 │
│     └─ GraphiteMergeTree          Graphite 时序专用                       │
│     ↑ 上述每个都有 Replicated* 复制版（生产标配）                          │
│                                                                         │
│  ② Log 家族（小数据/临时，无索引无分区）                                   │
│     ├─ TinyLog     每列独立文件，无并发读                                  │
│     ├─ StripeLog  单文件条带存储，带压缩                                   │
│     └─ Log        列式 + 标记文件，支持并发读                              │
│                                                                         │
│  ③ 集成引擎（外部数据源联邦查询）                                          │
│     ├─ URL / File / S3 / HDFS         文件/对象存储                       │
│     ├─ MySQL / PostgreSQL / MongoDB  关系/文档库                          │
│     ├─ Redis / Kafka                 缓存/消息流                          │
│     └─ JDBC / ODBC                   通用驱动                            │
│                                                                         │
│  ④ 特殊引擎（特定用途）                                                   │
│     ├─ Distributed       分布式路由层（不存数据）                          │
│     ├─ MaterializedView  物化视图（INSERT 触发预聚合）                    │
│     ├─ View              普通视图（仅 SQL 别名）                          │
│     ├─ Dictionary        字典（内存 KV 查找）                            │
│     ├─ Buffer            写入缓冲（合并小批量）                            │
│     ├─ Merge             多表合并查询                                      │
│     ├─ Null              黑洞（丢弃写入，用于测试/审计）                   │
│     ├─ Set / Join        内存集合/连接表                                   │
│     └─ Memory            纯内存表                                         │
│                                                                         │
└────────────────────────────────────────────────────────────────────────┘
```

### 2.2 核心原理：MergeTree 的 Part 与后台合并（必读）

MergeTree 是 ClickHouse 的灵魂。理解 Part 和 merge 机制是理解整个引擎家族的前提。

```
INSERT 一批数据 (一个 Block, 默认 1 个 part)
       │
       ▼
┌─────────────────────────────────────────────────────────┐
│  Part (磁盘上的数据块，不可变 immutable)                  │
│  ├── 数据文件 (列式压缩存储 .bin)                        │
│  ├── 稀疏主键索引 (每 index_granularity=8192 行存一个)    │
│  ├── 跳数索引 (minmax/bloom_filter/set 等)               │
│  ├── 分区键标记文件 (.mrk2)                              │
│  └── 校验文件 (.cidx)                                   │
└─────────────────────────────────────────────────────────┘
       │
       │  后台 merge 线程 (background_schedule_pool)
       │  选择策略：分区内部选择 2+ 个 part 合并成更大的 part
       │
       ▼
┌─────────────────────────────────────────────────────────┐
│  合并后的大 Part                                         │
│  ├── 旧 part 标记 inactive，待后台清理                    │
│  └── 同一 ORDER BY 主键的数据被重新排序合并               │
└─────────────────────────────────────────────────────────┘
       │
       │  继续合并直到达到 max_part_size (默认 150GB)
       ▼
   大 Part 不再合并 (除非达到 TTL/OPTIMIZE 触发)
```

**关键概念**：
- **Part 不可变**：一旦写入磁盘就不会修改，只能被合并成新 part（旧 part 标记 inactive 后清理）
- **稀疏索引**：每 8192 行才存一个主键值，索引极小可全放内存。代价是"点查"需扫一个 granule（8192 行），故 ClickHouse 不擅长点查
- **后台 merge**：异步进行，不会阻塞写入。但 merge 速度跟不上写入速度时，part 数量爆炸导致查询变慢
- **分区**：分区是物理目录隔离，**只在分区内 merge**。跨分区不会合并。分区是分区剪枝的物理基础
- **ORDER BY**：决定数据在 part 内的物理排序，是稀疏索引的依据。**查询的 WHERE 条件最好是 ORDER BY 前缀**

### 2.3 MergeTree 家族合并算法差异（核心对比）

```
基础 MergeTree merge:
  part1 + part2 ──> new_part
  行为：仅排序合并，不去重、不聚合、不折叠
  适用：明细表（append-only）

ReplacingMergeTree merge:
  part1 + part2 ──> 排序 + 同主键保留 version 最大 ──> new_part
  关键：去重发生在 merge 时，不是写入时
  时机：merge 异步，查询时数据可能仍有重复 → 需 FINAL

SummingMergeTree merge:
  part1 + part2 ──> 排序 + 同主键数值列 SUM + 非数值列取首行 ──> new_part
  关键：只对"非排序键且数值类型"的列求和
  注意：非数值列（如 String）取 part 中第一行的值，可能"丢失"

AggregatingMergeTree merge:
  part1 + part2 ──> 排序 + 同主键 AggregateFunction 列 merge ──> new_part
  关键：列必须是 AggregateFunction(...) 类型
  配合：写入用 *State，查询用 *Merge
  优势：可继续聚合（日→月→年无损）

CollapsingMergeTree merge:
  part1 + part2 ──> 排序 + 同主键 sign(+1) 与 sign(-1) 配对抵消 ──> new_part
  关键：要求"先 +1 后 -1"的写入顺序
  坑：乱序写入导致 sign 无法配对，折叠失败 → 用 VersionedCollapsingMergeTree

VersionedCollapsingMergeTree merge:
  part1 + part2 ──> 排序 + 按 version 排序后再 sign 抵消 ──> new_part
  关键：用 version 字段保证折叠顺序正确
  优势：容忍乱序写入
```

---

## 3. 关键概念逐个讲透（原理 + 场景 + 对比 + 决策表）

### 3.1 MergeTree 基础引擎

**原理**：见 §2.2。基础引擎不做任何数据变换，只做排序合并。

**场景**：append-only 明细表（事件日志、埋点数据、订单流水）。绝大多数生产表的默认选择。

**核心配置**：
- `PARTITION BY`：分区键，建议按时间（`toYYYYMM`）。**分区不是越细越好**——按天分区会导致分区数爆炸，每个分区至少一个 part，merge 调度压力大。经验：单表分区总数控制在 1000 以内
- `ORDER BY`：排序键，决定稀疏索引。**前缀匹配查询才走索引**，所以高频过滤条件放前面
- `SETTINGS index_granularity`：稀疏索引粒度，默认 8192。点查多可调小（如 1024），范围扫描保持默认
- `SETTINGS ttl`：自动过期清理，比手动删分区更优雅

**对比**：
| 维度 | MergeTree | ReplacingMergeTree | SummingMergeTree |
|------|-----------|--------------------|-------------------|
| 写入后行数 | 不变 | merge 时减少（去重） | merge 时减少（聚合） |
| 适用 | 明细 append | 状态表（最新值） | 数值预聚合 |
| 查询是否需 FINAL | 否 | 是（要严格去重时） | 是（要严格聚合时） |

### 3.2 ReplacingMergeTree 去重引擎

**原理**：merge 时，对**相同的 ORDER BY 主键**的行，保留 `version` 列最大的（或最后写入的，若无 version）。**去重只在 merge 时发生**，merge 是后台异步的，所以查询时数据可能仍有重复。

```
INSERT 1: (user=1, state='online',  ver=1)
INSERT 2: (user=1, state='busy',   ver=2)  ← 同主键 user=1，version 更大
INSERT 3: (user=2, state='offline', ver=1)

此时查询（无 FINAL）：3 行（重复未消除）
  user=1, online, ver=1
  user=1, busy,   ver=2
  user=2, offline, ver=1

后台 merge 后 / SELECT ... FINAL：
  user=1, busy,   ver=2   ← ver=2 胜出，ver=1 被丢弃
  user=2, offline, ver=1
```

**去重时机**（关键误区）：
- 写入时：**不去重**
- 后台 merge 时：**会去重**，但 merge 是异步的，可能延迟几分钟到几小时
- `OPTIMIZE TABLE ... FINAL`：**强制触发 merge 去重**，但代价高（重写整个 part），生产慎用
- `SELECT ... FINAL`：**查询时去重**，读取所有 part 并在内存中合并，比 `OPTIMIZE` 轻量但仍比普通 SELECT 慢。25.x 起 FINAL 性能已大幅优化（支持 push-down），但仍非"零成本"

**与 DISTINCT 对比**：
| 维度 | ReplacingMergeTree + FINAL | SELECT DISTINCT |
|------|----------------------------|------------------|
| 去重依据 | ORDER BY 主键 | SELECT 列全部 |
| 时机 | merge 时去重（持久） | 查询时去重（不持久） |
| 跨 part | FINAL 在查询时合并 | 查询时合并 |
| 性能 | 大数据优势（已部分 merge） | 小数据灵活，大数据慢 |
| 适用 | 持续写入的状态表 | 一次性去重查询 |
| 版本选择 | 支持 version 列选最新 | 不支持，只能取任意一行 |

**最佳实践**：用 `ReplacingMergeTree(version)` 而非裸 `ReplacingMergeTree`，version 列让去重可预测。查询需严格去重时加 `FINAL`，否则用 `argMax` 等聚合函数自己取最新值。

### 3.3 SummingMergeTree 求和引擎

**原理**：merge 时，对**相同的 ORDER BY 主键**的行：
- **数值列**（非排序键）：自动 `SUM`
- **非数值列**（如 String）：取**第一个 part 的第一行值**（行为不可预测，是常见坑）
- **排序键列**：保留（因为是主键）

```
表结构: ORDER BY (date, product_id)
  date, product_id, country, amount, order_count
  ('2024-01-01', 101, 'US', 99.99, 1)
  ('2024-01-01', 101, 'UK', 50.00, 1)   ← 同主键 (date, product_id)
  ('2024-01-01', 101, 'US', 10.00, 1)   ← 同主键 (date, product_id)

merge 后：
  ('2024-01-01', 101, <country 取首行>, 159.99, 3)
                ↑ 'country' 是 String，取第一个 part 的第一行值（不可控！）
```

**场景**：数值累加预聚合（GMV、PV、订单数）。**不适用**于：需要保留维度列值的场景（如 country），这种情况应该把维度列也放进 ORDER BY。

**与 sumState + AggregatingMergeTree 对比**：
| 维度 | SummingMergeTree | AggregatingMergeTree + sumState |
|------|-------------------|----------------------------------|
| 支持聚合 | 仅 SUM | 任意（sum/uniq/quantile/max...） |
| 列类型 | 普通 Decimal/Int | AggregateFunction(Sum, Decimal) |
| 二级聚合 | 不可（已丢精度） | 可（日→月→年无损） |
| 复杂度 | 低 | 高（需 *State/*Merge） |
| 适用 | 简单累加 | 复杂聚合、多级聚合 |

**最佳实践**：能用 SummingMergeTree 解决的别用 AggregatingMergeTree（后者复杂）。但只要涉及 uniq/quantile/avg 等非可加聚合，必须用 AggregatingMergeTree + *State。

### 3.4 AggregatingMergeTree 聚合状态引擎

**原理**：merge 时，对**相同的 ORDER BY 主键**的行，将 `AggregateFunction(...)` 类型的列**合并状态**（不是简单求和，而是聚合状态二进制 merge）。

```
列定义: page_views AggregateFunction(count)
        distinct_pages AggregateFunction(uniq, String)

写入：必须用 *State 函数写入"状态"，不能写普通值
  INSERT ... SELECT countState() AS page_views ...
  ↑ countState() 返回二进制状态，不是数字

merge 时：同主键的状态自动 merge
  <State: count=5> + <State: count=3> ──> <State: count=8>

查询：必须用 *Merge 函数取出最终值
  SELECT countMerge(page_views) FROM ... GROUP BY ...
  ↑ countMerge 把状态合并并输出数值
```

**为什么不能直接存 sum？** 因为 `sum` 已丢失"怎么算的"，无法做"日→月"的二级聚合而不丢精度。状态函数保留了"可继续聚合"的能力，这是 ClickHouse 实时数仓的核心。详见 [05-functions §3](../05-functions/README.md)。

**与物化视图配合**（典型用法）：
```sql
-- 明细表
CREATE TABLE events (...) ENGINE = MergeTree ORDER BY ...;

-- 预聚合表（AggregatingMergeTree）
CREATE TABLE events_daily ENGINE = AggregatingMergeTree ORDER BY (d, category) AS
SELECT toDate(ts) AS d, category, sumState(amount) AS gmv_state
FROM events GROUP BY d, category;

-- 查询
SELECT d, category, sumMerge(gmv_state) AS gmv FROM events_daily GROUP BY d, category;
```

**坑**：
- 直接 `SELECT state_col` 看到的是二进制乱码，必须 `*Merge`
- 写入用 `*State`，查询用 `*Merge`，反了会报错
- `SimpleAggregateFunction` 是简化版：用于 sum/max/any 等"可直接相加"的聚合，存普通值，省空间但不能跨级聚合

### 3.5 CollapsingMergeTree 折叠引擎

**原理**：用 `sign` 列（Int8，+1 或 -1）实现"增量更新"。merge 时，对**相同的 ORDER BY 主键**的行，如果存在 `+1` 和 `-1` 配对，则抵消删除；只剩同号的保留。

```
场景：库存表，每次进货/出货都写一行
  product_id, quantity_change, sign, ts
  (101, 100, +1, ...)   ← 进货 100，sign=+1
  (101,  20, +1, ...)   ← 进货 20，sign=+1
  (101,  10, -1, ...)   ← 出货 10，sign=-1

merge 折叠：
  +1 与 -1 配对：1 个 +1 抵消 1 个 -1
  剩余：2 个 +1（数量分别为 100, 20）

查询当前库存（注意：不是 SELECT *，必须 GROUP BY）：
  SELECT product_id, sum(quantity_change * sign) AS stock
  FROM inventory GROUP BY product_id;
  ↑ 即便没 merge 完，用 sum(col*sign) 也能得到正确结果
```

**关键坑：写入顺序**：
- CollapsingMergeTree 要求**严格按时间顺序写入**：先写 `+1`（旧状态），再写 `-1`（撤销旧状态），最后写 `+1`（新状态）
- 如果乱序写入（如 Kafka 消费乱序），`-1` 可能先于 `+1` 到达，merge 时无法配对，**折叠失败**
- 解决：用 `VersionedCollapsingMergeTree`（见 §3.6）

**查询模式**（必须记住）：
```sql
-- 错误：SELECT * 会得到未折叠的多行
SELECT * FROM inventory;

-- 正确：用 sum(col * sign) GROUP BY 主键
SELECT product_id, sum(quantity_change * sign) AS stock
FROM inventory GROUP BY product_id;
```

**与 ReplacingMergeTree 对比**：
| 维度 | ReplacingMergeTree | CollapsingMergeTree |
|------|--------------------|--------------------|
| 更新机制 | 覆盖（保留最新版本） | 撤销 + 重写（-1 抵消旧值，+1 写新值） |
| 删除支持 | 不支持（只能"覆盖为空"） | 支持（只写 -1 即可撤销） |
| 写入复杂度 | 低（直接写新行） | 中（需写撤销行 + 新行） |
| 历史可追溯 | 否（旧值被丢弃） | 是（撤销行也保留直到 merge） |
| 适用 | 状态表（用户最新状态） | 流水表（库存、余额、计数器） |

### 3.6 VersionedCollapsingMergeTree 版本折叠引擎

**原理**：在 CollapsingMergeTree 基础上增加 `version` 列。merge 时**先按 version 排序**，再做 sign 抵消。这样即使乱序写入，version 也能保证逻辑顺序正确。

```
乱序写入场景：
  INSERT: (user=1, score=120, +1, ver=2, ts=10:00)   ← 新状态先到
  INSERT: (user=1, score=-100, -1, ver=1, ts=10:01)  ← 旧状态后到（撤销）

CollapsingMergeTree：先到的 +1(ver=2) 与后到的 -1(ver=1) 配对抵消
  → 抵消了新状态，旧状态却没撤销 → 错误！

VersionedCollapsingMergeTree：先按 version 排序
  ver=1: -100(-1)  ← 撤销旧
  ver=2: +120(+1)  ← 写入新
  → 正确抵消旧值，保留新值
```

**场景**：消息来源可能乱序的增量更新场景（Kafka 消费、跨数据中心同步、CDC 补数据）。

**何时选 Versioned 而非普通 Collapsing**：只要有任何"写入可能乱序"的风险，就用 Versioned。代价仅是多存一个 version 列。

### 3.7 ReplicatedMergeTree 复制引擎

**原理**：基于 ZooKeeper / ClickHouse Keeper 协调多副本数据一致性。**不是同步复制**，是异步队列复制。

```
写入流程：
  Client ──INSERT──> Replica A (Primary)
                          │
                          ├─> 1. 写本地 part
                          ├─> 2. 写 ZK 复制日志 (replication_log)
                          │
                          ▼
                     ZooKeeper / Keeper
                          │
                          ├─> 3. Replica B 监听到日志
                          ├─> 4. B 从 A 拉取 part
                          └─> 5. B 写本地 part

合并协调（避免各副本独立 merge 产生不同 part）：
  - 副本选举 Leader（基于 ZK 临时节点）
  - Leader 决定哪些 part 合并
  - 其它副本从 ZK 读合并任务，执行相同合并
  - 保证所有副本最终一致
```

**核心组件**：
- **ZooKeeper / ClickHouse Keeper**：元数据存储、复制协调、Leader 选举。Keeper 是 ClickHouse 自研的 ZK 协议兼容实现，推荐生产用
- **复制队列** (`system.replication_queue`)：每个副本的待执行任务列表
- **Leader 选举**：每个 Replicated 表独立选举一个 replica 作为 leader，负责发起 merge

**复制状态查询**：
```sql
SELECT database, table, is_leader, is_readonly, queue_size,
       absolute_delay, active_replicas, total_replicas
FROM system.replicas WHERE database = 'engine_test';
```

**生产建议**：
- **始终用 Replicated\* 系列**，非复制版无高可用
- Keeper 至少 3 节点（容错 1），生产建议 5 节点（容错 2）
- 监控 `absolute_delay`（复制延迟秒数）和 `queue_size`（队列堆积）
- `is_readonly=1` 表示该副本只读（通常是 ZK 会话过期），需排查

**与 MergeTree 对比**：
| 维度 | MergeTree | ReplicatedMergeTree |
|------|-----------|---------------------|
| 高可用 | 否（单副本） | 是（多副本） |
| 写入开销 | 低 | 略高（写 ZK 日志） |
| 查询开销 | 低 | 低（读本地副本） |
| 适用 | 测试/单机 | 生产 |

### 3.8 Distributed 分布式表引擎

**原理**：Distributed 表**不存储数据**，只是查询路由层。写入时按分片键（sharding key）路由到对应分片的本地表；查询时 fan-out 到所有分片，汇总结果返回。

```
写入 (INSERT INTO distributed_table):
  Client ──> Distributed 表
                │
                ├─ 计算分片: hash(sharding_key) % shards
                ├─ 数据按分片切分
                ├─ 直发对应分片 OR 通过本机转发
                └─ 各分片的本地表 (ReplicatedMergeTree) 接收

查询 (SELECT FROM distributed_table):
  Client ─> Distributed 表
              │
              ├─ fan-out: 把查询发到所有分片
              ├─ 各分片本地查询 (本地表)
              ├─ 各分片返回部分结果
              └─ Distributed 表汇总 (merge) 返回
```

**分片键设计原则**：
- **高基数**：避免数据倾斜（如 `user_id` 比 `gender` 好）
- **查询过滤条件**：若查询常按 `user_id` 过滤，分片键用 `user_id` 可做分片剪枝（只查一个分片）
- **均匀分布**：用 `intHash32(user_id)` 打散热点
- **避免 `rand()`**：无法做分片剪枝

**与本地表关系**：必须先有本地表（`ReplicatedMergeTree`），再建 Distributed 表覆盖。生产架构：
```
分片1: 本地表 (ReplicatedMergeTree) + 1 个 Distributed 表 (查询入口)
分片2: 本地表 (ReplicatedMergeTree)
```

### 3.9 MaterializedView 物化视图

**原理**：物化视图是一张"自动同步"的表。**触发时机：源表 INSERT 时**（不是 UPDATE，不是 DELETE，不是实时）。源表每写入一批数据，物化视图就对这批数据执行 `SELECT ... GROUP BY ...` 并把结果写入自己的存储表。

```
源表 INSERT 一批 ─> 触发 MV 的 SELECT ─> 结果写入 MV 表
  (MergeTree)         (聚合 + *State)        (AggregatingMergeTree)
```

**关键限制**：
- **仅 INSERT 触发**：源表 DELETE/UPDATE 不会反向更新 MV（除非用 `ALTER ... MODIFY` 等特殊机制）
- **历史数据不回填**：MV 创建前的源表数据不会被处理。需先建 MV 再写数据，或手动 `INSERT INTO MV SELECT ... FROM 源表`
- **聚合结果是增量的**：MV 表里存的是每次 INSERT 触发的"部分聚合结果"，最终查询时还需 `*Merge` 合并

**与普通 View 对比**：
| 维度 | MaterializedView | View |
|------|------------------|------|
| 存储 | 有（存聚合结果） | 无（仅 SQL 别名） |
| 触发 | INSERT 自动同步 | 查询时展开 |
| 性能 | 查询快（已预聚合） | 查询慢（实时算） |
| 写入开销 | 增加（触发聚合） | 无 |
| 适用 | 预聚合加速 | 查询复用、权限隔离 |

### 3.10 Log 家族存储差异

```
TinyLog:
  ┌─────────────────────┐
  │ data.bin            │ ← 每列一个文件，无标记
  │ data.bin            │
  └─────────────────────┘
  特点：最简单，无并发读，无压缩
  适用：< 100MB 临时数据

StripeLog:
  ┌─────────────────────┐
  │ data.bin (条带)     │ ← 所有列存一个文件，带压缩
  │ index.idx           │
  └─────────────────────┘
  特点：单文件条带，压缩好，无并发读
  适用：1MB-1GB 中等日志

Log:
  ┌─────────────────────┐
  │ col1.bin            │ ← 每列独立文件
  │ col2.bin            │
  │ __marks.mrk         │ ← 标记文件，支持并发读
  └─────────────────────┘
  特点：列式 + 标记，支持并发读，性能最好
  适用：1-10GB 小批量数据
```

**为什么生产不用 Log**：无索引、无分区、无复制、无 TTL。一旦数据量增长，查询性能断崖式下跌。仅适合临时表、测试、ETT 中间结果。

### 3.11 Buffer 缓冲表引擎

**原理**：Buffer 表是"写入缓冲层"，数据先写内存缓冲区，达到阈值（行数/字节数/时间）后批量刷盘到目标表。

```
写入 ─> Buffer 表 (内存) ─> 阈值触发 ─> 目标表 (MergeTree)
                              │
                              └─ 风险：宕机时缓冲区数据丢失！
```

**关键参数**：`Buffer(db, table, num_buffers, min_time, max_time, min_rows, max_rows, min_bytes, max_bytes)`

**风险**：Buffer 数据在内存中，**ClickHouse 进程崩溃会丢失**。不可用于要求零丢失的场景。

**适用**：高频小批量写入的缓冲合并（如每秒 100 次 1 行的写入，用 Buffer 合并成每 100 秒 1 万行的大批量写入）。但现代 ClickHouse 推荐 `async_insert` 替代 Buffer 表（更安全，性能相当）。

---

## 4. 引擎家族核心对比决策表

### 4.1 MergeTree 家族全维度对比

| 引擎 | merge 时做什么 | 去重 | 聚合 | 支持复制 | 查询需特殊处理 | 适用场景 |
|------|----------------|------|------|----------|----------------|----------|
| MergeTree | 仅排序合并 | ❌ | ❌ | ❌ | 否 | append-only 明细 |
| ReplacingMergeTree | 同主键保留 version 最大 | ✅ merge 时 | ❌ | ❌ | FINAL 或 argMax | 状态表（用户最新状态） |
| SummingMergeTree | 同主键数值列 SUM | ❌ | ✅ SUM | ❌ | sum() GROUP BY | 数值累加预聚合 |
| AggregatingMergeTree | 同主键 AggregateFunction 列 merge | ❌ | ✅ 任意 | ❌ | *Merge + GROUP BY | 复杂聚合、多级聚合 |
| CollapsingMergeTree | 同主键 sign +1/-1 抵消 | ✅ 折叠 | ❌ | ❌ | sum(col*sign) GROUP BY | 增量更新（库存、计数器） |
| VersionedCollapsingMergeTree | 按 version 排序后 sign 抵消 | ✅ 折叠 | ❌ | ❌ | sum(col*sign) GROUP BY | 乱序写入的增量更新 |
| GraphiteMergeTree | Graphite rollup | ❌ | ✅ 时序 | ❌ | 否 | Graphite 监控 |
| ↑ 加 `Replicated` 前缀 | 同上 | 同上 | 同上 | ✅ | 同上 | 生产标配 |

### 4.2 业务场景 → 引擎选择决策表

| 业务场景 | 推荐引擎 | 理由 |
|----------|----------|------|
| 事件日志（埋点、点击流） | ReplicatedMergeTree | append-only，无需去重聚合 |
| 用户最新状态表 | ReplicatedReplacingMergeTree(version) | 需要保留最新版本 |
| 实时 GMV 报表 | ReplicatedAggregatingMergeTree + sumState | 多级聚合（日→月→年）无损 |
| UV 实时统计 | ReplicatedAggregatingMergeTree + uniqState | HLL 状态可跨级合并 |
| P99 延迟监控 | ReplicatedAggregatingMergeTree + quantileState | 分位数不可加，必须状态 |
| 库存/余额（顺序写入） | ReplicatedCollapsingMergeTree(sign) | sign 折叠实现增量更新 |
| 库存/余额（乱序写入） | ReplicatedVersionedCollapsingMergeTree(sign, version) | version 保证折叠正确 |
| Graphite 监控 | GraphiteMergeTree | 时序 rollup 内置 |
| 临时表/ETT 中间结果 | Log / Memory | 小数据，无持久化需求 |
| 跨分片查询入口 | Distributed + ReplicatedMergeTree | 路由层不存数据 |
| 高频小批量写入 | async_insert + MergeTree（推荐）或 Buffer | 替代 Buffer 更安全 |
| 数据归档（按月分表） | Merge（多表合并查询） | 透明跨表查询 |

### 4.3 Log 家族对比

| 引擎 | 存储 | 压缩 | 并发读 | 索引 | 适用数据量 |
|------|------|------|--------|------|------------|
| TinyLog | 列独立文件 | ❌ | ❌ | ❌ | < 100MB |
| StripeLog | 单文件条带 | ✅ | ❌ | ❌ | 1MB-1GB |
| Log | 列独立 + 标记 | ✅ | ✅ | ❌ | 1-10GB |

### 4.4 特殊引擎对比

| 引擎 | 存数据 | 触发时机 | 持久化 | 典型用途 |
|------|--------|----------|--------|----------|
| Distributed | ❌ | 查询时 | N/A | 分布式路由 |
| MaterializedView | ✅ | 源表 INSERT | ✅ | 预聚合 |
| View | ❌ | 查询时 | N/A | SQL 复用 |
| Buffer | 内存 | 阈值触发 | ❌（宕机丢） | 写入缓冲 |
| Merge | ❌ | 查询时 | N/A | 多表合并 |
| Null | ❌ | 写入即丢 | N/A | 测试/审计 |
| Set / Join | ✅ | INSERT | 部分 | IN 优化/连接 |
| Dictionary | 内存 | 定时刷新 | ✅ | 维表查找 |
| Memory | 内存 | 写入 | ❌（重启丢） | 临时内存表 |

---

## 5. 文件导航

| 文件 | 内容 | 关键章节 |
|------|------|----------|
| [01_mergetree_engines.sql](./01_mergetree_engines.sql) | MergeTree 家族 7 种引擎 | §1 MergeTree 基础、§2 ReplacingMergeTree 去重时机、§3 SummingMergeTree 非数值列坑、§4 AggregatingMergeTree 状态、§5 CollapsingMergeTree sign、§6 VersionedCollapsingMergeTree |
| [02_replicated_engines.sql](./02_replicated_engines.sql) | 复制引擎 + Keeper 协调 | §1 复制原理、§2 各 Replicated* 引擎、§7 复制 vs 非复制对比、§8 复制延迟监控 |
| [03_log_engines.sql](./03_log_engines.sql) | Log 家族存储差异 | §1 TinyLog、§2 StripeLog、§3 Log、§4 三引擎对比 |
| [04_integration_engines.sql](./04_integration_engines.sql) | 集成引擎 + 查询下推 | §1 URL/File、§2 S3/HDFS、§3 MySQL/PostgreSQL 下推、§4 表函数用法 |
| [05_special_engines.sql](./05_special_engines.sql) | 特殊引擎 | §1 Distributed 路由、§2 MaterializedView 触发、§3 View、§4 Dictionary、§5 Buffer、§6 Merge、§7 Null、§8 Set、§9 Join |
| [06_engine_selection_guide.md](./06_engine_selection_guide.md) | 引擎选择决策指南 | 决策树、对比表深化、性能基准、最佳实践 |

---

## 6. 常见误区与最佳实践

### 6.1 常见误区

1. **以为 `ReplacingMergeTree` 写入即去重** → 去重只在后台 merge 时发生，查询时数据可能仍有重复。需 `FINAL` 或 `argMax`
2. **`SELECT * FROM collapsing_table` 期望看到折叠后的库存** → 折叠也是 merge 时发生，且查询必须 `sum(col*sign) GROUP BY` 才能得到正确结果
3. **`SummingMergeTree` 表里 `country` 列值"飘忽不定"** → 非数值列在 merge 时取首行值，不可预测。维度列必须放进 ORDER BY
4. **直接 `SELECT state_col` 看到乱码以为坏了** → `AggregateFunction` 列是二进制状态，必须 `*Merge` 取值
5. **`Distributed` 表里查到数据以为它存数据** → 它只是路由层，数据在本地表。删 Distributed 表不会删数据
6. **物化视图创建后以为历史数据会自动回填** → 仅 INSERT 触发，历史数据需手动 `INSERT INTO MV SELECT`
7. **生产用 `MergeTree` 单副本** → 无高可用，磁盘损坏数据丢失。必须用 Replicated\*
8. **用 `CollapsingMergeTree` 处理 Kafka 乱序数据** → 乱序导致 sign 无法配对，折叠失败。改用 `VersionedCollapsingMergeTree`
9. **分区按天导致分区爆炸** → 单表分区数 > 1000 时 merge 调度崩溃。月分区通常够用
10. **`Buffer` 表用于关键业务数据** → 宕机会丢缓冲数据。改用 `async_insert`
11. **`OPTIMIZE TABLE ... FINAL` 当日常操作** → 代价极高（重写整个 part），仅用于特殊场景

### 6.2 最佳实践

1. **生产一律 Replicated\* 系列**：高可用是底线，Keeper 至少 3 节点
2. **ORDER BY 设计**：高频过滤条件放前缀，时间放最后（`ORDER BY (user_id, event_type, timestamp)`）
3. **分区按月**：`toYYYYMM(ts)` 是 90% 场景的最佳粒度，按天要谨慎
4. **状态表用 ReplacingMergeTree(version)**：version 列让去重可预测，比裸 ReplacingMergeTree 安全
5. **复杂聚合用 AggregatingMergeTree + *State**：保留多级聚合能力，避免精度丢失
6. **增量更新优先 VersionedCollapsingMergeTree**：容忍乱序，比普通 Collapsing 更安全
7. **预聚合用物化视图 + AggregatingMergeTree**：实时数仓标准架构
8. **Distributed 表分片键选高基数列**：`user_id` 或 `intHash32(user_id)`，避免数据倾斜
9. **TTL 自动清理冷数据**：比手动删分区优雅，配合冷热分层存储
10. **跳数索引按需添加**：`bloom_filter` 适合等值查高基数列，`minmax` 适合范围查有序列，不要无脑加
11. **监控 `system.replicas` 的 `queue_size` 和 `absolute_delay`**：复制延迟超 60s 告警
12. **`async_insert` 替代 Buffer 表**：更安全的高频小写入方案

---

## 7. 自测题（理解检查点）

完成本章后，应能回答：

1. `ReplacingMergeTree` 写入后立即查询，为什么还有重复行？有几种方法可以拿到去重后的结果？
2. `ReplacingMergeTree(version)` 中 version 列的作用是什么？不写 version 会怎样？
3. `SummingMergeTree` 表里一个 String 列在 merge 后值是什么？为什么会"飘忽不定"？
4. `AggregatingMergeTree` 为什么必须用 `sumState` 写入、`sumMerge` 查询？直接 `sum` 存进去会怎样？
5. `CollapsingMergeTree` 的查询为什么不能 `SELECT *`？正确的查询模式是什么？
6. `CollapsingMergeTree` 在 Kafka 乱序消费场景下为什么会"折叠失败"？`VersionedCollapsingMergeTree` 如何解决？
7. `ReplicatedMergeTree` 的复制是同步还是异步？复制延迟如何监控？
8. `Distributed` 表存数据吗？写入时数据如何路由？查询时如何 fan-out？
9. 物化视图在什么时机触发？源表的历史数据会被回填吗？
10. TinyLog、StripeLog、Log 三者在存储结构上的核心差异是什么？为什么生产不用？
11. `Buffer` 表会丢数据吗？什么场景下应该用 `Buffer`，什么场景应该用 `async_insert`？
12. 生产一张"用户实时订单 GMV 报表"表，从明细到日报应该用什么引擎组合？

答案线索均在本 README 及配套 SQL 文件中。

---

## 8. 关联章节

- [05-functions](../05-functions/README.md) —— `*State`/`*Merge` 聚合状态函数详解（与本章 §3.4 呼应）
- [02-principles](../02-principles/README.md) —— Part 合并、稀疏索引、向量化执行底层原理
- [08-performance](../08-performance/README.md) —— 引擎选择对查询性能的影响
- [03-data-types](../03-data-types/README.md) —— TTL 与数据生命周期

---

## 9. 参考资源

- [ClickHouse 表引擎总览](https://clickhouse.com/docs/en/engines/table-engines)
- [MergeTree 家族](https://clickhouse.com/docs/en/engines/table-engines/mergetree-family)
- [ReplacingMergeTree](https://clickhouse.com/docs/en/engines/table-engines/mergetree-family/replacingmergetree)
- [SummingMergeTree](https://clickhouse.com/docs/en/engines/table-engines/mergetree-family/summingmergetree)
- [AggregatingMergeTree](https://clickhouse.com/docs/en/engines/table-engines/mergetree-family/aggregatingmergetree)
- [CollapsingMergeTree](https://clickhouse.com/docs/en/engines/table-engines/mergetree-family/collapsingmergetree)
- [VersionedCollapsingMergeTree](https://clickhouse.com/docs/en/engines/table-engines/mergetree-family/versionedcollapsingmergetree)
- [ReplicatedMergeTree](https://clickhouse.com/docs/en/engines/table-engines/mergetree-family/replication)
- [Distributed](https://clickhouse.com/docs/en/engines/table-engines/special/distributed)
- [MaterializedView](https://clickhouse.com/docs/en/engines/table-engines/special/materialized-view)
- [Log 家族](https://clickhouse.com/docs/en/engines/table-engines/log-family)
- [集成引擎](https://clickhouse.com/docs/en/engines/table-engines/integrations)
