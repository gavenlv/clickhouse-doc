# ClickHouse Cluster Health Check - PowerShell Version

# 配置
$CH1_HTTP = "http://localhost:8123"
$CH2_HTTP = "http://localhost:8124"
$TOTAL_TESTS = 0
$PASSED_TESTS = 0
$FAILED_TESTS = 0

# 输出分隔线
function Print-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host "========================================"
    Write-Host $Title
    Write-Host "========================================"
}

# 测试结果
function Test-Result {
    param(
        [string]$TestName,
        [bool]$Result,
        [bool]$Expected
    )

    $script:TOTAL_TESTS++

    if ($Result -eq $Expected) {
        Write-Host "✓ $TestName" -ForegroundColor Green
        $script:PASSED_TESTS++
        return $true
    } else {
        Write-Host "✗ $TestName" -ForegroundColor Red
        Write-Host "  Expected: $Expected"
        Write-Host "  Got: $Result"
        $script:FAILED_TESTS++
        return $false
    }
}

# 1. 测试 ClickHouse 服务是否运行
Print-Section "1. 服务可用性测试"
try {
    $response1 = Invoke-WebRequest -Uri "$CH1_HTTP" -UseBasicParsing -TimeoutSec 5
    Test-Result "ClickHouse1 HTTP 服务" $true $true
} catch {
    Test-Result "ClickHouse1 HTTP 服务" $false $true
}

try {
    $response2 = Invoke-WebRequest -Uri "$CH2_HTTP" -UseBasicParsing -TimeoutSec 5
    Test-Result "ClickHouse2 HTTP 服务" $true $true
} catch {
    Test-Result "ClickHouse2 HTTP 服务" $false $true
}

# 2. 测试版本信息
Print-Section "2. 版本信息测试"
$VERSION1 = (Invoke-WebRequest -Uri "$CH1_HTTP/?query=SELECT%20version()" -UseBasicParsing).Content.Trim()
$VERSION2 = (Invoke-WebRequest -Uri "$CH2_HTTP/?query=SELECT%20version()" -UseBasicParsing).Content.Trim()

Write-Host "ClickHouse1 Version: $VERSION1"
Write-Host "ClickHouse2 Version: $VERSION2"

Test-Result "两个节点版本一致" ($VERSION1 -eq $VERSION2) $true

# 3. 测试 Keeper 连接
Print-Section "3. Keeper 连接测试"
try {
    $keeperNodes = (Invoke-WebRequest -Uri "$CH1_HTTP/?query=SELECT%20count()%20FROM%20system.zookeeper" -UseBasicParsing).Content.Trim()
    Write-Host "Keeper 节点路径数量: $keeperNodes"
    Test-Result "Keeper 连接正常" ($keeperNodes -gt 0) $true
} catch {
    Test-Result "Keeper 连接正常" $false $true
}

# 4. 测试集群配置
Print-Section "4. 集群配置测试"
try {
    $clusterInfo = (Invoke-WebRequest -Uri "$CH1_HTTP/?query=SELECT%20*%20FROM%20system.clusters%20WHERE%20cluster%20%3D%20'treasurycluster'" -UseBasicParsing).Content
    $clusterLines = $clusterInfo.Split("`n").Count
    Write-Host "集群配置行数: $clusterLines"
    Test-Result "集群配置正确" ($clusterLines -ge 2) $true
} catch {
    Test-Result "集群配置正确" $false $true
}

