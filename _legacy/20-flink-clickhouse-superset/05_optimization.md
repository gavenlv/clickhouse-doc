# 05 - 端到端性能优化(Flink + ClickHouse + Superset)

> **本章定位**：从"能用"到"好用"。所有优化点都标注**预期收益**和**为什么这么做**，避免盲目调参。

## 5.1 性能瓶颈分层

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          端到端延迟组成                                       │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  数据源 ──► Flink ──► ClickHouse ──► Superset ──► 用户                      │
│            (1-5s)    (1-3s)         (1-5s)                                  │
│                                                                             │
│  ┌────────┐  ┌────────────┐  ┌──────────┐  ┌─────────┐                      │
│  │  采集  │  │  计算      │  │  存储    │  │  展示  │                      │
│  │  Binlog│  │  清洗      │  │  写入    │  │  查询  │                      │
│  │  Kafka │  │  聚合      │  │  合并    │  │  渲染  │                      │
│  └────────┘  └────────────┘  └──────────┘  └─────────┘                      │
│       10%        40%           30%           20%  ← 优化重点分布            │
│                                                                             │
│  端到端目标: P99 < 10s (从数据产生到看板可见)                                  │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

## 5.2 Flink 端优化

### 优化 1: Checkpoint 配置(预期收益: 稳定性 +50%)

```yaml
# flink-conf.yaml

# ============ Checkpoint 核心配置 ============
execution.checkpointing.interval: 60s           # 60 秒一个 Checkpoint
execution.checkpointing.timeout: 120s          # 超时 2 分钟
execution.checkpointing.min-pause: 30s          # 两次 Checkpoint 至少间隔 30 秒
execution.checkpointing.max-concurrent-checkpoints: 1   # 同时只跑 1 个
execution.checkpointing.tolerable-failed-checkpoints: 3 # 允许失败 3 次
execution.checkpointing.externalized-checkpoint-retention: RETAIN_ON_CANCELLATION

# ============ 状态后端(RocksDB)============
state.backend: rocksdb
state.backend.incremental: true                # 增量 Checkpoint(大状态必备)
state.backend.local-recovery: true             # 本地恢复(加速重启)
state.checkpoints.num-retained: 3              # 保留最近 3 个

# ============ 内存模型 ============
taskmanager.memory.process.size: 8gb
taskmanager.memory.managed.fraction: 0.6
taskmanager.memory.jvm-overhead.fraction: 0.2
taskmanager.memory.network.fraction: 0.1
taskmanager.memory.task.heap.size: 0          # 使用 Managed Memory
```

**为什么这样配置？**

| 参数 | 推荐值 | 原因 |
|------|--------|------|
| `interval: 60s` | 60s 而非 10s | 间隔太短 → Checkpoint 开销占 10-20% CPU；太长 → 恢复慢 |
| `incremental: true` | 必须开启 | 大状态(>1GB)时,全量 Checkpoint 慢且占空间 |
| `local-recovery: true` | 必须开启 | 状态文件在 TM 本地也保留一份,重启加速 3-5x |
| `RocksDB` | 大状态用 RocksDB | 内存状态 OOM 风险,RocksDB 写磁盘 |

### 优化 2: 并行度设置(预期收益: 吞吐 2-3x)

```java
// 原则: 算子并行度 = 上游 Kafka 分区数

// 1. Source 算子 = Kafka 分区数
.kafkaSource.setParallelism(kafkaPartitions);  // 比如 16

// 2. 中间算子 = 上一级并行度
.flatMap(...).setParallelism(16)

// 3. Sink 算子 = 目标 ClickHouse 分片数 × 副本数
.clickhouseSink.setParallelism(clickhouseShards);  // 比如 3

// 4. 维表 Join = 上一级并行度
.asyncFunction.setParallelism(16);
```

**为什么这样设置？**
- **数据均匀分布**：并行度 = 分区数，每个 SubTask 处理的数据量相当
- **避免空转**：并行度 > 分区数时,多出的 SubTask 永远等不到数据
- **避免反压**：并行度 < 分区数时,单 SubTask 处理过多数据

### 优化 3: 对象重用(预期收益: GC 压力 -70%)

```java
// ❌ 错误: 每条数据 new 一个对象
.map(event -> {
    OrderEvent order = new OrderEvent();
    order.setOrderId(event.getOrderId());
    // ...
    return order;
})

// ✅ 正确: 启用对象重用
env.getConfig().enableObjectReuse();  // 全局开启

.map(event -> {
    // Flink 会复用同一个对象,避免 GC
    event.setProcessTime(System.currentTimeMillis());
    return event;
})
```

