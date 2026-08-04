# 实战案例分析

本文档通过真实案例展示 ClickHouse 数据更新的最佳实践和解决方案。

## 案例 1: 电商平台订单状态更新

### 业务背景

某电商平台需要每天更新数百万订单的状态，包括：
- 待支付 → 已支付
- 已支付 → 已发货
- 已发货 → 已完成
- 超时未支付 → 已取消

### 挑战

1. 订单数据量大：每天 100 万+ 新订单
2. 更新频率高：每小时更新一次
3. 实时性要求：需要快速看到状态变化
4. 数据一致性：不能出现状态错误

### 解决方案

#### 方案设计

```sql
-- 订单表结构
CREATE TABLE orders (
    order_id UInt64,
    user_id UInt64,
    product_id UInt64,
    amount Float64,
    order_status String,  -- pending, paid, shipped, completed, cancelled
    order_time DateTime,
    updated_at DateTime
) ENGINE = ReplicatedMergeTree()
PARTITION BY toYYYYMM(order_time)
ORDER BY (order_id, order_time);

-- 订单事件表（记录状态变更）
CREATE TABLE order_events (
    event_id UInt64,
    order_id UInt64,
    from_status String,
    to_status String,
    event_time DateTime,
    event_data String
) ENGINE = ReplicatedMergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (order_id, event_time);
```

#### 更新策略

```sql
-- 1. 使用轻量级更新（每小时）
-- 更新超时未支付的订单
ALTER TABLE orders
UPDATE order_status = 'cancelled',
    updated_at = now()
WHERE order_status = 'pending'
  AND order_time < now() - INTERVAL 30 MINUTE
SETTINGS lightweight_update = 1;

-- 2. 使用物化视图自动计算
-- 创建订单状态统计物化视图
CREATE MATERIALIZED VIEW order_status_stats_mv
ENGINE = SummingMergeTree()
ORDER BY (toYYYYMM(order_time), order_status)
AS SELECT
    toYYYYMM(order_time) as month,
    order_status,
    count() as order_count,
    sum(amount) as total_amount
FROM orders
GROUP BY month, order_status;

-- 3. 使用分区更新（每日归档）
-- 将已完成的订单移动到归档表
CREATE TABLE orders_archive AS orders;

ALTER TABLE orders_archive
EXCHANGE PARTITION toYYYYMM(now() - INTERVAL 3 MONTH)
WITH orders;
```

#### 性能优化

```sql
-- 创建跳数索引加速查询
ALTER TABLE orders
ADD INDEX idx_status order_status
TYPE set(0)
GRANULARITY 4;

-- 限制更新范围（只更新最近数据）
ALTER TABLE orders
UPDATE order_status = 'cancelled'
WHERE order_status = 'pending'
  AND order_time >= now() - INTERVAL 1 HOUR
  AND order_time < now() - INTERVAL 30 MINUTE
SETTINGS lightweight_update = 1;
```

#### 监控和验证

```sql
-- 监控更新进度
SELECT 
    mutation_id,
    command,
    is_done,
    parts_to_do,
    progress
FROM system.mutations
WHERE database = 'ecommerce'
  AND table = 'orders'
ORDER BY created DESC;

-- 验证更新结果
SELECT 
    order_status,
    count() as order_count,
    countIf(updated_at >= now() - INTERVAL 1 HOUR) as updated_count
FROM orders
WHERE order_time >= now() - INTERVAL 24 HOUR
GROUP BY order_status;
```

### 结果

- **更新速度**: 从 30 分钟降至 5 分钟（6x 提升）
- **查询性能**: 提升 50%
- **系统稳定性**: 提升显著

## 案例 2: 金融系统数据修正

### 业务背景

某金融系统发现历史交易数据中部分汇率计算错误，需要修正 2023 年全年的数据。

### 挑战

1. 数据量大：10 亿条交易记录
2. 数据敏感：不能出错
3. 更新范围广：需要修正 12 个月的数据
4. 停机时间短：只能在周末维护窗口进行

### 解决方案

#### 方案设计

```sql
-- 交易表结构
CREATE TABLE transactions (
    transaction_id UInt64,
    user_id UInt64,
    account_id UInt64,
    amount_original Float64,
    exchange_rate Float64,
    amount_converted Float64,
    currency String,
    transaction_time DateTime,
    status String
) ENGINE = ReplicatedMergeTree()
PARTITION BY toYYYYMM(transaction_time)
ORDER BY (transaction_id, transaction_time);
```

