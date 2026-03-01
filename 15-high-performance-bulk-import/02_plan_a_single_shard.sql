-- ========================================
-- 方案A：单分片极致优化方案
-- ========================================
-- 目标：8-12分钟完成150亿行数据导入
-- 架构：保持现有单分片双副本架构
-- 成本：$1,460/月（经济版）或$830/月（超经济版）
-- ========================================

-- ========================================
-- 1. 方案概述
-- ========================================
/*
【核心策略】
1. 多客户端并行导入（8-16个客户端同时导入不同文件）
2. 最大化插入线程（max_insert_threads = 24，利用32核CPU的75%）
3. 异步复制（insert_quorum = 1，降低副本同步延迟）
4. 批量参数优化（block_size = 1M行）
5. GCS直接读取（避免中间存储）

【预期性能】
- 当前：30分钟
- 优化后：8-12分钟
- 提升幅度：3-4倍

【适用场景】
- 预算控制在$1,500/月以内
- 可接受8-12分钟导入时间
- 不希望改变现有架构
- 快速上线需求
*/

-- ========================================
-- 2. 环境准备
-- ========================================

-- 2.1 检查集群状态
SELECT 
    cluster,
    shard_num,
    replica_num,
    host_name,
    host_address
FROM system.clusters
WHERE cluster = 'treasurycluster';

-- 2.2 检查当前配置
SELECT 
    name,
    value,
    description
FROM system.settings
WHERE name IN (
    'max_insert_threads',
    'max_insert_block_size',
    'min_insert_block_size_rows',
    'insert_quorum',
    'max_memory_usage',
    'max_threads'
);

-- 2.3 检查资源使用情况
SELECT 
    metric,
    value,
    description
FROM system.metrics
WHERE metric IN (
    'TotalThreads',
    'TotalQueries',
    'MemoryTracking',
    'CPUUsage'
);

-- ========================================
-- 3. 优化参数配置
-- ========================================

-- 3.1 会话级参数设置（推荐用于测试）
-- 设置高性能导入参数
SET max_insert_threads = 24;                      -- 并行插入线程（32核的75%）
SET max_insert_block_size = 1048576;              -- 1M行块
SET min_insert_block_size_rows = 1000000;         -- 最小批量1M行
SET min_insert_block_size_bytes = 1073741824;     -- 最小批量1GB
SET insert_quorum = 1;                            -- 异步复制（只等1副本）
SET insert_quorum_timeout = 300000;               -- 超时5分钟
SET max_memory_usage = 240000000000;              -- 内存限制240GB（256GB的93%）
SET input_format_parallel_parsing = 1;            -- 并行解析Parquet
SET input_format_parquet_max_block_size = 1000000;
SET max_threads = 32;                             -- 最大线程数
SET max_execution_time = 1800;                    -- 最大执行时间30分钟

-- 3.2 检查参数设置
SELECT 
    name,
    value,
    description
FROM system.settings
WHERE name IN (
    'max_insert_threads',
    'max_insert_block_size',
    'min_insert_block_size_rows',
    'insert_quorum',
    'max_memory_usage',
    'input_format_parallel_parsing'
);

-- ========================================
-- 4. 创建目标表
-- ========================================

-- 4.1 创建数据库
CREATE DATABASE IF NOT EXISTS bulk_import_plan_a;

-- 4.2 创建目标表（示例：150亿行，90列）
CREATE TABLE IF NOT EXISTS bulk_import_plan_a.target_table (
    -- 假设您的表有90列，这里用简化示例
    event_id String,
    event_type String,
    event_time DateTime,
    user_id UInt64,
    -- ... 其他86列 ...
    col87 String,
    col88 Float64,
    col89 UInt64,
    col90 DateTime
) ENGINE = ReplicatedMergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_time, user_id, event_id)
SETTINGS 
    index_granularity = 8192,
    min_bytes_for_wide_part = '10M',
    min_rows_for_wide_part = '100000';

-- ========================================
-- 5. 并行导入策略
-- ========================================

-- 5.1 策略1：单文件高性能导入
-- 适用于：少量大文件
INSERT INTO bulk_import_plan_a.target_table
SETTINGS 
    max_insert_threads = 24,
    max_insert_block_size = 1048576,
    min_insert_block_size_rows = 1000000,
    insert_quorum = 1,
    input_format_parallel_parsing = 1
