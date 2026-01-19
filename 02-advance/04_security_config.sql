-- ================================================
-- 04_security_config.sql
-- ClickHouse 安全配置示例
-- ================================================

-- ========================================
-- 1. 用户和角色管理
-- ========================================

-- 查看当前用户
SELECT name, storage, auth_type FROM system.users;

-- 查看当前角色
SELECT name, storage FROM system.roles;

-- 创建用户（需要管理员权限）
/*
CREATE USER IF NOT EXISTS app_user
IDENTIFIED WITH sha256_password BY 'secure_password_123'
HOST ANY
SETTINGS PROFILE default_profile;
*/

-- 为用户授予权限
/*
GRANT SELECT, INSERT ON default.* TO app_user;
*/

-- 创建角色
/*
CREATE ROLE IF NOT EXISTS readonly_role;
CREATE ROLE IF NOT EXISTS readwrite_role;
*/

-- 为角色授予权限
/*
GRANT SELECT ON *.* TO readonly_role;
GRANT SELECT, INSERT, UPDATE ON *.* TO readwrite_role;
*/

-- 将角色分配给用户
/*
GRANT readonly_role TO app_user;
*/

-- ========================================
-- 2. 访问控制列表 (ACL)
-- ========================================

-- 查看授权信息
SELECT
    user_name,
    role_name,
    database,
    table,
    grant_option
FROM system.grants;

-- 查看用户的角色
SELECT
    user_name,
    role_name
FROM system.role_grants;

-- 查看当前用户权限
SHOW GRANTS;

-- ========================================
-- 3. 配置文件和配额
-- ========================================

-- 查看配置文件
SELECT name, type FROM system.settings_profiles;

-- 查看配额
SELECT name, keys FROM system.quotas;

-- 创建自定义配置文件
/*
-- 在 users.xml 中添加或使用 SQL:
CREATE SETTINGS PROFILE IF NOT EXISTS app_profile
SETTINGS max_memory_usage = 10000000000,
         max_execution_time = 60,
         max_threads = 4;

CREATE SETTINGS PROFILE IF NOT EXISTS analytics_profile
SETTINGS max_memory_usage = 20000000000,
         max_execution_time = 300,
         max_threads = 8;
*/

-- 创建配额
/*
-- 在 users.xml 中添加或使用 SQL:
CREATE QUOTA IF NOT EXISTS app_quota
FOR INTERVAL 1 HOUR
MAX queries = 1000,
     errors = 10,
     result_rows = 10000000,
     read_rows = 100000000,
     execution_time = 3600
TO app_user;
*/

-- 查看当前用户的设置
SHOW SETTINGS;

-- ========================================
-- 4. 行级安全 (Row-Level Security)
-- ========================================

-- 创建测试表
CREATE TABLE IF NOT EXISTS security_test.users (
    user_id UInt64,
    username String,
    email String,
    department String,
    salary UInt32,
    is_active UInt8
) ENGINE = MergeTree()
ORDER BY user_id;

-- 插入测试数据
INSERT INTO security_test.users (user_id, username, email, department, salary, is_active) VALUES
(1, 'alice', 'alice@company.com', 'Engineering', 80000, 1),
(2, 'bob', 'bob@company.com', 'Engineering', 90000, 1),
(3, 'charlie', 'charlie@company.com', 'HR', 70000, 1),
(4, 'david', 'david@company.com', 'Finance', 85000, 1),
(5, 'eve', 'eve@company.com', 'Engineering', 75000, 1);

-- 创建视图实现行级过滤（只显示特定部门）
CREATE VIEW IF NOT EXISTS security_test.engineering_users AS
SELECT *
FROM security_test.users
WHERE department = 'Engineering';

CREATE VIEW IF NOT EXISTS security_test.hr_users AS
SELECT *
FROM security_test.users
WHERE department = 'HR';

-- 查询视图
SELECT * FROM security_test.engineering_users;
SELECT * FROM security_test.hr_users;

-- 使用策略实现行级安全（ClickHouse Enterprise 功能）
/*
-- 示例：创建只显示活跃用户的策略
CREATE POLICY IF NOT EXISTS active_users_policy
ON security_test.users
FOR SELECT
USING is_active = 1
TO app_user;

-- 应用策略
APPLY POLICY active_users_policy TO app_user;
*/

