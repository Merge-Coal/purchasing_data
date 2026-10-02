#!/usr/bin/env bash
# Failure-path tests for scripts/minimart_migrate.sh (the happy path lives in run_migrate_test.sh).
# Same simulated world (lib.sh: two real local Postgres clusters + a `docker` wrapper), but on other
# ports so both runners can run side by side:
#
#   bash test/minimart/migrate/run_failure_test.sh
#   MINIMART_FAIL_SECTIONS="3 4" bash test/minimart/migrate/run_failure_test.sh   # only some sections
#
# Scenarios (each asserts the exit code, that a refusing guard changed NOTHING, and that the old
# database is byte-identical afterwards):
#   1 missing extension          2 app still connected (before + during the dump)
#   3 verify mismatch + rerun    4 restore failure (mock + truncated stream), cutover and rehearse
#   5 sequence collisions        6 version guard (old server newer)
#   7 target protection          8 containers stopped / unknown
#   9 lock                      10 backup path / failing dump / disk guard
#  11 hostile data              12 secret hygiene (sentinel passwords through the whole run)
set -uo pipefail
OLD_PORT=${OLD_PORT:-55511}
NEW_PORT=${NEW_PORT:-55512}
source "$(dirname "$0")/lib.sh"

# ── sentinel passwords for scenario 12: in the environment of EVERY script run ────────────────
export MINIMART_APP_PASSWORD=$APP_PW MINIMART_RO_PASSWORD=$RO_PW
SECTIONS=${MINIMART_FAIL_SECTIONS:-"0 1 2 3 4 5 6 7 8 9 10 11 12"}
want() { case " $SECTIONS " in *" $1 "*) return 0 ;; esac; return 1; }

echo "Postgres old: $($PG14/postgres --version)   new: $($PG15/postgres --version)   bash $BASH_VERSION"
echo "scratch dir: $WORK"

# ── helpers ───────────────────────────────────────────────────────────────────────────────────
ALL_RUNS=$WORK/out/all_runs.txt; : > "$ALL_RUNS"
mig() { # like lib.sh's mig, but also keeps every output for the secret scan (scenario 12)
  OUT=$(bash "$MIG" "$@" 2>&1); RC=$?
  echo "$OUT" > "$WORK/out/last.txt"; { echo "### mig $*"; echo "$OUT"; } >> "$ALL_RUNS"
}
sha() { grep -v -E '^\\(un)?restrict ' | shasum -a 256 | cut -c1-24; }   # pg_dump >= 14.20 prints a random \restrict token
# fingerprint of the WHOLE old database: schema + data + sequence positions + large objects
old_fp() { PGHOST=127.0.0.1 PGPORT=$OLD_PORT "$PG14/pg_dump" -U mmadmin -d minimartdb -b "$@" 2>&1 | sha; }
new_fp() { PGHOST=127.0.0.1 PGPORT=$NEW_PORT "$PG15/pg_dump" -U postgres -d "${NDB:-minimart}" -b 2>&1 | sha; }
marker() { NPG -c "select coalesce(shobj_description(oid,'pg_database'), '') from pg_database where datname='minimart'"; }
new_tabs() { NP -c "select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace where c.relkind in ('r','p','v','m','S','f') and n.nspname !~ '^pg_' and n.nspname <> 'information_schema'"; }
dbs_new() { NPG -c "select string_agg(datname, ',' order by datname) from pg_database"; }
dbs_old() { PGHOST=127.0.0.1 PGPORT=$OLD_PORT "$PG14/psql" -U mmadmin -X -q -At -d postgres -c "select string_agg(datname, ',' order by datname) from pg_database"; }
COUNTS_SQL="select string_agg(format('select %L as t, count(*) as n from %I.%I', n.nspname || '.' || c.relname, n.nspname, c.relname), ' union all ' order by n.nspname, c.relname) from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.relkind in ('r','m') and n.nspname !~ '^pg_' and n.nspname <> 'information_schema'"
old_counts() { local q; q=$(OP -c "$COUNTS_SQL"); OP -c "select t || '=' || n from ($q) x order by t collate \"C\""; }
new_counts() { local q; q=$(NP -c "$COUNTS_SQL"); NP -c "select t || '=' || n from ($q) x order by t collate \"C\""; }
ndirs() { ls -1d "$WORK"/backups/$1 2>/dev/null | wc -l | tr -d ' '; }
# the "nothing changed" snapshot: old DB, new DB, marker, database lists on both servers, backup root listing
snap() { echo "old=$(old_fp) new=$(new_fp) marker=[$(marker)] newdbs=$(dbs_new) olddbs=$(dbs_old) backups=$(ls -1 "$WORK/backups" 2>/dev/null | tr '\n' ',')"; }
old_conn_count() { OP -c "select count(*) from pg_stat_activity where datname='minimartdb' and pid <> pg_backend_pid() and backend_type='client backend'"; }
# NB: killing a psql client does not stop a backend sleeping in pg_sleep: terminate the backend
kill_old_sessions() {
  OP -c "select pg_terminate_backend(pid) from pg_stat_activity where datname='minimartdb' and pid <> pg_backend_pid() and backend_type='client backend'" >/dev/null
  local i; for i in 1 2 3 4 5 6 7 8 9 10; do [ "$(old_conn_count)" = 0 ] && return 0; sleep 1; done; return 1
}
start_old_session() { ( PGHOST=127.0.0.1 PGPORT=$OLD_PORT "$PG14/psql" -U mmadmin -X -q -d minimartdb -c "select pg_sleep(600)" >/dev/null 2>&1 </dev/null & ); sleep 1; }
LOCK_PID=
hold_lock() { perl -MFcntl=:flock -e 'open(F,">>$ENV{MINIMART_MIGRATE_LOCK}") or die; flock(F,LOCK_EX); sleep 60' >/dev/null 2>&1 </dev/null & LOCK_PID=$!; sleep 1; }
release_lock() { [ -n "$LOCK_PID" ] && { kill "$LOCK_PID" 2>/dev/null; wait "$LOCK_PID" 2>/dev/null; }; LOCK_PID=; }
# fresh target: drop minimart + scratch DB + leftovers, run db/minimart_setup.sql (grants-only run: roles exist)
reset_new() {
  NPG -c "select pg_terminate_backend(pid) from pg_stat_activity where datname in ('minimart','minimart_rehearsal') and pid <> pg_backend_pid()" >/dev/null
  NPG -c "drop database if exists minimart" -c "drop database if exists minimart_rehearsal" >/dev/null 2>&1
  rm -rf "$WORK"/backups/cutover_* "$WORK"/backups/rehearsal_*
  NO_PW=1 setup_sql >/dev/null 2>&1 || bad "reset_new: setup_sql failed"
}
extra_cleanup() { release_lock; chmod -R u+w "$WORK/ro_root" 2>/dev/null; kill_old_sessions >/dev/null 2>&1; }
trap 'extra_cleanup; cleanup' EXIT

