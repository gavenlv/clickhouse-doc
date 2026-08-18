-- 检查 system.metrics 列
DESCRIBE TABLE system.metrics;
-- 检查 system.merges 列
SELECT name FROM system.columns WHERE database = 'system' AND table = 'merges' AND name IN ('rows_read','rows_written','create_time','database','table');
-- 内存指标名
SELECT metric FROM system.asynchronous_metrics WHERE metric LIKE '%Memory%' ORDER BY metric;
