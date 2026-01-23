# ================================================
# ClickHouse SQL 文件执行脚本 (PowerShell)
# ================================================

$ErrorActionPreference = "Stop"

Write-Host "================================================" -ForegroundColor Cyan
Write-Host "ClickHouse SQL 文件扫描和执行工具" -ForegroundColor Cyan
Write-Host "================================================" -ForegroundColor Cyan
Write-Host ""

# 配置
$PROJECT_ROOT = "d:\workspace\superset-github\clickhouse-doc"
$PYTHON_SCRIPT = "$PROJECT_ROOT\00-infra\run_sql_files.py"

# 检查 Python
try {
    $pythonVersion = python --version 2>&1
    Write-Host "Python 版本: $pythonVersion" -ForegroundColor Green
} catch {
    Write-Host "错误: 未找到 Python，请先安装 Python 3.x" -ForegroundColor Red
    pause
    exit 1
}

# 检查 requests 模块
try {
    python -c "import requests" 2>&1 | Out-Null
    Write-Host "requests 模块: 已安装" -ForegroundColor Green
} catch {
    Write-Host "安装 requests 模块..." -ForegroundColor Yellow
    pip install requests
}

# 运行 Python 脚本
Write-Host ""
Write-Host "开始执行 SQL 文件..." -ForegroundColor Cyan
Write-Host ""
python $PYTHON_SCRIPT

Write-Host ""
Write-Host "执行完成！" -ForegroundColor Green
pause