# a docker wrapper of our own (the scripts honour MINIMART_DOCKER); everything else goes to the stock mock
cat > "$WORK/bin/docker_wrap" <<'EOF'
#!/usr/bin/env bash
ORIG="${WRAP_ORIG:?}"
all=" $* "
case "$all" in
  *" pg_dump "*" -Fc "*)
    case "${WRAP_DUMP_MODE:-}" in
      fail_partial) printf 'PGDMP\001some-bytes-then-the-process-dies'; echo "pg_dump: error: simulated crash halfway" >&2; exit 1 ;;
      empty_ok)     exit 0 ;;
      garbage_ok)   printf 'this is not a pg_dump archive\n'; exit 0 ;;
      connect_after) "$ORIG" "$@"; rc=$?
        ( PGHOST=127.0.0.1 PGPORT="$WRAP_OLD_PORT" "$WRAP_PG14/psql" -U mmadmin -X -q -d minimartdb -c "select pg_sleep(600)" >/dev/null 2>&1 </dev/null & )
        sleep 1; exit $rc ;;
    esac ;;
  *" pg_dump "*" -s "*)
    [ "${WRAP_SCHEMA_FAIL:-0}" = 1 ] && { echo "pg_dump: error: simulated schema dump failure" >&2; exit 1; } ;;
  *" pg_restore "*"--single-transaction"*)
    # a restore whose input stream is cut off halfway (a REAL failure in the middle of the restore)
    if [ -n "${WRAP_RESTORE_TRUNC:-}" ]; then head -c "$WRAP_RESTORE_TRUNC" | "$ORIG" "$@"; exit "${PIPESTATUS[1]}"; fi ;;
esac
exec "$ORIG" "$@"
EOF
chmod +x "$WORK/bin/docker_wrap"
export WRAP_ORIG=$WORK/bin/docker WRAP_OLD_PORT=$OLD_PORT WRAP_PG14=$PG14
WRAP=$WORK/bin/docker_wrap
# fake df (disk guard): 1 KB free
mkdir -p "$WORK/fakebin"
printf '#!/bin/sh\necho "Filesystem 1024-blocks Used Available Capacity Mounted on"\necho "fake 100 99 1 99%% /"\n' > "$WORK/fakebin/df"; chmod +x "$WORK/fakebin/df"

# ═════════════════════════════════════════════════════════════════════════════════════════════
# 0. world, setup, a completed backup
# ═════════════════════════════════════════════════════════════════════════════════════════════
world_up
check "sentinel passwords are 24 characters" "24|24" "${#MINIMART_APP_PASSWORD}|${#MINIMART_RO_PASSWORD}"
section "0. setup + completed backup (precondition of every cutover scenario)"
OUTS=$(setup_sql); check "db/minimart_setup.sql exits 0" 0 $?
{ echo "### setup_sql"; echo "$OUTS"; } >> "$ALL_RUNS"
mig --backup-old; check "--backup-old exits 0" 0 "$RC"
BK=$(ls -1d "$WORK"/backups/pre_migration_*/ | tail -1)
[ -f "${BK}COMPLETE" ] && [ -s "${BK}old.dump" ] && ok "  backup is complete (COMPLETE + old.dump)" || bad "  backup incomplete"
BK_SIZE=$(wc -c < "${BK}old.dump" | tr -d ' ')
check "old database has the citext extension (scenario 1 depends on it)" 1 "$(OP -c "select count(*) from pg_extension where extname='citext'")"
OLD_EVENTS=$(OP -c "select count(*) from event_log")

# ═════════════════════════════════════════════════════════════════════════════════════════════
if want 1; then
section "1. MISSING EXTENSION on the new server (MOCK_HIDE_EXT=citext)"
reset_new
S=$(snap)
MOCK_HIDE_EXT=citext mig --rehearse
check "--rehearse stops before restoring: exit 1" 1 "$RC"
has "  message names the extension" "citext" "$OUT"
has "  says it is NOT available" "NOT available" "$OUT"
has "  says nothing changed" "Nothing changed" "$OUT"
hasnt "  never got as far as the restore" "Restore into" "$OUT"
check "  no minimart_rehearsal database" 0 "$(NPG -c "select count(*) from pg_database where datname='minimart_rehearsal'")"
check "  no rehearsal_* directory" 0 "$(ndirs 'rehearsal_*')"
check "  nothing at all changed (old db, new db, marker, database lists, backup root)" "$S" "$(snap)"
MOCK_HIDE_EXT=citext mig --cutover
check "--cutover stops before restoring: exit 1" 1 "$RC"
has "  message names the extension" "citext" "$OUT"
has "  says it is NOT available" "NOT available" "$OUT"
check "  no cutover_* directory" 0 "$(ndirs 'cutover_*')"
check "  target database untouched: no tables" 0 "$(new_tabs)"
check "  target marker untouched (none)" "" "$(marker)"
check "  nothing at all changed" "$S" "$(snap)"
fi

# ═════════════════════════════════════════════════════════════════════════════════════════════
if want 2; then
section "2. APP STILL CONNECTED (before the cutover, and appearing DURING the dump)"
reset_new
start_old_session
APP_BACKEND=$(OP -c "select pid from pg_stat_activity where datname='minimartdb' and pid <> pg_backend_pid() and query like 'select pg_sleep(600)%' limit 1")
S=$(snap)
mig --cutover
check "--cutover with the app connected: exit 3" 3 "$RC"
has "  lists the connection (user)" "mmadmin" "$OUT"
has "  lists the connection (pid)" "|$APP_BACKEND" "$OUT"
has "  tells to stop the app" "stop the minimart app" "$OUT"
has "  says nothing changed" "Nothing changed" "$OUT"
check "  no cutover_* directory (no dump taken)" 0 "$(ndirs 'cutover_*')"
check "  target has no tables, marker untouched" "0|" "$(new_tabs)|$(marker)"
check "  nothing at all changed" "$S" "$(snap)"
kill_old_sessions && ok "  session terminated with pg_terminate_backend" || bad "  could not terminate the sleeping session"
MINIMART_DOCKER=$WRAP WRAP_DUMP_MODE=connect_after mig --cutover
check "connection that appears DURING the dump: exit 3" 3 "$RC"
has "  says someone connected during the dump" "connected to the old database during the dump" "$OUT"
has "  says nothing was restored" "Nothing was restored" "$OUT"
hasnt "  does not claim success" "CUTOVER OK" "$OUT"
check "  the target was NOT restored (no tables)" 0 "$(new_tabs)"
check "  target marker untouched (restore never started)" "" "$(marker)"
check "  old database byte-identical to before" "$(echo "$S" | sed 's/ new=.*//')" "old=$(old_fp)"
kill_old_sessions && ok "  session terminated" || bad "  could not terminate the session"
rm -rf "$WORK"/backups/cutover_*
mig --cutover
check "the same cutover succeeds once the app is really stopped" 0 "$RC"
check "  marker cutover-complete" 1 "$(marker | grep -c 'cutover-complete')"
fi

