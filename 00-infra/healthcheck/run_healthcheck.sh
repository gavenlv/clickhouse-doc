#!/bin/bash
# ================================================
# Cluster Health Check Script
# 在 ClickHouse 启动后执行，验证集群是否正常工作
# ================================================

set -e

# 配置
MAX_RETRIES=30
RETRY_INTERVAL=5
HEALTHCHECK_SQL="/var/lib/clickhouse/user_files/cluster_healthcheck.sql"

echo "========================================="
echo "ClickHouse Cluster Health Check"
echo "========================================="

# 等待 ClickHouse 完全启动
echo ""
echo "Waiting for ClickHouse to be ready..."
for i in $(seq 1 $MAX_RETRIES); do
    if clickhouse-client --query "SELECT 1" &> /dev/null; then
        echo "✓ ClickHouse is ready!"
        break
    fi
    
    if [ $i -eq $MAX_RETRIES ]; then
        echo "✗ Timeout: ClickHouse did not start within $((MAX_RETRIES * RETRY_INTERVAL)) seconds"
        exit 1
    fi
    
    echo "  Waiting... ($i/$MAX_RETRIES)"
    sleep $RETRY_INTERVAL
done

# 等待额外的几秒，确保所有集群连接已建立
echo ""
echo "Waiting for cluster connections to stabilize..."
sleep 10

# 检查健康检查 SQL 文件是否存在
if [ ! -f "$HEALTHCHECK_SQL" ]; then
    echo "✗ Health check SQL file not found: $HEALTHCHECK_SQL"
    exit 1
fi

# 执行健康检查
echo ""
echo "Executing cluster health check..."
echo "========================================="
if clickhouse-client --multiquery < "$HEALTHCHECK_SQL"; then
    echo ""
    echo "========================================="
    echo "✓ Cluster health check PASSED!"
    echo "========================================="
    exit 0
else
    echo ""
    echo "========================================="
    echo "✗ Cluster health check FAILED!"
    echo "========================================="
    exit 1
fi
