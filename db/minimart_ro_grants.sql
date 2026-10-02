-- ============================================================
-- PT Merge Mining Industri — minimart mirror: grants for the read-only role
--
-- Gives the role `minimart_ro` (created elsewhere, by db/minimart_setup.sql; this
-- file never creates it) read access to the tables of the `minimart` database
-- that the ClickHouse sync (scripts/minimart_sync.sh) copies, WITHOUT the
-- columns that look like secrets (password hashes, tokens, OTPs, PINs, ...).
-- The minimart schema is not known in advance, so everything is derived from
-- the catalog every time the file runs.
--
-- USAGE  (run as a Postgres superuser; safe to run any number of times)
--
--   cd /opt/purchasing_data
--   docker exec -i mmi-postgres psql -U postgres -X < db/minimart_ro_grants.sql
--   # or, with a local server:   psql -U postgres -X -f db/minimart_ro_grants.sql
--
-- Optional psql variables (all before the file: `psql ... -v name=value`):
--   dbname      database to work on                      (default: minimart)
--   ro_role     role that receives the grants            (default: minimart_ro)
--               Must be a plain lower-case identifier ([a-z_][a-z0-9_]*, not pg_*);
--               exists so tests can use another role. The file \connect's into
--               dbname itself and stops with an error, before changing anything,
--               if the database or the role does not exist.
--   allow_cols  comma-separated `table.column` list: treated as NOT sensitive even
--               if the name rule matches. Opt-in, after a human has looked at the
--               column. e.g.  -v allow_cols=customers.reset_otp,orders.pin_code
--   deny_cols   comma-separated `table.column` list: additionally treated as
--               sensitive (the name rule cannot know that e.g. `phone` is private).
--               If a column is in both lists, deny_cols wins.
--               Both lists are of schema `public` tables, compared case-sensitively and
--               verbatim against the real names (no trimming: write `a.x,b.y`, no
--               spaces around commas; a name that itself contains a space is passed
--               as is, e.g. -v 'deny_cols=Legacy Notes.Note Text'). A name that
--               contains a comma, or a table name that contains a dot next to a
--               column name that makes `a.b.c` ambiguous, is not supported (the
--               match is on the string `table.column`). Entries that match nothing
--               are reported as WARNING.
--   Overrides are NOT remembered: pass them on every run; a run without them goes
--   back to the plain rule (and revokes what the override had opened).
--
-- WHAT IT CHANGES (catalog entries only; no table is read, rewritten or locked beyond
-- the instant a GRANT takes; lock_timeout makes it give up instead of queueing)
--   Scope = ordinary and partitioned tables of schema public that are not partition
--   children. Views, materialized views, foreign tables, other schemas, sequences
--   and functions are never granted (the first three kinds and other schemas are
--   listed as WARNINGs / verification rows so a human can decide).
--   * GRANT CONNECT ON DATABASE and GRANT USAGE ON SCHEMA public to the role
--     (plain grants; PUBLIC's own CONNECT is not revoked).
--   * table WITHOUT a sensitive column  -> table-level GRANT SELECT.
--   * table WITH a sensitive column     -> no table-level SELECT for the role (it is
--     revoked if present), but GRANT SELECT (<every non-sensitive column>); any
--     column-level SELECT the role holds on a now-sensitive column is revoked.
--   * table whose columns are ALL sensitive -> nothing is granted.
--   * Housekeeping on the role ITSELF only: every privilege it holds directly on
--     anything outside the scope above (tables/views/sequences in any non-system
--     schema, functions/procedures) is revoked, and every non-SELECT privilege
--     (INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, ...) on an in-scope
--     table or column is revoked. The role never gets a write privilege.
--   The statements are ordered revokes first, grants last, so a run that is
--   interrupted never leaves the role with more than it should have.
--   Convergent: re-running after a table/column was created, dropped or renamed
--   brings the grants to the state the rule describes; stale column grants on a
--   column that is sensitive now are revoked.
--
-- WHAT IT NEVER TOUCHES
--   Any other role (attributes, memberships, passwords), any owner, PUBLIC's grants,
--   ALTER DEFAULT PRIVILEGES (none are set, none are changed), table data, table
--   structure, pg_hba.conf, other databases, and the role itself (only its grants).
--
-- SENSITIVE COLUMN RULE  (single definition; the same two regexes are the constants
-- deny_substr / deny_word in scripts/minimart_gen_schema.sh, which must stay identical)
--   n = lower(regexp_replace(column_name, '([a-z0-9])([A-Z])', '\1_\2', 'g'))
--   (so camelCase `apiKey` becomes `api_key`), then the column is sensitive if
--   n ~ deny_substr  OR  n ~ deny_word. Substring words (password, token, hash, ...) match
--   anywhere, so `hashtag` and `tokenizer` are accepted false positives; short words
--   (otp, pin, pwd, salt, cvv, cvc, card) only match as a whole word, so
--   `shipping_address` or `spinach` are not sensitive but `pin_code`, `user_pin` and
--   `card_type` are. A false positive costs a column in the mirror (fix with
--   allow_cols), a false negative would leak a secret, hence the bias.
--
-- ROLLBACK  (run as postgres; this file only ever adds grants)
--
--   \c minimart
--   REVOKE ALL ON ALL TABLES IN SCHEMA public FROM minimart_ro;  -- also drops its column grants
--   REVOKE USAGE ON SCHEMA public FROM minimart_ro;
--   REVOKE CONNECT ON DATABASE minimart FROM minimart_ro;
--   -- the role itself is dropped by whoever created it (db/minimart_setup.sql).
--
-- SCHEMA DRIFT  -- READ THIS
--   No default privileges are set for the role (deliberately), so a NEW TABLE is not
--   readable until this file is re-run: the safe default. Likewise a new column on a
--   table that has column-level grants stays invisible until the re-run. BUT a table that
--   has a table-level grant (no sensitive column when last run) exposes a column added
--   later immediately, including a sensitive-looking one, until this file is re-run.
--   Therefore re-run this file after every minimart schema change (new table, new or
--   renamed column); scripts/minimart_sync.sh --verify should be run right after.
--
-- EXIT STATUS non-zero if: the database or role does not exist or ro_role is not a plain
-- identifier, the role is a superuser, or a hard verification check fails (a sensitive
-- column is still readable by the role -- e.g. through a PUBLIC grant or a role
-- membership --, the role holds a write privilege, CONNECT/USAGE is missing, an in-scope
-- table is not readable via its allowed columns).
--
-- Written for PostgreSQL 14 (local dev) and 16 (production). No 15+-only syntax.
-- ============================================================

\set ON_ERROR_STOP on
\set QUIET on
SET client_min_messages = warning;
SET log_statement = 'none';
SET lock_timeout = '5s';

-- ── The sensitive column rule: ONE place. Keep identical to the constants of the same
-- ── names in scripts/minimart_gen_schema.sh. (Always set here, not overridable by -v.)
\set deny_substr '(password|passwd|passphrase|secret|token|hash|api[^a-z0-9]?key|credential|private[^a-z0-9]?key|card[^a-z0-9]?(no|num)|pincode)'
\set deny_word   '(^|[^a-z0-9])(otp|pin|pwd|salt|cvv|cvc|card)([^a-z0-9]|$)'

-- ── Parameters ───────────────────────────────────────────────────────────────
\if :{?dbname}
\else
  \set dbname minimart
\endif
\if :{?ro_role}
\else
  \set ro_role minimart_ro
\endif
\if :{?allow_cols}
\else
  \set allow_cols ''
\endif
\if :{?deny_cols}
\else
  \set deny_cols ''
\endif

SELECT :'ro_role' ~ '^[a-z_][a-z0-9_]{0,62}$' AND :'ro_role' !~ '^pg_' AS ro_role_ok \gset
\if :ro_role_ok
\else
  \echo 'ERROR: ro_role must be a plain lower-case identifier ([a-z_][a-z0-9_]*, not pg_*)'
  DO $$ BEGIN RAISE EXCEPTION 'invalid ro_role'; END $$;
\endif

SELECT rolsuper AS am_super FROM pg_roles WHERE rolname = current_user \gset
\if :am_super
\else
  \echo 'ERROR: run this file as a Postgres superuser (psql -U postgres)'
  DO $$ BEGIN RAISE EXCEPTION 'not a superuser'; END $$;
\endif

-- ── Database and role must exist; nothing is created here ────────────────────
SELECT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'dbname') AS db_exists \gset
\if :db_exists
\else
  \echo 'ERROR: database does not exist (check -v dbname=...)'
  DO $$ BEGIN RAISE EXCEPTION 'target database not found'; END $$;
