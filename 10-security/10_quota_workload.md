# Quota 与 Workload Management

Quota（配额）和 Workload Management（工作负载管理）是 ClickHouse 安全体系中资源管控的核心机制。它们确保多用户环境下各工作负载不会相互干扰，防止单个查询或用户耗尽集群资源。

## 目录

- [Quota 与 Workload Management 概述](#quota-与-workload-management-概述)
- [Quota 核心机制](#quota-核心机制)
- [Workload Management 核心机制](#workload-management-核心机制)
- [Quota 配置方式](#quota-配置方式)
- [Workload Management 配置方式](#workload-management-配置方式)
- [资源限制类型详解](#资源限制类型详解)
- [Quota 监控与诊断](#quota-监控与诊断)
- [Workload 组调度策略](#workload-组调度策略)
- [实战示例](#实战示例)
- [常见误区与最佳实践](#常见误区与最佳实践)

## Quota 与 Workload Management 概述

### 为什么要用 Quota 和 Workload Management？

| 场景 | 问题 | 解决方案 |
|------|------|---------|
| **多用户共享集群** | 一个用户的慢查询占满所有 CPU | 按用户设置 `max_execution_time` |
| **内存泄漏** | 大聚合查询撑爆内存，OOM 导致进程重启 | 设置 `max_memory_usage` |
| **写入风暴** | 大量并发 INSERT 导致 Merge 队列积压 | 限制 `max_concurrent_queries_for_user` |
| **查询雪崩** | 突发查询量超过集群处理能力 | 设置 `max_concurrent_queries` |
| **成本控制** | 资源消耗无法追踪，账单失控 | 按 Quota 使用量计费 |
| **SLA 保障** | 高优查询被低优查询阻塞 | Workload 分组 + 优先级调度 |

### Quota vs Workload Management 对比

| 维度 | Quota | Workload Management |
|------|-------|-------------------|
| **作用范围** | 用户/角色级别 | 全局 + 用户/角色级别 |
| **管控粒度** | 资源使用量（内存/时间/行数/字节数） | 查询优先级、并发控制、资源分配 |
| **时间维度** | 支持时间窗口（每日/每周/每月）重置 | 实时调度 |
| **核心理念** | "限制"——防止超额使用 | "调度"——在不同工作负载间分配资源 |
| **典型场景** | 租户 A 每天最多查 1 小时 CPU 时间 | 生产查询优先级高于 ETL 查询 |

### Quota 与 Workload Management 的关系

```
                    ┌────────────────────────────────┐
                    │      ClickHouse 资源管控体系      │
                    ├────────────┬───────────────────┤
                    │   Quota    │  Workload Management│
                    │  (限制层)   │    (调度层)          │
                    ├────────────┼───────────────────┤
                    │  max_mem   │  workload_group     │
                    │  max_time  │  priority           │
                    │  max_rows  │  max_concurrent     │
                    │  max_bytes │  scheduling_policy  │
                    │  quota_key │  resource_sharing   │
                    └────────────┴───────────────────┘
```

## Quota 核心机制

### 什么是 Quota

Quota 是 ClickHouse 中用于限制用户在指定时间窗口内资源使用量的机制。Quota 的核心概念：

1. **配额键（Quota Key）**：标识资源消耗的归属，可以是用户名、IP 地址、自定义键
2. **时间窗口**：配额在指定时间周期内有效，到期自动重置
3. **资源维度**：可限制的维度包括查询时间、读取行数/字节数、写入行数/字节数、执行延迟等
4. **硬限制与软限制**：硬限制（超出即拒绝）和软限制（超出时触发告警）

### Quota 的工作原理

每次查询执行时，ClickHouse 会：

1. 检查当前用户的 Quota 配置
2. 计算当前时间窗口内已使用的资源量
3. 判断本次查询是否会超出配额
4. 如果超出：拒绝查询（硬限制）或记录告警（软限制）
5. 如果未超出：允许执行，并在查询完成后更新使用量

```
查询到达 → 匹配 Quota → 读取当前使用量 → 判断是否超限 → 允许/拒绝
                              ↑                          │
                              └── 查询完成 → 更新使用量 ←─┘
```

### Quota 的存储与同步

Quota 配置存储在 `access_control_path` 目录下（默认 `/var/lib/clickhouse/access/`），通过 SQL 创建的 Quota 会自动持久化到该目录，并在集群内通过 Keeper 同步。

```sql
-- 查看 Quota 存储路径
SELECT name, storage, source
FROM system.quotas;
```

## Workload Management 核心机制

### 什么是 Workload Management

Workload Management（工作负载管理，从 CH 24.x 引入）是比 Quota 更高级的资源调度机制。它允许将查询分组到不同的 Workload Group 中，为每个组分配独立的资源池，并设置优先级调度策略。

### Workload Group 的关键属性

| 属性 | 说明 | 默认值 |
|------|------|--------|
| `max_concurrent_queries` | 组内最大并发查询数 | 0（不限制） |
| `max_memory_usage` | 组内总内存使用上限 | 0（不限制） |
| `priority` | 调度优先级（数值越小优先级越高） | 0 |
| `scheduling_policy` | 调度策略（round_robin / fifo） | round_robin |
| `max_queued_queries` | 最大排队查询数 | 0（不限制） |
| `max_queued_waiting_ms` | 查询最大排队等待时间 | 0（不限制） |

### Workload 调度流程

```
查询到达 → 匹配 Workload Group → 检查并发限制 → 等待队列 → 调度执行
                                    │                 │
                                    ▼                 ▼
                              并发已满 → 排队     超时 → 拒绝
```

### Quota 与 Workload Management 的协同

在实际生产环境中，Quota 和 Workload Management 通常一起使用：

- **Workload Management** 负责实时调度和资源分配
- **Quota** 负责长期维度的资源使用限制（如"每天最多 1 小时 CPU 时间"）

## Quota 配置方式

### 方式一：通过 SQL 创建 Quota（推荐）

```sql
-- 创建基本 Quota：限制每天最多查询 1 小时
CREATE QUOTA IF NOT EXISTS daily_analyst_quota
WITH LIMITS
    -- 硬限制：执行时间每天最多 3600 秒
    QUERY_TIME = 3600 PER DAY,
    -- 软限制：读取行数每天最多 1 亿
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
```

### 方式二：通过 XML 配置 Quota（传统方式）

```xml
<!-- config.d/quotas.xml -->
<clickhouse>
    <quotas>
        <daily_analyst>
            <interval>
                <duration>86400</duration>  <!-- 24 小时 -->
                <queries>0</queries>        <!-- 0 表示不限制 -->
                <errors>0</errors>
                <result_rows>10000000</result_rows>
                <read_rows>100000000</read_rows>
                <execution_time>3600</execution_time>  <!-- 秒 -->
            </interval>
        </daily_analyst>
        
        <monthly_power_user>
            <interval>
                <duration>2592000</duration>  <!-- 30 天 -->
                <queries>100000</queries>
                <errors>1000</errors>
                <result_rows>0</result_rows>
                <read_rows>0</read_rows>
                <execution_time>72000</execution_time>  <!-- 20 小时 -->
            </interval>
        </monthly_power_user>
    </quotas>
</clickhouse>
```

### 方式三：通过用户/角色设置限制

```sql
-- 直接设置用户级别的资源限制
CREATE USER IF NOT EXISTS limited_user
IDENTIFIED WITH sha256_password BY 'LimitedUser123!'
SETTINGS
    max_memory_usage = 5000000000,       -- 5 GB
    max_execution_time = 600,             -- 10 分钟
    max_concurrent_queries_for_user = 3,
    max_rows_to_read = 100000000,         -- 1 亿行
    max_bytes_to_read = 10737418240;      -- 10 GB
```

## Workload Management 配置方式

### 创建 Workload Group

```sql
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
```

### 将 Workload Group 绑定到用户/角色

```sql
-- 为用户分配 Workload Group
CREATE USER IF NOT EXISTS prod_user
IDENTIFIED WITH sha256_password BY 'ProdUser123!'
SETTINGS workload_group = 'prod_group';

-- 为角色分配 Workload Group
CREATE ROLE IF NOT EXISTS etl_role
SETTINGS workload_group = 'etl_group';
```

## 资源限制类型详解

### 内存限制

| 设置项 | 说明 | 建议值 |
|--------|------|--------|
| `max_memory_usage` | 单个查询最大内存(MergeTree 引擎) | 总内存的 20-50% |
| `max_memory_usage_for_user` | 单用户总内存上限 | 总内存的 40-60% |
| `max_memory_usage_for_all_queries` | 全局内存上限 | 总内存的 80% |
| `memory_overcommit_ratio_denominator` | 内存超卖比例 | 默认 1GB |

#### 内存限制原理

ClickHouse 对内存使用量的跟踪发生在查询执行管道的每个阶段。当内存使用超过限制时，ClickHouse 会：

1. 立即终止当前查询
2. 释放已分配的内存
3. 记录 `MEMORY_LIMIT_EXCEEDED` 异常到 `query_log`

```sql
-- 创建一个内存限制严格的角色
CREATE ROLE IF NOT EXISTS memory_limited_role
SETTINGS
    max_memory_usage = 2147483648,        -- 2 GB
    max_memory_usage_for_user = 4294967296, -- 4 GB
    max_join_size = 1073741824,            -- 1 GB（JOIN 限制）
    max_bytes_before_external_group_by = 1073741824;  -- 1 GB（触发外部聚合）
```

### 时间限制

| 设置项 | 说明 | 建议值 |
|--------|------|--------|
| `max_execution_time` | 单个查询最大执行时间(秒) | 300-3600 |
| `max_execution_time_for_user` | 单用户总执行时间上限 | 3600-14400 |
| `timeout_before_checking_execution_speed` | 检查执行速度前的等待时间 | 10 秒 |

#### 时间限制的底层机制

ClickHouse 的查询执行是基于 Pipeline 模型的。时间限制的检查发生在每个 Pipeline 处理步骤完成后，而不是在每一步执行过程中中断。这意味着：

- 如果单个步骤的执行时间超过 `max_execution_time`，查询**不会立即被终止**
- 查询会在当前步骤完成后被终止
- 对于长时间运行的单个步骤（如大数据量的 GROUP BY），可能需要结合 `max_memory_usage` 一起限制

```sql
-- 创建时间限制严格的分析角色
CREATE ROLE IF NOT EXISTS time_limited_analyst
SETTINGS
    max_execution_time = 60,          -- 最多 1 分钟
    max_execution_time_for_user = 300, -- 每用户最多 5 分钟
    timeout_before_checking_execution_speed = 0;
```

### 数据量限制

| 设置项 | 说明 | 适用场景 |
|--------|------|---------|
| `max_rows_to_read` | 最多读取行数 | 防止全表扫描 |
| `max_bytes_to_read` | 最多读取字节数 | 防止 I/O 过载 |
| `max_rows_to_read_for_user` | 单用户总读取行数 | 用户级限制 |
| `max_result_rows` | 结果集最大行数 | 防止大结果集 |
| `max_result_bytes` | 结果集最大字节数 | 防止大结果集 |

```sql
-- 创建数据量限制角色
CREATE ROLE IF NOT EXISTS traffic_limited_role
SETTINGS
    max_rows_to_read = 100000000,       -- 1 亿行
    max_bytes_to_read = 10737418240,    -- 10 GB
    max_result_rows = 1000000,          -- 100 万行
    max_result_bytes = 1073741824;      -- 1 GB
```

### 并发限制

| 设置项 | 说明 | 建议值 |
|--------|------|--------|
| `max_concurrent_queries_for_user` | 单用户最大并发查询数 | 3-10 |
| `max_concurrent_queries` | 全局最大并发查询数 | 100-1000 |
| `max_concurrent_insert_queries` | 最大并发 INSERT 查询数 | 50-100 |

#### 并发控制的原理

ClickHouse 的并发控制基于查询计数。当一个查询到达时：

1. 检查当前正在执行的查询数
2. 如果达到上限，查询被放入等待队列（Workload Group）或直接被拒绝
3. 查询完成后，从计数中减除

**注意**：并发限制不是 CPU 绑定，而是查询级别限制。如果一个查询使用多个 CPU 核心，它仍然只算一个并发查询。

```sql
-- 创建并发限制角色
CREATE ROLE IF NOT EXISTS concurrent_limited_role
SETTINGS
    max_concurrent_queries_for_user = 3,
    max_concurrent_queries = 50;
```

### 写入限制

| 设置项 | 说明 | 建议值 |
|--------|------|--------|
| `max_partitions_per_insert_block` | 单个 INSERT 块最大分区数 | 100-200 |
| `max_block_size` | 插入块大小 | 默认 65409 |
| `min_insert_block_size_rows` | 最小插入块行数 | 默认 1048449 |
| `max_insert_delayed_streams_for_query` | 延迟插入流数 | 默认 0 |

```sql
-- 创建写入限制角色
CREATE ROLE IF NOT EXISTS write_limited_role
SETTINGS
    max_partitions_per_insert_block = 100,
    min_insert_block_size_rows = 1000000,
    max_insert_threads = 2;
```

### 网络与带宽限制

| 设置项 | 说明 | 适用场景 |
|--------|------|---------|
| `max_network_bandwidth` | 最大网络带宽(bytes/s) | 跨分片查询 |
| `max_network_bytes` | 最大网络传输量 | 分布式查询 |
| `max_network_bandwidth_for_user` | 每用户网络带宽 | 用户级限制 |

```sql
-- 创建网络限制角色
CREATE ROLE IF NOT EXISTS network_limited_role
SETTINGS
    max_network_bandwidth = 104857600,   -- 100 MB/s
    max_network_bytes = 10737418240,     -- 10 GB
    max_network_bandwidth_for_user = 209715200;  -- 200 MB/s
```

## Quota 监控与诊断

### 查看 Quota 定义

```sql
-- 查看所有 Quota
SELECT 
    name,
    quota_type,
    is_current_quota,
    max_concurrent_queries,
    max_query_time,
    max_read_rows,
    max_read_bytes
FROM system.quotas;

-- 查看 Quota 详细限制
SELECT 
    name,
    duration,
    is_randomized_interval,
    apply_to_all,
    apply_to_list,
    apply_to_except
FROM system.quota_limits;

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
    max_written_bytes
FROM system.quota_usage;
```

### 查看 Workload Group 状态

```sql
-- 查看 Workload Group 定义
SELECT 
    name,
    max_concurrent_queries,
    max_memory_usage,
    priority,
    scheduling_policy,
    max_queued_queries,
    max_queued_waiting_ms
FROM system.workload_groups;

-- 查看 Workload Group 当前状态
SELECT 
    name,
    running_queries,
    waiting_queries,
    memory_usage,
    disk_usage,
    cpu_usage_percent
FROM system.workload_group_stats;

-- 查看查询所属的 Workload Group
SELECT 
    query_id,
    user,
    query,
    workload_group,
    elapsed,
    memory_usage,
    read_rows
FROM system.processes
ORDER BY elapsed DESC;
```

### 监控资源使用超限

```sql
-- 查看被 Quota 限制的查询
SELECT 
    event_time,
    user,
    query,
    exception_code,
    exception_text
FROM system.query_log
WHERE exception_code = 241  -- QUOTA_EXCEEDED
  AND event_time >= now() - INTERVAL 1 DAY
ORDER BY event_time DESC;

-- 查看内存超限的查询
SELECT 
    event_time,
    user,
    query,
    formatReadableSize(memory_usage) as memory_str,
    exception_text
FROM system.query_log
WHERE exception_code = 241  -- MEMORY_LIMIT_EXCEEDED
  AND event_time >= now() - INTERVAL 1 DAY
ORDER BY memory_usage DESC;

-- 查看超时查询
SELECT 
    event_time,
    user,
    query,
    query_duration_ms / 1000 as duration_sec,
    exception_text
FROM system.query_log
WHERE exception_code = 159  -- TIMEOUT_EXCEEDED
  AND event_time >= now() - INTERVAL 1 DAY
ORDER BY query_duration_ms DESC;
```

## Workload 组调度策略

### 调度策略详解

| 策略 | 说明 | 适用场景 |
|------|------|---------|
| **round_robin** | 轮询调度，每个等待查询按顺序获得执行机会 | 多租户场景，公平分配 |
| **fifo** | 先入先出，按提交顺序执行 | ETL 作业，关键路径 |
| **priority** | 按优先级执行，高优先级先执行 | 生产查询优先于报表 |

### 多级调度示例

```sql
-- 创建多级 Workload Group
-- 第 1 级：关键业务查询
CREATE WORKLOAD GROUP IF NOT EXISTS critical_group
SETTINGS
    max_concurrent_queries = 5,
    max_memory_usage = 30000000000,    -- 30 GB
    priority = 1,                       -- 最高优先级
    scheduling_policy = 'fifo';

-- 第 2 级：常规分析查询
CREATE WORKLOAD GROUP IF NOT EXISTS normal_group
SETTINGS
    max_concurrent_queries = 10,
    max_memory_usage = 40000000000,    -- 40 GB
    priority = 5,
    scheduling_policy = 'round_robin';

-- 第 3 级：后台 ETL 查询
CREATE WORKLOAD GROUP IF NOT EXISTS background_group
SETTINGS
    max_concurrent_queries = 3,
    max_memory_usage = 10000000000,    -- 10 GB
    priority = 10,                      -- 最低优先级
    scheduling_policy = 'fifo';

-- 第 4 级：Ad-hoc 查询（限制最严格）
CREATE WORKLOAD GROUP IF NOT EXISTS adhoc_group
SETTINGS
    max_concurrent_queries = 3,
    max_memory_usage = 5000000000,     -- 5 GB
    priority = 15,
    scheduling_policy = 'round_robin',
    max_queued_queries = 5,
    max_queued_waiting_ms = 10000;     -- 10 秒排队超时
```

## 实战示例

### 示例 1：多层级服务 SLA

```sql
-- 创建基于服务等级的 Workload 分组
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
```

### 示例 2：防止查询风暴

```sql
-- 创建紧急防护 Workload Group
CREATE WORKLOAD GROUP IF NOT EXISTS emergency_group
SETTINGS
    max_concurrent_queries = 100,
    max_memory_usage = 100000000000,    -- 100 GB
    priority = 0,                        -- 最高优先级
    scheduling_policy = 'fifo';

-- 创建普通 Workload Group
CREATE WORKLOAD GROUP IF NOT EXISTS normal_group
SETTINGS
    max_concurrent_queries = 50,
    max_memory_usage = 50000000000,     -- 50 GB
    priority = 5,
    scheduling_policy = 'round_robin';

-- 创建全局并发限制
CREATE QUOTA IF NOT EXISTS global_concurrency_quota
WITH LIMITS
    MAX_CONCURRENT_QUERIES = 200
KEYED BY IP_ADDRESS
TO ALL;

-- 创建单个用户并发限制
CREATE QUOTA IF NOT EXISTS user_concurrency_quota
WITH LIMITS
    MAX_CONCURRENT_QUERIES = 10
KEYED BY USER_NAME
TO ALL;
```

### 示例 3：按时间段的资源分配

```sql
-- 工作时间段：留给生产查询
CREATE WORKLOAD GROUP IF NOT EXISTS business_hours_group
SETTINGS
    max_concurrent_queries = 20,
    max_memory_usage = 60000000000,     -- 60 GB
    priority = 3,
    scheduling_policy = 'round_robin';

-- 非工作时间段：允许批量 ETL
CREATE WORKLOAD GROUP IF NOT EXISTS off_hours_group
SETTINGS
    max_concurrent_queries = 30,
    max_memory_usage = 80000000000,     -- 80 GB
    priority = 5,
    scheduling_policy = 'round_robin';

-- 通过角色切换实现时间段控制
CREATE ROLE IF NOT EXISTS business_hours_role
SETTINGS workload_group = 'business_hours_group';

CREATE ROLE IF NOT EXISTS off_hours_role
SETTINGS workload_group = 'off_hours_group';

-- 用户可以在不同时间段切换角色
CREATE USER IF NOT EXISTS analyst
IDENTIFIED WITH sha256_password BY 'Analyst123!'
DEFAULT ROLE business_hours_role;
-- 非工作时间：SET ROLE off_hours_role;
```

### 示例 4：Quota 与 Workload Management 组合使用

```sql
-- 1. 创建 Workload Group（调度层）
CREATE WORKLOAD GROUP IF NOT EXISTS etl_workload
SETTINGS
    max_concurrent_queries = 5,
    max_memory_usage = 20000000000,     -- 20 GB
    priority = 10,
    scheduling_policy = 'fifo';

-- 2. 创建角色并绑定 Workload Group
CREATE ROLE IF NOT EXISTS etl_processor_role
SETTINGS workload_group = 'etl_workload';

-- 3. 创建 Quota（限制层）
CREATE QUOTA IF NOT EXISTS etl_daily_quota
WITH LIMITS
    QUERY_TIME = 21600 PER DAY,          -- 6 小时
    READ_BYTES = 107374182400 PER DAY,   -- 100 GB
    WRITTEN_BYTES = 53687091200 PER DAY  -- 50 GB
KEYED BY USER_NAME
TO etl_processor_role;

-- 4. 创建用户并分配角色
CREATE USER IF NOT EXISTS etl_user
IDENTIFIED WITH sha256_password BY 'ETLUser123!'
DEFAULT ROLE etl_processor_role;

-- 5. 验证配置
-- SELECT name, priority, max_concurrent_queries, max_memory_usage 
-- FROM system.workload_groups 
-- WHERE name = 'etl_workload';
-- 
-- SELECT quota_name, user_name, queries, query_time, read_bytes 
-- FROM system.quota_usage 
-- WHERE user_name = 'etl_user';
```

### 示例 5：多租户资源隔离

```sql
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
```

## 常见误区与最佳实践

### 常见误区

| 误区 | 纠正 |
|------|------|
| **Quota 和 Workload Management 是一个东西** | Quota 是限制层（限制使用量），Workload Management 是调度层（分配资源），两者互补 |
| **设置 `max_memory_usage` 就能防止 OOM** | `max_memory_usage` 只限制单个查询，多查询并发仍可能 OOM，需结合 Workload Group 的 `max_memory_usage` |
| **并发限制等于 CPU 限制** | 并发限制是查询级别，一个查询可能使用多个 CPU 核心，还需考虑 `max_threads` |
| **Workload Group 的优先级是抢占式的** | ClickHouse 的优先级是调度优先，不是抢占式。低优先级查询正在执行时，不会因高优先级查询到达而被中断 |
| **Quota 限制对所有查询立即生效** | Quota 的检查在查询开始前，已开始的查询不受影响 |
| **Quota 和 Workload 配置重启后丢失** | 通过 SQL 创建的 Quota 和 Workload Group 持久化存储在 `access_control_path`，重启不会丢失 |

### 最佳实践

1. **先 Workload 分组，再 Quota 限制**：先通过 Workload Group 划分不同优先级的工作负载，再为每个组设置 Quota
2. **设置合理的超时时间**：`max_execution_time` 是最基础的防护，所有用户都应设置
3. **内存限制要留有缓冲区**：Workload Group 的 `max_memory_usage` 总和不应超过物理内存的 80%
4. **使用 `max_bytes_before_external_group_by`**：对大查询启用外部聚合，避免内存溢出
5. **监控超限事件**：定期检查 `query_log` 中的 `QUOTA_EXCEEDED` 和 `MEMORY_LIMIT_EXCEEDED`
6. **为关键查询预留资源**：关键业务的 Workload Group 优先级设为 1，并预留足够的内存
7. **Quota Key 使用 USER_NAME**：在多用户场景中，按用户而不是按 IP 计算配额更准确
8. **定期审查 Quota 使用率**：查看 `system.quota_usage` 了解哪些用户即将达到配额上限
9. **测试环境验证**：在测试环境模拟生产负载，验证 Quota 和 Workload 配置的有效性
10. **结合外部监控系统**：Workload Group 的状态可以通过 Prometheus 导出，集成到 Grafana 仪表盘

### 配置检查清单

- [ ] 所有用户都设置了 `max_execution_time`
- [ ] 所有用户都设置了 `max_memory_usage`
- [ ] 关键业务 Workload Group 优先级设为 1-3
- [ ] 非关键业务 Workload Group 设置了 `max_queued_queries` 和 `max_queued_waiting_ms`
- [ ] Quota 设置了合理的时间窗口（不建议使用 `PER INTERVAL 0` 表示不限制）
- [ ] 监控系统配置了 Quota 超限告警
- [ ] Workload Group 的 `max_memory_usage` 总和不超过物理内存
- [ ] 定期检查 `system.quota_usage` 和 `system.workload_group_stats`

## 相关文档

- [用户认证](./01_authentication.md)
- [用户和角色管理](./02_user_role_management.md)
- [权限控制](./03_permissions.md)
- [多租户隔离](./11_multi_tenancy.md)
- [审计日志](./07_audit_log.md)
- [ClickHouse Quota 官方文档](https://clickhouse.com/docs/en/operations/access-rights#quotas)
- [ClickHouse Workload Management 官方文档](https://clickhouse.com/docs/en/operations/workload-management)