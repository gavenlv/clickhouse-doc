# ClickHouse 基础架构与核心机制（专家级详解）

> 本章是 ClickHouse 的"地基"。读完本章，你应能：从底层理解 MergeTree 的 Part 合并机制、稀疏索引原理、向量化执行；掌握复制表/分布式表的路由与一致性模型；熟练运用索引、物化视图、字典等加速手段；为业务场景精准选型表引擎与数据模型。
>
> 配套可运行 SQL：[01_basic_operations.sql](./01_basic_operations.sql) ~ [09_dictionaries.sql](./09_dictionaries.sql)。集群已启动（`treasurycluster`，CH 25.12.1.649，2 副本），所有 SQL 均已在集群验证零错误。

---

## 1. 本章解决什么问题（Why）

ClickHouse 是为 OLAP 而生的列式数据库，其设计哲学与传统 OLTP 数据库截然相反。新人常带着 OLTP 思维用 CH，导致性能灾难。本章先解决认知，再解决操作：

| 业务痛点 | 本章如何解答 |
|----------|--------------|
| 为什么 CH 不支持高频 UPDATE/DELETE？该用什么替代？ | §3.3 MergeTree 的"追加写 + 后台合并"机制 + §5 表引擎选型决策表 |
| 为什么 CH 查询比 MySQL 快 100 倍？是哪两个机制在起作用？ | §3.1 列式存储 + 向量化执行 + §3.2 稀疏索引原理图解 |
| 复制表和分布式表什么关系？是不是建了复制表就不用分布式表了？ | §4.1 复制 vs 分片正交关系图 + §4.2 分布式表路由流程 |
| `ReplicatedMergeTree()` 为什么不写 ZooKeeper 路径？背后宏机制是什么？ | §4.3 默认复制路径宏 + macros.xml 配置原理 |
| 索引建了为什么查询没用上？跳数索引和主键索引区别？ | §5 索引原理 + §5.2 稀疏索引 vs 跳数索引对比决策表 |
| 物化视图和投影该用哪个？为什么 MV 必须用 `*State` 函数？ | §6.1 物化视图预聚合原理 + §6.3 MV vs Projection 决策表 |
| 字典加速 JOIN 怎么做？什么场景该用字典？ | §7 字典的 4 种 LAYOUT + 加速 JOIN 实战 |
| ReplacingMergeTree / CollapsingMergeTree / VersionedCollapsingMergeTree 怎么选？ | §5 表引擎选型决策表（按业务场景） |

**学习路径建议**：先读 §2 全景图建立认知，再按 §3 → §4 → §5 → §6 → §7 顺序读原理，最后对照 SQL 文件跑一遍。

---

## 2. 核心机制全景图

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    ClickHouse 核心机制分层                                 │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  ① 存储引擎层 (MergeTree Family)                                         │
│     ├─ MergeTree          基础引擎：Part 合并 + 稀疏索引                  │
│     ├─ ReplicatedMergeTree 加 ZooKeeper 复制（生产必备）                   │
│     ├─ ReplacingMergeTree 按 ORDER BY 键去重，保留最新版本                 │
│     ├─ CollapsingMergeTree sign(+1/-1) 抵消，增量更新                     │
│     ├─ SummingMergeTree   同主键数值列自动求和（预聚合）                   │
│     ├─ AggregatingMergeTree 配合 *State 函数，最灵活的预聚合               │
│     └─ VersionedCollapsingMergeTree sign + version 严格版本控制            │
│                                                                          │
│  ② 集群拓扑层 (Cluster Topology)                                         │
│     ├─ Shard  水平切分数据（Distributed 表路由）                          │
│     ├─ Replica 同一份数据的多副本（Replicated 引擎同步）                    │
│     └─ Keeper 协调复制日志 + leader 选举                                  │
│                                                                          │
│  ③ 索引层 (Indexing)                                                     │
│     ├─ Primary Key 稀疏索引，每 8192 行一个 mark，定位粒度                 │
│     ├─ Skip Index 跳数索引，跳过不匹配的 granule                          │
│     │   ├─ minmax    数值/日期范围过滤                                    │
│     │   ├─ set       低基数枚举值过滤                                     │
│     │   ├─ bloom_filter 高基数等值过滤                                    │
│     │   └─ ngrambf_v1/tokenbf_v1 字符串模糊匹配                          │
│     └─ Projection 投影，备选排序 + 预聚合，查询自动选最优                   │
│                                                                          │
│  ④ 加速层 (Acceleration)                                                 │
│     ├─ Materialized View 物化视图，INSERT 触发预聚合                       │
│     ├─ Dictionary 字典，维度表常驻内存，加速 JOIN                          │
│     ├─ TTL 自动过期 + 分层存储（热→SSD→HDD）                              │
│     └─ Sampling 采样查询，大数据近似计算                                  │
│                                                                          │
│  ⑤ 执行层 (Execution)                                                    │
│     ├─ 向量化执行 SIMD，一次处理一个 vector（8192 行）                     │
│     ├─ 多线程并行，按 part 粒度并行扫描                                    │
│     └─ Pipeline 执行管道，算子流式串联                                    │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 3. MergeTree 引擎核心原理（地基中的地基）