# ═════════════════════════════════════════════════════════════════════════════════════════════
if want 3; then
section "3. VERIFY MISMATCH: a write racing the dump, then RERUN after the partial failure"
reset_new
OLD_EX=$(old_fp -T public.event_log)
N0=$(OP -c "select count(*) from event_log")
MOCK_AFTER_DUMP_SQL="set transaction_read_only = off; insert into event_log(kind) values ('x')" mig --cutover
check "the racing write really happened (mock hook; old event_log +1)" "$((N0 + 1))" "$(OP -c "select count(*) from event_log")"
check "cutover exits non-zero (1)" 1 "$RC"
has "  VERIFY FAILED" "VERIFY FAILED" "$OUT"
has "  the mismatching table is named" "public.event_log" "$OUT"
has "  says the old database is untouched" "The old database is untouched" "$OUT"
has "  tells to run --cutover again (rebuilds)" "rebuilds" "$OUT"
hasnt "  does NOT print CUTOVER OK" "CUTOVER OK" "$OUT"
hasnt "  does NOT tell the app to switch" "Next: point the app" "$OUT"
check "  marker is restored-unverified" 1 "$(marker | grep -c 'restored-unverified')"
check "  the restore did happen (tables exist) but holds the OLD count" "$N0" "$(NP -c "select count(*) from event_log")"
check "  old database: only the injected row differs (every other table byte-identical)" "$OLD_EX" "$(old_fp -T public.event_log)"
F1=$(old_fp)
rm -rf "$WORK"/backups/cutover_*
mig --cutover
check "RERUN without the hook succeeds (exit 0)" 0 "$RC"
has "  says it rebuilds the unverified earlier attempt" "never verified" "$OUT"
has "  VERIFY OK" "VERIFY OK" "$OUT"
has "  CUTOVER OK" "CUTOVER OK" "$OUT"
check "  marker is cutover-complete" 1 "$(marker | grep -c 'cutover-complete')"
check "  per-table counts old == new" "$(old_counts)" "$(new_counts)"
check "  the racing row is now in the new database" "$((N0 + 1))" "$(NP -c "select count(*) from event_log")"
check "  old database byte-identical across the whole rerun" "$F1" "$(old_fp)"
check "  --verify on its own agrees" 0 "$(bash "$MIG" --verify >/dev/null 2>&1; echo $?)"
start_old_session
mig --verify
check "--verify with the app connected still compares: exit 0" 0 "$RC"
has "  warns about the connection" "WARNING: the old database has 1 connection" "$OUT"
kill_old_sessions
fi

# ═════════════════════════════════════════════════════════════════════════════════════════════
if want 4; then
section "4. RESTORE FAILURE (mock: pg_restore cannot connect; and a restore cut off halfway)"
reset_new
F0=$(old_fp)
MOCK_RESTORE_FAIL=1 mig --cutover
check "--cutover with a failing restore: exit 1" 1 "$RC"
has "  clear message" "restore failed" "$OUT"
has "  shows pg_restore's own error" "pg_restore stderr" "$OUT"
has "  says the old database is untouched" "old database is untouched" "$OUT"
has "  says the dump is kept" "Dump kept in" "$OUT"
check "  target has NO tables" 0 "$(new_tabs)"
check "  marker is 'restoring'" 1 "$(marker | grep -c 'restoring')"
check "  final.dump kept for diagnosis" 1 "$(ls "$WORK"/backups/cutover_*/final.dump 2>/dev/null | wc -l | tr -d ' ')"
check "  old database byte-identical" "$F0" "$(old_fp)"
rm -rf "$WORK"/backups/cutover_*
mig --cutover
check "rerun without the hook succeeds" 0 "$RC"
has "  rebuilds the earlier attempt" "never verified" "$OUT"
check "  marker cutover-complete" 1 "$(marker | grep -c 'cutover-complete')"
check "  counts old == new" "$(old_counts)" "$(new_counts)"

# the restore dies in the MIDDLE (input cut off at 60%): single transaction => nothing is applied
reset_new
export WRAP_RESTORE_TRUNC=$((BK_SIZE * 6 / 10))
MINIMART_DOCKER=$WRAP mig --cutover
check "restore cut off halfway: --cutover exit 1" 1 "$RC"
has "  clear message" "restore failed" "$OUT"
check "  single transaction: target has NO tables (rolled back)" 0 "$(new_tabs)"
check "  marker is 'restoring'" 1 "$(marker | grep -c 'restoring')"
check "  old database byte-identical" "$F0" "$(old_fp)"
rm -rf "$WORK"/backups/cutover_*
unset WRAP_RESTORE_TRUNC
mig --cutover
check "  rerun without the truncation succeeds" 0 "$RC"
check "  marker cutover-complete" 1 "$(marker | grep -c 'cutover-complete')"

# rehearsal: same two failures
reset_new
S=$(snap)
MOCK_RESTORE_FAIL=1 mig --rehearse
check "--rehearse with a failing restore: exit 1" 1 "$RC"
has "  says restore FAILED" "restore FAILED" "$OUT"
hasnt "  no REHEARSAL OK" "REHEARSAL OK" "$OUT"
has "  says the scratch database was dropped" "scratch database minimart_rehearsal dropped" "$OUT"
check "  scratch DB is gone even though the run failed" 0 "$(NPG -c "select count(*) from pg_database where datname='minimart_rehearsal'")"
check "  the dump is kept" 1 "$(ls "$WORK"/backups/rehearsal_*/old.dump 2>/dev/null | wc -l | tr -d ' ')"
check "  real minimart untouched (no tables, no marker)" "0|" "$(new_tabs)|$(marker)"
rm -rf "$WORK"/backups/rehearsal_*
export WRAP_RESTORE_TRUNC=$((BK_SIZE * 6 / 10))
MINIMART_DOCKER=$WRAP mig --rehearse
unset WRAP_RESTORE_TRUNC
check "--rehearse with the restore cut off halfway: exit 1" 1 "$RC"
check "  scratch DB dropped" 0 "$(NPG -c "select count(*) from pg_database where datname='minimart_rehearsal'")"
check "  the dump is kept" 1 "$(ls "$WORK"/backups/rehearsal_*/old.dump 2>/dev/null | wc -l | tr -d ' ')"
check "  real minimart untouched" "0|" "$(new_tabs)|$(marker)"
check "  old database byte-identical" "$F0" "$(old_fp)"
rm -rf "$WORK"/backups/rehearsal_*
mig --rehearse; check "  a clean --rehearse afterwards: exit 0" 0 "$RC"
fi

