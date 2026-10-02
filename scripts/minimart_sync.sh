#!/usr/bin/env bash
# minimart (Postgres database `minimart` on mmi-postgres) -> ClickHouse database `minimart`.
# Runs on the host every 15 minutes from /etc/cron.d/minimart-ch-sync.
#
#   scripts/minimart_sync.sh            incremental run: every mirrored table is brought up to date
#                                       (snapshot tables are re-copied, incremental tables get the
#                                       rows newer than their watermark minus a 60 min overlap).
#                                       A table without a successful run for the CURRENT plan is
#                                       loaded in full first. Tables are independent: one failing
#                                       table does not stop the others (exit 1 at the end).
#   scripts/minimart_sync.sh --full     rebuild every table from Postgres (snapshot swap; also
#                                       repairs hard deletes and drift of the incremental tables)
#   scripts/minimart_sync.sh --init     read the Postgres catalog and (re)generate the mirror: create
#                                       database minimart, its state tables and one mirror table per
#                                       Postgres table, store the generated plan. Idempotent. Re-run
#                                       it after schema drift (see --verify) or an override change.
#   scripts/minimart_sync.sh --verify   compare Postgres and ClickHouse (row counts, sums of every
#                                       numeric column, max of every date/timestamp column, content
#                                       hash up to 1,000,000 rows), list schema drift and the
#                                       sensitive columns that are NOT mirrored; no writes; exit 1
#                                       on any mismatch, drift or error
#   scripts/minimart_sync.sh --print [table]
#                                       print what --init would generate (strategy and reason per
#                                       table, excluded columns, DDL and the sync SQL); no writes
#   scripts/minimart_sync.sh --grant-args
#                                       prints two lines, allow_cols=... and deny_cols=... (the
#                                       allow-column / exclude-column lines of the overrides file) to
#                                       be passed as `psql -v` variables to db/minimart_ro_grants.sql
#   scripts/minimart_sync.sh -h         this text
#
# HOW IT WORKS. Nothing about the minimart schema is hard-coded. --init asks ClickHouse to read the
# catalog of the Postgres database (pg_catalog / information_schema) through the named collection
# pg_minimart (read-only role minimart_ro; db/clickhouse-config.d/50-pg-minimart.xml), runs the
# planner query printed by scripts/minimart_gen_schema.sh (the strategy rule, the type mapping and the
# sensitive-column rule are documented in its header) and stores per table the generated DDL and sync
# SQL in minimart._plan (+ minimart._plan_cols for drift detection). A sync run then fills in the
# watermark and pipes the stored SQL into clickhouse-client. No Postgres credential passes through
# this script or cron. By default the client runs inside the procurement_clickhouse container,
# logged in with that container's own CLICKHOUSE_USER / CLICKHOUSE_PASSWORD; nothing is echoed.
#
# Optional overrides file (default <repo>/minimart_sync_overrides.conf), checked by --init:
#     exclude <table>                       do not mirror it
#     snapshot <table>                      force a full copy every run
#     incremental <table> <column> [updated|created]
#     exclude-column <table>.<column>       never mirror this column
#     allow-column <table>.<column>         mirror a column that the name rule or bytea rule excluded
#     string-column <table>.<column>        keep the Postgres text form (no typed conversion)
#   names with spaces or capitals go in double quotes, # starts a comment.
#
# Environment (all optional)
#   MINIMART_CH_CONTAINER  container name (default procurement_clickhouse)
#   MINIMART_SYNC_LOG      default /var/log/minimart-ch-sync.log
#   MINIMART_SYNC_LOCK     default /var/lock/minimart-ch-sync.lock
#   MINIMART_SYNC_TIMEOUT  seconds allowed per ClickHouse call (default 900)
#   MINIMART_OVERRIDES     overrides file; MINIMART_SMALL_ROWS  snapshot threshold (default 100000)
#   MINIMART_OVERLAP_MINUTES  incremental overlap (default 60)
#   MINIMART_VERIFY_HASH_MAX_ROWS  content hash only for tables up to this many rows (default 1000000)
#
# Safe to re-run at any time. A table's watermark (minimart._sync_state) is written by the very last
# statement of that table's script, so a failed table keeps its old watermark and its live mirror
# table; the next run redoes the work. A second run while one is active is skipped (flock).
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GEN="$REPO_DIR/scripts/minimart_gen_schema.sh"
SCHEMA_FILE="$REPO_DIR/db/minimart_ch_schema.sql"
CONTAINER="${MINIMART_CH_CONTAINER:-procurement_clickhouse}"
LOG_FILE="${MINIMART_SYNC_LOG:-/var/log/minimart-ch-sync.log}"
LOCK_FILE="${MINIMART_SYNC_LOCK:-/var/lock/minimart-ch-sync.lock}"
RUN_TIMEOUT="${MINIMART_SYNC_TIMEOUT:-900}"
OVERLAP_MINUTES="${MINIMART_OVERLAP_MINUTES:-60}"
HASH_MAX_ROWS="${MINIMART_VERIFY_HASH_MAX_ROWS:-1000000}"
OVERRIDES_FILE="${MINIMART_OVERRIDES:-$REPO_DIR/minimart_sync_overrides.conf}"
export MINIMART_OVERRIDES="$OVERRIDES_FILE"
for v in RUN_TIMEOUT OVERLAP_MINUTES HASH_MAX_ROWS; do
  [[ "${!v}" =~ ^[0-9]+$ ]] || { echo "$v must be a number" >&2; exit 2; }
