#!/usr/bin/env bash
# Self-checking tests for the Postgres side of the hauling mirror:
#   db/hauling_ro_setup.sql, test/hauling/seed.sql, test/hauling/mutate.sql
#
#   bash test/hauling/run_pg_tests.sh
#
# Runs against the local Homebrew Postgres (socket /tmp, current OS user is superuser, the socket
# trusts local connections, so `psql -U hauling_ro` needs no password).
#
# Databases (dropped and rebuilt at the start of every run):
#   hauling_dev        pg_schema.sql + seed.sql + the setup script. LEFT IN PLACE, UNMUTATED, for the
#                      sync tests / QC. Never dropped at the end.
#   hauling_ro_test    scratch copy used for the scenarios that need extra tables (users, audit_log,
#                      schema_migrations), a missing table and stray grants. Left in place.
#   hauling_ro_test_m  scratch copy (schema + seed) that mutate.sql is applied to, one step at a time.
# Roles:
#   hauling_ro         the real role (created/refreshed by the setup script). NEVER dropped. Its password is
#                      set to $HAULING_RO_TEST_PASSWORD (default below) by this test.
#   hauling_ro_t       throwaway copy of the role (the script run through `sed s/hauling_ro/hauling_ro_t/`),
#                      used for the "fresh create", "short password creates nothing" and connection-limit
#                      tests so they never disturb hauling_ro's connections. Dropped at the end.
#   hauling_app_t      throwaway stand-in for the live system's own roles (has grants and default privileges
#                      so the "nothing else changed" snapshot is not trivially empty). Dropped at the end.
set -uo pipefail

cd "$(dirname "$0")/../.."
export PGHOST=${PGHOST:-/tmp}
unset PGPASSWORD PGUSER PGDATABASE PGOPTIONS
PW=${HAULING_RO_TEST_PASSWORD:-test-password-0123456789}
DEV=hauling_dev
SCR=hauling_ro_test
MUT=hauling_ro_test_m
LOG=$(mktemp -d)/hauling_pg_test
mkdir -p "$LOG"
SETUP=db/hauling_ro_setup.sql
SETUP_T="$LOG/hauling_ro_setup_t.sql"
sed 's/hauling_ro/hauling_ro_t/g' "$SETUP" > "$SETUP_T"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS  $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL  $1"; }
q()   { psql -X -q -tA -v ON_ERROR_STOP=1 -d "$1" -c "$2"; }                  # q db sql   (superuser)
RO()  { PGPASSWORD=$PW psql -X -q -tA -v ON_ERROR_STOP=1 -U "${3:-hauling_ro}" -d "$1" -c "$2" 2>&1; }  # RO db sql [role]
ROIN(){ PGPASSWORD=$PW psql -X -q -tA -U hauling_ro -d "$1" 2>&1; }          # statements on stdin, each its own transaction
check() { # check "description" "got" "expected"
  if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 - expected [$3] got [$2]"; fi
}
expect_rc() { # expect_rc "desc" expected actual
  if [[ "$3" == "$2" ]]; then ok "$1 (exit $3)"; else bad "$1 - expected exit $2, got $3"; fi
}
contains() { # contains "desc" haystack needle
  if [[ "$2" == *"$3"* ]]; then ok "$1"; else bad "$1 - [$3] not in [${2:0:300}]"; fi
}
run_setup() { # run_setup db password [sqlfile]  -> RC, output in $LOG/setup.out
  { printf '\\set ro_password %s\n' "$2"; cat "${3:-$SETUP}"; } | psql -X -d postgres -v dbname="$1" >"$LOG/setup.out" 2>&1
  RC=${PIPESTATUS[1]}
}
role_exists() { q postgres "SELECT count(*) FROM pg_roles WHERE rolname = '$1'"; }

cleanup_roles() {
  for db in $DEV $SCR; do
    psql -X -q -d "$db" -c "DROP OWNED BY hauling_ro_t" -c "DROP OWNED BY hauling_app_t" >/dev/null 2>&1
  done
  psql -X -q -d postgres -c "DROP ROLE IF EXISTS hauling_ro_t" -c "DROP ROLE IF EXISTS hauling_app_t" >/dev/null 2>&1
}
trap 'cleanup_roles; jobs -p | xargs kill 2>/dev/null' EXIT
cleanup_roles

