# ClickHouse 故障排查专家指南

> **适用版本**: ClickHouse 20.x - 24.x  
> **集群名称**: treasurycluster (2 副本)  
> **最后更新**: 2026-08-03  

---

## 目录结构

```
07-troubleshooting/
├── README.md                          # 故障排查总览（专家指南）
├── 01_connection_issues.md            # 连接问题（Markdown 详解）
├── 02_performance_issues.md           # 性能问题（Markdown 详解）
├── 03_storage_issues.sql              # 存储故障（磁盘/Part损坏/压缩/目录结构）
├── 04_replication_issues.sql          # 复制故障（滞后/ZK/裂脑/队列卡住）
├── 05_query_issues.sql                # 查询故障（语法/超时/OOM/类型/索引）
├── 06_startup_issues.sql              # 启动故障（配置/端口/权限/Keeper）
├── 07_upgrade_issues.sql              # 升级故障（兼容/格式/配置废弃/回滚）
├── 08_data_consistency.sql            # 数据一致性（校验/修复/主从对比）
├── 09_resource_issues.sql             # 资源问题（CPU/内存/磁盘IO/网络）
├── 10_common_errors.sql               # 常见错误码（40/60/117/.../1010）
└── 11_flamegraph.sql                  # 火焰图与性能诊断（trace_log/采样）
```

---

## 故障排查方法论

### 1. 故障分级响应

| 等级 | 定义 | 响应时间 | 恢复目标 | 典型场景 |
|------|------|----------|----------|----------|
| **P0** | 集群完全不可用 | 5 min | 30 min | 全部节点宕机、数据目录损坏 |
| **P1** | 核心功能受损 | 15 min | 2 h | 写入完全阻塞、半数副本不可用 |
| **P2** | 性能严重下降 | 30 min | 4 h | 查询延迟 > 10x、复制延迟 > 1h |
| **P3** | 潜在风险 | 2 h | 24 h | 磁盘使用率 > 80%、部分慢查询 |

### 2. 标准化排查流程

```
发现异常指标/告警
    ↓
1. 确认影响范围：集群级别？节点级别？表级别？
    ↓
2. 收集现场信息：
   - 错误日志：system.text_log (Error/Critical)
   - 查询日志：system.query_log (ExceptionBeforeFinish)
   - 系统状态：system.metrics, system.asynchronous_metrics
    ↓
3. 对照故障特征定位到具体文件
    ↓
4. 执行诊断 SQL → 分析结果 → 执行修复
    ↓
5. 验证恢复：重复诊断步骤确认指标正常
    ↓
6. 记录事件：时间线、根因、修复步骤、改进措施
```

### 3. 快速诊断入口

```sql
-- 一键健康检查
SELECT 'Replica Status' AS check_type,
       sum(absolute_delay > 0) AS delayed,
       sum(is_session_expired = 1) AS expired
FROM system.replicas
UNION ALL
SELECT 'Disk Status',
       sum(free_space / total_space < 0.2),
       sum(free_space / total_space < 0.1)
FROM system.disks
UNION ALL
SELECT 'Part Count',
       sum(cnt > 50), sum(cnt > 100)
FROM (SELECT count(*) AS cnt FROM system.parts WHERE active = 1 GROUP BY database, table)
UNION ALL
SELECT 'Slow Queries (5s+)',
       sum(query_duration_ms > 5000),
       sum(query_duration_ms > 10000)
FROM system.query_log
WHERE type = 'QueryFinish' AND event_time > now() - INTERVAL 1 DAY;

-- 查看最近错误
SELECT event_time, level, logger_name, message
FROM system.text_log
WHERE level IN ('Error', 'Critical') AND event_time > now() - INTERVAL 1 HOUR
ORDER BY event_time DESC LIMIT 50;
```

---

## 专题导航

### 01 — 连接问题 [Markdown 文档](./01_connection_issues.md)

涵盖：无法连接、连接超时、认证失败、SSL/TLS、IPv6 连接问题。

