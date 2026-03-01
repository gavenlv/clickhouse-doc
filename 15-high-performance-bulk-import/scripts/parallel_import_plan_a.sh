#!/bin/bash
# ========================================
# 方案A：并行导入脚本
# ========================================
# 用途：多客户端并行导入Parquet文件到ClickHouse
# 使用：./parallel_import_plan_a.sh --parallel-clients 16
# ========================================

set -e  # 遇到错误立即退出

# ========================================
# 配置参数
# ========================================

# 默认配置
PARALLEL_CLIENTS=8
CLICKHOUSE_HOST="localhost"
CLICKHOUSE_PORT=9000
DATABASE="bulk_import_plan_a"
TABLE="target_table"
GCS_BUCKET="your-bucket-name"
GCS_PATH="data/**/*.parquet"
MAX_THREADS_PER_CLIENT=3
LOG_DIR="./logs"
LOG_FILE="${LOG_DIR}/import_$(date +%Y%m%d_%H%M%S).log"

# ========================================
# 解析命令行参数
# ========================================

while [[ $# -gt 0 ]]; do
    case $1 in
        --parallel-clients)
            PARALLEL_CLIENTS="$2"
            shift 2
            ;;
        --host)
            CLICKHOUSE_HOST="$2"
            shift 2
            ;;
        --database)
            DATABASE="$2"
            shift 2
            ;;
        --table)
            TABLE="$2"
            shift 2
            ;;
        --gcs-bucket)
            GCS_BUCKET="$2"
            shift 2
            ;;
        --help)
            echo "用法: $0 [选项]"
            echo "选项:"
            echo "  --parallel-clients N    并行客户端数量（默认：8）"
            echo "  --host HOST            ClickHouse主机（默认：localhost）"
            echo "  --database DB          数据库名（默认：bulk_import_plan_a）"
            echo "  --table TABLE          表名（默认：target_table）"
            echo "  --gcs-bucket BUCKET    GCS桶名"
            exit 0
            ;;
        *)
            echo "未知参数: $1"
            exit 1
            ;;
    esac
done

# ========================================
# 创建日志目录
# ========================================

mkdir -p "$LOG_DIR"

# ========================================
# 日志函数
# ========================================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# ========================================
# 检查ClickHouse连接
# ========================================

check_connection() {
    log "检查ClickHouse连接..."
    clickhouse-client --host="$CLICKHOUSE_HOST" --port="$CLICKHOUSE_PORT" --query="SELECT 1"
    if [ $? -eq 0 ]; then
        log "✓ ClickHouse连接成功"
    else
        log "✗ ClickHouse连接失败"
        exit 1
    fi
}

# ========================================
# 获取文件列表
# ========================================

get_file_list() {
    log "获取GCS文件列表..."
    # 这里需要根据实际情况获取文件列表
    # 示例：假设文件命名规则为 file_001.parquet, file_002.parquet, ...
    FILES=()
    for i in {1..100}; do
        FILES+=("gs://${GCS_BUCKET}/data/file_$(printf '%03d' $i).parquet")
    done
    log "✓ 找到 ${#FILES[@]} 个文件"
}

# ========================================
# 导入单个文件
# ========================================

import_file() {
    local file=$1
    local client_id=$2
    
    log "[Client $client_id] 开始导入: $file"
    
    clickhouse-client \
        --host="$CLICKHOUSE_HOST" \
        --port="$CLICKHOUSE_PORT" \
        --query="
            INSERT INTO ${DATABASE}.${TABLE}
            SETTINGS 
                max_insert_threads = ${MAX_THREADS_PER_CLIENT},
                max_insert_block_size = 1048576,
                min_insert_block_size_rows = 1000000,
                insert_quorum = 1,
                input_format_parallel_parsing = 1
            SELECT * FROM gcs(
                '${file}',
                'Parquet'
            )
        " 2>&1 | tee -a "$LOG_FILE"
    
    if [ ${PIPESTATUS[0]} -eq 0 ]; then
        log "[Client $client_id] ✓ 导入成功: $file"
        return 0
    else
        log "[Client $client_id] ✗ 导入失败: $file"
        return 1
    fi
}

# ========================================
# 并行导入
# ========================================

parallel_import() {
    log "开始并行导入（${PARALLEL_CLIENTS}个客户端）..."
    
    local total_files=${#FILES[@]}
    local files_per_client=$((total_files / PARALLEL_CLIENTS))
    local pids=()
    
    for ((client_id=0; client_id<PARALLEL_CLIENTS; client_id++)); do
        {
            local start_idx=$((client_id * files_per_client))
            local end_idx=$((start_idx + files_per_client))
            
            if [ $client_id -eq $((PARALLEL_CLIENTS - 1)) ]; then
                end_idx=$total_files
            fi
            
            for ((i=start_idx; i<end_idx; i++)); do
                import_file "${FILES[$i]}" $client_id
                if [ $? -ne 0 ]; then
                    log "[Client $client_id] 导入失败，停止该客户端"
                    break
                fi
            done
        } &
        pids+=($!)
    done
    
    # 等待所有客户端完成
    local failed=0
    for pid in "${pids[@]}"; do
        if ! wait $pid; then
            failed=1
        fi
    done
    
    if [ $failed -eq 0 ]; then
        log "✓ 所有导入任务完成"
    else
        log "✗ 部分导入任务失败"
    fi
}

# ========================================
# 验证导入结果
# ========================================

verify_import() {
    log "验证导入结果..."
    
    local count=$(clickhouse-client \
        --host="$CLICKHOUSE_HOST" \
        --port="$CLICKHOUSE_PORT" \
        --query="SELECT count() FROM ${DATABASE}.${TABLE}")
    
    log "✓ 导入完成，总行数: $count"
}

# ========================================
# 主流程
# ========================================

main() {
    log "========================================="
    log "开始执行并行导入方案A"
    log "========================================="
    
    log "配置信息:"
    log "  并行客户端数: ${PARALLEL_CLIENTS}"
    log "  ClickHouse主机: ${CLICKHOUSE_HOST}:${CLICKHOUSE_PORT}"
    log "  目标表: ${DATABASE}.${TABLE}"
    log "  GCS桶: ${GCS_BUCKET}"
    
    check_connection
    get_file_list
    parallel_import
    verify_import
    
    log "========================================="
    log "导入完成"
    log "========================================="
}

# 执行主流程
main
