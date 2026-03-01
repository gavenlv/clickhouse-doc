# 错误恢复与重试机制

## 1. 常见导入错误

### 1.1 网络错误

**错误类型**：
- 连接超时（Connection Timeout）
- 读取超时（Read Timeout）
- GCS访问拒绝（Access Denied）

**解决方案**：
```sql
-- 增加超时时间
SET connect_timeout = 600;      -- 10分钟
SET receive_timeout = 600;
SET send_timeout = 600;

-- 启用重试
SET max_retry_count = 3;
```

---

### 1.2 内存错误

**错误类型**：
- Memory Limit Exceeded
- Cannot allocate memory

**解决方案**：
```sql
-- 限制内存使用
SET max_memory_usage = 200000000000;  -- 200GB

-- 减小批量大小
SET max_insert_block_size = 524288;  -- 512K

-- 清理内存
SYSTEM DROP CACHE;
```

---

### 1.3 副本错误

**错误类型**：
- Replication queue overflow
- Replica is not active

**解决方案**：
```sql
-- 检查副本状态
SELECT * FROM system.replicas WHERE table = 'target_table';

-- 重启副本
SYSTEM RESTART REPLICA target_table;

-- 使用异步复制
SET insert_quorum = 1;
```

---

## 2. 断点续传实现

### 2.1 方法1：使用临时表

```sql
-- 步骤1：创建临时表
CREATE TABLE temp_import AS target_table;

-- 步骤2：分批导入
-- 每次导入一个文件
INSERT INTO temp_import
SELECT * FROM gcs('file_001.parquet', 'Parquet');

-- 步骤3：验证数据
SELECT count() FROM temp_import;

-- 步骤4：失败后可继续
-- 如果第3步失败，重新执行第2-3步

-- 步骤5：最终合并
INSERT INTO target_table SELECT * FROM temp_import;
```

---

### 2.2 方法2：分区导入

```sql
-- 按分区导入，每个分区独立
-- 导入分区1
INSERT INTO target_table
SELECT * FROM gcs('partition_01.parquet', 'Parquet')
WHERE date = '2024-01-01';

-- 导入分区2（如果分区1失败，不影响分区2）
INSERT INTO target_table
SELECT * FROM gcs('partition_02.parquet', 'Parquet')
WHERE date = '2024-01-02';

-- 检查缺失的分区
SELECT DISTINCT date
FROM gcs('*.parquet', 'Parquet')
WHERE date NOT IN (
    SELECT DISTINCT date FROM target_table
);
```

---

### 2.3 方法3：幂等性设计

```sql
-- 使用ReplacingMergeTree确保幂等性
CREATE TABLE target_table (
    event_id String,
    -- 其他字段...
    _version UInt64
) ENGINE = ReplacingMergeTree(_version)
ORDER BY (event_id);

-- 每次导入使用相同版本号
INSERT INTO target_table
SELECT *, 1 as _version FROM gcs('data.parquet', 'Parquet');

-- 重复导入相同数据不会产生重复
```

---

## 3. 重试策略

### 3.1 自动重试脚本

```bash
#!/bin/bash

# 重试配置
MAX_RETRIES=3
RETRY_DELAY=60  # 秒

# 导入函数
import_file() {
    local file=$1
    local retry=0
    
    while [ $retry -lt $MAX_RETRIES ]; do
        clickhouse-client --query="
            INSERT INTO target_table
            SELECT * FROM gcs('$file', 'Parquet')
        "
        
        if [ $? -eq 0 ]; then
            echo "Successfully imported $file"
            return 0
        fi
        
        retry=$((retry + 1))
        echo "Retry $retry/$MAX_RETRIES for $file after $RETRY_DELAY seconds"
        sleep $RETRY_DELAY
    done
    
    echo "Failed to import $file after $MAX_RETRIES retries"
    return 1
}

# 批量导入
for file in gs://bucket/data/*.parquet; do
    import_file "$file"
done
```

---

### 3.2 错误日志记录