# 5. 测试 macros
Print-Section "5. Macros 配置测试"
try {
    $macros1 = (Invoke-WebRequest -Uri "$CH1_HTTP/?query=SELECT%20*%20FROM%20system.macros%20FORMAT%20TabSeparated" -UseBasicParsing).Content
    $macros2 = (Invoke-WebRequest -Uri "$CH2_HTTP/?query=SELECT%20*%20FROM%20system.macros%20FORMAT%20TabSeparated" -UseBasicParsing).Content

    $macrosCount1 = $macros1.Split("`n").Where{ $_ -ne "" }.Count
    $macrosCount2 = $macros2.Split("`n").Where{ $_ -ne "" }.Count

    Write-Host "ClickHouse1 Macros 数量: $macrosCount1"
    Write-Host "ClickHouse2 Macros 数量: $macrosCount2"
    Write-Host "ClickHouse1 Macros:"
    Write-Host $macros1
    Write-Host "ClickHouse2 Macros:"
    Write-Host $macros2

    Test-Result "ClickHouse1 有 5 个 macros" ($macrosCount1 -eq 5) $true
    Test-Result "ClickHouse2 有 5 个 macros" ($macrosCount2 -eq 5) $true
} catch {
    Test-Result "Macros 配置正确" $false $true
}

# 6. 测试复制表创建
Print-Section "6. 复制表创建测试"
$TABLE_EXISTS = $false

try {
    # 删除表（如果存在）
    Invoke-WebRequest -Uri "$CH1_HTTP/" -Method POST -Body "DROP TABLE IF EXISTS test_replication" -UseBasicParsing | Out-Null

    # 创建表（使用默认路径）
    $createQuery = "CREATE TABLE test_replication (id UInt64, data String, created_at DateTime DEFAULT now()) ENGINE = ReplicatedMergeTree ORDER BY id"
    $createBody = $createQuery
    $createResult = Invoke-WebRequest -Uri "$CH1_HTTP/" -Method POST -Body $createBody -UseBasicParsing

    if ($createResult.StatusCode -eq 200) {
        Write-Host "✓ 表创建成功"

        # 等待表在两个副本上出现
        Start-Sleep -Seconds 3

        $tableExists1 = (Invoke-WebRequest -Uri "$CH1_HTTP/?query=EXISTS%20test_replication" -UseBasicParsing).Content.Trim()
        $tableExists2 = (Invoke-WebRequest -Uri "$CH2_HTTP/?query=EXISTS%20test_replication" -UseBasicParsing).Content.Trim()

        Write-Host "表在 ClickHouse1 存在: $tableExists1"
        Write-Host "表在 ClickHouse2 存在: $tableExists2"

        Test-Result "表在第一个副本存在" ($tableExists1 -eq "1") $true
        Test-Result "表在第二个副本存在" ($tableExists2 -eq "1") $true

        if (($tableExists1 -eq "1") -and ($tableExists2 -eq "1")) {
            $TABLE_EXISTS = $true
        }
    } else {
        Write-Host "✗ 表创建失败，状态码: $($createResult.StatusCode)"
        Test-Result "表创建成功" $false $true
    }
} catch {
    Write-Host "✗ 表创建异常: $_"
    Test-Result "表创建成功" $false $true
}

# 7. 测试数据插入和复制
Print-Section "7. 数据插入和复制测试"
if ($TABLE_EXISTS) {
    try {
        # 插入测试数据
        $insertBody = "1`thello`t`n2`tworld`t`n3`tclickhouse"
        $insertResult = Invoke-WebRequest -Uri "$CH1_HTTP/" -Method POST -Body "INSERT INTO test_replication FORMAT TabSeparated" -UseBasicParsing

        if ($insertResult.StatusCode -eq 200) {
            Write-Host "✓ 数据插入成功"

            # 等待复制
            Start-Sleep -Seconds 2

            # 查询两个副本的数据
            $countQuery = "SELECT count() FROM test_replication"
            $response1 = Invoke-WebRequest -Uri "$CH1_HTTP/?query=$([System.Uri]::EscapeDataString($countQuery))" -UseBasicParsing
            $response2 = Invoke-WebRequest -Uri "$CH2_HTTP/?query=$([System.Uri]::EscapeDataString($countQuery))" -UseBasicParsing
            $count1 = $response1.Content.Trim()
            $count2 = $response2.Content.Trim()

            Write-Host "ClickHouse1 数据行数: $count1"
            Write-Host "ClickHouse2 数据行数: $count2"

            Test-Result "第一个副本数据正确" ($count1 -eq "3") $true
            Test-Result "第二个副本数据正确" ($count2 -eq "3") $true
            Test-Result "数据已复制到第二个副本" ($count2 -eq $count1) $true
        } else {
            Write-Host "✗ 数据插入失败"
            Test-Result "数据插入成功" $false $true
        }
    } catch {
        Write-Host "✗ 数据插入异常: $_"
        Test-Result "数据插入成功" $false $true
    }
}

