-- A `hasAllTokens` that cannot match in the part must stay false in lazy apply mode
-- when another search in the same query uses one of its tokens.

DROP TABLE IF EXISTS tab_failed_search;
SET enable_full_text_index = 1;
SET use_skip_indexes = 1;
SET use_skip_indexes_on_data_read = 1;
SET use_skip_indexes_for_disjunctions = 1;
SET query_plan_direct_read_from_text_index = 1;
SET query_plan_optimize_count_from_text_index = 0;
SET use_query_condition_cache = 0;
SET text_index_posting_list_apply_mode = 'lazy';

DROP TABLE IF EXISTS tab_failed_search;

CREATE TABLE tab_failed_search
(
    k UInt64,
    s String,
    INDEX idx s TYPE text(tokenizer = splitByNonAlpha, posting_list_codec = 'bitpacking', posting_list_block_size = 128)
)
ENGINE = MergeTree ORDER BY k
SETTINGS index_granularity = 128, index_granularity_bytes = '10Mi';

-- 'alpha' is in rows [0, 500) and 'beta' in rows [900, 1000), so `hasAllTokens(s, ['alpha', 'beta'])` can never match.
INSERT INTO tab_failed_search
SELECT number, concat('w', if(number < 500, ' alpha', ''), if(number >= 900, ' beta', ''), if(number % 10 = 0, ' gamma', ''))
FROM numbers(1000)
SETTINGS max_insert_threads = 1, max_insert_block_size = 1000000, min_insert_block_size_rows = 1000000, min_insert_block_size_bytes = 0;

-- 'alpha' must span several compressed posting blocks, so that it is left to the lazy cursors.
SELECT token, num_posting_blocks > 1, has_compressed_postings FROM mergeTreeTextIndex(currentDatabase(), tab_failed_search, idx) WHERE token = 'alpha';

SELECT 'or, no index', count(), sum(k) FROM tab_failed_search WHERE hasAllTokens(s, ['alpha', 'beta']) OR hasAllTokens(s, ['alpha', 'gamma'])
SETTINGS use_skip_indexes = 0, query_plan_direct_read_from_text_index = 0;
SELECT 'or, lazy', count(), sum(k) FROM tab_failed_search WHERE hasAllTokens(s, ['alpha', 'beta']) OR hasAllTokens(s, ['alpha', 'gamma']);

SELECT 'not, no index', count(), sum(k) FROM tab_failed_search WHERE hasToken(s, 'alpha') AND NOT hasAllTokens(s, ['alpha', 'beta'])
SETTINGS use_skip_indexes = 0, query_plan_direct_read_from_text_index = 0;
SELECT 'not, lazy', count(), sum(k) FROM tab_failed_search WHERE hasToken(s, 'alpha') AND NOT hasAllTokens(s, ['alpha', 'beta']);

DROP TABLE tab_failed_search;
