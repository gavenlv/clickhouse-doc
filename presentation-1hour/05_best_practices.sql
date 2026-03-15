-- =====================================================
-- 05 - 最佳实践与常见问题
-- =====================================================
-- 集群: treasurycluster (2副本)
-- 时间: 55-60分钟
-- =====================================================

-- -----------------------------------------------------
-- 1. 表设计最佳实践
-- -----------------------------------------------------

-- 
-- ┌─────────────────────────────────────────────────────────────┐
-- │              表设计最佳实践                                   │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                             │
-- │  1. 选择合适的表引擎                                         │
-- │     - 95%+ 场景使用 MergeTree                               │
-- │     - 高可用需求用 ReplicatedMergeTree                     │
-- │                                                             │
-- │  2. 合理设计主键                                             │
-- │     - 高基数字段放前面                                       │
-- │     - 过滤频率高的放前面                                     │
-- │     - 避免使用随机值                                        │
-- │                                                             │
-- │  3. 选择合适的分区策略                                       │
-- │     - 日志/时序: toYYYYMMDD                                │
-- │     - 历史数据: toYYYYMM                                   │
-- │     - 小表: 不分区                                         │
-- │                                                             │
-- │  4. 使用合适的数据类型                                       │
-- │     - 整型: UInt8/16/32/64                                 │
-- │     - 字符串: String / FixedString                         │
-- │     - 枚举: Enum8/16                                        │
-- │     - 重复字符串: LowCardinality(String)                   │
-- │                                                             │
-- │  5. 避免 NULL                                               │
-- │     - Nullable 会增加存储和计算开销                         │
-- │     - 使用默认值代替 NULL                                  │
-- │                                                             │
-- └─────────────────────────────────────────────────────────────┘

-- -----------------------------------------------------
-- 2. 数据类型优化
-- -----------------------------------------------------

-- 使用 playground 数据库
USE playground;

-- 低基数字符串优化: LowCardinality (Replicated)
DROP TABLE IF EXISTS users ON CLUSTER treasurycluster SYNC;

CREATE TABLE users ON CLUSTER treasurycluster (
    user_id UInt32,
    username LowCardinality(String),
    country LowCardinality(String),
    status Enum8('active' = 1, 'inactive' = 2, 'pending' = 3)
) ENGINE = ReplicatedMergeTree()
ORDER BY user_id;

-- 插入测试数据
INSERT INTO users
SELECT 
    number AS user_id,
    'user_' || toString(number) AS username,
    ['US', 'CN', 'UK', 'JP', 'DE'][number % 5 + 1] AS country,
    CAST(number % 3 + 1 AS Enum8('active' = 1, 'inactive' = 2, 'pending' = 3)) AS status
FROM numbers(1000000);

-- 查看存储对比
SELECT 
    'LowCardinality' AS type,
    formatReadableSize(sum(data_compressed_bytes)) AS compressed,
    formatReadableSize(sum(data_uncompressed_bytes)) AS uncompressed
FROM system.parts_columns
WHERE database = 'playground' AND table = 'users' AND column IN ('username', 'country');

-- 
-- ┌─────────────────────────────────────────────────────────────┐
-- │              LowCardinality 优化效果                         │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                             │
-- │  普通 String:                                               │
-- │  ┌─────────────────────────────────────────────────────┐   │
-- │  │  100万行 × 20字节 = 20MB (未压缩)                  │   │
-- │  │  实际存储: ~15MB                                    │   │
-- │  └─────────────────────────────────────────────────────┘   │
-- │                                                             │
-- │  LowCardinality(String):                                    │
-- │  ┌─────────────────────────────────────────────────────┐   │
-- │  │  字典: 100万个唯一值 × 20字节 = 20MB               │   │
-- │  │  数据: 100万行 × 4字节 = 4MB                       │   │
-- │  │  实际存储: ~8MB (包含字典)                          │   │
-- │  └─────────────────────────────────────────────────────┘   │
-- │                                                             │
-- │  性能提升: 30-50% 查询速度                                 │
-- │                                                             │
-- └─────────────────────────────────────────────────────────────┘

-- -----------------------------------------------------
-- 3. 分片键选择
-- -----------------------------------------------------

