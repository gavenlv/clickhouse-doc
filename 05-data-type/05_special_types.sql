/*
 * 05_special_types.sql — 特殊类型详解（Enum / UUID / IPv4/IPv6 / Nullable / JSON / Bool）
 *
 * 【本章解决什么问题】
 *   - Enum8/Enum16 和 LowCardinality(String) 怎么选？
 *   - UUID 在 CH 中怎么存？generateUUIDv4 怎么用？
 *   - IPv4/IPv6 为什么比 String 存储省空间？查询更快？
 *   - Nullable 的 NULL 掩码怎么工作？性能开销多大？
 *   - JSON 类型（实验）怎么用？和 String+JSONExtract 比哪个好？
 *   - CH 没有 Bool 类型，怎么模拟？
 *
 * 【原理】
 *   特殊类型是 ClickHouse 的"列式优化"的极致体现：
 *   - Enum: 存储为 Int8/Int16，查询时映射为字符串
 *   - UUID: 存储为 Int128，16 字节固定长度
 *   - IPv4/IPv6: 存储为 UInt32 和 Int128，比 String 省 4-8x
 *   - Nullable: 额外存储 NULL 掩码列
 *   - JSON（实验）: 自动提取 JSON 字段为子列
 *
 * 【运行环境】
 *   - 集群：treasurycluster（CH 25.12.1.649）
 *   - 数据库：data_type_test
 */

-- ============================================================================
-- §0. 准备
-- ============================================================================
DROP DATABASE IF EXISTS data_type_test;
CREATE DATABASE data_type_test;
USE data_type_test;

-- ============================================================================
-- §1. Enum8 / Enum16 —— 枚举类型
-- ============================================================================
-- 【原理】Enum 存为 Int8/Int16，查询时映射为字符串
--         Enum8: 最多 128 个值，1 字节
--         Enum16: 最多 32768 个值，2 字节
-- 【场景】状态码、类型分类、固定选项

-- 1.1 创建带 Enum 的表
CREATE TABLE events_with_enum
(
    event_time DateTime,
    user_id UInt32,
    status Enum8('active' = 1, 'inactive' = 0, 'pending' = 2),  -- 定义枚举值 <=> 整数映射
    event_type Enum8('click' = 1, 'view' = 2, 'purchase' = 3, 'refund' = 4),
    priority Enum16('low' = 10, 'medium' = 50, 'high' = 100, 'critical' = 1000)
) ENGINE = MergeTree()
ORDER BY (event_time, user_id);

INSERT INTO events_with_enum VALUES
    ('2024-01-15 10:00:00', 1001, 'active', 'purchase', 'high'),
    ('2024-01-15 11:00:00', 1002, 'active', 'click', 'low'),
    ('2024-01-15 12:00:00', 1003, 'pending', 'view', 'medium'),
    ('2024-01-15 13:00:00', 1004, 'inactive', 'refund', 'critical');

-- 1.2 查询 Enum（显示为字符串）
SELECT
    event_time,
    user_id,
    status,
    event_type,
    priority
FROM events_with_enum;

-- 1.3 Enum 内部整数值
SELECT
    status,
    CAST(status, 'Int8') AS status_int,          -- 转为 Int8
    CAST(event_type, 'Int8') AS type_int,
    CAST(priority, 'Int16') AS priority_int
FROM events_with_enum;

-- 1.4 Enum 条件过滤
SELECT
    count() AS events,
    event_type,
    status
FROM events_with_enum
WHERE event_type IN ('purchase', 'refund')
  AND status = 'active'
GROUP BY event_type, status;

-- 1.5 Enum vs LowCardinality(String) 对比
-- 【对比】Enum 更省空间（1-2 字节 vs 字典索引也是 1-2 字节）
--         Enum 更严格（新增值需 ALTER TABLE）
--         LowCardinality 更灵活（可随时插新值）
-- 推荐：固定值集用 Enum，可变值集用 LowCardinality(String)

-- 1.6 扩展 Enum（需 ALTER）
ALTER TABLE events_with_enum MODIFY COLUMN
    event_type Enum8('click' = 1, 'view' = 2, 'purchase' = 3, 'refund' = 4, 'share' = 5);

-- 验证新值
INSERT INTO events_with_enum VALUES ('2024-01-15 14:00:00', 1005, 'active', 'share', 'low');
SELECT event_type, count() FROM events_with_enum GROUP BY event_type;

