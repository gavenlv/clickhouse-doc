-- ============================================================
-- 02 - 主键/排序键设计
-- 描述：ORDER BY 决定物理存储顺序和稀疏索引结构
-- 适用版本：ClickHouse 25.12+
-- ============================================================

-- 【原理】ORDER BY 与主键的关系
-- ============================================================
-- 在 ClickHouse 中：
-- 1. ORDER BY 决定了物理存储顺序（数据在磁盘上的排列）
-- 2. 主键（PRIMARY KEY）默认与 ORDER BY 相同
-- 3. 稀疏索引基于 ORDER BY 列，每 8192 行（granule）记录一个索引值
-- 4. 索引列的顺序决定了查询过滤的效果
-- 5. 有序数据的压缩率远高于无序数据
-- ============================================================

DROP DATABASE IF EXISTS modeling_test;
CREATE DATABASE modeling_test;
USE modeling_test;

-- ============================================================
-- 实验一：不同 ORDER BY 的存储大小对比
-- ============================================================

-- 【场景】相同数据，不同 ORDER BY 策略，对比存储大小

-- 方案 A：低基数列在前（错误的做法）
CREATE TABLE orders_orderby_status
(
    event_time    DateTime,
    user_id       UInt32,
    status        String,  -- 低基数：只有 3 种值
    amount        Float32,
    product_id    UInt32,
    category      String
)
ENGINE = MergeTree
ORDER BY (status, event_time, user_id);  -- 低基数在前

-- 方案 B：高基数列在前（正确的做法）
CREATE TABLE orders_orderby_user
(
    event_time    DateTime,
    user_id       UInt32,
    status        String,
    amount        Float32,
    product_id    UInt32,
    category      String
)
ENGINE = MergeTree
ORDER BY (user_id, event_time, status);  -- 高基数在前

-- 方案 C：无排序键（无序存储）
CREATE TABLE orders_orderby_none
(
    event_time    DateTime,
    user_id       UInt32,
    status        String,
    amount        Float32,
    product_id    UInt32,
    category      String
)
ENGINE = MergeTree
ORDER BY tuple();  -- 无排序

-- 插入相同的数据
INSERT INTO orders_orderby_status SELECT
    toDateTime('2024-01-01 00:00:00') + number % 31536000 AS event_time,
    number % 100000 AS user_id,
    ['Pending', 'Paid', 'Completed'][(number % 3) + 1] AS status,
    toFloat32(rand() % 1000) AS amount,
    number % 5000 AS product_id,
    ['Electronics', 'Clothing', 'Food', 'Books'][(number % 4) + 1] AS category
FROM system.numbers
LIMIT 1000000;

INSERT INTO orders_orderby_user SELECT
    toDateTime('2024-01-01 00:00:00') + number % 31536000 AS event_time,
    number % 100000 AS user_id,
    ['Pending', 'Paid', 'Completed'][(number % 3) + 1] AS status,
    toFloat32(rand() % 1000) AS amount,
    number % 5000 AS product_id,
    ['Electronics', 'Clothing', 'Food', 'Books'][(number % 4) + 1] AS category
FROM system.numbers
LIMIT 1000000;

INSERT INTO orders_orderby_none SELECT
    toDateTime('2024-01-01 00:00:00') + number % 31536000 AS event_time,
    number % 100000 AS user_id,
    ['Pending', 'Paid', 'Completed'][(number % 3) + 1] AS status,
    toFloat32(rand() % 1000) AS amount,
    number % 5000 AS product_id,
    ['Electronics', 'Clothing', 'Food', 'Books'][(number % 4) + 1] AS category
FROM system.numbers
LIMIT 1000000;

-- 【对比】存储大小对比
SELECT '【存储对比】不同 ORDER BY 的存储大小:';
SELECT table, formatReadableSize(sum(bytes_on_disk)) AS size
FROM system.parts
WHERE database = 'modeling_test' AND table LIKE 'orders_orderby%'
GROUP BY table
ORDER BY table;

-- ============================================================
-- 实验二：主键列顺序对查询性能的影响
-- ============================================================

-- 【场景】按 user_id 和 status 过滤，测试不同 ORDER BY 的性能

