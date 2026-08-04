-- =====================================================
-- 05 - 分片键设计
-- =====================================================
-- 分片键选择原则、均匀性实验、热点诊断、分片数规划
-- 集群: treasurycluster
-- =====================================================

DROP DATABASE IF EXISTS distributed_test;
CREATE DATABASE distributed_test;
USE distributed_test;

-- ========================================
-- 【原理】分片键选择原则
-- ========================================
-- 好的分片键需要满足:
--   1. 高基数: 不同值足够多，避免数据倾斜
--   2. 均匀分布: 每个值对应的数据量大致相等
--   3. 查询裁剪: 查询条件常包含分片键，可裁剪到单个分片
--   4. 不可变性: 分片键的值不变（否则数据路由到错误分片）
--
-- 路由公式:
--   目标分片 = cityHash64(sharding_key) % 分片总数
--
-- 常见分片键:
--   - cityHash64(user_id): 推荐，高基数均匀分布
--   - xxHash64(event_id): 高性能哈希，适合高吞吐
--   - intHash64(user_id): ClickHouse 内置整数哈希
--   - rand(): 随机，但单次批量插入可能扎堆
--   - sipHash64(ip_address): 适合按 IP 路由

-- -----------------------------------------------------
-- 1. 分片键均匀性实验
-- -----------------------------------------------------
-- 【原理】通过对比不同分片键的分布，选择最均匀的
-- 以 4 分片为例（实际集群可能只有 1 分片）

-- 实验 1: cityHash64 的均匀性
-- 【场景】验证 cityHash64 作为分片键的分布
SELECT 
    'cityHash64' AS method,
    cityHash64(number) % 4 AS shard,
    count() AS cnt,
    round(count() * 100.0 / sum(count()) OVER (), 2) AS pct
FROM numbers(1000000)
GROUP BY shard
ORDER BY shard;

-- 实验 2: xxHash64 的均匀性
-- 【对比】xxHash64 性能更好，分布同样均匀
SELECT 
    'xxHash64' AS method,
    xxHash64(toString(number)) % 4 AS shard,
    count() AS cnt,
    round(count() * 100.0 / sum(count()) OVER (), 2) AS pct
FROM numbers(1000000)
GROUP BY shard
ORDER BY shard;

-- 实验 3: intHash64 的均匀性
SELECT 
    'intHash64' AS method,
    intHash64(number) % 4 AS shard,
    count() AS cnt,
    round(count() * 100.0 / sum(count()) OVER (), 2) AS pct
FROM numbers(1000000)
GROUP BY shard
ORDER BY shard;

-- 实验 4: 直接取模
SELECT 
    'modulo' AS method,
    number % 4 AS shard,
    count() AS cnt,
    round(count() * 100.0 / sum(count()) OVER (), 2) AS pct
FROM numbers(1000000)
GROUP BY shard
ORDER BY shard;

-- 实验 5: rand() 的均匀性
-- 【坑】rand() 在单次查询中虽然是均匀的
-- 但每次 INSERT 批量数据时，rand() 连续调用可能产生相关性
SELECT 
    'rand' AS method,
    rand() % 4 AS shard,
    count() AS cnt,
    round(count() * 100.0 / sum(count()) OVER (), 2) AS pct
FROM numbers(1000000)
GROUP BY shard
ORDER BY shard;

-- -----------------------------------------------------
-- 2. 模拟真实数据的分片分布
-- -----------------------------------------------------
-- 【场景】使用真实业务字段模拟分片分布

-- 创建模拟用户表
CREATE TABLE IF NOT EXISTS shard_simulation
(
    user_id UInt32,
    event_id UInt64,
    event_time DateTime,
    city String,
    amount Float64
)
ENGINE = MergeTree
ORDER BY user_id;

