SELECT
    database,
    table,
    '',
    sum(rows) AS partition_rows,
    sum(bytes_on_disk) AS partition_bytes,
    formatReadableSize(sum(bytes_on_disk)) AS readable_size
FROM system.parts
WHERE active
  AND database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
GROUP BY database, table, partition
ORDER BY partition_bytes DESC
LIMIT 50;

-- 计算分区倾斜度
SELECT
    database,
    table,
    partition_key,
    count() AS partition_count,
    max(partition_rows) AS max_partition_rows,
    min(partition_rows) AS min_partition_rows,
    avg(partition_rows) AS avg_partition_rows,
    max(partition_rows) / greatest(min_partition_rows, 1) AS skew_ratio,
    CASE
        WHEN max(partition_rows) / greatest(min_partition_rows, 1) > 10 THEN 'CRITICAL'
        WHEN max(partition_rows) / greatest(min_partition_rows, 1) > 5 THEN 'WARNING'
        ELSE 'OK'
    END AS status
FROM (
    SELECT
        database,
        table,
        '',
        sum(rows) AS partition_rows
    FROM system.parts
    WHERE active
      AND database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
    GROUP BY database, table, partition
)
GROUP BY database, table
HAVING count() > 1
ORDER BY skew_ratio DESC;

-- 分区倾斜度最高的表
SELECT
    database,
    table,
    partition_key,
    skew_ratio,
    partition_count
FROM (
    SELECT
        database,
        table,
        partition_key,
        count() AS partition_count,
        max(partition_rows) / avg(partition_rows) AS skew_ratio
    FROM (
        SELECT
            database,
            table,
            '',
            sum(rows) AS partition_rows
        FROM system.parts
        WHERE active
          AND database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
        GROUP BY database, table, partition
    ) AS partition_stats
    JOIN system.tables USING (database, table)
    GROUP BY database, table, partition_key
)
WHERE skew_ratio > 3
ORDER BY skew_ratio DESC;

-- ========================================
-- 检测分区不均衡
-- ========================================

-- 查找分区键不合理的表
SELECT
    database,
    table,
    engine,
    partition_key,
    sorting_key,
    total_rows,
    total_bytes,
    count() AS partition_count
FROM system.tables
WHERE database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
  AND total_bytes > 1073741824  -- 大于 1GB
  AND (
    -- 分区键为空
    partition_key = ''
    -- 分区键只有一个值
    OR (SELECT count(DISTINCT partition)
        FROM system.parts
        WHERE active
          AND system.parts.database = system.tables.database
          AND system.parts.table = system.tables.table) <= 2
    -- 分区过多
    OR (SELECT count(DISTINCT partition)
        FROM system.parts
        WHERE active
          AND system.parts.database = system.tables.database
          AND system.parts.table = system.tables.table) > 1000
  )
ORDER BY total_bytes DESC;

-- 建议的分区键配置
SELECT
    database,
    table,
    current_partition_key,
    recommended_partition_key,
    reason
FROM (
    -- 基于时间的表建议按日期分区
    SELECT
        database,
        table,
        partition_key AS current_partition_key,
        'toYYYYMM(event_time)' AS recommended_partition_key,
        'Time-based table should use date partitioning' AS reason
    FROM system.tables
    WHERE database NOT IN ('system')
      AND (name ILIKE '%event%' OR name ILIKE '%log%' OR name ILIKE '%transaction%')
      AND partition_key NOT ILIKE '%toYYYY%'
      AND partition_key NOT ILIKE '%toDate%'
      AND total_bytes > 1073741824
);

-- ========================================
-- 检测分区不均衡
-- ========================================

-- 检测过期分区
SELECT
    database,
    table,
    '',
    sum(rows) AS rows,
    sum(bytes_on_disk) AS bytes,
    formatReadableSize(sum(bytes_on_disk)) AS readable_size,
    toDateTime(max('')) AS partition_date,
    now() - toDateTime(max('')) AS age
FROM system.parts
WHERE active
  AND database NOT IN ('system')
  AND toUInt32(partition) < toUInt32(toYYYYMM(now()) - 12)  -- 超过 12 个月
GROUP BY database, table, partition
ORDER BY partition;

-- 分区 TTL 配置检查
SELECT
    database,
    table,
    partition_key,
    engine,
    partition_ttl_is_set,
    data_ttl_is_set
FROM (
    SELECT
        database,
        table,
        partition_key,
        engine,
        data_ttl IS NOT NULL AND data_ttl != '' AS partition_ttl_is_set,
        data_ttl IS NOT NULL AND data_ttl != '' AS data_ttl_is_set
    FROM system.tables
    WHERE database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
      AND engine LIKE '%MergeTree%'
);

-- ========================================
-- 检测分区不均衡
-- ========================================

-- 查找排序键设计不合理的表
SELECT
    database,
    table,
    engine,
    sorting_key,
    primary_key,
    total_rows,
    total_bytes,
    formatReadableSize(total_bytes) AS readable_size