\endif

SELECT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'ro_role') AS role_exists \gset
\if :role_exists
\else
  \echo 'ERROR: role does not exist; it is created by db/minimart_setup.sql, not by this file (check -v ro_role=...)'
  DO $$ BEGIN RAISE EXCEPTION 'read-only role not found'; END $$;
\endif

SELECT rolsuper AS role_is_super FROM pg_roles WHERE rolname = :'ro_role' \gset
\if :role_is_super
  \echo 'ERROR: the read-only role is a superuser; refusing to continue'
  DO $$ BEGIN RAISE EXCEPTION 'read-only role is a superuser'; END $$;
\endif

SELECT oid AS ro_oid FROM pg_roles WHERE rolname = :'ro_role' \gset

-- ── Inside the target database ───────────────────────────────────────────────
\connect :"dbname"
\set QUIET on
SET client_min_messages = warning;
SET log_statement = 'none';
SET lock_timeout = '5s';

-- ── Catalog snapshot: tables in scope and their columns, with the rule applied ──
CREATE TEMP TABLE mm_tables AS
SELECT c.oid AS relid, c.relname::text AS relname
  FROM pg_class c JOIN pg_namespace ns ON ns.oid = c.relnamespace
 WHERE ns.nspname = 'public' AND c.relkind IN ('r', 'p') AND NOT c.relispartition;

