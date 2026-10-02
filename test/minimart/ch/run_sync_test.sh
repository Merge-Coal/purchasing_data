#!/usr/bin/env bash
# End-to-end test of the minimart mirror (scripts/minimart_sync.sh + scripts/minimart_gen_schema.sh +
# db/minimart_sync.sql + db/minimart_ch_schema.sql + db/minimart_ro_grants.sql) against a REAL scratch
# ClickHouse server and the local Postgres, using the stand-in schema of test/minimart/.
#
#   bash test/minimart/ch/run_sync_test.sh
#   MM_CH_BIN=/path/to/clickhouse-24.8 bash test/minimart/ch/run_sync_test.sh      # production version
#
# Uses (see lib.sh): Postgres database mmc_a + role mmc_ro_a, scratch ClickHouse on ports 19301/18301, the
# real scripts run unmodified behind the docker / clickhouse-client shims in shim/. Everything it creates in
# Postgres is prefixed mmc_a; it never touches a role or database called minimart*.
# Needs bash 3.2+ (runs on macOS bash), psql, perl (only if there is no flock/timeout), a ClickHouse binary.
# Takes a few minutes. Exit status 1 if any check fails.
#
# Groups: 1 basics, 2 --init / --print / types, 3 first sync + byte-for-byte compare + sensitive columns,
# 4 time zone, 5 mutations (incremental runs, documented limits, --full), 6 idempotence, 7 push-down,
# 8 failure handling, 9 --verify tampering, 10 concurrency/safety/timeouts/connections, 11 schema drift,
# 12 overrides, 13 edge cases.
source "$(dirname "$0")/lib.sh"
mm_env a 19301 18301
OUT=$WORK/out
chq() { CH -q "$1" </dev/null 2>&1; }      # same as lib.sh but stdin detached: an INSERT ... VALUES must not wait for data on stdin
ENV100="MINIMART_SMALL_ROWS=100"
ALL=$OUT/all_output.txt; : > "$ALL"
PLAN_Q="plan_id = (SELECT argMax(plan_id, planned_at) FROM minimart._plan_current)"

sec() { echo; echo "== $1 =="; }
# run [args]: sync_run + keep the output of every run in one file (for the secret scans)
run() { sync_run "$@"; { echo "### MM_ENV=[${MM_ENV:-}] $* (rc=$RC)"; cat "$OUT/last.txt"; } >> "$ALL"; }
log_has()  { grep -Fq -- "$1" "$LOG"; }
last_has() { grep -Eq -- "$1" "$OUT/last.txt"; }
out_has()  { grep -Eq -- "$2" "$1"; }

# ---- state helpers ------------------------------------------------------------------------------
plan_hashes() { chq "SELECT arrayStringConcat(groupArray(concat(table_name, ':', plan_hash)), ',') FROM (SELECT table_name, plan_hash FROM minimart._plan WHERE $PLAN_Q ORDER BY table_name)"; }
plan_strats() { chq "SELECT arrayStringConcat(groupArray(concat(table_name, ':', strategy)), ',') FROM (SELECT table_name, strategy FROM minimart._plan WHERE $PLAN_Q ORDER BY table_name)"; }
plan_field()  { chq "SELECT $2 FROM minimart._plan WHERE $PLAN_Q AND table_name = '$1' FORMAT TSVRaw"; }
state_rows()  { chq "SELECT count() FROM minimart._sync_state"; }
wm_all()      { chq "SELECT arrayStringConcat(groupArray(concat(table_name, '=', toString(m))), ',') FROM (SELECT table_name, max(synced_through) AS m FROM minimart._sync_state GROUP BY table_name ORDER BY table_name)"; }
wm_of()       { chq "SELECT toString(max(synced_through)) FROM minimart._sync_state WHERE table_name = '$1'"; }
leftovers()   { chq "SELECT count() FROM system.tables WHERE database = 'minimart' AND (startsWith(name, '_new_') OR startsWith(name, '_src_'))"; }
ch_count()    { chq "SELECT count() FROM minimart.\`$1\`"; }
log_count()   { grep -Fc -- "$1" "$LOG" || true; }
# watermark rows grew by exactly one per synced table: caller passes the number of tables expected
state_delta() { echo $(( $(state_rows) - $1 )); }

# ---- canonical per-row dumps: the same bytes from Postgres and ClickHouse -----------------------------
# kinds: i integer, u uuid, n numeric/decimal (text form), d date, s any text-like value (hex of the UTF-8 bytes),
# f8/f4 float (IEEE bits), fn unconstrained numeric -> Float64 (bits of the nearest double), b bool, t timestamp
# (epoch microseconds), as/ai arrays of text / integers (element-wise, NULL element = \N, NULL array = []).
# NULL is \N on both sides. Only the MIRRORED columns are listed (sensitive ones and bytea are not).
SPEC='categories|category_id|i
categories|name|s
categories|sort_order|i
settings|key|s
settings|value|s
products|product_id|i
products|public_id|u
products|sku|s
products|name|s
products|category_id|i
products|price|n
products|weight_kg|fn
products|rating|f4
products|margin|f8
products|active|b
products|tags|as
products|dims_mm|ai
products|attrs|s
products|released_on|d
products|created_at|t
products|updated_at|t
product_prices|product_id|i
product_prices|valid_from|d
product_prices|price|n
product_prices|note|s
customers|customer_id|i
customers|email|s
customers|full_name|s
customers|phone|s
customers|last_ip|ip
customers|birth_date|d
customers|loyalty_pts|i
customers|signed_up_at|t
customers|updated_at|t
orders|order_id|u
orders|invoice_no|i
orders|customer_id|i
orders|status|s
orders|currency|s
orders|total|n
orders|pickup_slot|s
orders|pickup_eta|s
orders|meta|s
orders|placed_at|t
orders|delivered_at|t
orders|updated_at|t
order_items|order_item_id|i
order_items|order_id|u
order_items|product_id|i
order_items|qty|i
order_items|unit_price|n
order_items|discount|n
order_items|created_at|t
stock_movements|movement_id|i
stock_movements|product_id|i
stock_movements|delta|i
stock_movements|reason|s
stock_movements|created_at|t
event_log|ts|t
event_log|kind|s
event_log|payload|s
event_log|amount|n
user_sessions|customer_id|i
user_sessions|expires_at|t
empty_table|id|i
empty_table|label|s
Legacy Notes|Note Id|i
Legacy Notes|Note Text|s
Legacy Notes|Created|t'
TABLES=$(printf '%s\n' "$SPEC" | awk -F'|' '!seen[$1]++ { print $1 }')
spec_of() { printf '%s\n' "$SPEC" | awk -F'|' -v t="$1" '$1 == t { print $2 "|" $3 }'; }

pg_expr() { # pg_expr kind column
  local q="\"$2\""
  case "$1" in
    i|u|d) echo "$q::text" ;;
    n)  echo "trim_scale($q)::text" ;;
    ip) echo "encode(convert_to(regexp_replace($q::text, '/(32|128)\$', ''), 'UTF8'), 'hex')" ;;     # inet::text appends /32, the output function does not     # ClickHouse's toString(Decimal) drops trailing zeros
    s)  echo "encode(convert_to($q::text, 'UTF8'), 'hex')" ;;
    f8) echo "encode(float8send($q), 'hex')" ;;
    f4) echo "encode(float4send($q), 'hex')" ;;
    fn) echo "encode(float8send($q::float8), 'hex')" ;;
    b)  echo "$q::int" ;;
    t)  echo "floor(extract(epoch from $q) * 1000000)::bigint" ;;
    as) echo "'[' || array_to_string(ARRAY(SELECT coalesce(encode(convert_to(x, 'UTF8'), 'hex'), '\\N') FROM unnest($q) WITH ORDINALITY AS u(x, o) ORDER BY o), ',') || ']'" ;;
    ai) echo "'[' || array_to_string(ARRAY(SELECT coalesce(x::text, '\\N') FROM unnest($q) WITH ORDINALITY AS u(x, o) ORDER BY o), ',') || ']'" ;;
  esac
}
ch_expr() { # ch_expr kind column
  local q="\`$2\`"
  case "$1" in
    i|u|n|d) echo "toString($q)" ;;
    s|ip) echo "lower(hex($q))" ;;
    f8|fn) echo "lpad(lower(hex(reinterpretAsUInt64($q))), 16, '0')" ;;
    f4) echo "lpad(lower(hex(reinterpretAsUInt32($q))), 8, '0')" ;;
    b)  echo "toUInt8($q)" ;;
    t)  echo "toUnixTimestamp64Micro($q)" ;;
    as) echo "concat('[', arrayStringConcat(arrayMap(x -> ifNull(lower(hex(x)), '\\\\N'), $q), ','), ']')" ;;
    ai) echo "concat('[', arrayStringConcat(arrayMap(x -> ifNull(toString(x), '\\\\N'), $q), ','), ']')" ;;
  esac
}
dump_exprs() { # dump_exprs pg|ch table
  local out="" sep="" col kind
  while IFS='|' read -r col kind; do
    out="$out$sep$("$1"_expr "$kind" "$col")"; sep=", "
  done <<<"$(spec_of "$2")"
  echo "$out"
}
use_final() { case "$1" in products|customers|orders) return 0 ;; *) return 1 ;; esac; }   # incremental_updated at MINIMART_SMALL_ROWS=100
pg_dump_table() { # pg_dump_table table -> sorted canonical rows
  psql -X -q -tA -F $'\t' -P null='\N' -v ON_ERROR_STOP=1 -d "$PGDB" -c "SELECT $(dump_exprs pg "$1") FROM \"$1\"" </dev/null 2>&1 | LC_ALL=C sort
}
ch_dump_table() {
  local fin=""; use_final "$1" && fin=" FINAL"
  CH -q "SELECT $(dump_exprs ch "$1") FROM minimart.\`$1\`$fin FORMAT TSVRaw" </dev/null 2>&1 | LC_ALL=C sort
}
compare_table() { # compare_table label table
  local f="$OUT/cmp_$(printf '%s' "$2" | tr -c 'A-Za-z0-9_\n' '_')"
  pg_dump_table "$2" > "$f.pg"; ch_dump_table "$2" > "$f.ch"
  local n; n=$(wc -l < "$f.pg" | tr -d ' ')
  if cmp -s "$f.pg" "$f.ch"; then ok "$1 $2: $n rows identical (every mirrored column, byte for byte)"
  else bad "$1 $2: Postgres and ClickHouse differ ($n rows in Postgres, $(wc -l < "$f.ch" | tr -d ' ') in the mirror)"; diff "$f.pg" "$f.ch" | head -4 | cut -c1-260; fi
}
compare_all() { local t; while IFS= read -r t; do compare_table "$1" "$t"; done <<<"$TABLES"; }
compare_diff() { # compare_diff table -> ONLY_PG ONLY_CH (rows present on one side only)
  local f="$OUT/dif_$(printf '%s' "$1" | tr -c 'A-Za-z0-9_\n' '_')"
  pg_dump_table "$1" > "$f.pg"; ch_dump_table "$1" > "$f.ch"
  ONLY_PG=$(LC_ALL=C comm -23 "$f.pg" "$f.ch" | wc -l | tr -d ' ')
  ONLY_CH=$(LC_ALL=C comm -13 "$f.pg" "$f.ch" | wc -l | tr -d ' ')
}
ch_sig() { # ch_sig table [FINAL]: md5 + count of the whole content (to prove "untouched" / "identical")
  CH -q "SELECT hex(MD5(arrayStringConcat(arraySort(groupArray(toString(tuple(*)))), '|'))) || ':' || toString(count()) FROM minimart.\`$1\`${2:+ $2}" </dev/null 2>&1
}
sig_all() { # sig_all physical|final|created -> one line per mirrored table
  # physical: raw rows of every table; final: FINAL for the incremental_updated tables (their window is re-sent, so
  # raw rows may repeat), raw for the others; created: only the tables whose raw rows must never change
  local t fin
  while IFS= read -r t; do
    fin=""
    if use_final "$t"; then [[ "$1" == created ]] && continue; [[ "$1" == final ]] && fin=FINAL; fi
    echo "$t=$(ch_sig "$t" $fin)"
  done <<<"$TABLES"
}
null_counts() { # null_counts pg|ch table -> NULL count per scalar column, one line
  local col kind exprs="" sep=""
  while IFS='|' read -r col kind; do
    [[ "$kind" == as || "$kind" == ai ]] && continue
    if [[ "$1" == pg ]]; then exprs="$exprs${sep}count(*) FILTER (WHERE \"$col\" IS NULL)"
    else exprs="$exprs${sep}countIf(isNull(\`$col\`))"; fi
    sep=", "
  done <<<"$(spec_of "$2")"
  if [[ "$1" == pg ]]; then psql -X -q -tA -F, -d "$PGDB" -c "SELECT $exprs FROM \"$2\"" </dev/null
  else CH -q "SELECT $exprs FROM minimart.\`$2\`${3:+ $3} FORMAT CSV" </dev/null 2>&1; fi
}
# INSERT ... SELECT statements the last run sent to Postgres, with the rows ClickHouse read: "table<TAB>read_rows"
insert_reads() { # insert_reads <server timestamp taken before the run>
  chq "SYSTEM FLUSH LOGS" >/dev/null
  chq "SELECT extract(query, '_src_([^\`]+)\`') AS t, max(read_rows) FROM system.query_log WHERE type = 'QueryFinish' AND event_time_microseconds >= parseDateTime64BestEffort('$1', 6) AND query LIKE 'INSERT INTO minimart.\`%' AND query LIKE '%FROM minimart.\`_src_%' GROUP BY t ORDER BY t FORMAT TSV"
}
reads_of() { printf '%s\n' "$1" | awk -F'\t' -v t="$2" '$1 == t { print $2 }'; }
no_leftovers() { check "$1: no _new_*/_src_* table left in ClickHouse" "0" "$(leftovers)"; }

