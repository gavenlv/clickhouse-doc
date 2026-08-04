# 08 - 实时性 SLA：数据新鲜度、监控与故障恢复

> **本章定位**：07 章讲了"数据怎么流",本章讲"**怎么保证数据是新的、是对的、故障时能恢复**"。内容覆盖：端到端 SLA 分级、各层延迟预算、新鲜度监控、告警体系、故障恢复 SOP。

## 8.1 实时性 SLA 的本质

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                      实时性 SLA 的三大维度                                    │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   ┌─────────────┐    ┌─────────────┐    ┌─────────────┐                    │
│   │   时效性     │    │   一致性     │    │   可用性     │                    │
│   │ Freshness   │    │ Consistency │    │ Availability │                    │
│   └─────────────┘    └─────────────┘    └─────────────┘                    │
│        │                  │                  │                              │
│        ▼                  ▼                  ▼                              │
│   数据从产生到          跨层流转后          系统持续                        │
│   看板可见的时间        数据是否一致         工作的能力                      │
│                                                                             │
│   衡量指标:           衡量指标:            衡量指标:                          │
│   - 端到端延迟         - 数量一致           - 99.9% SLA                     │
│   - P50/P95/P99        - 指标一致           - MTTR                          │
│   - 数据延迟           - 重复/丢失率        - 故障频率                       │
│                                                                             │
│   业务期望:           业务期望:            业务期望:                          │
│   秒级可见             财务/业务对账一致     7×24 不间断                      │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

## 8.2 SLA 等级定义

### 8.2.1 业务分级

| 等级 | 业务场景 | 端到端延迟 | 可用性 | 一致性要求 | 典型例子 |
|------|---------|-----------|--------|----------|---------|
| **P0** | 资金/风险 | < 1 秒 | 99.99% | 强一致(Exactly-Once) | 支付结果、欺诈检测 |
| **P1** | 实时大屏 | 1-5 秒 | 99.9% | 最终一致 | CEO 看板、运营监控 |
| **P2** | 业务分析 | 5-60 秒 | 99.5% | 最终一致 | 部门级看板、漏斗分析 |
| **P3** | 准实时分析 | 1-5 分钟 | 99% | 最终一致 | 用户行为分析、归因 |
| **P4** | T+1 报表 | 数小时 | 95% | 最终一致 | 月度/季度报表 |

### 8.2.2 延迟预算拆解

```
P1 业务(端到端 5 秒)的延迟预算:

┌──────────────────────────────────────────────────────────┐
│ 环节            预算      累计      优化空间                │
├──────────────────────────────────────────────────────────┤
│ MySQL → Binlog  100ms    100ms    无(物理限制)            │
│ Binlog → Kafka  100ms    200ms    调 Kafka 批大小         │
│ Kafka → Flink   200ms    400ms    调 Flink 消费并发       │
│ Flink 处理      300ms    700ms    优化逻辑/并行度          │
│ Flink → CH 写入 1500ms   2200ms   ClickHouse 写入调优     │
│ CH 物化视图      500ms   2700ms   减少聚合复杂度          │
│ CH → Superset   300ms   3000ms   Superset 缓存           │
│ Superset 渲染   100ms   3100ms   -                      │
│ 网络+用户感知   200ms   3300ms   -                      │
│ 缓冲            1700ms   5000ms   -                      │
└──────────────────────────────────────────────────────────┘

为什么这么拆?
  - 找出主瓶颈: ClickHouse 写入占 30%
  - 找出次瓶颈: 缓冲占 34%(用于抵消突发)
  - 优化重点: 减小 ClickHouse 写入延迟(批量+异步)
```

## 8.3 数据新鲜度(Freshness)监控

### 8.3.1 核心监控指标

```sql
-- ============ ODS 层新鲜度 ============
-- 监控: 距离最后一条数据过去了多久
SELECT
    -- 距当前时间
    now() - max(ods_ingest_time)           AS ods_lag,
    -- 距源库最后变更时间
    max(toDateTime64(ods_ts_ms/1000, 3))   AS src_last_change,
    now() - max(toDateTime64(ods_ts_ms/1000, 3)) AS src_lag,
    -- 行数(最近 1 分钟)
    countIf(ods_ingest_time >= now() - INTERVAL 1 MINUTE) AS rows_last_min
FROM realtime_olap.ods_order
WHERE ods_ingest_time >= today();

-- ============ DWD 层新鲜度 ============
SELECT
    now() - max(etl_time)    AS dwd_lag,
    countIf(etl_time >= now() - INTERVAL 1 MINUTE) AS dwd_rows_per_min
FROM realtime_olap.dwd_order
WHERE etl_time >= today();

-- ============ DWS 层新鲜度 ============
SELECT
    now() - max(etl_time)    AS dws_lag,
    count()                   AS dws_total_rows
FROM realtime_olap.dws_user_order_1d
WHERE etl_time >= today();
```

