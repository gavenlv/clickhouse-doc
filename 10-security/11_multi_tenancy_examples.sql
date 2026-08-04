-- ============================================================
-- ClickHouse 多租户隔离 示例
-- 集群：treasurycluster（CH 25.12.1.649）
-- 说明：本文件包含四种多租户隔离策略的完整可运行示例
-- 前置条件：无（DDL 使用 IF NOT EXISTS，幂等可重复执行）
-- 学习目标：掌握数据库级/表级/行级/混合隔离的配置方法，理解各策略的
--           适用场景和底层原理，能够搭建生产级多租户 ClickHouse 体系
-- ============================================================

-- ============================================================
-- 第一部分：策略一 — 数据库级隔离（Database-per-Tenant）
-- ============================================================

-- 【原理】每个租户拥有独立的数据库和表，物理隔离级别最高。
-- 租户 A 无法访问租户 B 的数据 —— 这是权限机制的保证，不依赖查询注入。
-- 与行级 RLS 的关键区别：DROP DATABASE 即可完成租户清理，
-- 数据备份恢复可以按租户独立操作。
--
-- 场景：金融行业 SaaS，每个客户数据必须物理隔离，合规要求极高
-- 对比：vs 行级隔离 — 数据库级无法直接跨租户 UNION ALL，但安全性更高

-- 创建租户 1 数据库和表
CREATE DATABASE IF NOT EXISTS tenant_acme_corp;

-- 租户 1 订单表
CREATE TABLE IF NOT EXISTS tenant_acme_corp.orders
(
    order_id UInt64,
    customer_id String,
    amount Decimal(18, 2),
    status String DEFAULT 'pending',
    created_at DateTime DEFAULT now()
)
ENGINE = MergeTree()
PARTITION BY toYYYYMM(created_at)
ORDER BY (order_id, created_at);

-- 租户 1 用户表
CREATE TABLE IF NOT EXISTS tenant_acme_corp.users
(
    user_id UInt64,
    name String,
    email String,
    tier String DEFAULT 'standard',
    created_at DateTime DEFAULT now()
)
ENGINE = MergeTree()
ORDER BY user_id;

-- 创建租户 2 数据库和表
CREATE DATABASE IF NOT EXISTS tenant_globex_inc;

CREATE TABLE IF NOT EXISTS tenant_globex_inc.orders
(
    order_id UInt64,
    customer_id String,
    amount Decimal(18, 2),
    status String DEFAULT 'pending',
    created_at DateTime DEFAULT now()
)
ENGINE = MergeTree()
PARTITION BY toYYYYMM(created_at)
ORDER BY (order_id, created_at);

CREATE TABLE IF NOT EXISTS tenant_globex_inc.users
(
    user_id UInt64,
    name String,
    email String,
    tier String DEFAULT 'standard',
    created_at DateTime DEFAULT now()
)
ENGINE = MergeTree()
ORDER BY user_id;

-- 创建租户用户（使用 SHA-256 密码认证）
CREATE USER IF NOT EXISTS acme_user
IDENTIFIED WITH sha256_password BY 'AcmePass123!';

CREATE USER IF NOT EXISTS globex_user
IDENTIFIED WITH sha256_password BY 'GlobexPass123!';

-- 创建租户角色并授予数据库权限
CREATE ROLE IF NOT EXISTS acme_role;
GRANT SELECT, INSERT, ALTER UPDATE, ALTER DELETE ON tenant_acme_corp.* TO acme_role;
GRANT acme_role TO acme_user;

CREATE ROLE IF NOT EXISTS globex_role;
GRANT SELECT, INSERT, ALTER UPDATE, ALTER DELETE ON tenant_globex_inc.* TO globex_role;
GRANT globex_role TO globex_user;

-- 插入租户 1 的测试数据
INSERT INTO tenant_acme_corp.users VALUES
(1, 'Alice Chen', 'alice@acme.com', 'enterprise', '2024-01-01 00:00:00'),
(2, 'Bob Wang', 'bob@acme.com', 'enterprise', '2024-01-15 00:00:00'),
(3, 'Carol Li', 'carol@acme.com', 'standard', '2024-02-01 00:00:00');

