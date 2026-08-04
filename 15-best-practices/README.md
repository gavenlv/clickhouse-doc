# 最佳实践与反模式

本章是 ClickHouse 生产经验的结晶。前半部分讲"正确做法"（schema 设计、写入优化、查询优化、ETL 职责划分），后半部分是本项目的核心新增——**15 个生产反模式案例库**：每个反模式都有症状、根因、影响量化、正反示例。读完本章，你将具备"一眼看出生产环境哪里有问题"的能力。

## 本章解决什么问题

| 痛点 | 对应文件 | 一句话解答 |
|------|---------|-----------|
| **ClickHouse 应该怎么用？** | [01 总览](./01_overview.sql) | 从 OLTP 思维切换到"列式 + 批量 + 合并"思维 |
| **表结构怎么设计才对？** | [02 Schema 设计](./02_schema_design.sql) | 排序键/分区/TTL/类型选择的正确姿势 |
| **查询怎么写才快？** | [03 查询优化](./03_query_optimization.sql) | 索引利用、列裁剪、物化视图、Projection |
| **哪些事千万别做？** | [07 反模式案例库](./07_anti_patterns.md) | 15 个生产环境最常见反模式 + 诊断流程 |
| **常见错误怎么演示？** | [08 反模式演示 SQL](./08_anti_patterns_examples.sql) | 每个反模式的可执行 ❌/✅ 对照 |
| **能做/不能做速查** | [05 Do's & Don'ts](./05_dos_and_donts.md) | 黄金法则速查表 |
| **ETL 和 CH 的职责边界？** | [06 ETL vs CH](./06_etl_vs_clickhouse.md) | 什么在 ETL 做，什么在 CH 做 |

## ClickHouse 设计哲学

理解最佳实践的前提，是理解 ClickHouse 的设计哲学。它与传统数据库有 4 个根本不同：

```
传统数据库（MySQL/PostgreSQL）        ClickHouse
────────────────────────────────────────────────────────────
1. 行式存储：一行一起读              列式存储：一列一起读
   → 适合点查、频繁更新                 → 适合分析、批量读
   
2. 数据原地更新                      数据不可变（Part 不可修改）
   → UPDATE/DELETE 是常态              → 只能重写分区（mutation）
   
3. 即时一致性                        最终一致性（后台合并）
   → 写完立刻能读到                     → 去重/聚合发生在合并时
   
4. 索引为点查优化                    索引为范围/聚合优化
   → B+Tree                           → 稀疏索引 + 跳数索引
```

**四大设计原则**（贯穿所有最佳实践）：

| 原则 | 含义 | 违反的后果 |
|------|------|-----------|
| **只读需要的列** | 列裁剪是性能基石 | SELECT * 慢 10-50x |
| **批量写入** | 每次 INSERT 一个 Part，批量才高效 | 单行写入 Part 爆炸 |
| **不可变数据** | Part 不可改，用重写/分区/TTL 管理 | 频繁 mutation 卡死 |
| **预聚合优先** | 高频查询走物化视图/Projection | 每次都全表聚合 |

## 核心概念深度：为什么"写入批量化"这么重要

很多人不理解为什么 ClickHouse 对批量写入如此执着。看这个模型：

```
每次 INSERT → 生成一个 Part（不可变数据块）
    ↓
后台合并线程把多个 Part 合并成更大的 Part
    ↓
合并后的 Part 更大、压缩率更高、查询更快
    ↓
但合并需要时间，如果生成速度 > 合并速度
    ↓
Part 数量无限增长 → 查询扫描文件头越来越多 → 越来越慢
```

**量化对比**（10 万行数据）：

```
写入方式             Part 数    查询延迟    磁盘占用
批量（1 次 INSERT）    1-3       50ms        1x
单行（10 万次 INSERT） 10 万     5s+         1.5-3x
```

**判断标准**：`system.parts` 中 active Part 数 > 300 = 写入方式有问题。

## 反模式案例库速查（本章核心）

