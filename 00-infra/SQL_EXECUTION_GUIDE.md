# SQL 文件提取和执行工具使用指南

## 📋 概述

本工具链提供以下功能：
1. **手动提取**：从 Markdown 文件中提取 SQL 到单独的 SQL 文件
2. **批量执行**：运行所有 SQL 文件并记录结果
3. **自动修复**：自动修复常见的 SQL 问题
4. **生成报告**：生成 HTML 和 JSON 格式的执行报告

## 🚀 快速开始

### 方式 1: 使用 Python 脚本（推荐）

```bash
# Windows
cd d:\workspace\superset-github\clickhouse-doc
00-infra\run_sql_files.bat

# 或手动运行
python 00-infra\run_sql_files.py
```

### 方式 2: 使用 PowerShell 脚本

```powershell
# 运行主脚本
cd d:\workspace\superset-github\clickhouse-doc
.\00-infra\run_sql_files.ps1

# 或运行批量测试脚本
.\00-infra\run_all_sql.ps1
```

## 📁 目录结构

```
clickhouse-doc/
├── 00-infra/
│   ├── run_sql_files.py          # Python 主脚本
│   ├── run_sql_files.bat         # Windows 批处理启动脚本
│   ├── run_sql_files.ps1        # PowerShell 启动脚本
│   ├── run_all_sql.ps1          # PowerShell 批量测试脚本
│   ├── execution_results/         # 执行结果目录（自动创建）
│   │   ├── execution_report.html  # HTML 格式报告
│   │   └── execution_report.json # JSON 格式报告
│   └── SYSTEM_TABLE_ALTERNATIVES.md  # 不可用表替代方案
├── 01-base/                    # SQL 文件目录
│   ├── *.sql                    # 原有的 SQL 文件
│   └── ...
├── 09-data-deletion/
│   ├── 01_partition_deletion_examples.sql   # 新提取的 SQL
│   ├── 02_ttl_deletion_examples.sql
│   └── ...
├── 10-date-update/
│   ├── 04_date_arithmetic_examples.sql
│   └── ...
└── 11-performance/
    └── 01_query_optimization_examples.sql
```

## 🔧 配置说明

### Python 脚本配置

编辑 `00-infra/run_sql_files.py` 中的配置：

```python
# 配置
PROJECT_ROOT = Path(r"d:\workspace\superset-github\clickhouse-doc")
CLICKHOUSE_HOST = "localhost"
CLICKHOUSE_PORT = 8123
CLICKHOUSE_USER = "default"
CLICKHOUSE_PASSWORD = ""
CLICKHOUSE_CLUSTER = "treasurycluster"
```

### PowerShell 脚本配置

编辑 `00-infra/run_all_sql.ps1` 中的配置：

```powershell
# 配置
$CLICKHOUSE_HOST = "localhost"
$CLICKHOUSE_PORT = 8123
$CLICKHOUSE_USER = "default"
$CLICKHOUSE_PASSWORD = ""
$CLICKHOUSE_CLUSTER = "treasurycluster"

$SQL_DIRS = @(
    "01-base",
    "02-advance",
    "09-data-deletion",
    "10-date-update",
    "11-data-update",
    "13-monitor",
    "12-security-authentication"
)
```

## 📝 已提取的 SQL 文件

### 09-data-deletion 目录
- `01_partition_deletion_examples.sql` - 从 01_partition_deletion.md 提取
- `02_ttl_deletion_examples.sql` - 从 02_ttl_deletion.md 提取

### 10-date-update 目录
- `02_date_time_functions_examples.sql` - 从 02_date_time_functions.md 提取（需要创建）
- `04_date_arithmetic_examples.sql` - 从 04_date_arithmetic.md 提取

### 11-performance 目录
- `01_query_optimization_examples.sql` - 从 01_query_optimization.md 提取

### 其他目录
- 更多目录的 SQL 文件需要手动或自动提取

## 🛠️ 手动提取 SQL

如果需要从新的 Markdown 文件提取 SQL：

1. 阅读 Markdown 文件
2. 找到所有 ```sql ... ``` 代码块
3. 将 SQL 代码复制到新的 .sql 文件
4. 将文件保存到对应目录

### 命名规范

