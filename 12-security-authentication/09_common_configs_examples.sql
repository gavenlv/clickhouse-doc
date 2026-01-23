-- ================================================
-- 09_common_configs_examples.sql
-- 从 09_common_configs.md 提取的 SQL 示例
-- 提取时间: 2026-01-23 14:40:17
-- ================================================


-- ========================================
-- SQL Block 1
-- ========================================

-- 创建管理员用户
CREATE USER IF NOT EXISTS admin
IDENTIFIED WITH sha256_password BY 'Admin@SecurePassword123!'
SETTINGS access_management = 1;

-- 创建只读用户
CREATE ROLE IF NOT EXISTS readonly_role;
GRANT SELECT ON *.* TO readonly_role;

CREATE USER IF NOT EXISTS readonly_user
IDENTIFIED WITH sha256_password BY 'ReadOnly@Password123!'
DEFAULT ROLE readonly_role
HOST IP '192.168.0.0/16';

-- ========================================
-- SQL Block 2
-- ========================================

-- 1. 创建角色
CREATE ROLE IF NOT EXISTS admin_role;
CREATE ROLE IF NOT EXISTS readonly_role;
CREATE ROLE IF NOT EXISTS writer_role;
CREATE ROLE IF NOT EXISTS analyst_role;

-- 2. 分配权限
GRANT ALL ON *.* TO admin_role;

GRANT SELECT ON *.* TO readonly_role;

GRANT SELECT, INSERT ON *.* TO writer_role;

GRANT SELECT, ALTER UPDATE, ALTER DELETE ON *.* TO analyst_role;

-- 3. 创建用户
CREATE USER IF NOT EXISTS admin
IDENTIFIED WITH sha256_password BY 'Admin@SecurePassword123!'
DEFAULT ROLE admin_role
SETTINGS access_management = 1;

CREATE USER IF NOT EXISTS readonly_user
IDENTIFIED WITH sha256_password BY 'ReadOnly@Password123!'
DEFAULT ROLE readonly_role;

CREATE USER IF NOT EXISTS writer_user
IDENTIFIED WITH sha256_password BY 'Writer@Password123!'
DEFAULT ROLE writer_role;

CREATE USER IF NOT EXISTS analyst_user
IDENTIFIED WITH sha256_password BY 'Analyst@Password123!'
DEFAULT ROLE analyst_role;

-- ========================================
-- SQL Block 3
-- ========================================

-- 创建 LDAP 用户
CREATE USER IF NOT EXISTS ldap_analyst
IDENTIFIED WITH ldap_server 'company_ldap';

-- 分配角色
CREATE ROLE IF NOT EXISTS analyst_role;
GRANT SELECT ON *.* TO analyst_role;
GRANT analyst_role TO ldap_analyst;

-- ========================================
-- SQL Block 4
-- ========================================

-- 1. 创建角色（细粒度权限）
CREATE ROLE IF NOT EXISTS admin_role;
CREATE ROLE IF NOT EXISTS readonly_role;
CREATE ROLE IF NOT EXISTS writer_role;
CREATE ROLE IF NOT EXISTS analyst_role;
CREATE ROLE IF NOT EXISTS security_admin_role;
CREATE ROLE IF NOT EXISTS audit_role;

-- 2. 分配权限
GRANT ALL ON *.* TO admin_role;

GRANT SELECT ON analytics.*, sales.*, marketing.* TO readonly_role;
GRANT SELECT ON system.* TO readonly_role;

GRANT SELECT, INSERT ON analytics.*, sales.*, marketing.* TO writer_role;

GRANT SELECT, ALTER UPDATE, ALTER DELETE ON analytics.*, sales.*, marketing.* TO analyst_role;

GRANT SELECT ON system.query_log TO audit_role;
GRANT SELECT ON system.error_log TO audit_role;
GRANT SELECT ON system.mutation_log TO audit_role;
GRANT SELECT ON security.* TO audit_role;

-- 3. 创建用户（限制资源）
CREATE USER IF NOT EXISTS admin
IDENTIFIED WITH sha256_password BY 'Admin@SecurePassword123!'
DEFAULT ROLE admin_role
SETTINGS access_management = 1;

CREATE USER IF NOT EXISTS readonly_user
IDENTIFIED WITH sha256_password BY 'ReadOnly@Password123!'
DEFAULT ROLE readonly_role
SETTINGS
    max_memory_usage = 10000000000,
    max_execution_time = 600;

CREATE USER IF NOT EXISTS analyst_user
IDENTIFIED WITH sha256_password BY 'Analyst@Password123!'
DEFAULT ROLE analyst_role
SETTINGS
    max_memory_usage = 20000000000,
    max_execution_time = 1800;

