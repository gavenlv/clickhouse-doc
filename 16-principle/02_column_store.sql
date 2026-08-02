-- ============================================================
-- 文件: 16-principle/02_column_store.sql
-- 学习目标: 理解列式存储的物理结构、压缩优势、向量化执行
-- 深度标准: 原理 + 场景 + 对比 + 可运行
-- 集群: treasurycluster (CH 25.12.1.649, 2 副本 × 1 分片, 3 Keeper)
-- 前置: 无（自包含测试数据，按顺序执行）
-- ============================================================
--
-- 本文件章节:
--   1.  列式 vs 行式存储对比（物理结构图解）
--   2.  列压缩效果实测（同列同类型 → 高压缩率）
--   3.  LowCardinality 字典编码原理（低基数列省 5-10× 存储）
--   4.  index_granularity 粒度实验（8192 / 4096 / 16384 对比）
--   5.  压缩算法对比（LZ4 / ZSTD / Delta / Gorilla 实测）
--   6.  向量化执行演示（聚合函数 SIMD 加速）
--   7.  数据类型选择对存储的影响（Int8 vs Int64）
--   8.  PREWHERE 优化（先读过滤列省 I/O）
--   9.  清理
--
-- 关联文档: README.md §3.1 六大支柱 / §3.3 稀疏索引 / 04_compression.md
-- ============================================================

CREATE DATABASE IF NOT EXISTS tutorial;
USE tutorial;

-- ============================================================
-- 1. 列式 vs 行式存储对比
-- ============================================================
-- 【原理】
--   行式: 按行存储, 一行的所有列物理相邻 → 读一行快, 读一列慢(要扫描所有行)
--   列式: 按列存储, 一列的所有值物理相邻 → 读一列快(只读该列文件), 读一行慢(要读多个列文件)
-- 【场景】OLAP 通常扫一列做聚合(SUM/AVG/COUNT), 列式完美匹配; OLTP 通常读整行, 行式匹配
-- 【对比】
--   行式(MySQL InnoDB): id|name|age 在同一页 → 读 avg(age) 要扫所有页
--   列式(CH MergeTree): id.bin|name.bin|age.bin 各自独立 → 读 avg(age) 只读 age.bin
-- 【坑】SELECT * 在列式下反而慢, 因为要读所有列文件 + 解压 + 拼装, 比行式开销大

-- 1.1 创建列式存储演示表
DROP TABLE IF EXISTS tutorial.column_store_demo;

CREATE TABLE tutorial.column_store_demo (
    id UInt64,
    user_id UInt32,
    event_type LowCardinality(String),  -- 6 个值, 用 LowCardinality
    event_date Date,
    value Float64,
    description String
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_date)
ORDER BY (event_date, user_id);

-- 【原理】INSERT 走 numbers(1000000) 表函数 + 数组下标, 一次生成 100 万行
-- 【结果解读】插入耗时数秒, 生成约 12 个 Part (按月分区 + 索引开销)
INSERT INTO tutorial.column_store_demo
SELECT
    number AS id,
    number % 10000 AS user_id,
    ['click', 'view', 'purchase', 'login', 'logout', 'signup'][number % 6 + 1] AS event_type,
    toDate('2024-01-01') + (number % 365) AS event_date,
    (rand() % 10000) / 100.0 AS value,
    repeat('description_', 10) AS description
FROM numbers(1000000);

-- 1.2 查看每列的存储占用 —— 列式核心优势
-- 【原理】system.parts_columns 每行=一个列在一个 Part 中的存储信息
-- 【结果解读】
--   - description 列最大(重复字符串, 压缩率高但总量大)
--   - event_type 列压缩率最高(LowCardinality + 6个值)
--   - value 列压缩率最低(随机浮点数, 难压缩)
SELECT
    column,
    formatReadableSize(sum(column_data_compressed_bytes)) AS compressed_size,
    formatReadableSize(sum(column_data_uncompressed_bytes)) AS uncompressed_size,
    round(sum(column_data_uncompressed_bytes) / sum(column_data_compressed_bytes), 2) AS compression_ratio,
    sum(rows) AS rows
FROM system.parts_columns
WHERE database = 'tutorial' AND table = 'column_store_demo' AND active = 1
GROUP BY column
ORDER BY compressed_size DESC;

