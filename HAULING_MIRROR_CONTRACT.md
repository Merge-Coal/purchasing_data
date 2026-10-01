# Hauling mirror — contract between the three workers

Goal: a faithful, continuously refreshed **mirror of the `hauling_tracker` Postgres
database inside the existing ClickHouse** (container `procurement_clickhouse`), in a
**separate ClickHouse database named `hauling`**, for later analytics dashboards.
No dashboard work in this task.

```
mmi-postgres / hauling_tracker  ──(hauling_ro, SELECT only)──▶  ClickHouse database `hauling`
   (Calvin's live system)             via named collection `pg_hauling`        (rebuildable copy)
```

## Hard safety rules (hauling_tracker is another team's LIVE system)
1. Nothing in this task may write to, alter, lock for more than a moment, or restart
   anything belonging to `hauling_tracker`, the `mmi-postgres` container, or other roles.
   The ONLY change allowed on the Postgres side: create role `hauling_ro` and grant it
   `CONNECT`, `USAGE` on schema `public`, and `SELECT` on an explicit list of tables.
2. No `ALTER DEFAULT PRIVILEGES`, no grants to PUBLIC, no changes to existing grants,
   no `ALTER SYSTEM`, no `pg_hba.conf` edits, no schema/data changes in hauling_tracker.
3. Never mirror secrets: the `sessions` table is excluded; `users` (if mirrored later)
   must exclude password hash columns via a column-level grant and column list.
4. The mirror is rebuildable from Postgres, so dropping the ClickHouse `hauling`
   database is the rollback. The ClickHouse `procurement` database must never be
   touched by hauling code (different database, different sync script, different state).
5. Existing procurement behaviour must not change: `scripts/ch_sync.sh`,
   `db/ch_sync.sql`, `db/postgres_*.sql`, the app, and its cron stay as they are.

## Fixed names (do not rename)
| Thing | Name |
|---|---|
| Postgres source database | `hauling_tracker` (on `mmi-postgres`, same Docker network `postgres_net` / compose network `mmi_pg` as procurement) |
| Postgres read-only role | `hauling_ro` (LOGIN, password from env `HAULING_RO_PASSWORD`, min 16 chars) |
| ClickHouse database | `hauling` |
| ClickHouse named collection | `pg_hauling` (file `db/clickhouse-config.d/40-pg-hauling.xml`, password `from_env="HAULING_RO_PASSWORD"`) |
| Sync script | `scripts/hauling_sync.sh` with modes: *(none)* incremental, `--full`, `--init`, `--verify`, `--print` |
| Sync SQL template | `db/hauling_sync.sql` |
| ClickHouse schema (idempotent) | `db/hauling_ch_schema.sql`, applied by `scripts/hauling_sync.sh --init` |
| Sync state table | `hauling._sync_state` |
| Log / lock | `/var/log/hauling-ch-sync.log`, `/var/lock/hauling-ch-sync.lock` |
| Cron file | `/etc/cron.d/hauling-ch-sync` (every 15 min) |
| Postgres setup script | `db/hauling_ro_setup.sql` — run as `postgres` superuser: `{ printf '\\set ro_password %s\n' "$PW"; cat db/hauling_ro_setup.sql; } \| docker exec -i mmi-postgres psql -U postgres -X`; optional `-v dbname=...` (default `hauling_tracker`) so it can be tested against a local database; it switches database itself with `\c`. Ends with a small verification table. Idempotent. |
| Runbook | `RUNBOOK_HAULING_MIRROR.md` |
| Local test databases | Postgres `hauling_dev` (stand-in for hauling_tracker), ClickHouse database `hauling` in a local scratch server |

## Tables in scope (phase 1)
Schemas for these five are known (see `test/hauling/pg_schema.sql`, a faithful stand-in):
`trips`, `barge_loadings`, `scale_readings_pending`, `station_heartbeat`, `error_log`.

