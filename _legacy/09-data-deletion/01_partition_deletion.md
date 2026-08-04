# 分区删除

分区删除是 ClickHouse 中最快、最高效的数据删除方法。

## 📋 基本语法

```sql
-- 删除单个分区
ALTER TABLE table_name
DROP PARTITION partition_value;

-- 删除多个分区
ALTER TABLE table_name
DROP PARTITION partition_value1, partition_value2, ...;

-- 使用 DETACH 后再删除（更安全）
ALTER TABLE table_name
DETACH PARTITION partition_value;
```

## 🎯 使用场景

### 场景 1: 删除历史数据

```sql
-- 删除 2023 年 1 月的所有数据
ALTER TABLE events
DROP PARTITION '2023-01';

-- 删除多个月份的数据
ALTER TABLE events
DROP PARTITION '2023-01', '2023-02', '2023-03';
```

### 场景 2: 按时间范围删除

```sql
-- 查看当前分区
SELECT 
    partition,
    formatReadableSize(sum(bytes_on_disk)) AS size,
    sum(rows) AS rows
FROM system.parts
WHERE table = 'events' AND active = 1
GROUP BY partition
ORDER BY partition;

-- 删除早于特定日期的分区
ALTER TABLE events
DROP PARTITION '2023-06';
```

### 场景 3: 清理测试数据

```sql
-- 删除测试分区的数据
ALTER TABLE events
DROP PARTITION 'test_2023-01';

-- 或使用 DETACH（保留数据文件）
ALTER TABLE events
DETACH PARTITION 'test_2023-01';

-- 重新附加分区（恢复数据）
ALTER TABLE events
ATTACH PARTITION 'test_2023-01';
```

### 场景 4: 定期清理脚本

```bash
#!/bin/bash
# clean_old_partitions.sh

CLICKHOUSE_HOST="localhost"
CLICKHOUSE_PORT="9000"
DATABASE="your_database"
TABLE="your_table"
RETENTION_MONTHS=6

# 计算要删除的分区
PARTITIONS_TO_DELETE=$(clickhouse-client --host=$CLICKHOUSE_HOST --port=$CLICKHOUSE_PORT --query="
    SELECT partition 
    FROM system.parts 
    WHERE database = '$DATABASE' 
      AND table = '$TABLE' 
      AND active = 1
      AND toDate(replaceRegexpOne(partition, '^(\\d{4})(\\d{2})', '\\1-\\2-01')) < addMonths(now(), -$RETENTION_MONTHS)
    GROUP BY partition
    ORDER BY partition
")

# 删除分区
for partition in $PARTITIONS_TO_DELETE; do
    echo "Dropping partition: $partition"
    clickhouse-client --host=$CLICKHOUSE_HOST --port=$CLICKHOUSE_PORT --query="
        ALTER TABLE $DATABASE.$TABLE DROP PARTITION '$partition'"
done
```

## 🔧 分区操作详解

### DROP vs DETACH vs DELETE

| 操作 | 速度 | 数据恢复 | 适用场景 |
|------|------|---------|---------|
| DROP PARTITION | ⭐⭐⭐⭐⭐ | ❌ 不可恢复 | 永久删除不需要的数据 |
| DETACH PARTITION | ⭐⭐⭐⭐⭐ | ✅ 可恢复 | 临时移除，可能需要恢复 |
| DELETE | ⭐⭐ | ⚠️ 困难 | 删除部分数据 |

### 分区命名规则

不同分区策略的分区值格式：

```sql
-- 按月分区
PARTITION BY toYYYYMM(event_time)
-- 分区值: '202301'

-- 按日期分区
PARTITION BY toDate(event_time)
-- 分区值: '2023-01-01'

-- 按年分区
PARTITION BY toYYYY(event_time)
-- 分区值: '2023'

-- 按自定义字段分区
PARTITION BY toUInt32(user_id) / 10000
-- 分区值: '1', '2', '3', ...

-- 复合分区
PARTITION BY (event_date, type)
-- 分区值: ('2023-01-01', 'type1')
```

## 📊 分区管理

### 查看分区信息

```sql
-- 查看表的分区详情
SELECT
    partition,
    sum(rows) AS total_rows,
    formatReadableSize(sum(bytes_on_disk)) AS total_size,
    count() AS parts_count,
    min(modification_time) AS oldest_part,
    max(modification_time) AS newest_part
FROM system.parts
WHERE database = 'your_database'
  AND table = 'your_table'
  AND active = 1
GROUP BY partition
ORDER BY partition DESC;
```

### 查看分区数据分布

```sql
-- 分析分区大小分布
SELECT
    partition,
    formatReadableSize(sum(bytes_on_disk)) AS size,
    formatReadableQuantity(sum(rows)) AS rows,
    sum(rows) / NULLIF(sum(bytes_on_disk), 0) AS rows_per_byte
FROM system.parts
WHERE database = 'your_database'
  AND table = 'your_table'
  AND active = 1
GROUP BY partition
ORDER BY sum(bytes_on_disk) DESC;
```

### 检查可删除的分区

```sql
-- 查找可以删除的旧分区（超过 90 天）
SELECT
    partition,
    toDate(replaceRegexpOne(partition, '^(\\d{4})(\\d{2})', '\\1-\\2-01')) AS partition_date,
    formatReadableSize(sum(bytes_on_disk)) AS size,
    formatReadableQuantity(sum(rows)) AS rows,
    dateDiff('day', 
        toDate(replaceRegexpOne(partition, '^(\\d{4})(\\d{2})', '\\1-\\2-01')),
        today()
    ) AS days_ago
FROM system.parts
WHERE database = 'your_database'
  AND table = 'your_table'
  AND active = 1
  AND toDate(replaceRegexpOne(partition, '^(\\d{4})(\\d{2})', '\\1-\\2-01')) < today() - INTERVAL 90 DAY
GROUP BY partition
HAVING sum(bytes_on_disk) > 0
ORDER BY partition;
```