SELECT * FROM gcs(
    'https://storage.googleapis.com/your-bucket/path/to/large_file.parquet',
    'Parquet'
    -- 可选：指定schema以提高性能
    -- 'event_id String, event_type String, ...'
);

-- 5.2 策略2：多文件并行导入（推荐）
-- 适用于：多个中小文件
-- ClickHouse会自动并行读取匹配的文件

-- 方式A：使用glob模式匹配所有文件
INSERT INTO bulk_import_plan_a.target_table
SETTINGS 
    max_insert_threads = 24,
    max_insert_block_size = 1048576,
    insert_quorum = 1
SELECT * FROM gcs(
    'https://storage.googleapis.com/your-bucket/data/**/*.parquet',  -- 递归匹配所有文件
    'Parquet'
);

-- 方式B：指定多个文件路径
INSERT INTO bulk_import_plan_a.target_table
SETTINGS max_insert_threads = 24
SELECT * FROM gcs(
    'https://storage.googleapis.com/your-bucket/data/{file1,file2,file3}.parquet',
    'Parquet'
);

-- 5.3 策略3：按分区并行导入（最高性能）
-- 假设数据按日期分区存储
-- 优点：每个分区独立导入，互不干扰

-- 导入2024年1月数据
INSERT INTO bulk_import_plan_a.target_table
SETTINGS max_insert_threads = 24
SELECT * FROM gcs(
    'https://storage.googleapis.com/your-bucket/data/year=2024/month=01/*.parquet',
    'Parquet'
);

-- 导入2024年2月数据
INSERT INTO bulk_import_plan_a.target_table
SETTINGS max_insert_threads = 24
SELECT * FROM gcs(
    'https://storage.googleapis.com/your-bucket/data/year=2024/month=02/*.parquet',
    'Parquet'
);

-- 导入2024年3月数据
INSERT INTO bulk_import_plan_a.target_table
SETTINGS max_insert_threads = 24
SELECT * FROM gcs(
    'https://storage.googleapis.com/your-bucket/data/year=2024/month=03/*.parquet',
    'Parquet'
);

-- ========================================
-- 6. 多客户端并行导入脚本
-- ========================================
/*
【实施方式】
在跳板机上启动多个clickhouse-client进程，同时导入不同的文件

示例脚本（Bash）：
#!/bin/bash

# 定义要导入的文件列表
files=(
    "gs://your-bucket/data/file_001.parquet"
    "gs://your-bucket/data/file_002.parquet"
    "gs://your-bucket/data/file_003.parquet"
    # ... 更多文件
)

# 启动并行导入（假设8个并发）
for i in {0..7}; do
    (
        for file in "${files[@]:$((i*${#files[@]}/8)):$((${#files[@]}/8))}"; do
            clickhouse-client --query="
                INSERT INTO bulk_import_plan_a.target_table
                SETTINGS max_insert_threads = 3, max_insert_block_size = 1048576
                SELECT * FROM gcs('$file', 'Parquet')
            "
        done
    ) &
done

wait

详细脚本见：scripts/parallel_import_plan_a.sh
*/

-- ========================================
-- 7. 性能监控
-- ========================================

-- 7.1 监控当前导入进度
SELECT 
    query_id,
    query,
    read_rows,
    written_rows,
    memory_usage,
    query_duration_ms,
    formatReadableSize(memory_usage) as memory
FROM system.processes
WHERE query LIKE '%INSERT%'
ORDER BY query_duration_ms DESC;

-- 7.2 监控历史导入性能
SELECT 
    event_date,
    count() as insert_count,
    sum(written_rows) as total_rows,
    formatReadableSize(sum(written_bytes)) as total_size,
    avg(query_duration_ms) / 1000 as avg_duration_sec,
    sum(written_rows) / (avg(query_duration_ms) / 1000) as rows_per_sec
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query LIKE '%INSERT INTO bulk_import_plan_a%'
  AND event_date >= today() - 1
GROUP BY event_date
ORDER BY event_date DESC;

-- 7.3 监控资源使用
SELECT 
    metric,
    value,
    description
