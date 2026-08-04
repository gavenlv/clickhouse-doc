-- ============================================================================
-- 05 - 容量规划（新增专题）
-- ============================================================================
-- 场景: 数据量增长预测、磁盘空间规划、内存和CPU规划、分片数规划、容量预警
-- 集群: treasurycluster (2副本)
-- 耗时: 15-20分钟
-- ============================================================================

DROP DATABASE IF EXISTS ops_test;
CREATE DATABASE ops_test;
USE ops_test;

-- ============================================================================
-- 【原理】容量规划方法论
--
-- 容量规划的核心是回答三个问题：
--   1. 现在用了多少？— 当前资源使用量
--   2. 增长有多快？   — 历史增长趋势
--   3. 未来要多少？   — 业务增长预测
--
-- 规划公式：
--   总容量 = 当前数据量 × (1 + 增长率)^周期数 × 副本数 × 安全系数(1.3~1.5)
--
-- 分层规划：
--   ┌─────────────────────────────────────────────────────────────────────────┐
--   │  Layer 1: 存储层 — 磁盘容量、对象存储、分层存储策略                      │
--   │  Layer 2: 计算层 — CPU 核数、内存大小、并发查询数                       │
--   │  Layer 3: 网络层 — 带宽、连接数、数据复制流量                           │
--   │  Layer 4: 元数据层 — ClickHouse Keeper 节点数、分区数、Parts 数         │
--   └─────────────────────────────────────────────────────────────────────────┘
-- ============================================================================

-- ============================================================================
-- 【对比】容量评估方法对比
--
-- ┌──────────────────┬──────────────────┬──────────────────┬──────────────────┐
-- │     方法          │     精度          │     复杂度        │     适用场景     │
-- ├──────────────────┼──────────────────┼──────────────────┼──────────────────┤
-- │ 线性回归预测      │ 中等              │ 低               │ 短期预测(1-3月)  │
-- ├──────────────────┼──────────────────┼──────────────────┼──────────────────┤
-- │ 时间序列分析      │ 较高              │ 中               │ 中期预测(3-6月)  │
-- ├──────────────────┼──────────────────┼──────────────────┼──────────────────┤
-- │ 业务模型驱动      │ 高                │ 高               │ 长期预测(6-12月) │
-- ├──────────────────┼──────────────────┼──────────────────┼──────────────────┤
-- │ 经验公式估算      │ 低                │ 极低             │ 快速估算         │
-- └──────────────────┴──────────────────┴──────────────────┴──────────────────┘
-- ============================================================================

-- ==========================================
-- 1. 磁盘容量规划
-- ==========================================

-- 1.1 当前存储概况
-- 【场景】快速了解集群总数据量、压缩比、副本数
-- 【坑】total_bytes 在 system.tables 中是压缩后的大小，原始数据需要根据压缩比估算
SELECT
    'Cluster Storage Overview' AS report_name,
    now() AS report_time,
    count(DISTINCT database) AS database_count,
    count(DISTINCT concat(database, '.', table)) AS table_count,
    formatReadableSize(sum(total_bytes)) AS total_compressed_size,
    formatReadableSize(sum(total_bytes_uncompressed)) AS total_uncompressed_size,
    CASE
        WHEN sum(total_bytes) > 0
        THEN round(sum(total_bytes_uncompressed) / sum(total_bytes), 2)
        ELSE 0
    END AS compression_ratio,
    sum(rows) AS total_rows
FROM (
    SELECT
        database,
        name AS table,
        total_bytes,
        total_bytes_uncompressed,
        total_rows AS rows
    FROM system.tables
    WHERE database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
      AND engine NOT LIKE '%View%'
      AND engine NOT LIKE '%Dictionary%'
);

-- 1.2 按数据库统计存储
-- 【场景】了解各数据库的存储占比，便于成本分摊
SELECT
    database,
    count() AS table_count,
    formatReadableSize(sum(total_bytes)) AS compressed_size,
    formatReadableSize(sum(total_bytes_uncompressed)) AS uncompressed_size,
    round(sum(total_bytes_uncompressed) / greatest(sum(total_bytes), 1), 2) AS compression_ratio,
    sum(rows) AS total_rows,
    round(sum(total_bytes) * 100.0 / greatest(sum(sum(total_bytes)) OVER (), 1), 2) AS storage_percent
