-- ============================================================
-- ClickHouse mirror of the hauling_tracker Postgres database (phase 1)
--
-- Idempotent: safe to apply any number of times. Applied by
--   scripts/hauling_sync.sh --init
-- (clickhouse-client --multiquery, stops at the first error).
--
-- Everything lives in its own database, `hauling`, never in `procurement`.
-- The whole database is a rebuildable copy of Postgres: `DROP DATABASE hauling`
-- is the rollback, `--init` followed by `--full` rebuilds it.
--
-- Column names are identical to Postgres. Type mapping (see
-- HAULING_MIRROR_CONTRACT.md and the conversions in db/hauling_sync.sql):
--   uuid -> UUID                 date -> Date
--   timestamptz -> DateTime64(3,'UTC')   (millisecond precision: the
--       microsecond part is truncated; the instant itself is exact)
--   enum -> LowCardinality(String)   text -> String   integer -> Int32
--   bigint -> Int64              boolean -> Bool
--   numeric (no precision) -> Float64
--   jsonb -> String (the raw jsonb text, e.g. {"a": 1}; use JSONExtract* on it)
--   NULLable in Postgres -> Nullable(...) here.
--
-- FOR DASHBOARD AUTHORS
--   trips, barge_loadings, scale_readings_pending are replaced wholesale on
--   every sync (snapshot swap), so they always hold exactly one copy of each
--   row: query them directly, no FINAL.
--   error_log and station_heartbeat are ReplacingMergeTree and are appended
--   incrementally with an overlap window, so a row may briefly exist twice
--   until a background merge collapses it. Always query them with FINAL
--   (SELECT ... FROM hauling.error_log FINAL), or aggregate with
--   uniqExact(error_id) / uniqExact(id), or argMax(col, received_at) per id.
--   count() without FINAL can over-count.
--
-- Adding a table later = one CREATE TABLE here + one block in
-- db/hauling_sync.sql + one `GRANT SELECT` in db/hauling_ro_setup.sql + one
-- entry in scripts/hauling_sync.sh (TABLES and verify_sql).
-- ============================================================

CREATE DATABASE IF NOT EXISTS hauling;

-- ── trips: snapshot swap every run (rows are edited as a trip moves through
--    its checkpoints and can be deleted; Postgres has no updated_at) ─────────
CREATE TABLE IF NOT EXISTS hauling.trips
(
    trip_id           UUID,
    date              Date,
    status            LowCardinality(String),
    no_tiket          Int32,
    no_lambung        String,
    jetty_destination LowCardinality(String),
    coal_quality      LowCardinality(String),
    cuaca_mmi         String,
    tare_site_kg      Int32,
    cp1_timestamp     Nullable(DateTime64(3, 'UTC')),
    gross_site_kg     Nullable(Int32),
    netto_site_kg     Nullable(Int32),
    cp2_timestamp     Nullable(DateTime64(3, 'UTC')),
    gross_jetty_kg    Nullable(Int32),
    netto_jetty_kg    Nullable(Int32),
    compare_gross_kg  Nullable(Int32),
    deviasi_kg        Nullable(Int32),
    cp3_timestamp     Nullable(DateTime64(3, 'UTC')),
    adjustment_kg     Int32,
    is_locked         Nullable(Bool),
    session_id        Nullable(UUID),
    tare_jetty_kg     Nullable(Int32),
    stockpile_code    String,
    tare_source       String,
    gross_source      String,
    cp1_event_id      Nullable(String),
    cp2_event_id      Nullable(String)
)
ENGINE = MergeTree
ORDER BY (date, trip_id);

-- ── barge_loadings: tiny, may be edited -> snapshot swap every run ───────────
CREATE TABLE IF NOT EXISTS hauling.barge_loadings
(
    loading_id     UUID,
    jetty          LowCardinality(String),
    barge_name     String,
    tug_boat_name  String,
    loading_date   Date,
    loading_qty_kg Int64,
    created_at     DateTime64(3, 'UTC'),
    stockpile_code String
)
ENGINE = MergeTree
ORDER BY (loading_date, loading_id);

-- ── scale_readings_pending: a transient queue (rows come and go) -> snapshot
--    swap every run. Its content is "what was in the queue at sync time". ─────
CREATE TABLE IF NOT EXISTS hauling.scale_readings_pending
(
    no_lambung   String,
    reading_type String,
    weight_kg    Float64,
    measured_at  DateTime64(3, 'UTC'),
    created_at   DateTime64(3, 'UTC')
)
ENGINE = MergeTree
ORDER BY (no_lambung, reading_type);

-- ── error_log: append-only -> incremental by created_at (1 h overlap).
--    ReplacingMergeTree ORDER BY error_id collapses re-sent rows: use FINAL. ──
CREATE TABLE IF NOT EXISTS hauling.error_log
(
    error_id   UUID,
    source     String,
    level      String,
    message    String,
    context    Nullable(String),
    created_at DateTime64(3, 'UTC')
)
ENGINE = ReplacingMergeTree
ORDER BY error_id;

-- ── station_heartbeat: append-only bigserial id, may grow large -> incremental
--    by received_at (1 h overlap) plus any id above the highest one mirrored.
--    ReplacingMergeTree ORDER BY id collapses re-sent rows: use FINAL. ────────
CREATE TABLE IF NOT EXISTS hauling.station_heartbeat
(
    id              Int64,
    received_at     DateTime64(3, 'UTC'),
    station_id      String,
    station_version Nullable(String),
    pc_time         Nullable(DateTime64(3, 'UTC')),
    skew_ms         Nullable(Int32),
    scale_connected Nullable(Bool),
    trucks_on_site  Nullable(Int32),
    sync_pending    Nullable(Int32),
    sync_dead       Nullable(Int32),
    oldest_job_min  Nullable(Int32),
    last_push_ok_at Nullable(DateTime64(3, 'UTC')),
    uptime_s        Nullable(Int32)
)
ENGINE = ReplacingMergeTree
ORDER BY id;

-- ── _sync_state: one row per successful run; the newest synced_through is the
--    watermark of the incremental tables. A failed run writes nothing. ────────
CREATE TABLE IF NOT EXISTS hauling._sync_state
(
    run_at         DateTime64(3, 'UTC'),
    synced_through DateTime64(3, 'UTC'),
    mode           LowCardinality(String)
)
ENGINE = MergeTree
ORDER BY run_at;
