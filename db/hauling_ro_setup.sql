-- ============================================================
-- PT Merge Mining Industri — hauling_tracker mirror: read-only Postgres role
--
-- Creates (or refreshes) the role `hauling_ro`, which the ClickHouse sync
-- (scripts/hauling_sync.sh, named collection pg_hauling) uses to copy five
-- tables out of Calvin's live hauling_tracker database into ClickHouse.
--
-- USAGE  (run as the `postgres` superuser; safe to run any number of times)
--
--   cd /opt/purchasing_data
--   PW='...at least 16 characters, no spaces or quotes...'   # = HAULING_RO_PASSWORD
--   { printf '\\set ro_password %s\n' "$PW"; cat db/hauling_ro_setup.sql; } \
--     | docker exec -i mmi-postgres psql -U postgres -X
--
-- Optional: `psql ... -v dbname=<db>` to target another database (default
-- `hauling_tracker`), e.g. a local stand-in for testing. The script switches
-- database itself with \connect. The password arrives as the psql variable
-- `ro_password`, is never written in this file and is never echoed. Re-running
-- with a new value rotates it. Exit status is non-zero if the password is
-- missing/short, the database does not exist, or a hard verification check fails.
--
-- WHAT IT CHANGES (catalog entries only; no table is read, rewritten or locked
-- beyond the instant a GRANT takes; lock_timeout makes it give up, not queue)
--   * role hauling_ro: created if missing; LOGIN, NOSUPERUSER, NOCREATEDB,
--     NOCREATEROLE, NOREPLICATION, CONNECTION LIMIT 20, password set.
--   * role settings (apply to hauling_ro's sessions only): timezone=UTC,
--     datestyle='ISO, YMD', default_transaction_read_only=on, statement_timeout=120s.
--     ClickHouse's postgresql() reader drops the UTC offset of timestamptz text,
--     so the role must always see UTC (the same trick as procurement_ro).
--   * GRANT CONNECT ON DATABASE, GRANT USAGE ON SCHEMA public, and
--     GRANT SELECT on exactly these tables of schema public (those that exist):
--         trips, barge_loadings, scale_readings_pending,
--         station_heartbeat, error_log
--     A missing table is reported (WARNING + verification row), never an error.
--   * Housekeeping on hauling_ro ITSELF only: any privilege it holds directly on
--     some other table (left over from manual experiments) is revoked, so the
--     end state is "exactly these five" every time.
--
-- WHAT IT NEVER TOUCHES
--   Any other role (attributes, memberships, passwords), any object's owner,
--   ALTER DEFAULT PRIVILEGES, grants to PUBLIC, other roles' grants, pg_hba.conf,
--   ALTER SYSTEM, table data, table structure, other databases, and the tables
--   sessions, users, audit_log, schema_migrations (hauling_ro gets nothing on them).
--
-- ROLLBACK  (run as postgres; role and grants are all this file ever creates)
--
--   \c hauling_tracker
--   REVOKE SELECT ON TABLE public.trips, public.barge_loadings, public.scale_readings_pending,
--                          public.station_heartbeat, public.error_log FROM hauling_ro;
--   REVOKE USAGE ON SCHEMA public FROM hauling_ro;
--   REVOKE CONNECT ON DATABASE hauling_tracker FROM hauling_ro;
--   DROP ROLE hauling_ro;      -- also drops its per-role settings; fails if it still owns/has
--                              -- privileges on anything, which is the point (nothing should remain)
--
--   (If a table was missing when the script ran, drop its name from the REVOKE list.
--   Terminate hauling_ro's sessions first if the sync is running:
--   SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE usename = 'hauling_ro';)
--
-- PHASE 2 (audit_log, users without the password hash, station_request_log):
--   see the clearly marked EXTENSION POINT below. Nothing there is active.
--
-- Written for PostgreSQL 14 (local dev) and 16 (production). No 15+-only syntax.
-- ============================================================

\set ON_ERROR_STOP on
\set QUIET on
SET client_min_messages = warning;
-- The ALTER ROLE … PASSWORD statement would otherwise land in the server log if
-- the server logs statements, durations or failing statements. (Session-level:
-- repeated after \connect, which opens a new session.)
SET log_statement = 'none';
SET log_min_error_statement = panic;
SET log_min_duration_statement = -1;
SET lock_timeout = '5s';

-- ── Configuration: the ONLY place the table lists live ───────────────────────
-- tables:        SELECT is granted on each of these (those that exist).
-- forbidden:     hauling_ro must NOT be able to read these (hard verification check).
-- colgrant_tables: tables where hauling_ro may hold COLUMN-level grants (phase 2:
--                add 'users' here when you enable the users block below); the
--                housekeeping step leaves column grants on these alone.
\set tables          '{trips,barge_loadings,scale_readings_pending,station_heartbeat,error_log}'
\set forbidden       '{sessions,users,audit_log,schema_migrations}'
\set colgrant_tables '{}'

\if :{?dbname}
\else
  \set dbname hauling_tracker
\endif

-- ── Require a password of at least 16 characters ─────────────────────────────
\if :{?ro_password}
\else
  \echo 'ERROR: missing ro_password (printf ''\\set ro_password %s\n'' "$PW" before the script)'
  DO $$ BEGIN RAISE EXCEPTION 'ro_password not set'; END $$;
\endif
SELECT length(:'ro_password') >= 16 AS password_ok \gset
\if :password_ok
\else
  DO $$ BEGIN RAISE EXCEPTION 'ro_password must be at least 16 characters'; END $$;
\endif

-- ── The target database must exist (fail before creating anything) ───────────
SELECT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'dbname') AS db_exists \gset
\if :db_exists
\else
  \echo 'ERROR: database does not exist (check -v dbname=...)'
  DO $$ BEGIN RAISE EXCEPTION 'target database not found'; END $$;
