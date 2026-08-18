# 数值类型

ClickHouse 支持多种数值类型，包括整数和浮点数。

## 整数类型

### 无符号整数 (UInt)

| 类型 | 大小 | 范围 |
|------|------|------|
| **UInt8** | 1 字节 | `0` ~ `255` |
| **UInt16** | 2 字节 | `0` ~ `65,535` |
| **UInt32** | 4 字节 | `0` ~ `4,294,967,295` |
| **UInt64** | 8 字节 | `0` ~ `18,446,744,073,709,551,615` |

### 有符号整数 (Int)

| 类型 | 大小 | 范围 |
|------|------|------|
| **Int8** | 1 字节 | `-128` ~ `127` |
| **Int16** | 2 字节 | `-32,768` ~ `32,767` |
| **Int32** | 4 字节 | `-2,147,483,648` ~ `2,147,483,647` |
| **Int64** | 8 字节 | `-9,223,372,036,854,775,808` ~ `9,223,372,036,854,775,807` |

## 浮点数类型

| 类型 | 大小 | 精度 |
|------|------|------|
| **Float32** | 4 字节 | 单精度（约 7 位小数） |
| **Float64** | 8 字节 | 双精度（约 16 位小数） |

## 使用场景详解（场景驱动选型）

> 选数值类型的本质是回答三个问题：**会不会溢出？需不需要精确？存储/查询性能优先级？**
> 先看业务量级选整数，再看精度要求选 Float/Decimal，最后用小类型换性能。

### 1. 整数：量级决定宽度

| 业务字段 | 推荐类型 | 为什么 |
|----------|---------|--------|
| 用户 ID / 订单 ID / 流水号 | UInt64 | 主键类字段量级可能突破 42 亿（UInt32 上限），一旦溢出数据损坏且无法修复 |
| 商品 ID / SKU / 广告计划 ID | UInt32 | 商品量级百万级，4B 足够，比 UInt64 省一半 |
| 状态码（0-5）、年龄、评分 | UInt8 | 0-255 够用，1 字节，压缩率最高 |
| 布尔标志（is_active、is_vip） | UInt8（0/1） | CH 无独立 Bool 类型，UInt8 承载，sum() 即计数 |
| 端口号、HTTP 状态码 | UInt16 | 0-65535 天然匹配 |
| IP 地址（点分十进制） | UInt32 | 一个 IPv4 正好 32 位，比 String 省 12 字节且可做范围比较 |
| Unix 时间戳（秒） | UInt32 | 秒级时间戳 2106 年前不溢出（见时间类型章节） |
| 温度、评分（可负） | Int8 | -128~127，覆盖室温/评分场景 |
| 账户余额（可透支） | Int64 | 有符号语义，允许负数 |
| 计数类（点击量、库存） | UInt32/UInt64 | 按量级：<42 亿 UInt32，更大 UInt64 |

**为什么小类型重要（三重复利）**：
- 存储：1 亿行 UInt8 = 100MB，UInt64 = 800MB
- 压缩：小整数重复值多，RLE/Delta 压缩率更高
- 向量化：一条 AVX2 指令处理 32 个 UInt8 vs 4 个 UInt64，吞吐差 8 倍

### 2. 浮点：什么场景"近似"可接受

Float 不精确，但**当数据本身就不是精确值**时，用 Float 是正确选择：

| 业务字段 | 推荐类型 | 为什么 |
|----------|---------|--------|
| 传感器温度/湿度/电压 | Float32 | 采集精度本就有限（±0.1°C），Float32 无损表达且省一半空间 |
| GPS 经纬度 | Float64 | 需要 6-7 位小数（约 0.1 米精度），Float32 只有约 7 位有效数字不够 |
| CTR/CVR/转化率等计算指标 | Float32 | 由除法派生的比率，本身就是近似结果，Float 无损表达 |
| 坐标、距离计算 | Float64 | 浮点运算快，适合空间计算 |
| 统计指标（均值、方差） | Float64 | 科学计算需要双精度累积 |

**反例（浮点禁区）**：金额、余额、税率、汇率、库存、积分——这些是"业务原始精确值"，必须 Decimal。

> 判别口诀：**"原始业务值精确存 Decimal，计算派生指标用 Float"**。ctr 是算出来的，存 Float32 完全够；单价是定出来的，必须 Decimal。

### 3. Decimal：精确计算的场景

| 业务字段 | 推荐类型 | 为什么 |
|----------|---------|--------|
| 订单金额、实付金额 | Decimal(18, 2) | 分单位精确，8 字节可表示 ±10^16 元 |
| 单价、折扣、运费 | Decimal(18, 2) | 逐项精确计算再相加 |
| 利率、汇率 | Decimal(18, 6) | 6 位小数（0.000001），复利计算无舍入漂移 |
| 广告结算费用 | Decimal(38, 4) | 千分位精度 + 大额，用 Decimal128 |
| 加密货币 | Decimal(76, S) | Decimal256，超大范围 |

