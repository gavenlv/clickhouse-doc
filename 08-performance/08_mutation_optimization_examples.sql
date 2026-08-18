-- ================================================================================
-- ClickHouse Mutation 优化示例
-- ================================================================================
-- 
-- 集群: treasurycluster (2 副本)
-- 预计学习时间: 20 分钟
-- 
-- 本文件涵盖:
--   1. 分区操作优先 - 替代 Mutation 删除
--   2. 轻量级删除 - lightweight_delete
--   3. 分批 Mutation - 避免大事务
--   4. 低峰期执行 - 减少影响
--   5. mutations_sync - 同步级别设置
--   6. 资源限制 - 线程与内存控制
--   7. Mutation 监控 - 进度与性能
-- 
-- Mutation 执行原理:
-- 
--   ┌─────────────────────────────────────────────────────────────────────────┐
--   │                    ClickHouse Mutation 流程                             │
--   └─────────────────────────────────────────────────────────────────────────┘
--   
--   ALTER TABLE ... DELETE/UPDATE:
--   ┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐
--   │ 创建     │───>│ 后台     │───>│ 重写     │───>│ 替换     │
--   │ Mutation │    │ 队列     │    │ Part     │    │ 旧Part   │
--   │ 任务     │    │ 执行     │    │ 数据     │    │          │
--   └──────────┘    └──────────┘    └──────────┘    └──────────┘
--   
--   Mutation 重写过程:
--   ┌─────────────────────────────────────────────────────────────────────────┐
--   │   Part A (原始)                                                         │
--   │   ┌──────────────────────────────────────────────────────────────────┐ │
--   │   │ Row 1: user_id=1, status='active'    ← 匹配条件, 保留            │ │
--   │   │ Row 2: user_id=2, status='inactive'  ← 匹配条件, 删除/更新       │ │
--   │   │ Row 3: user_id=3, status='active'    ← 匹配条件, 保留            │ │
--   │   │ ...                                                              │ │
--   │   └──────────────────────────────────────────────────────────────────┘ │
--   │                           │                                            │
--   │                           ▼                                            │
--   │   Part A' (重写后)                                                     │
--   │   ┌──────────────────────────────────────────────────────────────────┐ │
--   │   │ Row 1: user_id=1, status='active'                                │ │
--   │   │ Row 3: user_id=3, status='active'                                │ │
--   │   │ ...                                                              │ │
--   │   └──────────────────────────────────────────────────────────────────┘ │
--   └─────────────────────────────────────────────────────────────────────────┘
-- 
-- 删除策略选择:
-- 
--   ┌─────────────────────┐
--   │ 删除数据范围?       │
--   └──────────┬──────────┘
--              │
--   ┌─────────┴─────────┐
--   │                   │
--   ▼                   ▼
-- 整个分区          部分数据
--   │                   │
--   ▼                   ▼
-- ┌─────────────┐   ┌─────────────────┐
-- │ DROP        │   │ 数据量?         │
-- │ PARTITION   │   └────────┬────────┘
-- │ (瞬间)      │            │
-- └─────────────┘   ┌───────┴───────┐
--                   │               │
--                   ▼               ▼
--              小批量          大批量
--              (< 10K)         (> 10K)
--                   │               │
--                   ▼               ▼
--           ┌─────────────┐ ┌─────────────┐
--           │ lightweight │ │ 分批        │
--           │ DELETE      │ │ Mutation    │
--           │ (23.8+)     │ │             │
--           └─────────────┘ └─────────────┘
-- 
-- Mutation 性能影响:
-- 
--   ┌─────────────────────────────────────────────────────────────────────────┐
--   │                    Mutation 对系统的影响                                │
--   └─────────────────────────────────────────────────────────────────────────┘
--   
--   CPU:     重写数据需要 CPU 资源
--   内存:    加载 Part 到内存处理
--   磁盘IO:  读取旧 Part, 写入新 Part
--   合并:    新 Part 参与后台合并
--   
--   最佳实践:
--   ┌─────────────────────────────────────────────────────────────────────────┐
--   │ 1. 优先使用分区操作 (DROP PARTITION)                                    │
--   │ 2. 使用轻量级删除 (lightweight_delete)                                  │
--   │ 3. 分批处理, 避免大 Mutation                                            │
--   │ 4. 低峰期执行                                                           │
--   │ 5. 设置合理的 mutations_sync                                            │
--   └─────────────────────────────────────────────────────────────────────────┘
-- 
-- ================================================================================

