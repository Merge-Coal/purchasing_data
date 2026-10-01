#!/usr/bin/env bash
# End-to-end test of scripts/hauling_sync.sh (+ db/hauling_ch_schema.sql, db/hauling_sync.sql)
# against a REAL scratch ClickHouse server and the local Homebrew Postgres.
#
#   bash test/hauling/ch/run_sync_test.sh
#
# What it starts / uses:
#   * a scratch `clickhouse server` (Homebrew binary) with its own config on ports
#     $TEST_CH_TCP (19101) / $TEST_CH_HTTP (18101), server time zone Asia/Makassar (NOT UTC,
#     like the production host), a named collection `pg_hauling` -> 127.0.0.1 / $PGDB / hauling_ro
#     with the password taken from the environment (from_env), exactly like production;
#   * local Postgres database hauling_mirror_b (created from test/hauling/pg_schema.sql, left
#     in place at the end) and the REAL read-only role hauling_ro (db/hauling_ro_setup.sql:
#     timezone=UTC, datestyle='ISO, YMD'). The local Postgres uses trust auth, so the password
#     is never checked here; failures are provoked with REVOKE instead.
# It never touches any other database, never drops or alters the role hauling_ro itself, and
# only revokes/re-grants SELECT on tables of hauling_mirror_b.
# Scratch files go to $HAULING_TEST_DIR (default: a fresh mktemp dir, removed at the end
# unless HAULING_TEST_KEEP=1).
#
# Note: production runs ClickHouse 24.8, the local binary is newer (see the final report /
# the "version skew" list printed at the end).
set -uo pipefail

cd "$(dirname "$0")/../../.."
REPO=$PWD
T=test/hauling/ch
PGDB=${PGDB:-hauling_mirror_b}
PGUSER_RO=hauling_ro
TCP=${TEST_CH_TCP:-19101}
HTTP=${TEST_CH_HTTP:-18101}
CH_TZ=${TEST_CH_TZ:-Asia/Makassar}
WORK=${HAULING_TEST_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/hauling_ch_test.XXXXXX")}
rm -rf "$WORK/data" "$WORK/out"
mkdir -p "$WORK"/{data,tmp,user_files,format_schemas,out}
export PGHOST=${PGHOST:-/tmp}
unset PGPASSWORD PGDATABASE HAULING_CH_CLIENT HAULING_SYNC_LOG HAULING_SYNC_LOCK HAULING_SYNC_TIMEOUT
RO_PW=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)

PASS=0; FAIL=0; SKIP=0; SERVER_PID=; NOTZ_ROLE=hauling_ro_b_notz
ok()   { PASS=$((PASS+1)); echo "  PASS  $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL  $1"; }
skip() { SKIP=$((SKIP+1)); echo "  SKIP  $1"; }
check() { # check "description" expected actual
  if [[ "$3" == "$2" ]]; then ok "$1"; else bad "$1 — expected [$2] got [$3]"; fi
}

CH()  { clickhouse client --port "$TCP" "$@"; }
chq() { CH -q "$1" 2>&1; }                       # chq "sql" -> output (TSV by default)
PGS() { psql -X -q -tA -v ON_ERROR_STOP=1 -d "$PGDB" -c "$1"; }
PGF() { psql -X -q -v ON_ERROR_STOP=1 -d "$PGDB" -f "$1" >/dev/null; }
PGSU() { psql -X -q -tA -v ON_ERROR_STOP=1 -d postgres -c "$1"; }

LOG=$WORK/hauling-ch-sync.log
LOCK=$WORK/hauling-ch-sync.lock
SYNC="$REPO/scripts/hauling_sync.sh"
sync_run() { # sync_run [args...] -> RC, output in $WORK/out/last.txt
  HAULING_CH_CLIENT="clickhouse client --port $TCP" HAULING_SYNC_LOG=$LOG HAULING_SYNC_LOCK=$LOCK \
    bash "$SYNC" "$@" >"$WORK/out/last.txt" 2>&1; RC=$?
}
last_log() { tail -n "${1:-1}" "$LOG" 2>/dev/null; }
state_rows()  { chq "SELECT count() FROM hauling._sync_state"; }
state_max()   { chq "SELECT toString(max(synced_through)) FROM hauling._sync_state"; }
state_modes() { chq "SELECT arrayStringConcat(groupArray(mode), ',') FROM (SELECT mode FROM hauling._sync_state ORDER BY run_at)"; }

stop_server() {
  if [[ -n "$SERVER_PID" ]]; then
    # SIGTERM = graceful shutdown. (Not `SYSTEM SHUTDOWN`: it signals the whole process group,
    # which would kill this test script too.)
    kill "$SERVER_PID" 2>/dev/null
    for _ in $(seq 1 80); do kill -0 "$SERVER_PID" 2>/dev/null || break; sleep 0.25; done
    kill -9 "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null
    SERVER_PID=
  fi
}
cleanup() {
  stop_server
  # restore SELECT in case a failure test was interrupted; drop only OUR extra role
  PGS "GRANT SELECT ON trips, barge_loadings, scale_readings_pending, station_heartbeat, error_log TO $PGUSER_RO" >/dev/null 2>&1
  PGSU "DROP OWNED BY $NOTZ_ROLE; DROP ROLE IF EXISTS $NOTZ_ROLE" >/dev/null 2>&1
  [[ "${HAULING_TEST_KEEP:-0}" = 1 ]] || rm -rf "$WORK/data" "$WORK/tmp"
}
trap cleanup EXIT

