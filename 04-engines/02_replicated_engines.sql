-- ============================================================
-- 文件: 04-engines/02_replicated_engines.sql
-- 学习目标: 透彻理解 Replicated* 系列引擎的复制协调机制
-- 深度标准: 原理 + 场景 + 对比 + 可运行
-- 集群: treasurycluster (CH 25.12.1.649, 单分片 2 副本)
-- 前置: 无（自包含测试数据，按顺序执行）
-- ============================================================
--
-- 本文件章节:
--   1.  ReplicatedMergeTree 复制机制（Keeper 协调、Part 复制队列）
--   2.  ReplicatedReplacingMergeTree（去重 + 复制）
--   3.  ReplicatedSummingMergeTree（求和 + 复制）
--   4.  ReplicatedAggregatingMergeTree（聚合状态 + 复制）
--   5.  ReplicatedCollapsingMergeTree（折叠 + 复制，正确的 sign 镜像写法）
--   6.  ReplicatedVersionedCollapsingMergeTree（乱序安全 + 复制）
--   7.  复制表 vs 非复制表 对比（性能、存储、可用性）
--   8.  复制健康监控（system.replicas / replication_queue 关键字段）
--   9.  复制性能测试（10w 行写入 + 副本同步延迟观察）
--   10. 清理
-- ============================================================
--
-- 【核心概念回顾】
--   Replicated* = MergeTree 家族 + Keeper 协调的异步复制
--   ① 写入只到本地副本 → 入 Keeper 复制日志 → 其它副本拉取
--   ② merge 由 Leader 副本发起，其它副本执行相同 merge（保证 part 一致）
--   ③ 「异步」语义：写入返回 ≠ 所有副本已落盘。需要强一致用 insert_quorum
--   ④ Keeper 路径: /clickhouse/tables/{shard}/{table}/{replica_name}
--      —— 不同库的同名表若 ZK 路径相同会冲突（坑，详见 06_engine_selection_guide）
-- ============================================================

CREATE DATABASE IF NOT EXISTS engine_test ON CLUSTER 'treasurycluster';
USE engine_test;


-- ============================================================
-- 1. ReplicatedMergeTree 复制机制
-- ============================================================
-- 【原理】基础复制引擎：在 MergeTree 之上增加 Keeper 协调的 Part 复制
--   写入流程（异步复制）：
--     ① Client INSERT → 本地副本写 Part
--     ② 本地副本写 Keeper 复制日志 log/log-NNN
--     ③ 其它副本 Watch 到日志变化 → 拉取 Part → 写本地 → 标记完成
--   合并协调：
--     ① 副本选举 Leader（基于 ZK 临时节点，任一时刻只有 1 个 Leader）
--     ② Leader 决定哪些 Part 合并 → 入 Keeper 队列
--     ③ 所有副本执行相同合并 → 保证 part 命名一致
-- 【场景】生产环境所有表的默认选择；非复制 MergeTree 无高可用
-- 【对比】
--   MergeTree           — 单副本，磁盘损坏数据丢失，仅测试用
--   ReplicatedMergeTree — 多副本 + Keeper 协调，生产标配
-- 【坑1】异步复制：写入成功 ≠ 副本已同步。宕机可能丢未同步的 Part
--   → 强一致需求用 SETTINGS insert_quorum=2, select_sequential_consistency=1
-- 【坑2】必须有 Keeper 集群（3 节点起步，quorum=2）；Keeper 全挂则写入全部阻塞
-- 【坑3】默认 ZK 路径基于表名 → 不同库的同名表会冲突（详见 06 章）
-- 【关联】复制原理详见 ../02-principles/07_replication.md

DROP TABLE IF EXISTS replicated_events ON CLUSTER 'treasurycluster' SYNC;

-- 【写法】ReplicatedMergeTree() 的小括号可省略参数：使用 config.xml 的默认路径模板
--   <default_replica_path>/clickhouse/tables/{shard}/{database}/{table}</default_replica_path>
--   <default_replica_name>{replica}</default_replica_name>
--   {shard}/{replica} 来自 <remote_servers> 配置，按节点自动替换
CREATE TABLE replicated_events ON CLUSTER 'treasurycluster' (
    event_id UInt64,
    user_id UInt64,
    event_type String,
    event_data String,
    timestamp DateTime
) ENGINE = ReplicatedMergeTree()
PARTITION BY toYYYYMM(timestamp)
ORDER BY (user_id, event_type, timestamp);

