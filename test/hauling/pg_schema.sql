-- Local stand-in for the five phase-1 tables of hauling_tracker (Calvin's live system),
-- reconstructed from `\d` output pasted on 2026-10-01. Test-only; never run against
-- production. `sessions` is a MINIMAL stand-in (the real table has more columns we
-- have not seen) that exists only so trips.session_id keeps its foreign key.
--
--   createdb hauling_dev && psql -v ON_ERROR_STOP=1 -d hauling_dev -f test/hauling/pg_schema.sql

CREATE TYPE trip_status_enum        AS ENUM ('pending', 'in_transit', 'arrived_jetty', 'completed');
CREATE TYPE jetty_destination_enum  AS ENUM ('hasnur', 'talenta');
CREATE TYPE coal_quality_enum       AS ENUM ('raw', 'clean', 'premium', 'standard');
CREATE TYPE session_status_enum     AS ENUM ('active', 'ended');

CREATE TABLE sessions (
    session_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    status     session_status_enum NOT NULL DEFAULT 'active'
);

CREATE TABLE trips (
    trip_id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    date              date NOT NULL,
    status            trip_status_enum NOT NULL DEFAULT 'pending',
    no_tiket          integer NOT NULL,
    no_lambung        text NOT NULL,
    jetty_destination jetty_destination_enum NOT NULL,
    coal_quality      coal_quality_enum NOT NULL,
    cuaca_mmi         text NOT NULL,
    tare_site_kg      integer NOT NULL,
    cp1_timestamp     timestamptz,
    gross_site_kg     integer,
    netto_site_kg     integer,
    cp2_timestamp     timestamptz,
    gross_jetty_kg    integer,
    netto_jetty_kg    integer,
    compare_gross_kg  integer,
    deviasi_kg        integer,
    cp3_timestamp     timestamptz,
    adjustment_kg     integer NOT NULL DEFAULT 0,
    is_locked         boolean DEFAULT false,
    session_id        uuid REFERENCES sessions (session_id),
    tare_jetty_kg     integer,
    stockpile_code    text NOT NULL DEFAULT '',
    tare_source       text NOT NULL DEFAULT 'manual',
    gross_source      text NOT NULL DEFAULT 'manual',
    cp1_event_id      text,
    cp2_event_id      text,
    CONSTRAINT trips_gross_source_check CHECK (gross_source = ANY (ARRAY['manual', 'scale'])),
    CONSTRAINT trips_tare_source_check  CHECK (tare_source  = ANY (ARRAY['manual', 'scale']))
);
CREATE UNIQUE INDEX idx_trips_cp1_event_id ON trips (cp1_event_id) WHERE cp1_event_id IS NOT NULL;
CREATE INDEX idx_trips_cp2_event_id ON trips (cp2_event_id) WHERE cp2_event_id IS NOT NULL;
CREATE INDEX idx_trips_date    ON trips (date);
CREATE INDEX idx_trips_lambung ON trips (no_lambung);
CREATE INDEX idx_trips_status  ON trips (status);

CREATE TABLE barge_loadings (
    loading_id     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    jetty          jetty_destination_enum NOT NULL,
    barge_name     text NOT NULL,
    tug_boat_name  text NOT NULL,
    loading_date   date NOT NULL,
    loading_qty_kg bigint NOT NULL CHECK (loading_qty_kg > 0),
    created_at     timestamptz NOT NULL DEFAULT now(),
    stockpile_code text NOT NULL DEFAULT ''
);
CREATE INDEX idx_barge_loadings_jetty_date ON barge_loadings (jetty, loading_date);

CREATE TABLE scale_readings_pending (
    no_lambung   text NOT NULL,
    reading_type text NOT NULL CHECK (reading_type = ANY (ARRAY['tare', 'gross'])),
    weight_kg    numeric NOT NULL,
    measured_at  timestamptz NOT NULL,
    created_at   timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (no_lambung, reading_type)
);

CREATE TABLE station_heartbeat (
    id              bigserial PRIMARY KEY,
    received_at     timestamptz NOT NULL DEFAULT now(),
    station_id      text NOT NULL,
    station_version text,
    pc_time         timestamptz,
    skew_ms         integer,
    scale_connected boolean,
    trucks_on_site  integer,
    sync_pending    integer,
    sync_dead       integer,
    oldest_job_min  integer,
    last_push_ok_at timestamptz,
    uptime_s        integer
);
CREATE INDEX idx_station_heartbeat_station ON station_heartbeat (station_id, received_at DESC);

CREATE TABLE error_log (
    error_id   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    source     text NOT NULL CHECK (source = ANY (ARRAY['station', 'backend', 'frontend'])),
    level      text NOT NULL DEFAULT 'error' CHECK (level = ANY (ARRAY['error', 'warn'])),
    message    text NOT NULL,
    context    jsonb,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_error_log_created ON error_log (created_at DESC);
CREATE INDEX idx_error_log_source  ON error_log (source);
