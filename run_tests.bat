@echo off
REM ================================================
REM run_tests.bat
REM ClickHouse 综合测试脚本 (Windows)
REM ================================================

setlocal enabledelayedexpansion

REM 颜色定义（使用 ANSI 转义码，Windows 10+ 支持）
set "INFO=[INFO]"
set "SUCCESS=[SUCCESS]"
set "WARNING=[WARNING]"
set "ERROR=[ERROR]"

REM 打印信息
:print_info
echo %INFO% %~1
goto :eof

:print_success
echo %SUCCESS% %~1
goto :eof

:print_warning
echo %WARNING% %~1
goto :eof

:print_error
echo %ERROR% %~1
goto :eof

REM 检查 Docker 是否运行
:check_docker
call :print_info "检查 Docker 运行状态..."
docker ps >nul 2>&1
if %errorlevel% neq 0 (
    call :print_error "Docker 未运行，请先启动 Docker"
    exit /b 1
)
call :print_success "Docker 运行正常"
goto :eof

REM 检查 ClickHouse 集群是否启动
:check_cluster
call :print_info "检查 ClickHouse 集群状态..."
docker ps | findstr /C:"clickhouse1" >nul
if %errorlevel% neq 0 (
    call :print_error "ClickHouse 集群未启动，请先运行: cd 00-infra ^&^& docker compose up -d"
    exit /b 1
)
call :print_success "ClickHouse 集群运行正常"
goto :eof

REM 检查测试数据库是否存在
:check_test_databases
call :print_info "检查测试数据库..."
docker exec -it clickhouse1 clickhouse-client --query "SELECT count() FROM system.databases WHERE name LIKE 'test_%%'" --format=TSV 2>nul > temp_result.txt
set /p result=<temp_result.txt
del temp_result.txt

if !result! gtr 0 (
    call :print_warning "发现测试数据库，是否要清理？(y/n)"
    set /p response=
    if /i "!response!"=="y" (
        call :print_info "清理测试数据库..."
        docker exec -it clickhouse1 clickhouse-client --query "DROP DATABASE IF EXISTS test_info_schema ON CLUSTER 'treasurycluster' SYNC; DROP DATABASE IF EXISTS test_data_deletion ON CLUSTER 'treasurycluster' SYNC; DROP DATABASE IF EXISTS test_date_time ON CLUSTER 'treasurycluster' SYNC;"
        call :print_success "测试数据库已清理"
    )
)
goto :eof

REM 运行完整测试
:run_full_test
call :print_info "运行完整测试..."
docker exec -it clickhouse1 clickhouse-client --queries-file /var/lib/clickhouse/user_files/test_all_topics.sql
call :print_success "完整测试完成"
goto :eof

REM 显示测试结果
:show_test_results
call :print_info "测试结果统计"
echo.
docker exec -it clickhouse1 clickhouse-client --query "SELECT database, table, engine, total_rows, formatReadableSize(total_bytes) as size FROM system.tables WHERE database LIKE 'test_%%' ORDER BY database, table" --format Pretty
echo.
goto :eof

REM 显示分区信息
:show_partitions
call :print_info "分区信息"
echo.
docker exec -it clickhouse1 clickhouse-client --query "SELECT database, table, partition, sum(rows) as rows, formatReadableSize(sum(bytes_on_disk)) as size FROM system.parts WHERE database LIKE 'test_%%' AND active = 1 GROUP BY database, table, partition ORDER BY database, table, partition" --format Pretty
echo.
goto :eof

REM 显示副本状态
:show_replicas
call :print_info "副本状态"
echo.
docker exec -it clickhouse1 clickhouse-client --query "SELECT database, table, is_leader, can_become_leader, queue_size, absolute_delay FROM system.replicas WHERE database LIKE 'test_%%' ORDER BY database, table" --format Pretty
echo.
goto :eof

REM 清理测试数据
:cleanup_tests
call :print_info "清理测试数据..."
docker exec -it clickhouse1 clickhouse-client --query "DROP DATABASE IF EXISTS test_info_schema ON CLUSTER 'treasurycluster' SYNC; DROP DATABASE IF EXISTS test_data_deletion ON CLUSTER 'treasurycluster' SYNC; DROP DATABASE IF EXISTS test_date_time ON CLUSTER 'treasurycluster' SYNC;"
call :print_success "测试数据已清理"
goto :eof

REM 显示帮助信息
:show_help
echo ClickHouse 综合测试脚本 (Windows)
echo.
echo 用法: run_tests.bat [选项]
echo.
echo 选项:
echo     -h, --help              显示帮助信息
echo     -a, --all               运行完整测试
echo     -r, --results           显示测试结果
echo     -p, --partitions        显示分区信息
echo     -R, --replicas          显示副本状态
echo     -c, --cleanup           清理测试数据
echo.
echo 示例:
echo     run_tests.bat --all                    # 运行完整测试
echo     run_tests.bat --results                # 显示测试结果
echo     run_tests.bat --cleanup                # 清理测试数据
echo.
echo 详细文档请查看: TEST_GUIDE.md
goto :eof

REM 主函数
:main
if "%~1"=="" (
    call :show_help
    exit /b 0
)

REM 解析参数
:parse_args
if "%~1"=="" goto :end_parse

if /i "%~1"=="-h" goto :help
if /i "%~1"=="--help" goto :help

if /i "%~1"=="-a" goto :all
if /i "%~1"=="--all" goto :all

if /i "%~1"=="-r" goto :results
if /i "%~1"=="--results" goto :results

if /i "%~1"=="-p" goto :partitions
if /i "%~1"=="--partitions" goto :partitions

if /i "%~1"=="-R" goto :replicas
if /i "%~1"=="--replicas" goto :replicas

if /i "%~1"=="-c" goto :cleanup
if /i "%~1"=="--cleanup" goto :cleanup

echo %ERROR% 未知选项: %~1
call :show_help
exit /b 1

:help
call :show_help
exit /b 0

:all
call :check_docker
if %errorlevel% neq 0 exit /b 1
call :check_cluster
if %errorlevel% neq 0 exit /b 1
call :check_test_databases
call :run_full_test
call :show_test_results
shift
goto :parse_args

:results
call :check_docker
if %errorlevel% neq 0 exit /b 1
call :check_cluster
if %errorlevel% neq 0 exit /b 1
call :show_test_results
shift
goto :parse_args

:partitions
call :check_docker
if %errorlevel% neq 0 exit /b 1
call :check_cluster
if %errorlevel% neq 0 exit /b 1
call :show_partitions
shift
goto :parse_args

:replicas
call :check_docker
if %errorlevel% neq 0 exit /b 1
call :check_cluster
if %errorlevel% neq 0 exit /b 1
call :show_replicas
shift
goto :parse_args

:cleanup
call :check_docker
if %errorlevel% neq 0 exit /b 1
call :check_cluster
if %errorlevel% neq 0 exit /b 1
call :cleanup_tests
shift
goto :parse_args

:end_parse
exit /b 0

REM 运行主函数
call :main %*
