#!/usr/bin/env bash
# hauling_tracker (Postgres, Calvin's live system) -> ClickHouse database `hauling`.
# Runs on the host every 15 minutes from /etc/cron.d/hauling-ch-sync.
#
#   scripts/hauling_sync.sh            incremental: snapshot-swap trips, barge_loadings and
#                                      scale_readings_pending; append new error_log and
#                                      station_heartbeat rows (1 h overlap)
#   scripts/hauling_sync.sh --full     rebuild all five tables from Postgres (first run;
#                                      repairs drift). Chosen automatically when no
#                                      successful run is recorded yet.
#   scripts/hauling_sync.sh --init     create database `hauling` and its tables
#                                      (db/hauling_ch_schema.sql; idempotent; run once first)
#   scripts/hauling_sync.sh --verify   compare Postgres vs ClickHouse (row counts, sums,
#                                      status counts, max timestamps); no writes; prints a
#                                      table, exits 1 on any mismatch or error
#   scripts/hauling_sync.sh --print    print the SQL an incremental run would send
#   scripts/hauling_sync.sh -h         this text
#
# How it works: db/hauling_sync.sql is a template; this script fills in the watermark
# and pipes it into clickhouse-client. ClickHouse pulls from Postgres itself through the
# `pg_hauling` named collection (read-only role hauling_ro), so no Postgres credential
# passes through here or through cron. By default the client runs inside the
# procurement_clickhouse container, logged in with the container's own CLICKHOUSE_USER /
# CLICKHOUSE_PASSWORD; nothing is echoed or logged.
#
# Environment (all optional):
#   HAULING_CH_CLIENT     command that replaces `docker exec procurement_clickhouse ...`,
#                         e.g. 'clickhouse client --host 127.0.0.1 --port 19000'
#                         (split on spaces; used by test/hauling/ch/run_sync_test.sh)
#   HAULING_CH_CONTAINER  container name (default procurement_clickhouse)
#   HAULING_SYNC_LOG      default /var/log/hauling-ch-sync.log
#   HAULING_SYNC_LOCK     default /var/lock/hauling-ch-sync.lock
#   HAULING_SYNC_TIMEOUT  seconds allowed per ClickHouse call (default 900)
#
# Safe to re-run at any time. The watermark (hauling._sync_state) is only written by the
# very last statement of a run that succeeded; a failed run leaves it and the live mirror
# tables untouched, and the next run redoes the work. A second run while one is active is
# skipped (flock). Adding a table later: see the header of db/hauling_ch_schema.sql
# (TABLES and verify_sql below are the entries in this file).
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SQL_TEMPLATE="$REPO_DIR/db/hauling_sync.sql"
SCHEMA_FILE="$REPO_DIR/db/hauling_ch_schema.sql"
CONTAINER="${HAULING_CH_CONTAINER:-procurement_clickhouse}"
LOG_FILE="${HAULING_SYNC_LOG:-/var/log/hauling-ch-sync.log}"
LOCK_FILE="${HAULING_SYNC_LOCK:-/var/lock/hauling-ch-sync.lock}"
OVERLAP_MINUTES=60
RUN_TIMEOUT="${HAULING_SYNC_TIMEOUT:-900}"   # seconds per ClickHouse call; a run normally takes a few seconds

# Mirrored tables (the five phase-1 tables) plus the state table the preflight checks for.
TABLES="trips barge_loadings scale_readings_pending error_log station_heartbeat"

MODE=incremental
PRINT=0
case "${1:-}" in
  "")        ;;
  --full)    MODE=full ;;
  --init)    MODE=init ;;
  --verify)  MODE=verify ;;
  --print)   MODE=print; PRINT=1 ;;
  -h|--help) sed -n '2,39p' "$0"; exit 0 ;;
  *) echo "usage: $0 [--full|--init|--verify|--print|-h]" >&2; exit 2 ;;
esac
[ "$#" -le 1 ] || { echo "usage: $0 [--full|--init|--verify|--print|-h]" >&2; exit 2; }

log() {
  local line
  line="$(date '+%Y-%m-%d %H:%M:%S %z') [$MODE] $*"
  echo "$line" >> "$LOG_FILE"
  [ -t 1 ] && echo "$line"
  return 0
}

