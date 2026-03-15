-- =====================================================
-- 02 - ClickHouse 核心架构解析
-- =====================================================
-- 集群: treasurycluster (2副本)
-- 时间: 20-35分钟
-- =====================================================

-- -----------------------------------------------------
-- 1. ClickHouse 整体架构
-- -----------------------------------------------------

-- 
-- ┌─────────────────────────────────────────────────────────────┐
-- │                 ClickHouse 完整架构                          │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                             │
-- │  ┌─────────────────────────────────────────────────────┐   │
-- │  │              Client Layer (客户端层)                  │   │
-- │  │   HTTP    Native TCP    CLI    ODBC/JDBC           │   │
-- │  └─────────────────────┬───────────────────────────────┘   │
-- │                        │                                     │
-- │  ┌─────────────────────▼───────────────────────────────┐   │
-- │  │           Query Pipeline (查询管道)                   │   │
-- │  │                                                     │   │
-- │  │   Parser → Interpreter → Handler → Storage          │   │
-- │  │      │         │           │          │              │   │
-- │  │      ▼         ▼           ▼          ▼              │   │
-- │  │   AST    Optimization   Plan     Data               │   │
-- │  │                                                     │   │
-- │  └─────────────────────┬───────────────────────────────┘   │
-- │                        │                                     │
-- │  ┌─────────────────────▼───────────────────────────────┐   │
-- │  │         Storage Engine Layer (存储引擎层)             │   │
-- │  │                                                     │   │
-- │  │   MergeTree  Distributed  Memory  Buffer            │   │
-- │  │                                                     │   │
-- │  └─────────────────────────────────────────────────────┘   │
-- │                                                             │
-- └─────────────────────────────────────────────────────────────┘

-- -----------------------------------------------------
-- 2. 列式存储 vs 行式存储
-- -----------------------------------------------------

-- 使用 playground 数据库
USE playground;

-- 创建列式存储示例表 (Replicated)
DROP TABLE IF EXISTS col_store ON CLUSTER treasurycluster SYNC;

CREATE TABLE col_store (
    id UInt32,
    name String,
    age UInt8,
    city String
) ENGINE = ReplicatedMergeTree()
ORDER BY id;

INSERT INTO col_store VALUES 
    (1, 'Alice', 25, 'Beijing'),
    (2, 'Bob', 30, 'Shanghai'),
    (3, 'Charlie', 28, 'Beijing');

-- 查看存储文件
-- 
-- 列式存储文件结构:
-- 
-- ┌─────────────────────────────────────────────────────────────┐
-- │              ClickHouse 数据文件结构                         │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                             │
-- │  数据目录: /var/lib/clickhouse/data/database/table/        │
-- │                                                             │
-- │  ├── all_1_1_0/              ← Part 目录                    │
-- │  │   ├── checksums.txt       ← 文件校验和                   │
-- │  │   ├── columns.txt        ← 列信息                       │
-- │  │   ├── count.txt          ← 行数                         │
-- │  │   ├── id.bin              ← id 列数据 (压缩)            │
-- │  │   ├── id.mrk2             ← id 列标记文件               │
-- │  │   ├── name.bin            ← name 列数据                 │
-- │  │   ├── name.mrk2           ← name 列标记                 │
-- │  │   ├── age.bin             ← age 列数据                  │
-- │  │   ├── age.mrk2            ← age 列标记                   │
-- │  │   ├── city.bin            ← city 列数据                 │
-- │  │   └── city.mrk2           ← city 列标记                  │
-- │  │                                                     │
-- │  └── primary.idx              ← 主键索引                   │
-- │                                                             │
-- └─────────────────────────────────────────────────────────────┘

-- 查看列数据文件
-- SELECT 
--     column,
--     formatReadableSize(sum(on_disk_size)) AS compressed_size,
--     formatReadableSize(sum(mark_size_bytes)) AS mark_size
-- FROM system.parts_columns
-- WHERE database = 'playground' AND table = 'col_store' AND active = 1
-- GROUP BY column;

-- -----------------------------------------------------
-- 3. 向量化执行引擎
-- -----------------------------------------------------

-- 
-- ┌─────────────────────────────────────────────────────────────┐
-- │              向量化执行原理                                  │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                             │
-- │  行式执行 (Row-by-Row):                                     │
-- │  ┌───┬───┬───┬───┬───┐                                     │
-- │  │1  │2  │3  │4  │5  │  → 5次循环处理                     │
-- │  └───┴───┴───┴───┴───┘                                     │
-- │   for i in rows:                                           │
-- │       result[i] = func(row[i])                             │
-- │                                                             │
-- │  向量化执行 (Vectorized):                                   │
-- │  ┌─────────────────────────────────────────────────────┐   │
-- │  │  [1, 2, 3, 4, 5]     ← 列数据 (SIMD)               │   │
-- │  └─────────────────────────────────────────────────────┘   │
-- │       │                                                    │
-- │       ▼                                                    │
-- │  result = func([1,2,3,4,5])  ← 一次处理整列                 │
-- │                                                             │
-- │  性能提升: 10-100x                                       │
-- │                                                             │
-- └─────────────────────────────────────────────────────────────┘

