-- =====================================================
-- 06 - 两阶段聚合
-- =====================================================
-- 分布式查询的 sumState/sumMerge 两阶段过程
-- avg/uniq/quantile 的特殊处理
-- 优化器配置与谓词下推
-- 集群: treasurycluster
-- =====================================================

-- 注意: 集群建库必须加 ON CLUSTER，否则 clickhouse-server-2 上数据库不存在，
-- 后续 ON CLUSTER 建表会报 Code 81 (UNKNOWN_DATABASE)
DROP DATABASE IF EXISTS distributed_test ON CLUSTER treasurycluster SYNC;
CREATE DATABASE IF NOT EXISTS distributed_test ON CLUSTER treasurycluster;
USE distributed_test;

-- ========================================
-- 【原理】两阶段聚合是什么
-- ========================================
-- 分布式聚合查询不是简单地在各分片执行相同 SQL
-- 而是拆分为两个阶段:
--
-- 第一阶段（Partial）:
--   每个分片执行 sumState / countState / uniqState 等
--   → 产生中间聚合状态（不返回原始数据）
--   → 状态是紧凑的二进制格式，传输量小
--
-- 第二阶段（Merge）:
--   协调节点执行 sumMerge / countMerge / uniqMerge
--   → 合并各分片的状态，输出最终结果
--
-- 为什么需要 State 函数?
--   sum(amount) 可以拆分为 sumState → sumMerge
--   因为 sum 是可交换可结合的: sum(a) + sum(b) = sum(a+b)
--
--   但 avg(avg) ≠ 全局 avg ❌
--   avg(amount) 不能直接对各分片 avg 求平均
--   需要保存 {sum, count} 状态，最后 sum/count

-- -----------------------------------------------------
-- 1. 创建测试表
-- -----------------------------------------------------
CREATE TABLE IF NOT EXISTS agg_test_local ON CLUSTER treasurycluster
(
    user_id UInt32,
    event_type String,
    amount Float64,
    event_time DateTime
)
ENGINE = ReplicatedMergeTree
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_time, user_id);

-- 创建分布式表
CREATE TABLE IF NOT EXISTS agg_test_dist ON CLUSTER treasurycluster
AS agg_test_local
ENGINE = Distributed(treasurycluster, distributed_test, agg_test_local, cityHash64(user_id));

-- 插入测试数据
INSERT INTO agg_test_dist VALUES
-- user_id 分布: 1-5 各有不同数据量
(1, 'click', 1.0, '2024-01-15 10:00:00'),
(1, 'click', 2.0, '2024-01-15 10:05:00'),
(1, 'purchase', 100.0, '2024-01-15 10:10:00'),
(2, 'view', 0.5, '2024-01-15 10:00:00'),
(2, 'click', 1.5, '2024-01-15 10:15:00'),
(3, 'purchase', 200.0, '2024-01-15 10:00:00'),
(3, 'purchase', 150.0, '2024-01-15 10:20:00'),
(3, 'click', 3.0, '2024-01-15 10:25:00'),
(4, 'view', 0.3, '2024-01-15 10:00:00'),
(4, 'view', 0.8, '2024-01-15 10:30:00'),
(5, 'purchase', 300.0, '2024-01-15 10:00:00'),
(5, 'click', 2.5, '2024-01-15 10:35:00');

-- -----------------------------------------------------
-- 2. 查看两阶段聚合的执行计划
-- -----------------------------------------------------
-- 【原理】EXPLAIN 显示分布式查询是否使用两阶段聚合

-- 查看 sum 的两阶段聚合计划
-- 【场景】验证分布式 sum 是否拆分为两阶段
EXPLAIN PLAN
SELECT 
    event_type,
    sum(amount) AS total_amount
FROM agg_test_dist
GROUP BY event_type
ORDER BY total_amount DESC;

-- 查看 count 的两阶段聚合计划
EXPLAIN PLAN
SELECT 
    event_type,
    count() AS event_count
FROM agg_test_dist
GROUP BY event_type
ORDER BY event_count DESC;

-- -----------------------------------------------------
-- 3. 手动模拟两阶段聚合
-- -----------------------------------------------------
-- 【原理】手动执行 sumState 和 sumMerge，理解两阶段过程

-- 第一阶段: 每个分片执行 sumState（局部聚合）
-- sumState 返回聚合状态（二进制），不是最终数值
SELECT 
    hostName() AS host,
    event_type,
    sumState(amount) AS partial_state
FROM agg_test_dist
GROUP BY event_type;