# One line, no credentials: collapse newlines, mask anything that looks like a password.
oneline() {
  echo "$1" | tr '\n' ' ' | sed -E 's/([Pp]assword)[=:] *[^ ,;)]*/\1=[HIDDEN]/g' | cut -c1-"${2:-500}"
}

# Run a command with a time limit (GNU timeout, Homebrew gtimeout, or perl's alarm).
run_timeout() {
  local secs=$1; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$secs" "$@"
  else
    perl -e 'alarm shift @ARGV; exec @ARGV or die "exec failed: $!\n"' "$secs" "$@"
  fi
}

# ClickHouse client. Production: clickhouse-client inside the container, logged in with
# the container's env. Override with HAULING_CH_CLIENT. Every call is time-limited so a
# hung run cannot hold the lock forever. CHQ_STDIN=1 attaches stdin (only for the piped
# multi-query run); otherwise stdin stays detached so an interactive run cannot eat
# pasted input.
chq() {
  if [ -n "${HAULING_CH_CLIENT:-}" ]; then
    local c=()
    read -r -a c <<< "$HAULING_CH_CLIENT"
    if [ "${CHQ_STDIN:-0}" = 1 ]; then
      run_timeout "$RUN_TIMEOUT" "${c[@]}" "$@"
    else
      run_timeout "$RUN_TIMEOUT" "${c[@]}" "$@" < /dev/null
    fi
  else
    local i=()
    [ "${CHQ_STDIN:-0}" = 1 ] && i=(-i)
    # shellcheck disable=SC2016  # expanded by sh inside the container, on purpose
    run_timeout "$RUN_TIMEOUT" docker exec ${i[@]+"${i[@]}"} "$CONTAINER" sh -c \
      'exec clickhouse-client --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" "$@"' \
      chq "$@"
  fi
}

touch "$LOG_FILE" 2>/dev/null || LOG_FILE=/dev/null

# ── Lock (not for --print, which writes nothing) ─────────────────────────────
if [ "$MODE" != print ]; then
  if ! { exec 9>"$LOCK_FILE"; } 2>/dev/null; then
    log "FAILED: cannot open lock file $LOCK_FILE"
    exit 1
  fi
  if command -v flock >/dev/null 2>&1; then
    flock -n 9 && lock_rc=0 || lock_rc=$?
  else  # macOS has no flock(1); perl's flock on the inherited fd 9 is equivalent
    perl -MFcntl=:flock -e 'open(my $f, ">&=", 9) or exit 2; flock($f, LOCK_EX | LOCK_NB) or exit 1' \
      && lock_rc=0 || lock_rc=$?
  fi
  if [ "$lock_rc" -ne 0 ]; then
    if [ "$lock_rc" -ne 1 ]; then log "FAILED: cannot lock $LOCK_FILE (rc $lock_rc)"; exit 1; fi
    log "another run holds the lock; skipping this run"
    case "$MODE" in incremental|full) exit 0 ;; *) exit 1 ;; esac
  fi
fi

[ -r "$SQL_TEMPLATE" ] || { log "FAILED: $SQL_TEMPLATE not found"; exit 1; }

# ── --init: create the database and tables ──────────────────────────────────
if [ "$MODE" = init ]; then
  [ -r "$SCHEMA_FILE" ] || { log "FAILED: $SCHEMA_FILE not found"; exit 1; }
  if ! err="$(CHQ_STDIN=1 chq --multiquery < "$SCHEMA_FILE" 2>&1 >/dev/null)"; then
    log "FAILED: applying $SCHEMA_FILE: $(oneline "$err" 1500)"
    exit 1
  fi
  log "OK: database hauling and its tables exist (db/hauling_ch_schema.sql applied)"
  exit 0
fi

# ── --verify: Postgres vs ClickHouse, per table ─────────────────────────────
# Every ClickHouse-side value is computed from the mirror tables, every Postgres-side
# value from postgresql(pg_hauling, ...) with the same conversions as the sync.
vrow() { # vrow table metric pg_scalar_sql ch_scalar_sql
  printf "SELECT '%s' AS tbl, '%s' AS metric, toString((%s)) AS pg, toString((%s)) AS ch" "$1" "$2" "$3" "$4"
}
pgt() { printf "postgresql(pg_hauling, table = '%s')" "$1"; }
maxts() { # maxts source_table column from_clause  -> 'none' or the max as UTC text at ms precision
  printf "SELECT if(count() = 0, 'none', toString(fromUnixTimestamp64Milli(toUnixTimestamp64Milli(max(%s)), 'UTC'))) FROM %s" "$2" "$3"
}
verify_sql() { # one SELECT per metric, glued with UNION ALL
  local t="$1" out=""
  case "$t" in
    trips)
      out="$(vrow trips 'rows' "SELECT count() FROM $(pgt trips)" "SELECT count() FROM hauling.trips")
