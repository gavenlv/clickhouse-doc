# DBT 与 ClickHouse 集成

DBT（data build tool）是数据工程领域的"事实标准"转换工具。dbt-clickhouse adapter 让你可以用 SQL SELECT + YAML 配置的方式管理 ClickHouse 中的表、视图和物化视图，享受版本控制、测试、文档生成和 CI/CD 的完整工程化能力。

## 目录

- [为什么用 DBT 管理 ClickHouse](#为什么用-dbt-管理-clickhouse)
- [dbt-clickhouse 安装与配置](#dbt-clickhouse-安装与配置)
- [项目结构与核心概念](#项目结构与核心概念)
- [物化策略深度对比](#物化策略深度对比)
- [ClickHouse 特有功能集成](#clickhouse-特有功能集成)
- [DBT 测试与文档](#dbt-测试与文档)
- [CI/CD 集成](#cicd-集成)
- [生产环境最佳实践](#生产环境最佳实践)

## 为什么用 DBT 管理 ClickHouse

### SQL 脚本 vs DBT 工程化

```
传统 SQL 脚本管理：
  ├── 01_create_table.sql
  ├── 02_create_mv.sql
  ├── 03_daily_aggregation.sql
  └── ...

  痛点：
  ✗ 不知道 03_daily_aggregation.sql 依赖 01_create_table.sql
  ✗ 不知道这个表有没有被其他脚本使用
  ✗ 改了一个表定义，不知道要同步更新哪些下游
  ✗ 上线靠手动执行 SQL，没有版本管理

DBT 管理：
  dbt_project/
  ├── models/
  │   ├── staging/       # 原始层
  │   │   └── stg_orders.sql
  │   ├── intermediate/  # 中间层
  │   │   └── int_daily_orders.sql
  │   └── marts/         # 应用层
  │       └── fct_daily_kpi.sql
  ├── tests/             # 数据质量测试
  └── macros/            # 可复用 Jinja 宏

  优势：
  ✓ 自动解析依赖：ref('stg_orders') → DBT 知道执行顺序
  ✓ 血缘图：dbt docs generate → 可视化数据血缘
  ✓ 测试：YAML 声明 NOT NULL / UNIQUE / 自定义 SQL 约束
  ✓ 版本管理：全部模型在 Git 仓库中
  ✓ CI/CD：dbt build → 自动跑依赖 → 测试 → 生成文档
```

### DBT vs ClickHouse 物化视图：何时用哪个

| 场景 | 推荐工具 | 原因 |
|------|---------|------|
| **实时数据转换**（毫秒-秒级） | ClickHouse MV | MV 在 INSERT 时自动触发，DBT 是调度触发 |
| **T+1 批处理转换**（小时-天级） | DBT | 版本管理、测试、文档一体化 |
| **预聚合（SUM/COUNT）** | ClickHouse MV | AggregatingMergeTree + MV 是最优解 |
| **复杂业务逻辑转换** | DBT | 多人协作、代码审查、可追溯 |
| **数据质量测试** | DBT | 内建测试框架，NOT NULL/UNIQUE/自定义 |
| **联邦查询（跨库）** | DBT | ClickHouse 的跨库 UNION ALL 处理 |
| **Schema 变更管理** | DBT | Git diff 可以看到所有变更 |

## dbt-clickhouse 安装与配置

### 安装

```bash
# Python 3.9+
pip install dbt-clickhouse

# 验证
dbt --version
```

### 项目初始化

```bash
# 创建项目
dbt init my_clickhouse_project

# 目录结构
my_clickhouse_project/
├── dbt_project.yml       # 项目配置（profile、模型路径、物化策略）
├── profiles.yml          # 连接配置（host、port、user、password）
├── models/               # 模型 SQL 文件
│   ├── staging/
│   ├── intermediate/
│   └── marts/
├── tests/                # 自定义测试
├── macros/               # Jinja 宏
├── analyses/             # 一次性分析查询
├── seeds/                # CSV 种子数据
└── snapshots/            # SCD Type 2 缓慢变化维度
```

### profiles.yml 配置

```yaml
# ~/.dbt/profiles.yml
my_clickhouse_project:
  target: dev
  outputs:
    dev:
      type: clickhouse
      schema: dbt_models        # 模型输出的默认数据库
      host: clickhouse1
      port: 8123
      user: dbt_user
      password: DbtPass123!
      secure: false
      # ClickHouse 特有配置
      driver: native            # 'native' or 'http'
      connect_timeout: 10
      send_receive_timeout: 300  # 5 分钟超时（大表创建需要）
      # 集群模式
      cluster: treasurycluster
      # 分布式表配置
      distributed_suffix: '_dist'
```

## 项目结构与核心概念

### dbt_project.yml 核心配置

```yaml
# dbt_project.yml
name: 'clickhouse_analytics'
version: '1.0.0'
profile: 'my_clickhouse_project'

# 模型路径配置
model-paths: ["models"]
analysis-paths: ["analyses"]
test-paths: ["tests"]
seed-paths: ["seeds"]
macro-paths: ["macros"]
snapshot-paths: ["snapshots"]

models:
  clickhouse_analytics:
    # staging 层：从原始表读取，物化为视图（轻量）
    staging:
      +materialized: view
      +schema: staging
    
    # intermediate 层：中间计算
    intermediate:
      +materialized: table
      +schema: intermediate
      +cluster: treasurycluster
    
    # marts 层：业务宽表
    marts:
      +materialized: table
      +schema: marts
      +cluster: treasurycluster
      +engine: "MergeTree()"
      +order_by: "(event_date, event_type)"

# 钩子（hooks）
on-run-start:
  - "{{ custom_start_hook() }}"
on-run-end:
  - "GRANT SELECT ON {{ this }} TO analyst_role"
```

### Jinja 模板核心用法

```sql
-- models/marts/fct_daily_orders.sql
{{
    config(
        materialized='table',
        engine='ReplicatedMergeTree()',
        order_by='(order_date, product_id)',
        partition_by="toYYYYMM(order_date)",
        ttl="order_date + INTERVAL 90 DAY"
    )
}}

WITH daily_stats AS (
    SELECT
        toDate(created_at) AS order_date,
        product_id,
        count() AS order_count,
        sum(amount) AS total_amount
    FROM {{ ref('stg_orders') }}       -- DBT 依赖引用
    WHERE created_at >= '{{ var("start_date", "2024-01-01") }}'
    GROUP BY order_date, product_id
)
SELECT
    d.order_date,
    d.product_id,
    d.order_count,
    d.total_amount,
    p.product_name,                    -- 从产品维度 JOIN
    p.category
FROM daily_stats d
LEFT JOIN {{ ref('dim_products') }} p
    ON d.product_id = p.product_id
```

### 数据血缘可视化

```bash
# 生成文档网站
dbt docs generate

# 启动文档服务
dbt docs serve --port 8080
# → 浏览器访问 http://localhost:8080
# → 可视化血缘图：stg_orders → int_daily_orders → fct_daily_kpi
```

## 物化策略深度对比

ClickHouse 支持的 6 种 DBT 物化方式：

| 物化方式 | ClickHouse 实现 | 更新策略 | 适用场景 |
|---------|----------------|---------|---------|
| **table** | `CREATE TABLE ... AS SELECT ...` | 全量重建（DROP + CREATE） | 数据量不大、每日全量刷新 |
| **view** | `CREATE VIEW ... AS SELECT ...` | 实时（不存数据） | 简单查询封装、联邦查询 |
| **incremental** | `INSERT INTO ... SELECT ... WHERE ...` | 增量追加 | 大表、按日期增量 |
| **materialized_view** | `CREATE MATERIALIZED VIEW ... TO ...` | INSERT 时自动触发 | 实时预聚合 |
| **ephemeral** | CTE（不创建对象） | 查询时展开 | 中间计算，不想建表 |
| **distributed** | `CREATE TABLE ... ENGINE = Distributed(...)` | 代理查询 | 集群分布式查询入口 |

### Incremental 增量模型

```sql
-- models/staging/stg_orders.sql
{{
    config(
        materialized='incremental',
        engine='MergeTree()',
        order_by='(order_id)',
        unique_key='order_id',          -- 去重键
        incremental_strategy='delete+insert'  -- 或 'append'
    )
}}

SELECT
    order_id,
    customer_id,
    amount,
    status,
    created_at
FROM {{ source('raw', 'orders') }}

{% if is_incremental() %}
-- 只处理昨天以来的新数据
WHERE created_at >= (SELECT max(created_at) FROM {{ this }})
{% endif %}
```

### ClickHouse MV 物化视图

```sql
-- models/intermediate/int_hourly_events.sql
{{
    config(
        materialized='materialized_view',
        target='events_agg',            -- 目标 AggregatingMergeTree 表
        engine='AggregatingMergeTree()',
        order_by='(event_hour, event_type)',
        partition_by="toYYYYMM(event_hour)"
    )
}}

SELECT
    toStartOfHour(event_time) AS event_hour,
    event_type,
    count() AS event_count
FROM {{ ref('raw_events') }}
GROUP BY event_hour, event_type
```

## ClickHouse 特有功能集成

### 字典（Dictionary）

```sql
-- macros/create_dictionary.sql
{% macro create_product_dict() %}
    {% set query %}
    CREATE DICTIONARY IF NOT EXISTS {{ target.schema }}.product_dict
    (
        product_id String,
        product_name String,
        category String,
        price Decimal(18, 2)
    )
    PRIMARY KEY product_id
    SOURCE(CLICKHOUSE(
        HOST '{{ env_var("CH_HOST") }}'
        PORT 9000
        USER '{{ env_var("CH_USER") }}'
        PASSWORD '{{ env_var("CH_PASSWORD") }}'
        DATABASE '{{ target.schema }}'
        TABLE 'products'
    ))
    LIFETIME(MIN 1 MAX 3600)
    LAYOUT(HASHED());
    {% endset %}
    
    {% do run_query(query) %}
{% endmacro %}
```

### TTL 配置

```sql
-- models/staging/stg_events_with_ttl.sql
{{
    config(
        materialized='table',
        engine="MergeTree()",
        order_by='(event_time, event_type)',
        partition_by="toYYYYMM(event_time)",
        -- 90 天后自动清理数据
        ttl="event_time + INTERVAL 90 DAY DELETE"
    )
}}

SELECT * FROM {{ source('raw', 'events') }}
```

### CODEC 压缩配置

```sql
-- Column-level codec configuration via DBT
{{
    config(
        materialized='table',
        engine="MergeTree()",
        order_by='(user_id, event_time)'
    )
}}

SELECT
    user_id,
    event_time,
    event_type,
    -- DBT 支持列级注释（用于文档生成）
    -- 压缩配置在 SQL 中直接用 CODEC 函数
    -- 如需列级 CODEC，在 pre-hook 中执行 ALTER TABLE
    properties
FROM {{ source('raw', 'events') }}
```

## DBT 测试与文档

### Schema 测试（YAML 配置）

```yaml
# models/staging/schema.yml
version: 2

models:
  - name: stg_orders
    description: "从原始订单表清洗后的订单模型"
    columns:
      - name: order_id
        description: "订单ID（主键）"
        tests:
          - unique
          - not_null
      
      - name: amount
        description: "订单金额（元）"
        tests:
          - not_null
          - accepted_values:
              values: [0.01, 999999]          # 可被接受的取值范围（Min/Max形式）
      
      - name: status
        tests:
          - not_null
          - accepted_values:
              values: ['pending', 'completed', 'cancelled', 'refunded']
      
      - name: created_at
        tests:
          - not_null

  - name: stg_events
    description: "用户行为事件表"
    columns:
      - name: event_time
        tests:
          - dbt_utils.expression:
              expression: "event_time >= '2020-01-01'"
              # 事件时间不能早于系统上线时间
```

### 自定义 SQL 测试

```sql
-- tests/assert_positive_amount.sql
SELECT
    order_id,
    amount
FROM {{ ref('stg_orders') }}
WHERE amount <= 0

-- 如果返回任何行，测试失败

-- tests/assert_no_future_events.sql
SELECT
    event_id,
    event_time
FROM {{ ref('stg_events') }}
WHERE event_time > now()

-- 确保没有未来时间的事件
```

### 运行测试

```bash
# 运行所有测试
dbt test

# 只测试特定模型
dbt test --select stg_orders

# 构建 + 测试（推荐管线）
dbt build --select +fct_daily_kpi
```

## CI/CD 集成

### GitHub Actions 示例

```yaml
# .github/workflows/dbt_ci.yml
name: DBT CI/CD

on:
  pull_request:
    paths:
      - 'dbt/**'
  push:
    branches: [main]

jobs:
  dbt-build:
    runs-on: ubuntu-latest
    services:
      clickhouse:
        image: clickhouse/clickhouse-server:latest
        ports:
          - 8123:8123
          - 9000:9000
    steps:
      - uses: actions/checkout@v3
      
      - name: Setup Python
        uses: actions/setup-python@v4
        with:
          python-version: '3.11'
      
      - name: Install DBT
        run: pip install dbt-clickhouse
      
      - name: Run DBT
        run: |
          cd dbt/
          dbt deps              # 安装依赖包
          dbt build             # 构建 + 测试
          dbt docs generate     # 生成文档
      
      - name: Upload docs
        uses: actions/upload-artifact@v3
        with:
          name: dbt-docs
          path: dbt/target/
```

### Airflow 调度集成

```python
# dags/dbt_clickhouse_daily.py
from airflow import DAG
from airflow.operators.bash import BashOperator
from datetime import datetime, timedelta

default_args = {
    'owner': 'data_team',
    'retries': 1,
    'retry_delay': timedelta(minutes=5),
}

with DAG(
    dag_id='dbt_clickhouse_daily',
    start_date=datetime(2024, 1, 1),
    schedule_interval='0 3 * * *',    # 每天凌晨 3 点
    default_args=default_args,
    catchup=False,
) as dag:
    
    dbt_run = BashOperator(
        task_id='dbt_run',
        bash_command='cd /opt/airflow/dbt && dbt run --profiles-dir .'
    )
    
    dbt_test = BashOperator(
        task_id='dbt_test',
        bash_command='cd /opt/airflow/dbt && dbt test --profiles-dir .'
    )
    
    dbt_docs = BashOperator(
        task_id='dbt_docs_generate',
        bash_command='cd /opt/airflow/dbt && dbt docs generate --profiles-dir .'
    )
    
    dbt_run >> dbt_test >> dbt_docs
```

## 生产环境最佳实践

### 目录分层约定

```
models/
├── sources.yml              # 数据源定义（外部表）
├── staging/                  # STG 层：从原始表 1:1 映射
│   ├── stg_orders.sql
│   └── stg_orders.yml       # 测试 + 文档
├── intermediate/             # MID 层：通用中间计算
│   ├── int_daily_metrics.sql
│   └── int_user_sessions.sql
└── marts/                    # DM 层：业务宽表/指标
    ├── finance/
    │   └── fct_revenue.sql
    ├── marketing/
    │   └── fct_campaign_performance.sql
    └── product/
        └── fct_user_retention.sql
```

### ClickHouse 特有最佳实践

1. **大表用 incremental**：全量表每天重建在 CH 中开销极大，增量写入 + MergeTree 合并是标准模式
2. **MV 不走 DBT schedule**：ClickHouse 物化视图是 INSERT 触发，不应放入 DBT 定时调度
3. **字典用宏管理**：将字典创建封装为 DBT macro，纳入版本管理
4. **测试关注数据质量**：ClickHouse 的 real-time ingestion 容易产生脏数据，DBT 测试是第一道防线
5. **Cluster 参数谨慎设**：`dbt run` 在集群模式下会在每个节点执行 DDL，生产环境先用 `--select` 在单节点验证
6. **On-run-end hook 自动赋权**：每次构建后自动 `GRANT SELECT`，避免权限遗忘

### 常见命令

```bash
# 日常开发
dbt run                          # 运行所有模型
dbt run --select stg_orders+     # 运行 stg_orders 及其下游
dbt run --select +fct_revenue    # 运行 fct_revenue 及其上游
dbt test                         # 运行所有测试
dbt build                        # run + test 连贯执行

# 调试
dbt compile                      # 编译 Jinja → SQL（不执行）
dbt debug                        # 检查数据库连接

# 文档
dbt docs generate                # 生成文档网站
dbt docs serve                   # 本地预览

# 生产
dbt run --full-refresh           # 强制全量重建（忽略 incremental）
dbt source freshness             # 检查源数据新鲜度
```

## 相关文档

- [点击前往集成引擎基础](./01_integration_engines.sql) —— ClickHouse 集成引擎总览
- [点击前往批量导入指南](./11_bulk_import_guide.md) —— Parquet/GCS 大规模导入与 DBT 的配合
- [点击前往 ClickHouse Cloud 指南](./20_clickhouse_cloud.md) —— DBT + ClickHouse Cloud 集成
- [dbt-clickhouse 官方文档](https://github.com/ClickHouse/dbt-clickhouse)
- [DBT 官方文档](https://docs.getdbt.com/)
