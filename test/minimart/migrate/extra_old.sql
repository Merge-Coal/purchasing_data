-- Extra objects loaded into the simulated OLD minimart database on top of
-- test/minimart/stand_in_schema.sql + stand_in_seed.sql, to exercise what a real
-- database might also contain: an extension with its own type, a second schema,
-- awkward identifiers, float/timestamp specials, an unlogged table, large objects,
-- objects owned by a different role, ACLs, and a sequence that is BEHIND its data.
SET client_min_messages = warning;

CREATE EXTENSION citext;
CREATE ROLE legacy_app LOGIN;

CREATE SCHEMA audit;
CREATE TYPE audit.severity AS ENUM ('low', 'high');
CREATE TABLE audit.changes (
  change_id serial PRIMARY KEY,
  tbl       citext NOT NULL,
  sev       audit.severity NOT NULL DEFAULT 'low',
  at        timestamptz NOT NULL DEFAULT now(),
  old_row   jsonb
);
INSERT INTO audit.changes (tbl, sev, at, old_row)
SELECT 'Products', CASE WHEN g % 2 = 0 THEN 'high' ELSE 'low' END::audit.severity,
       TIMESTAMPTZ '2025-06-01 00:00:00+00' + (g || ' hours')::interval, jsonb_build_object('g', g)
  FROM generate_series(1, 30) g;
CREATE VIEW audit.recent AS SELECT * FROM audit.changes WHERE sev = 'high';

CREATE TABLE "weird""name" ("Col ""x""" integer PRIMARY KEY, "select" text, "UPPER" numeric(8,2));
INSERT INTO "weird""name" VALUES (1, 'a', 1.50), (2, NULL, NULL), (3, E'new\nline', 3.14);

CREATE TABLE specials (
  id integer PRIMARY KEY, f float8, r real, n numeric, ts timestamptz, d date, money_col money, bits bit(5), b bytea
);
INSERT INTO specials VALUES
  (1, 'NaN', 'NaN', 'NaN', 'infinity', 'infinity', '12.34', B'10101', '\x00ff'),
  (2, 'Infinity', 'Infinity', 1e1000::numeric, '-infinity', '-infinity', '-0.01', B'00001', ''),
  (3, '-Infinity', '-Infinity', -1.5, '2025-01-01 00:00:00.000001+00', '0001-01-01', NULL, NULL, NULL),
  (4, 0.1, 0.1, 0.1, now(), '9999-12-31', '9999999.99', B'11111', '\xdeadbeef');

CREATE UNLOGGED TABLE scratch_cache (k text PRIMARY KEY, v text);
INSERT INTO scratch_cache SELECT 'k' || g, repeat('v', g) FROM generate_series(1, 10) g;

SELECT lo_from_bytea(0, 'hello large object'::bytea) \g /dev/null
SELECT lo_from_bytea(0, decode(repeat('00ff', 5000), 'hex')) \g /dev/null

-- a sequence that is BEHIND the data (rows were inserted with explicit ids)
SELECT setval('customers_customer_id_seq', 5) \g /dev/null

-- objects owned by another role + ACLs (the migration drops owners and ACLs)
ALTER TABLE products OWNER TO legacy_app;
ALTER TABLE customers OWNER TO legacy_app;
ALTER TABLE audit.changes OWNER TO legacy_app;
ALTER TYPE order_status OWNER TO legacy_app;
ALTER FUNCTION touch_updated_at() OWNER TO legacy_app;
ALTER VIEW v_order_totals OWNER TO legacy_app;
ALTER MATERIALIZED VIEW mv_product_sales OWNER TO legacy_app;
ALTER SEQUENCE invoice_no_seq OWNER TO legacy_app;
ALTER SCHEMA audit OWNER TO legacy_app;
GRANT SELECT ON orders, order_items TO legacy_app;
GRANT USAGE ON SCHEMA audit TO legacy_app;

-- Added after the first adversarial review: a column named like the row alias used by the
-- verifier ("t"), a STALE and an UNPOPULATED materialised view, a sequence with MINVALUE above
-- its data, and database-level settings (search_path) that a dump does not carry.
CREATE TABLE tcol (t integer PRIMARY KEY, v text);
INSERT INTO tcol VALUES (1, 'one'), (2, 'two');
CREATE MATERIALIZED VIEW mv_nodata AS SELECT * FROM categories WITH NO DATA;
INSERT INTO order_items (order_id, product_id, qty, unit_price) SELECT order_id, 1, 1, 1 FROM orders LIMIT 1;  -- mv_product_sales is now stale
CREATE SEQUENCE s_min MINVALUE 1000 START 1000;
CREATE TABLE minseq_tab (id integer PRIMARY KEY DEFAULT nextval('s_min'), v text);
INSERT INTO minseq_tab VALUES (1, 'a'), (2, 'b');
DO $$ BEGIN EXECUTE format('ALTER DATABASE %I SET search_path = public, audit', current_database()); END $$;