# Everything that exists in the cluster/database apart from hauling_ro* itself, normalised so that
# PostgreSQL materialising a default ACL when we GRANT does not count as a change.
snapshot() { # snapshot db
  psql -X -q -tA -d "$1" <<'SQL'
\set ON_ERROR_STOP on
SELECT 'class|' || n.nspname || '.' || c.relname || '|' || c.relkind || '|' || pg_get_userbyid(c.relowner) || '|' ||
       coalesce((SELECT string_agg(CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee) END || ':' ||
                                   a.privilege_type || ':' || a.is_grantable || ':' || pg_get_userbyid(a.grantor), ',' ORDER BY a.grantee, a.privilege_type)
                   FROM aclexplode(coalesce(c.relacl, acldefault((CASE WHEN c.relkind = 'S' THEN 's' ELSE 'r' END)::"char", c.relowner))) a
                  WHERE a.grantee = 0 OR pg_get_userbyid(a.grantee) NOT LIKE 'hauling\_ro%'), '')
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname NOT IN ('pg_catalog', 'information_schema') AND n.nspname NOT LIKE 'pg\_toast%' AND n.nspname NOT LIKE 'pg\_temp%'
 ORDER BY 1;
SELECT 'column|' || c.oid::regclass || '.' || a.attname || '|' || format_type(a.atttypid, a.atttypmod) || '|' || a.attnotnull || '|' ||
       coalesce((SELECT string_agg(pg_get_userbyid(x.grantee) || ':' || x.privilege_type, ',' ORDER BY x.grantee, x.privilege_type) FROM aclexplode(a.attacl) x
                  WHERE pg_get_userbyid(x.grantee) NOT LIKE 'hauling\_ro%'), '')
  FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE a.attnum > 0 AND NOT a.attisdropped AND c.relkind IN ('r', 'p', 'v', 'm', 'f')
   AND n.nspname NOT IN ('pg_catalog', 'information_schema') AND n.nspname NOT LIKE 'pg\_toast%' AND n.nspname NOT LIKE 'pg\_temp%'
 ORDER BY 1;
SELECT 'schema|' || nspname || '|' || pg_get_userbyid(nspowner) || '|' ||
       coalesce((SELECT string_agg(CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee) END || ':' || a.privilege_type || ':' || a.is_grantable, ',' ORDER BY a.grantee, a.privilege_type)
                   FROM aclexplode(coalesce(nspacl, acldefault('n'::"char", nspowner))) a
                  WHERE a.grantee = 0 OR pg_get_userbyid(a.grantee) NOT LIKE 'hauling\_ro%'), '')
  FROM pg_namespace WHERE nspname NOT LIKE 'pg\_toast%' AND nspname NOT LIKE 'pg\_temp%' ORDER BY 1;
SELECT 'database|' || datname || '|' || pg_get_userbyid(datdba) || '|' ||
       coalesce((SELECT string_agg(CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee) END || ':' || a.privilege_type || ':' || a.is_grantable, ',' ORDER BY a.grantee, a.privilege_type)
                   FROM aclexplode(coalesce(datacl, acldefault('d'::"char", datdba))) a
                  WHERE a.grantee = 0 OR pg_get_userbyid(a.grantee) NOT LIKE 'hauling\_ro%'), '')
  FROM pg_database WHERE datname = current_database() ORDER BY 1;
SELECT 'default_acl|' || pg_get_userbyid(defaclrole) || '|' || coalesce(defaclnamespace::regnamespace::text, '-') || '|' || defaclobjtype || '|' ||
       coalesce((SELECT string_agg(CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee) END || ':' || a.privilege_type, ',' ORDER BY a.grantee, a.privilege_type)
                   FROM aclexplode(defaclacl) a WHERE a.grantee = 0 OR pg_get_userbyid(a.grantee) NOT LIKE 'hauling\_ro%'), '')
  FROM pg_default_acl ORDER BY 1;
SELECT 'member|' || pg_get_userbyid(roleid) || '|' || pg_get_userbyid(member) || '|' || admin_option
  FROM pg_auth_members WHERE pg_get_userbyid(roleid) NOT LIKE 'hauling\_ro%' AND pg_get_userbyid(member) NOT LIKE 'hauling\_ro%' ORDER BY 1;
SELECT 'role|' || rolname || '|' || rolsuper || rolinherit || rolcreaterole || rolcreatedb || rolcanlogin || rolreplication || rolbypassrls || '|' ||
       rolconnlimit || '|' || coalesce(rolvaliduntil::text, '-') || '|' || coalesce(md5(rolpassword), '-')
  FROM pg_authid WHERE rolname NOT LIKE 'hauling\_ro%' ORDER BY 1;
SELECT 'role_setting|' || coalesce(setdatabase::text, '-') || '|' || coalesce(pg_get_userbyid(nullif(setrole, 0)), '-') || '|' || setconfig::text
  FROM pg_db_role_setting WHERE setrole = 0 OR pg_get_userbyid(setrole) NOT LIKE 'hauling\_ro%' ORDER BY 1;
