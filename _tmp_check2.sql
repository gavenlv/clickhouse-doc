-- 检查 system.zookeeper_connection 的列
SELECT name FROM system.columns WHERE database = 'system' AND table = 'zookeeper_connection';
-- 检查 system.clusters 列
SELECT host_name FROM system.clusters WHERE cluster = 'treasurycluster' LIMIT 2;
-- 检查 system.replicas 是否有 zombie_parts
SELECT count() FROM system.columns WHERE database = 'system' AND table = 'replicas' AND name = 'zombie_parts';
-- 检查 system.asynchronous_metrics 列
SELECT name FROM system.columns WHERE database = 'system' AND table = 'asynchronous_metrics';
