-- ================================================
-- 03_mutation_deletion_examples.sql
-- 从 03_mutation_deletion.md 提取的 SQL 示例
-- 提取时间: 2026-01-23 14:40:17
-- ================================================


-- ========================================
-- 📋 基本语法
-- ========================================

-- 删除数据
ALTER TABLE table_name
DELETE WHERE condition;

-- 更新数据
ALTER TABLE table_name
UPDATE column = expression WHERE condition;

-- 立即执行 Mutation
ALTER TABLE table_name
DELETE WHERE condition
SETTINGS mutations_sync = 1;

-- ========================================
-- 📋 基本语法
-- ========================================

-- Mutation 是异步执行的
ALTER TABLE events
DELETE WHERE event_time < '2023-01-01';

-- 查看执行状态
SELECT
    mutation_id,
    command,
    is_done,
    create_time,
    done_time,
    exception_code
FROM system.mutations
WHERE database = 'your_database' AND table = 'your_table'
ORDER BY create_time DESC;

-- ========================================
-- 📋 基本语法
-- ========================================

-- Mutation 是重操作，会触发数据重写
-- 查看受影响的行数
SELECT
    mutation_id,
    command,
    parts_to_do_names,
    parts_to_do,
    is_done
FROM system.mutations
WHERE database = 'your_database' AND table = 'your_table';

-- ========================================
-- 📋 基本语法
-- ========================================

-- 删除特定条件的数据
ALTER TABLE events
DELETE WHERE event_time < '2023-01-01';

-- 删除多个条件
ALTER TABLE events
DELETE WHERE 
    event_time < '2023-01-01'
    OR level = 'debug';

-- 使用子查询
ALTER TABLE events
DELETE WHERE user_id IN (
    SELECT user_id FROM deleted_users
);

-- ========================================
-- 📋 基本语法
-- ========================================

-- 将大删除拆分为多个小批次
-- 批次 1
ALTER TABLE events
DELETE WHERE event_time >= '2022-01-01' AND event_time < '2022-03-01';

-- 批次 2
ALTER TABLE events
DELETE WHERE event_time >= '2022-03-01' AND event_time < '2022-05-01';

-- 批次 3
ALTER TABLE events
DELETE WHERE event_time >= '2022-05-01' AND event_time < '2022-07-01';

-- ========================================
-- 📋 基本语法
-- ========================================

-- 更新单列
ALTER TABLE events
UPDATE status = 'archived' WHERE event_time < '2023-01-01';

-- 使用表达式更新
ALTER TABLE events
UPDATE status = CASE 
    WHEN event_time < '2023-01-01' THEN 'archived'
    WHEN event_time < '2023-06-01' THEN 'old'
    ELSE 'current'
END;

-- ========================================
-- 📋 基本语法
-- ========================================

-- 更新多列
ALTER TABLE users
UPDATE 
    last_login = now(),
    login_count = login_count + 1
WHERE user_id = '123';

-- 使用 Map 更新
ALTER TABLE events
UPDATE tags = mapInsert(tags, 'processed', 'true') WHERE id = 123;

-- ========================================
-- 📋 基本语法
-- ========================================

-- 复杂条件更新
ALTER TABLE orders
UPDATE 
    status = 'cancelled',
    cancelled_at = now()
WHERE 
    status = 'pending'
    AND created_at < now() - INTERVAL 7 DAY
    AND payment_status = 'failed';

-- ========================================
-- 📋 基本语法
-- ========================================

-- 删除用户的所有数据
ALTER TABLE user_events
DELETE WHERE user_id = 'user123';

-- 删除用户的敏感信息（保留统计）
ALTER TABLE users
UPDATE 
    email = 'deleted@deleted.com',
    phone = 'deleted',
    address = 'deleted'
WHERE user_id = 'user123';

-- 记录删除操作
INSERT INTO data_deletion_log
SELECT
    user_id,
    'delete' as action,
    now() as timestamp
FROM users
WHERE user_id = 'user123';

-- ========================================
-- 📋 基本语法
-- ========================================

-- 修正错误数据
ALTER TABLE orders
UPDATE total_amount = quantity * unit_price
WHERE total_amount != quantity * unit_price;

-- 修正日期格式错误
ALTER TABLE events
UPDATE event_time = parseDateTimeBestEffort(event_date_str)
WHERE event_time = toDateTime('1970-01-01');

-- ========================================
-- 📋 基本语法
-- ========================================

-- 软删除（标记而非物理删除）
ALTER TABLE messages
UPDATE is_deleted = 1, deleted_at = now()
WHERE message_id IN (
    SELECT message_id FROM moderation_queue
    WHERE action = 'delete'
);

-- 查看软删除的数据
SELECT * FROM messages WHERE is_deleted = 1;

-- 恢复软删除的数据
ALTER TABLE messages
UPDATE is_deleted = 0, deleted_at = NULL
WHERE message_id = 'msg123';

