-- ============================================================
-- ClickHouse Quota 与 Workload Management 示例
-- 集群：treasurycluster（CH 25.12.1.649）
-- 说明：本文件包含 Quota 和 Workload Management 的完整示例
-- 前置条件：无
-- 学习目标：理解 Quota 和 Workload Management 的配置与监控
-- ============================================================

-- 注意：本文件中的 DDL 语句（CREATE QUOTA / CREATE WORKLOAD GROUP）
-- 在 ClickHouse 25.12 中受 support 情况影响，部分命令可能需要
-- 特定的配置或版本支持。如果遇到 "SYNTAX_ERROR" 或 "UNKNOWN_FUNCTION"，
-- 请检查版本兼容性。

-- ============================================================
-- 第一部分：Quota 基础操作
-- ============================================================

-- 【原理】Quota 是 ClickHouse 中用于限制用户在指定时间窗口内
-- 资源使用量的机制。Quota 在查询开始前检查，已开始的查询不受影响。
-- Quota 配置持久化存储在 access_control_path 目录，重启不丢失。

-- 场景：创建分析师角色的每日 Quota，限制每天查询时间 1 小时
-- 对比：XML 配置 vs SQL 创建，推荐使用 SQL 方式
-- 坑：PER DAY 是自然日，不是 24 小时滑动窗口

-- 创建基本 Quota：限制每天最多查询 1 小时
CREATE QUOTA IF NOT EXISTS daily_analyst_quota
WITH LIMITS
    QUERY_TIME = 3600 PER DAY,
    READ_ROWS = 100000000 PER DAY WITH NOTIFICATIONS
TO analyst_role;

-- 创建多维度 Quota
CREATE QUOTA IF NOT EXISTS power_user_quota
WITH LIMITS
    QUERY_TIME = 7200 PER WEEK,
    READ_ROWS = 1000000000 PER WEEK,
    RESULT_ROWS = 10000000 PER WEEK,
    ERRORS = 100 PER WEEK
TO power_user_role;

-- 创建带 Quota Key 的 Quota
CREATE QUOTA IF NOT EXISTS tenant_quota
WITH LIMITS
    QUERY_TIME = 3600 PER DAY,
    READ_BYTES = 10737418240 PER DAY  -- 10 GB
KEYED BY USER_NAME
TO tenant_role;

-- 创建带多个间隔的 Quota（每日 + 每周限制）
CREATE QUOTA IF NOT EXISTS multi_interval_quota
WITH LIMITS
    QUERY_TIME = 3600 PER DAY,
    QUERY_TIME = 14400 PER WEEK,
    READ_ROWS = 500000000 PER WEEK
KEYED BY USER_NAME
TO analyst_role;

-- ============================================================
-- 第二部分：Workload Group 基础操作
-- ============================================================

-- 【原理】Workload Group（从 CH 24.x 引入）是比 Quota 更高级的
-- 资源调度机制。它将查询分组到不同 Workload Group 中，为每个组
-- 分配独立的资源池并设置优先级调度策略。
-- Workload Group 的优先级是调度优先，不是抢占式。低优先级查询
-- 正在执行时，不会因高优先级查询到达而被中断。

-- 场景：创建生产环境 Workload Group
-- 对比：round_robin vs fifo 调度策略
-- round_robin：轮询调度，每个等待查询按顺序获得执行机会
-- fifo：先入先出，按提交顺序执行

-- 创建生产环境 Workload Group
CREATE WORKLOAD GROUP IF NOT EXISTS prod_group
SETTINGS
    max_concurrent_queries = 10,
    max_memory_usage = 50000000000,     -- 50 GB
    priority = 1,
    scheduling_policy = 'round_robin';

-- 创建 ETL Workload Group
CREATE WORKLOAD GROUP IF NOT EXISTS etl_group
SETTINGS
    max_concurrent_queries = 3,
    max_memory_usage = 30000000000,     -- 30 GB
    priority = 5,
    scheduling_policy = 'fifo';

