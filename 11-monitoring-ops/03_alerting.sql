-- ============================================================================
-- 03 - 告警配置
-- ============================================================================
-- 场景: 告警规则管理、阈值配置、告警通道配置、告警聚合与降噪
-- 集群: treasurycluster (2副本)
-- 耗时: 10-15分钟
-- ============================================================================

DROP DATABASE IF EXISTS ops_test;
CREATE DATABASE ops_test;
USE ops_test;

-- ============================================================================
-- 【原理】告警体系架构
--
--  ┌─────────────────────────────────────────────────────────────────────────┐
--  │                        告警体系架构                                      │
--  ├─────────────────────────────────────────────────────────────────────────┤
--  │                                                                          │
--  │   ┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────────────────┐ │
--  │   │ 数据采集  │───>│ 规则匹配  │───>│ 告警评估  │───>│  通知分发        │ │
--  │   │ system.* │    │ 阈值比较  │    │ 级别判定  │    │ Email/Slack/     │ │
--  │   │ metrics  │    │ 趋势分析  │    │ 聚合降噪  │    │ Webhook/电话     │ │
--  │   └──────────┘    └──────────┘    └──────────┘    └──────────────────┘ │
--  │                                                                          │
--  └─────────────────────────────────────────────────────────────────────────┘
--
-- 告警级别定义：
--   INFO     — 信息通知，无需立即处理
--   WARNING  — 警告，需要关注但不紧急
--   ERROR    — 错误，需要尽快处理
--   CRITICAL — 严重，需要立即处理（P0 级别）
-- ============================================================================

-- ============================================================================
-- 【对比】告警方案对比
--
-- ┌──────────────────┬──────────────────┬──────────────────┬──────────────────┐
-- │     方案          │     优点          │     缺点          │     适用场景     │
-- ├──────────────────┼──────────────────┼──────────────────┼──────────────────┤
-- │ Prometheus+       │ 生态成熟          │ 需要额外部署      │ 大型生产集群     │
-- │ AlertManager      │ 支持多通道        │ 配置复杂          │                  │
-- ├──────────────────┼──────────────────┼──────────────────┼──────────────────┤
-- │ 自建告警系统       │ 灵活定制          │ 开发成本高        │ 有特殊需求       │
-- │ (SQL轮询)         │ 与CH深度集成      │ 维护成本高        │                  │
-- ├──────────────────┼──────────────────┼──────────────────┼──────────────────┤
-- │ 云服务告警         │ 开箱即用          │ 依赖云厂商        │ 云上部署         │
-- │ (CH Cloud/阿里云) │ 免运维            │ 定制能力有限      │                  │
-- └──────────────────┴──────────────────┴──────────────────┴──────────────────┘
-- ============================================================================

-- ==========================================
-- 1. 关键告警指标和阈值设计
-- ==========================================

-- 1.1 告警阈值推荐表
-- 【场景】为运维团队提供标准化的告警阈值参考
-- 【坑】阈值设置过松会漏报，过紧会产生大量告警噪音
-- 【坑】不同业务场景的阈值应不同，OLAP 查询比实时报表的阈值更宽松
SELECT '===== 关键告警指标阈值推荐 =====' AS alert_guide;

SELECT '┌─────────────────────────┬──────────────────┬──────────────────┬──────────────────┐' AS line;
SELECT '│ 指标                     │ WARNING          │ CRITICAL         │ 检查间隔         │' AS line;
SELECT '├─────────────────────────┼──────────────────┼──────────────────┼──────────────────┤' AS line;
SELECT '│ 副本延迟                 │ > 60秒           │ > 300秒          │ 1分钟            │' AS line;
SELECT '│ Part 数量（单表）        │ > 200个          │ > 500个          │ 5分钟            │' AS line;
SELECT '│ Mutation 卡住            │ > 1小时          │ > 4小时          │ 5分钟            │' AS line;
SELECT '│ 磁盘使用率               │ > 80%            │ > 90%            │ 5分钟            │' AS line;
SELECT '│ 查询超时                 │ > 10秒           │ > 60秒           │ 实时             │' AS line;
SELECT '│ 查询失败率               │ > 1%             │ > 5%             │ 5分钟            │' AS line;
SELECT '│ 合并队列积压             │ > 20个           │ > 50个           │ 1分钟            │' AS line;
SELECT '│ ZooKeeper 会话过期       │ > 0 过期         │ > 0 过期+只读    │ 30秒             │' AS line;
SELECT '│ 分区倾斜比               │ > 3              │ > 10             │ 1小时            │' AS line;
SELECT '│ 连接数(占上限%)          │ > 80%            │ > 95%            │ 1分钟            │' AS line;
SELECT '│ CPU 使用率               │ > 70%            │ > 90%            │ 1分钟            │' AS line;
SELECT '│ 内存使用率               │ > 80%            │ > 95%            │ 1分钟            │' AS line;
SELECT '│ 磁盘 IO 等待             │ > 30%            │ > 60%            │ 1分钟            │' AS line;
SELECT '└─────────────────────────┴──────────────────┴──────────────────┴──────────────────┘' AS line;

