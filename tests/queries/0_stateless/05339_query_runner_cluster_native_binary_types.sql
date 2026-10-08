CREATE TABLE runner (query String, database String, settings Map(String, String)) ENGINE = QueryRunner SETTINGS cluster = 'test_shard_localhost', mode = 'synchronous';
INSERT INTO runner SELECT 'SELECT number, number::Dynamic AS d, dynamicType(d) FROM numbers(3)', currentDatabase(),
    map('log_comment', 'runner_' || name, 'output_format_native_encode_types_in_binary_format', encode, 'input_format_native_decode_types_in_binary_format', decode)
FROM values('name String, encode String, decode String', ('both', '1', '1'), ('encode', '1', '0'), ('decode', '0', '1'));
SYSTEM FLUSH LOGS query_log;
SELECT log_comment, type, exception_code FROM system.query_log
WHERE event_date >= yesterday() AND current_database = currentDatabase() AND log_comment LIKE 'runner_%' AND is_internal AND type != 'QueryStart'
ORDER BY log_comment;
DROP TABLE runner;
