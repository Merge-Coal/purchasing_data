-- Synthetic data for the local stand-in database `hauling_dev`.
-- Load AFTER pg_schema.sql:
--     psql -X -v ON_ERROR_STOP=1 -d hauling_dev -f test/hauling/pg_schema.sql
--     psql -X -v ON_ERROR_STOP=1 -d hauling_dev -f test/hauling/seed.sql
--
-- Fully deterministic: every "random" value is a hash (md5) of the row number, and
-- every uuid is md5(<label>)::uuid, so two loads produce identical rows (no now(),
-- no random(), no gen_random_uuid()).
-- Assumptions made where the real semantics are unknown: compare_gross_kg = gross_site_kg
-- (the reference gross), deviasi_kg = gross_jetty_kg - compare_gross_kg; the weighbridge
-- timestamps are Asia/Makassar wall-clock times (06:00-16:00 local), so the UTC value of cp1
-- is on the previous UTC calendar day for trips before 08:00 local (a deliberate edge for the sync).
--
-- EXPECTED TOTALS AFTER seed.sql (verified on PostgreSQL 14 when this file was written):
--   trips=1200  sum(netto_site_kg)=39525449  sum(netto_jetty_kg)=39473729
--         sum(gross_site_kg)=57501315  sum(gross_jetty_kg)=57390174  sum(deviasi_kg)=85107
--         sum(adjustment_kg)=-1534  sum(tare_site_kg)=18021348
--   trips by status: arrived_jetty=3, completed=1190, in_transit=4, pending=3
--   trips by jetty: hasnur=605, talenta=595
--   trips by quality: clean=379, premium=173, raw=403, standard=245
--   trips: distinct no_lambung=80, date range 2026-05-21..2026-08-26, with session_id=12,
--         cp1_event_id not null=645, cp2_event_id not null=605, is_locked true/false/null=858/333/9
--   trips: tare_jetty_kg not null=839, tare_source scale=714, gross_source scale=721, cp1 not
--         null=1197, cp2 not null=1193, cp3 not null=1190
--   sessions=3
--   barge_loadings=16  sum(loading_qty_kg)=121364538  dates 2026-05-30..2026-08-13
--   scale_readings_pending=4  sum(weight_kg)=129427.50
--   station_heartbeat=500  ids 1..500  received_at 2026-08-20 00:17:00.485..2026-08-25 21:40:00.262
--         UTC;  NULLs: station_version=10 pc_time=12 skew_ms=12 scale_connected=20
--         trucks_on_site=333 oldest_job_min=9 last_push_ok_at=15; sum(sync_pending)=7259
--         sum(sync_dead)=41
--   station_heartbeat per station: STN-JETTY-HASNUR=167, STN-JETTY-TALENTA=167, STN-SITE-01=166
--   error_log=300  context NOT NULL=225 (NULL=75)  max(length(context::text))=2112  created_at
--         2026-05-21 08:33:38.096..2026-08-25 23:01:17.929 UTC;  by level: error=200 warn=100;
--         sum(length(message))=22242
--   error_log by source: backend=114, frontend=87, station=99

BEGIN;

-- hash(key, modulus) -> 0..modulus-1, stable across runs and evaluation order.
CREATE FUNCTION pg_temp.h(k text, m int) RETURNS int LANGUAGE sql IMMUTABLE AS
$$ SELECT (('x' || substr(md5(k), 1, 7))::bit(28)::int % m) $$;

-- ── sessions (3; a few trips reference them) ────────────────────────────────
INSERT INTO sessions (session_id, status) VALUES
  (md5('session-1')::uuid, 'ended'),
  (md5('session-2')::uuid, 'ended'),
  (md5('session-3')::uuid, 'active');

-- ── trips: 1200 rows, 2026-05-21 .. 2026-08-26, trucks DT-001 .. DT-080 ─────
-- n 1..1190 completed, 1191-1194 in_transit, 1195-1197 arrived_jetty, 1198-1200 pending.
INSERT INTO trips (
  trip_id, date, status, no_tiket, no_lambung, jetty_destination, coal_quality, cuaca_mmi,
  tare_site_kg, cp1_timestamp, gross_site_kg, netto_site_kg, cp2_timestamp, gross_jetty_kg,
  netto_jetty_kg, compare_gross_kg, deviasi_kg, cp3_timestamp, adjustment_kg, is_locked,
  session_id, tare_jetty_kg, stockpile_code, tare_source, gross_source, cp1_event_id, cp2_event_id)