echo "== setup =="
command -v psql >/dev/null || { echo "psql not found"; exit 1; }
echo "bash: $BASH_VERSION   Postgres: $(psql --version | awk '{print $3}')   ClickHouse binary: $MM_CH_BIN"
echo "scratch dir: $WORK"
mm_pg_setup yes || exit 1
mm_ch_start
echo "ClickHouse: $("$MM_CH_BIN" --version | head -1)"
check "scratch ClickHouse is up with a non-UTC server time zone" "$CH_TZ" "$(chq "SELECT timezone()")"
check "no minimart database yet" "0" "$(chq "SELECT count() FROM system.databases WHERE name = 'minimart'")"
check "stand-in has 12 base tables + 1 view + 1 materialized view" "12,1,1" \
  "$(PGS "SELECT count(*) FILTER (WHERE c.relkind = 'r') || ',' || count(*) FILTER (WHERE c.relkind = 'v') || ',' || count(*) FILTER (WHERE c.relkind = 'm') FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'public'")"

# ══════════════════════════════════════════════════════════════════════════════════════════════
sec "1. script basics"
sync_run -h;                 check "-h exits 0" 0 "$RC"
last_has 'minimart_sync.sh' && ok "-h prints the usage text" || bad "-h printed no usage"
sync_run --bogus;            check "unknown option exits 2" 2 "$RC"
sync_run --full extra;       check "extra argument after --full exits 2" 2 "$RC"
sync_run --init extra;       check "extra argument after --init exits 2" 2 "$RC"
sync_run --print a b;        check "two arguments after --print exit 2" 2 "$RC"
bash -n scripts/minimart_sync.sh && ok "bash -n scripts/minimart_sync.sh" || bad "bash -n scripts/minimart_sync.sh"
bash -n scripts/minimart_gen_schema.sh && ok "bash -n scripts/minimart_gen_schema.sh" || bad "bash -n scripts/minimart_gen_schema.sh"
bash "$GEN" -h >/dev/null 2>&1;      check "gen_schema -h exits 0" 0 "$?"
bash "$GEN" >/dev/null 2>&1;         check "gen_schema without arguments exits 2" 2 "$?"
bash "$GEN" --bogus >/dev/null 2>&1; check "gen_schema unknown mode exits 2" 2 "$?"
if command -v shellcheck >/dev/null; then
  if shellcheck -S warning scripts/minimart_sync.sh scripts/minimart_gen_schema.sh >"$OUT/shellcheck.txt" 2>&1; then ok "shellcheck clean"; else bad "shellcheck"; head -20 "$OUT/shellcheck.txt"; fi
else skip "shellcheck not installed on this machine"; fi
run;           check "sync before --init fails (exit 1)" 1 "$RC"
log_has "run: scripts/minimart_sync.sh --init" && ok "...and tells the operator to run --init" || bad "no --init hint in the log"
run --full;    check "--full before --init fails (exit 1)" 1 "$RC"
run --verify;  check "--verify before --init fails (exit 1)" 1 "$RC"
check "...and none of them created the minimart database" "0" "$(chq "SELECT count() FROM system.databases WHERE name = 'minimart'")"
MM_ENV=$ENV100 run --print;  check "--print before --init works (exit 0)" 0 "$RC"
last_has 'STRATEGY' && ok "...and lists the strategies" || bad "--print before --init prints no strategy table"
check "...and created nothing in ClickHouse" "0" "$(chq "SELECT count() FROM system.databases WHERE name = 'minimart'")"
run --grant-args; check "--grant-args exits 0 without ClickHouse state (no overrides file)" 0 "$RC"

# ══════════════════════════════════════════════════════════════════════════════════════════════
sec "2. --init: plan, strategies, --print, mirror column types"
MM_ENV=""
run --init;  check "--init with the default threshold exits 0" 0 "$RC"
check "default threshold (100000 rows): 12 tables planned, every one a snapshot" "12:12" \
  "$(chq "SELECT count() || ':' || countIf(strategy = 'snapshot') FROM minimart._plan WHERE $PLAN_Q")"
ALL_TABLES_CSV="Legacy Notes,categories,customers,empty_table,event_log,order_items,orders,product_prices,products,settings,stock_movements,user_sessions"
check "planned tables are exactly the 12 base tables" "$ALL_TABLES_CSV" \
  "$(chq "SELECT arrayStringConcat(arraySort(groupArray(table_name)), ',') FROM minimart._plan WHERE $PLAN_Q")"
check "mirror tables created in ClickHouse are exactly those 12 (+ 4 state tables)" "$ALL_TABLES_CSV|_plan,_plan_cols,_plan_current,_sync_state" \
  "$(chq "SELECT arrayStringConcat(arraySort(groupArrayIf(name, NOT startsWith(name, '_'))), ',') || '|' || arrayStringConcat(arraySort(groupArrayIf(name, startsWith(name, '_'))), ',') FROM system.tables WHERE database = 'minimart'")"
check "view v_order_totals, materialized view mv_product_sales and sequence invoice_no_seq are not mirrored" "0,0" \
  "$(chq "SELECT (SELECT count() FROM system.tables WHERE database = 'minimart' AND (name LIKE '%v_order_totals%' OR name LIKE '%mv_product_sales%' OR name LIKE '%invoice_no_seq%' OR name LIKE '%inner%')) || ',' || (SELECT count() FROM minimart._plan_cols WHERE table_name IN ('v_order_totals', 'mv_product_sales', 'invoice_no_seq'))")"
no_leftovers "after --init"
check "--init loaded no data and wrote no watermark" "0,0" "$(chq "SELECT (SELECT count() FROM minimart.products) || ',' || (SELECT count() FROM minimart._sync_state)")"

MM_ENV=$ENV100
run --init;  check "--init with MINIMART_SMALL_ROWS=100 exits 0" 0 "$RC"
log_has "OK: plan" && ok "...and logs the plan summary" || bad "no 'OK: plan' line in the log"
check "strategy per table by the documented rule (threshold 100)" \
  "Legacy Notes:snapshot,categories:snapshot,customers:incremental_updated,empty_table:snapshot,event_log:snapshot,order_items:incremental_created,orders:incremental_updated,product_prices:snapshot,products:incremental_updated,settings:snapshot,stock_movements:incremental_created,user_sessions:snapshot" \
  "$(plan_strats)"
check_match "reason: categories = small table"          '^small table \(5 rows < 100\)$' "$(plan_field categories reason)"
check_match "reason: empty_table = small table"         '^small table \(0 rows < 100\)$' "$(plan_field empty_table reason)"
check_match "reason: Legacy Notes = small table"        '^small table \(2 rows < 100\)$' "$(plan_field 'Legacy Notes' reason)"
check "reason: event_log = no primary key"              "no primary key" "$(plan_field event_log reason)"
check "reason: user_sessions = key is an excluded column" "primary key includes an excluded column" "$(plan_field user_sessions reason)"
check "reason: product_prices = no usable change column" "no usable change column" "$(plan_field product_prices reason)"
check "reason: products = primary key + updated_at"      "primary key + updated_at" "$(plan_field products reason)"
check "reason: order_items = primary key + append-only created_at" "primary key + append-only created_at" "$(plan_field order_items reason)"
check "change column of products/customers/orders = updated_at; order_items/stock_movements = created_at; snapshots none" \
  "updated_at,updated_at,updated_at,created_at,created_at,,," \
  "$(for t in products customers orders order_items stock_movements categories event_log; do printf '%s,' "$(plan_field $t change_col)"; done)"
check "primary keys (composite, key-less, uuid)" "['product_id','valid_from']|[]|['order_id']|['Note Id']" \
  "$(plan_field product_prices pk)|$(plan_field event_log pk)|$(plan_field orders pk)|$(plan_field 'Legacy Notes' pk)"
