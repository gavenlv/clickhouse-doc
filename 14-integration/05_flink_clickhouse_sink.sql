-- ================================================================================
-- 20 - Flink → ClickHouse 写入模式最佳实践
-- ================================================================================
-- 
-- 预计学习时间: 50 分钟
-- 
-- 本文件涵盖:
--   1. 三种 Sink 模式对比 - JDBC / Async / 第三方连接器
--   2. ClickHouseSink 完整实现 - 批量、异步、重试、Exactly-Once
--   3. Flink CDC 实时入仓 - MySQL → ClickHouse 整库同步
--   4. 维表关联 - 实时维表与异步 IO
--   5. 状态与 Checkpoint 配置
--   6. 反压与背压处理
--   7. 写入性能调优参数
--   8. 数据倾斜解决方案
-- 
-- ┌─────────────────────────────────────────────────────────────────────────────┐
-- │                     Flink 写入 ClickHouse 三种模式                          │
-- ├─────────────────────────────────────────────────────────────────────────────┤
-- │                                                                             │
-- │  模式1: JDBC + Batch Insert (通用)                                          │
-- │  ┌────────┐   5000/batch   ┌────────┐   HTTP/TCP   ┌──────────────┐         │
-- │  │ Flink  │──────────────►│ Buffer │─────────────►│ ClickHouse   │         │
-- │  │        │   1000ms flush │        │              │              │         │
-- │  └────────┘                └────────┘              └──────────────┘         │
-- │  吞吐: 5-20万/秒    适用: 中小规模、通用场景                                  │
-- │                                                                             │
-- │  模式2: ClickHouse 官方 Sink (推荐)                                         │
-- │  ┌────────┐   5000/batch   ┌────────┐   HTTP         ┌──────────────┐      │
-- │  │ Flink  │──────────────►│ Buffer │───────────────►│ ClickHouse   │      │
-- │  │        │   1000ms flush │        │  retry+backoff │              │      │
-- │  └────────┘                └────────┘                └──────────────┘      │
-- │  吞吐: 20-100万/秒   适用: 生产环境、高吞吐                                   │
-- │                                                                             │
-- │  模式3: 异步 Insert (async_insert)                                         │
-- │  ┌────────┐   实时 flush   ┌────────┐   缓冲合并      ┌──────────────┐      │
-- │  │ Flink  │──────────────►│ Buffer │───────────────►│ ClickHouse   │      │
-- │  │        │   无 batch 延迟 │        │  服务端合并    │              │      │
-- │  └────────┘                └────────┘                └──────────────┘      │
-- │  吞吐: 50-200万/秒   适用: 极小行、追求低延迟                                 │
-- │                                                                             │
-- │  Why 三种都要了解?                                                          │
-- │    - JDBC 通用但慢,适合 PoC                                                 │
-- │    - 官方 Sink 是生产首选                                                    │
-- │    - 异步 Insert 适合高 QPS 小行,降低客户端复杂度                            │
-- │                                                                             │
-- └─────────────────────────────────────────────────────────────────────────────┘
-- ================================================================================

-- ========================================
-- 1. ClickHouse 表 DDL (目标表)
-- ========================================
-- 与 02_clickhouse_modeling.sql 中的 dwd_order 保持一致
-- 这里仅作示例参考

CREATE TABLE IF NOT EXISTS realtime_olap.dwd_order_sink_demo ON CLUSTER 'treasurycluster' (
    order_id          String,
    user_id           UInt64,
    product_id        UInt64,
    order_amount      Decimal(18, 2),
    order_status      LowCardinality(String),
    order_time        DateTime,
    region_code       LowCardinality(String),
    channel           LowCardinality(String),
    etl_time          DateTime DEFAULT now()
) ENGINE = ReplicatedReplacingMergeTree(
    '/clickhouse/tables/{shard}/realtime_olap/dwd_order_sink_demo',
    '{replica}',
    etl_time
)
PARTITION BY toYYYYMM(order_time)
ORDER BY (order_time, user_id, order_id);

