#!/usr/bin/env bash
# End-to-end test for migrate_ch_to_pg.js against a fake ClickHouse and a local
# Postgres (Homebrew, socket in /tmp, current OS user, no password).
#
#   bash test/run_migration_test.sh
#
# Leaves the database procurement_migtest in place (loaded from the base fixtures).
set -uo pipefail

cd "$(dirname "$0")/.."
DB=procurement_migtest
PORT=${FAKE_CH_PORT:-18123}
FIX=test/fixtures
LOG=$(mktemp -d)/migtest
mkdir -p "$LOG"

export PGHOST=${PGHOST:-/tmp} PGDATABASE=$DB
unset PGPASSWORD
export CLICKHOUSE_HOST=127.0.0.1 CLICKHOUSE_PORT=$PORT CLICKHOUSE_DB=procurement CLICKHOUSE_USER=procurement_user CLICKHOUSE_PASSWORD=fake-secret

PASS=0; FAIL=0; FAKE_PID=
ok()   { PASS=$((PASS+1)); echo "  PASS  $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL  $1"; }
q()    { psql -X -q -tA -v ON_ERROR_STOP=1 -c "$1"; }
check() { # check "description" "sql" "expected"
  local got; got=$(q "$2" 2>&1)
  if [[ "$got" == "$3" ]]; then ok "$1"; else bad "$1 — expected [$3] got [$got]"; fi
}
expect_exit() { # expect_exit "desc" expected actual
  if [[ "$3" == "$2" ]]; then ok "$1 (exit $3)"; else bad "$1 — expected exit $2, got $3"; fi
}
expect_grep() { # expect_grep "desc" pattern file
  if grep -qF -- "$2" "$3"; then ok "$1"; else bad "$1 — '$2' not in output"; fi
}

stop_fake() { [[ -n "$FAKE_PID" ]] && kill "$FAKE_PID" 2>/dev/null; wait "$FAKE_PID" 2>/dev/null; FAKE_PID=; }
trap stop_fake EXIT
start_fake() { # start_fake dir[:dir...]
  stop_fake
  FIXTURE_DIRS="$1" FAKE_CH_PORT=$PORT FAKE_CH_PASSWORD=$CLICKHOUSE_PASSWORD FAKE_NO_QUOTE_DECIMALS=${2:-0} \
    node test/fake_clickhouse.js 2>"$LOG/fake.log" &
  FAKE_PID=$!
  for _ in $(seq 1 50); do curl -s "http://127.0.0.1:$PORT/ping" >/dev/null 2>&1 && return 0; sleep 0.1; done
  echo "fake ClickHouse did not start"; cat "$LOG/fake.log"; exit 1
}
migrate() { # migrate logname [args...]  → sets RC
  local name=$1; shift
  node migrate_ch_to_pg.js "$@" >"$LOG/$name.out" 2>&1; RC=$?
}
checksum() { # md5 of every migrated table's content (gl_exports.created_at defaults to now(), excluded)
  q "SELECT md5(string_agg(x, '|' ORDER BY x)) FROM (
       SELECT 'purposes'||to_jsonb(t)::text x FROM purposes t UNION ALL
       SELECT 'users'||to_jsonb(t)::text FROM users t UNION ALL
       SELECT 'vendors'||to_jsonb(t)::text FROM vendors t UNION ALL
       SELECT 'items'||to_jsonb(t)::text FROM items t UNION ALL
       SELECT 'pr_templates'||to_jsonb(t)::text FROM pr_templates t UNION ALL
       SELECT 'pr_template_items'||to_jsonb(t)::text FROM pr_template_items t UNION ALL
       SELECT 'pr'||to_jsonb(t)::text FROM purchase_requests t UNION ALL
       SELECT 'pri'||to_jsonb(t)::text FROM purchase_request_items t UNION ALL
       SELECT 'po'||to_jsonb(t)::text FROM purchase_orders t UNION ALL
       SELECT 'poi'||to_jsonb(t)::text FROM purchase_order_items t UNION ALL
       SELECT 'poc'||to_jsonb(t)::text FROM purchase_order_charges t UNION ALL
       SELECT 'aa'||to_jsonb(t)::text FROM approval_actions t UNION ALL
       SELECT 'gl'||(to_jsonb(t)-'created_at')::text FROM gl_exports t UNION ALL
       SELECT 'ir'||to_jsonb(t)::text FROM item_requests t UNION ALL
       SELECT 'dc'||to_jsonb(t)::text FROM doc_counters t) s"
}
seqval() { q "SELECT last_value FROM pg_sequences WHERE schemaname = current_schema() AND sequencename = split_part(pg_get_serial_sequence('$1','$2'), '.', 2)"; }

