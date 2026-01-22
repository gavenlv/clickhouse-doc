# 行级安全

行级安全（Row-Level Security, RLS）允许在行级别控制数据访问，根据用户属性或其他条件限制哪些行可以被查询或修改。本节将详细介绍 ClickHouse 的行级安全功能。

## 📑 目录

- [行级安全概览](#行级安全概览)
- [创建行策略](#创建行策略)
- [行策略类型](#行策略类型)
- [基于用户属性的 RLS](#基于用户属性的-rls)
- [基于时间的 RLS](#基于时间的-rls)
- [动态 RLS](#动态-rls)
- [行策略监控](#行策略监控)
- [实战示例](#实战示例)

## 行级安全概览

### 行级安全优势

行级安全提供以下优势：

1. **数据隔离**：在同一表中实现不同用户的数据隔离
2. **简化查询**：无需在查询中手动添加过滤条件
3. **集中管理**：统一管理访问规则，易于维护
4. **安全性**：防止用户绕过应用层访问未授权数据
5. **透明性**：对用户完全透明，无需修改查询逻辑

### 行策略类型

| 类型 | 说明 | 适用场景 |
|------|------|---------|
| **Restrictive** | 限制性策略（AND 逻辑） | 严格限制访问 |
| **Permissive** | 许可性策略（OR 逻辑） | 允许更多访问 |
| **Mixed** | 混合策略 | 复杂访问控制 |

### 行策略应用范围

| 应用范围 | 说明 | 示例 |
|---------|------|------|
| **特定角色** | 只应用于指定角色 | `TO analyst_role` |
| **特定用户** | 只应用于指定用户 | `TO alice` |
| **所有用户** | 应用于所有用户（除管理员） | `TO ALL EXCEPT admin_role` |
| **所有管理员** | 应用于所有管理员 | `TO ALL ADMIN` |

## 创建行策略

### 基本行策略创建

```sql
-- 创建限制性行策略
CREATE ROW POLICY IF NOT EXISTS user_data_filter
ON analytics.user_events
USING user_id = current_user()
AS RESTRICTIVE TO readonly_user;

-- 创建许可性行策略
CREATE ROW POLICY IF NOT EXISTS recent_data_filter
ON analytics.events
USING event_time >= now() - INTERVAL 30 DAY
AS PERMISSIVE TO analyst_role;

-- 创建混合行策略
CREATE ROW POLICY IF NOT EXISTS department_filter
ON sales.orders
USING department = current_user_settings['department']
AS RESTRICTIVE TO analyst_role, manager_role;
```

### 行策略语法

```sql
CREATE [OR REPLACE] ROW POLICY [IF NOT EXISTS] name
ON [database.]table [AS PERMISSIVE | RESTRICTIVE]
[FOR SELECT | INSERT | UPDATE | DELETE]
[USING condition]
[WITH CHECK condition]
[TO role1, role2, ... | ALL EXCEPT role1, role2, ...]
```

### 行策略选项

| 选项 | 说明 | 默认值 |
|------|------|--------|
| `PERMISSIVE` | 许可性策略（OR） | - |
| `RESTRICTIVE` | 限制性策略（AND） | - |
| `USING` | 选择数据的条件 | - |
| `WITH CHECK` | 插入/更新数据的条件 | - |
| `TO` | 应用到的角色/用户 | - |

## 行策略类型

### 限制性策略（RESTRICTIVE）

限制性策略使用 AND 逻辑，必须满足所有条件才能访问数据。

```sql
-- 创建限制性策略
CREATE ROW POLICY IF NOT EXISTS strict_user_filter
ON analytics.user_data
USING user_id = current_user()
  AND status = 'active'
AS RESTRICTIVE TO readonly_user;

-- 查询：只会返回满足所有条件的行
SELECT * FROM analytics.user_data;
-- 等价于：
-- SELECT * FROM analytics.user_data 
-- WHERE user_id = current_user() AND status = 'active';
```

### 许可性策略（PERMISSIVE）

许可性策略使用 OR 逻辑，满足任意一个条件即可访问数据。

```sql
-- 创建许可性策略
CREATE ROW POLICY IF NOT EXISTS flexible_data_filter
ON analytics.events
USING 
    user_id = current_user()
    OR is_public = 1
    OR event_time >= now() - INTERVAL 7 DAY
AS PERMISSIVE TO analyst_role;

-- 查询：返回满足任意一个条件的行
SELECT * FROM analytics.events;
```

### 混合策略

可以同时使用限制性和许可性策略，实现复杂的访问控制。

```sql
-- 限制性策略 1
CREATE ROW POLICY IF NOT EXISTS user_filter
ON analytics.user_events
USING user_id = current_user()
AS RESTRICTIVE TO analyst_role;

-- 限制性策略 2
CREATE ROW POLICY IF NOT EXISTS status_filter
ON analytics.user_events
USING status IN ('active', 'pending')
AS RESTRICTIVE TO analyst_role;

-- 许可性策略
CREATE ROW POLICY IF NOT EXISTS admin_bypass
ON analytics.user_events
USING current_user() = 'admin'
AS PERMISSIVE TO admin_role;
```

## 基于用户属性的 RLS

### 基于 current_user() 的过滤

```sql
-- 创建表
CREATE TABLE IF NOT EXISTS analytics.user_events
ON CLUSTER 'treasurycluster'
(
    event_id UInt64,
    user_id String,
    event_type String,
    event_data String,
    event_time DateTime,
    created_at DateTime
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/user_events', '{replica}')
PARTITION BY toYYYYMM(event_time)
ORDER BY (user_id, event_time);

-- 创建行策略
CREATE ROW POLICY IF NOT EXISTS user_data_filter
ON analytics.user_events
USING user_id = current_user()
AS RESTRICTIVE TO readonly_user;

-- 创建用户
CREATE USER IF NOT EXISTS alice
IDENTIFIED WITH sha256_password BY 'Alice123!'
SETTINGS access_management = 0;

CREATE USER IF NOT EXISTS bob
IDENTIFIED WITH sha256_password BY 'Bob123!'
SETTINGS access_management = 0;

-- 测试：alice 只能看到自己的数据
-- SELECT * FROM analytics.user_events;  -- 只返回 user_id = 'alice' 的行
-- Bob 执行同样查询，只能看到 user_id = 'bob' 的行
```

### 基于用户设置的过滤

```sql
-- 创建带部门设置的用户
CREATE USER IF NOT EXISTS alice_sales
IDENTIFIED WITH sha256_password BY 'AliceSales123!'
SETTINGS department = 'sales';

CREATE USER IF NOT EXISTS bob_marketing
IDENTIFIED WITH sha256_password BY 'BobMarketing123!'
SETTINGS department = 'marketing';

-- 创建表
CREATE TABLE IF NOT EXISTS sales.orders
ON CLUSTER 'treasurycluster'
(
    order_id UInt64,
    user_id String,
    product_id String,
    amount Decimal(18, 2),
    department String,
    status String,
    order_date DateTime
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/orders', '{replica}')
PARTITION BY toYYYYMM(order_date)
ORDER BY (department, order_date);

-- 创建行策略
CREATE ROW POLICY IF NOT EXISTS department_filter
ON sales.orders
USING department = current_user_settings['department']
AS RESTRICTIVE TO alice_sales, bob_marketing;

-- 测试：alice_sales 只能看到 sales 部门的订单
-- SELECT * FROM sales.orders;  -- 只返回 department = 'sales' 的行
-- Bob 执行同样查询，只能看到 department = 'marketing' 的行
```

### 基于用户角色的过滤

```sql
-- 创建角色
CREATE ROLE IF NOT EXISTS sales_role;
CREATE ROLE IF NOT EXISTS marketing_role;

-- 创建行策略
CREATE ROW POLICY IF NOT EXISTS sales_data_filter
ON sales.orders
USING department = 'sales'
AS RESTRICTIVE TO sales_role;

CREATE ROW POLICY IF NOT EXISTS marketing_data_filter
ON sales.orders
USING department = 'marketing'
AS RESTRICTIVE TO marketing_role;

-- 创建用户并分配角色
CREATE USER IF NOT EXISTS alice
IDENTIFIED WITH sha256_password BY 'Alice123!'
DEFAULT ROLE sales_role;

CREATE USER IF NOT EXISTS bob
IDENTIFIED WITH sha256_password BY 'Bob123!'
DEFAULT ROLE marketing_role;
```

## 基于时间的 RLS

### 限制访问最近数据

```sql
-- 创建行策略：只允许访问最近 30 天的数据
CREATE ROW POLICY IF NOT EXISTS recent_data_filter
ON analytics.events
USING event_time >= now() - INTERVAL 30 DAY
AS RESTRICTIVE TO analyst_role;

-- 创建行策略：允许管理员访问所有数据
CREATE ROW POLICY IF NOT EXISTS admin_bypass_filter
ON analytics.events
USING 1=1
AS PERMISSIVE TO admin_role;
```

### 限制访问历史数据

```sql
-- 创建行策略：只允许访问历史数据（30 天前）
CREATE ROW POLICY IF NOT EXISTS historical_data_filter
ON analytics.events
USING event_time < now() - INTERVAL 30 DAY
AS RESTRICTIVE TO historian_role;

-- 创建行策略：允许访问当前日期之前的数据
CREATE ROW POLICY IF NOT EXISTS past_data_filter
ON analytics.events
USING event_time < today()
AS RESTRICTIVE TO readonly_user;
```

### 基于业务周期的过滤

```sql
-- 创建行策略：只允许访问当前季度
CREATE ROW POLICY IF NOT EXISTS current_quarter_filter
ON sales.orders
USING 
    toYear(order_date) = toYear(now())
    AND toQuarter(order_date) = toQuarter(now())
AS RESTRICTIVE TO current_quarter_analyst;

-- 创建行策略：只允许访问当前月
CREATE ROW POLICY IF NOT EXISTS current_month_filter
ON sales.orders
USING 
    toYearMonth(order_date) = toYearMonth(now())
AS RESTRICTIVE TO current_month_analyst;
```

## 动态 RLS

### 基于外部字典的动态过滤

```sql
-- 创建用户到部门的映射字典
CREATE DICTIONARY IF NOT EXISTS user_department_map
(
    user_id String,
    department String,
    access_level String
)
PRIMARY KEY user_id
SOURCE(FILE(
    path '/var/lib/clickhouse/user_files/user_department_map.tsv'
    format 'TabSeparated'
))
LIFETIME(MIN 1 MAX 3600)
LAYOUT(HASHED());

-- 创建行策略
CREATE ROW POLICY IF NOT EXISTS dynamic_department_filter
ON sales.orders
USING 
    department = dictGet('user_department_map', 'department', current_user())
    AND dictGet('user_department_map', 'access_level', current_user()) >= 'full'
AS RESTRICTIVE TO analyst_role;
```

### 基于查询参数的动态过滤

```sql
-- 创建行策略：基于用户设置的日期范围
CREATE ROW POLICY IF NOT EXISTS dynamic_date_filter
ON analytics.events
USING 
    event_time >= current_user_settings['min_date']
    AND event_time <= current_user_settings['max_date']
AS RESTRICTIVE TO analyst_role;

-- 为用户设置日期范围
CREATE USER IF NOT EXISTS analyst
IDENTIFIED WITH sha256_password BY 'Analyst123!'
SETTINGS 
    min_date = '2024-01-01',
    max_date = '2024-12-31';
```

### 基于标签的动态过滤

```sql
-- 创建行策略：基于标签过滤
CREATE ROW POLICY IF NOT EXISTS tag_filter
ON analytics.documents
USING 
    has(splitByChar(',', tags), current_user_settings['tag'])
    OR is_public = 1
AS PERMISSIVE TO analyst_role;

-- 为用户设置标签
CREATE USER IF NOT EXISTS alice
IDENTIFIED WITH sha256_password BY 'Alice123!'
SETTINGS tag = 'finance';

CREATE USER IF NOT EXISTS bob
IDENTIFIED WITH sha256_password BY 'Bob123!'
SETTINGS tag = 'marketing';
```

## 行策略监控

### 查看行策略

```sql
-- 查看所有行策略
SELECT 
    name,
    database,
    table,
    filter_expression,
    is_permissive,
    short_name
FROM system.row_policies
ORDER BY database, table, name;

-- 查看特定表的行策略
SELECT 
    name,
    filter_expression,
    is_permissive
FROM system.row_policies
WHERE database = 'analytics'
  AND table = 'user_events';

-- 查看应用于特定角色的行策略
SELECT 
    rp.name,
    rp.database,
    rp.table,
    rp.filter_expression,
    rp.is_permissive
FROM system.row_policies rp
JOIN system.grants g ON rp.name = g.access_type
WHERE g.role_name = 'analyst_role'
ORDER BY rp.database, rp.table;
```

### 测试行策略

```sql
-- 测试行策略效果
SELECT 
    user_id,
    count() as event_count
FROM analytics.user_events
GROUP BY user_id;

-- 使用不同用户测试
SET user = 'alice';
SELECT count() FROM analytics.user_events;

SET user = 'bob';
SELECT count() FROM analytics.user_events;

-- 查看查询执行计划（包含行策略）
EXPLAIN SELECT * FROM analytics.user_events;
```

## 实战示例

### 示例 1: 多租户数据隔离

```sql
-- 创建表
CREATE TABLE IF NOT EXISTS multi_tenant.orders
ON CLUSTER 'treasurycluster'
(
    order_id UInt64,
    tenant_id String,
    user_id String,
    amount Decimal(18, 2),
    status String,
    created_at DateTime
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/orders', '{replica}')
PARTITION BY toYYYYMM(created_at)
ORDER BY (tenant_id, created_at);

-- 创建租户用户
CREATE USER IF NOT EXISTS tenant1
IDENTIFIED WITH sha256_password BY 'Tenant1Password123!'
SETTINGS tenant_id = 'tenant1';

CREATE USER IF NOT EXISTS tenant2
IDENTIFIED WITH sha256_password BY 'Tenant2Password123!'
SETTINGS tenant_id = 'tenant2';

-- 创建行策略
CREATE ROW POLICY IF NOT EXISTS tenant_filter
ON multi_tenant.orders
USING tenant_id = current_user_settings['tenant_id']
AS RESTRICTIVE TO tenant1, tenant2;

-- 测试：每个租户只能看到自己的订单
-- tenant1: SELECT * FROM multi_tenant.orders;  -- 只返回 tenant_id = 'tenant1'
-- tenant2: SELECT * FROM multi_tenant.orders;  -- 只返回 tenant_id = 'tenant2'
```

### 示例 2: 基于权限级别的数据访问

```sql
-- 创建表
CREATE TABLE IF NOT EXISTS analytics.user_profiles
ON CLUSTER 'treasurycluster'
(
    user_id String,
    username String,
    email String,
    phone String,
    address String,
    credit_card String,
    ssn String,
    sensitivity_level Enum8('low' = 1, 'medium' = 2, 'high' = 3),
    created_at DateTime
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/user_profiles', '{replica}')
PARTITION BY toYYYYMM(created_at)
ORDER BY (user_id, created_at);

-- 创建角色
CREATE ROLE IF NOT EXISTS low_access_role;
CREATE ROLE IF NOT EXISTS medium_access_role;
CREATE ROLE IF NOT EXISTS high_access_role;

-- 创建行策略
-- 低权限用户：只能查看 low sensitivity 数据
CREATE ROW POLICY IF NOT EXISTS low_access_filter
ON analytics.user_profiles
USING sensitivity_level = 'low'
AS RESTRICTIVE TO low_access_role;

-- 中权限用户：可以查看 low 和 medium sensitivity 数据
CREATE ROW POLICY IF NOT EXISTS medium_access_filter
ON analytics.user_profiles
USING sensitivity_level IN ('low', 'medium')
AS RESTRICTIVE TO medium_access_role;

-- 高权限用户：可以查看所有数据
CREATE ROW POLICY IF NOT EXISTS high_access_filter
ON analytics.user_profiles
USING sensitivity_level IN ('low', 'medium', 'high')
AS RESTRICTIVE TO high_access_role;
```

### 示例 3: 地理区域数据隔离

```sql
-- 创建表
CREATE TABLE IF NOT EXISTS geo.sales
ON CLUSTER 'treasurycluster'
(
    sale_id UInt64,
    region String,
    country String,
    city String,
    amount Decimal(18, 2),
    sale_date DateTime
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/sales', '{replica}')
PARTITION BY toYYYYMM(sale_date)
ORDER BY (region, sale_date);

-- 创建区域用户
CREATE USER IF NOT EXISTS north_america_user
IDENTIFIED WITH sha256_password BY 'NorthAmerica123!'
SETTINGS region = 'North America';

CREATE USER IF NOT EXISTS europe_user
IDENTIFIED WITH sha256_password BY 'Europe123!'
SETTINGS region = 'Europe';

CREATE USER IF NOT EXISTS asia_user
IDENTIFIED WITH sha256_password BY 'Asia123!'
SETTINGS region = 'Asia';

-- 创建行策略
CREATE ROW POLICY IF NOT EXISTS region_filter
ON geo.sales
USING region = current_user_settings['region']
AS RESTRICTIVE TO north_america_user, europe_user, asia_user;

-- 测试：每个区域用户只能看到自己的销售数据
```

### 示例 4: 时间窗口访问控制

```sql
-- 创建表
CREATE TABLE IF NOT EXISTS analytics.time_series
ON CLUSTER 'treasurycluster'
(
    metric_id UInt64,
    metric_name String,
    value Float64,
    timestamp DateTime
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/time_series', '{replica}')
PARTITION BY toYYYYMM(timestamp)
ORDER BY (metric_id, timestamp);

-- 创建角色
CREATE ROLE IF NOT EXISTS realtime_analyst;
CREATE ROLE IF NOT EXISTS daily_analyst;
CREATE ROLE IF NOT EXISTS monthly_analyst;

-- 创建行策略
-- 实时分析师：只访问最近 1 小时
CREATE ROW POLICY IF NOT EXISTS realtime_filter
ON analytics.time_series
USING timestamp >= now() - INTERVAL 1 HOUR
AS RESTRICTIVE TO realtime_analyst;

-- 日分析师：只访问最近 7 天
CREATE ROW POLICY IF NOT EXISTS daily_filter
ON analytics.time_series
USING timestamp >= now() - INTERVAL 7 DAY
AS RESTRICTIVE TO daily_analyst;

-- 月分析师：只访问最近 30 天
CREATE ROW POLICY IF NOT EXISTS monthly_filter
ON analytics.time_series
USING timestamp >= now() - INTERVAL 30 DAY
AS RESTRICTIVE TO monthly_analyst;
```

### 示例 5: 组合多个策略

```sql
-- 创建表
CREATE TABLE IF NOT EXISTS secure.transactions
ON CLUSTER 'treasurycluster'
(
    transaction_id UInt64,
    user_id String,
    amount Decimal(18, 2),
    status String,
    sensitivity_level Enum8('low' = 1, 'medium' = 2, 'high' = 3),
    transaction_date DateTime
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/transactions', '{replica}')
PARTITION BY toYYYYMM(transaction_date)
ORDER BY (user_id, transaction_date);

-- 创建用户
CREATE USER IF NOT EXISTS alice
IDENTIFIED WITH sha256_password BY 'Alice123!'
SETTINGS 
    department = 'sales',
    sensitivity_level = 'medium';

-- 创建行策略
-- 策略 1：部门过滤
CREATE ROW POLICY IF NOT EXISTS department_filter
ON secure.transactions
USING department = current_user_settings['department']
AS RESTRICTIVE TO alice;

-- 策略 2：敏感级别过滤
CREATE ROW POLICY IF NOT EXISTS sensitivity_filter
ON secure.transactions
USING sensitivity_level <= current_user_settings['sensitivity_level']
AS RESTRICTIVE TO alice;

-- 策略 3：时间窗口过滤
CREATE ROW POLICY IF NOT EXISTS time_filter
ON secure.transactions
USING transaction_date >= now() - INTERVAL 90 DAY
AS RESTRICTIVE TO alice;

-- 组合效果：alice 只能看到最近 90 天、sales 部门、medium 或更低敏感级别的交易
```

## 🎯 行级安全最佳实践

1. **使用索引列**：在行策略中使用索引列以提高性能
2. **简化条件**：避免复杂的子查询和函数调用
3. **测试策略**：在生产环境前先在测试环境验证策略
4. **监控性能**：监控行策略对查询性能的影响
5. **文档化策略**：记录每个策略的目的和影响
6. **定期审查**：定期审查和清理不必要的策略
7. **分层策略**：创建多层策略以实现细粒度控制
8. **使用角色**：通过角色管理行策略，而非直接分配给用户

## ⚠️ 注意事项

1. **性能影响**：行策略会影响查询性能，需谨慎使用
2. **策略顺序**：多个策略的执行顺序可能影响结果
3. **管理员权限**：管理员角色默认不受行策略限制
4. **分布式表**：行策略需要在本地表上创建
5. **视图支持**：行策略不自动应用于视图
6. **调试困难**：行策略可能使查询调试变得更复杂

## 📚 相关文档

- [用户认证](./01_authentication.md)
- [用户和角色管理](./02_user_role_management.md)
- [权限控制](./03_permissions.md)
- [审计日志](./07_audit_log.md)