-- ==========================================
-- 2. 告警规则模板
-- ==========================================

-- 创建告警配置管理表
-- 【场景】统一管理所有告警规则，支持版本控制和批量更新
-- 【对比】相比手动配置告警，使用配置表可以统一管理、版本控制
CREATE TABLE IF NOT EXISTS ops_test.alert_config (
    category String,
    resource String,
    alert_type String,
    level String,
    threshold_value Float64,
    threshold_unit String,
    enabled UInt8 DEFAULT 1,
    cooldown_seconds UInt32 DEFAULT 300,
    description String,
    updated_at DateTime DEFAULT now()
)
ENGINE = MergeTree()
ORDER BY (category, resource, alert_type);

-- 插入标准告警配置
-- 【场景】初始化告警规则，适用于新集群搭建
INSERT INTO ops_test.alert_config (category, resource, alert_type, level, threshold_value, threshold_unit, enabled, cooldown_seconds, description) VALUES
('System', 'CPU', 'High Usage', 'WARNING', 70, 'percent', 1, 300, 'CPU 使用率超过 70%'),
('System', 'CPU', 'Critical Usage', 'CRITICAL', 90, 'percent', 1, 120, 'CPU 使用率超过 90%'),
('System', 'Memory', 'High Usage', 'WARNING', 80, 'percent', 1, 300, '内存使用率超过 80%'),
('System', 'Memory', 'Critical Usage', 'CRITICAL', 95, 'percent', 1, 120, '内存使用率超过 95%'),
('System', 'Disk', 'Low Space', 'WARNING', 80, 'percent', 1, 600, '磁盘使用率超过 80%'),
('System', 'Disk', 'Critical Low Space', 'CRITICAL', 90, 'percent', 1, 300, '磁盘使用率超过 90%'),
('System', 'Disk', 'IO High Wait', 'WARNING', 30, 'percent', 1, 300, '磁盘 IO 等待超过 30%'),
('Replication', 'Replica', 'Replica Lag', 'WARNING', 60, 'seconds', 1, 120, '副本延迟超过 60 秒'),
('Replication', 'Replica', 'Critical Replica Lag', 'CRITICAL', 300, 'seconds', 1, 60, '副本延迟超过 300 秒'),
('Replication', 'Replica', 'Session Expired', 'CRITICAL', 0, 'count', 1, 30, 'Keeper/ZooKeeper 会话过期'),
('Replication', 'Replica', 'Readonly Replica', 'CRITICAL', 0, 'count', 1, 30, '副本进入只读模式'),
('Data Quality', 'Partition', 'Partition Skew', 'WARNING', 3, 'ratio', 1, 3600, '分区倾斜度超过 3 倍'),
('Data Quality', 'Partition', 'Severe Partition Skew', 'CRITICAL', 10, 'ratio', 1, 1800, '分区倾斜度超过 10 倍'),
('Data Quality', 'Parts', 'Too Many Active Parts', 'WARNING', 200, 'count', 1, 600, '单表活跃 Parts 超过 200'),
('Data Quality', 'Parts', 'Critical Active Parts', 'CRITICAL', 500, 'count', 1, 300, '单表活跃 Parts 超过 500'),
('Operation', 'Merge', 'Merge Backlog', 'WARNING', 20, 'count', 1, 300, '合并队列积压超过 20 个'),
('Operation', 'Merge', 'Critical Merge Backlog', 'CRITICAL', 50, 'count', 1, 120, '合并队列积压超过 50 个'),
('Operation', 'Mutation', 'Stuck Mutation', 'WARNING', 3600, 'seconds', 1, 600, 'Mutation 执行超过 1 小时'),
('Operation', 'Mutation', 'Critical Stuck Mutation', 'CRITICAL', 14400, 'seconds', 1, 300, 'Mutation 执行超过 4 小时'),
('Operation', 'Connection', 'Too Many Connections', 'WARNING', 80, 'percent', 1, 300, '连接数超过上限的 80%'),
('Query', 'Performance', 'Slow Query', 'WARNING', 10, 'seconds', 1, 60, '查询执行时间超过 10 秒'),
('Query', 'Performance', 'Very Slow Query', 'CRITICAL', 60, 'seconds', 1, 30, '查询执行时间超过 60 秒'),
('Query', 'Errors', 'High Failure Rate', 'WARNING', 1, 'percent', 1, 600, '查询失败率超过 1%'),
('Query', 'Errors', 'Critical Failure Rate', 'CRITICAL', 5, 'percent', 1, 300, '查询失败率超过 5%');

