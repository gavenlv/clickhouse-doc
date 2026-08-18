-- ============================================================
-- 文件: 05-functions/05_json_functions.sql
-- 学习目标: 掌握 ClickHouse JSON 函数深度原理与实战
-- 深度标准: 原理 + 场景 + 对比 + 性能 + 可运行
-- 集群: CH 25.12 (单机模式，JSON 概念通用)
-- 前置: 无（自包含测试数据，按顺序执行）
-- ============================================================
--
-- 本文件章节:
--   1.  JSON 处理原理：三种方案概览
--   2.  JSONExtract 系列函数（按类型提取）
--   3.  JSON 查询路径语法（$ 路径 vs 简单 key）
--   4.  JSONHas / JSONLength / JSONKeys / JSONType
--   5.  JSON 数组与嵌套处理
--   6.  visitParam 系列（已废弃，兼容替代）
--   7.  JSON 类型（实验性原生类型）
--   8.  新旧 JSON 函数对比（visitParam → JSONExtract 迁移指南）
--   9.  性能对比：JSON 类型 vs String + JSONExtract
--   10. 实际 JSON 数据处理实战
--   11. 清理
-- ============================================================

DROP DATABASE IF EXISTS func_test;
CREATE DATABASE func_test;
USE func_test;


-- ============================================================
-- 0. 准备测试数据
-- ============================================================

DROP TABLE IF EXISTS api_logs;
DROP TABLE IF EXISTS user_profiles;
DROP TABLE IF EXISTS nested_json;

-- API 日志表（含多层嵌套 JSON）
CREATE TABLE api_logs (
    id UInt64,
    request_time DateTime,
    endpoint String,
    request_body String,
    response_body String,
    headers String,
    status_code UInt16
) ENGINE = MergeTree()
ORDER BY id;

INSERT INTO api_logs VALUES
    (1, '2024-01-15 08:00:00', '/api/users',
     '{"user_id":1001,"name":"John Doe","email":"john@example.com","tags":["premium","active"]}',
     '{"id":1001,"status":"ok","data":{"age":30,"city":"New York"}}',
     '{"Content-Type":"application/json","Accept":"*/*","Authorization":"Bearer tok_abc"}',
     200),
    (2, '2024-01-15 08:01:00', '/api/orders',
     '{"user_id":1002,"items":[{"product_id":101,"qty":2},{"product_id":102,"qty":1}],"total":799.98}',
     '{"order_id":5001,"status":"created","estimated_delivery":"2024-01-20"}',
     '{"Content-Type":"application/json","Authorization":"Bearer tok_def"}',
     201),
    (3, '2024-01-15 08:02:00', '/api/users',
     '{"user_id":1003,"name":"Jane Smith","email":"jane@example.com","tags":["new"]}',
     '{"id":1003,"status":"ok","data":{"age":25,"city":"London","preferences":{"theme":"dark","lang":"en"}}}',
     '{"Content-Type":"application/json","Accept":"*/*"}',
     200),
    (4, '2024-01-15 08:03:00', '/api/error',
     '{}',
     '{"error":{"code":400,"message":"Bad Request","details":"Missing required field: user_id"}}',
     '{"Content-Type":"application/json"}',
     400),
    (5, '2024-01-15 08:04:00', '/api/search',
     '{"query":"clickhouse","filters":{"category":"database","price_range":{"min":0,"max":1000}},"page":1}',
     '{"results":[{"id":1,"score":0.95},{"id":2,"score":0.87},{"id":3,"score":0.76}],"total":3,"page":1}',
     '{"Content-Type":"application/json","Accept":"*/*"}',
     200);

-- 用户画像表（JSON 类型，实验性）
CREATE TABLE user_profiles (
    id UInt64,
    name String,
    -- 注意：JSON 类型在 CH 25.12 中仍为实验性功能
    -- 需要 SET allow_experimental_json_type = 1
    profile JSON
) ENGINE = MergeTree()
ORDER BY id;

