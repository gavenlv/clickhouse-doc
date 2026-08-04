# ClickHouse 数据类型（专家级详解）

> 本章是 schema 设计的基础。读完本章，你应能：为每个字段选择最省空间又最准确的类型、理解 LowCardinality 的字典编码原理、知道 Decimal vs Float 的精度与性能权衡、明白 Nullable 为什么有额外开销、掌握时间类型内部存储与时区处理、精通复合类型（Array/Tuple/Map/Nested）选型、理解 AggregateFunction 状态存储原理、规避类型转换陷阱。
>
> 配套文件：10 个文件（2 个 MD + 8 个 SQL），覆盖 CH 全部数据类型体系

---

## 1. 本章解决什么问题（Why）

| 痛点 | 本章如何解答 |
|------|--------------|
| 字段类型选大了浪费空间，选小了溢出，怎么选？ | §3.1 数值类型选型原理 |
| LowCardinality 神器到底怎么省空间的？什么时候不能用？ | §3.2 LowCardinality 字典编码原理 |
| 金额用 Float 还是 Decimal？性能差多少？ | §3.3 Decimal vs Float 精度原理 |
| Nullable 为什么有性能开销？什么时候该用？ | §3.4 Nullable 存储原理 |
| Date/DateTime/DateTime64 内部怎么存？时区怎么处理？ | §3.5 时间类型内部表示 + 03_date_time_types.sql |
| String / FixedString / LowCardinality 怎么选？ | §3.6 字符串类型决策表 |
| Array/Tuple/Map/Nested 四类复合类型怎么选？性能差多少？ | 04_compound_types.sql 全套对比 |
| Enum8 和 LowCardinality(String) 怎么选？UUID/IPv4 存 String 浪费多少？ | 05_special_types.sql 存储对比实验 |
| AggregateFunction 存的是什么二进制状态？和 SimpleAggregateFunction 区别？ | 06_aggregate_function_types.sql 原理 + 实战 |
| CAST 和隐式转换有什么陷阱？溢出不报错怎么办？ | 07_type_conversion.sql 全套陷阱演示 |

---

## 2. 类型体系全景

