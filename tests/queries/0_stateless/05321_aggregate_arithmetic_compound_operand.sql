-- The operation with a constant is moved out of the aggregate only for an operand type where that keeps the result.
-- `min` and `max` compare an `Array` or a `Tuple` lexicographically, which an element-wise operation does not preserve.

SET optimize_arithmetic_operations_in_aggregate_functions = 1;

DROP TABLE IF EXISTS t_aggregate_arithmetic_array;
CREATE TABLE t_aggregate_arithmetic_array (arr Array(Int64)) ENGINE = MergeTree ORDER BY tuple();
INSERT INTO t_aggregate_arithmetic_array VALUES ([]), ([1]), ([1, 2]);

-- Negation keeps the empty array the least, and a prefix less than its extension.
SELECT min(arr * -1), max(arr * -1) FROM t_aggregate_arithmetic_array;
SELECT min(arr * -1), max(arr * -1) FROM t_aggregate_arithmetic_array SETTINGS optimize_arithmetic_operations_in_aggregate_functions = 0;

-- Over no rows the aggregate of the operation is the default value, not the operation applied to it.
SELECT min(arr + [1]), min(tuple(arr[1]) + tuple(1)) FROM t_aggregate_arithmetic_array WHERE 0;
SELECT min(arr + [1]), min(tuple(arr[1]) + tuple(1)) FROM t_aggregate_arithmetic_array WHERE 0 SETTINGS optimize_arithmetic_operations_in_aggregate_functions = 0;

DROP TABLE IF EXISTS t_aggregate_arithmetic_decimal_array;
CREATE TABLE t_aggregate_arithmetic_decimal_array (arr Array(Decimal(9, 0))) ENGINE = MergeTree ORDER BY tuple();
INSERT INTO t_aggregate_arithmetic_decimal_array VALUES ([1, 5]), ([0, 9]);

-- `Decimal` elements: division truncates each element, and the constant is cast into the native width of the element.
SELECT min(arr / 2), max(arr / 2), min((arr[1], arr[2]) / 2), max((arr[1], arr[2]) / 2) FROM t_aggregate_arithmetic_decimal_array;
SELECT min(arr / 2), max(arr / 2), min((arr[1], arr[2]) / 2), max((arr[1], arr[2]) / 2) FROM t_aggregate_arithmetic_decimal_array SETTINGS optimize_arithmetic_operations_in_aggregate_functions = 0;
SELECT min(arr * 9223372036854775807), max(arr * 9223372036854775807), min(tuple(arr[1]) * 9223372036854775807) FROM t_aggregate_arithmetic_decimal_array;
SELECT min(arr * 9223372036854775807), max(arr * 9223372036854775807), min(tuple(arr[1]) * 9223372036854775807) FROM t_aggregate_arithmetic_decimal_array SETTINGS optimize_arithmetic_operations_in_aggregate_functions = 0;

-- A `Variant` operand: `min` and `max` accept the result of the operation, not the `Variant` itself.
SELECT min(v * -1), max(v * -1) FROM (SELECT CAST(toInt64(number + 1), 'Variant(Int64, String)') AS v FROM numbers(2));

-- A compound constant makes the result compound too.
SELECT min(number * (2, 3)), min(number * tuple()) FROM numbers(3);

-- An IP address: `sum` and `avg` accept the result of the operation, not the address itself.
SELECT sum(ip * 1), avg(ip + 1) FROM (SELECT toIPv4(number + 1) AS ip FROM numbers(2));
SELECT sum(ip * 1), avg(ip + 1) FROM (SELECT toIPv6(concat('::', toString(number + 1))) AS ip FROM numbers(2));

-- `avg` of a date or a time is rounded to its resolution before the constant is added.
SELECT avg(t + INTERVAL 500 MILLISECOND), avg(d + 1) FROM (SELECT toDateTime(number, 'UTC') AS t, toDate('2019-11-22') + number AS d FROM numbers(2));
SELECT avg(t + INTERVAL 500 MILLISECOND), avg(d + 1) FROM (SELECT toDateTime(number, 'UTC') AS t, toDate('2019-11-22') + number AS d FROM numbers(2))
SETTINGS optimize_arithmetic_operations_in_aggregate_functions = 0;

-- A day is subtracted in the time zone: the first 02:30 on the day DST ends is earlier than the second 02:15, but not a day before.
SELECT min(t - INTERVAL 1 DAY), max(t - INTERVAL 1 DAY)
FROM (SELECT toTimeZone(toDateTime('2020-10-25 00:30:00', 'UTC') + number * 2700, 'Europe/Amsterdam') AS t FROM numbers(2));
SELECT min(t - INTERVAL 1 DAY), max(t - INTERVAL 1 DAY)
FROM (SELECT toTimeZone(toDateTime('2020-10-25 00:30:00', 'UTC') + number * 2700, 'Europe/Amsterdam') AS t FROM numbers(2))
SETTINGS optimize_arithmetic_operations_in_aggregate_functions = 0;

-- Still moved out: a scalar operand, and an hour added to a time. Not moved out: a compound operand, and a day added to a time.
SELECT extract(arrayStringConcat(groupArray(explain), ' '), 'function_name: (multiply|plus|min)')
FROM (EXPLAIN QUERY TREE SELECT min(arr[1] * -1) FROM t_aggregate_arithmetic_array);
SELECT extract(arrayStringConcat(groupArray(explain), ' '), 'function_name: (multiply|min)')
FROM (EXPLAIN QUERY TREE SELECT min(arr * -1) FROM t_aggregate_arithmetic_array);
SELECT extract(arrayStringConcat(groupArray(explain), ' '), 'function_name: (plus|min)')
FROM (EXPLAIN QUERY TREE SELECT min(toDateTime(number, 'UTC') + INTERVAL 1 HOUR) FROM numbers(2));
SELECT extract(arrayStringConcat(groupArray(explain), ' '), 'function_name: (plus|min)')
FROM (EXPLAIN QUERY TREE SELECT min(toDateTime(number, 'UTC') + INTERVAL 1 DAY) FROM numbers(2));

DROP TABLE t_aggregate_arithmetic_array;
DROP TABLE t_aggregate_arithmetic_decimal_array;
