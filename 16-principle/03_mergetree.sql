-- =====================================================
-- 03 - MergeTree 引擎原理
-- =====================================================
-- 本文件帮助你深入理解 ClickHouse MergeTree 引擎的工作原理
-- 包括数据存储结构、合并机制、主键索引等
-- =====================================================

-- -----------------------------------------------------
-- 1. MergeTree 核心概念
-- -----------------------------------------------------

-- MergeTree 存储结构图解:
-- 
-- ┌─────────────────────────────────────────────────────────────┐
-- │                   MergeTree 存储结构                         │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                              │
-- │  Table                                                       │
-- │  │                                                           │
-- │  ├── Partition 202401 (按月分区)                            │
-- │  │   │                                                       │
-- │  │   ├── Part_202401_1_1_2_3                               │
-- │  │   │   ├── primary.idx    (主键索引,稀疏)                │
-- │  │   │   ├── id.mrk2       (列标记文件)                   │
-- │  │   │   ├── id.bin        (列数据,压缩)                  │
-- │  │   │   ├── user_id.mrk2                              │
-- │  │   │   ├── user_id.bin                                │
-- │  │   │   ├── event_type.mkr2                           │
-- │  │   │   ├── event_type.bin    (String 类型)            │
-- │  │   │   ├── value.mrk2                                │
-- │  │   │   ├── value.bin                                 │
-- │  │   │   └── ...                                        │
-- │  │   │                                                   │
-- │  │   ├── Part_202401_2_4_5_6    (新插入)                │
-- │  │   │   └── ...                                        │
-- │  │   │                                                   │
-- │  │   └── [后台合并中...]                                  │
-- │  │       Part_202401_1_1_2_3 + Part_202401_2_4_6        │
-- │  │       → Part_202401_1_1_6_7 (合并后新 Part)          │
-- │  │                                                       │
-- │  └── Partition 202402 (下月分区)                           │
-- │      └── ...                                              │
-- │                                                              │
-- │  文件说明:                                                   │
-- │  *.idx  - 主键索引,每 8192 行一条记录(稀疏索引)            │
-- │  *.mrk2 - 列标记,记录索引文件与数据文件的映射关系          │
-- │  *.bin  - 列数据,压缩存储                                 │
-- │                                                              │
-- └─────────────────────────────────────────────────────────────┘

-- 1.1 Part 文件结构详解
--
-- ┌─────────────────────────────────────────────────────────────┐
-- │                   Part 文件结构详解                           │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                              │
-- │  Part 名称格式: {分区}_{min_block}_{max_block}_{level}     │
-- │  例: 202401_1_10_5                                          │
-- │                                                              │
-- │  ┌─────────────────────────────────────────────────────┐   │
-- │  │  202401_1_10_5  解析:                                │   │
-- │  │  ├── 分区: 202401                                  │   │
-- │  │  ├── 最小块号: 1                                   │   │
-- │  │  ├── 最大块号: 10                                  │   │
-- │  │  └── 合并层级: 5 (0=原始,越大合并次数越多)          │   │
-- │  └─────────────────────────────────────────────────────┘   │
-- │                                                              │
-- │  Block 编号含义:                                            │
-- │  每次 INSERT 产生一个新 Block,分配唯一编号                  │
-- │  合并时 min_block=起始块号, max_block=结束块号             │
-- │                                                              │
-- └─────────────────────────────────────────────────────────────┘

-- 1.2 数据写入流程
--
-- ┌─────────────────────────────────────────────────────────────┐
-- │                   MergeTree 数据写入流程                       │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                              │
-- │  ┌─────────────────────────────────────────────────────┐   │
-- │  │  1. Client INSERT                                    │   │
-- │  │     │                                                │   │
-- │  │     ▼                                                │   │
-- │  │  2. 写入内存缓冲区 (Buffer)                          │   │
-- │  │     │  默认 64KB-2MB, 可配置                         │   │
-- │  │     ▼                                                │   │
-- │  │  3. 刷盘 (Buffer 满或超时)                           │   │
-- │  │     │                                                │   │
-- │  │     ▼                                                │   │
-- │  │  4. 创建 Part 文件                                   │   │
-- │  │     │  - primary.idx (索引)                         │   │
-- │  │     │  - *.mrk2 (标记)                              │   │
-- │  │     │  - *.bin (数据)                                │   │
-- │  │     ▼                                                │   │
-- │  │  5. 注册到 ZooKeeper (复制表)                        │   │
-- │  │     │                                                │   │
-- │  │     ▼                                                │   │
-- │  │  6. 完成                                             │   │
-- │  └─────────────────────────────────────────────────────┘   │
-- │                                                              │
-- └─────────────────────────────────────────────────────────────┘

