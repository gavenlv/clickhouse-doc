# 01-getting-started：ClickHouse 入门到精通（专家级详解）

> 本章是 ClickHouse 的"地基"。读完本章，你应能：解释 ClickHouse 为什么快、列式存储与行式存储的本质差异、MergeTree 的 Part/排序键/稀疏索引/合并机制、分片副本与 Keeper 的协同原理；从底层理解复制表/分布式表的路由与一致性模型；熟练运用索引、物化视图、字典等加速手段；为业务场景精准选型表引擎与数据模型，并亲手创建第一张 `ReplicatedMergeTree` 复制表验证数据同步。
>
> 配套可运行 SQL（共 13 个文件，已全部在 `treasurycluster` CH 25.12.1.649 集群验证零错误）：
> 概念入门（01-06）· 实操入门（07-09）· 进阶专题（10-13）

> **重整说明（2026-08-02）**：本章由原 `01-base/` 与 `01-understanding-clickhouse/` 合并而成，作为重整计划 R1 批次的成果。

---

## 1. 本章解决什么问题（Why）

ClickHouse 的设计哲学与 MySQL/PostgreSQL 截然不同，初学者常踩的坑不是语法，而是**心智模型**没建立。新人常带着 OLTP 思维用 CH，导致性能灾难。本章先解决认知，再解决操作：

| 业务痛点 | 本章如何解答 |
|----------|--------------|
| 同样是数据库，为什么 ClickHouse 单机就能"秒扫亿行"？ | §2 OLAP vs OLTP 定位 + §3 四大加速原理拆解 |
| 列式存储到底"列"在哪？为什么压缩率能到 5-10 倍？ | §3.1 行式 vs 列式 ASCII 图 + §3.2 LZ4/ZSTD 压缩原理 |
| 向量化执行是什么？和批处理有什么区别？ | §3.3 SIMD 向量化执行图解 |
| 为什么 CH 不支持高频 UPDATE/DELETE？该用什么替代？ | §4.3 MergeTree 的"追加写 + 后台合并"机制 + §8 表引擎选型决策表 |
| MergeTree 的 ORDER BY 和 MySQL 索引是一回事吗？ | §4.1 Part 概念 + §4.3 稀疏索引（granule 8192） |
| `ReplacingMergeTree` 真的会"自动去重"吗？为什么查出来还有重复？ | §4.4 合并(merge)机制 + FINAL 真相 |
| 复制表和分布式表什么关系？是不是建了复制表就不用分布式表了？ | §5.1 复制 vs 分片正交关系图 + §7 分布式表路由流程 |
| `ReplicatedMergeTree()` 为什么不写 ZooKeeper 路径？背后宏机制是什么？ | §6.3 默认复制路径宏 + macros.xml 配置原理 |
| 分片和副本到底差在哪？Keeper 是干嘛的？ | §5.1 分片 vs 副本决策表 + §5.2 Raft 协议简介 |
| 索引建了为什么查询没用上？跳数索引和主键索引区别？ | §9 索引原理 + §9.2 稀疏索引 vs 跳数索引对比决策表 |
| 物化视图和投影该用哪个？为什么 MV 必须用 `*State` 函数？ | §9.3 MV vs Projection 决策表 + §9.4 *State 原理 |

**学习路径建议**：先读 §2 全景图建立认知，再按 §3 → §4 → §5 → §6 → §7 顺序读原理，最后对照 SQL 文件跑一遍。

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

**两个加速倍数叠加**：I/O 减少 50x（只读需要的列）× CPU 提升 10x（SIMD 向量化）≈ 100x+ 总加速。这就是 CH 快的本质，与"内存数据库"无关。

### 2.3 适用场景 vs 不适用场景决策表

| 场景 | 适合 ClickHouse？ | 原因 | 替代方案 |
|------|------------------|------|----------|
| 日志/事件分析 | ✅ 强烈推荐 | 海量追加、按时间范围聚合 | Elasticsearch、Doris |
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

**列存物理结构**：
```
/var/lib/clickhouse/data/db/table/{partition}/{part}/
  ├── data.bin        每个列一个文件（按列分开存）
  ├── index.mrk       mark 文件：稀疏索引的位置指针
  ├── primary.idx     主键索引：每 8192 行存一次主键值
  └── columns.txt     列信息
```

