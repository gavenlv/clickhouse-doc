# Iceberg 集成与 Lakehouse 架构

Apache Iceberg 已成为开放表格式的标准，而 ClickHouse 从 23.x 开始逐步增加了 Iceberg 支持。本章讲解 ClickHouse 如何融入 Lakehouse 架构，作为高性能查询引擎直接查询 Iceberg/Delta Lake/Hudi 表中的数据。

## 目录

- [Lakehouse 架构概述](#lakehouse-架构概述)
- [Iceberg 表引擎与表函数](#iceberg-表引擎与表函数)
- [ClickHouse + Iceberg 实战](#clickhouse--iceberg-实战)
- [Lakehouse 格式对比（Iceberg / Delta Lake / Hudi）](#lakehouse-格式对比iceberg--delta-lake--hudi)
- [ClickHouse 在 Lakehouse 中的角色](#clickhouse-在-lakehouse-中的角色)
- [混合架构设计模式](#混合架构设计模式)
- [性能考量与最佳实践](#性能考量与最佳实践)

## Lakehouse 架构概述

### 什么是 Lakehouse

Lakehouse = Data Lake（廉价对象存储 + 开放格式） + Data Warehouse（ACID + 高性能查询）：

```
传统架构：
  Data Lake（S3/GCS）       Data Warehouse（CH/Redshift）
  ├── 原始 Parquet          ├── 清洗后的表
  ├── 无 ACID 语义          ├── 有 ACID 语义
  └── 查询引擎 = Spark      └── 查询引擎 = ClickHouse
         ↑                         ↑
    ETL 管道数据复制（延迟、成本）
    
Lakehouse 架构：
  Data Lake（S3/GCS） + Iceberg/Delta Lake 表格式
  ├── 原始 Parquet（与写入时相同）
  ├── Iceberg 提供 ACID 语义（Snapshot / Partition Evolution）
  └── 查询引擎 = Spark + ClickHouse（同一份数据，无需复制）
         ↑
    无需 ETL！直接查询 Iceberg 表
```

### 为什么 ClickHouse + Lakehouse

| 需求 | 传统方案 | Lakehouse 方案（ClickHouse 直接查） |
|------|---------|----------------------------------|
| 查询数据湖中的 Parquet | ETL 导入 CH（小时级延迟，双倍存储） | 直接查 Iceberg 表（分钟级延迟，零复制） |
| Schema 变更（加列） | Spark 改 Parquet + CH 重建表 | Iceberg Schema Evolution，CH 自动适配 |
| 时间旅行（查历史数据） | 依赖备份/Snapshot | Iceberg Snapshot，SQL `FOR VERSION AS OF` |
| 跨引擎查询 | 每个引擎各存一份 | Spark 写、ClickHouse 读同一份 Iceberg 表 |

## Iceberg 表引擎与表函数

### Iceberg 表函数（临时查询）

```sql
-- 从 S3 读 Iceberg 表（临时查询）
SELECT *
FROM iceberg(
    's3://my-bucket/warehouse/db/orders',
    'minio_admin',
    'minio_password'
)
WHERE order_date >= '2024-01-01'
LIMIT 100;

-- 读取特定 Snapshot（时间旅行）
SELECT count()
FROM iceberg(
    's3://my-bucket/warehouse/db/orders',
    'minio_admin',
    'minio_password',
    'snapshot_id=1234567890'       -- 指定 snapshot
);

-- 读取某个时间点的数据
SELECT *
FROM iceberg(
    's3://my-bucket/warehouse/db/orders',
    'minio_admin',
    'minio_password',
    'snapshot_timestamp=2024-01-15T00:00:00Z'
);
```

### Iceberg 表引擎（持久化表）

```sql
-- 创建 Iceberg 表（持久化，支持 SELECT/INSERT/DELETE）
CREATE TABLE iceberg_orders
ENGINE = Iceberg(
    's3://my-bucket/warehouse/db/orders',   -- Iceberg 表路径
    'minio_admin',                            -- S3 access key
    'minio_password'                          -- S3 secret key
)
SETTINGS
    iceberg_catalog = 'default',
    use_schema_inference = 1;                -- 自动推断 Schema

-- 查询：和普通 MergeTree 表完全一样的语法
SELECT
    toDate(order_time) AS order_date,
    sum(amount) AS total_amount
FROM iceberg_orders
WHERE order_date >= '2024-01-01'
GROUP BY order_date
ORDER BY order_date;

-- 写入：INSERT 写入 Iceberg 表（注意：会写入到 S3）
INSERT INTO iceberg_orders VALUES
(10001, 'customer_001', 299.99, 'completed', now());

-- 删除：支持 DELETE（需要 Iceberg v2 表格式）
-- ALTER TABLE iceberg_orders DELETE WHERE status = 'cancelled';
```

### Schema Evolution（自动适配）

Iceberg 最强能力之一是 Schema 变更不影响历史数据：

```sql
-- Spark 侧：给 Iceberg 表加了一列
-- ALTER TABLE db.orders ADD COLUMN discount DECIMAL(18,2);

-- ClickHouse 侧：无需任何操作！新字段自动可见
SELECT
    order_id,
    amount,
    discount           -- 新列自动出现，历史数据为 NULL
FROM iceberg_orders
WHERE order_date = '2024-06-01';

-- 分区变更同样透明
-- Spark: ALTER TABLE db.orders REPLACE PARTITION FIELD (month(order_time))
-- ClickHouse: 查询自动适配新的分区策略，无需重新建表
```

## ClickHouse + Iceberg 实战

### 端到端流程：Flink → Iceberg → ClickHouse

```
数据流：
  Kafka ──→ Flink ──→ Iceberg 表（S3）
                        │
                        ├──→ Spark 批处理（ML 训练、报表）
                        │
                        └──→ ClickHouse 直接查询（Ad-hoc 分析、BI 看板）
                             ↑
                        同一份数据，零复制！
```

**Flink 写入 Iceberg**（Flink SQL）：

```sql
-- Flink SQL 建 Iceberg Catalog
CREATE CATALOG iceberg_catalog WITH (
    'type' = 'iceberg',
    'catalog-type' = 'hadoop',
    'warehouse' = 's3://my-bucket/warehouse'
);

-- 创建 Iceberg 表（Flink 侧）
CREATE TABLE iceberg_catalog.db.orders (
    order_id BIGINT,
    customer_id STRING,
    amount DECIMAL(18,2),
    status STRING,
    order_time TIMESTAMP(3)
) WITH (
    'format-version' = '2',                -- Iceberg v2（支持 DELETE）
    'write.upsert.enabled' = 'true'        -- 支持 UPSERT
);

-- Flink 从 Kafka 实时写入 Iceberg
INSERT INTO iceberg_catalog.db.orders
SELECT
    order_id,
    customer_id,
    amount,
    status,
    event_time AS order_time
FROM kafka_source;
```

**ClickHouse 读取同一份 Iceberg 表**：

```sql
-- ClickHouse 直接读（无需任何导入）
CREATE TABLE ch_orders
ENGINE = Iceberg('s3://my-bucket/warehouse/db/orders', 'ak', 'sk');

-- 与 BI 工具集成（Superset/Metabase 直接查 ClickHouse）
SELECT
    customer_id,
    sum(amount) AS total_spent,
    count() AS order_count
FROM ch_orders
WHERE order_time >= now() - INTERVAL 30 DAY
GROUP BY customer_id
ORDER BY total_spent DESC
LIMIT 100;
```

### 时间旅行查询

```sql
-- 查看所有 Snapshot
SELECT
    snapshot_id,
    parent_snapshot_id,
    toDateTime(timestamp_ms / 1000) AS snapshot_time,
    operation
FROM iceberg_orders.`$snapshots`
ORDER BY timestamp_ms DESC;

-- 查历史版本数据
SELECT count()
FROM iceberg_orders
FOR VERSION AS OF 1234567890;    -- 假装在某个 snapshot 时刻查询

-- 对比两个版本的数据变化
SELECT
    'current' AS version,
    count() AS row_count
FROM iceberg_orders
UNION ALL
SELECT
    'snapshot_456' AS version,
    count() AS row_count
FROM iceberg_orders
FOR VERSION AS OF 4567890123;
```

## Lakehouse 格式对比（Iceberg / Delta Lake / Hudi）

| 维度 | Apache Iceberg | Delta Lake | Apache Hudi |
|------|---------------|-----------|-------------|
| **ClickHouse 集成** | Iceberg 表引擎 + 表函数（原生支持） | deltaLake() 表函数（23.x+ 实验性） | 无原生支持，需通过 Parquet |
| **Schema Evolution** | 完整（ADD/DROP/RENAME/REORDER） | 完整 | 部分（ADD/DROP） |
| **Partition Evolution** | 支持（变更分区策略不重写数据） | 不支持（需重写） | 不支持 |
| **时间旅行** | Snapshot ID + Timestamp | Version Number + Timestamp | Commit Time |
| **ACID** | Serializable | Serializable | Snapshot Isolation |
| **生态成熟度** | Netflix 发起，Apache 顶级项目 | Databricks 主导，Linux Foundation | Uber 发起，Apache 顶级项目 |
| **写入引擎** | Spark / Flink / Trino | Spark / Flink | Spark / Flink / Kafka Connect |
| **推荐场景** | 多引擎共享数据、需要分区演进 | Databricks 生态、Delta Sharing | 流式 Upsert、CDC 场景 |

### ClickHouse 对各格式的集成能力

```
Iceberg         ★★★★★  Iceberg 表引擎 + 表函数（生产可用）
Delta Lake      ★★★☆☆  deltaLake() 表函数（部分版本支持）
Hudi            ★★☆☆☆  通过 Parquet/HDFS 引擎间接读（需额外处理）
Parquet (裸)    ★★★★☆  s3()/hdfs()/file() 表函数 + Parquet 格式
```

## ClickHouse 在 Lakehouse 中的角色

### 角色定位：高性能查询引擎

```
Lakehouse 分层架构：

  查询层  ┌──────────┐  ┌──────────┐  ┌──────────┐
          │Superset  │  │Metabase  │  │ 自定义 App│
          └────┬─────┘  └────┬─────┘  └────┬─────┘
               │             │             │
  计算层  ┌────┴─────────────┴─────────────┴────┐
          │  ClickHouse（OLAP 查询引擎）          │
          │  - 直接查 Iceberg 表                 │
          │  - 部分热点数据缓存到 MergeTree       │
          └──────────┬──────────────────────────┘
                     │
  表格式层  ┌────────┴──────────────────────────┐
          │  Apache Iceberg 表格式              │
          │  - Metadata（Schema + Snapshot）     │
          │  - Manifest（文件清单）              │
          │  - 数据文件（Parquet）               │
          └──────────┬──────────────────────────┘
                     │
  存储层  ┌──────────┴──────────────────────────┐
          │  S3 / GCS / MinIO / HDFS            │
          └─────────────────────────────────────┘
```

### 何时需要额外缓存到 MergeTree

虽然 ClickHouse 可以"直接查 Iceberg"，但在以下场景建议缓存到本地 MergeTree：

| 场景 | 原因 |
|------|------|
| **高并发查询（>50 QPS）** | S3 的 latency 在高并发下不可接受 |
| **亚秒级响应** | Iceberg 读取有 S3 网络开销，MergeTree 本地文件系统更快 |
| **重复查询同一批数据** | 用物化视图将 Iceberg 热数据缓存到 MergeTree |
| **复杂 JOIN** | 如果 JOIN 涉及多张 Iceberg 表，缓存到本地可以避免重复 S3 读取 |

```sql
-- 热数据缓存策略：MV 将 Iceberg 最近 7 天数据缓存到 MergeTree
CREATE MATERIALIZED VIEW iceberg_hot_cache
ENGINE = MergeTree()
ORDER BY (order_date, order_id)
AS SELECT *
FROM iceberg_orders
WHERE order_date >= today() - 7;
```

## 混合架构设计模式

### 模式 1：写入分离，查询统一

```
Flink/Spark ──写入──→ Iceberg（S3）──读取──→ ClickHouse ──→ Superset
                                      │
                        数据保留 90 天（廉价 S3 存储）
```

### 模式 2：热冷分层

```
Flink ──实时写入──→ ClickHouse MergeTree（最近 7 天）──→ Superset 实时看板
  │
  └──归档──→ Iceberg（S3，永久保留）──→ ClickHouse 直接查 ──→ 历史分析
```

### 模式 3：ClickHouse 作为加速层

```
Hudi/Delta Lake（S3）──全量数据──→ Spark 批处理
                    │
                    └──最近 30 天──→ ClickHouse MergeTree（缓存）──→ BI 查询
```

## 性能考量与最佳实践

### 分区裁剪下推

ClickHouse 读取 Iceberg 表时可以下推分区过滤，避免扫描所有文件：

```sql
-- 好的查询：分区键参与过滤
SELECT sum(amount)
FROM iceberg_orders
WHERE order_time >= '2024-01-01' AND order_time < '2024-02-01'
-- → 只读 1 月份分区的 Parquet 文件

-- 不好的查询：无分区过滤
SELECT count()
FROM iceberg_orders
WHERE status = 'completed'
-- → 扫描所有 Parquet 文件（除非 status 也是分区键）
```

### 列裁剪

ClickHouse 只读取查询中实际使用的列：

```sql
-- ClickHouse 只从 Parquet 读取 order_id 和 amount 两列
SELECT order_id, sum(amount)
FROM iceberg_orders
GROUP BY order_id;
```

### 文件大小建议

| 文件大小 | 对 ClickHouse 查询的影响 |
|---------|------------------------|
| < 32 MB | 文件数过多，metadata 开销大 |
| 128-256 MB（推荐） | 平衡查询延迟和并行度 |
| > 1 GB | 单文件太大，无法充分利用并行读取 |

```sql
-- Iceberg 表写入时设置目标文件大小
-- Spark: SET spark.sql.files.maxRecordsPerFile = 10000000
-- Flink: SET target-file-size-bytes = 268435456  -- 256 MB
```

### 最佳实践总结

1. **分区键选时间维度**：Iceberg 分区按时间（小时/天/月），ClickHouse 可以下推分区过滤
2. **文件大小 128-256MB**：不要太小（metadata 爆炸）也不要太大（并行度受限）
3. **高并发场景加缓存**：频繁查询的热数据用 MV 缓存到 MergeTree
4. **使用 Iceberg v2**：v2 支持 DELETE/UPDATE，与 ClickHouse 的 mutation 语义兼容
5. **监控 S3 读取成本**：ClickHouse 直接查 Iceberg 会产生 S3 GET 请求，注意成本
6. **Schema Evolution 先测后上**：虽然 Iceberg 理论上支持任意 Schema 变更，ClickHouse 适配需要验证

## 相关文档

- [点击前往集成引擎基础](./01_integration_engines.sql) —— S3/HDFS/File 集成引擎
- [点击前往批量导入指南](./11_bulk_import_guide.md) —— Parquet 大批量导入与 Iceberg 的区别
- [点击前往 ClickHouse Cloud 指南](./20_clickhouse_cloud.md) —— Cloud 版本的 Iceberg 支持差异
- [Apache Iceberg 官方文档](https://iceberg.apache.org/docs/latest/)
- [ClickHouse Iceberg Table Engine](https://clickhouse.com/docs/en/engines/table-engines/integrations/iceberg)
