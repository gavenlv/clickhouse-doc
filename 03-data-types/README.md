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

## 4. 使用场景全景（场景驱动选型）

**核心理念**：不要从"类型"出发想"能存什么"，而要从"业务字段"出发想"该用什么类型"。同一语义的字段在不同业务域，量级和精度要求完全不同，选型也随之不同。下面按 6 大业务域给出"字段 → 类型 → 理由"的完整答案。

### 4.1 电商交易域

| 字段 | 数据类型 | 为什么 |
|------|---------|--------|
| order_id | UInt64 | 订单号全局唯一、只增不减，用无符号防溢出；亿级订单也远达不到 UInt64 上限 |
| user_id | UInt64 | 用户量可能突破 42 亿（UInt32 上限），一旦溢出数据直接损坏，主键/外键一律用 UInt64 兜底 |
| product_id / sku_id | UInt32 | 商品量级远低于用户（百万级），4B 足够，节省一半空间 |
| 实付金额 amount | Decimal(18, 2) | 金额必须精确。Float64 存 0.1+0.2=0.30000000000000004，对账会差钱 |
| unit_price 单价 | Decimal(18, 2) | 单价要存"下单时快照"，不能 JOIN 时读现价，否则历史订单金额会漂移 |
| 优惠/运费 | Decimal(18, 2) | 逐项精确计算再相加 |
| order_status | Enum8 或 LowCardinality(String) | 状态值少且固定（pending/paid/shipped/completed/cancelled），Enum8 最省；若状态可动态扩展用 LowCardinality |
| payment_method | LowCardinality(String) | 基数 < 10（支付宝/微信/银行卡/现金），字典编码省 5-10x |
| 收货地址 | String | 变长自由文本，不可枚举，不能用 LowCardinality |
| 订单扩展属性 | Map(String, String) | 不同品类字段不同（手机要内存、衣服要尺码），用 Map 兜底免 ALTER |
| 商品标签 | Array(String) | 一件商品多个标签，用 Array 天然表达 |

> 场景故事：某电商曾用 Float64 存金额，月结对账差 0.03 元查了 3 天。金额相关的**每一列**（售价、折扣、运费、税、退款）都必须 Decimal，且小数位统一（分=2 位）。

### 4.2 日志与可观测域

| 字段 | 数据类型 | 为什么 |
|------|---------|--------|
| event_time | DateTime 或 DateTime64(3) | 日志按秒够用选 DateTime（4B）；APM 延迟分析要毫秒级用 DateTime64(3)（8B） |
| log_level | Enum8 | DEBUG/INFO/WARN/ERROR 固定 4 值，Enum8 比 String 省 10 倍且过滤更快 |
| service_name | LowCardinality(String) | 服务名有限（几十个），字典编码让 GROUP BY 秒回 |
| host / instance | LowCardinality(String) | 机器数量有限（几十到几百），同上 |
| trace_id | FixedString(16) 或 String | 32 位十六进制 ID 可转成 16 字节二进制；若直接存 String 用 UInt128/FixedString(16) |
| message 原文 | String | 自由文本不可枚举，String；不要为了省空间截断，会丢排障信息 |
| duration_ms | UInt16 或 UInt32 | 毫秒级耗时；<65s 用 UInt16，超时任务可能到分钟级用 UInt32 |
| 标签集合 | Map(String, String) | Prometheus 风格标签，键值对集合用 Map |
| 请求路径 | String | 高基数（含参数），**绝对禁用 LowCardinality** |

> 场景故事：日志平台把 level 存成 String，2 亿条/天的日志级别列占了 40GB；改成 Enum8 后仅 4GB，且 `WHERE level = 'ERROR'` 的过滤性能提升 3 倍。

### 4.3 金融与风控域

