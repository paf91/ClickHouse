-- `WITH TOTALS` of a subquery on the right of `IN` must be ignored when `rewrite_in_to_join`
-- rewrites the `IN` into a correlated `EXISTS`, as it is by the regular `IN` set.

SET enable_analyzer = 1;
SET allow_correlated_subqueries = 1;

SELECT 'rewrite_in_to_join = 0';
SET rewrite_in_to_join = 0;
SELECT number FROM numbers(3) WHERE number IN (SELECT number FROM numbers(10) GROUP BY number WITH TOTALS) ORDER BY number;
SELECT number FROM numbers(10) GROUP BY number WITH TOTALS HAVING number IN (SELECT number FROM numbers(5) GROUP BY number WITH TOTALS) ORDER BY number;
SELECT number FROM numbers(10) GROUP BY number WITH TOTALS HAVING number NOT IN (SELECT number FROM numbers(5) GROUP BY number WITH TOTALS) ORDER BY number;

SELECT 'rewrite_in_to_join = 1';
SET rewrite_in_to_join = 1;
SELECT number FROM numbers(3) WHERE number IN (SELECT number FROM numbers(10) GROUP BY number WITH TOTALS) ORDER BY number;
SELECT number FROM numbers(10) GROUP BY number WITH TOTALS HAVING number IN (SELECT number FROM numbers(5) GROUP BY number WITH TOTALS) ORDER BY number;
SELECT number FROM numbers(10) GROUP BY number WITH TOTALS HAVING number NOT IN (SELECT number FROM numbers(5) GROUP BY number WITH TOTALS) ORDER BY number;
SELECT DISTINCT number IN (SELECT number FROM numbers(100) WHERE -2147483649 GROUP BY ALL WITH TOTALS QUALIFY number IN (SELECT number FROM numbers(1025, 10) WHERE -2147483649 GROUP BY ALL WITH TOTALS)) FROM numbers(3);
