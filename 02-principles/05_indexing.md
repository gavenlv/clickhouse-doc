# 索引机制（专家级详解）

> 本章回答 ClickHouse 高性能的第四根支柱：**为什么 10 亿行表按主键查只需毫秒**。读完本章，你应能：说清稀疏索引 + mark 的定位机制、设计高效的 `ORDER BY` 主键、判断何时该加跳数索引、看懂 `EXPLAIN` 中的索引裁剪。
>
> 配套可运行 SQL：[03_mergetree.sql](./03_mergetree.sql)（含主键 mark 验证、跳数索引实测）。集群：`treasurycluster`（CH 25.12.1.649）。

---

## 1. 本章解决什么问题（Why）

| 痛点 | 本章如何解答 |
|------|--------------|
| 为什么 ClickHouse 没有传统 B+Tree 还能秒查 10 亿行？ | §2 稀疏索引 + mark 定位机制 |
| `ORDER BY (a, b, c)` 三列顺序怎么定？为什么换一下慢 100 倍？ | §3.2 主键列顺序的最左前缀原理 |
| `index_granularity = 8192` 默认值要不要改？大好还是小好？ | §3.4 粒度权衡（I/O vs 内存） |
| 跳数索引 `minmax` / `set` / `bloom_filter` / `tokenbf_v1` 一堆，何时用哪个？ | §4.3 跳数索引选型决策表 |
| `WHERE` 条件里用了函数，索引就不生效了吗？ | §3.5 主键失效的常见写法 |
| 加了跳数索引为什么 `SELECT` 没变快？ | §4.4 跳数索引的 GRANULARITY 与触发条件 |
| `PARTITION BY` 和 `ORDER BY` 都能加速，区别是什么？ | §5 分区裁剪 vs 主键索引的分工 |

---

## 2. 核心原理：稀疏索引 + Mark 机制

### 2.1 为什么不用 B+Tree（稠密索引）

传统数据库（MySQL InnoDB）用 B+Tree，**每行一个索引项**：

```
MySQL B+Tree（稠密索引）:
┌─────────────────────────────────────────────┐
│ 1000 万行表 → 1000 万个索引项                │
│ 每项 (key=42, row_ptr=0x7f8a) 约 16 字节     │
│ 索引总大小: 1000 万 × 16B ≈ 160 MB           │
│ 必须常驻内存才能快，否则频繁磁盘 I/O          │
└─────────────────────────────────────────────┘
问题：10 亿行表索引就 16GB，内存放不下，性能崩塌
```

ClickHouse 面向"扫亿级数据做聚合"的场景，稠密索引不现实。它用**稀疏索引**：每 N 行（默认 8192）才记一个索引项。

### 2.2 稀疏索引的物理结构

一个 MergeTree Part 在磁盘上的物理文件：

```
Part 目录: 202401_1_5_2/
├── primary.idx      ← 主键索引（极小！每 8192 行一个 mark 的主键值）
├── [列].mrk2        ← 每列的 mark 文件（每 8192 行记录该列在 data.bin 中的偏移）
├── [列].bin         ← 列的实际压缩数据
├── [列].idx2        ← 跳数索引数据（如有）
└── count.json       ← Part 元信息
```

### 2.3 Mark 定位机制（核心！）

`index_granularity = 8192` 意味着：每 8192 行组成一个"granule"（颗粒），是 ClickHouse 读写数据的**最小单元**。

```
表数据（1000 万行，ORDER BY user_id）:

行号:        0        8192       16384      24576      ... 
             │          │           │           │
主键值:    user_id=1  user_id=15  user_id=23  user_id=31  ← primary.idx 记录
             │          │           │           │
mark 编号:   mark0      mark1       mark2       mark3      ← data.mrk2 记录偏移
             │          │           │           │
data.bin:  [blob0]    [blob1]     [blob2]     [blob3]     ← 每块 8192 行的压缩数据
```

**查询 `WHERE user_id = 23` 的定位过程**：