-- ========================================
-- 2. 模式 1: JDBC + Batch Insert (Java)
-- ========================================
/*
 * 点击展开查看 Java 代码
 * 
 * 适用场景:
 *   - PoC 阶段快速验证
 *   - 中小规模 (日数据 < 1 亿)
 *   - 需要严格 Exactly-Once 语义
 * 
 * 缺点:
 *   - 单条 INSERT 慢(每条都是一次 RPC)
 *   - 高并发下 ClickHouse 连接数易爆
 *   - 没有自动批量合并
 * 
 * 关键参数:
 *   - batchSize: 5000 (过大反而慢,过大易 OOM)
 *   - flushInterval: 1000ms (1 秒,平衡延迟与吞吐)
 *   - maxRetries: 3 (重试 3 次,避免无限重试)
 *   - retryDelay: 1000ms (指数退避)
 */

/**
 * 自定义 JDBC Sink,实现批量写入 + 重试 + 两阶段提交
 * 
 * 核心思想:
 *   1. 缓存到 buffer,达到 batchSize 或 flushInterval 触发 flush
 *   2. 使用 PreparedStatement.addBatch() 批量执行
 *   3. 失败时指数退避重试
 *   4. Checkpoint 时调用 flush() 保证 Exactly-Once
 */
public class ClickHouseJdbcSink extends RichSinkFunction<OrderEvent> 
    implements CheckpointedFunction {
    
    private final String jdbcUrl;
    private final String username;
    private final String password;
    private final int batchSize;
    private final long flushIntervalMs;
    
    private transient Connection connection;
    private transient PreparedStatement statement;
    private transient List<OrderEvent> buffer;
    private transient ListState<OrderEvent> pendingElements;  // Checkpoint 容错
    
    @Override
    public void open(Configuration parameters) throws Exception {
        // 1. 初始化 JDBC 连接
        connection = DriverManager.getConnection(jdbcUrl, username, password);
        connection.setAutoCommit(false);
        
        // 2. 预编译 SQL
        String sql = "INSERT INTO dwd_order (order_id, user_id, ...) VALUES (?, ?, ...)";
        statement = connection.prepareStatement(sql);
        
        // 3. 初始化 buffer
        buffer = new ArrayList<>(batchSize);
        
        // Why 用 ListState?
        //   - Flink Checkpoint 时,未 flush 的数据会丢
        //   - ListState 持久化到 HDFS/S3
        //   - 重启时从 ListState 恢复,实现 Exactly-Once
    }
    
    @Override
    public void invoke(OrderEvent event, Context ctx) throws Exception {
        buffer.add(event);
        
        if (buffer.size() >= batchSize) {
            flush();
        }
    }
    
    private void flush() throws Exception {
        if (buffer.isEmpty()) return;
        
        int retry = 0;
        while (retry < 3) {
            try {
                // 1. 绑定参数
                for (OrderEvent event : buffer) {
                    statement.setString(1, event.getOrderId());
                    statement.setLong(2, event.getUserId());
                    // ...
                    statement.addBatch();
                }
                
                // 2. 批量执行
                int[] results = statement.executeBatch();
                
                // 3. 提交
                connection.commit();
                statement.clearBatch();
                buffer.clear();
                return;  // 成功,返回
                
            } catch (SQLException e) {
                retry++;
                if (retry >= 3) {
                    // 写入失败,保留到 ListState,下次 Checkpoint 重试
                    throw e;
                }
                Thread.sleep(1000L * retry);  // 指数退避
            }
        }
    }
    
    @Override
    public void snapshotState(FunctionSnapshotContext ctx) throws Exception {
        // Checkpoint 时强制 flush
        flush();
        // pendingElements 已经在 flush 中清空
    }
}

