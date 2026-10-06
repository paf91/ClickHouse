#!/usr/bin/env bash
# Tags: no-fasttest
# no-fasttest: SET ast_fuzzer_runs / ast_fuzzer_oracle are EXPERIMENTAL-tier settings and
#              are not allowed when `allow_feature_tier=0` (the Fast test default).
#
# `ANY INNER JOIN` keeps one row per join key, and which row survives depends on the plan. The TLP
# rewrite filters each partition before the join, so the partitions together keep more rows than
# the reference, and the oracles must skip such a query instead of reporting a mismatch. The query
# result depends on the plan too, so only the oracle errors are counted.

CUR_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../shell_config.sh
. "$CUR_DIR"/../shell_config.sh

$CLICKHOUSE_CLIENT --query "
    DROP VIEW IF EXISTS oracle_any_join_view;
    DROP VIEW IF EXISTS oracle_default_join_view;
    DROP VIEW IF EXISTS oracle_threads_view;
    DROP TABLE IF EXISTS oracle_any_join;
    CREATE TABLE oracle_any_join (v Int64, w UInt64) ENGINE = MergeTree ORDER BY v;
    INSERT INTO oracle_any_join SELECT number, number % 3 + 1 FROM numbers(100);
    CREATE VIEW oracle_any_join_view AS SELECT v, w FROM oracle_any_join ANY INNER JOIN oracle_any_join AS a ON w = a.w;
    CREATE VIEW oracle_default_join_view AS SELECT v, w FROM oracle_any_join INNER JOIN oracle_any_join AS a ON w = a.w
        SETTINGS join_default_strictness = 'ANY';
    CREATE VIEW oracle_threads_view AS SELECT v, w FROM oracle_any_join SETTINGS max_threads = 8;
"

# Prints how many of 30 runs of the query raise an oracle mismatch. `--ignore-error` keeps the
# batch going after a statement raises.
count_mismatches()
{
    local settings="$1"
    local query="$2"

    $CLICKHOUSE_CLIENT --ignore-error --query "
        SET send_logs_level = 'fatal';
        $settings
        SET ast_fuzzer_runs = 1;
        SET ast_fuzzer_oracle = 1;
        $(for _ in $(seq 1 30); do echo "$query"; done)
    " 2>&1 >/dev/null | grep -c 'AST_FUZZER_ORACLE_MISMATCH'
}

# The join returns rows, so a zero below is the oracle skipping the query.
$CLICKHOUSE_CLIENT --query "SELECT count() > 0 FROM oracle_any_join_view"

count_mismatches "" "SELECT count(), min(v) FROM oracle_any_join ANY INNER JOIN oracle_any_join AS a ON w = a.w WHERE v > 10;"
count_mismatches "SET join_default_strictness = 'ANY';" "SELECT count(), min(v) FROM oracle_any_join INNER JOIN oracle_any_join AS a ON w = a.w WHERE v > 10;"
count_mismatches "" "SELECT count(), min(v) FROM oracle_any_join_view WHERE v > 10;"
count_mismatches "" "SELECT count(), min(v) FROM oracle_default_join_view WHERE v > 10;"

# The oracles run their rewrites as internal queries, and only the TLP Aggregate rewrite names a
# state `_s_0`. With `ALL` the join is checked; a view that sets its own thread count is not,
# because the oracles pin a single thread.
count_mismatches "" "SELECT count(), min(v) FROM oracle_any_join ALL INNER JOIN oracle_any_join AS a ON w = a.w WHERE v > 10;" >/dev/null
count_mismatches "" "SELECT count(), min(v) FROM oracle_threads_view WHERE v > 10;" >/dev/null
$CLICKHOUSE_CLIENT --query "
    SYSTEM FLUSH LOGS query_log;
    SELECT countIf(position(query, '_s_0') > 0) > 0, countIf(position(query, '_s_0') > 0 AND position(query, 'oracle_threads_view') > 0)
    FROM system.query_log
    WHERE current_database = currentDatabase() AND is_internal AND type = 'QueryStart';
"

$CLICKHOUSE_CLIENT --query "
    DROP VIEW oracle_any_join_view;
    DROP VIEW oracle_default_join_view;
    DROP VIEW oracle_threads_view;
    DROP TABLE oracle_any_join;
"
