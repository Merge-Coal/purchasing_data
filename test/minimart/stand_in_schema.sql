-- ============================================================
-- Minimart STAND-IN schema (test fixture, invented: the real minimart schema
-- is unknown). Shared by Agent M (test/minimart/migrate/) and Agent C
-- (test/minimart/ch/). Owned by Agent M.
--
-- Plain Postgres 14+ SQL, no extensions, no roles/owners/grants, so it loads
-- into any empty database as any user:
--   psql -v ON_ERROR_STOP=1 -X -d <db> -f test/minimart/stand_in_schema.sql
--   psql -v ON_ERROR_STOP=1 -X -d <db> -f test/minimart/stand_in_seed.sql
--
-- Everything in `public`. Coverage checklist (what each table is for):
--   categories        tiny lookup, smallint PK, no sequence
--   settings          tiny lookup, text PK, no timestamps
--   products          identity PK (GENERATED ALWAYS), uuid, numeric(12,2),
--                     UNCONSTRAINED numeric, real/double, bool, text[], int[],
--                     jsonb, bytea, date, timestamptz created_at + updated_at
--                     (trigger-maintained), FK, CHECK, unique
--   product_prices    COMPOSITE primary key, numeric(12,4), date
--   customers         serial PK, sensitive columns (password_hash, api_token,
--                     reset_otp), timestamp WITHOUT tz, updated_at, inet, citext-free
--   orders            uuid PK, enum status, interval, time, char(3), jsonb,
--                     timestamptz + timestamp (local wall clock) columns,
--                     FK to customers, updated_at
--   order_items       bigserial PK, FKs to orders + products, numeric(5,4)
--   stock_movements   APPEND-ONLY (bigserial PK, created_at only, no updated_at)
--   event_log         NO primary key, no updated_at, created-at-like `ts`
--   user_sessions     text PK that is itself a secret (`token`) + expires_at
--   empty_table       zero rows
--   "Legacy Notes"    mixed-case name with a space + quoted column names
--   invoice_no_seq    stand-alone sequence (not owned by a column)
--   v_order_totals    plain view;  mv_product_sales  materialized view
--   order_status      enum;  money_amount  domain over numeric(14,2)
--   touch_updated_at()  trigger function
-- Tables with an updated_at: products, customers, orders.
-- Append-only with a created_at: stock_movements, order_items.
-- No primary key: event_log.
-- ============================================================

CREATE TYPE order_status AS ENUM ('new', 'paid', 'packed', 'shipped', 'delivered', 'cancelled', 'refund-pending');
CREATE DOMAIN money_amount AS numeric(14,2) CHECK (VALUE >= 0);

CREATE FUNCTION touch_updated_at() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END $$;

CREATE SEQUENCE invoice_no_seq START WITH 1000 INCREMENT BY 1;

CREATE TABLE categories (
  category_id smallint PRIMARY KEY,
  name        text NOT NULL UNIQUE,
  sort_order  integer NOT NULL DEFAULT 0
);

CREATE TABLE settings (
  key   text PRIMARY KEY,
  value text
);

CREATE TABLE products (
  product_id   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  public_id    uuid NOT NULL DEFAULT gen_random_uuid(),
  sku          varchar(32) NOT NULL UNIQUE,
  name         text NOT NULL,
  category_id  smallint REFERENCES categories(category_id),
  price        numeric(12,2) NOT NULL CHECK (price >= 0),
  weight_kg    numeric,                    -- unconstrained numeric
  rating       real,
  margin       double precision,
  active       boolean NOT NULL DEFAULT true,
  tags         text[] NOT NULL DEFAULT '{}',
  dims_mm      integer[],
  attrs        jsonb,
  photo        bytea,
  released_on  date,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX products_tags_idx ON products USING gin (tags);
CREATE INDEX products_category_idx ON products (category_id);
CREATE TRIGGER products_touch BEFORE UPDATE ON products
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

CREATE TABLE product_prices (
  product_id  bigint NOT NULL REFERENCES products(product_id) ON DELETE CASCADE,
  valid_from  date NOT NULL,
  price       numeric(12,4) NOT NULL,
  note        text,
  PRIMARY KEY (product_id, valid_from)
);

CREATE TABLE customers (
  customer_id   serial PRIMARY KEY,
  email         text NOT NULL UNIQUE,
  full_name     text NOT NULL,
  phone         text,
  password_hash text NOT NULL,             -- sensitive
  api_token     text,                      -- sensitive
  reset_otp     varchar(8),                -- sensitive
  last_ip       inet,
  birth_date    date,
  loyalty_pts   integer NOT NULL DEFAULT 0,
  signed_up_at  timestamp NOT NULL DEFAULT (now() AT TIME ZONE 'UTC'),  -- timestamp WITHOUT tz
  updated_at    timestamptz NOT NULL DEFAULT now()
);
CREATE TRIGGER customers_touch BEFORE UPDATE ON customers
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

CREATE TABLE orders (
  order_id      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  invoice_no    bigint NOT NULL DEFAULT nextval('invoice_no_seq'),
  customer_id   integer NOT NULL REFERENCES customers(customer_id),
  status        order_status NOT NULL DEFAULT 'new',
  currency      char(3) NOT NULL DEFAULT 'IDR',
  total         money_amount NOT NULL DEFAULT 0,
  pickup_slot   time,
  pickup_eta    interval,
  meta          jsonb,
  placed_at     timestamptz NOT NULL DEFAULT now(),
  delivered_at  timestamp,                 -- local wall-clock, no tz
  updated_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX orders_customer_idx ON orders (customer_id, placed_at);
CREATE TRIGGER orders_touch BEFORE UPDATE ON orders
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

CREATE TABLE order_items (
  order_item_id bigserial PRIMARY KEY,
  order_id      uuid NOT NULL REFERENCES orders(order_id) ON DELETE CASCADE,
  product_id    bigint NOT NULL REFERENCES products(product_id),
  qty           integer NOT NULL CHECK (qty > 0),
  unit_price    numeric(12,2) NOT NULL,
  discount      numeric(5,4) NOT NULL DEFAULT 0,
  created_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX order_items_order_idx ON order_items (order_id);

CREATE TABLE stock_movements (
  movement_id bigserial PRIMARY KEY,
  product_id  bigint NOT NULL REFERENCES products(product_id),
  delta       integer NOT NULL,
  reason      text NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE event_log (                    -- no primary key, duplicates allowed
  ts      timestamptz NOT NULL DEFAULT now(),
  kind    text NOT NULL,
  payload jsonb,
  amount  numeric(10,3)
);

CREATE TABLE user_sessions (
  token      text PRIMARY KEY,              -- sensitive primary key
  customer_id integer REFERENCES customers(customer_id) ON DELETE CASCADE,
  expires_at timestamptz NOT NULL
);

CREATE TABLE empty_table (
  id    integer PRIMARY KEY,
  label text
);

CREATE TABLE "Legacy Notes" (
  "Note Id"   integer PRIMARY KEY,
  "Note Text" text,
  "Created"   timestamptz DEFAULT now()
);

CREATE VIEW v_order_totals AS
  SELECT o.order_id, o.customer_id, o.status,
         COALESCE(sum(i.qty * i.unit_price * (1 - i.discount)), 0)::numeric(14,2) AS items_total
    FROM orders o LEFT JOIN order_items i ON i.order_id = o.order_id
   GROUP BY o.order_id, o.customer_id, o.status;

CREATE MATERIALIZED VIEW mv_product_sales AS
  SELECT product_id, sum(qty) AS units, sum(qty * unit_price)::numeric(14,2) AS revenue
    FROM order_items GROUP BY product_id;
