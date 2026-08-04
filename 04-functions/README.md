# ClickHouse 函数体系（专家级详解）

> 本章是 ClickHouse 的"表达能力核心"。读完本章，你应能：根据业务场景精准选函数、理解聚合组合子（Combinator）的底层机制、用窗口函数解决跨行计算、掌握 UDF 的适用场景与局限、在 JSON 处理方案中做出正确决策。
>
> 配套可运行 SQL 5 个文件：`01_basic` → `02_window` → `03_combinators` → `04_udf` → `05_json`。集群已启动（`treasurycluster`，CH 25.12.1.649），所有 SQL 均已验证零错误。

---

## 1. 本章解决什么问题（Why）

ClickHouse 的函数体系远比传统 OLTP 数据库庞大，且有几个"反直觉"设计。以下是 10+ 个常见痛点，以及本章如何解答：

| # | 痛点 | 本章如何解答 |
|---|------|--------------|
| 1 | 同样是"求和"，为什么有 `sum` / `sumWithOverflow` / `sumState` / `sumMerge`？它们到底什么关系？ | §3.1 聚合状态函数原理，讲透"两阶段聚合" |
| 2 | 物化视图预聚合为什么必须用 `*State` 函数，用 `sum` 会怎样？ | §3.2 AggregatingMergeTree 完整示例 + 对比 |
| 3 | 窗口函数的 `ROWS` 和 `RANGE` 到底差在哪？默认 frame 是什么？ | §4.3 窗口帧原理图解 |
| 4 | `arrayJoin` 为什么"一行变多行"？和 `arrayMap` 区别？ | §3.3 数组函数的"展开 vs 映射" |
| 5 | 老的 `JSONExtract*` 和新的 `JSON` 类型该用哪个？ | §5.3 JSON 方案对比决策表 |
| 6 | `count()` / `count(*)` / `count(列)` 哪个对？NULL 怎么算？ | §5.1 计数函数的坑 |
| 7 | `sumIf` 和 `sum(if(...))` 哪个快？为什么？ | `03_aggregate_combinators.sql` §11 性能对比 |
| 8 | 聚合组合子（-If / -State / -Array / -ForEach）怎么链式使用？ | `03_aggregate_combinators.sql` §10 链式组合子 |
| 9 | ClickHouse 的 UDF 为什么不能做聚合？生产环境怎么用？ | `04_udf.sql` §4 局限 + §6 生产建议 |
| 10 | `visitParam` 和 `JSONExtract` 什么关系？为什么说 visitParam 已废弃？ | `05_json_functions.sql` §6 迁移指南 |
| 11 | JSON 嵌套数组（三层以上）怎么高效解析？ | `05_json_functions.sql` §5 嵌套处理 |
| 12 | `-SimpleState` 和 `-State` 有什么区别？什么时候用哪个？ | `03_aggregate_combinators.sql` §7 SimpleState |
| 13 | `-OrDefault` 和 `COALESCE` 哪个好？ | `03_aggregate_combinators.sql` §9 OrDefault |
| 14 | 分区聚合（`sum(x) OVER (PARTITION BY k)`）和 GROUP BY 有什么区别？ | `02_window_functions_examples.sql` §1 原理图 |

---

