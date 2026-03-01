# ClickHouse 集群培训计划（从入门到专家）

## 📋 培训概述

**培训目标**：从零基础开始，循序渐进地掌握 ClickHouse 集群的部署、使用、优化和运维，最终达到专家级别。

**培训周期**：8-12 周（根据学习进度调整）

**培训方式**：理论讲解 + 实操演练 + 验证测试 + 项目实战

**培训环境**：
- 集群架构：2 个 ClickHouse Server + 3 个 Keeper 节点
- 集群名称：treasurycluster
- 访问方式：HTTP (8123/8124) / Native (9000/9001)
- Play UI：http://localhost:8123/play

---

## 🎯 培训路线图

```
阶段 1：基础入门 (2 周)
    ├─ 环境搭建与配置
    ├─ 基础 SQL 操作
    └─ 表引擎基础
         ↓
阶段 2：进阶应用 (3 周)
    ├─ 复制与分布式表
    ├─ 数据建模
    └─ 数据更新与删除
         ↓
阶段 3：性能优化 (2 周)
    ├─ 查询优化
    ├─ 索引优化
    └─ 系统调优
         ↓
阶段 4：高级特性 (2 周)
    ├─ 物化视图
    ├─ 数据集成
    └─ 高级功能
         ↓
阶段 5：运维管理 (2 周)
    ├─ 监控告警
    ├─ 故障排查
    └─ 备份恢复
         ↓
阶段 6：专家级实战 (1 周)
    ├─ 架构设计
    ├─ 性能调优实战
    └─ 生产环境最佳实践
```

---

## 📚 详细培训内容

## 阶段 1：基础入门（第 1-2 周）

### 第 1 周：环境搭建与基础操作

#### Day 1-2：环境搭建与理解

**学习目标**：
- 理解 ClickHouse 架构和特点
- 掌握集群启动和停止
- 了解集群配置文件

**理论内容**：
- ClickHouse 简介与特点
- OLAP 数据库基础概念
- 集群架构详解（Keeper + Server）
- 配置文件解析

**实操任务**：

```bash
# 任务 1：启动集群
cd 00-infra
docker compose up -d

# 验证点 1：检查所有容器状态
docker compose ps
# 期望输出：5 个容器全部 Running (healthy)

# 任务 2：查看集群配置
docker exec -it clickhouse-server-1 clickhouse-client

# 验证点 2：查询集群信息
SELECT * FROM system.clusters WHERE cluster = 'treasurycluster';
-- 期望输出：显示 2 个副本节点

# 验证点 3：查询 Macros 配置
SELECT * FROM system.macros;
-- 期望输出：cluster, shard, replica, layer, table_prefix

# 任务 3：访问 Play UI
# 浏览器打开 http://localhost:8123/play
# 执行查询：SELECT version()
```

**验证测试**：
```sql
-- 测试 1：连接测试
SELECT 1 AS test;
-- 期望结果：test = 1

-- 测试 2：版本查询
SELECT version();
-- 期望结果：返回版本号（如 25.12.1.649）

-- 测试 3：集群状态
SELECT 
    cluster,
    shard_num,
    replica_num,
    host_name
FROM system.clusters;
-- 期望结果：显示 2 个副本
```

**作业**：
1. 绘制集群架构图（包含所有组件和端口）
2. 解释每个配置文件的作用
3. 记录启动过程中的关键日志

---

#### Day 3-5：基础 SQL 操作

**学习目标**：
- 掌握数据库和表的基本操作
- 理解 MergeTree 引擎基础
- 学会数据插入和查询

**理论内容**：
- SQL 语法基础
- MergeTree 引擎原理
- 主键和排序键设计
- 分区表基础

**实操任务**：

```sql
-- 任务 1：创建数据库
CREATE DATABASE IF NOT EXISTS training;

-- 任务 2：创建第一个表
CREATE TABLE training.users (
    user_id UInt64,
    username String,
    email String,
    created_at DateTime DEFAULT now()
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(created_at)
ORDER BY user_id;

-- 验证点 1：查看表结构
DESCRIBE training.users;

-- 验证点 2：查看表引擎信息
SELECT 
    database,
    table,
    engine,
    partition_key,
    sorting_key
FROM system.tables
WHERE database = 'training' AND table = 'users';

-- 任务 3：插入数据
INSERT INTO training.users (user_id, username, email) VALUES
    (1, 'alice', 'alice@example.com'),
    (2, 'bob', 'bob@example.com'),
    (3, 'charlie', 'charlie@example.com');

-- 验证点 3：查询数据
SELECT * FROM training.users ORDER BY user_id;

-- 任务 4：查询优化示例
-- 好的查询：使用主键
SELECT * FROM training.users WHERE user_id = 1;

-- 不好的查询：全表扫描
SELECT * FROM training.users WHERE email LIKE '%example.com';

-- 验证点 4：查看查询性能
SELECT 
    query,
    read_rows,
    query_duration_ms
FROM system.query_log
WHERE query LIKE '%training.users%'
ORDER BY event_time DESC
LIMIT 5;
```

**验证测试**：
```sql
-- 测试 1：批量插入
INSERT INTO training.users (user_id, username, email, created_at)
SELECT 
    number + 100 AS user_id,
    concat('user', toString(number)) AS username,
    concat('user', toString(number), '@test.com') AS email,
    now() - INTERVAL number DAY AS created_at
FROM numbers(1000);

-- 验证插入行数
SELECT count() FROM training.users;
-- 期望结果：1003 行

-- 测试 2：聚合查询
SELECT 
    toYYYYMM(created_at) AS month,
    count() AS user_count
FROM training.users
GROUP BY month
ORDER BY month;

-- 测试 3：分区查看
SELECT 
    partition,
    name,
    rows
FROM system.parts
WHERE database = 'training' 
  AND table = 'users'
  AND active = 1;
```

**学习资源**：
- 文档：`01-base/01_basic_operations.sql`
- 文档：`03-engines/01_mergetree_engines.sql`

**作业**：
1. 创建一个包含 5 种数据类型的表
2. 插入 10000 条测试数据
3. 比较 ORDER BY 不同列的查询性能差异

---

#### Day 6-7：表引擎基础

**学习目标**：
- 理解 MergeTree 系列引擎
- 掌握不同引擎的适用场景
- 学会选择合适的引擎

**理论内容**：
- MergeTree 家族引擎对比
- ReplacingMergeTree - 数据去重
- SummingMergeTree - 预聚合
- CollapsingMergeTree - 增量更新

**实操任务**：

```sql
-- 任务 1：ReplacingMergeTree 去重
CREATE TABLE training.user_versions (
    user_id UInt64,
    username String,
    version UInt64,
    updated_at DateTime DEFAULT now()
) ENGINE = ReplacingMergeTree(version)
ORDER BY user_id;

-- 插入重复数据
INSERT INTO training.user_versions VALUES (1, 'alice_v1', 1, now());
INSERT INTO training.user_versions VALUES (1, 'alice_v2', 2, now());
INSERT INTO training.user_versions VALUES (1, 'alice_v3', 3, now());

-- 验证点 1：查看去重前
SELECT * FROM training.user_versions ORDER BY user_id;

-- 强制合并
OPTIMIZE TABLE training.user_versions FINAL;

-- 验证点 2：查看去重后
SELECT * FROM training.user_versions ORDER BY user_id;
-- 期望结果：只保留 version=3 的记录

-- 任务 2：SummingMergeTree 聚合
CREATE TABLE training.order_summary (
    order_date Date,
    product_id UInt64,
    quantity UInt64,
    amount Decimal(10, 2)
) ENGINE = SummingMergeTree()
PARTITION BY toYYYYMM(order_date)
ORDER BY (order_date, product_id);

-- 插入数据
INSERT INTO training.order_summary VALUES
    ('2024-01-01', 1, 10, 100.00),
    ('2024-01-01', 1, 5, 50.00),
    ('2024-01-01', 2, 8, 80.00);

-- 验证点 3：查看聚合前
SELECT * FROM training.order_summary;

-- 强制合并
OPTIMIZE TABLE training.order_summary FINAL;

-- 验证点 4：查看聚合后
SELECT * FROM training.order_summary;
-- 期望结果：product_id=1 的记录合并，quantity=15, amount=150.00

-- 任务 3：引擎选择练习
-- 场景：用户行为日志，需要按日期统计 PV/UV

-- 方案 1：MergeTree（原始数据）
CREATE TABLE training.user_events (
    event_id UInt64,
    user_id UInt64,
    event_type String,
    event_time DateTime
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_time, user_id);

-- 方案 2：SummingMergeTree（聚合数据）
CREATE TABLE training.event_summary (
    event_date Date,
    event_type String,
    pv UInt64,
    uv AggregateFunction(uniq, UInt64)
) ENGINE = AggregatingMergeTree()
PARTITION BY toYYYYMM(event_date)
ORDER BY (event_date, event_type);
```

**验证测试**：
```sql
-- 测试 1：ReplacingMergeTree 测试
-- 插入 100 个用户的多次版本
INSERT INTO training.user_versions
SELECT 
    number % 100 AS user_id,
    concat('user_', toString(number % 100), '_v', toString(intDiv(number, 100))) AS username,
    intDiv(number, 100) AS version,
    now() - INTERVAL number SECOND AS updated_at
FROM numbers(500);

-- 查看去重效果
SELECT 
    count() AS total_rows,
    uniqExact(user_id) AS unique_users
FROM training.user_versions;
-- 期望结果：total_rows > unique_users

OPTIMIZE TABLE training.user_versions FINAL;

SELECT count() AS rows_after_dedup FROM training.user_versions;
-- 期望结果：rows_after_dedup ≈ 100

-- 测试 2：引擎对比
-- 创建不同引擎的表并对比性能
-- （详见 03-engines/README.md）
```

**学习资源**：
- 文档：`03-engines/01_mergetree_engines.sql`
- 文档：`03-engines/06_engine_selection_guide.md`

**作业**：
1. 为 3 种不同场景设计表引擎方案
2. 实现 CollapsingMergeTree 的增量更新示例
3. 对比不同引擎的存储和查询性能

---

### 第 2 周：复制表与分布式表

#### Day 8-10：复制表实战

**学习目标**：
- 理解数据复制原理
- 掌握 ReplicatedMergeTree 使用
- 验证数据同步机制

**理论内容**：
- 复制表工作原理
- Keeper (ZooKeeper) 的作用
- Macros 配置详解
- 复制状态监控

**实操任务**：

```sql
-- 任务 1：创建复制表（使用默认路径）
CREATE TABLE training.replicated_events (
    event_id UInt64,
    user_id UInt64,
    event_type String,
    event_time DateTime,
    event_data String
) ENGINE = ReplicatedMergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_time, event_id);

-- 验证点 1：查看复制信息
SELECT 
    database,
    table,
    engine,
    replica_name,
    replica_path,
    zookeeper_path
FROM system.replicas
WHERE table = 'replicated_events';

-- 验证点 2：检查 ZooKeeper 节点
SELECT * FROM system.zookeeper 
WHERE path = '/clickhouse/tables/1/replicated_events';

-- 任务 2：插入数据并验证复制
-- 在节点 1 插入数据
INSERT INTO training.replicated_events VALUES
    (1, 100, 'click', now(), '{"page":"/home"}'),
    (2, 101, 'view', now(), '{"product":"laptop"}');

-- 验证点 3：在节点 1 查询
SELECT * FROM training.replicated_events;

-- 验证点 4：连接节点 2 验证复制
-- 打开新终端
docker exec -it clickhouse-server-2 clickhouse-client

SELECT * FROM training.replicated_events;
-- 期望结果：数据已同步

-- 任务 3：监控复制延迟
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
WHERE table = 'replicated_events';

-- 任务 4：测试复制一致性
-- 在节点 1 插入大量数据
INSERT INTO training.replicated_events
SELECT 
    number + 100 AS event_id,
    number % 1000 AS user_id,
    ['click', 'view', 'purchase'][number % 3 + 1] AS event_type,
    now() - INTERVAL number SECOND AS event_time,
    '{"data": "test"}' AS event_data
FROM numbers(10000);

-- 验证点 5：对比两个节点的数据
-- 节点 1
SELECT count() FROM training.replicated_events;

-- 节点 2
SELECT count() FROM training.replicated_events;
-- 期望结果：两个节点数据一致
```

**验证测试**：

```sql
-- 测试 1：复制表完整性测试
-- 创建测试表
CREATE TABLE training.test_replication (
    id UInt64,
    data String,
    created_at DateTime DEFAULT now()
) ENGINE = ReplicatedMergeTree()
ORDER BY id;

-- 在节点 1 插入数据
INSERT INTO training.test_replication (id, data) VALUES (1, 'test1');
INSERT INTO training.test_replication (id, data) VALUES (2, 'test2');
INSERT INTO training.test_replication (id, data) VALUES (3, 'test3');

-- 验证节点 1
SELECT * FROM training.test_replication ORDER BY id;

-- 验证节点 2（使用不同端口）
-- curl "http://localhost:8124/" --data "SELECT * FROM training.test_replication ORDER BY id"
-- 期望结果：3 行数据

-- 测试 2：复制延迟监控
-- 持续插入数据
INSERT INTO training.test_replication
SELECT number + 100, concat('data_', toString(number)), now()
FROM numbers(10000);

-- 检查复制队列
SELECT 
    table,
    queue_size,
    inserts_in_queue,
    merges_in_queue,
    log_max_index - log_pointer AS log_entries
FROM system.replicas
WHERE table = 'test_replication';
```

**学习资源**：
- 文档：`01-base/02_replicated_tables.sql`
- 文档：`03-engines/02_replicated_engines.sql`
- 文档：`00-infra/README.md`（复制配置说明）

**作业**：
1. 解释复制表的数据同步流程
2. 设计一个复制表的监控方案
3. 模拟节点故障并验证数据恢复

---

#### Day 11-14：分布式表实战

**学习目标**：
- 理解分布式表原理
- 掌握 Distributed 引擎使用
- 学会数据分片策略

**理论内容**：
- 分布式表架构
- 数据分片策略
- 路由规则
- 分布式查询优化

**实操任务**：