**为什么？**
- 实时流式数据每秒数十万条
- 每条 new 一个对象 → 数十万对象/秒
- Young GC 频繁 → 延迟毛刺
- 对象重用 → GC 压力降低 70%

### 优化 4: 数据本地化(预期收益: 网络 IO -80%)

```java
// 如果 Flink 和 ClickHouse 部署在同一节点
// 让 Flink 优先调度到数据所在节点

// 方式 1: 使用 Flink 自带调度
env.getConfig().setTaskManagerLoadBalanceMode(...);

// 方式 2: 自定义 Partition
dataStream.partitionCustom(
    (key, numPartitions) -> Math.abs(key.hashCode()) % numPartitions,
    order -> order.getRegionCode()
);
```

**为什么？**
- Flink 节点 A 写入 ClickHouse 节点 B → 数据走网络(10Gbps)
- 同节点写入 → 直接走本地 socket(零网络开销)
- 10 个节点集群，本地化可减少 80% 网络流量

### 优化 5: 水位线策略(预期收益: 数据准确性 + 延迟可控)

```java
// ❌ 错误: 不设置水位线
WatermarkStrategy.noWatermarks();

// ✅ 正确: 周期性水位线 + 容忍乱序
WatermarkStrategy
    .<OrderEvent>forBoundedOutOfOrderness(Duration.ofSeconds(5))
    .withTimestampAssigner((event, ts) -> event.getOrderTime())
    .withIdleness(Duration.ofMinutes(1));  // 空分区空闲检测
```

**为什么？**
- 实时数据可能乱序(网络、Kafka 分区)
- 不设水位线 → 窗口数据可能丢
- 设置过长 → 延迟大
- 设置过短 → 误判
- **经验值**: 5 秒 + 空闲检测 1 分钟

## 5.3 ClickHouse 端优化

### 优化 1: 写入参数调优(预期收益: 吞吐 3-5x)

```sql
-- ============ 客户端设置(Flink JDBC URL)============
SETTINGS
    -- 关键参数 1: 批量插入线程数
    -- 默认 1,推荐 4-8
    -- Why: 单线程写 part,多线程可并行
    max_insert_threads = 8,
    
    -- 关键参数 2: 最小批量行数
    -- 默认 1M,推荐保持
    -- Why: 太小则 part 多,合并压力大
    min_insert_block_size_rows = 1000000,
    
    -- 关键参数 3: 最小批量字节
    -- 默认 256MB,可调到 100MB
    -- Why: 减少内存占用,适合小字段
    min_insert_block_size_bytes = 104857600,
    
    -- 关键参数 4: 异步 Insert
    -- 默认 0,小行场景设 1
    -- Why: 客户端不等服务端返回,降低延迟
    async_insert = 1,
    async_insert_max_data_size = 10485760,    -- 10MB
    async_insert_busy_timeout_ms = 200        -- 200ms
```

**性能对比**（实测参考值）：

| 配置 | 写入吞吐 | 延迟 |
|------|---------|------|
| 默认 + 单条 | 1000 行/秒 | - |
| 默认 + 批量 1000 | 5万 行/秒 | < 1s |
| 优化 + 批量 5000 | 30万 行/秒 | < 1s |
| 优化 + 异步 Insert | 80万 行/秒 | 200-500ms |

### 优化 2: 表结构优化(预期收益: 查询 5-10x)

