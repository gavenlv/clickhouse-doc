-- =====================================================
-- 09 - 资源问题排查
-- =====================================================
-- 集群: treasurycluster (2副本)
-- 时间: 10-15分钟
-- =====================================================

-- -----------------------------------------------------
-- 准备环境
-- -----------------------------------------------------

DROP DATABASE IF EXISTS troubleshooting_test;
CREATE DATABASE troubleshooting_test;
USE troubleshooting_test;

-- -----------------------------------------------------
-- 1. CPU 100%
-- -----------------------------------------------------

--
-- 【原理】ClickHouse 是 CPU 密集型数据库，大量查询并发、复杂聚合计算、高
-- 基数 GROUP BY、大表 JOIN、数据压缩/解压、后台合并等操作都会消耗 CPU 资源。
-- CPU 持续 100% 通常由以下原因引起：大量并发查询超过 CPU 核数承载能力、
-- 个别查询设计不合理（全表扫描、无索引过滤）、后台合并/突变任务堆积、
-- 数据压缩级别过高（ZSTD 高等级）、外部字典频繁加载等。
--
-- 【场景】
--   - top/htop 显示 clickhouse 进程 CPU 使用率持续 100%
--   - 查询响应时间显著增加
--   - 系统负载（load average）远高于 CPU 核数
--   - 新连接建立缓慢
--   - 监控告警触发 CPU 使用率阈值
--

-- 诊断：查看当前 CPU 消耗最高的查询
SELECT
    query_id,
    user,
    query,
    elapsed,
    formatReadableSize(memory_usage) AS memory,
    formatReadableSize(read_bytes) AS bytes_read,
    read_rows,
    written_rows,
    ProfileEvents['RealTimeMicroseconds'] AS real_time_us,
    ProfileEvents['UserTimeMicroseconds'] AS user_time_us,
    ProfileEvents['SystemTimeMicroseconds'] AS system_time_us
FROM system.processes
ORDER BY elapsed DESC
LIMIT 20;

-- 诊断：查看 CPU 相关事件统计
SELECT
    event,
    value,
    description
FROM system.events
WHERE event LIKE '%CPU%'
   OR event LIKE '%Thread%'
   OR event LIKE '%ContextSwitch%'
ORDER BY event;

-- 诊断：查看系统资源使用情况
-- 【坑】system.asynchronous_metrics 只有 metric/value/description 三列，
--       CPU 时间指标按 metric 名过滤（如 OSUserTime/OSSystemTime 等）
SELECT
    metric,
    value,
    description
FROM system.asynchronous_metrics
WHERE metric LIKE '%CPU%'
ORDER BY metric;

-- 修复：限制并发查询数
-- 【坑】max_concurrent_queries 是服务端配置项（config.xml 的 <max_concurrent_queries>），
--       不允许通过 SET 修改（会报 UNKNOWN_SETTING），需改 config.xml 并重启：
--   <max_concurrent_queries>100</max_concurrent_queries>
--   <max_concurrent_queries_for_user>10</max_concurrent_queries_for_user>

-- 修复：限制查询使用的 CPU 线程数
-- 【坑】max_threads 可 SET 修改，但 max_threads_for_interactive_query 不是
--       内置设置（报 UNKNOWN_SETTING），只在部分版本存在，这里只设置 max_threads
SET max_threads = 8;

-- 修复：使用优先级队列区分高低优查询
-- 在 config.xml 中:
-- <query_thread_priority>
--     <priority>0</priority>  -- 0 = 最高优先级
-- </query_thread_priority>

-- 修复：杀掉占用 CPU 过高的查询
-- 先查看查询信息
SELECT query_id, query, elapsed
FROM system.processes
ORDER BY elapsed DESC;

-- 然后杀掉特定查询
-- KILL QUERY WHERE query_id = 'query_id';