### 3.2 压缩原理：为什么列式能压 5-10 倍

**核心原理**：相似数据放在一起，更容易找到重复模式。

```
salary 列（数字）原始字节:   8000 12000 15000 8000 12000 8000 8000
LZ4 算法看到模式 "8000" 重复: 存储 "8000" 一次 + 指针引用 → 大幅压缩

gender 列（字符串）:        "M" "F" "M" "M" "F" "M" "M" "F"
LowCardinality 直接存索引:   0 1 0 0 1 0 0 1  （只存 1 字节，原 8 字节）
```

ClickHouse 提供的主要压缩算法：

| 算法 | 压缩比 | 解压速度 | 适用 |
|------|--------|---------|------|
| LZ4（默认） | 2-5x | 极快（10+ GB/s） | 大多数列，CPU 受限场景 |
| ZSTD | 5-10x | 快（1-2 GB/s） | 历史冷数据、字符串列 |
| Delta + LZ4 | 对时序数据 10x+ | 快 | 时间戳、自增 ID |
| Gorilla | 对 float 时序 10x+ | 快 | 监控指标 float 列 |
| T64 | 整数 8x+ | 快 | UInt64 列 |

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

向量化原理深入详见 [02-principles/06_query_execution.md](../16-principle/06_query_execution.md)。

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

命名规则: {partition}_{min_block}_{max_block}_{level}
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

**表数据与稀疏索引的关系**：
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

**为什么 ClickHouse 选稀疏索引？**
1. 索引体积小（10 亿行只需 ~12 万 mark，几 MB）
2. 完全装进内存，查找快
3. 配合列式存储：定位到 granule 后，整批 SIMD 扫描，B+树的逐行查找反而成了瓶颈

**关键参数 `index_granularity`（默认 8192）**：
- 越小：索引越大，定位越精确，但索引占内存多
- 越大：索引越小，但每个 granule 扫的行多
- 默认 8192 是经验值，对绝大多数场景最优

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

**为什么这么设计？**
- 写入零阻塞：每次 INSERT 只写一个新 part，不修改已有数据
- 合并异步：后台线程慢慢合并，不影响写入
- 不可变：part 一旦写入不可修改（这也是不支持 UPDATE 的根因）

**合并的副作用**：
- ReplacingMergeTree：合并时才真正去重
- CollapsingMergeTree：合并时才真正抵消 sign
- SummingMergeTree：合并时才真正求和

**关键坑**：merge 是**异步**的，查询时数据可能还在多个小 part 里没合并。所以 `ReplacingMergeTree` 的"去重"不是查询时保证的，需要用 `FINAL` 或在查询里 `GROUP BY` 自己处理。

**Too many parts 异常**：如果写入太快（每秒几十次小 INSERT），part 数量爆炸，CH 会拒绝写入。解决：批量写入（每次 1 万~10 万行）+ async_insert。

### 4.5 分区（Partition）与 Part 的关系

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

### 5.3 复制 vs 分片的组合矩阵

| 拓扑 | 节点数 | 容量 | 可用性 | 适用 |
|------|-------|------|--------|------|
| 单节点 | 1 | 1x | 0 容错 | 测试/PoC |
| 1 分片 × 2 副本（本教程） | 2 | 1x | 1 节点容错 | 小规模生产、读扩展 |
| 2 分片 × 1 副本 | 2 | 2x | 0 容错 | 容量扩展、可接受数据丢失 |
| 2 分片 × 2 副本 | 4 | 2x | 1 节点容错 | 标准生产配置 |
| 3 分片 × 2 副本 | 6 | 3x | 1 节点容错 | 大规模生产 |

---

## 6. 复制表（ReplicatedMergeTree）

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

### 6.3 默认路径宏机制（本章集群已配置）

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

### 6.4 监控复制状态的关键指标

`system.replicas` 表是排查复制问题的金钥匙：