INSERT INTO user_profiles VALUES
    (1, 'Alice', '{"age":30,"city":"New York","tags":["premium","active"],"preferences":{"theme":"light","lang":"en"}}'),
    (2, 'Bob', '{"age":25,"city":"London","tags":["standard"],"preferences":{"theme":"dark","lang":"fr"}}'),
    (3, 'Charlie', '{"age":35,"city":"Tokyo","tags":["premium","vip"],"preferences":{"theme":"auto","lang":"ja"}}');

-- 多层嵌套 JSON 表
CREATE TABLE nested_json (
    id UInt64,
    data String
) ENGINE = MergeTree()
ORDER BY id;

INSERT INTO nested_json VALUES
    (1, '{"company":"TechCorp","departments":[{"name":"Engineering","employees":[{"id":1,"name":"Alice","skills":["Python","SQL"]},{"id":2,"name":"Bob","skills":["Java","K8s"]}]},{"name":"Sales","employees":[{"id":3,"name":"Charlie","skills":["CRM","Excel"]}]}],"metadata":{"founded":2010,"active":true}}');


-- ============================================================
-- 1. JSON 处理原理
-- ============================================================
-- 【原理】ClickHouse 提供三种 JSON 处理方案：
--
--   方案 A：String 列 + JSONExtract* 函数
--     原理：JSON 存为 String，每次查询时解析。每行独立解析，走
--           RapidJSON 库，无缓存。
--     优点：兼容已有数据，灵活，支持 JSONPath
--     缺点：每次查询都解析，速度慢；不支持索引
--     适用：低频查询、已有 String 列存 JSON
--
--   方案 B：visitParam* 函数（已废弃）
--     原理：轻量级解析，只读一层 key，不做递归解析。
--           较 JSONExtract 快但功能有限。
--     优点：比 JSONExtract 快
--     缺点：只支持扁平 JSON，不支持嵌套路径
--     适用：仅兼容遗留查询（不应在新代码中使用）
--
--   方案 C：JSON 原生类型（实验性）
--     原理：数据写入时解析为内部二进制格式，按子列存储。
--           查询时直接按子列读取，无需再次解析。
--     优点：查询快（按列读取），支持子列索引
--     缺点：存储空间略大，写入开销大，实验性功能
--     适用：新建表、高频查询 JSON 字段
--
-- 【场景】API 日志解析、用户画像、事件追踪、配置存储
-- 【对比决策树】见 README §5.3


-- ============================================================
-- 2. JSONExtract 系列函数
-- ============================================================
-- 【原理】JSONExtract(json_str, 'path', Type) 从 JSON 字符串中
--   按路径提取指定类型的值。每个函数名标明了返回类型：
--   JSONExtractString  → String
--   JSONExtractInt     → Int64
--   JSONExtractUInt    → UInt64
--   JSONExtractFloat   → Float64
--   JSONExtractBool    → Bool
--   JSONExtractArrayRaw → Array(String) 原始 JSON 数组
--   JSONExtractKeysAndValues → Map(String, String)
--   JSONExtract(json, path, type) → 通用版，type 为类型字符串

-- 2.1 基础提取：按类型提取顶层字段
-- 【场景】解析 API 请求体中的用户信息
SELECT
    id,
    request_body,
    JSONExtractString(request_body, 'name') AS user_name,
    JSONExtractUInt(request_body, 'user_id') AS user_id,
    JSONExtractString(request_body, 'email') AS email
FROM api_logs
WHERE endpoint = '/api/users'
ORDER BY id;

-- 2.2 提取布尔值
-- 【场景】解析响应体中的状态字段
-- 注意：JSON 中的 "ok" 是字符串，不是 true/false
SELECT
    id,
    JSONExtractString(response_body, 'status') AS status_str,
    JSONExtractBool(response_body, 'status') AS status_bool  -- 非布尔值返回 0
FROM api_logs
WHERE endpoint = '/api/users'
ORDER BY id;

