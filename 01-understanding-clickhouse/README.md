# 01 - 理解 ClickHouse（专家级详解）

> 本章是 ClickHouse 的"地基"。读完本章，你应能：解释 ClickHouse 为什么快、列式存储与行式存储的本质差异、MergeTree 的 Part/排序键/稀疏索引/合并机制、分片副本与 Keeper 的协同原理，并亲手创建第一张 `ReplicatedMergeTree` 复制表验证数据同步。
>
> 配套可运行 SQL（共 6 个文件，已全部在 `treasurycluster` CH 25.12.1.649 集群验证零错误）：
> [01_what_is_clickhouse.sql](./01_what_is_clickhouse.sql) · [02_column_oriented.sql](./02_column_oriented.sql) · [03_mergeTree_engine.sql](./03_mergeTree_engine.sql) · [04_basic_sql.sql](./04_basic_sql.sql) · [05_cluster_concepts.sql](./05_cluster_concepts.sql) · [06_first_replicated_table.sql](./06_first_replicated_table.sql)

---

## 1. 本章解决什么问题（Why）

ClickHouse 的设计哲学与 MySQL/PostgreSQL 截然不同，初学者常踩的坑不是语法，而是**心智模型**没建立。本章用 6 节可运行实验回答以下核心疑问：

| 痛点 | 本章如何解答 |
|------|--------------|
| 同样是数据库，为什么 ClickHouse 单机就能扫亿级数据？ | §2.1 OLAP vs OLTP 定位 + §2.2 四大加速原理拆解 |
| 列式存储到底"列"在哪？为什么压缩率能到 5-10 倍？ | §3.1 行式 vs 列式 ASCII 图 + §3.2 LZ4/ZSTD 压缩原理 |
| 向量化执行是什么？和批处理有什么区别？ | §3.3 SIMD 向量化执行图解 |
| MergeTree 的 ORDER BY 和 MySQL 索引是一回事吗？ | §4.1 Part 概念 + §4.3 稀疏索引（granule 8192）|
| `ReplacingMergeTree` 真的会"自动去重"吗？为什么查出来还有重复？ | §4.4 合并(merge)机制 + FINAL 真相 |
| 分片和副本到底差在哪？Keeper 是干嘛的？ | §5.1 分片 vs 副本决策表 + §5.2 Raft 协议简介 |
| 为什么分布式表叫"查询路由"而不存数据？ | §5.3 Distributed 引擎工作流图解 |
| `ReplicatedMergeTree` 第一个参数那个神秘路径是什么？ | §6 复制表实战 + ZooKeeper 路径含义 |

---

## 2. ClickHouse 定位：为什么它能"秒扫亿行"

### 2.1 OLAP vs OLTP —— 决定一切设计差异的根本定位

```
                  ┌─────────────────────────────────────────┐
                  │           数据库系统按负载分类             │
                  └─────────────────────────────────────────┘
                                    │
                ┌───────────────────┴───────────────────┐
                ▼                                        ▼
        ┌───────────────┐                       ┌───────────────┐
        │   OLTP         │                       │   OLAP         │
        │ (事务处理)      │                       │ (分析处理)      │
        ├───────────────┤                       ├───────────────┤
        │ MySQL/PG/Oracle│                       │ ClickHouse     │
        │ 行式存储        │                       │ Snowflake      │
        │ B+树索引       │                       │ BigQuery/Redshift│
        │ ACID 强事务    │                       │ 列式存储       │
        │ 单行点查快      │                       │ 大规模聚合快   │
        └───────────────┘                       └───────────────┘
        典型：银行转账                            典型：日报、漏斗、留存
        QPS：万级                                扫描行数：亿级/查询
        单查询行数：1-100                         单查询时间：100ms-10s
```

**为什么这个定位决定一切后续设计？**

| 设计选择 | OLTP 的取舍 | OLAP（ClickHouse）的取舍 |
|---------|------------|------------------------|
| 存储布局 | 行式（一行一行的元组，方便更新单行） | 列式（一列一列的向量，方便聚合整列） |
| 索引 | B+树稠密索引（每行都能 O(logN) 定位） | 稀疏索引（每 8192 行一个标记，省空间） |
| 事务 | ACID + MVCC | 不支持事务（INSERT 为主，UPDATE/DELETE 极慢） |
| 并发 | 大量短查询 | 少量长查询 + 并行扫描 |
| 写入 | 单行频繁写 | 批量写入（建议每批 1万-100万行） |
| 压缩 | 一般（行内数据类型混杂） | 极高（同列同类型，重复值多） |

