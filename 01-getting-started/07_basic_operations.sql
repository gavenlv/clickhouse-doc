-- ============================================================
-- 文件: 01-getting-started/07_basic_operations.sql
-- 学习目标: 掌握 ClickHouse 基础操作 + 理解底层原理（MergeTree/向量化/稀疏索引）
-- 深度标准: 原理 + 场景 + 对比 + 可运行
-- 集群: treasurycluster (CH 25.12.1.649, 2 副本)
-- 前置: 无（自包含测试数据，按顺序执行）
-- ============================================================
--
-- 本文件章节:
--   1.  ClickHouse 核心概念（列存/向量化/稀疏索引）
--   2.  复制集群原理与 MergeTree 引擎
--   3.  插入数据原理与幂等性
--   4.  基本查询与列式存储优势
--   5.  聚合查询原理
--   6.  JOIN 操作与优化
--   7.  窗口函数
--   8.  CTE 公共表表达式
--   9.  条件表达式（multiIf vs CASE WHEN）
--   10. 字符串操作
--   11. 日期时间操作
--   12. 数组操作（arrayJoin 反聚合）
--   13. 数据去重与幂等性入门
--   14. 清理
-- ============================================================

-- ============================================================
-- 1. ClickHouse 核心概念
-- ============================================================
-- 【原理】ClickHouse 三大支柱：
--   ① 列式存储：每列独立存储，查询只读需要的列，I/O 减少 50x
--   ② 向量化执行：SIMD 指令一次处理 8192 行（一个 vector），CPU 效率提升 10x
--   ③ 稀疏索引：每 8192 行一个 mark，索引极小常驻内存，二分查找定位 granule
--
-- 【对比】行式 vs 列式存储查询 sum(amount) WHERE region='East':
--   行式: 读整行 × 1亿行 → 逐行判断 → I/O 100GB, CPU 逐行分支
--   列式: 只读 amount+region 列 → SIMD 累加 → I/O 2GB, CPU 并行
--   总加速: I/O 省 50x × CPU 省 10x ≈ 100x+
--
-- 【场景】OLAP 分析查询（聚合、过滤、分组），非 OLTP 事务

-- ┌─────────────────────────────────────────────────────────────┐
-- │              ClickHouse 核心概念                              │
-- ├─────────────────────────────────────────────────────────────┤
-- │  1. 列式存储 (Columnar Storage)                              │
-- │     - 数据按列存储，每列一个文件                              │
-- │     - 只读取需要的列，减少 I/O                               │
-- │     - 更高压缩率（同类数据更易压缩）                          │
-- │                                                              │
-- │  2. 向量化执行 (Vectorized Execution)                        │
-- │     - SIMD 指令一次处理整列数据（8192 行一个 vector）         │
-- │     - 比传统行式执行快 10-100 倍                             │
-- │                                                              │
-- │  3. 稀疏索引 (Sparse Index)                                 │
-- │     - 每 8192 行一个索引标记 (mark)                          │
-- │     - 二分查找定位数据区域，减少扫描                          │
-- │                                                              │
-- │  4. MergeTree 引擎核心机制                                  │
-- │     - 数据按 PARTITION 分区存储                              │
-- │     - 后台异步合并 (Merge) 小 part → 大 part                │
-- │     - 支持副本复制保证高可用                                 │
-- │                                                              │
-- └─────────────────────────────────────────────────────────────┘

-- ============================================================
-- 2. 复制集群原理与 MergeTree 引擎
-- ============================================================
-- 【原理】ReplicatedMergeTree 复制流程:
--   1. 写入任意副本 → 该副本写本地 part + 在 ZK 的 log/ 节点追加日志
--   2. 其他副本监听 ZK log/，发现新日志
--   3. 其他副本通过 HTTP 从源副本拉取 part 数据
--   4. 最终一致（异步，通常秒级）
--
-- 【为什么用 ZK】ZK 只传"日志"（哪条 INSERT），不传数据（数据走 HTTP）
--   ZK 保证日志顺序，所有副本按相同顺序应用
--
-- 【默认路径宏】本集群已配置 default_replica_path 和 default_replica_name
--   所以 ReplicatedMergeTree() 不带参数也能工作
--   宏自动展开为 /clickhouse/tables/{shard}/{table} 和 {replica}