**关键系统表**: `system.users`, `system.settings`  
**关键配置**: `connect_timeout`, `receive_timeout`, `send_timeout`, `listen_host`

---

### 02 — 性能问题 [Markdown 文档](./02_performance_issues.md)

涵盖：查询缓慢、写入缓慢、CPU 高、内存不足、合并积压。

**关键系统表**: `system.processes`, `system.query_log`, `system.merges`, `system.parts`  
**关键配置**: `max_threads`, `max_memory_usage`, `background_pool_size`

---

### 03 — 存储故障 [SQL 脚本](./03_storage_issues.sql)

| 专题 | 原理 | 诊断 | 修复 |
|------|------|------|------|
| 磁盘空间不足 | 磁盘使用率 > 90% 自动暂停合并 | `system.disks` | TTL/扩容/分层存储 |
| Part 损坏 | 校验和错误 (Code: 40) | `CHECK TABLE`, `system.text_log` | DETACH + ATTACH / 从副本恢复 |
| 压缩问题 | 压缩比 < 2 或 CPU 过高 | `system.columns` (ratio) | 修改 CODEC / 重写数据 |
| 数据目录结构 | metadata/data/detached 目录异常 | `system.tables`, `system.detached_parts` | 重建 metadata / 清理 detached |

**版本对比**: v21.x 需手动校验 → v22.3+ 自动检测 → v23.8+ CHECK TABLE → v24.x 在线修复

---

### 04 — 复制故障 [SQL 脚本](./04_replication_issues.sql)

| 专题 | 原理 | 诊断 | 修复 |
|------|------|------|------|
| 副本滞后 | absolute_delay 持续增大 | `system.replicas` | 增加回放线程 / 优化网络 |
| ZK/Keeper 连接 | 会话过期/连接丢失 | `system.zookeeper_connection` | 调整 session_timeout / 重启 Keeper |
| 复制队列卡住 | 任务阻塞后续操作 | `system.replication_queue` | SYSTEM RESTART REPLICA |
| 裂脑 (Split Brain) | 多 leader 同时写入 | `system.replicas.is_leader` | 移除错误副本路径 |

**版本对比**: v21.x ZK 复制 → v22.3+ ClickHouse Keeper → v23.3+ 并行回放 → v24.x 多线程复制

---

### 05 — 查询故障 [SQL 脚本](./05_query_issues.sql)

| 专题 | 原理 | 诊断 | 修复 |
|------|------|------|------|
| 语法错误 | ClickHouse SQL 差异 | `EXPLAIN SYNTAX` | 修正 SQL / 使用别名 |
| 查询超时 | 超时保护机制 | `system.settings` (timeout) | 调整超时参数 / 优化查询 |
| OOM (内存溢出) | 内存限制机制 | `system.processes` | 设置 max_memory_usage / 启用磁盘溢出 |
| 类型不匹配 | 强类型检查 | `DESC TABLE` | CAST / toType 转换 |
| 跳数索引失效 | 索引与查询不匹配 | `EXPLAIN indexes=1` | 重建索引 / 匹配查询模式 |

---

### 06 — 启动故障 [SQL 脚本](./06_startup_issues.sql)

| 专题 | 原理 | 诊断 | 修复 |
|------|------|------|------|
| 配置错误 | XML 解析/配置项校验 | `clickhouse --check` | 修复 XML / 配置项 |
| 端口冲突 | 端口被占用 | `netstat -tlnp` | 修改端口配置 |
| 数据目录权限 | 用户/目录权限 | `system.disks` | chown / SELinux 配置 |
| Keeper 无法启动 | Raft 配置/快照损坏 | `system.zookeeper_connection` | 清理快照 / 检查 Raft 配置 |

---

### 07 — 升级故障 [SQL 脚本](./07_upgrade_issues.sql)