```sql
-- 创建错误日志表
CREATE TABLE import_errors (
    import_time DateTime DEFAULT now(),
    file_path String,
    error_message String,
    retry_count UInt32
) ENGINE = MergeTree()
ORDER BY import_time;

-- 记录错误
INSERT INTO import_errors (file_path, error_message, retry_count)
VALUES ('gs://bucket/data/file.parquet', 'Connection timeout', 3);

-- 查询错误统计
SELECT 
    file_path,
    count() as error_count,
    error_message
FROM import_errors
GROUP BY file_path, error_message
ORDER BY error_count DESC;
```

---

## 4. 数据一致性检查

### 4.1 行数验证

```sql
-- 源文件行数
SELECT count() as source_count
FROM gcs('data.parquet', 'Parquet');

-- 目标表行数
SELECT count() as target_count
FROM target_table;

-- 对比
SELECT 
    (SELECT count() FROM gcs('data.parquet', 'Parquet')) as source,
    (SELECT count() FROM target_table) as target,
    source - target as difference;
```

---

### 4.2 数据完整性验证

```sql
-- 检查唯一键
SELECT count() - uniqExact(event_id) as duplicates
FROM target_table;

-- 检查时间范围
SELECT 
    min(event_time) as min_time,
    max(event_time) as max_time,
    max_time - min_time as time_span
FROM target_table;

-- 检查空值
SELECT 
    countIf(event_id = '') as empty_ids,
    countIf(event_time = 0) as invalid_times
FROM target_table;
```

---

## 5. 故障恢复流程

### 5.1 导入失败恢复

```
步骤1：识别失败的导入任务
  ↓
步骤2：检查错误日志
  ↓
步骤3：修复错误（网络/权限/配置）
  ↓
步骤4：重新执行失败的导入
  ↓
步骤5：验证数据完整性
```

---

### 5.2 数据回滚

```sql
-- 方法1：删除失败的数据
ALTER TABLE target_table DELETE WHERE import_time > '2024-01-01';

-- 方法2：使用分区回滚
ALTER TABLE target_table DROP PARTITION '202401';

-- 方法3：恢复到备份
RESTORE TABLE target_table FROM BACKUP 'backup_name';
```

---

## 6. 监控和告警

### 6.1 导入进度监控

```sql
-- 监控当前导入任务
SELECT 
    query_id,
    query,
    read_rows,
    written_rows,
    query_duration_ms / 1000 as duration_sec,
    memory_usage
FROM system.processes
WHERE query LIKE '%INSERT%'
ORDER BY query_duration_ms DESC;
```

---

### 6.2 错误告警

```sql
-- 检查最近的错误
SELECT 
    event_time,
    query,
    exception
FROM system.query_log
WHERE type = 'ExceptionWhileProcessing'
  AND event_time > now() - INTERVAL 1 HOUR
ORDER BY event_time DESC;
```

---

## 7. 最佳实践

### 7.1 导入前准备

- ✅ 检查磁盘空间
- ✅ 检查网络连接
- ✅ 检查权限配置
- ✅ 备份现有数据

### 7.2 导入中监控

- ✅ 实时监控CPU/内存
- ✅ 监控导入进度
- ✅ 记录错误日志
- ✅ 验证数据完整性

### 7.3 导入后验证

- ✅ 检查总行数
- ✅ 检查数据分布
- ✅ 运行测试查询
- ✅ 备份新数据

---

## 8. 应急预案

### 8.1 网络中断

**预案**：
1. 等待网络恢复
2. 使用断点续传重新导入
3. 检查数据完整性

### 8.2 磁盘满

**预案**：
1. 清理旧数据
2. 扩展磁盘容量
3. 使用分层存储

### 8.3 节点故障

**预案**：
1. 切换到副本节点
2. 修复故障节点
3. 同步数据

---

## 9. 联系支持

如果遇到无法解决的问题：

1. 收集错误日志
2. 收集系统指标
3. 联系ClickHouse支持团队
