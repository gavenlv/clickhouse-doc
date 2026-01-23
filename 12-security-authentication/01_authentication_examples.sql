-- ================================================
-- 01_authentication_examples.sql
-- 从 01_authentication.md 提取的 SQL 示例
-- 提取时间: 2026-01-23 14:40:17
-- ================================================


-- ========================================
-- 创建 SHA-256 密码用户
-- ========================================

-- 创建使用 SHA-256 密码的用户
CREATE USER IF NOT EXISTS admin_user
IDENTIFIED WITH sha256_password BY 'SecurePassword123!'
SETTINGS access_management = 1;

-- 创建普通用户
CREATE USER IF NOT EXISTS readonly_user
IDENTIFIED WITH sha256_password BY 'ReadOnly123!';

-- 创建用户并指定默认角色
CREATE USER IF NOT EXISTS analyst
IDENTIFIED WITH sha256_password BY 'Analyst123!'
DEFAULT ROLE analyst_role;

-- ========================================
-- 创建 SHA-256 密码用户
-- ========================================

-- 创建使用 Double SHA-1 密码的用户
CREATE USER IF NOT EXISTS mysql_compatible_user
IDENTIFIED WITH double_sha1_password BY 'MySQLPassword123!';

-- ========================================
-- 创建 SHA-256 密码用户
-- ========================================

-- 创建使用明文密码的用户（仅用于测试）
CREATE USER IF NOT EXISTS test_user
IDENTIFIED WITH plaintext_password BY 'TestPassword123!';

-- 或者在 users.xml 中
<test_user>
    <password>TestPassword123!</password>
</test_user>

-- ========================================
-- 创建 SHA-256 密码用户
-- ========================================

-- 创建 LDAP 认证的用户
CREATE USER IF NOT EXISTS ldap_user
IDENTIFIED WITH ldap_server 'my_ldap_server'
SERVER my_ldap_server;

-- 为 LDAP 用户分配角色
CREATE ROLE IF NOT EXISTS ldap_role;
GRANT SELECT ON *.* TO ldap_role;
GRANT ldap_role TO ldap_user;

-- ========================================
-- 创建 SHA-256 密码用户
-- ========================================

-- 创建 Kerberos 认证的用户
CREATE USER IF NOT EXISTS kerberos_user
IDENTIFIED WITH kerberos
SERVER kerberos;

-- 为 Kerberos 用户分配角色
CREATE ROLE IF NOT EXISTS kerberos_role;
GRANT SELECT ON *.* TO kerberos_role;
GRANT kerberos_role TO kerberos_user;

-- ========================================
-- 创建 SHA-256 密码用户
-- ========================================

-- 创建使用 SSL 证书认证的用户
CREATE USER IF NOT EXISTS cert_user
IDENTIFIED WITH ssl_certificate CN 'user1'
SERVER 'clickhouse1';

-- 为证书用户分配角色
CREATE ROLE IF NOT EXISTS cert_role;
GRANT SELECT, INSERT ON *.* TO cert_role;
GRANT cert_role TO cert_user;

-- ========================================
-- 创建 SHA-256 密码用户
-- ========================================

-- 创建管理员用户（SHA-256 密码）
CREATE USER IF NOT EXISTS admin
IDENTIFIED WITH sha256_password BY 'AdminPassword123!'
SETTINGS access_management = 1;

-- 创建 LDAP 用户
CREATE USER IF NOT EXISTS ldap_analyst
IDENTIFIED WITH ldap_server 'company_ldap';

-- 创建 Kerberos 用户
CREATE USER IF NOT EXISTS kerberos_user
IDENTIFIED WITH kerberos
SERVER 'kerberos';

-- 创建证书用户
CREATE USER IF NOT EXISTS cert_user
IDENTIFIED WITH ssl_certificate CN 'analyst1';

-- 创建角色
CREATE ROLE IF NOT EXISTS admin_role;
CREATE ROLE IF NOT EXISTS analyst_role;
CREATE ROLE IF NOT EXISTS readonly_role;

-- 分配权限
GRANT ALL ON *.* TO admin_role;
GRANT SELECT, INSERT ON *.* TO analyst_role;
GRANT SELECT ON *.* TO readonly_role;

-- 分配角色
GRANT admin_role TO admin;
GRANT analyst_role TO ldap_analyst;
GRANT analyst_role TO kerberos_user;
GRANT analyst_role TO cert_user;
