-- =====================================================
-- 01 - ClickHouse 简介与核心优势
-- =====================================================
-- 集群: treasurycluster (2副本)
-- 时间: 0-20分钟
-- =====================================================

-- -----------------------------------------------------
-- 1. 什么是 ClickHouse?
-- -----------------------------------------------------

-- ClickHouse 是一个面向 OLAP 场景的列式存储数据库
-- 特点: 向量化执行、列式存储、分布式架构

SELECT 
    'ClickHouse' AS product,
    'Columnar Database' AS type,
    'Apache 2.0' AS license,
    '2016' AS open_source_year;

-- -----------------------------------------------------
-- 2. 为什么 ClickHouse 这么快?
-- -----------------------------------------------------

-- 核心优势对比图解:
-- 
-- ┌─────────────────────────────────────────────────────────────┐
-- │              ClickHouse 性能优势                              │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                              │
-- │  1. 列式存储                                                  │
-- │     ┌─────────────────────────────────────────────────────┐ │
-- │     │  id:  [1,2,3,4,5]     name: [A,B,C,D,E]            │ │
-- │     │  age: [10,20,30...]  只读需要的列                  │ │
-- │     └─────────────────────────────────────────────────────┘ │
-- │     优势: 减少 I/O、更高压缩率                                │
-- │                                                              │
-- │  2. 向量化执行                                                │
-- │     ┌─────────────────────────────────────────────────────┐ │
-- │     │  SIMD 指令一次处理整列数据                           │ │
-- │     │  比行式执行快 10-100 倍                              │ │
-- │     └─────────────────────────────────────────────────────┘ │
-- │                                                              │
-- │  3. 稀疏索引                                                  │
-- │     ┌─────────────────────────────────────────────────────┐ │
-- │     │  每 8192 行一个索引标记，快速定位数据区域            │ │
-- │     └─────────────────────────────────────────────────────┘ │
-- │                                                              │
-- │  4. 后台合并                                                  │
-- │     ┌─────────────────────────────────────────────────────┐ │
-- │     │  小文件自动合并成大文件，优化查询性能                │ │
-- │     └─────────────────────────────────────────────────────┘ │
-- │                                                              │
-- └─────────────────────────────────────────────────────────────┘

-- -----------------------------------------------------
-- 3. ClickHouse vs 传统数据库
-- -----------------------------------------------------

-- 性能对比 (来自官方 benchmark)
-- 
-- ┌─────────────────────────────────────────────────────────────┐
-- │              ClickHouse vs MySQL vs PostgreSQL              │
-- ├─────────────────────────────────────────────────────────────┤
-- │  场景: 1B 行数据聚合查询                                     │
-- │                                                              │
-- │  MySQL:      ████████████████████████████████  ~30秒        │
-- │  PostgreSQL: ████████████████████████████████  ~25秒        │
-- │  ClickHouse: █ 0.02秒 (快 1000-1500 倍)                   │
-- │                                                              │
-- │  压缩率对比:                                                 │
-- │  MySQL:      1x (原始)                                      │
-- │  ClickHouse: 10-20x (列式压缩)                              │
-- │                                                              │
-- └─────────────────────────────────────────────────────────────┘

-- 查看当前 ClickHouse 版本
SELECT version();

-- 查看编译信息
SELECT 
    name,
    value
FROM system.build_options
WHERE name = 'VersionInteger';

-- -----------------------------------------------------
-- 4. ClickHouse 适用场景
-- -----------------------------------------------------

-- 
-- ┌─────────────────────────────────────────────────────────────┐
-- │              ClickHouse 适用场景                              │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                              │
-- │  ✓ 实时分析仪表板 (Real-time Dashboards)                   │
-- │    - 用户行为分析、流量监控、实时BI                          │
-- │                                                              │
-- │  ✓ 日志分析与存储 (Log Analytics)                          │
-- │    - 服务器日志、应用埋点、ClickStream                       │
-- │                                                              │
-- │  ✓ 商业智能报表 (Business Intelligence)                    │
-- │    - Ad-hoc 查询、多维分析、TTA/TTD 优化                    │
-- │                                                              │
-- │  ✓ 地理空间数据 (Geospatial)                               │
-- │    - 位置追踪、地理围栏、路径分析                            │
-- │                                                              │
-- │  ✓ 时间序列数据 (Time Series)                               │
-- │    - 监控指标、IoT 传感器、金融行情                         │
-- │                                                              │
-- │  ✗ 不适合: 事务处理、频繁更新、点查询                        │
-- │                                                              │
-- └─────────────────────────────────────────────────────────────┘

-- -----------------------------------------------------
-- 5. 快速开始
-- -----------------------------------------------------

-- 使用 Docker 快速启动
-- docker run -d --name clickhouse-server -p 8123:8123 -p 9000:9000 \
--     -clickhouse/clickhouse-server

