# ClickHouse 运维管理指南

本目录包含 ClickHouse 集群的运维管理文档和脚本。

## 📁 目录结构

### 📖 运维指南

| 文档 | 描述 | 适用场景 |
|------|------|----------|
| [CLUSTER_ADMIN_GUIDE.md](./CLUSTER_ADMIN_GUIDE.md) | 集群管理指南 | 日常运维、状态监控、节点管理 |
| [TROUBLESHOOTING_GUIDE.md](./TROUBLESHOOTING_GUIDE.md) | 故障排查指南 | 问题诊断、错误分析、故障恢复 |
| [MONITORING_ALERTING_GUIDE.md](./MONITORING_ALERTING_GUIDE.md) | 监控告警指南 | 指标采集、告警配置、监控方案 |
| [BACKUP_RECOVERY_GUIDE.md](./BACKUP_RECOVERY_GUIDE.md) | 备份恢复指南 | 数据备份、灾难恢复、容灾方案 |
| [PERFORMANCE_TUNING_GUIDE.md](./PERFORMANCE_TUNING_GUIDE.md) | 性能调优指南 | 查询优化、存储优化、配置调优 |
| [ROUTINE_MAINTENANCE_GUIDE.md](./ROUTINE_MAINTENANCE_GUIDE.md) | 日常维护指南 | 定期维护、清理操作、健康检查 |
| [CAPACITY_PLANNING_GUIDE.md](./CAPACITY_PLANNING_GUIDE.md) | 容量规划指南 | 资源评估、扩容方案、容量预测 |
| [UPGRADE_GUIDE.md](./UPGRADE_GUIDE.md) | 版本升级指南 | 版本升级、兼容性检查、回滚方案 |
| [EMERGENCY_RESPONSE_GUIDE.md](./EMERGENCY_RESPONSE_GUIDE.md) | 应急响应指南 | 紧急故障处理、事故响应、灾备切换 |

### 🔧 SQL 脚本

| 脚本 | 描述 | 使用方式 |
|------|------|----------|
| [cluster_admin.sql](./cluster_admin.sql) | 集群管理 SQL | 直接执行查询和管理操作 |
| [monitoring.sql](./monitoring.sql) | 监控指标 SQL | 定期采集监控数据 |
| [maintenance.sql](./maintenance.sql) | 维护操作 SQL | 执行定期维护任务 |
| [diagnostics.sql](./diagnostics.sql) | 诊断检查 SQL | 故障诊断和健康检查 |

## 🚀 快速开始

### 1. 集群健康检查

```bash
# 执行快速健康检查
cd admin
psql -h localhost -p 9000 -u default < diagnostics.sql
```

### 2. 监控关键指标

```sql
-- 查看集群整体状态
SELECT * FROM cluster_overview();

-- 检查副本延迟
SELECT * FROM replica_delay_alert();

-- 监控磁盘使用
SELECT * FROM disk_usage_monitoring();
```

### 3. 执行日常维护

```bash
# 查看维护任务
cat ROUTINE_MAINTENANCE_GUIDE.md

# 执行清理脚本
psql -h localhost -p 9000 -u default < maintenance.sql
```

## 📋 运维检查清单

### 每日检查

- [ ] 集群节点状态正常
- [ ] 副本同步无延迟
- [ ] 磁盘空间充足（>20%）
- [ ] ZooKeeper/Keeper 连接正常
- [ ] 无报错日志

### 每周检查

- [ ] 查询性能趋势
- [ ] 数据增长趋势
- [ ] 合并任务积压情况
- [ ] 索引使用情况
- [ ] 备份完整性验证

### 每月检查

- [ ] 容量评估
- [ ] 性能基准测试
- [ ] 安全审计
- [ ] 配置优化建议
- [ ] 灾备演练

### 季度检查

- [ ] 版本更新评估
- [ ] 架构优化建议
- [ ] 成本优化
- [ ] 灾备演练

## 🔍 故障排查流程

```
发现问题
    ↓
执行诊断脚本 (diagnostics.sql)
    ↓
查阅故障排查指南 (TROUBLESHOOTING_GUIDE.md)
    ↓
确定问题类型
    ↓
执行相应解决方案
    ↓
验证恢复
    ↓
更新知识库
```

## 📊 监控体系

### 核心指标

| 类别 | 指标 | 告警阈值 | 处理建议 |
|------|------|----------|----------|
| **可用性** | 节点在线率 | < 100% | 立即检查节点状态 |
| **性能** | 查询延迟 | > 5s | 分析慢查询日志 |
| **复制** | 副本延迟 | > 60s | 检查网络和负载 |
| **存储** | 磁盘使用率 | > 80% | 清理数据或扩容 |
| **内存** | 内存使用率 | > 90% | 优化查询或扩容 |
| **队列** | 合并积压 | > 50 | 调整合并参数 |

## 🛡️ 应急响应

### 严重等级

| 等级 | 描述 | 响应时间 | 恢复目标 |
|------|------|----------|----------|
| P0 | 集群完全不可用 | 5 分钟 | 30 分钟 |
| P1 | 部分功能不可用 | 15 分钟 | 2 小时 |
| P2 | 性能严重下降 | 30 分钟 | 4 小时 |
| P3 | 潜在风险 | 2 小时 | 24 小时 |

### 应急联系

- 运维负责人：[联系方式]
- 开发负责人：[联系方式]
- 技术支持：[联系方式]

## 📚 相关资源

### 官方文档

- [ClickHouse 官方文档](https://clickhouse.com/docs)
- [ClickHouse GitHub](https://github.com/ClickHouse/ClickHouse)
- [ClickHouse 社区](https://clickhouse.com/blog)

### 内部资源

- [主项目 README](../../README.md)
- [基础设施文档](../README.md)
- [健康检查指南](../healthcheck/README.md)

## 📝 变更记录

| 日期 | 版本 | 变更内容 | 作者 |
|------|------|----------|------|
| 2026-01-19 | 1.0.0 | 初始版本，创建运维管理框架 | AI Assistant |

---

**维护者**: ClickHouse 运维团队
**最后更新**: 2026-01-19
**版本**: 1.0.0