-- ========================================
-- 3. 模式 2: ClickHouse 官方 Sink (生产推荐)
-- ========================================
/*
 * Why 推荐官方 Sink?
 *   - 内部实现 HTTP 协议(比 JDBC 快 3-5x)
 *   - 自动重试 + 退避策略
 *   - 支持 ClickHouse 特有功能(异步 Insert、JSONEachRow)
 *   - 社区维护,bug 修复及时
 * 
 * Maven 依赖:
 *   <dependency>
 *     <groupId>com.clickhouse</groupId>
 *     <artifactId>clickhouse-jdbc</artifactId>
 *     <version>0.6.0</version>
 *   </dependency>
 */

/**
 * 官方 ClickHouse Sink 完整示例
 * 
 * 关键配置:
 *   - batchSize: 5000-10000 (官方推荐)
 *   - flushInterval: 500-1000ms
 *   - 并行度: 与 Kafka 分区数一致
 */
public class ClickHouseOfficialSinkExample {
    
    public static void main(String[] args) throws Exception {
        StreamExecutionEnvironment env = StreamExecutionEnvironment.getExecutionEnvironment();
        
        // 1. 启用 Checkpoint (生产环境必须)
        env.enableCheckpointing(60000);  // 1 分钟
        env.getCheckpointConfig().setMinPauseBetweenCheckpoints(30000);
        env.getCheckpointConfig().setCheckpointTimeout(120000);
        env.getCheckpointConfig().setMaxConcurrentCheckpoints(1);
        env.getCheckpointConfig().setTolerableCheckpointFailureNumber(3);
        
        // 2. 配置状态后端 (RocksDB)
        env.setStateBackend(new EmbeddedRocksDBStateBackend());
        env.getConfig().setUseSnapshotCompression(true);
        
        // 3. Kafka Source
        KafkaSource<String> kafkaSource = KafkaSource.<String>builder()
            .setBootstrapServers("kafka:9092")
            .setGroupId("flink-clickhouse-consumer")
            .setTopics("dwd_order")
            .setStartingOffsets(OffsetsInitializer.committedOffsets())
            .setValueOnlyDeserializer(new SimpleStringSchema())
            .build();
        
        DataStream<String> kafkaStream = env.fromSource(kafkaSource, 
            WatermarkStrategy.noWatermarks(), "Kafka Source");
        
        // 4. 解析 + 转换
        DataStream<OrderEvent> orderStream = kafkaStream
            .map(json -> JSON.parseObject(json, OrderEvent.class))
            .filter(Objects::nonNull)
            .name("Parse Order Event");
        
        // 5. ClickHouse Sink (关键代码)
        ClickHouseSink<OrderEvent> clickhouseSink = ClickHouseSink.<OrderEvent>builder()
            .setUrls(new String[]{"jdbc:clickhouse://clickhouse1:8123,clickhouse2:8123/realtime_olap"})
            .setUsername("default")
            .setPassword("password")
            .setBatchSize(5000)                    // 每 5000 条 flush
            .setFlushInterval(Duration.ofMillis(1000))  // 或每 1 秒
            .setMaxRetries(3)
            .setRetryStrategy(new FixedRetryStrategy(3, Duration.ofSeconds(2)))
            .setRequestTimeout(Duration.ofSeconds(30))
            .setMapper((event, statement) -> {
                // 字段映射
                statement.setString(1, event.getOrderId());
                statement.setLong(2, event.getUserId());
                statement.setLong(3, event.getProductId());
                statement.setBigDecimal(4, event.getAmount());
                statement.setString(5, event.getStatus());
                statement.setTimestamp(6, Timestamp.valueOf(event.getOrderTime()));
                statement.setString(7, event.getRegion());
                statement.setString(8, event.getChannel());
            })
            .build();
        
        // 6. 设置并行度(关键!必须与 Kafka 分区数一致)
        orderStream.addSink(clickhouseSink)
            .setParallelism(8)  // 假设 Kafka 8 个分区
            .name("ClickHouse Sink");
        
        env.execute("Flink to ClickHouse Demo");
    }
}