-- 查看当前告警配置
SELECT * FROM ops_test.alert_config
ORDER BY category, resource, alert_type;

-- ==========================================
-- 3. 健康检查 SQL 模板
-- ==========================================

-- 3.1 副本延迟检查
-- 【场景】检查所有副本的延迟情况，触发延迟告警
-- 【原理】absolute_delay 表示副本落后主副本的秒数
-- 【坑】刚启动时延迟可能短暂偏高，建议持续 2 次采样再触发告警
SELECT
    now() AS alert_time,
    database,
    table,
    replica_name,
    'Replication' AS category,
    'Replica Lag' AS alert_type,
    CASE
        WHEN absolute_delay > 300 THEN 'CRITICAL'
        WHEN absolute_delay > 60 THEN 'WARNING'
        ELSE 'OK'
    END AS level,
    absolute_delay AS current_value,
    queue_size,
    is_readonly,
    is_session_expired,
    60 AS warning_threshold,
    300 AS critical_threshold
FROM system.replicas
WHERE absolute_delay > 60
ORDER BY absolute_delay DESC;

-- 3.2 Part 数量检查
-- 【场景】检查各表的活跃 Part 数量，触发碎片化告警
-- 【原理】Part 数量过多（> 500）说明合并压力大，影响查询性能
SELECT
    now() AS alert_time,
    database,
    table,
    'Data Quality' AS category,
    'Too Many Active Parts' AS alert_type,
    CASE
        WHEN part_count > 500 THEN 'CRITICAL'
        WHEN part_count > 200 THEN 'WARNING'
        ELSE 'OK'
    END AS level,
    part_count AS current_value,
    formatReadableSize(total_size) AS total_size,
    total_rows,
    200 AS warning_threshold,
    500 AS critical_threshold
FROM (
    SELECT
        database,
        table,
        count(*) AS part_count,
        sum(bytes_on_disk) AS total_size,
        sum(rows) AS total_rows
    FROM system.parts
    WHERE active = 1
      AND database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
    GROUP BY database, table
    HAVING count(*) > 200
)
ORDER BY part_count DESC;

-- 3.3 Mutation 卡住检查
-- 【场景】检测长时间未完成的 Mutation 操作
-- 【原理】Mutation 是异步操作，长时间未完成会阻塞该表的合并
SELECT
    now() AS alert_time,
    database,
    table,
    'Operation' AS category,
    'Stuck Mutation' AS alert_type,
    CASE
        WHEN elapsed_seconds > 14400 THEN 'CRITICAL'
        WHEN elapsed_seconds > 3600 THEN 'WARNING'
        ELSE 'OK'
    END AS level,
    elapsed_seconds AS current_value,
    command,
    parts_to_do,
    parts_done,
    round(progress * 100, 2) AS progress_percent,
    3600 AS warning_threshold,
    14400 AS critical_threshold
FROM (
    SELECT
        database,
        table,
        command,
        parts_to_do,
        parts_done,
        progress,
        dateDiff('second', create_time, now()) AS elapsed_seconds
    FROM system.mutations
    WHERE is_done = 0
      AND create_time < now() - INTERVAL 1 HOUR
)
ORDER BY elapsed_seconds DESC;

-- 3.4 磁盘空间检查
-- 【场景】磁盘空间不足是 ClickHouse 最常见的故障原因之一
-- 【坑】system.disks 中的 free_space 不是实时更新的，延迟约 1-2 分钟
SELECT
    now() AS alert_time,
    name AS disk_name,
    'System' AS category,
    'Low Disk Space' AS alert_type,
    CASE
        WHEN (free_space * 100.0 / total_space) < 10 THEN 'CRITICAL'
        WHEN (free_space * 100.0 / total_space) < 20 THEN 'WARNING'
        ELSE 'OK'
    END AS level,
    round(free_space * 100.0 / total_space, 2) AS free_percent,
    formatReadableSize(free_space) AS free_space_readable,
    formatReadableSize(total_space) AS total_space_readable,
    20 AS warning_threshold,
    10 AS critical_threshold