### 3.1 列式存储 + 向量化执行：为什么 CH 查询快 100 倍

**传统行式存储查询流程**：
```
SELECT sum(amount) FROM orders WHERE region = 'East'

行式:  读整行 [id,user,region,amount,...] × 1亿行
       → 逐行判断 region → 累加 amount
       I/O: 读取所有列（100GB），CPU: 逐行分支判断
```

**CH 列式存储查询流程**：
```
列式:  只读 amount 列 + region 列（2GB / 100GB）
       → 向量化：把 8192 个 amount 打包成 vector
       → SIMD 指令一次性累加整个 vector
       I/O: 只读 2 列（2GB，省 50x），CPU: SIMD 并行（省 10x+）
```

**两个加速倍数叠加**：I/O 减少 50x（只读需要的列）× CPU 提升 10x（SIMD 向量化）≈ 100x+ 总加速。这就是 CH 快的本质，与"内存数据库"无关。

**列存物理结构**：
```
/var/lib/clickhouse/data/db/table/{partition}/{part}/
  ├── data.bin        每个列一个文件（按列分开存）
  ├── index.mrk       mark 文件：稀疏索引的位置指针
  ├── primary.idx     主键索引：每 8192 行存一次主键值
  └── columns.txt     列信息
```

### 3.2 稀疏索引原理（CH 性能的第二个支柱）

**核心思想**：不为每行建索引，而是每 8192 行（一个 granule）建一个索引条目。索引极小，常驻内存。

```
表数据（按 ORDER BY 排序后存储）:
┌──────────────┬──────────────┬──────────────┬──────────────┐
│  granule 0   │  granule 1   │  granule 2   │  granule 3   │
│ 8192 行       │ 8192 行       │ 8192 行       │ 8192 行       │
│ user_id:     │ user_id:     │ user_id:     │ user_id:     │
│  [1..100]    │ [101..200]   │ [201..300]   │ [301..400]   │
└──────────────┴──────────────┴──────────────┴──────────────┘
       ▲              ▲              ▲              ▲
       │              │              │              │
   primary.idx 索引条目（只存每个 granule 的主键范围）:
   ┌─────────┬─────────┬─────────┬─────────┐
   │ mark 0  │ mark 1  │ mark 2  │ mark 3  │
   │ uid=1   │ uid=101 │ uid=201 │ uid=301 │
   └─────────┴─────────┴─────────┴─────────┘

查询 WHERE user_id = 250:
  1. 二分查找 primary.idx → 命中 mark 2（uid 范围 201-300）
  2. 只读 granule 2 的 8192 行（而非全表 1 亿行）
  3. 在 granule 2 内线性扫描找到 user_id=250
```

**关键参数 `index_granularity`（默认 8192）**：
- 越小：索引越大，定位越精确，但索引占内存多
- 越大：索引越小，但每个 granule 扫的行多
- 默认 8192 是经验值，对绝大多数场景最优

**为什么主键必须和 ORDER BY 一致**：主键索引就是按 ORDER BY 排序后每 8192 行取一个标记。ORDER BY 决定了数据物理排列，主键索引是它的"目录"。

### 3.3 Part 合并机制（MergeTree 的"灵魂"）

CH 的 INSERT 不是更新已有数据，而是创建一个新的 **part**（数据块）。后台异步合并小 part → 大 part。