-- 修复：调整后台任务线程数
-- 在 config.xml 中:
-- <background_pool_size>16</background_pool_size>
-- <background_merges_mutations_concurrency_ratio>2</background_merges_mutations_concurrency_ratio>
-- <background_schedule_pool_size>128</background_schedule_pool_size>
-- <background_fetches_pool_size>8</background_fetches_pool_size>
-- <background_message_broker_schedule_pool_size>16</background_message_broker_schedule_pool_size>
-- <background_distributed_schedule_pool_size>16</background_distributed_schedule_pool_size>

-- 修复：启用异步查询队列
-- 在 config.xml 中:
-- <async_server_dns_requests>true</async_server_dns_requests>
-- <async_insert>true</async_insert>

-- 修复：优化查询减少 CPU 使用
-- 1. 使用 PREWHERE 替代 WHERE（提前过滤）
-- 2. 使用低精度聚合函数（uniq -> uniqHLL12）
-- 3. 使用采样减少数据量
-- 4. 使用物化视图预聚合

-- -----------------------------------------------------
-- 2. 内存 OOM
-- -----------------------------------------------------

--
-- 【原理】ClickHouse 的 OOM 分为进程级和查询级。进程级 OOM 指整个 clickhouse-server
-- 进程被系统 OOM Killer 杀死，通常由 max_server_memory_usage 配置不当或内存
-- 泄漏引起。查询级 OOM 指单个查询超过 max_memory_usage 限制，被 ClickHouse
-- 内部机制中断。OOM 的常见原因包括：并发查询过多、聚合中间结果过大、
-- JOIN 的右表过大、未限制的 ORDER BY、高基数 GROUP BY、字符串列无限制等。
--
-- 【场景】
--   - 进程被系统 OOM Killer 杀死（dmesg 可见 "oom-killer"）
--   - 报错 "Memory limit (for query) exceeded"
--   - 报错 "Memory limit (total) exceeded"
--   - 报错 "Cannot allocate memory"
--   - 系统 swap 使用率持续升高
--   - 查询后内存不释放（内存泄漏）
--

-- 诊断：查看当前内存使用分布
-- 【坑】system.memory 表不存在（CH 25.x），内存指标在 system.asynchronous_metrics
SELECT
    metric,
    value,
    description
FROM system.asynchronous_metrics
WHERE metric IN ('OSMemoryTotal', 'OSMemoryAvailable', 'MemoryResident')
ORDER BY metric;

-- 诊断：查看各查询的内存使用
SELECT
    query_id,
    user,
    query,
    elapsed,
    formatReadableSize(memory_usage) AS current_memory,
    formatReadableSize(peak_memory_usage) AS peak_memory,
    formatReadableSize(read_bytes) AS bytes_read,
    read_rows
FROM system.processes
ORDER BY memory_usage DESC
LIMIT 20;

-- 诊断：查看内存相关的异步指标
SELECT
    name,
    value,
    description
FROM system.asynchronous_metrics
WHERE name LIKE '%Memory%'
   OR name LIKE '%MMap%'
ORDER BY name;

-- 诊断：查看系统 OOM 事件
-- 在 shell 中执行:
-- dmesg | grep -i oom | tail -20
-- journalctl -u clickhouse-server | grep -i "out of memory"

-- 修复：设置服务器总内存限制
-- 在 config.xml 中:
-- <max_server_memory_usage>0</max_server_memory_usage>  -- 0 = 自动计算
-- <max_server_memory_usage_to_ram_ratio>0.9</max_server_memory_usage_to_ram_ratio>

-- 修复：设置查询内存限制
SET max_memory_usage = 8000000000;  -- 8GB
SET max_memory_usage_for_user = 16000000000;  -- 16GB per user
SET max_memory_usage_for_all_queries = 32000000000;  -- 32GB total

-- 修复：启用磁盘溢出
SET max_bytes_before_external_group_by = 4000000000;  -- 4GB 后使用磁盘
SET max_bytes_before_external_sort = 4000000000;       -- 4GB 后使用磁盘

-- 修复：使用内存追踪定位泄漏
-- 如果怀疑内存泄漏，启用内存追踪:
-- SET memory_profiler_step = 1048576;  -- 每 1MB 采样一次
-- SET memory_tracker_fault_probability = 0;  -- 禁用 OOM 模拟

