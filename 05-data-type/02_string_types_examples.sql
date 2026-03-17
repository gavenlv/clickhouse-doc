-- =====================================================
-- 02 - ClickHouse 字符串类型示例
-- =====================================================
-- 集群: treasurycluster (2副本)
-- 时间: 5-10分钟
-- =====================================================

-- -----------------------------------------------------
-- 1. 字符串类型概述
-- -----------------------------------------------------

-- 
-- ┌─────────────────────────────────────────────────────────────┐
-- │              ClickHouse 字符串类型体系                        │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                              │
-- │  1. String - 可变长度字符串                                  │
-- │     - 无长度限制                                            │
-- │     - 存储任意文本 (UTF-8)                                 │
-- │     - 最常用的字符串类型                                    │
-- │                                                              │
-- │  2. FixedString(N) - 固定长度字符串                         │
-- │     - N 字节固定长度                                        │
-- │     - 不足补零，超长截断                                    │
-- │     - 适用: MD5(32), UUID(36), 编码等                       │
-- │                                                              │
-- │  3. LowCardinality(String) - 低基数优化字符串               │
-- │     - 字典编码压缩                                          │
-- │     - 适用于重复值多的场景                                  │
-- │     - 性能提升: 存储减少50%+，查询加速                      │
-- │                                                              │
-- │  ┌─────────────────────────────────────────────────────────┐│
-- │  │              类型选择决策树                              ││
-- │  ├─────────────────────────────────────────────────────────┤│
-- │  │                                                          ││
-- │  │  是否固定长度且较短?                                     ││
-- │  │     ├── 是 → FixedString(N)                             ││
-- │  │     │      (如: MD5, UUID, 国家代码)                     ││
-- │  │     │                                                   ││
-- │  │     └── 否 → 是否低基数? (唯一值<10000)                  ││
-- │  │              ├── 是 → LowCardinality(String)            ││
-- │  │              │      (如: 状态, 类别, 国家)               ││
-- │  │              │                                          ││
-- │  │              └── 否 → String                            ││
-- │  │                     (如: 用户输入, 描述文本)            ││
-- │  │                                                          ││
-- │  └─────────────────────────────────────────────────────────┘│
-- │                                                              │
-- │  存储原理:                                                  │
-- │                                                              │
-- │  String:                                                    │
-- │    ┌─────────┬─────────────────────────┐                   │
-- │    │ Offset  │ Data (Variable Length) │                   │
-- │    │ 8 bytes │    实际字符串内容        │                   │
-- │    └─────────┴─────────────────────────┘                   │
-- │                                                              │
-- │  FixedString:                                               │
-- │    ┌─────────────────────────────────────┐                 │
-- │    │    Data (Exactly N bytes)           │                 │
-- │    └─────────────────────────────────────┘                 │
-- │                                                              │
-- │  LowCardinality:                                            │
-- │    ┌──────────────┬─────────────────────┐                  │
-- │    │ Dictionary   │ Index (1-2 bytes)   │                  │
-- │    │ Unique Values│ Position in Dict    │                  │
-- │    └──────────────┴─────────────────────┘                  │
-- │                                                              │
-- └─────────────────────────────────────────────────────────────┘

-- 创建数据库（如果存在则不创建）
CREATE DATABASE IF NOT EXISTS example ON CLUSTER 'treasurycluster';


DROP TABLE IF EXISTS example.strings ON CLUSTER 'treasurycluster' SYNC;
CREATE TABLE IF NOT EXISTS example.strings ON CLUSTER 'treasurycluster' (
    id UInt64,
    message String,
    email String,
    url String
) ENGINE = ReplicatedMergeTree() ORDER BY id;

-- 插入数据
INSERT INTO example.strings VALUES
    (1, 'Hello, World!', 'user@example.com', 'https://example.com'),
    (2, '你好，世界！', 'user@example.org', 'https://example.org');

-- 查询
SELECT * FROM example.strings;

-- ========================================
-- String 类型
-- ========================================

-- 创建表（存储 MD5 哈希）
DROP TABLE IF EXISTS example.files ON CLUSTER 'treasurycluster' SYNC;
CREATE TABLE IF NOT EXISTS example.files ON CLUSTER 'treasurycluster' (
    id UInt64,
    file_name String,
    file_hash FixedString(32),  -- MD5 32 字符
    file_size UInt64
) ENGINE = ReplicatedMergeTree() ORDER BY id;

-- 插入数据
INSERT INTO example.files VALUES
    (1, 'document.pdf', 'd41d8cd98f00b204e9800998ecf8427e', 1024),
    (2, 'image.jpg', '0cc175b9c0f1b6a831c399e269772661', 2048);