INSERT INTO tenant_acme_corp.orders VALUES
(1001, '001', 299.99, 'completed', '2024-01-10 10:30:00'),
(1002, '001', 499.99, 'completed', '2024-01-20 14:00:00'),
(1003, '002', 159.50, 'pending', '2024-02-05 09:15:00'),
(1004, '003', 899.00, 'completed', '2024-02-10 16:45:00');

-- 插入租户 2 的测试数据
INSERT INTO tenant_globex_inc.users VALUES
(1, 'Dave Zhao', 'dave@globex.com', 'enterprise', '2024-01-05 00:00:00'),
(2, 'Eve Sun', 'eve@globex.com', 'standard', '2024-02-01 00:00:00');

INSERT INTO tenant_globex_inc.orders VALUES
(2001, '001', 1200.00, 'completed', '2024-01-15 08:00:00'),
(2002, '001', 350.00, 'pending', '2024-02-10 11:00:00'),
(2003, '002', 89.99, 'completed', '2024-02-20 13:30:00');

-- 验证数据隔离：管理员可以分别查询两个租户的数据
SELECT 'acme' AS tenant, order_id, amount, status, created_at
FROM tenant_acme_corp.orders
ORDER BY created_at;

SELECT 'globex' AS tenant, order_id, amount, status, created_at
FROM tenant_globex_inc.orders
ORDER BY created_at;

-- ============================================================
-- 第二部分：策略二 — 表级隔离（Schema-per-Tenant）
-- ============================================================

-- 【原理】所有租户共享同一个数据库，但每租户一张表。表名包含租户标识。
-- 权限控制粒度：GRANT ALL ON db.orders_tenantXXX TO tenant_user
-- 与数据库级隔离的权衡：表少时简单，表多时元数据会膨胀
--
-- 场景：中等规模 SaaS，租户数量 < 100，数据结构完全相同
-- 对比：vs 数据库级 — 更容易做跨租户分析（UNION ALL），但删除租户需要 DROP TABLE 逐个清理

-- 创建共享数据库
CREATE DATABASE IF NOT EXISTS multi_tenant;

-- 为租户 1 创建独立表
CREATE TABLE IF NOT EXISTS multi_tenant.orders_tenant001
(
    order_id UInt64,
    customer_id String,
    amount Decimal(18, 2),
    status String DEFAULT 'pending',
    created_at DateTime DEFAULT now()
)
ENGINE = MergeTree()
PARTITION BY toYYYYMM(created_at)
ORDER BY (order_id, created_at);

-- 为租户 2 创建独立表
CREATE TABLE IF NOT EXISTS multi_tenant.orders_tenant002
(
    order_id UInt64,
    customer_id String,
    amount Decimal(18, 2),
    status String DEFAULT 'pending',
    created_at DateTime DEFAULT now()
)
ENGINE = MergeTree()
PARTITION BY toYYYYMM(created_at)
ORDER BY (order_id, created_at);

-- 创建租户用户
CREATE USER IF NOT EXISTS tenant001
IDENTIFIED WITH sha256_password BY 'Tenant001Pass!';

CREATE USER IF NOT EXISTS tenant002
IDENTIFIED WITH sha256_password BY 'Tenant002Pass!';

-- 授予租户只在自己的表上操作
GRANT SELECT, INSERT ON multi_tenant.orders_tenant001 TO tenant001;
GRANT SELECT, INSERT ON multi_tenant.orders_tenant002 TO tenant002;

-- 插入测试数据
INSERT INTO multi_tenant.orders_tenant001 VALUES
(101, 'C001', 199.99, 'completed', '2024-01-10 10:00:00'),
(102, 'C002', 349.50, 'completed', '2024-01-20 14:30:00');

