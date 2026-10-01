-- Round 2: more appends once the heartbeat table is no longer empty.
INSERT INTO station_heartbeat (id, station_id, received_at, skew_ms) VALUES
  (60, 'stn-1', now(), 1),                         -- ordinary new row
  (61, 'stn-4', now() - interval '4 days', 2);     -- old received_at, id above the mirrored max
INSERT INTO error_log (error_id, source, level, message, created_at) VALUES
  ('00000000-0000-4000-8000-00000000e201', 'backend', 'error', 'round 2', now());
