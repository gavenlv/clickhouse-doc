# ClickHouse 注意事项清单

本文档提供 ClickHouse 使用的 Do's and Don'ts（应该做和不应该做）清单。

## 写入操作

### ✅ 应该做 (Do's)

```sql
-- 批量写入
INSERT INTO table SELECT * FROM source;

-- 使用异步写入
SET async_insert = 1;
INSERT INTO table VALUES (...);

-- 大批量写入
INSERT INTO table 
SELECT ...
FROM large_table
WHERE conditions;

-- 使用正确的分区键值
INSERT INTO partition_table (date, ...) 
VALUES ('2024-01-01', ...);
```

### ❌ 不应该做 (Don'ts)

```sql
-- 单行插入
INSERT INTO table VALUES (1, 'a', 100);

-- 频繁小批量
for row in data:
    INSERT INTO table VALUES (row)  -- 每次一行

-- 无分区键值
INSERT INTO partitioned_table (name) VALUES ('test');

-- 写入时使用函数导致分区失效
INSERT INTO table VALUES (toDate('2024-01-01'));  -- 可接受
-- 但不要在 PARTITION BY 中使用函数
```

## 查询操作

### ✅ 应该做 (Do's)

```sql
-- 只选需要的列
SELECT user_id, count() FROM table GROUP BY user_id;

-- 使用分区裁剪
SELECT * FROM table WHERE event_date = '2024-01-01';

-- 使用 LIMIT
SELECT * FROM table LIMIT 100;

-- 使用近似函数
SELECT uniq(user_id) FROM table;

-- 使用物化视图
SELECT * FROM materialized_view;
```

### ❌ 不应该做 (Don'ts)

```sql
-- SELECT *
SELECT * FROM large_table;

-- 无分区条件
SELECT * FROM table;

-- 在分区键上使用函数
SELECT * FROM table WHERE toYYYYMM(date) = 202401;

-- 全表聚合无 LIMIT
SELECT user_id, count() 
FROM table 
GROUP BY user_id;

-- 深度嵌套子查询
SELECT * FROM (
    SELECT * FROM (
        SELECT * FROM table
    )
);
```

## 表设计

### ✅ 应该做 (Do's)

```sql
-- 合理的主键顺序
ORDER BY (high_selectivity_col, medium, low);

-- 合适的分区
PARTITION BY toYYYYMM(date);

-- 合适的数据类型
event_date Date
status Enum8('a'=1, 'b'=2)
user_id UInt32
category LowCardinality(String)

-- 设置 index_granularity
SETTINGS index_granularity = 8192;
```

### ❌ 不应该做 (Don'ts)

```sql
-- 主键顺序不当
ORDER BY (low_selectivity, high_selectivity);

-- 分区过细
PARTITION BY toYYYYMMDD(date);  -- 每天一个分区

-- 使用 String 代替合适类型
event_date String  -- 不要
status String     -- 改用 Enum

-- 主键过长
ORDER BY (col1, col2, col3, col4, col5, col6);
```

## 数据类型

### ✅ 应该做 (Do's)

```sql
-- 使用日期类型
event_date Date
event_time DateTime

-- 使用数值类型
user_id UInt32
price Decimal(10, 2)

-- 使用枚举
status Enum8('pending'=1, 'done'=2)

-- 使用 LowCardinality
category LowCardinality(String)

-- 使用 Nullable 谨慎
Nullable(String)  -- 额外1字节开销
```

### ❌ 不应该做 (Don'ts)

```sql
-- String 存储日期
event_date String  -- "2024-01-01" 10字节 vs Date 2字节

-- String 存储数值
user_id String  -- "123456" vs UInt32 4字节

-- 过度使用 Nullable
Nullable(String)  -- 降低压缩率

-- 过大的数据类型
id UInt256  -- 用不着的位数
```

## 分布式操作

### ✅ 应该做 (Do's)

```sql
-- 使用分片键查询
SELECT * FROM dist_table
WHERE user_id = 123;  -- 利用分片键

-- 相同分片键的 JOIN
SELECT * FROM a
JOIN b ON a.user_id = b.user_id  -- 同分片键

-- 使用 GLOBAL JOIN
SELECT * FROM a
GLOBAL JOIN small_table b ON a.id = b.id;
```

### ❌ 不应该做 (Don'ts)

```sql
-- 跨分片大表 JOIN
SELECT * FROM large_dist_a
JOIN large_dist_b ON a.id = b.id;  -- 性能差

-- 无分片键条件的分布式查询
SELECT * FROM dist_table;  -- 扫描所有分片

-- 随机分片键
ENGINE = Distributed(cluster, db, table, rand());  -- 无法局部查询
```

## 资源管理

### ✅ 应该做 (Do's)

