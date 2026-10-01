# Runbook — Procurement cutover from ClickHouse to PostgreSQL

Run on **76.13.19.246** as **root**, in one shell session, top to bottom.
Every step has a command, what you should see, and what to do if you don't.

**STOP** means: do not continue. Do what the STOP line says (usually one
command to put the old app back), then paste the output into Claude.

After this runbook:

```
browser → procurement_app ──(read/write)──▶ mmi-postgres / database `procurement`   (source of truth)
                                                   │
                     every 15 min, host cron:      ▼  scripts/ch_sync.sh
                         procurement_clickhouse pulls changed rows      (warehouse, rollback copy)
```

| Phase | What | Minutes | App |
|---|---|---|---|
| 0 | Pre-checks (read-only) | 10 | up |
| 1 | Backups | 5 | up |
| 2 | Check out the branch, add `.env` values | 5 | up |
| 3 | Postgres roles, database, schema | 5 | up |
| 4 | Build the new image, test the connection | 10 | up |
| 5 | Stop the app, migrate | 10 | **down** |
| 6 | Start the app on Postgres, smoke tests | 10 | **up, on Postgres** |
| 7 | ClickHouse as warehouse: config, first sync, cron | 15 | up |
| 8 | Rollback (only if needed) | 15 | — |

About 70 minutes in total; the site is down for about 20 (phases 5–6).

Things never to run during or after this cutover:
`docker compose down -v` (deletes the ClickHouse volume), any `DROP` or
`TRUNCATE` in ClickHouse, anything against the `hauling_tracker` database, and
`docker restart mmi-postgres` (it serves another live system).

---

## Session setup — paste first, and again if your SSH session drops

```bash
cd /opt/purchasing_data
mkdir -p /opt/backups/procurement && chmod 700 /opt/backups/procurement
[ -f /root/pg_cutover_ts ] || date +%Y%m%d_%H%M%S > /root/pg_cutover_ts
TS=$(cat /root/pg_cutover_ts)
BK=/opt/backups/procurement/pre_cutover_$TS
mkdir -p "$BK" && chmod 700 "$BK"

# clickhouse-client inside the container, using the container's own login.
# chq does not read stdin (so it cannot swallow the next lines you paste);
# chqi does, for `chqi … < file` only.
chq()  { docker exec    procurement_clickhouse sh -c 'exec clickhouse-client --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" --database procurement "$@"' chq "$@"; }
chqi() { docker exec -i procurement_clickhouse sh -c 'exec clickhouse-client --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" --database procurement "$@"' chq "$@"; }
# psql as the postgres superuser inside mmi-postgres (no stdin, same reason)
pgq() { docker exec mmi-postgres psql -U postgres -X -v ON_ERROR_STOP=1 "$@"; }
# read one value from .env without printing it
envval() { grep -m1 "^$1=" /opt/purchasing_data/.env | cut -d= -f2-; }
SYNCED="purposes users vendors items purchase_requests purchase_request_items purchase_orders purchase_order_items purchase_order_charges approval_actions gl_exports item_requests pr_templates pr_template_items"
echo "TS=$TS BK=$BK"
```

Expected: `TS=2026…_…… BK=/opt/backups/procurement/pre_cutover_2026…`

---

## Phase 0 — Pre-checks (nothing changes)

### 0.1 Where the server is now

```bash
git rev-parse HEAD | tee /root/pg_cutover_old_commit
git branch --show-current
git status --short
docker ps --format '{{.Names}}\t{{.Image}}\t{{.Status}}' | grep -E 'procurement|mmi-postgres'
```

Expected: a commit hash (saved for rollback; probably `dcc70c2…` on
`clickhouse-caps-and-credential-removal`), `procurement_app`,
`procurement_clickhouse (healthy)` and `mmi-postgres` all `Up`.
`git status` may list modified files (handled in 2.1); note them.

### 0.2 The mmi-postgres network

```bash
docker inspect mmi-postgres -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{"\n"}}{{end}}'
```

Expected: one or more network names. Pick the one that is **not** `bridge`,
`host` or `none` (a project network such as `something_default` or
`mmi_net`) and set it:

