# ClickHouse 监控专题

本专题介绍如何全面监控 ClickHouse 的使用情况，特别是检测和预防常见的滥用行为和反模式。

## 📚 文档目录

```
13-monitor/
├── README.md                      # 监控总览（本文件）
├── 01_system_monitoring.md       # 系统资源监控
├── 02_query_monitoring.md        # 查询监控和反模式
├── 03_data_quality_monitoring.md # 数据质量监控
├── 04_operation_monitoring.md     # 操作监控
├── 05_abuse_detection.md         # 滥用检测
├── 06_alerting.md                # 告警机制
├── 07_best_practices.md          # 监控最佳实践
└── 08_common_configs.md          # 常见监控配置
```

## 🎯 监控目标

### 1. 系统健康监控
- CPU、内存、磁盘、网络使用率
- 集群健康状态
- 副本同步状态
- 分布式表状态

### 2. 查询性能监控
- 慢查询检测
- 查询资源消耗
- 查询反模式检测
- 查询频率统计

### 3. 数据质量监控
- 分区键使用合理性
- 排序键和主键设计
- 索引效率
- 数据倾斜检测

### 4. 操作审计监控
- 频繁 ALTER 操作
- 大量 MUTATION 操作
- 数据删除操作
- 表结构变更

### 5. 滥用行为检测
- 使用非复制表
- Transaction 表 JOIN
- 全表扫描
- 大量小查询
- 异常查询模式

## 🚀 快速开始

### 基础监控查询

```sql
-- 1. 慢查询监控
SELECT
    query_id,
    user,
    query_duration_ms / 1000 AS duration_sec,
    read_rows,
    read_bytes,
    memory_usage,
    substring(query, 1, 200) AS query
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query_duration_ms > 5000  -- 超过 5 秒
ORDER BY query_duration_ms DESC
LIMIT 10;

-- 2. 检测非复制表
SELECT
    database,
    table,
    engine,
    partition_key,
    sorting_key,
    total_rows,
    total_bytes
FROM system.tables
WHERE engine NOT LIKE '%Replicated%'
  AND database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
  AND total_bytes > 0
ORDER BY total_bytes DESC;

-- 3. 检测 JOIN 事务表
SELECT
    query_id,
    user,
    query_duration_ms,
    read_rows,
    substring(query, 1, 300) AS query
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query NOT LIKE '%system.%'
  AND (
    query ILIKE '%JOIN%transactions%'
    OR query ILIKE '%transactions%JOIN%'
    OR query ILIKE '%JOIN%transaction%'
    OR query ILIKE '%transaction%JOIN%'
  )
ORDER BY query_duration_ms DESC
LIMIT 10;

-- 4. 检测频繁 ALTER 操作
SELECT
    user,
    query,
    count() AS alter_count,
    avg(query_duration_ms) AS avg_duration_ms
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query ILIKE 'ALTER%'
  AND event_date >= today() - INTERVAL 7 DAY
GROUP BY user, query
HAVING alter_count > 10
ORDER BY alter_count DESC;

-- 5. 检测未使用索引的查询
SELECT
    query_id,
    user,
    read_rows,
    result_rows,
    read_rows / greatest(result_rows, 1) AS read_ratio,
    query_duration_ms,
    substring(query, 1, 300) AS query
FROM system.query_log
WHERE type = 'QueryFinish'
  AND read_rows > 100000
  AND result_rows < 1000
  AND read_rows / result_rows > 100
ORDER BY read_ratio DESC
LIMIT 10;
```

## 🔍 常见反模式检测

### 1. 使用非复制表
**问题描述**: 在生产环境中使用普通表引擎而非复制表引擎

**检测方法**:
```sql
-- 查找所有非复制表
SELECT
    database,
    table,
    engine,
    total_rows,
    total_bytes
FROM system.tables
WHERE database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
  AND engine NOT LIKE '%Replicated%'
  AND engine NOT LIKE '%View%'
  AND engine NOT LIKE '%Dictionary%'
ORDER BY total_bytes DESC;
```

**解决方案**:
- 使用 `ReplicatedMergeTree` 系列引擎
- 确保所有关键表都启用的复制

### 2. Transaction 表 JOIN
**问题描述**: 对 Transaction 类型的表进行 JOIN 操作

**检测方法**:
```sql
-- 检测 Transaction 表 JOIN
SELECT
    query_id,
    user,
    query_duration_ms,
    substring(query, 1, 500) AS query
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query ILIKE '%JOIN%'
  AND (
    query ILIKE '%transactions%'
    OR query ILIKE '%transaction%'
  )
ORDER BY query_duration_ms DESC
LIMIT 10;
```