### 2.2 ClickHouse 为什么快的四大支柱

```
                  ┌──────────────────────────────────────────┐
                  │      ClickHouse 单查询 100ms 拆解          │
                  └──────────────────────────────────────────┘
                                     │
        ┌──────────────┬─────────────┼─────────────┬──────────────┐
        ▼              ▼             ▼             ▼              ▼
    ① 列式存储     ② 向量化执行  ③ 数据压缩   ④ 并行扫描    ⑤ 稀疏索引
    ───────────    ──────────    ──────────    ──────────    ──────────
    只读需要的列   一次处理一批   LZ4/ZSTD     多核多线程    按 ORDER BY
    减少磁盘 IO    利用 SIMD     解压快且按需   自动并行化    跳过无关 granule
    A: SELECT      对一整列的     通常 5-10x   简单聚合      类似跳表
       sum(x)      向量做运算      压缩比        直接打满      避免 B+树
    不读 B,C 列    非常 CPU 友好                所有 CPU 核心  全表扫描代价
```

**1) 列式存储 —— 减少 IO 的根本**

行式存储读取 `SELECT sum(amount) FROM orders` 时，必须把 `id, user_id, amount, time, ...` 全部列都读出来，因为它们是行存布局。列式存储只读 `amount` 一列，IO 量直接降低一个数量级。

**2) 向量化执行 —— CPU 友好的执行模型**

传统解释器一次处理一行（switch 函数调用），ClickHouse 一次处理一批（通常一个 block 65536 行）：
```
传统逐行:     for row in rows:  amount_sum += row.amount   (慢，函数调用开销大)
向量化:        sum_vector(amounts[])                       (快，CPU SIMD 一条指令算 4-16 个 float)
```

**3) 数据压缩 —— 同类型数据天然可压缩**

列存中同一列是相同类型（如 `UInt64`、`String`），重复值/前缀非常多。ClickHouse 默认用 LZ4（快但压缩比一般），关键列可单独指定 ZSTD（压缩比更高）。

**4) 并行扫描 —— 自动利用多核**

ClickHouse 的查询计划天然并行，会自动把数据切成多个 part/stream，由多个线程同时处理。`max_threads` 控制并发度。

### 2.3 适用场景 vs 不适用场景决策表

| 场景 | 适合 ClickHouse？ | 原因 | 替代方案 |
|------|------------------|------|----------|
| 日志/事件分析 | ✅ 强烈推荐 | 海量追加、按时间范围聚合 | Elasticsearch（贵）、Doris |
| 用户行为漏斗/留存 | ✅ 强烈推荐 | `arrayJoin` + 窗口函数原生支持 | 自研 Spark |
| 时序监控指标 | ✅ 推荐 | 高压缩率 + 时间函数 | InfluxDB、TimescaleDB |
| 实时报表/Dashboard | ✅ 推荐 | 物化视图预聚合秒级响应 | Druid、Pinot |
| 用户特征宽表 | ✅ 推荐 | 列存+压缩，单表千亿行 | HBase（弱聚合） |
| 银行转账/订单事务 | ❌ 不适合 | 无 ACID 事务，UPDATE 慢 | MySQL、PostgreSQL |
| 单行点查（按 ID 取详情） | ❌ 不适合 | 没有稠密 B+树索引 | Redis、MySQL |
| 频繁 UPDATE/DELETE | ❌ 不适合 | 用 `ALTER UPDATE` 是异步重写 | MySQL |
| 高并发 OLTP（QPS 万级） | ❌ 不适合 | 单查询占满 CPU | MySQL |
| 在线 KV（key-value）查询 | ❌ 不适合 | 不是它的设计目标 | Redis |

---

## 3. 核心原理：列式存储与向量化

### 3.1 行式 vs 列式存储本质对比

