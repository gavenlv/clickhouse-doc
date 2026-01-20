# 连接问题

本文档描述 ClickHouse 连接相关的问题及解决方案。

## 问题 1: 无法连接到 ClickHouse

### 现象

```
Connection refused
Connection timeout
```

### 原因

- ClickHouse 服务未启动
- 端口被占用
- 防火墙阻止连接
- 网络问题

### 诊断

```sql
-- 检查服务是否运行
SELECT host_name(), port, version() FROM system.one;
```

```bash
# Linux/Mac
lsof -i :9000
lsof -i :8123

# Windows
netstat -ano | findstr :9000
netstat -ano | findstr :8123
```

### 解决方案

1. **检查服务状态**
   ```bash
   # Docker
   docker-compose ps
   docker-compose logs clickhouse1

   # Systemd
   systemctl status clickhouse-server
   ```

2. **检查端口占用**
   ```bash
   # 如果端口被占用，停止占用进程
   kill -9 <PID>
   ```

3. **检查防火墙**
   ```bash
   # Linux
   sudo iptables -L -n | grep 9000
   sudo iptables -A INPUT -p tcp --dport 9000 -j ACCEPT

   # Windows
   netsh advfirewall firewall add rule name="ClickHouse" dir=in action=allow protocol=TCP localport=9000
   ```

4. **检查网络连接**
   ```bash
   # 测试网络连通性
   ping <host>
   telnet <host> 9000
   ```

## 问题 2: 连接超时

### 现象

```
Connection timeout
Timeout connecting to ClickHouse
```

### 原因

- 网络延迟
- 查询执行时间过长
- 连接数过多

### 解决方案

1. **增加连接超时时间**
   ```xml
   <!-- config.xml -->
   <connect_timeout>10</connect_timeout>
   <receive_timeout>300</receive_timeout>
   <send_timeout>300</send_timeout>
   ```

2. **优化查询**
   ```sql
   -- 添加 LIMIT
   SELECT * FROM large_table LIMIT 1000;

   -- 添加 WHERE 条件
   SELECT * FROM table WHERE date = today();
   ```

3. **限制连接数**
   ```xml
   <max_concurrent_queries>100</max_concurrent_queries>
   ```

## 问题 3: 认证失败

### 现象

```
Authentication failed
Access denied
```

### 原因

- 用户名或密码错误
- 用户权限不足
- 用户不存在

### 诊断

```sql
-- 查看所有用户
SELECT * FROM system.users;
```

### 解决方案

1. **创建用户**
   ```sql
   CREATE USER IF NOT EXISTS app_user
   IDENTIFIED WITH plaintext_password BY 'your_password'
   DEFAULT ROLE ALL;
   ```

2. **授予权限**
   ```sql
   GRANT ALL ON *.* TO app_user;
   ```

3. **检查连接字符串**
   ```bash
   # 确保用户名和密码正确
   clickhouse-client --user app_user --password your_password
   ```

## 问题 4: SSL/TLS 连接问题

### 现象

```
SSL handshake failed
Certificate verification failed
```

### 解决方案

1. **配置 SSL**
   ```xml
   <!-- config.xml -->
   <openSSL>
       <server>
           <certificateFile>/etc/clickhouse-server/certs/server.crt</certificateFile>
           <privateKeyFile>/etc/clickhouse-server/certs/server.key</privateKeyFile>
           <caConfig>/etc/clickhouse-server/certs/ca.crt</caConfig>
           <verificationMode>strict</verificationMode>
       </server>
   </openSSL>
   ```

2. **客户端配置**
   ```bash
   clickhouse-client --secure \
       --user app_user \
       --password your_password \
       --certificate /path/to/cert.crt
   ```

## 问题 5: IPv6 连接失败

### 现象

```
Connection refused to IPv6 address
```

### 原因

- Docker 网络仅支持 IPv4
- 配置使用了 IPv6 地址

### 解决方案

1. **使用 IPv4 地址**
   ```xml
   <listen_host>0.0.0.0</listen_host>
   ```

2. **禁用 IPv6**
   ```xml
   <listen_try>0</listen_try>
   ```

---

**最后更新**: 2026-01-19
