# 09 - Superset 报表下钻明细：4 种机制 + ClickHouse 侧数据准备

> **本章定位**：业务方最常问的问题之一——"为什么我点 GMV 数字,看不到具体订单?" 本章讲清 4 种下钻方式怎么选、ClickHouse 侧明细数据怎么准备、性能与安全怎么处理。

## 9.1 痛点与本质

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    用户的下钻诉求                                           │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  场景: 业务方看 GMV 看板                                                    │
│                                                                             │
│  ┌────────────────────────────────────────┐                                │
│  │      2026-06-19 GMV: ¥1,234,567       │  ← 看到汇总                     │
│  │      订单数: 8,432                     │                                │
│  │      客单价: ¥146                      │                                │
│  └────────────────────────────────────────┘                                │
│                                                                             │
│  业务方: "我想看 ¥1,234,567 是哪些订单贡献的"                                │
│         "我想看是哪些商品/地区贡献的"                                        │
│         "我想看是哪几个销售搞的"                                             │
│                                                                             │
│  本质诉求:                                                                  │
│    1. 汇总 → 明细 (Drill to Detail)                                        │
│    2. 汇总 → 多维分析 (Drill Across)                                       │
│    3. 汇总 → 下钻到下层看板 (Drill Through)                                 │
│    4. 汇总 → 跨图过滤 (Cross Filter)                                        │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

## 9.2 4 种下钻机制对比

| 机制 | 工作原理 | 适用场景 | 性能 | 实现复杂度 |
|------|---------|---------|------|----------|
| **Cross-Filter 跨图过滤** | 点击图表值,过滤同看板其他图表 | 同一看板内的多维分析 | 中（其他图表重查） | ⭐ |
| **Drill-to-Detail 查明细** | 点击图表,弹出明细行列表 | 汇总→原始记录 | 高（查 DWD 明细） | ⭐⭐ |
| **Drill-Through 跳看板** | 点击图表,跳转到预设看板 | 跨层级分析 | 低（另一看板独立加载） | ⭐⭐ |
| **URL Parameter 自定义钻取** | 点击图表,跳到自定义 URL | 集成到业务系统、外部链接 | 中（自定义目标） | ⭐⭐⭐ |

**选型决策树**：

```
用户想看什么?
│
├─ 想看具体明细行(订单列表)
│   └─► Drill-to-Detail (Superset 1.1+ 原生支持)
│
├─ 想看其他维度的对比
│   └─► Cross-Filter (同看板内多图联动)
│
├─ 想看更深入的分析(转化漏斗、行为路径)
│   └─► Drill-Through (跳到另一个看板)
│
└─ 想跳到业务系统(订单详情页)
    └─► URL Parameter (自定义 URL)
```

## 9.3 机制 1: Cross-Filter 跨图过滤

### 9.3.1 工作原理

```
┌────────────────────────────────────────────────────────────────┐
│                  Cross-Filter 工作原理                           │
├────────────────────────────────────────────────────────────────┤
│                                                                │
│   Dashboard "实时 GMV 看板"                                    │
│                                                                │
│   ┌──────────────────┐    ┌──────────────────┐                │
│   │ 饼图: 各地区 GMV  │    │ 柱图: 各商品 GMV  │                │
│   │                  │    │                  │                │
│   │  APAC 40%  ◄─────┼────│  鞋 30%          │                │
│   │  EMEA 30%        │    │  衣 25%          │                │
│   │  AMER 30%        │    │  ...             │                │
│   └──────────────────┘    └──────────────────┘                │
│                                                                │
│   用户点击 "APAC" → 右侧柱图自动过滤为"APAC 地区商品分布"      │
│                                                                │
│   实现:                                                         │
│     - 每个图表配置 "Emit cross-filter"                          │
│     - 点击自动产生 {{ filter_values }} 模板参数                │
│     - 其他图表接收 filter_values,触发重新查询                  │
│                                                                │
└────────────────────────────────────────────────────────────────┘
```

### 9.3.2 关键配置

```
Superset UI 配置:
1. 看板级别: 开启 "Cross Filters" 功能
   Dashboard Edit → Settings → Enable cross-filtering

2. 图表级别: 配置 "Emit cross-filter"
   Chart Edit → Cross-filter → ☑ Emit cross-filter
   
3. 配置哪些维度参与跨图过滤
   Chart Edit → Cross-filter → 
     - "Region" column: ☑ 可作为过滤器
     - "Category" column: ☑ 可作为过滤器

4. 接收端图表: 引用过滤值
   {{ filter_values('region_code') | where_in }}
```