HASH1=$(plan_hashes); STRAT1=$(plan_strats)
run --init;  check "--init is idempotent (second run exits 0)" 0 "$RC"
check "...same plan hashes" "$HASH1" "$(plan_hashes)"
check "...same strategies" "$STRAT1" "$(plan_strats)"
check "...the live plan still has 12 tables" "12" "$(chq "SELECT count() FROM minimart._plan WHERE $PLAN_Q")"
no_leftovers "after the second --init"

echo "-- --print"
cp "$LOG" "$OUT/log_before_print"
BEFORE_STATE=$(state_rows); BEFORE_PLAN=$(chq "SELECT count() FROM minimart._plan")
run --print;  check "--print exits 0 after --init" 0 "$RC"
PRINT=$OUT/last.txt; cp "$PRINT" "$OUT/print_all.txt"
out_has "$PRINT" '^products +incremental_updated .*updated_at' && ok "--print shows strategy + change column of products" || bad "--print: no 'products incremental_updated ... updated_at' row"
out_has "$PRINT" '^products .*primary key \+ updated_at' && ok "--print shows the reason of products" || bad "--print: no reason for products"
out_has "$PRINT" '^event_log +snapshot .*no primary key' && ok "--print shows event_log: snapshot, no primary key" || bad "--print: no 'event_log snapshot ... no primary key' row"
out_has "$PRINT" '^Legacy_Notes +snapshot' && ok "--print lists the table with a space (shown with _)" || bad "--print: Legacy Notes row missing"
out_has "$PRINT" 'customers\.password_hash +\[sensitive name\]' && ok "--print lists the excluded sensitive column customers.password_hash" || bad "--print: customers.password_hash not listed as excluded"
out_has "$PRINT" 'products\.photo +\[binary \(bytea\)' && ok "--print lists products.photo as excluded (bytea) with its reason" || bad "--print: products.photo not listed with its reason"
out_has "$PRINT" 'user_sessions\.token' && ok "--print lists user_sessions.token as excluded" || bad "--print: user_sessions.token not listed"
out_has "$PRINT" 'EXCHANGE TABLES' && ok "--print shows the generated snapshot SQL (EXCHANGE TABLES)" || bad "--print: no EXCHANGE TABLES in the SQL"
out_has "$PRINT" 'minimart\._sync_state' && ok "--print shows the watermark write" || bad "--print: no _sync_state in the SQL"
check "--print leaves no unfilled plan-time placeholder" "0" "$(grep -c '@T@\|@COLS@\|@EXPRS@\|@SRC@\|@NEW@\|@ENGINE@\|@ORDER_BY@\|@DEST_COLS@\|@PK_COLS@\|@CHG@' "$PRINT")"
run --print products;  check "--print products exits 0" 0 "$RC"
last_has "generated SQL of table products" && ok "--print <table> shows that table's SQL" || bad "--print products: no SQL section"
last_has -- '-- --verify:' && last_has 'content hash|cityHash64' && ok "--print <table> also shows the verify SQL (with the content hash)" || bad "--print products: no verify SQL"
last_has 'WHERE \(s\.`updated_at` >' && ok "...and the pushed-down WHERE of the incremental statement" || bad "--print products: no incremental WHERE"
run --print "Legacy Notes";  check "--print \"Legacy Notes\" exits 0" 0 "$RC"
last_has 'Note Id' && ok "...and shows the quoted column names" || bad "--print Legacy Notes: no Note Id"
run --print no_such_table;  check "--print of an unknown table exits 1" 1 "$RC"
check "--print wrote nothing (state rows and plan rows unchanged)" "$BEFORE_STATE,$BEFORE_PLAN" "$(state_rows),$(chq "SELECT count() FROM minimart._plan")"

echo "-- excluded columns"
check "not mirrored, with a reason: exactly the 3 sensitive customers columns, products.photo and the user_sessions key" \
  "customers.api_token,customers.password_hash,customers.reset_otp,products.photo,user_sessions.token" \
  "$(chq "SELECT arrayStringConcat(arraySort(groupArray(concat(table_name, '.', col))), ',') FROM minimart._plan_cols WHERE $PLAN_Q AND NOT mirrored")"
check "reasons: sensitive name x4, binary x1" "sensitive name|sensitive name|sensitive name|binary (bytea); allow-column mirrors it as hex text|sensitive name" \
  "$(chq "SELECT arrayStringConcat(groupArray(reason), '|') FROM (SELECT reason FROM minimart._plan_cols WHERE $PLAN_Q AND NOT mirrored ORDER BY table_name, col)")"
check "no sensitive column is flagged readable by minimart_ro (grants file did its job)" "0" \
  "$(chq "SELECT count() FROM minimart._plan_cols WHERE $PLAN_Q AND sensitive AND readable")"

echo "-- mirror column types (documented mapping in the header of scripts/minimart_gen_schema.sh)"
EXPECT="categories|category_id|Int16
categories|name|String
categories|sort_order|Int32
settings|key|String
settings|value|Nullable(String)
products|product_id|Int64
products|public_id|UUID
products|sku|String
products|name|String
products|category_id|Nullable(Int16)
products|price|Decimal(12, 2)
products|weight_kg|Nullable(Float64)
products|rating|Nullable(Float32)
products|margin|Nullable(Float64)
products|active|Bool
products|tags|Array(Nullable(String))
products|dims_mm|Array(Nullable(Int32))
products|attrs|Nullable(String)
products|released_on|Nullable(Date32)
products|created_at|DateTime64(6, 'UTC')
products|updated_at|DateTime64(6, 'UTC')
product_prices|product_id|Int64
product_prices|valid_from|Date32
product_prices|price|Decimal(12, 4)
product_prices|note|Nullable(String)
customers|customer_id|Int32
customers|email|String
customers|full_name|String
customers|phone|Nullable(String)
customers|last_ip|Nullable(String)
customers|birth_date|Nullable(Date32)
customers|loyalty_pts|Int32
customers|signed_up_at|DateTime64(6, 'UTC')
customers|updated_at|DateTime64(6, 'UTC')
orders|order_id|UUID
orders|invoice_no|Int64
orders|customer_id|Int32
orders|status|LowCardinality(String)
orders|currency|String
orders|total|Decimal(14, 2)
orders|pickup_slot|Nullable(String)
orders|pickup_eta|Nullable(String)
orders|meta|Nullable(String)
orders|placed_at|DateTime64(6, 'UTC')
orders|delivered_at|Nullable(DateTime64(6, 'UTC'))
orders|updated_at|DateTime64(6, 'UTC')
order_items|order_item_id|Int64
order_items|order_id|UUID
order_items|product_id|Int64
order_items|qty|Int32
order_items|unit_price|Decimal(12, 2)
order_items|discount|Decimal(5, 4)
order_items|created_at|DateTime64(6, 'UTC')
stock_movements|movement_id|Int64
stock_movements|product_id|Int64
stock_movements|delta|Int32
stock_movements|reason|String
stock_movements|created_at|DateTime64(6, 'UTC')
event_log|ts|DateTime64(6, 'UTC')
event_log|kind|String
event_log|payload|Nullable(String)
event_log|amount|Nullable(Decimal(10, 3))
user_sessions|customer_id|Nullable(Int32)
user_sessions|expires_at|DateTime64(6, 'UTC')
empty_table|id|Int32
empty_table|label|Nullable(String)
Legacy Notes|Note Id|Int32
Legacy Notes|Note Text|Nullable(String)
Legacy Notes|Created|Nullable(DateTime64(6, 'UTC'))"
ACTUAL=$(chq "SELECT concat(table, '|', name, '|', type) FROM system.columns WHERE database = 'minimart' AND NOT startsWith(table, '_') ORDER BY table, position FORMAT TSVRaw")
for t in categories settings products product_prices customers orders order_items stock_movements event_log user_sessions empty_table "Legacy Notes"; do
  exp=$(printf '%s\n' "$EXPECT" | awk -F'|' -v t="$t" '$1 == t')
  act=$(printf '%s\n' "$ACTUAL" | awk -F'|' -v t="$t" '$1 == t')
  if [[ "$exp" == "$act" ]]; then ok "column names + ClickHouse types of $t match the documented mapping ($(printf '%s\n' "$exp" | wc -l | tr -d ' ') columns)"
  else bad "column types of $t differ from the documented mapping"; diff <(printf '%s\n' "$exp") <(printf '%s\n' "$act") | head -8; fi
done
check "stand-in has every type class: unconstrained numeric->Float64, numeric(p,s)->Decimal, timestamptz & timestamp->DateTime64(6,'UTC'), enum->LowCardinality(String), domain->Decimal(14, 2), bool->Bool, date->Date32" \
  "Nullable(Float64)|Decimal(12, 2)|DateTime64(6, 'UTC')|Nullable(DateTime64(6, 'UTC'))|LowCardinality(String)|Decimal(14, 2)|Bool|Nullable(Date32)" \
  "$(for p in products.weight_kg products.price products.created_at orders.delivered_at orders.status orders.total products.active products.released_on; do chq "SELECT type FROM system.columns WHERE database = 'minimart' AND table = '${p%%.*}' AND name = '${p##*.}' FORMAT TSVRaw"; done | paste -sd'|' -)"
check "jsonb/inet/time/interval -> Nullable(String)" "Nullable(String)|Nullable(String)|Nullable(String)|Nullable(String)" \
  "$(for p in products.attrs customers.last_ip orders.pickup_slot orders.pickup_eta; do chq "SELECT type FROM system.columns WHERE database = 'minimart' AND table = '${p%%.*}' AND name = '${p##*.}' FORMAT TSVRaw"; done | paste -sd'|' -)"

# ══════════════════════════════════════════════════════════════════════════════════════════════
sec "3. first sync (automatic full load) and byte-for-byte comparison"
T_FIRST=$(chq "SELECT toString(now64(6))")
run;  check "first sync exits 0" 0 "$RC"
check "...every table loaded in full because no state exists (12 log lines)" "12" "$(log_count 'no successful run of the current plan')"
last_log 1 | grep -q "OK in .*: 12 tables (12 loaded in full)" && ok "...final log line: OK, 12 tables loaded in full" || bad "first sync final log line: $(last_log 1)"
check "12 watermark rows, all mode full" "12:full" "$(chq "SELECT count() || ':' || arrayStringConcat(groupUniqArray(mode), ',') FROM minimart._sync_state")"
no_leftovers "after the first sync"
echo "-- engines and sorting keys of the loaded mirror tables"
check "engines after the first load: snapshot = MergeTree, incremental = ReplacingMergeTree" "MergeTree,MergeTree,MergeTree,MergeTree,MergeTree,MergeTree,MergeTree,ReplacingMergeTree,ReplacingMergeTree,ReplacingMergeTree,ReplacingMergeTree,ReplacingMergeTree" \
  "$(chq "SELECT arrayStringConcat(groupArray(engine), ',') FROM (SELECT engine FROM system.tables WHERE database = 'minimart' AND NOT startsWith(name, '_') ORDER BY if(name IN ('customers', 'order_items', 'orders', 'products', 'stock_movements'), 1, 0), name)")"