-- ============================================================
-- 2. LowCardinality 字典编码原理
-- ============================================================
-- 【原理】
--   LowCardinality(String) 内部用"字典编码":
--   - 维护一个值字典 (例: ['click','view','purchase','login','logout','signup'])
--   - 数据列只存索引 (UInt8 = 1 字节, 最多 256 个值; UInt16 = 2 字节, 最多 65536 个值)
--   - 查询时按需解码, 大部分聚合可直接在索引上做
-- 【场景】基数 < 1万 的字符串列: 国家/省份/事件类型/状态码/品类
-- 【对比】
--   普通 String: 每行存完整字符串, "click" 占 5+字节
--   LowCardinality: 每行存索引 1 字节, 字典另存一次
--   → 100万行: String ~5MB, LowCardinality ~1MB+字典(几十字节) = 省 5×
-- 【坑】
--   - 基数 > 65536 会自动退化, 性能反而下降
--   - 频繁更新的维度列不适合(字典膨胀)
--   - 与 ORDER BY 第一列冲突时可能不让用

DROP TABLE IF EXISTS tutorial.compression_comparison;

CREATE TABLE tutorial.compression_comparison (
    id UInt64,
    event_type_string String,           -- 普通 String
    event_type_lowcard LowCardinality(String),  -- 字典编码
    value Float64
) ENGINE = MergeTree()
ORDER BY id;

INSERT INTO tutorial.compression_comparison
SELECT
    number AS id,
    ['click', 'view', 'purchase', 'login', 'logout'][number % 5 + 1] AS event_type_string,
    ['click', 'view', 'purchase', 'login', 'logout'][number % 5 + 1] AS event_type_lowcard,
    rand() / 100.0 AS value
FROM numbers(1000000);

-- 2.1 对比存储大小
-- 【预期】LowCardinality 列压缩后约为普通 String 的 1/3 - 1/5
SELECT
    '普通 String' AS column_type,
    formatReadableSize(sum(column_data_compressed_bytes)) AS compressed,
    formatReadableSize(sum(column_data_uncompressed_bytes)) AS uncompressed,
    round(sum(column_data_uncompressed_bytes) / sum(column_data_compressed_bytes), 2) AS ratio
FROM system.parts_columns
WHERE database = 'tutorial' AND table = 'compression_comparison' AND column = 'event_type_string' AND active = 1
UNION ALL
SELECT
    'LowCardinality' AS column_type,
    formatReadableSize(sum(column_data_compressed_bytes)) AS compressed,
    formatReadableSize(sum(column_data_uncompressed_bytes)) AS uncompressed,
    round(sum(column_data_uncompressed_bytes) / sum(column_data_compressed_bytes), 2) AS ratio
FROM system.parts_columns
WHERE database = 'tutorial' AND table = 'compression_comparison' AND column = 'event_type_lowcard' AND active = 1;

-- ============================================================
-- 3. 列式存储查询优势演示
-- ============================================================
-- 3.1 只查一列 —— 列式优势最大化
-- 【原理】只读 value.bin, 不读其他列文件, I/O 最少
-- 【结果解读】100万行聚合通常 <100ms
SELECT
    count() AS total_rows,
    sum(value) AS total_value,
    avg(value) AS avg_value,
    max(value) AS max_value,
    min(value) AS min_value
FROM tutorial.column_store_demo;

-- 3.2 多列聚合 + 过滤 + 分组 —— 典型 OLAP 查询
SELECT
    event_type,
    count() AS cnt,
    sum(value) AS total
FROM tutorial.column_store_demo
WHERE event_date >= '2024-03-01'
GROUP BY event_type
ORDER BY total DESC;

-- 3.3 查看查询实际读取的字节数
-- 【原理】read_bytes = 从磁盘读取的压缩字节数; 若只查 2 列, 只读那 2 列的 .bin 文件
-- 【结果解读】read_bytes 远小于表总大小, 这就是列式存储省 I/O 的体现
-- 【注意】system.query_log 需在 config.xml 启用 <query_log>(本测试环境已禁用)。
--   此处用 system.query_thread_log 替代(需 SET log_query_threads = 1)。
--   生产环境建议开启 query_log，它含 tables/type 等更丰富字段。
SET log_query_threads = 1;

