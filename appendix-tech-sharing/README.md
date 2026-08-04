# ClickHouse 技术分享（附录 A）

> **定位：1 小时分享素材，非教程主干。**
>
> 本目录是从原 `18-ch-introduction-cn` / `19-ch-introduction-en` 降级而来的**分享演示包**，用于给团队做 ClickHouse 快速科普（1 小时讲完，附现场演示）。如需系统学习，深度内容请前往对应主干章节：
>
> | 本目录内容 | 深度版本（主干章） |
> |-----------|------------------|
> | 01 简介与优势 | [01-getting-started](../01-getting-started/README.md) |
> | 02 架构（列存/向量化/分布式） | [02-principles（原理）](../02-principles/README.md) + [09-distributed（分布式）](../09-distributed/README.md) |
> | 03 MergeTree 引擎 | [04-engines（表引擎）](../04-engines/README.md) |
> | 04 查询优化 | [08-performance（性能优化）](../08-performance/README.md) |
> | 05 最佳实践 | [15-best-practices（最佳实践与反模式）](../15-best-practices/README.md) |
> | 06 现场演示 | 同左（可直接用于分享演示） |

本目录包含 ClickHouse 技术分享的所有 SQL 演示文件。

## 目录结构

```
presentation-1hour/
├── README.md                    # 本文件 - 分享大纲
├── [01_intro.sql](01_intro.sql)                 # ClickHouse 简介与核心优势
├── [02_architecture.sql](02_architecture.sql)    # 架构解析：列式存储、向量化、分布式
├── [03_mergetree.sql](03_mergetree.sql)           # MergeTree 引擎核心原理
├── [04_query_optimization.sql](04_query_optimization.sql)  # 查询优化技巧
├── [05_best_practices.sql](05_best_practices.sql) # 最佳实践与常见问题
└── [06_demo.sql](06_demo.sql)                     # 现场演示案例
```

## 快速导航

| 文件 | 内容 |
|------|------|
| [01_intro.sql](01_intro.sql) | ClickHouse 简介与核心优势 |
| [02_architecture.sql](02_architecture.sql) | 架构解析：列式存储、向量化、分布式 |
| [03_mergetree.sql](03_mergetree.sql) | MergeTree 引擎核心原理 |
| [04_query_optimization.sql](04_query_optimization.sql) | 查询优化技巧 |
| [05_best_practices.sql](05_best_practices.sql) | 最佳实践与常见问题 |
| [06_demo.sql](06_demo.sql) | 现场演示案例 |

## 环境要求

- ClickHouse集群: treasurycluster (2副本)
- 数据库: playground (预先创建)
- 引擎: ReplicatedMergeTree 系列 (使用默认宏配置)
- 执行: 所有SQL包含 `ON CLUSTER treasurycluster`

## 内容概览

### 01 - ClickHouse 简介与核心优势

**文件**: [01_intro.sql](01_intro.sql)

**核心内容**:
- 什么是 ClickHouse?
- 为什么 ClickHouse 这么快?
  - 列式存储
  - 向量化执行
  - 稀疏索引
  - 后台合并
- ClickHouse vs 传统数据库
- ClickHouse 适用场景
- 快速开始示例
- 核心概念一览

### 02 - ClickHouse 核心架构解析

**文件**: [02_architecture.sql](02_architecture.sql)

**核心内容**:
- ClickHouse 整体架构
- 列式存储 vs 行式存储
  - 存储文件结构
  - 压缩率对比
- 向量化执行引擎
  - SIMD 指令优势
  - 性能对比
- 稀疏索引机制
  - 索引粒度
  - 索引查找原理
- 查询处理管道
  - Parser → Interpreter → Execution
- 分布式架构
  - 分片与副本
  - 数据分布策略
- 后台任务与合并

### 03 - MergeTree 引擎核心原理

**文件**: [03_mergetree.sql](03_mergetree.sql)

**核心内容**:

#### MergeTree 引擎家族详解

