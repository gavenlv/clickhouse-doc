-- ============================================================
-- 07 - 实时建模
-- 描述：实时数据流建模的挑战与优化策略
-- 适用版本：ClickHouse 25.12+
-- ============================================================

-- 【原理】实时数据流建模的挑战
-- ============================================================
-- 1. 实时写入与查询冲突：高频写入影响查询性能
-- 2. 数据一致性：实时数据可能有延迟或乱序
-- 3. 去重问题：实时数据可能重复
-- 4. 聚合延迟：预聚合需要平衡实时性和准确性
-- 5. Parts 爆炸：小批量写入导致大量小 parts
-- 6. 内存压力：实时聚合需要大量内存
-- ============================================================

DROP DATABASE IF EXISTS modeling_test;
CREATE DATABASE modeling_test;
USE modeling_test;

-- ============================================================
-- 实验一：实时写入优化
-- ============================================================

-- 【场景】实时日志系统，每秒写入 1000+ 条

-- 【原理】实时写入优化策略
-- 1. 异步 INSERT：使用 async INSERT 模式
-- 2. 批量写入：合并小批次为大批量
-- 3. 禁用 WAL：对于可容忍丢失的数据
-- 4. 优化 parts 合并：设置合适的合并策略
-- 5. 使用 Buffer 引擎做缓冲

-- 方案 A：直接写入（不推荐）
CREATE TABLE realtime_logs_direct
(
    event_time  DateTime,
    level       LowCardinality(String),
    message     String,
    service     LowCardinality(String),
    host        LowCardinality(String),
    duration_ms UInt32
)
ENGINE = MergeTree
ORDER BY (event_time, service)
PARTITION BY toDate(event_time)
TTL toDate(event_time) + INTERVAL 7 DAY DELETE;

-- 方案 B：使用 Buffer 引擎缓冲写入（推荐）
CREATE TABLE realtime_logs_buffer
(
    event_time  DateTime,
    level       LowCardinality(String),
    message     String,
    service     LowCardinality(String),
    host        LowCardinality(String),
    duration_ms UInt32
)
ENGINE = Buffer('modeling_test', 'realtime_logs_target',  -- 目标表
    16,          -- 缓冲区行数下限
    3,           -- 缓冲区时间下限（秒）
    100,         -- 缓冲区行数上限
    60,          -- 缓冲区时间上限（秒）
    1048576,     -- 缓冲区最大字节数
    2097152      -- 缓冲区刷新前的最大字节数
);

-- 目标表（实际存储数据）
CREATE TABLE realtime_logs_target
(
    event_time  DateTime,
    level       LowCardinality(String),
    message     String,
    service     LowCardinality(String),
    host        LowCardinality(String),
    duration_ms UInt32
)
ENGINE = MergeTree
ORDER BY (event_time, service)
PARTITION BY toDate(event_time)
TTL toDate(event_time) + INTERVAL 7 DAY DELETE;

-- 插入测试数据（模拟实时写入）
INSERT INTO realtime_logs_buffer SELECT
    now() - number % 3600 AS event_time,
    ['INFO', 'WARN', 'ERROR', 'DEBUG'][(number % 4) + 1] AS level,
    concat('log message ', toString(number)) AS message,
    ['api-gateway', 'user-service', 'order-service', 'payment-service'][(number % 4) + 1] AS service,
    ['host-1', 'host-2', 'host-3'][(number % 3) + 1] AS host,
    rand() % 5000 AS duration_ms
FROM system.numbers
LIMIT 10000;

-- 方案 C：使用异步 INSERT（客户端设置 async_insert = 1）
-- 在客户端连接时设置：
-- SETTINGS async_insert = 1, wait_for_async_insert = 0

-- 查看 Buffer 表状态
SELECT '【Buffer 表】查看缓冲状态:';
SELECT
    table,
    formatReadableSize(bytes_on_disk) AS size,
    rows
FROM system.parts
WHERE database = 'modeling_test' AND table = 'realtime_logs_target' AND active = 1;

-- 【坑】Buffer 表的注意事项
-- 1. Buffer 表的数据不是实时可见的（有延迟）
-- 2. Buffer 表重启后数据会丢失
-- 3. Buffer 表不能用于 ALTER TABLE 操作
-- 4. 查询 Buffer 表时，会同时查询缓冲区和目标表

-- ============================================================
-- 实验二：实时聚合（AggregatingMergeTree + 物化视图）
-- ============================================================