WITH g AS (
  SELECT n,
         CASE WHEN n <= 1190 THEN date '2026-05-21' + pg_temp.h('d' || n, 98)
              ELSE date '2026-08-26' - (n % 3) END                                 AS d,
         1 + pg_temp.h('truck' || n, 80)                                           AS truck,
         CASE WHEN n <= 1190 THEN 'completed' WHEN n <= 1194 THEN 'in_transit'
              WHEN n <= 1197 THEN 'arrived_jetty' ELSE 'pending' END               AS st
    FROM generate_series(1, 1200) AS n
), t AS (
  SELECT g.*,
         row_number() OVER (PARTITION BY d ORDER BY n)                             AS tiket,
         CASE WHEN pg_temp.h('j' || n, 100) < 52 THEN 'hasnur' ELSE 'talenta' END  AS jetty,
         CASE WHEN pg_temp.h('q' || n, 100) < 35 THEN 'raw'
              WHEN pg_temp.h('q' || n, 100) < 65 THEN 'clean'
              WHEN pg_temp.h('q' || n, 100) < 80 THEN 'premium' ELSE 'standard' END AS quality,
         14000 + pg_temp.h('tt' || truck, 1200) + pg_temp.h('tn' || n, 800)        AS tare,      -- 14000..15999
         44000 + pg_temp.h('g' || n, 8001)                                         AS gross,     -- 44000..52000
         -60 + pg_temp.h('dv' || n, 260)                                           AS dev,       -- -60..+199 (mean ~ +70)
         CASE WHEN pg_temp.h('tj' || n, 100) < 70 THEN pg_temp.h('tjd' || n, 41) - 20 END AS tj_delta,
         (date '2026-08-26' - (n % 3))                                             AS d_unfinished
    FROM g
), c AS (
  SELECT t.*,
         ((d::timestamp + (6 * 3600 + pg_temp.h('c1' || n, 36000)) * interval '1 second')
            AT TIME ZONE 'Asia/Makassar') + pg_temp.h('ms1' || n, 1000) * interval '1 millisecond' AS cp1,
         (40 + pg_temp.h('c2' || n, 80)) * interval '1 minute' + pg_temp.h('ms2' || n, 1000) * interval '1 millisecond' AS d12,
         (5 + pg_temp.h('c3' || n, 25)) * interval '1 minute' + pg_temp.h('ms3' || n, 1000) * interval '1 millisecond' AS d23
    FROM t
)
SELECT
  md5('trip-' || n)::uuid,
  d,
  st::trip_status_enum,
  tiket,
  'DT-' || lpad(truck::text, 3, '0'),
  jetty::jetty_destination_enum,
  quality::coal_quality_enum,
  (ARRAY['Cerah', 'Berawan', 'Hujan ringan', 'Hujan lebat', 'Gerimis'])[1 + pg_temp.h('w' || d::text, 5)],
  tare,
  CASE WHEN st <> 'pending' THEN cp1 END,
  CASE WHEN st <> 'pending' THEN gross END,
  CASE WHEN st <> 'pending' THEN gross - tare END,
  CASE WHEN st IN ('arrived_jetty', 'completed') THEN cp1 + d12 END,
  CASE WHEN st IN ('arrived_jetty', 'completed') THEN gross + dev END,
  CASE WHEN st IN ('arrived_jetty', 'completed') THEN gross + dev - (tare + coalesce(tj_delta, 0)) END,
  CASE WHEN st IN ('arrived_jetty', 'completed') THEN gross END,                  -- compare_gross_kg
  CASE WHEN st IN ('arrived_jetty', 'completed') THEN dev END,                    -- deviasi_kg = gross_jetty - compare_gross
  CASE WHEN st = 'completed' THEN cp1 + d12 + d23 END,
  CASE WHEN st = 'completed' AND pg_temp.h('adj' || n, 100) < 5 THEN pg_temp.h('adjv' || n, 401) - 200 ELSE 0 END,
  CASE WHEN st = 'completed' AND d < date '2026-08-01' THEN true
       WHEN pg_temp.h('lk' || n, 100) < 2 THEN NULL ELSE false END,
  CASE WHEN n % 100 = 7 THEN md5('session-' || (1 + (n / 100) % 3))::uuid END,
  CASE WHEN st IN ('arrived_jetty', 'completed') AND tj_delta IS NOT NULL THEN tare + tj_delta END,
  CASE WHEN pg_temp.h('sp' || n, 100) < 30 THEN 'SP-A' WHEN pg_temp.h('sp' || n, 100) < 45 THEN 'SP-B' ELSE '' END,
  CASE WHEN pg_temp.h('ts' || n, 100) < 60 THEN 'scale' ELSE 'manual' END,
  CASE WHEN st <> 'pending' AND pg_temp.h('gs' || n, 100) < 60 THEN 'scale' ELSE 'manual' END,
  CASE WHEN st <> 'pending' AND pg_temp.h('e1' || n, 100) < 55 THEN 'cp1-' || md5('cp1-' || n) END,
  CASE WHEN st IN ('arrived_jetty', 'completed') AND pg_temp.h('e2' || n, 100) < 50
       THEN 'cp2-' || md5('cp2-' || (n / 2)) END                                  -- pairs of trips share a cp2 id
