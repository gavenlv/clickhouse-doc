-- ============================================================================
-- 04 - Prometheus + Grafana 集成（新增专题）
-- ============================================================================
-- 场景: Prometheus 指标采集、Grafana 监控面板、告警规则配置
-- 集群: treasurycluster (2副本)
-- 耗时: 15-20分钟
-- ============================================================================

DROP DATABASE IF EXISTS ops_test;
CREATE DATABASE ops_test;
USE ops_test;

-- ============================================================================
-- 【原理】Prometheus 集成架构
--
-- ClickHouse 从 21.8+ 开始原生支持 Prometheus 协议暴露指标，无需额外安装
-- exporter。通过配置 config.xml 中的 prometheus 部分即可启用。
--
--  _________________________________________________________________________
-- |                        Prometheus 集成架构                               |
-- |                                                                          |
-- |  ┌──────────────┐     ┌──────────────┐     ┌──────────────────┐         |
-- |  │ ClickHouse   │────>│ Prometheus   │────>│ Grafana           │         |
-- |  │ :9363/metrics │     │ scrape       │     │ Dashboard + Alert │         |
-- |  │ (HTTP)       │     │ 15s interval │     │                   │         |
-- |  └──────────────┘     └──────────────┘     └──────────────────┘         |
-- |                            │                                             |
-- |                            ▼                                             |
-- |                     ┌──────────────────┐                                |
-- |                     │ AlertManager     │                                |
-- |                     │ 告警分组/抑制/静默 │                                |
-- |                     └──────────────────┘                                |
-- _________________________________________________________________________
--
-- 核心指标分类：
--   clickhouse_queries_*     — 查询相关（QPS、延迟、并发）
--   clickhouse_merges_*      — 合并相关
--   clickhouse_replicas_*    — 副本相关
--   clickhouse_parts_*       — Part 相关
--   clickhouse_disk_*        — 磁盘相关
--   clickhouse_memory_*      — 内存相关
--   clickhouse_network_*     — 网络相关
--   clickhouse_events_*      — 事件计数
-- ============================================================================

-- ============================================================================
-- 【对比】方案对比
--
-- ┌──────────────────┬──────────────────┬──────────────────┬──────────────────┐
-- │     方案          │     优点          │     缺点          │     适用场景     │
-- ├──────────────────┼──────────────────┼──────────────────┼──────────────────┤
-- │ 原生 Prometheus   │ 无需额外组件      │ 指标固定          │ 通用场景        │
-- │ 端点              │ 零配置            │ 不可自定义        │                  │
-- ├──────────────────┼──────────────────┼──────────────────┼──────────────────┤
-- │ 自定义 SQL Exporter│ 灵活定制指标      │ 需要额外部署      │ 有特殊需求       │
-- │ (如: clickhouse-  │ 可计算复杂指标    │ 维护成本         │                  │
-- │  exporter)        │                  │                  │                  │
-- ├──────────────────┼──────────────────┼──────────────────┼──────────────────┤
-- │ Prometheus+       │ 完整方案          │ 配置复杂          │ 大型生产集群     │
-- │ AlertManager+     │ 告警+可视化      │ 依赖多组件        │                  │
-- │ Grafana           │                  │                  │                  │
-- └──────────────────┴──────────────────┴──────────────────┴──────────────────┘
-- ============================================================================

-- ==========================================
-- 1. ClickHouse Prometheus 暴露端口配置
-- ==========================================

-- 【场景】在 config.xml 中配置 Prometheus 暴露端口
-- 【原理】ClickHouse 通过 HTTP 端点暴露 Prometheus 格式的指标

-- 1.1 config.xml 配置示例
-- 【坑】修改 config.xml 后需要重启 ClickHouse 或 reload 配置
-- 【坑】确保防火墙放行 9363 端口
SELECT '===== Prometheus 配置 (config.xml) =====' AS prom_config;