```
1. 读 primary.idx（极小，常驻内存）
   → 二分查找 user_id=23
   → 落在 [mark2(user_id=23), mark3(user_id=31)) 区间
   → 定位到 mark2

2. 读 user_id.mrk2 的 mark2 项
   → 得到 user_id 列在 data.bin 中的 (offset, size)
   → 同理可得其他列的偏移

3. 解压 data.bin 中 mark2 对应的 8192 行数据块
   → 在内存中线性扫描这 8192 行，过滤出 user_id=23 的行

结果: 只读了 1 个 granule（8192 行），而非全表 1000 万行
```

**关键认知**：
- ClickHouse 主键索引**不是用来"精确找到某一行"**，而是用来"快速跳到大致区域"
- 真正的过滤在"内存中扫描 8192 行 granule"完成
- 8192 这个值是经验值：太小 → mark 太多索引变大、随机 I/O 多；太大 → 单次扫描的行多、过滤效率低

### 2.4 稀疏索引 vs 稠密索引对比

| 维度 | 稀疏索引（ClickHouse） | 稠密索引（MySQL B+Tree） |
|------|----------------------|--------------------------|
| 索引项数 | 行数 / 8192 | 行数 |
| 10 亿行索引大小 | ~1.2 MB | ~16 GB |
| 能否常驻内存 | ✅ 轻松 | ❌ 大表困难 |
| 点查单行 | 慢（要扫 8192 行过滤） | 极快（直接定位） |
| 范围扫描聚合 | 极快（顺序读） | 一般（随机 I/O） |
| 适合场景 | OLAP 聚合扫描 | OLTP 点查 |

**这就是 ClickHouse 不适合"按主键查单行"而适合"扫亿级行做聚合"的根本原因。**

---

## 3. 主键（ORDER BY）设计原理

### 3.1 ORDER BY 的双重身份

ClickHouse 的 `ORDER BY` 同时是：
1. **主键索引**（primary.idx 按此列排序记录 mark）
2. **数据物理排序**（data.bin 按此顺序存储）

这与 MySQL 不同：MySQL 主键索引和数据的聚簇顺序可以分离（二级索引回表）。ClickHouse 的数据**本身就是按 ORDER BY 排序存储**的，因此：
- `ORDER BY` 列的范围查询 → 顺序 I/O，极快
- `ORDER BY` 列的等值查询 → 二分定位 mark，扫描 1 个 granule
- **非 `ORDER BY` 列的查询 → 全表扫描**（除非加跳数索引，见 §4）

### 3.2 主键列顺序：最左前缀原理

`ORDER BY (a, b, c)` 意味着数据先按 `a` 排序，`a` 相同再按 `b`，再按 `c`。主键索引的 `primary.idx` 也是按 `(a, b, c)` 排序记录的。

**最左前缀规则**：查询只能利用 `ORDER BY` 的"最左连续前缀"做二分裁剪。

```
ORDER BY (user_id, event_date, id)

查询条件                          能用主键裁剪？
WHERE user_id = 1                 ✅ 完全利用
WHERE user_id = 1 AND event_date  ✅ 利用 (user_id, event_date)
WHERE user_id = 1 AND id = 5      ⚠️ 只用 user_id，id 部分失效
WHERE event_date = '2024-01-01'   ❌ 无法利用（跳过了 user_id）
WHERE id = 5                      ❌ 无法利用
```

**为什么 `event_date` 在中间时，跳过它后面的 `id` 用不上？**
因为 `primary.idx` 中 `id` 在 `user_id` 相同时才有序。如果只查 `event_date`，整个索引在 `event_date` 维度是无序的，无法二分。

### 3.3 主键列顺序设计原则

| 原则 | 说明 | 反例 |
|------|------|------|
| ① 查询频率高的列在前 | 最常做 `WHERE` 的列放最左 | 把 `id`（极少查）放第一 |
| ② 选择性高的列在前 | distinct 值多，裁剪效果好 | 把 `status`（3 个值）放第一 |
| ③ 范围查询列在后 | 等值列在前，范围列在后 | `(date_range, user_id)` 错误 |
| ④ 列数 3–4 个为宜 | 太多主键索引变大、写入变慢 | 6+ 列主键 |
| ⑤ 避免 monotonous 列在前 | 如纯递增 `timestamp` 单列，所有新数据进最后 mark，写入热点 | 单用 `timestamp` 做主键 |