echo "== setup: fresh $DB =="
dropdb --if-exists "$DB" 2>/dev/null
createdb "$DB" || { echo "createdb failed"; exit 1; }
psql -X -q -v ON_ERROR_STOP=1 -f db/postgres_schema.sql >/dev/null || { echo "schema load failed"; exit 1; }
ok "schema loaded with ON_ERROR_STOP"

base_assertions() {
  check "row counts per table" "SELECT string_agg(n::text, ',' ORDER BY o) FROM (
      SELECT 1 o, count(*) n FROM purposes UNION ALL SELECT 2, count(*) FROM users UNION ALL
      SELECT 3, count(*) FROM vendors UNION ALL SELECT 4, count(*) FROM items UNION ALL
      SELECT 5, count(*) FROM pr_templates UNION ALL SELECT 6, count(*) FROM pr_template_items UNION ALL
      SELECT 7, count(*) FROM purchase_requests UNION ALL SELECT 8, count(*) FROM purchase_request_items UNION ALL
      SELECT 9, count(*) FROM purchase_orders UNION ALL SELECT 10, count(*) FROM purchase_order_items UNION ALL
      SELECT 11, count(*) FROM purchase_order_charges UNION ALL SELECT 12, count(*) FROM approval_actions UNION ALL
      SELECT 13, count(*) FROM gl_exports UNION ALL SELECT 14, count(*) FROM item_requests) s" "2,5,3,5,2,2,4,5,4,3,1,2,1,0"
  check "live counts users/pr/pri/po" "SELECT (SELECT count(*) FROM users WHERE is_deleted=0)||','||(SELECT count(*) FROM purchase_requests WHERE is_deleted=0)||','||(SELECT count(*) FROM purchase_request_items WHERE is_deleted=0)||','||(SELECT count(*) FROM purchase_orders WHERE is_deleted=0)" "4,3,4,3"
  check "soft-deleted rows preserved" "SELECT string_agg(x, ',' ORDER BY x) FROM (SELECT pr_number x FROM purchase_requests WHERE is_deleted=1 UNION ALL SELECT po_number FROM purchase_orders WHERE is_deleted=1 UNION ALL SELECT vendor_id FROM vendors WHERE is_deleted=1 UNION ALL SELECT item_id FROM items WHERE is_deleted=1) s" "ITEM-0010,PO-2025-010,PR-2026-003,V-0012"
  check "sum live PO total_amount (16 significant digits, exact)" "SELECT sum(total_amount) FROM purchase_orders WHERE is_deleted=0" "98765432270877.64"
  check "sum live PO subtotal_amount" "SELECT sum(subtotal_amount) FROM purchase_orders WHERE is_deleted=0" "98765432209877.64"
  check "sum live PR item requested_qty" "SELECT sum(requested_qty) FROM purchase_request_items WHERE is_deleted=0" "114.5000"
  check "PR whose pr_date changed collapsed to latest version" "SELECT pr_date||' '||status||' '||notes FROM purchase_requests WHERE pr_number='PR-2026-001'" "2026-01-06 approved v2 date changed"
  check "PO whose po_date changed collapsed to latest version" "SELECT po_date||' '||status FROM purchase_orders WHERE po_number='PO-2026-001'" "2026-01-08 issued"
  check "FINAL kept latest version (PR item approved)" "SELECT approved_qty||' '||status FROM purchase_request_items WHERE legacy_pr_item_id=2" "3.5000 approved"
  check "multi-version user kept latest full_name" "SELECT full_name FROM users WHERE username='md1'" "Budi MD 王"
  check "Chinese text in name_cn" "SELECT name_cn FROM items WHERE item_id='ITEM-0001'" "螺丝刀"
  check "PO primary_pr_id '' became NULL" "SELECT count(*) FROM purchase_orders WHERE po_number IN ('PO-2026-002','PO-2025-010') AND primary_pr_id IS NULL" "2"
  check "PO item pr_item_id '' became NULL" "SELECT pr_item_id IS NULL FROM purchase_order_items WHERE legacy_po_item_id=2" "t"
  check "PO item linked to PR item" "SELECT pr_item_id FROM purchase_order_items WHERE legacy_po_item_id=1" "33333333-3333-4333-8333-000000000002"
  check "NULL legacy ids assigned after max (users,pr,pri,po,poi)" "SELECT (SELECT legacy_user_id FROM users WHERE username='admin1')||','||(SELECT legacy_pr_id FROM purchase_requests WHERE pr_number='PR-2026-002')||','||(SELECT legacy_pr_item_id FROM purchase_request_items WHERE pr_item_id='33333333-3333-4333-8333-000000000004')||','||(SELECT legacy_po_id FROM purchase_orders WHERE po_number='PO-2026-004')||','||(SELECT legacy_po_item_id FROM purchase_order_items WHERE po_item_id='55555555-5555-4555-8555-000000000003')" "6,6,5,8,3"
  check "identity sequences = max(legacy id)" "SELECT '$(seqval users legacy_user_id),$(seqval purchase_requests legacy_pr_id),$(seqval purchase_request_items legacy_pr_item_id),$(seqval purchase_orders legacy_po_id),$(seqval purchase_order_items legacy_po_item_id)'" "6,6,5,8,3"
  check "doc_counters seeded" "SELECT string_agg(doc_type||':'||year||':'||last_no, ' ' ORDER BY doc_type, year) FROM doc_counters" "ITEM:0:10 PO:2025:10 PO:2026:4 PR:2025:7 PR:2026:3 V:0:12"
  check "DateTime64 Jakarta → timestamptz (UTC view)" "SELECT to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS.MS') FROM users WHERE username='requester1' AND is_deleted=0" "2026-01-05 02:15:30.123"
  check "timestamp crossing midnight UTC" "SELECT to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS.MS') FROM purchase_requests WHERE pr_number='PR-2025-007'" "2025-12-30 16:59:59.999"
  check "approval_actions MergeTree duplicate collapsed + NULL approved_qty kept" "SELECT count(*)||','||count(approved_qty) FROM approval_actions" "2,1"
  check "decimal precision kept (exchange_rate, min_order_qty, default_qty)" "SELECT (SELECT exchange_rate FROM purchase_orders WHERE po_number='PO-2026-002')||','||(SELECT min_order_qty FROM items WHERE item_id='LEGACY-ABC')||','||(SELECT default_qty FROM pr_template_items WHERE template_item_id='TI-1')" "1.000000,0.0001,2.5"
  check "nullable date NULL vs value" "SELECT coalesce(onboarding_date::text,'null') FROM vendors ORDER BY vendor_id LIMIT 2" $'2025-03-01\nnull'
  check "charges_amount copied" "SELECT charges_amount FROM purchase_orders WHERE po_number='PO-2026-002'" "50000.00"
  check "users_live_username_uq allows deleted duplicate" "SELECT count(*) FROM users WHERE username='requester1'" "2"
  check "pr_templates latest version" "SELECT display_name FROM pr_templates WHERE template_id='TPL-1'" "面包房 Bakery"
}