#### 更新策略（分区更新）

```sql
-- 1. 创建临时表
CREATE TABLE transactions_temp AS transactions;

-- 2. 逐月修正数据（每月独立处理）
-- 2023年1月
INSERT INTO transactions_temp
SELECT 
    transaction_id,
    user_id,
    account_id,
    amount_original,
    -- 修正汇率（假设USD/CNY从7.0改为7.2）
    amount_original * 7.2 as exchange_rate,
    amount_original * 7.2 as amount_converted,
    currency,
    transaction_time,
    status
FROM transactions
WHERE toYYYYMM(transaction_time) = '202301'
  AND currency = 'USD';

-- 替换分区
ALTER TABLE transactions
REPLACE PARTITION '202301'
FROM transactions_temp;

-- 清空临时表准备下个月
TRUNCATE TABLE transactions_temp;

-- 继续处理其他月份...
-- 2023年2月
INSERT INTO transactions_temp
SELECT 
    transaction_id,
    user_id,
    account_id,
    amount_original,
    amount_original * 7.2 as exchange_rate,
    amount_original * 7.2 as amount_converted,
    currency,
    transaction_time,
    status
FROM transactions
WHERE toYYYYMM(transaction_time) = '202302'
  AND currency = 'USD';

ALTER TABLE transactions
REPLACE PARTITION '202302'
FROM transactions_temp;

TRUNCATE TABLE transactions_temp;

-- 继续处理3-12月...

-- 3. 验证修正结果
SELECT 
    toYYYYMM(transaction_time) as month,
    currency,
    count() as transaction_count,
    sum(amount_converted) as total_converted,
    avg(exchange_rate) as avg_rate
FROM transactions
WHERE toYYYYMM(transaction_time) BETWEEN '202301' AND '202312'
  AND currency = 'USD'
GROUP BY month, currency
ORDER BY month;
```

#### 备份和回滚

```sql
-- 更新前备份
CREATE TABLE transactions_backup_202301 AS transactions
SELECT *
FROM transactions
WHERE toYYYYMM(transaction_time) = '202301';

-- 如果需要回滚
DROP TABLE transactions;
RENAME TABLE transactions_backup TO transactions;
-- 或者只恢复特定分区
ALTER TABLE transactions
DROP PARTITION '202301';
ALTER TABLE transactions
ATTACH PARTITION '202301'
FROM transactions_backup;
```

### 结果

- **更新时间**: 8 小时（12 个月）
- **数据准确性**: 100%
- **停机时间**: 0（在线更新）

## 案例 3: 日志系统批量处理

### 业务背景

某日志系统需要定期将未处理的日志标记为已处理，并统计处理状态。

### 挑战

1. 日志量大：每天 10 亿+ 条日志
2. 写入速率高：每秒 10 万+ 写入
3. 更新频率：每小时更新一次
4. 查询性能：需要快速查询处理状态

### 解决方案

#### 方案设计

```sql
-- 日志表结构
CREATE TABLE logs (
    log_id UInt64,
    user_id UInt64,
    log_type String,
    log_data String,
    processed UInt8 DEFAULT 0,
    processed_at DateTime,
    log_time DateTime
) ENGINE = ReplicatedMergeTree()
PARTITION BY toYYYYMM(log_time)
ORDER BY (user_id, log_time);

-- 处理统计表
CREATE TABLE log_processing_stats (
    stat_date Date,
    processed_count UInt64,
    unprocessed_count UInt64,
    error_count UInt64
) ENGINE = SummingMergeTree()
ORDER BY stat_date;
```

#### 更新策略（轻量级更新）

```sql
-- 1. 轻量级更新标记已处理的日志
ALTER TABLE logs
UPDATE processed = 1,
    processed_at = now()
WHERE processed = 0
  AND log_time < now() - INTERVAL 1 HOUR
SETTINGS 
    lightweight_update = 1,
    max_threads = 8;

-- 2. 更新统计表
INSERT INTO log_processing_stats
SELECT 
    toDate(now()) as stat_date,
    sum(processed) as processed_count,
    sum(1 - processed) as unprocessed_count,
    0 as error_count
FROM logs
WHERE toYYYYMM(log_time) = toYYYYMM(now())
GROUP BY stat_date
ON DUPLICATE KEY UPDATE
    processed_count = processed_count + _data.processed_count,
    unprocessed_count = unprocessed_count + _data.unprocessed_count,
    error_count = error_count + _data.error_count;
```