-- 插入模拟数据（1000 万行）
-- 使用真实场景的数据分布: 部分用户活跃，部分用户不活跃
INSERT INTO shard_simulation
SELECT 
    -- 80% 的用户是低频用户，20% 是高频用户
    multiIf(rand() % 5 = 0, number % 1000, number % 100000) AS user_id,
    number AS event_id,
    '2024-01-01'::DateTime + INTERVAL rand() % 86400 SECOND AS event_time,
    multiIf(rand() % 5 = 0, 'Beijing', rand() % 5 = 1, 'Shanghai', rand() % 5 = 2, 'Guangzhou', rand() % 5 = 3, 'Shenzhen', 'Hangzhou') AS city,
    round(rand() % 1000 + rand() * 0.01, 2) AS amount
FROM numbers(1000000);

-- 检查 user_id 的分布
-- 【原理】如果某些 user_id 数据量远大于其他，则分片会倾斜
SELECT 
    multiIf(
        cnt > 1000, '> 1000',
        cnt > 100, '101-1000',
        cnt > 10, '11-100',
        cnt > 1, '2-10',
        '1'
    ) AS user_frequency,
    count() AS user_count
FROM (
    SELECT user_id, count() AS cnt
    FROM shard_simulation
    GROUP BY user_id
)
GROUP BY user_frequency
ORDER BY user_frequency;

-- 检查 cityHash64(user_id) 的分片分布
-- 【场景】验证分片键的均匀性
SELECT 
    cityHash64(user_id) % 4 AS shard,
    count() AS row_count,
    uniqExact(user_id) AS unique_users,
    sum(amount) AS total_amount,
    round(avg(amount), 2) AS avg_amount
FROM shard_simulation
GROUP BY shard
ORDER BY shard;

-- 对比直接使用 city 作为分片键
-- 【坑】低基数字段作为分片键会导致数据倾斜
SELECT 
    cityHash64(city) % 4 AS shard,
    city,
    count() AS row_count
FROM shard_simulation
GROUP BY shard, city
ORDER BY shard, row_count DESC;

-- -----------------------------------------------------
-- 【原理】查询裁剪
-- -----------------------------------------------------
-- 如果 WHERE 条件包含分片键，协调节点可以只查询相关分片
-- 这称为"分片裁剪"（shard pruning）
--
-- 例如: 分片键 = cityHash64(user_id)
--   WHERE user_id = 123 → 可以裁剪（计算 cityHash64(123) % N）
--   WHERE user_id IN (1,2,3) → 可以裁剪到 1-3 个分片
--   WHERE amount > 100 → 不能裁剪（不包含分片键）
--
-- 注意: ClickHouse 的分片裁剪是自动的，不需要手动指定

-- 验证分片裁剪
-- 【原理】EXPLAIN 显示查询计划，可以看到是否裁剪了分片
EXPLAIN SYNTAX
SELECT count() FROM shard_simulation WHERE user_id = 123;

EXPLAIN SYNTAX  
SELECT count() FROM shard_simulation WHERE user_id IN (1, 2, 3);

-- 不能裁剪的查询（不包含分片键）
EXPLAIN SYNTAX
SELECT count() FROM shard_simulation WHERE amount > 100;

-- -----------------------------------------------------
-- 【场景】热点分片诊断和避免
-- -----------------------------------------------------
-- 热点分片的原因:
--   1. 分片键基数低（如按城市分片，北京数据远多于其他）
--   2. 分片键值分布不均（如某些用户数据量特别大）
--   3. 分片数不合理（过多或过少）

-- 诊断热点分片
-- 【场景】生产环境定期检查分片数据分布
SELECT 
    _shard_num,
    hostName() AS host,
    count() AS row_count,
    sum(bytes_on_disk) AS disk_bytes,
    formatReadableSize(sum(bytes_on_disk)) AS disk_size
FROM clusterAllReplicas(treasurycluster, system.parts)
WHERE database = 'distributed_test' AND table = 'shard_simulation' AND active = 1
GROUP BY _shard_num, host
ORDER BY _shard_num;

-- 检查数据倾斜度
-- 【原理】变异系数（CV）衡量数据分布均匀性
-- CV < 0.1 表示非常均匀，CV > 0.3 表示严重倾斜
WITH 
    stats AS (
        SELECT 
            _shard_num,
            count() AS row_count
        FROM clusterAllReplicas(treasurycluster, system.parts)
        WHERE database = 'distributed_test' AND table = 'shard_simulation' AND active = 1
        GROUP BY _shard_num
    ),
    agg AS (
        SELECT 
            avg(row_count) AS avg_cnt,
            stddevPop(row_count) AS std_cnt
        FROM stats
    )
