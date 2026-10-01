-- Changes to hauling_dev (loaded from pg_schema.sql + seed.sql) that simulate what the live
-- system does between two sync runs. Run ONE STEP at a time, e.g.
--     awk '/^-- ==== STEP 1 ====/{f=1;next} /^-- ==== STEP [0-9]+ ====/{f=0} f' test/hauling/mutate.sql \
--       | psql -X -v ON_ERROR_STOP=1 -d hauling_dev
-- Each step is plain SQL (no psql meta-commands) in its own transaction. Steps are meant to be run
-- once, in order, on a freshly seeded database. Effects on the seed totals (see seed.sql header)
-- are written under each step ("AFTER STEP n" lines are verified values).

-- ==== STEP 1 ====
-- trips: update 10, delete 3, insert 5.
--   Updates 1-3:  weights of completed trips n=1,2,3 (gross_jetty/netto_jetty/deviasi) and cp3 shifted +2 min
--   Updates 4-5:  completed trips n=4,5: is_locked toggled, adjustment_kg set
--   Update 6:     n=6 completed -> keeps status but cp1_timestamp moved +1 min (cp1<cp2 still holds), cp1_event_id set NULL
--   Update 7:     n=1191 in_transit -> arrived_jetty (cp2, gross_jetty, netto_jetty, compare, deviasi filled)
--   Update 8:     n=1195 arrived_jetty -> completed (cp3 filled)
--   Update 9:     n=1198 pending -> in_transit (cp1, gross_site, netto_site filled)
--   Update 10:    n=1199 pending: only tare_site_kg changed
--   Deletes:      n=21, 22, 23 (completed, no session)
--   Inserts:      5 new trips n=2001..2005 on 2026-08-27 (completed x2, in_transit, arrived_jetty, pending)
BEGIN;

UPDATE trips SET gross_jetty_kg = gross_jetty_kg + 120, netto_jetty_kg = netto_jetty_kg + 120,
                 deviasi_kg = deviasi_kg + 120, cp3_timestamp = cp3_timestamp + interval '2 minutes'
 WHERE trip_id IN (md5('trip-1')::uuid, md5('trip-2')::uuid, md5('trip-3')::uuid);

UPDATE trips SET is_locked = NOT coalesce(is_locked, false), adjustment_kg = 175
 WHERE trip_id IN (md5('trip-4')::uuid, md5('trip-5')::uuid);

UPDATE trips SET cp1_timestamp = cp1_timestamp + interval '1 minute', cp1_event_id = NULL
 WHERE trip_id = md5('trip-6')::uuid;

UPDATE trips SET status = 'arrived_jetty', cp2_timestamp = cp1_timestamp + interval '75 minutes 250 milliseconds',
                 gross_jetty_kg = gross_site_kg + 85, netto_jetty_kg = gross_site_kg + 85 - tare_site_kg,
                 compare_gross_kg = gross_site_kg, deviasi_kg = 85
 WHERE trip_id = md5('trip-1191')::uuid;

UPDATE trips SET status = 'completed', cp3_timestamp = cp2_timestamp + interval '15 minutes 500 milliseconds'
 WHERE trip_id = md5('trip-1195')::uuid;

UPDATE trips SET status = 'in_transit', cp1_timestamp = timestamptz '2026-08-26 02:10:05.375+00',
                 gross_site_kg = 47500, netto_site_kg = 47500 - tare_site_kg
 WHERE trip_id = md5('trip-1198')::uuid;

UPDATE trips SET tare_site_kg = tare_site_kg + 40 WHERE trip_id = md5('trip-1199')::uuid;

DELETE FROM trips WHERE trip_id IN (md5('trip-21')::uuid, md5('trip-22')::uuid, md5('trip-23')::uuid);

INSERT INTO trips (trip_id, date, status, no_tiket, no_lambung, jetty_destination, coal_quality, cuaca_mmi,
                   tare_site_kg, cp1_timestamp, gross_site_kg, netto_site_kg, cp2_timestamp, gross_jetty_kg,
                   netto_jetty_kg, compare_gross_kg, deviasi_kg, cp3_timestamp, adjustment_kg, is_locked,
                   tare_jetty_kg, stockpile_code, tare_source, gross_source, cp1_event_id, cp2_event_id)
