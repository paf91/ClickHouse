-- A part with a pending `DROP COLUMN` / `RENAME COLUMN` mutation is read from the parent part instead of
-- its projection part only when the mutation touches a column the projection holds or the query reads.
-- A pending drop or rename of an unrelated column keeps the projection usable.

DROP TABLE IF EXISTS t_proj_unrelated;
CREATE TABLE t_proj_unrelated (id UInt64, x UInt64, y UInt64, z UInt64, PROJECTION p (SELECT id, x ORDER BY x))
ENGINE = MergeTree ORDER BY id
SETTINGS min_bytes_for_wide_part = 0, index_granularity = 128;
INSERT INTO t_proj_unrelated SELECT number, number % 100, number, number FROM numbers(100000);

SYSTEM STOP MERGES t_proj_unrelated;
ALTER TABLE t_proj_unrelated DROP COLUMN y SETTINGS alter_sync = 0;
ALTER TABLE t_proj_unrelated RENAME COLUMN z TO w SETTINGS alter_sync = 0;

SELECT count() FROM t_proj_unrelated WHERE x = 5 SETTINGS force_optimize_projection = 1;
SELECT count() FROM t_proj_unrelated WHERE x = 5 SETTINGS optimize_use_projections = 0;

-- A pending rename of a column the projection holds makes the part read from the parent part.
ALTER TABLE t_proj_unrelated RENAME COLUMN x TO x2 SETTINGS alter_sync = 0;
SELECT count() FROM t_proj_unrelated WHERE x2 = 5 SETTINGS force_optimize_projection = 1; -- { serverError PROJECTION_NOT_USED }
SELECT count() FROM t_proj_unrelated WHERE x2 = 5;

DROP TABLE t_proj_unrelated;
