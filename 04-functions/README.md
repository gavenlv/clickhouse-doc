# ClickHouse 函数与窗口函数（专家级详解）

> 本章是 ClickHouse 的"表达能力核心"。读完本章，你应能：根据业务场景精准选函数、理解聚合状态函数的底层机制、用窗口函数解决跨行计算、识别常见性能陷阱。
>
> 配套可运行 SQL：[01_basic_functions_examples.sql](./01_basic_functions_examples.sql)、[02_window_functions_examples.sql](./02_window_functions_examples.sql)。集群已启动（`treasurycluster`，CH 25.12.1.649），所有 SQL 均已验证零错误。

---

## 1. 本章解决什么问题（Why）

ClickHouse 的函数体系远比传统 OLTP 数据库庞大，且有几个"反直觉"设计：

| 痛点 | 本章如何解答 |
|------|--------------|
| 同样是"求和"，为什么有 `sum` / `sumWithOverflow` / `sumState` / `sumMerge`？它们到底什么关系？ | §3.1 聚合状态函数原理，讲透"两阶段聚合" |
| 物化视图预聚合为什么必须用 `*State` 函数，用 `sum` 会怎样？ | §3.2 AggregatingMergeTree 完整示例 + 对比 |
| 窗口函数的 `ROWS` 和 `RANGE` 到底差在哪？默认 frame 是什么？ | §4.3 窗口帧原理图解 |
| `arrayJoin` 为什么"一行变多行"？和 `arrayMap` 区别？ | §3.3 数组函数的"展开 vs 映射" |
| 老的 `JSONExtract*` 和新的 `JSON` 类型该用哪个？ | §3.4 JSON 方案对比决策表 |
| `count()` / `count(*)` / `count(列)` 哪个对？NULL 怎么算？ | §3.5 计数函数的坑 |

---

## 2. 函数体系全景图

```
┌─────────────────────────────────────────────────────────────────┐
│                   ClickHouse 函数分类                              │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ① 标量函数（Scalar）：一行进一行出，可在任何表达式位置使用          │
│     ├─ 字符串：length / substring / splitByChar / replaceRegexpAll│
│     ├─ 日期：toDate / toDateTime / dateDiff / toStartOfDay       │
│     ├─ 数学：round / floor / pow / sqrt / sin / log              │
│     ├─ 条件：if / multiIf / nullIf / ifNull / coalesce            │
│     ├─ 类型转换：CAST / toInt32 / toFloat64 / toDecimal128       │
│     ├─ 哈希：sipHash64 / xxHash64 / cityHash64 / intHash32       │
│     ├─ IP：toIPv4 / toIPv6 / IPv4CIDRToRange                     │
│     ├─ 数组：arrayJoin / arrayMap / arrayFilter / arraySum       │
│     ├─ JSON：JSONExtractString / JSONExtractUInt / visitParam*   │
│     └─ Map：mapApply / mapPopulateSeries / mapKeys / mapValues   │
│                                                                  │
│  ② 聚合函数（Aggregate）：多行进一行出，配合 GROUP BY 使用           │
│     ├─ 基础：count / sum / avg / min / max / any / anyLast       │
│     ├─ 统计：varPop / varSamp / stddevPop / quantile / topK      │
│     ├─ 组合子（Combinator）：*If / *Array / *State / *Merge       │
│     └─ 状态型：sumState / quantileState / uniqState ...          │
│                                                                  │
│  ③ 窗口函数（Window）：多行进一行出，但不折叠行数                    │
│     ├─ 排名：row_number / rank / dense_rank / ntile              │
│     ├─ 导航：lag / lead / first_value / last_value / nth_value   │
│     └─ 聚合窗口：sum/avg/count OVER (...)                          │
│                                                                  │
│  ④ 表函数（Table Function）：返回一个表，用在 FROM 子句             │
│     ├─ numbers(N) / generateRandom                              │
│     ├─ file() / url() / remote()                                │
│     └─ cluster('name', db, table)                               │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

**最易混淆的三组**（本章重点对比）：
1. `sum` vs `sumState`+`sumMerge` → §3.1
2. `arrayJoin` vs `arrayMap` → §3.3
3. `ROWS` vs `RANGE` frame → §4.3

---

## 3. 核心原理：聚合状态函数（*State / *Merge）

> 这是本章最重要的进阶内容，也是 ClickHouse 实现"实时预聚合"的基石。原文件**完全缺失**，本节专门补齐。

### 3.1 一个问题引出 *State

**业务场景**：有一张 10 亿行的明细订单表 `orders`，要做"按天+品类"的实时 GMV 报表。

**方案 A（朴素）**：每次查询都扫全表
```sql
SELECT toDate(order_time) AS d, category, sum(amount) AS gmv
FROM orders GROUP BY d, category;
```
问题：10 亿行每次扫，慢且费 CPU。

**方案 B（物化视图预聚合）**：用 `sumState` 把"中间状态"物化到日表
```sql
-- 明细表
CREATE TABLE orders (...) ENGINE = MergeTree ORDER BY ...;