FROM system.tables
WHERE database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
  AND engine NOT LIKE '%View%'
  AND engine NOT LIKE '%Dictionary%'
GROUP BY database
ORDER BY sum(total_bytes) DESC;

-- 1.3 数据增长趋势分析
-- 【场景】分析近 30 天的数据增长趋势，为容量规划提供依据
-- 【原理】通过 system.parts 的 modification_time 近似估算每日数据增量
-- 【坑】modification_time 不是精确的写入时间，合并操作会更新，建议使用写入时间戳字段
SELECT
    toDate(modification_time) AS day,
    formatReadableSize(sum(bytes_on_disk)) AS bytes_added_compressed,
    formatReadableSize(sum(bytes_uncompressed)) AS bytes_added_uncompressed,
    sum(rows) AS rows_added,
    round(sum(bytes_on_disk) / greatest(sum(rows), 1), 2) AS avg_bytes_per_row
FROM system.parts
WHERE active = 1
  AND database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
  AND modification_time >= now() - INTERVAL 30 DAY
GROUP BY day
ORDER BY day;

-- 1.4 数据增长预测（线性回归）
-- 【场景】基于历史数据预测未来 3 个月的存储需求
-- 【原理】使用简单线性回归：y = ax + b，其中 x 是天数，y 是累计数据量
WITH daily_growth AS (
    SELECT
        toDate(modification_time) AS day,
        sum(bytes_on_disk) AS daily_bytes
    FROM system.parts
    WHERE active = 1
      AND database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
      AND modification_time >= now() - INTERVAL 90 DAY
    GROUP BY day
),
cumulative AS (
    SELECT
        day,
        daily_bytes,
        sum(daily_bytes) OVER (ORDER BY day) AS cumulative_bytes,
        row_number() OVER (ORDER BY day) AS x
    FROM daily_growth
),
stats AS (
    SELECT
        count(*) AS n,
        sum(x) AS sum_x,
        sum(cumulative_bytes) AS sum_y,
        sum(x * cumulative_bytes) AS sum_xy,
        sum(x * x) AS sum_xx
    FROM cumulative
)
SELECT
    'Growth Prediction' AS report_name,
    formatReadableSize(
        (SELECT max(cumulative_bytes) FROM cumulative)
    ) AS current_size,
    formatReadableSize(
        (SELECT max(cumulative_bytes) FROM cumulative) * 1.3
    ) AS estimated_3month_with_buffer,
    formatReadableSize(
        (SELECT
            (n * sum_xy - sum_x * sum_y) / (n * sum_xx - sum_x * sum_x) * (max_x + 90) +
            (sum_y - (n * sum_xy - sum_x * sum_y) / (n * sum_xx - sum_x * sum_x) * sum_x) / n
        FROM stats, (SELECT max(x) + 90 AS max_x FROM cumulative))
    ) AS predicted_90day_size,
    round(
        (SELECT
            ((n * sum_xy - sum_x * sum_y) / (n * sum_xx - sum_x * sum_x)) * 86400
        FROM stats)
    ) AS daily_growth_bytes_per_day,
    round(
        (SELECT
            ((n * sum_xy - sum_x * sum_y) / (n * sum_xx - sum_x * sum_x)) * 86400 / 1073741824
        FROM stats), 2
    ) AS daily_growth_gb_per_day;

