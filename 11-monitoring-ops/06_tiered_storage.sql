-- ============================================================================
-- 06 - 分层存储（新增专题）
-- ============================================================================
-- 场景: 热温冷数据分层、多卷存储配置、TTL MOVE TO 策略、S3 集成、性能影响
-- 集群: treasurycluster (2副本)
-- 耗时: 15-20分钟
-- 注意: 分层存储依赖 storage policy 配置，需在 config.xml 中预先定义
--       TTL MOVE TO VOLUME/DISK 需要对应存储策略生效
-- ============================================================================

DROP DATABASE IF EXISTS ops_test;
CREATE DATABASE ops_test;
USE ops_test;

-- ============================================================================
-- 【原理】分层存储架构
--
-- ClickHouse 的分层存储通过 Storage Policy 和 Volume 机制实现：
--
--   ┌─────────────────────────────────────────────────────────────────────────┐
--   │                         Storage Policy 体系                              │
--   └─────────────────────────────────────────────────────────────────────────┘
--
--   Storage Policy (存储策略)
--   ├── Volume 1: HOT (SSD/NVMe)
--   │   ├── Disk 1: /data/clickhouse/hot/    ← 高性能盘，新数据写入
--   │   └── Disk 2: /data/clickhouse/hot2/   ← 可多个磁盘做 JBOD
--   ├── Volume 2: WARM (HDD)
--   │   ├── Disk 1: /data/clickhouse/warm/   ← 中速盘，近期历史数据
--   │   └── ...
--   ├── Volume 3: COLD (S3/Object Store)
--   │   ├── Disk 1: s3://bucket/path/        ← 对象存储，长期归档
--   │   └── ...
--   └── 规则:
--       ├── move_factor: 0.1  → 磁盘空间 < 10% 时自动移入下一卷
--       ├── TTL 规则         → 按时间维度移动数据
--       └── 手动 MOVE        → 通过 ALTER 手动迁移
--
-- 数据流动路径:
--   INSERT → Volume 1 (HOT) → TTL → Volume 2 (WARM) → TTL → Volume 3 (COLD) → TTL → DELETE
--             第1-3天              第4-30天                  第31-365天              >365天
-- ============================================================================

-- ============================================================================
-- 【坑】分层存储注意事项
--   1. Storage Policy 必须在 config.xml 中预先定义，创建表时指定
--   2. 修改已有表的存储策略只能用 ALTER TABLE ... MODIFY SETTING storage_policy
--   3. TTL MOVE 是异步后台操作，不阻塞写入
--   4. S3 磁盘的延迟远高于本地盘，冷数据查询需要做好预期
--   5. move_factor 过小会导致磁盘写满后无法自动迁移
--   6. 多个 Disk 在同 Volume 下是 JBOD（填满一个再用下一个），不是 RAID
--   7. 不同 Volume 之间是顺序迁移，不会回退（数据只能从 HOT→WARM→COLD）
-- ============================================================================

-- ============================================================================
-- 【对比】分层存储方案对比
--
-- ┌──────────────────┬──────────────────┬──────────────────┬──────────────────┐
-- │     方案          │     成本          │     查询性能      │     运维复杂度   │
-- ├──────────────────┼──────────────────┼──────────────────┼──────────────────┤
-- │ 全 SSD 存储       │  高              │  最高             │  低              │
-- ├──────────────────┼──────────────────┼──────────────────┼──────────────────┤
-- │ SSD + HDD 分层    │  中              │  高（热数据）     │  中              │
-- ├──────────────────┼──────────────────┼──────────────────┼──────────────────┤
-- │ SSD + S3 分层     │  低              │  中               │  高              │
-- ├──────────────────┼──────────────────┼──────────────────┼──────────────────┤
-- │ 全 S3 存储        │  最低            │  低               │  中              │
-- └──────────────────┴──────────────────┴──────────────────┴──────────────────┘
-- ============================================================================

-- ==========================================
-- 1. 存储策略配置与查看
-- ==========================================