SELECT 'index|' || indexrelid::regclass || '|' || pg_get_indexdef(indexrelid) FROM pg_index i JOIN pg_class c ON c.oid = i.indrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'public' ORDER BY 1;
SELECT format('SELECT %L || count(*) || %L || coalesce(md5(string_agg(x::text, %L ORDER BY x::text)), %L) FROM %I.%I x',
              'data|' || schemaname || '.' || tablename || '|', '|', '|', '-', schemaname, tablename)
  FROM pg_tables WHERE schemaname = 'public' ORDER BY tablename \gexec
SQL
}

echo "== 1. Build hauling_dev (pg_schema + seed) and the scratch database =="
for db in $DEV $SCR $MUT; do
  psql -X -q -d postgres -c "DROP DATABASE IF EXISTS $db WITH (FORCE)" -c "CREATE DATABASE $db" || { echo "cannot create $db"; exit 1; }
  # PostgreSQL 15+ (production is 16) does not give PUBLIC CREATE on schema public; PG14 does. Mimic production.
  psql -X -q -v ON_ERROR_STOP=1 -d $db -c "REVOKE CREATE ON SCHEMA public FROM PUBLIC" \
    -f test/hauling/pg_schema.sql >"$LOG/load_$db.out" 2>&1 \
    && psql -X -q -v ON_ERROR_STOP=1 -d $db -f test/hauling/seed.sql >>"$LOG/load_$db.out" 2>&1
  expect_rc "schema + seed load into $db" 0 $?
done
# Stand-ins for the live system's own roles, so "nothing else changed" is checked against something real.
psql -X -q -v ON_ERROR_STOP=1 -d postgres -c "CREATE ROLE hauling_app_t NOLOGIN" >/dev/null
for db in $DEV $SCR; do
  psql -X -q -v ON_ERROR_STOP=1 -d $db <<'SQL'
GRANT USAGE, CREATE ON SCHEMA public TO hauling_app_t;
GRANT ALL ON ALL TABLES IN SCHEMA public TO hauling_app_t;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO hauling_app_t;
ALTER DEFAULT PRIVILEGES FOR ROLE hauling_app_t GRANT SELECT ON TABLES TO PUBLIC;
GRANT SELECT ON sessions TO hauling_app_t;
SQL
done
# Extra tables the real hauling_tracker has (the hash column name is a placeholder here, not a claim about the real schema).
psql -X -q -v ON_ERROR_STOP=1 -d $SCR <<'SQL'
CREATE TABLE users (user_id serial PRIMARY KEY, username text, pw_hash text);
INSERT INTO users (username, pw_hash) VALUES ('calvin', 'not-a-real-hash');
CREATE TABLE audit_log (audit_id serial PRIMARY KEY, what text);
INSERT INTO audit_log (what) VALUES ('x');
CREATE TABLE schema_migrations (version text PRIMARY KEY);
INSERT INTO schema_migrations VALUES ('001');
INSERT INTO sessions (status) VALUES ('active');
GRANT ALL ON users, audit_log, schema_migrations TO hauling_app_t;
SQL

echo "== 2. Seed data totals and determinism =="
check "trips count"                 "$(q $DEV 'SELECT count(*) FROM trips')" 1200
check "sum(netto_site_kg)"          "$(q $DEV 'SELECT sum(netto_site_kg) FROM trips')" 39525449
check "sum(netto_jetty_kg)"         "$(q $DEV 'SELECT sum(netto_jetty_kg) FROM trips')" 39473729
check "trips by status"             "$(q $DEV "SELECT string_agg(status||'='||c, ',' ORDER BY status) FROM (SELECT status::text, count(*) c FROM trips GROUP BY 1) x")" "arrived_jetty=3,completed=1190,in_transit=4,pending=3"
check "trips by coal quality"       "$(q $DEV "SELECT string_agg(k||'='||c, ',' ORDER BY k) FROM (SELECT coal_quality::text k, count(*) c FROM trips GROUP BY 1) x")" "clean=379,premium=173,raw=403,standard=245"
check "distinct trucks / date range" "$(q $DEV "SELECT count(DISTINCT no_lambung)||' '||min(date)||' '||max(date) FROM trips")" "80 2026-05-21 2026-08-26"
check "barge_loadings count/sum"    "$(q $DEV "SELECT count(*)||' '||sum(loading_qty_kg) FROM barge_loadings")" "16 121364538"
check "scale_readings_pending"      "$(q $DEV "SELECT count(*)||' '||sum(weight_kg) FROM scale_readings_pending")" "4 129427.50"
check "station_heartbeat count/ids" "$(q $DEV "SELECT count(*)||' '||min(id)||' '||max(id) FROM station_heartbeat")" "500 1 500"
check "error_log count/context NULLs" "$(q $DEV "SELECT count(*)||' '||count(*) FILTER (WHERE context IS NULL) FROM error_log")" "300 75"
check "error_log biggest context ~2 KB" "$(q $DEV "SELECT max(length(context::text)) FROM error_log")" 2112
check "weights consistent (netto=gross-tare, deviasi)" "$(q $DEV "SELECT count(*) FROM trips WHERE netto_site_kg <> gross_site_kg - tare_site_kg OR deviasi_kg <> gross_jetty_kg - compare_gross_kg OR NOT (cp1_timestamp < cp2_timestamp) OR NOT (cp2_timestamp < cp3_timestamp)")" 0
check "second independent load is byte-identical (determinism)" \
  "$(q $SCR "SELECT md5(string_agg(t::text, '|' ORDER BY t::text)) FROM trips t")" \
  "$(q $DEV "SELECT md5(string_agg(t::text, '|' ORDER BY t::text)) FROM trips t")"
