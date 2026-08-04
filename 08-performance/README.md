# 性能优化专题（已合并 → 08-performance）

> **⚠️ 本目录已合并到 [08-performance](../08-performance/)**
>
> 按重整计划（R7 批次），`11-performance`（性能优化专题）与 `02-advance/01_performance_optimization.sql`、`17-best-practices/03_query_optimization.sql` 已合并为统一的 `08-performance` 章节。
>
> 旧目录保留用于参考，新内容请访问 [08-performance/README.md](../08-performance/README.md)。

---

## 本章解决的核心问题

性能优化是 ClickHouse 生产环境中最常见的需求。以下是 10+ 个典型痛点，本章逐一给出解决方案：

| # | 痛点 | 根因 | 解决方案 | 对应专题 |
|---|------|------|----------|----------|
| 1 | 查询越来越慢，数据量上去后从秒级变分钟级 | 未利用主键索引，全表扫描 | 优化 ORDER BY 设计 | 02_primary_indexes |
| 2 | WHERE 条件无法过滤数据，每次扫描大量无关分区 | 分区键设计不当或未使用分区裁剪 | 合理设计分区键 + 查询条件包含分区键 | 03_partitioning |
| 3 | 按某列过滤时索引无效，走全表扫描 | 主键不包含该列，也无可用的跳数索引 | 创建跳数索引或 Projection | 04_skipping_indexes, 15_projections |
| 4 | 大列过滤导致大量 IO，查询响应慢 | 无 PREWHERE 下推，先读大列再过滤 | 使用 PREWHERE 自动下推 | 05_prewhere_optimization |
| 5 | 单条插入速度极慢，每秒只能插入几百行 | 每次 INSERT 生成新 part，频繁合并 | 批量插入 + 异步插入 | 06_bulk_inserts, 07_asynchronous_operations |
| 6 | Mutation 操作导致查询阻塞，磁盘空间暴涨 | Mutation 是全量重写，且是同步操作 | 分区替换 + 轻量更新 | 08_mutation_optimization |
| 7 | JOIN 查询 OOM 或超慢 | 右表过大，Hash Join 内存不足 | 切换 JOIN 算法或使用字典 | 16_join_strategies |
| 8 | 相同查询反复执行，每次都重新扫描全量数据 | 未开启查询缓存 | 启用查询缓存 + 物化视图 | 13_caching |
| 9 | 字符串列存储和查询效率低 | 使用了不合适的类型（String 存数字、Nullable 过度使用） | 优化数据类型选择 | 09_data_types |
| 10 | 硬件资源充足但单查询只能用一个 CPU | 并行度配置不足 | 调优线程和并行设置 | 14_hardware_tuning |
| 11 | 复杂查询的优化器选择低效执行计划 | 旧优化器能力有限 | 启用新优化器 enable_optimizer=1 | 12_analyzer |
| 12 | 聚合查询重复计算大量数据 | 没有预聚合机制 | 使用 Projections 或物化视图 | 15_projections |

---

## 性能优化体系全景图