```sql
-- 任务 1：创建分布式表
-- 首先创建本地复制表
CREATE TABLE training.events_local ON CLUSTER 'treasurycluster' (
    event_id UInt64,
    user_id UInt64,
    event_type String,
    event_time DateTime,
    event_data String
) ENGINE = ReplicatedMergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_time, user_id);

-- 创建分布式表
CREATE TABLE training.events_all ON CLUSTER 'treasurycluster' (
    event_id UInt64,
    user_id UInt64,
    event_type String,
    event_time DateTime,
    event_data String
) ENGINE = Distributed('treasurycluster', 'training', 'events_local', rand());

-- 验证点 1：查看分布式表配置
SELECT 
    database,
    table,
    engine,
    engine_full
FROM system.tables
WHERE table = 'events_all';

-- 任务 2：插入数据到分布式表
INSERT INTO training.events_all VALUES
    (1, 100, 'click', now(), '{"page":"/home"}'),
    (2, 200, 'view', now(), '{"product":"laptop"}'),
    (3, 300, 'purchase', now(), '{"order_id":"123"}');

-- 验证点 2：查询分布式表
SELECT * FROM training.events_all ORDER BY event_id;

-- 验证点 3：查询本地表（每个节点）
SELECT 'Node 1' AS node, count() AS count FROM training.events_local
UNION ALL
SELECT 'Node 2' AS node, count() AS count FROM training.events_local;

-- 任务 3：理解数据分布
-- 插入大量数据
INSERT INTO training.events_all
SELECT 
    number AS event_id,
    number % 1000 AS user_id,
    ['click', 'view', 'purchase'][number % 3 + 1] AS event_type,
    now() - INTERVAL number SECOND AS event_time,
    '{"data": "test"}' AS event_data
FROM numbers(10000);

-- 验证点 4：查看数据分布
-- 在两个节点上分别查询
SELECT 'clickhouse1' AS node, count() AS rows FROM training.events_local;

-- 在节点 2 上
-- SELECT 'clickhouse2' AS node, count() AS rows FROM training.events_local;

-- 任务 4：分布式聚合查询
SELECT 
    event_type,
    count() AS event_count,
    uniqExact(user_id) AS unique_users
FROM training.events_all
GROUP BY event_type
ORDER BY event_count DESC;

-- 任务 5：优化分布式查询
-- 使用 PREWHERE
SELECT 
    user_id,
    count() AS event_count
FROM training.events_all
PREWHERE event_time >= now() - INTERVAL 7 DAY
WHERE event_type = 'click'
GROUP BY user_id
ORDER BY event_count DESC
LIMIT 10;
```

**验证测试**：

```sql
-- 测试 1：分布式表性能测试
-- 创建测试表
CREATE TABLE training.perf_test_local ON CLUSTER 'treasurycluster' (
    id UInt64,
    category String,
    value Float64,
    created_at DateTime DEFAULT now()
) ENGINE = ReplicatedMergeTree()
PARTITION BY toYYYYMM(created_at)
ORDER BY (category, id);

CREATE TABLE training.perf_test_all ON CLUSTER 'treasurycluster' AS training.perf_test_local
ENGINE = Distributed('treasurycluster', 'training', 'perf_test_local', rand());

-- 插入 100 万条数据
INSERT INTO training.perf_test_all
SELECT 
    number AS id,
    concat('category_', toString(number % 100)) AS category,
    rand() % 1000 AS value,
    now() - INTERVAL (number % 365) DAY AS created_at
FROM numbers(1000000);

-- 测试查询性能
SELECT 
    category,
    avg(value) AS avg_value,
    count() AS count
FROM training.perf_test_all
GROUP BY category
ORDER BY avg_value DESC
LIMIT 10;

-- 测试 2：分布式 JOIN
CREATE TABLE training.users_local ON CLUSTER 'treasurycluster' (
    user_id UInt64,
    username String,
    region String
) ENGINE = ReplicatedMergeTree()
ORDER BY user_id;

CREATE TABLE training.users_all ON CLUSTER 'treasurycluster' AS training.users_local
ENGINE = Distributed('treasurycluster', 'training', 'users_local', user_id);

INSERT INTO training.users_all VALUES
    (100, 'alice', 'US'),
    (200, 'bob', 'EU'),
    (300, 'charlie', 'APAC');

-- 分布式 JOIN 查询
SELECT 
    e.user_id,
    u.username,
    u.region,
    e.event_type,
    e.event_time
FROM training.events_all AS e
JOIN training.users_all AS u ON e.user_id = u.user_id
ORDER BY e.event_time DESC
LIMIT 20;
```

**学习资源**：
- 文档：`01-base/03_distributed_tables.sql`
- 文档：`03-engines/05_special_engines.sql`（Distributed 引擎）

**作业**：
1. 解释分布式表与复制表的区别
2. 设计一个多分片集群方案
3. 测试分布式查询的性能优化策略

---

## 阶段 2：进阶应用（第 3-5 周）

### 第 3 周：数据建模

#### Day 15-17：数据建模基础

**学习目标**：
- 理解 ClickHouse 数据建模特点
- 掌握宽表、星型模型设计
- 学会主键和分区键设计

**理论内容**：
- ClickHouse 建模与传统数据库的差异
- 宽表模型（推荐）
- 星型模型和雪花模型
- 主键和排序键设计原则

**实操任务**：

```sql
-- 任务 1：宽表模型（推荐方式）
CREATE TABLE training.events_wide (
    event_id UInt64,
    event_time DateTime,
    user_id UInt64,
    -- 用户维度字段（预 JOIN）
    user_name String,
    user_email String,
    user_region String,
    user_vip_level UInt8,
    -- 产品维度字段
    product_id UInt64,
    product_name String,
    product_category String,
    product_price Decimal(10, 2),
    -- 事件指标
    event_type String,
    quantity UInt32,
    amount Decimal(10, 2)
) ENGINE = ReplicatedMergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_time, user_id, event_id);

-- 插入示例数据
INSERT INTO training.events_wide VALUES
    (1, now(), 1001, 'alice', 'alice@example.com', 'US', 2, 101, 'Laptop', 'Electronics', 999.99, 'purchase', 1, 999.99),
    (2, now(), 1002, 'bob', 'bob@example.com', 'EU', 1, 102, 'Phone', 'Electronics', 599.99, 'purchase', 2, 1199.98),
    (3, now(), 1001, 'alice', 'alice@example.com', 'US', 2, 103, 'Book', 'Books', 29.99, 'view', 1, 0);

-- 查询示例：按用户维度分析
SELECT 
    user_region,
    user_vip_level,
    count() AS event_count,
    sum(amount) AS total_amount,
    uniqExact(product_id) AS product_count
FROM training.events_wide
GROUP BY user_region, user_vip_level
ORDER BY total_amount DESC;

-- 任务 2：星型模型
-- 事实表
CREATE TABLE training.fact_events (
    event_id UInt64,
    event_time DateTime,
    user_key UInt64,      -- 用户维度外键
    product_key UInt64,   -- 产品维度外键
    event_type String,
    quantity UInt32,
    amount Decimal(10, 2)
) ENGINE = ReplicatedMergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_time, user_key);

-- 用户维度表
CREATE TABLE training.dim_user (
    user_key UInt64,
    user_id UInt64,
    user_name String,
    user_email String,
    user_region String,
    user_vip_level UInt8,
    valid_from Date,
    valid_to Date
) ENGINE = ReplacingMergeTree(valid_to)
ORDER BY (user_key, valid_from);

-- 产品维度表
CREATE TABLE training.dim_product (
    product_key UInt64,
    product_id UInt64,
    product_name String,
    product_category String,
    product_price Decimal(10, 2),
    valid_from Date,
    valid_to Date
) ENGINE = ReplacingMergeTree(valid_to)
ORDER BY (product_key, valid_from);

-- 查询示例：JOIN 维度表
SELECT 
    u.user_region,
    p.product_category,
    count() AS event_count,
    sum(f.amount) AS total_amount
FROM training.fact_events f
JOIN training.dim_user u ON f.user_key = u.user_key
JOIN training.dim_product p ON f.product_key = p.product_key
GROUP BY u.user_region, p.product_category
ORDER BY total_amount DESC;

-- 任务 3：主键设计优化
-- 场景 1：按时间范围查询
CREATE TABLE training.time_series (
    timestamp DateTime,
    metric_name String,
    metric_value Float64,
    tags Map(String, String)
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(timestamp)
ORDER BY (timestamp, metric_name);
-- 适合：WHERE timestamp BETWEEN ... AND metric_name = ...

-- 场景 2：按用户 ID 查询
CREATE TABLE training.user_events_optimized (
    user_id UInt64,
    event_time DateTime,
    event_type String,
    event_data String
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (user_id, event_time);
-- 适合：WHERE user_id = ... AND event_time BETWEEN ...

-- 场景 3：多维度查询
CREATE TABLE training.multi_dimension (
    region String,
    category String,
    event_time DateTime,
    metric_value Float64
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (region, category, event_time);
-- 适合：WHERE region = ... AND category = ... AND event_time BETWEEN ...
```

**验证测试**：

```sql
-- 测试 1：宽表查询性能
-- 插入 10 万条测试数据
INSERT INTO training.events_wide
SELECT 
    number AS event_id,
    now() - INTERVAL (number % 365) DAY AS event_time,
    number % 1000 + 1 AS user_id,
    concat('user_', toString(number % 1000)) AS user_name,
    concat('user_', toString(number % 1000), '@test.com') AS user_email,
    ['US', 'EU', 'APAC'][number % 3 + 1] AS user_region,
    number % 4 AS user_vip_level,
    number % 100 + 1 AS product_id,
    concat('product_', toString(number % 100)) AS product_name,
    ['Electronics', 'Books', 'Clothing'][number % 3 + 1] AS product_category,
    (number % 1000) * 10 AS product_price,
    ['click', 'view', 'purchase'][number % 3 + 1] AS event_type,
    number % 10 + 1 AS quantity,
    (number % 1000) * 10 * (number % 10 + 1) AS amount
FROM numbers(100000);

-- 执行聚合查询
SELECT 
    user_region,
    user_vip_level,
    count() AS event_count,
    sum(amount) AS total_amount
FROM training.events_wide
WHERE event_time >= now() - INTERVAL 30 DAY
GROUP BY user_region, user_vip_level
ORDER BY total_amount DESC;

-- 测试 2：对比 JOIN 性能
-- 插入维度表数据
INSERT INTO training.dim_user
SELECT 
    number AS user_key,
    number AS user_id,
    concat('user_', toString(number)) AS user_name,
    concat('user_', toString(number), '@test.com') AS user_email,
    ['US', 'EU', 'APAC'][number % 3 + 1] AS user_region,
    number % 4 AS user_vip_level,
    '2024-01-01' AS valid_from,
    '2099-12-31' AS valid_to
FROM numbers(1000);

INSERT INTO training.fact_events
SELECT 
    number AS event_id,
    now() - INTERVAL (number % 365) DAY AS event_time,
    number % 1000 AS user_key,
    number % 100 AS product_key,
    ['click', 'view', 'purchase'][number % 3 + 1] AS event_type,
    number % 10 + 1 AS quantity,
    (number % 1000) * 10 * (number % 10 + 1) AS amount
FROM numbers(100000);

-- 执行 JOIN 查询
SELECT 
    u.user_region,
    count() AS event_count,
    sum(f.amount) AS total_amount
FROM training.fact_events f
JOIN training.dim_user u ON f.user_key = u.user_key
GROUP BY u.user_region
ORDER BY total_amount DESC;
```

**学习资源**：
- 文档：`01-base/07_data_modeling.sql`
- 文档：`11-performance/02_primary_indexes.md`

**作业**：
1. 设计一个电商订单系统的宽表模型
2. 对比宽表和星型模型的查询性能
3. 设计适合时间范围查询的主键

---

#### Day 18-21：数据更新与删除

**学习目标**：
- 理解 ClickHouse 数据更新机制
- 掌握多种更新策略
- 学会选择合适的方案

**理论内容**：
- ClickHouse 数据更新特点
- Mutation 操作原理
- Lightweight DELETE
- 分区级操作

**实操任务**：

```sql
-- 任务 1：Mutation UPDATE
-- 创建测试表
CREATE TABLE training.user_profiles (
    user_id UInt64,
    username String,
    email String,
    status String DEFAULT 'active',
    created_at DateTime DEFAULT now()
) ENGINE = ReplicatedMergeTree()
ORDER BY user_id;

-- 插入测试数据
INSERT INTO training.user_profiles (user_id, username, email) VALUES
    (1, 'alice', 'alice@example.com'),
    (2, 'bob', 'bob@example.com'),
    (3, 'charlie', 'charlie@example.com');

-- 验证点 1：查看初始数据
SELECT * FROM training.user_profiles ORDER BY user_id;

-- 执行 UPDATE Mutation
ALTER TABLE training.user_profiles 
UPDATE status = 'inactive' 
WHERE user_id = 2;

-- 验证点 2：查看 Mutation 状态
SELECT 
    mutation_id,
    command,
    is_done,
    parts_to_do,
    latest_fail_time
FROM system.mutations
WHERE table = 'user_profiles'
ORDER BY mutation_id DESC
LIMIT 1;

-- 验证点 3：查看更新结果
SELECT * FROM training.user_profiles ORDER BY user_id;

-- 任务 2：Lightweight DELETE
-- 插入更多数据
INSERT INTO training.user_profiles (user_id, username, email) VALUES
    (4, 'david', 'david@example.com'),
    (5, 'eve', 'eve@example.com');

-- 执行轻量级删除
ALTER TABLE training.user_profiles 
DELETE WHERE user_id = 3;

-- 验证点 4：查看删除结果
SELECT * FROM training.user_profiles ORDER BY user_id;

-- 查看删除标记
SELECT 
    database,
    table,
    partition,
    name,
    rows,
    level
FROM system.parts
WHERE database = 'training' 
  AND table = 'user_profiles'
  AND active = 1;

-- 任务 3：分区级删除（推荐）
-- 创建分区表
CREATE TABLE training.logs_by_month (
    log_id UInt64,
    log_time DateTime,
    log_level String,
    message String
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(log_time)
ORDER BY (log_time, log_id);

-- 插入数据
INSERT INTO training.logs_by_month
SELECT 
    number AS log_id,
    toDateTime('2024-01-01') + INTERVAL number SECOND AS log_time,
    ['INFO', 'WARN', 'ERROR'][number % 3 + 1] AS log_level,
    concat('Log message ', toString(number)) AS message
FROM numbers(100000);

-- 验证点 5：查看分区
SELECT 
    partition,
    count() AS rows,
    formatReadableSize(sum(bytes)) AS size
FROM system.parts
WHERE database = 'training' 
  AND table = 'logs_by_month'
  AND active = 1
GROUP BY partition
ORDER BY partition;

-- 删除指定分区（最快）
ALTER TABLE training.logs_by_month DROP PARTITION '202401';

-- 验证点 6：查看删除后分区
SELECT * FROM training.logs_by_month LIMIT 10;

-- 任务 4：ReplacingMergeTree 去重更新
CREATE TABLE training.user_updates (
    user_id UInt64,
    username String,
    email String,
    version UInt64,
    updated_at DateTime DEFAULT now()
) ENGINE = ReplacingMergeTree(version)
ORDER BY user_id;

-- 插入初始数据
INSERT INTO training.user_updates VALUES
    (1, 'alice', 'alice@old.com', 1, now() - INTERVAL 1 DAY);

-- 更新邮箱（插入新版本）
INSERT INTO training.user_updates VALUES
    (1, 'alice', 'alice@new.com', 2, now());

-- 验证点 7：查看去重前
SELECT * FROM training.user_updates ORDER BY user_id;

-- 强制合并
OPTIMIZE TABLE training.user_updates FINAL;

-- 验证点 8：查看去重后
SELECT * FROM training.user_updates ORDER BY user_id;
-- 期望结果：只保留 version=2 的记录

-- 任务 5：TTL 自动删除
CREATE TABLE training.events_with_ttl (
    event_id UInt64,
    event_time DateTime,
    event_data String
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY event_time
TTL event_time + INTERVAL 30 DAY;

-- 插入数据（包括过期数据）
INSERT INTO training.events_with_ttl VALUES
    (1, now() - INTERVAL 40 DAY, 'old data'),
    (2, now() - INTERVAL 10 DAY, 'recent data'),
    (3, now(), 'new data');

-- 强制 TTL 清理
ALTER TABLE training.events_with_ttl MATERIALIZE TTL;

-- 验证点 9：查看过期数据是否被删除
SELECT * FROM training.events_with_ttl ORDER BY event_id;
```

