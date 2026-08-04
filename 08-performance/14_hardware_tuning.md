# 硬件调优和测试

合理的硬件配置和调优是 ClickHouse 性能优化的基础。

## 硬件推荐

### CPU 推荐

| 场景 | CPU 推荐 | 核心数 | 频率 |
|------|---------|--------|------|
| 小型集群 | Intel Xeon E5 / AMD EPYC | 8-16 核 | 2.0-3.0 GHz |
| 中型集群 | Intel Xeon Scalable / AMD EPYC | 16-32 核 | 2.5-3.5 GHz |
| 大型集群 | Intel Xeon Scalable / AMD EPYC | 32-64 核 | 2.5-3.5 GHz |

### 内存推荐

| 场景 | 内存推荐 | 说明 |
|------|---------|------|
| 小型集群 | 16-32 GB | 适合 < 100 GB 数据 |
| 中型集群 | 64-128 GB | 适合 100-1000 GB 数据 |
| 大型集群 | 256-512 GB | 适合 > 1000 GB 数据 |

### 存储推荐

| 场景 | 存储推荐 | 说明 |
|------|---------|------|
| 混合型 | NVMe SSD | 最佳性能 |
| 读取密集型 | NVMe SSD | 高 IOPS |
| 写入密集型 | NVMe SSD | 高吞吐量 |
| 归档存储 | HDD + 压缩 | 低成本 |

### 网络推荐

| 场景 | 网络推荐 | 带宽 |
|------|---------|------|
| 集群内网 | 10 Gbps | 高吞吐量 |
| 跨机房 | 1 Gbps | 低延迟 |

## 系统配置调优

### 1. 文件描述符限制

```bash
# 增加文件描述符限制
echo "* soft nofile 65536" >> /etc/security/limits.conf
echo "* hard nofile 65536" >> /etc/security/limits.conf

# 重启服务
systemctl restart clickhouse-server
```

### 2. 内核参数优化

```bash
# 优化内核参数
echo "vm.swappiness = 1" >> /etc/sysctl.conf
echo "vm.dirty_background_ratio = 5" >> /etc/sysctl.conf
echo "vm.dirty_ratio = 10" >> /etc/sysctl.conf
echo "net.core.somaxconn = 1024" >> /etc/sysctl.conf

# 应用配置
sysctl -p
```

### 3. 文件系统优化

```bash
# 使用 XFS 或 ext4 文件系统
mkfs.xfs /dev/sdb1

# 挂载优化
mount -o noatime,nodiratime /dev/sdb1 /data/clickhouse

# 添加到 /etc/fstab
echo "/dev/sdb1 /data/clickhouse xfs noatime,nodiratime 0 0" >> /etc/fstab
```

## ClickHouse 配置调优

### 1. 内存配置

```xml
<!-- config.xml -->
<clickhouse>
    <max_memory_usage>10000000000000</max_memory_usage>  <!-- 10 GB -->
    <max_memory_usage_for_user>8000000000000</max_memory_usage_for_user>  <!-- 8 GB -->
    <max_memory_usage_for_all_queries>4000000000000</max_memory_usage_for_all_queries>  <!-- 4 GB -->
</clickhouse>
```

### 2. 线程配置

```xml
<!-- config.xml -->
<clickhouse>
    <background_pool_size>16</background_pool_size>
    <background_merges_mutations_concurrency_ratio>2</background_merges_mutations_concurrency_ratio>
    <max_threads>8</max_threads>
    <max_concurrent_queries>100</max_concurrent_queries>
</clickhouse>
```

### 3. 缓存配置

```xml
<!-- config.xml -->
<clickhouse>
    <mark_cache_size>536870912</mark_cache_size>  <!-- 512 MB -->
    <uncompressed_cache_size>8589934592</uncompressed_cache_size>  <!-- 8 GB -->
    <compiled_expression_cache_size>1073741824</compiled_expression_cache_size>  <!-- 1 GB -->
</clickhouse>
```

### 4. 压缩配置

