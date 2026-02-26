---
name: 预测数据存储优化方案
overview: 针对已生成的156亿行预测数据，通过存储结构优化（维度分离+宽指标存储）将数据量降低99%，同时保留所有分析维度
todos:
  - id: create-readme
    content: 创建14-use-case目录和README.md，描述预测数据场景架构和维度分离方案
    status: pending
  - id: prediction-model
    content: 实现预测数据建模SQL，包含维度表、预测宽表、展开视图设计
    status: pending
    dependencies:
      - create-readme
  - id: import-optimization
    content: 实现导入优化SQL，包含Native格式导入、并行写入配置
    status: pending
    dependencies:
      - prediction-model
  - id: query-optimization
    content: 实现查询优化SQL，包含物化视图、预聚合表、跳数索引
    status: pending
    dependencies:
      - prediction-model
  - id: superset-integration
    content: 实现Superset集成SQL，包含分析视图、字典定义、查询模板
    status: pending
    dependencies:
      - query-optimization
  - id: performance-benchmark
    content: 实现性能基准测试SQL，验证导入和查询性能是否达标
    status: pending
    dependencies:
      - superset-integration
---

## 产品概述

针对大规模交易预测分析场景，构建高性能的ClickHouse数据模型和查询优化方案，解决千亿级预测数据的存储、导入和查询性能瓶颈。

## 核心需求

### 业务场景

- 基础数据：每batch约13M行交易数据，约90列不可分割的维度Key
- 星型模型：关联维度表（最大100W行，大部分10W行以内）
- 分析工具：Superset pivot table灵活多维分析

### 预测数据需求

- 数据科学家已生成的预测数据：60-70个月份，每个月份最多20个指标
- 每个batch数据量：13M x 60 x 20 = 156亿行
- **核心洞察**：同一行的90个维度Key在156亿行中重复了1200次（60月 x 20指标）

### 性能瓶颈与目标

| 瓶颈 | 当前状态 | 目标要求 | 差距 |
| --- | --- | --- | --- |
| 导入时间 | >1小时 | <2分钟 | **30x** |
| 查询时间 | >60秒 | <10秒 | **6x** |
| 数据规模 | 10个batch过千亿行 | 可持续扩展 | 存储优化 |


### 核心功能

1. **维度分离存储**：避免维度Key重复1200次，将数据量从156亿压缩到26M行
2. **高效数据导入**：支持大规模预测数据的快速写入
3. **快速查询响应**：支持Superset pivot table的灵活多维分析
4. **保留分析维度**：年度月份、指标、原始90个维度全部保留

## 技术栈选择

- **数据存储**：ClickHouse ReplicatedMergeTree 系列引擎
- **数据建模**：维度分离 + 宽指标存储（数组/Nested类型）
- **查询优化**：物化视图、ARRAY JOIN、跳数索引、查询缓存
- **导入优化**：Native格式、并行写入、异步插入

## 核心技术方案

### 1. 数据模型重构 - 维度分离

**核心思路**：将预测数据从"长格式"转为"宽格式"，消除维度冗余

```
原结构（156亿行）：
transaction_key | dim1...dim90 | prediction_month | metric_id | metric_value
     ↓              ↓              ↓
  重复1200次    重复1200次      重复20次

优化结构（26M行 = 13M维度 + 13M指标）：
1. 维度表（13M行）：transaction_key | dim1...dim90
2. 预测宽表（13M行）：transaction_key | metrics Nested(month UInt8, metric_id UInt8, value Float64)
```

**数据量对比**：

- 原方案：156亿行/batch
- 优化方案：26M行/batch（**减少99.8%**）

### 2. 导入优化方案

**目标：等效156亿行数据导入 < 2分钟**

策略：

- **数据量优化**：实际导入26M行（减少99.8%）
- **并行写入**：`max_insert_threads = 8`
- **Native格式**：使用ClickHouse Native格式传输，避免CSV解析
- **批量提交**：每批 ≥ 100万行

预估性能：

- 26M行使用并行+Native格式，预计 **30-60秒** 完成

### 3. 查询优化方案

**目标：查询响应 < 10秒**

策略：

- **展开视图**：使用ARRAY JOIN按需展开，不物理存储
- **物化聚合视图**：预计算常用聚合组合
- **分区裁剪**：PARTITION BY batch_id
- **排序键优化**：ORDER BY (batch_id, transaction_key)
- **跳数索引**：为metric_id、month添加索引
- **查询缓存**：启用`use_query_cache = 1`

### 4. 存储优化方案

- **维度分离**：避免1200倍维度冗余
- **压缩配置**：使用ZSTD压缩
- **TTL策略**：设置预测数据保留期
- **分层存储**：热数据SSD，冷数据HDD

## 目录结构

```
14-use-case/
├── README.md                              # 预测数据场景总览和架构说明
├── 01_prediction_model.sql                # 预测数据建模 - 维度表、预测宽表、展开视图
├── 02_import_optimization.sql             # 导入优化 - 并行写入、异步插入示例
├── 03_query_optimization.sql              # 查询优化 - 物化视图、索引、缓存配置
├── 04_superset_integration.sql            # Superset集成 - 视图、字典、查询模板
└── 05_performance_benchmark.sql           # 性能基准测试 - 导入和查询性能验证
```

## 实现注意事项

### 性能关键点

1. **维度分离是核心**：避免1200倍冗余是解决问题的关键
2. **批量大小**：插入批次 >= 100万行
3. **分区控制**：按batch_id分区，避免过多分区
4. **数组优化**：使用Nested类型而非多列

### 数据类型优化

- metric_id使用UInt8（最多20个指标）
- month使用UInt8（1-70）
- 参数值使用Float64
- 避免Nullable，使用默认值

### Superset兼容性

- 创建展开视图供Pivot Table使用
- 维度通过JOIN维度表获取
- 年月、指标通过ARRAY JOIN展开