# ── canonical per-row dumps: same bytes from Postgres and ClickHouse ─────────
# strings are compared as hex of their UTF-8 bytes, timestamps as epoch milliseconds
# (PG: floor(extract(epoch)*1000) truncates like ClickHouse), NULL as \N on both sides.
hx()  { echo "encode(convert_to($1, 'UTF8'), 'hex')"; }   # Postgres
ms()  { echo "floor(extract(epoch from $1) * 1000)::bigint"; }
chx() { echo "lower(hex($1))"; }
pg_dump_table() { # pg_dump_table table -> sorted canonical rows
  local q
  case "$1" in
  trips) q="SELECT trip_id, date, status::text, no_tiket, $(hx no_lambung), jetty_destination::text, coal_quality::text,
     $(hx cuaca_mmi), tare_site_kg, $(ms cp1_timestamp), gross_site_kg, netto_site_kg, $(ms cp2_timestamp), gross_jetty_kg,
     netto_jetty_kg, compare_gross_kg, deviasi_kg, $(ms cp3_timestamp), adjustment_kg, is_locked::int, session_id,
     tare_jetty_kg, $(hx stockpile_code), $(hx tare_source), $(hx gross_source), $(hx cp1_event_id), $(hx cp2_event_id) FROM trips" ;;
  barge_loadings) q="SELECT loading_id, jetty::text, $(hx barge_name), $(hx tug_boat_name), loading_date, loading_qty_kg,
     $(ms created_at), $(hx stockpile_code) FROM barge_loadings" ;;
  scale_readings_pending) q="SELECT $(hx no_lambung), $(hx reading_type), trim_scale(weight_kg)::text, $(ms measured_at), $(ms created_at)
     FROM scale_readings_pending" ;;
  error_log) q="SELECT error_id, $(hx source), $(hx level), $(hx message), $(hx 'context::text'), $(ms created_at) FROM error_log" ;;
  station_heartbeat) q="SELECT id, $(ms received_at), $(hx station_id), $(hx station_version), $(ms pc_time), skew_ms,
     scale_connected::int, trucks_on_site, sync_pending, sync_dead, oldest_job_min, $(ms last_push_ok_at), uptime_s FROM station_heartbeat" ;;
  esac
  psql -X -q -tA -F $'\t' -P null='\N' -v ON_ERROR_STOP=1 -d "$PGDB" -c "$q" | LC_ALL=C sort
}
ch_dump_table() {
  local q
  case "$1" in
  trips) q="SELECT trip_id, date, status, no_tiket, $(chx no_lambung), jetty_destination, coal_quality, $(chx cuaca_mmi),
     tare_site_kg, toUnixTimestamp64Milli(cp1_timestamp), gross_site_kg, netto_site_kg, toUnixTimestamp64Milli(cp2_timestamp),
     gross_jetty_kg, netto_jetty_kg, compare_gross_kg, deviasi_kg, toUnixTimestamp64Milli(cp3_timestamp), adjustment_kg,
     toUInt8(is_locked), session_id, tare_jetty_kg, $(chx stockpile_code), $(chx tare_source), $(chx gross_source),
     $(chx cp1_event_id), $(chx cp2_event_id) FROM hauling.trips" ;;
  barge_loadings) q="SELECT loading_id, jetty, $(chx barge_name), $(chx tug_boat_name), loading_date, loading_qty_kg,
     toUnixTimestamp64Milli(created_at), $(chx stockpile_code) FROM hauling.barge_loadings" ;;
  scale_readings_pending) q="SELECT $(chx no_lambung), $(chx reading_type), toString(weight_kg), toUnixTimestamp64Milli(measured_at),
     toUnixTimestamp64Milli(created_at) FROM hauling.scale_readings_pending" ;;
  error_log) q="SELECT error_id, $(chx source), $(chx level), $(chx message), $(chx context), toUnixTimestamp64Milli(created_at)
     FROM hauling.error_log FINAL" ;;
  station_heartbeat) q="SELECT id, toUnixTimestamp64Milli(received_at), $(chx station_id), $(chx station_version),
     toUnixTimestamp64Milli(pc_time), skew_ms, toUInt8(scale_connected), trucks_on_site, sync_pending, sync_dead, oldest_job_min,
     toUnixTimestamp64Milli(last_push_ok_at), uptime_s FROM hauling.station_heartbeat FINAL" ;;
  esac
  CH -q "$q FORMAT TSV" | LC_ALL=C sort
}
compare_table() { # compare_table desc table
  pg_dump_table "$2" > "$WORK/out/pg_$2.tsv"; ch_dump_table "$2" > "$WORK/out/ch_$2.tsv"
  local n; n=$(wc -l < "$WORK/out/pg_$2.tsv" | tr -d ' ')
  if cmp -s "$WORK/out/pg_$2.tsv" "$WORK/out/ch_$2.tsv"; then ok "$1: $n rows identical (every column, byte for byte)"
  else bad "$1: rows differ"; diff "$WORK/out/pg_$2.tsv" "$WORK/out/ch_$2.tsv" | head -6 | cut -c1-300; fi
}
compare_all() { # compare_all label
  for t in trips barge_loadings scale_readings_pending error_log station_heartbeat; do compare_table "$1 $t" "$t"; done
}
ch_sig() { # ch_sig table -> md5 of the full table content, to prove "untouched"
  chq "SELECT hex(MD5(arrayStringConcat(arraySort(groupArray(toString(tuple(*)))), '|'))) || ':' || toString(count()) FROM hauling.$1"
}

echo "== setup =="
command -v clickhouse >/dev/null || { echo "clickhouse binary not found (brew install clickhouse)"; exit 1; }
command -v psql >/dev/null || { echo "psql not found"; exit 1; }
echo "ClickHouse: $(clickhouse --version | head -1)   Postgres: $(psql --version)   bash: $BASH_VERSION"
echo "scratch dir: $WORK"

# ── Postgres side ────────────────────────────────────────────────────────────
PGSU "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$PGDB' AND pid <> pg_backend_pid()" >/dev/null 2>&1
dropdb --if-exists "$PGDB" 2>/dev/null
createdb "$PGDB" && PGF test/hauling/pg_schema.sql && PGF $T/seed.sql && ok "Postgres $PGDB created from test/hauling/pg_schema.sql and seeded" || { bad "Postgres setup"; exit 1; }
if { printf '\\set ro_password %s\n' "$RO_PW"; cat db/hauling_ro_setup.sql; } | psql -X -q -v dbname="$PGDB" -d postgres >"$WORK/out/ro_setup.txt" 2>&1; then
  ok "db/hauling_ro_setup.sql runs cleanly against $PGDB (exit 0)"
else
  bad "db/hauling_ro_setup.sql exited non-zero (see tail below); continuing with the role as far as it got"
  grep -E "FAIL|ERROR" "$WORK/out/ro_setup.txt" | head -5 | cut -c1-250
fi
RO_CFG=$(PGSU "SELECT lower(array_to_string(rolconfig, '|')) FROM pg_roles WHERE rolname = '$PGUSER_RO'")
case "$RO_CFG" in *timezone=utc*) ok "role hauling_ro has timezone=UTC";; *) bad "role hauling_ro lacks timezone=UTC: [$RO_CFG]";; esac
case "$RO_CFG" in *"datestyle=iso, ymd"*) ok "role hauling_ro has datestyle='ISO, YMD'";; *) bad "role hauling_ro lacks datestyle ISO, YMD: [$RO_CFG]";; esac
check "hauling_ro can read the 5 tables, not sessions" "true,true,true,true,true,false" \
  "$(PGS "SELECT string_agg(has_table_privilege('$PGUSER_RO', t, 'SELECT')::text, ',' ORDER BY o) FROM unnest(ARRAY['trips','barge_loadings','scale_readings_pending','station_heartbeat','error_log','sessions']) WITH ORDINALITY u(t, o)")"