-- 1.5 磁盘空间预测
-- 【场景】预测磁盘何时用尽
-- 【坑】预测结果仅供参考，实际使用时需考虑业务增长、促销活动等因素
WITH daily_growth AS (
    SELECT
        toDate(modification_time) AS day,
        sum(bytes_on_disk) AS daily_bytes
    FROM system.parts
    WHERE active = 1
      AND database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
      AND modification_time >= now() - INTERVAL 90 DAY
    GROUP BY day
),
cumulative AS (
    SELECT
        day,
        daily_bytes,
        sum(daily_bytes) OVER (ORDER BY day) AS cumulative_bytes,
        row_number() OVER (ORDER BY day) AS x
    FROM daily_growth
),
stats AS (
    SELECT
        count(*) AS n,
        sum(x) AS sum_x,
        sum(cumulative_bytes) AS sum_y,
        sum(x * cumulative_bytes) AS sum_xy,
        sum(x * x) AS sum_xx
    FROM cumulative
),
regression AS (
    SELECT
        (n * sum_xy - sum_x * sum_y) / (n * sum_xx - sum_x * sum_x) AS slope,
        (sum_y - ((n * sum_xy - sum_x * sum_y) / (n * sum_xx - sum_x * sum_x)) * sum_x) / n AS intercept
    FROM stats
)
SELECT
    'Disk Capacity Prediction' AS report_name,
    formatReadableSize(
        (SELECT min(total_space) FROM system.disks)
    ) AS min_disk_total,
    formatReadableSize(
        (SELECT min(free_space) FROM system.disks)
    ) AS min_disk_free,
    round(
        (SELECT min(free_space * 100.0 / total_space) FROM system.disks), 2
    ) AS min_free_percent,
    CASE
        WHEN (SELECT slope FROM regression) > 0
        THEN round(
            ((SELECT min(total_space) * 0.8 FROM system.disks) -
             (SELECT max(cumulative_bytes) FROM cumulative)) /
            (SELECT slope FROM regression)
        )
        ELSE NULL
    END AS days_until_80pct,
    CASE
        WHEN (SELECT slope FROM regression) > 0
        THEN round(
            ((SELECT min(total_space) FROM system.disks) -
             (SELECT max(cumulative_bytes) FROM cumulative)) /
            (SELECT slope FROM regression)
        )
        ELSE NULL
    END AS days_until_full
FROM regression, cumulative
LIMIT 1;

-- 1.6 压缩率分析
-- 【场景】压缩率影响存储效率，低压缩率的表需要关注
-- 【对比】ZSTD 通常比 LZ4 压缩率高 30-50%，但 CPU 消耗也更高
SELECT
    database,
    table,
    formatReadableSize(sum(bytes_on_disk)) AS compressed_size,
    formatReadableSize(sum(bytes_uncompressed)) AS uncompressed_size,
    round(sum(bytes_uncompressed) / greatest(sum(bytes_on_disk), 1), 2) AS compression_ratio,
    CASE
        WHEN sum(bytes_uncompressed) / greatest(sum(bytes_on_disk), 1) < 2 THEN '低(需优化)'
        WHEN sum(bytes_uncompressed) / greatest(sum(bytes_on_disk), 1) < 5 THEN '中等'
        ELSE '高'
    END AS compression_efficiency
FROM system.parts
WHERE active = 1
  AND database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
GROUP BY database, table
ORDER BY compression_ratio
LIMIT 20;

-- ==========================================
-- 2. 内存容量规划
-- ==========================================

-- 2.1 内存使用概况
-- 【场景】了解集群当前内存使用情况，评估是否需要扩容
SELECT
    'Memory Overview' AS report_name,
    formatReadableSize(
        (SELECT value FROM system.asynchronous_metrics WHERE metric = 'OSMemoryTotal')
    ) AS total_memory,
    formatReadableSize(
        (SELECT value FROM system.asynchronous_metrics WHERE metric = 'OSMemoryActive')
    ) AS active_memory,
    round(
        (SELECT value FROM system.asynchronous_metrics WHERE metric = 'OSMemoryActive') * 100.0 /
        (SELECT value FROM system.asynchronous_metrics WHERE metric = 'OSMemoryTotal'), 2
    ) AS memory_usage_percent,
    formatReadableSize(
        (SELECT value FROM system.asynchronous_metrics WHERE metric = 'MemoryResident')
    ) AS clickhouse_memory;

-- 2.2 查询内存消耗分析
-- 【场景】分析查询的内存消耗模式，为内存规划提供依据
-- 【坑】峰值内存使用可能远高于平均值，建议按 P99 规划
-- 【注意】使用 system.query_thread_log 替代 system.query_log
SET log_query_threads = 1;

SELECT
    'Query Memory Stats (Last 7 Days)' AS report_name,
    formatReadableSize(quantile(0.5)(memory_usage)) AS p50_memory,
    formatReadableSize(quantile(0.9)(memory_usage)) AS p90_memory,
    formatReadableSize(quantile(0.95)(memory_usage)) AS p95_memory,
    formatReadableSize(quantile(0.99)(memory_usage)) AS p99_memory,
    formatReadableSize(max(memory_usage)) AS peak_memory,
    count() AS total_queries,
    countIf(memory_usage > 1073741824) AS queries_over_1gb,
    countIf(memory_usage > 10737418240) AS queries_over_10gb
