#!/usr/bin/env bash
# Adversarial test of the minimart mirror against SCHEMA DRIFT, overrides, odd schemas and
# operations (scripts/minimart_sync.sh, scripts/minimart_gen_schema.sh, db/minimart_sync.sql,
# db/minimart_ch_schema.sql, db/minimart_ro_grants.sql), run unmodified through the shims of lib.sh.
#
#   bash test/minimart/ch/run_drift_test.sh                                   # ClickHouse 26.9 (local)
#   MM_CH_BIN=/path/to/clickhouse-24.8.14.39 bash test/minimart/ch/run_drift_test.sh   # production build
#   SECTIONS="A1 B3 C6" bash test/minimart/ch/run_drift_test.sh               # only some sections
#
# Sections
#   A1..A9  schema drift: new column, new table, dropped column, changed type, dropped table, renamed
#           column, sensitive column on a table-level grant, primary key changes, drift-free run
#   B1..B6  overrides file: every directive, names with spaces, syntax errors, CRLF, --grant-args
#   C1..C6  edge schemas: empty database, empty tables, all-sensitive table, weird names, odd types,
#           a 200k-row table (incremental by default, reads only the changed rows)
#   D1..D7  operations: --print on an empty ClickHouse, passwords never logged, quote in a table name,
#           10 cron-like runs with random mutations, repeated --init, threshold change, Postgres down
#
# Uses Postgres database mmc_b (+ mmc_b_empty), role mmc_ro_b (+ mmc_ro_b_empty) and a scratch ClickHouse on
# ports 19302 / 18302 ONLY. Never touches a Postgres role or database called minimart*.
# Runs on bash 3.2 (no associative arrays, mapfile or ${x,,}). Exit code 1 on any FAIL.
source "$(dirname "$0")/lib.sh"
mm_env b 19302 18302

# ---------------------------------------------------------------- cleanup (also the extra database)
t2_cleanup() {
  PGDB=mmc_b; RO_ROLE=mmc_ro_b
  mm_cleanup
  if [[ "${MM_TEST_KEEP:-0}" != 1 ]]; then
    PGSU "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = 'mmc_b_empty'" >/dev/null 2>&1
    dropdb --if-exists mmc_b_empty 2>/dev/null
    PGSU "DROP ROLE IF EXISTS mmc_ro_b_empty" >/dev/null 2>&1
  fi
}
trap t2_cleanup EXIT

# ---------------------------------------------------------------- helpers
OVR=$WORK/overrides.conf
hdr() { echo; echo "== $1 =="; }
SMALL=100
set_env() { MM_ENV="MINIMART_SMALL_ROWS=${1:-$SMALL} MINIMART_OVERRIDES=$OVR"; }
set_env
export TZ_PG_OPTS="-c timezone=UTC -c datestyle=ISO,YMD"

chv()  { chq "$1" | tr '\t' ' ' | sed -e 's/[[:space:]]*$//'; }                       # ClickHouse scalar/TSV, errors included
pgv()  { PGS "$1" 2>&1; }
pgu()  { PGOPTIONS="$TZ_PG_OPTS" PGS "$1" 2>&1; }                        # same session settings as the ro role
pgx()  { PGS "$1" >/dev/null || bad "Postgres statement failed: $(echo "$1" | head -c 150 | tr '\n' ' ')"; }   # mutation that must work
sqe()  { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e "s/'/\\\\'/g"; }                 # SQL string literal body
bq()   { printf '`%s`' "$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/`/\\`/g')"; }   # back-quoted identifier
quiet_setup() { local p=$PASS; mm_pg_setup "$1" >/dev/null; PASS=$p; }  # recreate Postgres db + role + grants
ch_drop() { chq "DROP DATABASE IF EXISTS minimart SYNC" >/dev/null; }
logreset() { : > "$LOG"; }
out()  { cat "$WORK/out/last.txt"; }
out_has()  { grep -cE -- "$1" "$WORK/out/last.txt" 2>/dev/null; }          # number of matching lines of the last run
log_has()  { grep -cE -- "$1" "$LOG" 2>/dev/null; }
check_out()   { # check_out "desc" regex : last run's output contains regex
  if [[ "$(out_has "$2")" -ge 1 ]]; then ok "$1"; else bad "$1 — /$2/ not in output: $(out | head -c 600 | LC_ALL=C tr '\n' '~' | LC_ALL=C tr -c '[:print:]~' '?')"; fi; }
check_noout() { if [[ "$(out_has "$2")" -eq 0 ]]; then ok "$1"; else bad "$1 — /$2/ found in output: $(grep -E -- "$2" "$WORK/out/last.txt" | head -3 | tr '\n' '~')"; fi; }
check_log()   { if [[ "$(log_has "$2")" -ge 1 ]]; then ok "$1"; else bad "$1 — /$2/ not in log: $(tail -n 6 "$LOG" | cut -c1-220 | tr '\n' '~')"; fi; }
check_nolog() { if [[ "$(log_has "$2")" -eq 0 ]]; then ok "$1"; else bad "$1 — /$2/ found in log: $(grep -E -- "$2" "$LOG" | head -3 | cut -c1-220 | tr '\n' '~')"; fi; }

has_tbl()  { chv "SELECT count() FROM system.tables WHERE database = 'minimart' AND name = '$(sqe "$1")'"; }
has_col()  { chv "SELECT count() FROM system.columns WHERE database = 'minimart' AND table = '$(sqe "$1")' AND name = '$(sqe "$2")'"; }
col_type() { chv "SELECT type FROM system.columns WHERE database = 'minimart' AND table = '$(sqe "$1")' AND name = '$(sqe "$2")'"; }
engine()   { chv "SELECT engine_full FROM system.tables WHERE database = 'minimart' AND name = '$1'" | sed 's/ ORDER BY.*//'; }
cnt()      { chv "SELECT uniqExact(tuple(*)) FROM minimart.$(bq "$1")"; }   # distinct rows (a re-sent row may exist twice)
nrows()    { chv "SELECT count() FROM minimart.$(bq "$1")"; }
isrep()    { [[ "$(chv "SELECT engine FROM system.tables WHERE database = 'minimart' AND name = '$(sqe "$1")'")" == Replacing* ]]; }
fin()      { isrep "$1" && echo FINAL; }                                           # FINAL only on a ReplacingMergeTree
nfinal()   { chv "SELECT count() FROM minimart.$(bq "$1") $(fin "$1")"; }
wm()       { chv "SELECT toString(max(synced_through)) FROM minimart._sync_state WHERE table_name = '$1'"; }
lastmode() { chv "SELECT mode FROM minimart._sync_state WHERE table_name = '$1' ORDER BY run_at DESC LIMIT 1"; }
strategy() { chv "SELECT strategy FROM minimart._plan WHERE plan_id = (SELECT argMax(plan_id, planned_at) FROM minimart._plan_current) AND table_name = '$1'"; }
phash()    { chv "SELECT plan_hash FROM minimart._plan WHERE plan_id = (SELECT argMax(plan_id, planned_at) FROM minimart._plan_current) AND table_name = '$1'"; }
plan_id()  { chv "SELECT argMax(plan_id, planned_at) FROM minimart._plan_current"; }
plan_tables() { chv "SELECT arrayStringConcat(arraySort(groupArray(table_name)), ',') FROM minimart._plan WHERE plan_id = (SELECT argMax(plan_id, planned_at) FROM minimart._plan_current)"; }
leftovers() { chv "SELECT count() FROM system.tables WHERE database = 'minimart' AND (startsWith(name, '_new_') OR startsWith(name, '_src_'))"; }
can_col()  { PGS "SELECT has_column_privilege('$RO_ROLE', '\"$1\"'::regclass, '$2', 'SELECT')" | head -c1; }   # t / f
can_tbl()  { PGS "SELECT has_table_privilege('$RO_ROLE', '\"$1\"', 'SELECT')" | head -c1; }

# gt A B : A > B as strings (watermarks have a fixed format)
gt() { [[ "$1" > "$2" ]]; }

# eq_data "desc" table key pg_row_expr ch_row_expr   (FINAL is added automatically on a ReplacingMergeTree)
#   md5 over all rows of  <key>|<row text>  ordered by key, computed by Postgres and by ClickHouse
eq_data() {
  local d=$1 t=$2 k=$3 pe=$4 ce=$5 p c
  p=$(pgu "SELECT md5(coalesce(string_agg(r, E'\\n' ORDER BY k COLLATE \"C\"), '')) FROM (SELECT ($k)::text AS k, ($pe) AS r FROM \"$t\") q")
  c=$(chv "SELECT lower(hex(MD5(arrayStringConcat(arrayMap(x -> x.2, arraySort(x -> x.1, groupArray((toString($k), $ce)))), '\\n')))) FROM minimart.$(bq "$t") $(fin "$t")")
  check "$d" "$p" "$c"
}

# fresh [yes|no] [extra Postgres SQL]: new Postgres db (stand-in schema [+ seed]) + new ClickHouse database,
# then --init, --full, --verify must all exit 0 (one PASS/FAIL for the lot); log emptied afterwards.
fresh() {
  rm -f "$OVR"; set_env
  quiet_setup "${1:-yes}"
  if [[ -n "${2:-}" ]]; then pgx "$2"; mm_grants; fi
  ch_drop
  local a b c
  sync_run --init;   a=$RC
  sync_run --full;   b=$RC
  sync_run --verify; c=$RC
  check "fresh mirror: --init, --full, --verify exit codes" "0 0 0" "$a $b $c"
  [[ "$a$b$c" == 000 ]] || { echo "      init/full/verify output:"; out | head -20 | sed 's/^/      | /'; }
  logreset
}

