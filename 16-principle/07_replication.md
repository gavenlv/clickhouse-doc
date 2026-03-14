# 复制和分片原理

本文档介绍 ClickHouse 的数据复制和分片机制，帮助你理解分布式架构。

## 概述

ClickHouse 支持水平扩展，通过复制和分片实现高可用和负载均衡。

## 复制 vs 分片

```
┌─────────────────────────────────────────────────────────────────┐
│                    复制 vs 分片                                   │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  分片 (Sharding): 水平切分数据                                   │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │  原始数据: [1,2,3,4,5,6,7,8,9,10]                     │   │
│  │         │                                                │   │
│  │         ▼                                                │   │
│  │   Shard 1: [1,4,7,10]  (user_id % 3 = 1)              │   │
│  │   Shard 2: [2,5,8]      (user_id % 3 = 2)              │   │
│  │   Shard 3: [3,6,9]      (user_id % 3 = 0)              │   │
│  │                                                          │   │
│  │   目的: 扩展存储容量和查询吞吐                           │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                 │
│  副本 (Replication): 冗余存储                                   │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │  Shard 1:                                                │   │
│  │   ├── Replica 1: [数据副本A]                           │   │
│  │   └── Replica 2: [数据副本A']  (完全相同)            │   │
│  │                                                          │   │
│  │   目的: 高可用、数据安全                                  │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                 │
│  集群拓扑:                                                      │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │  Cluster                                                 │   │
│  │  ├── Shard 1                                            │   │
│  │  │   ├── Replica 1.1 (本地)                           │   │
│  │  │   └── Replica 1.2 (远程)                           │   │
│  │  ├── Shard 2                                            │   │
│  │  │   ├── Replica 2.1                                  │   │
│  │  │   └── Replica 2.2                                  │   │
│  │  └── Shard 3                                            │   │
│  │      ├── Replica 3.1                                  │   │
│  │      └── Replica 3.2                                  │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

## 复制架构

### 复制原理

```
┌─────────────────────────────────────────────────────────────┐
│                 ClickHouse 复制架构                           │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  ZooKeeper / ClickHouse Keeper                              │
│         │                                                    │
│         │ 协调                                               │
│         ▼                                                    │
│  ┌──────────────────────────────────────────────────────┐  │
│  │                    数据复制流程                         │  │
│  ├──────────────────────────────────────────────────────┤  │
│  │                                                      │  │
│  │   Client ──► Replica 1 (主)                        │  │
│  │                │                                     │  │
│  │                ▼                                     │  │
│  │            Keeper (记录操作)                         │  │
│  │                │                                     │  │
│  │                ▼                                     │  │
│  │   Replica 1 ◄─────── 同步 ───────► Replica 2       │  │
│  │                                                      │  │
│  └──────────────────────────────────────────────────────┘  │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### ReplicatedMergeTree 工作流程

```
┌─────────────────────────────────────────────────────────────┐
│             ReplicatedMergeTree 工作流程                      │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  1. 写入操作                                                │
│  ┌─────────────────────────────────────────────────────┐  │
│  │  INSERT ──► Part ──► Keeper (记录 log entry)        │  │
│  └─────────────────────────────────────────────────────┘  │
│                                                              │
│  2. 副本同步                                                │
│  ┌─────────────────────────────────────────────────────┐  │
│  │  副本从 Keeper 拉取 log entry                        │  │
│  │  下载对应的 Part 文件                                │  │
│  │  本地合并                                            │  │
│  └─────────────────────────────────────────────────────┘  │
│                                                              │
│  3. 合并操作                                                │
│  ┌─────────────────────────────────────────────────────┐  │
│  │  某个副本发起合并                                     │  │
│  │  ──► Keeper 记录合并计划                              │  │
│  │  ──► 所有副本执行合并                                  │  │
│  │  ──► 生成新的 Part                                   │  │
│  └─────────────────────────────────────────────────────┘  │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

## 创建复制表

### 单副本表

```sql
-- 创建本地 MergeTree 表
CREATE TABLE tutorial.local_table (
    id UInt64,
    event_date Date,
    user_id UInt32,
    value Float64
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_date)
ORDER BY (event_date, user_id);
```

### 复制表

```sql
-- 创建 ReplicatedMergeTree 表 (节点 1)
CREATE TABLE tutorial.replicated_table (
    id UInt64,
    event_date Date,
    user_id UInt32,
    value Float64
) ENGINE = ReplicatedMergeTree(
    '/clickhouse/tables/{shard}/tutorial/replicated_table',
    '{replica}'
)
PARTITION BY toYYYYMM(event_date)
ORDER BY (event_date, user_id);

