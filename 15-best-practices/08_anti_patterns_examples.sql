-- ============================================================
-- ClickHouse 反模式演示 SQL
-- 集群：treasurycluster（CH 25.12.1.649）
-- 说明：本文件演示 15 个最常见反模式，每个都包含
--       ❌ 反模式写法 → 症状演示 → ✅ 正确写法
-- 前置条件：无（幂等可重复执行）
-- 学习目标：通过"踩坑"理解 ClickHouse 设计哲学，形成正确直觉
-- ============================================================

CREATE DATABASE IF NOT EXISTS antipattern_demo;

-- ============================================================
-- 反模式 1：单行 INSERT（小批量写入）
-- ============================================================

-- 【原理】每次 INSERT 生成一个不可变 Part。单行写入 = 每个 Part 一行，
-- 合并线程永远追不上生成速度，Part 数量爆炸 → 查询退化。

-- ❌ 反模式：循环单行写入（生产代码中的常见错误）
-- for i in range(10000):
--     clickhouse_client.execute("INSERT INTO t VALUES (%d, %s)" % (i, 'x'))
-- 效果：10000 个 Part

-- ✅ 正确：批量写入（一条 INSERT 多行）
CREATE TABLE IF NOT EXISTS antipattern_demo.events_batch
(
    id UInt64,
    event_type String
)
ENGINE = MergeTree()
ORDER BY id;

INSERT INTO antipattern_demo.events_batch VALUES
(1, 'click'), (2, 'view'), (3, 'purchase'), (4, 'click'), (5, 'view'),
(6, 'purchase'), (7, 'click'), (8, 'view'), (9, 'purchase'), (10, 'click');

-- ✅ 正确：异步插入（应用埋点场景）
-- SET async_insert = 1, wait_for_async_insert = 0;
-- INSERT INTO events VALUES ...  -- 服务器缓冲后批量落盘

-- 检查当前 Part 数量（健康标准：active < 300）
SELECT
    table,
    count() AS part_count,
    sum(rows) AS total_rows
FROM system.parts
WHERE database = 'antipattern_demo' AND active = 1
GROUP BY table;

-- ============================================================
-- 反模式 2：SELECT * 无脑全列
-- ============================================================

-- 【原理】列式存储的优势 = 只读需要的列。SELECT * 破坏列裁剪，
-- 宽表场景下慢 10-50x。

CREATE TABLE IF NOT EXISTS antipattern_demo.wide_events
(
    event_time DateTime,
    user_id UInt64,
    event_type String,
    col_4 String, col_5 String, col_6 String, col_7 String,
    col_8 String, col_9 String, col_10 String, col_11 String,
    col_12 String, col_13 String, col_14 String, col_15 String
)
ENGINE = MergeTree()
ORDER BY (event_time, user_id);

-- ❌ 反模式：只需要 event_type 却读所有 15 列
-- SELECT * FROM wide_events WHERE event_time = today();

-- ✅ 正确：只选需要的列
SELECT event_type, count()
FROM antipattern_demo.wide_events
WHERE event_time >= today()
GROUP BY event_type;

-- 用 EXPLAIN 验证列裁剪效果
-- EXPLAIN PIPELINE SELECT event_type FROM wide_events WHERE event_time = today();

-- ============================================================
-- 反模式 3：ORDER BY 低基数列在前
-- ============================================================

-- 【原理】稀疏索引按排序键顺序二分裁剪。低基数列（如 status 仅 3 种
-- 取值）放最前 → 索引几乎无法缩小范围 → 退化为全表扫描。

CREATE TABLE IF NOT EXISTS antipattern_demo.bad_order_key
(
    event_date Date,
    status LowCardinality(String),  -- 只有 3 种取值
    user_id UInt64,
    amount Decimal(18, 2)
)
ENGINE = MergeTree()
ORDER BY (status, event_date, user_id);  -- ❌ status 排第一