```
INSERT 1: 创建 part "20240101_1_1_0"    (1 个 granule)
INSERT 2: 创建 part "20240101_2_2_0"    (1 个 granule)
INSERT 3: 创建 part "20240101_3_3_0"    (1 个 granule)
                    │
                    ▼ 后台 merge
合并后:    part "20240101_1_3_1"        (3 个 granule，level=1)

命名规则: {partition}_{min_block}_{max_block}_{level}
```

**为什么这么设计**：
- 写入零阻塞：每次 INSERT 只写一个新 part，不修改已有数据
- 合并异步：后台线程慢慢合并，不影响写入
- 不可变：part 一旦写入不可修改（这也是不支持 UPDATE 的根因）

**合并的副作用**：
- ReplacingMergeTree：合并时才真正去重
- CollapsingMergeTree：合并时才真正抵消 sign
- SummingMergeTree：合并时才真正求和

**查询时数据可能是"未合并"状态** → 这就是为什么需要 `FINAL` 或 `argMax` 手动去重。

**Too many parts 异常**：如果写入太快（每秒几十次小 INSERT），part 数量爆炸，CH 会拒绝写入。解决：批量写入（每次 1 万~10 万行）+ async_insert。

### 3.4 分区（Partition）与 Part 的关系

```
表 = 多个分区（PARTITION BY）
  分区 = 多个 part（INSERT 产生，merge 合并）
  part = 多个 granule（每 8192 行）
  granule = 列存的最小读取单位
```

**分区剪枝（Partition Pruning）**：查询带分区键过滤时，只扫匹配分区。这是 CH 时间序列查询快的最重要优化。

```sql
-- 按月分区
PARTITION BY toYYYYMM(event_time)

-- 查询只扫 2024 年 1 月分区，跳过其他 11 个月
SELECT count() FROM events WHERE event_time BETWEEN '2024-01-01' AND '2024-01-31';
```

---

## 4. 复制与分布式：高可用 + 横向扩展

### 4.1 复制 vs 分片：正交关系（最易混淆）

```
                  ┌─────────────────────────────────────┐
                  │           Cluster (treasurycluster)   │
                  │   ┌────────────┐  ┌────────────┐    │
                  │   │  Shard 1   │  │  Shard 2   │    │
                  │   │            │  │            │    │
  分片(Shard):    │   │ Replica 1  │  │ Replica 1  │    │
  水平切分数据     │   │ (server-1) │  │ (server-2) │    │
  增加容量        │   │            │  │            │    │
                  │   │ Replica 2  │  │ Replica 2  │    │
  副本(Replica):  │   │ (server-2) │  │ (server-1) │    │
  数据冗余备份     │   │            │  │            │    │
  提供高可用       │   └────────────┘  └────────────┘    │
                  └─────────────────────────────────────┘

正交关系:
  - 分片解决"容量"问题（数据量太大，一台存不下）
  - 副本解决"可用性"问题（一台宕机，另一台顶上）
  - 两者独立配置，可任意组合
```

### 4.2 分布式表路由原理

```
Client ──INSERT──▶ Distributed 表（不存数据，只是路由层）
                       │
                       ▼ 1. 计算 sharding_key 的哈希
                       │    sharding_key = user_id
                       │    hash(user_id) % num_shards → 路由到 shard X
                       │
                       ▼ 2. 转发到 shard X 的某个副本本地表
                   Local Table (ReplicatedMergeTree, 真正存数据)

查询时:
Client ──SELECT──▶ Distributed 表
                       │
                       ▼ 1. 广播 SELECT 到所有 shard
                   Shard 1 Local  Shard 2 Local  ... Shard N Local
                       │              │                │
                       ▼ 2. 各 shard 本地聚合（部分聚合）
                       │              │                │
                       ▼ 3. Distributed 收集各 shard 结果，做最终合并聚合
                       │
                       ▼ 4. 返回 Client
```

**关键优化**：分布式聚合是"两阶段"的——各分片先做部分聚合（减少数据传输），协调节点再合并。这就是 `*State`/`*Merge` 函数的应用场景。

### 4.3 ReplicatedMergeTree 复制原理

