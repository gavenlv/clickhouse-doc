# 查询执行流程（专家级详解）

> 本章回答 ClickHouse 高性能的第二根支柱：**为什么 ClickHouse 查询比传统数据库快 100–1000 倍**。读完本章，你应能：画出 SQL 从字符串到结果的完整管道、说清向量化执行 + SIMD 的原理、理解 PREWHERE 为何能省 80% I/O、用 EXPLAIN 诊断慢查询。
>
> 配套可运行 SQL：[01_overview.sql](./01_overview.sql)（含 EXPLAIN 三种用法、query_log 解读）。集群：`treasurycluster`（CH 25.12.1.649）。

---

## 1. 本章解决什么问题（Why）

| 痛点 | 本章如何解答 |
|------|--------------|
| 一条 SQL 进去，ClickHouse 内部到底干了什么？ | §2 完整管道：Parser → Analyzer → Interpreter → Pipeline |
| 为什么 ClickHouse 比 MySQL 快 100 倍？是算法更优吗？ | §3 向量化执行 + SIMD，本质是"批量处理替代逐行" |
| `PREWHERE` 和 `WHERE` 有什么区别？为什么 PREWHERE 快？ | §4.1 PREWHERE 的"先读过滤列再读其他列"机制 |
| `EXPLAIN PLAN` / `EXPLAIN PIPELINE` / `EXPLAIN ESTIMATE` 看什么？ | §5 三种 EXPLAIN 的用途与读法 |
| `max_threads = 8` 设大一定快吗？ | §6 并行执行的拆分粒度与 Amdahl 定律 |
| 聚合查询为什么有时快有时慢？ | §7 聚合管道的两阶段（局部聚合 → 合并）与内存压力 |
| 查询日志里 `read_rows` / `read_bytes` / `memory_usage` 怎么读？ | §8 query_log 字段解读与诊断思路 |

---

## 2. 查询处理全管道

### 2.1 四阶段总览

```
SQL 字符串: "SELECT user_id, sum(amount) FROM orders WHERE date = '2024-01-01' GROUP BY user_id"
   │
   ▼  ① Parser（语法解析）
   │   SQL → AST（抽象语法树）
   │   纯语法层面，不关心表是否存在
   │
   ▼  ② Analyzer（语义分析）
   │   AST → Resolved AST
   │   - 解析表名/列名（查 system.tables / system.columns）
   │   - 类型推导、隐式转换
   │   - 谓词下推、常量折叠等逻辑优化
   │
   ▼  ③ Interpreter（计划生成）
   │   Resolved AST → QueryPlan（查询计划树）
   │   - 选择 Source（读哪个 Part）
   │   - 决定 Filter / Aggregating / Sorting 算子
   │   - 应用索引裁剪（partition + primary + skip index）
   │
   ▼  ④ Pipeline（物理执行）
   │   QueryPlan → Pipeline（有向无环图 DAG）
   │   - 算子拆成 Processor（Source/Filter/Transform/Sink）
   │   - 多线程并行执行，数据以 Block（列式批次）流动
   │
   ▼
结果集（向客户端推送）
```

### 2.2 Parser 阶段：SQL → AST

Parser 是手写的递归下降解析器（不是 flex/bison 生成），追求速度。它只做语法分析：

```
SQL: SELECT user_id, sum(amount) FROM orders WHERE date = '2024-01-01' GROUP BY user_id

AST 树:
SelectQuery
├── select: [Identifier(user_id), Function(sum, [Identifier(amount)])]
├── from: Identifier(orders)
├── where: Function(=, [Identifier(date), Literal('2024-01-01')])
└── group_by: [Identifier(user_id)]
```

**关键**：Parser 不验证 `orders` 表是否存在、`amount` 列是否存在。这些在 Analyzer 阶段做。这也是为什么拼写错误的表名要到执行时才报错（除非用 `EXPLAIN`）。

### 2.3 Analyzer 阶段：语义分析与优化

Analyzer 做两件事：**解析**（resolve）+ **优化**。

```
解析:
- 表名 → 找到实际表（system.tables）
- 列名 → 找到列定义（system.columns）
- 类型推导：sum(amount) 如果 amount 是 Decimal(10,2)，结果类型是 Decimal(10,2)

逻辑优化（基于规则）:
- 谓词下推: WHERE 推到子查询内部
- 常量折叠: WHERE 1=1 AND x=5 → WHERE x=5
- 列裁剪: SELECT * 但实际只用 2 列 → 只读 2 列
- 分区裁剪: WHERE date → 只选相关分区 Part
- 主键裁剪: WHERE user_id → 二分定位 mark 范围
```