-- 创建 Ad-hoc 查询 Workload Group
CREATE WORKLOAD GROUP IF NOT EXISTS adhoc_group
SETTINGS
    max_concurrent_queries = 5,
    max_memory_usage = 20000000000,     -- 20 GB
    priority = 10,
    max_queued_queries = 20,
    max_queued_waiting_ms = 30000;      -- 30 秒排队超时

-- 将 Workload Group 绑定到用户/角色
CREATE USER IF NOT EXISTS prod_user
IDENTIFIED WITH sha256_password BY 'ProdUser123!'
SETTINGS workload_group = 'prod_group';

CREATE ROLE IF NOT EXISTS etl_role
SETTINGS workload_group = 'etl_group';

-- ============================================================
-- 第三部分：资源限制设置
-- ============================================================

-- 【原理】ClickHouse 的资源限制发生在查询执行管道的每个阶段。
-- 内存限制：当内存使用超过限制时，ClickHouse 会立即终止查询并释放内存
-- 时间限制：在 Pipeline 步骤完成后检查，不是每一步执行过程中中断
-- 并发限制：查询级别限制，不是 CPU 绑定

-- 场景：创建一个内存限制严格的分析角色
-- 对比：max_memory_usage vs max_memory_usage_for_user
-- max_memory_usage：单个查询最大内存
-- max_memory_usage_for_user：单用户所有查询总内存上限

-- 创建一个内存限制严格的分析角色
CREATE ROLE IF NOT EXISTS memory_limited_role
SETTINGS
    max_memory_usage = 2147483648,          -- 2 GB
    max_memory_usage_for_user = 4294967296,  -- 4 GB
    max_join_size = 1073741824,              -- 1 GB（JOIN 限制）
    max_bytes_before_external_group_by = 1073741824;  -- 1 GB（触发外部聚合）

-- 场景：创建时间限制严格的分析角色
-- 坑：max_execution_time 在 Pipeline 步骤完成后才检查，不是实时中断
CREATE ROLE IF NOT EXISTS time_limited_analyst
SETTINGS
    max_execution_time = 60,            -- 最多 1 分钟
    max_execution_time_for_user = 300,   -- 每用户最多 5 分钟
    timeout_before_checking_execution_speed = 0;

-- 场景：创建数据量限制角色
CREATE ROLE IF NOT EXISTS traffic_limited_role
SETTINGS
    max_rows_to_read = 100000000,         -- 1 亿行
    max_bytes_to_read = 10737418240,      -- 10 GB
    max_result_rows = 1000000,            -- 100 万行
    max_result_bytes = 1073741824;        -- 1 GB

-- 场景：创建并发限制角色
CREATE ROLE IF NOT EXISTS concurrent_limited_role
SETTINGS
    max_concurrent_queries_for_user = 3,
    max_concurrent_queries = 50;

-- 场景：创建网络限制角色
CREATE ROLE IF NOT EXISTS network_limited_role
SETTINGS
    max_network_bandwidth = 104857600,    -- 100 MB/s
    max_network_bytes = 10737418240,      -- 10 GB
    max_network_bandwidth_for_user = 209715200;  -- 200 MB/s

-- ============================================================
-- 第四部分：多层级服务 SLA 示例
-- ============================================================

-- 【原理】多层级服务 SLA 通过将不同服务等级的用户分配到不同的
-- Workload Group 实现资源隔离，并通过 Quota 限制每日使用量。
-- 优先级数值越小，调度优先级越高。

-- 场景：铂金/黄金/银牌用户分级
-- 对比：不同级别的资源配额差异

-- 铂金用户：高优先级，大资源
CREATE WORKLOAD GROUP IF NOT EXISTS platinum_group
SETTINGS
    max_concurrent_queries = 20,
    max_memory_usage = 80000000000,     -- 80 GB
    priority = 1,
    scheduling_policy = 'round_robin';

-- 黄金用户：中优先级，中等资源
CREATE WORKLOAD GROUP IF NOT EXISTS gold_group
SETTINGS
    max_concurrent_queries = 15,
    max_memory_usage = 50000000000,     -- 50 GB
    priority = 5,
    scheduling_policy = 'round_robin';

