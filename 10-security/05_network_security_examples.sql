-- ================================================================================
-- ClickHouse 网络安全示例
-- ================================================================================
-- 
-- 集群: treasurycluster (2 副本)
-- 预计学习时间: 15 分钟
-- 
-- 本文件涵盖:
--   1. IP 地址限制 - HOST IP
--   2. 主机名限制 - HOST NAME
--   3. 正则表达式 - HOST REGEXP
--   4. 本地连接 - HOST LOCAL
--   5. 连接监控 - system.processes
--   6. 连接历史 - system.query_log
--   7. 网络使用统计 - 带宽监控
-- 
-- 网络访问控制:
-- 
--   ┌─────────────────────────────────────────────────────────────────────────┐
--   │                    ClickHouse 网络访问控制                              │
--   └─────────────────────────────────────────────────────────────────────────┘
--   
--   ┌─────────────────────────────────────────────────────────────────────────┐
--   │                       HOST 限制类型                                     │
--   └─────────────────────────────────────────────────────────────────────────┘
--   
--   HOST IP '192.168.1.0/24'      IP 地址段 (CIDR 表示法)
--   HOST NAME 'host.example.com'  主机名 (支持通配符)
--   HOST REGEXP 'worker-.*'       正则表达式匹配
--   HOST LOCAL                    本地 Unix socket 连接
--   HOST ANY                      允许所有主机 (默认)
--   
--   组合使用:
--   ┌────────────────────────────────────────────────────────────────────────┐
--   │ CREATE USER alice                                                      │
--   │ HOST IP '192.168.1.0/24', '10.0.0.0/8'    -- 多个 IP 段               │
--   │ HOST NAME '*.company.com'                 -- 通配符主机名              │
--   │ HOST LOCAL;                               -- 允许本地连接              │
--   └────────────────────────────────────────────────────────────────────────┘
-- 
-- 网络安全架构:
-- 
--   ┌─────────────────────────────────────────────────────────────────────────┐
--   │                       网络分层安全                                      │
--   └─────────────────────────────────────────────────────────────────────────┘
--   
--   Layer 1: 网络防火墙
--   ┌────────────────────────────────────────────────────────────────────────┐
--   │ 只允许特定 IP 访问 ClickHouse 端口 (9000/8123)                         │
--   └────────────────────────────────────────────────────────────────────────┘
--   
--   Layer 2: ClickHouse 用户 HOST 限制
--   ┌────────────────────────────────────────────────────────────────────────┐
--   │ CREATE USER ... HOST IP '192.168.1.0/24'                               │
--   └────────────────────────────────────────────────────────────────────────┘
--   
--   Layer 3: SSL/TLS 加密
--   ┌────────────────────────────────────────────────────────────────────────┐
--   │ 强制使用 SSL 连接, 加密传输数据                                        │
--   └────────────────────────────────────────────────────────────────────────┘
--   
--   Layer 4: 应用层认证
--   ┌────────────────────────────────────────────────────────────────────────┐
--   │ 用户名/密码, LDAP, Kerberos, SSL 证书                                  │
--   └────────────────────────────────────────────────────────────────────────┘
-- 
-- ================================================================================

CREATE USER IF NOT EXISTS alice
IDENTIFIED WITH sha256_password BY 'AlicePassword123!'
HOST IP '192.168.1.0/24', '10.0.0.0/8'
HOST LOCAL;

CREATE USER IF NOT EXISTS bob
IDENTIFIED WITH sha256_password BY 'BobPassword123!'
HOST IP '192.168.2.0/24'
HOST NAME 'analyst-*.company.com'
HOST REGEXP 'worker-\\d+\\.company\\.com';

-- ========================================
-- 使用 SQL 创建用户并限制 IP
-- ========================================

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

-- ========================================
-- 使用 SQL 创建用户并限制 IP
-- ========================================

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
