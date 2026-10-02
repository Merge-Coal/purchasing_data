#!/usr/bin/env bash
# Test of db/minimart_ro_grants.sql against the local Homebrew Postgres, using the stand-in
# minimart schema (test/minimart/stand_in_schema.sql + stand_in_seed.sql).
#
#   bash test/minimart/ch/run_grants_test.sh
#
# It creates (and at the end drops, unless MMG_TEST_KEEP=1) ONLY the database mmg_test and the
# role mmg_ro. It never runs the grants file with its default dbname/ro_role and never touches
# any other database or role (the cluster is shared with other work, including roles named
# minimart_*). Needs a superuser connection (PGHOST defaults to /tmp, current OS user).
set -uo pipefail

cd "$(dirname "$0")/../../.."
REPO=$PWD
GRANTS="$REPO/db/minimart_ro_grants.sql"
DB=mmg_test
RO=mmg_ro
export PGHOST=${PGHOST:-/tmp}
unset PGPASSWORD PGDATABASE PGUSER
WORK=$(mktemp -d "${TMPDIR:-/tmp}/mmg_grants_test.XXXXXX")

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  PASS  $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL  $1"; }
check() { # check "description" expected actual
  if [[ "$3" == "$2" ]]; then ok "$1"; else bad "$1 — expected [$2] got [$3]"; fi
}

PGT()  { psql -X -q -tA -v ON_ERROR_STOP=1 -d "$DB" -c "$1"; }          # query inside mmg_test
PGSU() { psql -X -q -tA -v ON_ERROR_STOP=1 -d postgres -c "$1"; }       # cluster-level query
PGF()  { psql -X -q -v ON_ERROR_STOP=1 -d "$DB" -f "$1" >/dev/null; }

# run_grants [extra psql args...] -> RC, output in $WORK/out.txt (unaligned, -A, so it can be parsed)
run_grants() {
  psql -X -A -d postgres -v ro_role="$RO" -v dbname="$DB" "$@" -f "$GRANTS" >"$WORK/out.txt" 2>&1; RC=$?
}
show_out() { sed 's/^/      | /' "$WORK/out.txt"; }

can_t() { PGT "SELECT has_table_privilege('$RO', '$1', 'SELECT')"; }                    # table-level SELECT
can_c() { PGT "SELECT has_column_privilege('$RO', '$1'::regclass, '$2', 'SELECT')"; }   # SELECT on a column (any way)
yn()    { [[ "$1" == t ]] && echo yes || echo no; }

# Everything ACL-related in mmg_test, human-diffable (grantee names, not oids).
acl_dump() {
  PGT "
  SELECT 'db '||datname||' '||coalesce(datacl::text,'') FROM pg_database WHERE datname = current_database()
  UNION ALL SELECT 'nsp '||nspname||' '||coalesce(nspacl::text,'') FROM pg_namespace
             WHERE nspname NOT LIKE 'pg\\_%' AND nspname <> 'information_schema'
  UNION ALL SELECT 'rel '||n.nspname||'.'||c.relname||' '||CASE WHEN x.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(x.grantee) END||' '||x.privilege_type||' '||x.is_grantable
             FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace CROSS JOIN LATERAL aclexplode(c.relacl) x
             WHERE n.nspname NOT IN ('pg_catalog','information_schema') AND n.nspname !~ '^pg_toast'
  UNION ALL SELECT 'col '||n.nspname||'.'||c.relname||'.'||a.attname||' '||CASE WHEN x.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(x.grantee) END||' '||x.privilege_type
             FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid JOIN pg_namespace n ON n.oid = c.relnamespace
             CROSS JOIN LATERAL aclexplode(a.attacl) x
             WHERE n.nspname NOT IN ('pg_catalog','information_schema') AND n.nspname !~ '^pg_toast'
  UNION ALL SELECT 'fn '||p.oid::regprocedure::text||' '||coalesce(p.proacl::text,'') FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
             WHERE n.nspname NOT IN ('pg_catalog','information_schema')
  ORDER BY 1"
}
# Roles, memberships, owners, default ACLs and data: things the grants file must never change.
other_dump() {
  { PGSU "SELECT r::text FROM pg_roles r ORDER BY rolname"
    PGSU "SELECT roleid::regrole||' '||member::regrole||' '||grantor::regrole FROM pg_auth_members ORDER BY 1"
    PGT "SELECT 'owner '||c.relname||' '||pg_get_userbyid(c.relowner) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'public' ORDER BY 1"
    PGT "SELECT 'defacl '||defaclrole||' '||defaclacl::text FROM pg_default_acl ORDER BY 1"
    PGT "SELECT 'rows customers='||(SELECT count(*) FROM customers)||' products='||(SELECT count(*) FROM products)"
    PGT "SELECT 'cols '||c.relname||' '||count(*) FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname='public' AND c.relkind IN ('r','p') AND a.attnum > 0 AND NOT a.attisdropped GROUP BY c.relname ORDER BY 1"
  }
}