-- 2.3 提取数值
-- 【场景】解析订单金额
SELECT
    id,
    request_body,
    JSONExtractFloat(request_body, 'total') AS order_total
FROM api_logs
WHERE endpoint = '/api/orders'
ORDER BY id;

-- 2.4 提取数组（原始 JSON 字符串）
-- 【场景】提取标签数组
SELECT
    id,
    JSONExtractArrayRaw(request_body, 'tags') AS tags_raw
FROM api_logs
WHERE endpoint = '/api/users'
ORDER BY id;

-- 2.5 提取数组并展开
-- 【场景】用户的每个标签一行
SELECT
    id,
    JSONExtractString(request_body, 'name') AS user_name,
    arrayJoin(JSONExtractArrayRaw(request_body, 'tags')) AS tag
FROM api_logs
WHERE endpoint = '/api/users'
ORDER BY id, tag;

-- 2.6 通用 JSONExtract（指定类型字符串）
-- 【原理】第三个参数是 ClickHouse 类型名（字符串形式）
SELECT
    id,
    JSONExtract(request_body, 'user_id', 'UInt64') AS user_id,
    JSONExtract(response_body, 'status', 'String') AS status,
    JSONExtract(response_body, 'data.age', 'UInt32') AS age
FROM api_logs
WHERE endpoint = '/api/users'
ORDER BY id;


-- ============================================================
-- 3. JSON 查询路径语法
-- ============================================================
-- 【原理】JSONExtract 支持两种路径语法：
--   1. 简单路径：'key' 或 'key.subkey'（点分隔）
--   2. JSONPath 语法：'$.key.subkey'（标准 JSONPath）
--      $.key            → 顶层 key
--      $.key.subkey     → 嵌套子 key
--      $.arr[0]         → 数组第 0 个元素
--      $.arr[*]         → 数组所有元素
-- 【场景】嵌套 JSON 提取

-- 3.1 简单路径（点分隔，最常用）
-- 【场景】提取嵌套对象中的字段
SELECT
    id,
    JSONExtractString(response_body, 'data.age') AS age,         -- 点分隔路径
    JSONExtractString(response_body, 'data.city') AS city,
    JSONExtractString(response_body, 'data.preferences.theme') AS theme,
    JSONExtractString(response_body, 'data.preferences.lang') AS lang
FROM api_logs
WHERE endpoint = '/api/users' AND id = 3
ORDER BY id;

-- 3.2 JSONPath 语法（$ 开头，标准路径）
-- 【场景】使用标准 JSONPath 提取
SELECT
    id,
    JSONExtractString(response_body, '$.data.age') AS jsonpath_age,
    JSONExtractString(response_body, '$.data.preferences.theme') AS jsonpath_theme
FROM api_logs
WHERE endpoint = '/api/users' AND id = 3
ORDER BY id;

-- 3.3 JSONPath 数组访问
-- 【场景】提取数组元素
SELECT
    id,
    -- 提取数组第 0 个元素
    JSONExtractString(request_body, '$.items[0].product_id') AS first_product,
    JSONExtractUInt(request_body, '$.items[0].qty') AS first_qty,
    -- 提取数组所有元素
    JSONExtractArrayRaw(request_body, '$.items') AS all_items
FROM api_logs
WHERE endpoint = '/api/orders'
ORDER BY id;

-- 3.4 错误路径处理
-- 【场景】路径不存在时返回 NULL 或 0
SELECT
    id,
    JSONExtractString(request_body, 'nonexistent') AS no_value,       -- NULL
    JSONExtractUInt(request_body, 'nonexistent') AS no_value_int,     -- 0
    JSONExtract(request_body, 'nonexistent', 'Nullable(String)') AS no_value_nullable  -- NULL
FROM api_logs
ORDER BY id;


