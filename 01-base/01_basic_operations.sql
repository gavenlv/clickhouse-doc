-- =====================================================
-- 01 - ClickHouse 基础操作示例
-- =====================================================
-- 集群: treasurycluster (2副本)
-- 时间: 0-20分钟
-- =====================================================

-- -----------------------------------------------------
-- 1. ClickHouse 基础概念
-- -----------------------------------------------------

-- ┌─────────────────────────────────────────────────────────────┐
-- │              ClickHouse 核心概念                              │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                              │
-- │  1. 列式存储 (Columnar Storage)                              │
-- │     - 数据按列存储，每列一个文件                              │
-- │     - 只读取需要的列，减少 I/O                               │
-- │     - 更高压缩率（同类数据更易压缩）                          │
-- │                                                              │
-- │  2. 向量化执行 (Vectorized Execution)                        │
-- │     - SIMD 指令一次处理整列数据                              │
-- │     - 比传统行式执行快 10-100 倍                             │
-- │                                                              │
-- │  3. 稀疏索引 (Sparse Index)                                 │
-- │     - 每 8192 行一个索引标记 (mark)                          │
-- │     - 快速定位数据区域，减少扫描                             │
-- │                                                              │
-- │  4. MergeTree 引擎核心机制                                  │
-- │     - 数据按 PARTITION 分区存储                              │
-- │     - 后台自动合并 (Merge) 小数据块                          │
-- │     - 支持副本复制保证高可用                                 │
-- │                                                              │
-- └─────────────────────────────────────────────────────────────┘

-- -----------------------------------------------------
-- 2. 复制集群原理
-- -----------------------------------------------------

-- ┌─────────────────────────────────────────────────────────────┐
-- │           ClickHouse ReplicatedMergeTree 复制原理               │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                              │
-- │   ZooKeeper / ClickHouse Keeper                              │
-- │         │                                                     │
-- │         │ 1. 写入请求                                        │
-- │         ▼                                                    │
-- │   ┌─────────────┐      ┌─────────────┐                     │
-- │   │  Replica 1  │ ───▶ │  Replica 2  │                     │
-- │   │  (primary)  │      │  (backup)   │                     │
-- │   └─────────────┘      └─────────────┘                     │
-- │         │                      │                             │
-- │         ▼                      ▼                             │
-- │   /clickhouse/tables/{shard}/{table}                        │
-- │                                                              │
-- │   复制流程:                                                  │
-- │   1. 写入到 Replica 1 (primary)                            │
-- │   2. Primary 写入本地 + 记录 ZooKeeper 日志                  │
-- │   3. Replica 2 从 ZooKeeper 拉取日志                       │
-- │   4. Replica 2 从 Primary 拉取数据                          │
-- │   5. 两副本数据最终一致                                      │
-- │                                                              │
-- └─────────────────────────────────────────────────────────────┘

-- ========================================
-- 1. 创建普通 MergeTree 表（生产环境：使用复制引擎 + ON CLUSTER）
-- ========================================
create database if not exists test;
use test;

drop TABLE if EXISTS test_users ON CLUSTER treasurycluster SYNC;
CREATE TABLE IF NOT EXISTS test_users ON CLUSTER 'treasurycluster' (
    id UInt64,
    name String,
    email String,
    age UInt8,
    created_at DateTime DEFAULT now(),
    updated_at DateTime DEFAULT now()
) ENGINE = ReplicatedMergeTree
ORDER BY id;

-- 查看表结构
DESCRIBE test_users;

-- 查看创建语句
SHOW CREATE test_users;

-- ┌─────────────────────────────────────────────────────────────┐
-- │           插入数据原理                                         │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                              │
-- │  ClickHouse 插入流程:                                        │
-- │                                                              │
-- │  1. Client 发送 INSERT 请求                                   │
-- │  2. Server 接收数据，创建一个 Block (数据块)                   │
-- │  3. Block 写入到本地存储 (part 目录)                         │
-- │  4. 对于复制表:                                              │
-- │     - 记录 ZooKeeper 日志                                    │
-- │     - 副本异步拉取并应用                                      │
-- │                                                              │
-- │  关键特性:                                                    │
-- │  - 插入数据最终一致 (最终一致性)                               │
-- │  - 去重机制: deduplicating-inserts-on-retries               │
-- │  - 幂等性: 相同数据重复插入不会产生重复                       │
-- │                                                              │
-- └─────────────────────────────────────────────────────────────┘

