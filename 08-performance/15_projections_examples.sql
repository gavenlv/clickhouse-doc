-- ================================================================================
-- ClickHouse Projections 投影深度示例
-- ================================================================================
--
-- 集群: treasurycluster (2 副本)
-- 预计学习时间: 20 分钟
--
-- 本文件涵盖:
--   1. Projections 创建与使用 - ALTER TABLE ... ADD PROJECTION
--   2. 查询自动路由实验 - 验证查询自动命中 Projection
--   3. 与物化视图的对比 - 自动路由 vs 手动路由
--   4. Projections 性能测试 - 原始表 vs Projection 查询对比
--   5. 监控 Projections - system.projection_parts
--   6. Projections 局限 - ALTER 困难、存储翻倍、聚合限制
--
-- 【原理】Projections 是 ClickHouse 20.6+ 引入的"物化视图"替代方案
-- 在后台自动维护聚合/排序后的数据副本，查询时自动路由到最优 Projection
--
-- 核心机制:
--   ┌─────────────────────────────────────────────────────────────────────────┐
--   │                    Projections 工作流程                                 │
--   └─────────────────────────────────────────────────────────────────────────┘
--
--   INSERT 时:
--   ┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐
--   │ 数据写入 │───>│ 主表存储 │───>│ 自动维护 │───>│ 写入     │
--   │ 原始数据 │    │ 原始格式 │    │ Projection│    │ Projection│
--   └──────────┘    └──────────┘    └──────────┘    └──────────┘
--
--   SELECT 时:
--   ┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐
--   │ 接收查询 │───>│ 优化器   │───>│ 命中     │───>│ 从       │
--   │          │    │ 自动路由 │    │ Projection│    │ Projection│
--   └──────────┘    └──────────┘    └──────────┘    └──────────┘
--                              │
--                              ▼
--                        ┌──────────┐
--                        │ 未命中   │
--                        │ 从原始表 │
--                        │ 读取     │
--                        └──────────┘
--
-- Projections 与物化视图对比:
--   ┌─────────────────────────────────────────────────────────────────────────┐
--   │                    对比维度表                                           │
--   └─────────────────────────────────────────────────────────────────────────┘
--   维度          | Projections                    | 物化视图 (MV)
--   ──────────────┼────────────────────────────────┼─────────────────────────
--   查询路由      | 自动（优化器决定）              | 手动（SELECT 必须指定 MV 名）
--   存储位置      | 与主表同一存储路径              | 独立表，可存不同磁盘/集群
--   维护成本      | 低（INSERT 时自动维护）         | 中（需额外管理 MV 生命周期）
--   ALTER 操作    | 困难（需重建或删除重建）         | 灵活（可独立 DDL）
--   聚合函数      | 有限（不支持所有聚合函数）       | 支持所有聚合函数 + State/Combine
--   存储翻倍      | 是（原始数据 + 投影副本）        | 是（原始数据 + MV 表）
--   数据一致性    | 强一致（原子写入）               | 最终一致（异步）
--   适用场景      | 加速已知查询模式                 | 复杂 ETL、跨集群复制
--
-- Projections 类型:
--   1. 普通 Projection: 重新排序的列子集
--      - 类似二级索引，但更强大（存储完整列数据）
--      - 适用于: 查询条件与主键顺序不同
--   2. 聚合 Projection: 预聚合数据
--      - 类似物化视图的聚合表
--      - 适用于: 固定模式的聚合查询
--
-- 【场景】何时使用 Projections：
--   ✅ 查询模式固定，需要加速
--   ✅ 不想管理额外的 MV 表
--   ✅ 需要强一致性保证
--   ❌ 查询模式多变，无法预测
--   ❌ 需要跨集群复制数据
--   ❌ 使用非支持的聚合函数
--
-- ================================================================================

DROP DATABASE IF EXISTS perf_test;
CREATE DATABASE perf_test;
USE perf_test;

-- ============================================================================
-- 0. 准备测试数据
-- ============================================================================

-- 创建订单表
CREATE TABLE orders
(
    order_id UInt64,
    customer_id UInt32,
    product_id UInt32,
    category_id UInt16,
    amount Decimal(12, 2),
    quantity UInt8,
    order_date Date,
    status String
)
ENGINE = MergeTree()
PARTITION BY toYYYYMM(order_date)
ORDER BY (order_date, customer_id);

