# 大规模预测数据分析场景

本专题解决千亿级预测数据的存储、导入和查询性能问题，支持Superset实时多维分析。

## 📊 业务场景

### 问题背景

```
基础数据：每batch约13M行交易数据，90列维度Key（不可分割）
预测数据：数据科学家已生成的156亿行（13M × 60月 × 20指标）
指标结构：4层父子结构，共20个指标
查询模式：每次查询都涉及所有指标、所有年份月份、加上维度分析

性能瓶颈：
├── 导入时间：>1小时 → 目标 <2分钟
├── 查询时间：>60秒 → 目标 <10秒
└── 数据规模：10个batch过千亿行
```

### 核心洞察

**同一transaction_key的90维度重复了1200次（60月 × 20指标）**

```
原结构（156亿行）：
┌─────────────────┬──────────────┬──────────────┬───────────────┐
│ transaction_key │ dim1...dim90 │ pred_month   │ metric_value  │
├─────────────────┼──────────────┼──────────────┼───────────────┤
│ KEY_001         │ A,B,C...     │ 2024-01      │ 100.5         │  ← 90个维度重复1200次
│ KEY_001         │ A,B,C...     │ 2024-02      │ 102.3         │
│ ...             │ ...          │ ...          │ ...           │
│ KEY_001         │ A,B,C...     │ 2029-12      │ 200.8         │
└─────────────────┴──────────────┴──────────────┴───────────────┘
```

## 🏗️ 解决方案：维度分离 + 数组存储

### 数据模型重构

```
优化后存储结构（总行数: 2600万 = 99.8%减少）

┌─────────────────────────────────────────────────────────────────┐
│ 1. transaction_dimensions (维度表) - 13M行                      │
├─────────────────────────────────────────────────────────────────┤
│ transaction_key │ dim1 │ dim2 │ ... │ dim90 │ batch_id         │
│ String          │ 各种类型    │      │       │ UInt32          │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│ 2. prediction_values (预测数据表) - 13M行                       │
├─────────────────────────────────────────────────────────────────┤
│ transaction_key │ batch_id │ metrics_values                    │
│ String          │ UInt32   │ Array(Array(Float64))             │
│                 │          │ [metric_id][month_offset] = value  │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│ 3. metric_metadata (指标元数据表) - 20行                        │
├─────────────────────────────────────────────────────────────────┤
│ metric_id │ metric_name │ level │ parent_id │ full_path        │
│ UInt8     │ String      │ UInt8 │ UInt8?    │ Array(UInt8)     │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│ 4. month_mapping (年月映射表) - 60行                            │
├─────────────────────────────────────────────────────────────────┤
│ month_offset │ year_month │ year │ quarter │ month_name        │
│ UInt8        │ String     │ UInt16│ UInt8   │ String           │
└─────────────────────────────────────────────────────────────────┘
```

### 指标4层父子结构

```
Level 0: TOTAL_REVENUE (总收入)
  │
  ├── Level 1: PRODUCT_REVENUE (产品收入)
  │     │
  │     ├── Level 2: ONLINE_REVENUE (线上收入)
  │     │     ├── Level 3: MOBILE_REVENUE (移动端收入)
  │     │     ├── Level 3: WEB_REVENUE (网页端收入)
  │     │     └── Level 3: APP_REVENUE (APP收入)
  │     │
  │     └── Level 2: OFFLINE_REVENUE (线下收入)
  │           ├── Level 3: STORE_REVENUE (门店收入)
  │           └── Level 3: PARTNER_REVENUE (合作伙伴收入)
  │
  ├── Level 1: SERVICE_REVENUE (服务收入)
  │     │
  │     ├── Level 2: CONSULTING_REVENUE (咨询收入)
  │     │     ├── Level 3: ENTERPRISE_CONSULTING (企业咨询)
  │     │     └── Level 3: SMB_CONSULTING (中小企业咨询)
  │     │
  │     └── Level 2: SUPPORT_REVENUE (支持收入)
  │           ├── Level 3: PREMIUM_SUPPORT (高级支持)
  │           └── Level 3: BASIC_SUPPORT (基础支持)
  │
  └── Level 1: OTHER_REVENUE (其他收入)
        ├── Level 2: LICENSING_REVENUE (许可收入)
        └── Level 2: SUBSCRIPTION_REVENUE (订阅收入)
```

## 📁 文件结构

```
14-use-case/
├── README.md                       # 本文件 - 场景总览
├── 01_schema_ddl.sql               # 完整DDL - 数据库、表结构定义
├── 02_sample_data_dml.sql          # 模拟数据生成和插入
├── 03_prediction_views.sql         # 展开视图 - 支持Superset Pivot
├── 04_import_optimization.sql      # 导入优化 - 并行写入、Native格式
├── 05_query_optimization.sql       # 查询优化 - 物化视图、索引、缓存
└── 06_superset_integration.sql     # Superset集成 - 查询模板
```

## 🎯 性能预期

| 指标 | 原方案 | 优化方案 | 提升 |
|------|--------|----------|------|
| 存储行数 | 156亿 | 2600万 | **99.8%减少** |
| 导入时间 | >1小时 | <2分钟 | **30x** |
| 查询时间 | >60s | <10s | **6x+** |
| Superset分析 | ✅ | ✅ | 完全兼容 |

## 🚀 快速开始

### 1. 创建数据库和表结构

```bash
docker exec -it clickhouse1 clickhouse-client --queries-file /var/lib/clickhouse/user_files/14-use-case/01_schema_ddl.sql
```

### 2. 生成模拟数据

```bash
docker exec -it clickhouse1 clickhouse-client --queries-file /var/lib/clickhouse/user_files/14-use-case/02_sample_data_dml.sql
```

### 3. 创建分析视图

```bash
docker exec -it clickhouse1 clickhouse-client --queries-file /var/lib/clickhouse/user_files/14-use-case/03_prediction_views.sql
```

### 4. 配置Superset数据源

在Superset中配置ClickHouse连接，使用 `prediction_analysis_view` 作为数据集。

## 📖 详细文档

- [01_schema_ddl.sql](./01_schema_ddl.sql) - 表结构定义和索引设计
- [02_sample_data_dml.sql](./02_sample_data_dml.sql) - 模拟数据生成
- [03_prediction_views.sql](./03_prediction_views.sql) - Superset分析视图
- [04_import_optimization.sql](./04_import_optimization.sql) - 导入性能优化
- [05_query_optimization.sql](./05_query_optimization.sql) - 查询性能优化
- [06_superset_integration.sql](./06_superset_integration.sql) - Superset集成指南

## 🔗 相关文档

- [08-performance/](../08-performance/README.md) - 性能优化专题
- [06-modeling/](../06-modeling/README.md) - 数据建模最佳实践