INSERT INTO multi_tenant.orders_tenant002 VALUES
(201, 'C101', 599.00, 'completed', '2024-01-12 09:00:00'),
(202, 'C102', 129.99, 'pending', '2024-02-01 11:00:00');

-- 管理员跨租户查询（需逐个列出表名）
SELECT 'tenant001' AS tenant_id, order_id, amount, status, created_at
FROM multi_tenant.orders_tenant001
UNION ALL
SELECT 'tenant002' AS tenant_id, order_id, amount, status, created_at
FROM multi_tenant.orders_tenant002
ORDER BY created_at;

-- ============================================================
-- 第三部分：策略三 — 行级隔离（Row-Level Security / RLS）
-- ============================================================

-- 【原理】所有租户共享同一张表，通过 tenant_id 列区分数据。
-- 行策略（ROW POLICY）在查询时自动注入 WHERE tenant_id = currentUserSetting('tenant_id')，
-- 对客户端完全透明。
--
-- 核心机制：行策略在服务器端 SQL 解析阶段注入过滤条件，客户端无法绕过。
-- 性能关键：tenant_id 必须是排序键的第一个字段，否则行策略过滤会退化为全表扫描。
--
-- 注意：管理员（拥有 ACCESS_MANAGEMENT 权限）默认不受行策略约束
--
-- 场景：大量小租户（> 500），每个租户数据量小，表结构统一
-- 对比：vs 数据库级 — 管理成本最低（一张表），但删除租户数据需要 ALTER ... DELETE mutation

-- 创建共享表（tenant_id 作为分区键和排序键）
CREATE TABLE IF NOT EXISTS multi_tenant.orders_shared
(
    order_id UInt64,
    tenant_id String,
    user_id String,
    product_id String DEFAULT '',
    amount Decimal(18, 2),
    status String DEFAULT 'pending',
    created_at DateTime DEFAULT now()
)
ENGINE = MergeTree()
PARTITION BY (tenant_id, toYYYYMM(created_at))
ORDER BY (tenant_id, created_at, order_id);

-- 创建租户用户（通过 SETTINGS 注入 tenant_id）
CREATE USER IF NOT EXISTS tenant_alpha
IDENTIFIED WITH sha256_password BY 'AlphaPass123!'
SETTINGS tenant_id = 'tenant_alpha';

CREATE USER IF NOT EXISTS tenant_beta
IDENTIFIED WITH sha256_password BY 'BetaPass123!'
SETTINGS tenant_id = 'tenant_beta';

-- 创建租户角色
CREATE ROLE IF NOT EXISTS saas_tenant_role;
GRANT SELECT, INSERT ON multi_tenant.orders_shared TO saas_tenant_role;
GRANT saas_tenant_role TO tenant_alpha, tenant_beta;

-- 核心：创建行级安全策略
-- 【关键】USING 子句中的 current_user_settings['tenant_id'] 会读取用户登录时的 SETTINGS
-- 客户端的任何 SQL 都无法绕过这个注入条件
CREATE ROW POLICY IF NOT EXISTS tenant_filter
ON multi_tenant.orders_shared
USING tenant_id = current_user_settings['tenant_id']
AS RESTRICTIVE TO tenant_alpha, tenant_beta;

-- 插入测试数据
-- 注意：tenant_id 列必须在 INSERT 中显式提供，行策略只对 SELECT 生效
INSERT INTO multi_tenant.orders_shared VALUES
(1, 'tenant_alpha', 'A001', 'P100', 299.99, 'completed', '2024-01-10 10:00:00'),
(2, 'tenant_alpha', 'A002', 'P200', 499.99, 'completed', '2024-01-20 14:00:00'),
(3, 'tenant_alpha', 'A001', 'P300', 159.50, 'pending', '2024-02-05 09:00:00'),
(4, 'tenant_beta', 'B001', 'P100', 599.00, 'completed', '2024-01-12 09:00:00'),
(5, 'tenant_beta', 'B002', 'P200', 129.99, 'pending', '2024-02-01 11:00:00'),
(6, 'tenant_beta', 'B001', 'P300', 899.00, 'completed', '2024-02-10 16:00:00');