**经典反例**：
```sql
-- ❌ 错：把低选择性 status 放第一，几乎所有查询都要扫多个 mark
ORDER BY (status, user_id, event_date)

-- ✅ 对：高频高选择性 user_id 在前
ORDER BY (user_id, event_date, id)
```

### 3.4 index_granularity 粒度权衡

`index_granularity`（默认 8192）控制每个 granule 的行数：

| 粒度 | 优点 | 缺点 | 适用 |
|------|------|------|------|
| 小（4096） | mark 多，过滤更精确，扫描行少 | primary.idx 变大，内存占用高，随机 I/O 多 | 点查多、过滤性强的表 |
| 默认（8192） | 平衡 | 平衡 | **90% 场景** |
| 大（16384+） | 索引更小，顺序读更高效 | 单 granule 扫描行多，过滤浪费 | 纯聚合扫描、低过滤表 |

**何时考虑改**：
- 表小（< 1000 万行）且点查多 → 可试 4096
- 表巨大（> 100 亿）且多聚合 → 可试 16384
- **多数情况默认 8192 已最优，不要乱改**

### 3.5 主键失效的常见写法

```sql
-- ❌ 在主键列上套函数 → 主键失效，全表扫描
WHERE toDate(event_time) = '2024-01-15'        -- 应改: event_time >= '2024-01-15' AND < '2024-01-16'
WHERE toYYYYMM(event_date) = 202401             -- 应改: event_date >= '2024-01-01' AND < '2024-02-01'
WHERE user_id + 1 = 100                         -- 应改: user_id = 99
WHERE lower(name) = 'alice'                     -- 主键完全失效

-- ❌ 类型不匹配导致隐式转换 → 可能失效
WHERE event_date = '2024-01-15 00:00:00'        -- Date 列与 DateTime 比较

-- ✅ 正确：直接对主键列做等值/范围比较
WHERE event_date = '2024-01-15'
WHERE user_id = 100 AND event_date BETWEEN '2024-01-01' AND '2024-01-31'
```

---

## 4. 跳数索引（Data Skipping Index）

### 4.1 跳数索引解决什么问题

主键索引只能加速 `ORDER BY` 列的查询。**非主键列**的过滤（如 `WHERE status = 'active'`）默认要全表扫描。

跳数索引在 granule 之上再建一层"摘要"，让查询能"跳过"确定不含目标数据的 granule：

```
无跳数索引:
WHERE status = 'active' → 扫描全部 1000 个 granule（每个 8192 行）

有 set 跳数索引(每 4 个 granule 一个摘要):
WHERE status = 'active' → 查摘要，跳过 status 只含 'inactive' 的 granule 块
                        → 可能只扫 50 个 granule，省 20×

跳数索引本质: "概要过滤器"，不能精确定位，只能粗筛
```

### 4.2 跳数索引的 GRANULARITY 参数

```sql
ALTER TABLE t ADD INDEX idx_status status TYPE set(100) GRANULARITY 4;
--                                                        ↑
--                              每 4 个数据 granule（4 × 8192 = 32768 行）聚合成一个索引块
```

- `GRANULARITY = 1`：每 8192 行一个索引块，过滤最精细，但索引最大
- `GRANULARITY = 4`（常见）：每 32768 行一块，平衡
- `GRANULARITY = N`：每 N×8192 行一块

**权衡**：GRANULARITY 小 → 过滤精准但索引大；大 → 索引小但可能误放行（把含目标值的块也跳过）。

### 4.3 跳数索引类型选型决策表

| 类型 | 原理 | 适用数据 | 适用查询 | 不适用 |
|------|------|----------|----------|--------|
| `minmax` | 记录每块的 min/max | 数值、日期 | 范围查询 `>`, `<`, `BETWEEN` | 等值查询、字符串 |
| `set(N)` | 记录每块的 distinct 值集合（最多 N 个） | 低基数枚举（< N） | 等值 `=`、`IN` | 高基数（超 N 失效）、范围 |
| `bloom_filter` | 布隆过滤器，可能有假阳性 | 高基数字符串、数值 | 等值 `=`、`IN` | 范围、模糊匹配 |
| `tokenbf_v1` | token 级布隆过滤器 | 文本，按非字母数字分词 | `LIKE '%token%'`、`hasToken()` | 精确等值、前缀 |
| `ngrambf_v1` | n-gram 布隆过滤器 | 文本，按 N 字符切分 | `LIKE '%phrase%'`、`search()` | 精确等值 |