ClickHouse 的 MergeTree 是核心存储引擎家族，分为两个系列：

---

##### 【MergeTree 系列】- 不支持副本（单节点环境）

| 引擎名称 | 说明 | 适用场景 |
|---------|------|---------|
| **MergeTree** | 核心基础引擎，最常用 | 通用场景，高性能写入 |
| **SummingMergeTree** | 自动聚合相同键的数值列 | 预聚合场景，指标汇总 |
| **AggregatingMergeTree** | 预聚合，需配合物化视图 | 复杂预聚合，高基数维度 |
| **CollapsingMergeTree** | 删除标记折叠 | 支持软删除 |
| **VersionedCollapsingMergeTree** | 版本控制折叠 | 带版本号的增量更新 |
| **ReplacingMergeTree** | 版本号替换 | 去重，保留最新版本 |
| **VersionedReplacingMergeTree** | 带版本号的替换 | 更精细的版本控制 |
| **GraphiteMergeTree** | Graphite 数据优化 | 监控指标存储 |

---

##### 【ReplicatedMergeTree 系列】- 支持副本（集群环境）

| 引擎名称 | 说明 | 适用场景 |
|---------|------|---------|
| **ReplicatedMergeTree** | 支持副本复制 | 生产集群，高可用 |
| **ReplicatedSummingMergeTree** | 副本 + 自动聚合 | 分布式预聚合 |
| **ReplicatedAggregatingMergeTree** | 副本 + 预聚合 | 分布式复杂聚合 |
| **ReplicatedCollapsingMergeTree** | 副本 + 删除标记折叠 | 分布式软删除 |
| **ReplicatedVersionedCollapsingMergeTree** | 副本 + 版本折叠 | 分布式增量更新 |
| **ReplicatedReplacingMergeTree** | 副本 + 版本替换 | 分布式去重 |
| **ReplicatedVersionedReplacingMergeTree** | 副本 + 版本替换 | 分布式版本控制 |
| **ReplicatedGraphiteMergeTree** | 副本 + Graphite 优化 | 分布式监控存储 |

---

##### 核心区别

| 特性 | MergeTree 系列 | ReplicatedMergeTree 系列 |
|-----|---------------|-------------------------|
| 副本支持 | ❌ 不支持 | ✅ 支持 |
| ZooKeeper | ❌ 不需要 | ✅ 需要 |
| 高可用 | ❌ 单节点 | ✅ 多副本 |
| 数据同步 | 本地 | 自动跨节点复制 |
| 适用环境 | 开发/测试 | 生产集群 |

---

##### MergeTree 核心概念

- **ORDER BY** (必须): 决定数据物理存储顺序，影响索引结构
- **PARTITION BY** (可选): 数据分区粒度，常用 toYYYYMM/toYYYYMMDD
- **PRIMARY KEY** (可选): 默认等于 ORDER BY，可独立设置
- **SAMPLE BY** (可选): 数据采样键，支持 SAMPLE 查询
- **SETTINGS**: 索引粒度、wide 格式等配置

##### 数据写入与 Part 文件

- Part 文件结构: .bin (压缩数据), .mrk2 (索引标记), primary.idx (主键索引)
- 写入流程: 内存 → 临时 part → 合并为正式 part
- 后台合并: 自动合并小 parts，优化存储

##### 主键选择原则

- 高基数字段放前面
- 过滤频率高的列放前面
- 避免使用随机值
- 复合主键不超过 3-4 个

##### 分区策略

- **按天分区** (toYYYYMMDD): 数据量大、需快速定位
- **按月分区** (toYYYYMM): 历史数据分析
- **不分区**: 数据量小，避免跨分区查询

### 04 - 查询优化技巧与实践

**文件**: [04_query_optimization.sql](04_query_optimization.sql)

**核心内容**:
- 查询优化核心原则
  - 列裁剪
  - 谓词下推
  - 分区裁剪
  - 索引利用
  - 数据采样