SELECT 
    round(avg_cnt, 0) AS avg_rows_per_shard,
    round(std_cnt, 0) AS stddev_rows,
    round(std_cnt / avg_cnt, 4) AS cv,
    multiIf(cv < 0.1, '✅ 均匀', cv < 0.3, '⚠️ 轻微倾斜', '❌ 严重倾斜') AS verdict
FROM agg;

-- -----------------------------------------------------
-- 【原理】分片数规划
-- -----------------------------------------------------
-- 分片数不是越多越好！
--
-- 分片多的优点:
--   - 数据分散，单节点存储压力小
--   - 查询并行度更高（每个分片独立执行）
--
-- 分片多的缺点:
--   - 网络开销大（跨分片数据传输）
--   - 协调节点聚合压力大
--   - 小查询延迟增加（查询多个分片的开销）
--   - 数据重分布困难
--
-- 建议:
--   - 分片数 ≤ 节点数
--   - 单分片数据量 ≥ 500GB（避免分片过小）
--   - 生产环境常见 2-8 分片
--   - 分片数 = 2^n（便于增减分片时数据迁移）
--
-- 分片数估算:
--   总数据量 100TB, 单节点推荐存储 10-20TB
--   节点数 = 100TB / 15TB ≈ 7 节点
--   分片数 = 节点数 = 8（取 2^n）
--   每个分片 = 100TB / 8 ≈ 12.5TB（合理）

-- 模拟不同分片数的性能对比
-- 【对比】分片数对查询性能的影响
-- 注意: 实际集群中分片数固定，这里只是模拟计算

-- 分片数为 4 时的数据分布
SELECT 
    cityHash64(user_id) % 4 AS shard,
    count() AS row_count,
    formatReadableSize(sum(amount)) AS amount_size
FROM shard_simulation
GROUP BY shard
ORDER BY shard;

-- 分片数为 8 时的数据分布
SELECT 
    cityHash64(user_id) % 8 AS shard,
    count() AS row_count
FROM shard_simulation
GROUP BY shard
ORDER BY shard;

-- 分片数为 16 时的数据分布
SELECT 
    cityHash64(user_id) % 16 AS shard,
    count() AS row_count
FROM shard_simulation
GROUP BY shard
ORDER BY shard;

-- -----------------------------------------------------
-- 【坑】分片键设计常见误区
-- -----------------------------------------------------
-- 1. "用时间字段做分片键"
--    问题: 时间字段通常基数低（按月/日），导致数据倾斜
--    正确做法: 时间字段作为分区键，不要作为分片键
--
-- 2. "分片键用 String 类型"
--    问题: Distributed 表的分片键必须返回整数
--    正确做法: 用 cityHash64(string_field)
--
-- 3. "分片键选主键字段"
--    问题: 主键字段不一定适合做分片键
--    正确做法: 选高基数且均匀分布的字段
--
-- 4. "分片定好后不用管"
--    问题: 业务增长可能导致数据分布变化
--    正确做法: 定期检查分片均匀性
--
-- 5. "分片数越多查询越快"
--    问题: 小查询分片多反而慢（网络开销 > 计算开销）
--    正确做法: 根据数据量和查询模式选择合适的分片数

-- -----------------------------------------------------
-- 最佳实践总结
-- -----------------------------------------------------
-- 1. 分片键优先选高基数字段: user_id, order_id, device_id
-- 2. 用 cityHash64() 或 xxHash64() 取哈希
-- 3. 避免低基数字段: status, city, gender
-- 4. 避免随机值: rand() 不利于查询裁剪
-- 5. 分片数 = 2^n, 常见 2/4/8
-- 6. 定期检查分片均匀性
-- 7. 上线前用真实数据模拟验证

-- -----------------------------------------------------
-- 清理
-- -----------------------------------------------------
DROP TABLE IF EXISTS shard_simulation;

DROP DATABASE IF EXISTS distributed_test;