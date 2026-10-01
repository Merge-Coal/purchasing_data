-- ============================================================
-- Postgres (OLTP, source of truth) → ClickHouse (warehouse) incremental sync
--
-- Template, not run directly: scripts/ch_sync.sh substitutes
--   @SINCE@      lower bound, 'YYYY-MM-DD hh:mm:ss.fff' in UTC (last run's
--                start minus a 15-minute overlap; 1970-01-01 for --full)
--   @RUN_START@  this run's start time in UTC, recorded as the new watermark
--   @MODE@       'incremental' or 'full'
--   @VERSION_FLOOR@  0 normally. With --bump, the current time in epoch ms: every
--                row is re-sent with a version at least this high, so it beats any
--                existing copy (used once, after the timestamp correction)
-- and streams the result into clickhouse-client --multiquery. The client stops
-- at the first failing statement, so the watermark row at the bottom is only
-- written when every table before it succeeded.
--
-- Source: named collection `pg_procurement` (db/clickhouse-config.d/
-- 30-pg-source.xml), Postgres role procurement_ro.
--
-- Conversions (Postgres → ClickHouse column types in db/clickhouse_schema.sql
-- and the runtime CREATE TABLEs the ClickHouse-era server.js ran):
--   timestamptz → DateTime64(3,'Asia/Jakarta'). ClickHouse 24.8 reads a
--       Postgres timestamp(tz) as DateTime64(6) in the *server* time zone and
--       ignores the '+00' offset in the text. procurement_ro's sessions are
--       pinned to UTC (db/postgres_setup.sql), so the text is UTC wall-clock;
--       toDateTime64(toString(x), 6, 'UTC') turns it back into the right
--       instant whatever the ClickHouse server time zone is.
--   version     = updated_at in epoch milliseconds — newer edits always win in
--       ReplacingMergeTree, and re-sending an unchanged row is harmless.
--   NULL uuid (primary_pr_id, purchase_order_items.pr_item_id) → ''.
--   uuid → String where the ClickHouse column is String (pr_id, po_id, …).
--   smallint is_deleted / is_taxable → UInt8; integer → UInt16 / UInt8.
--   numeric(p,s) → Decimal(p,s) (same precision both sides);
--   pr_template_items.default_qty (unconstrained numeric) → Float64.
--
-- Filters on converted expressions are evaluated in ClickHouse (not pushed to
-- Postgres): every run reads each table in full and inserts only changed rows.
-- Fine at this data size (well under 1 MB); revisit if tables reach ~1M rows.
--
-- users.password_hash is NOT read from Postgres (procurement_ro has no SELECT
-- on that column). The value already in ClickHouse for that user is carried
-- forward so a rollback to the ClickHouse-backed app still lets pre-cutover
-- users log in; users created after cutover get ''.
--
-- Append-only tables (approval_actions, gl_exports; plain MergeTree, no
-- version) are synced by anti-join on their id: exact, idempotent, and immune
-- to late-committing rows, which a timestamp watermark is not.
-- ============================================================

-- ── purposes ─────────────────────────────────────────────────────────────────
INSERT INTO procurement.purposes
    (purpose_id, company_id, label, sort_order, status, version, is_deleted, created_at, updated_at)
SELECT s.purpose_id, s.company_id, s.label, toUInt16(s.sort_order), s.status,
       greatest(toUInt64(toUnixTimestamp64Milli(toDateTime64(toString(s.updated_at), 6, 'UTC'))), toUInt64(@VERSION_FLOOR@)),
       toUInt8(s.is_deleted),
       toDateTime64(toString(s.created_at), 6, 'UTC'),
       toDateTime64(toString(s.updated_at), 6, 'UTC')
FROM postgresql(pg_procurement, table = 'purposes') AS s
WHERE toDateTime64(toString(s.updated_at), 6, 'UTC') > toDateTime64('@SINCE@', 6, 'UTC');

-- ── users (password_hash carried forward from ClickHouse, never read from PG) ─
INSERT INTO procurement.users
    (user_id, legacy_user_id, company_id, username, password_hash, role, full_name,
     email, department_id, status, version, is_deleted, created_at, updated_at)
