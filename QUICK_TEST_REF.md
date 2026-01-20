# 快速测试参考

## 🚀 快速开始

### 启动集群
```bash
cd 00-infra
docker compose up -d
```

### 运行完整测试

**Linux/Mac:**
```bash
cd ..
./run_tests.sh --all
```

**Windows:**
```cmd
cd ..
run_tests.bat --all
```

**直接使用 ClickHouse 客户端:**
```bash
docker exec -it clickhouse1 clickhouse-client --queries-file /var/lib/clickhouse/user_files/test_all_topics.sql
```

## 📊 测试概览

| 专题 | 测试表数量 | 测试用例数 | 主要功能 |
|------|-----------|-----------|---------|
| 08-information-schema | 3 | 50+ | 数据库元数据查询 |
| 09-data-deletion | 4 | 30+ | 数据删除方法 |
| 10-date-update | 3 | 60+ | 日期时间操作 |

## 🔧 测试命令

### Linux/Mac

| 命令 | 说明 |
|------|------|
| `./run_tests.sh --all` | 运行完整测试 |
| `./run_tests.sh --results` | 显示测试结果 |
| `./run_tests.sh --partitions` | 显示分区信息 |
| `./run_tests.sh --replicas` | 显示副本状态 |
| `./run_tests.sh --cleanup` | 清理测试数据 |
| `./run_tests.sh --help` | 显示帮助信息 |

### Windows

| 命令 | 说明 |
|------|------|
| `run_tests.bat --all` | 运行完整测试 |
| `run_tests.bat --results` | 显示测试结果 |
| `run_tests.bat --partitions` | 显示分区信息 |
| `run_tests.bat --replicas` | 显示副本状态 |
| `run_tests.bat --cleanup` | 清理测试数据 |
| `run_tests.bat --help` | 显示帮助信息 |

## 🧪 测试数据库

| 数据库 | 说明 |
|--------|------|
| `test_info_schema` | 元数据测试数据库 |
| `test_data_deletion` | 数据删除测试数据库 |
| `test_date_time` | 日期时间测试数据库 |

## 📋 快速查询

### 查看所有测试表
```sql
SELECT 
    database,
    table,
    engine,
    total_rows,
    formatReadableSize(total_bytes) as size
FROM system.tables
WHERE database LIKE 'test_%'
ORDER BY database, table;
```

### 查看分区信息
```sql
SELECT 
    database,
    table,
    partition,
    sum(rows) as rows,
    formatReadableSize(sum(bytes_on_disk)) as size
FROM system.parts
WHERE database LIKE 'test_%' AND active = 1
GROUP BY database, table, partition
ORDER BY database, table, partition;
```

### 查看副本状态
```sql
SELECT 
    database,
    table,
    is_leader,
    queue_size,
    absolute_delay
FROM system.replicas
WHERE database LIKE 'test_%'
ORDER BY database, table;
```

### 查看Mutation进度
```sql
SELECT 
    database,
    table,
    mutation_id,
    command,
    is_done,
    progress
FROM system.mutations
WHERE database = 'test_data_deletion'
ORDER BY created DESC;
```

## 🧹 清理测试数据

### 清理所有测试数据库
```bash
# Linux/Mac
./run_tests.sh --cleanup

# Windows
run_tests.bat --cleanup

# 或直接使用 SQL
docker exec -it clickhouse1 clickhouse-client --query "
DROP DATABASE IF EXISTS test_info_schema ON CLUSTER 'treasurycluster' SYNC;
DROP DATABASE IF EXISTS test_data_deletion ON CLUSTER 'treasurycluster' SYNC;
DROP DATABASE IF EXISTS test_date_time ON CLUSTER 'treasurycluster' SYNC;
"
```

## 📚 详细文档

- **[TEST_GUIDE.md](./TEST_GUIDE.md)** - 详细测试指南
- **[test_all_topics.sql](./test_all_topics.sql)** - 测试 SQL 文件
- **[README.md](./README.md)** - 项目主文档

## 💡 提示

1. **测试前检查**：确保集群正常运行
2. **测试后清理**：及时清理测试数据释放空间
3. **查看日志**：如有问题查看 `docker logs clickhouse1`
4. **分批测试**：可以单独测试某个专题
5. **监控性能**：测试时注意集群性能

## ⚠️ 注意事项

1. 测试需要在 `treasurycluster` 集群上运行
2. 测试会创建多个表和插入测试数据
3. Mutation 删除是异步的，需要等待完成
4. TTL 删除不是立即生效的，可能需要手动触发
5. 数据会在副本之间同步，需要一定时间

## 🔗 相关链接

- [ClickHouse 官方文档](https://clickhouse.com/docs)
- [ClickHouse GitHub](https://github.com/ClickHouse/ClickHouse)
- [Docker Hub](https://hub.docker.com/r/clickhouse/clickhouse-server)