-- ============================================================
-- 4. JSONHas / JSONLength / JSONExtractKeys / JSONType
-- ============================================================
-- 【原理】这些函数用于检查 JSON 结构，不提取值：
--   JSONHas(json, path)  → 检查路径是否存在（返回 1/0）
--   JSONLength(json, path) → 返回数组或对象的长度
--   JSONExtractKeys(json) → 返回对象的所有 key（Array(String)，25.12 起替代旧 JSONKeys）
--   JSONType(json, path)  → 返回值的类型名（String）
-- 【场景】数据验证、模式发现、脏数据检测

-- 4.1 JSONHas：检查字段是否存在
-- 【场景】检查 API 请求是否包含特定字段
SELECT
    id,
    endpoint,
    JSONHas(request_body, 'user_id') AS has_user_id,
    JSONHas(request_body, 'items') AS has_items,
    JSONHas(response_body, 'error') AS has_error
FROM api_logs
ORDER BY id;

-- 4.2 JSONLength：获取数组或对象长度
-- 【场景】统计数组大小
SELECT
    id,
    endpoint,
    JSONLength(request_body, 'tags') AS tag_count,
    JSONLength(request_body, 'items') AS item_count,
    JSONLength(response_body, 'results') AS result_count
FROM api_logs
ORDER BY id;

-- 4.3 JSONExtractKeys：获取对象的所有 key
-- 【场景】发现 JSON 对象的结构
SELECT
    id,
    endpoint,
    JSONExtractKeys(request_body) AS request_keys,
    JSONExtractKeys(response_body) AS response_keys,
    JSONExtractKeys(headers) AS header_keys
FROM api_logs
ORDER BY id;

-- 4.4 JSONType：获取值的类型
-- 【场景】检查字段的数据类型（用于调试脏数据）
SELECT
    id,
    JSONType(request_body, 'user_id') AS type_of_user_id,
    JSONType(request_body, 'name') AS type_of_name,
    JSONType(request_body, 'tags') AS type_of_tags,
    JSONType(request_body, 'items') AS type_of_items
FROM api_logs
ORDER BY id;

-- 4.5 综合应用：JSON 结构探索
-- 【场景】分析 API 日志中的 JSON 结构
SELECT
    id,
    endpoint,
    JSONHas(request_body, 'user_id') AS has_user_id,
    JSONHas(request_body, 'items') AS has_items,
    JSONLength(request_body, 'items') AS item_count,
    JSONType(request_body, 'total') AS total_type
FROM api_logs
ORDER BY id;


-- ============================================================
-- 5. JSON 数组与嵌套处理
-- ============================================================
-- 【原理】处理 JSON 数组需要组合使用：
--   JSONExtractArrayRaw(json, path) → 提取为 Array(String)
--   arrayJoin → 展开为多行
--   再对每个元素做 JSONExtract
-- 【场景】嵌套 JSON 数组的解析

-- 5.1 提取 JSON 数组并展开
-- 【场景】API 搜索结果展开
SELECT
    id,
    arrayJoin(JSONExtractArrayRaw(response_body, 'results')) AS result_raw
FROM api_logs
WHERE endpoint = '/api/search'
ORDER BY id;

-- 5.2 展开后提取每个元素字段
-- 【场景】搜索结果的结构化解析
SELECT
    id,
    JSONExtractUInt(result_raw, 'id') AS result_id,
    JSONExtractFloat(result_raw, 'score') AS score
FROM (
    SELECT
        id,
        arrayJoin(JSONExtractArrayRaw(response_body, 'results')) AS result_raw
    FROM api_logs
    WHERE endpoint = '/api/search'
)
ORDER BY result_id;

-- 5.3 深层嵌套 JSON 解析
-- 【场景】解析公司部门员工结构
WITH departments AS (
    SELECT
        id,
        arrayJoin(JSONExtractArrayRaw(data, 'departments')) AS dept
    FROM nested_json
)
SELECT
    id,
    JSONExtractString(dept, 'name') AS dept_name,
    employees_raw
FROM departments
ARRAY JOIN JSONExtractArrayRaw(dept, 'employees') AS employees_raw
ORDER BY dept_name;