-- 触发两条查询以便被记录
SELECT count(), sum(value) FROM tutorial.column_store_demo;
SELECT count(), avg(value) FROM tutorial.column_store_demo WHERE event_type = 'click';

SELECT
    query,
    read_rows,
    formatReadableSize(read_bytes) AS read_bytes,
    query_duration_ms
FROM system.query_thread_log
WHERE positionCaseInsensitive(query, 'column_store_demo') > 0
  AND is_initial_query = 1
ORDER BY event_time DESC
LIMIT 5;

-- ============================================================
-- 4. index_granularity 粒度实验
-- ============================================================
-- 【原理】
--   index_granularity = 每个 granule 的行数 (默认 8192)
--   granule 是索引最小单元, 也是向量化读取单元
--   - 太小: 索引膨胀(更多 mark), 内存压力大
--   - 太大: 过滤粒度粗, WHERE 命中率低时多读无用数据
--   - 8192 是经验值: 8192 行 × 列宽 ≈ L2 cache 大小 → 缓存友好
-- 【场景】一般不动; 极端场景(超高频点查)可调小到 4096; 大批量顺序扫描可调大到 32768
-- 【对比】vs B+Tree: B+Tree 每行一个索引项, 1亿行约1GB; 稀疏索引 8192 行一个, 1亿行仅 12K

DROP TABLE IF EXISTS tutorial.granularity_test;

CREATE TABLE tutorial.granularity_test (
    id UInt64,
    value Float64
) ENGINE = MergeTree()
ORDER BY id
SETTINGS index_granularity = 4096;  -- 默认 8192, 这里减半

INSERT INTO tutorial.granularity_test
SELECT number, rand() / 100.0
FROM numbers(100000);

-- 4.1 查看 mark 数量 —— 粒度越小, mark 越多
-- 【结果解读】rows=100000, index_granularity=4096 → marks ≈ 25 (100000/4096)
-- 【注意】system.parts 无 index_granularity 列(它是表级设置, 非每 Part 属性)。
--   marks 列 = 该 Part 的 mark 总数; 反推粒度 = rows / marks
SELECT
    name AS part_name,
    rows,
    marks,                                           -- mark 总数(每个 mark 对应一个 granule)
    round(rows / marks, 1) AS avg_granularity,       -- 反推实际粒度(≈4096)
    formatReadableSize(bytes) AS size
FROM system.parts
WHERE database = 'tutorial' AND table = 'granularity_test' AND active = 1;

-- 4.2 对比默认粒度
SELECT
    name,
    value,
    description
FROM system.merge_tree_settings
WHERE name IN ('index_granularity', 'index_granularity_bytes');

-- ============================================================
-- 5. 压缩算法对比实测
-- ============================================================
-- 【原理】不同列特性用不同 codec:
--   - LZ4 (默认): 通用, 速度快, 压缩比 2-4×
--   - ZSTD: 压缩比更高 3-6×, 速度稍慢, 适合冷数据
--   - Delta: 存差值, 适合递增序列(时间戳/ID), 通常配合 ZSTD: CODEC(Delta, ZSTD)
--   - Gorilla: 时间戳/浮点数专用 (Gorilla paper 编码), 适合时序数据
--   - T64: 64位整数, 按位压缩
-- 【场景】
--   - 热数据(频繁查询)用 LZ4 → CPU 优先
--   - 冷数据(归档)用 ZSTD(15+) → 存储优先
--   - 时序数据用 CODEC(Delta, ZSTD) → 时间戳列
-- 【对比】详见 04_compression.md
-- 【坑】CODEC 修改后需要 ALTER TABLE ... MATERIALIZE COLUMN 才能生效到旧数据

DROP TABLE IF EXISTS tutorial.compression_lz4;
DROP TABLE IF EXISTS tutorial.compression_zstd;
DROP TABLE IF EXISTS tutorial.compression_delta;

CREATE TABLE tutorial.compression_lz4 (
    id UInt64 CODEC(LZ4),
    value Float64 CODEC(LZ4),
    event_date Date CODEC(LZ4),
    data String CODEC(LZ4)
) ENGINE = MergeTree()
ORDER BY id;
-- 【说明】LZ4 是默认 codec, 显式声明仅为演示对比