-- 1.1 查看当前存储策略
-- 【场景】了解集群当前配置了哪些存储策略，每个策略包含哪些 Volume 和 Disk
-- 【原理】system.storage_policies 从 config.xml 中读取定义的存储策略
SELECT
    policy_name,
    volume_name,
    volume_priority,
    disks,
    max_data_part_size,
    move_factor,
    preferred_max_data_part_size_bytes
FROM system.storage_policies
ORDER BY policy_name, volume_priority;

-- 1.2 查看所有磁盘信息
-- 【场景】查看各磁盘的路径、类型、容量和使用情况
-- 【坑】keep_free_space 是保留空间，free_space 可能已扣除该值
SELECT
    name,
    path,
    formatReadableSize(free_space) AS free_space,
    formatReadableSize(total_space) AS total_space,
    formatReadableSize(keep_free_space) AS keep_free_space,
    round((total_space - free_space) / total_space * 100, 1) AS used_percent,
    type,
    is_read_only,
    is_writeable
FROM system.disks
ORDER BY name;

-- 1.3 查看各表使用的存储策略
-- 【场景】确认哪些表使用了分层存储策略，哪些还在默认策略
SELECT
    database,
    name AS table_name,
    engine,
    formatReadableSize(total_bytes) AS total_size,
    formatReadableSize(total_rows) AS total_rows,
    settings['storage_policy'] AS storage_policy,
    create_table_query
FROM system.tables
WHERE database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
  AND engine LIKE '%MergeTree%'
ORDER BY database, name;

-- ==========================================
-- 2. 创建分层存储测试环境
-- ==========================================

-- 2.1 创建分层存储策略下的测试表
-- 【场景】模拟一个三层分层存储的表（热数据 SSD、温数据 HDD、冷数据 S3）
-- 【原理】通过 storage_policy 指定预定义的策略，通过 TTL 定义数据流动规则
-- 【坑】storage_policy 必须在 config.xml 中已定义，否则创建表会失败
--       这里使用默认策略演示，实际部署需替换为真实策略名
CREATE TABLE ops_test.tiered_events (
    event_id UInt64,
    event_time DateTime,
    event_type String,
    user_id UInt64,
    event_data String,
    -- 热数据：最近 3 天在 SSD
    -- 温数据：3-30 天在 HDD
    -- 冷数据：30-365 天在 S3
    -- 超过 365 天删除
    _ttl_hot DateTime MATERIALIZED now()  -- 用于 TTL 判断的辅助列
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_type, event_time)
-- 注意：以下 storage_policy 仅为示例，实际需在 config.xml 中预先定义
-- SETTINGS storage_policy = 'tiered_ssd_hdd_s3'
SETTINGS index_granularity = 8192;

-- 2.2 为已有表添加分层存储策略
-- 【场景】将现有表的数据迁移到分层存储策略
-- 【原理】ALTER TABLE ... MODIFY SETTING storage_policy 可以动态修改存储策略
-- 【坑】修改后，已有数据不会立即迁移，需要等待后台 TTL 或手动触发
--       新写入的数据会直接写入新策略的第一个 Volume
-- ALTER TABLE ops_test.tiered_events
--     MODIFY SETTING storage_policy = 'tiered_ssd_hdd_s3';

-- 2.3 插入测试数据
-- 【场景】生成历史数据，模拟不同时间范围的数据分布
INSERT INTO ops_test.tiered_events
SELECT
    number AS event_id,
    now() - INTERVAL rand() % 400 DAY AS event_time,  -- 随机过去 400 天
    ['click', 'view', 'purchase', 'login', 'logout'][rand() % 5 + 1] AS event_type,
    rand() % 100000 AS user_id,
    toString(rand()) AS event_data
FROM system.numbers
LIMIT 100000;

-- ==========================================
-- 3. TTL 分层存储配置
-- ==========================================