-- 1.3 后台合并流程
--
-- ┌─────────────────────────────────────────────────────────────┐
-- │                   后台合并流程 (Background Merge)             │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                              │
-- │  触发条件:                                                   │
-- │  ┌─────────────────────────────────────────────────────┐   │
-- │  │ ✓ 后台任务定期检查 (每 15 秒)                        │   │
-- │  │ ✓ Part 数量超过阈值 (max_parts_to_merge_at_once)  │   │
-- │  │ ✓ Part 大小达到合并条件                             │   │
-- │  │ ✓ TTL 过期触发合并                                  │   │
-- │  └─────────────────────────────────────────────────────┘   │
-- │                                                              │
-- │  合并过程:                                                   │
-- │  ┌─────────────────────────────────────────────────────┐   │
-- │  │ Step 1: 选择待合并的 Parts                           │   │
-- │  │         (同分区、相邻块号、Level 相近)                │   │
-- │  │         ↓                                            │   │
-- │  │ Step 2: 读取多个 Part 的数据                         │   │
-- │  │         ↓                                            │   │
-- │  │ Step 3: 按主键排序合并                               │   │
-- │  │         ↓                                            │   │
-- │  │ Step 4: 写入新 Part                                  │   │
-- │  │         ↓                                            │   │
-- │  │ Step 5: 原子替换 (旧→新)                            │   │
-- │  │         ↓                                            │   │
-- │  │ Step 6: 清理旧 Parts                                 │   │
-- │  └─────────────────────────────────────────────────────┘   │
-- │                                                              │
-- │  示例:                                                       │
-- │  Before: 202401_1_2_0 + 202401_3_4_0 + 202401_5_6_0        │
-- │  After:  202401_1_6_1  (Level+1)                          │
-- │                                                              │
-- └─────────────────────────────────────────────────────────────┘

CREATE DATABASE IF NOT EXISTS tutorial;

-- 创建基础 MergeTree 表
DROP TABLE IF EXISTS tutorial.mergetree_demo;

CREATE TABLE IF NOT EXISTS tutorial.mergetree_demo (
    id UInt64,
    user_id UInt32,
    event_type String,
    event_date Date,
    value Float64,
    created_at DateTime DEFAULT now()
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_date)
ORDER BY (event_date, user_id, id)
SETTINGS index_granularity = 8192;

-- 插入数据 - 模拟多次小插入
INSERT INTO tutorial.mergetree_demo (id, user_id, event_type, event_date, value)
SELECT number, number % 1000, 'click', toDate('2024-01-01'), rand() / 100.0
FROM numbers(10000);

INSERT INTO tutorial.mergetree_demo (id, user_id, event_type, event_date, value)
SELECT number + 10000, number % 1000, 'view', toDate('2024-01-02'), rand() / 100.0
FROM numbers(10000);

INSERT INTO tutorial.mergetree_demo (id, user_id, event_type, event_date, value)
SELECT number + 20000, number % 1000, 'purchase', toDate('2024-01-03'), rand() / 100.0
FROM numbers(10000);

-- -----------------------------------------------------
-- 2. 查看 Parts 结构
-- -----------------------------------------------------

-- 查看分区和 Parts
SELECT 
    partition,
    name AS part_name,
    rows,
    formatReadableSize(bytes) AS size,
    level,
    active,
    min_date,
    max_date
FROM system.parts
WHERE database = 'tutorial' AND table = 'mergetree_demo' AND active = 1
ORDER BY partition, name;

-- 观察: 每次 INSERT 创建一个新的 Part
-- 后台会合并这些小 Parts

-- -----------------------------------------------------
-- 3. 强制合并演示
-- -----------------------------------------------------

-- 查看合并任务
SELECT 
    database,
    table,
    elapsed,
    progress,
    num_parts,
    result_part_name
