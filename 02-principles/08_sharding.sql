-- ============================================================
-- 文件: 02-principles/08_sharding.sql
-- 学习目标: 掌握 ClickHouse 分片(Sharding)与分布式查询原理，会用两阶段聚合
-- 深度标准: 原理 + 场景 + 对比 + 可运行
-- 集群: treasurycluster (CH 25.12.1.649, 2 副本 × 1 分片, 3 Keeper)
-- 前置: 无（自包含测试数据，按顺序执行）
-- ============================================================
--
-- 本文件章节:
--   1.  分片 vs 副本：概念区分与拓扑观察
--   2.  本地表 + 分布式表创建（ReplicatedMergeTree + Distributed）
--   3.  分片键原理：rand / hash / range 分片对比
--   4.  分布式写入：Distributed 表 INSERT 路由
--   5.  分布式查询：分解 → 并行 → 合并
--   6.  两阶段聚合：sumState/sumMerge 跨分片合并（核心）
--   7.  本地查询 vs 分布式查询性能对比
--   8.  跨分片 JOIN 策略（GLOBAL JOIN 实战）
--   9.  分片监控：数据分布与查询诊断
--   10. 清理
--
-- 【关键认知】本集群 treasurycluster 为"2 副本 × 1 分片"配置，
--   即只有一个分片、该分片有 2 个副本。因此分片相关的"跨分片"
--   行为在本集群上无法体现数据切分效果，但 SQL 语法、Distributed
--   引擎、两阶段聚合的原理完全一致。多分片集群只需在 config.xml
--   增加 <shard> 配置即可，DDL/DML 写法不变。
-- ============================================================

-- ============================================================
-- 1. 分片 vs 副本：概念区分与拓扑观察
-- ============================================================
-- 【原理】分片与副本解决不同问题：
--   - 分片(Shard): 水平切分数据，扩展存储与查询吞吐（写扩展）
--   - 副本(Replica): 同一份数据冗余存储，提升可用性与读吞吐（读扩展）
--   二者正交：每个分片可以有多个副本。
-- 【对比】
--   | 维度       | 分片(Shard)         | 副本(Replica)         |
--   |------------|---------------------|-----------------------|
--   | 解决问题   | 单机存储/算力不足    | 单点故障/读吞吐不足    |
--   | 数据关系   | 各分片数据不同       | 各副本数据相同         |
--   | 实现引擎   | Distributed 表      | ReplicatedMergeTree   |
--   | 协调组件   | 无（Distributed 路由）| Keeper（log 协调）    |
--   | 一致性     | 分片间无一致性问题   | 异步最终一致           |
-- 【场景】
--   - 数据量 > 单机磁盘容量 → 加分片
--   - 查询 QPS > 单机处理能力 → 加分片（并行）
--   - 担心节点宕机丢数据 → 加副本
--   - 读 QPS 高、单机 CPU 闲 → 加副本分担读

-- 1.1 观察集群拓扑
-- 【结果解读】treasurycluster: shard_num=1, 两个 replica (host_name 区分)
SELECT
    cluster,
    shard_num,
    replica_num,
    host_name,
    host_address,
    port,
    is_local
FROM system.clusters
WHERE cluster = 'treasurycluster'
ORDER BY shard_num, replica_num;

-- 1.2 观察本节点的宏配置（{shard}/{replica} 的值）
-- 【原理】ReplicatedMergeTree 的 '/path' 和 'replica' 参数用宏替换
-- 【结果解读】macro 列是宏名（如 shard/replica），substitution 列是替换值
SELECT macro, substitution FROM system.macros;


-- ============================================================
-- 2. 本地表 + 分布式表创建
-- ============================================================
-- 【原理】分片架构需要两层表：
--   ① 本地表（Local Table）: 每个分片上实际存储数据的表，用 ReplicatedMergeTree
--   ② 分布式表（Distributed Table）: 逻辑表，不存数据，只做查询路由
--   查询/写入分布式表时，Distributed 引擎自动路由到各分片的本地表。
-- 【对比】
--   | 操作         | 写本地表       | 写分布式表                |
--   |--------------|----------------|---------------------------|
--   | 数据落点     | 只落当前节点   | 按分片键路由到对应分片     |
--   | 适用场景     | 已知分片的定点写 | 上层应用不关心分片细节    |
--   | 性能         | 最快（无路由） | 稍慢（多一跳路由+网络）    |
-- 【坑】
--   - 生产建议写本地表（可控分片），查询用分布式表
--   - 写分布式表会多一次网络转发（Distributed → 各分片），且失败处理复杂