-- ========================================
-- 5. 列级安全 (Column-Level Security)
-- ========================================

-- 创建敏感列视图（隐藏薪资信息）
CREATE VIEW IF NOT EXISTS security_test.users_public AS
SELECT
    user_id,
    username,
    email,
    department,
    is_active
FROM security_test.users;

-- 查询公共视图
SELECT * FROM security_test.users_public;

-- 创建管理员视图（包含所有列）
CREATE VIEW IF NOT EXISTS security_test.users_admin AS
SELECT *
FROM security_test.users;

-- ========================================
-- 6. 数据掩码
-- ========================================

-- 创建带掩码的视图（隐藏邮箱）
CREATE VIEW IF NOT EXISTS security_test.users_masked_email AS
SELECT
    user_id,
    username,
    concat(substring(email, 1, 2), '***@', substring(email, position(email, '@'))) as masked_email,
    department,
    salary,
    is_active
FROM security_test.users;

-- 查询掩码视图
SELECT * FROM security_test.users_masked_email;

-- 创建带掩码的视图（隐藏薪资）
CREATE VIEW IF NOT EXISTS security_test.users_masked_salary AS
SELECT
    user_id,
    username,
    email,
    department,
    concat(toString(salary / 1000), 'k') as masked_salary,
    is_active
FROM security_test.users;

-- 查询薪资掩码视图
SELECT * FROM security_test.users_masked_salary;

-- ========================================
-- 7. 审计日志
-- ========================================

-- 启用查询日志（如果未启用）
/*
SET log_queries = 1;
SET log_queries_min_type = 'QueryFinish';
*/

-- 查看用户查询历史
SELECT
    event_time,
    user,
    query_id,
    type,
    query,
    query_duration_ms,
    read_rows,
    read_bytes,
    memory_usage
FROM system.query_log
WHERE event_date >= today()
  AND query NOT LIKE 'SELECT FROM system.%'
ORDER BY event_time DESC
LIMIT 20;

-- 查看敏感操作
SELECT
    event_time,
    user,
    type,
    query,
    exception_text
FROM system.query_log
WHERE event_date >= today()
  AND (
    ilike(query, '%DROP TABLE%')
    OR ilike(query, '%DELETE FROM%')
    OR ilike(query, '%ALTER TABLE%')
    OR ilike(query, '%CREATE USER%')
    OR ilike(query, '%GRANT%')
    OR ilike(query, '%REVOKE%')
  )
ORDER BY event_time DESC
LIMIT 10;

-- 创建审计日志表
CREATE TABLE IF NOT EXISTS security_test.audit_log (
    event_time DateTime,
    user String,
    operation_type String,
    query String,
    affected_table String,
    rows_affected UInt64
) ENGINE = MergeTree()
PARTITION BY toDate(event_time)
ORDER BY (event_time, user);

-- 插入审计记录（示例）
INSERT INTO security_test.audit_log VALUES
(now(), 'admin', 'SELECT', 'SELECT * FROM security_test.users', 'security_test.users', 5);

-- 查询审计日志
SELECT * FROM security_test.audit_log
WHERE event_time >= now() - INTERVAL 1 DAY
ORDER BY event_time DESC;

-- ========================================
-- 8. 网络安全配置
-- ========================================

-- 查看当前连接
SELECT
    user,
    initial_address as remote_host,
    initial_port as remote_port,
    connection_id,
    connected_at
FROM system.connections
ORDER BY connected_at DESC;

-- 查看当前设置
SELECT
    name,
    value,
    description
FROM system.settings
WHERE name LIKE '%tcp%'
   OR name LIKE '%host%'
   OR name LIKE '%interface%'
ORDER BY name;

-- 创建 IP 白名单（需要在配置文件中设置）
/*
-- 在 users.xml 中添加:
<ip_range>
    <name>local_network</name>
    <ip>::/0</ip>
    <ip>127.0.0.1</ip>
</ip_range>

-- 创建只允许特定 IP 访问的用户:
CREATE USER IF NOT EXISTS restricted_user
IDENTIFIED WITH sha256_password BY 'secure_password'
HOST IP '192.168.1.0/24'
HOST IP '10.0.0.0/8';
*/

