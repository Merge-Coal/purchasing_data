# CLAUDE.md — PT Merge Mining Industri Procurement App

## Project Overview

Internal web-based procurement system for **PT Merge Mining Industri** that digitises the end-to-end purchasing workflow:

```
Requester submits PR → MD approves/rejects line items → Purchasing creates PO → GL CSV export
```

## Stack

| Layer | Technology |
|---|---|
| Runtime | Node.js |
| Framework | Express.js |
| Database (OLTP) | PostgreSQL 16 via `pg` — database `procurement` on the shared `mmi-postgres` container (PG 14+ locally) |
| Warehouse | ClickHouse 24.8 (`procurement_clickhouse`) — analytics only, fed from Postgres every 15 min by `scripts/ch_sync.sh` |
| Auth | `express-session` + `bcryptjs` + `connect-pg-simple` (sessions in the Postgres `session` table) |
| Search | Fuse.js (fuzzy, threshold 0.4) |
| CSV Export | `json2csv` |
| Frontend | Vanilla JS single-page app (`public/index.html`) — no framework |
| Fonts | Inter, Instrument Serif, JetBrains Mono |
| Design | Aurora design system — custom CSS tokens |

## Key Files

- `server.js` — Express server, all API routes, session setup
- `db.js` — Postgres pool and query helpers
- `public/index.html` — entire frontend (single file, vanilla JS)
- `db/postgres_schema.sql` — Postgres schema (source of truth); `db/postgres_setup.sql` — roles/database bootstrap
- `db/clickhouse_schema.sql` — warehouse schema; `db/ch_sync.sql` + `scripts/ch_sync.sh` — Postgres → ClickHouse sync
- `migrate_ch_to_pg.js` — one-time ClickHouse → Postgres migration (cutover)
- `scripts/pg_backup.sh` — nightly `pg_dump` of `procurement` → `/opt/backups/procurement/`
- `RUNBOOK_POSTGRES_CUTOVER.md` — production cutover, sync, backup and rollback procedure
- `ingest.py` — one-time CSV ingest script for item master

## Roles & Default Accounts

| Username | Password | Role |
|---|---|---|
| requester1 | merge2026 | Requester |
| purchasing1 | merge2026 | Purchasing |
| md1 | merge2026 | MD |
| admin1 | merge2026 | Admin |

Role is enforced server-side via session — no client-side switching.

## Data Model (key tables)

```
users           — id, username, password_hash, role, full_name
items           — item_id, name_en, name_cn, category, uom, department
pr              — pr_id, pr_number, requested_by, department, date_requested, status, notes, requester_id
pr_items        — pr_item_id, pr_id, item_id, qty, qty_requested, qty_approved, uom, est_unit_price, status, notes
approvals       — approval_id, pr_id, approved_by, action, timestamp, notes
po              — po_id, po_number, pr_id (nullable), vendor_name, date_created, status, total_amount
po_items        — po_item_id, po_id, pr_item_id, item_id, qty, uom, unit_price, total_price, vendor_name
gl_export_log   — log_id, po_id, export_date, filename
sessions        — managed by connect-pg-simple (Postgres `session` table)
```

Auto-generated IDs: `PR-YYYY-NNN`, `PO-YYYY-NNN`, `ITEM-NNNN`

## API Routes (summary)

| Method | Route | Role |
|---|---|---|
| POST | /api/auth/login | Public |
| POST | /api/auth/logout | Public |
| GET | /api/auth/me | Public |
| GET | /api/items | Auth |
| GET | /api/items/search?q= | Auth |
| POST | /api/items | Auth |
| GET | /api/pr | Auth |
| POST | /api/pr | Requester / Purchasing / Admin |
| GET | /api/pr/:id | Auth |
| POST | /api/pr/:id/items/:itemId/approve | MD / Admin |
| GET | /api/pr-items/approved | Purchasing / Admin |
| GET | /api/po | Auth |
| POST | /api/po | Purchasing / Admin |
| GET | /api/po/:id | Auth |

## GL Export

Removed (unused). The `gl_exports` table is kept for history only; nothing writes to it.

## Local Dev Setup

```bash
npm install
createdb procurement_dev
psql -v ON_ERROR_STOP=1 -d procurement_dev -f db/postgres_schema.sql
export PGDATABASE=procurement_dev SESSION_SECRET=dev-only-secret   # PGHOST/PGUSER default to the local socket/user
node scripts/dev_seed.js        # dev users (password merge2026) + sample items
npm start
# open http://localhost:3000
```

Production runs in Docker (`docker compose up -d --build app`) against `mmi-postgres`; see
`RUNBOOK_POSTGRES_CUTOVER.md`. ClickHouse is not needed to run the app.

## Known Limitations (v1)

- No password reset UI — must edit DB directly
- Approver name in MD view is free-text (allows delegation, weaker audit)
- GL account codes are hardcoded
- No PO amendment — POs are immutable once created
- No email/push notifications, no vendor DB, no budget tracking, no multi-currency
