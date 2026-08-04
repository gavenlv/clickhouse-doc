# ClickHouse 反模式案例库

反模式（Anti-pattern）是那些"看起来正确、用久了才付出代价"的做法。ClickHouse 不是通用数据库，它的设计哲学是"列式 + 批量 + 合并"——把 OLTP 的思维套进来，就会踩坑。本章收集 15 个 ClickHouse 生产环境最常见反模式，每个都包含：症状、根因、影响、解决方案、正反示例。

> 配合 [08_anti_patterns_examples.sql](./08_anti_patterns_examples.sql) 一起学习效果最佳。

## 反模式速查表

| # | 反模式 | 一句话诊断 | 影响 | 修复成本 |
|---|--------|-----------|------|---------|
| 1 | 单行 INSERT | 每次写 1 行，Part 风暴 | 磁盘碎片、合并压力、查询变慢 | 低 |
| 2 | SELECT * | 读取所有列，网络/IO 浪费 | 慢 5-50x | 低 |
| 3 | 低基数列放 ORDER BY 首位 | 索引失效，全表扫描 | 慢 10-100x | 中 |
| 4 | 分区过细 | 每小时一个分区，Part 上万 | 合并失控、查询退化 | 高 |
| 5 | 用 String 存数值/日期 | 存储膨胀、无法下推计算 | 慢 3-10x + 磁盘浪费 | 中 |
| 6 | FINAL 滥用 | 全表合并式查询 | 慢 100x+ | 低 |
| 7 | 无物化视图预聚合 | 每次查询扫全表聚合 | 慢 10-100x | 中 |
| 8 | Mutation 当 UPDATE 用 | 高频 ALTER DELETE/UPDATE | 副本积压、卡死 | 高 |
| 9 | JOIN 无 GLOBAL | 跨分片重复广播 | 慢 5-20x | 低 |
| 10 | 无 TTL | 数据无限增长 | 磁盘满、查询退化 | 中 |
| 11 | 全量重写分布式表 | 小表也分片 | 查询放大、维护复杂 | 高 |
| 12 | 跳数索引过多 | 每个列都建索引 | 写入变慢、收益为零 | 中 |
| 13 | 复制表当普通表 | 只建副本不配 Keeper | 单点故障 | 低 |
| 14 | 未设并发/内存限制 | 一个查询 OOM 全集群 | 集群雪崩 | 中 |
| 15 | 依赖 FINAL 做唯一性 | 期望即时去重 | 结果错误/性能差 | 低 |

---

## 反模式 1：单行 INSERT（小批量写入）

### 症状
- 表内 Part 数量成千上万，`system.parts` 中 active Part 远超 300
- 后台一直有大量 merge 任务，`system.merges` 排队
- 查询速度随时间推移越来越慢

### 根因
ClickHouse 每次 INSERT 生成一个不可变的 Part，后台合并线程再合并它们。单行写入意味着每个 Part 只有一行，合并永远追不上生成速度。

```
INSERT × 10000 次（每次 1 行）
    ↓
生成 10000 个小 Part
    ↓
合并线程疲于奔命，Part 数量降不下来
    ↓
查询需要扫描数万个文件头，慢
```

### 影响量化
| 指标 | 批量写入（10万行/批） | 单行写入 |
|------|---------------------|---------|
| Part 数量 | 10 | 10000 |
| 查询延迟 | 50ms | 5s+ |
| 磁盘占用 | 1x | 1.5-3x（页/列碎片） |
| CPU（合并） | 低 | 高 |

### 解决方案

```sql
-- ❌ 反模式：逐行写入
INSERT INTO events VALUES (1, 'a');
INSERT INTO events VALUES (2, 'b');
-- 10000 行就是 10000 个 Part

-- ✅ 正确：批量写入
INSERT INTO events VALUES
(1, 'a'), (2, 'b'), ...;  -- 一批 1 万-10 万行

-- ✅ 正确：INSERT SELECT
INSERT INTO events SELECT ... FROM staging WHERE ...;

-- ✅ 正确：异步插入（app 场景）
SET async_insert = 1, wait_for_async_insert = 0;
INSERT INTO events VALUES (1, 'a');  -- 服务器缓冲后批量落盘
```

**关键设置**：`async_insert=1` 时服务器端按 `async_insert_max_data_size`（默认 1MB）缓冲，自动合并成大批次写入。对"业务系统逐条埋点"的场景是救命设置。

---

## 反模式 2：SELECT * 无脑全列

