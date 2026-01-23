@echo off
REM ================================================
REM ClickHouse SQL 工具快速启动
REM ================================================

:MENU
cls
echo ================================================
echo ClickHouse SQL 提取和执行工具
echo ================================================
echo.
echo 请选择操作：
echo.
echo   1. 从 Markdown 提取 SQL（自动）
echo   2. 执行所有 SQL 文件（Python）
echo   3. 执行所有 SQL 文件（PowerShell）
echo   4. 查看使用说明
echo   5. 查看执行报告
echo   0. 退出
echo.
set /p choice="请输入选项 (0-5): "

if "%choice%"=="1" goto EXTRACT
if "%choice%"=="2" goto RUN_PYTHON
if "%choice%"=="3" goto RUN_POWERSHELL
if "%choice%"=="4" goto GUIDE
if "%choice%"=="5" goto REPORT
if "%choice%"=="0" goto END

:EXTRACT
cls
echo ================================================
echo 从 Markdown 提取 SQL
echo ================================================
echo.
python d:\workspace\superset-github\clickhouse-doc\00-infra\extract_sql_from_md.py
echo.
echo 按任意键返回菜单...
pause >nul
goto MENU

:RUN_PYTHON
cls
echo ================================================
echo 执行所有 SQL 文件（Python）
echo ================================================
echo.
python d:\workspace\superset-github\clickhouse-doc\00-infra\run_sql_files.py
echo.
echo 按任意键返回菜单...
pause >nul
goto MENU

:RUN_POWERSHELL
cls
echo ================================================
echo 执行所有 SQL 文件（PowerShell）
echo ================================================
echo.
powershell -ExecutionPolicy Bypass -File d:\workspace\superset-github\clickhouse-doc\00-infra\run_all_sql.ps1
echo.
echo 按任意键返回菜单...
pause >nul
goto MENU

:GUIDE
cls
echo ================================================
echo 使用说明
echo ================================================
echo.
echo 详细使用说明请查看文档：
echo d:\workspace\superset-github\clickhouse-doc\00-infra\SQL_EXECUTION_GUIDE.md
echo.
echo 按任意键返回菜单...
pause >nul
goto MENU

:REPORT
cls
echo ================================================
echo 执行报告
echo ================================================
echo.
set REPORT_DIR=d:\workspace\superset-github\clickhouse-doc\00-infra\execution_results

if exist "%REPORT_DIR%\execution_report.html" (
    echo 打开 HTML 报告...
    start "" "%REPORT_DIR%\execution_report.html"
) else (
    echo 报告不存在，请先执行 SQL 文件
)

if exist "%REPORT_DIR%\execution_report.json" (
    echo.
    echo JSON 报告位置：%REPORT_DIR%\execution_report.json
)

echo.
echo 按任意键返回菜单...
pause >nul
goto MENU

:END
exit