```sql
-- 设置内存限制
SET max_memory_usage = 10000000000;  -- 10GB

-- 设置超时
SET max_execution_time = 60;

-- 限制读取行数
SET max_rows_to_read = 1000000;

-- 限制并发
SET max_concurrent_queries = 10;
```

### ❌ 不应该做 (Don'ts)

```sql
-- 无限制的查询
-- 默认 max_memory_usage = 0 (无限制)

-- 大结果集
SELECT * FROM large_table
INTO OUTFILE 'result.csv';  -- 可能 OOM

-- 并发过高
-- 同时运行 100+ 查询
```

## 监控和维护

### ✅ 应该做 (Do's)

```sql
-- 定期检查 Parts 数量
SELECT table, count() AS parts
FROM system.parts
WHERE active = 1
GROUP BY table;

-- 定期检查合并队列
SELECT * FROM system.merges;

-- 定期检查复制延迟
SELECT table, absolute_delay
FROM system.replicas
WHERE absolute_delay > 60;

-- 使用 TTL 自动清理
ALTER TABLE table MODIFY TTL event_date + INTERVAL 1 YEAR;
```

### ❌ 不应该做 (Don'ts)

```sql
-- 从不检查系统表
-- system.parts, system.merges, system.replicas

-- 从不清理旧数据
-- 导致磁盘空间耗尽

-- 从不优化
-- Parts 数量持续增长
```

## 配置参数

### ✅ 应该做 (Do's)

```xml
<!-- config.xml -->
<max_memory_usage>10000000000</max_memory_usage>
<max_threads>16</max_threads>
<keep_alive_timeout>3</keep_alive_timeout>
<max_connections>100</max_connections>
```

### ❌ 不应该做 (Don'ts)

```xml
<!-- 过低的内存限制 -->
<max_memory_usage>1000000</max_memory_usage>  -- 1MB

<!-- 过高的线程数 -->
<max_threads>1000</max_threads>  -- 上下文切换

<!-- 缺少关键配置 -->
<!-- 没有配置 max_connections -->
```

## 备份和恢复

### ✅ 应该做 (Do's)

```sql
-- 使用表备份
ALTER TABLE table FREEZE;

-- 使用导出
SELECT * INTO OUTFILE 'backup.tsv'
FROM table;

-- 使用复制
CREATE TABLE table_replica AS table
ENGINE = ReplicatedMergeTree();
```

### ❌ 不应该做 (Don'ts)

```sql
-- 无备份策略

-- 只依赖一个副本

-- 未测试恢复流程
```

## 性能检查清单

### 日常检查

- [ ] 监控查询延迟
- [ ] 监控磁盘使用
- [ ] 监控 Parts 数量
- [ ] 监控合并队列
- [ ] 监控复制延迟

### 定期任务

- [ ] 优化表 (OPTIMIZE)
- [ ] 清理旧分区
- [ ] 分析表统计
- [ ] 检查错误日志
- [ ] 备份数据

### 新部署检查

- [ ] 配置合理
- [ ] 主键设计正确
- [ ] 分区策略合理
- [ ] 数据类型合适
- [ ] 监控已配置

## 常见陷阱

### 1. 时间相关

```sql
-- 时区问题
SET use_client_time_zone = 0;  -- 使用服务端时区

-- 日期函数
toDate('2024-01-01')  -- 正确
Date('2024-01-01')    -- 也正确
```

### 2. 字符串匹配

```sql
-- LIKE vs exact match
SELECT * FROM table WHERE name LIKE '%test%';  -- 慢
SELECT * FROM table WHERE name = 'test';       -- 快

-- 使用索引
SELECT * FROM table WHERE uniqExact(user_id) > 1;  -- 快
```

### 3. NULL 处理

```sql
-- NULL 比较
SELECT * FROM table WHERE nullable_col = NULL;    -- 错误
SELECT * FROM table WHERE nullable_col IS NULL;   -- 正确

-- NULL 聚合
SELECT count(col) FROM table;       -- 不含 NULL
SELECT count(*) FROM table;         -- 包含 NULL
SELECT countIf(col, col IS NULL) FROM table;  -- 只计 NULL
```

## 快速参考表

| 操作 | Do | Don't |
|------|-----|-------|
| 写入 | 批量 > 10万行 | 单行插入 |
| 查询 | SELECT 具体列 | SELECT * |
| 分区 | 按月 | 按天 |
| 主键 | 高选择性在前 | 低选择性在前 |
| 类型 | 使用合适类型 | 使用 String |
| 内存 | 设置限制 | 无限制 |
| 监控 | 定期检查 | 从不检查 |

## 相关文档

- [01_overview.sql](./01_overview.sql) - 最佳实践概述
- [02_schema_design.sql](./02_schema_design.sql) - 表设计
- [03_query_optimization.sql](./03_query_optimization.sql) - 查询优化
- [04_common_mistakes.sql](./04_common_mistakes.sql) - 常见错误
