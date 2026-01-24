CREATE USER IF NOT EXISTS admin_user
IDENTIFIED WITH sha256_password BY 'SecurePassword123!'
-- REMOVED SET access_management (not supported) 1;

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



-- ========================================
-- 创建 SHA-256 密码用户
-- ========================================

-- 创建 LDAP 认证的用户
-- LDAP AUTHENTICATION (skipped - not configured)


-- 为 LDAP 用户分配角色
CREATE ROLE IF NOT EXISTS ldap_role;
GRANT SELECT ON *.* TO ldap_role;
-- GRANT TO ldap_user (skipped - user does not exist)

-- ========================================
-- 创建 SHA-256 密码用户
-- ========================================

-- 创建 Kerberos 认证的用户
-- KERBEROS AUTHENTICATION (skipped - not configured)


-- 为 Kerberos 用户分配角色
CREATE ROLE IF NOT EXISTS kerberos_role;
GRANT SELECT ON *.* TO kerberos_role;
-- GRANT TO kerberos_user (skipped - user does not exist)

-- ========================================
-- 创建 SHA-256 密码用户
-- ========================================

-- 创建使用 SSL 证书认证的用户
-- CERTIFICATE AUTHENTICATION (skipped - not configured)


-- 为证书用户分配角色
CREATE ROLE IF NOT EXISTS cert_role;
GRANT SELECT, INSERT ON *.* TO cert_role;
-- GRANT TO cert_user (skipped - user does not exist)

-- ========================================
-- 创建 SHA-256 密码用户
-- ========================================

-- 创建管理员用户（SHA-256 密码）
CREATE USER IF NOT EXISTS admin
IDENTIFIED WITH sha256_password BY 'AdminPassword123!'
-- REMOVED SET access_management (not supported) 1;

-- 创建 LDAP 用户
CREATE USER IF NOT EXISTS ldap_analyst
IDENTIFIED WITH ldap_server 'company_ldap';

-- 创建 Kerberos 用户
-- KERBEROS AUTHENTICATION (skipped - not configured)


-- 创建证书用户
-- CERTIFICATE AUTHENTICATION (skipped - not configured)


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
-- GRANT TO kerberos_user (skipped - user does not exist)
-- GRANT TO cert_user (skipped - user does not exist)
