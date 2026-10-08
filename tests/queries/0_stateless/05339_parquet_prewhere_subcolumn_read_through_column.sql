-- Tags: no-fasttest
-- Tag no-fasttest: needs Parquet and s3
-- Random settings limits: optimize_move_to_prewhere=(1, 1); query_plan_optimize_prewhere=(1, 1); query_plan_remove_unused_columns=(1, 1)

-- A Parquet read with PREWHERE must still return the subcolumns that the format reads through their
-- whole column (`n.null`, `arr.size0`), also when nothing above uses them (`indexHint`).

INSERT INTO FUNCTION file(currentDatabase() || '_05339.parquet')
SELECT number, if(number % 3 = 0, NULL, number) AS n, range(number % 4) AS arr, (number, toString(number))::Tuple(a UInt64, b String) AS t
FROM numbers(100)
SETTINGS engine_file_truncate_on_insert = 1;

SELECT 'file';
SELECT count(), sum(number) FROM file(currentDatabase() || '_05339.parquet') WHERE indexHint(n.null) AND number > 5;
SELECT indexHint(n.null), number FROM file(currentDatabase() || '_05339.parquet') WHERE number > 96 ORDER BY number;
SELECT countIf(n.null), sum(arr.size0), count() FROM file(currentDatabase() || '_05339.parquet') WHERE number > 5;
SELECT countIf(n.null), count() FROM file(currentDatabase() || '_05339.parquet') WHERE n > 5 OR number < 3;
SELECT countIf(n.null), count() FROM file(currentDatabase() || '_05339.parquet') PREWHERE n > 5 OR number < 3;
SELECT n.null, number FROM file(currentDatabase() || '_05339.parquet') WHERE number > 5 ORDER BY number LIMIT 3
SETTINGS query_plan_optimize_lazy_materialization = 1, query_plan_max_limit_for_lazy_materialization = 10;
SELECT sum(t.a), sum(length(t.b)) FROM file(currentDatabase() || '_05339.parquet') WHERE number > 5;

INSERT INTO FUNCTION s3(s3_conn, filename = currentDatabase() || '/05339.parquet', format = Parquet)
SELECT number, if(number % 3 = 0, NULL, number) AS n, range(number % 4) AS arr
FROM numbers(100)
SETTINGS s3_truncate_on_insert = 1;

SELECT 's3';
SELECT count(), sum(number) FROM s3(s3_conn, filename = currentDatabase() || '/05339.parquet', format = Parquet) WHERE indexHint(n.null) AND number > 5;
SELECT indexHint(n.null), number FROM s3(s3_conn, filename = currentDatabase() || '/05339.parquet', format = Parquet) WHERE number > 96 ORDER BY number;
SELECT countIf(n.null), sum(arr.size0), count() FROM s3(s3_conn, filename = currentDatabase() || '/05339.parquet', format = Parquet) WHERE number > 5;