FROM system.disks
WHERE (free_space * 100.0 / total_space) < 20;

-- 3.5 查询超时检查
-- 【场景】识别执行时间超过阈值的慢查询
-- 【注意】使用 system.query_thread_log 替代 system.query_log
SET log_query_threads = 1;

SELECT
    now() AS alert_time,
    user,
    query_id,
    'Query' AS category,
    'Slow Query' AS alert_type,
    CASE
        WHEN query_duration_ms > 60000 THEN 'CRITICAL'
        WHEN query_duration_ms > 10000 THEN 'WARNING'
        ELSE 'OK'
    END AS level,
    query_duration_ms / 1000 AS duration_seconds,
    substring(query, 1, 200) AS query,
    read_rows,
    formatReadableSize(memory_usage) AS memory_used,
    10 AS warning_threshold_seconds,
    60 AS critical_threshold_seconds
FROM system.query_thread_log
WHERE type = 'QueryFinish'
  AND event_time >= now() - INTERVAL 5 MINUTE
  AND query NOT LIKE '%system.%'
  AND query_duration_ms > 10000
ORDER BY query_duration_ms DESC
LIMIT 20;

-- 3.6 查询失败率检查
-- 【场景】突然升高的查询失败率可能表明集群存在问题
SELECT
    now() AS alert_time,
    'Query Errors' AS category,
    'High Failure Rate' AS alert_type,
    CASE
        WHEN (failed * 100.0 / total) > 5 THEN 'CRITICAL'
        WHEN (failed * 100.0 / total) > 1 THEN 'WARNING'
        ELSE 'OK'
    END AS level,
    round(failed * 100.0 / total, 2) AS failure_rate_percent,
    total AS total_queries,
    failed AS failed_queries,
    1 AS warning_threshold_pct,
    5 AS critical_threshold_pct
FROM (
    SELECT
        countIf(type = 'QueryFinish') AS total,
        countIf(type = 'ExceptionWhileProcessing') AS failed
    FROM system.query_thread_log
    WHERE event_time >= now() - INTERVAL 5 MINUTE
)
HAVING (failed * 100.0 / total) > 1;

-- 3.7 合并队列积压检查
SELECT
    now() AS alert_time,
    database,
    table,
    'Operation' AS category,
    'Merge Backlog' AS alert_type,
    CASE
        WHEN backlog > 50 THEN 'CRITICAL'
        WHEN backlog > 20 THEN 'WARNING'
        ELSE 'OK'
    END AS level,
    backlog AS current_value,
    formatReadableSize(total_size_compressed) AS total_size,
    20 AS warning_threshold,
    50 AS critical_threshold
FROM (
    SELECT
        database,
        table,
        count(*) AS backlog,
        sum(total_size_bytes_compressed) AS total_size_compressed
    FROM system.merges
    GROUP BY database, table
)
WHERE backlog > 20
ORDER BY backlog DESC;

-- 3.8 复制队列异常检查
-- 【场景】复制队列中的异常可能表明数据损坏或配置问题
SELECT
    now() AS alert_time,
    database,
    table,
    replica_name,
    'Replication' AS category,
    'Replication Queue Error' AS alert_type,
    CASE
        WHEN count() > 10 THEN 'CRITICAL'
        WHEN count() > 0 THEN 'WARNING'
        ELSE 'OK'
    END AS level,
    count() AS error_count,
    max(exception_code) AS last_error_code,
    max(last_exception_time) AS last_error_time
FROM system.replication_queue
WHERE last_exception_time > now() - INTERVAL 1 HOUR
GROUP BY database, table, replica_name
HAVING count() > 0;

-- 3.9 非复制大表检查
-- 【场景】非复制表在节点故障时数据会丢失，大表尤需关注
SELECT
    now() AS alert_time,
    database,
    table,
    'Data Quality' AS category,
    'Non-replicated Large Table' AS alert_type,
    'WARNING' AS level,
    formatReadableSize(total_bytes) AS table_size,
    total_bytes AS bytes,
    engine,
    rows AS total_rows