# ═════════════════════════════════════════════════════════════════════════════════════════════
if want 5; then
section "5. SEQUENCE COLLISIONS (serial, identity, standalone default, bigint, empty, shared, smallint, step, negative)"
cat > "$WORK/seq_extra.sql" <<'SQL'
SET client_min_messages = warning;
-- a standalone sequence feeding a column through DEFAULT nextval(), not owned by it, never used
CREATE SEQUENCE ord_seq START 1;
CREATE TABLE sa_default (id integer PRIMARY KEY DEFAULT nextval('ord_seq'), v text);
INSERT INTO sa_default (id, v) SELECT g, 'x' FROM generate_series(1, 50) g;
-- identity column whose sequence was restarted BEHIND its data
CREATE TABLE ident (id integer GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY, v text);
INSERT INTO ident (v) SELECT 'r' FROM generate_series(1, 10);
ALTER TABLE ident ALTER COLUMN id RESTART WITH 3;
-- bigserial with a value far above the int range (sequence behind)
CREATE TABLE bigser (id bigserial PRIMARY KEY, v text);
INSERT INTO bigser (id, v) VALUES (1, 'a'), (5000000000, 'b');
-- EMPTY table with a serial: must stay untouched
CREATE TABLE emptyser (id serial PRIMARY KEY, v text);
-- one sequence feeding two tables
CREATE SEQUENCE shared_seq;
CREATE TABLE tab_a (id integer PRIMARY KEY DEFAULT nextval('shared_seq'), v text);
CREATE TABLE tab_b (id integer PRIMARY KEY DEFAULT nextval('shared_seq'), v text);
INSERT INTO tab_a (id, v) SELECT g, 'a' FROM generate_series(1, 5) g;
INSERT INTO tab_b (id, v) SELECT g, 'b' FROM generate_series(100, 110) g;
-- smallserial close to its limit
CREATE TABLE smallt (id smallserial PRIMARY KEY);
INSERT INTO smallt (id) VALUES (1), (32000);
-- increment 10
CREATE SEQUENCE step_seq INCREMENT BY 10 START 10;
CREATE TABLE step_tab (id integer PRIMARY KEY DEFAULT nextval('step_seq'));
INSERT INTO step_tab (id) VALUES (10), (20), (50);
SQL
OP -f "$WORK/seq_extra.sql" && ok "old database: sequence-collision objects loaded"
check "  customers_customer_id_seq is behind its data in the old database (5 vs 200)" "5|200" "$(OP -c "select last_value from customers_customer_id_seq")|$(OP -c "select max(customer_id) from customers")"
reset_new
mig --rehearse
check "rehearsal with every kind of behind-the-data sequence: exit 0" 0 "$RC"
has "  VERIFY OK" "VERIFY OK" "$OUT"
has "  serial repaired (5 -> 200)" "reset from 5 to 200" "$OUT"
has "  standalone default repaired (unused -> 50)" "ord_seq reset from unused to 50" "$OUT"
has "  bigint repaired to 5000000000" "to 5000000000" "$OUT"
mig --cutover
check "cutover: exit 0" 0 "$RC"
has "  VERIFY OK" "VERIFY OK" "$OUT"
has "  sequence-vs-data check ran and passed" "next value is above the largest stored value" "$OUT"
check "  EMPTY table's sequence untouched (never called)" "t" "$(NP -c "select last_value is null from pg_sequences where sequencename='emptyser_id_seq'")"
check "  identity sequence repaired: last_value 10" "10" "$(NP -c "select last_value from pg_sequences where sequencename='ident_id_seq'")"
check "  bigint sequence at 5000000000" "5000000000" "$(NP -c "select last_value from pg_sequences where sequencename='bigser_id_seq'")"
APPT=$(NP <<'SQL' 2>&1
BEGIN;
SET ROLE minimart_app;
INSERT INTO customers (email, full_name, password_hash) VALUES ('seq@example.com', 'S', 'x') RETURNING 'cust=' || customer_id;
INSERT INTO sa_default (v) VALUES ('n') RETURNING 'standalone=' || id;
INSERT INTO ident (v) VALUES ('n') RETURNING 'identity=' || id;
INSERT INTO bigser (v) VALUES ('n') RETURNING 'big=' || id;
INSERT INTO emptyser (v) VALUES ('n') RETURNING 'empty=' || id;
INSERT INTO tab_a (v) VALUES ('n') RETURNING 'shared=' || id;
INSERT INTO smallt DEFAULT VALUES RETURNING 'small=' || id;
INSERT INTO step_tab DEFAULT VALUES RETURNING 'step=' || id;
ROLLBACK;
SQL
)
has "  app insert into the repaired serial gets 201" "cust=201" "$APPT"
has "  standalone-default sequence: next is 51" "standalone=51" "$APPT"
has "  identity: next is 11" "identity=11" "$APPT"
has "  bigint: next is 5000000001" "big=5000000001" "$APPT"
has "  EMPTY table: first value is 1" "empty=1" "$APPT"
has "  shared sequence: next is 111 (above BOTH tables)" "shared=111" "$APPT"
has "  smallserial: next is 32001" "small=32001" "$APPT"
has "  increment 10: next is 60" "step=60" "$APPT"
hasnt "  no duplicate-key error on any insert" "duplicate key" "$APPT"
hasnt "  no other error" "ERROR" "$APPT"
# a sequence with a NEGATIVE increment: not reset, warned, no crash
cat > "$WORK/neg_seq.sql" <<'SQL'
SET client_min_messages = warning;
CREATE SEQUENCE neg_seq INCREMENT BY -1 MINVALUE -1000 MAXVALUE -1 START -1;
CREATE TABLE neg_tab (id integer PRIMARY KEY DEFAULT nextval('neg_seq'), v text);
INSERT INTO neg_tab (v) VALUES ('a'), ('b'), ('c');
SQL
OP -f "$WORK/neg_seq.sql" && ok "old database: descending sequence loaded (ids -1,-2,-3)"
reset_new
mig --rehearse
check "rehearsal with a NEGATIVE-increment sequence: exit 0 (no crash, no false VERIFY FAILED)" 0 "$RC"
has "  warned: negative increment, not reset" "negative increment: not reset" "$OUT"
has "  VERIFY OK" "VERIFY OK" "$OUT"
hasnt "  no false 'sequence collision' for the descending sequence" "sequence collision" "$OUT"
OP -c "drop table neg_tab" -c "drop sequence neg_seq" >/dev/null
rm -rf "$WORK"/backups/rehearsal_*
fi