-- ============================================================================
-- §2. UUID —— 通用唯一标识符
-- ============================================================================
-- 【原理】UUID 存储为 Int128（16 字节），比 String(36) 省 20+ 字节

-- 2.1 创建带 UUID 的表
CREATE TABLE events_with_uuid
(
    event_id UUID,
    event_time DateTime,
    user_id UInt32,
    description String
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_time, user_id);

-- 2.2 生成 UUID
INSERT INTO events_with_uuid VALUES
    (generateUUIDv4(), '2024-01-15 10:00:00', 1001, 'First event'),
    (generateUUIDv4(), '2024-01-15 11:00:00', 1002, 'Second event'),
    (generateUUIDv4(), '2024-01-15 12:00:00', 1003, 'Third event');

-- 2.3 查询 UUID
SELECT
    event_id,
    event_time,
    user_id,
    description
FROM events_with_uuid;

-- 2.4 UUID 处理函数
SELECT
    event_id,
    UUIDStringToNum(event_id) AS uuid_as_int128,        -- 转为 Int128
    UUIDNumToString(uuid_as_int128) AS uuid_back,        -- 转回字符串
    empty(event_id) AS is_empty,
    toUUID('00000000-0000-0000-0000-000000000000') AS nil_uuid,
    empty(nil_uuid) AS nil_is_empty   -- TRUE
FROM events_with_uuid
LIMIT 1;

-- 2.5 UUID 存储大小对比
-- 【对比】UUID（16 字节）vs String(36)（36 字节）
-- 建两种表对比
CREATE TABLE uuid_test
(
    id UUID
) ENGINE = MergeTree()
ORDER BY id;

CREATE TABLE str_test
(
    id String
) ENGINE = MergeTree()
ORDER BY id;

INSERT INTO uuid_test SELECT generateUUIDv4() FROM numbers(100000);
INSERT INTO str_test SELECT toString(generateUUIDv4()) FROM numbers(100000);

SELECT
    'UUID' AS type,
    formatReadableSize(sum(bytes)) AS total_size
FROM system.parts
WHERE table = 'uuid_test' AND active = 1
UNION ALL
SELECT
    'String' AS type,
    formatReadableSize(sum(bytes)) AS total_size
FROM system.parts
WHERE table = 'str_test' AND active = 1;

-- 【结果】UUID 存储比 String 省 2x+ 空间

-- ============================================================================
-- §3. IPv4 / IPv6 —— 网络地址类型
-- ============================================================================
-- 【原理】IPv4 存为 UInt32（4 字节），IPv6 存为 Int128（16 字节）
--        比 String(15)/(39) 省 4-5x 空间，且支持范围查询

-- 3.1 创建带 IP 类型的表
CREATE TABLE events_with_ip
(
    event_time DateTime,
    user_id UInt32,
    ipv4 IPv4,
    ipv6 IPv6
) ENGINE = MergeTree()
ORDER BY (event_time, user_id);

INSERT INTO events_with_ip VALUES
    ('2024-01-15 10:00:00', 1001, '192.168.1.1', '::1'),
    ('2024-01-15 11:00:00', 1002, '10.0.0.1', '2001:db8::1'),
    ('2024-01-15 12:00:00', 1003, '172.16.0.1', 'fe80::1');

-- 3.2 IP 查询
SELECT
    user_id,
    ipv4,
    ipv6,
    IPv4NumToString(ipv4) AS ipv4_str,       -- 转为字符串
    IPv6NumToString(ipv6) AS ipv6_str,
    toIPv4('192.168.1.100') AS manual_ipv4,
    toIPv6('::1') AS manual_ipv6
FROM events_with_ip;

-- 3.3 IP 范围查询
-- 【场景】按 IP 段过滤
SELECT
    ipv4,
    user_id
FROM events_with_ip
WHERE ipv4 BETWEEN toIPv4('192.168.0.0') AND toIPv4('192.168.255.255');

-- 3.4 IP 存储大小对比
CREATE TABLE ipv4_test (ip IPv4) ENGINE = MergeTree() ORDER BY ip;
CREATE TABLE ip_str_test (ip String) ENGINE = MergeTree() ORDER BY ip;

INSERT INTO ipv4_test SELECT toIPv4(concat(
    toString(rand() % 256), '.',
    toString(rand() % 256), '.',
    toString(rand() % 256), '.',
    toString(rand() % 256)
)) FROM numbers(100000);