-- ┌─────────────────────────────────────────────────────────────┐
-- │           ClickHouse ReplicatedMergeTree 复制原理               │
-- ├─────────────────────────────────────────────────────────────┤
-- │   ZooKeeper / ClickHouse Keeper                              │
-- │         │  1. 写入日志                                       │
-- │         ▼                                                   │
-- │   /clickhouse/tables/{shard}/{table}                        │
-- │         │  2. 监听变化                                       │
-- │         ▼                                                   │
-- │   ┌─────────────┐      ┌─────────────┐                     │
-- │   │  Replica 1  │ ───▶ │  Replica 2  │                     │
-- │   │  (写入端)   │      │  (拉取端)   │                     │
-- │   └─────────────┘      └─────────────┘                     │
-- │   复制流程:                                                  │
-- │   1. 写入到 Replica 1                                       │
-- │   2. R1 写本地 part + 记录 ZK 日志                           │
-- │   3. R2 从 ZK 拉取日志                                      │
-- │   4. R2 从 R1 HTTP 拉取 part 数据                          │
-- │   5. 两副本最终一致                                          │
-- └─────────────────────────────────────────────────────────────┘

-- 创建独立数据库，避免与其他章节冲突
CREATE DATABASE IF NOT EXISTS base_test ON CLUSTER 'treasurycluster';
USE base_test;

-- ========================================
-- 创建普通 MergeTree 表（生产环境：使用复制引擎 + ON CLUSTER）
-- ========================================
-- 【原理】ENGINE = ReplicatedMergeTree() 使用默认宏路径
--   ORDER BY 决定数据物理排序 + 主键稀疏索引
--   PARTITION BY 决定数据分区（分区剪枝加速时间查询）
-- 【对比】MergeTree vs ReplicatedMergeTree:
--   MergeTree: 单机，无副本，测试用
--   ReplicatedMergeTree: 通过 ZK 复制，生产必备
-- 【坑】ReplicatedMergeTree 必须带括号()，否则语法错
-- 【坑】使用显式 ZK 路径（加 gs_ 前缀）避免与历史残留的 ZK 节点冲突
DROP TABLE IF EXISTS test_users ON CLUSTER 'treasurycluster' SYNC;

CREATE TABLE IF NOT EXISTS test_users ON CLUSTER 'treasurycluster' (
    id UInt64,
    name String,
    email String,
    age UInt8,
    created_at DateTime DEFAULT now(),
    updated_at DateTime DEFAULT now()
) ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/gs_test_users', '{replica}')
ORDER BY id;

-- 查看表结构
DESCRIBE test_users;

-- 查看创建语句（可看到 ZK 路径和副本名）
SHOW CREATE test_users;

-- ┌─────────────────────────────────────────────────────────────┐
-- │           插入数据原理                                         │
-- ├─────────────────────────────────────────────────────────────┤
-- │  ClickHouse 插入流程:                                        │
-- │  1. Client 发送 INSERT 请求                                   │
-- │  2. Server 接收数据，创建一个 Block (数据块)                   │
-- │  3. Block 写入到本地存储 (新 part 目录)                       │
-- │  4. 对于复制表:                                              │
-- │     - 记录 ZooKeeper 日志                                    │
-- │     - 副本异步拉取并应用                                      │
-- │                                                              │
-- │  关键特性:                                                    │
-- │  - 插入数据最终一致 (最终一致性)                               │
-- │  - 去重机制: deduplicating-inserts-on-retries               │
-- │    相同 block hash 重复写入会被去重（幂等性）                  │
-- │  - 不要小批量高频写入！会导致 part 爆炸 (Too many parts)      │
-- │                                                              │
-- └─────────────────────────────────────────────────────────────┘

