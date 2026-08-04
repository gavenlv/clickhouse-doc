# CPU/内存/网络资源优化指南

## 1. CPU优化

### 1.1 插入线程优化

**关键参数**：
```sql
-- 方案A（32核CPU）
SET max_insert_threads = 24;  -- CPU核心数的75%

-- 方案B（16核CPU）
SET max_insert_threads = 12;  -- CPU核心数的75%
```

**原理**：
- ClickHouse使用多线程并行插入
- 线程数 = CPU核心数 × 0.75（留25%给其他操作）
- 避免CPU 100%占用导致系统卡顿

**监控**：
```sql
-- 查看CPU使用率
SELECT metric, value FROM system.metrics WHERE metric = 'CPUUsage';

-- 查看线程数
SELECT metric, value FROM system.metrics WHERE metric = 'TotalThreads';
```

---

### 1.2 并行解析优化

**关键参数**：
```sql
SET input_format_parallel_parsing = 1;  -- 启用并行解析Parquet
SET input_format_parquet_max_block_size = 1000000;
SET max_threads = 32;  -- 最大线程数
```

**原理**：
- Parquet文件支持并行解析
- 多个线程同时解析不同的row group
- 大幅提升解析速度

---

### 1.3 避免CPU过载

**监控CPU使用**：
```bash
# 查看CPU使用情况
top -p $(pgrep clickhouse-server)

# 或使用ClickHouse SQL
SELECT 
    metric,
    value,
    description
FROM system.metrics
WHERE metric LIKE '%CPU%';
```

**优化建议**：
- CPU使用率 < 70%：可增加max_insert_threads
- CPU使用率 70-85%：当前配置合理
- CPU使用率 > 85%：减少max_insert_threads

---

## 2. 内存优化

### 2.1 内存限制设置

**关键参数**：
```sql
-- 方案A（256GB RAM）
SET max_memory_usage = 240000000000;  -- 240GB（93%）

-- 方案B（128GB RAM）
SET max_memory_usage = 120000000000;  -- 120GB（93%）
```

**原理**：
- 单个查询的最大内存使用
- 留7%给操作系统和其他进程
- 避免内存溢出

---

### 2.2 批量大小优化

**关键参数**：
```sql
SET max_insert_block_size = 1048576;        -- 1M行块
SET min_insert_block_size_rows = 1000000;   -- 最小1M行
SET min_insert_block_size_bytes = 1073741824; -- 最小1GB
```

**权衡**：
- 批量大：内存占用高，但效率高
- 批量小：内存占用低，但效率低

**建议**：
- 内存充足（>200GB）：使用1M行块
- 内存一般（100-200GB）：使用500K行块
- 内存紧张（<100GB）：使用100K行块

---

### 2.3 内存监控

**监控内存使用**：
```sql
-- 查看当前内存使用
SELECT 
    metric,
    value,
    formatReadableSize(value) as size
FROM system.metrics
WHERE metric = 'MemoryTracking';

-- 查看内存分配详情
SELECT 
    query_id,
    memory_usage,
    formatReadableSize(memory_usage) as size,
    query
FROM system.processes
ORDER BY memory_usage DESC
LIMIT 10;
```

**内存泄漏检查**：
```sql
-- 查看长时间运行的查询
SELECT 
    query_id,
    query_duration_ms,
    memory_usage,
    query
FROM system.processes
WHERE query_duration_ms > 300000  -- 超过5分钟
ORDER BY memory_usage DESC;
```

---

## 3. 网络优化

### 3.1 GCS网络优化

**关键参数**：
```sql
SET connect_timeout = 600;    -- 连接超时10分钟
SET receive_timeout = 600;    -- 接收超时10分钟
SET send_timeout = 600;       -- 发送超时10分钟
SET max_retry_count = 3;      -- 最大重试次数
```

**原理**：
- GCS下载大文件需要较长超时时间
- 网络波动需要重试机制

---

### 3.2 多客户端并行下载

**原理**：
- GCS支持并发下载
- 多个客户端同时下载不同文件
- 充分利用网络带宽

**实施**：
```bash
# 启动多个客户端并行导入
for i in {1..8}; do
    clickhouse-client --query="
        INSERT INTO target_table
        SETTINGS max_insert_threads = 3
        SELECT * FROM gcs('file_${i}.parquet', 'Parquet')
    " &
done
wait
```

---

### 3.3 网络监控

**监控网络使用**：
```sql
-- 查看网络IO
SELECT 
    filesystem,
    sum(read_bytes) as read_bytes,
    sum(write_bytes) as write_bytes,
    formatReadableSize(sum(read_bytes)) as read_size,
    formatReadableSize(sum(write_bytes)) as write_size
FROM system.filesystem
GROUP BY filesystem;
```

---

## 4. 磁盘IO优化

### 4.1 存储策略配置