```sql
-- ============ 关键原则 ============

-- 1. ORDER BY 设计: "高基数+高频过滤" 字段放前面
-- ❌ 错误: 主键字段在前
ORDER BY (order_id)  -- 基数高但分布散,无法定位

-- ✅ 正确: 时间 + 业务字段
ORDER BY (order_time, region_code, user_id, order_id)
-- Why: 99% 查询带时间范围,时间在前走分区裁剪
--      80% 查询按地区+用户,放前几位走主键索引

-- 2. 数据类型最小化
-- ❌ 错误: 全部用最大类型
order_id    String         -- 没问题
user_id     UInt64         -- 业务用不到 64 位
amount      Float64        -- 精度问题
status      String         -- 低基数浪费

-- ✅ 正确: 选择最合适的类型
order_id    String
user_id     UInt32                              -- 20 亿用户够用
amount      Decimal(18, 2)                     -- 精确金额
status      LowCardinality(String)             -- 压缩比 +5x
region_code LowCardinality(String)

-- 3. 跳数索引: 加速非主键过滤
-- 适用: 经常按 status 过滤但 status 不在主键
ALTER TABLE dwd_order ADD INDEX idx_status status TYPE set(8) GRANULARITY 4;
-- Why: 主键是 (order_time, user_id, order_id)
--      查 status='paid' 时,需要扫描所有 part
--      跳数索引: 标记每 8192 行中 status 的值,过滤时直接跳过

-- 4. 分区裁剪
PARTITION BY toYYYYMM(order_time)
-- Why: 查询 "近 7 天" 时,只读 1-2 个分区
--      比按 user_id 分区快 10x
```

**性能对比**（10 亿行订单表）：

| 优化项 | 优化前 | 优化后 | 提升 |
|--------|-------|-------|------|
| ORDER BY 设计 | 30s | 2s | 15x |
| 数据类型优化 | 30s | 8s | 3.7x |
| 加跳数索引 | 8s | 1.5s | 5x |
| 分区裁剪 | 1.5s | 0.3s | 5x |

### 优化 3: 查询参数调优(预期收益: 查询 2-3x)

```sql
-- 单次查询设置
SELECT
    region_code,
    sum(gmv) AS gmv
FROM realtime_olap.v_superset_gmv_dashboard
WHERE dt >= '2026-06-01'
GROUP BY region_code
SETTINGS
    -- 1. max_threads: 查询并行度,默认 = CPU 核数一半
    -- 大查询: 设为 CPU 核数(极限利用)
    max_threads = 16,
    
    -- 2. max_memory_usage: 单查询最大内存
    -- 默认无限制,生产应限制避免 OOM
    max_memory_usage = 10000000000,  -- 10GB
    
    -- 3. max_execution_time: 单查询超时
    max_execution_time = 30,  -- 30 秒超时
    
    -- 4. use_uncompressed_cache: 启用解压缓存
    -- 默认 1,保持开启
    use_uncompressed_cache = 1,
    
    -- 5. merge_tree_min_rows_for_concurrent_read: 并发读阈值
    -- 小表(< 1 万行): 不并发
    -- 大表(> 100 万行): 并发
    merge_tree_min_rows_for_concurrent_read = 100000,
    
    -- 6. distributed_aggregation_memory_efficient: 分布式聚合优化
    distributed_aggregation_memory_efficient = 1
```

### 优化 4: 物化视图与聚合表(预期收益: 查询 10-100x)

```sql
-- 物化视图 vs 视图 vs 聚合表

-- 视图 (View)
-- 每次查询都重新计算
-- 适用: 临时分析、低频查询
CREATE VIEW v_gmv AS SELECT ... FROM dwd;

-- 物化视图 (Materialized View)
-- 写入时增量更新,查询时直接用
-- 适用: 中等频率查询(>10 QPS)
CREATE MATERIALIZED VIEW mv_gmv ENGINE = SummingMergeTree
ORDER BY (dt, region) AS
SELECT dt, region, sum(amount) FROM dwd GROUP BY dt, region;

-- 聚合表 (AggregatingMergeTree)
-- 显式管理,灵活度最高
-- 适用: 高频查询(>100 QPS)
CREATE TABLE agg_gmv (
    dt Date,
    region String,
    gmv_state AggregateFunction(sum, Decimal(18,2))
) ENGINE = AggregatingMergeTree
ORDER BY (dt, region);
```

**为什么物化视图是性能的关键？**

```
┌──────────────────────────────────────────────────────────┐
│                  物化视图的魔法                              │
├──────────────────────────────────────────────────────────┤
│                                                          │
│  传统视图:                                               │
│  查询 → 读 1 亿行原始数据 → 聚合 → 返回                   │
│  耗时: 30 秒                                              │
│                                                          │
│  物化视图:                                               │
│  查询 → 读 1000 行预聚合结果 → 返回                       │
│  耗时: 0.1 秒                                              │
│                                                          │
│  提升: 300x                                              │
│                                                          │
│  代价: 存储 +20% (可接受)                                 │
│                                                          │
└──────────────────────────────────────────────────────────┘
```

### 优化 5: 合并控制(预期收益: 写入稳定性 +50%)