### 9.3.3 ClickHouse 侧的虚拟数据集

```sql
-- Cross-filter 接收端查询示例
-- 用户在地区饼图点击"APAC",这里自动加 WHERE region_code IN ('APAC')

CREATE VIEW IF NOT EXISTS realtime_olap.v_cross_filter_product_gmv ON CLUSTER 'treasurycluster' AS
SELECT
    product_category,
    product_brand,
    sum(gmv)              AS gmv,
    sum(order_cnt)        AS order_cnt
FROM realtime_olap.dws_user_order_1d
WHERE dt >= today() - INTERVAL 7 DAY
  AND {{ filter_values('region_code') | where_in }}  -- Jinja 宏
GROUP BY product_category, product_brand;
```

**Why Cross-Filter 适合多维分析？**
- 不需要新看板,同看板内多图联动
- 实现简单,Superset 原生支持
- 性能: 其他图表重新查询(可走缓存)

## 9.4 机制 2: Drill-to-Detail 查明细(推荐方案)

### 9.4.1 工作原理

```
┌────────────────────────────────────────────────────────────────┐
│               Drill-to-Detail 工作原理 (Superset 1.1+)         │
├────────────────────────────────────────────────────────────────┤
│                                                                │
│   图表: GMV 趋势 (基于 DWS 汇总)                              │
│   ┌────────────────────────────────┐                          │
│   │           /\                   │                          │
│   │     /\   /  \                  │                          │
│   │ /\ /  \ /    \                 │                          │
│   │/  V    V      \                │                          │
│   └────────────────────────────────┘                          │
│     ▲                                                          │
│     │ 用户点击 6/19 的数据点                                   │
│     │                                                          │
│     ▼                                                          │
│   ┌──────────────────────────────────────────┐                │
│   │  Modal 弹窗: 6/19 当天订单明细             │                │
│   ├──────────────────────────────────────────┤                │
│   │  order_id    user    amount   status     │                │
│   │  O20260619A  Alice   ¥1,200  paid        │                │
│   │  O20260619B  Bob     ¥99     paid        │                │
│   │  O20260619C  ...                            │                │
│   │  ... (最多 1000 行)                       │                │
│   └──────────────────────────────────────────┘                │
│                                                                │
│   实现:                                                         │
│     - 图表配置 "Drill to detail"                               │
│     - 指向另一个查询(查 DWD 明细)                              │
│     - Superset 自动注入点击时的维度值作为 filter                │
│                                                                │
└────────────────────────────────────────────────────────────────┘
```

### 9.4.2 Superset 端配置

```
Chart Edit 步骤:

1. 配置主图表(基于 DWS 汇总)
   - 数据集: v_gmv_dashboard
   - 维度: dt, region_code
   - 指标: SUM(gmv)
   - 图表类型: Line Chart

2. 配置 Drill-to-Detail
   - 同一个图表配置里 → "Drill to detail"
   - ☑ "Enable drill to detail"
   - 目标数据集: v_dwd_order_detail
   - 传递的过滤维度: dt, region_code
   - 显示列: order_id, user_name, amount, status, order_time
   - 排序: order_time DESC
   - 行数限制: 100

3. 用户体验
   - 点击图表数据点
   - 自动弹出明细 modal
   - 显示 100 条该时间/地区的具体订单
```

### 9.4.3 ClickHouse 侧:明细虚拟数据集

```sql
-- ========================================
-- 明细数据集: 供 Drill-to-Detail 使用
-- ========================================
-- 
-- 设计原则:
--   1. 基于 DWD 明细层(有完整原始数据)
--   2. 必须支持维度过滤(避免全表扫描)
--   3. 必须有 LIMIT(避免返回百万行)
--   4. 维度冗余(用户/商品/地区名称直接拉平)
-- 
-- ========================================

-- 9.4.3.1 基础明细视图
CREATE VIEW IF NOT EXISTS realtime_olap.v_dwd_order_detail ON CLUSTER 'treasurycluster' AS
SELECT
    -- 主键
    order_id,
    
    -- 业务字段
    order_time,
    pay_time,
    order_status,
    pay_method,
    order_amount,
    pay_amount,
    discount_amount,
    
    -- 维度冗余(避免 Superset 端 JOIN)
    user_id,
    -- user_name 通过 dictGet 关联
    dictGet('realtime_olap.dict_user_dict', 'user_name', user_id) AS user_name,
    user_tier,
    product_id,
    product_category,
    product_brand,
    region_code,
    channel
    
FROM realtime_olap.dwd_order
WHERE is_valid = 1
  AND order_time >= today() - INTERVAL 90 DAY;  -- 限制时间范围,加速

-- ========================================
-- Why 这样设计?
-- 
-- Q: 为什么不用 dwd_order 直接查?
-- A: 
--   - dwd_order 包含所有字段,Superset 端可能误用
--   - 视图做了"安全和性能封装"
--   - 时间过滤避免全表扫描
-- 
-- Q: 为什么要 dictGet user_name?
-- A:
--   - 避免 DWD 表存储冗余的用户名(节省存储)
--   - 字典查询 O(1),性能不受影响
--   - 用户改名实时生效(字典自动刷新)
-- 
-- Q: 为什么 LIMIT 在 Superset 端,不在视图?
-- A:
--   - 视图是数据集,Superset 端控制显示行数
--   - 但 Superset 会下发 LIMIT 1,000,000(默认)
--   - 需要在 Superset 端配置 "Row Limit" 为 100
-- ========================================
```