-- 3.1 设置 TTL MOVE TO VOLUME（按卷迁移）
-- 【场景】将数据按时间维度从热卷迁移到温卷，再迁移到冷卷
-- 【原理】TTL MOVE TO VOLUME 是 ClickHouse 的原生分层迁移机制
-- 【坑】VOLUME 名称必须与 storage_policy 中定义的 Volume 名称完全一致
--       多个 TTL 规则同时存在时，ClickHouse 会按最早满足的条件执行
--       一旦移动到下一级，不会再回退到上一级
-- · 第 3 天后从热卷移到温卷
-- · 第 30 天后从温卷移到冷卷
-- · 第 365 天后删除
ALTER TABLE ops_test.tiered_events
    MODIFY TTL event_time + INTERVAL 3 DAY TO VOLUME 'hot',
         event_time + INTERVAL 30 DAY TO VOLUME 'warm',
         event_time + INTERVAL 365 DAY TO DELETE;

-- 3.2 设置 TTL MOVE TO DISK（直接指定磁盘迁移）
-- 【场景】更精细地控制数据存放位置，直接指定目标磁盘
-- 【原理】TTL MOVE TO DISK 可以跳过 Volume 层，直接迁移到指定磁盘
-- 【坑】指定的 DISK 必须在 storage_policy 的某个 Volume 中
--       否则会报 "No such disk in storage policy" 错误
-- ALTER TABLE ops_test.tiered_events
--     MODIFY TTL event_time + INTERVAL 3 DAY TO DISK 'ssd_disk',
--          event_time + INTERVAL 30 DAY TO DISK 'hdd_disk',
--          event_time + INTERVAL 365 DAY TO DELETE;

-- 3.3 查看表当前的 TTL 配置
-- 【场景】确认 TTL 规则是否已生效，检查各规则的详细信息
-- 【原理】system.ttl_entries 存储了所有表的 TTL 配置信息
SELECT
    database,
    table,
    name AS column_name,
    min_bytes,
    max_bytes,
    formatReadableSize(min_bytes) AS min_size,
    formatReadableSize(max_bytes) AS max_size,
    rows
FROM system.ttl_entries
WHERE database = 'ops_test'
ORDER BY database, table;

-- 3.4 查看 TTL 合并任务的执行状态
-- 【场景】监控 TTL 后台任务的执行进度
-- 【原理】TTL 通过 Merge 任务执行，可以在 system.merges 中查看
-- 【坑】TTL 合并可能因资源竞争被延迟，需要关注 backlog
SELECT
    database,
    table,
    partition_id,
    result_part_name,
    progress,
    num_parts,
    formatReadableSize(total_size_bytes_compressed) AS size,
    elapsed,
    is_mutation
FROM system.merges
WHERE database = 'ops_test'
ORDER BY total_size_bytes_compressed DESC;

-- ==========================================
-- 4. 数据分布监控
-- ==========================================

-- 4.1 查看各磁盘上的数据分布
-- 【场景】了解数据在各磁盘上的实际分布情况，验证分层存储是否按预期工作
-- 【原理】system.parts 的 disk_name 字段记录了每个 Part 所在的磁盘
SELECT
    disk_name,
    count() AS part_count,
    sum(rows) AS total_rows,
    formatReadableSize(sum(bytes_on_disk)) AS total_size,
    formatReadableSize(sum(data_uncompressed_bytes)) AS uncompressed_size,
    round(sum(data_uncompressed_bytes) / greatest(sum(bytes_on_disk), 1), 2) AS compression_ratio
FROM system.parts
WHERE active = 1
  AND database = 'ops_test'
GROUP BY disk_name
ORDER BY disk_name;

-- 4.2 查看各表在各磁盘上的数据分布
-- 【场景】按表维度查看数据在磁盘上的分布，发现异常的磁盘倾斜
-- 【坑】如果某个表的数据全部集中在同一磁盘，说明 TTL 可能未生效
SELECT
    database,
    table,
    disk_name,
    count() AS part_count,
    sum(rows) AS total_rows,
    formatReadableSize(sum(bytes_on_disk)) AS total_size
FROM system.parts
WHERE active = 1
  AND database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
GROUP BY database, table, disk_name
ORDER BY database, table, disk_name;

-- 4.3 查看按时间范围的数据分布
-- 【场景】验证数据是否按时间维度正确分布在不同的存储层
-- 【原理】通过 event_time 范围与磁盘名称的关联，判断分层策略是否生效
SELECT
    disk_name,
    min(min_time) AS oldest_data,
    max(max_time) AS newest_data,
    dateDiff('day', max(max_time), now()) AS newest_data_age_days,
    dateDiff('day', min(min_time), now()) AS oldest_data_age_days,
    count() AS part_count,
    formatReadableSize(sum(bytes_on_disk)) AS size