# a second role WITHOUT the UTC pin: proves the timezone trap is real and that the test can see it
PGSU "DROP OWNED BY $NOTZ_ROLE" >/dev/null 2>&1; PGSU "DROP ROLE IF EXISTS $NOTZ_ROLE" >/dev/null 2>&1
PGSU "CREATE ROLE $NOTZ_ROLE LOGIN" >/dev/null && PGSU "ALTER ROLE $NOTZ_ROLE SET timezone = 'Asia/Jakarta'" >/dev/null
PGS "GRANT SELECT ON scale_readings_pending TO $NOTZ_ROLE" >/dev/null

# ── ClickHouse side: scratch server, time zone NOT UTC ───────────────────────
render_config() { # render_config pg_port
  sed -e "s#@DIR@#$WORK#g" -e "s#@TZ@#$CH_TZ#" -e "s#@TCP@#$TCP#" -e "s#@HTTP@#$HTTP#" -e "s#@PGPORT@#$1#" \
      -e "s#@PGDB@#$PGDB#" -e "s#@PGUSER@#$PGUSER_RO#" $T/config.xml.tmpl > "$WORK/config.xml"
}
render_config "${PGPORT:-5432}"
cp $T/users.xml.tmpl "$WORK/users.xml"
if CH -q "SELECT 1" >/dev/null 2>&1; then echo "port $TCP already answers; refusing to reuse someone else's server"; exit 1; fi
start_server() {
  HAULING_RO_PASSWORD="$RO_PW" nohup clickhouse server --config-file="$WORK/config.xml" >"$WORK/server.stdout" 2>&1 &
  SERVER_PID=$!
  for _ in $(seq 1 120); do CH -q "SELECT 1" >/dev/null 2>&1 && break; sleep 0.5; done
}
start_server
check "scratch ClickHouse is up with a non-UTC server time zone" "$CH_TZ" "$(chq "SELECT timezone()")"
check "no hauling database yet" "0" "$(chq "SELECT count() FROM system.databases WHERE name = 'hauling'")"

echo "== script basics =="
sync_run -h;           check "-h exits 0" 0 "$RC"
sync_run --bogus;      check "unknown option exits 2" 2 "$RC"
sync_run --full extra; check "extra argument exits 2" 2 "$RC"
bash -n scripts/hauling_sync.sh && ok "bash -n scripts/hauling_sync.sh" || bad "bash -n"
if command -v shellcheck >/dev/null; then
  if shellcheck -S warning scripts/hauling_sync.sh >"$WORK/out/shellcheck.txt" 2>&1; then ok "shellcheck clean"; else bad "shellcheck"; head -20 "$WORK/out/shellcheck.txt"; fi
else skip "shellcheck not installed on this machine"; fi
sync_run;  check "sync before --init fails (exit 1)" 1 "$RC"
grep -q "run: scripts/hauling_sync.sh --init" "$LOG" && ok "...and tells the operator to run --init" || bad "no --init hint in log"
check "...and did not create the hauling database" "0" "$(chq "SELECT count() FROM system.databases WHERE name = 'hauling'")"

echo "== --init =="
sync_run --init; check "--init exits 0" 0 "$RC"
check "6 tables exist" "_sync_state,barge_loadings,error_log,scale_readings_pending,station_heartbeat,trips" \
  "$(chq "SELECT arrayStringConcat(arraySort(groupArray(name)), ',') FROM system.tables WHERE database = 'hauling'")"
check "engines (_sync_state, barge, error_log, pending, heartbeat, trips)" "MergeTree,MergeTree,ReplacingMergeTree,MergeTree,ReplacingMergeTree,MergeTree" \
  "$(chq "SELECT arrayStringConcat(groupArray(engine), ',') FROM (SELECT engine FROM system.tables WHERE database = 'hauling' ORDER BY name)")"
chq "SELECT 1 FROM system.tables WHERE database='hauling' AND name='trips' AND create_table_query LIKE '%ORDER BY (date, trip_id)%'" | grep -q 1 && ok "trips ORDER BY (date, trip_id)" || bad "trips ORDER BY"
check "timestamps are DateTime64(3,'UTC'), booleans Nullable(Bool), weight Float64" \
  "Nullable(DateTime64(3, 'UTC'));Nullable(Bool);Float64" \
  "$(chq "SELECT (SELECT type FROM system.columns WHERE database='hauling' AND table='trips' AND name='cp1_timestamp') || ';' || (SELECT type FROM system.columns WHERE database='hauling' AND table='trips' AND name='is_locked') || ';' || (SELECT type FROM system.columns WHERE database='hauling' AND table='scale_readings_pending' AND name='weight_kg') FORMAT TSVRaw")"
sync_run --init; check "--init is idempotent (second run exits 0)" 0 "$RC"
check "--init loaded no data and no watermark" "0,0" "$(chq "SELECT (SELECT count() FROM hauling.trips) || ',' || (SELECT count() FROM hauling._sync_state)")"

echo "== --print =="
sync_run --print; check "--print exits 0 (no watermark yet)" 0 "$RC"
check "--print leaves no unreplaced placeholder" "0" "$(grep -c '@SINCE@\|@RUN_START@\|@HB_MAX_ID@\|@MODE@\|^-- @@' "$WORK/out/last.txt")"
grep -q "CREATE TABLE hauling.error_log_new AS" "$WORK/out/last.txt" && ok "...without a watermark it prints the full-rebuild SQL" || bad "print: not full SQL"
check "--print wrote nothing to ClickHouse" "0" "$(state_rows)"
grep -q "EXCHANGE TABLES hauling.trips_new AND hauling.trips" "$WORK/out/last.txt" && ok "...snapshot swap present" || bad "no EXCHANGE in print"

echo "== first sync (empty heartbeat table) =="
check "Postgres station_heartbeat is empty" "0" "$(PGS "SELECT count(*) FROM station_heartbeat")"
sync_run; check "first sync exits 0" 0 "$RC"
grep -q "no previous successful run recorded; doing a full sync" "$LOG" && ok "no watermark => automatic full sync (logged)" || bad "first run not logged as full"
check "watermark rows / mode" "1 full" "$(state_rows) $(state_modes)"
check "trips rows (42 + special ones)" "$(PGS 'SELECT count(*) FROM trips')" "$(chq 'SELECT count() FROM hauling.trips')"
check "empty station_heartbeat mirrors as empty" "0" "$(chq 'SELECT count() FROM hauling.station_heartbeat')"
compare_all "after first sync:"
check "server time zone is not UTC but timestamps equal Postgres epochs" "0" \
  "$(chq "SELECT count() FROM hauling.trips WHERE toUnixTimestamp64Milli(cp1_timestamp) != 1788217200123 AND trip_id = '00000000-0000-4000-8000-000000000001'")"