INSERT INTO replicated_events (event_id, user_id, event_type, event_data, timestamp) VALUES
    (1, 1, 'click',  '{"page":"home"}',                  '2024-01-01 10:00:00'),
    (2, 1, 'view',   '{"page":"products"}',              '2024-01-01 10:05:00'),
    (3, 2, 'click',  '{"page":"products"}',              '2024-01-01 11:00:00'),
    (4, 3, 'purchase','{"product_id":101,"amount":99.99}','2024-01-01 12:00:00'),
    (5, 1, 'logout', '{"duration":3600}',                '2024-01-02 09:00:00');

-- 1.1 查询数据
SELECT event_id, user_id, event_type, timestamp
FROM replicated_events
ORDER BY event_id;

-- 1.2 查看复制状态：system.replicas 的关键字段
-- 【字段解读】
--   is_leader             — 是否为合并 Leader（Leader 负责发起 merge）
--   is_readonly           — true=只读（Keeper 会话失效或初始化未完成）
--   is_session_expired    — true=Keeper 会话过期（严重告警）
--   queue_size            — 复制队列待处理任务数（>100 告警）
--   absolute_delay       — 副本落后秒数（>60s 告警）
--   total_replicas/active_replicas — 总副本数/活跃副本数（active < total 告警）
SELECT
    database,
    table,
    replica_name,
    is_leader,
    can_become_leader,
    is_readonly,
    is_session_expired,
    zookeeper_path,
    queue_size,
    absolute_delay,
    total_replicas,
    active_replicas
FROM system.replicas
WHERE table = 'replicated_events'
ORDER BY replica_name;

-- 1.3 查看复制队列详情（system.replication_queue）
--   每条记录 = 一个待处理的复制任务（GET_PART、MERGE_PARTS、DROP_PART 等）
--   type 列含义：GET_PART(拉取Part)、MERGE_PARTS(执行合并)、DROP/TTL 等
SELECT
    database,
    table,
    type,
    replica_name,
    position,
    node_name,
    num_tries,
    last_exception,
    last_attempt_time
FROM system.replication_queue
WHERE table = 'replicated_events'
ORDER BY replica_name, position
LIMIT 20;

-- 1.4 查看 Keeper 中的复制元数据路径
--   （不同 CH 版本 system.zookeeper 可能需要开 allow_experimental_analyzer）
SELECT
    database, table,
    zookeeper_path,
    replica_name,
    columns_version
FROM system.replicas
WHERE table = 'replicated_events';


-- ============================================================
-- 2. ReplicatedReplacingMergeTree（去重 + 复制）
-- ============================================================
-- 【原理】Replicated + ReplacingMergeTree(version)
--   合并时同主键保留 version 最大；复制协调与基础 RMT 相同
-- 【场景】状态快照表：用户最新状态、商品最新价格（多副本保障可用性）
-- 【坑】去重只发生在 merge 时；查询需 FINAL 或 argMax(GROUP BY) 取最新
--   详见 01_mergetree_engines.sql §2、06_engine_selection_guide §6
-- 【对比】vs 普通 ReplacingMergeTree：复制版多副本一致性，单节点宕机不丢去重状态

DROP TABLE IF EXISTS replicated_user_state ON CLUSTER 'treasurycluster' SYNC;

CREATE TABLE replicated_user_state ON CLUSTER 'treasurycluster' (
    user_id UInt64,
    state String,
    last_updated DateTime,
    version UInt64
) ENGINE = ReplicatedReplacingMergeTree(version)
PARTITION BY toYYYYMM(last_updated)
ORDER BY user_id;

INSERT INTO replicated_user_state VALUES
    (1, 'online',  '2024-01-01 10:00:00', 1),
    (2, 'offline', '2024-01-01 11:00:00', 1),
    (3, 'busy',    '2024-01-01 12:00:00', 1);

-- 模拟「更新」= INSERT 新版本（旧版本待 merge 时丢弃）
INSERT INTO replicated_user_state VALUES
    (1, 'busy',   '2024-01-01 10:30:00', 2),
    (2, 'online', '2024-01-01 11:30:00', 2),
    (4, 'away',   '2024-01-01 13:00:00', 1);

-- 2.1 默认查询：可能仍看到重复行（merge 未完成）
SELECT user_id, state, version FROM replicated_user_state ORDER BY user_id, version;