-- 【场景】实时统计每分钟的 API 请求量、延迟、错误率

-- 【原理】AggregatingMergeTree + 物化视图实现实时聚合
-- 1. 原始数据写入 MergeTree 表
-- 2. 物化视图实时聚合到 AggregatingMergeTree
-- 3. 查询时使用 *Merge 函数获取最终结果

-- 原始数据表
CREATE TABLE api_requests
(
    request_id    UInt64,
    api_name      LowCardinality(String),
    user_id       UInt32,
    response_time UInt32,        -- 毫秒
    status_code   UInt16,
    request_time  DateTime,
    bytes_sent    UInt32,
    method        LowCardinality(String)
)
ENGINE = MergeTree
ORDER BY (request_time, api_name)
PARTITION BY toDate(request_time)
TTL toDate(request_time) + INTERVAL 30 DAY DELETE;

-- 写入实时数据（模拟 10 万条 API 请求）
INSERT INTO api_requests SELECT
    number AS request_id,
    ['/api/orders', '/api/users', '/api/products', '/api/payments', '/api/auth'][(number % 5) + 1] AS api_name,
    number % 10000 AS user_id,
    rand() % 2000 AS response_time,
    toUInt16(if(rand() % 100 < 5, 500 + (rand() % 100), 200 + (rand() % 100))) AS status_code,
    now() - (number % 3600) AS request_time,
    rand() % 10000 AS bytes_sent,
    ['GET', 'POST', 'PUT', 'DELETE'][(number % 4) + 1] AS method
FROM system.numbers
LIMIT 100000;

-- 实时聚合 MV：每分钟统计
CREATE MATERIALIZED VIEW mv_realtime_api_stats
ENGINE = AggregatingMergeTree
ORDER BY (api_name, window_minute)
PARTITION BY toDate(window_minute)
AS SELECT
    api_name,
    toStartOfMinute(request_time) AS window_minute,
    countState() AS request_count,
    avgState(response_time) AS avg_response_time,
    maxState(response_time) AS max_response_time,
    quantileState(0.95)(response_time) AS p95_response_time,
    quantileState(0.99)(response_time) AS p99_response_time,
    countIfState(status_code >= 500) AS error_count,
    countIfState(status_code >= 400 AND status_code < 500) AS client_error_count,
    sumState(bytes_sent) AS total_bytes,
    uniqState(user_id) AS unique_users
FROM api_requests
GROUP BY api_name, toStartOfMinute(request_time);

-- 查询实时聚合结果
SELECT '【实时聚合】API 实时统计:';
SELECT
    api_name,
    window_minute,
    countMerge(request_count) AS requests,
    round(avgMerge(avg_response_time), 2) AS avg_ms,
    maxMerge(max_response_time) AS max_ms,
    round(quantileMerge(0.95)(p95_response_time), 2) AS p95_ms,
    round(quantileMerge(0.99)(p99_response_time), 2) AS p99_ms,
    countMerge(error_count) AS errors,
    round(countMerge(error_count) * 100.0 / countMerge(request_count), 2) AS error_rate_pct,
    formatReadableSize(sumMerge(total_bytes)) AS traffic,
    uniqMerge(unique_users) AS users
FROM mv_realtime_api_stats
WHERE window_minute >= now() - INTERVAL 10 MINUTE
GROUP BY api_name, window_minute
ORDER BY window_minute DESC, requests DESC;

-- ============================================================
-- 实验三：实时去重（ReplacingMergeTree + 版本号）
-- ============================================================

-- 【场景】实时订单状态更新，需要保证最终一致性

-- 【原理】实时去重策略
-- 1. 使用 ReplacingMergeTree 物理去重（后台 merge）
-- 2. 使用版本号列（version）控制保留最新版本
-- 3. 查询时使用 FINAL 或 argMax 获取最新状态
-- 4. 结合物化视图做实时聚合

-- 实时订单状态表
CREATE TABLE realtime_orders
(
    order_id      UInt64,
    order_status  LowCardinality(String),
    status_time   DateTime,
    operator      LowCardinality(String),
    remark        String,
    -- 版本号：使用事件时间戳，越大越新
    version       UInt64
)
ENGINE = ReplacingMergeTree(version)
ORDER BY order_id
PARTITION BY toYYYYMM(status_time);