drop_all() {
  # Our own database first (DROP OWNED also removes the role's grants on shared objects of this db), then the role.
  if [[ -n $(PGSU "SELECT 1 FROM pg_database WHERE datname = '$DB'" 2>/dev/null) ]]; then
    PGT "DROP OWNED BY $RO" >/dev/null 2>&1
    PGSU "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$DB' AND pid <> pg_backend_pid()" >/dev/null 2>&1
    PGSU "DROP DATABASE IF EXISTS $DB" >/dev/null 2>&1
  fi
  PGSU "DROP ROLE IF EXISTS $RO" >/dev/null 2>&1
}
cleanup() {
  if [[ "${MMG_TEST_KEEP:-0}" != 1 ]]; then drop_all; rm -rf "$WORK"; else echo "(MMG_TEST_KEEP=1: database $DB, role $RO and $WORK kept)"; fi
}
trap cleanup EXIT

echo "== setup =="
drop_all
if [[ -n $(PGSU "SELECT 1 FROM pg_roles WHERE rolname = '$RO'") ]]; then
  echo "cannot drop leftover role $RO (it holds privileges elsewhere?)"; exit 2
fi
PGSU "CREATE DATABASE $DB" >/dev/null || { echo "cannot create $DB"; exit 2; }
PGF test/minimart/stand_in_schema.sql || { echo "schema load failed"; exit 2; }
PGF test/minimart/stand_in_seed.sql   || { echo "seed load failed"; exit 2; }
PGSU "CREATE ROLE $RO NOLOGIN" >/dev/null

# ── Rule probe: one table, one column per name, expected sensitivity listed here ─────────────
#   name:yes|no
PROBE=(
  password:yes passwd:yes user_password:yes passphrase:yes client_secret:yes access_token:yes tokenValue:yes
  api_key:yes apiKey:yes "api key:yes" APIKEY:yes private_key:yes privateKey:yes
  card_number:yes cardNo:yes pincode:yes pin_code:yes user_pin:yes PIN:yes otp:yes otp_code:yes "Reset OTP:yes"
  pwd:yes salt:yes cvv:yes cvc:yes card:yes card_type:yes credentials:yes hashtag:yes tokenizer:yes
  shipping_address:no spinach:no discard:no pinned:no pinyin:no opinion:no cardinal:no salty:no
  saltine:no mapping:no footprint:no phone:no description:no unit_price:no checksum:no passenger:no
)
cols=""
for e in "${PROBE[@]}"; do cols+="\"${e%:*}\" integer, "; done
PGT "CREATE TABLE rule_probe (id integer, ${cols%, })" >/dev/null

# ── Pre-existing state the grants file must clean up ─────────────────────────────────────────
PGT "CREATE SCHEMA other_s; CREATE TABLE other_s.t (id int, v text); INSERT INTO other_s.t VALUES (1,'x')" >/dev/null
PGT "CREATE TABLE public.part_parent (id int, region text, note text) PARTITION BY LIST (region);
     CREATE TABLE public.part_child1 PARTITION OF public.part_parent FOR VALUES IN ('a');
     CREATE TABLE public.part_child2 PARTITION OF public.part_parent FOR VALUES IN ('b');
     INSERT INTO public.part_parent VALUES (1,'a','x'),(2,'b','y')" >/dev/null