-- 查询 1：按 user_id 过滤（高基数）
SELECT '【查询性能】按 user_id 过滤:';
SELECT '-- ORDER BY (status, event_time, user_id) --';
SELECT count() FROM orders_orderby_status WHERE user_id = 50000;
SELECT '-- ORDER BY (user_id, event_time, status) --';
SELECT count() FROM orders_orderby_user WHERE user_id = 50000;

-- 查询 2：按 status 过滤（低基数）
SELECT '【查询性能】按 status 过滤:';
SELECT '-- ORDER BY (status, event_time, user_id) --';
SELECT count() FROM orders_orderby_status WHERE status = 'Paid';
SELECT '-- ORDER BY (user_id, event_time, status) --';
SELECT count() FROM orders_orderby_user WHERE status = 'Paid';

-- 查询 3：按 user_id + status 过滤
SELECT '【查询性能】按 user_id + status 过滤:';
SELECT '-- ORDER BY (status, event_time, user_id) --';
SELECT count() FROM orders_orderby_status WHERE user_id = 50000 AND status = 'Paid';
SELECT '-- ORDER BY (user_id, event_time, status) --';
SELECT count() FROM orders_orderby_user WHERE user_id = 50000 AND status = 'Paid';

-- 查询 4：按时间范围过滤（时间在 ORDER BY 中间位置）
SELECT '【查询性能】按时间范围过滤:';
SELECT '-- ORDER BY (status, event_time, user_id) --';
SELECT count() FROM orders_orderby_status
WHERE event_time >= '2024-06-01' AND event_time < '2024-07-01';
SELECT '-- ORDER BY (user_id, event_time, status) --';
SELECT count() FROM orders_orderby_user
WHERE event_time >= '2024-06-01' AND event_time < '2024-07-01';

-- 【坑】当 ORDER BY 第一列不在 WHERE 条件中时，索引无法有效使用
-- 例如 ORDER BY (user_id, event_time)，但 WHERE 只过滤 event_time
-- 此时需要扫描所有 granule，性能下降

-- ============================================================
-- 实验三：主键选择原则验证
-- ============================================================

-- 【场景】验证不同主键设计对查询性能的影响

-- 原则 1：高基数在前
-- 原则 2：时间在左但不一定第一
-- 原则 3：查询过滤条件优先

-- 模拟用户行为日志表
-- 方案 A：按 (user_id, event_time) 排序 — 适合按用户查询
CREATE TABLE user_events_by_user
(
    user_id     UInt32,
    event_time  DateTime,
    event_type  String,
    page_url    String,
    duration_ms UInt32
)
ENGINE = MergeTree
ORDER BY (user_id, event_time);

-- 方案 B：按 (event_time, user_id) 排序 — 适合按时间范围查询
CREATE TABLE user_events_by_time
(
    user_id     UInt32,
    event_time  DateTime,
    event_type  String,
    page_url    String,
    duration_ms UInt32
)
ENGINE = MergeTree
ORDER BY (event_time, user_id);

-- 插入数据
INSERT INTO user_events_by_user SELECT
    number % 50000 AS user_id,
    toDateTime('2024-01-01 00:00:00') + number % 31536000 AS event_time,
    ['click', 'view', 'purchase', 'logout'][(number % 4) + 1] AS event_type,
    concat('/page_', toString(number % 100)) AS page_url,
    rand() % 30000 AS duration_ms
FROM system.numbers
LIMIT 500000;

INSERT INTO user_events_by_time SELECT
    number % 50000 AS user_id,
    toDateTime('2024-01-01 00:00:00') + number % 31536000 AS event_time,
    ['click', 'view', 'purchase', 'logout'][(number % 4) + 1] AS event_type,
    concat('/page_', toString(number % 100)) AS page_url,
    rand() % 30000 AS duration_ms
FROM system.numbers
LIMIT 500000;

-- 测试查询 1：按用户查询
SELECT '【按用户查询】ORDER BY (user_id, event_time):';
SELECT count() FROM user_events_by_user WHERE user_id = 10000;

SELECT '【按用户查询】ORDER BY (event_time, user_id):';
SELECT count() FROM user_events_by_time WHERE user_id = 10000;

