-- ================================================================================
-- 20 - Superset 语义层与数据可视化设计
-- ================================================================================
-- 
-- 预计学习时间: 45 分钟
-- 
-- 本文件涵盖:
--   1. Superset 数据源连接 - ClickHouse 直连 + 性能调优
--   2. 虚拟数据集 (Virtual Dataset) - 不落地,直接消费 ClickHouse 视图
--   3. 物理数据集 (Physical Dataset) - 高频看板缓存
--   4. 指标字典 (Metrics) - 统一口径,避免重复定义
--   5. 看板设计模式 - KPI 卡 / 趋势图 / 漏斗 / 排行榜
--   6. 缓存策略 - 减少 ClickHouse 压力
--   7. 行级权限 - 多租户看板
--   8. 嵌入式分析 - 把看板嵌到业务系统
-- 
-- 📌 进阶阅读:
--   本章讲"看板怎么搭",但没讲"用户看汇总后想看明细怎么办"。详见:
--     - 09_superset_drill_down.md  - 4 种下钻机制(Cross-Filter / Drill-to-Detail / Drill-Through / URL Parameter)
--                                - ClickHouse 侧明细数据准备 3 种策略
--                                - Jinja 模板 / 行级权限 / 性能优化
-- 
-- ┌─────────────────────────────────────────────────────────────────────────────┐
-- │                    Superset 在架构中的定位                                    │
-- ├─────────────────────────────────────────────────────────────────────────────┤
-- │                                                                             │
-- │   ClickHouse (存储)        Superset (语义层)         业务用户                │
-- │  ┌─────────────┐         ┌──────────────┐         ┌──────────┐            │
-- │  │  ADS 视图   │         │  Virtual     │         │          │            │
-- │  │  DWS 物化   │────────►│  Dataset     │────────►│  看板   │            │
-- │  │  字典       │  SQL查询  │  + Metrics   │  拖拽   │  图表   │            │
-- │  └─────────────┘         └──────────────┘         │  报表   │            │
-- │                                │                  └──────────┘            │
-- │                                ▼                                          │
-- │                         ┌──────────────┐                                  │
-- │                         │  Cache       │                                  │
-- │                         │  (Redis)     │                                  │
-- │                         └──────────────┘                                  │
-- │                                                                             │
-- │  Why 不用 Superset 算指标?                                                  │
-- │    - 性能差(每查必算,无法复用)                                              │
-- │    - 口径不一致(同一指标不同人算结果不同)                                    │
-- │    - 数据库压力大(BI 把数据库跑死)                                          │
-- │                                                                             │
-- │  正确做法:                                                                 │
-- │    - 90% 指标在 ClickHouse 计算(物化视图/视图)                              │
-- │    - Superset 只做最后一步 SELECT + 可视化                                   │
-- │    - 10% 临时分析可以用 Adhoc 模式                                          │
-- │                                                                             │
-- └─────────────────────────────────────────────────────────────────────────────┘
-- ================================================================================

-- ========================================
-- 1. 数据源连接(Superset UI 配置)
-- ========================================
/*
 * Connections → Databases → + DATABASE
 * 
 * ┌─────────────────────────────────────────────────────────────────┐
 * │  Database Connection: ClickHouse                                 │
 * ├─────────────────────────────────────────────────────────────────┤
 * │  SQLAlchemy URI:                                                │
 * │    clickhouse://default:password@clickhouse1:8123/realtime_olap │
 * │                                                                 │
 * │  Expose in SQL Lab:        ☑ Yes (允许 SQL Lab 查询)            │
 * │  Allow CSV Upload:         ☐ No  (生产建议关闭)                 │
 * │  Allow Multi Schema:       ☑ Yes                                │
 * │  Database Name:            ClickHouse Realtime                  │
 * │                                                                 │
 * │  [Advanced] → Performance Settings:                            │
 * │    - Engine:                ClickHouse (官方驱动)               │
 * │    - Method:                HTTP (默认)                         │
 * │    - Timeout:               60s                                │
 * │    - Username/Password:     default / *****                    │
 * └─────────────────────────────────────────────────────────────────┘
 * 
 * Why 用 HTTP 而非 Native 协议?
 *   - HTTP 兼容性好(代理、负载均衡友好)
 *   - Native 性能略高(15-20%),但配置复杂
 *   - 生产环境 90% 场景用 HTTP 就够了
 * 
 * 高级:多节点连接(负载均衡)
 *   clickhouse://default:password@clickhouse1:8123,clickhouse2:8123,clickhouse3:8123/realtime_olap?load_balancing=random
 * 
 * Why?
 *   - Superset 端连接池分散到多节点
 *   - 避免单节点连接数过多
 *   - random / in_order / first_or_random 三种策略
 */