check "ReplacingMergeTree(updated_at) for updated tables, plain ReplacingMergeTree for append-only" "1,1,1,1,1" \
  "$(chq "SELECT (SELECT engine_full LIKE 'ReplacingMergeTree(updated_at)%' FROM system.tables WHERE database='minimart' AND name='products') || ',' || (SELECT engine_full LIKE 'ReplacingMergeTree(updated_at)%' FROM system.tables WHERE database='minimart' AND name='customers') || ',' || (SELECT engine_full LIKE 'ReplacingMergeTree(updated_at)%' FROM system.tables WHERE database='minimart' AND name='orders') || ',' || (SELECT engine_full LIKE 'ReplacingMergeTree ORDER BY%' FROM system.tables WHERE database='minimart' AND name='order_items') || ',' || (SELECT engine_full LIKE 'ReplacingMergeTree ORDER BY%' FROM system.tables WHERE database='minimart' AND name='stock_movements')")"
check "ORDER BY: key columns (products/product_prices/orders), tuple() for key-less event_log" "(product_id)|product_id, valid_from|(order_id)|" \
  "$(chq "SELECT (SELECT sorting_key FROM system.tables WHERE database='minimart' AND name='products') || '|' || (SELECT sorting_key FROM system.tables WHERE database='minimart' AND name='product_prices') || '|' || (SELECT sorting_key FROM system.tables WHERE database='minimart' AND name='orders') || '|' || (SELECT sorting_key FROM system.tables WHERE database='minimart' AND name='event_log')")"

compare_all "first sync:"
for t in products customers orders order_items stock_movements categories settings product_prices event_log user_sessions empty_table "Legacy Notes"; do
  exp=$(null_counts pg "$t"); act=$(null_counts ch "$t" | tr -d '"')
  check "NULL counts of every scalar column of $t equal Postgres" "$exp" "$act"
done
check "row counts: products 1000, order_items 4500, orders 1500, stock_movements 3000, event_log 2020, empty_table 0" "1000,4500,1500,3000,2020,0" \
  "$(ch_count products),$(ch_count order_items),$(ch_count orders),$(ch_count stock_movements),$(ch_count event_log),$(ch_count empty_table)"
check "event_log duplicate rows survive (no primary key): duplicate groups equal Postgres" \
  "$(PGS "SELECT count(*) FROM (SELECT 1 FROM event_log GROUP BY ts, kind, payload::text, amount HAVING count(*) > 1) d")" \
  "$(chq "SELECT count() FROM (SELECT 1 FROM minimart.event_log GROUP BY ts, kind, payload, amount HAVING count() > 1)")"
check "unconstrained numeric 123456789012345678901234567890.123456789 -> nearest double" "1" "$(chq "SELECT weight_kg = 1.2345678901234568e29 FROM minimart.products WHERE sku = 'SKU-00001'")"
check "tiny negative numeric -1e-18 -> -1e-18" "1" "$(chq "SELECT weight_kg = -1e-18 FROM minimart.products WHERE sku = 'SKU-00002'")"
check "numeric 0 is 0, not NULL" "0" "$(chq "SELECT toString(weight_kg) FROM minimart.products WHERE sku = 'SKU-00003'")"
check "numeric 0.000000123456789012345 survives as a double (same row count as in Postgres)" "$(PGS "SELECT count(*) FROM products WHERE weight_kg = 0.000000123456789012345")" "$(chq "SELECT count() FROM minimart.products WHERE weight_kg = 0.000000123456789012345")"
check "numeric(12,2) stays exact (Decimal, no float noise): price of SKU-00001" "$(PGS "SELECT price::text FROM products WHERE sku = 'SKU-00001'")" "$(chq "SELECT toString(price) FROM minimart.products WHERE sku = 'SKU-00001'")"
check "empty arrays stay empty, NULL arrays become []: count(empty tags)/count(empty dims_mm)" \
  "$(PGS "SELECT count(*) FILTER (WHERE tags = '{}') || ',' || count(*) FILTER (WHERE dims_mm IS NULL OR cardinality(dims_mm) = 0) FROM products")" \
  "$(chq "SELECT countIf(empty(tags)) || ',' || countIf(empty(dims_mm)) FROM minimart.products")"
check "a text value '' stays '' and NULL stays NULL (settings)" "1,1,1" \
  "$(chq "SELECT (SELECT count() FROM minimart.settings WHERE key = 'empty_value' AND value = '' AND value IS NOT NULL) || ',' || (SELECT count() FROM minimart.settings WHERE key = 'null_value' AND value IS NULL) || ',' || (SELECT count() FROM minimart.settings WHERE key = 'motd' AND position(value, char(10)) > 0 AND position(value, char(9)) > 0 AND position(value, '\\\\') > 0)")"
check "unicode / emoji / quotes in names survive (byte compare above); spot check 饼干 and 🍜" "1,1" \
  "$(chq "SELECT (SELECT count() > 0 FROM minimart.products WHERE position(name, '饼干') > 0) || ',' || (SELECT count() > 0 FROM minimart.products WHERE position(name, '🍜') > 0)")"
check "jsonb text form is byte for byte Postgres' (attrs of product 2)" "$(PGS "SELECT encode(convert_to(attrs::text, 'UTF8'), 'hex') FROM products WHERE product_id = 2")" \
  "$(chq "SELECT lower(hex(attrs)) FROM minimart.products WHERE product_id = 2")"
check "composite primary key table product_prices mirrored completely" "$(PGS "SELECT count(*) FROM product_prices")" "$(ch_count product_prices)"
check "table with spaces: \"Legacy Notes\" and its \"Note Id\" column mirrored under the same names" "2" "$(ch_count 'Legacy Notes')"
check "pg microseconds survive: timestamptz created_at of product 1 = .123456" "123456" "$(chq "SELECT toString(toUnixTimestamp64Micro(created_at) % 1000000) FROM minimart.products WHERE product_id = 1")"
check "control for the push-down test: the first (full) load read all 1000 rows of products from Postgres" "1000" \
  "$(reads_of "$(insert_reads "$T_FIRST")" products)"

echo "-- sensitive columns never reach ClickHouse"
check "no mirror table has a column named like password/hash/token/otp/secret/api_key/pin" "0" \
  "$(chq "SELECT count() FROM system.columns WHERE database = 'minimart' AND NOT startsWith(table, '_') AND match(lower(name), 'password|passwd|hash|token|secret|otp|api_key|(^|_)pin($|_)|salt')")"
SECRETS="'\$2a\$10\$','tok_','sess_','NEWSECRET'"
SECRET_HITS=0
for t in $(chq "SELECT name FROM system.tables WHERE database = 'minimart' ORDER BY name FORMAT TSVRaw" | tr ' ' '#'); do
  tt=$(printf '%s' "$t" | tr '#' ' ')
  n=$(chq "SELECT count() FROM minimart.\`$tt\` WHERE multiSearchAny(toString(tuple(*)), [$SECRETS])")
  [[ "$n" == 0 ]] || { SECRET_HITS=$((SECRET_HITS + 1)); echo "    secret-looking value in minimart.$tt: $n rows"; }
done
check "no secret value (bcrypt-looking hash, tok_*, sess_* tokens) occurs in any row of any minimart table (incl. plan tables)" "0" "$SECRET_HITS"
FIRST_HASH=$(PGS "SELECT password_hash FROM customers WHERE customer_id = 1"); FIRST_TOKEN=$(PGS "SELECT api_token FROM customers WHERE customer_id = 2"); FIRST_SESS=$(PGS "SELECT token FROM user_sessions WHERE customer_id = 6")
chq "SYSTEM FLUSH LOGS" >/dev/null
check "system.query_log text holds no secret value (hash, token, session token)" "0" \
  "$(chq "SELECT count() FROM system.query_log WHERE (position(query, '$FIRST_HASH') > 0 OR position(query, '$FIRST_TOKEN') > 0 OR position(query, '$FIRST_SESS') > 0 OR position(query, 'tok_NEWSECRET') > 0) AND position(query, 'system.query_log') = 0")"
check "...and the column-level grants in Postgres: mmc_ro_a cannot read password_hash/api_token/reset_otp/token" "false,false,false,false" \
  "$(PGS "SELECT has_column_privilege('$RO_ROLE', 'customers', 'password_hash', 'SELECT') || ',' || has_column_privilege('$RO_ROLE', 'customers', 'api_token', 'SELECT') || ',' || has_column_privilege('$RO_ROLE', 'customers', 'reset_otp', 'SELECT') || ',' || has_column_privilege('$RO_ROLE', 'user_sessions', 'token', 'SELECT')")"
check "...but can read the other columns (email, customer_id, expires_at, orders.status)" "true,true,true,true" \
  "$(PGS "SELECT has_column_privilege('$RO_ROLE', 'customers', 'email', 'SELECT') || ',' || has_column_privilege('$RO_ROLE', 'customers', 'customer_id', 'SELECT') || ',' || has_column_privilege('$RO_ROLE', 'user_sessions', 'expires_at', 'SELECT') || ',' || has_column_privilege('$RO_ROLE', 'orders', 'status', 'SELECT')")"
psql -X -q -tA -U "$RO_ROLE" -d "$PGDB" -c "SELECT password_hash FROM customers LIMIT 1" >"$OUT/ro_denied.txt" 2>&1
grep -q "permission denied" "$OUT/ro_denied.txt" && ok "...logged in as mmc_ro_a, SELECT password_hash is rejected by Postgres (permission denied)" || bad "mmc_ro_a could read password_hash: $(head -c 200 "$OUT/ro_denied.txt")"
psql -X -q -tA -U "$RO_ROLE" -d "$PGDB" -c "SELECT email FROM customers LIMIT 1" >"$OUT/ro_ok.txt" 2>&1
[[ -s "$OUT/ro_ok.txt" ]] && ! grep -q ERROR "$OUT/ro_ok.txt" && ok "...and SELECT email works" || bad "mmc_ro_a cannot select email: $(head -c 200 "$OUT/ro_ok.txt")"
psql -X -q -tA -U "$RO_ROLE" -d "$PGDB" -c "UPDATE categories SET name = name" >"$OUT/ro_write.txt" 2>&1
grep -qi "permission denied\|read-only" "$OUT/ro_write.txt" && ok "...and the role cannot write (UPDATE rejected)" || bad "mmc_ro_a could UPDATE: $(head -c 200 "$OUT/ro_write.txt")"

sec "4. time zone"
check "server time zone is Asia/Makassar (UTC+8), not UTC" "Asia/Makassar" "$(chq "SELECT timezone()")"
check "timestamptz instants equal the Postgres epochs (every created_at/placed_at/ts/updated_at compared above); spot: product 1" \
  "$(PGS "SELECT floor(extract(epoch from created_at) * 1000000)::bigint FROM products WHERE product_id = 1")" "$(chq "SELECT toUnixTimestamp64Micro(created_at) FROM minimart.products WHERE product_id = 1")"