FROM system.query_thread_log
WHERE type = 'QueryFinish'
  AND event_time >= now() - INTERVAL 7 DAY
  AND memory_usage > 0;

-- 2.3 并发查询规划
-- 【场景】评估集群的并发处理能力
-- 【原理】并发能力 = (内存总量 - 系统预留) / 平均查询内存
SELECT
    'Concurrency Planning' AS report_name,
    formatReadableSize(
        (SELECT value FROM system.metrics WHERE metric = 'MemoryTracking')
    ) AS current_query_memory,
    (SELECT value FROM system.metrics WHERE metric = 'Query') AS current_queries,
    (SELECT value FROM system.metrics WHERE metric = 'MaxConcurrentQueries') AS max_concurrent_queries,
    formatReadableSize(
        (SELECT value FROM system.metrics WHERE metric = 'MemoryTracking') /
        greatest((SELECT value FROM system.metrics WHERE metric = 'Query'), 1)
    ) AS avg_memory_per_query,
    formatReadableSize(
        (SELECT value FROM system.asynchronous_metrics WHERE metric = 'OSMemoryTotal') * 0.8
    ) AS available_for_queries;

-- 2.4 内存规划建议
SELECT '===== 内存规划建议 =====' AS memory_advice;

SELECT '1. 内存与数据量比例: 1GB 内存 : 10-50GB 压缩数据'
UNION ALL
SELECT '2. max_memory_usage: 建议设为物理内存的 60-80%'
UNION ALL
SELECT '3. 大查询限制: 使用 max_memory_usage_for_user 限制单个用户'
UNION ALL
SELECT '4. 系统预留: 预留 20% 内存给 OS 和后台任务'
UNION ALL
SELECT '5. 查询并发: 并发数 = 可用内存 / 平均查询内存消耗';

-- ==========================================
-- 3. CPU 容量规划
-- ==========================================

-- 3.1 CPU 使用分析
-- 【场景】了解 CPU 使用模式，规划 CPU 资源
-- 【坑】CPU 使用率在合并操作期间可能飙升，需要区分查询和合并的 CPU 消耗
SELECT
    'CPU Stats' AS report_name,
    (SELECT avg(value) FROM system.asynchronous_metrics WHERE metric = 'OSCPUVirtualTimeMicroseconds') AS avg_cpu,
    (SELECT max(value) FROM system.asynchronous_metrics WHERE metric = 'OSCPUVirtualTimeMicroseconds') AS peak_cpu,
    (
        SELECT count() FROM system.processes
        WHERE elapsed > 60
    ) AS long_running_queries,
    (
        SELECT count() FROM system.merges
    ) AS active_merges,
    (
        SELECT count() FROM system.mutations
        WHERE is_done = 0
    ) AS active_mutations;

-- 3.2 CPU 规划建议
SELECT '===== CPU 规划建议 =====' AS cpu_advice;

SELECT '1. CPU 核数与磁盘数比例: 1:2 或 1:4'
UNION ALL
SELECT '2. 合并线程数: 建议设为 CPU 核数的一半'
UNION ALL
SELECT '3. 并发查询数: 建议不超过 CPU 核数的 2 倍'
UNION ALL
SELECT '4. 单节点 QPS 参考: 16 核 ~ 500 QPS, 32 核 ~ 1000 QPS'
UNION ALL
SELECT '5. 压缩算法选择: LZ4 适合 CPU 瓶颈场景, ZSTD 适合存储瓶颈场景';

-- 3.3 QPS 基准估算
SELECT '===== QPS 估算 =====' AS qps_estimation;

SELECT '查询类型: 简单点查 (单行)'
UNION ALL
SELECT '  16 核: ~2000 QPS'
UNION ALL
SELECT '  32 核: ~4000 QPS'
UNION ALL
SELECT '  64 核: ~8000 QPS'
UNION ALL
SELECT ''
UNION ALL
SELECT '查询类型: 聚合查询 (GROUP BY)'
UNION ALL
SELECT '  16 核: ~200 QPS'
UNION ALL
SELECT '  32 核: ~400 QPS'
UNION ALL
SELECT '  64 核: ~800 QPS'
UNION ALL
SELECT ''
UNION ALL
SELECT '查询类型: 复杂查询 (JOIN + 子查询)'
UNION ALL
SELECT '  16 核: ~50 QPS'
UNION ALL
SELECT '  32 核: ~100 QPS'
UNION ALL
SELECT '  64 核: ~200 QPS';