```
┌─────────────────────────────────────────────────────────────────┐
│                   ClickHouse 数据类型分类                          │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ① 数值类型                                                      │
│     ├─ 整数: UInt8/16/32/64/256, Int8/16/32/64/256              │
│     ├─ 浮点: Float32, Float64                                   │
│     └─ 定点: Decimal32/64/128/256                              │
│                                                                  │
│  ② 字符串类型                                                    │
│     ├─ String (变长)                                             │
│     ├─ FixedString(N) (定长)                                    │
│     └─ LowCardinality(String) (字典编码)                         │
│                                                                  │
│  ③ 时间类型                                                      │
│     ├─ Date (天数, UInt16)                                       │
│     ├─ DateTime (秒, UInt32)                                     │
│     └─ DateTime64(N) (亚秒, 支持毫秒/微秒/纳秒)                  │
│                                                                  │
│  ④ 复合类型                                                      │
│     ├─ Array(T)                                                  │
│     ├─ Tuple(T1, T2, ...)                                       │
│     ├─ Map(K, V)                                                │
│     └─ Nested(name1 Type1, ...)                                 │
│                                                                  │
│  ⑤ 特殊类型                                                      │
│     ├─ Nullable(T)                                               │
│     ├─ UUID                                                      │
│     ├─ IPv4 / IPv6                                              │
│     ├─ Enum8 / Enum16                                           │
│     └─ JSON (实验)                                              │
│                                                                  │
│  ⑥ 聚合状态类型                                                  │
│     └─ AggregateFunction(func, T)  (配合 *State 函数)            │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

---

## 3. 核心原理详解

### 3.1 数值类型选型原理

**原理**：ClickHouse 是列式存储，列宽直接决定 I/O 量和压缩率。选"刚好够用"的最小类型是优化的第一步。

| 类型 | 范围 | 大小 | 典型场景 |
|------|------|------|----------|
| UInt8 | 0 ~ 255 | 1B | 布尔、状态码、年龄 |
| UInt16 | 0 ~ 65,535 | 2B | 端口、小计数 |
| UInt32 | 0 ~ 42亿 | 4B | IP 值、时间戳(秒) |
| UInt64 | 0 ~ 1844京 | 8B | 主键、ID |
| Int8 | -128 ~ 127 | 1B | 温度、评分 |
| Float32 | ±3.4e38 | 4B | 坐标、百分比 |
| Float64 | ±1.7e308 | 8B | 科学计算 |

**为什么选最小类型？**
- 列式压缩前，1 亿行 UInt8 占 100MB，UInt64 占 800MB
- 压缩后差异仍存在（UInt8 压缩率更高）
- 向量化处理时，小类型一条 SIMD 指令处理更多值

**决策表**：
| 场景 | ❌ 错误 | ✅ 正确 | 原因 |
|------|--------|---------|------|
| 年龄 | UInt64 | UInt8 | 0-255 够用 |
| 用户 ID | UInt32 | UInt64 | 防溢出 |
| 金额(分) | Float64 | Decimal64/UInt64 | 避免浮点误差 |
| 状态(0-5) | String | UInt8/Enum8 | 省空间 |

### 3.2 LowCardinality 字典编码原理

**原理**：LowCardinality(String) 用**字典编码**——把字符串映射为 UInt8/UInt16 的整数索引，实际存储的是整数而非字符串。

```
普通 String:                    LowCardinality(String):
┌──────────────────┐            ┌──────────────────┐
│ "China"          │            │ 字典:            │
│ "China"          │            │  0 → "China"     │
│ "USA"            │            │  1 → "USA"       │
│ "China"          │            │  2 → "Japan"     │
│ "Japan"          │            └──────────────────┘
│ "China"          │            ┌──────────────────┐
│ ...              │            │ 0,0,1,0,2,0,... │ ← 只存索引(1字节)
└──────────────────┘            └──────────────────┘

每行存完整字符串(占N字节)       每行只存索引(1-2字节)
```

**适用条件**：
- 基数 < 10,000（不同值的数量）
- 超过 10,000 会自动退化为普通 String（且有转换开销）
- **绝对禁用**于：UUID、URL、自由文本、用户 ID 等高基数字段

**性能收益**：
- 存储省 5-10x（存索引而非字符串）
- 压缩率更高（整数列比字符串列好压）
- 比较更快（整数比较 vs 字符串比较）
- GROUP BY 更快（按整数分组）

| 场景 | 基数 | 用 LowCardinality？ |
|------|------|---------------------|
| 国家 | ~200 | ✅ 强烈推荐 |
| 状态码 | <100 | ✅ 强烈推荐 |
| HTTP method | 5-10 | ✅ |
| 用户 ID | 百万级 | ❌ 禁用 |
| URL | 高基数 | ❌ 禁用 |
| 任意文本 | 不可控 | ❌ 禁用 |

### 3.3 Decimal vs Float 精度原理

**原理**：
- Float 是**二进制浮点**（IEEE 754），无法精确表示十进制小数（如 0.1 存为 0.1000000000000000055...）
- Decimal 是**定点数**，用整数存储 + 固定小数位，精确到指定小数位

```
Float64 存储 0.1 + 0.2:
  0.1 → 0.1000000000000000055...
  0.2 → 0.2000000000000000111...
  相加 → 0.30000000000000004  ← 不是 0.3!

Decimal64(2) 存储 0.1 + 0.2:
  0.1 → 内部存 10 (×10^2)
  0.2 → 内部存 20
  相加 → 30 → 0.30  ← 精确