### 9.4.4 Superset Jinja 模板(关键)

```sql
-- 场景: 接收点击图表传递的 dt, region_code 参数
-- 这是 Superset "Drill to detail" 的核心机制

-- 在 Superset 的 "Drill to detail" 配置中,使用 Jinja 宏
SELECT
    order_id,
    order_time,
    user_name,
    order_amount,
    order_status,
    region_code,
    product_category
FROM realtime_olap.v_dwd_order_detail
WHERE 
    -- 接收图表点击的维度值
    toDate(order_time) = {{ url_param('dt') | to_date }}     -- 点击的日期
    AND ({{ url_param('region_code') | quote }} = '' 
         OR region_code = {{ url_param('region_code') | quote }})  -- 点击的地区
    -- 多条件时,全部要 OR 默认值
    AND ({{ url_param('product_category') | quote }} = '' 
         OR product_category = {{ url_param('product_category') | quote }})
ORDER BY order_time DESC
LIMIT {{ row_limit | default(100) }};
```

**Why 用 Jinja 宏？**

```sql
-- ❌ 错误: 硬编码参数
WHERE toDate(order_time) = '2026-06-19'  -- 用户点击 6/18 时不生效

-- ❌ 错误: 用 {{ filter_values }} 但 Superset 1.0 不支持
-- {{ filter_values('dt') }} 在某些版本会渲染成空

-- ✅ 正确: 用 url_param 接收点击传递的参数
WHERE toDate(order_time) = {{ url_param('dt') | to_date }}
-- 当用户点击图表时,Superset 自动生成 URL:
--   ?dt=2026-06-19&region_code=APAC&product_category=鞋
-- 模板自动渲染为:
--   WHERE toDate(order_time) = '2026-06-19'
--     AND region_code = 'APAC'
```

**Jinja 宏速查表**：

| 宏 | 用途 | 示例 |
|----|------|------|
| `{{ url_param('xxx') }}` | 取 URL 参数 | `?dt=2026-06-19` → `'2026-06-19'` |
| `{{ url_param('xxx') \| to_date }}` | 转为日期 | `'2026-06-19'` → `Date` |
| `{{ url_param('xxx') \| quote }}` | 加引号 | `APAC` → `'APAC'` |
| `{{ filter_values('xxx') }}` | 取看板 filter 值 | `[APAC, EMEA]` |
| `{{ current_username() }}` | 当前用户名 | `'alice'` |
| `{{ current_user_id() }}` | 当前用户 ID | `123` |
| `{{ from_dttm }}` | 时间筛选器-开始 | `DateTime` |
| `{{ to_dttm }}` | 时间筛选器-结束 | `DateTime` |
| `{{ row_limit }}` | 行数限制 | `1000` |

## 9.5 机制 3: Drill-Through 跳看板

### 9.5.1 适用场景

```
场景:
  - GMV 看板 → 点击"商品" → 跳转到"商品分析看板"
  - 区域看板 → 点击"区域" → 跳转到"区域运营看板"
  - 实时大屏 → 点击"异常" → 跳转到"异常明细看板"

本质: 跨看板跳转,实现层级化分析
```

### 9.5.2 实现:URL Parameter 自定义链接