### 2.4 Interpreter 阶段：生成查询计划

Interpreter 把优化后的 AST 转成 **QueryPlan**（查询计划树），每个节点是一个算子：

```
QueryPlan 树（自底向上执行）:

    CreatingSets (GROUP BY 后的 distinct 计算)
         │
    Aggregating (MergingAggregated)        ← 第二阶段：合并各线程的局部聚合
         │
    Aggregating (Aggregating)              ← 第一阶段：各线程本地聚合
         │
    Filter (WHERE date = '2024-01-01')
         │
    MergeTreeSelect (读取 Part 的 granule)
         │
    [Part1, Part2, Part3 ...]              ← 选中的 Part 列表
```

### 2.5 Pipeline 阶段：物理执行

QueryPlan 被转换成 **Pipeline**：一个由 Processor 组成的 DAG，数据以 **Block**（列式批次，通常 65536 行）为单位流动。

```
Pipeline DAG（多线程并行）:

  Thread1: [Read Part1] → [Filter] → [Agg local] ─┐
  Thread2: [Read Part2] → [Filter] → [Agg local] ─┼→ [Agg merge] → [Result]
  Thread3: [Read Part3] → [Filter] → [Agg local] ─┘
  ...

每个箭头是一个 Block 流（列式数据批次）
Processor 之间有缓冲队列，自动背压（下游慢则上游阻塞）
```

**关键概念**：
- **Processor**：Pipeline 的节点，分 Source（产生数据）、Transform（变换）、Sink（消费数据）
- **Block**：数据传输单元，一个 Block = 多列的列式批次（默认 65536 行）
- **Port**：Processor 的输入/输出端口
- **背压**：下游 Block 队列满时，上游自动暂停，避免 OOM

---

## 3. 向量化执行：为什么快 100 倍

### 3.1 逐行 vs 批量

```
传统解释执行（MySQL/PostgreSQL）:
for each row in table:
    result = func(row.column1, row.column2)   ← 每次处理 1 行
    save(result)

向量化执行（ClickHouse）:
for each batch (65536 行) in column:
    result_batch = func_vectorized(batch.column1, batch.column2)  ← 一次处理一批
    save(result_batch)
```

**为什么批量快**：
1. **减少循环开销**：1 次循环处理 65536 行，vs 65536 次循环
2. **CPU 缓存友好**：连续内存访问，L1/L2 cache 命中率高
3. **SIMD 指令**：一条指令同时处理多个数据（见 §3.2）
4. **减少分支预测失败**：批量处理时分支模式稳定

### 3.2 SIMD 指令：单指令多数据

现代 CPU 支持 SIMD（Single Instruction Multiple Data），如 AVX2（256 位）、AVX-512（512 位）：

```
标量加法（无 SIMD）:
[1,2,3,4,5,6,7,8] + [10,20,30,40,50,60,70,80]
→ 8 次加法: 1+10, 2+20, ..., 8+80

AVX2 SIMD 加法（256 位 = 8 个 Float32）:
一条指令同时算 8 个加法: [11,22,33,44,55,66,77,88]
→ 速度提升 8 倍

AVX-512 SIMD 加法（512 位 = 16 个 Float32）:
一条指令算 16 个加法 → 速度提升 16 倍
```

ClickHouse 大量使用 SIMD 优化：算术运算、比较、聚合（sum/count/avg）、字符串操作（substring/position）等。

### 3.3 向量化对列存的依赖

向量化**依赖列式存储**才能高效：

```
行式存储做向量化:
要算 sum(price), price 分散在每行中间
→ 取 price 要跳过其他列 → 内存不连续 → SIMD 无法高效加载

列式存储做向量化:
price 列连续存储: [10.5, 20.3, 8.7, ...] 连续内存
→ SIMD 直接 load 256 位 → 8 个 Float32 一次处理
```

**这是"列存 + 向量化"协同的本质**：列存让数据连续，向量化让 CPU 高效利用这种连续性。两者缺一不可。

### 3.4 哪些算子被向量化了

| 算子类别 | 向量化状态 | 说明 |
|----------|-----------|------|
| 算术（+,-,*,/） | ✅ 全向量化 | SIMD 加速 |
| 比较（=,<,>） | ✅ 全向量化 | 生成 bitmask |
| 聚合（sum,count,avg） | ✅ 全向量化 | 累加器批量更新 |
| 字符串（substring,position） | ✅ 大部分 | 复杂正则除外 |
| 日期函数 | ✅ 大部分 | 底层是整数运算 |
| 正则 `match/extract` | ⚠️ 部分向量化 | 复杂正则回退到标量 |
| JSON 解析 | ❌ 标量 | 复杂结构难向量化 |
| 自定义 UDF | ❌ 标量 | 视实现而定 |