CREATE DATABASE IF NOT EXISTS tutorial ON CLUSTER 'treasurycluster';

-- 2.1 本地表（每个分片上的实际存储表）
-- 【原理】ReplicatedMergeTree 让同一分片的多个副本数据同步
DROP TABLE IF EXISTS tutorial.shard_events ON CLUSTER 'treasurycluster' SYNC;

CREATE TABLE tutorial.shard_events ON CLUSTER 'treasurycluster' (
    id UInt64,
    event_date Date,
    user_id UInt32,
    event_type LowCardinality(String),
    amount Decimal(10, 2)
) ENGINE = ReplicatedMergeTree()
PARTITION BY toYYYYMM(event_date)
ORDER BY (user_id, event_date, id);

-- 2.2 分布式表（逻辑路由表）
-- 【原理】Distributed 引擎参数:
--   ('集群名', '数据库', '本地表名', [分片键表达式])
--   分片键决定 INSERT 到分布式表时数据路由到哪个分片
DROP TABLE IF EXISTS tutorial.dist_events ON CLUSTER 'treasurycluster' SYNC;

CREATE TABLE tutorial.dist_events ON CLUSTER 'treasurycluster' AS tutorial.shard_events
ENGINE = Distributed(
    'treasurycluster',      -- 集群名
    'tutorial',             -- 本地表所在库
    'shard_events',         -- 本地表名
    sipHash64(user_id)      -- 分片键（按 user_id 哈希分片）
);

-- 2.3 查看分布式表配置
SELECT
    database, table, engine,
    engine_full  -- 完整引擎定义（含分片键）
FROM system.tables
WHERE database = 'tutorial' AND table IN ('shard_events', 'dist_events');


-- ============================================================
-- 3. 分片键原理：rand / hash / range 分片对比
-- ============================================================
-- 【原理】分片键 = f(列值) % 分片数，决定数据去哪个分片
--   分片键设计目标:
--   ① 分布均匀（避免热点）
--   ② 查询局部化（高频查询条件 = 分片键，可只扫一个分片）
--   ③ 避免跨分片 JOIN（相关表用同分片键）
-- 【对比】三种分片键
--   | 类型     | 表达式                  | 优点              | 缺点                  | 适用                |
--   |----------|-------------------------|-------------------|-----------------------|---------------------|
--   | 随机分片 | rand()                  | 绝对均匀          | 无法局部查询          | 无明显查询模式的日志 |
--   | 哈希分片 | sipHash64(user_id)      | 同值同分片,可局部 | 值域不均仍倾斜        | 按用户/设备维度查询  |
--   | 范围分片 | toYYYYMM(event_date)    | 时间范围局部化    | 冷热不均(新数据集中)  | 时间序列、按月归档   |
-- 【场景】本集群单分片，分片键不实际切分数据，但语法与多分片完全一致

-- 3.1 创建不同分片键的分布式表（演示语法，单分片下行为相同）
DROP TABLE IF EXISTS tutorial.dist_rand ON CLUSTER 'treasurycluster' SYNC;
CREATE TABLE tutorial.dist_rand ON CLUSTER 'treasurycluster' AS tutorial.shard_events
ENGINE = Distributed('treasurycluster', 'tutorial', 'shard_events', rand());

DROP TABLE IF EXISTS tutorial.dist_hash ON CLUSTER 'treasurycluster' SYNC;
CREATE TABLE tutorial.dist_hash ON CLUSTER 'treasurycluster' AS tutorial.shard_events
ENGINE = Distributed('treasurycluster', 'tutorial', 'shard_events', sipHash64(user_id));

DROP TABLE IF EXISTS tutorial.dist_range ON CLUSTER 'treasurycluster' SYNC;
CREATE TABLE tutorial.dist_range ON CLUSTER 'treasurycluster' AS tutorial.shard_events
ENGINE = Distributed('treasurycluster', 'tutorial', 'shard_events', toYYYYMM(event_date));


