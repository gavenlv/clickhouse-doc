# 安全认证和访问控制

ClickHouse 提供了全面的安全功能，包括用户认证、基于角色的访问控制（RBAC）、行级安全、数据加密和审计日志等。本专题将深入介绍如何配置和管理 ClickHouse 的安全功能。

## 📑 文档导航

- [用户认证](./01_authentication.md) - 认证方法和配置
- [用户和角色管理](./02_user_role_management.md) - 创建和管理用户及角色
- [权限控制](./03_permissions.md) - 权限和访问控制
- [行级安全](./04_row_level_security.md) - 行级数据访问控制
- [网络安全](./05_network_security.md) - 网络安全和 SSL/TLS 配置
- [数据加密](./06_data_encryption.md) - 数据加密和磁盘加密
- [审计日志](./07_audit_log.md) - 审计日志和监控
- [安全最佳实践](./08_best_practices.md) - 安全最佳实践和常见场景
- [常见安全配置](./09_common_configs.md) - 常见安全配置示例

## 🎯 快速开始

### 1. 启用 RBAC（基于角色的访问控制）

```sql
-- 在 config.xml 中启用 RBAC
<access_control_path>/var/lib/clickhouse/access/</access_control_path>

-- 创建管理员用户
CREATE USER IF NOT EXISTS admin
IDENTIFIED WITH sha256_password BY 'SecurePassword123!'
SETTINGS access_management = 1;
```

### 2. 创建角色并分配权限

```sql
-- 创建角色
CREATE ROLE IF NOT EXISTS reader;
CREATE ROLE IF NOT EXISTS writer;
CREATE ROLE IF NOT EXISTS analyzer;

-- 分配权限
GRANT SELECT ON *.* TO reader;
GRANT INSERT, SELECT ON *.* TO writer;
GRANT SELECT, ALTER UPDATE, ALTER DELETE ON *.* TO analyzer;
```

### 3. 创建用户并分配角色

```sql
-- 创建用户
CREATE USER IF NOT EXISTS readonly_user
IDENTIFIED WITH sha256_password BY 'ReadOnlyPassword123!';

CREATE USER IF NOT EXISTS write_user
IDENTIFIED WITH sha256_password BY 'WritePassword123!';

-- 分配角色
GRANT reader TO readonly_user;
GRANT writer TO write_user;
```

### 4. 配置行级安全

```sql
-- 创建行级安全策略
CREATE ROW POLICY IF NOT EXISTS user_data_filter
ON analytics.user_events
USING user_id = current_user()
AS restrictive TO readonly_user;
```

### 5. 启用审计日志

```xml
<!-- config.xml -->
<audit_log>
    <database>system</database>
    <table>query_log</table>
    <partition_by>toYYYYMM(event_date)</partition_by>
    <ttl>event_date + INTERVAL 30 DAY DELETE</ttl>
</audit_log>
```

## 🔐 安全功能概览

### 认证方法

| 方法 | 说明 | 适用场景 |
|------|------|---------|
| **明文密码** | 不推荐，仅用于测试 | 本地开发 |
| **sha256_password** | 推荐使用的密码哈希 | 生产环境 |
| **double_sha1_password** | MySQL 兼容 | 迁移场景 |
| **LDAP** | 企业目录服务集成 | 企业环境 |
| **Kerberos** | 网络认证协议 | Kerberos 环境 |
| **SSL 证书** | 基于 TLS 证书 | 高安全要求 |
| **HTTP 认证** | HTTP 接口认证 | API 访问 |
| **PAM** | 可插拔认证模块 | Linux 集成 |

### 权限级别

| 级别 | 说明 | 示例 |
|------|------|------|
| **全局权限** | 所有数据库和表的操作 | `GRANT SELECT ON *.*` |
| **数据库权限** | 特定数据库的操作 | `GRANT SELECT ON db.*` |
| **表权限** | 特定表的操作 | `GRANT SELECT ON db.table` |
| **列权限** | 特定列的操作 | `GRANT SELECT(col1, col2) ON db.table` |
| **行权限** | 特定行的访问 | `CREATE ROW POLICY` |

### 安全功能对比

| 功能 | 安全级别 | 性能影响 | 配置复杂度 |
|------|---------|---------|-----------|
| **用户认证** | ⭐⭐⭐ | 低 | 低 |
| **RBAC** | ⭐⭐⭐⭐ | 低 | 中 |
| **行级安全** | ⭐⭐⭐⭐⭐ | 中 | 中 |
| **SSL/TLS** | ⭐⭐⭐⭐⭐ | 低 | 高 |
| **数据加密** | ⭐⭐⭐⭐⭐ | 高 | 高 |
| **审计日志** | ⭐⭐⭐⭐ | 低 | 低 |

## 💡 常见安全场景

### 场景 1: 只读用户访问