-- 模拟订单状态流转（同一订单多次更新）
INSERT INTO realtime_orders VALUES
    (1001, 'Pending',   '2024-06-01 10:00:00', 'system', '订单创建', 1),
    (1001, 'Paid',      '2024-06-01 10:05:00', 'system', '支付成功', 2),
    (1001, 'Shipped',   '2024-06-01 14:00:00', 'admin',  '已发货',  3),
    (1001, 'Completed', '2024-06-03 10:00:00', 'system', '已签收',  4),
    (1002, 'Pending',   '2024-06-01 11:00:00', 'system', '订单创建', 1),
    (1002, 'Cancelled', '2024-06-01 11:30:00', 'user',   '用户取消', 2);

-- 查询未去重的数据
SELECT '【去重前】包含所有状态变更:';
SELECT order_id, order_status, status_time, version
FROM realtime_orders
ORDER BY order_id, version;

-- 使用 FINAL 查询去重后（仅保留最新版本）
SELECT '【去重后】FINAL 查询:';
SELECT order_id, order_status, status_time, operator, remark
FROM realtime_orders FINAL
ORDER BY order_id;

-- 使用 argMax 查询最新状态（推荐，性能更好）
SELECT '【去重后】argMax 查询:';
SELECT
    order_id,
    argMax(order_status, version) AS latest_status,
    argMax(status_time, version) AS latest_time,
    argMax(operator, version) AS latest_operator
FROM realtime_orders
GROUP BY order_id
ORDER BY order_id;

-- 实时订单状态聚合
SELECT '【实时聚合】各状态订单数:';
SELECT
    argMax(order_status, version) AS current_status,
    count() AS order_count
FROM realtime_orders
GROUP BY order_id
ORDER BY current_status;

-- 【坑】ReplacingMergeTree 实时去重的注意事项
-- 1. 去重不是实时的，新写入的数据可能重复
-- 2. 查询时一定要用 FINAL 或 argMax
-- 3. 多个分片时，去重只在分片内生效
-- 4. 版本列必须是数值型或时间型

-- ============================================================
-- 实验四：实时大屏查询优化
-- ============================================================

-- 【场景】实时大屏需要秒级刷新，查询延迟 < 100ms

-- 【原理】实时大屏优化策略
-- 1. 使用物化视图预聚合
-- 2. 使用 AggregatingMergeTree 存储聚合状态
-- 3. 限制查询范围（最近 N 分钟/小时）
-- 4. 使用简单的聚合函数
-- 5. 避免 JOIN 和子查询

-- 创建实时大屏专用聚合表
CREATE TABLE realtime_dashboard
(
    metric_name   LowCardinality(String),
    metric_value  Float64,
    updated_at    DateTime
)
ENGINE = MergeTree
ORDER BY (metric_name, updated_at);

-- 创建物化视图，持续更新大屏指标
CREATE MATERIALIZED VIEW mv_dashboard_metrics
TO realtime_dashboard
AS SELECT
    'total_requests' AS metric_name,
    toFloat64(count()) AS metric_value,
    now() AS updated_at
FROM api_requests
WHERE request_time >= now() - INTERVAL 1 HOUR
GROUP BY metric_name;

-- 插入大屏指标
INSERT INTO realtime_dashboard VALUES
    ('total_requests', 100000, now()),
    ('active_users', 5000, now()),
    ('avg_response_time', 150.5, now()),
    ('error_rate', 2.3, now()),
    ('qps', 1500, now());

-- 查询大屏指标（单行查询，延迟极低）
SELECT '【实时大屏】核心指标:';
SELECT metric_name, metric_value, updated_at
FROM realtime_dashboard
ORDER BY metric_name;

-- 大屏常用查询：最近 N 分钟趋势
SELECT '【实时大屏】最近 10 分钟 API 趋势:';
SELECT
    toStartOfMinute(request_time) AS minute,
    count() AS requests,
    avg(response_time) AS avg_ms,
    countIf(status_code >= 500) AS errors
FROM api_requests
WHERE request_time >= now() - INTERVAL 10 MINUTE
GROUP BY toStartOfMinute(request_time)
ORDER BY minute;

-- 大屏常用查询：TOP 5 慢 API
SELECT '【实时大屏】TOP 5 慢 API:';
SELECT
    api_name,
    count() AS calls,
    round(avg(response_time), 2) AS avg_ms,
    round(quantile(0.95)(response_time), 2) AS p95_ms,
    max(response_time) AS max_ms