INSERT INTO ip_str_test SELECT concat(
    toString(rand() % 256), '.',
    toString(rand() % 256), '.',
    toString(rand() % 256), '.',
    toString(rand() % 256)
) FROM numbers(100000);

SELECT
    'IPv4' AS type,
    formatReadableSize(sum(bytes)) AS total_size
FROM system.parts
WHERE table = 'ipv4_test' AND active = 1
UNION ALL
SELECT
    'String' AS type,
    formatReadableSize(sum(bytes)) AS total_size
FROM system.parts
WHERE table = 'ip_str_test' AND active = 1;

-- 【结果】IPv4（4 字节）比 String（~15 字节）省 3-4x 空间

-- ============================================================================
-- §4. Nullable(T) —— 可空类型
-- ============================================================================
-- 【原理】Nullable(T) 额外存一个 NULL 掩码列（每行 1 bit）
-- 【场景】可选字段、缺失值

-- 4.1 Nullable 存储开销
CREATE TABLE nullable_demo
(
    id UInt8,
    age UInt8,
    age_nullable Nullable(UInt8),
    name String,
    name_nullable Nullable(String)
) ENGINE = MergeTree()
ORDER BY id;

INSERT INTO nullable_demo VALUES
    (1, 25, 25, 'Alice', 'Alice'),
    (2, 30, NULL, 'Bob', NULL),
    (3, NULL, 35, NULL, 'Charlie');

-- 4.2 查看列数差异
-- 【关键】Nullable 列在 system.columns 中显示为多列（数据列 + NULL 掩码列）
SELECT
    name,
    type,
    formatReadableSize(data_compressed_bytes) AS compressed
FROM system.columns
WHERE database = 'data_type_test'
  AND table = 'nullable_demo'
ORDER BY position;

-- 4.3 Nullable 查询处理
SELECT
    id,
    age,
    age_nullable,
    isNull(age_nullable) AS is_null,
    isNotNull(age_nullable) AS is_not_null,
    coalesce(age_nullable, 0) AS with_default,  -- NULL 替换为 0
    ifNull(age_nullable, 0) AS also_default
FROM nullable_demo;

-- 4.4 Nullable 不能作为主键/排序键
-- 【坑】以下语句会报错
-- CREATE TABLE bad_table (id Nullable(UInt64), value String) ENGINE = MergeTree() ORDER BY id;

-- 4.5 Nullable 性能对比
-- 【场景】大量 NULL 值的聚合性能
CREATE TABLE nullable_perf_test (val Nullable(UInt64)) ENGINE = MergeTree() ORDER BY tuple();
INSERT INTO nullable_perf_test SELECT if(number % 3 = 0, NULL, number) FROM numbers(1000000);

-- 聚合 Nullable 列
SELECT
    count(val) AS non_null_count,          -- 自动跳过 NULL
    sum(val) AS total,                     -- 自动跳过 NULL
    avg(val) AS avg_val,                   -- 自动跳过 NULL
    count() AS total_rows
FROM nullable_perf_test;

-- 【对比】如果不想用 Nullable，可以用 DEFAULT 值替代
-- 推荐：必填字段用 DEFAULT，可选字段（少量 NULL）用 Nullable

-- ============================================================================
-- §5. 布尔类型模拟
-- ============================================================================
-- 【原理】ClickHouse 没有独立的 Bool 类型，用 UInt8（0/1）模拟

-- 5.1 布尔模拟
CREATE TABLE bool_demo
(
    id UInt8,
    is_active UInt8,        -- 0/1 模拟布尔
    is_deleted UInt8,       -- 0/1
    status String
) ENGINE = MergeTree()
ORDER BY id;

INSERT INTO bool_demo VALUES
    (1, 1, 0, '正常'),
    (2, 1, 0, '正常'),
    (3, 0, 1, '已删除');

-- 5.2 布尔查询
SELECT
    id,
    is_active = 1 AS active,           -- 转为布尔表达式
    is_active AS active_raw,            -- 0/1
    is_active AND is_deleted = 0 AS valid,  -- 逻辑运算
    if(is_active = 1, '是', '否') AS active_text
FROM bool_demo;

-- 5.3 布尔聚合
SELECT
    sum(is_active) AS active_count,     -- 布尔值直接 sum
    countIf(is_active = 1) AS active_count_alt,
    avg(is_active) AS active_ratio      -- 活跃比例
