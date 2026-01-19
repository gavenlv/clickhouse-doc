#!/bin/bash

# ClickHouse Cluster Health Check Script
# 测试集群各项功能是否符合预期

# 配置
CH1_HTTP="http://localhost:8123"
CH2_HTTP="http://localhost:8124"
COLOR_GREEN='\033[0;32m'
COLOR_RED='\033[0;31m'
COLOR_YELLOW='\033[1;33m'
COLOR_NC='\033[0m' # No Color

# 计数器
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

# 测试函数
test_result() {
    local test_name="$1"
    local result="$2"
    local expected="$3"

    TOTAL_TESTS=$((TOTAL_TESTS + 1))

    if [ "$result" == "$expected" ]; then
        echo -e "${COLOR_GREEN}✓${COLOR_NC} $test_name"
        PASSED_TESTS=$((PASSED_TESTS + 1))
        return 0
    else
        echo -e "${COLOR_RED}✗${COLOR_NC} $test_name"
        echo "  Expected: $expected"
        echo "  Got: $result"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        return 1
    fi
}

# 输出分隔线
print_section() {
    echo ""
    echo "========================================"
    echo "$1"
    echo "========================================"
}

# 1. 测试 ClickHouse 服务是否运行
print_section "1. 服务可用性测试"
curl -s "$CH1_HTTP" > /dev/null 2>&1
test_result "ClickHouse1 HTTP 服务" $? "0"

curl -s "$CH2_HTTP" > /dev/null 2>&1
test_result "ClickHouse2 HTTP 服务" $? "0"

# 2. 测试版本信息
print_section "2. 版本信息测试"
VERSION1=$(curl -s "$CH1_HTTP/?query=SELECT%20version()")
VERSION2=$(curl -s "$CH2_HTTP/?query=SELECT%20version()")

echo "ClickHouse1 Version: $VERSION1"
echo "ClickHouse2 Version: $VERSION2"

test_result "两个节点版本一致" "$VERSION1" "$VERSION2"

# 3. 测试 Keeper 连接
print_section "3. Keeper 连接测试"
KEEPER_NODES=$(curl -s "$CH1_HTTP/?query=SELECT%20count()%20FROM%20system.zookeeper%20WHERE%20path%20%3D%20'/'" | tr -d '\n')
test_result "Keeper 节点数量" "$KEEPER_NODES" "1"

# 4. 测试集群配置
print_section "4. 集群配置测试"
CLUSTERS=$(curl -s "$CH1_HTTP/?query=SELECT%20cluster%2C%20shard_num%2C%20replica_num%20FROM%20system.clusters%20WHERE%20cluster%20%3D%20'treasurycluster'%20FORMAT%20TabSeparated" | wc -l)
test_result "集群副本数量" "$CLUSTERS" "2"

# 5. 测试 macros
print_section "5. Macros 配置测试"
MACROS1=$(curl -s "$CH1_HTTP/?query=SELECT%20*%20FROM%20system.macros%20FORMAT%20TabSeparated" | wc -l)
MACROS2=$(curl -s "$CH2_HTTP/?query=SELECT%20*%20FROM%20system.macros%20FORMAT%20TabSeparated" | wc -l)

echo "ClickHouse1 Macros 数量: $MACROS1"
echo "ClickHouse2 Macros 数量: $MACROS2"

test_result "每个节点有 macros" "$MACROS1" "5"
test_result "每个节点有 macros" "$MACROS2" "5"

# 6. 测试复制表创建
print_section "6. 复制表创建测试"
DROP_RESULT=$(curl -s -X POST "$CH1_HTTP/" --data "DROP TABLE IF EXISTS test_replication")
CREATE_RESULT=$(curl -s -X POST "$CH1_HTTP/" --data "CREATE TABLE test_replication (id UInt64, data String, created_at DateTime DEFAULT now()) ENGINE = ReplicatedMergeTree ORDER BY id")

if [ $? -eq 0 ]; then
    echo -e "${COLOR_GREEN}✓${COLOR_NC} 表创建成功"

    # 等待表在第二个副本上出现
    sleep 3

    TABLE_EXISTS1=$(curl -s "$CH1_HTTP/?query=EXISTS%20test_replication")
    TABLE_EXISTS2=$(curl -s "$CH2_HTTP/?query=EXISTS%20test_replication")

    echo "表在 ClickHouse1 存在: $TABLE_EXISTS1"
    echo "表在 ClickHouse2 存在: $TABLE_EXISTS2"

    test_result "表在第一个副本存在" "$TABLE_EXISTS1" "1"
    test_result "表在第二个副本存在" "$TABLE_EXISTS2" "1"
