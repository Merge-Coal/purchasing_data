-- Round 3: the documented gap. Old received_at AND an id lower than the highest one already
-- mirrored (61): an incremental run cannot see it, --full does.
INSERT INTO station_heartbeat (id, station_id, received_at, skew_ms) VALUES (55, 'stn-5', now() - interval '5 days', 3);