-- 测试查询 2：按时间范围查询
SELECT '【按时间查询】ORDER BY (user_id, event_time):';
SELECT count() FROM user_events_by_user
WHERE event_time >= '2024-06-01' AND event_time < '2024-07-01';

SELECT '【按时间查询】ORDER BY (event_time, user_id):';
SELECT count() FROM user_events_by_time
WHERE event_time >= '2024-06-01' AND event_time < '2024-07-01';

-- 测试查询 3：按用户 + 时间
SELECT '【按用户+时间查询】ORDER BY (user_id, event_time):';
SELECT count() FROM user_events_by_user
WHERE user_id = 10000 AND event_time >= '2024-06-01' AND event_time < '2024-07-01';

SELECT '【按用户+时间查询】ORDER BY (event_time, user_id):';
SELECT count() FROM user_events_by_time
WHERE user_id = 10000 AND event_time >= '2024-06-01' AND event_time < '2024-07-01';

-- ============================================================
-- 实验四：跳数索引与主键的配合
-- ============================================================

-- 【场景】主键无法覆盖所有查询条件时，使用跳数索引加速

-- 【原理】跳数索引是在主键索引基础上的辅助索引
-- 主键：精确定位 granule
-- 跳数索引：在主键无法过滤时，跳过不相关的 granule

CREATE TABLE events_with_skip_index
(
    event_time    DateTime,
    user_id       UInt32,
    event_type    String,
    status_code   UInt16,
    response_time UInt32,
    url           String,
    user_agent    String,
    -- 主键覆盖 user_id 和 event_time 的过滤
    -- 对 status_code 和 response_time 建跳数索引
    -- 【坑】跳数索引必须定义在列定义括号内（ENGINE 之前），
    --       set 类型已在 CH 24.x 移除（报语法错误 62），改用 bloom_filter
    INDEX idx_status_code status_code TYPE bloom_filter(0.01) GRANULARITY 4,
    INDEX idx_response_time response_time TYPE minmax GRANULARITY 3,
    INDEX idx_event_type event_type TYPE bloom_filter(0.01) GRANULARITY 3
)
ENGINE = MergeTree
ORDER BY (user_id, event_time);

-- 插入数据
INSERT INTO events_with_skip_index SELECT
    toDateTime('2024-01-01 00:00:00') + number % 31536000 AS event_time,
    number % 100000 AS user_id,
    ['click', 'view', 'api_call', 'error'][(number % 4) + 1] AS event_type,
    toUInt16(200 + (number % 100)) AS status_code,
    rand() % 5000 AS response_time,
    concat('/api/v', toString(number % 3), '/', toString(number % 100)) AS url,
    ['Mozilla/5.0', 'Chrome/120', 'Safari/17'][(number % 3) + 1] AS user_agent
FROM system.numbers
LIMIT 1000000;

-- 查询 1：主键覆盖（user_id + 时间范围）
SELECT '【主键覆盖】按 user_id 和时间查询:';
SELECT count() FROM events_with_skip_index
WHERE user_id = 50000
  AND event_time >= '2024-06-01' AND event_time < '2024-07-01';

-- 查询 2：主键部分覆盖 + 跳数索引
SELECT '【跳数索引】按 status_code 查询:';
SELECT count() FROM events_with_skip_index
WHERE status_code = 500;

-- 查询 3：主键 + 跳数索引联合
SELECT '【联合索引】按 user_id + response_time 查询:';
SELECT count() FROM events_with_skip_index
WHERE user_id = 50000 AND response_time > 4000;

-- 查询 4：跳数索引（bloom_filter 类型）
SELECT '【Bloom Filter】按 event_type 查询:';
SELECT count() FROM events_with_skip_index
WHERE event_type = 'error';

-- 【坑】跳数索引不是万能的
-- 1. 跳数索引增加了写入开销
-- 2. 跳数索引占用额外存储空间
-- 3. 如需跳数索引生效，插入数据后需要 OPTIMIZE 强制合并
-- 4. 跳数索引对低基数字段效果有限