CREATE TEMP TABLE mm_cols AS
WITH b AS (
  SELECT t.relid, t.relname, a.attnum::int AS attnum, a.attname::text AS attname,
         lower(regexp_replace(a.attname::text, '([a-z0-9])([A-Z])', '\1_\2', 'g')) AS n,
         t.relname || '.' || a.attname::text AS fq
    FROM mm_tables t JOIN pg_attribute a ON a.attrelid = t.relid
   WHERE a.attnum > 0 AND NOT a.attisdropped
), r AS (
  SELECT b.*,
         (b.n ~ :'deny_substr' OR b.n ~ :'deny_word')        AS rule_hit,
         b.fq = ANY (string_to_array(:'allow_cols', ','))    AS allowed,
         b.fq = ANY (string_to_array(:'deny_cols', ','))     AS denied
    FROM b
)
SELECT r.*,
       (r.denied OR (r.rule_hit AND NOT r.allowed)) AS sensitive,
       CASE WHEN r.denied THEN 'deny_cols'
            WHEN r.rule_hit AND NOT r.allowed THEN 'name rule' END AS reason
  FROM r;

-- Objects outside the scope, for reporting.
CREATE TEMP TABLE mm_outside AS
SELECT c.oid AS relid, n.nspname::text AS nspname, c.relname::text AS relname, c.relkind::text AS relkind, c.relispartition
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE c.relkind IN ('r', 'p', 'v', 'm', 'f')
   AND n.nspname NOT IN ('pg_catalog', 'information_schema') AND n.nspname !~ '^pg_(toast|temp)'
   AND c.oid NOT IN (SELECT relid FROM mm_tables);

-- ── Reports before changing anything ─────────────────────────────────────────
SELECT format('DO $w$ BEGIN RAISE WARNING %L; END $w$',
              'minimart_ro grants: ' || w.what || ' (not granted): ' || w.names)
  FROM (
    SELECT 'views / materialized views / foreign tables' AS what,
           string_agg(nspname || '.' || relname, ', ' ORDER BY nspname, relname) AS names
      FROM mm_outside WHERE relkind IN ('v', 'm', 'f')
    UNION ALL
    SELECT 'tables in other schemas',
           string_agg(nspname || '.' || relname, ', ' ORDER BY nspname, relname)
      FROM mm_outside WHERE relkind IN ('r', 'p') AND nspname <> 'public'
    UNION ALL
    SELECT 'partition children (read through their parent)',
           string_agg(nspname || '.' || relname, ', ' ORDER BY nspname, relname)
      FROM mm_outside WHERE relkind IN ('r', 'p') AND nspname = 'public' AND relispartition
  ) w
 WHERE w.names IS NOT NULL \gexec