SELECT s.user_id, s.legacy_user_id, s.company_id, s.username, h.password_hash, s.role,
       s.full_name, s.email, s.department_id, s.status,
       greatest(toUInt64(toUnixTimestamp64Milli(toDateTime64(toString(s.updated_at), 6, 'UTC'))), toUInt64(@VERSION_FLOOR@)),
       toUInt8(s.is_deleted),
       toDateTime64(toString(s.created_at), 6, 'UTC'),
       toDateTime64(toString(s.updated_at), 6, 'UTC')
FROM postgresql(pg_procurement, table = 'users') AS s
LEFT JOIN
(
    SELECT user_id, argMax(password_hash, version) AS password_hash
    FROM procurement.users
    GROUP BY user_id
) AS h ON h.user_id = s.user_id
WHERE toDateTime64(toString(s.updated_at), 6, 'UTC') > toDateTime64('@SINCE@', 6, 'UTC');

-- ── vendors ──────────────────────────────────────────────────────────────────
INSERT INTO procurement.vendors
    (vendor_id, company_id, vendor_code, vendor_name, category, status, contact_person,
     phone, mobile, email, address, city, country, npwp, payment_term_id,
     default_currency, tax_profile, risk_rating, onboarding_date, blocked_reason,
     search_text, version, is_deleted, created_at, updated_at)
SELECT s.vendor_id, s.company_id, s.vendor_code, s.vendor_name, s.category, s.status,
       s.contact_person, s.phone, s.mobile, s.email, s.address, s.city, s.country,
       s.npwp, s.payment_term_id, s.default_currency, s.tax_profile, s.risk_rating,
       s.onboarding_date, s.blocked_reason, s.search_text,
       greatest(toUInt64(toUnixTimestamp64Milli(toDateTime64(toString(s.updated_at), 6, 'UTC'))), toUInt64(@VERSION_FLOOR@)),
       toUInt8(s.is_deleted),
       toDateTime64(toString(s.created_at), 6, 'UTC'),
       toDateTime64(toString(s.updated_at), 6, 'UTC')
FROM postgresql(pg_procurement, table = 'vendors') AS s
WHERE toDateTime64(toString(s.updated_at), 6, 'UTC') > toDateTime64('@SINCE@', 6, 'UTC');

-- ── items ────────────────────────────────────────────────────────────────────
INSERT INTO procurement.items
    (item_id, company_id, base_item_id, item_code, name_en, name_cn, category_id,
     category_name, spec, uom, department_id, item_type, default_gl_account_id,
     min_order_qty, lead_time_days, status, search_text, version, is_deleted,
     created_at, updated_at)
SELECT s.item_id, s.company_id, s.base_item_id, s.item_code, s.name_en, s.name_cn,
       s.category_id, s.category_name, s.spec, s.uom, s.department_id, s.item_type,
       s.default_gl_account_id, toDecimal64(s.min_order_qty, 4), toUInt16(s.lead_time_days),
       s.status, s.search_text,
       greatest(toUInt64(toUnixTimestamp64Milli(toDateTime64(toString(s.updated_at), 6, 'UTC'))), toUInt64(@VERSION_FLOOR@)),
       toUInt8(s.is_deleted),
       toDateTime64(toString(s.created_at), 6, 'UTC'),
       toDateTime64(toString(s.updated_at), 6, 'UTC')
FROM postgresql(pg_procurement, table = 'items') AS s
WHERE toDateTime64(toString(s.updated_at), 6, 'UTC') > toDateTime64('@SINCE@', 6, 'UTC');

-- ── purchase_requests ────────────────────────────────────────────────────────
INSERT INTO procurement.purchase_requests
    (pr_id, legacy_pr_id, company_id, pr_number, requester_user_id, requested_by_name,
     department_id, cost_center_id, pr_date, needed_by_date, priority, status,
     total_estimated_amount, currency, notes, search_text, version, is_deleted,
     created_at, updated_at)
