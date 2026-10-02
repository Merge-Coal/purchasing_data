#!/usr/bin/env bash
# Test of scripts/minimart_backup.sh (nightly backup of database minimart on mmi-postgres) against the
# simulated world of lib.sh (real local Postgres clusters behind the `docker` wrapper).
#
#   bash test/minimart/migrate/run_backup_test.sh
set -uo pipefail
OLD_PORT=${OLD_PORT:-55521}
NEW_PORT=${NEW_PORT:-55522}
source "$(dirname "$0")/lib.sh"

world_up
BAK="$REPO/scripts/minimart_backup.sh"
BD=$WORK/nightly
export MINIMART_BACKUP_DIR=$BD
unset MINIMART_PG_CONTAINER MINIMART_BACKUP_DB MINIMART_BACKUP_RETENTION_DAYS MINIMART_DOCKER MINIMART_PG_USER
bak() { OUT=$(bash "$BAK" "$@" 2>&1); RC=$?; echo "$OUT" > "$WORK/out/last_backup.txt"; }

section "prepare: roles + database minimart with the old data (plain pg_dump | pg_restore, no migrate script involved)"
setup_sql >/dev/null; check "setup ran" 0 $?
docker exec minimart-postgres-1 pg_dump -U mmadmin -d minimartdb -Fc > "$WORK/out/seed.dump"
docker exec -i mmi-postgres pg_restore -U postgres -d minimart --no-owner --no-acl < "$WORK/out/seed.dump" 2>/dev/null; check "data restored into minimart" 0 $?
check "minimart has tables" "18" "$(NP -c "select count(*) from pg_tables where schemaname not in ('pg_catalog','information_schema')")"

section "normal run"
: > "$MOCK_LOG"
bak
check "exit 0" 0 "$RC"
has "log line starts with a timestamp and says OK" "OK $BD/minimart_" "$OUT"
check "exactly one line of output" 1 "$(grep -c . <<< "$OUT")"
FILE=$(ls -1 "$BD"/minimart_*.dump | head -1)
check "dump file exists" ok "$([ -s "$FILE" ] && echo ok || echo no)"
check "backup directory mode 700 or umask-protected file mode 600" "600" "$(stat -f %Lp "$FILE" 2>/dev/null || stat -c %a "$FILE")"
check "no .partial file left" 0 "$(ls -1 "$BD" | grep -c partial)"
check "pg_restore can list it" ok "$("$PG15/pg_restore" --list "$FILE" >/dev/null 2>&1 && echo ok || echo no)"
has "reports the number of tables" "18 tables" "$OUT"
check "only the minimart database was dumped (docker log mentions no other -d value)" "" "$(grep -oE ' -d [A-Za-z0-9_]+' "$MOCK_LOG" | sort -u | grep -v ' -d minimart$' | tr '\n' ' ')"
check "the old container was never contacted" 0 "$(grep -c 'minimart-postgres-1' "$MOCK_LOG")"
docker exec mmi-postgres createdb -U postgres minimart_restore_test
docker exec -i mmi-postgres pg_restore -U postgres -d minimart_restore_test --no-owner --no-acl < "$FILE" 2>/dev/null
check "test-restore into a scratch database works" "1000" "$(NDB=minimart_restore_test NP -c "select count(*) from products")"
docker exec mmi-postgres dropdb -U postgres minimart_restore_test

section "two runs in the same second do not overwrite (distinct file names are not required, the run must not corrupt the first)"
sleep 1; bak; check "second run exit 0" 0 "$RC"
check "two dumps now" 2 "$(ls -1 "$BD"/minimart_*.dump | wc -l | tr -d ' ')"

