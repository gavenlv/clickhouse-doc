-- 检查可用的诊断系统表
SELECT 'query_thread_log' AS t, count() AS has_rows FROM system.query_thread_log;
SELECT name FROM system.tables WHERE database = 'system' AND name LIKE '%trace%';
SELECT 'asynch metrics' AS t, count() FROM system.asynchronous_metrics;
SELECT metric, value FROM system.asynchronous_metrics WHERE metric LIKE 'LoadAverage%' OR metric LIKE 'OSCPU%' OR metric LIKE 'OSUser%' OR metric LIKE 'OSSystem%' ORDER BY metric;
SELECT 'merges cols' AS t, name FROM system.columns WHERE database = 'system' AND table = 'merges';
