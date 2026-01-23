@echo off
REM ================================================
REM ClickHouse SQL 文件执行脚本 (Windows)
REM ================================================

echo ================================================
echo ClickHouse SQL 文件扫描和执行工具
echo ================================================
echo.

REM 设置配置
set PROJECT_ROOT=d:\workspace\superset-github\clickhouse-doc
set CLICKHOUSE_HOST=localhost
set CLICKHOUSE_PORT=8123

REM 检查 Python 是否安装
python --version >nul 2>&1
if %errorlevel% neq 0 (
    echo 错误: 未找到 Python，请先安装 Python 3.x
    pause
    exit /b 1
)

REM 检查 requests 模块
python -c "import requests" >nul 2>&1
if %errorlevel% neq 0 (
    echo 安装 requests 模块...
    pip install requests
)

REM 运行 Python 脚本
python "%PROJECT_ROOT%\00-infra\run_sql_files.py"

pause
