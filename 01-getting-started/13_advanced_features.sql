/*
 * 13_advanced_features.sql — 高级特性入门
 *
 * 【本章解决什么问题】
 *   - TTL 怎么用？数据自动过期 vs 手动 DELETE 哪个更省资源？
 *   - 冷热数据分层存储怎么做？SSD 放热数据，HDD 放冷数据
 *   - 采样查询（SAMPLE）什么时候用？为什么能"快 10 倍代价 1% 误差"？
 *   - CTE 和子查询在 CH 怎么写？WITH 用法？
 *   - 数组函数：arrayJoin / arrayFilter / arrayMap 怎么处理 JSON 字段？
 *   - JSON 提取：JSONExtract vs visitParam vs Map 哪个快？
 *   - 异步插入 async_insert 怎么用？为什么能救高频小写场景？
 *   - PREWHERE 和 WHERE 区别？为什么 PREWHERE 能 10x 加速？
 *
 * 【原理】
 *   这些高级特性是 ClickHouse 区别于"普通列存数据库"的关键能力：
 *     - TTL + 分层存储：自动管理数据生命周期，无需外部脚本
 *     - SAMPLE：OLAP 特化的"近似查询"，用统计精度换性能
 *     - async_insert：把高频小写合并成批量写，绕过 "Too many parts"
 *     - PREWHERE：先读过滤列裁剪，再读其余列，减少 IO
 *
 * 【运行环境】
 *   - 集群：treasurycluster（CH 25.12.1.649）
 *   - 数据库：getting_started_test
 */

-- ============================================================================
-- §0. 准备
-- ============================================================================
DROP DATABASE IF EXISTS getting_started_test;
CREATE DATABASE getting_started_test;
USE getting_started_test;

-- ============================================================================
-- §1. TTL 自动过期 —— 数据生命周期管理
-- ============================================================================
-- 【原理】TTL（Time To Live）：到达时间后自动删除数据，无需手动 DELETE
--   - 比 DELETE 优势：异步、按分区整块删、不产生 mutation
--   - 必须配合 PARTITION BY 时间字段使用

-- 1.1 TTL 基础：按时间自动删除
CREATE TABLE logs_with_ttl
(
    event_time DateTime,
    level LowCardinality(String),
    message String
) ENGINE = MergeTree()
PARTITION BY toYYYYMMDD(event_time)
ORDER BY (event_time, level)
TTL event_time + INTERVAL 1 DAY;   -- 1 天后自动删除

-- 【关键】TTL 必须基于 ORDER BY 或 PARTITION BY 中的时间列
INSERT INTO logs_with_ttl
SELECT
    now() - INTERVAL number HOUR,
    ['INFO', 'WARN', 'ERROR'][1 + (number % 3)],
    concat('message_', number)
FROM numbers(48);   -- 48 小时数据，超过 24 小时的会被 TTL 删

-- 1.2 查看 TTL 状态
-- 【关键】min_date/max_date 显示 part 包含的时间范围；delete_ttl_info_min/max 显示 TTL 已处理范围
SELECT
    database,
    table,
    partition,
    min_date,
    max_date,
    rows,
    formatReadableSize(bytes_on_disk) AS size
FROM system.parts
WHERE database = 'getting_started_test'
  AND table = 'logs_with_ttl'
  AND active = 1
ORDER BY partition;

-- 1.3 TTL + 分层存储：热数据 SSD，冷数据 HDD（演示配置）
-- 【场景】日志保留 1 年：前 7 天热数据放 SSD，之后冷数据移 HDD
-- 【注意】本集群仅一个 disk，下面是配置示例（无实际多盘，仅文档演示，需在多磁盘集群执行）
-- CREATE TABLE logs_with_tiered_storage
-- (
--     event_time DateTime,
--     level LowCardinality(String),
--     message String
-- ) ENGINE = MergeTree()
-- PARTITION BY toYYYYMMDD(event_time)
-- ORDER BY (event_time, level)
-- TTL
--     event_time + INTERVAL 7 DAY TO VOLUME 'hot',     -- 7 天后移到 hot volume
--     event_time + INTERVAL 30 DAY TO VOLUME 'cold',   -- 30 天后移到 cold volume
--     event_time + INTERVAL 365 DAY DELETE;            -- 1 年后删除