-- ========================================
-- 9. 加密和 SSL/TLS
-- ========================================

-- 查看加密设置
/*
-- 在配置文件中启用 TLS:
<listen_host>::1</listen_host>
<listen_host>0.0.0.0</listen_host>

<tcp_port_secure>9440</tcp_port_secure>
<https_port>8443</https_port>

<openSSL>
    <server>
        <certificateFile>/etc/clickhouse-server/certs/server.crt</certificateFile>
        <privateKeyFile>/etc/clickhouse-server/certs/server.key</privateKeyFile>
        <caConfig>/etc/clickhouse-server/certs/ca.crt</caConfig>
        <verificationMode>strict</verificationMode>
        <cacheSessions>true</cacheSessions>
        <disableProtocols>sslv2,sslv3</disableProtocols>
        <preferServerCiphers>true</preferServerCiphers>
    </server>
</openSSL>
*/

-- 使用加密连接（示例）
/*
-- 使用 clickhouse-client 连接:
clickhouse-client --secure --host localhost --port 9440

-- 使用 HTTPS:
curl -k https://localhost:8443/?query=SELECT%201
*/

-- ========================================
-- 10. 数据加密
-- ========================================

/*
-- ClickHouse 支持磁盘加密（Enterprise 功能）
-- 在配置文件中启用:
<disk_encryption>
    <name>encrypted_disk</name>
    <path>/var/lib/clickhouse/encrypted</path>
    <key>your-encryption-key</key>
    <algorithm>AES-256-CBC</algorithm>
</disk_encryption>

-- 使用加密磁盘:
<storage_configuration>
    <disks>
        <disk_encrypted>
            <name>encrypted_disk</name>
            <path>/var/lib/clickhouse/encrypted</path>
        </disk_encrypted>
    </disks>
</storage_configuration>
*/

-- ========================================
-- 11. 密码管理
-- ========================================

-- 查看用户认证信息
SELECT
    name,
    auth_type,
    auth_params
FROM system.users;

-- 创建强密码用户
/*
CREATE USER IF NOT EXISTS secure_user
IDENTIFIED WITH double_sha1_password BY 'VeryStrongPassword123!'
HOST LOCAL
HOST REGEXP '192\.168\.1\.\d+';
*/

-- 修改用户密码
/*
ALTER USER app_user IDENTIFIED BY 'NewStrongPassword456!';
*/

-- 禁用用户
/*
ALTER USER app_user HOST NONE;
*/

-- 启用用户
/*
ALTER USER app_user HOST ANY;
*/

-- ========================================
-- 12. 最小权限原则
-- ========================================

-- 创建只读用户
/*
CREATE USER IF NOT EXISTS readonly_user
IDENTIFIED WITH sha256_password BY 'ReadOnlyPassword123'
HOST ANY;

GRANT SELECT ON *.* TO readonly_user;

-- 配置只读限制
CREATE SETTINGS PROFILE readonly_profile
SETTINGS readonly = 1;

GRANT readonly_profile TO readonly_user;
*/

-- 创建应用用户（最小权限）
/*
CREATE USER IF NOT EXISTS app_writer
IDENTIFIED WITH sha256_password BY 'AppWriterPassword123'
HOST IP '192.168.1.0/24';

-- 只授予必要的权限
GRANT SELECT, INSERT ON app_database.* TO app_writer;
GRANT CREATE TEMPORARY TABLE ON *.* TO app_writer;
*/

-- ========================================
-- 13. 定期安全审查
-- ========================================

-- 查看所有用户和权限
SELECT
    u.name as user_name,
    u.auth_type,
    g.role_name,
    g.database,
    g.table
FROM system.users u
LEFT JOIN system.role_grants rg ON u.name = rg.user_name
LEFT JOIN system.grants g ON g.user_name = u.name
ORDER BY u.name, g.database, g.table;

-- 查看有管理员权限的用户
SELECT
    user_name
FROM system.grants
WHERE grant_option = 1
GROUP BY user_name;