SELECT '<!-- 在 /etc/clickhouse-server/config.xml 中添加 -->' AS config_line
UNION ALL
SELECT '<prometheus>' AS config_line
UNION ALL
SELECT '    <endpoint>/metrics</endpoint>' AS config_line
UNION ALL
SELECT '    <port>9363</port>' AS config_line
UNION ALL
SELECT '    <metrics>true</metrics>' AS config_line
UNION ALL
SELECT '    <events>true</events>' AS config_line
UNION ALL
SELECT '    <asynchronous_metrics>true</asynchronous_metrics>' AS config_line
UNION ALL
SELECT '    <status_info>true</status_info>' AS config_line
UNION ALL
SELECT '</prometheus>' AS config_line;

-- 1.2 验证 Prometheus 端点是否正常工作
-- 在浏览器或 curl 中访问:
-- curl http://localhost:9363/metrics
-- 应该返回类似:
-- # HELP clickhouse_queries Number of executing queries
-- # TYPE clickhouse_queries gauge
-- clickhouse_queries 5

-- 1.3 Prometheus 采集配置 (prometheus.yml)
SELECT '===== Prometheus 采集配置 (prometheus.yml) =====' AS scrape_config;

SELECT 'scrape_configs:' AS yaml_line
UNION ALL
SELECT '  - job_name: ''clickhouse''' AS yaml_line
UNION ALL
SELECT '    scrape_interval: 15s' AS yaml_line
UNION ALL
SELECT '    scrape_timeout: 10s' AS yaml_line
UNION ALL
SELECT '    metrics_path: ''/metrics''' AS yaml_line
UNION ALL
SELECT '    static_configs:' AS yaml_line
UNION ALL
SELECT '      - targets:' AS yaml_line
UNION ALL
SELECT '        - ''clickhouse-server-1:9363''' AS yaml_line
UNION ALL
SELECT '        - ''clickhouse-server-2:9363''' AS yaml_line
UNION ALL
SELECT '        - ''clickhouse-server-3:9363''' AS yaml_line
UNION ALL
SELECT '        - ''clickhouse-server-4:9363''' AS yaml_line;

-- 1.4 scrape_interval 选择建议
-- 【场景】根据监控精度需求选择合适的采集间隔
-- 【原理】采集间隔越短，精度越高，但 Prometheus 和 ClickHouse 的负载也越大
SELECT '===== scrape_interval 选择建议 =====' AS interval_guide;

SELECT '15s — 默认值，适合大多数场景'
UNION ALL
SELECT '  QPS: 240 次/分钟/节点 | 存储: ~1GB/月/节点'
UNION ALL
SELECT ''
UNION ALL
SELECT '30s — 节省资源，适合非关键集群'
UNION ALL
SELECT '  QPS: 120 次/分钟/节点 | 存储: ~500MB/月/节点'
UNION ALL
SELECT ''
UNION ALL
SELECT '5s — 高精度，适合排查问题'
UNION ALL
SELECT '  QPS: 720 次/分钟/节点 | 存储: ~3GB/月/节点'
UNION ALL
SELECT '  注意: 仅在排查问题时临时使用，不建议长期开启';

-- ==========================================
-- 2. 关键指标采集
-- ==========================================

-- 2.1 查询相关指标
-- 【场景】通过 system.metrics 和 system.events 模拟 Prometheus 指标
-- 【原理】Prometheus 采集的指标与 system.metrics/events 对应
SELECT
    'clickhouse_queries' AS prometheus_metric,
    'gauge' AS metric_type,
    value AS current_value,
    '当前正在执行的查询数' AS description
FROM system.metrics
WHERE metric = 'Query'

UNION ALL

SELECT
    'clickhouse_connections',
    'gauge',
    value,
    '当前连接数'
FROM system.metrics
WHERE metric = 'Connection'

UNION ALL

SELECT
    'clickhouse_queries_total',
    'counter',
    toInt64(value),
    '自启动以来总查询数'
FROM system.events
WHERE event = 'Query'

UNION ALL