-- ========================================
-- 2. 插入数据
-- ========================================
INSERT INTO test_users (id, name, email, age) VALUES
(1, 'Alice', 'alice@example.com', 25),
(2, 'Bob', 'bob@example.com', 30),
(3, 'Charlie', 'charlie@example.com', 28),
(4, 'David', 'david@example.com', 35),
(5, 'Eve', 'eve@example.com', 22);
-- 利用mergetree 本身的特性去重 deduplicating-inserts-on-retries

SELECT * FROM test_users;



-- 批量插入（使用 VALUES）
INSERT INTO test_users  (id, name, email, age)  VALUES
(6, 'Frank', 'frank@example.com', 40),
(7, 'Grace', 'grace@example.com', 29);

-- 批量插入（使用 SELECT）
INSERT INTO test_users (id, name, email, age)
SELECT
    number + 8 as id,
    concat('User_', toString(number)) as name,
    concat('user', toString(number), '@example.com') as email,
    20 + (number % 30) as age
FROM numbers(5);

-- ┌─────────────────────────────────────────────────────────────┐
-- │           查询执行原理                                          │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                              │
-- │  ClickHouse 查询执行流程:                                     │
-- │                                                              │
-- │  1. Parser: 解析 SQL 为 AST                                   │
-- │  2. Analyzer: 分析和验证 AST                                  │
-- │  3. Optimizer: 优化执行计划                                   │
-- │  4. Executer: 执行查询                                        │
-- │                                                              │
-- │  列式存储查询优化:                                             │
-- │                                                              │
-- │  SELECT name, age FROM users WHERE age > 25                  │
-- │                                                              │
-- │  行式存储: 读取整行 → 过滤 → 返回列                           │
-- │  列式存储: 只读取 name, age 列 → 过滤 → 返回                  │
-- │                                                              │
-- │  优势:                                                        │
-- │  - 减少 I/O (只读需要的列)                                    │
-- │  - CPU 缓存友好 (列数据连续)                                   │
-- │  - 向量化执行 (SIMD)                                          │
-- │                                                              │
-- └─────────────────────────────────────────────────────────────┘

-- ========================================
-- 3. 基本查询
-- ========================================
-- 查询所有数据
SELECT * FROM test_users;

-- 查询特定列
SELECT id, name, email FROM test_users;

-- 使用 WHERE 条件
SELECT * FROM test_users WHERE age > 30;

-- 使用 ORDER BY 排序
SELECT * FROM test_users ORDER BY age DESC LIMIT 5;

-- 使用 LIMIT 限制结果数量
SELECT * FROM test_users LIMIT 3;

-- ┌─────────────────────────────────────────────────────────────┐
-- │           聚合查询原理                                          │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                              │
-- │  ClickHouse 聚合执行:                                         │
-- │                                                              │
-- │  1. 读取数据块 (列式)                                        │
-- │  2. 执行聚合函数 (向量化)                                     │
-- │  3. 合并中间结果                                             │
-- │  4. 返回最终结果                                             │
-- │                                                              │
-- │  聚合函数状态 (State Functions):                              │
-- │                                                              │
-- │  - sumState(x): 返回聚合中间状态                              │
-- │  - sumMerge(state): 合并多个状态                              │
-- │                                                              │
-- │  优势:                                                        │
-- │  - 增量聚合 (适合大数据流)                                    │
-- │  - 支持分布式聚合                                             │
-- │  - 内存效率高                                                │
-- │                                                              │
-- └─────────────────────────────────────────────────────────────┘

-- ========================================
-- 4. 聚合查询
-- ========================================
-- COUNT 统计
SELECT count() as total_users FROM test_users;

-- SUM/AVG/MAX/MIN
SELECT
    count() as total_count,
    sum(age) as total_age,
    avg(age) as avg_age,
    min(age) as min_age,
    max(age) as max_age
FROM test_users;

-- GROUP BY 分组
SELECT age, count() as user_count FROM test_users GROUP BY age ORDER BY age;