check "error_log load is identical too" \
  "$(q $SCR "SELECT md5(string_agg(t::text, '|' ORDER BY t::text)) FROM error_log t")" \
  "$(q $DEV "SELECT md5(string_agg(t::text, '|' ORDER BY t::text)) FROM error_log t")"

echo "== 3. Setup script: refusals leave nothing behind =="
run_setup $DEV 'short-pw-15char' "$SETUP_T"
if [[ $RC -ne 0 ]]; then ok "15-char password refused (exit $RC)"; else bad "15-char password was accepted"; fi
contains "refusal says why" "$(cat $LOG/setup.out)" "at least 16"
check "no role created after short password" "$(role_exists hauling_ro_t)" 0
run_setup $DEV 'x' "$SETUP_T"
check "1-char password: no role created" "$(role_exists hauling_ro_t)" 0
{ cat "$SETUP_T"; } | psql -X -d postgres -v dbname=$DEV >"$LOG/nopw.out" 2>&1; RC=${PIPESTATUS[1]}
if [[ $RC -ne 0 ]]; then ok "missing ro_password refused (exit $RC)"; else bad "missing ro_password was accepted"; fi
check "no role created without password" "$(role_exists hauling_ro_t)" 0
run_setup no_such_database_x "$PW" "$SETUP_T"
if [[ $RC -ne 0 ]]; then ok "unknown database refused (exit $RC)"; else bad "unknown database was accepted"; fi
check "no role created for unknown database" "$(role_exists hauling_ro_t)" 0

echo "== 4. Setup script: fresh create (throwaway name), then the real role =="
run_setup $DEV "$PW" "$SETUP_T"
expect_rc "fresh create of hauling_ro_t" 0 $RC
check "hauling_ro_t created with LOGIN and limit 20" "$(q postgres "SELECT rolcanlogin::text||' '||rolconnlimit FROM pg_roles WHERE rolname='hauling_ro_t'")" "true 20"
contains "fresh create: all hard verification checks passed" "$(cat $LOG/setup.out)" "hard checks passed"
if grep -qF -- "$PW" "$LOG/setup.out"; then bad "password appears in setup output"; else ok "password not in setup output"; fi

snapshot $DEV > "$LOG/snap_dev_before.txt"
snapshot $SCR > "$LOG/snap_scr_before.txt"
run_setup $DEV "$PW";        expect_rc "setup on hauling_dev, run 1" 0 $RC; cp "$LOG/setup.out" "$LOG/setup1.out"
snapshot $DEV > "$LOG/snap_dev_after1.txt"
run_setup $DEV "$PW";        expect_rc "setup on hauling_dev, run 2 (idempotent)" 0 $RC
snapshot $DEV > "$LOG/snap_dev_after2.txt"
if grep -qF -- "$PW" "$LOG/setup.out" "$LOG/setup1.out"; then bad "password appears in setup output"; else ok "password not echoed by the real-role runs"; fi
contains "verification table printed" "$(cat $LOG/setup1.out)" "SELECT granted on the existing listed tables"
check "state identical after run 1 and run 2" "$(diff <(grep -v '^$' $LOG/snap_dev_after1.txt) <(grep -v '^$' $LOG/snap_dev_after2.txt) | wc -l | tr -d ' ')" 0

