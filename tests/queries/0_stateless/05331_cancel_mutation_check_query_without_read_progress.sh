#!/usr/bin/env bash
# A mutation's check of whether a part is affected (`isStorageTouchedByMutations`) runs a `count()` query whose
# `IN (subquery)` set is built by that query's own pipeline. Cancellation used to be checked only when a source read
# data, so a subquery that keeps working on data it has already read (here, a cross join) could not be stopped by
# `KILL MUTATION`, `DETACH` or shutdown until the whole set was built.

CUR_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../shell_config.sh
. "$CUR_DIR"/../shell_config.sh

$CLICKHOUSE_CLIENT -q "DROP TABLE IF EXISTS t_cancel_check_query"

# Three partitions give three part tasks of one mutation, which share one set: one builds it, the others wait for it.
$CLICKHOUSE_CLIENT -q "
    CREATE TABLE t_cancel_check_query (id UInt64, p UInt64) ENGINE = MergeTree PARTITION BY p ORDER BY id
    SETTINGS number_of_free_entries_in_pool_to_execute_mutation = 0;
    INSERT INTO t_cancel_check_query VALUES (0, 0), (1, 1), (2, 2);"

# `ignore` keeps the set out of key and PREWHERE analysis, so the check query's own pipeline builds it.
# The cross join emits all of its output after its two sources have finished reading, and `sleep(1)` per output block
# makes that take minutes.
$CLICKHOUSE_CLIENT -q "
    ALTER TABLE t_cancel_check_query DELETE WHERE ignore(id IN (
        SELECT a.number + b.number + sleep(1) FROM numbers(2000) AS a, numbers(5000) AS b
    )) SETTINGS mutations_sync = 0"

# Wait until the mutation has been running for a couple of seconds, i.e. it is inside the check query and not merely
# queued. Fail hard on timeout, or `KILL MUTATION` below would cancel a queued mutation and the test would be vacuous.
i=0
while [ "$($CLICKHOUSE_CLIENT -q "SELECT count() FROM system.merges WHERE database = currentDatabase() AND table = 't_cancel_check_query' AND is_mutation AND elapsed > 2")" -lt 1 ]; do
    sleep 0.3
    i=$((i + 1))
    if [ "$i" -gt 200 ]; then
        echo "Mutation did not start in time" >&2
        exit 1
    fi
done

$CLICKHOUSE_CLIENT -q "KILL MUTATION WHERE database = currentDatabase() AND table = 't_cancel_check_query' FORMAT Null"

# The background mutation must disappear quickly. Without cancellation its merge-list entries stay until the whole
# set has been built (minutes).
i=0
while [ "$($CLICKHOUSE_CLIENT -q "SELECT count() FROM system.merges WHERE database = currentDatabase() AND table = 't_cancel_check_query'")" -ne 0 ]; do
    sleep 0.3
    i=$((i + 1))
    if [ "$i" -gt 100 ]; then
        break
    fi
done

$CLICKHOUSE_CLIENT -q "SELECT count() FROM system.merges WHERE database = currentDatabase() AND table = 't_cancel_check_query'"
$CLICKHOUSE_CLIENT -q "SELECT count() FROM t_cancel_check_query"
$CLICKHOUSE_CLIENT -q "DROP TABLE t_cancel_check_query"
