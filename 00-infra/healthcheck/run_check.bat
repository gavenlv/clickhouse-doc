@echo off
REM ClickHouse Cluster Health Check - Windows Batch
REM Runs the English version of health check script

echo ========================================
echo ClickHouse Cluster Health Check
echo ========================================
echo.

cd /d "%~dp0"

echo Running PowerShell health check...
powershell -ExecutionPolicy Bypass -File check.ps1

echo.
pause
