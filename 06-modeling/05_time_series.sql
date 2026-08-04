-- ============================================================
-- 05 - 时间序列建模
-- 描述：时间序列是 ClickHouse 最擅长的场景
-- 适用版本：ClickHouse 25.12+
-- ============================================================

-- 【原理】时间序列建模的核心思想
-- ============================================================
-- 1. 时间序列数据是 CH 最擅长的场景（天生的有序写入）
-- 2. 分区策略决定数据管理和查询效率
-- 3. 聚合策略（物化视图 + 时间窗口）减少数据量
-- 4. 降采样在数据精度和存储之间做平衡
-- 5. TTL 自动过期，管理数据生命周期
-- 6. 时序数据去重使用 ReplacingMergeTree + 时间戳
-- ============================================================

DROP DATABASE IF EXISTS modeling_test;
CREATE DATABASE modeling_test;
USE modeling_test;

-- ============================================================
-- 实验一：分区策略对比
-- ============================================================

-- 【场景】物联网设备传感器数据，每天产生 1 亿条记录

-- 【原理】分区策略的选择
-- 按天分区：适合数据量大、查询精确到天的场景
-- 按周分区：适合数据量适中、按周统计的场景
-- 按月分区：适合数据量小的场景
-- 按年分区：适合归档场景

-- 方案 A：按天分区（推荐，默认选择）
CREATE TABLE sensor_data_daily
(
    sensor_id   UInt32,
    event_time  DateTime,
    temperature Float32,
    humidity    Float32,
    pressure    Float32,
    battery     Float32
)
ENGINE = MergeTree
ORDER BY (sensor_id, event_time)
PARTITION BY toDate(event_time)  -- 按天分区
TTL toDate(event_time) + INTERVAL 90 DAY DELETE;  -- 90 天过期

-- 方案 B：按月分区（适合数据量较小的场景）
CREATE TABLE sensor_data_monthly
(
    sensor_id   UInt32,
    event_time  DateTime,
    temperature Float32,
    humidity    Float32,
    pressure    Float32,
    battery     Float32
)
ENGINE = MergeTree
ORDER BY (sensor_id, event_time)
PARTITION BY toYYYYMM(event_time)  -- 按月分区
TTL toDate(event_time) + INTERVAL 12 MONTH DELETE;  -- 12 个月过期

-- 方案 C：按周分区（适合按周统计的场景）
CREATE TABLE sensor_data_weekly
(
    sensor_id   UInt32,
    event_time  DateTime,
    temperature Float32,
    humidity    Float32,
    pressure    Float32,
    battery     Float32
)
ENGINE = MergeTree
ORDER BY (sensor_id, event_time)
PARTITION BY toMonday(event_time)  -- 按周分区
TTL toDate(event_time) + INTERVAL 180 DAY DELETE;

-- 插入测试数据
INSERT INTO sensor_data_daily SELECT
    number % 1000 AS sensor_id,
    toDateTime('2024-01-01 00:00:00') + number % 864000 AS event_time,
    toFloat32(20 + rand() % 20) AS temperature,
    toFloat32(50 + rand() % 50) AS humidity,
    toFloat32(1000 + rand() % 50) AS pressure,
    toFloat32(3.0 + rand() % 2) AS battery
FROM system.numbers
LIMIT 500000;

INSERT INTO sensor_data_monthly SELECT
    number % 1000 AS sensor_id,
    toDateTime('2024-01-01 00:00:00') + number % 864000 AS event_time,
    toFloat32(20 + rand() % 20) AS temperature,
    toFloat32(50 + rand() % 50) AS humidity,
    toFloat32(1000 + rand() % 50) AS pressure,
    toFloat32(3.0 + rand() % 2) AS battery
FROM system.numbers
LIMIT 500000;

INSERT INTO sensor_data_weekly SELECT
    number % 1000 AS sensor_id,
    toDateTime('2024-01-01 00:00:00') + number % 864000 AS event_time,
    toFloat32(20 + rand() % 20) AS temperature,
    toFloat32(50 + rand() % 50) AS humidity,
    toFloat32(1000 + rand() % 50) AS pressure,
    toFloat32(3.0 + rand() % 2) AS battery
FROM system.numbers
LIMIT 500000;

-- 【对比】分区数量对比
SELECT '【分区数量对比】:';
SELECT table, count() AS partition_count, formatReadableSize(sum(bytes_on_disk)) AS size
FROM system.parts
WHERE database = 'modeling_test' AND table LIKE 'sensor_data_%' AND active = 1
GROUP BY table
ORDER BY table;

-- 【坑】分区不是越细越好
-- 按小时分区会导致大量小 parts，影响 merge 性能
-- 每个分区建议至少 10 GB 以上数据
-- 对于 CH，按天分区是最通用的选择

