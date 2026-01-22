# 数据类型优化

合理的数据类型选择是 ClickHouse 性能优化的基础，可以显著提升查询性能和存储效率。

## 基本原则

### 1. 使用最小的数据类型

```sql
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
```

**性能提升**: 2-5x（存储和查询）

### 2. 避免 Nullable

```sql
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
```

**性能提升**: 1.5-3x

### 3. 使用定长类型

```sql
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
```

**性能提升**: 1.2-2x

### 4. 使用枚举类型

```sql
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
```

**性能提升**: 1.5-3x

### 5. 使用专用类型

```sql
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
```

**性能提升**: 1.3-2x

## 数值类型优化

### 整数类型

| 类型 | 字节数 | 范围 | 适用场景 |
|------|--------|------|---------|
| UInt8 | 1 | 0-255 | 小数值、状态、枚举 |
| UInt16 | 2 | 0-65535 | 端口、小ID |
| UInt32 | 4 | 0-4294967295 | 用户ID、订单ID |
| UInt64 | 8 | 0-2^64-1 | 大ID、事务ID |
| Int8 | 1 | -128-127 | 小数值、状态 |
| Int16 | 2 | -32768-32767 | 温度、坐标 |
| Int32 | 4 | -2147483648-2147483647 | 通用整数 |
| Int64 | 8 | -2^63-2^63-1 | 大整数、时间戳 |

```sql
-- ✅ 合理的整数类型
CREATE TABLE users (
    user_id UInt32,      -- 0-42 亿
    age UInt8,           -- 0-255
    score Int16,         -- -32768-32767
    balance Int64,       -- 大数值
    created_at DateTime
) ENGINE = MergeTree()
ORDER BY user_id;
```

### 浮点类型

| 类型 | 字节数 | 精度 | 适用场景 |
|------|--------|------|---------|
| Float32 | 4 | ~7 位小数 | 金额、坐标、温度 |
| Float64 | 8 | ~15 位小数 | 高精度计算 |

```sql
-- ✅ 合理的浮点类型
CREATE TABLE products (
    product_id UInt32,
    price Float32,        -- 金额（7 位精度足够）
    weight Float32,       -- 重量
    rating Float32,       -- 评分
    discount Float32      -- 折扣
) ENGINE = MergeTree()
ORDER BY product_id;
```

## 字符串类型优化

### String vs FixedString

```sql
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
```

### LowCardinality

```sql
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
```

### Enum 类型

```sql
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
```

## Nullable 优化

### 避免使用 Nullable

```sql
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
```

### Nullable 性能影响

| 特性 | 非 Nullable | Nullable | 性能影响 |
|------|-----------|----------|---------|
| 存储大小 | 1 字节 | 2 字节 | 2x |
| 查询性能 | 基准 | 降低 10-30% | 1.1-1.3x |
| 聚合性能 | 基准 | 降低 10-30% | 1.1-1.3x |

## 日期时间类型优化

### DateTime vs Date

```sql
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
```

### DateTime vs DateTime64

```sql
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
```

## 数组类型优化

### Array vs Tuple

```sql
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
```

## 数据类型优化示例

### 示例 1: 用户表优化

```sql
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
```

**性能提升**: 2-3x（存储和查询）

### 示例 2: 事件表优化

```sql
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
```

**性能提升**: 1.5-2.5x（存储和查询）

### 示例 3: 订单表优化

```sql
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
```

**性能提升**: 2-3x（存储和查询）

## 数据类型检查清单

- [ ] 是否使用最小类型？
  - [ ] 整数：UInt8/16/32/64、Int8/16/32/64
  - [ ] 浮点：Float32/64
  - [ ] 日期：Date vs DateTime vs DateTime64

- [ ] 是否避免 Nullable？
  - [ ] 使用默认值代替 Nullable
  - [ ] 评估 Nullable 的必要性
  - [ ] 考虑性能影响

- [ ] 是否使用专用类型？
  - [ ] Enum：低基数字符串
  - [ ] LowCardinality：< 10000 唯一值
  - [ ] FixedString：已知长度
  - [ ] IPv4/IPv6：IP 地址
  - [ ] UUID：唯一标识符

- [ ] 是否使用合适的数组类型？
  - [ ] Array：同类数据
  - [ ] Tuple：不同类型数据

## 性能提升

| 优化方法 | 性能提升 |
|---------|---------|
| 使用最小类型 | 2-5x |
| 避免 Nullable | 1.5-3x |
| 使用专用类型 | 1.3-2x |
| 使用定长类型 | 1.2-2x |
| 使用 LowCardinality | 1.5-3x |

## 相关文档

- [05-data-type/](../05-data-type/) - 数据类型详解
- [11_query_profiling.md](./11_query_profiling.md) - 查询分析和 Profiling
