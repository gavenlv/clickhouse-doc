/*
 * 07_type_conversion.sql — 类型转换与类型检查
 *
 * 【本章解决什么问题】
 *   - CAST 和 toTypeName 函数怎么用？
 *   - 隐式类型转换什么时候安全？什么时候会出问题？
 *   - 如何处理字符串转数字、数字转字符串的常见陷阱？
 *   - 如何检查列的类型和存储大小？
 *
 * 【原理】
 *   ClickHouse 的类型转换分两类：
 *   - 隐式转换：INSERT 时自动转换，SELECT 时按需转换
 *   - 显式转换：CAST(x AS Type) 或 toType(x) 函数
 *
 *   隐式转换规则：
 *   - 整数 → 整数：安全（小范围 → 大范围）
 *   - 整数 → 浮点：安全
 *   - 浮点 → 整数：截断（不是四舍五入）
 *   - 字符串 → 数字：安全（需能被解析）
 *   - 数字 → 字符串：安全
 *
 * 【运行环境】
 *   - 集群：treasurycluster（CH 25.12.1.649）
 *   - 数据库：data_type_test
 */

-- ============================================================================
-- §0. 准备
-- ============================================================================
DROP DATABASE IF EXISTS data_type_test;
CREATE DATABASE data_type_test;
USE data_type_test;

-- ============================================================================
-- §1. 显式类型转换
-- ============================================================================
-- 【原理】CAST(x AS Type) 是标准 SQL 语法，CH 也支持 toType(x) 快捷函数

-- 1.1 基本 CAST
SELECT
    CAST(123 AS String) AS int_to_str,              -- '123'
    CAST('123' AS UInt32) AS str_to_int,            -- 123
    CAST(123.45 AS Int32) AS float_to_int,          -- 123（截断）
    CAST(123 AS Float64) AS int_to_float;           -- 123.0

-- 1.2 toType 快捷函数
SELECT
    toString(123) AS s1,           -- '123'
    toUInt32('123') AS i1,         -- 123
    toInt32(toFloat64('123.45')) AS i3,  -- 123（先转浮点再截断）
    toFloat64('123.45') AS f1;     -- 123.45

-- [预期报错] '123.45' 含小数点，toInt32 无法直接解析，应先用 toFloat64 转换再截断
SELECT
    toInt32('123.45') AS i2;       -- 报错！含小数点

-- 1.3 类型信息查询
SELECT
    toTypeName(123) AS t1,                           -- 'UInt8'
    toTypeName(1234567890123) AS t2,                 -- 'UInt64'
    toTypeName(123.45) AS t3,                        -- 'Float64'
    toTypeName('hello') AS t4,                       -- 'String'
    toTypeName(toDate('2024-01-15')) AS t5,          -- 'Date'
    toTypeName([1, 2, 3]) AS t6,                     -- 'Array(UInt8)'
    toTypeName(tuple(1, 'a')) AS t7;                 -- 'Tuple(UInt8, String)'

-- ============================================================================
-- §2. 隐式类型转换
-- ============================================================================
-- 【原理】CH 在 INSERT 和 SELECT 时会自动进行类型转换

-- 2.1 INSERT 隐式转换
CREATE TABLE implicit_conversion
(
    id UInt32,
    price Float64,
    event_date Date,
    active UInt8,           -- 模拟布尔
    note String
) ENGINE = MergeTree()
ORDER BY id;

-- 字符串可以插入到数字列
INSERT INTO implicit_conversion VALUES
    ('123', '99.99', '2024-01-15', '1', '自动转换'),
    ('456', '199.99', '2024-01-16', '0', '也是自动转换');

SELECT * FROM implicit_conversion;

-- 2.2 SELECT 隐式转换
-- 字符串和数字比较
SELECT *
FROM implicit_conversion
WHERE id = '123'           -- 隐式转 UInt32
  AND active = 1;          -- 比较的是 UInt8

-- 2.3 隐式转换陷阱
-- 【坑】浮点转整数会截断，不是四舍五入
SELECT
    CAST(123.99 AS UInt32) AS truncated,    -- 123（不是 124）
    CAST(123.49 AS UInt32) AS trunc_2,      -- 123
    round(123.99) AS rounded;               -- 124（用 round 函数）

-- 【坑】字符串转数字时，首尾空格会导致解析失败（Code 6），需先 trimBoth 去空格
SELECT
    toUInt32(trimBoth('  123  ')) AS with_spaces;   -- 123

-- [预期报错] 带空格的字符串无法直接解析，应先用 trimBoth 处理
SELECT
    toUInt32('  123  ') AS with_spaces_raw;         -- 报错！

-- [预期报错] '123abc' 含非数字字符，toUInt32 无法解析
SELECT
    toUInt32('123abc') AS with_suffix;      -- 报错！

-- 【坑】超大数字转小类型会溢出
SELECT
    CAST(300 AS UInt8) AS overflow;         -- 44（300 - 256 = 44）

-- 安全做法：先检查范围
SELECT
    if(300 > 255, NULL, CAST(300 AS UInt8)) AS safe_cast;

-- ============================================================================
-- §3. 字符串类型转换
-- ============================================================================