SELECT
    'clickhouse_queries_failed_total',
    'counter',
    toInt64(value),
    '自启动以来失败查询数'
FROM system.events
WHERE event = 'FailedQuery'

UNION ALL

SELECT
    'clickhouse_queries_inserted_rows',
    'counter',
    toInt64(value),
    '自启动以来插入行数'
FROM system.events
WHERE event = 'InsertedRows'

UNION ALL

SELECT
    'clickhouse_queries_selected_rows',
    'counter',
    toInt64(value),
    '自启动以来查询行数'
FROM system.events
WHERE event = 'SelectedRows';

-- 2.2 合并相关指标
SELECT
    'clickhouse_merges_active' AS prometheus_metric,
    'gauge' AS metric_type,
    value AS current_value,
    '当前正在进行的合并数' AS description
FROM system.metrics
WHERE metric = 'Merge'

UNION ALL

SELECT
    'clickhouse_merges_total',
    'counter',
    toInt64(value),
    '自启动以来合并总次数'
FROM system.events
WHERE event = 'Merge'

UNION ALL

SELECT
    'clickhouse_merges_parts_total',
    'counter',
    toInt64(value),
    '自启动以来合并的 Part 数'
FROM system.events
WHERE event = 'PartMerged'

UNION ALL

SELECT
    'clickhouse_merges_rows_total',
    'counter',
    toInt64(value),
    '自启动以来合并的行数'
FROM system.events
WHERE event = 'MergedRows';

-- 2.3 副本相关指标
-- 【场景】监控副本同步状态和延迟
-- 【原理】通过 system.replicas 计算副本健康指标
SELECT
    'clickhouse_replicas_delay_seconds' AS prometheus_metric,
    'gauge' AS metric_type,
    toFloat64(max(absolute_delay)) AS current_value,
    '最大副本延迟秒数' AS description
FROM system.replicas

UNION ALL

SELECT
    'clickhouse_replicas_readonly',
    'gauge',
    toFloat64(countIf(is_readonly = 1)),
    '只读副本数'
FROM system.replicas

UNION ALL

SELECT
    'clickhouse_replicas_session_expired',
    'gauge',
    toFloat64(countIf(is_session_expired = 1)),
    '会话过期副本数'
FROM system.replicas

UNION ALL

SELECT
    'clickhouse_replicas_queue_size',
    'gauge',
    toFloat64(sum(queue_size)),
    '复制队列总大小'
FROM system.replicas;

-- 2.4 磁盘相关指标
-- 【场景】监控磁盘使用情况
SELECT
    'clickhouse_disk_free_bytes' AS prometheus_metric,
    'gauge' AS metric_type,
    toFloat64(sum(free_space)) AS current_value,
    '磁盘总剩余空间(字节)' AS description
FROM system.disks

UNION ALL

SELECT
    'clickhouse_disk_total_bytes',
    'gauge',
    toFloat64(sum(total_space)),
    '磁盘总容量(字节)'
FROM system.disks

UNION ALL

SELECT
    'clickhouse_disk_used_percent',
    'gauge',
    round((sum(total_space) - sum(free_space)) * 100.0 / sum(total_space), 2),
    '磁盘使用率(%)'
FROM system.disks;

-- 2.5 内存相关指标
-- 【场景】监控内存使用情况
SELECT
    'clickhouse_memory_tracking_bytes' AS prometheus_metric,
    'gauge' AS metric_type,
    toFloat64((SELECT value FROM system.metrics WHERE metric = 'MemoryTracking')) AS current_value,
    '查询内存跟踪(字节)' AS description
UNION ALL
SELECT
    'clickhouse_memory_os_total_bytes',
    'gauge',
    toFloat64((SELECT value FROM system.asynchronous_metrics WHERE metric = 'OSMemoryTotal')),
    'OS 总内存(字节)'
UNION ALL
SELECT
    'clickhouse_memory_os_active_bytes',
    'gauge',
    toFloat64((SELECT value FROM system.asynchronous_metrics WHERE metric = 'OSMemoryActive')),
    'OS 活跃内存(字节)'