FROM system.merges
WHERE database = 'tutorial' AND table = 'mergetree_demo';

-- 手动触发合并 (OPTIMIZE)
-- 注意: 生产环境慎用
OPTIMIZE TABLE tutorial.mergetree_demo FINAL;

-- 合并后的 Parts
SELECT 
    partition,
    name AS part_name,
    rows,
    formatReadableSize(bytes) AS size,
    level,
    active
FROM system.parts
WHERE database = 'tutorial' AND table = 'mergetree_demo' AND active = 1
ORDER BY partition, name;

-- -----------------------------------------------------
-- 4. 主键索引原理
-- -----------------------------------------------------

-- 主键索引工作原理:
--
-- ┌─────────────────────────────────────────────────────┐
-- │              主键索引工作原理                        │
-- ├─────────────────────────────────────────────────────┤
-- │                                                      │
-- │  数据 (按主键排序):                                  │
-- │  ┌─────────────────────────────────────────────┐   │
-- │  │ user_id: 1, event_date: 2024-01-01, id:1  │   │
-- │  │ user_id: 1, event_date: 2024-01-01, id:5  │   │
-- │  │ user_id: 2, event_date: 2024-01-01, id:2  │   │
-- │  │ user_id: 3, event_date: 2024-01-01, id:3  │   │
-- │  │ ...                                         │   │
-- │  └─────────────────────────────────────────────┘   │
-- │                                                      │
-- │  索引文件 (primary.idx):                            │
-- │  ┌─────────────────────────────────────────────┐   │
-- │  │ Mark 0: [user_id=1, event_date=2024-01-01]│   │
-- │  │ Mark 1: [user_id=15, event_date=2024-01-01]│  │
-- │  │ Mark 2: [user_id=28, event_date=2024-01-02]│  │
-- │  │ ...                                         │   │
-- │  └─────────────────────────────────────────────┘   │
-- │                                                      │
-- │  查询 WHERE user_id = 100 AND event_date = '2024-01-03'│
-- │  1. 二分查找定位 Mark                               │
-- │ 2. 读取对应数据块                                  │
-- │                                                      │
-- └─────────────────────────────────────────────────────┘

-- 查看主键索引文件大小
SELECT 
    name AS part_name,
    formatReadableSize(marks_size) AS marks_size,
    formatReadableSize(primary_key_bytes_in_memory) AS pk_size
FROM system.parts
WHERE database = 'tutorial' AND table = 'mergetree_demo' AND active = 1;

-- 验证稀疏索引: 查询特定范围
SELECT 
    user_id,
    event_date,
    count() AS cnt
FROM tutorial.mergetree_demo
WHERE user_id = 100 AND event_date >= '2024-01-01'
GROUP BY user_id, event_date;

-- -----------------------------------------------------
-- 5. 分区机制
-- -----------------------------------------------------

-- 分区工作原理:
--
-- ┌─────────────────────────────────────────────────────┐
-- │              分区裁剪原理                            │
-- ├─────────────────────────────────────────────────────┤
-- │                                                      │
-- │  查询: WHERE event_date = '2024-01-15'              │
-- │                                                      │
-- │  分区结构:                                          │
-- │  ┌─────────────────────────────────────────────┐   │
-- │  │ Partition 202401                            │   │
-- │  │   ├── Part_202401_1_1_2                    │   │
-- │  │   ├── Part_202401_2_3_4                    │   │
-- │  │                                             │   │
-- │  │ Partition 202402                            │   │
-- │  │   └── ...                                  │   │
-- │  └─────────────────────────────────────────────┘   │
-- │                                                      │
-- │  分区裁剪: 只读取 202401 分区                       │
-- │  跳过 202402, 202403 等分区                        │
-- │                                                      │
-- └─────────────────────────────────────────────────────┘

-- 创建按日期分区的表
DROP TABLE IF EXISTS tutorial.partition_demo;

CREATE TABLE IF NOT EXISTS tutorial.partition_demo (
    id UInt64,
    event_date Date,
    event_type String,
    value Float64
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_date)
ORDER BY (event_date, id);

