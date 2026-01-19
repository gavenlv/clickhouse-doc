# ClickHouse Cluster Health Check - PowerShell Version
# English version to avoid encoding issues

# Config
$CH1_HTTP = "http://localhost:8123"
$CH2_HTTP = "http://localhost:8124"
$TOTAL_TESTS = 0
$PASSED_TESTS = 0
$FAILED_TESTS = 0

# Output section
function Print-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host "========================================"
    Write-Host $Title
    Write-Host "========================================"
}

# Test result
function Test-Result {
    param(
        [string]$TestName,
        [bool]$Result,
        [bool]$Expected
    )

    $script:TOTAL_TESTS++

    if ($Result -eq $Expected) {
        Write-Host "OK $TestName" -ForegroundColor Green
        $script:PASSED_TESTS++
        return $true
    } else {
        Write-Host "FAIL $TestName" -ForegroundColor Red
        Write-Host "  Expected: $Expected"
        Write-Host "  Got: $Result"
        $script:FAILED_TESTS++
        return $false
    }
}

# 1. Test ClickHouse service
Print-Section "1. Service Availability Test"
try {
    $response1 = Invoke-WebRequest -Uri $CH1_HTTP -UseBasicParsing -TimeoutSec 5
    Test-Result "ClickHouse1 HTTP service" $true $true
} catch {
    Test-Result "ClickHouse1 HTTP service" $false $true
}

try {
    $response2 = Invoke-WebRequest -Uri $CH2_HTTP -UseBasicParsing -TimeoutSec 5
    Test-Result "ClickHouse2 HTTP service" $true $true
} catch {
    Test-Result "ClickHouse2 HTTP service" $false $true
}

# 2. Test version
Print-Section "2. Version Test"
try {
    $VERSION1 = (Invoke-WebRequest -Uri "$CH1_HTTP/?query=SELECT version()" -UseBasicParsing).Content.Trim()
    $VERSION2 = (Invoke-WebRequest -Uri "$CH2_HTTP/?query=SELECT version()" -UseBasicParsing).Content.Trim()

    Write-Host "ClickHouse1 Version: $VERSION1"
    Write-Host "ClickHouse2 Version: $VERSION2"

    Test-Result "Both nodes have same version" ($VERSION1 -eq $VERSION2) $true
} catch {
    Test-Result "Version check" $false $true
}

# 3. Test Keeper connection
Print-Section "3. Keeper Connection Test"
try {
    $keeperNodes = (Invoke-WebRequest -Uri "$CH1_HTTP/?query=SELECT count() FROM system.zookeeper" -UseBasicParsing).Content.Trim()
    Write-Host "Keeper node path count: $keeperNodes"
    Test-Result "Keeper connection OK" ($keeperNodes -gt 0) $true
} catch {
    Test-Result "Keeper connection OK" $false $true
}

# 4. Test cluster config
Print-Section "4. Cluster Config Test"
try {
    $clusterInfo = (Invoke-WebRequest -Uri "$CH1_HTTP/?query=SELECT * FROM system.clusters" -UseBasicParsing).Content
    Test-Result "Cluster config OK" ($clusterInfo.Length -gt 0) $true
} catch {
    Test-Result "Cluster config OK" $false $true
}

# 5. Test macros
Print-Section "5. Macros Config Test"
try {
    $macros1 = (Invoke-WebRequest -Uri "$CH1_HTTP/?query=SELECT * FROM system.macros FORMAT TabSeparated" -UseBasicParsing).Content
    $macros2 = (Invoke-WebRequest -Uri "$CH2_HTTP/?query=SELECT * FROM system.macros FORMAT TabSeparated" -UseBasicParsing).Content

    $macrosCount1 = ($macros1 -split "`n").Where{ $_ -ne "" }.Count
    $macrosCount2 = ($macros2 -split "`n").Where{ $_ -ne "" }.Count

    Write-Host "ClickHouse1 Macros count: $macrosCount1"
    Write-Host "ClickHouse2 Macros count: $macrosCount2"

    Test-Result "ClickHouse1 has 5 macros" ($macrosCount1 -eq 5) $true
    Test-Result "ClickHouse2 has 5 macros" ($macrosCount2 -eq 5) $true
} catch {
    Test-Result "Macros config OK" $false $true
}

# 6. Test replicated table creation
Print-Section "6. Replicated Table Creation Test"
$TABLE_EXISTS = $false

try {
    # Drop table if exists
    $dropUri = "$CH1_HTTP/"
    Invoke-WebRequest -Uri $dropUri -Method POST -Body "DROP TABLE IF EXISTS test_replication" -UseBasicParsing | Out-Null

    # Create table with default path
    $createQuery = "CREATE TABLE test_replication (id UInt64, data String, created_at DateTime DEFAULT now()) ENGINE = ReplicatedMergeTree ORDER BY id"
    $createUri = "$CH1_HTTP/"
    $createResult = Invoke-WebRequest -Uri $createUri -Method POST -Body $createQuery -UseBasicParsing

    if ($createResult.StatusCode -eq 200) {
        Write-Host "Table created successfully"

        # Wait for table to appear on both replicas
        Start-Sleep -Seconds 3

        $uri1 = "$CH1_HTTP/?query=EXISTS test_replication"
        $uri2 = "$CH2_HTTP/?query=EXISTS test_replication"
        $tableExists1 = (Invoke-WebRequest -Uri $uri1 -UseBasicParsing).Content.Trim()
        $tableExists2 = (Invoke-WebRequest -Uri $uri2 -UseBasicParsing).Content.Trim()

        Write-Host "Table exists on ClickHouse1: $tableExists1"
        Write-Host "Table exists on ClickHouse2: $tableExists2"

        Test-Result "Table exists on replica 1" ($tableExists1 -eq "1") $true
        Test-Result "Table exists on replica 2" ($tableExists2 -eq "1") $true

        if (($tableExists1 -eq "1") -and ($tableExists2 -eq "1")) {
            $TABLE_EXISTS = $true
        }
    } else {
        Write-Host "Table creation failed, status code: $($createResult.StatusCode)"
        Test-Result "Table created successfully" $false $true
    }
} catch {
    Write-Host "Table creation exception: $_"
    Test-Result "Table created successfully" $false $true
}

