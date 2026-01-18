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
    # Switch to clickhouse user and run server
    exec su -p clickhouse -c "/entrypoint.sh"
fi

# Run ClickHouse Server directly
exec /entrypoint.sh