FROM api_requests
WHERE request_time >= now() - INTERVAL 30 MINUTE
GROUP BY api_name
ORDER BY avg_ms DESC
LIMIT 5;

-- 大屏常用查询：错误分布
SELECT '【实时大屏】错误分布:';
SELECT
    api_name,
    countIf(status_code >= 500) AS server_errors,
    countIf(status_code >= 400 AND status_code < 500) AS client_errors,
    count() AS total
FROM api_requests
WHERE request_time >= now() - INTERVAL 1 HOUR
GROUP BY api_name
ORDER BY server_errors DESC;

-- ============================================================
-- 实验五：实时数据管道（端到端示例）
-- ============================================================

-- 【场景】完整的实时数据管道：日志采集 → 实时聚合 → 大屏展示

-- 步骤 1：原始数据表（日志采集）
CREATE TABLE raw_events
(
    event_id      UInt64,
    event_type    LowCardinality(String),
    user_id       UInt32,
    event_time    DateTime,
    properties    String,  -- JSON 格式的属性
    server_time   DateTime DEFAULT now()
)
ENGINE = MergeTree
ORDER BY (event_time, event_type)
PARTITION BY toDate(event_time)
TTL toDate(event_time) + INTERVAL 3 DAY DELETE;

-- 步骤 2：实时写入（使用异步 INSERT）
-- 客户端设置：async_insert = 1, wait_for_async_insert = 0

-- 步骤 3：实时聚合（物化视图）
CREATE MATERIALIZED VIEW mv_realtime_events
ENGINE = AggregatingMergeTree
ORDER BY (event_type, window_minute)
PARTITION BY toDate(window_minute)
AS SELECT
    event_type,
    toStartOfMinute(event_time) AS window_minute,
    countState() AS event_count,
    uniqState(user_id) AS unique_users
FROM raw_events
GROUP BY event_type, toStartOfMinute(event_time);

-- 步骤 4：写入模拟实时数据
INSERT INTO raw_events SELECT
    number AS event_id,
    ['page_view', 'click', 'purchase', 'login', 'logout'][(number % 5) + 1] AS event_type,
    number % 50000 AS user_id,
    now() - (number % 3600) AS event_time,
    format('{{"page":"{}","duration":{}}}', concat('/page_', toString(number % 100)), rand() % 30000) AS properties
FROM system.numbers
LIMIT 50000;

-- 步骤 5：实时查询
SELECT '【实时管道】最近 5 分钟事件统计:';
SELECT
    event_type,
    window_minute,
    countMerge(event_count) AS events,
    uniqMerge(unique_users) AS users
FROM mv_realtime_events
WHERE window_minute >= now() - INTERVAL 5 MINUTE
GROUP BY event_type, window_minute
ORDER BY window_minute DESC, events DESC;

-- 步骤 6：数据质量管理
SELECT '【数据质量】实时数据延迟检查:';
SELECT
    event_type,
    count() AS total_events,
    countIf(server_time - event_time > 5) AS delayed_events,  -- 延迟 > 5 秒
    round(avg(server_time - event_time), 2) AS avg_delay_seconds
FROM raw_events
WHERE event_time >= now() - INTERVAL 10 MINUTE
GROUP BY event_type;

-- ============================================================
-- 结论：实时建模最佳实践
-- ============================================================
-- 1. 写入优化：Buffer 引擎 + 异步 INSERT + 批量写入
-- 2. 聚合优化：物化视图 + AggregatingMergeTree + *State/Merge
-- 3. 去重优化：ReplacingMergeTree + 版本号 + argMax 查询
-- 4. 查询优化：预聚合 + 限制时间范围 + 避免 JOIN
-- 5. 大屏优化：专用聚合表 + 简单查询 + 低延迟
-- 6. 监控优化：数据延迟监控 + Parts 数量监控 + 写入 QPS 监控

-- 实时建模核心原则
-- 1. 写入与查询分离：Buffer 表缓冲写入，物化视图提供查询
-- 2. 最终一致性：接受短暂的数据不一致，保证最终一致
-- 3. 预聚合优先：将计算放在写入时，而非查询时
-- 4. 数据生命周期管理：TTL 控制数据保留时间
-- 5. 监控告警：实时监控数据延迟和错误率

SELECT 'DONE - 实时建模实验完成';

DROP DATABASE IF EXISTS modeling_test;