UNION ALL
SELECT
    'clickhouse_memory_os_free_bytes',
    'gauge',
    toFloat64((SELECT value FROM system.asynchronous_metrics WHERE metric = 'OSMemoryFree')),
    'OS 空闲内存(字节)';

-- 2.6 Part 相关指标
SELECT
    'clickhouse_parts_active' AS prometheus_metric,
    'gauge' AS metric_type,
    count() AS current_value,
    '活跃 Part 总数' AS description
FROM system.parts
WHERE active = 1
  AND database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')

UNION ALL

SELECT
    'clickhouse_parts_total_bytes',
    'gauge',
    sum(bytes_on_disk),
    'Part 总大小(字节)'
FROM system.parts
WHERE active = 1
  AND database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')

UNION ALL

SELECT
    'clickhouse_parts_inactive',
    'gauge',
    count(),
    '非活跃 Part 总数'
FROM system.parts
WHERE active = 0
  AND database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA');

-- ==========================================
-- 3. Grafana 监控面板设计
-- ==========================================

-- 【场景】设计 Grafana 监控面板，展示核心指标
-- 【原理】Grafana 通过 Prometheus 数据源查询 ClickHouse 指标

-- 3.1 面板布局建议
SELECT '===== Grafana 面板布局建议 =====' AS dashboard_design;

SELECT '行 1: 集群概览 (Cluster Overview)'
UNION ALL
SELECT '  ├─ 集群健康评分 (Stat: 0-100)'
UNION ALL
SELECT '  ├─ 活跃查询数 (Stat: gauge)'
UNION ALL
SELECT '  ├─ 副本延迟最大 (Stat: gauge)'
UNION ALL
SELECT '  └─ 磁盘使用率 (Stat: gauge)'
UNION ALL
SELECT ''
UNION ALL
SELECT '行 2: 查询性能 (Query Performance)'
UNION ALL
SELECT '  ├─ QPS 趋势 (Time Series: 1h/24h/7d)'
UNION ALL
SELECT '  ├─ 查询延迟 P50/P95/P99 (Time Series)'
UNION ALL
SELECT '  ├─ 慢查询 Top 10 (Table)'
UNION ALL
SELECT '  └─ 查询失败率 (Time Series)'
UNION ALL
SELECT ''
UNION ALL
SELECT '行 3: 系统资源 (System Resources)'
UNION ALL
SELECT '  ├─ CPU 使用率 (Time Series: 所有节点叠加)'
UNION ALL
SELECT '  ├─ 内存使用率 (Time Series)'
UNION ALL
SELECT '  ├─ 磁盘使用率 (Time Series: 按节点)'
UNION ALL
SELECT '  └─ 磁盘 IO 等待 (Time Series)'
UNION ALL
SELECT ''
UNION ALL
SELECT '行 4: 复制与合并 (Replication & Merges)'
UNION ALL
SELECT '  ├─ 副本延迟 (Time Series: 按表)'
UNION ALL
SELECT '  ├─ 合并队列积压 (Time Series)'
UNION ALL
SELECT '  ├─ Mutation 进度 (Table)'
UNION ALL
SELECT '  └─ 复制队列异常 (Stat)'
UNION ALL
SELECT ''
UNION ALL
SELECT '行 5: 存储与容量 (Storage & Capacity)'
UNION ALL
SELECT '  ├─ Part 数量增长 (Time Series)'
UNION ALL
SELECT '  ├─ 数据量增长趋势 (Time Series)'
UNION ALL
SELECT '  ├─ 压缩率 (Gauge)'
UNION ALL
SELECT '  └─ 容量预测 (Time Series: 实际+预测线)';

-- 3.2 关键 PromQL 查询示例
-- 【场景】Grafana 面板中使用的 PromQL 查询
SELECT '===== 常用 PromQL 查询 =====' AS promql_examples;

