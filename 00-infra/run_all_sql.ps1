# ================================================
# ClickHouse SQL 批量测试脚本
# ================================================

$ErrorActionPreference = "Stop"

# 配置
$CLICKHOUSE_HOST = "localhost"
$CLICKHOUSE_PORT = 8123
$CLICKHOUSE_USER = "default"
$CLICKHOUSE_PASSWORD = ""
$CLICKHOUSE_CLUSTER = "treasurycluster"

$PROJECT_ROOT = "d:\workspace\superset-github\clickhouse-doc"
$SQL_DIRS = @(
    "01-base",
    "02-advance",
    "09-data-deletion",
    "10-date-update",
    "11-data-update",
    "13-monitor",
    "12-security-authentication"
)

# 辅助函数：执行 SQL 查询
function Invoke-ClickHouse {
    param(
        [string]$Query,
        [string]$Database = "default",
        [string]$Cluster = $null
    )
    
    # 清理查询
    $Query = $Query.Trim()
    if (-not $Query -or $Query.StartsWith("--") -or $Query.StartsWith("/*")) {
        return
    }
    
    # 构建请求参数
    $params = @{
        "query" = $Query
        "database" = $Database
    }
    
    if ($Cluster) {
        $params["cluster"] = $Cluster
    }
    
    if ($CLICKHOUSE_USER) {
        $params["user"] = $CLICKHOUSE_USER
    }
    
    if ($CLICKHOUSE_PASSWORD) {
        $params["password"] = $CLICKHOUSE_PASSWORD
    }
    
    try {
        $url = "http://${CLICKHOUSE_HOST}:${CLICKHOUSE_PORT}/"
        $response = Invoke-RestMethod -Uri $url -Method Post -Body $params -TimeoutSec 300 -ErrorAction Stop
        
        if ($response -is [string]) {
            return @{ Success = $true; Result = $response.Trim() }
        } else {
            return @{ Success = $true; Result = $response | ConvertTo-Json -Compress }
        }
    }
    catch {
        return @{ Success = $false; Result = $_.Exception.Message }
    }
}

# 辅助函数：分割 SQL 语句
function Split-SqlStatements {
    param([string]$Content)
    
    $statements = @()
    $buffer = New-Object System.Text.StringBuilder
    $inString = $false
    
    foreach ($char in $Content.ToCharArray()) {
        if ($char -eq "'" -and -not $inString) {
            $inString = $true
        } elseif ($char -eq "'" -and $inString) {
            $inString = $false
        }
        
        if ($char -eq ';' -and -not $inString) {
            $stmt = $buffer.ToString().Trim()
            if ($stmt) {
                $statements += $stmt
            }
            $buffer.Clear()
        } else {
            $buffer.Append($char) | Out-Null
        }
    }
    
    # 处理最后一个语句
    $stmt = $buffer.ToString().Trim()
    if ($stmt) {
        $statements += $stmt
    }
    
    return $statements
}

