-- ============================================================
-- 文件: 05-functions/04_udf.sql
-- 学习目标: 掌握 ClickHouse 用户定义函数（UDF）原理与实战
-- 深度标准: 原理 + 场景 + 对比 + 局限 + 可运行
-- 集群: CH 25.12 (单机模式，UDF 概念通用)
-- 前置: 无（自包含测试数据，按顺序执行）
-- ============================================================
--
-- 本文件章节:
--   1.  UDF 原理：ClickHouse 的两种 UDF 机制
--   2.  SQL UDF（CREATE FUNCTION）：创建和使用
--   3.  Lambda UDF（参数化表达式）：内联定义
--   4.  UDF 的局限（不能做聚合、不能优化、性能差）
--   5.  生产环境中的 UDF 使用建议
--   6.  清理
-- ============================================================

DROP DATABASE IF EXISTS func_test;
CREATE DATABASE func_test;
USE func_test;


-- ============================================================
-- 0. 准备测试数据
-- ============================================================

DROP TABLE IF EXISTS sales;
DROP TABLE IF EXISTS products;
DROP TABLE IF EXISTS event_log;

CREATE TABLE sales (
    id UInt64,
    product_id UInt32,
    quantity UInt32,
    unit_price Decimal(10, 2),
    discount_rate Float32,
    sale_date Date,
    region String
) ENGINE = MergeTree()
ORDER BY id;

INSERT INTO sales VALUES
    (1, 101, 2, 299.99, 0.10, '2024-01-15', 'North'),
    (2, 101, 1, 299.99, 0.05, '2024-01-16', 'South'),
    (3, 102, 3, 499.99, 0.15, '2024-01-15', 'East'),
    (4, 103, 5, 49.99, 0.20, '2024-01-15', 'West'),
    (5, 104, 1, 899.99, 0.00, '2024-01-16', 'South'),
    (6, 105, 10, 29.99, 0.10, '2024-01-17', 'East'),
    (7, 101, 4, 299.99, 0.08, '2024-01-18', 'West'),
    (8, 102, 2, 499.99, 0.12, '2024-01-18', 'North');

CREATE TABLE products (
    id UInt32,
    name String,
    category String,
    base_price Decimal(10, 2),
    tax_rate Float32
) ENGINE = MergeTree()
ORDER BY id;

INSERT INTO products VALUES
    (101, 'Laptop', 'Electronics', 299.99, 0.13),
    (102, 'Monitor', 'Electronics', 499.99, 0.13),
    (103, 'Mouse', 'Accessories', 49.99, 0.08),
    (104, 'Keyboard', 'Electronics', 899.99, 0.13),
    (105, 'USB Cable', 'Accessories', 29.99, 0.08);

CREATE TABLE event_log (
    id UInt64,
    event_type String,
    event_data String,
    event_time DateTime
) ENGINE = MergeTree()
ORDER BY id;

INSERT INTO event_log VALUES
    (1, 'page_view', '{"page":"/home","user_id":1001}', '2024-01-15 08:00:00'),
    (2, 'purchase', '{"order_id":5001,"amount":299.99}', '2024-01-15 08:30:00'),
    (3, 'page_view', '{"page":"/products","user_id":1002}', '2024-01-15 09:00:00'),
    (4, 'error', '{"code":404,"message":"Not Found"}', '2024-01-15 09:15:00'),
    (5, 'purchase', '{"order_id":5002,"amount":499.99}', '2024-01-15 10:00:00');


-- ============================================================
-- 1. UDF 原理
-- ============================================================
-- 【原理】ClickHouse 支持两种 UDF 机制：
--
--   1) SQL UDF（CREATE FUNCTION）
--      - 语法：CREATE FUNCTION name AS (params) -> expression
--      - 本质：宏展开（macro substitution），非真正函数
--      - 存储：持久化在元数据中，跨会话可用
--      - 作用域：当前数据库（或全局，取决于权限）
--
--   2) Lambda UDF（参数化表达式）
--      - 语法：x -> expression（内联 lambda）
--      - 本质：匿名函数，在查询中直接定义和使用
--      - 存储：不持久化，仅在当前查询中有效
--      - 作用域：当前查询的表达式上下文
--
--   共同特点：
--     - 都是表达式级别的，不能做聚合、不能访问表、不能做 IO
--     - 都通过"宏展开"实现（编译期替换），不是运行时函数调用
--     - 都不支持递归
--
-- 【场景】
--   1. 封装复杂业务逻辑（价格计算、税率、折扣）
--   2. 避免重复写相同的表达式片段
--   3. 提高查询可读性
--   4. Lambda 用于数组函数（arrayMap, arrayFilter）的回调
--
-- 【坑】UDF 不是真正的数据库函数，不支持重载、不支持聚合、
--   不支持窗口、不支持多语句、性能与手写表达式相同（因为就是宏展开）