check "microseconds are truncated, not rounded (.999999 -> .999, .0005 -> .000, .9996 -> .999)" "999,0,999" \
  "$(chq "SELECT toString(toMillisecond(cp1_timestamp)) || ',' || toString(toMillisecond(cp2_timestamp)) || ',' || toString(toMillisecond(cp3_timestamp)) FROM hauling.trips WHERE trip_id = '00000000-0000-4000-8000-00000000f0f0'")"
check "fractional weights survive (14873.5 + 34873.25 + 15000 + 123456.789)" "188203.539" "$(chq 'SELECT round(sum(weight_kg), 3) FROM hauling.scale_readings_pending')"
check "123456.789 stays 123456.789 (no Decimal->Float binary noise)" "123456.789" "$(chq "SELECT toString(weight_kg) FROM hauling.scale_readings_pending WHERE no_lambung='TR-003'")"
check "14873.5 is exactly 14873.5" "14873.5" "$(chq "SELECT toString(weight_kg) FROM hauling.scale_readings_pending WHERE no_lambung='TR-001' AND reading_type='tare'")"
# NULLs stay NULL
for col in cp1_timestamp gross_site_kg netto_site_kg cp2_timestamp gross_jetty_kg netto_jetty_kg compare_gross_kg deviasi_kg cp3_timestamp is_locked session_id tare_jetty_kg cp1_event_id cp2_event_id; do
  check "NULL count of trips.$col equals Postgres" "$(PGS "SELECT count(*) FROM trips WHERE $col IS NULL")" "$(chq "SELECT countIf($col IS NULL) FROM hauling.trips")"
done
check "NULL is_locked is NULL (not false); NULL event id is NULL (not '')" "1,1" \
  "$(chq "SELECT countIf(is_locked IS NULL AND trip_id = '00000000-0000-4000-8000-00000000f001') || ',' || countIf(cp1_event_id IS NULL AND trip_id = '00000000-0000-4000-8000-00000000f001') FROM hauling.trips")"
check "error_log.context NULL stays NULL, '[]' stays '[]'" "1,[]" \
  "$(chq "SELECT countIf(context IS NULL) || ',' || anyIf(context, error_id = '00000000-0000-4000-8000-00000000e003') FROM hauling.error_log FINAL")"
check "message with quotes, backslash, tab, newline, CRLF, unicode, emoji (byte-compare)" "1" \
  "$(chq "SELECT count() FROM hauling.error_log FINAL WHERE error_id = '00000000-0000-4000-8000-00000000e002' AND position(message, char(10)) > 0 AND position(message, char(9)) > 0 AND position(message, '😀') > 0 AND position(message, '\\\\') > 0 AND position(message, '日本語') > 0 AND position(context, '😀') > 0")"
check "context is the jsonb text form byte for byte" "$(PGS "SELECT encode(convert_to(context::text,'UTF8'),'hex') FROM error_log WHERE error_id='00000000-0000-4000-8000-00000000e002'")" \
  "$(chq "SELECT lower(hex(context)) FROM hauling.error_log FINAL WHERE error_id='00000000-0000-4000-8000-00000000e002'")"
sync_run --verify; check "--verify passes on a clean mirror (exit 0)" 0 "$RC"
sed -n '1,14p' "$WORK/out/last.txt" | cut -c1-140

echo "== the timezone trap (control) =="
# a Postgres role WITHOUT timezone=UTC read through the same reader gives wrong instants; hauling_ro does not
PGEPOCH=$(PGS "SELECT floor(extract(epoch from measured_at)*1000)::bigint FROM scale_readings_pending WHERE no_lambung='TR-001' AND reading_type='tare'")
GOOD=$(chq "SELECT toUnixTimestamp64Milli(toDateTime64(toString(measured_at), 6, 'UTC')) FROM postgresql(pg_hauling, table='scale_readings_pending') WHERE no_lambung='TR-001' AND reading_type='tare'")
BADV=$(chq "SELECT toUnixTimestamp64Milli(toDateTime64(toString(measured_at), 6, 'UTC')) FROM postgresql('127.0.0.1:${PGPORT:-5432}', '$PGDB', 'scale_readings_pending', '$NOTZ_ROLE', 'x') WHERE no_lambung='TR-001' AND reading_type='tare'")
check "through hauling_ro (UTC-pinned) the instant equals Postgres" "$PGEPOCH" "$GOOD"
if [[ "$BADV" =~ ^[0-9]+$ && "$BADV" != "$PGEPOCH" ]]; then ok "control: a role without the UTC pin is off by $(( (BADV - PGEPOCH) / 3600000 )) h (the trap is real, the test sees it)"; else bad "control role did not show the offset: [$BADV] vs [$PGEPOCH]"; fi
# the incremental filter compares the raw column, which ClickHouse reads in SERVER time (here +8 h): show
# that this skew is real and that the one-day pad in db/hauling_sync.sql absorbs it
PGS "INSERT INTO station_heartbeat (id, station_id, received_at) VALUES (900, 'tz-probe', '2026-10-01 12:00:00+00')" >/dev/null
RAW=$(chq "SELECT count() FROM postgresql(pg_hauling, table='station_heartbeat') WHERE id = 900 AND received_at > toDateTime64('2026-10-01 11:59:59', 6, 'UTC')")
PAD=$(chq "SELECT count() FROM postgresql(pg_hauling, table='station_heartbeat') WHERE id = 900 AND received_at > toDateTime64('2026-10-01 13:00:00', 6, 'UTC') - INTERVAL 1 DAY")
CEIL=$(chq "SELECT count() FROM postgresql(pg_hauling, table='station_heartbeat') WHERE id = 900 AND received_at > toDateTime64('2026-10-03 13:00:00', 6, 'UTC') - INTERVAL 1 DAY")
check "raw filter is skewed by the server offset (a row at 12:00Z is NOT 'after 11:59:59Z')" "0" "$RAW"
check "padded window: a row 1 h older than @SINCE@ is inside" "1" "$PAD"
check "padded window: a row 2 days older than @SINCE@ is outside (the window is not unbounded)" "0" "$CEIL"
PGS "DELETE FROM station_heartbeat WHERE id = 900" >/dev/null