**启示**：能用内置向量化函数就别用复杂正则/UDF，性能差 10–100 倍。

---

## 4. PREWHERE：省 80% I/O 的利器

### 4.1 PREWHERE 原理

普通 `WHERE` 一次读取所有列，再过滤。`PREWHERE` 先只读过滤条件涉及的列，过滤后再读其他列：

```
表: 100 列，1 亿行，查询 WHERE status = 'active' (命中率 5%)

普通 WHERE:
1. 读取全部 100 列 × 1 亿行 = 100 亿列值  ← 巨大 I/O
2. 在内存中过滤 status = 'active'
3. 返回 500 万行 × 100 列

PREWHERE status = 'active':
1. 只读 status 列 × 1 亿行 = 1 亿列值     ← 1% I/O
2. 过滤得到 500 万行的 bitmask
3. 只对这 500 万行读其余 99 列 = 4.95 亿列值  ← 5% I/O
4. 返回 500 万行 × 100 列

总 I/O: 100 亿 → 5.95 亿，省 94%
```

### 4.2 PREWHERE 的两种用法

```sql
-- ① 手动指定（明确告诉 CH 先过滤哪列）
SELECT user_id, event_type, value
FROM events
PREWHERE event_date = '2024-01-15'   ← 先读这列过滤
WHERE user_id = 123;                  ← 再对剩余行过滤

-- ② 自动 PREWHERE（CH 默认开启）
SET optimize_move_to_prewhere = 1;    ← 默认开
SELECT * FROM events WHERE event_date = '2024-01-15' AND user_id = 123;
-- CH 自动把选择性高的条件移到 PREWHERE
```

### 4.3 PREWHERE 的适用与禁忌

**适用**：
- 表列多（> 10 列）、查询只用少数列
- 过滤条件选择性强（命中率高，如 5%–20%）
- 过滤列是主键或小列（I/O 小）

**禁忌**：
- 过滤条件命中率接近 100% → PREWHERE 反而多读一次列，变慢
- 过滤列是大列（如长文本 String）→ 先读它不划算
- 用 `count()` 只读一列 → PREWHERE 无意义（本就只读一列）

### 4.4 PREWHERE vs WHERE 对比

| 维度 | `WHERE` | `PREWHERE` |
|------|---------|------------|
| 读取顺序 | 一次读所有列 | 先读过滤列，再读其余列 |
| I/O 量 | 大（全列） | 小（过滤后剩余行的列） |
| 适用 | 过滤率低、列少 | 过滤率高、列多 |
| 自动优化 | — | `optimize_move_to_prewhere` 默认开 |
| 多个条件 | 都在 WHERE | 只能一个 PREWHERE |

**实践**：大多数情况让 CH 自动优化即可，手动 PREWHERE 留给调优场景。

---

## 5. EXPLAIN：诊断查询的三种武器

### 5.1 EXPLAIN PLAN（看计划树）

```sql
EXPLAIN PLAN
SELECT user_id, count() FROM events WHERE date = '2024-01-01' GROUP BY user_id;
```

输出是查询计划树，自底向上读。关注：
- `ReadFromMergeTree` → 看选了哪些 Part、多少 mark
- `Filter` → WHERE 是否下推
- `Aggregating` → 聚合分几阶段
- `Sorting` → 是否有额外排序开销

### 5.2 EXPLAIN PIPELINE（看物理执行）

```sql
EXPLAIN PIPELINE
SELECT count() FROM events;
```

输出是 Processor 级 DAG，看：
- 多少个 Read 线程（`max_threads`）
- 是否有 MergingAggregated（两阶段聚合）
- Processor 之间的连接（Ports）

### 5.3 EXPLAIN ESTIMATE（看估算成本）

```sql
EXPLAIN ESTIMATE
SELECT count() FROM events WHERE user_id = 100;
```

输出估算的 `rows` / `bytes` / `parts`，不实际执行。用于快速判断查询代价。

### 5.4 EXPLAIN indexes = 1（看索引使用）

```sql
EXPLAIN indexes = 1
SELECT count() FROM events WHERE user_id = 100;
```

输出会显示 `SelectedParts` / `SelectedMarks` / `UsedIndexes`，判断索引是否生效。

---

## 6. 并行执行原理

### 6.1 max_threads 的作用

```sql
SET max_threads = 8;
SELECT count() FROM huge_table;
```

