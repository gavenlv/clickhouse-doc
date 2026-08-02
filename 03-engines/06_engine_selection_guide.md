# ClickHouse 表引擎选型实战手册（专家级）

> 本文是 03-engines 章节的"实战收尾篇"。README.md 讲透原理，本文讲透"选型决策"——为什么选 A 不选 B、错误选型会怎样、配套可运行 SQL 如何验证。
>
> 配套可运行 SQL：[06_engine_selection_guide_examples.sql](./06_engine_selection_guide_examples.sql)（已集群验证零错误，CH 25.12.1.649，treasurycluster 单分片 2 副本）。
>
> 读完本文你应能：① 拿到业务需求 30 秒内锁定引擎；② 识别"看似合理实则灾难"的选型错误；③ 写出符合生产规范的 DDL；④ 解释每个选型决策背后的存储/查询/合并机制。

---

## 0. 选型心智模型（先看这个）

ClickHouse 引擎选型不是"看表格打勾"，而是**三个维度的权衡**：

| 维度 | 关键问题 | 影响什么 |
|------|----------|----------|
| **存储语义** | 数据是只追加？需要去重？需要更新？需要预聚合？ | 决定用哪个 MergeTree 变体 |
| **可用性语义** | 单机够用？需要副本？副本几份？是否需要强一致？ | 决定是否 Replicated* + quorum 设置 |
| **拓扑语义** | 数据量超过单机容量？需要跨节点并行查询？ | 决定是否 Distributed + 分片键设计 |

**核心心智模型**：
```
业务需求
   │
   ├─→ 存储语义 ─→ MergeTree 变体（6 选 1）
   │                  ↓
   ├─→ 可用性语义 ─→ 是否加 Replicated（+ Keeper 协调）
   │                  ↓
   ├─→ 拓扑语义 ─→ 是否套 Distributed（+ 分片键）
   │                  ↓
   └─→ 最终 DDL = Replicated*MergeTree 变体 + （可选）Distributed 外壳
```

**生产铁律**：99% 的生产表最终形态是 `Replicated<X>MergeTree` + （大数据量时）`Distributed` 外壳。非 Replicated 的 MergeTree 仅用于测试，Log 系列仅用于临时表。

---

## 1. MergeTree 家族选型：6 选 1 的本质

### 1.1 决策核心：数据更新模式

MergeTree 家族 6 个变体的本质差异是**"合并时对同主键行做什么"**：