# ================================================================= A. SCHEMA DRIFT
sec_A1() {
  hdr "A1 add a column (nullable; NOT NULL with default) to an incremental and to a snapshot table"
  fresh
  check "strategies: products incremental_updated, categories snapshot, orders incremental_updated" \
        "incremental_updated snapshot incremental_updated" "$(strategy products) $(strategy categories) $(strategy orders)"
  local wm_o0 wm_c0 hp0 hc0 ho0
  hp0=$(phash products); hc0=$(phash categories); ho0=$(phash orders)
  pgx "ALTER TABLE products ADD COLUMN extra_n integer, ADD COLUMN extra_nn integer NOT NULL DEFAULT 7"
  pgx "ALTER TABLE categories ADD COLUMN extra_n integer, ADD COLUMN extra_nn integer NOT NULL DEFAULT 3"
  pgx "UPDATE products SET extra_n = product_id * 2 WHERE product_id <= 20"     # the trigger bumps updated_at
  pgx "UPDATE products SET name = name || '!' WHERE product_id IN (5, 6)"
  pgx "UPDATE orders SET currency = 'EUR' WHERE invoice_no = (SELECT min(invoice_no) FROM orders)"
  wm_o0=$(wm orders); wm_c0=$(wm categories)
  logreset; sync_run
  check "sync with drift exits 0 (new columns do not stop anything)" 0 "$RC"
  check_log "DRIFT [new_column] products.extra_n logged"   'DRIFT \[new_column\] products\.extra_n:'
  check_log "DRIFT [new_column] products.extra_nn logged"  'DRIFT \[new_column\] products\.extra_nn:'
  check_log "DRIFT [new_column] categories.extra_n logged" 'DRIFT \[new_column\] categories\.extra_n:'
  check_nolog "no table is skipped for a new column" 'SKIPPED|PARTIAL|FAILED'
  check "new column is NOT in the mirror (products.extra_n, extra_nn; categories.extra_n)" "0 0 0" \
        "$(has_col products extra_n) $(has_col products extra_nn) $(has_col categories extra_n)"
  check "incremental sync still carries a change of the old column set (products 5 and 6 renamed)" \
        "$(pgv "SELECT string_agg(name, '|' ORDER BY product_id) FROM products WHERE product_id IN (5, 6)")" \
        "$(chv "SELECT arrayStringConcat(arraySort(x -> x.1, groupArray((product_id, name))).2, '|') FROM minimart.products FINAL WHERE product_id IN (5, 6)")"
  check "orders still incremental: its change arrived" "EUR" \
        "$(chv "SELECT currency FROM minimart.orders FINAL WHERE invoice_no = (SELECT min(invoice_no) FROM minimart.orders FINAL)")"
  gt "$(wm orders)" "$wm_o0" && ok "orders watermark advanced" || bad "orders watermark did not advance"
  gt "$(wm categories)" "$wm_c0" && ok "categories (snapshot) watermark advanced" || bad "categories watermark did not advance"
  sync_run --verify
  check "--verify exits 1 on drift" 1 "$RC"
  check_out "--verify has a SCHEMA DRIFT section" 'SCHEMA DRIFT'
  check_out "--verify lists new_column products.extra_n" 'new_column +products\.extra_n'
  check_out "--verify lists new_column categories.extra_nn" 'new_column +categories\.extra_nn'

  local wm_ord_pre; wm_ord_pre=$(wm orders)
  sync_run --init
  check "--init (adopt) exits 0" 0 "$RC"
  check "mirror structure is replaced by the next load, not by --init (extra_n still absent)" 0 "$(has_col products extra_n)"
  check "plan hash of products and categories changed, orders unchanged" "changed changed same" \
        "$([[ "$(phash products)" != "$hp0" ]] && echo changed) $([[ "$(phash categories)" != "$hc0" ]] && echo changed) $([[ "$(phash orders)" == "$ho0" ]] && echo same)"
  logreset; sync_run
  check "sync after --init exits 0" 0 "$RC"
  check_log "products is loaded in full (plan hash changed)" 'table products \(incremental_updated, full: no successful run'
  check_log "categories is loaded in full (plan hash changed)" 'table categories \(snapshot, full: no successful run'
  check_nolog "orders keeps its incremental watermark (no full reload)" 'table orders '
  check_nolog "customers keeps its incremental watermark (no full reload)" 'table customers '
  check "orders last mode is incremental, products last mode full" "incremental full" "$(lastmode orders) $(lastmode products)"
  gt "$(wm orders)" "$wm_ord_pre" && ok "orders watermark moved on (not reset)" || bad "orders watermark did not move on"
  check "new columns now in the mirror (products.extra_n, extra_nn, categories.extra_n, extra_nn)" "1 1 1 1" \
        "$(has_col products extra_n) $(has_col products extra_nn) $(has_col categories extra_n) $(has_col categories extra_nn)"
  check "products.extra_nn is not Nullable, extra_n is Nullable" "Int32 Nullable(Int32)" "$(col_type products extra_nn) $(col_type products extra_n)"
  check "products.extra_nn = 7 everywhere, extra_n correct (20 set)" "$(pgv "SELECT count(*) FILTER (WHERE extra_nn = 7), count(*) FILTER (WHERE extra_n = product_id * 2) FROM products" | tr '|' ' ')" \
        "$(chv "SELECT countIf(extra_nn = 7), countIf(extra_n = product_id * 2) FROM minimart.products FINAL")"
  check "categories.extra_nn = 3 everywhere" "5" "$(chv "SELECT countIf(extra_nn = 3) FROM minimart.categories")"
  sync_run --verify
  check "--verify exits 0 after adoption" 0 "$RC"
  check_noout "no drift section after adoption" 'SCHEMA DRIFT'
}

sec_A2() {
  hdr "A2 new tables: not readable -> reported and not mirrored; after the grants -> run --init; adopted by --init"
  fresh
  pgx "CREATE TABLE gadgets (id integer PRIMARY KEY, name text); INSERT INTO gadgets SELECT g, 'g' || g FROM generate_series(1, 30) g"
  pgx "CREATE TABLE secrets (id integer PRIMARY KEY, api_key text NOT NULL, note text); INSERT INTO secrets SELECT g, 'KEY-' || g, 'note ' || g FROM generate_series(1, 12) g"
  logreset; sync_run
  check "sync exits 0 with new tables not yet readable" 0 "$RC"
  check_log "DRIFT [new_table] gadgets: not readable"  'DRIFT \[new_table\] gadgets: not readable'
  check_log "DRIFT [new_table] secrets: not readable"  'DRIFT \[new_table\] secrets: not readable'
  check "new tables are NOT mirrored" "0 0" "$(has_tbl gadgets) $(has_tbl secrets)"
  sync_run --verify
  check "--verify exits 1" 1 "$RC"
  check_out "--verify lists new_table gadgets" 'new_table +gadgets'
  # now the grants are re-run
  mm_grants
  check "grants file exits 0 (re-run)" "0" "$(grep -c 'ERROR' "$WORK/out/grants.txt")"
  check "role can read gadgets, and secrets only without api_key" "t t f" \
        "$(can_tbl gadgets) $(can_col secrets note) $(can_col secrets api_key)"
  logreset; sync_run
  check "sync after the grants exits 0" 0 "$RC"
  check_log "DRIFT [new_table] gadgets: run --init (readable now)" 'DRIFT \[new_table\] gadgets: not in the mirror yet'
  check "still not mirrored before --init" "0 0" "$(has_tbl gadgets) $(has_tbl secrets)"
  sync_run --verify
  check "--verify exits 1" 1 "$RC"
  check_out "--verify lists new_table gadgets as not in the mirror yet" 'new_table +gadgets +not in the mirror yet'
  sync_run --init
  check "--init exits 0" 0 "$RC"
  check "plan now has gadgets and secrets" "yes" "$(plan_tables | grep -q 'gadgets' && plan_tables | grep -q 'secrets' && echo yes)"
  logreset; sync_run
  check "next run exits 0" 0 "$RC"
  check_log "gadgets loaded in full by the next run" 'table gadgets \(snapshot, full: no successful run'
  check "gadgets mirrored with 30 rows, secrets with 12" "30 12" "$(nrows gadgets) $(nrows secrets)"
  check "secrets mirrored WITHOUT api_key, with id and note" "0 1 1" "$(has_col secrets api_key) $(has_col secrets id) $(has_col secrets note)"
  check "secrets.note values correct" "$(pgv "SELECT string_agg(note, '|' ORDER BY id) FROM secrets")" \
        "$(chv "SELECT arrayStringConcat(arrayMap(x -> x.2, arraySort(x -> x.1, groupArray((id, note)))), '|') FROM minimart.secrets")"
  check "no KEY- string anywhere in the mirror of secrets" "0" "$(chv "SELECT count() FROM minimart.secrets WHERE note LIKE 'KEY-%'")"
  sync_run --verify
  check "--verify exits 0" 0 "$RC"
  check_out "--verify lists secrets.api_key as a sensitive column not mirrored" 'secrets\.api_key +\(not readable'
}

sec_A2b() {
  hdr "A2b new tables: --init while they are still unreadable, THEN the grants (the other order)"
  fresh
  pgx "CREATE TABLE gadgets (id integer PRIMARY KEY, name text); INSERT INTO gadgets SELECT g, 'g' || g FROM generate_series(1, 30) g"
  sync_run --init
  check "--init while the new table is unreadable exits 0" 0 "$RC"
  check "unreadable table is still not mirrored after --init" 0 "$(has_tbl gadgets)"
  logreset; sync_run
  check "sync exits 0" 0 "$RC"
  check_nolog "no FAILED / SKIPPED" 'FAILED|SKIPPED'
  mm_grants
  logreset; sync_run
  check "sync after the grants exits 0 (the unplanned table cannot be skipped)" 0 "$RC"
  check_log "the table is reported with a hint to run --init" 'DRIFT \[[a-z_]+\] gadgets.*--init'
  sync_run --verify
  check "--verify exits 1 until --init adopts the now-readable table" 1 "$RC"
  sync_run --init;   check "--init exits 0" 0 "$RC"
  logreset; sync_run; check "sync exits 0" 0 "$RC"
  check "gadgets mirrored with 30 rows" 30 "$(nrows gadgets)"
  check_nolog "no DRIFT lines left" 'DRIFT'
  sync_run --verify; check "--verify exits 0" 0 "$RC"
}