-- 
-- ┌─────────────────────────────────────────────────────────────┐
-- │              分片键选择原则                                   │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                             │
-- │  选择标准:                                                   │
-- │  1. 分布均匀: 避免数据倾斜                                  │
-- │  2. 经常一起查询: 减少跨分片 JOIN                          │
-- │  3. 经常过滤: 利用分片裁剪                                 │
-- │                                                             │
-- │  常见分片键:                                                │
-- │  - user_id: 用户行为分析                                    │
│  │  - date/时间: 时序数据                                    │
-- │  - region/国家: 地域分析                                   │
-- │  - tenant_id: 多租户场景                                   │
-- │                                                             │
-- │  避免:                                                      │
│  │  - 随机值 (sharding_key = rand())                        │
│  │  - 低基数值 (导致数据倾斜)                                │
-- │                                                             │
-- └─────────────────────────────────────────────────────────────┘

-- -----------------------------------------------------
-- 4. 写入优化
-- -----------------------------------------------------

-- 
-- ┌─────────────────────────────────────────────────────────────┐
-- │              写入最佳实践                                     │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                             │
-- │  1. 批量写入                                                │
-- │     - 每批 1000-10000 行                                   │
-- │     - 避免单行 INSERT                                       │
-- │                                                             │
-- │  2. 异步写入                                                │
-- │     - 使用 Buffer 表 + 后台刷新                            │
-- │     - 减少同步等待                                         │
-- │                                                             │
-- │  3. 避免小文件                                             │
-- │     - Part 文件 < 10MB 会影响性能                          │
-- │     - 使用 max_insert_block_size 控制                     │
-- │                                                             │
-- │  4. 写入时间                                                │
-- │     - 避免业务高峰期大量写入                               │
-- │     - 利用 TTL 清理历史数据                                │
-- │                                                             │
-- └─────────────────────────────────────────────────────────────┘

-- 创建 Buffer 表演示 (Replicated)
DROP TABLE IF EXISTS bp_events ON CLUSTER treasurycluster SYNC;
DROP TABLE IF EXISTS bp_events_buffer ON CLUSTER treasurycluster SYNC;

CREATE TABLE bp_events ON CLUSTER treasurycluster (
    event_id UInt64,
    event_time DateTime,
    event_type String
) ENGINE = ReplicatedMergeTree()
ORDER BY event_time;

CREATE TABLE bp_events_buffer ON CLUSTER treasurycluster AS bp_events
ENGINE = Buffer('playground', 'bp_events', 16, 10, 100, 10000, 1000000, 10000000, 100000000);

-- 写入 Buffer 表
INSERT INTO bp_events_buffer 
SELECT number, now(), 'click' FROM numbers(10000);

-- 查看 Buffer 状态
-- SELECT 
--     database,
--     table,
--     num_layers,
--     is_stale
-- FROM system.buffers
-- WHERE database = 'playground';

-- 刷新 Buffer
SYSTEM FLUSH TABLES bp_events_buffer;

SELECT count() FROM bp_events;

-- -----------------------------------------------------
-- 5. 常见错误与解决方案
-- -----------------------------------------------------

-- 
-- ┌─────────────────────────────────────────────────────────────┐
-- │              常见错误与解决方案                               │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                             │
-- │  错误 1: Too many parts                                    │
-- │  ┌─────────────────────────────────────────────────────┐   │
-- │  │ 原因: 写入过快，后台合并跟不上                        │   │
-- │  │ 解决: 批量写入、调整 max_parts_to_merge_at_once     │   │
-- │  └─────────────────────────────────────────────────────┘   │
-- │                                                             │
-- │  错误 2: Memory limit exceeded                              │
-- │  ┌─────────────────────────────────────────────────────┐   │
-- │  │ 原因: 单次查询数据量过大                             │   │
-- │  │ 解决: 使用 LIMIT、分区裁剪、PREWHERE                │   │
-- │  └─────────────────────────────────────────────────────┘   │
-- │                                                             │
-- │  错误 3: Block ... has wrong column  │                     │
-- │  ┌─────────────────────────────────────────────────────┐   │
-- │  │ 原因: 写入数据类型不匹配                              │   │
-- │  │ 解决: 确保字段顺序和类型正确                         │   │
-- │  └─────────────────────────────────────────────────────┘   │
-- │                                                             │
-- │  错误 4: Part is committed twice                           │
-- │  ┌─────────────────────────────────────────────────────┐   │
-- │  │ 原因: 重复写入相同主键数据                           │   │
-- │  │ 解决: 使用 ReplacingMergeTree 或去重逻辑           │   │
-- │  └─────────────────────────────────────────────────────┘   │
-- │                                                             │
-- └─────────────────────────────────────────────────────────────┘

-- -----------------------------------------------------
-- 6. 监控与调优
-- -----------------------------------------------------