echo "== 5. SAFETY: nothing but hauling_ro* changed (acl / default privileges / memberships / roles / data / indexes) =="
snap_lines=$(wc -l < "$LOG/snap_dev_before.txt" | tr -d ' ')
if [[ $snap_lines -gt 40 ]] && grep -q 'hauling_app_t' "$LOG/snap_dev_before.txt"; then ok "snapshot is non-trivial ($snap_lines lines, includes the stand-in app role)"; else bad "snapshot looks empty ($snap_lines lines)"; fi
if diff -u "$LOG/snap_dev_before.txt" "$LOG/snap_dev_after1.txt" >"$LOG/snap_dev.diff"; then ok "hauling_dev: snapshot unchanged by the setup script"; else bad "hauling_dev: snapshot changed:"; head -30 "$LOG/snap_dev.diff"; fi

echo "== 6. Grants: what hauling_ro can and cannot do (as hauling_ro, on hauling_dev) =="
check "current_user via psql -U hauling_ro" "$(RO $DEV 'SELECT current_user')" hauling_ro
for spec in trips:1200 barge_loadings:16 scale_readings_pending:4 station_heartbeat:500 error_log:300; do
  check "SELECT count(*) FROM ${spec%%:*}" "$(RO $DEV "SELECT count(*) FROM ${spec%%:*}")" "${spec##*:}"
done
out=$(RO $DEV 'SELECT count(*) FROM sessions');        contains "SELECT on sessions is denied" "$out" "permission denied for table sessions"
out=$(RO $DEV 'SELECT * FROM pg_authid');              contains "cannot read pg_authid" "$out" "permission denied"
out=$(printf '%s\n' "SET default_transaction_read_only = off;" "INSERT INTO trips (date, no_tiket, no_lambung, jetty_destination, coal_quality, cuaca_mmi, tare_site_kg) VALUES (now(), 1, 'x', 'hasnur', 'raw', 'x', 1);" | ROIN $DEV)
contains "INSERT denied even with read_only=off" "$out" "permission denied for table trips"
out=$(printf "SET default_transaction_read_only = off;\nUPDATE trips SET adjustment_kg = 1;\n" | ROIN $DEV)
contains "UPDATE denied even with read_only=off" "$out" "permission denied for table trips"
out=$(printf "SET default_transaction_read_only = off;\nDELETE FROM error_log;\n" | ROIN $DEV)
contains "DELETE denied even with read_only=off" "$out" "permission denied for table error_log"
out=$(printf "SET default_transaction_read_only = off;\nTRUNCATE station_heartbeat;\n" | ROIN $DEV)
contains "TRUNCATE denied even with read_only=off" "$out" "permission denied for table station_heartbeat"
out=$(printf "SET default_transaction_read_only = off;\nCREATE TABLE hauling_ro_should_not_exist (i int);\n" | ROIN $DEV)
contains "CREATE TABLE denied even with read_only=off" "$out" "permission denied for schema public"
out=$(printf "SET default_transaction_read_only = off;\nDROP TABLE trips;\n" | ROIN $DEV)
contains "DROP TABLE denied" "$out" "must be owner of table trips"
out=$(RO $DEV "CREATE TABLE hauling_ro_should_not_exist2 (i int)");  contains "writes are read-only by default too" "$out" "read-only transaction"
check "no table was created" "$(q $DEV "SELECT count(*) FROM pg_class WHERE relname LIKE 'hauling_ro_should_not_exist%'")" 0
check "row counts untouched after the write attempts" "$(q $DEV "SELECT (SELECT count(*) FROM trips)||' '||(SELECT count(*) FROM error_log)||' '||(SELECT count(*) FROM station_heartbeat)")" "1200 300 500"

echo "== 7. Session settings: UTC and ISO output =="
check "SHOW timezone"                      "$(RO $DEV 'SHOW timezone')" UTC
check "SHOW datestyle"                     "$(RO $DEV 'SHOW datestyle')" "ISO, YMD"
check "SHOW default_transaction_read_only" "$(RO $DEV 'SHOW default_transaction_read_only')" on
check "SHOW statement_timeout"             "$(RO $DEV 'SHOW statement_timeout')" 2min
expected=$(q $DEV "SELECT (cp1_timestamp AT TIME ZONE 'UTC')::text || '+00' FROM trips WHERE trip_id = md5('trip-1')::uuid")
check "cp1_timestamp::text is UTC wall clock with +00" "$(RO $DEV "SELECT cp1_timestamp::text FROM trips WHERE trip_id = md5('trip-1')::uuid")" "$expected"
check "no timestamptz text anywhere carries another offset" \
  "$(RO $DEV "SELECT (SELECT count(*) FROM trips WHERE cp1_timestamp::text !~ '[+]00\$' OR cp2_timestamp::text !~ '[+]00\$' OR cp3_timestamp::text !~ '[+]00\$')
                   + (SELECT count(*) FROM error_log WHERE created_at::text !~ '[+]00\$')
                   + (SELECT count(*) FROM station_heartbeat WHERE received_at::text !~ '[+]00\$' OR pc_time::text !~ '[+]00\$')
                   + (SELECT count(*) FROM barge_loadings WHERE created_at::text !~ '[+]00\$')
                   + (SELECT count(*) FROM scale_readings_pending WHERE measured_at::text !~ '[+]00\$')")" 0