```
┌─────┬──────────────────────┬──────────────────────────────┐
│  #  │ 反模式                │ 一句话诊断                   │
├─────┼──────────────────────┼──────────────────────────────┤
│  1  │ 单行 INSERT           │ Part 风暴，合并追不上        │
│  2  │ SELECT *              │ 破坏列裁剪，慢 5-50x         │
│  3  │ 低基数 ORDER BY 首位  │ 稀疏索引失效，全表扫描       │
│  4  │ 分区过细              │ Part 上万，合并失控          │
│  5  │ String 存数值/日期    │ 存储膨胀，无法下推计算       │
│  6  │ FINAL 滥用            │ 把合并搬进查询路径          │
│  7  │ 无物化视图预聚合      │ 高频聚合重复全表计算         │
│  8  │ Mutation 当日常操作   │ 副本积压，卡死               │
│  9  │ JOIN 无 GLOBAL        │ 跨分片重复广播右表           │
│ 10  │ 无 TTL                │ 数据无限增长                 │
│ 11  │ 小表也分片            │ 查询放大，运维复杂           │
│ 12  │ 跳数索引过多          │ 写入变慢，收益为零           │
│ 13  │ 复制表无副本保护      │ 单点故障 + 误删无备份        │
│ 14  │ 无并发/内存限制       │ 一个查询 OOM 全集群          │
│ 15  │ 依赖 FINAL 做唯一性   │ 结果错误/性能差              │
└─────┴──────────────────────┴──────────────────────────────┘
```

每个反模式的完整分析（症状/根因/影响量化/解决方案）见 [07 反模式案例库](./07_anti_patterns.md)，可执行演示见 [08 反模式演示 SQL](./08_anti_patterns_examples.sql)。

## 核心概念深度：排序键选择的黄金法则

排序键（ORDER BY）是 ClickHouse 性能的命脉。反模式 3 只是其中一种错误，正确的选择顺序是：

```
优先级从高到低：

1. 等值过滤最频繁的列（选择性越高越好）
2. 范围查询列（日期通常在这里）
3. 用于排序/分组的热点列
4. 不要超过 3-4 个列（索引膨胀）

为什么选择性重要？
  稀疏索引按排序键顺序二分裁剪。
  如果第一列只有 3 种取值（如 status），
  索引只能分成 3 个分支，无法继续缩小范围 → 全表扫描。
```

**反例诊断**：`ORDER BY (status, date, user_id)` 是经典错误。把 `user_id` 提到前面后，同样的查询 read_rows 从 100% 降到 0.01%。

## 核心概念深度：最终一致性（最重要也最容易被误解）

ClickHouse 的"合并引擎"家族（Replacing/Summing/Aggregating）都是**最终一致**的：

```
INSERT（立即可见，但可能重复/未聚合）
    ↓
后台合并（异步，不确定时间）
    ↓
最终状态（去重/聚合完成）
```

**三种应对策略**：

```sql
-- 策略 1：查询时处理（推荐，最灵活）
SELECT order_id, argMax(status, version)
FROM orders GROUP BY order_id;

-- 策略 2：强制合并后查（数据量小/报表前）
OPTIMIZE TABLE orders FINAL;
SELECT * FROM orders;

-- 策略 3：写入前保证唯一（应用层控制）
-- 不需要 CH 去重，写入的就是唯一数据
```

**铁律**：需要"读取即准确"的场景，不要依赖合并时机。

## 文档导航

### 入门（先读）

| 编号 | 专题 | 文件 | 类型 | 学习难度 |
|------|------|------|------|---------|
| 01 | 最佳实践总览 | [01_overview.sql](./01_overview.sql) | SQL 示例 | 入门 |
| 05 | Do's & Don'ts | [05_dos_and_donts.md](./05_dos_and_donts.md) | 速查文档 | 入门 |
| 06 | ETL vs ClickHouse | [06_etl_vs_clickhouse.md](./06_etl_vs_clickhouse.md) | 架构文档 | 入门 |

### 核心（必读）

| 编号 | 专题 | 文件 | 类型 | 学习难度 |
|------|------|------|------|---------|
| 02 | Schema 设计 | [02_schema_design.sql](./02_schema_design.sql) | SQL 示例 | 进阶 |
| 03 | 查询优化 | [03_query_optimization.sql](./03_query_optimization.sql) | SQL 示例 | 进阶 |
| 04 | 常见错误 | [04_common_mistakes.sql](./04_common_mistakes.sql) | SQL 示例 | 进阶 |

### 反模式案例库（本章核心新增）

| 编号 | 专题 | 文件 | 类型 | 学习难度 |
|------|------|------|------|---------|
| 07 | 反模式案例库 | [07_anti_patterns.md](./07_anti_patterns.md) | 专家文档 | 高级 |
| 08 | 反模式演示 SQL | [08_anti_patterns_examples.sql](./08_anti_patterns_examples.sql) | SQL 示例 | 高级 |

## 快速上手：3 步进入专家状态

### 第 1 步：建立正确思维