| 变体 | 合并时同主键行的处理 | 适用数据更新模式 | 不适用场景 |
|------|----------------------|------------------|------------|
| **MergeTree** | 保留所有行 | 只追加（append-only）日志/事件 | 任何需要去重/更新的场景 |
| **ReplacingMergeTree(ver)** | 保留 ver 最大（或最新）的一行 | 状态快照表（用户最新状态、商品最新价格） | 高频更新、强实时去重 |
| **SummingMergeTree** | 数值列 SUM，非数值列取首行 | 加法指标预聚合（日 GMV、日 PV） | 平均值/去重数/分位数 |
| **AggregatingMergeTree** | AggregateFunction 列状态 merge | 任意聚合预聚合（UV、P99、TopK） | 不愿写 *State/*Merge 的团队 |
| **CollapsingMergeTree(sign)** | sign(+1/-1) 配对抵消 | 流式增量计数器（库存、余额） | 乱序写入、sign 非镜像 |
| **VersionedCollapsingMergeTree(sign, ver)** | 按 ver 排序后 sign 配对抵消 | 乱序写入的增量计数器 | 不需要乱序容错时（多余开销） |

### 1.2 为什么"不立即去重/聚合"是最大陷阱

所有 MergeTree 变体的去重/聚合都**只在合并（merge）时发生**，而合并是后台异步的：
- 写入后立即查询，会看到"重复行"或"未聚合的明细"
- 必须用 `FINAL` 关键字（查询时强制合并，**性能差 2-10 倍**）或 `OPTIMIZE TABLE ... FINAL`（同步触发合并，**阻塞写入**）
- **生产推荐**：查询时用 `argMax + GROUP BY`（去重）或 `sum + GROUP BY`（求和）替代 `FINAL`

**为什么这样设计**：ClickHouse 优先写入吞吐量。如果每次写入都立即去重，需要全表扫描或全局索引，吞吐量会下降 100 倍。异步合并是" eventual consistency"的存储层体现。

### 1.3 选型反例（错误选型会怎样）

| 错误选型 | 灾难后果 | 正确选型 |
|----------|----------|----------|
| 用 MergeTree 存用户状态（需要更新） | 历史状态全部保留，查询结果混乱 | ReplacingMergeTree(version) |
| 用 ReplacingMergeTree 存库存变动 | 只保留最新库存，丢失历史变动 | CollapsingMergeTree(sign) |
| 用 SummingMergeTree 存 UV（去重数） | sum(1) 把重复用户算成多个，UV 错误 | AggregatingMergeTree + uniqState |
| 用 SummingMergeTree 存平均值 | sum(amount)/sum(count) 不能从 sum(amount) 还原 | AggregatingMergeTree + avgState |
| 用 CollapsingMergeTree 但 sign 写成差值 | 合并前后结果不一致，数据永久错误 | sign=-1 行必须镜像旧值（不是差值） |
| 用 AggregatingMergeTree 但 SELECT 状态列 | 返回二进制乱码，无法解读 | 必须 `*Merge(state_col)` 还原 |
| 用 ReplacingMergeTree 但没有 version 列 | "最新"按插入顺序，乱序写入时去重错误 | 加 version 列（时间戳或自增 ID） |

### 1.4 配套实验（已验证）

详见 [06_engine_selection_guide_examples.sql](./06_engine_selection_guide_examples.sql)：
- §3 演示 ReplacingMergeTree 去重 + argMax 替代 FINAL
- §4 演示 SummingMergeTree 加法预聚合
- §5 演示 CollapsingMergeTree 正确的 sign 镜像写法（含错误反例注释）
- §6 演示 TTL 自动过期

---

## 2. Replicated vs 非 Replicated：可用性决策

### 2.1 决策核心：能否容忍数据丢失

| 维度 | MergeTree（非复制） | Replicated*MergeTree |
|------|---------------------|----------------------|
| 副本数 | 1 | N（通常 2-3） |
| 磁盘故障 | **数据丢失** | 副本仍在 |
| 写入延迟 | 低（无 ZK 协调） | 略高（ZK 日志写入） |
| 读取扩展性 | 单节点 | 多副本负载均衡 |
| 运维复杂度 | 低（无 Keeper） | 高（需 Keeper 集群） |
| 生产推荐 | ❌ 仅测试 | ✅ 生产标配 |

### 2.2 异步复制的"陷阱"

Replicated* 的复制是**异步**的：
- 写入成功 ≠ 所有副本已落盘
- 副本宕机时，未同步的 Part 会丢失（如果该副本是写入副本）
- **强一致需求**：`SETTINGS insert_quorum=2, select_sequential_consistency=1`
  - quorum=2：至少 2 个副本写入成功才返回
  - select_sequential_consistency=1：查询必须读到最新已 quorum 的数据

### 2.3 Keeper 路径陷阱（高频踩坑）

Replicated* 表的 ZK 路径默认基于表名：
```
/clickhouse/tables/{shard}/{database}/{table}
```
**陷阱**：不同库的同名表若 ZK 路径相同会冲突 → "Missing columns" 报错。

**规避**：
- 方案 1：不同库用不同表名（如 `events_log` vs `events`）
- 方案 2：显式指定 ZK 路径 `ReplicatedMergeTree('/clickhouse/tables/{shard}/db_a/events', '{replica}')`

详见 [02_replicated_engines.sql](./02_replicated_engines.sql) §1 和 [06_engine_selection_guide_examples.sql](./06_engine_selection_guide_examples.sql) §2。

---

## 3. Distributed 表：分片决策

### 3.1 决策核心：数据量与查询并行度

| 数据量 | 拓扑选择 | 理由 |
|--------|----------|------|
| < 单机磁盘容量 | 单分片 2 副本 | 无需分片，副本足够可用性 |
| > 单机磁盘容量但 < 5TB | 2-4 分片 × 2 副本 | 分片提升容量与并行度 |
| > 5TB 或高 QPS | 5+ 分片 × 2-3 副本 | 水平扩展 |

### 3.2 分片键设计的本质

分片键决定数据如何分布到各分片：
- **目标**：① 查询能剪枝（只扫必要分片） ② 数据均匀分布
- **常见错误**：用 `rand()` 分片 → 所有查询都广播到全部分片，失去剪枝能力

**分片键选型**：
```sql
-- 查询总按 user_id 过滤 → 用 user_id 分片（同用户数据同分片，查询剪枝）
ENGINE = Distributed(cluster, db, local_table, user_id)

-- 查询总按时间范围过滤 → 用 intHash32(toYYYYMM(timestamp)) 分片（按月分桶）
ENGINE = Distributed(cluster, db, local_table, intHash32(toYYYYMM(timestamp)))

-- 无明确查询模式 → 用 rand() 或 intHash32(id)（均匀分布但无剪枝）
ENGINE = Distributed(cluster, db, local_table, rand())
```

### 3.3 两阶段聚合的原理（为什么需要 sumState/sumMerge）

分布式聚合必须两阶段：
1. **本地聚合**：每个分片本地聚合 → 得到中间状态（不是最终值）
2. **全局合并**：合并各分片的中间状态 → 最终值

**为什么不能直接 sum 再 sum**：
- `sum(amount)` → 各分片 `sum` → 合并 `sum(sum)` ✓（加法可合并）
- `avg(amount)` → 各分片 `avg` → 合并 `avg(avg)` ✗（错误！分片行数不同）
- `uniq(user_id)` → 各分片 `uniq` → 合并 `uniq(uniq)` ✗（重复用户跨分片）

**正确做法**：用 `*State` 物化中间态，用 `*Merge` 合并：
```sql
-- 错误（分布式 avg 不正确）
SELECT avg(amount) FROM distributed_table;

-- 正确（用 quantileState/quantileMerge 或 avgState/avgMerge）
SELECT avgMerge(avg_state) FROM (
    SELECT avgState(amount) AS avg_state FROM local_table GROUP BY dim
);

-- UV 跨分片去重
SELECT uniqMerge(uv_state) FROM (
    SELECT uniqState(user_id) AS uv_state FROM local_table GROUP BY dim
);
```

详见 [16-principle/08_sharding.sql](../16-principle/08_sharding.sql) 和 [04-functions/README.md](../04-functions/README.md) §3。

---

## 4. Log 系列选型：临时表的三选一

### 4.1 决策核心：数据量 + 是否需要并发读

| 引擎 | 压缩 | 并发读 | 列式 | 适用数据量 | 场景 |
|------|------|--------|------|------------|------|
| TinyLog | ❌ | ❌ | ✅ | < 1MB | 一次性中间结果 |
| StripeLog | LZ4 | ✅ | ❌（条带） | < 100MB | 小日志、需压缩 |
| Log | LZ4 | ✅ | ✅ | < 1GB | 小字典、并发分析 |
| MergeTree | LZ4/ZSTD | ✅ | ✅ | 任意 | **生产标配** |

### 4.2 为什么生产不用 Log 系列

Log 系列设计目标是"极简临时存储"，**没有**：
- 主键索引（查询全表扫描）
- 分区（无法按时间剪枝）
- 复制（宕机丢数据）
- UPDATE/DELETE（只能 DROP 重建）

**生产铁律**：99% 的生产表用 ReplicatedMergeTree 系列。Log 系列只用于临时表/字典表，且必须有 TTL 或定期清理。

详见 [03_log_engines.sql](./03_log_engines.sql)。

---

## 5. 集成引擎选型：何时用、何时不用

### 5.1 核心原则：集成引擎不是"加速器"

集成引擎（File/S3/MySQL/PG/Kafka/...）**不存数据**，每次查询都实时拉取外部源：
- 查询性能 = 网络延迟 + 远端查询性能（无法用 CH 的索引/压缩优化）
- 适合：联邦查询、临时探查、ETL 中转
- **不适合**：高频查询、大数据量、需要事务

### 5.2 集成引擎 vs 表函数

| 维度 | 引擎（CREATE TABLE） | 表函数（SELECT FROM fn()） |
|------|---------------------|--------------------------|
| 持久化 | ✅ 元数据存 system.tables | ❌ 仅当前查询 |
| 复用 | ✅ 多个查询共享 | ❌ 每次重写 |
| 权限管理 | ✅ 可 GRANT | ❌ 需用户级权限 |
| 适合场景 | 高频联邦查询 | 临时探查、ETL 一次性 |

### 5.3 集成引擎选型决策表

| 数据源 | 推荐引擎/函数 | 关键限制 | 生产用法 |
|--------|---------------|----------|----------|
| 本地文件 | File / file() | 受 user_files_path 限制 | ETL 中转 |
| 远程 HTTP | URL / url() | 受网络延迟影响 | 临时探查 |
| S3/GCS | S3 / s3() | 需 access_key/secret | 数据湖查询 |
| HDFS | HDFS / hdfs() | 需 Hadoop 客户端 | 传统数据湖 |
| MySQL | MySQL / mysql() | 只读，性能受限于 MySQL | 小表联邦 |
| PostgreSQL | PostgreSQL / postgresql() | 只读，PG 表必须存在 | 小表联邦 |
| Redis | Redis / redis() | 仅 KV，不支持复杂查询 | 小字典补全 |
| Kafka | Kafka | 仅消费，需物化视图落盘 | 实时事件流 |
| 通用 JDBC | JDBC | 性能差，仅兼容性场景 | 非 MySQL/PG 数据库 |

### 5.4 生产铁律

1. **高频查询的表必须落本地 MergeTree**，不要直接查外部源
2. **S3 数据用 Parquet + 分区路径**（按年月分目录）+ glob 模式查询
3. **Kafka 必须 MV 落盘**，引擎表本身不存数据
4. **MySQL/PG 联邦只用于小表 JOIN**，大表必须 ETL 导入
5. **所有集成引擎查询都要加超时**（`settings max_execution_time`）

详见 [04_integration_engines.sql](./04_integration_engines.sql)。

---

## 6. 特殊引擎选型：按场景匹配

### 6.1 MaterializedView（物化视图）

**本质**：INSERT 触发的自动 ETL，把源表数据按 SELECT 逻辑写入目标表。

| 场景 | 是否用 MV | 替代方案 |
|------|-----------|----------|
| 预聚合（明细→日表） | ✅ 强烈推荐 | 手动 ETL 调度 |
| 数据分发（一份数据多份 schema） | ✅ 推荐 | 多次 INSERT |
| 实时转换（JSON 解析、字段重命名） | ✅ 可用 | 写入时转换 |
| 实时 JOIN 维表 | ❌ MV 不支持 JOIN 触发 | 用字典或定时 JOIN |
| UPDATE 触发 | ❌ MV 只响应 INSERT | Mutation + 视图 |

**陷阱**：MV 是"INSERT 触发，非实时，非 UPDATE 触发"。源表 UPDATE 不会触发 MV。

### 6.2 Distributed（分布式表）

**本质**：查询路由层，不存数据。把查询拆分到各分片本地表，合并结果。

**何时用**：
- 数据量超过单机容量
- 需要跨节点并行查询加速
- 需要统一查询入口（屏蔽分片细节）

**何时不用**：
- 数据量小（< 单机容量）
- 写入为主、查询少（直接写本地表更简单）

### 6.3 Buffer（缓冲表）

**本质**：内存缓冲区，定时或定量刷盘到目标表。

**何时用**：高频小批量写入（每秒数千次 INSERT）

**陷阱**：宕机会丢缓冲数据！生产用要权衡 RPO。

### 6.4 Merge / Set / Join / Null / View

| 引擎 | 场景 | 注意 |
|------|------|------|
| Merge | 多张同结构表合并查询 | 只读，不能写入 |
| Set | `IN` 查询加速 | 只能在内存，重启丢 |
| Join | `JOIN` 加速 | 同 Set，重启丢 |
| Null | 测试/丢弃数据 | 数据流过即丢 |
| View | 数据抽象（不存数据） | 普通视图，每次查询原表 |

---

## 7. 完整选型决策树（生产版）

```
业务需求
   │
   ├─ 数据量 < 1GB 且临时？
   │    ├─ 是 → TinyLog/StripeLog/Log（按 §4.1 选）
   │    └─ 否 → 继续
   │
   ├─ 需要访问外部数据源？
   │    ├─ 是 → 集成引擎（按 §5.3 选）+ ETL 落地 MergeTree
   │    └─ 否 → 继续
   │
   ├─ 数据更新模式？
   │    ├─ 只追加 → MergeTree
   │    ├─ 需要去重（状态快照）→ ReplacingMergeTree(version)
   │    ├─ 加法预聚合 → SummingMergeTree
   │    ├─ 复杂聚合（UV/P99/TopK）→ AggregatingMergeTree + *State
   │    ├─ 流式增量计数器（库存/余额）→ CollapsingMergeTree(sign)
   │    └─ 乱序写入的增量计数器 → VersionedCollapsingMergeTree(sign, version)
   │
   ├─ 需要高可用（生产）？
   │    └─ 是 → 加 Replicated* 前缀（默认选择）
   │
   ├─ 数据量 > 单机容量？
   │    └─ 是 → 加 Distributed 外壳 + 分片键设计（按 §3.2）
   │
   ├─ 需要预聚合加速？
   │    └─ 是 → MaterializedView + 目标表（AggregatingMergeTree）
   │
   ├─ 高频小批量写入？
   │    └─ 是 → Buffer 表 + 目标 MergeTree
   │
   └─ 最终 DDL = Replicated*MergeTree 变体 + （可选）Distributed 外壳
                  + （可选）MaterializedView 预聚合
                  + （可选）TTL 生命周期
```

---

## 8. 性能基准（参考值，非实测）

> 以下数据基于公开基准与生产经验，**仅供选型参考**。实际性能取决于 schema、查询模式、硬件。配套 SQL 中有可运行的对比实验。

### 8.1 写入性能（相对值，MergeTree=1.0）

| 引擎 | 相对写入性能 | 原因 |
|------|--------------|------|
| TinyLog | 0.4x | 无压缩，单线程 |
| Log | 0.7x | 有压缩，但无 Part 机制 |
| MergeTree | 1.0x | 基准 |
| ReplacingMergeTree | 0.95x | 额外 version 排序 |
| ReplicatedMergeTree | 0.9x | ZK 日志写入开销 |
| SummingMergeTree | 1.0x | 合并时求和，写入无差异 |

### 8.2 查询性能（相对值，MergeTree=1.0）

| 引擎 | 相对查询性能 | 原因 |
|------|--------------|------|
| TinyLog | 0.1x | 全表扫描，无索引 |
| Log | 0.3x | 全表扫描，但有压缩 |
| MergeTree | 1.0x | 基准（稀疏索引 + 列式） |
| ReplacingMergeTree | 0.9x | FINAL 模式下 0.3-0.5x |
| AggregatingMergeTree | 5-50x | 预聚合后扫描量减少 10-100 倍 |
| Distributed（N 分片） | N×（理想） | 并行度提升 |

### 8.3 存储压缩比（相对值，原始=1.0）

| 引擎 | 压缩比 | 原因 |
|------|--------|------|
| TinyLog | 1.0x | 无压缩 |
| StripeLog | 2.5x | LZ4 |
| Log | 3.0x | LZ4 + 列式 |
| MergeTree | 7-10x | LZ4/ZSTD + 列式 + 排序 |
| AggregatingMergeTree | 100-1000x | 预聚合后行数大幅减少 |

---

## 9. 生产 DDL 模板（直接复制修改）

### 9.1 事件日志表（只追加 + 高可用 + 分片）

```sql
-- 本地表（每个分片创建）
CREATE TABLE events_local ON CLUSTER '{cluster}' (
    event_id UInt64,
    user_id UInt64,
    event_type LowCardinality(String),  -- 低基数用 LowCardinality 节省 5-10x 空间
    event_data String CODEC(ZSTD(3)),   -- 高压缩比字符串
    timestamp DateTime
) ENGINE = ReplicatedMergeTree()
PARTITION BY toYYYYMM(timestamp)        -- 按月分区（推荐）
ORDER BY (user_id, timestamp)           -- 查询模式：WHERE user_id=? AND timestamp>?
TTL timestamp + INTERVAL 90 DAY;        -- 90 天自动过期

-- 分布式表（查询入口）
CREATE TABLE events_distributed ON CLUSTER '{cluster}' AS events_local
ENGINE = Distributed('{cluster}', currentDatabase(), events_local, user_id);
```

### 9.2 状态快照表（去重 + 高可用）

```sql
CREATE TABLE user_state ON CLUSTER '{cluster}' (
    user_id UInt64,
    state LowCardinality(String),
    last_updated DateTime,
    version UInt64                       -- 必须有 version 列，否则乱序写入去重错误
) ENGINE = ReplicatedReplacingMergeTree(version)
PARTITION BY toYYYYMM(last_updated)
ORDER BY user_id;

-- 安全查询（不用 FINAL，性能好）
SELECT
    user_id,
    argMax(state, version) AS state,     -- argMax 取 version 最大的 state
    max(version) AS version
FROM user_state
GROUP BY user_id;
```

### 9.3 加法指标预聚合表（日 GMV）

```sql
CREATE TABLE daily_sales ON CLUSTER '{cluster}' (
    date Date,
    product_id UInt32,
    country LowCardinality(String),
    amount Decimal(10, 2),
    order_count UInt32
) ENGINE = ReplicatedSummingMergeTree
PARTITION BY toYYYYMM(date)
ORDER BY (date, product_id, country);

-- 安全查询（合并完成与否都正确）
SELECT
    date,
    product_id,
    sum(amount) AS total_amount,
    sum(order_count) AS total_orders
FROM daily_sales
GROUP BY date, product_id;
```

### 9.4 复杂聚合预聚合表（UV/P99）

```sql
CREATE TABLE user_metrics ON CLUSTER '{cluster}' (
    user_id UInt64,
    event_date Date,
    page_views AggregateFunction(count),
    distinct_pages AggregateFunction(uniq, String),
    latency_p99 AggregateFunction(quantile(0.99), Float64)
) ENGINE = ReplicatedAggregatingMergeTree
PARTITION BY toYYYYMM(event_date)
ORDER BY (user_id, event_date);

-- 写入：用 *State 物化中间态
INSERT INTO user_metrics
SELECT
    user_id,
    toDate(timestamp) AS event_date,
    countState() AS page_views,
    uniqState(page_url) AS distinct_pages,
    quantileState(0.99)(latency_ms) AS latency_p99
FROM events_local
GROUP BY user_id, toDate(timestamp);

-- 查询：用 *Merge 还原
SELECT
    user_id,
    event_date,
    countMerge(page_views) AS views,
    uniqMerge(distinct_pages) AS uv,
    quantileMerge(latency_p99) AS p99
FROM user_metrics
GROUP BY user_id, event_date;
```

### 9.5 流式增量计数器（库存）

```sql
CREATE TABLE inventory ON CLUSTER '{cluster}' (
    product_id UInt64,
    quantity Int32,
    sign Int8,                           -- +1 新增，-1 取消
    updated_at DateTime
) ENGINE = ReplicatedCollapsingMergeTree(sign)
PARTITION BY toYYYYMM(updated_at)
ORDER BY product_id;

-- 【关键】sign=-1 行的值必须镜像旧值，不是差值！
-- 初始：插 (101, 100, +1)
-- 更新到 90：插 (101, 100, -1) + (101, 90, +1)
-- 错误：插 (101, 10, -1)  -- 这是差值，不是镜像！

-- 安全查询
SELECT
    product_id,
    sum(quantity * sign) AS current_quantity
FROM inventory
GROUP BY product_id;
```

### 9.6 乱序写入的增量计数器

```sql
CREATE TABLE inventory_safe ON CLUSTER '{cluster}' (
    product_id UInt64,
    quantity Int32,
    sign Int8,
    version UInt64,                      -- 版本号，乱序时按 version 排序后折叠
    updated_at DateTime
) ENGINE = ReplicatedVersionedCollapsingMergeTree(sign, version)
PARTITION BY toYYYYMM(updated_at)
ORDER BY product_id;

-- 即使 sign=-1 先于 sign=+1 到达，version 保证合并正确
```

---

## 10. 选型自测题（10 道）

1. 日志事件表，每天 10 亿行，需要保留 90 天，查询总按 user_id + 时间范围。选什么引擎？
2. 用户状态表，需要记录最新状态，每天更新 10 次。选什么引擎？如何查询？
3. 日 GMV 报表，按 (日期, 商品, 国家) 聚合。选什么引擎？为什么不能用 avg？
4. 实时 UV 监控，跨 4 个分片。如何保证 UV 正确？
5. 库存表，每秒 1000 次变动。选 CollapsingMergeTree 还是 VersionedCollapsingMergeTree？为什么？
6. Kafka 实时事件流，每秒 10 万条。如何落地 CH？只用 Kafka 引擎行不行？
7. MySQL 里有 1 亿行用户元信息，CH 有 100 亿行事件日志。如何 JOIN？
8. 数据量 500GB，单机磁盘 1TB。需要分片吗？需要几个副本？
9. ReplacingMergeTree 写入后立即查询发现有重复行。是 bug 吗？如何解决？
10. SummingMergeTree 的非数值列"消失"了。为什么？如何避免？

<details>
<summary>答案线索</summary>

1. `ReplicatedMergeTree` + 按月分区 + `ORDER BY (user_id, timestamp)` + TTL 90 天
2. `ReplicatedReplacingMergeTree(version)` + 查询用 `argMax(state, version) GROUP BY user_id`
3. `ReplicatedSummingMergeTree` + `ORDER BY (date, product_id, country)`；avg 不可加和还原，要用 AggregatingMergeTree + avgState
4. 每分片 `uniqState(user_id)` → Distributed 表 `uniqMerge(state)`（HLL 算法可跨分片合并）
5. 若写入有序（sign=+1 先于 sign=-1）用 CollapsingMergeTree；若乱序用 VersionedCollapsingMergeTree
6. Kafka 引擎表 + 物化视图 + ReplicatedMergeTree 目标表；只用 Kafka 引擎会丢数据（引擎不存数据）
7. 把 MySQL 表 ETL 导入 CH 作字典表，用 `dictGet` 而非 JOIN；或用 MySQL 引擎联邦（仅小表）
8. 不需要分片（500GB < 1TB）；2 副本保证可用性
9. 不是 bug。去重只在 merge 时发生。用 `FINAL`（慢）或 `argMax + GROUP BY`（快）
10. SummingMergeTree 非数值列取首行值（不可预测）。把非数值列放进 ORDER BY 即可保留

</details>

---

## 11. 常见误区与纠正

| 误区 | 纠正 |
|------|------|
| "ReplacingMergeTree 自动去重" | 只在 merge 时去重，查询需 FINAL 或 argMax |
| "SummingMergeTree 能算 UV" | 不能，UV 必须用 AggregatingMergeTree + uniqState |
| "CollapsingMergeTree 的 sign 是差值" | sign=-1 行必须镜像旧值，不是差值 |
| "Distributed 表存数据" | 不存，只是查询路由层 |
| "MaterializedView 实时" | INSERT 触发，非实时，非 UPDATE 触发 |
| "Log 系列适合生产小表" | 不适合，无复制无索引，宕机丢数据 |
| "集成引擎能加速查询" | 不能，每次查询实时拉取外部源 |
| "FINAL 是性能优化" | 是性能杀手，2-10 倍慢，应用 argMax 替代 |
| "分区越细越好" | 分区过多导致 Part 爆炸，合并压力大。按月是默认推荐 |
| "LowCardinality 万能" | 基数 > 1万 时反效果，按列基数判断 |

---

## 12. 与配套 SQL 的对应关系

| 本文章节 | 配套 SQL 文件 | 实验内容 |
|----------|---------------|----------|
| §1 MergeTree 变体选型 | [01_mergetree_engines.sql](./01_mergetree_engines.sql) | 6 个变体的写入/合并/查询对比 |
| §1 MergeTree 变体选型 | [06_engine_selection_guide_examples.sql](./06_engine_selection_guide_examples.sql) | 生产场景的选型实战 |
| §2 Replicated 决策 | [02_replicated_engines.sql](./02_replicated_engines.sql) | 复制机制 + 健康监控 + sign 镜像 |
| §3 Distributed 决策 | [16-principle/08_sharding.sql](../16-principle/08_sharding.sql) | 两阶段聚合 + GLOBAL JOIN |
| §4 Log 系列选型 | [03_log_engines.sql](./03_log_engines.sql) | 三引擎存储结构对比实验 |
| §5 集成引擎选型 | [04_integration_engines.sql](./04_integration_engines.sql) | File/file()/url()/S3 注释 + ETL 模板 |
| §6 特殊引擎选型 | [05_special_engines.sql](./05_special_engines.sql) | Distributed/MV/Buffer/Dictionary |
| §9 生产 DDL 模板 | [06_engine_selection_guide_examples.sql](./06_engine_selection_guide_examples.sql) | 5 种生产场景的完整 DDL |

---

## 总结

选型不是"看表格打勾"，而是三个维度的权衡：**存储语义（MergeTree 变体）+ 可用性语义（Replicated）+ 拓扑语义（Distributed）**。

**生产铁律**：
1. 99% 的生产表用 `Replicated*MergeTree` 系列
2. 大数据量加 `Distributed` 外壳 + 合理分片键
3. 预聚合用 `MaterializedView + AggregatingMergeTree`
4. 永远不要用 Log 系列存业务数据
5. 集成引擎只用于 ETL 中转，不用于高频查询
6. 所有表必须有 TTL 或分区清理机制