check "date column text is plain ISO" "$(RO $DEV "SELECT date::text FROM trips WHERE trip_id = md5('trip-1')::uuid")" "$(q $DEV "SELECT to_char(date,'YYYY-MM-DD') FROM trips WHERE trip_id = md5('trip-1')::uuid")"
sess_tz=$(q $DEV "SHOW timezone")
if [[ "$sess_tz" != "UTC" ]]; then
  control=$(q $DEV "SELECT cp1_timestamp::text FROM trips WHERE trip_id = md5('trip-1')::uuid")
  if [[ "$control" != *"+00" ]]; then ok "control: an ordinary session ($sess_tz) sees a different offset ($control), so the role pin matters"; else bad "control session did not differ"; fi
fi
check "numeric weight survives as text" "$(RO $DEV "SELECT weight_kg::text FROM scale_readings_pending WHERE no_lambung='DT-012' AND reading_type='tare'")" 14873.5
check "jsonb context readable (huge row)" "$(RO $DEV "SELECT length(context::text) FROM error_log WHERE context ? 'blob'")" 2112

echo "== 8. Role attributes =="
check "rolconnlimit = 20"                  "$(q postgres "SELECT rolconnlimit FROM pg_roles WHERE rolname='hauling_ro'")" 20
check "LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS" "$(q postgres "SELECT rolcanlogin::text||rolsuper::text||rolcreatedb::text||rolcreaterole::text||rolreplication::text||rolbypassrls::text FROM pg_roles WHERE rolname='hauling_ro'")" truefalsefalsefalsefalsefalse
check "member of no roles"                 "$(q postgres "SELECT count(*) FROM pg_auth_members WHERE member = 'hauling_ro'::regrole")" 0
check "readable tables = exactly the five" "$(q $DEV "SELECT string_agg(relname, ',' ORDER BY relname) FROM pg_class WHERE relnamespace='public'::regnamespace AND relkind='r' AND has_table_privilege('hauling_ro', oid, 'SELECT')")" "barge_loadings,error_log,scale_readings_pending,station_heartbeat,trips"
check "no column-level grants anywhere"    "$(q $DEV "SELECT count(*) FROM pg_attribute a WHERE a.attacl IS NOT NULL AND EXISTS (SELECT 1 FROM aclexplode(a.attacl) x WHERE x.grantee = 'hauling_ro'::regrole::oid)")" 0
check "no write privilege of any kind on any table" "$(q $DEV "SELECT count(*) FROM pg_class c CROSS JOIN unnest(ARRAY['INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER']) p WHERE c.relkind='r' AND c.relnamespace='public'::regnamespace AND has_table_privilege('hauling_ro', c.oid, p)")" 0
check "no sequence privileges"             "$(q $DEV "SELECT count(*) FROM pg_class c WHERE c.relkind='S' AND CASE WHEN c.relkind='S' THEN has_sequence_privilege('hauling_ro', c.oid, 'USAGE,SELECT,UPDATE') END")" 0
check "no schema CREATE"                   "$(q $DEV "SELECT has_schema_privilege('hauling_ro','public','CREATE')::text")" false

echo "== 9. Extras: forbidden tables, a missing table, stray grants (database $SCR) =="
# A manual experiment someone left behind: table- and column-level grants outside the list.
psql -X -q -v ON_ERROR_STOP=1 -d $SCR -c "DROP TABLE station_heartbeat" >/dev/null
psql -X -q -v ON_ERROR_STOP=1 -d $SCR -c "GRANT SELECT ON users TO hauling_ro" -c "GRANT SELECT (what) ON audit_log TO hauling_ro" -c "GRANT SELECT ON sessions TO hauling_ro" >/dev/null
snapshot $SCR > "$LOG/snap_scr_before2.txt"
run_setup $SCR "$PW"
expect_rc "setup on a database with a missing table (exit)" 0 $RC
contains "missing table is reported (WARNING)" "$(cat $LOG/setup.out)" "table public.station_heartbeat does not exist"
contains "missing table is reported (verification row)" "$(cat $LOG/setup.out)" "MISSING: station_heartbeat"
check "stray grants on users/audit_log/sessions were revoked from hauling_ro" \
  "$(q $SCR "SELECT has_table_privilege('hauling_ro','users','SELECT')::text||has_any_column_privilege('hauling_ro','audit_log','SELECT')::text||has_any_column_privilege('hauling_ro','sessions','SELECT')::text||has_any_column_privilege('hauling_ro','schema_migrations','SELECT')::text")" falsefalsefalsefalse
