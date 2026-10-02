#!/usr/bin/env bash
# End-to-end test of the minimart migration tooling:
#   scripts/minimart_migrate.sh  db/minimart_setup.sql      (happy path + guards)
# See test/minimart/migrate/lib.sh for the simulated world (two real local Postgres clusters, a `docker`
# wrapper so the production scripts run unmodified). Sibling runners: run_failure_test.sh, run_backup_test.sh.
#
#   bash test/minimart/migrate/run_migrate_test.sh
set -uo pipefail
OLD_PORT=${OLD_PORT:-55501}
NEW_PORT=${NEW_PORT:-55502}
source "$(dirname "$0")/lib.sh"

echo "Postgres old: $($PG14/postgres --version)   new: $($PG15/postgres --version)   bash $BASH_VERSION"
echo "scratch dir: $WORK"
world_up

# ───────────────────────────────────────────────────────────────────────────
section "guards before db/minimart_setup.sql has been run"
mig --rehearse
check "rehearse without roles: exit 3" 3 "$RC"
has "  says to run db/minimart_setup.sql" "db/minimart_setup.sql" "$OUT"
check "  nothing created on the new server" "0" "$(NPG -c "select count(*) from pg_database where datname like 'minimart%'")"
mig --cutover
check "cutover without roles/backup: refuses (exit 3)" 3 "$RC"

# ───────────────────────────────────────────────────────────────────────────
section "db/minimart_setup.sql"
OUTS=$(setup_sql); RCS=$?
check "first run exits 0" 0 "$RCS"
hasnt "password not echoed (app)" "$APP_PW" "$OUTS"
hasnt "password not echoed (ro)" "$RO_PW" "$OUTS"
check "3 roles exist; none is superuser" "minimart_app,minimart_owner,minimart_ro|0" \
  "$(NPG -c "select string_agg(rolname, ',' order by rolname) || '|' || count(*) filter (where rolsuper) from pg_roles where rolname like 'minimart\_%'")"
check "app and ro can log in" "true,true" "$(NPG -c "select string_agg(rolcanlogin::text, ',') from pg_roles where rolname in ('minimart_app','minimart_ro')")"
check "owner is NOLOGIN" "f" "$(NPG -c "select rolcanlogin from pg_roles where rolname='minimart_owner'")"
RO_CFG=$(NPG -c "select lower(array_to_string(rolconfig, '|')) from pg_roles where rolname='minimart_ro'")
has "ro: timezone=UTC" "timezone=utc" "$RO_CFG"
has "ro: datestyle ISO, YMD" "datestyle=iso, ymd" "$RO_CFG"
has "ro: read-only default" "default_transaction_read_only=on" "$RO_CFG"
has "ro: statement_timeout 120s" "statement_timeout=120s" "$RO_CFG"
check "ro: connection limit 20" 20 "$(NPG -c "select rolconnlimit from pg_roles where rolname='minimart_ro'")"
check "app: connection limit 50 (default)" 50 "$(NPG -c "select rolconnlimit from pg_roles where rolname='minimart_app'")"
check "db minimart exists, owned by minimart_owner" "minimart_owner" "$(NPG -c "select pg_get_userbyid(datdba) from pg_database where datname='minimart'")"
check "PUBLIC has no CONNECT on minimart" "0" "$(NPG -c "select count(*) from pg_database d, aclexplode(d.datacl) a where d.datname='minimart' and a.grantee = 0")"
check "app has CONNECT, ro has CONNECT" "true|true" "$(NPG -c "select has_database_privilege('minimart_app','minimart','CONNECT') || '|' || has_database_privilege('minimart_ro','minimart','CONNECT')")"
PW1=$(NPG -c "select left(rolpassword, 13) from pg_authid where rolname='minimart_app'")
check "app password stored as SCRAM" "SCRAM-SHA-256" "$PW1"
HASH_A=$(NPG -c "select md5(rolpassword) from pg_authid where rolname='minimart_app'")
OUTS=$(NO_PW=1 setup_sql); RCS=$?
check "re-run WITHOUT passwords (grants-only) exits 0" 0 "$RCS"
check "  password untouched by a grants-only run" "$HASH_A" "$(NPG -c "select md5(rolpassword) from pg_authid where rolname='minimart_app'")"
OUTS=$(setup_sql); check "re-run with passwords (idempotent) exits 0" 0 $?
check "  password rotated (new salt) by a run with passwords" "1" "$([ "$HASH_A" != "$(NPG -c "select md5(rolpassword) from pg_authid where rolname='minimart_app'")" ] && echo 1 || echo 0)"
OUTS=$(APP_PW_USE=short15chars_xx setup_sql); RCS=$?
check "app password of 15 chars is rejected (psql exit 3)" 3 "$RCS"
has "  error says at least 16" "at least 16" "$OUTS"
OUTS=$(RO_PW_USE=short setup_sql); check "ro password of 5 chars is rejected (psql exit 3)" 3 $?
check "new database is empty of tables" 0 "$(NP -c "select count(*) from pg_tables where schemaname='public'")"
check "default privileges exist for minimart_owner -> app" "1" "$(NP -c "select count(*) from pg_default_acl d where pg_get_userbyid(defaclrole)='minimart_owner' and defaclobjtype='r' and defaclacl::text like '%minimart_app=arwd%'")"
check "no default privileges for minimart_ro on tables" "0" "$(NP -c "select count(*) from pg_default_acl d where defaclobjtype='r' and defaclacl::text like '%minimart_ro=%'")"
check "no other database was altered (procurement-style names untouched)" "0" "$(NPG -c "select count(*) from pg_db_role_setting where setdatabase <> 0")"