-- ==========================================
-- 4. 集群规模评估公式
-- ==========================================

-- 4.1 分片数规划
-- 【场景】评估集群需要多少分片
-- 【原理】分片数 = ceil(总数据量 / 单分片建议容量)
SELECT '===== 分片数规划公式 =====' AS shard_formula;

SELECT '分片数 = ceil(总数据量 × 副本数 × 1.3 / 单节点建议容量)'
UNION ALL
SELECT ''
UNION ALL
SELECT '参数说明:'
UNION ALL
SELECT '  总数据量: 当前数据量 × (1 + 月增长率)^规划月数'
UNION ALL
SELECT '  副本数: 通常为 2 或 3'
UNION ALL
SELECT '  安全系数: 1.3 (预留 30% 缓冲)'
UNION ALL
SELECT '  单节点建议容量: 10TB (压缩后)'
UNION ALL
SELECT ''
UNION ALL
SELECT '示例:'
UNION ALL
SELECT '  当前数据量: 5TB, 月增长率: 10%, 规划 12 个月'
UNION ALL
SELECT '  副本数: 2, 安全系数: 1.3'
UNION ALL
SELECT '  未来数据量 = 5 × 1.1^12 × 2 × 1.3 = 5 × 3.14 × 2 × 1.3 ≈ 40.8TB'
UNION ALL
SELECT '  分片数 = ceil(40.8 / 10) = 5 分片';

-- 4.2 当前分片数据分布
-- 【场景】检查数据在各分片上的分布是否均匀
-- 【原理】通过 cluster 函数查询所有分片的数据分布
SELECT
    shard_num,
    host_name,
    formatReadableSize(sum(bytes_on_disk)) AS total_size,
    sum(rows) AS total_rows,
    count(DISTINCT concat(database, '.', table)) AS table_count
FROM cluster('treasurycluster', system, parts)
WHERE active = 1
  AND database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
GROUP BY shard_num, host_name
ORDER BY shard_num;

-- 4.3 节点资源规格建议
SELECT '===== 节点规格建议 =====' AS node_spec;

SELECT '小规模 (< 1TB):'
UNION ALL
SELECT '  CPU: 8-16 核'
UNION ALL
SELECT '  内存: 32-64 GB'
UNION ALL
SELECT '  磁盘: 2-4 TB NVMe SSD'
UNION ALL
SELECT '  分片: 1-2'
UNION ALL
SELECT ''
UNION ALL
SELECT '中规模 (1-10TB):'
UNION ALL
SELECT '  CPU: 16-32 核'
UNION ALL
SELECT '  内存: 64-128 GB'
UNION ALL
SELECT '  磁盘: 4-10 TB NVMe SSD'
UNION ALL
SELECT '  分片: 2-4'
UNION ALL
SELECT ''
UNION ALL
SELECT '大规模 (10-100TB):'
UNION ALL
SELECT '  CPU: 32-64 核'
UNION ALL
SELECT '  内存: 128-256 GB'
UNION ALL
SELECT '  磁盘: 10-20 TB NVMe SSD + S3 冷存储'
UNION ALL
SELECT '  分片: 4-16'
UNION ALL
SELECT ''
UNION ALL
SELECT '超大规模 (> 100TB):'
UNION ALL
SELECT '  CPU: 64+ 核'
UNION ALL
SELECT '  内存: 256+ GB'
UNION ALL
SELECT '  磁盘: 分层存储 (SSD 热 + S3 冷)'
UNION ALL
SELECT '  分片: 16+';

-- ==========================================
-- 5. 容量监控和预警
-- ==========================================

-- 5.1 创建容量监控视图
-- 【场景】每日自动采集容量数据，用于趋势分析
CREATE TABLE IF NOT EXISTS ops_test.capacity_metrics (
    collect_time DateTime DEFAULT now(),
    total_data_bytes UInt64,
    total_disk_bytes UInt64,
    free_disk_bytes UInt64,
    total_memory_bytes UInt64,
    active_memory_bytes UInt64,
    total_parts UInt32,
    total_tables UInt32,
    total_databases UInt32,
    compression_ratio Float64,
    daily_growth_bytes UInt64
)
ENGINE = MergeTree()
ORDER BY collect_time;

