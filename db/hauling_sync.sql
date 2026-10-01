-- ============================================================
-- hauling_tracker (Postgres, another team's LIVE system) -> ClickHouse database `hauling`
--
-- Template, not run directly: scripts/hauling_sync.sh substitutes
--   @SINCE@      'YYYY-MM-DD hh:mm:ss.fff' UTC: the last successful run's start
--                minus a 1 hour overlap (1970-01-01 for --full)
--   @RUN_START@  this run's start time in UTC, recorded as the new watermark
--   @MODE@       'incremental' or 'full'
--   @HB_MAX_ID@  highest station_heartbeat.id already mirrored (0 if none)
-- keeps only the section that matches the mode (the `-- @@INCREMENTAL`,
-- `-- @@FULL`, `-- @@END` marker lines), and streams the result into
-- clickhouse-client --multiquery. The client stops at the first failing
-- statement, so the watermark INSERT at the bottom only runs when every
-- statement before it succeeded.
--
-- READ-ONLY towards Postgres: the only thing ever done there is
-- `SELECT ... FROM postgresql(pg_hauling, table = '...')` through the read-only
-- role hauling_ro (named collection db/clickhouse-config.d/40-pg-hauling.xml).
-- Nothing in this file writes to the hauling_tracker database.
--
-- Strategy
--   trips, barge_loadings, scale_readings_pending   snapshot swap every run:
--       hauling.<t>_new is created with the structure of hauling.<t>, filled
--       from Postgres, then EXCHANGE TABLES swaps it with the live table
--       atomically and the old copy is dropped. All loads happen BEFORE any
--       swap, so a failure while loading leaves every live table untouched.
--       Updates and deletes in Postgres propagate. A stale <t>_new left by a
--       failed run is dropped at the start of the next run.
--   error_log, station_heartbeat
--       incremental: rows newer than @SINCE@ (see below) that are not yet in
--       ClickHouse are appended (ReplacingMergeTree, so a re-sent row collapses
--       anyway; dashboards use FINAL). --full rebuilds them by snapshot swap
--       like the others (also repairs/removes anything that drifted).
--
-- Conversions (Postgres -> ClickHouse types in db/hauling_ch_schema.sql)
--   timestamptz  postgresql() hands over DateTime64(6) in the *server* time zone
--       and ignores the offset of the text. hauling_ro's sessions are pinned to
--       timezone=UTC and datestyle='ISO, YMD' (db/hauling_ro_setup.sql), so the
--       text is UTC wall-clock; toDateTime64(toString(x), 6, 'UTC') turns it back
--       into the right instant whatever the ClickHouse server time zone is.
--       The column is DateTime64(3): the microsecond part is truncated.
--   enum         String via toString(); text/uuid/date/int/bigint as they come.
--   boolean      read as UInt8, stored as Bool (CAST ... Nullable(Bool)).
--   numeric      scale_readings_pending.weight_kg has no declared precision;
--       ClickHouse reads it as a wide Decimal. toFloat64(Decimal) directly gives
--       binary noise (123456.789 -> 123456.78899999999), so it goes through its
--       text form: toFloat64(toString(x)) is the double nearest to the Postgres value.
--   jsonb        error_log.context arrives as its text form (String).
--
-- Incremental window. A row is sent if it is newer than @SINCE@ minus one extra
-- day and its key is not yet in ClickHouse. The extra day only widens the read:
-- the anti-join makes it exact. It is needed because the filter compares the RAW
-- timestamptz column, which ClickHouse types as DateTime64(6) in the server time
-- zone (it holds UTC wall-clock text, so it is off by the server's UTC offset,
-- e.g. 8 h on the Asia/Makassar host), and because a ClickHouse version may format
-- the literal it pushes down into the Postgres query differently. A one-day pad
-- covers any offset up to +/-14 h. The raw column is compared on purpose: wrapping
-- it in toDateTime64(toString(...)) would stop the filter being pushed down and
-- make every run read the whole table. station_heartbeat additionally takes every id
-- above the highest one mirrored, so a row inserted late with an old
-- received_at is not missed. A row with BOTH an old timestamp (more than ~25 h)
-- and an id lower than the highest mirrored one would be missed by an
-- incremental run; `--full` picks it up.
-- ============================================================

SET max_execution_time = 600;

-- Start clean: a failed earlier run may have left its half-loaded copies behind.
DROP TABLE IF EXISTS hauling.trips_new;
DROP TABLE IF EXISTS hauling.barge_loadings_new;
DROP TABLE IF EXISTS hauling.scale_readings_pending_new;
DROP TABLE IF EXISTS hauling.error_log_new;
DROP TABLE IF EXISTS hauling.station_heartbeat_new;

-- ── snapshot tables: load the new copies (live tables not touched yet) ────────

-- trips
CREATE TABLE hauling.trips_new AS hauling.trips;
INSERT INTO hauling.trips_new
    (trip_id, date, status, no_tiket, no_lambung, jetty_destination, coal_quality,
     cuaca_mmi, tare_site_kg, cp1_timestamp, gross_site_kg, netto_site_kg, cp2_timestamp,
     gross_jetty_kg, netto_jetty_kg, compare_gross_kg, deviasi_kg, cp3_timestamp,
     adjustment_kg, is_locked, session_id, tare_jetty_kg, stockpile_code, tare_source,
     gross_source, cp1_event_id, cp2_event_id)
SELECT s.trip_id,
       s.date,
       toString(s.status),
       s.no_tiket,
       s.no_lambung,
       toString(s.jetty_destination),
       toString(s.coal_quality),
       s.cuaca_mmi,
       s.tare_site_kg,
       toDateTime64(toString(s.cp1_timestamp), 6, 'UTC'),
       s.gross_site_kg,
       s.netto_site_kg,
       toDateTime64(toString(s.cp2_timestamp), 6, 'UTC'),
       s.gross_jetty_kg,
       s.netto_jetty_kg,
       s.compare_gross_kg,
       s.deviasi_kg,
       toDateTime64(toString(s.cp3_timestamp), 6, 'UTC'),
       s.adjustment_kg,
       CAST(s.is_locked AS Nullable(Bool)),
       s.session_id,
       s.tare_jetty_kg,
       s.stockpile_code,
       s.tare_source,
       s.gross_source,
       s.cp1_event_id,
       s.cp2_event_id
FROM postgresql(pg_hauling, table = 'trips') AS s;

-- barge_loadings
CREATE TABLE hauling.barge_loadings_new AS hauling.barge_loadings;
INSERT INTO hauling.barge_loadings_new
    (loading_id, jetty, barge_name, tug_boat_name, loading_date, loading_qty_kg, created_at,
     stockpile_code)
SELECT s.loading_id,
       toString(s.jetty),
       s.barge_name,
       s.tug_boat_name,
       s.loading_date,
       s.loading_qty_kg,
       toDateTime64(toString(s.created_at), 6, 'UTC'),
       s.stockpile_code
FROM postgresql(pg_hauling, table = 'barge_loadings') AS s;

-- scale_readings_pending
CREATE TABLE hauling.scale_readings_pending_new AS hauling.scale_readings_pending;
INSERT INTO hauling.scale_readings_pending_new
    (no_lambung, reading_type, weight_kg, measured_at, created_at)
SELECT s.no_lambung,
       s.reading_type,
       toFloat64(toString(s.weight_kg)),
       toDateTime64(toString(s.measured_at), 6, 'UTC'),
       toDateTime64(toString(s.created_at), 6, 'UTC')
FROM postgresql(pg_hauling, table = 'scale_readings_pending') AS s;

-- @@FULL
-- ── --full: also rebuild the incremental tables from scratch ───────────────────

CREATE TABLE hauling.error_log_new AS hauling.error_log;
INSERT INTO hauling.error_log_new
    (error_id, source, level, message, context, created_at)
SELECT s.error_id,
       s.source,
       s.level,
       s.message,
       s.context,
       toDateTime64(toString(s.created_at), 6, 'UTC')
FROM postgresql(pg_hauling, table = 'error_log') AS s;

CREATE TABLE hauling.station_heartbeat_new AS hauling.station_heartbeat;
INSERT INTO hauling.station_heartbeat_new
    (id, received_at, station_id, station_version, pc_time, skew_ms, scale_connected,
     trucks_on_site, sync_pending, sync_dead, oldest_job_min, last_push_ok_at, uptime_s)
SELECT s.id,
       toDateTime64(toString(s.received_at), 6, 'UTC'),
       s.station_id,
       s.station_version,
       toDateTime64(toString(s.pc_time), 6, 'UTC'),
       s.skew_ms,
       CAST(s.scale_connected AS Nullable(Bool)),
       s.trucks_on_site,
       s.sync_pending,
       s.sync_dead,
       s.oldest_job_min,
       toDateTime64(toString(s.last_push_ok_at), 6, 'UTC'),
       s.uptime_s
FROM postgresql(pg_hauling, table = 'station_heartbeat') AS s;
-- @@END

-- @@INCREMENTAL
-- ── incremental tables: append what is new ────────────────────────────────────

-- error_log (append-only; created_at)
INSERT INTO hauling.error_log
    (error_id, source, level, message, context, created_at)
SELECT s.error_id,
       s.source,
       s.level,
       s.message,
       s.context,
       toDateTime64(toString(s.created_at), 6, 'UTC')
FROM postgresql(pg_hauling, table = 'error_log') AS s
WHERE s.created_at > toDateTime64('@SINCE@', 6, 'UTC') - INTERVAL 1 DAY
  AND s.error_id NOT IN (SELECT error_id FROM hauling.error_log WHERE created_at > toDateTime64('@SINCE@', 3, 'UTC') - INTERVAL 2 DAY);

-- station_heartbeat (append-only; received_at, plus any id above the highest mirrored).
-- Two statements so each Postgres filter is a plain comparison. The table may be empty.
INSERT INTO hauling.station_heartbeat
    (id, received_at, station_id, station_version, pc_time, skew_ms, scale_connected,
     trucks_on_site, sync_pending, sync_dead, oldest_job_min, last_push_ok_at, uptime_s)
SELECT s.id,
       toDateTime64(toString(s.received_at), 6, 'UTC'),
       s.station_id,
       s.station_version,
       toDateTime64(toString(s.pc_time), 6, 'UTC'),
       s.skew_ms,
       CAST(s.scale_connected AS Nullable(Bool)),
       s.trucks_on_site,
       s.sync_pending,
       s.sync_dead,
       s.oldest_job_min,
       toDateTime64(toString(s.last_push_ok_at), 6, 'UTC'),
       s.uptime_s
FROM postgresql(pg_hauling, table = 'station_heartbeat') AS s
WHERE s.received_at > toDateTime64('@SINCE@', 6, 'UTC') - INTERVAL 1 DAY
  AND s.id NOT IN (SELECT id FROM hauling.station_heartbeat WHERE received_at > toDateTime64('@SINCE@', 3, 'UTC') - INTERVAL 2 DAY);

INSERT INTO hauling.station_heartbeat
    (id, received_at, station_id, station_version, pc_time, skew_ms, scale_connected,
     trucks_on_site, sync_pending, sync_dead, oldest_job_min, last_push_ok_at, uptime_s)
SELECT s.id,
       toDateTime64(toString(s.received_at), 6, 'UTC'),
       s.station_id,
       s.station_version,
       toDateTime64(toString(s.pc_time), 6, 'UTC'),
       s.skew_ms,
       CAST(s.scale_connected AS Nullable(Bool)),
       s.trucks_on_site,
       s.sync_pending,
       s.sync_dead,
       s.oldest_job_min,
       toDateTime64(toString(s.last_push_ok_at), 6, 'UTC'),
       s.uptime_s
FROM postgresql(pg_hauling, table = 'station_heartbeat') AS s
WHERE s.id > @HB_MAX_ID@
  AND s.id NOT IN (SELECT id FROM hauling.station_heartbeat WHERE id > @HB_MAX_ID@);
-- @@END

-- ── swap: every load above succeeded, so make the new copies live ─────────────
EXCHANGE TABLES hauling.trips_new AND hauling.trips;
EXCHANGE TABLES hauling.barge_loadings_new AND hauling.barge_loadings;
EXCHANGE TABLES hauling.scale_readings_pending_new AND hauling.scale_readings_pending;

-- @@FULL
EXCHANGE TABLES hauling.error_log_new AND hauling.error_log;
EXCHANGE TABLES hauling.station_heartbeat_new AND hauling.station_heartbeat;
-- @@END

-- The _new names now hold the previous copies (or nothing, for incremental tables).
DROP TABLE IF EXISTS hauling.trips_new;
DROP TABLE IF EXISTS hauling.barge_loadings_new;
DROP TABLE IF EXISTS hauling.scale_readings_pending_new;
DROP TABLE IF EXISTS hauling.error_log_new;
DROP TABLE IF EXISTS hauling.station_heartbeat_new;

-- ── watermark: last statement, only reached when everything above succeeded ───
INSERT INTO hauling._sync_state (run_at, synced_through, mode)
VALUES (now64(3, 'UTC'), toDateTime64('@RUN_START@', 3, 'UTC'), '@MODE@');