**Decimal 精度选择公式**：总位数 = 整数位 + 小数位。
- 金额分：整数 16 位 + 小数 2 位 = Decimal(18, 2)
- 利率：整数 12 位 + 小数 6 位 = Decimal(18, 6)
- 原则：小数位由业务精度定死（金额 2、利率 6），整数位留足未来量级（10 年以上增长余量）

**性能代价**：Decimal 运算有对齐/重缩放开销，乘法比 Float 慢 2-3 倍、聚合慢 1.5 倍。**只在真正需要精确的列用 Decimal**，不要让整表都 Decimal。

### 4. 真实业务场景一览

| 业务域 | 典型字段 | 类型组合 |
|--------|---------|---------|
| 电商订单 | order_id UInt64 + amount Decimal(18,2) + sku UInt32 | 混合精度模型 |
| 日志平台 | duration_ms UInt16/UInt32 + size_bytes UInt64 | 小整数为主 |
| 金融交易 | txn_amount Decimal(18,2) + balance Int64 | 精确优先 |
| 物联网 | temperature Float32 + battery UInt8 + gps Float64 | 浮点+小整数 |
| 广告结算 | spend Decimal(38,4) + ctr Float32 | 原始精确 + 派生近似 |

## 使用示例

### 基础使用

```sql
-- 创建表
CREATE TABLE example.numeric_types (
    id UInt64,
    user_id UInt32,
    age UInt8,
    balance Int64,
    temperature Float32,
    price Float64
) ENGINE = MergeTree ORDER BY id;

-- 插入数据
INSERT INTO example.numeric_types VALUES
    (1, 1001, 25, 1000, 36.5, 99.99),
    (2, 1002, 30, -500, 37.2, 199.99);

-- 查询数据
SELECT * FROM example.numeric_types;
```

### 数值计算

```sql
-- 基础运算
SELECT
    10 + 5 as add,          -- 15
    10 - 5 as subtract,     -- 5
    10 * 5 as multiply,     -- 50
    10 / 3 as divide,       -- 3.333...
    10 % 3 as modulo;       -- 1

-- 取整
SELECT
    floor(3.7) as floor_down,   -- 3
    ceil(3.2) as ceil_up,      -- 4
    round(3.5) as round_nearest, -- 4
    trunc(3.9) as truncate;     -- 3

-- 绝对值
SELECT
    abs(-10) as abs_positive,   -- 10
    abs(10) as abs_original;    -- 10
```

### 聚合函数

```sql
-- 创建测试表
CREATE TABLE example.sales (
    id UInt64,
    product_id UInt32,
    quantity UInt16,
    price UInt32,
    total_price UInt64,
    rating Float32
) ENGINE = MergeTree ORDER BY id;

-- 插入数据
INSERT INTO example.sales VALUES
    (1, 100, 5, 100, 500, 4.5),
    (2, 101, 3, 200, 600, 4.8),
    (3, 100, 2, 100, 200, 4.2),
    (4, 102, 1, 300, 300, 4.9);

-- 聚合函数
SELECT
    sum(quantity) as total_quantity,
    avg(price) as avg_price,
    min(rating) as min_rating,
    max(rating) as max_rating,
    count() as total_rows
FROM example.sales;

-- GROUP BY 聚合
SELECT
    product_id,
    sum(quantity) as total_quantity,
    sum(total_price) as total_sales,
    avg(rating) as avg_rating
FROM example.sales
GROUP BY product_id
ORDER BY product_id;
```

## 最佳实践

### 1. 选择合适的大小

```sql
-- ❌ 不好：使用 UInt64 存储年龄
CREATE TABLE users_bad (
    id UInt64,
    age UInt64      -- 浪费空间
) ENGINE = MergeTree ORDER BY id;

-- ✅ 好：使用 UInt8 存储年龄
CREATE TABLE users_good (
    id UInt64,
    age UInt8       -- 0-255，足够
) ENGINE = MergeTree ORDER BY id;
```

### 2. 主键使用 UInt64

```sql
-- ✅ 推荐：主键使用 UInt64
CREATE TABLE events (
    id UInt64,
    user_id UInt64,
    event_time DateTime
) ENGINE = MergeTree ORDER BY (id, event_time);
```

### 3. 数值溢出处理

```sql
-- 检查溢出
SELECT
    cast(toInt8(200) as UInt8);  -- 会溢出，产生错误

-- 使用 toUInt64 避免溢出
SELECT
    cast(200 as UInt64);  -- 正常
```

---

**最后更新**: 2026-01-19
