DROP DATABASE IF EXISTS troubleshooting_test;
CREATE DATABASE IF NOT EXISTS troubleshooting_test;
DROP TABLE IF EXISTS troubleshooting_test.sample_table SYNC;
DROP DATABASE IF EXISTS troubleshooting_test;
CREATE DATABASE troubleshooting_test;
CREATE TABLE troubleshooting_test.sample_table
(
    event_date Date,
    user_id UInt32,
    amount Float64
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/1/troubleshooting_test/sample_table', '1')
PARTITION BY toYYYYMM(event_date)
ORDER BY (event_date, user_id);
SELECT 'CREATE1-OK';
DROP DATABASE IF EXISTS troubleshooting_test;
CREATE DATABASE IF NOT EXISTS troubleshooting_test;
DROP TABLE IF EXISTS troubleshooting_test.sample_table SYNC;
DROP DATABASE IF EXISTS troubleshooting_test;
CREATE DATABASE troubleshooting_test;
CREATE TABLE troubleshooting_test.sample_table
(
    event_date Date,
    user_id UInt32,
    amount Float64
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/1/troubleshooting_test/sample_table', '1')
PARTITION BY toYYYYMM(event_date)
ORDER BY (event_date, user_id);
SELECT 'CREATE2-OK';
DROP DATABASE IF EXISTS troubleshooting_test;
