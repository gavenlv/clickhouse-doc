# ClickHouse 原理专题（专家级详解）

> 本章是理解 ClickHouse 高性能的"底层密码"。读完本章，你应能：解释 ClickHouse 为什么比传统数据库快 100-1000 倍、理解 MergeTree 的 Part 生命周期、掌握稀疏索引的 mark 定位机制、看懂查询执行管道、诊断性能瓶颈的根因。
>
> 配套文件：[01_overview.sql](./01_overview.sql)、[02_column_store.sql](./02_column_store.sql)、[03_mergetree.sql](./03_mergetree.sql)、[04_compression.md](./04_compression.md)、[05_indexing.md](./05_indexing.md)、[06_query_execution.md](./06_query_execution.md)、[07_replication.md](./07_replication.md)、[08_sharding.sql](./08_sharding.sql)

---

## 1. 本章解决什么问题（Why）

| 痛点 | 本章如何解答 |
|------|--------------|
| ClickHouse 凭什么比 MySQL 快 100 倍？是单个优化还是组合拳？ | §3.1 六大支柱原理 |
| MergeTree 的 Part 到底是什么？什么时候合并？合并时查询受影响吗？ | §3.2 Part 生命周期 |
| 主键索引为什么不建全量索引？8192 这个数字哪来的？ | §3.3 稀疏索引 mark 机制 |
| 向量化执行和 SIMD 是什么？为什么列式存储才能用？ | §3.4 向量化执行 |
| 查询在内部怎么流转？为什么 GROUP BY 比连接快？ | §3.5 查询执行管道 |
| 复制到底是同步还是异步？写入什么时候算"成功"？ | §3.6 复制原理 |
| 分布式查询的"两阶段聚合"具体怎么运作？ | §3.7 分片与分布式查询 |

---

## 2. ClickHouse 整体架构

```
┌─────────────────────────────────────────────────────────────────┐
│                        ClickHouse 架构                            │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│   ┌─────────────┐    ┌─────────────┐    ┌─────────────┐       │
│   │   Client    │    │   HTTP      │    │  Native     │       │
│   │   (TCP)     │    │   Server    │    │  Protocol   │       │
│   └──────┬──────┘    └──────┬──────┘    └──────┬──────┘       │
│          └───────────────────┼───────────────────┘                │
│                              │                                    │
│                      ┌───────▼───────┐                           │
│                      │  Interpreter  │  解析 SQL → AST           │
│                      │    / Parser   │                           │
│                      └───────┬───────┘                           │
│                              │                                    │
│              ┌───────────────┼───────────────┐                   │
│      ┌───────▼───────┐ ┌────▼────┐ ┌───────▼───────┐           │
│      │   Optimizer   │ │  Funcs  │ │  Aggregator   │           │
│      │ (谓词下推等)   │ │ (向量化) │ │ (分组聚合)     │           │
│      └───────┬───────┘ └─────────┘ └───────┬───────┘           │
│              │        ┌─────────────┐       │                    │
│              │        │ MergeTree   │       │                    │
│              │        │   Engine    │       │                    │
│              │        └──────┬──────┘       │                    │
│              │        ┌──────▼──────┐        │                    │
│              │        │   Storage    │        │                    │
│              │        │   (Parts)    │        │                    │
│              │        └─────────────┘        │                    │
│      ┌───────▼───────────────────────────────▼───────┐           │
│      │              ClickHouse Server                  │           │
│      └───────────────────────────────────────────────┘           │
└─────────────────────────────────────────────────────────────────┘
```

---

## 3. 核心原理详解

### 3.1 高性能的六大支柱

ClickHouse 的快不是单一优化，而是**六个维度的组合拳**，缺一不可：

| 支柱 | 原理 | 对比传统数据库 |
|------|------|----------------|
| ① 列式存储 | 按列组织数据，查询只读需要的列 | 行式存储读整行，I/O 浪费 |
| ② 向量化执行 | 用 SIMD 指令一次处理一批值 | 逐行解释执行 |
| ③ 数据压缩 | 同列数据同类型，压缩率高 5-10x | 行式压缩率低 |
| ④ 稀疏索引 | 每 8192 行一个 mark，索引极小 | B+Tree 每行索引，占空间 |
| ⑤ 分区剪枝 | 查询自动跳过无关分区 | 全表扫描 |
| ⑥ 并行处理 | 多线程 + 多分片并行 | 单线程或有限并行 |

**为什么列式存储是基础？** 只有列式存储才能同时实现向量化（连续同类型数据）、高压缩（同列同类型）和按需读列（少 I/O）。这是其他五个支柱的前提。

### 3.2 MergeTree 的 Part 生命周期

MergeTree 是 ClickHouse 的核心引擎，理解 Part 是理解一切的基础。