-- ============================================================
-- 实验二：聚合策略（物化视图 + 时间窗口）
-- ============================================================

-- 【场景】传感器数据按分钟、小时、天做聚合统计

-- 原始数据表
CREATE TABLE sensor_raw
(
    sensor_id   UInt32,
    event_time  DateTime,
    temperature Float32,
    humidity    Float32,
    pressure    Float32
)
ENGINE = MergeTree
ORDER BY (sensor_id, event_time)
PARTITION BY toDate(event_time);

-- 1. 分钟级聚合（1 分钟粒度）
CREATE MATERIALIZED VIEW mv_sensor_1min
ENGINE = AggregatingMergeTree
ORDER BY (sensor_id, window_start)
PARTITION BY toDate(window_start)
AS SELECT
    sensor_id,
    toStartOfMinute(event_time) AS window_start,
    avgState(temperature) AS avg_temp,
    maxState(temperature) AS max_temp,
    minState(temperature) AS min_temp,
    avgState(humidity) AS avg_humidity,
    avgState(pressure) AS avg_pressure,
    countState() AS sample_count
FROM sensor_raw
GROUP BY sensor_id, toStartOfMinute(event_time);

-- 2. 小时级聚合（从分钟级聚合）
CREATE MATERIALIZED VIEW mv_sensor_1hour
ENGINE = AggregatingMergeTree
ORDER BY (sensor_id, window_start)
PARTITION BY toDate(window_start)
AS SELECT
    sensor_id,
    toStartOfHour(window_start) AS window_start,
    avgMerge(avg_temp) AS avg_temp,
    maxMerge(max_temp) AS max_temp,
    minMerge(min_temp) AS min_temp,
    avgMerge(avg_humidity) AS avg_humidity,
    avgMerge(avg_pressure) AS avg_pressure,
    countMerge(sample_count) AS sample_count
FROM mv_sensor_1min
GROUP BY sensor_id, toStartOfHour(window_start);

-- 3. 天级聚合（从小时级聚合）
CREATE MATERIALIZED VIEW mv_sensor_1day
ENGINE = AggregatingMergeTree
ORDER BY (sensor_id, window_start)
PARTITION BY toDate(window_start)
AS SELECT
    sensor_id,
    toDate(window_start) AS window_start,
    avgMerge(avg_temp) AS avg_temp,
    maxMerge(max_temp) AS max_temp,
    minMerge(min_temp) AS min_temp,
    avgMerge(avg_humidity) AS avg_humidity,
    avgMerge(avg_pressure) AS avg_pressure,
    countMerge(sample_count) AS sample_count
FROM mv_sensor_1hour
GROUP BY sensor_id, toDate(window_start);

-- 插入测试数据
INSERT INTO sensor_raw SELECT
    number % 100 AS sensor_id,
    toDateTime('2024-01-01 00:00:00') + number % 86400 AS event_time,
    toFloat32(20 + rand() % 20) AS temperature,
    toFloat32(50 + rand() % 50) AS humidity,
    toFloat32(1000 + rand() % 50) AS pressure
FROM system.numbers
LIMIT 200000;

-- 查询聚合结果
SELECT '【分钟级聚合】传感器 1 的温度:';
SELECT window_start, avg_temp, max_temp, min_temp, sample_count
FROM mv_sensor_1min
WHERE sensor_id = 1
ORDER BY window_start
LIMIT 5;

SELECT '【小时级聚合】传感器 1 的温度:';
SELECT window_start, avg_temp, max_temp, min_temp
FROM mv_sensor_1hour
WHERE sensor_id = 1
ORDER BY window_start
LIMIT 5;

SELECT '【天级聚合】传感器 1 的温度:';
SELECT window_start, avg_temp, max_temp, min_temp
FROM mv_sensor_1day
WHERE sensor_id = 1
ORDER BY window_start;

-- ============================================================
-- 实验三：降采样（Downsampling）
-- ============================================================

-- 【场景】从高精度数据降采样到低精度，减少存储

-- 【原理】降采样策略
-- oldest：保留窗口内的最旧值
-- latest：保留窗口内的最新值
-- avg：保留窗口内的平均值
-- sum：保留窗口内的总和
-- max/min：保留窗口内的最大值/最小值
-- first/last：保留窗口内的第一个/最后一个值

-- 创建降采样表（1 分钟粒度 → 1 小时粒度）
CREATE TABLE sensor_downsampled
(
    sensor_id      UInt32,
    hour_start     DateTime,
    temp_avg       Float32,    -- 小时平均温度
    temp_max       Float32,    -- 小时最高温度
    temp_min       Float32,    -- 小时最低温度
    temp_first     Float32,    -- 小时初始温度
    temp_last      Float32,    -- 小时结束温度
    sample_count   UInt32      -- 采样点数
)
ENGINE = MergeTree
ORDER BY (sensor_id, hour_start);