-- 查看系统健康状态
SELECT 
    'Parts' AS metric,
    (SELECT count() FROM system.parts WHERE active = 1) AS active_parts,
    (SELECT count() FROM system.parts WHERE active = 0) AS inactive_parts
UNION ALL
SELECT 
    'Queries' AS metric,
    (SELECT count() FROM system.query_log WHERE type = 'QueryFinish' AND event_time > now() - INTERVAL 1 HOUR) AS queries_1h,
    NULL
UNION ALL
SELECT 
    'Errors' AS metric,
    (SELECT count() FROM system.query_log WHERE type = 'Exception' AND event_time > now() - INTERVAL 1 HOUR) AS errors_1h,
    NULL;

-- 查看慢查询
SELECT 
    query,
    formatReadableSize(read_bytes) AS read_size,
    read_rows,
    query_duration_ms / 1000 AS duration_sec
FROM system.query_log
WHERE type = 'QueryFinish' 
  AND event_time > now() - INTERVAL 1 HOUR
  AND query_duration_ms > 1000
ORDER BY query_duration_ms DESC
LIMIT 10;

-- 查看内存使用
SELECT 
    metric,
    formatReadableSize(value) AS size
FROM system.metrics
WHERE metric LIKE '%Memory%'
ORDER BY metric;

-- 
-- ┌─────────────────────────────────────────────────────────────┐
-- │              关键监控指标                                     │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                             │
-- │  系统健康:                                                   │
-- │  - active_parts: 活跃 Part 数量                            │
-- │  - total_rows: 数据总行数                                  │
-- │  - query_count: 查询数量                                   │
-- │                                                             │
-- │  性能指标:                                                  │
--  - query_duration_ms: 查询耗时                               │
-- │  - read_rows: 读取行数                                     │
-- │  - memory_usage: 内存使用                                  │
-- │                                                             │
-- │  告警阈值:                                                  │
-- │  - Parts > 300: 写入过快                                   │
-- │  - Query > 10s: 需优化                                     │
-- │  - Memory > 80%: 资源不足                                  │
-- │                                                             │
-- └─────────────────────────────────────────────────────────────┘

-- -----------------------------------------------------
-- 7. ETL vs ClickHouse 职责划分
-- -----------------------------------------------------

-- 
-- ┌─────────────────────────────────────────────────────────────┐
-- │              ETL vs ClickHouse 职责                         │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                             │
-- │  ETL 应该做:                                                 │
-- │  ✓ 数据清洗: NULL 处理、格式转换                          │
-- │  ✓ 数据转换: 编码、归一化                                  │
-- │  ✓ 数据聚合: 预聚合、维度表构建                           │
-- │  ✓ 数据分层: ODS → DWD → DWS                             │
-- │  ✓ 历史数据: 定期归档和清理                                │
-- │                                                             │
-- │  ClickHouse 应该做:                                         │
-- │  ✓ 高速分析: Ad-hoc 查询                                   │
-- │  ✓ 大数据聚合: COUNT/SUM/AVG                             │
-- │  │  ✓ 实时计算: 最新数据实时分析                         │   │
-- │  │  ✓ 多维分析: 任意维度组合                              │   │
-- │  │                                                            │
-- │  ✗ 避免: 频繁小更新、事务处理、JOIN 大表                  │
-- │  │                                                            │
-- └─────────────────────────────────────────────────────────────┘

-- -----------------------------------------------------
-- 8. 本章小结
-- -----------------------------------------------------

-- 
-- ┌─────────────────────────────────────────────────────────────┐
-- │              总结: ClickHouse 最佳实践                        │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                             │
-- │  表设计:                                                     │
-- │  - 使用 MergeTree 引擎                                      │
-- │  - 合理设计主键和分区                                       │
-- │  - 使用 LowCardinality 优化字符串                         │
-- │                                                             │
-- │  查询优化:                                                   │
-- │  - 避免 SELECT *                                           │
-- │  - 利用分区裁剪                                             │
-- │  - 合理使用物化视图                                         │
-- │                                                             │
-- │  写入优化:                                                   │
-- │  - 批量写入 (1000-10000 行/批)                             │
-- │  - 避免高峰期大量写入                                      │
-- │                                                             │
-- │  运维监控:                                                   │
-- │  - 关注 Parts 数量                                         │
-- │  - 定期分析慢查询                                          │
-- │  - 监控内存使用                                            │
-- │                                                             │
-- └─────────────────────────────────────────────────────────────┘

-- 验证完成
SELECT 
    'ClickHouse 1小时分享' AS topic,
    '已完成' AS status,
    now() AS completed_at;