SELECT '1. QPS (最近 5 分钟平均)'
UNION ALL
SELECT '   rate(clickhouse_queries_total[5m])'
UNION ALL
SELECT ''
UNION ALL
SELECT '2. 查询失败率'
UNION ALL
SELECT '   rate(clickhouse_queries_failed_total[5m]) / rate(clickhouse_queries_total[5m]) * 100'
UNION ALL
SELECT ''
UNION ALL
SELECT '3. 副本最大延迟'
UNION ALL
SELECT '   max(clickhouse_replicas_delay_seconds) by (table)'
UNION ALL
SELECT ''
UNION ALL
SELECT '4. 磁盘使用率'
UNION ALL
SELECT '   clickhouse_disk_used_percent'
UNION ALL
SELECT ''
UNION ALL
SELECT '5. 合并速率'
UNION ALL
SELECT '   rate(clickhouse_merges_total[5m])'
UNION ALL
SELECT ''
UNION ALL
SELECT '6. 活跃 Part 数'
UNION ALL
SELECT '   clickhouse_parts_active'
UNION ALL
SELECT ''
UNION ALL
SELECT '7. 查询内存使用 P99'
UNION ALL
SELECT '   quantile_over_time(0.99, clickhouse_memory_tracking_bytes[1h])'
UNION ALL
SELECT ''
UNION ALL
SELECT '8. 数据增长率 (字节/天)'
UNION ALL
SELECT '   increase(clickhouse_parts_total_bytes[24h])';

-- ==========================================
-- 4. Prometheus 告警规则配置
-- ==========================================

-- 【场景】配置 Prometheus 告警规则，对接 AlertManager
-- 【原理】Prometheus 根据告警规则评估指标，触发告警后发送到 AlertManager

-- 4.1 告警规则配置 (alert_rules.yml)
SELECT '===== Prometheus 告警规则 =====' AS alert_rules;

SELECT 'groups:' AS yaml
UNION ALL
SELECT '  - name: clickhouse_alerts' AS yaml
UNION ALL
SELECT '    interval: 30s' AS yaml
UNION ALL
SELECT '    rules:' AS yaml
UNION ALL
SELECT '      - alert: ClickHouseHighQueryLatency' AS yaml
UNION ALL
SELECT '        expr: clickhouse_queries_99th_percentile > 10' AS yaml
UNION ALL
SELECT '        for: 5m' AS yaml
UNION ALL
SELECT '        labels: { severity: warning }' AS yaml
UNION ALL
SELECT '        annotations:' AS yaml
UNION ALL
SELECT '          summary: "ClickHouse 查询延迟过高"' AS yaml
UNION ALL
SELECT ''
UNION ALL
SELECT '      - alert: ClickHouseReplicaLag' AS yaml
UNION ALL
SELECT '        expr: clickhouse_replicas_delay_seconds > 300' AS yaml
UNION ALL
SELECT '        for: 2m' AS yaml
UNION ALL
SELECT '        labels: { severity: critical }' AS yaml
UNION ALL
SELECT '        annotations:' AS yaml
UNION ALL
SELECT '          summary: "ClickHouse 副本延迟超过 300 秒"' AS yaml
UNION ALL
SELECT ''
UNION ALL
SELECT '      - alert: ClickHouseDiskSpaceLow' AS yaml
UNION ALL
SELECT '        expr: clickhouse_disk_used_percent > 90' AS yaml
UNION ALL
SELECT '        for: 5m' AS yaml
UNION ALL
SELECT '        labels: { severity: critical }' AS yaml
UNION ALL
SELECT '        annotations:' AS yaml
UNION ALL
SELECT '          summary: "ClickHouse 磁盘使用率超过 90%"' AS yaml
UNION ALL
SELECT ''
UNION ALL
SELECT '      - alert: ClickHouseMergeBacklog' AS yaml
UNION ALL
SELECT '        expr: clickhouse_merges_active > 50' AS yaml
UNION ALL
SELECT '        for: 5m' AS yaml
UNION ALL
SELECT '        labels: { severity: warning }' AS yaml
UNION ALL
SELECT '        annotations:' AS yaml
UNION ALL
SELECT '          summary: "ClickHouse 合并队列积压超过 50"' AS yaml
UNION ALL
SELECT ''
UNION ALL
SELECT '      - alert: ClickHouseTooManyParts' AS yaml
UNION ALL
SELECT '        expr: clickhouse_parts_active > 500' AS yaml
UNION ALL
SELECT '        for: 10m' AS yaml
UNION ALL
SELECT '        labels: { severity: warning }' AS yaml
UNION ALL
SELECT '        annotations:' AS yaml
UNION ALL
SELECT '          summary: "ClickHouse 活跃 Part 数超过 500"' AS yaml
UNION ALL
SELECT ''
UNION ALL
SELECT '      - alert: ClickHouseQueryFailed' AS yaml
UNION ALL
SELECT '        expr: rate(clickhouse_queries_failed_total[5m]) > 0.1' AS yaml
UNION ALL
SELECT '        for: 5m' AS yaml
UNION ALL
SELECT '        labels: { severity: critical }' AS yaml
UNION ALL
SELECT '        annotations:' AS yaml
UNION ALL
SELECT '          summary: "ClickHouse 查询失败率异常升高"' AS yaml
UNION ALL
SELECT ''
UNION ALL
SELECT '      - alert: ClickHouseNodeDown' AS yaml
UNION ALL
SELECT '        expr: up{job="clickhouse"} == 0' AS yaml
UNION ALL
SELECT '        for: 1m' AS yaml
UNION ALL
SELECT '        labels: { severity: critical }' AS yaml
UNION ALL
SELECT '        annotations:' AS yaml
UNION ALL
SELECT '          summary: "ClickHouse 节点 {{ $labels.instance }} 宕机"' AS yaml;