### 8.3.2 新鲜度告警规则

```
┌──────────────────────────────────────────────────────────┐
│                   新鲜度告警分级                             │
├──────────────────────────────────────────────────────────┤
│                                                          │
│  P0 告警(电话通知,5 分钟响应)                              │
│    - ODS 延迟 > 60 秒                                    │
│    - DWD 延迟 > 5 分钟                                   │
│    - DWS 延迟 > 10 分钟                                  │
│    - 新鲜度监控无数据 > 10 分钟(可能挂了)                   │
│                                                          │
│  P1 告警(IM 通知,30 分钟响应)                             │
│    - ODS 延迟 10-60 秒                                   │
│    - DWD 延迟 1-5 分钟                                   │
│    - DWS 延迟 5-10 分钟                                  │
│                                                          │
│  P2 告警(邮件通知,工作时间处理)                            │
│    - ODS 延迟 5-10 秒(短暂波动)                          │
│    - 数据量异常(下降 50% 以上)                            │
│    - 物化视图落后 5 分钟                                  │
│                                                          │
│  恢复后自动消除告警                                       │
│                                                          │
└──────────────────────────────────────────────────────────┘
```

### 8.3.3 Flink 端实时监控

```java
/**
 * Flink 内置指标
 * 
 * 关键指标:
 *   - numRecordsIn:  输入速率(条/秒)
 *   - numRecordsOut: 输出速率
 *   - latency:        数据延迟(从产生到输出)
 *   - checkpointDuration: Checkpoint 时长
 *   - backPressureTimeMsPerSecond: 反压时长
 */
public class FlinkMetricsConfig {
    
    public static void registerMetrics(StreamExecutionEnvironment env) {
        // 1. 注册全局指标
        env.getConfig().setGlobalJobParameters(...);
        
        // 2. 自定义业务指标
        DataStream<OrderEvent> stream = ...;
        stream.map(event -> {
            // 记录数据延迟
            long lag = System.currentTimeMillis() - event.getEventTime();
            getRuntimeContext()
                .getMetricGroup()
                .gauge("data_lag_ms", () -> lag);
            return event;
        });
    }
}

// 3. Prometheus + Grafana 集成
// flink-metrics-prometheus.jar 把指标暴露给 Prometheus
```

## 8.4 各层延迟监控 SQL

### 8.4.1 完整的可观测性查询

```sql
-- ========================================
-- 1. 端到端延迟看板(汇总视图)
-- ========================================
CREATE VIEW IF NOT EXISTS realtime_olap.v_sla_dashboard ON CLUSTER 'treasurycluster' AS
SELECT
    -- 时间维度
    toStartOfMinute(now())                  AS check_time,
    
    -- ODS 层延迟
    (SELECT now() - max(ods_ingest_time) 
     FROM realtime_olap.ods_order 
     WHERE ods_ingest_time >= today() - INTERVAL 1 DAY) AS ods_lag_sec,
    
    -- DWD 层延迟
    (SELECT now() - max(etl_time) 
     FROM realtime_olap.dwd_order 
     WHERE etl_time >= today() - INTERVAL 1 DAY) AS dwd_lag_sec,
    
    -- DWS 层延迟
    (SELECT now() - max(etl_time) 
     FROM realtime_olap.dws_user_order_1d 
     WHERE etl_time >= today() - INTERVAL 1 DAY) AS dws_lag_sec,
    
    -- 各层行数(最近 1 分钟)
    (SELECT count() FROM realtime_olap.ods_order 
     WHERE ods_ingest_time >= now() - INTERVAL 1 MINUTE) AS ods_rpm,
    (SELECT count() FROM realtime_olap.dwd_order 
     WHERE etl_time >= now() - INTERVAL 1 MINUTE) AS dwd_rpm;

-- 查询当前 SLA
SELECT * FROM realtime_olap.v_sla_dashboard;

-- ========================================
-- 2. 物化视图健康度
-- ========================================
SELECT
    name                            AS mv_name,
    engine,
    total_rows,
    formatReadableSize(total_bytes) AS size,
    -- 距上次插入时间
    (SELECT max(etl_time) FROM realtime_olap.dwd_order) - latest_modification_time AS mv_lag,
    -- 是否落后
    if(mv_lag > toIntervalMinute(5), '落后', '正常') AS status
FROM system.tables
WHERE database = 'realtime_olap'
  AND engine LIKE '%MaterializedView%'
ORDER BY mv_lag DESC;

-- ========================================
-- 3. 复制延迟监控(双副本)
-- ========================================
SELECT
    database,
    table,
    -- 副本延迟(秒)
    absolute_delay,
    -- 队列中的任务数
    queue_size
FROM system.replicas
WHERE database = 'realtime_olap'
ORDER BY absolute_delay DESC
LIMIT 10;
```