-- 参数说明:
-- /clickhouse/tables/{shard}/database/table: ZooKeeper 路径
-- {shard}: 分片编号
-- {replica}: 副本编号
```

### 使用默认路径

```sql
-- 简化创建 (使用配置文件中的默认路径)
CREATE TABLE tutorial.replicated_simple (
    id UInt64,
    event_date Date,
    user_id UInt32,
    value Float64
) ENGINE = ReplicatedMergeTree()
PARTITION BY toYYYYMM(event_date)
ORDER BY (event_date, user_id);
```

## 分片架构

### 分片原理

```
┌─────────────────────────────────────────────────────────────────┐
│                    ClickHouse 分片架构                            │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  集群拓扑:                                                      │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │              Cluster                                       │  │
│  │                                                            │  │
│  │   Shard 1         Shard 2         Shard 3              │  │
│  │   ┌─────────┐     ┌─────────┐     ┌─────────┐           │  │
│  │   │Replica1│     │Replica1│     │Replica1│           │  │
│  │   │Replica2│     │Replica2│     │Replica2│           │  │
│  │   └─────────┘     └─────────┘     └─────────┘           │  │
│  │                                                            │  │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                 │
│  数据分布:                                                      │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │ Shard 1: user_id % 3 = 0                               │  │
│  │ Shard 2: user_id % 3 = 1                               │  │
│  │ Shard 3: user_id % 3 = 2                               │  │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 分片键原理

```
┌─────────────────────────────────────────────────────────────────┐
│                    分片键工作原理                                  │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  分片键 = hash(列值) % 分片数量                                  │
│                                                                 │
│  例: sharding_key = sipHash64(user_id)                         │
│      分片数 = 3                                                 │
│                                                                 │
│      user_id=1  → hash=5837  → 5837 % 3 = 1 → Shard 2         │
│      user_id=2  → hash=2948  → 2948 % 3 = 2 → Shard 3         │
│      user_id=3  → hash=9182  → 9182 % 3 = 0 → Shard 1         │
│      user_id=4  → hash=1234  → 1234 % 3 = 1 → Shard 2         │
│                                                                 │
│  分片键类型:                                                    │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │ 1. 随机分片: rand()                                    │   │
│  │    - 优点: 数据均匀分布                                │   │
│  │    - 缺点: 无法局部查询,所有分片都要扫描               │   │
│  │                                                         │   │
│  │ 2. 哈希分片: sipHash64(user_id)                       │   │
│  │    - 优点: 相同值在同一分片,支持局部查询               │   │
│  │    - 缺点: 可能热点                                    │   │
│  │                                                         │   │
│  │ 3. 范围分片: toYYYYMM(event_date)                      │   │
│  │    - 优点: 时间范围查询局部化                          │   │
│  │    - 缺点: 数据倾斜(冷热不均)                          │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 分布式查询流程

```
┌─────────────────────────────────────────────────────────────────┐
│                    分布式查询执行流程                              │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  查询: SELECT count(), sum(value) FROM events                  │
│        WHERE date = '2024-01-01'                                │
│                                                                 │
│  Step 1: 查询规划                                                │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │  ┌─────────────────────────────────────────────────┐   │   │
│  │  │  Distributed                                  │   │   │
│  │  │  ├── 分解为子查询发送到各分片                  │   │   │
│  │  │  └── SELECT count(), sum(value) FROM local_  │   │   │
│  │  │        events WHERE date = '2024-01-01'       │   │   │
│  │  └─────────────────────────────────────────────────┘   │   │
│  └─────────────────────────────────────────────────────────┘   │
│                            │                                     │
│                            ▼                                     │
│  Step 2: 并行执行                                               │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │  ┌─────────┐  ┌─────────┐  ┌─────────┐                │   │
│  │  │ Shard 1 │  │ Shard 2 │  │ Shard 3 │                │   │
│  │  │ count:5 │  │count:8  │  │count:3  │                │   │
│  │  │ sum:50  │  │sum:120  │  │sum:25   │                │   │
│  │  └────┬────┘  └────┬────┘  └────┬────┘                │   │
│  └───────┼───────────┼───────────┼─────────────────────────┘   │
│          └───────────┴───────────┘                              │
│                            │                                     │
│                            ▼                                     │
│  Step 3: 合并结果                                               │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │  count = 5 + 8 + 3 = 16                                │   │
│  │  sum   = 50 + 120 + 25 = 195                          │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 分布式聚合