echo "== round 1 of changes in Postgres, second sync =="
sleep 1
PGF $T/mutate1.sql
WM1=$(state_max); sleep 1
sync_run; check "second sync exits 0" 0 "$RC"
check "watermark advanced" "1" "$(chq "SELECT toDateTime64('$WM1', 3, 'UTC') < max(synced_through) FROM hauling._sync_state")"
check "two watermark rows, second one incremental" "2 full,incremental" "$(state_rows) $(state_modes)"
grep -q "rows newer than" "$LOG" && ok "incremental run logged" || bad "incremental not logged"
compare_all "after round 1:"
check "updated trip: netto_site_kg +100 propagated" "$(PGS "SELECT netto_site_kg FROM trips WHERE trip_id='00000000-0000-4000-8000-000000000001'")" \
  "$(chq "SELECT netto_site_kg FROM hauling.trips WHERE trip_id='00000000-0000-4000-8000-000000000001'")"
check "value -> NULL propagated (gross_site_kg of trip 2 is NULL, not 0)" "1" "$(chq "SELECT count() FROM hauling.trips WHERE trip_id='00000000-0000-4000-8000-000000000002' AND gross_site_kg IS NULL AND netto_site_kg IS NULL")"
check "NULL -> value propagated (is_locked true, event id 'evt-new')" "1" "$(chq "SELECT count() FROM hauling.trips WHERE trip_id='00000000-0000-4000-8000-00000000f001' AND is_locked = true AND cp1_event_id = 'evt-new'")"
check "deleted trips are gone" "0" "$(chq "SELECT count() FROM hauling.trips WHERE trip_id IN ('00000000-0000-4000-8000-000000000005','00000000-0000-4000-8000-000000000006','00000000-0000-4000-8000-000000000007')")"
check "inserted trips arrived" "3" "$(chq "SELECT count() FROM hauling.trips WHERE trip_id IN ('00000000-0000-4000-8000-00000000f003','00000000-0000-4000-8000-00000000f004','00000000-0000-4000-8000-00000000f005')")"
check "barge_loadings: update + delete + insert propagated" "7600000,BG Anugerah 1 (rev);0;1" \
  "$(chq "SELECT toString(anyIf(loading_qty_kg, loading_id='00000000-0000-4000-8000-00000000b001')) || ',' || anyIf(barge_name, loading_id='00000000-0000-4000-8000-00000000b001') || ';' || toString(countIf(loading_id='00000000-0000-4000-8000-00000000b002')) || ';' || toString(countIf(loading_id='00000000-0000-4000-8000-00000000b003')) FROM hauling.barge_loadings")"
check "emptied scale queue is empty in ClickHouse" "0" "$(chq 'SELECT count() FROM hauling.scale_readings_pending')"
check "error_log: 3 new rows, each exactly once, physically (no FINAL needed)" "7,7,7" \
  "$(chq "SELECT count() || ',' || uniqExact(error_id) || ',' || (SELECT count() FROM hauling.error_log FINAL) FROM hauling.error_log")"
check "late error_log row (30 min old, inside the overlap) arrived" "1" "$(chq "SELECT count() FROM hauling.error_log FINAL WHERE error_id='00000000-0000-4000-8000-00000000e102'")"
check "5000-character message intact" "5000" "$(chq "SELECT length(message) FROM hauling.error_log FINAL WHERE error_id='00000000-0000-4000-8000-00000000e103'")"
check "station_heartbeat: 4 rows incl. the one with a 3-day-old received_at but a new id" "4,4,1" \
  "$(chq "SELECT count() || ',' || uniqExact(id) || ',' || countIf(received_at < now() - INTERVAL 2 DAY) FROM hauling.station_heartbeat")"
sync_run --verify; check "--verify passes after round 1" 0 "$RC"

echo "== idempotence: nothing changed, run again =="
SIG_T=$(ch_sig trips); SIG_E=$(ch_sig error_log); SIG_H=$(ch_sig station_heartbeat)
sync_run; check "third sync exits 0" 0 "$RC"
check "no duplicates appeared: trips / error_log / station_heartbeat tables identical (physical rows)" "$SIG_T|$SIG_E|$SIG_H" "$(ch_sig trips)|$(ch_sig error_log)|$(ch_sig station_heartbeat)"
compare_all "after idempotent run:"

echo "== round 2: appends once heartbeat is non-empty =="
PGF $T/mutate2.sql
sync_run; check "sync exits 0" 0 "$RC"
check "row id=60 (new) and id=61 (4 days old, id above the mirrored max) arrived once" "6,6" \
  "$(chq "SELECT count() || ',' || uniqExact(id) FROM hauling.station_heartbeat")"
check "error_log round-2 row arrived once" "1" "$(chq "SELECT count() FROM hauling.error_log WHERE error_id='00000000-0000-4000-8000-00000000e201'")"
compare_all "after round 2:"

echo "== documented gap: old received_at AND an id below the mirrored max =="
PGF $T/mutate3.sql
sync_run; check "incremental sync exits 0" 0 "$RC"
check "incremental run does NOT see it (documented limitation)" "0" "$(chq "SELECT count() FROM hauling.station_heartbeat WHERE id = 55")"
sync_run --verify; check "--verify reports it (exit 1)" 1 "$RC"
grep -q "MISMATCH" "$WORK/out/last.txt" && ok "...with a MISMATCH row" || bad "no MISMATCH row printed"
sync_run --full; check "--full picks it up (exit 0)" 0 "$RC"
check "id 55 present after --full" "1" "$(chq "SELECT count() FROM hauling.station_heartbeat WHERE id = 55")"
compare_all "after --full:"
sync_run --verify; check "--verify passes again" 0 "$RC"

echo "== --full is idempotent and repairs drift =="
SIG_ALL=$(for t in trips barge_loadings scale_readings_pending error_log station_heartbeat; do ch_sig $t; done | paste -sd'|' -)
sync_run --full; check "second --full exits 0" 0 "$RC"
check "content identical after repeated --full (no duplicates, even physically)" "$SIG_ALL" "$(for t in trips barge_loadings scale_readings_pending error_log station_heartbeat; do ch_sig $t; done | paste -sd'|' -)"
chq "INSERT INTO hauling.error_log (error_id, source, level, message, created_at) VALUES (generateUUIDv4(), 'backend', 'error', 'ghost row only in ClickHouse', now())" >/dev/null
sync_run --verify; check "ghost row in an incremental table: --verify fails (exit 1)" 1 "$RC"
sync_run; check "plain incremental run does not remove it" "1" "$(chq "SELECT count() FROM hauling.error_log FINAL WHERE message LIKE 'ghost%'")"
sync_run --full; check "--full rebuild removes it" "0" "$(chq "SELECT count() FROM hauling.error_log FINAL WHERE message LIKE 'ghost%'")"
compare_all "after drift repair:"