-- 预聚合表：列类型是 AggregateFunction，不是数值！
CREATE TABLE orders_daily_mv ENGINE = AggregatingMergeTree ORDER BY (d, category) AS
SELECT
    toDate(order_time) AS d,
    category,
    sumState(amount) AS gmv_state   -- ← 关键：存"状态"而非"和"
FROM orders
GROUP BY d, category;

-- 查询：用 sumMerge 把状态合并出最终值
SELECT d, category, sumMerge(gmv_state) AS gmv
FROM orders_daily_mv
GROUP BY d, category;
```

### 3.2 原理：状态到底是什么？

`sumState(amount)` **不返回数值**，返回的是 `AggregateFunction(Sum, Decimal(10,2))` 类型的**二进制中间状态**。可以理解为：

```
普通 sum:   [1,2,3,4] ──聚合──> 10          （直接出结果）
sumState:   [1,2,3,4] ──序列化─> <State: {sum=10, count=4, ...}>
                                      ↑
                                二进制 blob，可存储、可传输、可再合并
sumMerge:   <State: {sum=10}> + <State: {sum=20}> ──> 30
```

**为什么不能直接 `sum` 存到预聚合表？** 因为日表里 `sum=10` 已经丢失了"怎么算出来的"，无法再做"日→月"的二级聚合而不丢精度（比如加权平均、分位数根本无法从已聚合值恢复）。**状态函数保留了"可继续聚合"的能力**，这是 ClickHouse 实时数仓的核心。

### 3.3 *State / *Merge 全家族对比表

| 聚合目标 | 普通函数 | State 函数（存状态） | Merge 函数（合并状态出结果） | 典型场景 |
|----------|----------|----------------------|------------------------------|----------|
| 求和 | `sum(x)` | `sumState(x)` | `sumMerge(s)` | GMV、计数累加 |
| 计数 | `count()` | `countState()` | `countMerge(s)` | PV/UV 累计 |
| 唯一计数 | `uniq(x)` | `uniqState(x)` | `uniqMerge(s)` | UV（HLL 状态） |
| 分位数 | `quantile(0.9)(x)` | `quantile(0.9)(x)` 的 `quantileState(0.9)(x)` | `quantileMerge(0.9)(s)` | P99 延迟监控 |
| 最大值 | `max(x)` | `maxState(x)` | `maxMerge(s)` | 峰值指标 |
| 数组收集 | `groupArray(x)` | `groupArrayState(x)` | `groupArrayMerge(s)` | 漏斗步骤收集 |
| TopK | `topK(10)(x)` | `topKState(10)(x)` | `topKMerge(10)(s)` | 热搜榜 |

**关键规则**：
- `*State` 返回 `AggregateFunction(...)` 类型，**不能直接 SELECT 看数值**（看到的是二进制）
- `*Merge` 输入是状态列，输出是最终值
- 状态列必须用 `AggregatingMergeTree` 引擎，INSERT 时同主键的状态会**自动 merge**（这是引擎行为，不是查询行为）
- `SimpleAggregateFunction` 是简化版：用于 `sum`/`max`/`any` 等可"直接相加"的聚合，存普通值而非二进制状态，更省空间

### 3.4 完整可运行示例（见 01 SQL 文件 §11）

01 SQL 文件新增了完整章节：明细表 → AggregatingMergeTree 预聚合表 → 二级（月）聚合 → 性能对比，全部可在集群验证。

---

## 4. 核心原理：窗口函数与窗口帧

### 4.1 窗口函数 vs 聚合函数

```
聚合函数 (GROUP BY):           窗口函数 (OVER):
┌──────────────────┐           ┌──────────────────────────────┐
│ 原始 3 行          │           │ 原始 3 行                      │
│   A  10           │           │   A  10  ← +running_sum=10    │
│   A  20   ──GROUP BY──>  │   A  20  ← +running_sum=30    │
│   A  30           │   A:60    │   A  30  ← +running_sum=60    │
│                   │ (1 行)    │ (仍 3 行，每行带窗口结果)        │
└──────────────────┘           └──────────────────────────────┘
折叠行数                         不折叠行数
```

### 4.2 OVER 子句三要素

```sql
function(args) OVER (
    [PARTITION BY 列]        -- 分区：相当于"分组边界"
    [ORDER BY 列]            -- 排序：决定"前后"语义
    [frame_clause]           -- 帧：当前行的计算范围
)
```

- **不写 PARTITION BY**：整张表是一个分区
- **写了 ORDER BY 但不写 frame**：默认 frame = `RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW`（这是最隐蔽的坑，见 §4.3）
- **不写 ORDER BY 也不写 frame**：默认 frame = 整个分区（`ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING`）

### 4.3 窗口帧 ROWS vs RANGE（核心难点）

```
数据:  价格 [100, 100, 200, 300]
       ORDER BY price

