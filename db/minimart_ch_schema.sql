-- ============================================================
-- ClickHouse mirror of the minimart Postgres database: the STATIC part
--
-- Idempotent; applied by `scripts/minimart_sync.sh --init` (clickhouse-client
-- --multiquery, stops at the first error) before the generated part.
--
-- Everything lives in its own database, `minimart`, never in `procurement` or
-- `hauling`. The whole database is a rebuildable copy of Postgres:
-- `DROP DATABASE minimart` is the rollback, `--init` followed by `--full`
-- rebuilds it.
--
-- The mirrored tables themselves are NOT in this file: the schema of minimart
-- is not known in advance, so `--init` reads the Postgres catalog through the
-- read-only role minimart_ro (named collection pg_minimart) and GENERATES
-- (scripts/minimart_gen_schema.sh + the templates in db/minimart_sync.sql)
--     minimart.<table>        the copy (MergeTree or ReplacingMergeTree)
--     minimart._src_<table>   an ENGINE = PostgreSQL view of the Postgres table
--                             that names only the mirrored columns (holds no data)
-- and stores what it generated here, in the four tables below, so it can be
-- reviewed (`scripts/minimart_sync.sh --print`) and is never committed.
--
--   _sync_state    one row per table per successful run; the newest synced_through
--                  of a table is its watermark. A failed run writes nothing.
--   _plan_current  which generated plan is live (the newest row)
--   _plan          one row per mirrored table: strategy, reason, key, change
--                  column, DDL, the full / incremental / verify SQL
--   _plan_cols     one row per Postgres column (also the excluded ones, with the
--                  reason): the baseline that schema-drift detection compares to
--
-- For dashboard authors: tables with strategy `snapshot` hold exactly one copy of
-- every row (query them directly). Tables with strategy `incremental_*` are
-- ReplacingMergeTree and may briefly hold a row twice: use FINAL, or aggregate
-- with uniqExact(<key>). `_plan` says which is which:
--     SELECT table_name, strategy FROM minimart._plan
--      WHERE plan_id = (SELECT argMax(plan_id, planned_at) FROM minimart._plan_current)
-- ============================================================

CREATE DATABASE IF NOT EXISTS minimart;

CREATE TABLE IF NOT EXISTS minimart._sync_state
(
    table_name     String,
    run_at         DateTime64(3, 'UTC'),
    synced_through DateTime64(3, 'UTC'),
    mode           LowCardinality(String),
    plan_hash      String
)
ENGINE = MergeTree
ORDER BY (table_name, run_at)
TTL toDateTime(run_at) + INTERVAL 90 DAY;

CREATE TABLE IF NOT EXISTS minimart._plan_current
(
    plan_id    String,
    planned_at DateTime64(3, 'UTC'),
    tables     UInt32
)
ENGINE = MergeTree
ORDER BY planned_at;

CREATE TABLE IF NOT EXISTS minimart._plan
(
    plan_id          String,
    table_name       String,
    strategy         LowCardinality(String),
    reason           String,
    est_rows         Int64,
    pk               Array(String),
    change_col       String,
    mirrored_cols    Array(String),
    excluded_cols    Array(String),
    src_ddl          String,
    dest_ddl         String,
    full_sql         String,
    incr_sql         String,
    verify_sql       String,
    verify_hash_sql  String,
    plan_hash        String
)
ENGINE = MergeTree
ORDER BY (plan_id, table_name);

CREATE TABLE IF NOT EXISTS minimart._plan_cols
(
    plan_id    String,
    table_name String,
    col        String,
    pos        Int32,
    pg_type    String,
    nullable   UInt8,
    readable   UInt8,
    sensitive  UInt8,
    mirrored   UInt8,
    reason     String,
    sig        String
)
ENGINE = MergeTree
ORDER BY (plan_id, table_name, pos);
