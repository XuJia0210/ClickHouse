#!/usr/bin/env bash

CUR_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../shell_config.sh
. "$CUR_DIR"/../shell_config.sh

function involved_parallel_replicas () {
    # Not using current_database = '$CLICKHOUSE_DATABASE' as nested parallel queries aren't run with it
    $CLICKHOUSE_CLIENT --query "
        SELECT
            initial_query_id,
            (count() - 2) / 2 as number_of_parallel_replicas
        FROM system.query_log
    WHERE event_date >= yesterday()
      AND initial_query_id LIKE '$1%'
    GROUP BY initial_query_id
    ORDER BY min(event_time_microseconds) ASC
    FORMAT TSV"
}

$CLICKHOUSE_CLIENT --query "
    CREATE TABLE test_parallel_replicas_automatic_count
    (
        number Int64,
        p Int64
    )
    ENGINE=MergeTree()
      ORDER BY number
      PARTITION BY p
      SETTINGS index_granularity = 8192  -- Don't randomize it to avoid flakiness
    AS
      SELECT number, number % 2 AS p FROM numbers(2_000_000)
      UNION ALL
      SELECT number, 3 AS p FROM numbers(10_000_000, 8_000_000)
"

$CLICKHOUSE_CLIENT --query "
    CREATE TABLE test_parallel_replicas_automatic_count_right_side
    (
        number Int64,
        value Int64
    )
    ENGINE=MergeTree()
      ORDER BY number
      SETTINGS index_granularity = 8192  -- Don't randomize it to avoid flakiness
    AS
      SELECT number, number % 2 AS v FROM numbers(1_000_000)
"


function run_query_with_pure_parallel_replicas () {
    # $1 -> query_id
    # $2 -> min rows per replica
    # $3 -> query
    $CLICKHOUSE_CLIENT \
        --query "$3" \
        --query_id "${1}_pure" \
        --max_parallel_replicas 3 \
        --prefer_localhost_replica 1 \
        --use_hedged_requests 0 \
        --cluster_for_parallel_replicas 'parallel_replicas' \
        --allow_experimental_parallel_reading_from_replicas 1 \
        --parallel_replicas_for_non_replicated_merge_tree 1 \
        --parallel_replicas_min_number_of_rows_per_replica "$2" \
        --allow_experimental_analyzer 1
}

query_id_base="02784_automatic_parallel_replicas-$CLICKHOUSE_DATABASE"

#### Reading 10M rows without filters
whole_table_query="SELECT sum(number) FROM test_parallel_replicas_automatic_count format Null"
run_query_with_pure_parallel_replicas "${query_id_base}_whole_table_0" 0 "$whole_table_query"
run_query_with_pure_parallel_replicas "${query_id_base}_whole_table_10M" 10000000 "$whole_table_query"
run_query_with_pure_parallel_replicas "${query_id_base}_whole_table_6M" 6000000 "$whole_table_query" # 1.6 replicas -> 1 replica -> No parallel replicas
run_query_with_pure_parallel_replicas "${query_id_base}_whole_table_5M" 5000000 "$whole_table_query"
run_query_with_pure_parallel_replicas "${query_id_base}_whole_table_1M" 1000000 "$whole_table_query"

##### Reading 2M rows without filters as partition (p=3) is pruned completely
query_with_partition_pruning="SELECT sum(number) FROM test_parallel_replicas_automatic_count WHERE p != 3 format Null"
run_query_with_pure_parallel_replicas "${query_id_base}_pruning_0" 0 "$query_with_partition_pruning"
run_query_with_pure_parallel_replicas "${query_id_base}_pruning_10M" 10000000 "$query_with_partition_pruning"
run_query_with_pure_parallel_replicas "${query_id_base}_pruning_1M" 1000000 "$query_with_partition_pruning"
run_query_with_pure_parallel_replicas "${query_id_base}_pruning_500k" 500000 "$query_with_partition_pruning"