-- ========================================
-- 4. 模式 3: 异步 Insert 配置 (ClickHouse 端)
-- ========================================
/*
 * 适用场景:
 *   - 高 QPS 小批量写入(每秒数万到数十万条)
 *   - 客户端不擅长 batching
 *   - 追求端到端低延迟
 * 
 * 原理:
 *   - 客户端 INSERT 不等返回,直接返回
 *   - ClickHouse 服务端缓冲,达到阈值后批量落盘
 *   - 通过 settings 控制行为
 */

-- 4.1 启用异步 Insert
SET async_insert = 1;
SET wait_for_async_insert = 0;  -- 0=不等,1=等(默认是 1)

-- 4.2 异步 Insert 调优参数
SET async_insert_max_data_size = 10485760;  -- 10MB (默认)
SET async_insert_busy_timeout_ms = 200;    -- 200ms (默认,降低可降低延迟)
SET async_insert_stale_timeout_ms = 0;     -- 不使用陈旧数据

-- Why 这套参数?
--   - async_insert_max_data_size: 缓冲满了立即落盘,避免延迟过高
--   - async_insert_busy_timeout_ms: 缓冲多久没满也强制落盘
--   - 配合 use_async_insert=1 的 Flink 端,实现秒级延迟

-- 4.3 Flink 端使用异步 Insert
/*
 * 在 JDBC URL 中加参数:
 *   jdbc:clickhouse://host:8123/db?async_insert=1&wait_for_async_insert=0
 * 
 * 注意:
 *   - 不再需要客户端 batch,服务端自动处理
 *   - 但失去 Exactly-Once(Flink Checkpoint 不知道 ClickHouse 何时落盘)
 *   - 适合"日志采集"等可容忍少量丢失的场景
 */

-- ========================================
-- 5. Flink CDC 整库同步(MySQL → ClickHouse)
-- ========================================
/*
 * 场景: 业务数据库全量+增量同步到 ClickHouse ODS
 * 
 * 工具: flink-cdc-connectors (开源)
 *   https://github.com/apache/flink-cdc-connectors
 * 
 * Maven 依赖:
 *   <dependency>
 *     <groupId>com.ververica</groupId>
 *     <artifactId>flink-connector-mysql-cdc</artifactId>
 *     <version>3.0.1</version>
 *   </dependency>
 */

/**
 * MySQL CDC → ClickHouse 完整示例
 * 
 * 关键决策:
 *   - 全量阶段: 单并发读 MySQL,批量写入 ClickHouse
 *   - 增量阶段: 多并发读 Binlog,实时写入
 *   - 状态: 用 Flink Checkpoint 持久化 offset
 */
public class MysqlCdcToClickHouse {
    
    public static void main(String[] args) throws Exception {
        StreamExecutionEnvironment env = StreamExecutionEnvironment.getExecutionEnvironment();
        env.enableCheckpointing(60000);
        env.setParallelism(4);
        
        // 1. MySQL CDC Source
        MySqlSource<String> cdcSource = MySqlSource.<String>builder()
            .hostname("mysql-host")
            .port(3306)
            .databaseList("business_db")
            .tableList("business_db.orders", "business_db.users", "business_db.products")
            .username("cdc_user")
            .password("cdc_pass")
            .deserializer(new JsonDebeziumDeserializationSchema())  // 输出 JSON
            .startupOptions(StartupOptions.initial())  // 先全量,后增量
            .build();
        
        DataStream<String> cdcStream = env.fromSource(cdcSource, 
            WatermarkStrategy.noWatermarks(), "MySQL CDC");
        
        // 2. 解析 + 分流(根据 table 字段路由到不同 ClickHouse 表)
        cdcStream
            .process(new RouteToTableFunction())
            .name("Route CDC Events");
        
        // 3. 不同表写入不同 ClickHouse 表
        // orders -> ods_order
        // users -> ods_user
        // products -> ods_product
        
        // ... 详见 02_clickhouse_modeling.sql 的 ODS 表结构
        
        env.execute("MySQL CDC to ClickHouse");
    }
}

