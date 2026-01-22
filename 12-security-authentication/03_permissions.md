# 权限控制

ClickHouse 提供了细粒度的权限控制系统，允许在数据库、表、列甚至行级别控制访问。本节将详细介绍 ClickHouse 的权限模型和权限管理。

## 📑 目录

- [权限模型](#权限模型)
- [权限类型](#权限类型)
- [授予权限](#授予权限)
- [撤销权限](#撤销权限)
- [列级权限](#列级权限)
- [函数和字典权限](#函数和字典权限)
- [权限监控](#权限监控)
- [实战示例](#实战示例)

## 权限模型

### 权限层级

ClickHouse 的权限系统分为多个层级：

```
全局级别 (*.*)
├── 数据库级别 (database.*)
│   ├── 表级别 (database.table)
│   │   ├── 列级别 (database.table.column)
│   │   └── 行级别 (ROW POLICY)
│   └── 视图级别 (database.view)
├── 字典级别 (DICTIONARY)
└── 函数级别 (FUNCTION)
```

### 权限作用域

| 作用域 | 说明 | 示例 |
|--------|------|------|
| **全局** | 所有数据库和表 | `GRANT SELECT ON *.*` |
| **数据库** | 特定数据库的所有表 | `GRANT SELECT ON db.*` |
| **表** | 特定表 | `GRANT SELECT ON db.table` |
| **列** | 特定列 | `GRANT SELECT(col1, col2) ON db.table` |
| **行** | 特定行（通过行策略） | `CREATE ROW POLICY` |
| **字典** | 外部字典 | `GRANT SELECT ON DICTIONARY` |
| **函数** | 用户自定义函数 | `GRANT SELECT ON FUNCTION` |

## 权限类型

### 数据操作权限

| 权限 | 说明 | 示例 |
|------|------|------|
| **SELECT** | 查询数据 | `SELECT * FROM table` |
| **INSERT** | 插入数据 | `INSERT INTO table VALUES (...)` |
| **ALTER** | 修改表结构 | `ALTER TABLE ...` |
| **TRUNCATE** | 清空表 | `TRUNCATE TABLE table` |
| **CREATE** | 创建对象 | `CREATE TABLE ...` |
| **DROP** | 删除对象 | `DROP TABLE ...` |
| **OPTIMIZE** | 优化表 | `OPTIMIZE TABLE ...` |
| **SHOW** | 显示信息 | `SHOW TABLES` |
| **KILL QUERY** | 终止查询 | `KILL QUERY ...` |
| **SYSTEM** | 系统操作 | `SYSTEM RELOAD ...` |

### ALTER 子权限

| 子权限 | 说明 | 示例 |
|--------|------|------|
| **ALTER UPDATE** | 更新数据 | `ALTER TABLE ... UPDATE ...` |
| **ALTER DELETE** | 删除数据 | `ALTER TABLE ... DELETE ...` |
| **ALTER ADD COLUMN** | 添加列 | `ALTER TABLE ... ADD COLUMN ...` |
| **ALTER DROP COLUMN** | 删除列 | `ALTER TABLE ... DROP COLUMN ...` |
| **ALTER MODIFY COLUMN** | 修改列 | `ALTER TABLE ... MODIFY COLUMN ...` |
| **ALTER ADD INDEX** | 添加索引 | `ALTER TABLE ... ADD INDEX ...` |
| **ALTER DROP INDEX** | 删除索引 | `ALTER TABLE ... DROP INDEX ...` |
| **ALTER RENAME** | 重命名 | `ALTER TABLE ... RENAME ...` |

### 其他权限

| 权限 | 说明 | 示例 |
|------|------|------|
| **SOURCE** | 从外部源导入数据 | `CREATE TABLE ... ENGINE = URL(...)` |
| **SINK** | 导出到外部目标 | `INSERT INTO FUNCTION ...` |
| **VIEW** | 创建视图 | `CREATE VIEW ...` |
| **DICTIONARY** | 访问字典 | `SELECT * FROM dict(...)` |
| **FUNCTION** | 执行 UDF | `SELECT my_func(...)` |
| **ALL** | 所有权限 | `GRANT ALL ON *.*` |

## 授予权限

### 授予全局权限

```sql
-- 授予全局 SELECT 权限（只读）
GRANT SELECT ON *.* TO readonly_role;

-- 授予全局 INSERT 和 SELECT 权限（读写）
GRANT INSERT, SELECT ON *.* TO writer_role;

-- 授予所有权限（管理员）
GRANT ALL ON *.* TO admin_role;

-- 授予特定 ALTER 子权限
GRANT ALTER UPDATE, ALTER DELETE ON *.* TO updater_role;

-- 授予系统操作权限
GRANT SYSTEM ON *.* TO system_admin_role;

-- 授予终止查询权限
GRANT KILL QUERY ON *.* TO query_killer_role;
```

### 授予数据库级别权限

```sql
-- 授予特定数据库的 SELECT 权限
GRANT SELECT ON analytics.* TO analyst_role;

-- 授予特定数据库的所有权限
GRANT ALL ON analytics.* TO analytics_admin_role;

-- 授予特定数据库的读写权限
GRANT SELECT, INSERT ON sales.* TO sales_writer_role;

-- 授予多个数据库的权限
GRANT SELECT ON analytics.*, sales.*, marketing.* TO multi_db_reader_role;
```

### 授予表级别权限

```sql
-- 授予特定表的 SELECT 权限
GRANT SELECT ON analytics.events TO event_reader_role;

-- 授予特定表的读写权限
GRANT SELECT, INSERT ON sales.orders TO order_writer_role;

-- 授予特定表的 UPDATE 和 DELETE 权限
GRANT ALTER UPDATE, ALTER DELETE ON sales.orders TO order_updater_role;

-- 授予多个表的权限
GRANT SELECT ON 
    analytics.events,
    analytics.users,
    analytics.orders
TO analyst_role;
```

### 授予列级别权限

```sql
-- 授予特定列的 SELECT 权限
GRANT SELECT(user_id, event_type, event_time) 
ON analytics.events 
TO restricted_analyst_role;

-- 授予 INSERT 权限到特定列
GRANT INSERT(user_id, event_type) 
ON analytics.events 
TO event_writer_role;

-- 授予 UPDATE 权限到特定列
GRANT ALTER UPDATE(status, amount) 
ON sales.orders 
TO order_updater_role;

-- 组合列级权限
GRANT 
    SELECT(user_id, username) 
    ON analytics.users,
    SELECT(event_id, event_type) 
    ON analytics.events
TO restricted_role;
```

### 授予函数和字典权限

```sql
-- 授予字典权限
GRANT SELECT ON DICTIONARY user_dict TO dictionary_user_role;

-- 授予函数权限
GRANT SELECT ON FUNCTION my_udf TO function_user_role;

-- 授予多个字典权限
GRANT SELECT ON DICTIONARY
    user_dict,
    product_dict,
    category_dict
TO dictionary_analyst_role;
```

## 撤销权限

### 撤销权限

```sql
-- 撤销全局权限
REVOKE INSERT ON *.* FROM writer_role;

-- 撤销数据库权限
REVOKE ALTER ON analytics.* FROM analyst_role;

-- 撤销表权限
REVOKE SELECT ON analytics.events FROM event_reader_role;

-- 撤销列权限
REVOKE SELECT(password, token) ON analytics.users FROM analyst_role;

-- 撤销 ALTER 子权限
REVOKE ALTER UPDATE, ALTER DELETE ON sales.* FROM updater_role;
```

### 撤销所有权限

```sql
-- 撤销角色所有权限
REVOKE ALL PRIVILEGES, GRANT OPTION FROM admin_role;

-- 撤销用户所有权限
REVOKE ALL PRIVILEGES, GRANT OPTION FROM alice;

-- 撤销特定作用域的所有权限
REVOKE ALL PRIVILEGES ON analytics.* FROM analytics_role;
```

## 列级权限

### 创建列级权限

```sql
-- 创建只读敏感列的角色
CREATE ROLE IF NOT EXISTS sensitive_data_reader;

-- 授予非敏感列的 SELECT 权限
GRANT 
    SELECT(user_id, username, email) 
ON analytics.users 
TO sensitive_data_reader;

-- 拒绝敏感列的访问
REVOKE SELECT(password, token, credit_card) 
ON analytics.users 
FROM sensitive_data_reader;

-- 创建敏感数据管理员角色
CREATE ROLE IF NOT EXISTS sensitive_data_admin;

-- 授予所有列的权限
GRANT ALL ON analytics.users TO sensitive_data_admin;
```

### 列级权限实战

```sql
-- 场景：保护用户隐私数据
CREATE ROLE IF NOT EXISTS privacy_protected_role;

-- 用户可以查看基本信息
GRANT 
    SELECT(user_id, username, email, created_at) 
ON analytics.users 
TO privacy_protected_role;

-- 用户不能查看敏感信息
REVOKE 
    SELECT(password, token, phone, address) 
ON analytics.users 
FROM privacy_protected_role;

-- 创建隐私管理员角色
CREATE ROLE IF NOT EXISTS privacy_admin_role;

-- 隐私管理员可以查看所有信息
GRANT SELECT ON analytics.users TO privacy_admin_role;

-- 分配用户
CREATE USER IF NOT EXISTS alice
IDENTIFIED WITH sha256_password BY 'Alice123!'
DEFAULT ROLE privacy_protected_role;

CREATE USER IF NOT EXISTS admin
IDENTIFIED WITH sha256_password BY 'Admin123!'
DEFAULT ROLE privacy_admin_role;
```

## 函数和字典权限

### 字典权限

```sql
-- 创建外部字典
CREATE DICTIONARY IF NOT EXISTS user_dict
(
    user_id UInt64,
    user_name String,
    department String
)
PRIMARY KEY user_id
SOURCE(CLICKHOUSE(
    HOST 'clickhouse1'
    PORT 9000
    USER 'dict_user'
    PASSWORD 'DictPassword123!'
    DATABASE 'analytics'
    TABLE 'users'
))
LIFETIME(MIN 1 MAX 3600)
LAYOUT(HASHED());

-- 授予字典权限
CREATE ROLE IF NOT EXISTS dictionary_reader;
GRANT SELECT ON DICTIONARY user_dict TO dictionary_reader;

-- 使用字典
SELECT 
    e.event_id,
    e.event_type,
    dictGet('user_dict', 'user_name', e.user_id) as user_name,
    dictGet('user_dict', 'department', e.user_id) as department
FROM analytics.events e;
```

### 用户定义函数（UDF）权限

```sql
-- 创建用户定义函数
CREATE FUNCTION IF NOT EXISTS calculate_discount
AS (amount -> amount * 0.9);

-- 授予函数权限
CREATE ROLE IF NOT EXISTS discount_user;
GRANT SELECT ON FUNCTION calculate_discount TO discount_user;

-- 使用 UDF
SELECT 
    order_id,
    amount,
    calculate_discount(amount) as discounted_amount
FROM sales.orders;
```

## 权限监控

### 查看权限

```sql
-- 查看角色权限
SHOW GRANTS FOR readonly_role;

-- 查看用户权限
SHOW GRANTS FOR alice;

-- 查看所有角色的权限
SELECT 
    role_name,
    access_type,
    database,
    table,
    column,
    is_partial_revoke
FROM system.grants
WHERE role_name IS NOT NULL
ORDER BY role_name, access_type;

-- 查看特定数据库的权限
SELECT 
    role_name,
    access_type,
    table,
    column
FROM system.grants
WHERE database = 'analytics'
ORDER BY role_name, table, column;
```

### 查看权限使用情况

```sql
-- 查看用户查询历史和权限使用
SELECT 
    user,
    query,
    query_duration_ms,
    read_rows,
    read_bytes,
    memory_usage,
    exception_code
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_time >= now() - INTERVAL 1 DAY
ORDER BY event_time DESC
LIMIT 100;

-- 查看权限拒绝的查询
SELECT 
    user,
    query,
    exception_text,
    event_time
FROM system.query_log
WHERE type = 'Exception'
  AND exception_code = 516  -- ACCESS_DENIED
  AND event_time >= now() - INTERVAL 7 DAY
ORDER BY event_time DESC;
```

## 实战示例

### 示例 1: 创建多级权限系统

```sql
-- 创建角色
CREATE ROLE IF NOT EXISTS readonly_role;
CREATE ROLE IF NOT EXISTS writer_role;
CREATE ROLE IF NOT EXISTS analyzer_role;
CREATE ROLE IF NOT EXISTS admin_role;

-- 分配权限
-- 只读角色
GRANT SELECT ON *.* TO readonly_role;

-- 写入角色
GRANT SELECT, INSERT ON *.* TO writer_role;

-- 分析师角色
GRANT SELECT ON *.* TO analyzer_role;
GRANT ALTER UPDATE, ALTER DELETE ON analytics.* TO analyzer_role;

-- 管理员角色
GRANT ALL ON *.* TO admin_role;

-- 创建用户
CREATE USER IF NOT EXISTS alice
IDENTIFIED WITH sha256_password BY 'Alice123!'
DEFAULT ROLE readonly_role;

CREATE USER IF NOT EXISTS bob
IDENTIFIED WITH sha256_password BY 'Bob123!'
DEFAULT ROLE writer_role;

CREATE USER IF NOT EXISTS charlie
IDENTIFIED WITH sha256_password BY 'Charlie123!'
DEFAULT ROLE analyzer_role;

CREATE USER IF NOT EXISTS admin
IDENTIFIED WITH sha256_password BY 'Admin123!'
DEFAULT ROLE admin_role
SETTINGS access_management = 1;
```

### 示例 2: 创建列级权限保护敏感数据

```sql
-- 创建角色
CREATE ROLE IF NOT EXISTS public_analyst;
CREATE ROLE IF NOT EXISTS internal_analyst;
CREATE ROLE IF NOT EXISTS security_admin;

-- 公开分析师：只能查看非敏感数据
GRANT 
    SELECT(
        user_id, 
        username, 
        created_at, 
        last_login
    ) 
ON analytics.users 
TO public_analyst;

-- 内部分析师：可以查看更多数据
GRANT 
    SELECT(
        user_id, 
        username, 
        email, 
        phone, 
        created_at, 
        last_login,
        account_status
    ) 
ON analytics.users 
TO internal_analyst;

-- 安全管理员：可以查看所有数据
GRANT ALL ON analytics.users TO security_admin;

-- 创建用户
CREATE USER IF NOT EXISTS public_analyst
IDENTIFIED WITH sha256_password BY 'PublicAnalyst123!'
DEFAULT ROLE public_analyst;

CREATE USER IF NOT EXISTS internal_analyst
IDENTIFIED WITH sha256_password BY 'InternalAnalyst123!'
DEFAULT ROLE internal_analyst;

CREATE USER IF NOT EXISTS security_admin
IDENTIFIED WITH sha256_password BY 'SecurityAdmin123!'
DEFAULT ROLE security_admin;
```

### 示例 3: 创建按部门的权限控制

```sql
-- 创建角色
CREATE ROLE IF NOT EXISTS sales_reader;
CREATE ROLE IF NOT EXISTS marketing_reader;
CREATE ROLE IF NOT EXISTS finance_reader;

-- 销售部门：只能访问销售数据
GRANT SELECT ON sales.* TO sales_reader;

-- 营销部门：只能访问营销数据
GRANT SELECT ON marketing.* TO marketing_reader;

-- 财务部门：只能访问财务数据
GRANT SELECT ON finance.* TO finance_reader;

-- 创建用户
CREATE USER IF NOT EXISTS alice_sales
IDENTIFIED WITH sha256_password BY 'AliceSales123!'
SETTINGS department = 'sales';

CREATE USER IF NOT EXISTS bob_marketing
IDENTIFIED WITH sha256_password BY 'BobMarketing123!'
SETTINGS department = 'marketing';

CREATE USER IF NOT EXISTS charlie_finance
IDENTIFIED WITH sha256_password BY 'CharlieFinance123!'
SETTINGS department = 'finance';

-- 分配角色
GRANT sales_reader TO alice_sales;
GRANT marketing_reader TO bob_marketing;
GRANT finance_reader TO charlie_finance;

-- 创建行级安全策略
CREATE ROW POLICY IF NOT EXISTS department_filter
ON sales.orders
USING department = current_user_settings['department']
AS RESTRICTIVE TO sales_reader, marketing_reader, finance_reader;
```

### 示例 4: 创建临时访问权限

```sql
-- 创建临时角色（24 小时有效期）
CREATE ROLE IF NOT EXISTS temp_access_role
SETTINGS
    max_execution_time = 86400,  -- 24 小时
    max_memory_usage = 5000000000;  -- 5 GB

GRANT SELECT ON analytics.* TO temp_access_role;

-- 创建临时用户
CREATE USER IF NOT EXISTS temp_user
IDENTIFIED WITH sha256_password BY 'TempUser123!'
DEFAULT ROLE temp_access_role;

-- 24 小时后删除临时用户
-- DROP USER IF EXISTS temp_user;
```

### 示例 5: 创建只读视图权限

```sql
-- 创建只读视图
CREATE VIEW analytics.user_summary AS
SELECT 
    user_id,
    username,
    email,
    created_at,
    status
FROM analytics.users;

-- 创建只读角色
CREATE ROLE IF NOT EXISTS view_only_role;
GRANT SELECT ON analytics.user_summary TO view_only_role;

-- 拒绝对底层表的访问
REVOKE SELECT ON analytics.users FROM view_only_role;

-- 创建用户
CREATE USER IF NOT EXISTS readonly_user
IDENTIFIED WITH sha256_password BY 'ReadOnly123!'
DEFAULT ROLE view_only_role;
```

## 🎯 权限管理最佳实践

1. **最小权限原则**：只授予必要的最小权限
2. **使用角色**：通过角色管理权限，而非直接分配给用户
3. **定期审查**：定期审查和清理不必要的权限
4. **列级权限**：对敏感数据使用列级权限
5. **行级安全**：对需要行级隔离的数据使用行策略
6. **审计日志**：启用审计日志以追踪权限使用
7. **权限测试**：在生产环境前先测试权限配置
8. **文档化**：记录权限设计决策和变更历史

## ⚠️ 注意事项

1. **权限传播**：修改角色权限会影响所有拥有该角色的用户
2. **默认权限**：新建用户默认没有任何权限
3. **拒绝优先**：REVOKE 优先于 GRANT
4. **视图权限**：对视图的权限需要基础表的权限
5. **分布式表**：分布式表的权限需要本地表的权限
6. **权限继承**：角色继承会继承所有权限

## 📚 相关文档

- [用户认证](./01_authentication.md)
- [用户和角色管理](./02_user_role_management.md)
- [行级安全](./04_row_level_security.md)
- [审计日志](./07_audit_log.md)