### 8.4.2 慢查询监控

```sql
-- 找出最近的慢查询(> 5 秒)
SELECT
    event_time,
    query_duration_ms / 1000.0                AS duration_sec,
    query_kind,
    -- 关键: 查询 SQL(去掉长内容)
    substring(query, 1, 200)                  AS query_preview,
    -- 读取的行数
    read_rows,
    formatReadableSize(read_bytes)            AS read_size,
    -- 涉及的表
    tables,
    -- 用户
    user,
    -- 错误信息(如果有)
    exception
FROM system.query_log
WHERE event_time >= now() - INTERVAL 1 HOUR
  AND type = 'QueryFinish'
  AND query_duration_ms > 5000
ORDER BY query_duration_ms DESC
LIMIT 20;
```

## 8.5 实时性保证技术

### 8.5.1 端到端 Exactly-Once 的难点

```
┌──────────────────────────────────────────────────────────────┐
│              Exactly-Once 实现的难点                            │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│  阶段 1: Kafka → Flink                                       │
│    - Flink Checkpoint + Kafka offset 提交 → ✅ 容易           │
│    - Kafka 0.11+ 支持事务 → ✅ 容易                          │
│                                                              │
│  阶段 2: Flink 内部处理                                       │
│    - 状态后端(内存/RocksDB)→ ✅ 容易                          │
│    - 算子链路 → ✅ Flink 原生支持                              │
│                                                              │
│  阶段 3: Flink → ClickHouse                                   │
│    - ClickHouse 没有事务 ❌                                    │
│    - 没有 UNDO LOG ❌                                          │
│    - 批量写入,要么全成要么全失败 ❌                              │
│    - 两阶段提交需要特殊处理 ⚠️                                  │
│                                                              │
│  阶段 4: ClickHouse → Superset                              │
│    - Superset 是查询方,只读 → ✅ 容易                          │
│                                                              │
│  结论: Exactly-Once 真正的难点在 Flink → ClickHouse            │
│        业界通用方案: At-Least-Once + 幂等去重                  │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

### 8.5.2 实际方案:At-Least-Once + 幂等

```java
/**
 * 实际生产方案
 * 
 * 设计:
 *   1. Flink Checkpoint 60 秒
 *   2. ClickHouse Sink 批量写入 + 重试
 *   3. DWD 表用 ReplacingMergeTree(etl_time)
 *   4. 重复数据靠 ClickHouse 后台合并去重
 * 
 * 数据可能出现重复(At-Least-Once)
 * 但 DWD 表查询结果是去重的(幂等)
 * 
 * Why 这个方案?
 *   - ClickHouse 100% 兼容
 *   - Flink 端零侵入
 *   - 业务可容忍秒级重复
 *   - 99% 场景足够
 */
public class AtLeastOnceWithDedup {
    
    // 1. Flink 端: At-Least-Once (Checkpoint + 重试)
    public static void main(String[] args) {
        StreamExecutionEnvironment env = ...;
        env.enableCheckpointing(60000);  // 60 秒
        
        DataStream<DwdOrderEvent> stream = ...;
        
        // 2. ClickHouse Sink: 批量 + 重试(可能重复写入)
        stream.addSink(ClickHouseSink.<DwdOrderEvent>builder()
            .setBatchSize(5000)
            .setFlushInterval(Duration.ofMillis(1000))
            .setMaxRetries(3)
            .build());
    }
    
    // 2. ClickHouse 端: 幂等去重
    // DDL:
    //   CREATE TABLE dwd_order (...)
    //   ENGINE = ReplicatedReplacingMergeTree(..., etl_time)
    //   ...
    
    // 3. 查询时(可选): 强制去重
    public static String idempotentQuery() {
        return "SELECT * FROM dwd_order FINAL WHERE order_time >= today() - 7";
        // FINAL 强制合并去重,但性能差,慎用
    }
}
```

**为什么不直接用 Exactly-Once？**

```
Exactly-Once 的代价:
  - 性能下降 30-50%(两阶段提交开销)
  - 实现复杂度高(需 Zookeeper 协调)
  - ClickHouse 端需要特殊处理