-- ========================================
-- 6. 维表关联(实时维表)
-- ========================================
/*
 * 场景: 订单流需要关联用户昵称、商品类目
 * 
 * 方案对比:
 * 
 * 方案1: 预加载维表 (适合小维表, < 10万行)
 *   - 启动时全量加载到内存
 *   - 用 HashMap 缓存
 *   - 定期 refresh
 * 
 * 方案2: 异步 IO + HBase/Redis (适合大维表)
 *   - 每条数据异步查 HBase
 *   - Flink 异步 IO 提高吞吐
 *   - 缓存热点数据
 * 
 * 方案3: ClickHouse 字典 (推荐)
 *   - ClickHouse 自带 Dictionary
 *   - 维表存 ClickHouse 的普通表 + 创建 Dictionary
 *   - 业务表直接 dictGet,O(1) 内存查询
 *   - Why 推荐: 不需要额外组件(Flink 端无需任何代码)
 */

-- 6.1 ClickHouse 维表 + 字典(在 ClickHouse 端)
CREATE TABLE IF NOT EXISTS realtime_olap.dim_user ON CLUSTER 'treasurycluster' (
    user_id        UInt64,
    user_name      String,
    user_tier      LowCardinality(String),
    user_age_group LowCardinality(String),
    register_time  DateTime
) ENGINE = ReplicatedMergeTree(
    '/clickhouse/tables/{shard}/realtime_olap/dim_user',
    '{replica}'
)
ORDER BY user_id;

CREATE DICTIONARY IF NOT EXISTS realtime_olap.dict_dim_user ON CLUSTER 'treasurycluster' (
    user_id        UInt64,
    user_name      String DEFAULT '',
    user_tier      String DEFAULT 'unknown',
    user_age_group String DEFAULT 'unknown'
) PRIMARY KEY user_id
SOURCE(CLICKHOUSE(DB 'realtime_olap' TABLE 'dim_user'))
LIFETIME(MIN 60 MAX 300)  -- 1-5 分钟刷新
LAYOUT(HASHED());

-- 6.2 DWD 表写入时直接关联(在 Flink 端通过 SQL 完成,或者写入 DWD 后用视图关联)
-- 方案 A: Flink 端 JOIN 维表后写入(强实时)
--   缺点: Flink 端要维护维表缓存
-- 
-- 方案 B: ClickHouse 端用视图关联 (推荐)
CREATE VIEW IF NOT EXISTS realtime_olap.dwd_order_with_user ON CLUSTER 'treasurycluster' AS
SELECT
    o.*,
    dictGet('realtime_olap.dict_dim_user', 'user_name', o.user_id)     AS user_name,
    dictGet('realtime_olap.dict_dim_user', 'user_tier', o.user_id)     AS user_tier,
    dictGet('realtime_olap.dict_dim_user', 'user_age_group', o.user_id) AS user_age_group
FROM realtime_olap.dwd_order o;

-- Why 这种方式更好?
--   - Flink 端只写最简字段(性能最优)
--   - 维表更新不影响 Flink(解耦)
--   - 字典查询 < 10ms (O(1) 内存)
--   - Superset 直接查视图,无需再 JOIN

-- ========================================
-- 7. 状态与 Checkpoint 配置
-- ========================================
/*
 * Flink 状态配置(写入 ClickHouse 场景):
 * 
 * - State Backend: RocksDBStateBackend
 *   Why: 大状态(>1GB)时,内存状态会 OOM,RocksDB 写磁盘
 * 
 * - Checkpoint 间隔: 60 秒
 *   Why: 太快(< 10 秒)→ 写入开销大; 太慢(> 5 分钟)→ 重启恢复慢
 * 
 * - Checkpoint 超时: 120 秒
 *   Why: 60 秒间隔 + 60 秒超时 = 留出容错空间
 * 
 * - Checkpoint 存储: HDFS / S3
 *   Why: 本地磁盘重启后丢失,必须用分布式存储
 */