**选型决策树**：
```
查询是范围查询(>, <, BETWEEN)?
  └─ 是 → minmax

查询是等值(=, IN)?
  └─ 列基数?
       ├─ < 1000 → set(1000)
       ├─ 高基数 → bloom_filter(0.01)

查询是模糊匹配(LIKE '%xx%')?
  └─ 分词方式?
       ├─ 按单词(英文) → tokenbf_v1
       └─ 按字符(n-gram, 中文) → ngrambf_v1
```

### 4.4 跳数索引的触发与陷阱

**触发条件**：查询的 `WHERE` 必须包含索引列的"可下推"条件，且索引已物化。

```sql
-- 添加索引后，需对已有数据物化（新建索引只对新 Part 生效）
ALTER TABLE t ADD INDEX idx_x x TYPE bloom_filter(0.01) GRANULARITY 4;
-- 老 Part 不会自动建索引！需:
OPTIMIZE TABLE t FINAL;  -- 强制重组，或等自然合并
```

**常见陷阱**：
1. **加了索引没变快** → 老 Part 未物化索引，需 `OPTIMIZE FINAL` 或等合并
2. **`set(N)` N 设太小** → distinct 值超 N 时该块索引失效，退化成全扫描
3. **`bloom_filter` 假阳性** → 可能有"漏网"的块要扫，但不漏报（不会跳过含目标值的块）
4. **索引不是免费的** → 每个索引增加写入和合并开销，索引越多写入越慢
5. **`LIKE '%xx%'` 用 `minmax` 没用** → minmax 只对范围有效，模糊匹配要用 tokenbf/ngrambf

### 4.5 跳数索引 vs 主键索引

| 维度 | 主键索引 | 跳数索引 |
|------|----------|----------|
| 作用对象 | ORDER BY 列 | 任意列 |
| 精度 | mark 级（8192 行） | GRANULARITY 级（可更粗） |
| 是否排序 | 数据按此排序 | 不改数据顺序 |
| 数量限制 | 1 个（ORDER BY） | 多个 |
| 维护成本 | 自动 | 需 `OPTIMIZE` 物化老 Part |
| 优先级 | **永远先优化主键** | 主键无法覆盖的列才考虑 |

**原则**：先优化 `ORDER BY` 主键（覆盖最高频查询），再用跳数索引补漏。不要指望跳数索引替代主键。

---

## 5. 分区裁剪 vs 主键索引

很多人混淆 `PARTITION BY` 和 `ORDER BY` 的加速作用：

| 维度 | `PARTITION BY` | `ORDER BY` |
|------|----------------|------------|
| 作用层 | 分区级（物理隔离） | Part 内 mark 级 |
| 裁剪粒度 | 整个分区跳过 | mark 级二分定位 |
| 典型用法 | `toYYYYMM(date)` 按月 | `(user_id, date)` |
| 查询加速 | `WHERE date` 范围 → 跳过无关月份分区 | `WHERE user_id = X` → 定位 mark |
| 协同 | 先分区裁剪（粗筛），再主键定位（细筛） | — |

**执行顺序**：
```
查询: WHERE event_date = '2024-01-15' AND user_id = 100
ORDER BY (user_id, event_date), PARTITION BY toYYYYMM(event_date)

1. 分区裁剪: 只看 202401 分区（跳过其他月份）
2. 主键定位: 在 202401 分区的 Part 内，按 (user_id, event_date) 二分找 mark
3. 读取 granule: 解压 mark 对应的 8192 行，过滤
```

**分区设计原则**：
- 用时间分区（`toYYYYMM` / `toYYYYMMDD`），便于 TTL 与裁剪
- 分区数不要过多（< 1000），否则元数据爆炸、合并变慢
- 分区键尽量与高频查询的时间范围对齐

---

## 6. 实战诊断

### 6.1 查看主键与索引