ROWS BETWEEN 1 PRECEDING AND CURRENT ROW   (物理行)
  行1(100): 帧=[100]              avg=100
  行2(100): 帧=[100,100]          avg=100
  行3(200): 帧=[100,200]          avg=150
  行4(300): 帧=[200,300]          avg=250

RANGE BETWEEN 100 PRECEDING AND CURRENT ROW  (值范围: price-100 ~ price)
  行1(100): 值域[0,100]  匹配行=[100,100]  avg=100
  行2(100): 值域[0,100]  匹配行=[100,100]  avg=100
  行3(200): 值域[100,200] 匹配行=[100,100,200] avg=133.3
  行4(300): 值域[200,300] 匹配行=[200,300]  avg=250
```

**对比表**：

| 维度 | ROWS | RANGE |
|------|------|-------|
| 单位 | 物理行位置 | ORDER BY 列的值范围 |
| 并列值处理 | 每行独立 | 同值同帧 |
| 常见用法 | 移动平均(N 天/行) | 累计到当前"值" |
| 性能 | 快（按行定位） | 慢（需值比较） |
| 默认 | —— | `ORDER BY` 时的默认 frame |

**最隐蔽的坑**：写 `sum(x) OVER (ORDER BY d)` 看似"累计求和"，但默认是 `RANGE`，当 `d` 有重复值时，**同值的行会一起算进同一帧**，导致"累计值跳变"。要安全做累计求和，应显式写 `ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW`。

### 4.4 三类窗口函数选型

| 类别 | 函数 | 何时用 |
|------|------|--------|
| 排名 | `row_number` | 唯一编号、分页、取 Top-N |
| 排名 | `rank` | 允许并列且跳号（如"第 1/1/3 名"） |
| 排名 | `dense_rank` | 允许并列不跳号（如"第 1/1/2 名"） |
| 排名 | `ntile(N)` | 切桶（四分位、十分位） |
| 导航 | `lag(col, n)` | 环比、同环比、间隔检测 |
| 导航 | `lead(col, n)` | 预测下一条、趋势 |
| 导航 | `first_value`/`last_value` | 区间首末值（注意 frame！`last_value` 默认到当前行，需显式 `UNBOUNDED FOLLOWING` 才是分区末） |
| 聚合窗口 | `sum/avg/count OVER` | 累计、移动平均、占比 |

---

## 5. 关键函数深度对比（决策表）

### 5.1 计数函数

| 写法 | 行为 | NULL 处理 | 推荐 |
|------|------|-----------|------|
| `count()` | 计所有行 | 不忽略（算行） | ✅ ClickHouse 惯用 |
| `count(*)` | 同 `count()` | 同上 | 可用，但非惯用 |
| `count(col)` | 计 col 非空行 | 忽略 NULL | 统计非空时用 |
| `count(DISTINCT col)` | 精确去重 | 忽略 NULL | 准确但慢，大数据用 `uniq` |
| `uniq(col)` | 近似去重（HLL） | 忽略 NULL | 大数据 UV，误差 <1% |
| `uniqExact(col)` | 精确去重 | 忽略 NULL | 等同 `count(DISTINCT)` |

### 5.2 数组：展开 vs 映射

| 函数 | 行为 | 输入→输出行数 | 场景 |
|------|------|---------------|------|
| `arrayJoin(arr)` | 把数组展开成多行 | 1 行 → N 行 | 标签表展开、事件拆解 |
| `arrayMap(f, arr)` | 对每个元素套函数 | 1 行 → 1 行 | 批量变换，如 `arrayMap(x->x*2, arr)` |
| `arrayFilter(f, arr)` | 过滤元素 | 1 行 → 1 行 | 筛选满足条件的元素 |
| `arrayAggregate(f, arr)` | 数组内聚合 | 1 行 → 1 值 | `arraySum`/`arrayAvg` 的通用形式 |

**核心区别**：`arrayJoin` 改变行数（展开），其余保持行数（变换）。`arrayJoin` 是 ClickHouse 独有的"反聚合"能力，等价于其他库的 `UNNEST`。

### 5.3 JSON 方案对比

| 方案 | 类型 | 适用 | 性能 | 灵活性 |
|------|------|------|------|--------|
| `JSONExtract*(str, path)` | String + 函数解析 | 已有 String 列存 JSON | 每次查询解析，慢 | 高 |
| `visitParam*(str, key)` | String + 轻量解析 | 简单扁平 JSON | 比 JSONExtract 快 | 低（只支持简单结构） |
| `JSON` 类型（实验） | 原生类型 | 新建表 | 解析一次，查询快 | 高 |
| 子列提取 + 物化 | 普通列 | 高频查询字段 | 最快 | 需提前建模 |

**推荐**：高频查询字段抽成普通列 + 索引；低频/动态字段用 `JSONExtract*`；新表可试 `JSON` 类型。

### 5.4 条件函数

| 函数 | 等价 SQL | 何时用 |
|------|----------|--------|
| `if(cond, a, b)` | `CASE WHEN cond THEN a ELSE b END` | 二选一，简洁 |
| `multiIf(c1,a1, c2,a2, ..., default)` | 嵌套 `CASE` | 多分支，避免深层嵌套 |
| `nullIf(a, b)` | `CASE WHEN a=b THEN NULL ELSE a END` | 除零保护、过滤哨兵值 |
| `ifNull(a, b)` | `COALESCE(a, b)` | NULL 兜底 |
| `coalesce(a, b, c)` | 同 | 多级兜底 |

---

## 6. 文件导航

| 文件 | 内容 | 关键章节 |
|------|------|----------|
| [01_basic_functions_examples.sql](./01_basic_functions_examples.sql) | 标量 + 聚合 + 状态函数 | §1 聚合基础、§11 **聚合状态函数（sumState/sumMerge + AggregatingMergeTree）**、§6 数组（arrayJoin）、§10 JSON |
| [02_window_functions_examples.sql](./02_window_functions_examples.sql) | 排名/导航/聚合窗口 + 帧 | §2 排名函数、§3 累计求和、§7 **窗口帧 ROWS vs RANGE**、§8 实战场景 |

---

## 7. 常见误区与最佳实践

### 误区
1. **在 `AggregatingMergeTree` 表上直接 `SELECT sum_state_col` 期望看到数值** → 看到二进制，必须 `sumMerge(col)`
2. **`last_value(price) OVER (ORDER BY d)` 期望得到分区最后一个值** → 默认 frame 到当前行，得到的是"当前行值"，需 `ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING`
3. **`sum(x) OVER (ORDER BY d)` 做累计求和，d 有重复值时结果跳变** → 默认 `RANGE` frame，同值同帧；改用 `ROWS`
4. **`count(DISTINCT col)` 对亿级数据** → 极慢，改用 `uniq(col)`（误差 <1%）
5. **用 `//` 注释** → ClickHouse 只支持 `--` 注释，`//` 会语法错误
6. **`arrayJoin` 和 `arrayMap` 混用** → `arrayJoin` 改变行数，`arrayMap` 不变

