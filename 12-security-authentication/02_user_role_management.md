# 用户和角色管理

ClickHouse 的基于角色的访问控制（RBAC）允许通过角色来管理用户权限，简化权限管理并提高安全性。本节将详细介绍如何创建和管理用户及角色。

## 📑 目录

- [RBAC 概览](#rbac-概览)
- [创建和管理用户](#创建和管理用户)
- [创建和管理角色](#创建和管理角色)
- [角色继承和层次结构](#角色继承和层次结构)
- [用户设置](#用户设置)
- [用户和角色监控](#用户和角色监控)
- [实战示例](#实战示例)

## RBAC 概览

### RBAC 优势

基于角色的访问控制（RBAC）提供以下优势：

1. **简化管理**：通过角色统一管理权限
2. **最小权限原则**：为不同角色分配不同的最小权限
3. **职责分离**：将不同的职责分配给不同的角色
4. **易于审计**：通过角色更容易追踪权限
5. **灵活性**：可以灵活组合角色和权限

### RBAC 组件

| 组件 | 说明 | 示例 |
|------|------|------|
| **用户** | 数据库访问的实体 | alice, bob, admin |
| **角色** | 权限的集合 | reader, writer, admin_role |
| **权限** | 对数据库对象的操作 | SELECT, INSERT, UPDATE |
| **组** | 用户的集合（可选） | team1, team2 |

### 权限层级

```
数据库 (database)
├── 表 (table)
│   ├── 列 (column)
│   └── 行 (row)
└── 视图 (view)
```

## 创建和管理用户

### 创建用户

#### 基本用户创建

```sql
-- 创建基本用户
CREATE USER IF NOT EXISTS alice
IDENTIFIED WITH sha256_password BY 'AlicePassword123!';

-- 创建用户并指定默认角色
CREATE USER IF NOT EXISTS bob
IDENTIFIED WITH sha256_password BY 'BobPassword123!'
DEFAULT ROLE analyst_role;

-- 创建用户并指定多个默认角色
CREATE USER IF NOT EXISTS charlie
IDENTIFIED WITH sha256_password BY 'CharliePassword123!'
DEFAULT ROLE readonly_role, analyst_role;
```

#### 创建高级用户

```sql
-- 创建管理员用户
CREATE USER IF NOT EXISTS admin
IDENTIFIED WITH sha256_password BY 'AdminPassword123!'
DEFAULT ROLE admin_role
SETTINGS access_management = 1;

-- 创建带 IP 限制的用户
CREATE USER IF NOT EXISTS restricted_user
IDENTIFIED WITH sha256_password BY 'RestrictedPassword123!'
HOST IP '192.168.1.0/24'
HOST LOCAL;

-- 创建带 SQL 限制的用户
CREATE USER IF NOT EXISTS readonly_user
IDENTIFIED WITH sha256_password BY 'ReadOnlyPassword123!'
SETTINGS
    max_execution_time = 300,  -- 5 分钟
    max_memory_usage = 10000000000,  -- 10 GB
    max_rows_to_read = 1000000000;  -- 10 亿行
```

#### 创建分布式集群用户

```sql
-- 在集群上创建用户
CREATE USER IF NOT EXISTS cluster_user
IDENTIFIED WITH sha256_password BY 'ClusterPassword123!'
ON CLUSTER 'treasurycluster';

-- 在所有节点上创建用户
CREATE USER IF NOT EXISTS replicator
IDENTIFIED WITH sha256_password BY 'ReplicatorPassword123!'
ON CLUSTER 'treasurycluster'
DEFAULT ROLE replicator_role;
```

### 管理用户

#### 查看用户

```sql
-- 查看所有用户
SELECT name, storage, auth_type, host_ip
FROM system.users;

-- 查看用户详细信息
SHOW CREATE USER admin;

-- 查看用户权限
SHOW GRANTS FOR admin;

-- 查看用户角色
SHOW GRANTS FOR alice
WHERE type = 'ROLE';

-- 查看用户设置
SELECT name, value, changed
FROM system.settings
WHERE user = 'alice';
```

#### 修改用户

```sql
-- 修改用户密码
ALTER USER admin IDENTIFIED WITH sha256_password BY 'NewPassword123!';

-- 修改用户默认角色
ALTER USER alice DEFAULT ROLE readonly_role, analyst_role;

-- 修改用户主机限制
ALTER USER bob HOST IP '10.0.0.0/8', '192.168.0.0/16';

-- 修改用户设置
ALTER USER readonly_user
SETTINGS
    max_execution_time = 600,
    max_memory_usage = 20000000000;
```

#### 删除用户

```sql
-- 删除用户
DROP USER IF EXISTS test_user;

-- 在集群上删除用户
DROP USER IF EXISTS old_user
ON CLUSTER 'treasurycluster';

-- 删除用户及其所有权限
DROP USER IF EXISTS deprecated_user
SETTINGS drop_atomic = 0;
```

## 创建和管理角色

### 创建角色

#### 基本角色创建

```sql
-- 创建只读角色
CREATE ROLE IF NOT EXISTS readonly_role;

-- 创建写入角色
CREATE ROLE IF NOT EXISTS writer_role;

-- 创建分析师角色
CREATE ROLE IF NOT EXISTS analyst_role;
```

#### 创建带权限的角色

```sql
-- 创建只读角色并分配权限
CREATE ROLE IF NOT EXISTS readonly_role
GRANT SELECT ON *.*;

-- 创建写入角色并分配权限
CREATE ROLE IF NOT EXISTS writer_role
GRANT INSERT, SELECT ON *.*;

-- 创建管理员角色并分配权限
CREATE ROLE IF NOT EXISTS admin_role
GRANT ALL ON *.*;
```

#### 创建专用角色

```sql
-- 创建数据库管理员角色
CREATE ROLE IF NOT EXISTS db_admin_role
GRANT
    CREATE, DROP, ALTER, TRUNCATE
    ON *.*
SETTINGS
    access_management = 1;

-- 创建数据分析角色（限制内存）
CREATE ROLE IF NOT EXISTS data_analyst_role
GRANT SELECT ON *.*
SETTINGS
    max_memory_usage = 5000000000,  -- 5 GB
    max_execution_time = 300;       -- 5 分钟

-- 创建临时用户角色（有有效期）
CREATE ROLE IF NOT EXISTS temp_role
GRANT SELECT ON *.*
SETTINGS
    max_execution_time = 60,  -- 1 分钟
    max_rows_to_read = 1000000;  -- 100 万行
```

### 管理角色

#### 查看角色

```sql
-- 查看所有角色
SELECT name, storage
FROM system.roles;

-- 查看角色详细信息
SHOW CREATE ROLE analyst_role;

-- 查看角色权限
SHOW GRANTS FOR analyst_role;

-- 查看角色成员
SELECT user_name, role_name
FROM system.role_grants
WHERE role_name = 'analyst_role';
```

#### 修改角色

```sql
-- 为角色添加权限
GRANT INSERT ON analytics.* TO analyst_role;

-- 为角色移除权限
REVOKE INSERT ON system.* FROM analyst_role;

-- 修改角色设置
ALTER ROLE data_analyst_role
SETTINGS
    max_memory_usage = 10000000000,
    max_execution_time = 600;
```

#### 删除角色

```sql
-- 删除角色
DROP ROLE IF EXISTS old_role;

-- 在集群上删除角色
DROP ROLE IF EXISTS deprecated_role
ON CLUSTER 'treasurycluster';
```

## 角色继承和层次结构

### 角色继承

ClickHouse 支持角色继承，允许创建角色层次结构，简化权限管理。

#### 创建角色继承

```sql
-- 创建基础角色
CREATE ROLE IF NOT EXISTS base_role
GRANT SELECT ON *.*;

-- 创建只读角色（继承基础角色）
CREATE ROLE IF NOT EXISTS readonly_role
GRANT SELECT ON *.*
SETTINGS INHERIT 'base_role';

-- 创建分析师角色（继承只读角色）
CREATE ROLE IF NOT EXISTS analyst_role
GRANT SELECT, ALTER UPDATE ON *.*
SETTINGS INHERIT 'readonly_role';
```

#### 角色层次结构示例

```
admin_role (管理员)
├── db_admin_role (数据库管理员)
│   ├── readonly_role (只读)
│   └── writer_role (写入)
├── analyst_role (分析师)
│   ├── readonly_role
│   └── data_analyst_role (数据分析师)
└── user_role (普通用户)
    └── readonly_role
```

```sql
-- 创建角色层次结构
CREATE ROLE IF NOT EXISTS base_role;
GRANT SELECT ON *.* TO base_role;

CREATE ROLE IF NOT EXISTS readonly_role INHERIT base_role;

CREATE ROLE IF NOT EXISTS writer_role INHERIT base_role;
GRANT INSERT ON *.* TO writer_role;

CREATE ROLE IF NOT EXISTS db_admin_role INHERIT readonly_role, writer_role;
GRANT CREATE, DROP, ALTER ON *.* TO db_admin_role;

CREATE ROLE IF NOT EXISTS analyst_role INHERIT readonly_role;
GRANT SELECT, ALTER UPDATE ON *.* TO analyst_role;

CREATE ROLE IF NOT EXISTS admin_role INHERIT db_admin_role, analyst_role;
GRANT ALL ON *.* TO admin_role;
```

### 查看角色继承

```sql
-- 查看角色继承关系
SELECT 
    r.name as role_name,
    r2.name as inherited_role
FROM system.role_grants rg
JOIN system.roles r ON rg.role_name = r.name
LEFT JOIN system.roles r2 ON rg.inherited_role = r2.name;

-- 查看角色的所有权限（包括继承的）
SHOW GRANTS FOR admin_role WITH INHERIT;
```

## 用户设置

### 资源限制设置

```sql
-- 创建有限资源的角色
CREATE ROLE IF NOT EXISTS limited_role
SETTINGS
    -- 内存限制
    max_memory_usage = 10000000000,           -- 10 GB
    max_memory_usage_for_user = 20000000000,  -- 20 GB per user
    
    -- 时间限制
    max_execution_time = 600,                 -- 10 分钟
    max_execution_time_for_user = 1800,       -- 30 分钟 per user
    
    -- 数据量限制
    max_rows_to_read = 1000000000,            -- 10 亿行
    max_bytes_to_read = 10000000000,          -- 10 GB
    max_rows_to_read_for_user = 5000000000,   -- 50 亿行 per user
    
    -- 查询限制
    max_concurrent_queries_for_user = 5,      -- 每用户 5 个并发查询
    max_concurrent_queries = 100,             -- 全局 100 个并发查询
    max_concurrent_insert_queries = 50,       -- 50 个并发插入

    -- 结果集限制
    max_result_rows = 10000000,               -- 1000 万行
    max_result_bytes = 1000000000;            -- 1 GB
```

### 网络设置

```sql
-- 创建网络限制的角色
CREATE ROLE IF NOT EXISTS network_limited_role
SETTINGS
    -- 网络限制
    max_network_bandwidth = 1000000000,       -- 1 GB/s
    max_network_bytes = 10000000000,         -- 10 GB
    
    -- 连接设置
    max_concurrent_queries_for_user = 3,      -- 每用户 3 个并发查询
    max_concurrent_queries = 20;              -- 全局 20 个并发查询
```

### 备份和恢复设置

```sql
-- 创建用于备份的角色
CREATE ROLE IF NOT EXISTS backup_role
SETTINGS
    max_execution_time = 3600,                -- 1 小时
    max_memory_usage = 20000000000,           -- 20 GB
    max_network_bandwidth = 1000000000;       -- 1 GB/s
```

## 用户和角色监控

### 监控用户活动

```sql
-- 查看当前连接的用户
SELECT 
    user,
    client_hostname,
    client_port,
    connection_id,
    query,
    elapsed
FROM system.processes
WHERE type = 'Query';

-- 查看用户查询历史
SELECT 
    user,
    query,
    query_duration_ms,
    read_rows,
    read_bytes,
    memory_usage,
    event_time
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_time >= now() - INTERVAL 1 DAY
ORDER BY event_time DESC;

-- 查看用户资源使用
SELECT 
    user,
    count() as query_count,
    sum(read_rows) as total_read_rows,
    sum(read_bytes) as total_read_bytes,
    sum(memory_usage) as total_memory_usage,
    avg(query_duration_ms) as avg_query_duration_ms
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_time >= now() - INTERVAL 1 DAY
GROUP BY user;
```

### 监控角色使用

```sql
-- 查看角色分配情况
SELECT 
    r.name as role_name,
    count(DISTINCT rg.user_name) as user_count,
    count(DISTINCT rg.role_name) as granted_role_count
FROM system.roles r
LEFT JOIN system.role_grants rg ON r.name = rg.role_name
GROUP BY r.name
ORDER BY user_count DESC;

-- 查看角色权限分布
SELECT 
    role_name,
    access_type,
    count(*) as count
FROM system.grants
WHERE role_name IS NOT NULL
GROUP BY role_name, access_type
ORDER BY role_name, count DESC;
```

## 实战示例

### 示例 1: 创建多角色用户系统

```sql
-- 创建角色
CREATE ROLE IF NOT EXISTS readonly_role;
CREATE ROLE IF NOT EXISTS writer_role;
CREATE ROLE IF NOT EXISTS admin_role;

-- 分配权限
GRANT SELECT ON *.* TO readonly_role;
GRANT INSERT, SELECT ON *.* TO writer_role;
GRANT ALL ON *.* TO admin_role;

-- 创建用户
CREATE USER IF NOT EXISTS alice
IDENTIFIED WITH sha256_password BY 'AlicePassword123!'
DEFAULT ROLE readonly_role;

CREATE USER IF NOT EXISTS bob
IDENTIFIED WITH sha256_password BY 'BobPassword123!'
DEFAULT ROLE writer_role;

CREATE USER IF NOT EXISTS admin
IDENTIFIED WITH sha256_password BY 'AdminPassword123!'
DEFAULT ROLE admin_role
SETTINGS access_management = 1;
```

### 示例 2: 创建按部门的数据访问控制

```sql
-- 创建角色
CREATE ROLE IF NOT EXISTS sales_role;
CREATE ROLE IF NOT EXISTS marketing_role;
CREATE ROLE IF NOT EXISTS finance_role;

-- 创建用户并设置部门属性
CREATE USER IF NOT EXISTS alice_sales
IDENTIFIED WITH sha256_password BY 'AliceSales123!'
SETTINGS department = 'sales';

CREATE USER IF NOT EXISTS bob_marketing
IDENTIFIED WITH sha256_password BY 'BobMarketing123!'
SETTINGS department = 'marketing';

CREATE USER IF NOT EXISTS charlie_finance
IDENTIFIED WITH sha256_password BY 'CharlieFinance123!'
SETTINGS department = 'finance';

-- 创建行级安全策略
CREATE ROW POLICY IF NOT EXISTS department_filter
ON sales.orders
USING department = current_user_settings['department']
AS RESTRICTIVE TO sales_role, marketing_role, finance_role;

-- 分配角色
GRANT SELECT ON sales.* TO sales_role;
GRANT SELECT ON marketing.* TO marketing_role;
GRANT SELECT ON finance.* TO finance_role;

GRANT sales_role TO alice_sales;
GRANT marketing_role TO bob_marketing;
GRANT finance_role TO charlie_finance;
```

### 示例 3: 创建临时访问用户

```sql
-- 创建临时角色（1 小时有效期）
CREATE ROLE IF NOT EXISTS temp_role
SETTINGS
    max_execution_time = 3600,  -- 1 小时
    max_memory_usage = 5000000000;  -- 5 GB

GRANT SELECT ON analytics.* TO temp_role;

-- 创建临时用户
CREATE USER IF NOT EXISTS temp_user
IDENTIFIED WITH sha256_password BY 'TempPassword123!'
DEFAULT ROLE temp_role;

-- 1 小时后删除临时用户
-- DROP USER IF EXISTS temp_user;
```

### 示例 4: 集群用户管理

```sql
-- 在集群上创建角色
CREATE ROLE IF NOT EXISTS cluster_reader_role
ON CLUSTER 'treasurycluster'
GRANT SELECT ON *.*;

CREATE ROLE IF NOT EXISTS cluster_writer_role
ON CLUSTER 'treasurycluster'
GRANT INSERT, SELECT ON *.*;

-- 在集群上创建用户
CREATE USER IF NOT EXISTS cluster_analyst
IDENTIFIED WITH sha256_password BY 'ClusterAnalyst123!'
DEFAULT ROLE cluster_reader_role
ON CLUSTER 'treasurycluster';

CREATE USER IF NOT EXISTS cluster_writer
IDENTIFIED WITH sha256_password BY 'ClusterWriter123!'
DEFAULT ROLE cluster_writer_role
ON CLUSTER 'treasurycluster';
```

## 🎯 用户和角色管理最佳实践

1. **使用角色而非直接权限**：通过角色管理权限，而非直接分配给用户
2. **最小权限原则**：只授予必要的最小权限
3. **角色层次结构**：创建角色层次结构以简化管理
4. **定期审查权限**：定期审查和清理不必要的权限
5. **资源限制**：为普通用户设置合理的资源限制
6. **命名规范**：使用清晰的命名规范（如 `readonly_role`、`writer_role`）
7. **文档化**：记录角色和用户的设计决策
8. **测试先行**：在生产环境前先在测试环境验证

## ⚠️ 注意事项

1. **权限传播**：修改角色权限会影响所有拥有该角色的用户
2. **默认角色**：用户必须至少有一个默认角色才能查询
3. **集群一致性**：在集群上创建用户和角色需要使用 `ON CLUSTER` 子句
4. **密码安全**：使用强密码并定期更换
5. **审计日志**：启用审计日志以追踪用户和角色活动

## 📚 相关文档

- [用户认证](./01_authentication.md)
- [权限控制](./03_permissions.md)
- [行级安全](./04_row_level_security.md)
- [审计日志](./07_audit_log.md)
