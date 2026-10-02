# Runbook: Minimart, move its database into `mmi-postgres`

Run on **76.13.19.246** as **root**, top to bottom. Say "3.2 failed" and paste the
output of that step only.

```
OLD   minimart-postgres-1   (own container, port 5433 public)
        |   pg_dump / pg_restore, verified table by table
        v
NEW   mmi-postgres / database `minimart`   (roles: minimart_owner, minimart_app, minimart_ro)
```

The old container is **never deleted** by this runbook. It is stopped in phase 4,
and until you decide otherwise it is the rollback. `mmi-postgres` is never
restarted, and the databases `procurement` and `hauling_tracker` are never touched.

Downtime is already scheduled, so the cutover (phase 3) is ready to run. The
rehearsal (phase 2) comes first: its measured timing becomes the expected downtime.

| Phase | What | Minutes | Minimart app |
|---|---|---|---|
| 0 | Read-only discovery: how the app connects, who uses port 5433, inspect the old database | 20 | up |
| 1 | Backup of the OLD database to `/opt/backups/minimart/pre_migration_<ts>/` | 5 + dump time | up |
| 2 | Passwords, roles and the empty `minimart` database on mmi-postgres, then the rehearsal | 15 + rehearsal time | up |
| 3 | Cutover: stop the app, final dump, restore, verify, repoint the app, start, browser test | rehearsal time + about 15 | **down from 3.1 until 3.4a** |
| 4 | Stop (not delete) the old container, after you have used the new database for the time you agreed | 5 | up |
| 5 | Close public port 5433 (your decision, separate) | 10 | up |
| 6 | Nightly backup of `minimart`, cron and log rotation, test restore | 15 | up |
| 7 | Rollback (only if needed) | 15 | down while you do it |

**How to use this file.** Paste **one block at a time**. Never paste old terminal
output back into the shell (the lines under "Expected" are not commands). Every
block starts with `cd /opt/purchasing_data` and defines its own helper functions,
so it works in a fresh SSH session. Nothing here prints a password: they are
generated on the server, read from files by the commands, and sent on stdin.

**STOP** means: do not run the next step. Do what the STOP line says (usually
nothing, or one undo command), then paste the output into Claude.

Blocks with names in capital letters at the top (`APP_CONTAINERS=...`,
`SERVICE=...`) contain **values you must check against phase 0**. Edit that line in
the paste if your server differs. The blocks refuse to run when the value is
wrong, they do not guess.

**Things never to run** (during this work or after it):

- `docker rm`, `docker container prune`, `docker system prune`, `docker volume rm`,
  `docker volume prune`: they delete the old container or its data volume, which is the rollback.
- `docker compose down` (with or without `-v`) in `/opt/minimart`: it removes
  `minimart-postgres-1` together with the app.
- a plain `docker compose up -d` in `/opt/minimart` after phase 3: it starts the old
  database again through `depends_on` and puts the app back on the old network. Always
  use the exact command in 3.4a (`--no-deps` and both `-f` files).
- `docker stop mmi-postgres`, `docker restart mmi-postgres`, any change to its
  `pg_hba.conf` or settings: procurement and hauling run on it.
- `DROP DATABASE` on anything but `minimart`, `minimart_rehearsal` and
  `minimart_restore_test`. Never anything in `procurement` or `hauling_tracker`.
- `docker inspect` without `-f`, `docker exec ... printenv`, `env`,
  `docker compose config` and `cat .env`: they print passwords. The blocks here use formats
  that cannot.
- `git stash pop`.

---

## Phase 0: Discovery (app up, nothing changes)

### 0.1 Which branch is the server on?

```bash
cd /opt/purchasing_data
git fetch origin
echo "branch: $(git rev-parse --abbrev-ref HEAD)"
echo "tracked files modified: $(git status --porcelain --untracked-files=no | wc -l | tr -d ' ')"
git ls-tree --name-only origin/minimart-migration scripts/minimart_migrate.sh scripts/minimart_backup.sh db/minimart_setup.sql
git merge-base --is-ancestor HEAD origin/minimart-migration && echo "contained: everything this server runs is in origin/minimart-migration" || echo "NOT contained"
```

Expected: the current branch name, `tracked files modified: 0`, the three file
names, `contained: ...`.

**STOP** (nothing to undo) if the count is not 0, a file name is missing (the
branch has not been pushed), or it says `NOT contained` (the server runs commits
that `minimart-migration` lacks; switching would remove them). Paste the output.

### 0.2 Switch to the branch (refuses on local changes)

```bash
cd /opt/purchasing_data
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
  echo "REFUSED: tracked files are modified. Paste 'git status' into Claude. Nothing changed."
elif ! git merge-base --is-ancestor HEAD origin/minimart-migration; then
  echo "REFUSED: this branch has commits that origin/minimart-migration lacks. Nothing changed."
else
  git checkout -B minimart-migration origin/minimart-migration
  git log -1 --oneline
  chmod +x scripts/minimart_migrate.sh scripts/minimart_backup.sh
  bash -n scripts/minimart_migrate.sh && bash -n scripts/minimart_backup.sh && echo "script syntax OK"
  ls -l db/minimart_setup.sql
fi
```

Expected: `Switched to ...`, a commit line, `script syntax OK`, the setup file listed.
From now on the server runs `minimart-migration`. Do not `git pull` another
branch or run `deploy.sh` for procurement before you have told Claude: check it first.

**STOP** on `REFUSED`. Nothing was changed.

### 0.3 Containers, compose labels, free disk

```bash
cd /opt/purchasing_data
docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'
echo
docker ps -a --format '{{.Names}}\t{{.Label "com.docker.compose.project"}}\t{{.Label "com.docker.compose.service"}}\t{{.Label "com.docker.compose.project.working_dir"}}' | grep -i minimart
echo
df -h /opt/backups 2>/dev/null || df -h /opt
ls -ld /opt/minimart
```

Expected: a table in which `mmi-postgres` and `minimart-postgres-1` are `Up`, plus
the minimart app container(s); then lines like
`minimart-app-1   minimart   app   /opt/minimart` (container, compose project,
service, directory). **Write down**: the app container name(s) (used as
`APP_CONTAINERS`), the compose project (`PROJECT`), the app's service (`SERVICE`).
Free disk: you need more than three times the database size under `/opt/backups`
(the size is in 0.6; 1.1 checks it again).

**STOP** if `mmi-postgres` or `minimart-postgres-1` is not `Up`, or no app container
is listed. Nothing to undo.

### 0.4 The old container and who listens on 5433

Every command uses a `-f` format, so no environment variable (no password) is printed.

```bash
cd /opt/purchasing_data
OLD=minimart-postgres-1
docker inspect -f 'image={{.Config.Image}} state={{.State.Status}} started={{.State.StartedAt}} restart={{.HostConfig.RestartPolicy.Name}}' "$OLD"
docker inspect -f '{{range .Mounts}}{{.Type}} {{.Name}} {{.Source}} -> {{.Destination}}{{println}}{{end}}' "$OLD"
docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}network={{$k}} ip={{$v.IPAddress}}{{println}}{{end}}' "$OLD"
docker port "$OLD"
echo "--- mmi-postgres networks:"
docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}network={{$k}} ip={{$v.IPAddress}}{{println}}{{end}}' mmi-postgres
echo "--- listening on 5433:"
ss -ltnp | grep -E ':5433( |$)'
```

Expected, in order: the image (for example `postgres:16-alpine`), `state=running`, the
restart policy (`always`, `unless-stopped` or `no`); the data volume (its name and
path: this is the data, it is never deleted); the old network
(`minimart_default` or similar); `5432/tcp -> 0.0.0.0:5433` (a public port); the
networks of `mmi-postgres` (it should list `postgres_net`); and a `LISTEN` line for
`0.0.0.0:5433`, normally owned by `docker-proxy`.

**STOP** if `mmi-postgres` is not on a network called `postgres_net` (3.3c uses
`MMI_PG_NETWORK` from `/opt/purchasing_data/.env`, the same network procurement uses: tell
Claude if they differ). Nothing to undo.

### 0.5 How does the app connect? (names and masked values only)

The two helpers print a variable only if its name looks like host, port, database,
user or URL. Anything that looks like a password, secret, token or key shows only its length,
and the password part of a URL is replaced by `***`.

```bash
cd /opt/purchasing_data
APP_DIR=/opt/minimart
APP_CONTAINERS="minimart-app-1"     # the app container name(s) from 0.3, space separated
conn_vars() { awk '
  BEGIN { q = sprintf("%c", 39) }
  { s = $0; sub(/^[ \t]*-?[ \t]*/, "", s); gsub(/"/, "", s); gsub(q, "", s)
    i = index(s, "="); j = index(s, ": "); sk = 1
    if (i == 0 || (j > 0 && j < i)) { i = j; sk = 2 }
    if (i == 0) next
    k = substr(s, 1, i - 1); v = substr(s, i + sk)
    if (k !~ /^[A-Za-z_][A-Za-z0-9_]*$/) next
    u = toupper(k)
    if (u ~ /(PASS|PWD|SECRET|TOKEN|KEY|CRED)/) { print k "=<hidden, " length(v) " chars>"; next }
    if (u !~ /(HOST|PORT|DB|DATABASE|USER|URL|URI|DSN|SCHEMA|SSL)/) next
    if (index(v, "://") > 0 && index(v, "@") > 0) {
      p = index(v, "://"); sch = substr(v, 1, p + 2); r = substr(v, p + 3); at = 0
      for (n = length(r); n > 0; n--) if (substr(r, n, 1) == "@") { at = n; break }
      cred = substr(r, 1, at - 1); tail = substr(r, at + 1); c = index(cred, ":")
      usr = (c > 0) ? substr(cred, 1, c - 1) : cred
      q = index(tail, "?"); if (q > 0) tail = substr(tail, 1, q - 1)
      v = sch usr ":***@" tail }
    print k "=" v }'; }
ls -la "$APP_DIR"
for c in $APP_CONTAINERS; do
  echo "--- connection settings seen inside $c"
  docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$c" | conn_vars
  echo "--- networks of $c"
  docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$c"
done
for f in "$APP_DIR"/.env "$APP_DIR"/*.env; do
  [ -f "$f" ] && { echo "--- $f"; conn_vars < "$f"; }
done
for f in "$APP_DIR"/docker-compose*.yml "$APP_DIR"/compose*.y*ml; do
  [ -f "$f" ] && { echo "--- $f"; grep -nE '^[[:space:]]*(depends_on|networks|env_file|container_name|image|ports|restart):|5433|^[[:space:]]+- "?[0-9]+:[0-9]+' "$f"; conn_vars < "$f"; }
done
echo "--- files that mention the old database:"
grep -rIlE '5433|minimart-postgres' "$APP_DIR" --exclude-dir=node_modules --exclude-dir=.git 2>/dev/null | head -n 20
```

