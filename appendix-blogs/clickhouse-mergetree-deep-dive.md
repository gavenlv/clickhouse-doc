# ClickHouse MergeTree 深度解析：列式存储与高性能的秘密

## 前言

ClickHouse 是当前业界最快的 OLAP 数据库之一，其核心秘密在于 **MergeTree 存储引擎**和**列式存储架构**。本文将深入解析：

1. 列式存储 vs 行式存储的本质区别
2. ClickHouse 为什么这么快
3. MergeTree 的工作原理
4. 如何正确使用 MergeTree

---

## 一、列式存储 vs 行式存储

### 1.1 存储模式对比

```
┌─────────────────────────────────────────────────────────────────┐
│                    行式存储 (Row-oriented)                        │
├─────────────────────────────────────────────────────────────────┤
│  ┌─────────────────────────────────────────────────────────┐    │
│  │ Row 1: [id:1, name:Alice, age:25, city:Beijing]        │    │
│  │ Row 2: [id:2, name:Bob,   age:30, city:Shanghai]       │    │
│  │ Row 3: [id:3, name:Carol, age:28, city:Guangzhou]      │    │
│  └─────────────────────────────────────────────────────────┘    │
│                                                                 │
│  特点：每一行数据连续存储                                         │
│  适用场景：OLTP 事务处理、需要整行读写                            │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│                    列式存储 (Column-oriented)                     │
├─────────────────────────────────────────────────────────────────┤
│  ┌─────────────────────────────────────────────────────────┐    │
│  │ id:    [1, 2, 3, ...]                                   │    │
│  │ name:  [Alice, Bob, Carol, ...]                        │    │
│  │ age:   [25, 30, 28, ...]                               │    │
│  │ city:  [Beijing, Shanghai, Guangzhou, ...]            │    │
│  └─────────────────────────────────────────────────────────┘    │
│                                                                 │
│  特点：每一列数据连续存储                                         │
│  适用场景：OLAP 分析、只读取需要的列                              │
└─────────────────────────────────────────────────────────────────┘
```

### 1.2 为什么列式存储更适合分析

**场景：计算所有用户的平均年龄**

```sql
-- 只读取 age 这一列
SELECT avg(age) FROM users;
```

| 存储方式 | 读取量 | I/O 操作 |
|---------|-------|---------|
| 行式存储 | 整行数据 (id+name+age+city) | 读取 4 个字段，但只需要 1 个 |
| 列式存储 | 只有 age 列 | 只读取 1 个字段，I/O 减少 75% |

### 1.3 列式存储的优势

```
┌─────────────────────────────────────────────────────────────────┐
│                    列式存储核心优势                               │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  1️⃣ 列级别压缩效率高                                           │
│     ─────────────────────────                                    │
│     • 同列数据类型相同 (age 都是 Int8/Int32)                    │
│     • 相邻值相似 → 压缩率高                                     │
│     • 典型压缩比：10-30x                                        │
│                                                                 │
│  2️⃣ 只读取需要的列                                              │
│     ────────────────────                                         │
│     • SELECT avg(age) → 只读 age 列                            │
│     • 跳过 id, name, city 列                                   │
│     • I/O 量大幅减少                                           │
│                                                                 │
│  3️⃣ 向量化执行                                                  │
│     ──────────────                                              │
│     • 同列数据连续 → CPU SIMD 指令批量处理                       │
│     • 一次循环处理 thousands rows                               │
│     • 性能提升 10-100x                                          │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## 二、ClickHouse 为什么这么快？

### 2.1 性能快的六大核心因素

```
┌─────────────────────────────────────────────────────────────────┐
│                 ClickHouse 高性能六大支柱                         │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│    ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐     │
│    │ 列式存储 │  │ 向量化   │  │ 稀疏索引 │  │ 后台合并 │     │
│    │          │→ │ 执行引擎 │→ │          │→ │          │     │
│    └──────────┘  └──────────┘  └──────────┘  └──────────┘     │
│         │                        │                        │      │
│         │               ┌──────────┐  ┌──────────┐       │      │
│         └─────────────→│ 数据压缩 │→ │ 查询优化 │←───────┘      │
│                         └──────────┘  └──────────┘               │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 2.2 详细解析

