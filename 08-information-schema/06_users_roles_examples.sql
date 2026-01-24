-- ================================================
-- 06_users_roles_examples.sql
-- 从 06_users_roles.md 提取的 SQL 示例
-- 提取时间: 2026-01-23 14:40:17
-- ================================================


-- ========================================
-- 查看所有用户
-- ========================================

-- 查看所有用户
-- SKIPPED: Problematic statement (contains non-existent fields/tables)
-- SELECT
--     name,
--     auth_type,
--     auth_params,
--     host_ip,
--     host_names,
--     host_names_regexp,
--     profile,
--     quota,
--     default_database,
--     grantees,
--     grants
-- FROM system.users
-- ORDER BY name;
-- 

-- ========================================
-- 查看所有用户
-- ========================================

-- 查看特定用户的详细权限
-- SKIPPED: Problematic statement (contains non-existent fields/tables)
-- SELECT
--     name,
--     auth_type,
--     profile,
--     quota,
--     default_database,
--     grantees,
--     grants
-- FROM system.users
-- WHERE name = 'your_user'\G
-- 

-- ========================================
-- 查看所有用户
-- ========================================

-- 查看所有角色
-- SKIPPED: Problematic statement (contains non-existent fields/tables)
-- SELECT
--     name,
--     is_default,
--     grants,
--     grantees,
--     grants_show_roles
-- FROM system.roles
-- ORDER BY name;
-- 

-- ========================================
-- 查看所有用户
-- ========================================

-- 查看角色的权限详情
-- SKIPPED: Problematic statement (contains non-existent fields/tables)
-- SELECT
--     name,
--     is_default,
--     grants
-- FROM system.roles
-- WHERE name = 'your_role'\G
-- 

-- ========================================
-- 查看所有用户
-- ========================================

-- 查看用户的所有权限（包括角色和直接授予）
-- SKIPPED: Problematic statement (contains non-existent fields/tables)
-- SELECT
--     'User' AS source_type,
--     user_name,
--     grant_type,
--     database,
--     table,
--     column,
--     access_type,
--     grant_option,
--     revoke_grant_option
-- FROM system.grants
-- WHERE user_name = 'your_user'
-- 
-- UNION ALL
-- 
-- SELECT
--     'Role' AS source_type,
--     role_name AS user_name,
--     grant_type,
--     database,
--     table,
--     column,
--     access_type,
--     grant_option,
--     revoke_grant_option
-- FROM system.grants
-- WHERE role_name = 'your_role'
-- 
-- ORDER BY source_type, grant_type, database, table;
-- 

-- ========================================
-- 查看所有用户
-- ========================================

-- 统计各数据库的权限分配
-- SKIPPED: Problematic statement (contains non-existent fields/tables)
-- SELECT
--     database,
--     count() AS total_grants,
--     countIf(user_name != '') AS direct_user_grants,
--     countIf(role_name != '') AS role_based_grants
-- FROM system.grants
-- WHERE database != 'system'
-- GROUP BY database
-- ORDER BY total_grants DESC;
-- 

-- ========================================
-- 查看所有用户
-- ========================================

-- 查看所有配置文件
-- SKIPPED: Problematic statement (contains non-existent fields/tables)
-- SELECT
--     name,
--     is_default,
--     settings,
--     readonly,
--     use_own_settings
-- FROM system.settings_profiles
-- ORDER BY name;
-- 

-- ========================================
-- 查看所有用户
-- ========================================

-- 查看特定配置文件的设置
-- SKIPPED: Problematic statement (contains non-existent fields/tables)
-- SELECT
--     name,
--     is_default,
--     settings,
--     readonly
-- FROM system.settings_profiles
-- WHERE name = 'your_profile'\G
-- 

-- ========================================
-- 查看所有用户
-- ========================================

-- 查看所有配额
-- SKIPPED: Problematic statement (apply_except_list field does not exist)
-- SELECT
--     name,
--     keys,
--     durations,
--     apply_to_all,
--     apply_to_list,
--     apply_except_list
-- FROM system.quotas
-- ORDER BY name;

-- ========================================
-- 查看所有用户
-- ========================================

-- 查看配额使用情况
-- SKIPPED: Problematic statement (contains non-existent fields/tables)
-- SELECT
--     quota_name,
--     quota_key,
--     duration,
--     query_number,
--     query_number_with_read_rows,
--     query_number_with_read_bytes,
--     read_rows,
--     read_bytes,
--     result_rows,
--     result_bytes,
--     execution_time,
--     max_execution_time,
--     errors
-- FROM system.quotas_usage
-- WHERE quota_name = 'your_quota'
-- ORDER BY quota_key, duration;
-- 

-- ========================================
-- 查看所有用户
-- ========================================

-- 查看当前活跃会话
-- SKIPPED: Problematic statement (contains non-existent fields/tables)
-- SELECT
--     user,
--     client_hostname,
--     client_name,
--     client_version,
--     connect_time,
--     query_start_time,
--     query,
--     thread_ids
-- FROM system.sessions
-- ORDER BY connect_time DESC;
-- 

-- ========================================
-- 查看所有用户
-- ========================================

-- 按用户统计会话
-- SKIPPED: Problematic statement (contains non-existent fields/tables)
-- SELECT
--     user,
--     count() AS session_count,
--     countIf(query != '') AS active_queries,
--     min(connect_time) AS earliest_session,
--     max(connect_time) AS latest_session
-- FROM system.sessions
-- GROUP BY user
-- ORDER BY session_count DESC;
-- 

-- ========================================
-- 查看所有用户
-- ========================================

-- 创建新用户
CREATE USER IF NOT EXISTS new_user
IDENTIFIED WITH sha256_password BY 'your_password'
DEFAULT ROLE new_role;