-- 插入 100 万行测试数据
INSERT INTO orders
SELECT
    number as order_id,
    number % 10000 as customer_id,
    number % 500 as product_id,
    (number % 50)::UInt16 as category_id,
    (rand() % 10000)::Decimal(12, 2) / 100 as amount,
    (rand() % 10 + 1)::UInt8 as quantity,
    toDate('2024-01-01') + (number % 365) as order_date,
    ['pending', 'completed', 'cancelled', 'refunded'][(number % 4) + 1] as status
FROM numbers(1000000);

-- 验证数据
SELECT count(), min(order_date), max(order_date) FROM orders;

-- ============================================================================
-- 1. 创建普通 Projection（重新排序）
-- ============================================================================
-- 【原理】普通 Projection 存储了按不同列排序的数据副本
-- 当查询的 ORDER BY 或 WHERE 条件匹配 Projection 的排序键时，优化器自动路由

-- 创建一个按 customer_id 排序的 Projection（原始表按 order_date, customer_id 排序）
ALTER TABLE orders
ADD PROJECTION orders_by_customer
(
    SELECT
        customer_id,
        order_id,
        order_date,
        amount,
        status
    ORDER BY (customer_id, order_date)
);

-- 将 Projection 物化到已有数据
ALTER TABLE orders MATERIALIZE PROJECTION orders_by_customer;

-- 【坑】MATERIALIZE PROJECTION 是异步操作，需要等待后台进程完成
-- 可以通过 system.projection_parts 查看物化进度

-- 查询 Projection 物化状态
SELECT
    name,
    partition,
    rows,
    bytes_on_disk,
    data_compressed_bytes,
    data_uncompressed_bytes,
    active
FROM system.projection_parts
WHERE table = 'orders' AND database = 'perf_test';

-- ============================================================================
-- 2. 创建聚合 Projection（预聚合）
-- ============================================================================
-- 【原理】聚合 Projection 会在 INSERT 时自动计算聚合函数
-- 当查询的 GROUP BY 和聚合函数匹配时，优化器自动读取聚合结果

ALTER TABLE orders
ADD PROJECTION daily_category_stats
(
    SELECT
        order_date,
        category_id,
        count() as order_count,
        sum(amount) as total_amount,
        sum(quantity) as total_quantity,
        avg(amount) as avg_amount
    GROUP BY order_date, category_id  -- 注意: 投影内 GROUP BY 不能加括号（25.12 报 NOT_AN_AGGREGATE）
);

-- 物化聚合 Projection
ALTER TABLE orders MATERIALIZE PROJECTION daily_category_stats;

-- 【坑】聚合 Projection 支持的聚合函数有限：
-- ✅ count, sum, avg, min, max, any, anyLast
-- ❌ uniq, quantile, stddevSamp, topK, 等复杂聚合函数

-- ============================================================================
-- 3. 查询自动路由实验
-- ============================================================================
-- 【原理】ClickHouse 优化器会自动选择最优的 Projection 来服务查询
-- 通过 EXPLAIN 可以验证路由决策

-- 实验 1: 按 customer_id 查询（应该命中 orders_by_customer Projection）
-- 【场景】用户维度的查询，原始表按日期排序，但查询按用户过滤
EXPLAIN PLAN
SELECT customer_id, sum(amount) as total
FROM orders
WHERE customer_id = 123
GROUP BY customer_id;

-- 实验 2: 按日期和类别的聚合查询（应该命中 daily_category_stats Projection）
EXPLAIN PLAN
SELECT
    order_date,
    category_id,
    count() as order_count,
    sum(amount) as total_amount
FROM orders
WHERE order_date >= '2024-06-01' AND order_date < '2024-07-01'
GROUP BY order_date, category_id;

-- 实验 3: 不匹配 Projection 的查询（从原始表读取）
-- 【坑】不是所有查询都能命中 Projection，优化器会评估成本
EXPLAIN PLAN
SELECT status, count() as cnt
FROM orders
GROUP BY status;

-- 实验 4: 使用 EXPLAIN PIPELINE 查看数据读取路径
EXPLAIN PIPELINE
SELECT customer_id, count() as cnt
FROM orders
WHERE customer_id IN (1, 2, 3)
GROUP BY customer_id;

-- ============================================================================
-- 4. Projections 性能测试
-- ============================================================================
-- 【场景】对比原始表查询和 Projection 查询的性能差异

-- 测试 1: 按 customer_id 过滤（orders_by_customer 应该加速）
-- 原始表排序: (order_date, customer_id) -> 需要扫描大量数据
-- Projection 排序: (customer_id, order_date) -> 直接定位

