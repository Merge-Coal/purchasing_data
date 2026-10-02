#!/usr/bin/env bash
# Tests RUNBOOK_MINIMART_MIGRATION.md itself: the fenced ```bash blocks are EXTRACTED from the
# runbook and executed, so what the user pastes is what is tested.
#
#   MINIMART_TEST_DIR=<scratch dir> bash test/minimart/migrate/run_runbook_test.sh
#
# What it proves
#   * static lint of every block (also the <!-- notest --> ones): `bash -n`, starts with
#     `cd /opt/purchasing_data`, no `set -e` / `exit` / `read` / heredoc / prompt text, no forbidden
#     docker commands, no unformatted `docker inspect`, no `printenv` of anything but the two
#     login names, and every section with a block has an "Expected" and a "STOP" paragraph;
#   * every other block is run in a FRESH `bash` process with an EMPTY environment (only PATH and HOME),
#     so a block that depends on a variable, function or `cd` of an earlier block fails;
#   * the output contains the 'Expected' markers the runbook documents, destructive blocks refuse when
#     their precondition is false, and no password ever reaches an output or the docker log.
# The simulated world is test/minimart/migrate/lib.sh (two real Postgres clusters + a docker mock).
# Path substitutions, by sed on the extracted text only (the runbook is never edited):
#   /opt/purchasing_data -> a sandbox git checkout  ($WORK/repo, with wrapper scripts that call the real ones)
#   /opt/backups -> $WORK/backups   /var/log -> $WORK/out   /root/ -> $WORK/root/   /opt/minimart -> $WORK/minimart_app
# Blocks marked <!-- notest --> need things that do not exist locally (compose, iptables/ufw/ss, a real
# /etc/cron.d). They are linted and syntax checked, not run; 6.2 additionally runs in the sandbox with
# /etc/cron.d and /etc/logrotate.d redirected, to check what it writes.
set -uo pipefail
OLD_PORT=${OLD_PORT:-55531}
NEW_PORT=${NEW_PORT:-55532}
source "$(dirname "$0")/lib.sh"
hasre() { if grep -Eq -- "$2" <<< "$3"; then ok "$1"; else bad "$1: no match for [$2] in: $(head -c 500 <<< "$3" | tr '\n' ' ')"; fi; }

RUNBOOK=${RUNBOOK_FILE:-$REPO/RUNBOOK_MINIMART_MIGRATION.md}
[ -f "$RUNBOOK" ] || { echo "missing $RUNBOOK"; exit 1; }
BLK=$WORK/blocks; RUN=$WORK/run; SH=$WORK/repo; APP=$WORK/minimart_app
mkdir -p "$BLK" "$RUN" "$WORK/root" "$APP" "$WORK/etc/cron.d" "$WORK/etc/logrotate.d"
SLEEP_PIDS=""
trap 'for p in $SLEEP_PIDS; do kill $p 2>/dev/null; done; cleanup' EXIT

echo "Postgres old: $($PG14/postgres --version)   new: $($PG15/postgres --version)   bash $BASH_VERSION"
echo "scratch dir: $WORK"

# ── extraction ───────────────────────────────────────────────────────────────
# One file per ```bash block: blocks/<section id>_<n>.sh ; a <!-- notest --> on the line before the fence
# also creates blocks/<section id>_<n>.notest
awk -v dir="$BLK" '
  { pn = (last == "<!-- notest -->"); last = $0 }
  inb && /^```[[:space:]]*$/ { inb = 0; close(f); next }
  inb { print >> f; next }
  /^### / { id = $2; n = 0; next }
  /^```bash[[:space:]]*$/ { inb = 1; n++; f = dir "/" id "_" n ".sh"; printf "" > f; if (pn) { nt = dir "/" id "_" n ".notest"; printf "" > nt; close(nt) }; next }