- 列裁剪优化
  - SELECT * vs 选择性列
  - 性能对比
- PREWHERE 优化
  - 先过滤再读取
  - 自动优化
- 分区裁剪
  - 利用 PARTITION BY
  - 避免全表扫描
- 使用 Skipping Index
  - set 类型
  - bloom_filter 类型
- 数据采样
  - SAMPLE 语法
  - 近似计算
- 近似聚合
  - uniq vs uniqExact
  - quantile vs quantileExact
- 物化视图优化
  - 预聚合
  - 性能对比

### 05 - 最佳实践与常见问题

**文件**: [05_best_practices.sql](05_best_practices.sql)

**核心内容**:
- 表设计最佳实践
  - 表引擎选择
  - 主键设计
  - 分区策略
  - 数据类型优化
  - 避免 NULL
- 数据类型优化
  - LowCardinality(String)
  - 压缩率提升
- 分片键选择原则
  - 分布均匀
  - 查询模式
- 写入优化
  - 批量写入
  - 异步写入
  - Buffer 表
  - 避免小文件
- 常见错误与解决方案
  - Too many parts
  - Memory limit exceeded
  - 数据类型错误
  - 重复写入
- 监控与调优
  - 系统健康指标
  - 慢查询分析
  - 内存使用
- ETL vs ClickHouse 职责划分

### 06 - 现场演示案例

**文件**: [06_demo.sql](06_demo.sql)

**演示内容**:
1. **实时分析仪表板**
   - 今日订单统计
   - 过去7天趋势
   - 品类销售排行
   - 小时分布
   - 用户留存分析

2. **实时数据管道**
   - Buffer 表演示
   - 高吞吐写入
   - 后台刷新

3. **物化视图预聚合**
   - 日统计视图
   - 毫秒级响应
   - 性能对比

4. **用户行为漏斗分析**
   - 页面浏览 → 购买转化
   - 各步骤转化率
   - 整体转化率

5. **地理分布分析**
   - 按国家统计
   - 订单量与收入
   - 平均订单金额

## 使用方式

### 1. 环境准备

```bash
# 启动 ClickHouse 集群 (使用 00-infra 目录配置)
cd 00-infra
docker-compose up -d

# 验证集群状态
docker ps
```

### 2. 执行演示

按顺序执行每个SQL文件：

```bash
# 方式1: 使用 clickhouse-client
clickhouse-client --host localhost --port 9000 < presentation-1hour/01_intro.sql

# 方式2: 使用 HTTP 接口
curl -X POST http://localhost:8123/ --data-binary @presentation-1hour/01_intro.sql

# 方式3: 在 ClickHouse 客户端中
clickhouse-client --host localhost --port 9000
> source presentation-1hour/01_intro.sql
```

### 3. 数据库说明

所有演示使用 `playground` 数据库，该数据库已预先创建。如需创建：

```sql
CREATE DATABASE IF NOT EXISTS playground;
```

### 4. 集群配置

集群名称: `treasurycluster`  
副本数: 2  
所有 DDL 语句包含 `ON CLUSTER treasurycluster`  
所有 DROP 语句使用 `SYNC` 选项同步执行

## 重要提示

1. **执行顺序**: 建议按文件编号顺序执行 (01 → 06)
2. **数据清理**: 演示过程中创建的表会使用 `DROP ... SYNC` 删除
3. **性能测试**: 部分操作涉及大量数据 (300万行)，执行时间可能较长
4. **配置要求**: 建议使用至少 4GB 内存的机器运行演示

## 参考资源

- [ClickHouse 官方文档](https://clickhouse.com/docs)
- [ClickHouse GitHub](https://github.com/ClickHouse/ClickHouse)
- [ClickHouse 性能基准测试](https://clickhouse.com/benchmark)

## 贡献

如有问题或建议，欢迎提交 Issue 或 Pull Request。

---

**版本**: v1.0  
**最后更新**: 2024
**维护者**: ClickHouse 技术团队