## 🎯 实战场景

### 场景 1: 自动化清理脚本（PowerShell）

```powershell
# clean_old_partitions.ps1

$ClickHouseHost = "localhost"
$ClickHousePort = 8123
$Database = "your_database"
$Table = "your_table"
$RetentionMonths = 6

# 获取要删除的分区
$PartitionsToDrop = clickhouse-client --host=$ClickHouseHost --port=$ClickHousePort --format=TSV --query="
    SELECT partition 
    FROM system.parts 
    WHERE database = '$Database' 
      AND table = '$Table' 
      AND active = 1
      AND toDate(replaceRegexpOne(partition, '^(\\d{4})(\\d{2})', '\1-\2-01')) < addMonths(now(), -$RetentionMonths)
    GROUP BY partition
    ORDER BY partition
"

# 删除每个分区
foreach ($Partition in $PartitionsToDrop -split "`n") {
    if ($Partition -match '\d+') {
        Write-Host "Dropping partition: $Partition"
        $Query = "ALTER TABLE $Database.$Table DROP PARTITION '$Partition'"
        clickhouse-client --host=$ClickHouseHost --port=$ClickHousePort --query=$Query
    }
}
```

### 场景 2: 分区归档

```sql
-- 1. 创建归档表（使用不同的存储策略）
CREATE TABLE events_archive AS events
ENGINE = MergeTree
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_time, user_id)
SETTINGS storage_policy = 'archive_policy';

-- 2. 将旧数据移动到归档表
INSERT INTO events_archive
SELECT * FROM events
WHERE event_time < '2023-01-01';

-- 3. 验证数据已复制
SELECT 
    'events' as table_name,
    partition,
    sum(rows) as rows
FROM system.parts
WHERE database = 'default' AND table = 'events' AND active = 1
GROUP BY partition

UNION ALL

SELECT 
    'events_archive',
    partition,
    sum(rows)
FROM system.parts
WHERE database = 'default' AND table = 'events_archive' AND active = 1
GROUP BY partition;

-- 4. 删除原表中的旧分区
ALTER TABLE events
DROP PARTITION '2022-12';
```

### 场景 3: 分区交换

```sql
-- 使用分区交换快速删除数据（适用于临时表）

-- 1. 创建临时表
CREATE TEMPORARY TABLE temp_delete AS events;

-- 2. 插入要保留的数据
INSERT INTO temp_delete
SELECT * FROM events
WHERE event_time >= '2023-01-01';

-- 3. 替换分区
ALTER TABLE events
REPLACE PARTITION '2023-01' FROM temp_delete;

-- 4. 验证数据
SELECT count() FROM events;
```

### 场景 4: 条件删除（通过分区）

```sql
-- 将数据重新分区后删除

-- 1. 添加临时分区列
ALTER TABLE events
ADD COLUMN temp_partition String;

-- 2. 标记要删除的数据
ALTER TABLE events
UPDATE temp_partition = 'delete' WHERE event_time < '2023-01-01';

-- 3. 强制合并
OPTIMIZE TABLE events FINAL;

-- 4. 删除标记的分区
ALTER TABLE events
DROP PARTITION 'delete';

-- 5. 清理临时列
ALTER TABLE events
DROP COLUMN temp_partition;
```

## 📈 监控和验证

### 监控删除操作

```sql
-- 查看正在执行的 ALTER 操作
SELECT
    database,
    table,
    mutation_id,
    command,
    is_done,
    create_time,
    exception_code,
    exception_text
FROM system.mutations
WHERE command LIKE '%DROP PARTITION%'
ORDER BY create_time DESC;
```

### 验证删除结果

```sql
-- 检查分区是否已删除
SELECT
    partition,
    sum(rows) AS rows,
    sum(bytes_on_disk) AS bytes
FROM system.parts
WHERE database = 'your_database'
  AND table = 'your_table'
  AND active = 1
GROUP BY partition
ORDER BY partition;

-- 检查非活动数据块（等待清理）
SELECT
    partition,
    name AS part_name,
    bytes_on_disk,
    remove_time
FROM system.parts
WHERE database = 'your_database'
  AND table = 'your_table'
  AND active = 0
ORDER BY partition;
```

## ⚠️ 注意事项

1. **备份优先**：执行 DROP PARTITION 前务必备份
2. **分区键设计**：合理设计分区键以支持按需删除
3. **删除验证**：删除后验证数据已正确移除
4. **空间释放**：DROP 是立即释放空间，DETACH 需要手动清理
5. **权限要求**：需要 ALTER 权限

## 💡 最佳实践

1. **使用 DETACH 测试**：生产环境前用 DETACH 测试
2. **批量删除**：一次删除多个分区比多次删除更高效
3. **监控进度**：使用 `system.mutations` 监控删除进度
4. **自动化脚本**：使用脚本自动化定期清理
5. **日志记录**：记录所有删除操作以便审计

## 📝 相关文档

- [02_ttl_deletion.md](./02_ttl_deletion.md) - TTL 自动删除
- [03_mutation_deletion.md](./03_mutation_deletion.md) - Mutation 删除
- [05_deletion_strategies.md](./05_deletion_strategies.md) - 删除策略选择
