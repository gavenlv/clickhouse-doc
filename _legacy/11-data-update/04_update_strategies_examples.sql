-- ================================================================================
-- ClickHouse 数据更新策略选择指南
-- ================================================================================
-- 
-- 集群: treasurycluster (2 副本)
-- 预计学习时间: 20 分钟
-- 
-- 本文件涵盖:
--   1. 更新策略决策树 - 如何选择合适的更新方式
--   2. 分区更新 - REPLACE PARTITION
--   3. Mutation 更新 - ALTER TABLE UPDATE
--   4. 轻量级更新 - lightweight_update
--   5. 追加模式 - 事件日志表
--   6. 混合策略 - 分层更新方案
-- 
-- ================================================================================
-- 更新策略决策树
-- ================================================================================
-- 
--   ┌─────────────────────────────────────────────────────────────────────────┐
--   │                     如何选择更新策略?                                   │
--   └─────────────────────────────────────────────────────────────────────────┘
--   
--   ┌─────────────────────────────────────────────────────────────────────────┐
--   │                    需要更新数据?                                        │
--   └─────────────────────────────────────────────────────────────────────────┘
--                                  │
--                                  ▼
--                     ┌────────────────────────┐
--                     │  更新数据量比例?       │
--                     └────────────────────────┘
--                        │              │            │
--                    < 1%│          1-30%│        > 30%│
--                        ▼              ▼              ▼
--              ┌───────────────┐ ┌───────────────┐ ┌───────────────┐
--              │ 轻量级更新    │ │ Mutation      │ │ 分区更新      │
--              │ 或 Mutation   │ │ 或轻量级更新  │ │ REPLACE       │
--              └───────────────┘ └───────────────┘ └───────────────┘
--                      │               │               │
--                      ▼               ▼               ▼
--              ┌───────────────┐ ┌───────────────┐ ┌───────────────┐
--              │ 更新频率?     │ │ 是否需要      │ │ 是否需要      │
--              └───────────────┘ │ 立即可见?     │ │ 保留原数据?   │
--                 │       │      └───────────────┘ └───────────────┘
--              低频│    高频│      是│         否│    是│         否│
--                 ▼        ▼        ▼           ▼      ▼           ▼
--           ┌─────────┐ ┌────────┐ ┌────────┐ ┌────────┐ ┌────────┐
--           │Mutation │ │轻量级  │ │Mutation│ │分区    │ │EXCHANGE│
--           │(同步)   │ │更新    │ │(同步)  │ │替换    │ │或追加  │
--           └─────────┘ └────────┘ └────────┘ └────────┘ └────────┘
-- 
-- ================================================================================
-- 更新策略对比表
-- ================================================================================
-- 
--   ┌─────────────────────────────────────────────────────────────────────────┐
--   │                      更新策略特性对比                                   │
--   └─────────────────────────────────────────────────────────────────────────┘
--   
--   策略            执行时间    磁盘I/O    空间占用    实时性    适用场景
--   ───────────────────────────────────────────────────────────────────────
--   Mutation        慢(分钟级)  高(全量)   高(翻倍)   异步      批量修正
--   轻量级更新      快(秒级)    低(增量)   低         实时      高频小更新
--   REPLACE分区     极快(毫秒)  无         无         实时      大批量更新
--   EXCHANGE分区    极快(毫秒)  无         无         原子      表间交换
--   追加模式        快          无         累积       查询时    高频更新
-- 
-- ================================================================================
-- 最佳实践总结
-- ================================================================================
-- 
--   ┌─────────────────────────────────────────────────────────────────────────┐
--   │                      更新策略最佳实践                                   │
--   └─────────────────────────────────────────────────────────────────────────┘
--   
--   1. 优先考虑追加模式:
--      - 设计事件日志表, 查询时合并最新状态
--      - 避免频繁更新, 只追加新数据
--   
--   2. 根据数据量选择策略:
--      - < 1%: 轻量级更新 或 Mutation
--      - 1-30%: Mutation (异步) 或 轻量级更新
--      - > 30%: 分区更新 (REPLACE PARTITION)
--   
--   3. 利用分区设计:
--      - 设计合理的分区键 (如按月分区)
--      - 更新时只替换受影响的分区
--   
--   4. 避免高频小更新:
--      - 合并小更新为批量更新
--      - 使用定时任务在低峰期执行
-- 
-- ================================================================================

CREATE TABLE IF NOT EXISTS logs_temp AS logs;

-- 更新数据
INSERT INTO logs_temp
SELECT 
    event_id,
    user_id,
    event_type,
    'processed' as status,
    event_time
FROM logs
WHERE event_time >= '2024-01-01'
  AND event_time < '2024-02-01';

-- 替换分区
ALTER TABLE logs
REPLACE PARTITION '202401'
FROM logs_temp;

-- 清理
DROP TABLE logs_temp;

-- ========================================
-- SQL Block 2
-- ========================================

-- 轻量级更新（ClickHouse 23.8+）
ALTER TABLE users
UPDATE status = 'active',
    last_updated = now()
WHERE user_id IN (1, 2, 3, 4, 5)
-- REMOVED SET lightweight_update (not supported) 1;

-- 或使用 Mutation
ALTER TABLE users
UPDATE status = 'active',
    last_updated = now()
WHERE user_id IN (1, 2, 3, 4, 5);