```
原始数据（逻辑表）:
┌─────┬──────────┬──────┬────────┐
│ id  │ user_name │ age  │ salary │
├─────┼──────────┼──────┼────────┤
│  1  │ Alice     │  25  │ 8000   │
│  2  │ Bob       │  30  │ 12000  │
│  3  │ Charlie   │  35  │ 15000  │
└─────┴──────────┴──────┴────────┘

行式存储（MySQL/PostgreSQL）：按"行"连续存储
┌──────────────────────────────────────────────────┐
│ [1, Alice, 25, 8000] [2, Bob, 30, 12000] [3,...] │  ← 一行内多列混在一起
└──────────────────────────────────────────────────┘
查询 SELECT sum(salary)：必须读出每一整行才能取到 salary，浪费 IO

列式存储（ClickHouse）：按"列"连续存储
┌────────┬─────────────────────┬───────────┬──────────────────────┐
│ id:    │ [1, 2, 3]           │ user_name:│ [Alice, Bob, Charlie] │
│ age:   │ [25, 30, 35]        │ salary:   │ [8000, 12000, 15000]  │
└────────┴─────────────────────┴───────────┴──────────────────────┘
查询 SELECT sum(salary)：只读 salary 这一列，其他列完全跳过
```

| 维度 | 行式存储 | 列式存储 |
|------|---------|---------|
| 写入单行 | 快（追加一段） | 慢（要写到 N 个列文件） |
| 读单行所有列 | 快（连续读） | 慢（要从 N 个列拼回） |
| 聚合单列 `sum(salary)` | 慢（要读所有列） | 快（只读一列） |
| 压缩率 | 一般（同行类型混杂） | 极高（同列同类型 + 重复值） |
| 适合 | OLTP（点查/更新） | OLAP（聚合/扫描） |

### 3.2 压缩原理：为什么列式能压 5-10 倍

**核心原理**：相似数据放在一起，更容易找到重复模式。

```
salary 列（数字）原始字节:   8000 12000 15000 8000 12000 8000 8000
LZ4 算法看到模式 "8000" 重复: 存储 "8000" 一次 + 指针引用 → 大幅压缩

gender 列（字符串）:        "M" "F" "M" "M" "F" "M" "M" "F"
LowCardinality 直接存索引:   0 1 0 0 1 0 0 1  （只存 1 字节，原 8 字节）
```

ClickHouse 提供两种主要压缩算法：

| 算法 | 压缩比 | 解压速度 | 适用 |
|------|--------|---------|------|
| LZ4（默认） | 2-5x | 极快（10+ GB/s） | 大多数列，CPU 受限场景 |
| ZSTD | 5-10x | 快（1-2 GB/s） | 历史冷数据、字符串列 |
| Delta + LZ4 | 对时序数据 10x+ | 快 | 时间戳、自增 ID |

**LowCardinality 类型是列存压缩的加速器**：对于基数 < 1万 的列（如性别、城市、状态码），把 String 存为"字典索引 + 1-2 字节编码"，**体积可缩小 10-100 倍**。

### 3.3 向量化执行（Vectorized Execution）

```
传统逐行执行（解释器）:
  for row in rows:
      v = row.amount * 0.9     ← 每行一次函数调用、一次分支判断
      sum += v
  极慢：100万行 = 100万次函数调用

向量化执行（ClickHouse）:
  一次取一个 block (65536 行):
  amounts = [8000, 12000, 15000, ..., 99.99]   ← 一个连续数组
  discounted = SIMD_multiply(amounts, 0.9)       ← CPU 一条指令算 4-16 个 float
  sum = SIMD_sum(discounted)                    ← 累加也是 SIMD
  极快：100万行只需 ~15 次 SIMD 调用
```

**SIMD（单指令多数据）** 是现代 CPU 的能力：一条机器指令同时处理多个数据。列式存储天然适合 SIMD，因为同一列的数据类型一致、内存连续。

### 3.4 谁是 ClickHouse 的"亲戚"—— OLAP 数据库横评

| 维度 | ClickHouse | Snowflake | BigQuery | Doris | Druid |
|------|-----------|-----------|----------|-------|-------|
| 部署 | 自建/云 | 仅云 | 仅云 | 自建/云 | 自建/云 |
| 实时写入 | 强（高频小批量也 OK） | 弱（批量为主） | 弱（流式 API 慢） | 中 | 强 |
| 单表聚合 | 极快 | 快 | 快 | 快 | 快 |
| JOIN 性能 | 弱（建议预 JOIN） | 强 | 强 | 中 | 弱 |
| 高并发点查 | 弱 | 中 | 中 | 强 | 强 |
| 成本 | 低（自建） | 高 | 按扫描量 | 中 | 中 |
| 典型场景 | 海量明细分析 | 云数仓 | 云数仓 | 实时数仓 | 实时指标 |