SELECT s.pr_id, s.legacy_pr_id, s.company_id, s.pr_number, s.requester_user_id,
       s.requested_by_name, s.department_id, s.cost_center_id, s.pr_date,
       s.needed_by_date, s.priority, s.status,
       toDecimal64(s.total_estimated_amount, 2), s.currency, s.notes, s.search_text,
       greatest(toUInt64(toUnixTimestamp64Milli(toDateTime64(toString(s.updated_at), 6, 'UTC'))), toUInt64(@VERSION_FLOOR@)),
       toUInt8(s.is_deleted),
       toDateTime64(toString(s.created_at), 6, 'UTC'),
       toDateTime64(toString(s.updated_at), 6, 'UTC')
FROM postgresql(pg_procurement, table = 'purchase_requests') AS s
WHERE toDateTime64(toString(s.updated_at), 6, 'UTC') > toDateTime64('@SINCE@', 6, 'UTC');

-- ── purchase_request_items ───────────────────────────────────────────────────
INSERT INTO procurement.purchase_request_items
    (pr_item_id, legacy_pr_item_id, company_id, pr_id, line_no, item_id,
     item_description, requested_qty, approved_qty, uom, estimated_unit_price,
     estimated_total_price, department_id, cost_center_id, gl_account_id, status,
     notes, version, is_deleted, created_at, updated_at)
SELECT s.pr_item_id, s.legacy_pr_item_id, s.company_id, toString(s.pr_id),
       toUInt16(s.line_no), s.item_id, s.item_description,
       toDecimal64(s.requested_qty, 4), toDecimal64(s.approved_qty, 4), s.uom,
       toDecimal64(s.estimated_unit_price, 2), toDecimal64(s.estimated_total_price, 2),
       s.department_id, s.cost_center_id, s.gl_account_id, s.status, s.notes,
       greatest(toUInt64(toUnixTimestamp64Milli(toDateTime64(toString(s.updated_at), 6, 'UTC'))), toUInt64(@VERSION_FLOOR@)),
       toUInt8(s.is_deleted),
       toDateTime64(toString(s.created_at), 6, 'UTC'),
       toDateTime64(toString(s.updated_at), 6, 'UTC')
FROM postgresql(pg_procurement, table = 'purchase_request_items') AS s
WHERE toDateTime64(toString(s.updated_at), 6, 'UTC') > toDateTime64('@SINCE@', 6, 'UTC');

-- ── purchase_orders ──────────────────────────────────────────────────────────
INSERT INTO procurement.purchase_orders
    (po_id, legacy_po_id, company_id, po_number, primary_pr_id, vendor_id, vendor_name,
     po_date, expected_delivery_date, currency, exchange_rate, payment_term_id, status,
     subtotal_amount, discount_amount, charges_amount, tax_amount, withholding_amount,
     total_amount, notes, search_text, created_by_user_id, version, is_deleted,
     created_at, updated_at)
SELECT s.po_id, s.legacy_po_id, s.company_id, s.po_number,
       ifNull(toString(s.primary_pr_id), ''),
       s.vendor_id, s.vendor_name, s.po_date, s.expected_delivery_date, s.currency,
       toDecimal64(s.exchange_rate, 6), s.payment_term_id, s.status,
       toDecimal64(s.subtotal_amount, 2), toDecimal64(s.discount_amount, 2),
       toDecimal64(s.charges_amount, 2), toDecimal64(s.tax_amount, 2),
       toDecimal64(s.withholding_amount, 2), toDecimal64(s.total_amount, 2),
       s.notes, s.search_text, s.created_by_user_id,
       greatest(toUInt64(toUnixTimestamp64Milli(toDateTime64(toString(s.updated_at), 6, 'UTC'))), toUInt64(@VERSION_FLOOR@)),
       toUInt8(s.is_deleted),
       toDateTime64(toString(s.created_at), 6, 'UTC'),
       toDateTime64(toString(s.updated_at), 6, 'UTC')
FROM postgresql(pg_procurement, table = 'purchase_orders') AS s
WHERE toDateTime64(toString(s.updated_at), 6, 'UTC') > toDateTime64('@SINCE@', 6, 'UTC');