# ───────────────────────────────────────────────────────────────────────────
section "--inspect (read-only report of the old database)"
( PGHOST=127.0.0.1 PGPORT=$OLD_PORT "$PG14/psql" -U mmadmin -X -q -d minimartdb -c "select pg_sleep(300)" >/dev/null 2>&1 & echo $! > "$WORK/app.pid" )
sleep 1; APP_PID=$(cat "$WORK/app.pid")
STATS_BEFORE=$(OP -c "select sum(n_tup_ins+n_tup_upd+n_tup_del) from pg_stat_user_tables")
mig --inspect
check "inspect exits 0" 0 "$RC"
has "lists tables with exact counts" "public.products" "$OUT"
has "  products rows" "1000" "$OUT"
has "  event_log (no PK, with duplicates)" "2020" "$OUT"
has "reports tables without a primary key" "public.event_log" "$OUT"
has "reports unlogged table" "scratch_cache" "$OUT"
has "reports extensions" "citext" "$OUT"
has "reports sequences and what they feed" "public.customers.customer_id" "$OUT"
has "reports the standalone sequence" "invoice_no_seq" "$OUT"
has "reports large objects" "large_objects" "$OUT"
has "reports sensitive-looking columns: password_hash" "password_hash" "$OUT"
has "  api_token" "api_token" "$OUT"
has "  reset_otp" "reset_otp" "$OUT"
has "  user_sessions.token" "user_sessions" "$OUT"
has "time columns: customers.signed_up_at is a plain timestamp" "signed_up_at" "$OUT"
has "  UTC wall-clock verdict" "looks like UTC wall clock" "$OUT"
has "  timestamptz is reported as absolute" "absolute time (fine)" "$OUT"
has "who is connected: the simulated app session" "mmadmin" "$OUT"
has "reports collation (old = C)" "collate" "$OUT"
has "reports roles incl. legacy_app" "legacy_app" "$OUT"
has "reports a custom owner / acl" "legacy_app=r/" "$OUT"
hasnt "no ERROR lines in the inspect output" "ERROR" "$OUT"
check "inspect changed nothing (no inserts/updates/deletes)" "$STATS_BEFORE" "$(OP -c "select sum(n_tup_ins+n_tup_upd+n_tup_del) from pg_stat_user_tables")"
# session read-only
RO_TRY=$(docker exec -i -e "PGOPTIONS=-c default_transaction_read_only=on" minimart-postgres-1 psql -U mmadmin -d minimartdb -X -q -c "create table zz_probe(a int)" 2>&1)
has "the old database sessions this script opens are read-only" "read-only transaction" "$RO_TRY"
# wrong login hint
OUT=$(MINIMART_OLD_PGUSER=nobody bash "$MIG" --inspect 2>&1); RC=$?
check "wrong old login: exit 1 with hint" 1 "$RC"
has "  hint names the env vars" "MINIMART_OLD_PGUSER" "$OUT"
OUT=$(MINIMART_OLD_CONTAINER=does-not-exist bash "$MIG" --inspect 2>&1); RC=$?
check "unknown container: exit 1" 1 "$RC"

