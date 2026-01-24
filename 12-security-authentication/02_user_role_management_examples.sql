CREATE USER IF NOT EXISTS alice
IDENTIFIED WITH sha256_password BY 'AlicePassword123!';

-- 创建用户并指定默认角色
CREATE USER IF NOT EXISTS bob
IDENTIFIED WITH sha256_password BY 'BobPassword123!'
DEFAULT ROLE analyst_role;

-- 创建用户并指定多个默认角色
CREATE USER IF NOT EXISTS charlie
IDENTIFIED WITH sha256_password BY 'CharliePassword123!'
DEFAULT ROLE readonly_role, analyst_role;

-- ========================================
-- 基本用户创建
-- ========================================

-- 创建管理员用户
CREATE USER IF NOT EXISTS admin
IDENTIFIED WITH sha256_password BY 'AdminPassword123!'
DEFAULT ROLE admin_role
-- REMOVED SET access_management (not supported) 1;

-- 创建带 IP 限制的用户
CREATE USER IF NOT EXISTS restricted_user
IDENTIFIED WITH sha256_password BY 'RestrictedPassword123!'
HOST IP '192.168.1.0/24'
HOST LOCAL;

-- 创建带 SQL 限制的用户
CREATE USER IF NOT EXISTS readonly_user
IDENTIFIED WITH sha256_password BY 'ReadOnlyPassword123!'
SETTINGS -- REMOVED SETTING max_memory_usage (not supported) 10000000000,  -- 10 GB
    max_rows_to_read = 1000000000;  -- 10 亿行

-- ========================================
-- 基本用户创建
-- ========================================

-- 在集群上创建用户
CREATE USER IF NOT EXISTS cluster_user
IDENTIFIED WITH sha256_password BY 'ClusterPassword123!'
ON CLUSTER 'treasurycluster';

-- 在所有节点上创建用户
CREATE USER IF NOT EXISTS replicator
IDENTIFIED WITH sha256_password BY 'ReplicatorPassword123!'
ON CLUSTER 'treasurycluster'
DEFAULT ROLE replicator_role;

-- ========================================
-- 基本用户创建
-- ========================================

-- 查看所有用户
SELECT name, storage, auth_type, host_ip
FROM system.users;

-- 查看用户详细信息
SHOW CREATE USER admin;

-- 查看用户权限
SHOW GRANTS FOR admin;

-- 查看用户角色
SHOW GRANTS FOR alice
WHERE type = 'ROLE';

-- 查看用户设置
SELECT name, value, changed
FROM system.settings
WHERE user = 'alice';

-- ========================================
-- 基本用户创建
-- ========================================

-- 修改用户密码
ALTER USER admin IDENTIFIED WITH sha256_password BY 'NewPassword123!';

-- 修改用户默认角色
ALTER USER alice DEFAULT ROLE readonly_role, analyst_role;

-- 修改用户主机限制
ALTER USER bob HOST IP '10.0.0.0/8', '192.168.0.0/16';

-- 修改用户设置
ALTER USER readonly_user
SETTINGS -- REMOVED SETTING max_memory_usage (not supported) 20000000000;

-- ========================================
-- 基本用户创建
-- ========================================

-- 删除用户
DROP USER IF EXISTS test_user;

-- 在集群上删除用户
DROP USER IF EXISTS old_user
ON CLUSTER 'treasurycluster';

-- 删除用户及其所有权限
DROP USER IF EXISTS deprecated_user
SETTINGS drop_atomic = 0;

-- ========================================
-- 基本用户创建
-- ========================================

-- 创建只读角色
CREATE ROLE IF NOT EXISTS readonly_role;

-- 创建写入角色
CREATE ROLE IF NOT EXISTS writer_role;

-- 创建分析师角色
CREATE ROLE IF NOT EXISTS analyst_role;

-- ========================================
-- 基本用户创建
-- ========================================

-- 创建只读角色并分配权限
CREATE ROLE IF NOT EXISTS readonly_role
GRANT SELECT ON *.*;

-- 创建写入角色并分配权限
CREATE ROLE IF NOT EXISTS writer_role
GRANT INSERT, SELECT ON *.*;

-- 创建管理员角色并分配权限
CREATE ROLE IF NOT EXISTS admin_role
GRANT ALL ON *.*;

-- ========================================
-- 基本用户创建
-- ========================================

-- 创建数据库管理员角色
CREATE ROLE IF NOT EXISTS db_admin_role
GRANT
    CREATE, DROP, ALTER, TRUNCATE
    ON *.*
-- REMOVED SET access_management (not supported) 1;

-- 创建数据分析角色（限制内存）
CREATE ROLE IF NOT EXISTS data_analyst_role
GRANT SELECT ON *.*
-- REMOVED SET max_memory_usage (not supported) 5000000000,  -- 5 GB
    max_execution_time = 300;       -- 5 分钟