CREATE TABLE tutorial.compression_zstd (
    id UInt64 CODEC(ZSTD(3)),
    value Float64 CODEC(ZSTD(3)),
    event_date Date CODEC(ZSTD(3)),
    data String CODEC(ZSTD(3))
) ENGINE = MergeTree()
ORDER BY id;
-- 【说明】ZSTD level 1-22, 默认 3, 越高压缩比越高但越慢

CREATE TABLE tutorial.compression_delta (
    id UInt64 CODEC(Delta, ZSTD),
    value Float64 CODEC(Delta, ZSTD),
    event_date Date CODEC(Delta, ZSTD),
    data String CODEC(ZSTD)
) ENGINE = MergeTree()
ORDER BY id;
-- 【说明】Delta 对递增整数/时间戳有效, 后接 ZSTD 二次压缩;
--   String 列 Delta 无意义, 直接用 ZSTD

-- 5.1 插入相同数据, 对比压缩效果
INSERT INTO tutorial.compression_lz4
SELECT number, rand() / 100.0, toDate('2024-01-01') + (number % 30), repeat('data_', 20)
FROM numbers(100000);

INSERT INTO tutorial.compression_zstd SELECT * FROM tutorial.compression_lz4;

INSERT INTO tutorial.compression_delta SELECT * FROM tutorial.compression_lz4;

-- 5.2 查看压缩效果
-- 【结果解读】ZSTD 压缩比最高, LZ4 中等, Delta 对随机数据效果一般
SELECT
    table,
    formatReadableSize(sum(bytes)) AS total_size,
    formatReadableSize(sum(data_uncompressed_bytes)) AS uncompressed_size,
    round(sum(data_uncompressed_bytes) / sum(bytes), 2) AS compression_ratio
FROM system.parts
WHERE database = 'tutorial'
  AND table LIKE 'compression_%'
  AND active = 1
GROUP BY table
ORDER BY total_size;

-- ============================================================
-- 6. 向量化执行演示
-- ============================================================
-- 【原理】
--   向量化: 一次处理一批数据 (8192 行 granule), 用 SIMD 指令并行计算
--   - AVX2: 一次 8 个 Float64 / 16 个 Float32
--   - AVX-512: 一次 16 个 Float64 / 32 个 Float32
--   - 列式存储天然提供连续同类型数据, 完美匹配 SIMD
-- 【场景】聚合(sum/avg/count)、过滤(WHERE)、表达式计算(price*1.1)
-- 【对比】逐行执行: 每行一次 CPU 操作, 流水线气泡多, 缓存命中率低
-- 【坑】不是所有函数都向量化, 复杂 UDF 可能退化到逐行

-- 6.1 聚合函数 —— 全部向量化
-- 【结果解读】100万行聚合通常 <100ms, 靠向量化 + 多线程并行
SELECT
    count() AS total_rows,
    sum(value) AS total_value,
    avg(value) AS avg_value,
    stddevPop(value) AS std_dev,
    quantileExact(0.5)(value) AS median,
    quantileExact(0.95)(value) AS p95
FROM tutorial.column_store_demo;

-- 6.2 表达式计算 —— 向量化
-- 【原理】price * 1.1 会编译成 SIMD vmulpd 指令, 一次算 8 个 Float64
SELECT
    event_type,
    round(sum(value * 1.1), 2) AS total_with_tax,
    round(avg(value * 1.1), 2) AS avg_with_tax
FROM tutorial.column_store_demo
GROUP BY event_type
ORDER BY total_with_tax DESC;

-- ============================================================
-- 7. 数据类型选择对存储的影响
-- ============================================================
-- 【原理】
--   数据类型决定列宽, 列宽决定 I/O 和压缩效果
--   - Int8: 1 字节, 范围 -128~127
--   - Int16: 2 字节
--   - Int32: 4 字节
--   - Int64: 8 字节
--   - Float32: 4 字节 (精度 7 位)
--   - Float64: 8 字节 (精度 15 位)
-- 【场景】能用小类型就用小类型: 年龄用 UInt8, 金额用 Decimal(10,2) 而非 Float64
-- 【对比】Int8 vs Int64: 100万行差 7MB, 算上压缩差 1-2MB
-- 【坑】Float 类型不能精确表示货币, 用 Decimal

