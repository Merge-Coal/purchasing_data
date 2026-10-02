# Runbook - Minimart mirror: copy the `minimart` database into ClickHouse

Run on **76.13.19.246** as **root**. Numbered steps, top to bottom. Say "5.4
failed" and paste the output of that step only.

```
mmi-postgres / minimart  --(minimart_ro, SELECT only)-->  ClickHouse database `minimart`
   your own app's data        named collection pg_minimart       a rebuildable copy
                              every 15 min, host cron: scripts/minimart_sync.sh
```

**Start here only after the migration is done.** This runbook begins when the
database `minimart` already lives on `mmi-postgres` and the minimart app uses it:
`RUNBOOK_MINIMART_MIGRATION.md` must be finished through its **phase 3 (the
cutover: restore, `--verify` clean, app started on the new database, browser test,
and the check in 3.6)**. That runbook already created the roles and put
`MINIMART_RO_PASSWORD` into `.env` (its 2.1 and 2.3). Its later phases (stopping the
old container, closing port 5433, the backup cron) do not matter here and can happen
before or after this runbook. This file does not repeat
anything from the migration runbook and changes none of its files.

Nothing in the minimart schema is written down in this repository: the mirror
**reads the catalog of the live database** and generates its tables and sync from
it (`--init`). So the one decision point is in 5.2: you read what it generated
before the first load.

What this runbook changes on the Postgres side: grants for the login
`minimart_ro` (which the migration created) and its password. Nothing in
`minimart` is written or altered, no other database or role is touched, and
`mmi-postgres` is never restarted. The procurement app and the hauling mirror keep
running throughout; the only effect on them is the 5-second ClickHouse blip in
phase 3.

| Phase | What | Minutes | Effect |
|---|---|---|---|
| 0 | Read-only pre-checks, save a "before" picture of Postgres | 15 | none |
| 1 | Get the code, add `MINIMART_RO_PASSWORD` to `.env` | 5 | none |
| 2 | Postgres: set the password and grants of `minimart_ro`, test it, prove nothing else changed | 10 | grants only |
| 3 | Recreate the ClickHouse container (about 5 s warehouse blip) | 5 | app unaffected |
| 4 | Can ClickHouse read minimart? Is a secret column refused? | 5 | read-only |
| 5 | Generate the mirror (`--init`), review it, first full load, verify | 15 and up | new ClickHouse database only |
| 6 | Cron every 15 minutes, log rotation, check 20 minutes later | 5 + 20 wait | |
| 7 | Rollback (only if needed) | 10 | |
| 8 | Operations: schema drift, adding or excluding things, morning check, password rotation, notes for dashboard authors | | |

About 55 minutes of work plus the 20-minute wait in 6.3. The first full load
(5.4) takes as long as the data is big: seconds for a small database.

**How to use this file.** Paste **one block at a time**, never old terminal
output (the lines under "Expected" are not commands). Every block starts with
`cd /opt/purchasing_data` and defines its own helper functions, so it works in a
fresh SSH session. Nothing here prints the password. Names like `<N>` in an
expected output stand for a number that depends on your data.

**STOP** means: do not run the next step. Do what the STOP line says (usually
nothing, or one undo command), then paste the output into Claude.

Things never to run during or after this work: `docker compose down -v`
(deletes the ClickHouse volume), any `DROP` or `TRUNCATE` on the ClickHouse
databases **`procurement`** or **`hauling`**, anything that writes to the
`minimart` Postgres database, `docker restart mmi-postgres` (it serves another
live system) and `git stash pop`. (Dropping the ClickHouse database `minimart` is
fine and is the rollback: it only holds a copy.)

Facts to know up front:

- **The mirror needs no backup.** It is rebuilt from Postgres at any time with
  `scripts/minimart_sync.sh --init` and `--full` (5.1, 5.4). The backup of
  `minimart` itself is part of the migration runbook, not of this one.