UNION ALL $(vrow trips 'sum(netto_site_kg)' "SELECT ifNull(sum(netto_site_kg), 0) FROM $(pgt trips)" "SELECT ifNull(sum(netto_site_kg), 0) FROM hauling.trips")
UNION ALL $(vrow trips 'sum(netto_jetty_kg)' "SELECT ifNull(sum(netto_jetty_kg), 0) FROM $(pgt trips)" "SELECT ifNull(sum(netto_jetty_kg), 0) FROM hauling.trips")
UNION ALL $(vrow trips 'count by status' \
  "SELECT arrayStringConcat(arraySort(groupArray(concat(toString(status), '=', toString(c)))), ', ') FROM (SELECT status, count() AS c FROM $(pgt trips) GROUP BY status)" \
  "SELECT arrayStringConcat(arraySort(groupArray(concat(toString(status), '=', toString(c)))), ', ') FROM (SELECT status, count() AS c FROM hauling.trips GROUP BY status)")" ;;
    barge_loadings)
      out="$(vrow barge_loadings 'rows' "SELECT count() FROM $(pgt barge_loadings)" "SELECT count() FROM hauling.barge_loadings")
UNION ALL $(vrow barge_loadings 'sum(loading_qty_kg)' "SELECT ifNull(sum(loading_qty_kg), 0) FROM $(pgt barge_loadings)" "SELECT ifNull(sum(loading_qty_kg), 0) FROM hauling.barge_loadings")" ;;
    scale_readings_pending)
      out="$(vrow scale_readings_pending 'rows' "SELECT count() FROM $(pgt scale_readings_pending)" "SELECT count() FROM hauling.scale_readings_pending")
UNION ALL $(vrow scale_readings_pending 'sum(weight_kg)' "SELECT round(sum(toFloat64(weight_kg)), 3) FROM $(pgt scale_readings_pending)" "SELECT round(sum(weight_kg), 3) FROM hauling.scale_readings_pending")" ;;
    error_log)
      out="$(vrow error_log 'rows' "SELECT count() FROM $(pgt error_log)" "SELECT uniqExact(error_id) FROM hauling.error_log")
UNION ALL $(vrow error_log 'max(created_at)' \
  "$(maxts error_log "toDateTime64(toString(created_at), 6, 'UTC')" "$(pgt error_log)")" \
  "$(maxts error_log created_at hauling.error_log)")" ;;
    station_heartbeat)
      out="$(vrow station_heartbeat 'rows' "SELECT count() FROM $(pgt station_heartbeat)" "SELECT uniqExact(id) FROM hauling.station_heartbeat")
UNION ALL $(vrow station_heartbeat 'max(received_at)' \
  "$(maxts station_heartbeat "toDateTime64(toString(received_at), 6, 'UTC')" "$(pgt station_heartbeat)")" \
  "$(maxts station_heartbeat received_at hauling.station_heartbeat)")" ;;
    *) return 1 ;;
  esac
  echo "$out"
}

if [ "$MODE" = verify ]; then
  q=""
  for t in $TABLES; do
    [ -n "$q" ] && q="$q
UNION ALL "
    q="$q$(verify_sql "$t")"
  done
  # (the output alias must not be `table`: it would shadow the table = '...' argument of postgresql())
  q="SELECT tbl AS tablename, metric, pg AS postgres, ch AS clickhouse, if(pg = ch, 'ok', 'MISMATCH') AS result FROM ($q)
       ORDER BY indexOf(splitByChar(' ', '$TABLES'), tbl), metric != 'rows', metric FORMAT TSVWithNames"
  if ! out="$(chq --query "$q" 2>&1)"; then
    log "FAILED: $(oneline "$out" 1500)"
    exit 1
  fi
  if command -v column >/dev/null 2>&1; then echo "$out" | column -t -s "$(printf '\t')"; else echo "$out"; fi
  bad="$(echo "$out" | awk -F'\t' 'NR > 1 && $5 != "ok" { n++ } END { print n + 0 }')"
  rows="$(echo "$out" | awk 'END { print NR - 1 }')"
  if [ "$bad" -ne 0 ] || [ "$rows" -le 0 ]; then
    log "verify: $bad of $rows checks MISMATCH (the source is live: run a sync first, then verify again)"
    exit 1
  fi
  log "verify: OK ($rows checks, Postgres and ClickHouse agree)"
  exit 0