At-Least-Once 的代价:
  - 可能有少量重复(分钟级)
  - 业务可容忍(对账/监控可发现)

业务视角:
  - 99% 业务: At-Least-Once 就够了
  - 1% 业务(资金): 必须 Exactly-Once,用专用方案
```

### 8.5.3 Exactly-Only-If-Needed 方案

```sql
-- 真正的去重要求: 数据进 ClickHouse 后,业务侧看到的是去重后的

-- 方案: 用 ReplacingMergeTree + FINAL 查询
CREATE TABLE realtime_olap.dwd_order_exactly_once ON CLUSTER 'treasurycluster' (
    order_id      String,
    -- 其他字段...
    etl_time      DateTime  -- 版本列
) ENGINE = ReplicatedReplacingMergeTree(
    '/clickhouse/tables/{shard}/realtime_olap/dwd_order_exactly_once',
    '{replica}',
    etl_time
)
PARTITION BY toYYYYMM(order_time)
ORDER BY (order_time, order_id);

-- 写入: Flink 携带事件时间作为版本
-- INSERT INTO dwd_order_exactly_once VALUES (?, ..., ?)

-- 查询: 用 FINAL 强制去重
SELECT * FROM realtime_olap.dwd_order_exactly_once FINAL
WHERE order_time >= today() - INTERVAL 7 DAY;

-- 注意: FINAL 影响性能,生产慎用
-- 替代: 依赖后台自动合并(非实时)
```

## 8.6 监控告警体系

### 8.6.1 监控架构

```
┌──────────────────────────────────────────────────────────────┐
│                     监控告警体系                                │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐       │
│  │ 数据源       │    │ Flink       │    │ ClickHouse  │       │
│  │ 埋点         │    │ 指标         │    │ 指标         │       │
│  └──────┬──────┘    └──────┬──────┘    └──────┬──────┘       │
│         │                  │                  │               │
│         ▼                  ▼                  ▼               │
│  ┌──────────────────────────────────────────────────────┐   │
│  │              Prometheus (指标存储)                      │   │
│  └──────────────────────────┬───────────────────────────┘   │
│                             │                                │
│                             ▼                                │
│  ┌──────────────────────────────────────────────────────┐   │
│  │              Grafana (可视化)                          │   │
│  │  - Flink 作业仪表板                                   │   │
│  │  - ClickHouse 仪表板                                  │   │
│  │  - Superset 仪表板                                    │   │
│  │  - 业务指标仪表板                                      │   │
│  └──────────────────────────────────────────────────────┘   │
│                             │                                │
│                             ▼                                │
│  ┌──────────────────────────────────────────────────────┐   │
│  │              AlertManager (告警)                       │   │
│  │  - 钉钉/飞书/邮件 通知                                │   │
│  │  - 告警分级 + 值班路由                                 │   │
│  └──────────────────────────────────────────────────────┘   │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

### 8.6.2 必监控的核心指标

```yaml
# ============ Flink 必监控指标 ============
flink_job_uptime:                     # 作业运行时长
  rule: < 60s
  alert: 异常重启

flink_checkpoint_duration:            # Checkpoint 时长
  rule: > 5min
  alert: P2

flink_checkpoint_failed:              # Checkpoint 失败次数
  rule: > 3 in 10min
  alert: P1

flink_backpressure_ratio:             # 反压时间占比
  rule: > 10%
  alert: P1

flink_num_records_in_per_sec:         # 输入速率
  rule: < 业务预期 × 0.5
  alert: 数据源异常

flink_data_lag_ms:                    # 数据延迟
  rule: > 60000
  alert: P1 (> 60 秒)

# ============ ClickHouse 必监控指标 ============
clickhouse_insert_query_duration:     # 写入查询耗时
  rule: P99 > 5s
  alert: P1

clickhouse_parts_active:              # 活跃 part 数
  rule: > 200
  alert: P1 (合并跟不上)

clickhouse_replication_queue:         # 复制队列
  rule: > 100
  alert: P1 (副本延迟)

clickhouse_zookeeper_session:         # ZK 会话
  rule: expired
  alert: P0 (集群不可用)

clickhouse_disk_free_percent:         # 磁盘剩余
  rule: < 20%
  alert: P1

clickhouse_query_duration_p99:        # 查询 P99
  rule: > 5s
  alert: P2

# ============ Superset 必监控指标 ============
superset_cache_hit_rate:              # 缓存命中率
  rule: < 50%
  alert: P3

superset_query_failure_rate:          # 查询失败率
  rule: > 5%
  alert: P2

superset_dashboard_load_time:         # 看板加载时间
  rule: P95 > 10s
  alert: P2

# ============ 端到端指标 ============
end_to_end_data_lag_sec:              # 端到端数据延迟
  rule: > 60
  alert: P1 (P0 业务 > 10s)

end_to_end_consistency_diff:          # 跨层数据量差异
  rule: > 1%
  alert: P2 (每日对账时检测)
```

