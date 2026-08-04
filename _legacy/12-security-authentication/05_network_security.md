# 网络安全

网络安全是保护 ClickHouse 集群的重要组成部分。本节将介绍如何配置 SSL/TLS、防火墙规则、IP 白名单和其他网络安全措施。

## 📑 目录

- [SSL/TLS 配置](#ssltls-配置)
- [IP 白名单](#ip-白名单)
- [防火墙规则](#防火墙规则)
- [网络隔离](#网络隔离)
- [代理和负载均衡](#代理和负载均衡)
- [网络安全监控](#网络安全监控)
- [实战示例](#实战示例)

## SSL/TLS 配置

### 生成证书

```bash
# 1. 生成 CA 私钥
openssl genrsa -out ca.key 2048

# 2. 生成 CA 证书
openssl req -x509 -new -nodes -key ca.key -sha256 -days 3650 \
    -out ca.crt \
    -subj "/C=CN/ST=Beijing/L=Beijing/O=Company/OU=IT/CN=ClickHouse-CA"

# 3. 生成服务器私钥
openssl genrsa -out server.key 2048

# 4. 生成服务器证书签名请求（CSR）
openssl req -new -key server.key -out server.csr \
    -subj "/C=CN/ST=Beijing/L=Beijing/O=Company/OU=IT/CN=clickhouse1.company.com"

# 5. 创建服务器证书扩展配置
cat > server_ext.cnf << EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
subjectAltName = @alt_names
[alt_names]
DNS.1 = clickhouse1.company.com
DNS.2 = clickhouse1
DNS.3 = localhost
IP.1 = 192.168.1.10
EOF

# 6. 使用 CA 签名服务器证书
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
    -out server.crt -days 3650 -sha256 -extfile server_ext.cnf

# 7. 生成客户端私钥
openssl genrsa -out client.key 2048

# 8. 生成客户端证书签名请求（CSR）
openssl req -new -key client.key -out client.csr \
    -subj "/C=CN/ST=Beijing/L=Beijing/O=Company/OU=IT/CN=analyst1"

# 9. 使用 CA 签名客户端证书
openssl x509 -req -in client.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
    -out client.crt -days 3650 -sha256

# 10. 验证证书
openssl x509 -in server.crt -text -noout
openssl x509 -in client.crt -text -noout
```

### 配置服务器 SSL

```xml
<!-- config.xml -->
<openSSL>
    <server>
        <!-- 服务器证书和私钥 -->
        <certificateFile>/etc/clickhouse-server/certs/server.crt</certificateFile>
        <privateKeyFile>/etc/clickhouse-server/certs/server.key</privateKeyFile>
        
        <!-- CA 证书（用于验证客户端证书） -->
        <caFile>/etc/clickhouse-server/certs/ca.crt</caFile>
        
        <!-- 验证模式 -->
        <verificationMode>none</verificationMode>  <!-- 客户端验证：none, relaxed, strict, once -->
        
        <!-- 是否加载默认 CA 证书 -->
        <loadDefaultCAFile>false</loadDefaultCAFile>
        
        <!-- 缓存设置 -->
        <cacheSessions>true</cacheSessions>
        <sessionCacheSize>1024</sessionCacheSize>
        <sessionTimeout>86400</sessionTimeout>
        
        <!-- 协议版本 -->
        <protocols>tlsv1.2, tlsv1.3</protocols>
        
        <!-- 密码套件 -->
        <ciphers>ECDHE-RSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-GCM-SHA384</ciphers>
    </server>
    
    <client>
        <!-- 客户端 CA 证书（用于验证服务器证书） -->
        <caFile>/etc/clickhouse-server/certs/ca.crt</caFile>
        
        <!-- 验证模式 -->
        <verificationMode>strict</verificationMode>
        
        <!-- 是否加载默认 CA 证书 -->
        <loadDefaultCAFile>false</loadDefaultCAFile>
        
        <!-- 缓存设置 -->
        <cacheSessions>true</cacheSessions>
        <sessionCacheSize>1024</sessionCacheSize>
        <sessionTimeout>86400</sessionTimeout>
        
        <!-- 协议版本 -->
        <protocols>tlsv1.2, tlsv1.3</protocols>
        
        <!-- 无效证书处理 -->
        <invalidCertificateHandler>
            <name>RejectCertificateHandler</name>
        </invalidCertificateHandler>
    </client>
</openSSL>

<!-- HTTPS 接口配置 -->
<https_port>8443</https_port>
<tcp_port_secure>9440</tcp_port_secure>
<interserver_https_port>9009</interserver_https_port>
```

### 配置客户端 SSL

```bash
# 使用 SSL 连接 ClickHouse
clickhouse-client \
    --host clickhouse1.company.com \
    --port 9440 \
    --secure \
    --user admin \
    --password 'AdminPassword123!' \
    --ca-file /etc/clickhouse-client/certs/ca.crt \
    --cert-file /etc/clickhouse-client/certs/client.crt \
    --key-file /etc/clickhouse-client/certs/client.key

# 使用 HTTPS 接口
curl -k \
    --cert /etc/clickhouse-client/certs/client.crt \
    --key /etc/clickhouse-client/certs/client.key \
    https://clickhouse1.company.com:8443/?query=SELECT%20version()
```

### 配置集群间 SSL

```xml
<!-- config.xml -->
<interserver_https_port>9009</interserver_https_port>

<!-- clickhouse1.xml (config.d/) -->
<openSSL>
    <server>
        <certificateFile>/etc/clickhouse-server/certs/clickhouse1.crt</certificateFile>
        <privateKeyFile>/etc/clickhouse-server/certs/clickhouse1.key</privateKeyFile>
        <caFile>/etc/clickhouse-server/certs/ca.crt</caFile>
        <verificationMode>none</verificationMode>
    </server>
    <client>
        <caFile>/etc/clickhouse-server/certs/ca.crt</caFile>
        <verificationMode>strict</verificationMode>
    </client>
</openSSL>
```

## IP 白名单

### 配置全局 IP 白名单

```xml
<!-- config.xml -->
<ip_filter>
    <!-- 允许本地访问 -->
    <ip>::1</ip>
    <ip>127.0.0.1</ip>
    
    <!-- 允许特定子网 -->
    <ip>192.168.0.0/16</ip>
    <ip>10.0.0.0/8</ip>
    
    <!-- 拒绝特定 IP -->
    <ip>192.168.1.100</ip>
</ip_filter>
```

### 配置用户级 IP 白名单

```xml
<!-- users.xml -->
<users>
    <admin_user>
        <password_sha256_hex>...</password_sha256_hex>
        <networks>
            <ip>::1</ip>
            <ip>127.0.0.1</ip>
            <ip>192.168.1.0/24</ip>
        </networks>
        <profile>default</profile>
        <quota>default</quota>
    </admin_user>
    
    <analyst_user>
        <password_sha256_hex>...</password_sha256_hex>
        <networks>
            <ip>192.168.2.0/24</ip>
            <ip>10.1.0.0/16</ip>
        </networks>
        <profile>readonly</profile>
        <quota>limited</quota>
    </analyst_user>
</users>
```

### 使用 SQL 创建用户并限制 IP

```sql
-- 创建用户并限制 IP
CREATE USER IF NOT EXISTS alice
IDENTIFIED WITH sha256_password BY 'AlicePassword123!'
HOST IP '192.168.1.0/24', '10.0.0.0/8'
HOST LOCAL;

CREATE USER IF NOT EXISTS bob
IDENTIFIED WITH sha256_password BY 'BobPassword123!'
HOST IP '192.168.2.0/24'
HOST NAME 'analyst-*.company.com'
HOST REGEXP 'worker-\\d+\\.company\\.com';
```

## 防火墙规则

### iptables 规则

```bash
#!/bin/bash

# ClickHouse 服务器防火墙规则

# 允许已建立的连接
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# 允许本地访问
iptables -A INPUT -s 127.0.0.1 -j ACCEPT
iptables -A INPUT -s ::1 -j ACCEPT

# 允许 ZooKeeper/Keeper 端口
iptables -A INPUT -p tcp --dport 9181 -s 192.168.1.10 -j ACCEPT  # clickhouse1
iptables -A INPUT -p tcp --dport 9181 -s 192.168.1.11 -j ACCEPT  # clickhouse2

# 允许 ClickHouse 复制端口
iptables -A INPUT -p tcp --dport 9009 -s 192.168.1.0/24 -j ACCEPT

# 允许 ClickHouse 查询端口（仅限内网）
iptables -A INPUT -p tcp --dport 9000 -s 192.168.0.0/16 -j ACCEPT
iptables -A INPUT -p tcp --dport 9001 -s 192.168.0.0/16 -j ACCEPT

# 允许 ClickHouse HTTP 端口（仅限内网）
iptables -A INPUT -p tcp --dport 8123 -s 192.168.0.0/16 -j ACCEPT
iptables -A INPUT -p tcp --dport 8124 -s 192.168.0.0/16 -j ACCEPT

# 允许 ClickHouse HTTPS 端口（仅限内网）
iptables -A INPUT -p tcp --dport 8443 -s 192.168.0.0/16 -j ACCEPT

# 允许 SSH
iptables -A INPUT -p tcp --dport 22 -s 192.168.0.0/16 -j ACCEPT

# 拒绝其他所有入站连接
iptables -A INPUT -j DROP

# 保存规则
iptables-save > /etc/iptables/rules.v4
```

### firewalld 规则

```bash
#!/bin/bash

# ClickHouse 服务器 firewalld 规则

# 创建 ClickHouse 服务
cat > /etc/firewalld/services/clickhouse.xml << 'EOF'
<?xml version="1.0" encoding="utf-8"?>
<service>
  <short>ClickHouse</short>
  <description>ClickHouse Database Server</description>
  <port protocol="tcp" port="9000"/>
  <port protocol="tcp" port="9001"/>
  <port protocol="tcp" port="9009"/>
  <port protocol="tcp" port="8123"/>
  <port protocol="tcp" port="8124"/>
  <port protocol="tcp" port="8443"/>
  <port protocol="tcp" port="9440"/>
</service>
EOF

# 重启 firewalld
systemctl restart firewalld

# 添加 ClickHouse 服务
firewall-cmd --permanent --add-service=clickhouse

# 允许特定网段访问
firewall-cmd --permanent --add-source=192.168.0.0/16
firewall-cmd --permanent --add-source=10.0.0.0/8

# 允许本地访问
firewall-cmd --permanent --add-source=127.0.0.1
firewall-cmd --permanent --add-source=::1

# 拒绝其他所有访问
firewall-cmd --permanent --set-target=DROP

# 重新加载防火墙规则
firewall-cmd --reload

# 查看规则
firewall-cmd --list-all
```

## 网络隔离

### VPC 网络隔离

```
公网
  ↓
负载均衡器（公网 IP）
  ↓
DMZ 网络
  └── 应用服务器（仅 HTTPS）
      ↓
应用服务器
  ↓
ClickHouse 专用网络（私有 IP）
  ├── ClickHouse 节点 1（192.168.1.10）
  ├── ClickHouse 节点 2（192.168.1.11）
  └── ClickHouse 节点 3（192.168.1.12）
```

### 网络段划分

| 网络段 | 用途 | CIDR | 访问控制 |
|--------|------|------|---------|
| **公网** | Internet 访问 | - | 仅 HTTPS |
| **DMZ** | 应用服务器 | 10.0.1.0/24 | 仅 ClickHouse HTTPS |
| **应用层** | 应用服务器 | 10.0.2.0/24 | ClickHouse TCP |
| **ClickHouse** | 数据库服务器 | 192.168.1.0/24 | 仅应用层访问 |
| **管理** | 管理网络 | 192.168.2.0/24 | 所有访问 |

### Docker 网络隔离

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
      - management_net
    ports:
      - "8123:8123"  # 仅用于测试，生产环境应移除
    volumes:
      - ./certs:/etc/clickhouse-server/certs:ro

  clickhouse2:
    image: clickhouse/clickhouse-server:latest
    container_name: clickhouse-server-2
    hostname: clickhouse2
    networks:
      - clickhouse_net
      - management_net
    ports:
      - "8124:8123"  # 仅用于测试

  app:
    image: my-app:latest
    container_name: app-server
    hostname: app
    networks:
      - clickhouse_net
      - management_net

networks:
  clickhouse_net:
    driver: bridge
    internal: false
    ipam:
      config:
        - subnet: 172.20.0.0/16

  management_net:
    driver: bridge
    internal: false
    ipam:
      config:
        - subnet: 172.21.0.0/16
```

## 代理和负载均衡

### Nginx 反向代理

```nginx
# /etc/nginx/conf.d/clickhouse.conf

upstream clickhouse_cluster {
    # ClickHouse 节点
    server clickhouse1:8443 max_fails=3 fail_timeout=30s;
    server clickhouse2:8443 max_fails=3 fail_timeout=30s;
    server clickhouse3:8443 max_fails=3 fail_timeout=30s;
    
    # 保持连接
    keepalive 32;
}

server {
    listen 443 ssl http2;
    server_name clickhouse.company.com;

    # SSL 配置
    ssl_certificate /etc/nginx/ssl/server.crt;
    ssl_certificate_key /etc/nginx/ssl/server.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;

    # 安全头
    add_header Strict-Transport-Security "max-age=31536000" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;

    # 代理 ClickHouse
    location / {
        proxy_pass https://clickhouse_cluster;
        proxy_ssl_verify on;
        proxy_ssl_trusted_certificate /etc/nginx/ssl/ca.crt;
        
        # 超时设置
        proxy_connect_timeout 60s;
        proxy_send_timeout 300s;
        proxy_read_timeout 300s;
        
        # 缓冲设置
        proxy_buffering off;
        proxy_request_buffering off;
        
        # 头部设置
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    # 健康检查
    location /health {
        access_log off;
        return 200 "OK\n";
    }
}
```

### HAProxy 负载均衡

```haproxy
# /etc/haproxy/haproxy.cfg

defaults
    mode http
    timeout connect 10s
    timeout client 30s
    timeout server 30s
    option httplog
    option dontlognull

frontend clickhouse_frontend
    bind *:443 ssl crt /etc/haproxy/certs/server.pem
    default_backend clickhouse_backend

backend clickhouse_backend
    balance roundrobin
    option httpchk GET /ping
    server clickhouse1 clickhouse1:8443 check ssl verify none
    server clickhouse2 clickhouse2:8443 check ssl verify none
    server clickhouse3 clickhouse3:8443 check ssl verify none

listen stats
    bind *:8080
    stats enable
    stats uri /stats
    stats refresh 30s
    stats show-legends
    stats show-node
```

## 网络安全监控

### 监控连接

```sql
-- 查看当前连接
SELECT 
    user,
    client_hostname,
    client_port,
    server_port_name,
    connection_id,
    query,
    elapsed
FROM system.processes
WHERE type = 'Query'
ORDER BY elapsed DESC;

-- 查看连接历史
SELECT 
    user,
    client_hostname,
    event_time,
    query_duration_ms,
    read_rows,
    read_bytes,
    memory_usage
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_time >= now() - INTERVAL 1 DAY
ORDER BY event_time DESC;

-- 查看异常连接
SELECT 
    user,
    client_hostname,
    exception_text,
    event_time
FROM system.query_log
WHERE type = 'Exception'
  AND (exception_code = 516  -- ACCESS_DENIED
       OR exception_code = 82  -- NETWORK_ERROR)
  AND event_time >= now() - INTERVAL 7 DAY
ORDER BY event_time DESC;
```

### 监控网络流量

```sql
-- 查看网络使用情况
SELECT 
    user,
    count() as query_count,
    sum(read_bytes) / 1024 / 1024 / 1024 as read_gb,
    sum(write_bytes) / 1024 / 1024 / 1024 as write_gb,
    sum(read_bytes + write_bytes) / 1024 / 1024 / 1024 as total_gb
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_time >= now() - INTERVAL 1 DAY
GROUP BY user
ORDER BY total_gb DESC;

-- 查看客户端网络使用
SELECT 
    client_hostname,
    count() as query_count,
    sum(read_bytes) / 1024 / 1024 / 1024 as read_gb,
    sum(write_bytes) / 1024 / 1024 / 1024 as write_gb
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_time >= now() - INTERVAL 1 DAY
GROUP BY client_hostname
ORDER BY read_gb DESC;
```

## 实战示例

### 示例 1: 完整的 SSL/TLS 配置

```bash
#!/bin/bash

# 1. 生成证书
cd /etc/clickhouse-server/certs
./generate_certs.sh

# 2. 配置 SSL
cat > /etc/clickhouse-server/config.d/ssl.xml << 'EOF'
<clickhouse>
    <openSSL>
        <server>
            <certificateFile>/etc/clickhouse-server/certs/server.crt</certificateFile>
            <privateKeyFile>/etc/clickhouse-server/certs/server.key</privateKeyFile>
            <caFile>/etc/clickhouse-server/certs/ca.crt</caFile>
            <verificationMode>none</verificationMode>
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
            <protocols>tlsv1.2, tlsv1.3</protocols>
        </client>
    </openSSL>
    <https_port>8443</https_port>
    <tcp_port_secure>9440</tcp_port_secure>
    <interserver_https_port>9009</interserver_https_port>
</clickhouse>
EOF

# 3. 重启 ClickHouse
systemctl restart clickhouse-server

# 4. 测试 SSL 连接
clickhouse-client \
    --host clickhouse1.company.com \
    --port 9440 \
    --secure \
    --user admin \
    --password 'AdminPassword123!'
```

### 示例 2: 多层网络隔离

```bash
#!/bin/bash

# 第 1 层：DMZ 网络（仅 HTTPS）
iptables -A INPUT -p tcp --dport 443 -j ACCEPT
iptables -A INPUT -p tcp --dport 80 -j ACCEPT

# 第 2 层：应用层（ClickHouse HTTPS）
iptables -A INPUT -s 10.0.2.0/24 -p tcp --dport 8443 -j ACCEPT

# 第 3 层：ClickHouse 专用网络（仅 TCP）
iptables -A INPUT -s 192.168.1.0/24 -p tcp --dport 9000 -j ACCEPT
iptables -A INPUT -s 192.168.1.0/24 -p tcp --dport 9009 -j ACCEPT

# 第 4 层：管理网络（所有访问）
iptables -A INPUT -s 192.168.2.0/24 -j ACCEPT

# 拒绝其他所有访问
iptables -A INPUT -j DROP

# 保存规则
iptables-save > /etc/iptables/rules.v4
```

## 🎯 网络安全最佳实践

1. **使用 SSL/TLS**：始终使用加密连接
2. **最小化暴露**：仅暴露必要的端口
3. **IP 白名单**：限制访问来源
4. **网络隔离**：使用 VPC 和网络段隔离
5. **监控连接**：监控异常连接行为
6. **定期更新证书**：每 12 个月更新证书
7. **使用代理**：使用反向代理保护 ClickHouse
8. **防火墙规则**：配置严格的防火墙规则

## ⚠️ 注意事项

1. **性能影响**：SSL/TLS 会增加 CPU 开销
2. **证书管理**：妥善管理证书和私钥
3. **连接池**：使用连接池减少连接开销
4. **超时设置**：配置合理的超时时间
5. **负载均衡**：确保负载均衡器支持 SSL
6. **监控网络**：监控网络流量和连接数

## 📚 相关文档

- [用户认证](./01_authentication.md)
- [数据加密](./06_data_encryption.md)
- [审计日志](./07_audit_log.md)
- [安全最佳实践](./08_best_practices.md)