```sql
-- 查看表的主键列
SELECT name, type FROM system.columns
WHERE database = 'tutorial' AND table = 'your_table' AND is_in_primary_key = 1;

-- 查看跳数索引
SELECT name, type, expr, granularity FROM system.data_skipping_indices
WHERE database = 'tutorial' AND table = 'your_table';
```

### 6.2 验证索引是否被使用

```sql
-- 执行前后对比 read_rows
-- 【前置】system.query_log 需在 config.xml 启用; 若未启用, 用 system.query_thread_log
--   (SET log_query_threads = 1) 或 EXPLAIN 估算替代
SELECT read_rows, read_bytes, query_duration_ms
FROM system.query_log
WHERE query LIKE '%your_table%' AND type = 'QueryFinish'
ORDER BY event_time DESC LIMIT 5;

-- 如果加了索引 read_rows 没降 → 索引未生效（检查物化、条件可下推）
```

### 6.3 EXPLAIN 查看裁剪

```sql
EXPLAIN indexes = 1
SELECT count() FROM your_table WHERE user_id = 100;
-- 输出会显示 UsedIndexes / SelectedParts / SelectedMarks
```

---

## 7. 常见误区与最佳实践

### 误区
1. **"主键就是唯一索引"** → 错。ClickHouse 主键不保证唯一，只是排序键。
2. **`ORDER BY` 列越多越好** → 错。列多则索引大、写入慢，3–4 列最佳。
3. **跳数索引能替代主键** → 错。跳数索引是粗筛，主键才是核心。
4. **加了跳数索引立即生效** → 错。老 Part 需 `OPTIMIZE FINAL` 物化。
5. **`WHERE` 里用函数不影响索引** → 错。主键列套函数直接失效。
6. **小表也要优化索引** → 不必要。千万行以下默认配置已够。

### 最佳实践
1. **`ORDER BY` 放最高频高选择性列**：如 `user_id`、`device_id`
2. **时间列做分区，不一定要进主键**：`PARTITION BY toYYYYMM(date)` 已能裁剪
3. **跳数索引按需添加**：先 EXPLAIN 看是否全扫描，再针对性加
4. **`set` 索引 N 值要够**：设为列基数的 1.2 倍以上
5. **监控 `read_rows`**：慢查询先看读了多少行，判断是否索引失效
6. **别在 `WHERE` 对主键列套函数**：用范围比较替代 `toDate()`/`toYYYYMM()`

---

## 8. 自测题

1. ClickHouse 为什么不用 B+Tree？稀疏索引省了多少空间？
2. `ORDER BY (a, b, c)` 下，`WHERE b = 1` 能用主键吗？为什么？
3. `index_granularity = 8192` 意味着查单行最多要扫多少行？
4. `WHERE toDate(event_time) = '2024-01-15'` 为什么慢？怎么改？
5. `set(100)` 索引在列有 200 个 distinct 值时会怎样？
6. 跳数索引加了但 `read_rows` 没降，可能的原因有哪些？
7. `PARTITION BY toYYYYMM(date)` 和 `ORDER BY date` 都能加速 `WHERE date`，区别？

答案线索均在本 README 及 [03_mergetree.sql](./03_mergetree.sql) 中。

---

## 9. 关联章节

- [03_mergetree.sql](./03_mergetree.sql) —— Part 物理结构与 mark 验证
- [04_compression.md](./04_compression.md) —— 压缩如何影响 mark 定位（granule 内数据是压缩块）
- [06_query_execution.md](./06_query_execution.md) —— 查询管道如何利用索引裁剪
- [08-performance](../08-performance/README.md) —— 索引性能调优实战

---

## 10. 参考资源

- [ClickHouse 索引文档](https://clickhouse.com/docs/en/engines/table-engines/mergetree-family/mergetree#table_engine-mergetree-index)
- [跳数索引](https://clickhouse.com/docs/en/engines/table-engines/mergetree-family/mergetree#table_engine-mergetree-data_skipping-indexes)
- [EXPLAIN 语法](https://clickhouse.com/docs/en/sql-reference/statements/explain)
- [index_granularity 调优](https://clickhouse.com/docs/en/operations/settings/merge-tree-settings)
