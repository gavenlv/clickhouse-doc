# ClickHouse 原理专题（专家级详解）

> 本章是理解 ClickHouse 高性能的"底层密码"。读完本章，你应能：
> - 解释 ClickHouse 为什么比传统行式数据库快 100–1000 倍，并指出每一倍来自哪里
> - 看懂 MergeTree 的 Part 生命周期：写入 → 后台 Merge → TTL 清理 → 复制传播
> - 画出稀疏索引的 mark 二分查找流程，并解释 8192 这个数字的来历
> - 看懂 EXPLAIN PIPELINE 输出，定位查询瓶颈在 I/O / CPU / 网络
> - 区分 PARTITION BY 与 ORDER BY 的物理作用、区分 Replicated 与 Distributed 的角色
> - 诊断"查询慢、Part 爆炸、副本滞后、TTL 不生效"四类典型问题的根因
>
> 配套文件：[01_overview.sql](./01_overview.sql) · [02_column_store.sql](./02_column_store.sql) · [03_mergetree.sql](./03_mergetree.sql) · [04_compression.md](./04_compression.md) · [05_indexing.md](./05_indexing.md) · [06_query_execution.md](./06_query_execution.md) · [07_replication.md](./07_replication.md) · [08_sharding.sql](./08_sharding.sql)
>
> 集群已启动：`treasurycluster`（CH 25.12.1.649，2 副本 × 1 分片，3 Keeper）。本章所有 SQL 已在 clickhouse-server-1 验证零错误。

---

## 1. 本章解决什么问题（Why）