ClickHouse 按 `max_threads` 把数据拆成 N 份，每份一个线程处理：

```
1 亿行表, max_threads = 8:

Thread1: 处理 Part1 (1250 万行) → partial_count=12500000 ─┐
Thread2: 处理 Part2 (1250 万行) → partial_count=12500000  ├→ 合并 = 100000000
...                                                       │
Thread8: 处理 Part8 (1250 万行) → partial_count=12500000 ─┘
```

### 6.2 Amdahl 定律与并行极限

并行加速比受"串行部分"限制：

```
查询 = 95% 可并行（扫表聚合）+ 5% 串行（结果合并、网络）
8 线程: 加速比 = 1 / (0.05 + 0.95/8) ≈ 6.3 倍（不是 8 倍）
16 线程: 加速比 = 1 / (0.05 + 0.95/16) ≈ 9.1 倍
32 线程: 加速比 = 1 / (0.05 + 0.95/32) ≈ 12.3 倍（边际递减）
```

**何时调大 `max_threads`**：
- 大表全表扫描 → 调大有益
- 小表 / 点查 → 调大无益，反而线程开销大
- **默认值** = CPU 核数，多数场景最优

### 6.3 并行聚合的两阶段

```
SELECT user_id, sum(amount) FROM orders GROUP BY user_id

Stage 1: 局部聚合（各线程并行）
Thread1: 读 Part1 → 本地哈希表 {user1: 100, user2: 200}
Thread2: 读 Part2 → 本地哈希表 {user1: 150, user3: 80}
...

Stage 2: 合并聚合（单线程或少量线程）
合并所有哈希表: {user1: 250, user2: 200, user3: 80}
```

**关键**：聚合结果如果有 N 个分组，Stage 2 要处理 N 个合并。分组数极大（如百万）时 Stage 2 成瓶颈。

---

## 7. 聚合管道深入

### 7.1 聚合的内存模型

ClickHouse 聚合用**哈希表**，内存布局：

```
聚合: SELECT user_id, sum(amount) FROM orders GROUP BY user_id

内存中哈希表:
┌──────────────────────────────┐
│ key=user1 → {sum=250, cnt=3} │
│ key=user2 → {sum=200, cnt=2} │
│ key=user3 → {sum=80,  cnt=1} │
│ ...                          │
└──────────────────────────────┘

问题: 分组数巨大（如 1 亿 user_id）→ 哈希表占内存 → OOM
```

### 7.2 内存不够怎么办：Spill to Disk

当哈希表超过内存限制，ClickHouse 会 **spill（溢写）到磁盘**：

```
1. 哈希表满 → 按哈希值分桶
2. 部分桶写到磁盘临时文件
3. 内存只保留一个桶继续聚合
4. 处理完内存桶 → 读下一个磁盘桶
5. 最终合并所有桶结果
```

**代价**：磁盘 I/O，比纯内存慢 10–100 倍。监控 `memory_usage` 和 `spill_size`。

### 7.3 聚合优化技巧

```sql
-- ① 减少分组数：能否预聚合？
-- 慢: SELECT user_id, sum(x) FROM events GROUP BY user_id  -- 千万分组
-- 快: 先按天预聚合到日表（物化视图），再查日表

-- ② 用 *State 函数预聚合（见 04-functions）
-- AggregatingMergeTree + sumState → 查询时 sumMerge

-- ③ 限制内存
SET max_memory_usage = 10000000000;  -- 10GB
SET max_bytes_before_external_group_by = 5000000000;  -- 5GB 后 spill
```

---

## 8. 查询日志诊断

### 8.1 system.query_log 关键字段

> **前置条件**：`system.query_log` 需在 `config.xml` 启用 `<query_log>` 段。部分环境（如本测试集群）为省 CPU 用 `<query_log remove="1"/>` 禁用了它。若表不存在，可改用 `system.query_thread_log`（需 `SET log_query_threads = 1`）或 `system.processes`（看实时查询）。生产环境**强烈建议开启** query_log，它是慢查询诊断的唯一权威数据源。

```sql
SELECT
    query,
    query_duration_ms,                              -- 耗时
    read_rows,                                      -- 读取行数（关键！）
    read_bytes,                                     -- 读取字节数
    formatReadableSize(memory_usage) AS memory,     -- 内存峰值
    formatReadableSize(read_bytes) AS data_read,
    type                                            -- QueryStart/QueryFinish/ExceptionBeforeStart/ExceptionWhileProcessing
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_time > now() - INTERVAL 1 HOUR
ORDER BY query_duration_ms DESC
LIMIT 10;
```