sec_A3() {
  hdr "A3 drop a column: that table is skipped (PARTIAL, exit 1); every other table is still synced"
  fresh
  local p_n p_wm c_wm o_wm
  pgx "ALTER TABLE products DROP COLUMN rating"
  pgx "INSERT INTO categories VALUES (6, 'Frozen', 60)"
  pgx "INSERT INTO products (sku, name, category_id, price) VALUES ('NEW-1', 'new product', 1, 1.5)"
  pgx "UPDATE orders SET currency = 'GBP' WHERE invoice_no = (SELECT max(invoice_no) FROM orders)"
  p_n=$(nrows products); p_wm=$(wm products); c_wm=$(wm categories); o_wm=$(wm orders)
  logreset; sync_run
  check "sync exits 1 (PARTIAL)" 1 "$RC"
  check_log "DRIFT [dropped_column] products.rating" 'DRIFT \[dropped_column\] products\.rating:'
  check_log "SKIPPED products logged" 'SKIPPED products: schema drift'
  check_log "PARTIAL line names products" 'PARTIAL: .*products\(drift\)'
  check_nolog "no other table is skipped or failed" 'SKIPPED (?!products)|FAILED'
  check "skipped table untouched: rows, watermark, new product absent" "$p_n $p_wm 0" \
        "$(nrows products) $(wm products) $(chv "SELECT count() FROM minimart.products WHERE sku = 'NEW-1'")"
  check "skipped table still has its old column (mirror untouched)" 1 "$(has_col products rating)"
  check "other snapshot table synced: categories 6 rows" 6 "$(nrows categories)"
  check "other incremental table synced: orders change arrived" "GBP" "$(chv "SELECT currency FROM minimart.orders FINAL WHERE invoice_no = (SELECT max(invoice_no) FROM minimart.orders FINAL)")"
  gt "$(wm categories)" "$c_wm" && ok "categories watermark advanced" || bad "categories watermark did not advance"
  gt "$(wm orders)" "$o_wm" && ok "orders watermark advanced" || bad "orders watermark did not advance"
  sync_run --verify
  check "--verify exits 1" 1 "$RC"
  check_out "--verify lists dropped_column products.rating" 'dropped_column +products\.rating'
  check_out "--verify marks products skipped" 'products +\(skipped: schema drift\)'
  sync_run --init
  check "--init exits 0" 0 "$RC"
  logreset; sync_run
  check "sync after --init exits 0" 0 "$RC"
  check "products adopted: 1001 rows, rating column gone" "1001 0" "$(nfinal products) $(has_col products rating)"
  sync_run --verify
  check "--verify exits 0" 0 "$RC"
}

sec_A4() {
  hdr "A4 change a column type: changed_column, table skipped until --init"
  fresh
  pgx "ALTER TABLE categories ALTER COLUMN sort_order TYPE bigint"                     # integer -> bigint (snapshot)
  pgx "ALTER TABLE settings ALTER COLUMN value TYPE varchar(50)"                       # text -> varchar(10..50)
  pgx "ALTER TABLE products ALTER COLUMN price TYPE numeric(14,2)"                         # numeric(12,2) -> (14,2), incremental_updated
  pgx "ALTER TABLE stock_movements ALTER COLUMN delta TYPE bigint"                         # integer -> bigint on an incremental_created table
  pgx "ALTER TABLE products ALTER COLUMN category_id TYPE integer"                     # smallint -> integer, incremental_updated
  pgx "ALTER TABLE event_log ALTER COLUMN kind DROP NOT NULL"                          # nullability change
  pgx "UPDATE orders SET currency = 'JPY' WHERE invoice_no = (SELECT max(invoice_no) FROM orders)"
  local wm_s wm_i; wm_s=$(wm settings); wm_i=$(wm stock_movements)
  logreset; sync_run
  check "sync exits 1 (PARTIAL)" 1 "$RC"
  local t
  for t in categories.sort_order settings.value stock_movements.delta products.price products.category_id event_log.kind; do
    check_log "DRIFT [changed_column] $t" "DRIFT \\[changed_column\\] ${t//./\\.}:"
  done
  for t in categories settings stock_movements products event_log; do check_log "SKIPPED $t" "SKIPPED $t: schema drift"; done
  check "skipped tables untouched (watermarks)" "$wm_s $wm_i" "$(wm settings) $(wm stock_movements)"
  check "unchanged tables still synced (orders change arrived)" "JPY" "$(chv "SELECT currency FROM minimart.orders FINAL WHERE invoice_no = (SELECT max(invoice_no) FROM minimart.orders FINAL)")"
  check_nolog "nothing FAILED (skipping is not failing)" 'FAILED'
  sync_run --verify
  check "--verify exits 1, lists changed_column" 1 "$RC"
  check_out "--verify lists changed_column products.price" 'changed_column +products\.price'
  sync_run --init; check "--init exits 0" 0 "$RC"
  logreset; sync_run; check "sync exits 0 after --init" 0 "$RC"
  check "new types in the mirror" "Int64 Decimal(14, 2) Nullable(Int32) Int64" "$(col_type categories sort_order) $(col_type products price) $(col_type products category_id) $(col_type stock_movements delta)"
  check "settings.value still correct (6 rows)" "$(pgv "SELECT md5(string_agg(coalesce(key || value, '~'), ',' ORDER BY key)) FROM settings")" \
        "$(chv "SELECT lower(hex(MD5(arrayStringConcat(arrayMap(x -> x.2, arraySort(x -> x.1, groupArray((key, ifNull(concat(key, value), '~'))))), ','))))  FROM minimart.settings")"
  sync_run --verify; check "--verify exits 0" 0 "$RC"
}

sec_A5() {
  hdr "A5 drop a table in Postgres"
  fresh
  pgx "DROP TABLE settings"
  pgx "UPDATE categories SET name = name || '*' WHERE category_id = 1"
  local n0; n0=$(nrows settings)
  logreset; sync_run
  check_log "DRIFT [dropped_table] settings" 'DRIFT \[dropped_table\] settings:'
  check "the sync as a whole does not fail on it: every other table synced" "Snacks*" "$(chv "SELECT name FROM minimart.categories WHERE category_id = 1")"
  check_nolog "no table FAILED" 'FAILED'
  check "mirror table of the dropped table is kept with its rows" "$n0" "$(nrows settings)"
  echo "      (exit code of a run with a dropped table: $RC; the dropped table is reported as SKIPPED)"
  check "run exit code is 0 or 1 (documented: PARTIAL names the skipped table)" "ok" "$([[ $RC -le 1 ]] && echo ok)"
  sync_run --verify
  check "--verify exits 1" 1 "$RC"
  check_out "--verify lists dropped_table settings" 'dropped_table +settings'
  sync_run --init
  check "--init exits 0" 0 "$RC"
  logreset; sync_run
  check "sync exits 0 after --init" 0 "$RC"
  check "plan no longer has settings" "no" "$(plan_tables | grep -q settings && echo yes || echo no)"
  check "mirror table kept after --init (orphan)" 1 "$(has_tbl settings)"
  sync_run --verify
  check_out "--verify lists the orphan mirror table" 'mirror tables that are not in the plan'
  check_out "orphan named settings" '^  settings$'
  check "--verify exit code with only an orphan: 0 (informational)" 0 "$RC"
}

sec_A6() {
  hdr "A6 rename a column (= drop + add), rename a table"
  fresh
  pgx "ALTER TABLE products RENAME COLUMN rating TO rating_score"
  pgx "ALTER TABLE empty_table RENAME TO empty_table2"
  pgx "UPDATE categories SET name = 'Snax' WHERE category_id = 1"
  logreset; sync_run
  check "sync exits 1 (products skipped, empty_table dropped)" 1 "$RC"
  check_log "dropped_column products.rating" 'DRIFT \[dropped_column\] products\.rating:'
  check_log "new_column products.rating_score" 'DRIFT \[new_column\] products\.rating_score:'
  check_log "dropped_table empty_table" 'DRIFT \[dropped_table\] empty_table:'
  check_log "new_table empty_table2 (keeps its grants, so readable)" 'DRIFT \[new_table\] empty_table2: not in the mirror yet'
  check "other tables synced" "Snax" "$(chv "SELECT name FROM minimart.categories WHERE category_id = 1")"
  sync_run --verify; check "--verify exits 1" 1 "$RC"
  sync_run --init;   check "--init exits 0" 0 "$RC"
  logreset; sync_run; check "sync exits 0" 0 "$RC"
  check "products has rating_score and not rating; empty_table2 mirrored" "1 0 1" "$(has_col products rating_score) $(has_col products rating) $(has_tbl empty_table2)"
  check "rating_score values equal to Postgres" "$(pgv "SELECT round(sum(rating_score::float8)::numeric, 3)::float8 FROM products")" "$(chv "SELECT round(sum(toFloat64(rating_score)), 3) FROM minimart.products FINAL")"
  sync_run --verify; check "--verify exits 0 (the old empty_table mirror is only an orphan)" 0 "$RC"
}

sec_A7() {
  hdr "A7 new column with a sensitive name on a table that has TABLE-level SELECT"
  fresh
  pgx "ALTER TABLE products ADD COLUMN secret_note text"
  pgx "UPDATE products SET secret_note = 'TOPSECRET-' || product_id WHERE product_id <= 10"
  check "precondition: the role can read the new column through the table-level grant" "t" "$(can_col products secret_note)"
  logreset; sync_run
  check "sync exits 0" 0 "$RC"
  check_log "DRIFT [sensitive_readable] products.secret_note" 'DRIFT \[sensitive_readable\] products\.secret_note:'
  check "never mirrored" 0 "$(has_col products secret_note)"
  check "no TOPSECRET text anywhere in the products mirror" 0 "$(chv "SELECT count() FROM minimart.products WHERE position(toString(tuple(*)), 'TOPSECRET') > 0")"
  sync_run --verify
  check "--verify exits 1" 1 "$RC"
  check_out "--verify lists sensitive_readable" 'sensitive_readable +products\.secret_note'
  # the documented fix: re-run the grants, then adopt
  mm_grants
  check "after the grants the role can no longer read it" "f" "$(can_col products secret_note)"
  check "...but still reads the other products columns" "t" "$(can_col products name)"
  logreset; sync_run
  check "sync after the grants exits 0 (sig readable 1 -> 0 on secret_note is not in the mirrored set)" 0 "$RC"
  echo "      (drift lines after the grants, before --init:)"; grep 'DRIFT' "$LOG" | cut -c1-200 | sed 's/^/      | /'
  sync_run --init;   check "--init exits 0" 0 "$RC"
  logreset; sync_run; check "sync exits 0" 0 "$RC"
  check_nolog "no DRIFT line after grants + --init" 'DRIFT'
  sync_run --verify
  check "--verify exits 0 after grants + --init" 0 "$RC"
  check "still never mirrored" 0 "$(has_col products secret_note)"
}