```
                    ZooKeeper / Keeper
                    ┌─────────────────────┐
                    │ /clickhouse/tables/  │
                    │   {shard}/{table}/   │
                    │   replicas/           │
                    │   ├─ replica1/        │
                    │   │  └─ log/  ←写入日志│
                    │   └─ replica2/        │
                    │      └─ log/          │
                    └─────────┬─────────────┘
                              │
            ┌─────────────────┴─────────────────┐
            ▼                                   ▼
     ┌──────────────┐                    ┌──────────────┐
     │  Replica 1   │ ◀──── 拉取数据 ─── │  Replica 2   │
     │  (Leader)    │                    │  (Follower)  │
     │  写入本地     │                    │  从 R1 拉 part│
     │  +写 ZK 日志  │                    │              │
     └──────────────┘                    └──────────────┘

复制流程:
  1. Client 写 Replica 1（任意副本可写）
  2. R1 写本地 part + 在 ZK 的 log/ 节点追加一条 INSERT 记录
  3. R2 监听 ZK log/，发现新记录
  4. R2 从 R1 拉取对应 part（HTTP 拉取，不是 ZK 传数据）
  5. R2 写入本地 part，更新 ZK 确认
  6. 最终一致（异步，通常秒级）
```

**为什么用 ZK 而不是直接多写**：
- ZK 只传"日志"（哪条 INSERT），不传数据（数据走 HTTP）
- ZK 保证日志顺序，所有副本按相同顺序应用
- Leader 选举：哪个副本负责触发 merge，避免各副本独立 merge 产生不同 part

**默认路径宏机制**（本章集群已配置）：
```xml
<!-- /etc/clickhouse-server/config.d/macros.xml -->
<macros>
    <cluster>treasurycluster</cluster>
    <shard>1</shard>           <!-- 不同节点不同 -->
    <replica>clickhouse1</replica>  <!-- 不同节点不同 -->
</macros>

<!-- 默认复制路径（已配置）-->
<default_replica_path>/clickhouse/tables/{shard}/{table}</default_replica_path>
<default_replica_name>{replica}</default_replica_name>
```

所以创建复制表可以简化为：
```sql
-- 不用写 ZK 路径，宏自动展开
CREATE TABLE t (...) ENGINE = ReplicatedMergeTree() ORDER BY ...;
-- 等价于
-- ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/t', '{replica}')
```

---

## 5. 表引擎选型决策表（核心场景）

| 引擎 | 去重/合并机制 | 适用场景 | 不适用场景 | 查询去重方式 |
|------|--------------|----------|------------|-------------|
| `MergeTree` | 无去重 | 不可变日志、事件流 | 需要更新 | 直接查 |
| `ReplacingMergeTree(ver)` | 按 ORDER BY 键去重，保留 max(ver) | 用户资料、配置、状态机 | 频繁更新 | `argMax(x, ver)` 或 `FINAL` |
| `CollapsingMergeTree(sign)` | sign +1/-1 抵消 | 增量计数器、库存 | 需要保留历史 | `sum(col * sign)` |
| `VersionedCollapsingMergeTree(sign, ver)` | sign + version | 金融交易、严格版本 | 简单状态 | `sum(col*sign)` + `max(ver)` |
| `SummingMergeTree` | 同主键数值列求和 | 预聚合报表 | 需要明细 | 直接查（合并后即求和） |
| `AggregatingMergeTree` | 同主键 *State 合并 | 任意聚合预聚合 | 简单求和（用 Summing） | `*Merge(state_col)` |
| `Replicated*` 上述引擎 | 上述 + ZK 复制 | **生产必备** | 单机测试 | 同上 |

**选型决策树**：
```
数据需要更新吗?
├─ 否 → MergeTree (或 ReplicatedMergeTree 生产用)
└─ 是 → 更新模式是什么?
    ├─ 整行覆盖（最新版本生效）→ ReplacingMergeTree(version)
    │   场景: 用户资料、商品信息、配置
    │   查询: SELECT argMax(col, version) FROM t GROUP BY pk
    │
    ├─ 增量增减（+1/-1 抵消）→ CollapsingMergeTree(sign)
    │   场景: 库存、计数器、订单状态
    │   查询: SELECT sum(col * sign) FROM t GROUP BY pk
    │
    ├─ 增量 + 严格版本 → VersionedCollapsingMergeTree(sign, version)
    │   场景: 金融交易、需要审计的库存
    │   查询: SELECT sum(col*sign) FROM t WHERE version=最新 GROUP BY pk
    │
    └─ 预聚合（不需要明细）→ 选哪种?
        ├─ 只求和 → SummingMergeTree
        ├─ 任意聚合（avg/quantile/uniq）→ AggregatingMergeTree + *State
        └─ 多个不同聚合 → AggregatingMergeTree（最通用）
```

