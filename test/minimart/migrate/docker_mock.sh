#!/usr/bin/env bash
# Thin stand-in for the `docker` CLI, used by test/minimart/migrate/run_migrate_test.sh so the
# REAL scripts (scripts/minimart_migrate.sh, scripts/minimart_backup.sh) run unmodified.
#
# Each "container" is a directory $MOCK_DIR/<name>/ with:
#   pgbin   path of the Postgres bin directory whose psql/pg_dump/pg_restore run "inside" it
#   port    TCP port of its Postgres server on 127.0.0.1 (trust auth)
#   env     NAME=value lines served by `docker exec <c> printenv NAME`
#   running (file present = container is running)
# Supported: exec [-i] [-t] [-e K=V] [-u U] [-w D] <c> <cmd...> ; inspect -f '{{.State.Running}}' <c> ;
#            stop|start <c> ; ps ; network/other -> exit 1.
# Test hooks (environment of the CALLER):
#   MOCK_LOG              append every invocation (one line) to this file (never contains stdin)
#   MOCK_HIDE_EXT         comma list: those extensions are hidden from pg_available_extensions
#                         when a psql in the NEW container asks (simulates a server without them)
#   MOCK_AFTER_DUMP_SQL   after a successful `pg_dump -Fc` in the old container, run this SQL
#                         against that same database (simulates a write racing the dump)
#   MOCK_RESTORE_FAIL     1 = pg_restore targets a non-existent database (real failure, no data applied)
set -u
[ -n "${MOCK_DIR:-}" ] || { echo "MOCK_DIR not set" >&2; exit 1; }
[ -n "${MOCK_LOG:-}" ] && echo "docker $*" >> "$MOCK_LOG"
sub=${1:-}; shift || true
case "$sub" in
  inspect)
    while [ $# -gt 1 ]; do shift; done; c=$1
    [ -d "$MOCK_DIR/$c" ] || { echo "Error: No such object: $c" >&2; exit 1; }
    if [ -e "$MOCK_DIR/$c/running" ]; then echo true; else echo false; fi; exit 0 ;;
  stop)  rm -f "$MOCK_DIR/$1/running"; echo "$1"; exit 0 ;;
  start) touch "$MOCK_DIR/$1/running"; echo "$1"; exit 0 ;;
  exec)
    envs=()
    while [ $# -gt 0 ]; do
      case "$1" in
        -i|-t|-it|-d) shift ;;
        -e) envs+=("$2"); shift 2 ;;
        -u|-w) shift 2 ;;
        *) break ;;
      esac
    done
    c=${1:-}; shift
    [ -d "$MOCK_DIR/$c" ] || { echo "Error: No such container: $c" >&2; exit 1; }
    [ -e "$MOCK_DIR/$c/running" ] || { echo "Error response from daemon: container $c is not running" >&2; exit 1; }
    pgbin=$(cat "$MOCK_DIR/$c/pgbin"); port=$(cat "$MOCK_DIR/$c/port")
    tool=${1:-}
    if [ "$tool" = printenv ]; then
      v=$(grep -m1 "^$2=" "$MOCK_DIR/$c/env" 2>/dev/null | cut -d= -f2-) || true
      [ -n "$v" ] || exit 1
      echo "$v"; exit 0
    fi
    for e in ${envs[@]+"${envs[@]}"}; do export "${e?}"; done
    export PGHOST=127.0.0.1 PGPORT=$port PATH="$pgbin:$PATH"
    # --- hooks ---
    if [ "$tool" = psql ] && [ -n "${MOCK_HIDE_EXT:-}" ] && [ "$c" = "${MOCK_NEW_NAME:-mmi-postgres}" ]; then
      args=(); for a in "$@"; do
        args+=("${a//pg_available_extensions/(select * from pg_available_extensions where name <> all(string_to_array('${MOCK_HIDE_EXT}', ','))) pg_available_extensions}")
      done
      set -- "${args[@]}"
    fi
    if [ "$tool" = pg_restore ] && [ "${MOCK_RESTORE_FAIL:-0}" = 1 ]; then
      args=(); for a in "$@"; do args+=("$a"); done
      for i in "${!args[@]}"; do [ "${args[$i]}" = "-d" ] && args[$((i+1))]="no_such_database_for_test"; done
      set -- "${args[@]}"
    fi
    if [ "$tool" = pg_dump ] && [ -n "${MOCK_AFTER_DUMP_SQL:-}" ]; then
      "$@"; rc=$?
      if [ $rc -eq 0 ]; then
        db=; u=postgres; prev=
        for a in "$@"; do [ "$prev" = -d ] && db=$a; [ "$prev" = -U ] && u=$a; prev=$a; done
        # only for the full custom-format dump (not -s / globals)
        case " $* " in *" -Fc "*) env -u PGOPTIONS psql -U "$u" -d "$db" -X -q -c "$MOCK_AFTER_DUMP_SQL" >/dev/null 2>&1 ;; esac
      fi
      exit $rc
    fi
    exec "$@" ;;
  ps) exit 0 ;;
  *) echo "docker mock: unsupported: $sub $*" >&2; exit 1 ;;
esac