-- ========================================
-- 📋 基本语法
-- ========================================

-- 对数据进行聚合更新
ALTER TABLE daily_metrics
UPDATE 
    total_value = sum(value)
GROUP BY metric_name, date
WHERE date = today() - INTERVAL 1 DAY;

-- ========================================
-- 📋 基本语法
-- ========================================

-- 查看所有 Mutation
SELECT
    database,
    table,
    mutation_id,
    command,
    is_done,
    parts_to_do,
    parts_to_do_names,
    create_time,
    done_time,
    exception_code,
    exception_text
FROM system.mutations
WHERE database = 'your_database'
ORDER BY create_time DESC;

-- ========================================
-- 📋 基本语法
-- ========================================

-- 监控 Mutation 的资源使用
SELECT
    mutation_id,
    command,
    formatReadableSize(total_bytes_read_uncompressed) AS bytes_read,
    formatReadableSize(total_bytes_written_uncompressed) AS bytes_written,
    elapsed,
    cpu_time_ns / 1e9 AS cpu_seconds
FROM system.mutations
WHERE database = 'your_database' AND table = 'your_table'
ORDER BY create_time DESC;

-- ========================================
-- 📋 基本语法
-- ========================================

-- 预估 Mutation 的影响
SELECT
    '预估删除行数' as metric,
    count() as value
FROM your_table
WHERE event_time < '2023-01-01'

UNION ALL

SELECT
    '预估影响的分区数',
    count(DISTINCT partition)
FROM your_table
WHERE event_time < '2023-01-01'

UNION ALL

SELECT
    '预估影响的数据量',
    formatReadableSize(sum(length(data)))
FROM your_table
WHERE event_time < '2023-01-01';

-- ========================================
-- 📋 基本语法
-- ========================================

-- 步骤 1: 预估影响
SELECT
    count() AS rows_to_delete,
    formatReadableSize(sum(length(data))) AS size_to_delete,
    count(DISTINCT partition) AS partitions_affected
FROM events
WHERE event_time < '2023-01-01';

-- 步骤 2: 备份数据
INSERT INTO events_backup
SELECT * FROM events
WHERE event_time < '2023-01-01';

-- 步骤 3: 验证备份
SELECT count() FROM events_backup;

-- 步骤 4: 执行删除
ALTER TABLE events
DELETE WHERE event_time < '2023-01-01'
SETTINGS mutations_sync = 1;

-- 步骤 5: 验证删除
SELECT count() FROM events WHERE event_time < '2023-01-01';

-- 步骤 6: 清理备份（如需要）
-- ALTER TABLE events_backup DROP PARTITION '2022-12';

-- ========================================
-- 📋 基本语法
-- ========================================

-- 按优先级删除数据

-- 先删除最不重要的数据
ALTER TABLE events
DELETE WHERE priority = 'low' AND event_time < '2023-01-01';

-- 等待完成
-- SELECT is_done FROM system.mutations WHERE command LIKE '%priority = low%';

-- 再删除中等重要数据
ALTER TABLE events
DELETE WHERE priority = 'medium' AND event_time < '2023-01-01';

-- 最后删除高优先级数据（如有必要）
ALTER TABLE events
DELETE WHERE priority = 'high' AND event_time < '2023-01-01';

-- ========================================
-- 📋 基本语法
-- ========================================

-- 增量删除策略

-- 第一天：删除最旧的数据
ALTER TABLE events
DELETE WHERE event_time < '2022-01-01'
SETTINGS max_threads = 4;

-- 第二天：删除次旧的数据
ALTER TABLE events
DELETE WHERE 
    event_time >= '2022-01-01' 
    AND event_time < '2022-03-01'
SETTINGS max_threads = 4;

-- 第三天：删除更近的数据
ALTER TABLE events
DELETE WHERE 
    event_time >= '2022-03-01' 
    AND event_time < '2022-06-01'
SETTINGS max_threads = 4;

-- ========================================
-- 📋 基本语法
-- ========================================

-- 异步执行（默认）
ALTER TABLE events
DELETE WHERE event_time < '2023-01-01';

-- 同步执行（等待完成）
ALTER TABLE events
DELETE WHERE event_time < '2023-01-01'
SETTINGS mutations_sync = 1;

-- 同步执行所有之前的 Mutation
ALTER TABLE events
DELETE WHERE event_time < '2023-01-01'
SETTINGS mutations_sync = 2;

-- ========================================
-- 📋 基本语法
-- ========================================

-- 控制并发线程数
ALTER TABLE events
DELETE WHERE event_time < '2023-01-01'
SETTINGS max_threads = 4;

-- 控制复制线程数（复制表）
ALTER TABLE events
DELETE WHERE event_time < '2023-01-01'
SETTINGS replicated_deduplication_window = 0;