done
MAX_EXEC=$(( RUN_TIMEOUT > 90 ? RUN_TIMEOUT - 30 : 60 ))

MODE=incremental
PRINT_TABLE=""
USAGE="usage: $0 [--full|--init|--verify|--print [table]|--grant-args|-h]"
case "${1:-}" in
  "")          ;;
  --full)      MODE=full ;;
  --init)      MODE=init ;;
  --verify)    MODE=verify ;;
  --print)     MODE=print; PRINT_TABLE="${2:-}"; [ "$#" -le 2 ] || { echo "$USAGE" >&2; exit 2; } ;;
  --grant-args) MODE=grant-args ;;
  -h|--help)   sed -n '2,/^set -euo/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "$USAGE" >&2; exit 2 ;;
esac
if [ "$MODE" != print ]; then [ "$#" -le 1 ] || { echo "$USAGE" >&2; exit 2; }; fi

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

# SQL string literal (with quotes) from a bash string.
lit() { printf "'%s'" "$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e "s/'/\\\\'/g")"; }

# Back-quoted identifier from a bash string.
bqi() { printf '`%s`' "$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/`/\\`/g')"; }

# Best effort after a failed script: drop that table's staging and source tables so that no
# Postgres connection of the source table stays open.
cleanup_table() { # cleanup_table <postgres table name>
  chq --query "DROP TABLE IF EXISTS minimart.$(bqi "_src_$1") SYNC" >/dev/null 2>&1 || true
  chq --query "DROP TABLE IF EXISTS minimart.$(bqi "_new_$1") SYNC" >/dev/null 2>&1 || true
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

# ClickHouse client inside the container, logged in with the container's env. Every call is
# time-limited so a hung run cannot hold the lock forever. CHQ_STDIN=1 attaches stdin (only for
# the piped multi-query calls); otherwise stdin stays detached so an interactive run cannot eat
# pasted input.
chq() {
  local i=()
  [ "${CHQ_STDIN:-0}" = 1 ] && i=(-i)
  # shellcheck disable=SC2016  # expanded by sh inside the container, on purpose
  run_timeout "$RUN_TIMEOUT" docker exec ${i[@]+"${i[@]}"} "$CONTAINER" sh -c \
    'exec clickhouse-client --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" "$@"' \
    chq "$@"
}

touch "$LOG_FILE" 2>/dev/null || LOG_FILE=/dev/null

# ── modes that need neither lock nor ClickHouse ──────────────────────────────
if [ "$MODE" = grant-args ]; then "$GEN" --grant-args; exit $?; fi

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

[ -x "$GEN" ] || [ -r "$GEN" ] || { log "FAILED: $GEN not found"; exit 1; }

# Plan id of the currently stored plan (empty if none). Sets PLAN_ID or fails.
load_plan() {
  local have
  if ! have="$(chq --query "SELECT count() FROM system.tables WHERE database = 'minimart' AND name IN ('_sync_state', '_plan_current', '_plan', '_plan_cols')" 2>&1)"; then
    log "FAILED: cannot reach ClickHouse: $(oneline "$have")"; return 1
  fi
  if [ "$have" != 4 ]; then
    log "FAILED: ClickHouse database minimart is not initialised ($have of 4 state tables found); run: scripts/minimart_sync.sh --init"; return 1
  fi
  if ! PLAN_ID="$(chq --query "SELECT argMax(plan_id, planned_at) FROM minimart._plan_current" 2>&1)"; then
    log "FAILED: cannot read the plan: $(oneline "$PLAN_ID")"; return 1
  fi
  if ! [[ "$PLAN_ID" =~ ^[A-Za-z0-9_-]{4,64}$ ]]; then
    log "FAILED: no generated plan stored yet; run: scripts/minimart_sync.sh --init"; return 1
  fi
}

# Schema drift: live Postgres catalog vs the stored plan. Fills DRIFT_LINES (TSV: kind table
# column detail) and SKIP_TABLES (newline separated tables that must not be synced until --init
# is re-run). Sets DRIFT_OK=0 if the check could not run.
DRIFT_LINES=""; SKIP_TABLES=""; DRIFT_OK=1
check_drift() {
  local out
  DRIFT_LINES=""; SKIP_TABLES=""; DRIFT_OK=1
  if ! "$GEN" --check-overrides >/dev/null 2>"${TMPDIR:-/tmp}/minimart_ovr.$$"; then
    log "WARNING: overrides file invalid, schema drift not checked: $(oneline "$(cat "${TMPDIR:-/tmp}/minimart_ovr.$$")" 300)"
    rm -f "${TMPDIR:-/tmp}/minimart_ovr.$$"; DRIFT_OK=0; return 0
  fi
  rm -f "${TMPDIR:-/tmp}/minimart_ovr.$$"
  if ! out="$("$GEN" --drift | CHQ_STDIN=1 chq --multiquery --format TSVRaw 2>&1)"; then
    log "FAILED: schema drift check: $(oneline "$out" 1500)"; DRIFT_OK=0; return 1
  fi
  DRIFT_LINES="$out"
  SKIP_TABLES="$(printf '%s\n' "$out" | awk -F'\t' '$1 == "dropped_column" || $1 == "changed_column" || $1 == "dropped_table" { print $2 }' | sort -u)"
  return 0
}
log_drift() {
  [ -n "$DRIFT_LINES" ] || return 0
  printf '%s\n' "$DRIFT_LINES" | awk -F'\t' '{ printf "DRIFT [%s] %s%s: %s\n", $1, $2, ($3 == "" ? "" : "." $3), $4 }' | while IFS= read -r l; do log "$l"; done
}

# ── --print ──────────────────────────────────────────────────────────────────
print_plan() {
  local tables cols stored sql_out skipped_objs
  if ! tables="$("$GEN" --summary | CHQ_STDIN=1 chq --multiquery --format TSVRaw 2>&1)"; then
    echo "FAILED: $(oneline "$tables" 1500)" >&2; exit 1
  fi
  if ! cols="$("$GEN" --cols | CHQ_STDIN=1 chq --multiquery --format TSVRaw 2>&1)"; then
    echo "FAILED: $(oneline "$cols" 1500)" >&2; exit 1
  fi
  stored="$(chq --query "SELECT table_name, plan_hash FROM minimart._plan WHERE plan_id = (SELECT argMax(plan_id, planned_at) FROM minimart._plan_current) FORMAT TSVRaw" 2>/dev/null || true)"
  echo "== minimart mirror plan: what --init would generate from the live Postgres catalog (nothing is written) =="
  if [ -r "$OVERRIDES_FILE" ]; then
    echo "overrides file : $OVERRIDES_FILE ($(grep -cvE '^[[:space:]]*(#|$)' "$OVERRIDES_FILE" || true) active lines)"
  else
    echo "overrides file : $OVERRIDES_FILE (absent: none applied)"
  fi
  echo "small tables   : below ${MINIMART_SMALL_ROWS:-100000} estimated rows are snapshots (MINIMART_SMALL_ROWS)"
  echo
  echo "-- tables"
  {
    printf 'TABLE\tSTRATEGY\tROWS(est)\tKEY\tCHANGE_COLUMN\tVS_STORED_PLAN\tREASON\n'
    printf '%s\n' "$tables" | MM_STORED="$stored" awk -F'\t' '
      BEGIN { n = split(ENVIRON["MM_STORED"], ls, "\n"); for (i = 1; i <= n; i++) { split(ls[i], p, "\t"); st[p[1]] = p[2] } }
      NF { key = ($5 == "" ? "-" : $5); chg = ($6 == "" ? "-" : $6); gsub(/ /, "", key)
        if ($2 == "excluded") vs = "-"
        else if (!($1 in st)) vs = "new"
        else if (st[$1] == $7) vs = "same"
        else vs = "DIFFERENT"
        tbl = $1; gsub(/ /, "_", tbl)
        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", tbl, $2, $4, key, chg, vs, $3 }'
  } | { if command -v column >/dev/null 2>&1; then column -t -s "$(printf '\t')"; else cat; fi; }
  echo "   (spaces in table and key names are shown as _ in this list; a stored plan marked DIFFERENT or new is adopted by --init)"
  echo
  echo "-- columns NOT mirrored (a column that is excluded is never read from Postgres)"
  printf '%s\n' "$cols" | awk -F'\t' '$8 == 0 && $9 != "" { printf "  %s.%s  [%s]\n", $1, $2, $9 }' | sort | { grep . || echo "  none"; }
  echo
  echo "-- never mirrored: views, materialized views, foreign tables, tables of schemas other than public"
  if skipped_objs="$("$GEN" --skipped | CHQ_STDIN=1 chq --multiquery --format TSVRaw 2>&1)"; then
    printf '%s\n' "$skipped_objs" | awk -F'\t' 'NF >= 3 { printf "  %s.%s  [%s]\n", $1, $2, $3 }' | { grep . || echo "  none"; }
  else echo "  (could not list: $(oneline "$skipped_objs" 200))"; fi
  echo
  echo "-- sensitive-name columns that minimart_ro CAN read (should be none: run db/minimart_ro_grants.sql)"
  printf '%s\n' "$cols" | awk -F'\t' '$6 == 1 && $7 == 1 { printf "  WARNING %s.%s\n", $1, $2 }' | sort | { grep . || echo "  none"; }
  echo
  if [ -n "$PRINT_TABLE" ]; then
    echo "== generated SQL of table $PRINT_TABLE =="
    if ! sql_out="$("$GEN" --sql "$PRINT_TABLE" | CHQ_STDIN=1 chq --multiquery --format TSVRaw 2>&1)"; then echo "FAILED: $(oneline "$sql_out" 1500)" >&2; exit 1; fi
    [ -n "$sql_out" ] || { echo "no mirrored table named $PRINT_TABLE in the live catalog plan"; exit 1; }
  else
    echo "== generated SQL: per table the source table, the mirror table and the statements run every 15 minutes =="
    echo "   (@SINCE@ @SINCE_PAD@ @RUN_START@ @MODE@ @MAX_EXEC@ are filled in at run time;"
    echo "    '--print <table>' also shows the full-load and verify SQL of one table)"
    echo
    if ! sql_out="$("$GEN" --sql | CHQ_STDIN=1 chq --multiquery --format TSVRaw 2>&1)"; then echo "FAILED: $(oneline "$sql_out" 1500)" >&2; exit 1; fi
  fi
  printf '%s\n' "$sql_out"
  exit 0
}
if [ "$MODE" = print ]; then print_plan; fi

# ── --init ───────────────────────────────────────────────────────────────────
if [ "$MODE" = init ]; then
  [ -r "$SCHEMA_FILE" ] || { log "FAILED: $SCHEMA_FILE not found"; exit 1; }
  if ! ovr_err="$("$GEN" --check-overrides 2>&1 >/dev/null)"; then log "FAILED: $(oneline "$ovr_err" 800)"; exit 1; fi
  if ! err="$(CHQ_STDIN=1 chq --multiquery < "$SCHEMA_FILE" 2>&1 >/dev/null)"; then
    log "FAILED: applying $SCHEMA_FILE: $(oneline "$err" 1500)"; exit 1
  fi
  NEW_PLAN="$(date -u +%Y%m%d%H%M%S)-$$"
  if ! err="$("$GEN" --install "$NEW_PLAN" | CHQ_STDIN=1 chq --multiquery 2>&1 >/dev/null)"; then
    log "FAILED: generating the plan from the Postgres catalog (nothing was activated): $(oneline "$err" 1500)"; exit 1
  fi
  if ! n_planned="$(chq --query "SELECT tables FROM minimart._plan_current WHERE plan_id = '$NEW_PLAN'" 2>&1)" || ! [[ "$n_planned" =~ ^[0-9]+$ ]]; then
    log "FAILED: the new plan was not recorded: $(oneline "$n_planned")"; exit 1
  fi
  PLAN_ID="$NEW_PLAN"
  failed=0; created=0
  if ! rows="$(chq --query "SELECT table_name, src_ddl, dest_ddl FROM minimart._plan WHERE plan_id = '$PLAN_ID' ORDER BY table_name FORMAT TSVRaw" 2>&1)"; then
    log "FAILED: cannot read the new plan: $(oneline "$rows")"; exit 1
  fi
  while IFS=$'\t' read -r t src dest; do
    [ -n "$t" ] || continue
    # the source table is created only to check its DDL, then dropped (it lives only inside a table's sync script)
    if err="$(printf '%s;\n%s;\nDROP TABLE IF EXISTS minimart.%s SYNC;\n' "$src" "$dest" "$(bqi "_src_$t")" | CHQ_STDIN=1 chq --multiquery 2>&1 >/dev/null)"; then
      created=$((created + 1))
    else
      failed=$((failed + 1)); log "FAILED: creating tables for $t: $(oneline "$err" 800)"
    fi
  done <<<"$rows"
  # Housekeeping: drop leftover source/staging tables of failed runs, keep the last 5 plans.
  chq --query "SELECT name FROM system.tables WHERE database = 'minimart' AND (startsWith(name, '_new_') OR startsWith(name, '_src_')) FORMAT TSVRaw" 2>/dev/null \
    | while IFS= read -r stale; do
        [ -n "$stale" ] && chq --query "DROP TABLE IF EXISTS minimart.$(bqi "$stale") SYNC" >/dev/null 2>&1 || true
      done
  chq --query "ALTER TABLE minimart._plan DELETE WHERE plan_id NOT IN (SELECT plan_id FROM minimart._plan_current ORDER BY planned_at DESC LIMIT 5) SETTINGS mutations_sync = 1" >/dev/null 2>&1 || true
  chq --query "ALTER TABLE minimart._plan_cols DELETE WHERE plan_id NOT IN (SELECT plan_id FROM minimart._plan_current ORDER BY planned_at DESC LIMIT 5) SETTINGS mutations_sync = 1" >/dev/null 2>&1 || true
  summary="$(chq --query "SELECT concat(toString(countIf(strategy = 'snapshot')), ' snapshot, ', toString(countIf(strategy = 'incremental_updated')), ' incremental_updated, ', toString(countIf(strategy = 'incremental_created')), ' incremental_created') FROM minimart._plan WHERE plan_id = '$PLAN_ID'" 2>/dev/null || true)"
  check_drift || true
  if [ "$failed" -ne 0 ]; then log "FAILED: plan $PLAN_ID stored but $failed table(s) could not be created"; exit 1; fi
  log "OK: plan $PLAN_ID: $n_planned tables ($summary); run scripts/minimart_sync.sh --print to review, then --full for the first load"
  # sensitive columns left out, drift still open (e.g. an unreadable table)
  chq --query "SELECT table_name, col, reason FROM minimart._plan_cols WHERE plan_id = '$PLAN_ID' AND NOT mirrored AND sensitive ORDER BY table_name, pos FORMAT TSVRaw" 2>/dev/null \
    | awk -F'\t' 'NF { printf "not mirrored (sensitive): %s.%s\n", $1, $2 }' | while IFS= read -r l; do log "$l"; done
  log_drift
  chq --query "SELECT 1" >/dev/null 2>&1 && "$GEN" --skipped | CHQ_STDIN=1 chq --multiquery --format TSVRaw 2>/dev/null \
    | awk -F'\t' 'NF >= 3 { printf "not mirrored (%s): %s.%s\n", $3, $1, $2 }' | while IFS= read -r l; do log "$l"; done
  exit 0
fi

# ── --verify ─────────────────────────────────────────────────────────────────
if [ "$MODE" = verify ]; then
  load_plan || exit 1
  check_drift || exit 1
  problems=0
  [ "$DRIFT_OK" = 1 ] || problems=$((problems + 1))
  out_file="$(mktemp "${TMPDIR:-/tmp}/minimart_verify.XXXXXX")"
  trap 'rm -f "$out_file"' EXIT
  if ! rows="$(chq --query "SELECT p.table_name, if(ifNull(t.total_rows, 0) <= $HASH_MAX_ROWS, 1, 0) FROM minimart._plan AS p LEFT JOIN (SELECT name, total_rows FROM system.tables WHERE database = 'minimart') AS t ON t.name = p.table_name WHERE p.plan_id = '$PLAN_ID' ORDER BY p.table_name FORMAT TSVRaw" 2>&1)"; then
    log "FAILED: cannot read the plan: $(oneline "$rows")"; exit 1
  fi
  ntab=0
  while IFS=$'\t' read -r t with_hash; do
    [ -n "$t" ] || continue
    ntab=$((ntab + 1))
    if printf '%s\n' "$SKIP_TABLES" | grep -qxF -- "$t"; then
      printf '%s\t%s\t%s\t%s\t%s\n' "$t" "(skipped: schema drift)" "-" "-" "MISMATCH" >> "$out_file"; continue
    fi
    if ! srcddl="$(chq --query "SELECT src_ddl FROM minimart._plan WHERE plan_id = '$PLAN_ID' AND table_name = $(lit "$t") FORMAT TSVRaw" 2>&1)" || [ -z "$srcddl" ]; then
      printf '%s\t%s\t%s\t%s\t%s\n' "$t" "(error)" "$(oneline "$srcddl" 150)" "-" "MISMATCH" >> "$out_file"; continue
    fi
    if ! vsql="$(chq --query "SELECT verify_sql FROM minimart._plan WHERE plan_id = '$PLAN_ID' AND table_name = $(lit "$t") FORMAT TSVRaw" 2>&1)"; then
      printf '%s\t%s\t%s\t%s\t%s\n' "$t" "(error)" "$(oneline "$vsql" 150)" "-" "MISMATCH" >> "$out_file"; continue
    fi
    hsql=""
    if [ "$with_hash" = 1 ]; then
      hsql="$(chq --query "SELECT verify_hash_sql FROM minimart._plan WHERE plan_id = '$PLAN_ID' AND table_name = $(lit "$t") FORMAT TSVRaw" 2>/dev/null || true)"
    fi
    q="$vsql"
    [ -z "$hsql" ] || q="$vsql
UNION ALL
$hsql"
    # one source connection at a time: the source table exists only for the duration of this check
    if ! res="$(printf '%s;\n%s;\nDROP TABLE IF EXISTS minimart.%s SYNC;\n' "$srcddl" "$q" "$(bqi "_src_$t")" | CHQ_STDIN=1 chq --multiquery --format TSV 2>&1)"; then
      printf '%s\t%s\t%s\t%s\t%s\n' "$t" "(error)" "$(oneline "$res" 150)" "-" "MISMATCH" >> "$out_file"; cleanup_table "$t"; continue
    fi
    printf '%s\n' "$res" | awk -F'\t' -v hash_skipped="$([ "$with_hash" = 1 ] && echo 0 || echo 1)" '
      NF >= 5 {
        res = "ok"
        if ($3 != $4) {
          if ($5 == "float") { a = $3 + 0; b = $4 + 0; d = a - b; if (d < 0) d = -d; m = (a < 0 ? -a : a); n = (b < 0 ? -b : b); if (n > m) m = n; if (m < 1) m = 1
                               if (d > 1e-6 * m) res = "MISMATCH" }
          else res = "MISMATCH"
        }
        printf "%s\t%s\t%s\t%s\t%s\n", $1, $2, $3, $4, res; t = $1 }
      END { if (hash_skipped == 1 && t != "") printf "%s\tcontent hash\t(skipped: too many rows)\t-\tok\n", t }' >> "$out_file"
  done <<<"$rows"
  echo "== $ntab mirrored tables, Postgres vs ClickHouse =="
  { printf 'TABLE\tMETRIC\tPOSTGRES\tCLICKHOUSE\tRESULT\n'; cat "$out_file"; } | { if command -v column >/dev/null 2>&1; then column -t -s "$(printf '\t')"; else cat; fi; }
  bad="$(awk -F'\t' '$5 == "MISMATCH" { n++ } END { print n + 0 }' "$out_file")"
  checks="$(awk 'END { print NR }' "$out_file")"
  problems=$((problems + bad))
  # never-synced tables
  never="$(chq --query "SELECT p.table_name FROM minimart._plan AS p LEFT JOIN (SELECT table_name, argMax(plan_hash, run_at) AS last_hash FROM minimart._sync_state GROUP BY table_name) AS s ON s.table_name = p.table_name WHERE p.plan_id = '$PLAN_ID' AND s.last_hash != p.plan_hash ORDER BY p.table_name FORMAT TSVRaw" 2>/dev/null || true)"
  if [ -n "$never" ]; then echo; echo "== tables with no successful sync of the current plan (run --full) =="; printf '%s\n' "$never" | sed 's/^/  /'; problems=$((problems + 1)); fi
  # sensitive columns left out, orphan mirror tables
  echo; echo "== sensitive columns that are NOT mirrored =="
  chq --query "SELECT table_name, col, if(readable = 1, 'READABLE by minimart_ro: run db/minimart_ro_grants.sql', 'not readable by minimart_ro') FROM minimart._plan_cols WHERE plan_id = '$PLAN_ID' AND NOT mirrored AND sensitive ORDER BY table_name, pos FORMAT TSVRaw" 2>/dev/null \
    | awk -F'\t' 'NF { printf "  %s.%s  (%s)\n", $1, $2, $3 }' | { grep . || echo "  none"; }
  orphans="$(chq --query "SELECT name FROM system.tables WHERE database = 'minimart' AND NOT startsWith(name, '_') AND name NOT IN (SELECT table_name FROM minimart._plan WHERE plan_id = '$PLAN_ID') ORDER BY name FORMAT TSVRaw" 2>/dev/null || true)"
  if [ -n "$orphans" ]; then echo; echo "== mirror tables that are not in the plan (excluded or dropped in Postgres; DROP TABLE minimart.<name> if no longer wanted) =="; printf '%s\n' "$orphans" | sed 's/^/  /'; fi
  if [ -n "$DRIFT_LINES" ]; then
    echo; echo "== SCHEMA DRIFT: Postgres changed since the plan was generated =="
    printf '%s\n' "$DRIFT_LINES" | awk -F'\t' '{ printf "  %-18s %s%s  %s\n", $1, $2, ($3 == "" ? "" : "." $3), $4 }'
    problems=$((problems + $(printf '%s\n' "$DRIFT_LINES" | awk 'END { print NR }')))
  fi
  if [ "$problems" -ne 0 ]; then
    log "verify: $problems problem(s) ($bad of $checks checks MISMATCH; the source is live: run a sync first, then verify again; drift: scripts/minimart_sync.sh --init)"
    exit 1
  fi
  log "verify: OK ($checks checks over $ntab tables, Postgres and ClickHouse agree, no schema drift)"
  exit 0
fi

# ── incremental / full ───────────────────────────────────────────────────────
TS_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?$'
load_plan || exit 1
if ! RUN_START="$(chq --query "SELECT toString(now64(3, 'UTC'))" 2>&1)" || ! [[ "$RUN_START" =~ $TS_RE ]]; then
  log "FAILED: cannot read the ClickHouse clock: $(oneline "$RUN_START")"; exit 1
fi
check_drift || exit 1
log_drift
if ! rows="$(chq --query "SELECT table_name, strategy, plan_hash FROM minimart._plan WHERE plan_id = '$PLAN_ID' ORDER BY table_name FORMAT TSVRaw" 2>&1)"; then
  log "FAILED: cannot read the plan: $(oneline "$rows")"; exit 1
fi
started=$SECONDS; n_ok=0; n_fail=0; n_skip=0; n_full=0; failed_list=""
while IFS=$'\t' read -r t strategy phash; do
  [ -n "$t" ] || continue
  if printf '%s\n' "$SKIP_TABLES" | grep -qxF -- "$t"; then
    n_skip=$((n_skip + 1)); failed_list="$failed_list $t(drift)"
    log "SKIPPED $t: schema drift (see DRIFT lines); run scripts/minimart_sync.sh --init to adopt it"; continue
  fi
  # this table's watermark for the CURRENT plan; none -> full load
  # (the LAST run of the table must have used the current plan: after --init changed it, and after a change
  # that was undone again, the mirror table has another structure and has to be reloaded in full)
  if ! state="$(chq --query "SELECT if(argMax(plan_hash, run_at) = $(lit "$phash"), count(), 0), toString(max(synced_through) - toIntervalMinute($OVERLAP_MINUTES)), toString(max(synced_through) - toIntervalMinute($((OVERLAP_MINUTES + 1440)))) FROM minimart._sync_state WHERE table_name = $(lit "$t") FORMAT TSV" 2>&1)"; then
    n_fail=$((n_fail + 1)); failed_list="$failed_list $t"; log "FAILED $t: cannot read the watermark: $(oneline "$state")"; continue
  fi
  SINCE='1970-01-01 00:00:00.000'; SINCE_PAD="$SINCE"; col=sql; why=""
  if [ "${state%%$'\t'*}" = 0 ]; then MODE_SQL=full; why="its last run used another plan, or none"
  elif [ "$MODE" = full ]; then MODE_SQL=full; why=""
  else
    MODE_SQL=incremental; rest="${state#*$'\t'}"; SINCE="${rest%%$'\t'*}"; SINCE_PAD="${rest#*$'\t'}"
  fi
  [[ "$SINCE" =~ $TS_RE ]] && [[ "$SINCE_PAD" =~ $TS_RE ]] || { n_fail=$((n_fail + 1)); failed_list="$failed_list $t"; log "FAILED $t: unexpected watermark '$state'"; continue; }
  if [ "$MODE_SQL" = full ]; then col=full_sql; else col=incr_sql; fi
  if ! sqltext="$(chq --query "SELECT $col FROM minimart._plan WHERE plan_id = '$PLAN_ID' AND table_name = $(lit "$t") FORMAT TSVRaw" 2>&1)" || [ -z "$sqltext" ]; then
    n_fail=$((n_fail + 1)); failed_list="$failed_list $t"; log "FAILED $t: cannot read its SQL: $(oneline "$sqltext")"; continue
  fi
  sqltext="$(printf '%s\n' "$sqltext" | sed -e "s/@SINCE_PAD@/$SINCE_PAD/g" -e "s/@SINCE@/$SINCE/g" -e "s/@RUN_START@/$RUN_START/g" \
                                           -e "s/@MODE@/$MODE_SQL/g" -e "s/@MAX_EXEC@/$MAX_EXEC/g")"
  t0=$SECONDS
  if err="$(printf '%s\n' "$sqltext" | CHQ_STDIN=1 chq --multiquery 2>&1 >/dev/null)"; then
    n_ok=$((n_ok + 1)); [ "$MODE_SQL" = full ] && n_full=$((n_full + 1))
    if [ "$MODE" = full ] || [ "$MODE_SQL" = full ]; then log "table $t ($strategy, $MODE_SQL${why:+: $why}) OK in $((SECONDS - t0))s"; fi
  else
    n_fail=$((n_fail + 1)); failed_list="$failed_list $t"
    log "FAILED $t after $((SECONDS - t0))s; its watermark was not advanced: $(oneline "$err" 1500)"
    cleanup_table "$t"
  fi
done <<<"$rows"
if [ "$n_fail" -ne 0 ] || [ "$n_skip" -ne 0 ]; then
  log "PARTIAL: $n_ok tables ok, $n_fail failed, $n_skip skipped for drift in $((SECONDS - started))s; not synced:$failed_list"
  exit 1
fi
log "OK in $((SECONDS - started))s: $n_ok tables ($n_full loaded in full); newest watermark $RUN_START UTC"
