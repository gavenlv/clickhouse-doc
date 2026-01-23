-- ================================================
-- 09_data_types_examples.sql
-- 从 09_data_types.md 提取的 SQL 示例
-- 提取时间: 2026-01-23 14:40:17
-- ================================================


-- ========================================
-- 1. 使用最小的数据类型
-- ========================================

-- ✅ 使用最小类型
CREATE TABLE users (
    user_id UInt32,      -- 0-42 亿（4 字节）
    age UInt8,           -- 0-255（1 字节）
    status UInt8,         -- 枚举值（1 字节）
    created_at DateTime   -- 8 字节
) ENGINE = MergeTree()
ORDER BY user_id;

-- ❌ 使用过大类型
CREATE TABLE users (
    user_id UInt64,      -- 0-2^64-1（8 字节）
    age String,          -- 不必要
    status String,        -- 不必要
    created_at DateTime64 -- 不需要微秒精度
) ENGINE = MergeTree()
ORDER BY user_id;

-- ========================================
-- 1. 使用最小的数据类型
-- ========================================

-- ✅ 使用非 Nullable 类型
CREATE TABLE users (
    user_id UInt32,
    username String,
    email String,
    status UInt8 DEFAULT 0  -- 默认值代替 Nullable
) ENGINE = MergeTree()
ORDER BY user_id;

-- ❌ 使用 Nullable 类型
CREATE TABLE users (
    user_id UInt32,
    username Nullable(String),
    email Nullable(String),
    status Nullable(UInt8)  -- 不必要
) ENGINE = MergeTree()
ORDER BY user_id;

-- ========================================
-- 1. 使用最小的数据类型
-- ========================================

-- ✅ 使用定长类型
CREATE TABLE events (
    event_id UInt64,
    user_id UInt32,
    event_type FixedString(16),  -- 定长字符串
    event_time DateTime
) ENGINE = MergeTree()
ORDER BY (user_id, event_time);

-- ❌ 使用变长类型
CREATE TABLE events (
    event_id UInt64,
    user_id UInt32,
    event_type String,  -- 变长字符串
    event_time DateTime
) ENGINE = MergeTree()
ORDER BY (user_id, event_time);

-- ========================================
-- 1. 使用最小的数据类型
-- ========================================

-- ✅ 使用 Enum 类型
CREATE TABLE orders (
    order_id UInt64,
    status Enum8('pending'=1, 'paid'=2, 'shipped'=3, 'completed'=4, 'cancelled'=5),
    priority Enum8('low'=1, 'medium'=2, 'high'=3),
    created_at DateTime
) ENGINE = MergeTree()
ORDER BY order_id;

-- ❌ 使用 String 类型
CREATE TABLE orders (
    order_id UInt64,
    status String,  -- 不必要
    priority String,  -- 不必要
    created_at DateTime
) ENGINE = MergeTree()
ORDER BY order_id;

-- ========================================
-- 1. 使用最小的数据类型
-- ========================================

-- ✅ 使用专用类型
CREATE TABLE events (
    event_id UInt64,
    user_id UInt32,
    ip_addr IPv4,  -- IP 地址
    event_time DateTime,
    url String
) ENGINE = MergeTree()
ORDER BY (user_id, event_time);

-- ❌ 使用 String 存储数字
CREATE TABLE events (
    event_id UInt64,
    user_id UInt32,
    ip_addr String,  -- 不必要
    event_time DateTime,
    url String
) ENGINE = MergeTree()
ORDER BY (user_id, event_time);

-- ========================================
-- 1. 使用最小的数据类型
-- ========================================

-- ✅ 合理的整数类型
CREATE TABLE users (
    user_id UInt32,      -- 0-42 亿
    age UInt8,           -- 0-255
    score Int16,         -- -32768-32767
    balance Int64,       -- 大数值
    created_at DateTime
) ENGINE = MergeTree()
ORDER BY user_id;

-- ========================================
-- 1. 使用最小的数据类型
-- ========================================

-- ✅ 合理的浮点类型
CREATE TABLE products (
    product_id UInt32,
    price Float32,        -- 金额（7 位精度足够）
    weight Float32,       -- 重量
    rating Float32,       -- 评分
    discount Float32      -- 折扣
) ENGINE = MergeTree()
ORDER BY product_id;

-- ========================================
-- 1. 使用最小的数据类型
-- ========================================

-- ✅ 使用 FixedString（已知长度）
CREATE TABLE users (
    user_id UInt32,
    username String,
    phone FixedString(11),  -- 手机号（11 位）
    email String,
    created_at DateTime
) ENGINE = MergeTree()
ORDER BY user_id;

-- ❌ 使用 String（已知长度）
CREATE TABLE users (
    user_id UInt32,
    username String,
    phone String,  -- 不必要
    email String,
    created_at DateTime
) ENGINE = MergeTree()
ORDER BY user_id;

-- ========================================
-- 1. 使用最小的数据类型
-- ========================================

-- ✅ 使用 LowCardinality（低基数）
CREATE TABLE events (
    event_id UInt64,
    user_id UInt32,
    event_type LowCardinality(String),  -- 低基数（< 10000 个唯一值）
    event_time DateTime,
    event_data String
) ENGINE = MergeTree()
ORDER BY (user_id, event_time);

-- ❌ 使用 String（低基数）
CREATE TABLE events (
    event_id UInt64,
    user_id UInt32,
    event_type String,  -- 不必要
    event_time DateTime,
    event_data String
) ENGINE = MergeTree()
ORDER BY (user_id, event_time);