echo "== --verify detects tampering =="
sync_run --verify; check "clean mirror: exit 0" 0 "$RC"
chq "ALTER TABLE hauling.trips UPDATE netto_site_kg = netto_site_kg + 1 WHERE trip_id = '00000000-0000-4000-8000-000000000001' SETTINGS mutations_sync = 2" >/dev/null
sync_run --verify; check "tampered netto_site_kg: exit 1" 1 "$RC"
grep -E "trips +sum\(netto_site_kg\).*MISMATCH" "$WORK/out/last.txt" >/dev/null && ok "...mismatch is on sum(netto_site_kg)" || bad "wrong metric flagged"
check "...and a failed verify is logged" "1" "$(last_log 1 | grep -c 'checks MISMATCH')"
sync_run; check "next sync repairs it (snapshot swap)" 0 "$RC"
sync_run --verify; check "verify clean again" 0 "$RC"
chq "ALTER TABLE hauling.trips DELETE WHERE trip_id = '00000000-0000-4000-8000-000000000001' SETTINGS mutations_sync = 2" >/dev/null
sync_run --verify; check "deleted trip row: exit 1" 1 "$RC"
sync_run; sync_run --verify; check "repaired by next sync" 0 "$RC"
chq "ALTER TABLE hauling.barge_loadings UPDATE loading_qty_kg = 1 WHERE 1 SETTINGS mutations_sync = 2" >/dev/null
sync_run --verify; check "tampered barge_loadings sum: exit 1" 1 "$RC"
sync_run; sync_run --verify; check "repaired" 0 "$RC"

echo "== failed runs: watermark and live tables must not move =="
PGS "UPDATE trips SET netto_site_kg = 12345 WHERE trip_id = '00000000-0000-4000-8000-000000000003'" >/dev/null
PGS "INSERT INTO error_log (source, message) VALUES ('backend', 'after-failure row')" >/dev/null
PGS "REVOKE SELECT ON error_log FROM $PGUSER_RO" >/dev/null
SIG_BEFORE=$(for t in trips barge_loadings scale_readings_pending error_log station_heartbeat; do ch_sig $t; done | paste -sd'|' -)
ST_ROWS=$(state_rows); ST_MAX=$(state_max)
sync_run; check "load of error_log fails (permission revoked): exit 1" 1 "$RC"
grep -q "FAILED.*watermark not advanced" "$LOG" && ok "...logged as FAILED, watermark not advanced" || bad "FAILED line missing"
check "watermark row count and value unchanged" "$ST_ROWS $ST_MAX" "$(state_rows) $(state_max)"
check "all five live tables byte-identical to before the failed run" "$SIG_BEFORE" "$(for t in trips barge_loadings scale_readings_pending error_log station_heartbeat; do ch_sig $t; done | paste -sd'|' -)"
check "the stale half-loaded trips_new copy is left behind" "1" "$(chq "SELECT count() FROM system.tables WHERE database='hauling' AND name = 'trips_new'")"
check "live trips still shows the OLD value (swap did not happen)" "0" "$(chq "SELECT count() FROM hauling.trips WHERE netto_site_kg = 12345")"
sync_run; check "second failing run also exits 1 (starts by dropping the stale _new, fails again)" 1 "$RC"
check "...still no change to watermark" "$ST_ROWS $ST_MAX" "$(state_rows) $(state_max)"
check "no credential in the log or in the output" "0" "$(cat "$LOG" "$WORK/out/last.txt" | grep -c -F -e "$RO_PW")"
PGS "REVOKE SELECT ON trips FROM $PGUSER_RO" >/dev/null
sync_run; check "failure on the very first table (trips revoked): exit 1" 1 "$RC"
check "...live trips untouched" "$(echo "$SIG_BEFORE" | cut -d'|' -f1)" "$(ch_sig trips)"
PGS "GRANT SELECT ON trips, error_log TO $PGUSER_RO" >/dev/null
sync_run; check "after restoring access the next run succeeds" 0 "$RC"
check "watermark advanced by exactly one row" "$((ST_ROWS + 1))" "$(state_rows)"
check "the stale _new tables are gone" "0" "$(chq "SELECT count() FROM system.tables WHERE database='hauling' AND name LIKE '%\\_new'")"
compare_all "after recovery:"
check "recovered run picked up the changes made during the outage" "1,12345" \
  "$(chq "SELECT (SELECT count() FROM hauling.error_log FINAL WHERE message = 'after-failure row') || ',' || toString((SELECT netto_site_kg FROM hauling.trips WHERE trip_id='00000000-0000-4000-8000-000000000003'))")"

echo "== Postgres unreachable (named collection points at a closed port) =="
PGS "UPDATE trips SET netto_site_kg = 777 WHERE trip_id = '00000000-0000-4000-8000-000000000004'" >/dev/null
stop_server; render_config 59999; start_server
SIG_BEFORE=$(for t in trips barge_loadings scale_readings_pending error_log station_heartbeat; do ch_sig $t; done | paste -sd'|' -)
ST_ROWS=$(state_rows); ST_MAX=$(state_max)
sync_run; check "sync with Postgres unreachable: exit 1" 1 "$RC"
check "...watermark unchanged, live tables untouched" "$ST_ROWS $ST_MAX $SIG_BEFORE" "$(state_rows) $(state_max) $(for t in trips barge_loadings scale_readings_pending error_log station_heartbeat; do ch_sig $t; done | paste -sd'|' -)"
check "...no credential in log or output" "0" "$(cat "$LOG" "$WORK/out/last.txt" | grep -c -F -e "$RO_PW")"
last_log 1 | cut -c1-260
stop_server; render_config "${PGPORT:-5432}"; start_server
sync_run; check "Postgres reachable again: next run succeeds" 0 "$RC"
check "...and picked up the change made in the meantime" "777" "$(chq "SELECT netto_site_kg FROM hauling.trips WHERE trip_id='00000000-0000-4000-8000-000000000004'")"
compare_all "after outage:"