## 2. 函数体系全景图

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                          ClickHouse 函数分类                                   │
├──────────────────────────────────────────────────────────────────────────────┤
│                                                                               │
│  ① 标量函数（Scalar）：一行进一行出，可在任何表达式位置使用                       │
│     ├─ 字符串：length / substring / splitByChar / replaceRegexpAll             │
│     ├─ 日期：toDate / toDateTime / dateDiff / toStartOfDay                    │
│     ├─ 数学：round / floor / pow / sqrt / sin / log                           │
│     ├─ 条件：if / multiIf / nullIf / ifNull / coalesce                         │
│     ├─ 类型转换：CAST / toInt32 / toFloat64 / toDecimal128                    │
│     ├─ 哈希：sipHash64 / xxHash64 / cityHash64 / intHash32                    │
│     ├─ IP：toIPv4 / toIPv6 / IPv4CIDRToRange                                  │
│     ├─ 数组：arrayJoin / arrayMap / arrayFilter / arraySum                    │
│     ├─ JSON：JSONExtractString / JSONExtractUInt / JSONHas                    │
│     └─ Map：mapApply / mapPopulateSeries / mapKeys / mapValues                │
│                                                                               │
│  ② 聚合函数（Aggregate）：多行进一行出，配合 GROUP BY 使用                        │
│     ├─ 基础：count / sum / avg / min / max / any / anyLast                    │
│     ├─ 统计：varPop / varSamp / stddevPop / quantile / topK                   │
│     └─ 组合子（Combinator）：*If / *Array / *State / *Merge / *ForEach / ...   │
│                                                                               │
│  ③ 窗口函数（Window）：多行进一行出，但不折叠行数                                 │
│     ├─ 排名：row_number / rank / dense_rank / ntile                           │
│     ├─ 导航：lag / lead / first_value / last_value / nth_value                │
│     └─ 聚合窗口：sum/avg/count OVER (...)                                       │
│                                                                               │
│  ④ 表函数（Table Function）：返回一个表，用在 FROM 子句                          │
│     ├─ numbers(N) / generateRandom                                            │
│     ├─ file() / url() / remote()                                              │
│     └─ cluster('name', db, table)                                             │
│                                                                               │
│  ⑤ 用户定义函数（UDF）：自定义表达式逻辑                                        │
│     ├─ SQL UDF：CREATE FUNCTION ... AS (params) -> expr（持久化）              │
│     └─ Lambda UDF：x -> expr（内联匿名函数，不持久化）                           │
│                                                                               │
└──────────────────────────────────────────────────────────────────────────────┘
```

**最易混淆的三组**（本章重点对比）：
1. `sum` vs `sumState`+`sumMerge` → 01 SQL §11
2. `arrayJoin` vs `arrayMap` → 01 SQL §6
3. `ROWS` vs `RANGE` frame → 02 SQL §5

---

## 3. 聚合组合子（Aggregate Combinators）原理详解

> 聚合组合子是 ClickHouse 独有的"函数修饰器"机制。它们不是独立函数，而是附加在聚合函数后的后缀修饰符，改变聚合函数的行为。详见 `03_aggregate_combinators.sql`。

### 3.1 什么是组合子？

**组合子（Combinator）** = 一个函数接受另一个函数并返回新函数。在 ClickHouse 中，聚合组合子作用于聚合函数，返回行为不同的聚合函数。

```
sumIf(x, cond) = sum(x) 的"条件版"
└─ 不是 sum + If，而是组合子 -If 修饰 sum
```

### 3.2 组合子全景表

| 组合子 | 作用 | 常用搭配 | 对应 SQL 章节 |
|--------|------|----------|--------------|
| `-If` | 条件过滤 | `sumIf`, `countIf`, `avgIf`, `uniqIf` | §2 |
| `-Array` | 数组元素聚合 | `sumArray`, `uniqArray` | §3 |
| `-State` | 存中间状态（二进制） | `sumState`, `countState`, `uniqState` | §4 |
| `-Merge` | 合并状态出结果 | `sumMerge`, `countMerge`, `uniqMerge` | §4 |
| `-MergeState` | 合并后仍保持状态 | `sumMergeState`, `uniqMergeState` | §4 |
| `-ForEach` | 逐位置聚合 | `sumForEach`, `avgForEach` | §5 |
| `-Resample` | 时间窗口重采样 | `sumResample`, `countResample` | §6 |
| `-SimpleState` | 简化版状态（普通值） | `sumSimpleState`, `maxSimpleState` | §7 |
| `-Distinct` | 去重后聚合 | `countDistinct`, `sumDistinct` | §8 |
| `-OrDefault` | 空值返回默认值 | `sumOrDefault`, `countOrDefault` | §9 |

### 3.3 链式规则

组合子可以链式叠加，执行顺序从右到左：

```
sumIfState(x, cond)  = 先 -If 条件过滤 → 再 -State 存状态
uniqIfMerge(s)       = 先 -If 条件过滤 → 再 -Merge 合并状态
countDistinctIf(x, cond) = 先 -If → 再 -Distinct
```

常见链式组合：

| 链式组合 | 效果 |
|----------|------|
| `sumIf(x, cond)` | 条件求和 |
| `sumIfState(x, cond)` | 条件求和的状态 |
| `sumIfMerge(s)` | 合并条件求和状态 |
| `uniqIf(x, cond)` | 条件去重计数 |
| `countDistinctIf(x, cond)` | 条件去重计数（等价 `uniqIf`） |

### 3.4 性能对比

| 方案 | 扫描方式 | 推荐度 |
|------|----------|--------|
| `sumIf(x, cond)` | 聚合内过滤 | ⭐⭐⭐ 推荐 |
| `sum(if(cond, x, 0))` | 每行 if 计算 | ⭐⭐ 兜底 |
| `WHERE cond` + 两次查询 | 两次全表扫描 | ⭐ 不推荐 |

组合子聚合（如 `sumIf`）比"普通聚合 + if 嵌套"更高效，因为组合子是聚合函数内置的过滤逻辑，在聚合循环内部判断，避免了 if 函数的条件判断开销。

---

## 4. UDF 使用场景和局限

> 详见 `04_udf.sql`。ClickHouse 支持两种 UDF：SQL UDF（`CREATE FUNCTION`）和 Lambda UDF（内联匿名函数）。

### 4.1 两种 UDF 对比

| 特性 | SQL UDF | Lambda UDF |
|------|---------|------------|
| 语法 | `CREATE FUNCTION f AS (p) -> expr` | `p -> expr` |
| 持久化 | ✅ 存元数据，跨会话可用 | ❌ 仅当前查询 |
| 作用域 | 当前数据库 | 当前表达式 |
| 适用场景 | 业务逻辑封装 | 数组回调（arrayMap/arrayFilter） |

### 4.2 推荐使用场景

- ✅ 业务逻辑封装：价格计算、税率、折扣、脱敏
- ✅ 数据清洗函数：格式转换、标准化
- ✅ 复杂条件表达式封装（`multiIf` 多分支）
- ✅ Lambda 用于数组函数回调

### 4.3 不推荐使用场景

- ❌ 高频过滤条件（`WHERE my_udf(col) > 10`）—— 影响索引选择
- ❌ 大数据量聚合中的 UDF —— 无法向量化
- ❌ 嵌套多层 UDF —— 增加表达式树深度
- ❌ 替代聚合函数 —— UDF 不能做聚合

### 4.4 UDF 局限清单

| 局限项 | 说明 | 替代方案 |
|--------|------|----------|
| 不能做聚合 | 不能包含聚合函数 | 视图 / 子查询 |
| 不能优化 | 不公共子表达式消除 | 手写展开 |
| 性能差 | 无向量化加速 | 内置函数优先 |
| 不支持重载 | 同名 UDF 覆盖 | 不同名称 |
| 不能访问表 | 不能执行 SELECT | 视图 / 物化视图 |
| Lambda 不持久化 | 查询结束消失 | 转为 SQL UDF |
| 无类型声明 | 参数类型推断 | 调用时 CAST |
| 不支持递归 | 不能自引用 | 用循环/列表 |
| 不支持窗口函数 | 不能包含 OVER 子句 | 窗口函数直接写 |
| 不支持多语句 | 只能一个表达式 | 嵌套表达式 |

---

## 5. JSON 处理方案对比决策树

> 详见 `05_json_functions.sql`。ClickHouse 提供三种 JSON 处理方案，选型取决于业务场景。

### 5.1 方案对比表

| 特性 | `JSONExtract*` (String) | `visitParam*` (已废弃) | `JSON` 类型 (实验性) |
|------|------------------------|----------------------|---------------------|
| 原理 | 每次查询解析（RapidJSON） | 轻量扁平解析 | 写入时解析，子列存储 |
| 支持嵌套路径 | ✅ | ❌ | ✅ |
| 支持 JSONPath | ✅ | ❌ | ✅ |
| 支持数组 | ✅ | ❌ | ✅ |
| 查询速度 | 慢 | 中 | 快（零解析） |
| 写入速度 | 快 | 快 | 中（解析开销） |
| 存储空间 | 小（String） | 小（String） | 中（二进制） |
| 支持索引 | ❌ | ❌ | ✅（子列索引） |
| 需要 SET | ❌ | ❌ | ✅ `allow_experimental_json_type` |
| 状态 | 稳定 | 已废弃（22.x+） | 实验性 |

### 5.2 决策树

```
你的 JSON 数据存在哪？
│
├─ 已有 String 列（存量数据）
│  ├─ 低频查询 → JSONExtract*（不改表，最省事）
│  └─ 高频查询 → 物化列提取高频字段 + JSONExtract* 兜底
│
├─ 新建表（增量数据）
│  ├─ JSON 字段查询频繁 → JSON 类型（SET 启用）或抽成普通列
│  └─ JSON 字段偶尔查 → String + JSONExtract*（写入快）
│
└─ 遗留代码用 visitParam*
   └─ 逐步迁移到 JSONExtract*（见 §6.4 迁移对照表）