**生产环境铁律**：所有引擎加 `Replicated` 前缀 + `ON CLUSTER 'treasurycluster'`。

---

## 6. 索引与物化视图：查询加速双雄

### 6.1 三层索引体系

```
查询 WHERE user_id = 123 AND status = 'active'

第 1 层: 分区剪枝 (Partition Pruning)
  └─ 跳过不匹配的分区（粗粒度，按月/天）
  └─ 命中: 只扫 2024-01 分区

第 2 层: 主键稀疏索引 (Primary Key Index)
  └─ 按 ORDER BY (user_id, ...) 二分查找 mark
  └─ 命中: 只扫 mark 范围内的几个 granule（8192 行/个）

第 3 层: 跳数索引 (Skip Index) - 可选
  └─ 在每个 granule 上判断 status 是否可能命中
  └─ 命中: 跳过 status 不匹配的 granule
```

### 6.2 稀疏索引 vs 跳数索引对比

| 维度 | 主键稀疏索引 | 跳数索引（Skip Index） |
|------|-------------|----------------------|
| 自动创建 | 是（ORDER BY 决定） | 否（需手动 ADD INDEX） |
| 索引粒度 | 每 8192 行一个 mark | 每 N 个 granule 一个（GRANULARITY 参数） |
| 作用列 | ORDER BY 列 | 任意列 |
| 索引类型 | 单一（范围查找） | minmax / set / bloom_filter / ngrambf |
| 是否影响写入 | 否（索引和数据一起生成） | 是（额外维护索引） |
| 查询自动用 | 是 | 是 |
| 适合场景 | 高频过滤的排序列 | 非排序列的等值/范围过滤 |

**跳数索引选型决策表**：

| 数据特征 | 推荐索引 | 示例 |
|----------|----------|------|
| 数值/日期范围 | `minmax` | `temperature TYPE minmax` |
| 低基数枚举（<1000） | `set(N)` | `status TYPE set(100)` |
| 高基数等值（ID类） | `bloom_filter` | `user_id TYPE bloom_filter(0.01)` |
| 长文本包含搜索 | `tokenbf_v1` | `url TYPE tokenbf_v1(...)` |
| 子串模糊匹配 | `ngrambf_v1` | `user_agent TYPE ngrambf_v1(3,256,2,0)` |

### 6.3 物化视图 vs 投影决策表

| 维度 | 物化视图（MV） | 投影（Projection） |
|------|---------------|-------------------|
| 存储位置 | 独立表 | 依附主表 |
| 触发时机 | INSERT 时触发 | INSERT 时同步写入 |
| 引擎可选 | 是（可选 SummingMT 等） | 否（用主表引擎） |
| 跨表查询 | 是（可 JOIN 多表） | 否（仅主表） |
| 查询自动路由 | 否（需手动查 MV） | 是（优化器自动选） |
| 维护成本 | 中（独立 part 合并） | 低（随主表合并） |
| 适用场景 | 多维预聚合、跨表 | 单表备选排序/聚合 |

**推荐**：单表加速用投影；跨表预聚合/复杂转换用物化视图。

### 6.4 物化视图预聚合必须用 *State 函数

```sql
-- ❌ 错误：用 sum 直接存，无法二次聚合
CREATE MATERIALIZED VIEW mv ENGINE = AggregatingMergeTree ORDER BY ... AS
SELECT day, sum(amount) AS gmv FROM raw GROUP BY day;
-- 问题：日表 → 月表时，sum(日 gmv) 会算错（因为可能重复聚合）

-- ✅ 正确：用 sumState 存状态，sumMerge 还原
CREATE MATERIALIZED VIEW mv ENGINE = AggregatingMergeTree ORDER BY ... AS
SELECT day, sumState(amount) AS gmv_state FROM raw GROUP BY day;
-- 月表: SELECT sumMerge(gmv_state) FROM mv GROUP BY month ← 状态可继续合并
```

原理详见 [04-functions/README.md §3](../04-functions/README.md)。

---

## 7. 字典加速 JOIN

CH 的 JOIN 是性能短板（右表全量加载内存）。字典把维度表常驻内存，用 `dictGet` 替代 JOIN，快 10-100x。

