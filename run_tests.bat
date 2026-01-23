@echo off
chcp 65001 >nul
echo ========================================
echo ClickHouse SQL 测试工具
echo ========================================
echo.
echo 请选择操作：
echo   1. 提取所有 Markdown 中的 SQL
echo   2. 运行所有目录测试
echo   3. 运行指定目录测试
echo   4. 查看执行总结
echo   5. 退出
echo.
set /p choice=请输入选项 (1-5):

if "%choice%"=="1" goto extract
if "%choice%"=="2" goto run_all
if "%choice%"=="3" goto run_dir
if "%choice%"=="4" goto summary
if "%choice%"=="5" goto end

:extract
echo.
echo [1/2] 提取 SQL...
python extract_sql_from_md.py
echo.
echo [2/2] 运行测试...
python run_all_batches.py
goto end

:run_all
echo.
echo 运行所有目录测试...
python run_all_batches.py
goto end

:run_dir
echo.
echo 可用目录：
echo   05-data-type
echo   07-troubleshooting
echo   08-information-schema
echo   09-data-deletion
echo   10-date-update
echo   11-data-update
echo   11-performance
echo   12-security-authentication
echo   13-monitor
echo.
set /p dirname=请输入目录名：
if "%dirname%"=="" goto end
echo.
echo 运行目录: %dirname%
python run_batch_sql.py %dirname%
goto end

:summary
echo.
echo ========================================
echo 打开执行总结
echo ========================================
start EXECUTION_SUMMARY.md
goto end

:end
echo.
echo 按任意键退出...
pause >nul