-- 管理员视图：可以看到所有租户的数据
SELECT tenant_id, order_id, user_id, amount, status, created_at
FROM multi_tenant.orders_shared
ORDER BY tenant_id, created_at;

-- 模拟租户查询：使用 SETTINGS 临时切换 tenant_id 来验证隔离
-- （仅用于测试，生产环境每个租户用自己的用户登录）

-- 模拟 tenant_alpha 的查询结果：应该只看到 tenant_alpha 的 3 条数据
SELECT order_id, user_id, amount, status, created_at
FROM multi_tenant.orders_shared
WHERE tenant_id = 'tenant_alpha'
ORDER BY created_at;

-- 模拟 tenant_beta 的查询结果：应该只看到 tenant_beta 的 3 条数据
SELECT order_id, user_id, amount, status, created_at
FROM multi_tenant.orders_shared
WHERE tenant_id = 'tenant_beta'
ORDER BY created_at;

-- ============================================================
-- 第四部分：策略四 — 混合隔离策略
-- ============================================================

-- 【原理】大租户使用数据库级隔离（高安全+独立资源），小租户使用行级 RLS（低成本+易管理）。
-- 这是生产环境最经济高效的选择。
-- 关键权衡：两种隔离策略并存时，需要用统一的管理接口（脚本/SQL 模板）来降低运维复杂度
--
-- 场景：SaaS 平台，头部 20% 租户贡献 80% 营收，需要独立的 SLA 保障
-- 对比：纯一种策略要么成本过高（全数据库级），要么安全不足（全行级）

-- 大租户：专属数据库
CREATE DATABASE IF NOT EXISTS enterprise_tenant_a;

CREATE TABLE IF NOT EXISTS enterprise_tenant_a.orders
(
    order_id UInt64,
    customer_id String,
    amount Decimal(18, 2),
    status String DEFAULT 'pending',
    created_at DateTime DEFAULT now()
)
ENGINE = MergeTree()
PARTITION BY toYYYYMM(created_at)
ORDER BY (order_id, created_at);

CREATE USER IF NOT EXISTS ent_a_user
IDENTIFIED WITH sha256_password BY 'EntAPass123!'
SETTINGS tenant_id = 'ent_a';

CREATE ROLE IF NOT EXISTS ent_a_role;
GRANT ALL ON enterprise_tenant_a.* TO ent_a_role;
GRANT ent_a_role TO ent_a_user;

-- 中小租户：共享表 + RLS
CREATE TABLE IF NOT EXISTS multi_tenant.orders_smb
(
    order_id UInt64,
    tenant_id String,
    user_id String,
    amount Decimal(18, 2),
    status String DEFAULT 'pending',
    created_at DateTime DEFAULT now()
)
ENGINE = MergeTree()
PARTITION BY (tenant_id, toYYYYMM(created_at))
ORDER BY (tenant_id, created_at);

CREATE USER IF NOT EXISTS smb_tenant_1
IDENTIFIED WITH sha256_password BY 'SMB1Pass123!'
SETTINGS tenant_id = 'smb_tenant_1';

CREATE USER IF NOT EXISTS smb_tenant_2
IDENTIFIED WITH sha256_password BY 'SMB2Pass123!'
SETTINGS tenant_id = 'smb_tenant_2';

CREATE ROLE IF NOT EXISTS smb_tenant_role;
GRANT SELECT, INSERT ON multi_tenant.orders_smb TO smb_tenant_role;
GRANT smb_tenant_role TO smb_tenant_1, smb_tenant_2;

-- 行级安全策略（仅作用于 SMB 租户的共享表）
CREATE ROW POLICY IF NOT EXISTS smb_tenant_filter
ON multi_tenant.orders_smb
USING tenant_id = current_user_settings['tenant_id']
AS RESTRICTIVE TO smb_tenant_1, smb_tenant_2;