#### Reading ~500k rows as index filter should prune granules from partition=1 and partition=2, and drop p3 completely
query_with_index="SELECT sum(number) FROM test_parallel_replicas_automatic_count WHERE number < 500_000 format Null"
run_query_with_pure_parallel_replicas "${query_id_base}_index_0" 0 "$query_with_index"
run_query_with_pure_parallel_replicas "${query_id_base}_index_1M" 1000000 "$query_with_index"
run_query_with_pure_parallel_replicas "${query_id_base}_index_300k" 300000 "$query_with_index"
run_query_with_pure_parallel_replicas "${query_id_base}_index_200k" 200000 "$query_with_index"
run_query_with_pure_parallel_replicas "${query_id_base}_index_100k" 100000 "$query_with_index"

#### Reading 1M (because of LIMIT)
limit_table_query="SELECT sum(number) FROM (SELECT number FROM test_parallel_replicas_automatic_count LIMIT 1_000_000) format Null"
run_query_with_pure_parallel_replicas "${query_id_base}_limit_0" 0 "$limit_table_query"
run_query_with_pure_parallel_replicas "${query_id_base}_limit_10M" 10000000 "$limit_table_query"
run_query_with_pure_parallel_replicas "${query_id_base}_limit_1M" 1000000 "$limit_table_query"
run_query_with_pure_parallel_replicas "${query_id_base}_limit_500k" 500000 "$limit_table_query"

#### Reading 10M (because of LIMIT is applied after aggregations)
limit_agg_table_query="SELECT sum(number) FROM test_parallel_replicas_automatic_count LIMIT 1_000_000 format Null"
run_query_with_pure_parallel_replicas "${query_id_base}_useless_limit_0" 0 "$limit_agg_table_query"
run_query_with_pure_parallel_replicas "${query_id_base}_useless_limit_10M" 10000000 "$limit_agg_table_query"
run_query_with_pure_parallel_replicas "${query_id_base}_useless_limit_1M" 1000000 "$limit_agg_table_query"
run_query_with_pure_parallel_replicas "${query_id_base}_useless_limit_500k" 500000 "$limit_agg_table_query"

#### JOIN (left side 10M, right side 1M)
#### As the right side of the JOIN is a table, ideally it shouldn't be executed with parallel replicas and instead passed as is to the replicas
#### so each of them executes the join with the assigned granules of the left table, but that's not implemented yet
#### https://github.com/ClickHouse/ClickHouse/issues/49301#issuecomment-1619897920
#### Note that this currently fails with the analyzer since it doesn't support JOIN with parallel replicas
simple_join_query="SELECT sum(value) FROM test_parallel_replicas_automatic_count INNER JOIN test_parallel_replicas_automatic_count_right_side USING number format Null"
run_query_with_pure_parallel_replicas "${query_id_base}_simple_join_0" 0 "$simple_join_query" # 3 replicas for the right side first, 3 replicas for the left
run_query_with_pure_parallel_replicas "${query_id_base}_simple_join_10M" 10000000 "$simple_join_query" # Right: 0. Left: 0
run_query_with_pure_parallel_replicas "${query_id_base}_simple_join_5M" 5000000 "$simple_join_query" # Right: 0. Left: 2
run_query_with_pure_parallel_replicas "${query_id_base}_simple_join_1M" 1000000 "$simple_join_query" # Right: 1->0. Left: 10->3
run_query_with_pure_parallel_replicas "${query_id_base}_simple_join_300k" 400000 "$simple_join_query" # Right: 2. Left: 3

#### If the filter does not help, it shouldn't disable parallel replicas. Table has 1M rows, filter removes all rows
helpless_filter_query="SELECT sum(number) FROM test_parallel_replicas_automatic_count_right_side WHERE value = 42 format Null"
run_query_with_pure_parallel_replicas "${query_id_base}_helpless_filter_0" 0 "$helpless_filter_query"
run_query_with_pure_parallel_replicas "${query_id_base}_helpless_filter_2M" 2000000 "$helpless_filter_query"
run_query_with_pure_parallel_replicas "${query_id_base}_helpless_filter_500000" 500000 "$helpless_filter_query"
run_query_with_pure_parallel_replicas "${query_id_base}_helpless_filter_100000" 100000 "$helpless_filter_query"

$CLICKHOUSE_CLIENT --query "SYSTEM FLUSH LOGS"
involved_parallel_replicas "${query_id_base}"