-- 完整配置示例(application.properties 或代码)
/*
execution.checkpointing.interval: 60s
execution.checkpointing.timeout: 120s
execution.checkpointing.min-pause: 30s
execution.checkpointing.max-concurrent-checkpoints: 1
execution.checkpointing.tolerable-failed-checkpoints: 3

state.backend: rocksdb
state.backend.incremental: true
state.checkpoints.dir: hdfs://namenode:8020/flink/checkpoints
state.savepoints.dir: hdfs://namenode:8020/flink/savepoints

# 关键: 启用本地恢复
state.backend.local-recovery: true
*/

-- ========================================
-- 8. 反压与背压处理
-- ========================================
/*
 * 反压(Backpressure)症状:
 *   - Flink Web UI 显示某个算子是红色 (HIGH)
 *   - Checkpoint 超时
 *   - 数据延迟越来越大
 * 
 * 常见原因:
 *   1. ClickHouse 写入慢 → 增大 batchSize,降低 checkpoint 频率
 *   2. Kafka 消费慢 → 增加并行度
 *   3. 状态太大 → 启用 RocksDB 增量 Checkpoint
 *   4. 数据倾斜 → 加盐/重新分区
 * 
 * 排查命令(在 Flink Web UI):
 *   - 看背压指标: SubTask Metrics → backPressureTimeMsPerSecond
 *   - 看火焰图:火焰图 → 找到热点函数
 */

-- ========================================
-- 9. 写入性能调优参数(终极清单)
-- ========================================
/*
┌──────────────────────────────────────────────────────────────────────┐
│              Flink 写入 ClickHouse 性能调优 Checklist                    │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  客户端(Flink):                                                       │
│  □ batchSize: 5000-10000 (不要 > 50000,易 OOM)                       │
│  □ flushInterval: 500-1000ms (平衡延迟与吞吐)                          │
│  □ maxRetries: 3 (配合指数退避)                                       │
│  □ 并行度 = Kafka 分区数 (避免数据倾斜)                                │
│  □ 启用对象重用: env.getConfig().enableObjectReuse()                 │
│  □ 启用 Netty 直接内存: taskmanager.memory.direct.memory               │
│                                                                      │
│  服务端(ClickHouse):                                                  │
│  □ max_insert_threads = 8 (并行写入)                                   │
│  □ async_insert = 1 (小行场景)                                        │
│  □ async_insert_busy_timeout_ms = 200                                  │
│  □ parts_to_throw_insert = 300 (熔断保护)                              │
│  □ max_parts_in_total = 100000                                       │
│  □ max_server_memory_usage 留 30% 给 OS                               │
│                                                                      │
│  表结构(目标表):                                                       │
│  □ 使用 ReplicatedMergeTree (不要用普通 MergeTree)                    │
│  □ PARTITION BY toYYYYMM(时间字段)                                    │
│  □ ORDER BY (时间字段, 高频过滤字段, 主键)                              │
│  □ 设置合适的 TTL(数据保留期)                                          │
│  □ 主键索引粒度: index_granularity = 8192 (默认即可)                  │
│                                                                      │
│  集群:                                                                │
│  □ 至少 2 副本(高可用)                                                │
│  □ 3-6 分片(平衡扩展性与 JOIN 性能)                                   │
│  □ Zookeeper 独立部署(3-5 节点)                                      │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
*/