-- 插入不同月份的数据
INSERT INTO tutorial.partition_demo VALUES (1, '2024-01-15', 'click', 10.0);
INSERT INTO tutorial.partition_demo VALUES (2, '2024-02-15', 'view', 20.0);
INSERT INTO tutorial.partition_demo VALUES (3, '2024-03-15', 'purchase', 30.0);
INSERT INTO tutorial.partition_demo VALUES (4, '2024-04-15', 'click', 40.0);
INSERT INTO tutorial.partition_demo VALUES (5, '2024-05-15', 'view', 50.0);

-- 查看分区
SELECT 
    partition,
    name AS part_name,
    rows,
    min_date,
    max_date,
    active
FROM system.parts
WHERE database = 'tutorial' AND table = 'partition_demo' AND active = 1
ORDER BY partition;

-- 分区裁剪测试 - 只查询 2024-02
SELECT * FROM tutorial.partition_demo
WHERE event_date >= '2024-02-01' AND event_date < '2024-03-01';

-- 查看扫描的分区
SELECT 
    partition,
    rows
FROM system.parts
WHERE database = 'tutorial' AND table = 'partition_demo' AND active = 1
  AND max_date >= '2024-02-01' AND min_date < '2024-03-01';

-- -----------------------------------------------------
-- 6. 多种 MergeTree 变体
-- -----------------------------------------------------

-- ReplacingMergeTree - 自动去重
DROP TABLE IF EXISTS tutorial.replacing_demo;

CREATE TABLE IF NOT EXISTS tutorial.replacing_demo (
    id UInt64,
    user_id UInt32,
    value Float64,
    version UInt8,
    updated_at DateTime DEFAULT now()
) ENGINE = ReplacingMergeTree(version)
ORDER BY id;

INSERT INTO tutorial.replacing_demo VALUES (1, 100, 10.0, 1, now());
INSERT INTO tutorial.replacing_demo VALUES (1, 100, 20.0, 2, now());
INSERT INTO tutorial.replacing_demo VALUES (1, 100, 30.0, 3, now());

-- 查看去重前
SELECT * FROM tutorial.replacing_demo ORDER BY id;

-- 强制合并
OPTIMIZE TABLE tutorial.replacing_demo FINAL;

-- 查看去重后
SELECT * FROM tutorial.replacing_demo ORDER BY id;

-- SummingMergeTree - 自动求和聚合
DROP TABLE IF EXISTS tutorial.summing_demo;

CREATE TABLE IF NOT EXISTS tutorial.summing_demo (
    event_date Date,
    category String,
    product_id UInt32,
    quantity UInt32,
    amount Float64
) ENGINE = SummingMergeTree()
PARTITION BY toYYYYMM(event_date)
ORDER BY (event_date, category, product_id);

INSERT INTO tutorial.summing_demo VALUES 
    ('2024-01-01', 'electronics', 1, 10, 1000.0),
    ('2024-01-01', 'electronics', 1, 5, 500.0),  -- 相同 key，会合并
    ('2024-01-01', 'books', 2, 3, 60.0);

-- 查看聚合前
SELECT * FROM tutorial.summing_demo;

-- 强制合并
OPTIMIZE TABLE tutorial.summing_demo FINAL;

-- 查看聚合后
SELECT * FROM tutorial.summing_demo;

-- AggregatingMergeTree - 预聚合
DROP TABLE IF EXISTS tutorial.aggregating_demo;

CREATE TABLE IF NOT EXISTS tutorial.aggregating_demo (
    event_date Date,
    user_id UInt32,
    event_type String,
    pv UInt64,
    uv AggregateFunction(uniq, UInt32)
) ENGINE = AggregatingMergeTree()
PARTITION BY toYYYYMM(event_date)
ORDER BY (event_date, user_id, event_type);

-- 插入数据需要使用 -State 函数
INSERT INTO tutorial.aggregating_demo VALUES 
    ('2024-01-01', 1, 'click', 10, uniqState(100)),
    ('2024-01-01', 1, 'click', 5, uniqState(100)),
    ('2024-01-01', 2, 'view', 8, uniqState(200));

-- 查询需要使用 -Merge 函数
SELECT 
    event_date,
    user_id,
    event_type,
    sum(pv) AS total_pv,
    uniqMerge(uv) AS total_uv
FROM tutorial.aggregating_demo
GROUP BY event_date, user_id, event_type;

-- CollapsingMergeTree - 增量更新
DROP TABLE IF EXISTS tutorial.collapsing_demo;

