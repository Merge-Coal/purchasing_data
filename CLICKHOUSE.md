# ClickHouse — PT Merge Mining Industri Procurement

## Status: warehouse, fed from Postgres

Since the Postgres cutover (`RUNBOOK_POSTGRES_CUTOVER.md`) the app reads and writes
**PostgreSQL** (database `procurement` on `mmi-postgres`). ClickHouse is the analytics
warehouse and the rollback copy: it no longer receives writes from the app, only from
the sync. Do not write to the synced tables by hand — the next sync will not undo it,
and Postgres will not see it.

How the sync works:

- ClickHouse pulls from Postgres itself, through the named collection `pg_procurement`
  (`db/clickhouse-config.d/30-pg-source.xml`; SELECT-only role `procurement_ro`, password
  from the container env `PG_RO_PASSWORD`). `procurement_ro` cannot read
  `users.password_hash` or `session`.
- `scripts/ch_sync.sh` (host cron, every 15 min) fills in `db/ch_sync.sql` and runs it.
  14 tables: purposes, users, vendors, items, purchase_requests, purchase_request_items,
  purchase_orders, purchase_order_items, purchase_order_charges, approval_actions,
  gl_exports, item_requests, pr_templates, pr_template_items.
- ReplacingMergeTree tables get rows with `updated_at` after the last run (15-minute
  overlap), `version` = `updated_at` in ms, so the newest edit wins and re-sends are
  harmless. Append-only `approval_actions` / `gl_exports` get only ids not yet present.
- The watermark is `procurement._sync_state` (one row per successful run). A failed run
  writes no row, so the next run retries the same window.
- Sync only inserts: soft deletes (`is_deleted = 1`) arrive, hard deletes in Postgres do not.
- `users.password_hash` keeps whatever ClickHouse already had (pre-cutover users); users
  created after cutover have `''` here.

Commands (on the server, in `/opt/purchasing_data`):

```bash
scripts/ch_sync.sh            # incremental (what cron runs)
scripts/ch_sync.sh --full     # every row again — first run, or repair after a gap
scripts/ch_sync.sh --verify   # every Postgres id present in ClickHouse? exit 1 if not
scripts/ch_sync.sh --print    # show the SQL an incremental run would send
tail -20 /var/log/procurement-ch-sync.log
```

Query current state with `FINAL` as before. The sections below describe the
pre-cutover setup, when ClickHouse was the app's live database.

## Connection Details

| Property | Value |
|---|---|
| Host (production) | `76.13.19.246` |
| HTTP port | `8123` |
| Native port | `9000` |
| Database | `procurement` |
| User | `procurement_user` |
| Password | `${CLICKHOUSE_PASSWORD}` |

---

## Docker Setup

ClickHouse runs as a second container alongside the Node.js app.

```
docker-compose.yml
├── app (procurement_app)              — Node.js, port 3000
└── clickhouse (procurement_clickhouse) — port 8123 (HTTP), 9000 (native)
    └── volume: clickhouse_data (persistent)
    └── init:   db/clickhouse_schema.sql (41 tables)
```

### First-time setup on a new server

```bash
# 1. Set password in .env (must match CLICKHOUSE_PASSWORD in docker-compose.yml)
echo "CLICKHOUSE_PASSWORD=${CLICKHOUSE_PASSWORD}" >> .env

# 2. Start both services
docker compose up -d

# 3. Run SQLite → ClickHouse migration (dry-run first)
pip install requests
python3 migrate_clickhouse.py --dry-run
python3 migrate_clickhouse.py

# 4. Verify
curl -s "http://localhost:8123/?database=procurement&query=SELECT+name,total_rows+FROM+system.tables+WHERE+database='procurement'+ORDER+BY+name" \
  -u procurement_user:${CLICKHOUSE_PASSWORD}
```

---

## Common Commands

### Push item master only (after DB updates)

```bash
python3 migrate_clickhouse.py --items-only --host 76.13.19.246 --password '${CLICKHOUSE_PASSWORD}'
docker restart procurement_app
```

### Ad-hoc query via HTTP

```bash
curl -s "http://76.13.19.246:8123/?database=procurement&query=SELECT+COUNT(*)+FROM+items+FINAL" \
  -u procurement_user:${CLICKHOUSE_PASSWORD}
```

### Check table row counts

```bash
curl -s "http://76.13.19.246:8123/?database=procurement&query=SELECT+name,total_rows+FROM+system.tables+WHERE+database='procurement'+ORDER+BY+name" \
  -u procurement_user:${CLICKHOUSE_PASSWORD}
```

---

## Node.js Client (`clickhouse.js`)

Thin HTTP wrapper around the ClickHouse HTTP interface.

```javascript
const ch = require('./clickhouse');

// Query (always FINAL for current-state tables using ReplacingMergeTree)
const rows = await ch.query(
  'SELECT * FROM items FINAL WHERE company_id = {cid:String}',
  { cid: 'PTMMI' }
);

// Insert
await ch.insert('items', [{ item_id: 'ITEM-0001', name_en: 'PC Strand', ... }]);

// Health check
await ch.ping();
```

**Important:** Always use `FINAL` when querying `ReplacingMergeTree` tables to avoid reading stale duplicate rows before background merges complete.

---

## Schema Overview (41 tables)

Defined in `db/clickhouse_schema.sql`.

| Group | Tables |
|---|---|
| Master data | companies, departments, cost_centers, gl_accounts, tax_codes, payment_terms, users, app_sessions |
| Vendor | vendors, vendor_bank_accounts, vendor_documents |
| Item | item_categories, items, item_vendor_prices |
| Workflow | approval_workflows, approval_steps |
| PR | purchase_requests, purchase_request_items |
| RFQ | request_for_quotes, request_for_quote_items |
| Quotation | supplier_quotations, supplier_quotation_items |
| PO | purchase_orders, purchase_order_items, purchase_order_tax_lines |
| Receiving | goods_receipts, goods_receipt_items |
| Invoice | supplier_invoices, supplier_invoice_items, supplier_invoice_tax_lines |
| Payment | payments |
| GL | gl_exports, gl_export_lines |
| Budget | budget_headers, budget_lines, budget_movements |
| Audit | approval_actions, status_history, procurement_events, attachments, comments |

### Engine strategy

- `ReplacingMergeTree(version)` — current-state tables (items, vendors, PRs, POs, etc.)
- `MergeTree` — append-only tables (audit events, GL export lines, budget movements)
- `LowCardinality(String)` — bounded fields (status, role, category, UOM)
- `Decimal(18,2)` for money, `Decimal(18,4)` for quantities

---

## Migration Scripts

| Script | Purpose |
|---|---|
| `migrate_clickhouse.py` | Full SQLite → ClickHouse migration |
| `migrate_clickhouse.py --dry-run` | Preview what would be migrated |
| `migrate_clickhouse.py --items-only` | Push item master only (use after item imports) |

---

## Pending Work

- [ ] Migrate app API routes from SQLite (`better-sqlite3`) to ClickHouse client
- [ ] Receiving module UI + `goods_receipts` inserts
- [ ] Invoice matching UI + `supplier_invoices` inserts
- [ ] Vendor master UI + `vendor_bank_accounts` / `vendor_documents`
- [ ] Budget and cost center UI
- [ ] Reporting dashboards (spend by vendor/category, PR aging, open POs, budget vs actual)
- [ ] Automated daily backup cron on server