**验证测试**：

```sql
-- 测试 1：Mutation 性能测试
-- 创建大表
CREATE TABLE training.large_table (
    id UInt64,
    category String,
    value Float64,
    status String DEFAULT 'pending'
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(now())
ORDER BY id;

-- 插入 100 万条数据
INSERT INTO training.large_table (id, category, value)
SELECT 
    number AS id,
    concat('cat_', toString(number % 100)) AS category,
    rand() % 1000 AS value
FROM numbers(1000000);

-- 执行 Mutation 更新
ALTER TABLE training.large_table 
UPDATE status = 'completed' 
WHERE category = 'cat_1';

-- 监控 Mutation 进度
SELECT 
    mutation_id,
    command,
    is_done,
    parts_to_do,
    latest_fail_time
FROM system.mutations
WHERE table = 'large_table'
ORDER BY mutation_id DESC;

-- 测试 2：删除策略对比
-- 场景：删除 10 万条数据

-- 方法 1：DELETE Mutation
ALTER TABLE training.large_table DELETE WHERE id BETWEEN 100000 AND 199999;

-- 方法 2：分区删除（如果数据在特定分区）
-- ALTER TABLE training.large_table DROP PARTITION 'partition_name';

-- 对比两种方法的性能和资源消耗
SELECT 
    table,
    count() AS mutation_count,
    sumIf(1, is_done = 0) AS running_mutations
FROM system.mutations
WHERE database = 'training'
GROUP BY table;
```

**学习资源**：
- 文档：`01-base/06_data_updates.sql`
- 文档：`09-data-deletion/README.md`
- 文档：`11-data-update/README.md`

**作业**：
1. 对比不同更新策略的适用场景
2. 设计一个订单状态更新的最佳方案
3. 实现一个自动清理过期数据的 TTL 方案

---

### 第 4 周：高级数据操作

#### Day 22-24：数据去重与幂等性

**学习目标**：
- 掌握数据去重技术
- 实现幂等性写入
- 处理数据更新场景

**实操任务**：

```sql
-- 任务 1：ReplacingMergeTree 实现用户资料更新
CREATE TABLE training.user_profiles_dedup (
    user_id UInt64,
    username String,
    email String,
    phone String,
    address String,
    version UInt64,
    updated_at DateTime DEFAULT now()
) ENGINE = ReplacingMergeTree(version)
ORDER BY user_id;

-- 模拟多次更新
INSERT INTO training.user_profiles_dedup VALUES
    (1001, 'alice', 'alice@v1.com', '111-1111', 'Address 1', 1, now() - INTERVAL 3 DAY);
    
INSERT INTO training.user_profiles_dedup VALUES
    (1001, 'alice', 'alice@v2.com', '222-2222', 'Address 2', 2, now() - INTERVAL 2 DAY);
    
INSERT INTO training.user_profiles_dedup VALUES
    (1001, 'alice', 'alice@v3.com', '333-3333', 'Address 3', 3, now());

-- 验证点 1：查看所有版本
SELECT * FROM training.user_profiles_dedup ORDER BY user_id;

-- 查询时强制 FINAL（不推荐生产使用）
SELECT * FROM training.user_profiles_dedup FINAL ORDER BY user_id;

-- 推荐：手动 OPTIMIZE
OPTIMIZE TABLE training.user_profiles_dedup FINAL;

-- 验证点 2：查看去重后
SELECT * FROM training.user_profiles_dedup ORDER BY user_id;

-- 任务 2：CollapsingMergeTree 实现订单状态更新
CREATE TABLE training.order_states (
    order_id UInt64,
    user_id UInt64,
    product_id UInt64,
    quantity UInt32,
    status String,
    sign Int8,  -- 1: 新增/修改, -1: 取消
    version UInt64,
    updated_at DateTime DEFAULT now()
) ENGINE = CollapsingMergeTree(sign)
ORDER BY (order_id, version);

-- 订单创建
INSERT INTO training.order_states VALUES
    (5001, 1001, 201, 2, 'created', 1, 1, now());

-- 订单支付
INSERT INTO training.order_states VALUES
    (5001, 1001, 201, 2, 'created', -1, 1, now()),  -- 取消旧状态
    (5001, 1001, 201, 2, 'paid', 1, 2, now());      -- 新增新状态

-- 订单发货
INSERT INTO training.order_states VALUES
    (5001, 1001, 201, 2, 'paid', -1, 2, now()),
    (5001, 1001, 201, 2, 'shipped', 1, 3, now());

-- 验证点 3：查看折叠前
SELECT * FROM training.order_states ORDER BY order_id, version;

-- 强制合并
OPTIMIZE TABLE training.order_states FINAL;

-- 验证点 4：查看折叠后（只保留最新状态）
SELECT * FROM training.order_states ORDER BY order_id;

-- 任务 3：VersionedCollapsingMergeTree 严格版本控制
CREATE TABLE training.financial_transactions (
    transaction_id UInt64,
    account_id UInt64,
    amount Decimal(18, 2),
    transaction_type String,
    sign Int8,
    version UInt64,
    created_at DateTime DEFAULT now()
) ENGINE = VersionedCollapsingMergeTree(sign, version)
ORDER BY transaction_id;

-- 插入交易记录
INSERT INTO training.financial_transactions VALUES
    (10001, 1001, 100.00, 'deposit', 1, 1, now()),
    (10002, 1001, -50.00, 'withdraw', 1, 1, now()),
    (10003, 1001, 200.00, 'deposit', 1, 2, now());

-- 取消一笔交易
INSERT INTO training.financial_transactions VALUES
    (10002, 1001, -50.00, 'withdraw', -1, 1, now());

-- 验证点 5：查看合并前
SELECT * FROM training.financial_transactions ORDER BY transaction_id;

-- 强制合并
OPTIMIZE TABLE training.financial_transactions FINAL;

-- 验证点 6：查看合并后
SELECT * FROM training.financial_transactions ORDER BY transaction_id;

-- 计算账户余额
SELECT 
    account_id,
    sum(amount * sign) AS balance
FROM training.financial_transactions
GROUP BY account_id;
```

**验证测试**：

```sql
-- 测试 1：幂等性写入测试
CREATE TABLE training.idempotent_writes (
    id UInt64,
    data String,
    hash String,  -- 数据哈希
    created_at DateTime DEFAULT now()
) ENGINE = ReplacingMergeTree(created_at)
ORDER BY (id, hash);

-- 模拟重复写入
INSERT INTO training.idempotent_writes VALUES
    (1, 'data_1', 'hash_abc', now());
    
INSERT INTO training.idempotent_writes VALUES
    (1, 'data_1', 'hash_abc', now());  -- 相同数据
    
INSERT INTO training.idempotent_writes VALUES
    (1, 'data_2', 'hash_xyz', now());  -- 不同数据

-- 查看结果
SELECT * FROM training.idempotent_writes ORDER BY id;

OPTIMIZE TABLE training.idempotent_writes FINAL;

SELECT * FROM training.idempotent_writes ORDER BY id;

-- 测试 2：电商订单完整示例
-- 创建订单表
CREATE TABLE training.ecommerce_orders (
    order_id UInt64,
    user_id UInt64,
    product_id UInt64,
    quantity UInt32,
    price Decimal(10, 2),
    total_amount Decimal(10, 2),
    status String,
    sign Int8,
    version UInt64,
    created_at DateTime DEFAULT now()
) ENGINE = CollapsingMergeTree(sign)
ORDER BY (order_id, version);

-- 订单流程
-- 1. 创建订单
INSERT INTO training.ecommerce_orders VALUES
    (100001, 1001, 501, 2, 99.99, 199.98, 'pending', 1, 1, now());

-- 2. 支付成功
INSERT INTO training.ecommerce_orders VALUES
    (100001, 1001, 501, 2, 99.99, 199.98, 'pending', -1, 1, now()),
    (100001, 1001, 501, 2, 99.99, 199.98, 'paid', 1, 2, now());

-- 3. 发货
INSERT INTO training.ecommerce_orders VALUES
    (100001, 1001, 501, 2, 99.99, 199.98, 'paid', -1, 2, now()),
    (100001, 1001, 501, 2, 99.99, 199.98, 'shipped', 1, 3, now());

-- 4. 完成
INSERT INTO training.ecommerce_orders VALUES
    (100001, 1001, 501, 2, 99.99, 199.98, 'shipped', -1, 3, now()),
    (100001, 1001, 501, 2, 99.99, 199.98, 'completed', 1, 4, now());

-- 查看订单历史
SELECT * FROM training.ecommerce_orders ORDER BY order_id, version;

-- 强制合并查看当前状态
OPTIMIZE TABLE training.ecommerce_orders FINAL;

SELECT * FROM training.ecommerce_orders ORDER BY order_id;
```

**学习资源**：
- 文档：`01-base/09_data_deduplication.sql`
- 文档：`01-base/06_data_updates.sql`

**作业**：
1. 实现一个支持审计日志的数据更新方案
2. 设计一个幂等性的数据导入流程
3. 对比三种去重引擎的性能和适用场景

---

#### Day 25-28：实时数据处理

**学习目标**：
- 掌握实时数据写入技巧
- 学会批量插入优化
- 理解异步插入机制

**实操任务**：

```sql
-- 任务 1：批量插入优化
CREATE TABLE training.batch_insert_test (
    id UInt64,
    category String,
    value Float64,
    created_at DateTime DEFAULT now()
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(created_at)
ORDER BY id;

-- 方法 1：单条插入（慢，不推荐）
-- INSERT INTO training.batch_insert_test VALUES (1, 'cat1', 1.0, now());

-- 方法 2：批量 VALUES 插入（推荐）
INSERT INTO training.batch_insert_test VALUES
    (1, 'cat1', 1.0, now()),
    (2, 'cat2', 2.0, now()),
    (3, 'cat3', 3.0, now()),
    (4, 'cat4', 4.0, now()),
    (5, 'cat5', 5.0, now());

-- 方法 3：INSERT SELECT（最快）
INSERT INTO training.batch_insert_test
SELECT 
    number AS id,
    concat('cat_', toString(number % 100)) AS category,
    rand() % 1000 AS value,
    now() AS created_at
FROM numbers(10000);

-- 验证点 1：查看插入性能统计
SELECT 
    query,
    read_rows,
    written_rows,
    query_duration_ms,
    memory_usage
FROM system.query_log
WHERE query LIKE '%INSERT INTO training.batch_insert_test%'
  AND type = 'QueryFinish'
ORDER BY event_time DESC
LIMIT 5;

-- 任务 2：异步插入
-- 启用异步插入
SET async_insert = 1;
SET wait_for_async_insert = 0;  -- 不等待完成
SET async_insert_max_data_size = 100000;  -- 100KB 缓冲
SET async_insert_busy_timeout_ms = 10000;  -- 10 秒超时

-- 插入数据
INSERT INTO training.batch_insert_test VALUES (10001, 'async1', 10.0, now());

-- 验证点 2：查看异步插入状态
SELECT 
    name,
    value,
    description
FROM system.settings
WHERE name LIKE '%async_insert%';

-- 任务 3：Buffer 表优化高频写入
-- 创建 Buffer 表
CREATE TABLE training.events_buffer AS training.batch_insert_test
ENGINE = Buffer(currentDatabase(), batch_insert_test, 
    16,  -- 分片数
    10,  -- 最小刷新间隔（秒）
    100, -- 最大刷新间隔（秒）
    10000,  -- 最小行数
    1000000,  -- 最大行数
    10000000,  -- 最小字节
    100000000  -- 最大字节
);

-- 插入到 Buffer 表
INSERT INTO training.events_buffer VALUES
    (20001, 'buffer1', 20.0, now()),
    (20002, 'buffer2', 21.0, now()),
    (20003, 'buffer3', 22.0, now());

-- 验证点 3：查看 Buffer 表状态
SELECT 
    database,
    table,
    rows,
    bytes
FROM system.tables
WHERE table LIKE '%buffer%';

-- 等待缓冲刷新或手动刷新
OPTIMIZE TABLE training.events_buffer;

-- 任务 4：物化视图实时聚合
-- 创建原始事件表
CREATE TABLE training.raw_events (
    event_time DateTime,
    event_type String,
    user_id UInt64,
    value Float64
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY event_time;

-- 创建聚合结果表
CREATE TABLE training.event_aggregates (
    event_date Date,
    event_type String,
    event_count UInt64,
    total_value Float64,
    avg_value Float64
) ENGINE = SummingMergeTree()
ORDER BY (event_date, event_type);

-- 创建物化视图
CREATE MATERIALIZED VIEW training.event_aggregates_mv
TO training.event_aggregates AS
SELECT 
    toDate(event_time) AS event_date,
    event_type,
    count() AS event_count,
    sum(value) AS total_value,
    avg(value) AS avg_value
FROM training.raw_events
GROUP BY event_date, event_type;

-- 插入原始数据
INSERT INTO training.raw_events VALUES
    (now(), 'click', 1001, 1.0),
    (now(), 'click', 1002, 1.0),
    (now(), 'view', 1001, 0.0),
    (now(), 'purchase', 1003, 100.0);

-- 验证点 4：查看实时聚合结果
SELECT * FROM training.event_aggregates ORDER BY event_date, event_type;

-- 继续插入数据
INSERT INTO training.raw_events VALUES
    (now(), 'click', 1004, 1.0),
    (now(), 'purchase', 1005, 200.0);

-- 再次查看聚合结果
SELECT * FROM training.event_aggregates ORDER BY event_date, event_type;
```