# ───────────────────────────────────────────────────────────────────────────
section "--backup-old"
mig --backup-old
check "backup exits 0" 0 "$RC"
BK=$(ls -1d "$WORK"/backups/pre_migration_*/ | tail -1)
for f in old.dump schema.sql globals.sql counts.tsv MANIFEST SHA256SUMS COMPLETE; do [ -s "$BK$f" ] && ok "  $f exists" || bad "  $f missing"; done
has "  ends with an OK line" "OK $WORK/backups/pre_migration_" "$OUT"
check "  directory mode 700" "700" "$(stat -f %Lp "$BK" 2>/dev/null || stat -c %a "$BK")"
check "  globals.sql mode 600" "600" "$(stat -f %Lp "${BK}globals.sql" 2>/dev/null || stat -c %a "${BK}globals.sql")"
check "  counts.tsv has 18 tables (matviews are not counted)" 18 "$(grep -c . "${BK}counts.tsv")"
has "  counts.tsv: products 1000" "public.products	1000" "$(cat "${BK}counts.tsv")"
has "  schema.sql is plain SQL" "CREATE TABLE public.products" "$(cat "${BK}schema.sql")"
has "  globals.sql has the legacy role" "legacy_app" "$(cat "${BK}globals.sql")"
check "  the dump is a valid pg_restore archive" "ok" "$("$PG15/pg_restore" --list "${BK}old.dump" >/dev/null 2>&1 && echo ok || echo bad)"
check "  SHA256SUMS verifies" "ok" "$(cd "$BK" && { shasum -a 256 -c SHA256SUMS >/dev/null 2>&1 || sha256sum -c SHA256SUMS >/dev/null 2>&1; } && echo ok || echo bad)"
# the old DB is untouched (still no marker objects): counts equal
check "  old database unchanged by the backup" "1000" "$(OP -c "select count(*) from products")"

# ───────────────────────────────────────────────────────────────────────────
section "--rehearse (scratch DB minimart_rehearsal, real minimart untouched)"
mig --rehearse
check "rehearse exits 0" 0 "$RC"
has "  prints VERIFY OK" "VERIFY OK" "$OUT"
has "  prints REHEARSAL OK" "REHEARSAL OK" "$OUT"
has "  prints timing: dump" "dump:" "$OUT"
has "  prints timing: restore" "restore:" "$OUT"
has "  prints the total / expected downtime" "expected cutover downtime" "$OUT"
has "  warns that database-level settings are not carried (search_path)" "settings stored on it" "$OUT"
has "  gives a ready-to-paste ALTER DATABASE" "ALTER DATABASE minimart SET search_path TO public, audit;" "$OUT"
has "  warns about the sort-order difference C vs en_US.UTF-8" "text SORT ORDER differs" "$OUT"
has "  sequence behind its data was repaired" "reset from 5 to 200" "$OUT"
has "  ownership changed to minimart_owner" "changed to minimart_owner" "$OUT"
check "  scratch database dropped" 0 "$(NPG -c "select count(*) from pg_database where datname='minimart_rehearsal'")"
check "  real minimart still empty" 0 "$(NP -c "select count(*) from pg_tables where schemaname not in ('pg_catalog','information_schema')")"
check "  rehearsal dump deleted after success" 0 "$(ls -1d "$WORK"/backups/rehearsal_* 2>/dev/null | wc -l | tr -d ' ')"
# rerun with a leftover scratch DB
NPG -c "create database minimart_rehearsal" >/dev/null
mig --rehearse
check "rehearse refuses to drop a database that is not a marked scratch database (exit 3)" 3 "$RC"
has "  says so" "not a rehearsal scratch database" "$OUT"
check "  the unmarked database is still there" 1 "$(NPG -c "select count(*) from pg_database where datname='minimart_rehearsal'")"
NPG -c "comment on database minimart_rehearsal is 'minimart-rehearsal-scratch'" >/dev/null
mig --rehearse
check "rehearse again with a leftover scratch DB exits 0" 0 "$RC"
has "  says it dropped the leftover" "exists from an earlier run" "$OUT"
# KEEP flag
MINIMART_KEEP_REHEARSAL=1 mig --rehearse
check "rehearse with MINIMART_KEEP_REHEARSAL=1 keeps the DB" 1 "$(NPG -c "select count(*) from pg_database where datname='minimart_rehearsal'")"
NPG -c "drop database minimart_rehearsal" >/dev/null