echo; echo "== 1. dry run (base fixtures) =="
start_fake "$FIX/base"
migrate dry --dry-run
expect_exit "dry run succeeds" 0 "$RC"
expect_grep "dry run reports missing optional table" "item_requests does not exist" "$LOG/dry.out"
expect_grep "dry run reports PR collapse" "22222222-2222-4222-8222-000000000002 (versions 1000 / 2000)" "$LOG/dry.out"
expect_grep "dry run predicts new legacy id" "legacy_po_id = 8 (expected" "$LOG/dry.out"
check "dry run wrote nothing" "SELECT (SELECT count(*) FROM users)+(SELECT count(*) FROM purchase_requests)+(SELECT count(*) FROM doc_counters)" "0"

echo; echo "== 2. real migration =="
migrate real
expect_exit "migration succeeds" 0 "$RC"
expect_grep "verification passed" "Verification PASSED" "$LOG/real.out"
expect_grep "assigned legacy id reported" "legacy_po_id" "$LOG/real.out"
base_assertions
SUM_A=$(checksum)

echo; echo "== 3. rerun without --truncate must refuse =="
migrate refuse
expect_exit "rerun refused" 1 "$RC"
expect_grep "refusal explains why" "already contain rows (pass --truncate" "$LOG/refuse.out"
check "data unchanged after refusal" "SELECT '$(checksum)'" "$SUM_A"

echo; echo "== 4. --truncate rerun is idempotent =="
migrate trunc --truncate
expect_exit "truncate run succeeds" 0 "$RC"
expect_grep "verification passed" "Verification PASSED" "$LOG/trunc.out"
check "identical content after --truncate rerun" "SELECT '$(checksum)'" "$SUM_A"
base_assertions

echo; echo "== 5. extra fixtures: item_requests present, gl_exports in server.js ReplacingMergeTree shape =="
start_fake "$FIX/base:$FIX/extra"
migrate extra --truncate
expect_exit "extra run succeeds" 0 "$RC"
check "item_requests loaded (latest version, deleted kept)" "SELECT string_agg(status||'/'||is_deleted, ',' ORDER BY request_id) FROM item_requests" "approved/0,rejected/1"
check "gl_exports from Replacing variant" "SELECT count(*)||','||coalesce(max(legacy_log_id)::text,'') FROM gl_exports" "2,17"
expect_grep "warns: deleted gl_exports lose their flag" "has no is_deleted column" "$LOG/extra.out"

