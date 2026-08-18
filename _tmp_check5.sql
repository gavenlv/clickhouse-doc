-- 检查 system.merges 全列
SELECT name FROM system.columns WHERE database = 'system' AND table = 'merges' ORDER BY position;
