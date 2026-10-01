-- One-time correction of timestamps written by the ClickHouse-era app.
--
-- Problem: clickhouse.js nowTs() and seed_purposes.js wrote the UTC wall-clock
-- time into DateTime64(3,'Asia/Jakarta') columns, so every row the old app
-- wrote is 7 hours earlier than the real moment. Rows written by the Python
-- import scripts (migrate_clickhouse.py, import_templates.py, push_items_*)
-- used Asia/Jakarta time and are already correct.
--
-- Shifted by +7 hours (created_at and updated_at; approval_actions.action_at):
--   purchase_requests, purchase_request_items, purchase_orders,
--   purchase_order_items, purchase_order_charges, approval_actions, users,
--   purposes, item_requests
--   items, vendors: only rows OUTSIDE a bulk import (a minute that holds 20+
--   rows created at once is an import batch and is left alone)
-- Left alone: pr_templates, pr_template_items, and the import batches above.
--
-- Run as the postgres superuser (it must switch off the updated_at trigger so
-- updated_at keeps its own value instead of becoming now()):
--
--   PREVIEW (changes nothing, ends with ROLLBACK):
--     docker exec -i mmi-postgres psql -U postgres -X -d procurement < scripts/fix_timestamps.sql
--   APPLY (one transaction, refuses to run a second time):
--     docker exec -i mmi-postgres psql -U postgres -X -d procurement -v apply=1 < scripts/fix_timestamps.sql
--
-- After applying, push the corrected rows to the warehouse:
--     scripts/ch_sync.sh --full
-- (approval_actions in ClickHouse is append-only and keeps its old action_at;
-- see RUNBOOK_POSTGRES_CUTOVER.md "Timestamp correction".)

\set ON_ERROR_STOP on
\pset footer off
\if :{?apply}
\else
  \set apply 0
\endif

-- Refuse to run twice (a second +7h would be wrong).
SELECT to_regclass('public.timestamp_fix_log') IS NOT NULL AS has_log \gset
\if :has_log
  SELECT count(*) > 0 AS already FROM public.timestamp_fix_log \gset
\else
  \set already false
\endif
\if :already
  \echo 'ABORT: this correction was already applied (see public.timestamp_fix_log). Nothing changed.'
  \quit
\endif

BEGIN;
SET LOCAL session_replication_role = replica;   -- no updated_at trigger
SET LOCAL TimeZone = 'Asia/Bangkok';

CREATE TEMP TABLE result (tbl text, shifted int, left_alone int, note text);

-- Bulk-import minutes in items / vendors.
CREATE TEMP TABLE batch_items   AS SELECT date_trunc('minute', created_at) AS m FROM items   GROUP BY 1 HAVING count(*) >= 20;
CREATE TEMP TABLE batch_vendors AS SELECT date_trunc('minute', created_at) AS m FROM vendors GROUP BY 1 HAVING count(*) >= 20;

-- Rows in an import batch that were edited afterwards: not touched, but listed.
INSERT INTO result
SELECT 'items (batch rows edited later)', 0,
       (SELECT count(*) FROM items i WHERE date_trunc('minute', i.created_at) IN (SELECT m FROM batch_items)
          AND i.updated_at > i.created_at + interval '2 seconds'), 'left alone — check by hand if it matters';
INSERT INTO result
SELECT 'vendors (batch rows edited later)', 0,
       (SELECT count(*) FROM vendors v WHERE date_trunc('minute', v.created_at) IN (SELECT m FROM batch_vendors)
          AND v.updated_at > v.created_at + interval '2 seconds'), 'left alone — check by hand if it matters';

DO $$
DECLARE t text; n int; total int;
BEGIN
  -- Every row was written by the old app (or seed_purposes.js).
  FOREACH t IN ARRAY ARRAY['purchase_requests','purchase_request_items','purchase_orders',
                           'purchase_order_items','purchase_order_charges','users','purposes','item_requests'] LOOP
    EXECUTE format('SELECT count(*) FROM %I', t) INTO total;
    EXECUTE format('UPDATE %I SET created_at = created_at + interval ''7 hours'', updated_at = updated_at + interval ''7 hours''', t);
    GET DIAGNOSTICS n = ROW_COUNT;
    INSERT INTO result VALUES (t, n, total - n, '');
  END LOOP;

  SELECT count(*) INTO total FROM approval_actions;
  UPDATE approval_actions SET action_at = action_at + interval '7 hours';
  GET DIAGNOSTICS n = ROW_COUNT;
  INSERT INTO result VALUES ('approval_actions (action_at)', n, total - n, '');

  -- Mixed tables: skip the bulk-import batches.
  SELECT count(*) INTO total FROM items;
  UPDATE items SET created_at = created_at + interval '7 hours', updated_at = updated_at + interval '7 hours'
   WHERE date_trunc('minute', created_at) NOT IN (SELECT m FROM batch_items);
  GET DIAGNOSTICS n = ROW_COUNT;
  INSERT INTO result VALUES ('items', n, total - n, 'import batch left alone');

  SELECT count(*) INTO total FROM vendors;
  UPDATE vendors SET created_at = created_at + interval '7 hours', updated_at = updated_at + interval '7 hours'
   WHERE date_trunc('minute', created_at) NOT IN (SELECT m FROM batch_vendors);
  GET DIAGNOSTICS n = ROW_COUNT;
  INSERT INTO result VALUES ('vendors', n, total - n, 'import batch left alone');

  SELECT count(*) INTO total FROM pr_templates;       INSERT INTO result VALUES ('pr_templates', 0, total, 'Jakarta time already');
  SELECT count(*) INTO total FROM pr_template_items;  INSERT INTO result VALUES ('pr_template_items', 0, total, 'Jakarta time already');
END $$;

\echo
\echo '== What this changes =='
SELECT tbl, shifted AS rows_shifted, left_alone AS rows_left_alone, note FROM result ORDER BY tbl;

\echo
\echo '== Sanity: document dates vs corrected local created date (expected 0) =='
SELECT 'purchase_requests' AS tbl, count(*) AS date_mismatch
  FROM purchase_requests WHERE (created_at AT TIME ZONE 'Asia/Bangkok')::date <> pr_date
UNION ALL
SELECT 'purchase_orders', count(*)
  FROM purchase_orders WHERE (created_at AT TIME ZONE 'Asia/Bangkok')::date <> po_date;

\echo
\echo '== Hours of day AFTER the shift (office rows should now sit in about 08-18) =='
SELECT 'purchase_requests' AS tbl, string_agg(h || ':' || c, ' ' ORDER BY h) AS hours_local
  FROM (SELECT to_char(created_at AT TIME ZONE 'Asia/Bangkok', 'HH24') h, count(*) c FROM purchase_requests GROUP BY 1) x
UNION ALL
SELECT 'approval_actions', string_agg(h || ':' || c, ' ' ORDER BY h)
  FROM (SELECT to_char(action_at AT TIME ZONE 'Asia/Bangkok', 'HH24') h, count(*) c FROM approval_actions GROUP BY 1) x;

\if :apply
  CREATE TABLE public.timestamp_fix_log (applied_at timestamptz NOT NULL DEFAULT now(), note text);
  INSERT INTO public.timestamp_fix_log (note) VALUES ('+7h on app-written rows (see scripts/fix_timestamps.sql)');
  COMMIT;
  \echo
  \echo 'APPLIED. Next: scripts/ch_sync.sh --full'
\else
  ROLLBACK;
  \echo
  \echo 'PREVIEW ONLY — nothing was changed. Re-run with -v apply=1 to apply.'
\endif
