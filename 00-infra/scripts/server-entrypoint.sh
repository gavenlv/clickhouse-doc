#!/bin/bash
# Entrypoint script for ClickHouse Server to handle permissions

# Ensure data directory exists
mkdir -p /var/lib/clickhouse/data
mkdir -p /var/lib/clickhouse/tmp
mkdir -p /var/lib/clickhouse/user_files
mkdir -p /var/lib/clickhouse/format_schemas
mkdir -p /var/lib/clickhouse/access
mkdir -p /var/lib/clickhouse/preprocessed_configs

# Fix permissions if running as root
if [ "$(id -u)" = "0" ]; then
    chown -R clickhouse:clickhouse /var/lib/clickhouse
    # 启动 ClickHouse Server（使用正确的可执行文件）
    exec su-exec clickhouse /usr/bin/clickhouse-server --config-file=/etc/clickhouse-server/config.xml
else
    # 直接启动 ClickHouse Server
    exec /usr/bin/clickhouse-server --config-file=/etc/clickhouse-server/config.xml
fi