**验证测试**：

```sql
-- 测试 1：插入性能对比
-- 创建测试表
CREATE TABLE training.perf_test_insert (
    id UInt64,
    data String,
    created_at DateTime DEFAULT now()
) ENGINE = MergeTree()
ORDER BY id;

-- 测试单条插入（10 次）
-- 记录开始时间
INSERT INTO training.perf_test_insert VALUES (1, 'data_1', now());
INSERT INTO training.perf_test_insert VALUES (2, 'data_2', now());
-- ... 重复 10 次

-- 测试批量插入（1000 条）
INSERT INTO training.perf_test_insert
SELECT number, concat('data_', toString(number)), now()
FROM numbers(1000);

-- 对比性能
SELECT 
    'Single inserts' AS method,
    count() AS inserts,
    sum(query_duration_ms) AS total_time_ms
FROM system.query_log
WHERE query LIKE '%INSERT INTO training.perf_test_insert VALUES%'
  AND type = 'QueryFinish'
UNION ALL
SELECT 
    'Batch insert' AS method,
    1 AS inserts,
    query_duration_ms AS total_time_ms
FROM system.query_log
WHERE query LIKE '%INSERT INTO training.perf_test_insert SELECT%'
  AND type = 'QueryFinish'
ORDER BY method;

-- 测试 2：物化视图实时性测试
-- 清空表
TRUNCATE TABLE training.raw_events;
TRUNCATE TABLE training.event_aggregates;

-- 插入数据并立即查询
INSERT INTO training.raw_events
SELECT 
    now() - INTERVAL number SECOND AS event_time,
    ['click', 'view', 'purchase'][number % 3 + 1] AS event_type,
    number % 100 AS user_id,
    rand() % 100 AS value
FROM numbers(1000);

-- 立即查询聚合结果
SELECT 
    event_date,
    event_type,
    event_count,
    total_value
FROM training.event_aggregates
ORDER BY event_date, event_type;
```

**学习资源**：
- 文档：`01-base/08_realtime_writes.sql`
- 文档：`11-performance/06_bulk_inserts.md`

**作业**：
1. 实现一个高频数据写入的优化方案
2. 设计一个实时监控系统的数据流架构
3. 对比同步和异步插入的性能差异

---

## 阶段 3：性能优化（第 6-7 周）

### 第 5 周：查询优化

#### Day 29-31：查询优化基础

**学习目标**：
- 掌握查询优化技巧
- 理解 PREWHERE 优化
- 学会分析查询性能

**理论内容**：
- ClickHouse 查询执行流程
- PREWHERE vs WHERE
- 分区裁剪原理
- 主键索引使用

**实操任务**：

```sql
-- 任务 1：创建测试数据集
CREATE TABLE training.large_events (
    event_id UInt64,
    event_time DateTime,
    user_id UInt64,
    event_type String,
    event_data String,
    amount Float64
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_time, user_id, event_id);

-- 插入 100 万条测试数据
INSERT INTO training.large_events
SELECT 
    number AS event_id,
    now() - INTERVAL (number % 365) DAY AS event_time,
    number % 10000 AS user_id,
    ['click', 'view', 'purchase', 'refund'][number % 4 + 1] AS event_type,
    concat('data_', toString(number)) AS event_data,
    rand() % 1000 AS amount
FROM numbers(1000000);

-- 任务 2：WHERE vs PREWHERE
-- 方法 1：使用 WHERE
SELECT count()
FROM training.large_events
WHERE event_type = 'purchase'
  AND event_time >= now() - INTERVAL 30 DAY;

-- 方法 2：使用 PREWHERE（更快）
SELECT count()
FROM training.large_events
PREWHERE event_type = 'purchase'
WHERE event_time >= now() - INTERVAL 30 DAY;

-- 验证点 1：对比查询性能
SELECT 
    query_duration_ms,
    read_rows,
    read_bytes,
    memory_usage
FROM system.query_log
WHERE query LIKE '%FROM training.large_events%'
  AND type = 'QueryFinish'
ORDER BY event_time DESC
LIMIT 2;

-- 任务 3：分区裁剪
-- 查询特定分区（快速）
SELECT count()
FROM training.large_events
WHERE event_time >= '2024-01-01' AND event_time < '2024-02-01';

-- 验证点 2：查看扫描的分区
EXPLAIN PLAN 
SELECT count()
FROM training.large_events
WHERE event_time >= '2024-01-01' AND event_time < '2024-02-01';

-- 任务 4：主键索引优化
-- 好的查询：使用主键前缀
SELECT * FROM training.large_events
WHERE event_time >= now() - INTERVAL 7 DAY
  AND user_id = 123
LIMIT 10;

-- 不好的查询：跳过主键前缀
SELECT * FROM training.large_events
WHERE user_id = 123
LIMIT 10;

-- 验证点 3：对比性能
SELECT 
    substring(query, 1, 100) AS query_preview,
    query_duration_ms,
    read_rows
FROM system.query_log
WHERE query LIKE '%user_id = 123%'
  AND type = 'QueryFinish'
ORDER BY event_time DESC
LIMIT 2;

-- 任务 5：避免函数计算
-- 慢：在 WHERE 中使用函数
SELECT count()
FROM training.large_events
WHERE toYYYYMM(event_time) = 202401;

-- 快：使用范围查询
SELECT count()
FROM training.large_events
WHERE event_time >= '2024-01-01' AND event_time < '2024-02-01';

-- 验证点 4：对比性能
SELECT 
    query_duration_ms,
    read_rows
FROM system.query_log
WHERE query LIKE '%event_time%'
  AND type = 'QueryFinish'
ORDER BY event_time DESC
LIMIT 2;
```

**验证测试**：

```sql
-- 测试 1：查询性能基准测试
-- 创建测试表
CREATE TABLE training.query_perf_test (
    id UInt64,
    category String,
    subcategory String,
    value Float64,
    created_at DateTime
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(created_at)
ORDER BY (created_at, category, id);

-- 插入测试数据
INSERT INTO training.query_perf_test
SELECT 
    number AS id,
    concat('cat_', toString(number % 100)) AS category,
    concat('sub_', toString(number % 500)) AS subcategory,
    rand() % 1000 AS value,
    now() - INTERVAL (number % 365) DAY AS created_at
FROM numbers(1000000);

-- 测试不同查询方式的性能
-- 1. 全表扫描
SELECT avg(value) FROM training.query_perf_test;

-- 2. 使用分区
SELECT avg(value) 
FROM training.query_perf_test
WHERE created_at >= now() - INTERVAL 30 DAY;

-- 3. 使用主键
SELECT avg(value)
FROM training.query_perf_test
WHERE created_at >= now() - INTERVAL 30 DAY
  AND category = 'cat_1';

-- 4. 使用 PREWHERE
SELECT avg(value)
FROM training.query_perf_test
PREWHERE created_at >= now() - INTERVAL 30 DAY
WHERE category = 'cat_1';

-- 对比所有查询的性能
SELECT 
    substring(query, 1, 200) AS query_preview,
    query_duration_ms AS duration_ms,
    read_rows,
    formatReadableSize(read_bytes) AS read_size
FROM system.query_log
WHERE query LIKE '%query_perf_test%'
  AND type = 'QueryFinish'
  AND query NOT LIKE '%system.query_log%'
ORDER BY event_time DESC
LIMIT 4;
```

**学习资源**：
- 文档：`11-performance/01_query_optimization.md`
- 文档：`11-performance/05_prewhere_optimization.md`

**作业**：
1. 优化 5 个慢查询并记录性能提升
2. 设计一个查询性能测试方案
3. 分析查询执行计划并优化

---

#### Day 32-35：索引优化

**学习目标**：
- 掌握主键索引设计
- 学会跳数索引使用
- 理解索引选择策略

**实操任务**：

```sql
-- 任务 1：主键索引设计
-- 场景 1：时间序列查询
CREATE TABLE training.time_series_data (
    timestamp DateTime,
    metric_name String,
    metric_value Float64,
    tags Map(String, String)
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(timestamp)
ORDER BY (timestamp, metric_name);

-- 场景 2：用户行为查询
CREATE TABLE training.user_behavior (
    user_id UInt64,
    event_time DateTime,
    event_type String,
    event_data String
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (user_id, event_time);

-- 场景 3：多维分析查询
CREATE TABLE training.multi_dim_data (
    region String,
    category String,
    subcategory String,
    event_time DateTime,
    value Float64
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (region, category, subcategory, event_time);

-- 任务 2：数据跳数索引
CREATE TABLE training.events_with_skip_index (
    event_id UInt64,
    event_time DateTime,
    user_id UInt64,
    event_type String,
    amount Float64,
    tags Array(String)
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_time, user_id);

-- 添加 minmax 索引（数值范围）
ALTER TABLE training.events_with_skip_index
ADD INDEX idx_amount_minmax amount TYPE minmax GRANULARITY 4;

-- 添加 set 索引（枚举值）
ALTER TABLE training.events_with_skip_index
ADD INDEX idx_event_type_set event_type TYPE set(100) GRANULARITY 4;

-- 添加 bloom_filter 索引（高基数）
ALTER TABLE training.events_with_skip_index
ADD INDEX idx_user_id_bloom user_id TYPE bloom_filter(0.01) GRANULARITY 4;

-- 添加 tokenbf_v1 索引（字符串搜索）
ALTER TABLE training.events_with_skip_index
ADD INDEX idx_tags_tokenbf tags TYPE tokenbf_v1(512, 3, 0) GRANULARITY 4;

-- 验证点 1：查看索引
SELECT 
    database,
    table,
    name AS index_name,
    type,
    expr,
    granularity
FROM system.data_skipping_indices
WHERE table = 'events_with_skip_index';

-- 插入测试数据
INSERT INTO training.events_with_skip_index
SELECT 
    number AS event_id,
    now() - INTERVAL (number % 365) DAY AS event_time,
    number % 10000 AS user_id,
    ['click', 'view', 'purchase', 'refund'][number % 4 + 1] AS event_type,
    rand() % 1000 AS amount,
    ['tag1', 'tag2', 'tag3'] AS tags
FROM numbers(1000000);

-- 强制索引生效
OPTIMIZE TABLE training.events_with_skip_index FINAL;

-- 验证点 2：测试索引效果
-- 查询使用 amount 索引
SELECT count()
FROM training.events_with_skip_index
WHERE amount > 500;

-- 查询使用 event_type 索引
SELECT count()
FROM training.events_with_skip_index
WHERE event_type = 'purchase';

-- 查询使用 user_id 索引
SELECT count()
FROM training.events_with_skip_index
WHERE user_id = 123;

-- 验证点 3：查看索引使用情况
SELECT 
    table,
    index_name,
    granules,
    marks
FROM system.data_skipping_indices
WHERE table = 'events_with_skip_index';

-- 任务 3：索引性能对比
-- 创建无索引表
CREATE TABLE training.events_no_index (
    event_id UInt64,
    event_time DateTime,
    user_id UInt64,
    event_type String,
    amount Float64
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY event_time;

-- 插入相同数据
INSERT INTO training.events_no_index
SELECT 
    number AS event_id,
    now() - INTERVAL (number % 365) DAY AS event_time,
    number % 10000 AS user_id,
    ['click', 'view', 'purchase', 'refund'][number % 4 + 1] AS event_type,
    rand() % 1000 AS amount
FROM numbers(1000000);

-- 对比查询性能
-- 有索引
SELECT count() FROM training.events_with_skip_index WHERE user_id = 123;

-- 无索引
SELECT count() FROM training.events_no_index WHERE user_id = 123;

-- 验证点 4：对比性能数据
SELECT 
    substring(query, 1, 100) AS query_preview,
    query_duration_ms,
    read_rows
FROM system.query_log
WHERE query LIKE '%user_id = 123%'
  AND type = 'QueryFinish'
ORDER BY event_time DESC
LIMIT 2;
```

**验证测试**：

```sql
-- 测试 1：不同索引类型对比
CREATE TABLE training.index_comparison (
    id UInt64,
    category String,
    value Float64,
    created_at DateTime
) ENGINE = MergeTree()
ORDER BY id;

-- 插入数据
INSERT INTO training.index_comparison
SELECT 
    number AS id,
    concat('cat_', toString(number % 100)) AS category,
    rand() % 1000 AS value,
    now() - INTERVAL (number % 365) DAY AS created_at
FROM numbers(1000000);

-- 测试不同索引类型
-- 1. minmax 索引
ALTER TABLE training.index_comparison
ADD INDEX idx_value_minmax value TYPE minmax GRANULARITY 4;

-- 2. set 索引
ALTER TABLE training.index_comparison
ADD INDEX idx_category_set category TYPE set(100) GRANULARITY 4;

-- 3. bloom_filter 索引
ALTER TABLE training.index_comparison
ADD INDEX idx_value_bloom value TYPE bloom_filter(0.01) GRANULARITY 4;

-- OPTIMIZE 使索引生效
OPTIMIZE TABLE training.index_comparison FINAL;

-- 执行查询并记录性能
SELECT count() FROM training.index_comparison WHERE value > 500;
SELECT count() FROM training.index_comparison WHERE category = 'cat_1';
SELECT count() FROM training.index_comparison WHERE value IN (SELECT number FROM numbers(100));

-- 测试 2：索引命中率分析
SELECT 
    table,
    index_name,
    type,
    granules,
    marks,
    formatReadableSize(data_compressed_bytes) AS compressed_size,
    formatReadableSize(data_uncompressed_bytes) AS uncompressed_size
FROM system.data_skipping_indices
WHERE database = 'training'
ORDER BY table, index_name;
```

