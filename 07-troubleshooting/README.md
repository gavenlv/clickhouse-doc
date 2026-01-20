# ClickHouse 故障排查指南

本目录包含 ClickHouse 常见问题及解决方案。

## 目录结构

```
07-troubleshooting/
├── README.md                      # 故障排查总览
├── 01_connection_issues.md        # 连接问题
├── 02_performance_issues.md       # 性能问题
├── 03_storage_issues.md          # 存储问题
├── 04_replication_issues.md      # 复制问题
├── 05_query_issues.md            # 查询问题
├── 06_startup_issues.md          # 启动问题
├── 07_upgrade_issues.md          # 升级问题
├── 08_data_consistency.md        # 数据一致性问题
├── 09_resource_issues.md         # 资源问题
└── 10_common_errors.md           # 常见错误码
```

## 故障排查流程

```
发现问题
    ↓
确定问题类别
    ↓
查阅对应指南
    ↓
应用解决方案
    ↓
验证恢复
```

## 快速诊断

### 第一步：健康检查

```sql
-- 执行健康检查
SELECT
    'Replica Status' as check_type,
    sum(absolute_delay > 0) as delayed_replicas,
    sum(is_session_expired = 1) as expired_replicas
FROM system.replicas
UNION ALL
SELECT
    'Disk Status',
    sum(free_space / total_space < 0.2),
    sum(free_space / total_space < 0.1)
FROM system.disks
UNION ALL
SELECT
    'Merge Status',
    sum(count(*) > 20),
    sum(count(*) > 50)
FROM (
    SELECT count(*) as cnt
    FROM system.parts
    WHERE active = 1
    GROUP BY database, table
)
UNION ALL
SELECT
    'Query Status',
    sum(query_duration_ms > 5000),
    sum(query_duration_ms > 10000)
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_time > now() - INTERVAL 1 DAY;
```

### 第二步：查看错误日志

```sql
-- 查看最近的错误
SELECT
    event_time,
    level,
    logger_name,
    message
FROM system.text_log
WHERE level IN ('Error', 'Critical')
  AND event_time > now() - INTERVAL 1 HOUR
ORDER BY event_time DESC
LIMIT 50;
```

## 问题分类

### 1. 连接问题

- 无法连接到 ClickHouse
- 连接超时
- 认证失败

**参考**: [01_connection_issues.md](./01_connection_issues.md)

### 2. 性能问题

- 查询缓慢
- 写入缓慢
- CPU 使用率高

**参考**: [02_performance_issues.md](./02_performance_issues.md)

### 3. 存储问题

- 磁盘空间不足
- 数据损坏
- 分区错误

**参考**: [03_storage_issues.md](./03_storage_issues.md)

### 4. 复制问题

- 副本同步延迟
- 副本不一致
- 复制失败

**参考**: [04_replication_issues.md](./04_replication_issues.md)

### 5. 查询问题

- 查询错误
- 语法错误
- 结果错误

**参考**: [05_query_issues.md](./05_query_issues.md)

### 6. 启动问题

- ClickHouse 无法启动
- 配置错误
- 依赖缺失

**参考**: [06_startup_issues.md](./06_startup_issues.md)

### 7. 升级问题

- 升级失败
- 兼容性问题
- 数据迁移问题

**参考**: [07_upgrade_issues.md](./07_upgrade_issues.md)

### 8. 数据一致性问题

- 数据丢失
- 数据重复
- 数据错误

**参考**: [08_data_consistency.md](./08_data_consistency.md)

### 9. 资源问题

- 内存不足
- CPU 满载
- 网络问题

**参考**: [09_resource_issues.md](./09_resource_issues.md)

### 10. 常见错误码

- 解释常见错误码
- 提供解决方案

**参考**: [10_common_errors.md](./10_common_errors.md)

## 应急响应

### 严重等级

| 等级 | 描述 | 响应时间 | 恢复目标 |
|------|------|----------|----------|
| **P0** | 集群完全不可用 | 5 分钟 | 30 分钟 |
| **P1** | 部分功能不可用 | 15 分钟 | 2 小时 |
| **P2** | 性能严重下降 | 30 分钟 | 4 小时 |
| **P3** | 潜在风险 | 2 小时 | 24 小时 |

### 应急步骤

1. **P0/P1 级别**：
   - 立即通知相关人员
   - 切换到备用系统（如果可用）
   - 执行故障恢复
   - 记录事件

2. **P2/P3 级别**：
   - 评估影响范围
   - 制定恢复计划
   - 执行恢复操作
   - 监控恢复进度

## 诊断工具

### 系统表

| 表名 | 用途 |
|------|------|
| `system.clusters` | 集群配置 |
| `system.replicas` | 副本状态 |
| `system.merges` | 合并任务 |
| `system.processes` | 当前查询 |
| `system.query_log` | 查询日志 |
| `system.text_log` | 文本日志 |
| `system.disks` | 磁盘信息 |
| `system.zookeeper` | ZK 状态 |

### 常用查询

```sql
-- 查看当前查询
SELECT * FROM system.processes;

-- 查看慢查询
SELECT
    query_duration_ms,
    query,
    read_rows
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query_duration_ms > 1000
ORDER BY query_duration_ms DESC;

-- 查看磁盘使用
SELECT
    name,
    formatReadableSize(free_space) as free,
    formatReadableSize(total_space) as total
FROM system.disks;
```

## 获取帮助

如果以上方案都无法解决问题：

1. 收集日志信息：
   ```bash
   docker-compose logs > logs.txt
   ```

2. 检查系统资源：
   ```bash
   docker stats
   ```

3. 查阅官方文档：
   - [ClickHouse 文档](https://clickhouse.com/docs)
   - [故障排查指南](https://clickhouse.com/docs/en/operations/troubleshooting)

4. 社区支持：
   - [GitHub Issues](https://github.com/ClickHouse/ClickHouse/issues)
   - [Slack 社区](https://clickhouse.com/slack)

---

**最后更新**: 2026-01-19
**适用版本**: ClickHouse 23.x+
**集群名称**: treasurycluster