VALUES
  (md5('trip-2001')::uuid, '2026-08-27', 'completed', 1, 'DT-005', 'hasnur', 'clean', 'Cerah',
   14800, '2026-08-26 22:30:00.100+00', 46000, 31200, '2026-08-27 00:05:00.200+00', 46090, 31290, 46000, 90,
   '2026-08-27 00:25:00.300+00', 0, false, 14800, 'SP-A', 'scale', 'scale', 'cp1-new-2001', 'cp2-new-2001'),
  (md5('trip-2002')::uuid, '2026-08-27', 'completed', 2, 'DT-017', 'talenta', 'raw', 'Cerah',
   15200, '2026-08-26 23:10:00+00', 49000, 33800, '2026-08-27 00:50:00+00', 49120, 33920, 49000, 120,
   '2026-08-27 01:10:00+00', -50, false, NULL, '', 'manual', 'manual', 'cp1-new-2002', NULL),
  (md5('trip-2003')::uuid, '2026-08-27', 'in_transit', 3, 'DT-033', 'hasnur', 'premium', 'Berawan',
   14500, '2026-08-27 01:40:00.999+00', 45500, 31000, NULL, NULL, NULL, NULL, NULL, NULL, 0, false,
   NULL, '', 'scale', 'scale', 'cp1-new-2003', NULL),
  (md5('trip-2004')::uuid, '2026-08-27', 'arrived_jetty', 4, 'DT-048', 'talenta', 'standard', 'Berawan',
   15900, '2026-08-27 00:10:00+00', 50500, 34600, '2026-08-27 01:55:00+00', 50610, 34710, 50500, 110, NULL, 0, false,
   NULL, 'SP-B', 'manual', 'scale', NULL, 'cp2-new-2004'),
  (md5('trip-2005')::uuid, '2026-08-27', 'pending', 5, 'DT-061', 'hasnur', 'clean', 'Gerimis',
   14200, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 0, false, NULL, '', 'manual', 'manual', NULL, NULL);

COMMIT;

-- ==== STEP 2 ====
-- error_log: 20 new rows with created_at = now() (+ i milliseconds so they are distinct and ordered);
-- station_heartbeat: 15 new rows, three of them late-arriving: received_at is OLD (inside/outside the
-- sync overlap window) but the id is NEW (higher than every earlier id).
--   heartbeat ids 501..512: received_at = now() - (12-i) minutes (normal, in order)
--   heartbeat id 513: received_at '2026-08-20 03:00:00+00' (days old, NEW id)    <- late-arriving
--   heartbeat id 514: received_at now() - interval '3 hours'                      <- late-arriving, outside a 1 h overlap
--   heartbeat id 515: received_at now() - interval '20 minutes' with NULL optional columns
BEGIN;

INSERT INTO error_log (error_id, source, level, message, context, created_at)
SELECT md5('mut-err-' || i)::uuid,
       (ARRAY['station', 'backend', 'frontend'])[1 + i % 3],
       CASE WHEN i % 4 = 0 THEN 'warn' ELSE 'error' END,
       CASE WHEN i % 5 = 0 THEN E'multi-line\nmessage with "quotes" and 中文 #' || i ELSE 'new error after sync #' || i END,
       CASE WHEN i % 3 = 0 THEN NULL ELSE jsonb_build_object('step', 2, 'i', i, 'note', '中文 "q"') END,
       now() + i * interval '1 millisecond'
  FROM generate_series(1, 20) AS i;

INSERT INTO station_heartbeat (received_at, station_id, station_version, pc_time, skew_ms, scale_connected,
                               trucks_on_site, sync_pending, sync_dead, oldest_job_min, last_push_ok_at, uptime_s)
SELECT now() - (12 - i) * interval '1 minute',
       (ARRAY['STN-SITE-01', 'STN-JETTY-HASNUR', 'STN-JETTY-TALENTA'])[1 + i % 3],
       '1.4.3', now() - (12 - i) * interval '1 minute', 10 * i, true, i % 9, i, 0, NULL,
       now() - (12 - i) * interval '1 minute' - interval '30 seconds', 86400 + i * 60
  FROM generate_series(1, 12) AS i;

INSERT INTO station_heartbeat (received_at, station_id, station_version, pc_time, skew_ms, scale_connected,
                               trucks_on_site, sync_pending, sync_dead, oldest_job_min, last_push_ok_at, uptime_s)
VALUES
  (timestamptz '2026-08-20 03:00:00+00', 'STN-SITE-01', '1.4.2', timestamptz '2026-08-20 03:00:00.040+00', 40, true, 4, 2, 0, 3, timestamptz '2026-08-20 02:59:30+00', 7200),
  (now() - interval '3 hours', 'STN-JETTY-HASNUR', '1.4.3', now() - interval '3 hours', -20, false, NULL, 11, 1, 25, now() - interval '3 hours 5 minutes', 5400),
  (now() - interval '20 minutes', 'STN-JETTY-TALENTA', NULL, NULL, NULL, NULL, NULL, 0, 0, NULL, NULL, 300);

COMMIT;

-- ==== STEP 3 ====
-- scale_readings_pending: delete all rows, insert 2 new ones (fractional weights);
-- barge_loadings: update one row's quantity (barge n=1: loading_qty_kg := 7777000).
BEGIN;

DELETE FROM scale_readings_pending;

INSERT INTO scale_readings_pending (no_lambung, reading_type, weight_kg, measured_at, created_at) VALUES
  ('DT-070', 'tare',  15333.125, timestamptz '2026-08-27 00:30:00.500+00', timestamptz '2026-08-27 00:30:01+00'),
  ('DT-071', 'gross', 49999.9,   timestamptz '2026-08-27 00:45:00+00',     timestamptz '2026-08-27 00:45:01+00');

UPDATE barge_loadings SET loading_qty_kg = 7777000 WHERE loading_id = md5('barge-1')::uuid;

COMMIT;