ClickHouse 性能优化可从**写入、查询、存储、网络**四个维度展开：

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                     ClickHouse 性能优化体系全景图                             │
│                                                                             │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │  一、写入优化                          吞吐量: 10万~100万行/秒         │ │
│  │  ├─ 批量插入 (≥1000行/批)                                              │ │
│  │  ├─ 异步插入 (async_insert=1)                                          │ │
│  │  ├─ 分区设计 (避免过多小分区)                                           │ │
│  │  └─ 写入限速 (max_insert_block_size)                                   │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
│                                                                             │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │  二、查询优化                          延迟: 毫秒~秒级                 │ │
│  │  ├─ 索引优化 (主键/跳数/Projection)                                     │ │
│  │  ├─ 分区裁剪 (WHERE 包含分区键)                                         │ │
│  │  ├─ PREWHERE 下推 (提前过滤大列)                                        │ │
│  │  ├─ 查询重写 (避免函数、减少数据量)                                     │ │
│  │  ├─ JOIN 优化 (小表右置、字典替代)                                      │ │
│  │  ├─ 缓存利用 (查询缓存、页缓存)                                         │ │
│  │  └─ 并行执行 (max_threads、并行副本)                                    │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
│                                                                             │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│   │  三、存储优化                          压缩比: 5~15x                   │ │
│  │  ├─ 数据类型优化 (最小类型、避免 Nullable)                              │ │
│  │  ├─ 压缩算法选择 (LZ4/ZSTD/Delta)                                      │ │
│  │  ├─ 分区与 TTL (数据生命周期管理)                                       │ │
│  │  └─ 存储布局优化 (列顺序、物化列)                                       │ │
│  │  └──────────────────────────────────────────────────────────────────────┘ │
│                                                                             │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │  四、网络优化                          延迟: 毫秒~秒级                 │ │
│  │  ├─ 分布式查询优化 (GLOBAL JOIN vs 本地 JOIN)                           │ │
│  │  ├─ 数据本地性 (分片键与 JOIN 键对齐)                                   │ │
│  │  ├─ 字典服务化 (Dictionary 集中管理维度)                                │ │
│  │  └─ 减少数据传输 (列裁剪、行过滤)                                       │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 核心原理

### 1. 查询执行 Pipeline

ClickHouse 的查询执行是一个**向量化 Pipeline**：

```
SQL → Parser → Analyzer → Optimizer → Pipeline Builder → Executor → Result
                                                                      │
                                                                      ▼
                                                         ┌────────────────────┐
                                                         │  向量化执行引擎     │
                                                         │  ┌──────────────┐  │
                                                         │  │ Source 1     │  │
                                                         │  │ (读取列存)   │  │
                                                         │  └──────┬───────┘  │
                                                         │         │         │
                                                         │  ┌──────▼───────┐  │
                                                         │  │ Transform 1  │  │
                                                         │  │ (过滤/投影)  │  │
                                                         │  └──────┬───────┘  │
                                                         │         │         │
                                                         │  ┌──────▼───────┐  │
                                                         │  │ Transform 2  │  │
                                                         │  │ (聚合/排序)  │  │
                                                         │  └──────┬───────┘  │
                                                         │         │         │
                                                         │  ┌──────▼───────┐  │
                                                         │  │ Sink         │  │
                                                         │  │ (输出结果)   │  │
                                                         │  └──────────────┘  │
                                                         └────────────────────┘
```

- **Source**: 从 MergeTree 读取数据，利用稀疏索引跳过不必要的数据块
- **Transform**: 一系列向量化操作（过滤、投影、聚合、排序），每个操作处理一批列数据
- **Sink**: 合并结果并输出

### 2. 稀疏索引原理

ClickHouse 的**主键索引不是 B-Tree，而是稀疏索引**：

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  数据文件 (.bin)                       索引文件 (.idx)                      │
│  ┌─────────────────────────────────┐    ┌─────────────────────────────┐    │
│  │ Granule 0: user_id=1..1000     │◄───│ Mark 0: user_id=1           │    │
│  ├─────────────────────────────────┤    ├─────────────────────────────┤    │
│  │ Granule 1: user_id=1001..2000  │◄───│ Mark 1: user_id=1001        │    │
│  ├─────────────────────────────────┤    ├─────────────────────────────┤    │
│  │ Granule N: ...                 │◄───│ Mark N: ...                 │    │
│  └─────────────────────────────────┘    └─────────────────────────────┘    │
│                                                                             │
│  每个 Granule = 8192 行 (由 index_granularity 控制)                         │
│  查询时先二分查找 .idx 文件定位 Granule，再读取对应 .bin 文件                │
└─────────────────────────────────────────────────────────────────────────────┘
```

**关键理解**：稀疏索引只能在 ORDER BY 前缀列上高效工作。查询条件必须包含 ORDER BY 的第一列才能有效利用索引。

### 3. 向量化执行

ClickHouse 不是一次处理一行，而是一次处理一批（通常 1024 行）列数据：

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  行式处理 (MySQL)              向量化处理 (ClickHouse)                      │
│                                                                             │
│  for each row:                  for each batch:                             │
│    read a, b, c                  read a[0..1023], b[0..1023], c[0..1023]   │
│    compute a + b                 compute a + b (SIMD)                       │
│    filter result                 filter result (SIMD)                       │
│    write result                  write result (SIMD)                        │
│                                                                             │
│  CPU 利用率: 低                   CPU 利用率: 高                             │
│  分支预测: 差                     分支预测: 好                                │
│  缓存友好: 差                     缓存友好: 好                                │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 4. PREWHERE 下推

ClickHouse 自动将 WHERE 条件中涉及大列的部分下推到 PREWHERE 阶段：

```
原始查询:
SELECT event_data, user_id FROM events WHERE event_time > '2024-01-01'