-- 第二阶段: 协调节点执行 sumMerge（全局合并）
-- sumMerge 将各分片的状态合并为最终结果
-- 【原理】sumMerge 接受 sumState 的输出，返回最终 sum
SELECT 
    event_type,
    sumMerge(partial_state) AS total_amount
FROM (
    SELECT 
        event_type,
        sumState(amount) AS partial_state
    FROM agg_test_dist
    GROUP BY event_type
)
GROUP BY event_type
ORDER BY event_type;

-- 对比直接 sum（等效于两阶段聚合）
SELECT 
    event_type,
    sum(amount) AS total_amount
FROM agg_test_dist
GROUP BY event_type
ORDER BY event_type;

-- -----------------------------------------------------
-- 【原理】avg 的特殊处理
-- -----------------------------------------------------
-- avg = sum / count
-- 不能直接对各分片 avg 求平均！
--
-- 错误: avg(avg(amount)) ≠ 全局 avg(amount) ❌
-- 正确: sum(sum(amount)) / sum(count(amount)) ✅
--
-- ClickHouse 的 avgMerge 内部处理了 sum/count 的合并

-- 查看 avg 的两阶段执行计划
EXPLAIN PLAN
SELECT 
    event_type,
    avg(amount) AS avg_amount
FROM agg_test_dist
GROUP BY event_type;

-- 手动模拟 avg 的两阶段执行
-- 【原理】avgState 返回 {sum, count} 二元组
-- avgMerge 计算 sum/count
SELECT 
    event_type,
    avgMerge(avg_state) AS avg_amount
FROM (
    SELECT 
        event_type,
        avgState(amount) AS avg_state
    FROM agg_test_dist
    GROUP BY event_type
)
GROUP BY event_type
ORDER BY event_type;

-- 验证结果一致
SELECT 
    event_type,
    avg(amount) AS avg_amount
FROM agg_test_dist
GROUP BY event_type
ORDER BY event_type;

-- -----------------------------------------------------
-- 【原理】uniq 的特殊处理
-- -----------------------------------------------------
-- uniq 使用 HyperLogLog（HLL）算法
-- HLL 是一种概率性基数估计方法
--
-- uniq 不能直接求和的原因:
--   错误: sum(uniq(user_id))  ❌
--   问题: 相同 user_id 可能出现在多个分片，会被重复计算
--
-- 正确方式:
--   uniqState → 每个分片产生 HLL 状态
--   uniqMerge → 合并 HLL 状态，去重
--
-- 注意: uniq 是近似值，不是精确去重
-- 如果需要精确去重，用 uniqExact（但更慢更耗内存）

-- 查看 uniq 的两阶段执行计划
EXPLAIN PLAN
SELECT 
    event_type,
    uniq(user_id) AS unique_users
FROM agg_test_dist
GROUP BY event_type;

-- 手动模拟 uniq 的两阶段执行
SELECT 
    event_type,
    uniqMerge(uniq_state) AS unique_users
FROM (
    SELECT 
        event_type,
        uniqState(user_id) AS uniq_state
    FROM agg_test_dist
    GROUP BY event_type
)
GROUP BY event_type
ORDER BY event_type;

-- 验证结果一致
SELECT 
    event_type,
    uniq(user_id) AS unique_users
FROM agg_test_dist
GROUP BY event_type
ORDER BY event_type;

-- 对比: 错误地直接对各分片 uniq 求和
-- 【坑】这个结果是不正确的！
SELECT 
    event_type,
    sum(uniq(user_id)) AS wrong_unique_users
FROM agg_test_dist
GROUP BY event_type
ORDER BY event_type;

-- -----------------------------------------------------
-- 【原理】quantile 的特殊处理
-- -----------------------------------------------------
-- 分位数（quantile）也不能直接合并
-- quantile(0.5)(amount) 是近似值，使用 TDigest 算法
--
-- 正确方式:
--   quantileState(0.5)(amount) → 产生 TDigest 状态
--   quantileMerge(0.5) → 合并 TDigest 状态

-- 查看 quantile 的两阶段执行计划
EXPLAIN PLAN
SELECT 
    event_type,
    quantile(0.5)(amount) AS median_amount,
    quantile(0.95)(amount) AS p95_amount
FROM agg_test_dist
GROUP BY event_type;

-- 手动模拟 quantile 的两阶段执行
SELECT 
    event_type,
    quantileMerge(0.5)(quantile_state) AS median_amount,
    quantileMerge(0.95)(quantile_state) AS p95_amount
FROM (
    SELECT 
        event_type,
        quantileState(0.5)(amount) AS quantile_state
    FROM agg_test_dist
    GROUP BY event_type
)
GROUP BY event_type
ORDER BY event_type;