-- HAVING 过滤分组
SELECT age, count() as user_count
FROM test_users
GROUP BY age
HAVING count() >= 2
ORDER BY age;

-- ┌─────────────────────────────────────────────────────────────┐
-- │           JOIN 操作原理                                        │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                              │
-- │  ClickHouse JOIN 类型:                                        │
-- │                                                              │
-- │  - INNER JOIN: 只返回匹配的行                                 │
-- │  - LEFT JOIN: 返回左表所有行                                  │
-- │  - RIGHT JOIN: 返回右表所有行                                  │
-- │  - FULL JOIN: 返回所有行                                      │
-- │  - CROSS JOIN: 笛卡尔积                                      │
-- │                                                              │
-- │  JOIN 执行优化:                                               │
-- │                                                              │
-- │  1. 右表作为驱动表 (Broadcast Join)                          │
-- │  2. 右表数据加载到内存                                        │
-- │  3. 扫描左表并查找匹配                                        │
-- │                                                              │
-- │  最佳实践:                                                    │
-- │  - 右表尽量小 (适合内存)                                      │
-- │  - 使用 GLOBAL 关键字做全局 JOIN                             │
-- │  - 避免大表 JOIN                                              │
-- │                                                              │
-- └─────────────────────────────────────────────────────────────┘

-- ========================================
-- 5. 高级查询
-- ========================================
-- JOIN 操作
CREATE TABLE IF NOT EXISTS test_orders ON CLUSTER 'treasurycluster' (
    order_id UInt64,
    user_id UInt64,
    product_id UInt32,
    amount Decimal(10, 2),
    order_date DateTime DEFAULT now()
) ENGINE = ReplicatedMergeTree
ORDER BY order_id;

INSERT INTO test_orders (order_id, user_id, product_id, amount) VALUES
(1, 1, 101, 99.99),
(2, 1, 102, 49.99),
(3, 2, 103, 199.99),
(4, 3, 101, 99.99),
(5, 4, 104, 149.99);

-- INNER JOIN
SELECT
    u.name,
    u.email,
    o.order_id,
    o.amount
FROM test_users u
INNER JOIN test_orders o ON u.id = o.user_id
ORDER BY u.id, o.order_id;

-- LEFT JOIN
SELECT
    u.name,
    count(o.order_id) as order_count,
    sum(o.amount) as total_spent
FROM test_users u
LEFT JOIN test_orders o ON u.id = o.user_id
GROUP BY u.id, u.name
ORDER BY total_spent DESC;

-- ┌─────────────────────────────────────────────────────────────┐
-- │           窗口函数原理                                         │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                              │
-- │  窗口函数 vs 聚合函数:                                        │
-- │                                                              │
-- │  聚合函数: GROUP BY 后返回单行                                │
-- │  窗口函数: 不减少行数，每行有聚合结果                          │
-- │                                                              │
-- │  常用窗口函数:                                                │
-- │                                                              │
-- │  - ROW_NUMBER(): 行号                                        │
-- │  - RANK(): 排名 (有间隙)                                     │
-- │  - DENSE_RANK(): 密集排名 (无间隙)                            │
-- │  - LAG(col): 前一行值                                        │
-- │  - LEAD(col): 后一行值                                       │
-- │  - FIRST_VALUE(col): 窗口起始值                              │
-- │  - LAST_VALUE(col): 窗口结束值                               │
-- │  - SUM(col) OVER (): 累计 sum                               │
-- │                                                              │
-- │  执行原理:                                                    │
-- │  1. 按 PARTITION 分区                                        │
-- │  2. 按 ORDER BY 排序                                         │
-- │  3. 按 ROWS/RANGE 滑动窗口                                   │
-- │  4. 计算窗口函数                                             │
-- │                                                              │
-- └─────────────────────────────────────────────────────────────┘

-- ========================================
-- 6. 窗口函数
-- ========================================
SELECT
    id,
    name,
    age,
    ROW_NUMBER() OVER (ORDER BY age DESC) as age_rank,
    RANK() OVER (ORDER BY age DESC) as age_rank_dense,
    DENSE_RANK() OVER (ORDER BY age DESC) as age_rank_dense2,
    NTILE(4) OVER (ORDER BY age DESC) as age_quartile,
    LAG(age) OVER (ORDER BY age DESC) as prev_age,
    LEAD(age) OVER (ORDER BY age DESC) as next_age