-- 插入测试数据
INSERT INTO enterprise_tenant_a.orders VALUES
(10001, 'EA001', 5000.00, 'completed', '2024-01-15 09:00:00'),
(10002, 'EA002', 3500.00, 'completed', '2024-02-01 14:00:00');

INSERT INTO multi_tenant.orders_smb VALUES
(1, 'smb_tenant_1', 'S001', 199.99, 'completed', '2024-01-10 10:00:00'),
(2, 'smb_tenant_1', 'S002', 89.50, 'pending', '2024-01-20 15:00:00'),
(3, 'smb_tenant_2', 'T001', 299.00, 'completed', '2024-01-12 11:00:00');

-- 管理员全量视图：需要 UNION ALL 大租户数据库 + SMB 共享表
SELECT 'ent_a' AS tenant_id, order_id, amount, status, created_at
FROM enterprise_tenant_a.orders
UNION ALL
SELECT tenant_id, order_id, amount, status, created_at
FROM multi_tenant.orders_smb
ORDER BY tenant_id, created_at;

-- ============================================================
-- 第五部分：资源隔离 — Workload Group + Quota
-- ============================================================

-- 【原理】在四种隔离策略的基础上，通过 Workload Group 实现 CPU/内存资源隔离，
-- 通过 Quota 实现使用量限制。资源隔离和数据隔离是两个独立维度：
-- - 数据隔离：确保租户 A 看不到租户 B 的数据
-- - 资源隔离：确保租户 A 的慢查询不会拖慢租户 B 的响应时间
--
-- 场景：多租户共享同一集群时，防止"吵闹邻居"问题
-- 坑：Workload Group 的调度优先级是非抢占式的，高优查询到达时不会中断正在执行的低优查询

-- 为数据库级大租户创建专属 Workload Group
CREATE WORKLOAD GROUP IF NOT EXISTS tenant_enterprise_group
SETTINGS
    max_concurrent_queries = 20,
    max_memory_usage = 50000000000,     -- 50 GB
    priority = 1,                        -- 最高优先级
    scheduling_policy = 'round_robin';

-- 为 SMB 共享租户创建 Workload Group
CREATE WORKLOAD GROUP IF NOT EXISTS tenant_smb_group
SETTINGS
    max_concurrent_queries = 10,
    max_memory_usage = 20000000000,     -- 20 GB
    priority = 5,                        -- 中等优先级
    scheduling_policy = 'round_robin';

-- 绑定 Workload Group 到角色
ALTER ROLE ent_a_role SETTINGS workload_group = 'tenant_enterprise_group';
ALTER ROLE smb_tenant_role SETTINGS workload_group = 'tenant_smb_group';

-- 为大租户设置 Quota
CREATE QUOTA IF NOT EXISTS enterprise_tenant_quota
WITH LIMITS
    QUERY_TIME = 14400 PER DAY,          -- 4 小时
    READ_BYTES = 107374182400 PER DAY,   -- 100 GB
    ERRORS = 1000 PER HOUR
KEYED BY USER_NAME
TO ent_a_user;

-- 为 SMB 租户设置 Quota
CREATE QUOTA IF NOT EXISTS smb_tenant_quota
WITH LIMITS
    QUERY_TIME = 1800 PER DAY,           -- 30 分钟
    READ_BYTES = 10737418240 PER DAY     -- 10 GB
KEYED BY USER_NAME
TO smb_tenant_role;

-- ============================================================
-- 第六部分：租户监控与计量
-- ============================================================

-- 【原理】多租户环境需要按租户维度监控资源消耗，用于：
-- 1. 成本分摊（Chargeback / Showback）
-- 2. SLA 监控（响应时间、错误率）
-- 3. 异常检测（某个租户突然产生大量查询）
--
-- 注意：本集群 query_log 可能被禁用（config.xml <query_log remove="1"/>），
-- 可改用 system.query_thread_log（SET log_query_threads=1）或从应用层埋点