sec_A7b() {
  hdr "A7b order matters? --init BEFORE the grants, then the grants (the log line says: re-run the grants)"
  fresh
  pgx "ALTER TABLE products ADD COLUMN secret_note text"
  sync_run --init
  check "--init exits 0 (the readable sensitive column is reported, not mirrored)" 0 "$RC"
  check_log "init reports sensitive_readable" 'DRIFT \[sensitive_readable\] products\.secret_note'
  logreset; sync_run
  check "sync exits 0 with a readable sensitive column" 0 "$RC"
  check "secret_note not mirrored" 0 "$(has_col products secret_note)"
  sync_run --verify; check "--verify exits 1 until the grants are re-run" 1 "$RC"
  check_out "--verify says READABLE" 'READABLE by minimart_ro'
  mm_grants
  logreset; sync_run
  check "after the grants (no --init): sync exits 0 and does not skip products (the log message told the user only to re-run the grants)" 0 "$RC"
  check_nolog "products not skipped after the grants" 'SKIPPED'
  sync_run --verify
  check "after the grants (no --init): --verify exits 0 (nothing else to adopt)" 0 "$RC"
  [[ $RC -eq 0 ]] || out | grep -E 'DRIFT|changed_column|new_column' | head -5 | sed 's/^/      | /'
}

sec_A8() {
  hdr "A8 add / drop a primary key changes the strategy on --init (plan hash differs => full reload)"
  fresh yes "CREATE TABLE ledger (id integer NOT NULL, v integer, updated_at timestamptz NOT NULL DEFAULT now());
             INSERT INTO ledger SELECT g, g, now() - interval '1 day' FROM generate_series(1, 300) g; ANALYZE ledger"
  check "ledger without primary key is a snapshot" "snapshot" "$(strategy ledger)"
  local h0 h1 h2
  h0=$(phash ledger)
  pgx "ALTER TABLE ledger ADD PRIMARY KEY (id)"
  pgx "UPDATE ledger SET v = -v, updated_at = now() WHERE id <= 5"
  logreset; sync_run
  check "sync exits 1 (ledger skipped: key changed)" 1 "$RC"
  check_log "DRIFT [changed_column] ledger.id" 'DRIFT \[changed_column\] ledger\.id:'
  check_log "SKIPPED ledger" 'SKIPPED ledger: schema drift'
  sync_run --init; check "--init exits 0" 0 "$RC"
  check "strategy is now incremental_updated" "incremental_updated" "$(strategy ledger)"
  h1=$(phash ledger)
  [[ "$h0" != "$h1" ]] && ok "plan hash changed after adding the primary key" || bad "plan hash did not change"
  logreset; sync_run
  check "sync exits 0" 0 "$RC"
  check_log "ledger reloaded in full" 'table ledger \(incremental_updated, full: no successful run'
  check_nolog "products NOT reloaded (keeps its incremental watermark)" 'table products '
  check "ledger content correct (300 rows, sum(v))" "$(pgv "SELECT count(*) || ' ' || sum(v) FROM ledger")" "$(chv "SELECT concat(toString(count()), ' ', toString(sum(v))) FROM minimart.ledger FINAL")"
  check "ledger engine ReplacingMergeTree" "ReplacingMergeTree(updated_at)" "$(engine ledger)"
  pgx "ALTER TABLE ledger DROP CONSTRAINT ledger_pkey"
  logreset; sync_run
  check "dropping the key: sync exits 1 (skipped)" 1 "$RC"
  sync_run --init; check "--init exits 0" 0 "$RC"
  h2=$(phash ledger)
  check "strategy back to snapshot" "snapshot" "$(strategy ledger)"
  [[ "$h2" != "$h1" ]] && ok "plan hash differs again" || bad "plan hash did not change when the key was dropped"
  logreset; sync_run; check "sync exits 0" 0 "$RC"
  check "ledger engine MergeTree, 300 rows" "MergeTree 300" "$(engine ledger) $(nrows ledger)"
  [[ "$h2" == "$h0" ]] && echo "      (note: the plan hash after dropping the key equals the original snapshot hash: $h0)"
  # and back: the same plan hash as the incremental era (h1) comes back, its old watermark is still in _sync_state
  pgx "ALTER TABLE ledger ADD PRIMARY KEY (id)"
  pgx "UPDATE ledger SET v = v + 1000, updated_at = now() WHERE id <= 3"
  sync_run; check "re-adding the key: sync exits 1 (skipped)" 1 "$RC"
  sync_run --init; check "--init exits 0" 0 "$RC"
  check "strategy incremental_updated again, same plan hash as before (h1)" "incremental_updated $h1" "$(strategy ledger) $(phash ledger)"
  logreset; sync_run; check "sync exits 0" 0 "$RC"
  check "BUG? incremental table must be a ReplacingMergeTree again (the swap to it only happens in a full load, which a recurring plan hash skips)" \
        "ReplacingMergeTree(updated_at)" "$(engine ledger)"
  pgx "UPDATE ledger SET v = v + 5, updated_at = now() WHERE id <= 3"
  sync_run; check "incremental run exits 0" 0 "$RC"
  check "no duplicate physical rows after the update (ledger rows == 300 without FINAL)" 300 "$(nrows ledger)"
  sync_run --verify; check "--verify exits 0" 0 "$RC"
}

sec_A9() {
  hdr "A9 a drift-free run produces no DRIFT lines"
  fresh
  pgx "UPDATE products SET name = name || '.' WHERE product_id < 4"
  logreset; sync_run
  check "incremental run exits 0" 0 "$RC"
  check_nolog "no DRIFT line in the log" 'DRIFT'
  sync_run --full; check "--full exits 0" 0 "$RC"
  check_nolog "no DRIFT line after --full" 'DRIFT'
  sync_run --init; check "--init exits 0" 0 "$RC"
  check_nolog "no DRIFT line after --init" 'DRIFT'
  sync_run --verify; check "--verify exits 0" 0 "$RC"
  check_noout "no SCHEMA DRIFT section" 'SCHEMA DRIFT'
}

sec_A10() {
  hdr "A10 drift that is undone (column added, adopted, dropped again) leaves no stale structure behind"
  fresh
  pgx "ALTER TABLE products ADD COLUMN extra_n integer"
  sync_run --init; sync_run
  check "extra_n adopted" 1 "$(has_col products extra_n)"
  pgx "ALTER TABLE products DROP COLUMN extra_n"
  sync_run; check "sync exits 1 (dropped_column)" 1 "$RC"
  sync_run --init; check "--init exits 0" 0 "$RC"
  logreset; sync_run; check "sync exits 0" 0 "$RC"
  check "BUG? the dropped column is gone from the mirror table (the plan hash is the original one again, so no full reload happens)" 0 "$(has_col products extra_n)"
  sync_run --verify; check "--verify exits 0" 0 "$RC"
}

# ================================================================= B. OVERRIDES
# plan_reason table / col_reason table col (reason of an excluded column in _plan_cols)
plan_reason() { chv "SELECT reason FROM minimart._plan WHERE plan_id = (SELECT argMax(plan_id, planned_at) FROM minimart._plan_current) AND table_name = '$(sqe "$1")'"; }
chg_col()     { chv "SELECT change_col FROM minimart._plan WHERE plan_id = (SELECT argMax(plan_id, planned_at) FROM minimart._plan_current) AND table_name = '$(sqe "$1")'"; }
col_reason()  { chv "SELECT reason FROM minimart._plan_cols WHERE plan_id = (SELECT argMax(plan_id, planned_at) FROM minimart._plan_current) AND table_name = '$(sqe "$1")' AND col = '$(sqe "$2")'"; }
# ovr "line" ...: write the overrides file (one line per argument)
ovr() { : > "$OVR"; local l; for l in "$@"; do printf '%s\n' "$l" >> "$OVR"; done; }
# rebuild: --init + --full + --verify with the current overrides; one check of the three exit codes
rebuild() { # rebuild "description"
  local a b c
  sync_run --init;   a=$RC
  sync_run --full;   b=$RC
  sync_run --verify; c=$RC
  check "$1: --init, --full, --verify exit codes" "0 0 0" "$a $b $c"
  [[ "$a$b$c" == 000 ]] || { echo "      last output:"; out | head -12 | sed 's/^/      | /'; }
}

sec_B1() {
  hdr "B1 overrides: exclude, snapshot, incremental"
  fresh
  ovr "# comment" "" "exclude product_prices" "exclude \"Legacy Notes\""
  sync_run --init; check "--init with exclude exits 0" 0 "$RC"
  check "excluded tables are not in the plan" "no no" "$(plan_tables | grep -q product_prices && echo yes || echo no) $(plan_tables | grep -q 'Legacy Notes' && echo yes || echo no)"
  check "their old mirror tables are kept (orphans)" "1 1" "$(has_tbl product_prices) $(has_tbl 'Legacy Notes')"
  sync_run --verify
  check "--verify exits 0" 0 "$RC"
  check_noout "--verify no longer checks product_prices" 'product_prices +(rows|sum|max|content)'
  check_out "--verify lists the orphans" '^  product_prices$'
  check_nolog "no DRIFT [new_table] for an excluded table" 'DRIFT \[new_table\] (product_prices|Legacy)'
  ch_drop; sync_run --init; sync_run --full
  check "fresh ClickHouse database: excluded tables are never created" "0 0" "$(has_tbl product_prices) $(has_tbl 'Legacy Notes')"
  check "all other tables mirrored (10)" 10 "$(chv "SELECT count() FROM minimart._plan WHERE plan_id = (SELECT argMax(plan_id, planned_at) FROM minimart._plan_current)")"

  # strategy overrides
  ovr "snapshot products" "incremental orders placed_at created" "incremental stock_movements created_at updated" \
      "incremental event_log ts created" "incremental categories sort_order" "incremental customers signed_up_at updated"
  rebuild "B1 strategy overrides"
  check "snapshot products: strategy snapshot (it would be incremental_updated), reason, engine MergeTree" "snapshot|override: snapshot|MergeTree" \
        "$(strategy products)|$(plan_reason products)|$(engine products)"
  check "incremental orders placed_at created -> incremental_created on placed_at" "incremental_created placed_at" "$(strategy orders) $(chg_col orders)"
  check "incremental stock_movements created_at updated -> incremental_updated on created_at, ReplacingMergeTree(created_at)" "incremental_updated created_at ReplacingMergeTree(created_at)" \
        "$(strategy stock_movements) $(chg_col stock_movements) $(engine stock_movements)"
  check "customers: naive timestamp as change column (override)" "incremental_updated signed_up_at" "$(strategy customers) $(chg_col customers)"
  check "event_log has no primary key: incremental override ignored, stated in the reason" "snapshot" "$(strategy event_log)"
  check_match "...reason says no primary key" 'no primary key' "$(plan_reason event_log)"
  check "incremental on a non-timestamp column is ignored" "snapshot" "$(strategy categories)"
  # the overridden incremental plans really sync
  pgx "INSERT INTO stock_movements (product_id, delta, reason) VALUES (1, 5, 'override-test')"
  pgx "INSERT INTO orders (customer_id, total) VALUES (1, 12.5)"
  pgx "UPDATE products SET name = 'snapshot-override' WHERE product_id = 2"
  sync_run; check "run exits 0" 0 "$RC"
  check "new stock movement and new order mirrored by the overridden incremental plans, products (snapshot) updated" "1 1 snapshot-override" \
        "$(chv "SELECT count() FROM minimart.stock_movements FINAL WHERE reason = 'override-test'") $(chv "SELECT count() FROM minimart.orders FINAL WHERE total = 12.5") $(chv "SELECT name FROM minimart.products WHERE product_id = 2")"
  sync_run --verify; check "--verify exits 0" 0 "$RC"
}