-- ========================================
-- SQL Block 3
-- ========================================

-- 创建修正表
CREATE TABLE IF NOT EXISTS orders_fixed AS orders;

-- 修正数据（所有金额增加 10%）
INSERT INTO orders_fixed
SELECT 
    order_id,
    user_id,
    product_id,
    amount * 1.1 as amount,
    order_date,
    status
FROM orders
WHERE toYYYYMM(order_date) IN ('202401', '202402', '202403');

-- 替换分区
ALTER TABLE orders
REPLACE PARTITION '202401', '202402', '202403'
FROM orders_fixed;

-- 清理
DROP TABLE orders_fixed;

-- ========================================
-- SQL Block 4
-- ========================================

-- 方案 1: 轻量级更新
ALTER TABLE orders
UPDATE status = 'completed',
    completed_at = now()
WHERE order_id = 12345
-- REMOVED SET lightweight_update (not supported) 1;

-- 方案 2: 重新设计表结构（追加模式）
-- 原表: orders
-- 新表: order_events (事件日志)
-- 查询时取最新事件

-- ========================================
-- SQL Block 5
-- ========================================

-- 创建归档表
CREATE TABLE IF NOT EXISTS orders_archive (
    order_id UInt64,
    user_id UInt64,
    amount Float64,
    order_date DateTime,
    status String
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(order_date)
ORDER BY order_id;

-- 交换分区
ALTER TABLE orders_archive
EXCHANGE PARTITION '202301'
WITH orders;

-- 继续交换其他月份...

-- ========================================
-- SQL Block 6
-- ========================================

-- 1. 最新数据使用轻量级更新
ALTER TABLE events
UPDATE status = 'processed'
WHERE event_time >= now() - INTERVAL 7 DAY
-- REMOVED SET lightweight_update (not supported) 1;

-- 2. 旧数据使用分区更新归档
ALTER TABLE events_archive
EXCHANGE PARTITION '202312'
WITH events;

-- ========================================
-- SQL Block 7
-- ========================================

-- 创建物化视图
CREATE MATERIALIZED VIEW user_stats_mv
ENGINE = SummingMergeTree()
ORDER BY (user_id, date)
AS SELECT
    user_id,
    toDate(event_time) as date,
    count() as event_count,
    sum(amount) as total_amount
FROM events
GROUP BY user_id, date;

-- 使用 Mutation 更新原表
ALTER TABLE events
UPDATE status = 'processed'
WHERE event_time >= now() - INTERVAL 30 DAY;

-- ========================================
-- SQL Block 8
-- ========================================

-- 1. 使用分区更新
ALTER TABLE users
REPLACE PARTITION '202401'
FROM users_temp;

-- 2. 定期合并
OPTIMIZE TABLE users
PARTITION '202401'
FINAL;

-- ========================================
-- SQL Block 9
-- ========================================

-- 合理的分区策略
CREATE TABLE IF NOT EXISTS events (
    event_id UInt64,
    user_id UInt64,
    event_time DateTime,
    event_data String
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)  -- 按月分区
ORDER BY (user_id, event_time);

-- ========================================
-- SQL Block 10
-- ========================================

-- 1. 备份数据
CREATE TABLE IF NOT EXISTS users_backup AS users;

-- 2. 检查更新范围
SELECT 
    count() as total_rows,
    formatReadableSize(sum(bytes_on_disk)) as total_size
FROM system.parts
WHERE table = 'users'
  AND partition IN ('202401', '202402');

-- 3. 在测试环境验证
-- 先在测试表上执行更新

-- ========================================
-- SQL Block 11
-- ========================================

-- 监控 Mutation 进度
SELECT 
    mutation_id,
    command,
    is_done,
    parts_to_do,
    progress
FROM system.mutations
WHERE database = 'current_db'
  AND table = 'users'
ORDER BY created DESC;

-- ========================================
-- SQL Block 12
-- ========================================

-- 验证更新结果
SELECT 
    status,
    count() as count
FROM users
WHERE toYYYYMM(created_at) = '202401'
GROUP BY status;

-- ========================================
-- SQL Block 13
-- ========================================

-- 错误做法
ALTER TABLE users UPDATE status = 'active';

-- 正确做法
CREATE TABLE IF NOT EXISTS users_temp AS users;
INSERT INTO users_temp SELECT * FROM users WHERE ...;
ALTER TABLE users REPLACE PARTITION '202401' FROM users_temp;

-- ========================================
-- SQL Block 14
-- ========================================

-- 错误做法
-- 每分钟执行一次
ALTER TABLE orders UPDATE status = 'new' WHERE order_id = x;

-- 正确做法
-- 使用事件日志表
CREATE TABLE IF NOT EXISTS order_events (
    order_id UInt64,
    event_type String,
    event_time DateTime,
    event_data String
) ENGINE = MergeTree()
ORDER BY (order_id, event_time);

-- 查询时取最新事件

-- ========================================
-- SQL Block 15
-- ========================================

-- 1. 先验证数据
SELECT count() FROM users_temp WHERE status = 'active';

-- 2. 对比数据
SELECT status, count() FROM users WHERE ... GROUP BY status;
SELECT status, count() FROM users_temp WHERE ... GROUP BY status;

-- 3. 确认无误后再替换
ALTER TABLE users REPLACE PARTITION '202401' FROM users_temp;