#### ① 列式存储 + 压缩

```sql
-- 查看实际压缩效果
SELECT 
    column,
    formatReadableSize(sum(compressed_bytes)) AS compressed,
    formatReadableSize(sum(data_uncompressed_bytes)) AS uncompressed,
    round(sum(data_uncompressed_bytes) / sum(compressed_bytes), 1) AS ratio
FROM system.parts_columns
WHERE database = 'your_db' AND table = 'your_table'
GROUP BY column;
```

**典型结果**：
- `UInt32` 类型：压缩比约 10:1
- `String` 低基数：压缩比约 20:1
- `DateTime`：压缩比约 15:1

#### ② 向量化执行引擎

```
传统 Row-by-Row 执行：
┌───┬───┬───┬───┬───┐
│1  │2  │3  │4  │5  │  → 5次循环，5次CPU指令
└───┴───┴───┴───┴───┘

ClickHouse 向量化执行：
┌───────────────────────────────────────┐
│  Column A: [1, 2, 3, 4, 5, ...]       │  → 一次SIMD指令处理
│           + 运算 (批量)                │    thousands rows
└───────────────────────────────────────┘
```

#### ③ 稀疏索引 - 主键快速定位

```sql
CREATE TABLE events (
    user_id UInt32,
    event_date Date,
    event_type String
) ENGINE = MergeTree()
ORDER BY (event_date, user_id);  -- 主键
```

```
数据按主键排序后，每 8192 行创建一个索引标记：

primary.idx (稀疏索引):
┌─────────────────────────────────────────────────────────┐
│ Mark 0: [event_date=2024-01-01, user_id=1]              │
│ Mark 1: [event_date=2024-01-01, user_id=1025]          │
│ Mark 2: [event_date=2024-01-01, user_id=2050]          │
│ ...                                                     │
│ Mark N: [event_date=2024-01-02, user_id=500]           │
└─────────────────────────────────────────────────────────┘

查询 WHERE event_date = '2024-01-01' AND user_id = 1500
  → 二分查找定位到 Mark 1
  → 直接读取对应数据块
  → 跳过 99% 的数据！
```

---

## 三、MergeTree 工作原理

### 3.1 MergeTree 存储结构

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         MergeTree 存储架构                               │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  Table                                                                  │
│  │                                                                      │
│  ├── Partition 202401 (按月分区)                                        │
│  │   │                                                                  │
│  │   ├── Part_202401_1_1_2_0                                           │
│  │   │   ├── primary.idx    (主键稀疏索引)                             │
│  │   │   ├── user_id.mrk2  (列标记文件)                               │
│  │   │   ├── user_id.bin   (列数据-压缩)                              │
│  │   │   ├── event_type.mrk2                                        │
│  │   │   ├── event_type.bin                                          │
│  │   │   └── ...                                                      │
│  │   │                                                                  │
│  │   ├── Part_202401_3_4_5_0  (新插入)                                │
│  │   │   └── ...                                                      │
│  │   │                                                                  │
│  │   └── [后台合并中...]                                               │
│  │       Part_202401_1_1_2_0 + Part_202401_3_4_5_0                    │
│  │       → Part_202401_1_1_5_1  (合并后新 Part)                      │
│  │                                                                       │
│  └── Partition 202402                                                  │
│      └── ...                                                           │
│                                                                         │
│  Part 命名规则: {分区}_{min_block}_{max_block}_{level}                 │
│  例: 202401_1_10_5                                                     │
│      ├── 分区: 202401                                                  │
│      ├── 最小块号: 1                                                   │
│      ├── 最大块号: 10                                                   │
│      └── 合并层级: 5 (0=原始, 越大=合并次数越多)                        │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### 3.2 数据写入流程