check "DateTime64(6,'UTC') renders in UTC, not in the server zone (product 1: 2024-01-01 00:01:00.123456)" "2024-01-01 00:01:00.123456" "$(chq "SELECT toString(created_at) FROM minimart.products WHERE product_id = 1")"
check "naive timestamp keeps its wall clock, labelled UTC (customer 1 signed_up_at 2023-06-01 09:30:15.250)" "2023-06-01 09:30:15.250000" "$(chq "SELECT toString(signed_up_at) FROM minimart.customers WHERE customer_id = 1")"
PGSU "ALTER ROLE $RO_ROLE SET timezone = 'America/Los_Angeles'" >/dev/null
run --full;  check "full sync as a role WITHOUT the UTC pin (America/Los_Angeles) exits 0" 0 "$RC"
compare_table "unpinned role (full sync):" products
compare_table "unpinned role (full sync):" customers
compare_table "unpinned role (full sync):" orders
compare_table "unpinned role (full sync):" "Legacy Notes"
PGSU "ALTER ROLE $RO_ROLE SET timezone = 'UTC'" >/dev/null

echo "-- --init is idempotent and keeps the state"
HASH1=$(plan_hashes); S0=$(state_rows); SIG0=$(sig_all physical)
run --init;  check "--init after data was loaded exits 0" 0 "$RC"
check "...same plan hashes" "$HASH1" "$(plan_hashes)"
check "...watermark rows kept" "$S0" "$(state_rows)"
check "...mirror content untouched" "$SIG0" "$(sig_all physical)"
run;  check "the next sync exits 0" 0 "$RC"
last_log 1 | grep -q " 12 tables (0 loaded in full)" && ok "...and is incremental (no table reloaded in full, state was kept)" || bad "next sync after --init: $(last_log 1)"
run --verify;  check "--verify passes on a clean mirror (exit 0)" 0 "$RC"
sed -n '1,16p' "$OUT/last.txt" | cut -c1-150

# ══════════════════════════════════════════════════════════════════════════════════════════════
sec "5. mutations round 1A: updates, inserts, snapshot deletes, rows inside the overlap window"
S0=$(state_rows); WM0=$(wm_all)
PGF $T/t1_mutate1.sql && ok "t1_mutate1.sql applied to Postgres" || bad "t1_mutate1.sql failed"
sleep 1
run;  check "incremental run exits 0" 0 "$RC"
last_log 1 | grep -q "OK in .*: 12 tables (0 loaded in full)" && ok "...logged OK, no table loaded in full" || bad "final log line: $(last_log 1)"
check "...12 new watermark rows (one per table)" "12" "$(state_delta "$S0")"
check "...every watermark advanced" "12" "$(chq "SELECT count() FROM (SELECT table_name, max(synced_through) m FROM minimart._sync_state GROUP BY table_name) WHERE m > now64(3, 'UTC') - INTERVAL 10 MINUTE")"
no_leftovers "after the incremental run"
for t in categories settings product_prices empty_table "Legacy Notes" event_log user_sessions; do compare_table "snapshot table identical right after the run:" "$t"; done
for t in products customers orders; do compare_table "incremental_updated read with FINAL (updates, inserts, in-window rows):" "$t"; done
for t in order_items stock_movements; do compare_table "incremental_created, PHYSICAL rows (no FINAL, no duplicates):" "$t"; done
check "order_items: physical rows (no FINAL) = Postgres count" "$(PGS "SELECT count(*) FROM order_items")" "$(ch_count order_items)"
check "order_items: no key stored twice" "0" "$(chq "SELECT count() - uniqExact(order_item_id) FROM minimart.order_items")"
check "stock_movements: no key stored twice" "0" "$(chq "SELECT count() - uniqExact(movement_id) FROM minimart.stock_movements")"
check "the row with an OLD created_at (45 min, inside the overlap) arrived: SKU-NEW-03, order item 40 min old" "1,1" \
  "$(chq "SELECT (SELECT count() FROM minimart.products FINAL WHERE sku = 'SKU-NEW-03') || ',' || (SELECT count() FROM minimart.order_items WHERE order_id = 'bbbbbbbb-0000-4000-8000-000000000002')")"
check "a NULL <-> value change arrived: product 8 weight NULL, product 4 weight = -98765432109876543210.5" "1,1" \
  "$(chq "SELECT (SELECT weight_kg IS NULL FROM minimart.products FINAL WHERE product_id = 8) || ',' || (SELECT weight_kg = -98765432109876543210.5 FROM minimart.products FINAL WHERE product_id = 4)")"
check "snapshot propagated an UPDATE of the no-primary-key table event_log (99.999 x3) and its deletes" "$(PGS "SELECT count(*) FILTER (WHERE amount = 99.999) || ',' || count(*) FROM event_log")" \
  "$(chq "SELECT countIf(amount = toDecimal64(99.999, 3)) || ',' || count() FROM minimart.event_log")"