```sql
-- 创建一个"商品分析看板",接收 region_code 参数
-- 看板 URL: https://superset/dashboard/2/?region_code=APAC

-- 在商品分析看板的 SQL 中,接收参数
SELECT
    product_category,
    product_brand,
    sum(gmv)         AS gmv,
    sum(order_cnt)   AS order_cnt
FROM realtime_olap.dws_user_order_1d
WHERE dt >= today() - INTERVAL 30 DAY
  AND region_code = {{ url_param('region_code') | quote }}  -- 关键
GROUP BY product_category, product_brand;
```

**Superset 配置**:

```
步骤 1: 在源图表配置"自定义 URL"
  Chart Edit → "Custom URL" → 
    URL: /superset/dashboard/2/?region_code={{ encodeURIComponent(region) }}
    
  说明: 点击图表某一行时,触发 URL 跳转
        {{ encodeURIComponent(region) }} 是 Superset 模板变量

步骤 2: 目标看板接收参数
  目标 Dashboard 的所有图表 SQL 中,使用 url_param('region_code')

步骤 3: 配置 dashboard 级 cross-filter
  目标 Dashboard → URL Parameters → 允许外部传入
```

## 9.6 机制 4: 嵌入到业务系统(URL + SDK)

```javascript
// 场景: 业务方在 CRM 系统点击订单,跳转到 Superset 看分析
// URL: https://crm.company.com/order/12345
//         ↓
// 跳转: https://superset/dashboard/10/?order_id=12345

// Superset 看板的 SQL:
SELECT *
FROM realtime_olap.v_dwd_order_detail
WHERE order_id = {{ url_param('order_id') | quote }};

// 业务系统集成代码 (JavaScript)
function openAnalytics(orderId) {
    // 跳转到 Superset,带上订单号
    const url = `https://superset.company.com/superset/dashboard/10/?order_id=${orderId}`;
    window.open(url, '_blank');
}

// CRM 页面调用
<button onclick="openAnalytics('O20260619A001')">查看分析</button>
```

## 9.7 ClickHouse 侧:明细数据准备的 3 种策略

```
┌──────────────────────────────────────────────────────────────┐
│            明细数据准备的 3 种策略                              │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│  策略 A: 直接查 DWD 明细表                                    │
│    适用: 明细量适中(<1 亿),过滤条件明确                       │
│    优点: 实时性最强,数据最新                                 │
│    缺点: 大表查询慢,需要分页                                  │
│                                                              │
│  策略 B: 物化视图预展开                                       │
│    适用: 高频下钻的固定维度组合                               │
│    优点: 查询快(< 100ms)                                    │
│    缺点: 灵活性差,改维度难                                   │
│                                                              │
│  策略 C: ClickHouse 视图 + Dictionary                       │
│    适用: 90% 场景                                             │
│    优点: 灵活性高,字段丰富                                   │
│    缺点: 性能依赖 DWD 性能                                   │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

### 策略 A: 直接查 DWD

```sql
-- 直接查询 DWD(配合 Superset 的"Drill to detail")
-- 关键: 必须带时间过滤 + LIMIT

SELECT
    order_id,
    order_time,
    user_id,
    product_id,
    order_amount,
    order_status
FROM realtime_olap.dwd_order
WHERE order_time >= '2026-06-19' AND order_time < '2026-06-20'
  AND region_code = 'APAC'
  AND is_valid = 1
ORDER BY order_time DESC
LIMIT 100;

-- 性能预估:
--   - DWD 表按时间分区,带时间过滤后只读 1 个分区
--   - 1 天数据约 1 亿行
--   - 单分区扫描 + 过滤: < 1 秒
--   - 加上 LIMIT 100: < 0.5 秒
```

### 策略 B: 物化视图预展开