-- 5.4 三层嵌套：公司 → 部门 → 员工 → 技能
-- 【场景】每个员工及其技能
WITH departments AS (
    SELECT
        id,
        arrayJoin(JSONExtractArrayRaw(data, 'departments')) AS dept
    FROM nested_json
),
employees AS (
    SELECT
        id,
        JSONExtractString(dept, 'name') AS dept_name,
        arrayJoin(JSONExtractArrayRaw(dept, 'employees')) AS emp
    FROM departments
)
SELECT
    id,
    dept_name,
    JSONExtractString(emp, 'name') AS emp_name,
    JSONExtractArrayRaw(emp, 'skills') AS skills
FROM employees
ORDER BY dept_name, emp_name;

-- 5.5 JSON 数组聚合
-- 【场景】收集所有员工的技能（去重）
WITH departments AS (
    SELECT
        arrayJoin(JSONExtractArrayRaw(data, 'departments')) AS dept
    FROM nested_json
),
employees AS (
    SELECT
        arrayJoin(JSONExtractArrayRaw(dept, 'employees')) AS emp
    FROM departments
)
SELECT
    groupUniqArray(skill) AS all_skills
FROM (
    SELECT
        arrayJoin(JSONExtractArrayRaw(emp, 'skills')) AS skill
    FROM employees
);


-- ============================================================
-- 6. visitParam 系列（已废弃，兼容性说明）
-- ============================================================
-- 【原理】visitParam 系列是 ClickHouse 早期的轻量 JSON 解析函数，
--   只支持扁平 JSON（一层 key），不做递归解析，比 JSONExtract 快。
--   从 CH 22.x 起已废弃，推荐用 JSONExtract* 替代。
-- 【场景】仅用于兼容遗留查询，新代码不应使用。
-- 【坑】visitParam 不支持嵌套路径，如 'data.age' 会失败。

-- 6.1 visitParamExtractString / visitParamExtractUInt
-- 【对比】vs JSONExtractString
SELECT
    id,
    -- visitParam 风格（已废弃）
    visitParamExtractString(request_body, 'name') AS vp_name,
    visitParamExtractUInt(request_body, 'user_id') AS vp_user_id,
    -- JSONExtract 风格（推荐）
    JSONExtractString(request_body, 'name') AS je_name,
    JSONExtractUInt(request_body, 'user_id') AS je_user_id
FROM api_logs
WHERE endpoint = '/api/users'
ORDER BY id;

-- 6.2 visitParam 的局限：不支持嵌套路径
-- 【场景】尝试用 visitParam 提取嵌套字段
-- 【结果】visitParam 返回空字符串，JSONExtract 正常工作
SELECT
    id,
    visitParamExtractString(response_body, 'data.age') AS vp_age,         -- 空
    JSONExtractString(response_body, 'data.age') AS je_age,               -- 有值
    visitParamExtractString(response_body, 'data.city') AS vp_city,       -- 空
    JSONExtractString(response_body, 'data.city') AS je_city              -- 有值
FROM api_logs
WHERE endpoint = '/api/users' AND id = 1
ORDER BY id;

-- 6.3 visitParam 的局限：不支持数组
-- 【场景】尝试用 visitParam 提取数组
-- 【结果】visitParam 返回原始字符串，JSONExtractArrayRaw 返回数组
SELECT
    id,
    visitParamExtractString(request_body, 'tags') AS vp_tags,  -- 原始 JSON 字符串
    JSONExtractArrayRaw(request_body, 'tags') AS je_tags       -- 解析后的数组
FROM api_logs
WHERE endpoint = '/api/users'
ORDER BY id;