' "$RUNBOOK"
NBLOCKS=$(ls "$BLK"/*.sh 2>/dev/null | wc -l | tr -d ' ')
NNOTEST=$(ls "$BLK"/*.notest 2>/dev/null | wc -l | tr -d ' ')
section "extraction"
echo "  $NBLOCKS bash blocks, $NNOTEST marked notest"
[ "$NBLOCKS" -ge 40 ] && ok "at least 40 blocks extracted" || bad "only $NBLOCKS blocks extracted"

# ── static lint (all blocks) ─────────────────────────────────────────────────
section "static lint of every block (also the notest ones)"
LINT_BAD=0
for f in "$BLK"/*.sh; do
  b=$(basename "$f" .sh)
  bash -n "$f" 2>"$WORK/out/syntax.err" || { bad "$b: bash -n: $(head -n 2 "$WORK/out/syntax.err" | tr '\n' ' ')"; LINT_BAD=1; }
  first=$(grep -v '^[[:space:]]*$' "$f" | head -n 1)
  [ "$first" = "cd /opt/purchasing_data" ] || { bad "$b: first line is [$first], must be 'cd /opt/purchasing_data'"; LINT_BAD=1; }
  code=$(grep -v '^[[:space:]]*#' "$f")
  grep -Eq '(^|[;&|{(][[:space:]]*)set -[a-z]*e' <<< "$code" && { bad "$b: set -e"; LINT_BAD=1; }
  grep -Eq '(^|[;&|{(][[:space:]]*)exit([[:space:]]|$)' <<< "$code" && { bad "$b: exit"; LINT_BAD=1; }
  grep -Eq '(^|[;&|{(][[:space:]]*)read([[:space:]]|$)' <<< "$code" && { bad "$b: read"; LINT_BAD=1; }
  grep -q '<<' "$f" && { bad "$b: heredoc"; LINT_BAD=1; }
  grep -Eq '^[[:space:]]*[$#] ' "$f" && grep -Eq '^[[:space:]]*\$ ' "$f" && { bad "$b: prompt text"; LINT_BAD=1; }
  grep -Eq 'docker (rm|restart|container prune|system prune|volume|network (rm|prune))|compose down|docker stop mmi-postgres|--volumes' <<< "$code" && { bad "$b: forbidden docker command"; LINT_BAD=1; }
  grep -E 'docker inspect' <<< "$code" | grep -qv -- ' -f ' && { bad "$b: docker inspect without -f"; LINT_BAD=1; }
  grep -E 'printenv' <<< "$code" | grep -Eqv 'printenv POSTGRES_(USER|DB)' && { bad "$b: printenv of something other than POSTGRES_USER/POSTGRES_DB"; LINT_BAD=1; }
  grep -Eq 'docker compose.* config([[:space:]]|$)' <<< "$code" && ! grep -Eq 'config (--quiet|--services)' <<< "$code" && { bad "$b: docker compose config without --quiet/--services"; LINT_BAD=1; }
  grep -Eq '(cat|less|more|head|tail) +[^ ]*\.env([[:space:]]|$)' <<< "$code" && { bad "$b: prints an .env file"; LINT_BAD=1; }
  grep -Eq '(^|[;&|{(][[:space:]]*)env([[:space:]]|$)' <<< "$code" && { bad "$b: runs env"; LINT_BAD=1; }
  grep -E 'echo[^#]*\$\{?(PW|APP_PW|RO_PW|PASSWORD)\}?([^A-Za-z_#{]|$)' <<< "$code" | grep -Fv '| grep' | grep -q . && { bad "$b: echoes a password variable"; LINT_BAD=1; }
done
[ "$LINT_BAD" = 0 ] && ok "all $NBLOCKS blocks pass the lint (syntax, cd first, no set -e/exit/read/heredoc, no forbidden docker commands, no secret printing)"
# every section with a block has "Expected" and "STOP"
awk '
  function flush() { if (id != "" && hasb) { if (!hexp) print id ": no Expected"; if (!hstop) print id ": no STOP" } }
  /^### / { flush(); id = $2; hasb = 0; hexp = 0; hstop = 0; next }
  /^## / { flush(); id = ""; next }
  /^```bash/ { hasb = 1 }
  /Expected/ { hexp = 1 }
  /(^|[^A-Z_])STOP([^A-Z_]|$)/ { hstop = 1 }
  END { flush() }
' "$RUNBOOK" > "$WORK/out/lint_sections.txt" || bad "section lint awk failed"
check "every section with a block has an Expected and a STOP paragraph" "" "$(cat "$WORK/out/lint_sections.txt" | tr '\n' ';')"

# ── substitution + runner ────────────────────────────────────────────────────
subst() { sed -e "s#/opt/purchasing_data#$SH#g" -e "s#/opt/backups#$WORK/backups#g" -e "s#/var/log#$WORK/out#g" -e "s#/root/#$WORK/root/#g" -e "s#/opt/minimart#$APP#g" "$@"; }
RAN=""; RUNN=0
runb() { # runb id [n] [sed expression ...]  -> BOUT, BRC. Fresh bash, empty environment.
  local id=$1 n=${2:-1}; shift; [[ $# -gt 0 ]] && shift
  local f="$BLK/${id}_${n}.sh" r="$RUN/${id}_${n}.sh"
  [ -f "$f" ] || { bad "block $id:$n does not exist"; BOUT=; BRC=99; return; }
  subst "$f" > "$r"
  local e; for e in "$@"; do sed -i.bak -e "$e" "$r"; rm -f "$r.bak"; done
  BOUT=$(env -i PATH="$PATH" HOME="$HOME" bash "$r" 2>&1); BRC=$?
  RUNN=$((RUNN + 1)); printf '%s\n' "$BOUT" > "$WORK/out/run_$(printf %03d $RUNN)_${id}_${n}.txt"
  case " $RAN " in *" ${id}_${n} "*) ;; *) RAN="$RAN ${id}_${n}" ;; esac
}

# ── simulated world + helpers ────────────────────────────────────────────────
world_up
mv "$WORK/bin/docker" "$WORK/bin/docker_mock"
mkcontainer minimart-app-1 "$PG14" "$OLD_PORT" 'PGHOST=minimart-postgres-1'
echo always > "$WORK/mock/minimart-postgres-1/restart"
cat > "$WORK/bin/docker" <<'EOS'
#!/usr/bin/env bash
# test shim in front of docker_mock.sh: canned answers for the read-only discovery commands the
# runbook uses; everything else goes to the mock. Always the same MOCK_DIR/MOCK_LOG (blocks run with an empty env).
export MOCK_DIR=@WORK@/mock MOCK_LOG=@WORK@/out/docker.log
MOCK=@WORK@/bin/docker_mock
sub=${1:-}
state() { if [ -e "$MOCK_DIR/$1/running" ]; then echo running; else echo exited; fi; }
policy() { cat "$MOCK_DIR/$1/restart" 2>/dev/null || echo no; }
case "$sub" in
  ps)
    echo "docker $*" >> "$MOCK_LOG"
    case "$*" in
      *"table "*) printf '%s\n' 'NAMES                IMAGE               STATUS' 'mmi-postgres         postgres:16         Up 3 weeks' 'minimart-postgres-1  postgres:16-alpine  Up 9 days' 'minimart-app-1       minimart-app        Up 9 days' ;;
      *working_dir*) printf '%s\t%s\t%s\t%s\n' minimart-postgres-1 minimart postgres /opt/minimart minimart-app-1 minimart app /opt/minimart ;;
    esac
    exit 0 ;;
  port) echo "docker $*" >> "$MOCK_LOG"; echo '5432/tcp -> 0.0.0.0:5433'; echo '5432/tcp -> [::]:5433'; exit 0 ;;
  update)
    echo "docker $*" >> "$MOCK_LOG"
    for a in "$@"; do case "$a" in --restart=*) echo "${a#--restart=}" > "$MOCK_DIR/${@: -1}/restart" ;; esac; done
    echo "${@: -1}"; exit 0 ;;
  stop)
    if [ "${2:-}" = minimart-app-1 ]; then   # the simulated app: its client and its backend on the old database go away
      [ -s @WORK@/app.pid ] && kill "$(cat @WORK@/app.pid)" 2>/dev/null
      PGHOST=127.0.0.1 PGPORT=@OLD_PORT@ @PG14@/psql -U mmadmin -d minimartdb -X -q -At -c "select pg_terminate_backend(pid) from pg_stat_activity where application_name = 'minimart-app-sim'" >/dev/null 2>&1
    fi
    exec bash "$MOCK" "$@" ;;
  inspect)
    if [ "${2:-}" = -f ]; then
      fmt=$3; name=${4:-}
      case "$fmt" in
        '{{.State.Running}}') exec bash "$MOCK" "$@" ;;
      esac
      echo "docker $*" >> "$MOCK_LOG"
      case "$fmt" in
        *Config.Env*) printf '%s\n' 'PATH=/usr/local/bin:/usr/bin' 'NODE_ENV=production' 'PGHOST=minimart-postgres-1' 'PGPORT=5432' 'PGDATABASE=minimartdb' 'PGUSER=mmadmin' 'PGPASSWORD=S3cretOldPw99' 'DATABASE_URL=postgresql://mmadmin:S3cretOldPw99@minimart-postgres-1:5432/minimartdb?sslmode=disable' 'SESSION_SECRET=zzTopSecretValue' 'API_KEY=abcSecretKey' ;;
        *Mounts*) echo 'volume minimart_pgdata /var/lib/docker/volumes/minimart_pgdata/_data -> /var/lib/postgresql/data' ;;
        *Networks*'ip='*) if [ "$name" = mmi-postgres ]; then echo 'network=postgres_net ip=172.20.0.2'; else echo 'network=minimart_default ip=172.19.0.2'; fi ;;
        *Networks*) if [ "$name" = mmi-postgres ]; then echo 'postgres_net '; else echo 'minimart_default '; fi ;;
        'image='*) echo "image=postgres:16-alpine state=$(state "$name") started=2026-09-20T01:02:03Z restart=$(policy "$name")" ;;
        'state={{.State.Status}} restart='*) echo "state=$(state "$name") restart=$(policy "$name")" ;;
        'state={{.State.Status}}') echo "state=$(state "$name")" ;;
        '{{.HostConfig.RestartPolicy.Name}}') policy "$name" ;;
        *) echo "shim: unknown inspect format: $fmt" >&2; exit 1 ;;
      esac
      exit 0
    fi
    exec bash "$MOCK" "$@" ;;
  *) exec bash "$MOCK" "$@" ;;
esac
EOS
sed -i.bak -e "s#@WORK@#$WORK#g" -e "s#@OLD_PORT@#$OLD_PORT#g" -e "s#@PG14@#$PG14#g" "$WORK/bin/docker"; rm -f "$WORK/bin/docker.bak"
printf '%s\n' '#!/usr/bin/env bash' "echo 'LISTEN 0 4096 0.0.0.0:5433 0.0.0.0:* users:((\"docker-proxy\",pid=1234,fd=4))'" > "$WORK/bin/ss"
printf '%s\n' '#!/usr/bin/env bash' 'exec shasum -a 256 "$@"' > "$WORK/bin/sha256sum"
chmod +x "$WORK/bin/docker" "$WORK/bin/ss" "$WORK/bin/sha256sum"

# sandbox git checkout of the server's /opt/purchasing_data: starts on branch postgres-oltp-migration
gitq() { git -C "$SH" -c user.name=test -c user.email=test@example.com "$@"; }
rm -rf "$SH" "$WORK/origin.git"; mkdir -p "$SH"
git init -q --bare "$WORK/origin.git"
git -C "$SH" init -q; gitq checkout -q -b postgres-oltp-migration
mkdir -p "$SH/scripts" "$SH/db"; echo base > "$SH/README"; gitq add README; gitq commit -q -m base
gitq remote add origin "$WORK/origin.git"; gitq push -q origin postgres-oltp-migration
gitq checkout -q -b minimart-migration
printf '#!/usr/bin/env bash\n:\n' > "$SH/scripts/minimart_migrate.sh"; cp "$SH/scripts/minimart_migrate.sh" "$SH/scripts/minimart_backup.sh"
echo '-- placeholder' > "$SH/db/minimart_setup.sql"
gitq add scripts db; gitq commit -q -m "minimart files"; gitq push -q origin minimart-migration
gitq checkout -q postgres-oltp-migration; gitq branch -q -D minimart-migration
install_wrappers() { # what a checkout would bring: the real scripts (reached through wrappers that set the test paths)
  rm -f "$SH/scripts/minimart_migrate.sh" "$SH/scripts/minimart_backup.sh" "$SH/db/minimart_setup.sql"
  printf '%s\n' '#!/usr/bin/env bash' "exec env MINIMART_MIGRATE_LOCK=$WORK/out/migrate.lock MINIMART_MIGRATE_LOG=$WORK/out/minimart-migration.log MINIMART_BACKUP_ROOT=$WORK/backups/minimart TMPDIR=$WORK/out bash \"$REPO/scripts/minimart_migrate.sh\" \"\$@\"" > "$SH/scripts/minimart_migrate.sh"
  printf '%s\n' '#!/usr/bin/env bash' "exec env MINIMART_BACKUP_DIR=$WORK/backups/minimart TMPDIR=$WORK/out bash \"$REPO/scripts/minimart_backup.sh\" \"\$@\"" > "$SH/scripts/minimart_backup.sh"
  chmod +x "$SH/scripts/minimart_migrate.sh" "$SH/scripts/minimart_backup.sh"
  ln -s "$REPO/db/minimart_setup.sql" "$SH/db/minimart_setup.sql"
}
# the minimart app's files (secrets here are canaries: they must never appear in any output)
printf '%s\n' 'PGHOST=minimart-postgres-1' 'PGPORT=5432' 'PGDATABASE=minimartdb' 'PGUSER=mmadmin' 'PGPASSWORD=S3cretOldPw99' 'SESSION_SECRET=zzTopSecretValue' 'OTHER=1' > "$APP/.env"
printf '%s\n' 'services:' '  postgres:' '    image: postgres:16-alpine' '    container_name: minimart-postgres-1' '    environment:' '      POSTGRES_USER: mmadmin' '      POSTGRES_PASSWORD: S3cretOldPw99' '    ports:' '      - "5433:5432"' '  app:' '    image: minimart-app' '    env_file: .env' '    depends_on:' '      - postgres' '    environment:' '      DATABASE_URL: postgresql://mmadmin:S3cretOldPw99@minimart-postgres-1:5432/minimartdb' '      API_KEY: abcSecretKey' > "$APP/docker-compose.yml"
chmod 600 "$APP/.env"; cp -p "$APP/.env" "$WORK/env_orig"
old_app_up() { ( PGAPPNAME=minimart-app-sim PGHOST=127.0.0.1 PGPORT=$OLD_PORT "$PG14/psql" -U mmadmin -X -q -d minimartdb -c "select pg_sleep(600)" >/dev/null 2>&1 & echo $! > "$WORK/app.pid" ); sleep 1; SLEEP_PIDS="$SLEEP_PIDS $(cat "$WORK/app.pid")"; }
new_app_up() { ( PGAPPNAME=minimart-app-sim PGHOST=127.0.0.1 PGPORT=$NEW_PORT "$PG15/psql" -U minimart_app -X -q -d minimart -c "select pg_sleep(600)" >/dev/null 2>&1 & echo $! > "$WORK/app2.pid" ); sleep 1; SLEEP_PIDS="$SLEEP_PIDS $(cat "$WORK/app2.pid")"; }
dockerlog() { cat "$WORK/out/docker.log"; }

# ───────────────────────────────────────────────────────────────────────────
section "phase 0: branch"
runb 0.1; check "0.1 exit 0" 0 "$BRC"
has "  names the current branch" "branch: postgres-oltp-migration" "$BOUT"
has "  no modified tracked files" "tracked files modified: 0" "$BOUT"
has "  lists scripts/minimart_migrate.sh on the branch" "scripts/minimart_migrate.sh" "$BOUT"
has "  lists db/minimart_setup.sql on the branch" "db/minimart_setup.sql" "$BOUT"
has "  contained" "contained: everything this server runs" "$BOUT"
echo change >> "$SH/README"
runb 0.1; has "0.1 counts a modified tracked file" "tracked files modified: 1" "$BOUT"
runb 0.2; has "0.2 REFUSES with a modified tracked file" "REFUSED: tracked files are modified" "$BOUT"
check "  and stays on the old branch" "postgres-oltp-migration" "$(gitq rev-parse --abbrev-ref HEAD)"
gitq checkout -q README
echo extra > "$SH/extra.txt"; gitq add extra.txt; gitq commit -q -m "server-only commit"
runb 0.1; has "0.1 detects a commit the branch lacks" "NOT contained" "$BOUT"
runb 0.2; has "0.2 REFUSES when the server has commits origin/minimart-migration lacks" "REFUSED: this branch has commits" "$BOUT"
gitq reset -q --hard HEAD~1
runb 0.2; check "0.2 switches (exit 0)" 0 "$BRC"
has "  script syntax OK" "script syntax OK" "$BOUT"
check "  now on minimart-migration" "minimart-migration" "$(gitq rev-parse --abbrev-ref HEAD)"
install_wrappers

section "phase 0: containers, network, ports, app settings, inspect"
runb 0.3; check "0.3 exit" 0 "$BRC"
has "  lists mmi-postgres" "mmi-postgres" "$BOUT"
has "  lists the app container with compose project and service" "minimart-app-1	minimart	app	/opt/minimart" "$BOUT"
has "  shows free disk" "Filesystem" "$BOUT"
runb 0.4; has "0.4 old container details (image, state, restart policy)" "image=postgres:16-alpine state=running" "$BOUT"
has "  data volume" "minimart_pgdata" "$BOUT"
has "  public port mapping" "5432/tcp -> 0.0.0.0:5433" "$BOUT"
has "  mmi-postgres is on postgres_net" "network=postgres_net" "$BOUT"
has "  who listens on 5433" "0.0.0.0:5433" "$BOUT"
runb 0.5; check "0.5 exit" 0 "$BRC"
has "  host shown" "PGHOST=minimart-postgres-1" "$BOUT"
has "  user shown" "PGUSER=mmadmin" "$BOUT"
has "  password masked with its length" "PGPASSWORD=<hidden, 13 chars>" "$BOUT"
has "  URL password masked, query stripped" "DATABASE_URL=postgresql://mmadmin:***@minimart-postgres-1:5432/minimartdb" "$BOUT"
has "  compose structural lines" "container_name: minimart-postgres-1" "$BOUT"
has "  compose password masked" "POSTGRES_PASSWORD=<hidden, 13 chars>" "$BOUT"
has "  files that mention the old database" "docker-compose.yml" "$BOUT"
hasnt "  no old password anywhere" "S3cretOldPw99" "$BOUT"
hasnt "  no session secret" "zzTopSecretValue" "$BOUT"
hasnt "  no api key" "abcSecretKey" "$BOUT"
runb 0.6; check "0.6 exit (the block ends with greps)" 0 "$BRC"
has "  exit=0 of --inspect" "exit=0" "$BOUT"
has "  section: Tables" "== Tables (exact row counts) ==" "$BOUT"
has "  section: Who is connected" "== Who is connected to this database right now ==" "$BOUT"
has "  section: Time columns" "== Time columns" "$BOUT"
check "  file written, mode 600, no ERROR" "600|0" "$(stat -f %Lp "$WORK/root/minimart_inspect.txt" 2>/dev/null || stat -c %a "$WORK/root/minimart_inspect.txt")|$(grep -c ERROR "$WORK/root/minimart_inspect.txt")"

section "phase 1: backup of the old database"
runb 1.1; has "1.1 prints sizes" "old database:" "$BOUT"
has "  OK line" "OK $WORK/backups/minimart/pre_migration_" "$BOUT"
has "  exit=0" "exit=0" "$BOUT"
NREL=$(sed -n 's/^old database minimartdb holds \([0-9]*\) table(s)$/\1/p' <<< "$BOUT")
NBASE=$(OP -c "select count(*) from information_schema.tables where table_schema not in ('pg_catalog','information_schema') and table_type = 'BASE TABLE'")
has "  counts.tsv line" "counts.tsv: $NREL table(s)" "$BOUT"
hasre "  says how many tables the old database holds" "^old database minimartdb holds [0-9]+ table\(s\)$" "$BOUT"
runb 1.2; check "1.2 exit" 0 "$BRC"
has "  old.dump checksum" "old.dump: OK" "$BOUT"
has "  schema.sql checksum" "schema.sql: OK" "$BOUT"
has "  counts.tsv checksum" "counts.tsv: OK" "$BOUT"
has "  COMPLETE listed" "COMPLETE" "$BOUT"
has "  table data entries" "table data entries in old.dump:" "$BOUT"
hasre "  totals" "^$NREL tables, [0-9]+ rows in counts.tsv" "$BOUT"
check "  seven files in the directory" 7 "$(ls -1 "$(ls -1d "$WORK"/backups/minimart/pre_migration_*/ | tail -n 1)" | wc -l | tr -d ' ')"