```

### 5.3 visitParam → JSONExtract 迁移对照表

| 废弃函数 | 替代函数 |
|----------|----------|
| `visitParamExtractString(s, k)` | `JSONExtractString(s, k)` |
| `visitParamExtractUInt(s, k)` | `JSONExtractUInt(s, k)` |
| `visitParamExtractInt(s, k)` | `JSONExtractInt(s, k)` |
| `visitParamExtractFloat(s, k)` | `JSONExtractFloat(s, k)` |
| `visitParamExtractBool(s, k)` | `JSONExtractBool(s, k)` |
| `visitParamExtractRaw(s, k)` | `JSONExtractRaw(s, k)` |
| `visitParamHas(s, k)` | `JSONHas(s, k)` |
| `visitParamKeys(s)` | `JSONKeys(s)` |
| `visitParamNum(s)` | `JSONLength(s)` |

---

## 6. 常见误区与最佳实践

### 误区

1. **在 `AggregatingMergeTree` 表上直接 `SELECT sum_state_col` 期望看到数值** → 看到二进制，必须 `sumMerge(col)`

2. **`last_value(price) OVER (ORDER BY d)` 期望得到分区最后一个值** → 默认 frame 到当前行，得到的是"当前行值"，需 `ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING`

3. **`sum(x) OVER (ORDER BY d)` 做累计求和，d 有重复值时结果跳变** → 默认 `RANGE` frame，同值同帧；改用 `ROWS`

4. **`count(DISTINCT col)` 对亿级数据** → 极慢，改用 `uniq(col)`（误差 <1%）

5. **用 `//` 注释** → ClickHouse 只支持 `--` 注释，`//` 会语法错误