-- ── purchase_order_items ─────────────────────────────────────────────────────
INSERT INTO procurement.purchase_order_items
    (po_item_id, legacy_po_item_id, company_id, po_id, line_no, pr_item_id,
     quotation_item_id, item_id, item_description, ordered_qty, received_qty,
     invoiced_qty, uom, unit_price, discount_amount, tax_amount, total_price,
     gl_account_id, cost_center_id, vendor_name, status, notes, purpose, version,
     is_deleted, created_at, updated_at)
SELECT s.po_item_id, s.legacy_po_item_id, s.company_id, toString(s.po_id),
       toUInt16(s.line_no), ifNull(toString(s.pr_item_id), ''),
       s.quotation_item_id, s.item_id, s.item_description,
       toDecimal64(s.ordered_qty, 4), toDecimal64(s.received_qty, 4),
       toDecimal64(s.invoiced_qty, 4), s.uom,
       toDecimal64(s.unit_price, 2), toDecimal64(s.discount_amount, 2),
       toDecimal64(s.tax_amount, 2), toDecimal64(s.total_price, 2),
       s.gl_account_id, s.cost_center_id, s.vendor_name, s.status, s.notes, s.purpose,
       greatest(toUInt64(toUnixTimestamp64Milli(toDateTime64(toString(s.updated_at), 6, 'UTC'))), toUInt64(@VERSION_FLOOR@)),
       toUInt8(s.is_deleted),
       toDateTime64(toString(s.created_at), 6, 'UTC'),
       toDateTime64(toString(s.updated_at), 6, 'UTC')
FROM postgresql(pg_procurement, table = 'purchase_order_items') AS s
WHERE toDateTime64(toString(s.updated_at), 6, 'UTC') > toDateTime64('@SINCE@', 6, 'UTC');

-- ── purchase_order_charges ───────────────────────────────────────────────────
INSERT INTO procurement.purchase_order_charges
    (charge_id, company_id, po_id, line_no, charge_type, description, amount,
     gl_account_code, is_taxable, version, is_deleted, created_at, updated_at)
SELECT s.charge_id, s.company_id, toString(s.po_id), toUInt16(s.line_no),
       s.charge_type, s.description, toDecimal64(s.amount, 2), s.gl_account_code,
       toUInt8(s.is_taxable),
       greatest(toUInt64(toUnixTimestamp64Milli(toDateTime64(toString(s.updated_at), 6, 'UTC'))), toUInt64(@VERSION_FLOOR@)),
       toUInt8(s.is_deleted),
       toDateTime64(toString(s.created_at), 6, 'UTC'),
       toDateTime64(toString(s.updated_at), 6, 'UTC')
FROM postgresql(pg_procurement, table = 'purchase_order_charges') AS s
WHERE toDateTime64(toString(s.updated_at), 6, 'UTC') > toDateTime64('@SINCE@', 6, 'UTC');

-- ── item_requests (request_id is String in ClickHouse) ───────────────────────
INSERT INTO procurement.item_requests
    (request_id, company_id, requested_by_user_id, requested_by_name, name_en, name_cn,
     category_name, spec, uom, notes, source_excel_name, status, approved_item_id,
     admin_notes, version, is_deleted, created_at, updated_at)
SELECT toString(s.request_id), s.company_id, s.requested_by_user_id, s.requested_by_name,
       s.name_en, s.name_cn, s.category_name, s.spec, s.uom, s.notes,
       s.source_excel_name, s.status, s.approved_item_id, s.admin_notes,
       greatest(toUInt64(toUnixTimestamp64Milli(toDateTime64(toString(s.updated_at), 6, 'UTC'))), toUInt64(@VERSION_FLOOR@)),
       toUInt8(s.is_deleted),
       toDateTime64(toString(s.created_at), 6, 'UTC'),
       toDateTime64(toString(s.updated_at), 6, 'UTC')
FROM postgresql(pg_procurement, table = 'item_requests') AS s
WHERE toDateTime64(toString(s.updated_at), 6, 'UTC') > toDateTime64('@SINCE@', 6, 'UTC');