-- ============================================================
-- 2. SQL UDF（CREATE FUNCTION）
-- ============================================================
-- 【原理】CREATE FUNCTION 定义一个持久化的 SQL UDF，
--   在查询编译时被宏展开为对应的表达式。
--   类似于 SQL 标准中的"存储函数"但功能受限。

-- 2.1 创建简单 UDF：计算含税价格
-- 【场景】金融场景中频繁计算含税价格
DROP FUNCTION IF EXISTS price_with_tax;

CREATE FUNCTION price_with_tax AS (price, tax_rate) -> price * (1 + tax_rate);

-- 使用 UDF
SELECT
    id,
    unit_price,
    discount_rate,
    price_with_tax(unit_price, 0.13) AS price_inc_tax
FROM sales
LIMIT 5;

-- 2.2 创建 UDF：计算折扣后金额
-- 【场景】销售报表中计算实际成交价
DROP FUNCTION IF EXISTS discounted_price;

CREATE FUNCTION discounted_price AS (price, discount) -> price * (1 - discount);

-- 使用 UDF（组合使用）
SELECT
    id,
    unit_price,
    discount_rate,
    discounted_price(unit_price, discount_rate) AS after_discount,
    price_with_tax(discounted_price(unit_price, discount_rate), 0.13) AS final_price
FROM sales
LIMIT 5;

-- 2.3 创建 UDF：带条件逻辑
-- 【场景】根据订单金额计算运费（满 100 免运费，否则 10 元）
DROP FUNCTION IF EXISTS shipping_cost;

CREATE FUNCTION shipping_cost AS (amount) -> multiIf(amount >= 100, 0, 10);

SELECT
    id,
    unit_price * quantity AS order_amount,
    shipping_cost(unit_price * quantity) AS shipping
FROM sales
LIMIT 5;

-- 2.4 创建 UDF：数据脱敏
-- 【场景】显示用户信息时脱敏
DROP FUNCTION IF EXISTS mask_email;

-- 注意：concat 和 substring 都是标量函数，UDF 内可自由组合
CREATE FUNCTION mask_email AS (email) ->
    concat(
        substring(email, 1, 2),
        '***',
        substring(email, position(email, '@'), length(email) - position(email, '@') + 1)
    );

-- 使用 UDF 脱敏
SELECT
    id,
    event_data,
    mask_email(JSONExtractString(event_data, 'page')) AS masked_page
FROM event_log
WHERE event_type = 'page_view'
LIMIT 5;

-- 2.5 查看已创建的 UDF
-- 【原理】UDF 存储在系统表 system.functions 中
SELECT
    name,
    create_query
FROM system.functions
WHERE name IN ('price_with_tax', 'discounted_price', 'shipping_cost', 'mask_email')
AND origin = 'SQLUserDefinedFunction';

-- 2.6 UDF 的持久化
-- 【原理】SQL UDF 创建后永久有效（直到 DROP FUNCTION），
--   重启服务器后仍存在。存储在元数据服务（如 ZooKeeper 或本地目录）。
--   DROP FUNCTION 可删除


-- ============================================================
-- 3. Lambda UDF（参数化表达式）
-- ============================================================
-- 【原理】Lambda UDF 是内联定义的匿名函数，语法为：
--   param1, param2, ... -> expression
--   主要用于数组函数（arrayMap, arrayFilter, arraySort 等）的回调。
--   也可以用于任何需要表达式的地方（如 SELECT 子句）。
-- 【场景】数组变换、过滤、排序；复杂表达式复用

-- 3.1 Lambda 基础：简单变换
-- 【场景】对数组每个元素做平方运算
SELECT
    arrayMap(x -> x * x, [1, 2, 3, 4, 5]) AS squared;

-- 3.2 Lambda 配合 arrayFilter 过滤
-- 【场景】筛选出数组中的偶数
SELECT
    arrayFilter(x -> x % 2 = 0, [1, 2, 3, 4, 5, 6]) AS evens;

-- 3.3 Lambda 配合 arraySort 排序
-- 【场景】按字符串长度排序
SELECT
    arraySort(x -> length(x), ['apple', 'kiwi', 'banana', 'fig']) AS sorted_by_length;

-- 3.4 Lambda 多参数（多元素回调）
-- 【原理】arrayMap 等函数可以传入多个数组，lambda 接收多个参数
--   每个参数对应一个数组的当前元素
-- 【场景】两个数组对应元素相乘
SELECT
    arrayMap((x, y) -> x * y, [1, 2, 3], [10, 20, 30]) AS element_wise_product;