| 字段 | 含义 | 异常情况 |
|------|------|----------|
| `is_leader` | 是否为主副本（负责 merge） | 多个 is_leader=1 → 脑裂 |
| `is_readonly` | 是否只读 | =1 表示 Keeper 连不上，无法写入 |
| `absolute_delay` | 复制延迟（秒） | 高说明副本落后，可能数据不一致 |
| `queue_size` | 待处理任务数 | 持续高说明复制积压 |
| `active_replicas` | 活跃副本数 | < total_replicas 说明有副本掉线 |

---

## 7. 分布式表（Distributed）

### 7.1 分布式表路由原理

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

### 7.2 分布式表的写入策略

| 写入方式 | 优点 | 缺点 | 推荐度 |
|----------|------|------|--------|
| 直写本地表（每分片各自写） | 无分布式表开销，无丢数据风险 | 客户端需自己路由分片 | ✅ 生产推荐 |
| 写分布式表 | 客户端无需关心分片 | 有额外开销，重启可能丢数据 | ⚠️ 谨慎 |
| 写分布式表 + `insert_distributed_sync=1` | 同步写，不丢数据 | 性能下降 | ⚠️ 折中 |

**关键设计点**：
- Distributed 表本身不持有数据，只是配置元信息（指向哪个集群、哪个库表、用什么分片键）
- 查询下推：`WHERE`/`GROUP BY`/`LIMIT` 等会下推到分片本地执行，最后在协调节点合并
- **推荐直接写本地表**以避免分布式表写入的额外开销和数据丢失风险

### 7.3 分片键选择

```sql
-- 分片键决定数据如何分布到各分片
CREATE TABLE dist_table ON CLUSTER treasurycluster
AS local_table
ENGINE = Distributed(
    treasurycluster,         -- 集群名
    currentDatabase(),       -- 数据库
    local_table,             -- 本地表名
    rand()                   -- 分片键（哈希后取模）
);

-- 常见分片键选择：
-- rand()              → 均匀随机分布（无业务含义，简单）
-- user_id             → 相同用户落在同分片（利于用户级聚合）
-- cityHash64(user_id) → 哈希分布（避免 user_id 集中）
-- intHash64(user_id) % 4 → 显式控制分片数
```

---

## 8. 表引擎选型决策表（核心场景）

| 引擎 | 去重/合并机制 | 适用场景 | 不适用场景 | 查询去重方式 |
|------|--------------|----------|------------|-------------|
| `MergeTree` | 无去重 | 不可变日志、事件流 | 需要更新 | 直接查 |
| `ReplacingMergeTree(ver)` | 按 ORDER BY 键去重，保留 max(ver) | 用户资料、配置、状态机 | 频繁更新 | `argMax(x, ver)` 或 `FINAL` |
| `CollapsingMergeTree(sign)` | sign +1/-1 抵消 | 增量计数器、库存 | 需要保留历史 | `sum(col * sign)` |
| `VersionedCollapsingMergeTree(sign, ver)` | sign + version | 金融交易、严格版本 | 简单状态 | `sum(col*sign)` + `max(ver)` |
| `SummingMergeTree` | 同主键数值列求和 | 预聚合报表 | 需要明细 | 直接查（合并后即求和） |
| `AggregatingMergeTree` | 同主键 *State 合并 | 任意聚合预聚合 | 简单求和（用 Summing） | `*Merge(state_col)` |
| `Replicated*` 上述引擎 | 上述 + ZK 复制 | **生产必备** | 单机测试 | 同上 |
| `Distributed` | 不存数据，路由 | 跨分片查询 | 单分片无需 | 路由到分片 |

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

引擎深度对比详见 [04-engines/06_engine_selection_guide.md](../03-engines/06_engine_selection_guide.md)。

---

## 9. 索引与物化视图：查询加速双雄

### 9.1 三层索引体系

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

### 9.2 稀疏索引 vs 跳数索引对比

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

### 9.3 物化视图 vs 投影决策表

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

### 9.4 物化视图预聚合必须用 *State 函数

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

原理详见 [05-functions/README.md §3](../04-functions/README.md)。

---

## 10. 字典加速 JOIN

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

字典深度详见 [06-modeling/04_dictionaries.md](../03-engines/05_special_engines.sql)（重整中）。

---

## 11. 文件导航

本章共 13 个 SQL 文件，按学习顺序分三组：

