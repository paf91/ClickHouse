-- Tags: no-fasttest
-- Tag no-fasttest: depends on S3 and Parquet

-- A filter or a row policy on a column that is added after the data file is read (a Hive partition column,
-- a virtual column) uses the value of that column, even when the data file has a column with the same name.

-- The path says `key = 9`, the data files store `key = 10`, NULL and `_file = 'evil'`.
INSERT INTO FUNCTION file(currentDatabase() || '/05321/key=9/data.parquet', Parquet, 'key Int64, v Int64') SELECT 10, number FROM numbers(1000) SETTINGS engine_file_truncate_on_insert = 1, output_format_parquet_row_group_size = 100;
INSERT INTO FUNCTION file(currentDatabase() || '/05321/nullable/key=9/data.parquet', Parquet, 'key Nullable(Int64), v Int64') SELECT NULL, number FROM numbers(1000) SETTINGS engine_file_truncate_on_insert = 1, output_format_parquet_row_group_size = 100;
INSERT INTO FUNCTION file(currentDatabase() || '/05321/virtual/data.parquet', Parquet, '_file String, v Int64') SELECT 'evil', number FROM numbers(1000) SETTINGS engine_file_truncate_on_insert = 1, output_format_parquet_row_group_size = 100;
INSERT INTO FUNCTION s3(s3_conn, filename = currentDatabase() || '/05321/key=9/data.parquet', format = Parquet, structure = 'key Int64, v Int64') SELECT 10, number FROM numbers(1000) SETTINGS s3_truncate_on_insert = 1, output_format_parquet_row_group_size = 100;

SET use_hive_partitioning = 1, optimize_count_from_files = 0;
SET input_format_parquet_filter_push_down = 1, input_format_parquet_bloom_filter_push_down = 1, input_format_parquet_page_filter_push_down = 1, input_format_parquet_dictionary_filter_push_down = 1048576;

-- { echoOn }
SELECT key, count() FROM file(currentDatabase() || '/05321/key=9/data.parquet', Parquet, 'key Int64, v Int64') GROUP BY key;
SELECT count() FROM file(currentDatabase() || '/05321/key=9/data.parquet', Parquet, 'key Int64, v Int64') WHERE key = 9;
SELECT count() FROM file(currentDatabase() || '/05321/key=9/data.parquet', Parquet, 'key Int64, v Int64') WHERE key = 10;
SELECT count() FROM file(currentDatabase() || '/05321/key=9/data.parquet', Parquet, 'key Int64, v Int64') WHERE key = 9 AND v < 10;
SELECT count() FROM file(currentDatabase() || '/05321/key=9/data.parquet', Parquet, 'key Int64, v Int64') WHERE key = 9 OR v < 10;
SELECT count() FROM file(currentDatabase() || '/05321/key=9/data.parquet', Parquet, 'key Int64, v Int64') WHERE key IN (9);
SELECT count(), sum(v) FROM file(currentDatabase() || '/05321/key=9/data.parquet', Parquet) WHERE key = 9;
SELECT count() FROM file(currentDatabase() || '/05321/nullable/key=9/data.parquet', Parquet, 'key Nullable(Int64), v Int64') WHERE key IS NOT NULL;

SELECT count() FROM s3(s3_conn, filename = currentDatabase() || '/05321/key=9/data.parquet', format = Parquet, structure = 'key Int64, v Int64') WHERE key = 9 SETTINGS use_query_condition_cache = 1;
SELECT count() FROM s3(s3_conn, filename = currentDatabase() || '/05321/key=9/data.parquet', format = Parquet, structure = 'key Int64, v Int64') WHERE key = 9 SETTINGS use_query_condition_cache = 1;
SELECT count() FROM url('http://localhost:11111/test/' || currentDatabase() || '/05321/key=9/data.parquet', Parquet, 'key Int64, v Int64') WHERE key = 9;

SELECT _file, count() FROM file(currentDatabase() || '/05321/virtual/data.parquet', Parquet, 'v Int64') GROUP BY _file;
SELECT count() FROM file(currentDatabase() || '/05321/virtual/data.parquet', Parquet, 'v Int64') WHERE _file = 'data.parquet';

CREATE TABLE t_05321_file AS file(currentDatabase() || '/05321/key=9/data.parquet', Parquet, 'key Int64, v Int64');
CREATE ROW POLICY p_05321_file ON t_05321_file USING key = 9 TO ALL;
SELECT count() FROM t_05321_file;
DROP ROW POLICY p_05321_file ON t_05321_file;
DROP TABLE t_05321_file;

-- The format still prunes row groups on the columns of the data file.
SELECT count() FROM file(currentDatabase() || '/05321/key=9/data.parquet', Parquet, 'key Int64, v Int64') WHERE key = 9 AND v < 10 SETTINGS log_comment = '05321_prune';
SYSTEM FLUSH LOGS query_log;
SELECT ProfileEvents['ParquetPrunedRowGroups'] > 0 FROM system.query_log WHERE current_database = currentDatabase() AND log_comment = '05321_prune' AND type = 'QueryFinish';
