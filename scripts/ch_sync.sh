#!/usr/bin/env bash
# Postgres (source of truth) → ClickHouse (warehouse) sync. Runs on the host,
# every 15 minutes from /etc/cron.d/procurement-ch-sync (RUNBOOK_POSTGRES_CUTOVER.md).
#
#   scripts/ch_sync.sh            incremental: rows changed since the last
#                                 successful run (minus a 15-minute overlap)
#   scripts/ch_sync.sh --full     every row (first run after cutover; repairs)
#   scripts/ch_sync.sh --verify   compare ids Postgres vs ClickHouse, no writes;
#                                 exits 1 if any Postgres row is missing
#   scripts/ch_sync.sh --print    print the SQL an incremental run would send
#
# How it works: db/ch_sync.sql is a template; this script fills in the
# watermark and pipes it into clickhouse-client inside procurement_clickhouse.
# ClickHouse pulls from Postgres itself through the `pg_procurement` named
# collection, so no Postgres credential passes through here or through cron.
# The ClickHouse login is the container's own CLICKHOUSE_USER /
# CLICKHOUSE_PASSWORD, which docker compose sets from /opt/purchasing_data/.env;
# nothing is echoed or logged.
#
# Safe to re-run at any time: current-state tables are ReplacingMergeTree
# (highest version wins), append-only tables are inserted by id anti-join.
# A run that fails part-way does not advance the watermark, so the next run
# redoes it. ClickHouse data is only ever inserted, never deleted.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SQL_TEMPLATE="$REPO_DIR/db/ch_sync.sql"
CONTAINER="${CH_CONTAINER:-procurement_clickhouse}"
LOG_FILE="${CH_SYNC_LOG:-/var/log/procurement-ch-sync.log}"
LOCK_FILE="${CH_SYNC_LOCK:-/var/lock/procurement-ch-sync.lock}"
OVERLAP_MINUTES=15
RUN_TIMEOUT=900   # seconds; a run normally takes a few seconds

MODE=incremental
case "${1:-}" in
  "")       ;;
  --full)   MODE=full ;;
  --verify) MODE=verify ;;
  --print)  MODE=print ;;
  -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
  *) echo "usage: $0 [--full|--verify|--print]" >&2; exit 2 ;;
esac

log() {
  local line
  line="$(date '+%Y-%m-%d %H:%M:%S %z') [$MODE] $*"
  echo "$line" >> "$LOG_FILE"
  [ -t 1 ] && echo "$line"
  return 0
}

# clickhouse-client inside the container, logged in with the container's env.
# `timeout` bounds every call so a hung run cannot hold the lock forever.
# CHQ_STDIN=1 attaches stdin (only for the piped multi-query run); otherwise
# stdin stays detached so an interactive run cannot eat pasted input.
chq() {
  local i=()
  [ "${CHQ_STDIN:-0}" = 1 ] && i=(-i)
  # shellcheck disable=SC2016  # expanded by sh inside the container, on purpose
  timeout "$RUN_TIMEOUT" docker exec ${i[@]+"${i[@]}"} "$CONTAINER" sh -c \
    'exec clickhouse-client --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" --database procurement "$@"' \
    chq "$@"
}

TABLES="purposes users vendors items purchase_requests purchase_request_items
purchase_orders purchase_order_items purchase_order_charges item_requests
pr_templates pr_template_items approval_actions gl_exports"

id_column() {
  case "$1" in
    purposes) echo purpose_id ;;            users) echo user_id ;;
    vendors) echo vendor_id ;;              items) echo item_id ;;
    purchase_requests) echo pr_id ;;        purchase_request_items) echo pr_item_id ;;
    purchase_orders) echo po_id ;;          purchase_order_items) echo po_item_id ;;
    purchase_order_charges) echo charge_id ;; item_requests) echo request_id ;;
    pr_templates) echo template_id ;;       pr_template_items) echo template_item_id ;;
    approval_actions) echo approval_action_id ;; gl_exports) echo gl_export_id ;;
    *) return 1 ;;
  esac
}

touch "$LOG_FILE" 2>/dev/null || LOG_FILE=/dev/null

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  log "another sync is still running; skipping this run"
  exit 0
