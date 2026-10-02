#!/usr/bin/env bash
# Shared test library for test/minimart/migrate/run_*_test.sh (sourced, not run).
# Builds the two throw-away Postgres clusters, the `docker` wrapper and the helper functions.
# See run_migrate_test.sh for the description of the simulated world.
# Callers set OLD_PORT / NEW_PORT before sourcing so that several runners can run side by side.
cd "$(dirname "${BASH_SOURCE[0]}")/../../.."
REPO=$PWD
T=test/minimart
PG14=${PG14:-/opt/homebrew/opt/postgresql@14/bin}
PG15=${PG15:-/opt/homebrew/opt/postgresql@15/bin}
OLD_PORT=${OLD_PORT:-55501}
NEW_PORT=${NEW_PORT:-55502}
if [ -n "${MINIMART_TEST_DIR:-}" ]; then WORK=$MINIMART_TEST_DIR; OWN_WORK=0; else WORK=$(mktemp -d "${TMPDIR:-/tmp}/minimart_migrate_test.XXXXXX"); OWN_WORK=1; fi
mkdir -p "$WORK"/{bin,mock,out,backups}
WORK=$(cd "$WORK" && pwd)

for b in "$PG14/initdb" "$PG15/initdb"; do [ -x "$b" ] || { echo "missing $b (brew install postgresql@14 postgresql@15)"; exit 1; }; done

PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); echo "  PASS  $1"; }
bad()   { FAIL=$((FAIL+1)); echo "  FAIL  $1"; }
check() { if [[ "$3" == "$2" ]]; then ok "$1"; else bad "$1 — expected [$2] got [$3]"; fi; }
has()   { if grep -qF -- "$2" <<< "$3"; then ok "$1"; else bad "$1 — missing [$2] in: $(head -c 400 <<< "$3" | tr '\n' ' ')"; fi; }
hasnt() { if grep -qF -- "$2" <<< "$3"; then bad "$1 — unexpected [$2]"; else ok "$1"; fi; }
section() { echo; echo "== $* =="; }

# ── clusters ─────────────────────────────────────────────────────────────────
OLD_DATA=$WORK/old_data; NEW_DATA=$WORK/new_data
mkcluster() { # mkcluster bindir datadir port superuser locale
  rm -rf "$2"
  "$1/initdb" -D "$2" -U "$4" -A trust -E UTF8 --locale="$5" >/dev/null 2>&1 || { echo "initdb failed"; exit 1; }
  "$1/pg_ctl" -D "$2" -o "-p $3 -c listen_addresses=127.0.0.1 -c unix_socket_directories= -c fsync=off -c max_connections=100" \
     -l "$2.log" -w start >/dev/null 2>&1 || { echo "cannot start cluster on $3 (see $2.log)"; tail -5 "$2.log"; exit 1; }
}
cleanup() {
  [ -n "${APP_PID:-}" ] && kill "$APP_PID" 2>/dev/null
  "$PG14/pg_ctl" -D "$OLD_DATA" -m immediate stop >/dev/null 2>&1
  "$PG15/pg_ctl" -D "$NEW_DATA" -m immediate stop >/dev/null 2>&1
  [[ "${MINIMART_TEST_KEEP:-0}" = 1 ]] || { [ -n "${WORK:-}" ] && [ "$WORK" != / ] && [ -d "$WORK/mock" ] && rm -rf "$WORK"; }
}
trap cleanup EXIT

# psql helpers (host side, direct to the clusters)
OP() { PGHOST=127.0.0.1 PGPORT=$OLD_PORT "$PG14/psql" -U mmadmin -X -q -At -v ON_ERROR_STOP=1 -d "${ODB:-minimartdb}" "$@"; }   # OP -c "sql"
NP() { PGHOST=127.0.0.1 PGPORT=$NEW_PORT "$PG15/psql" -U postgres -X -q -At -v ON_ERROR_STOP=1 -d "${NDB:-minimart}" "$@"; }    # NP -c "sql"
NPG() { PGHOST=127.0.0.1 PGPORT=$NEW_PORT "$PG15/psql" -U postgres -X -q -At -v ON_ERROR_STOP=1 -d postgres "$@"; }