-- 开启查询计时（25.12 中新分析器默认启用，enable_optimizer 已移除，无需设置）
-- SET enable_optimizer = 1;

-- 查询 1: 按 customer_id 查询（应该使用 Projection）
SELECT
    customer_id,
    count() as order_count,
    sum(amount) as total_amount
FROM orders
WHERE customer_id BETWEEN 100 AND 200
GROUP BY customer_id;

-- 查询 2: 按日期聚合（应该使用 daily_category_stats Projection）
SELECT
    order_date,
    count() as order_count,
    sum(amount) as total_amount
FROM orders
WHERE order_date = '2024-06-15'
GROUP BY order_date;

-- 查询 3: 多维度聚合（可能使用 daily_category_stats Projection）
SELECT
    category_id,
    sum(amount) as total_amount,
    avg(amount) as avg_amount
FROM orders
WHERE order_date >= '2024-01-01' AND order_date < '2024-04-01'
GROUP BY category_id;

-- ============================================================================
-- 5. Projections 与物化视图对比实验
-- ============================================================================
-- 【对比】同等功能的物化视图实现

-- 创建物化视图作为对比
CREATE MATERIALIZED VIEW mv_daily_category_stats
ENGINE = AggregatingMergeTree()
PARTITION BY toYYYYMM(order_date)
ORDER BY (order_date, category_id)
AS SELECT
    order_date,
    category_id,
    countState() as order_count,
    sumState(amount) as total_amount,
    avgState(amount) as avg_amount
FROM orders
GROUP BY order_date, category_id;

-- 查询物化视图
SELECT
    order_date,
    category_id,
    countMerge(order_count) as order_count,
    sumMerge(total_amount) as total_amount,
    avgMerge(avg_amount) as avg_amount
FROM mv_daily_category_stats
WHERE order_date >= '2024-06-01' AND order_date < '2024-07-01'
GROUP BY order_date, category_id;

-- 【对比】Projections 优势：
-- 1. 查询不需要指定表名，优化器自动路由
-- 2. 数据一致性更强（原子写入）
-- 3. 不需要管理额外的表生命周期
--
-- 物化视图优势：
-- 1. 可以跨集群/跨磁盘存储
-- 2. 支持所有聚合函数（包括 State/Combine 组合）
-- 3. ALTER 操作更灵活
-- 4. 可以独立进行分区操作

-- ============================================================================
-- 6. Projections 的局限与陷阱
-- ============================================================================

-- 【坑 1】ALTER 操作困难
-- 不能直接 ALTER PROJECTION，需要删除重建
-- 删除 Projection:
ALTER TABLE orders DROP PROJECTION orders_by_customer;
-- 重新添加:
ALTER TABLE orders ADD PROJECTION orders_by_customer
(
    SELECT customer_id, order_id, order_date, amount, status
    ORDER BY (customer_id, order_date)
);
-- 需要重新物化:
ALTER TABLE orders MATERIALIZE PROJECTION orders_by_customer;

-- 【坑 2】存储翻倍
-- 每个 Projection 都会存储一份完整的数据副本
-- 查询真实存储:
SELECT
    table,
    name as projection_name,
    rows,
    bytes_on_disk,
    formatReadableSize(bytes_on_disk) as readable_size
FROM system.projection_parts
WHERE database = 'perf_test' AND table = 'orders'
ORDER BY name;

-- 主表存储:
SELECT
    table,
    formatReadableSize(sum(data_compressed_bytes)) as compressed,
    formatReadableSize(sum(data_uncompressed_bytes)) as uncompressed,
    count() as parts
FROM system.parts
WHERE database = 'perf_test' AND table = 'orders' AND active = 1
GROUP BY table;

-- 【坑 3】不是所有聚合函数都支持
-- 尝试创建不支持聚合函数的 Projection（会报错）
-- ALTER TABLE orders ADD PROJECTION bad_projection
-- (
--     SELECT
--         order_date,
--         uniq(customer_id) as unique_customers  -- uniq 不支持！
--     GROUP BY order_date
-- );

-- 【坑 4】Projection 与原始表数据一致性
-- 新插入的数据会自动写入 Projection，不需要手动维护
-- 验证：
INSERT INTO orders
VALUES (1000001, 9999, 1, 1, 100.00, 1, '2024-12-01', 'pending');

-- 查询新插入的数据（应该自动命中 Projection）
SELECT customer_id, count() as cnt
FROM orders
WHERE customer_id = 9999
GROUP BY customer_id;

