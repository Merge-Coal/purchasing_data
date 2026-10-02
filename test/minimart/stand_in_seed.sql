-- Minimart STAND-IN seed data (deterministic, no random()). Run after
-- stand_in_schema.sql. ~1,000 products, 200 customers, 1,500 orders, ~4,500
-- order items, 3,000 stock movements, 2,000 events. Includes NULLs, unicode
-- (Chinese, emoji), quotes, backslashes, tabs/newlines, microsecond
-- timestamps, negative and very large/small numerics, empty arrays.
-- Owned by Agent M.
SET client_min_messages = warning;
SET timezone = 'UTC';

INSERT INTO categories VALUES
  (1,'Snacks',10),(2,'Drinks',20),(3,'Instant noodles',30),(4,'Household',40),(5,'面包 / Bakery',50);

INSERT INTO settings VALUES
  ('store_name','Minimart ''Merge'''),('currency','IDR'),('open_hours','07:00-22:00'),('motd',E'Line1\nLine2\ttabbed \\ backslash'),('empty_value',''),('null_value',NULL);

INSERT INTO products (sku, name, category_id, price, weight_kg, rating, margin, active, tags, dims_mm, attrs, photo, released_on, created_at)
SELECT 'SKU-' || lpad(g::text, 5, '0'),
       CASE WHEN g % 50 = 0 THEN '饼干 ' || g
            WHEN g % 33 = 0 THEN 'Quote "q" ''s, comma ' || g
            WHEN g % 77 = 0 THEN E'multi\nline\ttab \\ ' || g
            WHEN g % 91 = 0 THEN 'emoji 🍜 ' || g
            ELSE 'Product ' || g END,
       CASE WHEN g % 17 = 0 THEN NULL ELSE (g % 5) + 1 END,
       (g * 137 % 100000) / 100.0 + 0.5,
       CASE WHEN g % 4 = 0 THEN NULL WHEN g % 9 = 0 THEN 0.000000123456789012345 ELSE g / 7.0 END,
       CASE WHEN g % 6 = 0 THEN NULL ELSE (g % 50) / 10.0 END,
       CASE WHEN g % 8 = 0 THEN NULL ELSE sin(g) END,
       g % 10 <> 0,
       CASE WHEN g % 3 = 0 THEN '{}' ELSE ARRAY['t' || (g % 7), 'x y', 'q"uote', 'comma,s'] END,
       CASE WHEN g % 5 = 0 THEN NULL ELSE ARRAY[g % 100, g % 7, g % 13] END,
       CASE WHEN g % 4 = 1 THEN NULL
            ELSE jsonb_build_object('g', g, 'nested', jsonb_build_object('a', ARRAY[1,2,3], 'note', 'ünï'), 'flag', g % 2 = 0) END,
       CASE WHEN g % 7 = 0 THEN decode(lpad(to_hex(g), 8, '0'), 'hex') ELSE NULL END,
       DATE '2020-01-01' + (g % 1500),
       TIMESTAMPTZ '2024-01-01 00:00:00.123456+00' + (g || ' minutes')::interval
  FROM generate_series(1, 1000) g;
-- Edge numerics in the unconstrained column
UPDATE products SET weight_kg = 123456789012345678901234567890.123456789 WHERE sku = 'SKU-00001';
UPDATE products SET weight_kg = -0.000000000000000001 WHERE sku = 'SKU-00002';
UPDATE products SET weight_kg = 0 WHERE sku = 'SKU-00003';
-- updated_at distinct from created_at on some rows (trigger sets now(); override after)
ALTER TABLE products DISABLE TRIGGER products_touch;
UPDATE products SET updated_at = created_at + interval '1 day 00:00:00.654321' WHERE product_id % 3 = 0;
UPDATE products SET updated_at = created_at WHERE product_id % 3 <> 0;
ALTER TABLE products ENABLE TRIGGER products_touch;

INSERT INTO product_prices
SELECT p.product_id, DATE '2023-01-01' + (k * 90), p.price * (1 + k / 10.0), CASE WHEN k = 2 THEN 'promo' END
  FROM products p, generate_series(0, 2) k WHERE p.product_id % 2 = 0;

INSERT INTO customers (email, full_name, phone, password_hash, api_token, reset_otp, last_ip, birth_date, loyalty_pts, signed_up_at, updated_at)
SELECT 'user' || g || '@example.com',
       CASE WHEN g % 20 = 0 THEN '王小明 ' || g ELSE 'Customer ' || g END,
       CASE WHEN g % 3 = 0 THEN NULL ELSE '+62812' || lpad(g::text, 7, '0') END,
       '$2a$10$' || md5(g::text) || md5((g * 2)::text),
       CASE WHEN g % 2 = 0 THEN 'tok_' || md5((g * 3)::text) END,
       CASE WHEN g % 10 = 0 THEN lpad((g % 1000000)::text, 6, '0') END,
       CASE WHEN g % 4 = 0 THEN NULL WHEN g % 4 = 1 THEN ('10.0.' || (g % 250) || '.' || (g % 200 + 1))::inet ELSE ('2001:db8::' || to_hex(g))::inet END,
       CASE WHEN g % 5 = 0 THEN NULL ELSE DATE '1960-01-01' + (g * 37 % 15000) END,
       g * 13 % 5000,
       TIMESTAMP '2023-06-01 08:30:15.250' + (g || ' hours')::interval,
       TIMESTAMPTZ '2024-02-01 00:00:00.5+00' + (g || ' minutes')::interval
  FROM generate_series(1, 200) g;