# ── docker wrapper ───────────────────────────────────────────────────────────
cp "$T/migrate/docker_mock.sh" "$WORK/bin/docker"; chmod +x "$WORK/bin/docker"
mkcontainer() { # name pgbin port "env lines"
  mkdir -p "$WORK/mock/$1"; echo "$2" > "$WORK/mock/$1/pgbin"; echo "$3" > "$WORK/mock/$1/port"; printf '%s\n' "$4" > "$WORK/mock/$1/env"; touch "$WORK/mock/$1/running"
}
export MOCK_DIR=$WORK/mock MOCK_LOG=$WORK/out/docker.log
export PATH="$WORK/bin:$PATH"
unset PGHOST PGPORT PGUSER PGDATABASE PGPASSWORD MINIMART_OLD_PGUSER MINIMART_OLD_DB MINIMART_NEW_DB MINIMART_LC_COLLATE MINIMART_LC_CTYPE \
      MINIMART_OLD_CONTAINER MINIMART_NEW_CONTAINER MOCK_HIDE_EXT MOCK_AFTER_DUMP_SQL MOCK_RESTORE_FAIL MINIMART_VERIFY_CONTENT
export MINIMART_BACKUP_ROOT=$WORK/backups MINIMART_MIGRATE_LOG=$WORK/out/migrate.log MINIMART_MIGRATE_LOCK=$WORK/out/migrate.lock TMPDIR=$WORK/out
mkdir -p "$TMPDIR"

MIG="$REPO/scripts/minimart_migrate.sh"
mig() { # mig [env assignments are given by the caller via env] args... -> RC, output in $OUT
  OUT=$(bash "$MIG" "$@" 2>&1); RC=$?; echo "$OUT" > "$WORK/out/last.txt"
}
APP_PW=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)
RO_PW=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)
setup_sql() { # setup_sql [psql -v args...]  (passwords via stdin \set, like the runbook)
  { [ "${NO_PW:-0}" = 1 ] || { printf '\\set app_password %s\n' "${APP_PW_USE:-$APP_PW}"; printf '\\set ro_password %s\n' "${RO_PW_USE:-$RO_PW}"; }
    cat "$REPO/db/minimart_setup.sql"; } \
  | PGHOST=127.0.0.1 PGPORT=$NEW_PORT "$PG15/psql" -U postgres -X -v ON_ERROR_STOP=1 -d postgres "$@" 2>&1
}


# world_up: start both clusters, load the old database (stand-in + seed + extras).
world_up() {
  section "world: two clusters (old PG14 locale C, new PG15 en_US.UTF-8)"
  mkcluster "$PG14" "$OLD_DATA" "$OLD_PORT" mmadmin C && ok "old cluster started on $OLD_PORT"
  mkcluster "$PG15" "$NEW_DATA" "$NEW_PORT" postgres en_US.UTF-8 && ok "new cluster started on $NEW_PORT"
  mkcontainer minimart-postgres-1 "$PG14" "$OLD_PORT" $'POSTGRES_USER=mmadmin\nPOSTGRES_DB=minimartdb'
  mkcontainer mmi-postgres "$PG15" "$NEW_PORT" $'POSTGRES_USER=postgres'
  PGHOST=127.0.0.1 PGPORT=$OLD_PORT "$PG14/createdb" -U mmadmin minimartdb
  OP -f $T/stand_in_schema.sql && OP -f $T/stand_in_seed.sql && OP -f $T/migrate/extra_old.sql && ok "old database loaded (stand-in schema + seed + extras)"
  OP -c "update customers set signed_up_at = now() at time zone 'UTC' where customer_id = 1" >/dev/null
  OLD_TABLES=$(OP -c "select count(*) from pg_tables where schemaname not in ('pg_catalog','information_schema')")
  check "old database has 18 tables (12 stand-in public + audit.changes + weird + specials + scratch_cache + tcol + minseq_tab)" 18 "$OLD_TABLES"
}
# world_summary: print totals and exit with the right code
world_summary() { echo; echo "RESULT: PASS=$PASS FAIL=$FAIL"; [ "$FAIL" -eq 0 ]; }
