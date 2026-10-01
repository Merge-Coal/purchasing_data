-- Round 1 of changes in the live (stand-in) Postgres, after the first sync.
SET timezone = 'Asia/Makassar';

-- trips: update values, value -> NULL, NULL -> value, delete, insert
UPDATE trips SET netto_site_kg = netto_site_kg + 100, status = 'completed' WHERE trip_id = '00000000-0000-4000-8000-000000000001';
UPDATE trips SET gross_site_kg = NULL, netto_site_kg = NULL WHERE trip_id = '00000000-0000-4000-8000-000000000002';
UPDATE trips SET is_locked = true, cp2_timestamp = '2026-10-01 07:00:00.987654+08', netto_jetty_kg = 18999,
                 status = 'arrived_jetty', cp1_event_id = 'evt-new' WHERE trip_id = '00000000-0000-4000-8000-00000000f001';
UPDATE trips SET status = 'completed', cp3_timestamp = now(), gross_jetty_kg = 35500, netto_jetty_kg = 20000
 WHERE trip_id = '00000000-0000-4000-8000-00000000f002';
DELETE FROM trips WHERE trip_id IN ('00000000-0000-4000-8000-000000000005', '00000000-0000-4000-8000-000000000006',
                                    '00000000-0000-4000-8000-000000000007');
INSERT INTO trips (trip_id, date, status, no_tiket, no_lambung, jetty_destination, coal_quality, cuaca_mmi, tare_site_kg,
                   cp1_timestamp, gross_site_kg, netto_site_kg, is_locked, stockpile_code)
VALUES ('00000000-0000-4000-8000-00000000f003', '2026-10-01', 'in_transit', 2010, 'TR-NEW1', 'talenta', 'raw', 'berawan', 15100, now(), 35000, 19900, NULL, 'SP-9'),
       ('00000000-0000-4000-8000-00000000f004', '2026-10-01', 'pending', 2011, 'TR-NEW2 ü', 'hasnur', 'standard', E'tab\there', 15200, NULL, NULL, NULL, false, ''),
       ('00000000-0000-4000-8000-00000000f005', '2026-10-01', 'completed', 2012, 'TR-NEW3', 'hasnur', 'premium', 'cerah', 15300, now() - interval '2 hours', 36000, 20700, true, 'SP-1');

-- barge_loadings: update, delete, insert
UPDATE barge_loadings SET loading_qty_kg = 7600000, barge_name = 'BG Anugerah 1 (rev)' WHERE loading_id = '00000000-0000-4000-8000-00000000b001';
DELETE FROM barge_loadings WHERE loading_id = '00000000-0000-4000-8000-00000000b002';
INSERT INTO barge_loadings (loading_id, jetty, barge_name, tug_boat_name, loading_date, loading_qty_kg, stockpile_code)
VALUES ('00000000-0000-4000-8000-00000000b003', 'talenta', 'BG New', 'TB New', '2026-10-01', 5000000, 'SP-2');

-- scale_readings_pending: the queue is emptied
DELETE FROM scale_readings_pending;

-- error_log: new rows, one of them late (created_at in the past, inside the overlap)
INSERT INTO error_log (error_id, source, level, message, context, created_at) VALUES
  ('00000000-0000-4000-8000-00000000e101', 'station',  'error', E'new: "q" ''s'' \\ \n 日本語 😀', '{"a": [1, {"b": "ü\n"}]}', now()),
  ('00000000-0000-4000-8000-00000000e102', 'backend',  'warn',  'late row', NULL, now() - interval '30 minutes'),
  ('00000000-0000-4000-8000-00000000e103', 'frontend', 'error', repeat('x', 5000), '{}', now());

-- station_heartbeat: still empty before this point. Normal rows, a row received 20 min ago,
-- and a LATE row: old received_at (3 days) but a new id.
INSERT INTO station_heartbeat (station_id, station_version, pc_time, skew_ms, scale_connected, trucks_on_site, sync_pending,
                               sync_dead, oldest_job_min, last_push_ok_at, uptime_s, received_at) VALUES
  ('stn-1', '1.2.3', now(), -15, true, 3, 0, 0, NULL, now(), 3600, now()),
  ('stn-2', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, now()),
  ('stn-1', '1.2.3', now() - interval '20 minutes', 250, false, 0, 4, 1, 12, now() - interval '25 minutes', 7200, now() - interval '20 minutes'),
  ('stn-3', '1.0.0', now() - interval '3 days', 0, true, 1, 0, 0, 0, now() - interval '3 days', 1, now() - interval '3 days');