CREATE TABLE IF NOT EXISTS antipattern_demo.good_order_key
(
    event_date Date,
    status LowCardinality(String),
    user_id UInt64,
    amount Decimal(18, 2)
)
ENGINE = MergeTree()
ORDER BY (event_date, user_id, status);  -- ✅ 高基数/高频过滤列在前

-- 插入相同数据
INSERT INTO antipattern_demo.bad_order_key SELECT
    '2024-01-01', ['new','paid','cancelled'][rand() % 3], number, rand() % 10000
FROM numbers(100000);
INSERT INTO antipattern_demo.good_order_key SELECT
    '2024-01-01', ['new','paid','cancelled'][rand() % 3], number, rand() % 10000
FROM numbers(100000);

-- 对比：按 user_id 过滤时的读取行数
SELECT 'bad_order_key' AS table_name, sum(read_rows) AS read_rows FROM (
    SELECT read_rows FROM system.query_log WHERE query LIKE '%bad_order_key%' AND query LIKE '%user_id =%'
    ORDER BY event_time DESC LIMIT 1
) SETTINGS log_queries = 0;  -- 简化演示，直接对比下面查询

-- ✅ 正确查询（user_id 在排序键中靠后，但等值过滤仍有收益）
SELECT count()
FROM antipattern_demo.good_order_key
WHERE user_id = 50000 AND event_date = '2024-01-01';

-- ============================================================
-- 反模式 4：分区过细
-- ============================================================

-- 【原理】分区是物理隔离级别。粒度过细（小时/分钟）导致 Part 数 =
-- 分区数 × 每区 Part 数，爆炸式增长。

-- ❌ 反模式：按小时分区
CREATE TABLE IF NOT EXISTS antipattern_demo.part_by_hour
(
    event_time DateTime,
    user_id UInt64
)
ENGINE = MergeTree()
PARTITION BY toStartOfHour(event_time)  -- ❌ 每小时一个分区
ORDER BY event_time;

-- ✅ 正确：按天分区
CREATE TABLE IF NOT EXISTS antipattern_demo.part_by_day
(
    event_time DateTime,
    user_id UInt64
)
ENGINE = MergeTree()
PARTITION BY toDate(event_time)  -- ✅ 天级裁剪 + TTL 清理
ORDER BY event_time;

-- 检查分区数量差异
SELECT
    table,
    count(DISTINCT partition) AS partition_count,
    count() AS part_count
FROM system.parts
WHERE database = 'antipattern_demo' AND active = 1
GROUP BY table;

-- ============================================================
-- 反模式 5：用 String 存数值/日期
-- ============================================================

-- 【原理】String 变长编码无法利用定长压缩和向量化计算。

-- ❌ 反模式
CREATE TABLE IF NOT EXISTS antipattern_demo.string_types
(
    order_id String,
    amount String,
    order_date String
)
ENGINE = MergeTree()
ORDER BY order_id;

-- ✅ 正确
CREATE TABLE IF NOT EXISTS antipattern_demo.proper_types
(
    order_id UInt64,
    amount Decimal(18, 2),
    order_date Date
)
ENGINE = MergeTree()
ORDER BY order_id;

-- 存储对比（同样数据）
INSERT INTO antipattern_demo.string_types VALUES
('1', '99.50', '2024-01-15'),
('2', '199.00', '2024-01-16');

INSERT INTO antipattern_demo.proper_types VALUES
(1, 99.50, '2024-01-15'),
(2, 199.00, '2024-01-16');

-- ✅ 数值计算可以直接做
SELECT sum(amount) FROM antipattern_demo.proper_types;
-- ❌ String 需要先转换，且索引无法优化
-- SELECT sum(toDecimal64(amount, 2)) FROM antipattern_demo.string_types;

-- ============================================================
-- 反模式 6：FINAL 滥用
-- ============================================================