### 症状
- 查询只需要 2 列，却扫描了 50 列
- 列多时（宽表）问题尤其严重

### 根因
列式存储的核心优势就是"只读需要的列"。SELECT * 强制读取所有列，破坏列裁剪。

### 影响量化
宽表 100 列，查询实际用 3 列：
- 列裁剪：只读 3/100 = 3% 数据
- SELECT *：读 100% 数据，慢 ~33x

### 解决方案

```sql
-- ❌ 反模式
SELECT * FROM events WHERE event_date = today();

-- ✅ 正确：只选需要的列
SELECT event_type, count()
FROM events
WHERE event_date = today()
GROUP BY event_type;

-- ✅ 高级：需要大量列时用 column 列表而非 *
```

---

## 反模式 3：ORDER BY 低基数列在前

### 症状
- 主键明明存在，查询却不走索引（`system.query_log` 显示 Read 行数 = 全表行数）
- `SHOW INDEX` 无效，`EXPLAIN` 显示没有使用索引

### 根因
ClickHouse 稀疏索引的查询效率取决于排序键的顺序。**排在前面的列选择性越高，索引裁剪效率越高**。如果低基数列（如 `status`，只有 3 种取值）在最前面，索引树分叉几乎无法缩小范围。

```
-- ❌ 反模式：status 只有 3 种取值，却排第一
ORDER BY (status, event_date, user_id)
→ 过滤 event_date 时索引无法有效裁剪（先过 status 的三个分支）

-- ✅ 正确：高基数/高选择性列在前
ORDER BY (event_date, user_id, status)
→ 过滤 event_date 直接二分定位到对应分区
```

### 选择排序键的黄金法则

```
1. 过滤最频繁的等值条件 → 放最前
2. 范围查询条件（日期） → 靠前但通常不是第一位（除非数据量巨大）
3. 高选择性列 > 低选择性列
4. 排序键 ≠ 主键：ORDER BY 才是真正的索引
5. 不要超过 3-4 个列（索引膨胀）
```

---

## 反模式 4：分区过细

### 症状
- `system.parts` 中 active Part 数量上万
- 磁盘上有几千个分区目录
- OPTIMIZE 永远跑不完

### 根因
分区是"物理隔离"级别，每个分区有独立的 Part 集合。分区粒度过细（如 `toMinute()` 或 `toHour()`）会让 Part 数量 = 分区数 × 每区 Part 数，爆炸式增长。

### 分区粒度决策表

| 数据量/查询模式 | 推荐分区粒度 | 原因 |
|----------------|-------------|------|
| < 100GB | 不分区或按月 | 分区本身有开销 |
| 100GB-1TB | 按月 | 查询按天，分区按月 |
| 1TB-10TB | 按天 | 天级裁剪 + TTL 清理 |
| 实时监控（秒级） | 不分区 + 按时间排序 | 数据只写不删 |

**铁律**：单个分区内 Part 数 < 1000；全表 active Part 数 < 300（健康）。

---

## 反模式 5：用 String 存数值/日期

### 症状
- 磁盘占用比预期大 3-10 倍
- 数值计算（求和/平均）慢
- 日期过滤失效

### 根因
String 是变长编码，无法利用数值类型的定长压缩和向量化计算。

```sql
-- ❌ 反模式
CREATE TABLE t (
    order_id String,      -- 数值用 String
    amount String,        -- 金额用 String  
    order_date String     -- 日期用 String
);

-- ✅ 正确
CREATE TABLE t (
    order_id UInt64,
    amount Decimal(18, 2),
    order_date Date
);
```

### 类型选择速查

| 数据 | 正确类型 | 备注 |
|------|---------|------|
| 整型 ID | UInt32/UInt64 | 不要 String |
| 金额 | Decimal(18, 2) | 不要 Float（精度问题） |
| 日期 | Date/DateTime | 不要 String |
| 枚举 | Enum8/Enum16 | 不要 String |
| 低基数字符串 | LowCardinality(String) | 基数 < 1 万 |
| 经纬度 | Float32/Float64 | 合理场景 |
| IP | IPv4/IPv6 | 比 String 快且省 |

---

## 反模式 6：FINAL 滥用

### 症状
- 查询带 `FINAL` 后慢 100 倍
- 每个查询都写 `FINAL` 但数据根本没有重复

### 根因
`FINAL` 会让 ClickHouse 在查询时"实时合并所有相关 Part"来去重，这本质上是把后台合并工作搬到查询路径上。

### 解决方案