| LAYOUT | 数据结构 | 查询复杂度 | 适用 | 内存 |
|--------|----------|-----------|------|------|
| `HASHED` | 哈希表 | O(1) | 通用，键值查找 | 全量加载 |
| `CACHE` | LRU 缓存 | O(1) | 大字典（不常全查） | 部分加载 |
| `FLAT` | 数组下标 | O(1) | 键是连续整数 | 最省 |
| `RANGE_HASHED` | 哈希 + 区间 | O(log n) | IP 段、价格区间 | 中 |

```sql
-- 字典替代 JOIN
SELECT
    u.user_id,
    dictGet('user_dict', 'name', u.user_id) AS name,    -- O(1) 查找
    dictGet('user_dict', 'country', u.user_id) AS country
FROM events u;
-- 比 LEFT JOIN user_dict 快 10x+
```

---

## 8. 文件导航

| 文件 | 主题 | 关键章节 |
|------|------|----------|
| [01_basic_operations.sql](./01_basic_operations.sql) | 基础 CRUD + 去重入门 | §1 MergeTree 原理、§2 复制集群机制、§3 插入/查询原理、§4 聚合、§5 JOIN、§6 窗口函数、§7 CTE、§8 去重幂等 |
| [02_replicated_tables.sql](./02_replicated_tables.sql) | 复制表机制 | §1 复制架构、§2 Macros 宏机制、§3 默认复制路径、§4 复制状态监控、§5 ReplacingMT、§6 CollapsingMT、§7 复制队列 |
| [03_distributed_tables.sql](./03_distributed_tables.sql) | 分布式表路由 | §1 分布式架构、§2 分片 vs 副本、§3 Distributed 引擎、§4 分片键选择、§5 负载均衡、§6 跨分片聚合、§7 分布式 JOIN |
| [04_data_types.sql](./04_data_types.sql) | 数据类型深度 | §1 数值类型选型、§2 字符串/LowCardinality/FixedString、§3 日期时间、§4 Decimal 精度、§5 Array/Map/Tuple、§6 Enum、§7 UUID/IP/JSON、§8 Nullable |
| [05_indexes.sql](./05_indexes.sql) | 索引体系 | §1 稀疏索引原理、§2 index_granularity、§3 跳数索引 4 种类型、§4 主键设计原则、§5 投影 Projection、§6 PREWHERE 优化 |
| [06_optimization.sql](./06_optimization.sql) | 性能优化 | §1 分区策略、§2 TTL 分层存储、§3 压缩 Codec、§4 采样查询、§5 GROUP BY 优化、§6 批量插入、§7 系统表监控、§8 慢查询分析 |
| [07_constraints.sql](./07_constraints.sql) | 数据更新与去重 | §1 ReplacingMergeTree、§2 CollapsingMergeTree、§3 VersionedCollapsingMergeTree、§4 Mutation、§5 Lightweight DELETE、§6 分区级操作、§7 幂等性设计 |
| [08_materialized_views.sql](./08_materialized_views.sql) | 物化视图预聚合 | §1 MV 基础、§2 SummingMT 预聚合、§3 AggregatingMT + *State、§4 多级聚合、§5 实时统计、§6 MV vs Projection 对比 |
| [09_dictionaries.sql](./09_dictionaries.sql) | 字典加速 | §1 字典创建、§2 HASHED/CACHE/FLAT 布局、§3 dictGet 用法、§4 字典加速 JOIN、§5 字典刷新策略、§6 字典监控 |

---

## 9. 常见误区与最佳实践

### 误区

1. **用 `FINAL` 解决所有去重问题** → `FINAL` 性能差（查询时触发合并），应优先用 `argMax(col, version)` 手动去重，低峰期 `OPTIMIZE TABLE FINAL`。
2. **主键索引能加速所有列查询** → 主键只对 ORDER BY 列有效。非排序列查询要靠跳数索引。
3. **小批量高频写入（每秒几百次 INSERT）** → part 爆炸，触发 "Too many parts"。应批量写（1 万~10 万行/次）或用 `async_insert`。
4. **分布式表当本地表 JOIN** → 分布式 JOIN 会广播全表，慢。用 `GLOBAL JOIN` 或字典替代。
5. **`count(*)` 比 `count()` 慢** → CH 中两者等价，但 `count()` 是惯用写法。
6. **物化视图用 `sum` 而非 `sumState`** → 无法二次聚合，预聚合链断裂。详见 §6.4。
7. **用 `//` 注释** → CH 只支持 `--` 注释，`//` 会语法错误。
8. **在 `ReplicatedMergeTree()` 不加括号** → 新版要求 `ReplicatedMergeTree()` 带括号（即使为空，用默认宏路径）。
9. **`formatDateTime(d, '%A')` 取星期名** → CH 不支持 `%A`/`%B`，用 `dateName('weekday', d)`。
10. **小写 `md5`/`sha256`** → CH 函数名大小写敏感，必须 `MD5`/`SHA256` 大写。