```
┌─────────────────────────────────────────────────────────────────┐
│                    MergeTree 数据写入流程                         │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  1. INSERT 语句                                                  │
│     │                                                            │
│     ▼                                                            │
│  2. 写入内存缓冲区                                               │
│     │ (默认 64KB-2MB, 可配置)                                     │
│     ▼                                                            │
│  3. 缓冲区刷盘 (满或超时)                                         │
│     │                                                            │
│     ▼                                                            │
│  4. 创建 Part 文件                                               │
│     ├── primary.idx (主键索引)                                  │
│     ├── *.mrk2 (列标记)                                         │
│     └── *.bin (压缩列数据)                                       │
│     │                                                            │
│     ▼                                                            │
│  5. ZooKeeper 注册 (复制表)                                      │
│     │                                                            │
│     ▼                                                            │
│  6. 完成 ✓                                                       │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 3.3 后台合并机制

```sql
-- 观察：每次 INSERT 产生一个新 Part
INSERT INTO events VALUES (1, '2024-01-01', 'click');
INSERT INTO events VALUES (2, '2024-01-01', 'view');
INSERT INTO events VALUES (3, '2024-01-02', 'purchase');

-- 查看 Parts
SELECT name, rows, level FROM system.parts 
WHERE table = 'events' AND active = 1;
-- 结果：3 个独立的 Part
```

**后台合并触发条件**：
```
✓ 后台任务定期检查 (每 15 秒)
✓ Part 数量超过阈值
✓ Part 大小达到合并条件
✓ TTL 过期触发
```

**合并过程**：
```
Before:  Part_202401_1_2_0  +  Part_202401_3_4_0  +  Part_202401_5_6_0
              ↓                        ↓                    ↓
         Level=0                  Level=0               Level=0

After:   Part_202401_1_6_1
              ↑
         Level=1 (合并后层级提升)
```

---

## 四、MergeTree 变体家族

### 4.1 家族成员一览

```
┌─────────────────────────────────────────────────────────────────┐
│                      MergeTree 家族                             │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  MergeTree (基础)                                                │
│  ├── ReplacingMergeTree - 去重                                   │
│  ├── SummingMergeTree - 求和聚合                                 │
│  ├── AggregatingMergeTree - 预聚合                               │
│  ├── CollapsingMergeTree - 增量更新                              │
│  ├── VersionedCollapsingMergeTree - 版本控制折叠                 │
│  └── GraphiteMergeTree - 时序数据优化                            │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 4.2 实战示例

#### ReplacingMergeTree - 自动去重

```sql
CREATE TABLE sessions (
    session_id String,
    user_id UInt32,
    duration UInt32,
    version UInt8  -- 版本号，用于保留最新记录
) ENGINE = ReplacingMergeTree(version)
ORDER BY (user_id, session_id);

-- 插入多次同一 session
INSERT INTO sessions VALUES ('s1', 100, 30, 1);
INSERT INTO sessions VALUES ('s1', 100, 45, 2);  -- 同 session，更新
INSERT INTO sessions VALUES ('s1', 100, 60, 3);  -- 再次更新

-- 合并后只保留 version=3 的记录
OPTIMIZE TABLE sessions FINAL;

SELECT * FROM sessions;
-- 结果: s1, 100, 60, 3
```

#### SummingMergeTree - 自动求和

```sql
CREATE TABLE metrics (
    date Date,
    region String,
    product String,
    amount UInt64
) ENGINE = SummingMergeTree()
ORDER BY (date, region, product);

-- 相同 key 的 amount 会自动求和
INSERT INTO metrics VALUES 
    ('2024-01-01', 'North', 'A', 100),
    ('2024-01-01', 'North', 'A', 50),   -- 相同 key，合并
    ('2024-01-01', 'South', 'B', 30);

OPTIMIZE TABLE metrics FINAL;

SELECT * FROM metrics;
-- 结果: ('2024-01-01', 'North', 'A', 150), ('2024-01-01', 'South', 'B', 30)
```

---

## 五、最佳实践

### 5.1 表设计黄金法则