| 专题 | 原理 | 诊断 | 修复 |
|------|------|------|------|
| 版本兼容 | 跨版本不兼容变更 | `SELECT version()` | 检查 CHANGELOG / 逐版本升级 |
| 数据格式变更 | 存储格式/索引格式变更 | `system.tables.format_version` | OPTIMIZE TABLE / 重写数据 |
| 配置项废弃 | 配置项被移除 | `system.text_log` (deprecated) | 替换为新配置项 |
| 回滚方案 | 版本降级策略 | 备份配置和数据 | 恢复旧版本二进制 / 数据导出导入 |

**版本兼容性建议**: v20→v21 需迁移 ZK 路径, v21→v22 存储格式变更, v22→v23 配置项大量废弃, v23→v24 主要兼容

---

### 08 — 数据一致性 [SQL 脚本](./08_data_consistency.sql)

| 专题 | 原理 | 诊断 | 修复 |
|------|------|------|------|
| 主从不一致 | 最终一致性模型 | `system.parts` (GROUP BY) | SYSTEM SYNC REPLICA |
| 校验 Checksum | 文件级校验和 | `CHECK TABLE` | DETACH + ATTACH 重建 |
| 修复手段 | 轻到重 10 种方法 | `system.replicas` | 从 FETCH PARTITION 到全量重建 |

**修复优先级**: SYNC → RESTART → FETCH → DROP+ATTACH → DETACH+ATTACH → MUTATION → 全量重建

---

### 09 — 资源问题 [SQL 脚本](./09_resource_issues.sql)

| 专题 | 原理 | 诊断 | 修复 |
|------|------|------|------|
| CPU 100% | 并发/聚合/压缩/合并 | `system.processes`, `system.events` | 限并发 / 杀查询 / 调整线程池 |
| 内存 OOM | 进程级/查询级 OOM | `system.memory`, `dmesg` | 设置内存限制 / 启用磁盘溢出 |
| 磁盘 IO 高 | 写入/合并/读取 | `system.events` (IO) | 限速 / 换 SSD / 提高压缩 |
| 网络延迟 | 集群通信/复制 | `system.events` (Network) | 压缩传输 / 优化集群拓扑 |

---

### 10 — 常见错误码 [SQL 脚本](./10_common_errors.sql)

涵盖 30+ 个关键错误码的【原理】、【场景】、【修复】：

| 错误码范围 | 分类 | 示例 |
|-----------|------|------|
| 0-199 | 系统级错误 | 40 (Checksum), 60 (ReadOnly), 117 (UnknownUser) |
| 200-399 | 数据库对象错误 | 218 (Protocol), 226 (NoTable), 242 (TooManyQueries) |
| 400-599 | 数据操作错误 | 441 (NoSpace), 517 (UnknownEngine), 519 (TableExists) |
| 600-799 | SQL 解析错误 | 632 (TooManyPartitions), 652 (CannotParse), 681 (Timeout) |
| 1000-1999 | 网络与协议错误 | 1000 (Network), 1001 (CannotConnect), 1010 (ZKError) |

**版本对比**: v20.x 错误码 1000-1999 范围 → v21.x 新增 500-999 → v22.x 重新整理 → v23.x 新增 632

---

### 11 — 火焰图与性能诊断 [SQL 脚本](./11_flamegraph.sql)

| 专题 | 原理 | 诊断 | 工具 |
|------|------|------|------|
| trace_log | CPU/内存采样追踪 | `system.trace_log` | FlameGraph 火焰图 |
| query_profiler | 实时采样分析器 | `system.settings` (profiler) | 配置采样间隔 |
| 采样分析 | 堆栈解析 | `demangle(addressToSymbol())` | stackcollapse + flamegraph.pl |
| 高级诊断 | 查询计划/事件/指标 | `EXPLAIN`, `ProfileEvents` | 物化视图 / Projection |

**采样配置建议**: 生产环境 100ms(10Hz), 诊断模式 1ms(1000Hz), 开发环境 0.1ms(10000Hz)

---

## 诊断工具速查

### 核心系统表