FROM system.metrics
WHERE metric IN (
    'MemoryTracking',
    'TotalThreads',
    'TotalQueries',
    'CPUUsage'
);

-- 7.4 监控磁盘IO
SELECT 
    filesystem,
    sum(read_bytes) as read_bytes,
    sum(write_bytes) as write_bytes,
    formatReadableSize(sum(read_bytes)) as read_size,
    formatReadableSize(sum(write_bytes)) as write_size
FROM system.filesystem
GROUP BY filesystem;

-- ========================================
-- 8. 验证导入结果
-- ========================================

-- 8.1 检查总行数
SELECT count() as total_rows
FROM bulk_import_plan_a.target_table;

-- 8.2 检查分区信息
SELECT 
    partition,
    count() as parts,
    sum(rows) as rows,
    formatReadableSize(sum(data_compressed_bytes)) as compressed_size,
    formatReadableSize(sum(data_uncompressed_bytes)) as uncompressed_size
FROM system.parts
WHERE database = 'bulk_import_plan_a' 
  AND table = 'target_table'
  AND active = 1
GROUP BY partition
ORDER BY partition;

-- 8.3 检查数据完整性
SELECT 
    min(event_time) as min_time,
    max(event_time) as max_time,
    uniqExact(user_id) as unique_users,
    uniqExact(event_id) as unique_events
FROM bulk_import_plan_a.target_table;

-- 8.4 检查副本状态
SELECT 
    database,
    table,
    engine,
    replica_name,
    replica_path,
    total_replicas,
    active_replicas
FROM system.replicas
WHERE database = 'bulk_import_plan_a';

-- ========================================
-- 9. 故障恢复
-- ========================================

-- 9.1 如果导入失败，检查错误日志
SELECT 
    event_time,
    query,
    exception
FROM system.query_log
WHERE type = 'ExceptionWhileProcessing'
  AND query LIKE '%INSERT%'
ORDER BY event_time DESC
LIMIT 10;

-- 9.2 清理失败的parts
OPTIMIZE TABLE bulk_import_plan_a.target_table FINAL;

-- 9.3 检查并修复损坏的数据
CHECK TABLE bulk_import_plan_a.target_table;

-- ========================================
-- 10. 性能优化建议
-- ========================================

-- 建议1：根据实际数据调整max_insert_threads
-- CPU使用率低：增加max_insert_threads
-- CPU使用率高：减少max_insert_threads

-- 查看CPU使用情况
SELECT 
    metric,
    value
FROM system.metrics
WHERE metric = 'CPUUsage';

-- 建议2：调整批量大小
-- 内存充足：增大max_insert_block_size
-- 内存不足：减小max_insert_block_size

-- 查看内存使用情况
SELECT 
    metric,
    value,
    formatReadableSize(value) as size
FROM system.metrics
WHERE metric = 'MemoryTracking';

-- 建议3：使用异步复制提高速度
-- 生产环境：insert_quorum = 2（等待2副本）
-- 导入时：insert_quorum = 1（异步复制）
SET insert_quorum = 1;

-- ========================================
-- 11. 清理示例
-- ========================================

-- 删除测试数据
DROP TABLE IF EXISTS bulk_import_plan_a.target_table;
DROP DATABASE IF EXISTS bulk_import_plan_a;

-- ========================================
-- 12. 完整导入示例
-- ========================================

-- 完整的生产级导入脚本
-- 步骤1：设置参数
SET max_insert_threads = 24;
SET max_insert_block_size = 1048576;
SET min_insert_block_size_rows = 1000000;
SET insert_quorum = 1;
SET max_memory_usage = 240000000000;
SET input_format_parallel_parsing = 1;

-- 步骤2：执行导入
INSERT INTO bulk_import_plan_a.target_table
SELECT * FROM gcs(
    'https://storage.googleapis.com/your-bucket/data/**/*.parquet',
    'Parquet'
);

-- 步骤3：验证结果
SELECT 
    count() as total_rows,
    formatReadableSize(sum(data_compressed_bytes)) as size
FROM system.parts
WHERE database = 'bulk_import_plan_a' 
  AND table = 'target_table'
  AND active = 1;
