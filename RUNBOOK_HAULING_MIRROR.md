# Runbook — Hauling mirror: copy `hauling_tracker` into ClickHouse

Run on **76.13.19.246** as **root**. Numbered steps, top to bottom. Say "3.2
failed" and paste the output of that step only.

```
mmi-postgres / hauling_tracker  ──(hauling_ro, SELECT only)──▶  ClickHouse database `hauling`
   Calvin's live system             named collection pg_hauling          a rebuildable copy
                                    every 15 min, host cron: scripts/hauling_sync.sh
```

`hauling_tracker` belongs to **another team's live system**. The only thing
this runbook changes on the Postgres side is one new login, `hauling_ro`, that
can read five tables. Nothing in `hauling_tracker` is written, altered or
restarted, and `mmi-postgres` is never restarted. The procurement app and its
own sync (`scripts/ch_sync.sh`) are not touched and keep running throughout.

| Phase | What | Minutes | Effect |
|---|---|---|---|
| 0 | Read-only pre-checks, save a "before" picture of Postgres | 10 | none |
| 1 | Get the code, add `HAULING_RO_PASSWORD` to `.env` | 5 | none |
| 2 | Create `hauling_ro` in Postgres, test it, prove nothing else changed | 10 | one new Postgres login |
| 3 | Recreate the ClickHouse container (about 5 s warehouse blip) | 5 | app unaffected |
| 4 | Can ClickHouse read hauling? Are the timestamps identical? | 5 | read-only |
| 5 | Create the `hauling` database, first sync, verify | 5 | new ClickHouse database only |
| 6 | Cron every 15 minutes, log rotation, check 20 minutes later | 5 + 20 wait | |
| 7 | Rollback (only if needed) | 10 | |
| 8 | Later: new tables, Calvin changes a table, a dashboard user | | |

About 40 minutes of work plus the 20-minute wait in 6.3.

**How to use this file.** Paste **one block at a time**, never old terminal
output (the lines under "Expected" are not commands). Every block starts with
`cd /opt/purchasing_data` and defines its own helper functions, so it works in a
fresh SSH session. Nothing here prints the password.

**STOP** means: do not run the next step. Do what the STOP line says (usually
nothing, or one undo command), then paste the output into Claude.

