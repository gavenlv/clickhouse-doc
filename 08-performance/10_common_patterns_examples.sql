-- ================================================================================
-- ClickHouse 常见查询模式优化示例
-- ================================================================================
-- 
-- 集群: treasurycluster (2 副本)
-- 预计学习时间: 25 分钟
-- 
-- 本文件涵盖:
--   1. SELECT * 避免 - 明确指定列
--   2. 子查询转 JOIN - 优化关联查询
--   3. 函数条件优化 - 避免在过滤列上使用函数
--   4. ORDER BY 表达式 - 排序优化
--   5. GROUP BY 表达式 - 使用物化列
--   6. DISTINCT 优化 - 与 GROUP BY 对比
--   7. 分页优化 - 游标分页 vs OFFSET
--   8. COUNT DISTINCT - uniq 函数
--   9. IN 子查询 - 转 JOIN
--   10. LIKE 优化 - hasToken 与索引
--   11. OR 条件 - 转 IN 或 UNION
--   12. 大范围查询 - 物化视图
--   13. 多表 JOIN - GLOBAL JOIN
--   14. 重复计算 - 子查询复用
--   15. 相关子查询 - 转窗口函数
-- 
-- 常见反模式与优化:
-- 
--   ┌─────────────────────────────────────────────────────────────────────────┐
--   │                    ClickHouse 查询反模式                                │
--   └─────────────────────────────────────────────────────────────────────────┘
--   
--   反模式 1: SELECT *
--   ❌ SELECT * FROM events WHERE ...
--   ✅ SELECT event_id, user_id, event_type FROM events WHERE ...
--   
--   反模式 2: 函数包裹过滤列
--   ❌ WHERE toYYYYMM(event_time) = '202401'
--   ✅ WHERE event_time >= '2024-01-01' AND event_time < '2024-02-01'
--   
--   反模式 3: IN 子查询
--   ❌ WHERE user_id IN (SELECT user_id FROM active_users)
--   ✅ FROM events e INNER JOIN active_users a ON e.user_id = a.user_id
--   
--   反模式 4: COUNT(DISTINCT)
--   ❌ count(DISTINCT user_id)
--   ✅ uniqCombined(user_id)  -- 近似但快速
--   
--   反模式 5: OFFSET 分页
--   ❌ LIMIT 100 OFFSET 1000
--   ✅ WHERE id > last_id LIMIT 100  -- 游标分页
-- 
-- 查询优化策略:
-- 
--   ┌─────────────────────────────────────────────────────────────────────────┐
--   │                      查询优化决策树                                     │
--   └─────────────────────────────────────────────────────────────────────────┘
--   
--                    ┌─────────────────┐
--                    │ 查询是否高效?   │
--                    └────────┬────────┘
--                             │
--              ┌──────────────┴──────────────┐
--              │                             │
--              ▼                             ▼
--           是(保留)                     否(优化)
--                                          │
--                         ┌────────────────┴────────────────┐
--                         │                                 │
--                         ▼                                 ▼
--                   索引问题?                          内存问题?
--                         │                                 │
--                         ▼                                 ▼
--              ┌─────────────────┐              ┌─────────────────┐
--              │ 优化WHERE条件   │              │ 使用物化视图    │
--              │ 分区裁剪/索引   │              │ 减少中间结果    │
--              └─────────────────┘              └─────────────────┘
-- 
-- ================================================================================
-- §0. 准备演示数据
-- ================================================================================
-- 本文件依赖 5 张演示表（events / orders / active_users / users / products），
-- 为保证可独立重复运行，先统一重建并填充数据。
-- 注意: 先删物化视图再删源表（MV 依赖源表）
DROP TABLE IF EXISTS event_daily_stats_mv;
DROP TABLE IF EXISTS event_daily_stats_mv2;
DROP TABLE IF EXISTS event_ids_mv;
DROP TABLE IF EXISTS user_event_stats_mv;
DROP TABLE IF EXISTS order_user_product_mv;
DROP TABLE IF EXISTS events;
CREATE TABLE events
(
    event_id UInt64,
    user_id UInt32,
    event_type String,
    event_time DateTime,
    event_data String
)
ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (user_id, event_time);