| 表名 | 用途 | 关联专题 |
|------|------|----------|
| `system.replicas` | 副本状态、延迟、队列 | 04, 08 |
| `system.replication_queue` | 复制队列任务详情 | 04 |
| `system.disks` | 磁盘空间、存储策略 | 03, 06 |
| `system.parts` | 分区数量、大小、活跃状态 | 03, 08 |
| `system.merges` | 合并任务进度、积压 | 02, 09 |
| `system.processes` | 当前查询、内存、耗时 | 02, 05, 09 |
| `system.query_log` | 查询历史、性能、错误 | 02, 05, 09 |
| `system.text_log` | 服务器日志（Error/Critical） | 03-11 |
| `system.trace_log` | CPU/内存采样分析 | 11 |
| `system.events` | 累计事件计数器 | 09, 11 |
| `system.metrics` | 实时指标（线程、连接） | 09 |
| `system.asynchronous_metrics` | 异步系统指标 | 09, 11 |
| `system.zookeeper_connection` | ZK/Keeper 连接状态 | 04, 06 |
| `system.data_skipping_indices` | 跳数索引定义和使用 | 05 |
| `system.detached_parts` | 分离的分区状态 | 03 |
| `system.settings` | 配置项当前值 | 05-07 |
| `system.columns` | 列定义、压缩算法 | 03 |

### 常用 Shell 命令

```bash
# 网络诊断
netstat -tlnp | grep -E '(9000|8123|9004|9005|9009|9181)'
ping -c 10 replica_host
telnet host port

# 磁盘诊断
iostat -x 1 10
df -h /var/lib/clickhouse
du -sh /var/lib/clickhouse/data/*

# 进程诊断
top -p $(pidof clickhouse-server)
ps aux | grep clickhouse

# 配置检查
clickhouse-server --config-file /etc/clickhouse-server/config.xml --check
clickhouse-server --config-file /etc/clickhouse-server/config.xml --print

# 日志查看
journalctl -u clickhouse-server -n 100 --no-pager
tail -f /var/log/clickhouse-server/clickhouse-server.err.log
```

---

## 应急响应流程

### P0 级：集群完全不可用

1. **第一时间** — 确认影响范围，通知相关人员
2. **快速恢复** — 尝试重启服务：`systemctl restart clickhouse-server`
3. **数据保护** — 备份当前数据目录（快照或 cp）
4. **根因分析** — 检查 text_log 中的 Fatal 级别错误
5. **恢复验证** — 确认所有节点正常，复制延迟归零
6. **事后复盘** — 记录事件时间线，更新故障预案

### P1 级：核心功能受损

1. **定位** — 使用快速诊断入口检查健康状态
2. **隔离** — 停止非核心查询，保障写入链路
3. **修复** — 根据故障特征定位到对应专题文件执行修复
4. **监控** — 恢复后持续观察 30 分钟
5. **记录** — 更新事故报告

---

## 最佳实践

### 巡检建议

- **每日**: 检查 `system.disks` (磁盘使用率), `system.replicas` (复制延迟)
- **每周**: 检查 `system.merges` (合并积压), `system.query_log` (慢查询趋势)
- **每月**: 运行 `CHECK TABLE` 抽样检查, 检查 `system.parts` (分区数异常)

### 预防措施

- 配置磁盘使用率告警 (75% 警告, 85% 严重, 95% 紧急)
- 设置合理的 TTL 策略自动清理过期数据
- 使用 ClickHouse Keeper 替代 ZooKeeper (降低复制延迟)
- 升级前先在测试环境验证兼容性
- 重要表开启副本复制 (ReplicatedMergeTree)
- 配置 `max_server_memory_usage_to_ram_ratio` 防止 OOM

---

## 参考资源

- [ClickHouse 官方文档](https://clickhouse.com/docs)
- [ClickHouse 故障排查指南](https://clickhouse.com/docs/en/operations/troubleshooting)
- [ClickHouse GitHub Issues](https://github.com/ClickHouse/ClickHouse/issues)
- [FlameGraph 火焰图工具](https://github.com/brendangregg/FlameGraph)
- [ClickHouse Keeper 文档](https://clickhouse.com/docs/en/operations/clickhouse-keeper)