读 [01_overview.sql](./01_overview.sql) + [06_etl_vs_clickhouse.md](./06_etl_vs_clickhouse.md)，理解"列式 + 批量 + 不可变 + 最终一致"四大哲学。

### 第 2 步：掌握正确做法

读 [02_schema_design.sql](./02_schema_design.sql) + [03_query_optimization.sql](./03_query_optimization.sql)，建立 schema 设计和查询优化的正确姿势。

### 第 3 步：熟悉反模式（关键一步）

读 [07_anti_patterns.md](./07_anti_patterns.md) 的速查表，然后逐个运行 [08_anti_patterns_examples.sql](./08_anti_patterns_examples.sql) 中的 ❌/✅ 对照演示。**能识别反模式，才算真正理解 ClickHouse。**

## 常见误区

| 误区 | 现实 |
|------|------|
| **"ClickHouse 就是快，怎么写都行"** | 写法不同性能差 100 倍。SELECT * 和列裁剪能差 50 倍 |
| **"单行 INSERT 没问题，数据少"** | Part 是累积的。1 万次单行写入 = 1 万个 Part，查询永远慢 |
| **"FINAL 是去重神器"** | FINAL 把合并搬到查询路径，大数据量慢 100 倍。用 argMax/GROUP BY |
| **"mutation 就是 UPDATE"** | mutation 重写整个分区 + 每个副本都执行，是补救不是日常操作 |
| **"建了索引就快"** | 跳数索引只在选择性高时生效。盲建拖累写入 |
| **"复制表 = 有备份"** | 副本解决高可用，备份解决误操作。DROP 会复制到所有副本 |
| **"ReplacingMergeTree 写完就唯一"** | 去重发生在后台合并时，是最终一致，不是即时一致 |
| **"小表也分片更专业"** | 分片只在单表超单机承载时有收益，小表分片是反模式 |

## 生产检查清单

### Schema 设计
- [ ] 排序键高基数/高频过滤列在前（≤ 3-4 列）
- [ ] 分区粒度匹配数据量（<100GB 不分区/按月，1TB+ 按天）
- [ ] 数值/日期/枚举用了正确类型（非 String）
- [ ] 低基数字符串用 LowCardinality
- [ ] 金额用 Decimal（非 Float）
- [ ] 跳数索引 ≤ 3 个，且 EXPLAIN 验证过收益
- [ ] TTL 已配置（热/温/冷分层）

### 写入
- [ ] 批量写入（每批 ≥ 1 万行）或 async_insert
- [ ] 不使用高频 mutation
- [ ] 按时间删除用 DROP PARTITION / TTL
- [ ] active Part 数 < 300

### 查询
- [ ] 不使用 SELECT *
- [ ] 高频聚合走物化视图/Projection
- [ ] 不使用 FINAL（用 argMax/GROUP BY）
- [ ] 分布式 JOIN 用了 GLOBAL（右表小）
- [ ] 维度表用字典替代 JOIN

### 集群
- [ ] 复制表 ≥ 2 副本 + 定期备份
- [ ] 用户/角色设置了内存/并发限制
- [ ] Workload Group 隔离了生产/ETL/Ad-hoc
- [ ] 小表未分片

### 运维
- [ ] Part/合并/副本监控已配置（system.parts/merges/replicas）
- [ ] mutation 队列定期检查
- [ ] 定期性能审计（EXPLAIN 关键查询）

## 学习路径建议

```
第一天：01 + 06（思维转变）→ 02（Schema 设计）
第二天：03（查询优化）→ 04（常见错误）
第三天：07 反模式案例库通读 → 08 演示 SQL 逐个运行（关键一步）
第四天：回顾 05 Do's & Don'ts → 对照自己的生产环境做检查清单
第五天：用 07 的诊断流程排查一个真实慢查询，形成自己的排查方法论
```

## 相关章节

- [点击前往 06-modeling（数据建模）](../06-modeling/README.md) —— 排序键/分区设计的正面教材
- [点击前往 08-performance（性能优化）](../08-performance/README.md) —— 反模式的正面解法（Projections/JOIN 策略）
- [点击前往 11-monitoring-ops（监控运维）](../11-monitoring-ops/README.md) —— Part/合并/副本监控
- [点击前往 09-distributed（分布式架构）](../09-distributed/README.md) —— 分片与副本的正确姿势
- [ClickHouse 官方最佳实践](https://clickhouse.com/docs/en/best-practices/)

---
**注意**：本章 SQL 示例针对 `treasurycluster` 集群（CH 25.12.1.649）优化。反模式演示使用独立数据库 `antipattern_demo`，不影响其他数据。