-- 通过 HTTP 接口访问
-- curl 'http://localhost:8123/'

-- 使用 playground 数据库
USE playground;

-- 创建测试表 (ReplicatedMergeTree)
CREATE TABLE IF NOT EXISTS hello ON CLUSTER treasurycluster (
    id UInt32,
    name String,
    created_at DateTime DEFAULT now()
) ENGINE = ReplicatedMergeTree()
ORDER BY id;

-- 插入数据
INSERT INTO hello (id, name) VALUES 
    (1, 'Alice'),
    (2, 'Bob'),
    (3, 'Charlie');

-- 查询数据
SELECT * FROM hello;

-- -----------------------------------------------------
-- 6. 核心概念一览
-- -----------------------------------------------------

-- 
-- ┌─────────────────────────────────────────────────────────────┐
-- │              ClickHouse 核心概念                             │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                              │
-- │  Table Engine (表引擎)                                      │
-- │  ├── MergeTree - 核心引擎，支持主键索引和后台合并           │
-- │  ├── Distributed - 分布式表引擎                            │
-- 1  │  ├── ReplicatedMergeTree - 复制表引擎                   │
-- │  └── Buffer - 缓冲引擎                                      │
-- │                                                              │
-- │  Key Concepts                                                │
-- │  ├── ORDER BY - 主键排序，决定数据物理存储顺序              │
-- │  ├── PARTITION BY - 分区键，控制数据划分粒度               │
-- │  ├── PRIMARY KEY - 主键(可选，默认同 ORDER BY)              │
-- │  └── SAMPLE BY - 采样键，用于数据采样                      │
-- │                                                              │
-- │  Data Parts                                                  │
-- │  ├── Active parts - 当前活跃的数据分片                     │
-- │  ├── Merging parts - 正在合并的数据分片                     │
-- │  └── Mutations - 异步数据修改操作                          │
-- │                                                              │
-- └─────────────────────────────────────────────────────────────┘

-- 查看所有表引擎
SELECT name FROM system.table_engines LIMIT 10;

-- 查看系统函数
SELECT 
    if(is_aggregate = 1, '聚合函数', '普通函数') AS type,
    count() AS count
FROM system.functions
GROUP BY type;

-- -----------------------------------------------------
-- 7. 练习: 创建你的第一张表
-- -----------------------------------------------------

-- 练习: 创建用户事件表 (Replicated)
DROP TABLE IF EXISTS user_events ON CLUSTER treasurycluster SYNC;

CREATE TABLE IF NOT EXISTS user_events ON CLUSTER treasurycluster (
    event_id UInt64,
    user_id UInt32,
    event_type Enum8('click' = 1, 'view' = 2, 'purchase' = 3, 'login' = 4),
    event_time DateTime,
    page_url String,
    country String,
    revenue Float64 DEFAULT 0
) ENGINE = ReplicatedMergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_type, user_id, event_time)
SETTINGS index_granularity = 8192;

-- 插入测试数据
INSERT INTO user_events
SELECT 
    number AS event_id,
    number % 10000 AS user_id,
    CAST(number % 4 + 1 AS Enum8('click' = 1, 'view' = 2, 'purchase' = 3, 'login' = 4)) AS event_type,
    now() - INTERVAL (number % 10000) MINUTE AS event_time,
    concat('https://example.com/page/', toString(number % 100)) AS page_url,
    ['US', 'CN', 'UK', 'JP', 'DE'][number % 5 + 1] AS country,
    if(number % 10 = 0, rand() % 1000, 0) AS revenue
FROM numbers(10000);

-- 查询验证
SELECT 
    event_type,
    count() AS cnt,
    uniqExact(user_id) AS unique_users,
    sum(revenue) AS total_revenue
FROM user_events
GROUP BY event_type
ORDER BY cnt DESC;

-- -----------------------------------------------------
-- 8. 本章小结
-- -----------------------------------------------------

-- 
-- ┌─────────────────────────────────────────────────────────────┐
-- │              本章要点                                       │
-- ├─────────────────────────────────────────────────────────────┤
-- │                                                              │
-- │  1. ClickHouse 是面向 OLAP 的列式数据库                     │
-- │  2. 核心优势: 列式存储 + 向量化执行 + 稀疏索引              │
-- │  3. 性能比传统数据库快 100-1000 倍                          │
-- │  4. 适用场景: 分析型查询、报表、日志、实时BI               │
-- │  5. 不适合: 事务型应用、频繁更新                            │
-- │                                                              │
-- │  下一步: 02_architecture.sql - 深入理解架构                 │
-- │                                                              │
-- └─────────────────────────────────────────────────────────────┘

-- 验证学习
SELECT 
    'intro' AS chapter,
    'completed' AS status,
    now() AS completed_at;
