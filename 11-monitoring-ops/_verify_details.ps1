$files = @('01_system_monitoring','06_tiered_storage','07_routine_maintenance')
foreach ($f in $files) {
    docker cp "d:\workspace\big-data\clickhouse-doc\11-monitoring-ops\$f.sql" "clickhouse-server-1:/tmp/verify.sql" | Out-Null
    $out = docker exec clickhouse-server-1 bash -c "clickhouse-client --multiquery --ignore-error --queries-file /tmp/verify.sql 2>&1 | grep -E '^Code: [0-9]+' | cut -c1-220 | sort | uniq -c"
    Write-Output "=== $f ==="
    Write-Output $out
}