-- 【原理】FINAL 在查询时实时合并所有相关 Part，把后台合并工作
-- 搬到查询路径上，慢 100 倍。

CREATE TABLE IF NOT EXISTS antipattern_demo.replacing_demo
(
    order_id UInt64,
    status String,
    version UInt64
)
ENGINE = ReplacingMergeTree(version)
ORDER BY order_id;

INSERT INTO antipattern_demo.replacing_demo VALUES
(1, 'new', 1),
(1, 'paid', 2),
(2, 'new', 1);

-- ❌ 反模式：每个查询都 FINAL
SELECT * FROM antipattern_demo.replacing_demo FINAL;

-- ✅ 正确：argMax 替代 FINAL
SELECT
    order_id,
    argMax(status, version) AS latest_status
FROM antipattern_demo.replacing_demo
GROUP BY order_id;

-- ✅ 或先合并再查（小表场景）
OPTIMIZE TABLE antipattern_demo.replacing_demo FINAL;
SELECT * FROM antipattern_demo.replacing_demo;

-- ============================================================
-- 反模式 7：无物化视图预聚合
-- ============================================================

-- 【原理】高频聚合查询每次都全表计算，是最大浪费。MV 在 INSERT 时
-- 增量预聚合。

-- 源表
CREATE TABLE IF NOT EXISTS antipattern_demo.raw_events
(
    event_time DateTime,
    event_type String,
    amount Decimal(18, 2)
)
ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_type, event_time);

-- ✅ 物化视图：INSERT 时增量预聚合
CREATE MATERIALIZED VIEW IF NOT EXISTS antipattern_demo.mv_daily
ENGINE = SummingMergeTree()
PARTITION BY toYYYYMM(day)
ORDER BY (day, event_type)
AS SELECT
    toDate(event_time) AS day,
    event_type,
    count() AS event_count,
    sum(amount) AS total_amount
FROM antipattern_demo.raw_events
GROUP BY day, event_type;

-- 写入数据
INSERT INTO antipattern_demo.raw_events SELECT
    '2024-01-15 10:00:00' + number % 3600, ['click','view','purchase'][number % 3], rand() % 1000
FROM numbers(10000);

-- ❌ 反模式：看板直接扫源表（每次全量聚合 10000 行）
SELECT toDate(event_time) AS day, event_type, count(), sum(amount)
FROM antipattern_demo.raw_events
GROUP BY day, event_type;

-- ✅ 正确：查预聚合表（只读聚合结果）
SELECT * FROM antipattern_demo.mv_daily ORDER BY total_amount DESC;

-- 验证聚合一致性
SELECT
    (SELECT count() FROM antipattern_demo.mv_daily) AS mv_rows,
    (SELECT count() FROM (
        SELECT 1 FROM antipattern_demo.raw_events
        GROUP BY toDate(event_time), event_type
    )) AS direct_groups;

-- ============================================================
-- 反模式 8：Mutation 当日常操作
-- ============================================================

-- 【原理】ALTER ... UPDATE/DELETE 是 mutation，会重写所有匹配分区数据，
-- 且每个副本都执行。高频使用 = 副本积压、卡死。

-- ❌ 反模式：高频条件删除
-- ALTER TABLE events DELETE WHERE event_type = 'debug';  -- 每次重写全部

-- ✅ 正确 1：分区删除（条件 = 分区键时）
-- ALTER TABLE antipattern_demo.part_by_day DROP PARTITION '2024-01-15';

-- ✅ 正确 2：TTL 自动过期（后台合并时删除，不阻塞查询）
ALTER TABLE antipattern_demo.raw_events
    MODIFY TTL event_time + INTERVAL 90 DAY DELETE;

-- ✅ 正确 3：轻量删除（CH 23.x+，标记不重写）
-- ALTER TABLE antipattern_demo.raw_events
--     DELETE WHERE event_type = 'debug' SETTINGS lightweight_deletes = 1;

