# 常见安全配置

本节提供了 ClickHouse 常见安全场景的配置示例，可以直接在生产环境中使用或根据需求进行调整。

## 📑 目录

- [基础安全配置](#基础安全配置)
- [企业级安全配置](#企业级安全配置)
- [高安全级别配置](#高安全级别配置)
- [多租户配置](#多租户配置)
- [合规性配置](#合规性配置)
- [DevSecOps 配置](#devsecops-配置)

## 基础安全配置

### 1. 最小安全配置

```xml
<!-- config.xml -->
<clickhouse>
    <!-- 1. 启用访问控制 -->
    <access_control_path>/var/lib/clickhouse/access/</access_control_path>
    
    <!-- 2. IP 白名单 -->
    <ip_filter>
        <ip>::1</ip>
        <ip>127.0.0.1</ip>
        <ip>192.168.0.0/16</ip>
    </ip_filter>
    
    <!-- 3. 启用审计日志 -->
    <query_log>
        <database>system</database>
        <table>query_log</table>
        <partition_by>toYYYYMM(event_date)</partition_by>
        <ttl>event_date + INTERVAL 30 DAY DELETE</ttl>
        <type>1,2,4</type>
    </query_log>
</clickhouse>
```

```sql
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
```

### 2. Docker 基础安全配置

```yaml
# docker-compose.yml
version: '3.8'

services:
  clickhouse1:
    image: clickhouse/clickhouse-server:latest
    container_name: clickhouse-server-1
    hostname: clickhouse1
    networks:
      - clickhouse_net
    ports:
      - "8123:8123"
      - "9000:9000"
    volumes:
      - ./data/clickhouse1:/var/lib/clickhouse
      - ./config/users_secure.xml:/etc/clickhouse-server/users.d/users_secure.xml:ro
    ulimits:
      nofile:
        soft: 262144
        hard: 262144

networks:
  clickhouse_net:
    driver: bridge
    internal: true
```

```xml
<!-- config/users_secure.xml -->
<?xml version="1.0"?>
<clickhouse>
    <users>
        <!-- 删除默认用户 -->
        <default remove="remove"/>
        
        <!-- 创建管理员用户 -->
        <admin>
            <password_sha256_hex>8d969eef6ecad3c29a3a629280e686cf0c3f5d5a86aff3ca12020c923adc6c92</password_sha256_hex>
            <access_management>1</access_management>
            <networks>
                <ip>::1</ip>
                <ip>127.0.0.1</ip>
            </networks>
            <profile>default</profile>
            <quota>default</quota>
        </admin>
        
        <!-- 创建只读用户 -->
        <readonly>
            <password_sha256_hex>5e884898da28047151d0e56f8dc6292773603d0d6aabbdd62a11ef721d1542d8</password_sha256_hex>
            <networks>
                <ip>172.18.0.0/16</ip>
            </networks>
            <profile>readonly</profile>
            <quota>default</quota>
        </readonly>
    </users>
</clickhouse>
```

## 企业级安全配置

### 1. 完整企业级配置

```xml
<!-- config.xml -->
<clickhouse>
    <!-- 访问控制 -->
    <access_control_path>/var/lib/clickhouse/access/</access_control_path>
    
    <!-- IP 过滤 -->
    <ip_filter>
        <ip>::1</ip>
        <ip>127.0.0.1</ip>
        <ip>10.0.0.0/8</ip>
        <ip>192.168.0.0/16</ip>
    </ip_filter>
    
    <!-- SSL/TLS 配置 -->
    <openSSL>
        <server>
            <certificateFile>/etc/clickhouse-server/certs/server.crt</certificateFile>
            <privateKeyFile>/etc/clickhouse-server/certs/server.key</privateKeyFile>
            <caFile>/etc/clickhouse-server/certs/ca.crt</caFile>
            <verificationMode>strict</verificationMode>
            <loadDefaultCAFile>false</loadDefaultCAFile>
            <cacheSessions>true</cacheSessions>
            <sessionCacheSize>1024</sessionCacheSize>
            <sessionTimeout>86400</sessionTimeout>
            <protocols>tlsv1.2, tlsv1.3</protocols>
        </server>
        <client>
            <caFile>/etc/clickhouse-server/certs/ca.crt</caFile>
            <verificationMode>strict</verificationMode>
            <loadDefaultCAFile>false</loadDefaultCAFile>
            <cacheSessions>true</cacheSessions>
            <sessionCacheSize>1024</sessionCacheSize>
            <sessionTimeout>86400</sessionTimeout>
        </client>
    </openSSL>
    
    <!-- 端口配置 -->
    <https_port>8443</https_port>
    <tcp_port_secure>9440</tcp_port_secure>
    <interserver_https_port>9009</interserver_https_port>
    
    <!-- 审计日志 -->
    <query_log>
        <database>system</database>
        <table>query_log</table>
        <partition_by>toYYYYMM(event_date)</partition_by>
        <ttl>event_date + INTERVAL 90 DAY DELETE</ttl>
        <type>1,2,4</type>
        <record_exception>1</record_exception>
        <record_failed_queries>1</record_failed_queries>
    </query_log>
    
    <query_thread_log>
        <database>system</database>
        <table>query_thread_log</table>
        <partition_by>toYYYYMM(event_date)</partition_by>
        <ttl>event_date + INTERVAL 90 DAY DELETE</ttl>
    </query_thread_log>
    
    <error_log>
        <database>system</database>
        <table>error_log</table>
        <partition_by>toYYYYMM(event_date)</partition_by>
        <ttl>event_date + INTERVAL 180 DAY DELETE</ttl>
    </error_log>
    
    <mutation_log>
        <database>system</database>
        <table>mutation_log</table>
        <partition_by>toYYYYMM(event_date)</partition_by>
        <ttl>event_date + INTERVAL 180 DAY DELETE</ttl>
    </mutation_log>
</clickhouse>
```

```sql
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
```

### 2. 集成 LDAP 配置

```xml
<!-- config.xml -->
<ldap_servers>
    <company_ldap>
        <host>ldap.company.com</host>
        <port>636</port>
        <bind_dn>cn=clickhouse,cn=users,dc=company,dc=com</bind_dn>
        <bind_password>SecurePassword123!</bind_password>
        <verification_dn>cn=users,dc=company,dc=com</verification_dn>
        <enable_tls>yes</enable_tls>
        <tls_minimum_protocol>tlsv1.2</tls_minimum_protocol>
        <tls_require_cert>never</tls_require_cert>
        <search_base>cn=users,dc=company,dc=com</search_base>
        <search_filter>(&(sAMAccountName={user})(objectClass=user))</search_filter>
    </company_ldap>
</ldap_servers>
```

```sql
-- 创建 LDAP 用户
CREATE USER IF NOT EXISTS ldap_analyst
IDENTIFIED WITH ldap_server 'company_ldap';

-- 分配角色
CREATE ROLE IF NOT EXISTS analyst_role;
GRANT SELECT ON *.* TO analyst_role;
GRANT analyst_role TO ldap_analyst;
```

## 高安全级别配置

### 1. 高安全级别完整配置

```xml
<!-- config.xml -->
<clickhouse>
    <!-- 访问控制 -->
    <access_control_path>/var/lib/clickhouse/access/</access_control_path>
    
    <!-- IP 过滤 -->
    <ip_filter>
        <ip>::1</ip>
        <ip>127.0.0.1</ip>
        <ip>10.0.0.0/8</ip>
        <ip>192.168.0.0/16</ip>
    </ip_filter>
    
    <!-- SSL/TLS 配置 -->
    <openSSL>
        <server>
            <certificateFile>/etc/clickhouse-server/certs/server.crt</certificateFile>
            <privateKeyFile>/etc/clickhouse-server/certs/server.key</privateKeyFile>
            <caFile>/etc/clickhouse-server/certs/ca.crt</caFile>
            <verificationMode>strict</verificationMode>
            <loadDefaultCAFile>false</loadDefaultCAFile>
            <cacheSessions>true</cacheSessions>
            <sessionCacheSize>1024</sessionCacheSize>
            <sessionTimeout>86400</sessionTimeout>
            <protocols>tlsv1.2, tlsv1.3</protocols>
            <ciphers>ECDHE-RSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-GCM-SHA384</ciphers>
        </server>
        <client>
            <caFile>/etc/clickhouse-server/certs/ca.crt</caFile>
            <verificationMode>strict</verificationMode>
            <loadDefaultCAFile>false</loadDefaultCAFile>
            <cacheSessions>true</cacheSessions>
            <sessionCacheSize>1024</sessionCacheSize>
            <sessionTimeout>86400</sessionTimeout>
            <protocols>tlsv1.2, tlsv1.3</protocols>
        </client>
    </openSSL>
    
    <!-- 端口配置（禁用 HTTP，仅 HTTPS） -->
    <!-- <http_port>8123</http_port> -->
    <https_port>8443</https_port>
    <tcp_port_secure>9440</tcp_port_secure>
    <interserver_https_port>9009</interserver_https_port>
    
    <!-- 审计日志 -->
    <query_log>
        <database>system</database>
        <table>query_log</table>
        <partition_by>toYYYYMM(event_date)</partition_by>
        <ttl>event_date + INTERVAL 365 DAY DELETE</ttl>
        <type>1,2,4</type>
        <record_exception>1</record_exception>
        <record_failed_queries>1</record_failed_queries>
    </query_log>
    
    <query_thread_log>
        <database>system</database>
        <table>query_thread_log</table>
        <partition_by>toYYYYMM(event_date)</partition_by>
        <ttl>event_date + INTERVAL 365 DAY DELETE</ttl>
    </query_thread_log>
    
    <error_log>
        <database>system</database>
        <table>error_log</table>
        <partition_by>toYYYYMM(event_date)</partition_by>
        <ttl>event_date + INTERVAL 365 DAY DELETE</ttl>
    </error_log>
    
    <mutation_log>
        <database>system</database>
        <table>mutation_log</table>
        <partition_by>toYYYYMM(event_date)</partition_by>
        <ttl>event_date + INTERVAL 365 DAY DELETE</ttl>
    </mutation_log>
    
    <session_log>
        <database>system</database>
        <table>session_log</table>
        <partition_by>toYYYYMM(event_date)</partition_by>
        <ttl>event_date + INTERVAL 365 DAY DELETE</ttl>
    </session_log>
    
    <!-- 禁用不安全的特性 -->
    <allow_experimental_database_ordinary>0</allow_experimental_database_ordinary>
    <allow_experimental_server_side_cache>0</allow_experimental_server_side_cache>
</clickhouse>
```

```sql
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
```

## 多租户配置

### 1. 多租户数据隔离配置

```sql
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
```

### 2. 多租户资源隔离配置

```sql
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
```

## 合规性配置

### 1. GDPR 合规配置

```xml
<!-- config.xml -->
<clickhouse>
    <!-- 审计日志（保留 7 年） -->
    <query_log>
        <database>system</database>
        <table>query_log</table>
        <partition_by>toYYYYMM(event_date)</partition_by>
        <ttl>event_date + INTERVAL 7 YEAR DELETE</ttl>
        <type>1,2,4</type>
        <record_exception>1</record_exception>
        <record_failed_queries>1</record_failed_queries>
    </query_log>
    
    <!-- 数据访问日志 -->
    <query_log>
        <database>compliance</database>
        <table>data_access_log</table>
        <partition_by>toYYYYMM(event_date)</partition_by>
        <ttl>event_date + INTERVAL 7 YEAR DELETE</ttl>
    </query_log>
</clickhouse>
```

```sql
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
```

### 2. HIPAA 合规配置

```xml
<!-- config.xml -->
<clickhouse>
    <!-- 启用加密日志 -->
    <query_log>
        <database>system</database>
        <table>query_log</table>
        <partition_by>toYYYYMM(event_date)</partition_by>
        <ttl>event_date + INTERVAL 6 YEAR DELETE</ttl>
    </query_log>
    
    <!-- HIPAA 审计日志 -->
    <query_log>
        <database>compliance</database>
        <table>hipaa_audit_log</table>
        <partition_by>toYYYYMM(event_date)</partition_by>
        <ttl>event_date + INTERVAL 6 YEAR DELETE</ttl>
    </query_log>
</clickhouse>
```

```sql
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
```

## DevSecOps 配置

### 1. GitOps 安全配置

```yaml
# .github/workflows/clickhouse-security.yml
name: ClickHouse Security

on:
  push:
    branches: [ main ]
  pull_request:
    branches: [ main ]

jobs:
  security-scan:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v2
      
      - name: Security Configuration Check
        run: |
          chmod +x scripts/security_check.sh
          ./scripts/security_check.sh
      
      - name: SSL Certificate Validation
        run: |
          openssl x509 -in certs/server.crt -noout -text
          openssl x509 -in certs/ca.crt -noout -text
      
      - name: User Configuration Validation
        run: |
          clickhouse-local --queries-file scripts/validate_users.sql
```

```bash
#!/bin/bash
# scripts/security_check.sh

# 1. 检查 SSL 配置
if [ ! -f "config.d/ssl.xml" ]; then
    echo "ERROR: SSL configuration not found"
    exit 1
fi

# 2. 检查证书文件
for cert in server.crt server.key ca.crt; do
    if [ ! -f "certs/$cert" ]; then
        echo "ERROR: Certificate $cert not found"
        exit 1
    fi
done

# 3. 检查用户配置
if grep -q "<password>" config/users.xml; then
    echo "WARNING: Plaintext passwords detected"
fi

# 4. 检查审计日志配置
if ! grep -q "<query_log>" config.xml; then
    echo "ERROR: Audit logging not enabled"
    exit 1
fi

echo "Security check passed"
```

### 2. 基础设施即代码安全配置

```hcl
# Terraform main.tf
resource "aws_instance" "clickhouse" {
  ami           = "ami-0c55b159cbfafe1f0"
  instance_type = "m5.2xlarge"
  
  # 安全组
  vpc_security_group_ids = [aws_security_group.clickhouse_sg.id]
  
  # 根卷加密
  root_block_device {
    volume_type = "gp3"
    volume_size = 100
    encrypted   = true
    kms_key_id  = aws_kms_key.clickhouse_key.arn
  }
  
  # 用户数据
  user_data = file("cloud-init.yml")
  
  tags = {
    Name = "clickhouse-server"
    Environment = "production"
  }
}

resource "aws_security_group" "clickhouse_sg" {
  name        = "clickhouse-security-group"
  description = "ClickHouse security group"
  
  # VPC 互访
  ingress {
    from_port   = 9440
    to_port     = 9440
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]
  }
  
  # HTTPS
  ingress {
    from_port   = 8443
    to_port     = 8443
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]
  }
  
  # SSH（仅管理网络）
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["192.168.0.0/16"]
  }
}

resource "aws_kms_key" "clickhouse_key" {
  description = "ClickHouse encryption key"
  tags = {
    Name = "clickhouse-key"
  }
}
```

## 🎯 配置选择指南

| 场景 | 推荐配置 | 说明 |
|------|---------|------|
| **开发环境** | 基础安全配置 | 最小权限、简单认证 |
| **测试环境** | 基础安全配置 | 与生产环境类似 |
| **生产环境** | 企业级安全配置 | 完整的安全措施 |
| **高安全要求** | 高安全级别配置 | 严格的访问控制、加密 |
| **多租户** | 多租户配置 | 数据隔离、资源隔离 |
| **合规要求** | 合规性配置 | 满足 GDPR、HIPAA 等 |

## 📚 相关文档

- [用户认证](./01_authentication.md)
- [用户和角色管理](./02_user_role_management.md)
- [权限控制](./03_permissions.md)
- [网络安全](./05_network_security.md)
- [数据加密](./06_data_encryption.md)
- [审计日志](./07_audit_log.md)
- [安全最佳实践](./08_best_practices.md)