\endif

-- ── Role (cluster-wide) ──────────────────────────────────────────────────────
-- CREATE ROLE defaults to NOLOGIN; LOGIN and the password arrive together in
-- the ALTER below, so the role is never loginable without a password.
SELECT 'CREATE ROLE hauling_ro NOLOGIN'
 WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'hauling_ro') \gexec

ALTER ROLE hauling_ro LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION
      -- ClickHouse keeps up to 16 pooled connections per named collection
      -- (postgresql_connection_pool_size); same limit as procurement_ro.
      CONNECTION LIMIT 20 PASSWORD :'ro_password';

ALTER ROLE hauling_ro SET timezone = 'UTC';
ALTER ROLE hauling_ro SET datestyle = 'ISO, YMD';
ALTER ROLE hauling_ro SET default_transaction_read_only = on;
ALTER ROLE hauling_ro SET statement_timeout = '120s';

-- ── Inside the target database ───────────────────────────────────────────────
\connect :"dbname"
\set QUIET on
SET client_min_messages = warning;
SET log_statement = 'none';
SET log_min_error_statement = panic;
SET log_min_duration_statement = -1;
SET lock_timeout = '5s';

-- Plain GRANT: PUBLIC's default CONNECT is left as it is (not revoked).
SELECT format('GRANT CONNECT ON DATABASE %I TO hauling_ro', current_database()) \gexec
GRANT USAGE ON SCHEMA public TO hauling_ro;

-- Housekeeping: privileges hauling_ro holds DIRECTLY on any table/view outside
-- the list (and, unless listed in colgrant_tables, column-level ones).
SELECT format('REVOKE ALL ON TABLE %I.%I FROM hauling_ro', n.nspname, c.relname)
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE c.relkind IN ('r', 'p', 'v', 'm', 'f')
   AND NOT (n.nspname = 'public' AND c.relname = ANY (:'tables'::text[]))
   AND EXISTS (SELECT 1 FROM aclexplode(c.relacl) a WHERE a.grantee = 'hauling_ro'::regrole::oid) \gexec

SELECT format('REVOKE ALL (%I) ON TABLE %I.%I FROM hauling_ro', a.attname, n.nspname, c.relname)
  FROM pg_attribute a
  JOIN pg_class c ON c.oid = a.attrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE a.attnum > 0 AND NOT a.attisdropped
   AND c.relkind IN ('r', 'p', 'v', 'm', 'f')
   AND NOT (n.nspname = 'public' AND c.relname = ANY (:'tables'::text[]))
   AND NOT (n.nspname = 'public' AND c.relname = ANY (:'colgrant_tables'::text[]))
   AND EXISTS (SELECT 1 FROM aclexplode(a.attacl) x WHERE x.grantee = 'hauling_ro'::regrole::oid) \gexec

-- The grants. Only tables that exist; the loop is driven by :tables above.
SELECT format('GRANT SELECT ON TABLE public.%I TO hauling_ro', t)
  FROM unnest(:'tables'::text[]) AS t
 WHERE to_regclass(format('public.%I', t)) IS NOT NULL \gexec

-- Tell the operator which of the listed tables are missing (a different hauling_tracker version?).
SELECT format('DO $w$ BEGIN RAISE WARNING %L; END $w$',
              'hauling_ro setup: table public.' || t || ' does not exist in ' || current_database() || '; nothing granted on it')
  FROM unnest(:'tables'::text[]) AS t
 WHERE to_regclass(format('public.%I', t)) IS NULL \gexec