INSERT INTO events
SELECT
    number + 1 AS event_id,
    (number % 1000) + 1 AS user_id,
    ['click', 'view', 'purchase'][number % 3 + 1] AS event_type,
    toDateTime('2024-01-10 00:00:00') + INTERVAL number MINUTE AS event_time,
    concat('{"keyword":', toString(number % 10), '}') AS event_data
FROM numbers(100000);

DROP TABLE IF EXISTS orders;
CREATE TABLE orders
(
    order_id UInt64,
    user_id UInt32,
    product_id UInt32,
    amount Float64,
    order_date Date
)
ENGINE = MergeTree()
ORDER BY order_id;

INSERT INTO orders
SELECT
    number + 1 AS order_id,
    (number % 1000) + 1 AS user_id,
    (number % 100) + 1 AS product_id,
    (number % 1000) + 0.5 AS amount,
    toDate('2024-01-10') + INTERVAL (number % 30) DAY AS order_date
FROM numbers(10000);

DROP TABLE IF EXISTS active_users;
CREATE TABLE active_users (user_id UInt32) ENGINE = MergeTree() ORDER BY user_id;
INSERT INTO active_users SELECT DISTINCT user_id FROM events LIMIT 500;

DROP TABLE IF EXISTS users;
CREATE TABLE users (user_id UInt32, username String) ENGINE = MergeTree() ORDER BY user_id;
INSERT INTO users SELECT number + 1, concat('user_', toString(number + 1)) FROM numbers(1000);

DROP TABLE IF EXISTS products;
CREATE TABLE products (product_id UInt32, product_name String) ENGINE = MergeTree() ORDER BY product_id;
INSERT INTO products SELECT number + 1, concat('product_', toString(number + 1)) FROM numbers(100);

-- ================================================================================

SELECT * FROM events
WHERE event_time >= now() - INTERVAL 7 DAY;

-- ✅ 推荐
SELECT 
    event_id,
    user_id,
    event_type,
    event_time
FROM events
WHERE event_time >= now() - INTERVAL 7 DAY;

-- ========================================
-- 解决方案
-- ========================================

-- ❌ 避免
SELECT * FROM orders
WHERE user_id IN (SELECT user_id FROM active_users);

-- ✅ 推荐
SELECT o.*
FROM orders o
INNER JOIN active_users u ON o.user_id = u.user_id;

-- ========================================
-- 解决方案
-- ========================================

-- ❌ 避免
SELECT * FROM events
WHERE toYYYYMM(event_time) = '202401';

-- ✅ 推荐
SELECT * FROM events
WHERE event_time >= '2024-01-01'
  AND event_time < '2024-02-01';

-- ========================================
-- 解决方案
-- ========================================

-- ❌ 避免
SELECT * FROM events
ORDER BY toDate(event_time);

-- ✅ 推荐
SELECT 
    event_id,
    user_id,
    event_type,
    event_time,
    toDate(event_time) as date
FROM events
ORDER BY event_time;

-- ========================================
-- 解决方案
-- ========================================

-- ❌ 避免
SELECT 
    toDate(event_time) as date,
    count() as event_count
FROM events
GROUP BY toDate(event_time);

-- ✅ 推荐
-- 方法 1: 使用物化列（events 已在 §0 创建，这里用 ALTER 添加物化列）
ALTER TABLE events
ADD COLUMN IF NOT EXISTS event_date Date MATERIALIZED toDate(event_time);

-- 查询
SELECT 
    event_date,
    count() as event_count
FROM events
GROUP BY event_date;

-- 方法 2: 使用物化视图
CREATE MATERIALIZED VIEW IF NOT EXISTS event_daily_stats_mv
ENGINE = AggregatingMergeTree()
ORDER BY (event_date)
AS SELECT
    toDate(event_time) as event_date,
    countState() as event_count
FROM events
GROUP BY event_date;

-- 查询
SELECT 
    event_date,
    countMerge(event_count) as event_count
FROM event_daily_stats_mv
GROUP BY event_date;

-- ========================================
-- 解决方案
-- ========================================

-- ❌ 避免
SELECT DISTINCT toDate(event_time) as date
FROM events;

-- ✅ 推荐
SELECT DISTINCT event_time
FROM events;

-- ========================================
-- 解决方案
-- ========================================

-- ❌ 避免
SELECT * FROM events
ORDER BY event_time
LIMIT 100 OFFSET 1000;