| 痛点 | 本章如何解答 |
|------|--------------|
| ClickHouse 凭什么比 MySQL 快 100 倍？是单个优化还是组合拳？ | §3.1 六大支柱原理 + §4 行列对比实测 |
| MergeTree 的 Part 到底是什么？什么时候合并？合并时查询受影响吗？ | §3.2 Part 生命周期 + §5 存储结构 |
| 主键索引为什么不建全量索引？8192 这个数字哪来的？ | §3.3 稀疏索引 mark 机制 + §5.2 |
| 向量化执行和 SIMD 是什么？为什么列式存储才能用？ | §3.4 向量化执行原理 |
| 查询在内部怎么流转？为什么 GROUP BY 比连接快？ | §3.5 查询执行管道 + [06_query_execution.md](./06_query_execution.md) |
| 复制到底是同步还是异步？写入什么时候算"成功"？ | §3.6 复制原理 + [07_replication.md](./07_replication.md) |
| 分布式查询的"两阶段聚合"具体怎么运作？sumState/sumMerge 在哪里用？ | §3.7 分片与分布式查询 + [08_sharding.sql](./08_sharding.sql) |
| PARTITION BY 和 ORDER BY 该怎么选？分错会怎样？ | §5.1 分区 vs 主键排序决策表 |
| 压缩算法 LZ4/ZSTD/Delta/Gorilla 该选哪个？ | [04_compression.md](./04_compression.md) §codec 选择决策树 |
| 跳数索引什么时候有用，什么时候是负担？ | [05_indexing.md](./05_indexing.md) §跳数索引选择矩阵 |

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
│                              ▼                                    │
│                      ┌───────────────┐                           │
│                      │  Parser → AST │  词法/语法解析            │
│                      └───────┬───────┘                           │
│                              ▼                                    │
│                      ┌───────────────┐                           │
│                      │  Interpreter  │  AST → QueryPlan          │
│                      │  + Analyzer   │  谓词下推/列裁剪/常量折叠 │
│                      └───────┬───────┘                           │
│              ┌───────────────┼───────────────┐                   │
│      ┌───────▼───────┐ ┌────▼────┐ ┌───────▼───────┐           │
│      │   Pipeline    │ │  Funcs  │ │  Aggregator   │           │
│      │  (Pull 模型)  │ │ (向量化) │ │ (两阶段聚合)  │           │
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
│                                                                  │
│   ┌─────────────────────────────────────────────────────┐       │
│   │  Keeper (Raft) ── 复制日志 / 选主 / 元数据            │       │
│   └─────────────────────────────────────────────────────┘       │
└─────────────────────────────────────────────────────────────────┘
```

**关键事实**：
- ClickHouse 没有 MySQL 那样的"查询优化器成本模型"，**优化主要靠"规则 + 启发式"**（谓词下推、列裁剪、常量折叠、PREWHERE 自动改写）。这意味着执行计划可预测，但也意味着写错 SQL 优化器救不了你。
- 25.x 默认启用 **analyzer**（新查询分析器），把 AST 直接翻译成逻辑计划，比旧的 interpreter 路径更准确（见 12_analyzer 章节）。
- Pipeline 在 21.x 后改为 **Pull 模型**：下游算子向上游"拉"数据，背压自然形成，避免 OOM。

---

## 3. 核心原理详解

### 3.1 高性能的六大支柱

ClickHouse 的快不是单一优化，而是**六个维度的组合拳**，缺一不可：

| 支柱 | 原理 | 对比传统数据库 | 加速倍数（典型） |
|------|------|----------------|------------------|
| ① 列式存储 | 按列组织数据，查询只读需要的列 | 行式存储读整行，I/O 浪费 | 5–100×（取决于列数） |
| ② 向量化执行 | 用 SIMD 指令一次处理一批值 | 逐行解释执行 | 10–100×（CPU 密集算子） |
| ③ 数据压缩 | 同列数据同类型，压缩率高 5–10x | 行式压缩率低 | 2–5×（I/O bound 场景） |
| ④ 稀疏索引 | 每 8192 行一个 mark，索引极小 | B+Tree 每行索引，占空间 | 内存命中 → 10–100× |
| ⑤ 分区剪枝 | 查询自动跳过无关分区 | 全表扫描 | 10–1000×（按月分区查单天） |
| ⑥ 并行处理 | 多线程 + 多分片并行 | 单线程或有限并行 | 与核数/分片数线性 |

**为什么列式存储是基础？** 只有列式存储才能同时实现向量化（连续同类型数据）、高压缩（同列同类型）和按需读列（少 I/O）。这是其他五个支柱的前提。

> **误区警示**：六大支柱不是"开关"，而是"设计选择"。例如，向量化牺牲了单行延迟（攒批才能 SIMD），所以 ClickHouse **点查慢**——这不是 bug，是架构代价。

### 3.2 MergeTree 的 Part 生命周期

MergeTree 是 ClickHouse 的核心引擎，理解 Part 是理解一切的基础。

```
Part 生命周期:
  INSERT (一批数据)
    ↓ ① 内存 Buffer 攒批 (default max_insert_block_size=1048576 行)
    ↓ ② 刷盘生成 1 个 Part (不可变的数据块)
    ↓ ③ 注册到 system.parts (active=1)
    ↓ ④ 复制表: 写 Keeper log entry, 异步传播到副本
    ↓ ⑤ 后台 Merge 线程定期合并小 Part → 大Part
    ↓ ⑥ 达到 TTL 阈值 → 旧 Part 被删除/移动

Part 的物理结构 (Wide 格式, 小 Part 用 Compact 单文件):
  Part_20240101_20240131_1_5_2/
  ├── primary.idx      # 主键索引(稀疏, 每8192行一个mark)
  ├── <column>.bin     # 每列一个文件 (LZ4/ZSTD 压缩)
  ├── <column>.mrk2    # 每列一个 mark 文件 (列在 .bin 中的偏移)
  ├── count.txt        # 行数
  ├── columns.txt      # 列结构
  ├── checksums.txt    # 校验和
  └── minmax_<col>.idx # 分区列的 minmax (剪枝用)

为什么 Part 不可变?
  - 写入后不修改 → 并发安全, 无锁读取
  - 合并生成新 Part, 旧 Part 标记 inactive → 后台清理
  - 查询只看 active Part → 不受合并影响

合并策略 (关键配置):
  - min_bytes_for_wide_part: 小于阈值(默认 10MB)用 compact 单文件
  - min_rows_for_wide_part: 同上(默认 8192 行)
  - max_parts_in_total: 分区Part数上限(默认 10万) → 超过写入直接拒绝
  - parts_to_delay_insert: 接近上限时延迟写入(默认 30万)
  - parts_to_throw_insert: 接近上限时拒绝写入(默认 60万)
  - merge_max_block_size: 合并批次大小(默认 8192)