FROM bool_demo;

-- ============================================================================
-- §6. JSON 类型（实验性）
-- ============================================================================
-- 【原理】CH 23.x+ 实验性 JSON 类型，自动解析 JSON 为子列
-- 【场景】半结构化日志、动态 schema

-- 6.1 启用 JSON 类型（实验性）
SET allow_experimental_json_type = 1;

-- 6.2 创建带 JSON 类型的表
CREATE TABLE events_with_json_type
(
    event_time DateTime,
    user_id UInt32,
    payload JSON
) ENGINE = MergeTree()
ORDER BY (event_time, user_id);

INSERT INTO events_with_json_type VALUES
    ('2024-01-15 10:00:00', 1001, '{"page":"home","action":"click","duration":1.5,"tags":["hot","new"]}'),
    ('2024-01-15 11:00:00', 1002, '{"page":"product","product_id":101,"action":"view","duration":3.2}'),
    ('2024-01-15 12:00:00', 1003, '{"page":"checkout","action":"purchase","amount":99.99,"items":3}');

-- 6.3 JSON 子列查询
SELECT
    event_time,
    user_id,
    payload.page AS page,
    payload.action AS action,
    payload.duration AS duration,
    payload.amount AS amount
FROM events_with_json_type;

-- 6.4 JSON 类型和 String+JSONExtract 对比
-- 【对比】JSON 类型：自动建子列，查询更快，写入更慢
--         String+JSONExtract：灵活，但查询需解析
-- 推荐：明确字段用 Map 或 Tuple，半结构化用 JSON 类型

-- 6.5 查看 JSON 子列
SELECT
    name,
    type,
    formatReadableSize(data_compressed_bytes) AS compressed
FROM system.columns
WHERE database = 'data_type_test'
  AND table = 'events_with_json_type'
ORDER BY position;

-- ============================================================================
-- §7. 特殊类型选型决策树
-- ============================================================================
-- 字段是什么?
--   │
--   ├─ 固定选项
--   │   ├─ 值固定不变 → Enum8/Enum16（1-2 字节，最省）
--   │   └─ 值可能增加 → LowCardinality(String)（灵活）
--   │
--   ├─ 标识符
--   │   ├─ UUID → UUID 类型（16 字节，比 String 省 2x）
--   │   └─ 自增 ID → UInt64（8 字节）
--   │
--   ├─ 网络地址
--   │   ├─ IPv4 → IPv4 类型（4 字节，比 String 省 4x）
--   │   └─ IPv6 → IPv6 类型（16 字节，比 String 省 2x）
--   │
--   ├─ 可空
--   │   ├─ 少量 NULL → Nullable(T)（有掩码开销）
--   │   └─ 多数有值 → DEFAULT 值（无开销）
--   │
--   ├─ 布尔 → UInt8（0/1）
--   │
--   └─ 半结构化
--       ├─ 键值对 → Map(K,V)（查询快）
--       ├─ 异构 → JSON 类型（自动子列）
--       └─ 通用 → String + JSONExtract（灵活）

-- ============================================================================
-- §8. 清理
-- ============================================================================
DROP TABLE IF EXISTS events_with_enum;
DROP TABLE IF EXISTS events_with_uuid;
DROP TABLE IF EXISTS uuid_test;
DROP TABLE IF EXISTS str_test;
DROP TABLE IF EXISTS events_with_ip;
DROP TABLE IF EXISTS ipv4_test;
DROP TABLE IF EXISTS ip_str_test;
DROP TABLE IF EXISTS nullable_demo;
DROP TABLE IF EXISTS nullable_perf_test;
DROP TABLE IF EXISTS bool_demo;
DROP TABLE IF EXISTS events_with_json_type;
DROP DATABASE IF EXISTS data_type_test;

-- ============================================================================
-- §9. 自测题
-- ============================================================================
-- 1. Enum8 和 LowCardinality(String) 的核心区别是什么？各适合什么场景？
-- 2. UUID 类型内部存储为 Int128，为什么比 String(36) 省空间？省多少？
-- 3. IPv4 类型比 String 存储 IP 地址省多少空间？为什么？
-- 4. Nullable(UInt8) 比普通 UInt8 多了什么额外开销？
-- 5. ClickHouse 为什么没有独立的 Bool 类型？用什么替代？
-- 6. JSON 类型和 String+JSONExtract 的优缺点对比？