**解决方案**:
- 避免对 Transaction 表进行 JOIN
- 考虑使用子查询或物化视图
- 使用分布式表代替直接 JOIN

### 3. 错误的分区键
**问题描述**: 分区键选择不当导致数据倾斜或查询效率低

**检测方法**:
```sql
-- 检测分区不均衡
SELECT
    database,
    table,
    partition,
    sum(rows) AS partition_rows,
    sum(bytes) AS partition_bytes,
    formatReadableSize(sum(bytes)) AS readable_size
FROM system.parts
WHERE active
  AND database NOT IN ('system')
GROUP BY database, table, partition
ORDER BY partition_rows DESC
LIMIT 20;

-- 计算分区倾斜度
SELECT
    database,
    table,
    max(partition_rows) / avg(partition_rows) AS skew_ratio,
    count() AS partition_count
FROM (
    SELECT
        database,
        table,
        partition,
        sum(rows) AS partition_rows
    FROM system.parts
    WHERE active
      AND database NOT IN ('system')
    GROUP BY database, table, partition
)
GROUP BY database, table
HAVING skew_ratio > 3  -- 倾斜度超过 3
ORDER BY skew_ratio DESC;
```

**解决方案**:
- 选择高基数字段作为分区键
- 避免使用低基数字段（如性别、状态）
- 使用日期/时间字段进行分区
- 定期监控分区均衡性

### 4. 错误的 ORDER BY
**问题描述**: 查询使用错误的排序键，导致性能低下

**检测方法**:
```sql
-- 检测未使用排序键的 WHERE 条件
SELECT
    query_id,
    user,
    query_duration_ms,
    read_rows,
    result_rows,
    substring(query, 1, 300) AS query
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query ILIKE '%WHERE%'
  AND NOT query ILIKE '%PREWHERE%'
  AND read_rows > 10000
  AND query_duration_ms > 1000
ORDER BY query_duration_ms DESC
LIMIT 10;

-- 检测全表扫描
SELECT
    query_id,
    user,
    query_duration_ms,
    read_rows,
    read_bytes,
    substring(query, 1, 300) AS query
FROM system.query_log
WHERE type = 'QueryFinish'
  AND read_rows > 1000000  -- 读取超过 100 万行
  AND query_duration_ms > 3000
ORDER BY read_rows DESC
LIMIT 10;
```

**解决方案**:
- 确保查询 WHERE 条件使用排序键的前缀
- 使用 PREWHERE 优化过滤条件
- 添加合适的数据跳数索引
- 重写查询以利用索引

### 5. 索引问题
**问题描述**: 未使用合适的数据跳数索引

**检测方法**:
```sql
-- 查找缺少索引的表
SELECT
    database,
    table,
    engine,
    total_rows,
    total_bytes,
    formatReadableSize(total_bytes) AS readable_size
FROM system.tables
WHERE database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
  AND total_bytes > 1000000000  -- 大于 1GB
  AND (
    SELECT count()
    FROM system.data_skipping_indices
    WHERE database = system.tables.database
      AND table = system.tables.table
  ) = 0
ORDER BY total_bytes DESC;

-- 索引使用效率
SELECT
    database,
    table,
    name AS index_name,
    type,
    expr,
    marks,
    granules,
    type
FROM system.data_skipping_indices
WHERE database NOT IN ('system')
ORDER BY database, table;
```

**解决方案**:
- 为常用过滤条件添加数据跳数索引
- 使用 minmax、set、bloom_filter 等索引类型
- 监控索引使用效率
- 定期维护和优化索引

### 6. 频繁 ALTER 操作
**问题描述**: 频繁执行 ALTER 操作影响性能

**检测方法**:
```sql
-- 检测频繁 ALTER 操作
SELECT
    user,
    database,
    count() AS alter_count,
    sum(query_duration_ms) AS total_duration_ms,
    any(substring(query, 1, 200)) AS example_query
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query ILIKE 'ALTER%'
  AND event_date >= today() - INTERVAL 1 DAY
GROUP BY user, database
HAVING alter_count > 5
ORDER BY alter_count DESC;

-- 检测 ALTER 历史趋势
SELECT
    toDate(event_time) AS date,
    count() AS alter_count,
    avg(query_duration_ms) AS avg_duration_ms
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query ILIKE 'ALTER%'
  AND event_date >= today() - INTERVAL 30 DAY
GROUP BY date
ORDER BY date;
```

**解决方案**:
- 批量执行 ALTER 操作
- 使用 OPTIMIZE 代替频繁的 ALTER
- 规划表结构变更
- 监控 ALTER 操作频率

