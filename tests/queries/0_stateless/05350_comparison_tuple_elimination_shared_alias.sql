-- A nested single-element tuple comparison inside an alias shared by GROUP BY and ORDER BY / HAVING / WHERE
-- (identifier resolve cache) must be rewritten the same way as the projection copy.

DROP TABLE IF EXISTS t_tuple_elim;
DROP TABLE IF EXISTS t_tuple_elim_lc;
CREATE TABLE t_tuple_elim (s Nullable(String), n UInt64) ENGINE = MergeTree ORDER BY n;
INSERT INTO t_tuple_elim SELECT if(number = 5, NULL, toString(number % 3)), number FROM numbers(12);
CREATE TABLE t_tuple_elim_lc (s LowCardinality(String), n UInt64) ENGINE = MergeTree ORDER BY n;
INSERT INTO t_tuple_elim_lc SELECT toString(number % 3), number FROM numbers(12);

SET enable_identifier_resolve_cache = 1;

SELECT NOT (tuple(tuple(n, 1)) = tuple(tuple(n, 2))) AS r FROM t_tuple_elim GROUP BY r ORDER BY r;
SELECT NOT (tuple(tuple(n % 2, 1)) != tuple(tuple(1, 1))) AS r, count() FROM t_tuple_elim GROUP BY r ORDER BY r;
SELECT NOT (tuple(tuple(n % 2, 1)) = tuple((1, 1))) AS r, count() FROM t_tuple_elim GROUP BY r ORDER BY r;
SELECT NOT (tuple((1, 1)) = tuple(tuple(n % 2, 1))) AS r, count() FROM t_tuple_elim GROUP BY r HAVING r ORDER BY r;
SELECT NOT (tuple(tuple(tuple(n % 2, 1))) = tuple(tuple(tuple(1, 1)))) AS r, count() FROM t_tuple_elim WHERE NOT r GROUP BY r ORDER BY r;
SELECT NOT ((n % 2, tuple(tuple(n % 3, 1))) = (1, tuple(tuple(1, 1)))) AS r, count() FROM t_tuple_elim GROUP BY r ORDER BY r;
SELECT NOT (tuple(tuple(s, 1)) = tuple(tuple('1', 1))) AS r, count() FROM t_tuple_elim GROUP BY r ORDER BY r;
SELECT NOT (tuple(tuple(s, 1)) = tuple(tuple('1', 1))) AS r, count() FROM t_tuple_elim_lc GROUP BY r ORDER BY r;
SELECT NOT (tuple(tuple(n % 2, 1)) = tuple(tuple(1, 1))) AS r, count() FROM t_tuple_elim GROUP BY r WITH ROLLUP ORDER BY r, count();

-- The nested comparison is eliminated completely in one visit.
SELECT count() FROM (EXPLAIN QUERY TREE SELECT tuple(tuple(n, 1)) = tuple(tuple(n, 2)) FROM t_tuple_elim) WHERE explain ILIKE '%function_name: tuple%';

DROP TABLE t_tuple_elim;
DROP TABLE t_tuple_elim_lc;
