-- ============================================================
-- Minimart: Postgres roles + database bootstrap on the shared mmi-postgres server.
--
-- Run as the `postgres` superuser. Idempotent: safe to run any number of times.
-- It is run (a) BEFORE the data is restored (creates roles + the empty database +
-- default privileges) and (b) AFTER the restore (grants on the tables that now
-- exist; scripts/minimart_migrate.sh does this itself, without passwords).
--
--   export MINIMART_APP_PASSWORD=... MINIMART_RO_PASSWORD=...   # >= 16 chars each
--   { printf '\\set app_password %s\n' "$MINIMART_APP_PASSWORD"
--     printf '\\set ro_password %s\n'  "$MINIMART_RO_PASSWORD"
--     cat db/minimart_setup.sql; } | docker exec -i mmi-postgres psql -U postgres -X -v ON_ERROR_STOP=1
--
-- Passwords must be plain alphanumerics (A-Z a-z 0-9 . _ ~ + / = -), at least 16 characters:
-- psql's \set strips quotes and spaces and mishandles backslashes, so anything else would
-- silently become a different password. `LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32` is fine.
-- (Passwords come in as psql variables from stdin, so they never appear in `ps`,
-- shell history of the container, or this file. Same pattern as
-- db/postgres_setup.sql. The runbook has the exact block.)
--
-- Optional psql variables (-v name=value):
--   dbname        database to create/configure        (default minimart)
--   app_password  rotate/set the app password; if absent and the role already
--                 exists, the password is left unchanged (grants-only run)
--   ro_password   same for the read-only warehouse role
--   app_conn_limit  connection limit for minimart_app (default 50)
--   lc_collate / lc_ctype  create the database with these locales (default: the
--                 server default). Only used when the database does not exist yet.
--                 Example: Alpine postgres images sort in byte (C) order; pass
--                 C (or C.UTF-8) here to keep the old ORDER BY behaviour.
--   db_timezone   ALTER DATABASE ... SET timezone = <value>. Default: do nothing
--                 (leave the server default). Only set it if discovery shows the
--                 app relies on a local session time zone.
--
-- Only touches the roles minimart_owner / minimart_app / minimart_ro and the
-- database named by :dbname. It never connects to, locks or alters any other
-- database, role, pg_hba or system setting of the server (the same cluster
-- hosts procurement and hauling_tracker).
--
-- Roles:
--   minimart_owner  NOLOGIN. Owns the database, every schema and every object.
--   minimart_app    LOGIN. The minimart application. SELECT/INSERT/UPDATE/DELETE on
--                   every table, USAGE/SELECT/UPDATE on every sequence. No DDL, no
--                   TRUNCATE. Future tables created by minimart_owner are covered
--                   by default privileges.
--   minimart_ro     LOGIN. ClickHouse mirror. timezone=UTC, ISO/YMD dates (the
--                   postgresql() table function drops the UTC offset of timestamptz),
--                   read-only default, statement_timeout 120 s, CONNECTION LIMIT 20.
--                   This file grants it CONNECT and USAGE on the schemas ONLY: table
--                   and column-level SELECT is given by db/minimart_ro_grants.sql
--                   (so sensitive columns can be withheld) and there are deliberately
--                   no default privileges for it.
--
-- Written for PostgreSQL 14 (local tests) and 16 (production).
-- ============================================================

\set ON_ERROR_STOP on
\set QUIET on
SET client_min_messages = warning;
-- ALTER ROLE ... PASSWORD must not land in the server log.
SET log_statement = 'none';
SET log_min_duration_statement = -1;
SET log_duration = off;
SET log_min_error_statement = panic;

\if :{?dbname}
\else
  \set dbname minimart
\endif
\if :{?app_conn_limit}
\else
  \set app_conn_limit 50
\endif

-- ── Passwords: validate those given; a missing one is only OK for an existing role ──
SELECT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'minimart_app') AS app_exists,
       EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'minimart_ro')  AS ro_exists \gset

