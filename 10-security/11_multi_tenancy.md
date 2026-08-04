# 多租户隔离

多租户（Multi-Tenancy）是 SaaS 场景下的核心需求——多个客户（租户）共享同一套 ClickHouse 集群，但彼此的数据和资源完全隔离。本章深入剖析 ClickHouse 中实现多租户隔离的多种策略及其底层原理。

## 目录

- [多租户隔离概述](#多租户隔离概述)
- [隔离策略对比](#隔离策略对比)
- [策略一：数据库级隔离](#策略一数据库级隔离)
- [策略二：表级隔离（Schema-per-Tenant）](#策略二表级隔离schema-per-tenant)
- [策略三：行级隔离（RLS）](#策略三行级隔离rls)
- [策略四：混合隔离策略](#策略四混合隔离策略)
- [资源隔离](#资源隔离)
- [租户监控与计量](#租户监控与计量)
- [跨租户数据共享](#跨租户数据共享)
- [实战示例](#实战示例)
- [常见误区与最佳实践](#常见误区与最佳实践)

## 多租户隔离概述

### 多租户的挑战

| 挑战 | 描述 | 影响 |
|------|------|------|
| **数据隔离** | 租户 A 能看到租户 B 的数据 | 严重的数据泄露事故 |
| **资源争抢** | 一个租户的查询占满所有 CPU | 其他租户查询变慢或超时 |
| **性能噪音** | 大租户的查询干扰小租户的性能 | SLA 无法保障 |
| **运维复杂度** | 需要为每个租户单独管理 | 运维成本线性增长 |
| **成本分摊** | 无法准确计算每个租户的资源消耗 | 账单不透明 |

### 隔离级别与安全等级

```
数据隔离强度
     ▲
     │  数据库级隔离       ★★★★★（最强）
     │  (Database-per-Tenant)
     │
     │  表级隔离           ★★★★
     │  (Schema-per-Tenant)
     │
     │  行级隔离(RLS)      ★★★
     │  (Row-Level Security)
     │
     │  应用层隔离         ★★（最弱）
     │  (WHERE tenant_id = ?)
     └──────────────────────────→ 管理复杂度
         低 ←──────────────→ 高
```

## 隔离策略对比

| 策略 | 隔离级别 | 数据隔离 | 性能隔离 | 管理复杂度 | 适用场景 |
|------|---------|---------|---------|-----------|---------|
| **数据库级** | 最高 | 物理隔离 | 强（独立表） | 低 | 租户数据差异大、合规要求高 |
| **表级** | 高 | 逻辑隔离 | 中（共享数据库） | 中 | 租户数据结构相似 |
| **行级（RLS）** | 中 | 查询级隔离 | 弱（共享表） | 高 | 小型租户、数据量小 |
| **混合策略** | 可定制 | 分层隔离 | 可定制 | 最高 | 大型租户专属库 + 小租户共享表 |

### 选择决策树

```
租户数量？
├── < 50 且数据量大 → 数据库级隔离
├── 50-500 → 表级隔离
├── > 500 且数据量小 → 行级隔离
└── 混合 → 大租户专属库 + 小租户共享表

数据合规要求？
├── 金融/医疗 → 数据库级 + 加密
└── 一般业务 → 表级或行级

租户间数据差异？
├── 大（不同 schema） → 数据库级
└── 小（相同 schema） → 行级或表级
```

## 策略一：数据库级隔离

### 原理

每个租户拥有独立的数据库，数据存储在各自的表中。这是最强的隔离方式，相当于"物理隔离"。

**优点**：
- 完全的数据隔离，一个租户无法访问其他租户的数据
- 可以为每个租户设置独立的表结构、索引、TTL
- 备份恢复可以按租户独立操作
- 删除租户只需 `DROP DATABASE`

**缺点**：
- 管理复杂度随租户数线性增长
- 无法直接跨租户查询（需要 UNION ALL 多个数据库）
- 元数据膨胀（大量相似的表结构）

### 实现方式

```sql
-- 为每个租户创建独立的数据库
CREATE DATABASE IF NOT EXISTS tenant_001
ON CLUSTER 'treasurycluster';

CREATE DATABASE IF NOT EXISTS tenant_002
ON CLUSTER 'treasurycluster';

-- 在每个租户数据库中创建表结构
CREATE TABLE IF NOT EXISTS tenant_001.orders
ON CLUSTER 'treasurycluster'
(
    order_id UInt64,
    product_id String,
    amount Decimal(18, 2),
    status String,
    created_at DateTime
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/tenant_001_orders', '{replica}')
PARTITION BY toYYYYMM(created_at)
ORDER BY (order_id, created_at);

-- 创建租户专用用户
CREATE USER IF NOT EXISTS tenant_001_user
IDENTIFIED WITH sha256_password BY 'Tenant001Pass123!'
SETTINGS tenant_id = '001';

-- 授予租户数据库权限
GRANT ALL ON tenant_001.* TO tenant_001_user;
```

### 自动化管理脚本

```bash
#!/bin/bash
# 创建新租户的自动化脚本
TENANT_ID=$1
TENANT_PASSWORD=$2

# 创建数据库
clickhouse-client --query "CREATE DATABASE IF NOT EXISTS tenant_${TENANT_ID} ON CLUSTER 'treasurycluster'"

# 创建表结构
clickhouse-client --query "
CREATE TABLE IF NOT EXISTS tenant_${TENANT_ID}.orders ON CLUSTER 'treasurycluster'
(
    order_id UInt64,
    product_id String,
    amount Decimal(18, 2),
    status String,
    created_at DateTime
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/tenant_${TENANT_ID}_orders', '{replica}')
PARTITION BY toYYYYMM(created_at)
ORDER BY (order_id, created_at)
"

# 创建用户
clickhouse-client --query "
CREATE USER IF NOT EXISTS tenant_${TENANT_ID}_user
IDENTIFIED WITH sha256_password BY '${TENANT_PASSWORD}'
SETTINGS tenant_id = '${TENANT_ID}'
"

# 授予权限
clickhouse-client --query "GRANT ALL ON tenant_${TENANT_ID}.* TO tenant_${TENANT_ID}_user"

echo "Tenant ${TENANT_ID} created successfully"
```

## 策略二：表级隔离（Schema-per-Tenant）

### 原理

所有租户共享同一个数据库，但每个租户使用独立的表。表名通常包含租户标识。

**优点**：
- 管理相对简单，所有租户在同一个数据库中
- 可以按租户独立设置表参数
- 备份恢复可以按表粒度操作

**缺点**：
- 表数量随着租户数增长而膨胀
- 跨租户查询需要 UNION ALL 多个表
- 无法直接使用通配符查询所有租户

### 实现方式

```sql
-- 创建共享数据库
CREATE DATABASE IF NOT EXISTS multi_tenant
ON CLUSTER 'treasurycluster';

-- 为每个租户创建独立的表
CREATE TABLE IF NOT EXISTS multi_tenant.orders_tenant001
ON CLUSTER 'treasurycluster'
(
    order_id UInt64,
    product_id String,
    amount Decimal(18, 2),
    status String,
    created_at DateTime
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/orders_tenant001', '{replica}')
PARTITION BY toYYYYMM(created_at)
ORDER BY (order_id, created_at);

CREATE TABLE IF NOT EXISTS multi_tenant.orders_tenant002
ON CLUSTER 'treasurycluster'
(
    order_id UInt64,
    product_id String,
    amount Decimal(18, 2),
    status String,
    created_at DateTime
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/orders_tenant002', '{replica}')
PARTITION BY toYYYYMM(created_at)
ORDER BY (order_id, created_at);

-- 创建租户用户
CREATE USER IF NOT EXISTS tenant001
IDENTIFIED WITH sha256_password BY 'Tenant001Pass123!';

-- 授予租户表权限
GRANT ALL ON multi_tenant.orders_tenant001 TO tenant001;
```

### 跨租户查询

```sql
-- 查询所有租户的数据（需要明确列出所有表）
SELECT 
    'tenant001' as tenant_id,
    order_id,
    amount,
    status,
    created_at
FROM multi_tenant.orders_tenant001
UNION ALL
SELECT 
    'tenant002' as tenant_id,
    order_id,
    amount,
    status,
    created_at
FROM multi_tenant.orders_tenant002
WHERE created_at >= today() - INTERVAL 7 DAY
ORDER BY created_at DESC;
```

## 策略三：行级隔离（RLS）

### 原理

所有租户共享同一张表，通过行级安全策略（Row Policy）在查询时自动过滤数据。租户标识通过 `tenant_id` 列区分。

**优点**：
- 管理最简单，只需维护一张表
- 跨租户查询方便（添加 `tenant_id` 过滤条件即可）
- 表结构统一，schema 变更一次完成

**缺点**：
- 数据隔离依赖行策略配置，出问题可能导致数据泄露
- 所有租户数据在同一个 Part 中，无法独立管理
- 删除租户数据需要执行 `ALTER TABLE ... DELETE`
- 性能受行策略过滤条件影响

### 实现方式

```sql
-- 创建共享表
CREATE TABLE IF NOT EXISTS multi_tenant.orders
ON CLUSTER 'treasurycluster'
(
    order_id UInt64,
    tenant_id String,
    user_id String,
    product_id String,
    amount Decimal(18, 2),
    status String,
    created_at DateTime
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/orders', '{replica}')
PARTITION BY (tenant_id, toYYYYMM(created_at))
ORDER BY (tenant_id, created_at, order_id);

-- 创建租户用户
CREATE USER IF NOT EXISTS tenant1
IDENTIFIED WITH sha256_password BY 'Tenant1Password123!'
SETTINGS tenant_id = 'tenant1';

CREATE USER IF NOT EXISTS tenant2
IDENTIFIED WITH sha256_password BY 'Tenant2Password123!'
SETTINGS tenant_id = 'tenant2';

-- 创建租户角色
CREATE ROLE IF NOT EXISTS tenant_role;
GRANT SELECT, INSERT ON multi_tenant.* TO tenant_role;

GRANT tenant_role TO tenant1;
GRANT tenant_role TO tenant2;

-- 创建行级安全策略（核心隔离机制）
CREATE ROW POLICY IF NOT EXISTS tenant_filter
ON multi_tenant.orders
USING tenant_id = current_user_settings['tenant_id']
AS RESTRICTIVE TO tenant1, tenant2;

-- 验证：tenant1 查询时自动加上 WHERE tenant_id = 'tenant1'
-- tenant1: SELECT * FROM multi_tenant.orders;  → 只返回 tenant1 的数据
```

### RLS 的底层原理

当 ClickHouse 执行查询时，行策略的过滤条件会被注入到查询计划中：

```
用户查询：SELECT * FROM multi_tenant.orders
                        ↓
    ClickHouse 解析器注入行策略条件
                        ↓
实际执行：SELECT * FROM multi_tenant.orders 
          WHERE tenant_id = current_user_settings('tenant_id')
                        ↓
         存储引擎扫描 → 过滤不匹配的行 → 返回结果
```

**关键点**：
- 行策略在服务器端执行，客户端无法绕过
- 行策略对管理员默认不生效（拥有 `ACCESS_MANAGEMENT` 权限的用户）
- 行策略的过滤条件会参与索引选择，如果 `tenant_id` 是排序键，性能几乎无损耗

## 策略四：混合隔离策略

### 原理

根据租户的规模和数据敏感度，采用不同的隔离策略组合。大租户使用数据库级隔离，中小租户使用行级隔离，实现最佳的隔离效果和资源利用率。

### 实现方式

```sql
-- 1. 大租户：专属数据库
CREATE DATABASE IF NOT EXISTS enterprise_tenant_a
ON CLUSTER 'treasurycluster';

-- 大租户专属表
CREATE TABLE IF NOT EXISTS enterprise_tenant_a.orders
ON CLUSTER 'treasurycluster'
(
    order_id UInt64,
    product_id String,
    amount Decimal(18, 2),
    status String,
    created_at DateTime
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/ent_a_orders', '{replica}')
PARTITION BY toYYYYMM(created_at)
ORDER BY (order_id, created_at);

-- 大租户用户
CREATE USER IF NOT EXISTS ent_a_user
IDENTIFIED WITH sha256_password BY 'EntAPass123!'
SETTINGS tenant_id = 'ent_a';
GRANT ALL ON enterprise_tenant_a.* TO ent_a_user;

-- 2. 中小租户：共享表 + RLS
CREATE TABLE IF NOT EXISTS shared_tenant.orders
ON CLUSTER 'treasurycluster'
(
    order_id UInt64,
    tenant_id String,
    user_id String,
    amount Decimal(18, 2),
    status String,
    created_at DateTime
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/shared_orders', '{replica}')
PARTITION BY (tenant_id, toYYYYMM(created_at))
ORDER BY (tenant_id, created_at);

-- 中小租户用户
CREATE USER IF NOT EXISTS smb_tenant_1
IDENTIFIED WITH sha256_password BY 'SMB1Pass123!'
SETTINGS tenant_id = 'smb_tenant_1';

CREATE USER IF NOT EXISTS smb_tenant_2
IDENTIFIED WITH sha256_password BY 'SMB2Pass123!'
SETTINGS tenant_id = 'smb_tenant_2';

-- 共享表角色
CREATE ROLE IF NOT EXISTS shared_tenant_role;
GRANT SELECT, INSERT ON shared_tenant.* TO shared_tenant_role;
GRANT shared_tenant_role TO smb_tenant_1, smb_tenant_2;

-- 行级安全策略
CREATE ROW POLICY IF NOT EXISTS shared_tenant_filter
ON shared_tenant.orders
USING tenant_id = current_user_settings['tenant_id']
AS RESTRICTIVE TO smb_tenant_1, smb_tenant_2;
```

## 资源隔离

### 按租户分配 Workload Group

```sql
-- 大租户：高优先级，大资源
CREATE WORKLOAD GROUP IF NOT EXISTS tenant_enterprise_group
SETTINGS
    max_concurrent_queries = 20,
    max_memory_usage = 50000000000,     -- 50 GB
    priority = 1,
    scheduling_policy = 'round_robin';

-- 中小租户：中优先级，中等资源
CREATE WORKLOAD GROUP IF NOT EXISTS tenant_smb_group
SETTINGS
    max_concurrent_queries = 10,
    max_memory_usage = 20000000000,     -- 20 GB
    priority = 5,
    scheduling_policy = 'round_robin';
```

### 按租户设置 Quota

```sql
-- 大租户 Quota：每天 4 小时
CREATE QUOTA IF NOT EXISTS enterprise_tenant_quota
WITH LIMITS
    QUERY_TIME = 14400 PER DAY,          -- 4 小时
    READ_BYTES = 107374182400 PER DAY    -- 100 GB
KEYED BY USER_NAME
TO ent_a_user;

-- 中小租户 Quota：每天 30 分钟
CREATE QUOTA IF NOT EXISTS smb_tenant_quota
WITH LIMITS
    QUERY_TIME = 1800 PER DAY,           -- 30 分钟
    READ_BYTES = 10737418240 PER DAY     -- 10 GB
KEYED BY USER_NAME
TO shared_tenant_role;
```

### 按租户分片

对于超大租户，可以在集群级别实现租户分片：

```sql
-- 为租户 A 创建专用的分布式表
-- 使用租户 A 的分片配置
CREATE TABLE IF NOT EXISTS enterprise_tenant_a.orders_dist
ON CLUSTER 'treasurycluster'
AS enterprise_tenant_a.orders
ENGINE = Distributed(
    'treasurycluster',
    'enterprise_tenant_a',
    'orders',
    cityHash64(order_id)
);
```

## 租户监控与计量

### 按租户统计资源消耗

```sql
-- 按租户（用户）统计查询量
SELECT 
    user,
    count() as query_count,
    sum(query_duration_ms) / 1000 as total_duration_sec,
    avg(query_duration_ms) as avg_duration_ms,
    sum(read_rows) as total_read_rows,
    formatReadableSize(sum(read_bytes)) as total_read_bytes,
    formatReadableSize(sum(memory_usage)) as total_memory
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_time >= now() - INTERVAL 1 DAY
GROUP BY user
ORDER BY total_duration_sec DESC;

-- 按租户统计写入量
SELECT 
    user,
    count() as write_count,
    sum(written_rows) as total_written_rows,
    formatReadableSize(sum(written_bytes)) as total_written_bytes
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query LIKE 'INSERT%'
  AND event_time >= now() - INTERVAL 1 DAY
GROUP BY user
ORDER BY total_written_bytes DESC;

-- 按租户统计存储使用量
SELECT 
    database,
    table,
    sum(bytes_on_disk) as total_bytes,
    formatReadableSize(sum(bytes_on_disk)) as total_bytes_str,
    sum(rows) as total_rows,
    count() as part_count
FROM system.parts
WHERE active = 1
  AND database LIKE 'tenant_%'
GROUP BY database, table
ORDER BY total_bytes DESC;

-- 按租户统计错误率
SELECT 
    user,
    count() as total_queries,
    countIf(type = 'Exception') as error_count,
    round(error_count / count() * 100, 2) as error_rate_pct
FROM system.query_log
WHERE event_time >= now() - INTERVAL 1 DAY
GROUP BY user
ORDER BY error_rate_pct DESC;
```

### 租户使用报表

```sql
-- 生成租户使用日报
SELECT 
    toDate(event_time) as day,
    user as tenant_id,
    count() as query_count,
    sum(query_duration_ms) / 1000 as total_cpu_seconds,
    sum(read_rows) as total_read_rows,
    formatReadableSize(sum(read_bytes)) as total_read_data,
    sum(written_rows) as total_written_rows,
    formatReadableSize(sum(written_bytes)) as total_written_data
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date = today() - 1
GROUP BY day, tenant_id
ORDER BY total_cpu_seconds DESC;
```

## 跨租户数据共享

### 场景：管理后台需要查看所有租户数据

```sql
-- 方案一：创建管理视图
CREATE VIEW IF NOT EXISTS multi_tenant.admin_orders AS
SELECT 
    'tenant001' as tenant_id,
    order_id,
    amount,
    status,
    created_at
FROM multi_tenant.orders_tenant001
UNION ALL
SELECT 
    'tenant002' as tenant_id,
    order_id,
    amount,
    status,
    created_at
FROM multi_tenant.orders_tenant002;

-- 方案二（RLS 场景）：创建管理员角色绕过行策略
CREATE ROLE IF NOT EXISTS admin_role;
GRANT ALL ON multi_tenant.* TO admin_role;
-- 注意：管理员不受行策略限制

-- 方案三：创建物化视图定期汇总各租户数据
CREATE MATERIALIZED VIEW IF NOT EXISTS multi_tenant.daily_tenant_stats
ENGINE = ReplicatedSummingMergeTree()
PARTITION BY toYYYYMM(stat_date)
ORDER BY (tenant_id, stat_date)
AS SELECT
    tenant_id,
    toDate(created_at) as stat_date,
    count() as order_count,
    sum(amount) as total_amount,
    countIf(status = 'completed') as completed_count
FROM multi_tenant.orders
GROUP BY tenant_id, stat_date;
```

### 场景：租户间数据共享（如公共字典）

```sql
-- 创建共享字典
CREATE DICTIONARY IF NOT EXISTS shared.product_catalog
(
    product_id String,
    product_name String,
    category String,
    price Decimal(18, 2)
)
PRIMARY KEY product_id
SOURCE(CLICKHOUSE(
    HOST 'clickhouse1'
    PORT 9000
    USER 'shared_user'
    PASSWORD 'SharedPass123!'
    DATABASE 'shared'
    TABLE 'products'
))
LIFETIME(MIN 1 MAX 3600)
LAYOUT(HASHED());

-- 授予所有租户对字典的只读权限
CREATE ROLE IF NOT EXISTS shared_dict_reader;
GRANT SELECT ON DICTIONARY shared.product_catalog TO shared_dict_reader;

-- 将字典角色分配给所有租户角色
GRANT shared_dict_reader TO tenant_role;
```

## 实战示例

### 示例 1：完整的数据库级多租户

```sql
-- 1. 创建租户数据库
CREATE DATABASE IF NOT EXISTS tenant_acme_corp ON CLUSTER 'treasurycluster';
CREATE DATABASE IF NOT EXISTS tenant_globex_inc ON CLUSTER 'treasurycluster';

-- 2. 创建租户表
CREATE TABLE IF NOT EXISTS tenant_acme_corp.orders
ON CLUSTER 'treasurycluster'
(
    order_id UInt64,
    customer_id String,
    amount Decimal(18, 2),
    status String,
    created_at DateTime
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/acme_orders', '{replica}')
PARTITION BY toYYYYMM(created_at)
ORDER BY (order_id, created_at);

CREATE TABLE IF NOT EXISTS tenant_globex_inc.orders
ON CLUSTER 'treasurycluster'
(
    order_id UInt64,
    customer_id String,
    amount Decimal(18, 2),
    status String,
    created_at DateTime
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/globex_orders', '{replica}')
PARTITION BY toYYYYMM(created_at)
ORDER BY (order_id, created_at);

-- 3. 创建租户用户和角色
CREATE USER IF NOT EXISTS acme_user
IDENTIFIED WITH sha256_password BY 'AcmePass123!';
CREATE ROLE IF NOT EXISTS acme_role;
GRANT ALL ON tenant_acme_corp.* TO acme_role;
GRANT acme_role TO acme_user;

CREATE USER IF NOT EXISTS globex_user
IDENTIFIED WITH sha256_password BY 'GlobexPass123!';
CREATE ROLE IF NOT EXISTS globex_role;
GRANT ALL ON tenant_globex_inc.* TO globex_role;
GRANT globex_role TO globex_user;

-- 4. 配置资源隔离
CREATE WORKLOAD GROUP IF NOT EXISTS acme_group
SETTINGS
    max_concurrent_queries = 10,
    max_memory_usage = 30000000000,     -- 30 GB
    priority = 3,
    scheduling_policy = 'round_robin';

ALTER USER acme_user SETTINGS workload_group = 'acme_group';

CREATE WORKLOAD GROUP IF NOT EXISTS globex_group
SETTINGS
    max_concurrent_queries = 5,
    max_memory_usage = 15000000000,     -- 15 GB
    priority = 5,
    scheduling_policy = 'round_robin';

ALTER USER globex_user SETTINGS workload_group = 'globex_group';

-- 5. 创建 Quota
CREATE QUOTA IF NOT EXISTS acme_quota
WITH LIMITS
    QUERY_TIME = 7200 PER DAY,           -- 2 小时
    READ_BYTES = 53687091200 PER DAY     -- 50 GB
KEYED BY USER_NAME
TO acme_user;

CREATE QUOTA IF NOT EXISTS globex_quota
WITH LIMITS
    QUERY_TIME = 3600 PER DAY,           -- 1 小时
    READ_BYTES = 10737418240 PER DAY     -- 10 GB
KEYED BY USER_NAME
TO globex_user;
```

### 示例 2：完整的行级多租户

```sql
-- 1. 创建租户表
CREATE TABLE IF NOT EXISTS saas.orders
ON CLUSTER 'treasurycluster'
(
    order_id UInt64,
    tenant_id String,
    user_id String,
    amount Decimal(18, 2),
    product_category String,
    status String,
    created_at DateTime
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/saas_orders', '{replica}')
PARTITION BY (tenant_id, toYYYYMM(created_at))
ORDER BY (tenant_id, created_at, order_id);

-- 2. 创建租户角色
CREATE ROLE IF NOT EXISTS saas_tenant_role;
GRANT SELECT, INSERT ON saas.orders TO saas_tenant_role;

-- 3. 创建租户用户
CREATE USER IF NOT EXISTS tenant_a
IDENTIFIED WITH sha256_password BY 'TenantAPass123!'
SETTINGS tenant_id = 'tenant_a';
GRANT saas_tenant_role TO tenant_a;

CREATE USER IF NOT EXISTS tenant_b
IDENTIFIED WITH sha256_password BY 'TenantBPass123!'
SETTINGS tenant_id = 'tenant_b';
GRANT saas_tenant_role TO tenant_b;

-- 4. 创建行级安全策略
CREATE ROW POLICY IF NOT EXISTS saas_tenant_filter
ON saas.orders
USING tenant_id = current_user_settings['tenant_id']
AS RESTRICTIVE TO tenant_a, tenant_b;

-- 5. 配置资源隔离
CREATE WORKLOAD GROUP IF NOT EXISTS saas_tenant_group
SETTINGS
    max_concurrent_queries = 10,
    max_memory_usage = 20000000000,     -- 20 GB
    priority = 5,
    scheduling_policy = 'round_robin';

ALTER ROLE saas_tenant_role SETTINGS workload_group = 'saas_tenant_group';

-- 6. 创建 Quota
CREATE QUOTA IF NOT EXISTS saas_tenant_quota
WITH LIMITS
    QUERY_TIME = 3600 PER DAY,           -- 1 小时
    READ_BYTES = 10737418240 PER DAY     -- 10 GB
KEYED BY USER_NAME
TO saas_tenant_role;
```

### 示例 3：租户数据清理

```sql
-- 数据库级：直接删除数据库
-- DROP DATABASE IF EXISTS tenant_acme_corp;

-- 表级：删除租户表
-- DROP TABLE IF EXISTS multi_tenant.orders_tenant001;

-- 行级：执行 Mutation 删除
-- ALTER TABLE saas.orders DELETE WHERE tenant_id = 'tenant_a';

-- 行级：使用分区删除（如果 tenant_id 是分区键）
-- ALTER TABLE saas.orders DROP PARTITION WHERE tenant_id = 'tenant_a';
-- 注意：ClickHouse 不支持直接按条件 DROP PARTITION，
-- 需要先查出分区名再删除
SELECT 
    partition_id,
    name as part_name,
    rows
FROM system.parts
WHERE database = 'saas'
  AND table = 'orders'
  AND active = 1
  AND partition_id LIKE '%tenant_a%'
ORDER BY part_name;
```

### 示例 4：租户数据迁移

```sql
-- 场景：将中小租户从行级隔离升级为数据库级隔离

-- 1. 创建新数据库
CREATE DATABASE IF NOT EXISTS tenant_upgraded;

-- 2. 创建新表
CREATE TABLE IF NOT EXISTS tenant_upgraded.orders
(
    order_id UInt64,
    tenant_id String,
    user_id String,
    amount Decimal(18, 2),
    status String,
    created_at DateTime
)
ENGINE = MergeTree()
PARTITION BY toYYYYMM(created_at)
ORDER BY (order_id, created_at);

-- 3. 迁移数据
INSERT INTO tenant_upgraded.orders
SELECT * FROM saas.orders
WHERE tenant_id = 'tenant_a';

-- 4. 验证数据
SELECT count() FROM tenant_upgraded.orders;
SELECT count() FROM saas.orders WHERE tenant_id = 'tenant_a';

-- 5. 更新用户权限
REVOKE ALL ON saas.orders FROM tenant_a;
GRANT ALL ON tenant_upgraded.* TO tenant_a;
```

## 常见误区与最佳实践

### 常见误区

| 误区 | 纠正 |
|------|------|
| **行级安全策略（RLS）能完全替代数据库级隔离** | RLS 在查询层面过滤，但不阻止管理员查看所有数据。对于高合规要求场景，必须使用数据库级隔离 |
| **行策略不会影响性能** | 如果 `tenant_id` 不是排序键，行策略的过滤条件会导致全表扫描 |
| **所有租户共享同一个 Workload Group** | 不同规模的租户需要不同的 Workload Group，否则大租户会抢占小租户资源 |
| **多租户只在查询时做隔离就够了** | 数据隔离、资源隔离、运维隔离三者缺一不可 |
| **租户越多，成本越低** | 共享资源可以降低成本，但行级隔离的维护复杂度和性能风险会随租户数增长 |
| **RLS 策略绑定到用户就行** | 应该通过角色管理 RLS，而不是直接绑定到用户，这样便于批量管理 |

### 最佳实践

1. **先评估再选型**：根据租户数量、数据量、合规要求选择隔离策略
2. **大租户专用库，小租户共享表**：混合策略是最经济高效的选择
3. **`tenant_id` 必须作为排序键**：无论是数据库级还是行级，`tenant_id` 都应该是 ORDER BY 的第一个字段
4. **使用角色管理租户权限**：通过角色（而非直接绑定）管理租户的权限和 RLS
5. **设置 Workload Group 和 Quota**：防止一个租户影响其他租户
6. **监控租户资源使用**：按租户/用户统计资源消耗，用于成本分摊
7. **自动化租户管理**：使用脚本自动化租户创建、迁移、删除
8. **定期审计租户数据隔离**：模拟不同租户的访问，验证隔离是否有效
9. **备份恢复按租户**：数据库级隔离可以按租户独立备份，行级隔离需要全表备份
10. **文档化租户架构**：记录每个租户采用的隔离策略和资源配置

### 配置检查清单

- [ ] 根据租户规模和合规要求选择隔离策略
- [ ] `tenant_id` 作为排序键的第一个字段
- [ ] 行级隔离场景下行策略已正确配置
- [ ] 每个租户有独立的 Workload Group（或按等级分组）
- [ ] 每个租户/角色设置了 Quota
- [ ] 管理员角色不受行策略限制（用于后台管理）
- [ ] 租户间数据共享已通过字典或视图实现
- [ ] 监控系统按租户维度统计资源消耗
- [ ] 租户创建/迁移/删除自动化脚本已就绪
- [ ] 定期进行租户隔离审计

## 相关文档

- [Quota 与 Workload Management](./10_quota_workload.md)
- [用户和角色管理](./02_user_role_management.md)
- [权限控制](./03_permissions.md)
- [行级安全](./04_row_level_security.md)
- [审计日志](./07_audit_log.md)
- [安全最佳实践](./08_best_practices.md)
- [ClickHouse 行级安全官方文档](https://clickhouse.com/docs/en/operations/access-rights#row-policy)