```
┌─────────────────────────────────────────────────────────────────┐
│                   MergeTree 表设计法则                           │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ✅ 法则 1: 选择合适的主键顺序                                   │
│     ─────────────────────────────                                │
│     ORDER BY (filter_col1, filter_col2, pk_col)                 │
│     区分度高的列放前面                                           │
│                                                                 │
│  ✅ 法则 2: 合理设计分区                                        │
│     ─────────────────────                                       │
│     PARTITION BY toYYYYMM(date)  -- 按月分区                   │
│     避免分区过多或过少                                          │
│                                                                 │
│  ✅ 法则 3: 选择合适的列类型                                     │
│     ──────────────────────                                       │
│     • 用 UInt32 而非 Int64 (范围够用时)                        │
│     • 用 DateTime 而非 String                                   │
│     • LowCardinality(String) 用于低基数字符串                    │
│                                                                 │
│  ❌ 法则 4: 避免这些错误                                         │
│     ───────────────────                                         │
│     • 主键包含高基数列 (如 UUID) 放前面                         │
│     • 不分区导致 Part 过多                                     │
│     • 使用 String 存储日期                                       │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 5.2 实战示例 - 正确的表设计

```sql
-- 事件表设计
CREATE TABLE app_events (
    event_date Date,
    event_time DateTime,
    user_id UInt32,           -- 低基数，用 UInt32
    event_type LowCardinality(String),  -- 低基数字符串优化
    page_url String,
    duration UInt32,
    revenue Float64
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_date)
ORDER BY (event_date, user_id, event_time)  -- 先过滤列，再唯一列
SETTINGS index_granularity = 8192;
```

### 5.3 查询优化技巧

```sql
-- ✅ 正确做法：只选择需要的列
SELECT event_type, count() 
FROM app_events 
GROUP BY event_type;

-- ❌ 错误做法：SELECT * (读取所有列)
-- SELECT * FROM app_events LIMIT 10;

-- ✅ 使用 PREWHERE 优化 (先过滤再读取)
SELECT user_id, count()
FROM app_events
PREWHERE event_date >= '2024-01-01'
WHERE event_type = 'purchase'
GROUP BY user_id;

-- ✅ 利用分区裁剪
SELECT * FROM app_events
WHERE event_date BETWEEN '2024-01-01' AND '2024-01-31';  -- 只扫描1月分区
```

### 5.4 监控和维护

```sql
-- 查看 Parts 状态
SELECT 
    partition,
    count() AS part_count,
    sum(rows) AS total_rows,
    formatReadableSize(sum(bytes)) AS size
FROM system.parts
WHERE database = 'your_db' AND table = 'your_table' AND active = 1
GROUP BY partition
ORDER BY partition;

-- 查看合并队列
SELECT * FROM system.merges
WHERE database = 'your_db';

-- 查看 MergeTree 设置
SELECT name, value, description
FROM system.merge_tree_settings
WHERE name IN ('max_parts_to_merge_at_once', 'index_granularity');
```

---

## 六、总结

```
┌─────────────────────────────────────────────────────────────────┐
│                      核心要点回顾                                 │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  1️⃣ 列式存储                                                    │
│     • 数据按列存储，每列独立 .bin 文件                            │
│     • 同列同类型，压缩效率高 (10-30x)                            │
│     • 只读需要的列，I/O 大幅减少                                  │
│                                                                 │
│  2️⃣ ClickHouse 高性能来源                                       │
│     • 列式存储 + 高压缩比                                        │
│     • 向量化执行 (SIMD 批量处理)                                 │
│     • 稀疏索引快速定位数据                                       │
│     • 后台合并优化数据布局                                       │
│                                                                 │
│  3️⃣ MergeTree 核心机制                                          │
│     • 数据按 Part 存储，每次 INSERT 创建新 Part                  │
│     • 后台自动合并小 Parts                                       │
│     • 主键稀疏索引，每 8192 行一个标记                           │
│     • 分区支持快速裁剪数据                                       │
│                                                                 │
│  4️⃣ 正确使用 MergeTree                                           │
│     • 合理设计主键顺序                                           │
│     • 选择合适的分区粒度                                         │
│     • 使用合适的 MergeTree 变体                                  │
│     • 利用分区裁剪和 PREWHERE 优化                               │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## 参考资料

- [ClickHouse 官方文档](https://clickhouse.com/docs)
- [MergeTree 引擎详解](https://clickhouse.com/docs/en/engines/table-engines/mergetree-family/mergetree)
- [system.parts 表](https://clickhouse.com/docs/en/operations/system-tables/parts)

---

*本文基于 ClickHouse 文档和实战经验编写*