# ═════════════════════════════════════════════════════════════════════════════════════════════
if want 6; then
section "6. VERSION GUARD: old server NEWER than the new server"
mkcontainer rev-old "$PG15" "$NEW_PORT" $'POSTGRES_USER=postgres\nPOSTGRES_DB=postgres'
mkcontainer rev-new "$PG14" "$OLD_PORT" $'POSTGRES_USER=mmadmin'
reset_new
S=$(snap)
MINIMART_OLD_CONTAINER=rev-old MINIMART_NEW_CONTAINER=rev-new MINIMART_NEW_PGUSER=mmadmin mig --rehearse
check "--rehearse: exit 1" 1 "$RC"
has "  says NEWER" "NEWER" "$OUT"
has "  says nothing changed" "Nothing changed" "$OUT"
hasnt "  stopped before touching anything (no restore)" "Rehearsal into" "$OUT"
MINIMART_OLD_CONTAINER=rev-old MINIMART_NEW_CONTAINER=rev-new MINIMART_NEW_PGUSER=mmadmin mig --cutover
check "--cutover: exit 1" 1 "$RC"
has "  says NEWER" "NEWER" "$OUT"
check "  nothing changed anywhere (databases of both clusters, backup root, old db)" "$S" "$(snap)"
check "  no rehearsal / cutover directory" "0|0" "$(ndirs 'rehearsal_*')|$(ndirs 'cutover_*')"
fi

# ═════════════════════════════════════════════════════════════════════════════════════════════
if want 7; then
section "7. TARGET PROTECTION"
# a: marker 'restoring' with leftover tables -> rebuilt
reset_new
NP -c "create table leftover(a int); insert into leftover values (1)" >/dev/null
NPG -c "COMMENT ON DATABASE minimart IS 'minimart-migration: restoring 2026-01-01T00:00:00Z'"
mig --cutover
check "marker 'restoring' + leftover table: cutover exit 0 (rebuilt)" 0 "$RC"
has "  says it rebuilds the earlier attempt" "will be dropped and rebuilt" "$OUT"
check "  leftover table is gone" "" "$(NP -c "select to_regclass('public.leftover')")"
check "  marker cutover-complete" 1 "$(marker | grep -c 'cutover-complete')"
# c (needs a populated target): the rehearsal database name equal to the real one
S=$(snap); C=$(new_counts)
MINIMART_REHEARSAL_DB=minimart mig --rehearse
check "MINIMART_REHEARSAL_DB=minimart: --rehearse refuses (exit 3)" 3 "$RC"
has "  says refusing" "refusing" "$OUT"
check "  the real database is untouched (counts, content, marker)" "$S" "$(snap)"
check "  counts still equal" "$C" "$(new_counts)"
# cutover-complete + rerun
mig --cutover; check "marker cutover-complete: --cutover refused (exit 3)" 3 "$RC"
check "  state unchanged" "$S" "$(snap)"
# b: non-empty target without our marker
reset_new
NP -c "create table intruder(a int); insert into intruder values (1), (2)" >/dev/null
S=$(snap)
mig --cutover
check "non-empty minimart, NO marker: refused (exit 3)" 3 "$RC"
has "  says it is not empty / refuses to touch it" "not empty" "$OUT"
has "  says nothing changed" "Nothing changed" "$OUT"
check "  the foreign data is intact" 2 "$(NP -c "select count(*) from intruder")"
check "  no cutover directory, no dump" 0 "$(ndirs 'cutover_*')"
check "  nothing at all changed" "$S" "$(snap)"
NPG -c "COMMENT ON DATABASE minimart IS 'owned by somebody else'"
mig --cutover
check "  a foreign comment on the database is not our marker: still refused (exit 3)" 3 "$RC"
check "  data intact" 2 "$(NP -c "select count(*) from intruder")"
NP -c "drop table intruder; create sequence only_a_sequence" >/dev/null
mig --cutover
check "  a lone sequence also counts as 'not empty': refused (exit 3)" 3 "$RC"
check "  sequence intact" 1 "$(NP -c "select count(*) from pg_class where relname='only_a_sequence'")"
# informational: what the rehearsal does with a pre-existing database named by MINIMART_REHEARSAL_DB
NPG -c "drop database if exists decoy_db_x" -c "create database decoy_db_x" >/dev/null 2>&1
PGHOST=127.0.0.1 PGPORT=$NEW_PORT "$PG15/psql" -U postgres -X -q -d decoy_db_x -c "create table precious(a int)" >/dev/null
MINIMART_REHEARSAL_DB=decoy_db_x mig --rehearse
if [ "$(NPG -c "select count(*) from pg_database where datname='decoy_db_x'")" = 0 ] && grep -q "exists from an earlier run: dropping it first" <<< "$OUT"; then
  echo "  NOTE  (not a check) MINIMART_REHEARSAL_DB=<any existing database> is DROPPED by --rehearse without any ownership marker: only a mistyped env var can do this"
else NPG -c "drop database if exists decoy_db_x" >/dev/null; fi
fi

# ═════════════════════════════════════════════════════════════════════════════════════════════
if want 8; then
section "8. CONTAINERS: stopped / unknown"
reset_new
S=$(snap)
rm -f "$WORK/mock/minimart-postgres-1/running"
for m in --inspect --backup-old --rehearse --cutover --verify; do
  MINIMART_BACKUP_ROOT=$WORK/bk8 mig "$m"
  check "old container stopped: $m exits 1" 1 "$RC"
  has "  $m: clear message" "container minimart-postgres-1 is not running" "$OUT"
done
check "  --verify cannot compare without the old database (documented: exit 1, not 'OK')" 0 "$(grep -c 'VERIFY OK' <<< "$OUT")"
check "  no backup root / rehearsal / cutover directory was created" "0|0|0" "$([ -d "$WORK/bk8" ] && echo 1 || echo 0)|$(ndirs 'rehearsal_*')|$(ndirs 'cutover_*')"
mig --rollback-info; check "  --rollback-info still works with the old container stopped" 0 "$RC"
touch "$WORK/mock/minimart-postgres-1/running"
check "  nothing changed" "$S" "$(snap)"
rm -f "$WORK/mock/mmi-postgres/running"
for m in --rehearse --cutover --verify; do
  mig "$m"
  check "new container stopped: $m exits 1" 1 "$RC"
  has "  $m: clear message" "container mmi-postgres is not running" "$OUT"