check "other four tables still granted" "$(q $SCR "SELECT string_agg(relname, ',' ORDER BY relname) FROM pg_class WHERE relnamespace='public'::regnamespace AND relkind='r' AND has_table_privilege('hauling_ro', oid, 'SELECT')")" "barge_loadings,error_log,scale_readings_pending,trips"
out=$(RO $SCR 'SELECT count(*) FROM users');             contains "hauling_ro cannot read users"             "$out" "permission denied for table users"
out=$(RO $SCR 'SELECT count(*) FROM audit_log');         contains "hauling_ro cannot read audit_log"         "$out" "permission denied for table audit_log"
out=$(RO $SCR 'SELECT count(*) FROM schema_migrations'); contains "hauling_ro cannot read schema_migrations" "$out" "permission denied for table schema_migrations"
out=$(RO $SCR 'SELECT count(*) FROM sessions');          contains "hauling_ro cannot read sessions"          "$out" "permission denied for table sessions"
snapshot $SCR > "$LOG/snap_scr_after.txt"
if diff -u "$LOG/snap_scr_before2.txt" "$LOG/snap_scr_after.txt" >"$LOG/snap_scr.diff"; then ok "$SCR: snapshot unchanged (other roles' grants, default privileges, data)"; else bad "$SCR: snapshot changed:"; head -30 "$LOG/snap_scr.diff"; fi
run_setup $SCR "$PW"; expect_rc "setup on $SCR again (idempotent)" 0 $RC
snapshot $SCR > "$LOG/snap_scr_after2.txt"
check "$SCR: second run changes nothing" "$(diff "$LOG/snap_scr_after.txt" "$LOG/snap_scr_after2.txt" | wc -l | tr -d ' ')" 0
# Same script, but the forbidden table list is violated through PUBLIC: the verification must FAIL loudly (exit non-zero).
psql -X -q -d $SCR -c "GRANT SELECT ON schema_migrations TO PUBLIC" >/dev/null
run_setup $SCR "$PW"
if [[ $RC -ne 0 ]]; then ok "verification fails (exit $RC) when a forbidden table is readable via PUBLIC"; else bad "verification did not fail for a PUBLIC-readable forbidden table"; fi
contains "failing row is shown" "$(cat $LOG/setup.out)" "CANNOT select public.schema_migrations"
psql -X -q -d $SCR -c "REVOKE SELECT ON schema_migrations FROM PUBLIC" >/dev/null

echo "== 10. Live-database behaviour: concurrent locks, connection limit =="
# A busy application holds ROW EXCLUSIVE locks (normal writes); the grant step must neither wait for them nor block them.
psql -X -q -d $DEV -c "BEGIN; LOCK TABLE trips, error_log IN ROW EXCLUSIVE MODE; SELECT pg_sleep(10); COMMIT;" >/dev/null 2>&1 &
HOLD=$!; sleep 1
t0=$(date +%s); run_setup $DEV "$PW"; t1=$(date +%s)
if [[ $RC -eq 0 && $((t1 - t0)) -le 4 ]]; then ok "setup runs in $((t1 - t0)) s while writers hold ROW EXCLUSIVE on trips/error_log"; else bad "setup blocked or failed under ROW EXCLUSIVE locks (exit $RC, $((t1 - t0)) s)"; fi
wait $HOLD 2>/dev/null
# Worst case: someone holds ACCESS EXCLUSIVE (a migration). Whatever happens, setup must not hang beyond lock_timeout.
psql -X -q -d $DEV -c "BEGIN; LOCK TABLE trips IN ACCESS EXCLUSIVE MODE; SELECT pg_sleep(12); COMMIT;" >/dev/null 2>&1 &
HOLD=$!; sleep 1
t0=$(date +%s); run_setup $DEV "$PW"; t1=$(date +%s)
if [[ $((t1 - t0)) -le 9 ]]; then ok "setup under ACCESS EXCLUSIVE on trips finished in $((t1 - t0)) s (exit $RC; never waits longer than lock_timeout)"; else bad "setup waited $((t1 - t0)) s under ACCESS EXCLUSIVE"; fi
wait $HOLD 2>/dev/null
run_setup $DEV "$PW"; expect_rc "setup after the locks are gone" 0 $RC