CREATE USER IF NOT EXISTS audit_user
IDENTIFIED WITH sha256_password BY 'Audit@Password123!'
DEFAULT ROLE audit_role
SETTINGS
    max_memory_usage = 5000000000,
    max_execution_time = 300;

-- 4. 创建审计告警
CREATE TABLE IF NOT EXISTS security.alerts
(
    alert_id UUID,
    alert_type String,
    alert_level Enum8('info' = 1, 'warning' = 2, 'error' = 3, 'critical' = 4),
    message String,
    details String,
    alert_time DateTime,
    resolved UInt8 DEFAULT 0
)
ENGINE = MergeTree()
PARTITION BY toYYYYMM(alert_time)
ORDER BY (alert_id, alert_time);

-- 5. 创建安全事件监控视图
CREATE MATERIALIZED VIEW IF NOT EXISTS security.security_alerts_mv
TO security.alerts
AS SELECT
    generateUUIDv4() as alert_id,
    'access_denied' as alert_type,
    'critical'::Enum8('info' = 1, 'warning' = 2, 'error' = 3, 'critical' = 4) as alert_level,
    format('Access denied: user={}, query={}', user, substring(query, 1, 100)) as message,
    format('user={}, query={}, exception={}', user, query, exception_text) as details,
    event_time as alert_time
FROM system.query_log
WHERE exception_code = 516
  AND event_time >= now() - INTERVAL 5 MINUTE;

-- ========================================
-- SQL Block 5
-- ========================================

-- 1. 创建租户表
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

-- 2. 创建租户用户
CREATE USER IF NOT EXISTS tenant1
IDENTIFIED WITH sha256_password BY 'Tenant1@Password123!'
SETTINGS tenant_id = 'tenant1';

CREATE USER IF NOT EXISTS tenant2
IDENTIFIED WITH sha256_password BY 'Tenant2@Password123!'
SETTINGS tenant_id = 'tenant2';

CREATE USER IF NOT EXISTS tenant3
IDENTIFIED WITH sha256_password BY 'Tenant3@Password123!'
SETTINGS tenant_id = 'tenant3';

-- 3. 创建租户角色
CREATE ROLE IF NOT EXISTS tenant_role;
GRANT SELECT, INSERT ON multi_tenant.* TO tenant_role;

GRANT tenant_role TO tenant1;
GRANT tenant_role TO tenant2;
GRANT tenant_role TO tenant3;

-- 4. 创建行级安全策略
CREATE ROW POLICY IF NOT EXISTS tenant_filter
ON multi_tenant.orders
USING tenant_id = current_user_settings['tenant_id']
AS RESTRICTIVE TO tenant1, tenant2, tenant3;

-- 5. 创建租户监控视图
CREATE VIEW IF NOT EXISTS multi_tenant.tenant_stats AS
SELECT 
    tenant_id,
    count() as order_count,
    sum(amount) as total_amount,
    avg(amount) as avg_amount,
    toYYYYMM(created_at) as month
FROM multi_tenant.orders
GROUP BY tenant_id, month
ORDER BY month DESC;

-- ========================================
-- SQL Block 6
-- ========================================

-- 1. 创建资源受限的角色
CREATE ROLE IF NOT EXISTS small_tenant_role
GRANT SELECT, INSERT ON multi_tenant.* TO small_tenant_role
SETTINGS
    max_memory_usage = 5000000000,      -- 5 GB
    max_execution_time = 600,          -- 10 分钟
    max_concurrent_queries_for_user = 3;

CREATE ROLE IF NOT EXISTS medium_tenant_role
GRANT SELECT, INSERT ON multi_tenant.* TO medium_tenant_role
SETTINGS
    max_memory_usage = 10000000000,     -- 10 GB
    max_execution_time = 1800,         -- 30 分钟
    max_concurrent_queries_for_user = 5;

CREATE ROLE IF NOT EXISTS large_tenant_role
GRANT SELECT, INSERT ON multi_tenant.* TO large_tenant_role
SETTINGS
    max_memory_usage = 20000000000,     -- 20 GB
    max_execution_time = 3600,         -- 60 分钟
    max_concurrent_queries_for_user = 10;

-- 2. 为租户分配不同的角色
CREATE USER IF NOT EXISTS small_tenant
IDENTIFIED WITH sha256_password BY 'SmallTenant@Password123!'
SETTINGS tenant_id = 'small_tenant'
DEFAULT ROLE small_tenant_role;

CREATE USER IF NOT EXISTS medium_tenant
IDENTIFIED WITH sha256_password BY 'MediumTenant@Password123!'
SETTINGS tenant_id = 'medium_tenant'
DEFAULT ROLE medium_tenant_role;

