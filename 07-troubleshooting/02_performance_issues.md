# 性能问题

本文档描述 ClickHouse 性能相关的问题及解决方案。

## 问题 1: 查询缓慢

### 现象

- 查询响应时间过长
- CPU 使用率高
- 内存占用大

### 诊断

```sql
-- 查看当前正在执行的查询
SELECT
    query_id,
    user,
    query,
    elapsed,
    read_rows,
    formatReadableSize(read_bytes) as bytes_read,
    formatReadableSize(memory_usage) as memory
FROM system.processes
ORDER BY elapsed DESC;

-- 查看慢查询历史
SELECT
    query_duration_ms / 1000 as duration_seconds,
    query,
    read_rows,
    formatReadableSize(read_bytes) as bytes_read
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query_duration_ms > 1000
  AND event_time > now() - INTERVAL 1 DAY
ORDER BY query_duration_ms DESC
LIMIT 20;
```

### 解决方案

1. **优化查询**
   ```sql
   -- ❌ 不好：全表扫描
   SELECT * FROM large_table;

   -- ✅ 好：添加 WHERE 条件
   SELECT * FROM large_table WHERE date = today();

   -- ✅ 好：添加 LIMIT
   SELECT * FROM large_table WHERE date = today() LIMIT 1000;
   ```

2. **添加索引**
   ```sql
   -- 添加跳数索引
   ALTER TABLE table_name ADD INDEX idx_column (column) TYPE minmax GRANULARITY 1;
   ```

3. **使用 Projection**
   ```sql
   -- 创建投影
   ALTER TABLE table_name ADD PROJECTION proj_name
   (SELECT column1, column2 ORDER BY column1);
   ```

4. **调整配置**
   ```xml
   <max_threads>8</max_threads>
   <max_memory_usage>8000000000</max_memory_usage>
   ```

## 问题 2: 写入缓慢

### 现象

- 数据插入延迟高
- 批量插入阻塞

### 诊断

```sql
-- 查看插入统计
SELECT
    event,
    value,
    description
FROM system.events
WHERE event LIKE 'Insert%'
ORDER BY value DESC;

-- 查看合并任务
SELECT
    database,
    table,
    count(*) as merge_count
FROM system.merges
GROUP BY database, table
ORDER BY merge_count DESC;
```

### 解决方案

1. **批量插入**
   ```sql
   -- ❌ 不好：单条插入
   INSERT INTO table VALUES (1, 'data1');
   INSERT INTO table VALUES (2, 'data2');

   -- ✅ 好：批量插入
   INSERT INTO table VALUES
       (1, 'data1'),
       (2, 'data2'),
       (3, 'data3');
   ```

2. **使用异步插入**
   ```xml
   <async_insert>1</async_insert>
   <wait_for_async_insert>0</wait_for_async_insert>
   <async_insert_max_data_size>1048576</async_insert_max_data_size>
   ```

3. **使用 Buffer 表**
   ```sql
   CREATE TABLE buffer_table ON CLUSTER 'treasurycluster'
   AS target_table
   ENGINE = Buffer(database, target_table,
       16, 10, 100, 10000000, 10, 100, 2);
   ```

4. **调整合并参数**
   ```xml
   <max_bytes_to_merge_at_max_space_in_pool>10737418240</max_bytes_to_merge_at_max_space_in_pool>
   <background_pool_size>16</background_pool_size>
   ```

## 问题 3: CPU 使用率高

### 现象

- CPU 持续 100%
- 系统响应缓慢

### 诊断

```sql
-- 查看正在执行的查询
SELECT * FROM system.processes ORDER BY elapsed DESC;

-- 查看 CPU 事件
SELECT
    event,
    value,
    description
FROM system.events
WHERE event LIKE 'CPU%'
ORDER BY value DESC;
```

### 解决方案

1. **限制并发查询**
   ```xml
   <max_concurrent_queries>100</max_concurrent_queries>
   <max_concurrent_queries_for_user>10</max_concurrent_queries_for_user>
   ```

2. **优化查询**
   - 添加 WHERE 条件
   - 使用 LIMIT
   - 避免全表扫描

3. **调整线程数**
   ```xml
   <max_threads>8</max_threads>
   <background_pool_size>16</background_pool_size>
   ```

4. **杀掉占用 CPU 的查询**
   ```sql
   -- 查看查询 ID
   SELECT query_id, query FROM system.processes;

   -- 杀掉查询
   KILL QUERY WHERE query_id = 'query_id';
   ```

## 问题 4: 内存不足

### 现象

```
Memory limit exceeded
OutOfMemory
```

### 诊断

```sql
-- 查看内存使用
SELECT
    formatReadableSize(total_memory) as total,
    formatReadableSize(free_memory) as free,
    formatReadableSize(total_memory - free_memory) as used
FROM system.memory;

-- 查看查询内存使用
SELECT
    query_id,
    query,
    formatReadableSize(memory_usage) as memory
FROM system.processes
ORDER BY memory_usage DESC;
```

### 解决方案

1. **限制查询内存**
   ```sql
   SET max_memory_usage = 4000000000;  -- 4GB
   ```

2. **优化查询**
   - 使用 LIMIT
   - 避免 SELECT *
   - 使用聚合函数

3. **增加内存限制**
   ```xml
   <max_memory_usage>8000000000</max_memory_usage>
   ```

4. **使用物化视图**
   ```sql
   CREATE MATERIALIZED VIEW mv_table ON CLUSTER 'treasurycluster'
   ENGINE = AggregatingMergeTree()
   ORDER BY group_key
   AS SELECT
       group_key,
       sumState(metric) as metric
   FROM source_table
   GROUP BY group_key;
   ```

## 问题 5: 合并积压

### 现象

- 分区数量持续增长
- 查询性能下降

### 诊断

```sql
-- 查看合并任务
SELECT
    database,
    table,
    count(*) as pending_merges,
    sum(progress) as total_progress
FROM system.merges
GROUP BY database, table
ORDER BY pending_merges DESC;

-- 查看分区数量
SELECT
    database,
    table,
    count(*) as part_count
FROM system.parts
WHERE active = 1
GROUP BY database, table
HAVING count(*) > 50
ORDER BY part_count DESC;
```

### 解决方案

1. **手动触发合并**
   ```sql
   OPTIMIZE TABLE table_name ON CLUSTER 'treasurycluster' PARTITION '202401' FINAL;
   ```

2. **调整合并参数**
   ```sql
   SET GLOBAL max_bytes_to_merge_at_max_space_in_pool = 10737418240;  -- 10GB
   SET GLOBAL max_bytes_to_merge_at_once = 1610612736;  -- 1.5GB
   ```

3. **限制写入频率**
   - 降低批量插入的大小
   - 增加插入间隔

4. **使用 TTL 自动清理**
   ```sql
   ALTER TABLE table_name ON CLUSTER 'treasurycluster'
   MODIFY TTL event_time TO DELETE + INTERVAL 90 DAY;
   ```

---

**最后更新**: 2026-01-19