# ───────────────────────────────────────────────────────────────────────────
section "--cutover guards"
mig --cutover
check "app still connected: exit 3" 3 "$RC"
has "  lists the connection" "mmadmin" "$OUT"
has "  says to stop the app" "stop the minimart app" "$OUT"
check "  new database still empty (nothing changed)" 0 "$(NP -c "select count(*) from pg_tables where schemaname not in ('pg_catalog','information_schema')")"
check "  no cutover dump directory created" 0 "$(ls -1d "$WORK"/backups/cutover_* 2>/dev/null | wc -l | tr -d ' ')"
kill "$APP_PID" 2>/dev/null; wait "$APP_PID" 2>/dev/null; APP_PID=
OP -c "select pg_terminate_backend(pid) from pg_stat_activity where datname='minimartdb' and pid <> pg_backend_pid()" >/dev/null; sleep 1
# target not empty and not ours
NP -c "create table intruder(a int)" >/dev/null
mig --cutover
check "non-empty target without marker: exit 3" 3 "$RC"
has "  refuses to touch it" "not empty" "$OUT"
check "  the foreign table is still there" 1 "$(NP -c "select count(*) from pg_tables where tablename='intruder'")"
NP -c "drop table intruder" >/dev/null
# wrong source database (empty): must refuse, not report success
OUT=$(MINIMART_OLD_DB=postgres bash "$MIG" --backup-old 2>&1); RC=$?
check "empty/wrong old database: --backup-old refuses (exit 3)" 3 "$RC"
has "  says NO tables and lists the databases" "has NO tables" "$OUT"
OUT=$(MINIMART_OLD_DB=postgres bash "$MIG" --rehearse 2>&1); RC=$?
check "empty/wrong old database: --rehearse refuses (exit 3)" 3 "$RC"
# no backup yet in a fresh root
OUT=$(MINIMART_BACKUP_ROOT=$WORK/emptybackups bash "$MIG" --cutover 2>&1); RC=$?
check "cutover without a completed pre_migration backup: exit 3" 3 "$RC"
has "  tells to run --backup-old" "--backup-old" "$OUT"