-- 3.5 Lambda 在 GROUP BY 中复用
-- 【场景】定义一个 lambda 计算折扣后金额，在查询中多次使用
WITH discounted AS (x, discount) -> x * (1 - discount)
SELECT
    region,
    sum(discounted(unit_price * quantity, discount_rate)) AS revenue_after_discount,
    avg(discounted(unit_price, discount_rate)) AS avg_discounted_price
FROM sales
GROUP BY region
ORDER BY revenue_after_discount DESC;

-- 3.6 Lambda 配合 arrayMap 做数据清洗
-- 【场景】对数组中的字符串做 trim 和 lower
SELECT
    arrayMap(x -> lower(trim(x)), ['  Hello  ', '  World  ', '  ClickHouse  ']) AS cleaned;

-- 3.7 Lambda 嵌套（高阶函数）
-- 【场景】数组的数组，对每个子数组求和
SELECT
    arrayMap(arr -> arraySum(arr), [[1, 2, 3], [4, 5], [6]]) AS sum_of_subs;

-- 3.8 Lambda UDF 与 SQL UDF 组合
-- 【场景】SQL UDF 定义基础逻辑，Lambda 在数组上下文中调用它
DROP FUNCTION IF EXISTS square;

CREATE FUNCTION square AS (x) -> x * x;

-- 在 Lambda 中调用 SQL UDF
SELECT
    arrayMap(x -> square(x), [1, 2, 3, 4, 5]) AS squared_via_udf;


-- ============================================================
-- 4. UDF 的局限（必读）
-- ============================================================
-- 【原理】ClickHouse 的 UDF 有以下显著局限，理解这些局限
--   才能正确使用 UDF，避免在错误场景中浪费时间。

-- 4.1 局限一：不能做聚合
-- 【原理】UDF 只能包装标量表达式，不能包含聚合函数。
--   以下代码会报错：
--   CREATE FUNCTION avg_price AS (price) -> avg(price)  -- 错误！
-- 【原因】UDF 是宏展开，展开后 avg(price) 在非聚合上下文中无效
-- 【替代方案】用视图（VIEW）或子查询封装聚合逻辑

-- 正确做法：用视图封装聚合
DROP VIEW IF EXISTS avg_price_view;

CREATE VIEW avg_price_view AS
SELECT
    region,
    avg(unit_price) AS avg_price,
    sum(quantity * unit_price) AS total_revenue
FROM sales
GROUP BY region;

SELECT * FROM avg_price_view ORDER BY total_revenue DESC;

-- 4.2 局限二：UDF 不能优化
-- 【原理】UDF 内联展开后，优化器无法跨表达式边界优化。
--   例如 UDF 内部用了相同的子表达式，不会自动公共子表达式消除。
-- 【场景】复杂 UDF 嵌套时，相同计算可能被执行多次

-- 4.3 局限三：UDF 性能差（相比内置函数）
-- 【原理】UDF 展开后仍是表达式，但：
--   1. 不被向量化优化（内置函数有 SIMD 加速）
--   2. 嵌套 UDF 增加表达式树深度，编译开销增大
--   3. Lambda UDF 对每一行/元素都执行函数调用开销
-- 【对比】同样功能的 UDF vs 手写表达式，UDF 版本可能慢 2~5x
-- 【结论】高频计算路径（如 WHERE 过滤条件）避免使用 UDF

-- 4.4 局限四：UDF 不支持重载
-- 【原理】不能定义同名不同参数的 UDF，后创建的会覆盖前者
-- 【替代方案】用不同名称区分

-- 4.5 局限五：UDF 不能访问表
-- 【原理】UDF 只能对传入参数做表达式计算，不能执行 SELECT、
--   INSERT 等 DML 操作，也不能访问数据库对象。
-- 【替代方案】用物化视图或存储过程（如果 CH 支持）

-- 4.6 局限六：Lambda UDF 不持久化
-- 【原理】Lambda 在每次查询中定义，不能跨查询复用。
--   如果需要持久化，用 CREATE FUNCTION 转为 SQL UDF。
-- 【场景】频繁使用的 lambda 逻辑应转为 SQL UDF

-- 4.7 局限七：参数类型推断
-- 【原理】UDF 参数类型在调用时推断，无显式类型声明。
--   如果传入类型不匹配，编译时报错。
-- 【场景】定义 UDF 时考虑输入类型，或用 CAST 确保类型一致