**学习资源**：
- 文档：`11-performance/02_primary_indexes.md`
- 文档：`11-performance/04_skipping_indexes.md`

**作业**：
1. 为 3 种不同查询场景设计主键和索引
2. 对比不同索引类型的性能差异
3. 分析生产环境查询并优化索引

---

### 第 6 周：系统调优与监控

#### Day 36-38：系统配置优化

**学习目标**：
- 理解关键配置参数
- 掌握内存和并发优化
- 学会监控和诊断

**实操任务**：

```sql
-- 任务 1：查看当前配置
-- 内存配置
SELECT 
    name,
    value,
    changed,
    description
FROM system.settings
WHERE name IN (
    'max_memory_usage',
    'max_bytes_before_external_group_by',
    'max_bytes_before_external_sort',
    'max_threads',
    'max_insert_threads'
);

-- 并发配置
SELECT 
    name,
    value,
    description
FROM system.settings
WHERE name LIKE '%thread%' OR name LIKE '%concurrent%';

-- 任务 2：优化内存使用
-- 设置查询内存限制
SET max_memory_usage = 10000000000;  -- 10GB

-- 设置外部聚合阈值
SET max_bytes_before_external_group_by = 20000000000;  -- 20GB

-- 设置外部排序阈值
SET max_bytes_before_external_sort = 20000000000;  -- 20GB

-- 任务 3：优化并发
-- 设置查询线程数
SET max_threads = 8;

-- 设置插入线程数
SET max_insert_threads = 4;

-- 设置并发读取
SET max_parallel_replicas = 2;

-- 任务 4：监控资源使用
-- 查看内存使用
SELECT 
    metric,
    value,
    description
FROM system.asynchronous_metrics
WHERE metric LIKE '%Memory%' OR metric LIKE '%memory%'
ORDER BY metric;

-- 查看 CPU 使用
SELECT 
    metric,
    value
FROM system.metrics
WHERE metric LIKE '%CPU%' OR metric LIKE '%Thread%'
ORDER BY metric;

-- 查看磁盘 I/O
SELECT 
    metric,
    value
FROM system.metrics
WHERE metric LIKE '%Disk%' OR metric LIKE '%IO%'
ORDER BY metric;

-- 任务 5：查看查询统计
SELECT 
    user,
    count() AS query_count,
    sum(query_duration_ms) / 1000 AS total_time_sec,
    avg(query_duration_ms) AS avg_time_ms,
    sum(read_rows) AS total_read_rows,
    sum(memory_usage) AS total_memory
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today() - INTERVAL 7 DAY
GROUP BY user
ORDER BY total_time_sec DESC;
```

**验证测试**：

```sql
-- 测试 1：内存使用监控
-- 创建大表测试
CREATE TABLE training.memory_test (
    id UInt64,
    data String,
    value Float64
) ENGINE = MergeTree()
ORDER BY id;

-- 插入大量数据
INSERT INTO training.memory_test
SELECT 
    number AS id,
    repeat('data', 100) AS data,
    rand() % 1000 AS value
FROM numbers(1000000);

-- 执行内存密集型查询
SELECT 
    id,
    sum(value) OVER (ORDER BY id ROWS BETWEEN 1000 PRECEDING AND CURRENT ROW) AS running_sum
FROM training.memory_test
LIMIT 10000;

-- 查看内存使用
SELECT 
    metric,
    value,
    description
FROM system.asynchronous_metrics
WHERE metric LIKE '%Memory%'
ORDER BY metric;

-- 测试 2：并发查询测试
-- 同时执行多个查询
SELECT count() FROM training.memory_test WHERE value > 500;
SELECT avg(value) FROM training.memory_test;
SELECT uniqExact(id) FROM training.memory_test;

-- 查看并发统计
SELECT 
    toStartOfMinute(event_time) AS minute,
    count() AS query_count,
    avg(query_duration_ms) AS avg_duration
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_time >= now() - INTERVAL 1 HOUR
GROUP BY minute
ORDER BY minute DESC;
```

**学习资源**：
- 文档：`11-performance/14_hardware_tuning.md`
- 文档：`13-monitor/01_system_monitoring.md`

**作业**：
1. 优化集群配置参数
2. 设计一个资源监控方案
3. 分析系统瓶颈并提出优化建议

---

#### Day 39-42：性能分析与故障排查

**学习目标**：
- 掌握性能分析工具
- 学会故障排查方法
- 理解常见问题解决方案

**实操任务**：

```sql
-- 任务 1：查询性能分析
-- 使用 EXPLAIN 分析查询
EXPLAIN PLAN 
SELECT 
    event_type,
    count() AS count,
    avg(amount) AS avg_amount
FROM training.events_with_skip_index
WHERE event_time >= now() - INTERVAL 30 DAY
GROUP BY event_type
ORDER BY count DESC;

-- 使用 EXPLAIN PIPELINE 查看执行管道
EXPLAIN PIPELINE 
SELECT count() FROM training.events_with_skip_index;

-- 使用 EXPLAIN ESTIMATE 查看估算
EXPLAIN ESTIMATE
SELECT count() FROM training.events_with_skip_index
WHERE user_id = 123;

-- 任务 2：慢查询分析
-- 查找慢查询
SELECT 
    query_id,
    user,
    query_duration_ms / 1000 AS duration_sec,
    read_rows,
    read_bytes,
    memory_usage,
    substring(query, 1, 200) AS query_preview
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query_duration_ms > 5000  -- 超过 5 秒
  AND event_date >= today() - INTERVAL 7 DAY
ORDER BY query_duration_ms DESC
LIMIT 20;

-- 任务 3：查询 Profile
-- 启用 Profile
SET allow_introspection_functions = 1;

-- 执行查询并查看 Profile
SELECT 
    count(),
    sum(value)
FROM training.events_with_skip_index
WHERE event_time >= now() - INTERVAL 30 DAY
SETTINGS profiler_log_queries = 1;

-- 查看 Profile 结果
SELECT 
    query_id,
    event_time,
    query_duration_ms,
    read_rows,
    memory_usage
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query LIKE '%sum(value)%'
ORDER BY event_time DESC
LIMIT 1;

-- 任务 4：系统健康检查
-- 检查集群状态
SELECT 
    cluster,
    shard_num,
    replica_num,
    host_name,
    host_address,
    port,
    is_local
FROM system.clusters;

-- 检查副本状态
SELECT 
    database,
    table,
    replica_name,
    replica_path,
    total_replicas,
    active_replicas,
    queue_size
FROM system.replicas;

-- 检查磁盘使用
SELECT 
    name,
    path,
    free_space,
    total_space,
    free_space / total_space * 100 AS free_percent
FROM system.disks;

-- 检查合并队列
SELECT 
    database,
    table,
    count() AS merge_count
FROM system.merges
GROUP BY database, table;

-- 任务 5：常见问题排查
-- 问题 1：查询超时
SELECT 
    query_id,
    query_duration_ms,
    exception_code,
    exception,
    substring(query, 1, 200) AS query_preview
FROM system.query_log
WHERE type = 'ExceptionWhileProcessing'
ORDER BY event_time DESC
LIMIT 10;

-- 问题 2：内存不足
SELECT 
    metric,
    value,
    description
FROM system.metrics
WHERE metric LIKE '%Memory%';

-- 问题 3：副本延迟
SELECT 
    database,
    table,
    replica_name,
    queue_size,
    inserts_in_queue,
    merges_in_queue,
    log_max_index - log_pointer AS log_distance
FROM system.replicas
WHERE queue_size > 0
ORDER BY queue_size DESC;

-- 问题 4：分区过多
SELECT 
    database,
    table,
    count() AS partition_count
FROM system.parts
WHERE active = 1
GROUP BY database, table
HAVING partition_count > 100
ORDER BY partition_count DESC;
```

**验证测试**：

```sql
-- 测试 1：性能基准测试
-- 创建测试表
CREATE TABLE training.benchmark (
    id UInt64,
    category String,
    value Float64,
    created_at DateTime
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(created_at)
ORDER BY (created_at, id);

-- 插入测试数据
INSERT INTO training.benchmark
SELECT 
    number AS id,
    concat('cat_', toString(number % 100)) AS category,
    rand() % 1000 AS value,
    now() - INTERVAL (number % 365) DAY AS created_at
FROM numbers(1000000);

-- 运行基准测试
SELECT 
    'Q1: Simple count' AS query_name,
    count() AS result
FROM training.benchmark;

SELECT 
    'Q2: Filtered count' AS query_name,
    count() AS result
FROM training.benchmark
WHERE created_at >= now() - INTERVAL 30 DAY;

SELECT 
    'Q3: Aggregation' AS query_name,
    category,
    count() AS count,
    avg(value) AS avg_value
FROM training.benchmark
WHERE created_at >= now() - INTERVAL 30 DAY
GROUP BY category
ORDER BY count DESC
LIMIT 10;

SELECT 
    'Q4: Join query' AS query_name,
    b.category,
    count() AS count
FROM training.benchmark b
JOIN (
    SELECT DISTINCT category
    FROM training.benchmark
    WHERE value > 500
) c ON b.category = c.category
GROUP BY b.category
ORDER BY count DESC
LIMIT 10;

-- 查看基准测试结果
SELECT 
    query,
    query_duration_ms,
    read_rows,
    memory_usage
FROM system.query_log
WHERE query LIKE '%training.benchmark%'
  AND type = 'QueryFinish'
  AND query NOT LIKE '%system.query_log%'
ORDER BY event_time DESC
LIMIT 4;

-- 测试 2：故障模拟
-- 模拟慢查询
SELECT 
    id,
    repeat('data', 10000) AS large_string,
    sleep(0.01) AS delay
FROM numbers(100);

-- 查看慢查询
SELECT 
    query_id,
    query_duration_ms,
    read_rows,
    substring(query, 1, 100) AS query_preview
FROM system.query_log
WHERE query LIKE '%sleep%'
  AND type = 'QueryFinish'
ORDER BY event_time DESC
LIMIT 1;
```

**学习资源**：
- 文档：`11-performance/11_query_profiling.md`
- 文档：`07-troubleshooting/README.md`

**作业**：
1. 分析 10 个慢查询并提供优化方案
2. 设计一个性能监控系统
3. 编写故障排查手册

---

## 阶段 4：高级特性（第 8-9 周）

### 第 7 周：物化视图与高级功能

#### Day 43-46：物化视图

**学习目标**：
- 掌握物化视图创建和使用
- 理解数据预聚合
- 学会级联物化视图

**实操任务**：

```sql
-- 任务 1：基础物化视图
-- 创建原始数据表
CREATE TABLE training.raw_user_events (
    event_time DateTime,
    user_id UInt64,
    event_type String,
    page_id UInt64,
    duration UInt32
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_time, user_id);

-- 创建聚合结果表
CREATE TABLE training.user_event_summary (
    event_date Date,
    user_id UInt64,
    event_type String,
    event_count UInt64,
    total_duration UInt64,
    avg_duration Float64
) ENGINE = SummingMergeTree()
ORDER BY (event_date, user_id, event_type);

-- 创建物化视图
CREATE MATERIALIZED VIEW training.user_event_summary_mv
TO training.user_event_summary AS
SELECT 
    toDate(event_time) AS event_date,
    user_id,
    event_type,
    count() AS event_count,
    sum(duration) AS total_duration,
    avg(duration) AS avg_duration
FROM training.raw_user_events
GROUP BY event_date, user_id, event_type;

-- 插入原始数据
INSERT INTO training.raw_user_events VALUES
    (now(), 1001, 'click', 101, 50),
    (now(), 1001, 'view', 102, 100),
    (now(), 1002, 'click', 103, 60),
    (now(), 1001, 'click', 104, 70);

-- 验证点 1：查看实时聚合结果
SELECT * FROM training.user_event_summary
ORDER BY event_date, user_id, event_type;

-- 任务 2：预聚合多个维度
-- 创建多维度聚合表
CREATE TABLE training.event_multi_dim_agg (
    event_date Date,
    event_type String,
    page_id UInt64,
    pv UInt64,
    uv AggregateFunction(uniq, UInt64),
    total_duration UInt64
) ENGINE = AggregatingMergeTree()
ORDER BY (event_date, event_type, page_id);

-- 创建物化视图
CREATE MATERIALIZED VIEW training.event_multi_dim_agg_mv
TO training.event_multi_dim_agg AS
SELECT 
    toDate(event_time) AS event_date,
    event_type,
    page_id,
    count() AS pv,
    uniqState(user_id) AS uv,
    sum(duration) AS total_duration
FROM training.raw_user_events
GROUP BY event_date, event_type, page_id;

-- 插入更多数据
INSERT INTO training.raw_user_events
SELECT 
    now() - INTERVAL number SECOND AS event_time,
    number % 100 AS user_id,
    ['click', 'view', 'scroll'][number % 3 + 1] AS event_type,
    number % 10 AS page_id,
    rand() % 100 AS duration
FROM numbers(10000);

-- 验证点 2：查询聚合结果
SELECT 
    event_date,
    event_type,
    page_id,
    pv,
    uniqMerge(uv) AS uv,
    total_duration
FROM training.event_multi_dim_agg
GROUP BY event_date, event_type, page_id, pv, total_duration
ORDER BY event_date, event_type, page_id
LIMIT 10;

-- 任务 3：级联物化视图
-- 第一层：小时聚合
CREATE TABLE training.events_hourly (
    event_hour DateTime,
    event_type String,
    event_count UInt64
) ENGINE = SummingMergeTree()
ORDER BY (event_hour, event_type);

CREATE MATERIALIZED VIEW training.events_hourly_mv
TO training.events_hourly AS
SELECT 
    toStartOfHour(event_time) AS event_hour,
    event_type,
    count() AS event_count
FROM training.raw_user_events
GROUP BY event_hour, event_type;

-- 第二层：天聚合（从小时聚合）
CREATE TABLE training.events_daily (
    event_date Date,
    event_type String,
    event_count UInt64
) ENGINE = SummingMergeTree()
ORDER BY (event_date, event_type);

CREATE MATERIALIZED VIEW training.events_daily_mv
TO training.events_daily AS
SELECT 
    toDate(event_hour) AS event_date,
    event_type,
    sum(event_count) AS event_count
FROM training.events_hourly
GROUP BY event_date, event_type;

-- 验证点 3：查询级联聚合结果
SELECT 'Hourly' AS level, * FROM training.events_hourly ORDER BY event_hour DESC LIMIT 5
UNION ALL
SELECT 'Daily' AS level, toString(event_date), event_type, event_count FROM training.events_daily ORDER BY event_date DESC LIMIT 5;

-- 任务 4：物化视图管理
-- 查看所有物化视图
SELECT 
    database,
    table,
    engine,
    engine_full
FROM system.tables
WHERE engine = 'MaterializedView'
  AND database = 'training';

-- 查看物化视图定义
SHOW CREATE TABLE training.user_event_summary_mv;

-- 暂停物化视图
-- DETACH TABLE training.user_event_summary_mv;

-- 恢复物化视图
-- ATTACH TABLE training.user_event_summary_mv;

-- 删除物化视图
-- DROP TABLE training.user_event_summary_mv;
```