-- ── pr_templates ─────────────────────────────────────────────────────────────
INSERT INTO procurement.pr_templates
    (template_id, company_id, template_name, display_name, sort_order, version,
     is_deleted, created_at, updated_at)
SELECT s.template_id, s.company_id, s.template_name, s.display_name, toUInt8(s.sort_order),
       greatest(toUInt64(toUnixTimestamp64Milli(toDateTime64(toString(s.updated_at), 6, 'UTC'))), toUInt64(@VERSION_FLOOR@)),
       toUInt8(s.is_deleted),
       toDateTime64(toString(s.created_at), 6, 'UTC'),
       toDateTime64(toString(s.updated_at), 6, 'UTC')
FROM postgresql(pg_procurement, table = 'pr_templates') AS s
WHERE toDateTime64(toString(s.updated_at), 6, 'UTC') > toDateTime64('@SINCE@', 6, 'UTC');

-- ── pr_template_items ────────────────────────────────────────────────────────
INSERT INTO procurement.pr_template_items
    (template_item_id, company_id, template_id, item_id, name_en, name_cn, spec,
     department, uom, default_qty, sort_order, version, is_deleted, created_at, updated_at)
SELECT s.template_item_id, s.company_id, s.template_id, s.item_id, s.name_en, s.name_cn,
       s.spec, s.department, s.uom, toFloat64(s.default_qty), toUInt16(s.sort_order),
       greatest(toUInt64(toUnixTimestamp64Milli(toDateTime64(toString(s.updated_at), 6, 'UTC'))), toUInt64(@VERSION_FLOOR@)),
       toUInt8(s.is_deleted),
       toDateTime64(toString(s.created_at), 6, 'UTC'),
       toDateTime64(toString(s.updated_at), 6, 'UTC')
FROM postgresql(pg_procurement, table = 'pr_template_items') AS s
WHERE toDateTime64(toString(s.updated_at), 6, 'UTC') > toDateTime64('@SINCE@', 6, 'UTC');

-- ── approval_actions (append-only MergeTree: insert ids not yet present) ─────
INSERT INTO procurement.approval_actions
    (approval_action_id, company_id, document_type, document_id, document_item_id,
     workflow_id, step_no, actor_user_id, actor_name, action, action_at, from_status,
     to_status, approved_qty, notes)
SELECT s.approval_action_id, s.company_id, s.document_type, s.document_id,
       s.document_item_id, s.workflow_id, toUInt16(s.step_no), s.actor_user_id,
       s.actor_name, s.action,
       toDateTime64(toString(s.action_at), 6, 'UTC'),
       s.from_status, s.to_status, s.approved_qty, s.notes
FROM postgresql(pg_procurement, table = 'approval_actions') AS s
WHERE toString(s.approval_action_id) NOT IN
      (SELECT toString(approval_action_id) FROM procurement.approval_actions);

-- ── gl_exports (append-only: insert ids not yet present) ─────────────────────
-- Only the columns both historical ClickHouse definitions share (the schema
-- file's MergeTree with UUID id / Date export_date, and the old server.js
-- ReplacingMergeTree with String id / String export_date); INSERT … SELECT
-- casts by position, and toString() on both sides of the anti-join works
-- for either id type.
INSERT INTO procurement.gl_exports
    (gl_export_id, legacy_log_id, company_id, source_document_type, source_document_id,
     export_number, export_date, filename, status, exported_by_user_id, notes)
SELECT s.gl_export_id, s.legacy_log_id, s.company_id, s.source_document_type,
       s.source_document_id, s.export_number, s.export_date, s.filename, s.status,
       s.exported_by_user_id, s.notes
FROM postgresql(pg_procurement, table = 'gl_exports') AS s
WHERE toString(s.gl_export_id) NOT IN
      (SELECT toString(gl_export_id) FROM procurement.gl_exports);

-- ── Advance the watermark (only reached if everything above succeeded) ───────
INSERT INTO procurement._sync_state (run_at, synced_through, mode)
VALUES (now64(3, 'UTC'), toDateTime64('@RUN_START@', 3, 'UTC'), '@MODE@');