-- 6.4 visitParam 迁移指南
-- 【迁移对照表】
--   废弃函数                      | 替代函数
--   ------------------------------|---------------------------
--   visitParamExtractString(s,k)  | JSONExtractString(s,k)
--   visitParamExtractUInt(s,k)    | JSONExtractUInt(s,k)
--   visitParamExtractInt(s,k)     | JSONExtractInt(s,k)
--   visitParamExtractFloat(s,k)   | JSONExtractFloat(s,k)
--   visitParamExtractBool(s,k)    | JSONExtractBool(s,k)
--   visitParamExtractRaw(s,k)     | JSONExtractRaw(s,k)
--   visitParamHas(s,k)            | JSONHas(s,k)
--   visitParamKeys(s)             | JSONExtractKeys(s)（25.12 起）
--   visitParamNum(s)              | JSONLength(s)


-- ============================================================
-- 7. JSON 类型（实验性原生类型）
-- ============================================================
-- 【原理】JSON 类型是 ClickHouse 22.6+ 引入的实验性功能。
--   写入时解析 JSON 为内部二进制格式，按子列（subcolumn）存储。
--   查询时直接读取子列，无需解析。
--   优点：查询快、支持子列索引、自动类型推断
--   缺点：存储略大、写入慢、实验性功能
-- 【场景】高频查询的 JSON 字段、新建表
-- 【注意】需要 SET allow_experimental_json_type = 1

-- 7.1 启用 JSON 类型
SET allow_experimental_json_type = 1;

-- 7.2 查询 JSON 类型列
-- 【原理】JSON 类型的子列直接用 `.` 访问（类似 struct）
SELECT
    id,
    name,
    profile.age,                    -- 直接访问子列
    profile.city,
    profile.tags,
    profile.preferences.theme      -- 嵌套子列
FROM user_profiles
ORDER BY id;

-- 7.3 JSON 类型子列的类型推断
-- 【原理】JSON 类型自动推断每个子列的类型
-- 查看表结构
DESCRIBE TABLE user_profiles;

-- 7.4 JSON 类型子列在 WHERE 中使用
-- 【场景】按 JSON 子列过滤
SELECT
    id,
    name,
    profile.age,
    profile.city,
    profile.preferences.theme
FROM user_profiles
WHERE profile.age > 28
  AND profile.city = 'New York'
ORDER BY id;

-- 7.5 JSON 类型子列聚合
-- 【场景】按 JSON 子列分组聚合
-- 【坑】Dynamic 类型不能直接 GROUP BY / 聚合，需用 `.:类型` 后缀取具体子列
SELECT
    profile.preferences.theme.:String AS theme,
    count() AS user_count,
    avg(profile.age.:Int64) AS avg_age
FROM user_profiles
GROUP BY theme
ORDER BY user_count DESC;

-- 7.6 JSON 类型子列与函数混合使用
-- 【场景】JSON 类型列用子列访问 + 普通 String 列用 JSONExtract
-- 【坑】JSON 类型列不能直接传给 JSONExtract*（类型不是 String），
--       混合数据源时先用 toString(profile) 转成 String 再解析
SELECT
    id,
    name,
    profile.age.:Int64 AS age,
    JSONExtractString(toString(profile), 'city') AS city_alt
FROM user_profiles
ORDER BY id;


-- ============================================================
-- 8. 新旧 JSON 函数对比
-- ============================================================
-- 【原理】全面对比三种方案

-- 8.1 功能对比表
-- 【对比】
--   特性                | JSONExtract* | visitParam* | JSON 类型
--   --------------------|--------------|-------------|----------
--   支持嵌套路径        | ✅           | ❌          | ✅
--   支持 JSONPath       | ✅           | ❌          | ✅
--   支持数组            | ✅           | ❌          | ✅
--   查询速度            | 慢           | 中          | 快
--   写入速度            | 快           | 快          | 中
--   存储空间            | 小(String)   | 小(String)  | 中
--   支持索引            | ❌           | ❌          | ✅(子列)
--   是否需要 SET        | ❌           | ❌          | ✅
--   状态                | 稳定         | 已废弃      | 实验性

-- 8.2 性能对比（直观演示）
-- 【场景】同数据量下三种方案查询速度对比
-- 【注意】以下仅展示查询逻辑，实际性能测试需在亿级数据跑