-- ========================================
-- 2. 虚拟数据集 (Virtual Dataset) - 推荐模式
-- ========================================
/*
 * 核心思想: 在 Superset 中创建 "虚拟表" 指向 ClickHouse 视图
 * 
 * 优点:
 *   - 不落地数据(直接消费 ClickHouse 视图,零延迟)
 *   - 灵活性高(随时修改 SQL)
 *   - 无存储成本
 * 
 * 缺点:
 *   - 性能依赖 ClickHouse 视图效率
 *   - 不能做复杂的 ETL 逻辑
 * 
 * 适用: 90% 的看板场景
 */

-- 2.1 在 ClickHouse 中创建分析视图(基础)
-- 这是 Superset 虚拟数据集直接消费的 SQL 模板

CREATE VIEW IF NOT EXISTS realtime_olap.v_superset_gmv_dashboard ON CLUSTER 'treasurycluster' AS
SELECT
    -- 时间维度
    toDate(order_time)                                   AS dt,
    toYear(order_time)                                   AS year,
    toQuarter(order_time)                                AS quarter,
    toMonth(order_time)                                  AS month,
    toDateTime(toStartOfHour(order_time))                AS hour,
    
    -- 业务维度
    region_code,
    product_category,
    product_brand,
    channel,
    user_tier,
    user_age_group,
    order_status,
    pay_method,
    
    -- 核心指标(在 ClickHouse 端聚合,Superset 只做最后 SELECT)
    order_id,
    user_id,
    order_amount,
    pay_amount,
    discount_amount,
    
    -- 派生指标(可选,简单计算)
    pay_amount - discount_amount                         AS net_amount,
    if(order_amount > 0, discount_amount / order_amount, 0) AS discount_rate
FROM realtime_olap.dwd_order
WHERE is_valid = 1
  AND order_time >= today() - INTERVAL 90 DAY;  -- 只查近 90 天,加速查询

-- Why 视图加 WHERE 过滤?
--   - Superset 看板通常只看近期数据
--   - 视图里加时间过滤,Superset 查询时自动带
--   - 减少 99% 扫描量

-- 2.2 Superset 中创建虚拟数据集
/*
 * Data → Datasets → + DATASET
 * 
 * ┌─────────────────────────────────────────────────────────────────┐
 * │  New Dataset                                                      │
 * ├─────────────────────────────────────────────────────────────────┤
 * │  Database:        ClickHouse Realtime                            │
 * │  Schema:          realtime_olap                                 │
 * │  Table:           v_superset_gmv_dashboard                       │
 * │  [OR] Use SQL:    ☑ Yes                                         │
 * │                                                                 │
 * │  SQL:                                                             │
 * │    SELECT * FROM realtime_olap.v_superset_gmv_dashboard         │
 * │    WHERE {{ time_range }}  -- Superset Jinja 宏                  │
 * │    {{ filter_where }}       -- 通用过滤宏                         │
 * │                                                                 │
 * │  [Save]                                                          │
 * └─────────────────────────────────────────────────────────────────┘
 * 
 * Why 用 Jinja 宏?
 *   - {{ time_range }}: 自动注入时间范围(看板级)
 *   - {{ filter_where }}: 自动注入用户筛选条件
 *   - {{ url_param('xxx') }}: 取 URL 参数
 *   - 避免在 Superset 端做复杂 SQL
 */

