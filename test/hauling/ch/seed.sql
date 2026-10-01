-- Inline seed for run_sync_test.sh (self-contained; independent of test/hauling/seed.sql).
-- Deliberately awkward values: NULLs, fractional weights, microsecond timestamps
-- written with non-UTC offsets, quotes / backslashes / tabs / newlines / unicode
-- in error messages and jsonb context.
SET timezone = 'Asia/Makassar';   -- the session writing the seed is NOT UTC, on purpose

INSERT INTO sessions (session_id, status) VALUES
  ('00000000-0000-4000-8000-0000000000a1', 'active'),
  ('00000000-0000-4000-8000-0000000000a2', 'ended');

-- 40 plain completed trips + a few special ones.
INSERT INTO trips (trip_id, date, status, no_tiket, no_lambung, jetty_destination, coal_quality, cuaca_mmi,
                   tare_site_kg, cp1_timestamp, gross_site_kg, netto_site_kg, cp2_timestamp, gross_jetty_kg,
                   netto_jetty_kg, compare_gross_kg, deviasi_kg, cp3_timestamp, adjustment_kg, is_locked,
                   session_id, tare_jetty_kg, stockpile_code, tare_source, gross_source, cp1_event_id, cp2_event_id)
SELECT ('00000000-0000-4000-8000-' || lpad(g::text, 12, '0'))::uuid,
       date '2026-09-01' + (g % 20),
       'completed',
       1000 + g,
       'TR-' || lpad((g % 12)::text, 3, '0'),
       CASE WHEN g % 2 = 0 THEN 'hasnur' ELSE 'talenta' END::jetty_destination_enum,
       (ARRAY['raw','clean','premium','standard'])[1 + g % 4]::coal_quality_enum,
       CASE WHEN g % 3 = 0 THEN 'hujan' ELSE 'cerah' END,
       14000 + g,
       timestamptz '2026-09-01 06:00:00.123456+08' + g * interval '1 hour',
       34000 + g * 10, 20000 + g * 10 - 1,
       timestamptz '2026-09-01 07:00:00.5+08' + g * interval '1 hour',
       34100 + g * 10, 20100 + g * 10,
       34050 + g * 10, g - 20,
       timestamptz '2026-09-01 08:00:00+00' + g * interval '1 hour' + interval '999 microseconds',
       0, g % 2 = 0, '00000000-0000-4000-8000-0000000000a1', 14100 + g,
       'SP-' || (g % 3), 'scale', 'scale', 'cp1-' || g, 'cp2-' || g
  FROM generate_series(1, 40) g;

-- Special trips: all-NULL optional columns; NULL is_locked; empty-string codes; in_transit.
INSERT INTO trips (trip_id, date, status, no_tiket, no_lambung, jetty_destination, coal_quality, cuaca_mmi,
                   tare_site_kg, is_locked, stockpile_code)
VALUES ('00000000-0000-4000-8000-00000000f001', '2026-09-30', 'pending', 2001, 'TR-NULL', 'hasnur', 'raw', '', 15000, NULL, ''),
       ('00000000-0000-4000-8000-00000000f002', '2026-09-30', 'in_transit', 2002, 'TR-ÅÄÖ "q" ''s''', 'talenta', 'premium', E'line1\nline2', 15001, false, 'S\P');
UPDATE trips SET cp1_timestamp = '2026-09-30 10:00:00.000001+00', gross_site_kg = 36000 WHERE trip_id = '00000000-0000-4000-8000-00000000f002';

INSERT INTO barge_loadings (loading_id, jetty, barge_name, tug_boat_name, loading_date, loading_qty_kg, created_at, stockpile_code) VALUES
  ('00000000-0000-4000-8000-00000000b001', 'hasnur',  'BG Anugerah 1', 'TB Mutiara', '2026-09-10', 7500000, '2026-09-10 20:15:33.250987+08', 'SP-0'),
  ('00000000-0000-4000-8000-00000000b002', 'talenta', 'BG 粤海 2',      'TB "Sinar"', '2026-09-12', 8250500, '2026-09-12 08:00:00+00', '');

INSERT INTO scale_readings_pending (no_lambung, reading_type, weight_kg, measured_at, created_at) VALUES
  ('TR-001', 'tare',  14873.5,    '2026-10-01 05:00:00.5+08',  '2026-10-01 05:00:01.123456+08'),
  ('TR-001', 'gross', 34873.25,   '2026-10-01 05:30:00+08',    '2026-10-01 05:30:00+08'),
  ('TR-002', 'tare',  15000,      '2026-10-01 06:00:00+00',    '2026-10-01 06:00:00+00'),
  ('TR-003', 'gross', 123456.789, '2026-10-01 06:30:00+08',    '2026-10-01 06:30:00+08');

-- station_heartbeat stays EMPTY in the base seed (production: 0 rows).

INSERT INTO error_log (error_id, source, level, message, context, created_at) VALUES
  ('00000000-0000-4000-8000-00000000e001', 'station',  'error', 'plain message',
     NULL, '2026-09-30 10:00:00+08'),
  ('00000000-0000-4000-8000-00000000e002', 'backend',  'warn',
     E'quotes '' " \\ backslash\ttab\nnewline\r\nCRLF; unicode: åäö 日本語 😀 ünï; semicolon; -- comment; /* x */',
     '{"k": "v with \"quotes\" and \\ backslash", "n": [1, 2.50, null], "u": "日本語 😀", "nl": "a\nb", "nested": {"x": true}}',
     '2026-09-30 11:30:15.654321+08'),
  ('00000000-0000-4000-8000-00000000e003', 'frontend', 'error', '', '[]', '2026-09-30 12:00:00+00'),
  ('00000000-0000-4000-8000-00000000e004', 'frontend', 'error', '{"looks": "like json"}', '{}', '2026-10-01 00:00:00.001+00');

-- Truncation (not rounding) of microseconds to milliseconds: .999999 must become .999.
INSERT INTO trips (trip_id, date, status, no_tiket, no_lambung, jetty_destination, coal_quality, cuaca_mmi, tare_site_kg,
                   cp1_timestamp, cp2_timestamp, cp3_timestamp, netto_site_kg, netto_jetty_kg)
VALUES ('00000000-0000-4000-8000-00000000f0f0', '2026-09-29', 'completed', 2003, 'TR-MS', 'hasnur', 'clean', 'cerah', 14999,
        '2026-09-29 12:00:00.999999+00', '2026-09-29 12:00:01.0005+00', '2026-09-29 23:59:59.9996+00', 1, 2);