-- ============================================================
-- 5. UDF 局限大全（完整清单）
-- ============================================================
-- 【原理】以下表格汇总了所有局限，供参考：
--
--   局限项             | 说明                          | 替代方案
--   -------------------|-------------------------------|-------------------
--   不能做聚合         | 不能包含聚合函数               | 视图 / 子查询
--   不能优化           | 不公共子表达式消除             | 手写展开
--   性能差             | 无向量化加速                   | 内置函数优先
--   不支持重载         | 同名 UDF 覆盖                  | 不同名称
--   不能访问表         | 不能执行 SELECT 等             | 视图 / 物化视图
--   Lambda 不持久化    | 查询结束消失                   | 转为 SQL UDF
--   无类型声明         | 参数类型推断                   | 调用时 CAST
--   不支持递归         | 不能自引用                      | 用循环/列表
--   不支持窗口函数     | 不能包含 OVER 子句             | 窗口函数直接写
--   不支持多语句       | 只能一个表达式                  | 嵌套表达式


-- ============================================================
-- 6. 生产环境中的 UDF 使用建议
-- ============================================================
-- 【原理】UDF 在 ClickHouse 中是"双刃剑"——用对场景提升效率，
--   用错场景引入性能问题。以下是生产环境建议：

-- 6.1 推荐使用场景
-- 【场景①】业务逻辑封装：价格计算、税率、折扣、脱敏等
--   这些逻辑不变且频繁使用，UDF 提升可读性
DROP FUNCTION IF EXISTS calc_final_price;

CREATE FUNCTION calc_final_price AS (base_price, discount, tax_rate) ->
    base_price * (1 - discount) * (1 + tax_rate);

SELECT
    id,
    calc_final_price(unit_price, discount_rate, 0.13) AS final_price
FROM sales
LIMIT 5;

-- 【场景②】数据清洗函数：格式转换、脱敏、标准化
DROP FUNCTION IF EXISTS normalize_url;

CREATE FUNCTION normalize_url AS (url) ->
    replaceRegexpAll(lower(trim(url)), '^https?://', '');

SELECT
    normalize_url('  HTTPS://Example.com/Page  ') AS cleaned_url;

-- 【场景③】复杂条件表达式封装
DROP FUNCTION IF EXISTS order_tier;

CREATE FUNCTION order_tier AS (amount) ->
    multiIf(
        amount >= 1000, 'VIP',
        amount >= 500, 'Premium',
        amount >= 100, 'Standard',
        'Basic'
    );

SELECT
    id,
    unit_price * quantity AS amount,
    order_tier(unit_price * quantity) AS tier
FROM sales
LIMIT 5;

-- 6.2 不推荐使用场景
-- 【场景①】高频过滤条件（WHERE 子句）
--   不推荐：WHERE my_udf(column) > 10
--   推荐：手写表达式，让优化器做索引选择
-- 【场景②】大数据量聚合中的 UDF
--   不推荐：SELECT sum(my_udf(amount)) FROM big_table
--   推荐：直接写表达式，利用向量化
-- 【场景③】嵌套多层 UDF
--   不推荐：SELECT udf3(udf2(udf1(x))) ...
--   推荐：合并为一个表达式，或拆成多步 CTE

-- 6.3 UDF 性能测试（对比手写表达式）
-- 【原理】数据量小时差异不大，大数据量时 UDF 可能慢 2~5x
--   以下测试用小数据集，仅展示方法，实际需在亿级数据测试
SELECT
    -- UDF 版本
    calc_final_price(unit_price, discount_rate, 0.13) AS udf_version,
    -- 手写表达式版本
    unit_price * (1 - discount_rate) * (1 + 0.13) AS inline_version
FROM sales;

-- 6.4 UDF 管理最佳实践
-- 【最佳实践①】UDF 命名规范：前缀 + 描述性名称
--   如：calc_*, fmt_*, mask_*, tier_*
-- 【最佳实践②】UDF 文档化：在注释中说明输入输出
-- 【最佳实践③】定期审查：用 system.functions 检查未使用的 UDF
-- 【最佳实践④】测试覆盖：CREATE 后立即做 SELECT 验证
-- 【最佳实践⑤】避免依赖：UDF 之间相互调用增加复杂度

-- 6.5 UDF 生命周期管理
-- 查看所有用户定义的 UDF
SELECT
    name,
    create_query,
    origin
FROM system.functions
WHERE origin = 'SQLUserDefinedFunction'
ORDER BY name;

-- 删除 UDF
-- DROP FUNCTION IF EXISTS calc_final_price;
-- DROP FUNCTION IF EXISTS normalize_url;
-- DROP FUNCTION IF EXISTS order_tier;
-- DROP FUNCTION IF EXISTS price_with_tax;
-- DROP FUNCTION IF EXISTS discounted_price;
-- DROP FUNCTION IF EXISTS shipping_cost;
-- DROP FUNCTION IF EXISTS mask_email;
-- DROP FUNCTION IF EXISTS square;


-- ============================================================
-- 7. 清理
-- ============================================================
DROP DATABASE IF EXISTS func_test;