-- ========================================
-- 1. 使用最小的数据类型
-- ========================================

-- ✅ 使用 Enum8（低基数）
CREATE TABLE orders (
    order_id UInt64,
    status Enum8('pending'=1, 'paid'=2, 'shipped'=3, 'completed'=4, 'cancelled'=5),
    created_at DateTime
) ENGINE = MergeTree()
ORDER BY order_id;

-- ✅ 使用 Enum16（高基数）
CREATE TABLE products (
    product_id UInt32,
    category Enum16('electronics'=1, 'clothing'=2, 'food'=3, ..., 'books'=100),
    created_at DateTime
) ENGINE = MergeTree()
ORDER BY product_id;

-- ========================================
-- 1. 使用最小的数据类型
-- ========================================

-- ✅ 使用默认值
CREATE TABLE users (
    user_id UInt32,
    username String,
    email String,
    status UInt8 DEFAULT 0,  -- 默认值
    created_at DateTime
) ENGINE = MergeTree()
ORDER BY user_id;

-- ❌ 使用 Nullable
CREATE TABLE users (
    user_id UInt32,
    username Nullable(String),
    email Nullable(String),
    status Nullable(UInt8),
    created_at DateTime
) ENGINE = MergeTree()
ORDER BY user_id;

-- ========================================
-- 1. 使用最小的数据类型
-- ========================================

-- ✅ 使用 Date（只需要日期）
CREATE TABLE users (
    user_id UInt32,
    birth_date Date,  -- 只需要日期
    register_date DateTime  -- 需要时间
) ENGINE = MergeTree()
ORDER BY user_id;

-- ❌ 使用 DateTime（只需要日期）
CREATE TABLE users (
    user_id UInt32,
    birth_date DateTime,  -- 不必要
    register_date DateTime
) ENGINE = MergeTree()
ORDER BY user_id;

-- ========================================
-- 1. 使用最小的数据类型
-- ========================================

-- ✅ 使用 DateTime（秒级精度）
CREATE TABLE events (
    event_id UInt64,
    user_id UInt32,
    event_time DateTime,  -- 秒级精度足够
    event_data String
) ENGINE = MergeTree()
ORDER BY (user_id, event_time);

-- ✅ 使用 DateTime64（需要毫秒级）
CREATE TABLE metrics (
    metric_id UInt64,
    metric_value Float64,
    timestamp DateTime64(3)  -- 毫秒级精度
) ENGINE = MergeTree()
ORDER BY timestamp;

-- ========================================
-- 1. 使用最小的数据类型
-- ========================================

-- ✅ 使用 Array（同类数据）
CREATE TABLE users (
    user_id UInt32,
    tags Array(String),  -- 标签数组
    scores Array(UInt16),  -- 分数数组
    created_at DateTime
) ENGINE = MergeTree()
ORDER BY user_id;

-- ❌ 使用多个列（不适合数组）
CREATE TABLE users (
    user_id UInt32,
    tag1 String,
    tag2 String,
    tag3 String,
    tag4 String,
    tag5 String,
    score1 UInt16,
    score2 UInt16,
    score3 UInt16,
    score4 UInt16,
    score5 UInt16,
    created_at DateTime
) ENGINE = MergeTree()
ORDER BY user_id;

-- ========================================
-- 1. 使用最小的数据类型
-- ========================================

-- 优化前
CREATE TABLE users (
    user_id UInt64,
    age String,
    status String,
    email Nullable(String),
    phone String,
    created_at DateTime64
) ENGINE = MergeTree()
ORDER BY user_id;

-- 优化后
CREATE TABLE users (
    user_id UInt32,              -- 4 字节（足够）
    age UInt8,                    -- 1 字节（0-255）
    status Enum8('active'=1, 'inactive'=2, 'banned'=3),  -- 1 字节
    email String,                  -- 非 Nullable
    phone FixedString(11),         -- 定长
    created_at DateTime            -- 秒级精度
) ENGINE = MergeTree()
ORDER BY user_id;

-- ========================================
-- 1. 使用最小的数据类型
-- ========================================

-- 优化前
CREATE TABLE events (
    event_id UInt64,
    user_id UInt64,
    event_type String,
    ip_address String,
    event_time DateTime64
) ENGINE = MergeTree()
ORDER BY (user_id, event_time);

-- 优化后
CREATE TABLE events (
    event_id UInt64,
    user_id UInt32,                      -- 4 字节
    event_type LowCardinality(String),      -- 低基数
    ip_address IPv4,                      -- 专用类型
    event_time DateTime                   -- 秒级精度
) ENGINE = MergeTree()
ORDER BY (user_id, event_time);

-- ========================================
-- 1. 使用最小的数据类型
-- ========================================

-- 优化前
CREATE TABLE orders (
    order_id UInt64,
    user_id UInt64,
    amount String,            -- 不必要
    status String,
    priority String,
    created_at DateTime64
) ENGINE = MergeTree()
ORDER BY order_id;

-- 优化后
CREATE TABLE orders (
    order_id UInt64,
    user_id UInt32,                  -- 4 字节
    amount Float32,                  -- 金额（7 位精度）
    status Enum8('pending'=1, 'paid'=2, 'shipped'=3, 'completed'=4, 'cancelled'=5),
    priority Enum8('low'=1, 'medium'=2, 'high'=3),
    created_at DateTime               -- 秒级精度
) ENGINE = MergeTree()
ORDER BY order_id;
