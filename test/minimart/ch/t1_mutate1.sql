-- Round 1A of test/minimart/ch/run_sync_test.sh: updates, inserts, NULL <-> value changes everywhere, and
-- hard deletes ONLY in snapshot tables (so that --verify must pass right after the next sync).
-- Rows with an old updated_at / created_at that are still inside the 60 minute overlap window are
-- inserted too (they must be picked up by the next incremental run). Run as the superuser, in mmc_a only.
SET timezone = 'UTC';
SET client_min_messages = warning;

-- ---- products (incremental_updated; the trigger moves updated_at) ----
UPDATE products SET name = E'Renamed 🍜 "q" ''s \\ back\tslash', price = price + 1.11, active = NOT active,
                    tags = ARRAY['n1', 'x"y', 'a,b', '', 'back\slash'] WHERE product_id IN (1, 2, 3);
UPDATE products SET weight_kg = NULL, rating = NULL WHERE product_id = 8;                       -- value -> NULL
UPDATE products SET weight_kg = -98765432109876543210.5, margin = '-0'::float8, rating = 3.4028235e38,
                    dims_mm = NULL WHERE product_id = 4;                                        -- NULL -> value
UPDATE products SET category_id = NULL WHERE product_id = 10;                                   -- value -> NULL
UPDATE products SET category_id = 3, attrs = '{"k": [1, 2, {"z": null}], "s": "x\ty", "e": ""}' WHERE product_id = 17;  -- NULL -> value
UPDATE products SET tags = '{}', dims_mm = '{}' WHERE product_id = 20;                          -- empty arrays
UPDATE products SET attrs = NULL WHERE product_id = 2;
INSERT INTO products (sku, name, category_id, price, weight_kg, rating, margin, active, tags, dims_mm, attrs, photo, released_on)
VALUES ('SKU-NEW-01', E'new\nline "quoted" 日本語 😀', 2, 0.01, 1e-30, 0.5, 1e300, true, ARRAY['a', NULL, 'c'], ARRAY[1, NULL, 3], '{"n": 1.50}', '\xdeadbeef', DATE '2031-12-31'),
       ('SKU-NEW-02', 'plain', NULL, 99999999.99, NULL, NULL, NULL, false, '{}', NULL, NULL, NULL, NULL);
-- old updated_at/created_at, but inside the 60 minute overlap: must still arrive
INSERT INTO products (sku, name, category_id, price, active, created_at, updated_at)
VALUES ('SKU-NEW-03', 'inside the overlap window', 1, 1.00, true, now() - interval '45 minutes 123456 microseconds', now() - interval '30 minutes 654321 microseconds');

-- ---- customers (incremental_updated; sensitive columns change too) ----
UPDATE customers SET full_name = E'Renamed ''Cust'' \\ 王', phone = NULL, birth_date = DATE '1999-12-31', last_ip = '192.168.0.1',
                     api_token = 'tok_NEWSECRET_AAAA', password_hash = '$2a$10$NEWSECRETHASHAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA' WHERE customer_id = 7;
UPDATE customers SET phone = '+62999', loyalty_pts = loyalty_pts + 1, signed_up_at = TIMESTAMP '2030-02-03 04:05:06.000007' WHERE customer_id = 3;
INSERT INTO customers (email, full_name, phone, password_hash, api_token, reset_otp, last_ip, birth_date, loyalty_pts, signed_up_at)
VALUES ('new1@example.com', 'New One', NULL, '$2a$10$NEWSECRETHASHBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB', 'tok_NEWSECRET_BBBB', '123456', '::1', NULL, 5, TIMESTAMP '2024-01-01 00:00:00.000001'),
       ('new2@example.com', 'New "Two"', '', 'x', NULL, NULL, NULL, DATE '1900-01-01', 0, TIMESTAMP '1969-12-31 23:59:59.999999');
INSERT INTO customers (email, full_name, password_hash, updated_at)
VALUES ('new3@example.com', 'inside the overlap window', 'x', now() - interval '20 minutes');

-- ---- orders (incremental_updated, uuid key, enum, interval, time) ----
UPDATE orders SET status = 'delivered', total = total + 5.55 WHERE order_id = '00000000-0000-4000-8000-000000000001';
UPDATE orders SET delivered_at = NULL WHERE order_id IN (SELECT order_id FROM orders WHERE delivered_at IS NOT NULL ORDER BY order_id LIMIT 3);  -- value -> NULL
UPDATE orders SET delivered_at = TIMESTAMP '2030-12-31 23:59:59.999999', pickup_eta = interval '1 day 02:03:04.5', pickup_slot = '23:59:59.999999',
                  meta = '[]'::jsonb WHERE order_id = '00000000-0000-4000-8000-000000000002';  -- NULL -> value