```

**关键决策点**：
- **批量写入**：每次 INSERT 生成 1 个 Part，频繁小写入会导致 Part 爆炸。建议每次写入 1 万–10 万行，或用 `Buffer` 表自动攒批。
- **分区粒度**：分区太细 → Part 太多；太粗 → 剪枝失效。**经验值：单分区数据量 ≥ 1GB 或 ≥ 100 万行才单独分区**。大多数场景按月分区最优。
- **合并时机**：后台异步，不阻塞写入，但占用 CPU/IO。可通过 `system.merges` 观察，必要时 `OPTIMIZE TABLE ... FINAL` 强制合并（生产慎用，会重写整个分区）。

> **Part 爆炸的典型症状**：`SELECT count() FROM system.parts WHERE table='x' AND active=1` 持续上涨；写入延迟变高；`Too many parts` 错误。根因通常是：① 小批量高频写入；② 分区太细（按天/按小时分区但数据量小）。修复：合并写入批次 + 改粗分区。

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
  1. 二分查找 primary.idx → 定位到 mark N (假设 mark 60: user_id=4800)
  2. 用 data.mrk2 找到该 mark 在 data.bin 的偏移量
  3. 只读取该 granule 的 8192 行 (向量化读取)
  4. 在这 8192 行中线性扫描目标 (SIMD 加速)

为什么是 8192?
  - 经验值, 平衡索引大小与读取粒度
  - 8192 行 × 列宽 ≈ CPU L2 缓存大小 (256KB-1MB) → 缓存友好
  - 可通过 index_granularity 调整(一般不动)
  - 太小: 索引膨胀, 内存压力大
  - 太大: 过滤粒度粗, 多读无用数据

为什么不用 B+Tree?
  - B+Tree 每行一个索引条目 → 1亿行索引约1GB
  - 稀疏索引 8192 行一个 → 1亿行仅 12000 条目, 几KB
  - 索引小 → 常驻内存 → 查询快
  - 代价: 不能高效点查(要读8192行), 但 OLAP 不需要

跳数索引 (Data Skipping Index) - 在主键之外, 对非排序列建二级过滤:
  - minmax: 记录每个granule的min/max, 范围查询跳过 (适合数值/日期)
  - set(N): 记录每个granule的值集合(上限N), 等值查询跳过 (适合低基数)
  - bloom_filter: 布隆过滤器, 适合高基数等值查询 (有假阳性, 无假阴性)
  - tokenbf_v1: token 级布隆, 适合 LIKE '%word%'
  - ngrambf_v1: ngram 布隆, 适合模糊匹配 (开销大于 tokenbf)
  - GRANULARITY 参数: 每 N 个 granule 聚合一次 (默认 1)
```

> **关键认知**：ClickHouse 的"主键"不是 MySQL 的"主键"。ClickHouse 主键 = ORDER BY 列 = 稀疏索引的排序列。它**不保证唯一性**，只是定义了数据在 Part 内的物理排序。同一行可以多次出现，去重靠 ReplacingMergeTree（异步）或 FINAL（慢）。

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
  - 向量化需要连续的同类型数据 (CPU 寄存器要求)
  - 列式存储天然按列连续
  - 行式存储每行混合类型, 无法批量处理 (要逐字段解析)

SIMD (Single Instruction Multiple Data):
  - AVX2: 一次处理 256 位 = 8 个 Float32 / 4 个 Float64
  - AVX-512: 一次处理 512 位 = 16 个 Float32 / 8 个 Float64
  - ClickHouse 编译时自动启用, 查 `system.build_options` 看 HAVE_EMBEDDED_COMPILER
  - 不是所有函数都向量化, 但核心算子(sum/avg/比较/过滤)都向量化了
```

> **反直觉点**：向量化让单行延迟变高（要攒批），但吞吐量极高。这就是 ClickHouse 适合 OLAP（扫亿级行）不适合 OLTP（点查单行）的根本原因——架构选择，不是优化不足。

### 3.5 查询执行管道

```
SELECT region, sum(amount) FROM orders WHERE date > '2024-01-01' GROUP BY region