-- 2.2 FINAL 查询：强制查询时去重
SELECT user_id, state, version FROM replicated_user_state FINAL ORDER BY user_id;

-- 2.3 推荐：argMax + GROUP BY（不阻塞、可并行、性能好）
-- 【坑】argMax(val, ver) 的别名不能是 ver（与列同名会触发 ILLEGAL_AGGREGATION）
SELECT
    user_id,
    argMax(state, version) AS state,
    max(version) AS max_ver
FROM replicated_user_state
GROUP BY user_id
ORDER BY user_id;


-- ============================================================
-- 3. ReplicatedSummingMergeTree（求和 + 复制）
-- ============================================================
-- 【原理】合并时同主键数值列求和；非数值列取首行值（不可预测，坑！）
-- 【场景】按维度预聚合的「加法指标」表：日 GMV、日 PV、订单数
-- 【坑1】非数值列必须放进 ORDER BY，否则合并后值不可控
-- 【坑2】查询仍要 sum() + GROUP BY（合并可能未完成）
-- 【对比】只能求和；要 avg/uniq/分位数请用 ReplicatedAggregatingMergeTree

DROP TABLE IF EXISTS replicated_daily_sales ON CLUSTER 'treasurycluster' SYNC;

CREATE TABLE replicated_daily_sales ON CLUSTER 'treasurycluster' (
    date Date,
    product_id UInt32,
    country String,
    amount Decimal(10, 2),
    order_count UInt32
) ENGINE = ReplicatedSummingMergeTree
PARTITION BY toYYYYMM(date)
ORDER BY (date, product_id, country);

INSERT INTO replicated_daily_sales VALUES
    ('2024-01-01', 101, 'US', 99.99, 1),
    ('2024-01-01', 101, 'US', 99.99, 1),
    ('2024-01-01', 102, 'US', 49.99, 1),
    ('2024-01-01', 102, 'UK', 59.99, 1),
    ('2024-01-02', 101, 'US', 199.99, 1);

-- 3.1 安全查询：sum() + GROUP BY（合并完成与否都正确）
SELECT
    date,
    product_id,
    sum(amount) AS total_amount,
    sum(order_count) AS total_orders
FROM replicated_daily_sales
GROUP BY date, product_id
ORDER BY date, product_id;

-- 3.2 触发合并观察物理求和
OPTIMIZE TABLE replicated_daily_sales FINAL;
SELECT * FROM replicated_daily_sales ORDER BY date, product_id, country;