### 最佳实践
1. **实时预聚合三件套**：明细表（MergeTree）+ 物化视图（`AggregatingMergeTree` + `*State`）+ 查询（`*Merge`）
2. **分位数监控用 `quantileState`**：避免每次重算 P99
3. **UV 用 `uniqState`**：跨分片合并无损
4. **窗口函数加 `PARTITION BY`**：避免全表单分区导致性能灾难
5. **移动平均显式写 frame**：`ROWS BETWEEN N PRECEDING AND CURRENT ROW`
6. **`multiIf` 替代嵌套 `CASE WHEN`**：可读性更好

---

## 8. 自测题（理解检查点）

完成本章后，应能回答：

1. 为什么 `sumState` 不能直接 `SELECT` 看到求和结果？它的返回类型是什么？
2. `AggregatingMergeTree` 在什么时机把状态 merge？是查询时还是写入时？
3. `sum(x) OVER (ORDER BY d)` 和 `sum(x) OVER (ORDER BY d ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)` 在 `d` 有重复值时结果有何不同？
4. `last_value(col) OVER (PARTITION BY k ORDER BY t)` 默认返回什么？如何得到分区真正的末值？
5. `arrayJoin(['a','b','c'])` 返回几行？`arrayMap(x->upper(x), ['a','b'])` 返回几行？
6. `uniq` 和 `count(DISTINCT)` 的区别？什么时候选哪个？
7. 如何用 `*State`/`*Merge` 实现"日表 → 月表"的二级聚合且不丢精度？

答案线索均在本 README 及配套 SQL 文件中。

---

## 9. 关联章节

- [03-engines](../03-engines/README.md) —— `AggregatingMergeTree` / `SummingMergeTree` 引擎详解
- [16-principle](../16-principle/README.md) —— 聚合管道、向量化执行原理
- [11-performance](../11-performance/README.md) —— 函数对查询性能的影响
- [10-date-update](../10-date-update/README.md) —— 日期函数大全

---

## 10. 参考资源

- [ClickHouse 聚合函数](https://clickhouse.com/docs/en/sql-reference/aggregate-functions)
- [聚合状态 combinator (*State/*Merge)](https://clickhouse.com/docs/en/sql-reference/aggregate-functions/combinators)
- [AggregatingMergeTree 引擎](https://clickhouse.com/docs/en/engines/table-engines/mergetree-family/aggregatingmergetree)
- [窗口函数](https://clickhouse.com/docs/en/sql-reference/window-functions)
