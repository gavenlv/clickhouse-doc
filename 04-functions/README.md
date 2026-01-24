# ClickHouse Functions and Window Functions

本目录包含 ClickHouse 函数和窗口函数的详细教程和实践示例。

## 📚 目录

- [基本函数](01_basic_functions_examples.sql) - 各类基本函数的使用示例
- [窗口函数](02_window_functions_examples.sql) - 窗口函数的高级应用

---

## 1. 基本函数 (01_basic_functions_examples.sql)

### 1.1 聚合函数 (Aggregate Functions)

聚合函数用于对一组值进行计算并返回单个值。

#### 常用聚合函数

```sql
-- 基本聚合函数
SELECT 
    count() as total_records,              -- 总记录数
    count(DISTINCT product_id) as unique_products,  -- 唯一值计数
    sum(quantity) as total_quantity,       -- 求和
    avg(price) as avg_price,               -- 平均值
    min(price) as min_price,               -- 最小值
    max(price) as max_price                -- 最大值
FROM sales_data;

-- 条件聚合
SELECT 
    category,
    sumIf(quantity, region = 'North') as north_quantity,
    avgIf(price, category = 'Electronics') as electronics_avg_price,
    countIf(price > 100) as expensive_items_count
FROM sales_data
GROUP BY category;

-- 统计聚合函数
SELECT 
    category,
    variance(price) as price_variance,    -- 方差
    stddev(price) as price_stddev,        -- 标准差
    quantile(0.5)(price) as median_price,    -- 中位数
    quantile(0.9)(price) as p90_price         -- 90分位数
FROM sales_data
GROUP BY category;
```

#### 重要提示

- `count()` 计算所有行（不包括 NULL 值）
- `count(DISTINCT expr)` 计算唯一值
- `sumIf(expr, condition)` 只在条件满足时求和
- `quantile(p)` 计算百分位数，p 在 0 到 1 之间

### 1.2 字符串函数 (String Functions)

字符串函数用于处理和转换文本数据。

```sql
-- 基本字符串操作
SELECT 
    length(username) as username_length,      -- 字符串长度
    upper(username) as username_upper,        -- 转大写
    lower(email) as email_lower,              -- 转小写
    trim(LEADING 'Software' FROM bio),        -- 去除前导字符
    substring(username, 1, 4) as prefix       -- 截取子串
FROM users_data;

-- 字符串分割和连接
SELECT 
    splitByChar('@', email) as parts,                     -- 按字符分割
    arrayElement(splitByChar('@', email), 1) as local,   -- 获取数组元素
    concat('User: ', username, ' - ', email) as combined  -- 连接字符串
FROM users_data;

-- 字符串搜索和替换
SELECT 
    positionCaseInsensitive(bio, 'Engineer') as pos,      -- 查找位置
    countMatches(bio, 'Engineer') as count,               -- 匹配计数
    replaceRegexpOne(username, '_', ' ') as readable      -- 正则替换
FROM users_data;
```

### 1.3 日期时间函数 (Date/Time Functions)

日期时间函数用于处理和转换时间数据。

```sql
-- 日期时间提取
SELECT 
    toYear(event_time) as year,           -- 年份
    toMonth(event_time) as month,         -- 月份
    toDayOfMonth(event_time) as day,      -- 日
    toHour(event_time) as hour,           -- 小时
    toMinute(event_time) as minute,       -- 分钟
    toDayOfWeek(event_time) as weekday,   -- 星期
    toQuarter(event_time) as quarter      -- 季度
FROM events_data;

-- 日期时间计算
SELECT 
    event_time,
    now() as current_time,
    dateDiff('day', event_time, now()) as days_ago,     -- 计算差值
    addDays(event_time, 7) as week_later,              -- 添加天数
    toStartOfDay(event_time) as day_start,             -- 天的开始
    toStartOfMonth(event_time) as month_start           -- 月的开始
FROM events_data;

-- 日期时间格式化
SELECT 
    formatDateTime(event_time, '%Y-%m-%d') as date_only,
    formatDateTime(event_time, '%H:%M:%S') as time_only,
    formatDateTime(event_time, '%Y年%m月%d日') as chinese_format
FROM events_data;
```

### 1.4 数学函数 (Math Functions)

数学函数执行数值计算。

```sql
SELECT 
    round(value1) as rounded,          -- 四舍五入
    floor(value1) as floored,          -- 向下取整
    ceil(value2) as ceiled,            -- 向上取整
    abs(value3 - 150) as abs_diff,    -- 绝对值
    pow(value1, 2) as squared,         -- 幂运算
    sqrt(value1) as root,              -- 平方根
    exp(value1 / 10) as exponential,   -- 指数
    log10(value1) as logarithm         -- 对数
FROM numeric_data;

-- 三角函数
SELECT 
    sin(toFloat32(3.14159 / 4)) as sin_45deg,
    cos(toFloat32(3.14159 / 6)) as cos_30deg,
    tan(toFloat32(3.14159 / 4)) as tan_45deg;
```