PGT "CREATE TABLE public.public_probe (id int, v text); GRANT SELECT ON public_probe TO PUBLIC;
     CREATE TABLE public.all_secret (password text, api_token text)" >/dev/null
PGT "GRANT SELECT ON customers TO $RO;                     -- stale table-level grant on a table with secrets
     GRANT UPDATE ON products TO $RO;                      -- write privilege
     GRANT INSERT, DELETE, TRUNCATE ON event_log TO $RO;
     GRANT UPDATE (name) ON products TO $RO;               -- column-level write
     GRANT SELECT (token) ON user_sessions TO $RO;         -- column grant on a sensitive column
     GRANT SELECT ON v_order_totals, mv_product_sales TO $RO;
     GRANT USAGE ON SEQUENCE invoice_no_seq TO $RO;
     GRANT EXECUTE ON FUNCTION touch_updated_at() TO $RO;
     GRANT USAGE ON SCHEMA other_s TO $RO;
     GRANT SELECT ON other_s.t TO $RO;
     GRANT SELECT ON part_child1 TO $RO;
     GRANT SELECT (id) ON rule_probe TO $RO;
     GRANT SELECT (password) ON rule_probe TO $RO" >/dev/null

echo "== missing database / role / bad role name: nothing is created =="
ROLES_BEFORE=$(PGSU "SELECT string_agg(rolname, ',' ORDER BY rolname) FROM pg_roles")
DBS_BEFORE=$(PGSU "SELECT string_agg(datname, ',' ORDER BY datname) FROM pg_database")
run_grants -v dbname=mmg_no_such_db
[[ $RC -ne 0 ]] && ok "missing database: non-zero exit (rc=$RC)" || bad "missing database: exit 0"
grep -q 'database does not exist' "$WORK/out.txt" && ok "missing database: clear message" || { bad "missing database: message"; show_out; }
run_grants -v ro_role=mmg_no_such_role
[[ $RC -ne 0 ]] && ok "missing role: non-zero exit (rc=$RC)" || bad "missing role: exit 0"
grep -q 'role does not exist' "$WORK/out.txt" && ok "missing role: clear message" || { bad "missing role: message"; show_out; }
for badname in 'MixedCase' 'mmg_ro; DROP TABLE customers' 'pg_read_all_data' 'mmg ro' '"mmg_ro"' ''; do
  run_grants -v "ro_role=$badname"
  [[ $RC -ne 0 ]] && grep -q 'ro_role must be a plain' "$WORK/out.txt" && ok "invalid ro_role [$badname] rejected" || { bad "invalid ro_role [$badname] not rejected (rc=$RC)"; show_out; }
done
check "no role created by the failed runs" "$ROLES_BEFORE" "$(PGSU "SELECT string_agg(rolname, ',' ORDER BY rolname) FROM pg_roles")"
check "no database created by the failed runs" "$DBS_BEFORE" "$(PGSU "SELECT string_agg(datname, ',' ORDER BY datname) FROM pg_database")"
check "table customers still exists after the failed runs" "200" "$(PGT 'SELECT count(*) FROM customers')"

echo "== first run =="
PUBLIC_BEFORE=$(acl_dump | grep -E '^rel public\.public_probe PUBLIC ')
OTHER_BEFORE=$(other_dump)
run_grants
[[ $RC -eq 0 ]] && ok "first run exits 0" || { bad "first run exit $RC"; show_out; }
grep -q 'all hard checks passed' "$WORK/out.txt" && ok "run ends with 'all hard checks passed'" || { bad "no success line"; show_out; }