```
Part 生命周期:
  INSERT (一批数据)
    ↓
  生成 1 个 Part (不可变的数据块)
    ↓
  后台 Merge 线程定期合并小 Part → 大Part
    ↓
  达到分区/TTL 阈值 → 旧 Part 被删除/移动

Part 的物理结构:
  Part_20240101_20240131_1_5_2/
  ├── primary.idx      # 主键索引(稀疏, 每8192行一个mark)
  ├── data.bin         # 列数据(LZ4/ZSTD压缩)
  ├── data.mrk2        # mark文件(列的偏移量)
  ├── count.txt        # 行数
  ├── columns.txt      # 列结构
  └── checksums.txt    # 校验和

为什么 Part 不可变?
  - 写入后不修改 → 并发安全, 无锁
  - 合并生成新Part, 旧Part标记 inactive → 后台清理
  - 查询只看 active Part → 不受合并影响

合并策略 (merge_tree 配置):
  - min_bytes_for_wide_part: 小于阈值用 compact 格式(单文件)
  - max_parts_in_total: 分区Part数上限(避免过多小文件)
  - merge_max_block_size: 合并批次大小
```

**关键决策点**：
- **批量写入**：每次 INSERT 生成 1 个 Part，频繁小写入会导致 Part 爆炸。建议每次写入 1 万-10 万行。
- **分区粒度**：分区太细 → Part 太多；太粗 → 剪枝失效。建议按月分区。
- **合并时机**：后台异步，不阻塞写入，但占用 CPU/IO。

### 3.3 稀疏索引的 mark 机制

ClickHouse 不用 B+Tree，而是用**稀疏索引**——这是它省内存又快的关键。

```
数据(按ORDER BY排序):          稀疏主键索引(每8192行一个mark):
┌────────────────────┐         ┌──────────────────────┐
│ 行1:  user_id=1    │         │ mark 0: user_id=1    │  ← 第0个granule起始
│ 行2:  user_id=2    │         │                      │
│ ...                │  8192行  │                      │
│ 行8192: user_id=50 │         │ mark 1: user_id=50   │  ← 第1个granule起始
│ 行8193: user_id=51 │         │                      │
│ ...                │  8192行  │                      │
│ 行16384: user_id=99│         │ mark 2: user_id=99   │
└────────────────────┘         └──────────────────────┘

查询 WHERE user_id = 5000:
  1. 二分查找 primary.idx → 定位到 mark N
  2. 用 data.mrk2 找到该 mark 在 data.bin 的偏移量
  3. 只读取该 granule 的 8192 行
  4. 在这 8192 行中线性扫描目标

为什么是 8192?
  - 经验值, 平衡索引大小与读取粒度
  - 8192 行 × 列宽 ≈ CPU L2 缓存大小 → 缓存友好
  - 可通过 index_granularity 调整(一般不动)

为什么不用 B+Tree?
  - B+Tree 每行一个索引条目 → 1亿行索引约1GB
  - 稀疏索引 8192 行一个 → 1亿行仅 12000 条目, 几KB
  - 索引小 → 常驻内存 → 查询快

跳数索引 (Data Skipping Index):
  - 在主键之外, 对某些列建二级过滤
  - minmax: 记录每个granule的min/max, 范围查询跳过
  - set: 记录每个granule的值集合, 等值查询跳过
  - bloom_filter: 布隆过滤器, 适合高基数等值查询
```

### 3.4 向量化执行

```
逐行执行 (传统数据库):       向量化执行 (ClickHouse):
┌────────────────────┐       ┌────────────────────┐
│ row1: price*1.1    │       │ [p1,p2,...,p8192]  │
│ row2: price*1.1    │       │     *1.1 (SIMD)    │ ← 一条指令处理8/16个值
│ row3: price*1.1    │  ──►  │ = [r1,r2,...,r8192]│
│ ...                │       └────────────────────┘
└────────────────────┘       CPU 流水线满载, 缓存命中率高

为什么列式才能向量化?
  - 向量化需要连续的同类型数据
  - 列式存储天然按列连续
  - 行式存储每行混合类型, 无法批量处理

SIMD (Single Instruction Multiple Data):
  - AVX2: 一次处理 256 位 = 8 个 Float32
  - AVX-512: 一次处理 512 位 = 16 个 Float32
  - ClickHouse 编译时自动启用, 无需配置
```

### 3.5 查询执行管道