```sql
-- 场景: 高频下钻"订单-用户-商品"三联表
-- 用物化视图预展开,查询亚秒级

-- 创建展开的明细物化视图
CREATE TABLE IF NOT EXISTS realtime_olap.mv_dwd_order_enriched ON CLUSTER 'treasurycluster' (
    order_id      String,
    order_time    DateTime,
    
    -- 订单字段
    order_amount  Decimal(18, 2),
    order_status  LowCardinality(String),
    
    -- 用户字段(冗余)
    user_id       UInt64,
    user_name     String,
    user_tier     LowCardinality(String),
    
    -- 商品字段(冗余)
    product_id    UInt64,
    product_name  String,
    product_brand LowCardinality(String),
    
    -- 地区字段(冗余)
    region_code   LowCardinality(String),
    region_name   String
) ENGINE = ReplicatedReplacingMergeTree(
    '/clickhouse/tables/{shard}/realtime_olap/mv_dwd_order_enriched',
    '{replica}',
    order_time
)
PARTITION BY toYYYYMM(order_time)
ORDER BY (order_time, order_id);

-- 物化视图:从 DWD 自动展开
CREATE MATERIALIZED VIEW IF NOT EXISTS realtime_olap.mv_to_enriched
ON CLUSTER 'treasurycluster'
TO realtime_olap.mv_dwd_order_enriched AS
SELECT
    o.order_id,
    o.order_time,
    o.order_amount,
    o.order_status,
    o.user_id,
    dictGet('realtime_olap.dict_user_dict', 'user_name', o.user_id) AS user_name,
    o.user_tier,
    o.product_id,
    dictGet('realtime_olap.dict_product_dict', 'product_name', o.product_id) AS product_name,
    o.product_brand,
    o.region_code,
    dictGet('realtime_olap.dict_region_dict', 'region_name', o.region_code) AS region_name
FROM realtime_olap.dwd_order o
WHERE o.is_valid = 1;

-- Superset 直接查这个物化视图(快,无需 JOIN)
SELECT * FROM realtime_olap.mv_dwd_order_enriched
WHERE order_time = {{ url_param('dt') | to_date }}
  AND region_code = {{ url_param('region_code') | quote }}
ORDER BY order_time DESC
LIMIT {{ row_limit | default(100) }};
```

**Why 用物化视图？**

```
直接查 DWD:    500ms - 2s(需要 dictGet 多次)
物化视图:      50ms - 200ms(数据已展开)

但代价:
  - 存储 +30%
  - 写入开销 +10%
  - 灵活性降低

何时用:
  ✓ 高频下钻(每天 > 1000 次)
  ✓ 维度组合固定
  ✓ 实时性要求高
  
何时不用:
  ✗ 临时下钻分析
  ✗ 维度组合变化大
```

### 策略 C: 视图(默认推荐)

```sql
-- 90% 场景用视图就够
CREATE VIEW IF NOT EXISTS realtime_olap.v_dwd_order_enriched_view ON CLUSTER 'treasurycluster' AS
SELECT
    o.order_id,
    o.order_time,
    o.order_amount,
    o.order_status,
    o.user_id,
    dictGet('realtime_olap.dict_user_dict', 'user_name', o.user_id) AS user_name,
    o.user_tier,
    o.product_id,
    o.product_category,
    o.product_brand,
    o.region_code,
    o.channel
FROM realtime_olap.dwd_order o
WHERE o.is_valid = 1
  AND o.order_time >= today() - INTERVAL 365 DAY;  -- 只看 1 年内

-- 优点:
--   - 零存储成本
--   - 灵活性最高
--   - 字段可加可减
-- 缺点:
--   - 大数据量下查询稍慢
--   - dictGet 每次都调用

-- 性能: 单分区(1 天)查询 100 行 < 1s
```

## 9.8 性能优化

### 9.8.1 DWD 明细查询慢? 4 个优化方向

```
┌──────────────────────────────────────────────────────────────┐
│            DWD 下钻查询性能优化金字塔                          │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│  优先级 1 (必做):                                            │
│    □ 强制时间过滤(避免全表扫描)                              │
│    □ 强制 LIMIT 100(下钻不该返回 10 万行)                    │
│    □ 物化视图预展开(高频下钻)                                 │
│                                                              │
│  优先级 2 (强烈推荐):                                         │
│    □ 跳数索引(常用过滤字段)                                  │
│    □ dictGet 替代 JOIN                                       │
│    □ Superset 行数限制配置                                   │
│                                                              │
│  优先级 3 (锦上添花):                                         │
│    □ 投影(简化返回字段)                                     │
│    □ 采样(罕见下钻场景)                                     │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

### 9.8.2 跳数索引加速下钻

```sql
-- 场景: 经常按 region_code 下钻
-- DWD 表主键 (order_time, user_id, order_id),不含 region_code
-- 查询时会扫描整个 part,慢

-- 加跳数索引
ALTER TABLE realtime_olap.dwd_order
ADD INDEX idx_region_code region_code TYPE set(64) GRANULARITY 4;

-- 之后查询自动跳过不含 APAC 的 part
-- 性能提升: 5-10x(取决于数据分布)
```

### 9.8.3 Superset 端强制 LIMIT

```python
# superset_config.py

# 全局行数限制
SQL_MAX_ROW = 10000

# Drill-to-detail 单独配置
DRILL_TO_DETAIL_ROW_LIMIT = 100  # 下钻最多 100 行