echo "== locking, timeouts, stdin =="
# a lock held by someone else (perl flock; same mechanism the script falls back to on macOS)
perl -MFcntl=:flock -e 'open(F, ">", $ARGV[0]); flock(F, LOCK_EX); sleep 6' "$LOCK" &
HOLDER=$!; sleep 1
ST_ROWS=$(state_rows)
sync_run; check "run while the lock is held: skipped, exit 0" 0 "$RC"
grep -q "another run holds the lock; skipping" "$LOG" && ok "...logged as skipped" || bad "skip not logged"
check "...and wrote nothing" "$ST_ROWS" "$(state_rows)"
sync_run --verify; check "--verify while the lock is held: exit 1 (not a silent pass)" 1 "$RC"
sync_run --init;   check "--init while the lock is held: exit 1" 1 "$RC"
sync_run --print;  check "--print needs no lock: exit 0" 0 "$RC"
wait $HOLDER 2>/dev/null
# a real overlap: run A is slowed down on its first ClickHouse call, run B starts meanwhile
cat > "$WORK/slow_client.sh" <<EOS
#!/usr/bin/perl
# stand-in for the ClickHouse client: waits \$SLOW seconds (one process, so a timeout kills it), then execs the real one
select(undef, undef, undef, \$ENV{SLOW} || 0);
exec "clickhouse", "client", "--port", "$TCP", @ARGV;
EOS
chmod +x "$WORK/slow_client.sh"
ST_ROWS=$(state_rows)
( SLOW=2 HAULING_CH_CLIENT="$WORK/slow_client.sh" HAULING_SYNC_LOG=$LOG HAULING_SYNC_LOCK=$LOCK bash "$SYNC" >"$WORK/out/runA.txt" 2>&1; echo $? > "$WORK/out/runA.rc" ) &
RUN_A=$!
sleep 1
sync_run; check "overlapping run B: skipped, exit 0" 0 "$RC"
wait $RUN_A; check "run A finished OK (exit 0)" 0 "$(cat "$WORK/out/runA.rc")"
check "exactly one of the two runs wrote a watermark" "$((ST_ROWS + 1))" "$(state_rows)"
sync_run; check "lock is released afterwards (next run works)" 0 "$RC"
# timeout
START=$SECONDS
SLOW=8 HAULING_CH_CLIENT="$WORK/slow_client.sh" HAULING_SYNC_LOG=$LOG HAULING_SYNC_LOCK=$LOCK HAULING_SYNC_TIMEOUT=2 bash "$SYNC" >"$WORK/out/last.txt" 2>&1; RC=$?
check "a hung ClickHouse call is cut off by the timeout (non-zero exit)" "1" "$([ "$RC" -ne 0 ] && echo 1 || echo 0)"
[ $((SECONDS - START)) -lt 7 ] && ok "...within $((SECONDS - START))s, not waiting for the 8 s call" || bad "timeout did not cut the call short"
sync_run; check "and the next run works" 0 "$RC"
# stdin: only the piped multiquery may read it
echo "leftover-stdin" > "$WORK/out/stdin.txt"
OUT=$( { HAULING_CH_CLIENT="clickhouse client --port $TCP" HAULING_SYNC_LOG=$LOG HAULING_SYNC_LOCK=$LOCK bash "$SYNC" --verify >/dev/null 2>&1; cat; } < "$WORK/out/stdin.txt")
check "a run does not swallow what is on stdin" "leftover-stdin" "$OUT"
# unwritable log / lock paths
sync_run_paths() { HAULING_CH_CLIENT="clickhouse client --port $TCP" HAULING_SYNC_LOG=$1 HAULING_SYNC_LOCK=$2 bash "$SYNC" "${@:3}" >"$WORK/out/last.txt" 2>&1; RC=$?; }
sync_run_paths "$WORK/no/such/dir/x.log" "$WORK/no/such/dir/x.lock"; check "unwritable lock path: exit 1, no silent success" 1 "$RC"
sync_run_paths "$WORK/no/such/dir/x.log" "$LOCK"; check "unwritable log path is tolerated (logs go nowhere, run works)" 0 "$RC"

echo "== production code path: docker exec (shimmed; no Docker on this machine) =="
mkdir -p "$WORK/shim"
cat > "$WORK/shim/docker" <<EOS
#!/bin/sh
# stand-in for: docker exec [-i] CONTAINER sh -c SCRIPT chq ARGS...  (records whether -i was given)
[ "\$1" = exec ] || exit 64
shift
if [ "\$1" = "-i" ]; then echo "i" >> "$WORK/shim/docker.calls"; shift; else echo "-" >> "$WORK/shim/docker.calls"; fi
CONTAINER=\$1; shift
echo "container=\$CONTAINER" >> "$WORK/shim/docker.container"
CLICKHOUSE_USER=procurement_user CLICKHOUSE_PASSWORD=not-the-real-one exec "\$@"
EOS
cat > "$WORK/shim/clickhouse-client" <<EOS
#!/bin/sh
# stand-in for clickhouse-client inside the container: checks it was given the login from the
# container env, then talks to the scratch server (whose default user has no password)
seen_user=0; seen_pw=0
while [ \$# -gt 0 ]; do
  case "\$1" in
    --user) [ "\$2" = procurement_user ] && seen_user=1; shift 2 ;;
    --password) [ "\$2" = not-the-real-one ] && seen_pw=1; shift 2 ;;
    *) break ;;
  esac
done
echo "user=\$seen_user password=\$seen_pw" >> "$WORK/shim/login.calls"
unset CLICKHOUSE_USER CLICKHOUSE_PASSWORD   # the real client also reads these; the scratch server's default user has none
exec clickhouse client --port $TCP "\$@"
EOS
chmod +x "$WORK/shim/docker" "$WORK/shim/clickhouse-client"
prod_run() { PATH="$WORK/shim:$PATH" HAULING_SYNC_LOG=$LOG HAULING_SYNC_LOCK=$LOCK bash "$SYNC" "$@" >"$WORK/out/last.txt" 2>&1; RC=$?; }
: > "$WORK/shim/docker.calls"; : > "$WORK/shim/login.calls"; : > "$WORK/shim/docker.container"
ST_ROWS=$(state_rows)
prod_run; check "default client path (docker exec) runs a sync: exit 0" 0 "$RC"
check "...it wrote a watermark" "$((ST_ROWS + 1))" "$(state_rows)"
prod_run --verify; check "...and --verify: exit 0" 0 "$RC"
check "container name is procurement_clickhouse" "procurement_clickhouse" "$(sort -u "$WORK/shim/docker.container" | sed 's/container=//')"
check "every call carried the container's CLICKHOUSE_USER / CLICKHOUSE_PASSWORD" "user=1 password=1" "$(sort -u "$WORK/shim/login.calls")"
NCALLS=$(wc -l < "$WORK/shim/docker.calls" | tr -d ' ')
check "only the piped multiquery run attached stdin (docker exec -i): 1 of $NCALLS calls" "1" "$(grep -c '^i$' "$WORK/shim/docker.calls")"
check "no credential reached the log" "0" "$(grep -c 'not-the-real-one' "$LOG")"
HAULING_CH_CONTAINER=other_ch PATH="$WORK/shim:$PATH" HAULING_SYNC_LOG=$LOG HAULING_SYNC_LOCK=$LOCK bash "$SYNC" --verify >/dev/null 2>&1
check "HAULING_CH_CONTAINER overrides the container name" "1" "$(grep -c 'container=other_ch' "$WORK/shim/docker.container")"