-- 4.2 AlertManager 配置
-- 【场景】配置 AlertManager 通知渠道
SELECT '===== AlertManager 配置示例 =====' AS alertmanager_config;

SELECT 'route:' AS yaml
UNION ALL
SELECT '  receiver: ''default''' AS yaml
UNION ALL
SELECT '  routes:' AS yaml
UNION ALL
SELECT '    - match: { severity: critical }' AS yaml
UNION ALL
SELECT '      receiver: ''pagerduty''' AS yaml
UNION ALL
SELECT '    - match: { severity: warning }' AS yaml
UNION ALL
SELECT '      receiver: ''slack''' AS yaml
UNION ALL
SELECT ''
UNION ALL
SELECT 'receivers:' AS yaml
UNION ALL
SELECT '  - name: ''default''' AS yaml
UNION ALL
SELECT '    email_configs:' AS yaml
UNION ALL
SELECT '      - to: ops@example.com' AS yaml
UNION ALL
SELECT ''
UNION ALL
SELECT '  - name: ''slack''' AS yaml
UNION ALL
SELECT '    slack_configs:' AS yaml
UNION ALL
SELECT '      - channel: ''#clickhouse-alerts''' AS yaml
UNION ALL
SELECT '        send_resolved: true' AS yaml
UNION ALL
SELECT ''
UNION ALL
SELECT '  - name: ''pagerduty''' AS yaml
UNION ALL
SELECT '    pagerduty_configs:' AS yaml
UNION ALL
SELECT '      - routing_key: ${PAGERDUTY_KEY}' AS yaml;

-- ==========================================
-- 5. 自定义指标（通过 SQL 导出到 Prometheus）
-- ==========================================

-- 【场景】当原生端点不满足需求时，通过自定义 SQL 导出指标
-- 【原理】使用 clickhouse-exporter 或 textfile collector 自定义指标

-- 5.1 自定义指标导出示例
-- 可以创建一个 cron 任务，定期执行以下 SQL 并输出到 Prometheus
-- textfile collector 目录
SELECT
    '# HELP clickhouse_custom_parts_skew Part skew ratio by table' AS prom_line
UNION ALL
SELECT
    '# TYPE clickhouse_custom_parts_skew gauge'