done
MINIMART_BACKUP_ROOT=$WORK/bk8 mig --backup-old
check "  --backup-old only needs the OLD container: exit 0 with the new one stopped" 0 "$RC"
mig --inspect; check "  --inspect only needs the old container: exit 0" 0 "$RC"
mig --rollback-info; check "  --rollback-info needs neither: exit 0" 0 "$RC"
touch "$WORK/mock/mmi-postgres/running"
check "  no rehearsal / cutover directory created while it was stopped" "0|0" "$(ndirs 'rehearsal_*')|$(ndirs 'cutover_*')"
for m in --inspect --backup-old --rehearse --cutover --verify; do
  MINIMART_OLD_CONTAINER=no-such-container MINIMART_BACKUP_ROOT=$WORK/bk8b mig "$m"
  check "unknown OLD container name: $m exits 1" 1 "$RC"
  has "  $m: message names it" "container no-such-container is not running" "$OUT"
done
for m in --rehearse --cutover --verify; do
  MINIMART_NEW_CONTAINER=no-such-container mig "$m"
  check "unknown NEW container name: $m exits 1" 1 "$RC"
  has "  $m: message names it" "container no-such-container is not running" "$OUT"
done
check "  nothing changed by all of that" "$S" "$(snap)"
fi

# ═════════════════════════════════════════════════════════════════════════════════════════════
if want 9; then
section "9. LOCK: one mutating run at a time; read-only modes unaffected"
reset_new
mig --cutover; check "precondition: a populated, verified target" 0 "$RC"
S=$(snap)
hold_lock
for m in --backup-old --rehearse --cutover; do
  mig "$m"
  check "lock held: $m exits 3" 3 "$RC"
  has "  $m: 'another minimart_migrate.sh run' message" "another minimart_migrate.sh run" "$OUT"
  has "  $m: says nothing changed" "nothing changed" "$OUT"
done
check "  nothing changed (databases, backup root, marker, content)" "$S" "$(snap)"
mig --inspect;       check "read-only --inspect works while the lock is held" 0 "$RC"; hasnt "  not blocked" "another minimart_migrate.sh run" "$OUT"
mig --verify;        check "read-only --verify works while the lock is held" 0 "$RC"; has "  VERIFY OK" "VERIFY OK" "$OUT"
mig --rollback-info; check "read-only --rollback-info works while the lock is held" 0 "$RC"
release_lock
mig --backup-old; check "after the lock is released the same --backup-old runs: exit 0" 0 "$RC"
# a genuinely concurrent run: a real --rehearse in the background, a second mutating run meanwhile
rm -f "$WORK/out/bg.rc"
( bash "$MIG" --rehearse > "$WORK/out/bg_rehearse.txt" 2>&1; echo $? > "$WORK/out/bg.rc" ) &
BGP=$!
for i in $(seq 1 40); do grep -q "Preflight" "$WORK/out/bg_rehearse.txt" 2>/dev/null && break; sleep 0.25; done
S=$(ls -1 "$WORK/backups" | tr '\n' ',')
mig --backup-old; check "while a real --rehearse runs: --backup-old exits 3" 3 "$RC"
has "  'another minimart_migrate.sh run' message" "another minimart_migrate.sh run" "$OUT"
mig --cutover;    check "while a real --rehearse runs: --cutover exits 3" 3 "$RC"
check "  no new backup directory appeared" "$S" "$(ls -1 "$WORK/backups" | tr '\n' ',' | sed 's/rehearsal_[0-9_]*,//')"
wait $BGP
check "  the first (background) --rehearse finished OK and was not disturbed" "0" "$(cat "$WORK/out/bg.rc" 2>/dev/null)"
has "  its output says REHEARSAL OK" "REHEARSAL OK" "$(cat "$WORK/out/bg_rehearse.txt")"
cat "$WORK/out/bg_rehearse.txt" >> "$ALL_RUNS"
fi

# ═════════════════════════════════════════════════════════════════════════════════════════════
if want 10; then
section "10. BACKUP PATH, a dump that dies halfway, disk guard"
reset_new
S=$(snap)
if [ "$(id -u)" != 0 ]; then
  mkdir -p "$WORK/ro_root"; chmod 555 "$WORK/ro_root"
  MINIMART_BACKUP_ROOT=$WORK/ro_root/bk mig --backup-old
  check "non-writable backup root: --backup-old exits 1" 1 "$RC"
  has "  clear message" "cannot create" "$OUT"
  check "  no directory and no COMPLETE left behind" "0" "$(find "$WORK/ro_root" -mindepth 1 2>/dev/null | wc -l | tr -d ' ')"
  chmod 755 "$WORK/ro_root"
else echo "  SKIP  non-writable path test (running as root)"; fi
: > "$WORK/afile"
MINIMART_BACKUP_ROOT=$WORK/afile/bk mig --backup-old
check "backup root below a regular file: exit 1" 1 "$RC"
has "  clear message" "cannot create" "$OUT"
# a dump that dies halfway (after writing some bytes)
BK10=$WORK/bk10
MINIMART_BACKUP_ROOT=$BK10 MINIMART_DOCKER=$WRAP WRAP_DUMP_MODE=fail_partial mig --backup-old
check "pg_dump dies after writing some bytes: --backup-old exits 1" 1 "$RC"
has "  says the dump failed" "pg_dump of the old database failed" "$OUT"
check "  no old.dump* file remains" 0 "$(find "$BK10" -name 'old.dump*' | wc -l | tr -d ' ')"
check "  no COMPLETE file remains" 0 "$(find "$BK10" -name COMPLETE | wc -l | tr -d ' ')"
hasnt "  no OK line" " OK " "$OUT"
MINIMART_BACKUP_ROOT=$BK10 mig --cutover
check "  and --cutover treats that root as having no backup: exit 3" 3 "$RC"
has "  tells to run --backup-old" "--backup-old" "$OUT"
MINIMART_BACKUP_ROOT=$BK10 MINIMART_DOCKER=$WRAP WRAP_DUMP_MODE=garbage_ok mig --backup-old
check "pg_dump exits 0 but wrote garbage: exit 1" 1 "$RC"
has "  says the dump cannot be read" "cannot read the dump" "$OUT"
check "  no old.dump*, no COMPLETE" "0|0" "$(find "$BK10" -name 'old.dump*' | wc -l | tr -d ' ')|$(find "$BK10" -name COMPLETE | wc -l | tr -d ' ')"
MINIMART_BACKUP_ROOT=$BK10 MINIMART_DOCKER=$WRAP WRAP_DUMP_MODE=empty_ok mig --backup-old
check "pg_dump exits 0 but wrote nothing: exit 1" 1 "$RC"
has "  says empty" "empty" "$OUT"
check "  no old.dump*, no COMPLETE" "0|0" "$(find "$BK10" -name 'old.dump*' | wc -l | tr -d ' ')|$(find "$BK10" -name COMPLETE | wc -l | tr -d ' ')"
# the second dump (schema) fails: the first one is on disk but the backup must NOT look complete
BK10b=$WORK/bk10b
MINIMART_BACKUP_ROOT=$BK10b MINIMART_DOCKER=$WRAP WRAP_SCHEMA_FAIL=1 mig --backup-old
check "schema dump fails after the data dump succeeded: exit 1" 1 "$RC"
has "  says schema dump failed" "schema dump failed" "$OUT"
check "  no COMPLETE file" 0 "$(find "$BK10b" -name COMPLETE | wc -l | tr -d ' ')"
MINIMART_BACKUP_ROOT=$BK10b mig --cutover
check "  an incomplete backup directory does not satisfy the cutover guard: exit 3" 3 "$RC"
check "  nothing changed anywhere but the scratch backup roots" "$(echo "$S" | sed 's/ backups=.*//')" "$(snap | sed 's/ backups=.*//')"
# disk guard: fake df reports 1 KB free
S=$(snap)
PATH="$WORK/fakebin:$PATH" mig --rehearse
check "disk guard (1 KB free): --rehearse exits 1" 1 "$RC"
has "  says not enough disk space" "not enough disk space" "$OUT"
PATH="$WORK/fakebin:$PATH" mig --cutover
check "disk guard: --cutover exits 1" 1 "$RC"
has "  says not enough disk space" "not enough disk space" "$OUT"
check "  nothing changed (no scratch DB, no dumps, no restore)" "$S" "$(snap)"
fi