FROM test_users
ORDER BY age DESC;

-- ┌─────────────────────────────────────────────────────────────┐
-- │           CTE (公共表表达式) 原理                              │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                              │
-- │  CTE 特点:                                                   │
-- │                                                              │
-- │  - 临时结果集，只在查询期间存在                               │
-- │  - 提高可读性和可维护性                                       │
-- │  - 支持递归查询 (WITH RECURSIVE)                             │
-- │                                                              │
-- │  vs 子查询:                                                  │
-- │                                                              │
-- │  CTE: 可多次引用，性能更好                                   │
-- │  子查询: 每次执行一次                                         │
-- │                                                              │
-- │  性能:                                                       │
-- │  - ClickHouse 对 CTE 进行了优化                              │
-- │  - 子查询物化 (Materialize)                                   │
-- │  - 避免重复计算                                              │
-- │                                                              │
-- └─────────────────────────────────────────────────────────────┘

-- ========================================
-- 7. CTE (Common Table Expression)
-- ========================================
WITH user_stats AS (
    SELECT
        id,
        name,
        age,
        CASE
            WHEN age < 25 THEN 'Young'
            WHEN age < 35 THEN 'Adult'
            ELSE 'Senior'
        END as age_group
    FROM test_users
)
SELECT
    age_group,
    count() as user_count,
    avg(age) as avg_age
FROM user_stats
GROUP BY age_group
ORDER BY avg_age;

-- ┌─────────────────────────────────────────────────────────────┐
-- │           条件表达式原理                                      │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                              │
-- │  ClickHouse 条件函数:                                         │
-- │                                                              │
-- │  1. CASE WHEN (标准 SQL)                                    │
-- │     - CASE WHEN condition THEN result                        │
-- │       [WHEN ...] [ELSE result] END                         │
-- │                                                              │
-- │  2. if(condition, true_value, false_value)                 │
-- │     - 简化的三元表达式                                        │
-- │     - 向量化执行，高性能                                      │
-- │                                                              │
-- │  3. multiIf(cond1, val1, cond2, val2, ..., default)       │
-- │     - 多个条件判断                                           │
-- │     - 比嵌套 if 性能更好                                     │
-- │                                                              │
-- │  执行优化:                                                    │
-- │  - 短路求值 (部分条件)                                       │
-- │  - 向量化执行                                                │
-- │                                                              │
-- └─────────────────────────────────────────────────────────────┘

-- ========================================
-- 8. 条件表达式
-- ========================================
SELECT
    id,
    name,
    age,
    CASE
        WHEN age < 25 THEN 'Young'
        WHEN age < 35 THEN 'Adult'
        WHEN age < 50 THEN 'Middle-aged'
        ELSE 'Senior'
    END as age_category,
    multiIf(age < 25, 'Young', age < 35, 'Adult', 'Senior') as age_category2
FROM test_users
ORDER BY age;

-- IF 函数
SELECT
    id,
    name,
    age,
    if(age >= 30, 'Senior Member', 'Junior Member') as membership_level
FROM test_users
ORDER BY age DESC;

-- ┌─────────────────────────────────────────────────────────────┐
-- │           字符串函数原理                                      │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                              │
-- │  ClickHouse 字符串处理:                                       │
-- │                                                              │
-- │  1. 字符串函数 (Vectorized)                                  │
-- │     - length(), lower(), upper()                            │
-- │     - substring(), splitByChar()                            │
-- │     - replace(), extract()                                  │
-- │                                                              │
-- │  2. 字符串索引                                               │
-- │     - 主键索引不支持字符串范围查询                             │
-- │     - 使用跳数索引优化 (minmax, set, bloom_filter)          │
-- │                                                              │
-- │  3. 字符串存储优化                                           │
-- │     - LowCardinality(String): 低基数字符串                   │
-- │     - FixedString(n): 固定长度字符串                         │
-- │     - UUID: 专用 UUID 类型                                   │
-- │                                                              │
-- │  性能优化:                                                   │
-- │  - 使用 LowCardinality 减少内存                              │
-- │  - 避免字符串正则表达式                                      │
-- │  - 使用 prewhere 减少字符串列读取                            │
-- │                                                              │
-- └─────────────────────────────────────────────────────────────┘

