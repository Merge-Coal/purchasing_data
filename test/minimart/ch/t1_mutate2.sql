-- Round 1B of test/minimart/ch/run_sync_test.sh: what an incremental run cannot see (documented limits).
--   * hard deletes in incremental tables (arrive with --full only)
--   * updates of an append-only (incremental_created) table (arrive with --full only)
--   * "late" rows: a created_at / updated_at older than watermark - 60 minutes (arrive with --full only)
-- plus a snapshot table that becomes empty again. Run as the superuser, in mmc_a only.
SET timezone = 'UTC';
SET client_min_messages = warning;

DELETE FROM order_items WHERE order_item_id IN (10, 11, 12);
DELETE FROM stock_movements WHERE movement_id <= 5;
DELETE FROM order_items WHERE product_id = 999;
DELETE FROM stock_movements WHERE product_id = 999;
DELETE FROM products WHERE product_id = 999;                       -- product_prices cascade
DELETE FROM user_sessions WHERE customer_id = 150;
DELETE FROM orders WHERE customer_id = 150;                        -- order_items cascade
DELETE FROM customers WHERE customer_id = 150;
UPDATE order_items SET qty = qty + 10 WHERE order_item_id = 20;   -- append-only table: not propagated by incremental runs

INSERT INTO products (sku, name, price, created_at, updated_at) VALUES ('SKU-LATE-01', 'late arrival', 1, now() - interval '5 hours', now() - interval '5 hours');
INSERT INTO customers (email, full_name, password_hash, updated_at) VALUES ('late@example.com', 'late arrival', 'x', now() - interval '5 hours');
INSERT INTO orders (order_id, customer_id, placed_at, updated_at) VALUES ('bbbbbbbb-0000-4000-8000-0000000000aa', 4, now() - interval '5 hours', now() - interval '5 hours');
INSERT INTO order_items (order_id, product_id, qty, unit_price, created_at) VALUES ('bbbbbbbb-0000-4000-8000-0000000000aa', 5, 1, 1, now() - interval '5 hours');
INSERT INTO stock_movements (product_id, delta, reason, created_at) VALUES (5, 1, 'late arrival', now() - interval '5 hours');

DELETE FROM empty_table;                                           -- snapshot goes back to zero rows