else
    echo -e "${COLOR_RED}✗${COLOR_NC} 表创建失败"
    FAILED_TESTS=$((FAILED_TESTS + 1))
fi

# 7. 测试数据插入和复制
print_section "7. 数据插入和复制测试"
if [ "$TABLE_EXISTS1" == "1" ] && [ "$TABLE_EXISTS2" == "1" ]; then
    # 插入测试数据
    INSERT_RESULT=$(curl -s -X POST "$CH1_HTTP/" --data-binary "INSERT INTO test_replication FORMAT TabSeparated
1	data1
2	data2
3	data3")

    if [ $? -eq 0 ]; then
        echo -e "${COLOR_GREEN}✓${COLOR_NC} 数据插入成功"

        # 等待复制
        sleep 2

        # 查询两个副本的数据
        COUNT1=$(curl -s "$CH1_HTTP/?query=SELECT%20count()%20FROM%20test_replication" | tr -d '\n')
        COUNT2=$(curl -s "$CH2_HTTP/?query=SELECT%20count()%20FROM%20test_replication" | tr -d '\n')

        echo "ClickHouse1 数据行数: $COUNT1"
        echo "ClickHouse2 数据行数: $COUNT2"

        test_result "第一个副本数据正确" "$COUNT1" "3"
        test_result "第二个副本数据正确" "$COUNT2" "3"
        test_result "数据已复制到第二个副本" "$COUNT2" "$COUNT1"
    else
        echo -e "${COLOR_RED}✗${COLOR_NC} 数据插入失败"
        FAILED_TESTS=$((FAILED_TESTS + 1))
    fi
fi

# 8. 测试复制状态
print_section "8. 复制状态测试"
REPLICA_STATUS1=$(curl -s "$CH1_HTTP/?query=SELECT%20is_leader%2C%20replica_name%20FROM%20system.replicas%20WHERE%20table%20%3D%20'test_replication'%20FORMAT%20TabSeparated")
REPLICA_STATUS2=$(curl -s "$CH2_HTTP/?query=SELECT%20is_leader%2C%20replica_name%20FROM%20system.replicas%20WHERE%20table%20%3D%20'test_replication'%20FORMAT%20TabSeparated")

echo "ClickHouse1 复制状态:"
echo "$REPLICA_STATUS1"
echo ""
echo "ClickHouse2 复制状态:"
echo "$REPLICA_STATUS2"

# 检查是否有 leader
LEADER_COUNT=$(echo "$REPLICA_STATUS1"$'\n'"$REPLICA_STATUS2" | grep -c "1" || echo "0")
test_result "存在一个 leader" "$LEADER_COUNT" "1"

# 9. 测试 ZooKeeper 路径
print_section "9. ZooKeeper 路径测试"
if [ "$TABLE_EXISTS1" == "1" ]; then
    ZK_PATH=$(curl -s "$CH1_HTTP/?query=SELECT%20zookeeper_path%20FROM%20system.replicas%20WHERE%20table%20%3D%20'test_replication'%20FORMAT%20TabSeparated" | tr -d '\n')

    echo "ZooKeeper 路径: $ZK_PATH"
    echo "预期路径: /clickhouse/tables/1/test_replication"

    test_result "ZooKeeper 路径使用默认配置" "$ZK_PATH" "/clickhouse/tables/1/test_replication"
fi

# 10. 清理测试表
print_section "10. 清理测试数据"
DROP_RESULT=$(curl -s -X POST "$CH1_HTTP/" --data "DROP TABLE IF EXISTS test_replication")

if [ $? -eq 0 ]; then
    echo -e "${COLOR_GREEN}✓${COLOR_NC} 测试表清理成功"
else
    echo -e "${COLOR_RED}✗${COLOR_NC} 测试表清理失败"
    FAILED_TESTS=$((FAILED_TESTS + 1))
fi

# 输出总结
print_section "测试总结"
echo -e "总测试数: $TOTAL_TESTS"
echo -e "${COLOR_GREEN}通过: $PASSED_TESTS${COLOR_NC}"
echo -e "${COLOR_RED}失败: $FAILED_TESTS${COLOR_NC}"

if [ $FAILED_TESTS -eq 0 ]; then
    echo -e "${COLOR_GREEN}✓ 所有测试通过！${COLOR_NC}"
    exit 0
else
    echo -e "${COLOR_RED}✗ 有 $FAILED_TESTS 个测试失败${COLOR_NC}"
    exit 1
fi
