create table t1 (a Int)
    engine=ReplicatedMergeTree('/clickhouse/tables/default/test', 'r1')
    order by tuple() SETTINGS index_granularity = 8192;
attach table t2 UUID '6c32d92e-bebf-4730-ae73-c43e5748f829'
       (a Int) engine=ReplicatedMergeTree('/clickhouse/tables/default/test', 'r1')
       order by tuple() SETTINGS index_granularity = 8192; -- { serverError REPLICA_ALREADY_EXISTS };