# ───────────────────────────────────────────────────────────────────────────
section "--cutover (happy path) into a database created with lc_collate=C"
NPG -c "drop database minimart" >/dev/null
OUTS=$(setup_sql -v lc_collate=C); check "setup with -v lc_collate=C exits 0" 0 $?
check "  database minimart now has collate C" "C" "$(NPG -c "select datcollate from pg_database where datname='minimart'")"
OLD_SIG=$(OP -c "select md5(string_agg(p::text, '|' order by product_id)) from products p")
mig --cutover
check "cutover exits 0" 0 "$RC"
has "  CUTOVER OK" "CUTOVER OK" "$OUT"
has "  VERIFY OK" "VERIFY OK" "$OUT"
hasnt "  no sort-order warning (old C = new C)" "SORT ORDER differs" "$OUT"
has "  guard: app stopped" "no other connections" "$OUT"
has "  timing line" "restore" "$OUT"
has "  sequence behind its data repaired" "reset from 5 to 200" "$OUT"
has "  tells what is next" "Next: point the app" "$OUT"
check "  marker says cutover-complete" "1" "$(NPG -c "select count(*) from pg_database d where datname='minimart' and shobj_description(d.oid,'pg_database') like 'minimart-migration: cutover-complete %'")"
CD=$(ls -1d "$WORK"/backups/cutover_*/ | tail -1)
check "  final dump kept" "ok" "$([ -s "${CD}final.dump" ] && echo ok || echo bad)"
check "  row content identical (md5 of every products row)" "$OLD_SIG" "$(NP -c "select md5(string_agg(p::text, '|' order by product_id)) from products p")"
check "  audit.changes rows" 30 "$(NP -c "select count(*) from audit.changes")"
check "  citext extension present and working" "t" "$(NP -c "select 'ABC'::citext = 'abc'::citext")"
check "  large objects restored (2)" 2 "$(NP -c "select count(*) from pg_largeobject_metadata")"
check "  large objects owned by minimart_owner" "minimart_owner" "$(NP -c "select string_agg(distinct pg_get_userbyid(lomowner), ',') from pg_largeobject_metadata")"
check "  weird identifiers survived" "3" "$(NP -c "select count(*) from \"weird\"\"name\"")"
check "  specials: NaN/infinity survived" "NaN|infinity" "$(NP -c "select f::text || '|' || ts::text from specials where id = 1")"
check "  all tables/views/seqs/types/functions owned by minimart_owner" "0" "$(NP -c "select count(*) from pg_shdepend sd where sd.dbid=(select oid from pg_database where datname='minimart') and sd.deptype='o' and sd.refobjid <> (select oid from pg_roles where rolname='minimart_owner') and not exists (select 1 from pg_depend d where d.classid=sd.classid and d.objid=sd.objid and d.deptype='e')")"
check "  schema audit owned by minimart_owner" "minimart_owner" "$(NP -c "select pg_get_userbyid(nspowner) from pg_namespace where nspname='audit'")"
check "  old owner legacy_app does not exist on the new server" "0" "$(NPG -c "select count(*) from pg_roles where rolname='legacy_app'")"
check "  no ACLs carried over (--no-acl): legacy_app has no grant on orders" "0" "$(NP -c "select count(*) from pg_class where relname='orders' and relacl::text like '%legacy_app%'")"
check "  ANALYZE ran (products has statistics)" "1" "$(NP -c "select count(*) from pg_stat_user_tables where relname='products' and last_analyze is not null")"
# application role: DML ok, sequences ok, repaired sequence gives 201, no DDL, no TRUNCATE
APPT=$(NP <<'SQL' 2>&1
BEGIN;
SET ROLE minimart_app;
INSERT INTO customers (email, full_name, password_hash) VALUES ('t@example.com', 'T', 'x') RETURNING customer_id;
UPDATE customers SET loyalty_pts = 1 WHERE customer_id = 1;
INSERT INTO products (sku, name, price) VALUES ('NEW-1', 'n', 1.5) RETURNING product_id;
INSERT INTO audit.changes (tbl) VALUES ('x') RETURNING change_id;
SELECT nextval('invoice_no_seq');
DELETE FROM user_sessions WHERE token = 'none';
ROLLBACK;
SQL
)
has "  app: insert into a repaired serial gets 201 (no collision)" "201" "$APPT"
has "  app: identity (always) column works" "1001" "$APPT"
has "  app: nextval on a standalone sequence works (5001)" "5001" "$APPT"
hasnt "  app: no permission errors on DML" "permission denied" "$APPT"
denied() { local o; o=$(NP -c "$1" 2>&1); if grep -q 'permission denied' <<< "$o"; then echo denied; else echo allowed; fi; }
check "  app cannot CREATE TABLE" "denied" "$(denied "set role minimart_app; create table zz(a int)")"
check "  app cannot TRUNCATE" "denied" "$(denied "set role minimart_app; truncate table categories")"
check "  ro role has no table privileges until db/minimart_ro_grants.sql" "denied" "$(denied "set role minimart_ro; select 1 from products limit 1")"
check "  ro role can use the schema" "t" "$(NP -c "select has_schema_privilege('minimart_ro','public','USAGE')")"
check "  setup report after the restore: no table the app cannot DML, none owned by someone else" "0|0|0" "$(NO_PW=1 setup_sql -v dbname=minimart -A -t -F'|' | grep '^minimart|' | awk -F'|' '{print $5"|"$6"|"$7}')"
check "  old database still has everything" "1000" "$(OP -c "select count(*) from products")"
check "  old database has no migration objects added" "0" "$(OP -c "select count(*) from pg_class where relname like 'zz%' or relname like '%migration%'")"

