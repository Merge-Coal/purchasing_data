# Minimart — contract between the two lead agents

Two jobs on branch `minimart-migration` (branched from `hauling-mirror`, so the hauling files are available as the pattern to copy).
The owner of minimart is the user; nobody else's system is involved. No dashboard work.

```
OLD   minimart-postgres-1 (postgres:16-alpine, own container, port 5433 public)
        │  pg_dump / pg_restore  (Agent M)
        ▼
NEW   mmi-postgres / database `minimart`  ──(minimart_ro, SELECT only)──▶  ClickHouse database `minimart`  (Agent C)
```

## UNKNOWNS (no discovery output yet) — design around them, never guess
The schema of minimart is NOT known: table names, columns, sizes, extensions, the old
container's superuser/db names and the app's connection settings are all unknown. Therefore:
- Everything is **introspection-driven**: scripts read `information_schema` / `pg_catalog` of the live
  database at run time. No hard-coded table or column names in production scripts.
- Anything that needs a value from the server (old DB user/name, network, app env file) is read at
  run time from `docker inspect` / `docker exec ... printenv`, or is a clearly named variable at the top
  of the runbook block.
- The minimart app's compose/env live in `/opt/minimart` on the server, NOT in this repo. The runbook
  must show how to find how the app connects (a read-only block), then edit it with a guarded,
  backed-up change, with an exact rollback.
- Tests use a **stand-in schema you invent** in `test/minimart/` covering varied types (serial/identity,
  uuid, text, numeric(p,s), unconstrained numeric, timestamptz, timestamp, date, bool, jsonb, enums,
  arrays, bytea, FKs, a table with no primary key, a table with updated_at, an append-only table with
  created_at, a tiny lookup table, a sensitive-looking column such as password_hash/token). The tooling must
  survive all of them.

## Fixed names (do not rename)
| Thing | Name |
|---|---|
| Old container | `minimart-postgres-1` (read-only access only until cutover; NEVER delete it, only stop it at cutover) |
| Central server | `mmi-postgres` (never restart it, never alter other databases, roles, pg_hba or system settings) |
| New Postgres database | `minimart` |
| Roles | `minimart_owner` (NOLOGIN, owns objects), `minimart_app` (LOGIN, DML only), `minimart_ro` (LOGIN, SELECT only, `timezone=UTC`, `datestyle='ISO, YMD'`, read-only default, `statement_timeout` 120s, CONNECTION LIMIT 20) |
| Passwords | env `MINIMART_APP_PASSWORD`, `MINIMART_RO_PASSWORD`, min 16 chars, never echoed, never committed |
| Docker network | `postgres_net` (compose network name `mmi_pg`, env `MMI_PG_NETWORK`) as in procurement/hauling |
| ClickHouse database | `minimart` (in the existing container `procurement_clickhouse`) |
| ClickHouse named collection | `pg_minimart` (`db/clickhouse-config.d/50-pg-minimart.xml`, `from_env="MINIMART_RO_PASSWORD"`) |
| Mirror script | `scripts/minimart_sync.sh` modes: *(none)* incremental, `--full`, `--init`, `--verify`, `--print` |
| Mirror log / lock | `/var/log/minimart-ch-sync.log`, `/var/lock/minimart-ch-sync.lock` |
| Mirror cron | `/etc/cron.d/minimart-ch-sync`: minutes 3,18,33,48; nightly `42 4 * * *` full + verify |
| Backup | nightly `scripts/minimart_backup.sh` -> `/opt/backups/minimart/`, cron `/etc/cron.d/minimart-pg-backup` at 02:45, log `/var/log/minimart-pg-backup.log` ending in an `OK ...` line |
| Backup of old DB | before anything else: `/opt/backups/minimart/pre_migration_<ts>/` |

## Agent M — migrate the database to `mmi-postgres`
Owns (only these): `db/minimart_setup.sql`, `scripts/minimart_migrate.sh`, `scripts/minimart_backup.sh`,
`RUNBOOK_MINIMART_MIGRATION.md`, everything under `test/minimart/migrate/` and `test/minimart/stand_in_schema.sql` (shared stand-in; M writes it first, within the first steps, because C needs it).