```bash
NET=put_the_network_name_here
echo "$NET" > /root/pg_cutover_net
docker network inspect "$NET" -f 'driver={{.Driver}} scope={{.Scope}}'
for c in $(docker network inspect "$NET" -f '{{range .Containers}}{{.Name}} {{end}}'); do
  echo "$c: $(docker inspect "$c" -f "{{json (index .NetworkSettings.Networks \"$NET\").Aliases}}")"
done
```

Expected: `driver=bridge scope=local`, then each container on that network with
its aliases (mmi-postgres, and maybe the hauling system's containers).

**STOP** if the only network is `bridge`/`host`, or if any container listed has
an alias or name of exactly `app`, `clickhouse`, `procurement_app` or
`procurement_clickhouse` — joining that network would make those names
ambiguous for the other system. Nothing to undo; paste the output.

### 0.3 Postgres: version, access rules, nothing named procurement yet

```bash
pgq -Atc "select version()"
pgq -Atc "show password_encryption"
pgq -Atc "select line_number, type, database, user_name, address, auth_method from pg_hba_file_rules where type like 'host%'"
pgq -Atc "select datname from pg_database order by 1"
pgq -Atc "select rolname from pg_roles where rolname like 'procurement%'"
```

Expected:
- `PostgreSQL 16.…`, `scram-sha-256`
- a `host` rule that matches all databases/users from any address with
  `scram-sha-256` (or `md5`) — the postgres image's default
  `host|{all}|{all}|all|…|scram-sha-256`. Containers on the docker network
  connect over TCP from a 172.x address and need that rule.
- `hauling_tracker`, `postgres`, `template0`, `template1` — and **no**
  `procurement`.
- no rows for the roles.

**STOP** if no host rule admits other containers (changing `pg_hba.conf` means
reconfiguring a container another system depends on; that needs a decision).
If `procurement` or the roles already exist from an earlier attempt, check the
database is empty (`pgq -d procurement -Atc "select count(*) from purchase_requests"`
→ `0` or "relation does not exist") and continue; the setup is re-runnable.

### 0.4 ClickHouse: what holds data

```bash
chq --query "SELECT name, total_rows FROM system.tables WHERE database='procurement' AND total_rows > 0 ORDER BY name FORMAT PrettyCompactMonoBlock"
chq --query "SELECT name, total_rows FROM system.tables WHERE database='procurement' AND total_rows > 0
             AND name NOT IN ('purposes','users','vendors','items','purchase_requests','purchase_request_items','purchase_orders','purchase_order_items','purchase_order_charges','approval_actions','gl_exports','item_requests','pr_templates','pr_template_items')
             FORMAT PrettyCompactMonoBlock"
chq --query "SHOW CREATE TABLE procurement.gl_exports" --format TSVRaw | head -3
chq --query "SELECT 'item_requests', countIf(toUUIDOrNull(request_id) IS NULL) FROM item_requests UNION ALL SELECT 'gl_exports', countIf(toUUIDOrNull(toString(gl_export_id)) IS NULL) FROM gl_exports FORMAT TSV"
```

Expected:
- First list: the tables the app uses, with row counts. Note them.
- Second list (non-empty tables the migration does **not** carry over): ideally
  empty. Anything listed stays in ClickHouse untouched, but the new app will not
  see it. **STOP** and paste the list if it shows anything other than
  `app_sessions` — someone has to decide whether that data matters.
- `gl_exports`: either `ENGINE = MergeTree` with `gl_export_id UUID` (schema
  file) or `ReplacingMergeTree(version)` with `gl_export_id String`
  (old server.js). The sync handles both; just note which.
- Non-UUID ids: both counts `0`. A non-zero count is not a blocker, but those
  rows will appear twice in the warehouse after the first sync (old id and the
  migrated uuid); paste it into the report.

### 0.5 Disk, cron, tools, branch

```bash
df -h / /opt /var/lib/docker | sort -u
systemctl is-active crond; command -v flock openssl python3 curl
git fetch origin && git branch -r | grep postgres-oltp-migration
```

Expected: at least 2 GB free on each; `active`; four paths; and
`origin/postgres-oltp-migration`.

**STOP** if the branch is missing (it has not been pushed yet) or the disk has
under 1 GB free. Nothing to undo.

---

## Phase 1 — Backups

### 1.1 ClickHouse: every table, raw, plus its DDL

`BACKUP DATABASE … TO File(...)` needs a `backups` path in the server config,
which this server does not have (adding one means a config change and a
restart before we have a backup). Copying the Docker volume needs ClickHouse
stopped. A per-table `SELECT * … FORMAT Native` needs neither, keeps every
row version and the exact column types, and is a few hundred KB here.

```bash
for t in $(chq --query "SELECT name FROM system.tables WHERE database='procurement' AND engine LIKE '%MergeTree' ORDER BY name"); do
  chq --query "SHOW CREATE TABLE procurement.\`$t\`" --format TSVRaw > "$BK/ch_$t.sql"
  chq --query "SELECT * FROM procurement.\`$t\` FORMAT Native" > "$BK/ch_$t.native"
  printf '%-32s rows=%-8s bytes=%s\n' "$t" "$(chq --query "SELECT count() FROM procurement.\`$t\`")" "$(stat -c %s "$BK/ch_$t.native")"
done | tee "$BK/ch_counts.txt"
```

Expected: one line per table (about 45). Every table with rows has
`bytes` > 0.

To restore one table later (only into an empty or re-created table, otherwise
rows double): `chqi --multiquery < "$BK/ch_T.sql"` then
`chqi --query "INSERT INTO procurement.T FORMAT Native" < "$BK/ch_T.native"`.

### 1.2 Postgres roles (before we create any)

The shared server's role list. Not a backup of hauling_tracker — that database
is not read at all.

```bash
pgq -c "select 1" >/dev/null && docker exec mmi-postgres pg_dumpall -U postgres --globals-only > "$BK/pg_globals.sql"
chmod 600 "$BK/pg_globals.sql"; grep -c '^CREATE ROLE' "$BK/pg_globals.sql"
```

Expected: a number ≥ 1 (the existing roles).

### 1.3 Config and image

```bash
cp -p .env "$BK/env.before" && chmod 600 "$BK/env.before"
cp -p docker-compose.yml "$BK/docker-compose.yml.before"
docker tag "$(docker inspect procurement_app -f '{{.Image}}')" procurement-app:pre-pg-$TS
docker image ls procurement-app
ls -la "$BK" | head
```

Expected: an image tagged `procurement-app:pre-pg-<TS>` (fallback for
rollback), and the backup files.

---

## Phase 2 — Code and `.env` (no container changes yet)

### 2.1 Clear local edits out of the way

```bash
git status --short
git diff > "$BK/server_local_changes.patch"; wc -l "$BK/server_local_changes.patch"
git stash push -m "pre-pg-cutover $TS" || true
```

The server collects stray edits; they are saved in the patch and in the stash.
**Never** `git stash pop` afterwards (it would put old files back over the
new ones).

### 2.2 Check out the branch

`git pull origin main` (the old deploy routine) does **not** apply: this work is
on its own branch until it is merged.

```bash
git checkout -B postgres-oltp-migration origin/postgres-oltp-migration
git log -1 --oneline
ls -l db/postgres_setup.sql db/postgres_schema.sql db/ch_sync.sql scripts/ch_sync.sh scripts/pg_backup.sh migrate_ch_to_pg.js
chmod +x scripts/ch_sync.sh scripts/pg_backup.sh
```

Expected: the branch's latest commit, and all six files listed.
If checkout refuses because "untracked working tree files would be
overwritten", move each listed file into `$BK/` (`mv FILE "$BK/"`) and repeat.

From here the compose file on disk is the new one. The running containers are
unaffected until phases 5–7 — do **not** run `docker compose up` before then.

### 2.3 Add the new `.env` values

```bash
NET=$(cat /root/pg_cutover_net)
[ -z "$(tail -c1 .env)" ] || echo >> .env
grep -q '^MMI_PG_NETWORK='  .env || echo "MMI_PG_NETWORK=$NET" >> .env
grep -q '^PG_APP_PASSWORD=' .env || echo "PG_APP_PASSWORD=$(openssl rand -hex 24)" >> .env
grep -q '^PG_RO_PASSWORD='  .env || echo "PG_RO_PASSWORD=$(openssl rand -hex 24)" >> .env
chmod 600 .env
grep -E '^(MMI_PG_NETWORK|PG_APP_PASSWORD|PG_RO_PASSWORD)=' .env | awk -F= '{print $1, length($2)}'
docker compose config --quiet && echo "compose OK"
```

Expected:
```
MMI_PG_NETWORK <length of the name>
PG_APP_PASSWORD 48
PG_RO_PASSWORD 48
compose OK
```

---

## Phase 3 — Postgres: roles, database, schema

Only creates `procurement_owner`, `procurement_app`, `procurement_ro` and the
`procurement` database. `CREATE DATABASE` copies `template0` and takes no lock
on any other database.

### 3.1 Roles and database (first run of the setup script)

Passwords go in on stdin, so they never appear in the process list.

```bash
{ printf '\\set app_password %s\n\\set ro_password %s\n' "$(envval PG_APP_PASSWORD)" "$(envval PG_RO_PASSWORD)"; cat db/postgres_setup.sql; } \
  | docker exec -i mmi-postgres psql -U postgres -X; echo "exit=$?"
```

Expected:
```
  database   |     db_owner      | tables_in_public | tables_not_owned_by_owner
-------------+-------------------+------------------+---------------------------
 procurement | procurement_owner |                0 |                         0
exit=0
```

### 3.2 Schema, created as the owner role

```bash
{ echo 'SET ROLE procurement_owner;'; cat db/postgres_schema.sql; } \
  | docker exec -i mmi-postgres psql -U postgres -X -q -v ON_ERROR_STOP=1 -d procurement; echo "exit=$?"
```

Expected: `exit=0` and nothing else.

### 3.3 Grants on the new tables (second run of the same script)

```bash
{ printf '\\set app_password %s\n\\set ro_password %s\n' "$(envval PG_APP_PASSWORD)" "$(envval PG_RO_PASSWORD)"; cat db/postgres_setup.sql; } \
  | docker exec -i mmi-postgres psql -U postgres -X; echo "exit=$?"
```

Expected: same table as 3.1 but `tables_in_public` = **16**,
`tables_not_owned_by_owner` = **0**, `exit=0`.

### 3.4 Check the privileges

```bash
docker exec mmi-postgres psql -U procurement_app -h 127.0.0.1 -d procurement -XAtc "select current_user, count(*) from purchase_requests"
docker exec mmi-postgres psql -U procurement_ro  -h 127.0.0.1 -d procurement -XAtc "select current_user, current_setting('TimeZone'), (select count(user_id) from users)"
docker exec mmi-postgres psql -U procurement_ro  -h 127.0.0.1 -d procurement -XAtc "select password_hash from users"
pgq -Atc "select datacl from pg_database where datname = 'procurement'"
pgq -Atc "select datname, pg_get_userbyid(datdba) from pg_database where datname = 'hauling_tracker'"
```

Expected:
- `procurement_app|0`
- `procurement_ro|UTC|0`
- `ERROR:  permission denied for table users` — **this error is correct**
- `{procurement_owner=CTc/procurement_owner,procurement_app=Tc/procurement_owner,procurement_ro=c/procurement_owner}`
  (no entry starting with `=`: PUBLIC cannot connect)
- `hauling_tracker|<its usual owner>` — unchanged

(These run inside the container over loopback, which the postgres image
trusts, so they test grants, not passwords. Passwords are tested in 4.2.)

Undo for phases 2–3 if you abandon here (nothing uses it yet):
`pgq -c "DROP DATABASE procurement"` then
`pgq -c "DROP ROLE procurement_app; DROP ROLE procurement_ro; DROP ROLE procurement_owner"`.

---

## Phase 4 — Build the new image, test connections (old app still serving)

### 4.1 Build

```bash
docker compose build app 2>&1 | tail -5
docker compose run --rm --no-deps -T app ls -1 server.js db.js migrate_ch_to_pg.js </dev/null
```

Expected: build ends with the image `… Built`; the `ls` prints the three file
names. (`-T … </dev/null` on every `docker compose run` here keeps it from
reading the lines you paste after it.) `docker compose run` starts a throw-away container on the new networks;
it does not touch the running `procurement_app`.

**STOP** if the build fails. The old app is still running untouched; paste the
output.

### 4.2 Postgres login over the network, with the real password

```bash
docker compose run --rm --no-deps -T app node -e "
const {Client}=require('pg'); const c=new Client();
c.connect().then(()=>c.query('select current_user, current_database(), (select count(*) from purchase_requests) as prs'))
 .then(r=>{console.log(JSON.stringify(r.rows[0])); return c.end();})
 .catch(e=>{console.error('FAIL', e.message); process.exit(1);});" </dev/null
```

Expected: `{"current_user":"procurement_app","current_database":"procurement","prs":"0"}`

- `getaddrinfo ENOTFOUND mmi-postgres` → wrong `MMI_PG_NETWORK`; fix `.env`, rerun.
- `password authentication failed` → rerun 3.3 (it re-applies the `.env` passwords).
- `no pg_hba.conf entry` → **STOP** (see 0.3).

### 4.3 Migration dry run now, while the old app is still serving

The pre-flight checks (orphaned item ids, duplicate PR/PO numbers, duplicate
usernames, bad dates) are what is most likely to stop the migration. Find out
now, with no downtime, instead of in phase 5. The dry run only reads
ClickHouse and writes nothing anywhere.

```bash
docker compose run --rm --no-deps -T app node migrate_ch_to_pg.js --dry-run </dev/null 2>&1 | tee "$BK/migrate_dry_run_early.log"; echo "exit=${PIPESTATUS[0]}"
```

Expected: the report ends with `DRY RUN complete — nothing written`, `exit=0`.

**STOP** on any other exit code. The old app is still serving and nothing was
changed; paste `$BK/migrate_dry_run_early.log`. Do not start phase 5 until this
passes (new rows created in the meantime are normally harmless; 5.3 repeats the
dry run after the app is stopped).

---

## Phase 5 — Stop the app and migrate  ⟵ downtime starts

Tell users the system is down for about 20 minutes. Everyone is logged out
(sessions move to Postgres).

### 5.1 Let the migration restart identity sequences

`migrate_ch_to_pg.js --truncate` (only needed for a re-run) truncates with
`RESTART IDENTITY`, which Postgres allows only for the owner of the sequences.
Grant the owner role to the app login for the migration only; 5.6 takes it back.

```bash
pgq -d procurement -c "GRANT procurement_owner TO procurement_app"
```

Expected: `GRANT ROLE`

### 5.2 Stop the old app (stop, not remove — it is the fast way back)

```bash
docker stop procurement_app
docker ps -a --filter name=procurement_app --format '{{.Names}} {{.Status}}'
```

Expected: `procurement_app Exited (…)`.

**Fast way back from any STOP in phases 5 and 6 (before 6.1):**
```bash
pgq -d procurement -c "REVOKE procurement_owner FROM procurement_app"
docker start procurement_app
```
The old container still has the old code and config, and ClickHouse has not
been written to — no data is lost.

### 5.3 Dry run

```bash
docker compose run --rm --no-deps -T app node migrate_ch_to_pg.js --dry-run </dev/null 2>&1 | tee "$BK/migrate_dry_run.log"; echo "exit=${PIPESTATUS[0]}"
```

Expected: the script's report ending in success, `exit=0`.

**STOP** on any other exit code (`1` = pre-flight failed: duplicate legacy ids,
duplicate PR/PO numbers, orphans…; `3` = unexpected error). Run the fast way
back above, then paste `$BK/migrate_dry_run.log` into Claude.

### 5.4 Migrate

```bash
docker compose run --rm --no-deps -T app node migrate_ch_to_pg.js </dev/null 2>&1 | tee "$BK/migrate.log"; echo "exit=${PIPESTATUS[0]}"
```

Expected: `exit=0`.

- `exit=1` (refused / pre-flight) or `exit=3` (rolled back): nothing was
  written. **STOP**: fast way back, paste `$BK/migrate.log`.
- `exit=2`: data was committed but its own verification found a mismatch.
  **STOP**: fast way back (the old app reads ClickHouse, which is intact), paste
  the log. A later re-run uses `--truncate`.

### 5.5 Row counts, side by side

```bash
for t in $SYNCED; do
  e=$(chq --query "SELECT engine FROM system.tables WHERE database='procurement' AND name='$t'")
  f=""; [ "$e" = MergeTree ] || f=FINAL      # FINAL only on ReplacingMergeTree
  printf '%-24s pg=%-7s ch=%s\n' "$t" \
    "$(pgq -d procurement -Atc "select count(*) from $t")" \
    "$(chq --query "SELECT count() FROM $t $f")"
done
```

Expected: matching numbers, except where the migration report explained a
difference (e.g. rows it skipped). The migration has already verified itself;
this is for your own eyes.

### 5.6 Take the owner role back

```bash
pgq -d procurement -c "REVOKE procurement_owner FROM procurement_app"
pgq -Atc "select pg_has_role('procurement_app', 'procurement_owner', 'MEMBER')"
```

Expected: `REVOKE ROLE`, then `f`.

### 5.7 Back up the freshly migrated Postgres data

Before any user writes to it (the nightly cron only starts in phase 7).

```bash
scripts/pg_backup.sh; echo "exit=$?"
```

Expected: `… OK /opt/backups/procurement/procurement_<date>.dump (…, 16 tables)`, `exit=0`.
If it fails, fix it before 6.1 (paste the output); the app is still stopped.

---

## Phase 6 — Start the app on Postgres  ⟵ point of no return

`docker compose up -d app` replaces the old `procurement_app` container, and
from the first user write on, Postgres holds data ClickHouse does not have
until the sync (phase 7) runs. Going back after this is phase 8.

### 6.1 Start

```bash
docker compose up -d app
sleep 10
docker compose ps app
docker compose logs --tail=20 app
```

Expected: `procurement_app … Up`, and the log shows
`Connecting to Postgres...`, `Postgres OK`, `Fuse index built (ok)`,
`Procurement app running → http://localhost:3000`.

If it shows `Postgres unreachable — exiting` and restarts: see 4.2. If you
cannot fix it within a few minutes: phase 8, case A.

### 6.2 Smoke tests

Use a real admin or purchasing login. The password is read without echo and
never stored in shell history.

```bash
curl -s -o /dev/null -w 'home %{http_code}\n' http://127.0.0.1:3000/
```

Paste this line **on its own**, then type the username and password:

```bash
read -rp 'Username: ' U; read -rsp 'Password: ' P; echo
```

```bash
CJ=$(mktemp)
curl -s -c "$CJ" -H 'Content-Type: application/json' \
  --data "$(U="$U" P="$P" python3 -c 'import json,os; print(json.dumps({"username":os.environ["U"],"password":os.environ["P"]}))')" \
  http://127.0.0.1:3000/api/auth/login; echo
unset P
curl -s -b "$CJ" http://127.0.0.1:3000/api/auth/me; echo
curl -s -b "$CJ" http://127.0.0.1:3000/api/pr | head -c 400; echo
curl -s -b "$CJ" http://127.0.0.1:3000/api/po | head -c 400; echo
rm -f "$CJ"
```

Expected: `home 200`; login returns `{"success":true,"user":{…}}`; `/me` shows
the same user; `/api/pr` and `/api/po` start with JSON listing the most recent
PR/PO numbers you know exist.

Then in the browser: log in, open the PR list and one PR, the PO list and
one PO, and search items. Watch `docker compose logs -f app` while users start
working; the first real approval or PO is the write test.

**STOP** (→ phase 8, case A) if login fails for known users or the lists are
empty or wrong.

---

## Phase 7 — ClickHouse becomes the warehouse

The app does not depend on ClickHouse any more, so this phase causes no
downtime.

### 7.1 Restart ClickHouse with the Postgres source

```bash
docker compose up -d clickhouse
for i in $(seq 1 30); do s=$(docker inspect -f '{{.State.Health.Status}}' procurement_clickhouse); [ "$s" = healthy ] && break; sleep 3; done; echo "$s"
docker logs --tail=20 procurement_clickhouse 2>&1 | grep -iE 'error|exception' || echo "no errors"
```

Expected: `healthy`, `no errors`. The data volume is kept (only the container
is recreated).

If it does not become healthy: the app is unaffected. Put the old ClickHouse
config back and paste the logs:
```bash
git show "$(cat /root/pg_cutover_old_commit)":docker-compose.yml > /root/old-compose.yml
docker compose -f /root/old-compose.yml --project-directory /opt/purchasing_data up -d clickhouse
```

### 7.2 Can ClickHouse read Postgres, and are timestamps right?

```bash
chq --query "SELECT count() FROM postgresql(pg_procurement, table = 'purchase_requests')"
pgq -d procurement -Atc "select count(*) from purchase_requests"
chq --query "SELECT toString(max(toDateTime64(toString(updated_at), 6, 'UTC'))) FROM postgresql(pg_procurement, table = 'purchase_requests')"
pgq -d procurement -Atc "select to_char(max(updated_at) at time zone 'UTC', 'YYYY-MM-DD HH24:MI:SS.US') from purchase_requests"
```

Expected: the two counts are equal; the two timestamps are **identical**.

Two more reads that the sync depends on and the first query does not cover
(`users` has a column-level grant; `default_qty` is an unconstrained `numeric`):

```bash
chq --query "SELECT count(user_id), count(legacy_user_id) FROM postgresql(pg_procurement, table = 'users')"
chq --query "SELECT count(), sum(toFloat64(default_qty)) FROM postgresql(pg_procurement, table = 'pr_template_items')"
```

Expected: both run without an error (numbers only matter if the migration
loaded data: users and template rows). A `permission denied for table users`
or a type error here means the sync would fail at that table in 7.3: **do not
continue**, paste the error. The app is unaffected.

- `Not enough privileges … NAMED COLLECTION` → the users.d grant did not load;
  paste `docker exec procurement_clickhouse ls /etc/clickhouse-server/users.d/`.
- `password authentication failed for user "procurement_ro"` → rerun 3.3, then
  `docker compose up -d --force-recreate clickhouse`.
- timestamps differ by whole hours → do not continue to 7.3; paste both.

### 7.3 First sync (full)

```bash
scripts/ch_sync.sh --full; echo "exit=$?"
```

Expected: `… [full] start: rows changed after 1970-01-01 00:00:00.000 UTC`,
`… [full] OK in Ns; watermark now … UTC`, `exit=0`.

### 7.4 Verify

```bash
scripts/ch_sync.sh --verify; echo "exit=$?"
chq --query "SELECT username, password_hash != '' AS has_hash FROM users FINAL ORDER BY username FORMAT PrettyCompactMonoBlock"
scripts/ch_sync.sh; echo "exit=$?"
```

Expected:
- a table with `missing_in_ch` = **0** on every row, `verify: OK`, `exit=0`.
  `ch_distinct_ids` may exceed `pg_rows` (ClickHouse also keeps rows the
  migration did not carry over); it must never be lower.
- every pre-cutover user has `has_hash = 1` (their ClickHouse hash is kept, so
  the rollback app can still log them in).
- an incremental run: `[incremental] OK`, `exit=0`.

### 7.5 Cron: sync every 15 minutes, Postgres backup nightly

```bash
cat > /etc/cron.d/procurement-ch-sync <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
*/15 * * * * root /opt/purchasing_data/scripts/ch_sync.sh >> /var/log/procurement-ch-sync.log 2>&1
EOF
cat > /etc/cron.d/procurement-pg-backup <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
30 2 * * * root /opt/purchasing_data/scripts/pg_backup.sh >> /var/log/procurement-pg-backup.log 2>&1
EOF
cat > /etc/logrotate.d/procurement <<'EOF'
/var/log/procurement-ch-sync.log /var/log/procurement-pg-backup.log {
    monthly
    rotate 6
    compress
    missingok
    notifempty
}
EOF
chmod 644 /etc/cron.d/procurement-ch-sync /etc/cron.d/procurement-pg-backup /etc/logrotate.d/procurement
scripts/pg_backup.sh; echo "exit=$?"
ls -la /opt/backups/procurement/
```

Expected: `… OK /opt/backups/procurement/procurement_<date>.dump (…, 16 tables)`,
`exit=0`, and the dump listed.

Twenty minutes later:
```bash
tail -5 /var/log/procurement-ch-sync.log
```
Expected: `[incremental] OK` lines at :00/:15/:30/:45.

### 7.6 Done

Tell users the system is back. Future deploys from this branch:
`cd /opt/purchasing_data && git pull origin postgres-oltp-migration && docker compose up -d --build app`
(until the branch is merged into `main`).

---

## Phase 8 — Rollback

### Case A — before users have written anything on Postgres

(The app was started in 6.1 but failed smoke tests, or nobody has used it yet.)

```bash
docker stop procurement_app
git checkout "$(cat /root/pg_cutover_old_commit)"
docker compose up -d --build
docker compose ps
```

Expected: both services `Up`, the app on ClickHouse exactly as before the
cutover. Leave the Postgres database in place for the next attempt (the next
migration run needs `--truncate`).

### Case B — after users have written to Postgres

The 15-minute sync has been copying every insert and update into ClickHouse
with a newer `version`, so the ClickHouse-backed app sees them. Run one last
sync after stopping the app so nothing from the final minutes is missed:

```bash
docker stop procurement_app                         # no more writes
scripts/ch_sync.sh; echo "exit=$?"                  # must be exit=0
scripts/ch_sync.sh --verify; echo "exit=$?"         # missing_in_ch all 0
rm -f /etc/cron.d/procurement-ch-sync /etc/cron.d/procurement-pg-backup   # scripts leave with the branch
git checkout "$(cat /root/pg_cutover_old_commit)"   # or: git checkout clickhouse-caps-and-credential-removal
docker compose up -d --build                        # old app + old ClickHouse config
docker compose ps
```

Expected: `Up` for both; log in, and the PRs/POs created on Postgres are there.

What does not come back:
- **Passwords set after cutover.** The warehouse never receives password
  hashes from Postgres. Pre-cutover users keep their old ClickHouse hash
  and log in as before. Users created, or passwords changed, after cutover need
  a reset with `create_user.js` on the old build.
- **Hard deletes.** The sync only inserts. The new app soft-deletes
  (`is_deleted = 1`, which does sync); anything removed in Postgres by hand
  would reappear.
- **Sessions.** Everyone is logged out again.
- **Writes after the last successful sync, if the sync is not running.** Check
  how far it got:
  `chq --query "SELECT max(synced_through) FROM _sync_state"` (UTC) and
  `grep FAILED /var/log/procurement-ch-sync.log | tail`. As long as Postgres is
  up, the `scripts/ch_sync.sh` in the block above closes the gap. If Postgres
  itself is lost, restore the latest dump (below) and then sync.

Going forward again later: re-run phases 5–7 with `--truncate` on the migration
(ClickHouse then holds the newest data).

### Restoring a Postgres backup

```bash
docker stop procurement_app
ls -t /opt/backups/procurement/procurement_*.dump | head -3
docker exec -i mmi-postgres pg_restore -U postgres -d procurement --clean --if-exists --single-transaction < /opt/backups/procurement/procurement_YYYYMMDD_HHMMSS.dump; echo "exit=$?"
docker compose up -d app
```

Expected: `exit=0`. The dump includes the grants, so no setup re-run is
needed.

---

## Reference

| What | Where |
|---|---|
| Roles and database setup | `db/postgres_setup.sql` (re-runnable; rotates passwords) |
| Schema | `db/postgres_schema.sql`, applied as `procurement_owner` |
| Warehouse sync | `scripts/ch_sync.sh` (`--full`, `--verify`, `--print`), SQL in `db/ch_sync.sql`, log `/var/log/procurement-ch-sync.log`, watermark `procurement._sync_state` in ClickHouse |
| Postgres source for ClickHouse | `db/clickhouse-config.d/30-pg-source.xml`, `30-pg-source-users.xml` |
| Nightly backup | `scripts/pg_backup.sh` → `/opt/backups/procurement/procurement_*.dump` (14 days) |
| Pre-cutover backups | `/opt/backups/procurement/pre_cutover_<TS>/` |
