# 字符串类型

ClickHouse 支持多种字符串类型，用于存储文本数据。

## 字符串类型

### String

- **描述**: 任意长度的字符串
- **大小**: 不固定，根据实际内容
- **使用场景**: 存储文本、日志、JSON、XML 等

### FixedString(N)

- **描述**: 固定长度为 N 的字符串
- **大小**: N 字节
- **使用场景**: 存储定长数据（MD5、UUID、哈希值）

### LowCardinality(String)

- **描述**: 使用字典编码的低基数字符串
- **大小**: 根据唯一值数量动态调整
- **使用场景**: 存储低基数字符串（国家、状态、类别）

## 使用示例

### String 类型

```sql
-- 创建表
CREATE TABLE example.strings (
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
```

### FixedString 类型

```sql
-- 创建表（存储 MD5 哈希）
CREATE TABLE example.files (
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
```

### LowCardinality 类型

```sql
-- 创建表（国家、状态）
CREATE TABLE example.users (
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
```

## 字符串函数

### 字符串操作

```sql
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
```

### 字符串搜索

```sql
-- 包含
SELECT
    hasSubString('Hello World', 'World'),   -- 1
    hasSubString('Hello World', 'Python');   -- 0

-- 位置
SELECT
    position('Hello World', 'World'),        -- 7
    position('Hello World', 'Python');       -- 0

-- 替换
SELECT
    replace('Hello World', 'World', 'ClickHouse');  -- Hello ClickHouse
```

### 字符串分割

```sql
-- 分割为数组
SELECT
    splitByString(',', 'apple,banana,cherry'),  -- ['apple', 'banana', 'cherry']
    splitByString(' ', 'Hello World');            -- ['Hello', 'World']

-- 连接数组
SELECT
    arrayJoin(['apple', 'banana', 'cherry']),
    arrayStringConcat(['apple', 'banana', 'cherry'], ',');  -- apple,banana,cherry
```

## 最佳实践

### 1. 使用 LowCardinality 优化

```sql
-- ❌ 不好：低基数字符串使用 String
CREATE TABLE users_bad (
    id UInt64,
    country String,   -- 重复字符串
    status String     -- 重复字符串
) ENGINE = MergeTree ORDER BY id;

-- ✅ 好：低基数字符串使用 LowCardinality
CREATE TABLE users_good (
    id UInt64,
    country LowCardinality(String),  -- 字典编码
    status LowCardinality(String)    -- 字典编码
) ENGINE = MergeTree ORDER BY id;
```

### 2. FixedString 用于定长数据

```sql
-- ✅ 推荐：MD5、UUID 使用 FixedString
CREATE TABLE files (
    id UInt64,
    file_name String,
    file_md5 FixedString(32),   -- MD5 32 字符
    file_uuid FixedString(36)    -- UUID 36 字符
) ENGINE = MergeTree ORDER BY id;
```

### 3. 避免存储过大的字符串

```sql
-- ❌ 不好：存储大文本
CREATE TABLE logs_bad (
    id UInt64,
    log_content String  -- 可能很大
) ENGINE = MergeTree ORDER BY id;

-- ✅ 好：大文本存储到外部，只存引用
CREATE TABLE logs_good (
    id UInt64,
    log_path String,     -- 存储文件路径
    log_size UInt64
) ENGINE = MergeTree ORDER BY id;
```

---

**最后更新**: 2026-01-19