echo; echo "== 6. ClickHouse without output_format_json_quote_decimals (dry run) =="
start_fake "$FIX/base" 1
migrate noquote --dry-run --truncate
expect_exit "dry run still works" 0 "$RC"
expect_grep "warns about unquoted decimals" "lacks output_format_json_quote_decimals" "$LOG/noquote.out"

echo; echo "== 7. bad fixtures: pre-flight must abort without writing =="
start_fake "$FIX/base:$FIX/bad"
SUM_B=$(checksum)
migrate bad_dry --dry-run --truncate
expect_exit "bad dry run fails pre-flight" 1 "$RC"
migrate bad --truncate
expect_exit "bad real run fails pre-flight" 1 "$RC"
expect_grep "duplicate pr_number detected" "PR-2026-001: 22222222-2222-4222-8222-000000000002, 22222222-2222-4222-8222-000000000009" "$LOG/bad.out"
expect_grep "orphan PR item detected" "33333333-3333-4333-8333-000000000009 -> pr_id=\"22222222-2222-4222-8222-000000000099\"" "$LOG/bad.out"
expect_grep "bad role detected" "role=\"superuser\"" "$LOG/bad.out"
expect_grep "empty uuid primary key detected" "gl_exports: row with empty/NULL gl_export_id" "$LOG/bad.out"
expect_grep "ambiguous MergeTree duplicate detected" "77777777-7777-4777-8777-000000000001: two different rows" "$LOG/bad.out"
expect_grep "states nothing written" "Nothing was written" "$LOG/bad.out"
check "data unchanged after failed pre-flight (even with --truncate)" "SELECT '$(checksum)'" "$SUM_B"

echo; echo "== 7b. load error mid-transaction (after TRUNCATE) must roll everything back =="
start_fake "$FIX/base:$FIX/rollback"
migrate rollback --truncate
expect_exit "load error exits 3" 3 "$RC"
expect_grep "reports rollback" "transaction ROLLED BACK" "$LOG/rollback.out"
check "data unchanged after rollback (TRUNCATE undone too)" "SELECT '$(checksum)'" "$SUM_B"

echo; echo "== 7c. deleted rows sharing a legacy id (old max()+1 numbering) are repaired =="
start_fake "$FIX/base:$FIX/dupleg"
migrate dupleg --truncate
expect_exit "duplicate legacy ids among deleted rows: migration succeeds" 0 "$RC"
expect_grep "reports the repair" "REPAIR: 4 deleted row(s) shared a legacy id" "$LOG/dupleg.out"
expect_grep "verification passed" "Verification PASSED" "$LOG/dupleg.out"
check "live row keeps its legacy id" "SELECT legacy_pr_item_id FROM purchase_request_items WHERE pr_item_id='33333333-3333-4333-8333-000000000001'" "1"
check "all-deleted group: oldest row keeps the id" "SELECT legacy_pr_item_id FROM purchase_request_items WHERE pr_item_id='33333333-3333-4333-8333-000000000201'" "50"
check "all 10 rows loaded, legacy ids unique" "SELECT count(*)||','||count(DISTINCT legacy_pr_item_id) FROM purchase_request_items" "10,10"
check "repaired rows got ids past the old maximum" "SELECT min(legacy_pr_item_id) > 50 FROM purchase_request_items WHERE pr_item_id IN ('33333333-3333-4333-8333-000000000101','33333333-3333-4333-8333-000000000102','33333333-3333-4333-8333-000000000202','33333333-3333-4333-8333-000000000203')" "t"
check "identity sequence = max(legacy id)" "SELECT '$(seqval purchase_request_items legacy_pr_item_id)' = (SELECT max(legacy_pr_item_id)::text FROM purchase_request_items)" "t"

echo; echo "== 7d. two LIVE rows sharing a legacy id must still stop the migration =="
start_fake "$FIX/base:$FIX/livedup"
SUM_C=$(checksum)
migrate livedup --truncate
expect_exit "live duplicate legacy id fails pre-flight" 1 "$RC"
expect_grep "names the duplicate" "purchase_request_items: duplicate legacy_pr_item_id" "$LOG/livedup.out"
expect_grep "states nothing written" "Nothing was written" "$LOG/livedup.out"
check "data unchanged after failed pre-flight" "SELECT '$(checksum)'" "$SUM_C"

echo; echo "== 8. restore base data for QC =="
start_fake "$FIX/base"
migrate final --truncate
expect_exit "final base load" 0 "$RC"
check "final state matches step 2" "SELECT '$(checksum)'" "$SUM_A"

stop_fake
echo
echo "Outputs in $LOG  (real.out = full migration log)"
echo "RESULT: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