-- ========================================
-- 9. 字符串操作
-- ========================================
SELECT
    id,
    name,
    email,
    length(name) as name_length,
    lower(name) as name_lower,
    upper(name) as name_upper,
    substring(name, 1, 3) as name_prefix,
    splitByChar('@', email)[1] as email_username,
    replace(email, 'example.com', 'test.com') as new_email
FROM test_users
LIMIT 5;

-- ┌─────────────────────────────────────────────────────────────┐
-- │           日期时间函数原理                                     │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                              │
-- │  ClickHouse 日期时间类型:                                     │
-- │                                                              │
-- │  - Date: 日期 (2024-01-01)                                  │
-- │  - DateTime: 日期时间 (秒精度)                               │
-- │  - DateTime64: 日期时间 (纳秒精度)                           │
-- │                                                              │
-- │  常用函数:                                                   │
-- │                                                              │
-- │  - toDate(), toDateTime(), toDateTime64()                  │
-- │  - toYYYYMM(), toYYYYMMDD(), toStartOfMonth()              │
-- │  - dateDiff(), age()                                        │
-- │  - formatDateTime()                                          │
-- │                                                              │
-- │  时区处理:                                                   │
-- │  - 设置时区: timezone = 'Asia/Shanghai'                     │
--   - 存储 UTC 时间，显示转换                                     │
-- │                                                              │
-- │  性能优化:                                                   │
-- │  - Date 类型比 DateTime 更节省存储                           │
-- │  - 按日期分区减少扫描                                        │
-- │  - 预计算常用时间聚合                                         │
-- │                                                              │
-- └─────────────────────────────────────────────────────────────┘

-- ========================================
-- 10. 日期时间操作
-- ========================================
SELECT
    id,
    name,
    created_at,
    toDate(created_at) as date_only,
    toYYYYMM(created_at) as year_month,
    toStartOfMonth(created_at) as month_start,
    dateDiff('day', created_at, now()) as days_since_creation,
    formatDateTime(created_at, '%Y-%m-%d %H:%M:%S') as formatted_date
FROM test_users
ORDER BY created_at;

-- ┌─────────────────────────────────────────────────────────────┐
-- │           数组函数原理                                        │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                              │
-- │  ClickHouse 原生数组支持:                                     │
-- │                                                              │
-- │  - Array(T): 数组类型                                        │
-- │  - 数组元素可以是任意类型                                      │
-- │  - 支持嵌套数组                                               │
-- │                                                              │
-- │  常用数组函数:                                                │
-- │                                                              │
-- │  - length(arr): 数组长度                                     │
-- │  - arr[index]: 访问元素 (1-based)                           │
-- │  - has(arr, elem): 检查元素存在                              │
-- │  - arrayJoin(arr): 数组展开 (生成多行)                        │
-- │  - arraySort(), arrayReverse()                              │
-- │  - arrayFilter(), arrayMap()                                │
-- │                                                              │
-- │  数组聚合:                                                   │
-- │  - groupArray(): 将列值聚合为数组                            │
-- │  - groupUniqArray(): 去重后聚合                              │
-- │                                                              │
-- │  使用场景:                                                   │
-- │  - 存储多值字段                                               │
-- │  - 用户标签、产品属性                                         │
-- │  - 实时统计                                                   │
-- │                                                              │
-- └─────────────────────────────────────────────────────────────┘

-- ========================================
-- 11. 数组操作
-- ========================================
CREATE TABLE IF NOT EXISTS test_products ON CLUSTER 'treasurycluster' (
    id UInt64,
    name String,
    tags Array(String),
    prices Array(Decimal(10, 2))
) ENGINE = ReplicatedMergeTree
ORDER BY id;

INSERT INTO test_products VALUES
(1, 'Laptop', ['electronics', 'computer', 'work'], [999.99, 899.99]),
(2, 'Chair', ['furniture', 'office', 'ergonomic'], [199.99, 179.99]),
(3, 'Book', ['education', 'reading'], [29.99, 24.99, 19.99]);