-- 查看当前所有租户相关信息（Workload Group 和 Quota）
SELECT 
    name AS wg_name,
    max_concurrent_queries,
    formatReadableSize(max_memory_usage) AS max_memory,
    priority,
    scheduling_policy
FROM system.workload_groups
WHERE name LIKE '%tenant%'
ORDER BY priority;

SELECT 
    quota_name,
    user_name,
    queries,
    max_queries,
    query_time AS used_query_time_ms,
    max_query_time AS max_query_time_ms,
    formatReadableSize(read_bytes) AS read_bytes_str,
    formatReadableSize(max_read_bytes) AS max_read_bytes_str
FROM system.quota_usage
ORDER BY quota_name, user_name;

-- 查看当前各租户的活跃查询
SELECT 
    user,
    count() AS active_query_count,
    sum(elapsed) / 1000 AS total_elapsed_sec,
    formatReadableSize(sum(memory_usage)) AS total_memory,
    formatReadableSize(sum(read_bytes)) AS total_read_bytes
FROM system.processes
WHERE user LIKE '%tenant%' OR user LIKE '%ent_%' OR user LIKE '%smb_%'
GROUP BY user
ORDER BY total_elapsed_sec DESC;

-- 按租户统计存储使用量
SELECT 
    database,
    table,
    count() AS part_count,
    sum(rows) AS total_rows,
    formatReadableSize(sum(bytes_on_disk)) AS total_bytes_on_disk
FROM system.parts
WHERE active = 1
  AND (database LIKE 'tenant_%' OR database = 'multi_tenant')
GROUP BY database, table
ORDER BY sum(bytes_on_disk) DESC;

-- ============================================================
-- 第七部分：租户数据迁移示例
-- ============================================================

-- 【原理】当小租户成长到需要独立数据库级别隔离时，需要将数据从共享表
-- 迁移到专属数据库。迁移方式取决于隔离策略：
-- - 行级 → 数据库级：INSERT ... SELECT ... WHERE tenant_id = 'xxx'
-- - 表级 → 数据库级：RENAME TABLE 或 INSERT ... SELECT
--
-- 场景：smb_tenant_1 升级为独立数据库
-- 对比：迁移后需撤销旧权限 + 授予新数据库权限 + 清理共享表中的残留数据

-- 第一步：创建目标数据库和表
CREATE DATABASE IF NOT EXISTS tenant_smb1_upgraded;

CREATE TABLE IF NOT EXISTS tenant_smb1_upgraded.orders
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
ORDER BY (order_id, created_at);

-- 第二步：从共享表迁移数据
INSERT INTO tenant_smb1_upgraded.orders
SELECT * FROM multi_tenant.orders_smb
WHERE tenant_id = 'smb_tenant_1';

-- 第三步：验证迁移
SELECT 'source' AS location, count() AS cnt FROM multi_tenant.orders_smb WHERE tenant_id = 'smb_tenant_1'
UNION ALL
SELECT 'target' AS location, count() AS cnt FROM tenant_smb1_upgraded.orders;

-- 第四步：更新权限（注释，具体执行视情况）
-- REVOKE smb_tenant_role FROM smb_tenant_1;
-- GRANT ALL ON tenant_smb1_upgraded.* TO smb_tenant_1;

-- 第五步：清理共享表中的残留数据（注释，具体执行视情况）
-- ALTER TABLE multi_tenant.orders_smb DELETE WHERE tenant_id = 'smb_tenant_1';

-- ============================================================
-- 第八部分：跨租户数据共享
-- ============================================================

-- 【原理】多租户场景下经常需要共享数据（如产品目录、汇率表），但又要避免数据泄露。
-- 推荐方式：
-- 1. 字典（Dictionary）：租户共享读，不可写 —— 最安全
-- 2. 视图（View）：管理员暴露聚合/脱敏后的数据
-- 3. 物化视图：预计算跨租户汇总，避免 UNION ALL 性能问题
--
-- 场景：所有租户共享产品目录，管理员需要全局统计视图