FROM system.tables
WHERE database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
  AND total_bytes > 1073741824  -- 大于 1GB
  AND (
    -- 排序键为空
    sorting_key = ''
    -- 排序键只有一个字段
    OR length(splitByChar(',', sorting_key)) = 1
    -- 主键和排序键不匹配
    OR (primary_key != sorting_key AND primary_key NOT ILIKE '%' || sorting_key || '%')
  )
ORDER BY total_bytes DESC;

-- 排序键利用率分析
SELECT
    database,
    table,
    sorting_key,
    total_rows,
    total_bytes,
    avg(marks) AS avg_marks,
    avg(granules) AS avg_granules
FROM system.parts
WHERE active
  AND database NOT IN ('system')
GROUP BY database, table
HAVING total_bytes > 1073741824
ORDER BY total_bytes DESC;

-- ========================================
-- 检测分区不均衡
-- ========================================

-- 查询是否使用排序键
SELECT
    query_id,
    user,
    substring(query, 1, 300) AS query,
    read_rows,
    result_rows,
    query_duration_ms,
    CASE
        WHEN query ILIKE '%' || replace(sorting_key, ',', '%') || '%' THEN 'MATCHES'
        ELSE 'NO MATCH'
    END AS matches_sorting_key
FROM system.query_log
CROSS JOIN (
    SELECT DISTINCT
        database,
        table,
        sorting_key
    FROM system.tables
    WHERE database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
      AND sorting_key != ''
    LIMIT 10
)
WHERE type = 'QueryFinish'
  AND event_date >= today()
  AND query ILIKE '%' || database || '.' || table || '%'
  AND read_rows > 10000
ORDER BY query_duration_ms DESC
LIMIT 20;

-- ========================================
-- 检测分区不均衡
-- ========================================

-- 查找缺少索引的大表
SELECT
    database,
    table,
    engine,
    total_rows,
    total_bytes,
    formatReadableSize(total_bytes) AS readable_size,
    index_count,
    CASE
        WHEN index_count = 0 THEN 'NO INDEX'
        WHEN index_count < 2 THEN 'LOW COVERAGE'
        ELSE 'OK'
    END AS index_status
FROM (
    SELECT
        t.database,
        t.table,
        t.engine,
        t.total_rows,
        t.total_bytes,
        count(i.name) AS index_count
    FROM system.tables AS t
    LEFT JOIN system.data_skipping_indices AS i
        ON t.database = i.database AND t.table = i.table
    WHERE t.database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
      AND t.total_bytes > 1073741824  -- 大于 1GB
    GROUP BY t.database, t.table, t.engine, t.total_rows, t.total_bytes
)
WHERE index_status != 'OK'
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
    formatReadableSize(bytes_on_disk) AS bytes_on_disk
FROM system.data_skipping_indices
WHERE database NOT IN ('system')
ORDER BY database, table;

-- ========================================
-- 检测分区不均衡
-- ========================================

-- 分析索引命中率
SELECT
    database,
    table,
    name AS index_name,
    marks,
    granules,
    marks / greatest(granules, 1) AS mark_ratio,
    CASE
        WHEN marks / greatest(granules, 1) < 0.01 THEN 'HIGHLY EFFECTIVE'
        WHEN marks / greatest(granules, 1) < 0.1 THEN 'EFFECTIVE'
        ELSE 'INEFFECTIVE'
    END AS effectiveness
FROM system.data_skipping_indices
WHERE database NOT IN ('system')
ORDER BY mark_ratio;

-- ========================================
-- 检测分区不均衡
-- ========================================

-- 查找主键设计不合理的表
SELECT
    database,
    table,
    engine,
    primary_key,
    sorting_key,
    total_rows,
    total_bytes
FROM system.tables
WHERE database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
  AND total_bytes > 1073741824
  AND (
    -- 主键为空
    primary_key = ''
    -- 主键和排序键完全不同
    OR (primary_key != sorting_key AND NOT primary_key ILIKE '%' || substring(sorting_key, 1, 20) || '%')
    -- 主键字段过多
    OR length(splitByChar(',', primary_key)) > 5
  )
ORDER BY total_bytes DESC;

-- 主键唯一性检查
SELECT
    database,
    table,
    primary_key,
    total_rows,
    estimated_distinct_values,
    total_rows / greatest(estimated_distinct_values, 1) AS uniqueness_ratio,
    CASE
        WHEN total_rows / greatest(estimated_distinct_values, 1) < 1.1 THEN 'HIGHLY UNIQUE'
        WHEN total_rows / greatest(estimated_distinct_values, 1) < 10 THEN 'MODERATELY UNIQUE'
        ELSE 'LOW UNIQUENESS'
    END AS uniqueness_status
FROM (
    SELECT
        database,
        table,
        primary_key,
        total_rows,
        -- 估算唯一值数量
        total_rows / (SELECT avg(rows)
                      FROM system.parts
                      WHERE active
                        AND system.parts.database = system.tables.database
                        AND system.parts.table = system.tables.table) AS estimated_distinct_values
    FROM system.tables
    WHERE database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
      AND total_bytes > 1073741824
)
ORDER BY uniqueness_ratio DESC;

-- ========================================
-- 检测分区不均衡
-- ========================================