### 8.6.3 Grafana 仪表板示例

```json
{
  "dashboard": {
    "title": "实时数据链路 SLA 监控",
    "panels": [
      {
        "title": "端到端数据延迟(秒)",
        "type": "graph",
        "targets": [
          {
            "expr": "clickhouse_query_local {query='SELECT now()-max(etl_time) FROM dwd_order'}",
            "legendFormat": "DWD 延迟"
          },
          {
            "expr": "clickhouse_query_local {query='SELECT now()-max(ods_ingest_time) FROM ods_order'}",
            "legendFormat": "ODS 延迟"
          }
        ]
      },
      {
        "title": "Flink Checkpoint 时长",
        "type": "graph",
        "targets": [
          {
            "expr": "flink_jobmanager_job_lastCheckpointDuration",
            "legendFormat": "{{ job_name }}"
          }
        ]
      },
      {
        "title": "各层写入速率(行/分钟)",
        "type": "graph",
        "targets": [
          {
            "expr": "rate(clickhouse_inserted_rows_total[1m]) * 60",
            "legendFormat": "{{ table }}"
          }
        ]
      },
      {
        "title": "ClickHouse Part 数",
        "type": "graph",
        "targets": [
          {
            "expr": "clickhouse_parts_active",
            "legendFormat": "{{ table }}"
          }
        ]
      }
    ]
  }
}
```

## 8.7 故障恢复 SOP

### 8.7.1 故障分类与处理

```
┌──────────────────────────────────────────────────────────────────┐
│                    故障分类与处理矩阵                                │
├──────────────────────────────────────────────────────────────────┤
│                                                                  │
│  故障类型          现象                  恢复方式                  │
│  ──────────────────────────────────────────────────────────────  │
│  Flink 作业崩溃    看板无数据            重启 + 从 Checkpoint      │
│                                                                  │
│  Kafka 数据堆积    看板延迟大            扩容 Flink 并发           │
│                                                                  │
│  ClickHouse 慢     看板查询超时          优化 SQL / 加索引         │
│                                                                  │
│  副本同步失败      副本数据不一致        ZooKeeper 检查 + 重同步   │
│                                                                  │
│  物化视图落后      DWS 数据老            检查源数据 + 重建 MV      │
│                                                                  │
│  维表数据陈旧      DWD 字段错误          刷新 Dictionary          │
│                                                                  │
│  数据源故障        写入速率 = 0         切换数据源 / 等恢复        │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

### 8.7.2 故障恢复 Runbook

**故障 1: Flink 作业崩溃**

```bash
# ============ 排查步骤 ============

# 1. 查看 Flink Web UI
#   http://flink-jobmanager:8081
#   - 查看失败的作业
#   - 查看异常堆栈

# 2. 查看日志
kubectl logs -n flink <taskmanager-pod> --tail=200

# 3. 常见原因
#   - OOM: taskmanager.memory.process.size 调大
#   - Checkpoint 超时: execution.checkpointing.timeout 调大
#   - 维表查询超时: HBase 慢,检查 HBase 集群
#   - Kafka rebalance: Kafka 分区数变化

# ============ 恢复步骤 ============

# 1. 从最近的 Checkpoint 重启
flink run -c com.example.OdsToDwdOrderJob \
    --fromSavepoint \
    hdfs://namenode/flink/savepoints/savepoint-xxx \
    /opt/flink/jobs/flink-job.jar

# 2. 如果 Checkpoint 都失败,重置 offset 从最新
kafka-consumer-groups.sh --bootstrap-server kafka:9092 \
    --group flink-ods-to-dwd-order \
    --reset-offsets --to latest --execute

# 3. 启动后验证
# - 查看 numRecordsIn > 0
# - 查看 ods_order 表有新数据
# - 查看 dwd_order 表有数据流入
```

**故障 2: ClickHouse 副本不一致**

```sql
-- 1. 查看副本状态
SELECT
    database,
    table,
    replica_name,
    is_session_expired,
    absolute_delay,
    queue_size
FROM system.replicas
WHERE database = 'realtime_olap'
  AND (is_session_expired = 1 OR absolute_delay > 60);

-- 2. 重连 ZK 会话
SYSTEM RESTART REPLICA realtime_olap.dwd_order;