| 字段 | 数据类型 | 为什么 |
|------|---------|--------|
| 交易金额 | Decimal(18, 2) 或 Decimal(38, 2) | 跨境/大额场景用 Decimal128；分是硬通货，绝不用 Float |
| 利率 / 汇率 | Decimal(18, 6) | 利率 6 位小数精度（0.000001），Decimal 保证复利计算精确 |
| 账户余额 | Decimal(18, 2) | 余额可负（透支），Decimal 天然有符号语义 |
| 交易状态 | Enum8 | 成功/失败/处理中/已冲正，固定集合 |
| 渠道类型 | LowCardinality(String) | 渠道有限（网银/手机/柜面/POS），字典编码 |
| 商户号 | UInt64 | 商户 ID 量级大，8B 兜底 |
| 批次号 / 流水号 | UInt64 | 全局递增流水，UInt64 防溢出 |
| 风控特征向量 | Array(Float32) | 模型特征定长数组，Array(Float32) 比 JSON 省且可向量计算 |
| 时间戳 | DateTime64(6) | 交易时序强，微秒级可用于精确排序/对账 |

> 场景故事：风控要"同卡 5 分钟 3 次大额"实时判定，交易时间用 DateTime64(6) 才能精确排序，秒级 DateTime 会在并发高峰产生并列，误杀正常交易。

### 4.4 物联网（IoT）域

| 字段 | 数据类型 | 为什么 |
|------|---------|--------|
| device_id / sensor_id | UInt32 或 UInt64 | 设备量亿级用 UInt32 够；若预留接入规模用 UInt64 |
| event_time | DateTime | 秒级采集够用；毫秒级采样用 DateTime64(3) |
| temperature / humidity | Float32 | 传感器读数本身有精度上限（±0.1°C），Float32 足够且省一半 |
| 电压 / 电流 | Float32 | 连续模拟量，Float32 |
| GPS 经纬度 | Float64 | 经纬度需要 6-7 位小数（约 0.1 米），Float64 精度才能覆盖 |
| battery 电量 | UInt8 | 0-100 整数百分比，UInt8 |
| 设备状态 | Enum8 | 在线/离线/故障/维护，固定值 |
| 固件版本 | LowCardinality(String) | 版本号有限（几十个），字典编码 |
| 原始报文 | String | 不可控长度自由文本 |

> 场景故事：车联网每车每秒上报 100 条信号，温度用 Float64 比 Float32 多存一倍（8B vs 4B），1 亿辆车一年的存储成本差距巨大。传感器数据**不要**用 Decimal——采集精度本来就低，Decimal 的高精度是浪费。

### 4.5 用户行为分析域

| 字段 | 数据类型 | 为什么 |
|------|---------|--------|
| event_name | LowCardinality(String) | 埋点事件名有限（几百个），字典编码后 GROUP BY 极快 |
| user_id | UInt64 | 用户主键，防溢出 |
| 页面 URL | String | 高基数含参数，禁用 LowCardinality |
| 属性字典 | Map(String, String) | 事件属性键值对，用 Map 免 ALTER |
| session_id | UUID 或 String | 会话 ID 高基数唯一，String/UUID 均可，禁用 LowCardinality |
| 停留时长 | UInt32 | 秒数，UInt32 覆盖 136 年 |
| device_type | LowCardinality(String) | iOS/Android/Web/H5 等几十种 |
| 渠道来源 | LowCardinality(String) | 渠道有限（几百个） |
| 漏斗步骤 | UInt8 | 步骤编号 0-N，UInt8 或 Enum8 |

> 场景故事：埋点事件名如果存 String，每日 5 亿事件的 event_name 列（平均 15 字节）约 75GB；LowCardinality 后字典索引 2 字节/行，仅 10GB，且 `GROUP BY event_name` 从秒级降到毫秒级。

### 4.6 广告与增长域