**验证测试**：

```sql
-- 测试 1：物化视图性能测试
-- 清空表
TRUNCATE TABLE training.raw_user_events;
TRUNCATE TABLE training.user_event_summary;

-- 插入大量数据
INSERT INTO training.raw_user_events
SELECT 
    now() - INTERVAL number SECOND AS event_time,
    number % 1000 AS user_id,
    ['click', 'view', 'scroll', 'purchase'][number % 4 + 1] AS event_type,
    number % 100 AS page_id,
    rand() % 100 AS duration
FROM numbers(100000);

-- 查询聚合结果
SELECT 
    event_date,
    event_type,
    sum(event_count) AS total_events,
    sum(total_duration) AS total_duration
FROM training.user_event_summary
GROUP BY event_date, event_type
ORDER BY event_date, event_type;

-- 测试 2：实时性验证
-- 插入新数据
INSERT INTO training.raw_user_events VALUES
    (now(), 9999, 'click', 999, 99);

-- 立即查询（应该看到新数据）
SELECT * FROM training.user_event_summary
WHERE user_id = 9999;
```

**学习资源**：
- 文档：`01-base/05_advanced_features.sql`（物化视图部分）
- 文档：`03-engines/05_special_engines.sql`（MaterializedView 引擎）

**作业**：
1. 设计一个实时监控系统的物化视图架构
2. 实现多级聚合的物化视图
3. 对比物化视图和普通视图的性能差异

---

#### Day 47-49：高级功能

**学习目标**：
- 掌握投影（Projection）
- 学会字典使用
- 理解窗口函数

**实操任务**：

```sql
-- 任务 1：投影（Projection）
-- 创建表
CREATE TABLE training.sales_data (
    sale_time DateTime,
    product_id UInt64,
    region String,
    category String,
    amount Decimal(10, 2),
    quantity UInt32
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(sale_time)
ORDER BY (sale_time, product_id);

-- 添加按地区聚合的投影
ALTER TABLE training.sales_data ADD PROJECTION sales_by_region (
    SELECT 
        region,
        category,
        sum(amount),
        sum(quantity)
    GROUP BY region, category
);

-- 添加按产品聚合的投影
ALTER TABLE training.sales_data ADD PROJECTION sales_by_product (
    SELECT 
        product_id,
        sum(amount),
        sum(quantity)
    GROUP BY product_id
);

-- 插入数据
INSERT INTO training.sales_data
SELECT 
    now() - INTERVAL number SECOND AS sale_time,
    number % 100 AS product_id,
    ['US', 'EU', 'APAC'][number % 3 + 1] AS region,
    ['Electronics', 'Books', 'Clothing'][number % 3 + 1] AS category,
    rand() % 1000 AS amount,
    number % 10 + 1 AS quantity
FROM numbers(100000);

-- OPTIMIZE 使投影生效
OPTIMIZE TABLE training.sales_data FINAL;

-- 验证点 1：查询使用投影
SELECT 
    region,
    category,
    sum(amount) AS total_amount,
    sum(quantity) AS total_quantity
FROM training.sales_data
GROUP BY region, category
ORDER BY total_amount DESC;

-- 验证点 2：查看投影信息
SELECT 
    database,
    table,
    name AS projection_name,
    type
FROM system.projections
WHERE table = 'sales_data';

-- 任务 2：字典
-- 创建简单字典
CREATE DICTIONARY training.product_dict
(
    product_id UInt64,
    product_name String,
    category String,
    price Decimal(10, 2)
)
PRIMARY KEY product_id
SOURCE(CLICKHOUSE(
    table 'products'
    db 'training'
    host 'localhost'
    port 9000
))
LAYOUT(HASHED())
LIFETIME(MIN 300 MAX 600);

-- 使用字典查询
SELECT 
    dictGet('training.product_dict', 'product_name', toUInt64(1)) AS product_name,
    dictGet('training.product_dict', 'price', toUInt64(1)) AS price;

-- 任务 3：窗口函数
-- 创建测试数据
CREATE TABLE training.window_test (
    user_id UInt64,
    event_time DateTime,
    event_type String,
    value Float64
) ENGINE = MergeTree()
ORDER BY (user_id, event_time);

INSERT INTO training.window_test VALUES
    (1, '2024-01-01 10:00:00', 'click', 10.0),
    (1, '2024-01-01 10:01:00', 'view', 20.0),
    (1, '2024-01-01 10:02:00', 'click', 15.0),
    (2, '2024-01-01 10:00:00', 'view', 25.0),
    (2, '2024-01-01 10:01:00', 'click', 30.0);

-- 窗口函数示例
SELECT 
    user_id,
    event_time,
    event_type,
    value,
    -- 累计求和
    sum(value) OVER (PARTITION BY user_id ORDER BY event_time) AS running_sum,
    -- 移动平均
    avg(value) OVER (
        PARTITION BY user_id 
        ORDER BY event_time 
        ROWS BETWEEN 2 PRECEDING AND CURRENT ROW
    ) AS moving_avg,
    -- 排名
    row_number() OVER (PARTITION BY user_id ORDER BY event_time) AS row_num,
    -- 前一个值
    lagInFrame(value, 1) OVER (PARTITION BY user_id ORDER BY event_time) AS prev_value,
    -- 后一个值
    leadInFrame(value, 1) OVER (PARTITION BY user_id ORDER BY event_time) AS next_value
FROM training.window_test
ORDER BY user_id, event_time;
```

**验证测试**：

```sql
-- 测试 1：投影性能对比
-- 无投影查询
SELECT 
    region,
    sum(amount)
FROM training.sales_data
GROUP BY region;

-- 有投影查询
SELECT 
    region,
    category,
    sum(amount),
    sum(quantity)
FROM training.sales_data
GROUP BY region, category
ORDER BY sum(amount) DESC;

-- 对比性能
SELECT 
    substring(query, 1, 100) AS query_preview,
    query_duration_ms,
    read_rows
FROM system.query_log
WHERE query LIKE '%sales_data%'
  AND type = 'QueryFinish'
  AND query NOT LIKE '%system.query_log%'
ORDER BY event_time DESC
LIMIT 2;

-- 测试 2：窗口函数复杂查询
-- 创建更大的数据集
INSERT INTO training.window_test
SELECT 
    number % 100 AS user_id,
    now() - INTERVAL number SECOND AS event_time,
    ['click', 'view', 'purchase'][number % 3 + 1] AS event_type,
    rand() % 100 AS value
FROM numbers(10000);

-- 复杂窗口函数查询
SELECT 
    user_id,
    toDate(event_time) AS event_date,
    event_type,
    count() AS event_count,
    sum(value) AS total_value,
    -- 累计
    sum(sum(value)) OVER (
        PARTITION BY user_id, event_date 
        ORDER BY event_type
    ) AS cumulative_value,
    -- 排名
    rank() OVER (
        PARTITION BY user_id, event_date 
        ORDER BY sum(value) DESC
    ) AS value_rank
FROM training.window_test
GROUP BY user_id, event_date, event_type
ORDER BY user_id, event_date, value_rank;
```

**学习资源**：
- 文档：`01-base/05_advanced_features.sql`
- 文档：`03-engines/05_special_engines.sql`

**作业**：
1. 设计一个使用投影优化的查询方案
2. 实现一个字典加速查询的场景
3. 使用窗口函数实现用户行为漏斗分析

---

### 第 8 周：数据集成与安全

#### Day 50-52：数据集成

**学习目标**：
- 掌握数据导入导出方法
- 学会外部系统集成
- 理解数据格式转换

**实操任务**：

```sql
-- 任务 1：数据导入
-- CSV 格式导入
CREATE TABLE training.import_csv (
    id UInt64,
    name String,
    value Float64
) ENGINE = MergeTree()
ORDER BY id;

-- 从文件导入（如果有文件）
-- INSERT INTO training.import_csv
-- SELECT * FROM file('data.csv', 'CSV');

-- 从 INSERT SELECT 导入
INSERT INTO training.import_csv
SELECT 
    number AS id,
    concat('name_', toString(number)) AS name,
    rand() % 100 AS value
FROM numbers(1000);

-- 验证点 1：查看导入数据
SELECT count() FROM training.import_csv;

-- 任务 2：数据导出
-- 导出为 CSV
SELECT * FROM training.import_csv
INTO OUTFILE 'export.csv'
FORMAT CSV;

-- 导出为 JSON
SELECT * FROM training.import_csv
INTO OUTFILE 'export.json'
FORMAT JSONEachRow;

-- 导出为 Parquet
SELECT * FROM training.import_csv
INTO OUTFILE 'export.parquet'
FORMAT Parquet;

-- 任务 3：外部系统集成
-- MySQL 集成
CREATE TABLE training.mysql_table (
    id UInt64,
    name String,
    created_at DateTime
) ENGINE = MySQL(
    'mysql_host:3306',
    'database',
    'table',
    'user',
    'password'
);

-- PostgreSQL 集成
CREATE TABLE training.postgres_table (
    id UInt64,
    name String
) ENGINE = PostgreSQL(
    'postgres_host:5432',
    'database',
    'table',
    'user',
    'password'
);

-- 任务 4：Kafka 集成
-- 创建 Kafka 表
CREATE TABLE training.kafka_events (
    event_id UInt64,
    event_time DateTime,
    event_type String,
    user_id UInt64
) ENGINE = Kafka()
SETTINGS 
    kafka_broker_list = 'kafka:9092',
    kafka_topic_list = 'events',
    kafka_group_name = 'clickhouse_consumer',
    kafka_format = 'JSONEachRow';

-- 创建目标表
CREATE TABLE training.events_from_kafka (
    event_id UInt64,
    event_time DateTime,
    event_type String,
    user_id UInt64
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY event_time;

-- 创建物化视图消费 Kafka
CREATE MATERIALIZED VIEW training.kafka_consumer_mv
TO training.events_from_kafka AS
SELECT * FROM training.kafka_events;

-- 任务 5：数据格式转换
-- JSON 解析
SELECT 
    JSONExtractString('{"name":"Alice","age":30}', 'name') AS name,
    JSONExtractUInt('{"name":"Alice","age":30}', 'age') AS age;

-- 复杂 JSON 解析
SELECT 
    JSONExtractString('{"user":{"name":"Bob","email":"bob@example.com"}}', 'user', 'name') AS name,
    JSONExtractString('{"user":{"name":"Bob","email":"bob@example.com"}}', 'user', 'email') AS email;

-- 数组处理
SELECT 
    arrayJoin([1, 2, 3, 4, 5]) AS number,
    number * 2 AS doubled;

-- Map 处理
SELECT 
    map('a', 1, 'b', 2, 'c', 3) AS data_map,
    data_map['a'] AS value_a;
```

**验证测试**：

```sql
-- 测试 1：数据格式转换
-- 创建 JSON 数据表
CREATE TABLE training.json_data (
    json_string String
) ENGINE = TinyLog();

INSERT INTO training.json_data VALUES
    ('{"user_id": 1, "event_type": "click", "amount": 100.50}'),
    ('{"user_id": 2, "event_type": "view", "amount": 0}'),
    ('{"user_id": 3, "event_type": "purchase", "amount": 250.00}');

-- 解析 JSON 并插入结构化表
CREATE TABLE training.parsed_events (
    user_id UInt64,
    event_type String,
    amount Float64
) ENGINE = MergeTree()
ORDER BY user_id;

INSERT INTO training.parsed_events
SELECT 
    JSONExtractUInt(json_string, 'user_id') AS user_id,
    JSONExtractString(json_string, 'event_type') AS event_type,
    JSONExtractFloat(json_string, 'amount') AS amount
FROM training.json_data;

SELECT * FROM training.parsed_events;

-- 测试 2：批量数据导入
-- 创建大表
CREATE TABLE training.bulk_import (
    id UInt64,
    category String,
    value Float64,
    created_at DateTime DEFAULT now()
) ENGINE = MergeTree()
ORDER BY id;

-- 批量插入 100 万条
INSERT INTO training.bulk_import
SELECT 
    number AS id,
    concat('cat_', toString(number % 100)) AS category,
    rand() % 1000 AS value
FROM numbers(1000000);

-- 验证导入
SELECT 
    count() AS total_rows,
    uniqExact(category) AS unique_categories,
    min(created_at) AS first_insert,
    max(created_at) AS last_insert
FROM training.bulk_import;
```

**学习资源**：
- 文档：`01-base/08_realtime_writes.sql`
- 文档：`03-engines/04_integration_engines.sql`

**作业**：
1. 实现一个从 MySQL 导入数据的方案
2. 设计一个 Kafka 实时数据流架构
3. 编写数据格式转换的通用函数

---

#### Day 53-56：安全与权限

**学习目标**：
- 掌握用户和角色管理
- 学会权限控制
- 理解安全最佳实践

**实操任务**：