-- -----------------------------------------------------
-- 【原理】两阶段聚合的优化配置
-- -----------------------------------------------------
-- 1. enable_optimize_predicate_expression = 1
--    启用谓词下推优化，将 WHERE 条件下推到各分片
--    减少网络传输量
--
-- 2. prefer_localhost_replica = 0
--    不优先使用本地副本，让协调节点随机选择副本
--    避免所有查询都打到同一节点
--
-- 3. optimize_distributed_group_by_sharding_key = 1
--    如果 GROUP BY 字段包含分片键，可以本地完成聚合
--    避免跨分片数据传输

-- 开启优化配置
SET enable_optimize_predicate_expression = 1;
SET prefer_localhost_replica = 0;
SET optimize_distributed_group_by_sharding_key = 1;

-- 查看优化后的执行计划
-- 【原理】谓词下推后，WHERE 条件在各分片执行
EXPLAIN PLAN
SELECT 
    event_type,
    sum(amount) AS total_amount,
    count() AS event_count
FROM agg_test_dist
WHERE event_time >= '2024-01-15 10:00:00'
  AND event_time < '2024-01-15 10:30:00'
GROUP BY event_type
ORDER BY total_amount DESC;

-- 执行优化后的查询
SELECT 
    event_type,
    sum(amount) AS total_amount,
    count() AS event_count
FROM agg_test_dist
WHERE event_time >= '2024-01-15 10:00:00'
  AND event_time < '2024-01-15 10:30:00'
GROUP BY event_type
ORDER BY total_amount DESC;

-- 恢复默认设置
SET enable_optimize_predicate_expression = 0;
SET prefer_localhost_replica = 1;
SET optimize_distributed_group_by_sharding_key = 0;

-- -----------------------------------------------------
-- 【对比】不同聚合函数的两阶段支持
-- -----------------------------------------------------
-- +------------------+------------------+------------------+
-- | 聚合函数          | 两阶段支持        | 状态函数          |
-- +------------------+------------------+------------------+
-- | sum              | ✅ 直接支持       | sumState          |
-- | count            | ✅ 直接支持       | countState        |
-- | avg              | ✅ 通过 sum/count | avgState          |
-- | uniq             | ✅ HLL 合并       | uniqState         |
-- | uniqExact        | ✅ 精确合并       | uniqExactState    |
-- | quantile         | ✅ TDigest 合并   | quantileState     |
-- | min              | ✅ 直接支持       | minState          |
-- | max              | ✅ 直接支持       | maxState          |
-- | groupArray       | ❌ 不支持         | —                |
-- | any              | ✅ 直接支持       | anyState          |
-- | anyLast          | ✅ 直接支持       | anyLastState      |
-- +------------------+------------------+------------------+
--
-- groupArray 不支持两阶段聚合
-- 因为 groupArray 需要收集所有原始数据，无法预聚合
-- 如果分布式查询使用 groupArray，会触发全量数据拉取

-- 查看 groupArray 的执行计划（不支持下推）
EXPLAIN PLAN
SELECT 
    event_type,
    groupArray(amount) AS amounts
FROM agg_test_dist
GROUP BY event_type;

-- -----------------------------------------------------
-- 【坑】两阶段聚合常见问题
-- -----------------------------------------------------
-- 1. "两阶段聚合对所有查询自动优化"
--    实际: 某些聚合函数不支持（如 groupArray）
--    需要检查 EXPLAIN PLAN 确认
--
-- 2. "两阶段聚合结果和单节点一致"
--    实际: uniq 是近似算法，分片越多误差越大
--    如果要求精确去重，用 uniqExact
--
-- 3. "两阶段聚合一定更快"
--    实际: 协调节点合并状态也需要计算资源
--    数据量小时，单节点聚合可能更快
--
-- 4. "两阶段聚合减少网络传输"
--    实际: 不一定！如果分组基数很大，状态传输量也很大
--    建议用 max_bytes_before_external_group_by 控制

-- 查看聚合状态的大小
-- 【原理】sumState/uniqState 等状态的大小取决于数据量
SELECT 
    event_type,
    sumState(amount) AS sum_state,
    uniqState(user_id) AS uniq_state
FROM agg_test_dist
GROUP BY event_type;

-- -----------------------------------------------------
-- 清理
-- -----------------------------------------------------
DROP TABLE IF EXISTS agg_test_dist ON CLUSTER treasurycluster SYNC;
DROP TABLE IF EXISTS agg_test_local ON CLUSTER treasurycluster SYNC;

-- 与开头 ON CLUSTER 建库对应，DROP 也须 ON CLUSTER
DROP DATABASE IF EXISTS distributed_test ON CLUSTER treasurycluster SYNC;