FROM (
    SELECT
        disk_name,
        min(event_time) AS min_time,
        max(event_time) AS max_time,
        bytes_on_disk
    FROM ops_test.tiered_events
    INNER JOIN system.parts
        ON ops_test.tiered_events._part = system.parts.name
    WHERE system.parts.active = 1
    GROUP BY disk_name, _part, bytes_on_disk
)
GROUP BY disk_name
ORDER BY disk_name;

-- 4.4 查看 S3 外部存储的使用情况
-- 【场景】如果使用 S3 作为冷存储层，需要监控 S3 的读写和延迟
-- 【原理】system.s3_queue 和 system.s3_settings 提供 S3 集成的运行时信息
-- 【坑】S3 的延迟（latency_ms）可能因网络抖动而波动，需要设置合理的告警阈值
SELECT
    name,
    value,
    description
FROM system.asynchronous_metrics
WHERE name LIKE '%S3%'
   OR name LIKE '%s3%'
ORDER BY name;

-- ==========================================
-- 5. 手动数据迁移操作
-- ==========================================

-- 5.1 手动将分区迁移到指定磁盘
-- 【场景】需要立即将某个热分区迁移到冷存储，不等 TTL 自动触发
-- 【原理】ALTER TABLE ... MOVE PARTITION ... TO DISK/VOLUME 是即时操作
-- 【坑】手动 MOVE 会触发一个后台任务，可以通过 system.merges 监控进度
--       如果目标磁盘空间不足，操作会失败
-- · 将 2024 年 1 月的数据移到 HDD 磁盘
-- ALTER TABLE ops_test.tiered_events
--     MOVE PARTITION '202401' TO DISK 'hdd_disk';

-- 5.2 手动将整个表的数据迁移到新的存储策略
-- 【场景】切换存储策略后，需要手动触发历史数据的迁移
-- 【原理】通过 OPTIMIZE ... FINAL 触发合并，同时触发 TTL 移动
-- 【坑】大表完全合并可能耗时很长，建议分分区执行
-- OPTIMIZE TABLE ops_test.tiered_events PARTITION '202401' FINAL;
-- OPTIMIZE TABLE ops_test.tiered_events PARTITION '202402' FINAL;

-- 5.3 查看所有正在进行的迁移任务
-- 【场景】监控手动迁移的执行进度
SELECT
    database,
    table,
    partition_id,
    result_part_name,
    progress,
    num_parts,
    formatReadableSize(total_size_bytes_compressed) AS size,
    elapsed,
    is_mutation
FROM system.merges
WHERE database = 'ops_test'
ORDER BY progress;

-- ==========================================
-- 6. 性能影响分析
-- ==========================================

-- 6.1 对比不同存储层的查询性能
-- 【场景】评估冷热数据在不同存储层上的查询性能差异
-- 【原理】通过查询延迟和读取字节数判断存储层对性能的影响
-- 【坑】首次查询冷数据时，S3 的延迟可能比本地盘高 10-100 倍
--       缓存预热后，后续查询可能大幅改善
-- · 热数据查询（最近 3 天，预期在 SSD）
SELECT 'Hot Data Query' AS test_case,
       count() AS event_count,
       avg(length(event_data)) AS avg_data_size
FROM ops_test.tiered_events
WHERE event_time > now() - INTERVAL 3 DAY;

-- · 温数据查询（3-30 天，预期在 HDD）
SELECT 'Warm Data Query' AS test_case,
       count() AS event_count,
       avg(length(event_data)) AS avg_data_size
FROM ops_test.tiered_events
WHERE event_time BETWEEN now() - INTERVAL 30 DAY AND now() - INTERVAL 3 DAY;

-- · 冷数据查询（30-365 天，预期在 S3/冷存储）
SELECT 'Cold Data Query' AS test_case,
       count() AS event_count,
       avg(length(event_data)) AS avg_data_size