执行管道 (Pipeline, Pull 模型):
  ┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐
  │  Source  │───►│  Filter  │───►│  GroupBy │───►│  Sink    │
  │ (读Part) │    │(谓词下推) │    │ (聚合)   │    │ (输出)   │
  └──────────┘    └──────────┘    └──────────┘    └──────────┘
       │               │               │
   多线程并行      向量化过滤      分组聚合
   (每个Part一个线程,  (SIMD 比较)   (两阶段:
    max_threads 控制)                本地聚合 → 合并)

关键优化:
  ① 谓词下推: WHERE 尽早过滤, 减少后续数据量
  ② PREWHERE: 先读过滤列, 过滤后再读其他列 (省I/O, 见 06_query_execution.md)
  ③ 聚合分阶段: 先各线程本地聚合 → 再合并 (两阶段聚合, 见 04-functions §11)
  ④ 流式处理: 不需全部数据加载到内存 (但 GROUP BY 大基数会爆内存)
  ⑤ 列裁剪: 只读 SELECT 和 WHERE 涉及的列

为什么 GROUP BY 快?
  - 劯片级: 哈希聚合 (Hash Aggregation), O(n) 平均复杂度
  - 节点级: 各线程独立聚合, 最后合并 (无锁并行)
  - 集群级: 各分片本地聚合 → 协调节点合并 (两阶段, 配合 *State 函数)
  - 内存级: 两阶段聚合大幅减少最终合并的哈希表大小

为什么 JOIN 慢?
  - 右表要全部加载进内存建哈希表 (默认 hash join)
  - 跨分片 JOIN 要么广播右表, 要么重分布数据, 网络开销大
  - ClickHouse 没有 OLTP 那样的嵌套循环+索引点查, 大表 JOIN 大表很慢
```

### 3.6 复制原理

```
ReplicatedMergeTree 复制 (异步, 最终一致):

  INSERT 到 clickhouse1 (任意副本)
    ↓
  ① 写入本地 Part (创建 .bin/.mrk2/primary.idx 文件)
  ② 写 Keeper 日志: /tables/{shard}/{table}/log/entry-1
    ("新增Part xxx, 校验和=xxx")
    ↓ (异步, 不等副本确认)
  ③ 返回客户端 "写入成功"  ← 注意: 此时副本可能还没同步!
    ↓
  ④ clickhouse2 监听到 Keeper 日志变化 (Watcher 机制)
  ⑤ 从 clickhouse1 拉取 Part 数据 (HTTP, 默认 9009 端口)
  ⑥ 写入本地, 在 Keeper 标记完成 (entry-1 ack)

写入语义:
  - 默认: 写入主副本本地 + Keeper 日志写入成功即返回 (异步复制)
  - 不保证副本已同步 (最终一致, 通常毫秒级, 故障时可能落后)
  - 可用 insert_quorum 参数要求多数副本确认 (强一致, 但慢)
  - 可用 select_sequential_consistency 读取保证看到最新写入 (牺牲性能)

复制一致性级别 (写入端):
  - insert_quorum=N: 写入需 N 个副本确认 (通常 N = floor(总副本/2)+1)
  - insert_quorum_timeout: 等待 quorum 的超时 (超时则写入失败)
  - 未达 quorum 时: 写入失败, 但已写入的副本数据保留 (需手动清理)

复制一致性级别 (读取端):
  - select_sequential_consistency=1: 强制读最新写入 (依赖 Keeper log 序号)
  - 默认 0: 任意副本可读 (可能读到旧数据, 但快)

详见 07_replication.md
```

> **关键决策**：默认异步复制 → 写入快但故障时可能丢数据；quorum → 强一致但写入延迟翻倍。生产环境通常折中：写入用 quorum=auto（多数派），读取用默认（最终一致），业务层容忍毫秒级延迟。

### 3.7 分片与分布式查询

```
分布式查询 (Distributed 引擎):

  SELECT region, sum(amount) FROM dist_table GROUP BY region
    ↓
  协调节点解析查询 (任意节点都可作协调者)
    ↓
  ┌────────────┬────────────┬────────────┐
  │            │            │            │
  ▼            ▼            ▼            ▼
 Shard 1    Shard 2    Shard 3   ...   (并行查询各分片本地表)
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
  - 各分片只传状态(小, 几十字节), 不传明细(大, GB级) → 网络省 100-10000×
  - sumState/sumMerge 详见 04-functions §11