-- ========================================
-- 10. 数据倾斜解决方案
-- ========================================
/*
 * 数据倾斜症状:
 *   - 某个 Flink SubTask 处理的数据量是其他 10x
 *   - 那个 SubTask Checkpoint 慢
 * 
 * 原因:
 *   - Kafka 分区不均(用户ID 热点)
 *   - ClickHouse 写入时按 partition key 倾斜
 * 
 * 解决方案:
 * 
 * 1. 加盐(打散热点 key)
 *    原: keyBy(user_id)
 *    改: keyBy(user_id + random.nextInt(10))
 *    然后聚合时: group by user_id,sum(amount)
 * 
 * 2. 两阶段聚合(局部+全局)
 *    第一阶段: 随机分区,做局部聚合
 *    第二阶段: 按真实 key 分区,做全局聚合
 * 
 * 3. 拆分热点 key
 *    检测热点 key → 单独处理 → 写完后合并
 */

-- ========================================
-- 11. 完整生产示例(从 0 到 1)
-- ========================================
/*
 * 场景: 订单实时入仓 + 维表关联 + DWS 聚合
 * 
 * 数据流:
 *   MySQL (binlog)
 *     → Flink CDC (解析)
 *     → 数据清洗 (过滤无效、补全)
 *     → 维表关联 (HBase / 内存)
 *     → 分流 (按业务类型)
 *     → ClickHouse Sink (批量)
 *     → ODS / DWD
 *     → 物化视图自动聚合到 DWS
 */

CREATE TABLE kafka_orders_source (
    order_id    STRING,
    user_id     BIGINT,
    product_id  BIGINT,
    amount      DECIMAL(18, 2),
    status      STRING,
    order_time  TIMESTAMP(3),
    WATERMARK FOR order_time AS order_time - INTERVAL '5' SECOND
) WITH (
    'connector' = 'kafka',
    'topic' = 'dwd_order',
    'properties.bootstrap.servers' = 'kafka:9092',
    'properties.group.id' = 'flink-consumer',
    'format' = 'json',
    'scan.startup.mode' = 'latest-offset'
);

CREATE TABLE clickhouse_order_sink (
    order_id    STRING,
    user_id     BIGINT,
    product_id  BIGINT,
    amount      DECIMAL(18, 2),
    status      STRING,
    order_time  TIMESTAMP(3),
    region      STRING,
    PRIMARY KEY (order_id) NOT ENFORCED
) WITH (
    'connector' = 'clickhouse',
    'url' = 'clickhouse://clickhouse1:8123',
    'database-name' = 'realtime_olap',
    'table-name' = 'dwd_order',
    'sink.batch-size' = '5000',
    'sink.flush-interval' = '1000',
    'sink.max-retries' = '3'
);

-- 业务逻辑:清洗 + 维表关联 + 写入
INSERT INTO clickhouse_order_sink
SELECT
    order_id,
    user_id,
    product_id,
    amount,
    CASE
        WHEN status IN ('PAID', 'SHIPPED') THEN 'paid'
        WHEN status = 'CREATED'           THEN 'created'
        WHEN status = 'COMPLETED'         THEN 'completed'
        ELSE 'unknown'
    END AS status,
    order_time,
    'CN' AS region  -- 简化:实际从维表获取
FROM kafka_orders_source
WHERE order_id IS NOT NULL
  AND amount > 0;

-- ========================================
-- 12. 监控指标
-- ========================================
/*
 * 必须监控的指标(告警阈值):
 * 
 * Flink 端:
 *   - 写入速率(条/秒): < 业务预期
 *   - Checkpoint 时长: > 5 分钟告警
 *   - 反压时长: > 10% 告警
 *   - 状态大小: > 100GB 告警
 * 
 * ClickHouse 端:
 *   - parts_active: < 100(合并队列正常)
 *   - insert_query_duration: P99 < 5s
 *   - background_pool_task: < CPU 核数 × 0.8
 *   - disk_free: > 20%
 *   - zookeeper_session: 正常
 * 
 * 端到端:
 *   - 数据延迟 = now() - max(event_time) < 10s
 */