-- 2.3 高级虚拟数据集 - 多表 JOIN
-- 
-- 场景: GMV 看板需要关联用户名称
-- 原则: JOIN 提前在 ClickHouse 端做,Superset 只 SELECT

CREATE VIEW IF NOT EXISTS realtime_olap.v_superset_gmv_with_user ON CLUSTER 'treasurycluster' AS
SELECT
    o.* EXCEPT (etl_time),
    u.user_name,
    u.register_time,
    dateDiff('year', u.register_time, o.order_time) AS user_age_years
FROM realtime_olap.dwd_order o
LEFT JOIN realtime_olap.dim_user u ON o.user_id = u.user_id
WHERE o.is_valid = 1
  AND o.order_time >= today() - INTERVAL 365 DAY;

-- ========================================
-- 3. 物理数据集 (Physical Dataset) - 高频看板
-- ========================================
/*
 * 场景: 实时大屏,每 5 秒刷新一次,100 个用户同时查看
 * 
 * 问题:
 *   - 直接查 ClickHouse 视图 → 100 个并发查询 → 数据库压力大
 *   - 看板慢(每次都重新计算)
 * 
 * 解决方案: 物化视图(在 ClickHouse 端)
 *   - 把高频看板需要的预聚合数据落地
 *   - 看板直接查聚合表(秒级响应)
 *   - 物化视图自动增量更新
 */

-- 3.1 实时大屏专用聚合表(分钟级)

CREATE TABLE IF NOT EXISTS realtime_olap.ads_realtime_dashboard ON CLUSTER 'treasurycluster' (
    -- 维度
    minute         DateTime,
    region_code    LowCardinality(String),
    channel        LowCardinality(String),
    product_category LowCardinality(String),
    
    -- 指标
    gmv            Decimal(18, 2),
    order_cnt      UInt32,
    pay_cnt        UInt32,
    pay_user_cnt   AggregateFunction(uniq, UInt64),
    new_user_cnt   AggregateFunction(uniq, UInt64)
) ENGINE = ReplicatedAggregatingMergeTree(
    '/clickhouse/tables/{shard}/realtime_olap/ads_realtime_dashboard',
    '{replica}'
)
PARTITION BY toYYYYMM(minute)
ORDER BY (minute, region_code, channel, product_category)
TTL minute + INTERVAL 7 DAY  -- 大屏数据只保留 7 天
SETTINGS index_granularity = 8192;

-- 物化视图:从 DWD 自动聚合
CREATE MATERIALIZED VIEW IF NOT EXISTS realtime_olap.mv_ads_realtime_dashboard
ON CLUSTER 'treasurycluster'
TO realtime_olap.ads_realtime_dashboard AS
SELECT
    toStartOfMinute(order_time)    AS minute,
    region_code,
    channel,
    product_category,
    
    sumSimpleState(order_amount)   AS gmv,
    sumSimpleState(1)               AS order_cnt,
    sumSimpleState(if(order_status IN ('paid','shipped','completed'), 1, 0)) AS pay_cnt,
    uniqState(user_id)             AS pay_user_cnt,
    uniqState(user_id)             AS new_user_cnt
FROM realtime_olap.dwd_order
WHERE is_valid = 1
GROUP BY minute, region_code, channel, product_category;

-- 3.2 Superset 端查询(直接用 -Merge 函数)
CREATE VIEW IF NOT EXISTS realtime_olap.v_superset_realtime_dashboard ON CLUSTER 'treasurycluster' AS
SELECT
    minute,
    region_code,
    channel,
    product_category,
    
    sum(gmv)         AS gmv,
    sum(order_cnt)   AS order_cnt,
    sum(pay_cnt)     AS pay_cnt,
    uniqMerge(pay_user_cnt)   AS pay_user_cnt,
    uniqMerge(new_user_cnt)   AS new_user_cnt
FROM realtime_olap.ads_realtime_dashboard
WHERE minute >= now() - INTERVAL 1 HOUR
GROUP BY minute, region_code, channel, product_category;

-- Why 用物化视图?
--   - 写入 DWD 时自动触发,延迟 < 1 秒
--   - 看板查询走聚合表(亚秒级)
--   - 100 个并发用户查询,只触发 1 次聚合计算
--   - ClickHouse CPU 降低 80%