```sql
-- ❌ 反模式：每个查询都 FINAL
SELECT * FROM orders FINAL WHERE user_id = 42;

-- ✅ 正确 1：用 argMax 替代 FINAL（ReplacingMergeTree）
SELECT
    order_id,
    argMax(status, version) AS status,
    argMax(amount, version) AS amount
FROM orders
WHERE user_id = 42
GROUP BY order_id;

-- ✅ 正确 2：先 OPTIMIZE 合并，再普通查询
OPTIMIZE TABLE orders FINAL;  -- 定期手动合并
SELECT * FROM orders WHERE user_id = 42;

-- ✅ 正确 3：接受"最终一致"，查询时用 GROUP BY 去重
SELECT order_id, max(version) FROM orders GROUP BY order_id;
```

**判断标准**：只有"必须看到最新版本且数据量小"的场景才用 FINAL；大数据量场景用 argMax 或 GROUP BY。

---

## 反模式 7：无物化视图预聚合

### 症状
- 每次 Dashboard 查询都扫全表做 GROUP BY
- 数据量增长后查询时间线性变长
- 同一份聚合被反复计算

### 根因
ClickHouse 查询很快，但不是免费。高频聚合查询（如每分钟刷新的看板）每次都全量计算，是最大的浪费。

### 解决方案

```sql
-- ✅ 物化视图：INSERT 时增量预聚合
CREATE MATERIALIZED VIEW mv_daily_metrics
ENGINE = SummingMergeTree()
PARTITION BY toYYYYMM(day)
ORDER BY (day, event_type)
AS SELECT
    toDate(event_time) AS day,
    event_type,
    count() AS event_count,
    sum(amount) AS total_amount
FROM events
GROUP BY day, event_type;

-- 查询看板：走预聚合表（毫秒级）
SELECT * FROM mv_daily_metrics WHERE day = today();

-- ✅ 备选：Projection（CH 22.6+，透明优化）
ALTER TABLE events
    ADD PROJECTION p_daily
    (SELECT toDate(event_time), event_type, count()
     GROUP BY toDate(event_time), event_type);
ALTER TABLE events MATERIALIZE PROJECTION p_daily;
```

**决策**：物化视图 = 显式、可控；Projection = 透明、无需改查询。查询模式固定用 MV，需要兼容所有查询用 Projection。

---

## 反模式 8：Mutation 当 UPDATE/DELETE 用

### 症状
- `system.mutations` 队列积压几十条
- 副本之间数据不一致，`system.replicas` 显示有延迟
- 一次 DELETE 卡几小时

### 根因
`ALTER ... UPDATE/DELETE`（mutation）不是即时操作，它会重写所有匹配的分区数据，且每个副本都要执行。频繁 mutation 等于频繁全量重写。

### 解决方案

```sql
-- ❌ 反模式：高频条件删除
ALTER TABLE events DELETE WHERE event_type = 'debug';  -- 每次重写全部匹配数据

-- ✅ 正确 1：用分区删除（如果条件对应分区键）
ALTER TABLE events DROP PARTITION '2024-01';

-- ✅ 正确 2：轻量删除（CH 23.x+，仅标记不重写）
ALTER TABLE events DELETE WHERE ... SETTINGS lightweight_deletes = 1;
-- 或 ALTER TABLE ... APPLY DELETED MASK

-- ✅ 正确 3：TTL 自动过期（定期清理，后台合并时删除）
ALTER TABLE events
    MODIFY TTL event_date + INTERVAL 90 DAY DELETE;

-- ✅ 正确 4：设计时就分区隔离（按天分区，删除 = DROP PARTITION）
```

**经验法则**：mutation 是"补救手段"，不是日常操作。每日清理用 TTL，按时间删除用 DROP PARTITION，业务更新用重新建模（重写分区）。

---

## 反模式 9：JOIN 无 GLOBAL

### 症状
- 分布式表 JOIN 慢
- `system.query_log` 中 Join 阶段耗时占比巨大
- 网络传输量异常大

### 根因
普通 JOIN 在分布式执行时，右表会**在每个分片上重复加载**（如果右表是分布式表，则每个分片都拉全量）。GLOBAL JOIN 只加载一次并广播。

### 解决方案

```sql
-- ❌ 反模式：分布式表直接 JOIN
SELECT *
FROM dist_orders o
JOIN dist_users u ON o.user_id = u.user_id;  -- 每个分片重复拉取右表

-- ✅ 正确：GLOBAL JOIN
SELECT *
FROM dist_orders o
GLOBAL JOIN dist_users u ON o.user_id = u.user_id;  -- 右表加载一次，广播

-- ✅ 更优：右表小的话用字典
SELECT o.*, dictGet('users_dict', 'name', o.user_id)
FROM dist_orders o;
```