### 1.5 条件函数 (Conditional Functions)

条件函数用于实现逻辑判断。

```sql
-- if 函数
SELECT 
    product_name,
    stock,
    if(stock >= reorder_point, 'In Stock', 'Low Stock') as status
FROM product_inventory;

-- ifNull 函数 - 处理 NULL 值
SELECT 
    ifNull(stock, 0) as safe_stock
FROM product_inventory;

-- multiIf - 多重条件判断
SELECT 
    product_name,
    stock,
    multiIf(
        stock = 0, 'Out of Stock',
        stock < reorder_point, 'Critical Stock',
        stock < reorder_point * 2, 'Normal Stock',
        'High Stock'
    ) as stock_level
FROM product_inventory;
```

### 1.6 数组函数 (Array Functions)

数组函数用于处理数组类型数据。

```sql
-- 基本数组操作
SELECT 
    item_name,
    tags,
    length(tags) as tag_count,              -- 数组长度
    has(tags, 'tech') as has_tech,         -- 检查元素
    indexOf(tags, 'tech') as position,     -- 查找位置
    arrayJoin(tags) as individual_tag      -- 展开数组
FROM tags_data;

-- 数组操作
SELECT 
    arrayConcat(tags, ['new']) as concat,        -- 连接数组
    arrayPushBack(tags, 'item') as push_back,    -- 追加元素
    arrayPushFront(tags, 'item') as push_front,  -- 前置元素
    arraySlice(tags, 1, 2) as slice              -- 切片
FROM tags_data;

-- 数组聚合
SELECT 
    scores,
    arraySum(scores) as total,
    arrayAvg(scores) as avg,
    arrayMin(scores) as min,
    arrayMax(scores) as max,
    arraySort(scores) as sorted
FROM tags_data;
```

### 1.7 类型转换函数 (Type Conversion Functions)

类型转换函数用于在不同数据类型之间转换。

```sql
-- 字符串转数字
SELECT 
    toInt32(string_num) as int32,
    toFloat32(string_num) as float32,
    toDecimal128(string_num, 2) as decimal128
FROM mixed_data;

-- 字符串转日期
SELECT 
    toDate(date_str) as date,
    toDateTime(date_str) as datetime
FROM mixed_data;
```

### 1.8 哈希函数 (Hash Functions)

哈希函数用于生成数据的哈希值。

```sql
SELECT 
    md5(session_id) as md5_hash,
    sha1(session_id) as sha1_hash,
    sha256(session_id) as sha256_hash,
    sipHash64(session_id) as siphash,
    xxHash64(session_id) as xxhash,
    intHash32(user_id) as int_hash
FROM user_sessions;
```

### 1.9 IP 地址函数 (IP Address Functions)

IP 地址函数用于处理 IPv4 地址。

```sql
SELECT 
    client_ip,
    toIPv4(client_ip) as ipv4,
    IPv4NumToString(toIPv4(client_ip)) as back_to_string,
    IPv4NumToClassC(toIPv4(client_ip)) as class_c
FROM access_logs;
```

### 1.10 JSON 函数 (JSON Functions)

JSON 函数用于解析和提取 JSON 数据。

```sql
SELECT 
    json_string,
    JSONExtractString(json_string, 'name') as name,
    JSONExtractUInt(json_string, 'age') as age,
    JSONExtractString(json_string, '$.city') as jsonpath_city
FROM json_data;
```

---

## 2. 窗口函数 (02_window_functions_examples.sql)

窗口函数是在 ClickHouse 中执行跨行计算的强大工具，可以对与当前行相关的行集执行计算。

### 2.1 窗口函数基本语法

```sql
function_name([expression]) OVER (
    [PARTITION BY partition_expression]
    [ORDER BY sort_expression]
    [frame_clause]
)
```

**关键组件：**
- `PARTITION BY` - 将数据分成组（类似 GROUP BY）
- `ORDER BY` - 在每个分区内排序
- `frame_clause` - 定义当前行的计算范围

### 2.2 排名函数 (Ranking Functions)

排名函数为每行分配一个排名。

```sql
-- ROW_NUMBER - 连续的唯一编号（无并列）
SELECT 
    salesperson,
    sale_date,
    revenue,
    row_number() OVER (PARTITION BY salesperson ORDER BY revenue DESC) as rn
FROM sales;

-- RANK - 有并列时跳过编号
SELECT 
    category,
    price,
    rank() OVER (PARTITION BY category ORDER BY price DESC) as rank_num
FROM sales;

-- DENSE_RANK - 有并列时不跳过编号
SELECT 
    category,
    price,
    dense_rank() OVER (PARTITION BY category ORDER BY price DESC) as dense_rank_num
FROM sales;
```