-- ============================================================
-- 4. 分布式写入：Distributed 表 INSERT 路由
-- ============================================================
-- 【原理】INSERT 到分布式表时：
--   ① Distributed 引擎计算每行的分片键 → 决定目标分片
--   ② 按分片分组数据，通过 Native 协议发送到各分片
--   ③ 各分片收到后写入本地表
--   【注意】本集群单分片，所有数据都路由到 shard 1，但流程与多分片一致

-- 4.1 通过分布式表写入（推荐查询用分布式表，写入看场景）
INSERT INTO tutorial.dist_events VALUES
    (1, '2024-01-15', 1001, 'click',   29.99),
    (2, '2024-01-15', 1002, 'view',    0.00),
    (3, '2024-01-15', 1001, 'purchase', 199.50),
    (4, '2024-01-16', 1003, 'click',   15.00),
    (5, '2024-01-16', 1002, 'purchase', 89.90),
    (6, '2024-01-16', 1004, 'view',    0.00),
    (7, '2024-01-17', 1001, 'click',   12.50),
    (8, '2024-01-17', 1003, 'purchase', 350.00),
    (9, '2024-01-17', 1005, 'view',    0.00),
    (10, '2024-01-17', 1002, 'click',  8.99);

-- 4.2 验证数据已落本地表（Distributed 不存数据）
-- 【结果解读】本地表 shard_events 有 10 行，分布式表查询也返回 10 行
SELECT 'local_table' AS source, count() AS rows FROM tutorial.shard_events
UNION ALL
SELECT 'distributed_table' AS source, count() AS rows FROM tutorial.dist_events;


-- ============================================================
-- 5. 分布式查询：分解 → 并行 → 合并
-- ============================================================
-- 【原理】分布式表 SELECT 流程:
--   ① 协调节点收到 SELECT，改写为子查询发往各分片
--   ② 各分片并行执行子查询，返回"部分结果"
--   ③ 协调节点合并各分片部分结果，返回最终结果
--   【关键】不是"拉全量数据再聚合"，而是"各分片先聚合，再合并聚合结果"

-- 5.1 普通聚合（自动两阶段）
-- 【原理】sum/count 等可加聚合，CH 自动两阶段：
--   各分片: SELECT sum(amount) FROM shard_events → 部分和
--   协调节点: 合并各分片部分和 → 总和
SELECT
    event_type,
    count() AS event_count,
    sum(amount) AS total_amount,
    avg(amount) AS avg_amount
FROM tutorial.dist_events
GROUP BY event_type
ORDER BY total_amount DESC;

-- 5.2 查看分布式查询计划（EXPLAIN）
-- 【结果解读】计划中有 RemoteSource / ReadFromRemote，证明查询被分发到各分片
EXPLAIN PLAN
SELECT count(), sum(amount) FROM tutorial.dist_events WHERE event_date = '2024-01-15';


-- ============================================================
-- 6. 两阶段聚合：sumState/sumMerge 跨分片合并（核心）
-- ============================================================
-- 【原理】这是分布式聚合的进阶，也是 04-functions 聚合状态函数的分布式应用
--   普通聚合(sum)对"可加"指标(求和/计数)天然支持两阶段:
--     分片: sum(amount) → s1, s2, s3 (部分和)
--     协调: s1+s2+s3 = 总和
--   但对"不可加"指标(分位数/UV/TopK)，普通聚合无法两阶段:
--     分片: quantile(0.9)(amount) → q1, q2, q3 (各分片自己的 P90)
--     协调: 无法从 q1,q2,q3 算出全局 P90！(分位数不可加)
--   解决: 用 *State 函数，各分片返回"聚合状态"(二进制)，协调节点 *Merge 合并
--   详见 05-functions/README.md §3 聚合状态函数原理
-- 【场景】跨分片 UV(uniq)、P99 延迟(quantile)、TopK、漏斗步骤收集
-- 【对比】
--   | 指标          | 普通聚合能否两阶段 | 状态函数方案                  |
--   |---------------|-------------------|-------------------------------|
--   | sum / count   | ✅ 可加            | 不需要(但 sumState 也可用)    |
--   | avg           | ⚠️ 需 sum+count   | avgState 可两阶段             |
--   | uniq (UV)     | ❌ 不可加          | uniqState + uniqMerge         |
--   | quantile      | ❌ 不可加          | quantileState + quantileMerge |
--   | topK          | ❌ 不可加          | topKState + topKMerge         |