sec_B1b() {
  hdr "B1b overrides naming something that does not exist"
  fresh
  ovr "exclude no_such_table" "snapshot no_such_table2" "incremental products no_such_col" "exclude-column products.no_such_col" "string-column nosuch.col" "allow-column products.nosuchcol"
  sync_run --init
  check "--init exits 0 (a typo is not fatal)" 0 "$RC"
  check "init/--print/log WARNs about overrides that match nothing (a typo in exclude / exclude-column would leave a table or column mirrored silently)" "yes" \
        "$( { out; cat "$LOG"; } | grep -qiE 'no_such|match(es)? nothing|unknown (table|column)|not found' && echo yes || echo no)"
}

sec_B2() {
  hdr "B2 overrides: exclude-column, allow-column (bytea, sensitive), string-column"
  fresh
  ovr "exclude-column products.margin" "exclude-column orders.order_id" "string-column products.price" "string-column products.created_at" \
      "string-column orders.placed_at" "allow-column products.photo" "string-column customers.signed_up_at" "string-column orders.delivered_at"
  rebuild "B2 column overrides"
  check "exclude-column products.margin: not in the mirror, reason recorded" "0 override: exclude-column" "$(has_col products margin) $(col_reason products margin)"
  check "exclude-column of a primary key column (orders.order_id): table becomes a snapshot, column absent" "snapshot 0" "$(strategy orders) $(has_col orders order_id)"
  check_match "...with the reason in the plan" 'primary key includes an excluded column' "$(plan_reason orders)"
  check "orders still has all 1500 rows" 1500 "$(nrows orders)"
  check "string-column: price String, created_at String, placed_at String" "String String String" "$(col_type products price) $(col_type products created_at) $(col_type orders placed_at)"
  eq_data "string-column products.price equals Postgres' text form" products product_id "price::text" "price"
  eq_data "string-column products.created_at equals Postgres' text form (UTC session)" products product_id "created_at::text" "created_at"
  eq_data "string-column orders.placed_at equals Postgres' text form" orders "invoice_no" "placed_at::text" "placed_at"
  eq_data "string-column naive timestamp customers.signed_up_at equals Postgres' text" customers customer_id "signed_up_at::text" "signed_up_at"
  eq_data "string-column orders.delivered_at (nullable) equals Postgres' text" orders invoice_no "coalesce(delivered_at::text, '~')" "ifNull(delivered_at, '~')"
  # bytea
  check "allow-column products.photo: mirrored, as String" "String" "$(col_type products photo | sed 's/Nullable(\(.*\))/\1/')"
  check "photo values: Postgres bytea::text is the hex form" "\\x00000007" "$(pgv "SELECT photo::text FROM products WHERE product_id = 7")"
  eq_data "allow-column bytea mirrored as the hex text of Postgres (\\x....) for every row" products product_id "coalesce(photo::text, '~')" "ifNull(photo, '~')"
  # a string-column on the change column => no usable change column
  ovr "string-column products.updated_at" "string-column products.created_at"
  sync_run --init
  check "string-column on the change columns (updated_at and created_at): products falls back to snapshot (no usable change column)" "snapshot" "$(strategy products)"
}