DROP TABLE IF EXISTS tutorial.type_selection;

CREATE TABLE tutorial.type_selection (
    id UInt64,
    value_int8 Int8,
    value_int16 Int16,
    value_int32 Int32,
    value_int64 Int64,
    value_float32 Float32,
    value_float64 Float64
) ENGINE = MergeTree()
ORDER BY id;

INSERT INTO tutorial.type_selection
SELECT
    number AS id,
    (rand() % 100) - 50 AS value_int8,
    (rand() % 10000) - 5000 AS value_int16,
    (rand() % 1000000) - 500000 AS value_int32,
    (rand() % 1000000000) - 500000000 AS value_int64,
    (rand() % 10000) / 100.0 AS value_float32,
    (rand() % 1000000) / 100.0 AS value_float64
FROM numbers(1000000);

-- 7.1 对比各类型存储大小
-- 【结果解读】Int8 最小, Int64 最大, Float32 比 Float64 省一半
SELECT
    column,
    formatReadableSize(sum(column_data_compressed_bytes)) AS compressed,
    formatReadableSize(sum(column_data_uncompressed_bytes)) AS uncompressed,
    round(sum(column_data_uncompressed_bytes) / sum(column_data_compressed_bytes), 1) AS ratio
FROM system.parts_columns
WHERE database = 'tutorial' AND table = 'type_selection' AND active = 1
GROUP BY column
ORDER BY compressed;

-- ============================================================
-- 8. PREWHERE 优化
-- ============================================================
-- 【原理】
--   WHERE: 一次性读所有列 → 过滤 → 输出
--   PREWHERE: 先读过滤列(主键/索引列) → 过滤掉不满足的行 → 再读其他列
--   高过滤率场景(过滤掉 90%+)省 I/O 极多
-- 【场景】过滤条件选择性高(95%+ 行被过滤), 且过滤列不是 SELECT 列
-- 【对比】
--   WHERE: 读 5 列 × 100万行 = 500万 cell
--   PREWHERE (95% 过滤): 读 1 列 × 100万 + 4 列 × 5万 = 120万 cell → 省 76%
-- 【坑】25.x 默认 optimize_move_to_prewhere=1, 会自动把适合的 WHERE 改写为 PREWHERE
--       但显式 PREWHERE 优先级更高, 适合人工调优

SELECT
    user_id,
    count() AS cnt,
    round(sum(value), 2) AS total_value
FROM tutorial.column_store_demo
PREWHERE event_date >= '2024-03-01'  -- 先读这一列过滤
WHERE event_type = 'purchase'         -- 再用过滤后的行读 event_type 列做二次过滤
GROUP BY user_id
ORDER BY cnt DESC
LIMIT 10;

-- ============================================================
-- 9. 清理
-- ============================================================
DROP TABLE IF EXISTS tutorial.column_store_demo;
DROP TABLE IF EXISTS tutorial.compression_comparison;
DROP TABLE IF EXISTS tutorial.granularity_test;
DROP TABLE IF EXISTS tutorial.compression_lz4;
DROP TABLE IF EXISTS tutorial.compression_zstd;
DROP TABLE IF EXISTS tutorial.compression_delta;
DROP TABLE IF EXISTS tutorial.type_selection;

-- =====================================================
-- 本章小结
-- =====================================================
-- 1. 列式存储按列独立文件, 查询只读需要的列 → 省 I/O
-- 2. 同列同类型 → 压缩率高 5-10× → 再省 I/O
-- 3. LowCardinality 字典编码: 低基数字符串省 5-10× 存储
-- 4. index_granularity=8192 平衡索引大小与读取粒度
-- 5. 压缩算法: LZ4(热) / ZSTD(冷) / Delta(序列) / Gorilla(时序)
-- 6. 向量化: SIMD 一次处理 8/16 个值, CPU 密集算子提速 10-100×
-- 7. 数据类型选最小够用: Int8 < Int16 < Int32 < Int64
-- 8. PREWHERE 先读过滤列, 高过滤率场景省 I/O
--
-- 下一步: 03_mergetree.sql - MergeTree 引擎原理
-- =====================================================