fi

[ -r "$SQL_TEMPLATE" ] || { log "FAILED: $SQL_TEMPLATE not found"; exit 1; }

# ── --verify: every Postgres id must exist in ClickHouse ─────────────────────
if [ "$MODE" = verify ]; then
  q=""
  for t in $TABLES; do
    k="$(id_column "$t")"
    [ -n "$q" ] && q="$q UNION ALL "
    q="$q SELECT '$t' AS table_name,
      (SELECT count(s.$k) FROM postgresql(pg_procurement, table = '$t') AS s) AS pg_rows,
      (SELECT uniqExact(toString($k)) FROM procurement.$t) AS ch_distinct_ids,
      (SELECT count() FROM postgresql(pg_procurement, table = '$t') AS s
         WHERE toString(s.$k) NOT IN (SELECT toString($k) FROM procurement.$t)) AS missing_in_ch"
  done
  if ! out="$(chq --query "SELECT * FROM ($q) ORDER BY table_name FORMAT TSVWithNames" 2>&1)"; then
    log "FAILED: $out"
    exit 1
  fi
  if command -v column >/dev/null; then echo "$out" | column -t; else echo "$out"; fi
  missing="$(echo "$out" | awk -F'\t' 'NR > 1 { s += $4 } END { print s + 0 }')"
  if [ "$missing" -ne 0 ]; then
    log "verify: $missing Postgres row(s) missing in ClickHouse"
    exit 1
  fi
  log "verify: OK (ch_distinct_ids > pg_rows only means ClickHouse also holds rows Postgres does not, e.g. pre-cutover rows not migrated)"
  exit 0
fi

# ── Watermark ────────────────────────────────────────────────────────────────
TS_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?$'

if [ "$MODE" != print ]; then
  if ! err="$(chq --query "CREATE TABLE IF NOT EXISTS procurement._sync_state (
      run_at          DateTime64(3, 'UTC'),
      synced_through  DateTime64(3, 'UTC'),
      mode            LowCardinality(String)
    ) ENGINE = MergeTree ORDER BY run_at" 2>&1)"; then
    log "FAILED: cannot reach ClickHouse or create _sync_state: $(echo "$err" | tr '\n' ' ' | cut -c1-500)"
    exit 1
  fi
fi

if ! RUN_START="$(chq --query "SELECT toString(now64(3, 'UTC'))" 2>&1)" \
   || ! [[ "$RUN_START" =~ $TS_RE ]]; then
  log "FAILED: cannot read the ClickHouse clock: $(echo "$RUN_START" | tr '\n' ' ' | cut -c1-500)"
  exit 1
fi

SINCE='1970-01-01 00:00:00.000'
if [ "$MODE" = incremental ] || [ "$MODE" = print ]; then
  state="$(chq --query "SELECT count(), toString(max(synced_through) - toIntervalMinute($OVERLAP_MINUTES))
                        FROM procurement._sync_state FORMAT TSV" 2>/dev/null || echo "0")"
  if [ "${state%%$'\t'*}" = 0 ]; then
    [ "$MODE" = incremental ] && MODE=full
    log "no previous successful run recorded; doing a full sync"
  else
    SINCE="${state#*$'\t'}"
  fi
fi
[[ "$SINCE" =~ $TS_RE ]] || { log "FAILED: unexpected watermark '$SINCE'"; exit 1; }

sql="$(sed -e "s/@SINCE@/$SINCE/g" -e "s/@RUN_START@/$RUN_START/g" \
           -e "s/@MODE@/$MODE/g" "$SQL_TEMPLATE")"

if [ "$MODE" = print ]; then
  echo "$sql"
  exit 0
fi

# ── Run ──────────────────────────────────────────────────────────────────────
log "start: rows changed after $SINCE UTC"
started=$SECONDS
if ! err="$(echo "$sql" | CHQ_STDIN=1 chq --multiquery 2>&1 >/dev/null)"; then
  log "FAILED after $((SECONDS - started))s; watermark not advanced: $(echo "$err" | tr '\n' ' ' | cut -c1-2000)"
  exit 1
fi
log "OK in $((SECONDS - started))s; watermark now $RUN_START UTC"
