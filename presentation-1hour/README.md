# ClickHouse 一小时技术分享

本目录包含为期约1小时的ClickHouse技术分享所有SQL演示文件。

## 目录结构

```
presentation-1hour/
├── README.md              # 本文件 - 分享大纲与时间安排
├── 01_intro.sql           # ClickHouse 简介与核心优势 (0-20分钟)
├── 02_architecture.sql    # 架构解析：列式存储、向量化、分布式 (20-35分钟)
├── 03_mergetree.sql       # MergeTree 引擎核心原理 (35-45分钟)
├── 04_query_optimization.sql  # 查询优化技巧 (45-55分钟)
├── 05_best_practices.sql  # 最佳实践与常见问题 (55-60分钟)
└── 06_demo.sql            # 现场演示案例
```

## 环境要求

- ClickHouse集群: treasurycluster (2副本)
- 数据库: playground (预先创建)
- 引擎: ReplicatedMergeTree 系列 (使用默认宏配置)
- 执行: 所有SQL包含 `ON CLUSTER treasurycluster`

## 内容概览

### 01 - ClickHouse 简介与核心优势 (0-20分钟)

**文件**: `01_intro.sql`

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

### 02 - ClickHouse 核心架构解析 (20-35分钟)

**文件**: `02_architecture.sql`

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

### 03 - MergeTree 引擎核心原理 (35-45分钟)

**文件**: `03_mergetree.sql`

**核心内容**:
- MergeTree 家族概览
- MergeTree 核心概念
  - ORDER BY
  - PARTITION BY
  - PRIMARY KEY
  - SAMPLE BY
  - SETTINGS
- 数据写入与 Part 文件
  - Part 文件结构
  - 写入流程
- 后台合并演示
  - 合并前后对比
  - 手动触发合并
- 主键选择原则
  - 高基数优先
  - 避免随机值
- 分区策略
  - 按天/按月/不分区
- MergeTree 变体
  - SummingMergeTree
  - AggregatingMergeTree
  - 物化视图预聚合

### 04 - 查询优化技巧与实践 (45-55分钟)

**文件**: `04_query_optimization.sql`

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

### 05 - 最佳实践与常见问题 (55-60分钟)

**文件**: `05_best_practices.sql`

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

**文件**: `06_demo.sql`

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
