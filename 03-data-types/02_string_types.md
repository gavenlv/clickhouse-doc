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

## 使用场景详解（场景驱动选型）

> 选字符串类型的本质是回答一个问题：**这个字段的值可枚举吗？基数是多少？**
> 高基数/不可控 → String；定长二进制标识 → FixedString；低基数枚举 → LowCardinality。

### 1. String：高基数、不可控、自由文本

**适用场景**：
| 业务字段 | 为什么用 String |
|----------|----------------|
| 日志原文 message | 长度不可控、内容任意，无法枚举 |
| 请求/响应体、JSON blob | 结构化文本整体存储，后续用 JSON 函数解析 |
| URL（含参数）、UserAgent | 基数极高（百万级），字典编码会退化 |
| 姓名、地址、邮箱、电话 | 变长自由文本，不可枚举 |
| 大文本（说明、评论） | 通用字符串，长度不定 |

**为什么这些场景不能用别的类型**：
- 用 LowCardinality：基数超过 1 万自动退化为普通 String，且每次写入多一次字典查找开销，**更慢更占内存**
- 用 FixedString：变长文本会被**截断**（数据丢失）或**补 \0**（产生脏数据）
- String 是变长存储 + 长度前缀（Varint 1-9 字节），任何长度都能无损存储

**String 性能优化技巧**：
- 压缩后性能依然好：日志/JSON 文本压缩率 5-10x
- 需要 LIKE/搜索用 `hasSubString`、`position` 等函数，避免 `%` 通配全表扫
- 大字段（>64KB）会存到 `large_objects` 列文件，查询不选它就不读

### 2. FixedString(N)：定长二进制标识

**适用场景**：
| 业务字段 | 推荐 N | 为什么 |
|----------|--------|--------|
| MD5 哈希 | FixedString(16) | MD5 是 16 字节二进制；若存 32 字符十六进制文本用 FixedString(32) |
| UUID | FixedString(16) | UUID 本质 16 字节二进制；文本形式（36 字符）可转二进制省 20 字节/行 |
| 国家代码（ISO-3166） | FixedString(2) | 固定 2 字符 |
| 货币代码（ISO-4217） | FixedString(3) | 固定 3 字符 |
| SHA-256 哈希 | FixedString(32) | 32 字节二进制 |

**为什么定长数据用 FixedString**：
- String 每行要存长度前缀（Varint），FixedString 无前缀，省 1-9 字节/行
- 定长列压缩率更高（无长度变化干扰 Delta/RLE）
- 语义明确：值必须恰好 N 字节

**陷阱（务必注意）**：
- 长度不足 N：写入时自动补 `\0`，查询时 `length()` 会算上补位，比较需 `trimRight` 或直接用 `fixedString` 转换比较
- 长度超过 N：**静默截断**，数据丢失不报错
- 存文本字符串（如"hello"）→ FixedString(5) 恰好；但存"你好世界"（UTF-8 12 字节）→ FixedString(6) 会截断！**N 是字节数不是字符数**
- 不要用 FixedString 存任意用户输入，校验成本高且容易踩补位坑

### 3. LowCardinality(String)：低基数字典编码

**适用场景**（基数 < 10,000 的枚举值）：
| 业务字段 | 典型基数 | 为什么用 |
|----------|---------|---------|
| 国家/地区 | ~200 | 字典编码，GROUP BY 秒回 |
| 城市 | 几千 | 同上 |
| 订单状态、支付方式 | < 50 | 枚举语义 + 高性能 |
| 渠道来源、设备类型 | 几百 | 维度查询密集 |
| 事件名（埋点） | 几百 | GROUP BY event_name 高频 |
| 服务名、host、机房 | 几十 | 日志/监控维度 |
| 版本号、语言、币种 | 几十 | 有限枚举 |

**为什么省**：列只存 1-2 字节字典索引（UInt8/UInt16），字典值独立存储。平均 15 字节的字符串 → 2 字节，省 5-10x，且整数索引的压缩、比较、分组都更快。

**禁用的高基数场景**：
| 字段 | 基数 | 后果 |
|------|------|------|
| URL（含参数） | 百万级 | 字典退化为普通 String，写入多一次查找开销 |
| UserAgent | 百万级 | 同上 |
| UUID / session_id | 极高 | 字典无共享值，纯浪费 |
| 手机号 / 邮箱 | 极高 | 同上 |
| message 日志正文 | 不可控 | 同上 |

**基数接近 1 万的临界点**：字典要全驻内存（约基数×平均长度），超过 1 万自动退化；即使 5 千-1 万，字典查找的 CPU 开销也可能抵不过省下的存储，**高并发写入场景尤其要谨慎**。

### 4. 场景决策表（快速查表）

| 业务字段 | 推荐类型 | 一句话理由 |
|----------|---------|-----------|
| 日志正文 | String | 不可枚举自由文本 |
| 请求 URL | String | 高基数含参数 |
| MD5 / 哈希 | FixedString(16/32) | 定长二进制 |
| 国家 / 状态 / 渠道 | LowCardinality(String) | 基数<1万 |
| 事件名 / 服务名 | LowCardinality(String) | 维度分组高频 |
| 手机号 / 邮箱 | String | 高基数，禁用字典 |
| 国家代码 ISO | FixedString(2) | 定长代码 |

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