-- 从原始数据降采样到小时级
INSERT INTO sensor_downsampled
SELECT
    sensor_id,
    toStartOfHour(event_time) AS hour_start,
    avg(temperature) AS temp_avg,
    max(temperature) AS temp_max,
    min(temperature) AS temp_min,
    argMin(temperature, event_time) AS temp_first,   -- 最早的
    argMax(temperature, event_time) AS temp_last,    -- 最晚的
    count() AS sample_count
FROM sensor_raw
GROUP BY sensor_id, toStartOfHour(event_time);

-- 查询降采样结果
SELECT '【降采样】小时级数据:';
SELECT sensor_id, hour_start, temp_avg, temp_max, temp_min, temp_first, temp_last, sample_count
FROM sensor_downsampled
WHERE sensor_id = 1
ORDER BY hour_start
LIMIT 10;

-- 【坑】降采样会丢失数据精度
-- 降采样后无法恢复原始数据
-- 建议保留原始数据一段时间后再降采样

-- ============================================================
-- 实验四：时序数据去重（ReplacingMergeTree + 时间戳）
-- ============================================================

-- 【场景】物联网设备可能重复上报数据，需要去重

-- 【原理】ReplacingMergeTree 的去重机制
-- 1. 去重发生在后台 merge 时，不是查询时
-- 2. 使用 ORDER BY 列作为去重键
-- 3. 可以指定版本列，保留最新版本
-- 4. 查询时需要使用 FINAL 关键字或 argMax 获取最新值

-- 创建去重表
CREATE TABLE sensor_dedup
(
    sensor_id      UInt32,
    event_time     DateTime,
    temperature    Float32,
    humidity       Float32,
    -- 重复数据可能来自不同上报时间，使用上报时间作为版本
    report_time    DateTime,
    -- 使用批次号做版本比较
    batch_id       UInt64
)
ENGINE = ReplacingMergeTree(batch_id)  -- 用 batch_id 做版本，值越大越新
ORDER BY (sensor_id, event_time)        -- 去重键：相同 sensor_id + event_time 视为重复
PARTITION BY toDate(event_time);

-- 插入重复数据（模拟重复上报）
INSERT INTO sensor_dedup VALUES
    (1, '2024-06-01 10:00:00', 25.5, 60.0, '2024-06-01 10:00:05', 1),
    (1, '2024-06-01 10:00:00', 25.7, 60.1, '2024-06-01 10:00:10', 2),  -- 重复，更新温度
    (1, '2024-06-01 10:00:00', 25.6, 60.2, '2024-06-01 10:00:15', 3),  -- 重复，更新湿度
    (2, '2024-06-01 10:00:00', 30.0, 55.0, '2024-06-01 10:00:08', 1),
    (2, '2024-06-01 10:05:00', 31.0, 54.0, '2024-06-01 10:05:12', 1);

-- 查询去重前的数据（包含重复行）
SELECT '【去重前】包含重复数据:';
SELECT sensor_id, event_time, temperature, humidity, batch_id
FROM sensor_dedup
ORDER BY sensor_id, event_time, batch_id DESC;

-- 使用 FINAL 查询去重后的结果
SELECT '【去重后】使用 FINAL:';
SELECT sensor_id, event_time, temperature, humidity, batch_id
FROM sensor_dedup FINAL
ORDER BY sensor_id, event_time;

-- 手动触发 merge 以查看去重效果
-- OPTIMIZE TABLE sensor_dedup FINAL;

-- 使用 argMax 获取最新版本（不需要 FINAL）
SELECT '【去重后】使用 argMax:';
SELECT
    sensor_id,
    event_time,
    argMax(temperature, batch_id) AS temperature,
    argMax(humidity, batch_id) AS humidity,
    max(batch_id) AS batch_id
FROM sensor_dedup
GROUP BY sensor_id, event_time
ORDER BY sensor_id, event_time;

-- 【坑】ReplacingMergeTree 的注意事项
-- 1. 去重不是实时的，依赖后台 merge 触发
-- 2. 查询时需要 FINAL 或 argMax 才能看到最新版本
-- 3. FINAL 降低了查询性能，建议使用 argMax
-- 4. 版本列的类型必须是数值型或时间型

-- ============================================================
-- 实验五：TTL 自动过期
-- ============================================================

-- 【场景】数据自动过期，管理存储成本

