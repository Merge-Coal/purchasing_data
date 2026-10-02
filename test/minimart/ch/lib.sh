#!/usr/bin/env bash
# Shared harness of the minimart ClickHouse-mirror tests (test/minimart/ch/*.sh). Source it:
#
#   source "$(dirname "$0")/lib.sh"; mm_env a 19301 18301        # name, ClickHouse TCP port, HTTP port
#   mm_pg_setup yes                                                # Postgres db mmc_a + stand-in schema/seed + role
#   mm_ch_start                                                    # scratch ClickHouse server
#   sync_run --init; check "init exits 0" 0 "$RC"
#   ...
#   mm_summary                                                     # prints PASS/FAIL, sets the exit code
#
# What it provides
#   * a scratch `clickhouse server` (binary $MM_CH_BIN, default `clickhouse`; set it to the official 24.8 build
#     to test the production version) with its own config on its own ports, server time zone Asia/Makassar
#     (NOT UTC, like the production host), a named collection `pg_minimart` -> 127.0.0.1 / mmc_<name> /
#     mmc_ro_<name>, password from the environment (from_env) exactly like production, query_log on.
#   * Postgres database mmc_<name> and the read-only role mmc_ro_<name> created like minimart_ro
#     (timezone=UTC, datestyle='ISO, YMD', read-only default, statement_timeout) with its grants applied by the
#     REAL db/minimart_ro_grants.sql (column-level on tables with sensitive columns).
#   * the REAL scripts run unmodified: `docker` and `clickhouse-client` on PATH are the shims in shim/ (they
#     understand only `docker exec [-i] procurement_clickhouse sh -c '...' chq ...` and check that the login
#     comes from the container environment).
# It never touches any other database or role (everything is prefixed mmc_) and never a Postgres
# role called minimart_* (another agent's tests use those names on the same server).
# Scratch files: $MM_TEST_DIR (default: a fresh mktemp dir, removed at the end unless MM_TEST_KEEP=1).

[[ -n "${MM_LIB_LOADED:-}" ]] && return 0
MM_LIB_LOADED=1
set -uo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
cd "$REPO" || exit 1
T=test/minimart/ch
export PGHOST=${PGHOST:-/tmp}
unset PGPASSWORD PGDATABASE MINIMART_SYNC_LOG MINIMART_SYNC_LOCK MINIMART_SYNC_TIMEOUT MINIMART_OVERRIDES MINIMART_SMALL_ROWS \
      MINIMART_OVERLAP_MINUTES MINIMART_VERIFY_HASH_MAX_ROWS MINIMART_CH_CONTAINER

PASS=0; FAIL=0; SKIP=0; SERVER_PID=; RC=0
ok()   { PASS=$((PASS+1)); echo "  PASS  $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL  $1"; }
skip() { SKIP=$((SKIP+1)); echo "  SKIP  $1"; }
check() { # check "description" expected actual
  if [[ "$3" == "$2" ]]; then ok "$1"; else bad "$1 — expected [$2] got [$3]"; fi
}
check_match() { # check_match "description" extended-regex actual
  if [[ "$3" =~ $2 ]]; then ok "$1"; else bad "$1 — [$3] does not match /$2/"; fi
}

mm_env() { # mm_env name tcp_port http_port
  NAME=$1; TCP=$2; HTTP=$3
  PGDB=mmc_$NAME; RO_ROLE=mmc_ro_$NAME
  MM_CH_BIN=${MM_CH_BIN:-clickhouse}
  CH_TZ=${TEST_CH_TZ:-Asia/Makassar}
  WORK=${MM_TEST_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/minimart_ch_test_$NAME.XXXXXX")}
  rm -rf "$WORK/data" "$WORK/out"
  mkdir -p "$WORK"/{data,tmp,user_files,format_schemas,out}
  RO_PW=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)
  LOG=$WORK/minimart-ch-sync.log
  LOCK=$WORK/minimart-ch-sync.lock
  SYNC="$REPO/scripts/minimart_sync.sh"
  GEN="$REPO/scripts/minimart_gen_schema.sh"
  export MM_CH_PORT=$TCP MM_CH_BIN MM_SHIM_LOG=$WORK/shim.log
  trap mm_cleanup EXIT
}

CH()   { "$MM_CH_BIN" client --port "$TCP" "$@"; }
chq()  { CH -q "$1" 2>&1; }                       # chq "sql" -> output (TSV by default)
PGS()  { psql -X -q -tA -v ON_ERROR_STOP=1 -d "$PGDB" -c "$1"; }
PGF()  { psql -X -q -v ON_ERROR_STOP=1 -d "$PGDB" -f "$1" >/dev/null; }
PGSU() { psql -X -q -tA -v ON_ERROR_STOP=1 -d postgres -c "$1"; }