FROM system.tables
WHERE database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
  AND engine NOT LIKE '%Replicated%'
  AND engine NOT LIKE '%View%'
  AND engine NOT LIKE '%Dictionary%'
  AND engine NOT LIKE '%Distributed%'
  AND total_bytes > 10737418240  -- 10GB
ORDER BY total_bytes DESC;

-- ==========================================
-- 4. 告警响应流程
-- ==========================================

-- 【场景】定义标准化的告警响应流程，确保故障快速处理
-- 【原理】不同级别的告警有不同的响应时间和处理流程

SELECT '===== 告警响应流程 =====' AS response_flow;

SELECT '【P0 - CRITICAL】'
UNION ALL
SELECT '  响应时间: < 5 分钟'
UNION ALL
SELECT '  处理方式: 立即电话通知值班工程师'
UNION ALL
SELECT '  升级机制: 15 分钟未处理升级到团队负责人'
UNION ALL
SELECT '  典型场景: 集群宕机、数据丢失、磁盘满'
UNION ALL
SELECT ''
UNION ALL
SELECT '【P1 - WARNING】'
UNION ALL
SELECT '  响应时间: < 30 分钟'
UNION ALL
SELECT '  处理方式: IM 通知，值班工程师在工作时间处理'
UNION ALL
SELECT '  升级机制: 2 小时未处理升级到 P0'
UNION ALL
SELECT '  典型场景: 副本延迟、磁盘使用率超过 80%'
UNION ALL
SELECT ''
UNION ALL
SELECT '【P2 - INFO】'
UNION ALL
SELECT '  响应时间: < 24 小时'
UNION ALL
SELECT '  处理方式: 记录到工单系统，排期处理'
UNION ALL
SELECT '  典型场景: Part 数量偏多、慢查询优化建议';

-- 创建告警响应流程配置表
CREATE TABLE IF NOT EXISTS ops_test.alert_response_policy (
    level String,
    response_timeout_seconds UInt32,
    escalation_delay_seconds UInt32,
    notification_channels String,
    escalation_channels String,
    description String
)
ENGINE = MergeTree()
ORDER BY level;

INSERT INTO ops_test.alert_response_policy VALUES
('CRITICAL', 300, 900, 'phone,sms,slack', 'team_lead_phone', 'P0 级别，5 分钟内响应，15 分钟升级'),
('WARNING', 1800, 7200, 'slack,email', 'phone', 'P1 级别，30 分钟内响应，2 小时升级'),
('INFO', 86400, 0, 'email', 'none', 'P2 级别，24 小时内处理，不升级');

-- 查看响应策略
SELECT * FROM ops_test.alert_response_policy;

-- ==========================================
-- 5. 告警通道配置
-- ==========================================

-- 创建告警通道配置表
-- 【场景】管理告警通知的分发渠道，支持多通道并行
-- 【坑】不要在数据库中存储真实的 Webhook URL 和密码，应从环境变量或配置中心获取
CREATE TABLE IF NOT EXISTS ops_test.alert_channels (
    channel_name String,
    channel_type String,  -- 'email', 'slack', 'webhook', 'dingtalk', 'wecom'
    config_json String,   -- 通道配置（不含敏感信息）
    enabled UInt8 DEFAULT 1,
    notify_levels String DEFAULT 'WARNING,CRITICAL',
    cooldown_seconds UInt32 DEFAULT 300,
    description String,
    created_at DateTime DEFAULT now()
)
ENGINE = MergeTree()
ORDER BY (channel_type, channel_name);

-- 插入示例告警通道配置
INSERT INTO ops_test.alert_channels (channel_name, channel_type, config_json, enabled, notify_levels, cooldown_seconds, description) VALUES
('ops-email', 'email', '{"recipients": "ops@example.com,oncall@example.com", "subject_prefix": "[CH Alert]"}', 1, 'WARNING,CRITICAL', 300, '运维团队邮件通知'),
('ops-slack', 'slack', '{"channel": "#clickhouse-alerts", "mention_users": "@oncall"}', 1, 'CRITICAL', 120, 'Slack 告警频道'),
('ops-webhook', 'webhook', '{"url": "${ALERT_WEBHOOK_URL}", "method": "POST", "format": "json"}', 1, 'WARNING,CRITICAL', 300, '通用 Webhook 回调'),
('ops-dingtalk', 'dingtalk', '{"webhook_url": "${DINGTALK_WEBHOOK}", "at_mobiles": ["138xxxx"]}', 1, 'CRITICAL', 60, '钉钉机器人告警'),
('ops-wecom', 'wecom', '{"webhook_url": "${WECOM_WEBHOOK}", "at_all": false}', 1, 'CRITICAL', 60, '企业微信机器人告警');

