# 用户认证

ClickHouse 支持多种用户认证方法，从简单的密码认证到企业级的 Kerberos 和 LDAP 认证。本节将详细介绍各种认证方法的配置和使用。

## 📑 目录

- [认证方法概览](#认证方法概览)
- [密码认证](#密码认证)
- [LDAP 认证](#ldap-认证)
- [Kerberos 认证](#kerberos-认证)
- [SSL 证书认证](#ssl-证书认证)
- [认证配置示例](#认证配置示例)

## 认证方法概览

ClickHouse 支持以下认证方法：

| 认证方法 | 描述 | 适用场景 | 安全级别 |
|---------|------|---------|---------|
| **plaintext_password** | 明文密码 | 本地开发测试 | ⭐ |
| **sha256_password** | SHA-256 哈希密码 | 生产环境推荐 | ⭐⭐⭐⭐ |
| **double_sha1_password** | 双 SHA-1 哈希 | MySQL 兼容 | ⭐⭐ |
| **ldap** | LDAP 目录服务 | 企业环境 | ⭐⭐⭐⭐ |
| **kerberos** | Kerberos 协议 | Kerberos 环境 | ⭐⭐⭐⭐ |
| **ssl_certificate** | TLS 客户端证书 | 高安全要求 | ⭐⭐⭐⭐⭐ |
| **no_password** | 无密码（仅限受信任网络） | 内部服务 | ⭐⭐ |

## 密码认证

### SHA-256 密码（推荐）

SHA-256 密码是 ClickHouse 推荐使用的密码认证方法，提供了良好的安全性和性能平衡。

#### 创建 SHA-256 密码用户

```sql
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
```

#### 生成 SHA-256 哈希

```bash
# 使用 clickhouse-local 生成 SHA-256 哈希
echo -n 'SecurePassword123!' | clickhouse-local --query 'SELECT hex(SHA256(toString(readContent())))'

# 或使用 OpenSSL
echo -n 'SecurePassword123!' | openssl dgst -sha256 -binary | xxd -p -c 32
```

#### 配置文件中的 SHA-256 用户

```xml
<!-- users.xml -->
<users>
    <admin_user>
        <password_sha256_hex>8d969eef6ecad3c29a3a629280e686cf0c3f5d5a86aff3ca12020c923adc6c92</password_sha256_hex>
        <access_management>1</access_management>
        <networks>
            <ip>::1</ip>
            <ip>192.168.0.0/16</ip>
        </networks>
        <profile>default</profile>
        <quota>default</quota>
    </admin_user>
</users>
```

### Double SHA-1 密码

Double SHA-1 与 MySQL 的密码哈希兼容，便于从 MySQL 迁移。

```sql
-- 创建使用 Double SHA-1 密码的用户
CREATE USER IF NOT EXISTS mysql_compatible_user
IDENTIFIED WITH double_sha1_password BY 'MySQLPassword123!';
```

### 明文密码（不推荐）

明文密码仅用于开发测试环境，不应在生产环境中使用。

```sql
-- 创建使用明文密码的用户（仅用于测试）
CREATE USER IF NOT EXISTS test_user
IDENTIFIED WITH plaintext_password BY 'TestPassword123!';

-- 或者在 users.xml 中
<test_user>
    <password>TestPassword123!</password>
</test_user>
```

## LDAP 认证

LDAP 认证允许 ClickHouse 集成企业 LDAP 目录服务，如 Active Directory 或 OpenLDAP。

### 配置 LDAP 认证

#### 1. 配置 LDAP 服务器

```xml
<!-- config.xml -->
<ldap_servers>
    <my_ldap_server>
        <host>ldap.company.com</host>
        <port>389</port>
        <bind_dn>cn=clickhouse,cn=users,dc=company,dc=com</bind_dn>
        <bind_password>SecurePassword123!</bind_password>
        <verification_dn>cn=users,dc=company,dc=com</verification_dn>
        <enable_tls>no</enable_tls>
        <tls_minimum_protocol>tlsv1.2</tls_minimum_protocol>
        <tls_require_cert>never</tls_require_cert>
        <search_base>cn=users,dc=company,dc=com</search_base>
        <search_filter>(&(sAMAccountName={user})(objectClass=user))</search_filter>
    </my_ldap_server>
</ldap_servers>
```

#### 2. 创建 LDAP 认证用户

```sql
-- 创建 LDAP 认证的用户
CREATE USER IF NOT EXISTS ldap_user
IDENTIFIED WITH ldap_server 'my_ldap_server'
SERVER my_ldap_server;

-- 为 LDAP 用户分配角色
CREATE ROLE IF NOT EXISTS ldap_role;
GRANT SELECT ON *.* TO ldap_role;
GRANT ldap_role TO ldap_user;
```

#### 3. 测试 LDAP 认证

```bash
# 使用 LDAP 用户连接
clickhouse-client --user ldap_user --password 'LDAPPassword123!' --host clickhouse1
```

### LDAP 认证配置选项

| 参数 | 说明 | 默认值 |
|------|------|--------|
| `host` | LDAP 服务器地址 | - |
| `port` | LDAP 服务器端口 | 389 |
| `bind_dn` | 绑定 DN | - |
| `bind_password` | 绑定密码 | - |
| `verification_dn` | 验证 DN | - |
| `enable_tls` | 是否启用 TLS | no |
| `tls_minimum_protocol` | TLS 最低版本 | tlsv1.2 |
| `search_base` | 搜索基础 DN | - |
| `search_filter` | 搜索过滤器 | - |

## Kerberos 认证

Kerberos 认证提供了强大的网络认证服务，适用于企业级环境。

### 配置 Kerberos 认证

#### 1. 配置 ClickHouse 使用 Kerberos

```xml
<!-- config.xml -->
<kerberos>
    <principal>clickhouse/host.company.com@COMPANY.COM</principal>
    <keytab>/etc/clickhouse-server/clickhouse.keytab</keytab>
</kerberos>
```

#### 2. 创建 Kerberos 认证用户

```sql
-- 创建 Kerberos 认证的用户
CREATE USER IF NOT EXISTS kerberos_user
IDENTIFIED WITH kerberos
SERVER kerberos;

-- 为 Kerberos 用户分配角色
CREATE ROLE IF NOT EXISTS kerberos_role;
GRANT SELECT ON *.* TO kerberos_role;
GRANT kerberos_role TO kerberos_user;
```

#### 3. 配置 Kerberos 服务器

```xml
<!-- config.xml -->
<kerberos_servers>
    <my_kdc>
        <realm>COMPANY.COM</realm>
        <host>kdc1.company.com</host>
        <port>88</port>
    </my_kdc>
</kerberos_servers>
```

#### 4. 测试 Kerberos 认证

```bash
# 获取 Kerberos 票据
kinit user@COMPANY.COM

# 使用 Kerberos 认证连接
clickhouse-client --user kerberos_user --kerberos
```

## SSL 证书认证

SSL 证书认证提供了最高级别的安全性，适用于高安全要求的环境。

### 配置 SSL 证书认证

#### 1. 配置 ClickHouse 服务器 SSL

```xml
<!-- config.xml -->
<openSSL>
    <server>
        <certificateFile>/etc/clickhouse-server/certs/server.crt</certificateFile>
        <privateKeyFile>/etc/clickhouse-server/certs/server.key</privateKeyFile>
        <caFile>/etc/clickhouse-server/certs/ca.crt</caFile>
        <verificationMode>require</verificationMode>
        <loadDefaultCAFile>false</loadDefaultCAFile>
        <cacheSessions>true</cacheSessions>
        <sessionCacheSize>1024</sessionCacheSize>
        <sessionTimeout>86400</sessionTimeout>
    </server>
</openSSL>
```

#### 2. 配置客户端 SSL 认证

```xml
<!-- config.xml -->
<openSSL>
    <client>
        <loadDefaultCAFile>false</loadDefaultCAFile>
        <caFile>/etc/clickhouse-server/certs/ca.crt</caFile>
        <cacheSessions>true</cacheSessions>
        <sessionCacheSize>1024</sessionCacheSize>
        <sessionTimeout>86400</sessionTimeout>
        <invalidCertificateHandler>
            <name>RejectCertificateHandler</name>
        </invalidCertificateHandler>
    </client>
</openSSL>
```

#### 3. 创建 SSL 证书认证用户

```sql
-- 创建使用 SSL 证书认证的用户
CREATE USER IF NOT EXISTS cert_user
IDENTIFIED WITH ssl_certificate CN 'user1'
SERVER 'clickhouse1';

-- 为证书用户分配角色
CREATE ROLE IF NOT EXISTS cert_role;
GRANT SELECT, INSERT ON *.* TO cert_role;
GRANT cert_role TO cert_user;
```

#### 4. 生成客户端证书

```bash
# 生成客户端私钥
openssl genrsa -out client.key 2048

# 生成证书签名请求
openssl req -new -key client.key -out client.csr -subj "/CN=user1"

# 使用 CA 签名证书
openssl x509 -req -in client.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out client.crt -days 365
```

#### 5. 使用 SSL 证书连接

```bash
# 使用 SSL 证书连接
clickhouse-client \
    --user cert_user \
    --port 9440 \
    --ssl \
    --ssl-ca-file /etc/clickhouse-server/certs/ca.crt \
    --ssl-cert-file /etc/clickhouse-server/certs/client.crt \
    --ssl-key-file /etc/clickhouse-server/certs/client.key
```

## 认证配置示例

### 完整的认证配置示例

```xml
<!-- config.xml -->
<clickhouse>
    <!-- LDAP 服务器配置 -->
    <ldap_servers>
        <company_ldap>
            <host>ldap.company.com</host>
            <port>389</port>
            <bind_dn>cn=clickhouse,cn=users,dc=company,dc=com</bind_dn>
            <bind_password>SecurePassword123!</bind_password>
            <search_base>cn=users,dc=company,dc=com</search_base>
            <search_filter>(&(sAMAccountName={user})(objectClass=user))</search_filter>
        </company_ldap>
    </ldap_servers>

    <!-- Kerberos 配置 -->
    <kerberos>
        <principal>clickhouse/clickhouse1.company.com@COMPANY.COM</principal>
        <keytab>/etc/clickhouse-server/clickhouse.keytab</keytab>
    </kerberos>

    <!-- SSL 配置 -->
    <openSSL>
        <server>
            <certificateFile>/etc/clickhouse-server/certs/server.crt</certificateFile>
            <privateKeyFile>/etc/clickhouse-server/certs/server.key</privateKeyFile>
            <caFile>/etc/clickhouse-server/certs/ca.crt</caFile>
            <verificationMode>require</verificationMode>
        </server>
        <client>
            <loadDefaultCAFile>false</loadDefaultCAFile>
            <caFile>/etc/clickhouse-server/certs/ca.crt</caFile>
        </client>
    </openSSL>

    <!-- IP 过滤 -->
    <ip_filter>
        <ip>::1</ip>
        <ip>192.168.0.0/16</ip>
    </ip_filter>
</clickhouse>
```

### 多种认证方法示例

```sql
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
```

## 🎯 认证方法选择指南

| 场景 | 推荐认证方法 | 原因 |
|------|-------------|------|
| **生产环境** | SHA-256 密码 | 安全性好，配置简单 |
| **企业环境** | LDAP | 与企业目录服务集成 |
| **Kerberos 环境** | Kerberos | 与现有 Kerberos 基础设施集成 |
| **高安全要求** | SSL 证书 | 最高级别的安全性 |
| **MySQL 迁移** | Double SHA-1 | 兼容 MySQL 密码 |
| **开发测试** | 明文密码 | 简单快捷 |

## ⚠️ 安全注意事项

1. **使用强密码**：密码长度至少 12 个字符，包含大小写字母、数字和特殊字符
2. **定期更换密码**：每 90 天更换一次密码
3. **启用 SSL/TLS**：始终使用加密连接
4. **限制网络访问**：配置 IP 白名单
5. **移除默认用户**：删除或修改默认的 default 用户
6. **最小权限原则**：只授予必要的权限
7. **定期审查**：定期审查用户权限和活动
8. **监控异常**：监控异常登录行为

## 📚 相关文档

- [用户和角色管理](./02_user_role_management.md)
- [权限控制](./03_permissions.md)
- [网络安全](./05_network_security.md)
- [安全最佳实践](./08_best_practices.md)
