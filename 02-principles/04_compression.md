# 数据压缩与编码（专家级详解）

> 本章回答 ClickHouse 高性能的第三根支柱：**为什么列式压缩能省 5–10×存储、提速 2–5×查询**。读完本章，你应能：根据列的数据特征精准选 codec、读懂 `system.parts_columns` 诊断压缩率、避开"压不动的坑"。
>
> 配套可运行 SQL：[02_column_store.sql](./02_column_store.sql)（含 LZ4/ZSTD/Delta/Gorilla 实测对比）。集群：`treasurycluster`（CH 25.12.1.649）。

---

## 1. 本章解决什么问题（Why）

| 痛点 | 本章如何解答 |
|------|--------------|
| 同样 1 亿行数据，MySQL 占 50GB，ClickHouse 只占 3GB，凭什么？ | §2 列式压缩的物理原理（同列同类型 → 高压缩比） |
| LZ4 / ZSTD / Delta / Gorilla / DoubleDelta 一堆，怎么选？ | §4 codec 选择决策树 + 数据特征匹配表 |
| `CODEC(Delta, ZSTD)` 和 `CODEC(ZSTD)` 有什么区别？为什么组合更省？ | §3.4 组合 codec 的流水线原理 |
| 时间戳用 Delta 还是 Gorilla？Float64 用 Gorilla 对吗？ | §3.2/§3.3 各 codec 适用数据类型表 |
| LowCardinality 到底什么时候用？用错反而更慢？ | §5 LowCardinality 适用边界（基数 < 1 万） |
| 压缩率高就一定快吗？为什么 ZSTD(22) 反而慢？ | §6 压缩比 vs 速度的权衡（CPU vs I/O） |
| `ALTER TABLE ... MODIFY COLUMN ... CODEC(...)` 改了不生效？ | §7.2 codec 修改的隐藏陷阱（只对新 Part 生效） |

---

## 2. 核心原理：列式为什么压得这么狠

### 2.1 行存 vs 列存的压缩本质

```
行式存储（MySQL/PostgreSQL）：
┌──────────────────────────────────────────────┐
│ 行1: [id=1, name="Alice", age=25, city="BJ"] │  ← 一行内类型混合
│ 行2: [id=2, name="Bob",   age=30, city="SH"] │     Int/String/Int/String
│ 行3: [id=3, name="Carol", age=28, city="BJ"] │     压缩器看到: 1,"Alice",25,"BJ",2,"Bob",...
└──────────────────────────────────────────────┘
问题：类型交替 → 重复模式少 → 通用压缩器（LZ4/ZSTD）找不到规律 → 压缩比 1.5–2× 顶天

列式存储（ClickHouse）：
┌──────────────────────────────────────────────┐
│ id 列:    [1, 2, 3, 4, 5, ...]              │  ← 全是 UInt64，递增
│ age 列:   [25, 30, 28, 35, 22, ...]         │  ← 全是 UInt8，范围 0–255
│ city 列:  ["BJ", "SH", "BJ", "GZ", ...]     │  ← 全是 String，重复值多
│ name 列:  ["Alice", "Bob", "Carol", ...]    │  ← 全是 String
└──────────────────────────────────────────────┘
优势：同列同类型 → 重复模式密集 → 通用压缩器 + 专用编码双管齐下 → 压缩比 5–10×
```

**关键洞察**：压缩率的提升不来自"更好的算法"，而来自"数据组织方式让算法更易工作"。这是列存对行存的根本优势。

### 2.2 ClickHouse 的两层压缩流水线

ClickHouse 对每一列的存储经过 **编码（Codec）→ 通用压缩（Compression）** 两层处理：

```
原始列数据 [v1, v2, v3, ...]
      │
      ▼  ① 专用编码层（Codec，可选）
      │   - Delta:      存差值 [v2-v1, v3-v2, ...]     → 趋势数据差值小，更易压缩
      │   - DoubleDelta: 二次差值                       → 单调递增序列极佳
      │   - Gorilla:    XOR 编码                         → 浮点/时间戳，相邻值相似
      │   - T64:        位打包压缩                       → 整数列高位冗余
      │
      ▼  ② 通用压缩层（Compression，默认 LZ4）
      │   - LZ4:  极快，压缩比 2–4×
      │   - ZSTD: 稍慢，压缩比 3–6×（可调 level 1–22）
      │
      ▼
最终落盘的压缩字节流（写入 data.bin）
```

