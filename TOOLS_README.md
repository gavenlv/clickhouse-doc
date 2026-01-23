# ClickHouse SQL 执行工具说明

## 📋 概述

本工具集用于：
1. 从 Markdown 文档中提取 SQL 语句
2. 批量执行 SQL 文件
3. 生成详细的执行报告

## 🚀 快速开始

### Windows 用户

双击运行：
```
run_tests.bat
```

### 命令行用户

```bash
# 提取所有 SQL
python extract_sql_from_md.py

# 运行所有测试
python run_all_batches.py

# 运行指定目录
python run_batch_sql.py <目录名>

# 示例
python run_batch_sql.py 05-data-type
python run_batch_sql.py 08-information-schema
```

## 📁 工具文件说明

| 文件 | 功能 |
|------|------|
| `extract_sql_from_md.py` | 从 Markdown 文件中提取 SQL 代码块 |
| `run_batch_sql.py` | 执行单个目录的 SQL 文件 |
| `run_all_batches.py` | 批量执行所有目录的 SQL 文件 |
| `run_tests.bat` | Windows 快速启动菜单 |
| `run_sql_files.py` | 原始 SQL 执行工具（已废弃） |

## 📂 目录结构

```
clickhouse-doc/
├── extract_sql_from_md.py      # SQL 提取工具
├── run_batch_sql.py           # 批量执行工具
├── run_all_batches.py         # 全部执行工具
├── run_tests.bat             # Windows 启动器
├── EXECUTION_SUMMARY.md       # 执行总结报告
│
├── 05-data-type/            # 数据类型示例
├── 07-troubleshooting/      # 故障排查
├── 08-information-schema/   # 信息模式
├── 09-data-deletion/       # 数据删除
├── 10-date-update/         # 日期时间
├── 11-data-update/         # 数据更新
├── 11-performance/         # 性能优化
├── 12-security-authentication/  # 安全认证
└── 13-monitor/             # 监控
    ├── *_examples.sql       # 从 MD 提取的 SQL 文件
    └── execution_report_*.json  # 执行报告（JSON）
```

## 📊 执行报告

每个目录执行后会生成 JSON 格式的报告：

```json
{
  "timestamp": "2026-01-23T14:43:06.641682",
  "directory": "12-security-authentication",
  "summary": {
    "total_files": 9,
    "total_statements": 447,
    "total_success": 374,
    "total_errors": 73
  },
  "results": {
    "目录\\文件名.sql": [
      {
        "statement": "SQL 语句内容",
        "success": true,
        "result": "执行结果"
      }
    ]
  }
}
```

## 🔧 配置

### ClickHouse 连接配置

在 `run_batch_sql.py` 中修改：

```python
CLICKHOUSE_HOST = "localhost"
CLICKHOUSE_PORT = 8123
CLICKHOUSE_USER = "default"
CLICKHOUSE_PASSWORD = ""
```

### 提取配置

在 `extract_sql_from_md.py` 中修改：

```python
PROJECT_ROOT = Path(r"d:\workspace\superset-github\clickhouse-doc")
TARGET_DIRS = [
    "05-data-type",
    "07-troubleshooting",
    # ... 添加更多目录
]
EXCLUDE_FILES = [
    "README.md",
    # ... 添加更多排除文件
]
```

## 📈 测试结果总结

最新测试结果（2026-01-23）：

| 指标 | 数值 |
|------|------|
| 总 SQL 文件 | 74 |
| 总 SQL 语句 | 2209 |
| 成功 | 2101 |
| 失败 | 108 |
| **成功率** | **95.1%** |

详细报告请查看：`EXECUTION_SUMMARY.md`

## 🐛 常见问题

### Q1: 提取的 SQL 文件为空

**原因**: MD 文件中没有 ` ```sql ... ```` 代码块

**解决**: 检查 MD 文件格式，确保 SQL 代码在正确的代码块中

### Q2: 执行时连接失败

**原因**: ClickHouse 服务未启动或配置错误

**解决**:
```bash
# 检查服务是否运行
curl http://localhost:8123/?query=SELECT%20version()

# 检查端口
netstat -ano | findstr :8123
```

### Q3: 很多 SQL 语句失败

**原因**: 依赖关系或版本不兼容

**解决**: 查看 `EXECUTION_SUMMARY.md` 中的失败原因分析

### Q4: 提取了非 SQL 内容

**原因**: MD 文件中的非 SQL 代码块被错误提取

**解决**: 工具已自动过滤，如仍有问题请检查 MD 文件

## 🔍 故障排查

### 查看详细日志

```bash
# 运行并保存输出
python run_batch_sql.py <目录名> > test.log 2>&1

# 查看日志
type test.log
```

### 检查特定错误

```bash
# 搜索报告中的失败语句
python -c "import json; data=json.load(open('目录/execution_report_*.json')); print([r for r in data['results'] if any(not s['success'] for s in r)])"
```

## 📝 注意事项

1. **执行顺序**: 某些 SQL 文件有依赖关系，建议按目录顺序执行
2. **版本兼容**: 某些语法需要特定 ClickHouse 版本
3. **权限要求**: 某些操作需要管理员权限
4. **数据清理**: 执行前确保测试数据库已清理

## 🚨 警告

- ⚠️ 执行删除操作前请确认
- ⚠️ 部分示例使用测试数据库，可能影响生产环境
- ⚠️ 安全认证相关的 SQL 仅用于示例，生产环境需修改

## 📞 获取帮助

如有问题，请查看：
- `EXECUTION_SUMMARY.md` - 执行总结
- `00-infra/SYSTEM_TABLE_ALTERNATIVES.md` - 系统表替代方案
- 各目录下的执行报告 JSON 文件

## 📄 相关文档

- `README.md` - 项目总体说明
- `TEST_GUIDE.md` - 测试指南
- `00-infra/SQL_EXECUTION_GUIDE.md` - SQL 执行详细指南

---

**最后更新**: 2026-01-23