-- 查看 mutation 队列（应保持为空）
SELECT
    table,
    count() AS mutation_count
FROM system.mutations
WHERE database = 'antipattern_demo'
GROUP BY table;

-- ============================================================
-- 反模式 9：JOIN 无 GLOBAL
-- ============================================================

-- 【原理】分布式表 JOIN 时，普通 JOIN 会在每个分片重复加载右表；
-- GLOBAL JOIN 只加载一次并广播。

-- 本地示例（模拟概念）：小维度表优先用字典/本地 JOIN
CREATE TABLE IF NOT EXISTS antipattern_demo.dim_users
(
    user_id UInt64,
    user_name String,
    tier String
)
ENGINE = MergeTree()
ORDER BY user_id;

INSERT INTO antipattern_demo.dim_users VALUES
(1, 'Alice', 'gold'),
(2, 'Bob', 'silver'),
(3, 'Carol', 'gold');

-- ✅ 正确：小表 JOIN 用本地表（不分片）
SELECT
    e.user_id,
    u.user_name,
    count() AS event_count
FROM antipattern_demo.events_batch e
LEFT JOIN antipattern_demo.dim_users u ON e.user_id = u.user_id
GROUP BY e.user_id, u.user_name;

-- ✅ 更优：字典替代 JOIN（超高频场景）
CREATE DICTIONARY IF NOT EXISTS antipattern_demo.users_dict
(
    user_id UInt64,
    user_name String,
    tier String
)
PRIMARY KEY user_id
SOURCE(CLICKHOUSE(DATABASE 'antipattern_demo' TABLE 'dim_users'))
LIFETIME(MIN 60 MAX 300)
LAYOUT(HASHED());

-- 用字典查询（比 JOIN 快 10-100x）
SELECT
    e.user_id,
    dictGet('antipattern_demo.users_dict', 'user_name', e.user_id) AS user_name,
    count() AS event_count
FROM antipattern_demo.events_batch e
GROUP BY e.user_id;

-- ============================================================
-- 反模式 10：无 TTL 数据无限增长
-- ============================================================

-- 【原理】ClickHouse 默认不清理数据。必须显式 TTL。

-- ✅ 基础 TTL：90 天后删除
ALTER TABLE antipattern_demo.raw_events
    MODIFY TTL event_time + INTERVAL 90 DAY DELETE;

-- 查看 TTL 配置
SELECT
    table,
    delete_ttl_info_min AS min_ttl,
    delete_ttl_info_max AS max_ttl
FROM system.parts
WHERE database = 'antipattern_demo'
  AND table = 'raw_events'
  AND active = 1
LIMIT 1;

-- ============================================================
-- 反模式 11：小表也分片
-- ============================================================

-- 【原理】分片收益只在单表超单机承载时体现。维度表/小表分片
-- 只会增加查询放大和运维复杂度。

-- ❌ 反模式：维度表也建 Distributed
-- CREATE TABLE dim_users_dist AS dim_users ENGINE = Distributed(cluster, db, dim_users, cityHash64(user_id));

-- ✅ 正确：维度表用复制表（每个节点一份，本地 JOIN）
-- ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/dim_users', '{replica}')

-- 决策判断：
-- 事实表：数据量 > 1TB → 分片；否则复制表即可
-- 维度表：永不主动分片（用复制表 + 字典）

-- ============================================================
-- 反模式 12：跳数索引过多
-- ============================================================

-- 【原理】跳数索引只在选择性高、条件匹配时才生效。盲目建索引
-- 拖累写入，无查询收益。

CREATE TABLE IF NOT EXISTS antipattern_demo.indexed_events
(
    event_time DateTime,
    user_id UInt64,
    event_type String,
    url String
)
ENGINE = MergeTree()
ORDER BY event_time
-- ✅ 精准建索引：只给高频过滤且非排序键的列建
INDEX idx_user_id user_id TYPE minmax GRANULARITY 4,
INDEX idx_event_type event_type TYPE set(100) GRANULARITY 4;