-- 银牌用户：低优先级，有限资源
CREATE WORKLOAD GROUP IF NOT EXISTS silver_group
SETTINGS
    max_concurrent_queries = 10,
    max_memory_usage = 20000000000,     -- 20 GB
    priority = 10,
    scheduling_policy = 'round_robin';

-- 创建角色并绑定 Workload Group
CREATE ROLE IF NOT EXISTS platinum_role
SETTINGS workload_group = 'platinum_group';

CREATE ROLE IF NOT EXISTS gold_role
SETTINGS workload_group = 'gold_group';

CREATE ROLE IF NOT EXISTS silver_role
SETTINGS workload_group = 'silver_group';

-- 创建 Quota（每日限制）
CREATE QUOTA IF NOT EXISTS platinum_quota
WITH LIMITS
    QUERY_TIME = 14400 PER DAY,          -- 4 小时
    READ_BYTES = 107374182400 PER DAY    -- 100 GB
KEYED BY USER_NAME
TO platinum_role;

CREATE QUOTA IF NOT EXISTS gold_quota
WITH LIMITS
    QUERY_TIME = 7200 PER DAY,           -- 2 小时
    READ_BYTES = 53687091200 PER DAY     -- 50 GB
KEYED BY USER_NAME
TO gold_role;

CREATE QUOTA IF NOT EXISTS silver_quota
WITH LIMITS
    QUERY_TIME = 3600 PER DAY,           -- 1 小时
    READ_BYTES = 10737418240 PER DAY     -- 10 GB
KEYED BY USER_NAME
TO silver_role;

-- ============================================================
-- 第五部分：多租户资源隔离
-- ============================================================

-- 场景：为不同规模的租户分配不同的资源池
-- 对比：small vs large 租户的资源差异

-- 租户 1：小租户，严格限制
CREATE WORKLOAD GROUP IF NOT EXISTS tenant_small_group
SETTINGS
    max_concurrent_queries = 3,
    max_memory_usage = 5000000000,      -- 5 GB
    priority = 10,
    scheduling_policy = 'round_robin';

CREATE ROLE IF NOT EXISTS tenant_small_role
SETTINGS workload_group = 'tenant_small_group';

CREATE QUOTA IF NOT EXISTS tenant_small_quota
WITH LIMITS
    QUERY_TIME = 1800 PER DAY,           -- 30 分钟
    READ_BYTES = 5368709120 PER DAY      -- 5 GB
KEYED BY USER_NAME
TO tenant_small_role;

-- 租户 2：大租户，宽松限制
CREATE WORKLOAD GROUP IF NOT EXISTS tenant_large_group
SETTINGS
    max_concurrent_queries = 20,
    max_memory_usage = 50000000000,     -- 50 GB
    priority = 3,
    scheduling_policy = 'round_robin';

CREATE ROLE IF NOT EXISTS tenant_large_role
SETTINGS workload_group = 'tenant_large_group';

CREATE QUOTA IF NOT EXISTS tenant_large_quota
WITH LIMITS
    QUERY_TIME = 14400 PER DAY,          -- 4 小时
    READ_BYTES = 107374182400 PER DAY    -- 100 GB
KEYED BY USER_NAME
TO tenant_large_role;

-- ============================================================
-- 第六部分：监控与诊断
-- ============================================================

-- 查看所有 Quota 定义
SELECT 
    name,
    storage,
    source
FROM system.quotas
ORDER BY name;

-- 查看 Quota 详细限制
SELECT 
    name,
    duration,
    is_randomized_interval,
    apply_to_all,
    apply_to_list,
    apply_to_except
FROM system.quota_limits
ORDER BY name;

-- 查看 Quota 使用情况
SELECT 
    quota_name,
    user_name,
    queries,
    max_queries,
    query_time,
    max_query_time,
    read_rows,
    max_read_rows,
    read_bytes,
    max_read_bytes,
    written_rows,
    max_written_rows,
    written_bytes,
    max_written_bytes,
    formatReadableTimeDelta(query_time) as query_time_str,
    formatReadableTimeDelta(max_query_time) as max_query_time_str,
    formatReadableSize(read_bytes) as read_bytes_str,
    formatReadableSize(max_read_bytes) as max_read_bytes_str
FROM system.quota_usage
ORDER BY quota_name, user_name;