# Why:
#   - 下钻本意是"看几行样本",不是"导出全部"
#   - 100 行 = 1 屏,用户体验好
#   - 10000 行 = 加载慢,UI 卡
```

### 9.8.4 缓存 DWD 下钻结果

```sql
-- 场景: 同一时段,100 个用户下钻同一订单
-- 每次都查 ClickHouse = 100 次查询

-- 方案 1: Superset Redis 缓存
--   已经在 04 章配置,5 分钟 TTL
--   - key = dashboard + chart + filter
--   - 用户重复下钻,命中缓存

-- 方案 2: ClickHouse 端 query_cache
SET use_query_cache = 1;
SET query_cache_ttl = 300;  -- 5 分钟
-- 相同查询直接命中 ClickHouse 内存
```

## 9.9 安全与权限

### 9.9.1 行级权限(防止看到不该看的)

```sql
-- 场景: 区域经理只能下钻本区域的订单
-- 即使 URL 拼了 region_code=APAC 也不行

-- 方案 1: ClickHouse 视图加权限过滤
CREATE VIEW IF NOT EXISTS realtime_olap.v_dwd_order_rls ON CLUSTER 'treasurycluster' AS
SELECT *
FROM realtime_olap.dwd_order
WHERE 
    -- 区域经理只能看本区域
    region_code IN (
        SELECT region_code 
        FROM realtime_olap.user_region_mapping 
        WHERE user_name = {{ current_username() }}
    )
    -- 超级管理员看全部
    OR {{ current_username() }} IN ('admin', 'data_team');

-- 方案 2: Superset Row Level Security (RLS)
-- Settings → Row Level Security
-- Table: v_dwd_order_detail
-- Clause: region_code = '{{ current_user.region }}'
-- Roles: Regional_Manager
```

**Why 双重防护？**
- ClickHouse 视图: 数据层防护(防 SQL 注入)
- Superset RLS: 应用层防护(防误用)
- **安全要纵深防御,不能依赖单层**

### 9.9.2 敏感字段脱敏

```sql
-- 场景: 下钻明细中,手机号/身份证号需要脱敏

CREATE VIEW IF NOT EXISTS realtime_olap.v_dwd_order_safe ON CLUSTER 'treasurycluster' AS
SELECT
    order_id,
    order_time,
    order_amount,
    order_status,
    region_code,
    product_category,
    
    -- 脱敏: 手机号显示前 3 后 4
    concat(
        substring(phone, 1, 3),
        '****',
        substring(phone, -4)
    ) AS phone_masked,
    
    -- 脱敏: 身份证号显示前 6 后 4
    concat(
        substring(id_card, 1, 6),
        '********',
        substring(id_card, -4)
    ) AS id_card_masked
    
FROM realtime_olap.dwd_order
WHERE is_valid = 1;

-- 高级: 基于角色的脱敏
--   - 客服: 看完整手机号
--   - 运营: 看脱敏
--   - 财务: 看完整身份证
-- 
-- 实现: 用 {{ current_user_role() }} 区分
```

### 9.9.3 下钻防滥刷

```python
# superset_config.py

# 限流: 单用户下钻频率
RATE_LIMIT_DASHBOARD = "100/minute"
RATE_LIMIT_QUERY = "30/minute"

# 慢查询熔断
SLOW_QUERY_TIMEOUT = 10  # 10 秒超时直接返回错误
```

## 9.10 实战模板

### 9.10.1 完整模板: GMV 看板下钻

```sql
-- ========================================
-- 1. 汇总层: GMV 看板的图表数据集
-- ========================================
CREATE VIEW IF NOT EXISTS realtime_olap.v_gmv_chart ON CLUSTER 'treasurycluster' AS
SELECT
    toStartOfHour(order_time)        AS hour,
    region_code,
    product_category,
    sum(order_amount)                 AS gmv,
    count()                           AS order_cnt
FROM realtime_olap.dwd_order
WHERE order_time >= today() - INTERVAL 1 DAY
  AND is_valid = 1
GROUP BY hour, region_code, product_category;

-- ========================================
-- 2. 明细层: 下钻明细数据集(Drill to detail)
-- ========================================
CREATE VIEW IF NOT EXISTS realtime_olap.v_drill_order_detail ON CLUSTER 'treasurycluster' AS
SELECT
    order_id,
    order_time,
    order_status,
    pay_method,
    order_amount,
    pay_amount,
    discount_amount,
    
    -- 用户
    user_id,
    dictGet('realtime_olap.dict_user_dict', 'user_name', user_id) AS user_name,
    user_tier,
    
    -- 商品
    product_id,
    product_category,
    product_brand,
    
    -- 地区
    region_code,
    channel