section "phase 2: passwords, roles, rehearsal"
printf 'SESSION_SECRET=x\nPG_APP_PASSWORD=abc' > "$SH/.env"
runb 2.1; check "2.1 exit" 0 "$BRC"
has "  app password length 32" "MINIMART_APP_PASSWORD 32" "$BOUT"
has "  ro password length 32" "MINIMART_RO_PASSWORD 32" "$BOUT"
APP_PW_R=$(grep '^MINIMART_APP_PASSWORD=' "$SH/.env" | cut -d= -f2-); RO_PW_R=$(grep '^MINIMART_RO_PASSWORD=' "$SH/.env" | cut -d= -f2-)
hasre "  passwords are alphanumeric" '^[A-Za-z0-9]{32}$' "$APP_PW_R"
has "  .env keeps the existing lines (also after a missing newline)" "PG_APP_PASSWORD=abc" "$(cat "$SH/.env")"
check "  .env mode 600" 600 "$(stat -f %Lp "$SH/.env" 2>/dev/null || stat -c %a "$SH/.env")"
runb 2.1; check "2.1 again keeps the passwords (idempotent)" "$APP_PW_R|$RO_PW_R" "$(grep '^MINIMART_APP_PASSWORD=' "$SH/.env" | cut -d= -f2-)|$(grep '^MINIMART_RO_PASSWORD=' "$SH/.env" | cut -d= -f2-)"
check "  one line per password" 2 "$(grep -c '^MINIMART_' "$SH/.env")"
check "  backup of the original .env" "SESSION_SECRET=x" "$(head -n 1 "$WORK/root/env_before_minimart")"
sed -i.bak 's/^MINIMART_RO_PASSWORD=.*/MINIMART_RO_PASSWORD=short/' "$SH/.env"; rm -f "$SH/.env.bak"
runb 2.1; check "2.1 replaces an invalid (short) password" "1|32" "$(grep -c '^MINIMART_RO_PASSWORD=' "$SH/.env")|$(grep '^MINIMART_RO_PASSWORD=' "$SH/.env" | cut -d= -f2- | tr -d '\n' | wc -c | tr -d ' ')"
RO_PW_R=$(grep '^MINIMART_RO_PASSWORD=' "$SH/.env" | cut -d= -f2-)
runb 2.2; check "2.2 exit" 0 "$BRC"
has "  old sorts line" "old server sorts:" "$BOUT"
has "  new sorts line" "mmi-postgres sorts:" "$BOUT"
hasre "  old collate line" "old collate / ctype:  C / C" "$BOUT"
hasre "  new default line" "mmi-postgres default: en_US" "$BOUT"
mv "$SH/.env" "$SH/.env.hold"
runb 2.3; has "2.3 does not run without the passwords" "NOT RUN" "$BOUT"
check "  nothing created" 0 "$(NPG -c "select count(*) from pg_database where datname = 'minimart'")"
mv "$SH/.env.hold" "$SH/.env"
runb 2.3; check "2.3 exit" 0 "$BRC"
has "  exit=0" "exit=0" "$BOUT"
hasre "  database row: minimart owned by minimart_owner, no tables" "minimart +\| +minimart_owner +\|" "$BOUT"
hasre "  roles: minimart_app can log in, limit 50" "minimart_app +\| t +\| f +\| +50" "$BOUT"
hasre "  roles: minimart_ro limit 20 and settings" "minimart_ro +\| t +\| f +\| +20 \| TimeZone=UTC" "$BOUT"
has "  read-only default listed" "default_transaction_read_only=on" "$BOUT"
hasnt "  app password not printed" "$APP_PW_R" "$BOUT"
hasnt "  ro password not printed" "$RO_PW_R" "$BOUT"
check "  stored password is the one from .env (SCRAM)" "SCRAM-SHA-256" "$(NPG -c "select left(rolpassword, 13) from pg_authid where rolname = 'minimart_app'")"
NP -c "create table zz_probe(a int)" >/dev/null
runb 2.4; has "2.4 REFUSES when minimart has a table" "REFUSED: minimart has 1 relation(s)" "$BOUT"
check "  database still there with its table" 1 "$(NP -c "select count(*) from pg_tables where tablename = 'zz_probe'")"
NP -c "drop table zz_probe" >/dev/null
NPG -c "comment on database minimart is 'minimart-migration: cutover-complete 2026-01-01T00:00:00Z'" >/dev/null
runb 2.4; has "2.4 REFUSES when the migration marker is set" "REFUSED: minimart has 0 relation(s) and marker 'minimart-migration: cutover-complete" "$BOUT"
NPG -c "comment on database minimart is null" >/dev/null
runb 2.4; has "2.4 drops the empty database" "minimart dropped (it was empty)" "$BOUT"
check "  gone" 0 "$(NPG -c "select count(*) from pg_database where datname = 'minimart'")"
runb 2.3 1 's/^COLLATE=.*/COLLATE=C/'; check "2.3 with COLLATE=C exit" 0 "$BRC"
check "  database created with collation C" "C" "$(NPG -c "select datcollate from pg_database where datname = 'minimart'")"
runb 2.3 1 's/^COLLATE=.*/COLLATE=C/'; check "2.3 is repeatable (idempotent)" 0 "$BRC"
runb 2.3 1 's/^COLLATE=.*/COLLATE=C/' 's/^DB_TIMEZONE=.*/DB_TIMEZONE=UTC/'; check "2.3 with DB_TIMEZONE=UTC exit" 0 "$BRC"
check "  the timezone is stored on the database" "{TimeZone=UTC}" "$(NPG -c "select setconfig from pg_db_role_setting s join pg_database d on d.oid = s.setdatabase where d.datname = 'minimart' and s.setrole = 0")"
NPG -c "alter database minimart reset timezone" >/dev/null
check "  and the documented undo removes it" "0" "$(NPG -c "select count(*) from pg_db_role_setting s join pg_database d on d.oid = s.setdatabase where d.datname = 'minimart'")"
runb 2.5; check "2.5 exit" 0 "$BRC"
has "  exit=0" "exit=0" "$BOUT"
has "  preflight" "== Preflight ==" "$BOUT"
has "  VERIFY OK" "VERIFY OK: all checks passed" "$BOUT"
has "  Timing section" "== Timing ==" "$BOUT"
has "  expected downtime line" "expected cutover downtime: about" "$BOUT"
has "  REHEARSAL OK" "REHEARSAL OK" "$BOUT"
has "  scratch database dropped" "scratch database minimart_rehearsal dropped" "$BOUT"
has "  sequence repair notice" "reset from 5 to 200" "$BOUT"
hasre "  sort note or warning (documented in 2.2/2.5)" "note: collation names differ|WARNING: text SORT ORDER differs|^new: " "$BOUT"
check "  minimart untouched (no tables)" 0 "$(NP -c "select count(*) from pg_tables where schemaname not in ('pg_catalog','information_schema')")"
check "  scratch database gone" 0 "$(NPG -c "select count(*) from pg_database where datname = 'minimart_rehearsal'")"
runb 2.6; check "2.6 exit" 0 "$BRC"
hasre "  database work line" "database work in the last rehearsal: [0-9]+ s" "$BOUT"
hasre "  expected downtime line" "expected downtime: about [0-9]+ minutes" "$BOUT"
has "  timing lines from the log" "REHEARSAL OK" "$BOUT"
has "  dump timing in the log" " dump: " "$BOUT"