-- 方案 A：String + JSONExtract（通用方案）
SELECT
    id,
    JSONExtractString(response_body, 'data.age') AS age,
    JSONExtractString(response_body, 'data.city') AS city
FROM api_logs
WHERE endpoint = '/api/users'
ORDER BY id;

-- 方案 B：String + visitParam（仅扁平、已废弃）
SELECT
    id,
    visitParamExtractString(request_body, 'name') AS name
FROM api_logs
WHERE endpoint = '/api/users'
ORDER BY id;

-- 方案 C：JSON 类型（需要 SET 启用）
SET allow_experimental_json_type = 1;
SELECT
    id,
    name,
    profile.age,
    profile.city
FROM user_profiles
ORDER BY id;

-- 8.3 选型建议
-- 【场景①】已有 String 列存 JSON，低频查询
--   推荐：JSONExtract*（无需改表结构）
-- 【场景②】已有 String 列存 JSON，高频查询
--   推荐：物化列提取高频字段 + JSONExtract* 兜底
-- 【场景③】新建表，JSON 字段查询频繁
--   推荐：JSON 类型（实验性）或抽成普通列
-- 【场景④】遗留代码用 visitParam*
--   推荐：逐步迁移到 JSONExtract*（见 §6.4 迁移表）


-- ============================================================
-- 9. 性能对比：JSON 类型 vs String + JSONExtract
-- ============================================================
-- 【原理】JSON 类型写入时解析，子列按列存，查询时零解析开销。
--   String + JSONExtract 每次查询都解析，CPU 开销大。
-- 【场景】以下测试展示两种方案在相同查询下的差异

-- 9.1 测试数据准备
DROP TABLE IF EXISTS perf_json_string;
DROP TABLE IF EXISTS perf_json_type;

-- String 方案表
CREATE TABLE perf_json_string (
    id UInt64,
    data String
) ENGINE = MergeTree()
ORDER BY id;

-- JSON 类型方案表（需要 SET）
SET allow_experimental_json_type = 1;

CREATE TABLE perf_json_type (
    id UInt64,
    data JSON
) ENGINE = MergeTree()
ORDER BY id;

-- 插入相同数据
-- 注：拼 JSON 字符串用 concat 更直观；format 的 {{ }} 转义与 {n} 占位混用易歧义
INSERT INTO perf_json_string SELECT
    number,
    concat('{"user_id":', toString(number),
           ',"name":"User_', toString(number),
           '","score":', toString(number % 100),
           ',"active":', if(number % 2 = 0, 'true', 'false'), '}')
FROM numbers(1000);

INSERT INTO perf_json_type SELECT
    number,
    concat('{"user_id":', toString(number),
           ',"name":"User_', toString(number),
           '","score":', toString(number % 100),
           ',"active":', if(number % 2 = 0, 'true', 'false'), '}')
FROM numbers(1000);

-- 9.2 查询性能对比
-- 【原理】String 方案每次解析 JSON；JSON 类型直接读子列

-- 方案 A：String + JSONExtract
SELECT
    JSONExtractUInt(data, 'user_id') AS user_id,
    JSONExtractString(data, 'name') AS name,
    JSONExtractUInt(data, 'score') AS score
FROM perf_json_string
WHERE JSONExtractUInt(data, 'score') > 50
ORDER BY score DESC
LIMIT 10;

-- 方案 B：JSON 类型
SELECT
    data.user_id.:UInt64 AS user_id,
    data.name.:String AS name,
    data.score.:UInt8 AS score
FROM perf_json_type
WHERE data.score.:UInt8 > 50
ORDER BY data.score.:UInt8 DESC
LIMIT 10;

