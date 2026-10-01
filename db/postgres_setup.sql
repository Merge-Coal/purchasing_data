-- ============================================================
-- PT Merge Mining Industri — Procurement: Postgres roles + database bootstrap
--
-- Run as the `postgres` superuser on the shared mmi-postgres server. Safe to
-- run any number of times. Run it TWICE during setup: once before
-- db/postgres_schema.sql (creates roles, database, default privileges) and
-- once after it (grants on the tables that now exist, and the column-level
-- restriction on users.password_hash, which needs the table to exist).
--
--   docker exec -i mmi-postgres psql -U postgres -X \
--     -v app_password="$PG_APP_PASSWORD" -v ro_password="$PG_RO_PASSWORD" \
--     < db/postgres_setup.sql
--
-- Passwords arrive as psql variables and are never written in this file.
-- Re-running with new values rotates them.
--
-- Only touches the roles procurement_owner / procurement_app / procurement_ro
-- and the database named by :dbname (default `procurement`). It never
-- connects to, locks or alters any other database on the server (the same
-- cluster hosts hauling_tracker).
--
-- Roles:
--   procurement_owner  NOLOGIN. Owns the database, the public schema and every
--                      object db/postgres_schema.sql creates. Apply the schema
--                      with `SET ROLE procurement_owner` so later ALTERs work.
--   procurement_app    LOGIN. The app (and migrate_ch_to_pg.js). DML plus
--                      TRUNCATE on every table, USAGE/SELECT/UPDATE (setval) on
--                      every sequence. No DDL.
--   procurement_ro     LOGIN. ClickHouse's warehouse sync. SELECT only, never
--                      the `session` table, never users.password_hash. Its
--                      sessions are read-only and in UTC (see below).
--
-- Written for PostgreSQL 14 (local dev) and 16 (production).
-- ============================================================

\set ON_ERROR_STOP on
\set QUIET on
SET client_min_messages = warning;
-- The ALTER ROLE … PASSWORD statements below would otherwise land in the
-- server log if mmi-postgres logs DDL or failing statements.
SET log_statement = 'none';
SET log_min_error_statement = panic;

\if :{?dbname}
\else
  \set dbname procurement
\endif

-- ── Require both passwords, at least 16 characters ───────────────────────────
\if :{?app_password}
\else
  \echo 'ERROR: missing -v app_password=...'
  DO $$ BEGIN RAISE EXCEPTION 'app_password not set'; END $$;
\endif
\if :{?ro_password}
\else
  \echo 'ERROR: missing -v ro_password=...'
  DO $$ BEGIN RAISE EXCEPTION 'ro_password not set'; END $$;
\endif
SELECT length(:'app_password') >= 16 AND length(:'ro_password') >= 16 AS passwords_ok \gset
\if :passwords_ok
\else
  DO $$ BEGIN RAISE EXCEPTION 'app_password and ro_password must be at least 16 characters'; END $$;
\endif

-- ── Roles (cluster-wide) ─────────────────────────────────────────────────────
SELECT 'CREATE ROLE procurement_owner NOLOGIN'
 WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'procurement_owner') \gexec
SELECT 'CREATE ROLE procurement_app LOGIN'
 WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'procurement_app') \gexec
SELECT 'CREATE ROLE procurement_ro LOGIN'
 WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'procurement_ro') \gexec

ALTER ROLE procurement_owner NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION;
ALTER ROLE procurement_app   LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION
      CONNECTION LIMIT 30 PASSWORD :'app_password';
ALTER ROLE procurement_ro    LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION
      CONNECTION LIMIT 5  PASSWORD :'ro_password';

-- ClickHouse's postgresql() reader drops the UTC offset from timestamptz text
-- and reads the wall-clock part, so the warehouse role always gets UTC, ISO
-- output. db/ch_sync.sql relies on this. Read-only by default as a second
-- fence behind the SELECT-only grants.
ALTER ROLE procurement_ro SET timezone = 'UTC';
ALTER ROLE procurement_ro SET datestyle = 'ISO, YMD';
ALTER ROLE procurement_ro SET default_transaction_read_only = on;
ALTER ROLE procurement_ro SET statement_timeout = '120s';

-- ── Database ─────────────────────────────────────────────────────────────────
-- CREATE DATABASE cannot run inside a transaction or DO block, hence \gexec.
SELECT format('CREATE DATABASE %I OWNER procurement_owner ENCODING %L TEMPLATE template0',
              :'dbname', 'UTF8')
 WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'dbname') \gexec

ALTER DATABASE :"dbname" OWNER TO procurement_owner;
REVOKE ALL ON DATABASE :"dbname" FROM PUBLIC;
GRANT CONNECT, TEMPORARY ON DATABASE :"dbname" TO procurement_app;
GRANT CONNECT ON DATABASE :"dbname" TO procurement_ro;

-- ── Inside the procurement database ──────────────────────────────────────────
\connect :"dbname"
\set QUIET on
SET client_min_messages = warning;

-- PG14 gives PUBLIC CREATE on `public`; PG15+ makes pg_database_owner own it.
-- Same end state on both: procurement_owner owns it, nobody else may create.
ALTER SCHEMA public OWNER TO procurement_owner;
REVOKE ALL ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO procurement_app, procurement_ro;

-- Everything procurement_owner creates from now on (the schema file, later
-- migrations) is covered without re-running this file.
ALTER DEFAULT PRIVILEGES FOR ROLE procurement_owner IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE ON TABLES TO procurement_app;
ALTER DEFAULT PRIVILEGES FOR ROLE procurement_owner IN SCHEMA public
  GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO procurement_app;
ALTER DEFAULT PRIVILEGES FOR ROLE procurement_owner IN SCHEMA public
  GRANT SELECT ON TABLES TO procurement_ro;
-- Functions are executable by PUBLIC by default (the updated_at trigger
-- function needs nothing further).

-- Objects that already exist (second run, after the schema).
GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE ON ALL TABLES IN SCHEMA public TO procurement_app;
GRANT USAGE, SELECT, UPDATE ON ALL SEQUENCES IN SCHEMA public TO procurement_app;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO procurement_ro;

-- The warehouse role must not read sessions or password hashes. Default
-- privileges just granted SELECT on these, so take it back explicitly.
-- Re-run this file after adding a column to users, or the warehouse role
-- will not see the new column.
DO $$
DECLARE cols text;
BEGIN
  IF to_regclass('public.session') IS NOT NULL THEN
    REVOKE ALL ON TABLE public.session FROM procurement_ro;
  END IF;
  IF to_regclass('public.users') IS NOT NULL THEN
    REVOKE SELECT ON TABLE public.users FROM procurement_ro;
    SELECT string_agg(quote_ident(attname), ', ' ORDER BY attnum) INTO cols
      FROM pg_attribute
     WHERE attrelid = 'public.users'::regclass AND attnum > 0
       AND NOT attisdropped AND attname <> 'password_hash';
    EXECUTE format('GRANT SELECT (%s) ON TABLE public.users TO procurement_ro', cols);
  END IF;
END $$;

-- ── Report ───────────────────────────────────────────────────────────────────
\unset QUIET
SELECT current_database() AS database,
       pg_get_userbyid(d.datdba) AS db_owner,
       (SELECT count(*) FROM pg_tables WHERE schemaname = 'public') AS tables_in_public,
       (SELECT count(*) FROM pg_tables WHERE schemaname = 'public'
                                         AND tableowner <> 'procurement_owner') AS tables_not_owned_by_owner
  FROM pg_database d WHERE d.datname = current_database();
