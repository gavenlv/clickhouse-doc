-- ================================================================================
-- ClickHouse JOIN 策略深度示例
-- ================================================================================
--
-- 集群: treasurycluster (2 副本)
-- 预计学习时间: 25 分钟
--
-- 本文件涵盖:
--   1. JOIN 算法对比 - Hash Join / Merge Join / Partial Merge Join
--   2. 分布式 JOIN 方案 - GLOBAL JOIN / 字典 / 本地 JOIN
--   3. GLOBAL JOIN 广播流程 - 网络传输与性能影响
--   4. 字典替代 JOIN 实验 - 100x 性能提升验证
--   5. 列裁剪与行过滤优化 - 减少 JOIN 数据量
--   6. 小表驱动大表原则 - 数据分布对性能的影响
--   7. JOIN 常见陷阱 - NULL 处理、类型不匹配、重复行
--
-- 【原理】ClickHouse 的 JOIN 实现与 OLTP 数据库有本质区别：
--   - 右表全量加载到内存（Hash Join）或排序后磁盘操作（Merge Join）
--   - 左表流式处理，右表全量参与
--   - 没有索引辅助 JOIN（ClickHouse 是列存，不是行存索引）
--
-- JOIN 算法选择:
--   ┌─────────────────────────────────────────────────────────────────────────┐
--   │                    ClickHouse JOIN 算法决策树                           │
--   └─────────────────────────────────────────────────────────────────────────┘
--
--   是否为分布式查询?
--   ├─ 是 → 检查 distributed_product_mode
--   │   ├─ local    → 查询在每个分片本地执行，右表需要每个分片都存在
--   │   ├─ global   → 右表广播到所有分片（GLOBAL JOIN）
--   │   └─ deny     → 拒绝分布式 JOIN
--   │
--   └─ 否 → 检查 join_algorithm 设置
--       ├─ auto (默认) → ClickHouse 自动选择
--       │   ├─ 右表小 → Hash Join（内存哈希表）
--       │   └─ 右表大 → Merge Join（排序后合并）
--       ├─ hash        → 强制 Hash Join
--       ├─ merge       → 强制 Merge Join
--       └─ partial_merge → 部分合并 JOIN（分块处理）
--
-- 三种 JOIN 算法对比:
--   ┌─────────────────────────────────────────────────────────────────────────┐
--   │                    算法对比表                                           │
--   └─────────────────────────────────────────────────────────────────────────┘
--   算法           | 内存使用 | 适用场景               | 性能特点
--   ───────────────┼──────────┼───────────────────────┼─────────────────────
--   Hash Join      | 高       | 右表小 (< 1GB)       | 最快，右表加载到内存
--   Merge Join     | 低       | 右表大，已排序        | 中等，适合大数据量
--   Partial Merge  | 中       | 右表大，未排序        | 慢，分块处理
--
-- ================================================================================

DROP DATABASE IF EXISTS perf_test;
CREATE DATABASE perf_test;
USE perf_test;

-- ============================================================================
-- 0. 准备测试数据
-- ============================================================================

-- 创建大表（事实表）- 100 万行
CREATE TABLE orders
(
    order_id UInt64,
    customer_id UInt32,
    product_id UInt32,
    amount Decimal(12, 2),
    quantity UInt8,
    order_date Date,
    status String
)
ENGINE = MergeTree()
PARTITION BY toYYYYMM(order_date)
ORDER BY (order_date, order_id);

INSERT INTO orders
SELECT
    number as order_id,
    (number % 100000)::UInt32 as customer_id,  -- 10 万客户
    (number % 5000)::UInt32 as product_id,     -- 5000 产品
    (rand() % 10000)::Decimal(12, 2) / 100 as amount,
    (rand() % 10 + 1)::UInt8 as quantity,
    toDate('2024-01-01') + (number % 365) as order_date,
    ['pending', 'completed', 'cancelled', 'refunded'][(number % 4) + 1] as status
FROM numbers(1000000);

-- 创建小表（维度表）- 10 万行
CREATE TABLE customers
(
    customer_id UInt32,
    name String,
    email String,
    city String,
    registration_date Date,
    tier String
)
ENGINE = MergeTree()
ORDER BY customer_id;