-- 创建临时用户角色（有有效期）
CREATE ROLE IF NOT EXISTS temp_role
GRANT SELECT ON *.*
SETTINGS
    max_execution_time = 60,  -- 1 分钟
    max_rows_to_read = 1000000;  -- 100 万行

-- ========================================
-- 基本用户创建
-- ========================================

-- 查看所有角色
SELECT name, storage
FROM system.roles;

-- 查看角色详细信息
SHOW CREATE ROLE analyst_role;

-- 查看角色权限
SHOW GRANTS FOR analyst_role;

-- 查看角色成员
SELECT user_name, role_name
FROM system.role_grants
WHERE role_name = 'analyst_role';

-- ========================================
-- 基本用户创建
-- ========================================

-- 为角色添加权限
GRANT INSERT ON analytics.* TO analyst_role;

-- 为角色移除权限
REVOKE INSERT ON system.* FROM analyst_role;

-- 修改角色设置
ALTER ROLE data_analyst_role
-- REMOVED SET max_memory_usage (not supported) 10000000000,
    max_execution_time = 600;

-- ========================================
-- 基本用户创建
-- ========================================

-- 删除角色
DROP ROLE IF EXISTS old_role;

-- 在集群上删除角色
DROP ROLE IF EXISTS deprecated_role
ON CLUSTER 'treasurycluster';

-- ========================================
-- 基本用户创建
-- ========================================

-- 创建基础角色
CREATE ROLE IF NOT EXISTS base_role
GRANT SELECT ON *.*;

-- 创建只读角色（继承基础角色）
CREATE ROLE IF NOT EXISTS readonly_role
GRANT SELECT ON *.*
SETTINGS INHERIT 'base_role';

-- 创建分析师角色（继承只读角色）
CREATE ROLE IF NOT EXISTS analyst_role
GRANT SELECT, ALTER UPDATE ON *.*
SETTINGS INHERIT 'readonly_role';

-- ========================================
-- 基本用户创建
-- ========================================

-- 创建角色层次结构
CREATE ROLE IF NOT EXISTS base_role;
GRANT SELECT ON *.* TO base_role;

CREATE ROLE IF NOT EXISTS readonly_role INHERIT base_role;

CREATE ROLE IF NOT EXISTS writer_role INHERIT base_role;
GRANT INSERT ON *.* TO writer_role;

CREATE ROLE IF NOT EXISTS db_admin_role INHERIT readonly_role, writer_role;
GRANT CREATE, DROP, ALTER ON *.* TO db_admin_role;

CREATE ROLE IF NOT EXISTS analyst_role INHERIT readonly_role;
GRANT SELECT, ALTER UPDATE ON *.* TO analyst_role;

CREATE ROLE IF NOT EXISTS admin_role INHERIT db_admin_role, analyst_role;
GRANT ALL ON *.* TO admin_role;

-- ========================================
-- 基本用户创建
-- ========================================

-- 查看角色继承关系
SELECT 
    r.name as role_name,
    r2.name as inherited_role
FROM system.role_grants rg
JOIN system.roles r ON rg.role_name = r.name
LEFT JOIN system.roles r2 ON rg.inherited_role = r2.name;

-- 查看角色的所有权限（包括继承的）
SHOW GRANTS FOR admin_role WITH INHERIT;

-- ========================================
-- 基本用户创建
-- ========================================

-- 创建有限资源的角色
CREATE ROLE IF NOT EXISTS limited_role
SETTINGS -- REMOVED SETTING max_concurrent_queries (not supported) 100,             -- 全局 100 个并发查询
    max_concurrent_insert_queries = 50,       -- 50 个并发插入

    -- 结果集限制
    max_result_rows = 10000000,               -- 1000 万行
    max_result_bytes = 1000000000;            -- 1 GB

-- ========================================
-- 基本用户创建
-- ========================================

-- 创建网络限制的角色
CREATE ROLE IF NOT EXISTS network_limited_role
SETTINGS -- REMOVED SETTING max_concurrent_queries (not supported) 20;              -- 全局 20 个并发查询

-- ========================================
-- 基本用户创建
-- ========================================

-- 创建用于备份的角色
CREATE ROLE IF NOT EXISTS backup_role
SETTINGS -- REMOVED SETTING max_memory_usage (not supported) 20000000000,           -- 20 GB
    max_network_bandwidth = 1000000000;       -- 1 GB/s

-- ========================================
-- 基本用户创建
-- ========================================

-- 查看当前连接的用户
SELECT 
    user,
    client_hostname,
    client_port,
    connection_id,
    query,
    elapsed
FROM system.processes
WHERE type = 'Query';

-- 查看用户查询历史
SELECT 
    user,
    query,
    query_duration_ms,
    read_rows,
    read_bytes,
    memory_usage,
    event_time
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_time >= now() - INTERVAL 1 DAY
ORDER BY event_time DESC;