### 11.1 概念入门（01-06）—— 从原 `01-understanding-clickhouse` 合并

| 文件 | 内容 | 关键章节 |
|------|------|----------|
| [01_what_is_clickhouse.sql](./01_what_is_clickhouse.sql) | CH 定位、版本、能力概览 | §1 验证版本、§2 千万行聚合体验、§3 压缩率观测、§4 适用场景决策表 |
| [02_column_oriented.sql](./02_column_oriented.sql) | 行式vs列式、压缩、向量化 | §1 多类型列表、§2 列压缩对比、§3 LowCardinality vs String、§4 EXPLAIN PIPELINE 看向量化 |
| [03_mergetree_engine.sql](./03_mergetree_engine.sql) | Part/排序键/分区/合并/稀疏索引 | §2 ORDER BY 排序键、§3 PARTITION BY、§4 system.parts 看 part、§5 稀疏索引、§6 ReplacingMergeTree FINAL 真相 |
| [04_basic_sql.sql](./04_basic_sql.sql) | 数据类型、INSERT、SELECT、JOIN、窗口 | §1 全数据类型展示、§4 SELECT 基础、§5 聚合、§7 JOIN、§10 窗口函数 |
| [05_cluster_concepts.sql](./05_cluster_concepts.sql) | 集群拓扑、分片副本、Keeper | §1 system.clusters、§3 本地表 vs 分布式表、§7 system.replicas、§8 ReplicatedMergeTree 创建 |
| [06_first_replicated_table.sql](./06_first_replicated_table.sql) | 第一个复制表实战 | §2 ON CLUSTER 创建复制表、§3 system.replicas 监控、§4 数据一致性验证、§8 Keeper 路径观察 |

### 11.2 实操入门（07-09）—— 从原 `01-base` 保留

| 文件 | 内容 | 关键章节 |
|------|------|----------|
| [07_basic_operations.sql](./07_basic_operations.sql) | 基础 CRUD + 去重入门 | §1 MergeTree 原理、§2 复制集群机制、§3 插入/查询原理、§4 聚合、§5 JOIN、§6 窗口函数、§7 CTE、§8 去重幂等 |
| [08_replicated_tables.sql](./08_replicated_tables.sql) | 复制表机制 | §1 复制架构、§2 Macros 宏机制、§3 默认复制路径、§4 复制状态监控、§5 ReplacingMT、§6 CollapsingMT、§7 复制队列 |
| [09_distributed_tables.sql](./09_distributed_tables.sql) | 分布式表路由 | §1 分布式架构、§2 分片 vs 副本、§3 Distributed 引擎、§4 分片键选择、§5 负载均衡、§6 跨分片聚合、§7 分布式 JOIN |

### 11.3 进阶专题（10-13）—— R1 新增

| 文件 | 内容 | 关键章节 |
|------|------|----------|
| [10_system_queries.sql](./10_system_queries.sql) | 系统表查询入门 | §1 system.clusters、§2 system.replicas、§3 system.parts、§4 system.merges、§5 system.query_thread_log、§6 system.dictionaries、§7 系统表组合诊断 |
| [11_materialized_views.sql](./11_materialized_views.sql) | 物化视图入门 | §1 MV 基础、§2 SummingMT 预聚合、§3 AggregatingMT + *State、§4 多级聚合、§5 实时统计、§6 MV vs Projection 对比 |
| [12_data_modeling.sql](./12_data_modeling.sql) | 数据建模入门 | §1 宽表 vs 星型、§2 ORDER BY 设计、§3 分区策略、§4 反范式 vs 范式、§5 时间序列建模、§6 用户行为宽表案例 |
| [13_advanced_features.sql](./13_advanced_features.sql) | 高级特性入门 | §1 TTL 自动过期、§2 分层存储、§3 采样查询、§4 CTE 与子查询、§5 数组函数、§6 JSON 提取、§7 异步插入、§8 PREWHERE |

---

## 12. 常见误区与最佳实践

### 12.1 误区清单