Requirements:
1. Backup of the old DB (custom-format dump + plain schema dump + per-table counts) before anything.
2. `db/minimart_setup.sql`: idempotent; creates DB `minimart`, the three roles (owner/app/ro) with the settings above (the ro role is created here so ONE place defines roles; C's grants rely on it); app gets DML on all tables, USAGE+ALL on sequences; default privileges for the owner so future tables work; `ALTER DATABASE ... SET timezone` only if the discovery shows a local-time need (parameterised, default leave as is); ends with a verification table. Same stdin-`\set` password pattern as `db/postgres_setup.sql`.
3. `scripts/minimart_migrate.sh` modes: `--inspect` (read-only report of the old DB: tables, rows, sizes, extensions, sequences, large objects, roles, sensitive-looking columns, time-column kinds, who is connected), `--rehearse` (dump old -> restore into scratch DB `minimart_rehearsal` on mmi-postgres -> verify -> drop, prints timing), `--cutover` (guarded: requires app stopped = no non-admin connections on old DB, fresh dump, restore into `minimart`, fix ownership to `minimart_owner`, reset every sequence/identity above max, ANALYZE, verify), `--verify` (per-table row counts old vs new + checksums/sums on every numeric column + max of every timestamp column + sequence check; exit non-zero on mismatch), `--rollback-info` (prints exact manual rollback). The restore must not require extensions that mmi-postgres lacks: detect and stop before restoring.
4. Handle collation/encoding differences (Alpine vs Debian) and `--no-owner --no-acl`.
5. Timestamps: report (do not auto-fix) whether time columns look like UTC wall-clock stored in a local column, as happened in procurement; verification compares values byte-for-byte so the migration itself never shifts data.
6. Runbook (`RUNBOOK_MINIMART_MIGRATION.md`): phases 0 read-only discovery (how the app connects: compose/env under /opt/minimart, who is on port 5433), 1 backup, 2 rehearsal with timing, 3 cutover (stop app -> final dump -> restore -> verify -> edit the app's connection -> start -> browser test), 4 stop (not delete) old container, 5 close public port 5433 (user's call, separate, guarded), 6 add backup cron, 7 rollback (start old container, point app back; data written after cutover is lost — say so). Follow the runbook rules below.
7. `scripts/minimart_backup.sh` + cron/logrotate lines in the runbook, like `scripts/pg_backup.sh`.

## Agent C — mirror into ClickHouse database `minimart`
Owns (only these): `db/clickhouse-config.d/50-pg-minimart.xml`, `db/minimart_ch_schema.sql` (if any static part) , `db/minimart_sync.sql` (templates), `scripts/minimart_sync.sh`,
`scripts/minimart_gen_schema.sh` or `.py`/`.js` (the introspection generator), `RUNBOOK_MINIMART_MIRROR.md`, everything under `test/minimart/ch/`, plus the ONLY shared-file edits: `docker-compose.yml` (one env var `MINIMART_RO_PASSWORD` with `${...:-}` default + one read-only mount of the new XML on the clickhouse service), `.env.example`, `CLAUDE.md`, `CLICKHOUSE.md` (a short section each). M must not touch those four files.

Requirements:
1. Same architecture and safety rules as the hauling mirror (copy the pattern from `scripts/hauling_sync.sh`, `db/hauling_sync.sql`, `db/clickhouse-config.d/40-pg-hauling.xml`, `RUNBOOK_HAULING_MIRROR.md`, `test/hauling/`); read `HAULING_MIRROR_CONTRACT.md` for the type mapping and lessons (timestamptz offset dropped by `postgresql()` => ro role pinned UTC; numeric via `toFloat64(toString())`, etc.).
2. Because the schema is unknown, `--init` **introspects** the Postgres database through `minimart_ro` and generates the ClickHouse DDL and the per-table sync from the catalog; the generated result is printed (`--print`) for human review and stored in ClickHouse database state, not committed. Strategy chosen automatically per table with a documented rule: has primary key + `updated_at`-like column => incremental ReplacingMergeTree with version; has primary key + append-only `created_at`-like column => incremental with overlap; small tables (below a documented row threshold) and tables with no usable change column => snapshot swap via `EXCHANGE TABLES`; no primary key => snapshot swap with ORDER BY tuple(). Provide an override file (e.g. `/opt/purchasing_data/minimart_sync_overrides.conf`, optional) to force a table's strategy or exclude it.
3. **Sensitive columns:** columns whose names match a deny pattern (password, passwd, hash, token, secret, api_key, otp, pin, card) are excluded from the mirror automatically and listed in `--print`/`--verify`; the minimart_ro grants must be column-level for such tables (so ClickHouse can't read the secret even by mistake). Because `minimart_ro` is created by Agent M's setup, C ships `db/minimart_ro_grants.sql` (idempotent, generated/introspective: SELECT on all tables except it grants column lists for tables with sensitive columns) and runs it as superuser in the runbook. C owns that file too.
4. Enums, arrays, jsonb, bytea, numerics, intervals, unknown types: documented mapping with a safe fallback to `String` (cast `::text` on the Postgres side) so an unexpected type never breaks the sync.
5. `--verify`: introspective; per table row count PG vs CH, plus sum of every numeric column and max of every timestamp column; exit non-zero on mismatch. A schema drift (new table/column in Postgres) is detected and reported, with `--init` re-runnable to adopt it; drift must never silently corrupt the mirror or stop other tables.
6. Concurrency/safety: `flock`, timeouts on every client call, failed run does not advance state, password from container env never echoed, runs fine with zero rows.
7. Cron lines and the runbook: install, init, first full load, verify, morning check, rollback (`DROP DATABASE minimart` in ClickHouse + remove cron/config/mount), adding or excluding a table, what to do on schema drift.

## Hard safety rules (both)
1. Never touch procurement or hauling things: `scripts/ch_sync.sh`, `db/ch_sync.sql`, `db/postgres_*.sql`, `db/hauling_*`, `scripts/hauling_sync.sh`, `scripts/pg_backup.sh`, the app code, other crons. Do not edit files you do not own.
2. Never `docker compose down -v`, never DROP/TRUNCATE ClickHouse `procurement` or `hauling`, never restart `mmi-postgres`, never run anything against the production server (there is no access; all work is local).
3. Nothing may be pushed or committed by agents. The lead (me) commits at the end. Do NOT run `git add/commit/push/stash/checkout`.
4. Do not install packages system-wide; use the scratchpad for scratch data. Local tools: Postgres 14 (Homebrew, socket `/tmp`, OS user superuser, no password), ClickHouse 26.9 at `/opt/homebrew/bin/clickhouse`; official 24.8.14.39 binary may be downloaded into the scratchpad to test the production version. No Docker locally: tests must mock `docker exec` with a thin wrapper (see how `test/hauling/ch/run_sync_test.sh` does it) so the real scripts are executed unmodified.
5. Postgres 16 production: avoid syntax newer than what PG 14 + 16 both accept; ClickHouse production 24.8: avoid newer-only features, or document and gate them.

## Runbook rules (learned the hard way)
The user pastes commands by hand from code blocks and cannot SSH from here. They have pasted old output back into the shell, and fresh SSH sessions lose `cd` and shell helpers. So: every block self-contained (starts with `cd /opt/purchasing_data` and defines its helper functions), commands only (no prompt text, no `read`, no `exit`, no `set -e`), small, each with "Expected output" and a STOP rule, destructive steps guarded by a precondition check, secrets never printed. The user has ALREADY scheduled downtime for minimart, so the cutover phase is ready to run, but rehearsal comes first and its timing is reported.

## Jurisdiction
Each lead may spawn as many subagents as it judges useful (guideline 2-4 each; keep it proportionate), assign them disjoint files inside the lead's own file list, and is responsible for their work and for an internal QC pass (adversarial review plus running every test) before reporting. Leads must not edit each other's files. Agent M must write `test/minimart/stand_in_schema.sql` (+ optional `stand_in_seed.sql`) FIRST so Agent C can use it; if it does not exist yet when C needs it, C waits briefly (check every minute for up to ~10 minutes) rather than creating its own copy.

## Final report each lead returns
Files created/changed (full paths), how tests were run and the counts (PASS/FAIL), QC findings and what was fixed, anything the user must decide or paste from the server (list the exact read-only commands), known limits, and the exact order of runbook phases.