-- ========================================
-- 4. 指标字典 (Metrics) - 统一口径
-- ========================================
/*
 * 痛点: 
 *   - "GMV" 到底怎么算?包不包含退款?包不包含运费?
 *   - 分析师 A 和 B 算出来的结果不一样
 *   - 老板说"你给我算的跟财务不一样"
 * 
 * 解决方案:
 *   - 在 ClickHouse 端定义统一视图
 *   - 在 Superset 端配置"指标列"
 *   - 所有看板引用同一份定义
 */

-- 4.1 ClickHouse 端 - 统一指标视图

CREATE VIEW IF NOT EXISTS realtime_olap.v_metrics_standard ON CLUSTER 'treasurycluster' AS
SELECT
    -- 时间维度
    toDate(order_time)                          AS dt,
    region_code,
    channel,
    product_category,
    
    -- ==================== 核心指标(统一定义) ====================
    
    -- GMV (Gross Merchandise Volume) = 总订单金额
    -- 包含: 已支付 + 未支付 (只要下单就算)
    sum(order_amount)                           AS gmv,
    
    -- 有效 GMV (剔除非正常订单)
    -- 包含: 已支付/已发货/已完成 (剔除已取消/已退款)
    sumIf(order_amount, order_status NOT IN ('cancelled', 'refunded')) AS valid_gmv,
    
    -- 销售额 (Sales) = 实际支付金额
    sumIf(pay_amount, order_status IN ('paid', 'shipped', 'completed', 'refunded')) AS sales,
    
    -- 退款金额
    sumIf(pay_amount, order_status = 'refunded') AS refund_amount,
    
    -- 订单数
    count()                                     AS order_cnt,
    countIf(order_status NOT IN ('cancelled', 'refunded')) AS valid_order_cnt,
    countIf(order_status IN ('paid', 'shipped', 'completed', 'refunded')) AS pay_order_cnt,
    
    -- 用户数
    uniq(user_id)                               AS user_cnt,
    uniqIf(user_id, order_status IN ('paid', 'shipped', 'completed', 'refunded')) AS pay_user_cnt,
    uniqIf(user_id, is_new_user = 1)            AS new_user_cnt,
    
    -- 客单价 (AOV - Average Order Value)
    if(count() > 0, sum(order_amount) / count(), 0) AS aov,
    
    -- 转化率(下单 → 支付)
    if(count() > 0, 
       countIf(order_status IN ('paid', 'shipped', 'completed', 'refunded')) / count(), 
       0)                                       AS conversion_rate,
    
    -- 笔单价
    if(countIf(order_status IN ('paid', 'shipped', 'completed', 'refunded')) > 0,
       sumIf(order_amount, order_status IN ('paid', 'shipped', 'completed', 'refunded')) 
       / countIf(order_status IN ('paid', 'shipped', 'completed', 'refunded')),
       0)                                       AS avg_pay_amount

FROM realtime_olap.dwd_order
WHERE is_valid = 1
  AND order_time >= today() - INTERVAL 365 DAY
GROUP BY dt, region_code, channel, product_category;

-- Why 在 ClickHouse 端定义指标?
--   - 一次定义,所有看板使用
--   - 修改定义时只改一处
--   - 财务/业务/技术三方对账有据可依
--   - Superset 配置只需 SUM 一下,不再写复杂表达式

-- 4.2 Superset 端 - 指标列配置
/*
 * Data → Datasets → v_metrics_standard → Columns → 编辑
 * 
 * ┌─────────────────────────────────────────────────────────────────┐
 * │  Column: gmv                                                      │
 * ├─────────────────────────────────────────────────────────────────┤
 * │  Type:        Metric (不是 Dimension)                            │
 * │  Expression:  SUM(gmv)                                          │
 * │  Description: GMV - 总订单金额(包含已支付+未支付)                  │
 * │  Format:      $#,###.##                                          │
 * │  Is Certified: ☑ (标记为标准指标)                                 │
 * └─────────────────────────────────────────────────────────────────┘
 * 
 * ┌─────────────────────────────────────────────────────────────────┐
 * │  Column: sales                                                   │
 * ├─────────────────────────────────────────────────────────────────┤
 * │  Expression:  SUM(sales)                                        │
 * │  Description: 销售额 - 实际支付金额(已支付+已发货+已完成)        │
 * │  Format:      $#,###.##                                          │
 * │  Is Certified: ☑                                                │
 * └─────────────────────────────────────────────────────────────────┘
 * 
 * 标记为 "Certified" 后,该指标在所有看板中:
 *   - 优先显示
 *   - 锁定不能修改(避免被误改)
 *   - 显示定义说明
 */