-- ============================================================
-- 4. ReplicatedAggregatingMergeTree（聚合状态 + 复制）
-- ============================================================
-- 【原理】合并时同主键 AggregateFunction 列做状态 merge（不是简单求和）
--   写入用 *State，查询用 *Merge；状态可继续 merge（日→月→年不丢精度）
-- 【场景】任意聚合的预聚合表/物化视图：sum/count/uniq/quantile/topK 全家族
-- 【对比】vs SummingMergeTree：
--   - Summing 只能求和；Aggregating 支持所有聚合
--   - Summing 已求和无法恢复分布；Aggregating 状态可继续 merge
--   - UV 去重、P99 监控只能用 Aggregating + uniqState/quantileState
-- 【坑】状态列是二进制不能直接 SELECT，必须 *Merge 还原
-- 【关联】*State/*Merge 原理详见 05-functions/README.md §3

DROP TABLE IF EXISTS replicated_user_metrics ON CLUSTER 'treasurycluster' SYNC;

CREATE TABLE replicated_user_metrics ON CLUSTER 'treasurycluster' (
    user_id UInt64,
    event_date Date,
    -- 列类型必须是 AggregateFunction(...)，不是普通数值
    page_views AggregateFunction(count),
    distinct_pages AggregateFunction(uniq, String),
    total_data_size AggregateFunction(sum, UInt64)
) ENGINE = ReplicatedAggregatingMergeTree
PARTITION BY toYYYYMM(event_date)
ORDER BY (user_id, event_date);

-- 4.1 用 INSERT SELECT 把明细聚合进状态表
-- 【关键】这里用 countState/uniqState/sumState 物化中间态
INSERT INTO replicated_user_metrics
SELECT
    user_id,
    toDate(timestamp) AS event_date,
    countState() AS page_views,
    uniqState(event_type) AS distinct_pages,
    sumState(length(event_data)) AS total_data_size
FROM replicated_events
GROUP BY user_id, toDate(timestamp);

-- 4.2 查询预聚合表：用 *Merge 还原最终值
SELECT
    user_id,
    event_date,
    countMerge(page_views) AS total_page_views,
    uniqMerge(distinct_pages) AS distinct_event_types,
    sumMerge(total_data_size) AS total_data_size
FROM replicated_user_metrics
GROUP BY user_id, event_date
ORDER BY user_id, event_date;

-- 4.3 二级聚合：日表 → 月表（状态可继续合并，不丢精度）
--   若用 SummingMergeTree 存 sum，月表只能 sum(日sum)，但 UV/分位数无法恢复
SELECT
    toStartOfMonth(event_date) AS month,
    countMerge(page_views) AS monthly_views,
    uniqMerge(distinct_pages) AS monthly_distinct_events
FROM replicated_user_metrics
GROUP BY month
ORDER BY month;


-- ============================================================
-- 5. ReplicatedCollapsingMergeTree（折叠 + 复制）
-- ============================================================
-- 【原理】sign(+1/-1) 标记行：合并时同主键 +1/-1 配对抵消（不看值，只看符号配对）
--   实现「状态替换」：要改值就先插 sign=-1 镜像旧行，再插 sign=+1 新行
-- 【场景】流式增量计数器：库存、账户余额、积分变动
-- 【关键规则★】取消行(sign=-1)的值必须 = 被取消行(sign=+1)的值（镜像），不是差值！
--   正确: 先插 (id, old_val, +1)，更新时插 (id, old_val, -1) + (id, new_val, +1)
--   错误: 插 (id, delta, -1) —— 合并前后结果不一致！
--   错误: 插 (id, -old_val, -1) —— 取反值也不是镜像！
-- 【查询】必须 sum(col * sign) + GROUP BY，不能 SELECT *
-- 【坑1】若取消行写成「差值」(如卖10写 value=10,sign=-1)，合并前后结果不一致！
--   错误写法 (101,10,-1) 会让合并前 sum=100-10+20=110，合并后只剩(101,20,+1)=20
-- 【坑2】查询必须 sum(col * sign) + GROUP BY，不能 SELECT *
-- 【坑3】并发乱序写入(sign=-1 先于 +1 到达)会折叠错误 → 用 VersionedCollapsingMergeTree
-- 【对比】vs ReplacingMergeTree：RMT 是覆盖(新值替旧值)，CMT 是状态镜像抵消

DROP TABLE IF EXISTS replicated_inventory ON CLUSTER 'treasurycluster' SYNC;

CREATE TABLE replicated_inventory ON CLUSTER 'treasurycluster' (
    product_id UInt64,
    quantity Int32,
    sign Int8,
    timestamp DateTime
) ENGINE = ReplicatedCollapsingMergeTree(sign)
PARTITION BY toYYYYMM(timestamp)
ORDER BY product_id;

-- 5.1 初始库存（sign=+1 表示当前状态）
INSERT INTO replicated_inventory VALUES
    (101, 100, 1, '2024-01-01 10:00:00'),
    (102, 50,  1, '2024-01-01 10:00:00'),
    (103, 75,  1, '2024-01-01 10:00:00');

-- 5.2 状态更新：101 卖10(新库存90)，102 卖5(新库存45)
-- 【正确写法★】先插 sign=-1 镜像旧值，再插 sign=+1 新值
--   注意 sign=-1 行的值是「旧值」(100/50)，不是差值(10/5)，也不是取反(-100/-50)
INSERT INTO replicated_inventory VALUES
    (101, 100, -1, '2024-01-01 11:00:00'),
    (101, 90,   1, '2024-01-01 11:00:00'),
    (102, 50,  -1, '2024-01-01 11:00:00'),
    (102, 45,   1, '2024-01-01 11:00:00');

-- 5.3 再次更新：101 进货20(新库存110)，103 进货10(新库存85)
INSERT INTO replicated_inventory VALUES
    (101, 90,  -1, '2024-01-01 12:00:00'),
    (101, 110,  1, '2024-01-01 12:00:00'),
    (103, 75,  -1, '2024-01-01 12:00:00'),
    (103, 85,   1, '2024-01-01 12:00:00');

-- 5.4 正确查询：sum(quantity * sign) + GROUP BY
-- 【结果解读】101: 100-100+90-90+110=110; 102: 50-50+45=45; 103: 75-75+85=85
--   合并前/后结果都一致(这是正确用法的标志)
SELECT
    product_id,
    sum(quantity * sign) AS current_inventory
FROM replicated_inventory
GROUP BY product_id
ORDER BY product_id;

-- 5.5 触发合并后再次查询，验证结果一致
-- 【关键验证】如果 sign 镜像写法正确，合并前后 sum(col*sign) 必须相等
OPTIMIZE TABLE replicated_inventory FINAL;
SELECT
    product_id,
    sum(quantity * sign) AS current_inventory_after_merge
FROM replicated_inventory
GROUP BY product_id
ORDER BY product_id;


-- ============================================================
-- 6. ReplicatedVersionedCollapsingMergeTree（乱序安全 + 复制）
-- ============================================================
-- 【原理】同 CollapsingMergeTree，但合并时按 version 严格排序后再折叠
--   解决 CollapsingMergeTree 在并发乱序写入下的折叠错误
-- 【场景】高并发增量计数器：多写入端同时操作同一主键（Kafka 消费、CDC 补数据）
-- 【关键规则★】与 CollapsingMergeTree 相同：sign=-1 行的值必须 = 被取消行的值（镜像）
-- 【对比】比 CollapsingMergeTree 多一个 version 列，写入略复杂但并发安全

DROP TABLE IF EXISTS replicated_user_scores ON CLUSTER 'treasurycluster' SYNC;

CREATE TABLE replicated_user_scores ON CLUSTER 'treasurycluster' (
    user_id UInt64,
    score Int32,
    sign Int8,
    version UInt64,
    timestamp DateTime
) ENGINE = ReplicatedVersionedCollapsingMergeTree(sign, version)
PARTITION BY toYYYYMM(timestamp)
ORDER BY user_id;

-- 6.1 初始分数（sign=+1 表示当前状态）
INSERT INTO replicated_user_scores VALUES
    (1, 100, 1, 1, '2024-01-01 10:00:00'),
    (2, 150, 1, 1, '2024-01-01 10:00:00'),
    (3, 200, 1, 1, '2024-01-01 10:00:00');

-- 6.2 更新分数：先 sign=-1 镜像旧值，再 sign=+1 插新值
-- 【关键★】sign=-1 行的 score 必须 = 被取消行的 score（镜像），不是取反！
--   这样 sum(score*sign) 在合并前/后都一致：
--     合并前: 100*(+1) + 100*(-1) + 120*(+1) = 120
--     合并后: +1/-1 配对抵消，剩 120*(+1) = 120
--   若误写成 -100（取反），合并前会算成 100+100+120=320，与合并后 120 不一致！
INSERT INTO replicated_user_scores VALUES
    (1, 100, -1, 1, '2024-01-01 11:00:00'),
    (1, 120,  1, 2, '2024-01-01 11:00:00'),
    (2, 150, -1, 1, '2024-01-01 11:00:00'),
    (2, 160,  1, 2, '2024-01-01 11:00:00');

-- 6.3 查询最新分数
-- 【结果解读】user1: 120; user2: 160; user3: 200（version 旧的被抵消）
SELECT
    user_id,
    sum(score * sign) AS current_score
FROM replicated_user_scores
GROUP BY user_id
ORDER BY user_id;

-- 6.4 验证：触发合并后结果不变
OPTIMIZE TABLE replicated_user_scores FINAL;
SELECT
    user_id,
    sum(score * sign) AS current_score_after_merge
FROM replicated_user_scores
GROUP BY user_id
ORDER BY user_id;


-- ============================================================
-- 7. 复制表 vs 非复制表 对比
-- ============================================================
-- 【原理】同样数据存两份，对比写入性能、存储开销、可用性差异
-- 【场景】评估是否值得为高可用付出额外存储和写入开销
-- 【对比】
--   MergeTree           — 单副本，写入快、存储小，但无高可用
--   ReplicatedMergeTree — 多副本，写入略慢(需 Keeper 协调)、存储 N 倍，高可用
-- 【坑】本地 MergeTree 表不能 ON CLUSTER（它本就是单节点表）

DROP TABLE IF EXISTS mt_compare ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS rmt_compare ON CLUSTER 'treasurycluster' SYNC;

-- 单副本 MergeTree（仅当前节点，不用 ON CLUSTER）
CREATE TABLE engine_test.mt_compare (
    id UInt64,
    user_id UInt64,
    data String,
    timestamp DateTime
) ENGINE = MergeTree()
ORDER BY (user_id, timestamp);

-- 多副本 ReplicatedMergeTree（ON CLUSTER 在所有节点建表）
CREATE TABLE engine_test.rmt_compare ON CLUSTER 'treasurycluster' (
    id UInt64,
    user_id UInt64,
    data String,
    timestamp DateTime
) ENGINE = ReplicatedMergeTree()
ORDER BY (user_id, timestamp);

INSERT INTO engine_test.mt_compare SELECT
    number AS id,
    number % 100 AS user_id,
    repeat('data', 10) AS data,
    now() - INTERVAL rand() * 30 DAY AS timestamp
FROM numbers(10000);

INSERT INTO engine_test.rmt_compare SELECT
    number AS id,
    number % 100 AS user_id,
    repeat('data', 10) AS data,
    now() - INTERVAL rand() * 30 DAY AS timestamp
FROM numbers(10000);

-- 7.1 行数对比
SELECT 'MergeTree' AS engine, count() AS row_count FROM engine_test.mt_compare
UNION ALL
SELECT 'ReplicatedMergeTree', count() FROM engine_test.rmt_compare;

-- 7.2 存储对比
-- 【结果解读】rmt_compare 在两个副本各存一份，但 system.tables 的 total_bytes 只反映本节点
SELECT
    name,
    engine,
    total_rows,
    formatReadableSize(total_bytes) AS readable_size
FROM system.tables
WHERE table LIKE '%_compare'
  AND database = 'engine_test';

-- 7.3 Part 层面对比：观察 active part 数和大小
SELECT
    table,
    count() AS part_count,
    sum(rows) AS total_rows,
    formatReadableSize(sum(bytes_on_disk)) AS total_size
FROM system.parts
WHERE database = 'engine_test' AND table LIKE '%_compare' AND active = 1
GROUP BY table;


-- ============================================================
-- 8. 复制健康监控（system.replicas / replication_queue 关键字段）
-- ============================================================
-- 【原理】生产监控必须关注的指标与告警阈值
-- 【场景】日常巡检 + Prometheus/Grafana 告警规则配置
-- 【告警阈值表】
--   is_readonly = true            — Keeper 失联，副本进入只读，告警 P0
--   is_session_expired = true     — Keeper 会话过期，告警 P0
--   queue_size > 100              — 复制积压，告警 P1
--   absolute_delay > 60s          — 副本落后超 1 分钟，告警 P1
--   active_replicas < total_replicas — 有副本失联，告警 P1
--   leader_count != 1（每表）     — 无 Leader 或多 Leader，告警 P0

-- 8.1 全库复制健康一览
SELECT
    database,
    table,
    replica_name,
    is_leader,
    is_readonly,
    is_session_expired,
    queue_size,
    absolute_delay,
    total_replicas,
    active_replicas,
    active_replicas < total_replicas AS has_inactive_replica
FROM system.replicas
WHERE database = 'engine_test'
ORDER BY table, replica_name;

-- 8.2 按表汇总健康指标
SELECT
    table,
    sum(if(is_leader, 1, 0)) AS leader_count,
    sum(if(is_readonly, 1, 0)) AS readonly_count,
    sum(if(is_session_expired, 1, 0)) AS expired_count,
    avg(queue_size) AS avg_queue_size,
    max(absolute_delay) AS max_delay_seconds,
    max(total_replicas) AS total_replicas,
    min(active_replicas) AS min_active_replicas
FROM system.replicas
WHERE database = 'engine_test'
GROUP BY table
ORDER BY table;

-- 8.3 复制队列详情（堆积的任务）
--   健康状态下 queue_size 应 < 10；若持续增长说明副本拉取异常
SELECT
    database,
    table,
    type,
    count() AS task_count,
    max(num_tries) AS max_retries,
    anyIf(last_exception, last_exception != '') AS sample_exception
FROM system.replication_queue
WHERE database = 'engine_test'
GROUP BY database, table, type
ORDER BY table, type;


-- ============================================================
-- 9. 复制性能测试
-- ============================================================
-- 【原理】10w 行写入 + 查询性能 + 副本同步延迟观察
-- 【场景】评估复制开销是否可接受（一般 < 10% 额外开销）
-- 【对比】写入耗时 vs 查询耗时；副本同步延迟（absolute_delay）

DROP TABLE IF EXISTS rmt_performance ON CLUSTER 'treasurycluster' SYNC;

CREATE TABLE rmt_performance ON CLUSTER 'treasurycluster' (
    id UInt64,
    user_id UInt64,
    event_type String,
    event_value Float64,
    timestamp DateTime
) ENGINE = ReplicatedMergeTree()
PARTITION BY toYYYYMM(timestamp)
ORDER BY (user_id, timestamp);

-- 9.1 写入 10w 行（用 numbers 生成，模拟事件流）
INSERT INTO rmt_performance SELECT
    number AS id,
    number % 1000 AS user_id,
    concat('type_', toString(number % 10)) AS event_type,
    rand() * 1000 AS event_value,
    now() - INTERVAL rand() * 30 DAY AS timestamp
FROM numbers(100000);

-- 9.2 查询性能测试（命中 ORDER BY 前缀 user_id）
SELECT
    user_id,
    count() AS event_count,
    avg(event_value) AS avg_value
FROM rmt_performance
WHERE user_id IN (100, 200, 300)
GROUP BY user_id
ORDER BY user_id;

-- 9.3 监控复制延迟（写入后立即查看，可能仍有少量延迟）
SELECT
    table,
    replica_name,
    queue_size,
    absolute_delay,
    is_leader
FROM system.replicas
WHERE table = 'rmt_performance';

-- 9.4 Part 分布情况
SELECT
    partition,
    count() AS part_count,
    sum(rows) AS total_rows,
    formatReadableSize(sum(bytes_on_disk)) AS total_size,
    min(modification_time) AS oldest_part,
    max(modification_time) AS newest_part
FROM system.parts
WHERE database = 'engine_test' AND table = 'rmt_performance' AND active = 1
GROUP BY partition
ORDER BY partition;


-- ============================================================
-- 10. 维护操作（注释说明，不执行）
-- ============================================================
-- 【原理】生产中常用的复制表维护操作
-- 【注意】以下操作均会触发集群范围影响，需在维护窗口执行

-- 10.1 强制合并（触发复制）：生产慎用，会锁合并队列影响写入
-- OPTIMIZE TABLE engine_test.replicated_events FINAL;

-- 10.2 删除旧分区（需所有副本同意，自动同步）
-- ALTER TABLE engine_test.replicated_events DROP PARTITION '202401';

-- 10.3 副本修复（节点宕机后恢复）
--   方式1: 直接重启节点，副本会自动从队列补齐
--   方式2: 数据损坏 → DROP 表 → 重新 CREATE → 自动从其它副本拉取全量
--   方式3: 紧急 → ALTER TABLE ... FETCH PARTITION ... FROM 'replica_path'

-- 10.4 清理复制日志（Keeper 自动清理，无需手动）
--   Keeper 路径 /clickhouse/tables/{shard}/{table}/log/ 中的旧日志会被自动 GC


-- ============================================================
-- 11. 清理
-- ============================================================
DROP TABLE IF EXISTS replicated_events ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS replicated_user_state ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS replicated_daily_sales ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS replicated_user_metrics ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS replicated_inventory ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS replicated_user_scores ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS engine_test.mt_compare ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS engine_test.rmt_compare ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS rmt_performance ON CLUSTER 'treasurycluster' SYNC;


-- ============================================================
-- 12. Replicated* 系列最佳实践总结
-- ============================================================
-- 【生产标配】所有生产表必须用 Replicated* 系列，至少 2 副本 + 3 节点 Keeper
-- 【强一致场景】SETTINGS insert_quorum=2, select_sequential_consistency=1
--   —— 牺牲写入性能换取读写一致性（写入需 2 副本确认，查询只读已确认的）
-- 【监控告警】必监指标：is_readonly / is_session_expired / queue_size / absolute_delay
-- 【故障恢复】优先重启节点让其自动补齐；数据损坏用 DROP+CREATE 触发全量重拉
-- 【引擎选择】
--   通用明细：    ReplicatedMergeTree
--   状态去重：    ReplicatedReplacingMergeTree(version)
--   数值累加：    ReplicatedSummingMergeTree
--   复杂聚合：    ReplicatedAggregatingMergeTree（配合 *State/*Merge）
--   流式计数器：  ReplicatedCollapsingMergeTree(sign)（顺序写入）
--                 ReplicatedVersionedCollapsingMergeTree(sign, version)（乱序写入）
