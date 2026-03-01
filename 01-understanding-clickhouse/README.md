# 01 - 理解 ClickHouse

本目录帮助你从零开始理解 ClickHouse 的核心概念，适合完全零基础的初学者。

## 学习目标

完成本章节后，你将能够：
- 理解 ClickHouse 的定位和适用场景
- 掌握 ClickHouse 的核心架构概念
- 熟悉基本的 SQL 操作
- 了解 ClickHouse 与传统数据库的差异

## 文件说明

### 01_what_is_clickhouse.sql
**什么是 ClickHouse？**
- ClickHouse 的定位和特点
- 适用场景 vs 不适用场景
- 性能特点展示
- 与其他数据库的对比

### 02_column_oriented.sql
**列式存储原理**
- 行式存储 vs 列式存储
- 列式存储的优势
- 数据压缩原理
- 实际性能对比

### 03_mergeTree_engine.sql
**MergeTree 引擎家族**
- MergeTree 基础概念
- 排序键和主键
- 数据分区原理
- 合并(Merge)机制

### 04_basic_sql.sql
**基础 SQL 操作**
- 创建数据库和表
- 数据类型介绍
- INSERT 和 SELECT
- 基本查询语法

### 05_cluster_concepts.sql
**集群基础概念**
- 分片(Shard)概念
- 副本(Replica)概念
- 分布式表原理
- Keeper/ZooKeeper 作用

### 06_first_replicated_table.sql
**第一个复制表**
- 创建复制表
- 理解复制机制
- 验证数据同步
- 故障转移基础

## 学习路径建议

```
第1天: 01_what_is_clickhouse.sql + 02_column_oriented.sql
       ↓ 理解 ClickHouse 是什么，为什么快

第2天: 03_mergeTree_engine.sql
       ↓ 理解最核心的 MergeTree 引擎

第3天: 04_basic_sql.sql
       ↓ 动手实践基础 SQL

第4天: 05_cluster_concepts.sql
       ↓ 理解集群架构

第5天: 06_first_replicated_table.sql
       ↓ 创建第一个高可用表
```

## 环境准备

确保集群已启动：
```bash
cd 00-infra
docker compose up -d
```

验证连接：
```bash
# 访问 Play UI
open http://localhost:8123/play

# 或使用 curl
curl http://localhost:8123/?query=SELECT%201
```

## 学习方法

1. **阅读注释**：每个 SQL 文件包含详细的注释说明
2. **动手执行**：在 Play UI 或客户端中实际执行每条 SQL
3. **观察结果**：仔细查看查询结果和系统响应
4. **修改尝试**：尝试修改参数，观察不同效果
5. **记录笔记**：记录自己的理解和疑问

## 验证检查清单

完成本章节后，确认你能：
- [ ] 解释 ClickHouse 为什么适合 OLAP 场景
- [ ] 说明列式存储的优势
- [ ] 创建一个 MergeTree 表并插入数据
- [ ] 解释分片和副本的区别
- [ ] 创建复制表并验证数据同步

## 下一步

完成本章后，继续学习：
- `01-base/` - 更深入的 SQL 操作和最佳实践
- `02-advance/` - 高级特性和优化技巧

## 常见问题

**Q: 为什么 ClickHouse 这么快？**
A: 列式存储 + 向量化执行 + 数据压缩 + 并行处理

**Q: ClickHouse 适合事务处理吗？**
A: 不适合。ClickHouse 是 OLAP 数据库，不适合高频事务(OLTP)场景

**Q: 为什么需要 Keeper？**
A: 用于协调复制表的元数据和选举，确保多个副本数据一致
