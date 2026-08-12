DROP DATABASE IF EXISTS test_alts;
CREATE DATABASE test_alts;
CREATE TABLE test_alts.t (event_date Date, user_id UInt32) ENGINE=MergeTree() PARTITION BY toYYYYMM(event_date) ORDER BY event_date;
INSERT INTO test_alts.t SELECT toDate('2024-01-01') + number%31, number FROM numbers(100);