SELECT format('DO $w$ BEGIN RAISE WARNING %L; END $w$',
              'minimart_ro grants: ' || x.which || ' entry ' || quote_literal(x.e) || ' matches no column of a public table')
  FROM (SELECT 'allow_cols' AS which, e FROM unnest(string_to_array(:'allow_cols', ',')) e
        UNION ALL
        SELECT 'deny_cols', e FROM unnest(string_to_array(:'deny_cols', ',')) e) x
 WHERE x.e <> '' AND NOT EXISTS (SELECT 1 FROM mm_cols m WHERE m.fq = x.e) \gexec

-- ── 1. Revokes (narrowing first) ─────────────────────────────────────────────
-- Table-level SELECT on a table with a sensitive column (this also drops the role's
-- column-level grants on that table; step 3 gives the allowed columns back).
SELECT format('REVOKE SELECT ON TABLE public.%I FROM %I', t.relname, :'ro_role')
  FROM mm_tables t JOIN pg_class c ON c.oid = t.relid
 WHERE EXISTS (SELECT 1 FROM mm_cols m WHERE m.relid = t.relid AND m.sensitive)
   AND EXISTS (SELECT 1 FROM aclexplode(c.relacl) x
                WHERE x.grantee = :ro_oid::oid AND x.privilege_type = 'SELECT')
 ORDER BY t.relname \gexec

-- Any column-level privilege on a sensitive column.
SELECT format('REVOKE ALL (%I) ON TABLE public.%I FROM %I', m.attname, m.relname, :'ro_role')
  FROM mm_cols m JOIN pg_attribute a ON a.attrelid = m.relid AND a.attnum = m.attnum
 WHERE m.sensitive
   AND EXISTS (SELECT 1 FROM aclexplode(a.attacl) x WHERE x.grantee = :ro_oid::oid)
 ORDER BY m.relname, m.attnum \gexec

-- Non-SELECT privileges (whatever this server version calls them) on in-scope tables...
SELECT format('REVOKE %s ON TABLE public.%I FROM %I',
              string_agg(DISTINCT x.privilege_type, ', '), t.relname, :'ro_role')
  FROM mm_tables t JOIN pg_class c ON c.oid = t.relid
 CROSS JOIN LATERAL aclexplode(c.relacl) x
 WHERE x.grantee = :ro_oid::oid AND x.privilege_type <> 'SELECT'
 GROUP BY t.relid, t.relname
 ORDER BY t.relname \gexec
-- ...and on their columns.
SELECT format('REVOKE %s (%I) ON TABLE public.%I FROM %I',
              string_agg(DISTINCT x.privilege_type, ', '), m.attname, m.relname, :'ro_role')
  FROM mm_cols m JOIN pg_attribute a ON a.attrelid = m.relid AND a.attnum = m.attnum
 CROSS JOIN LATERAL aclexplode(a.attacl) x
 WHERE x.grantee = :ro_oid::oid AND x.privilege_type <> 'SELECT'
 GROUP BY m.relid, m.attnum, m.relname, m.attname
 ORDER BY m.relname, m.attnum \gexec

-- Everything the role holds directly on tables/views/sequences outside the scope.
SELECT format('REVOKE ALL ON %s %I.%I FROM %I',
              CASE WHEN c.relkind = 'S' THEN 'SEQUENCE' ELSE 'TABLE' END,
              n.nspname, c.relname, :'ro_role')
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE c.relkind IN ('r', 'p', 'v', 'm', 'f', 'S')
   AND n.nspname NOT IN ('pg_catalog', 'information_schema') AND n.nspname !~ '^pg_(toast|temp)'
   AND c.oid NOT IN (SELECT relid FROM mm_tables)
   AND (EXISTS (SELECT 1 FROM aclexplode(c.relacl) x WHERE x.grantee = :ro_oid::oid)
        OR EXISTS (SELECT 1 FROM pg_attribute a CROSS JOIN LATERAL aclexplode(a.attacl) x
                    WHERE a.attrelid = c.oid AND x.grantee = :ro_oid::oid))
 ORDER BY n.nspname, c.relname \gexec