-- 分区倾斜分析
SELECT
    database,
    table,
    '',
    sum(rows) AS rows,
    sum(bytes_on_disk) AS bytes,
    formatReadableSize(sum(bytes_on_disk)) AS readable_size
FROM system.parts
WHERE active
  AND database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
GROUP BY database, table, partition
HAVING sum(bytes_on_disk) > 1073741824  -- 大于 1GB
ORDER BY bytes DESC;

-- 严重倾斜的分区
SELECT
    database,
    table,
    '',
    partition_bytes,
    avg_bytes,
    partition_bytes / avg_bytes AS skew_ratio
FROM (
    SELECT
        database,
        table,
        '',
        sum(bytes_on_disk) AS partition_bytes
    FROM system.parts
    WHERE active
      AND database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
    GROUP BY database, table, partition
) AS partition_stats
JOIN (
    SELECT
        database,
        table,
        avg(bytes_on_disk) AS avg_bytes
    FROM system.parts
    WHERE active
      AND database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
    GROUP BY database, table
) AS table_stats USING (database, table)
WHERE partition_bytes / avg_bytes > 5  -- 倾斜度超过 5 倍
ORDER BY skew_ratio DESC;

-- ========================================
-- 检测分区不均衡
-- ========================================

-- 数据分布分析
SELECT
    database,
    table,
    count() AS part_count,
    sum(rows) AS total_rows,
    min(rows) AS min_part_rows,
    max(rows) AS max_part_rows,
    avg(rows) AS avg_part_rows,
    max(rows) / greatest(avg(rows), 1) AS max_avg_ratio,
    stdDev(rows) AS rows_stddev
FROM system.parts
WHERE active
  AND database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
GROUP BY database, table
HAVING count() > 10  -- 至少有 10 个部分
  AND max(rows) / greatest(avg(rows), 1) > 3  -- 最大部分是平均的 3 倍
ORDER BY max_avg_ratio DESC;

-- Part 大小分布
SELECT
    database,
    table,
    count() AS part_count,
    min(bytes_on_disk) AS min_bytes,
    max(bytes_on_disk) AS max_bytes,
    avg(bytes_on_disk) AS avg_bytes,
    formatReadableSize(max(bytes_on_disk)) AS max_readable,
    formatReadableSize(avg(bytes_on_disk)) AS avg_readable
FROM system.parts
WHERE active
  AND database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
GROUP BY database, table
HAVING max(bytes_on_disk) / greatest(avg(bytes_on_disk), 1) > 10
ORDER BY max_avg_ratio DESC;

-- ========================================
-- 检测分区不均衡
-- ========================================

-- 高空值率列检测
SELECT
    database,
    table,
    name AS column_name,
    type,
    default_kind,
    default_expression
FROM system.columns
WHERE database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
  AND default_kind = ''
  AND type NOT LIKE '%Nullable%'
  -- 需要结合实际数据查询，这里只是结构检查
ORDER BY database, table, position;

-- ========================================
-- 检测分区不均衡
-- ========================================

-- 不合理的数据类型
SELECT
    database,
    table,
    name AS column_name,
    type,
    default_kind,
    default_expression,
    total_bytes * 100.0 / (
        SELECT sum(bytes_on_disk)
        FROM system.parts
        WHERE active
          AND system.parts.database = system.columns.database
          AND system.parts.table = system.columns.table
    ) AS column_size_percent
FROM system.columns
WHERE database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
  AND (
    -- 使用 String 存储数值
    type = 'String' AND name ILIKE '%id%'
    -- 使用 Float64 存储整数
    OR type = 'Float64' AND name ILIKE '%count%'
    -- 使用高精度 Decimal 存储低精度数据
    OR type LIKE 'Decimal%' AND name ILIKE '%rate%'
  )
ORDER BY column_size_percent DESC;

-- ========================================
-- 检测分区不均衡
-- ========================================

-- 创建数据质量汇总视图
CREATE VIEW monitoring.data_quality_summary AS
SELECT
    'Partition Skew' AS quality_metric,
    count() AS issue_count,
    avg(skew_ratio) AS avg_skew_ratio
FROM (
    SELECT
        database,
        table,
        max(partition_rows) / avg(partition_rows) AS skew_ratio
    FROM (
        SELECT
            database,
            table,
            '',
            sum(rows) AS partition_rows
        FROM system.parts
        WHERE active
          AND database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
        GROUP BY database, table, partition
    )
    GROUP BY database, table
)
WHERE skew_ratio > 3

UNION ALL
SELECT
    'No Partition Key' AS quality_metric,
    count() AS issue_count,
    0 AS avg_skew_ratio
FROM system.tables
WHERE database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
  AND partition_key = ''
  AND total_bytes > 1073741824

UNION ALL
SELECT
    'No Index' AS quality_metric,
    count() AS issue_count,
    0 AS avg_skew_ratio
FROM system.tables AS t
LEFT JOIN system.data_skipping_indices AS i
    ON t.database = i.database AND t.table = i.table
WHERE t.database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
  AND t.total_bytes > 1073741824
  AND i.name IS NULL;