-- 插入当前容量数据
INSERT INTO ops_test.capacity_metrics
    (total_data_bytes, total_disk_bytes, free_disk_bytes,
     total_memory_bytes, active_memory_bytes, total_parts,
     total_tables, total_databases, compression_ratio, daily_growth_bytes)
SELECT
    (SELECT sum(total_bytes) FROM system.tables WHERE database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')),
    (SELECT sum(total_space) FROM system.disks),
    (SELECT sum(free_space) FROM system.disks),
    (SELECT value FROM system.asynchronous_metrics WHERE metric = 'OSMemoryTotal'),
    (SELECT value FROM system.asynchronous_metrics WHERE metric = 'OSMemoryActive'),
    (SELECT count() FROM system.parts WHERE active = 1 AND database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')),
    (SELECT count() FROM system.tables WHERE database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')),
    (SELECT count(DISTINCT database) FROM system.tables WHERE database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')),
    1.0,
    0;

-- 5.2 容量预警
-- 【场景】根据容量数据生成预警
SELECT
    'Capacity Warning' AS report_name,
    CASE
        WHEN disk_used_percent > 90 THEN 'CRITICAL: 磁盘使用率超过 90%，需要立即扩容'
        WHEN disk_used_percent > 80 THEN 'WARNING: 磁盘使用率超过 80%，建议近期扩容'
        ELSE 'OK: 磁盘容量充足'
    END AS disk_warning,
    CASE
        WHEN memory_used_percent > 95 THEN 'CRITICAL: 内存使用率超过 95%，OOM 风险高'
        WHEN memory_used_percent > 80 THEN 'WARNING: 内存使用率超过 80%'
        ELSE 'OK: 内存容量充足'
    END AS memory_warning,
    CASE
        WHEN parts_count > 100000 THEN 'WARNING: 活跃 Part 数超过 10 万，合并压力大'
        ELSE 'OK: Part 数量正常'
    END AS parts_warning
FROM (
    SELECT
        (sum(total_space) - sum(free_space)) * 100.0 / sum(total_space) AS disk_used_percent,
        (SELECT value FROM system.asynchronous_metrics WHERE metric = 'OSMemoryActive') * 100.0 /
        (SELECT value FROM system.asynchronous_metrics WHERE metric = 'OSMemoryTotal') AS memory_used_percent,
        (SELECT count() FROM system.parts WHERE active = 1 AND database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')) AS parts_count
    FROM system.disks
);

-- 5.3 扩容建议
-- 【场景】根据容量数据生成扩容建议
SELECT '===== 扩容建议 =====' AS scaling_advice;

SELECT '1. 磁盘扩容: 当使用率超过 80% 时提前扩容'
UNION ALL
SELECT '2. 扩容大小: 当前数据量的 1.5~2 倍'
UNION ALL
SELECT '3. 内存扩容: 当内存使用率超过 80% 且查询延迟增加时'
UNION ALL
SELECT '4. 计算扩容: 当 CPU 使用率持续超过 70% 或 QPS 达到上限时'
UNION ALL
SELECT '5. 分片扩容: 当单分片数据量超过 10TB 时'
UNION ALL
SELECT '6. 节点扩容: 当总数据量超过集群承载上限时';

-- ==========================================
-- 清理
-- ==========================================
DROP TABLE IF EXISTS ops_test.capacity_metrics;
DROP DATABASE IF EXISTS ops_test;

-- ============================================================================
-- 最佳实践：
-- 1. 持续监控：建立容量监控 Dashboard，每日跟踪存储和计算资源使用
-- 2. 增长预测：基于历史数据做趋势分析，每季度更新预测模型
-- 3. 预留缓冲：预留 30-50% 的安全余量，应对突发增长
-- 4. 分层存储：热数据 NVMe SSD，温数据 SATA SSD，冷数据 S3
-- 5. 成本优化：ZSTD 比 LZ4 节省 30-50% 空间，合理设置压缩算法
-- 6. 扩容策略：存储扩容增加磁盘，计算扩容增加节点，性能扩容增加分片
-- 7. 分片规划：单分片建议不超过 10TB，单表建议不超过 10000 个分区
-- 8. 内存规划：1GB 内存 : 10-50GB 压缩数据，max_memory_usage 设为物理内存的 60-80%
-- 9. 设置容量告警：80% 预警，90% 紧急，95% 严重
-- 10. 定期生成容量报告，推动业务方合理规划数据生命周期
-- ============================================================================