INSERT INTO customers
SELECT
    number as customer_id,
    'customer_' || toString(number) as name,
    'user_' || toString(number) || '@example.com' as email,
    ['北京', '上海', '广州', '深圳', '杭州', '成都', '武汉', '南京'][(number % 8) + 1] as city,
    toDate('2023-01-01') + (number % 365) as registration_date,
    ['bronze', 'silver', 'gold', 'platinum'][(number % 4) + 1] as tier
FROM numbers(100000);

-- 创建超小表（配置表）- 100 行
CREATE TABLE product_categories
(
    category_id UInt16,
    category_name String,
    description String
)
ENGINE = MergeTree()
ORDER BY category_id;

INSERT INTO product_categories
SELECT
    number as category_id,
    'category_' || toString(number) as category_name,
    'description for category ' || toString(number) as description
FROM numbers(100);

-- 验证数据
SELECT 'orders', count() FROM orders;
SELECT 'customers', count() FROM customers;
SELECT 'product_categories', count() FROM product_categories;

-- ============================================================================
-- 1. JOIN 算法对比实验
-- ============================================================================
-- 【原理】ClickHouse 默认使用 Hash Join（右表加载到内存构建哈希表）
-- 通过 join_algorithm 设置可以切换算法

-- 实验 1.1: Hash Join（默认）
-- 【场景】右表小，内存足够，最快
SELECT
    o.order_id,
    o.amount,
    c.name,
    c.tier
FROM orders o
INNER JOIN customers c ON o.customer_id = c.customer_id
WHERE o.order_date >= '2024-06-01'
LIMIT 10;

-- 查看 Hash Join 的执行计划
EXPLAIN PLAN
SELECT
    o.order_id,
    o.amount,
    c.name
FROM orders o
INNER JOIN customers c ON o.customer_id = c.customer_id
WHERE o.order_date >= '2024-06-01';

-- 实验 1.2: 强制 Merge Join（25.12 的算法名为 full_sorting_merge，'merge' 已不存在）
-- 【场景】右表太大，内存不足时使用
SELECT
    o.order_id,
    o.amount,
    c.name,
    c.tier
FROM orders o
INNER JOIN customers c ON o.customer_id = c.customer_id
WHERE o.order_date >= '2024-06-01'
LIMIT 10
SETTINGS join_algorithm = 'full_sorting_merge';

-- 实验 1.3: 强制 Partial Merge Join
-- 【场景】右表巨大且未排序，分块处理
SELECT
    o.order_id,
    o.amount,
    c.name,
    c.tier
FROM orders o
INNER JOIN customers c ON o.customer_id = c.customer_id
WHERE o.order_date >= '2024-06-01'
LIMIT 10
SETTINGS join_algorithm = 'partial_merge';

-- 【对比】三种算法性能差异
-- 1. Hash Join: 最快，但右表必须能放入内存
-- 2. Full Sorting Merge: 需要排序，适合大表，额外排序开销
-- 3. Partial Merge: 避免全量加载，但最慢

-- ============================================================================
-- 2. 分布式 JOIN 方案对比
-- ============================================================================
-- 【原理】分布式 JOIN 的 3 种方案：
--   1. GLOBAL JOIN: 右表广播到所有分片（网络开销大）
--   2. 字典: 使用 Dictionary 加载维度表（最快，适合低频变更）
--   3. 本地 JOIN: 每个分片本地 JOIN（需要右表在每台机器存在）

-- 实验 2.1: GLOBAL JOIN
-- 【场景】右表小，但每个分片都有完整的右表数据
-- 【原理】GLOBAL JOIN 将右表数据收集到 initiator 节点，然后广播到所有分片
-- 
-- 广播流程:
--   ┌──────────────┐         ┌──────────────┐
--   │  Initiator   │         │  Worker 1    │
--   │  (接收查询)  │         │              │
--   └──────┬───────┘         └──────────────┘
--          │                        │
--          ▼                        │
--   ┌──────────────┐                │
--   │ 收集右表数据  │               │
--   │ 到 initiator │                │
--   └──────┬───────┘                │
--          │                        │
--          ▼                        │
--   ┌──────────────┐    ┌───────────┴──────────┐
--   │ 广播到所有分片 │───>│ Worker 1 本地执行    │
--   └──────────────┘    │ Worker 2 本地执行    │
--                       │ Worker N 本地执行    │
--                       └─────────────────────┘