CREATE TABLE IF NOT EXISTS tutorial.collapsing_demo (
    id UInt64,
    user_id UInt32,
    value Float64,
    sign Int8,  -- 1: 新增, -1: 取消
    version UInt8
) ENGINE = CollapsingMergeTree(sign)
ORDER BY id;

-- 插入新记录 (sign = 1)
INSERT INTO tutorial.collapsing_demo VALUES (1, 100, 10.0, 1, 1);
-- 取消旧记录 (sign = -1)
INSERT INTO tutorial.collapsing_demo VALUES (1, 100, 10.0, -1, 1);
-- 插入新记录 (sign = 1)
INSERT INTO tutorial.collapsing_demo VALUES (1, 100, 20.0, 1, 2);

-- 查看折叠前
SELECT * FROM tutorial.collapsing_demo ORDER BY id, version;

-- 强制合并
OPTIMIZE TABLE tutorial.collapsing_demo FINAL;

-- 查看折叠后
SELECT * FROM tutorial.collapsing_demo ORDER BY id;

-- -----------------------------------------------------
-- 7. TTL (Time To Live)
-- -----------------------------------------------------

DROP TABLE IF EXISTS tutorial.ttl_demo;

CREATE TABLE IF NOT EXISTS tutorial.ttl_demo (
    id UInt64,
    event_date DateTime,
    value Float64,
    expired_data String
) ENGINE = MergeTree()
ORDER BY id
TTL event_date + INTERVAL 1 DAY;

-- 插入数据
INSERT INTO tutorial.ttl_demo VALUES 
    (1, now() - INTERVAL 2 DAY, 10.0, 'expired'),
    (2, now() - INTERVAL 12 HOUR, 20.0, 'recent'),
    (3, now(), 30.0, 'new');

-- 查看 TTL
SELECT 
    name AS part_name,
    rows,
    ttl_info
FROM system.parts
WHERE database = 'tutorial' AND table = 'ttl_demo' AND active = 1;

-- 手动触发 TTL 清理
ALTER TABLE tutorial.ttl_demo MATERIALIZE TTL;

-- 查看过期数据是否被删除
SELECT * FROM tutorial.ttl_demo;

-- -----------------------------------------------------
-- 8. 写入和读取流程
-- -----------------------------------------------------

-- 写入流程:
-- 1. 接收 INSERT 请求
-- 2. 创建新的 Part
-- 3. 写入内存缓冲区
-- 4. 刷新到磁盘
-- 5. 注册到 ZooKeeper (如果是复制表)

-- 读取流程:
-- 1. 解析查询条件
-- 2. 确定需要扫描的分区
-- 3. 定位主键索引范围
-- 4. 读取列数据
-- 5. 执行聚合/过滤
-- 6. 返回结果

-- 演示读取流程
EXPLAIN PLAN 
SELECT 
    event_date,
    count() AS cnt
FROM tutorial.mergetree_demo
WHERE user_id = 100 AND event_date >= '2024-01-01'
GROUP BY event_date;

-- -----------------------------------------------------
-- 9. 清理
-- -----------------------------------------------------

DROP TABLE IF EXISTS tutorial.mergetree_demo;
DROP TABLE IF EXISTS tutorial.partition_demo;
DROP TABLE IF EXISTS tutorial.replacing_demo;
DROP TABLE IF EXISTS tutorial.summing_demo;
DROP TABLE IF EXISTS tutorial.aggregating_demo;
DROP TABLE IF EXISTS tutorial.collapsing_demo;
DROP TABLE IF EXISTS tutorial.ttl_demo;

-- =====================================================
-- 本章小结
-- =====================================================
--
-- MergeTree 核心要点:
-- 1. 数据按 Part 存储，每次 INSERT 创建新 Part
-- 2. 后台自动合并小 Parts 成大 Parts
-- 3. 主键是稀疏索引，每 8192 行为一个 Granule
-- 4. 分区用于快速裁剪数据
-- 5. ReplacingMergeTree: 自动去重
-- 6. SummingMergeTree: 自动求和聚合
-- 7. AggregatingMergeTree: 预聚合
-- 8. CollapsingMergeTree: 增量更新
-- 9. TTL: 自动过期数据
--
-- 下一步: 04_compression.md - 数据压缩和编码
-- =====================================================