-- ============================================================
-- 3. 插入数据原理与幂等性
-- ============================================================
-- 【原理】每次 INSERT 创建一个新 part，part 命名: {partition}_{min_block}_{max_block}_{level}
--   part 一旦写入不可修改（这是不支持 UPDATE 的根因）
--   后台异步合并小 part → 大 part
-- 【场景】批量写入（每次 1万~10万行），避免小批量高频写
-- 【坑】INSERT VALUES 中不能有行内注释（-- 注释），否则解析失败

INSERT INTO test_users (id, name, email, age) VALUES
(1, 'Alice', 'alice@example.com', 25),
(2, 'Bob', 'bob@example.com', 30),
(3, 'Charlie', 'charlie@example.com', 28),
(4, 'David', 'david@example.com', 35),
(5, 'Eve', 'eve@example.com', 22);

SELECT * FROM test_users;

-- 批量插入（使用 VALUES）
INSERT INTO test_users (id, name, email, age) VALUES
(6, 'Frank', 'frank@example.com', 40),
(7, 'Grace', 'grace@example.com', 29);

-- 批量插入（使用 SELECT 生成数据）
-- 【场景】生成测试数据、从其他表迁移数据
INSERT INTO test_users (id, name, email, age)
SELECT
    number + 8 AS id,
    concat('User_', toString(number)) AS name,
    concat('user', toString(number), '@example.com') AS email,
    20 + (number % 30) AS age
FROM numbers(5);

-- ┌─────────────────────────────────────────────────────────────┐
-- │           查询执行原理                                          │
-- ├─────────────────────────────────────────────────────────────┤
-- │  ClickHouse 查询执行流程:                                     │
-- │  1. Parser: 解析 SQL 为 AST                                   │
-- │  2. Analyzer: 分析和验证 AST                                  │
-- │  3. Optimizer: 优化执行计划（分区剪枝/列裁剪/谓词下推）        │
-- │  4. Executor: 并行执行（按 part 粒度并行扫描）                │
-- │                                                              │
-- │  列式存储查询优化:                                             │
-- │  SELECT name, age FROM users WHERE age > 25                  │
-- │  行式: 读整行 → 过滤 → 返回列（I/O 浪费）                    │
-- │  列式: 只读 name, age 列 → 过滤 → 返回（I/O 最小）           │
-- └─────────────────────────────────────────────────────────────┘

-- ============================================================
-- 4. 基本查询与列式存储优势
-- ============================================================
-- 【原理】列式存储只读需要的列，减少 I/O
-- 【对比】SELECT name, age 只读 2 列；SELECT * 读所有列（慢，慎用）

-- 查询所有数据（慎用 SELECT *，生产环境只查需要的列）
SELECT * FROM test_users;

-- 查询特定列（只读 name, age 列，I/O 最小）
SELECT id, name, email FROM test_users;

-- 使用 WHERE 条件（主键索引加速 id 查询）
SELECT * FROM test_users WHERE id = 3;

-- 非主键列查询（走全表扫描，可用跳数索引加速，见 05_indexes.sql）
SELECT * FROM test_users WHERE age > 30;

-- 使用 ORDER BY 排序
SELECT * FROM test_users ORDER BY age DESC LIMIT 5;

-- 使用 LIMIT 限制结果数量
SELECT * FROM test_users LIMIT 3;