-- 实际部署需要在 config.xml 配置 storage_configuration:
-- <storage_configuration>
--   <disks>
--     <ssd>...</ssd>
--     <hdd>...</hdd>
--   </disks>
--   <volumes>
--     <hot><disks><disk>ssd</disk></disks></hot>
--     <cold><disks><disk>hdd</disk></disks></cold>
--   </volumes>
-- </storage_configuration>

-- 1.4 TTL + 聚合：到期前自动预聚合（避免丢失精度）
CREATE TABLE metrics_raw_ttl
(
    metric_time DateTime,
    host LowCardinality(String),
    value Float64
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(metric_time)
ORDER BY (metric_time, host)
TTL
    metric_time + INTERVAL 1 HOUR DELETE,
    metric_time + INTERVAL 1 DAY DELETE
        WHERE host = 'test';   -- 仅删除 test 主机的过期数据

INSERT INTO metrics_raw_ttl
SELECT
    now() - INTERVAL number MINUTE,
    ['host1', 'host2', 'test'][1 + (number % 3)],
    rand() % 100
FROM numbers(120);

SELECT count() FROM metrics_raw_ttl;

-- 1.5 手动触发 TTL（一般不需要，CH 后台自动跑）
-- OPTIMIZE TABLE logs_with_ttl TTL FINAL;

-- 【TTL 设计原则】
-- ✅ TTL 列必须出现在 ORDER BY 或 PARTITION BY 中
-- ✅ TTL 按整个 partition 删，所以 PARTITION BY 粒度要匹配 TTL 粒度
-- ✅ TTL + 分区剪枝 = 天然冷热分离
-- ❌ 反例：TTL 时间 < 分区时间粒度（如 TTL 1 天但 PARTITION BY 月）
-- ❌ 反例：TTL 设过短，导致活跃 part 数爆炸

-- ============================================================================
-- §2. 分层存储 —— 冷热数据分离
-- ============================================================================
-- 【原理】CH 支持多磁盘配置，TTL 自动迁移数据
--   - hot volume：SSD，存近期热数据
--   - cold volume：HDD/S3，存历史冷数据
--   - move_factor：当 hot volume 占满 X% 时自动迁到 cold

-- 2.1 查看当前磁盘配置
SELECT
    name,
    path,
    formatReadableSize(free_space) AS free,
    formatReadableSize(total_space) AS total,
    type
FROM system.disks;

-- 2.2 查看 storage 配置（本集群为单盘，但语法相同）
-- 【关键】system.disks 关键列：name/path/free_space/total_space/is_writable
SELECT
    name AS disk_name,
    path,
    formatReadableSize(free_space) AS free,
    formatReadableSize(total_space) AS total,
    type
FROM system.disks;

-- 2.3 查看 volume 与 disk 关系
-- 【关键】system.storage_policies 列：policy_name/volume_name/volume_priority/disks/max_data_part_size/move_factor
SELECT
    policy_name,
    volume_name,
    volume_priority,
    disks,
    max_data_part_size,
    move_factor,
    prefer_not_to_merge
FROM system.storage_policies
ORDER BY policy_name, volume_priority;

-- 【生产配置示例（注释）】
-- <storage_configuration>
--   <disks>
--     <default><path>/var/lib/clickhouse/</path></default>
--     <ssd_disk><path>/mnt/ssd/</path></ssd_disk>
--     <hdd_disk><path>/mnt/hdd/</path></hdd_disk>
--     <s3_backup>
--       <type>s3</type>
--       <endpoint>https://s3.amazonaws.com/my-bucket/</endpoint>
--       <access_key_id>...</access_key_id>
--       <secret_access_key>...</secret_access_key>
--     </s3_backup>
--   </disks>
--   <policies>
--     <tiered>
--       <volumes>
--         <hot>
--           <disk>ssd_disk</disk>
--           <max_data_part_size_bytes>10737418240</max_data_part_size_bytes>  -- 10GB
--         </hot>
--         <cold>
--           <disk>hdd_disk</disk>
--         </cold>
--         <archive>
--           <disk>s3_backup</disk>
--         </archive>
--       </volumes>
--       <move_factor>0.1</move_factor>  -- hot 用满 90% 时迁到 cold
--     </tiered>
--   </policies>
-- </storage_configuration>

-- ============================================================================
-- §3. 采样查询（SAMPLE）—— 近似查询的威力
-- ============================================================================
-- 【原理】SAMPLE 按 ORDER BY 的哈希取模采样，保证"统计无偏"
--   - 比 LIMIT N 随机抽更准确（哈希采样确定性 + 无偏）
--   - 用 1% 数据估算全量，误差约 1/sqrt(sample_size)
--   - 必须在 ORDER BY 含 `intHash` 列时才可用

-- 3.1 创建带 SAMPLE 支持的表
-- 【关键】SAMPLE BY 要求：表达式必须是整数类型，且必须出现在 ORDER BY 中
CREATE TABLE events_sampled
(
    event_time DateTime,
    user_id UInt32,
    -- 必须为采样添加 intHash 列
    user_hash UInt64 MATERIALIZED intHash64(user_id),
    amount Float64
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_time, user_hash)
SAMPLE BY user_hash;   -- ← 关键：声明 SAMPLE BY 表达式

INSERT INTO events_sampled
SELECT
    now() - INTERVAL number SECOND,
    number % 10000 AS user_id,
    rand() % 1000 AS amount
FROM numbers(10000000);

-- 3.2 全量查询（基线）
SELECT
    count() AS total_events,
    sum(amount) AS total_amount,
    avg(amount) AS avg_amount,
    uniqExact(user_id) AS unique_users
FROM events_sampled
WHERE event_time >= now() - INTERVAL 1 HOUR;

-- 3.3 1% 采样查询：速度提升约 100x，误差约 10%（sqrt(1/100)）
SELECT
    count() * 100 AS est_total_events,           -- 采样后需乘回采样比例
    sum(amount) * 100 AS est_total_amount,
    avg(amount) AS est_avg_amount,                -- avg 不需要乘
    uniq(user_id) * 100 AS est_unique_users      -- uniq 是近似，已经包含采样影响
FROM events_sampled
SAMPLE 0.01
WHERE event_time >= now() - INTERVAL 1 HOUR;

-- 3.4 SAMPLE 偏移：取 1%-2% 的数据（用于多副本分担）
SELECT
    count() * 100 AS est_events_in_1_to_2_pct
FROM events_sampled
SAMPLE 0.01 OFFSET 0.01
WHERE event_time >= now() - INTERVAL 1 HOUR;

-- 3.5 SAMPLE 与 COUNT 配合：估算总行数
-- 【场景】大表估算总行数，count() 全扫太慢
SELECT count() * 100 AS est_total_rows
FROM events_sampled SAMPLE 0.01;

-- 实际总行数
SELECT count() FROM events_sampled;

-- 【SAMPLE 适用场景】
-- ✅ 大数据量估算（日志分析、指标聚合）
-- ✅ 用户行为漏斗（百万级 UV）
-- ✅ 实时大盘（不需要精确值）
-- ❌ 不适合：金额计算（财务必须精确）、低基数聚合（基数 < 1000）

-- ============================================================================
-- §4. CTE 与子查询 —— 复杂查询组织
-- ============================================================================
-- 【原理】CTE（WITH）让复杂查询可读，CH 的 CTE 是语法糖，会内联展开

-- 4.1 普通 CTE
WITH
    (SELECT avg(amount) FROM events_sampled) AS global_avg
SELECT
    user_id,
    sum(amount) AS user_total,
    count() AS user_events,
    user_total / user_events AS user_avg,
    user_avg - global_avg AS diff_from_global
FROM events_sampled
WHERE event_time >= now() - INTERVAL 1 HOUR
GROUP BY user_id
ORDER BY diff_from_global DESC
LIMIT 10;

-- 4.2 命名 CTE（CH 23.x+ 支持 WITH <name> AS）
WITH high_value_users AS
    (
        SELECT user_id
        FROM events_sampled
        GROUP BY user_id
        HAVING sum(amount) > 50000
    )
SELECT
    e.user_id,
    count() AS high_value_events,
    sum(e.amount) AS total
FROM events_sampled e
WHERE e.user_id IN (SELECT user_id FROM high_value_users)
  AND e.event_time >= now() - INTERVAL 1 DAY
GROUP BY e.user_id
ORDER BY total DESC
LIMIT 10;

-- 4.3 子查询
SELECT
    user_id,
    total_amount,
    rank_pos
FROM
(
    SELECT
        user_id,
        sum(amount) AS total_amount,
        ROW_NUMBER() OVER (ORDER BY sum(amount) DESC) AS rank_pos
    FROM events_sampled
    WHERE event_time >= now() - INTERVAL 1 HOUR
    GROUP BY user_id
)
WHERE rank_pos <= 10;

-- 4.4 CTE 在 MV 中的应用
CREATE TABLE user_summary_cte
(
    user_id UInt32,
    event_count UInt64,
    total_amount Float64
) ENGINE = MergeTree()
ORDER BY user_id;

-- 用 CTE 让 INSERT SELECT 更可读
INSERT INTO user_summary_cte
WITH
    filtered AS (
        SELECT user_id, amount
        FROM events_sampled
        WHERE event_time >= now() - INTERVAL 1 DAY
    )
SELECT
    user_id,
    count() AS event_count,
    sum(amount) AS total_amount
FROM filtered
GROUP BY user_id;

SELECT * FROM user_summary_cte ORDER BY total_amount DESC LIMIT 5;

-- ============================================================================
-- §5. 数组函数 —— 处理嵌套数据
-- ============================================================================
-- 【原理】CH 原生支持 Array(T) 类型，比 JSON 灵活，比 JOIN 快

-- 5.1 创建带数组的表
CREATE TABLE events_with_arrays
(
    event_time DateTime,
    user_id UInt32,
    tags Array(String),           -- 标签数组
    product_ids Array(UInt32),    -- 浏览过的商品 ID
    amounts Array(Float64)        -- 每个商品的金额
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_time, user_id);

INSERT INTO events_with_arrays VALUES
    ('2024-01-15 10:00:00', 1001, ['hot', 'promo', 'new'], [101, 102, 103], [99.9, 199.9, 299.9]),
    ('2024-01-15 11:00:00', 1002, ['hot', 'sale'],         [201, 202],       [49.9, 89.9]),
    ('2024-01-15 12:00:00', 1003, ['new', 'flash'],        [301],            [999.0]);

-- 5.2 arrayJoin：数组展开为多行（最常用）
-- 【场景】每个 tag 单独聚合统计
SELECT
    tag,
    count() AS tag_count
FROM events_with_arrays
ARRAY JOIN tags AS tag
GROUP BY tag
ORDER BY tag_count DESC;

-- 5.3 arrayFilter：过滤数组元素
-- 【场景】只保留金额 > 100 的商品
SELECT
    user_id,
    arrayFilter(x -> x > 100, amounts) AS high_value_amounts
FROM events_with_arrays;

-- 5.4 arrayMap：对数组元素逐个应用函数
-- 【场景】所有金额打 9 折
SELECT
    user_id,
    arrayMap(x -> x * 0.9, amounts) AS discounted_amounts
FROM events_with_arrays;

-- 5.5 arraySum / arrayAvg / arrayMax / arrayMin：数组聚合
-- 【坑】arrayCount(arr) 单参数版本要求 UInt8 数组（计非零元素）；统计数组长度用 length(arr)
SELECT
    user_id,
    arraySum(amounts) AS total_amount,
    arrayAvg(amounts) AS avg_amount,
    arrayMax(amounts) AS max_amount,
    arrayMin(amounts) AS min_amount,
    length(amounts) AS items_count
FROM events_with_arrays;

-- 5.6 arrayElement + has：访问与判断
SELECT
    user_id,
    amounts[1] AS first_amount,           -- 第一个元素（1-indexed）
    has(tags, 'hot') AS is_hot,           -- 是否含 'hot'
    hasAny(tags, ['hot', 'sale']) AS has_hot_or_sale,
    hasAll(tags, ['hot', 'promo']) AS has_hot_and_promo
FROM events_with_arrays;

-- 5.7 arrayDistinct / arraySort / arrayReverse
SELECT
    user_id,
    arrayDistinct(tags) AS distinct_tags,
    arraySort(amounts) AS sorted_amounts,
    arrayReverse(arraySort(amounts)) AS desc_amounts
FROM events_with_arrays;

-- 5.8 数组展开多列（ARRAY JOIN 多列）
SELECT
    user_id,
    product_id,
    amount
FROM events_with_arrays
ARRAY JOIN
    product_ids AS product_id,
    amounts AS amount;

-- 5.9 arrayReduce：对数组应用任意聚合函数
SELECT
    user_id,
    arrayReduce('sum', amounts) AS arr_sum,
    arrayReduce('avg', amounts) AS arr_avg,
    arrayReduce('uniq', tags) AS uniq_tags
FROM events_with_arrays;

-- ============================================================================
-- §6. JSON 提取 —— 三种方案对比
-- ============================================================================
-- 【场景】事件表有个 JSON 字符串列，需要提取字段

CREATE TABLE events_with_json
(
    event_time DateTime,
    user_id UInt32,
    event_data String    -- JSON 字符串
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_time, user_id);

INSERT INTO events_with_json VALUES
    ('2024-01-15 10:00:00', 1001, '{"page":"home","duration":30,"items":["a","b"]}'),
    ('2024-01-15 11:00:00', 1002, '{"page":"product","duration":45,"items":["c"]}'),
    ('2024-01-15 12:00:00', 1003, '{"page":"cart","duration":60,"items":["d","e","f"]}');

-- 6.1 方案 A：JSONExtract（标准 JSON，最通用）
SELECT
    event_time,
    user_id,
    JSONExtractString(event_data, 'page') AS page,
    JSONExtractInt(event_data, 'duration') AS duration,
    JSONExtractArrayRaw(event_data, 'items') AS items_raw
FROM events_with_json;

-- 6.2 方案 B：visitParam（轻量 JSON，更快，但限制多）
-- 【适用】只有一层的扁平 JSON，不嵌套
SELECT
    event_time,
    user_id,
    visitParamExtractString(event_data, 'page') AS page,
    visitParamExtractUInt(event_data, 'duration') AS duration
FROM events_with_json;

-- 6.3 方案 C：用 Map 替代 JSON（最快，但需 schema 约束）
-- 【适用】键固定且类型一致时
CREATE TABLE events_with_map
(
    event_time DateTime,
    user_id UInt32,
    event_map Map(String, String)
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_time, user_id);

INSERT INTO events_with_map VALUES
    ('2024-01-15 10:00:00', 1001, {'page': 'home', 'duration': '30'}),
    ('2024-01-15 11:00:00', 1002, {'page': 'product', 'duration': '45'});

SELECT
    event_time,
    user_id,
    event_map['page'] AS page,
    toUInt32(event_map['duration']) AS duration
FROM events_with_map;

-- 6.4 三种方案对比
-- | 方案         | 速度 | 灵活性 | 适用                       |
-- |-------------|------|-------|---------------------------|
-- | JSONExtract | 慢   | 高    | 任意嵌套 JSON              |
-- | visitParam  | 中   | 低    | 一层 JSON，无嵌套           |
-- | Map 类型    | 极快 | 低    | 键固定，类型一致，schema 已知 |

-- 【生产建议】能转 Map 就转 Map，性能差距 10-100x

-- 6.5 JSON 提取 + 数组展开组合
SELECT
    event_time,
    user_id,
    JSONExtractString(event_data, 'page') AS page,
    arr_item
FROM events_with_json
ARRAY JOIN JSONExtractArrayRaw(event_data, 'items') AS arr_item;

-- ============================================================================
-- §7. 异步插入 async_insert —— 高频小写救星
-- ============================================================================
-- 【原理】async_insert 把客户端的小批量 INSERT 缓冲到服务端，凑够批量再写入
--   - 解决"每秒几百次 INSERT"导致 part 爆炸的问题
--   - 用法：单条 INSERT 加 SETTINGS async_insert=1
--   - 代价：写入延迟增加（默认 1s 异步刷盘）

CREATE TABLE events_async
(
    event_time DateTime DEFAULT now(),
    user_id UInt32,
    amount Float64
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_time, user_id);

-- 7.1 同步插入（默认）：每条 INSERT 立即生成 1 个 part
-- 高频小写会导致 "Too many parts" 异常
INSERT INTO events_async (user_id, amount) VALUES (1001, 100.0);
INSERT INTO events_async (user_id, amount) VALUES (1002, 200.0);
INSERT INTO events_async (user_id, amount) VALUES (1003, 300.0);

-- 7.2 异步插入：服务端缓冲后批量写
INSERT INTO events_async (user_id, amount) SETTINGS async_insert = 1, wait_for_async_insert = 1
VALUES (1004, 400.0);

INSERT INTO events_async (user_id, amount) SETTINGS async_insert = 1, wait_for_async_insert = 1
VALUES (1005, 500.0);

-- 7.3 批量异步插入（更高效）
INSERT INTO events_async (user_id, amount) SETTINGS async_insert = 1, wait_for_async_insert = 0
SELECT
    number % 1000 AS user_id,
    rand() % 1000 AS amount
FROM numbers(10000);

-- 7.4 查看异步插入状态
-- 【关键】监控 system.asynchronous_inserts 看异步队列
-- 列：query/database/table/format/first_update/total_bytes/entries.query_id/entries.bytes
SELECT
    database,
    table,
    format,
    first_update,
    formatReadableSize(total_bytes) AS total_bytes,
    length(`entries.query_id`) AS pending_query_count
FROM system.asynchronous_inserts
ORDER BY first_update DESC
LIMIT 10;

-- 7.5 异步插入关键参数
-- | 参数                          | 默认 | 说明                              |
-- |------------------------------|------|----------------------------------|
-- | async_insert                 | 0    | 是否启用                          |
-- | wait_for_async_insert        | 1    | 是否等待写入完成（0=fire-and-forget） |
-- | async_insert_max_data_size   | 1MB  | 缓冲数据大小阈值                   |
-- | async_insert_busy_timeout_ms | 200  | 缓冲超时（毫秒）                   |

-- 【async_insert 适用场景】
-- ✅ 高频小写（每秒 > 100 次 INSERT）
-- ✅ 客户端无法批量（如日志采集器逐条上报）
-- ❌ 不适合：批量已 > 1万行的场景（无收益）

-- ============================================================================
-- §8. PREWHERE —— 列存查询的核武器
-- ============================================================================
-- 【原理】PREWHERE 先只读"过滤条件列"，定位匹配行后再读其余列
--   - 比 WHERE 减少最多 90% 的列存 IO
--   - 自动 PREWHERE：CH 默认会把 WHERE 中第一个条件转 PREWHERE
--   - 手动 PREWHERE：可指定选择性最高的条件先过滤

CREATE TABLE events_prewhere
(
    event_time DateTime,
    user_id UInt32,
    event_type LowCardinality(String),    -- 低基数（高选择性过滤）
    region LowCardinality(String),
    amount Float64,
    payload String                         -- 大字段（避免读取）
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_time, user_id);

INSERT INTO events_prewhere
SELECT
    now() - INTERVAL number SECOND,
    number % 1000 AS user_id,
    ['view', 'click', 'purchase'][1 + (number % 100 = 0 ? 2 : (number % 2))] AS event_type,
    ['cn-east', 'cn-north', 'cn-south'][1 + (number % 3)] AS region,
    rand() % 1000 AS amount,
    repeat('x', 1000) AS payload            -- 1KB 大字段
FROM numbers(1000000);

-- 8.1 自动 PREWHERE：CH 优化器自动选 WHERE 中条件
-- 查看 EXPLAIN，会看到有 Prewhere 步骤
EXPLAIN SYNTAX
SELECT user_id, amount
FROM events_prewhere
WHERE event_type = 'purchase' AND region = 'cn-east';

-- 8.2 手动 PREWHERE：指定选择性高的列先过滤
-- 【场景】purchase 行极少（1%），先过滤 purchase 再读 payload
SELECT user_id, amount, payload
FROM events_prewhere
PREWHERE event_type = 'purchase'    -- 先读 event_type 列，过滤 99% 行
WHERE region = 'cn-east';           -- 再读 region / amount / payload

-- 8.3 PREWHERE vs WHERE 性能对比
-- 【对比】读取字节数（通过 system.query_thread_log 查看）
SELECT count(), sum(amount)
FROM events_prewhere
WHERE event_type = 'purchase';

SELECT count(), sum(amount)
FROM events_prewhere
PREWHERE event_type = 'purchase';

-- 8.4 PREWHERE 多列：选择性从高到低排
-- 【原则】选择性最高的条件放 PREWHERE，其余放 WHERE
SELECT user_id, amount
FROM events_prewhere
PREWHERE event_type = 'purchase'    -- 选择性 1%
WHERE region = 'cn-east'            -- 选择性 33%
  AND amount > 500;                 -- 选择性 50%

-- 【PREWHERE 适用场景】
-- ✅ 大字段表（payload / json / blob 列）：先过滤再读大字段
-- ✅ 极不均衡列（event_type 99% view，1% purchase）：先过滤稀有值
-- ✅ 高选择性条件：先用选择性高的列过滤
-- ❌ 不适合：所有列大小相近 + 条件选择性都差不多（无收益）

-- 【PREWHERE 原理图】
--      WHERE 方式：读所有列 → 过滤
--      ┌─────────┬─────────┬─────────┬─────────┬─────────┐
--      │ time    │ user_id │ type    │ amount  │ payload │
--      │ 全读    │ 全读    │ 全读    │ 全读    │ 全读    │  ← 浪费！
--      └─────────┴─────────┴─────────┴─────────┴─────────┘
--                                  ↓ 过滤后保留 1% 行
--
--      PREWHERE 方式：先读 type 列 → 找到匹配行 → 再读其余列
--      ┌─────────┐
--      │ type    │  ← 只读这一列，过滤掉 99% 行
--      └─────────┘
--          ↓ 命中 1% 行
--      ┌─────────┬─────────┬─────────┬─────────┐
--      │ time    │ user_id │ amount  │ payload │  ← 只读这 1% 行的列
--      └─────────┴─────────┴─────────┴─────────┘
--      IO 减少 99%

-- ============================================================================
-- §9. 高级特性组合实战
-- ============================================================================
-- 【场景】实时日志分析：高频小写 + MV 预聚合 + TTL 自动清理 + 字典补充维度

-- 9.1 维表（字典源）
CREATE TABLE dim_log_source
(
    source_id UInt16,
    source_name String,
    team LowCardinality(String)
) ENGINE = MergeTree()
ORDER BY source_id;

INSERT INTO dim_log_source VALUES
    (1, 'web-frontend', 'FE'),
    (2, 'mobile-app',   'Mobile'),
    (3, 'backend-api',  'BE'),
    (4, 'scheduler',    'Data');

-- 【坑】字典属性不支持 LowCardinality(String)，必须用普通 String
DROP DICTIONARY IF EXISTS log_source_dict;
CREATE DICTIONARY log_source_dict
(
    source_id UInt16,
    source_name String,
    team String
)
PRIMARY KEY source_id
SOURCE(CLICKHOUSE(TABLE 'dim_log_source' DB 'getting_started_test'))
LAYOUT(HASHED())
LIFETIME(MIN 300 MAX 3600);

SYSTEM RELOAD DICTIONARY log_source_dict;

-- 9.2 原始日志表（TTL 30 天自动清理）
CREATE TABLE logs_raw_advanced
(
    log_time DateTime DEFAULT now(),
    source_id UInt16,
    level LowCardinality(String),
    message String
) ENGINE = MergeTree()
PARTITION BY toYYYYMMDD(log_time)
ORDER BY (log_time, source_id)
TTL log_time + INTERVAL 30 DAY;

-- 9.3 预聚合目标表（按分钟聚合，TTL 90 天）
CREATE TABLE logs_per_minute
(
    minute DateTime,
    source_id UInt16,
    level LowCardinality(String),
    log_count UInt64
) ENGINE = SummingMergeTree()
PARTITION BY toYYYYMM(minute)
ORDER BY (minute, source_id, level)
TTL minute + INTERVAL 90 DAY;

-- 9.4 MV：原始表 INSERT 时自动聚合到分钟表
-- 【坑】CH 函数名是 toStartOfMinute，不是 toStartMinute（同理 toStartOfHour/toStartOfDay）
CREATE MATERIALIZED VIEW mv_logs_per_minute
TO logs_per_minute
AS
SELECT
    toStartOfMinute(log_time) AS minute,
    source_id,
    level,
    count() AS log_count
FROM logs_raw_advanced
GROUP BY minute, source_id, level;

-- 9.5 模拟高频写入（用 async_insert）
INSERT INTO logs_raw_advanced (source_id, level, message)
SETTINGS async_insert = 1, wait_for_async_insert = 0
SELECT
    (number % 4) + 1 AS source_id,
    ['INFO', 'WARN', 'ERROR'][1 + (number % 3)] AS level,
    concat('msg_', number) AS message
FROM numbers(50000);

-- 9.6 查询：字典补维度 + 预聚合表 + 近期过滤
SELECT
    m.minute,
    dictGet('log_source_dict', 'source_name', m.source_id) AS source_name,
    dictGet('log_source_dict', 'team', m.source_id) AS team,
    m.level,
    sum(m.log_count) AS total_logs
FROM logs_per_minute m
WHERE m.minute >= now() - INTERVAL 1 HOUR
GROUP BY m.minute, source_name, team, m.level
ORDER BY m.minute DESC, total_logs DESC
LIMIT 20;

-- 9.7 异常级别告警（用 PREWHERE 加速）
SELECT
    dictGet('log_source_dict', 'source_name', source_id) AS source_name,
    count() AS error_count,
    min(log_time) AS first_error,
    max(log_time) AS last_error
FROM logs_raw_advanced
PREWHERE level = 'ERROR'        -- 先过滤 ERROR（小比例）
WHERE log_time >= now() - INTERVAL 1 HOUR
GROUP BY source_name
ORDER BY error_count DESC;

-- ============================================================================
-- §10. 高级特性决策矩阵
-- ============================================================================
-- 【按场景选特性】
-- | 场景                  | 推荐特性                    | 收益             |
-- |---------------------|----------------------------|-----------------|
-- | 数据生命周期管理       | TTL + 分层存储              | 自动清理 + 冷热分离 |
-- | 大数据量估算          | SAMPLE 1%                  | 100x 加速，10% 误差 |
-- | 复杂查询组织          | CTE (WITH)                 | 可读性提升        |
-- | 标签/数组数据         | arrayJoin / arrayMap       | 避免多表 JOIN     |
-- | JSON 字段提取         | JSONExtract / Map          | Map 最快          |
-- | 高频小写              | async_insert               | 避免 part 爆炸    |
-- | 大字段表查询          | PREWHERE                   | 减少 90%+ IO     |

-- 【组合模式】
-- 1. 实时日志：原始表 + async_insert + MV 预聚合 + TTL 自动清理
-- 2. 用户行为：宽表 + 字典补维度 + PREWHERE 加速大字段
-- 3. 监控指标：长表 + SAMPLE 估算 + CTE 复杂分析
-- 4. 嵌套数据：Array 类型 + arrayJoin 展开 + arrayMap 转换

-- ============================================================================
-- §11. 清理与小结
-- ============================================================================
-- 【本章核心结论】
-- 1. TTL：数据自动过期 + 分层存储，比 DELETE 高效 100x
-- 2. SAMPLE：OLAP 特化近似查询，大数据量估算神器
-- 3. CTE：让复杂查询可读，CH 自动内联展开
-- 4. 数组函数：arrayJoin/arrayFilter/arrayMap 是处理嵌套数据的瑞士军刀
-- 5. JSON：能用 Map 就别用 JSONExtract，性能差 10-100x
-- 6. async_insert：高频小写救星，避免 "Too many parts"
-- 7. PREWHERE：列存查询核武器，大字段表加速 10x+

-- 清理（保留表结构便于回看）
-- DROP DATABASE IF EXISTS getting_started_test;