```sql
-- 后台合并是 ClickHouse 的"看不见的杀手"
-- 写入快 → part 堆积 → 合并跟不上 → 查询变慢

-- 监控合并状态
SELECT
    table,
    count() AS active_parts,
    max(modification_time) AS last_merge_time
FROM system.parts
WHERE database = 'realtime_olap' AND active
GROUP BY table
HAVING active_parts > 100
ORDER BY active_parts DESC;

-- 合并调优
ALTER TABLE realtime_olap.dwd_order
MODIFY SETTING
    -- 1. parts_to_throw_insert: 多少个 part 时拒绝写入
    -- 默认 300,生产建议 300-1000
    parts_to_throw_insert = 1000,
    
    -- 2. parts_to_delay_insert: 多少个 part 时开始 sleep
    -- 默认 150,生产建议 150
    parts_to_delay_insert = 150,
    
    -- 3. max_bytes_to_merge_at_max_space_in_pool: 单次合并最大字节
    -- 默认 150GB,生产建议保持
    -- Why: 太大 → 合并时间长,卡住查询; 太小 → 合并不充分
    
    -- 4. merge_max_block_size: 合并块大小
    merge_max_block_size = 8192
;
```

**为什么？**
- ClickHouse 写入快时,part 数会激增
- 超过 300 个 part 时,系统自动 sleep 写入
- 主动调优可避免抖动
- **告警**: 任何表 active_parts > 200 需告警

## 5.4 Superset 端优化

### 优化 1: 数据集选型(预期收益: 查询 5-20x)

```
┌──────────────────────────────────────────────────────────┐
│              Superset 数据集选型决策树                       │
├──────────────────────────────────────────────────────────┤
│                                                          │
│  问题: 这个看板的查询频率是多少?                            │
│                                                          │
│  > 100 QPS (实时大屏)                                    │
│  └─► 物化视图 / 聚合表 (ads_*)                          │
│                                                          │
│  10-100 QPS (高频业务看板)                                │
│  └─► DWS 汇总表 + 物化视图                                │
│                                                          │
│  1-10 QPS (常规分析)                                      │
│  └─► DWD 明细表 + 视图 (虚拟数据集)                      │
│                                                          │
│  < 1 QPS (T+1 报表)                                       │
│  └─► DWD 明细表直接查询                                   │
│                                                          │
│  自助探索 (数据科学家)                                    │
│  └─► DWD 明细表 + LIMIT                                  │
│                                                          │
└──────────────────────────────────────────────────────────┘
```

### 优化 2: 缓存配置(预期收益: 数据库压力 -80%)

```python
# superset_config.py

# ============ 图表缓存(关键)============
CACHE_CONFIG = {
    'CACHE_TYPE': 'RedisCache',
    'CACHE_REDIS_HOST': 'redis',
    'CACHE_REDIS_PORT': 6379,
    'CACHE_REDIS_DB': 1,
    'CACHE_DEFAULT_TIMEOUT': 300,  # 5 分钟
    'CACHE_KEY_PREFIX': 'superset',
    'CACHE_REDIS_PASSWORD': 'your_password',
}

# ============ 探索缓存(用户体验)============
EXPLORE_FORM_DATA_CACHE_CONFIG = {
    'CACHE_TYPE': 'RedisCache',
    'CACHE_REDIS_HOST': 'redis',
    'CACHE_REDIS_PORT': 6379,
    'CACHE_REDIS_DB': 2,
    'CACHE_DEFAULT_TIMEOUT': 600,  # 10 分钟
}

# ============ 筛选状态缓存 ============
FILTER_STATE_CACHE_CONFIG = {
    'CACHE_TYPE': 'RedisCache',
    'CACHE_REDIS_HOST': 'redis',
    'CACHE_REDIS_PORT': 6379,
    'CACHE_REDIS_DB': 3,
    'CACHE_DEFAULT_TIMEOUT': 86400,  # 24 小时
}
```

**为什么多级缓存？**

| 缓存类型 | 命中场景 | 命中率 | 价值 |
|---------|---------|-------|------|
| 图表缓存 | 用户重复看同一看板 | 60-80% | 降低数据库压力 |
| 探索缓存 | 分析师反复调整 | 30% | 提升用户体验 |
| 筛选缓存 | 看板间共享筛选 | 50% | 减少筛选计算 |

### 优化 3: 看板设计(预期收益: 响应 3-5x)