-- 3. 强制重新同步(慎用)
ALTER TABLE realtime_olap.dwd_order 
MODIFY SETTING check_delay_period = 60;  -- 缩短检查间隔

-- 4. 如果数据真丢了,从 ODS 重放
-- 思路: 把 ODS 数据重新过一遍 ETL 写入 DWD
```

**故障 3: 物化视图卡住**

```sql
-- 1. 查看物化视图状态
SELECT
    name,
    total_rows,
    total_bytes,
    latest_modification_time
FROM system.tables
WHERE database = 'realtime_olap'
  AND engine LIKE '%MaterializedView%'
ORDER BY latest_modification_time ASC;

-- 2. 查看是否有 part 卡住
SELECT
    table,
    count() AS stuck_parts,
    sum(bytes_on_disk) AS stuck_bytes
FROM system.parts
WHERE database = 'realtime_olap'
  AND active
  AND modification_time < now() - INTERVAL 10 MINUTE
GROUP BY table
HAVING stuck_parts > 0;

-- 3. 重建物化视图
DETACH TABLE realtime_olap.mv_dws_user_order_1d ON CLUSTER 'treasurycluster';
DROP TABLE realtime_olap.mv_dws_user_order_1d ON CLUSTER 'treasurycluster';

-- 重新创建(会从 DWD 历史数据回填)
CREATE MATERIALIZED VIEW realtime_olap.mv_dws_user_order_1d
ON CLUSTER 'treasurycluster'
TO realtime_olap.dws_user_order_1d AS
SELECT ...;
```

**故障 4: 看板加载慢**

```sql
-- 1. 找出慢查询
SELECT
    query_duration_ms,
    substring(query, 1, 300) AS query_preview,
    read_rows,
    formatReadableSize(read_bytes) AS read_size
FROM system.query_log
WHERE event_time >= now() - INTERVAL 1 HOUR
  AND type = 'QueryFinish'
  AND query_duration_ms > 10000
ORDER BY query_duration_ms DESC
LIMIT 10;

-- 2. EXPLAIN 看执行计划
EXPLAIN PIPELINE
SELECT ... FROM ...;

-- 3. 常见优化
--   - 加主键索引
--   - 用物化视图替代实时计算
--   - 缩小查询时间范围
--   - 减少返回字段
```

### 8.7.3 应急开关(Kill Switch)

```sql
-- 场景: 故障时快速止血

-- 1. 停止 Flink 写入
--   在 Flink 控制台取消作业,或调用 REST API
--   POST /jobs/<job-id>/cancel

-- 2. 暂停物化视图
--   ClickHouse 23.x+ 支持暂停/恢复 MV
ALTER TABLE realtime_olap.dws_user_order_1d
MODIFY SETTING refresh_strategy = 'never';  -- 临时关闭自动刷新

-- 恢复:
-- ALTER TABLE realtime_olap.dws_user_order_1d
-- MODIFY SETTING refresh_strategy = 'always';

-- 3. 切换到备用数据集
--   Superset 端配置降级看板(直接查 ODS)
```

## 8.8 容量与限流保护

### 8.8.1 ClickHouse 写入限流

```sql
-- ============ 防止写入过快 ============

-- 1. 限制并发插入
SET max_insert_threads = 4;  -- 防止单次插入占满 CPU

-- 2. 触发背压的 part 数阈值
SET parts_to_throw_insert = 1000;   -- 超过 1000 个 part 拒绝写入
SET parts_to_delay_insert = 150;    -- 超过 150 个 part sleep 一下
SET max_delay_to_insert = 10;       -- 最多 sleep 10 秒

-- 3. 限制内存使用
SET max_memory_usage = 50000000000;  -- 50GB 硬限

-- 4. 单查询超时
SET max_execution_time = 30;         -- 30 秒超时
SET timeout_overflow_mode = 'throw';  -- 超时直接抛错,避免堆积
```

### 8.8.2 Flink 反压处理

```java
/**
 * 反压处理策略
 * 
 * 1. 监控: 必装 backpressure 指标
 * 2. 自适应: 当反压时自动降低并行度? 不,应该反之
 * 3. 真正的反压: 增加瓶颈算子的并行度
 */
public class BackpressureHandler {
    
    // 1. 检测反压
    public static boolean isBackpressure(StreamExecutionEnvironment env) {
        // 读取 flink_jobmanager_job_backPressureTimeMsPerSecond 指标
        // > 0.1 表示有反压
        return false; // 示例
    }
    