section "phase 3: cutover"
old_app_up
runb 3.1 1 's/^APP_CONTAINERS=.*/APP_CONTAINERS="mmi-postgres"/'
has "3.1 refuses a database container as APP_CONTAINERS" "STOP: mmi-postgres is not the minimart app" "$BOUT"
has "  says NOT STOPPED" "NOT STOPPED" "$BOUT"
runb 3.1 1 's/^APP_CONTAINERS=.*/APP_CONTAINERS=""/'
has "3.1 refuses an empty APP_CONTAINERS" "STOP: APP_CONTAINERS is empty" "$BOUT"
runb 3.1 1 's/^APP_CONTAINERS=.*/APP_CONTAINERS="no-such-app"/'
has "3.1 refuses an unknown container" "STOP: no-such-app is not a running container" "$BOUT"
check "  the real app container is still running after the refusals" 1 "$([ -e "$WORK/mock/minimart-app-1/running" ] && echo 1 || echo 0)"
runb 3.1; check "3.1 exit" 0 "$BRC"
has "  docker stop echoes the container" "minimart-app-1" "$BOUT"
has "  no connections left" "connections left on the old database: 0" "$BOUT"
check "  the app container is stopped" 0 "$([ -e "$WORK/mock/minimart-app-1/running" ] && echo 1 || echo 0)"
OP -c "alter database minimartdb set work_mem to '8MB'" >/dev/null
runb 3.2; check "3.2 exit" 0 "$BRC"
has "  warns about settings stored on the old database" "settings stored on it that a dump does NOT carry" "$BOUT"
has "  exit=0" "exit=0" "$BOUT"
has "  guards" "old database has no other connections: app is stopped" "$BOUT"
has "  VERIFY OK" "VERIFY OK: all checks passed" "$BOUT"
has "  CUTOVER OK" "CUTOVER OK minimart from minimartdb@minimart-postgres-1" "$BOUT"
has "  final dump line" "final dump kept at $WORK/backups/minimart/cutover_" "$BOUT"
has "  next step line" "Next: point the app at mmi-postgres / minimart as minimart_app" "$BOUT"
has "  old container untouched message" "The old container is still running and untouched" "$BOUT"
check "  marker cutover-complete" 1 "$(NPG -c "select count(*) from pg_database d where datname = 'minimart' and shobj_description(d.oid, 'pg_database') like 'minimart-migration: cutover-complete %'")"
check "  data arrived: products 1000" 1000 "$(NP -c "select count(*) from products")"
check "  database collation is the one chosen in 2.3 (C)" C "$(NPG -c "select datcollate from pg_database where datname = 'minimart'")"
runb 3.2; has "3.2 again after success is refused" "already completed" "$BOUT"
has "  exit=3" "exit=3" "$BOUT"
runb 3.2a; check "3.2a exit" 0 "$BRC"
has "  prints the old database-wide setting as a statement for minimart" "ALTER DATABASE minimart SET work_mem TO '8MB';" "$BOUT"
has "  list settings (search_path) are NOT quoted as one string" "ALTER DATABASE minimart SET search_path TO public, audit;" "$BOUT"
has "  shows the settings minimart has now" "settings of minimart now:" "$BOUT"
runb 3.2b; has "3.2b echoes the statement" "ALTER DATABASE minimart SET work_mem TO '8MB';" "$BOUT"
has "  exit=0" "exit=0" "$BOUT"
check "  the settings are on the new database (as on the old one)" "$(NPG -c "select string_agg(c, '|' order by c) from pg_db_role_setting s join pg_database d on d.oid = s.setdatabase, unnest(s.setconfig) c where d.datname = 'minimart' and s.setrole = 0")" "$(OP -c "select string_agg(c, '|' order by c) from pg_db_role_setting s join pg_database d on d.oid = s.setdatabase, unnest(s.setconfig) c where d.datname = 'minimartdb' and s.setrole = 0")"
check "  and the search_path really works for a new session" "5" "$(NP -c "select count(*) from categories")"
runb 3.2a; has "3.2a now lists it under settings of minimart" "(database): work_mem=8MB" "$BOUT"
runb 3.2b; check "3.2b is repeatable (exit 0)" 0 "$BRC"
NPG -c "alter database minimart reset all" >/dev/null
OP -c "alter database minimartdb reset all" >/dev/null
runb 3.2b; has "3.2b with no settings on the old database does nothing" "nothing to apply" "$BOUT"
runb 3.3a; has "3.3a backs up .env" "backed up $APP/.env" "$BOUT"
has "  backs up the compose file" "backed up $APP/docker-compose.yml" "$BOUT"
runb 3.3a; has "3.3a again keeps the first backup" "backup already exists, kept: $APP/.env.bak_" "$BOUT"
check "  exactly one .bak per file" "1|1" "$(ls "$APP"/.env.bak_* | wc -l | tr -d ' ')|$(ls "$APP"/docker-compose.yml.bak_* | wc -l | tr -d ' ')"
runb 3.3a 1 's#^FILES=.*#FILES="'$APP'/.env '$APP'/nothing.yml"#'; has "3.3a reports a MISSING file" "MISSING $APP/nothing.yml" "$BOUT"
mkdir -p "$WORK/hold"; mv "$APP"/.env.bak_* "$WORK/hold/"
runb 3.3b; has "3.3b refuses without the backup" "STOP: no backup of $APP/.env yet (3.3a)" "$BOUT"
check "  and did not change the file" "PGHOST=minimart-postgres-1" "$(grep '^PGHOST=' "$APP/.env")"
mv "$WORK"/hold/.env.bak_* "$APP/"
runb 3.3b; check "3.3b exit" 0 "$BRC"
has "  host" "PGHOST=mmi-postgres" "$BOUT"
has "  port" "PGPORT=5432" "$BOUT"
has "  database" "PGDATABASE=minimart" "$BOUT"
has "  user" "PGUSER=minimart_app" "$BOUT"
has "  password hidden and equal to MINIMART_APP_PASSWORD" "PGPASSWORD=<hidden, 32 chars, equals MINIMART_APP_PASSWORD>" "$BOUT"
hasnt "  password not printed" "$APP_PW_R" "$BOUT"
check "  file: values replaced in place, no duplicates" "1|1|1|1|1" "$(for k in PGHOST PGPORT PGDATABASE PGUSER PGPASSWORD; do grep -c "^$k=" "$APP/.env"; done | tr '\n' '|' | sed 's/|$//')"
check "  file: unrelated lines kept" "SESSION_SECRET=zzTopSecretValue|OTHER=1" "$(grep -E '^(SESSION_SECRET|OTHER)=' "$APP/.env" | tr '\n' '|' | sed 's/|$//')"
check "  file: the new password is in the file" "$APP_PW_R" "$(grep '^PGPASSWORD=' "$APP/.env" | cut -d= -f2-)"
check "  env file mode stays private" 600 "$(stat -f %Lp "$APP/.env" 2>/dev/null || stat -c %a "$APP/.env")"
# URL variant: start again from the backup, app reads one url
cp -p "$(ls -1 "$APP"/.env.bak_* | head -n 1)" "$APP/.env"; echo 'DATABASE_URL=postgresql://mmadmin:S3cretOldPw99@minimart-postgres-1:5432/minimartdb' >> "$APP/.env"
runb 3.3b 1 's/^HOST_VAR=.*/HOST_VAR=; PORT_VAR=; DB_VAR=; USER_VAR=; PASS_VAR=/' 's/^URL_VAR=.*/URL_VAR=DATABASE_URL/'
has "3.3b URL variant prints the masked URL" "DATABASE_URL=postgresql://minimart_app:***@mmi-postgres:5432/minimart" "$BOUT"
hasnt "  no password in the output" "$APP_PW_R" "$BOUT"
check "  file has the real URL once" "1|postgresql://minimart_app:$APP_PW_R@mmi-postgres:5432/minimart" "$(grep -c '^DATABASE_URL=' "$APP/.env")|$(grep '^DATABASE_URL=' "$APP/.env" | cut -d= -f2-)"
check "  PGHOST untouched in the URL variant" "PGHOST=minimart-postgres-1" "$(grep '^PGHOST=' "$APP/.env")"
cp -p "$(ls -1 "$APP"/.env.bak_* | head -n 1)" "$APP/.env"
runb 3.3b >/dev/null; has "3.3b final run (separate variables) again" "PGPASSWORD=<hidden, 32 chars, equals MINIMART_APP_PASSWORD>" "$BOUT"
new_app_up
runb 3.4b; check "3.4b exit" 0 "$BRC"
hasre "  a minimart_app session on the new database" "^minimart_app\|[^|]*\|[^|]*\|(idle|active)" "$BOUT"
has "  nothing on the old database" "connections still open on the OLD database: 0" "$BOUT"
runb 3.4c 1; has "3.4c grants the escape hatch" "GRANT" "$BOUT"
check "  minimart_app is now a member of minimart_owner" "t" "$(echo "$BOUT" | tail -n 1)"
runb 3.4c 2; has "3.4c undo revokes it" "REVOKE" "$BOUT"
check "  no longer a member" "f" "$(echo "$BOUT" | tail -n 1)"
runb 3.6; check "3.6 minimart_ro has no table privilege yet" "0" "$(echo "$BOUT" | tail -n 1)"

