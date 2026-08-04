/*
 * 01_all_data_mutation.sql — 数据变更全攻略（合并自 09-data-deletion + 11-data-update）
 *
 * 【本章解决什么问题】
 *   - ClickHouse 为什么不适合频繁更新删除？底层机制是什么？
 *   - 删除/更新大量数据用什么方法最快？
 *   - 如何自动清理过期数据，不需要手动干预？
 *   - 少量数据修改怎么高效？轻量操作和 Mutation 的区别？
 *   - 删除/更新怎么监控进度？卡住了怎么处理？
 *   - 如何高效写入大量数据，避免 Mutation 产生？
 *   - 异步插入的队列机制是什么？和 Buffer 表怎么选？
 *   - 变更操作和查询的并发隔离级别？
 *   - 生产环境有哪些典型的数据变更方案？
 *
 * 【原理】
 *   ClickHouse 的 ALTER TABLE UPDATE/DELETE 不是原地修改，而是创建新的 Part 版本。
 *   变更操作是异步的，会产生写放大，频繁操作会导致 Part 数量爆炸。
 *   最佳实践是：优先分区操作 > TTL > 轻量操作 > Mutation（最后手段）。
 *
 * 【运行环境】
 *   - 集群：treasurycluster（CH 25.12.1.649）
 *   - 数据库：mutation_test
 *
 * 【内容结构】
 *   §1  Mutation 原理与操作
 *   §2  分区操作（DROP/MOVE/REPLACE/EXCHANGE）
 *   §3  TTL（行级/列级/GROUP BY）
 *   §4  轻量操作（DELETE/UPDATE）
 *   §5  Mutation 监控与排错
 *   §6  批量写入优化
 *   §7  异步插入
 *   §8  并发与隔离
 *   §9  实战案例
 */

-- ============================================================================
-- §0. 准备
-- ============================================================================
DROP DATABASE IF EXISTS mutation_test;
CREATE DATABASE mutation_test;
USE mutation_test;

-- ============================================================================
-- §1. Mutation 原理与操作
-- ============================================================================
-- 【原理】Mutation 是异步的，提交后立即返回，后台执行。
--         每个 Mutation 产生一个新的 Part 版本，旧 Part 标记为非活跃。
--         频繁 Mutation 导致 Part 数量爆炸，严重影响查询性能。
--
--         执行流程：
--         1. 提交 ALTER TABLE UPDATE/DELETE → 写入 mutation_log
--         2. 后台对每个 Part 执行变更 → 生成新 Part
--         3. 新 Part 替换旧 Part → 旧 Part 标记为 inactive
--         4. 后台合并清理 inactive Part