建议使用以下命名规范：
- 原文件名 + `_examples.sql`
- 例如：`01_partition_deletion.md` → `01_partition_deletion_examples.sql`

## 🔍 SQL 自动修复

工具会自动修复以下问题：

### 1. 系统表替换

```sql
-- ❌ 不可用
FROM system.ttl_tables WHERE ...

-- ✅ 修复后
SHOW CREATE TABLE your_table;

-- 或
-- 注意：system.ttl_tables 不可用，已注释
```

### 2. 列名修复

```sql
-- ❌ 旧版本列名
SELECT rows_read, bytes_read FROM system.processes

-- ✅ 修复后
SELECT read_rows, read_bytes FROM system.processes
```

### 3. 函数替换

```sql
-- ❌ 不支持的函数
toEndOfMonth(now())

-- ✅ 修复后
addMonths(toStartOfMonth(now()), 1)
```

### 4. 设置参数移除

```sql
-- ❌ 不支持的设置
SETTINGS access_management = 1

-- ✅ 修复后
-- 移除此设置
```

## 📊 查看执行报告

执行完成后，会在 `00-infra/execution_results/` 目录生成报告：

### HTML 报告

打开 `execution_report.html` 查看可视化报告：

- 文件级别统计
- 语句级别详细结果
- 成功/失败状态
- 错误信息

### JSON 报告

`execution_report.json` 包含结构化数据，可用于：
- CI/CD 集成
- 自动化测试
- 数据分析

## ⚡ 性能优化建议

### 执行速度优化

1. **使用 Python 脚本**：比 PowerShell 快 2-3 倍
2. **限制并发**：调整 `max_concurrent_queries` 设置
3. **批量执行**：一次性执行整个文件而不是逐条执行

### 内存使用优化

1. **分批执行**：对于大型 SQL 文件，分批执行
2. **清理日志**：定期清理 `system.query_log`
3. **调整超时**：增加 `query_timeout_ms` 设置

## 🐛 故障排除

### 连接失败

```bash
错误: Connection failed

解决方案：
1. 检查 ClickHouse 是否运行
2. 检查端口是否正确（默认 8123）
3. 检查防火墙设置
4. 检查用户权限
```

### 模块缺失

```bash
ModuleNotFoundError: No module named 'requests'

解决方案：
pip install requests
```

### 编码错误

```bash
UnicodeDecodeError

解决方案：
1. 确保 SQL 文件使用 UTF-8 编码
2. 在脚本中设置正确的编码
```

## 🔄 持续集成

### GitHub Actions 示例

```yaml
name: Test ClickHouse SQL

on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v2
      
      - name: Start ClickHouse
        run: |
          docker run -d --name clickhouse \
            -p 8123:8123 \
            clickhouse/clickhouse-server
      
      - name: Wait for ClickHouse
        run: sleep 30
      
      - name: Run SQL files
        run: |
          pip install requests
          python 00-infra/run_sql_files.py
      
      - name: Upload report
        uses: actions/upload-artifact@v2
        with:
          name: execution-report
          path: 00-infra/execution_results/
```

## 📚 相关文档

- `SYSTEM_TABLE_ALTERNATIVES.md` - 不可用系统表的替代方案
- `TEST_GUIDE.md` - 测试指南
- `QUICK_TEST_REF.md` - 快速测试参考

## 💡 最佳实践

1. **先测试后部署**：在测试环境先运行 SQL
2. **版本控制**：将 SQL 文件纳入版本控制
3. **定期更新**：定期提取新文档中的 SQL
4. **文档同步**：保持 SQL 文件和 Markdown 文档同步
5. **错误追踪**：记录所有错误并修复

## 🎯 下一步

1. **提取所有目录的 SQL**：完成所有 Markdown 文件的 SQL 提取
2. **编写单元测试**：为关键 SQL 编写测试
3. **性能基准测试**：建立查询性能基线
4. **自动化流程**：将执行流程集成到 CI/CD

## 📞 支持和反馈

如有问题或建议，请：
1. 检查执行报告中的详细错误信息
2. 参考 ClickHouse 官方文档
3. 查看系统表替代方案文档
4. 记录错误并提交 Issue

---

**最后更新**: 2026-01-23
**版本**: 1.0.0
