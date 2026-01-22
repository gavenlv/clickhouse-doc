# 安全最佳实践

本节总结了 ClickHouse 安全的最佳实践，包括安全设计原则、实施指南和常见场景的安全解决方案。

## 📑 目录

- [安全设计原则](#安全设计原则)
- [身份认证最佳实践](#身份认证最佳实践)
- [访问控制最佳实践](#访问控制最佳实践)
- [网络安全最佳实践](#网络安全最佳实践)
- [数据保护最佳实践](#数据保护最佳实践)
- [监控和审计最佳实践](#监控和审计最佳实践)
- [运维安全最佳实践](#运维安全最佳实践)
- [常见安全场景](#常见安全场景)

## 安全设计原则

### 核心安全原则

| 原则 | 说明 | 实施方法 |
|------|------|---------|
| **最小权限原则** | 只授予必要的最小权限 | 使用角色、限制权限范围 |
| **纵深防御** | 多层安全防护 | 网络、应用、数据、审计 |
| **防御深度** | 避免单点故障 | 多个安全控制点 |
| **职责分离** | 分离不同职责 | 不同角色、审批流程 |
| **审计追踪** | 记录所有关键操作 | 启用审计日志 |
| **定期审查** | 定期审查安全配置 | 权限审查、安全扫描 |
| **及时更新** | 及时更新系统和补丁 | 定期升级 ClickHouse |
| **应急响应** | 制定应急响应计划 | 安全事件响应流程 |

### 安全分层

```
第 1 层：网络安全
├── 防火墙规则
├── IP 白名单
├── VPC 网络隔离
└── SSL/TLS 加密

第 2 层：身份认证
├── 强密码策略
├── 多因素认证
├── LDAP/Kerberos 集成
└── 证书认证

第 3 层：访问控制
├── RBAC 角色管理
├── 权限限制
├── 行级安全
└── 列级权限

第 4 层：数据保护
├── 数据加密
├── 脱敏处理
├── 备份加密
└── 密钥管理

第 5 层：监控审计
├── 审计日志
├── 告警规则
├── 异常检测
└── 安全分析
```

## 身份认证最佳实践

### 1. 使用强密码

```sql
-- 创建用户时使用强密码（至少 12 个字符，包含大小写字母、数字和特殊字符）
CREATE USER IF NOT EXISTS admin
IDENTIFIED WITH sha256_password BY 'Admin@SecurePassword123!'
SETTINGS access_management = 1;

-- 定期更换密码（每 90 天）
ALTER USER admin IDENTIFIED WITH sha256_password BY 'NewAdmin@Password123!';
```

### 2. 使用 SHA-256 密码

```sql
-- ✅ 推荐：使用 SHA-256 密码
CREATE USER IF NOT EXISTS user1
IDENTIFIED WITH sha256_password BY 'SecurePassword123!';

-- ❌ 避免：使用明文密码（仅用于测试）
CREATE USER IF NOT EXISTS test_user
IDENTIFIED WITH plaintext_password BY 'TestPassword123!';
```

### 3. 集成企业目录服务

```sql
-- 集成 LDAP 进行身份认证
CREATE USER IF NOT EXISTS ldap_user
IDENTIFIED WITH ldap_server 'company_ldap';

CREATE ROLE IF NOT EXISTS ldap_role;
GRANT SELECT ON *.* TO ldap_role;
GRANT ldap_role TO ldap_user;
```

### 4. 限制网络访问

```sql
-- 创建用户并限制 IP 访问
CREATE USER IF NOT EXISTS internal_user
IDENTIFIED WITH sha256_password BY 'InternalPassword123!'
HOST IP '192.168.0.0/16', '10.0.0.0/8'
HOST LOCAL;
```

### 5. 移除默认用户

```sql
-- ❌ 删除或修改默认的 default 用户
DROP USER IF EXISTS default;

-- 或修改默认用户密码
ALTER USER default IDENTIFIED WITH sha256_password BY 'NewSecurePassword123!';
```

## 访问控制最佳实践

### 1. 使用角色管理权限

```sql
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
```

### 2. 实施最小权限原则

```sql
-- 只授予必要的最小权限
CREATE ROLE IF NOT EXISTS data_analyst;
GRANT SELECT ON analytics.* TO data_analyst;
GRANT SELECT ON sales.* TO data_analyst;
-- 不授予 INSERT、UPDATE、DELETE 等权限
```

### 3. 使用行级安全

```sql
-- 创建行级安全策略
CREATE ROW POLICY IF NOT EXISTS user_data_filter
ON analytics.user_events
USING user_id = current_user()
AS RESTRICTIVE TO readonly_user;
```

### 4. 使用列级权限

```sql
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
```

### 5. 定期审查权限

```sql
-- 定期审查用户权限
SELECT 
    user,
    count() as permission_count,
    groupUniqArray(distinct table) as tables
FROM system.grants
WHERE user IS NOT NULL
GROUP BY user
ORDER BY permission_count DESC;
```

## 网络安全最佳实践

### 1. 始终使用 SSL/TLS

```xml
<!-- config.xml -->
<openSSL>
    <server>
        <certificateFile>/etc/clickhouse-server/certs/server.crt</certificateFile>
        <privateKeyFile>/etc/clickhouse-server/certs/server.key</privateKeyFile>
        <caFile>/etc/clickhouse-server/certs/ca.crt</caFile>
        <verificationMode>strict</verificationMode>
    </server>
    <client>
        <caFile>/etc/clickhouse-server/certs/ca.crt</caFile>
        <verificationMode>strict</verificationMode>
    </client>
</openSSL>
```

### 2. 配置 IP 白名单

```xml
<!-- users.xml -->
<users>
    <admin>
        <password_sha256_hex>...</password_sha256_hex>
        <networks>
            <ip>::1</ip>
            <ip>127.0.0.1</ip>
            <ip>192.168.1.0/24</ip>
        </networks>
    </admin>
</users>
```

### 3. 使用防火墙限制端口

```bash
#!/bin/bash
# 只允许必要端口
iptables -A INPUT -p tcp --dport 9000 -s 192.168.0.0/16 -j ACCEPT
iptables -A INPUT -p tcp --dport 8123 -s 192.168.0.0/16 -j ACCEPT
iptables -A INPUT -p tcp --dport 8443 -j DROP  # 拒绝 HTTP 访问
iptables -A INPUT -j DROP
```

### 4. 使用反向代理

```nginx
# Nginx 反向代理
upstream clickhouse_cluster {
    server clickhouse1:8443;
    server clickhouse2:8443;
    server clickhouse3:8443;
}

server {
    listen 443 ssl http2;
    server_name clickhouse.company.com;

    ssl_certificate /etc/nginx/ssl/server.crt;
    ssl_certificate_key /etc/nginx/ssl/server.key;
    ssl_protocols TLSv1.2 TLSv1.3;

    location / {
        proxy_pass https://clickhouse_cluster;
        proxy_ssl_verify on;
    }
}
```

## 数据保护最佳实践

### 1. 加密敏感数据

```sql
-- 使用应用层加密
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
```

### 2. 数据脱敏

```sql
-- 查询时脱敏
SELECT 
    user_id,
    username,
    concat(substring(email, 1, 1), '***@', splitByChar('@', email)[2]) as masked_email
FROM analytics.users;
```

### 3. 备份加密

```bash
#!/bin/bash
# 加密备份
clickhouse-backup create my_backup
gpg --encrypt --recipient admin@company.com my_backup.tar
rm my_backup.tar
```

### 4. 定期备份数据

```bash
#!/bin/bash
# 每日备份
clickhouse-backup create daily_backup_$(date +%Y%m%d)
# 保留最近 30 天的备份
clickhouse-backup delete local --older-than 30
```

## 监控和审计最佳实践

### 1. 启用审计日志

```xml
<!-- config.xml -->
<query_log>
    <database>system</database>
    <table>query_log</table>
    <partition_by>toYYYYMM(event_date)</partition_by>
    <ttl>event_date + INTERVAL 30 DAY DELETE</ttl>
    <type>1,2,4</type>
</query_log>
```

### 2. 监控异常访问

```sql
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
```

### 3. 设置告警规则

```sql
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
```

### 4. 定期分析审计日志

```sql
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
```

## 运维安全最佳实践

### 1. 定期更新 ClickHouse

```bash
#!/bin/bash
# 定期检查更新
clickhouse-client --query "SELECT version();"

# 备份数据
clickhouse-backup create pre_upgrade_backup

# 升级 ClickHouse
apt-get update
apt-get install --only-upgrade clickhouse-server clickhouse-client

# 重启服务
systemctl restart clickhouse-server
```

### 2. 使用配置管理工具

```yaml
# Ansible playbook 示例
- name: Configure ClickHouse security
  hosts: clickhouse_servers
  tasks:
    - name: Copy SSL certificates
      copy:
        src: files/ssl/
        dest: /etc/clickhouse-server/certs/
        mode: '0600'
    
    - name: Configure SSL
      copy:
        src: config.d/ssl.xml
        dest: /etc/clickhouse-server/config.d/ssl.xml
      notify: restart clickhouse
    
    - name: Configure firewall
      iptables:
        chain: INPUT
        protocol: tcp
        destination_port: 9000
        source: 192.168.0.0/16
        jump: ACCEPT
```

### 3. 使用自动化部署

```bash
#!/bin/bash
# 自动化部署脚本

# 1. 生成 SSL 证书
./generate_certs.sh

# 2. 配置防火墙
./configure_firewall.sh

# 3. 配置 ClickHouse
./configure_clickhouse.sh

# 4. 创建用户和角色
clickhouse-client --queries-file create_users.sql

# 5. 配置审计日志
clickhouse-client --queries-file configure_audit.sql

# 6. 启动 ClickHouse
systemctl start clickhouse-server

# 7. 验证配置
clickhouse-client --query "SELECT version();"
```

### 4. 应急响应计划

```bash
#!/bin/bash
# 安全事件应急响应脚本

# 1. 隔离受影响的服务器
iptables -A INPUT -s 192.168.1.10 -j DROP

# 2. 停止 ClickHouse 服务
systemctl stop clickhouse-server

# 3. 备份审计日志
clickhouse-client --query "SELECT * FROM system.query_log WHERE event_time >= now() - INTERVAL 1 HOUR" > audit_log_backup.tsv

# 4. 分析安全事件
clickhouse-client --query "SELECT user, query FROM system.query_log WHERE type = 'Exception' AND event_time >= now() - INTERVAL 1 HOUR"

# 5. 修复安全漏洞
# ... 修复步骤 ...

# 6. 恢复服务
systemctl start clickhouse-server

# 7. 验证恢复
clickhouse-client --query "SELECT 1"
```

## 常见安全场景

### 场景 1: 多租户数据隔离

```sql
-- 创建租户表
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
```

### 场景 2: 保护敏感数据

```sql
-- 创建脱敏视图
CREATE TABLE IF NOT EXISTS public.user_profiles_masked AS
SELECT 
    user_id,
    username,
    concat(substring(email, 1, 1), '***@', splitByChar('@', email)[2]) as masked_email,
    created_at
FROM secure.user_profiles;

-- 授予公众访问脱敏数据
GRANT SELECT ON public.user_profiles_masked TO public_role;

-- 限制访问真实数据
GRANT SELECT ON secure.user_profiles TO admin_role;
```

### 场景 3: 审计合规

```sql
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
```

## 安全检查清单

### 身份认证

- [ ] 使用强密码（至少 12 个字符）
- [ ] 使用 SHA-256 密码哈希
- [ ] 集成 LDAP/Kerberos
- [ ] 限制网络访问（IP 白名单）
- [ ] 移除默认用户
- [ ] 定期更换密码（每 90 天）
- [ ] 启用多因素认证（如适用）

### 访问控制

- [ ] 使用角色管理权限
- [ ] 实施最小权限原则
- [ ] 使用行级安全
- [ ] 使用列级权限
- [ ] 定期审查权限
- [ ] 分离职责
- [ ] 记录权限变更

### 网络安全

- [ ] 启用 SSL/TLS
- [ ] 配置 IP 白名单
- [ ] 配置防火墙规则
- [ ] 使用反向代理
- [ ] 隔离网络（VPC）
- [ ] 限制端口暴露
- [ ] 监控网络流量

### 数据保护

- [ ] 加密敏感数据
- [ ] 实施数据脱敏
- [ ] 加密备份
- [ ] 定期备份数据
- [ ] 管理加密密钥
- [ ] 实施数据保留策略
- [ ] 符合数据保护法规

### 监控审计

- [ ] 启用审计日志
- [ ] 监控异常访问
- [ ] 设置告警规则
- [ ] 定期分析日志
- [ ] 备份审计日志
- [ ] 实施日志轮换
- [ ] 符合合规要求

### 运维安全

- [ ] 定期更新 ClickHouse
- [ ] 使用配置管理工具
- [ ] 自动化部署
- [ ] 制定应急响应计划
- [ ] 定期安全扫描
- [ ] 渗透测试
- [ ] 安全培训

## 🎯 安全建议

1. **优先考虑安全**：在设计和实施时优先考虑安全
2. **纵深防御**：多层安全防护，避免单点故障
3. **最小权限**：只授予必要的最小权限
4. **定期审查**：定期审查和更新安全配置
5. **持续监控**：持续监控安全状态和异常事件
6. **及时响应**：及时发现和响应安全事件
7. **培训员工**：定期进行安全培训
8. **合规要求**：确保符合相关法规和标准

## ⚠️ 常见安全错误

1. **弱密码**：使用简单或默认密码
2. **过度权限**：授予不必要的权限
3. **未加密传输**：使用明文传输数据
4. **缺少审计**：未启用审计日志
5. **未及时更新**：未及时更新系统
6. **公开端口**：不必要地暴露端口
7. **缺少备份**：未定期备份数据
8. **未隔离网络**：未实施网络隔离

## 📚 相关文档

- [用户认证](./01_authentication.md)
- [用户和角色管理](./02_user_role_management.md)
- [权限控制](./03_permissions.md)
- [网络安全](./05_network_security.md)
- [数据加密](./06_data_encryption.md)
- [审计日志](./07_audit_log.md)