-- ========================================
-- 5. 看板设计模式
-- ========================================

/*
┌──────────────────────────────────────────────────────────────────────────┐
│                    5 类核心看板设计模式                                      │
├──────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  模式 1: 实时大屏 (5 秒刷新)                                              │
│  ┌────────────────────────────────────────┐                              │
│  │  KPI: 实时 GMV │ 订单数 │ 支付用户数   │                              │
│  │  ────────────────────────────────────  │                              │
│  │  折线: 最近 1 小时 GMV 趋势           │                              │
│  │  ┌─────────────────────────────────┐  │                              │
│  │  │       /\          /\            │  │                              │
│  │  │  /\  /  \   /\  /  \   /\       │  │                              │
│  │  │ /  \/    \ /  \/    \ /  \      │  │                              │
│  │  │/             \/             \    │  │                              │
│  │  └─────────────────────────────────┘  │                              │
│  │  地图: 各地区 GMV 分布                │                              │
│  │  排行榜: TOP 10 商品                  │                              │
│  └────────────────────────────────────────┘                              │
│  数据源: ads_realtime_dashboard (物化视图)                                │
│  刷新: 5 秒                                                               │
│  Why: 物化视图支持高频查询,避免数据库被压垮                                │
│                                                                          │
│  模式 2: 业务分析 (按需刷新)                                               │
│  ┌────────────────────────────────────────┐                              │
│  │  KPI: 月度 GMV │ 月活 │ 转化率        │                              │
│  │  ────────────────────────────────────  │                              │
│  │  漏斗: 访问 → 下单 → 支付 → 完成     │                              │
│  │  对比: 同比 / 环比                     │                              │
│  │  钻取: 地区 → 城市 → 门店            │                              │
│  └────────────────────────────────────────┘                              │
│  数据源: v_metrics_standard (虚拟数据集)                                  │
│  刷新: 用户主动操作                                                       │
│  Why: 业务分析查询模式灵活,虚拟数据集支持动态筛选                          │
│                                                                          │
│  模式 3: 高管驾驶舱 (T+1 报表)                                            │
│  ┌────────────────────────────────────────┐                              │
│  │  KPI: 营收 │ 利润 │ 同比增长          │                              │
│  │  趋势: 12 个月营收趋势                 │                              │
│  │  分布: 业务线营收占比                  │                              │
│  └────────────────────────────────────────┘                              │
│  数据源: ads_daily_summary (离线预聚合)                                   │
│  刷新: 每天凌晨                                                           │
│  Why: T+1 数据精度要求高,适合离线聚合                                      │
│                                                                          │
│  模式 4: 自助分析 (数据科学家)                                             │
│  ┌────────────────────────────────────────┐                              │
│  │  SQL Lab 直接查询                      │                              │
│  │  自定义维度、指标                      │                              │
│  │  临时实验                              │                              │
│  └────────────────────────────────────────┘                              │
│  数据源: dwd_order (明细表)                                                │
│  限制: 限制行数 + 限制用户                                                 │
│  Why: 给数据科学家灵活空间,但防止生产数据库被跑死                          │
│                                                                          │
│  模式 5: 嵌入式看板 (业务系统)                                             │
│  ┌────────────────────────────────────────┐                              │
│  │  嵌入到业务后台                         │                              │
│  │  权限: 按用户角色过滤                   │                              │
│  │  性能: 预渲染                           │                              │
│  └────────────────────────────────────────┘                              │
│  工具: Superset Embedded SDK                                              │
│  Why: 业务用户无需切换工具,降低使用门槛                                    │
│                                                                          │
└──────────────────────────────────────────────────────────────────────────┘
*/