-- 6.1 演示：UV 跨分片合并
-- 【原理】uniq(user_id) 用 HyperLogLog，各分片算自己的 HLL 状态，
--   协调节点 uniqMerge 合并 HLL 状态得到全局 UV
--   对比 count(DISTINCT user_id) 必须把所有 user_id 拉到协调节点才能去重，慢且费网络
SELECT
    event_date,
    uniqMerge(uv_state) AS uv  -- 合并各分片的 HLL 状态
FROM
(
    -- 子查询：各分片本地计算 uniqState
    SELECT
        event_date,
        uniqState(user_id) AS uv_state  -- 返回 HLL 二进制状态
    FROM tutorial.dist_events
    GROUP BY event_date
)
GROUP BY event_date
ORDER BY event_date;

-- 6.2 对比：直接 uniq（CH 内部其实也做了类似优化，但显式 *State 更可控）
SELECT
    event_date,
    uniq(user_id) AS uv
FROM tutorial.dist_events
GROUP BY event_date
ORDER BY event_date;

-- 6.3 演示：P90 分位数跨分片合并
-- 【原理】quantile(0.9) 不可加，必须用 quantileState + quantileMerge
SELECT
    event_type,
    quantileMerge(0.9)(p90_state) AS p90_amount  -- 合并各分片的分位数状态
FROM
(
    SELECT
        event_type,
        quantileState(0.9)(amount) AS p90_state  -- 各分片返回分位数状态
    FROM tutorial.dist_events
    GROUP BY event_type
)
GROUP BY event_type
ORDER BY event_type;

-- 6.4 配合 AggregatingMergeTree 物化视图的完整方案（见 04-functions）
-- 明细表 → MV 用 *State 预聚合到日表 → 查询用 *Merge 跨分片合并
-- 详见 05-functions/01_basic_functions_examples.sql §11


-- ============================================================
-- 7. 本地查询 vs 分布式查询性能对比
-- ============================================================
-- 【原理】
--   本地查询(查 shard_events): 只扫当前节点数据，无网络开销，最快
--   分布式查询(查 dist_events): 路由到所有分片，有网络往返，但可并行
--   【单分片集群下】二者扫的数据相同，分布式查询多了路由开销，略慢
--   【多分片集群下】分布式查询并行扫所有分片，可能更快（取决于数据量与网络）

-- 7.1 本地查询
SELECT 'local' AS source, count() AS rows, sum(amount) AS total
FROM tutorial.shard_events
WHERE event_date BETWEEN '2024-01-15' AND '2024-01-17';

-- 7.2 分布式查询（单分片下应与本地查询结果相同）
SELECT 'distributed' AS source, count() AS rows, sum(amount) AS total
FROM tutorial.dist_events
WHERE event_date BETWEEN '2024-01-15' AND '2024-01-17';

-- 7.3 利用分片键过滤（多分片时可只扫一个分片）
-- 【原理】WHERE user_id = 1001 且分片键 = sipHash64(user_id) 时，
--   Distributed 引擎能算出 user_id=1001 只在某个分片，只发查询到那一个分片
--   单分片下看不出差异，多分片下省 (N-1)/N 的扫描量
SELECT count() AS user_events
FROM tutorial.dist_events
WHERE user_id = 1001;  -- 分片键过滤


-- ============================================================
-- 8. 跨分片 JOIN 策略（GLOBAL JOIN 实战）
-- ============================================================
-- 【原理】跨分片 JOIN 是分布式查询的难点:
--   普通 JOIN: 各分片把右表全量拉到协调节点 → 协调节点 JOIN → 网络爆炸
--   GLOBAL JOIN: 协调节点先算右表子查询 → 把结果广播到各分片 → 各分片本地 JOIN
-- 【对比】
--   | 策略          | 右表处理       | 网络传输     | 适用               |
--   |---------------|----------------|--------------|--------------------|
--   | JOIN          | 各分片拉右表   | 大（右表×N） | 右表也分片且同键   |
--   | GLOBAL JOIN   | 协调算后广播   | 小（结果×N） | 右表小（维表）     |
--   | 子查询 IN     | 类似 GLOBAL    | 小           | 半连接             |
-- 【场景】大事实表 JOIN 小维表（如 events JOIN users）→ 用 GLOBAL JOIN