-- 修复：限制不同操作的缓冲区大小
SET max_block_size = 65536;
SET max_insert_block_size = 1048576;
-- max_join_block_size 不是 CH 25.x 内置设置（报 UNKNOWN_SETTING），JOIN 内存上限用 max_bytes_in_join：
SET max_bytes_in_join = 104857600;  -- 100MB

-- 修复：使用低内存消耗的聚合函数
-- 使用 uniqCombined 替代 uniqExact（精度换内存）
-- 使用 quantileTDigest 替代 quantileExact
-- 使用 sumMap 替代 groupArray

-- -----------------------------------------------------
-- 3. 磁盘 IO 高
-- -----------------------------------------------------

--
-- 【原理】ClickHouse 的磁盘 IO 主要由以下操作引起：数据写入（INSERT）、
-- 后台合并（MERGE）、数据读取（SELECT 扫表）、磁盘排序/聚合溢出、数据备份
-- 等。磁盘 IO 过高通常表现为 IOPS 或吞吐量达到磁盘上限，导致查询延迟增加、
-- 写入阻塞、合并任务积压。
--
-- 【场景】
--   - iostat 显示磁盘利用率持续 100%
--   - 写入延迟增加（INSERT 变慢）
--   - 合并任务积压（parts 数量增加）
--   - 查询延迟增加（IO 等待变高）
--   - 系统 iowait 持续升高
--   - 磁盘队列深度过大
--

-- 诊断：查看磁盘 IO 事件
SELECT
    event,
    value,
    description
FROM system.events
WHERE event LIKE '%IO%'
   OR event LIKE '%Read%'
   OR event LIKE '%Write%'
   OR event LIKE '%File%'
ORDER BY event;

-- 诊断：查看各表的磁盘读取量
SELECT
    database,
    table,
    formatReadableSize(sum(data_compressed_bytes)) AS compressed,
    formatReadableSize(sum(data_uncompressed_bytes)) AS uncompressed,
    round(sum(data_uncompressed_bytes) / sum(data_compressed_bytes), 2) AS ratio
FROM system.columns
WHERE database NOT IN ('system', 'INFORMATION_SCHEMA')
GROUP BY database, table
ORDER BY sum(data_compressed_bytes) DESC;

-- 诊断：查看后台合并任务的 IO 压力
SELECT
    database,
    table,
    count() AS merge_count,
    sum(rows_read) AS total_rows_read,
    sum(rows_written) AS total_rows_written,
    formatReadableSize(sum(bytes_read_uncompressed)) AS bytes_read,
    formatReadableSize(sum(bytes_written_uncompressed)) AS bytes_written
FROM system.merges
WHERE database NOT IN ('system')
GROUP BY database, table
ORDER BY merge_count DESC;

-- 修复：限制后台合并速度
-- 在 config.xml 中:
-- <merge_tree>
--     <max_bytes_to_merge_at_max_space_in_pool>10737418240</max_bytes_to_merge_at_max_space_in_pool>
--     <max_bytes_to_merge_at_min_space_in_pool>1048576</max_bytes_to_merge_at_min_space_in_pool>
--     <merge_max_block_size>8192</merge_max_block_size>
--     <merge_selecting_sleep_ms>5000</merge_selecting_sleep_ms>
-- </merge_tree>

-- 修复：使用 SSD 加速 IO
-- 将数据目录和日志目录放在不同磁盘上

-- 修复：使用 RAID 0 或 RAID 10 提升 IOPS

-- 修复：调整读取缓冲区大小
SET max_read_buffer_size = 1048576;  -- 1MB
SET min_bytes_to_use_direct_io = 0;  -- 禁用 Direct IO

-- 修复：使用压缩减少 IO 量
-- 选择更高的压缩比（如 ZSTD 替代 LZ4）
-- ALTER TABLE table MODIFY COLUMN column CODEC(ZSTD(5))

-- 修复：控制写入频率
-- 使用批量写入减少 IO 次数
-- 使用 Buffer 表缓冲写入

-- 修复：使用异步 IO 减少 IO 等待
-- 在 config.xml 中:
-- <async_insert>1</async_insert>
-- <async_insert_max_data_size>1048576</async_insert_max_data_size>