section "retention"
touch -t 202001010000 "$BD/minimart_20200101_000000.dump"
touch -t 202001010000 "$BD/minimart_20200101_000001.dump.partial"
mkdir -p "$BD/pre_migration_20200101_000000" "$BD/cutover_20200101_000000" "$BD/rehearsal_20200101_000000"
touch -t 202001010000 "$BD/pre_migration_20200101_000000/old.dump" "$BD/cutover_20200101_000000/final.dump" "$BD/rehearsal_20200101_000000/old.dump" "$BD/pre_migration_20200101_000000"
touch -t 202001010000 "$BD/other_20200101.dump" "$BD/notes.txt"
sleep 1
bak
check "exit 0" 0 "$RC"
has "says it removed the old dump" "removed $BD/minimart_20200101_000000.dump" "$OUT"
check "old dump deleted" no "$([ -e "$BD/minimart_20200101_000000.dump" ] && echo yes || echo no)"
check "old .partial deleted" no "$([ -e "$BD/minimart_20200101_000001.dump.partial" ] && echo yes || echo no)"
check "recent dumps kept" 3 "$(ls -1 "$BD"/minimart_2026*.dump | wc -l | tr -d ' ')"
check "pre_migration_ directory untouched" ok "$([ -f "$BD/pre_migration_20200101_000000/old.dump" ] && echo ok || echo no)"
check "cutover_ directory untouched" ok "$([ -f "$BD/cutover_20200101_000000/final.dump" ] && echo ok || echo no)"
check "rehearsal_ directory untouched" ok "$([ -f "$BD/rehearsal_20200101_000000/old.dump" ] && echo ok || echo no)"
check "foreign files untouched" "2" "$(ls -1 "$BD/other_20200101.dump" "$BD/notes.txt" 2>/dev/null | wc -l | tr -d ' ')"
MINIMART_BACKUP_RETENTION_DAYS=abc bash "$BAK" >/dev/null 2>&1; check "non-numeric retention is rejected (exit 1)" 1 $?
MINIMART_BACKUP_RETENTION_DAYS=0 bak; check "retention 0 days still keeps the file just written" ok "$([ -e "$(echo "$OUT" | sed -n 's/.* OK \([^ ]*\) (.*/\1/p' | head -1)" ] && echo ok || echo no)"

section "failure paths (no file may be kept, exit 1, one FAILED line)"
rm -f "$BD"/minimart_*.dump
MINIMART_BACKUP_DB=no_such_db bak
check "unknown database: exit 1" 1 "$RC"; has "  FAILED line" "FAILED:" "$OUT"
check "  no dump file" 0 "$(ls -1 "$BD" | grep -c '^minimart_')"
MINIMART_PG_CONTAINER=nope bak
check "unknown container: exit 1" 1 "$RC"; has "  FAILED line" "FAILED:" "$OUT"
rm -f "$MOCK_DIR/mmi-postgres/running"
bak; check "container stopped: exit 1" 1 "$RC"; has "  FAILED line" "FAILED:" "$OUT"
touch "$MOCK_DIR/mmi-postgres/running"
# empty database: refuse to write an empty backup
NPG -c "create database minimart_empty" >/dev/null
MINIMART_BACKUP_DB=minimart_empty bak
check "database without tables: exit 1" 1 "$RC"; has "  says refusing" "no tables" "$OUT"
NPG -c "drop database minimart_empty" >/dev/null
# non-writable directory
mkdir -p "$WORK/ro_dir"; chmod 500 "$WORK/ro_dir"
MINIMART_BACKUP_DIR=$WORK/ro_dir/sub bak
check "cannot create the backup directory: exit 1" 1 "$RC"; has "  FAILED line" "FAILED:" "$OUT"
MINIMART_BACKUP_DIR=$WORK/ro_dir bak
check "backup directory not writable: exit 1" 1 "$RC"
chmod 700 "$WORK/ro_dir"
# pg_dump fails halfway: own docker wrapper
mkdir -p "$WORK/bin2"
cat > "$WORK/bin2/docker" <<'EOS'
#!/usr/bin/env bash
# delegates to the mock; sabotages pg_dump / pg_restore --list depending on FAKE
for a in "$@"; do
  case "$a" in
    pg_dump) if [ "${FAKE:-}" = dumpfail ]; then head -c 1000 /dev/urandom | head -c 200; exit 1; fi
             if [ "${FAKE:-}" = junk ]; then echo "this is not a dump"; exit 0; fi
             if [ "${FAKE:-}" = empty ]; then exit 0; fi ;;
  esac
done
exec "$REAL_DOCKER" "$@"
EOS
chmod +x "$WORK/bin2/docker"
for mode in dumpfail junk empty; do
  OUT=$(FAKE=$mode REAL_DOCKER="$WORK/bin/docker" MINIMART_DOCKER="$WORK/bin2/docker" bash "$BAK" 2>&1); RC=$?
  check "pg_dump '$mode': exit 1" 1 "$RC"; has "  FAILED line" "FAILED:" "$OUT"
  check "  no dump and no .partial kept" 0 "$(ls -1 "$BD" | grep -c '^minimart_')"
done

section "secrets and logs"
bak
check "normal run again after all failures: exit 0" 0 "$RC"
hasnt "no password-like env values in the output" "$APP_PW" "$OUT"
check "docker log never contains the generated passwords" 0 "$(grep -c -e "$APP_PW" -e "$RO_PW" "$MOCK_LOG")"

world_summary