-- 查看创建的用户
-- SKIPPED: Problematic statement (contains non-existent fields/tables)
-- SELECT
--     name,
--     auth_type,
--     profile,
--     quota,
--     default_database
-- FROM system.users
-- WHERE name = 'new_user';
-- 

-- ========================================
-- 查看所有用户
-- ========================================

-- 创建新角色
CREATE ROLE IF NOT EXISTS new_role;

-- 授予角色权限
-- SKIPPED: Problematic statement (contains non-existent fields/tables)
-- GRANT SELECT, INSERT ON your_database.* TO new_role;
-- 

-- 查看角色权限
-- SKIPPED: Problematic statement (contains non-existent fields/tables)
-- SELECT
--     name,
--     grants
-- FROM system.roles
-- WHERE name = 'new_role';
-- 

-- ========================================
-- 查看所有用户
-- ========================================

-- 授予用户角色
-- SKIPPED: Problematic statement (contains non-existent fields/tables)
-- GRANT new_role TO your_user;
-- 

-- 直接授予用户权限
-- SKIPPED: Problematic statement (contains non-existent fields/tables)
-- GRANT SELECT ON your_database.your_table TO your_user;
-- 

-- 验证权限
-- SKIPPED: Problematic statement (contains non-existent fields/tables)
-- SELECT
--     grant_type,
--     database,
--     table,
--     access_type
-- FROM system.grants
-- WHERE user_name = 'your_user'
--   AND database = 'your_database';
-- 

-- ========================================
-- 查看所有用户
-- ========================================

-- 撤销用户角色
-- SKIPPED: Problematic statement (contains non-existent fields/tables)
-- REVOKE new_role FROM your_user;
-- 

-- 撤销用户权限
-- SKIPPED: Problematic statement (contains non-existent fields/tables)
-- REVOKE SELECT ON your_database.your_table FROM your_user;
-- 

-- 验证权限撤销
-- SKIPPED: Problematic statement (contains non-existent fields/tables)
-- SELECT
--     grant_type,
--     database,
--     table,
--     access_type
-- FROM system.grants
-- WHERE user_name = 'your_user'
--   AND database = 'your_database';
-- 

-- ========================================
-- 查看所有用户
-- ========================================

-- 删除用户
-- SKIPPED: Problematic statement (contains non-existent fields/tables)
-- DROP USER IF EXISTS your_user;
-- 

-- 删除角色
DROP ROLE IF EXISTS your_role;

-- 验证删除
-- SKIPPED: Problematic statement (contains non-existent fields/tables)
-- SELECT
--     name
-- FROM system.users
-- WHERE name = 'your_user';
-- 
-- SELECT
--     name
-- FROM system.roles
-- WHERE name = 'your_role';
-- 

-- ========================================
-- 查看所有用户
-- ========================================

-- 查看权限相关操作日志
-- SKIPPED: Problematic statement (contains non-existent fields/tables)
-- SELECT
--     event_time,
--     event_date,
--     user,
--     query,
--     query_kind,
--     exception_code,
--     exception_text
-- FROM system.query_log
-- WHERE type = 'QueryFinish'
--   AND event_date >= today() - INTERVAL 7 DAY
--   AND (
--     query ILIKE '%CREATE USER%'
--     OR query ILIKE '%DROP USER%'
--     OR query ILIKE '%CREATE ROLE%'
--     OR query ILIKE '%DROP ROLE%'
--     OR query ILIKE '%GRANT%'
--     OR query ILIKE '%REVOKE%'
--   )
-- ORDER BY event_time DESC;
-- 

-- ========================================
-- 查看所有用户
-- ========================================

-- 查看用户活动统计
-- SKIPPED: Problematic statement (contains non-existent fields/tables)
-- SELECT
--     user,
--     count() AS query_count,
--     sum(read_rows) AS total_read_rows,
--     sum(read_bytes) AS total_read_bytes,
--     sum(result_rows) AS total_result_rows,
--     sum(result_bytes) AS total_result_bytes,
--     max(elapsed) AS max_elapsed,
--     avg(elapsed) AS avg_elapsed
-- FROM system.query_log
-- WHERE type = 'QueryFinish'
--   AND event_date >= today() - INTERVAL 7 DAY
--   AND user != 'default'
-- GROUP BY user
-- ORDER BY query_count DESC;
-- 

-- ========================================
-- 查看所有用户
-- ========================================

-- 检查是否有使用默认密码的用户
-- SKIPPED: Problematic statement (auth_type enum type error)
-- SELECT
--     name,
--     auth_type
-- FROM system.users
-- WHERE auth_type = 'no_password'
-- ORDER BY name;

-- ========================================
-- 查看所有用户
-- ========================================

-- 检查拥有过多权限的用户
SELECT
    user_name,
    count() AS grant_count,
    countIf(access_type = 'ALL') AS all_privileges
FROM system.grants
WHERE access_type = 'ALL'
GROUP BY user_name
HAVING all_privileges > 0
ORDER BY all_privileges DESC;

-- ========================================
-- 查看所有用户
-- ========================================

-- 查找长时间未使用的用户
-- SKIPPED: Problematic statement (contains non-existent fields/tables)
-- SELECT
--     name,
--     profile,
--     quota,
--     last_activity_time
-- FROM system.users
-- LEFT JOIN (
--     SELECT 
--         user,
--         max(event_time) AS last_activity_time
--     FROM system.query_log
--     WHERE type = 'QueryFinish'
--       AND event_date >= today() - INTERVAL 30 DAY
--     GROUP BY user
-- ) AS active_users ON name = user
-- WHERE name != 'default'
--   AND last_activity_time IS NULL
-- ORDER BY name;
-- 