```xml
<!-- config.xml -->
<clickhouse>
    <compression>
        <case>
            <min_part_size>10485760</min_part_size>  <!-- 10 MB -->
            <min_part_size_ratio>0.01</min_part_size_ratio>
            <method>lz4</method>
        </case>
        <case>
            <min_part_size>1073741824</min_part_size>  <!-- 1 GB -->
            <min_part_size_ratio>0.1</min_part_size_ratio>
            <method>zstd</method>
        </case>
    </compression>
</clickhouse>
```

## 硬件测试

### 测试工具

```bash
# 1. CPU 测试
clickhouse-benchmark --query="SELECT count() FROM numbers(1000000000)"

# 2. 内存测试
clickhouse-benchmark --query="SELECT sum(number) FROM numbers(1000000000)"

# 3. 磁盘测试
clickhouse-benchmark --query="SELECT * FROM events WHERE event_time >= now() - INTERVAL 7 DAY"

# 4. 网络测试
clickhouse-benchmark --concurrency=10 --query="SELECT count() FROM numbers(100000000)"
```

### 性能基准测试

```sql
-- 测试插入性能
INSERT INTO events
SELECT 
    number as event_id,
    number % 10000 as user_id,
    'click' as event_type,
    now() as event_time,
    '{}' as event_data
FROM numbers(1000000);

-- 测试查询性能
SELECT count() FROM events;

-- 测试聚合性能
SELECT 
    user_id,
    count() as event_count
FROM events
GROUP BY user_id;

-- 测试 JOIN 性能
SELECT 
    o.order_id,
    u.username
FROM orders o
INNER JOIN users u ON o.user_id = u.user_id;
```

## 硬件监控

### CPU 监控

```sql
-- 查看 CPU 使用率
SELECT 
    metric,
    value,
    description
FROM system.metrics
WHERE metric LIKE '%CPU%';
```

### 内存监控

```sql
-- 查看内存使用
SELECT 
    metric,
    value,
    description
FROM system.metrics
WHERE metric LIKE '%Memory%';
```

### 磁盘监控

```sql
-- 查看磁盘使用
SELECT 
    metric,
    value,
    description
FROM system.metrics
WHERE metric LIKE '%Disk%';
```

## 性能调优检查清单

### 硬件配置

- [ ] CPU 是否合理？
  - [ ] 核心数 8-64
  - [ ] 频率 2.5-3.5 GHz

- [ ] 内存是否充足？
  - [ ] 16-512 GB
  - [ ] 数据量的 10-20%

- [ ] 存储是否快速？
  - [ ] NVMe SSD
  - [ ] 高 IOPS

### 系统配置

- [ ] 文件描述符是否增加？
  - [ ] 65536

- [ ] 内核参数是否优化？
  - [ ] swappiness = 1
  - [ ] dirty_ratio = 10

- [ ] 文件系统是否优化？
  - [ ] noatime, nodiratime

### ClickHouse 配置

- [ ] 内存是否合理配置？
  - [ ] max_memory_usage
  - [ ] max_memory_usage_for_user
  - [ ] max_memory_usage_for_all_queries

- [ ] 线程是否合理配置？
  - [ ] background_pool_size
  - [ ] max_threads
  - [ ] max_concurrent_queries

- [ ] 缓存是否合理配置？
  - [ ] mark_cache_size
  - [ ] uncompressed_cache_size
  - [ ] compiled_expression_cache_size

- [ ] 压缩是否合理配置？
  - [ ] min_part_size
  - [ ] 压缩方法

## 性能提升

| 优化方法 | 性能提升 |
|---------|---------|
| CPU 优化 | 1.2-2x |
| 内存优化 | 1.5-3x |
| 存储优化 | 2-10x |
| 系统配置优化 | 1.2-2x |
| ClickHouse 配置优化 | 1.5-5x |

## 相关文档

- [01_query_optimization.md](./01_query_optimization.md) - 查询优化基础
- [11_query_profiling.md](./11_query_profiling.md) - 查询分析和 Profiling