echo "== plain tables readable in full =="
for t in categories settings products product_prices orders order_items stock_movements event_log empty_table '"Legacy Notes"' public_probe part_parent; do
  check "table-level SELECT on $t" "t" "$(can_t "$t")"
done
for c in "products|product_id" "products|sku" "products|photo" "products|updated_at" "orders|order_id" "orders|meta" \
         "event_log|ts" "event_log|payload" "empty_table|id" '"Legacy Notes"|Note Id' '"Legacy Notes"|Note Text' '"Legacy Notes"|Created'; do
  tbl=${c%%|*}; col=${c#*|}; check "column $tbl.$col readable" t "$(can_c "$tbl" "$col")"
done

echo "== customers: secrets hidden, rest readable =="
check "customers: no table-level SELECT (stale grant revoked)" f "$(can_t customers)"
for c in password_hash api_token reset_otp; do check "customers.$c NOT readable" f "$(can_c customers $c)"; done
for c in customer_id email full_name phone last_ip birth_date loyalty_pts signed_up_at updated_at; do
  check "customers.$c readable" t "$(can_c customers $c)"
done
check "customers non-sensitive column count granted" 9 "$(PGT "SELECT count(*) FROM pg_attribute WHERE attrelid='customers'::regclass AND attnum>0 AND NOT attisdropped AND has_column_privilege('$RO', attrelid, attnum, 'SELECT')")"

echo "== user_sessions (sensitive primary key) =="
check "user_sessions.token NOT readable (column grant revoked)" f "$(can_c user_sessions token)"
check "user_sessions.customer_id readable" t "$(can_c user_sessions customer_id)"
check "user_sessions.expires_at readable" t "$(can_c user_sessions expires_at)"
check "user_sessions: no table-level SELECT" f "$(can_t user_sessions)"

echo "== views, other schemas, partition children, all-sensitive table =="
check "view v_order_totals not readable (direct grant revoked)" f "$(can_t v_order_totals)"
check "matview mv_product_sales not readable" f "$(can_t mv_product_sales)"
check "other_s.t not readable (direct grant revoked)" f "$(can_t other_s.t)"
check "partition child part_child1 not readable (direct grant revoked)" f "$(can_t part_child1)"
check "partition child part_child2 not readable" f "$(can_t part_child2)"
check "all_secret: nothing readable" f "$(PGT "SELECT has_table_privilege('$RO','all_secret','SELECT') OR has_any_column_privilege('$RO','all_secret','SELECT')")"
check "no direct grants left on sequence invoice_no_seq" 0 "$(PGT "SELECT count(*) FROM pg_class c, aclexplode(c.relacl) x WHERE c.relname='invoice_no_seq' AND x.grantee = '$RO'::regrole")"
check "no direct EXECUTE grant left on touch_updated_at()" 0 "$(PGT "SELECT count(*) FROM pg_proc p, aclexplode(p.proacl) x WHERE p.proname='touch_updated_at' AND x.grantee = '$RO'::regrole")"
check "role has CONNECT and USAGE on public" "true|true" "$(PGT "SELECT has_database_privilege('$RO','$DB','CONNECT')||'|'||has_schema_privilege('$RO','public','USAGE')")"
check "PUBLIC's CONNECT on the database not revoked" t "$(PGT "SELECT datacl::text ~ '(^\\{|,)=Tc/' FROM pg_database WHERE datname = '$DB'")"
grep -q 'other_s.t' "$WORK/out.txt" && ok "output reports the table in another schema" || bad "other schema table not reported"
grep -q 'v_order_totals' "$WORK/out.txt" && ok "output reports the views" || bad "views not reported"
grep -q 'part_child1' "$WORK/out.txt" && ok "output reports the partition children" || bad "partition children not reported"

echo "== role never has a write privilege =="
check "no write privilege on any table/column (INSERT/UPDATE/DELETE/TRUNCATE/REFERENCES/TRIGGER)" 0 "$(PGT "
  SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace, unnest(ARRAY['INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER']) p
   WHERE c.relkind IN ('r','p','v','m','f') AND n.nspname NOT IN ('pg_catalog','information_schema') AND n.nspname !~ '^pg_toast'
     AND (has_table_privilege('$RO', c.oid, p) OR (p IN ('INSERT','UPDATE','REFERENCES') AND has_any_column_privilege('$RO', c.oid, p)))")"
check "old write privileges gone from products/event_log" 0 "$(PGT "SELECT count(*) FROM pg_class c, aclexplode(c.relacl) x WHERE c.relname IN ('products','event_log') AND x.grantee='$RO'::regrole AND x.privilege_type <> 'SELECT'")"
check "no non-SELECT column privilege left" 0 "$(PGT "SELECT count(*) FROM pg_attribute a, aclexplode(a.attacl) x WHERE x.grantee='$RO'::regrole AND x.privilege_type <> 'SELECT'")"

echo "== PUBLIC, other roles and structure untouched =="
check "PUBLIC SELECT entry on public_probe unchanged" "$PUBLIC_BEFORE" "$(acl_dump | grep -E '^rel public\.public_probe PUBLIC ')"
[[ -n "$PUBLIC_BEFORE" ]] && ok "(sanity) the PUBLIC entry exists" || bad "(sanity) PUBLIC entry missing"
check "no PUBLIC-grantee entry created on customers" 0 "$(acl_dump | grep -c '^rel public\.customers PUBLIC ')"
OTHER_AFTER=$(other_dump)
if [[ "$OTHER_BEFORE" == "$OTHER_AFTER" ]]; then ok "roles, memberships, owners, default ACLs, row counts, column counts unchanged"
else bad "something outside the grants changed"; diff <(echo "$OTHER_BEFORE") <(echo "$OTHER_AFTER") | head -20; fi
check "no default privileges exist" 0 "$(PGT 'SELECT count(*) FROM pg_default_acl')"

echo "== output =="
SENS_LIST=$(awk '/^== minimart_ro grants: sensitive columns EXCLUDED/{f=1;next} f&&/^$/{exit} f&&/^table.column\|/{next} f{print}' "$WORK/out.txt" | grep -v '^(' | cut -d'|' -f1)
for want in customers.password_hash customers.api_token customers.reset_otp user_sessions.token all_secret.password rule_probe.password; do
  grep -qxF "$want" <<<"$SENS_LIST" && ok "excluded list shows $want" || { bad "excluded list misses $want"; }
done
if [[ "$SENS_LIST" == "$(LC_ALL=C sort <<<"$SENS_LIST")" ]]; then ok "excluded list is sorted (C collation)"; else bad "excluded list not sorted"; fi
grep -qE '^customers\|columns \(9 of 12\)\|password_hash, api_token, reset_otp\|ok$' "$WORK/out.txt" && ok "per-table row: customers|columns (9 of 12)|excluded|ok" || { bad "per-table customers row"; grep -n '^customers' "$WORK/out.txt"; }
grep -qE '^products\|table\|\|ok$' "$WORK/out.txt" && ok "per-table row: products|table" || bad "per-table products row"
grep -qE '^all_secret\|none\|password, api_token\|WARN$' "$WORK/out.txt" && ok "per-table row: all_secret|none" || bad "per-table all_secret row"
grep -qE '^role cannot write anything.*\|\(none\)\|\(none\)\|ok$' "$WORK/out.txt" && ok "global row: cannot write anything" || bad "global write row"
grep -qE '^role has no privilege on views.*\|ok$' "$WORK/out.txt" && ok "global row: no privilege on views" || bad "global views row"

echo "== rule table (rule_probe) =="
for e in "${PROBE[@]}"; do
  name=${e%:*}; want=${e#*:}
  got=$(PGT "SELECT has_column_privilege('$RO', 'rule_probe'::regclass, \$q\$$name\$q\$, 'SELECT')")
  if [[ $want == yes ]]; then check "rule_probe.$name sensitive (not readable)" f "$got"; else check "rule_probe.$name not sensitive (readable)" t "$got"; fi
done
check "rule_probe.id readable" t "$(can_c rule_probe id)"

echo "== idempotence =="
ACL1=$(acl_dump)
run_grants
[[ $RC -eq 0 ]] && ok "second run exits 0" || { bad "second run exit $RC"; show_out; }
ACL2=$(acl_dump)
if [[ "$ACL1" == "$ACL2" ]]; then ok "privileges identical after a second run ($(wc -l <<<"$ACL2" | tr -d ' ') entries)"; else bad "second run changed privileges"; diff <(echo "$ACL1") <(echo "$ACL2") | head; fi
run_grants
[[ $RC -eq 0 ]] && ok "third run exits 0" || bad "third run exit $RC"
check "privileges identical after a third run" "$ACL1" "$(acl_dump)"

echo "== convergence: new table =="
PGT "CREATE TABLE new_plain (id int, note text); CREATE TABLE new_sens (id int, password_hash text, name text, \"clientSecret\" text)" >/dev/null
check "new table not readable before the re-run (no default privileges)" f "$(can_t new_plain)"
run_grants; [[ $RC -eq 0 ]] && ok "run after CREATE TABLE exits 0" || { bad "exit $RC"; show_out; }
check "new_plain readable after re-run" t "$(can_t new_plain)"
check "new_sens.id readable" t "$(can_c new_sens id)"
check "new_sens.name readable" t "$(can_c new_sens name)"
check "new_sens.password_hash NOT readable" f "$(can_c new_sens password_hash)"
check "new_sens.clientSecret (camelCase) NOT readable" f "$(can_c new_sens clientSecret)"
check "new_sens: no table-level SELECT" f "$(can_t new_sens)"

echo "== convergence: new / dropped / renamed columns =="
PGT "ALTER TABLE products ADD COLUMN new_secret_key text, ADD COLUMN shipping_address text, ADD COLUMN \"apiKey\" text" >/dev/null
check "products: new column readable via table-level grant until the re-run (documented window)" t "$(can_c products new_secret_key)"
run_grants; [[ $RC -eq 0 ]] && ok "run after ADD COLUMN exits 0" || { bad "exit $RC"; show_out; }
check "products.new_secret_key NOT readable" f "$(can_c products new_secret_key)"
check "products.apiKey NOT readable" f "$(can_c products apiKey)"
check "products.shipping_address readable" t "$(can_c products shipping_address)"
check "products: table-level SELECT replaced by columns" f "$(can_t products)"
check "products.sku / photo still readable" "t|t" "$(can_c products sku)|$(can_c products photo)"
PGT "ALTER TABLE products DROP COLUMN margin" >/dev/null
run_grants; [[ $RC -eq 0 ]] && ok "run after DROP COLUMN exits 0" || { bad "exit $RC"; show_out; }
check "products.price still readable after dropping margin" t "$(can_c products price)"
grep -q 'margin' "$WORK/out.txt" && bad "dropped column still mentioned" || ok "dropped column not mentioned"
PGT "ALTER TABLE customers RENAME COLUMN loyalty_pts TO loyalty_token" >/dev/null
run_grants; [[ $RC -eq 0 ]] && ok "run after RENAME to a sensitive name exits 0" || { bad "exit $RC"; show_out; }
check "renamed customers.loyalty_token now NOT readable (stale column grant revoked)" f "$(can_c customers loyalty_token)"
PGT "ALTER TABLE customers RENAME COLUMN loyalty_token TO loyalty_pts" >/dev/null
run_grants
check "renamed back: customers.loyalty_pts readable again" t "$(can_c customers loyalty_pts)"
PGT "DROP TABLE new_plain" >/dev/null
run_grants; [[ $RC -eq 0 ]] && ok "run after DROP TABLE exits 0" || { bad "exit $RC"; show_out; }

echo "== overrides =="
ACL_PRE=$(acl_dump)
run_grants -v allow_cols=customers.reset_otp
[[ $RC -eq 0 ]] && ok "allow_cols run exits 0" || { bad "exit $RC"; show_out; }
check "allow_cols: customers.reset_otp readable" t "$(can_c customers reset_otp)"
check "allow_cols: customers.password_hash still NOT readable" f "$(can_c customers password_hash)"
check "allow_cols: customers.api_token still NOT readable" f "$(can_c customers api_token)"
grep -q 'opened by allow_cols.*customers.reset_otp' "$WORK/out.txt" && ok "allow_cols shown as WARN row" || bad "allow_cols not reported"
run_grants -v allow_cols=customers.reset_otp,customers.api_token -v deny_cols=customers.phone
[[ $RC -eq 0 ]] && ok "allow+deny run exits 0" || { bad "exit $RC"; show_out; }
check "deny_cols: customers.phone NOT readable" f "$(can_c customers phone)"
check "allow_cols (second entry): customers.api_token readable" t "$(can_c customers api_token)"
check "customers.email still readable" t "$(can_c customers email)"
run_grants -v deny_cols=customers.password_hash -v allow_cols=customers.password_hash
check "deny_cols wins over allow_cols" f "$(can_c customers password_hash)"
run_grants -v 'deny_cols=Legacy Notes.Note Text'
[[ $RC -eq 0 ]] && ok "deny_cols with spaces exits 0" || { bad "exit $RC"; show_out; }
check "deny_cols 'Legacy Notes.Note Text' NOT readable" f "$(can_c '"Legacy Notes"' 'Note Text')"
check "'Legacy Notes'.\"Note Id\" readable" t "$(can_c '"Legacy Notes"' 'Note Id')"
run_grants -v deny_cols=customers.no_such_col
grep -q "deny_cols entry 'customers.no_such_col' matches no column" "$WORK/out.txt" && ok "unmatched override entry is warned about" || bad "unmatched entry not warned"
run_grants
[[ $RC -eq 0 ]] && ok "run without overrides exits 0" || { bad "exit $RC"; show_out; }
check "overrides not remembered: customers.reset_otp NOT readable again" f "$(can_c customers reset_otp)"
check "overrides not remembered: customers.api_token NOT readable again" f "$(can_c customers api_token)"
check "overrides not remembered: customers.phone readable again" t "$(can_c customers phone)"
check "overrides not remembered: Legacy Notes.Note Text readable again" t "$(can_c '"Legacy Notes"' 'Note Text')"
check "privileges back to the pre-override state" "$ACL_PRE" "$(acl_dump)"

echo "== hard failure: a PUBLIC grant exposes a sensitive column =="
PGT "CREATE TABLE leaky (id int, password_hash text); GRANT SELECT ON leaky TO PUBLIC" >/dev/null
run_grants
[[ $RC -ne 0 ]] && ok "sensitive column readable through PUBLIC: non-zero exit (rc=$RC)" || bad "leaky PUBLIC grant not detected"
grep -qE '^sensitive columns readable by the role\|\(none\)\|leaky.password_hash\|FAIL$' "$WORK/out.txt" && ok "FAIL row names leaky.password_hash" || { bad "FAIL row"; show_out; }
grep -q 'VERIFICATION FAILED' "$WORK/out.txt" && ok "failure message printed" || bad "no failure message"
PGT "DROP TABLE leaky" >/dev/null
run_grants
[[ $RC -eq 0 ]] && ok "after removing the leak: exit 0 again" || { bad "exit $RC"; show_out; }

echo "== final state =="
check "customers: still no table-level SELECT" f "$(can_t customers)"
check "role cannot INSERT into categories" f "$(PGT "SELECT has_table_privilege('$RO','categories','INSERT')")"
check "role is NOLOGIN and not superuser (attributes unchanged)" "false|false" "$(PGSU "SELECT rolcanlogin||'|'||rolsuper FROM pg_roles WHERE rolname='$RO'")"

echo
echo "== result: $PASS passed, $FAIL failed =="
[[ $FAIL -eq 0 ]] || exit 1
