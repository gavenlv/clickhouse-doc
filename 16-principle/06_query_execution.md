# 查询执行流程

本文档介绍 ClickHouse 的查询执行流程，包括解析、优化、执行等阶段。

## 概述

ClickHouse 的查询执行是一个复杂的管道处理过程，涉及多个阶段的优化和转换。

## 查询处理管道

```
┌─────────────────────────────────────────────────────────────┐
│                 ClickHouse 查询处理管道                        │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  SQL 查询                                                    │
│     │                                                        │
│     ▼                                                        │
│ ┌─────────────────────────────────────────────────────┐    │
│ │ 1. Parser - 语法解析                                 │    │
│ │    SQL → AST (抽象语法树)                           │    │
│ └─────────────────────────────────────────────────────┘    │
│     │                                                        │
│     ▼                                                        │
│ ┌─────────────────────────────────────────────────────┐    │
│ │ 2. Interpreter - 语义解释                            │    │
│ │    AST → 查询计划                                     │    │
│ └─────────────────────────────────────────────────────┘    │
│     │                                                        │
│     ▼                                                        │
│ ┌─────────────────────────────────────────────────────┐    │
│ │ 3. Query Pipeline - 查询管道                         │    │
│ │    ┌────────────────────────────────────────────┐   │    │
│ │    │ Source → Filter → GroupBy → OrderBy → ... │   │    │
│ │    └────────────────────────────────────────────┘   │    │
│ └─────────────────────────────────────────────────────┘    │
│     │                                                        │
│     ▼                                                        │
│ ┌─────────────────────────────────────────────────────┐    │
│ │ 4. 执行阶段                                          │    │
│ │    - 读取数据                                        │    │
│ │    - 过滤/聚合                                       │    │
│ │    - 返回结果                                        │    │
│ └─────────────────────────────────────────────────────┘    │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

## 查询解析阶段

### 1. 语法解析 (Parser)

```
SQL: SELECT event_date, count() FROM events WHERE user_id = 123 GROUP BY event_date

AST:
SelectQuery
├── columns: [event_date, count()]
├── from: events
├── where: user_id = 123
└── group_by: [event_date]
```

### 2. 语义解释 (Interpreter)

```sql
-- 查看查询计划
EXPLAIN PLAN 
SELECT event_date, count() 
FROM tutorial.events 
WHERE user_id = 123 
GROUP BY event_date;
```

## 查询优化

### PREWHERE 优化

PREWHERE 是 ClickHouse 特有的优化，先读取主键列进行过滤，减少 I/O。

```
┌─────────────────────────────────────────────────────────────┐
│                    PREWHERE 优化原理                          │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  普通查询:                                                   │
│  ┌─────────────────────────────────────────────────────┐    │
│  │ SELECT user_id, event_type, value                  │    │
│  │ FROM events                                        │    │
│  │ WHERE event_date = '2024-01-15'                    │    │
│  │   AND user_id = 123;                               │    │
│  └─────────────────────────────────────────────────────┘    │
│  1. 读取所有列                                              │
│  2. 过滤数据                                                │
│                                                              │
│  PREWHERE 优化:                                              │
│  ┌─────────────────────────────────────────────────────┐    │
│  │ SELECT user_id, event_type, value                  │    │
│  │ FROM events                                        │    │
│  │ PREWHERE event_date = '2024-01-15'                │    │
│  │ WHERE user_id = 123;                               │    │
│  └─────────────────────────────────────────────────────┘    │
│  1. 只读取主键列 (event_date)                               │
│  2. 过滤不符合日期的数据                                    │
│  3. 只读取剩余行的其他列                                     │
│  4. 继续过滤                                                │
│                                                              │
│  优势: 减少 I/O，提升性能                                    │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

```sql
-- 使用 PREWHERE
SELECT user_id, event_type, value
FROM tutorial.events
PREWHERE event_date = '2024-01-15'
WHERE user_id = 123;
```

### 分区裁剪

```sql
-- 利用分区键进行裁剪
SELECT * FROM events
WHERE event_date >= '2024-01-01' AND event_date < '2024-02-01';

-- 查看分区裁剪
EXPLAIN PLAN 
SELECT * FROM events
WHERE event_date >= '2024-01-01';
```

### 谓词下推

```
┌─────────────────────────────────────────────────────────────┐
│                    谓词下推原理                                │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  原始查询:                                                  │
│  SELECT sum(value)                                          │
│  FROM (SELECT * FROM events WHERE date = '2024-01-01')     │
│  WHERE type = 'click';                                      │
│                                                              │
│  优化后:                                                    │
│  SELECT sum(value)                                          │
│  FROM events                                                │
│  WHERE date = '2024-01-01' AND type = 'click';            │
│                                                              │
│  效果: 在数据源就进行过滤，减少数据传输                      │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

## 向量化执行

### 向量化原理

```
┌─────────────────────────────────────────────────────────────┐
│                   向量化执行原理                               │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  传统行式执行:                                              │
│  for (i = 0; i < n; i++) {                                │
│      result[i] = func(row[i]);                             │  ← 每次处理1行
│  }                                                          │
│                                                              │
│  向量化执行:                                                │
│  result = func(batch);                                      │  ← 每次处理一批
│                                                              │
│  ┌─────────────────────────────────────────────────────┐    │
│  │  SIMD 指令: 单指令多数据                             │    │
│  │  [1,2,3,4] + [5,6,7,8] = [6,8,10,12]              │    │
│  │  一次计算多个数据                                    │    │
│  └─────────────────────────────────────────────────────┘    │
│                                                              │
│  优势:                                                      │
│  - 减少循环开销                                             │
│  - 更好利用 CPU 缓存                                         │
│  - 充分利用 SIMD 指令                                       │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### 向量化执行示例