```
SELECT region, sum(amount) FROM orders WHERE date > '2024-01-01' GROUP BY region

执行管道 (Pipeline):
  ┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐
  │  Source  │───►│  Filter  │───►│  GroupBy │───►│  Sink    │
  │ (读Part) │    │(谓词下推) │    │ (聚合)   │    │ (输出)   │
  └──────────┘    └──────────┘    └──────────┘    └──────────┘
       │               │               │
   多线程并行      向量化过滤      分组聚合
   (每个Part一个线程)

关键优化:
  ① 谓词下推: WHERE 尽早过滤, 减少后续数据量
  ② PREWHERE: 先读过滤列, 过滤后再读其他列 (省I/O)
  ③ 聚合分阶段: 先各线程本地聚合 → 再合并 (两阶段聚合)
  ④ 流式处理: 不需全部数据加载到内存

为什么 GROUP BY 快?
  - 哈希聚合 (Hash Aggregation), O(n)
  - 各线程独立聚合, 最后合并
  - 配合 *State 函数可分阶段 (见 04-functions §11)
```

### 3.6 复制原理

```
ReplicatedMergeTree 复制 (异步, 最终一致):

  INSERT 到 clickhouse1
    ↓
  ① 写入本地 Part
  ② 写 Keeper 日志: /tables/{shard}/{table}/log/entry-1
    ("新增Part xxx")
    ↓ (异步, 不等副本确认)
  ③ 返回客户端 "写入成功"  ← 注意: 此时副本可能还没同步!
    ↓
  ④ clickhouse2 监听到日志变化
  ⑤ 从 clickhouse1 拉取 Part 数据 (HTTP)
  ⑥ 写入本地, 在 Keeper 标记完成

写入语义:
  - 写入主副本即返回成功 (异步复制)
  - 不保证副本已同步 (最终一致)
  - 可用 insert_quorum 参数要求多数副本确认 (强一致, 但慢)

复制一致性级别:
  - insert_quorum: 写入需 N/2+1 副本确认
  - select_sequential_consistency: 读取需读最新写入 (牺牲性能)
  - 默认: 异步, 最终一致

详见 07_replication.md
```

### 3.7 分片与分布式查询

```
分布式查询 (Distributed 引擎):

  SELECT region, sum(amount) FROM dist_table GROUP BY region
    ↓
  协调节点解析查询
    ↓
  ┌────────────┬────────────┐
  │            │            │
  ▼            ▼            ▼
 Shard 1    Shard 2    Shard 3   (并行查询各分片本地表)
 本地聚合    本地聚合    本地聚合
 sumState    sumState    sumState  ← 两阶段聚合: 先本地用*State
  │            │            │
  └────────────┼────────────┘
               ▼
         协调节点合并
         sumMerge  ← 合并状态出最终结果
               │
               ▼
           返回客户端

为什么用两阶段聚合?
  - 各分片只传状态(小), 不传明细(大) → 网络省
  - sumState/sumMerge 详见 04-functions §11

分布式 JOIN 的两种方式:
  - GLOBAL JOIN: 广播右表到各分片 → 适合小表
  - 普通 JOIN: 各分片分别拉取右表 → 适合大表(慢)
```

---

## 4. 列式存储 vs 行式存储

```
行式存储 (Row-oriented):              列式存储 (Column-oriented):
┌─────────────────────────┐           ┌─────────────────────────┐
│ id: 1, name: Alice,    │           │ id:    [1, 2, 3, 4]   │
│ id: 2, name: Bob,      │           │ name:  [Alice, Bob,    │
│ id: 3, name: Charlie,  │    ──►    │       Charlie, David]  │
│ id: 4, name: David     │           │ age:   [25, 30, 35, 40]│
└─────────────────────────┘           └─────────────────────────┘

查询 SELECT avg(age) 时:
- 行式: 读取整行(包括不需要的name列), 提取age → I/O浪费
- 列式: 只读取age列 → I/O最少, 且可向量化
```

| 维度 | 行式存储 | 列式存储 (ClickHouse) |
|------|----------|----------------------|
| 查询读列 | 读整行，浪费 I/O | 只读需要的列 |
| 压缩率 | 低（行内类型混合） | 高 5-10x（同列同类型） |
| 向量化 | 不支持 | 支持（SIMD） |
| 单行更新 | 快 | 慢（不擅长） |
| 事务 | 支持 | 不支持 |
| 适用场景 | OLTP | OLAP |

---

## 5. 数据存储结构

```
┌─────────────────────────────────────────────────────────────┐
│                     MergeTree 存储结构                        │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  Table (表)                                                  │
│  ├── Partition 1 (分区, 如 202401)                           │
│  │   ├── Part 202401_1_5_2 (合并后的Part)                    │
│  │   │   ├── primary.idx      (主键索引, 稀疏)                │
│  │   │   ├── data.bin         (列数据, 压缩)                  │
│  │   │   ├── data.mrk2        (mark文件, 列偏移)              │
│  │   │   ├── count.txt        (行数)                         │
│  │   │   └── checksums.txt    (校验和)                       │
│  │   └── Part 202401_6_6_0 (未合并的小Part)                  │
│  └── Partition 2 (分区, 如 202402)                           │
│      └── ...                                                │
│                                                              │
│  分区(Partition): 数据物理隔离单元, 按分区键划分                │
│  Part: 不可变数据块, 后台合并                                 │
│  Granule: 8192行一组, 索引最小单元                             │
└─────────────────────────────────────────────────────────────┘
```