-- 5.1 漏斗看板视图
CREATE VIEW IF NOT EXISTS realtime_olap.v_superset_funnel ON CLUSTER 'treasurycluster' AS
SELECT
    toDate(order_time)                          AS dt,
    channel,
    region_code,
    
    -- 漏斗各阶段
    uniqIf(user_id, order_status != 'unknown')  AS step1_visit,
    uniqIf(user_id, order_status IN ('created', 'paid', 'shipped', 'completed')) AS step2_order,
    uniqIf(user_id, order_status IN ('paid', 'shipped', 'completed', 'refunded')) AS step3_pay,
    uniqIf(user_id, order_status IN ('shipped', 'completed')) AS step4_ship,
    uniqIf(user_id, order_status = 'completed') AS step5_complete,
    
    -- 漏斗转化率
    if(step1_visit > 0, step2_order / step1_visit, 0)   AS rate_visit_to_order,
    if(step2_order > 0, step3_pay / step2_order, 0)      AS rate_order_to_pay,
    if(step3_pay > 0, step4_ship / step3_pay, 0)        AS rate_pay_to_ship,
    if(step4_ship > 0, step5_complete / step4_ship, 0)   AS rate_ship_to_complete
    
FROM realtime_olap.dwd_order
WHERE is_valid = 1
  AND order_time >= today() - INTERVAL 90 DAY
GROUP BY dt, channel, region_code;

-- 5.2 排行榜视图(TOP N)
CREATE VIEW IF NOT EXISTS realtime_olap.v_superset_topn ON CLUSTER 'treasurycluster' AS
SELECT
    toDate(order_time)                          AS dt,
    product_id,
    product_name,
    product_category,
    product_brand,
    
    sum(order_amount)                           AS gmv,
    count()                                     AS order_cnt,
    uniq(user_id)                               AS user_cnt,
    
    -- 排名(供 Superset 展示)
    row_number() OVER (PARTITION BY dt ORDER BY gmv DESC) AS gmv_rank
FROM realtime_olap.dwd_order
WHERE is_valid = 1
  AND order_time >= today() - INTERVAL 30 DAY
GROUP BY dt, product_id, product_name, product_category, product_brand;

-- ========================================
-- 6. 缓存策略
-- ========================================

/*
 * Superset 默认带缓存,需要合理配置
 * 
 * 配置文件: superset_config.py
 * 
 * # 启用 Redis 缓存
 * CACHE_CONFIG = {
 *     'CACHE_TYPE': 'RedisCache',
 *     'CACHE_REDIS_HOST': 'redis',
 *     'CACHE_REDIS_PORT': 6379,
 *     'CACHE_REDIS_DB': 1,
 *     'CACHE_DEFAULT_TIMEOUT': 300  # 5 分钟
 * }
 * 
 * # 图表级缓存(每个图表独立)
 * FILTER_STATE_CACHE_CONFIG = {
 *     'CACHE_TYPE': 'RedisCache',
 *     ...
 * }
 * 
 * # 探索性查询缓存(用户操作)
 * EXPLORE_FORM_DATA_CACHE_CONFIG = {
 *     'CACHE_TYPE': 'RedisCache',
 *     ...
 * }
 * 
 * Why 多级缓存?
 *   - CACHE_CONFIG: 图表数据缓存(最常用,降低数据库压力)
 *   - FILTER_STATE_CACHE: 筛选状态缓存(避免重复计算筛选器)
 *   - EXPLORE_FORM_DATA_CACHE: 探索页表单数据(用户编辑体验)
 * 
 * 缓存策略选择:
 * 
 * | 数据源            | 缓存时间     | Why                                  |
 * |-------------------|-------------|--------------------------------------|
 * | 实时大屏(物化视图) | 30-60 秒    | 容忍稍旧,但保证响应速度               |
 * | 业务分析(虚拟数据集)| 5-15 分钟   | 数据变更不频繁,长缓存降负载           |
 * | T+1 报表          | 24 小时      | 离线数据,缓存到次日重新计算            |
 * | 自助分析          | 0 (不缓存)   | 数据科学家探索,必须实时              |
 */