-- 3.1 字符串 ↔ 数字
SELECT
    toString(12345) AS num_to_str,
    toString(123.456) AS float_to_str,
    toUInt64('1234567890123') AS str_to_big_int,
    toFloat64('3.14159') AS str_to_float;

-- 3.2 字符串 ↔ 日期
SELECT
    toString(toDate('2024-01-15')) AS date_to_str,
    toDate('2024-01-15') AS str_to_date,
    toDateTime('2024-01-15 10:30:00') AS str_to_datetime,
    toString(now()) AS now_as_str;

-- 3.3 字符串 ↔ UUID
SELECT
    toString(generateUUIDv4()) AS uuid_to_str,
    toUUID('550e8400-e29b-41d4-a716-446655440000') AS str_to_uuid;

-- 3.4 字符串 ↔ IP
SELECT
    IPv4NumToString(toIPv4('192.168.1.1')) AS ipv4_str,
    IPv6NumToString(toIPv6('::1')) AS ipv6_str;

-- ============================================================================
-- §4. 类型检查与数据验证
-- ============================================================================

-- 4.1 检查列类型
SELECT
    name,
    type,
    is_in_primary_key,
    default_expression
FROM system.columns
WHERE database = 'data_type_test'
  AND table = 'implicit_conversion'
ORDER BY position;

-- 4.2 检查值是否可转换
-- 【场景】导入数据时验证字段值
SELECT
    toTypeName('123') AS t1,
    toTypeName(123) AS t2,
    -- 验证字符串是否为有效数字
    isFinite(toFloat64('123.45')) AS valid_number,
    isFinite(toFloat64('abc')) AS invalid_number,  -- 0
    -- 验证字符串是否为有效日期
    toDate('2024-01-15') AS valid_date;
    -- toDate('2024-13-15') AS invalid_date;  -- 报错

-- 4.3 安全转换：使用 try 前缀（某些版本支持）
-- tryToInt32('abc') 返回 NULL 而不是报错（CH 21.x+）
SELECT
    tryToInt32('123') AS valid_int,         -- 123
    tryToInt32('abc') AS invalid_int,       -- NULL
    tryToDate('2024-01-15') AS valid_date,  -- 2024-01-15
    tryToDate('bad-date') AS invalid_date;  -- NULL

-- ============================================================================
-- §5. 类型转换常见陷阱
-- ============================================================================

-- 5.1 溢出陷阱
-- 超过目标类型范围时，会静默溢出（不报错！）
SELECT
    CAST(500 AS UInt8) AS overflow_1,       -- 500 - 256 = 244
    CAST(-1 AS UInt8) AS overflow_2,        -- 255（-1 的 UInt8 表示）
    CAST(100000 AS UInt16) AS overflow_3;   -- 100000 - 65536 = 34464

-- 安全做法：先检查范围
SELECT
    if(500 BETWEEN 0 AND 255, CAST(500 AS UInt8), NULL) AS safe;

-- 5.2 精度陷阱
-- Float → Decimal 需注意精度
SELECT
    toDecimal64(0.1, 2) AS d1,             -- 0.10
    toDecimal64(0.1 + 0.2, 2) AS d2,       -- 0.30（Decimal 精确）
    toFloat64(0.1 + 0.2) AS f;             -- 0.30000000000000004（浮点误差）

-- 5.3 时区转换陷阱
-- DateTime 到处是 UTC，显示时按时区转换
SELECT
    toDateTime('2024-01-15 10:00:00', 'UTC') AS utc_time,
    toTimeZone(utc_time, 'Asia/Shanghai') AS shanghai_time,  -- 2024-01-15 18:00:00
    toUnixTimestamp(utc_time) AS same_epoch;

-- ============================================================================
-- §6. 类型转换性能对比
-- ============================================================================

-- 6.1 创建测试表
CREATE TABLE conversion_perf
(
    str_val String,
    int_val UInt32,
    float_val Float64
) ENGINE = MergeTree()
ORDER BY int_val;

INSERT INTO conversion_perf
SELECT
    toString(number),
    number,
    number / 100.0
FROM numbers(100000);

-- 6.2 字符串转数字性能
SELECT
    'CAST to UInt32' AS op,
    count() AS rows,
    avg(CAST(str_val AS UInt32)) AS result
FROM conversion_perf;

SELECT
    'toUInt32' AS op,
    count() AS rows,
    avg(toUInt32(str_val)) AS result
FROM conversion_perf;

-- 6.3 数字转字符串
SELECT
    'toString' AS op,
    count() AS rows,
    length(toString(int_val)) AS result
FROM conversion_perf;

-- 【结论】CAST 和 toType 性能几乎相同，toType 更简洁

-- ============================================================================
-- §7. 清理
-- ============================================================================
DROP TABLE IF EXISTS implicit_conversion;
DROP TABLE IF EXISTS conversion_perf;
DROP DATABASE IF EXISTS data_type_test;

-- ============================================================================
-- §8. 自测题
-- ============================================================================
-- 1. CAST(123.99 AS UInt32) 的结果是多少？为什么？
-- 2. CAST(300 AS UInt8) 的结果是多少？为什么不报错？
-- 3. toTypeName(123) 和 toTypeName(1234567890123) 的结果分别是什么？
-- 4. tryToInt32('abc') 和 toInt32('abc') 有什么区别？
-- 5. 隐式类型转换在什么情况下最危险？如何避免？