**区别示例：**
```
价格:    100, 90, 90, 80
RANK:      1,  2,  2,  4   (跳过3)
DENSE_RANK: 1,  2,  2,  3   (不跳过)
ROW_NUMBER:1,  2,  3,  4   (唯一)
```

### 2.3 偏移函数 (Offset Functions)

偏移函数访问当前行之前或之后的行。

```sql
-- LAG - 访问之前的行
SELECT 
    sale_date,
    price,
    lag(price) OVER (ORDER BY sale_date) as prev_price,           -- 前一行
    lag(price, 2) OVER (ORDER BY sale_date) as prev_2_price,     -- 前两行
    price - lag(price) OVER (ORDER BY sale_date) as price_change   -- 价格变化
FROM sales;

-- LEAD - 访问之后的行
SELECT 
    sale_date,
    price,
    lead(price) OVER (ORDER BY sale_date) as next_price,          -- 后一行
    lead(price, 2) OVER (ORDER BY sale_date) as next_2_price     -- 后两行
FROM sales;
```

### 2.4 首尾值函数 (First/Last Value Functions)

```sql
-- FIRST_VALUE - 获取分区的第一个值
SELECT 
    sale_date,
    price,
    first_value(price) OVER (PARTITION BY salesperson ORDER BY sale_date) as first_price
FROM sales;

-- LAST_VALUE - 获取分区的最后一个值
SELECT 
    sale_date,
    price,
    last_value(price) OVER (PARTITION BY salesperson ORDER BY sale_date) as last_price
FROM sales;
```

### 2.5 聚合窗口函数 (Aggregate Window Functions)

在窗口中使用聚合函数。

```sql
-- 运行总计 (累积求和)
SELECT 
    sale_date,
    salesperson,
    revenue,
    sum(revenue) OVER (PARTITION BY salesperson ORDER BY sale_date) as running_total
FROM sales;

-- 移动平均
SELECT 
    sale_date,
    price,
    avg(price) OVER (ORDER BY sale_date ROWS BETWEEN 2 PRECEDING AND CURRENT ROW) as ma_3day
FROM sales;

-- 分区聚合
SELECT 
    category,
    price,
    avg(price) OVER (PARTITION BY category) as category_avg,
    max(price) OVER (PARTITION BY category) as category_max
FROM sales;
```

### 2.6 窗口框架 (Window Frames)

窗口框架定义当前行的计算范围。

```sql
-- ROWS - 基于物理行位置
avg(price) OVER (ORDER BY sale_date ROWS BETWEEN 2 PRECEDING AND CURRENT ROW)

-- RANGE - 基于值范围
avg(price) OVER (ORDER BY price RANGE BETWEEN 100 PRECEDING AND CURRENT ROW)

-- 常用框架模式
ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW  -- 从开头到当前行
ROWS BETWEEN 2 PRECEDING AND 2 FOLLOWING         -- 当前行前后各2行
ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING  -- 整个分区
```

### 2.7 实际应用场景

#### 场景 1：识别顶级表现者

```sql
WITH sales_by_person AS (
    SELECT 
        salesperson,
        sum(revenue) as total_sales
    FROM sales
    GROUP BY salesperson
)
SELECT 
    salesperson,
    total_sales,
    rank() OVER (ORDER BY total_sales DESC) as rank_num,
    CASE 
        WHEN rank() OVER (ORDER BY total_sales DESC) <= 1 THEN '🏆 Top Performer'
        WHEN rank() OVER (ORDER BY total_sales DESC) <= 3 THEN '🥈 Top 3'
        ELSE ''
    END as award
FROM sales_by_person;
```

#### 场景 2：比较当前销售与历史最佳

```sql
SELECT 
    sale_date,
    salesperson,
    revenue,
    max(revenue) OVER (PARTITION BY salesperson) as best_sale,
    avg(revenue) OVER (PARTITION BY salesperson) as avg_sale,
    revenue / max(revenue) OVER (PARTITION BY salesperson) * 100 as pct_of_best
FROM sales;
```

#### 场景 3：移动平均和趋势分析

```sql
WITH daily_totals AS (
    SELECT 
        sale_date,
        sum(revenue) as daily_revenue
    FROM sales
    GROUP BY sale_date
)
SELECT 
    sale_date,
    daily_revenue,
    avg(daily_revenue) OVER (ORDER BY sale_date ROWS BETWEEN 6 PRECEDING AND CURRENT ROW) as ma_7day,
    avg(daily_revenue) OVER (ORDER BY sale_date ROWS BETWEEN 29 PRECEDING AND CURRENT ROW) as ma_30day
FROM daily_totals;
```

#### 场景 4：检测间隔和异常