-- 6.1 配置示例 (superset_config.py)
-- 
-- # ============ 基础配置 ============
-- ENABLE_CORS = True
-- CORS_OPTIONS = { ... }
-- 
-- # ============ 缓存配置(关键) ============
-- CACHE_CONFIG = {
--     'CACHE_TYPE': 'RedisCache',
--     'CACHE_REDIS_HOST': 'redis',
--     'CACHE_REDIS_PORT': 6379,
--     'CACHE_REDIS_DB': 1,
--     'CACHE_DEFAULT_TIMEOUT': 300,        # 默认 5 分钟
--     'CACHE_KEY_PREFIX': 'superset_cache',
--     'CACHE_REDIS_PASSWORD': 'your_password',
-- }
-- 
-- # ============ SQL Lab 配置 ============
-- SQLLAB_TIMEOUT = 300                   # 查询超时(秒)
-- SQLLAB_CTAS_NO_LIMIT = True             # 允许大结果集
-- SUPERSET_WEBSERVER_TIMEOUT = 60
-- 
-- # ============ 性能配置 ============
-- SUPERSET_DASHBOARD_PERIODICAL_REFRESH_LIMIT = 30
-- # 限制:同一看板不能超过 30 个图表(避免查询雪崩)
-- 
-- # ============ 特性标志 ============
-- FEATURE_FLAGS = {
--     'ENABLE_TEMPLATE_PROCESSING': True,
--     'DASHBOARD_CROSS_FILTERS': True,
--     'DASHBOARD_RBAC': True,             # 看板级权限
--     'EMBEDDED_SUPERSET': True,          # 嵌入式
-- }

-- ========================================
-- 7. 行级权限(多租户)
-- ========================================

/*
 * 场景: 同一看板,不同区域经理只能看自己区域的数据
 * 
 * 方案 1: Row Level Security (RLS) - Superset 内置
 *   - 在 Superset 中定义 RLS 规则
 *   - 绑定到角色
 *   - 用户查询时自动追加 WHERE 条件
 *   - 简单,适合中小规模
 * 
 * 方案 2: ClickHouse 端过滤 - 性能更优
 *   - 用 user_id / region_code 在 ClickHouse 端做权限过滤
 *   - 通过参数注入 {{ current_user_id() }}
 *   - 性能更好(数据库端执行)
 * 
 * 方案 3: 多套看板(完全隔离)
 *   - 每个区域独立看板
 *   - 最安全但维护成本高
 * 
 * 推荐: 方案 2 (ClickHouse 端)
 */

-- 7.1 ClickHouse 端 RLS 视图
CREATE VIEW IF NOT EXISTS realtime_olap.v_superset_gmv_rls ON CLUSTER 'treasurycluster' AS
SELECT *
FROM realtime_olap.v_superset_gmv_dashboard
WHERE 
    -- 通过 Superset Jinja 注入当前用户
    -- {{ current_user_region() }} 返回用户所属区域
    region_code IN (SELECT region_code FROM realtime_olap.user_region_mapping 
                    WHERE user_name = {{ current_username() }})
    OR
    -- 超级管理员可看所有
    {{ current_username() }} IN ('admin', 'data_team');

-- 7.2 Superset 中配置
/*
 * Settings → Row Level Security → + ROW LEVEL SECURITY
 * 
 * ┌─────────────────────────────────────────────────────────────────┐
 * │  RLS Rule: Regional Manager Filter                               │
 * ├─────────────────────────────────────────────────────────────────┤
 * │  Table:    v_superset_gmv_rls                                    │
 * │  Clause:   region_code = '{{ current_user.region }}'             │
 * │  Roles:    Regional_Manager, Regional_Director                  │
 * │  Filter Type: Regular                                           │
 * └─────────────────────────────────────────────────────────────────┘
 * 
 * Why 用 RLS 而非多套看板?
 *   - 一套代码,所有用户共用
 *   - 修改只改一处
 *   - 减少维护成本 80%
 */