-- 模拟分布式环境（单节点通过 Distributed 表测试）
-- 创建分布式表
CREATE TABLE orders_distributed AS orders
ENGINE = Distributed('treasurycluster', 'perf_test', 'orders', rand());

-- GLOBAL JOIN 查询
SELECT
    o.order_id,
    o.amount,
    c.name
FROM orders_distributed o
GLOBAL INNER JOIN customers c ON o.customer_id = c.customer_id
WHERE o.order_date >= '2024-06-01'
LIMIT 10
SETTINGS distributed_product_mode = 'global';

-- 查看 GLOBAL JOIN 的执行计划
EXPLAIN PLAN
SELECT
    o.order_id,
    o.amount,
    c.name
FROM orders_distributed o
GLOBAL INNER JOIN customers c ON o.customer_id = c.customer_id
WHERE o.order_date >= '2024-06-01';

-- 【坑】GLOBAL JOIN 的性能影响：
-- 1. 右表数据需要通过网络传输到所有分片
-- 2. 右表数据量越大，网络开销越大
-- 3. 建议右表 < 1GB 时使用 GLOBAL JOIN

-- 实验 2.2: 字典替代 JOIN
-- 【场景】维度表数据变更不频繁，需要极致性能
-- 【原理】字典加载到内存，查询时直接通过 dictGet 函数获取，无需 JOIN

-- 创建字典
CREATE DICTIONARY dict_customers
(
    customer_id UInt32,
    name String,
    email String,
    city String,
    tier String
)
PRIMARY KEY customer_id
SOURCE(CLICKHOUSE(TABLE 'customers' DATABASE 'perf_test'))
LIFETIME(MIN 300 MAX 600)
LAYOUT(FLAT());

-- 验证字典数据
SELECT dictGet('perf_test.dict_customers', 'name', toUInt64(1));
SELECT dictGet('perf_test.dict_customers', 'tier', toUInt64(1));

-- 字典查询（替代 JOIN）
-- 【场景】快速获取维度属性，无需 JOIN 开销
SELECT
    o.order_id,
    o.amount,
    dictGet('perf_test.dict_customers', 'name', toUInt64(o.customer_id)) as customer_name,
    dictGet('perf_test.dict_customers', 'tier', toUInt64(o.customer_id)) as customer_tier
FROM orders o
WHERE o.order_date >= '2024-06-01'
LIMIT 10;

-- 【对比】字典 vs JOIN 性能：字典查询延迟通常在微秒级
-- 字典是 100x 性能提升的核心手段

-- 实验 2.3: 本地 JOIN（每个分片独立执行）
-- 【场景】右表在每个分片都有完整副本
SELECT
    o.order_id,
    o.amount,
    c.name
FROM orders o
INNER JOIN customers c ON o.customer_id = c.customer_id
WHERE o.order_date >= '2024-06-01'
LIMIT 10;

-- ============================================================================
-- 3. 字典替代 JOIN 的 100x 性能提升实验
-- ============================================================================
-- 【场景】高频查询场景，字典查询比 JOIN 快 100x 以上

-- 实验 3.1: 测试 JOIN 性能
SELECT
    c.tier,
    count() as order_count,
    sum(o.amount) as total_amount
FROM orders o
INNER JOIN customers c ON o.customer_id = c.customer_id
WHERE o.order_date >= '2024-01-01'
GROUP BY c.tier;

-- 实验 3.2: 测试字典查询性能
SELECT
    dictGet('perf_test.dict_customers', 'tier', toUInt64(o.customer_id)) as tier,
    count() as order_count,
    sum(o.amount) as total_amount
FROM orders o
WHERE o.order_date >= '2024-01-01'
GROUP BY tier;

-- 【对比】字典优势：
-- 1. 无 JOIN 算子开销（哈希表构建、数据 shuffle）
-- 2. 直接通过指针获取，延迟在微秒级
-- 3. 可以跨查询共享，无需重复构建
-- 4. 支持动态更新（LIFETIME 控制刷新频率）
--
-- 字典劣势：
-- 1. 只能用于维度查询（key-value 模式）
-- 2. 不支持复杂 JOIN 条件（如范围、LIKE）
-- 3. 数据变更不是实时的（受 LIFETIME 控制）
-- 4. 占用额外内存