-- 8.1 准备一张小维表
DROP TABLE IF EXISTS tutorial.users_dim ON CLUSTER 'treasurycluster' SYNC;
CREATE TABLE tutorial.users_dim ON CLUSTER 'treasurycluster' (
    user_id UInt32,
    user_name String,
    vip_level UInt8
) ENGINE = ReplicatedMergeTree()
ORDER BY user_id;

INSERT INTO tutorial.users_dim VALUES
    (1001, 'Alice', 3),
    (1002, 'Bob',   1),
    (1003, 'Carol', 2),
    (1004, 'Dave',  1),
    (1005, 'Eve',   3);

-- 8.2 普通 JOIN（右表被拉到协调节点，大表场景下灾难）
SELECT
    e.event_type,
    u.user_name,
    u.vip_level,
    e.amount
FROM tutorial.dist_events AS e
INNER JOIN tutorial.users_dim AS u ON e.user_id = u.user_id
ORDER BY e.amount DESC
LIMIT 5;

-- 8.3 GLOBAL JOIN（右表子查询先在协调节点算完，再广播到各分片本地 JOIN）
-- 【语法】GLOBAL JOIN 右侧用子查询
SELECT
    e.event_type,
    u.user_name,
    u.vip_level,
    e.amount
FROM tutorial.dist_events AS e
GLOBAL INNER JOIN
(
    SELECT user_id, user_name, vip_level FROM tutorial.users_dim
) AS u ON e.user_id = u.user_id
ORDER BY e.amount DESC
LIMIT 5;
-- 【结果解读】两种 JOIN 结果相同，但 GLOBAL JOIN 在多分片+大右表时性能优很多

-- 8.4 IN 子查询的分布式版（GLOBAL IN）
-- 【原理】GLOBAL IN: 协调节点先算右表子查询，结果广播到各分片做本地 IN 过滤
SELECT
    event_type,
    count() AS vip_events
FROM tutorial.dist_events
WHERE user_id GLOBAL IN (
    SELECT user_id FROM tutorial.users_dim WHERE vip_level >= 2
)
GROUP BY event_type
ORDER BY vip_events DESC;


-- ============================================================
-- 9. 分片监控：数据分布与查询诊断
-- ============================================================

-- 9.1 查看集群拓扑
SELECT
    cluster,
    shard_num,
    replica_num,
    host_name,
    is_local
FROM system.clusters
WHERE cluster = 'treasurycluster'
ORDER BY shard_num, replica_num;

-- 9.2 查看本地表数据量（各分片实际存储）
SELECT
    database, table,
    count() AS parts,
    sum(rows) AS total_rows,
    formatReadableSize(sum(bytes_on_disk)) AS size
FROM system.parts
WHERE database = 'tutorial' AND table = 'shard_events' AND active = 1
GROUP BY database, table;

-- 9.3 查看分布式表的发送队列（待发往各分片的数据）
-- 【原理】写分布式表时，数据先入本地 buffer/queue，再异步发到各分片
--   队列堆积说明网络拥塞或目标分片不可达
-- 【结果解读】data_files=0 表示无积压（数据已全部发往分片）
SELECT
    database, table,
    sum(data_files) AS pending_files,
    formatReadableSize(sum(data_compressed_bytes)) AS pending_size,
    sum(error_count) AS errors,
    any(last_exception) AS last_error
FROM system.distribution_queue
WHERE database = 'tutorial'
GROUP BY database, table;

-- 9.4 查看查询日志（含分布式查询的 read_rows）
-- 【原理】ClickHouse 有两套查询日志表，都依赖 config.xml 配置才会创建/写入:
--   ① system.query_log        —— 每条查询一行，含 tables/read_rows/ProfileEvent 等
--     需在 config.xml 启用 <query_log>(默认有，但本测试环境用 <query_log remove="1"/> 禁用了)
--   ② system.query_thread_log —— 每条查询的每个线程一行(粒度更细)
--     需在 config.xml 保留 <query_thread_log> 且会话级 SET log_query_threads = 1
-- 【坑】
--   - system.query_log 不存在 → 检查 config.xml 是否被 remove
--   - query_thread_log 存在但 0 行 → 默认 log_query_threads=0，需 SET 为 1
--   - 生产排障必开 query_log，它是慢查询/异常诊断的唯一权威数据源
-- 【替代】若只想看"当前正在跑"的查询(非历史)，用 system.processes(实时，无需配置)