**分层存储**：
```xml
<storage_configuration>
    <disks>
        <hyperdisk>
            <path>/mnt/hyperdisk/</path>
        </hyperdisk>
        <ssd>
            <path>/mnt/ssd/</path>
        </ssd>
        <gcs>
            <type>s3</type>
            <endpoint>https://storage.googleapis.com/bucket/</endpoint>
        </gcs>
    </disks>
    
    <policies>
        <tiered_storage>
            <volumes>
                <hot>
                    <disk>hyperdisk</disk>
                    <max_data_part_size_bytes>10737418240</max_data_part_size_bytes> <!-- 10GB -->
                </hot>
                <warm>
                    <disk>ssd</disk>
                </warm>
                <cold>
                    <disk>gcs</disk>
                </cold>
            </volumes>
        </tiered_storage>
    </policies>
</storage_configuration>
```

---

### 4.2 IO调度优化

**查看磁盘IO**：
```bash
# 使用iostat查看磁盘IO
iostat -x 1

# 查看磁盘队列
iotop
```

**优化建议**：
- 使用Extreme Hyperdisk（高IOPS）
- 调整max_insert_block_size减少小IO
- 避免同时运行大量查询

---

## 5. 综合优化建议

### 5.1 方案A优化配置

```sql
-- CPU优化
SET max_insert_threads = 24;              -- 32核的75%
SET max_threads = 32;
SET input_format_parallel_parsing = 1;

-- 内存优化
SET max_memory_usage = 240000000000;      -- 240GB
SET max_insert_block_size = 1048576;      -- 1M行

-- 网络优化
SET connect_timeout = 600;
SET receive_timeout = 600;
SET max_retry_count = 3;

-- 复制优化
SET insert_quorum = 1;                    -- 异步复制
SET insert_quorum_timeout = 300000;
```

---

### 5.2 方案B优化配置

```sql
-- CPU优化
SET max_insert_threads = 12;              -- 16核的75%
SET max_threads = 16;

-- 内存优化
SET max_memory_usage = 120000000000;      -- 120GB
SET max_insert_block_size = 1048576;

-- 分布式优化
SET prefer_localhost_replica = 0;         -- 分布式写入
SET insert_distributed_sync = 2;
SET insert_quorum = 2;
```

---

## 6. 性能基准测试

### 6.1 测试方法

```sql
-- 记录开始时间
SELECT now() as start_time;

-- 执行导入
INSERT INTO target_table
SETTINGS max_insert_threads = 24
SELECT * FROM gcs('data.parquet', 'Parquet');

-- 记录结束时间
SELECT now() as end_time;

-- 计算性能
SELECT 
    count() as total_rows,
    query_duration_ms / 1000 as duration_sec,
    count() / (query_duration_ms / 1000) as rows_per_sec
FROM system.query_log
WHERE query LIKE '%INSERT INTO target_table%'
  AND type = 'QueryFinish'
ORDER BY event_time DESC
LIMIT 1;
```

---

### 6.2 性能指标

**目标性能**：
- 方案A：8-12分钟导入150亿行
- 方案B：2-3分钟导入150亿行

**计算方法**：
```
150亿行 / 8分钟 = 3125万行/秒
150亿行 / 3分钟 = 8333万行/秒
```

---

## 7. 常见问题

### 问题1：CPU使用率低

**原因**：
- max_insert_threads设置过小
- 单线程处理瓶颈
- 数据量小

**解决**：
```sql
-- 增加插入线程
SET max_insert_threads = 24;

-- 启用并行解析
SET input_format_parallel_parsing = 1;
```

---

### 问题2：内存溢出

**原因**：
- max_memory_usage设置过大
- 批量大小过大
- 并发查询过多

**解决**：
```sql
-- 限制内存使用
SET max_memory_usage = 200000000000;

-- 减小批量大小
SET max_insert_block_size = 524288;

-- 限制并发
SET max_concurrent_queries = 10;
```

---

### 问题3：网络瓶颈

**原因**：
- 单客户端下载速度慢
- GCS到单节点带宽限制

**解决**：
```bash
# 使用多客户端并行下载
# 见 scripts/parallel_import_plan_a.sh
```

---

## 8. 最佳实践

### 8.1 监控指标

**关键指标**：
- CPU使用率：< 85%
- 内存使用率：< 90%
- 网络吞吐量：接近带宽上限
- 磁盘IOPS：接近上限

### 8.2 调优流程

```
1. 设置初始参数
   ↓
2. 执行测试导入
   ↓
3. 监控资源使用
   ↓
4. 调整参数
   ↓
5. 重复步骤2-4，直到达到最优性能
```

### 8.3 注意事项

- ⚠️ 生产环境先在测试环境验证
- ⚠️ 监控系统资源避免过载
- ⚠️ 留足够的资源余量
- ⚠️ 定期检查性能指标