```

**Decimal 类型选择**：
| 类型 | 有效位数 | 范围 | 场景 |
|------|----------|------|------|
| Decimal32(S) | 1-9 位 | ±10^9 | 小金额(分) |
| Decimal64(S) | 1-18 位 | ±10^18 | 标准金额 |
| Decimal128(S) | 1-38 位 | ±10^38 | 大额、高精度 |
| Decimal256(S) | 1-76 位 | ±10^76 | 加密货币 |

**性能对比**：
| 操作 | Float64 | Decimal64 | 差距 |
|------|---------|-----------|------|
| 加法 | 快 | 略慢(整数运算+对齐) | 1.2x |
| 乘法 | 快 | 慢(需重缩放) | 2-3x |
| 聚合 sum | 快 | 略慢 | 1.5x |
| 存储 | 8B | 8B | 相同 |

**决策**：金额、利率等需精确计算用 Decimal；统计/科学计算用 Float。

### 3.4 Nullable 存储原理

**原理**：Nullable(T) 不只存 T 的值，还额外存一个 **NULL 掩码**（每行 1 bit，8192 行约 1KB）。

```
普通 UInt8:                Nullable(UInt8):
┌──────────┐               ┌──────────┐ ┌──────────┐
│ 10       │               │ 10       │ │ 0 (非空) │
│ 20       │               │ 20       │ │ 0        │
│ 30       │               │ 0 (占位) │ │ 1 (NULL) │
└──────────┘               │ 40       │ │ 0        │
                           └──────────┘ └──────────┘
3 字节                      3 字节 + 3 bit 掩码 + 额外文件
```

**额外开销**：
- 存储：多一个掩码列
- 查询：每行需检查掩码，无法完全向量化
- 索引：Nullable 列不能作为主键/排序键
- 聚合：需处理 NULL 语义

**决策表**：
| 场景 | 推荐 | 原因 |
|------|------|------|
| 可选字段（少量 NULL） | Nullable(T) | 语义清晰 |
| 必填字段 | DEFAULT 值 | 省开销 |
| 外键 | 0 或空字符串 | 避免 Nullable |
| 主键/排序键 | ❌ 禁止 Nullable | 不支持 |

### 3.5 时间类型内部表示

**原理**：时间类型本质是整数存储，函数是对整数的算术运算。

| 类型 | 内部表示 | 大小 | 精度 | 范围 |
|------|----------|------|------|------|
| Date | UInt16 (天数) | 2B | 天 | 1970 ~ 2149 |
| DateTime | UInt32 (Unix秒) | 4B | 秒 | 1970 ~ 2106 |
| DateTime64(N) | Int64 (tick) | 8B | 10^-N 秒 | 更广 |

**时区处理**：
- DateTime 存的是 UTC 秒，查询时按列时区转换
- 建表可指定 `DateTime('Asia/Shanghai')`
- DateTime64 同理

**决策**：
- 只需日期 → Date（最省空间）
- 秒级足够 → DateTime
- 毫秒/微秒 → DateTime64(3)/(6)

### 3.6 字符串类型决策表

| 类型 | 原理 | 适用 | 不适用 |
|------|------|------|--------|
| String | 变长字节序列 | 通用文本、JSON、日志 | 低基数字段 |
| FixedString(N) | 定长 N 字节 | MD5(16)、UUID(16)、定长哈希 | 变长文本 |
| LowCardinality(String) | 字典编码 | 基数<1万的枚举值 | 高基数、UUID |

**FixedString 注意**：
- 不足 N 字节会补 `\0`
- 超过 N 字节会截断
- 主要用于固定长度的二进制标识（哈希值），普通文本用 String

---

## 4. 文件导航

| 文件 | 主题 | 内容 | 状态 |
|------|------|------|------|
| [01_numeric_types.md](./01_numeric_types.md) | 数值类型详解 | 整数/浮点/Decimal 原理与选型 | ✅ 已细化 |
| [01_numeric_types_examples.sql](./01_numeric_types_examples.sql) | 数值类型示例 | 可运行示例（含溢出、精度演示） | ✅ 已细化 |
| [02_string_types.md](./02_string_types.md) | 字符串类型详解 | String/FixedString/LowCardinality 字典编码 | ✅ 已细化 |
| [02_string_types_examples.sql](./02_string_types_examples.sql) | 字符串类型示例 | LowCardinality 压缩对比、FixedString | ✅ 已细化 |
| [03_date_time_types.sql](./03_date_time_types.sql) | 时间类型详解 | Date/DateTime/DateTime64 内部表示、时区处理、精度实验、时间函数、分区聚合实战 | ✅ 已创建 |
| [04_compound_types.sql](./04_compound_types.sql) | 复合类型详解 | Array/Tuple/Map/Nested 四类复合类型原理、操作函数、选型对比 | ✅ 已创建 |
| [05_special_types.sql](./05_special_types.sql) | 特殊类型详解 | Enum/UUID/IPv4/IPv6/Nullable/JSON/Bool 原理、存储对比、选型决策 | ✅ 已创建 |
| [06_aggregate_function_types.sql](./06_aggregate_function_types.sql) | 聚合状态类型 | AggregateFunction vs SimpleAggregateFunction 原理、多级聚合、实时大屏实战 | ✅ 已创建 |
| [07_type_conversion.sql](./07_type_conversion.sql) | 类型转换详解 | CAST/toType 显式转换、隐式转换陷阱、溢出/精度陷阱、安全转换 | ✅ 已创建 |

---

## 5. 类型选择决策树

```
字段是什么?
  │
  ├─ 数值
  │   ├─ 整数 → 选最小够用类型 (UInt8 ~ UInt64)
  │   ├─ 小数
  │   │   ├─ 金额/需精确 → Decimal64/128
  │   │   └─ 统计/科学 → Float64
  │   └─ 布尔 → UInt8 (CH 无独立 Bool 类型)
  │
  ├─ 字符串
  │   ├─ 低基数(<1万) → LowCardinality(String)
  │   ├─ 定长哈希 → FixedString(N)
  │   └─ 通用文本 → String
  │
  ├─ 时间
  │   ├─ 只需日期 → Date
  │   ├─ 秒级 → DateTime
  │   └─ 亚秒 → DateTime64(N)
  │
  ├─ 集合
  │   ├─ 同类型列表 → Array(T)
  │   ├─ 键值对 → Map(K,V)
  │   └─ 异构 → Tuple
  │
  ├─ 枚举
  │   ├─ 少量值 → Enum8
  │   └─ 较多值 → LowCardinality(String) (更灵活)
  │
  └─ 可空?
      ├─ 少量 NULL → Nullable(T)
      └─ 多数有值 → DEFAULT 默认值 (避免 Nullable 开销)