-- 【坑 5】Projection 对写入性能有影响
-- 每次 INSERT 都需要维护所有 Projection，会增加写入延迟
-- 适合: 查询频繁、写入不频繁的场景
-- 不适合: 高频写入场景

-- ============================================================================
-- 7. system.projection_parts 监控
-- ============================================================================
-- 【原理】system.projection_parts 提供 Projection 的详细元数据

-- 查看所有 Projection 的详细信息
SELECT
    database,
    table,
    name,
    partition,
    rows,
    bytes_on_disk,
    formatReadableSize(bytes_on_disk) as readable_size,
    data_compressed_bytes,
    data_uncompressed_bytes,
    data_compressed_bytes / data_uncompressed_bytes as compression_ratio,
    active,
    level,
    modification_time,
    min_date,
    max_date
FROM system.projection_parts
WHERE database = 'perf_test'
ORDER BY table, name, partition;

-- 查看 Projection 查询命中统计（需启用 query_log）
-- SELECT
--     query,
--     query_duration_ms,
--     read_rows,
--     read_bytes,
--     ProfileEvents['ProjectionWriterCreated'] as proj_writer_created,
--     ProfileEvents['ProjectionWriterBlocks'] as proj_writer_blocks
-- FROM system.query_log
-- WHERE type = 'QueryFinish'
--   AND database = 'perf_test'
--   AND event_time >= now() - INTERVAL 1 HOUR
-- ORDER BY event_time DESC
-- LIMIT 10;

-- 查看 Projection 写入性能（需启用 query_log）
-- SELECT
--     event_time,
--     ProfileEvents['ProjectionWriterCreated'] as proj_created,
--     ProfileEvents['ProjectionWriterBlocks'] as proj_blocks,
--     ProfileEvents['ProjectionWriterBlocksAlreadyWritten'] as proj_blocks_written
-- FROM system.query_log
-- WHERE type = 'QueryFinish'
--   AND query LIKE '%INSERT%'
--   AND event_time >= now() - INTERVAL 1 HOUR
-- ORDER BY event_time DESC
-- LIMIT 5;

-- ============================================================================
-- 8. 实战：多 Projection 策略
-- ============================================================================
-- 【场景】为不同查询模式创建多个 Projection

-- 创建按 status 排序的 Projection
ALTER TABLE orders
ADD PROJECTION orders_by_status
(
    SELECT
        status,
        order_date,
        customer_id,
        amount,
        quantity
    ORDER BY (status, order_date)
);

ALTER TABLE orders MATERIALIZE PROJECTION orders_by_status;

-- 创建按 product_id 聚合的 Projection
ALTER TABLE orders
ADD PROJECTION product_sales_stats
(
    SELECT
        product_id,
        count() as sale_count,
        sum(amount) as total_sales,
        sum(quantity) as total_quantity
    GROUP BY product_id
);

ALTER TABLE orders MATERIALIZE PROJECTION product_sales_stats;

-- 验证所有 Projection 都已生效
SELECT
    name,
    rows,
    formatReadableSize(bytes_on_disk) as size,
    active
FROM system.projection_parts
WHERE database = 'perf_test' AND table = 'orders'
ORDER BY name;

-- 测试不同查询模式的路由:
-- 模式 1: 按 status 过滤
EXPLAIN PLAN
SELECT status, count() as cnt, sum(amount) as total
FROM orders
WHERE status = 'completed'
GROUP BY status;

-- 模式 2: 按 product_id 聚合
EXPLAIN PLAN
SELECT product_id, sum(amount) as total_sales
FROM orders
WHERE product_id IN (1, 2, 3)
GROUP BY product_id;

-- ============================================================================
-- 9. Projections 最佳实践总结
-- ============================================================================
-- 【最佳实践】
-- 1. 先分析查询模式，再创建 Projection
-- 2. 每个表不超过 3 个 Projection（避免写入过载）
-- 3. 聚合 Projection 优先于普通 Projection（存储效率更高）
-- 4. 定期监控 system.projection_parts 检查数据一致性
-- 5. 对已有数据创建 Projection 后，务必 MATERIALIZE
-- 6. 优先使用 ALTER TABLE ADD PROJECTION，而不是 CREATE TABLE 时定义
-- 7. 测试环境验证 Projection 路由是否正确（EXPLAIN PLAN）
-- 8. 注意存储翻倍，评估磁盘空间
-- 9. 写入频繁的表慎用 Projection
-- 10. 考虑用物化视图替代需要复杂聚合函数的场景

-- ============================================================================
-- 清理
-- ============================================================================
DROP DATABASE IF EXISTS perf_test;