-- 查看告警通道配置
SELECT
    channel_name,
    channel_type,
    enabled,
    notify_levels,
    cooldown_seconds,
    description
FROM ops_test.alert_channels
ORDER BY channel_type, channel_name;

-- ==========================================
-- 6. 告警聚合与降噪
-- ==========================================

-- 【原理】告警聚合通过时间窗口和相似度匹配，将重复告警合并为一条
-- 【场景】在故障期间，大量重复告警会淹没真正需要关注的问题

-- 6.1 告警静默规则
-- 【场景】维护窗口期间需要静默某些告警，避免误报
CREATE TABLE IF NOT EXISTS ops_test.alert_silence_rules (
    rule_name String,
    resource_pattern String,       -- 匹配的资源名，支持通配符
    alert_type_pattern String,     -- 匹配的告警类型
    silence_start DateTime,
    silence_end DateTime,
    reason String,
    created_by String,
    created_at DateTime DEFAULT now()
)
ENGINE = MergeTree()
ORDER BY (resource_pattern, alert_type_pattern);

-- 插入静默规则示例
INSERT INTO ops_test.alert_silence_rules (rule_name, resource_pattern, alert_type_pattern, silence_start, silence_end, reason, created_by) VALUES
('Maintenance Window', 'Disk%', 'Low Space', now(), now() + INTERVAL 2 HOUR, '计划内磁盘扩容维护', 'admin'),
('Upgrade Window', 'Replica%', 'Replica Lag', now(), now() + INTERVAL 1 HOUR, '计划内滚动升级，副本延迟预期内', 'admin');

-- 查看当前生效的静默规则
SELECT *
FROM ops_test.alert_silence_rules
WHERE silence_start <= now() AND silence_end >= now()
ORDER BY silence_end;

-- 6.2 告警升级机制
-- 【场景】告警在规定时间内未处理，自动升级通知级别和渠道
CREATE TABLE IF NOT EXISTS ops_test.alert_escalation_policy (
    alert_type_pattern String,
    initial_level String,
    escalation_delay_seconds UInt32,
    escalation_level String,
    escalation_channel String,
    max_escalations UInt8 DEFAULT 3,
    description String
)
ENGINE = MergeTree()
ORDER BY alert_type_pattern;

INSERT INTO ops_test.alert_escalation_policy VALUES
('Disk%', 'WARNING', 1800, 'CRITICAL', 'phone', 3, '磁盘告警 30 分钟未处理升级为 CRITICAL 并电话通知'),
('Replica%', 'WARNING', 600, 'CRITICAL', 'dingtalk', 2, '副本延迟 10 分钟未处理升级为 CRITICAL'),
('Merge%', 'WARNING', 3600, 'CRITICAL', 'webhook', 2, '合并积压 1 小时未处理升级');

-- 查看升级策略
SELECT * FROM ops_test.alert_escalation_policy;

-- 6.3 告警历史统计
-- 【场景】分析告警趋势，优化告警规则
SELECT
    category,
    resource,
    alert_type,
    level,
    count() AS trigger_count,
    count(DISTINCT concat(toString(database), '.', toString(table))) AS affected_objects
FROM ops_test.active_alerts
GROUP BY category, resource, alert_type, level
ORDER BY trigger_count DESC;

-- ==========================================
-- 清理
-- ==========================================
DROP DATABASE IF EXISTS ops_test;

-- ============================================================================
-- 最佳实践：
-- 1. 阈值设置：分层设置（WARNING / CRITICAL），基于历史数据调整（quantile 分析）
-- 2. 告警通道：工作时间 IM 通知，非工作时间 CRITICAL 走电话/短信
-- 3. 告警降噪：合并重复告警，设置冷却时间，避免告警风暴
-- 4. 告警升级：长时间未处理自动升级，确保问题不被忽略
-- 5. 静默规则：维护窗口期间启用静默，避免误报
-- 6. 定期 review：每月 review 告警规则，淘汰无效规则
-- 7. 响应时间：CRITICAL < 5 分钟，WARNING < 30 分钟，INFO < 24 小时
-- 8. 告警自愈：对于已知问题可尝试自动修复（如自动触发 OPTIMIZE）
-- ============================================================================