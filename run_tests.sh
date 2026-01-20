#!/bin/bash

# ================================================
# run_tests.sh
# ClickHouse 综合测试脚本
# ================================================

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 打印带颜色的消息
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 检查 Docker 是否运行
check_docker() {
    print_info "检查 Docker 运行状态..."
    if ! docker ps > /dev/null 2>&1; then
        print_error "Docker 未运行，请先启动 Docker"
        exit 1
    fi
    print_success "Docker 运行正常"
}

# 检查 ClickHouse 集群是否启动
check_cluster() {
    print_info "检查 ClickHouse 集群状态..."
    if ! docker ps | grep -q "clickhouse1"; then
        print_error "ClickHouse 集群未启动，请先运行: cd 00-infra && docker compose up -d"
        exit 1
    fi
    print_success "ClickHouse 集群运行正常"
}

# 检查测试数据库是否存在
check_test_databases() {
    print_info "检查测试数据库..."
    result=$(docker exec -it clickhouse1 clickhouse-client --query "SELECT count() FROM system.databases WHERE name LIKE 'test_%'" --format=TSV 2>/dev/null | tr -d '\r')
    if [ "$result" -gt 0 ]; then
        print_warning "发现测试数据库，是否要清理？(y/n)"
        read -r response
        if [ "$response" = "y" ] || [ "$response" = "Y" ]; then
            print_info "清理测试数据库..."
            docker exec -it clickhouse1 clickhouse-client --query "
                DROP DATABASE IF EXISTS test_info_schema ON CLUSTER 'treasurycluster' SYNC;
                DROP DATABASE IF EXISTS test_data_deletion ON CLUSTER 'treasurycluster' SYNC;
                DROP DATABASE IF EXISTS test_date_time ON CLUSTER 'treasurycluster' SYNC;
            "
            print_success "测试数据库已清理"
        fi
    fi
}

# 运行完整测试
run_full_test() {
    print_info "运行完整测试..."
    docker exec -it clickhouse1 clickhouse-client --queries-file /var/lib/clickhouse/user_files/test_all_topics.sql
    print_success "完整测试完成"
}

# 运行特定测试
run_specific_test() {
    local test_type=$1
    print_info "运行 $test_type 测试..."

    case $test_type in
        "info_schema")
            sed -n '/^-- ========================================.*08-information-schema 测试$/,/^-- 09-data-deletion �测试$/p' test_all_topics.sql | \
            head -n -1 | \
            docker exec -i clickhouse1 clickhouse-client --multiquery
            ;;
        "data_deletion")
            sed -n '/^-- 09-data-deletion 测试$/,/^-- 10-date-update 测试$/p' test_all_topics.sql | \
            head -n -1 | \
            docker exec -i clickhouse1 clickhouse-client --multiquery
            ;;
        "date_time")
            sed -n '/^-- 10-date-update 测试$/,/^-- ========================================.*清理和总结$/p' test_all_topics.sql | \
            head -n -1 | \
            docker exec -i clickhouse1 clickhouse-client --multiquery
            ;;
        *)
            print_error "未知的测试类型: $test_type"
            exit 1
            ;;
    esac

    print_success "$test_type 测试完成"
}

# 显示测试结果
show_test_results() {
    print_info "测试结果统计"
    echo ""
    docker exec -it clickhouse1 clickhouse-client --query "
        SELECT 
            database,
            table,
            engine,
            total_rows,
            formatReadableSize(total_bytes) as size
        FROM system.tables
        WHERE database LIKE 'test_%'
        ORDER BY database, table
    " --format Pretty
    echo ""
}

# 显示分区信息
show_partitions() {
    print_info "分区信息"
    echo ""
    docker exec -it clickhouse1 clickhouse-client --query "
        SELECT 
            database,
            table,
            partition,
            sum(rows) as rows,
            formatReadableSize(sum(bytes_on_disk)) as size
        FROM system.parts
        WHERE database LIKE 'test_%' AND active = 1
        GROUP BY database, table, partition
        ORDER BY database, table, partition
    " --format Pretty
    echo ""
}

# 显示副本状态
show_replicas() {
    print_info "副本状态"
    echo ""
    docker exec -it clickhouse1 clickhouse-client --query "
        SELECT 
            database,
            table,
            is_leader,
            can_become_leader,
            queue_size,
            absolute_delay
        FROM system.replicas
        WHERE database LIKE 'test_%'
        ORDER BY database, table
    " --format Pretty
    echo ""
}

# 清理测试数据
cleanup_tests() {
    print_info "清理测试数据..."
    docker exec -it clickhouse1 clickhouse-client --query "
        DROP DATABASE IF EXISTS test_info_schema ON CLUSTER 'treasurycluster' SYNC;
        DROP DATABASE IF EXISTS test_data_deletion ON CLUSTER 'treasurycluster' SYNC;
        DROP DATABASE IF EXISTS test_date_time ON CLUSTER 'treasurycluster' SYNC;
    "
    print_success "测试数据已清理"
}

# 显示帮助信息
show_help() {
    cat << EOF
ClickHouse 综合测试脚本

用法: ./run_tests.sh [选项]

选项:
    -h, --help              显示帮助信息
    -a, --all               运行完整测试
    -i, --info-schema       只运行 08-information-schema 测试
    -d, --data-deletion     只运行 09-data-deletion 测试
    -t, --date-time         只运行 10-date-update 测试
    -r, --results           显示测试结果
    -p, --partitions        显示分区信息
    -R, --replicas          显示副本状态
    -c, --cleanup           清理测试数据

示例:
    ./run_tests.sh --all                    # 运行完整测试
    ./run_tests.sh --info-schema            # 只运行元数据测试
    ./run_tests.sh --data-deletion          # 只运行数据删除测试
    ./run_tests.sh --date-time              # 只运行日期时间测试
    ./run_tests.sh --results                # 显示测试结果
    ./run_tests.sh --cleanup                # 清理测试数据

详细文档请查看: TEST_GUIDE.md
EOF
}

# 主函数
main() {
    # 检查参数
    if [ $# -eq 0 ]; then
        show_help
        exit 0
    fi

    # 解析参数
    while [ $# -gt 0 ]; do
        case $1 in
            -h|--help)
                show_help
                exit 0
                ;;
            -a|--all)
                check_docker
                check_cluster
                check_test_databases
                run_full_test
                show_test_results
                shift
                ;;
            -i|--info-schema)
                check_docker
                check_cluster
                run_specific_test "info_schema"
                shift
                ;;
            -d|--data-deletion)
                check_docker
                check_cluster
                run_specific_test "data_deletion"
                shift
                ;;
            -t|--date-time)
                check_docker
                check_cluster
                run_specific_test "date_time"
                shift
                ;;
            -r|--results)
                check_docker
                check_cluster
                show_test_results
                shift
                ;;
            -p|--partitions)
                check_docker
                check_cluster
                show_partitions
                shift
                ;;
            -R|--replicas)
                check_docker
                check_cluster
                show_replicas
                shift
                ;;
            -c|--cleanup)
                check_docker
                check_cluster
                cleanup_tests
                shift
                ;;
            *)
                print_error "未知选项: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

# 运行主函数
main "$@"
