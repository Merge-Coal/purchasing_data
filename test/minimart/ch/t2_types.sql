-- Helper of test/minimart/ch/run_drift_test.sh (section C5): types that the stand-in schema does not have.
-- Plain Postgres 14+ SQL, no extensions.
SET client_min_messages = warning;

CREATE TYPE mood AS ENUM ('very happy', '悲しい', 'it''s ok');
CREATE TYPE pt AS (x integer, y text);

CREATE TABLE types_t (
  id integer PRIMARY KEY,
  m money, b3 bit(3), vb varbit, ttz timetz,
  a2 integer[][], a3 integer[][][],
  ta text[], na numeric(5,2)[], ua uuid[], tsa timestamp[],
  n40 numeric(40,10), n76 numeric(76,0), n77 numeric(77,0), n1000 numeric(1000,0),
  mc mood, comp pt,
  gen integer GENERATED ALWAYS AS (id * 2) STORED,
  f4 real, f8 double precision
);

INSERT INTO types_t (id, m, b3, vb, ttz, a2, a3, ta, na, ua, tsa, n40, n76, n77, n1000, mc, comp, f4, f8) VALUES
 (1, '1234.56', B'101', B'10101', '10:11:12+07',
  ARRAY[[1,2],[3,4]], ARRAY[[[1,2],[3,4]],[[5,6],[7,8]]],
  ARRAY['a,b', 'q"uote', 'back\slash', NULL, '', '{x}', 'it''s', '悲しい'],
  ARRAY[1.5, NULL, -2.25], ARRAY['a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11'::uuid, NULL],
  ARRAY['2024-01-01 10:00:00'::timestamp, NULL, '2025-06-30 23:59:59.123456'],
  123456789012345678901234567890.1234567890,
  (repeat('1234567890', 7) || '123456')::numeric,
  (repeat('1234567890', 7) || '1234567')::numeric,
  ('1' || repeat('0', 299))::numeric, 'very happy', ROW(1, 'a b')::pt, 1.5, 2.5),
 (2, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL),
 (3, '-0.01', B'000', B'', '00:00:00-12', ARRAY[[NULL,2],[3,NULL]], NULL, '{}', '{}', '{}', '{}',
  -0.0000000001, -1, 0, -5, '悲しい', ROW(NULL, NULL)::pt, 'NaN', 'Infinity'),
 (4, '9999999.99', B'111', B'1', '23:59:59.999999+14', '{{1},{2}}', '{{{1}}}',
  ARRAY[E'x\ny', E'tab\t', ''''], '{0.00}', '{}', '{}', 0, 0, 0, 0, 'it''s ok', ROW(7, '')::pt, '-Infinity', 'NaN');

-- CREATE TABLE AS: attndims is 0, so the arrays are not typed
CREATE TABLE ctas_arr AS SELECT 1 AS id, ARRAY[1,2,3] AS a, ARRAY['x','y'] AS t;
ALTER TABLE ctas_arr ADD PRIMARY KEY (id);

-- declarative partitioning: parent mirrored, children not
CREATE TABLE part (id integer, d date NOT NULL, v text, PRIMARY KEY (id, d)) PARTITION BY RANGE (d);
CREATE TABLE part_2024 PARTITION OF part FOR VALUES FROM ('2024-01-01') TO ('2025-01-01');
CREATE TABLE part_2025 PARTITION OF part FOR VALUES FROM ('2025-01-01') TO ('2026-01-01');
INSERT INTO part SELECT g, DATE '2024-01-01' + g, 'p' || g FROM generate_series(1, 20) g;
INSERT INTO part SELECT 100 + g, DATE '2025-01-01' + g, 'q' || g FROM generate_series(1, 20) g;

-- inheritance: both are plain tables for the catalog
CREATE TABLE inh_parent (id integer PRIMARY KEY, a text);
CREATE TABLE inh_child (extra integer) INHERITS (inh_parent);
INSERT INTO inh_parent VALUES (1, 'parent');
INSERT INTO inh_child VALUES (2, 'child', 9), (3, 'child2', 8);

-- a view over a mirrored table: never mirrored
CREATE VIEW v_types AS SELECT id, m FROM types_t;