-- ✅ 推荐
-- 方法 1: 使用游标分页
SELECT * FROM events
WHERE event_time > '2024-01-20 10:00:00'  -- 上一次的最后一条记录的时间
ORDER BY event_time
LIMIT 100;

-- 方法 2: 使用物化视图
CREATE MATERIALIZED VIEW IF NOT EXISTS event_ids_mv
ENGINE = MergeTree()
ORDER BY (event_time, event_id)
AS SELECT 
    event_time,
    event_id
FROM events;

-- 分页查询
SELECT e.*
FROM events e
INNER JOIN event_ids_mv m ON e.event_id = m.event_id
WHERE m.event_time >= '2024-01-20 10:00:00'
ORDER BY e.event_time, e.event_id
LIMIT 100;

-- ========================================
-- 解决方案
-- ========================================

-- ❌ 避免
SELECT 
    user_id,
    count(DISTINCT event_id) as unique_events
FROM events
GROUP BY user_id;

-- ✅ 推荐
-- 方法 1: 使用 uniqCombined
SELECT 
    user_id,
    uniqCombined(event_id) as unique_events
FROM events
GROUP BY user_id;

-- 方法 2: 使用物化视图
CREATE MATERIALIZED VIEW IF NOT EXISTS user_event_stats_mv
ENGINE = AggregatingMergeTree()
ORDER BY (user_id)
AS SELECT
    user_id,
    uniqState(event_id) as unique_events_state
FROM events
GROUP BY user_id;

-- 查询
SELECT 
    user_id,
    uniqMerge(unique_events_state) as unique_events
FROM user_event_stats_mv
GROUP BY user_id;

-- ========================================
-- 解决方案
-- ========================================

-- ❌ 避免
SELECT * FROM events
WHERE user_id IN (SELECT user_id FROM active_users);

-- ✅ 推荐
-- 方法 1: 使用 JOIN
SELECT e.*
FROM events e
INNER JOIN active_users a ON e.user_id = a.user_id;

-- 方法 2: 使用子查询（限制返回结果）
SELECT * FROM events
WHERE user_id IN (
    SELECT user_id 
    FROM active_users 
    LIMIT 10000
);

-- ========================================
-- 解决方案
-- ========================================

-- ❌ 避免
SELECT * FROM events
WHERE event_data LIKE '%keyword%';

-- ✅ 推荐
-- 方法 1: 使用 hasToken
SELECT * FROM events
WHERE hasToken(event_data, 'keyword');

-- 方法 2: 使用 ngrambf_v1 索引
-- 说明: events 已在 §0 创建（含 event_data 列），直接在其上添加跳数索引；
--       CREATE TABLE ... 结构示意不再重复建表
ALTER TABLE events
ADD INDEX IF NOT EXISTS idx_event_data event_data
TYPE ngrambf_v1(4, 256, 3, 0)
GRANULARITY 1;

-- 重建索引（对已有数据生效，否则只对新写入数据生效；MATERIALIZE 不支持 IF NOT EXISTS）
ALTER TABLE events MATERIALIZE INDEX idx_event_data;

-- 查询
SELECT * FROM events
WHERE event_data LIKE '%keyword%';

-- ========================================
-- 解决方案
-- ========================================

-- ❌ 避免
SELECT * FROM events
WHERE user_id = 1
   OR user_id = 2
   OR user_id = 3;

-- ✅ 推荐
-- 方法 1: 使用 IN
SELECT * FROM events
WHERE user_id IN (1, 2, 3);

-- 方法 2: 使用 UNION
SELECT * FROM events WHERE user_id = 1
UNION ALL
SELECT * FROM events WHERE user_id = 2
UNION ALL
SELECT * FROM events WHERE user_id = 3;

-- ========================================
-- 解决方案
-- ========================================

-- ❌ 避免
SELECT * FROM events
WHERE event_time >= '2023-01-01'
  AND event_time < '2024-01-01';

-- ✅ 推荐
-- 查询最近数据
SELECT * FROM events
WHERE event_time >= now() - INTERVAL 30 DAY;