-- 数组操作
SELECT
    name,
    tags,
    length(tags) as tag_count,
    tags[1] as first_tag,
    has(tags, 'electronics') as has_electronics,
    arrayJoin(tags) as tag_expanded
FROM test_products
ORDER BY id;

-- 数组聚合操作
SELECT
    name,
    max(prices) as max_price,
    min(prices) as min_price,
    avg(arrayJoin(prices)) as avg_price
FROM test_products
GROUP BY name
ORDER BY name;

-- ========================================
-- 12. 清理测试表（生产环境：使用 ON CLUSTER SYNC 确保集群范围删除）
-- ========================================
DROP TABLE IF EXISTS test_users ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS test_orders ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS test_products ON CLUSTER 'treasurycluster' SYNC;

-- ========================================
-- 13. 查看所有表
-- ========================================
SHOW TABLES;

-- ┌─────────────────────────────────────────────────────────────┐
-- │           数据去重与幂等性原理                                  │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                              │
-- │  ClickHouse 去重机制:                                         │
-- │                                                              │
-- │  1. 插入去重 (Deduplicating Inserts)                         │
-- │     - 相同插入块 (Block) 重复写入会被去重                      │
-- │     - 基于 block data hash 判断                               │
-- │     - 幂等性保证                                             │
-- │                                                              │
-- │  2. ReplacingMergeTree                                        │
-- │     - 指定 version 字段                                      │
-- │     - 保留最大 version 的记录                                │
-- │     - 使用 FINAL 或 argMax 查询                              │
-- │                                                              │
-- │  3. CollapsingMergeTree                                       │
-- │     - 使用 sign 字段 (+1/-1)                                 │
-- │     - 插入 +1 和 -1 相互抵消                                  │
-- │     - 适合增量更新                                           │
-- │                                                              │
-- │  4. VersionedCollapsingMergeTree                            │
-- │     - sign + version 组合                                    │
-- │     - 更严格的版本控制                                        │
-- │                                                              │
-- │  合并时机:                                                   │
-- │  - 后台自动合并 (异步)                                       │
-- │  - OPTIMIZE 手动触发                                          │
-- │  - 查询时 (仅 FINAL)                                         │
-- │                                                              │
-- │  注意事项:                                                    │
-- │  - FINAL 性能较差，慎用                                      │
-- │  - 推荐使用 argMax 手动去重                                   │
-- │  - 定期 OPTIMIZE 低峰期执行                                   │
-- │                                                              │
-- └─────────────────────────────────────────────────────────────┘

-- ========================================
-- 14. 数据去重与幂等性测试
-- ========================================
-- 说明：解决上游写入一半程序崩溃时，如何保证 ClickHouse 数据不重复

-- ========================================
-- 场景 1：ReplacingMergeTree - 保留最新版本
-- ========================================
-- 适用场景：用户资料更新、配置信息、状态变更

DROP TABLE IF EXISTS dedup_user_profiles ON CLUSTER 'treasurycluster' SYNC;

CREATE TABLE dedup_user_profiles ON CLUSTER 'treasurycluster' (
    user_id UInt64,
    profile_id String,       -- 业务唯一ID
    name String,
    email String,
    phone String,
    updated_at DateTime,
    version UInt64,           -- 版本号（必需）
    inserted_at DateTime DEFAULT now()
) ENGINE = ReplicatedReplacingMergeTree(version)  -- version 指定去重字段
PARTITION BY toYYYYMM(updated_at)
ORDER BY (user_id, profile_id)  -- 唯一键
SETTINGS index_granularity = 8192;

-- 插入初始数据（version 1）
INSERT INTO dedup_user_profiles VALUES
(1001, 'prof-001', '张三', 'zhangsan@example.com', '13800000001', '2024-01-01 10:00:00', 1, now()),
(1002, 'prof-002', '李四', 'lisi@example.com', '13800000002', '2024-01-01 10:00:00', 1, now()),
(1003, 'prof-003', '王五', 'wangwu@example.com', '13800000003', '2024-01-01 10:00:00', 1, now());