---

## 4. 核心原理：MergeTree 引擎家族

### 4.1 Part 概念 —— 理解 MergeTree 的基础

```
INSERT 一次 → 生成 1 个 Part（数据片段）
                                          ┌─ Part 是磁盘上的真实目录
INSERT 1: [行1, 行2, 行3]  →  all_1_1_0/  │   内含每列的 .bin 数据文件 + .idx 索引
                                          └─ 在 system.parts 中可见
INSERT 2: [行4, 行5]       →  all_2_2_0/

后台 Merge:
   all_1_1_0 + all_2_2_0  →  all_1_2_1  (合并后大 Part)
   原小 Part 标记 inactive，最终被清理
```

**为什么这样设计？**
- 写入快：每次 INSERT 直接生成一个新 Part，无需修改已有数据
- 合并异步：后台线程慢慢合并小 Part → 大 Part，不影响在线查询
- 不可变：Part 一旦生成不变（除 merge/mutation），高并发读无锁

**Part 数过多是性能杀手**：建议单表活跃 part 数 < 1000。频繁小批量 INSERT 会产生大量小 part，需要监控。

### 4.2 ORDER BY 排序键 —— MergeTree 的"灵魂"

```sql
CREATE TABLE events (
    event_date Date,
    user_id UInt32,
    event_type LowCardinality(String),
    amount Float64
) ENGINE = MergeTree()
ORDER BY (event_date, user_id);   -- ← 排序键决定一切
```

**ORDER BY 的三重身份**：
1. **物理排序**：数据在 part 内按这个顺序物理存储
2. **默认主键**：未指定 `PRIMARY KEY` 时，主键 = ORDER BY
3. **裁剪键**：查询 WHERE 命中排序键前缀时，可跳过大量 granule

```
排序键设计原则:
✅ 前缀常用过滤条件（按时间查询多 → 时间放前面）
✅ 第二列承接第一列的子排序（如 user_id 在 date 之后，用于"某天某用户"查询）
✅ 通常 2-4 列，过多浪费空间
✅ 高基数列放前面，区分度好

❌ 反例: ORDER BY (event_type) -- 只 5 个枚举值，根本裁剪不掉
❌ 反例: ORDER BY (user_id, event_date) -- 按时间范围查询时无法裁剪
```

### 4.3 稀疏索引（Sparse Index）—— 与 B+树的本质区别

```
传统 B+树稠密索引（MySQL）:           稀疏索引（ClickHouse MergeTree）:
每行一个索引项                        每 8192 行一个"标记"（mark）
┌──────────────────┐                  ┌──────────────────────────┐
│ row1 → offset0   │                  │ mark0: date=2024-01-01   │
│ row2 → offset1   │                  │   ↓ 指向行 0-8191         │
│ row3 → offset2   │                  │ mark1: date=2024-01-15   │
│ ...              │                  │   ↓ 指向行 8192-16383    │
│ rowN → offsetN   │                  │ mark2: date=2024-02-01   │
└──────────────────┘                  └──────────────────────────┘
N 行 = N 个索引项                     N 行 = N/8192 个标记
索引本身大，但每行可定位                 索引极小（1万行才 1 个 mark）
                                      定位粒度粗，但配合列存扫描极快
```

**为什么 ClickHouse 选稀疏索引？**
1. 索引体积小（10 亿行只需 ~12 万 mark，几 MB）
2. 完全装进内存，查找快
3. 配合列式存储：定位到 granule 后，整批 SIMD 扫描，B+树的逐行查找反而成了瓶颈

`index_granularity` 默认 8192，可在 `CREATE TABLE` 中调整。OLAP 大表通常保持默认即可。

### 4.4 合并（Merge）机制 —— 数据规整的后台魔法

```
T0:  INSERT 5次 → 5个小 Part:  P1, P2, P3, P4, P5
                                      
T1:  后台 merge schedule 启动:
     P1 + P2 → M1                  (合并为较大 Part)
     P3 + P4 → M2

T2:  继续 merge:
     M1 + M2 + P5 → M3             (更大 Part)
     旧 P1, P2, P3, P4, M1, M2 标记 inactive → 清理

最终: 1 个大 Part M3，查询高效
```