-- ┌─────────────────────────────────────────────────────────────┐
-- │           聚合查询原理                                          │
-- ├─────────────────────────────────────────────────────────────┤
-- │  ClickHouse 聚合执行管道:                                    │
-- │  1. 读取数据块 (列式，只读聚合需要的列)                       │
-- │  2. 向量化聚合 (SIMD 累加每个分组的累加器)                   │
-- │  3. 合并中间结果 (跨 part / 跨线程)                          │
-- │  4. 返回最终结果                                             │
-- │                                                              │
-- │  聚合状态函数 (*State/*Merge):                                │
-- │  - sumState(x): 返回聚合中间状态（二进制）                    │
-- │  - sumMerge(state): 合并多个状态                             │
-- │  - 用于物化视图预聚合、分布式聚合                             │
-- │  详见 04-functions 和 08_materialized_views                  │
-- └─────────────────────────────────────────────────────────────┘

-- ============================================================
-- 5. 聚合查询原理
-- ============================================================
-- 【原理】CH 聚合走"分组聚合管道"：向量化 SIMD 计算每个分组的累加器
-- 【对比】CH 的 count() 比 MySQL count(*) 快 100x+，因列存+SIMD
-- 【坑】count() 是 CH 惯用写法（等价 count(*)），但更地道

-- COUNT 统计（CH 惯用 count()，非 count(*)）
SELECT count() AS total_users FROM test_users;

-- SUM/AVG/MAX/MIN
SELECT
    count() AS total_count,
    sum(age) AS total_age,
    avg(age) AS avg_age,
    min(age) AS min_age,
    max(age) AS max_age
FROM test_users;

-- GROUP BY 分组
SELECT age, count() AS user_count FROM test_users GROUP BY age ORDER BY age;

-- HAVING 过滤分组
SELECT age, count() AS user_count
FROM test_users
GROUP BY age
HAVING count() >= 2
ORDER BY age;

-- ┌─────────────────────────────────────────────────────────────┐
-- │           JOIN 操作原理                                        │
-- ├─────────────────────────────────────────────────────────────┤
-- │  ClickHouse JOIN 机制:                                        │
-- │  1. 右表作为驱动表 (Broadcast Join)                          │
-- │  2. 右表全量加载到内存                                        │
-- │  3. 扫描左表并查找匹配                                        │
-- │                                                              │
-- │  【坑】右表大（超内存）会导致 OOM                              │
-- │  【优化】                                                     │
-- │  - 右表尽量小 (适合内存)                                      │
-- │  - 分布式表用 GLOBAL JOIN 避免广播                            │
-- │  - 维度表用字典替代 JOIN（见 09_dictionaries.sql）           │
-- │  - 考虑去规范化（宽表）减少 JOIN                              │
-- └─────────────────────────────────────────────────────────────┘

-- ============================================================
-- 6. JOIN 操作与优化
-- ============================================================
-- 【原理】CH JOIN: 右表全量加载内存，扫描左表查找匹配
-- 【场景】事实表 JOIN 维度表（维度表小）
-- 【坑】右表大 → OOM；分布式 JOIN → 广播全表

CREATE TABLE IF NOT EXISTS test_orders ON CLUSTER 'treasurycluster' (
    order_id UInt64,
    user_id UInt64,
    product_id UInt32,
    amount Decimal(10, 2),
    order_date DateTime DEFAULT now()
) ENGINE = ReplicatedMergeTree()
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

-- LEFT JOIN + 聚合
SELECT
    u.name,
    count(o.order_id) AS order_count,
    sum(o.amount) AS total_spent
FROM test_users u
LEFT JOIN test_orders o ON u.id = o.user_id
GROUP BY u.id, u.name
ORDER BY total_spent DESC;

-- ┌─────────────────────────────────────────────────────────────┐
-- │           窗口函数原理                                         │
-- ├─────────────────────────────────────────────────────────────┤
-- │  窗口函数 vs 聚合函数:                                        │
-- │  聚合 (GROUP BY): 折叠行数，每分组一行                        │
-- │  窗口 (OVER): 不折叠，每行带窗口结果                          │
-- │                                                              │
-- │  默认 frame 隐患:                                             │
-- │  - ORDER BY 不写 frame → 默认 RANGE（同值同帧）              │
-- │  - 累计求和应显式写 ROWS BETWEEN UNBOUNDED PRECEDING          │
-- │  详见 05-functions/02_window_functions_examples.sql          │
-- └─────────────────────────────────────────────────────────────┘

-- ============================================================
-- 7. 窗口函数
-- ============================================================
-- 【原理】窗口函数不折叠行数，每行带窗口聚合结果
-- 【坑】sum(x) OVER (ORDER BY d) 默认 RANGE frame，d 有重复值时累计值跳变
--   安全做法: 显式写 ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
SELECT
    id,
    name,
    age,
    row_number() OVER (ORDER BY age DESC) AS age_rank,
    rank() OVER (ORDER BY age DESC) AS age_rank_gap,
    dense_rank() OVER (ORDER BY age DESC) AS age_rank_dense,
    ntile(4) OVER (ORDER BY age DESC) AS age_quartile,
    lag(age) OVER (ORDER BY age DESC) AS prev_age,
    lead(age) OVER (ORDER BY age DESC) AS next_age
FROM test_users
ORDER BY age DESC;

-- ┌─────────────────────────────────────────────────────────────┐
-- │           CTE (公共表表达式) 原理                              │
-- ├─────────────────────────────────────────────────────────────┤
-- │  CTE 特点:                                                   │
-- │  - 临时结果集，只在查询期间存在                               │
-- │  - 提高可读性和可维护性                                       │
-- │  - 支持递归查询 (WITH RECURSIVE)                             │
-- │  - CH 对 CTE 做了优化（物化避免重复计算）                     │
-- └─────────────────────────────────────────────────────────────┘

-- ============================================================
-- 8. CTE (Common Table Expression)
-- ============================================================
-- 【场景】复杂查询分步、多次引用同一子查询
WITH user_stats AS (
    SELECT
        id,
        name,
        age,
        multiIf(
            age < 25, 'Young',
            age < 35, 'Adult',
            'Senior'
        ) AS age_group
    FROM test_users
)
SELECT
    age_group,
    count() AS user_count,
    avg(age) AS avg_age
FROM user_stats
GROUP BY age_group
ORDER BY avg_age;

-- ┌─────────────────────────────────────────────────────────────┐
-- │           条件表达式原理                                      │
-- ├─────────────────────────────────────────────────────────────┤
-- │  ClickHouse 条件函数:                                         │
-- │  1. CASE WHEN (标准 SQL)                                    │
-- │  2. if(condition, true_value, false_value)                 │
-- │     - 简化的三元表达式，向量化执行                            │
-- │  3. multiIf(cond1, val1, cond2, val2, ..., default)       │
-- │     - 多分支，比嵌套 CASE WHEN/if 可读性好                   │
-- │  【对比】multiIf 比嵌套 CASE WHEN 性能相当但可读性更好        │
-- └─────────────────────────────────────────────────────────────┘

-- ============================================================
-- 9. 条件表达式（multiIf vs CASE WHEN）
-- ============================================================
-- 【对比】CASE WHEN 是标准 SQL；multiIf 是 CH 专用，多分支更简洁
-- 【场景】数据分级、哨兵值过滤

SELECT
    id,
    name,
    age,
    CASE
        WHEN age < 25 THEN 'Young'
        WHEN age < 35 THEN 'Adult'
        WHEN age < 50 THEN 'Middle-aged'
        ELSE 'Senior'
    END AS age_category,
    multiIf(
        age < 25, 'Young',
        age < 35, 'Adult',
        'Senior'
    ) AS age_category2
FROM test_users
ORDER BY age;

-- IF 函数（二选一）
SELECT
    id,
    name,
    age,
    if(age >= 30, 'Senior Member', 'Junior Member') AS membership_level
FROM test_users
ORDER BY age DESC;

-- ┌─────────────────────────────────────────────────────────────┐
-- │           字符串函数原理                                      │
-- ├─────────────────────────────────────────────────────────────┤
-- │  ClickHouse 字符串处理:                                       │
-- │  - length() 返回字节数（非字符数），char_length() 才是字符数  │
-- │  - splitByChar 返回数组，用 [n] 取元素（1-based）            │
-- │  - 主键不支持字符串范围查询，用跳数索引优化                    │
-- │                                                              │
-- │  字符串存储优化:                                              │
-- │  - LowCardinality(String): 低基数（<1万），省 10x 内存       │
-- │  - FixedString(n): 固定长度，省空间                          │
-- │  - UUID: 专用 UUID 类型（16 字节）                            │
-- └─────────────────────────────────────────────────────────────┘

-- ============================================================
-- 10. 字符串操作
-- ============================================================
-- 【原理】length() 返回字节数，对中文不等于字符数
-- 【场景】日志解析、JSON 文本处理、URL 拆解
SELECT
    id,
    name,
    email,
    length(name) AS name_length,
    lower(name) AS name_lower,
    upper(name) AS name_upper,
    substring(name, 1, 3) AS name_prefix,
    splitByChar('@', email)[1] AS email_username,
    replace(email, 'example.com', 'test.com') AS new_email
FROM test_users
LIMIT 5;

-- ┌─────────────────────────────────────────────────────────────┐
-- │           日期时间函数原理                                     │
-- ├─────────────────────────────────────────────────────────────┤
-- │  ClickHouse 日期时间类型:                                     │
-- │  - Date: 天数 (UInt16，2 字节)                              │
-- │  - DateTime: 秒级 Unix 时间戳 (UInt32，4 字节)               │
-- │  - DateTime64: 亚秒精度 (8 字节)                             │
-- │                                                              │
-- │  时区处理:                                                   │
-- │  - 存储 UTC 时间，查询时转换                                 │
-- │  - Date 比 DateTime 更省存储，能用 Date 就别用 DateTime     │
-- │                                                              │
-- │  【坑】formatDateTime 不支持 %A/%B（星期/月份名）            │
-- │       用 dateName('weekday', d) / dateName('month', d)      │
-- └─────────────────────────────────────────────────────────────┘

-- ============================================================
-- 11. 日期时间操作
-- ============================================================
-- 【原理】Date 是天数(UInt16)，DateTime 是 Unix 秒(UInt32)
-- 【坑】CH 25.12 的 formatDateTime 不支持 %A/%B，用 dateName()
SELECT
    id,
    name,
    created_at,
    toDate(created_at) AS date_only,
    toYYYYMM(created_at) AS year_month,
    toStartOfMonth(created_at) AS month_start,
    dateDiff('day', created_at, now()) AS days_since_creation,
    formatDateTime(created_at, '%Y-%m-%d %H:%M:%S') AS formatted_date,
    dateName('weekday', created_at) AS weekday_name
FROM test_users
ORDER BY created_at;

-- ┌─────────────────────────────────────────────────────────────┐
-- │           数组函数原理                                        │
-- ├─────────────────────────────────────────────────────────────┤
-- │  ClickHouse 原生数组支持:                                     │
-- │  - Array(T): 数组类型                                        │
-- │  - arrayJoin(arr): 一行变多行（反聚合，CH 独有）              │
-- │  - arrayMap(f, arr): 对每个元素套函数（不改行数）            │
-- │  - groupArray(col): 将列值聚合为数组（arrayJoin 的逆）        │
-- │                                                              │
-- │  arrayJoin vs arrayMap:                                      │
-- │  - arrayJoin: 改变行数（1→N），用于标签展开                   │
-- │  - arrayMap: 不改行数（1→1），用于批量变换                    │
-- └─────────────────────────────────────────────────────────────┘

-- ============================================================
-- 12. 数组操作（arrayJoin 反聚合）
-- ============================================================
-- 【原理】arrayJoin 把数组每个元素拆成单独一行（反聚合）
-- 【场景】标签展开、事件拆解
CREATE TABLE IF NOT EXISTS test_products ON CLUSTER 'treasurycluster' (
    id UInt64,
    name String,
    tags Array(String),
    prices Array(Decimal(10, 2))
) ENGINE = ReplicatedMergeTree()
ORDER BY id;

INSERT INTO test_products VALUES
(1, 'Laptop', ['electronics', 'computer', 'work'], [999.99, 899.99]),
(2, 'Chair', ['furniture', 'office', 'ergonomic'], [199.99, 179.99]),
(3, 'Book', ['education', 'reading'], [29.99, 24.99, 19.99]);

-- 数组操作：arrayJoin 一行变多行
SELECT
    name,
    tags,
    length(tags) AS tag_count,
    tags[1] AS first_tag,
    has(tags, 'electronics') AS has_electronics,
    arrayJoin(tags) AS tag_expanded
FROM test_products
ORDER BY id;

-- 数组聚合操作
SELECT
    name,
    max(prices) AS max_price,
    min(prices) AS min_price,
    avg(arrayJoin(prices)) AS avg_price
FROM test_products
GROUP BY name
ORDER BY name;

-- ┌─────────────────────────────────────────────────────────────┐
-- │           数据去重与幂等性原理                                  │
-- ├─────────────────────────────────────────────────────────────┤
-- │  ClickHouse 去重机制:                                         │
-- │  1. 插入去重 (Deduplicating Inserts)                         │
-- │     - 相同 block hash 重复写入被忽略（幂等性）                │
-- │     - 基于 block data hash 判断                               │
-- │                                                              │
-- │  2. ReplacingMergeTree(version)                              │
-- │     - 后台合并时保留 max(version) 的记录                      │
-- │     - 查询时用 argMax(x, version) 或 FINAL 去重             │
-- │     - argMax 比 FINAL 快 10x+                                │
-- │                                                              │
-- │  3. CollapsingMergeTree(sign)                                │
-- │     - sign +1/-1 抵消                                        │
-- │     - 适合增量更新（库存、计数器）                            │
-- │                                                              │
-- │  合并时机:                                                   │
-- │  - 后台自动合并 (异步，不可控)                               │
-- │  - OPTIMIZE 手动触发 (低峰期)                                │
-- │  - 查询时 FINAL (性能差，慎用)                               │
-- └─────────────────────────────────────────────────────────────┘

-- ============================================================
-- 13. 数据去重与幂等性入门
-- ============================================================
-- 说明：解决上游写入一半程序崩溃时，如何保证 ClickHouse 数据不重复
-- 详细去重机制见 07_constraints.sql

-- ========================================
-- 场景 1：ReplacingMergeTree - 保留最新版本
-- ========================================
-- 适用场景：用户资料更新、配置信息、状态变更
-- 【原理】后台合并时按 ORDER BY 键去重，保留 max(version) 的记录
-- 【对比】argMax(x, version) 比 FINAL 快 10x+，是查询去重首选

DROP TABLE IF EXISTS dedup_user_profiles ON CLUSTER 'treasurycluster' SYNC;

CREATE TABLE dedup_user_profiles ON CLUSTER 'treasurycluster' (
    user_id UInt64,
    profile_id String,
    name String,
    email String,
    phone String,
    updated_at DateTime,
    version UInt64,
    inserted_at DateTime DEFAULT now()
) ENGINE = ReplicatedReplacingMergeTree(version)
PARTITION BY toYYYYMM(updated_at)
ORDER BY (user_id, profile_id)
SETTINGS index_granularity = 8192;

-- 插入初始数据（version 1）
INSERT INTO dedup_user_profiles VALUES
(1001, 'prof-001', '张三', 'zhangsan@example.com', '13800000001', '2024-01-01 10:00:00', 1, now()),
(1002, 'prof-002', '李四', 'lisi@example.com', '13800000002', '2024-01-01 10:00:00', 1, now()),
(1003, 'prof-003', '王五', 'wangwu@example.com', '13800000003', '2024-01-01 10:00:00', 1, now());

-- 模拟程序崩溃：重复插入相同数据（block hash 去重，不会产生重复）
INSERT INTO dedup_user_profiles VALUES
(1001, 'prof-001', '张三', 'zhangsan@example.com', '13800000001', '2024-01-01 10:00:00', 1, now()),
(1002, 'prof-002', '李四', 'lisi@example.com', '13800000002', '2024-01-01 10:00:00', 1, now()),
(1003, 'prof-003', '王五', 'wangwu@example.com', '13800000003', '2024-01-01 10:00:00', 1, now());

-- 查询原始数据（可能看到重复，因后台未合并）
SELECT * FROM dedup_user_profiles
ORDER BY user_id, profile_id, version;

-- 查询去重后的数据（使用 argMax 手动去重 - 推荐，比 FINAL 快 10x+）
SELECT
    user_id,
    profile_id,
    argMax(name, version) AS name,
    argMax(email, version) AS email,
    argMax(phone, version) AS phone,
    argMax(updated_at, version) AS updated_at,
    max(version) AS latest_version
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
    argMax(name, version) AS name,
    argMax(email, version) AS email,
    max(version) AS latest_version
FROM dedup_user_profiles
GROUP BY user_id, profile_id
ORDER BY user_id;

-- 使用 FINAL 查询（自动去重，但性能较差，慎用）
SELECT * FROM dedup_user_profiles FINAL
ORDER BY user_id;

-- 手动触发合并（低峰期执行）
OPTIMIZE TABLE dedup_user_profiles FINAL;

-- 再次查询（已合并，无重复）
SELECT * FROM dedup_user_profiles
ORDER BY user_id, version;

-- ========================================
-- 场景 2：CollapsingMergeTree - 增量更新
-- ========================================
-- 适用场景：库存管理、订单状态、增量计数器
-- 【原理】sign +1/-1 抵消，合并时同主键的 +1 和 -1 行被删除
-- 【对比】比 ReplacingMergeTree 适合"增量增减"（不是"整行覆盖"）

DROP TABLE IF EXISTS dedup_inventory ON CLUSTER 'treasurycluster' SYNC;

CREATE TABLE dedup_inventory ON CLUSTER 'treasurycluster' (
    product_id UInt64,
    product_name String,
    quantity Int32,
    sign Int8,
    timestamp DateTime,
    inserted_at DateTime DEFAULT now()
) ENGINE = ReplicatedCollapsingMergeTree(sign)
PARTITION BY toYYYYMM(timestamp)
ORDER BY product_id
SETTINGS index_granularity = 8192;

-- 初始化库存（sign = 1）
INSERT INTO dedup_inventory VALUES
(101, '产品A', 100, 1, '2024-01-01 10:00:00', now()),
(102, '产品B', 50, 1, '2024-01-01 10:00:00', now()),
(103, '产品C', 75, 1, '2024-01-01 10:00:00', now());

-- 销售商品（sign = -1，抵消部分库存）
INSERT INTO dedup_inventory VALUES
(101, '产品A', 10, -1, '2024-01-01 11:00:00', now()),
(102, '产品B', 5, -1, '2024-01-01 11:00:00', now());

-- 进货（sign = 1）
INSERT INTO dedup_inventory VALUES
(101, '产品A', 20, 1, '2024-01-01 12:00:00', now()),
(103, '产品C', 10, 1, '2024-01-01 12:00:00', now());

-- 查询当前库存（使用 GROUP BY 抵消 sign）
-- 【原理】sum(quantity * sign) 把 +1 和 -1 的数量相加，得到净库存
SELECT
    product_id,
    argMax(product_name, timestamp) AS product_name,
    sum(quantity * sign) AS current_inventory,
    max(timestamp) AS last_updated
FROM dedup_inventory
GROUP BY product_id
ORDER BY product_id;

-- 使用 FINAL 查询
SELECT * FROM dedup_inventory FINAL
ORDER BY product_id, timestamp;

-- ============================================================
-- 14. 清理测试表
-- ============================================================
DROP TABLE IF EXISTS test_users ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS test_orders ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS test_products ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS dedup_user_profiles ON CLUSTER 'treasurycluster' SYNC;
DROP TABLE IF EXISTS dedup_inventory ON CLUSTER 'treasurycluster' SYNC;

-- 验证清理
SELECT name FROM system.tables WHERE database = 'base_test';

-- 如需彻底清理数据库（可选）
-- DROP DATABASE IF EXISTS base_test ON CLUSTER 'treasurycluster';