check "snapshot propagated deletes: settings.store_name, Legacy Notes 2, user_sessions of customers 1..5 are gone" "0,0,0" \
  "$(chq "SELECT (SELECT count() FROM minimart.settings WHERE key = 'store_name') || ',' || (SELECT count() FROM minimart.\`Legacy Notes\` WHERE \`Note Id\` = 2) || ',' || (SELECT count() FROM minimart.user_sessions WHERE customer_id IN (1,2,3,4,5))")"
check "snapshot table empty_table was loaded (2 rows after being empty)" "2" "$(ch_count empty_table)"
check "new secret values (tok_NEWSECRET_*, sess_NEWSECRET_*, NEWSECRETHASH) did not reach any column of any mirror table" "0" \
  "$(for t in customers user_sessions products orders; do chq "SELECT count() FROM minimart.\`$t\` WHERE position(toString(tuple(*)), 'NEWSECRET') > 0"; done | awk '{ n += $1 } END { print n + 0 }')"
run --verify;  check "--verify passes right after the sync (exit 0)" 0 "$RC"

sec "6. idempotence"
SIG_P=$(sig_all created); SIG_F=$(sig_all final); S0=$(state_rows)
sleep 1
run;  check "second incremental run with no change exits 0" 0 "$RC"
check "...physical rows of the snapshot and incremental_created tables identical (no duplicates were added)" "$SIG_P" "$(sig_all created)"
check "...FINAL content of the incremental_updated tables identical" "$SIG_F" "$(sig_all final)"
check "...watermark rows grew by one per table (12)" "12" "$(state_delta "$S0")"
no_leftovers "after the no-change run"
compare_all "after the no-change run:"
S0=$(state_rows)
run --full;  check "--full exits 0" 0 "$RC"
SIG_FULL1=$(sig_all physical)
check "...watermark rows grew by 12; every table logged as a full load" "12" "$(state_delta "$S0")"
no_leftovers "after --full"
run --full;  check "a repeated --full exits 0" 0 "$RC"
check "...and leaves identical physical content" "$SIG_FULL1" "$(sig_all physical)"
compare_all "after --full:"
SIG_F=$(sig_all final)
run;  check "incremental after --full exits 0" 0 "$RC"
check "...and keeps the content (FINAL signature identical)" "$SIG_F" "$(sig_all final)"

sec "7. push-down / efficiency (rows ClickHouse reads from Postgres)"
sleep 1
T0=$(chq "SELECT toString(now64(6))")
run;  check "no-change incremental run exits 0" 0 "$RC"
MIRROR_N="products=$(ch_count products) customers=$(ch_count customers) orders=$(ch_count orders) order_items=$(ch_count order_items) stock_movements=$(ch_count stock_movements)"
READS=$(insert_reads "$T0"); echo "$READS" | tr '\t' ' ' | paste -sd';' - | sed 's/^/    read_rows per INSERT..SELECT: /'
# the append-only statements also scan the mirror table once for the anti-join (read_rows counts that too): subtract it
for p in products:1003 customers:203 orders:1503 order_items:4504 stock_movements:3004; do
  t=${p%%:*}; size=${p##*:}; n=$(reads_of "$READS" "$t")
  case "$t" in order_items|stock_movements) [[ "$n" =~ ^[0-9]+$ ]] && n=$((n - $(ch_count "$t"))) ;; esac
  if [[ "$n" =~ ^[0-9]+$ ]] && [[ "$n" -le 60 ]]; then ok "incremental run on $t read $n rows from Postgres (table has $size): the WHERE is pushed down"
  else bad "incremental run on $t read [$n] rows from Postgres (table has $size): the window is not pushed down"; fi
done
for t in categories settings event_log user_sessions "Legacy Notes"; do
  n=$(reads_of "$READS" "$t"); check "snapshot table $t is read completely (control: read_rows = rows)" "$(PGS "SELECT count(*) FROM \"$t\"")" "$n"
done

# ══════════════════════════════════════════════════════════════════════════════════════════════
sec "5B. mutations round 1B: what an incremental run cannot see (documented), then --full"
N_DEL_ORD=$(PGS "SELECT count(*) FROM orders WHERE customer_id = 150")
N_DEL_ITEMS=$(PGS "SELECT count(*) FROM order_items WHERE order_item_id IN (10, 11, 12) OR product_id = 999 OR order_id IN (SELECT order_id FROM orders WHERE customer_id = 150)")
N_DEL_MOV=$(PGS "SELECT count(*) FROM stock_movements WHERE movement_id <= 5 OR product_id = 999")
PGF $T/t1_mutate2.sql && ok "t1_mutate2.sql applied (hard deletes in incremental tables, update of an append-only table, 5-hour-old 'late' rows)" || bad "t1_mutate2.sql failed"
sleep 1
run;  check "incremental run exits 0" 0 "$RC"
for t in categories settings product_prices empty_table "Legacy Notes" event_log user_sessions; do compare_table "snapshot table identical (empty_table is empty again):" "$t"; done
compare_diff products;       check "products: the deleted row is STILL in the mirror (hard delete not propagated), the late row is missing" "1,1" "$ONLY_CH,$ONLY_PG"
compare_diff customers;      check "customers: deleted row still there, late row missing" "1,1" "$ONLY_CH,$ONLY_PG"
compare_diff orders;         check "orders: the $N_DEL_ORD deleted orders still there, late row missing" "$N_DEL_ORD,1" "$ONLY_CH,$ONLY_PG"
compare_diff order_items;    check "order_items: $N_DEL_ITEMS deleted rows still there (+ old qty of the updated row); late row and the updated row missing/old" "$((N_DEL_ITEMS + 1)),2" "$ONLY_CH,$ONLY_PG"
compare_diff stock_movements; check "stock_movements: $N_DEL_MOV deleted rows still there; late row missing" "$N_DEL_MOV,1" "$ONLY_CH,$ONLY_PG"
check "the 5-hour-old late rows are NOT picked up by an incremental run (older than watermark - 60 min): documented" "0,0,0,0,0" \
  "$(chq "SELECT (SELECT count() FROM minimart.products FINAL WHERE sku = 'SKU-LATE-01') || ',' || (SELECT count() FROM minimart.customers FINAL WHERE email = 'late@example.com') || ',' || (SELECT count() FROM minimart.orders FINAL WHERE order_id = 'bbbbbbbb-0000-4000-8000-0000000000aa') || ',' || (SELECT count() FROM minimart.order_items WHERE order_id = 'bbbbbbbb-0000-4000-8000-0000000000aa') || ',' || (SELECT count() FROM minimart.stock_movements WHERE reason = 'late arrival')")"
check "UPDATE of an append-only (incremental_created) row does not propagate: qty of order item 20 differs" "1" \
  "$(chq "SELECT qty != $(PGS "SELECT qty FROM order_items WHERE order_item_id = 20") FROM minimart.order_items WHERE order_item_id = 20")"
run --verify;  check "--verify between a hard delete and --full reports a mismatch (exit 1)" 1 "$RC"
for t in orders order_items stock_movements; do
  out_has "$OUT/last.txt" "^$t +rows .*MISMATCH" && ok "...MISMATCH on rows of $t" || bad "--verify: no 'rows ... MISMATCH' line for $t"
done
for t in products customers; do   # one row deleted and one late row missing: the row count is equal, the content is not
  out_has "$OUT/last.txt" "^$t +(content hash|max\\(updated_at\\)|sum\\(.*) .*MISMATCH" && ok "...MISMATCH on the content of $t (equal row count, a deleted and a missing row)" || bad "--verify: no MISMATCH line for $t"
done
out_has "$OUT/last.txt" '^(categories|settings|event_log|empty_table) .*MISMATCH' && bad "--verify flags a snapshot table that is in sync" || ok "...no MISMATCH on the snapshot tables, which are in sync"
log_has "verify: " && ok "...and the log has a 'verify:' summary line" || bad "no verify line in the log"
run --full;  check "--full repairs: exits 0" 0 "$RC"
compare_all "after --full (hard deletes and late rows arrived):"
for t in products customers orders order_items stock_movements; do compare_diff "$t"; check "$t: nothing left on either side after --full" "0,0" "$ONLY_PG,$ONLY_CH"; done
run --verify;  check "--verify after --full passes (exit 0)" 0 "$RC"
run;  check "incremental run after --full exits 0" 0 "$RC"
compare_all "after the next incremental run:"

# ══════════════════════════════════════════════════════════════════════════════════════════════
sec "8. failure handling and state"
echo "-- 8a. SELECT revoked on orders while Postgres changes"
cat > "$WORK/t1_m3.sql" <<'EOF'
SET timezone = 'UTC';
UPDATE categories SET name = 'Drinks (changed in 8a)' WHERE category_id = 2;
UPDATE products SET name = 'changed in 8a' WHERE product_id = 30;
UPDATE orders SET status = 'paid', total = total + 1 WHERE order_id = '00000000-0000-4000-8000-000000000005';
INSERT INTO settings VALUES ('added_in_8a', 'x');
INSERT INTO stock_movements (product_id, delta, reason) VALUES (1, 1, 'added in 8a');
EOF
PGF "$WORK/t1_m3.sql" && ok "Postgres changed (categories, products, orders, settings, stock_movements)" || bad "8a mutation failed"
sleep 1
SIG_ORD=$(ch_sig orders); WM_B=$(wm_all); WM_ORD=$(wm_of orders); S0=$(state_rows)
PGS "REVOKE SELECT ON TABLE orders FROM $RO_ROLE" >/dev/null
run;  check "run with an unreadable table exits 1" 1 "$RC"
last_log 1 | grep -q "PARTIAL" && ok "...last log line is PARTIAL: $(last_log 1 | cut -c1-200)" || bad "no PARTIAL line, got: $(last_log 1)"
log_has "orders" && last_log 3 | grep -q "orders" && ok "...and names the failed table orders" || bad "orders is not named in the last log lines"
compare_table "other tables synced despite the failure:" categories
compare_table "other tables synced despite the failure:" products
compare_table "other tables synced despite the failure:" settings
compare_table "other tables synced despite the failure:" stock_movements
check "orders: live mirror table untouched" "$SIG_ORD" "$(ch_sig orders)"
check "orders: watermark did NOT advance" "$WM_ORD" "$(wm_of orders)"
check "the other 11 tables advanced (11 new watermark rows)" "11" "$(state_delta "$S0")"
no_leftovers "after the failed table"
mm_grants;  [[ -z "$(PGS "SELECT 1 WHERE NOT has_table_privilege('$RO_ROLE', 'orders', 'SELECT')")" ]] && ok "grants restored by db/minimart_ro_grants.sql (SELECT on orders again)" || bad "orders still not readable"
run;  check "after re-granting, the next run exits 0" 0 "$RC"
compare_table "...and repaired orders:" orders
check "...orders watermark advanced" "1" "$([[ "$(wm_of orders)" > "$WM_ORD" ]] && echo 1 || echo 0)"
no_leftovers "after the repair"

echo "-- 8b. failure inside the run (Postgres lock held; lock_timeout makes the SELECT fail)"
cat > "$WORK/t1_m4.sql" <<'EOF'
SET timezone = 'UTC';
UPDATE categories SET name = 'Snacks (changed in 8b)' WHERE category_id = 1;
UPDATE products SET name = 'changed in 8b' WHERE product_id = 31;
UPDATE orders SET status = 'shipped' WHERE order_id = '00000000-0000-4000-8000-000000000006';
UPDATE customers SET full_name = 'changed in 8b' WHERE customer_id = 11;
INSERT INTO stock_movements (product_id, delta, reason) VALUES (2, 2, 'added in 8b');
EOF
PGF "$WORK/t1_m4.sql" && ok "Postgres changed (categories, products, orders, customers, stock_movements)" || bad "8b mutation failed"
sleep 1
PGSU "ALTER ROLE $RO_ROLE SET lock_timeout = '1500ms'" >/dev/null
psql -X -q -d "$PGDB" -c "BEGIN; LOCK TABLE categories, orders IN ACCESS EXCLUSIVE MODE; SELECT pg_sleep(300);" >/dev/null 2>&1 &
LOCKER=$!
for _ in $(seq 1 50); do [[ "$(PGS "SELECT count(*) FROM pg_locks l JOIN pg_class c ON c.oid = l.relation WHERE l.mode = 'AccessExclusiveLock' AND l.granted AND c.relname IN ('categories', 'orders')")" == 2 ]] && break; sleep 0.1; done
check "a Postgres session holds ACCESS EXCLUSIVE locks on categories (snapshot) and orders (incremental)" "2" \
  "$(PGS "SELECT count(*) FROM pg_locks l JOIN pg_class c ON c.oid = l.relation WHERE l.mode = 'AccessExclusiveLock' AND l.granted AND c.relname IN ('categories', 'orders')")"
SIG_CAT=$(ch_sig categories); SIG_ORD=$(ch_sig orders); WM_CAT=$(wm_of categories); WM_ORD=$(wm_of orders); S0=$(state_rows)
run;  check "run that fails inside the table scripts exits 1" 1 "$RC"
last_log 1 | grep -q "PARTIAL: 10 tables ok, 2 failed" && ok "...PARTIAL: 10 ok, 2 failed" || bad "last log line: $(last_log 1)"
log_has "FAILED categories" && log_has "FAILED orders" && ok "...both failures are logged with their table name" || bad "FAILED lines missing in the log"
check "categories (snapshot): live table unchanged although a staging copy was started" "$SIG_CAT" "$(ch_sig categories)"
check "orders (incremental): live table unchanged" "$SIG_ORD" "$(ch_sig orders)"
check "both watermarks did NOT advance" "$WM_CAT|$WM_ORD" "$(wm_of categories)|$(wm_of orders)"
check "the other 10 tables advanced (10 new watermark rows)" "10" "$(state_delta "$S0")"
no_leftovers "after the failed tables (cleanup_table)"
compare_table "unlocked tables are current:" products
compare_table "unlocked tables are current:" customers
compare_table "unlocked tables are current:" stock_movements
kill "$LOCKER" 2>/dev/null; PGSU "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$PGDB' AND query LIKE '%pg_sleep(300)%' AND pid <> pg_backend_pid()" >/dev/null
wait "$LOCKER" 2>/dev/null
PGSU "ALTER ROLE $RO_ROLE RESET lock_timeout" >/dev/null
run;  check "after the lock is gone the next run exits 0" 0 "$RC"
compare_table "...and repaired:" categories
compare_table "...and repaired:" orders

echo "-- 8c. failure on the ClickHouse side (a column of a mirror table disappears)"
PGS "INSERT INTO stock_movements (product_id, delta, reason) VALUES (3, 3, 'added in 8c'); UPDATE products SET name = 'changed in 8c' WHERE product_id = 32" >/dev/null
sleep 1
chq "ALTER TABLE minimart.stock_movements DROP COLUMN reason" >/dev/null
SIG_MOV=$(ch_sig stock_movements); WM_MOV=$(wm_of stock_movements); S0=$(state_rows)
run;  check "run exits 1 when the mirror table was damaged" 1 "$RC"
last_log 1 | grep -q "PARTIAL: 11 tables ok, 1 failed" && ok "...PARTIAL: 11 ok, 1 failed" || bad "last log line: $(last_log 1)"
check "stock_movements watermark did not advance, others did" "$WM_MOV|11" "$(wm_of stock_movements)|$(state_delta "$S0")"
compare_table "other tables synced:" products
no_leftovers "after the ClickHouse-side failure"
run --full;  check "--full rebuilds the damaged table (exit 0)" 0 "$RC"
compare_all "after --full repaired the damaged mirror table:"
check "...and the column is back" "reason" "$(chq "SELECT name FROM system.columns WHERE database = 'minimart' AND table = 'stock_movements' AND name = 'reason'")"

# ══════════════════════════════════════════════════════════════════════════════════════════════
sec "9. --verify detects tampering"
run --verify;  check "clean mirror: --verify exits 0" 0 "$RC"
out_has "$OUT/last.txt" '^empty_table +rows +0 +0 +ok' && ok "...zero-row table empty_table verifies (rows 0 = 0)" || bad "--verify: no 'empty_table rows 0 0 ok' line"
out_has "$OUT/last.txt" 'customers\.password_hash' && out_has "$OUT/last.txt" 'user_sessions\.token' && ok "...and lists the sensitive columns that are NOT mirrored" || bad "--verify does not list the sensitive columns"
SIG_ALL=$(sig_all physical); S0=$(state_rows)
run --verify; check "--verify has no side effects: mirror content unchanged" "$SIG_ALL" "$(sig_all physical)"
check "...and no watermark written" "0" "$(state_delta "$S0")"
chq "ALTER TABLE minimart.products UPDATE price = price + 1 WHERE product_id = 5 SETTINGS mutations_sync = 2" >/dev/null
chq "ALTER TABLE minimart.products UPDATE margin = margin + 5e298 WHERE product_id = 5 SETTINGS mutations_sync = 2" >/dev/null     # SKU-NEW-01 has margin 1e300: +1 would vanish in the double sum
chq "ALTER TABLE minimart.products UPDATE active = NOT active WHERE product_id = 7 SETTINGS mutations_sync = 2" >/dev/null
chq "ALTER TABLE minimart.customers UPDATE full_name = 'tampered' WHERE customer_id = 9 SETTINGS mutations_sync = 2" >/dev/null
chq "ALTER TABLE minimart.orders UPDATE placed_at = toDateTime64('2099-01-01 00:00:00', 6, 'UTC') WHERE order_id = '00000000-0000-4000-8000-000000000009' SETTINGS mutations_sync = 2" >/dev/null
chq "ALTER TABLE minimart.categories DELETE WHERE category_id = 3 SETTINGS mutations_sync = 2" >/dev/null
chq "INSERT INTO minimart.stock_movements (movement_id, product_id, delta, reason, created_at) VALUES (99999999, 1, 0, 'ghost', toDateTime64('2020-01-01 00:00:00', 6, 'UTC'))" >/dev/null
chq "ALTER TABLE minimart.settings UPDATE value = 'tamper' WHERE key = 'currency' SETTINGS mutations_sync = 2" >/dev/null
chq "ALTER TABLE minimart.order_items UPDATE discount = discount + 0.0001 WHERE order_item_id = 1 SETTINGS mutations_sync = 2" >/dev/null
chq "ALTER TABLE minimart.event_log UPDATE payload = 'x' WHERE kind = 'new' SETTINGS mutations_sync = 2" >/dev/null
SIG_T=$(sig_all physical); S0=$(state_rows)
run --verify;  check "tampered mirror: --verify exits 1" 1 "$RC"
V=$OUT/last.txt
out_has "$V" '^products +sum\(price\) .*MISMATCH' && ok "numeric tamper (price + 1) -> MISMATCH on sum(price)" || bad "no MISMATCH on products sum(price)"
out_has "$V" '^products +sum\(margin\) .*MISMATCH' && ok "float tamper (margin + 5e298) -> MISMATCH on sum(margin)" || bad "no MISMATCH on products sum(margin)"
out_has "$V" '^products +count true\(active\) .*MISMATCH' && ok "bool tamper -> MISMATCH on count true(active)" || bad "no MISMATCH on products count true(active)"
out_has "$V" '^products +content hash .*MISMATCH' && ok "...products content hash MISMATCH too" || bad "no MISMATCH on products content hash"
out_has "$V" '^customers +content hash .*MISMATCH' && ok "string tamper (full_name) -> MISMATCH on content hash" || bad "no MISMATCH on customers content hash"
out_has "$V" '^customers +(rows|sum|max)\(?.*MISMATCH' && bad "customers: a metric other than the content hash is MISMATCH" || ok "...and ONLY on the content hash (rows/sums/max still agree)"
out_has "$V" '^orders +max\(placed_at\) .*MISMATCH' && ok "timestamp tamper (placed_at 2099) -> MISMATCH on max(placed_at)" || bad "no MISMATCH on orders max(placed_at)"
out_has "$V" '^categories +rows .*MISMATCH' && ok "deleted row in the mirror -> MISMATCH on rows (categories)" || bad "no MISMATCH on categories rows"
out_has "$V" '^stock_movements +rows .*MISMATCH' && ok "ghost row in the mirror -> MISMATCH on rows (stock_movements)" || bad "no MISMATCH on stock_movements rows"
out_has "$V" '^settings +content hash .*MISMATCH' && ok "snapshot string tamper -> MISMATCH on content hash (settings)" || bad "no MISMATCH on settings content hash"
out_has "$V" '^order_items +sum\(discount\) .*MISMATCH' && ok "decimal tamper (discount + 0.0001) -> MISMATCH on sum(discount)" || bad "no MISMATCH on order_items sum(discount)"
out_has "$V" '^event_log +content hash .*MISMATCH' && ok "no-primary-key table tamper -> MISMATCH on content hash (event_log)" || bad "no MISMATCH on event_log content hash"
out_has "$V" '^(product_prices|user_sessions|empty_table|Legacy) .*MISMATCH' && bad "--verify flags an untouched table" || ok "untouched tables (product_prices, user_sessions, empty_table, Legacy Notes) stay ok"
check "--verify did not change the tampered mirror (read-only) and wrote no watermark" "$SIG_T|0" "$(sig_all physical)|$(state_delta "$S0")"
log_has "verify: " && ok "the log has the verify summary" || bad "no verify line in the log"
run --full;  check "--full repairs the tampered mirror (exit 0)" 0 "$RC"
run --verify;  check "--verify passes again (exit 0)" 0 "$RC"

# ══════════════════════════════════════════════════════════════════════════════════════════════
sec "10. concurrency, secrets, timeouts, connections"
echo "-- lock"
S0=$(state_rows)
perl -MFcntl=:flock -e 'open(F, ">>", $ARGV[0]) or die "open: $!"; flock(F, LOCK_EX) or die "flock: $!"; sleep 120' "$LOCK" &
HOLDER=$!; sleep 1
run;          check "incremental run while another run holds the lock: skipped, exit 0" 0 "$RC"
log_has "another run holds the lock" && ok "...and logs it" || bad "no 'holds the lock' line"
run --full;   check "--full while locked: skipped, exit 0" 0 "$RC"
run --verify; check "--verify while locked exits 1" 1 "$RC"
run --init;   check "--init while locked exits 1" 1 "$RC"
run --print;  check "--print while locked still works (it writes nothing)" 0 "$RC"
check "nothing was written while locked" "0" "$(state_delta "$S0")"
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
run;  check "after the holder is gone the lock is free again (exit 0)" 0 "$RC"

echo "-- secrets and docker exec"
SECRET_PW=$(grep -c "not-the-real-one\|$RO_PW" "$LOG" "$ALL" "$WORK/shim.log" "$WORK/shim.log.login" | awk -F: '{ n += $2 } END { print n + 0 }')
check "neither the container's ClickHouse password nor the Postgres role password appears in the log, any output or the shim logs" "0" "$SECRET_PW"
check "the Postgres role password is not in any ClickHouse query text (system.query_log) either" "0" "$(chq "SYSTEM FLUSH LOGS" >/dev/null; chq "SELECT count() FROM system.query_log WHERE (position(query, '$RO_PW') > 0 OR position(query, 'not-the-real-one') > 0) AND position(query, 'system.query_log') = 0")"
check "...nor in system.processes" "0" "$(chq "SELECT count() FROM system.processes WHERE (position(query, '$RO_PW') > 0 OR position(query, 'not-the-real-one') > 0) AND position(query, 'system.processes') = 0")"
N_EXEC=$(wc -l < "$WORK/shim.log" | tr -d ' ')
check "every ClickHouse call went through 'docker exec ... procurement_clickhouse' ($N_EXEC calls, none to another container)" "$N_EXEC" "$(grep -Ec '^docker exec( -i)? procurement_clickhouse$' "$WORK/shim.log")"
check "...and every one reached clickhouse-client inside it with the container login (no direct client call)" "$N_EXEC" "$(grep -c '^login user=1 password=1$' "$WORK/shim.log.login")"
MM_ENV="$ENV100 MINIMART_CH_CONTAINER=no_such_container" run
check "MINIMART_CH_CONTAINER is honoured: a missing container makes the run fail (exit 1)" 1 "$RC"
log_has "no_such_container" && ok "...and the log says which container was not found" || bad "the log does not mention the configured container: $(last_log 1 | cut -c1-200)"
MM_ENV=$ENV100

echo "-- every ClickHouse call has a time limit (MINIMART_SYNC_TIMEOUT=2, client that hangs)"
mkdir -p "$WORK/slow"
printf '#!/bin/sh\nexec sleep 40\n' > "$WORK/slow/docker"; chmod +x "$WORK/slow/docker"
for m in "" --init --verify; do
  t0=$SECONDS
  env PATH="$WORK/slow:$REPO/$T/shim:$PATH" MINIMART_SYNC_LOG="$LOG" MINIMART_SYNC_LOCK="$LOCK" MINIMART_SYNC_TIMEOUT=2 bash "$SYNC" $m >"$OUT/slow.txt" 2>&1; rc=$?
  el=$((SECONDS - t0))
  if [[ "$rc" == 1 && "$el" -le 15 ]]; then ok "hanging client, run mode '${m:-incremental}': fails fast (exit 1 after ${el}s, limit 2s per call)"
  else bad "hanging client, run mode '${m:-incremental}': exit $rc after ${el}s (expected exit 1 within ~15s)"; fi
done
run;  check "...and the lock was released: a normal run works right after (exit 0)" 0 "$RC"

echo "-- Postgres connections of the read-only role (minimart_ro has CONNECTION LIMIT 20)"
: > "$OUT/conn.samples"
( while :; do psql -X -q -tA -d postgres -c "SELECT count(*) FROM pg_stat_activity WHERE usename = '$RO_ROLE'" >> "$OUT/conn.samples" 2>/dev/null; done ) &
SAMPLER=$!
run --init; RC_INIT=$RC
run --full; RC_FULL=$RC
run;        RC_INCR=$RC
run --verify; RC_VER=$RC
run --print;  RC_PRINT=$RC
kill "$SAMPLER" 2>/dev/null; wait "$SAMPLER" 2>/dev/null
MAXCONN=$(sort -n "$OUT/conn.samples" | tail -1); NSAMP=$(wc -l < "$OUT/conn.samples" | tr -d ' ')
check "init/full/incremental/verify/print all exit 0 while sampled" "0,0,0,0,0" "$RC_INIT,$RC_FULL,$RC_INCR,$RC_VER,$RC_PRINT"
echo "    $NSAMP samples of pg_stat_activity during init, full, incremental, verify, print: max $MAXCONN connections of $RO_ROLE"
if [[ "$MAXCONN" =~ ^[0-9]+$ && "$MAXCONN" -le 20 && "$NSAMP" -ge 20 ]]; then ok "connection count of the ro role never exceeded 20 (max $MAXCONN in $NSAMP samples)"; else bad "connection count max [$MAXCONN] in $NSAMP samples (limit 20)"; fi
sleep 1
CONN_AFTER=$(PGSU "SELECT count(*) FROM pg_stat_activity WHERE usename = '$RO_ROLE'")
if [[ "$CONN_AFTER" =~ ^[0-9]+$ && "$CONN_AFTER" -lt 5 ]]; then ok "after the runs the ro role has $CONN_AFTER connections (< 5)"; else bad "after the runs the ro role still has [$CONN_AFTER] connections"; fi
S_FREE=$(PGS "SELECT count(*) FROM pg_stat_activity WHERE usename = '$RO_ROLE' AND state = 'idle'")
echo "    (idle ro connections left open by ClickHouse: $S_FREE)"
compare_all "after the connection-sampled runs:"

# ══════════════════════════════════════════════════════════════════════════════════════════════
sec "11. schema drift"
S0=$(state_rows)
PGS "ALTER TABLE categories ADD COLUMN extra_note text; ALTER TABLE products ADD COLUMN access_token text; CREATE TABLE mmc_new_table (id int PRIMARY KEY, v text); INSERT INTO mmc_new_table VALUES (1, 'a')" >/dev/null
PGS "GRANT SELECT ON mmc_new_table TO $RO_ROLE" >/dev/null
run --verify;  check "--verify after new columns / a new table exits 1 (drift)" 1 "$RC"
V=$OUT/last.txt
out_has "$V" 'new_column +categories\.extra_note' && ok "...reports the new column categories.extra_note" || bad "--verify: new column categories.extra_note not reported"
out_has "$V" 'new_table +mmc_new_table' && ok "...reports the new table mmc_new_table" || bad "--verify: new table not reported"
out_has "$V" 'new_column +products\.access_token' && ok "...reports the new column products.access_token" || bad "--verify: new column products.access_token not reported"
run;  check "a sync with drift (only additions) still runs and exits 0 or 1 without corrupting anything" 0 "$([[ $RC == 0 || $RC == 1 ]] && echo 0 || echo "$RC")"
compare_all "drift (new columns) does not corrupt the mirror:"
run --init;  check "--init adopts the drift (exit 0)" 0 "$RC"
check "...new table mirrored, new column categories.extra_note mirrored, products.access_token NOT mirrored (sensitive name)" "1,1,0" \
  "$(chq "SELECT (SELECT count() FROM system.tables WHERE database = 'minimart' AND name = 'mmc_new_table') || ',' || (SELECT count() FROM system.columns WHERE database = 'minimart' AND table = 'categories' AND name = 'extra_note') || ',' || (SELECT count() FROM system.columns WHERE database = 'minimart' AND table = 'products' AND name = 'access_token')")"
log_has "sensitive_readable" && ok "...and warns that the new sensitive-named column is readable by the ro role" || skip "no sensitive_readable warning in the log"
run;  check "sync after --init exits 0 (changed tables reloaded in full)" 0 "$RC"
PGS "UPDATE categories SET extra_note = 'hello' WHERE category_id = 1; UPDATE products SET access_token = 'tok_NEWSECRET_ZZZZ' WHERE product_id = 1" >/dev/null
sleep 1; run;  check "sync exits 0" 0 "$RC"
check "the new categories column carries data" "hello" "$(chq "SELECT extra_note FROM minimart.categories WHERE category_id = 1")"
check "the secret in the new column never reached ClickHouse" "0" "$(chq "SELECT count() FROM minimart.products FINAL WHERE position(toString(tuple(*)), 'NEWSECRET') > 0")"
PGS "ALTER TABLE categories DROP COLUMN extra_note" >/dev/null
S0=$(state_rows); SIG_C=$(ch_sig categories)
run;  check "a dropped Postgres column: run exits 1 (PARTIAL)" 1 "$RC"
last_log 1 | grep -q "PARTIAL" && ok "...PARTIAL logged" || bad "no PARTIAL line: $(last_log 1)"
log_has "SKIPPED categories" && ok "...categories is skipped, not synced with a wrong column list" || bad "no SKIPPED categories line"
check "...the skipped mirror table was left untouched, the other 12 advanced" "$SIG_C|12" "$(ch_sig categories)|$(state_delta "$S0")"
run --verify;  check "--verify reports dropped_column (exit 1)" 1 "$RC"
out_has "$OUT/last.txt" 'dropped_column +categories' && ok "...with the line dropped_column categories.extra_note" || bad "--verify: no dropped_column line"
run --init;  check "--init adopts the dropped column (exit 0)" 0 "$RC"
run;  check "sync exits 0 after the drift is adopted" 0 "$RC"
run --verify;  check "--verify passes after the drift was adopted (exit 0)" 0 "$RC"
PGS "DROP TABLE mmc_new_table" >/dev/null
run --verify;  check "--verify after a table disappeared in Postgres exits 1" 1 "$RC"
out_has "$OUT/last.txt" 'dropped_table +mmc_new_table' && ok "...reports dropped_table mmc_new_table" || bad "--verify: no dropped_table line"
run --init;  check "--init adopts it (exit 0)" 0 "$RC"
check "...the orphan mirror table minimart.mmc_new_table is kept (never dropped automatically)" "1" "$(chq "SELECT count() FROM system.tables WHERE database = 'minimart' AND name = 'mmc_new_table'")"
chq "DROP TABLE minimart.mmc_new_table" >/dev/null
PGS "ALTER TABLE products DROP COLUMN access_token" >/dev/null
run --init; run;  check "back to a clean state: sync exits 0" 0 "$RC"
run --verify;  check "--verify passes (exit 0)" 0 "$RC"

# ══════════════════════════════════════════════════════════════════════════════════════════════
sec "12. overrides file"
OVR=$WORK/overrides.conf
cat > "$OVR" <<'EOF'
# test overrides
exclude settings
snapshot orders
incremental product_prices valid_from created
exclude-column customers.phone
allow-column products.photo
string-column products.released_on
exclude "Legacy Notes"
EOF
MM_ENV="$ENV100 MINIMART_OVERRIDES=$OVR"
run --init;  check "--init with an overrides file exits 0" 0 "$RC"
check "exclude settings and \"Legacy Notes\": not in the plan, not mirrored" "0,0" \
  "$(chq "SELECT (SELECT count() FROM minimart._plan WHERE $PLAN_Q AND table_name IN ('settings', 'Legacy Notes')) || ',' || (SELECT count() FROM system.columns WHERE database = 'minimart' AND table IN ('settings', 'Legacy Notes') AND 0)")"
check "snapshot override orders -> snapshot; incremental override product_prices -> incremental_created on valid_from" "snapshot|incremental_created" "$(plan_field orders strategy)|$(plan_field product_prices strategy)"
check "exclude-column customers.phone: column not mirrored, reason recorded" "0|override: exclude-column" \
  "$(chq "SELECT count() FROM system.columns WHERE database = 'minimart' AND table = 'customers' AND name = 'phone'")|$(chq "SELECT reason FROM minimart._plan_cols WHERE $PLAN_Q AND table_name = 'customers' AND col = 'phone'")"
check "allow-column products.photo: mirrored as text" "Nullable(String)" "$(chq "SELECT type FROM system.columns WHERE database = 'minimart' AND table = 'products' AND name = 'photo'")"
check "string-column products.released_on: kept as text" "Nullable(String)" "$(chq "SELECT type FROM system.columns WHERE database = 'minimart' AND table = 'products' AND name = 'released_on'")"
run;  check "sync with overrides exits 0" 0 "$RC"
check "products.photo mirrored as hex text of the bytea (SKU-00007: 00000007)" "\\\\x00000007" "$(chq "SELECT photo FROM minimart.products FINAL WHERE sku = 'SKU-00007'")"
check "products.released_on keeps the Postgres text form (2020-01-02 style)" "$(PGS "SELECT released_on::text FROM products WHERE product_id = 1")" "$(chq "SELECT released_on FROM minimart.products FINAL WHERE product_id = 1")"
run --verify;  check "--verify with overrides passes (exit 0)" 0 "$RC"
check "--grant-args prints the exclude/allow columns for the grants file" "allow_cols=products.photo|deny_cols=customers.phone" "$(MM_ENV="MINIMART_OVERRIDES=$OVR" run --grant-args; paste -sd'|' "$OUT/last.txt")"
printf 'frobnicate settings\n' > "$WORK/bad.conf"
MM_ENV="$ENV100 MINIMART_OVERRIDES=$WORK/bad.conf" run --init;  check "an invalid overrides file makes --init fail (exit 1) and says which line" 1 "$RC"
log_has "frobnicate" && ok "...the log names the unknown directive" || bad "the log does not name the bad directive"
MM_ENV="$ENV100 MINIMART_OVERRIDES=$WORK/bad.conf" run;  check "an invalid overrides file does not stop the normal sync (exit 0, drift check warned)" 0 "$RC"
MM_ENV=$ENV100
run --init;  run;  check "back to no overrides: --init + sync exit 0" 0 "$RC"
compare_all "after removing the overrides:"

# ══════════════════════════════════════════════════════════════════════════════════════════════
sec "13. edge cases"
echo "-- nullable change columns"
PGS "ALTER TABLE order_items ALTER COLUMN created_at DROP NOT NULL; ALTER TABLE products ALTER COLUMN updated_at DROP NOT NULL" >/dev/null
run --init;  check "--init after the change columns became nullable exits 0" 0 "$RC"
run;  check "full reload under the new plan exits 0" 0 "$RC"
PGS "INSERT INTO order_items (order_id, product_id, qty, unit_price, created_at) VALUES ('bbbbbbbb-0000-4000-8000-000000000001', 6, 1, 1, NULL); INSERT INTO products (sku, name, price, updated_at) VALUES ('SKU-NULLUPD', 'null updated_at', 1, NULL)" >/dev/null
run;  check "incremental run with a NULL change-column value exits 0" 0 "$RC"
run;  run;  check "...and two more runs exit 0" 0 "$RC"
check "append-only table: a row whose created_at IS NULL is stored exactly once physically (not re-sent every run)" "1" \
  "$(chq "SELECT count() FROM minimart.order_items WHERE created_at IS NULL")"
check "incremental_updated table: the NULL updated_at row reads back once with FINAL" "1" "$(chq "SELECT count() FROM minimart.products FINAL WHERE sku = 'SKU-NULLUPD'")"
compare_table "nullable change columns:" products
compare_table "nullable change columns:" order_items

echo "-- special float values, a table whose schema is odd"
PGS "INSERT INTO products (sku, name, price, margin, rating) VALUES ('SKU-INF', 'infinity', 1, 'Infinity'::float8, '-Infinity'::real), ('SKU-NAN', 'nan', 1, 'NaN'::float8, 'NaN'::real)" >/dev/null
run;  check "a run with Infinity / NaN floats exits 0" 0 "$RC"
check "Infinity and NaN arrive as inf / nan" "inf,-inf|nan,nan" \
  "$(chq "SELECT (SELECT toString(margin) || ',' || toString(rating) FROM minimart.products FINAL WHERE sku = 'SKU-INF') || '|' || (SELECT toString(margin) || ',' || toString(rating) FROM minimart.products FINAL WHERE sku = 'SKU-NAN')")"
run --verify;  check "--verify tolerates Infinity / NaN in a float column (exit 0)" 0 "$RC"

mm_summary