**两层为何协同**：专用编码把"有结构的数据"变成"更小的、更重复的字节流"，通用压缩再对字节流做最后压缩。例：时间戳列先 Delta 编码（变成小差值序列），再 ZSTD 压缩，比直接 ZSTD 省额外 2–3 倍。

---

## 3. 压缩算法与编码（Codec）详解

### 3.1 通用压缩算法：LZ4 vs ZSTD

| 维度 | LZ4（默认） | ZSTD |
|------|-------------|------|
| **压缩速度** | 极快（~500 MB/s） | 快（~100 MB/s，level=3） |
| **解压速度** | 极快（~2 GB/s） | 快（~1 GB/s） |
| **压缩比** | 2–4× | 3–6×（level 越高比越高，速度越慢） |
| **level 参数** | 无 | 1（快）–22（极慢，压缩比极限） |
| **CPU 占用** | 低 | 中（level 高则高） |
| **适用场景** | 热数据、查询频繁 | 冷数据、归档、存储敏感 |
| **何时选** | 默认；CPU 是瓶颈时 | 存储是瓶颈、I/O bound 查询 |

**关键认知**：
- LZ4 是 ClickHouse 的默认压缩算法，对绝大多数场景最优
- ZSTD 不是"更好"的 LZ4，而是"用 CPU 换存储/I/O"的权衡
- level 调高的边际收益递减：ZSTD(3) 比 LZ4 省 50%，ZSTD(22) 比 ZSTD(3) 只多省 10%，但慢 20 倍
- **生产推荐**：热表 LZ4；冷归档表 ZSTD(3–6)；切勿用 ZSTD(19+) 做在线查询表

### 3.2 Delta 编码：趋势数据的利器

**原理**：不存绝对值，存相邻值的差。对递增/递减序列，差值远小于原值，位宽更省。

```
原始 UInt64 时间戳列（秒）:
[1700000000, 1700000001, 1700000002, 1700000003, ...]
                    ↓ Delta 编码
[1700000000, +1, +1, +1, +1, ...]   ← 后续全是 1，再经 LZ4 压缩几乎不占空间

原始 UInt64 自增 ID:
[1, 2, 3, 4, ..., 1000000]
                    ↓ Delta
[1, 1, 1, 1, ..., 1]                ← 全 1，LZ4 后 < 1KB
```

**适用数据类型**：
- ✅ `UInt*` / `Int*` 递增序列（自增 ID、时间戳）
- ✅ `Date` / `DateTime`（底层是 UInt16/UInt32）
- ❌ `Float*`（差值无规律）
- ❌ 随机分布的整数（差值依然大）

**`Delta` vs `DoubleDelta`**：
| Codec | 编码 | 最适合 | 压缩效果 |
|-------|------|--------|----------|
| `Delta` | 一次差分 `v[i] - v[i-1]` | 线性递增（时间戳、ID） | 差值小且重复 |
| `DoubleDelta` | 二次差分 `Δ(v[i]) - Δ(v[i-1])` | 恒定速率递增（每秒固定 N 条） | 二次差为 0，极致压缩 |

**经验**：时间戳列 `DoubleDelta` 通常比 `Delta` 再省 30–50%，但要求"速率稳定"。波动大的用 `Delta`。

### 3.3 Gorilla 编码：浮点与时间戳专用

**原理**：Facebook 在论文 "Gorilla: A Fast, Scalable, In-Memory Time Series Database" 提出，基于"相邻浮点值的高位字节往往相同"这一观察，用 XOR + 前导零游程编码。

```
原始 Float64（CPU 利用率序列）:
[0.4521, 0.4523, 0.4525, 0.4520, ...]
                    ↓ Gorilla XOR 编码
v[0] 全量 64 位 → v[1]=v[0] XOR v[1]，结果高位为 0，只存变化的位
                → 相似浮点序列压缩到 1–2 bit/值
```

**适用数据类型**：
- ✅ `Float32` / `Float64`（传感器数据、监控指标、价格序列）
- ✅ `DateTime64`（毫秒/微秒时间戳）
- ❌ 整数（用 Delta 更好）
- ❌ 取值范围跳跃大的浮点（如随机 hash 转浮点）