-- 创建大表进行向量化性能测试 (Replicated)
DROP TABLE IF EXISTS vector_test ON CLUSTER treasurycluster SYNC;

CREATE TABLE vector_test ON CLUSTER treasurycluster (
    id UInt64,
    value Float64,
    category UInt8
) ENGINE = ReplicatedMergeTree()
ORDER BY id;

-- 插入100万行数据
INSERT INTO vector_test
SELECT 
    number AS id,
    rand() * 1000 AS value,
    number % 10 AS category
FROM numbers(1000000);

-- 查看查询执行计划
EXPLAIN PLAN SELECT count(), avg(value), sum(value) 
FROM vector_test 
WHERE category = 5;

-- 查看管道执行
EXPLAIN PIPELINE SELECT count() FROM vector_test;

-- 执行并查看性能
SELECT 
    count() AS cnt,
    avg(value) AS avg_val,
    sum(value) AS total_val
FROM vector_test
WHERE category = 5;

-- -----------------------------------------------------
-- 4. 稀疏索引机制
-- -----------------------------------------------------

-- 
-- ┌─────────────────────────────────────────────────────────────┐
-- │              ClickHouse 稀疏索引                             │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                             │
-- │  主键索引 (primary.idx):                                    │
-- │  ┌─────────────────────────────────────────────────────┐   │
-- │  │  物理存储: 每 8192 行一个索引条目                    │   │
-- │  │                                                     │   │
-- │  │  示例 (ORDER BY id):                                │   │
-- │  │  ─────────────────────────────────────────────     │   │
-- │  │  索引位置: 0    8192   16384  24576  32768 ...    │   │
-- │  │  索引值:     0    8192   16384  24576  32768 ...    │   │
-- │  │                                                     │   │
-- │  │  查询 id = 10000 时:                               │   │
-- │  │  - 定位到索引区间: [8192, 16384)                  │   │
│  │  │  - 只需扫描这一个数据块                            │   │
-- │  └─────────────────────────────────────────────────────┘   │
-- │                                                             │
-- │  优势: 索引文件小，内存友好                                 │
-- │  限制: 适合范围查询，不适合点查询                           │
-- │                                                             │
-- └─────────────────────────────────────────────────────────────┘

-- 查看索引信息
SELECT 
    name,
    value,
    description
FROM system.merge_tree_settings
WHERE name = 'index_granularity';

-- 创建带复合主键的表 (Replicated)
DROP TABLE IF EXISTS sparse_index_demo ON CLUSTER treasurycluster SYNC;

CREATE TABLE sparse_index_demo ON CLUSTER treasurycluster (
    event_date Date,
    user_id UInt32,
    event_type String,
    payload String
) ENGINE = ReplicatedMergeTree()
PARTITION BY toYYYYMM(event_date)
ORDER BY (event_date, user_id)
SETTINGS index_granularity = 8192;

-- 插入数据
INSERT INTO sparse_index_demo
SELECT 
    toDate('2024-01-01') + (number % 30) AS event_date,
    number % 10000 AS user_id,
    ['click', 'view', 'purchase'][number % 3 + 1] AS event_type,
    repeat('x', 100) AS payload
FROM numbers(100000);

-- 查看 parts 和索引
SELECT 
    partition,
    name AS part_name,
    rows,
    formatReadableSize(bytes) AS size
FROM system.parts
WHERE database = 'playground' AND table = 'sparse_index_demo' AND active = 1;

-- -----------------------------------------------------
-- 5. 查询处理管道
-- -----------------------------------------------------

-- 
-- ┌─────────────────────────────────────────────────────────────┐
-- │              ClickHouse 查询处理流程                         │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                             │
-- │  1. Parser (解析)                                           │
-- │     SQL Text → AST (抽象语法树)                            │
-- │     SELECT * FROM users WHERE age > 20                     │
-- │            ↓                                                │
-- │     SelectQuery                                            │
-- │       ├── from: users                                      │
-- │       ├── where: age > 20                                  │
-- │       └── ...                                              │
-- │                                                             │
-- │  2. Interpreter (解释)                                     │
-- │     AST → QueryPlan (优化查询计划)                         │
-- │     - 谓词下推 (Predicate Pushdown)                        │
-- │     - 列裁剪 (Column Pruning)                              │
-- │     - 表达式优化                                           │
-- │                                                             │
-- │  3. Execution (执行)                                       │
-- │     Pipeline → 并行执行                                     │
-- │     - 读取 → 过滤 → 聚合 → 排序 → 返回                    │
-- │                                                             │
-- └─────────────────────────────────────────────────────────────┘

-- 使用 EXPLAIN 分析查询计划
EXPLAIN PLAN 
SELECT 
    user_id,
    count() AS cnt
FROM sparse_index_demo
WHERE event_date >= '2024-01-01' AND event_date < '2024-01-15'
GROUP BY user_id
ORDER BY cnt DESC
LIMIT 10;