#### 优化方案（追加模式）

```sql
-- 重新设计为追加模式
-- 原始日志表（只追加，不更新）
CREATE TABLE logs_raw (
    log_id UInt64,
    user_id UInt64,
    log_type String,
    log_data String,
    log_time DateTime
) ENGINE = ReplicatedMergeTree()
PARTITION BY toYYYYMM(log_time)
ORDER BY (user_id, log_time);

-- 处理事件表（记录处理状态）
CREATE TABLE log_processing_events (
    event_id UInt64,
    log_id UInt64,
    event_type String,  -- processed, error
    event_time DateTime,
    event_data String
) ENGINE = ReplicatedMergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (log_id, event_time);

-- 查询时合并（获取最新处理状态）
SELECT 
    r.log_id,
    r.user_id,
    r.log_type,
    r.log_data,
    r.log_time,
    if(
        e.event_type = 'processed',
        1,
        0
    ) as processed,
    e.event_time as processed_at
FROM logs_raw r
LEFT JOIN (
    SELECT 
        log_id,
        argMax(event_type, event_time) as event_type,
        argMax(event_time, event_time) as event_time
    FROM log_processing_events
    WHERE event_time >= now() - INTERVAL 7 DAY
    GROUP BY log_id
) e ON r.log_id = e.log_id
WHERE r.log_time >= now() - INTERVAL 7 DAY
LIMIT 1000;
```

### 结果

- **更新性能**: 提升 10x（从追加模式）
- **查询性能**: 提升 40%
- **写入性能**: 提升 20%

## 案例 4: 用户画像实时更新

### 业务背景

某社交平台需要实时更新用户画像标签，包括兴趣标签、活跃度等级等。

### 挑战

1. 用户量大：1 亿+ 用户
2. 更新频率：每分钟更新数千用户
3. 实时性要求：毫秒级响应
4. 数据一致性：不能出现标签丢失

### 解决方案

#### 方案设计（混合模式）

```sql
-- 用户基本信息表（稳定数据）
CREATE TABLE users_base (
    user_id UInt64,
    username String,
    email String,
    created_at DateTime
) ENGINE = ReplicatedMergeTree()
ORDER BY user_id;

-- 用户画像表（频繁更新）
CREATE TABLE user_profiles (
    user_id UInt64,
    tags Array(String),
    interests Array(String),
    activity_level String,
    last_active DateTime,
    updated_at DateTime
) ENGINE = ReplicatedReplacingMergeTree(updated_at)
ORDER BY user_id;

-- 用户画像变更日志
CREATE TABLE user_profile_changes (
    change_id UInt64,
    user_id UInt64,
    change_type String,  -- add_tag, remove_tag, update_level
    change_value String,
    change_time DateTime
) ENGINE = ReplicatedMergeTree()
PARTITION BY toYYYYMM(change_time)
ORDER BY (user_id, change_time);
```

#### 更新策略

```sql
-- 1. 轻量级更新用户画像
ALTER TABLE user_profiles
UPDATE tags = arrayAppend(tags, 'premium'),
    interests = arrayAppend(interests, 'shopping'),
    activity_level = 'high',
    last_active = now(),
    updated_at = now()
WHERE user_id IN (1, 2, 3, ..., 1000)
SETTINGS lightweight_update = 1;

-- 2. 记录变更日志
INSERT INTO user_profile_changes
SELECT 
    rowNumberInAllBlocks() as change_id,
    user_id,
    'add_tag' as change_type,
    'premium' as change_value,
    now() as change_time
FROM (
    SELECT 1 as user_id
    UNION ALL SELECT 2
    UNION ALL SELECT 3
    -- ...
);

-- 3. 定期合并（使用 ReplacingMergeTree）
OPTIMIZE TABLE user_profiles
FINAL;
```

#### 查询优化

```sql
-- 查询用户画像（使用 argMax 获取最新版本）
SELECT 
    user_id,
    tags,
    interests,
    activity_level,
    argMax(updated_at, user_id) as latest_updated
FROM user_profiles
WHERE user_id IN (1, 2, 3)
GROUP BY user_id, tags, interests, activity_level;
```

### 结果

- **更新速度**: 从 100ms 降至 10ms（10x 提升）
- **查询速度**: 从 50ms 降至 20ms（2.5x 提升）
- **并发能力**: 提升 5x

## 案例 5: 数据仓库ETL更新

### 业务背景