优化后:
阶段 1 (PREWHERE): 读取 event_time 列，过滤出匹配的行号
阶段 2: 根据行号读取 event_data 和 user_id 列

效果: 避免读取 event_data 大列的全量数据，IO 减少 50-90%
```

### 5. Projections 自动路由

Projections 在 INSERT 时自动维护聚合/排序后的数据副本，查询时优化器自动选择最优数据源：

```
INSERT → 写入主表数据 + 写入 Projection 数据（原子操作）
SELECT → 优化器判断是否可以使用 Projection
         ├─ 是 → 从 Projection 读取（更少数据、更快排序）
         └─ 否 → 从原始表读取
```

---

## Projections 原理详解

### 与物化视图的对比决策表

| 决策维度 | Projections | 物化视图 (MV) |
|----------|-------------|---------------|
| **查询路由** | 自动（优化器决定，对用户透明） | 手动（SELECT 必须指定 MV 表名） |
| **存储位置** | 与主表同一存储路径 | 独立表，可存不同磁盘/集群 |
| **维护成本** | 低（INSERT 时自动维护） | 中（需额外管理 MV 生命周期） |
| **ALTER 操作** | 困难（需 DROP 后重建，再 MATERIALIZE） | 灵活（可独立 DDL） |
| **聚合函数** | 有限（count/sum/avg/min/max/any/anyLast） | 支持所有聚合函数 + State/Combine |
| **存储翻倍** | 是（原始数据 + 投影副本） | 是（原始数据 + MV 表） |
| **数据一致性** | 强一致（原子写入，同一事务） | 最终一致（异步写入） |
| **适用场景** | 加速已知查询模式，简化架构 | 复杂 ETL、跨集群复制、异构存储 |
| **写入性能影响** | 中（每个 Projection 增加写入开销） | 低（异步写入，不阻塞主表） |
| **监控方式** | system.projection_parts | system.tables + system.parts |

**选择原则**：
- 查询模式固定、希望架构简洁 → **Projections**
- 需要复杂聚合、灵活存储、跨集群 → **物化视图**
- 查询模式多变、无法预测 → **都不适合**，优化主键设计

---

## JOIN 策略对比

ClickHouse 提供了 5 种 JOIN 方式，各有优劣：

| 方式 | 原理 | 性能 | 适用场景 | 限制 |
|------|------|------|----------|------|
| **GLOBAL JOIN** | 右表收集到 initiator 节点，广播到所有分片 | ⭐⭐⭐ | 分布式环境，右表 < 1GB | 网络开销大，右表不能太大 |
| **字典 (Dictionary)** | 维度表加载到内存，dictGet 直接获取 | ⭐⭐⭐⭐⭐ | 高频查询，维度表不频繁变更 | 只支持 key-value 查询，不支持复杂条件 |
| **本地 JOIN** | 每个分片独立执行 JOIN | ⭐⭐⭐⭐ | 右表在每个分片有完整副本 | 数据分布要求高 |
| **子查询 IN** | 只检查存在性，不返回右表字段 | ⭐⭐⭐⭐⭐ | 只需判断存在性 | 不能返回右表字段 |
| **物化视图预 JOIN** | 写入时预 JOIN 结果 | ⭐⭐⭐⭐⭐ | 实时性要求高的预关联查询 | 灵活性差，变更成本高 |

### 五种方式的选择逻辑

```
需要 JOIN 吗？
├─ 只需判断存在性（不返回右表字段）→ IN 子查询
├─ 需要返回右表字段？
│   ├─ 维度表不频繁变更 → 字典 (dictGet) ★ 首选
│   ├─ 分布式环境，维度表小 → GLOBAL JOIN
│   ├─ 维度表在每个分片存在 → 本地 JOIN
│   └─ 需要实时关联结果 → 物化视图预 JOIN
└─ JOIN 都不适合 → 考虑反范式化设计（冗余字段到事实表）
```

---

## 常见误区（10+ 条）

1. **❌ 主键就是唯一约束** — ClickHouse 的主键不唯一，只用于排序和索引
2. **❌ 分区越多查询越快** — 分区过多（>1000）反而降低性能，每个分区需要独立元数据
3. **❌ 跳数索引越多越好** — 每个索引增加写入开销，且查询时评估所有索引有时间成本
4. **❌ JOIN 右表越大越好** — ClickHouse 的 JOIN 将右表加载到内存，右表必须小于左表
5. **❌ 小表 LEFT JOIN 大表没问题** — 大表在右会被全量加载到内存，导致 OOM
6. **❌ Projections 可以替代所有物化视图** — Projections 不支持复杂聚合函数，ALTER 困难
7. **❌ 查询缓存解决所有重复查询问题** — 查询参数变化时缓存失效，物化视图更稳定
8. **❌ Nullable 列没关系** — Nullable 列额外存储 UInt8 标记，查询和存储效率降低 30-50%
9. **❌ Mutation 和普通 UPDATE 一样快** — Mutation 是全量重写 part，不是原地更新
10. **❌ String 存数字没关系** — 字符串比较比数值比较慢 10-100 倍，且压缩率差
11. **❌ WHERE 中用函数不影响性能** — `toYYYYMM(date) = '202401'` 无法使用索引，触发表级扫描
12. **❌ GLOBAL JOIN 和普通 JOIN 一样快** — GLOBAL JOIN 需要网络广播，数据传输时间不可忽略

---

## 最佳实践（10+ 条）

1. **✅ ORDER BY 设计** — 将高选择性列放在前面，常用过滤条件优先
2. **✅ 分区键选择** — 按时间分区，粒度适中（每个分区 1-10 GB），避免过多分区
3. **✅ 数据类型选最小** — 能用 UInt8 不用 UInt32，能用 Date 不用 DateTime
4. **✅ 避免 Nullable** — 用默认值替代 NULL（如 `0`、`''`、`1970-01-01`）
5. **✅ 批量插入** — 每次 INSERT ≥ 1000 行，使用 `INSERT INTO ... VALUES` 多行形式
6. **✅ 异步插入** — 高频写入场景设置 `async_insert=1, wait_for_async_insert=0`
7. **✅ PREWHERE 自动下推** — 确保 `optimize_move_to_prewhere=1`（默认开启）
8. **✅ 启用新优化器** — 设置 `enable_optimizer=1` 获得更好的查询计划
9. **✅ 小表右置** — JOIN 时始终将小表放在右侧，大表在左侧
10. **✅ 字典替代 JOIN** — 维度表不频繁变更时，使用 Dictionary + dictGet 替代 JOIN
11. **✅ 先过滤再 JOIN** — 使用子查询或 WITH 先过滤和投影，减少 JOIN 数据量
12. **✅ Projections 适度使用** — 每个表不超过 3 个 Projection，避免写入过载
13. **✅ 定期分析慢查询** — 使用 `system.query_log` 监控查询性能，定位瓶颈
14. **✅ 硬件匹配** — 确保 CPU 核心数、内存大小、磁盘 IOPS 之间的平衡

---

## 自测题（10+ 道）

### 索引与查询

1. **表 `events` 按 `(event_date, city_id, event_type)` 排序，以下哪些查询能有效利用主键索引？**
   ```sql
   A. SELECT * FROM events WHERE event_type = 'click';
   B. SELECT * FROM events WHERE event_date = '2024-06-01' AND city_id = 100;
   C. SELECT * FROM events WHERE event_date >= '2024-06-01' AND event_date < '2024-07-01';
   D. SELECT * FROM events WHERE city_id = 100 AND event_type = 'click';
   ```
   > **答案**: B 和 C。B 使用了前缀列 `event_date`，C 使用了前缀列 `event_date` 的范围查询。A 没有使用前缀列，D 跳过了 `event_date` 直接使用 `city_id`。

2. **以下查询哪个更快？为什么？**
   ```sql
   -- 查询 A
   SELECT * FROM events WHERE toYYYYMM(event_date) = '202406';
   -- 查询 B
   SELECT * FROM events WHERE event_date >= '2024-06-01' AND event_date < '2024-07-01';
   ```
   > **答案**: 查询 B 更快。B 可以使用分区裁剪和索引，A 中的 `toYYYYMM` 函数阻止了索引使用。

### Projections

3. **Projections 和物化视图的核心区别是什么？**
   > **答案**: 查询路由方式不同。Projections 是自动路由（优化器透明选择），物化视图需要手动指定表名。

4. **一个表已经有 3 个 Projection，再添加第 4 个有什么风险？**
   > **答案**: 写入性能下降。每次 INSERT 都要维护所有 Projection，过多的 Projection 会显著增加写入延迟，建议每个表不超过 3 个。

5. **以下聚合函数哪个不能在 Projection 中使用？**
   ```sql
   A. count()
   B. sum()
   C. uniq()
   D. avg()
   ```
   > **答案**: C。`uniq()` 不是 Projection 支持的聚合函数。

### JOIN

6. **ClickHouse 中 JOIN 的右表为什么要小？**
   > **答案**: ClickHouse 的 Hash Join 会将右表全量加载到内存构建哈希表。右表越大，内存占用越高，超过 `max_memory_usage` 会导致 OOM。

7. **以下哪种场景下字典查询比 JOIN 快 100 倍？**
   > **答案**: 高频维度查询场景。字典加载到内存后，`dictGet` 是 O(1) 的指针访问，而 JOIN 需要构建哈希表、数据 shuffle、网络传输（分布式）。

8. **GLOBAL JOIN 的广播流程是怎样的？**
   > **答案**: (1) 右表数据收集到 initiator 节点；(2) initiator 将右表数据广播到所有分片；(3) 每个分片在本地执行 JOIN。

### 写入优化

9. **单条插入和批量插入的性能差异有多大？**
   > **答案**: 批量插入（≥1000 行/批）比单条插入快 100-1000 倍。单条插入每次生成新 part，合并线程压力大。

10. **异步插入的 trade-off 是什么？**
    > **答案**: 异步插入降低延迟（不等待写入完成），但牺牲了实时可见性（数据延迟可见）和写入确认（可能丢数据）。

### 数据类型

11. **为什么 Nullable 列要尽量避免？**
    > **答案**: Nullable 额外存储 UInt8 标记列，内存占用增加，查询时多一次判断，压缩率降低，整体性能下降 30-50%。

12. **String 类型存储 IP 地址有什么问题？**
    > **答案**: String 存储 IP 占用更多空间（"255.255.255.255" 15 字节 vs IPv4 4 字节），比较慢，压缩率低。推荐使用 `IPv4` 或 `UInt32` 类型。

---

## 文件导航表

| 编号 | 专题 | 文件 | 核心内容 | 预计学习时间 |
|------|------|------|----------|-------------|
| 01 | 查询优化基础 | [md](./01_query_optimization.md) / [sql](./01_query_optimization_examples.sql) | 分区裁剪、主键利用、PREWHERE、LIMIT/SAMPLE、EXPLAIN、OR vs IN、子查询 vs JOIN、物化列、LIMIT BY、DISTINCT vs GROUP BY、并行设置 | 30 分钟 |
| 02 | 主键索引优化 | [md](./02_primary_indexes.md) / [sql](./02_primary_indexes_examples.sql) | 稀疏索引原理、ORDER BY 设计、前缀索引、索引粒度、跳数索引 | 20 分钟 |
| 03 | 分区键优化 | [md](./03_partitioning.md) / [sql](./03_partitioning_examples.sql) | 分区键选择、分区裁剪、分区管理、过多分区问题 | 15 分钟 |
| 04 | 数据跳数索引 | [md](./04_skipping_indexes.md) / [sql](./04_skipping_indexes_examples.sql) | 跳数索引类型（minmax/set/bloom_filter）、创建与维护、索引效果分析 | 15 分钟 |
| 05 | PREWHERE 优化 | [md](./05_prewhere_optimization.md) / [sql](./05_prewhere_optimization_examples.sql) | PREWHERE 自动下推、手动 PREWHERE、大列过滤优化 | 10 分钟 |
| 06 | 批量插入优化 | [md](./06_bulk_inserts.md) / [sql](./06_bulk_inserts_examples.sql) | 批量插入策略、块大小调优、插入性能测试 | 10 分钟 |
| 07 | 异步操作优化 | [md](./07_asynchronous_operations.md) / [sql](./07_asynchronous_operations_examples.sql) | 异步插入配置、async_insert 参数、等待策略 | 10 分钟 |
| 08 | Mutation 优化 | [md](./08_mutation_optimization.md) / [sql](./08_mutation_optimization_examples.sql) | 分区替换、轻量更新、Mutation 合并、避免高频 Mutation | 15 分钟 |
| 09 | 数据类型优化 | [md](./09_data_types.md) / [sql](./09_data_types_examples.sql) | 最小类型原则、避免 Nullable、低基数类型、物化列 | 15 分钟 |
| 10 | 常见性能模式 | [md](./10_common_patterns.md) / [sql](./10_common_patterns_examples.sql) | 预聚合、采样查询、增量聚合、TopN 模式 | 15 分钟 |
| 11 | 查询分析和 Profiling | [md](./11_query_profiling.md) / [sql](./11_query_profiling_examples.sql) | system.query_log 分析、慢查询定位、ProfileEvents、内存分析 | 15 分钟 |
| 12 | 查询分析器 | [md](./12_analyzer.md) / [sql](./12_analyzer_examples.sql) | enable_optimizer、EXPLAIN OPTIMIZE、PREWHERE 自动优化、并行化 | 10 分钟 |
| 13 | 缓存优化 | [md](./13_caching.md) / [sql](./13_caching_examples.sql) | 查询缓存、条件缓存、页缓存、缓存命中率监控、物化视图替代 | 15 分钟 |
| 14 | 硬件调优 | [md](./14_hardware_tuning.md) / [sql](./14_hardware_tuning_examples.sql) | CPU/内存/磁盘配置建议、性能基准测试、系统指标监控 | 10 分钟 |
| **15** | **Projections 投影深度** | **[sql](./15_projections_examples.sql)** | **Projections 创建与自动路由、与物化视图对比、性能测试、监控、局限** | **20 分钟** |
| **16** | **JOIN 策略深度** | **[sql](./16_join_strategies.sql)** | **JOIN 算法对比、分布式 JOIN 方案、字典替代 JOIN、列裁剪、陷阱与最佳实践** | **25 分钟** |

> **粗体** = 本批次新增的专家级专题

---

## 推荐学习路径

```
初学者路径:
  01_query_optimization → 02_primary_indexes → 03_partitioning → 09_data_types → 06_bulk_inserts

进阶路径:
  04_skipping_indexes → 05_prewhere_optimization → 08_mutation_optimization → 13_caching

专家路径:
  15_projections → 16_join_strategies → 12_analyzer → 11_query_profiling → 14_hardware_tuning

实战路径:
  10_common_patterns → 07_asynchronous_operations → 所有 SQL 示例实践
```

---

## 相关文档

- [01-getting-started/](../01-getting-started/README.md) — 基础使用
- [04-engines/](../04-engines/README.md) — 表引擎专题
- [07-data-mutation/](../07-data-mutation/README.md) — 数据变更专题
- [02-principles/](../02-principles/README.md) — 原理深度

## 更多资源

- [ClickHouse 性能优化文档](https://clickhouse.com/docs/en/operations/optimization)
- [ClickHouse 查询优化指南](https://clickhouse.com/docs/en/sql-reference/ansi)
- [ClickHouse 硬件推荐](https://clickhouse.com/docs/en/operations/hardware)