**Merge 的副作用**：
- **ReplacingMergeTree**：合并时按 ORDER BY 去重，保留最新版本
- **SummingMergeTree**：合并时同 ORDER BY 的数值列自动 SUM
- **CollapsingMergeTree**：合并时按 sign 字段折叠

**关键坑**：merge 是**异步**的，查询时数据可能还在多个小 part 里没合并。所以 `ReplacingMergeTree` 的"去重"不是查询时保证的，需要用 `FINAL` 或在查询里 `GROUP BY` 自己处理。

### 4.5 MergeTree 家族引擎选型决策表

| 引擎 | 行为 | 适用场景 | 不适用场景 |
|------|------|---------|------------|
| `MergeTree` | 基础引擎，无去重无汇总 | 90% 场景的明细表 | 需要去重/汇总 |
| `ReplacingMergeTree(ver)` | merge 时按排序键去重，保留最大版本 | 用户状态表、CDC 同步 | 强一致去重需求（merge 异步） |
| `SummingMergeTree` | merge 时同键数值列累加 | 预聚合指标表 | 需要精确数值（用 AggregatingMergeTree） |
| `AggregatingMergeTree` | 存 AggregateFunction 状态，merge 时合并 | 物化视图预聚合 | 直接存数值的场景 |
| `CollapsingMergeTree(sign)` | 按 sign 字段 +1/-1 抵消 | 频繁"撤销"的事件流 | 不需要撤销语义 |
| `ReplicatedMergeTree` | 上述任意引擎 + 副本同步 | 生产环境必选 | 单节点测试 |
| `Distributed` | 不存数据，路由查询到分片 | 跨分片查询 | 单分片无需 |

---

## 5. 核心原理：集群架构（分片、副本、Keeper）

### 5.1 分片（Shard）vs 副本（Replica）—— 最常混淆的两个概念

```
单节点:        1 个 ClickHouse 进程 + 1 份数据
                                       ↓ 容量/可用性不足时
              ┌────────────────────────┴───────────────────────┐
              ▼                                                  ▼
        垂直扩展（升硬件）                                  水平扩展（加机器）
        CPU/内存/磁盘升级                                  分片 or 副本？

┌────────────────────────────────┐    ┌────────────────────────────────────┐
│ 分片（Sharding）                 │    │ 副本（Replication）                  │
│ ─────────────────              │    │ ──────────────────                  │
│ 数据"水平切分"                 │    │ 数据"完整拷贝"                       │
│                                │    │                                     │
│ Shard1: 用户 1-1000            │    │ Replica A: 全部数据 ──┐              │
│ Shard2: 用户 1001-2000         │    │ Replica B: 全部数据 ──┤ 数据相同      │
│                                │    │                       │              │
│ ↑ 不同分片数据不同              │    │ ↑ 副本间数据相同                      │
│ ↑ 解决"容量"问题（写不下）     │    │ ↑ 解决"可用性"问题（一台宕机不影响）   │
│ ↑ 查询时 Distributed 聚合      │    │ ↑ ReplicatedMergeTree 自动同步      │
└────────────────────────────────┘    └────────────────────────────────────┘
```

| 维度 | 分片 | 副本 |
|------|------|------|
| 目的 | 提升容量/吞吐 | 提升高可用/读吞吐 |
| 数据 | 不同分片数据不同 | 副本间数据相同 |
| 引擎 | MergeTree（本地表）+ Distributed（路由表） | ReplicatedMergeTree |
| 协调者 | Distributed 表自动路由 | Keeper（ZooKeeper）协调 |
| 副本数 | 通常 1（每分片自己再配副本） | 通常 2-3 |
| 写入复杂度 | 需要分片键 | 写一个副本，自动复制 |

**生产最佳实践**：分片 + 副本组合。例如 2 分片 × 2 副本 = 4 节点。本教程集群为 **1 分片 × 2 副本**，重点演示副本机制。

### 5.2 Keeper / ZooKeeper 的作用 —— 复制表的"协调中枢"