某数据仓库需要定期从多个数据源同步数据到 ClickHouse，并更新已有记录。

### 挑战

1. 数据源多：10+ 个数据源
2. 数据量大：每天 1TB+ 数据
3. 更新复杂：需要增量更新
4. 时间窗口：每天只有 2 小时同步窗口

### 解决方案

#### 方案设计

```sql
-- 事实表
CREATE TABLE sales_facts (
    sale_id UInt64,
    product_id UInt64,
    customer_id UInt64,
    amount Float64,
    sale_date Date,
    store_id UInt64,
    etl_updated_at DateTime,
    etl_source String
) ENGINE = ReplicatedMergeTree()
PARTITION BY toYYYYMM(sale_date)
ORDER BY (sale_id, sale_date);

-- ETL 日志表
CREATE TABLE etl_logs (
    log_id UInt64,
    source_system String,
    target_table String,
    records_processed UInt64,
    records_updated UInt64,
    records_inserted UInt64,
    start_time DateTime,
    end_time DateTime,
    status String
) ENGINE = ReplicatedMergeTree()
PARTITION BY toYYYYMM(start_time)
ORDER BY (start_time, source_system);
```

#### ETL 策略

```sql
-- 1. 创建临时表
CREATE TABLE sales_facts_temp AS sales_facts;

-- 2. 从外部数据源加载数据
-- 假设数据已导出到 CSV 文件
INSERT INTO sales_facts_temp
FROM file('sales_202401.csv', 'CSV')
SETTINGS 
    input_format_null_as_default = 1,
    date_time_input_format = 'best_effort';

-- 3. 使用 INSERT SELECT 合并数据（自动去重）
INSERT INTO sales_facts
SELECT 
    sale_id,
    product_id,
    customer_id,
    amount,
    sale_date,
    store_id,
    now() as etl_updated_at,
    'source_system_name' as etl_source
FROM sales_facts_temp
WHERE sale_date >= '2024-01-01'
  AND sale_date < '2024-02-01';

-- 4. 使用 DeduplicationMergeTree 去重
-- 或者手动删除重复数据
-- （见 09-data-deletion/ 专题）

-- 5. 记录 ETL 日志
INSERT INTO etl_logs
VALUES (
    1,
    'source_system_name',
    'sales_facts',
    (SELECT count() FROM sales_facts_temp),
    (SELECT count() FROM sales_facts WHERE etl_updated_at >= now() - INTERVAL 1 HOUR),
    (SELECT count() FROM sales_facts WHERE etl_updated_at >= now() - INTERVAL 1 HOUR AND etl_source = 'source_system_name'),
    now() - INTERVAL 2 HOUR,
    now(),
    'completed'
);
```

#### 性能优化

```sql
-- 1. 使用分区裁剪
INSERT INTO sales_facts
SELECT * FROM sales_facts_temp
WHERE sale_date = '2024-01-01';  -- 每天单独处理

-- 2. 并行加载
-- 使用多个 ClickHouse 客户端并行加载不同日期的数据

-- 3. 批量插入
-- 每批插入 10 万条，减少网络开销
```

### 结果

- **同步速度**: 从 4 小时降至 1.5 小时（2.7x 提升）
- **数据准确性**: 100%
- **资源使用**: 优化 30%

## 总结

### 关键经验

1. **合理选择更新方法**：
   - 大数据量（> 30%）: 分区更新
   - 中小数据量（< 30%）: 轻量级更新
   - 极小数据量（< 1%）: Mutation

2. **设计合适的表结构**：
   - 使用 ReplicatedMergeTree 确保高可用
   - 合理的分区键（通常按时间）
   - 适当的排序键（通常按主键+时间）

3. **监控和验证**：
   - 实时监控更新进度
   - 更新后验证数据准确性
   - 定期检查系统性能

4. **备份和回滚**：
   - 更新前备份重要数据
   - 准备好回滚方案
   - 测试回滚流程

5. **性能优化**：
   - 使用索引加速查询
   - 限制更新范围
   - 分批处理大数据量
   - 在低峰期执行大规模更新

## 相关文档

- [01_mutation_update.md](./01_mutation_update.md) - Mutation 更新
- [02_lightweight_update.md](./02_lightweight_update.md) - 轻量级更新
- [03_partition_update.md](./03_partition_update.md) - 分区更新
- [04_update_strategies.md](./04_update_strategies.md) - 更新策略选择
- [07_batch_updates.md](./07_batch_updates.md) - 批量更新实战