section "phase 4: old container"
runb 4.1; check "4.1 exit" 0 "$BRC"
has "  exit=0" "exit=0" "$BOUT"
has "  VERIFY OK before the app wrote anything" "VERIFY OK: all checks passed" "$BOUT"
NP -c "update categories set name = name || '-x' where category_id = (select min(category_id) from categories)" >/dev/null
runb 4.1; has "4.1 after a write to minimart: FAIL lines and exit=1 (documented as normal)" "exit=1" "$BOUT"
has "  names the changed table" "FAIL  public.categories" "$BOUT"
has "  says VERIFY FAILED" "VERIFY FAILED" "$BOUT"
NP -c "update categories set name = left(name, length(name) - 2) where category_id = (select min(category_id) from categories)" >/dev/null
old_app_up
runb 4.2; has "4.2 refuses while the old database has a connection" "REFUSED: connections on the old database: '1'" "$BOUT"
check "  old container still running" 1 "$([ -e "$WORK/mock/minimart-postgres-1/running" ] && echo 1 || echo 0)"
kill "$(cat "$WORK/app.pid")" 2>/dev/null; OP -c "select pg_terminate_backend(pid) from pg_stat_activity where application_name = 'minimart-app-sim'" >/dev/null; sleep 2
runb 4.2; check "4.2 exit" 0 "$BRC"
has "  stopped" "state=exited restart=unless-stopped" "$BOUT"
has "  final dump named" "final dump kept: $WORK/backups/minimart/cutover_" "$BOUT"
check "  old container stopped (not removed)" "0|1" "$([ -e "$WORK/mock/minimart-postgres-1/running" ] && echo 1 || echo 0)|$([ -d "$WORK/mock/minimart-postgres-1" ] && echo 1 || echo 0)"
check "  restart policy changed from always" "unless-stopped" "$(cat "$WORK/mock/minimart-postgres-1/restart")"
runb 4.2 >/dev/null 2>&1; has "4.2 pasted again with the old container stopped does not crash into a half state" "REFUSED" "$BOUT"