FROM realtime_olap.dwd_order
WHERE is_valid = 1
  AND order_time >= today() - INTERVAL 90 DAY;  -- 限制时间范围

-- ========================================
-- 3. Superset 配置
-- ========================================
-- 
-- Chart 1: GMV 趋势 (基于 v_gmv_chart)
--   Dimensions: hour, region_code, product_category
--   Metrics: SUM(gmv)
--   Visualization: Line Chart
--   Drill to detail: ☑
--   - Target dataset: v_drill_order_detail
--   - Pass filters: hour, region_code, product_category
--   - Row limit: 100
--   - Sort: order_time DESC
-- 
-- Chart 2: 订单明细表格 (基于 v_drill_order_detail)
--   - 在 Chart 1 配置 "Drill to detail" 时被自动引用
--   - 字段: order_id, order_time, user_name, order_amount, order_status
--   - 默认按 order_time DESC
-- 
-- 用户体验:
--   1. 看到 GMV 趋势图
--   2. 点击某小时/某地区数据点
--   3. 弹出明细列表(100 行订单)
--   4. 可以导出 CSV(Superset 原生支持)
```

### 9.10.2 Jinja 模板全集

```sql
-- 完整的下钻查询模板(可直接复制到 Superset)
SELECT
    -- 业务字段
    order_id,
    order_time,
    order_status,
    order_amount,
    pay_amount,
    
    -- 维度字段(从 URL 接收)
    region_code,
    product_category,
    channel,
    
    -- 用户维度(用 dictGet)
    user_id,
    dictGet('realtime_olap.dict_user_dict', 'user_name', user_id) AS user_name,
    user_tier
    
FROM realtime_olap.v_drill_order_detail
WHERE 
    -- 时间过滤(必须)
    order_time >= {{ from_dttm | default('today() - INTERVAL 7 DAY') }}
    AND order_time < {{ to_dttm | default('today()') }}
    
    -- 维度过滤(从 URL 接收,空值表示"全部")
    AND ({{ url_param('region_code') | quote }} = '' 
         OR region_code = {{ url_param('region_code') | quote }})
    AND ({{ url_param('product_category') | quote }} = '' 
         OR product_category = {{ url_param('product_category') | quote }})
    AND ({{ url_param('channel') | quote }} = '' 
         OR channel = {{ url_param('channel') | quote }})
    
    -- 当前用户权限(行级安全)
    AND (region_code IN (
            SELECT region_code 
            FROM realtime_olap.user_region_mapping 
            WHERE user_name = {{ current_username() | quote }}
         )
         OR {{ current_username() | quote }} IN ('admin', 'data_team'))
    
ORDER BY order_time DESC
LIMIT {{ row_limit | default(100) }};
```

**Jinja 模板的 6 个关键点**:

```
1. 时间过滤必须有,避免全表扫描
2. URL 参数用 {{ url_param('xxx') | quote }} 接收
3. 多值参数用 {{ filter_values('xxx') | where_in }} 接收
4. 行级安全用 {{ current_username() }} 注入
5. LIMIT 用 {{ row_limit | default(100) }} 控制
6. 排序默认 order_time DESC(用户体验)
```

## 9.11 异常处理

### 9.11.1 下钻查询失败怎么办

```sql
-- 场景 1: 查询超时
--   用户下钻,ClickHouse 查询超过 30 秒
--   处理: 
--     1. 自动重试一次(可能临时慢)
--     2. 返回友好错误:"查询超时,请缩小时间范围"
--     3. 记录到告警,运维介入

-- 场景 2: 返回空数据
--   可能有数据但过滤条件太严
--   处理:
--     1. Superset 显示"无数据"
--     2. 提供"清除筛选"按钮
--     3. 显示可能的原因(时间范围/维度组合)