    // 2. 临时措施: 限制消费速率
    public static void applyRateLimit(DataStream<?> stream) {
        // 用 windowWithRate 限制每秒最多处理 N 条
        // 不推荐,治标不治本
    }
    
    // 3. 根本措施: 扩容
    //   - 增加 Kafka 分区
    //   - 增加 Flink 并行度
    //   - 增加 ClickHouse 节点
}
```

## 8.9 数据质量监控

### 8.9.1 数据质量维度

```
┌──────────────────────────────────────────────────────────────┐
│                      数据质量 5 大维度                          │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│  1. 完整性: 必填字段是否有 NULL                                 │
│     监控: countIf(order_id = '')                              │
│                                                              │
│  2. 准确性: 数值是否在合理范围                                  │
│     监控: countIf(amount < 0 OR amount > 1000000)             │
│                                                              │
│  3. 一致性: 跨表数据是否一致                                   │
│     监控: ODS 数量 vs DWD 数量                                │
│                                                              │
│  4. 时效性: 数据是否及时                                       │
│     监控: now() - max(event_time)                             │
│                                                              │
│  5. 唯一性: 主键是否唯一                                      │
│     监控: count() vs uniqExact(order_id)                      │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

### 8.9.2 自动化数据质量检查

```sql
-- ============ 每日数据质量检查报告 ============
CREATE VIEW IF NOT EXISTS realtime_olap.v_data_quality_daily ON CLUSTER 'treasurycluster' AS
SELECT
    toDate(etl_time)                                              AS dt,
    
    -- 完整性: 必填字段
    count()                                                       AS total_rows,
    countIf(order_id = '' OR order_id IS NULL)                    AS null_order_id,
    countIf(user_id = 0)                                          AS invalid_user,
    
    -- 准确性: 数值范围
    countIf(order_amount < 0)                                     AS negative_amount,
    countIf(order_amount > 10000000)                              AS too_large_amount,
    
    -- 唯一性
    count() - uniqExact(order_id)                                 AS duplicate_rows,
    
    -- 时效性
    now() - max(etl_time)                                         AS max_lag,
    
    -- 异常率
    100.0 * countIf(is_valid = 0) / count()                       AS invalid_pct
    
FROM realtime_olap.dwd_order
WHERE etl_time >= today() - INTERVAL 7 DAY
GROUP BY dt;

-- 查询今日数据质量
SELECT * FROM realtime_olap.v_data_quality_daily
WHERE dt = today()
FORMAT Vertical;
```

## 8.10 业务对账机制

### 8.10.1 跨系统对账

```sql
-- ============ ClickHouse vs 业务库(MySQL)对账 ============

-- 1. ClickHouse 侧订单数
SELECT
    toDate(order_time)             AS dt,
    count()                         AS ch_count,
    sum(order_amount)               AS ch_amount
FROM realtime_olap.dwd_order
WHERE order_time >= today() - INTERVAL 7 DAY
  AND is_valid = 1
GROUP BY dt;

-- 2. MySQL 侧订单数(假设已经同步过来)
SELECT
    toDate(create_time)            AS dt,
    count(*)                        AS mysql_count,
    sum(amount)                     AS mysql_amount
FROM mysql_source.orders
WHERE create_time >= today() - INTERVAL 7 DAY
  AND status != 'invalid'
GROUP BY dt;

-- 3. 差异对比(应有自动化的对账作业)
-- ch_count != mysql_count → 异常
-- ch_amount != mysql_amount → 异常
-- 差异 > 1% → P1 告警
```

### 8.10.2 跨层对账(自动)

```sql
-- 检查 DWS 数据是否和 DWD 一致
SELECT
    dwd.dt,
    dwd.actual_orders,
    dws.aggregated_orders,
    abs(dwd.actual_orders - dws.aggregated_orders) AS diff,
    100.0 * abs(dwd.actual_orders - dws.aggregated_orders) 
        / nullIf(dwd.actual_orders, 0)              AS diff_pct
FROM
    (SELECT
        toDate(order_time) AS dt,
        count()            AS actual_orders
    FROM realtime_olap.dwd_order
    WHERE order_time >= today() - INTERVAL 7 DAY
      AND is_valid = 1
    GROUP BY dt) dwd
LEFT JOIN
    (SELECT
        dt,
        sum(order_cnt)    AS aggregated_orders
    FROM realtime_olap.dws_user_order_1d
    WHERE dt >= today() - INTERVAL 7 DAY
    GROUP BY dt) dws
ON dwd.dt = dws.dt
WHERE diff_pct > 1
ORDER BY diff_pct DESC;
```

## 8.11 SLA 报告与改进

### 8.11.1 周报/月报模板