**何时用 GLOBAL**：右表小（< 100 万行）且被多个分片重复使用。右表大且本身已正确分片 → 用普通 JOIN（键与分片键一致时能本地 JOIN）。

---

## 反模式 10：无 TTL 数据无限增长

### 症状
- 磁盘占用持续上涨
- 冷数据占 80% 但从不被查询
- 备份时间越来越长

### 根因
ClickHouse 默认不清理数据。业务只查最近 30 天，但数据永久保留。

### 解决方案

```sql
-- ✅ 基础 TTL：90 天后删除
ALTER TABLE events
    MODIFY TTL event_date + INTERVAL 90 DAY DELETE;

-- ✅ 分层 TTL：30 天转冷存储，90 天删除（需要多磁盘配置）
ALTER TABLE events
    MODIFY TTL event_date + INTERVAL 30 DAY TO VOLUME 'cold',
    event_date + INTERVAL 90 DAY DELETE;

-- ✅ 列级 TTL：敏感列提前清除
ALTER TABLE events
    MODIFY COLUMN ip_address String TTL event_date + INTERVAL 30 DAY;

-- ✅ 移动分区（按周归档）
ALTER TABLE events MOVE PARTITION '2023-12' TO DISK 'archive';
```

**TTL 注意**：TTL 删除发生在合并时，不是精确时间点；`OPTIMIZE TABLE ... FINAL` 可强制立即触发。

---

## 反模式 11：小表也分片

### 症状
- 几十万行的维度表也建了 Distributed 表
- 查询 JOIN 维度表时跨分片广播
- 运维复杂度高但毫无收益

### 根因
把"分片"当成了"标准配置"。分片的收益只在单表数据量超过单机承载时体现。

### 分片决策树

```
单表数据量 > 单机磁盘/查询能力？
├── 否 → 不分片！一张复制表（ReplicatedMergeTree）就够
└── 是 → 分片
    ├── 键选择：高基数、均匀分布、查询频繁过滤的列
    ├── 副本：≥2（配 Keeper）
    └── 分布式表：只做查询入口
```

**经验法则**：维度表、字典表、配置表永不分片。事实表先估算增长，< 1TB 通常不分片。

---

## 反模式 12：跳数索引过多

### 症状
- 写入变慢（每个索引都要维护）
- 查询没变快（索引从未命中）
- 磁盘额外占用

### 根因
跳数索引不是"建了就快"。它只在**选择性高、查询条件匹配索引类型**时才生效。盲目给每个列建索引反而拖累写入。

### 跳数索引选型矩阵

| 查询条件 | 推荐索引 | 何时不建 |
|---------|---------|---------|
| 等值/范围（数值） | minmax | 列已经是排序键 |
| 高基数等值（ID/URL） | bloom_filter | 选择性 > 90% 用 minmax |
| 前缀/contains | tokenbf_v1 | 短字符串用 set |
| 多值文本搜索 | ngrambf_v1 | 不需要子串匹配时不建 |
| 低基数枚举 | set | 值 < 100 直接用列本身 |

**验证方法**：

```sql
-- 检查索引命中率
EXPLAIN indexes = 1
SELECT * FROM events WHERE user_id = 42;
-- 看 output 中 Rows 减少是否明显

-- 没有收益就 DROP
ALTER TABLE events DROP INDEX idx_user_id;
```

**铁律**：一个表跳数索引 ≤ 3 个，且必须逐个用 EXPLAIN 验证收益。

---

## 反模式 13：建了复制表却没有副本保护

### 症状
- `ReplicatedMergeTree` 表但只有一个节点
- 节点宕机后数据无法恢复（除非备份）
- 误以为"复制表 = 有备份"

### 根因
`ReplicatedMergeTree` 只是"复制"到其他副本，副本数 = 1 时就是普通表。且复制 ≠ 备份：误删除的 DROP TABLE 也会复制到所有副本。

### 解决方案

```
1. 副本数 ≥ 2，且分布在不同物理机/可用区
2. Keeper 集群 ≥ 3 节点（奇数）
3. 定期 BACKUP/RESTORE 到对象存储
4. 误删除演练：DROP 后从备份恢复

✅ 正确的复制表（2 副本）
ENGINE = ReplicatedMergeTree(
    '/clickhouse/tables/{shard}/events',
    '{replica}'
)
```