6. **`arrayJoin` 和 `arrayMap` 混用** → `arrayJoin` 改变行数，`arrayMap` 不变

7. **`sumIf` 和 `sum(if(...))` 等价，随便选** → 大数据量下 `sumIf` 快 1.5~3x（见 03 SQL §11）

8. **UDF 可以替代内置函数** → UDF 是宏展开，不能向量化，性能差 2~5x

9. **`visitParam` 还能用，懒得改** → visitParam 已废弃，不支持嵌套和数组，应迁移到 JSONExtract

10. **聚合组合子太多记不住，全用 `WHERE` + 普通聚合** → 组合子一次扫描完成条件聚合，WHERE 需要多次扫描

### 最佳实践

1. **实时预聚合三件套**：明细表（MergeTree）+ 物化视图（`AggregatingMergeTree` + `*State`）+ 查询（`*Merge`）

2. **分位数监控用 `quantileState`**：避免每次重算 P99

3. **UV 用 `uniqState`**：跨分片合并无损

4. **窗口函数加 `PARTITION BY`**：避免全表单分区导致性能灾难

5. **移动平均显式写 frame**：`ROWS BETWEEN N PRECEDING AND CURRENT ROW`

6. **`multiIf` 替代嵌套 `CASE WHEN`**：可读性更好

7. **组合子优先于嵌套 if**：`sumIf(x, cond)` 优于 `sum(if(cond, x, 0))`

8. **JSON 高频字段物化**：从 JSON 字符串中提取高频字段为普通列 + 索引

9. **UDF 命名规范**：前缀 + 描述性名称（`calc_*`, `fmt_*`, `mask_*`）

