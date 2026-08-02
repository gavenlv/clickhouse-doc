-- ============================================================
-- 文件: 03-engines/01_mergetree_engines.sql
-- 学习目标: 透彻理解 MergeTree 家族 7 引擎的 Part 合并算法差异
-- 深度标准: 原理 + 场景 + 对比 + 可运行
-- 集群: treasurycluster (CH 25.12.1.649, 单分片 2 副本)
-- 前置: 无（自包含测试数据，按顺序执行）
-- ============================================================
--
-- 本文件章节:
--   1.  MergeTree 基础引擎（Part 合并骨架、稀疏索引、分区剪枝）
--   2.  ReplacingMergeTree 去重引擎（去重时机、version、FINAL 陷阱）
--   3.  SummingMergeTree 求和引擎（数值列求和、非数值列任意值陷阱）
--   4.  AggregatingMergeTree 聚合引擎（*State/*Merge、可二级聚合）
--   5.  CollapsingMergeTree 折叠引擎（sign 抵消、增量更新）
--   6.  VersionedCollapsingMergeTree 版本折叠（并发乱序安全）
--   7.  GraphiteMergeTree（时序降采样，配置说明）
--   8.  合并算法对比实验（同数据不同引擎，观察合并结果差异）
--   9.  ReplacingMergeTree 去重查询三种写法性能对比
--   10. 清理
-- ============================================================

CREATE DATABASE IF NOT EXISTS engines_test ON CLUSTER 'treasurycluster';
USE engines_test;


-- ============================================================
-- 1. MergeTree 基础引擎
-- ============================================================
-- 【原理】所有 MergeTree 系引擎共享同一套存储骨架：
--   ① INSERT 按分区键切分 → 分区内按 ORDER BY 排序 → 切成 granule(默认8192行)
--   ② 每个 granule 生成一条稀疏主键索引
--   ③ 列式压缩落盘 → 形成不可变的 Part
--   ④ 后台 merge 线程把小 Part 合并成大 Part（MergeTree 只做物理合并，不改内容）
-- 【场景】只追加(append-only)的明细日志、事件流，绝大多数 OLAP 表的默认选择
-- 【对比】MergeTree 是基准，其它引擎只在「合并时对同排序键行施加不同函数」上 differs
-- 【坑】ORDER BY 既是排序键也是主键索引键，没有「主键唯一约束」概念

DROP TABLE IF EXISTS mergetree_events ON CLUSTER 'treasurycluster' SYNC;

CREATE TABLE mergetree_events ON CLUSTER 'treasurycluster' (
    event_id UInt64,
    user_id UInt64,
    event_type String,
    event_data String,
    timestamp DateTime
) ENGINE = ReplicatedMergeTree()
PARTITION BY toYYYYMM(timestamp)
ORDER BY (user_id, event_type, timestamp)
SETTINGS index_granularity = 8192;

-- 注意: INSERT VALUES 内不能有行内注释，注释只能写在外面
INSERT INTO mergetree_events (event_id, user_id, event_type, event_data, timestamp) VALUES
    (1, 1, 'click', '{"page":"home"}', '2024-01-01 10:00:00'),
    (2, 1, 'view', '{"page":"products"}', '2024-01-01 10:05:00'),
    (3, 2, 'click', '{"page":"products"}', '2024-01-01 11:00:00'),
    (4, 3, 'purchase', '{"product_id":101,"amount":99.99}', '2024-01-01 12:00:00'),
    (5, 1, 'logout', '{"duration":3600}', '2024-01-02 09:00:00'),
    (6, 4, 'login', '{"ip":"192.168.1.1"}', '2024-01-02 10:00:00'),
    (7, 5, 'search', '{"query":"laptop"}', '2024-01-02 11:00:00'),
    (8, 2, 'add_to_cart', '{"product_id":102}', '2024-01-03 14:00:00'),
    (9, 3, 'purchase', '{"product_id":103,"amount":149.99}', '2024-01-03 15:00:00'),
    (10, 6, 'click', '{"page":"about"}', '2024-01-04 16:00:00');

-- 1.1 分区剪枝：只扫 2024-01 分区
-- 【结果解读】WHERE 命中分区键，跳过其它分区的 Part
SELECT
    toDate(timestamp) AS event_day,
    count() AS event_count
FROM mergetree_events
WHERE timestamp >= '2024-01-01' AND timestamp < '2024-01-03'
GROUP BY event_day
ORDER BY event_day;

-- 1.2 排序键剪枝：WHERE user_id=1 AND event_type='click' 命中 ORDER BY 前缀
-- 【结果解读】ORDER BY 前缀匹配能命中稀疏主键索引，快速定位 granule
SELECT user_id, event_type, count() AS event_count
FROM mergetree_events
WHERE user_id = 1 AND event_type = 'click'
GROUP BY user_id, event_type;

-- 1.3 查看 Part 信息（观察后台合并）
-- 【原理】每次 INSERT 产生一个 Part，后台 merge 把它们合并
-- 【结果解读】active=1 的 Part 数量随合并减少；rows 是该 Part 行数
SELECT partition, name, rows, bytes_on_disk, modification_time
FROM system.parts
WHERE table = 'mergetree_events' AND database = 'engines_test' AND active = 1
ORDER BY partition;


-- ============================================================
-- 2. ReplacingMergeTree 去重引擎（陷阱最多）
-- ============================================================
-- 【原理】合并时，对 ORDER BY 相同的行只保留一行：
--   - 指定 version 列 → 保留 version 最大者
--   - 不指定 version  → 保留「最后写入」的（合并顺序不定，不可靠！）
-- 【场景】状态快照表：用户最新状态、商品最新价格、配置最新版本
-- 【坑1】去重只在后台合并时发生，查询默认读到全部重复行！
-- 【坑2】不指定 version 时「最新」语义不确定，必须带 version 列
-- 【坑3】FINAL 查询时临时合并，性能差，大数据量禁用

DROP TABLE IF EXISTS replacing_user_state ON CLUSTER 'treasurycluster' SYNC;

CREATE TABLE replacing_user_state ON CLUSTER 'treasurycluster' (
    user_id UInt64,
    state String,
    last_updated DateTime,
    version UInt64
) ENGINE = ReplicatedReplacingMergeTree(version)
PARTITION BY toYYYYMM(last_updated)
ORDER BY user_id;

-- 2.1 第一批写入
INSERT INTO replacing_user_state VALUES
    (1, 'online', '2024-01-01 10:00:00', 1),
    (2, 'offline', '2024-01-01 11:00:00', 1),
    (3, 'busy', '2024-01-01 12:00:00', 1);

-- 2.2 「更新」= INSERT 新版本（旧版本不会被删除，等合并时丢弃）
INSERT INTO replacing_user_state VALUES
    (1, 'busy', '2024-01-01 10:30:00', 2),
    (2, 'online', '2024-01-01 11:30:00', 2),
    (4, 'away', '2024-01-01 13:00:00', 1);

-- 2.3 默认查询：看到全部行（含重复）！去重还没发生
-- 【结果解读】user_id=1 有两行(online v1, busy v2)，因为两个 Part 还没合并
SELECT user_id, state, version FROM replacing_user_state ORDER BY user_id, version;

-- 2.4 FINAL 查询：强制查询时合并，去重生效
-- 【结果解读】每个 user_id 只剩 version 最大的一行
SELECT user_id, state, version FROM replacing_user_state FINAL ORDER BY user_id;

-- 2.5 强制后台合并（生产慎用，会锁合并影响写入）
OPTIMIZE TABLE replacing_user_state FINAL;

-- 2.6 合并后再查：已物理去重
SELECT user_id, state, version FROM replacing_user_state ORDER BY user_id;


-- ============================================================
-- 3. SummingMergeTree 求和引擎
-- ============================================================
-- 【原理】合并时对 ORDER BY 相同的行：数值列求和，非数值列取「任意值」(不可预测!)
-- 【场景】按维度预聚合的「加法指标」表：日 GMV、日 PV、日点击量
-- 【坑1】非数值列(如 category)合并后取任意值 → 所有维度列必须放进 ORDER BY！
-- 【坑2】查询仍要 sum() + GROUP BY，因为合并可能未完成
-- 【对比】只能求和；要 avg/uniq/分位数请用 AggregatingMergeTree

DROP TABLE IF EXISTS summing_daily_sales ON CLUSTER 'treasurycluster' SYNC;

CREATE TABLE summing_daily_sales ON CLUSTER 'treasurycluster' (
    date Date,
    product_id UInt32,
    country String,
    amount Decimal(10, 2),
    order_count UInt32
) ENGINE = ReplicatedSummingMergeTree
PARTITION BY toYYYYMM(date)
ORDER BY (date, product_id, country);

-- 3.1 同一 (date,product,country) 多次写入（模拟多次批次到达）
INSERT INTO summing_daily_sales VALUES
    ('2024-01-01', 101, 'US', 99.99, 1),
    ('2024-01-01', 101, 'US', 99.99, 1),
    ('2024-01-01', 101, 'US', 99.99, 1),
    ('2024-01-01', 102, 'US', 49.99, 1),
    ('2024-01-01', 102, 'UK', 59.99, 1),
    ('2024-01-02', 101, 'US', 199.99, 1),
    ('2024-01-02', 103, 'UK', 79.99, 1);

-- 3.2 默认查询：可能仍多行（合并未完成）
-- 【结果解读】(2024-01-01, 101, US) 可能看到 3 行未合并
SELECT * FROM summing_daily_sales ORDER BY date, product_id, country;

-- 3.3 正确查询：sum() + GROUP BY（合并完成与否结果都正确）
-- 【结果解读】(2024-01-01, 101, US) amount=299.97, order_count=3
SELECT
    date,
    product_id,
    sum(amount) AS total_amount,
    sum(order_count) AS total_orders
FROM summing_daily_sales
GROUP BY date, product_id
ORDER BY date, product_id;

-- 3.4 触发合并观察物理求和
OPTIMIZE TABLE summing_daily_sales FINAL;
SELECT * FROM summing_daily_sales ORDER BY date, product_id, country;


-- ============================================================
-- 4. AggregatingMergeTree 聚合引擎（最强大）
-- ============================================================
-- 【原理】合并时对 ORDER BY 相同的行，把 AggregateFunction 状态列做 merge
--   配合 *State 写入、*Merge 查询（详见 04-functions §3 聚合状态函数）
-- 【场景】任意聚合的预聚合表/物化视图：支持 sum/count/uniq/quantile/topK 全家族
-- 【对比】vs SummingMergeTree：
--   - Summing 只能求和；Aggregating 支持所有聚合
--   - Summing 已求和无法恢复分布；Aggregating 状态可继续 merge(日表→月表不丢精度)
--   - UV 去重、P99 监控只能用 Aggregating + uniqState/quantileState
-- 【坑】状态列不能直接 SELECT 看数值(是二进制)，必须 *Merge 还原

DROP TABLE IF EXISTS aggregating_user_metrics ON CLUSTER 'treasurycluster' SYNC;

CREATE TABLE aggregating_user_metrics ON CLUSTER 'treasurycluster' (
    user_id UInt64,
    event_date Date,
    -- 列类型是 AggregateFunction，不是普通数值！
    page_views AggregateFunction(count),
    distinct_events AggregateFunction(uniq, String),
    total_data_size AggregateFunction(sum, UInt64)
) ENGINE = ReplicatedAggregatingMergeTree
PARTITION BY toYYYYMM(event_date)
ORDER BY (user_id, event_date);

-- 4.1 用 INSERT SELECT 把明细聚合进状态表
-- 【关键】这里用 countState/uniqState/sumState 物化中间态
INSERT INTO aggregating_user_metrics
SELECT
    user_id,
    toDate(timestamp) AS event_date,
    countState() AS page_views,
    uniqState(event_type) AS distinct_events,
    sumState(length(event_data)) AS total_data_size
FROM mergetree_events
GROUP BY user_id, toDate(timestamp);

-- 4.2 查询预聚合表：用 *Merge 还原最终值
-- 【结果解读】与扫明细表完全一致，但只扫预聚合表(行数少很多)
SELECT
    user_id,
    event_date,
    countMerge(page_views) AS total_page_views,
    uniqMerge(distinct_events) AS distinct_event_types,
    sumMerge(total_data_size) AS total_data_size
FROM aggregating_user_metrics
GROUP BY user_id, event_date
ORDER BY user_id, event_date;

-- 4.3 二级聚合：日表 → 月表（状态可继续合并，不丢精度）
-- 【原理】这是 *State 的威力：月表对日表的状态再做 merge
-- 【对比】若用 SummingMergeTree 存 sum，月表只能 sum(日sum)，但 UV/分位数无法恢复
SELECT
    toStartOfMonth(event_date) AS month,
    countMerge(page_views) AS monthly_views,
    uniqMerge(distinct_events) AS monthly_distinct_events
FROM aggregating_user_metrics
GROUP BY month
ORDER BY month;


-- ============================================================
-- 5. CollapsingMergeTree 折叠引擎（增量更新）
-- ============================================================
-- 【原理】用 sign(+1/-1) 标记行：合并时对同 ORDER BY 的 +1/-1 成对抵消(不看值，只看符号配对)
--   实现「状态替换」：要改值就先插 sign=-1 镜像旧行，再插 sign=+1 新行
-- 【场景】流式增量计数器：库存、账户余额、积分变动
-- 【关键规则★】取消行(sign=-1)的值必须 = 被取消行(sign=+1)的值！
--   这样 sum(value*sign) 在合并前/后都一致：
--     合并前: old*(+1) + old*(-1) + new*(+1) = new
--     合并后: +1/-1 配对抵消，剩 new*(+1) = new
-- 【坑1】若取消行写成「差值」(如卖10写 value=10,sign=-1)，合并前后结果不一致！
--   错误写法 (101,10,-1) 会让合并前 sum=100-10+20=110，合并后只剩(101,20,+1)=20
-- 【坑2】查询必须 sum(value * sign) + GROUP BY，不能 SELECT *
-- 【坑3】并发乱序写入(sign=-1 先于 +1 到达)会折叠错误 → 用 VersionedCollapsingMergeTree
-- 【对比】vs ReplacingMergeTree：RMT 是覆盖(新值替旧值)，CMT 是状态镜像抵消

DROP TABLE IF EXISTS collapsing_inventory ON CLUSTER 'treasurycluster' SYNC;

CREATE TABLE collapsing_inventory ON CLUSTER 'treasurycluster' (
    product_id UInt64,
    quantity Int32,
    sign Int8,
    timestamp DateTime
) ENGINE = ReplicatedCollapsingMergeTree(sign)
PARTITION BY toYYYYMM(timestamp)
ORDER BY product_id;

-- 5.1 初始库存（sign=+1 表示当前状态）
INSERT INTO collapsing_inventory VALUES
    (101, 100, 1, '2024-01-01 10:00:00'),
    (102, 50, 1, '2024-01-01 10:00:00'),
    (103, 75, 1, '2024-01-01 10:00:00');

-- 5.2 状态更新：101 卖10(新库存90)，102 卖5(新库存45)
-- 【关键】先插 sign=-1 镜像旧值，再插 sign=+1 新值
INSERT INTO collapsing_inventory VALUES
    (101, 100, -1, '2024-01-01 11:00:00'),
    (101, 90, 1, '2024-01-01 11:00:00'),
    (102, 50, -1, '2024-01-01 11:00:00'),
    (102, 45, 1, '2024-01-01 11:00:00');

-- 5.3 再次更新：101 进货20(新库存110)，103 进货10(新库存85)
INSERT INTO collapsing_inventory VALUES
    (101, 90, -1, '2024-01-01 12:00:00'),
    (101, 110, 1, '2024-01-01 12:00:00'),
    (103, 75, -1, '2024-01-01 12:00:00'),
    (103, 85, 1, '2024-01-01 12:00:00');

-- 5.4 默认查询：看到未折叠的全部行
-- 【结果解读】product_id=101 有 5 行(100,+1)(100,-1)(90,+1)(90,-1)(110,+1)
SELECT * FROM collapsing_inventory ORDER BY product_id, timestamp;

-- 5.5 正确查询：sum(quantity * sign) 抵消计算
-- 【结果解读】101: 100-100+90-90+110=110; 102: 50-50+45=45; 103: 75-75+85=85
--   合并前/后结果一致(这是正确用法的标志)
SELECT
    product_id,
    sum(quantity * sign) AS current_inventory
FROM collapsing_inventory
GROUP BY product_id
ORDER BY product_id;

-- 5.6 触发合并后再次查询，验证结果一致
OPTIMIZE TABLE collapsing_inventory FINAL;
SELECT
    product_id,
    sum(quantity * sign) AS current_inventory_after_merge
FROM collapsing_inventory
GROUP BY product_id
ORDER BY product_id;


-- ============================================================
-- 6. VersionedCollapsingMergeTree 版本折叠（并发安全）
-- ============================================================
-- 【原理】同 CollapsingMergeTree，但合并时按 version 严格排序后再折叠
--   解决 CollapsingMergeTree 在并发乱序写入下的折叠错误
-- 【场景】高并发增量计数器：多写入端同时操作同一主键
-- 【对比】比 CollapsingMergeTree 多一个 version 列，写入略复杂但并发安全

DROP TABLE IF EXISTS versioned_collapsing_scores ON CLUSTER 'treasurycluster' SYNC;

CREATE TABLE versioned_collapsing_scores ON CLUSTER 'treasurycluster' (
    user_id UInt64,
    score_change Int32,
    sign Int8,
    version UInt64,
    timestamp DateTime
) ENGINE = ReplicatedVersionedCollapsingMergeTree(sign, version)
PARTITION BY toYYYYMM(timestamp)
ORDER BY user_id;

-- 6.1 初始分数
INSERT INTO versioned_collapsing_scores VALUES
    (1, 100, 1, 1, '2024-01-01 10:00:00'),
    (2, 150, 1, 1, '2024-01-01 10:00:00'),
    (3, 200, 1, 1, '2024-01-01 10:00:00');

-- 6.2 更新分数：先 sign=-1 删旧版本，再 sign=+1 插新版本
INSERT INTO versioned_collapsing_scores VALUES
    (1, -100, -1, 1, '2024-01-01 11:00:00'),
    (1, 120, 1, 2, '2024-01-01 11:00:00'),
    (2, -150, -1, 1, '2024-01-01 11:00:00'),
    (2, 160, 1, 2, '2024-01-01 11:00:00');

-- 6.3 查询最新分数
-- 【结果解读】user1: 120; user2: 160; user3: 200（version 旧的被抵消）
SELECT
    user_id,
    sum(score_change * sign) AS current_score
FROM versioned_collapsing_scores
GROUP BY user_id
ORDER BY user_id;


-- ============================================================
-- 7. GraphiteMergeTree（时序降采样，配置说明）
-- ============================================================
-- 【原理】专为 Graphite 监控数据设计：按 rollup 配置对老数据自动降精度聚合
--   例如 30 天前数据从 60s 粒度降到 300s 粒度，节省存储
-- 【场景】Graphite 监控指标存储
-- 【注意】需要在 config.xml 的 <graphite_rollup> 配置聚合规则，本集群未配置故仅说明
-- 配置示例（仅供参考，不在本集群执行）:
--   CREATE TABLE graphite.data (
--       Path String, Time UInt32, Value Float64, Version UInt32
--   ) ENGINE = GraphiteMergeTree('graphite_rollup')
--   PARTITION BY toYYYYMM(toDateTime(Time))
--   ORDER BY (Path, Time);


-- ============================================================
-- 8. 合并算法对比实验（同数据不同引擎）
-- ============================================================
-- 【原理】用相同数据建不同引擎表，观察合并后「同排序键行」的不同处理
-- 【对比】这是本章核心实验：直观展示各引擎合并算法差异

-- 8.1 准备对比数据：3 条同排序键 (k=1) 的行，数值列 v 分别 10/20/30
DROP TABLE IF EXISTS cmp_mt ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS cmp_replacing ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS cmp_summing ON CLUSTER 'treasurycluster' SYNC;

CREATE TABLE cmp_mt ON CLUSTER 'treasurycluster' (
    k UInt32, v UInt32, ver UInt32
) ENGINE = ReplicatedMergeTree() ORDER BY k;

CREATE TABLE cmp_replacing ON CLUSTER 'treasurycluster' (
    k UInt32, v UInt32, ver UInt32
) ENGINE = ReplicatedReplacingMergeTree(ver) ORDER BY k;

CREATE TABLE cmp_summing ON CLUSTER 'treasurycluster' (
    k UInt32, v UInt32, ver UInt32
) ENGINE = ReplicatedSummingMergeTree ORDER BY k;

-- 8.2 分两次 INSERT（产生 2 个 Part，触发后台合并去重/求和）
INSERT INTO cmp_mt VALUES (1, 10, 1), (1, 20, 2), (1, 30, 3);
INSERT INTO cmp_replacing VALUES (1, 10, 1), (1, 20, 2), (1, 30, 3);
INSERT INTO cmp_summing VALUES (1, 10, 1), (1, 20, 2), (1, 30, 3);

-- 8.3 强制合并，让各引擎算法生效
OPTIMIZE TABLE cmp_mt FINAL;
OPTIMIZE TABLE cmp_replacing FINAL;
OPTIMIZE TABLE cmp_summing FINAL;

-- 8.4 对比合并结果
-- 【结果解读】
--   MergeTree:           3 行全保留 (v=10,20,30) —— 不去重不聚合
--   ReplacingMergeTree:  1 行 (v=30, ver=3)       —— 保留 version 最大
--   SummingMergeTree:    1 行 (v=60)              —— 数值列求和 10+20+30
SELECT 'MergeTree' AS engine, k, v, ver FROM cmp_mt
UNION ALL
SELECT 'ReplacingMergeTree', k, v, ver FROM cmp_replacing
UNION ALL
SELECT 'SummingMergeTree', k, v, ver FROM cmp_summing
ORDER BY engine, k;


-- ============================================================
-- 9. ReplacingMergeTree 去重查询三种写法对比
-- ============================================================
-- 【原理】ReplacingMergeTree 去重查询有三种方式，性能与语义不同：
--   A. FINAL              —— 查询时临时合并，简单但性能差(单线程、阻塞)
--   B. GROUP BY + argMax  —— 业务层手动取最新，性能好(可并行)，推荐
--   C. OPTIMIZE FINAL     —— 物理合并后普通查，但影响写入，不能在线频繁用
-- 【场景】生产环境用 B(argMax)，测试/小数据用 A(FINAL)

DROP TABLE IF EXISTS dedup_demo ON CLUSTER 'treasurycluster' SYNC;

CREATE TABLE dedup_demo ON CLUSTER 'treasurycluster' (
    id UInt32,
    val String,
    ver UInt32
) ENGINE = ReplicatedReplacingMergeTree(ver) ORDER BY id;

INSERT INTO dedup_demo VALUES
    (1, 'old', 1), (2, 'old', 1), (3, 'old', 1),
    (1, 'new', 2), (2, 'new', 2), (4, 'new', 1);

-- 9.1 写法A: FINAL（简单但慢）
-- 【结果解读】每个 id 去重，保留 ver 最大
SELECT id, val, ver FROM dedup_demo FINAL ORDER BY id;

-- 9.2 写法B: argMax（推荐，可并行，性能好）
-- 【原理】argMax(val, ver) 返回使 ver 最大的那个 val
-- 【结果解读】与 FINAL 结果一致，但不阻塞合并、可并行
SELECT
    id,
    argMax(val, ver) AS val,
    max(ver) AS ver
FROM dedup_demo
GROUP BY id
ORDER BY id;

-- 9.3 写法C: 子查询去重（另一种手动写法）
SELECT t.id, t.val, t.ver
FROM dedup_demo t
INNER JOIN (
    SELECT id, max(ver) AS max_ver FROM dedup_demo GROUP BY id
) m ON t.id = m.id AND t.ver = m.max_ver
ORDER BY t.id;


-- ============================================================
-- 10. 清理（如需）
-- ============================================================
DROP TABLE IF EXISTS mergetree_events ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS replacing_user_state ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS summing_daily_sales ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS aggregating_user_metrics ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS collapsing_inventory ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS versioned_collapsing_scores ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS cmp_mt ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS cmp_replacing ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS cmp_summing ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS dedup_demo ON CLUSTER 'treasurycluster' SYNC;