Expected: a listing of `/opt/minimart`; then for the app container something like

```
PGHOST=minimart-postgres-1
PGPORT=5432
PGDATABASE=minimart
PGUSER=minimart
PGPASSWORD=<hidden, 16 chars>
```

(your names will differ: `DATABASE_URL=postgresql://minimart:***@minimart-postgres-1:5432/minimart`
is just as common), its networks, the same variables as they appear in the `.env` and
compose files, structural compose lines (`depends_on`, `networks`, `ports`), and the files that
mention the old database. **Write down** the exact variable names and which file defines
them (an env file, the compose `environment:` list, or an `env_file:`).

**STOP** if any password is visible in the output: do not paste it anywhere, tell
Claude only the variable name. Nothing to undo.

### 0.6 Inspect the old database (read-only)

Every session this opens is read-only. The report lists tables with exact row
counts, sizes, extensions, sequences, large objects, roles, sensitive-looking
columns, time columns and who is connected. It holds no passwords and no row data
(only timestamps as min/max of time columns).

```bash
cd /opt/purchasing_data
scripts/minimart_migrate.sh --inspect > /root/minimart_inspect.txt 2>&1; echo "exit=$?"
chmod 600 /root/minimart_inspect.txt
wc -l < /root/minimart_inspect.txt
grep -c 'ERROR' /root/minimart_inspect.txt
grep '^== ' /root/minimart_inspect.txt
```

Expected: `exit=0`, a line count (100 or more), `0`, and the section headings
`== Old database ==`, `== Server ==`, `== Tables (exact row counts) ==`, `== Totals ==`,
`== Extensions ...`, `== Sequences ...`, `== Large objects ==`, `== Other objects ...`,
`== Roles ...`, `== Columns that look sensitive ...`, `== Time columns ...`,
`== Who is connected to this database right now ==` and `== Read next ==`.

**STOP** on `exit` other than 0 or a non-zero ERROR count. If the message says it cannot
connect to the old database, paste it: Claude gives you the
`MINIMART_OLD_PGUSER=... MINIMART_OLD_DB=...` prefix for the command. (Do not look the names
up with `docker exec ... printenv` or an unformatted `docker inspect`: they print passwords.)

### 0.7 Hand-back list after phase 0

Paste into Claude (all of it is free of passwords):

1. The output of 0.1, 0.3 and 0.4.
2. The output of 0.5 (check once more that no password is visible).
3. `cat /root/minimart_inspect.txt` (the whole file).
4. Your answer to: can the old database be written to by anything other than the app
   (cron jobs, people connecting to port 5433)? The "Who is connected" section shows
   what is connected right now.

Claude replies with the names to use for `APP_CONTAINERS`, `SERVICE`, the variable names in 3.4, and
whether the collation decision in 2.2 matters.

---

## Phase 1: Backup of the old database (app up)

`pg_dump` takes a consistent snapshot and only reads: the app keeps working. This is
the backup everything else rests on; it is made **before** anything is created on
`mmi-postgres`.

### 1.1 Take the backup

```bash
cd /opt/purchasing_data
oldq() { local u d; u=$(docker exec minimart-postgres-1 printenv POSTGRES_USER 2>/dev/null </dev/null); u=${u:-postgres}; d=$(docker exec minimart-postgres-1 printenv POSTGRES_DB 2>/dev/null </dev/null); d=${d:-$u}; docker exec -i -e PGOPTIONS='-c default_transaction_read_only=on' minimart-postgres-1 psql -U "$u" -d "$d" -X -At -v ON_ERROR_STOP=1 -c "$1" </dev/null; }
mkdir -p /opt/backups/minimart
FREE_KB=$(df -Pk /opt/backups/minimart | awk 'NR==2{print $4}')
NEED_KB=$(oldq "select pg_database_size(current_database())/1024")
echo "free: ${FREE_KB} KB   old database: ${NEED_KB} KB"
case "$FREE_KB$NEED_KB" in
  ''|*[!0-9]*) echo "STOP: could not read the sizes" ;;
  *) if [ "$FREE_KB" -gt $((NEED_KB * 3)) ]; then
       scripts/minimart_migrate.sh --backup-old; echo "exit=$?"
     else
       echo "STOP: less than three times the database size is free under /opt/backups"
     fi ;;
esac
```

Expected (the numbers differ):

```
free: 41234567 KB   old database: 812345 KB
old database minimartdb holds 17 table(s)

== Backup of the OLD database -> /opt/backups/minimart/pre_migration_20261003_081500 ==
database minimartdb on minimart-postgres-1 (PostgreSQL 16.4)
old.dump: 120M, 16 table data entries
schema.sql: 410 lines
globals.sql: roles of the old server saved
counts.tsv: 17 table(s), 1234567 rows
OK /opt/backups/minimart/pre_migration_20261003_081500 (121M)
exit=0
```

**STOP** unless the last line before `exit=0` starts with `OK` and `exit=0`. A
`FAILED:` line, an `exit=3`, or a size `STOP` leaves nothing behind except possibly a partial
directory; paste the output. Re-running is safe. Two `exit=3` cases: another run is active
(wait for it), or `old database '...' has NO tables: wrong database?` (the script lists the databases
of the old server: paste it and Claude gives you the `MINIMART_OLD_DB=` prefix for the command).

### 1.2 Check the backup

The directory holds seven files: `old.dump` (the data, custom format, restorable
one table at a time), `schema.sql` (readable SQL of the structure), `globals.sql`
(the roles of the old server, **with their password hashes**: keep it private, mode
600), `counts.tsv` (exact row count per table), `MANIFEST` (what and when),
`SHA256SUMS` (checksums of the first three data files) and `COMPLETE` (written last: a
directory without it is not a finished backup).

```bash
cd /opt/purchasing_data
BK=$(ls -1d /opt/backups/minimart/pre_migration_*/ | tail -n 1)
if [ -s "${BK}COMPLETE" ]; then
  ls -l "$BK"
  cat "${BK}MANIFEST"
  (cd "$BK" && sha256sum -c SHA256SUMS)
  echo "table data entries in old.dump: $(docker exec -i minimart-postgres-1 pg_restore --list < "${BK}old.dump" | grep -c ' TABLE DATA ')"
  awk -F'\t' '{ n++; s += $2 } END { print n " tables, " s " rows in counts.tsv" }' "${BK}counts.tsv"
else
  echo "STOP: no completed backup directory (no COMPLETE file): repeat 1.1"
fi
```

Expected: seven files, the manifest, `old.dump: OK`, `schema.sql: OK`, `counts.tsv: OK`,
a number of table data entries, and the table and row totals, which must equal
the figures printed by 1.1.

**STOP** if a checksum says `FAILED` or the numbers disagree with 1.1: repeat 1.1.

---

## Phase 2: Roles, empty database and rehearsal (app up)

Creates the roles and the **empty** `minimart` database on `mmi-postgres`, then runs the
rehearsal: dump the old database, restore it into a scratch database
`minimart_rehearsal`, verify it table by table, drop it. The rehearsal never touches
`minimart`, can be repeated any number of times, and puts a short read load on the old
database.

### 2.1 Generate the passwords

Both go into `/opt/purchasing_data/.env`, mode 600, as they do for `HAULING_RO_PASSWORD`. They are
generated from letters and digits only (`db/minimart_setup.sql` and URLs both need that), and no block
contains a password value, so nothing secret reaches the shell history of the root account. Do not
type a password of your own into a command: if you must choose one, edit `.env` in an editor.
`MINIMART_RO_PASSWORD` is read from there by ClickHouse when the mirror is installed
(`from_env`, as for hauling). `MINIMART_APP_PASSWORD` is not used by any compose service
there (compose ignores variables it does not reference): it is the master copy that 3.4
copies into the minimart app's own env file. The block keeps passwords that already
exist, so it can be pasted again.

```bash
cd /opt/purchasing_data
genpw() { LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32; }
if [ ! -f .env ]; then
  echo "STOP: /opt/purchasing_data/.env does not exist"
else
  [ -e /root/env_before_minimart ] || { cp -p .env /root/env_before_minimart && chmod 600 /root/env_before_minimart; }
  [ -z "$(tail -c1 .env)" ] || echo >> .env
  for k in MINIMART_APP_PASSWORD MINIMART_RO_PASSWORD; do
    grep -Eq "^$k=[A-Za-z0-9]{16,}\$" .env || { grep -v "^$k=" .env > .env.new; cat .env.new > .env; rm -f .env.new; echo "$k=$(genpw)" >> .env; }
  done
  chmod 600 .env
  awk -F= '/^MINIMART_(APP|RO)_PASSWORD=/ { print $1, length($2) }' .env
fi
```

Expected:

```
MINIMART_APP_PASSWORD 32
MINIMART_RO_PASSWORD 32
```

**STOP** if either length is not 32 or the `.env` message appears. Undo (removes
nothing else): `cp -p /root/env_before_minimart /opt/purchasing_data/.env`.

### 2.2 Decide the collation (read-only)

`ORDER BY` on text depends on the database collation. The old container is probably
Alpine (byte order: all capitals before lower case) and `mmi-postgres` is Debian
(linguistic order: a, A, b, B). The data is not affected, but screens and reports can
list rows in another order. The test below sorts the same words on both servers.

```bash
cd /opt/purchasing_data
oldq() { local u d; u=$(docker exec minimart-postgres-1 printenv POSTGRES_USER 2>/dev/null </dev/null); u=${u:-postgres}; d=$(docker exec minimart-postgres-1 printenv POSTGRES_DB 2>/dev/null </dev/null); d=${d:-$u}; docker exec -i -e PGOPTIONS='-c default_transaction_read_only=on' minimart-postgres-1 psql -U "$u" -d "$d" -X -At -v ON_ERROR_STOP=1 -c "$1" </dev/null; }
newq() { docker exec -i mmi-postgres psql -U postgres -d postgres -X -At -v ON_ERROR_STOP=1 -c "$1" </dev/null; }
SORT="select string_agg(x, ',' order by x) from (values ('a'),('B'),('c'),('A'),('Z'),('b')) t(x)"
echo "old server sorts:  $(oldq "$SORT")"
echo "mmi-postgres sorts: $(newq "$SORT")"
echo "old collate / ctype:  $(oldq "select datcollate || ' / ' || datctype from pg_database where datname = current_database()")"
echo "mmi-postgres default: $(newq "select datcollate || ' / ' || datctype from pg_database where datname = 'postgres'")"
```

Expected on Linux, for an Alpine old container:

```
old server sorts:  A,B,Z,a,b,c
mmi-postgres sorts: a,A,b,B,c,Z
old collate / ctype:  en_US.utf8 / en_US.utf8
mmi-postgres default: en_US.utf8 / en_US.utf8
```

(Both servers can report the same collation name and still sort differently: Alpine
uses musl, which ignores it. Trust the first two lines, not the last two.)

**Decide, then use the answer in 2.3:**

- The two sort lines are **the same**: nothing to decide, leave `COLLATE=` empty in 2.3.
- They **differ** and you want the old behaviour: set `COLLATE=C` in 2.3. This creates
  `minimart` in byte order, as before. It can only be chosen while `minimart` is empty
  (now). If you already ran 2.3 without it, use 2.4.
- They differ and you accept the Debian order (the app sorts in code, or nobody
  will notice): leave it empty.

Whichever you choose, the rehearsal and the cutover reuse the collation of the
existing `minimart` database. The migrate script runs the same kind of sort test itself:
it prints `WARNING: text SORT ORDER differs ...` when sorting differs and
`note: collation names differ ... sort text identically` when only the names differ.

**STOP** if a line is empty or shows an error (a container is not running): paste it.
Nothing to undo.

### 2.3 Create the roles and the empty database

Two choices go in here: `COLLATE` (decided in 2.2) and `DB_TIMEZONE`. Leave `DB_TIMEZONE` empty
the first time. If the rehearsal in 2.5 prints `WARNING: default time zone differs: old server X,
mmi-postgres Y`, set `DB_TIMEZONE` to **X** (the old server's zone), paste this block again (it is
repeatable) and rehearse again. Why: a column `timestamp without time zone` with `DEFAULT now()`
stores the clock of the session's time zone, so without it new rows would be written in Y's
clock next to old rows written in X's (the data itself is copied unchanged either way).

The passwords go in on stdin, so they never appear in the process list or the
shell history. The script is idempotent: it can be re-run (it also sets the
passwords again).

```bash
cd /opt/purchasing_data
COLLATE=      # empty = server default; C = byte order (2.2)
DB_TIMEZONE=  # empty = leave the server default; or the OLD server's zone, e.g. UTC (see below and 2.5)
envval() { grep -m1 "^$1=" /opt/purchasing_data/.env | cut -d= -f2-; }
VARS=""; [ -n "$COLLATE" ] && VARS="-v lc_collate=$COLLATE"; [ -n "$DB_TIMEZONE" ] && VARS="$VARS -v db_timezone=$DB_TIMEZONE"
if envval MINIMART_APP_PASSWORD | grep -Eq '^[A-Za-z0-9]{16,}$' && envval MINIMART_RO_PASSWORD | grep -Eq '^[A-Za-z0-9]{16,}$' && [ -s db/minimart_setup.sql ]; then
  { printf '\\set app_password %s\n' "$(envval MINIMART_APP_PASSWORD)"
    printf '\\set ro_password %s\n' "$(envval MINIMART_RO_PASSWORD)"
    cat db/minimart_setup.sql; } | docker exec -i mmi-postgres psql -U postgres -X -v ON_ERROR_STOP=1 $VARS
  echo "exit=$?"
else
  echo "NOT RUN: password missing or not plain letters/digits (2.1), or db/minimart_setup.sql missing (0.2)"
fi
```

Expected: two result tables and `exit=0`. The first has one row:
`minimart | minimart_owner | <collate> | 0 | 0 | 0 | 0` (database, owner, collation,
tables, tables not owned by the owner, tables the app cannot read and write,
tables the read-only role can write: all four counts are 0 on an empty database). The
second lists three roles:

```
 rolname        | can_login | superuser | conn_limit | role_settings
 minimart_app   | t         | f         |         50 |
 minimart_owner | f         | f         |         -1 |
 minimart_ro    | t         | f         |         20 | TimeZone=UTC | DateStyle=ISO, YMD | default_transaction_read_only=on | statement_timeout=120s
```

With `DB_TIMEZONE` set, nothing else in the output changes; check it with
`docker exec mmi-postgres psql -U postgres -X -At -c "select setconfig from pg_db_role_setting s join pg_database d on d.oid = s.setdatabase where d.datname = 'minimart'"`
(shows `{TimeZone=UTC}`). To undo it: `ALTER DATABASE minimart RESET timezone`.

**STOP** on any `ERROR`, `exit` other than 0, or `NOT RUN`. The setup only creates
three roles and one database: nothing else on the server changes. Undo, if you want to
start over (the database is empty at this point): 2.4, and
`docker exec mmi-postgres psql -U postgres -X -c 'DROP ROLE minimart_ro, minimart_app, minimart_owner'`
once the database is gone.

### 2.4 Only if needed: re-create the empty database with another collation

Refuses unless `minimart` has zero tables, views and sequences and no migration marker,
so it can never drop real data. Afterwards run 2.3 again with the `COLLATE` you want.

```bash
cd /opt/purchasing_data
nq() { docker exec -i mmi-postgres psql -U postgres -X -At -v ON_ERROR_STOP=1 "$@" </dev/null; }
EXISTS=$(nq -d postgres -c "select count(*) from pg_database where datname = 'minimart'")
TABLES=$(nq -d minimart -c "select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.relkind in ('r','p','v','m','S','f') and n.nspname !~ '^pg_' and n.nspname <> 'information_schema'" 2>/dev/null)
MARK=$(nq -d postgres -c "select coalesce(shobj_description(oid, 'pg_database'), '') from pg_database where datname = 'minimart'")
if [ "$EXISTS" != 1 ]; then
  echo "minimart does not exist: nothing to drop, run 2.3"
elif [ "$TABLES" != 0 ] || [ -n "$MARK" ]; then
  echo "REFUSED: minimart has $TABLES relation(s) and marker '$MARK'. Nothing changed."
else
  nq -d postgres -c "drop database minimart" && echo "minimart dropped (it was empty): now run 2.3"
fi
```

Expected: `DROP DATABASE`, then `minimart dropped (it was empty): now run 2.3`. **STOP** on `REFUSED`: the
database holds data or a migration marker. Never work around it (this is the
guard that protects the cutover); paste the line.

### 2.5 The rehearsal

```bash
cd /opt/purchasing_data
scripts/minimart_migrate.sh --rehearse; echo "exit=$?"
```

Expected (shortened; your names, sizes and seconds differ; the verify section has one
`PASS` line per table):

```
== Preflight ==
old: minimart-postgres-1  db=minimartdb user=minimart  PostgreSQL 16.4
new: mmi-postgres  user=postgres  PostgreSQL 16.4
extensions in old database: none  (all available on the new server)
old database: encoding=UTF8 collate=en_US.utf8 ctype=en_US.utf8
disk on mmi-postgres: 98765432 KB free, old database 812345 KB
disk: 41234567 KB free under /opt/backups/minimart, database 812345 KB

== Rehearsal into minimart_rehearsal (the real minimart is not touched) ==
dump: 14 s, 120M, 16 table data entries
restore: 22 s

== Post-restore on minimart_rehearsal ==
  psql:<stdin>:52: NOTICE:  ownership: 54 object(s) changed to minimart_owner
  grants for minimart_app refreshed (db/minimart_setup.sql)
  psql:<stdin>:46: NOTICE:  sequence public.customers_customer_id_seq reset from 5 to 200 (max of public.customers.customer_id)
  ...
  ANALYZE done
  every object is owned by minimart_owner
post-restore (owners, grants, sequences, analyze): 3 s

== Verify: old (minimartdb@minimart-postgres-1) vs new (minimart_rehearsal@mmi-postgres) ==
  PASS  public.orders  rows=48210
  ...
  PASS  catalog inventory identical (...)
VERIFY OK: all checks passed
verify: 9 s

== Timing ==
  dump 14 s + restore 22 s + post-restore 3 s + verify 9 s = 48 s
  expected cutover downtime: about 1 minute(s) of database work, plus stopping/starting the app and the browser test.
REHEARSAL OK (48 s total). The scratch dump was deleted.
  scratch database minimart_rehearsal dropped
exit=0
```

Lines you may see in the preflight, none of them an error:

- `note: collation names differ (...) but both sort text identically`: nothing to do.
- `WARNING: text SORT ORDER differs: ...`: the order of `ORDER BY` on text will change unless you
  chose `COLLATE=C` (2.2, 2.4).
- `WARNING: default time zone differs: old server X, mmi-postgres Y ...`: see the `DB_TIMEZONE` note in 2.3.
- `WARNING: the old database has settings stored on it that a dump does NOT carry`, followed by
  `ALTER DATABASE ...` lines: apply them after the cutover with 3.2a and 3.2b, not by pasting the
  printed lines.
- `WARNING: the old database had N live connection(s) during this rehearsal`: the app is running, as
  it should be. Rows it wrote between the dump and the verify show up as `FAIL` lines with
  `rows=` / `sum:` / `hash=` differences and the rehearsal ends `REHEARSAL FAILED`. That is
  expected, not a defect: the restore and every other table were checked. Run the rehearsal again at a
  quiet moment until one ends in `REHEARSAL OK`: 3.1 will only stop the app after one did.

A sequence line says `reset from X to Y` where the old sequence was behind its data; that is the
script repairing it.

**STOP** and paste the whole output if you see any of: a `VERIFY FAILED` that is not the
live-connection case above (for example `missing in new database`, `extra table in new database`,
`catalog inventory differs`, `BEHIND old`, `not owned by minimart_owner`); `FAILED:`;
`extension(s) used by the old database are NOT available` (the restore would fail; installing an
extension means changing the shared server, which needs a decision); `role(s) missing` (run 2.3);
or an `exit` other than 0 (`exit=1` with `REHEARSAL FAILED` in the live-connection case is the
exception). Nothing has been changed on `minimart` or the old database; the scratch database is
dropped on the way out (if the script was killed, the next rehearsal drops the leftover first).

### 2.6 The expected downtime

The cutover does the same work as the rehearsal on the same data (a fresh dump, a restore,
the same checks), so its database time is the rehearsal's `total`.

```bash
cd /opt/purchasing_data
T=$(grep '\[rehearse\]' /var/log/minimart-migration.log 2>/dev/null | grep 'REHEARSAL OK' | tail -n 1 | sed -E 's/.*\(([0-9]+) s total\).*/\1/')
case "$T" in
  ''|*[!0-9]*) echo "no successful rehearsal in the log: run 2.5 first" ;;
  *) echo "database work in the last rehearsal: $T s"
     echo "expected downtime: about $(( (T + 59) / 60 + 15 )) minutes (database work rounded up, plus 15 for stopping the app, editing its settings, starting it and the browser test)" ;;
esac
grep '\[rehearse\]' /var/log/minimart-migration.log 2>/dev/null | grep -E ' dump: | restore: |post-restore|verify:|REHEARSAL' | tail -n 5
```