# 8. 测试复制状态
Print-Section "8. 复制状态测试"
if ($TABLE_EXISTS) {
    try {
        $replicaStatus1 = (Invoke-WebRequest -Uri "$CH1_HTTP/?query=SELECT%20is_leader%2C%20replica_name%2C%20total_replicas%20FROM%20system.replicas%20WHERE%20table%20%3D%20'test_replication'%20FORMAT%20TabSeparated" -UseBasicParsing).Content
        $replicaStatus2 = (Invoke-WebRequest -Uri "$CH2_HTTP/?query=SELECT%20is_leader%2C%20replica_name%2C%20total_replicas%20FROM%20system.replicas%20WHERE%20table%20%3D%20'test_replication'%20FORMAT%20TabSeparated" -UseBasicParsing).Content

        Write-Host "ClickHouse1 复制状态:"
        Write-Host $replicaStatus1
        Write-Host ""
        Write-Host "ClickHouse2 复制状态:"
        Write-Host $replicaStatus2

        # 检查是否有 leader
        $hasLeader = $replicaStatus1.Contains("1") -or $replicaStatus2.Contains("1")
        Test-Result "存在一个 leader" $hasLeader $true
    } catch {
        Test-Result "复制状态检查" $false $true
    }
}

# 9. 测试 ZooKeeper 路径
Print-Section "9. ZooKeeper 路径测试"
if ($TABLE_EXISTS) {
    try {
        $zkPath = (Invoke-WebRequest -Uri "$CH1_HTTP/?query=SELECT%20zookeeper_path%20FROM%20system.replicas%20WHERE%20table%20%3D%20'test_replication'%20FORMAT%20TabSeparated" -UseBasicParsing).Content.Trim()

        Write-Host "ZooKeeper 路径: $zkPath"
        Write-Host "预期路径: /clickhouse/tables/1/test_replication"

        $expectedPath = "/clickhouse/tables/1/test_replication"
        Test-Result "ZooKeeper 路径使用默认配置" ($zkPath -eq $expectedPath) $true
    } catch {
        Test-Result "ZooKeeper 路径检查" $false $true
    }
}

# 10. 清理测试表
Print-Section "10. 清理测试数据"
try {
    $dropResult = Invoke-WebRequest -Uri "$CH1_HTTP/" -Method POST -Body "DROP TABLE IF EXISTS test_replication" -UseBasicParsing

    if ($dropResult.StatusCode -eq 200) {
        Write-Host "✓ 测试表清理成功"
    } else {
        Write-Host "✗ 测试表清理失败，状态码: $($dropResult.StatusCode)"
    }
} catch {
    Write-Host "✗ 测试表清理异常: $_"
}

# 输出总结
Print-Section "测试总结"
Write-Host "总测试数: $TOTAL_TESTS"
Write-Host "通过: $PASSED_TESTS" -ForegroundColor Green
Write-Host "失败: $FAILED_TESTS" -ForegroundColor Red

if ($FAILED_TESTS -eq 0) {
    Write-Host "✓ 所有测试通过！" -ForegroundColor Green
    exit 0
} else {
    Write-Host "✗ 有 $FAILED_TESTS 个测试失败" -ForegroundColor Red
    exit 1
}