FROM ops_test.tiered_events
WHERE event_time BETWEEN now() - INTERVAL 365 DAY AND now() - INTERVAL 30 DAY;

-- 6.2 查看各存储层的延迟指标
-- 【场景】通过系统指标了解各存储层的 I/O 性能
-- 【原理】system.events 记录了磁盘读取相关的累计事件
-- 【坑】这些是累计值，需要计算 delta 才能得到实时性能
SELECT
    event,
    value,
    description
FROM system.events
WHERE event LIKE '%DiskRead%'
   OR event LIKE '%DiskWrite%'
   OR event LIKE '%S3%'
   OR event LIKE '%RemoteRead%'
ORDER BY event;

-- 6.3 查看分层存储的 I/O 分布
-- 【场景】了解各磁盘的 I/O 负载，判断是否需要调整存储策略
SELECT
    name,
    path,
    formatReadableSize(free_space) AS free_space,
    formatReadableSize(total_space) AS total_space,
    round((total_space - free_space) / total_space * 100, 1) AS used_percent,
    type,
    is_read_only
FROM system.disks
ORDER BY name;

-- ==========================================
-- 7. S3 集成配置与监控
-- ==========================================

-- 7.1 查看 S3 磁盘配置
-- 【场景】确认 S3 存储的挂载配置和连接信息
-- 【原理】S3 作为 ClickHouse 的磁盘类型，通过 DiskS3 配置实现
-- 【坑】S3 磁盘的 endpoint 和 region 必须在 config.xml 中正确配置
--       如果使用 MinIO 等兼容 S3 的存储，需要配置正确的 endpoint
SELECT
    name,
    path,
    type,
    is_read_only,
    is_writeable
FROM system.disks
WHERE type = 's3'
ORDER BY name;

-- 7.2 通过 S3 表函数直接查询外部数据
-- 【场景】不将数据导入 ClickHouse，直接查询 S3 上的 Parquet/CSV 文件
-- 【原理】s3() 表函数支持直接读取 S3 上的文件，无需预定义磁盘
-- 【坑】s3 表函数需要网络访问权限，且性能取决于网络带宽
--       文件格式必须与声明的 FORMAT 一致
-- · 查询 S3 上的 Parquet 文件
-- SELECT count(*) FROM s3('https://s3.amazonaws.com/bucket/path/events.parquet', 'Parquet');

-- 7.3 基于 S3 创建外部表
-- 【场景】将 S3 上的数据映射为 ClickHouse 表，实现冷数据按需查询
-- 【原理】S3 引擎表可以像本地表一样查询，数据存储在 S3 上
-- 【坑】S3 引擎表的写入性能较差，适合只读场景的冷数据
--       不支持索引，查询需要全表扫描
CREATE TABLE IF NOT EXISTS ops_test.s3_events_archive (
    event_id UInt64,
    event_time DateTime,
    event_type String,
    user_id UInt64,
    event_data String
) ENGINE = S3('https://s3.amazonaws.com/bucket/events/{_partition_id}/', 'Parquet')
PARTITION BY toYYYYMM(event_time);

-- ==========================================
-- 8. 分层存储容量规划
-- ==========================================

-- 8.1 各存储层容量使用预测
-- 【场景】根据数据增长趋势，预测各存储层未来的容量需求
-- 【原理】基于历史数据量和分层策略，计算每层的存储需求
-- 【坑】压缩比在不同存储层可能不同（SSD 上的数据更新鲜，压缩比可能更低）
SELECT
    'HOT (SSD)' AS storage_tier,
    formatReadableSize(sum(bytes_on_disk)) AS current_size,
    formatReadableSize(sum(bytes_on_disk) * 1.5) AS projected_3mo_size,  -- 50% 增长估算
    formatReadableSize(sum(bytes_on_disk) * 2.0) AS projected_6mo_size
FROM system.parts
WHERE active = 1
  AND database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
  AND min_time >= now() - INTERVAL 3 DAY
UNION ALL
SELECT
    'WARM (HDD)' AS storage_tier,
    formatReadableSize(sum(bytes_on_disk)),
    formatReadableSize(sum(bytes_on_disk) * 1.3),
    formatReadableSize(sum(bytes_on_disk) * 1.5)