# 主函数：执行所有 SQL 文件
function Test-SqlFiles {
    param([string]$Directory)
    
    Write-Host ""
    Write-Host "================================================" -ForegroundColor Cyan
    Write-Host "测试目录: $Directory" -ForegroundColor Cyan
    Write-Host "================================================" -ForegroundColor Cyan
    
    $sqlFiles = Get-ChildItem -Path "$PROJECT_ROOT\$Directory" -Filter "*.sql" -File | Sort-Object Name
    
    if ($sqlFiles.Count -eq 0) {
        Write-Host "未找到 SQL 文件" -ForegroundColor Yellow
        return
    }
    
    Write-Host "找到 $($sqlFiles.Count) 个 SQL 文件`n" -ForegroundColor Green
    
    $totalStatements = 0
    $totalSuccess = 0
    $totalErrors = 0
    $fileResults = @{}
    
    foreach ($file in $sqlFiles) {
        Write-Host "`n`n----------------------------------------" -ForegroundColor Gray
        Write-Host "文件: $($file.Name)" -ForegroundColor White
        Write-Host "----------------------------------------" -ForegroundColor Gray
        
        $content = Get-Content $file.FullName -Raw -Encoding UTF8
        $statements = Split-SqlStatements $content
        
        $fileSuccess = 0
        $fileErrors = 0
        $fileStmtResults = @()
        
        Write-Host "找到 $($statements.Count) 个 SQL 语句`n" -ForegroundColor Cyan
        
        for ($i = 0; $i -lt $statements.Count; $i++) {
            $stmt = $statements[$i].Trim()
            
            if (-not $stmt -or $stmt.StartsWith("--")) {
                continue
            }
            
            Write-Host "[$($i + 1)/$($statements.Count)] 执行: $($stmt.Substring(0, [Math]::Min(80, $stmt.Length)))..." -ForegroundColor Gray
            
            # 确定数据库和集群
            $database = "default"
            $cluster = $null
            
            if ($stmt -match "CREATE\s+DATABASE") {
                if ($stmt -match "CREATE\s+DATABASE\s+IF\s+NOT\s+EXISTS\s+(\w+)") {
                    $database = $matches[1]
                }
            }
            
            if ($stmt -match "ON\s+CLUSTER") {
                if ($stmt -match "ON\s+CLUSTER\s+['\""]?(\w+)['\""]?") {
                    $cluster = $matches[1]
                }
            }
            
            # 执行查询
            $result = Invoke-ClickHouse -Query $stmt -Database $database -Cluster $cluster
            
            $totalStatements++
            
            if ($result.Success) {
                $fileSuccess++
                $totalSuccess++
                Write-Host "  ✓ 成功" -ForegroundColor Green
                if ($result.Result -and $result.Result.Length -lt 500) {
                    Write-Host "  结果: $($result.Result)" -ForegroundColor DarkGreen
                }
            } else {
                $fileErrors++
                $totalErrors++
                Write-Host "  ✗ 失败: $($result.Result)" -ForegroundColor Red
            }
            
            $fileStmtResults += @{
                Statement = $stmt.Substring(0, [Math]::Min(200, $stmt.Length))
                Success = $result.Success
                Result = $result.Result
            }
            
            Start-Sleep -Milliseconds 50
        }
        
        $fileResults[$file.Name] = @{
            Success = $fileSuccess
            Errors = $fileErrors
            Results = $fileStmtResults
        }
        
        Write-Host "`n文件结果: $fileSuccess/$($statements.Count) 成功, $fileErrors 失败" -ForegroundColor Cyan
    }
    
    # 返回结果
    return @{
        TotalFiles = $sqlFiles.Count
        TotalStatements = $totalStatements
        TotalSuccess = $totalSuccess
        TotalErrors = $totalErrors
        FileResults = $fileResults
    }
}

# 主流程
Write-Host ""
Write-Host "测试 ClickHouse 连接..." -ForegroundColor Cyan

$testResult = Invoke-ClickHouse -Query "SELECT version()"
if ($testResult.Success) {
    Write-Host "✓ 连接成功: ClickHouse $($testResult.Result)" -ForegroundColor Green
} else {
    Write-Host "✗ 连接失败: $($testResult.Result)" -ForegroundColor Red
    pause
    exit 1
}

# 执行所有目录
$allResults = @{}
$grandTotalFiles = 0
$grandTotalStatements = 0
$grandTotalSuccess = 0
$grandTotalErrors = 0

foreach ($dir in $SQL_DIRS) {
    $dirPath = Join-Path $PROJECT_ROOT $dir
    if (-not (Test-Path $dirPath)) {
        Write-Host "目录不存在: $dir" -ForegroundColor Yellow
        continue
    }
    
    $result = Test-SqlFiles -Directory $dir
    $allResults[$dir] = $result
    
    $grandTotalFiles += $result.TotalFiles
    $grandTotalStatements += $result.TotalStatements
    $grandTotalSuccess += $result.TotalSuccess
    $grandTotalErrors += $result.TotalErrors
}

# 显示总结
Write-Host ""
Write-Host "================================================" -ForegroundColor Cyan
Write-Host "执行总结" -ForegroundColor Cyan
Write-Host "================================================" -ForegroundColor Cyan
Write-Host "目录总数: $($SQL_DIRS.Count)" -ForegroundColor White
Write-Host "文件总数: $grandTotalFiles" -ForegroundColor White
Write-Host "语句总数: $grandTotalStatements" -ForegroundColor White
Write-Host "成功: $grandTotalSuccess" -ForegroundColor Green
Write-Host "失败: $grandTotalErrors" -ForegroundColor Red

if ($grandTotalErrors -gt 0) {
    Write-Host "`n⚠️  有 $grandTotalErrors 个语句执行失败" -ForegroundColor Yellow
} else {
    Write-Host "`n✓ 所有语句执行成功！" -ForegroundColor Green
}

Write-Host ""
pause