```
              ┌─────────────────────────────────────┐
              │   ClickHouse Keeper（独立进程）       │
              │   ─────────────────────────         │
              │   1. 存储复制表的元数据               │
              │      /clickhouse/tables/{shard}/     │
              │           {table}/replicas/{replica}│
              │   2. 选举主副本（Leader）             │
              │   3. 通知副本"有新 Part 写入了"        │
              │   4. 分布式 DDL 协调                  │
              └─────────────────────────────────────┘
                          ↑          ↑
                          │          │
                通知 + 心跳 + 选举    通知 + 心跳 + 选举
                          │          │
              ┌───────────┴──────────┴───────────┐
              ▼                                    ▼
        ┌──────────────┐                  ┌──────────────┐
        │  ClickHouse1  │                  │  ClickHouse2  │
        │  (Replica 1)  │  ←──同步 Part──→ │  (Replica 2)  │
        │  is_leader=1  │                  │  is_leader=0  │
        └──────────────┘                  └──────────────┘
              ↑                                    ↑
              └──── INSERT 直写本节点 ──────────────┘
                    本节点生成 Part → 写入 Keeper
                    其他副本从源节点拉取 Part
```

**Keeper 基于 Raft 协议**（简介）：
- 多数派写入才提交：3 节点容忍 1 节点宕机，5 节点容忍 2 节点宕机
- 强 Leader：所有写请求由 Leader 处理，Follower 只读
- 任期（term）机制：避免脑裂，旧 Leader 失效后新 Leader 必须有更新 term

**为什么不用 MySQL 那种基于 binlog 的复制？**
- ClickHouse 的 Part 是不可变的大块数据，不适合流式 binlog
- 元数据用 Keeper 协调，Part 实体在节点间直接 HTTP 拉取，更高效

### 5.3 Distributed 表 —— 查询路由而非数据存储

```
┌─────────────────────────────────────────────────────────────┐
│  客户端                                                      │
│     │                                                        │
│     │  SELECT count() FROM dist_table                         │
│     ▼                                                        │
│  ┌──────────────────────────────────────────┐                │
│  │  Distributed 表（不存数据，只路由）        │                │
│  │  ─────────────────────────              │                │
│  │  1. 把查询下推到所有分片                  │                │
│  │  2. 各分片本地执行                        │                │
│  │  3. 收集各分片结果合并                    │                │
│  └──────────────────────────────────────────┘                │
│           │                              │                   │
│           ▼                              ▼                   │
│  ┌────────────────┐              ┌────────────────┐         │
│  │  Shard1 本地表   │              │  Shard2 本地表   │         │
│  │  count() = 1.2M │              │  count() = 0.8M │         │
│  └────────────────┘              └────────────────┘         │
│           │                              │                   │
│           └──────────────┬───────────────┘                   │
│                          ▼                                   │
│                  合并结果 = 2M                                │
└─────────────────────────────────────────────────────────────┘
```

**关键设计点**：
- Distributed 表本身不持有数据，只是配置元信息（指向哪个集群、哪个库表、用什么分片键）
- 查询下推：`WHERE`/`GROUP BY`/`LIMIT` 等会下推到分片本地执行，最后在协调节点合并
- 写入分布式表：INSERT 时按分片键路由到对应分片，但**推荐直接写本地表**以避免分布式表写入的额外开销和数据丢失风险

### 5.4 复制 vs 分片的组合矩阵

| 拓扑 | 节点数 | 容量 | 可用性 | 适用 |
|------|-------|------|--------|------|
| 单节点 | 1 | 1x | 0 容错 | 测试/PoC |
| 1 分片 × 2 副本（本教程） | 2 | 1x | 1 节点容错 | 小规模生产、读扩展 |
| 2 分片 × 1 副本 | 2 | 2x | 0 容错 | 容量扩展、可接受数据丢失 |
| 2 分片 × 2 副本 | 4 | 2x | 1 节点容错 | 标准生产配置 |
| 3 分片 × 2 副本 | 6 | 3x | 1 节点容错 | 大规模生产 |

---

## 6. 核心原理：复制表（ReplicatedMergeTree）

### 6.1 创建复制表的关键参数

```sql
CREATE TABLE my_table ON CLUSTER treasurycluster
(...)
ENGINE = ReplicatedMergeTree(
    '/clickhouse/tables/{shard}/my_table',  -- ① ZooKeeper 路径
    '{replica}'                              -- ② 副本名
)
ORDER BY (...);

-- ① 路径 '/clickhouse/tables/{shard}/my_table':
--    {shard} 宏会被替换为当前节点的 shard 编号
--    同一分片的所有副本共享这个路径（这是它们能复制的前提）
--    不同分片的路径不同（数据独立）

-- ② '{replica}':
--    {replica} 宏替换为当前节点的副本名（如 'clickhouse1'）
--    每个副本在 Keeper 上注册唯一节点
```