UPDATE orders SET meta = NULL, pickup_slot = NULL WHERE order_id = '00000000-0000-4000-8000-000000000004';
INSERT INTO orders (order_id, customer_id, status, currency, total, pickup_slot, pickup_eta, meta, placed_at, delivered_at)
VALUES ('bbbbbbbb-0000-4000-8000-000000000001', 1, 'refund-pending', 'EUR', 0, NULL, NULL, NULL, now(), NULL),
       ('bbbbbbbb-0000-4000-8000-000000000002', 2, 'cancelled', 'IDR', 123456789012.34, '00:00', interval '-5 minutes', '{"a": {"b": [null, true]}}', TIMESTAMPTZ '1999-12-31 23:59:59.999999+00', TIMESTAMP '1999-12-31 23:59:59.999999');
INSERT INTO orders (order_id, customer_id, total, placed_at, updated_at)
VALUES ('bbbbbbbb-0000-4000-8000-000000000003', 3, 1, now() - interval '50 minutes', now() - interval '25 minutes');   -- inside the overlap

-- ---- order_items / stock_movements (incremental_created, append-only) ----
INSERT INTO order_items (order_id, product_id, qty, unit_price, discount, created_at) VALUES
  ('bbbbbbbb-0000-4000-8000-000000000001', 1, 2, 12.50, 0, now()),
  ('bbbbbbbb-0000-4000-8000-000000000001', 2, 1, 0.01, 0.0001, now() + interval '1 second'),
  ('bbbbbbbb-0000-4000-8000-000000000002', 3, 7, 99999999.99, 0.9999, now() - interval '40 minutes 999999 microseconds'),   -- old created_at, inside the overlap
  ('bbbbbbbb-0000-4000-8000-000000000003', 4, 1, 1, 0, now() - interval '59 minutes');                                      -- near the end of the overlap
INSERT INTO stock_movements (product_id, delta, reason, created_at) VALUES
  (1, -3, E'sale "x" \\ y', now()), (2, 10, 'restock 补货', now() - interval '30 minutes'), (3, 0, '', now() + interval '2 minutes');

-- ---- snapshot tables: update / insert / DELETE ----
UPDATE categories SET name = 'Snacks (renamed)', sort_order = -1 WHERE category_id = 1;
INSERT INTO categories VALUES (6, 'Frozen 🧊', 60), (7, E'tab\there', 70);
UPDATE settings SET value = 'x' WHERE key = 'open_hours';
UPDATE settings SET value = NULL WHERE key = 'currency';
UPDATE settings SET value = 'filled' WHERE key = 'null_value';
DELETE FROM settings WHERE key = 'store_name';
INSERT INTO settings VALUES ('new_key', E'a''b"c\\d'), ('', NULL);
UPDATE product_prices SET price = price * 2, note = NULL WHERE product_id = 4 AND valid_from = DATE '2023-01-01';
DELETE FROM product_prices WHERE product_id = 2;
INSERT INTO product_prices VALUES (6, DATE '2031-01-01', 0.0001, 'new'), (8, DATE '1999-01-01', -5.5, NULL);
UPDATE event_log SET amount = 99.999 WHERE ctid IN (SELECT ctid FROM event_log WHERE kind = 'view' ORDER BY ts LIMIT 3);
UPDATE event_log SET payload = NULL WHERE ctid IN (SELECT ctid FROM event_log WHERE kind = 'cart' AND payload IS NOT NULL ORDER BY ts LIMIT 2);
DELETE FROM event_log WHERE ctid IN (SELECT ctid FROM event_log WHERE kind = 'login' ORDER BY ts LIMIT 5);
INSERT INTO event_log (ts, kind, payload, amount) VALUES (now(), 'new', '{"a": 1}', -5.5), (now(), 'new', '{"a": 1}', -5.5), (now(), 'new', NULL, NULL);
UPDATE "Legacy Notes" SET "Note Text" = E'new\ntext', "Created" = NULL WHERE "Note Id" = 1;
DELETE FROM "Legacy Notes" WHERE "Note Id" = 2;
INSERT INTO "Legacy Notes" VALUES (3, NULL, TIMESTAMPTZ '1970-01-01 00:00:00.000001+00'), (4, '日本語 😀', now());
DELETE FROM user_sessions WHERE customer_id IN (1, 2, 3, 4, 5);
UPDATE user_sessions SET expires_at = expires_at + interval '1 day' WHERE customer_id IN (6, 7);
INSERT INTO user_sessions VALUES ('sess_NEWSECRET_CCCC', 9, now() + interval '1 day'), ('sess_NEWSECRET_DDDD', NULL, now());
INSERT INTO empty_table VALUES (1, 'one'), (2, NULL);