sec_B3() {
  hdr "B3 overrides: allow-column on a sensitive column (needs the grants), --grant-args, deny via grants"
  fresh
  ovr "allow-column customers.reset_otp" "exclude-column products.margin" "exclude-column \"Legacy Notes\".\"Note Text\""
  sync_run --init; check "--init exits 0" 0 "$RC"
  check "allow-column on a column the role cannot read: still not mirrored (reason: no SELECT privilege)" "0 no SELECT privilege for minimart_ro" "$(has_col customers reset_otp) $(col_reason customers reset_otp)"
  sync_run --grant-args
  check "--grant-args exits 0" 0 "$RC"
  check "--grant-args prints allow_cols= and deny_cols= (names with spaces verbatim)" "allow_cols=customers.reset_otp|deny_cols=products.margin,Legacy Notes.Note Text" "$(grep -E '^(allow|deny)_cols=' "$WORK/out/last.txt" | tr '\n' '|' | sed 's/|$//')"
  local ga=() l
  while IFS= read -r l; do ga[${#ga[@]}]="-v"; ga[${#ga[@]}]="$l"; done < <(grep -E '^(allow|deny)_cols=' "$WORK/out/last.txt")
  mm_grants ${ga[@]+"${ga[@]}"}
  check "grants file with the --grant-args exits 0 (no ERROR in its output)" 0 "$(grep -c ERROR "$WORK/out/grants.txt")"
  check "role can now read customers.reset_otp, still not api_token / password_hash" "t f f" "$(can_col customers reset_otp) $(can_col customers api_token) $(can_col customers password_hash)"
  check "role can no longer read products.margin and \"Legacy Notes\".\"Note Text\"; reads products.name and Legacy Notes.Note Id" "f f t t" \
        "$(can_col products margin) $(can_col 'Legacy Notes' 'Note Text') $(can_col products name) $(can_col 'Legacy Notes' 'Note Id')"
  logreset; sync_run
  check_log "drift is reported for the changed privileges before --init" 'DRIFT'
  logreset
  rebuild "B3 after the grants"
  check "customers.reset_otp is now mirrored; api_token, password_hash are not" "1 0 0" "$(has_col customers reset_otp) $(has_col customers api_token) $(has_col customers password_hash)"
  eq_data "reset_otp values arrive (equal to Postgres)" customers customer_id "coalesce(reset_otp, '~')" "ifNull(reset_otp, '~')"
  check "margin and Note Text not mirrored" "0 0" "$(has_col products margin) $(has_col 'Legacy Notes' 'Note Text')"
  check_nolog "no DRIFT after grants + init" 'DRIFT \[(changed|new|dropped)'
  sync_run --verify; check "--verify exits 0" 0 "$RC"
  # without the overrides the plain rule applies again
  rm -f "$OVR"; mm_grants
  check "grants without the overrides revoke reset_otp again" "f" "$(can_col customers reset_otp)"
  sync_run; echo "      (sync after the revoke, before --init: rc=$RC)"
  sync_run --init; sync_run --full; sync_run --verify
  check "back to the plain rule: --verify exits 0, reset_otp not mirrored, margin mirrored" "0 0 1" "$RC $(has_col customers reset_otp) $(has_col products margin)"
}

sec_B4() {
  hdr "B4 overrides: names with spaces / quotes, comments, CRLF, tabs, BOM"
  fresh
  pgx 'CREATE TABLE "Sp T" (id integer PRIMARY KEY, "c""d" text, keep text, "Odd Col" text); INSERT INTO "Sp T" VALUES (1, $$a$$, $$b$$, $$c$$)'
  mm_grants
  printf '# overrides with CRLF line endings\r\n\r\n   exclude\tproduct_prices   # trailing comment\r\n\t# indented comment\r\nsnapshot  "Legacy Notes"\r\nexclude-column "Legacy Notes"."Note Text"\r\nexclude-column "Sp T"."c""d"\r\nstring-column "Sp T"."Odd Col"\r\nincremental products created_at created\r\n' > "$OVR"
  MINIMART_OVERRIDES="$OVR" bash "$GEN" --check-overrides >"$WORK/out/co.txt" 2>&1; local rc=$?
  check "--check-overrides accepts CRLF, tabs, comments, quoted names" 0 "$rc"
  rebuild "B4 CRLF file"
  check "exclude product_prices applied" "no" "$(plan_tables | grep -q product_prices && echo yes || echo no)"
  check "snapshot \"Legacy Notes\" applied; Note Text excluded; Created kept" "snapshot 0 1" "$(strategy 'Legacy Notes') $(has_col 'Legacy Notes' 'Note Text') $(has_col 'Legacy Notes' Created)"
  check "table with a space mirrored; column with a double quote in its name excluded by the quoted override (\"\" = one quote); the others mirrored" "1 0 1 1" "$(has_tbl 'Sp T') $(has_col 'Sp T' 'c"d') $(has_col 'Sp T' keep) $(has_col 'Sp T' 'Odd Col')"
  check "incremental products created_at created (the ' created' kind, with CRLF)" "incremental_created created_at" "$(strategy products) $(chg_col products)"
  check "Sp T row content" "1 b c" "$(chv "SELECT concat(toString(id), ' ', keep, ' ', \`Odd Col\`) FROM minimart.\`Sp T\`")"
  # UTF-8 byte order mark at the start of the file (Windows editors)
  printf '\xef\xbb\xbfexclude product_prices\nexclude settings\n' > "$OVR"
  sync_run --init
  if [[ $RC -eq 0 ]]; then
    check "BOM: accepted AND the first directive is applied" "no" "$(plan_tables | grep -q product_prices && echo yes || echo no)"
  else
    check "BOM: rejected (--init exit 1, nothing silently ignored); message: $(grep -a FAILED "$LOG" | tail -1 | cut -c1-200)" 1 "$RC"
  fi
}

sec_B5() {
  hdr "B5 overrides: syntax errors fail --init BEFORE changing anything; at run time they do not stop the sync"
  fresh
  ovr "exclude-column products.margin"
  sync_run --init; check "valid override: --init exits 0" 0 "$RC"
  sync_run --full; check "full exits 0" 0 "$RC"
  local pid0 n0 cur0 plans0 wm0 cases="frobnicate x|incremental products|exclude-column products|exclude \"unterminated|incremental products updated_at weekly|exclude products extra|snapshot|exclude-column .x|allow-column a.b c"
  pid0=$(plan_id); plans0=$(chv "SELECT count() FROM minimart._plan"); cur0=$(chv "SELECT count() FROM minimart._plan_current"); n0=$(nrows products); wm0=$(wm products)
  local bad_line IFS_SAVE=$IFS
  IFS='|'
  for bad_line in $cases; do
    IFS=$IFS_SAVE
    ovr "exclude product_prices" "$bad_line"
    sync_run --init
    check "syntax error [$bad_line]: --init exits 1" 1 "$RC"
    check_log "...with a clear message naming the overrides file and line 2" 'overrides file .* line 2'
    check "...old plan untouched (plan id, _plan rows, _plan_current rows, mirror rows, watermark)" "$pid0 $plans0 $cur0 $n0 $wm0" "$(plan_id) $(chv "SELECT count() FROM minimart._plan") $(chv "SELECT count() FROM minimart._plan_current") $(nrows products) $(wm products)"
    IFS='|'
  done
  IFS=$IFS_SAVE
  ovr "exclude product_prices" "frobnicate x"
  sync_run --print; check "--print with a syntax error exits non-zero" 1 "$([[ $RC -ne 0 ]] && echo 1 || echo 0)"
  sync_run --grant-args; check "--grant-args with a syntax error exits non-zero" 1 "$([[ $RC -ne 0 ]] && echo 1 || echo 0)"
  # run time: the stored plan keeps working
  pgx "UPDATE products SET name = 'still-syncing' WHERE product_id = 3"
  logreset; sync_run
  check "run with an invalid overrides file: exits 0 (the sync does not stop)" 0 "$RC"
  check_log "WARNING: overrides file invalid, schema drift not checked" 'WARNING: overrides file invalid, schema drift not checked'
  check "data still synced" "still-syncing" "$(chv "SELECT name FROM minimart.products FINAL WHERE product_id = 3")"
  sync_run --verify; check "--verify with an invalid overrides file exits 1" 1 "$RC"
  # ...and a real drift at the same time must not corrupt anything: the table's own sync fails loudly
  pgx "ALTER TABLE categories DROP COLUMN sort_order"
  pgx "UPDATE products SET name = 'other-table' WHERE product_id = 4"
  local c0 cw0; c0=$(nrows categories); cw0=$(wm categories)
  logreset; sync_run
  check "drop column while the drift check is blind: run exits 1" 1 "$RC"
  check_log "that table FAILED loudly (its watermark was not advanced)" 'FAILED categories'
  check "its mirror and watermark untouched" "$c0 $cw0" "$(nrows categories) $(wm categories)"
  check "the other tables still synced" "other-table" "$(chv "SELECT name FROM minimart.products FINAL WHERE product_id = 4")"
  ovr "exclude-column products.margin"
  sync_run --init; sync_run
  check "valid file again + --init: sync exits 0" 0 "$RC"
}

# ================================================================= C. EDGE SCHEMAS
# use_db <suffix>: point the scratch ClickHouse (named collection pg_minimart) at Postgres database mmc_b<suffix>
use_db() {
  mm_ch_stop
  PGDB=mmc_b$1; RO_ROLE=mmc_ro_b$1
  mm_ch_start
}

sec_C1() {
  hdr "C1 an EMPTY Postgres database (no tables at all)"
  ch_drop
  local p=$PASS
  PGSU "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = 'mmc_b_empty'" >/dev/null 2>&1
  dropdb --if-exists mmc_b_empty 2>/dev/null; createdb mmc_b_empty
  PGDB=mmc_b_empty; RO_ROLE=mmc_ro_b_empty; mm_ro_role
  PASS=$p
  check "grants file on an empty database exits 0 (no ERROR)" 0 "$(grep -c ERROR "$WORK/out/grants.txt")"
  mm_ch_stop; mm_ch_start                       # named collection now points at mmc_b_empty / mmc_ro_b_empty
  sync_run --init
  check "--init exits 0" 0 "$RC"
  check_log "--init says 0 tables" 'OK: plan .*: 0 tables'
  sync_run;         check "incremental run exits 0" 0 "$RC"
  check_log "run logged OK with 0 tables" 'OK in [0-9]+s: 0 tables'
  sync_run --full;  check "--full exits 0" 0 "$RC"
  sync_run --verify; check "--verify exits 0 on a mirror of nothing" 0 "$RC"
  sync_run --print;  check "--print exits 0" 0 "$RC"
  sync_run --init;  check "second --init exits 0" 0 "$RC"
  check "no mirror tables, no leftovers" "0 0" "$(chv "SELECT count() FROM system.tables WHERE database = 'minimart' AND NOT startsWith(name, '_')") $(leftovers)"
  # the empty database gets its first table
  pgx "CREATE TABLE first_t (id integer PRIMARY KEY, v text); INSERT INTO first_t VALUES (1, 'x'), (2, NULL)"
  logreset; sync_run
  check "new table in the empty database: sync exits 0" 0 "$RC"
  check_log "reported as new_table (not readable until the grants are run)" 'DRIFT \[new_table\] first_t'
  mm_grants; sync_run --init
  check "--init exits 0 after the grants" 0 "$RC"
  sync_run;   check "sync exits 0" 0 "$RC"
  check "first_t mirrored (2 rows)" 2 "$(nrows first_t)"
  sync_run --verify; check "--verify exits 0" 0 "$RC"
  # back to the normal database
  ch_drop
  PGDB=mmc_b; RO_ROLE=mmc_ro_b
  mm_ch_stop; mm_ch_start
}

sec_C2() {
  hdr "C2 only EMPTY tables (default threshold, then every table incremental)"
  fresh no
  check "every mirror table has 0 rows" "0" "$(chv "SELECT sum(total_rows) FROM system.tables WHERE database = 'minimart' AND NOT startsWith(name, '_')")"
  sync_run;         check "incremental run exits 0" 0 "$RC"
  sync_run --verify; check "--verify exits 0" 0 "$RC"
  # MINIMART_SMALL_ROWS=0 makes every table with a key and a change column incremental
  set_env 0
  rebuild "C2 threshold 0 (incremental templates on empty tables)"
  check "incremental strategies in use" "incremental_updated incremental_updated incremental_created" "$(strategy products) $(strategy orders) $(strategy stock_movements)"
  pgx "INSERT INTO categories VALUES (1, 'c', 1)"
  pgx "INSERT INTO products (sku, name, category_id, price) VALUES ('E-1', 'first', 1, 2.5)"
  pgx "INSERT INTO customers (email, full_name, password_hash) VALUES ('e@x', 'E', 'h')"
  pgx "INSERT INTO orders (customer_id, total) VALUES (1, 9)"
  pgx "INSERT INTO stock_movements (product_id, delta, reason) VALUES (1, 4, 'in')"
  sync_run; check "run exits 0" 0 "$RC"
  check "rows arrive through the incremental templates (products customers orders stock_movements)" "1 1 1 1" "$(nfinal products) $(nfinal customers) $(nfinal orders) $(nfinal stock_movements)"
  sync_run --verify; check "--verify exits 0" 0 "$RC"
  set_env
}

sec_C3() {
  hdr "C3 tables with no mirrorable column (all sensitive / not readable)"
  fresh yes "CREATE TABLE all_secret (password text, api_token text, pin_code integer); INSERT INTO all_secret VALUES ('p', 't', 1), ('q', 'u', 2)"
  pgx "CREATE TABLE unread (id integer PRIMARY KEY, v text); INSERT INTO unread VALUES (1, 'a')"      # created after the grants: unreadable
  check "precondition: the role reads nothing of all_secret and unread" "f f f f" "$(can_col all_secret password) $(can_col all_secret pin_code) $(can_tbl unread) $(can_col unread v)"
  sync_run --init
  check "--init exits 0" 0 "$RC"
  check "neither is mirrored or in the plan" "0 0 no no" "$(has_tbl all_secret) $(has_tbl unread) $(plan_tables | grep -q all_secret && echo yes || echo no) $(plan_tables | grep -q unread && echo yes || echo no)"
  check "reasons are recorded per column" "sensitive name|no SELECT privilege for minimart_ro" "$(col_reason all_secret password)|$(col_reason unread v)"
  logreset; sync_run
  check "sync exits 0 (nothing to do for them, nothing breaks)" 0 "$RC"
  check_nolog "no FAILED / SKIPPED" 'FAILED|SKIPPED'
  sync_run --verify
  check "--verify exits 0 (the not-mirrored tables are not a problem once --init adopted the catalog)" 0 "$RC"
  check_out "--verify lists all_secret.password among the sensitive columns not mirrored" 'all_secret\.password'
  sync_run --print
  check "--print exits 0" 0 "$RC"
  check_out "--print lists the unmirrored columns of all_secret" 'all_secret\.password +\[sensitive name\]'
  check_out "--print lists unread.v with its reason" 'unread\.v +\[no SELECT privilege'
  check "the 12 stand-in tables are mirrored" 12 "$(chv "SELECT count() FROM minimart._plan WHERE plan_id = (SELECT argMax(plan_id, planned_at) FROM minimart._plan_current)")"
}

sec_C4() {
  hdr "C4 weird names"
  local long63 col63
  long63=$(printf 't%.0s' $(seq 1 63)); col63=$(printf 'c%.0s' $(seq 1 63))
  fresh no
  PGF "$T/t2_weird_names.sql" || bad "t2_weird_names.sql failed"
  mm_grants
  check "grants file on the weird schema exits 0 (no ERROR)" 0 "$(grep -c ERROR "$WORK/out/grants.txt")"
  sync_run --init
  check "--init exits 0" 0 "$RC"
  logreset; sync_run --full
  echo "      (--full rc=$RC; failed tables: $(grep -a -o 'FAILED [^ ]*' "$LOG" | sort -u | tr '\n' ' '))"
  check "BUG? --full exits 0: no weird name may make a table fail on every run (a name that cannot be read must be EXCLUDED at --init with a reason)" 0 "$RC"
  check "BUG? no table FAILED (a double quote in a table or column name is not supported by ClickHouse' PostgreSQL engine)" 0 "$(log_has 'FAILED')"
  sync_run --verify
  check "--verify exits 0" 0 "$RC"
  # per table: mirrored right, or excluded with a reason
  check "backtick table + column mirrored" "1 1" "$(has_tbl 'tick`tbl') $(has_col 'tick`tbl' 'col`umn')"
  check "backtick table: 2 rows, 1 non-null" "2 1" "$(chv "SELECT concat(toString(count()), ' ', toString(count($(bq 'col`umn')))) FROM minimart.$(bq 'tick`tbl')")"
  check "single quote table mirrored with its data" "2 1 11" "$(nrows "it's") $(chv "SELECT count() FROM minimart.$(bq "it's") WHERE $(bq "it's col") = 'x'") $(chv "SELECT sum(v) FROM minimart.$(bq "it's")")"
  check "back\\slash (backslash in table and column name): mirrored OR excluded with a reason" "ok" "$([[ "$(has_tbl 'back\slash')" == 1 || -n "$(col_reason 'back\slash' 'b\c')" ]] && echo ok)"
  ! grep -aq 'FAILED back' "$LOG" && check "back\\slash: row with a backslash value intact" 'a\b' "$(chv "SELECT $(bq 'b\c') FROM minimart.$(bq 'back\slash') WHERE id = 1")"
  check "dq\"t (double quote in table name): mirrored OR excluded with a reason" "ok" "$([[ "$(has_tbl 'dq"t')" == 1 || -n "$(col_reason 'dq"t' v)" ]] && echo ok)"
  check "dq_col.x\"y (double quote in a column name): mirrored OR excluded with a reason" "ok" "$([[ "$(has_col dq_col 'x"y')" == 1 || -n "$(col_reason dq_col 'x"y')" ]] && echo ok)"
  check "dq_col still mirrors its other column" 1 "$(has_col dq_col ok)"
  check "_hidden, _plan, _sync_state: not mirrored, not in the plan" "0 0 0" "$(has_tbl _hidden) $(chv "SELECT count() FROM minimart._plan WHERE table_name = '_plan'") $(chv "SELECT count() FROM minimart._plan WHERE table_name = '_sync_state'")"
  sync_run --print
  check "--print states the reason: reserved name (leading underscore)" 3 "$(out_has '^_(hidden|plan|sync_state) +excluded .*reserved name')"
  check "the internal tables _plan and _sync_state are intact (not overwritten by the Postgres tables of the same names)" "ok" "$([[ "$(chv "SELECT count() FROM minimart._plan")" -gt 5 && "$(chv "SELECT count() FROM minimart._sync_state")" -gt 5 ]] && echo ok)"
  check "at@sign: excluded (unsupported name), not mirrored" "0 unsupported name" "$(has_tbl 'at@sign') $(col_reason 'at@sign' v)"
  check "at_col.a@b excluded, at_col.ok mirrored" "0 1 unsupported name" "$(has_col at_col 'a@b') $(has_col at_col ok) $(col_reason at_col 'a@b')"
  check "63-character table and column names mirrored" "long" "$(chv "SELECT \`$col63\` FROM minimart.\`$long63\`")"
  check "wide table (131 columns) mirrored with its rows, sum correct" "131 20 $(pgv "SELECT sum(c130) FROM wide")" "$(chv "SELECT count() FROM system.columns WHERE database = 'minimart' AND table = 'wide'") $(nrows wide) $(chv "SELECT sum(c130) FROM minimart.wide")"
  check "ClickHouse keyword column names: all 12 mirrored with their values" "12 s|2|k|4|5|f|t|g|w|d|n|i" "$(chv "SELECT count() FROM system.columns WHERE database = 'minimart' AND table = 'kw' AND name != 'id'") $(chv "SELECT concat(\`select\`, '|', toString(\`order\`), '|', \`key\`, '|', toString(\`index\`), '|', toString(\`limit\`), '|', \`from\`, '|', \`table\`, '|', \`group\`, '|', \`where\`, '|', \`default\`, '|', \`null\`, '|', \`insert\`) FROM minimart.kw WHERE id = 1")"
  check "unicode table / column names mirrored" "值 é" "$(chv "SELECT concat(\`列\`, ' ', \`naïve\`) FROM minimart.\`表格\`")"
  check "dot in table name: mirrored OR excluded with a reason (never a failure)" "ok" "$([[ "$(has_tbl 'dot.name')" == 1 || -n "$(col_reason 'dot.name' 'a.b')" ]] && echo ok)"
  check "double space / leading space names mirrored" "1" "$(chv "SELECT count() FROM minimart.\`two  spaces \` WHERE \` lead\` = 'x'")"
  check "newline in a table name: not mirrored (unsupported)" "0" "$(chv "SELECT count() FROM system.tables WHERE database = 'minimart' AND position(name, char(10)) > 0")"
  check "newline in a column name: that column excluded, the other mirrored" "0 1" "$(chv "SELECT count() FROM system.columns WHERE database = 'minimart' AND table = 'nl_col' AND position(name, char(10)) > 0") $(has_col nl_col ok)"
  pgx "INSERT INTO categories VALUES (1, 'a', 1)"
  pgx "UPDATE \"it's\" SET v = 50 WHERE id = 1"
  sync_run
  check "next incremental run exits 0 with the weird tables in the plan" 0 "$RC"
  sync_run --verify; check "--verify exits 0 again" 0 "$RC"
}

sec_C5() {
  hdr "C5 types that are not in the stand-in"
  fresh no
  PGF "$T/t2_types.sql" || bad "t2_types.sql failed"
  mm_grants
  check "grants exit 0" 0 "$(grep -c ERROR "$WORK/out/grants.txt")"
  check "partition children and the view are not readable by the role; the parent is" "t f f" "$(can_tbl part) $(can_tbl part_2024) $(can_tbl v_types)"
  sync_run --init;  check "--init exits 0" 0 "$RC"
  logreset; sync_run --full; check "--full exits 0" 0 "$RC"
  check_nolog "no FAILED" 'FAILED'
  sync_run --verify; check "--verify exits 0" 0 "$RC"
  check "view not mirrored; partition parent mirrored, children not" "0 1 0 0" "$(has_tbl v_types) $(has_tbl part) $(has_tbl part_2024) $(has_tbl part_2025)"
  check "partitioned parent has all 40 rows (read through the parent)" 40 "$(nrows part)"
  check "inheritance: both tables mirrored; the parent holds the child's rows too (as SELECT does in Postgres)" "$(pgv "SELECT (SELECT count(*) FROM inh_parent) || ' ' || (SELECT count(*) FROM ONLY inh_parent) || ' ' || (SELECT count(*) FROM inh_child)")" \
        "$(nrows inh_parent) $(chv "SELECT countIf(a = 'parent') FROM minimart.inh_parent") $(nrows inh_child)"
  check "money / bit / varbit / timetz are Nullable(String), arrays 1-3 dimensional typed" "Nullable(String) Nullable(String) Nullable(String) Nullable(String) Array(Array(Nullable(Int32))) Array(Array(Array(Nullable(Int32)))) Array(Nullable(String)) Array(Nullable(Decimal(5, 2))) Array(Nullable(UUID)) Array(Nullable(String))" \
        "$(col_type types_t m) $(col_type types_t b3) $(col_type types_t vb) $(col_type types_t ttz) $(col_type types_t a2) $(col_type types_t a3) $(col_type types_t ta) $(col_type types_t na) $(col_type types_t ua) $(col_type types_t tsa)"
  check "numeric(40,10) Decimal256, numeric(76,0) Decimal(76,0), numeric(77,0) and numeric(1000,0) Float64, enum LowCardinality, composite String, generated Int32" \
        "Nullable(Decimal(40, 10)) Nullable(Decimal(76, 0)) Nullable(Float64) Nullable(Float64) LowCardinality(Nullable(String)) Nullable(String) Nullable(Int32)" \
        "$(col_type types_t n40) $(col_type types_t n76) $(col_type types_t n77) $(col_type types_t n1000) $(col_type types_t mc) $(col_type types_t comp) $(col_type types_t gen)"
  eq_data "money text form" types_t id "coalesce(m::text, '~')" "ifNull(m, '~')"
  eq_data "bit(3) / varbit text" types_t id "coalesce(b3::text || '/' || vb::text, '~')" "ifNull(concat(b3, '/', vb), '~')"
  eq_data "timetz text" types_t id "coalesce(ttz::text, '~')" "ifNull(ttz, '~')"
  eq_data "2-D int array (flattened, NULL elements)" types_t id "coalesce(array_to_string(a2, ',', 'N'), '')" "arrayStringConcat(arrayMap(x -> ifNull(toString(x), 'N'), arrayFlatten(a2)), ',')"
  eq_data "3-D int array (flattened)" types_t id "coalesce(array_to_string(a3, ',', 'N'), '')" "arrayStringConcat(arrayMap(x -> ifNull(toString(x), 'N'), arrayFlatten(a3)), ',')"
  eq_data "text[] with NULL elements, commas, quotes, backslashes, braces, unicode" types_t id "coalesce(array_to_string(ta, chr(31), '<NULL>'), '')" "arrayStringConcat(arrayMap(x -> ifNull(x, '<NULL>'), ta), '\\x1f')"
  eq_data "numeric(5,2)[] with NULL (Decimal printed without trailing zeros: compared with trim_scale)" types_t id "coalesce((SELECT array_to_string(array_agg(trim_scale(x)), ',', 'N') FROM unnest(na) x), '')" "arrayStringConcat(arrayMap(x -> ifNull(toString(x), 'N'), na), ',')"
  eq_data "uuid[]" types_t id "coalesce(array_to_string(ua, ',', 'N'), '')" "arrayStringConcat(arrayMap(x -> ifNull(toString(x), 'N'), ua), ',')"
  eq_data "timestamp[] (strings)" types_t id "coalesce(array_to_string(tsa, ',', 'N'), '')" "arrayStringConcat(arrayMap(x -> ifNull(x, 'N'), tsa), ',')"
  eq_data "numeric(40,10) (Decimal256) exact value (trailing zeros not printed by ClickHouse: trim_scale)" types_t id "coalesce(trim_scale(n40)::text, '~')" "ifNull(toString(n40), '~')"
  eq_data "numeric(76,0) exact" types_t id "coalesce(n76::text, '~')" "ifNull(toString(n76), '~')"
  eq_data "enum with spaces / unicode / quote" types_t id "coalesce(mc::text, '~')" "ifNull(toString(mc), '~')"
  eq_data "composite type as its text form" types_t id "coalesce(comp::text, '~')" "ifNull(comp, '~')"
  eq_data "generated column" types_t id "coalesce(gen::text, '~')" "ifNull(toString(gen), '~')"
  eq_data "double precision incl. NaN, Infinity, -Infinity (ClickHouse spells them nan, inf, -inf)" types_t id "coalesce(replace(lower(f8::text), 'infinity', 'inf'), '~')" "ifNull(toString(f8), '~')"
  check "real NaN / -Infinity survive (row 3 NaN, row 4 -Infinity)" "nan -inf" "$(chv "SELECT toString(f4) FROM minimart.types_t WHERE id = 3") $(chv "SELECT toString(f4) FROM minimart.types_t WHERE id = 4")"
  check "numeric(1000,0) 1e299 as Float64" "t" "$(chv "SELECT if(abs(n1000 / 1e299 - 1) < 1e-12, 't', 'f') FROM minimart.types_t WHERE id = 1")"
  check "ctas array columns (attndims 0): the whole literal as String" "{1,2,3} {x,y}" "$(chv "SELECT concat(a, ' ', t) FROM minimart.ctas_arr")"
}

sec_C5b() {
  hdr "C5b values that Postgres allows and ClickHouse may not parse: infinity, NaN in numeric(p,s), array dimension mismatch, extreme dates"
  fresh no
  pgx "CREATE TABLE inf_ts (id integer PRIMARY KEY, ts timestamptz, d date); INSERT INTO inf_ts VALUES (1, 'infinity', 'infinity'), (2, '-infinity', '-infinity'), (3, now(), current_date)"
  pgx "CREATE TABLE nan_dec (id integer PRIMARY KEY, n numeric(12,2)); INSERT INTO nan_dec VALUES (1, 'NaN'), (2, 1.5)"
  pgx "CREATE TABLE nan_num (id integer PRIMARY KEY, n numeric); INSERT INTO nan_num VALUES (1, 'NaN'), (2, 1.5)"
  pgx "CREATE TABLE arr_mis (id integer PRIMARY KEY, a integer[]); INSERT INTO arr_mis VALUES (1, '{{1,2},{3,4}}'), (2, '{5,6}')"
  pgx "CREATE TABLE ext_ts (id integer PRIMARY KEY, ts timestamptz); INSERT INTO ext_ts VALUES (1, '0001-01-01 00:00:00+00'), (2, '9999-12-31 23:59:59+00'), (3, '4713-01-01 BC')"
  pgx "CREATE TABLE ok_t (id integer PRIMARY KEY, v text); INSERT INTO ok_t VALUES (1, 'fine')"
  mm_grants
  sync_run --init; check "--init exits 0" 0 "$RC"
  logreset; sync_run --full
  local rc_full=$RC t
  echo "      --full rc=$rc_full. Per table (OK = loaded; FAILED = that table's script failed, the others are unaffected):"
  for t in inf_ts nan_dec nan_num arr_mis ext_ts ok_t; do
    if grep -aq "FAILED $t " "$LOG"; then echo "        $t: FAILED: $(grep -a "FAILED $t " "$LOG" | head -1 | sed 's/.*Received exception from server//' | cut -c1-230)"; else echo "        $t: OK ($(nrows $t) rows)"; fi
  done
  check "other tables are unaffected by a table that cannot be loaded" "1 fine" "$(nrows ok_t) $(chv "SELECT v FROM minimart.ok_t")"
  check "a failing table is never silent: run exit 1 and a PARTIAL line naming it" "ok" \
        "$(if grep -aq 'FAILED ' "$LOG"; then grep -aq 'PARTIAL: .*not synced:' "$LOG" && [[ $rc_full -eq 1 ]] && echo ok; else echo ok; fi)"
  check "unconstrained numeric 'NaN' loads (nan_num: 2 rows)" "2" "$(nrows nan_num 2>/dev/null | head -1)"
  check "LIMITATION? date / timestamptz 'infinity' (common as 'valid until') loads by default (inf_ts: 3 rows)" "3" "$(nrows inf_ts 2>/dev/null | head -1)"
  check "LIMITATION? numeric(12,2) 'NaN' loads by default (nan_dec: 2 rows)" "2" "$(nrows nan_dec 2>/dev/null | head -1)"
  check "LIMITATION? integer[] holding a 2-D value loads by default (arr_mis: 2 rows)" "2" "$(nrows arr_mis 2>/dev/null | head -1)"
  check "LIMITATION? timestamptz at year 1 / 9999 / 4713 BC (outside 1900..2299 of DateTime64) loads by default (ext_ts: 3 rows)" "3" "$(nrows ext_ts 2>/dev/null | head -1)"
  # the documented remedy for a column ClickHouse cannot type: string-column
  ovr "string-column inf_ts.ts" "string-column inf_ts.d" "string-column nan_dec.n" "string-column arr_mis.a" "string-column ext_ts.ts"
  sync_run --init; check "--init with string-column overrides exits 0" 0 "$RC"
  logreset; sync_run --full
  check "with string-column overrides the whole run is clean (the remedy works)" 0 "$RC"
  eq_data "inf_ts.ts as text (infinity preserved)" inf_ts id "ts::text" "ts"
  eq_data "nan_dec.n as text (NaN preserved)" nan_dec id "n::text" "n"
  eq_data "arr_mis.a as its text literal" arr_mis id "a::text" "a"
  eq_data "ext_ts.ts as text" ext_ts id "ts::text" "ts"
  sync_run --verify; check "--verify exits 0 with the overrides" 0 "$RC"
}

sec_C6() {
  hdr "C6 200k-row table: incremental by default, fast first load, an incremental run reads only the changed rows"
  SMALL=100000
  fresh yes "CREATE TABLE big (id bigserial PRIMARY KEY, v integer NOT NULL, payload text, updated_at timestamptz NOT NULL);
             INSERT INTO big (v, payload, updated_at) SELECT g, md5(g::text), now() - interval '10 days' + (g || ' seconds')::interval FROM generate_series(1, 200000) g;
             CREATE INDEX big_updated_idx ON big (updated_at);
             CREATE TABLE big_log (id bigserial PRIMARY KEY, msg text, created_at timestamptz NOT NULL);
             INSERT INTO big_log (msg, created_at) SELECT 'm' || g, now() - interval '20 days' + (g || ' seconds')::interval FROM generate_series(1, 150000) g;
             CREATE INDEX big_log_created_idx ON big_log (created_at);
             ANALYZE big; ANALYZE big_log"
  check "default threshold (no MINIMART_SMALL_ROWS): big incremental_updated, big_log incremental_created; stand-in tables snapshot" \
        "incremental_updated incremental_created snapshot snapshot" "$(strategy big) $(strategy big_log) $(strategy products) $(strategy orders)"
  check "mirror has all rows" "200000 150000" "$(nfinal big) $(nfinal big_log)"
  ch_drop; sync_run --init
  local t0=$SECONDS d; logreset; sync_run --full; d=$((SECONDS - t0))
  check "--full of 350k rows exits 0" 0 "$RC"
  echo "      --full of the whole mirror: ${d}s; big: $(grep -a 'table big ' "$LOG" | tail -1 | sed 's/.* OK in //'), big_log: $(grep -a 'table big_log ' "$LOG" | tail -1 | sed 's/.* OK in //')"
  [[ $d -lt 120 ]] && ok "first full load of the big tables completes in under 120s (${d}s)" || bad "first full load took ${d}s"
  pgx "UPDATE big SET v = -v, updated_at = now() WHERE id <= 50"
  pgx "INSERT INTO big_log (msg, created_at) SELECT 'new' || g, now() FROM generate_series(1, 30) g"
  logreset; t0=$SECONDS; sync_run; d=$((SECONDS - t0))
  check "incremental run exits 0" 0 "$RC"
  [[ $d -lt 30 ]] && ok "incremental run completes in under 30s (${d}s)" || bad "incremental run took ${d}s"
  chq "SYSTEM FLUSH LOGS" >/dev/null; sleep 1; chq "SYSTEM FLUSH LOGS" >/dev/null
  local rr_big rr_log
  rr_big=$(chv "SELECT read_rows FROM system.query_log WHERE type = 'QueryFinish' AND query LIKE 'INSERT INTO minimart.\`big\` %' AND query LIKE '%updated_at\` >%' ORDER BY event_time DESC LIMIT 1")
  rr_log=$(chv "SELECT read_rows FROM system.query_log WHERE type = 'QueryFinish' AND query LIKE 'INSERT INTO minimart.\`big_log\` %' AND query LIKE '%created_at\` >%' ORDER BY event_time DESC LIMIT 1")
  echo "      read_rows of the incremental INSERT: big=$rr_big (50 changed of 200000), big_log=$rr_log (30 new of 150000)"
  [[ "$rr_big" =~ ^[0-9]+$ && $rr_big -le 1000 ]] && ok "incremental INSERT of big read only the changed rows ($rr_big)" || bad "incremental INSERT of big read '$rr_big' rows (expected about 50)"
  [[ "$rr_log" =~ ^[0-9]+$ && $rr_log -le 1000 ]] && ok "incremental INSERT of big_log read only the new rows ($rr_log)" || bad "incremental INSERT of big_log read '$rr_log' rows (expected about 30)"
  check "changes arrived: big sum(v) and big_log count equal Postgres" "$(pgv "SELECT (SELECT sum(v) FROM big) || ' ' || (SELECT count(*) FROM big_log)")" "$(chv "SELECT concat(toString((SELECT sum(v) FROM minimart.big FINAL)), ' ', toString((SELECT count() FROM minimart.big_log FINAL)))")"
  t0=$SECONDS; sync_run --verify; d=$((SECONDS - t0))
  check "--verify of 350k + stand-in rows exits 0" 0 "$RC"
  echo "      --verify took ${d}s"
  SMALL=100; set_env
}

# ----------------------------------------------------------------- section runner
run_sec() { case " ${SECTIONS:-all} " in *" all "*|*" $1 "*) "sec_$1" ;; esac; }
mm_ch_start
for s in A1 A2 A2b A3 A4 A5 A6 A7 A7b A8 A9 A10 B1 B1b B2 B3 B4 B5 C2 C3 C4 C5 C5b C6 C1; do run_sec $s; done
mm_summary
