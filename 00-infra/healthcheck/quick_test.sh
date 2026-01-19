#!/bin/bash

# Quick Test Script - 测试基本功能

echo "========================================"
echo "ClickHouse Quick Test"
echo "========================================"
echo ""

# 1. 测试连接
echo "1. Testing connection to ClickHouse1..."
if curl -s http://localhost:8123 > /dev/null 2>&1; then
    echo "   ✓ ClickHouse1 is accessible"
else
    echo "   ✗ ClickHouse1 is not accessible"
    exit 1
fi

echo "2. Testing connection to ClickHouse2..."
if curl -s http://localhost:8124 > /dev/null 2>&1; then
    echo "   ✓ ClickHouse2 is accessible"
else
    echo "   ✗ ClickHouse2 is not accessible"
    exit 1
fi

# 2. 测试版本
echo ""
echo "3. Checking versions..."
VERSION1=$(curl -s "http://localhost:8123/?query=SELECT version()")
VERSION2=$(curl -s "http://localhost:8124/?query=SELECT version()")
echo "   ClickHouse1: $VERSION1"
echo "   ClickHouse2: $VERSION2"

if [ "$VERSION1" == "$VERSION2" ]; then
    echo "   ✓ Versions match"
else
    echo "   ✗ Versions do not match"
    exit 1
fi

# 3. 测试表创建
echo ""
echo "4. Testing table creation with default path..."
DROP_RESULT=$(curl -s -X POST http://localhost:8123/ --data "DROP TABLE IF EXISTS quick_test" 2>&1)
CREATE_RESULT=$(curl -s -X POST http://localhost:8123/ --data "CREATE TABLE quick_test (id UInt64, value String) ENGINE = ReplicatedMergeTree ORDER BY id" 2>&1)

if [ $? -eq 0 ]; then
    echo "   ✓ Table created successfully"

    # 4. 测试数据插入
    echo ""
    echo "5. Testing data insertion..."
    INSERT_RESULT=$(curl -s -X POST http://localhost:8123/ --data-binary "INSERT INTO quick_test FORMAT TabSeparated
1	one
2	two
3	three" 2>&1)

    if [ $? -eq 0 ]; then
        echo "   ✓ Data inserted successfully"

        # 5. 测试数据复制
        echo ""
        echo "6. Testing data replication..."
        sleep 2

        COUNT1=$(curl -s "http://localhost:8123/?query=SELECT count() FROM quick_test" | tr -d '\n')
        COUNT2=$(curl -s "http://localhost:8124/?query=SELECT count() FROM quick_test" 2>&1 | tr -d '\n')

        echo "   ClickHouse1 count: $COUNT1"
        echo "   ClickHouse2 count: $COUNT2"

        if [ "$COUNT1" == "$COUNT2" ] && [ "$COUNT1" == "3" ]; then
            echo "   ✓ Data replicated successfully"
        else
            echo "   ✗ Data replication failed"
        fi
    else
        echo "   ✗ Data insertion failed"
    fi

    # 6. 清理
    echo ""
    echo "7. Cleaning up..."
    DROP_RESULT=$(curl -s -X POST http://localhost:8123/ --data "DROP TABLE IF EXISTS quick_test" 2>&1)
    if [ $? -eq 0 ]; then
        echo "   ✓ Cleanup successful"
    else
        echo "   ✗ Cleanup failed"
    fi
else
    echo "   ✗ Table creation failed"
    exit 1
fi

echo ""
echo "========================================"
echo "Quick test completed!"
echo "========================================"