-- ============================================================================
-- EXTENSION POINT — PHASE 2 (COMMENTED OUT ON PURPOSE)
--
-- audit_log, users and station_request_log have not been seen yet, so no column
-- names are guessed here. To enable one of them, edit this file:
--   a. audit_log / station_request_log (whole table): add the name to :tables
--      (top of file) and remove it from :forbidden.
--   b. users (column-level, WITHOUT the password hash): add 'users' to
--      :colgrant_tables, remove it from :forbidden, and uncomment/complete the
--      block below with the real column names (run `\d users` on the server first;
--      never grant the whole table).
--   c. Re-run the script, then add the sync entry, the ClickHouse schema entry and
--      the --verify entry (see the runbook).
--
--   -- GRANT SELECT (<col1>, <col2>, ...) ON TABLE public.users TO hauling_ro;   -- NOT the hash column
--   -- or derive the list by excluding the hash column by name (<hash_column> = real name):
--   -- SELECT format('GRANT SELECT (%s) ON TABLE public.users TO hauling_ro',
--   --               string_agg(quote_ident(attname), ', ' ORDER BY attnum))
--   --   FROM pg_attribute
--   --  WHERE attrelid = 'public.users'::regclass AND attnum > 0 AND NOT attisdropped
--   --    AND attname <> '<hash_column>' \gexec
--   -- A column added to users later is NOT visible to hauling_ro until this file is re-run.
-- ============================================================================

-- ── Verification ─────────────────────────────────────────────────────────────
-- status: ok | FAIL (hard; makes the script exit non-zero) | WARN (informational)
CREATE TEMP TABLE hauling_ro_checks (n serial, check_name text, expected text, actual text, status text);

-- Helper facts, computed once.
SELECT :'tables'::text[] AS want_tables,
       :'forbidden'::text[] AS forbidden_tables,
       ARRAY(SELECT t FROM unnest(:'tables'::text[]) t WHERE to_regclass(format('public.%I', t)) IS NOT NULL ORDER BY t) AS want_present,
       ARRAY(SELECT t FROM unnest(:'tables'::text[]) t WHERE to_regclass(format('public.%I', t)) IS NULL ORDER BY t) AS want_missing,
       ARRAY(SELECT n.nspname || '.' || c.relname
               FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
              WHERE c.relkind IN ('r', 'p', 'v', 'm', 'f')
                AND n.nspname NOT IN ('pg_catalog', 'information_schema') AND n.nspname !~ '^pg_toast'
                AND (has_table_privilege('hauling_ro', c.oid, 'SELECT')
                     OR has_any_column_privilege('hauling_ro', c.oid, 'SELECT'))
              ORDER BY 1) AS readable \gset v_

INSERT INTO hauling_ro_checks (check_name, expected, actual, status)
SELECT 'role exists', 'true', EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'hauling_ro')::text, NULL;
INSERT INTO hauling_ro_checks (check_name, expected, actual, status)
SELECT 'can login', 'true', rolcanlogin::text, NULL FROM pg_roles WHERE rolname = 'hauling_ro';
INSERT INTO hauling_ro_checks (check_name, expected, actual, status)
SELECT 'not superuser/createdb/createrole/replication/bypassrls', 'false/false/false/false/false',
       concat_ws('/', rolsuper::text, rolcreatedb::text, rolcreaterole::text, rolreplication::text, rolbypassrls::text), NULL
  FROM pg_roles WHERE rolname = 'hauling_ro';
INSERT INTO hauling_ro_checks (check_name, expected, actual, status)
SELECT 'connection limit', '20', rolconnlimit::text, NULL FROM pg_roles WHERE rolname = 'hauling_ro';
INSERT INTO hauling_ro_checks (check_name, expected, actual, status)
SELECT 'role settings', 'DateStyle=ISO, YMD | default_transaction_read_only=on | statement_timeout=120s | TimeZone=UTC',
       coalesce((SELECT string_agg(s, ' | ' ORDER BY lower(s)) FROM unnest(rolconfig) s), '(none)'), NULL
  FROM pg_roles WHERE rolname = 'hauling_ro';
INSERT INTO hauling_ro_checks (check_name, expected, actual, status)
SELECT 'member of no roles', '(none)',
       coalesce((SELECT string_agg(pg_get_userbyid(roleid), ', ') FROM pg_auth_members WHERE member = r.oid), '(none)'), NULL
  FROM pg_roles r WHERE rolname = 'hauling_ro';