section "phase 6: nightly backup"
runb 6.1; check "6.1 exit" 0 "$BRC"
has "  syntax OK" "script syntax OK" "$BOUT"
hasre "  OK line" "OK $WORK/backups/minimart/minimart_[0-9_]+\.dump \([0-9.]+[KMG]?, [0-9]+ tables\)" "$BOUT"
has "  exit=0" "exit=0" "$BOUT"
check "  dump mode 600" 600 "$(stat -f %Lp "$(ls -1t "$WORK"/backups/minimart/minimart_*.dump | head -n 1)" 2>/dev/null || stat -c %a "$(ls -1t "$WORK"/backups/minimart/minimart_*.dump | head -n 1)")"
check "  the pre_migration and cutover directories are still there" "1|1" "$(ls -1d "$WORK"/backups/minimart/pre_migration_*/ | wc -l | tr -d ' ')|$(ls -1d "$WORK"/backups/minimart/cutover_*/ | wc -l | tr -d ' ')"
# 6.2 is notest: run it here only in the sandbox, with /etc redirected, to check what it writes
runb 6.2 1 "s#/etc/cron.d#$WORK/etc/cron.d#g" "s#/etc/logrotate.d#$WORK/etc/logrotate.d#g"; RAN=$(echo "$RAN" | sed 's/ 6.2_1//')
has "6.2 (sandbox) installs" "installed" "$BOUT"
check "  cron line" "45 2 * * * root $SH/scripts/minimart_backup.sh >> $WORK/out/minimart-pg-backup.log 2>&1" "$(grep '^45 ' "$WORK/etc/cron.d/minimart-pg-backup")"
check "  cron file has SHELL and PATH" "2" "$(grep -cE '^(SHELL|PATH)=' "$WORK/etc/cron.d/minimart-pg-backup")"
has "  logrotate stanza" "monthly" "$(cat "$WORK/etc/logrotate.d/minimart-pg-backup")"
check "  logrotate names the log" "$WORK/out/minimart-pg-backup.log {" "$(head -n 1 "$WORK/etc/logrotate.d/minimart-pg-backup")"
rm -f "$WORK/etc/cron.d/minimart-pg-backup"
env -i PATH="$PATH" HOME="$HOME" bash "$SH/scripts/minimart_backup.sh" >> "$WORK/out/minimart-pg-backup.log" 2>&1
runb 6.3; has "6.3 morning check: BACKUP OK" "BACKUP OK" "$BOUT"
echo "garbage line" >> "$WORK/out/minimart-pg-backup.log"
runb 6.3; has "6.3 notices a log that does not end in OK" "BACKUP PROBLEM" "$BOUT"
runb 6.4; has "6.4 restore exit 0" "restore exit=0" "$BOUT"
hasre "  same number of tables" "tables in the dump copy: $NBASE +in live minimart: $NBASE" "$BOUT"
has "  row counts identical" "row counts identical" "$BOUT"
check "  scratch database exists until 6.5" 1 "$(NPG -c "select count(*) from pg_database where datname = 'minimart_restore_test'")"
runb 6.4; has "6.4 again refuses while the scratch database exists" "STOP: minimart_restore_test already exists" "$BOUT"
runb 6.5; has "6.5 drops it" "dropped minimart_restore_test" "$BOUT"
check "  only minimart remains" "minimart" "$(echo "$BOUT" | tail -n 1)"

