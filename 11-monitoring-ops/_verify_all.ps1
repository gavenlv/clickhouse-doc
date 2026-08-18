$files = Get-ChildItem "d:\workspace\big-data\clickhouse-doc\11-monitoring-ops\*.sql" | Sort-Object Name
foreach ($f in $files) {
    docker cp $f.FullName "clickhouse-server-1:/tmp/verify.sql" | Out-Null
    # 仅统计真实错误（客户端异常前缀），排除查询结果中 system.text_log 消息包含的 "Code:" 文本
    # --ignore-error: 不因首个错误停止，暴露文件内全部错误
    $out = docker exec clickhouse-server-1 bash -c "clickhouse-client --multiquery --ignore-error --queries-file /tmp/verify.sql 2>&1 | grep -cE 'Received exception from server|Error on processing query'"
    Write-Output "$($f.Name): $out errors"
}