INSERT INTO hauling_ro_checks (check_name, expected, actual, status)
SELECT 'CONNECT on ' || current_database(), 'true', has_database_privilege('hauling_ro', current_database(), 'CONNECT')::text, NULL;
INSERT INTO hauling_ro_checks (check_name, expected, actual, status)
SELECT 'USAGE on schema public', 'true', has_schema_privilege('hauling_ro', 'public', 'USAGE')::text, NULL;
INSERT INTO hauling_ro_checks (check_name, expected, actual, status)
SELECT 'tables present in database', array_to_string(:'v_want_tables'::text[], ','),
       CASE WHEN :'v_want_missing'::text[] = '{}' THEN array_to_string(:'v_want_tables'::text[], ',')
            ELSE 'MISSING: ' || array_to_string(:'v_want_missing'::text[], ',') END,
       CASE WHEN :'v_want_missing'::text[] = '{}' THEN 'ok' ELSE 'WARN' END;
INSERT INTO hauling_ro_checks (check_name, expected, actual, status)
SELECT 'SELECT granted on the existing listed tables', array_to_string(:'v_want_present'::text[], ','),
       coalesce((SELECT string_agg(split_part(x, '.', 2), ',' ORDER BY x) FROM unnest(:'v_readable'::text[]) x
                  WHERE x LIKE 'public.%' AND split_part(x, '.', 2) = ANY (:'v_want_present'::text[])), '(none)'), NULL;
INSERT INTO hauling_ro_checks (check_name, expected, actual, status)
SELECT 'any OTHER readable table (via PUBLIC or other grants)', '(none)',
       coalesce((SELECT string_agg(x, ',' ORDER BY x) FROM unnest(:'v_readable'::text[]) x
                  WHERE NOT (x LIKE 'public.%' AND split_part(x, '.', 2) = ANY (:'v_want_tables'::text[]))), '(none)'),
       NULL;
-- Hard check, per forbidden table that exists: neither table- nor column-level SELECT.
INSERT INTO hauling_ro_checks (check_name, expected, actual, status)
SELECT 'CANNOT select public.' || f, 'false',
       (has_table_privilege('hauling_ro', c.oid, 'SELECT') OR has_any_column_privilege('hauling_ro', c.oid, 'SELECT'))::text, NULL
  FROM unnest(:'v_forbidden_tables'::text[]) f
  JOIN pg_class c ON c.oid = to_regclass(format('public.%I', f));
INSERT INTO hauling_ro_checks (check_name, expected, actual, status)
SELECT 'forbidden tables that exist', '(informational)',
       coalesce((SELECT string_agg(f, ',') FROM unnest(:'v_forbidden_tables'::text[]) f WHERE to_regclass(format('public.%I', f)) IS NOT NULL), '(none exist)'),
       'ok';
INSERT INTO hauling_ro_checks (check_name, expected, actual, status)
SELECT 'row-level security on listed tables', '(none)',
       coalesce((SELECT string_agg(relname, ',') FROM pg_class
                  WHERE relnamespace = 'public'::regnamespace AND relname = ANY (:'v_want_present'::text[]) AND relrowsecurity), '(none)'),
       NULL;
-- On PG14-era databases PUBLIC may hold CREATE on schema public. We never touch PUBLIC grants,
-- so INSERT/UPDATE/DELETE stay impossible (no grant) but CREATE TABLE would depend on
-- default_transaction_read_only alone.
INSERT INTO hauling_ro_checks (check_name, expected, actual, status)
SELECT 'CREATE on schema public', 'false', has_schema_privilege('hauling_ro', 'public', 'CREATE')::text,
       CASE WHEN has_schema_privilege('hauling_ro', 'public', 'CREATE') THEN 'WARN' ELSE 'ok' END;

-- Status for rows that did not set one: ok when actual = expected.
-- The 'any OTHER readable' and 'row-level security' rows are WARN-only.
UPDATE hauling_ro_checks
   SET status = CASE
         WHEN check_name IN ('any OTHER readable table (via PUBLIC or other grants)', 'row-level security on listed tables')
           THEN CASE WHEN actual = expected THEN 'ok' ELSE 'WARN' END
         WHEN actual = expected THEN 'ok' ELSE 'FAIL' END
 WHERE status IS NULL;

\unset QUIET
\echo
\echo '== hauling_ro setup: verification =='
SELECT check_name, expected, actual, status FROM hauling_ro_checks ORDER BY n;
\set QUIET on
SELECT count(*) FILTER (WHERE status = 'FAIL') > 0 AS has_fail,
       count(*) FILTER (WHERE status = 'WARN') AS warnings FROM hauling_ro_checks \gset
\if :has_fail
  \echo 'hauling_ro setup: VERIFICATION FAILED (see FAIL rows above)'
  DO $$ BEGIN RAISE EXCEPTION 'hauling_ro verification failed'; END $$;
\else
  \echo hauling_ro setup: all hard checks passed, warnings = :warnings
\endif