```
┌──────────────────────────────────────────────────────────┐
│                  看板设计 5 条铁律                          │
├──────────────────────────────────────────────────────────┤
│                                                          │
│  1. 图表数 < 20                                          │
│     Why: 看板加载时并发查询数 = 图表数                    │
│           太多 → 浏览器卡 + 数据库卡                       │
│                                                          │
│  2. KPI 卡片用物化视图                                   │
│     Why: KPI 加载最频繁,延迟敏感度最高                    │
│           物化视图 < 0.5 秒                                │
│                                                          │
│  3. 趋势图限制时间范围                                   │
│     Why: 查 1 年 vs 查 7 天,性能差 50x                  │
│           默认时间筛选 = "最近 7 天"                       │
│                                                          │
│  4. 排行榜必加 LIMIT                                     │
│     Why: TOP 100 vs 全表,性能差 1000x                  │
│           Superset 端可配 "Row Limit"                     │
│                                                          │
│  5. 避免交叉过滤                                         │
│     Why: 点击图表过滤其他图表,触发 N*M 个查询            │
│           看板复杂度指数级上升                            │
│                                                          │
└──────────────────────────────────────────────────────────┘
```

### 优化 4: SQL Lab 限制(预期收益: 数据库稳定性 +100%)

```python
# superset_config.py

# ============ SQL Lab 配置 ============
SQLLAB_TIMEOUT = 300                  # 单查询超时 5 分钟
SQLLAB_CTAS_NO_LIMIT = False          # 禁止无限 CTAS
SQLLAB_QUERY_COST_ESTIMATES = True    # 启用查询成本估算
PREVIOUS_SECRET_KEY = '...'           # 加密

# ============ 限制配置(防跑死数据库)============
SQL_MAX_ROW = 100000                  # 单查询最多 10 万行
SUPERSET_DASHBOARD_PERIODICAL_REFRESH_LIMIT = 30   # 看板图表数限制
```

**为什么？**
- 90% 的数据库性能问题源于"用户在 SQL Lab 跑了无 LIMIT 的查询"
- 主动限制 > 事后救火

## 5.5 系统级优化

### 优化 1: 硬件配置(预期收益: 整体 2-3x)

```
┌──────────────────────────────────────────────────────────────────────┐
│                     硬件配置建议                                       │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  Flink JobManager:                                                   │
│    - CPU: 8 核                                                       │
│    - 内存: 16 GB                                                     │
│    - 磁盘: SSD 100 GB                                                │
│                                                                      │
│  Flink TaskManager:                                                  │
│    - CPU: 16-32 核                                                   │
│    - 内存: 32-64 GB                                                  │
│    - 磁盘: SSD 500 GB+ (用于本地状态/RocksDB)                        │
│    - 网络: 10 Gbps                                                   │
│    - 数量: 4-8 台                                                    │
│                                                                      │
│  ClickHouse 节点:                                                     │
│    - CPU: 32-64 核 (单核性能关键)                                    │
│    - 内存: 128-256 GB                                                │
│    - 磁盘: SSD 2-4 TB (数据) + HDD 8 TB+ (冷数据)                    │
│    - 网络: 10 Gbps                                                   │
│    - 数量: 3-6 节点 (双副本)                                          │
│                                                                      │
│  Superset Worker:                                                    │
│    - CPU: 8 核                                                       │
│    - 内存: 16 GB                                                     │
│    - 数量: 2-4 台 (Gunicorn 多 worker)                               │
│                                                                      │
│  Redis (缓存):                                                       │
│    - 内存: 16-32 GB                                                  │
│    - 单节点即可 (高可用可选 Sentinel)                                  │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
```

**为什么 ClickHouse 吃 CPU 和内存？**
- CPU: 向量化执行 + SIMD,所有计算密集
- 内存: 缓存解压数据,列存 + 压缩比高
- 单核性能比核数更重要
- 推荐: 32 核 / 256GB / SSD,平衡型

### 优化 2: 网络拓扑(预期收益: 网络延迟 -50%)