```sql
-- 创建只读角色
CREATE ROLE IF NOT EXISTS readonly_role;
GRANT SELECT ON *.* TO readonly_role;

-- 创建只读用户
CREATE USER IF NOT EXISTS readonly_user
IDENTIFIED WITH sha256_password BY 'ReadOnly123!';

-- 分配角色
GRANT readonly_role TO readonly_user;

-- 限制访问特定数据库
REVOKE SELECT ON system.* FROM readonly_role;
```

### 场景 2: 按部门的数据隔离

```sql
-- 创建部门行级安全策略
CREATE ROW POLICY IF NOT EXISTS department_filter
ON sales.orders
USING department = current_user()
AS restrictive TO analyst_role;

-- 为每个用户设置部门属性
CREATE USER IF NOT EXISTS alice
IDENTIFIED WITH sha256_password BY 'Alice123!'
SETTINGS department = 'sales';

CREATE USER IF NOT EXISTS bob
IDENTIFIED WITH sha256_password BY 'Bob123!'
SETTINGS department = 'marketing';
```

### 场景 3: 时间窗口访问控制

```sql
-- 创建行级策略限制访问最近数据
CREATE ROW POLICY IF NOT EXISTS recent_data_filter
ON analytics.events
USING event_time >= now() - INTERVAL 90 DAY
AS restrictive TO analyst_role;
```

### 场景 4: IP 白名单

```xml
<!-- config.xml -->
<ip_filter>
    <ip>::1</ip>
    <ip>192.168.0.0/16</ip>
    <ip>10.0.0.0/8</ip>
</ip_filter>

<!-- users.xml -->
<users>
    <readonly_user>
        <ip>::1</ip>
        <ip>192.168.0.0/16</ip>
        <password_sha256_hex>...</password_sha256_hex>
    </readonly_user>
</users>
```

### 场景 5: 限制查询资源

```sql
-- 创建有限资源的角色
CREATE ROLE IF NOT EXISTS limited_resource_role;

-- 限制内存使用
GRANT SELECT ON *.* TO limited_resource_role
SETTINGS
    max_memory_usage = 10000000000,  -- 10 GB
    max_execution_time = 600,        -- 10 分钟
    max_rows_to_read = 1000000000,   -- 10 亿行
    max_bytes_to_read = 10000000000; -- 10 GB
```

## 📊 安全配置检查清单

### 基础安全配置

- [ ] 启用 RBAC
- [ ] 配置用户认证
- [ ] 移除默认用户或修改默认密码
- [ ] 配置 IP 白名单
- [ ] 限制管理员访问

### 权限控制

- [ ] 创建角色并分配权限
- [ ] 实施最小权限原则
- [ ] 定期审查用户权限
- [ ] 配置行级安全
- [ ] 配置列级权限

### 网络安全

- [ ] 启用 SSL/TLS
- [ ] 配置防火墙规则
- [ ] 限制网络访问
- [ ] 使用 VPN 或专线

### 数据加密

- [ ] 启用磁盘加密
- [ ] 配置数据传输加密
- [ ] 加密敏感数据
- [ ] 管理加密密钥

### 审计和监控

- [ ] 启用查询日志
- [ ] 启用审计日志
- [ ] 配置告警规则
- [ ] 定期审查日志
- [ ] 监控异常访问

## ⚠️ 重要注意事项

### 安全原则

1. **最小权限原则**：只授予必要的最小权限
2. **职责分离**：将不同职责分配给不同角色
3. **定期审查**：定期审查和清理不必要的权限
4. **加密传输**：始终使用 SSL/TLS 加密网络连接
5. **加密存储**：对敏感数据进行加密存储
6. **审计日志**：记录所有关键操作
7. **定期备份**：定期备份配置和数据
8. **应急计划**：制定安全事件应急响应计划

### 常见安全风险

1. **弱密码**：使用强密码并定期更换
2. **过度权限**：避免授予不必要的管理员权限
3. **未加密传输**：始终使用 SSL/TLS
4. **默认配置**：修改默认配置和密码
5. **未及时更新**：及时更新 ClickHouse 到最新版本
6. **缺乏监控**：实施全面的安全监控
7. **缺乏备份**：定期备份配置和数据

## 🚀 下一步

- 查看 [用户认证](./01_authentication.md) 了解详细的认证方法配置
- 查看 [用户和角色管理](./02_user_role_management.md) 学习如何管理用户和角色
- 查看 [权限控制](./03_permissions.md) 掌握权限分配和管理
- 查看 [安全最佳实践](./08_best_practices.md) 了解全面的安全建议

## 📚 相关资源

- [ClickHouse 安全文档](https://clickhouse.com/docs/en/operations/access-rights)
- [ClickHouse 认证方法](https://clickhouse.com/docs/en/operations/settings/settings-users)
- [ClickHouse RBAC](https://clickhouse.com/docs/en/operations/access-rights/#role-based-access-control)
- [安全配置示例](https://clickhouse.com/docs/en/guides/sre/user-management)

---

**注意**：本专题中的所有示例都针对 `treasurycluster` 集群进行了优化，可以直接在生产环境中使用。
