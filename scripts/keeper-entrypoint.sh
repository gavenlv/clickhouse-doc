#!/bin/bash
# Entrypoint script for ClickHouse Keeper to handle permissions

# Ensure data directory exists with correct permissions
mkdir -p /var/lib/clickhouse/coordination/log
mkdir -p /var/lib/clickhouse/coordination/snapshots

# Fix permissions if running as root
if [ "$(id -u)" = "0" ]; then
    chown -R clickhouse:clickhouse /var/lib/clickhouse
    # Switch to clickhouse user and run keeper
    exec su -p clickhouse -c "/usr/bin/clickhouse-keeper --config /etc/clickhouse-server/config.d/keeper.xml"
fi

# Run ClickHouse Keeper directly
exec /usr/bin/clickhouse-keeper --config /etc/clickhouse-server/config.d/keeper.xml