FROM system.parts
WHERE active = 1
  AND database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
  AND min_time BETWEEN now() - INTERVAL 30 DAY AND now() - INTERVAL 3 DAY
UNION ALL
SELECT
    'COLD (S3/Archive)' AS storage_tier,
    formatReadableSize(sum(bytes_on_disk)),
    formatReadableSize(sum(bytes_on_disk) * 1.2),
    formatReadableSize(sum(bytes_on_disk) * 1.3)
FROM system.parts
WHERE active = 1
  AND database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
  AND min_time < now() - INTERVAL 30 DAY;

-- 8.2 自动迁移效率评估
-- 【场景】评估 TTL 自动迁移的执行效率，判断是否需要调整迁移策略
-- 【原理】通过 system.merges 中的 TTL 相关合并任务，评估迁移吞吐量
-- 【坑】如果 TTL 合并任务长期堆积，说明迁移速度跟不上数据增长速度
--       此时需要调整 move_factor 或增加 Volume 的磁盘数量
SELECT
    database,
    table,
    count() AS pending_moves,
    max(elapsed) AS max_elapsed_seconds,
    avg(elapsed) AS avg_elapsed_seconds,
    sum(num_parts) AS total_parts_to_merge
FROM system.merges
WHERE database = 'ops_test'
  AND is_mutation = 0
GROUP BY database, table;

-- ==========================================
-- 9. 存储策略最佳实践检查
-- ==========================================

-- 9.1 检查是否有表未配置分层存储但数据量很大
-- 【场景】发现应该使用分层存储但未配置的大表
-- 【原理】数据量超过 1TB 的表通常建议使用分层存储来降低成本
SELECT
    database,
    name AS table_name,
    engine,
    formatReadableSize(total_bytes) AS total_size,
    formatReadableSize(total_rows) AS total_rows,
    settings['storage_policy'] AS storage_policy,
    CASE
        WHEN settings['storage_policy'] = '' OR settings['storage_policy'] IS NULL
        THEN 'No tiering - consider adding storage policy'
        ELSE 'Tiered'
    END AS recommendation
FROM system.tables
WHERE database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
  AND engine LIKE '%MergeTree%'
  AND total_bytes > 107374182400  -- > 100GB
ORDER BY total_bytes DESC;

-- 9.2 检查磁盘空间使用率
-- 【场景】发现磁盘使用率过高可能导致 TTL 迁移失败
-- 【坑】如果磁盘剩余空间小于 10%，move_factor 可能无法正常工作
--       建议保持各磁盘的剩余空间 > 20%
SELECT
    name,
    path,
    formatReadableSize(free_space) AS free_space,
    formatReadableSize(total_space) AS total_space,
    round((total_space - free_space) / total_space * 100, 1) AS used_percent,
    CASE
        WHEN (total_space - free_space) / total_space > 0.9 THEN 'CRITICAL'
        WHEN (total_space - free_space) / total_space > 0.8 THEN 'WARNING'
        ELSE 'OK'
    END AS status
FROM system.disks
ORDER BY used_percent DESC;

-- ==========================================
-- 10. 分层存储配置示例
-- ==========================================