-- 查看用户资源使用
SELECT 
    user,
    count() as query_count,
    sum(read_rows) as total_read_rows,
    sum(read_bytes) as total_read_bytes,
    sum(memory_usage) as total_memory_usage,
    avg(query_duration_ms) as avg_query_duration_ms
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_time >= now() - INTERVAL 1 DAY
GROUP BY user;

-- ========================================
-- 基本用户创建
-- ========================================

-- 查看角色分配情况
SELECT 
    r.name as role_name,
    count(DISTINCT rg.user_name) as user_count,
    count(DISTINCT rg.role_name) as granted_role_count
FROM system.roles r
LEFT JOIN system.role_grants rg ON r.name = rg.role_name
GROUP BY r.name
ORDER BY user_count DESC;

-- 查看角色权限分布
SELECT 
    role_name,
    access_type,
    count(*) as count
FROM system.grants
WHERE role_name IS NOT NULL
GROUP BY role_name, access_type
ORDER BY role_name, count DESC;

-- ========================================
-- 基本用户创建
-- ========================================

-- 创建角色
CREATE ROLE IF NOT EXISTS readonly_role;
CREATE ROLE IF NOT EXISTS writer_role;
CREATE ROLE IF NOT EXISTS admin_role;

-- 分配权限
GRANT SELECT ON *.* TO readonly_role;
GRANT INSERT, SELECT ON *.* TO writer_role;
GRANT ALL ON *.* TO admin_role;

-- 创建用户
CREATE USER IF NOT EXISTS alice
IDENTIFIED WITH sha256_password BY 'AlicePassword123!'
DEFAULT ROLE readonly_role;

CREATE USER IF NOT EXISTS bob
IDENTIFIED WITH sha256_password BY 'BobPassword123!'
DEFAULT ROLE writer_role;

CREATE USER IF NOT EXISTS admin
IDENTIFIED WITH sha256_password BY 'AdminPassword123!'
DEFAULT ROLE admin_role
-- REMOVED SET access_management (not supported) 1;

-- ========================================
-- 基本用户创建
-- ========================================

-- 创建角色
CREATE ROLE IF NOT EXISTS sales_role;
CREATE ROLE IF NOT EXISTS marketing_role;
CREATE ROLE IF NOT EXISTS finance_role;

-- 创建用户并设置部门属性
CREATE USER IF NOT EXISTS alice_sales
IDENTIFIED WITH sha256_password BY 'AliceSales123!'
-- REMOVED SET department (not supported) 'sales';

CREATE USER IF NOT EXISTS bob_marketing
IDENTIFIED WITH sha256_password BY 'BobMarketing123!'
-- REMOVED SET department (not supported) 'marketing';

CREATE USER IF NOT EXISTS charlie_finance
IDENTIFIED WITH sha256_password BY 'CharlieFinance123!'
-- REMOVED SET department (not supported) 'finance';

-- 创建行级安全策略
CREATE ROW POLICY IF NOT EXISTS department_filter
ON sales.orders
USING department = current_user_settings['department']
AS RESTRICTIVE TO sales_role, marketing_role, finance_role;

-- 分配角色
GRANT SELECT ON sales.* TO sales_role;
GRANT SELECT ON marketing.* TO marketing_role;
GRANT SELECT ON finance.* TO finance_role;

GRANT sales_role TO alice_sales;
GRANT marketing_role TO bob_marketing;
GRANT finance_role TO charlie_finance;

-- ========================================
-- 基本用户创建
-- ========================================

-- 创建临时角色（1 小时有效期）
CREATE ROLE IF NOT EXISTS temp_role
SETTINGS -- REMOVED SETTING max_memory_usage (not supported) 5000000000;  -- 5 GB

GRANT SELECT ON analytics.* TO temp_role;

-- 创建临时用户
CREATE USER IF NOT EXISTS temp_user
IDENTIFIED WITH sha256_password BY 'TempPassword123!'
DEFAULT ROLE temp_role;

-- 1 小时后删除临时用户
-- DROP USER IF EXISTS temp_user;

-- ========================================
-- 基本用户创建
-- ========================================

-- 在集群上创建角色
CREATE ROLE IF NOT EXISTS cluster_reader_role
ON CLUSTER 'treasurycluster'
GRANT SELECT ON *.*;

CREATE ROLE IF NOT EXISTS cluster_writer_role
ON CLUSTER 'treasurycluster'
GRANT INSERT, SELECT ON *.*;

-- 在集群上创建用户
CREATE USER IF NOT EXISTS cluster_analyst
IDENTIFIED WITH sha256_password BY 'ClusterAnalyst123!'
DEFAULT ROLE cluster_reader_role
ON CLUSTER 'treasurycluster';

CREATE USER IF NOT EXISTS cluster_writer
IDENTIFIED WITH sha256_password BY 'ClusterWriter123!'
DEFAULT ROLE cluster_writer_role
ON CLUSTER 'treasurycluster';