-- ================================================================================
-- §0. 准备演示数据
-- ================================================================================
-- 本文件所有演示基于 default.users（MergeTree，按 toYYYYMM(created_at) 分区）。
-- 为保证可独立重复运行，先重建表并填充数据（覆盖 2023 全年 12 个分区 + 2024-01 大分区）
DROP TABLE IF EXISTS users_temp;
DROP TABLE IF EXISTS users;
CREATE TABLE users
(
    user_id UInt64,
    username String,
    email String,
    created_at DateTime,
    last_login DateTime
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(created_at)
ORDER BY created_at;

INSERT INTO users
SELECT
    number + 1 AS user_id,
    concat('user_', toString(number + 1)) AS username,
    concat('user_', toString(number + 1), '@example.com') AS email,
    toDateTime('2024-01-15 10:00:00') + INTERVAL number MINUTE AS created_at,
    now() AS last_login
FROM numbers(100000);

-- 第二批：2023 年 12 个月各 1 行（保证 DROP PARTITION 演示的 12 个分区都存在）
INSERT INTO users
SELECT
    number + 100001 AS user_id,
    concat('user_', toString(number + 100001)) AS username,
    concat('user_', toString(number + 100001), '@example.com') AS email,
    toDateTime('2023-01-02 08:00:00') + INTERVAL number MONTH AS created_at,
    now() AS last_login
FROM numbers(12);

-- 确认数据就绪
SELECT count() AS total_rows, uniqExact(toYYYYMM(created_at)) AS month_cnt FROM users;

-- ✅ 用临时表整分区替换（替代 Mutation 删除）
-- 原理: REPLACE PARTITION 是元数据级操作（改目录指针），秒级完成，不重写数据
CREATE TABLE IF NOT EXISTS users_temp AS users;
-- 把 2024-01 分区数据复制到临时表，并把 email 改为 'replaced@example.com'（演示"用新数据整体替换"）
INSERT INTO users_temp
SELECT user_id, username, 'replaced@example.com' AS email, created_at, last_login
FROM users
WHERE toYYYYMM(created_at) = 202401;
ALTER TABLE users REPLACE PARTITION '202401' FROM users_temp;
DROP TABLE IF EXISTS users_temp;

-- ❌ 使用 Mutation（慢速，需重写该分区所有 Part）
ALTER TABLE users DELETE WHERE toYYYYMM(created_at) = '202401';

-- ========================================
-- 策略 1: 优先使用分区操作
-- ========================================

-- ✅ 使用轻量级删除（CH 23.8+；25.12 默认 DELETE 即轻量级删除，lightweight_delete 设置已移除）
ALTER TABLE users
DELETE WHERE user_id IN (1, 2, 3);

-- ❌ 使用传统 Mutation
ALTER TABLE users DELETE WHERE user_id IN (1, 2, 3);

-- ========================================
-- 策略 1: 优先使用分区操作
-- ========================================

-- ✅ 分批处理
-- 批次 1
ALTER TABLE users
DELETE WHERE user_id BETWEEN 1 AND 10000;

-- 等待完成后执行下一批次
-- 批次 2
ALTER TABLE users
DELETE WHERE user_id BETWEEN 10001 AND 20000;

-- ❌ 单次大批量 Mutation（反例示意：省略号 `...` 不是合法 SQL，真实写法见下行）
-- 真实写法（会重写所有涉及 Part，应避免）：
-- ALTER TABLE users DELETE WHERE user_id IN (SELECT number FROM numbers(1, 100000));

-- ========================================
-- 策略 1: 优先使用分区操作
-- ========================================

-- ✅ 低峰期执行
ALTER TABLE users
DELETE WHERE created_at < now() - INTERVAL 90 DAY;

-- 或使用定时任务

-- ========================================
-- 策略 1: 优先使用分区操作
-- ========================================

-- 0: 异步执行（默认）
ALTER TABLE users
DELETE WHERE user_id IN (1, 2, 3)
SETTINGS mutations_sync = 0;

-- 1: 等待当前分片完成
ALTER TABLE users
DELETE WHERE user_id IN (1, 2, 3)
SETTINGS mutations_sync = 1;

-- 2: 等待所有分片完成
ALTER TABLE users
DELETE WHERE user_id IN (1, 2, 3)
SETTINGS mutations_sync = 2;

-- ========================================
-- 策略 1: 优先使用分区操作
-- ========================================

-- 限制并发线程数
ALTER TABLE users
DELETE WHERE user_id IN (1, 2, 3)
;  -- 说明: 25.12 不支持 ALTER ... SETTINGS max_threads（已移除），删除语句以分号结束

-- 限制内存使用
ALTER TABLE users
DELETE WHERE user_id IN (1, 2, 3)
;  -- 说明: 25.12 不支持 ALTER ... SETTINGS max_memory_usage（已移除），删除语句以分号结束

-- ========================================
-- 策略 1: 优先使用分区操作
-- ========================================

-- 设置 Mutation 优先级（1-10，默认 5）
ALTER TABLE users
DELETE WHERE user_id IN (1, 2, 3)
SETTINGS priority = 8;

-- ========================================
-- 策略 1: 优先使用分区操作
-- ========================================

-- 是否等待复制完成
ALTER TABLE users
DELETE WHERE user_id IN (1, 2, 3)
SETTINGS replication_alter_partitions_sync = 2;  -- 0: 不同步, 1: 当前表, 2: 所有副本

-- ========================================
-- 策略 1: 优先使用分区操作
-- ========================================

-- 查看 Mutation 状态
-- 说明: 25.12 的 system.mutations 列名为 create_time / latest_fail_reason（无 progress/exception_text/created_at/done_at）
SELECT 
    database,
    table,
    mutation_id,
    command,
    is_done,
    parts_to_do,
    parts_to_do_names,
    latest_fail_reason
FROM system.mutations
WHERE database = 'default'
ORDER BY create_time DESC;

-- ========================================
-- 策略 1: 优先使用分区操作
-- ========================================

-- 实时监控 Mutation 进度
-- 说明: 25.12 中子查询 JOIN 必须带别名（set joined_subquery_requires_alias），
--       且 system.mutations 无 progress 列，用 create_time 计算已执行时长
SELECT 
    database,
    table,
    mutation_id,
    command,
    is_done,
    parts_to_do,
    dateDiff('second', create_time, now()) as elapsed_seconds
FROM system.mutations
WHERE database = 'default'
  AND is_done = 0
ORDER BY create_time DESC;

-- ========================================
-- 策略 1: 优先使用分区操作
-- ========================================

-- 查看最近完成的 Mutation
SELECT 
    database,
    table,
    mutation_id,
    command,
    parts_to_do,
    is_done,
    create_time,
    latest_fail_reason,
    dateDiff('second', create_time, now()) as duration_seconds
FROM system.mutations
WHERE is_done = 1
  AND database = 'default'
ORDER BY create_time DESC
LIMIT 10;

-- ========================================
-- 策略 1: 优先使用分区操作
-- ========================================

-- ✅ 分批删除（每批 1 万行）
-- 批次 1
ALTER TABLE users
DELETE WHERE user_id BETWEEN 1 AND 10000
;  -- 说明: 25.12 不支持 ALTER ... SETTINGS max_threads（已移除），删除语句以分号结束

-- 等待完成后执行下一批次
-- 批次 2
ALTER TABLE users
DELETE WHERE user_id BETWEEN 10001 AND 20000
;  -- 说明: 25.12 不支持 ALTER ... SETTINGS max_threads（已移除），删除语句以分号结束

-- ❌ 单次大批量删除（反例示意，真实写法见下行）
-- ALTER TABLE users DELETE WHERE user_id IN (SELECT number FROM numbers(1, 20000));

-- ========================================
-- 策略 1: 优先使用分区操作
-- ========================================

-- ✅ 使用分区删除
-- 删除 2023 年的所有分区
-- 说明: ALTER ... DROP PARTITION 一次只能删一个分区（不支持逗号分隔多分区），逐月删除
ALTER TABLE users DROP PARTITION '202301';
ALTER TABLE users DROP PARTITION '202302';
ALTER TABLE users DROP PARTITION '202303';
ALTER TABLE users DROP PARTITION '202304';
ALTER TABLE users DROP PARTITION '202305';
ALTER TABLE users DROP PARTITION '202306';
ALTER TABLE users DROP PARTITION '202307';
ALTER TABLE users DROP PARTITION '202308';
ALTER TABLE users DROP PARTITION '202309';
ALTER TABLE users DROP PARTITION '202310';
ALTER TABLE users DROP PARTITION '202311';
ALTER TABLE users DROP PARTITION '202312';

-- ❌ 使用 Mutation（反例示意，需逐月匹配，真实写法见下行）
-- ALTER TABLE users
-- DELETE WHERE toYYYYMM(created_at) IN (SELECT toYYYYMM(toDate('2023-01-01') + INTERVAL number MONTH) FROM numbers(12));

-- ========================================
-- 策略 1: 优先使用分区操作
-- ========================================

-- ✅ 使用轻量级删除（25.12 默认 DELETE 即轻量级删除，无需 SETTINGS）
ALTER TABLE users
DELETE WHERE user_id IN (SELECT number FROM numbers(1, 1000));

-- ❌ 使用传统 Mutation（反例示意，真实写法见下行）
-- ALTER TABLE users DELETE WHERE user_id IN (SELECT number FROM numbers(1, 1000));

-- ========================================
-- 策略 1: 优先使用分区操作
-- ========================================

-- ✅ 组合策略：新数据用轻量级删除，旧数据用分区删除
-- 新数据（最近 30 天）
ALTER TABLE users
DELETE WHERE created_at >= now() - INTERVAL 30 DAY
  AND user_id IN (SELECT number FROM numbers(1, 1000));

-- 旧数据（30 天前）：把满足条件的数据整分区替换
-- 注意：2023 各分区在前面 DROP PARTITION 演示中已删除，
--       此处用剩余数据的 2024-01 分区演示 REPLACE PARTITION
CREATE TABLE IF NOT EXISTS users_temp AS users;
INSERT INTO users_temp
SELECT * FROM users
WHERE created_at < now() - INTERVAL 30 DAY;

ALTER TABLE users
REPLACE PARTITION '202401'
FROM users_temp;

DROP TABLE users_temp;