\if :{?app_password}
  SELECT length(:'app_password') >= 16 AS app_pw_ok \gset
  \if :app_pw_ok
  \else
    \echo 'ERROR: app_password must be at least 16 characters'
    DO $$ BEGIN RAISE EXCEPTION 'app_password must be at least 16 characters'; END $$;
  \endif
\else
  \if :app_exists
  \else
    \echo 'ERROR: missing -v app_password=... (role minimart_app does not exist yet)'
    DO $$ BEGIN RAISE EXCEPTION 'app_password not set'; END $$;
  \endif
\endif
\if :{?ro_password}
  SELECT length(:'ro_password') >= 16 AS ro_pw_ok \gset
  \if :ro_pw_ok
  \else
    \echo 'ERROR: ro_password must be at least 16 characters'
    DO $$ BEGIN RAISE EXCEPTION 'ro_password must be at least 16 characters'; END $$;
  \endif
\else
  \if :ro_exists
  \else
    \echo 'ERROR: missing -v ro_password=... (role minimart_ro does not exist yet)'
    DO $$ BEGIN RAISE EXCEPTION 'ro_password not set'; END $$;
  \endif
\endif

-- ── Roles (cluster-wide) ─────────────────────────────────────────────────────
SELECT 'CREATE ROLE minimart_owner NOLOGIN'
 WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'minimart_owner') \gexec
SELECT 'CREATE ROLE minimart_app LOGIN'
 WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'minimart_app') \gexec
SELECT 'CREATE ROLE minimart_ro LOGIN'
 WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'minimart_ro') \gexec

ALTER ROLE minimart_owner NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION;
ALTER ROLE minimart_app   LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION
      CONNECTION LIMIT :app_conn_limit;
ALTER ROLE minimart_ro    LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION
      -- ClickHouse keeps up to 16 pooled connections per named collection.
      CONNECTION LIMIT 20;
\if :{?app_password}
  ALTER ROLE minimart_app PASSWORD :'app_password';
\endif
\if :{?ro_password}
  ALTER ROLE minimart_ro PASSWORD :'ro_password';
\endif

-- ClickHouse's postgresql() reader drops the UTC offset from timestamptz text and
-- reads the wall-clock part, so the warehouse role always gets UTC, ISO output.
-- Read-only by default as a second fence behind the grants.
ALTER ROLE minimart_ro SET timezone = 'UTC';
ALTER ROLE minimart_ro SET datestyle = 'ISO, YMD';
ALTER ROLE minimart_ro SET default_transaction_read_only = on;
ALTER ROLE minimart_ro SET statement_timeout = '120s';

-- ── Database ─────────────────────────────────────────────────────────────────
-- CREATE DATABASE cannot run inside a transaction or DO block, hence \gexec.
\if :{?lc_collate}
  \if :{?lc_ctype}
  \else
    \set lc_ctype :lc_collate
  \endif
  SELECT format('CREATE DATABASE %I OWNER minimart_owner ENCODING %L LC_COLLATE %L LC_CTYPE %L TEMPLATE template0',
                :'dbname', 'UTF8', :'lc_collate', :'lc_ctype')
   WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'dbname') \gexec
\else
  SELECT format('CREATE DATABASE %I OWNER minimart_owner ENCODING %L TEMPLATE template0',
                :'dbname', 'UTF8')
   WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'dbname') \gexec
\endif

ALTER DATABASE :"dbname" OWNER TO minimart_owner;
\if :{?db_timezone}
  ALTER DATABASE :"dbname" SET timezone = :'db_timezone';
\endif
REVOKE ALL ON DATABASE :"dbname" FROM PUBLIC;
GRANT CONNECT, TEMPORARY ON DATABASE :"dbname" TO minimart_app;
GRANT CONNECT ON DATABASE :"dbname" TO minimart_ro;

-- ── Inside the minimart database ─────────────────────────────────────────────
\connect :"dbname"
\set QUIET on
SET client_min_messages = warning;
SET log_statement = 'none';
SET log_min_duration_statement = -1;
SET log_duration = off;