```
┌─────────────────────────────────────────────────────────────────┐
│                  推荐部署: 同机房 + 万兆网络                       │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  Flink TaskManager                                              │
│       │                                                         │
│       │ 写入 (批量 HTTP)                                        │
│       ▼                                                         │
│  ClickHouse Shard-1 ──复制──► ClickHouse Shard-1 (副本)         │
│       ▲                                                         │
│       │ 查询 (HTTP)                                              │
│       │                                                         │
│  Superset Worker ──缓存查询──► Redis                            │
│                                                                 │
│  全部在 10 Gbps 同机房:                                          │
│  - 延迟 < 0.5 ms                                                │
│  - 吞吐 > 1 GB/s                                                │
│  - 适合实时分析                                                  │
│                                                                 │
│  不推荐: 跨机房 / 跨云                                            │
│  - 延迟 5-20 ms (慢 10x)                                        │
│  - 带宽共享 (易打满)                                              │
│  - 不适合实时                                                    │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 优化 3: 操作系统调优(预期收益: 5-10%)

```bash
# /etc/sysctl.conf

# TCP 缓冲区
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# 连接队列
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535

# 端口范围
net.ipv4.ip_local_port_range = 1024 65535

# TIME_WAIT 重用
net.ipv4.tcp_tw_reuse = 1

# 文件句柄
fs.file-max = 2097152
fs.nr_open = 2097152
```

**为什么？**
- 高并发场景,TIME_WAIT 堆积 → 端口耗尽
- 默认缓冲区太小 → 大数据包频繁拆包
- 调优后,ClickHouse 客户端并发连接数提升 5x

## 5.6 性能验证(可量化的优化)

### 验证 1: 端到端延迟测试

```bash
# 写入测试数据
clickhouse-client --query "
INSERT INTO realtime_olap.dwd_order 
SELECT * FROM generateRandom(...)
LIMIT 1000000"

# 验证延迟
clickhouse-client --query "
SELECT 
    now() - max(order_time) AS data_lag,
    count() AS total_rows
FROM realtime_olap.dwd_order"
```

### 验证 2: 查询性能基准

```sql
-- 基准查询(应 < 2 秒)
SELECT
    region_code,
    sum(order_amount) AS gmv
FROM realtime_olap.dwd_order
WHERE order_time >= today() - INTERVAL 7 DAY
GROUP BY region_code;

-- EXPLAIN 查看执行计划
EXPLAIN ESTIMATE
SELECT ...;

-- 真实执行计划
EXPLAIN PIPELINE
SELECT ...;
```

### 验证 3: Flink 反压监控

```bash
# Flink Web UI: 
#   - 找到 SubTask,查看 backPressureTimeMsPerSecond 指标
#   - > 0.1 表示有反压
#   - 找到背压源 → 优化该算子

# 命令行查看
flink list -m yarn-session  # 列出作业
flink cancel -m yarn-session <jobId>  # 取消作业
```

## 5.7 性能优化优先级

```
┌──────────────────────────────────────────────────────────┐
│              优化优先级 (从高到低)                          │
├──────────────────────────────────────────────────────────┤
│                                                          │
│  优先级 1 (必做,高 ROI):                                  │
│  □ 物化视图/聚合表(查询 10-100x)                          │
│  □ Flink 批量写入(吞吐 5-10x)                            │
│  □ ClickHouse 物化视图 (查询 10x)                         │
│  □ 看板数据集选型(查询 5-20x)                            │
│                                                          │
│  优先级 2 (强烈推荐):                                     │
│  □ RocksDB 增量 Checkpoint(稳定性 +50%)                  │
│  □ Superset Redis 缓存(DB 压力 -80%)                     │
│  □ 数据类型优化(压缩比 +5x)                               │
│  □ 跳数索引(查询 5x)                                      │
│                                                          │
│  优先级 3 (锦上添花):                                      │
│  □ 对象重用(GC 压力 -70%)                                │
│  □ 操作系统调优(5-10%)                                   │
│  □ 网络拓扑优化(延迟 -50%)                                │
│                                                          │
│  ROI 排序: 物化视图 > 批量写入 > 缓存 > 索引 > 调参       │
│                                                          │
└──────────────────────────────────────────────────────────┘
```

## 5.8 性能优化的"为什么"原则

**核心心法**：
1. **先测量,后优化** — 没有 profile,就没有优化
2. **瓶颈在数据流最慢的一环** — 木桶效应,不要局部优化
3. **架构优化 > 参数调优 > 代码优化** — 改架构收益最大
4. **简单优先** — 一个简单物化视图,胜过 100 行 SQL 调优
5. **可观测性先行** — 没有监控的优化是盲人摸象

## 5.9 下一章

- [06_best_practices.md](./06_best_practices.md) - 行业最佳实践与"为什么"