### 7. 大量小查询
**问题描述**: 频繁执行小查询消耗资源

**检测方法**:
```sql
-- 检测频繁小查询
SELECT
    user,
    count() AS query_count,
    avg(read_rows) AS avg_rows,
    avg(query_duration_ms) AS avg_duration_ms,
    substring(any(query), 1, 200) AS example_query
FROM system.query_log
WHERE type = 'QueryFinish'
  AND read_rows < 1000
  AND event_date >= today() - INTERVAL 1 DAY
GROUP BY user
HAVING query_count > 1000
ORDER BY query_count DESC;

-- 检测 QPS 过高
SELECT
    toStartOfMinute(event_time) AS minute,
    count() AS qps
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today()
GROUP BY minute
HAVING qps > 100
ORDER BY minute DESC
LIMIT 10;
```

**解决方案**:
- 批量处理查询
- 使用缓存减少重复查询
- 合并小查询
- 实现查询限流

## 📊 监控仪表板

### 关键指标

| 指标类别 | 关键指标 | 告警阈值 |
|---------|---------|---------|
| **系统资源** | CPU 使用率 | > 80% |
| | 内存使用率 | > 85% |
| | 磁盘使用率 | > 80% |
| | 磁盘 I/O 等待 | > 20% |
| **查询性能** | 慢查询比例 | > 5% |
| | 查询超时次数 | > 10/hour |
| | 平均查询延迟 | > 1s |
| **数据质量** | 分区倾斜度 | > 3 |
| | 复制表覆盖率 | < 100% |
| | 索引覆盖率 | < 80% |
| **操作审计** | ALTER 操作频率 | > 10/hour |
| | MUTATION 操作频率 | > 5/hour |
| | 删除操作次数 | > 20/day |

## 🛠️ 监控工具

### 1. 系统监控
```sql
-- 创建监控视图
CREATE VIEW monitoring.system_health AS
SELECT
    now() AS timestamp,
    'CPU' AS metric,
    avgProfile(cpu) AS value
UNION ALL
SELECT
    now() AS timestamp,
    'Memory' AS metric,
    avgProfile(memory) AS value;
```

### 2. 查询监控
```sql
-- 查询性能统计
CREATE VIEW monitoring.query_performance AS
SELECT
    toStartOfMinute(event_time) AS minute,
    count() AS total_queries,
    countIf(query_duration_ms > 1000) AS slow_queries,
    avg(query_duration_ms) AS avg_duration_ms,
    max(query_duration_ms) AS max_duration_ms,
    sum(read_bytes) AS total_read_bytes,
    sum(memory_usage) AS total_memory_usage
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today() - INTERVAL 7 DAY
GROUP BY minute;
```

### 3. 反模式检测
```sql
-- 反模式汇总
CREATE VIEW monitoring.anti_patterns AS
SELECT
    'Non-replicated tables' AS pattern_type,
    count() AS count
FROM system.tables
WHERE engine NOT LIKE '%Replicated%'
  AND database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
UNION ALL
SELECT
    'Partition skew > 3' AS pattern_type,
    count() AS count
FROM (
    SELECT
        database,
        table,
        max(partition_rows) / avg(partition_rows) AS skew_ratio
    FROM (
        SELECT
            database,
            table,
            partition,
            sum(rows) AS partition_rows
        FROM system.parts
        WHERE active
          AND database NOT IN ('system')
        GROUP BY database, table, partition
    )
    GROUP BY database, table
)
WHERE skew_ratio > 3;
```

## ⚠️ 重要注意事项

1. **监控开销**: 监控本身会消耗资源，需要权衡监控粒度
2. **日志保留**: 合理设置日志保留时间，避免占用过多空间
3. **告警疲劳**: 合理设置告警阈值，避免频繁误报
4. **历史数据**: 定期清理历史监控数据
5. **性能影响**: 避免在生产环境运行复杂的监控查询
6. **权限控制**: 监控系统应该有严格的访问控制
7. **自动化**: 尽可能实现自动化的监控和告警
8. **持续优化**: 根据实际情况持续优化监控策略

## 📚 相关文档

- [06-admin/](../06-admin/) - 运维管理
- [11-performance/](../11-performance/) - 性能优化
- [12-security-authentication/](../12-security-authentication/) - 安全认证
- [01-base/](../01-base/) - 基础使用

## 🔗 官方资源

- [Monitoring](https://clickhouse.com/docs/en/operations/monitoring)
- [Query Profiling](https://clickhouse.com/docs/en/operations/profiling)
- [System Tables](https://clickhouse.com/docs/en/operations/system-tables)