echo
echo "== scenario B: the lead's realistic data (test/hauling/seed.sql + mutate.sql, 1200 trips) =="
if [[ -r test/hauling/seed.sql && -r test/hauling/mutate.sql ]]; then
  stop_server
  PGSU "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$PGDB' AND pid <> pg_backend_pid()" >/dev/null 2>&1
  dropdb --if-exists "$PGDB" && createdb "$PGDB" && PGF test/hauling/pg_schema.sql && PGF test/hauling/seed.sql && ok "Postgres $PGDB re-created with test/hauling/seed.sql" || { bad "scenario B setup"; }
  { printf '\\set ro_password %s\n' "$RO_PW"; cat db/hauling_ro_setup.sql; } | psql -X -q -v dbname="$PGDB" -d postgres >"$WORK/out/ro_setup2.txt" 2>&1 || bad "hauling_ro setup (scenario B)"
  rm -rf "$WORK/data"; mkdir -p "$WORK/data"; start_server
  sync_run --init; check "--init on a fresh server" 0 "$RC"
  sync_run; check "first sync (full) exits 0" 0 "$RC"
  check "seed.sql header totals reached in ClickHouse: trips / sum netto_site / sum netto_jetty" "1200,39525449,39473729" \
    "$(chq "SELECT count() || ',' || sum(netto_site_kg) || ',' || sum(netto_jetty_kg) FROM hauling.trips")"
  check "...status counts" "arrived_jetty=3, completed=1190, in_transit=4, pending=3" "$(chq "SELECT arrayStringConcat(arraySort(groupArray(concat(status, '=', toString(c)))), ', ') FROM (SELECT status, count() c FROM hauling.trips GROUP BY status)")"
  check "...barge 16 rows / 121364538 kg; pending 4 rows / 129427.5 kg" "16,121364538,4,129427.5" \
    "$(chq "SELECT (SELECT count() FROM hauling.barge_loadings) || ',' || (SELECT sum(loading_qty_kg) FROM hauling.barge_loadings) || ',' || (SELECT count() FROM hauling.scale_readings_pending) || ',' || (SELECT toString(sum(weight_kg)) FROM hauling.scale_readings_pending)")"
  check "...error_log 300 (sum(length(message)) 22242) and heartbeat 500 (sum(sync_pending) 7259)" "300,22242,500,7259" \
    "$(chq "SELECT (SELECT count() FROM hauling.error_log FINAL) || ',' || (SELECT sum(lengthUTF8(message)) FROM hauling.error_log FINAL) || ',' || (SELECT count() FROM hauling.station_heartbeat FINAL) || ',' || (SELECT sum(sync_pending) FROM hauling.station_heartbeat FINAL)")"
  compare_all "B first sync:"
  sync_run --verify; check "--verify passes" 0 "$RC"
  step() { awk -v n="$1" '$0 ~ "^-- ==== STEP " n " ====" {f=1; next} /^-- ==== STEP [0-9]+ ====/ {f=0} f' test/hauling/mutate.sql | psql -X -q -v ON_ERROR_STOP=1 -d "$PGDB" >/dev/null; }
  step 1; sync_run; check "STEP 1 (10 updates, 3 deletes, 5 inserts): sync exits 0" 0 "$RC"
  compare_all "B after STEP 1:"
  check "...1202 trips" "1202" "$(chq 'SELECT count() FROM hauling.trips')"
  step 2; sync_run; check "STEP 2 (20 errors, 15 heartbeats incl. late ids 513/514): sync exits 0" 0 "$RC"
  compare_all "B after STEP 2:"
  check "...heartbeat 515 rows, each once, physically" "515,515" "$(chq 'SELECT count() || char(44) || uniqExact(id) FROM hauling.station_heartbeat')"
  check "...late heartbeat 513 (received_at days old, new id) and 514 (3 h old) present" "2" "$(chq 'SELECT count() FROM hauling.station_heartbeat WHERE id IN (513, 514)')"
  check "...error_log 320, each once, physically" "320,320" "$(chq 'SELECT count() || char(44) || uniqExact(error_id) FROM hauling.error_log')"
  step 3; sync_run; check "STEP 3 (queue replaced, barge updated): sync exits 0" 0 "$RC"
  compare_all "B after STEP 3:"
  check "...pending now has the 2 new fractional readings" "2,65333.025" "$(chq 'SELECT count() || char(44) || toString(sum(weight_kg)) FROM hauling.scale_readings_pending')"
  check "...barge n=1 quantity 7777000" "7777000" "$(chq "SELECT loading_qty_kg FROM hauling.barge_loadings WHERE loading_id = '$(PGS "SELECT md5('barge-1')::uuid")'")"
  sync_run --verify; check "--verify passes after all steps" 0 "$RC"
  sync_run; sync_run --full; check "--full on realistic data exits 0" 0 "$RC"
  compare_all "B after --full:"
  sync_run --verify; check "final --verify passes" 0 "$RC"
else
  skip "scenario B: test/hauling/seed.sql / mutate.sql not present"
fi

echo "== final state =="
sync_run --verify; check "final --verify passes" 0 "$RC"
compare_all "final:"
cat "$WORK/out/last.txt" | cut -c1-130
echo "-- last log lines --"; tail -n 6 "$LOG" | cut -c1-200

# leave Postgres in place; restore the grants the role is supposed to have
PGS "GRANT SELECT ON trips, barge_loadings, scale_readings_pending, station_heartbeat, error_log TO $PGUSER_RO" >/dev/null
stop_server
echo
echo "database $PGDB left in place; ClickHouse scratch server stopped"
echo "RESULT: $PASS passed, $FAIL failed, $SKIP skipped"
[[ $FAIL -eq 0 ]]