FROM c;

-- ── barge_loadings: 16 ──────────────────────────────────────────────────────
INSERT INTO barge_loadings (loading_id, jetty, barge_name, tug_boat_name, loading_date, loading_qty_kg, created_at, stockpile_code)
SELECT md5('barge-' || n)::uuid,
       (CASE WHEN n % 2 = 1 THEN 'hasnur' ELSE 'talenta' END)::jetty_destination_enum,
       'BG. MMI ' || (300 + n),
       (ARRAY['TB. Sinar Borneo 5', 'TB. Bintang Laut 12', 'TB. Samudra Jaya 3', 'TB. Kapuas Express'])[1 + n % 4],
       date '2026-05-25' + n * 5,
       5500000 + pg_temp.h('bq' || n, 4000001),
       ((date '2026-05-25' + n * 5)::timestamp + interval '17 hours 20 minutes') AT TIME ZONE 'Asia/Makassar',
       CASE WHEN n % 4 = 0 THEN 'SP-B' WHEN n % 3 = 0 THEN 'SP-A' ELSE '' END
  FROM generate_series(1, 16) AS n;

-- ── scale_readings_pending: 4 rows, fractional weights ──────────────────────
INSERT INTO scale_readings_pending (no_lambung, reading_type, weight_kg, measured_at, created_at) VALUES
  ('DT-012', 'tare',  14873.5,  timestamptz '2026-08-26 01:15:30.250+00', timestamptz '2026-08-26 01:15:31+00'),
  ('DT-012', 'gross', 48210.25, timestamptz '2026-08-26 02:02:11.125+00', timestamptz '2026-08-26 02:02:12+00'),
  ('DT-047', 'tare',  15109.0,  timestamptz '2026-08-26 03:40:00+00',     timestamptz '2026-08-26 03:40:01+00'),
  ('DT-063', 'gross', 51234.75, timestamptz '2026-08-26 04:05:45.500+00', timestamptz '2026-08-26 04:05:46+00');

-- ── station_heartbeat: 500 rows, 3 stations, ids 1..500 in time order, some NULLs ──
INSERT INTO station_heartbeat (received_at, station_id, station_version, pc_time, skew_ms, scale_connected,
                               trucks_on_site, sync_pending, sync_dead, oldest_job_min, last_push_ok_at, uptime_s)