# Connection limit on the throwaway role (so hauling_ro's own pool is not disturbed).
for i in $(seq 1 20); do PGPASSWORD=$PW psql -X -q -U hauling_ro_t -d $DEV -c "SELECT pg_sleep(8)" >/dev/null 2>&1 & done
sleep 2
out=$(RO $DEV 'SELECT 1' hauling_ro_t)
contains "21st connection is refused (limit 20)" "$out" "too many connections for role"
wait 2>/dev/null

echo "== 11. mutate.sql (scratch database $MUT, one step at a time) =="
step() { awk -v s="$1" '$0 ~ "^-- ==== STEP " s " ====" {f=1; next} /^-- ==== STEP [0-9]+ ====/ {f=0} f' test/hauling/mutate.sql; }
check "three STEP markers" "$(grep -c '^-- ==== STEP [0-9] ====' test/hauling/mutate.sql)" 3
before_trips_sum=$(q $MUT "SELECT sum(netto_jetty_kg) FROM trips")
step 1 | psql -X -q -v ON_ERROR_STOP=1 -d $MUT >"$LOG/m1.out" 2>&1; expect_rc "step 1 runs" 0 $?
check "step 1: trips 1200 - 3 deleted + 5 inserted" "$(q $MUT 'SELECT count(*) FROM trips')" 1202
check "step 1: deleted trips are gone" "$(q $MUT "SELECT count(*) FROM trips WHERE trip_id IN (md5('trip-21')::uuid, md5('trip-22')::uuid, md5('trip-23')::uuid)")" 0
check "step 1: statuses" "$(q $MUT "SELECT string_agg(status||'='||c, ',' ORDER BY status) FROM (SELECT status::text, count(*) c FROM trips GROUP BY 1) x")" "arrived_jetty=4,completed=1190,in_transit=5,pending=3"
check "step 1: weights/timestamps still consistent" "$(q $MUT "SELECT count(*) FROM trips WHERE netto_site_kg <> gross_site_kg - tare_site_kg OR NOT (cp1_timestamp < cp2_timestamp) OR NOT (cp2_timestamp < cp3_timestamp)")" 0
check "step 1: netto_jetty changed" "$([[ $(q $MUT 'SELECT sum(netto_jetty_kg) FROM trips') != "$before_trips_sum" ]] && echo yes)" yes
step 2 | psql -X -q -v ON_ERROR_STOP=1 -d $MUT >"$LOG/m2.out" 2>&1; expect_rc "step 2 runs" 0 $?
check "step 2: error_log 300 + 20" "$(q $MUT 'SELECT count(*) FROM error_log')" 320
check "step 2: new errors are recent (created_at ~ now)" "$(q $MUT "SELECT count(*) FROM error_log WHERE created_at > now() - interval '5 minutes'")" 20
check "step 2: station_heartbeat 500 + 15, max id 515" "$(q $MUT "SELECT count(*)||' '||max(id) FROM station_heartbeat")" "515 515"
check "step 2: late-arriving rows have newer id than their received_at implies" \
  "$(q $MUT "SELECT count(*) FROM station_heartbeat h WHERE id > 500 AND received_at < (SELECT max(received_at) FROM station_heartbeat WHERE id <= 500) ")" 1
step 3 | psql -X -q -v ON_ERROR_STOP=1 -d $MUT >"$LOG/m3.out" 2>&1; expect_rc "step 3 runs" 0 $?
check "step 3: scale_readings_pending replaced by 2 rows" "$(q $MUT "SELECT count(*)||' '||string_agg(no_lambung, ',' ORDER BY no_lambung) FROM scale_readings_pending")" "2 DT-070,DT-071"
check "step 3: barge qty updated" "$(q $MUT "SELECT loading_qty_kg FROM barge_loadings WHERE loading_id = md5('barge-1')::uuid")" 7777000
check "hauling_dev was not touched by mutate (still seed totals)" "$(q $DEV "SELECT (SELECT count(*) FROM trips)||' '||(SELECT count(*) FROM error_log)||' '||(SELECT count(*) FROM scale_readings_pending)")" "1200 300 4"

echo
echo "hauling_dev, hauling_ro_test and hauling_ro_test_m are left in place; hauling_ro was not dropped."
echo "logs: $LOG"
echo "PASS: $PASS  FAIL: $FAIL"
[[ $FAIL -eq 0 ]]