-- 【原理】TTL 的机制
-- 1. TTL 可以设置到行级别（DELETE）或列级别（只删除某列的值）
-- 2. TTL 在后台 merge 时执行，不是实时删除
-- 3. TTL 可以设置多个条件
-- 4. TTL 可以配合 GROUP BY 做数据降采样后再删除

-- 带 TTL 的表
CREATE TABLE sensor_with_ttl
(
    sensor_id      UInt32,
    event_time     DateTime,
    temperature    Float32,
    humidity       Float32,
    pressure       Float32,
    -- 列级别 TTL：原始数据 30 天后删除，但保留聚合值
    raw_data       String
)
ENGINE = MergeTree
ORDER BY (sensor_id, event_time)
PARTITION BY toDate(event_time)
-- 行级别 TTL：90 天后删除整行
TTL toDate(event_time) + INTERVAL 90 DAY DELETE,
    -- 列级别 TTL：30 天后删除 raw_data 列
    toDate(event_time) + INTERVAL 30 DAY TO COLUMN raw_data
-- 设置 TTL 只在合并时执行，不会单独触发
SETTINGS merge_with_ttl_timeout = 3600;

-- 插入测试数据
INSERT INTO sensor_with_ttl SELECT
    number % 100 AS sensor_id,
    toDateTime('2024-06-01 00:00:00') + number % 86400 AS event_time,
    toFloat32(20 + rand() % 20) AS temperature,
    toFloat32(50 + rand() % 50) AS humidity,
    toFloat32(1000 + rand() % 50) AS pressure,
    toString(rand()) AS raw_data
FROM system.numbers
LIMIT 100000;

-- 查看 TTL 定义
SELECT '【TTL 定义】查看表的 TTL 设置:';
SELECT name, engine, ttl_expr
FROM system.tables
WHERE database = 'modeling_test' AND name = 'sensor_with_ttl';

-- 【坑】TTL 的注意事项
-- 1. TTL 不是实时删除的，依赖后台 merge
-- 2. 可以通过 ALTER TABLE MODIFY TTL 修改
-- 3. 列级别 TTL 将列值置为默认值，不是立刻释放空间
-- 4. 设置 merge_with_ttl_timeout 控制 TTL 合并超时

-- 修改 TTL
ALTER TABLE sensor_with_ttl MODIFY TTL
    toDate(event_time) + INTERVAL 60 DAY DELETE;  -- 改为 60 天

-- 添加新的 TTL 条件
ALTER TABLE sensor_with_ttl ADD TTL
    toDate(event_time) + INTERVAL 180 DAY DELETE;

-- 删除 TTL
-- ALTER TABLE sensor_with_ttl REMOVE TTL;

-- 查询 TTL 合并进度
SELECT '【TTL 进度】查看 TTL 合并状态:';
SELECT
    table,
    partition_id,
    rows,
    formatReadableSize(bytes_on_disk) AS size,
    min_time,
    max_time
FROM system.parts
WHERE database = 'modeling_test' AND table = 'sensor_with_ttl' AND active = 1
ORDER BY partition_id;

-- ============================================================
-- 结论：时间序列建模指南
-- ============================================================
-- 1. 分区策略：按天分区是最通用的选择
-- 2. 聚合策略：物化视图 + 时间窗口，逐层降采样
-- 3. 降采样：保留原始数据短期，降采样数据长期
-- 4. 去重：ReplacingMergeTree + 版本号，用 argMax 查询
-- 5. TTL：设置行级和列级 TTL，管理数据生命周期
-- 6. 时间序列查询优化：使用时间范围过滤 + ORDER BY 时间列

-- 最佳实践：完整的时间序列表设计
CREATE TABLE best_practice_time_series
(
    sensor_id    UInt32,
    event_time   DateTime,
    value        Float32,
    -- 元数据
    quality      UInt8,        -- 数据质量：0-100
    location     LowCardinality(String)  -- 位置信息
)
ENGINE = MergeTree
ORDER BY (sensor_id, event_time)
PARTITION BY toDate(event_time)
TTL toDate(event_time) + INTERVAL 90 DAY DELETE
SETTINGS index_granularity = 8192;

-- 对应的物化视图（小时级聚合）
CREATE MATERIALIZED VIEW mv_best_practice_hourly
ENGINE = AggregatingMergeTree
ORDER BY (sensor_id, hour_start)
PARTITION BY toDate(hour_start)
AS SELECT
    sensor_id,
    toStartOfHour(event_time) AS hour_start,
    avgState(value) AS avg_value,
    maxState(value) AS max_value,
    minState(value) AS min_value,
    countState() AS sample_count
FROM best_practice_time_series
GROUP BY sensor_id, toStartOfHour(event_time);

SELECT 'DONE - 时间序列建模实验完成';

DROP DATABASE IF EXISTS modeling_test;