- **Connection budget.** `minimart_ro` has `CONNECTION LIMIT 20` and a 120 s
  `statement_timeout`. The scripts never keep a connection: the planner
  (`--init`, `--print`, `--verify`'s drift check) opens at most about 10 at once
  for a few seconds, a sync run opens 1 per table, one table after the other, and
  closes it before the next. Between runs `minimart_ro` has 0 sessions. A database
  with 50 or 500 tables is therefore no problem; 5.6 proves the zero.
- **Secrets are never mirrored.** A column whose name looks like a secret
  (password, passwd, passphrase, secret, token, hash, api key, credential,
  private key, card number, pincode, and the whole words otp, pin, pwd, salt, cvv,
  cvc, card) is excluded twice: Postgres refuses `minimart_ro` to read it
  (column-level grants, phase 2) and the generated sync never names it (phase 5).
  `bytea` (binary) columns are excluded by default too.
- **Times.** The host is on Asia/Makassar (UTC+8): cron times and log stamps in this
  file are host time (`+0800`).

---

## Phase 0 - Pre-checks (nothing changes)

### 0.1 Where the server is now

```bash
cd /opt/purchasing_data
[ -s /root/minimart_old_commit ] || git rev-parse HEAD > /root/minimart_old_commit
cat /root/minimart_old_commit
git branch --show-current
git status --short | grep -v '^??' | head -20
docker ps --format '{{.Names}}\t{{.Status}}'
df -h / /opt /var/lib/docker | sort -u
systemctl is-active crond; command -v flock openssl
awk --version 2>&1 | head -1
date '+%F %T %Z'
tail -n 2 /var/log/procurement-ch-sync.log
tail -n 2 /var/log/hauling-ch-sync.log
```

Expected: a commit hash (saved once in `/root/minimart_old_commit`, the undo point
for 3.1) and the branch name; `git status` lists nothing (untracked files are
hidden on purpose) or only files you already know about;
`procurement_clickhouse` Up (healthy), `procurement_app` Up, `mmi-postgres` Up
(and your minimart app); at least 2 GB free; `active`; two paths (`flock`,
`openssl`); `GNU Awk 4.x` or `5.x` (RHEL's default; the overrides file in 5.3 needs GNU awk);
a time zone `+08`/`WITA`; the last two lines of each sync log, ending in
`[incremental] OK` from the last quarter hour.

**STOP** if `procurement_clickhouse` or `mmi-postgres` is not Up, the disk has
under 1 GB free, or `flock`/`openssl` print nothing. Nothing to undo.

### 0.2 Is the migration finished? (read-only)

The helper opens its sessions read-only, so these cannot write even by mistake.

```bash
cd /opt/purchasing_data
pgq() { docker exec -e PGOPTIONS='-c default_transaction_read_only=on' mmi-postgres psql -U postgres -X -v ON_ERROR_STOP=1 "$@"; }
pgq -Atc "select datname || ' owner=' || pg_get_userbyid(datdba) from pg_database where datname in ('minimart', 'procurement', 'hauling_tracker', 'minimart_rehearsal') order by 1"
pgq -Atc "select rolname, rolcanlogin, rolsuper, rolconnlimit, coalesce(array_to_string(rolconfig, ' | '), '') from pg_roles where rolname like 'minimart%' order by 1"
pgq -Atc "select 'minimart_ro has a password: ' || (rolpassword is not null)::text from pg_authid where rolname = 'minimart_ro'"
pgq -d minimart -Atc "select table_schema, table_type, count(*) from information_schema.tables where table_schema not in ('pg_catalog', 'information_schema') group by 1, 2 order by 1, 2"
pgq -d minimart -Atc "select usename, count(*) from pg_stat_activity where datname = 'minimart' group by 1 order by 1"
pgq -d minimart -Atc "select count(*) || ' tables readable by minimart_ro' from information_schema.tables t where t.table_schema not in ('pg_catalog', 'information_schema') and has_table_privilege('minimart_ro', format('%I.%I', t.table_schema, t.table_name), 'SELECT')"
```

Expected, in order:

1. `minimart owner=minimart_owner`, plus `hauling_tracker` and `procurement` (and no
   `minimart_rehearsal`: the migration drops it).
2. Three roles: `minimart_app|t|f|50|` (the limit is whatever the migration set),
   `minimart_owner|f|f|-1|`, `minimart_ro|t|f|20|` followed by four settings in any
   order: `TimeZone=UTC`, `DateStyle=ISO, YMD`, `default_transaction_read_only=on`,
   `statement_timeout=120s`.
3. `minimart_ro has a password: true`.
4. `public|BASE TABLE|<N>` (your tables). Rows for `VIEW` or for another schema are
   allowed but are **not mirrored** (only ordinary tables of schema `public`).
5. `minimart_app|<n>` (the app is connected to the new database).
6. `0 tables readable by minimart_ro` (the migration gives it no table privileges on
   purpose; phase 2 here does). Anything else: paste it, someone granted more.

**STOP** if `minimart` or one of the three roles is missing, `minimart_ro` is a
superuser or has no password, or its settings are not as listed: the migration is
not finished. Go back to its cutover phase. If line 5 shows no `minimart_app`
session, the app may be idle at this hour or still pointed at the old container:
tell Claude, because the mirror would copy a database nobody writes to. Nothing to
undo.

### 0.3 Connection headroom and the network rule

```bash
cd /opt/purchasing_data
pgq() { docker exec -e PGOPTIONS='-c default_transaction_read_only=on' mmi-postgres psql -U postgres -X -v ON_ERROR_STOP=1 "$@"; }
pgq -Atc "select count(*) || ' of ' || current_setting('max_connections') || ' connections in use' from pg_stat_activity"
pgq -Atc "select count(*) || ' sessions of minimart_ro' from pg_stat_activity where usename = 'minimart_ro'"
pgq -Atc "show password_encryption"
pgq -Atc "select line_number, type, database, user_name, address, auth_method from pg_hba_file_rules where type like 'host%'"
```

Expected: something like `14 of 100 connections in use` (the mirror holds a few
connections for a few seconds every 15 minutes, 20 at most); `0 sessions of
minimart_ro`; `scram-sha-256`; a `host` rule for all databases and users from any
address with `scram-sha-256` (the image's default), and normally also `127.0.0.1`
with `trust` (used by the checks in 2.3).

**STOP** if connections are within 25 of the maximum or no `host` rule admits other
containers (changing `pg_hba.conf` means reconfiguring a container another system
depends on; that needs a decision). Nothing to undo.

### 0.4 What will be mirrored? (read-only)

Writes the query file `/root/minimart_sens.sql`, used again in 2.3 and 8.3. It lists
every column of schema `public` whose name matches the secret rule (the same two
patterns as `scripts/minimart_gen_schema.sh` and `db/minimart_ro_grants.sql`) and
whether `minimart_ro` can read it **right now**.

```bash
cd /opt/purchasing_data
pgq() { docker exec -e PGOPTIONS='-c default_transaction_read_only=on' mmi-postgres psql -U postgres -X -v ON_ERROR_STOP=1 "$@"; }
pgf() { docker exec -i -e PGOPTIONS='-c default_transaction_read_only=on' mmi-postgres psql -U postgres -X -v ON_ERROR_STOP=1 -d minimart "$@"; }
cat > /root/minimart_sens.sql <<'EOF'
select c.relname || '.' || a.attname as sensitive_column,
       has_column_privilege('minimart_ro', c.oid, a.attnum, 'SELECT') as ro_can_read,
       format('select %I from public.%I limit 1', a.attname, c.relname) as probe
  from pg_attribute a join pg_class c on c.oid = a.attrelid
 where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'p') and not c.relispartition
   and a.attnum > 0 and not a.attisdropped
   and (lower(regexp_replace(a.attname, '([a-z0-9])([A-Z])', '\1_\2', 'g')) ~ '(password|passwd|passphrase|secret|token|hash|api[^a-z0-9]?key|credential|private[^a-z0-9]?key|card[^a-z0-9]?(no|num)|pincode)'
     or lower(regexp_replace(a.attname, '([a-z0-9])([A-Z])', '\1_\2', 'g')) ~ '(^|[^a-z0-9])(otp|pin|pwd|salt|cvv|cvc|card)([^a-z0-9]|$)')
 order by 1
EOF
pgq -d minimart -Atc "select c.relname, c.reltuples::bigint as est_rows, pg_size_pretty(pg_total_relation_size(c.oid)) as size, (select count(*) from pg_index i where i.indrelid = c.oid and i.indisprimary) as has_pk from pg_class c where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'p') and not c.relispartition order by pg_total_relation_size(c.oid) desc limit 30"
pgq -d minimart -Atc "select count(*) || ' tables, ' || pg_size_pretty(sum(pg_total_relation_size(c.oid))) from pg_class c where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'p') and not c.relispartition"
pgq -d minimart -Atc "select count(*) || ' tables without a primary key' from pg_class c where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'p') and not c.relispartition and not exists (select 1 from pg_index i where i.indrelid = c.oid and i.indisprimary)"
pgf -At < /root/minimart_sens.sql | cut -d'|' -f1,2
```

Expected: up to 30 lines `table|estimated rows|size|1 or 0` (largest first; write
down the biggest one: it sets how long 5.4 takes; an estimate of `-1` means the table was
never analysed, tell Claude if a big table shows it); `<N> tables, <size>`; `<N>
tables without a primary key` (these are mirrored as full copies every run, which is
fine for small ones); and the **list of secret-looking columns** as
`table.column|f` (every one `f` at this point: `minimart_ro` has no grants yet).

Read the secret list now. A name that looks secret but is harmless (a `hashtag`
column) will be left out of the mirror: that is the safe direction and is fixed in 5.3.
A secret column whose name does not look like one (a column called `pass` or `code`)
is **not** caught: add it to the overrides in 5.3 before the first load.

**STOP** only if a command errors. Nothing to undo.

### 0.5 ClickHouse: healthy, procurement and hauling intact

```bash
cd /opt/purchasing_data
chq() { docker exec procurement_clickhouse sh -c 'exec clickhouse-client --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" "$@"' chq "$@"; }
docker inspect -f '{{.State.Health.Status}}' procurement_clickhouse
chq --query "SELECT version()"
chq --query "SELECT name FROM system.databases WHERE name NOT IN ('INFORMATION_SCHEMA','information_schema') ORDER BY name"
chq --query "SELECT database, count() AS tables FROM system.tables WHERE database IN ('procurement', 'hauling', 'minimart') GROUP BY database ORDER BY database" | tee /root/minimart_ch_before.txt
chq --query "SELECT name FROM system.named_collections ORDER BY name"
docker exec procurement_clickhouse du -sh /var/lib/clickhouse
```

Expected: `healthy`; `24.8....`; the databases `default`, `hauling`, `procurement`, `system`
and **no** `minimart` (a leftover from an earlier attempt is fine: everything here is
re-runnable); the table counts of `hauling` and `procurement` (saved in
`/root/minimart_ch_before.txt`; 3.2 and 7.2 compare against it); `pg_hauling` and
`pg_procurement` (not `pg_minimart` yet); a size well under the free disk space. (If
the `named_collections` line is refused with "Not enough privileges", skip that one:
step 4.1 is the real test.)

**STOP** if not `healthy`.

### 0.6 Save a "before" picture of minimart (read-only)

Writes files under `/root` (nothing in Postgres). The first file lists every
privilege on the database, schemas, tables, columns and default ACLs, all roles and
memberships, and a fingerprint of every table's structure (owner, columns, number of
indexes), **leaving out `minimart_ro`**. After phase 2 the same query must give
exactly the same answer: that is the proof nothing else changed. The other two files
are row counts and write/read counters per table, for comparison with a live app.

```bash
cd /opt/purchasing_data
cat > /root/minimart_fp.sql <<'EOF'
select 'db', datname, pg_get_userbyid(datdba), case when x.grantee=0 then 'PUBLIC' else pg_get_userbyid(x.grantee) end, x.privilege_type, x.is_grantable::text
  from pg_database d cross join lateral aclexplode(coalesce(d.datacl, acldefault('d'::"char", d.datdba))) x
 where d.datname = current_database() and pg_get_userbyid(x.grantee) <> 'minimart_ro'
union all
select 'schema', nspname, pg_get_userbyid(nspowner), case when x.grantee=0 then 'PUBLIC' else pg_get_userbyid(x.grantee) end, x.privilege_type, x.is_grantable::text
  from pg_namespace s cross join lateral aclexplode(coalesce(s.nspacl, acldefault('n'::"char", s.nspowner))) x
 where s.nspname !~ '^pg_' and s.nspname <> 'information_schema' and pg_get_userbyid(x.grantee) <> 'minimart_ro'
union all
select 'rel', n.nspname || '.' || c.relname, pg_get_userbyid(c.relowner), case when x.grantee=0 then 'PUBLIC' else pg_get_userbyid(x.grantee) end, x.privilege_type, x.is_grantable::text
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
       cross join lateral aclexplode(coalesce(c.relacl, acldefault((case when c.relkind='S' then 's' else 'r' end)::"char", c.relowner))) x
 where n.nspname !~ '^pg_' and n.nspname <> 'information_schema' and c.relkind in ('r','p','v','m','S','f')
   and pg_get_userbyid(x.grantee) <> 'minimart_ro'
union all
select 'col', n.nspname || '.' || c.relname || '.' || a.attname, '', case when x.grantee=0 then 'PUBLIC' else pg_get_userbyid(x.grantee) end, x.privilege_type, x.is_grantable::text
  from pg_attribute a join pg_class c on c.oid = a.attrelid join pg_namespace n on n.oid = c.relnamespace
       cross join lateral aclexplode(a.attacl) x
 where n.nspname !~ '^pg_' and n.nspname <> 'information_schema' and a.attacl is not null
   and pg_get_userbyid(x.grantee) <> 'minimart_ro'
union all
select 'defacl', pg_get_userbyid(defaclrole), defaclobjtype::text, coalesce(defaclacl::text, ''), '', ''
  from pg_default_acl
union all
select 'role', rolname, rolsuper::text || rolcreatedb::text || rolcreaterole::text || rolcanlogin::text || rolreplication::text || rolbypassrls::text,
       rolconnlimit::text, coalesce(rolvaliduntil::text, ''), coalesce(rolconfig::text, '')
  from pg_roles where rolname <> 'minimart_ro'
union all
select 'member', pg_get_userbyid(roleid), pg_get_userbyid(member), '', '', '' from pg_auth_members
 where pg_get_userbyid(member) <> 'minimart_ro'
union all
select 'struct', n.nspname || '.' || c.relname, pg_get_userbyid(c.relowner), c.relkind::text,
       md5(coalesce((select string_agg(a.attname || ':' || format_type(a.atttypid, a.atttypmod) || ':' || a.attnotnull::text, ',' order by a.attnum)
                       from pg_attribute a where a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped), '')),
       (select count(*) from pg_index i where i.indrelid = c.oid)::text
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
 where n.nspname !~ '^pg_' and n.nspname <> 'information_schema' and c.relkind in ('r','p','v','m','S','f')
order by 1, 2, 3, 4, 5, 6
EOF
cat > /root/minimart_counts.sql <<'EOF'
select table_name, (xpath('/row/c/text()', query_to_xml(format('select count(*) as c from %I.%I', table_schema, table_name), false, true, '')))[1]::text as row_count
  from information_schema.tables where table_schema = 'public' and table_type = 'BASE TABLE' order by 1
EOF
cat > /root/minimart_stats.sql <<'EOF'
select relname, n_tup_ins, n_tup_upd, n_tup_del, seq_scan, idx_scan from pg_stat_user_tables where schemaname = 'public' order by 1
EOF
run() { docker exec -i -e PGOPTIONS='-c default_transaction_read_only=on' mmi-postgres psql -U postgres -X -At -v ON_ERROR_STOP=1 -d minimart < "$1" > "$2"; echo "$2 exit=$?"; }
run /root/minimart_fp.sql /root/minimart_fp_before.txt
run /root/minimart_counts.sql /root/minimart_counts_before.txt
run /root/minimart_stats.sql /root/minimart_stats_before.txt
wc -l /root/minimart_fp_before.txt /root/minimart_counts_before.txt /root/minimart_stats_before.txt
grep -c minimart_ro /root/minimart_fp_before.txt
```

Expected: three `exit=0` lines; line counts above 20 for the first file, and one
line per table for the other two; and `0`. The counts query reads every table once
(`count(*)`): a few seconds per million rows.

**STOP** if an exit is not 0 or a file is empty. Nothing to undo.

---

## Phase 1 - Code and `.env` (no container changes yet)

Until phase 3 the running containers are unaffected, and a normal app deploy
(`docker compose up -d --build app`) keeps working: the new variable has an empty
default in `docker-compose.yml`.

### 1.1 Which branch has the minimart mirror?

```bash
cd /opt/purchasing_data
git fetch origin
b=$(git branch --show-current); echo "current branch: $b"
echo "--- on origin/$b:";                  git ls-tree --name-only "origin/$b" scripts/minimart_sync.sh db/minimart_ro_grants.sql
echo "--- on origin/main:";                git ls-tree --name-only origin/main scripts/minimart_sync.sh db/minimart_ro_grants.sql
echo "--- on origin/minimart-migration:";  git ls-tree --name-only origin/minimart-migration scripts/minimart_sync.sh db/minimart_ro_grants.sql
git status --porcelain --untracked-files=no
```

Expected, one of:

- **A. On your current branch:** both files listed under `origin/<current branch>`
  (usually because the migration branch was merged into it, or you are already on
  `minimart-migration`). Use 1.2A.
- **B. Only on `origin/minimart-migration`**, not under your current branch. Use 1.2B.

The last command must print nothing. If it lists modified files, save them first
(they stay in the stash; **never** `git stash pop`):

```bash
cd /opt/purchasing_data
[ -n "$(git status --porcelain --untracked-files=no)" ] && { git diff > /root/minimart_server_local_changes.patch; wc -l /root/minimart_server_local_changes.patch; git stash push -m "pre-minimart-mirror"; }
git status --porcelain --untracked-files=no
```

**STOP** if neither branch has the files (it has not been pushed). Nothing to undo.

### 1.2A The files are on your current branch

```bash
cd /opt/purchasing_data
git pull --ff-only origin "$(git branch --show-current)"
git log -1 --format='%h %s'
git log -1 --format='newest commit touching the mirror: %h %s' -- scripts/minimart_sync.sh db/minimart_ro_grants.sql
```

The first commit line is the head of the branch: it must be the commit Claude gave
you after pushing. The second line is the commit that last changed the mirror files.

### 1.2B Not merged into your current branch: use the migration branch

The server then runs `minimart-migration` instead of its current branch. **Do not
switch back until the branch is merged**: the mirror's files exist only on this
branch, and switching would remove them from disk while the container still mounts
one of them. Deploy the app from the same branch meanwhile.

```bash
cd /opt/purchasing_data
git checkout -B minimart-migration origin/minimart-migration
git log -1 --format='%h %s'
```

### 1.3 Check the files arrived

```bash
cd /opt/purchasing_data
ls -l db/minimart_setup.sql db/minimart_ro_grants.sql db/minimart_ch_schema.sql db/minimart_sync.sql scripts/minimart_sync.sh scripts/minimart_gen_schema.sh db/clickhouse-config.d/50-pg-minimart.xml
chmod +x scripts/minimart_sync.sh scripts/minimart_gen_schema.sh
bash -n scripts/minimart_sync.sh && bash -n scripts/minimart_gen_schema.sh && echo "script syntax OK"
grep -nE 'MINIMART_RO_PASSWORD|50-pg-minimart' docker-compose.yml
scripts/minimart_sync.sh -h | head -n 3
```

Expected: seven files listed, `script syntax OK`, two compose lines
(`- MINIMART_RO_PASSWORD=${MINIMART_RO_PASSWORD:-}` and the read-only mount of
`50-pg-minimart.xml`), and the first lines of the script's help text.

**STOP** if a file is missing or the checkout refused (usually "local changes would
be overwritten" or "untracked files would be overwritten": move each named file to
`/root/` with `mv` and repeat 1.2). Nothing else has changed yet.

### 1.4 Add the password to `.env`

If the migration runbook already put a `MINIMART_RO_PASSWORD` into `.env`, this
block keeps it (it only adds one when there is none) and 2.1 then sets that same
value on the role.

```bash
cd /opt/purchasing_data
cp -p .env /root/env_before_minimart_$(date +%Y%m%d_%H%M%S) && chmod 600 /root/env_before_minimart_*
sed -i '/^MINIMART_RO_PASSWORD=$/d' .env
[ -z "$(tail -c1 .env)" ] || echo >> .env
grep -q '^MINIMART_RO_PASSWORD=' .env || echo "MINIMART_RO_PASSWORD=$(openssl rand -hex 24)" >> .env
chmod 600 .env
grep -E '^MINIMART_RO_PASSWORD=' .env | awk -F= '{print $1, length($2)}'
docker compose config --quiet && echo "compose OK"
```

Expected:
```
MINIMART_RO_PASSWORD 32
compose OK
```

`32` is the value the migration runbook generated (its 2.1); a value made by this
block has length `48`. Run this block again later and it keeps the existing password.
Any length of at least 16 letters and digits is fine (2.1 checks that). **STOP** if
the length is under 16 or compose does not say OK. Undo: copy the newest
`/root/env_before_minimart_*` back to `.env` (`ls -t /root/env_before_minimart_* | head -1`).

---

## Phase 2 - Postgres: the password and the grants of `minimart_ro`

The role exists since the migration. This phase gives it the password from `.env`
and `SELECT` on exactly the tables (and non-secret columns) it should read. No table
is read or changed; no other role is touched. A grant takes a lock for an instant
(the grants script gives up after 5 s rather than wait).

### 2.1 Set the password of `minimart_ro`

This is the same step as the migration's 2.3: `db/minimart_setup.sql` takes the
password on stdin as a psql variable (`\set ro_password ...`), so it never appears in
the process list, and with only `ro_password` given it leaves `minimart_app`'s password
alone. If the migration already set the role's password from this same `.env` value
(length `32` in 1.4), this repeats it: harmless. It is needed when 1.4 had to generate a
new value (length `48`) or the `.env` value was ever changed. The file is idempotent and
re-asserts the role settings and the grants of `minimart_app` (as the migration left
them). `minimart_app`'s connection limit is read first and passed back, so it stays
exactly as it is.

```bash
cd /opt/purchasing_data
pgq() { docker exec -e PGOPTIONS='-c default_transaction_read_only=on' mmi-postgres psql -U postgres -X -v ON_ERROR_STOP=1 "$@"; }
envval() { grep -m1 "^$1=" /opt/purchasing_data/.env | cut -d= -f2-; }
LIM=$(pgq -Atc "select rolconnlimit from pg_roles where rolname = 'minimart_app'")
if envval MINIMART_RO_PASSWORD | grep -Eq '^[A-Za-z0-9]{16,}$' && [[ "$LIM" =~ ^-?[0-9]+$ ]] && [ -s db/minimart_setup.sql ] && [ -s /root/minimart_fp_before.txt ]; then
  { printf '\\set ro_password %s\n' "$(envval MINIMART_RO_PASSWORD)"; cat db/minimart_setup.sql; } | docker exec -i mmi-postgres psql -U postgres -X -v ON_ERROR_STOP=1 -v app_conn_limit="$LIM"
  echo "exit=$?"
else
  echo "NOT RUN: password missing, short or not plain letters/digits (1.4), minimart_app not found, setup file missing (1.2), or the before picture is missing (0.6)"
fi
```

Expected: two small result tables and `exit=0`. The first has one row:
`minimart | minimart_owner | <collate> | <N> | 0 | 0 | 0` (database, owner, collation,
tables, `tables_not_owned_by_owner`, `tables_app_cannot_dml`, `tables_ro_can_write`: the
last three are 0). The second lists the three roles: `minimart_app` (can login `t`, `conn_limit` as before), `minimart_owner`
(`f`), `minimart_ro` (`t`, `conn_limit` 20, role_settings with `TimeZone=UTC`,
`DateStyle=ISO, YMD`, `default_transaction_read_only=on`,
`statement_timeout=120s`). Safe to repeat.

**STOP** on `exit` other than 0, a `NOT RUN` line, or `tables_ro_can_write` above 0.
Undo: nothing to undo for a password; the role keeps working with the old one only
if you restore the `.env` backup from 1.4 and repeat this block.

### 2.2 Grant `SELECT` (table level, and column level where a table has a secret column)

`db/minimart_ro_grants.sql` reads the catalog and applies the rule: a table without a
secret-looking column gets `SELECT` on the whole table; a table with one gets
`SELECT` on every other column only. The arguments come from the optional overrides
file (5.3; absent now, so both lists are empty): `scripts/minimart_sync.sh
--grant-args` prints them, the block below passes them on. The file is idempotent
and convergent: re-running it after a schema change brings the grants back to what
the rule says (this is what 8.3 uses).

```bash
cd /opt/purchasing_data
args=(); while IFS= read -r l; do [ -n "$l" ] && args+=(-v "$l"); done < <(scripts/minimart_sync.sh --grant-args)
echo "grant arguments: ${args[*]}"
if [ "${#args[@]}" -eq 4 ] && [ -s db/minimart_ro_grants.sql ] && [ -s /root/minimart_fp_before.txt ]; then
  docker exec -i mmi-postgres psql -U postgres -X "${args[@]}" < db/minimart_ro_grants.sql
  echo "exit=$?"
else
  echo "NOT RUN: --grant-args did not print two lines (the overrides file has an error: run scripts/minimart_gen_schema.sh --check-overrides), the grants file is missing, or the before picture is missing (0.6)"
fi
```

Expected: first `grant arguments: -v allow_cols= -v deny_cols=`. Then possibly a
`WARNING:` line (views or other schemas that are not granted: they are not mirrored;
note the names) and three tables, then `exit=0`:

```
== minimart_ro grants: per table (table | how granted | excluded sensitive columns | status) ==
 table      | granted           | excluded_sensitive_columns          | status
 <table>    | table             |                                     | ok
 <table>    | columns (9 of 12) | password_hash, api_token, reset_otp | ok
== minimart_ro grants: sensitive columns EXCLUDED (review; ...) ==
 table.column            | reason
 <table>.<column>        | name rule
== minimart_ro grants: checks ==
 sensitive columns readable by the role   | (none) | (none) | ok
 role cannot write anything (...)         | (none) | (none) | ok
 ...
minimart_ro grants: all hard checks passed, warnings = 0
```

Every `status` is `ok`; `granted` is `table` or `columns (n of m)`; the excluded
list is the same list you saw in 0.4. `warnings = 1` with the check "CREATE on
schema public ... true" means PUBLIC may create objects in `public` (a PostgreSQL 14
default; the migration normally closes it): note it, it is not caused by this
runbook. A warning "tables with no readable column at all" names a table whose every
column looks secret: it is not mirrored.

**STOP** on `exit` other than 0, any `FAIL` row, or `VERIFICATION FAILED`. Paste the
tables. Undo (revokes exactly what this granted): 7.4.

### 2.3 What can `minimart_ro` actually do?

The first block logs in **as `minimart_ro`** from inside the postgres container
(`env -u PGTZ -u TZ` because that container's `PGTZ/TZ` would make the session report
Makassar even though the role is UTC). It runs over loopback, which the image trusts,
so it tests the grants; the password is tested by ClickHouse in 4.1.

```bash
cd /opt/purchasing_data
hro() { docker exec mmi-postgres env -u PGTZ -u TZ psql -U minimart_ro -h 127.0.0.1 -d minimart -XAt "$@"; }
hro -c "select current_user, current_setting('TimeZone'), current_setting('DateStyle'), current_setting('default_transaction_read_only'), current_setting('statement_timeout')"
hro -c "select count(*) filter (where has_table_privilege(c.oid, 'SELECT')) || ' whole tables, ' || count(*) filter (where not has_table_privilege(c.oid, 'SELECT') and has_any_column_privilege(c.oid, 'SELECT')) || ' tables by column, ' || count(*) || ' tables in public' from pg_class c where c.relnamespace = 'public'::regnamespace and c.relkind in ('r','p') and not c.relispartition"
t=$(hro -c "select relname from pg_class c where c.relnamespace = 'public'::regnamespace and c.relkind in ('r','p') and not c.relispartition and has_table_privilege(c.oid, 'SELECT') order by pg_relation_size(c.oid) limit 1")
echo "smallest fully readable table: $t"
hro -c "select count(*) from public.\"$t\""
hro -c "begin read write; delete from public.\"$t\" where false; rollback"
```

Expected:

- `minimart_ro|UTC|ISO, YMD|on|2min`
- `<a> whole tables, <b> tables by column, <a+b> tables in public` (the three
  numbers add up: every table is readable, some only by column)
- the name of the smallest fully readable table, then its row count (the same as in
  `/root/minimart_counts_before.txt`, give or take what the app wrote since)
- `ERROR:  permission denied for table <that table>` on the last line: **this error
  is correct**. The role cannot write even when the read-only default is switched off.

Now the secret columns, as the superuser (read-only) and then as `minimart_ro`:

```bash
cd /opt/purchasing_data
pgm() { docker exec -i -e PGOPTIONS='-c default_transaction_read_only=on' mmi-postgres psql -U postgres -X -v ON_ERROR_STOP=1 -d minimart "$@"; }
hro() { docker exec mmi-postgres env -u PGTZ -u TZ psql -U minimart_ro -h 127.0.0.1 -d minimart -XAt "$@"; }
pgm -At < /root/minimart_sens.sql | cut -d'|' -f1,2
probe=$(pgm -At < /root/minimart_sens.sql | head -n 1 | cut -d'|' -f3)
if [ -n "$probe" ]; then echo "probe: $probe"; hro -c "$probe"; else echo "no secret-looking columns in minimart: nothing to refuse"; fi
```

Expected: the same list as in 0.4 but with `f` for **every** column (this is the
answer to "can `minimart_ro` read a secret?": no), then `probe: select <column> from
public.<table> limit 1` and `ERROR:  permission denied for table <table>`
(**correct**), or the "nothing to refuse" line.

Then what `minimart_ro` holds and where it cannot go:

```bash
cd /opt/purchasing_data
pgq() { docker exec -e PGOPTIONS='-c default_transaction_read_only=on' mmi-postgres psql -U postgres -X -v ON_ERROR_STOP=1 "$@"; }
pgq -d minimart -Atc "select count(*) from pg_class c where c.relnamespace = 'public'::regnamespace and c.relkind in ('r','p','v','m') and (has_table_privilege('minimart_ro', c.oid, 'INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER') or has_any_column_privilege('minimart_ro', c.oid, 'INSERT,UPDATE,REFERENCES'))"
pgq -d minimart -Atc "select has_schema_privilege('minimart_ro', 'public', 'CREATE')"
pgq -Atc "select datname from pg_database where has_database_privilege('minimart_ro', datname, 'CONNECT') order by 1"
pgq -Atc "select rolsuper, rolcreatedb, rolcreaterole, rolreplication, rolbypassrls, rolconnlimit from pg_roles where rolname = 'minimart_ro'"
pgq -Atc "select count(*) from pg_auth_members where member = 'minimart_ro'::regrole"
```

Expected: `0` (no table with any write privilege); `f` (a `t` is the same thing as the
`CREATE on schema public` warning in 2.2: paste it); a list that contains `minimart`
and **not** `procurement` (another database may be listed when PUBLIC may connect to
it; nothing in it is readable for this role: tell Claude if `procurement` is
listed); `f|f|f|f|f|20`; `0`.

**STOP** if anything differs, especially a write privilege, a secret column that is
readable (`t`), `has_*` returning `t`, or a probe that returns data. Undo: 7.4.

If the `hro` lines fail with `fe_sendauth: no password supplied` or `password
authentication failed`, this container asks a password even on loopback: the grants
can be tested instead with `docker exec mmi-postgres psql -U postgres -d minimart -XAtc "set role minimart_ro; <the same statement>"`
(it checks privileges but not the role's session settings); paste it into Claude
rather than skipping the test.

### 2.4 Nothing else in minimart changed

```bash
cd /opt/purchasing_data
run() { docker exec -i -e PGOPTIONS='-c default_transaction_read_only=on' mmi-postgres psql -U postgres -X -At -v ON_ERROR_STOP=1 -d minimart < "$1" > "$2"; echo "$2 exit=$?"; }
if [ -s /root/minimart_fp_before.txt ] && [ -s /root/minimart_fp.sql ]; then
  run /root/minimart_fp.sql /root/minimart_fp_after.txt
  diff /root/minimart_fp_before.txt /root/minimart_fp_after.txt && echo "IDENTICAL: no privilege, role, schema, default ACL or table structure other than minimart_ro's changed"
  run /root/minimart_counts.sql /root/minimart_counts_after.txt
  run /root/minimart_stats.sql /root/minimart_stats_after.txt
  diff /root/minimart_counts_before.txt /root/minimart_counts_after.txt && echo "row counts: unchanged"
else
  echo "NOT RUN: /root/minimart_fp.sql or the before picture is missing (0.6)"
fi
```

Expected: `exit=0` three times and `IDENTICAL: ...`. The comparison ignores
`minimart_ro` itself (its grants are what phase 2 added) and compares everything else,
including PUBLIC, the other roles (so `minimart_app`'s connection limit), and a
fingerprint of every table's owner, columns and index count.

The row-count diff may print lines: **the minimart app is live**, so counts grow with
its own writes. Lines where a count is only higher are normal; a count that dropped,
or a table that appeared or vanished, is not (the grants never write). The counters
in `/root/minimart_stats_after.txt` behave the same way: `n_tup_ins/upd/del` are the
app's writes (`diff /root/minimart_stats_before.txt /root/minimart_stats_after.txt`),
while the mirror's reads can only move `seq_scan` and `idx_scan`.

**STOP** if `diff` of the fingerprint prints any line (something besides
`minimart_ro` changed; do not guess, paste the lines) or a row count dropped. Undo: 7.4.

---

## Phase 3 - ClickHouse: pick up the new source (about 5 s blip)

The container is recreated (volume and data kept) so it reads the new config file
and `MINIMART_RO_PASSWORD`. The warehouse is unreachable for about 5 s; a procurement
or hauling sync that starts in that window simply runs on the next tick; the apps do
not use ClickHouse and keep serving. The block refuses to run in the few minutes around
a procurement (:00/:15/:30/:45) or hauling (:07/:22/:37/:52) sync (from one minute
before to two minutes after the start), and tells you to wait.

### 3.1 Recreate and wait

```bash
cd /opt/purchasing_data
m=$((10#$(date +%M))); busy=0
for b in 0 7 15 22 30 37 45 52; do d=$(( (m - b + 60) % 60 )); { [ "$d" -le 2 ] || [ "$d" -ge 59 ]; } && busy=1; done
if [ "$busy" = 1 ]; then
  echo "NOT RUN: a procurement or hauling sync is starting or running now (minute $m). Wait three minutes and paste this block again."
else
  docker compose config --quiet && docker compose up -d --force-recreate --no-deps clickhouse
  for i in $(seq 1 30); do s=$(docker inspect -f '{{.State.Health.Status}}' procurement_clickhouse); [ "$s" = healthy ] && break; sleep 3; done; echo "$s"
  docker logs --tail=30 procurement_clickhouse 2>&1 | grep -iE 'error|exception' || echo "no errors"
fi
```

Expected: a line about `procurement_clickhouse` being recreated/started (and
nothing about `procurement_app`), then `healthy`, then `no errors`.

If it does not become healthy: the app is unaffected. Paste the logs, then put the
previous config back:
```bash
cd /opt/purchasing_data
git show "$(cat /root/minimart_old_commit)":docker-compose.yml > /root/old-compose.yml
docker compose -f /root/old-compose.yml --project-directory /opt/purchasing_data up -d --force-recreate --no-deps clickhouse
```

### 3.2 Is the new source loaded, and are procurement and hauling still fine?

```bash
cd /opt/purchasing_data
chq() { docker exec procurement_clickhouse sh -c 'exec clickhouse-client --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" "$@"' chq "$@"; }
chq --query "SELECT name FROM system.named_collections ORDER BY name"
docker exec procurement_clickhouse ls /etc/clickhouse-server/config.d/
docker exec procurement_clickhouse sh -c 'printf %s "$MINIMART_RO_PASSWORD" | wc -c'
docker ps --format '{{.Names}}\t{{.Status}}' | grep -E 'procurement|mmi-postgres'
chq --query "SELECT database, count() AS tables FROM system.tables WHERE database IN ('procurement', 'hauling', 'minimart') GROUP BY database ORDER BY database" | diff /root/minimart_ch_before.txt - && echo "procurement and hauling table counts unchanged"
scripts/ch_sync.sh; echo "procurement sync exit=$?"
scripts/hauling_sync.sh; echo "hauling sync exit=$?"
```

Expected: `pg_hauling`, `pg_minimart`, `pg_procurement`; the file list includes
`50-pg-minimart.xml`; `48`; the containers Up; `procurement and hauling table counts
unchanged`; both syncs `exit=0` (each run once by hand).

**STOP** if `pg_minimart` is missing (if the `named_collections` line itself is
refused with "Not enough privileges", skip it and go on to 4.1) or the password length
is `0` (`.env` has no value: redo 1.4, then 3.1). A failing procurement or hauling
sync here is not caused by minimart (their files are untouched); paste its log line
anyway: `tail -3 /var/log/procurement-ch-sync.log /var/log/hauling-ch-sync.log`.

---

## Phase 4 - Can ClickHouse read minimart? (read-only)

Postgres sends `timestamptz` as text with an offset, and ClickHouse's `postgresql()`
reader drops the offset and reads the wall-clock part. `minimart_ro` is pinned to UTC
for exactly that reason, so what ClickHouse sees equals the real UTC instant. The host
is on Makassar time: a wrong setup would show up here as timestamps eight hours apart.

### 4.1 Tables, a count and a timestamp

```bash
cd /opt/purchasing_data
chq() { docker exec procurement_clickhouse sh -c 'exec clickhouse-client --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" "$@"' chq "$@"; }
pgm() { docker exec -e PGOPTIONS='-c default_transaction_read_only=on' mmi-postgres psql -U postgres -X -v ON_ERROR_STOP=1 -d minimart "$@"; }
chq --query "SELECT count() FROM postgresql(pg_minimart, schema = 'information_schema', table = 'tables') WHERE table_schema = 'public' AND table_type = 'BASE TABLE'"
pgm -Atc "select count(*) from information_schema.tables where table_schema = 'public' and table_type = 'BASE TABLE'"
t=$(pgm -Atc "select c.relname from pg_class c where c.relnamespace = 'public'::regnamespace and c.relkind in ('r','p') and not c.relispartition and has_table_privilege('minimart_ro', c.oid, 'SELECT') and c.relname ~ '^[a-z_][a-z0-9_]*$' order by pg_relation_size(c.oid) limit 1")
echo "table: $t"
chq --query "SELECT count() FROM postgresql(pg_minimart, table = '$t')"
pgm -Atc "select count(*) from public.\"$t\""
col=$(pgm -Atc "select c.relname || '|' || a.attname from pg_attribute a join pg_class c on c.oid = a.attrelid where c.relnamespace = 'public'::regnamespace and c.relkind in ('r','p') and a.atttypid = 'timestamptz'::regtype and a.attnum > 0 and not a.attisdropped and has_column_privilege('minimart_ro', c.oid, a.attnum, 'SELECT') and c.relname ~ '^[a-z_][a-z0-9_]*$' and a.attname ~ '^[a-z_][a-z0-9_]*$' order by c.relname, a.attnum limit 1")
echo "timestamptz column: ${col:-none}"
if [ -n "$col" ]; then
  tt=${col%%|*}; cc=${col##*|}
  chq --query "SELECT toString(max(toDateTime64(toString($cc), 6, 'UTC'))) FROM postgresql(pg_minimart, table = '$tt')"
  pgm -Atc "select to_char(max($cc) at time zone 'UTC', 'YYYY-MM-DD HH24:MI:SS.US') from public.$tt"
fi
```

Expected: the two table counts are equal (the number of tables in `public`; both
sides see only what `minimart_ro` may read, so a table whose every column is secret
would differ by one: tell Claude); `table: <name>` and two equal row counts; then
either `timestamptz column: <table>|<column>` and two **identical** timestamps
(`2026-...`, six decimals), or `none` (the database has no `timestamptz` column; then
see 8.7 for what the naive `timestamp` columns mean).

- `password authentication failed for user "minimart_ro"` or `no password supplied`
  -> the `.env` value and the role disagree. Redo 2.1, then 3.1, then this block.
- `Not enough privileges ... NAMED COLLECTION` -> the users grant did not load; paste
  `docker exec procurement_clickhouse ls /etc/clickhouse-server/users.d/`. (This fails
  closed: nothing is readable.)
- timestamps differ by whole hours -> **do not continue**; paste both lines.
- `could not translate host name` -> the clickhouse container is not on the
  mmi-postgres network; paste `docker inspect procurement_clickhouse -f '{{json .NetworkSettings.Networks}}'`.

### 4.2 The secret column must be refused

```bash
cd /opt/purchasing_data
chq() { docker exec procurement_clickhouse sh -c 'exec clickhouse-client --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" "$@"' chq "$@"; }
pgm() { docker exec -i -e PGOPTIONS='-c default_transaction_read_only=on' mmi-postgres psql -U postgres -X -v ON_ERROR_STOP=1 -d minimart "$@"; }
row=$(pgm -At < /root/minimart_sens.sql | head -n 1)
if [ -n "$row" ]; then
  tc=${row%%|*}; tt=${tc%%.*}; cc=${tc#*.}
  echo "trying to read $tc through ClickHouse"
  chq --query "SELECT \`$cc\` FROM postgresql(pg_minimart, table = '$tt') LIMIT 1" 2>&1 | grep -m1 -o 'permission denied for table [^ ]*'
else
  echo "no secret-looking columns in minimart: nothing to refuse"
fi
```

Expected: `permission denied for table <table>` (**correct**: ClickHouse cannot read the
secret column either), or the "nothing to refuse" line. (A table or column name with
a space or capitals is not handled by this block: use a hand-written query and tell
Claude.)

**STOP** if the last line prints nothing although a column was tried (that would mean
the secret was readable: do not continue, paste the output, and roll back with 7.4).

---

## Phase 5 - The `minimart` database and the first load

Only creates the ClickHouse database `minimart` (never touches `procurement` or
`hauling`) and reads Postgres through the named collection.

### 5.1 Generate the mirror

```bash
cd /opt/purchasing_data
scripts/minimart_sync.sh --init; echo "exit=$?"
```

Expected, in a few seconds (more for hundreds of tables):

```
2026-10-02 14:03:11 +0800 [init] OK: plan 20261002060309-12345: <N> tables (<a> snapshot, <b> incremental_updated, <c> incremental_created); run scripts/minimart_sync.sh --print to review, then --full for the first load
2026-10-02 14:03:11 +0800 [init] not mirrored (sensitive): <table>.<column>
exit=0
```

`<N>` is the number of mirrored tables (the tables of `public` minus excluded ones).
There is one `not mirrored (sensitive)` line per secret column; they match the list
from 0.4. Safe to repeat: every run stores a new plan (the last 5 are kept).
`--init` creates the tables empty and drops its check tables again; no data is read.

**STOP** on `FAILED:` or a non-zero exit. The message is in the log line (passwords
are masked). Typical causes: `cannot reach ClickHouse` (container not healthy),
`password authentication failed` (redo 2.1 and 3.1), `Not enough privileges`.
Nothing is damaged: the mirror is a copy.

### 5.2 Review what was generated (read-only)

```bash
cd /opt/purchasing_data
scripts/minimart_sync.sh --print | head -n 60
```

Expected, the top of the report (`--print | less` shows all of it; the second half
is the generated SQL):

```
== minimart mirror plan: what --init would generate from the live Postgres catalog (nothing is written) ==
overrides file : /opt/purchasing_data/minimart_sync_overrides.conf (absent: none applied)
small tables   : below 100000 estimated rows are snapshots (MINIMART_SMALL_ROWS)

-- tables
TABLE      STRATEGY             ROWS(est)  KEY           CHANGE_COLUMN  VS_STORED_PLAN  REASON
<table>    snapshot             <n>        <key>         -              same            small table (<n> rows < 100000)
<table>    incremental_updated  <n>        <key>         updated_at     same            primary key + updated_at
<table>    incremental_created  <n>        <key>         created_at     same            primary key + append-only created_at
<table>    snapshot             <n>        -             -              same            no primary key
<table>    snapshot             <n>        <k1>,<k2>     -              same            no usable change column

-- columns NOT mirrored (a column that is excluded is never read from Postgres)
  <table>.<column>  [sensitive name]
  <table>.<column>  [binary (bytea); allow-column mirrors it as hex text]

-- never mirrored: views, materialized views, foreign tables, tables of schemas other than public
  public.<view>  [view]

-- sensitive-name columns that minimart_ro CAN read (should be none: run db/minimart_ro_grants.sql)
  none
```

How to read it:

- **STRATEGY** is chosen per table by a fixed rule (first match wins): no primary
  key, or a key column is excluded -> `snapshot`; fewer than 100,000 estimated rows ->
  `snapshot`; primary key and an `updated_at`-like timestamp column ->
  `incremental_updated`; primary key and an append-only `created_at`-like column ->
  `incremental_created`; anything else -> `snapshot`. **REASON** says which line
  matched. A `snapshot` is copied completely and swapped in atomically every run, so
  updates and deletes arrive within 15 minutes. An `incremental_*` table gets only
  rows newer than its watermark (minus a 60-minute overlap); see 8.6 for what that
  means for queries.
- **ROWS(est)** is Postgres' own estimate; a table that was never analysed shows 0
  and is treated as small.
- **VS_STORED_PLAN**: `same` after 5.1. `new` or `DIFFERENT` appear later, after
  Postgres changed (8.3).
- **columns NOT mirrored**: secrets (`sensitive name`), binary columns, and anything
  excluded by your overrides. Never read from Postgres.
- **never mirrored**: views, materialized views, foreign tables and tables outside
  schema `public`. If one of them matters, tell Claude.
- **sensitive-name columns that minimart_ro CAN read**: must say `none`. A line
  `WARNING <table>.<column>` means the grants of 2.2 are out of date: run 2.2 again
  and then `--init` again, before any data is loaded.

If the layout is what you expect, go to 5.4. If a strategy or a column is wrong, use
5.3. To see one table's full SQL (its source table, mirror table, incremental and
full load, and verify queries): `scripts/minimart_sync.sh --print <table>`.

**STOP** before the first load if the WARNING list is not `none`, a table you expected
is missing (it is not readable by `minimart_ro`, is in another schema, or has no
column that is readable: run 2.2 again and `--init`), or a secret column whose name
does not look like one appears in no list (add it in 5.3).

### 5.3 Optional: the overrides file

Skip this unless 5.2 showed something to change. The file is read by `--init`, by
every sync (for the drift check) and by the grants step; it lives in the repository
directory and is **not** in git (it will show as untracked in `git status`, which is
fine). One directive per line, `#` starts a comment, names with spaces or capitals go
in double quotes:

| Line | Effect |
|---|---|
| `exclude <table>` | do not mirror the table |
| `snapshot <table>` | full copy every run, whatever its size |
| `incremental <table> <column> [updated\|created]` | incremental on that column (default `updated`: re-sent rows replace old ones; `created`: append-only) |
| `exclude-column <table>.<column>` | never mirror this column, **and withhold it from `minimart_ro`** (needs 2.2 again) |
| `allow-column <table>.<column>` | mirror a column that the name rule or the `bytea` rule excluded (only after you looked at it; needs 2.2 again for a secret-looking name; a `bytea` column is then mirrored as hex text) |
| `string-column <table>.<column>` | keep the Postgres text form of the column (no typed conversion; the fix for a column that fails to convert, see 8.7) |

Create a template (does nothing if the file exists), then edit it:

```bash
cd /opt/purchasing_data
if [ ! -e minimart_sync_overrides.conf ]; then
cat > minimart_sync_overrides.conf <<'EOF'
# minimart mirror overrides. One directive per line; # starts a comment.
# Names with spaces or capitals go in double quotes: exclude "Legacy Notes"
#
# exclude <table>
# snapshot <table>
# incremental <table> <column> [updated|created]
# exclude-column <table>.<column>
# allow-column <table>.<column>
# string-column <table>.<column>
EOF
chmod 644 minimart_sync_overrides.conf
fi
ls -l minimart_sync_overrides.conf
scripts/minimart_gen_schema.sh --check-overrides
scripts/minimart_sync.sh --grant-args
```

Expected: the file listed; `overrides file ...: OK`; and two lines `allow_cols=` and
`deny_cols=` (they list the `exclude-column` and `allow-column` entries once you add
some). An error names the line (`overrides file ... line 3: unknown directive ...`).

After every change to the file, in this order (each step is a block from this
runbook):

1. `nano minimart_sync_overrides.conf` (or `vi`), then the block above to check it.
2. **If you used `exclude-column` or `allow-column`:** run 2.2 again (it passes the
   file's entries to the grants file). `exclude` of a whole table and `snapshot`,
   `incremental`, `string-column` do not need it.
3. `scripts/minimart_sync.sh --print` (5.2): the tables the change affects show
   `DIFFERENT` or `new` in `VS_STORED_PLAN` and the lists reflect your overrides.
4. `scripts/minimart_sync.sh --init` (5.1) adopts it (a second `--print` now says
   `same`).
5. Continue with 5.4 (first load), or, if the mirror already has data, nothing more:
   the next sync run (or 5.4) reloads the changed tables in full by itself.

Between step 2 and step 4 a cron run may log `SKIPPED <table>: schema drift` for the
table whose grants changed (the privilege change counts as drift until `--init`
adopts it): harmless, it only means that table waits a few minutes. The grants step
prints a `WARNING` for an `exclude-column` / `allow-column` entry that matches no
column.

### 5.4 First load (everything, once)

```bash
cd /opt/purchasing_data
scripts/minimart_sync.sh --full; echo "exit=$?"
```

Expected: one line per table as it finishes, then the summary, then `exit=0`:

```
2026-10-02 14:05:02 +0800 [full] table <table> (snapshot, full: no successful run of the current plan) OK in 0s
2026-10-02 14:05:02 +0800 [full] table <table> (incremental_updated, full: no successful run of the current plan) OK in 1s
...
2026-10-02 14:05:09 +0800 [full] OK in 7s: <N> tables (<N> loaded in full); newest watermark 2026-10-02 06:05:02.013 UTC
exit=0
```

Tables are independent: one failing table prints `FAILED <table> after Ns; its
watermark was not advanced: <message>` and the run ends with `PARTIAL: ... not synced:
<table>` and exit 1 while all the others are loaded. Read the message (8.2 explains
the common ones) and either fix it or paste it.

If 0.4 showed a table above a few million rows, this can take minutes. Run it in the
background so a dropped SSH session does not kill it (the script is safe to run
again and the lock keeps a second copy out), then watch the log:

```bash
cd /opt/purchasing_data
nohup scripts/minimart_sync.sh --full > /root/minimart_full.out 2>&1 &
sleep 5; tail -n 5 /var/log/minimart-ch-sync.log
```

Repeat the `tail` until the line `[full] OK in ...` or `PARTIAL` appears. A single
table that needs more than about 14 minutes hits the per-call limit; see 8.7.

### 5.5 Verify against Postgres

```bash
cd /opt/purchasing_data
scripts/minimart_sync.sh --verify; echo "exit=$?"
```

Expected: a table (`TABLE METRIC POSTGRES CLICKHOUSE RESULT`), every `result` =
`ok`, then two short lists (`sensitive columns that are NOT mirrored`: one line per
secret column, each `(not readable by minimart_ro)`), the line
`[verify] verify: OK (<n> checks over <N> tables, Postgres and ClickHouse agree, no schema drift)`
and `exit=0`:

```
== <N> mirrored tables, Postgres vs ClickHouse ==
TABLE     METRIC               POSTGRES                    CLICKHOUSE                  RESULT
<table>   rows                 <n>                         <n>                         ok
<table>   sum(<numeric col>)   <value>                     <value>                     ok
<table>   max(<time col>)      2026-09-30 11:02:44.123456  2026-09-30 11:02:44.123456  ok
<table>   content hash         <number>                    <number>                    ok
```

Per table: the row count, the sum of every numeric column (floating-point columns
may differ in the last digits and are compared with a tolerance), the maximum of
every date and timestamp column, and a content hash of every mirrored column (up to
1,000,000 rows per table). Both sides are computed by ClickHouse from the same
conversion, one live from Postgres and one from the copy. The source is live: if the
app writes between the sync and the verify, a count can differ by a few rows for an
`incremental` table: run `scripts/minimart_sync.sh` (the normal run) and verify again
before calling it a mismatch.

**STOP** on any `MISMATCH` that survives a second sync + verify, `(error)` in a row, a
section "SCHEMA DRIFT" or "tables with no successful sync" (paste the output). The
mirror is a copy, so nothing is damaged. To start over:
`scripts/minimart_sync.sh --init && scripts/minimart_sync.sh --full`; to remove
everything, 7.2.

### 5.6 An incremental run must change nothing; nothing stays connected

```bash
cd /opt/purchasing_data
chq() { docker exec procurement_clickhouse sh -c 'exec clickhouse-client --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" "$@"' chq "$@"; }
pgq() { docker exec -e PGOPTIONS='-c default_transaction_read_only=on' mmi-postgres psql -U postgres -X -v ON_ERROR_STOP=1 "$@"; }
scripts/minimart_sync.sh; echo "exit=$?"
scripts/minimart_sync.sh --verify > /root/minimart_verify_last.txt; echo "verify exit=$?"
tail -n 1 /var/log/minimart-ch-sync.log
chq --query "SELECT countIf(startsWith(name, '_new_') OR startsWith(name, '_src_')) AS leftover_tables, countIf(NOT startsWith(name, '_')) AS mirror_tables, countIf(startsWith(name, '_') AND NOT startsWith(name, '_new_') AND NOT startsWith(name, '_src_')) AS state_tables FROM system.tables WHERE database = 'minimart'"
pgq -Atc "select count(*) || ' sessions of minimart_ro' from pg_stat_activity where usename = 'minimart_ro'"
```

Expected: `... [incremental] OK in Ns: <N> tables (0 loaded in full); newest watermark ... UTC`
and `exit=0`; `verify exit=0` and the log's last line `[verify] verify: OK (...)` (the
verify's own table went to `/root/minimart_verify_last.txt`); `0  <N>  4`
(no leftover helper tables, the mirror tables, and the four state tables `_sync_state`,
`_plan_current`, `_plan`, `_plan_cols`); and `0 sessions of minimart_ro` (a cron run
at that moment can make it 1: repeat). A `--verify` that prints "another run holds
the lock" and exits 1 means a run was in progress: wait a minute and repeat.

**STOP** on a non-zero exit, a `MISMATCH`, leftover tables, or sessions that do not
go back to 0 after a minute. The mirror is a copy; paste the output.

---

## Phase 6 - Every 15 minutes, by cron

The procurement sync runs at :00/:15/:30/:45 and the hauling one at :07/:22/:37/:52.
This one runs at :03/:18/:33/:48 so none of the three starts together on the
0.5-core ClickHouse.

### 6.1 Install cron and log rotation

Only installs if the verify in 5.5 still passes.

Two lines go into the cron file: the normal sync every 15 minutes, and a **nightly
full rebuild at 04:42 followed by a verify** (hauling's is at 04:12). The incremental
runs never see rows deleted in an `incremental_*` table, or updates to an
`incremental_created` table; the nightly full run repairs both, and the verify line in
the log shows whether the mirror matches Postgres afterwards. The two commands are
separated by `;` (not `&&`) on purpose: the verify must run even if the full run
reports a partial failure.

```bash
cd /opt/purchasing_data
if scripts/minimart_sync.sh --verify >/dev/null 2>&1; then
cat > /etc/cron.d/minimart-ch-sync <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
3,18,33,48 * * * * root /opt/purchasing_data/scripts/minimart_sync.sh >> /var/log/minimart-ch-sync.log 2>&1
42 4 * * * root /opt/purchasing_data/scripts/minimart_sync.sh --full >> /var/log/minimart-ch-sync.log 2>&1 ; /opt/purchasing_data/scripts/minimart_sync.sh --verify >> /var/log/minimart-ch-sync.log 2>&1
EOF
cat > /etc/logrotate.d/minimart-ch-sync <<'EOF'
/var/log/minimart-ch-sync.log {
    monthly
    rotate 6
    compress
    missingok
    notifempty
}
EOF
chmod 644 /etc/cron.d/minimart-ch-sync /etc/logrotate.d/minimart-ch-sync
echo "installed"
else
echo "NOT INSTALLED: verify failed, repeat 5.4 and 5.5 first"
fi
ls -l /etc/cron.d/minimart-ch-sync /etc/logrotate.d/minimart-ch-sync
logrotate -d /etc/logrotate.d/minimart-ch-sync 2>&1 | grep -iE 'error|considering'
```

Expected: `installed`, both files listed (`-rw-r--r-- 1 root root`), and a
`considering log /var/log/minimart-ch-sync.log` line from the logrotate dry run
(`-d` rotates nothing).

### 6.2 Is cron alive?

```bash
cd /opt/purchasing_data
systemctl is-active crond
cat /etc/cron.d/minimart-ch-sync
ls /etc/cron.d/
```

Expected: `active`, the four lines of the file (two settings and the two jobs) and the
three sync files (`procurement-ch-sync` or similar, `hauling-ch-sync`,
`minimart-ch-sync`). cron reads new files in `/etc/cron.d` by itself; no restart is
needed.

### 6.3 Twenty minutes later

```bash
cd /opt/purchasing_data
tail -n 8 /var/log/minimart-ch-sync.log
grep minimart-ch-sync /var/log/cron | tail -n 3
tail -n 2 /var/log/procurement-ch-sync.log /var/log/hauling-ch-sync.log
scripts/minimart_sync.sh --verify > /root/minimart_verify_last.txt; echo "verify exit=$?"
tail -n 1 /var/log/minimart-ch-sync.log
```

Expected: `[incremental] OK` lines at :03/:18/:33/:48 (one or two since 6.1); the same
times in `/var/log/cron`; procurement's and hauling's `[incremental] OK` still running;
`verify exit=0` and the log's last line `[verify] verify: OK`.

**STOP** if no minimart line appeared after 20 minutes, or a line says `FAILED` or
`PARTIAL`. The cause is in that log line (paste it). Remove the cron file with 7.1 if
it keeps failing; the other syncs are independent and unaffected.

### 6.4 The next morning (after 04:42)

```bash
cd /opt/purchasing_data
grep -E '\[full\] OK|\[full\] PARTIAL|\[verify\]' /var/log/minimart-ch-sync.log | tail -n 4
```

Expected: a `[full] OK in ...` line and a `[verify] verify: OK` line stamped around
04:42. If the verify line says `problem(s)`, run `scripts/minimart_sync.sh --verify` by
hand and paste the table (a `DRIFT` section means 8.3).

Done. The mirror follows minimart within 15 minutes, and is checked against Postgres
every night.

---

## Phase 7 - Rollback (only if needed)

Each step stands alone; you can stop after any of them. 7.1 only pauses the mirror
(the copy stays). 7.2 removes the copy. 7.3 removes the password and the source
connection from the ClickHouse container. 7.4 removes the grants. The repository files
can stay: without the cron file and the `.env` value they do nothing. Nothing in
`procurement`, `hauling` or the minimart tables is touched by any of this.

### 7.1 Stop the sync

```bash
cd /opt/purchasing_data
rm -f /etc/cron.d/minimart-ch-sync /etc/logrotate.d/minimart-ch-sync
flock -w 120 /var/lock/minimart-ch-sync.lock true && echo "no sync running"
[ ! -e /etc/cron.d/minimart-ch-sync ] && echo "cron file removed"
```

Expected: `no sync running` (a run in progress is waited for, up to 2 minutes) and
`cron file removed`.

### 7.2 Drop the ClickHouse database `minimart`

This is safe: it holds only a copy of Postgres data, and the sync can rebuild it (5.1,
5.4). The "never DROP in ClickHouse" rule applies to the **`procurement`** and
**`hauling`** databases, which this command does not touch: it names `minimart`
literally, and the guard refuses to run unless that database looks like the mirror
(it has the state tables `_plan_current` and `_sync_state`).

```bash
cd /opt/purchasing_data
chq() { docker exec procurement_clickhouse sh -c 'exec clickhouse-client --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" "$@"' chq "$@"; }
DB=minimart
if [ "$DB" = minimart ] && [ "$(chq --query "SELECT count() FROM system.tables WHERE database = 'minimart' AND name IN ('_plan_current', '_sync_state')")" = 2 ]; then
  chq --query "DROP DATABASE minimart SYNC"
else
  echo "NOT DROPPED: no ClickHouse database 'minimart' with the state tables _plan_current and _sync_state was found"
fi
chq --query "SELECT name FROM system.databases WHERE name NOT IN ('INFORMATION_SCHEMA','information_schema') ORDER BY name"
chq --query "SELECT database, count() AS tables FROM system.tables WHERE database IN ('procurement', 'hauling', 'minimart') GROUP BY database ORDER BY database" | diff /root/minimart_ch_before.txt - && echo "procurement and hauling table counts are as before"
```

Expected: the database list is `default`, `hauling`, `procurement`, `system` (no
`minimart`) and `procurement and hauling table counts are as before`.

### 7.3 Remove the password from the ClickHouse container

The simple version (recommended): remove only the `.env` value. The compose file
keeps its (now empty) variable and the read-only mount of the XML file, both inert:
the named collection `pg_minimart` then holds an empty password and nothing uses it.

```bash
cd /opt/purchasing_data
cp -p .env /root/env_before_minimart_rollback && chmod 600 /root/env_before_minimart_rollback
sed -i '/^MINIMART_RO_PASSWORD=/d' .env
grep -c '^MINIMART_RO_PASSWORD=' .env
docker compose up -d --force-recreate --no-deps clickhouse
for i in $(seq 1 30); do s=$(docker inspect -f '{{.State.Health.Status}}' procurement_clickhouse); [ "$s" = healthy ] && break; sleep 3; done; echo "$s"
```

Expected: `0`, then `healthy`. The ClickHouse container restarting also closes the
connections it held to Postgres as `minimart_ro`. (Do this at a quiet minute: see 3.1.)

The complete version (optional): also take the two lines out of `docker-compose.yml`,
which makes the file differ from git. A later `git pull` that changes
`docker-compose.yml` then needs `git checkout docker-compose.yml` first (which brings
the lines back).

```bash
cd /opt/purchasing_data
cp -p docker-compose.yml /root/docker-compose.before_minimart_rollback.yml
sed -i -e '/MINIMART_RO_PASSWORD=/d' -e '/50-pg-minimart\.xml/d' docker-compose.yml
grep -c -i minimart docker-compose.yml
docker compose config --quiet && echo "compose OK" && docker compose up -d --force-recreate --no-deps clickhouse
```

Expected: a count of the remaining comment lines that mention minimart (harmless),
`compose OK`, and the container recreated. Undo: copy the saved file back.

### 7.4 Remove the Postgres grants

Revokes what 2.2 granted, in the `minimart` database only, and ends the role's sessions.
It does **not** drop the role (it belongs to the migration's `db/minimart_setup.sql`)
and leaves its `CONNECT` and schema `USAGE`, which that file also grants. It needs no
change to any table.

```bash
cd /opt/purchasing_data
if [ "$(docker exec mmi-postgres psql -U postgres -XAtc "select count(*) from pg_roles where rolname = 'minimart_ro'")" = 1 ]; then
docker exec -i mmi-postgres psql -U postgres -X -v ON_ERROR_STOP=1 -d minimart <<'EOF'
SELECT count(pg_terminate_backend(pid)) AS sessions_ended FROM pg_stat_activity WHERE usename = 'minimart_ro' AND pid <> pg_backend_pid();
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM minimart_ro;
EOF
echo "exit=$?"
else
echo "NOT RUN: there is no role minimart_ro"
fi
docker exec mmi-postgres psql -U postgres -XAt -d minimart -c "select count(*) || ' tables readable by minimart_ro' from pg_class c where c.relnamespace = 'public'::regnamespace and c.relkind in ('r','p','v','m') and (has_table_privilege('minimart_ro', c.oid, 'SELECT') or has_any_column_privilege('minimart_ro', c.oid, 'SELECT'))"
```

Expected: `sessions_ended` with a number (0 or a few: ClickHouse sessions were still open),
`REVOKE`, `exit=0` and `0 tables readable by minimart_ro`. (`REVOKE ALL ON ALL TABLES`
also removes column-level grants.)

Prove minimart is back to its original state (needs the files from 0.6):

```bash
cd /opt/purchasing_data
if [ -s /root/minimart_fp_before.txt ] && [ -s /root/minimart_fp.sql ]; then
  docker exec -i -e PGOPTIONS='-c default_transaction_read_only=on' mmi-postgres psql -U postgres -X -At -v ON_ERROR_STOP=1 -d minimart < /root/minimart_fp.sql > /root/minimart_fp_after_rollback.txt
  diff /root/minimart_fp_before.txt /root/minimart_fp_after_rollback.txt && echo "IDENTICAL to the picture taken in 0.6"
fi
```

To stop using the code on the server too (optional): nothing to do, the new files are
inert. Do not `git checkout` an old commit just for this; it would leave the repository
on a detached HEAD for the next deploy.

---

## Phase 8 - Operations

### 8.1 The morning check (one block)

```bash
cd /opt/purchasing_data
echo "--- last runs"; grep -E '\[(incremental|full)\] (OK|PARTIAL)|\[verify\]' /var/log/minimart-ch-sync.log | tail -n 6
echo "--- problems today"; grep "^$(date +%F)" /var/log/minimart-ch-sync.log | grep -E 'FAILED|PARTIAL|SKIPPED|DRIFT|WARNING' | tail -n 10
echo "--- verify now"; scripts/minimart_sync.sh --verify > /root/minimart_verify_last.txt; echo "verify exit=$?"; grep -vE ' ok$' /root/minimart_verify_last.txt; tail -n 1 /var/log/minimart-ch-sync.log
```

Expected: `[incremental] OK` lines from the last quarter hours, last night's `[full] OK`
and `[verify] verify: OK`; under "problems today" nothing; and `verify exit=0` with only the headings and the "sensitive columns that are NOT
mirrored" list from the verify file, and a last log line `[verify] verify: OK`. A `FAILED`, `PARTIAL`, `SKIPPED` or `DRIFT` line: 8.2 and 8.3.

### 8.2 Reading the log

`/var/log/minimart-ch-sync.log`, one line per event, `[mode]` after the time:

| Line | Meaning | What to do |
|---|---|---|
| `[incremental] OK in 3s: <N> tables (0 loaded in full); newest watermark ...` | Normal run. `(k loaded in full)` is a table (re)loaded completely: first run after `--init` or a changed plan | nothing |
| `[full] table <t> (...) OK in 5s` and `[full] OK in ...` | A full rebuild finished | nothing |
| `[verify] verify: OK (...)` | Postgres and the mirror agree | nothing |
| `[verify] verify: <n> problem(s) ...` | A mismatch or drift | run `--verify` by hand; 8.3 |
| `another run holds the lock; skipping this run` | A previous run (usually the nightly full) is still going; cron exit 0 | nothing, unless it repeats for hours |
| `FAILED <t> after Ns; its watermark was not advanced: <message>` | One table failed; its old copy is intact and the next run retries; other tables are unaffected | read the message: 8.7 (timeout, infinity, conversion), `password authentication failed` (2.1 + 3.1), `permission denied` (2.2) |
| `PARTIAL: <n> tables ok, <f> failed, <s> skipped for drift ...; not synced: <list>` | The run's summary when anything failed; exit 1 | the list names the tables |
| `SKIPPED <t>: schema drift` | Postgres changed that table incompatibly; it is not synced until `--init` | 8.3 |
| `DRIFT [kind] <table>.<column>: ...` | Schema drift report, repeated every run until fixed | 8.3 |
| `FAILED: ... not initialised ... run: scripts/minimart_sync.sh --init` | The ClickHouse database `minimart` is missing or empty | 5.1 and 5.4 |
| `FAILED: cannot reach ClickHouse` | Container down or restarting | `docker ps`, wait a minute |
| `WARNING: overrides file invalid, schema drift not checked: ...` | A syntax error in the overrides file | `scripts/minimart_gen_schema.sh --check-overrides` |

(The lines always go to the log. A run you start by hand in the terminal also prints
them on the screen; when its output is redirected or piped, as in 5.6, they do not,
so read the log's last line.)

### 8.3 Schema drift: Postgres changed

The sync compares the live catalog with the stored plan on **every** run. Nothing
corrupts and other tables keep syncing. `scripts/minimart_sync.sh --verify` lists the
findings in the section "SCHEMA DRIFT" and exits 1; the sync logs them as `DRIFT
[kind]` lines. For each kind:

| Kind | What happened | Effect until fixed | Next commands |
|---|---|---|---|
| `new_table` | A new table in `public` | not mirrored; detail says whether `minimart_ro` can read it | 2.2 (the new table is not readable until the grants are re-run), then 5.1 (`--init`). The first run after that loads it in full by itself |
| `new_column` | A column was added to a mirrored table | the column is not copied; the table keeps syncing | 2.2 (matters when the table has column-level grants: a new column stays unreadable until then; a secret-looking name is then withheld), then 5.1. The table is reloaded in full by the next run |
| `sensitive_readable` | `minimart_ro` can read a column whose name looks secret (typically a new column on a table with a table-level grant) | the column is **not** mirrored: the sync never names it. But Postgres would let `minimart_ro` read it | 2.2 immediately (this withholds it), then 5.1 (the privilege change shows as `changed_column` until `--init` adopts it) |
| `changed_column` | A column's type, nullability, key or readability changed | that table is **skipped** (`SKIPPED` lines, run exits `PARTIAL`) | 5.1; the next run reloads it in full |
| `dropped_column` | A column was dropped | that table is **skipped** | 5.1; the next run reloads it in full |
| `dropped_table` | A mirrored table no longer exists in Postgres | skipped; its mirror table stays | 5.1; then `--verify` lists it under "mirror tables that are not in the plan": drop it by hand once you are sure, `docker exec procurement_clickhouse sh -c 'clickhouse-client --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" --query "DROP TABLE minimart.\`<table>\`"'` |

What it looks like (examples from a test database), in the log and in `--verify`:

```
2026-10-02 10:36:46 +0800 [incremental] DRIFT [new_column] products.zzz: added in Postgres, not mirrored until --init is re-run
2026-10-02 10:37:56 +0800 [incremental] SKIPPED products: schema drift (see DRIFT lines); run scripts/minimart_sync.sh --init to adopt it
2026-10-02 10:37:57 +0800 [incremental] PARTIAL: 11 tables ok, 0 failed, 1 skipped for drift in 2s; not synced: products(drift)

== SCHEMA DRIFT: Postgres changed since the plan was generated ==
  dropped_column     products.margin  dropped in Postgres: this table is skipped until --init is re-run
```

Standard order after a schema change in minimart: 2.2 (grants; always safe), 5.1
(`--init`), 5.2 (look at `VS_STORED_PLAN` and the strategy), then `scripts/minimart_sync.sh`
(the changed tables load in full by themselves) or `--full`, then `--verify`. A
`DRIFT` line does not need to be handled at 3 a.m.: the only cost of waiting is that a
skipped table is not updated.

### 8.4 Adding or excluding a table or column

There is no list of tables to edit. A new table is picked up by 8.3 (`new_table`).
To leave something out or to override the strategy: the overrides file in 5.3 (`exclude
<table>`, `exclude-column <table>.<column>`, `snapshot <table>`, `incremental <table>
<column> [updated|created]`, `allow-column`, `string-column`), then, in order: the
grants step 2.2 (only for `exclude-column` / `allow-column`), `--init` (5.1), `--print`
(5.2). To bring back an excluded column, remove its line (or use `allow-column`) and
repeat. Excluding a table after it was mirrored leaves its ClickHouse copy behind
(`--verify` lists it as "not in the plan"): drop it as in 8.3 when you want it gone.

Before opening a secret-looking column with `allow-column`, look at what it holds:
the grants file then makes it readable to `minimart_ro` and the mirror copies it.

### 8.5 Rotating the password

Change `MINIMART_RO_PASSWORD` in `.env`, set it on the role (2.1), recreate the
ClickHouse container (3.1), prove it (4.1). The steps in this order:

```bash
cd /opt/purchasing_data
cp -p .env /root/env_before_minimart_rotate_$(date +%Y%m%d_%H%M%S)
sed -i '/^MINIMART_RO_PASSWORD=/d' .env
[ -z "$(tail -c1 .env)" ] || echo >> .env
echo "MINIMART_RO_PASSWORD=$(openssl rand -hex 24)" >> .env
chmod 600 .env
grep -E '^MINIMART_RO_PASSWORD=' .env | awk -F= '{print $1, length($2)}'
```

Expected: `MINIMART_RO_PASSWORD 48`. Then 2.1 and 3.1 straight away: between them every
sync run fails with `password authentication failed` (harmless: a failed run changes
nothing, and the next run after 3.1 catches up). The minimart app's own password is a
different one and is not touched.

### 8.6 What each strategy means for dashboard authors

The table `minimart._plan` says which strategy every table has:

```sql
SELECT table_name, strategy FROM minimart._plan
 WHERE plan_id = (SELECT argMax(plan_id, planned_at) FROM minimart._plan_current)
 ORDER BY table_name
```

- `snapshot`: the table holds exactly one copy of every row (it is replaced as a
  whole every 15 minutes, so updates and deletes are visible). Query it directly.
- `incremental_updated`: a `ReplacingMergeTree`. A changed row is sent again and the
  newest version replaces the old one on merge, so a row may briefly exist twice.
  **Use `FINAL`** (`SELECT ... FROM minimart.<t> FINAL`) or aggregate with
  `uniqExact(<key>)`. A row deleted in Postgres stays in the mirror until the
  nightly `--full` (04:42).
- `incremental_created`: for append-only tables. A row is only inserted when its key
  is not already in the mirror, so each row exists once physically; `FINAL` is
  harmless but not needed. An update to an old row is not seen until the nightly
  `--full`.
- Everything is a copy refreshed every 15 minutes (a snapshot table can be up to
  15 minutes old, an incremental one up to 15 minutes plus the time of a run).
- A dashboard must not use `procurement_user` (it can write and sees procurement). Use
  a separate ClickHouse user that can only read the mirror, granted
  `GRANT SELECT ON minimart.*`; see `RUNBOOK_HAULING_MIRROR.md` section 8.4 for the
  pattern (users file or SQL, read-only profile, loopback ports and an SSH tunnel).
  Never grant it `procurement` or `hauling`.

### 8.7 Known limits

- **Types.** `integer`/`bigint`/`smallint`, `real`/`double`, `uuid`, `boolean`,
  `numeric(p,s)` (as an exact `Decimal(p,s)`), `date` (as `Date32`), text types and
  enums (as `LowCardinality(String)`) are mapped one to one. `json`/`jsonb`,
  `time`, `interval`, `inet`, `money`, ranges, geometric types, extension types and
  anything unknown are copied as `String` (the Postgres text form), so an unexpected
  type never breaks the sync. Arrays of numbers, text and uuid become ClickHouse
  arrays; **a NULL array becomes an empty array** (ClickHouse arrays cannot be NULL).
- **Unconstrained `numeric`** (no precision, e.g. `weight numeric`) becomes
  **`Float64`**, the nearest double: it can lose digits beyond 15-17 significant
  figures. `--verify` compares such sums with a small relative tolerance.
- **`bytea`** (binary) columns are excluded by default (they are not analytic data and
  can be huge). `allow-column <table>.<column>` mirrors one as hex text.
- **Timestamps** are `DateTime64(6, 'UTC')`: microseconds are kept. A `timestamptz`
  is the real UTC instant. A **naive `timestamp`** (no time zone) keeps its wall clock
  and is **labelled UTC**, whatever zone the app meant by it. If the app stores local
  times in naive columns, ClickHouse shows them as if they were UTC (the same trap as
  procurement). **Compare against the migration's inspect report** (the section
  `== Time columns ...` of `/root/minimart_inspect.txt`, made by
  `scripts/minimart_migrate.sh --inspect` in migration runbook step 0.6): columns reported as local wall-clock stored in a `timestamp` column need a
  a correction in the dashboard query: ask Claude for the exact expression for your
  zone, since the label `UTC` is wrong for those columns.
- **`infinity` / `-infinity`** timestamps or dates cannot be converted: the run
  fails for that **table only** (`FAILED <t> ...`), all others continue, and its old
  copy stays. Fix it with `string-column <table>.<column>` (5.3), then `--init`.
- **Hard deletes** in `incremental_*` tables arrive with the nightly `--full`;
  **updates** to `incremental_created` tables too (8.6).
- **Per-table limits.** A table must be read within the 120 s `statement_timeout` of
  `minimart_ro` and within the per-call limit of the script (900 s, 870 s of it for
  the statement). For a table too big for that, tell Claude: the real fix is
  raising `statement_timeout` on the Postgres role, which is a change to the
  migration's setup file as well (`db/minimart_setup.sql` sets 120 s and would put it
  back on every re-run). `MINIMART_SYNC_TIMEOUT=3600 scripts/minimart_sync.sh --full`
  lifts only the script's own limit, for one manual run.
- **Many tables.** The source connection is opened per table and closed before the
  next one, so the 20-connection limit of `minimart_ro` is no limit on the number of
  tables (see the connection budget at the top). A schema with views, other schemas or
  partitions: only ordinary tables of `public` are mirrored (partitioned tables as one
  table); the grants step prints a `WARNING` naming what it left out.