-- ❌ 反模式：给排序键列建索引（无用）
-- INDEX idx_event_time event_time TYPE minmax GRANULARITY 4  -- 排序键已有索引

-- 验证索引是否命中
-- EXPLAIN indexes = 1
-- SELECT * FROM indexed_events WHERE user_id = 42;

-- ============================================================
-- 反模式 13：复制表却只有单副本
-- ============================================================

-- 【原理】ReplicatedMergeTree 只是"复制"到其他副本。副本数 = 1
-- 时就是普通表；且复制 ≠ 备份（DROP 会复制到所有副本）。

-- ✅ 正确：副本 ≥ 2 + 定期备份
-- ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/events', '{replica}')

-- 检查副本数
SELECT
    table,
    count() AS replica_count
FROM system.replicas
WHERE database = 'antipattern_demo'
GROUP BY table;

-- ✅ 备份到本地/对象存储
-- BACKUP TABLE antipattern_demo.raw_events
-- TO Disk('backups', 'raw_events_backup');

-- ============================================================
-- 反模式 14：无并发/内存限制
-- ============================================================

-- 【原理】CH 默认允许单查询大量内存和无限并发。共享集群必须
-- 显式设置边界，否则一个查询 OOM 全集群。

-- ✅ 用户级限制
CREATE USER IF NOT EXISTS limited_analyst
IDENTIFIED WITH sha256_password BY 'LimitedPass123!'
SETTINGS
    max_memory_usage = 10000000000,      -- 10 GB
    max_concurrent_queries_for_user = 5,  -- 单用户并发 5
    max_execution_time = 300;             -- 5 分钟超时

-- ✅ 角色级限制（可复用，推荐）
CREATE ROLE IF NOT EXISTS limited_role
SETTINGS
    max_memory_usage = 10000000000,
    max_concurrent_queries_for_user = 5;

-- ✅ Workload Group（生产推荐）
CREATE WORKLOAD GROUP IF NOT EXISTS demo_etl_group
SETTINGS
    max_concurrent_queries = 10,
    max_memory_usage = 50000000000,
    priority = 5;

-- 验证用户设置
SELECT
    user_name,
    settings['max_memory_usage'] AS max_mem,
    settings['max_concurrent_queries_for_user'] AS max_concurrent
FROM system.users
WHERE user_name = 'limited_analyst';

-- ============================================================
-- 反模式 15：依赖 FINAL/期望即时唯一
-- ============================================================

-- 【原理】ReplacingMergeTree/SummingMergeTree 的去重发生在后台合并时，
-- 不是 INSERT 时。新数据合并前会短暂重复 = 最终一致。

-- ❌ 反模式：写入后立刻期望唯一
INSERT INTO antipattern_demo.replacing_demo VALUES
(3, 'new', 1), (3, 'paid', 2);

-- 合并前：可能看到两行 order_id=3（不是错误，是设计）
SELECT * FROM antipattern_demo.replacing_demo
WHERE order_id = 3;

-- ✅ 正确：查询时主动去重（不依赖合并时机）
SELECT
    order_id,
    argMax(status, version) AS latest_status
FROM antipattern_demo.replacing_demo
GROUP BY order_id
ORDER BY order_id;

-- ✅ 或先 OPTIMIZE 再查
OPTIMIZE TABLE antipattern_demo.replacing_demo FINAL;
SELECT * FROM antipattern_demo.replacing_demo ORDER BY order_id;

-- ============================================================
-- 清理示例资源
-- ============================================================

-- DROP DATABASE IF EXISTS antipattern_demo;
-- DROP DICTIONARY IF EXISTS antipattern_demo.users_dict;
-- DROP USER IF EXISTS limited_analyst;
-- DROP ROLE IF EXISTS limited_role;
-- DROP WORKLOAD GROUP IF EXISTS demo_etl_group;