-- 查看详细管道
EXPLAIN PIPELINE 
SELECT count() FROM sparse_index_demo 
WHERE event_type = 'purchase';

-- -----------------------------------------------------
-- 6. 分布式架构
-- -----------------------------------------------------

-- 
-- ┌─────────────────────────────────────────────────────────────┐
-- │              ClickHouse 分布式架构                          │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                             │
-- │  集群结构:                                                   │
-- │                                                             │
-- │         ┌──────────────┐                                   │
-- │         │   Client      │                                   │
-- │         └──────┬───────┘                                   │
-- │                │                                           │
-- │         ┌──────▼───────┐                                   │
-- │         │  Coordinator │ ← 查询协调节点                     │
-- │         │   (任意节点)  │                                   │
-- │         └──────┬───────┘                                   │
-- │                │                                           │
-- │      ┌────────┼────────┐                                   │
-- │      │        │        │                                   │
-- │  ┌───▼───┐ ┌───▼───┐ ┌───▼───┐                             │
-- │  │Shard 1│ │Shard 2│ │Shard 3│ ← 分片 (数据分片)          │
-- │  │ Replica│ │Replica│ │Replica│ ← 副本 (高可用)            │
-- │  └───────┘ └───────┘ └───────┘                             │
-- │                                                             │
-- │  分片策略:                                                   │
-- │  - 哈希分片: sharding_key % N                              │
-- │  - 范围分片: 按时间/区域划分                                │
-- │  - 一致性哈希: 数据均衡分布                                 │
-- │                                                             │
-- └─────────────────────────────────────────────────────────────┘

-- 查看集群配置 (如果有)
SELECT 
    cluster,
    shard_num,
    replica_num,
    host_name,
    is_local
FROM system.clusters
LIMIT 10;

-- -----------------------------------------------------
-- 7. 后台任务与合并
-- -----------------------------------------------------

-- 
-- ┌─────────────────────────────────────────────────────────────┐
-- │              ClickHouse 后台合并机制                         │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                             │
-- │  写入流程:                                                   │
-- │  ┌─────────────────────────────────────────────────────┐   │
-- │  │  INSERT → 生成 Part 文件 → Active                   │   │
-- │  │         │                                            │   │
-- │  │         ▼                                            │   │
-- │  │     Part_1_1_0   ← 初始 part                         │   │
-- │  │     Part_2_1_0   ← 第二个 part                       │   │
-- │  │     Part_3_1_0   ← 第三个 part                       │   │
-- │  └─────────────────────────────────────────────────────┘   │
-- │                          │                                  │
-- │                          ▼                                  │
-- │  ┌─────────────────────────────────────────────────────┐   │
-- │  │              后台合并 (Background Merge)              │   │
-- │  │                                                    │   │
-- │  │   Part_1_1_0 + Part_2_1_0 + Part_3_1_0             │   │
-- │  │              ↓                                       │   │
-- │  │         Part_1_3_1 (合并后)                         │   │
-- │  │                                                    │   │
-- │  └─────────────────────────────────────────────────────┘   │
-- │                                                             │
-- │  合并策略:                                                   │
-- │  - 相同分区内的 parts 合并                                  │
-- │  - 合并顺序: 小 → 中 → 大                                   │
-- │  - TTL 合并: 清理过期数据                                   │
-- │                                                             │
-- └─────────────────────────────────────────────────────────────┘

-- 查看当前的合并任务
SELECT 
    database,
    table,
    elapsed,
    progress,
    num_parts,
    formatReadableSize(total_size_bytes_compressed) AS size
FROM system.merges
LIMIT 5;

-- 查看合并配置
SELECT 
    name,
    value
FROM system.merge_tree_settings
WHERE name IN ('max_parts_to_merge_at_once', 'merge_with_ttl_timeout');

-- 强制触发一次小合并 (演示用)
OPTIMIZE TABLE sparse_index_demo FINAL;

-- -----------------------------------------------------
-- 8. 内存管理
-- -----------------------------------------------------

-- 查看内存使用
SELECT 
    metric,
    formatReadableSize(value) AS size
FROM system.metrics
WHERE metric LIKE '%Memory%'
LIMIT 10;

-- -----------------------------------------------------
-- 9. 本章小结
-- -----------------------------------------------------

-- 
-- ┌─────────────────────────────────────────────────────────────┐
-- │              本章要点                                       │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                             │
-- │  1. 列式存储: 按列存储，I/O 少，压缩率高                    │
-- │  2. 向量化执行: SIMD 指令，10-100x 性能提升                │
-- │  3. 稀疏索引: 8192 行/索引条目，内存友好                   │
-- │  4. 后台合并: 自动合并小文件，优化查询性能                  │
-- │  5. 分布式: 支持水平扩展，分片+副本                         │
-- │                                                             │
-- │  下一步: 03_mergetree.sql - 深入理解 MergeTree              │
-- │                                                             │
-- └─────────────────────────────────────────────────────────────┘

-- 验证学习
SELECT 
    'architecture' AS chapter,
    (SELECT count() FROM system.parts WHERE database = 'playground') AS parts_created;