INSERT INTO orders (order_id, customer_id, status, currency, total, pickup_slot, pickup_eta, meta, placed_at, delivered_at, updated_at)
SELECT ('00000000-0000-4000-8000-' || lpad(g::text, 12, '0'))::uuid,
       (g % 200) + 1,
       (ARRAY['new','paid','packed','shipped','delivered','cancelled','refund-pending'])[g % 7 + 1]::order_status,
       CASE WHEN g % 11 = 0 THEN 'USD' ELSE 'IDR' END,
       (g * 7919 % 9000000) / 100.0,
       CASE WHEN g % 3 = 0 THEN NULL ELSE TIME '08:00' + (g % 600 || ' minutes')::interval END,
       CASE WHEN g % 4 = 0 THEN NULL ELSE (g % 90 || ' minutes ' || g % 59 || ' seconds')::interval END,
       CASE WHEN g % 5 = 0 THEN NULL ELSE jsonb_build_object('channel', CASE WHEN g % 2 = 0 THEN 'web' ELSE 'pos' END, 'items', g % 6, 'note', 'a "b" c') END,
       TIMESTAMPTZ '2025-01-01 00:00:00.000001+00' + (g * 17 || ' minutes')::interval,
       CASE WHEN g % 7 IN (4, 5) THEN TIMESTAMP '2025-01-02 13:45:10.5' + (g * 17 || ' minutes')::interval END,
       TIMESTAMPTZ '2025-01-01 00:00:00+00' + (g * 17 + 5 || ' minutes')::interval
  FROM generate_series(1, 1500) g;

INSERT INTO order_items (order_id, product_id, qty, unit_price, discount, created_at)
SELECT o.order_id, ((o.n * 31 + k * 97) % 1000) + 1, (k % 5) + 1,
       ((o.n * 31 + k * 97) % 1000 + 1) * 1.25, CASE WHEN k = 2 THEN 0.0525 ELSE 0 END,
       o.placed_at + (k || ' seconds')::interval
  FROM (SELECT order_id, placed_at, row_number() OVER (ORDER BY order_id) AS n FROM orders) o,
       generate_series(1, 3) k;
INSERT INTO order_items (order_id, product_id, qty, unit_price, discount, created_at)
SELECT order_id, 1, 1, 0.01, 0.9999, placed_at FROM orders WHERE order_id::text LIKE '%0000';

INSERT INTO stock_movements (product_id, delta, reason, created_at)
SELECT (g % 1000) + 1, CASE WHEN g % 3 = 0 THEN -(g % 20) - 1 ELSE g % 50 + 1 END,
       (ARRAY['restock','sale','shrinkage','adjustment'])[g % 4 + 1],
       TIMESTAMPTZ '2025-01-01 00:00:00.5+00' + (g * 3 || ' minutes')::interval
  FROM generate_series(1, 3000) g;

-- event_log: no PK; deliberate exact duplicate rows
INSERT INTO event_log (ts, kind, payload, amount)
SELECT TIMESTAMPTZ '2025-03-01 00:00:00.000999+00' + (g || ' seconds')::interval,
       (ARRAY['login','view','cart','checkout','error'])[g % 5 + 1],
       CASE WHEN g % 3 = 0 THEN NULL ELSE jsonb_build_object('n', g) END,
       CASE WHEN g % 4 = 0 THEN NULL ELSE (g % 1000) / 8.0 END
  FROM generate_series(1, 2000) g;
INSERT INTO event_log (ts, kind, payload, amount) SELECT ts, kind, payload, amount FROM event_log WHERE kind = 'error' AND amount IS NOT NULL LIMIT 20;

INSERT INTO user_sessions
SELECT 'sess_' || md5(g::text), g, TIMESTAMPTZ '2026-01-01 00:00:00+00' + (g || ' hours')::interval
  FROM generate_series(1, 50) g;

INSERT INTO "Legacy Notes" VALUES (1, 'first note', '2024-05-05 05:05:05+00'), (2, NULL, '2024-05-06 06:06:06.789+00');

-- Move the stand-alone sequence and the identity sequences to non-trivial values
SELECT setval('invoice_no_seq', 5000) \g /dev/null
REFRESH MATERIALIZED VIEW mv_product_sales;
ANALYZE;