-- 9.3 性能结论
-- 【结论】JSON 类型在以下场景优势明显：
--   1. 多次查询同一 JSON 字段（只需解析一次写入时）
--   2. 使用 WHERE 过滤 JSON 子列（JSON 类型支持子列索引）
--   3. 聚合 JSON 子列（直接读列存，无解析开销）
-- 【结论】String + JSONExtract 在以下场景仍可用：
--   1. JSON 字段查询频率低
--   2. 需要兼容已有表结构
--   3. 写入速度敏感（JSON 类型写入慢约 30%）


-- ============================================================
-- 10. 实际 JSON 数据处理实战
-- ============================================================
-- 【场景】综合运用 JSON 函数解决实际问题

-- 10.1 实战：API 日志分析
-- 【场景】统计各 API 端点的请求量、错误率、平均响应数据大小
SELECT
    endpoint,
    count() AS total_requests,
    countIf(status_code >= 400) AS error_count,
    round(countIf(status_code >= 400) / count() * 100, 2) AS error_pct,
    -- 解析 JSON 中的字段
    uniq(JSONExtractUInt(request_body, 'user_id')) AS unique_users,
    countIf(JSONHas(request_body, 'items')) AS order_requests
FROM api_logs
GROUP BY endpoint
ORDER BY total_requests DESC;

-- 10.2 实战：用户画像聚合
-- 【场景】从 JSON 类型的用户画像中分析用户分布
SET allow_experimental_json_type = 1;

SELECT
    profile.preferences.theme.:String AS theme,
    profile.preferences.lang.:String AS lang,
    count() AS user_count,
    avg(profile.age.:Int64) AS avg_age,
    -- 数组长度（数组子列已推断类型，可直接访问；用 avg 聚合）
    avg(length(profile.tags)) AS avg_tag_count
FROM user_profiles
GROUP BY theme, lang
ORDER BY user_count DESC;

-- 10.3 实战：订单数据处理
-- 【场景】从 API 请求中提取订单信息并结构化
SELECT
    id,
    request_time,
    JSONExtractUInt(request_body, 'user_id') AS user_id,
    JSONExtractFloat(request_body, 'total') AS order_total,
    -- 提取数组中的商品
    JSONExtractArrayRaw(request_body, 'items') AS items_raw,
    -- 计算商品数量
    JSONLength(request_body, 'items') AS item_count,
    -- 提取第一个商品 ID
    JSONExtractUInt(request_body, '$.items[0].product_id') AS first_product_id,
    JSONExtractUInt(request_body, '$.items[0].qty') AS first_product_qty
FROM api_logs
WHERE endpoint = '/api/orders'
ORDER BY id;

-- 10.4 实战：JSON 数据清洗与验证
-- 【场景】检查 JSON 数据完整性，标记脏数据
SELECT
    id,
    endpoint,
    request_body,
    multiIf(
        NOT JSONHas(request_body, 'user_id') AND endpoint LIKE '/api/user%', 'Missing user_id',
        NOT JSONHas(request_body, 'items') AND endpoint = '/api/orders', 'Missing items',
        'Valid'
    ) AS validation_status,
    -- 如果缺少字段，提供默认值
    JSONExtractString(request_body, 'name', 'Anonymous') AS safe_name,
    JSONExtractUInt(request_body, 'user_id', 0) AS safe_user_id
FROM api_logs
ORDER BY id;

-- 10.5 实战：JSON 路径不存在时的安全处理
-- 【场景】使用 JSONExtract 的默认值参数（CH 22.3+ 支持）
SELECT
    id,
    request_body,
    -- 带默认值的提取（如果路径不存在）
    JSONExtractString(request_body, 'name', 'N/A') AS name_with_default,
    JSONExtractUInt(request_body, 'user_id', 0) AS user_id_with_default,
    -- 不带默认值（路径不存在返回 NULL 或 0）
    JSONExtractString(request_body, 'name') AS name_no_default,
    JSONExtractUInt(request_body, 'user_id') AS user_id_no_default
FROM api_logs
ORDER BY id;


-- ============================================================
-- 11. 清理
-- ============================================================
DROP DATABASE IF EXISTS func_test;