**经典场景**：IoT 监控表 `metrics(ts DateTime64, cpu Float64, mem Float64)`，`ts` 用 `Gorilla`，`cpu/mem` 用 `Gorilla`，比默认 LZ4 省 3–5×。

### 3.4 组合 Codec：流水线叠加

ClickHouse 允许 codec 组合，按声明顺序串联执行：

```sql
-- 正确：先 Delta 编码，再 ZSTD 压缩
ts DateTime CODEC(Delta, ZSTD)

-- 执行顺序:
ts 原始值 → Delta 编码 → ZSTD 压缩 → 落盘
              (差值序列)   (压缩字节流)

-- 读取时反向: 落盘 → ZSTD 解压 → Delta 解码 → 原始值
```

**常见组合推荐**：

| 列类型 | 推荐组合 | 原因 |
|--------|----------|------|
| 时间戳 `DateTime` | `CODEC(Delta, ZSTD)` | Delta 压差值，ZSTD 再压一次 |
| 自增 ID `UInt64` | `CODEC(Delta, LZ4)` | 差值恒定，LZ4 已足够 |
| 监控浮点 `Float64` | `CODEC(Gorilla, ZSTD)` | Gorilla 压相似值，ZSTD 兜底 |
| 低基数字符串 | `LowCardinality(String)` + 默认 LZ4 | 字典编码本身已是高效 codec |
| 随机字符串（如 UUID） | `CODEC(ZSTD(6))` | 无规律，只能靠通用压缩 |
| Decimal 金额 | `CODEC(T64)` 或默认 | T64 压高位冗余 |

### 3.5 T64 编码：整数高位压缩

**原理**：很多整数列实际值域远小于类型表示范围（如 `UInt64` 存用户 ID，实际 < 10^9 只用 30 位，高 34 位全 0）。T64 把多个值的"有效位"打包，丢弃高位冗余。

```
UInt64 列实际值域 [0, 10^9)，每个值只用 30 位:
原始: [000...00010110..., 000...00011100..., ...]   每个 64 位
T64:  打包成连续 30 位流，节省 34/64 ≈ 53% 空间
```

**适用**：`Int*`/`UInt*` 且值域远小于类型范围。生产中较少手动指定，默认 LZ4 通常已够。

---

## 4. Codec 选择决策树

```
                       你的列是什么类型？
                            │
            ┌───────────────┼───────────────┐
            ▼               ▼               ▼
        整数/时间        浮点/Decimal       字符串
            │               │               │
   值是否递增/有趋势？    相邻值相似？     基数 < 1万？
        │       │           │     │         │     │
       是       否          是     否        是    否
        │       │           │     │         │     │
        ▼       ▼           ▼     ▼         ▼     ▼
   Delta/DoubleDelta    Gorilla  默认    LowCard  默认
   + ZSTD/LZ4           + ZSTD    LZ4    (自动)   ZSTD(3)

特殊场景:
  - 冷归档表（极少查询）: 全列 ZSTD(6-12)
  - 实时热表（高频查询）: 全列 LZ4（默认）
  - 超大表且 I/O bound:  组合 codec 提升压缩比
```

### 数据特征 → Codec 推荐表

| 数据特征 | 示例列 | 推荐 Codec | 预期压缩比 |
|----------|--------|------------|-----------|
| 单调递增整数 | `id UInt64`, `timestamp` | `Delta, LZ4` | 50–200× |
| 恒定速率递增 | 每秒固定 N 条的 `ts` | `DoubleDelta, LZ4` | 100–500× |
| 相似浮点序列 | CPU/内存指标 | `Gorilla, ZSTD` | 10–30× |
| 毫秒时间戳 | `DateTime64(3)` | `Gorilla` 或 `DoubleDelta` | 20–50× |
| 低基数字符串 | 枚举（省份/状态） | `LowCardinality(String)` | 10–50× |
| 中基数枚举 | 类目（< 1万种） | `LowCardinality(String)` | 5–10× |
| 高基数随机串 | UUID/trace_id | `ZSTD(6)` | 2–3× |
| 长文本 | 日志/描述 | `ZSTD(3)` | 3–5× |
| Decimal 金额 | 价格 `Decimal(18,2)` | `T64` 或默认 | 3–5× |
| 数组列 `Array(T)` | 标签数组 | 默认（数组元素单独压缩） | 取决于元素 |