```
┌─────────────────────────────────────────────────────────────────┐
│                    两阶段聚合                                      │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  Stage 1: 每个分片本地聚合                                       │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │  Shard 1: SELECT user_id, count() AS cnt              │   │
│  │           FROM local_events GROUP BY user_id          │   │
│  │           → {user_id:1, cnt:100}, {user_id:2, cnt:80} │   │
│  │                                                          │   │
│  │  Shard 2: → {user_id:1, cnt:120}, {user_id:3, cnt:90}│   │
│  │                                                          │   │
│  │  Shard 3: → {user_id:2, cnt:70}, {user_id:3, cnt:110}│   │
│  └─────────────────────────────────────────────────────────┘   │
│                            │                                     │
│                            ▼                                     │
│  Stage 2: 协调节点合并                                          │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │  user_id: 1 → 100 + 120 = 220                        │   │
│  │  user_id: 2 → 80 + 70 = 150                          │   │
│  │  user_id: 3 → 90 + 110 = 200                         │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                 │
│  分布式聚合函数:                                                 │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │  count()       → 自动分布式                            │   │
│  │  sum()         → 自动分布式                            │   │
│  │  uniq()        → uniqMerge()   (需要手动合并)         │   │
│  │  quantile()    → quantileMerge() (需要手动合并)       │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 跨分片 JOIN

```
┌─────────────────────────────────────────────────────────────────┐
│                    跨分片 JOIN 策略                                │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  1. 广播 JOIN (小表)                                             │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │  users 表较小 → 复制到所有分片                         │   │
│  │                                                           │   │
│  │  Shard 1: [events] + [users 副本]                     │   │
│  │  Shard 2: [events] + [users 副本]                     │   │
│  │  Shard 3: [events] + [users 副本]                     │   │
│  └─────────────────────────────────────────────────────────┘   │
│                            │                                     │
│                            ▼                                     │
│  2. 哈希 JOIN (大表)                                            │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │  按 JOIN key 重新分配数据                              │   │
│  │                                                           │   │
│  │  Shard 1: events.user_id%3=0 + users.id%3=0           │   │
│  │  Shard 2: events.user_id%3=1 + users.id%3=1           │   │
│  │  Shard 3: events.user_id%3=2 + users.id%3=2           │   │
│  └─────────────────────────────────────────────────────────┘   │
│                            │                                     │
│                            ▼                                     │
│  3. 全局 JOIN                                                   │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │  收集到协调节点处理                                     │   │
│  │                                                           │   │
│  │  [Sh1_events] ─┐                                        │   │
│  │  [Sh2_events] ─┼──► 合并 ──► JOIN ──► 返回            │   │
│  │  [Sh3_events] ─┘    协调节点                          │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 创建分布式表

```sql
-- 创建本地表 (每个分片)
CREATE TABLE tutorial.local_events (
    id UInt64,
    event_date Date,
    user_id UInt32,
    event_type String,
    value Float64
) ENGINE = ReplicatedMergeTree()
PARTITION BY toYYYYMM(event_date)
ORDER BY (event_date, user_id);

-- 创建分布式表
CREATE TABLE tutorial.distributed_events (
    id UInt64,
    event_date Date,
    user_id UInt32,
    event_type String,
    value Float64
) ENGINE = Distributed(
    'treasurycluster',          -- 集群名称
    'tutorial',                 -- 数据库
    'local_events',             -- 本地表
    sipHash64(user_id)          -- 分片键
);
```

### 分片键选择

```sql
-- 随机分片 (负载均衡，但无法局部查询)
ENGINE = Distributed(cluster, db, table, rand())

-- 哈希分片 (按用户分片)
ENGINE = Distributed(cluster, db, table, sipHash64(user_id))

-- 按日期分片 (适合时间序列)
ENGINE = Distributed(cluster, db, table, toYYYYMM(event_date))
```

## 复制和分片实战

### 创建测试表

```sql
-- 1. 创建本地复制表
CREATE TABLE IF NOT EXISTS tutorial.repl_table (
    id UInt64,
    event_date Date,
    user_id UInt32,
    event_type String,
    value Float64
) ENGINE = ReplicatedMergeTree()
PARTITION BY toYYYYMM(event_date)
ORDER BY (event_date, user_id);

-- 2. 创建分布式表
CREATE TABLE IF NOT EXISTS tutorial.dist_table AS tutorial.repl_table
ENGINE = Distributed('treasurycluster', 'tutorial', 'repl_table', rand());
```

### 插入数据

```sql
-- 插入数据到分布式表
INSERT INTO tutorial.dist_table
SELECT 
    number,
    toDate('2024-01-01') + (number % 30),
    number % 1000,
    ['click', 'view', 'purchase'][number % 3 + 1],
    rand() / 100.0
FROM numbers(100000);
```

### 验证复制

```sql
-- 查看副本状态
SELECT 
    database,
    table,
    replica_name,
    replica_path,
    total_replicas,
    active_replicas,
    queue_size,
    inserts_in_queue,
    merges_in_queue
FROM system.replicas
WHERE table = 'repl_table';

-- 查看数据分布
SELECT 
    'Replica 1' AS replica,
    count() AS rows
FROM tutorial.repl_table
UNION ALL
SELECT 
    'Replica 2' AS replica,
    count() AS rows
FROM tutorial.repl_table;
```

## 复制机制详解