-- 查看跳数索引大小
SELECT '【跳数索引存储】查看索引大小:';
-- 【坑】system.data_skipping_indices 的列名是 name（不是 index_name）
SELECT table, name AS index_name, formatReadableSize(sum(data_compressed_bytes)) AS size
FROM system.data_skipping_indices
WHERE database = 'modeling_test'
GROUP BY table, name;

-- ============================================================
-- 实验五：复合主键的列顺序对查询的影响
-- ============================================================

-- 【场景】验证 (a, b, c) 与 (a, c, b) 的区别

CREATE TABLE pk_test_abc
(
    a UInt32,  -- 高基数
    b UInt32,  -- 中基数
    c UInt32,  -- 低基数
    data String
)
ENGINE = MergeTree
ORDER BY (a, b, c);

CREATE TABLE pk_test_acb
(
    a UInt32,
    b UInt32,
    c UInt32,
    data String
)
ENGINE = MergeTree
ORDER BY (a, c, b);

-- 插入数据
INSERT INTO pk_test_abc SELECT
    number % 100000 AS a,
    number % 1000 AS b,
    number % 10 AS c,
    toString(rand()) AS data
FROM system.numbers
LIMIT 500000;

INSERT INTO pk_test_acb SELECT
    number % 100000 AS a,
    number % 1000 AS b,
    number % 10 AS c,
    toString(rand()) AS data
FROM system.numbers
LIMIT 500000;

-- 查询 A：按 (a, b) 过滤
SELECT '【查询 (a, b)】ORDER BY (a, b, c):';
SELECT count() FROM pk_test_abc WHERE a = 50000 AND b = 500;

SELECT '【查询 (a, b)】ORDER BY (a, c, b):';
SELECT count() FROM pk_test_acb WHERE a = 50000 AND b = 500;

-- 查询 B：按 (a, c) 过滤
SELECT '【查询 (a, c)】ORDER BY (a, b, c):';
SELECT count() FROM pk_test_abc WHERE a = 50000 AND c = 5;

SELECT '【查询 (a, c)】ORDER BY (a, c, b):';
SELECT count() FROM pk_test_acb WHERE a = 50000 AND c = 5;

-- 查询 C：按 (a, b, c) 过滤
SELECT '【查询 (a, b, c)】ORDER BY (a, b, c):';
SELECT count() FROM pk_test_abc WHERE a = 50000 AND b = 500 AND c = 5;

SELECT '【查询 (a, b, c)】ORDER BY (a, c, b):';
SELECT count() FROM pk_test_acb WHERE a = 50000 AND b = 500 AND c = 5;

-- ============================================================
-- 结论：主键/排序键设计原则
-- ============================================================
-- 1. 高基数在前：第一列选择去重值最多的列
-- 2. 查询过滤条件优先：最常出现在 WHERE 中的列排在前面
-- 3. 时间在左但不一定第一：时间列放在 ORDER BY 中间位置（第二或第三）
-- 4. 主键列数不宜过多：3-5 列最佳，过多会增大索引存储
-- 5. 主键列的顺序影响查询性能：将最常过滤的列放在最左边
-- 6. 跳数索引是补充：对主键无法覆盖的列建跳数索引
-- 7. 避免在低基数列上建主键：低基数列在前会导致索引效率低下

-- 【最佳实践示例】
-- 电商订单表
CREATE TABLE best_practice_orders
(
    order_id      UInt64,
    user_id       UInt32,       -- 高基数，查询频率高 → 第 1 位
    order_time    DateTime,     -- 中基数，时间范围查询 → 第 2 位
    order_status  LowCardinality(String),  -- 低基数，不放在主键
    product_id    UInt32,       -- 高基数，查询频率一般 → 第 3 位
    amount        Decimal(10, 2),
    -- 其他字段...
    INDEX idx_status order_status TYPE bloom_filter(0.01) GRANULARITY 4
)
ENGINE = MergeTree
ORDER BY (user_id, order_time, product_id)
PARTITION BY toYYYYMM(order_time);

SELECT '【最佳实践】推荐的主键设计完成';
SELECT 'DONE - 主键/排序键设计实验完成';

DROP DATABASE IF EXISTS modeling_test;