# 7. Test data insertion and replication
Print-Section "7. Data Insertion and Replication Test"
if ($TABLE_EXISTS) {
    try {
        # Insert test data
        $insertUri = "$CH1_HTTP/"
        $insertBody = "1`thello`t`n2`tworld`t`n3`tclickhouse"
        $insertResult = Invoke-WebRequest -Uri $insertUri -Method POST -Body "INSERT INTO test_replication FORMAT TabSeparated" -UseBasicParsing

        if ($insertResult.StatusCode -eq 200) {
            Write-Host "Data inserted successfully"

            # Wait for replication
            Start-Sleep -Seconds 2

            # Query data from both replicas
            $uri1 = "$CH1_HTTP/?query=SELECT count() FROM test_replication"
            $uri2 = "$CH2_HTTP/?query=SELECT count() FROM test_replication"
            $response1 = Invoke-WebRequest -Uri $uri1 -UseBasicParsing
            $response2 = Invoke-WebRequest -Uri $uri2 -UseBasicParsing
            $count1 = $response1.Content.Trim()
            $count2 = $response2.Content.Trim()

            Write-Host "ClickHouse1 row count: $count1"
            Write-Host "ClickHouse2 row count: $count2"

            Test-Result "Replica 1 data correct" ($count1 -eq "3") $true
            Test-Result "Replica 2 data correct" ($count2 -eq "3") $true
            Test-Result "Data replicated to replica 2" ($count2 -eq $count1) $true
        } else {
            Write-Host "Data insertion failed"
            Test-Result "Data inserted successfully" $false $true
        }
    } catch {
        Write-Host "Data insertion exception: $_"
        Test-Result "Data inserted successfully" $false $true
    }
}

# 8. Test replication status
Print-Section "8. Replication Status Test"
if ($TABLE_EXISTS) {
    try {
        $query = "SELECT is_leader, replica_name, total_replicas FROM system.replicas WHERE table="
        $query += [char]39 + "test_replication" + [char]39
        $query += " FORMAT TabSeparated"
        $uri1 = "$CH1_HTTP/?query=$query"
        $uri2 = "$CH2_HTTP/?query=$query"
        $replicaStatus1 = (Invoke-WebRequest -Uri $uri1 -UseBasicParsing).Content
        $replicaStatus2 = (Invoke-WebRequest -Uri $uri2 -UseBasicParsing).Content

        Write-Host "ClickHouse1 replication status:"
        Write-Host $replicaStatus1
        Write-Host ""
        Write-Host "ClickHouse2 replication status:"
        Write-Host $replicaStatus2

        # Check if has leader
        $hasLeader = ($replicaStatus1 -match "`t1") -or ($replicaStatus2 -match "`t1")
        Test-Result "One leader exists" $hasLeader $true
    } catch {
        Test-Result "Replication status check" $false $true
    }
}

# 9. Test ZooKeeper path
Print-Section "9. ZooKeeper Path Test"
if ($TABLE_EXISTS) {
    try {
        $query = "SELECT zookeeper_path FROM system.replicas WHERE table="
        $query += [char]39 + "test_replication" + [char]39
        $query += " FORMAT TabSeparated"
        $uri = "$CH1_HTTP/?query=$query"
        $zkPath = (Invoke-WebRequest -Uri $uri -UseBasicParsing).Content.Trim()

        Write-Host "ZooKeeper path: $zkPath"
        Write-Host "Expected path: /clickhouse/tables/1/test_replication"

        $expectedPath = "/clickhouse/tables/1/test_replication"
        Test-Result "ZooKeeper path uses default config" ($zkPath -eq $expectedPath) $true
    } catch {
        Test-Result "ZooKeeper path check" $false $true
    }
}

# 10. Cleanup test table
Print-Section "10. Cleanup Test Data"
try {
    $dropUri = "$CH1_HTTP/"
    $dropResult = Invoke-WebRequest -Uri $dropUri -Method POST -Body "DROP TABLE IF EXISTS test_replication" -UseBasicParsing

    if ($dropResult.StatusCode -eq 200) {
        Write-Host "Test table cleanup successful"
    } else {
        Write-Host "Test table cleanup failed, status code: $($dropResult.StatusCode)"
    }
} catch {
    Write-Host "Test table cleanup exception: $_"
}

# Output summary
Print-Section "Test Summary"
Write-Host "Total tests: $TOTAL_TESTS"
Write-Host "Passed: $PASSED_TESTS" -ForegroundColor Green
Write-Host "Failed: $FAILED_TESTS" -ForegroundColor Red

if ($FAILED_TESTS -eq 0) {
    Write-Host "ALL TESTS PASSED!" -ForegroundColor Green
    exit 0
} else {
    Write-Host "$FAILED_TESTS tests failed" -ForegroundColor Red
    exit 1
}