### 1. INSERT 流程

```
INSERT 流程:

1. Client 发送 INSERT 到一个副本
   │
2. 该副本接收数据，创建 Part
   │
3. 将操作写入 Keeper (log entry)
   │
4. 其他副本从 Keeper 拉取 log entry
   │
5. 下载对应的 Part 文件
   │
6. 验证数据完整性
   │
7. 注册到本地表
```

### 2. 合并流程

```
合并流程:

1. 某个副本发起合并
   │
2. 创建合并任务，写入 Keeper
   │
3. 所有副本获取合并任务
   │
4. 各副本执行合并
   │
5. 生成新的 Part
   │
6. 清理旧 Parts
```

### 3. 故障恢复

```
故障恢复:

1. 副本故障
   │
2. 检测到不可用
   │
3. 从其他副本同步数据
   │
4. 追赶合并进度
   │
5. 恢复完成
```

## 监控复制

### 查看复制状态

```sql
-- 查看副本状态
SELECT 
    database,
    table,
    replica_name,
    is_stale,
    is_readonly,
    total_replicas,
    active_replicas,
    queue_size,
    last_queue_update
FROM system.replicas;

-- 查看复制队列
SELECT 
    database,
    table,
    replica_name,
    type,
    create_time,
    num_tries,
    last_exception
FROM system.replication_queue
LIMIT 10;
```

### 查看数据一致性

```sql
-- 检查各副本数据一致性
SELECT 
    database,
    table,
    replica_name,
    rows,
    formatReadableSize(bytes) AS size
FROM system.parts
WHERE database = 'tutorial' 
  AND table = 'repl_table'
  AND active = 1
ORDER BY replica_name, name;
```

## 高可用配置

### 典型集群配置

```xml
<!-- config.xml -->
<remote_servers>
    <my_cluster>
        <shard>
            <replica>
                <host>clickhouse1</host>
                <port>9000</port>
            </replica>
            <replica>
                <host>clickhouse2</host>
                <port>9000</port>
            </replica>
        </shard>
    </my_cluster>
</remote_servers>

<!-- macros -->
<macros>
    <shard>1</shard>
    <replica>1</replica>
</macros>
```

### 配置 Keeper

```xml
<!-- keeper.xml -->
<keeper_server>
    <tcp_port>9181</tcp_port>
    <server_id>1</server_id>
    <raft_configuration>
        <server>
            <id>1</id>
            <hostname>keeper1</hostname>
            <port>9444</port>
        </server>
        <server>
            <id>2</id>
            <hostname>keeper2</hostname>
            <port>9444</port>
        </server>
        <server>
            <id>3</id>
            <hostname>keeper3</hostname>
            <port>9444</port>
        </server>
    </raft_configuration>
</keeper_server>
```

## 最佳实践

### 1. 复制表设计

```sql
-- 使用默认路径简化配置
CREATE TABLE t (...) ENGINE = ReplicatedMergeTree()
ORDER BY ...

-- 合理设置分区
PARTITION BY toYYYYMM(event_date)

-- 避免过多分区
-- 分区数量 < 1000
```

### 2. 分片键选择

```sql
-- 按业务选择分片键
-- 原则:
-- 1. 查询局部性 (同一用户数据在同一分片)
-- 2. 负载均衡 (数据均匀分布)
-- 3. 避免跨分片 JOIN
```

### 3. 监控要点

```sql
-- 监控复制延迟
SELECT 
    table,
    absolute_delay
FROM system.replicas
WHERE absolute_delay > 60;

-- 监控队列
SELECT 
    table,
    queue_size,
    merges_in_queue
FROM system.replicas
WHERE queue_size > 100;
```

## 相关 SQL

### 查看集群信息

```sql
-- 查看集群
SELECT * FROM system.clusters;

-- 查看分布式表
SELECT 
    database,
    table,
    cluster,
    sharding_key,
    is_stale
FROM system.tables
WHERE engine = 'Distributed';
```

### 故障排查

```sql
-- 查看错误日志
SELECT 
    event_time,
    message
FROM system.logs
WHERE level = 'Error'
  AND event_time > now() - INTERVAL 1 HOUR
LIMIT 10;

-- 查看 ZooKeeper 异常
SELECT 
    database,
    table,
    zookeeper_exception,
    last_queue_update_exception
FROM system.replicas
WHERE zookeeper_exception != '';
```

## 总结

| 特性 | 说明 |
|------|------|
| ReplicatedMergeTree | 基于 Keeper 的异步复制 |
| Distributed | 数据分片，分布式查询 |
| 分片键 | 决定数据分布方式 |
| 复制延迟 | 通常毫秒级 |
| 一致性 | 最终一致性 |

## 下一步

- 继续学习 [README.md](./README.md) 了解更多信息
- 参考 [11-performance/](../11-performance/) 学习性能优化