分布式 JOIN 的三种方式 (按性能从快到慢):
  - GLOBAL JOIN: 协调节点先把右表子查询结果广播到各分片 → 适合小右表
  - 普通 JOIN (默认): 各分片分别拉取右表全量 → 大右表会爆网络
  - redistributed JOIN: 按 JOIN key 重分布两表 → 25.x 实验性, 大表 JOIN 大表
```

> **设计原则**：ClickHouse 的分布式是"应用层"分布式—— Distributed 表只是路由层，数据真实存储在各分片的本地表。这意味着**分片键选错会全局受影响**（跨分片 JOIN 慢、数据倾斜、热点）。

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

| 维度 | 行式存储 | 列式存储 (ClickHouse) | 说明 |
|------|----------|----------------------|------|
| 查询读列 | 读整行，浪费 I/O | 只读需要的列 | 列式核心优势 |
| 压缩率 | 低（行内类型混合） | 高 5-10x（同列同类型） | 列式第二优势 |
| 向量化 | 不支持 | 支持（SIMD） | 列式第三优势 |
| 单行更新 | 快 | 慢（要重写整个 Part） | OLTP 反向优势 |
| 单行点查 | 快（B+Tree + 索引） | 慢（要读 8192 行 granule） | OLTP 反向优势 |
| 事务 | 支持 ACID | 不支持（只有 Atomic INSERT） | OLTP 反向优势 |
| 范围扫描 | 慢 | 快 | OLAP 核心场景 |
| 聚合分析 | 慢 | 快 100-1000× | OLAP 核心场景 |
| 适用场景 | OLTP（订单、账户） | OLAP（日志、报表、数仓） | 互补，不替代 |

> **专家认知**：ClickHouse 不是"更好的 MySQL"，而是"不同的工具"。OLTP 场景用 ClickHouse 是灾难（点查慢、无事务、更新贵），OLAP 场景用 MySQL 也是灾难（扫亿行慢、聚合慢）。选型先看场景，再看工具。

---

## 5. 数据存储结构

```
┌─────────────────────────────────────────────────────────────┐
│                     MergeTree 存储结构                        │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  Table (表)                                                  │
│  ├── Partition 1 (分区, 如 202401)                           │
│  │   ├── Part 202401_1_5_2 (合并后的Part, Wide 格式)         │
│  │   │   ├── primary.idx      (主键索引, 稀疏)                │
│  │   │   ├── id.bin           (列数据, LZ4 压缩)             │
│  │   │   ├── id.mrk2          (mark 文件, 列偏移)             │
│  │   │   ├── user_id.bin                                   │
│  │   │   ├── user_id.mrk2                                  │
│  │   │   ├── count.txt        (行数)                        │
│  │   │   └── checksums.txt    (校验和)                      │
│  │   └── Part 202401_6_6_0 (未合并的小Part, 可能 Compact)    │
│  │       └── data.bin (单文件, 因为 < min_bytes_for_wide)    │
│  └── Partition 2 (分区, 如 202402)                           │
│      └── ...                                                │
│                                                              │
│  分区(Partition): 数据物理隔离单元, 按分区键划分, 不同目录     │
│  Part: 不可变数据块, 后台合并, 文件级粒度                     │
│  Granule: 8192行一组, 索引最小单元, 读取最小粒度              │
└─────────────────────────────────────────────────────────────┘
```

### 5.1 分区 vs 主键排序（决策表）

| 概念 | 作用 | 物理表现 | 选择原则 | 反例 |
|------|------|----------|----------|------|
| **PARTITION BY** | 物理隔离数据，支持剪枝和 TTL | 不同目录，可整目录删除 | 按时间（月/日），查询常用过滤条件 | 按秒分区 → Part 爆炸 |
| **ORDER BY** | Part 内数据排序，决定主键索引 | 同一 Part 内数据按此列物理排序 | 等值过滤列 → 范围过滤列 → 聚合维度列 | 把低基数列放第一 → 索引失效 |

**关键区别**：分区是物理切分（不同目录），排序是分区内排序。分区剪枝跳过整个分区（O(分区数)），主键索引在分区内定位 granule（O(log(mark数))）。

**经验法则**：
- PARTITION BY：先用 `toYYYYMM(date)` 起步，数据量再大才用 `toYYYYMMDD(date)`
- ORDER BY：`(过滤列, 排序列, 聚合列)`，例如 `(user_id, event_date, event_type)`
- 不要超过 4-5 列 ORDER BY，索引膨胀

### 5.2 Part 命名规则

```
Part 名: {partition}_{min_block}_{max_block}_{level}_{mutation}