**经验法则**：复制解决"高可用"，备份解决"误操作"。两者都要。

---

## 反模式 14：无并发/内存限制（查询雪崩）

### 症状
- 一个大的 GROUP BY 把集群内存打爆，进程 OOM 重启
- 一个用户跑 100 个并发慢查询
- 集群频繁不可用

### 根因
ClickHouse 默认允许单查询使用大量内存和无限并发。共享集群必须显式设置边界。

### 解决方案

```sql
-- ✅ 用户级限制（推荐）
CREATE USER analyst
SETTINGS
    max_memory_usage = 10000000000,      -- 10GB
    max_concurrent_queries_for_user = 5,  -- 单用户并发 5
    max_execution_time = 300,             -- 5 分钟超时
    max_rows_to_read = 1000000000;        -- 10 亿行

-- ✅ 角色级限制（推荐，可复用）
CREATE ROLE limited_role
SETTINGS max_memory_usage = 10000000000, max_concurrent_queries_for_user = 5;

-- ✅ 全局兜底（config.xml）
-- <max_memory_usage>100000000000</max_memory_usage>  -- 100GB
-- <max_concurrent_queries>100</max_concurrent_queries>

-- ✅ Workload Group 隔离（推荐生产使用）
CREATE WORKLOAD GROUP etl_group
SETTINGS max_concurrent_queries = 10, max_memory_usage = 50000000000;
```

---

## 反模式 15：依赖 FINAL/唯一性语义

### 症状
- 期望"同一主键只有一行"，实际出现重复
- 用 ReplacingMergeTree 但没理解合并时机
- 报表对不上

### 根因
ReplacingMergeTree/SummingMergeTree 的"去重/聚合"发生在**后台合并时**，不是 INSERT 时。新写入的数据在合并前会短暂重复。

### 解决方案

```sql
-- ❌ 反模式：期望 IMMEDIATE 去重
INSERT INTO orders SELECT ...;  -- 以为马上只保留一份

-- ✅ 正确 1：查询时主动去重（即使未合并）
SELECT order_id, argMax(status, version)
FROM orders GROUP BY order_id;

-- ✅ 正确 2：强制合并后查询
OPTIMIZE TABLE orders FINAL;
SELECT * FROM orders;

-- ✅ 正确 3：接受最终一致（报表场景）
-- 确保合并在报表前完成（调度 OPTIMIZE 或等自然合并）
```

**铁律**：ClickHouse 是"最终一致"数据库。需要"读取即准确"的场景，要么查询时 GROUP BY/argMax，要么写入前就保证唯一。

---

## 反模式诊断流程

遇到性能问题，按此流程定位反模式：

```
查询慢？
├── 1. system.query_log 看 read_rows
│      └── read_rows ≈ 全表 → 反模式 3（索引失效）/ 反模式 2（SELECT *）
├── 2. EXPLAIN 看是否用索引/Projection
├── 3. system.parts 看 Part 数量
│      └── > 300 → 反模式 1（小批量）/ 反模式 4（分区过细）
├── 4. system.merges 看合并排队
├── 5. 看是否含 FINAL/JOIN/GLOBAL → 反模式 6 / 9
└── 6. 看聚合是否可预计算 → 反模式 7

写入慢/卡？
├── 1. 单行写入？ → 反模式 1
├── 2. mutation 队列长？ → 反模式 8
├── 3. 跳数索引多？ → 反模式 12
└── 4. 副本延迟？ → 反模式 13

集群不稳定？
├── 1. 无内存/并发限制 → 反模式 14
├── 2. 磁盘涨满 → 反模式 10
└── 3. 表结构不匹配 → 反模式 5/11
```

---

## 相关文档

- [点击前往反模式演示 SQL](./08_anti_patterns_examples.sql) —— 每个反模式的可执行演示
- [点击前往注意事项清单](./05_dos_and_donts.md) —— Do's and Don'ts 速查
- [点击前往 ETL 职责划分](./06_etl_vs_clickhouse.md) —— 什么该在 ETL 做，什么该在 CH 做
- [点击前往 08-performance（性能优化）](../08-performance/README.md) —— 反模式的正面解法
- [点击前往 06-modeling（数据建模）](../06-modeling/README.md) —— 排序键/分区设计的正面教材
- [点击前往 11-monitoring-ops（监控运维）](../11-monitoring-ops/README.md) —— Part/合并/副本监控
- [ClickHouse 官方最佳实践](https://clickhouse.com/docs/en/best-practices/)