-- ============================================================================
-- 4. 列裁剪和行过滤优化
-- ============================================================================
-- 【原理】JOIN 前先做过滤和投影，减少参与 JOIN 的数据量

-- 实验 4.1: 未优化的 JOIN（先 JOIN 后过滤）
-- 【坑】这种写法会先 JOIN 全量数据，再过滤，性能差
SELECT
    o.order_id,
    o.amount,
    c.name,
    c.tier
FROM orders o
INNER JOIN customers c ON o.customer_id = c.customer_id
WHERE o.order_date >= '2024-06-01'
  AND c.tier = 'gold';

-- 实验 4.2: 优化的 JOIN（先过滤后 JOIN）
-- 【原理】子查询先过滤和投影，减少 JOIN 的数据量
SELECT
    o.order_id,
    o.amount,
    c.name
FROM (
    -- 先过滤订单
    SELECT order_id, amount, customer_id
    FROM orders
    WHERE order_date >= '2024-06-01'
) o
INNER JOIN (
    -- 先过滤客户
    SELECT customer_id, name
    FROM customers
    WHERE tier = 'gold'
) c ON o.customer_id = c.customer_id;

-- 实验 4.3: 使用 WITH 子句优化
WITH
    filtered_orders AS (
        SELECT order_id, amount, customer_id
        FROM orders
        WHERE order_date >= '2024-06-01'
    ),
    gold_customers AS (
        SELECT customer_id, name
        FROM customers
        WHERE tier = 'gold'
    )
SELECT
    o.order_id,
    o.amount,
    c.name
FROM filtered_orders o
INNER JOIN gold_customers c ON o.customer_id = c.customer_id;

-- 【对比】优化效果：
-- 1. 减少 JOIN 的行数（先过滤再 JOIN）
-- 2. 减少 JOIN 的列数（只选择需要的列）
-- 3. 减少网络传输（分布式场景下）
-- 4. 减少内存使用（哈希表更小）

-- ============================================================================
-- 5. 小表驱动大表原则
-- ============================================================================
-- 【原理】ClickHouse 的 JOIN 总是将右表加载到内存（Hash Join）
-- 因此右表应该是小表，左表是大表
-- 这个原则与 MySQL 等 OLTP 数据库相反（它们是小表驱动大表）

-- 实验 5.1: 正确用法（大表 LEFT JOIN 小表）
-- 【场景】大表在左，小表在右，右表加载到内存
SELECT
    o.order_id,
    o.amount,
    c.name,
    c.tier
FROM orders o  -- 大表（左）
LEFT JOIN customers c ON o.customer_id = c.customer_id  -- 小表（右）
WHERE o.order_date >= '2024-06-01'
LIMIT 10;

-- 实验 5.2: 错误用法（小表 LEFT JOIN 大表）
-- 【坑】右表过大，可能 OOM 或性能极差
-- 右表（orders）有 100 万行，会全部加载到内存
SELECT
    c.customer_id,
    c.name,
    o.amount
FROM customers c  -- 小表（左）
LEFT JOIN orders o ON c.customer_id = o.customer_id  -- 大表（右）- 危险！
WHERE c.tier = 'gold'
LIMIT 10
SETTINGS join_algorithm = 'partial_merge';  -- 需要切换算法避免 OOM

-- 【原则】始终将小表放在 JOIN 右侧
-- 如果两个表都很大，考虑使用 Merge Join 或 Partial Merge Join

-- ============================================================================
-- 6. JOIN 常见陷阱
-- ============================================================================

-- 【坑 1】NULL 处理
-- ClickHouse 的 NULL 不会与任何值相等（包括 NULL 本身）
-- 创建含 NULL 的测试数据
CREATE TABLE orders_with_nulls
(
    order_id UInt64,
    customer_id Nullable(UInt32),
    amount Decimal(12, 2)
)
ENGINE = MergeTree()
ORDER BY order_id;

INSERT INTO orders_with_nulls
SELECT number, if(number % 10 = 0, NULL, number % 100000), (rand() % 10000)::Decimal(12, 2) / 100
FROM numbers(100000);

-- JOIN 时 NULL 不匹配（左表有 NULL customer_id）
SELECT
    o.order_id,
    o.customer_id,
    c.name