section "phase 7: rollback"
runb 7.1; check "7.1 exit" 0 "$BRC"
has "  header" "Manual rollback of the minimart migration. Nothing below runs automatically." "$BOUT"
has "  situations" "Situation C" "$BOUT"
has "  never restart mmi-postgres" "Never restart or remove mmi-postgres" "$BOUT"
runb 7.6; has "7.6 refuses without an export" "REFUSED: no export" "$BOUT"
check "  minimart still exists" 1 "$(NPG -c "select count(*) from pg_database where datname = 'minimart'")"
runb 7.2; hasre "7.2 writes an export" "^OK $WORK/backups/minimart/rollback_export_[0-9_]+\.dump \(" "$BOUT"
check "  export file exists and is a valid archive" "ok" "$("$PG15/pg_restore" --list "$(ls -1t "$WORK"/backups/minimart/rollback_export_*.dump | head -n 1)" >/dev/null 2>&1 && echo ok || echo bad)"
runb 7.6; has "7.6 refuses while the old container is stopped" "REFUSED: the old container is not running" "$BOUT"
echo "garbage" > "$APP/.env"
runb 7.3 2; has "7.3 step 2 restores the original env file" "restored $APP/.env from $APP/.env.bak_" "$BOUT"
check "  content equals the original" "$(cat "$WORK/env_orig")" "$(cat "$APP/.env")"
check "  the edited copy is kept" 1 "$(ls "$APP"/.env.after_cutover_* | wc -l | tr -d ' ')"
check "  the compose file too" 1 "$(ls "$APP"/docker-compose.yml.after_cutover_* | wc -l | tr -d ' ')"
mv "$APP/.env.bak_"* "$WORK/hold/"
runb 7.3 2; has "7.3 step 2 says NO BACKUP when there is none" "NO BACKUP for $APP/.env" "$BOUT"
mv "$WORK"/hold/.env.bak_* "$APP/"
runb 7.4; has "7.4 old container accepts connections" "accepting connections" "$BOUT"
has "  state running" "state=running" "$BOUT"
check "  old container running again" 1 "$([ -e "$WORK/mock/minimart-postgres-1/running" ] && echo 1 || echo 0)"
kill "$(cat "$WORK/app2.pid")" 2>/dev/null; NP -c "select pg_terminate_backend(pid) from pg_stat_activity where application_name = 'minimart-app-sim'" >/dev/null; sleep 2
runb 7.6; check "7.6 exit" 0 "$BRC"
has "  dropped" "DROP DATABASE" "$BOUT"
check "  minimart is gone from mmi-postgres" 0 "$(NPG -c "select count(*) from pg_database where datname = 'minimart'")"
check "  the three roles stay" 3 "$(NPG -c "select count(*) from pg_roles where rolname like 'minimart\_%'")"
check "  the old database is untouched" 1000 "$(OP -c "select count(*) from products")"