-- 或使用物化视图汇总
-- 说明: 前面已建同名 AggregatingMergeTree 版 event_daily_stats_mv，
--       这里改用 SummingMergeTree 演示另一种实现，命名 event_daily_stats_mv2
CREATE MATERIALIZED VIEW IF NOT EXISTS event_daily_stats_mv2
ENGINE = SummingMergeTree()
ORDER BY (date)
AS SELECT
    toDate(event_time) as date,
    count() as event_count
FROM events
GROUP BY date;

-- 查询物化视图
SELECT 
    date,
    sum(event_count) as total_events
FROM event_daily_stats_mv2
WHERE date >= toDate(now() - INTERVAL 365 DAY)
  AND date <= toDate(now())
GROUP BY date;

-- ========================================
-- 解决方案
-- ========================================

-- ❌ 避免
SELECT 
    o.order_id,
    o.amount,
    u.username,
    p.product_name
FROM orders o
LEFT JOIN users u ON o.user_id = u.user_id
LEFT JOIN products p ON o.product_id = p.product_id
WHERE o.order_date >= now() - INTERVAL 7 DAY;

-- ✅ 推荐
-- 方法 1: 使用 GLOBAL JOIN
SELECT 
    o.order_id,
    o.amount,
    u.username,
    p.product_name
FROM orders o
GLOBAL LEFT JOIN users u ON o.user_id = u.user_id
GLOBAL LEFT JOIN products p ON o.product_id = p.product_id
WHERE o.order_date >= now() - INTERVAL 7 DAY
SETTINGS distributed_product_mode = 'global';

-- 方法 2: 使用物化视图
CREATE MATERIALIZED VIEW IF NOT EXISTS order_user_product_mv
ENGINE = MergeTree()
ORDER BY (order_id)
AS SELECT
    o.order_id,
    o.amount,
    u.username,
    p.product_name
FROM orders o
LEFT JOIN users u ON o.user_id = u.user_id
LEFT JOIN products p ON o.product_id = p.product_id;

-- 查询物化视图
-- 增量处理示意：业务侧记录已处理的最大 order_id，下次从该值继续（伪代码占位符已改为实际值）
SELECT *
FROM order_user_product_mv
WHERE order_id >= 9000
LIMIT 1000;

-- ========================================
-- 解决方案
-- ========================================

-- ❌ 避免
SELECT 
    user_id,
    sum(amount) / count() as avg_amount,
    sum(amount) / count() * 2 as avg_amount_double
FROM orders
GROUP BY user_id;

-- ✅ 推荐
SELECT 
    user_id,
    avg_amount,
    avg_amount * 2 as avg_amount_double
FROM (
    SELECT 
        user_id,
        sum(amount) / count() as avg_amount
    FROM orders
    GROUP BY user_id
)
GROUP BY user_id, avg_amount;

-- ========================================
-- 解决方案
-- ========================================

-- ❌ 避免
SELECT 
    user_id,
    event_count,
    (
        SELECT avg(event_count)
        FROM (
            SELECT 
                user_id,
                count() as event_count
            FROM events
            WHERE event_time >= now() - INTERVAL 30 DAY
            GROUP BY user_id
        )
        WHERE user_id = outer.user_id
    ) as avg_event_count
FROM (
    SELECT 
        user_id,
        count() as event_count
    FROM events
    WHERE event_time >= now() - INTERVAL 30 DAY
    GROUP BY user_id
) outer;

-- ✅ 推荐
-- 方法 1: 使用 JOIN
SELECT 
    e1.user_id,
    e1.event_count,
    e2.avg_event_count
FROM (
    SELECT 
        user_id,
        count() as event_count
    FROM events
    WHERE event_time >= now() - INTERVAL 30 DAY
    GROUP BY user_id
) e1
INNER JOIN (
    SELECT 
        user_id,
        avg(event_count) as avg_event_count
    FROM (
        SELECT 
            user_id,
            count() as event_count
        FROM events
        WHERE event_time >= now() - INTERVAL 30 DAY
        GROUP BY user_id
    )
    GROUP BY user_id
) e2 ON e1.user_id = e2.user_id;

-- 方法 2: 使用窗口函数
SELECT 
    user_id,
    event_count,
    avg(event_count) OVER (PARTITION BY user_id) as avg_event_count
FROM (
    SELECT 
        user_id,
        count() as event_count
    FROM events
    WHERE event_time >= now() - INTERVAL 30 DAY
    GROUP BY user_id
);