FROM orders_with_nulls o
LEFT JOIN customers c ON o.customer_id = c.customer_id
LIMIT 10;

-- 解决方案：使用 COALESCE 处理 NULL
SELECT
    o.order_id,
    COALESCE(o.customer_id, 0) as customer_id,
    c.name
FROM orders_with_nulls o
LEFT JOIN customers c ON COALESCE(o.customer_id, 0) = c.customer_id
LIMIT 10;

-- 【坑 2】类型不匹配
-- JOIN 条件两侧的类型必须一致，否则性能差或结果错误
-- 创建类型不匹配的表
CREATE TABLE customers_with_string_id
(
    customer_id String,  -- 字符串类型！
    name String
)
ENGINE = MergeTree()
ORDER BY customer_id;

INSERT INTO customers_with_string_id
SELECT toString(number), 'customer_' || toString(number)
FROM numbers(100000);

-- 类型不匹配的 JOIN（隐式转换，性能差）
SELECT
    o.order_id,
    c.name
FROM orders o
INNER JOIN customers_with_string_id c ON toString(o.customer_id) = c.customer_id
WHERE o.order_date >= '2024-06-01'
LIMIT 10;

-- 【坑】toString 函数导致无法使用左表主键，需要全表扫描！
-- 解决方案：统一数据类型，或提前转换

-- 正确的做法：确保 JOIN 键类型一致
SELECT
    o.order_id,
    c.name
FROM orders o
INNER JOIN customers_with_string_id c ON o.customer_id = c.customer_id::UInt32
WHERE o.order_date >= '2024-06-01'
LIMIT 10;

-- 更优的做法：在维度表中直接使用正确的类型
-- 创建使用正确类型的表
CREATE TABLE customers_proper
(
    customer_id UInt32,  -- 正确的类型！
    name String
)
ENGINE = MergeTree()
ORDER BY customer_id;

INSERT INTO customers_proper
SELECT number, 'customer_' || toString(number)
FROM numbers(100000);

-- 类型匹配的 JOIN（性能最优）
SELECT
    o.order_id,
    c.name
FROM orders o
INNER JOIN customers_proper c ON o.customer_id = c.customer_id
WHERE o.order_date >= '2024-06-01'
LIMIT 10;

-- 【坑 3】重复行
-- 如果右表有重复的 JOIN 键，会导致结果行数膨胀
-- 创建含重复数据的客户表
CREATE TABLE customers_duplicate
(
    customer_id UInt32,
    name String
)
ENGINE = MergeTree()
ORDER BY customer_id;

INSERT INTO customers_duplicate
SELECT number % 50000, 'customer_' || toString(number)  -- 每个 customer_id 可能有 2 行
FROM numbers(100000);

-- 重复导致的膨胀（结果行数可能远超预期）
SELECT
    o.order_id,
    o.amount,
    c.name
FROM orders o
INNER JOIN customers_duplicate c ON o.customer_id = c.customer_id
WHERE o.order_date >= '2024-06-01'
  AND o.customer_id = 123
LIMIT 10;

-- 解决方案：先去重再 JOIN
SELECT
    o.order_id,
    o.amount,
    c.name
FROM orders o
INNER JOIN (
    SELECT DISTINCT customer_id, name
    FROM customers_duplicate
) c ON o.customer_id = c.customer_id
WHERE o.order_date >= '2024-06-01'
  AND o.customer_id = 123
LIMIT 10;

-- 【坑 4】IN 与 JOIN 的性能差异
-- IN 通常比 JOIN 快（只需要检查是否存在，不需要构建整行结果）
-- IN 查询
SELECT
    o.order_id,
    o.amount
FROM orders o
WHERE o.customer_id IN (
    SELECT customer_id
    FROM customers
    WHERE tier = 'gold'
)
AND o.order_date >= '2024-06-01'
LIMIT 10;

-- JOIN 查询（等价但可能更慢）
SELECT
    o.order_id,
    o.amount
FROM orders o
INNER JOIN (
    SELECT customer_id
    FROM customers
    WHERE tier = 'gold'
) c ON o.customer_id = c.customer_id
WHERE o.order_date >= '2024-06-01'
LIMIT 10;

-- 【推荐】只要不返回右表字段，优先使用 IN 而不是 JOIN

