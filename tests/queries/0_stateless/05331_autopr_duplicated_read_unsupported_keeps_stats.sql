-- A duplicated read that cannot be measured must not drop the statistics of the coordinated read.
-- The build side is a compact part read with a `Nested` sub-array added after the insert: the reader
-- fills it from its sibling's offsets, and such a partially read column cannot be sampled. Before the
-- fix it marked the whole execution's statistics as unsupported, nothing was cached, and the next
-- execution never considered parallel replicas.

DROP TABLE IF EXISTS probe_side;
DROP TABLE IF EXISTS build_side;

CREATE TABLE probe_side (id UInt64) ENGINE = MergeTree ORDER BY id;
CREATE TABLE build_side (id UInt64, n Nested(a UInt64)) ENGINE = MergeTree ORDER BY id
SETTINGS min_bytes_for_wide_part = '10G', min_rows_for_wide_part = 1000000000;

INSERT INTO probe_side SELECT number FROM numbers(2000000);
INSERT INTO build_side SELECT number, [number] FROM numbers(2000000);
ALTER TABLE build_side ADD COLUMN `n.b` Array(UInt64);

SET enable_analyzer = 1, enable_parallel_replicas = 1, max_parallel_replicas = 3,
    cluster_for_parallel_replicas = 'test_cluster_one_shard_three_replicas_localhost',
    parallel_replicas_for_non_replicated_merge_tree = 1, parallel_replicas_local_plan = 1,
    automatic_parallel_replicas_mode = 1;
-- Same pins as `05293_autopr_duplicated_read_ratio_gate`: one decision path, a coordinated read split
-- finely enough to win the time comparison, the build side kept on the right and unfiltered, and
-- neither the per-replica floor nor the duplicated-read gate in the way of taking the candidate.
SET serialize_query_plan = 0;
SET merge_tree_min_bytes_per_task_for_remote_reading = 4096;
SET query_plan_join_swap_table = 0, enable_join_runtime_filters = 0,
    query_plan_optimize_join_order_randomize = 0;
SET automatic_parallel_replicas_min_bytes_per_replica = 0;
SET automatic_parallel_replicas_max_duplicated_read_ratio = 1;
SET max_rows_to_read = 0;

SELECT sum(p.id + arraySum(b.`n.b`)) FROM probe_side AS p INNER JOIN build_side AS b ON p.id = b.id
FORMAT Null SETTINGS log_comment = 'unsupported_dup_1_collect';

SELECT sum(p.id + arraySum(b.`n.b`)) FROM probe_side AS p INNER JOIN build_side AS b ON p.id = b.id
FORMAT Null SETTINGS log_comment = 'unsupported_dup_2_decide';

SYSTEM FLUSH LOGS query_log;

SELECT log_comment, ProfileEvents['ParallelReplicasUsedCount'] > 0 AS parallel_replicas_used
FROM system.query_log
WHERE event_date >= yesterday() AND event_time >= now() - toIntervalMinute(15)
  AND current_database = currentDatabase() AND log_comment LIKE 'unsupported_dup_%' AND type = 'QueryFinish'
  AND query_id = initial_query_id
ORDER BY log_comment;

DROP TABLE probe_side;
DROP TABLE build_side;
