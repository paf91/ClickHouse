-- Tags: distributed

-- With a `Distributed` table among them, the tables of `merge` aggregate on their own and their partial states are
-- merged above. A table that lacks a grouping column, or has it under another type than the common one, aggregates by
-- other keys, so a group must still be returned once.

SET group_by_two_level_threshold = 1, group_by_two_level_threshold_bytes = 1;

CREATE TABLE t_a (id UInt64, a UInt8, s String) ENGINE = MergeTree ORDER BY id;
CREATE TABLE t_b (id UInt64) ENGINE = MergeTree ORDER BY id;
INSERT INTO t_a VALUES (1, 5, 'x'), (10, 0, '');
INSERT INTO t_b VALUES (10), (11);
CREATE TABLE t_dist_a AS t_a ENGINE = Distributed(test_shard_localhost, currentDatabase(), t_a);
CREATE TABLE t_dist_b AS t_b ENGINE = Distributed(test_shard_localhost, currentDatabase(), t_b);
CREATE TABLE t_dist2_b AS t_b ENGINE = Distributed(test_cluster_two_shards_localhost, currentDatabase(), t_b);

SELECT 'missing', id, a, count() FROM merge(currentDatabase(), '^t_(a|dist_b)$') GROUP BY id, a ORDER BY ALL;
SELECT 'missing two', id, a, s, count() FROM merge(currentDatabase(), '^t_(a|dist_b)$') GROUP BY id, a, s ORDER BY ALL;
SELECT 'missing local', id, s, count() FROM merge(currentDatabase(), '^t_(dist_a|b)$') GROUP BY id, s ORDER BY ALL;
SELECT 'missing two shards', id, a, count() FROM merge(currentDatabase(), '^t_(a|dist2_b)$') GROUP BY id, a ORDER BY ALL;
SELECT 'grouping sets', id, a, count() FROM merge(currentDatabase(), '^t_(a|dist_b)$') GROUP BY GROUPING SETS ((id, a), (id)) ORDER BY ALL;
SELECT 'totals', id, a, count() FROM merge(currentDatabase(), '^t_(a|dist_b)$') GROUP BY id, a WITH TOTALS ORDER BY ALL;
SELECT 'rollup', id, a, count() FROM merge(currentDatabase(), '^t_(a|dist_b)$') GROUP BY ROLLUP(id, a) ORDER BY ALL;
SELECT 'not memory efficient', id, a, count() FROM merge(currentDatabase(), '^t_(a|dist_b)$') GROUP BY id, a ORDER BY ALL
SETTINGS distributed_aggregation_memory_efficient = 0;

CREATE TABLE u_a (id UInt32, s String) ENGINE = MergeTree ORDER BY id;
CREATE TABLE u_b (id UInt64, s String) ENGINE = MergeTree ORDER BY id;
CREATE TABLE u_c (id UInt64, s LowCardinality(String)) ENGINE = MergeTree ORDER BY id;
INSERT INTO u_a VALUES (10, 'x'), (1, 'y');
INSERT INTO u_b VALUES (10, 'x'), (11, 'z');
INSERT INTO u_c VALUES (10, 'x'), (1, 'y');
CREATE TABLE u_dist_b AS u_b ENGINE = Distributed(test_shard_localhost, currentDatabase(), u_b);

SELECT 'common type', id, s, count() FROM merge(currentDatabase(), '^u_(a|dist_b)$') GROUP BY id, s ORDER BY ALL;
SELECT 'common type LowCardinality', s, count() FROM merge(currentDatabase(), '^u_(c|dist_b)$') GROUP BY s ORDER BY ALL;