### 6.2 复制工作流

```
INSERT 到 Replica1:
   1. Replica1 写入本地 Part P1
   2. Replica1 在 Keeper 上注册: /replicas/clickhouse2/log → "有新 Part P1"
   3. Replica2 监听到 Keeper 事件
   4. Replica2 从 Replica1 HTTP 拉取 Part P1
   5. Replica2 写入本地 Part P1
   6. Replica2 在 Keeper 上确认: 已收到 P1

   ↑ 整个过程对客户端透明，但有一定延迟（通常 < 1s）
```

### 6.3 监控复制状态的关键指标

`system.replicas` 表是排查复制问题的金钥匙：

| 字段 | 含义 | 异常情况 |
|------|------|----------|
| `is_leader` | 是否为主副本（负责 merge） | 多个 is_leader=1 → 脑裂 |
| `is_readonly` | 是否只读 | =1 表示 Keeper 连不上，无法写入 |
| `absolute_delay` | 复制延迟（秒） | 高说明副本落后，可能数据不一致 |
| `queue_size` | 待处理任务数 | 持续高说明复制积压 |
| `active_replicas` | 活跃副本数 | < total_replicas 说明有副本掉线 |

---

## 7. 文件导航

| 文件 | 内容 | 关键章节 |
|------|------|----------|
| [01_what_is_clickhouse.sql](./01_what_is_clickhouse.sql) | CH 定位、版本、能力概览 | §1 验证版本、§2 千万行聚合体验、§3 压缩率观测、§4 适用场景决策表 |
| [02_column_oriented.sql](./02_column_oriented.sql) | 行式vs列式、压缩、向量化 | §1 多类型列表、§2 列压缩对比、§3 LowCardinality vs String、§4 EXPLAIN PIPELINE 看向量化 |
| [03_mergeTree_engine.sql](./03_mergeTree_engine.sql) | Part/排序键/分区/合并/稀疏索引 | §2 ORDER BY 排序键、§3 PARTITION BY、§4 system.parts 看 part、§5 稀疏索引、§6 ReplacingMergeTree FINAL 真相 |
| [04_basic_sql.sql](./04_basic_sql.sql) | 数据类型、INSERT、SELECT、JOIN、窗口 | §1 全数据类型展示、§4 SELECT 基础、§5 聚合、§7 JOIN、§10 窗口函数 |
| [05_cluster_concepts.sql](./05_cluster_concepts.sql) | 集群拓扑、分片副本、Keeper | §1 system.clusters、§3 本地表 vs 分布式表、§7 system.replicas、§8 ReplicatedMergeTree 创建 |
| [06_first_replicated_table.sql](./06_first_replicated_table.sql) | 第一个复制表实战 | §2 ON CLUSTER 创建复制表、§3 system.replicas 监控、§4 数据一致性验证、§8 Keeper 路径观察 |

---

## 8. 常见误区与最佳实践

### 8.1 误区清单

1. **"ClickHouse 也能做事务"** → 错。无 ACID 事务，单条 UPDATE/DELETE 是异步 mutation，比 INSERT 慢 100 倍
2. **"ReplacingMergeTree 自动去重了，查出来就没重复"** → 错。merge 是异步的，查询时未必合并完成。需要 `FINAL` 或自己 `GROUP BY`
3. **"分片键随便选都行"** → 错。分片键决定数据路由，选错会导致数据倾斜或跨分片 JOIN
4. **"用 `SELECT *` 没关系"** → 错。列式存储的核心优势就是只读需要的列，`SELECT *` 会读取所有列，性能急剧下降
5. **"频繁小批量 INSERT 也 OK"** → 错。每次 INSERT 生成一个 part，过多会触发 `Too many parts` 异常。建议批量写入（每批 1万-100万行）
6. **"PARTITION BY 越细越好"** → 错。分区过细会产生大量小 part，建议按月分区，单分区数据量 < 1亿行
7. **"ORDER BY 里的列越多越好"** → 错。排序键会存储多份（primary.idx + skp 文件），通常 2-4 列足够
8. **"复制表能解决一切高可用"** → 错。复制表只解决单表高可用，Keeper 自身也要高可用（3 节点起步）
9. **"用 `//` 注释"** → 错。ClickHouse SQL 只认 `--`，`//` 会语法错误
10. **"分布式表写入比本地表好"** → 错。分布式表写入有额外开销和丢数据风险，生产推荐直写本地表