```

---

## 6. 常见误区与最佳实践

### 误区
1. **所有整数用 UInt64**：浪费空间，年龄用 UInt8 即可
2. **金额用 Float64**：浮点误差，财务数据错误
3. **所有字符串用 String**：低基数字段没用 LowCardinality，浪费
4. **滥用 Nullable**：每个字段都 Nullable，增加开销且不能做主键
5. **LowCardinality 用于高基数**：超过 1 万值会退化，反而更慢

### 最佳实践
1. **选最小够用类型**：UInt8 能装的就别用 UInt64
2. **低基数字符串用 LowCardinality**：省 5-10x 空间
3. **金额用 Decimal**：避免浮点误差
4. **避免 Nullable**：用 DEFAULT 替代
5. **时间按精度选**：Date 最省，DateTime64 按需
6. **主键用 UInt64**：避免溢出

---

## 7. 自测题

1. 为什么 UInt8 比 UInt64 省 8 倍空间？对压缩率有什么影响？
2. LowCardinality(String) 的字典编码原理是什么？基数超过多少会退化？
3. Float64 存储 0.1+0.2 结果是什么？为什么金额不能用 Float？
4. Nullable(UInt8) 比普通 UInt8 多了什么开销？为什么不能做主键？
5. Date 内部如何存储？为什么只占 2 字节？
6. FixedString(32) 适合存什么？不适合存什么？

---

## 8. 关联章节

- [05-functions](../05-functions/README.md) —— 类型相关函数（转换、数组、Map、聚合）
- [06-modeling](../06-modeling/README.md) —— schema 设计、主键设计、时间序列建模（新建中）
- [08-performance](../08-performance/README.md) —— 类型对性能的影响
- [15-best-practices](../15-best-practices/README.md) —— schema 设计最佳实践