| 字段 | 数据类型 | 为什么 |
|------|---------|--------|
| impression / click | UInt8（0/1） | 布尔语义，1 字节，sum() 即曝光/点击量 |
| campaign_id | UInt32 | 广告计划量级百万级，4B |
| creative_id | UInt32 | 创意量级同上 |
| 花费 spend | Decimal(18, 4) | 广告结算精确到 4 位小数（千分之），Decimal 保证对账 |
| ctr / cvr 指标 | Float32 | 计算得出的比率，本身是浮点结果，Float 即可（**计算指标**与**存储金额**要分清） |
| 定向人群标签 | Array(String) 或 Array(UInt32) | 人群包是集合，Array 表达 |
| 投放时间窗 | DateTime | 秒级够用 |

> 关键区分：**"业务原始值"要精确存 Decimal，"计算派生的比率"用 Float**。ctr = click / impression 的结果天然是近似值，用 Float32 无损表达，不需要 Decimal。

### 4.7 选错类型的代价（反面教材）

| 错误 | 后果 | 正确做法 |
|------|------|---------|
| 用户 ID 用 UInt32 | 42 亿后溢出变负数，数据损坏 | UInt64 |
| 金额用 Float64 | 对账不平、报表差钱 | Decimal(18, 2)+ |
| 日志级别用 String | 存储膨胀 5-10x，过滤慢 | Enum8 / LowCardinality |
| URL 用 LowCardinality | 字典退化成普通 String，且每次写入有字典查找开销 | String |
| 传感器温度用 Decimal | 高精度浪费 4 倍空间，无收益 | Float32 |
| 所有字符串用 FixedString | 变长文本被截断/补 \0，数据错误 | String |

---

## 5. 文件导航

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

## 6. 类型选择决策树

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

## 7. 常见误区与最佳实践

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

## 8. 自测题

1. 为什么 UInt8 比 UInt64 省 8 倍空间？对压缩率有什么影响？
2. LowCardinality(String) 的字典编码原理是什么？基数超过多少会退化？
3. Float64 存储 0.1+0.2 结果是什么？为什么金额不能用 Float？
4. Nullable(UInt8) 比普通 UInt8 多了什么开销？为什么不能做主键？
5. Date 内部如何存储？为什么只占 2 字节？
6. FixedString(32) 适合存什么？不适合存什么？
7. 场景判断：以下字段各该选什么类型？（答案见文末）
   - 电商订单表 user_id → ？
   - 传感器温度 → ？
   - 日志级别 → ？
   - 请求 URL → ？
   - 账户余额 → ？

---

## 9. 关联章节

- [05-functions](../05-functions/README.md) —— 类型相关函数（转换、数组、Map、聚合）
- [06-modeling](../06-modeling/README.md) —— schema 设计、主键设计、时间序列建模（新建中）
- [08-performance](../08-performance/README.md) —— 类型对性能的影响
- [15-best-practices](../15-best-practices/README.md) —— schema 设计最佳实践

---

## 10. 自测题答案

1. UInt8 每行 1 字节，UInt64 每行 8 字节；列式存储下全列 I/O 差 8 倍，且小整数列连续重复值多、压缩率更高，向量化时一条 SIMD 指令能处理 8 倍行数。
2. LowCardinality 建立"值→整数索引"字典，列只存 1-2 字节索引；基数超过 10,000 自动退化为普通 String（每次写入多一次字典查找，得不偿失）。
3. Float64 二进制无法精确表示十进制小数，0.1+0.2 = 0.30000000000000004；金额累计、对账、税费计算都会因舍入产生误差，必须用 Decimal。
4. 多一个 NULL 掩码列（每行 1 bit + 独立文件）；查询每行要检查掩码破坏向量化；Nullable 列不能作为主键/排序键。
5. Date 内部是 UInt16，存"距 1970-01-01 的天数"，2 字节覆盖到 2149 年。
6. 适合：定长二进制标识（MD5 的 16 字节、UUID 的 16 字节、哈希）；不适合：任意变长文本（会被截断或补 \0）。
7. 场景答案：user_id → UInt64（防溢出）；传感器温度 → Float32（采集精度有限）；日志级别 → Enum8（固定集合）；请求 URL → String（高基数含参数）；账户余额 → Decimal(18, 2)（金额精确）。