Things never to run during or after this work: `docker compose down -v`
(deletes the ClickHouse volume), any `DROP` or `TRUNCATE` on the ClickHouse
database **`procurement`**, anything that writes to `hauling_tracker` other than
the setup script in 2.1, `docker restart mmi-postgres` (it serves another live
system) and `git stash pop`. (Dropping the ClickHouse database `hauling` is
fine and is the rollback: it only holds a copy. The old "never DROP in
ClickHouse" rule is about `procurement`, which is the real data.)

Two facts to know up front:

- **The mirror needs no backup.** It is rebuilt from Postgres at any time with
  `scripts/hauling_sync.sh --init` and `--full` (5.1, 5.2). The nightly
  `pg_backup.sh` is for `procurement` only; backups of `hauling_tracker`
  itself are not part of this runbook.
- **Hauling data is paused history right now.** No trips since 2026-08-26, so
  the numbers below should not move while you work. If they do, hauling has
  restarted: the mirror handles that, but the reference values in this file will
  be out of date.

---

## Phase 0 — Pre-checks (nothing changes)

### 0.1 Where the server is now

```bash
cd /opt/purchasing_data
git rev-parse HEAD | tee /root/hauling_old_commit
git branch --show-current
git status --short | head -20
docker ps --format '{{.Names}}\t{{.Status}}' | grep -E 'procurement|mmi-postgres'
df -h / /opt /var/lib/docker | sort -u
systemctl is-active crond; command -v flock openssl
tail -n 3 /var/log/procurement-ch-sync.log
```

Expected: a commit hash (saved in `/root/hauling_old_commit`) and the branch
(`main`); `git status` lists nothing, or only files you already know about;
`procurement_app` Up, `procurement_clickhouse` Up (healthy), `mmi-postgres` Up;
at least 2 GB free; `active`; two paths (`flock`, `openssl`); the last lines of
the procurement sync log, ending in `[incremental] OK` from the last quarter
hour.

**STOP** if `procurement_clickhouse` or `mmi-postgres` is not Up, the disk has
under 1 GB free, or `flock`/`openssl` print nothing. Nothing to undo.

### 0.2 hauling_tracker: is it what we expect? (read-only)

The helper opens its sessions read-only, so these cannot write even by mistake.

```bash
cd /opt/purchasing_data
pgq() { docker exec -e PGOPTIONS='-c default_transaction_read_only=on' mmi-postgres psql -U postgres -X -v ON_ERROR_STOP=1 "$@"; }
pgq -Atc "select datname from pg_database order by 1"
pgq -d hauling_tracker -Atc "select tablename from pg_tables where schemaname='public' order by 1"
pgq -d hauling_tracker -Atc "select table_name, count(*) from information_schema.columns where table_schema='public' and table_name in ('trips','barge_loadings','scale_readings_pending','station_heartbeat','error_log') group by 1 order by 1"
pgq -d hauling_tracker -Atc "select 'trips', count(*) from trips union all select 'barge_loadings', count(*) from barge_loadings union all select 'scale_readings_pending', count(*) from scale_readings_pending union all select 'station_heartbeat', count(*) from station_heartbeat union all select 'error_log', count(*) from error_log"
pgq -d hauling_tracker -Atc "select status, count(*), sum(netto_site_kg), sum(netto_jetty_kg) from trips group by 1 order by 1"
pgq -d hauling_tracker -Atc "select 'last trip date', max(date)::text from trips union all select 'last error', to_char(max(created_at) at time zone 'UTC', 'YYYY-MM-DD HH24:MI:SS') from error_log"
```

Expected, in order:

1. `hauling_tracker`, `postgres`, `template0`, `template1` (and `procurement`).
2. The tables of `hauling_tracker`, including `trips`, `barge_loadings`,
   `scale_readings_pending`, `station_heartbeat`, `error_log`, `sessions`,
   `users`, `audit_log`, `schema_migrations`, `station_request_log` (others are fine).
3. Column counts: `barge_loadings|8`, `error_log|6`, `scale_readings_pending|5`,
   `station_heartbeat|13`, `trips|27`.
4. Row counts: `trips|6474`, `barge_loadings|16`, `scale_readings_pending|4`,
   `station_heartbeat|0`, `error_log|6570`.
5. `in_transit|1|…` and `completed|6473|…` (listed in status order; the
   `in_transit` sums may be empty); the sums add up to about 213,678,000 kg
   (site) and 214,132,000 kg (jetty), i.e. 213,678 t and 214,132 t.
6. `last trip date|2026-08-26` and a last error time.

**STOP** if `hauling_tracker` or one of the five tables is missing, or a column
count differs (the mirror's table definitions assume exactly these columns).
Small count differences mean hauling restarted: not a failure, but tell Claude
before continuing. Nothing to undo.

### 0.3 The role must not exist yet; the network rule; connection headroom

```bash
cd /opt/purchasing_data
pgq() { docker exec -e PGOPTIONS='-c default_transaction_read_only=on' mmi-postgres psql -U postgres -X -v ON_ERROR_STOP=1 "$@"; }
pgq -Atc "select count(*) from pg_roles where rolname = 'hauling_ro'"
pgq -Atc "select count(*) || ' of ' || current_setting('max_connections') || ' connections in use' from pg_stat_activity"
pgq -Atc "show password_encryption"
pgq -Atc "select line_number, type, database, user_name, address, auth_method from pg_hba_file_rules where type like 'host%'"
```

Expected: `0`; something like `12 of 100 connections in use` (the mirror holds
a few connections for a few seconds every 15 minutes, 20 at most); `scram-sha-256`;
a `host` rule for all databases and users from any address with `scram-sha-256`
(the postgres image's default `host|{all}|{all}|all|…|scram-sha-256`), and
normally also `127.0.0.1` with `trust` (used by the checks in 2.2).

**STOP** if the first line is not `0` (a `hauling_ro` already exists: someone
made it, or an earlier attempt did; paste the output and do not continue), if
connections are within 25 of the maximum, or no `host` rule admits other
containers (changing `pg_hba.conf` means reconfiguring a container another
system depends on; that needs a decision). Nothing to undo.

### 0.4 ClickHouse: healthy, no `hauling` database yet

```bash
cd /opt/purchasing_data
chq() { docker exec procurement_clickhouse sh -c 'exec clickhouse-client --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" "$@"' chq "$@"; }
docker inspect -f '{{.State.Health.Status}}' procurement_clickhouse
chq --query "SELECT version()"
chq --query "SELECT name FROM system.databases WHERE name NOT IN ('INFORMATION_SCHEMA','information_schema') ORDER BY name"
chq --query "SELECT count() AS procurement_tables FROM system.tables WHERE database = 'procurement'"
chq --query "SELECT name FROM system.named_collections ORDER BY name"
docker exec procurement_clickhouse du -sh /var/lib/clickhouse
```

Expected: `healthy`; `24.8.…`; the databases `default`, `procurement`, `system`
and **no** `hauling`; a table count (**write it down**: 7.2 checks it is the same
afterwards); `pg_procurement` only; a size well under the free disk space.
(If the `named_collections` line is refused with "Not enough privileges", skip
that one: step 4.1 is the real test.)

**STOP** if not `healthy`. If a `hauling` database already exists from an
earlier attempt, that is fine (everything here is re-runnable); just tell Claude.

### 0.5 Save a "before" picture of hauling_tracker's permissions (read-only)

This writes two files under `/root` (nothing in Postgres). It lists every
privilege on the database, schema, tables, columns and default ACLs, plus all
roles and memberships, **leaving out `hauling_ro`**. After 2.1 the same query
must give exactly the same answer: that is the proof nothing else changed.

```bash
cd /opt/purchasing_data
cat > /root/hauling_fp.sql <<'EOF'
select 'db', datname, pg_get_userbyid(datdba), case when x.grantee=0 then 'PUBLIC' else pg_get_userbyid(x.grantee) end, x.privilege_type, x.is_grantable::text
  from pg_database d cross join lateral aclexplode(coalesce(d.datacl, acldefault('d'::"char", d.datdba))) x
 where d.datname = current_database() and pg_get_userbyid(x.grantee) <> 'hauling_ro'
union all
select 'schema', nspname, pg_get_userbyid(nspowner), case when x.grantee=0 then 'PUBLIC' else pg_get_userbyid(x.grantee) end, x.privilege_type, x.is_grantable::text
  from pg_namespace s cross join lateral aclexplode(coalesce(s.nspacl, acldefault('n'::"char", s.nspowner))) x
 where s.nspname = 'public' and pg_get_userbyid(x.grantee) <> 'hauling_ro'
union all
select 'rel', c.relname, pg_get_userbyid(c.relowner), case when x.grantee=0 then 'PUBLIC' else pg_get_userbyid(x.grantee) end, x.privilege_type, x.is_grantable::text
  from pg_class c cross join lateral aclexplode(coalesce(c.relacl, acldefault((case when c.relkind='S' then 's' else 'r' end)::"char", c.relowner))) x
 where c.relnamespace = 'public'::regnamespace and c.relkind in ('r','p','v','m','S','f')
   and pg_get_userbyid(x.grantee) <> 'hauling_ro'
union all
select 'col', c.relname || '.' || a.attname, '', case when x.grantee=0 then 'PUBLIC' else pg_get_userbyid(x.grantee) end, x.privilege_type, x.is_grantable::text
  from pg_attribute a join pg_class c on c.oid=a.attrelid cross join lateral aclexplode(a.attacl) x
 where c.relnamespace = 'public'::regnamespace and a.attacl is not null
   and pg_get_userbyid(x.grantee) <> 'hauling_ro'
union all
select 'defacl', pg_get_userbyid(defaclrole), defaclobjtype::text, coalesce(defaclacl::text,''), '', ''
  from pg_default_acl
union all
select 'role', rolname, rolsuper::text || rolcreatedb::text || rolcreaterole::text || rolcanlogin::text || rolreplication::text || rolbypassrls::text,
       rolconnlimit::text, coalesce(rolvaliduntil::text,''), coalesce(rolconfig::text,'')
  from pg_roles where rolname <> 'hauling_ro'
union all
select 'member', pg_get_userbyid(roleid), pg_get_userbyid(member), '', '', '' from pg_auth_members
 where pg_get_userbyid(member) <> 'hauling_ro'
order by 1, 2, 3, 4, 5, 6
EOF
docker exec -i -e PGOPTIONS='-c default_transaction_read_only=on' mmi-postgres psql -U postgres -X -At -v ON_ERROR_STOP=1 -d hauling_tracker < /root/hauling_fp.sql > /root/hauling_fp_before.txt; echo "exit=$?"
wc -l < /root/hauling_fp_before.txt
grep -c hauling_ro /root/hauling_fp_before.txt
```

Expected: `exit=0`, a line count above 50, and `0`.

**STOP** if the exit is not 0 or the file is empty. Nothing to undo.

### 0.6 Tell Calvin

Calvin owns `hauling_tracker`. Before phase 2, tell him that a **read-only login
`hauling_ro`** is being added to his Postgres (SELECT on `trips`,
`barge_loadings`, `scale_readings_pending`, `station_heartbeat`, `error_log`;
nothing else; never `sessions` or `users`), that it connects every 15 minutes
from this server for a few seconds, and that nothing in his database changes.
The user has approved this; Calvin should still hear it from you before it
happens, and he must be told again before any later table is added (8.1).

---

## Phase 1 — Code and `.env` (no container changes yet)

Until phase 3 the running containers are unaffected, and a normal app deploy
(`docker compose up -d --build app`) keeps working: the new variable has an
empty default in `docker-compose.yml`.

### 1.1 Which branch has the hauling files?

```bash
cd /opt/purchasing_data
git fetch origin
echo "--- on origin/main:";          git ls-tree --name-only origin/main db/hauling_ro_setup.sql scripts/hauling_sync.sh
echo "--- on origin/hauling-mirror:"; git ls-tree --name-only origin/hauling-mirror db/hauling_ro_setup.sql scripts/hauling_sync.sh
git status --porcelain --untracked-files=no
```

Expected, one of:

- **A. Merged:** both files listed under `origin/main`. Use 1.2A.
- **B. Not merged yet:** nothing under `origin/main`, both files under
  `origin/hauling-mirror`. Use 1.2B.

The last command must print nothing. If it lists modified files, save them
first (they stay in the stash; **never** `git stash pop`):

```bash
cd /opt/purchasing_data
[ -n "$(git status --porcelain --untracked-files=no)" ] && { git diff > /root/hauling_server_local_changes.patch; wc -l /root/hauling_server_local_changes.patch; git stash push -m "pre-hauling-mirror"; }
git status --porcelain --untracked-files=no
```

**STOP** if neither branch has the files (it has not been pushed). Nothing to undo.

### 1.2A Merged into main

```bash
cd /opt/purchasing_data
git pull --ff-only origin main
git log -1 --oneline
```

### 1.2B Not merged: use the branch

The server then runs `hauling-mirror` instead of `main`. **Do not switch back to
`main` until the branch is merged**: the mirror's files exist only on this
branch, and switching would remove them from disk while the container still
mounts them. Deploy the app from the same branch meanwhile:
`git pull origin hauling-mirror && docker compose up -d --build app`.

```bash
cd /opt/purchasing_data
git checkout -B hauling-mirror origin/hauling-mirror
git log -1 --oneline
```

### 1.3 Check the files arrived

```bash
cd /opt/purchasing_data
ls -l db/hauling_ro_setup.sql db/hauling_ch_schema.sql db/hauling_sync.sql scripts/hauling_sync.sh db/clickhouse-config.d/40-pg-hauling.xml
chmod +x scripts/hauling_sync.sh
bash -n scripts/hauling_sync.sh && echo "script syntax OK"
grep -n 'HAULING_RO_PASSWORD' docker-compose.yml
```

Expected: five files listed, `script syntax OK`, and one compose line:
`- HAULING_RO_PASSWORD=${HAULING_RO_PASSWORD:-}`.

**STOP** if a file is missing or the checkout refused (usually "local changes
would be overwritten" or "untracked files would be overwritten": move each named
file to `/root/` with `mv` and repeat 1.2). Nothing else has changed yet.

### 1.4 Add the password to `.env`

```bash
cd /opt/purchasing_data
cp -p .env /root/env_before_hauling && chmod 600 /root/env_before_hauling
sed -i '/^HAULING_RO_PASSWORD=$/d' .env
[ -z "$(tail -c1 .env)" ] || echo >> .env
grep -q '^HAULING_RO_PASSWORD=' .env || echo "HAULING_RO_PASSWORD=$(openssl rand -hex 24)" >> .env
chmod 600 .env
grep -E '^HAULING_RO_PASSWORD=' .env | awk -F= '{print $1, length($2)}'
docker compose config --quiet && echo "compose OK"
```

Expected:
```
HAULING_RO_PASSWORD 48
compose OK
```

Run this block again later and it keeps the existing password (it only adds one
if there is none). **STOP** if the length is not 48 or compose does not say OK.
Undo: `cp -p /root/env_before_hauling .env`.

---

## Phase 2 — Postgres: the read-only role

Creates the role `hauling_ro` and grants it `CONNECT` on `hauling_tracker`,
`USAGE` on schema `public` and `SELECT` on the five tables, nothing else. Needs
no lock on any table beyond the instant a grant takes (the script gives up after
5 s rather than wait). No tables are read or changed, no other role is touched.
Tell Calvin first (0.6).

### 2.1 Create the role and grants

The password goes in on stdin, so it never appears in the process list. The
script is re-runnable (it also sets the password again).

```bash
cd /opt/purchasing_data
envval() { grep -m1 "^$1=" /opt/purchasing_data/.env | cut -d= -f2-; }
if envval HAULING_RO_PASSWORD | grep -Eq '^[A-Za-z0-9]{16,}$' && [ -s db/hauling_ro_setup.sql ] && [ -s /root/hauling_fp_before.txt ]; then
  { printf '\\set ro_password %s\n' "$(envval HAULING_RO_PASSWORD)"; cat db/hauling_ro_setup.sql; } | docker exec -i mmi-postgres psql -U postgres -X
  echo "exit=$?"
else
  echo "NOT RUN: password missing, short or not plain letters/digits (1.4), setup file missing (1.2), or the before picture is missing (0.5)"
fi
```

Expected: a table headed `== hauling_ro setup: verification ==` with one row per
check (`check_name | expected | actual | status`) and `ok` in the status column of
every row, then `hauling_ro setup: all hard checks passed, warnings = 0` and
`exit=0`. The rows to look at:

```
role exists                                    true    true                  ok
can login                                      true    true                  ok
connection limit                               20      20                    ok
role settings   DateStyle=ISO, YMD | default_transaction_read_only=on | statement_timeout=120s | TimeZone=UTC   (same in both columns)
member of no roles                             (none)  (none)                ok
SELECT granted on the existing listed tables   barge_loadings,error_log,scale_readings_pending,station_heartbeat,trips   (same in both columns)
any OTHER readable table (via PUBLIC …)        (none)  (none)                ok
CANNOT select public.sessions                  false   false                 ok   (also users, audit_log, schema_migrations)
```

**STOP** on `exit` other than 0, any `FAIL` row, or any `WARN` row (paste the
table; a warning means a listed table is missing, something other than the five
tables is readable, or `public` allows CREATE for everyone). Undo (this is the whole undo for
phases 1-2): section 7.4.

### 2.2 What can `hauling_ro` actually do?

The first block logs in **as `hauling_ro`** from inside the postgres container
(`env -u PGTZ -u TZ` because that container's `PGTZ/TZ=Asia/Makassar` would make
the session report Makassar even though the role is UTC). These run over loopback,
which the postgres image trusts, so they test the grants; the password is tested
by ClickHouse in 4.1.

```bash
cd /opt/purchasing_data
hro() { docker exec mmi-postgres env -u PGTZ -u TZ psql -U hauling_ro -h 127.0.0.1 -d hauling_tracker -XAt "$@"; }
hro -c "select current_user, current_setting('TimeZone'), current_setting('DateStyle'), current_setting('default_transaction_read_only')"
hro -c "select 'trips', count(*) from trips union all select 'barge_loadings', count(*) from barge_loadings union all select 'scale_readings_pending', count(*) from scale_readings_pending union all select 'station_heartbeat', count(*) from station_heartbeat union all select 'error_log', count(*) from error_log"
hro -c "select relname from pg_class where relnamespace = 'public'::regnamespace and relkind in ('r','p','v','m') and has_table_privilege(oid, 'SELECT') order by 1"
hro -c "select count(*) from sessions"
hro -c "select count(*) from users"
hro -c "select count(*) from audit_log"
```

Expected:

- `hauling_ro|UTC|ISO, YMD|on`
- the five counts, same as 0.2
- exactly five names: `barge_loadings`, `error_log`, `scale_readings_pending`,
  `station_heartbeat`, `trips` (this is the real, effective access, including
  anything inherited from PUBLIC)
- three lines `ERROR:  permission denied for table sessions` / `users` /
  `audit_log`: **these errors are correct**

Then, as the superuser (read-only), what `hauling_ro` holds and where it cannot go:

```bash
cd /opt/purchasing_data
pgq() { docker exec -e PGOPTIONS='-c default_transaction_read_only=on' mmi-postgres psql -U postgres -X -v ON_ERROR_STOP=1 "$@"; }
pgq -d hauling_tracker -Atc "select c.relname, string_agg(x.privilege_type, ',' order by x.privilege_type) from pg_class c cross join lateral aclexplode(c.relacl) x where x.grantee = 'hauling_ro'::regrole and c.relnamespace = 'public'::regnamespace group by 1 order by 1"
pgq -d hauling_tracker -Atc "select has_table_privilege('hauling_ro','trips','INSERT,UPDATE,DELETE,TRUNCATE'), has_schema_privilege('hauling_ro','public','CREATE')"
pgq -Atc "select datname from pg_database where has_database_privilege('hauling_ro', datname, 'CONNECT') order by 1"
pgq -Atc "select rolsuper, rolcreatedb, rolcreaterole, rolreplication, rolbypassrls, rolconnlimit from pg_roles where rolname = 'hauling_ro'"
pgq -Atc "select count(*) from pg_auth_members where member = 'hauling_ro'::regrole"
```

Expected: five lines, each `<table>|SELECT`; `f|f` (a `t` in the second place is
the same thing as the `CREATE on schema public` WARN in 2.1: paste it); a short list that contains
`hauling_tracker` and does **not** contain `procurement`; `f|f|f|f|f|20`; `0`.

**STOP** if anything differs, especially a table other than the five, an extra
privilege, or `has_*` returning `t`. Undo: 7.4.

### 2.3 Nothing else in hauling_tracker changed

```bash
cd /opt/purchasing_data
if [ -s /root/hauling_fp_before.txt ] && [ -s /root/hauling_fp.sql ]; then
  docker exec -i -e PGOPTIONS='-c default_transaction_read_only=on' mmi-postgres psql -U postgres -X -At -v ON_ERROR_STOP=1 -d hauling_tracker < /root/hauling_fp.sql > /root/hauling_fp_after.txt
  echo "exit=$?"
  diff /root/hauling_fp_before.txt /root/hauling_fp_after.txt && echo "IDENTICAL: no privilege, role, schema or default ACL other than hauling_ro's changed"
else
  echo "NOT RUN: /root/hauling_fp.sql or the before picture is missing (0.5)"
fi
```

Expected: `exit=0` and `IDENTICAL: …`. The comparison ignores `hauling_ro`
itself (its grants are what 2.1 added) and compares everything else, including
PUBLIC and the other roles, with unset ACLs treated as the defaults they stand for.

**STOP** if `diff` prints any line (it means something besides `hauling_ro`
changed; do not guess, paste the lines). Undo: 7.4.

---

## Phase 3 — ClickHouse: pick up the new source (about 5 s blip)

The container is recreated (volume and data kept) so it reads the new config
file and `HAULING_RO_PASSWORD`. The warehouse is unreachable for about 5 s and
the 15-minute procurement sync simply runs on the next tick; the app does not
use ClickHouse and keeps serving. If you are near :00/:15/:30/:45, wait a minute.

### 3.1 Recreate and wait

```bash
cd /opt/purchasing_data
docker compose config --quiet && docker compose up -d clickhouse
for i in $(seq 1 30); do s=$(docker inspect -f '{{.State.Health.Status}}' procurement_clickhouse); [ "$s" = healthy ] && break; sleep 3; done; echo "$s"
docker logs --tail=30 procurement_clickhouse 2>&1 | grep -iE 'error|exception' || echo "no errors"
```

Expected: a line about `procurement_clickhouse` being recreated/started (and
nothing about `procurement_app`), then `healthy`, then `no errors`.

If it does not become healthy: the app is unaffected. Paste the logs, then put
the previous config back:
```bash
cd /opt/purchasing_data
git show "$(cat /root/hauling_old_commit)":docker-compose.yml > /root/old-compose.yml
docker compose -f /root/old-compose.yml --project-directory /opt/purchasing_data up -d clickhouse
```

### 3.2 Is the new source loaded, and is procurement still fine?

```bash
cd /opt/purchasing_data
chq() { docker exec procurement_clickhouse sh -c 'exec clickhouse-client --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" "$@"' chq "$@"; }
chq --query "SELECT name FROM system.named_collections ORDER BY name"
docker exec procurement_clickhouse ls /etc/clickhouse-server/config.d/
docker exec procurement_clickhouse sh -c 'printf %s "$HAULING_RO_PASSWORD" | wc -c'
docker ps --format '{{.Names}}\t{{.Status}}' | grep procurement
chq --query "SELECT count() AS procurement_tables FROM system.tables WHERE database = 'procurement'"
scripts/ch_sync.sh; echo "exit=$?"
```

Expected: `pg_hauling` and `pg_procurement`; the file list includes
`40-pg-hauling.xml`; `48`; both containers Up; the same table count as in 0.4;
`exit=0` (the procurement sync, run once by hand).

**STOP** if `pg_hauling` is missing (if the `named_collections` line itself is
refused with "Not enough privileges", skip it and go on to 4.1) or the password length is `0` (`.env` has no
value: redo 1.4, then `docker compose up -d --force-recreate clickhouse`). A
failing procurement sync here is not caused by hauling (its files are untouched);
paste its log line anyway: `tail -3 /var/log/procurement-ch-sync.log`.

---

## Phase 4 — Can ClickHouse read hauling? (read-only)

Postgres sends `timestamptz` as text with an offset, and ClickHouse's
`postgresql()` reader drops the offset and reads the wall-clock part. `hauling_ro`
is pinned to UTC for exactly that reason, so what ClickHouse sees equals the real
UTC instant. The host is on Makassar time (UTC+8): a wrong setup would show up
here as timestamps eight hours apart.

### 4.1 Count and timestamps, `trips`

```bash
cd /opt/purchasing_data
chq() { docker exec procurement_clickhouse sh -c 'exec clickhouse-client --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" "$@"' chq "$@"; }
pgq() { docker exec -e PGOPTIONS='-c default_transaction_read_only=on' mmi-postgres psql -U postgres -X -v ON_ERROR_STOP=1 "$@"; }
chq --query "SELECT count() FROM postgresql(pg_hauling, table = 'trips')"
pgq -d hauling_tracker -Atc "select count(*) from trips"
chq --query "SELECT toString(max(toDateTime64(toString(cp3_timestamp), 6, 'UTC'))) FROM postgresql(pg_hauling, table = 'trips')"
pgq -d hauling_tracker -Atc "select to_char(max(cp3_timestamp) at time zone 'UTC', 'YYYY-MM-DD HH24:MI:SS.US') from trips"
```

Expected: the two counts are equal (6474); the two timestamps are **identical**
(`2026-08-2…`).

- `password authentication failed for user "hauling_ro"` or `no password
  supplied` → the `.env` value and the role disagree. Rerun 2.1, then
  `docker compose up -d --force-recreate clickhouse`, then this block.
- `Not enough privileges … NAMED COLLECTION` → the users grant did not load;
  paste `docker exec procurement_clickhouse ls /etc/clickhouse-server/users.d/`.
  (This fails closed: nothing is readable.)
- timestamps differ by whole hours → **do not continue**; paste both lines.
- `could not translate host name` → the clickhouse container is not on the
  mmi-postgres network; paste `docker inspect procurement_clickhouse -f '{{json .NetworkSettings.Networks}}'`.

### 4.2 The other four tables, and the one that must be refused

```bash
cd /opt/purchasing_data
chq() { docker exec procurement_clickhouse sh -c 'exec clickhouse-client --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" "$@"' chq "$@"; }
pgq() { docker exec -e PGOPTIONS='-c default_transaction_read_only=on' mmi-postgres psql -U postgres -X -v ON_ERROR_STOP=1 "$@"; }
chq --query "SELECT count(), sum(loading_qty_kg) FROM postgresql(pg_hauling, table = 'barge_loadings')"
pgq -d hauling_tracker -Atc "select count(*), sum(loading_qty_kg) from barge_loadings"
chq --query "SELECT count(), sum(toFloat64(weight_kg)) FROM postgresql(pg_hauling, table = 'scale_readings_pending')"
pgq -d hauling_tracker -Atc "select count(*), sum(weight_kg) from scale_readings_pending"
chq --query "SELECT count(), countIf(context IS NOT NULL), toString(max(toDateTime64(toString(created_at), 6, 'UTC'))) FROM postgresql(pg_hauling, table = 'error_log')"
pgq -d hauling_tracker -Atc "select count(*), count(context), to_char(max(created_at) at time zone 'UTC', 'YYYY-MM-DD HH24:MI:SS.US') from error_log"
chq --query "SELECT count() FROM postgresql(pg_hauling, table = 'station_heartbeat')"
chq --query "SELECT count() FROM postgresql(pg_hauling, table = 'sessions')" 2>&1 | grep -m1 -o 'permission denied for table sessions'
```

Expected: each ClickHouse line equals the Postgres line under it (tab versus `|`
is the only difference, and `129427.5` equals `129427.50`; `barge_loadings` 16 rows; `scale_readings_pending` 4;
`error_log` 6570 and identical timestamps); `0` for the heartbeat table; and
finally `permission denied for table sessions` (**correct**: ClickHouse cannot
read it either).

**STOP** if a table errors with a type or permission message (paste it), counts
or timestamps differ, or the last line prints nothing (that would mean
`sessions` was readable: do not continue, paste the output, and roll back with 7.4).

---

## Phase 5 — The `hauling` database and the first sync

Only creates the ClickHouse database `hauling` (never touches `procurement`).

### 5.1 Create the tables

```bash
cd /opt/purchasing_data
scripts/hauling_sync.sh --init; echo "exit=$?"
```

Expected: `… [init] OK: database hauling and its tables exist (db/hauling_ch_schema.sql applied)`
and `exit=0`. Safe to repeat.

### 5.2 First sync (everything, once)

```bash
cd /opt/purchasing_data
scripts/hauling_sync.sh --full; echo "exit=$?"
```

Expected, in a few seconds:
```
… [full] no previous successful run recorded; doing a full sync
… [full] start: full rebuild of all tables from Postgres
… [full] OK in 3s; watermark now 2026-10-01 … UTC
exit=0
```

### 5.3 Verify against Postgres

```bash
cd /opt/purchasing_data
scripts/hauling_sync.sh --verify; echo "exit=$?"
```

Expected: a table (`tablename metric postgres clickhouse result`) with twelve rows,
**every `result` = `ok`**, then `… [verify] verify: OK (12 checks, Postgres and ClickHouse agree)`
and `exit=0`. The values to recognise:

```
trips                   rows                 6474   6474   ok
trips                   sum(netto_site_kg)   2136…  2136…  ok     (about 213,678,000)
trips                   sum(netto_jetty_kg)  2141…  2141…  ok     (about 214,132,000)
trips                   count by status      completed=6473, in_transit=1   (same on both sides)
barge_loadings          rows                 16     16     ok
scale_readings_pending  rows                 4      4      ok
error_log               rows                 6570   6570   ok
station_heartbeat       rows                 0      0      ok
station_heartbeat       max(received_at)     none   none   ok
```
(The row order may differ.)
(The other three rows are `sum(loading_qty_kg)`, `sum(weight_kg)` and
`max(created_at)` of `error_log`.) If the numbers moved since 0.2, hauling
restarted; the two sides must still agree with each other.

### 5.4 An incremental run must change nothing

```bash
cd /opt/purchasing_data
chq() { docker exec procurement_clickhouse sh -c 'exec clickhouse-client --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" "$@"' chq "$@"; }
scripts/hauling_sync.sh; echo "exit=$?"
scripts/hauling_sync.sh --verify; echo "exit=$?"
chq --query "SELECT name, total_rows FROM system.tables WHERE database = 'hauling' ORDER BY name"
```

Expected: `… [incremental] start: rows newer than … UTC (plus snapshot tables)`,
`… [incremental] OK in Ns; …`, `exit=0`; the same verify table as 5.3 with the
same numbers and `exit=0`; and exactly six tables, with no `*_new` leftovers:
`_sync_state 2`, `barge_loadings 16`, `error_log 6570`, `scale_readings_pending 4`,
`station_heartbeat 0`, `trips 6474`. (If a cron run holds the lock at that
moment, a `--verify` prints "another run holds the lock" and exits 1: wait a
minute and repeat.)

**STOP** on any non-zero exit or any `MISMATCH`. The mirror is a copy, so
nothing is damaged: paste the output. To start over,
`scripts/hauling_sync.sh --init && scripts/hauling_sync.sh --full` is always safe;
to remove everything, 7.2.

---

## Phase 6 — Every 15 minutes, by cron

The procurement sync runs at :00/:15/:30/:45. This one runs at :07/:22/:37/:52
so the two never start together on the 0.5-core ClickHouse.

### 6.1 Install cron and log rotation

Only installs if the verify in 5.3 still passes.

Two lines go into the cron file: the normal sync every 15 minutes, and a **nightly
full rebuild at 04:12 followed by a verify**. The incremental runs never see rows deleted
in `error_log` / `station_heartbeat`, or a heartbeat that arrives very late with an older
id; the nightly full run repairs that and the verify line in the log shows whether the
mirror matches Postgres afterwards (it reads the five small tables in about 2 s).

```bash
cd /opt/purchasing_data
if scripts/hauling_sync.sh --verify >/dev/null 2>&1; then
cat > /etc/cron.d/hauling-ch-sync <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
7,22,37,52 * * * * root /opt/purchasing_data/scripts/hauling_sync.sh >> /var/log/hauling-ch-sync.log 2>&1
12 4 * * * root /opt/purchasing_data/scripts/hauling_sync.sh --full >> /var/log/hauling-ch-sync.log 2>&1 && /opt/purchasing_data/scripts/hauling_sync.sh --verify >> /var/log/hauling-ch-sync.log 2>&1
EOF
cat > /etc/logrotate.d/hauling-ch-sync <<'EOF'
/var/log/hauling-ch-sync.log {
    monthly
    rotate 6
    compress
    missingok
    notifempty
}
EOF
chmod 644 /etc/cron.d/hauling-ch-sync /etc/logrotate.d/hauling-ch-sync
echo "installed"
else
echo "NOT INSTALLED: verify failed, repeat 5.2 and 5.3 first"
fi
ls -l /etc/cron.d/hauling-ch-sync /etc/logrotate.d/hauling-ch-sync
logrotate -d /etc/logrotate.d/hauling-ch-sync 2>&1 | grep -iE 'error|considering' 
```

Expected: `installed`, both files listed (`-rw-r--r-- 1 root root`), and a
`considering log /var/log/hauling-ch-sync.log` line from the logrotate dry run
(`-d` rotates nothing).

### 6.2 Is cron alive?

```bash
cd /opt/purchasing_data
systemctl is-active crond
cat /etc/cron.d/hauling-ch-sync
```

Expected: `active`, and the three lines of the file. cron reads new files in
`/etc/cron.d` by itself; no restart is needed.

### 6.3 Twenty minutes later

```bash
cd /opt/purchasing_data
tail -n 8 /var/log/hauling-ch-sync.log
grep hauling-ch-sync /var/log/cron | tail -n 3
tail -n 3 /var/log/procurement-ch-sync.log
scripts/hauling_sync.sh --verify; echo "exit=$?"
```

Expected: `[incremental] OK` lines at :07/:22/:37/:52 (one or two since 6.1);
the same times in `/var/log/cron`; procurement's `[incremental] OK` at
:00/:15/:30/:45 still running; verify `exit=0`.

**STOP** if no hauling line appeared after 20 minutes, or a line says `FAILED`.
The cause is in that log line (paste it). Remove the cron file with 7.1 if it
keeps failing; the procurement sync is independent and unaffected.

### 6.4 The next morning (after 04:12)

```bash
cd /opt/purchasing_data
grep -E '\[full\]|\[verify\]' /var/log/hauling-ch-sync.log | tail -n 4
```

Expected: a `[full] OK` line and a `[verify] verify: OK` line stamped around 04:12.
If the verify line says it failed, run `scripts/hauling_sync.sh --verify` by hand and
paste the table.

Done. The mirror stays at the same numbers until hauling restarts, then follows
within 15 minutes.

---

## Phase 7 — Rollback (only if needed)

Each step stands alone; you can stop after any of them. 7.1 only pauses the
mirror (the copy stays). 7.2 removes the copy. 7.3 and 7.4 remove the login. The
repository files can stay: without the cron file and the `.env` value they do nothing.

### 7.1 Stop the sync

```bash
cd /opt/purchasing_data
rm -f /etc/cron.d/hauling-ch-sync /etc/logrotate.d/hauling-ch-sync
flock -w 120 /var/lock/hauling-ch-sync.lock true && echo "no sync running"
[ ! -e /etc/cron.d/hauling-ch-sync ] && echo "cron file removed"
```

Expected: `no sync running` (a run in progress is waited for, up to 2 minutes) and
`cron file removed`.

### 7.2 Drop the ClickHouse database `hauling`

This is safe: it holds only a copy of Postgres data, and the sync can rebuild it
(5.1, 5.2). The "never DROP in ClickHouse" rule applies to the **`procurement`**
database, which this command does not touch (it names `hauling` literally, and the
guard refuses to run unless that database looks like the mirror).

```bash
cd /opt/purchasing_data
chq() { docker exec procurement_clickhouse sh -c 'exec clickhouse-client --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" "$@"' chq "$@"; }
if [ "$(chq --query "SELECT count() FROM system.tables WHERE database = 'hauling' AND name = '_sync_state'")" = 1 ]; then
  chq --query "DROP DATABASE hauling SYNC"
else
  echo "NOT DROPPED: no ClickHouse database 'hauling' with a _sync_state table was found"
fi
chq --query "SELECT name FROM system.databases WHERE name NOT IN ('INFORMATION_SCHEMA','information_schema') ORDER BY name"
chq --query "SELECT count() AS procurement_tables FROM system.tables WHERE database = 'procurement'"
```

Expected: the database list is `default`, `procurement`, `system` (no `hauling`)
and the `procurement` table count equals the number noted in 0.4.

### 7.3 Remove the password from the ClickHouse container

```bash
cd /opt/purchasing_data
cp -p .env /root/env_before_hauling_rollback && chmod 600 /root/env_before_hauling_rollback
sed -i '/^HAULING_RO_PASSWORD=/d' .env
grep -c '^HAULING_RO_PASSWORD=' .env
docker compose up -d --force-recreate clickhouse
for i in $(seq 1 30); do s=$(docker inspect -f '{{.State.Health.Status}}' procurement_clickhouse); [ "$s" = healthy ] && break; sleep 3; done; echo "$s"
```

Expected: `0`, then `healthy`. The ClickHouse container restarting also closes the
connections it held to Postgres as `hauling_ro`.

### 7.4 Remove the Postgres role

Revokes exactly what the setup script granted, then drops the role. It acts only
on `hauling_ro` (and ends that role's sessions); it needs no change to any table.
If the role was granted more tables later (8.1), add them to the `REVOKE SELECT` list.

```bash
cd /opt/purchasing_data
if [ "$(docker exec mmi-postgres psql -U postgres -XAtc "select count(*) from pg_roles where rolname = 'hauling_ro'")" = 1 ]; then
docker exec -i mmi-postgres psql -U postgres -X -v ON_ERROR_STOP=1 -d hauling_tracker <<'EOF'
SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE usename = 'hauling_ro';
REVOKE SELECT ON TABLE public.trips, public.barge_loadings, public.scale_readings_pending, public.station_heartbeat, public.error_log FROM hauling_ro;
REVOKE USAGE ON SCHEMA public FROM hauling_ro;
REVOKE CONNECT ON DATABASE hauling_tracker FROM hauling_ro;
DROP ROLE hauling_ro;
EOF
echo "exit=$?"
else
echo "NOT RUN: there is no role hauling_ro"
fi
docker exec mmi-postgres psql -U postgres -XAtc "select count(*) from pg_roles where rolname = 'hauling_ro'"
```

Expected: a `pg_terminate_backend` table with 0 rows (or a few `t` rows: ClickHouse
sessions were still open), then `REVOKE`, `REVOKE`, `REVOKE`, `DROP ROLE`,
`exit=0` and a final `0`. If `DROP ROLE` says "cannot be dropped because
some objects depend on it", it lists them: paste that, do not force anything.

Prove hauling_tracker is back to its original state (needs the files from 0.5):

```bash
cd /opt/purchasing_data
if [ -s /root/hauling_fp_before.txt ] && [ -s /root/hauling_fp.sql ]; then
  docker exec -i -e PGOPTIONS='-c default_transaction_read_only=on' mmi-postgres psql -U postgres -X -At -v ON_ERROR_STOP=1 -d hauling_tracker < /root/hauling_fp.sql > /root/hauling_fp_after_rollback.txt
  diff /root/hauling_fp_before.txt /root/hauling_fp_after_rollback.txt && echo "IDENTICAL to the picture taken in 0.5"
fi
```

To stop using the code on the server too (optional): nothing to do, the new
files are inert. Do not `git checkout` an old commit just for this; it would
leave the repository on a detached HEAD for the next deploy.

---

## Phase 8 — Later

### 8.1 Adding a phase-2 table (`audit_log`, `users`, `station_request_log`)

Their columns have not been seen, so none are defined yet. First get the
definition (read-only), and **tell Calvin** that one more table becomes readable:

```bash
cd /opt/purchasing_data
docker exec -e PGOPTIONS='-c default_transaction_read_only=on' mmi-postgres psql -U postgres -X -d hauling_tracker -c '\d public.audit_log'
```

Then it is four small edits in the repo, each at a marked place:

| File | Edit |
|---|---|
| `db/hauling_ro_setup.sql` | add the table to `:tables` and remove it from `:forbidden` (see its "EXTENSION POINT — PHASE 2"). For `users`: grant **columns**, never the table, leaving out the password hash |
| `db/hauling_ch_schema.sql` | one `CREATE TABLE IF NOT EXISTS hauling.<table>` |
| `db/hauling_sync.sql` | one block for it (snapshot swap or incremental, like its neighbours) |
| `scripts/hauling_sync.sh` | one entry in `TABLES` and one in `verify_sql` |

On the server: `git pull`, rerun 2.1 (idempotent; it adds the new grant), rerun
2.2/2.3 (the before/after comparison should now show only the new table's
`hauling_ro` grant, which is excluded from the comparison, so it stays
`IDENTICAL`), then `scripts/hauling_sync.sh --init`, `--full`, `--verify`
(5.1 to 5.3). Never mirror `sessions` or `schema_migrations`.

### 8.2 Calvin changes a mirrored table

The sync names every column it copies, so a **new** column in a mirrored table is
simply not copied and nothing breaks. A **renamed or dropped** column makes the
run fail with a `FAILED` line in `/var/log/hauling-ch-sync.log`; the mirror keeps
its last good copy (a failed run swaps nothing and does not advance the
watermark), and the other procurement jobs are unaffected. Fix the column in
`db/hauling_ch_schema.sql` and `db/hauling_sync.sql` (and `scripts/hauling_sync.sh`
if it appears in `verify_sql`), then rebuild the table: drop only that table's
mirror with the `hauling.<table>` name, or simply drop the database (7.2) and
redo 5.1 to 5.3. A column added to `users` after it is mirrored needs 2.1 re-run,
because that grant is per column.

### 8.3 Rotating the password

Change `HAULING_RO_PASSWORD` in `.env` (`openssl rand -hex 24`; remove the old
line first with `sed -i '/^HAULING_RO_PASSWORD=/d' .env`), rerun 2.1 (sets the
new password on the role), then `docker compose up -d --force-recreate clickhouse`
(3.1), then 4.1 to prove it.

### 8.4 Pointing a dashboard at ClickHouse (described, not set up)

Do not give a dashboard `procurement_user`: it can write and sees procurement.
Create a separate ClickHouse user that can only read the mirror:

- a file `db/clickhouse-config.d/50-hauling-reader.xml`, mounted into
  `/etc/clickhouse-server/users.d/` the same way as the 30- users file, defining
  `<hauling_reader>` with its own password (from a new `.env` value), the
  built-in `readonly` profile, an optional `max_execution_time` and `max_memory_usage`
  cap in a profile, and `<grants><query>GRANT SELECT ON hauling.*</query></grants>`
  so it sees nothing in `procurement` or `system`; or, equivalently, the SQL
  `CREATE USER … ; GRANT SELECT ON hauling.* TO …` (the container allows access
  management; SQL-created users live in the data volume);
- reach: the HTTP/native ports are bound to `127.0.0.1` on the host on purpose.
  A dashboard on this host or behind an SSH tunnel
  (`ssh -L 8123:127.0.0.1:8123 root@76.13.19.246`) can use them; anything else
  should join `procurement_net` as a container. Do not publish the ports;
- dashboards must read `error_log` and `station_heartbeat` with `FINAL`, and
  `trips`, `barge_loadings`, `scale_readings_pending` directly (see the header of
  `db/hauling_ch_schema.sql`);
- remember the data is a copy refreshed every 15 minutes, and
  `scale_readings_pending` is a queue snapshot, not history.