section "--cutover run again after success"
NP -c "insert into \"Legacy Notes\" values (99, 'written after cutover', now())" >/dev/null
mig --cutover
check "second cutover is refused (exit 3)" 3 "$RC"
has "  says already completed" "already completed" "$OUT"
check "  data written after the first cutover is still there" "1" "$(NP -c "select count(*) from \"Legacy Notes\" where \"Note Id\" = 99")"
NP -c "delete from \"Legacy Notes\" where \"Note Id\" = 99" >/dev/null

section "--cutover rebuild refuses while the application roles are connected"
NPG -c "comment on database minimart is 'minimart-migration: restored-unverified 2026-01-01T00:00:00Z'" >/dev/null
( PGHOST=127.0.0.1 PGPORT=$NEW_PORT "$PG15/psql" -U minimart_app -X -q -d minimart -c "select pg_sleep(300)" >/dev/null 2>&1 & echo $! > "$WORK/app2.pid" )
sleep 1; APP_PID=$(cat "$WORK/app2.pid")
NP -c "insert into \"Legacy Notes\" values (777, 'live row', now())" >/dev/null
mig --cutover
check "rebuild with minimart_app connected: exit 3" 3 "$RC"
has "  says the application roles are connected" "application roles are connected" "$OUT"
check "  live row still there" 1 "$(NP -c "select count(*) from \"Legacy Notes\" where \"Note Id\" = 777")"
NPG -c "select pg_terminate_backend(pid) from pg_stat_activity where usename='minimart_app' and pid <> pg_backend_pid()" >/dev/null; kill "$APP_PID" 2>/dev/null; APP_PID=; sleep 1

section "--cutover rebuild path keeps collation and database time zone"
NPG -c "alter database minimart set timezone = 'Asia/Bangkok'" >/dev/null
NPG -c "comment on database minimart is 'minimart-migration: restored-unverified 2026-01-01T00:00:00Z'" >/dev/null
mig --cutover
check "cutover over an unverified earlier attempt: exit 0" 0 "$RC"
has "  says it rebuilds the earlier attempt" "never verified" "$OUT"
check "  collation C kept" "C" "$(NPG -c "select datcollate from pg_database where datname='minimart'")"
check "  database time zone kept" "timezone=asia/bangkok" "$(NPG -c "select lower(s.setconfig::text) from pg_db_role_setting s join pg_database d on d.oid=s.setdatabase where d.datname='minimart' and s.setrole=0" | tr -d '{}')"
check "  marker complete again" "1" "$(NPG -c "select count(*) from pg_database d where datname='minimart' and shobj_description(d.oid,'pg_database') like '%cutover-complete%'")"
check "  database owner is minimart_owner again" "minimart_owner" "$(NPG -c "select pg_get_userbyid(datdba) from pg_database where datname='minimart'")"

