-- ================================================
-- 05_special_engines.sql
-- ClickHouse 特殊引擎示例
-- ================================================

-- ========================================
-- 1. Distributed（分布式表引擎）
-- ========================================

-- 创建本地表
CREATE TABLE IF NOT EXISTS engine_test.local_orders (
    order_id UInt64,
    user_id UInt64,
    product_id UInt32,
    amount Decimal(10, 2),
    order_date DateTime DEFAULT now()
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(order_date)
ORDER BY (user_id, order_id);

-- 创建分布式表
CREATE TABLE IF NOT EXISTS engine_test.distributed_orders AS local_orders
ENGINE = Distributed(treasurycluster, engine_test, local_orders, user_id);

-- 插入数据（通过分布式表）
INSERT INTO engine_test.distributed_orders (order_id, user_id, product_id, amount) VALUES
(1, 101, 1001, 99.99),
(2, 102, 1002, 49.99),
(3, 103, 1003, 199.99),
(4, 104, 1001, 99.99),
(5, 105, 1004, 149.99);

-- 查询分布式表
SELECT * FROM engine_test.distributed_orders ORDER BY order_id;

-- 查询本地表
SELECT * FROM engine_test.local_orders ORDER BY order_id;

-- 使用 Distributed 表进行跨节点查询
SELECT
    user_id,
    count() as order_count,
    sum(amount) as total_amount
FROM engine_test.distributed_orders
GROUP BY user_id
ORDER BY total_amount DESC;

-- ========================================
-- 2. MaterializedView（物化视图引擎）
-- ========================================

-- 创建源表
CREATE TABLE IF NOT EXISTS engine_test.source_events (
    event_id UInt64,
    user_id UInt64,
    event_type String,
    event_value Float64,
    timestamp DateTime
) ENGINE = MergeTree()
ORDER BY (user_id, timestamp);

-- 创建物化视图
CREATE MATERIALIZED VIEW IF NOT EXISTS engine_test.event_stats_mv
ENGINE = AggregatingMergeTree()
ORDER BY (user_id, toDate(timestamp))
AS SELECT
    user_id,
    toDate(timestamp) as event_date,
    countState() as event_count_state,
    sumState(event_value) as total_value_state
FROM engine_test.source_events
GROUP BY user_id, toDate(timestamp);

-- 插入数据到源表
INSERT INTO engine_test.source_events (event_id, user_id, event_type, event_value, timestamp) VALUES
(1, 1, 'click', 10.5, '2024-01-01 10:00:00'),
(2, 1, 'view', 5.0, '2024-01-01 10:05:00'),
(3, 2, 'click', 15.0, '2024-01-01 11:00:00'),
(4, 3, 'purchase', 99.99, '2024-01-01 12:00:00'),
(5, 1, 'click', 20.0, '2024-01-02 09:00:00');

-- 查询物化视图（预聚合数据）
SELECT
    user_id,
    event_date,
    countMerge(event_count_state) as event_count,
    sumMerge(total_value_state) as total_value
FROM engine_test.event_stats_mv
GROUP BY user_id, event_date
ORDER BY event_date, user_id;

-- ========================================
-- 3. View（普通视图引擎）
-- ========================================

-- 创建普通视图
CREATE VIEW IF NOT EXISTS engine_test.active_users AS
SELECT
    user_id,
    count() as event_count,
    max(timestamp) as last_event_time
FROM engine_test.source_events
GROUP BY user_id
HAVING last_event_time > now() - INTERVAL 1 DAY;

-- 查询视图
SELECT * FROM engine_test.active_users;

-- 创建带过滤的视图
CREATE VIEW IF NOT EXISTS engine_test.click_events AS
SELECT
    event_id,
    user_id,
    event_value,
    timestamp
FROM engine_test.source_events
WHERE event_type = 'click';

-- 查询视图
SELECT * FROM engine_test.click_events;

-- ========================================
-- 4. Dictionary（字典引擎）
-- ========================================

/*
注意：Dictionary 需要在配置文件中定义或使用 SQL 创建

创建字典:
CREATE DICTIONARY IF NOT EXISTS engine_test.user_dict (
    user_id UInt64,
    user_name String,
    email String
) PRIMARY KEY user_id
SOURCE(CLICKHOUSE(HOST 'localhost' PORT 9000 USER 'default' PASSWORD '' DB 'engine_test' TABLE 'users'))
LAYOUT(HASHED())
LIFETIME(MIN 300 MAX 3600);

使用字典:
SELECT
    e.user_id,
    e.event_value,
    dictGet('engine_test.user_dict', 'user_name', e.user_id) as user_name
FROM engine_test.source_events e
WHERE e.user_id IN (1, 2, 3);
*/

-- ========================================
-- 5. Buffer（缓冲表引擎）
-- ========================================

-- 创建目标表
CREATE TABLE IF NOT EXISTS engine_test.buffer_target (
    id UInt64,
    data String,
    timestamp DateTime
) ENGINE = MergeTree()
ORDER BY id;

-- 创建缓冲表
CREATE TABLE IF NOT EXISTS engine_test.buffer_table (
    id UInt64,
    data String,
    timestamp DateTime
) ENGINE = Buffer(engine_test, buffer_target, 16, 10, 100, 10000, 1000000, 10000000, 100000000);

-- 解释参数：
-- 16: 缓冲区数量
-- 10: 最小时间（秒）
-- 100: 最大时间（秒）
-- 10000: 最小行数
-- 1000000: 最大行数
-- 10000000: 最小字节数
-- 100000000: 最大字节数

-- 插入数据到缓冲表
INSERT INTO engine_test.buffer_table VALUES
(1, 'data 1', now()),
(2, 'data 2', now()),
(3, 'data 3', now());

-- 查询目标表（数据可能还在缓冲中）
SELECT * FROM engine_test.buffer_target;

-- 手动刷新缓冲
-- Buffer 表会自动刷新，无需手动操作

-- ========================================
-- 6. Merge（合并表引擎）
-- ========================================

-- 创建多个源表
CREATE TABLE IF NOT EXISTS engine_test.merge_src1 (
    id UInt64,
    data String,
    source String DEFAULT 'src1',
    created_at DateTime DEFAULT now()
) ENGINE = MergeTree()
ORDER BY id;

CREATE TABLE IF NOT EXISTS engine_test.merge_src2 (
    id UInt64,
    data String,
    source String DEFAULT 'src2',
    created_at DateTime DEFAULT now()
) ENGINE = MergeTree()
ORDER BY id;

-- 插入数据
INSERT INTO engine_test.merge_src1 (id, data) VALUES (1, 'data 1'), (2, 'data 2');
INSERT INTO engine_test.merge_src2 (id, data) VALUES (3, 'data 3'), (4, 'data 4');

-- 创建合并表
CREATE TABLE IF NOT EXISTS engine_test.merge_all AS
engine_test.merge_src1
ENGINE = Merge(engine_test, '^merge_src');

-- 查询合并表
SELECT * FROM engine_test.merge_all ORDER BY id;

-- ========================================
-- 7. Null（空表引擎）
-- ========================================

-- 创建 Null 表（写入的数据会被丢弃）
CREATE TABLE IF NOT EXISTS engine_test.null_sink (
    id UInt64,
    data String,
    timestamp DateTime
) ENGINE = Null();

-- 插入数据（数据不会被保存）
INSERT INTO engine_test.null_sink VALUES
(1, 'data 1', now()),
(2, 'data 2', now());

-- 查询表（结果为空）
SELECT count() FROM engine_test.null_sink;

-- 使用场景：数据清洗测试、性能测试

-- ========================================
-- 8. Set（集合引擎）
-- ========================================

-- 创建 Set 表
CREATE TABLE IF NOT EXISTS engine_test.user_set (
    user_id UInt64
) ENGINE = Set();

-- 插入数据
INSERT INTO engine_test.user_set VALUES (1), (2), (3), (4), (5);

-- 使用 Set 进行 IN 查询
SELECT
    e.event_id,
    e.user_id,
    e.event_type
FROM engine_test.source_events e
WHERE e.user_id IN engine_test.user_set;

-- ========================================
-- 9. Join（连接表引擎）
-- ========================================

-- 创建右表
CREATE TABLE IF NOT EXISTS engine_test.user_profiles (
    user_id UInt64,
    name String,
    email String
) ENGINE = MergeTree()
ORDER BY user_id;

-- 插入用户数据
INSERT INTO engine_test.user_profiles (user_id, name, email) VALUES
(1, 'Alice', 'alice@example.com'),
(2, 'Bob', 'bob@example.com'),
(3, 'Charlie', 'charlie@example.com');

-- 创建 Join 表
CREATE TABLE IF NOT EXISTS engine_test.user_join (
    user_id UInt64,
    name String,
    email String
) ENGINE = Join(ANY, LEFT, user_id);

-- 插入数据到 Join 表
INSERT INTO engine_test.user_join
SELECT * FROM engine_test.user_profiles;

-- 使用 Join 表进行连接查询
SELECT
    e.event_id,
    e.user_id,
    j.name as user_name,
    e.event_type
FROM engine_test.source_events e
LEFT JOIN engine_test.user_join j USING (user_id)
WHERE e.user_id IN (1, 2, 3);

-- ========================================
-- 10. 特殊引擎性能测试
-- ========================================

-- Distributed 表性能
SELECT
    user_id,
    count() as order_count,
    sum(amount) as total_amount
FROM engine_test.distributed_orders
GROUP BY user_id;

-- View 查询性能
SELECT * FROM engine_test.active_users;

-- MaterializedView 查询性能（应该更快）
SELECT
    user_id,
    event_date,
    countMerge(event_count_state) as event_count
FROM engine_test.event_stats_mv
WHERE user_id = 1
GROUP BY user_id, event_date;

-- ========================================
-- 11. 特殊引擎使用场景
-- ========================================

-- 场景 1：数据归档（Merge 引擎）
-- 创建按月分表的归档表
/*
CREATE TABLE IF NOT EXISTS engine_test.archive_202401 (...) ENGINE = MergeTree();
CREATE TABLE IF NOT EXISTS engine_test.archive_202402 (...) ENGINE = MergeTree();

-- 创建合并视图
CREATE TABLE IF NOT EXISTS engine_test.archive_all AS
engine_test.archive_*
ENGINE = Merge(engine_test, '^archive_');

-- 查询所有归档数据
SELECT * FROM engine_test.archive_all;
*/

-- 场景 2：实时统计（MaterializedView）
-- 见前面 MaterializedView 示例

-- 场景 3：分布式查询（Distributed）
-- 见前面 Distributed 示例

-- ========================================
-- 12. 清理测试表
-- ========================================
DROP TABLE IF EXISTS engine_test.local_orders;
DROP TABLE IF EXISTS engine_test.distributed_orders;
DROP TABLE IF EXISTS engine_test.source_events;
DROP TABLE IF EXISTS engine_test.event_stats_mv;
DROP TABLE IF EXISTS engine_test.active_users;
DROP TABLE IF EXISTS engine_test.click_events;
DROP TABLE IF EXISTS engine_test.buffer_target;
DROP TABLE IF EXISTS engine_test.buffer_table;
DROP TABLE IF EXISTS engine_test.merge_src1;
DROP TABLE IF EXISTS engine_test.merge_src2;
DROP TABLE IF EXISTS engine_test.merge_all;
DROP TABLE IF EXISTS engine_test.null_sink;
DROP TABLE IF EXISTS engine_test.user_set;
DROP TABLE IF EXISTS engine_test.user_profiles;
DROP TABLE IF EXISTS engine_test.user_join;

-- ========================================
-- 13. 特殊引擎最佳实践总结
-- ========================================
/*
特殊引擎最佳实践：

1. Distributed（分布式表）
   - 适用场景：集群部署、负载均衡
   - 优点：透明访问集群数据
   - 缺点：本身不存储数据
   - 最佳实践：
     * 合理选择分片键
     * 配置合适的副本
     * 监控查询性能

2. MaterializedView（物化视图）
   - 适用场景：预聚合、实时统计
   - 优点：查询性能高
   - 缺点：写入成本高
   - 最佳实践：
     * 选择合适的聚合函数
     * 合理设计 GROUP BY
     * 定期清理数据

3. View（普通视图）
   - 适用场景：数据抽象、简化查询
   - 优点：提高查询可读性
   - 缺点：无性能提升
   - 最佳实践：
     * 用于常用查询模式
     * 保持视图简单

4. Buffer（缓冲表）
   - 适用场景：高频小批量写入
   - 优点：提高写入性能
   - 缺点：数据延迟
   - 最佳实践：
     * 合理配置缓冲参数
     * 监控缓冲状态

5. Merge（合并表）
   - 适用场景：数据归档、多表统一查询
   - 优点：透明访问多个表
   - 缺点：性能可能较低
   - 最佳实践：
     * 统一表结构
     * 合理命名

6. Null（空表）
   - 适用场景：数据丢弃、性能测试
   - 优点：不占用存储
   - 缺点：数据无法查询
   - 使用场景：测试、调试

7. Set（集合）
   - 适用场景：IN 查询优化
   - 优点：查询性能高
   - 缺点：需要维护
   - 最佳实践：
     * 定期更新
     * 使用合适的数据量

8. Join（连接表）
   - 适用场景：频繁连接的右表
   - 优点：连接性能高
   - 缺点：需要维护
   - 最佳实践：
     * 适用于相对静态数据
     * 选择合适的连接策略

选择建议：
- 集群部署：Distributed
- 预聚合：MaterializedView
- 数据抽象：View
- 高频写入：Buffer
- 数据归档：Merge
- 测试调试：Null
- IN 查询：Set
- 频繁连接：Join
*/