Phase 2 (schemas not yet seen — DO NOT GUESS their columns): `audit_log`, `users`
(without password hash), `station_request_log`. `sessions` and `schema_migrations`
are never mirrored. Everything must be **table-driven** so adding a table later is a
small, documented change (schema entry + sync entry + grant line + verify entry).

## Sync strategy per table
| Table | Behaviour in Postgres | Strategy |
|---|---|---|
| `trips` | no created_at/updated_at; rows are edited as a trip moves through checkpoints; deletes possible | **Snapshot swap** every run: load into `hauling.trips_new`, then `EXCHANGE TABLES`, then drop the old one. Atomic; a failed load leaves the live mirror untouched. Handles updates and deletes. |
| `barge_loadings` | tiny, may be edited | snapshot swap |
| `scale_readings_pending` | a transient queue (rows come and go) | snapshot swap |
| `error_log` | append-only, `created_at` | incremental: `created_at > watermark − 1 h overlap`; ReplacingMergeTree ORDER BY `error_id` so re-sent rows collapse |
| `station_heartbeat` | append-only bigserial `id`, `received_at`; currently EMPTY and may grow large | incremental by `received_at` with overlap, ReplacingMergeTree ORDER BY `id`; must work on an empty table |

Run safely re-runnable at any time; a failed run must not advance the watermark;
`flock` prevents overlapping runs; every client call has a timeout; the ClickHouse
login comes from the container env, never echoed.

## Type mapping Postgres → ClickHouse
`uuid`→`UUID`; `date`→`Date`; `timestamptz`→`DateTime64(3,'UTC')` (the read-only role
is pinned to `timezone=UTC`, `datestyle='ISO, YMD'` because ClickHouse's `postgresql()`
reader drops the offset and reads the wall-clock text — same trick as procurement,
see `db/postgres_setup.sql` and `db/ch_sync.sql`); enums→`LowCardinality(String)`;
`text`→`String`; `integer`→`Int32`; `bigint`→`Int64`; `boolean`→`Bool`; unconstrained
`numeric`→`Float64` (cast with `toFloat64`); `jsonb`→`String` (raw JSON text).
Nullable in Postgres ⇒ `Nullable(...)` in ClickHouse. Column names identical to Postgres.

## Verification the sync must provide (`--verify`)
Per table: row counts PG vs CH; for `trips` also `sum(netto_site_kg)`, `sum(netto_jetty_kg)`
and count by `status`; for `barge_loadings` `sum(loading_qty_kg)`; for `error_log`/
`station_heartbeat` max timestamp. Exit non-zero on any mismatch. Production reference
values (from 2026-10-01, hauling paused so they should not move): trips 6474
(6473 completed + 1 in_transit), netto_jetty ≈ 214132 t, netto_site ≈ 213678 t,
barge_loadings 16, error_log 6570, scale_readings_pending 4, station_heartbeat 0.

## Server facts
Production: RHEL-family host, Docker + Compose v2, run as root; the user pastes commands
by hand (cannot SSH from here). Past mistakes to design the runbook around: the user
repeatedly pasted old terminal output back into the shell; a fresh SSH session loses
shell helper functions and the working directory. So **every runbook block must be
self-contained** (`cd /opt/purchasing_data` and any helper function defined at the top
of the block), commands only (no prompt text), small, with expected output and a
STOP rule; destructive steps are guarded by a precondition check.
Host timezone is Asia/Makassar; `mmi-postgres` has `PGTZ/TZ=Asia/Makassar` in its
container env, which `docker exec psql` inherits (network clients do not).

## Local test environment (this Mac)
PostgreSQL 14 (Homebrew, socket `/tmp`, current OS user is superuser, no password).
ClickHouse installed via `brew install clickhouse` (may still be downloading; check
`which clickhouse` and `/tmp/brew_clickhouse.log`). No Docker. Use the scratchpad
directory for scratch data/configs. Production is Postgres 16 / ClickHouse 24.8: avoid
Postgres 15+ only syntax; note any ClickHouse feature newer than 24.8.