---

## 5. LowCardinality：字典编码的边界

### 5.1 原理

`LowCardinality(T)` 对基数（distinct 值数）小的列，建立"值字典 + 索引数组"：

```
原始 city 列 (String):
["北京", "上海", "北京", "广州", "北京", "上海", ...]

LowCardinality 编码:
字典:    [0:北京, 1:上海, 2:广州]          ← 只存 3 个字符串各一次
索引:    [0, 1, 0, 2, 0, 1, ...]           ← 每行存 UInt8 索引（1 字节）

节省: 原每行 "北京"=6字节 → 索引 1 字节，且索引列再经 LZ4 压缩到几乎 0
```

### 5.2 适用边界（关键！）

| 基数 | 推荐 | 原因 |
|------|------|------|
| < 1 万 | ✅ 强烈推荐 | 字典小，索引 2 字节，省 80%+ |
| 1 万 – 10 万 | ⚠️ 谨慎 | 字典占内存，需实测 |
| > 10 万 | ❌ 不要用 | 字典比原数据还大，反慢 |
| 无限增长（如 UUID） | ❌ 绝对不要 | 字典膨胀，写入变慢 |

**坑**：
- `LowCardinality` 字典在内存中，查询时需加载，基数过大占内存
- 对 `LowCardinality` 列做 `LIKE '%xx%'` 比 `String` 慢（需先反字典化）
- 适合 `=` / `IN` 等值查询，不适合模糊匹配

### 5.3 实测对比（见 02_column_store.sql）

预期结果：低基数（4 种事件类型）下，`LowCardinality(String)` 比 `String` 压缩后省 3–5 倍。

---

## 6. 压缩比 vs 速度的权衡

### 6.1 核心矛盾

```
压缩比 ↑  →  磁盘 I/O ↓  →  查询快（I/O bound 时）
         →  CPU ↑       →  查询慢（CPU bound 时）
```

**判断你属于哪种 bound**：
- 查询大量行、聚合算子简单（count/sum）→ **I/O bound** → 高压缩比有益
- 查询少量行、复杂计算（regex/JSON/复杂 UDF）→ **CPU bound** → 高压缩比有害

### 6.2 ZSTD level 实测建议

| level | 压缩比（相对 LZ4） | 压缩速度 | 解压速度 | 推荐场景 |
|-------|-------------------|----------|----------|----------|
| 1 | 省 30% | 快 | 极快 | 通用 |
| 3 | 省 50% | 中 | 快 | **默认推荐** |
| 6 | 省 60% | 慢 | 中 | 冷数据 |
| 12 | 省 65% | 很慢 | 中 | 归档 |
| 22 | 省 70% | 极慢 | 中 | 极端归档（几乎不用） |

**生产经验**：在线表用 ZSTD(3) 已是甜蜜点，再高边际收益小于 CPU 损失。

---

## 7. 实战与陷阱

### 7.1 查看/诊断压缩效果

```sql
-- 查看每列的压缩详情（最常用诊断查询）
-- 【注意】CH 25.x system.parts_columns 用 column_data_compressed_bytes /
--   column_data_uncompressed_bytes(每列粒度), 而非 data_compressed_bytes(整 Part)
SELECT
    column,
    data_type,
    formatReadableSize(sum(column_data_compressed_bytes)) AS compressed,
    formatReadableSize(sum(column_data_uncompressed_bytes)) AS uncompressed,
    round(sum(column_data_uncompressed_bytes) / sum(column_data_compressed_bytes), 2) AS ratio,
    any(compression_codec) AS codec
FROM system.parts_columns
WHERE database = 'tutorial' AND table = 'your_table' AND active = 1
GROUP BY column, data_type
ORDER BY compressed DESC;
```

**诊断思路**：
- `ratio` < 2：压缩不动，检查是否选错 codec（如随机串用了 Delta）
- `ratio` > 50：压缩极好，正常（递增列、LowCardinality）
- 某列 `compressed` 占全表 80%+：该列是存储瓶颈，优先优化

### 7.2 修改 codec 的陷阱

```sql
-- 期望：把 value 列从 LZ4 改成 ZSTD
ALTER TABLE t MODIFY COLUMN value Float64 CODEC(ZSTD(3));
```

