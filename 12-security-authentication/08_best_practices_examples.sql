-- 创建数据库（如果存在则不创建）
CREATE DATABASE IF NOT EXISTS compliance;
CREATE DATABASE IF NOT EXISTS multi_tenant;


CREATE USER IF NOT EXISTS admin
IDENTIFIED WITH sha256_password BY 'Admin@SecurePassword123!'
-- REMOVED SET access_management (not supported) 1;

-- 定期更换密码（每 90 天）
ALTER USER admin IDENTIFIED WITH sha256_password BY 'NewAdmin@Password123!';

-- ========================================
-- 1. 使用强密码
-- ========================================

-- ✅ 推荐：使用 SHA-256 密码
CREATE USER IF NOT EXISTS user1
IDENTIFIED WITH sha256_password BY 'SecurePassword123!';

-- ❌ 避免：使用明文密码（仅用于测试）
CREATE USER IF NOT EXISTS test_user
IDENTIFIED WITH plaintext_password BY 'TestPassword123!';

-- ========================================
-- 1. 使用强密码
-- ========================================

-- 集成 LDAP 进行身份认证
-- LDAP AUTHENTICATION (skipped - not configured)


CREATE ROLE IF NOT EXISTS ldap_role;
GRANT SELECT ON *.* TO ldap_role;
-- GRANT TO ldap_user (skipped - user does not exist)

-- ========================================
-- 1. 使用强密码
-- ========================================

-- 创建用户并限制 IP 访问
CREATE USER IF NOT EXISTS internal_user
IDENTIFIED WITH sha256_password BY 'InternalPassword123!'
HOST IP '192.168.0.0/16', '10.0.0.0/8'
HOST LOCAL;

-- ========================================
-- 1. 使用强密码
-- ========================================

-- ❌ 删除或修改默认的 default 用户
DROP USER IF EXISTS default;

-- 或修改默认用户密码
ALTER USER default IDENTIFIED WITH sha256_password BY 'NewSecurePassword123!';

-- ========================================
-- 1. 使用强密码
-- ========================================

-- ✅ 推荐：使用角色管理权限
CREATE ROLE IF NOT EXISTS readonly_role;
GRANT SELECT ON *.* TO readonly_role;

CREATE USER IF NOT EXISTS alice
IDENTIFIED WITH sha256_password BY 'AlicePassword123!'
DEFAULT ROLE readonly_role;

-- ❌ 避免：直接为用户分配权限
CREATE USER IF NOT EXISTS bob
IDENTIFIED WITH sha256_password BY 'BobPassword123!';
GRANT SELECT ON *.* TO bob;

-- ========================================
-- 1. 使用强密码
-- ========================================

-- 只授予必要的最小权限
CREATE ROLE IF NOT EXISTS data_analyst;
GRANT SELECT ON analytics.* TO data_analyst;
GRANT SELECT ON sales.* TO data_analyst;
-- 不授予 INSERT、UPDATE、DELETE 等权限

-- ========================================
-- 1. 使用强密码
-- ========================================

-- 创建行级安全策略
CREATE ROW POLICY IF NOT EXISTS user_data_filter
ON analytics.user_events
USING user_id = current_user()
AS RESTRICTIVE TO readonly_user;

-- ========================================
-- 1. 使用强密码
-- ========================================

-- 只授予非敏感列的访问权限
GRANT 
    SELECT(user_id, username, email) 
ON analytics.users 
TO public_analyst;

-- 撤销敏感列的访问权限
REVOKE 
    SELECT(password, token, ssn) 
ON analytics.users 
FROM public_analyst;

-- ========================================
-- 1. 使用强密码
-- ========================================

-- 定期审查用户权限
SELECT 
    user,
    count() as permission_count,
    groupUniqArray(distinct table) as tables
FROM system.grants
WHERE user IS NOT NULL
GROUP BY user
ORDER BY permission_count DESC;

-- ========================================
-- 1. 使用强密码
-- ========================================

-- 使用应用层加密
DROP TABLE IF EXISTS secure.encrypted_users;
CREATE TABLE IF NOT EXISTS secure.encrypted_users
(
    user_id UInt64,
    username String,
    encrypted_email String,  -- 应用层加密
    encrypted_phone String,  -- 应用层加密
    created_at DateTime
)
ENGINE = MergeTree()
PARTITION BY toYYYYMM(created_at)
ORDER BY (user_id, created_at);

-- ========================================
-- 1. 使用强密码
-- ========================================

-- 查看异常访问
SELECT 
    user,
    count() as failed_attempts
FROM system.query_log
WHERE exception_code = 516  -- ACCESS_DENIED
  AND event_time >= now() - INTERVAL 1 DAY
GROUP BY user
HAVING failed_attempts > 10
ORDER BY failed_attempts DESC;

-- ========================================
-- 1. 使用强密码
-- ========================================

-- 慢查询告警
CREATE MATERIALIZED VIEW security.slow_query_alerts_mv
TO security.alerts
AS SELECT
    generateUUIDv4() as alert_id,
    'slow_query' as alert_type,
    'warning'::Enum8('info' = 1, 'warning' = 2, 'error' = 3, 'critical' = 4) as alert_level,
    format('Slow query: user={}, duration={}ms', user, query_duration_ms) as message,
    event_time as alert_time
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query_duration_ms > 10000;

-- ========================================
-- 1. 使用强密码
-- ========================================

-- 每周安全报告
SELECT 
    'Security Report' as report_type,
    format('Week: {} to {}', 
           toMonday(now() - INTERVAL 1 WEEK), 
           now()) as period,
    '' as line
UNION ALL
SELECT 
    format('Total queries: {}', count()) as report_type,
    '' as period,
    '' as line
FROM system.query_log
WHERE event_time >= now() - INTERVAL 1 WEEK
UNION ALL
SELECT 
    format('Failed queries: {}', count()) as report_type,
    '' as period,
    '' as line
FROM system.query_log
WHERE type = 'Exception'
  AND event_time >= now() - INTERVAL 1 WEEK;

-- ========================================
-- 1. 使用强密码
-- ========================================

-- 创建租户表
DROP TABLE IF EXISTS multi_tenant.orders;
CREATE TABLE IF NOT EXISTS multi_tenant.orders
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
ORDER BY (tenant_id, created_at);

-- 创建租户用户
CREATE USER IF NOT EXISTS tenant1
IDENTIFIED WITH sha256_password BY 'Tenant1Password123!'
SETTINGS tenant_id = 'tenant1';

-- 创建行级安全策略
CREATE ROW POLICY IF NOT EXISTS tenant_filter
ON multi_tenant.orders
USING tenant_id = current_user_settings['tenant_id']
AS RESTRICTIVE TO tenant1;

-- ========================================
-- 1. 使用强密码
-- ========================================

-- 配置审计日志
<query_log>
    <database>system</database>
    <table>query_log</table>
    <partition_by>toYYYYMM(event_date)</partition_by>
    <ttl>event_date + INTERVAL 365 DAY DELETE</ttl>
</query_log>

-- 创建审计报告
CREATE VIEW IF NOT EXISTS compliance.audit_report AS
SELECT 
    user,
    count() as query_count,
    countIf(type = 'Exception') as error_count,
    avg(query_duration_ms) as avg_duration_ms
FROM system.query_log
WHERE event_time >= now() - INTERVAL 30 DAY
GROUP BY user;
