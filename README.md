> **OUTDATED (before the 2026-10-01 Postgres cutover):** this document describes the SQLite / ClickHouse-era setup and its commands no longer apply. Current setup: `CLAUDE.md` and `RUNBOOK_POSTGRES_CUTOVER.md`.

# PT Merge Mining Industri — Procurement App

Local procurement web app: Purchase Requests → MD Approval → Purchase Orders → GL CSV Export.

## Stack
- **Backend**: Node.js + Express + better-sqlite3
- **Frontend**: Single HTML file, vanilla JS, no framework
- **Search**: Fuse.js (fuzzy, threshold 0.4)
- **Export**: json2csv → GL journal CSV

## Setup

### 1. Install dependencies
```bash
npm install
```

### 2. Point to your existing item_master.db

The app adds new tables to your existing SQLite database without touching the `items` table.

```bash
# macOS / Linux
export DB_PATH=/path/to/item_master.db

# Windows
set DB_PATH=C:\path\to\item_master.db
```

To use the existing database in this project:
```bash
export DB_PATH=./item_master.db
```

### 3. Start the server
```bash
npm start
```

Open → **http://localhost:3000**

---

## Usage

### Role selector (top right)
- **Requester** — create PRs, view PR/PO lists
- **MD Approval** — review and approve/reject pending PRs
- **Admin** — manage item master (add new items)

### Requester flow
1. **Create PR** tab → fill requester name, department, add line items via search → Submit
2. **PR List** tab → once PR is approved, click "Create PO" → enter vendor + confirm prices
3. **PO List** tab → click "Export GL CSV" to download journal entry file

### MD Approval flow
1. Switch role to **MD Approval**
2. Click **Review** on any pending PR → view line items → Approve or Reject with notes

---

## GL Export
Files saved to `./exports/` as `GL_PO-YYYY-NNN_YYYYMMDD.csv`  
Two journal rows per PO:
- Debit 5000 Inventory/Expense
- Credit 2100 Accounts Payable

---

## Database tables added (never touches existing `items` table)
- `pr` — purchase request headers
- `pr_items` — PR line items
- `approvals` — approval audit log
- `po` — purchase order headers
- `po_items` — PO line items
- `gl_export_log` — GL export history