-- 9.4a 方案一：system.query_thread_log（本环境可用，先开启线程级日志）
SET log_query_threads = 1;

-- 触发一条分布式查询，使其被记录到 query_thread_log
SELECT count(), sum(amount) FROM tutorial.dist_events WHERE event_date = '2024-01-15';

-- 查询历史（is_initial_query=1 表示协调节点发起的初始查询，0 表示分片子查询）
SELECT
    event_time,
    query_id,
    is_initial_query,                              -- 1=协调节点初始查询, 0=分片子查询
    query_duration_ms,                             -- 耗时(ms)
    read_rows,                                     -- 读取行数(关键！)
    formatReadableSize(read_bytes) AS data_read,   -- 读取字节数
    formatReadableSize(peak_memory_usage) AS peak_mem
FROM system.query_thread_log
WHERE positionCaseInsensitive(query, 'dist_events') > 0  -- 按查询文本过滤
ORDER BY event_time DESC
LIMIT 5;
-- 【结果解读】
--   - 若 is_initial_query=1 的行 read_rows ≈ 分片子查询 read_rows 之和，说明两阶段聚合生效
--   - 多分片集群下会看到 N 条 is_initial_query=0 的子查询(每分片一条)

-- 9.4b 方案二：system.query_log（生产标配，需 config 启用）
-- 取消下方注释并在 config.xml 移除 <query_log remove="1"/> 后可使用:
-- SELECT
--     event_time,
--     query_duration_ms,
--     read_rows,
--     formatReadableSize(read_bytes) AS data_read,
--     formatReadableSize(memory_usage) AS memory,
--     type,                                        -- QueryStart/QueryFinish/ExceptionBeforeStart/ExceptionWhileProcessing
--     arrayStringConcat(tables, ', ') AS tables    -- 涉及的表
-- FROM system.query_log
-- WHERE type = 'QueryFinish'
--   AND has(tables, 'tutorial.dist_events')
-- ORDER BY event_time DESC
-- LIMIT 5;

-- 9.4c 方案三：system.processes（看当前正在执行的查询，无需配置）
-- 【场景】实时排障："现在哪个查询在卡？" 不是历史日志
SELECT
    query_id,
    query,                                         -- 正在执行的 SQL
    elapsed,                                       -- 已执行秒数
    read_rows,
    formatReadableSize(read_bytes) AS data_read,
    formatReadableSize(memory_usage) AS memory
FROM system.processes
WHERE query NOT LIKE '%system.processes%'  -- 排除自身
ORDER BY elapsed DESC
LIMIT 5;


-- ============================================================
-- 10. 清理
-- ============================================================
DROP TABLE IF EXISTS tutorial.dist_events ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS tutorial.dist_rand ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS tutorial.dist_hash ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS tutorial.dist_range ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS tutorial.shard_events ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS tutorial.users_dim ON CLUSTER 'treasurycluster' SYNC;

-- =====================================================
-- 本章小结
-- =====================================================
-- 1. 分片(Shard)扩存储/算力，副本(Replica)提可用性/读吞吐，二者正交
-- 2. 本地表(ReplicatedMergeTree)存数据，分布式表(Distributed)做路由
-- 3. 分片键决定数据分布：随机/哈希/范围各有取舍，匹配查询模式是关键
-- 4. 分布式聚合：sum/count 天然两阶段；uniq/quantile/topK 需 *State/*Merge
-- 5. 跨分片 JOIN：小右表用 GLOBAL JOIN，避免拉全量到协调节点
-- 6. 监控：system.distribution_queue(发送队列)、system.query_thread_log/query_log(read_rows)
--
-- 关联阅读:
--   - 07_replication.md (副本机制，与分片互补)
--   - 05-functions/README.md §3 (聚合状态函数原理)
--   - 03_mergetree.sql §8 (MergeTree 家族含 ReplicatedMergeTree)
-- =====================================================