Expected: `database work in the last rehearsal: 48 s`, `expected downtime: about 16 minutes (...)`,
and the five timing lines of the last rehearsal. The 15 minutes are an estimate for the
manual part: replace it with your own after the first run. Tell the people who use the
app the number you get.

**STOP** if it says `no successful rehearsal in the log`: run 2.5 first.

### 2.7 Hand-back list after phase 2

Paste into Claude: the whole output of 2.5 (or at least the lines `old database:`,
`WARNING`/`note`, `dump:`, `restore:`, `post-restore`, `verify:`, `Timing`,
`REHEARSAL OK`), the output of 2.2 and 2.6. Claude confirms the window before you go on.

---

## Phase 3: Cutover (app DOWN from 3.1 until the app is started in 3.4a)

Order of this phase: stop the app, run the cutover (final dump, restore, ownership,
sequences, verify), repoint the app, start it, test in the browser. The old
container keeps running untouched the whole time: it is the rollback.

### 3.1 Stop the app

Refuses unless the backup exists, a rehearsal succeeded, and every name in
`APP_CONTAINERS` is a running container that is not a database. `docker stop` keeps
the container (and its configuration) in place.

```bash
cd /opt/purchasing_data
APP_CONTAINERS="minimart-app-1"     # the app container name(s) from 0.3 / 0.5, space separated, NOT the database
oldq() { local u d; u=$(docker exec minimart-postgres-1 printenv POSTGRES_USER 2>/dev/null </dev/null); u=${u:-postgres}; d=$(docker exec minimart-postgres-1 printenv POSTGRES_DB 2>/dev/null </dev/null); d=${d:-$u}; docker exec -i -e PGOPTIONS='-c default_transaction_read_only=on' minimart-postgres-1 psql -U "$u" -d "$d" -X -At -v ON_ERROR_STOP=1 -c "$1" </dev/null; }
ok=1
ls /opt/backups/minimart/pre_migration_*/COMPLETE >/dev/null 2>&1 || { echo "STOP: no completed backup (phase 1)"; ok=0; }
grep -q '\[rehearse\] REHEARSAL OK' /var/log/minimart-migration.log 2>/dev/null || { echo "STOP: no successful rehearsal in the log (phase 2)"; ok=0; }
[ -n "$APP_CONTAINERS" ] || { echo "STOP: APP_CONTAINERS is empty"; ok=0; }
for c in $APP_CONTAINERS; do
  case "$c" in
    minimart-postgres-1|mmi-postgres|procurement*|hauling*) echo "STOP: $c is not the minimart app"; ok=0; continue ;;
  esac
  [ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" = true ] || { echo "STOP: $c is not a running container (already stopped? then go to 3.2)"; ok=0; }
done
if [ "$ok" = 1 ]; then
  docker stop $APP_CONTAINERS
  sleep 5
  echo "connections left on the old database: $(oldq "select count(*) from pg_stat_activity where datname = current_database() and pid <> pg_backend_pid() and backend_type = 'client backend'")"
  oldq "select usename || '|' || coalesce(nullif(application_name, ''), '-') || '|' || coalesce(client_addr::text, 'local') || '|' || state from pg_stat_activity where datname = current_database() and pid <> pg_backend_pid() and backend_type = 'client backend'"
else
  echo "NOT STOPPED"
fi
```

Expected: the container name(s) echoed by `docker stop`, then
`connections left on the old database: 0` and nothing below it. **The app is down now.**

**STOP** on any `STOP:` line (nothing was stopped), or if connections are left: the
rows below the count say who (`user|application|address|state`). Find and stop those clients
(another app container, a cron job, someone with `psql` on port 5433), wait a few
seconds and paste the block again. Do not go to 3.2 with connections left (the script
would refuse anyway). Undo: `docker start <the container name>`.

### 3.2 The cutover

```bash
cd /opt/purchasing_data
scripts/minimart_migrate.sh --cutover; echo "exit=$?"
```

Expected (shortened; compare with the rehearsal):

```
== Preflight ==
...
== Cutover guards ==
backup of the old database found: /opt/backups/minimart/pre_migration_20261003_081500/
old database has no other connections: app is stopped

== Final dump of the old database -> /opt/backups/minimart/cutover_20261003_220100/final.dump ==
dump: 14 s, 120M, 16 table data entries

== Restore into minimart ==
restore: 22 s

== Post-restore on minimart ==
...
== Verify: old (...) vs new (minimart@mmi-postgres) ==
  PASS  ...
VERIFY OK: all checks passed

== Cutover data move complete ==
  dump 14 s, restore 22 s, post-restore 3 s, verify 9 s
  final dump kept at /opt/backups/minimart/cutover_20261003_220100/final.dump
  Next: point the app at mmi-postgres / minimart as minimart_app (runbook phase 3), start it, test in the browser.
  The old container is still running and untouched: it is the rollback.
CUTOVER OK minimart from minimartdb@minimart-postgres-1 (48 s)
exit=0
```

The old database is only ever read. Exit codes: **0** done and verified; **3** a guard
refused (nothing, or only a final dump, was done); **1** a step failed.

**STOP** unless `exit=0` and `CUTOVER OK`. What each failure means, and what to do, is
in the table "The cutover stops midway" in phase 7. In short: the old database is
untouched in every case, and running 3.2 again is safe unless it says
`already completed` (then it refuses on purpose: the app may have written to
`minimart` since). Never start the app on `minimart` after a `VERIFY FAILED`.

### 3.2a Settings stored on the old database (read-only)

A dump does not carry `ALTER DATABASE ... SET` settings (for example `search_path`). The script warned about
them in the preflight if the old database has any. This lists them as statements for `minimart`.

```bash
cd /opt/purchasing_data
oldq() { local u d; u=$(docker exec minimart-postgres-1 printenv POSTGRES_USER 2>/dev/null </dev/null); u=${u:-postgres}; d=$(docker exec minimart-postgres-1 printenv POSTGRES_DB 2>/dev/null </dev/null); d=${d:-$u}; docker exec -i -e PGOPTIONS='-c default_transaction_read_only=on' minimart-postgres-1 psql -U "$u" -d "$d" -X -At -v ON_ERROR_STOP=1 -c "$1" </dev/null; }
echo "settings of the old database (applied to minimart in 3.2b):"
oldq "select format('ALTER DATABASE %I SET %s TO %s;', 'minimart', split_part(c, '=', 1), CASE WHEN split_part(c, '=', 1) IN ('search_path', 'temp_tablespaces', 'session_preload_libraries', 'local_preload_libraries') THEN substr(c, position('=' in c) + 1) ELSE quote_literal(substr(c, position('=' in c) + 1)) END) from pg_db_role_setting s join pg_database d on d.oid = s.setdatabase, unnest(s.setconfig) c where d.datname = current_database() and s.setrole = 0"
echo "settings of single roles in the old database (NOT applied: tell Claude if any):"
oldq "select r.rolname || ': ' || c from pg_db_role_setting s join pg_database d on d.oid = s.setdatabase join pg_roles r on r.oid = s.setrole, unnest(s.setconfig) c where d.datname = current_database()"
echo "settings of minimart now:"
docker exec -i mmi-postgres psql -U postgres -X -At -c "select coalesce(r.rolname, '(database)') || ': ' || c from pg_db_role_setting s join pg_database d on d.oid = s.setdatabase left join pg_roles r on r.oid = s.setrole, unnest(s.setconfig) c where d.datname = 'minimart'" </dev/null
```