-- 查询
SELECT * FROM example.files WHERE file_hash = 'd41d8cd98f00b204e9800998ecf8427e';

-- ========================================
-- String 类型
-- ========================================

-- 创建表（国家、状态）
DROP TABLE IF EXISTS example.users ON CLUSTER 'treasurycluster' SYNC;
CREATE TABLE IF NOT EXISTS example.users ON CLUSTER 'treasurycluster' (
    id UInt64,
    name String,
    country LowCardinality(String),  -- 只有 200 个国家
    status LowCardinality(String),    -- 只有少量状态
    gender LowCardinality(String)     -- 只有 'M', 'F', 'U'
) ENGINE = ReplicatedMergeTree() ORDER BY id;

-- 插入数据
INSERT INTO example.users VALUES
    (1, 'Alice', 'USA', 'active', 'F'),
    (2, 'Bob', 'China', 'inactive', 'M'),
    (3, 'Charlie', 'UK', 'active', 'M'),
    (4, 'Diana', 'USA', 'active', 'F');

-- 查询
SELECT country, count() as user_count
FROM example.users
GROUP BY country
ORDER BY user_count DESC;

-- ========================================
-- String 类型
-- ========================================

-- 长度
SELECT
    length('Hello') as len,              -- 5
    lengthUTF8('你好') as len_utf8;       -- 2（不是字节长度）

-- 拼接
SELECT
    concat('Hello', ' ', 'World'),        -- Hello World
    'Hello ' || 'World';                  -- Hello World

-- 子串
SELECT
    substring('Hello World', 1, 5),      -- Hello（从 1 开始）
    substring('Hello World', 7, 5);      -- World

-- 大小写转换
SELECT
    upper('hello') as upper,              -- HELLO
    lower('WORLD') as lower;              -- world

-- ========================================
-- String 类型
-- ========================================

-- 包含
SELECT
    position('Hello World', 'World'),   -- 1
    position('Hello World', 'Python');   -- 0

-- 位置
SELECT
    position('Hello World', 'World'),        -- 7
    position('Hello World', 'Python');       -- 0

-- 替换
SELECT
    replace('Hello World', 'World', 'ClickHouse');  -- Hello ClickHouse

-- ========================================
-- String 类型
-- ========================================

-- 分割为数组
SELECT
    splitByString(',', 'apple,banana,cherry'),  -- ['apple', 'banana', 'cherry']
    splitByString(' ', 'Hello World');            -- ['Hello', 'World']

-- 连接数组
SELECT
    arrayJoin(['apple', 'banana', 'cherry']),
    arrayStringConcat(['apple', 'banana', 'cherry'], ',');  -- apple,banana,cherry

-- ========================================
-- String 类型
-- ========================================

-- ❌ 不好：低基数字符串使用 String（示例，已注释）
-- CREATE TABLE IF NOT EXISTS users_bad ON CLUSTER 'treasurycluster' (
--     id UInt64,
--     country String,   -- 重复字符串
--     status String     -- 重复字符串
-- ) ENGINE = ReplicatedMergeTree() ORDER BY id;

-- ✅ 好：低基数字符串使用 LowCardinality
CREATE TABLE IF NOT EXISTS users_good ON CLUSTER 'treasurycluster' (
    id UInt64,
    country LowCardinality(String),  -- 字典编码
    status LowCardinality(String)    -- 字典编码
) ENGINE = ReplicatedMergeTree() ORDER BY id;

-- ========================================
-- String 类型
-- ========================================

-- ✅ 推荐：MD5、UUID 使用 FixedString
CREATE TABLE IF NOT EXISTS files ON CLUSTER 'treasurycluster' (
    id UInt64,
    file_name String,
    file_md5 FixedString(32),   -- MD5 32 字符
    file_uuid FixedString(36)    -- UUID 36 字符
) ENGINE = ReplicatedMergeTree() ORDER BY id;

-- ========================================
-- String 类型
-- ========================================

-- ❌ 不好：存储大文本（示例，已注释）
-- CREATE TABLE IF NOT EXISTS logs_bad ON CLUSTER 'treasurycluster' (
--     id UInt64,
--     log_content String  -- 可能很大
-- ) ENGINE = ReplicatedMergeTree() ORDER BY id;

-- ✅ 好：大文本存储到外部，只存引用
CREATE TABLE IF NOT EXISTS logs_good ON CLUSTER 'treasurycluster' (
    id UInt64,
    log_path String,     -- 存储文件路径
    log_size UInt64
) ENGINE = ReplicatedMergeTree() ORDER BY id;