CREATE USER IF NOT EXISTS large_tenant
IDENTIFIED WITH sha256_password BY 'LargeTenant@Password123!'
SETTINGS tenant_id = 'large_tenant'
DEFAULT ROLE large_tenant_role;

-- 3. 创建资源监控视图
CREATE VIEW IF NOT EXISTS multi_tenant.resource_usage AS
SELECT 
    user,
    count() as query_count,
    sum(read_rows) as total_read_rows,
    sum(read_bytes) / 1024 / 1024 / 1024 as total_read_gb,
    sum(memory_usage) / 1024 / 1024 / 1024 as total_memory_gb,
    avg(query_duration_ms) as avg_duration_ms
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_time >= now() - INTERVAL 1 DAY
GROUP BY user
ORDER BY total_memory_gb DESC;

-- ========================================
-- SQL Block 7
-- ========================================

-- 1. 创建数据访问日志表
CREATE TABLE IF NOT EXISTS compliance.data_access_log
ON CLUSTER 'treasurycluster'
(
    access_id UUID,
    user_id String,
    accessed_user_id String,
    access_type Enum8('read' = 1, 'write' = 2, 'delete' = 3),
    table_name String,
    columns_accessed Array(String),
    access_time DateTime,
    ip_address IPv6,
    purpose String
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/data_access_log', '{replica}')
PARTITION BY toYYYYMM(access_time)
ORDER BY (access_id, access_time);

-- 2. 创建 PII 数据表
CREATE TABLE IF NOT EXISTS compliance.user_pii
ON CLUSTER 'treasurycluster'
(
    user_id String,
    encrypted_name String,  -- 加密
    encrypted_email String,  -- 加密
    encrypted_phone String,  -- 加密
    encrypted_address String,  -- 加密
    consent_timestamp DateTime,  -- 同意时间
    data_retention_date DateTime,  -- 保留期限
    deletion_requested UInt8 DEFAULT 0  -- 是否请求删除
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/user_pii', '{replica}')
PARTITION BY toYYYYMM(consent_timestamp)
ORDER BY (user_id, consent_timestamp);

-- 3. 创建数据删除请求视图
CREATE VIEW IF NOT EXISTS compliance.deletion_requests AS
SELECT 
    user_id,
    encrypted_name,
    encrypted_email,
    deletion_requested,
    data_retention_date,
    now() as request_time
FROM compliance.user_pii
WHERE deletion_requested = 1;

-- 4. 创建访问监控视图
CREATE MATERIALIZED VIEW IF NOT EXISTS compliance.access_monitor_mv
TO compliance.data_access_log
AS SELECT
    generateUUIDv4() as access_id,
    user,
    '' as accessed_user_id,
    if(contains(query, 'SELECT'), 'read', 
       if(contains(query, 'INSERT'), 'write', 'delete'))::Enum8('read' = 1, 'write' = 2, 'delete' = 3) as access_type,
    database,
    columns_accessed,
    event_time as access_time,
    address as ip_address,
    '' as purpose
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_time >= now() - INTERVAL 5 MINUTE;

-- ========================================
-- SQL Block 8
-- ========================================

-- 1. 创建 PHI 数据表
CREATE TABLE IF NOT EXISTS compliance.patient_phi
ON CLUSTER 'treasurycluster'
(
    patient_id String,
    encrypted_name String,
    encrypted_ssn String,
    encrypted_medical_record String,
    encrypted_diagnosis String,
    encrypted_treatment String,
    access_level Enum8('doctor' = 1, 'nurse' = 2, 'admin' = 3),
    created_at DateTime,
    last_accessed DateTime
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/patient_phi', '{replica}')
PARTITION BY toYYYYMM(created_at)
ORDER BY (patient_id, created_at);

-- 2. 创建 HIPAA 角色和权限
CREATE ROLE IF NOT EXISTS doctor_role;
GRANT SELECT ON compliance.patient_phi TO doctor_role;

CREATE ROW POLICY IF NOT EXISTS doctor_access_filter
ON compliance.patient_phi
USING access_level = 'doctor'
AS RESTRICTIVE TO doctor_role;

CREATE ROLE IF NOT EXISTS nurse_role;
GRANT SELECT(patient_id, encrypted_name, encrypted_diagnosis) ON compliance.patient_phi TO nurse_role;

CREATE ROW POLICY IF NOT EXISTS nurse_access_filter
ON compliance.patient_phi
USING access_level IN ('doctor', 'nurse')
AS RESTRICTIVE TO nurse_role;
