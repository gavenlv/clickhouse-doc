-- ================================================
-- 10_common_patterns_examples.sql
-- 从 10_common_patterns.md 提取的 SQL 示例
-- 提取时间: 2026-01-23 14:40:17
-- ================================================


-- ========================================
-- 解决方案
-- ========================================

-- ❌ 避免
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
-- 方法 1: 使用物化列
CREATE TABLE events (
    event_id UInt64,
    user_id UInt32,
    event_time DateTime,
    event_date Date MATERIALIZED toDate(event_time)
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (user_id, event_time);

-- 查询
SELECT 
    event_date,
    count() as event_count
FROM events
GROUP BY event_date;

-- 方法 2: 使用物化视图
CREATE MATERIALIZED VIEW event_daily_stats_mv
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
    sumMerge(event_count) as event_count
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
CREATE MATERIALIZED VIEW event_ids_mv
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
CREATE MATERIALIZED VIEW user_event_stats_mv
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
CREATE TABLE events (
    event_id UInt64,
    user_id UInt32,
    event_data String,
    event_time DateTime
) ENGINE = MergeTree()
ORDER BY (user_id, event_time);

ALTER TABLE events
ADD INDEX idx_event_data event_data
TYPE ngrambf_v1(4, 256, 3, 0.01)
GRANULARITY 1;

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
CREATE MATERIALIZED VIEW event_daily_stats_mv
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
FROM event_daily_stats_mv
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
CREATE MATERIALIZED VIEW order_user_product_mv
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
SELECT *
FROM order_user_product_mv
WHERE order_id >= last_processed_order_id
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