-- 查看 Workload Group 定义
SELECT 
    name,
    max_concurrent_queries,
    max_memory_usage,
    formatReadableSize(max_memory_usage) as max_memory_str,
    priority,
    scheduling_policy,
    max_queued_queries,
    max_queued_waiting_ms
FROM system.workload_groups
ORDER BY priority;

-- 查看 Workload Group 当前状态
SELECT 
    name,
    running_queries,
    waiting_queries,
    formatReadableSize(memory_usage) as memory_str,
    formatReadableSize(disk_usage) as disk_str,
    cpu_usage_percent
FROM system.workload_group_stats
ORDER BY name;

-- 查看查询所属的 Workload Group
SELECT 
    query_id,
    user,
    substring(query, 1, 80) as query_preview,
    workload_group,
    elapsed,
    formatReadableSize(memory_usage) as memory_str,
    read_rows
FROM system.processes
ORDER BY elapsed DESC;

-- 查看被 Quota 限制的查询
SELECT 
    event_time,
    user,
    substring(query, 1, 80) as query_preview,
    exception_code,
    exception_text
FROM system.query_log
WHERE exception_code = 241  -- QUOTA_EXCEEDED
  AND event_time >= now() - INTERVAL 1 DAY
ORDER BY event_time DESC
LIMIT 10;

-- 查看内存超限的查询
SELECT 
    event_time,
    user,
    substring(query, 1, 80) as query_preview,
    formatReadableSize(memory_usage) as memory_str,
    exception_text
FROM system.query_log
WHERE exception_code = 241  -- MEMORY_LIMIT_EXCEEDED
  AND event_time >= now() - INTERVAL 1 DAY
ORDER BY memory_usage DESC
LIMIT 10;

-- 查看超时查询
SELECT 
    event_time,
    user,
    substring(query, 1, 80) as query_preview,
    query_duration_ms / 1000 as duration_sec,
    exception_text
FROM system.query_log
WHERE exception_code = 159  -- TIMEOUT_EXCEEDED
  AND event_time >= now() - INTERVAL 1 DAY
ORDER BY query_duration_ms DESC
LIMIT 10;

-- 清理示例资源（生产环境谨慎使用）
-- DROP QUOTA IF EXISTS daily_analyst_quota;
-- DROP QUOTA IF EXISTS power_user_quota;
-- DROP QUOTA IF EXISTS tenant_quota;
-- DROP QUOTA IF EXISTS multi_interval_quota;
-- DROP QUOTA IF EXISTS platinum_quota;
-- DROP QUOTA IF EXISTS gold_quota;
-- DROP QUOTA IF EXISTS silver_quota;
-- DROP QUOTA IF EXISTS tenant_small_quota;
-- DROP QUOTA IF EXISTS tenant_large_quota;
-- 
-- DROP WORKLOAD GROUP IF EXISTS prod_group;
-- DROP WORKLOAD GROUP IF EXISTS etl_group;
-- DROP WORKLOAD GROUP IF EXISTS adhoc_group;
-- DROP WORKLOAD GROUP IF EXISTS platinum_group;
-- DROP WORKLOAD GROUP IF EXISTS gold_group;
-- DROP WORKLOAD GROUP IF EXISTS silver_group;
-- DROP WORKLOAD GROUP IF EXISTS tenant_small_group;
-- DROP WORKLOAD GROUP IF EXISTS tenant_large_group;
-- 
-- DROP USER IF EXISTS prod_user;
-- DROP ROLE IF EXISTS memory_limited_role;
-- DROP ROLE IF EXISTS time_limited_analyst;
-- DROP ROLE IF EXISTS traffic_limited_role;
-- DROP ROLE IF EXISTS concurrent_limited_role;
-- DROP ROLE IF EXISTS network_limited_role;
-- DROP ROLE IF EXISTS platinum_role;
-- DROP ROLE IF EXISTS gold_role;
-- DROP ROLE IF EXISTS silver_role;
-- DROP ROLE IF EXISTS etl_role;
-- DROP ROLE IF EXISTS tenant_small_role;
-- DROP ROLE IF EXISTS tenant_large_role;