# ═════════════════════════════════════════════════════════════════════════════════════════════
if want 11; then
section "11. HOSTILE DATA through the whole rehearsal + cutover"
cat > "$WORK/hostile.sql" <<'SQL'
SET client_min_messages = warning;
-- quoted sequence name with a space and capitals, behind its data
CREATE SEQUENCE "My Seq";
CREATE TABLE hostile_seq (id integer PRIMARY KEY DEFAULT nextval('"My Seq"'), v text);
INSERT INTO hostile_seq (id, v) VALUES (1, 'a'), (2, 'b'), (3, 'c');
CREATE VIEW hostile_view AS SELECT id, v FROM hostile_seq;
-- zero rows, text column
CREATE TABLE hostile_empty (note text);
-- 1,000,000-byte bytea + jsonb with unicode / emoji / escapes
CREATE TABLE hostile_big (id integer PRIMARY KEY, b bytea, j jsonb);
INSERT INTO hostile_big VALUES (1, decode(repeat('ab', 1000000), 'hex'),
  '{"emoji":"😀🎉","cn":"采购订单","esc":"quote \" and \\ backslash","nl":"a\nb\ttab","nested":{"arr":[1,2.50,null,true]}}'::jsonb);
-- a schema named with a hyphen
CREATE SCHEMA "legacy-data";
CREATE TABLE "legacy-data"."t-1" (id serial PRIMARY KEY, "col-x" text);
INSERT INTO "legacy-data"."t-1" ("col-x") VALUES ('x'), ('y');
CREATE VIEW "legacy-data"."v-1" AS SELECT * FROM "legacy-data"."t-1";
-- text primary key holding the separators used by the verify output: | tab newline CR backslash
CREATE TABLE hostile_pk (k text PRIMARY KEY, n integer);
INSERT INTO hostile_pk VALUES ('a|b', 1), (E'tab\there', 2), (E'new\nline', 3), (E'x|y\nz', 4), ('|', 5), ('plain', 6),
  (E'\r\n', 7), ('  spaces  ', 8), ('日本語|テスト', 9), (E'back\\slash', 10), ('NULL', 11), ('~', 12);
SQL
OP -f "$WORK/hostile.sql" && ok "old database: hostile objects loaded"
check "  bytea is 1,000,000 bytes in the old database" 1000000 "$(OP -c "select octet_length(b) from hostile_big")"
reset_new
mig --rehearse
check "rehearsal with hostile data: exit 0" 0 "$RC"
has "  VERIFY OK" "VERIFY OK" "$OUT"
has "  REHEARSAL OK" "REHEARSAL OK" "$OUT"
has "  the hyphenated schema's table is compared" "legacy-data.t-1" "$OUT"
has "  the text-PK table is compared" "public.hostile_pk  rows=12" "$OUT"
has "  the empty table is compared" "public.hostile_empty  rows=0" "$OUT"
has "  quoted sequence repaired (3)" "My Seq reset from unused to 3" "$OUT"
hasnt "  no FAIL line" "  FAIL " "$OUT"
hasnt "  no psql error" "ERROR" "$OUT"
F11=$(old_fp)
mig --cutover
check "cutover with hostile data: exit 0" 0 "$RC"
has "  VERIFY OK" "VERIFY OK" "$OUT"
has "  CUTOVER OK" "CUTOVER OK" "$OUT"
has "  ownership changed (views, sequences, schema included)" "changed to minimart_owner" "$OUT"
has "  every object owned by minimart_owner" "every object is owned by minimart_owner" "$OUT"
check "  old database byte-identical after rehearsal + cutover" "$F11" "$(old_fp)"
check "  bytea: 1,000,000 bytes, same md5" "1000000|$(OP -c "select md5(b) from hostile_big")" "$(NP -c "select octet_length(b) || '|' || md5(b) from hostile_big")"
check "  jsonb: identical text" "$(OP -c "select md5(j::text) from hostile_big")" "$(NP -c "select md5(j::text) from hostile_big")"
check "  jsonb: emoji (8 bytes) and CJK (12 bytes) survived" "8|12" "$(NP -c "select octet_length(j->>'emoji') || '|' || octet_length(j->>'cn') from hostile_big")"
check "  text PK: all 12 rows and the separator keys" "12|5" "$(NP -c "select count(*) || '|' || count(*) filter (where k in ('a|b', E'tab\there', E'new\nline', E'x|y\nz', '|')) from hostile_pk")"
check "  text PK: whole table identical (md5 of every key + value)" "$(OP -c "select md5(string_agg(k || '#' || n, '~' order by n)) from hostile_pk")" "$(NP -c "select md5(string_agg(k || '#' || n, '~' order by n)) from hostile_pk")"
check "  multibyte PK intact (19 bytes)" 19 "$(NP -c "select octet_length(k) from hostile_pk where n = 9")"
check "  quoted sequence \"My Seq\" owned by minimart_owner" "minimart_owner" "$(NP -c "select pg_get_userbyid(relowner) from pg_class where relname='My Seq'")"
check "  views owned by minimart_owner (public + hyphen schema)" "minimart_owner,minimart_owner" "$(NP -c "select string_agg(pg_get_userbyid(relowner), ',') from pg_class where relname in ('hostile_view','v-1')")"
check "  schema legacy-data owned by minimart_owner" "minimart_owner" "$(NP -c "select pg_get_userbyid(nspowner) from pg_namespace where nspname='legacy-data'")"
check "  grants: app has DML on the hyphen-schema table, USAGE on its schema and on \"My Seq\"" "true|true|true|true" \
  "$(NP -c "select has_table_privilege('minimart_app', '\"legacy-data\".\"t-1\"', 'INSERT') || '|' || has_schema_privilege('minimart_app', 'legacy-data', 'USAGE') || '|' || has_sequence_privilege('minimart_app', '\"My Seq\"', 'USAGE') || '|' || has_sequence_privilege('minimart_app', '\"legacy-data\".\"t-1_id_seq\"', 'USAGE')")"