-- 10.1 单 Volume 多 Disk 配置（JBOD 模式）
-- 【场景】多个磁盘组成一个 Volume，数据依次写入各磁盘
-- 【原理】JBOD（Just a Bunch Of Disks）模式，填满一个再写下一个
-- 【坑】JBOD 模式下，磁盘容量不均衡会导致空间浪费
--       建议同一 Volume 中的磁盘容量尽量一致
/*
config.xml 配置示例:
<storage_configuration>
    <disks>
        <ssd_disk1>
            <path>/mnt/ssd1/</path>
        </ssd_disk1>
        <ssd_disk2>
            <path>/mnt/ssd2/</path>
        </ssd_disk2>
        <hdd_disk1>
            <path>/mnt/hdd1/</path>
        </hdd_disk1>
        <s3_disk>
            <type>s3</type>
            <endpoint>https://s3.amazonaws.com/bucket/clickhouse/</endpoint>
            <region>us-east-1</region>
            <access_key_id>...</access_key_id>
            <secret_access_key>...</secret_access_key>
        </s3_disk>
    </disks>
    <policies>
        <tiered_ssd_hdd_s3>
            <volumes>
                <hot>
                    <disk>ssd_disk1</disk>
                    <disk>ssd_disk2</disk>
                    <max_data_part_size>10737418240</max_data_part_size>  <!-- 10GB -->
                </hot>
                <warm>
                    <disk>hdd_disk1</disk>
                    <max_data_part_size>107374182400</max_data_part_size>  <!-- 100GB -->
                    <perform_ttl_move_on_insert>1</perform_ttl_move_on_insert>
                </warm>
                <cold>
                    <disk>s3_disk</disk>
                    <perform_ttl_move_on_insert>0</perform_ttl_move_on_insert>
                    <prefer_not_to_merge>1</prefer_not_to_merge>
                </cold>
            </volumes>
            <move_factor>0.1</move_factor>  <!-- 磁盘空间 < 10% 时自动迁移 -->
        </tiered_ssd_hdd_s3>
    </policies>
</storage_configuration>
*/

-- 10.2 按数据大小分配存储策略
-- 【场景】根据数据量选择不同的存储策略
-- · 小表（< 50GB）：全 SSD，不配置分层
-- · 中表（50GB - 1TB）：SSD + HDD 两层
-- · 大表（> 1TB）：SSD + HDD + S3 三层
-- 【坑】存储策略一旦选定，后续修改需要重建表或使用 MODIFY SETTING
--       MODIFY SETTING 不会重建已有数据，只有新写入数据会按新策略存放

-- 10.3 存储策略迁移检查清单
-- 【场景】在实施分层存储前，检查以下关键点
-- 1. 所有需要的磁盘路径已创建且有正确的权限
-- 2. config.xml 中已正确定义 disks 和 policies
-- 3. 表已使用正确的 storage_policy 创建
-- 4. TTL 规则已正确定义（MOVE TO VOLUME/DISK）
-- 5. move_factor 已根据实际需求设置（建议 0.1 - 0.2）
-- 6. 监控告警已配置（磁盘使用率、TTL 延迟）
-- 7. 备份策略已覆盖所有存储层
-- 8. 回滚方案已准备好

-- ==========================================
-- 11. 分层存储性能调优
-- ==========================================

-- 11.1 调整 TTL 合并的并发度
-- 【场景】加速或减慢 TTL 迁移速度
-- 【原理】通过调整后台合并线程数来控制 TTL 迁移速度
-- 【坑】过多的合并线程会消耗大量 I/O 和 CPU，影响在线查询性能
-- · 限制 TTL 合并的并发
-- SET GLOBAL max_merges_in_parallel = 4;
-- SET GLOBAL max_merges_in_parallel_for_ttl = 2;

-- 11.2 调整数据迁移策略
-- 【场景】根据业务需求调整数据在各存储层的留存时间
-- · 热数据（SSD）：最近 7 天（高频访问）
-- · 温数据（HDD）：7-90 天（偶尔访问）
-- · 冷数据（S3）：90 天以上（合规/归档需求）
-- ALTER TABLE ops_test.tiered_events
--     MODIFY TTL event_time + INTERVAL 7 DAY TO VOLUME 'hot',
--          event_time + INTERVAL 90 DAY TO VOLUME 'warm',
--          event_time + INTERVAL 730 DAY TO DELETE;

-- 11.3 查看 TTL 合并效率
-- 【场景】评估当前 TTL 合并的执行效率
-- 【原理】通过 system.events 中的 TTL 相关事件统计
SELECT
    event,
    value,
    description
FROM system.events
WHERE event LIKE '%TTL%'
   OR event LIKE '%Merge%'
ORDER BY event;

-- ==========================================
-- 清理
-- ==========================================
DROP TABLE IF EXISTS ops_test.tiered_events;
DROP TABLE IF EXISTS ops_test.s3_events_archive;
DROP DATABASE IF EXISTS ops_test;