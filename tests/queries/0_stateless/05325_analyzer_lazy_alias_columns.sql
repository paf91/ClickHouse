-- The analyzer resolves the expression of an ALIAS column only when the column is used.
-- Check the cases when ALIAS columns reference each other, subcolumns and matchers.

SET enable_analyzer = 1;

DROP TABLE IF EXISTS t_lazy_alias;

CREATE TABLE t_lazy_alias
(
    id UInt64,
    m Map(String, UInt64),
    tup Tuple(a UInt64, b String),
    n Nested(x UInt64, y String),
    -- References an ALIAS column declared after it.
    a1 UInt64 ALIAS a2 + 1,
    a2 UInt64 ALIAS id * 10,
    -- References an ALIAS column declared before it.
    a3 String ALIAS toString(a1) || '-' || tup.b,
    -- The declared type differs from the type of the expression.
    a4 Int32 ALIAS m['k'],
    a5 UInt64 ALIAS tup.a + a4,
    metric_x UInt64 ALIAS m['x'],
    metric_y UInt64 ALIAS m['y'],
    other_z UInt64 ALIAS m['z']
)
ENGINE = MergeTree ORDER BY id;

INSERT INTO t_lazy_alias (id, m, tup, n.x, n.y) VALUES (1, {'k': 5, 'x': 7}, (100, 'b1'), [1, 2], ['p', 'q']), (2, {'y': 3}, (200, 'b2'), [3], ['r']);

SELECT a1 FROM t_lazy_alias ORDER BY id;
SELECT a3 FROM t_lazy_alias ORDER BY id;
SELECT a1, a2, a3 FROM t_lazy_alias ORDER BY id;
SELECT a4, toTypeName(a4), a5 FROM t_lazy_alias ORDER BY id;
SELECT t.a1, t_lazy_alias.a2 FROM t_lazy_alias AS t ORDER BY id;

-- An alias in the query with the same name as a column used in an ALIAS expression.
SELECT id + 1000 AS id, a2 FROM t_lazy_alias ORDER BY a2;

SELECT arraySum([COLUMNS('metric_.*') APPLY sum]) FROM t_lazy_alias SETTINGS asterisk_include_alias_columns = 1;
SELECT COLUMNS('metric_.*') FROM t_lazy_alias ORDER BY id;
SELECT * FROM t_lazy_alias ORDER BY id FORMAT Vertical SETTINGS asterisk_include_alias_columns = 1;

SELECT n.x, a1 FROM t_lazy_alias ARRAY JOIN n ORDER BY id, n.x;
SELECT sum(a5) FROM t_lazy_alias WHERE a1 > 15;
SELECT a2 FROM t_lazy_alias PREWHERE a1 = 21;

DROP TABLE t_lazy_alias;

-- ALIAS columns added by ALTER, the query uses a part of them.
DROP TABLE IF EXISTS t_many_aliases;
CREATE TABLE t_many_aliases (id UInt64, m Map(String, UInt64)) ENGINE = MergeTree ORDER BY id;
ALTER TABLE t_many_aliases ADD COLUMN c0 UInt64 ALIAS m['k0'];
ALTER TABLE t_many_aliases ADD COLUMN c1 UInt64 ALIAS m['k1'];
ALTER TABLE t_many_aliases ADD COLUMN c2 UInt64 ALIAS c1 + m['k2'];
INSERT INTO t_many_aliases VALUES (1, {'k1': 1, 'k2': 2});
SELECT c2, c0 FROM t_many_aliases;
DROP TABLE t_many_aliases;