```sql
-- 聚合函数使用向量化执行
SELECT 
    event_type,
    count() AS cnt,
    sum(value) AS total,
    avg(value) AS avg,
    stddevPop(value) AS std
FROM tutorial.events
GROUP BY event_type;
```

## 并行执行

### 查询并行化

```sql
-- 设置并行线程数
SET max_threads = 8;

-- 执行查询
SELECT count() FROM tutorial.events;
```

### 数据并行读取

```
┌─────────────────────────────────────────────────────────────┐
│                   数据并行读取                                │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  单线程读取:                                                 │
│  ┌─────────────────────────────────────────────────────┐    │
│  │ Read Part1 ──► Process ──► Part2 ──► Process ...   │    │
│  └─────────────────────────────────────────────────────┘    │
│                                                              │
│  多线程读取:                                                 │
│  ┌─────────────────────────────────────────────────────┐    │
│  │ Thread1: Read Part1 ──┐                            │    │
│  │ Thread2: Read Part2 ──┼──► Merge ──► Result      │    │
│  │ Thread3: Read Part3 ──┘                            │    │
│  └─────────────────────────────────────────────────────┘    │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

## 查询执行示例

### 创建测试数据

```sql
CREATE DATABASE IF NOT EXISTS tutorial;

CREATE TABLE IF NOT EXISTS tutorial.query_exec_demo (
    id UInt64,
    event_date Date,
    user_id UInt32,
    event_type String,
    value Float64
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_date)
ORDER BY (event_date, user_id, id);

INSERT INTO tutorial.query_exec_demo
SELECT 
    number,
    toDate('2024-01-01') + (number % 365),
    number % 10000,
    ['click', 'view', 'purchase'][number % 3 + 1],
    rand() / 100.0
FROM numbers(1000000);
```

### EXPLAIN 使用

```sql
-- 查看执行计划
EXPLAIN PLAN 
SELECT 
    event_date,
    count(),
    sum(value)
FROM tutorial.query_exec_demo
WHERE user_id = 100
GROUP BY event_date;

-- 查看执行管道
EXPLAIN PIPELINE
SELECT count() FROM tutorial.query_exec_demo;

-- 估算查询成本
EXPLAIN ESTIMATE
SELECT count() FROM tutorial.query_exec_demo
WHERE user_id = 100;
```

### 查询分析

```sql
-- 查看查询统计
SELECT 
    query,
    read_rows,
    read_bytes,
    query_duration_ms,
    formatReadableSize(memory_usage) AS memory
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query LIKE '%query_exec_demo%'
ORDER BY event_time DESC
LIMIT 5;
```

## 查询执行阶段详解

### 1. Source 阶段

```sql
-- 读取数据源
SELECT * FROM events;
```

### 2. Filter 阶段

```sql
-- 过滤数据
SELECT * FROM events WHERE user_id = 100;
```

### 3. Aggregating 阶段

```sql
-- 聚合
SELECT user_id, count() FROM events GROUP BY user_id;
```

### 4. OrderBy 阶段

```sql
-- 排序
SELECT * FROM events ORDER BY event_date;
```

### 5. Limit 阶段

```sql
-- 限制结果
SELECT * FROM events LIMIT 10;
```

## 常见优化技巧

### 1. 使用 PREWHERE

```sql
-- 好的写法
SELECT user_id, event_type
FROM events
PREWHERE event_date = '2024-01-15'
WHERE user_id = 100;
```

### 2. 避免函数在 WHERE 中

```sql
-- 慢
SELECT * FROM events WHERE toYYYYMM(event_date) = 202401;

-- 快
SELECT * FROM events WHERE event_date >= '2024-01-01' AND event_date < '2024-02-01';
```

### 3. 限制返回数据

```sql
-- 使用 LIMIT
SELECT * FROM events LIMIT 1000;

-- 使用 PREWHERE 减少读取
SELECT * FROM events
PREWHERE event_date >= '2024-01-01'
LIMIT 1000;
```

### 4. 使用合适的列

```sql
-- 只选择需要的列
SELECT user_id, count() FROM events GROUP BY user_id;

-- 避免 SELECT *
```

## 查询性能分析

### 1. 慢查询日志

```sql
SELECT 
    query,
    query_duration_ms,
    read_rows,
    read_bytes
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query_duration_ms > 1000
ORDER BY query_duration_ms DESC
LIMIT 10;
```

### 2. 查询 Profile

```sql
SET allow_introspection_functions = 1;

-- 执行查询
SELECT count() FROM tutorial.query_exec_demo
SETTINGS profiler_log_queries = 1;
```

### 3. 监控资源使用

```sql
SELECT 
    metric,
    value,
    description
FROM system.metrics
WHERE metric LIKE '%Thread%'
   OR metric LIKE '%Query%';
```

## 下一步

- [07_replication.md](./07_replication.md) - 复制和分片原理