SELECT r,
       (ARRAY['STN-SITE-01', 'STN-JETTY-HASNUR', 'STN-JETTY-TALENTA'])[1 + n % 3],
       CASE WHEN n % 50 = 0 THEN NULL WHEN n % 3 = 0 THEN '1.4.2' ELSE '1.4.3' END,
       CASE WHEN n % 40 = 0 THEN NULL ELSE r - skew * interval '1 millisecond' END,
       CASE WHEN n % 40 = 0 THEN NULL ELSE skew END,
       CASE WHEN n % 25 = 0 THEN NULL ELSE pg_temp.h('sc' || n, 100) >= 8 END,
       CASE WHEN n % 3 = 1 THEN pg_temp.h('tr' || n, 13) END,                     -- site station only
       pg_temp.h('sp' || n, 31),
       CASE WHEN pg_temp.h('sd' || n, 100) < 6 THEN 1 + pg_temp.h('sd2' || n, 2) ELSE 0 END,
       CASE WHEN pg_temp.h('sp' || n, 31) = 0 THEN NULL ELSE 1 + pg_temp.h('oj' || n, 45) END,
       CASE WHEN n % 33 = 0 THEN NULL ELSE r - pg_temp.h('lp' || n, 600) * interval '1 second' END,
       (n % 200) * 1020 + pg_temp.h('up' || n, 600)
  FROM (SELECT n,
               timestamptz '2026-08-20 00:00:00+00' + n * interval '17 minutes' + pg_temp.h('hm' || n, 1000) * interval '1 millisecond' AS r,
               pg_temp.h('sk' || n, 551) - 150 AS skew
          FROM generate_series(1, 500) AS n) AS s
 ORDER BY n;

-- ── error_log: 300 rows ─────────────────────────────────────────────────────
INSERT INTO error_log (error_id, source, level, message, context, created_at)
SELECT md5('err-' || n)::uuid,
       (ARRAY['station', 'backend', 'frontend'])[1 + pg_temp.h('es' || n, 3)],
       CASE WHEN pg_temp.h('el' || n, 100) < 30 THEN 'warn' ELSE 'error' END,
       (ARRAY[
          'Scale connection timeout on COM3 after 5000 ms',
          E'Unhandled "TypeError": cannot read properties of undefined (reading ''trip_id'')\n    at saveTrip (/app/routes/trips.js:142:17)\n    at process.processTicksAndRejections',
          '称重失败：地磅连接超时，请检查串口线 (COM3)',
          E'Sync job failed:\r\n  HTTP 502 Bad Gateway\n  body="<html><h1>502</h1></html>"',
          'duplicate key value violates unique constraint "idx_trips_cp1_event_id"',
          'Cannot write C:\Users\station\logs\app.log (backslashes, 100% literal)',
          'Clock skew too large: 41230 ms; 时钟偏差过大 😀 reset',
          E'Message with a tab\there, ''single'' and "double" quotes; a semicolon, comma | pipe',
          'Weight out of range: gross 52310 kg > limit 52000 kg',
          'Heartbeat failed for station STN-JETTY-HASNUR'
        ])[1 + n % 10] || ' [e' || n || ']',
       CASE
         WHEN n = 150 THEN jsonb_build_object('blob', repeat('stack frame "é"中 ', 110), 'n', n)      -- ~2.1 KB of jsonb text
         WHEN n % 4 = 0 THEN NULL
         WHEN n % 60 = 3 THEN to_jsonb('plain "string" context, 中文'::text)
         WHEN n % 40 = 2 THEN '[1, 2, {"a": "é", "b": null}]'::jsonb
         WHEN n % 25 = 1 THEN '{}'::jsonb
         WHEN n % 3 = 0 THEN jsonb_build_object('station', 'STN-SITE-01', 'attempt', n % 5)
         ELSE jsonb_build_object(
                'station', (ARRAY['STN-SITE-01', 'STN-JETTY-HASNUR', 'STN-JETTY-TALENTA'])[1 + n % 3],
                'attempt', n % 5, 'ok', n % 2 = 0, 'ratio', (n % 7) / 4.0,
                'detail', jsonb_build_object(
                    'note', '称重失败 "retry" it''s 🙂',
                    'path', 'C:\temp\x',
                    'tags', jsonb_build_array('a', 'b"c', NULL, 3, 1.5)))
       END,
       timestamptz '2026-05-21 00:00:00+00' + (n * 27900 + pg_temp.h('et' || n, 20000)) * interval '1 second'
         + pg_temp.h('ems' || n, 1000) * interval '1 millisecond'
  FROM generate_series(1, 300) AS n;

COMMIT;
ANALYZE;