section "--verify (old vs new, on the rehearsal copy so that mutations can be reverted)"
MINIMART_KEEP_REHEARSAL=1 mig --rehearse; check "rehearsal copy built" 0 "$RC"
export MINIMART_NEW_DB=minimart_rehearsal
mig --verify; check "verify of an exact copy: exit 0" 0 "$RC"; has "  says VERIFY OK" "VERIFY OK" "$OUT"
has "  numeric sums are compared" "rows=1000" "$OUT"
vcase() { # vcase "description" "mutate sql" "revert sql" "expected text" [env]
  NDB=minimart_rehearsal NP -c "set session_replication_role = replica; $2" >/dev/null || { bad "mutation failed: $1"; return; }
  OUT=$(env ${5:-X=1} bash "$MIG" --verify 2>&1); RC=$?
  if [ "$RC" -eq 1 ] && grep -qF -- "$4" <<< "$OUT"; then ok "$1 -> detected ($4)"; else bad "$1 -> exit $RC, wanted 1 with [$4]: $(grep -E 'FAIL' <<< "$OUT" | head -3 | tr '\n' ' ')"; fi
  NDB=minimart_rehearsal NP -c "set session_replication_role = replica; $3" >/dev/null || bad "revert failed: $1"
}
vcase "changed numeric value"   "update products set price = price + 1 where product_id = 5" "update products set price = price - 1 where product_id = 5" "sum:price"
vcase "changed text value"      "update products set name = name || 'x' where product_id = 6" "update products set name = left(name, length(name) - 1) where product_id = 6" "hash="
vcase "changed max date (no content check)" "update products set released_on = released_on + 1 where product_id = (select product_id from products order by released_on desc, product_id limit 1)" "update products set released_on = released_on - 1 where product_id = (select product_id from products order by released_on desc, product_id limit 1)" "max:released_on" "MINIMART_VERIFY_CONTENT=0"
vcase "changed text next to a column named t" "update tcol set v = 'CHANGED' where t = 1" "update tcol set v = 'one' where t = 1" "hash="
vcase "deleted row"             "create table zz_keep as select * from event_log where kind='login' limit 1; delete from event_log where kind='login' and ts = (select min(ts) from event_log where kind='login')" "insert into event_log select * from zz_keep; drop table zz_keep" "rows="
vcase "renamed table (missing)" "alter table specials rename to specials_x" "alter table specials_x rename to specials" "missing in new database"
vcase "extra table"             "create table zz_extra(a int)" "drop table zz_extra" "extra table in new database"
vcase "sequence behind its data" "do \$\$ begin perform setval('customers_customer_id_seq', 3); end \$\$" "do \$\$ begin perform setval('customers_customer_id_seq', 200); end \$\$" "BEHIND old"
vcase "table owned by someone else" "alter table categories owner to postgres" "alter table categories owner to minimart_owner" "not owned by minimart_owner"
vcase "extra index"             "create index zz_idx on categories (name)" "drop index zz_idx" "catalog inventory differs"
vcase "NaN changed to a number" "update specials set f = 1 where id = 1" "update specials set f = 'NaN' where id = 1" "sum:f"
vcase "large object changed"    "select lo_put((select min(oid) from pg_largeobject_metadata), 0, '\\x41')" "select lo_put((select min(oid) from pg_largeobject_metadata), 0, '\\x68')" "inv|largeobjects"
mig --verify; check "after reverting every mutation: verify exit 0 again" 0 "$RC"
check "content check off: a text-only change is NOT detected (documented limit)" "0" "$( NDB=minimart_rehearsal NP -c "set session_replication_role = replica; update products set name = name || 'y' where product_id = 7" >/dev/null; MINIMART_VERIFY_CONTENT=0 bash "$MIG" --verify >/dev/null 2>&1; echo $?; NDB=minimart_rehearsal NP -c "set session_replication_role = replica; update products set name = left(name, length(name) - 1) where product_id = 7" >/dev/null )"
unset MINIMART_NEW_DB
NPG -c "drop database minimart_rehearsal" >/dev/null

section "--rollback-info and usage"
mig --rollback-info
check "rollback-info exits 0" 0 "$RC"
has "  explains data written after cutover is lost" "NOT in the" "$OUT"
has "  names the old container" "docker start minimart-postgres-1" "$OUT"
has "  never restart mmi-postgres" "Never restart or remove mmi-postgres" "$OUT"
has "  names the dump directories" "pre_migration_" "$OUT"
mig; check "no argument: usage, exit 2" 2 "$RC"
mig --bogus; check "unknown option: exit 2" 2 "$RC"
mig -h; check "-h: exit 0" 0 "$RC"; has "  help lists --cutover" "--cutover" "$OUT"

world_summary