### 分区 vs 主键排序

| 概念 | 作用 | 选择原则 |
|------|------|----------|
| **PARTITION BY** | 物理隔离数据，支持剪枝和 TTL | 按时间（月/日），查询常用过滤条件 |
| **ORDER BY** | Part 内数据排序，决定主键索引 | 查询过滤+聚合维度，高频列在前 |

**关键区别**：分区是物理切分（不同目录），排序是分区内排序。分区剪枝跳过整个分区，主键索引在分区内定位 granule。

---

## 6. 文件导航

| 文件 | 主题 | 关键内容 |
|------|------|----------|
| [01_overview.sql](./01_overview.sql) | 架构概览 | 查询管道图、系统信息查询 |
| [02_column_store.sql](./02_column_store.sql) | 列式存储 | 列式 vs 行式对比、压缩率实测 |
| [03_mergetree.sql](./03_mergetree.sql) | MergeTree 原理 | Part 结构、合并过程、分区与排序 |
| [04_compression.md](./04_compression.md) | 压缩编码 | LZ4/ZSTD/Delta 原理与选型 |
| [05_indexing.md](./05_indexing.md) | 索引机制 | 稀疏索引、跳数索引、mark 定位 |
| [06_query_execution.md](./06_query_execution.md) | 查询执行 | Pipeline、谓词下推、PREWHERE |
| [07_replication.md](./07_replication.md) | 复制原理 | replica log、quorum、一致性 |
| [08_sharding.sql](./08_sharding.sql) | 分片原理 | 分布式查询、两阶段聚合、JOIN |

---

## 7. 常见误区与最佳实践

### 误区
1. **把 ClickHouse 当 MySQL 用**：高频小写入、点查、事务 → 全是 ClickHouse 的弱项
2. **ReplacingMergeTree 当实时去重**：合并是异步的，查询时未必已去重，需 FINAL（慢）或业务层处理
3. **分区太细**：按天分区 + 数据量小 → Part 爆炸，合并跟不上。建议按月。
4. **ORDER BY 随便选**：不按查询模式设计排序键 → 索引失效，全表扫描
5. **以为复制是同步的**：默认异步，主副本写入即返回，副本可能滞后

### 最佳实践
1. **批量写入**：每次 1 万-10 万行，避免小 Part
2. **ORDER BY 设计**：等值过滤列 → 范围过滤列 → 聚合维度列
3. **分区按月**：兼顾剪枝效率和 Part 数量
4. **用 PREWHERE 替代 WHERE**：高过滤率场景省 I/O
5. **预聚合**：用 AggregatingMergeTree + *State 函数（见 04-functions §11）
6. **低基数用 LowCardinality**：省空间、提速

---

## 8. 自测题

完成本章后，应能回答：

1. ClickHouse 快的六大支柱是什么？为什么说列式存储是其他五个的前提？
2. Part 为什么设计成不可变？合并时查询受影响吗？
3. 稀疏索引的 8192 是什么含义？为什么不用 B+Tree？
4. 查询 `WHERE user_id=5000` 在 MergeTree 中如何定位数据？（mark 二分查找流程）
5. 向量化执行为什么只能用于列式存储？
6. 复制是同步还是异步？写入什么时候返回成功？如何实现强一致？
7. 分布式查询的两阶段聚合是什么？为什么用 sumState 而非 sum？
8. PARTITION BY 和 ORDER BY 的区别？各自解决什么问题？

答案线索均在本 README 及配套文件中。

---

## 9. 关联章节

- [00-infra](../00-infra/README.md) —— 集群部署、Keeper Raft 原理
- [03-engines](../03-engines/README.md) —— MergeTree 家族各引擎对比
- [04-functions](../04-functions/README.md) —— *State/*Merge 聚合状态函数
- [11-performance](../11-performance/README.md) —— 基于原理的性能优化

---

## 10. 参考资源

- [ClickHouse 架构概览](https://clickhouse.com/docs/en/architecture/architecture-overview)
- [MergeTree 引擎原理](https://clickhouse.com/docs/en/engines/table-engines/mergetree-family/mergetree)
- [ClickHouse 内部存储结构](https://clickhouse.com/docs/en/development/architecture)
- [向量化执行](https://clickhouse.com/docs/en/development/architecture#vectorized-query-execution)
