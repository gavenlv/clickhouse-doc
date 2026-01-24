-- 创建数据库（如果存在则不创建）
CREATE DATABASE IF NOT EXISTS example;


DROP TABLE IF EXISTS example.strings;
CREATE TABLE IF NOT EXISTS example.strings (
    id UInt64,
    message String,
    email String,
    url String
) ENGINE = MergeTree ORDER BY id;

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
DROP TABLE IF EXISTS example.files;
CREATE TABLE IF NOT EXISTS example.files (
    id UInt64,
    file_name String,
    file_hash FixedString(32),  -- MD5 32 字符
    file_size UInt64
) ENGINE = MergeTree ORDER BY id;

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
DROP TABLE IF EXISTS example.users;
CREATE TABLE IF NOT EXISTS example.users (
    id UInt64,
    name String,
    country LowCardinality(String),  -- 只有 200 个国家
    status LowCardinality(String),    -- 只有少量状态
    gender LowCardinality(String)     -- 只有 'M', 'F', 'U'
) ENGINE = MergeTree ORDER BY id;

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

-- ❌ 不好：低基数字符串使用 String
CREATE TABLE IF NOT EXISTS users_bad (
    id UInt64,
    country String,   -- 重复字符串
    status String     -- 重复字符串
) ENGINE = MergeTree ORDER BY id;

-- ✅ 好：低基数字符串使用 LowCardinality
CREATE TABLE IF NOT EXISTS users_good (
    id UInt64,
    country LowCardinality(String),  -- 字典编码
    status LowCardinality(String)    -- 字典编码
) ENGINE = MergeTree ORDER BY id;

-- ========================================
-- String 类型
-- ========================================

-- ✅ 推荐：MD5、UUID 使用 FixedString
CREATE TABLE IF NOT EXISTS files (
    id UInt64,
    file_name String,
    file_md5 FixedString(32),   -- MD5 32 字符
    file_uuid FixedString(36)    -- UUID 36 字符
) ENGINE = MergeTree ORDER BY id;

-- ========================================
-- String 类型
-- ========================================

-- ❌ 不好：存储大文本
CREATE TABLE IF NOT EXISTS logs_bad (
    id UInt64,
    log_content String  -- 可能很大
) ENGINE = MergeTree ORDER BY id;

-- ✅ 好：大文本存储到外部，只存引用
CREATE TABLE IF NOT EXISTS logs_good (
    id UInt64,
    log_path String,     -- 存储文件路径
    log_size UInt64
) ENGINE = MergeTree ORDER BY id;