1. **"ClickHouse 也能做事务"** → 错。无 ACID 事务，单条 UPDATE/DELETE 是异步 mutation，比 INSERT 慢 100 倍
2. **"ReplacingMergeTree 自动去重了，查出来就没重复"** → 错。merge 是异步的，查询时未必合并完成。需要 `FINAL` 或自己 `GROUP BY`
3. **"用 `FINAL` 解决所有去重问题"** → `FINAL` 性能差（查询时触发合并），应优先用 `argMax(col, version)` 手动去重，低峰期 `OPTIMIZE TABLE FINAL`
4. **"主键索引能加速所有列查询"** → 主键只对 ORDER BY 列有效。非排序列查询要靠跳数索引
5. **"分片键随便选都行"** → 错。分片键决定数据路由，选错会导致数据倾斜或跨分片 JOIN
6. **"用 `SELECT *` 没关系"** → 错。列式存储的核心优势就是只读需要的列，`SELECT *` 会读取所有列，性能急剧下降
7. **"频繁小批量 INSERT（每秒几百次 INSERT）"** → part 爆炸，触发 "Too many parts"。应批量写（1 万~10 万行/次）或用 `async_insert`
8. **"PARTITION BY 越细越好"** → 错。分区过细会产生大量小 part，建议按月分区，单分区数据量 < 1 亿行
9. **"ORDER BY 里的列越多越好"** → 错。排序键会存储多份（primary.idx + skp 文件），通常 2-4 列足够
10. **"复制表能解决一切高可用"** → 错。复制表只解决单表高可用，Keeper 自身也要高可用（3 节点起步）
11. **"用 `//` 注释"** → 错。ClickHouse SQL 只认 `--`，`//` 会语法错误
12. **"分布式表写入比本地表好"** → 错。分布式表写入有额外开销和丢数据风险，生产推荐直写本地表
13. **"小写 `md5`/`sha256`"** → CH 函数名大小写敏感，必须 `MD5`/`SHA256` 大写
14. **"在 `ReplicatedMergeTree()` 不加括号"** → 新版要求 `ReplicatedMergeTree()` 带括号（即使为空，用默认宏路径）
15. **"物化视图用 `sum` 而非 `sumState`"** → 无法二次聚合，预聚合链断裂。详见 §9.4

### 12.2 最佳实践

1. **数据类型精打细算**：枚举值用 `LowCardinality(String)`，IP 用 `IPv4`/`IPv6`，金额用 `Decimal(P,S)`
2. **排序键前缀优先**：最常用的过滤条件放最前面，如 `ORDER BY (event_date, user_id)`
3. **按月分区**：`PARTITION BY toYYYYMM(date_col)` 是最稳妥的选择，单分区 50-100GB
4. **批量写入**：单次 INSERT 至少 1 万行，避免高频小批量；高频小写用 `async_insert` + `Buffer` 表
5. **生产必用 ReplicatedMergeTree**：单机 MergeTree 无容灾
6. **JOIN 用 GLOBAL JOIN**：跨分片 JOIN 时广播右表，避免 N×N 网络开销
7. **预聚合优先于 JOIN**：用物化视图 + AggregatingMergeTree 替代实时 JOIN
8. **去重查询**：`SELECT argMax(col, version) FROM t GROUP BY pk` 比 `FINAL` 快 10x
9. **监控 part 数和 queue_size**：`system.parts` 和 `system.replicas` 是健康风向标
10. **JOIN 优化**：右表小（<内存）+ `GLOBAL JOIN` + 字典替代维度表 JOIN

---

## 13. 自测题（理解检查点）

完成本章后，应能回答：