-- 1.1 创建测试表
CREATE TABLE mutation_demo
(
    id UInt32,
    name String,
    status String,
    amount Float64,
    event_time DateTime
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (id, event_time);

-- 插入测试数据
INSERT INTO mutation_demo VALUES
    (1, 'Alice', 'active', 100.0, '2024-01-15 10:00:00'),
    (2, 'Bob', 'active', 200.0, '2024-01-15 11:00:00'),
    (3, 'Charlie', 'inactive', 150.0, '2024-01-16 10:00:00'),
    (4, 'David', 'active', 300.0, '2024-02-01 10:00:00'),
    (5, 'Eve', 'pending', 250.0, '2024-02-15 10:00:00'),
    (6, 'Frank', 'inactive', 50.0, '2024-03-01 10:00:00');

-- 1.2 Mutation DELETE —— 按条件删除
-- 【场景】删除特定条件的行（如已离职用户、过期数据）
-- 【注意】Mutation 是异步的，不会立即生效
ALTER TABLE mutation_demo
DELETE WHERE status = 'inactive';

-- 查看 Mutation 状态
SELECT
    database,
    table,
    command,
    is_done,
    latest_failed_part,
    latest_fail_time
FROM system.mutations
WHERE database = 'mutation_test'
  AND table = 'mutation_demo'
ORDER BY create_time DESC
LIMIT 5;

-- 等待 Mutation 完成（生产环境应通过监控轮询，不是用 sleep）
SELECT sleep(1);

-- 验证删除结果
SELECT * FROM mutation_demo ORDER BY id;

-- 1.3 Mutation UPDATE —— 按条件更新
-- 【场景】批量修改数据（如调整价格、更新状态）
ALTER TABLE mutation_demo
UPDATE status = 'processed'
WHERE amount > 150;

SELECT sleep(1);

-- 验证更新结果
SELECT * FROM mutation_demo ORDER BY id;

-- 1.4 Mutation 注意事项
-- 【坑】Mutation 不是事务，不可回滚
-- 【坑】大量 Mutation 导致 Part 增多，查询变慢
-- 【坑】主键/排序键列不能更新
-- 【坑】UPDATE 和 DELETE 不能在同一条 ALTER 中执行

-- 查看当前 Part 数量（验证 Mutation 产生新 Part）
SELECT
    table,
    count() AS part_count,
    countIf(active = 1) AS active_parts,
    countIf(active = 0) AS inactive_parts
FROM system.parts
WHERE database = 'mutation_test'
  AND table = 'mutation_demo'
GROUP BY table;

-- ============================================================================
-- §2. 分区操作（最快，推荐）
-- ============================================================================
-- 【原理】分区操作不涉及数据重写，只修改元数据，因此最快。
--         DROP PARTITION：删除整个分区（秒级）
--         MOVE PARTITION：跨表/跨磁盘移动（秒级）
--         REPLACE PARTITION：用另一表分区替换（秒级）
--         EXCHANGE PARTITION：交换分区（原子操作）

-- 2.1 创建分区测试表
CREATE TABLE partition_demo
(
    id UInt32,
    data String,
    event_time Date
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (id, event_time);

INSERT INTO partition_demo VALUES
    (1, 'Jan data', '2024-01-15'),
    (2, 'Jan data 2', '2024-01-20'),
    (3, 'Feb data', '2024-02-15'),
    (4, 'Feb data 2', '2024-02-20'),
    (5, 'Mar data', '2024-03-15'),
    (6, 'Mar data 2', '2024-03-20');

-- 2.2 查看分区
SELECT
    partition,
    name AS part_name,
    rows,
    formatReadableSize(bytes_on_disk) AS size
FROM system.parts
WHERE database = 'mutation_test'
  AND table = 'partition_demo'
  AND active = 1
ORDER BY partition;

-- 2.3 DROP PARTITION —— 删除整个分区
-- 【场景】清理历史数据（如只保留最近 3 个月）
-- 【速度】秒级，不产生 Mutation
ALTER TABLE partition_demo
DROP PARTITION '2024-01';

SELECT sleep(1);

-- 验证：1 月数据已删除
SELECT * FROM partition_demo ORDER BY id;

-- 2.4 MOVE PARTITION —— 跨表移动分区
-- 【场景】数据归档：将旧分区移到归档表
-- 创建归档表（结构相同）
CREATE TABLE archive_demo
(
    id UInt32,
    data String,
    event_time Date
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (id, event_time);

-- 将 2 月分区移动到归档表
ALTER TABLE partition_demo
MOVE PARTITION '2024-02' TO TABLE archive_demo;

SELECT sleep(1);

-- 验证：原表 2 月数据已删除
SELECT 'partition_demo' AS table_name, * FROM partition_demo ORDER BY id;
SELECT 'archive_demo' AS table_name, * FROM archive_demo ORDER BY id;

-- 2.5 REPLACE PARTITION —— 用另一表分区替换
-- 【场景】批量更新：用新数据替换整个分区
-- 准备新数据
CREATE TABLE new_data_demo
(
    id UInt32,
    data String,
    event_time Date
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (id, event_time);

-- 插入新的 3 月数据（替换旧数据）
INSERT INTO new_data_demo VALUES
    (5, 'Mar data - corrected', '2024-03-15'),
    (6, 'Mar data 2 - corrected', '2024-03-20'),
    (7, 'Mar data 3 - new', '2024-03-25');

-- 替换原表 3 月分区
ALTER TABLE partition_demo
REPLACE PARTITION '2024-03' FROM new_data_demo;

SELECT sleep(1);

-- 验证：3 月数据已被替换
SELECT * FROM partition_demo ORDER BY id;

-- 2.6 EXCHANGE PARTITION —— 原子交换分区
-- 【场景】零停机分区替换
-- 【注意】EXCHANGE 是原子操作，但要求两张表结构完全相同
-- 本例中 new_data_demo 和 partition_demo 结构相同
-- 将 new_data_demo 的 3 月分区与 partition_demo 的 3 月分区交换
ALTER TABLE partition_demo EXCHANGE PARTITION '2024-03' WITH TABLE new_data_demo;

SELECT sleep(1);

-- 验证：两个表的 3 月分区已交换
SELECT 'partition_demo' AS table_name, * FROM partition_demo ORDER BY id;
SELECT 'new_data_demo' AS table_name, * FROM new_data_demo ORDER BY id;

-- ============================================================================
-- §3. TTL（自动数据过期）
-- ============================================================================
-- 【原理】TTL（Time-To-Live）是 ClickHouse 的自动数据过期机制。
--         在后台合并时执行，不是实时触发。
--         支持三种级别：
--         行级 TTL：整行过期后删除
--         列级 TTL：列值过期后清空或置为默认值
--         GROUP BY TTL：降采样聚合后过期

-- 3.1 行级 TTL
-- 【场景】日志表自动清理 90 天前的数据
CREATE TABLE ttl_row_demo
(
    id UInt32,
    event_time DateTime,
    data String
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (id, event_time)
TTL event_time + INTERVAL 90 DAY;  -- 90 天后自动删除

-- 3.2 列级 TTL
-- 【场景】敏感数据自动脱敏（如 30 天后清空 IP 地址）
CREATE TABLE ttl_column_demo
(
    id UInt32,
    event_time DateTime,
    ip_address String TTL event_time + INTERVAL 30 DAY,  -- 30 天后清空
    data String
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (id, event_time);

-- 3.3 修改 TTL
-- 【场景】调整数据保留策略
ALTER TABLE ttl_row_demo
MODIFY TTL event_time + INTERVAL 180 DAY;  -- 改为 180 天

-- 3.4 查看 TTL 配置
SELECT
    table,
    expression,
    min(ttl_expression) AS ttl_expr
FROM system.parts
WHERE database = 'mutation_test'
  AND table LIKE 'ttl_%'
  AND active = 1
GROUP BY table, expression;

-- 3.5 TTL 注意事项
-- 【坑】TTL 不是实时触发的，默认合并间隔由 merge_with_ttl_timeout 控制
-- 【坑】频繁 TTL 删除会触发后台合并，消耗 I/O
-- 【坑】TTL 列不会被删除，只是置为数据类型的默认值
-- 推荐：TTL 用于自动清理，分区删除用于手动立即清理

-- ============================================================================
-- §4. 轻量操作（CH 23.8+，优先使用）
-- ============================================================================
-- 【原理】轻量操作不像 Mutation 那样重写整个 Part，而是写一个"删除/更新标记"。
--         查询时根据标记过滤，标记在下次合并时真正清理。
--         比 Mutation 快很多，资源消耗低。

-- 4.1 创建测试表
CREATE TABLE lightweight_demo
(
    id UInt32,
    name String,
    status String,
    amount Float64,
    event_time DateTime
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (id, event_time);

INSERT INTO lightweight_demo VALUES
    (1, 'Alice', 'active', 100.0, '2024-01-15 10:00:00'),
    (2, 'Bob', 'active', 200.0, '2024-01-15 11:00:00'),
    (3, 'Charlie', 'inactive', 150.0, '2024-01-16 10:00:00'),
    (4, 'David', 'active', 300.0, '2024-02-01 10:00:00');

-- 4.2 轻量 DELETE
-- 【场景】删除少量数据行
-- 【注意】CH 23.8+，默认开启 lightweight_delete
ALTER TABLE lightweight_demo
DELETE WHERE id = 3;

SELECT sleep(1);

-- 验证
SELECT * FROM lightweight_demo ORDER BY id;

-- 4.3 轻量 UPDATE
-- 【场景】更新少量数据行
ALTER TABLE lightweight_demo
UPDATE status = 'updated'
WHERE id = 2;

SELECT sleep(1);

-- 验证
SELECT * FROM lightweight_demo ORDER BY id;

-- 4.4 轻量操作 vs Mutation 对比
-- 【对比】
-- 轻量操作：写标记，快，资源少，适合少量数据
-- Mutation：重写 Part，慢，资源多，适合大量数据
-- 推荐：轻量操作优先，Mutation 是最后手段

-- ============================================================================
-- §5. Mutation 监控与排错
-- ============================================================================

-- 5.1 查看 Mutation 队列
SELECT
    database,
    table,
    mutation_id,
    command,
    create_time,
    block_numbers.partition_id AS partition_id,
    is_done,
    latest_failed_part,
    latest_fail_time,
    latest_fail_reason
FROM system.mutations
WHERE database = 'mutation_test'
ORDER BY create_time DESC;

-- 5.2 查看正在运行的 Mutation
SELECT
    database,
    table,
    mutation_id,
    command,
    elapsed,
    progress,
    formatReadableSize(memory_usage) AS memory
FROM system.mutations
WHERE NOT is_done
ORDER BY create_time;

-- 5.3 查看 Mutation 对 Part 的影响
SELECT
    database,
    table,
    count() AS total_parts,
    countIf(active = 1) AS active_parts,
    countIf(min_block_number != max_block_number) AS mutated_parts
FROM system.parts
WHERE database = 'mutation_test'
GROUP BY database, table;

-- 5.4 取消 Mutation
-- 【场景】Mutation 卡住了，需要取消
-- KILL MUTATION WHERE database = 'mutation_test' AND table = 'mutation_demo';

-- 5.5 Mutation 常见问题
-- 【坑】Mutation 卡住：检查是否有大量 Part 未合并
-- 【坑】Mutation 失败：检查是否有关键列被修改
-- 【坑】Mutation 慢：先合并 Part，再执行 Mutation

-- ============================================================================
-- §6. 批量写入优化（避免 Mutation）
-- ============================================================================
-- 【原理】最佳实践是避免频繁 Mutation，通过批量写入来减少数据变更的需求。
--         核心思路：用 INSERT 代替 UPDATE/DELETE。

-- 6.1 分区替换策略（推荐）
-- 【场景】每天全量更新用户状态
-- 创建日快照表
CREATE TABLE user_snapshot_daily
(
    snapshot_date Date,
    user_id UInt32,
    name String,
    status String,
    amount Float64
) ENGINE = MergeTree()
PARTITION BY snapshot_date
ORDER BY (snapshot_date, user_id);

-- 每天插入新快照（全量数据）
INSERT INTO user_snapshot_daily VALUES
    ('2024-01-15', 1, 'Alice', 'active', 100.0),
    ('2024-01-15', 2, 'Bob', 'active', 200.0);

-- 查询最新快照
SELECT * FROM user_snapshot_daily
WHERE snapshot_date = (SELECT max(snapshot_date) FROM user_snapshot_daily);

-- 6.2 增量 Merge 策略（ReplacingMergeTree）
-- 【场景】用版本号去重替代 UPDATE
CREATE TABLE user_latest
(
    user_id UInt32,
    name String,
    status String,
    version UInt32
) ENGINE = ReplacingMergeTree(version)
ORDER BY user_id;

-- 插入初始数据
INSERT INTO user_latest VALUES (1, 'Alice', 'active', 1);
INSERT INTO user_latest VALUES (2, 'Bob', 'active', 1);

-- 用新版本替代旧数据（不需要 UPDATE）
INSERT INTO user_latest VALUES (1, 'Alice', 'inactive', 2);

-- 查询最新版本
SELECT
    user_id,
    argMax(name, version) AS name,
    argMax(status, version) AS status
FROM user_latest
GROUP BY user_id;

-- 6.3 CollapsingMergeTree 策略
-- 【场景】用 sign 标记替代 DELETE
CREATE TABLE user_collapsing
(
    user_id UInt32,
    name String,
    status String,
    sign Int8
) ENGINE = CollapsingMergeTree(sign)
ORDER BY user_id;

-- 插入初始数据（sign=1 表示有效行）
INSERT INTO user_collapsing VALUES (1, 'Alice', 'active', 1);
INSERT INTO user_collapsing VALUES (2, 'Bob', 'active', 1);

-- 删除用户（插入 sign=-1 的取消行）
INSERT INTO user_collapsing VALUES (1, 'Alice', 'active', -1);

-- 查询有效数据（自动折叠）
SELECT
    user_id,
    name,
    status
FROM user_collapsing
FINAL;  -- 使用 FINAL 自动折叠 sign=1 的行

-- ============================================================================
-- §7. 异步插入（Async Insert）
-- ============================================================================
-- 【原理】异步插入将多个 INSERT 合并为一批写入，减少 Parts 数量，提高写入吞吐。
--         INSERT 先写入缓冲区，缓冲区满或超时后再批量写入 MergeTree。
--         适合大量小批次写入场景（如日志采集、实时数据流）。

-- 7.1 启用异步插入
SET async_insert = 1;           -- 开启异步插入
SET async_insert_threads = 4;   -- 异步插入线程数
SET wait_for_async_insert = 0;  -- 不等确认，直接返回

-- 7.2 创建异步插入表
CREATE TABLE async_insert_demo
(
    id UInt32,
    data String,
    event_time DateTime
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (id, event_time);

-- 7.3 异步插入数据（立即返回，后台写入）
INSERT INTO async_insert_demo VALUES
    (1, 'async data 1', now()),
    (2, 'async data 2', now());

-- 7.4 异步插入配置参数
-- 【关键参数】
-- async_insert = 1                        # 启用异步插入
-- async_insert_threads = 4                # 异步线程数
-- wait_for_async_insert = 0               # 不等确认
-- async_insert_max_data_size = 10485760   # 缓冲区最大 10MB
-- async_insert_busy_timeout_ms = 1000     # 超时 1 秒
-- async_insert_stale_timeout_ms = 500     # 老化超时

-- 7.5 异步插入 vs Buffer 表对比
-- 【对比】
-- | 维度 | 异步插入 | Buffer 表 |
-- |------|---------|-----------|
-- | 原理 | 服务端缓冲区 | 内存表定期刷盘 |
-- | 数据安全 | 缓冲区在内存，宕机丢失 | 同左 |
-- | 配置复杂度 | 简单（SET 参数） | 复杂（需定义刷盘规则） |
-- | 适用版本 | CH 21.12+ | 所有版本 |
-- | 推荐 | ✅ 新项目推荐 | ⚠️ 兼容旧项目 |
-- 推荐：新项目优先使用异步插入，Buffer 表仅用于兼容旧版本

-- 关闭异步插入（恢复默认）
SET async_insert = 0;

-- ============================================================================
-- §8. 并发与隔离
-- ============================================================================
-- 【原理】ClickHouse 不支持传统的事务隔离级别（ACID）。
--         Mutation 和 SELECT 的并发行为由 MergeTree 的 MVCC 机制保证。
--         每个 SELECT 读到的是执行时的快照，不受后续 Mutation 影响。

-- 8.1 创建并发测试表
CREATE TABLE concurrency_demo
(
    id UInt32,
    amount Float64,
    event_time DateTime
) ENGINE = MergeTree()
ORDER BY (id, event_time);

INSERT INTO concurrency_demo VALUES
    (1, 100.0, '2024-01-15 10:00:00'),
    (2, 200.0, '2024-01-15 11:00:00');

-- 8.2 并发行为说明
-- 【原理】
-- 1. SELECT 和 Mutation 不互斥：SELECT 读到的是发起时的数据快照
-- 2. Mutation 提交后，已发起的 SELECT 不受影响（读旧版本）
-- 3. 新发起的 SELECT 读到 Mutation 完成后的数据
-- 4. 没有 MVCC 隔离级别概念，只有"读已提交"的语义

-- 8.3 验证并发行为
-- 启动 Mutation（后台执行）
ALTER TABLE concurrency_demo
UPDATE amount = amount * 2
WHERE id = 1;

-- 同时查询（读的是 Mutation 发起前的快照）
SELECT * FROM concurrency_demo ORDER BY id;

-- 等待 Mutation 完成
SELECT sleep(1);

-- 再次查询（读的是 Mutation 完成后的数据）
SELECT * FROM concurrency_demo ORDER BY id;

-- 8.4 并发注意事项
-- 【坑】长查询和 Mutation 同时执行时，查询可能读到旧数据
-- 【坑】大量 Mutation 并发会导致 Part 数量激增
-- 推荐：在低峰期执行 Mutation，避免与大查询并发

-- ============================================================================
-- §9. 实战案例
-- ============================================================================

-- 9.1 案例：日志表自动清理 + 归档
-- 【场景】日志表保留 30 天，超期自动删除，但需保留月度归档
CREATE TABLE logs
(
    event_time DateTime,
    level String,
    message String
) ENGINE = MergeTree()
PARTITION BY toYYYYMMDD(event_time)
ORDER BY (event_time, level)
TTL event_time + INTERVAL 30 DAY;

-- 月度归档表
CREATE TABLE logs_archive
(
    month Date,
    level String,
    total_count UInt64,
    last_event_time DateTime
) ENGINE = SummingMergeTree()
ORDER BY (month, level);

-- 物化视图：自动归档
CREATE MATERIALIZED VIEW mv_logs_archive
TO logs_archive
AS
SELECT
    toStartOfMonth(event_time) AS month,
    level,
    count() AS total_count,
    max(event_time) AS last_event_time
FROM logs
GROUP BY month, level;

-- 插入测试数据
INSERT INTO logs VALUES
    (now(), 'INFO', 'System started'),
    (now(), 'WARN', 'Disk space low'),
    (now(), 'ERROR', 'Connection timeout'),
    (now() - INTERVAL 40 DAY, 'INFO', 'Old log entry');  -- 这条会因 TTL 过期

-- 查看归档
SELECT * FROM logs_archive ORDER BY month, level;

-- 9.2 案例：用户状态变更审计
-- 【场景】用户状态变更不覆盖，保留历史记录
CREATE TABLE user_status_history
(
    user_id UInt32,
    old_status String,
    new_status String,
    changed_at DateTime,
    operator String
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(changed_at)
ORDER BY (user_id, changed_at);

-- 状态变更时插入审计记录（不 UPDATE 原表）
INSERT INTO user_status_history VALUES
    (1, 'pending', 'active', '2024-01-15 10:00:00', 'admin'),
    (1, 'active', 'suspended', '2024-01-20 10:00:00', 'admin'),
    (2, 'pending', 'active', '2024-01-16 10:00:00', 'admin');

-- 查看当前状态（取最新记录）
SELECT
    user_id,
    argMax(new_status, changed_at) AS current_status
FROM user_status_history
GROUP BY user_id;

-- 9.3 案例：批量数据修正
-- 【场景】发现某段时间的数据有误，需要批量修正
-- 创建订单表
CREATE TABLE orders
(
    order_id UInt64,
    product_id UInt32,
    amount Decimal(10, 2),
    order_date Date
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(order_date)
ORDER BY (order_id, order_date);

INSERT INTO orders VALUES
    (1001, 1, 99.99, '2024-01-15'),
    (1002, 2, 199.99, '2024-01-15'),
    (1003, 1, 149.99, '2024-01-16'),
    (1004, 3, 299.99, '2024-02-01');

-- 方案一：如果数据量小，用 Mutation UPDATE
ALTER TABLE orders
UPDATE amount = amount * 1.1
WHERE order_date >= '2024-01-01'
  AND order_date < '2024-02-01';

SELECT sleep(1);

-- 方案二：如果数据量大，用分区替换
-- 1. 创建临时表
CREATE TABLE orders_corrected
(
    order_id UInt64,
    product_id UInt32,
    amount Decimal(10, 2),
    order_date Date
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(order_date)
ORDER BY (order_id, order_date);

-- 2. 插入修正后的数据
INSERT INTO orders_corrected
SELECT
    order_id,
    product_id,
    amount * 1.1 AS amount,  -- 修正逻辑
    order_date
FROM orders
WHERE order_date >= '2024-01-01'
  AND order_date < '2024-02-01';

-- 3. 替换原分区
ALTER TABLE orders REPLACE PARTITION '2024-01' FROM orders_corrected;

-- 验证
SELECT * FROM orders ORDER BY order_id;

-- 9.4 案例：GDPR 数据删除
-- 【场景】用户要求删除所有个人数据（GDPR 合规）
-- 创建用户事件表
CREATE TABLE user_events
(
    user_id UInt32,
    event_time DateTime,
    ip_address String,
    user_agent String,
    event_data String
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (user_id, event_time);

INSERT INTO user_events VALUES
    (1, '2024-01-15 10:00:00', '192.168.1.1', 'Mozilla/5.0', '{"page":"home"}'),
    (1, '2024-01-15 11:00:00', '192.168.1.1', 'Mozilla/5.0', '{"page":"product"}'),
    (2, '2024-01-15 10:00:00', '10.0.0.1', 'Chrome/120', '{"page":"search"}');

-- 删除用户 1 的所有数据
ALTER TABLE user_events
DELETE WHERE user_id = 1;

SELECT sleep(1);

-- 验证
SELECT * FROM user_events ORDER BY user_id;

-- 注意：对于 GDPR 场景，需要考虑：
-- 1. 使用分区删除如果 user_id 是分区键
-- 2. 删除后需要强制合并才能真正清理磁盘
-- 3. 备份中可能仍包含被删除数据
OPTIMIZE TABLE user_events FINAL;

-- ============================================================================
-- §10. 清理
-- ============================================================================
DROP TABLE IF EXISTS mutation_demo;
DROP TABLE IF EXISTS partition_demo;
DROP TABLE IF EXISTS archive_demo;
DROP TABLE IF EXISTS new_data_demo;
DROP TABLE IF EXISTS ttl_row_demo;
DROP TABLE IF EXISTS ttl_column_demo;
DROP TABLE IF EXISTS lightweight_demo;
DROP TABLE IF EXISTS user_snapshot_daily;
DROP TABLE IF EXISTS user_latest;
DROP TABLE IF EXISTS user_collapsing;
DROP TABLE IF EXISTS async_insert_demo;
DROP TABLE IF EXISTS concurrency_demo;
DROP TABLE IF EXISTS logs;
DROP TABLE IF EXISTS logs_archive;
DROP VIEW IF EXISTS mv_logs_archive;
DROP TABLE IF EXISTS user_status_history;
DROP TABLE IF EXISTS orders;
DROP TABLE IF EXISTS orders_corrected;
DROP TABLE IF EXISTS user_events;
DROP DATABASE IF EXISTS mutation_test;

-- ============================================================================
-- §11. 自测题
-- ============================================================================
-- 1. Mutation 为什么是异步的？Mutation 提交后发生了什么？
-- 2. DROP PARTITION 和 DELETE 操作的区别是什么？为什么分区操作更快？
-- 3. TTL 是实时触发的吗？什么情况下 TTL 会执行？
-- 4. 轻量操作和 Mutation 的核心区别是什么？轻量操作有什么限制？
-- 5. 如何监控 Mutation 的进度？卡住了怎么处理？
-- 6. 什么场景下应该用 ReplacingMergeTree 替代 UPDATE？
-- 7. 异步插入和 Buffer 表的区别是什么？推荐用哪个？
-- 8. ClickHouse 的并发隔离级别是什么？Mutation 和 SELECT 会互相阻塞吗？
-- 9. GDPR 场景下删除用户数据，需要注意哪些问题？
-- 10. 批量数据修正，数据量小和大分别用什么方案？