**坑**：`MODIFY COLUMN ... CODEC(...)` **只对新插入/合并产生的 Part 生效**，老 Part 保持原 codec。要让全表立即生效：

```sql
-- 方式 1: 触发全表重组（重写所有 Part，代价大）
ALTER TABLE t UPDATE value = value WHERE 1;  -- 强制重写
-- 或
OPTIMIZE TABLE t FINAL;

-- 方式 2: 接受渐进式迁移（推荐）
-- 新数据用新 codec，老数据随 TTL/合并自然替换
```

### 7.3 全局压缩配置（config.xml）

```xml
<!-- 对所有新表生效的全局压缩策略 -->
<compression>
    <!-- 冷数据（> 1 个月）用高压缩 -->
    <case>
        <min_part_age_days>30</min_part_age_days>
        <method>zstd</method>
        <level>6</level>
    </case>
    <!-- 默认热数据用 LZ4 -->
</compression>
```

**注意**：全局配置是"按 Part 年龄"动态切换，不是建表时固化。适合"热表冷化"场景。

### 7.4 常见误区

1. **"压缩率越高越好"** → 错。CPU bound 查询会被高压缩比拖慢。
2. **"LowCardinality 总是好的"** → 错。高基数列反受其害。
3. **"ZSTD(22) 最省空间就该用"** → 错。写入慢 20 倍，查询也慢。
4. **"改 codec 立即生效"** → 错。只对新 Part 生效，老数据需重组。
5. **"Float 不能压缩"** → 错。Gorilla 对相似浮点压缩极好。
6. **"Delta 编码适合所有整数"** → 错。随机分布整数 Delta 后差值仍大，无效。

### 7.5 最佳实践

1. **默认 LZ4 起步**：90% 场景默认即最优
2. **时间戳列加 Delta**：`CODEC(Delta, ZSTD)` 几乎总是有益
3. **低基数字符串用 LowCardinality**：枚举/状态/类目列标配
4. **监控浮点用 Gorilla**：IoT/监控场景显著省空间
5. **冷热分层**：热表 LZ4，冷归档 ZSTD(6+)
6. **用 system.parts_columns 诊断**：定期查 ratio，发现"压不动"的列
7. **建表时定好 codec**：改 codec 代价大，初始设计最关键

---

## 8. 自测题

1. 同样 1 亿行数据，为什么 ClickHouse 比 MySQL 小 10 倍？是算法更先进吗？
2. `CODEC(Delta, ZSTD)` 的两层处理顺序是什么？为什么不能反过来？
3. 时间戳列用 `Delta` 还是 `DoubleDelta`？取决于什么数据特征？
4. `LowCardinality(String)` 的基数超过多少就不该用？为什么？
5. `ALTER TABLE ... MODIFY COLUMN ... CODEC(ZSTD)` 执行后，老数据会立即用新 codec 吗？
6. 一个 CPU bound 的复杂查询表，应该用 LZ4 还是 ZSTD(22)？为什么？
7. 如何用一条 SQL 查出某张表"最占空间且压缩比最低"的列？

答案线索均在本 README 及 [02_column_store.sql](./02_column_store.sql) 中。

---

## 9. 关联章节

- [02_column_store.sql](./02_column_store.sql) —— 压缩 codec 实测对比（LZ4/ZSTD/Delta/Gorilla/LowCardinality）
- [03_mergetree.sql](./03_mergetree.sql) —— Part 物理结构（codec 作用在 Part 的列文件上）
- [05_indexing.md](./05_indexing.md) —— 稀疏索引与 mark（压缩如何影响 mark 定位）
- [02-principles/README.md](./README.md) —— 高性能六大支柱之"数据压缩"

---

## 10. 参考资源

- [ClickHouse 压缩配置](https://clickhouse.com/docs/en/operations/compression)
- [Column Codec 文档](https://clickhouse.com/docs/en/sql-reference/statements/create/table#column-codecs)
- [LowCardinality 类型](https://clickhouse.com/docs/en/sql-reference/data-types/low-cardinality)
- [Gorilla 论文](https://www.vldb.org/pvldb/vol8/p1816-teller.pdf)
- [ZSTD 算法](https://github.com/facebook/zstd)
