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
