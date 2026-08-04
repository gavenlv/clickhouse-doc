-- ================================================================================
-- ClickHouse 身份认证示例
-- ================================================================================
-- 
-- 集群: treasurycluster (2 副本)
-- 预计学习时间: 20 分钟
-- 
-- 本文件涵盖:
--   1. SHA-256 密码认证 - 最常用的认证方式
--   2. Double SHA-1 密码 - MySQL 兼容
--   3. 明文密码 - 仅用于测试
--   4. LDAP 认证 - 企业目录集成
--   5. Kerberos 认证 - 企业单点登录
--   6. SSL 证书认证 - 双向 SSL 认证
-- 
-- 身份认证架构:
-- 
--   ┌─────────────────────────────────────────────────────────────────────────┐
--   │                    ClickHouse 身份认证方式                              │
--   └─────────────────────────────────────────────────────────────────────────┘
--   
--   ┌─────────────────────────────────────────────────────────────────────────┐
--   │                         认证方式选择指南                                │
--   └─────────────────────────────────────────────────────────────────────────┘
--   
--   ┌─────────────┐
--   │ 应用场景?   │
--   └──────┬──────┘
--          │
--   ┌──────┴──────────────────────────────────────────┐
--   │        │        │         │          │          │
--   ▼        ▼        ▼         ▼          ▼          ▼
-- 开发测试  小团队   大型企业  已有LDAP   已有Kerberos 高安全要求
--   │        │        │         │          │          │
--   ▼        ▼        ▼         ▼          ▼          ▼
-- 明文密码  SHA256   SHA256    LDAP      Kerberos   SSL证书
-- (仅测试)  (推荐)   (推荐)
-- 
-- 密码存储格式:
-- 
--   SHA-256 密码:
--   ┌────────────────────────────────────────────────────────────────────────┐
--   │ 用户输入密码: "MyPassword123!"                                         │
--   │                        ↓                                               │
--   │ SHA-256(password) → 存储在 ClickHouse                                  │
--   │ "a1b2c3d4e5..."                                                       │
--   └────────────────────────────────────────────────────────────────────────┘
--   
--   Double SHA-1 密码 (MySQL兼容):
--   ┌────────────────────────────────────────────────────────────────────────┐
--   │ 用户输入密码: "MyPassword123!"                                         │
--   │                        ↓                                               │
--   │ SHA1(SHA1(password)) → 存储在 ClickHouse                               │
--   │ 与 MySQL password() 函数兼容                                          │
--   └────────────────────────────────────────────────────────────────────────┘
-- 
-- LDAP 认证流程:
-- 
--   ┌──────────┐     ┌──────────┐     ┌──────────┐     ┌──────────┐
--   │ 用户请求 │────>│ClickHouse│────>│ LDAP     │────>│ 返回用户 │
--   │ 登录     │     │ 验证     │     │ 服务器   │     │ 信息     │
--   └──────────┘     └──────────┘     └──────────┘     └──────────┘
--                         │
--                         ▼
--                  ┌──────────┐
--                  │ 创建会话 │
--                  │ 分配角色 │
--                  └──────────┘
-- 
-- ================================================================================

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