# ── global checks ────────────────────────────────────────────────────────────
section "global checks"
for f in "$BLK"/*.sh; do
  b=$(basename "$f" .sh)
  if [ -e "$BLK/$b.notest" ]; then NOTESTED="${NOTESTED:-} $b"; continue; fi
  case " $RAN " in *" $b "*) ;; *) bad "block $b is not run by this test and not marked notest"; ;; esac
done
ok "every non-notest block was executed ($(echo $RAN | wc -w | tr -d ' ') runs)"
echo "  notest blocks (linted and syntax checked only):$NOTESTED"
check "no password in any captured output or in the docker log" "0" "$(grep -rlF -e "$APP_PW_R" -e "$RO_PW_R" "$WORK/out" 2>/dev/null | wc -l | tr -d ' ')"
check "no old-app canary secret in any captured output" "0" "$(grep -rlF -e S3cretOldPw99 -e zzTopSecretValue -e abcSecretKey "$WORK/out" 2>/dev/null | wc -l | tr -d ' ')"
check "docker was never asked to rm, restart, prune or run compose" "0" "$(grep -cE '^docker (rm|restart|container|system|volume|compose)' "$WORK/out/docker.log")"
check "mmi-postgres was never stopped" "0" "$(grep -cE '^docker stop mmi-postgres' "$WORK/out/docker.log")"
check "only the app container and the old container were stopped" "docker stop minimart-app-1|docker stop minimart-postgres-1" "$(grep -E '^docker stop' "$WORK/out/docker.log" | sort -u | tr '\n' '|' | sed 's/|$//')"
check "no other database on mmi-postgres was touched" "0" "$(NPG -c "select count(*) from pg_database where datname not in ('postgres','template0','template1')")"

world_summary