-- -----------------------------------------------------
-- 4. 网络延迟
-- -----------------------------------------------------

--
-- 【原理】ClickHouse 集群中节点间网络延迟会影响：跨节点查询性能（分布式表
-- 查询）、副本间数据同步（复制延迟）、集群间（跨 DC）查询、数据迁移等。
-- 网络延迟过高通常由网络带宽不足、网络链路拥塞、跨数据中心部署、DNS 解析
-- 慢、TCP 连接数过多引起。
--
-- 【场景】
--   - 分布式查询延迟高（subquery 等待时间长）
--   - 副本间同步延迟大（absolute_delay 高）
--   - 跨集群查询超时
--   - 数据迁移速度慢
--   - 报错 "All connection tries failed"
--   - 报错 "Timeout: connection lost"
--

-- 诊断：检查网络相关事件
SELECT
    event,
    value,
    description
FROM system.events
WHERE event LIKE '%Network%'
   OR event LIKE '%TCP%'
   OR event LIKE '%DNS%'
   OR event LIKE '%Remote%'
ORDER BY event;

-- 诊断：检查分布式查询性能
-- 【坑】演示集群禁用了 system.query_log，改用 system.query_thread_log（线程级）
SELECT
    query_id,
    query,
    formatReadableSize(read_bytes) AS bytes_read,
    formatReadableSize(peak_memory_usage) AS memory,
    read_rows,
    query_duration_ms AS elapsed_ms,
    initial_query_id,
    initial_user
FROM system.query_thread_log
WHERE event_time > now() - INTERVAL 1 DAY
  AND initial_query_id != '' AND initial_query_id != query_id
ORDER BY elapsed_ms DESC
LIMIT 20;

-- 诊断：检查副本间网络延迟
-- 使用 ICMP ping 测试
-- 在 shell 中执行:
-- ping -c 10 replica_host
-- mtr replica_host

-- 修复：优化网络配置
-- 在 config.xml 中:
-- <max_network_bandwidth>104857600</max_network_bandwidth>  -- 100 MB/s
-- <max_network_bytes>1099511627776</max_network_bytes>  -- 1 TB
-- <max_connections>1024</max_connections>

-- 修复：使用压缩减少网络传输
SET network_compression_method = 'lz4';
SET network_zstd_compression_level = 3;

-- 修复：使用分布式查询优化
-- 1. 使用 GLOBAL IN 减少子查询的跨节点传输
-- 2. 使用偏好本地查询
-- 3. 使用物化视图在本地完成聚合

-- 修复：优化集群拓扑
-- 1. 将频繁 JOIN 的表放在同一节点
-- 2. 使用本地表替代分布式表（能本地就不远端）
-- 3. 使用 prefer_localhost_replica = 1

-- 修复：设置 TCP 参数优化网络
-- 在 shell 中执行:
-- sysctl -w net.ipv4.tcp_keepalive_time=60
-- sysctl -w net.ipv4.tcp_keepalive_intvl=10
-- sysctl -w net.ipv4.tcp_keepalive_probes=6
-- sysctl -w net.core.somaxconn=65535

-- -----------------------------------------------------
-- 清理测试环境
-- -----------------------------------------------------

DROP DATABASE IF EXISTS troubleshooting_test;

-- =====================================================
-- 附：资源问题排查速查表
-- =====================================================
--
-- 症状                    | 诊断命令                  | 修复方法
-- ------------------------|---------------------------|---------------------------
-- CPU 100%                | system.processes          | 限制并发 / 优化查询 / 杀查询
-- 内存 OOM                | system.memory / dmesg     | 设置内存限制 / 启用磁盘溢出
-- 磁盘 IO 高              | system.events (IO)        | 限速 / 换 SSD / 提高压缩
-- 网络延迟高              | system.events (Network)   | 压缩传输 / 优化集群拓扑
-- 后台任务积压            | system.merges             | 调整合并线程 / 限速写入
-- 连接数满                | system.processes          | 调整 max_concurrent_queries
--
-- =====================================================