Expected: under the first heading nothing (the common case), or lines such as
`ALTER DATABASE minimart SET search_path TO public, audit;` and `ALTER DATABASE minimart SET work_mem TO '8MB';`
(list settings such as `search_path` must not be quoted as one string, which is why these statements
are generated here and not pasted from the script's warning). Under the second heading nothing. The
last heading shows what `minimart` has (for example `(database): TimeZone=UTC` if you set `DB_TIMEZONE`).

**STOP** and tell Claude if the second heading lists anything: the old app's login does not exist
on `mmi-postgres`, so its settings have to be mapped to `minimart_app` by hand.

### 3.2b Apply them (only if 3.2a listed database settings)

Applies exactly the statements 3.2a showed, to `minimart` only. Does nothing if there are none.

```bash
cd /opt/purchasing_data
oldq() { local u d; u=$(docker exec minimart-postgres-1 printenv POSTGRES_USER 2>/dev/null </dev/null); u=${u:-postgres}; d=$(docker exec minimart-postgres-1 printenv POSTGRES_DB 2>/dev/null </dev/null); d=${d:-$u}; docker exec -i -e PGOPTIONS='-c default_transaction_read_only=on' minimart-postgres-1 psql -U "$u" -d "$d" -X -At -v ON_ERROR_STOP=1 -c "$1" </dev/null; }
MARK=$(docker exec -i mmi-postgres psql -U postgres -X -At -c "select coalesce(shobj_description(oid, 'pg_database'), '') from pg_database where datname = 'minimart'" </dev/null)
STMTS=$(oldq "select format('ALTER DATABASE %I SET %s TO %s;', 'minimart', split_part(c, '=', 1), CASE WHEN split_part(c, '=', 1) IN ('search_path', 'temp_tablespaces', 'session_preload_libraries', 'local_preload_libraries') THEN substr(c, position('=' in c) + 1) ELSE quote_literal(substr(c, position('=' in c) + 1)) END) from pg_db_role_setting s join pg_database d on d.oid = s.setdatabase, unnest(s.setconfig) c where d.datname = current_database() and s.setrole = 0")
if ! echo "$MARK" | grep -q 'cutover-complete'; then
  echo "STOP: the cutover is not complete (3.2). Marker: $MARK"
elif [ -z "$STMTS" ]; then
  echo "nothing to apply: the old database has no database-wide settings"
else
  echo "$STMTS"
  echo "$STMTS" | docker exec -i mmi-postgres psql -U postgres -X -v ON_ERROR_STOP=1 -d minimart; echo "exit=$?"
fi
```

Expected: `nothing to apply: ...`, or the statements echoed, one `ALTER DATABASE` per line, and `exit=0`.
**STOP** on an `ERROR` or an `exit` other than 0 (nothing else was changed). Undo one setting:
`ALTER DATABASE minimart RESET <name>`.

### 3.3a Back up the app's files

The first backup of each file is kept for good: running this block again never
replaces it, so the original is always the oldest `.bak_*`.

```bash
cd /opt/purchasing_data
FILES="/opt/minimart/.env /opt/minimart/docker-compose.yml"    # the files you will change or rely on (0.5)
TS=$(date +%Y%m%d_%H%M%S)
for f in $FILES; do
  if [ ! -f "$f" ]; then
    echo "MISSING $f"
  elif ls "$f".bak_* >/dev/null 2>&1; then
    echo "backup already exists, kept: $(ls -1 "$f".bak_* | head -n 1)"
  else
    cp -p "$f" "$f.bak_$TS" && echo "backed up $f -> $f.bak_$TS"
  fi
done
```

Expected: one `backed up` (or `backup already exists`) line per file. **STOP** on
`MISSING`: correct `FILES` (the env file of 0.5) and paste again.

### 3.3b Point the app's settings at mmi-postgres

The helper replaces `KEY=VALUE` in the env file or appends it, and prints nothing
secret. The new values are host `mmi-postgres`, port `5432`, database `minimart`, user
`minimart_app`, and the password of `MINIMART_APP_PASSWORD` from 2.1.
Set the five names to what 0.5 showed (leave a name empty to skip it). If the app
reads one URL instead (for example `DATABASE_URL`), put its name in `URL_VAR`,
empty the five, and keep the scheme the old URL used. Refuses unless 3.2 completed and the
file was backed up (3.3a).

```bash
cd /opt/purchasing_data
umask 077
APP_ENV=/opt/minimart/.env          # the env file that holds the OLD connection settings (0.5)
HOST_VAR=PGHOST; PORT_VAR=PGPORT; DB_VAR=PGDATABASE; USER_VAR=PGUSER; PASS_VAR=PGPASSWORD    # names from 0.5
URL_VAR=                            # e.g. DATABASE_URL when the app reads one URL; then empty the five above
URL_SCHEME=postgresql               # keep the scheme the old URL used (postgres or postgresql)
envval() { grep -m1 "^$1=" /opt/purchasing_data/.env | cut -d= -f2-; }
setenv() { [ -n "$2" ] || return 0; K="$2" V="$3" awk 'BEGIN { k = ENVIRON["K"]; v = ENVIRON["V"] } index($0, k "=") == 1 { print k "=" v; d = 1; next } { print } END { if (!d) print k "=" v }' "$1" > "$1.new" && cat "$1.new" > "$1"; rm -f "$1.new"; }
PW=$(envval MINIMART_APP_PASSWORD)
MARK=$(docker exec -i mmi-postgres psql -U postgres -X -At -c "select coalesce(shobj_description(oid, 'pg_database'), '') from pg_database where datname = 'minimart'" </dev/null)
if [ ! -f "$APP_ENV" ]; then
  echo "STOP: $APP_ENV does not exist"
elif ! ls "$APP_ENV".bak_* >/dev/null 2>&1; then
  echo "STOP: no backup of $APP_ENV yet (3.3a)"
elif ! echo "$MARK" | grep -q 'cutover-complete'; then
  echo "STOP: the cutover is not complete (3.2). Marker: $MARK"
elif ! echo "$PW" | grep -Eq '^[A-Za-z0-9]{16,}$'; then
  echo "STOP: MINIMART_APP_PASSWORD is missing or not plain letters/digits (2.1)"
else
  setenv "$APP_ENV" "$HOST_VAR" mmi-postgres
  setenv "$APP_ENV" "$PORT_VAR" 5432
  setenv "$APP_ENV" "$DB_VAR" minimart
  setenv "$APP_ENV" "$USER_VAR" minimart_app
  setenv "$APP_ENV" "$PASS_VAR" "$PW"
  setenv "$APP_ENV" "$URL_VAR" "$URL_SCHEME://minimart_app:$PW@mmi-postgres:5432/minimart"
  for k in $HOST_VAR $PORT_VAR $DB_VAR $USER_VAR; do echo "$k=$(grep -m1 "^$k=" "$APP_ENV" | cut -d= -f2-)"; done
  [ -z "$PASS_VAR" ] || { [ "$(grep -m1 "^$PASS_VAR=" "$APP_ENV" | cut -d= -f2-)" = "$PW" ] && echo "$PASS_VAR=<hidden, ${#PW} chars, equals MINIMART_APP_PASSWORD>" || echo "$PASS_VAR: DOES NOT MATCH"; }
  [ -z "$URL_VAR" ] || echo "$URL_VAR=$(grep -m1 "^$URL_VAR=" "$APP_ENV" | cut -d= -f2- | sed 's#//\([^:]*\):[^@]*@#//\1:***@#')"
fi
```

Expected (separate variables):

```
PGHOST=mmi-postgres
PGPORT=5432
PGDATABASE=minimart
PGUSER=minimart_app
PGPASSWORD=<hidden, 32 chars, equals MINIMART_APP_PASSWORD>
```

or, with a URL, one line `DATABASE_URL=postgresql://minimart_app:***@mmi-postgres:5432/minimart`.

**STOP** on `STOP:` or `DOES NOT MATCH`. If 0.5 showed the connection values written
in `docker-compose.yml` itself (not in an env file), do not edit that file by hand:
tell Claude. Undo: 7.3b puts the original file back.

### 3.3c The app must join the Docker network of mmi-postgres

`mmi-postgres` is reached over `postgres_net` (as procurement and hauling do). A
small override file adds that external network to the app's service without touching
`docker-compose.yml`. `default` keeps the app on its own project network (it keeps
reaching the old container for the rollback and anything else it needs).

<!-- notest -->
```bash
cd /opt/purchasing_data
APP_DIR=/opt/minimart
BASE=$APP_DIR/docker-compose.yml     # the compose file of 0.3
SERVICE=app                          # the app's compose service from 0.3, NOT the database
NET=$(grep -m1 '^MMI_PG_NETWORK=' /opt/purchasing_data/.env 2>/dev/null | cut -d= -f2-)
NET=${NET:-postgres_net}             # the network of mmi-postgres (0.4): the one procurement uses, MMI_PG_NETWORK in .env
OVR=$APP_DIR/docker-compose.mmi-network.yml
if [ -e "$OVR" ]; then
  echo "STOP: $OVR already exists (look at it; remove it only if you made it for this)"
elif ! docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' mmi-postgres | grep -qw "$NET"; then
  echo "STOP: mmi-postgres is not on the network $NET"
elif ! docker compose -f "$BASE" config --services | grep -qx "$SERVICE"; then
  echo "STOP: $SERVICE is not a service of $BASE"
else
  printf '%s\n' 'services:' "  $SERVICE:" '    networks:' '      - default' '      - mmi_pg' 'networks:' '  mmi_pg:' '    external: true' "    name: $NET" > "$OVR"
  cat "$OVR"
  docker compose -f "$BASE" -f "$OVR" config --quiet && echo "compose OK"
fi
```

Expected: the nine lines of the file and `compose OK`. This block is not run by the
test harness (it needs `/opt/minimart` and compose).

**STOP** unless `compose OK`. If compose complains about an undefined network
`default`, the app service lists its own networks: replace `      - default` by those names
(from 0.5, "networks of ..."), delete the file (`rm /opt/minimart/docker-compose.mmi-network.yml`)
and run the block again. Undo: `rm /opt/minimart/docker-compose.mmi-network.yml`.

### 3.4a Start the app

`--no-deps` is essential: without it compose also (re)creates and starts the database
service the app `depends_on`, which would restart the old container. The
project name is passed explicitly so compose recreates the existing app and does not
make a second copy. **From now on use exactly this command** to start or recreate the
app.

<!-- notest -->
```bash
cd /opt/purchasing_data
APP_DIR=/opt/minimart
PROJECT=minimart      # the compose project from 0.3
SERVICE=app           # the app's service from 0.3
dc() { docker compose -p "$PROJECT" -f "$APP_DIR/docker-compose.yml" -f "$APP_DIR/docker-compose.mmi-network.yml" "$@"; }
dc up -d --no-deps "$SERVICE"
sleep 15
dc ps
dc logs --tail 40 "$SERVICE" 2>&1 | grep -Ei 'error|denied|refused|fatal|password|timeout|econn|does not exist' | head -n 20
echo "log scan done"
```

Expected: the app `Up` (not `Restarting`), the log scan printing nothing before
`log scan done`.

**STOP** if the app restarts in a loop or the scan prints lines:

- `password authentication failed`: the password in the env file differs from the role's.
  Run 2.3 again (it sets the role's password from `.env`) and 3.3b again.
- `could not translate host name` or `Connection refused`: the app is not on `postgres_net` (3.3c)
  or the host value is wrong (3.3b).
- `permission denied for ...` / `must be owner of ...`: the app changes the schema or truncates
  tables at startup, which `minimart_app` may not (it has SELECT, INSERT, UPDATE, DELETE and
  sequence use only). See 3.4c.

Undo (back on the old database): 7.3.

### 3.4b Is the app really using the new database?

Use the app for a minute first (log in, open a page), then:

```bash
cd /opt/purchasing_data
oldq() { local u d; u=$(docker exec minimart-postgres-1 printenv POSTGRES_USER 2>/dev/null </dev/null); u=${u:-postgres}; d=$(docker exec minimart-postgres-1 printenv POSTGRES_DB 2>/dev/null </dev/null); d=${d:-$u}; docker exec -i -e PGOPTIONS='-c default_transaction_read_only=on' minimart-postgres-1 psql -U "$u" -d "$d" -X -At -v ON_ERROR_STOP=1 -c "$1" </dev/null; }
echo "sessions of minimart_app on the NEW database (user|application|from|state):"
docker exec -i mmi-postgres psql -U postgres -X -At -c "select usename || '|' || coalesce(nullif(application_name, ''), '-') || '|' || coalesce(client_addr::text, 'local') || '|' || state from pg_stat_activity where datname = 'minimart' and usename = 'minimart_app' order by pid" </dev/null
echo "connections still open on the OLD database: $(oldq "select count(*) from pg_stat_activity where datname = current_database() and pid <> pg_backend_pid() and backend_type = 'client backend'")"
```

Expected: at least one `minimart_app|...|<the app container's address>|idle` row, and
`connections still open on the OLD database: 0`.

**STOP** if there is no `minimart_app` session after a minute of use (the app still points elsewhere
or cannot connect: read the log as in 3.4a), or the old database has connections (something still
uses it, and its writes will be lost: find it with the rows `--inspect` showed in 0.6).

### 3.4c Only if the log says `permission denied`: the escape hatch

`minimart_app` is deliberately DML only, so a bug or a hack cannot drop tables. Some apps
run schema migrations or `TRUNCATE` at startup. First find the statement
(`docker logs --since 10m mmi-postgres 2>&1 | grep -B1 -A3 'permission denied'` shows it)
and tell Claude: usually the app has a switch to skip migrations. If you decide the app
must be allowed to change the schema, make it a member of the owner role. **This is your
decision**: it gives the app owner rights (DDL, TRUNCATE, DROP) on every minimart table, and
objects it creates are owned by `minimart_app` unless it runs `SET ROLE minimart_owner`.
Note that the database still has the **old** schema, exactly as restored.

```bash
cd /opt/purchasing_data
docker exec -i mmi-postgres psql -U postgres -X -v ON_ERROR_STOP=1 -d minimart -c "GRANT minimart_owner TO minimart_app" </dev/null
docker exec -i mmi-postgres psql -U postgres -X -At -c "select pg_has_role('minimart_app', 'minimart_owner', 'member')" </dev/null
```

Expected: `GRANT ROLE` (or `GRANT`), then `t`. Restart the app (3.4a). **STOP** on an `ERROR`
(nothing was granted). Undo:

```bash
cd /opt/purchasing_data
docker exec -i mmi-postgres psql -U postgres -X -v ON_ERROR_STOP=1 -d minimart -c "REVOKE minimart_owner FROM minimart_app" </dev/null
docker exec -i mmi-postgres psql -U postgres -X -At -c "select pg_has_role('minimart_app', 'minimart_owner', 'member')" </dev/null
```

Expected: `REVOKE ROLE` (or `REVOKE`), then `f`.

### 3.5 Browser test (generic: you know the app, so adapt it)

The app is up again. Do these in the browser with a real account, and note anything odd:

1. Log in, log out, log in again.
2. Open every main page or menu entry once: lists load, nothing says `error` or `500`.
3. Search, sort and filter a list that has text in it. Compare the order with how it used to look
   (see 2.2 if the order changed).
4. Open three records you know well. Dates and times must be what you expect (no shift of
   hours): compare with a record you remember or an old screenshot.
5. Create a clearly named **test** record, edit it, find it in the list, then delete it (or mark it for
   deletion) the way the app allows.
6. Anything that uses files, images, exports or reports: open one, download one.
7. After 5 minutes of use, look at the app log again (3.4a) for errors.

If these pass, the cutover is done and the old container is still the rollback. If one fails and the
data written so far does not matter, roll back now (phase 7, situation A: nothing is lost
if nobody has used the app yet). The decision rules are in phase 7.

### 3.6 Before the ClickHouse mirror

`minimart_ro` can connect and use schemas, but has **no table privileges after setup, on purpose**:
the mirror's grants (`db/minimart_ro_grants.sql`, which withholds password and token columns)
are run **after** the cutover, as step of `RUNBOOK_MINIMART_MIRROR.md` (it may not be on this
branch yet: ask Claude). Nothing else in this runbook needs it.

```bash
cd /opt/purchasing_data
docker exec -i mmi-postgres psql -U postgres -d minimart -X -At -c "select count(*) from information_schema.tables t where t.table_schema not in ('pg_catalog', 'information_schema') and has_table_privilege('minimart_ro', format('%I.%I', t.table_schema, t.table_name), 'SELECT')" </dev/null
```

Expected: `0` (it becomes the number of tables after the mirror's grants). **STOP** and
paste it if the number is not 0: someone granted `minimart_ro` more than the setup does.

---

## Phase 4: Stop the old container (app up on the new database)

Do this only after the app has run on `minimart` for as long as you agreed (suggested:
at least one full working day, including whatever runs only at the end of a day or month
if the app has such jobs). **You decide when.** Until then, the old container
(untouched since the final dump) is the cheapest rollback: situation A in phase 7.

### 4.1 Compare once more (informational)

`--verify` compares the old database with `minimart`. Once the app has written to `minimart`
the two differ **by design**, so this is not a gate: it shows that the old database
was not changed by anything, and that only tables the app writes to differ.

```bash
cd /opt/purchasing_data
scripts/minimart_migrate.sh --verify; echo "exit=$?"
```

Expected: if the app wrote nothing yet, `VERIFY OK: all checks passed` and `exit=0`. After real
use, `FAIL` lines for the tables that grew or changed (`rows=...` or `sum:`/`hash=` differences)
and `exit=1` are normal. Not normal: `missing in new database`, `extra table in new database`,
`catalog inventory differs`, `BEHIND old`, `not owned by minimart_owner`. If it warns that the old
database has connections, rows written to the old one after the cutover will show as
differences: find out who writes there before 4.2. **STOP** and paste the output if
anything on the "not normal" list appears.

### 4.2 Stop it (not delete it)

Refuses unless the cutover completed, the old database has no connections, and the
final dump exists. Then it stops `minimart-postgres-1` and, if its restart policy is `always`,
changes that to `unless-stopped` so that a reboot does not bring the old database (and the
public port 5433) back by itself.

```bash
cd /opt/purchasing_data
OLD=minimart-postgres-1
oldq() { local u d; u=$(docker exec "$OLD" printenv POSTGRES_USER 2>/dev/null </dev/null); u=${u:-postgres}; d=$(docker exec "$OLD" printenv POSTGRES_DB 2>/dev/null </dev/null); d=${d:-$u}; docker exec -i -e PGOPTIONS='-c default_transaction_read_only=on' "$OLD" psql -U "$u" -d "$d" -X -At -v ON_ERROR_STOP=1 -c "$1" </dev/null; }
MARK=$(docker exec -i mmi-postgres psql -U postgres -X -At -c "select coalesce(shobj_description(oid, 'pg_database'), '') from pg_database where datname = 'minimart'" </dev/null)
CONN=$(oldq "select count(*) from pg_stat_activity where datname = current_database() and pid <> pg_backend_pid() and backend_type = 'client backend'")
FINAL=$(ls -1t /opt/backups/minimart/cutover_*/final.dump 2>/dev/null | head -n 1)
if ! echo "$MARK" | grep -q 'cutover-complete'; then
  echo "REFUSED: the cutover is not complete. Marker: $MARK"
elif [ "$CONN" != 0 ]; then
  echo "REFUSED: connections on the old database: '$CONN' (must be 0; empty means the old container is not running)"
elif [ ! -s "$FINAL" ]; then
  echo "REFUSED: no final dump found under /opt/backups/minimart/cutover_*/"
else
  docker stop "$OLD"
  [ "$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$OLD")" = always ] && docker update --restart=unless-stopped "$OLD"
  docker inspect -f 'state={{.State.Status}} restart={{.HostConfig.RestartPolicy.Name}}' "$OLD"
  echo "final dump kept: $FINAL"
fi
```

Expected: `minimart-postgres-1` (from `docker stop`, and a second time from `docker update` when
the policy was `always`), `state=exited restart=unless-stopped` (or `no`), and the final dump path. The container, its volume and the dumps stay. Port 5433 stops
answering. Rolling back from here is situation B in phase 7. **STOP** on `REFUSED` (nothing
was stopped). Undo: `docker start minimart-postgres-1`.

Do not delete the container or its volume for weeks. The nightly backup of `minimart`
(phase 6) is the real safety net from now on; the old volume is the extra copy.

---

## Phase 5: Close public port 5433 (your decision, separate)

Stopping the container in 4.2 already closes the port. What this phase adds: while the
old container runs (the rollback window) or after you start it again for a rollback, port
5433 is open to the internet, and **Docker publishes ports through iptables rules that bypass
`ufw`**, so `ufw deny 5433` would not close it. The rule below drops 5433 only for traffic that
comes in on the public network interface; the app, other containers and `localhost` are unaffected.
It lasts until the next reboot unless you make it persistent your distribution's way.

### 5.1 Read-only checks first

<!-- notest -->
```bash
cd /opt/purchasing_data
echo "--- listening:"; ss -ltn | grep -E ':5433( |$)'
echo "--- docker port:"; docker port minimart-postgres-1 2>&1
echo "--- DOCKER-USER chain:"; iptables -S DOCKER-USER
echo "--- default route interface:"; ip -o -4 route show to default | awk '{ print $5 }'
echo "--- ufw:"; ufw status 2>&1 | head -n 5
echo "--- who was connected when you inspected (from 0.6):"
sed -n '/== Who is connected/,$p' /root/minimart_inspect.txt | head -n 20
```

Expected: a `0.0.0.0:5433` listener while the old container runs (none after 4.2); the
DOCKER-USER chain (`-N DOCKER-USER`, `-A DOCKER-USER -j RETURN` on a stock Docker);
one interface name (for example `eth0`); the `ufw` state; and the connections of 0.6.
Anything connecting **from an address outside the server** (not `local socket`, not a
172.x container address) is a client you must tell before you close the port: another
application, a BI tool, someone's laptop.

**STOP** if `DOCKER-USER` does not exist (Docker's firewall integration is off: ask Claude)
or no interface name is printed.

### 5.2 Add the rule (guarded)

<!-- notest -->
```bash
cd /opt/purchasing_data
IFACE=$(ip -o -4 route show to default | awk '{ print $5 }' | head -n 1)
RULE="-i $IFACE -p tcp -m conntrack --ctorigdstport 5433 --ctdir ORIGINAL -j DROP"
if [ -z "$IFACE" ]; then
  echo "STOP: no default interface found"
elif ! iptables -S DOCKER-USER >/dev/null 2>&1; then
  echo "STOP: no DOCKER-USER chain"
elif iptables -C DOCKER-USER $RULE 2>/dev/null; then
  echo "rule already present"
else
  iptables -I DOCKER-USER $RULE && echo "rule added for interface $IFACE"
fi
iptables -S DOCKER-USER
```

Expected: `rule added for interface eth0` and a chain with the `DROP` rule first.
`--ctorigdstport` matches the **original** destination port (5433): Docker has already
rewritten it to 5432 when the rule is evaluated.

You cannot test this from the server. From **another machine** (your laptop):
`nc -vz -w 5 76.13.19.246 5433`. Before the rule (with the old container running) it
says `succeeded`; after, it times out. If the old container is stopped it is refused
either way and proves nothing: test while it runs, or after a rollback start.

### 5.3 Undo

<!-- notest -->
```bash
cd /opt/purchasing_data
IFACE=$(ip -o -4 route show to default | awk '{ print $5 }' | head -n 1)
RULE="-i $IFACE -p tcp -m conntrack --ctorigdstport 5433 --ctdir ORIGINAL -j DROP"
iptables -C DOCKER-USER $RULE 2>/dev/null && iptables -D DOCKER-USER $RULE && echo "rule removed" || echo "no such rule"
iptables -S DOCKER-USER
```

Expected: `rule removed` and a chain without the `DROP` rule. **STOP** if the rule is still
listed. Check IPv6 separately if `ss -ltn` showed `[::]:5433`: the same rule
with `ip6tables` (ask Claude first, the chain may not exist).

---

## Phase 6: Nightly backup of `minimart` (app up)

`scripts/minimart_backup.sh` dumps **only** the database `minimart` from `mmi-postgres`
(custom format, one consistent snapshot, the app keeps working) to
`/opt/backups/minimart/minimart_<timestamp>.dump`, keeps 14 days, and deletes nothing else:
the `pre_migration_*`, `cutover_*` and `rehearsal_*` directories are never touched.
It refuses to write a backup of a database without tables, and each run ends with exactly one
log line, `... OK <file> (<size>, <n> tables)` or `... FAILED: <why>`.

### 6.1 First backup, by hand

```bash
cd /opt/purchasing_data
chmod +x scripts/minimart_backup.sh
bash -n scripts/minimart_backup.sh && echo "script syntax OK"
scripts/minimart_backup.sh; echo "exit=$?"
ls -l /opt/backups/minimart/minimart_*.dump | tail -n 3
```

Expected:

```
script syntax OK
2026-10-03 22:30:10 +0700 OK /opt/backups/minimart/minimart_20261003_223010.dump (121M, 16 tables)
exit=0
-rw------- 1 root root 126877696 Oct  3 22:30 /opt/backups/minimart/minimart_20261003_223010.dump
```

**STOP** unless the line says `OK` and `exit=0`. A `FAILED:` line says why (cannot query
the database, no tables, `pg_dump` failed, dump unreadable, fewer table data entries
than tables); no file is kept. Paste it.

### 6.2 Cron and log rotation

Runs at 02:45, after procurement's 02:30 backup. Written with `printf`, so no pasted
line can end up inside a heredoc.

<!-- notest -->
```bash
cd /opt/purchasing_data
if [ -x scripts/minimart_backup.sh ] && ls /opt/backups/minimart/minimart_*.dump >/dev/null 2>&1; then
  printf '%s\n' 'SHELL=/bin/bash' 'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin' '45 2 * * * root /opt/purchasing_data/scripts/minimart_backup.sh >> /var/log/minimart-pg-backup.log 2>&1' > /etc/cron.d/minimart-pg-backup
  printf '%s\n' '/var/log/minimart-pg-backup.log {' '    monthly' '    rotate 6' '    compress' '    missingok' '    notifempty' '}' > /etc/logrotate.d/minimart-pg-backup
  chmod 644 /etc/cron.d/minimart-pg-backup /etc/logrotate.d/minimart-pg-backup
  echo "installed"
else
  echo "NOT INSTALLED: run 6.1 first"
fi
ls -l /etc/cron.d/minimart-pg-backup /etc/logrotate.d/minimart-pg-backup
logrotate -d /etc/logrotate.d/minimart-pg-backup 2>&1 | grep -iE 'error|considering'
systemctl is-active cron crond 2>/dev/null
```

Expected: `installed`, both files listed (`-rw-r--r-- 1 root root`), a `considering log
/var/log/minimart-pg-backup.log` line from the logrotate dry run (it rotates nothing), and
`active` for the one of `cron`/`crond` that exists (the other prints `inactive`). cron reads new files in `/etc/cron.d` by itself.
**STOP** on `NOT INSTALLED` (run 6.1). Undo: `rm -f /etc/cron.d/minimart-pg-backup /etc/logrotate.d/minimart-pg-backup`.

### 6.3 The morning check

Paste this the day after the first night (and whenever you like):

```bash
cd /opt/purchasing_data
tail -n 3 /var/log/minimart-pg-backup.log
tail -n 1 /var/log/minimart-pg-backup.log | grep -q ' OK ' && echo "BACKUP OK" || echo "BACKUP PROBLEM"
ls -lt /opt/backups/minimart/minimart_*.dump | head -n 3
```

Expected: the last log lines ending in `OK /opt/backups/minimart/minimart_<today>_0245xx.dump (...)`,
`BACKUP OK`, and the newest dumps with today's date. **STOP** on `BACKUP PROBLEM`: the line
above it says why (`FAILED: ...`); paste it and run 6.1 by hand.

### 6.4 Test a restore into a scratch database

A backup you never restored is a hope. This restores the newest dump into
`minimart_restore_test` (never into `minimart`), compares row counts with the live
database, and leaves the scratch database for you to look at until 6.5.

```bash
cd /opt/purchasing_data
SCRATCH=minimart_restore_test
DUMP=$(ls -1t /opt/backups/minimart/minimart_*.dump 2>/dev/null | head -n 1)
cnt() { docker exec -i mmi-postgres psql -U postgres -d "$1" -X -At -c "select table_schema || '.' || table_name || '|' || (xpath('/row/c/text()', query_to_xml(format('select count(*) as c from %I.%I', table_schema, table_name), false, true, '')))[1]::text from information_schema.tables where table_schema not in ('pg_catalog', 'information_schema') and table_type = 'BASE TABLE' order by 1" </dev/null; }
if [ ! -s "$DUMP" ]; then
  echo "STOP: no dump found (6.1)"
elif [ "$(docker exec -i mmi-postgres psql -U postgres -X -At -c "select count(*) from pg_database where datname = '$SCRATCH'" </dev/null)" != 0 ]; then
  echo "STOP: $SCRATCH already exists (6.5 drops it)"
else
  docker exec mmi-postgres createdb -U postgres "$SCRATCH" </dev/null
  docker exec -i mmi-postgres pg_restore -U postgres -d "$SCRATCH" --no-owner --no-acl --exit-on-error < "$DUMP"; echo "restore exit=$?"
  echo "tables in the dump copy: $(cnt "$SCRATCH" | wc -l | tr -d ' ')   in live minimart: $(cnt minimart | wc -l | tr -d ' ')"
  if diff <(cnt "$SCRATCH") <(cnt minimart) >/dev/null; then echo "row counts identical"; else echo "row counts differ (rows written since the dump are expected):"; diff <(cnt "$SCRATCH") <(cnt minimart) | head -n 10; fi
fi
```

Expected: `restore exit=0`, the same number of tables in both, and `row counts identical`
(or a few differing rows if the app wrote since the dump; every table must still exist).
**STOP** on a restore exit other than 0 or a different table count: the backup is not usable;
paste the output.

### 6.5 Drop the scratch database

```bash
cd /opt/purchasing_data
SCRATCH=minimart_restore_test
if [ "$SCRATCH" = minimart_restore_test ]; then
  docker exec mmi-postgres dropdb -U postgres --if-exists "$SCRATCH" </dev/null && echo "dropped $SCRATCH (if it existed)"
fi
docker exec -i mmi-postgres psql -U postgres -X -At -c "select datname from pg_database where datname like 'minimart%' order by 1" </dev/null
```

Expected: `dropped minimart_restore_test (if it existed)` and a database list with only
`minimart`. **STOP** if other `minimart%` names are listed (for example `minimart_rehearsal`
from a killed rehearsal): paste the list, do not drop anything by hand.

---

## Phase 7: Rollback

**Read this first.** Rolling back means going back to the data as it was at the final dump
(3.2). **Everything the app wrote to `minimart` on `mmi-postgres` after the cutover is lost
for the old database**: new records, edits, deletions. If real work was done since, export it first (7.2)
and decide with the people who did the work. If nobody used the app on `minimart` yet,
nothing is lost.

`scripts/minimart_migrate.sh --rollback-info` prints the same procedure with your exact
paths.

| Situation | Is the old container running? | Do |
|---|---|---|
| A | yes (phase 4 not done) | 7.2 (optional export), 7.3, done |
| B | no (stopped in 4.2) | 7.2 (optional export), 7.4, 7.3, done |
| C | its data is damaged or gone | 7.5 |

### 7.1 Print the procedure

```bash
cd /opt/purchasing_data
scripts/minimart_migrate.sh --rollback-info
```

Expected: `Manual rollback of the minimart migration. Nothing below runs automatically.`, the
warning about data written after the cutover, `Situation A`, `Situation B`, `Situation C`,
the dump directories, and `Never restart or remove mmi-postgres`. **STOP** here and read it
before anything else in this phase; it changes nothing.

### 7.2 Optional: save what was written since the cutover

A full dump of the **new** database, so that nothing is lost for good. It is an archive: it
cannot be loaded into the old database as it is. To bring rows written since the cutover
back later, restore it into a scratch database (the command in 6.4 with this file) and copy
the rows table by table; that is a manual job, ask Claude with the table names. Only runs when
`minimart` was actually cut over.

```bash
cd /opt/purchasing_data
umask 077
OUT=/opt/backups/minimart/rollback_export_$(date +%Y%m%d_%H%M%S).dump
MARK=$(docker exec -i mmi-postgres psql -U postgres -X -At -c "select coalesce(shobj_description(oid, 'pg_database'), '') from pg_database where datname = 'minimart'" </dev/null)
if ! echo "$MARK" | grep -q 'cutover-complete'; then
  echo "nothing to export: minimart was not cut over (marker: $MARK)"
elif docker exec mmi-postgres pg_dump -U postgres -d minimart -Fc > "$OUT.partial" </dev/null && [ -s "$OUT.partial" ] && docker exec -i mmi-postgres pg_restore --list < "$OUT.partial" | grep -q ' TABLE DATA '; then
  mv "$OUT.partial" "$OUT"
  echo "OK $OUT ($(du -h "$OUT" | cut -f1))"
else
  rm -f "$OUT.partial"
  echo "FAILED: no export written"
fi
```

Expected: `OK /opt/backups/minimart/rollback_export_<ts>.dump (<size>)`. **STOP** on `FAILED`: do not
roll back before you have an export, unless you accept the loss.

### 7.3 Situation A (and the last step of B): put the app back on the old database

Three steps, all in this order. The old container must be running (`docker ps`: B starts it in 7.4).

7.3a stops the app:

<!-- notest -->
```bash
cd /opt/purchasing_data
APP_CONTAINERS="minimart-app-1"     # as in 3.1
docker stop $APP_CONTAINERS
```

7.3b puts the original files back (the oldest `.bak_*` of each file is the state before
3.3b). It also keeps the edited file next to it, so nothing is lost:

```bash
cd /opt/purchasing_data
FILES="/opt/minimart/.env /opt/minimart/docker-compose.yml"    # as in 3.3a
TS=$(date +%Y%m%d_%H%M%S)
for f in $FILES; do
  b=$(ls -1 "$f".bak_* 2>/dev/null | head -n 1)
  if [ -z "$b" ]; then
    echo "NO BACKUP for $f: STOP"
  else
    cp -p "$f" "$f.after_cutover_$TS" && cp -p "$b" "$f" && echo "restored $f from $b (edited copy: $f.after_cutover_$TS)"
  fi
done
```

Expected: one `restored ... from ...bak_...` line per file. **STOP** on `NO BACKUP`.

7.3c starts the app on the old database: the override file (and with it the
network) is left out, so the app is exactly as before the migration.

<!-- notest -->
```bash
cd /opt/purchasing_data
APP_DIR=/opt/minimart
PROJECT=minimart      # as in 3.4a
SERVICE=app           # as in 3.4a
docker compose -p "$PROJECT" -f "$APP_DIR/docker-compose.yml" up -d --no-deps "$SERVICE"
sleep 15
docker compose -p "$PROJECT" -f "$APP_DIR/docker-compose.yml" ps
```

Expected: the app `Up`. Test it in the browser (3.5). The old database is as it was at the final
dump. `minimart` on `mmi-postgres` can stay where it is: it harms nothing, and the app no
longer uses it.

### 7.4 Situation B: start the old container first

```bash
cd /opt/purchasing_data
OLD=minimart-postgres-1
docker start "$OLD"
for i in 1 2 3 4 5 6 7 8 9 10; do docker exec "$OLD" pg_isready </dev/null && break; sleep 3; done
docker inspect -f 'state={{.State.Status}}' "$OLD"
```

Expected: `<address or socket> - accepting connections` and `state=running`. Then do 7.3 (3.1's `docker stop` first
if the app is still running on `minimart`). If you closed port 5433 in phase 5, the rule is
still there and the rollback is not exposed. **STOP** if it never accepts connections:
`docker logs --tail 30 minimart-postgres-1` shows why (paste it), then go to 7.5.

### 7.5 Situation C: the old container's data is damaged or gone

The dumps on the host are the source: `/opt/backups/minimart/pre_migration_<ts>/old.dump`
(the state before the migration) and `/opt/backups/minimart/cutover_<ts>/final.dump` (the
state at the cutover, the one you want). Restoring them into a **new empty database of a
fresh postgres container** (never into `mmi-postgres`' `minimart` unless you intend that, and
never over a running database) needs the container's name, user and database; ask Claude
for the exact commands. The form is:

<!-- notest -->
```bash
cd /opt/purchasing_data
docker exec -i <container> pg_restore -U <user> -d <database> --no-owner --exit-on-error < /opt/backups/minimart/cutover_<ts>/final.dump
```

Expected: no output at all (`--exit-on-error` makes any problem stop it with a message). **STOP**
on any message and paste it. This block is not run by the test harness (placeholders).

### 7.6 Optional, later: remove the unused `minimart` database from mmi-postgres

Only after the old setup has worked again for as long as you like. Refuses unless a rollback export
exists (7.2), the old container is running and nobody is connected to `minimart`. The three roles stay.

```bash
cd /opt/purchasing_data
EXPORT=$(ls -1t /opt/backups/minimart/rollback_export_*.dump 2>/dev/null | head -n 1)
OLD_UP=$([ "$(docker inspect -f '{{.State.Running}}' minimart-postgres-1 2>/dev/null)" = true ] && echo yes || echo no)
CONN=$(docker exec -i mmi-postgres psql -U postgres -X -At -c "select count(*) from pg_stat_activity where datname = 'minimart'" </dev/null)
if [ ! -s "$EXPORT" ]; then
  echo "REFUSED: no export under /opt/backups/minimart/rollback_export_*.dump (7.2)"
elif [ "$OLD_UP" != yes ]; then
  echo "REFUSED: the old container is not running"
elif [ "$CONN" != 0 ]; then
  echo "REFUSED: $CONN connection(s) to minimart"
else
  docker exec -i mmi-postgres psql -U postgres -X -v ON_ERROR_STOP=1 -c "DROP DATABASE minimart" </dev/null
fi
```

Expected: `DROP DATABASE`. **STOP** on `REFUSED` (nothing changed).

### The cutover stops midway: what each message means

The old database is only ever read, so it is intact in every row. `minimart` carries a marker
(`restoring`, `restored-unverified`, `cutover-complete`) that the script reads to decide
what is safe.

| What you see | Exit | Meaning | Do |
|---|---|---|---|
| `stop the minimart app first` and a list of connections | 3 | Something is still connected to the old database. Nothing changed. | Stop those clients (3.1 shows who), paste 3.2 again. |
| `no completed backup in ... pre_migration_*` | 3 | Phase 1 not done. | Run 1.1, then 3.2. |
| `role(s) missing` or `database minimart does not exist` | 3 | Phase 2 not done. | Run 2.3, then 3.2. |
| `minimart is not empty (N relation(s)) and was not written by this script` | 3 | Someone put objects in `minimart`. Refused to touch it. | Paste the line. Do not drop anything by hand. |
| `the cutover into minimart was already completed` | 3 | Done earlier. Refuses so that the app's data is not overwritten. | Continue at 3.3. To redo it deliberately you need rollback 7.2, 7.6 and 2.3 first. |
| `minimart holds an earlier attempt that was never verified` (printed as a note) | n/a | An earlier run stopped midway. It is dropped and rebuilt, keeping the collation. | Nothing: this is the script recovering. |
| `someone connected to the old database during the dump` | 3 | The final dump may not match. Nothing was restored. | Find what reconnected (the app restarting by itself? `docker ps`, restart policy), stop it, run 3.2 again. |
| `the cutover needs a SUPERUSER login on the old server` | 3 | The login the script found cannot see other users' connections, so the "app is stopped" check would be blind. | Paste it: Claude gives the `MINIMART_OLD_PGUSER=<superuser>` prefix for the command. |
| `not enough free space for the restore on mmi-postgres` | 3 | The data volume is shared with other systems. Nothing changed. | Paste it. Do not delete anything on `mmi-postgres` to make room. |
| `row level security policies ... reference role(s) missing` | 3 | The restore would fail. | Paste it. |
| `old database '...' has NO tables: wrong database?` | 3 | The script found the wrong database name. | Paste it: Claude gives the `MINIMART_OLD_DB=` prefix. |
| `refusing to rebuild minimart: the application roles are connected to it` | 3 | A retry would drop a database the app has started to use, which may hold newer data. | Stop the app, then paste the line before doing anything else. |
| `the data is verified, but the completion marker could not be written` | 1 | The data is fine. **Do not run 3.2 again** (it would rebuild `minimart`). | Run the `COMMENT ON DATABASE ...` command the message prints, then continue at 3.2a. |
| `old server ... is NEWER than the central server` | 1 | `pg_restore` cannot load it. | Paste it: needs a decision about `mmi-postgres`. |
| `extension(s) ... NOT available` | 1 | The restore would fail. Nothing changed. | Paste it (see 2.5). |
| `restore failed (single transaction: nothing was applied)` plus `pg_restore stderr` | 1 | Nothing reached `minimart`. The dump is kept in `cutover_<ts>/`. | Paste the stderr lines. Fix cause, run 3.2 again. |
| `post-restore step failed` | 1 | `minimart` is marked unverified. | Paste it. 3.2 again rebuilds it. |
| `VERIFY FAILED` / `verification FAILED: do NOT start the app` | 1 | The copy differs from the old database. | Do not start the app on `minimart`. Paste the `FAIL` lines. 3.2 again rebuilds it. The app can simply be started again on the old database (7.3b, 7.3c; nothing was changed in its files if you had not done 3.3 yet). |
| `the old database got a connection after the dump` | 3 | Data may differ. | Do not use `minimart`. Find and stop the client, run 3.2 again (it rebuilds). |
| interrupted (SSH lost, Ctrl-C) | n/a | `minimart` still has the `restoring` or `restored-unverified` marker or is empty. | Run 3.2 again. If the app was already stopped, it stays stopped until you start it. |

If the app has to run **before** the cutover can be fixed (the window is over), start it on
the old database: nothing in its files has been touched before 3.3b, so just start it with
the normal command for your setup (`docker start <app container>` works if you only stopped it in 3.1).

---

## Known limits

- **Versions.** The tooling was tested with PostgreSQL 14 (old) to 15 (new) on a laptop, not
  16 to 16 as on the server. `pg_restore` of a dump from the same or an older major
  version is supported, and the script refuses a newer old server. Run the rehearsal: it is the real
  test.
- **Extensions.** The script stops before restoring if an extension the old database uses is
  not available on `mmi-postgres`. Adding one means changing the shared server: that is a
  decision, not part of this runbook.
- **No freeze of the old database against outside clients.** The script checks for other
  connections before and after the dump, but nothing stops a client on the public port 5433
  from connecting between the check and `docker stop`, or from writing to the old database
  after you stop the app. Keep the window short, and close port 5433 (phase 5) once the old
  container no longer has to be reachable.
- **Time columns are reported, not fixed.** `--inspect` says whether `timestamp` (no time zone)
  columns look like UTC or local wall clock. The migration copies values byte for byte and
  never shifts data. If the report says the app writes UTC into local columns (as procurement
  did), that is a separate correction after the migration, with its own backup.
- **The app role is DML only.** `minimart_app` has SELECT, INSERT, UPDATE, DELETE on tables and
  USAGE, SELECT, UPDATE on sequences, no DDL and no TRUNCATE. An app that migrates its schema at
  startup needs the escape hatch in 3.4c. New tables created later by `minimart_owner` are
  covered by default privileges; tables created by other roles are not.
- **Privileges are not carried over.** The old grants and owners are dropped on purpose
  (`--no-owner --no-acl`): everything is owned by `minimart_owner`. Roles of the old server
  (the app's old login) do not exist on `mmi-postgres`; they are saved in `globals.sql`.
- **Collation** is only a choice while `minimart` is empty (2.2, 2.4).
- **Materialised views** are compared by the catalog inventory only, not row by row (their
  contents are rebuilt from the tables).
- **`--verify` after real use** reports the tables the app changed as differences (4.1).
- **The rehearsal reads the old database twice** (rehearsal and cutover dump): a short extra load.

## Reference

| What | Where |
|---|---|
| Migration script | `scripts/minimart_migrate.sh` (`--inspect`, `--backup-old`, `--rehearse`, `--cutover`, `--verify`, `--rollback-info`), log `/var/log/minimart-migration.log` |
| Roles and database setup | `db/minimart_setup.sql` (idempotent; the passwords come from `.env` on stdin) |
| Backups of the old database | `/opt/backups/minimart/pre_migration_<ts>/` and `cutover_<ts>/final.dump` (keep them) |
| Nightly backup | `scripts/minimart_backup.sh`, cron `/etc/cron.d/minimart-pg-backup` 02:45, log `/var/log/minimart-pg-backup.log`, `/opt/backups/minimart/minimart_*.dump` (14 days) |
| Passwords | `/opt/purchasing_data/.env`: `MINIMART_APP_PASSWORD`, `MINIMART_RO_PASSWORD` (mode 600; copy of the app one in the app's env file) |
| App files | `/opt/minimart`: `.env.bak_<ts>`, `docker-compose.yml.bak_<ts>`, `docker-compose.mmi-network.yml` |
| Mirror into ClickHouse | `RUNBOOK_MINIMART_MIRROR.md` (after the cutover; `db/minimart_ro_grants.sql`) |
