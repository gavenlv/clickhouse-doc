# ClickHouse Local

ClickHouse Local（`clickhouse-local`）是 ClickHouse 中一个被低估的利器——它让你无需启动 ClickHouse 服务进程，直接在命令行分析本地文件。它是一个"可执行的分析引擎"，专门用于数据探查、ETL 预处理、日志分析和 Shell 管道处理。

## 目录

- [什么是 ClickHouse Local](#什么是-clickhouse-local)
- [clickhouse-local vs clickhouse-client](#clickhouse-local-vs-clickhouse-client)
- [安装与基本使用](#安装与基本使用)
- [支持的文件格式](#支持的文件格式)
- [管道模式与 Shell 集成](#管道模式与-shell-集成)
- [典型使用场景](#典型使用场景)
- [性能特性与限制](#性能特性与限制)

## 什么是 ClickHouse Local

### 一句话定义

**`clickhouse-local` 是一个独立的进程，内嵌了完整的 ClickHouse SQL 查询引擎（含 MergeTree 等表引擎），但不需要 ClickHouse Server，不依赖任何外部进程。**

```
clickhouse-local 的工作流程：

  输入文件（CSV/Parquet/JSON...）
      ↓
  clickhouse-local 进程
  ├── 内嵌 ClickHouse 查询引擎
  ├── 内嵌 MergeTree / Memory 表引擎
  ├── 完整的 SQL 解析与优化
  └── 向量化执行
      ↓
  输出结果（stdout / 文件）
```

### 核心特性

| 特性 | 说明 |
|------|------|
| **零配置** | 无需 config.xml、users.xml、Keeper 集群。命令行即用 |
| **内嵌引擎** | 内嵌 MergeTree、Memory、File 等表引擎，完整 SQL 支持 |
| **文件直达** | 可以直接用 `file()` / `s3()` 表函数查询，无需提前建表 |
| **管道友好** | `stdin` → SQL 分析 → `stdout`，Shell 管道的天然搭档 |
| **单进程** | 启动快（<1 秒），退出即释放所有资源 |
| **无状态** | 不持久化数据，每次运行独立 |

## clickhouse-local vs clickhouse-client

| 维度 | clickhouse-local | clickhouse-client |
|------|-----------------|-------------------|
| **需要服务端？** | 不需要，自己就是执行引擎 | 需要连接 ClickHouse Server |
| **数据存哪里？** | 内存 / 临时目录（进程结束清除） | ClickHouse Server 的数据目录 |
| **启动时间** | < 1 秒 | 客户端 < 1 秒；服务端 10-30s |
| **适用场景** | 文件分析、ETL 预处理 | 生产查询、数据管理 |
| **SQL 能力** | 100%（同一套引擎） | 100% |
| **并发** | 单进程，无并发 | 服务端天然并发 |
| **表引擎** | Memory / MergeTree / File / URL / S3 等 | 所有引擎 |
| **DDL** | 支持 CREATE TABLE 等（临时） | 持久化 DDL |

## 安装与基本使用

### 安装

```bash
# Linux (DEB)
apt-get install clickhouse-client
# clickhouse-local 随 clickhouse-client 包一起安装

# Linux (RPM)  
yum install clickhouse-client

# macOS
brew install clickhouse

# 验证
clickhouse-local --version
```

### 基本语法

```bash
# 最简形式：单行 SQL
clickhouse-local --query "SELECT 1 + 1"

# 查询 CSV 文件
clickhouse-local --query "
    SELECT 
        count() AS total_rows,
        uniq(user_id) AS unique_users,
        avg(amount) AS avg_amount
    FROM file('sales.csv', 'CSV', 'date Date, user_id UInt64, product String, amount Decimal(18,2)')
" 

# 带输入输出格式
clickhouse-local \
    --input-format CSVWithNames \
    --output-format JSONEachRow \
    --query "SELECT * FROM table WHERE amount > 100" \
    < input.csv > output.json
```

### 常用参数

| 参数 | 说明 | 示例 |
|------|------|------|
| `--query` / `-q` | 执行的 SQL | `-q "SELECT count() FROM table"` |
| `--input-format` | 输入格式（stdin 的数据格式） | `--input-format CSV` |
| `--output-format` | 输出格式（stdout 的数据格式） | `--output-format JSONEachRow` |
| `--structure` | 表结构定义（简写，用于 stdin） | `--structure "a UInt64, b String"` |
| `--table` | 表函数路径（包含格式和结构） | `--table "file('data.csv')"` |
| `--file` / `-N` | SQL 从文件读取 | `-N analyze.sql` |
| `--path` | 临时数据目录 | `--path /tmp/ch_local` |

## 支持的文件格式

### 输入格式

| 格式 | 文件类型 | 适用场景 |
|------|---------|---------|
| **CSV / CSVWithNames** | 文本 | 通用表格数据 |
| **TSV / TSVWithNames** | 文本 | Tab 分隔文件 |
| **JSONEachRow** | 文本 | 一行一条 JSON |
| **JSONAsString** | 文本 | 整行作为一个 String 列 |
| **Parquet** | 二进制 | 大数据、列式存储 |
| **Native** | 二进制 | ClickHouse 原生格式（最快） |
| **LineAsString** | 文本 | 每行作为单列字符串 |
| **Regexp** | 文本 | 正则表达式解析非结构化文本 |

### 输出格式

| 格式 | 用途 |
|------|------|
| **Pretty / PrettyCompact** | 人类阅读 |
| **CSV / TSV** | 导出到 Excel / 其他工具 |
| **JSONEachRow** | API 返回 / jq 管道 |
| **Parquet** | 归档 / 下一级处理 |
| **TabSeparatedRaw** | 纯文本管道 |
| **Vertical** | 宽表逐列展示 |
| **Markdown** | 直接粘贴到文档 |

## 管道模式与 Shell 集成

### 基础管道

```bash
# cat → clickhouse-local → 分析结果
cat nginx.log | clickhouse-local \
    --input-format Regexp \
    --structure "ip String, time DateTime, method String, url String, status UInt16, size UInt64" \
    --query "
        SELECT 
            status,
            count() AS cnt,
            round(cnt * 100.0 / sum(cnt) OVER (), 2) AS pct
        FROM table
        GROUP BY status
        ORDER BY cnt DESC
    " \
    --output-format PrettyCompact

# 输出：
# ┌─status─┬────cnt─┬───pct─┐
# │    200 │ 452389 │ 85.23 │
# │    404 │  45823 │  8.63 │
# │    500 │  18523 │  3.49 │
# │    301 │  13982 │  2.63 │
# └────────┴────────┴───────┘
```

### 多步骤管道

```bash
# Step 1: 数据清洗
# Step 2: 聚合分析
# Step 3: 格式化输出

cat raw_events.log \
| clickhouse-local -q "
    SELECT 
        toDate(parseDateTimeBestEffort(replaceAll(line, '^([^,]*),', ''))) AS date,
        line
    FROM table
    FORMAT TSV
" \
| clickhouse-local \
    --input-format TSV \
    --structure "date Date, line String" \
    -q "
    SELECT 
        date,
        count() AS events
    FROM table
    WHERE date >= today() - 30
    GROUP BY date
    ORDER BY date
    "
```

### Shell 脚本集成

```bash
#!/bin/bash
# 每天凌晨分析昨天的 nginx 日志并输出报告

YESTERDAY=$(date -d "yesterday" +%Y-%m-%d)
LOG_FILE="/var/log/nginx/access.log.${YESTERDAY}"

if [ ! -f "$LOG_FILE" ]; then
    echo "No log file for $YESTERDAY"
    exit 1
fi

cat "$LOG_FILE" | clickhouse-local \
    --input-format Regexp \
    --structure 'ip String, time DateTime, method String, url String, status UInt16, size UInt64' \
    --query "
    SELECT
        status,
        count() AS requests,
        formatReadableSize(sum(size)) AS bandwidth,
        avg(size) AS avg_response_size
    FROM table
    GROUP BY status
    ORDER BY requests DESC
    FORMAT PrettyCompact
    "

# 输出慢请求 Top 10
cat "$LOG_FILE" | clickhouse-local \
    --input-format Regexp \
    --structure 'ip String, time DateTime, method String, url String, status UInt16, size UInt64, response_time Float64' \
    --query "
    SELECT * FROM table
    WHERE response_time > 1.0
    ORDER BY response_time DESC
    LIMIT 10
    FORMAT Vertical
    "
```

## 典型使用场景

### 场景 1：数据探查

```bash
# 快速查看 CSV 的前 10 行 + 统计信息
clickhouse-local -q "
    SELECT 
        '前10行' AS info, * 
    FROM file('unknown_file.csv', 'CSV', 'col1 String, col2 String, col3 String')
    LIMIT 10
    UNION ALL
    SELECT 
        '总行数' AS info, 
        toString(count()), '', ''
    FROM file('unknown_file.csv', 'CSV', 'col1 String, col2 String, col3 String')
    FORMAT PrettyCompact
"
```

### 场景 2：ETL 预处理

```bash
# 清洗 JSON 日志 → 输出 Parquet
# 原始日志：每行一个 JSON 对象，字段不规范
# 目标：结构化 Parquet，字段类型正确

cat messy_events.jsonl | clickhouse-local \
    --input-format JSONEachRow \
    --structure "ts String, uid String, action String, metadata String" \
    --query "
    SELECT
        parseDateTimeBestEffort(ts) AS event_time,
        toUInt64OrZero(uid) AS user_id,
        action AS event_type,
        -- 从 metadata 中提取关键字段
        JSONExtractString(metadata, 'browser') AS browser,
        JSONExtractFloat(metadata, 'duration') AS duration_ms,
        now() AS processed_at
    FROM table
    WHERE user_id > 0 AND event_time >= '2024-01-01'
    " \
    --output-format Parquet > clean_events.parquet
```

### 场景 3：日志分析

```bash
# 分析 ClickHouse 自己生成的 JSON 日志
cat /var/log/clickhouse-server/clickhouse-server.log | grep '"type":"QueryFinish"' | \
clickhouse-local \
    --input-format JSONAsString \
    --query "
    SELECT 
        JSONExtractString(json, 'query_id') AS query_id,
        JSONExtractString(json, 'user') AS user,
        toFloat64(JSONExtractString(json, 'query_duration_ms')) / 1000 AS duration_sec,
        JSONExtractUInt(json, 'read_rows') AS read_rows,
        formatReadableSize(JSONExtractUInt(json, 'memory_usage')) AS memory
    FROM table
    WHERE duration_sec > 10
    ORDER BY duration_sec DESC
    LIMIT 20
    FORMAT PrettyCompact
    "
```

### 场景 4：快速聚合多个文件

```bash
# 把 30 天的 CSV 分区合并为一个 Parquet
clickhouse-local -q "
    SELECT * FROM file('data_*.csv', 'CSVWithNames')
    ORDER BY date, user_id
    " --output-format Parquet > merged.parquet
```

### 场景 5：数据格式转换

```bash
# CSV → JSONEachRow
clickhouse-local \
    --input-format CSVWithNames \
    --output-format JSONEachRow \
    -q "SELECT * FROM table" \
    < input.csv > output.jsonl

# JSONEachRow → Parquet
clickhouse-local \
    --input-format JSONEachRow \
    --output-format Parquet \
    -q "SELECT * FROM table" \
    < input.jsonl > output.parquet

# 查看 Parquet 的 Schema（不用 Spark/Arrow）
clickhouse-local -q "
    DESCRIBE TABLE file('data.parquet')
    FORMAT PrettyCompact
"
```

## 性能特性与限制

### 性能优势

| 特性 | 说明 |
|------|------|
| **向量化执行** | 与 ClickHouse Server 相同的向量化引擎 |
| **并行读取** | 多个 Parquet/CSV 文件可并行读取 |
| **零拷贝** | stdin/stdout 管道，无磁盘 IO |
| **压缩感知** | 直接读取 gzip/bzip2/zstd 压缩文件 |

### 已知限制

| 限制 | 说明 | 绕过方式 |
|------|------|---------|
| **无 ReplicatedMergeTree** | 单进程，没有分布式能力 | 用 `--path` 指定持久化目录模拟 |
| **无 Keeper** | 无分布式协调 | 单机场景用 `--path` |
| **数据不持久化** | 进程结束数据丢失 | 用 `--path` 指定持久化目录 |
| **无 HTTP 接口** | 只能命令行调用 | 用 Shell 脚本包装为 API |
| **单进程** | 无并发处理能力 | 用 GNU parallel 或 xargs 并行化 |

### 持久化模式

```bash
# 用 --path 指定数据目录，数据在多次调用间保留
clickhouse-local \
    --path /tmp/ch_local_store \
    -q "
    CREATE TABLE IF NOT EXISTS persistent_data (
        date Date,
        user_id UInt64,
        value Float64
    ) ENGINE = MergeTree()
    ORDER BY (date, user_id);
    
    INSERT INTO persistent_data
    SELECT toDate(today()), number, rand()
    FROM numbers(1000);
    "

# 后续可以查询持久化表中的数据
clickhouse-local \
    --path /tmp/ch_local_store \
    -q "SELECT count() FROM persistent_data"
```

## 相关文档

- [点击前往集成引擎基础](./01_integration_engines.sql) —— file()/s3()/hdfs() 表函数
- [点击前往批量导入指南](./11_bulk_import_guide.md) —— clickhouse-local 在 ETL 管道中的应用
- [ClickHouse Local 官方文档](https://clickhouse.com/docs/en/operations/utilities/clickhouse-local)