UNION ALL
SELECT
    'clickhouse_custom_parts_skew{database="' || database || '",table="' || table || '"} ' || toString(skew_ratio)
FROM (
    SELECT
        database,
        table,
        max(partition_rows) / greatest(min(partition_rows), 1) AS skew_ratio
    FROM (
        SELECT
            database,
            table,
            partition,
            sum(rows) AS partition_rows
        FROM system.parts
        WHERE active = 1
          AND database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
        GROUP BY database, table, partition
        HAVING sum(rows) > 10000000
    )
    GROUP BY database, table
    HAVING skew_ratio > 3
);

-- 5.2 自定义指标：每个表的 Part 数量
SELECT
    '# HELP clickhouse_custom_table_parts Active parts count by table' AS prom_line
UNION ALL
SELECT
    '# TYPE clickhouse_custom_table_parts gauge'
UNION ALL
SELECT
    'clickhouse_custom_table_parts{database="' || database || '",table="' || table || '"} ' || toString(part_count)
FROM (
    SELECT
        database,
        table,
        count(*) AS part_count
    FROM system.parts
    WHERE active = 1
      AND database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
    GROUP BY database, table
);

-- ==========================================
-- 6. 集成验证
-- ==========================================

-- 【场景】验证 Prometheus 集成是否正常工作
-- 【原理】通过查询 system.metrics 确认指标可达

-- 6.1 验证 CheckList
SELECT '===== Prometheus 集成验证清单 =====' AS verification;

SELECT '1. ClickHouse Prometheus 端口是否开启？'
UNION ALL
SELECT '   curl http://localhost:9363/metrics | head -20'
UNION ALL
SELECT ''
UNION ALL
SELECT '2. Prometheus target 是否 up？'
UNION ALL
SELECT'   Prometheus Web UI → Status → Targets → clickhouse job 应为 UP'
UNION ALL
SELECT ''
UNION ALL
SELECT '3. 指标是否正常采集？'
UNION ALL
SELECT '   在 Prometheus 中查询: clickhouse_queries'
UNION ALL
SELECT ''
UNION ALL
SELECT '4. Grafana 能否连接 Prometheus？'
UNION ALL
SELECT '   Grafana → Configuration → Data Sources → Prometheus → Test'
UNION ALL
SELECT ''
UNION ALL
SELECT '5. 告警规则是否生效？'
UNION ALL
SELECT '   Prometheus → Alerts → 查看规则状态'
UNION ALL
SELECT ''
UNION ALL
SELECT '6. 指标数据是否持久化？'
UNION ALL
SELECT '   查询过去 1 小时的数据: clickhouse_queries[1h]';

-- 6.2 确认当前节点版本和 Prometheus 支持
SELECT
    version() AS clickhouse_version,
    'Prometheus endpoint 支持版本: 21.8+' AS support_info,
    CASE
        WHEN toUInt32(extract(version(), '^(\\d+)')) >= 21 THEN '✅ 支持原生 Prometheus 端点'
        ELSE '❌ 需要额外安装 clickhouse-exporter'
    END AS prometheus_support;

-- ==========================================
-- 清理
-- ==========================================
DROP DATABASE IF EXISTS ops_test;

-- ============================================================================
-- 最佳实践：
-- 1. scrape_interval: 15s 适合大多数场景，关键集群可设为 10s
-- 2. 至少保留 30 天指标数据，用于容量分析和趋势预测
-- 3. Grafana 面板建议按行组织：概览/查询/系统/复制/存储
-- 4. 告警规则设置 for 参数避免瞬时抖动导致误报
-- 5. 使用 AlertManager 的路由规则实现告警分级通知
-- 6. 定期检查 Prometheus 的存储使用，避免磁盘满
-- 7. 自定义指标使用 textfile collector 方式，避免增加 ClickHouse 负载
-- 8. 节点发现推荐使用 Prometheus 的服务发现机制（consul/k8s），而非静态配置
-- ============================================================================