-- ...and on functions / procedures / aggregates.
SELECT format('REVOKE ALL ON ROUTINE %s FROM %I', p.oid::regprocedure, :'ro_role')
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname NOT IN ('pg_catalog', 'information_schema') AND n.nspname !~ '^pg_(toast|temp)'
   AND EXISTS (SELECT 1 FROM aclexplode(p.proacl) x WHERE x.grantee = :ro_oid::oid)
 ORDER BY 1 \gexec

-- ── 2. Basic access (plain grants: PUBLIC's own CONNECT is not revoked) ─────
SELECT format('GRANT CONNECT ON DATABASE %I TO %I', current_database(), :'ro_role') \gexec
SELECT format('GRANT USAGE ON SCHEMA public TO %I', :'ro_role') \gexec

-- ── 3. The grants ────────────────────────────────────────────────────────────
-- Tables without a sensitive column: table-level SELECT.
SELECT format('GRANT SELECT ON TABLE public.%I TO %I', t.relname, :'ro_role')
  FROM mm_tables t
 WHERE NOT EXISTS (SELECT 1 FROM mm_cols m WHERE m.relid = t.relid AND m.sensitive)
 ORDER BY t.relname \gexec

-- Leftover column-level entries on those tables are redundant now (the table-level grant
-- stays in force); removing them keeps the ACL canonical. Done after the grant: no gap.
SELECT format('REVOKE SELECT (%I) ON TABLE public.%I FROM %I', m.attname, m.relname, :'ro_role')
  FROM mm_cols m JOIN pg_attribute a ON a.attrelid = m.relid AND a.attnum = m.attnum
 WHERE NOT EXISTS (SELECT 1 FROM mm_cols s WHERE s.relid = m.relid AND s.sensitive)
   AND EXISTS (SELECT 1 FROM aclexplode(a.attacl) x WHERE x.grantee = :ro_oid::oid AND x.privilege_type = 'SELECT')
 ORDER BY m.relname, m.attnum \gexec

-- Tables with at least one sensitive column: SELECT on the other columns only.
SELECT format('GRANT SELECT (%s) ON TABLE public.%I TO %I',
              string_agg(quote_ident(m.attname), ', ' ORDER BY m.attnum), m.relname, :'ro_role')
  FROM mm_cols m
 WHERE NOT m.sensitive
   AND EXISTS (SELECT 1 FROM mm_cols s WHERE s.relid = m.relid AND s.sensitive)
 GROUP BY m.relid, m.relname
 ORDER BY m.relname \gexec

-- ── Verification ─────────────────────────────────────────────────────────────
-- status: ok | FAIL (hard; makes the script exit non-zero) | WARN (informational)
CREATE TEMP TABLE mm_read AS
SELECT m.relid, m.relname, m.attnum, m.attname, m.fq, m.sensitive, m.reason, m.rule_hit, m.allowed, m.denied,
       has_column_privilege(:'ro_role'::name, m.relid, m.attnum::int2, 'SELECT') AS readable
  FROM mm_cols m;

CREATE TEMP TABLE mm_report AS
SELECT t.relname AS table_name,
       CASE WHEN has_table_privilege(:'ro_role'::name, t.relid, 'SELECT') THEN 'table'
            WHEN count(*) FILTER (WHERE r.readable) = 0 THEN 'none'
            ELSE 'columns (' || (count(*) FILTER (WHERE r.readable))::text || ' of ' || count(r.attnum)::text || ')'
       END AS granted,
       coalesce(string_agg(r.attname, ', ' ORDER BY r.attnum) FILTER (WHERE r.sensitive), '') AS excluded_sensitive_columns,
       CASE WHEN count(*) FILTER (WHERE r.sensitive AND r.readable) > 0
              OR count(*) FILTER (WHERE NOT r.sensitive AND NOT r.readable) > 0 THEN 'FAIL'
            WHEN count(r.attnum) > 0 AND count(*) FILTER (WHERE NOT r.sensitive) = 0 THEN 'WARN'
            WHEN NOT has_table_privilege(:'ro_role'::name, t.relid, 'SELECT')
                 AND count(r.attnum) = 0 THEN 'FAIL'
            ELSE 'ok' END AS status
  FROM mm_tables t LEFT JOIN mm_read r ON r.relid = t.relid
 GROUP BY t.relid, t.relname;

CREATE TEMP TABLE mm_checks (n serial, check_name text, expected text, actual text, status text);

INSERT INTO mm_checks (check_name, expected, actual, status)
SELECT 'role exists', 'true', EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'ro_role')::text, NULL;
INSERT INTO mm_checks (check_name, expected, actual, status)
SELECT 'CONNECT on ' || current_database(), 'true', has_database_privilege(:'ro_role'::name, current_database(), 'CONNECT')::text, NULL;
INSERT INTO mm_checks (check_name, expected, actual, status)
SELECT 'USAGE on schema public', 'true', has_schema_privilege(:'ro_role'::name, 'public', 'USAGE')::text, NULL;