-- 【坑 5】JOIN 的内存使用
-- 右表数据量超过 max_memory_usage 会导致 OOM
-- 查看当前内存限制
SELECT name, value, description
FROM system.settings
WHERE name IN ('max_memory_usage', 'max_bytes_in_join');

-- 设置 JOIN 内存限制
SELECT
    o.order_id,
    c.name
FROM orders o
INNER JOIN customers c ON o.customer_id = c.customer_id
WHERE o.order_date >= '2024-06-01'
LIMIT 10
SETTINGS max_bytes_in_join = 104857600;  -- 限制 JOIN 使用 100MB

-- ============================================================================
-- 7. 高级 JOIN 优化技巧
-- ============================================================================

-- 技巧 1: 使用 ANY 关键字避免重复
-- ANY LEFT JOIN 在右表匹配到第一行后停止，避免重复
SELECT
    o.order_id,
    o.amount,
    c.name
FROM orders o
ANY LEFT JOIN customers_duplicate c ON o.customer_id = c.customer_id
WHERE o.order_date >= '2024-06-01'
  AND o.customer_id = 123
LIMIT 10;

-- 技巧 2: ASOF JOIN（时间序列 JOIN）
-- 适用于按时间匹配最近值的场景
CREATE TABLE prices
(
    product_id UInt32,
    price Decimal(12, 2),
    effective_date Date
)
ENGINE = MergeTree()
ORDER BY (product_id, effective_date);

INSERT INTO prices
SELECT
    number % 100 as product_id,
    (rand() % 10000)::Decimal(12, 2) / 100 as price,
    toDate('2024-01-01') + (number % 365) as effective_date
FROM numbers(10000);

-- ASOF JOIN：为每个订单匹配最近的价格
SELECT
    o.order_id,
    o.product_id,
    o.amount,
    p.price,
    p.effective_date
FROM orders o
ASOF LEFT JOIN prices p ON o.product_id = p.product_id AND o.order_date >= p.effective_date
WHERE o.order_date >= '2024-06-01'
  AND o.order_date < '2024-06-07'
LIMIT 20;

-- 技巧 3: 使用分片键优化分布式 JOIN
-- 确保 JOIN 键与分片键一致，避免数据跨节点传输
-- 创建同分片键的分布式表
CREATE TABLE orders_sharded AS orders
ENGINE = Distributed('treasurycluster', 'perf_test', 'orders', customer_id);
-- 分片键为 customer_id，与 JOIN 键一致，可避免 GLOBAL JOIN

-- 技巧 4: 预聚合减少 JOIN 数据量
-- 先聚合再 JOIN
SELECT
    c.tier,
    s.total_amount,
    s.order_count
FROM (
    SELECT customer_id, sum(amount) as total_amount, count() as order_count
    FROM orders
    WHERE order_date >= '2024-01-01'
    GROUP BY customer_id
) s
INNER JOIN customers c ON s.customer_id = c.customer_id
ORDER BY s.total_amount DESC;

-- ============================================================================
-- 8. JOIN 策略选择指南
-- ============================================================================
-- 【最佳实践】
--
-- 场景 1: 维度表 < 100 万行，查询频繁
--   → 使用 Dictionary（dictGet），性能最优
--   示例: 用户信息、产品信息、配置表
--
-- 场景 2: 维度表 < 1GB，查询不频繁
--   → 使用 Hash Join（默认），简单直接
--   示例: 偶尔关联查询的小表
--
-- 场景 3: 维度表 > 1GB，内存不足
--   → 使用 Merge Join 或 Partial Merge Join
--   示例: 历史数据关联
--
-- 场景 4: 分布式环境，维度表小
--   → 使用 GLOBAL JOIN，确保数据一致性
--   示例: 跨分片关联维度表
--
-- 场景 5: 只需要判断存在性
--   → 使用 IN 子查询，比 JOIN 更快
--   示例: 过滤有订单的客户
--
-- 场景 6: 需要关联但不需要返回右表字段
--   → 使用 IN 或 EXISTS，避免 JOIN 开销
--   示例: 筛选特定条件下的记录
--
-- 场景 7: 维度表需要跨查询共享
--   → 使用 Dictionary，数据在内存中共享
--   示例: 全局配置、公共维度

-- ============================================================================
-- 清理
-- ============================================================================
DROP DATABASE IF EXISTS perf_test;