### 8.2 最佳实践

1. **数据类型精打细算**：枚举值用 `LowCardinality(String)`，IP 用 `IPv4`/`IPv6`，金额用 `Decimal(P,S)`
2. **排序键前缀优先**：最常用的过滤条件放最前面
3. **按月分区**：`PARTITION BY toYYYYMM(date_col)` 是最稳妥的选择
4. **批量写入**：单次 INSERT 至少 1 万行，避免高频小批量
5. **生产必用 ReplicatedMergeTree**：单机 MergeTree 无容灾
6. **JOIN 用 GLOBAL JOIN**：跨分片 JOIN 时广播右表，避免 N×N 网络开销
7. **预聚合优先于 JOIN**：用物化视图 + AggregatingMergeTree 替代实时 JOIN
8. **监控 part 数和 queue_size**：`system.parts` 和 `system.replicas` 是健康风向标

---

## 9. 自测题（理解检查点）

完成本章后，应能回答：

1. ClickHouse 单机能"秒扫亿行"的四大支柱是什么？为什么 OLTP 数据库做不到？
2. 列式存储的压缩率为什么比行式高 5-10 倍？`LowCardinality` 又是怎么进一步压缩的？
3. MergeTree 的 ORDER BY 有哪三重身份？为什么建议"最常用过滤条件放前面"？
4. ClickHouse 的稀疏索引和 MySQL 的 B+树稠密索引有什么本质区别？为什么稀疏索引在 OLAP 场景反而更优？
5. `ReplacingMergeTree` 的去重是什么时候发生的？为什么查询时仍可能有重复？如何强制查询时去重？
6. 分片和副本分别解决什么问题？本教程的 `treasurycluster` 是哪种拓扑？
7. `ReplicatedMergeTree` 第一个参数那个 ZooKeeper 路径里，`{shard}` 和 `{replica}` 分别意味着什么？为什么"同一分片的多副本"必须共享同一路径？
8. `system.replicas` 中 `is_readonly = 1` 意味着什么？通常是什么原因导致的？
9. 写入分布式表 vs 直接写本地表，各有什么利弊？生产推荐哪种？
10. `INSERT` 一次会生成几个 part？为什么"频繁小批量 INSERT"是反模式？

答案线索均在本 README 及配套 6 个 SQL 文件中。

---

## 10. 集群与运行环境

- 集群名：`treasurycluster`
- 版本：ClickHouse 25.12.1.649
- 拓扑：1 分片 × 2 副本（clickhouse1 + clickhouse2）
- 客户端：`clickhouse-server-1` 容器内 `clickhouse-client`
- 教程使用的独立数据库：`understanding_test`（避免与其他章节冲突）

**验证方法**：

```bash
# 把 SQL 文件拷进容器
docker cp "d:\workspace\big-data\clickhouse-doc\01-understanding-clickhouse\<文件>" clickhouse-server-1:/tmp/<文件名>

# 在集群执行（--multiquery 支持多语句）
docker exec clickhouse-server-1 clickhouse-client --multiquery --queries-file /tmp/<文件名>
```

---

## 11. 关联章节

- [02-column-oriented](./02_column_oriented.sql) —— 列式存储深入
- [03-engines](../03-engines/README.md) —— MergeTree 家族全部引擎详解
- [04-functions](../04-functions/README.md) —— 函数与窗口函数
- [11-performance](../11-performance/README.md) —— 性能调优与索引深入
- [16-principle](../16-principle/README.md) —— 向量化、聚合管道等底层原理

---

## 12. 参考资源

- [ClickHouse 官方文档 - Introduction](https://clickhouse.com/docs/en/intro)
- [ClickHouse 设计原理 - Why Columnar](https://clickhouse.com/docs/en/optimize/skipping-indexes)
- [MergeTree 引擎原理](https://clickhouse.com/docs/en/engines/table-engines/mergetree-family/mergetree)
- [ReplicatedMergeTree 复制机制](https://clickhouse.com/docs/en/engines/table-engines/mergetree-family/replication)
- [ClickHouse Keeper 文档](https://clickhouse.com/docs/en/guides/sre/keeper)
- [ClickHouse 与其他 OLAP 对比](https://clickhouse.com/docs/en/introduction/observability)