-- HARD: no sensitive column is readable (table-level, column-level, PUBLIC or membership).
INSERT INTO mm_checks (check_name, expected, actual, status)
SELECT 'sensitive columns readable by the role', '(none)',
       coalesce((SELECT string_agg(fq, ', ' ORDER BY fq COLLATE "C") FROM mm_read WHERE sensitive AND readable), '(none)'), NULL;

-- HARD: every in-scope table is readable through its allowed columns.
INSERT INTO mm_checks (check_name, expected, actual, status)
SELECT 'in-scope tables NOT readable via their allowed columns', '(none)',
       coalesce((SELECT string_agg(DISTINCT relname, ', ') FROM mm_read WHERE NOT sensitive AND NOT readable), '(none)'), NULL;

-- HARD: no write privilege on any table/view/column/sequence of a user schema.
INSERT INTO mm_checks (check_name, expected, actual, status)
SELECT 'role cannot write anything (INSERT/UPDATE/DELETE/TRUNCATE/REFERENCES/TRIGGER, sequence UPDATE)', '(none)',
       coalesce((SELECT string_agg(x, ', ' ORDER BY x COLLATE "C") FROM (
          SELECT format('%I.%I:%s', n.nspname, c.relname, p) AS x
            FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
           CROSS JOIN unnest(ARRAY['INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'REFERENCES', 'TRIGGER']) p
           WHERE c.relkind IN ('r', 'p', 'v', 'm', 'f')
             AND n.nspname NOT IN ('pg_catalog', 'information_schema') AND n.nspname !~ '^pg_(toast|temp)'
             AND has_table_privilege(:'ro_role'::name, c.oid, p)
          UNION
          SELECT format('%I.%I:%s (column)', n.nspname, c.relname, p)
            FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
           CROSS JOIN unnest(ARRAY['INSERT', 'UPDATE', 'REFERENCES']) p
           WHERE c.relkind IN ('r', 'p', 'v', 'm', 'f')
             AND n.nspname NOT IN ('pg_catalog', 'information_schema') AND n.nspname !~ '^pg_(toast|temp)'
             AND has_any_column_privilege(:'ro_role'::name, c.oid, p)
          UNION
          SELECT format('%I.%I:UPDATE (sequence)', n.nspname, c.relname)
            FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
           WHERE c.relkind = 'S'
             AND n.nspname NOT IN ('pg_catalog', 'information_schema') AND n.nspname !~ '^pg_(toast|temp)'
             AND CASE WHEN c.relkind = 'S' THEN has_sequence_privilege(:'ro_role'::name, c.oid, 'UPDATE') END) w), '(none)'), NULL;

-- WARN: anything readable outside the scope (could only come from PUBLIC or a role membership).
INSERT INTO mm_checks (check_name, expected, actual, status)
SELECT 'role has no privilege on views / materialized views / foreign tables', '(none)',
       coalesce((SELECT string_agg(nspname || '.' || relname, ', ' ORDER BY nspname, relname) FROM mm_outside
                  WHERE relkind IN ('v', 'm', 'f')
                    AND (has_table_privilege(:'ro_role'::name, relid, 'SELECT')
                         OR has_any_column_privilege(:'ro_role'::name, relid, 'SELECT'))), '(none)'), NULL;
INSERT INTO mm_checks (check_name, expected, actual, status)
SELECT 'role cannot read tables outside the scope (other schemas, partition children)', '(none)',
       coalesce((SELECT string_agg(nspname || '.' || relname, ', ' ORDER BY nspname, relname) FROM mm_outside
                  WHERE relkind IN ('r', 'p')
                    AND (has_table_privilege(:'ro_role'::name, relid, 'SELECT')
                         OR has_any_column_privilege(:'ro_role'::name, relid, 'SELECT'))), '(none)'), NULL;
INSERT INTO mm_checks (check_name, expected, actual, status)
SELECT 'columns matching the name rule but opened by allow_cols', '(none)',
       coalesce((SELECT string_agg(fq, ', ' ORDER BY fq COLLATE "C") FROM mm_cols WHERE rule_hit AND allowed AND NOT denied), '(none)'), NULL;
INSERT INTO mm_checks (check_name, expected, actual, status)
SELECT 'tables with no readable column at all (all columns sensitive)', '(none)',
       coalesce((SELECT string_agg(table_name, ', ' ORDER BY table_name COLLATE "C") FROM mm_report WHERE status = 'WARN'), '(none)'), NULL;
INSERT INTO mm_checks (check_name, expected, actual, status)
SELECT 'role is member of no roles (memberships can add privileges)', '(none)',
       coalesce((SELECT string_agg(pg_get_userbyid(roleid), ', ') FROM pg_auth_members WHERE member = :ro_oid::oid), '(none)'), NULL;
INSERT INTO mm_checks (check_name, expected, actual, status)
SELECT 'CREATE on schema public (PUBLIC default on PG14; not touched here)', 'false',
       has_schema_privilege(:'ro_role'::name, 'public', 'CREATE')::text, NULL;

UPDATE mm_checks
   SET status = CASE
         WHEN check_name LIKE 'role has no privilege on views%'
           OR check_name LIKE 'role cannot read tables outside%'
           OR check_name LIKE 'columns matching the name rule%'
           OR check_name LIKE 'tables with no readable column%'
           OR check_name LIKE 'role is member of no roles%'
           OR check_name LIKE 'CREATE on schema public%'
           THEN CASE WHEN actual = expected THEN 'ok' ELSE 'WARN' END
         WHEN actual = expected THEN 'ok' ELSE 'FAIL' END
 WHERE status IS NULL;

\unset QUIET
\echo
\echo '== minimart_ro grants: per table (table | how granted | excluded sensitive columns | status) =='
SELECT table_name AS "table", granted, excluded_sensitive_columns, status
  FROM mm_report ORDER BY table_name COLLATE "C";

\echo
\echo '== minimart_ro grants: sensitive columns EXCLUDED (review; opt back in with allow_cols=table.column) =='
SELECT fq AS "table.column", reason FROM mm_cols WHERE sensitive ORDER BY fq COLLATE "C";

\echo
\echo '== minimart_ro grants: checks =='
SELECT check_name, expected, actual, status FROM mm_checks ORDER BY n;
\set QUIET on

SELECT (SELECT count(*) FROM mm_checks WHERE status = 'FAIL')
     + (SELECT count(*) FROM mm_report WHERE status = 'FAIL') > 0 AS has_fail,
       (SELECT count(*) FROM mm_checks WHERE status = 'WARN')
     + (SELECT count(*) FROM mm_report WHERE status = 'WARN') AS warnings \gset
\if :has_fail
  \echo 'minimart_ro grants: VERIFICATION FAILED (see FAIL rows above)'
  DO $$ BEGIN RAISE EXCEPTION 'minimart_ro grants verification failed'; END $$;
\else
  \echo minimart_ro grants: all hard checks passed, warnings = :warnings
\endif