```sql
-- 任务 1：用户管理
-- 创建用户
CREATE USER IF NOT EXISTS analyst 
IDENTIFIED BY 'password123'
SETTINGS readonly = 1;

CREATE USER IF NOT EXISTS developer 
IDENTIFIED BY 'dev456'
SETTINGS readonly = 0;

CREATE USER IF NOT EXISTS admin_user 
IDENTIFIED BY 'admin789'
SETTINGS readonly = 0;

-- 查看用户
SELECT 
    name,
    storage,
    auth_type,
    enabled,
    readonly
FROM system.users;

-- 任务 2：角色管理
-- 创建角色
CREATE ROLE IF NOT EXISTS reader;
CREATE ROLE IF NOT EXISTS writer;
CREATE ROLE IF NOT EXISTS admin;

-- 给角色赋予权限
GRANT SELECT ON *.* TO reader;
GRANT SELECT, INSERT, ALTER ON training.* TO writer;
GRANT ALL ON *.* TO admin;

-- 将角色赋予用户
GRANT reader TO analyst;
GRANT writer TO developer;
GRANT admin TO admin_user;

-- 查看角色
SELECT 
    name,
    storage,
    granted_roles
FROM system.roles;

-- 任务 3：权限控制
-- 查看权限
SHOW GRANTS FOR analyst;
SHOW GRANTS FOR developer;
SHOW GRANTS FOR admin_user;

-- 撤销权限
REVOKE INSERT ON training.* FROM writer;

-- 删除角色
-- DROP ROLE IF EXISTS writer;

-- 任务 4：行级安全
-- 创建表
CREATE TABLE training.sensitive_data (
    id UInt64,
    department String,
    data String
) ENGINE = MergeTree()
ORDER BY id;

-- 插入数据
INSERT INTO training.sensitive_data VALUES
    (1, 'HR', 'HR data'),
    (2, 'Finance', 'Finance data'),
    (3, 'IT', 'IT data'),
    (4, 'HR', 'More HR data');

-- 创建行级策略
CREATE ROW POLICY policy_hr ON training.sensitive_data
FOR SELECT
USING department = 'HR'
TO reader;

-- 任务 5：审计日志
-- 启用审计日志（需要配置）
-- SET log_queries = 1;

-- 查看查询日志
SELECT 
    event_time,
    user,
    query_duration_ms,
    read_rows,
    memory_usage,
    substring(query, 1, 200) AS query_preview
FROM system.query_log
WHERE type = 'QueryFinish'
ORDER BY event_time DESC
LIMIT 10;

-- 查看用户活动
SELECT 
    user,
    count() AS query_count,
    sum(query_duration_ms) AS total_time_ms,
    sum(read_rows) AS total_read_rows
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today() - INTERVAL 7 DAY
GROUP BY user
ORDER BY query_count DESC;
```

**验证测试**：

```sql
-- 测试 1：权限验证
-- 使用 analyst 用户登录
-- docker exec -it clickhouse-server-1 clickhouse-client --user analyst --password password123

-- 尝试 SELECT（应该成功）
-- SELECT * FROM training.events_all LIMIT 10;

-- 尝试 INSERT（应该失败）
-- INSERT INTO training.events_all VALUES (999999, 0, 'test', now(), 'test');
-- 期望结果：权限错误

-- 测试 2：角色切换
-- 查看当前用户角色
SELECT 
    current_user,
    current_roles;

-- 切换角色
SET ROLE reader;

-- 再次查看
SELECT current_roles;

-- 测试 3：审计追踪
-- 查看特定用户的查询
SELECT 
    event_time,
    user,
    query_duration_ms,
    substring(query, 1, 100) AS query_preview
FROM system.query_log
WHERE user = 'analyst'
  AND type = 'QueryFinish'
ORDER BY event_time DESC
LIMIT 10;
```

**学习资源**：
- 文档：`12-security-authentication/README.md`
- 文档：`06-admin/CLUSTER_ADMIN_GUIDE.md`

**作业**：
1. 设计一个多租户系统的权限方案
2. 实现行级安全控制
3. 编写安全审计报告

---

## 阶段 5：运维管理（第 10-11 周）

### 第 9 周：监控与告警

#### Day 57-60：监控系统

**学习目标**：
- 掌握系统监控方法
- 学会告警配置
- 理解监控最佳实践

**实操任务**：

```sql
-- 任务 1：系统监控
-- CPU 监控
SELECT 
    metric,
    value,
    description
FROM system.asynchronous_metrics
WHERE metric LIKE '%CPU%'
ORDER BY metric;

-- 内存监控
SELECT 
    metric,
    value,
    description
FROM system.asynchronous_metrics
WHERE metric LIKE '%Memory%'
ORDER BY metric;

-- 磁盘监控
SELECT 
    name,
    path,
    free_space,
    total_space,
    formatReadableSize(free_space) AS free,
    formatReadableSize(total_space) AS total,
    free_space / total_space * 100 AS free_percent
FROM system.disks;

-- 网络监控
SELECT 
    metric,
    value,
    description
FROM system.asynchronous_metrics
WHERE metric LIKE '%Network%'
ORDER BY metric;

-- 任务 2：查询监控
-- 慢查询监控
SELECT 
    query_id,
    user,
    query_duration_ms / 1000 AS duration_sec,
    read_rows,
    read_bytes,
    memory_usage,
    substring(query, 1, 200) AS query_preview
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query_duration_ms > 5000
ORDER BY query_duration_ms DESC
LIMIT 20;

-- 查询统计
SELECT 
    user,
    count() AS query_count,
    avg(query_duration_ms) AS avg_duration,
    max(query_duration_ms) AS max_duration,
    sum(read_rows) AS total_read_rows
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today() - INTERVAL 7 DAY
GROUP BY user
ORDER BY query_count DESC;

-- 任务 3：复制监控
-- 副本状态
SELECT 
    database,
    table,
    replica_name,
    total_replicas,
    active_replicas,
    queue_size,
    inserts_in_queue,
    merges_in_queue
FROM system.replicas;

-- 副本延迟
SELECT 
    database,
    table,
    replica_name,
    log_max_index,
    log_pointer,
    log_max_index - log_pointer AS log_distance
FROM system.replicas
WHERE log_max_index - log_pointer > 0
ORDER BY log_distance DESC;

-- 任务 4：性能监控
-- 查询性能统计
SELECT 
    toStartOfHour(event_time) AS hour,
    count() AS query_count,
    avg(query_duration_ms) AS avg_duration,
    quantile(0.95)(query_duration_ms) AS p95_duration,
    quantile(0.99)(query_duration_ms) AS p99_duration
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_time >= now() - INTERVAL 24 HOUR
GROUP BY hour
ORDER BY hour;

-- 资源使用统计
SELECT 
    toStartOfHour(event_time) AS hour,
    sum(memory_usage) AS total_memory,
    sum(read_bytes) AS total_read_bytes,
    sum(written_bytes) AS total_written_bytes
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_time >= now() - INTERVAL 24 HOUR
GROUP BY hour
ORDER BY hour;

-- 任务 5：告警规则
-- 磁盘使用告警
SELECT 
    name AS disk,
    formatReadableSize(free_space) AS free_space,
    free_space / total_space * 100 AS free_percent,
    CASE 
        WHEN free_space / total_space < 0.1 THEN 'CRITICAL'
        WHEN free_space / total_space < 0.2 THEN 'WARNING'
        ELSE 'OK'
    END AS status
FROM system.disks;

-- 副本延迟告警
SELECT 
    database,
    table,
    replica_name,
    log_max_index - log_pointer AS log_distance,
    CASE 
        WHEN log_max_index - log_pointer > 1000 THEN 'CRITICAL'
        WHEN log_max_index - log_pointer > 100 THEN 'WARNING'
        ELSE 'OK'
    END AS status
FROM system.replicas
WHERE log_max_index - log_pointer > 0;

-- 慢查询告警
SELECT 
    user,
    count() AS slow_query_count,
    CASE 
        WHEN count() > 100 THEN 'CRITICAL'
        WHEN count() > 10 THEN 'WARNING'
        ELSE 'OK'
    END AS status
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query_duration_ms > 5000
  AND event_time >= now() - INTERVAL 1 HOUR
GROUP BY user
HAVING slow_query_count > 0;
```

**验证测试**：

```sql
-- 测试 1：监控仪表板数据
-- 创建监控视图
CREATE VIEW training.monitoring_dashboard AS
SELECT 
    now() AS timestamp,
    (SELECT value FROM system.asynchronous_metrics WHERE metric = 'MemoryTracking') AS memory_used,
    (SELECT free_space FROM system.disks WHERE name = 'default') AS disk_free,
    (SELECT count() FROM system.processes) AS active_queries,
    (SELECT count() FROM system.merges) AS active_merges;

-- 查询监控数据
SELECT * FROM training.monitoring_dashboard;

-- 测试 2：告警测试
-- 模拟慢查询
SELECT 
    number,
    sleep(0.1) AS delay
FROM numbers(10);

-- 检查慢查询告警
SELECT 
    query_id,
    query_duration_ms,
    substring(query, 1, 100) AS query_preview
FROM system.query_log
WHERE query LIKE '%sleep%'
  AND type = 'QueryFinish'
ORDER BY event_time DESC
LIMIT 1;
```

**学习资源**：
- 文档：`13-monitor/README.md`
- 文档：`13-monitor/06_alerting.md`

**作业**：
1. 设计一个完整的监控系统
2. 实现关键指标的告警规则
3. 编写运维监控日报模板

---

### 第 10 周：故障排查与备份

#### Day 61-64：故障排查

**学习目标**：
- 掌握故障排查方法
- 学会常见问题解决
- 理解应急响应流程

**实操任务**：

```sql
-- 任务 1：诊断查询
-- 集群健康检查
SELECT 
    cluster,
    shard_num,
    replica_num,
    host_name,
    port,
    is_local,
    errors_count,
    slowdowns_count
FROM system.clusters;

-- 副本健康检查
SELECT 
    database,
    table,
    replica_name,
    replica_path,
    total_replicas,
    active_replicas,
    queue_size,
    zookeeper_exception
FROM system.replicas;

-- 任务 2：常见问题排查
-- 问题 1：查询超时
SELECT 
    query_id,
    user,
    query_duration_ms,
    exception_code,
    exception,
    substring(query, 1, 200) AS query_preview
FROM system.query_log
WHERE type = 'ExceptionWhileProcessing'
ORDER BY event_time DESC
LIMIT 10;

-- 问题 2：内存不足
SELECT 
    metric,
    value,
    description
FROM system.asynchronous_metrics
WHERE metric LIKE '%Memory%'
  AND value > 1000000000;  -- 超过 1GB

-- 问题 3：副本同步失败
SELECT 
    database,
    table,
    replica_name,
    zookeeper_path,
    zookeeper_exception,
    last_queue_update_exception
FROM system.replicas
WHERE zookeeper_exception != ''
   OR last_queue_update_exception != '';

-- 问题 4：分区过多
SELECT 
    database,
    table,
    count() AS partition_count
FROM system.parts
WHERE active = 1
GROUP BY database, table
HAVING partition_count > 100
ORDER BY partition_count DESC;

-- 任务 3：性能问题排查
-- 查看当前运行的查询
SELECT 
    query_id,
    user,
    query_duration_ms,
    read_rows,
    memory_usage,
    substring(query, 1, 200) AS query_preview
FROM system.processes
ORDER BY query_duration_ms DESC;

-- 查看合并队列
SELECT 
    database,
    table,
    elapsed,
    progress,
    num_parts,
    result_part_name,
    source_part_names,
    total_size_bytes_compressed,
    bytes_read_uncompressed,
    rows_read,
    rows_written,
    columns_written,
    memory_usage
FROM system.merges;

-- 查看阻塞查询
SELECT 
    query_id,
    user,
    is_initial_query,
    query_duration_ms,
    read_rows,
    memory_usage,
    substring(query, 1, 200) AS query_preview
FROM system.processes
WHERE query_duration_ms > 60000;  -- 超过 1 分钟

-- 任务 4：日志分析
-- 查看错误日志
SELECT 
    event_time,
    query_id,
    query,
    exception,
    stack_trace
FROM system.query_log
WHERE type = 'ExceptionWhileProcessing'
ORDER BY event_time DESC
LIMIT 20;

-- 查看慢查询日志
SELECT 
    event_time,
    query_duration_ms,
    read_rows,
    memory_usage,
    query
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query_duration_ms > 10000
ORDER BY query_duration_ms DESC
LIMIT 20;

-- 任务 5：应急处理
-- 终止慢查询
-- KILL QUERY WHERE query_id = 'xxx';

-- 终止用户的所有查询
-- KILL QUERY WHERE user = 'problematic_user';

-- 暂停表
-- DETACH TABLE problematic_table;

-- 恢复表
-- ATTACH TABLE problematic_table;
```

**验证测试**：

```sql
-- 测试 1：模拟问题并排查
-- 模拟慢查询
SELECT 
    number,
    repeat('data', 10000) AS large_string,
    sleep(0.01)
FROM numbers(100);

-- 查找慢查询
SELECT 
    query_id,
    query_duration_ms,
    read_rows,
    memory_usage
FROM system.query_log
WHERE query LIKE '%sleep%'
  AND type = 'QueryFinish'
ORDER BY event_time DESC
LIMIT 1;

-- 测试 2：问题诊断
-- 创建有问题的表（分区过多）
CREATE TABLE training.too_many_partitions (
    id UInt64,
    partition_key Date
) ENGINE = MergeTree()
PARTITION BY partition_key
ORDER BY id;

-- 插入数据（每个日期一个分区）
INSERT INTO training.too_many_partitions
SELECT 
    number AS id,
    toDate('2024-01-01') + number AS partition_key
FROM numbers(500);

-- 检查分区数量
SELECT 
    database,
    table,
    count() AS partition_count
FROM system.parts
WHERE active = 1
  AND table = 'too_many_partitions'
GROUP BY database, table;
```

**学习资源**：
- 文档：`07-troubleshooting/README.md`
- 文档：`06-admin/TROUBLESHOOTING_GUIDE.md`

**作业**：
1. 编写故障排查手册
2. 设计应急响应流程
3. 实现自动化故障检测

---

#### Day 65-70：备份与恢复

**学习目标**：
- 掌握备份策略
- 学会数据恢复
- 理解灾难恢复

**实操任务**：