fi

# ── Preflight: the schema must exist (run --init once) ──────────────────────
TS_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?$'
n_tables=0
for _ in $TABLES; do n_tables=$((n_tables + 1)); done
n_tables=$((n_tables + 1))   # + _sync_state
if ! have="$(chq --query "SELECT count() FROM system.tables WHERE database = 'hauling' AND name IN ('$(echo "$TABLES _sync_state" | sed "s/ /','/g")')" 2>&1)"; then
  log "FAILED: cannot reach ClickHouse: $(oneline "$have")"
  exit 1
fi
if [ "$have" != "$n_tables" ]; then
  log "FAILED: ClickHouse database hauling is missing tables ($have of $n_tables found); run: scripts/hauling_sync.sh --init"
  exit 1
fi

# ── Clock and watermark ─────────────────────────────────────────────────────
if ! RUN_START="$(chq --query "SELECT toString(now64(3, 'UTC'))" 2>&1)" || ! [[ "$RUN_START" =~ $TS_RE ]]; then
  log "FAILED: cannot read the ClickHouse clock: $(oneline "$RUN_START")"
  exit 1
fi

if ! state="$(chq --query "SELECT count(), toString(max(synced_through) - toIntervalMinute($OVERLAP_MINUTES))
                           FROM hauling._sync_state FORMAT TSV" 2>&1)"; then
  log "FAILED: cannot read the watermark: $(oneline "$state")"
  exit 1
fi
SINCE='1970-01-01 00:00:00.000'
if [ "${state%%$'\t'*}" = 0 ]; then
  [ "$MODE" = print ] || { MODE=full; log "no previous successful run recorded; doing a full sync"; }
  MODE_SQL=full
elif [ "$MODE" = full ]; then
  MODE_SQL=full
else
  MODE_SQL=incremental
  SINCE="${state#*$'\t'}"
fi
[[ "$SINCE" =~ $TS_RE ]] || { log "FAILED: unexpected watermark '$state'"; exit 1; }

if ! HB_MAX_ID="$(chq --query "SELECT toString(max(id)) FROM hauling.station_heartbeat" 2>&1)" \
   || ! [[ "$HB_MAX_ID" =~ ^[0-9]+$ ]]; then
  log "FAILED: cannot read max(id) of hauling.station_heartbeat: $(oneline "$HB_MAX_ID")"
  exit 1
fi

# Keep only the section of the template for this mode, then fill in the placeholders.
sql="$(awk -v mode="$MODE_SQL" '
        /^-- @@(INCREMENTAL|FULL)[ \t]*$/ { skip = (tolower(substr($2, 3)) != mode); next }
        /^-- @@END[ \t]*$/                { skip = 0; next }
        !skip                             { print }' "$SQL_TEMPLATE" \
      | sed -e "s/@SINCE@/$SINCE/g" -e "s/@RUN_START@/$RUN_START/g" \
            -e "s/@MODE@/$MODE_SQL/g" -e "s/@HB_MAX_ID@/$HB_MAX_ID/g")"

if [ "$PRINT" = 1 ]; then
  echo "$sql"
  exit 0
fi

# ── Run ──────────────────────────────────────────────────────────────────────
if [ "$MODE_SQL" = full ]; then
  log "start: full rebuild of all tables from Postgres"
else
  log "start: rows newer than $SINCE UTC (plus snapshot tables)"
fi
started=$SECONDS
if ! err="$(echo "$sql" | CHQ_STDIN=1 chq --multiquery 2>&1 >/dev/null)"; then
  log "FAILED after $((SECONDS - started))s; watermark not advanced: $(oneline "$err" 2000)"
  exit 1
fi
log "OK in $((SECONDS - started))s; watermark now $RUN_START UTC"