check "  ro role can use the hyphen schema (SELECT comes with db/minimart_ro_grants.sql)" "t" "$(NP -c "select has_schema_privilege('minimart_ro', 'legacy-data', 'USAGE')")"
check "  setup report: no table the app cannot DML, none not owned by owner" "0|0" "$(NO_PW=1 setup_sql -v dbname=minimart -A -t -F'|' | grep '^minimart|' | awk -F'|' '{print $5"|"$6}')"
APPT=$(NP <<'SQL' 2>&1
BEGIN;
SET ROLE minimart_app;
INSERT INTO hostile_seq (v) VALUES ('n') RETURNING 'myseq=' || id;
INSERT INTO "legacy-data"."t-1" ("col-x") VALUES ('n') RETURNING 'hyphen=' || id;
INSERT INTO hostile_pk VALUES ('new|key', 99);
SELECT 'view=' || count(*) FROM hostile_view;
ROLLBACK;
SQL
)
has "  app: next \"My Seq\" value is 4 (sequence reset coped with the quoting)" "myseq=4" "$APPT"
has "  app: hyphen-schema serial continues at 3" "hyphen=3" "$APPT"
has "  app: view readable (3 old rows + the new one)" "view=4" "$APPT"
hasnt "  app: no errors" "ERROR" "$APPT"
# does --verify really see a change in a '|'-bearing key? (mutate a kept rehearsal copy)
MINIMART_KEEP_REHEARSAL=1 mig --rehearse; check "rehearsal copy kept for the mutation checks" 0 "$RC"
export MINIMART_NEW_DB=minimart_rehearsal
mig --verify; check "verify of the exact copy: exit 0" 0 "$RC"
NDB=minimart_rehearsal NP -c "update hostile_pk set k = 'a|c' where k = 'a|b'" >/dev/null
mig --verify
check "verify detects a changed key containing '|': exit 1" 1 "$RC"
has "  names the table and the hash" "hostile_pk" "$OUT"
has "  as a content (hash) difference" "hash=" "$OUT"
NDB=minimart_rehearsal NP -c "update hostile_pk set k = 'a|b' where k = 'a|c'" >/dev/null
NDB=minimart_rehearsal NP -c "update hostile_pk set n = n + 100 where k = E'x|y\nz'" >/dev/null
mig --verify; check "verify detects a changed value next to a newline-bearing key: exit 1" 1 "$RC"
NDB=minimart_rehearsal NP -c "update hostile_pk set n = n - 100 where k = E'x|y\nz'" >/dev/null
mig --verify; check "reverted: verify exit 0 again" 0 "$RC"
unset MINIMART_NEW_DB
NPG -c "drop database minimart_rehearsal" >/dev/null
rm -rf "$WORK"/backups/rehearsal_*
# a table whose NAME contains '|' (verify output uses '|' as the separator)
cat > "$WORK/pipe_tab.sql" <<'SQL'
SET client_min_messages = warning;
CREATE TABLE "pipe|tab" ("c|ol" integer PRIMARY KEY, v numeric);
INSERT INTO "pipe|tab" VALUES (1, 1.5), (2, 2.5);
SQL
OP -f "$WORK/pipe_tab.sql" && ok "old database: table with '|' in its name loaded"
mig --rehearse
check "rehearsal with a '|' in a TABLE name: exit 0" 0 "$RC"
has "  VERIFY OK (no false 'extra table in new database')" "VERIFY OK" "$OUT"
hasnt "  no false extra-table failure" "extra table in new database" "$OUT"
OP -c 'drop table "pipe|tab"' >/dev/null
rm -rf "$WORK"/backups/rehearsal_*
fi

# ═════════════════════════════════════════════════════════════════════════════════════════════
if want 12; then
section "12. SECRET HYGIENE: sentinel passwords were in the environment of every run"
check "sentinel passwords were exported to every script run" "2" "$(env | grep -c -E '^MINIMART_(APP|RO)_PASSWORD=')"
check "docker command log is not empty (the scan is meaningful)" "1" "$([ "$(grep -c 'pg_dump' "$MOCK_LOG")" -gt 10 ] && echo 1 || echo 0)"
check "all runs' output was captured (the scan is meaningful)" "1" "$([ "$(grep -c '^### mig' "$ALL_RUNS")" -gt 50 ] && echo 1 || echo 0)"
echo "$MINIMART_APP_PASSWORD" > "$WORK/out/zz_canary.txt"
check "scan self-test: a planted canary IS found by the scan" 1 "$(grep -rlaF -- "$MINIMART_APP_PASSWORD" "$WORK"/out 2>/dev/null | wc -l | tr -d ' ')"
rm -f "$WORK/out/zz_canary.txt"
for who in app ro; do
  if [ "$who" = app ]; then pw=$MINIMART_APP_PASSWORD; else pw=$MINIMART_RO_PASSWORD; fi
  label="$who password"
  check "$label not in any script stdout/stderr ($ALL_RUNS)" 0 "$(grep -cF -- "$pw" "$ALL_RUNS")"
  check "$label not in the migration log ($MINIMART_MIGRATE_LOG)" 0 "$(grep -cF -- "$pw" "$MINIMART_MIGRATE_LOG" 2>/dev/null)"
  check "$label not in the docker command lines ($MOCK_LOG)" 0 "$(grep -cF -- "$pw" "$MOCK_LOG")"
  check "$label not in any file under out/ or the backup roots" 0 "$(grep -rlaF -- "$pw" "$WORK"/out "$WORK"/backups "$WORK"/bk* 2>/dev/null | wc -l | tr -d ' ')"
done
check "the migration log exists and has entries" "1" "$([ "$(grep -c . "$MINIMART_MIGRATE_LOG")" -gt 20 ] && echo 1 || echo 0)"
fi

world_summary