### 8.2 诊断思路

| 症状 | 可能原因 | 排查 |
|------|----------|------|
| `read_rows` ≈ 全表行数 | 索引未生效 / 无 WHERE | 检查 WHERE 是否用了主键列、是否套函数 |
| `read_bytes` 大但 `read_rows` 小 | 读了大列（长 String） | 检查是否 `SELECT *`，能否只查需要的列 |
| `memory_usage` 接近 `max_memory_usage` | 聚合分组太多 | 加 `max_bytes_before_external_group_by` 或预聚合 |
| `query_duration_ms` 高但 `read_rows` 低 | CPU bound（复杂函数） | 简化函数，避免正则/JSON |
| `type = ExceptionWhileProcessing` | 执行中报错 | 看 `exception` 字段 |

### 8.3 EXPLAIN + query_log 组合诊断

```sql
-- 1. 先 EXPLAIN 看计划是否合理
EXPLAIN indexes = 1 SELECT ... ;

-- 2. 执行查询
SELECT ... ;

-- 3. 查 query_log 看实际读了多少
SELECT read_rows, read_bytes, query_duration_ms, memory_usage
FROM system.query_log WHERE query LIKE '%your_query%' AND type = 'QueryFinish'
ORDER BY event_time DESC LIMIT 1;

-- 4. 对比预期：如果 EXPLAIN 显示只读 100 万行，但 query_log 显示读 1 亿 → 索引未生效
```

---

## 9. 常见误区与最佳实践

### 误区
1. **"ClickHouse 快是因为 C++ 写的"** → 不是。是列存 + 向量化 + 稀疏索引的架构优势。
2. **"max_threads 越大越快"** → 错。受 Amdahl 定律限制，且线程开销有成本。
3. **"PREWHERE 总是比 WHERE 快"** → 错。命中率接近 100% 时反而慢。
4. **"聚合一定在内存中"** → 错。内存不够会 spill 到磁盘，慢 10–100 倍。
5. **"EXPLAIN 能看到真实行数"** → EXPLAIN ESTIMATE 是估算，看真实读多少用 query_log。
6. **"复杂正则和内置函数一样快"** → 错。正则难向量化，慢 10–100 倍。

### 最佳实践
1. **让 CH 自动 PREWHERE**：保持 `optimize_move_to_prewhere = 1`
2. **大聚合用预聚合**：物化视图 + `*State` 函数
3. **监控 `read_rows`**：慢查询第一步看读了多少行
4. **`max_threads` 默认即可**：除非大表扫描，否则别动
5. **避免 `SELECT *`**：只查需要的列，列存下差异巨大
6. **聚合前加 `max_bytes_before_external_group_by`**：防 OOM，宁可 spill 不要崩

---

## 10. 自测题

1. ClickHouse 查询比 MySQL 快 100 倍，主要原因是什么？（提示：三个支柱）
2. `PREWHERE` 为什么比 `WHERE` 省 I/O？它先读什么列？
3. 向量化执行为什么依赖列式存储？行存能向量化吗？
4. `max_threads = 32` 为什么不能让查询快 32 倍？
5. 聚合查询 `GROUP BY` 分组数极大时，为什么会变慢甚至 OOM？
6. `EXPLAIN PLAN` 和 `EXPLAIN PIPELINE` 看的东西有什么区别？
7. `query_log` 里 `read_rows` 等于全表行数，说明什么问题？

答案线索均在本 README 及 [01_overview.sql](./01_overview.sql) 中。

---

## 11. 关联章节

- [01_overview.sql](./01_overview.sql) —— EXPLAIN 三种用法、query_log 解读实战
- [02_column_store.sql](./02_column_store.sql) —— 向量化执行演示
- [05_indexing.md](./05_indexing.md) —— 索引裁剪如何减少 read_rows
- [04-functions/README.md](../04-functions/README.md) —— 聚合状态函数与两阶段聚合
- [11-performance](../11-performance/README.md) —— 查询性能调优实战

---

## 12. 参考资源

- [ClickHouse 查询执行](https://clickhouse.com/docs/en/operations/query-cache)
- [EXPLAIN 语法](https://clickhouse.com/docs/en/sql-reference/statements/explain)
- [Pipeline 与 Processor](https://clickhouse.com/docs/en/development/architecture)
- [向量化执行](https://clickhouse.com/docs/en/development/algorithm-implementation)
- [PREWHERE 优化](https://clickhouse.com/docs/en/sql-reference/statements/select/prewhere)
- [system.query_log](https://clickhouse.com/docs/en/operations/system-tables/query_log)