-- 查看权限过多的用户
SELECT
    user_name,
    count(DISTINCT concat(database, '.', table)) as table_access_count
FROM system.grants
WHERE database != 'system'
GROUP BY user_name
HAVING count(DISTINCT concat(database, '.', table)) > 10
ORDER BY table_access_count DESC;

-- 查看未使用的用户（需要查询日志支持）
/*
SELECT
    u.name as user_name,
    max(l.event_time) as last_login
FROM system.users u
LEFT JOIN system.query_log l ON u.name = l.user
GROUP BY u.name
HAVING max(l.event_time) < now() - INTERVAL 30 DAY
ORDER BY last_login;
*/

-- ========================================
-- 14. 安全扫描查询
-- ========================================

-- 扫描弱密码用户（示例逻辑）
/*
SELECT
    name as user_name,
    'Check password strength' as recommendation
FROM system.users
WHERE auth_type LIKE 'plaintext_password';
*/

-- 扫描过度授权
SELECT
    user_name,
    'Review permissions' as issue,
    count(DISTINCT database) as database_count,
    count(DISTINCT table) as table_count
FROM system.grants
WHERE grant_option = 1
GROUP BY user_name
HAVING database_count > 5 OR table_count > 20;

-- 扫描敏感数据访问
SELECT
    user_name,
    database,
    table,
    count() as access_count
FROM system.query_log
WHERE event_date >= today()
  AND query LIKE '%password%'
  OR query LIKE '%salary%'
  OR query LIKE '%credit_card%'
GROUP BY user_name, database, table
ORDER BY access_count DESC;

-- ========================================
-- 15. 安全事件响应
-- ========================================

-- 创建安全事件表
CREATE TABLE IF NOT EXISTS security_test.security_events (
    event_time DateTime,
    event_type String,
    user_name String,
    remote_host String,
    details String,
    severity String
) ENGINE = MergeTree()
PARTITION BY toDate(event_time)
ORDER BY (event_time, event_type);

-- 记录安全事件（示例）
INSERT INTO security_test.security_events VALUES
(now(), 'FAILED_LOGIN', 'unknown', '192.168.1.100', '3 failed attempts', 'WARNING'),
(now(), 'UNAUTHORIZED_ACCESS', 'app_user', '192.168.1.101', 'Attempted DROP TABLE', 'CRITICAL');

-- 查看安全事件
SELECT
    event_time,
    event_type,
    user_name,
    remote_host,
    details,
    severity
FROM security_test.security_events
WHERE event_time >= now() - INTERVAL 7 DAY
ORDER BY event_time DESC;

-- ========================================
-- 16. 清理测试数据
-- ========================================
DROP TABLE IF EXISTS security_test.users;
DROP TABLE IF EXISTS security_test.engineering_users;
DROP TABLE IF EXISTS security_test.hr_users;
DROP TABLE IF EXISTS security_test.users_public;
DROP TABLE IF EXISTS security_test.users_admin;
DROP TABLE IF EXISTS security_test.users_masked_email;
DROP TABLE IF EXISTS security_test.users_masked_salary;
DROP TABLE IF EXISTS security_test.audit_log;
DROP TABLE IF EXISTS security_test.security_events;
DROP DATABASE IF EXISTS security_test;

-- ========================================
-- 17. 安全最佳实践总结
-- ========================================
/*
安全配置最佳实践：

1. 认证和授权
   - 使用强密码和加密认证
   - 实施最小权限原则
   - 定期审查用户权限
   - 禁用未使用的账户

2. 数据保护
   - 实施行级和列级安全
   - 使用数据掩码保护敏感信息
   - 启用数据加密
   - 配置 SSL/TLS 连接

3. 访问控制
   - 限制网络访问（IP 白名单）
   - 使用角色和权限组
   - 配置配额和资源限制
   - 实施审计日志

4. 监控和告警
   - 监控异常访问模式
   - 检测安全事件
   - 设置安全告警
   - 定期安全审计

5. 合规性
   - 遵守 GDPR、HIPAA 等法规
   - 记录所有数据访问
   - 实施数据保留策略
   - 定期安全评估
*/