1. ClickHouse 单机能"秒扫亿行"的四大支柱是什么？为什么 OLTP 数据库做不到？
2. 列式存储的压缩率为什么比行式高 5-10 倍？`LowCardinality` 又是怎么进一步压缩的？
3. MergeTree 的 part 合并是同步还是异步？这导致了什么现象（与 ReplacingMergeTree 去重的关系）？
4. MergeTree 的 ORDER BY 有哪三重身份？为什么建议"最常用过滤条件放前面"？
5. ClickHouse 的稀疏索引和 MySQL 的 B+树稠密索引有什么本质区别？`index_granularity` 默认是多少？调小它有什么利弊？
6. `ReplacingMergeTree` 的去重是什么时候发生的？`FINAL` 和 `argMax(col, version)` 哪个性能好？为什么？
7. 分片和副本分别解决什么问题？本教程的 `treasurycluster` 是哪种拓扑？
8. `ReplicatedMergeTree()` 不带参数为什么也能工作？背后的宏机制是什么？
9. `ReplicatedMergeTree` 第一个参数那个 ZooKeeper 路径里，`{shard}` 和 `{replica}` 分别意味着什么？为什么"同一分片的多副本"必须共享同一路径？
10. `system.replicas` 中 `is_readonly = 1` 意味着什么？通常是什么原因导致的？
11. 分布式表查询时，聚合是在分片做还是协调节点做？为什么用 `*State` 能优化这个过程？
12. 写入分布式表 vs 直接写本地表，各有什么利弊？生产推荐哪种？
13. 跳数索引的 `set` 和 `bloom_filter` 分别适合什么数据特征？
14. 物化视图预聚合为什么必须用 `sumState` 而非 `sum`？用 `sum` 会导致什么问题？
15. `CollapsingMergeTree` 的 sign 机制如何实现"增量更新"？查询时为什么要 `sum(col * sign)`？
16. 为什么 ClickHouse 不支持高频 UPDATE？Mutation（ALTER UPDATE）是如何实现的？

答案线索均在本 README 及配套 13 个 SQL 文件中。

---

## 14. 集群与运行环境

- 集群名：`treasurycluster`
- 版本：ClickHouse 25.12.1.649
- 拓扑：1 分片 × 2 副本（clickhouse1 + clickhouse2）
- Keeper：3 节点（keeper1, keeper2, keeper3）
- 客户端：`clickhouse-server-1` 容器内 `clickhouse-client`
- 教程使用的独立数据库：`getting_started_test`（避免与其他章节冲突）

**访问方式**：

| 接口 | 地址 |
|------|------|
| ClickHouse1 HTTP | http://localhost:8123 |
| ClickHouse2 HTTP | http://localhost:8124 |
| Play UI | http://localhost:8123/play |
| ClickHouse1 Native | localhost:9000 |
| ClickHouse2 Native | localhost:9001 |

**验证方法**：

```bash
# 把 SQL 文件拷进容器
docker cp "d:\workspace\big-data\clickhouse-doc\01-getting-started\<文件>" clickhouse-server-1:/tmp/<文件名>

# 在集群执行（--multiquery 支持多语句）
docker exec clickhouse-server-1 clickhouse-client --multiquery --queries-file /tmp/<文件名>
```

---

## 15. 关联章节

- [02-principles](../16-principle/README.md) —— 向量化执行、查询管道、压缩 codec 底层原理 ✅
- [04-engines](../03-engines/README.md) —— MergeTree 家族全部引擎完整对比 ✅
- [05-functions](../04-functions/README.md) —— 聚合状态函数 `*State`/`*Merge` 详解 ✅
- [08-performance](../11-performance/README.md) —— 查询性能调优进阶
- [03-data-types](../05-data-type/README.md) —— 数据类型深度
- [10-date-update](../10-date-update/README.md) —— 日期函数、数据更新策略

---

## 16. 参考资源

- [ClickHouse 官方文档 - Introduction](https://clickhouse.com/docs/en/intro)
- [ClickHouse 设计原理 - Why Columnar](https://clickhouse.com/docs/en/optimize/skipping-indexes)
- [MergeTree 引擎原理](https://clickhouse.com/docs/en/engines/table-engines/mergetree-family/mergetree)
- [ReplicatedMergeTree 复制机制](https://clickhouse.com/docs/en/engines/table-engines/mergetree-family/replication)
- [Distributed 分布式表](https://clickhouse.com/docs/en/engines/table-engines/special/distributed)
- [ClickHouse Keeper 文档](https://clickhouse.com/docs/en/guides/sre/keeper)
- [稀疏索引与跳数索引](https://clickhouse.com/docs/en/guides/best-practices/sparse-primary-indexes)
- [物化视图](https://clickhouse.com/docs/en/sql-reference/statements/create/view#materialized-view)
- [字典](https://clickhouse.com/docs/en/sql-reference/dictionaries)
- [ClickHouse 与其他 OLAP 对比](https://clickhouse.com/docs/en/introduction/observability)