```sql
-- 任务 1：数据备份
-- 创建备份表
CREATE TABLE training.backup_users AS training.users;

-- 备份数据
INSERT INTO training.backup_users
SELECT * FROM training.users;

-- 查看备份
SELECT 
    database,
    table,
    count() AS rows,
    formatReadableSize(sum(bytes)) AS size
FROM system.parts
WHERE database = 'training' 
  AND table = 'backup_users'
  AND active = 1;

-- 任务 2：分区备份
-- 备份特定分区
ALTER TABLE training.large_events 
FREEZE PARTITION '202401';

-- 查看备份
SELECT 
    database,
    table,
    partition,
    name,
    active
FROM system.parts
WHERE database = 'training'
  AND table = 'large_events'
  AND name LIKE '%frozen%';

-- 任务 3：数据导出备份
-- 导出为 SQL
SELECT * FROM training.users
INTO OUTFILE 'users_backup.sql'
FORMAT SQLInsert;

-- 导出为 CSV
SELECT * FROM training.users
INTO OUTFILE 'users_backup.csv'
FORMAT CSV;

-- 导出为 JSON
SELECT * FROM training.users
INTO OUTFILE 'users_backup.json'
FORMAT JSONEachRow;

-- 任务 4：数据恢复
-- 从备份表恢复
INSERT INTO training.users
SELECT * FROM training.backup_users;

-- 从文件恢复
-- INSERT INTO training.users
-- SELECT * FROM file('users_backup.csv', 'CSV');

-- 从分区快照恢复
ALTER TABLE training.large_events 
ATTACH PARTITION '202401' FROM '/path/to/backup';

-- 任务 5：灾难恢复
-- 完整备份流程
-- 1. 停止写入
-- 2. 冻结所有分区
ALTER TABLE training.large_events FREEZE;

-- 3. 复制数据文件
-- cp -r /var/lib/clickhouse/shadow/ /backup/

-- 4. 清理冻结
ALTER TABLE training.large_events UNFREEZE;

-- 恢复流程
-- 1. 停止服务
-- systemctl stop clickhouse-server

-- 2. 恢复数据
-- cp -r /backup/* /var/lib/clickhouse/

-- 3. 启动服务
-- systemctl start clickhouse-server

-- 4. 验证数据
SELECT count() FROM training.large_events;
```

**验证测试**：

```sql
-- 测试 1：备份恢复测试
-- 创建测试表
CREATE TABLE training.test_backup_restore (
    id UInt64,
    data String,
    created_at DateTime DEFAULT now()
) ENGINE = MergeTree()
ORDER BY id;

-- 插入测试数据
INSERT INTO training.test_backup_restore
SELECT 
    number AS id,
    concat('data_', toString(number)) AS data
FROM numbers(1000);

-- 备份
CREATE TABLE training.test_backup AS training.test_backup_restore;
INSERT INTO training.test_backup SELECT * FROM training.test_backup_restore;

-- 模拟数据丢失
TRUNCATE TABLE training.test_backup_restore;

-- 验证数据丢失
SELECT count() FROM training.test_backup_restore;

-- 恢复
INSERT INTO training.test_backup_restore SELECT * FROM training.test_backup;

-- 验证恢复
SELECT count() FROM training.test_backup_restore;

-- 测试 2：备份完整性验证
-- 验证备份数据完整性
SELECT 
    'Original' AS source,
    count() AS rows,
    sum(length(data)) AS data_size
FROM training.test_backup_restore
UNION ALL
SELECT 
    'Backup' AS source,
    count() AS rows,
    sum(length(data)) AS data_size
FROM training.test_backup;
```

**学习资源**：
- 文档：`06-admin/BACKUP_RECOVERY_GUIDE.md`
- 文档：`02-advance/02_backup_recovery.sql`

**作业**：
1. 设计完整的备份策略
2. 编写灾难恢复方案
3. 实现自动化备份脚本

---

## 阶段 6：专家级实战（第 12 周）

### 第 11-12 周：项目实战

#### Day 71-77：实战项目

**项目 1：实时分析系统**

**需求**：
- 设计一个实时用户行为分析系统
- 支持百万级 QPS 的数据写入
- 支持实时 PV/UV 统计
- 支持多维分析

**实现步骤**：

```sql
-- 步骤 1：设计表结构
-- 原始事件表
CREATE TABLE training.realtime_events (
    event_id UInt64,
    event_time DateTime,
    user_id UInt64,
    event_type String,
    page_id UInt64,
    device_type String,
    region String,
    extra_data Map(String, String)
) ENGINE = ReplicatedMergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_time, user_id, event_id);

-- 实时聚合表（分钟级）
CREATE TABLE training.events_minute_agg (
    minute DateTime,
    event_type String,
    page_id UInt64,
    region String,
    pv UInt64,
    uv AggregateFunction(uniq, UInt64)
) ENGINE = AggregatingMergeTree()
ORDER BY (minute, event_type, page_id, region);

-- 物化视图
CREATE MATERIALIZED VIEW training.events_minute_agg_mv
TO training.events_minute_agg AS
SELECT 
    toStartOfMinute(event_time) AS minute,
    event_type,
    page_id,
    region,
    count() AS pv,
    uniqState(user_id) AS uv
FROM training.realtime_events
GROUP BY minute, event_type, page_id, region;

-- 步骤 2：实现 Buffer 表优化写入
CREATE TABLE training.events_buffer AS training.realtime_events
ENGINE = Buffer(currentDatabase(), realtime_events, 
    16, 10, 100, 10000, 1000000, 10000000, 100000000);

-- 步骤 3：查询接口
-- 实时 PV/UV
SELECT 
    minute,
    event_type,
    sum(pv) AS total_pv,
    uniqMerge(uv) AS total_uv
FROM training.events_minute_agg
WHERE minute >= now() - INTERVAL 1 HOUR
GROUP BY minute, event_type
ORDER BY minute DESC, total_pv DESC;

-- 多维分析
SELECT 
    region,
    event_type,
    sum(pv) AS total_pv,
    uniqMerge(uv) AS total_uv
FROM training.events_minute_agg
WHERE minute >= toStartOfDay(now())
GROUP BY region, event_type
ORDER BY total_pv DESC;
```

**验证测试**：

```sql
-- 模拟实时数据流
INSERT INTO training.events_buffer
SELECT 
    number AS event_id,
    now() - INTERVAL (number % 60) SECOND AS event_time,
    number % 10000 AS user_id,
    ['click', 'view', 'purchase'][number % 3 + 1] AS event_type,
    number % 100 AS page_id,
    ['mobile', 'desktop', 'tablet'][number % 3 + 1] AS device_type,
    ['US', 'EU', 'APAC'][number % 3 + 1] AS region,
    map('key', 'value') AS extra_data
FROM numbers(10000);

-- 验证实时聚合
SELECT 
    minute,
    event_type,
    sum(pv) AS total_pv,
    uniqMerge(uv) AS total_uv
FROM training.events_minute_agg
WHERE minute >= now() - INTERVAL 5 MINUTE
GROUP BY minute, event_type
ORDER BY minute DESC, event_type;
```

---

**项目 2：监控系统**

**需求**：
- 设计一个完整的监控系统
- 监控集群、查询、性能
- 实现告警功能

**实现步骤**：

```sql
-- 步骤 1：创建监控视图
CREATE VIEW monitoring.cluster_health AS
SELECT 
    now() AS timestamp,
    (SELECT count() FROM system.clusters WHERE cluster = 'treasurycluster') AS nodes_count,
    (SELECT count() FROM system.replicas WHERE active_replicas = total_replicas) AS healthy_replicas,
    (SELECT sum(free_space) FROM system.disks) AS total_free_space;

CREATE VIEW monitoring.query_stats AS
SELECT 
    toStartOfMinute(event_time) AS minute,
    count() AS query_count,
    avg(query_duration_ms) AS avg_duration,
    quantile(0.95)(query_duration_ms) AS p95_duration,
    sum(memory_usage) AS total_memory
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_time >= now() - INTERVAL 1 HOUR
GROUP BY minute
ORDER BY minute DESC;

-- 步骤 2：创建告警视图
CREATE VIEW monitoring.alerts AS
SELECT 
    'disk_space' AS alert_type,
    name AS disk_name,
    free_space / total_space * 100 AS free_percent,
    CASE 
        WHEN free_space / total_space < 0.1 THEN 'CRITICAL'
        WHEN free_space / total_space < 0.2 THEN 'WARNING'
        ELSE 'OK'
    END AS severity
FROM system.disks
WHERE free_space / total_space < 0.2
UNION ALL
SELECT 
    'slow_queries' AS alert_type,
    toString(count()) AS metric,
    count() AS value,
    CASE 
        WHEN count() > 100 THEN 'CRITICAL'
        WHEN count() > 10 THEN 'WARNING'
        ELSE 'OK'
    END AS severity
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query_duration_ms > 5000
  AND event_time >= now() - INTERVAL 5 MINUTE
GROUP BY count();

-- 步骤 3：查询监控数据
SELECT * FROM monitoring.cluster_health;
SELECT * FROM monitoring.query_stats LIMIT 10;
SELECT * FROM monitoring.alerts;
```

---

**项目 3：性能优化实战**

**需求**：
- 分析现有查询性能
- 优化慢查询
- 设计索引方案

**实现步骤**：

```sql
-- 步骤 1：识别慢查询
SELECT 
    query_id,
    query_duration_ms,
    read_rows,
    read_bytes,
    memory_usage,
    substring(query, 1, 300) AS query_preview
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query_duration_ms > 10000
  AND event_date >= today() - INTERVAL 7 DAY
ORDER BY query_duration_ms DESC
LIMIT 20;

-- 步骤 2：分析查询执行计划
-- 对慢查询使用 EXPLAIN
EXPLAIN PLAN 
SELECT /* 慢查询 SQL */;

-- 步骤 3：优化表结构
-- 添加索引
ALTER TABLE training.large_events
ADD INDEX idx_user_bloom user_id TYPE bloom_filter(0.01) GRANULARITY 4;

-- 修改主键（需要重建表）
-- CREATE TABLE training.large_events_optimized AS training.large_events
-- ENGINE = MergeTree()
-- PARTITION BY toYYYYMM(event_time)
-- ORDER BY (user_id, event_time, event_id);

-- 步骤 4：优化查询
-- 使用 PREWHERE
SELECT count()
FROM training.large_events
PREWHERE user_id IN (SELECT number FROM numbers(100))
WHERE event_time >= now() - INTERVAL 30 DAY;

-- 使用物化视图预聚合
CREATE MATERIALIZED VIEW training.events_summary_mv
TO training.events_summary AS
SELECT 
    toDate(event_time) AS event_date,
    event_type,
    count() AS event_count,
    uniqState(user_id) AS unique_users
FROM training.large_events
GROUP BY event_date, event_type;

-- 步骤 5：验证优化效果
-- 对比优化前后性能
SELECT 
    query,
    query_duration_ms,
    read_rows
FROM system.query_log
WHERE query LIKE '%优化后的查询%'
ORDER BY event_time DESC
LIMIT 1;
```

---

## 📊 培训评估体系

### 阶段性考核

#### 阶段 1 考核（第 2 周末）
- **理论测试**：ClickHouse 基础概念（30 分钟）
- **实操测试**：
  1. 创建复制表并验证数据同步（20 分钟）
  2. 创建分布式表并插入数据（20 分钟）
  3. 执行聚合查询并分析结果（20 分钟）
- **通过标准**：完成所有测试，正确率 > 80%

#### 阶段 2 考核（第 5 周末）
- **理论测试**：数据建模和优化理论（45 分钟）
- **实操测试**：
  1. 设计电商订单系统表结构（30 分钟）
  2. 实现数据去重和更新方案（30 分钟）
  3. 优化慢查询并记录性能提升（30 分钟）
- **通过标准**：完成所有测试，正确率 > 75%

#### 阶段 3 考核（第 7 周末）
- **理论测试**：性能优化原理（45 分钟）
- **实操测试**：
  1. 分析查询执行计划并优化（30 分钟）
  2. 设计主键和索引方案（30 分钟）
  3. 实现查询性能基准测试（30 分钟）
- **通过标准**：完成所有测试，正确率 > 70%

#### 阶段 4 考核（第 9 周末）
- **理论测试**：高级功能和安全（45 分钟）
- **实操测试**：
  1. 实现多级物化视图（30 分钟）
  2. 设计权限管理方案（30 分钟）
  3. 实现数据导入导出流程（30 分钟）
- **通过标准**：完成所有测试，正确率 > 70%

#### 阶段 5 考核（第 11 周末）
- **理论测试**：运维管理知识（45 分钟）
- **实操测试**：
  1. 设计监控系统并配置告警（30 分钟）
  2. 排查模拟故障并恢复（30 分钟）
  3. 实现备份恢复方案（30 分钟）
- **通过标准**：完成所有测试，正确率 > 70%

#### 最终考核（第 12 周末）
- **综合项目**（3 天）：
  - 设计并实现一个完整的 ClickHouse 应用系统
  - 包含表设计、性能优化、监控告警
  - 提交项目报告和演示
- **答辩**（1 小时）：
  - 讲解项目架构和实现
  - 回答技术问题
  - 展示性能指标

---

## 📚 学习资源清单

### 官方文档
- [ClickHouse 官方文档](https://clickhouse.com/docs)
- [ClickHouse GitHub](https://github.com/ClickHouse/ClickHouse)
- [ClickHouse 博客](https://clickhouse.com/blog)

### 项目内文档
- `00-infra/README.md` - 集群配置说明
- `01-base/README.md` - 基础使用指南
- `02-advance/README.md` - 高级功能指南
- `03-engines/README.md` - 表引擎详解
- `06-admin/README.md` - 运维管理指南
- `11-performance/README.md` - 性能优化指南
- `13-monitor/README.md` - 监控系统指南

### 推荐书籍
- 《ClickHouse 原理解析与应用实践》
- 《大数据分析：ClickHouse 实战》

### 在线课程
- ClickHouse 官方培训课程
- 极客时间 ClickHouse 专栏

---

## 💡 学习建议

### 学习方法
1. **理论与实践结合**：先理解概念，再动手实践
2. **循序渐进**：按阶段推进，不要跳跃
3. **多做实验**：每个知识点都要亲自验证
4. **记录笔记**：记录学习过程中的问题和心得
5. **参与社区**：加入 ClickHouse 社区，交流经验

### 常见问题
1. **学习时间不足**：可适当延长培训周期，重点掌握核心内容
2. **实践环境问题**：确保 Docker 环境正常，必要时增加资源
3. **性能优化困难**：多分析查询执行计划，理解 ClickHouse 内部机制
4. **生产环境经验少**：多做项目实战，模拟生产场景

### 专家级要求
1. **深入理解原理**：掌握 ClickHouse 内部机制
2. **丰富的实战经验**：参与多个生产项目
3. **优化能力强**：能独立解决性能问题
4. **架构设计能力**：能设计复杂的数据架构
5. **故障排查能力**：快速定位和解决问题

---

## 📋 培训总结

通过 12 周的系统培训，学员将：

✅ 掌握 ClickHouse 集群的部署和配置
✅ 熟练使用 SQL 进行数据操作
✅ 理解并应用各种表引擎
✅ 掌握性能优化技巧
✅ 学会运维监控和故障排查
✅ 具备独立设计和实现项目的能力

**从零基础到专家，ClickHouse 精通之旅！** 🚀