```sql
SELECT 
    sale_date,
    salesperson,
    lag(sale_date) OVER (PARTITION BY salesperson ORDER BY sale_date) as prev_date,
    dateDiff('day', lag(sale_date) OVER (PARTITION BY salesperson ORDER BY sale_date), sale_date) as days_gap,
    CASE 
        WHEN dateDiff('day', lag(sale_date) OVER (PARTITION BY salesperson ORDER BY sale_date), sale_date) > 7 
        THEN '⚠️ Long Gap'
        ELSE 'OK'
    END as status
FROM sales;
```

### 2.8 性能优化建议

1. **使用分区减少数据量**
   ```sql
   -- 好的做法
   rank() OVER (PARTITION BY salesperson ORDER BY revenue DESC)
   
   -- 避免（除非必要）
   rank() OVER (ORDER BY revenue DESC)
   ```

2. **选择合适的窗口框架**
   ```sql
   -- 避免过大的框架
   avg(price) OVER (ORDER BY sale_date ROWS BETWEEN 1000 PRECEDING AND CURRENT ROW)
   
   -- 更高效的方式
   avg(price) OVER (ORDER BY sale_date ROWS BETWEEN 7 PRECEDING AND CURRENT ROW)
   ```

3. **窗口函数 vs 自连接**
   - 窗口函数通常更高效
   - 避免使用自连接实现窗口函数功能

### 2.9 常见错误和解决方案

#### 错误 1：忘记 PARTITION BY
```sql
-- 错误：全局排名
row_number() OVER (ORDER BY revenue DESC)

-- 正确：分组内排名
row_number() OVER (PARTITION BY salesperson ORDER BY revenue DESC)
```

#### 错误 2：窗口函数在 WHERE 中使用
```sql
-- 错误：不能在 WHERE 中使用窗口函数
SELECT * FROM sales WHERE rank() OVER (...) <= 10

-- 正确：使用子查询
SELECT * FROM (
    SELECT *, rank() OVER (ORDER BY revenue DESC) as rnk
    FROM sales
) WHERE rnk <= 10
```

#### 错误 3：混淆 ROWS 和 RANGE
```sql
-- ROWS：基于行数
avg(price) OVER (ORDER BY sale_date ROWS BETWEEN 2 PRECEDING AND CURRENT ROW)

-- RANGE：基于值范围
avg(price) OVER (ORDER BY price RANGE BETWEEN 100 PRECEDING AND CURRENT ROW)
```

---

## 3. 最佳实践

### 3.1 函数选择

1. **聚合函数**
   - 使用 `sumIf`, `avgIf` 代替 `CASE WHEN` + 聚合
   - 使用 `quantile` 而不是手动计算百分位

2. **字符串函数**
   - 优先使用 `positionCaseInsensitive` 进行不区分大小写的搜索
   - 使用 `splitByChar` 而不是正则表达式进行简单分割

3. **日期时间函数**
   - 使用 `toStartOfDay` 等函数进行日期规范化
   - 使用 `dateDiff` 计算日期差值，而不是手动计算

### 3.2 窗口函数使用

1. **性能考虑**
   - 在 PARTITION BY 中使用高基数列时要谨慎
   - 尽量减少窗口框架的大小
   - 考虑使用 FINAL 关键字或物化视图进行预计算

2. **代码可读性**
   - 为窗口函数结果使用有意义的别名
   - 使用注释说明复杂的窗口逻辑
   - 考虑将复杂窗口函数逻辑封装到视图或 CTE 中

3. **数据一致性**
   - 注意 NULL 值对窗口函数的影响
   - 使用 `ignore nulls` 选项处理 NULL 值（如果支持）

---

## 4. 参考资料

- [ClickHouse 官方文档 - 函数](https://clickhouse.com/docs/en/sql-reference/functions/)
- [ClickHouse 官方文档 - 窗口函数](https://clickhouse.com/docs/en/sql-reference/window-functions/)
- [ClickHouse 函数速查表](https://clickhouse.com/docs/en/sql-reference/functions/)

---

## 5. 练习建议

1. **基础练习**
   - 使用不同类型的聚合函数计算统计指标
   - 练习字符串操作和正则表达式
   - 熟悉日期时间函数的各种用法

2. **进阶练习**
   - 使用窗口函数进行排名和分位计算
   - 实现移动平均和趋势分析
   - 使用偏移函数进行周期比较

3. **实战项目**
   - 构建销售分析仪表板
   - 实现用户行为分析
   - 创建性能监控系统

---

## 注意事项

- 本目录中的 SQL 示例都包含完整的测试数据，可以直接运行
- 建议按照文件顺序学习：先基本函数，后窗口函数
- 运行示例前请确保 ClickHouse 服务正常运行
- 部分高级功能可能需要特定版本的 ClickHouse