# sync_run [args...]: runs scripts/minimart_sync.sh unmodified through the docker shim.
# RC = exit code, $WORK/out/last.txt = stdout+stderr. Extra environment: set variables before the call
# with `env`-style prefix through MM_ENV (e.g. MM_ENV="MINIMART_SMALL_ROWS=100").
sync_run() {
  # shellcheck disable=SC2086
  env PATH="$REPO/$T/shim:$PATH" MINIMART_SYNC_LOG="$LOG" MINIMART_SYNC_LOCK="$LOCK" ${MM_ENV:-} \
    bash "$SYNC" "$@" >"$WORK/out/last.txt" 2>&1; RC=$?
}
last_log() { tail -n "${1:-1}" "$LOG" 2>/dev/null; }

mm_pg_setup() { # mm_pg_setup yes|no   (seed data or schema only)
  PGSU "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$PGDB' AND pid <> pg_backend_pid()" >/dev/null 2>&1
  dropdb --if-exists "$PGDB" 2>/dev/null
  createdb "$PGDB" && PGF test/minimart/stand_in_schema.sql || { bad "Postgres $PGDB schema"; return 1; }
  [[ "$1" == yes ]] && { PGF test/minimart/stand_in_seed.sql || { bad "Postgres $PGDB seed"; return 1; }; }
  mm_ro_role
  ok "Postgres $PGDB created from the stand-in schema$([[ "$1" == yes ]] && echo ' and seed'); role $RO_ROLE granted by db/minimart_ro_grants.sql"
}
mm_ro_role() { # (re)create the read-only role like minimart_ro and apply the REAL grants file
  PGSU "DROP OWNED BY $RO_ROLE" >/dev/null 2>&1; PGSU "DROP ROLE IF EXISTS $RO_ROLE" >/dev/null 2>&1
  PGSU "CREATE ROLE $RO_ROLE LOGIN CONNECTION LIMIT 20" >/dev/null
  PGSU "ALTER ROLE $RO_ROLE SET timezone = 'UTC'" >/dev/null
  PGSU "ALTER ROLE $RO_ROLE SET datestyle = 'ISO, YMD'" >/dev/null
  PGSU "ALTER ROLE $RO_ROLE SET default_transaction_read_only = on" >/dev/null
  PGSU "ALTER ROLE $RO_ROLE SET statement_timeout = '120s'" >/dev/null
  mm_grants
}
mm_grants() { # mm_grants [extra psql args...]: run db/minimart_ro_grants.sql for this test's db and role
  psql -X -q -v ON_ERROR_STOP=1 -d postgres -v dbname="$PGDB" -v ro_role="$RO_ROLE" "$@" -f db/minimart_ro_grants.sql >"$WORK/out/grants.txt" 2>&1
}

mm_render_config() {
  sed -e "s#@DIR@#$WORK#g" -e "s#@TZ@#$CH_TZ#" -e "s#@TCP@#$TCP#" -e "s#@HTTP@#$HTTP#" -e "s#@PGPORT@#${PGPORT:-5432}#" \
      -e "s#@PGDB@#$PGDB#" -e "s#@PGUSER@#$RO_ROLE#" $T/config.xml.tmpl > "$WORK/config.xml"
  cp $T/users.xml.tmpl "$WORK/users.xml"
}
mm_ch_start() {
  command -v "$MM_CH_BIN" >/dev/null || { echo "ClickHouse binary $MM_CH_BIN not found"; exit 1; }
  mm_render_config
  if CH -q "SELECT 1" >/dev/null 2>&1; then echo "port $TCP already answers; refusing to reuse someone else's server"; exit 1; fi
  MINIMART_RO_PASSWORD="$RO_PW" nohup "$MM_CH_BIN" server --config-file="$WORK/config.xml" >"$WORK/server.stdout" 2>&1 &
  SERVER_PID=$!
  for _ in $(seq 1 120); do CH -q "SELECT 1" >/dev/null 2>&1 && break; sleep 0.5; done
  CH -q "SELECT 1" >/dev/null 2>&1 || { echo "ClickHouse did not start; see $WORK/server.stdout"; tail -5 "$WORK/server.stdout"; exit 1; }
}
mm_ch_stop() {
  if [[ -n "$SERVER_PID" ]]; then
    kill "$SERVER_PID" 2>/dev/null   # SIGTERM = graceful shutdown (not SYSTEM SHUTDOWN: it signals the process group)
    for _ in $(seq 1 80); do kill -0 "$SERVER_PID" 2>/dev/null || break; sleep 0.25; done
    kill -9 "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null
    SERVER_PID=
  fi
}
mm_cleanup() {
  mm_ch_stop
  PGSU "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$PGDB' AND pid <> pg_backend_pid()" >/dev/null 2>&1
  if [[ "${MM_TEST_KEEP:-0}" != 1 ]]; then
    dropdb --if-exists "$PGDB" 2>/dev/null
    PGSU "DROP ROLE IF EXISTS $RO_ROLE" >/dev/null 2>&1
    rm -rf "$WORK/data" "$WORK/tmp"
  fi
}
mm_summary() {
  echo
  echo "ClickHouse $("$MM_CH_BIN" --version | head -1 | sed 's/ClickHouse local version //')  Postgres $(psql --version | awk '{print $3}')  bash $BASH_VERSION"
  echo "RESULT: $PASS passed, $FAIL failed, $SKIP skipped"
  [[ $FAIL -eq 0 ]]
}