-- 场景 3: ClickHouse 副本延迟
--   查询时数据不一致
--   处理:
--     1. 不让用户看到中间状态
--     2. ClickHouse 用 FINAL 保证一致性(慎用)
--     3. 或用业务可接受的方式(如金额允许 ±1% 误差)
```

### 9.11.2 下钻数据的"实时性"说明

```
┌──────────────────────────────────────────────────────────────┐
│            下钻数据的实时性                                   │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│  看板显示: GMV 999,000(基于 ADS 物化视图,延迟 < 1 秒)       │
│  下钻明细: 100 个订单,总金额 999,000(基于 DWD,延迟 < 5 秒)  │
│                                                              │
│  理论上: 99.9% 一致                                         │
│  实际上: 偶尔有微小差异                                      │
│                                                              │
│  Why?                                                         │
│    - ADS 是预聚合,最近 1 分钟的数据已写入                    │
│    - DWD 是明细,新订单按到达顺序写入                         │
│    - 极端情况下: 看板显示的金额来自 100 个订单的聚合          │
│      下钻时这 100 个订单的总和可能比看板数字少几块钱         │
│      (因为又新增了几个订单被算进了看板,但还没进明细)         │
│                                                              │
│  业务可接受:                                                 │
│    - GMV 误差 < 0.01%: 99.9% 业务场景可接受                  │
│    - 订单数误差 < 0.1%: 1000 单里差 1 单,业务不敏感           │
│                                                              │
│  解决方案(如确实有强一致要求):                                │
│    - 看板和明细都基于 DWD(无聚合)                            │
│    - 但看板会慢 10-100x                                      │
│    - 不推荐                                                  │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

## 9.12 反模式(避坑指南)

| # | 反模式 | 后果 | 正确做法 |
|---|--------|------|---------|
| 1 | 下钻返回 10 万行 | 浏览器卡死 | LIMIT 100 |
| 2 | 下钻查全表 DWD | 数据库挂掉 | 强制时间过滤 |
| 3 | 下钻用 SELECT * | 传大量无用字段 | 只 SELECT 必要列 |
| 4 | 下钻不做权限控制 | 数据泄露 | RLS + 视图过滤 |
| 5 | 跨图过滤加复杂逻辑 | Superset 性能差 | 简单维度过滤即可 |
| 6 | 跳看板用硬编码 URL | 维护灾难 | 用 Jinja 模板参数 |
| 7 | 下钻显示原始手机号 | 合规问题 | 字段脱敏 |
| 8 | 下钻无加载提示 | 用户不知道在转 | 加 loading 状态 |

## 9.13 最佳实践 Checklist

```
┌──────────────────────────────────────────────────────────────┐
│       Superset 下钻明细 12 条最佳实践                          │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│  [机制选型]                                                  │
│  □ Cross-Filter: 同一看板内多图联动                          │
│  □ Drill-to-Detail: 汇总→明细(最常用)                       │
│  □ Drill-Through: 跨看板跳转                                 │
│  □ URL Parameter: 集成业务系统                               │
│                                                              │
│  [明细数据准备]                                              │
│  □ 基于 DWD 明细层                                           │
│  □ 用 dictGet 关联维表                                       │
│  □ 视图封装,不做裸表查询                                    │
│  □ 物化视图预展开(>1000 QPS)                                 │
│                                                              │
│  [性能]                                                      │
│  □ 强制时间过滤                                              │
│  □ 强制 LIMIT 100                                            │
│  □ 跳数索引(常用过滤维度)                                    │
│  □ Superset 缓存配置                                         │
│  □ ClickHouse query_cache 启用                              │
│                                                              │
│  [安全]                                                      │
│  □ 行级权限(RLS)                                            │
│  □ 敏感字段脱敏                                              │
│  □ 限流配置                                                  │
│                                                              │
│  [可观测性]                                                  │
│  □ 监控下钻查询 P99                                          │
│  □ 告警下钻失败率                                            │
│  □ 用户体验日志                                              │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

## 9.14 终极心法

**下钻的本质是"分页+过滤"**:
- 不需要复杂架构,Superset 原生 + Jinja 模板就够
- 90% 场景用 Drill-to-Detail 即可
- 复杂场景(跨系统集成)才需要 URL Parameter

**明细数据的"性能/灵活性"平衡**:
- 视图(默认) > 物化视图(高频) > 直接查 DWD(罕见)
- 90% 场景用视图,需要极致性能时才上物化视图
- 物化视图不是越多越好

**安全是"必要不充分条件"**:
- 必须做行级权限和字段脱敏
- 但做了不等于 100% 安全
- 纵深防御,多层防护

**用户体验 > 技术实现**:
- 下钻体验 = "点击 → 1 秒内看到明细"
- 超过 3 秒用户就焦虑
- 超过 10 秒用户就放弃

## 9.15 下一章建议

- [04_superset_dashboard.sql](./04_superset_dashboard.sql) - Superset 基础配置
- [06_best_practices.md](./06_best_practices.md) - 行业最佳实践
- [08_realtime_sla.md](./08_realtime_sla.md) - 实时性 SLA 与监控