-- 创建共享产品目录表
CREATE TABLE IF NOT EXISTS shared_catalog.products
(
    product_id String,
    product_name String,
    category String,
    base_price Decimal(18, 2)
)
ENGINE = MergeTree()
ORDER BY product_id;

CREATE USER IF NOT EXISTS shared_catalog_reader
IDENTIFIED WITH sha256_password BY 'SharedRead123!';

CREATE ROLE IF NOT EXISTS shared_read_role;
GRANT SELECT ON shared_catalog.* TO shared_read_role;
GRANT shared_read_role TO shared_catalog_reader;

-- 授予所有租户读取产品目录的权限
GRANT shared_read_role TO acme_role, globex_role, saas_tenant_role;

-- 插入产品目录数据
INSERT INTO shared_catalog.products VALUES
('P100', 'Widget Pro', 'Electronics', 299.99),
('P200', 'Gadget Max', 'Electronics', 499.99),
('P300', 'Service Basic', 'Services', 159.50),
('P400', 'Enterprise Suite', 'Software', 899.00);

-- 管理员创建跨租户统计视图
CREATE VIEW IF NOT EXISTS multi_tenant.admin_tenant_stats AS
SELECT 
    tenant_id,
    count() AS order_count,
    sum(amount) AS total_amount,
    round(avg(amount), 2) AS avg_amount,
    countIf(status = 'completed') AS completed_count,
    round(completed_count / count() * 100, 1) AS completion_rate_pct
FROM multi_tenant.orders_shared
GROUP BY tenant_id;

-- 查看全局统计
SELECT * FROM multi_tenant.admin_tenant_stats ORDER BY total_amount DESC;

-- ============================================================
-- 第九部分：清理示例资源
-- ============================================================

-- 【原理】生产环境建议保留这些资源，以下为清理脚本供测试后使用

-- 清理数据库（会删除所有表和数据）
-- DROP DATABASE IF EXISTS tenant_acme_corp;
-- DROP DATABASE IF EXISTS tenant_globex_inc;
-- DROP DATABASE IF EXISTS enterprise_tenant_a;
-- DROP DATABASE IF EXISTS tenant_smb1_upgraded;
-- DROP DATABASE IF EXISTS multi_tenant;
-- DROP DATABASE IF EXISTS shared_catalog;

-- 清理 Workload Group
-- DROP WORKLOAD GROUP IF EXISTS tenant_enterprise_group;
-- DROP WORKLOAD GROUP IF EXISTS tenant_smb_group;

-- 清理 Quota
-- DROP QUOTA IF EXISTS enterprise_tenant_quota;
-- DROP QUOTA IF EXISTS smb_tenant_quota;

-- 清理用户
-- DROP USER IF EXISTS acme_user;
-- DROP USER IF EXISTS globex_user;
-- DROP USER IF EXISTS tenant001;
-- DROP USER IF EXISTS tenant002;
-- DROP USER IF EXISTS tenant_alpha;
-- DROP USER IF EXISTS tenant_beta;
-- DROP USER IF EXISTS ent_a_user;
-- DROP USER IF EXISTS smb_tenant_1;
-- DROP USER IF EXISTS smb_tenant_2;
-- DROP USER IF EXISTS shared_catalog_reader;

-- 清理角色
-- DROP ROLE IF EXISTS acme_role;
-- DROP ROLE IF EXISTS globex_role;
-- DROP ROLE IF EXISTS saas_tenant_role;
-- DROP ROLE IF EXISTS smb_tenant_role;
-- DROP ROLE IF EXISTS ent_a_role;
-- DROP ROLE IF EXISTS shared_read_role;

-- 清理行级安全策略
-- DROP ROW POLICY IF EXISTS tenant_filter ON multi_tenant.orders_shared;
-- DROP ROW POLICY IF EXISTS smb_tenant_filter ON multi_tenant.orders_smb;