-- ========================================
-- 8. 嵌入式分析
-- ========================================

/*
 * 场景: 把 Superset 看板嵌入到业务后台
 * 
 * 工具: Embedded Superset SDK
 *   https://github.com/apache/superset/tree/master/superset-embedded-sdk
 * 
 * 优势:
 *   - 业务用户无需切换工具
 *   - 权限统一(SSO)
 *   - 减少培训成本
 * 
 * 示例 (JavaScript):
 *   import { embedDashboard } from "@superset-ui/embedded-sdk";
 *   
 *   embedDashboard({
 *     id: "dashboard-uuid",        // 看板 ID
 *     supersetDomain: "https://superset.company.com",
 *     mountPoint: document.getElementById("superset-container"),
 *     fetchGuestToken: () => fetchGuestTokenFromBackend(),
 *     dashboardUiConfig: {
 *       hideTitle: true,
 *       hideChartControls: false,
 *       filters: { expanded: false }
 *     }
 *   });
 * 
 * Why 用 SDK 而非 iframe?
 *   - iframe: 简单但权限/尺寸控制弱
 *   - SDK: 细粒度控制,性能更好,支持交互
 */

-- ========================================
-- 9. 性能优化清单
-- ========================================

/*
 * ┌────────────────────────────────────────────────────────────────────┐
 * │         Superset + ClickHouse 性能优化 Checklist                    │
 * ├────────────────────────────────────────────────────────────────────┤
 * │                                                                    │
 * │  数据源层:                                                          │
 * │  □ 使用物化视图(高频看板)                                           │
 * │  □ 使用虚拟数据集(常规看板)                                         │
 * │  □ 视图中加时间过滤(避免全表扫描)                                    │
 * │  □ 指标在 ClickHouse 端计算,不在 Superset 端算                     │
 * │                                                                    │
 * │  Superset 配置:                                                     │
 * │  □ 启用 Redis 缓存(5-15 分钟)                                     │
 * │  □ 异步查询(Sql Lab 大查询)                                        │
 * │  □ 限制 SQL Lab 行数(< 10000)                                      │
 * │  □ 看板图表数限制(< 30)                                            │
 * │  □ 配置合理的刷新间隔                                              │
 * │                                                                    │
 * │  看板设计:                                                          │
 * │  □ KPI 卡片用物化视图(亚秒级)                                       │
 * │  □ 趋势图用 DWS 汇总(秒级)                                         │
 * │  □ 排行榜加 LIMIT(避免全表)                                         │
 * │  □ 过滤器加默认值                                                  │
 * │  □ 避免交叉过滤(性能消耗)                                          │
 * │                                                                    │
 * │  数据库:                                                            │
 * │  □ ClickHouse 慢查询监控(> 5s 告警)                                │
 * │  □ Superset 端开启 SQL 审计                                         │
 * │  □ 定期 ANALYZE 表统计信息                                         │
 * │                                                                    │
 * └────────────────────────────────────────────────────────────────────┘
 */

-- ========================================
-- 10. 验证查询
-- ========================================

-- 检查视图性能
EXPLAIN PIPELINE
SELECT * FROM realtime_olap.v_superset_gmv_dashboard
WHERE dt >= today() - INTERVAL 7 DAY
LIMIT 1000;

-- 检查物化视图状态
SELECT
    name,
    engine,
    total_rows,
    formatReadableSize(total_bytes) AS size,
    formatReadableTimeDelta(now() - latest_modification_time) AS last_update
FROM system.tables
WHERE database = 'realtime_olap' 
  AND engine LIKE '%MaterializedView%'
ORDER BY total_rows DESC;

-- 检查 DWS 表大小
SELECT
    table,
    formatReadableSize(sum(bytes_on_disk)) AS size,
    sum(rows) AS total_rows
FROM system.parts
WHERE database = 'realtime_olap'
  AND table IN ('dws_user_order_day', 'dws_product_order_day', 'ads_realtime_dashboard')
  AND active
GROUP BY table;