10. **定期审查 UDF**：用 `system.functions` 检查未使用的 UDF

---

## 7. 文件导航

| 文件 | 内容 | 关键章节 |
|------|------|----------|
| [01_basic_functions_examples.sql](./01_basic_functions_examples.sql) | 标量/聚合/状态函数 + 数组 + JSON + Map | §1 聚合基础、§6 **arrayJoin 展开原理**、§11 **聚合状态函数（sumState/sumMerge + AggregatingMergeTree）** |
| [02_window_functions_examples.sql](./02_window_functions_examples.sql) | 排名/导航/聚合窗口 + 帧 | §2 排名函数、§3 累计求和、§5 **窗口帧 ROWS vs RANGE**、§6 实战场景 |
| [03_aggregate_combinators.sql](./03_aggregate_combinators.sql) | **聚合组合子全集** | §2 **-If 条件聚合**、§4 **-State/-Merge 状态链**、§7 **-SimpleState**、§10 **链式组合子**、§11 **性能对比** |
| [04_udf.sql](./04_udf.sql) | **用户定义函数** | §2 **SQL UDF 创建和使用**、§3 **Lambda UDF**、§4 **UDF 局限**、§6 **生产建议** |
| [05_json_functions.sql](./05_json_functions.sql) | **JSON 函数深度** | §2 **JSONExtract 系列**、§3 **JSONPath 语法**、§5 **嵌套数组解析**、§6 **visitParam 废弃**、§7 **JSON 类型**、§9 **性能对比** |

---

## 8. 自测题（理解检查点）

完成本章后，应能回答：

### 聚合组合子
1. 什么是聚合组合子？`sumIf(x, cond)` 和 `sum(if(cond, x, 0))` 有什么区别？
2. `-State` 和 `-SimpleState` 有什么区别？分别用于什么场景？
3. `-ForEach` 和 `-Array` 在处理数组时有什么不同？
4. 链式组合子 `sumIfState(x, cond)` 的执行顺序是什么？
5. `-OrDefault` 和 `COALESCE(agg(x), 0)` 的优劣？

### UDF
6. ClickHouse 的 UDF 为什么不能做聚合？
7. SQL UDF 和 Lambda UDF 的主要区别是什么？
8. 在什么情况下不应该使用 UDF？
9. UDF 是如何影响查询性能的？

### JSON
10. `JSONExtract*` 和 `JSON` 类型在查询速度上为什么有差异？
11. `visitParam*` 系列函数为什么被废弃？应该如何迁移？
12. 如何解析 JSON 嵌套数组（三层以上）？
13. 对于高频查询的 JSON 字段，应该怎么优化？

### 综合
14. `sumState` 的返回类型是什么？为什么不能直接 SELECT 看到数值？
15. `AggregatingMergeTree` 在什么时机把状态 merge？是查询时还是写入时？
16. 如何用 `*State`/`*Merge` 实现"日表 → 月表"的二级聚合且不丢精度？
17. `sum(x) OVER (ORDER BY d)` 和 `sum(x) OVER (ORDER BY d ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)` 在 `d` 有重复值时结果有何不同？
18. `arrayJoin(['a','b','c'])` 返回几行？`arrayMap(x->upper(x), ['a','b'])` 返回几行？
19. `uniq` 和 `count(DISTINCT)` 的区别？什么时候选哪个？
20. 聚合组合子全景图中有 10 种组合子，你能列举出 8 种吗？

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
- [聚合组合子（Combinators）](https://clickhouse.com/docs/en/sql-reference/aggregate-functions/combinators)
- [AggregatingMergeTree 引擎](https://clickhouse.com/docs/en/engines/table-engines/mergetree-family/aggregatingmergetree)
- [窗口函数](https://clickhouse.com/docs/en/sql-reference/window-functions)
- [JSON 函数](https://clickhouse.com/docs/en/sql-reference/functions/json-functions)
- [用户定义函数](https://clickhouse.com/docs/en/sql-reference/statements/create/function)
- [SimpleAggregateFunction](https://clickhouse.com/docs/en/engines/table-engines/mergetree-family/aggregatingmergetree#simpleaggregatefunction)