### 最佳实践

1. **生产环境铁律**：`Replicated*` 引擎 + `ON CLUSTER 'treasurycluster'` + 独立数据库（如 `base_test`）。
2. **ORDER BY 设计**：高基数过滤列在前，时间列在后。如 `ORDER BY (user_id, event_time)`。
3. **分区策略**：按月分区（`toYYYYMM`），单分区 50-100GB。分区数 < 100。
4. **写入优化**：批量写（≥1 万行/次）+ `async_insert` + `Buffer` 表缓冲高频小写。
5. **去重查询**：`SELECT argMax(col, version) FROM t GROUP BY pk` 比 `FINAL` 快 10x。
6. **预聚合三件套**：明细表（MergeTree）+ MV（AggregatingMergeTree + `*State`）+ 查询（`*Merge`）。
7. **JOIN 优化**：右表小（<内存）+ `GLOBAL JOIN` + 字典替代维度表 JOIN。
8. **监控**：`system.parts`（part 数量）、`system.replicas`（复制延迟）、`system.merges`（合并状态）、`system.query_log`（慢查询）。

---

## 10. 自测题（理解检查点）

完成本章后，应能回答：

1. MergeTree 的 part 合并是同步还是异步？这导致了什么现象（与 ReplacingMergeTree 去重的关系）？
2. 稀疏索引的 `index_granularity` 默认是多少？调小它有什么利弊？
3. `ReplicatedMergeTree()` 不带参数为什么也能工作？背后的宏机制是什么？
4. 分布式表查询时，聚合是在分片做还是协调节点做？为什么用 `*State` 能优化这个过程？
5. `ReplacingMergeTree` 的 `FINAL` 和 `argMax(col, version)` 哪个性能好？为什么？
6. 跳数索引的 `set` 和 `bloom_filter` 分别适合什么数据特征？
7. 物化视图预聚合为什么必须用 `sumState` 而非 `sum`？用 `sum` 会导致什么问题？
8. 字典加速 JOIN 比直接 JOIN 快多少？什么场景下字典不适用？
9. `CollapsingMergeTree` 的 sign 机制如何实现"增量更新"？查询时为什么要 `sum(col * sign)`？
10. 为什么 ClickHouse 不支持高频 UPDATE？Mutation（ALTER UPDATE）是如何实现的？

答案线索均在本 README 及配套 SQL 文件中。

---

## 11. 关联章节

- [04-functions](../04-functions/README.md) —— 聚合状态函数 `*State`/`*Merge` 详解（本章 §6.4 的原理基础）
- [03-engines](../03-engines/README.md) —— MergeTree 家族引擎完整对比
- [16-principle](../16-principle/README.md) —— 向量化执行、查询管道底层原理
- [11-performance](../11-performance/README.md) —— 查询性能调优进阶
- [10-date-update](../10-date-update/README.md) —— 日期函数、数据更新策略

---

## 12. 参考资源

- [ClickHouse MergeTree 引擎](https://clickhouse.com/docs/en/engines/table-engines/mergetree-family/mergetree)
- [ReplicatedMergeTree 复制表](https://clickhouse.com/docs/en/engines/table-engines/mergetree-family/replication)
- [Distributed 分布式表](https://clickhouse.com/docs/en/engines/table-engines/special/distributed)
- [稀疏索引与跳数索引](https://clickhouse.com/docs/en/guides/best-practices/sparse-primary-indexes)
- [物化视图](https://clickhouse.com/docs/en/sql-reference/statements/create/view#materialized-view)
- [字典](https://clickhouse.com/docs/en/sql-reference/dictionaries)
- [数据类型](https://clickhouse.com/docs/en/sql-reference/data-types)