-- 模拟程序崩溃：重复插入相同的数据
-- 即使重复插入，也不会产生重复数据（相同的 profile_id + version）
INSERT INTO dedup_user_profiles VALUES
(1001, 'prof-001', '张三', 'zhangsan@example.com', '13800000001', '2024-01-01 10:00:00', 1, now()),
(1002, 'prof-002', '李四', 'lisi@example.com', '13800000002', '2024-01-01 10:00:00', 1, now()),
(1003, 'prof-003', '王五', 'wangwu@example.com', '13800000003', '2024-01-01 10:00:00', 1, now());

-- 查询原始数据（可能看到重复）
SELECT * FROM dedup_user_profiles
ORDER BY user_id, profile_id, version;

-- 查询去重后的数据（使用 argMax 手动去重 - 推荐）
SELECT
    user_id,
    profile_id,
    argMax(name, version) as name,
    argMax(email, version) as email,
    argMax(phone, version) as phone,
    argMax(updated_at, version) as updated_at,
    max(version) as latest_version
FROM dedup_user_profiles
GROUP BY user_id, profile_id
ORDER BY user_id;

-- 更新用户资料（version 2）
INSERT INTO dedup_user_profiles VALUES
(1001, 'prof-001', '张三丰', 'zhangsanfeng@example.com', '13800000011', '2024-01-01 11:00:00', 2, now()),
(1002, 'prof-002', '李四光', 'lisiguang@example.com', '13800000012', '2024-01-01 11:00:00', 2, now());

-- 再次查询去重后的数据（应该看到更新的资料）
SELECT
    user_id,
    profile_id,
    argMax(name, version) as name,
    argMax(email, version) as email,
    max(version) as latest_version
FROM dedup_user_profiles
GROUP BY user_id, profile_id
ORDER BY user_id;

-- 使用 FINAL 关键字查询（自动去重，但性能较差）
SELECT * FROM dedup_user_profiles FINAL
ORDER BY user_id;

-- 手动触发合并
OPTIMIZE TABLE dedup_user_profiles FINAL;

-- 再次查询（已合并，无重复）
SELECT * FROM dedup_user_profiles
ORDER BY user_id, version;

-- ========================================
-- 场景 2：CollapsingMergeTree - 增量更新
-- ========================================
-- 适用场景：库存管理、订单状态、增量计数器

DROP TABLE IF EXISTS dedup_inventory ON CLUSTER 'treasurycluster' SYNC;

CREATE TABLE dedup_inventory ON CLUSTER 'treasurycluster' (
    product_id UInt64,
    product_name String,
    quantity Int32,
    sign Int8,               -- 1 for insert, -1 for delete（必需）
    timestamp DateTime,
    inserted_at DateTime DEFAULT now()
) ENGINE = ReplicatedCollapsingMergeTree(sign)  -- sign 指定字段
PARTITION BY toYYYYMM(timestamp)
ORDER BY product_id
SETTINGS index_granularity = 8192;

-- 初始化库存（sign = 1）
INSERT INTO dedup_inventory VALUES
(101, '产品A', 100, 1, '2024-01-01 10:00:00', now()),
(102, '产品B', 50, 1, '2024-01-01 10:00:00', now()),
(103, '产品C', 75, 1, '2024-01-01 10:00:00', now());

-- 销售商品（sign = -1）
-- 如果程序崩溃，重试时再次执行，结果也是正确的
INSERT INTO dedup_inventory VALUES
(101, '产品A', 10, -1, '2024-01-01 11:00:00', now()),
(102, '产品B', 5, -1, '2024-01-01 11:00:00', now());

-- 进货（sign = 1）
INSERT INTO dedup_inventory VALUES
(101, '产品A', 20, 1, '2024-01-01 12:00:00', now()),
(103, '产品C', 10, 1, '2024-01-01 12:00:00', now());

-- 查询当前库存（使用 GROUP BY 抵消 sign）
SELECT
    product_id,
    argMax(product_name, timestamp) as product_name,
    sum(quantity * sign) as current_inventory,
    max(timestamp) as last_updated
FROM dedup_inventory
GROUP BY product_id
ORDER BY product_id;

-- 使用 FINAL 查询
SELECT * FROM dedup_inventory FINAL
ORDER BY product_id, timestamp;