```markdown
# 实时数据链路 SLA 周报

## 整体情况
- 数据延迟 P99: X 秒 (目标 < 5 秒) ✅
- 系统可用性: 99.9% (目标 99.9%) ✅
- 数据准确率: 99.99% (目标 99.95%) ✅
- 故障次数: 2 次 (同比 -50%)

## 各层延迟
- ODS: 平均 1.2s, P99 3.5s
- DWD: 平均 2.5s, P99 8s (偏高,需优化)
- DWS: 平均 3.8s, P99 12s (偏高)
- 端到端: 平均 5s, P99 15s

## 故障清单
1. 06-15 14:30 Flink 作业崩溃 (原因: OOM, 措施: 调大内存)
2. 06-18 02:00 ClickHouse 副本同步延迟 (原因: 网络抖动, 已恢复)

## 优化项
1. DWD ClickHouse 写入批次调大到 10000
2. 物化视图加 TTL 减少合并压力
3. 新增 DWS 看板降级方案

## 下周计划
1. 接入新业务:直播带货
2. ClickHouse 23.x 升级评估
3. 实时大屏性能优化
```

### 8.11.2 持续改进机制

```
┌──────────────────────────────────────────────────────────────┐
│                 SLA 持续改进机制                                │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│  每日:                                                       │
│    - 看 SLA 监控仪表板                                        │
│    - 处理当日告警                                              │
│    - 记录异常事件                                              │
│                                                              │
│  每周:                                                       │
│    - SLA 周报                                                 │
│    - 复盘本周故障                                              │
│    - 排期优化任务                                              │
│                                                              │
│  每月:                                                       │
│    - 容量评估(数据增长/资源使用)                                │
│    - SLA 趋势分析                                              │
│    - 季度容量规划                                              │
│                                                              │
│  每季度:                                                     │
│    - 架构 review                                              │
│    - 技术债清理                                                │
│    - 升级/重构计划                                             │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

## 8.12 SLA 设计 Checklist

```
┌──────────────────────────────────────────────────────────────┐
│          SLA 体系建设 Checklist                                │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│  [分级]                                                      │
│  □ 业务分级(P0/P1/P2/P3/P4)                                 │
│  □ 每级 SLA 量化(延迟/可用性/一致性)                          │
│  □ SLA 写入合同/服务说明                                      │
│                                                              │
│  [延迟预算]                                                   │
│  □ 端到端延迟预算 < 5 秒                                      │
│  □ 各层延迟预算已拆解                                         │
│  □ 关键瓶颈环节有优化计划                                      │
│                                                              │
│  [监控]                                                      │
│  □ 4 个核心组件都有监控                                        │
│  □ 端到端监控看板                                             │
│  □ 业务指标监控(对账)                                         │
│  □ 告警分级清晰                                               │
│                                                              │
│  [告警]                                                      │
│  □ 关键指标都有告警                                            │
│  □ 告警分级(电话/IM/邮件)                                    │
│  □ 值班表+告警路由                                            │
│  □ 告警收敛规则                                               │
│                                                              │
│  [恢复]                                                      │
│  □ 故障 Runbook                                              │
│  □ 应急开关(限流/降级)                                        │
│  □ 跨层对账机制                                               │
│  □ 数据回溯方案                                               │
│                                                              │
│  [复盘]                                                      │
│  □ 故障复盘机制                                               │
│  □ 周报/月报制度                                              │
│  □ 持续改进计划                                               │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

## 8.13 终极心法

**实时性的本质是"管理用户的期望"**：
- 业务方说"我要实时",可能 1 秒就够,也可能 1 小时就够
- SLA 设计不是"越快越好",而是"够用就好 + 明确告知"
- 过度承诺 = 永远延期;清晰承诺 = 稳定交付

**可观测性是 SLA 的基础**：
- 没有监控的 SLA = 写在纸上的 SLA
- 监控不是为了"看",是为了"提前发现 + 快速定位"
- 监控覆盖率 > 90% 才算合格

**故障不可怕,可怕的是没有恢复机制**：
- 任何系统都会故障,关键是 MTTR
- 90% 故障可以用 Runbook 解决
- 10% 故障需要架构改进

## 8.14 下一章建议

- [06_best_practices.md](./06_best_practices.md) - 行业最佳实践
- [05_optimization.md](./05_optimization.md) - 性能优化深入
- [ClickHouse 官方监控文档](https://clickhouse.com/docs/operations/monitoring) - 监控配置
- [Apache Flink Metrics](https://nightlies.apache.org/flink/flink-docs-stable/docs/ops/metrics/) - Flink 指标