-- `public` first (exists in every database), then every other user schema that
-- exists (after a restore). PG14 gives PUBLIC CREATE on public, PG15+ does not:
-- same end state on both.
ALTER SCHEMA public OWNER TO minimart_owner;
REVOKE ALL ON SCHEMA public FROM PUBLIC;

DO $$
DECLARE s record;
BEGIN
  FOR s IN
    SELECT n.nspname
      FROM pg_namespace n
     WHERE n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'
       AND NOT EXISTS (SELECT 1 FROM pg_depend d
                        WHERE d.classid = 'pg_namespace'::regclass AND d.objid = n.oid AND d.deptype = 'e')
  LOOP
    EXECUTE format('GRANT USAGE ON SCHEMA %I TO minimart_app, minimart_ro', s.nspname);
    -- Everything minimart_owner creates from now on is covered without re-running this file.
    EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE minimart_owner IN SCHEMA %I '
                   'GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO minimart_app', s.nspname);
    EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE minimart_owner IN SCHEMA %I '
                   'GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO minimart_app', s.nspname);
    -- Objects that already exist (second run, after the restore). Tables, views,
    -- materialised views, partitioned and foreign tables are all in ALL TABLES.
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA %I TO minimart_app', s.nspname);
    EXECUTE format('GRANT USAGE, SELECT, UPDATE ON ALL SEQUENCES IN SCHEMA %I TO minimart_app', s.nspname);
  END LOOP;
END $$;
-- minimart_ro: no table privileges and no default privileges here, on purpose.
-- db/minimart_ro_grants.sql grants SELECT (column-level where a table has
-- password/token/secret-like columns). Functions are executable by PUBLIC by default.

-- ── Report: every column below should be as stated in the header ─────────────
\unset QUIET
SELECT current_database()                                          AS database,
       pg_get_userbyid(d.datdba)                                   AS db_owner,
       d.datcollate                                                AS collate,
       (SELECT count(*) FROM pg_tables
         WHERE schemaname NOT IN ('pg_catalog','information_schema'))            AS tables,
       (SELECT count(*) FROM pg_tables
         WHERE schemaname NOT IN ('pg_catalog','information_schema')
           AND tableowner <> 'minimart_owner')                     AS tables_not_owned_by_owner,
       (SELECT count(*) FROM information_schema.tables t
         WHERE t.table_schema NOT IN ('pg_catalog','information_schema')
           AND t.table_type = 'BASE TABLE'
           AND NOT (has_table_privilege('minimart_app', format('%I.%I', t.table_schema, t.table_name), 'SELECT')
                AND has_table_privilege('minimart_app', format('%I.%I', t.table_schema, t.table_name), 'INSERT')
                AND has_table_privilege('minimart_app', format('%I.%I', t.table_schema, t.table_name), 'UPDATE')
                AND has_table_privilege('minimart_app', format('%I.%I', t.table_schema, t.table_name), 'DELETE'))
       )                                                           AS tables_app_cannot_dml,
       (SELECT count(*) FROM information_schema.tables t
         WHERE t.table_schema NOT IN ('pg_catalog','information_schema')
           AND (has_table_privilege('minimart_ro', format('%I.%I', t.table_schema, t.table_name), 'INSERT')
             OR has_table_privilege('minimart_ro', format('%I.%I', t.table_schema, t.table_name), 'UPDATE')
             OR has_table_privilege('minimart_ro', format('%I.%I', t.table_schema, t.table_name), 'DELETE'))
       )                                                           AS tables_ro_can_write
  FROM pg_database d WHERE d.datname = current_database();

SELECT rolname, rolcanlogin AS can_login, rolsuper AS superuser, rolconnlimit AS conn_limit,
       COALESCE(array_to_string(rolconfig, ' | '), '') AS role_settings
  FROM pg_roles WHERE rolname IN ('minimart_owner', 'minimart_app', 'minimart_ro') ORDER BY rolname;