例: 202401_1_10_5_0
  ├── partition: 202401 (分区键值)
  ├── min_block: 1 (合并前最小 block 编号)
  ├── max_block: 10 (合并前最大 block 编号)
  ├── level: 5 (合并层级, 0=原始, 越大合并次数越多)
  └── mutation: 0 (mutation 版本, 0=无 mutation)

例: all_5_5_0 (无分区表, partition 固定为 "all")
```

**Block 编号含义**：每次 INSERT 分配一个递增的 block 号。合并后 min_block/max_block 是参与合并的所有 Part 的范围。这个命名让你一眼看出 Part 的"血统"。

---

## 6. 文件导航

| 文件 | 主题 | 关键内容 | 适合谁读 |
|------|------|----------|----------|
| [01_overview.sql](./01_overview.sql) | 架构概览 | 系统信息查询、EXPLAIN 工具、Pipeline 演示 | 初学者，建立全局观 |
| [02_column_store.sql](./02_column_store.sql) | 列式存储 | 列式 vs 行式对比、压缩率实测、LowCardinality、index_granularity | 想理解 I/O 优化 |
| [03_mergetree.sql](./03_mergetree.sql) | MergeTree 原理 | Part 结构、合并过程、分区与排序、5 种 MergeTree 变体 | 表设计者必读 |
| [04_compression.md](./04_compression.md) | 压缩编码 | LZ4/ZSTD/Delta/Gorilla 原理与选型决策树 | 存储成本敏感场景 |
| [05_indexing.md](./05_indexing.md) | 索引机制 | 稀疏索引、mark 定位、跳数索引选择矩阵 | 查询慢必看 |
| [06_query_execution.md](./06_query_execution.md) | 查询执行 | Pipeline、PREWHERE、向量化、并行执行 | 想读 EXPLAIN 输出 |
| [07_replication.md](./07_replication.md) | 复制原理 | replica log、quorum、故障恢复、一致性级别 | 高可用架构必读 |
| [08_sharding.sql](./08_sharding.sql) | 分片原理 | 分布式查询、两阶段聚合、分片键选择、跨分片 JOIN | 大集群运维必读 |

---

## 7. 常见误区与最佳实践

### 误区

1. **把 ClickHouse 当 MySQL 用**：高频小写入、点查、事务 → 全是 ClickHouse 的弱项
   - 修正：写入攒批（≥1万行/次），点查用 Redis/MySQL，事务用 PG
2. **ReplacingMergeTree 当实时去重**：合并是异步的，查询时未必已去重，需 FINAL（慢）或业务层处理
   - 修正：查询时 `SELECT ... FINAL`（25.x 已优化但仍慢）或用 `argMax`/`GROUP BY` 去重
3. **分区太细**：按天分区 + 数据量小 → Part 爆炸，合并跟不上。建议按月。
   - 修正：单分区数据量 < 1GB 时合并到更粗分区
4. **ORDER BY 随便选**：不按查询模式设计排序键 → 索引失效，全表扫描
   - 修正：ORDER BY 第一列必须是高频等值过滤列
5. **以为复制是同步的**：默认异步，主副本写入即返回，副本可能滞后
   - 修正：强一致用 `insert_quorum=auto`，但接受延迟代价
6. **以为 Distributed 表存数据**：Distributed 表只是路由层，数据在本地表
   - 修正：DDL 要在所有分片建本地表（用 `ON CLUSTER`）
7. **跳数索引乱建**：以为加了索引就快，实际上跳数索引有写入/合并开销
   - 修正：只为高频且高选择性的查询建跳数索引（见 05_indexing 决策矩阵）
8. **大量 SELECT ***：读所有列 → 列式优势全失
   - 修正：只读需要的列，用 `SELECT col1, col2` 而非 `*`

### 最佳实践

1. **批量写入**：每次 1 万–10 万行，避免小 Part。高频小写入用 `Buffer` 表或 Kafka 引擎攒批。
2. **ORDER BY 设计**：等值过滤列 → 范围过滤列 → 聚合维度列。例：`(user_id, event_date, event_type)`
3. **分区按月**：兼顾剪枝效率和 Part 数量。`toYYYYMM(event_date)` 是 90% 场景的最优解。
4. **用 PREWHERE 替代 WHERE**：高过滤率场景省 I/O。25.x 默认 `optimize_move_to_prewhere=1` 会自动改写。
5. **预聚合**：用 AggregatingMergeTree + `*State` 函数（见 04-functions §11）
6. **低基数用 LowCardinality**：基数 < 1万的字符串列用 `LowCardinality(String)`，省 5-10× 存储。
7. **避免跨分片 JOIN**：分片键要让高频 JOIN 在分片内完成。无法避免时用 `GLOBAL JOIN`。
8. **TTL 自动清理**：用 `TTL date + INTERVAL 30 DAY` 替代手动 DELETE，省运维。
9. **监控 Part 数量**：`SELECT count() FROM system.parts WHERE active=1` 应稳定在数百以内。

---

## 8. 自测题

完成本章后，应能回答：

1. ClickHouse 快的六大支柱是什么？为什么说列式存储是其他五个的前提？
2. Part 为什么设计成不可变？合并时查询受影响吗？为什么？
3. 稀疏索引的 8192 是什么含义？为什么不用 B+Tree？代价是什么？
4. 查询 `WHERE user_id=5000` 在 MergeTree 中如何定位数据？画出 mark 二分查找流程。
5. 向量化执行为什么只能用于列式存储？为什么这让单行点查变慢？
6. 复制是同步还是异步？写入什么时候返回成功？如何实现强一致？代价是什么？
7. 分布式查询的两阶段聚合是什么？为什么用 sumState 而非 sum？
8. PARTITION BY 和 ORDER BY 的区别？各自解决什么问题？分区太细会怎样？
9. LowCardinality(String) 的原理是什么？什么场景下反而更慢？
10. 跳数索引 minmax / set / bloom_filter 各适合什么场景？GRANULARITY 参数怎么选？
11. Distributed 表写入时数据怎么落到分片？ coordinater 节点故障会丢数据吗？
12. ReplacingMergeTree 的"去重"什么时候发生？查询时一定能看到去重结果吗？

答案线索均在本 README 及配套文件中。

---

## 9. 关联章节

- [00-infra](../00-infra/README.md) —— 集群部署、Keeper Raft 原理
- [03-engines](../03-engines/README.md) —— MergeTree 家族各引擎对比
- [04-functions](../04-functions/README.md) —— *State/*Merge 聚合状态函数（两阶段聚合基石）
- [11-performance](../11-performance/README.md) —— 基于原理的性能优化
- [09-data-deletion](../09-data-deletion/README.md) —— TTL/Mutation/Lightweight Delete 删除机制

---

## 10. 参考资源

- [ClickHouse 架构概览](https://clickhouse.com/docs/en/architecture/architecture-overview)
- [MergeTree 引擎原理](https://clickhouse.com/docs/en/engines/table-engines/mergetree-family/mergetree)
- [ClickHouse 内部存储结构](https://clickhouse.com/docs/en/development/architecture)
- [向量化执行](https://clickhouse.com/docs/en/development/architecture#vectorized-query-execution)
- [ReplicatedMergeTree 设计](https://clickhouse.com/docs/en/engines/table-engines/mergetree-family/replication)
- [Distributed 表引擎](https://clickhouse.com/docs/en/engines/table-engines/special/distributed)
- [ClickHouse Keeper vs ZooKeeper](https://clickhouse.com/docs/en/guides/developer/altinity-kb-keeper-vs-zookeeper)
