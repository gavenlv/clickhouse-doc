# ClickHouse SQL 提取和执行工具

本目录包含 ClickHouse SQL 文件提取和执行工具链。

## 📦 工具组件

### 1. SQL 提取工具

- **extract_sql_from_md.py** - 自动从 Markdown 文件提取 SQL
- **功能**：
  - 扫描所有目录的 .md 文件
  - 提取 ```sql ... ``` 代码块
  - 生成对应的 _examples.sql 文件
  - 自动跳过已提取的文件

### 2. SQL 执行工具

#### Python 版本（推荐）

- **run_sql_files.py** - Python 主执行脚本
- **功能**：
  - 扫描所有 SQL 文件
  - 逐个执行 SQL 语句
  - 自动修复常见问题
  - 生成 HTML 和 JSON 报告
  - 支持超时和重试

#### PowerShell 版本

- **run_sql_files.ps1** - PowerShell 启动脚本
- **run_all_sql.ps1** - PowerShell 批量执行脚本
- **功能**：
  - 测试 ClickHouse 连接
  - 执行指定目录的 SQL 文件
  - 显示实时进度
  - 汇总执行结果

### 3. 启动脚本

- **quick_start.bat** - Windows 快速启动菜单
- **run_sql_files.bat** - Python 脚本启动器

### 4. 文档

- **SQL_EXECUTION_GUIDE.md** - 完整使用指南
- **SYSTEM_TABLE_ALTERNATIVES.md** - 不可用系统表替代方案

## 🚀 快速开始

### 方式 1: 使用快速启动菜单

```bash
# 双击运行
quick_start.bat
```

然后选择：
- 选项 1: 从 Markdown 提取 SQL
- 选项 2: 执行 SQL（Python）
- 选项 3: 执行 SQL（PowerShell）
- 选项 4: 查看使用说明
- 选项 5: 查看执行报告

### 方式 2: 直接运行 Python 脚本

```bash
# 提取 SQL
python 00-infra\extract_sql_from_md.py

# 执行 SQL
python 00-infra\run_sql_files.py
```

### 方式 3: 使用 PowerShell

```powershell
# 运行启动脚本
.\run_sql_files.ps1

# 或运行批量测试
.\run_all_sql.ps1
```

## 📁 生成的文件

### SQL 文件

从 Markdown 提取的 SQL 文件：
- `09-data-deletion/01_partition_deletion_examples.sql`
- `09-data-deletion/02_ttl_deletion_examples.sql`
- `10-date-update/04_date_arithmetic_examples.sql`
- `11-performance/01_query_optimization_examples.sql`
- 更多...

### 执行报告

执行结果保存在 `execution_results/` 目录：
- `execution_report.html` - 可视化 HTML 报告
- `execution_report.json` - 机器可读 JSON 报告

## ⚙️ 配置

### Python 配置

编辑 `run_sql_files.py`：

```python
CLICKHOUSE_HOST = "localhost"
CLICKHOUSE_PORT = 8123
CLICKHOUSE_USER = "default"
CLICKHOUSE_PASSWORD = ""
CLICKHOUSE_CLUSTER = "treasurycluster"
```

### PowerShell 配置

编辑 `run_all_sql.ps1`：

```powershell
$CLICKHOUSE_HOST = "localhost"
$CLICKHOUSE_PORT = 8123
$CLICKHOUSE_USER = "default"
$CLICKHOUSE_PASSWORD = ""
$CLICKHOUSE_CLUSTER = "treasurycluster"

$SQL_DIRS = @(
    "01-base",
    "02-advance",
    # ... 更多目录
)
```

## 🔧 自动修复功能

工具会自动修复以下问题：

1. **system.ttl_tables** → 使用 SHOW CREATE TABLE
2. **system.asynchronous_metrics_log** → 使用 system.query_log
3. **system.zookeeper** → 使用 system.replicas
4. **列名修复**：rows_read → read_rows
5. **函数修复**：toEndOfMonth → addMonths
6. **设置移除**：access_management = 1

详见 `SYSTEM_TABLE_ALTERNATIVES.md`

## 📊 工作流程

```
┌─────────────────┐
│   .md 文件    │
│   (原始文档）   │
└────────┬────────┘
         │
         ▼
┌─────────────────────────────────┐
│   extract_sql_from_md.py      │
│   (提取 SQL 代码）            │
└────────┬────────────────────┘
         │
         ▼
┌─────────────────┐
│  *_examples.sql│
│   (SQL 文件）   │
└────────┬────────┘
         │
         ▼
┌─────────────────────────────────┐
│   run_sql_files.py           │
│   (执行 SQL 并修复）            │
└────────┬────────────────────┘
         │
         ▼
┌─────────────────────────────────┐
│   execution_results/          │
│   (HTML + JSON 报告）         │
└─────────────────────────────┘
```

## 💡 使用建议

### 1. 首次使用

1. 运行 `extract_sql_from_md.py` 提取所有 SQL
2. 检查生成的 SQL 文件是否正确
3. 运行 `run_sql_files.py` 执行测试
4. 查看执行报告，修复错误

### 2. 日常使用

1. 当有新的 Markdown 文档时，运行提取工具
2. 执行 SQL 文件测试
3. 将 SQL 文件纳入版本控制

### 3. CI/CD 集成

将执行流程集成到持续集成：
```yaml
- name: Extract SQL
  run: python 00-infra/extract_sql_from_md.py

- name: Test SQL
  run: python 00-infra/run_sql_files.py

- name: Upload Reports
  uses: actions/upload-artifact@v2
  with:
    path: 00-infra/execution_results/
```

## 🐛 故障排除

### 连接问题

- 检查 ClickHouse 是否运行
- 检查端口 8123 是否可访问
- 检查用户名和密码

### Python 问题

- 确保已安装 Python 3.x
- 安装依赖：`pip install requests`

### PowerShell 问题

- 确保允许运行脚本
- 使用：`Set-ExecutionPolicy RemoteSigned`

## 📚 相关文档

- `SQL_EXECUTION_GUIDE.md` - 详细使用指南
- `SYSTEM_TABLE_ALTERNATIVES.md` - 系统表替代方案
- 主项目 `README.md` - 项目概述
- `TEST_GUIDE.md` - 测试指南

## 📞 支持和反馈

遇到问题？
1. 查看执行报告中的详细错误
2. 参考 ClickHouse 官方文档
3. 检查 `SYSTEM_TABLE_ALTERNATIVES.md`
4. 提交 Issue 或 Pull Request

## 📝 版本历史

- **v1.0.0** (2026-01-23)
  - 初始版本
  - 支持 Markdown 到 SQL 提取
  - 支持 Python 和 PowerShell 执行
  - 自动修复常见问题
  - 生成 HTML 和 JSON 报告

## 👥 贡献

欢迎贡献！请：
1. Fork 项目
2. 创建功能分支
3. 提交更改
4. 创建 Pull Request

---

**最后更新**: 2026-01-23
**维护者**: ClickHouse 文档团队
