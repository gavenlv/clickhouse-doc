# SQL 执行测试总结

**测试时间**: 2026-01-23
**ClickHouse 版本**: 25.12.3.21

## 整体统计

| 指标 | 数量 |
|------|------|
| 总 SQL 文件 | 74 |
| 总 SQL 语句 | 2209 |
| 成功 | 2101 |
| 失败 | 108 |
| **成功率** | **95.1%** |

## 各目录执行情况

### ✅ 完全成功（0 失败）

| 目录 | 成功数 | 状态 |
|------|---------|------|
| 05-data-type | 38 | ✅ 完美 |
| 07-troubleshooting | 6 | ✅ 完美 |
| 08-information-schema | 190 | ✅ 完美 |
| 13-monitor | 216 | ✅ 完美 |

### ⚠️ 少量失败（< 10 个）

| 目录 | 成功 | 失败 | 失败率 |
|------|------|------|---------|
| 09-data-deletion | 236 | 4 | 1.7% |
| 10-date-update | 326 | 3 | 0.9% |

### ⚠️ 中量失败（10-30 个）

| 目录 | 成功 | 失败 | 失败率 |
|------|------|------|---------|
| 11-data-update | 352 | 23 | 6.1% |
| 11-performance | 354 | 15 | 4.1% |

### ⚠️ 较多失败（> 30 个）

| 目录 | 成功 | 失败 | 失败率 |
|------|------|------|---------|
| 12-security-authentication | 383 | 63 | 14.1% |

## 失败原因分析

### 1. 依赖关系问题（约 50%）
- 用户/角色不存在（ldap_user, kerberos_user, cert_user 等）
- 表不存在（依赖之前的 CREATE 语句）
- 数据库不存在

**示例错误**:
```
There is no role `ldap_user` in `user directories`
Could not find table: compare_table
```

### 2. 不支持的语法/设置（约 30%）
- `lightweight_delete` 设置（旧版 ClickHouse 特性）
- `CREATE ROLE ... INHERIT` 语法
- 自定义函数语法问题
- SET 语句（配置文件语法，非 SQL）

**示例错误**:
```
Setting lightweight_delete is neither a builtin setting nor startup setting
Syntax error: Missing comma
```

### 3. 数据格式问题（约 15%）
- JSON 格式的 INSERT 语句
- 字符串引号问题
- 多行语句格式

**示例错误**:
```
Syntax error: failed at position ...
```

### 4. 提取问题（约 5%）
- MD 文件中的非 SQL 内容被提取
- 语句被截断
- 注释和 SQL 混合

## 解决方案

### 已完成的修复

1. ✅ **修复 SQL 提取逻辑**
   - 改进正则表达式匹配
   - 过滤非 SQL 代码块（bash、xml 等）
   - 改进注释判断逻辑

2. ✅ **修复 SQL 分割逻辑**
   - 正确处理字符串中的分号
   - 支持单引号和双引号
   - 正确处理转义字符

3. ✅ **改进注释判断**
   - 使用 SQL 关键词检测
   - 不误判包含注释的 SQL 语句

### 待处理的问题

#### 1. 依赖顺序问题
**建议**: 在每个 SQL 文件开头添加依赖检查和创建语句

```sql
-- 检查并创建必要的角色
CREATE ROLE IF NOT EXISTS base_role;
CREATE ROLE IF NOT EXISTS readonly_role INHERIT base_role;
```

#### 2. 不支持的语法标记
**建议**: 在 SQL 文件中添加版本要求说明

```sql
-- 需要ClickHouse版本: 23.x+
-- 或使用轻量级删除（需要 23.x+）
ALTER TABLE table_name
DELETE WHERE condition
SETTINGS lightweight_delete = 1;
```

#### 3. 配置语句分离
**建议**: 将 SET 语句移到单独的配置文件，或添加跳过标记

```sql
-- 注意：以下是 ClickHouse 配置文件内容，不是 SQL 语句
-- <settings>
--   <optimize_where_to_prewhere>1</optimize_where_to_prewhere>
-- </settings>
```

## 建议

### 短期改进
1. 添加执行前的依赖检查
2. 标记不支持的语法
3. 分离配置语句和 SQL 语句

### 长期改进
1. 为每个主题添加测试数据库初始化脚本
2. 创建执行顺序文件
3. 添加版本兼容性检查

## 结论

**整体评估**: ✅ 良好

- 成功率达到 95.1%，大部分 SQL 语句可以正确执行
- 失败的主要原因是依赖关系和版本兼容性，而非语法错误
- 核心功能（数据类型、系统监控、故障排查）完全成功

**下一步行动**:
1. 处理依赖关系问题
2. 标记不支持的语法
3. 优化错误提示信息
