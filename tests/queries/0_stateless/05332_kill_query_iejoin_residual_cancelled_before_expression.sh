#!/usr/bin/env bash
# Tags: no-fasttest, no-parallel

# Verify that a `LEFT` `ie_join` cancelled right before its residual `JOIN ON` predicate is evaluated
# does not evaluate the residual and does not emit any rows (neither matched nor unmatched ones).
# The residual is `throwIf` that fails on every candidate pair, so evaluating it after the kill
# reports `FUNCTION_THROW_IF_VALUE_IS_NON_ZERO` instead of `QUERY_WAS_CANCELLED`, and emitting the
# batch or the unmatched rows of the `LEFT` join after the kill would print rows to the client.
# no-parallel: the failpoint is global, an unrelated query could consume it.

CUR_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../shell_config.sh
. "$CUR_DIR"/../shell_config.sh

trap '${CLICKHOUSE_CLIENT} -q "SYSTEM DISABLE FAILPOINT iejoin_residual_before_expression_pause" 2>/dev/null' EXIT

query="
    SELECT l.number, r.number
    FROM numbers(10) AS l
    LEFT JOIN numbers(10) AS r ON l.number < r.number + 1 AND r.number < l.number + 1
        AND throwIf(l.number + r.number >= 0, 'the residual was evaluated after the cancellation') = 0
"

# The residual predicate must be evaluated by `IEJoinTransform`: that is the code path under test.
${CLICKHOUSE_CLIENT} --enable_analyzer=1 --join_algorithm=ie_join -q "EXPLAIN PIPELINE $query" \
    | grep -qF "IEJoinTransform" || { echo "FAIL: no IEJoinTransform in the pipeline"; exit 1; }

query_id="kill_query_iejoin_residual_before_expression_${CLICKHOUSE_DATABASE}_$RANDOM"
output_file="${CLICKHOUSE_TMP}/${query_id}.out"

${CLICKHOUSE_CLIENT} -q "SYSTEM ENABLE FAILPOINT iejoin_residual_before_expression_pause"

timeout 120 ${CLICKHOUSE_CLIENT} --query_id="$query_id" --enable_analyzer=1 --query "
    $query
    FORMAT TSV
    SETTINGS max_threads = 1, join_algorithm = 'ie_join'
" >"$output_file" 2>&1 &
client_pid=$!

if ! timeout 60 ${CLICKHOUSE_CLIENT} -q "SYSTEM WAIT FAILPOINT iejoin_residual_before_expression_pause PAUSE"
then
    echo "FAIL: timed out waiting for iejoin_residual_before_expression_pause"
    ${CLICKHOUSE_CLIENT} -q "SYSTEM DISABLE FAILPOINT iejoin_residual_before_expression_pause"
    ${CLICKHOUSE_CURL} -sS "${CLICKHOUSE_URL}&http_wait_end_of_query=0" -d "KILL QUERY WHERE query_id = '${query_id}' ASYNC" >/dev/null
    exit 1
fi

# The query is deliberately held at the failpoint, so a synchronous `KILL QUERY` would wait for it
# and prevent this test from releasing the failpoint. The stateless-test random settings can enable
# `http_wait_end_of_query`, which makes the HTTP request wait even with `ASYNC`; override it.
${CLICKHOUSE_CURL} -sS "${CLICKHOUSE_URL}&http_wait_end_of_query=0" -d "KILL QUERY WHERE query_id = '${query_id}' ASYNC" >/dev/null

# Do not release the failpoint until the asynchronous kill has reached the query: otherwise the
# residual can be evaluated before the cancellation is set, and the query fails with `throwIf`.
cancelled=0
deadline=$((SECONDS + 60))
while (( SECONDS < deadline ))
do
    cancelled=$(${CLICKHOUSE_CURL} -sS "${CLICKHOUSE_URL}" -d "SELECT count() FROM system.processes WHERE query_id = '${query_id}' AND is_cancelled")
    [[ "$cancelled" -ge 1 ]] && break
    sleep 0.1
done
[[ "$cancelled" -ge 1 ]] || { echo "FAIL: the query was not marked as cancelled in system.processes"; exit 1; }

${CLICKHOUSE_CLIENT} -q "SYSTEM DISABLE FAILPOINT iejoin_residual_before_expression_pause"

wait "$client_pid"

grep -qF "QUERY_WAS_CANCELLED" "$output_file" || { echo "FAIL: the query did not report QUERY_WAS_CANCELLED"; cat "$output_file"; exit 1; }
grep -qF "FUNCTION_THROW_IF_VALUE_IS_NON_ZERO" "$output_file" && { echo "FAIL: the residual was evaluated after the cancellation"; cat "$output_file"; exit 1; }
grep -qE "^[0-9]+	[0-9]+$" "$output_file" && { echo "FAIL: the join emitted rows after the cancellation"; cat "$output_file"; exit 1; }

echo "OK"
