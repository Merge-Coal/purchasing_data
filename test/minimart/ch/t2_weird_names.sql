-- Helper of test/minimart/ch/run_drift_test.sh (section C4): tables and columns with awkward names.
-- Plain Postgres 14+ SQL; every name goes through format(%I) so quoting is done by Postgres itself.
SET client_min_messages = warning;

DO $$
DECLARE
  long63 text := repeat('t', 63);
  col63  text := repeat('c', 63);
  wide   text := '';
  vals   text := '';
  i      int;
BEGIN
  -- backtick, single quote, backslash
  EXECUTE format('CREATE TABLE %I (id integer PRIMARY KEY, %I text, updated_at timestamptz NOT NULL DEFAULT now())', 'tick`tbl', 'col`umn');
  EXECUTE format('INSERT INTO %I VALUES (1, %L), (2, NULL)', 'tick`tbl', 'x');
  EXECUTE format('CREATE TABLE %I (id integer PRIMARY KEY, %I text, v integer)', 'it''s', 'it''s col');
  EXECUTE format('INSERT INTO %I VALUES (1, %L, 5), (2, NULL, 6)', 'it''s', 'x');
  EXECUTE format('CREATE TABLE %I (id integer PRIMARY KEY, %I text)', 'back\slash', 'b\c');
  EXECUTE format('INSERT INTO %I VALUES (1, %L), (2, NULL)', 'back\slash', 'a\b');
  -- double quote (ClickHouse'' PostgreSQL engine does not escape it)
  EXECUTE format('CREATE TABLE %I (id integer PRIMARY KEY, v text)', 'dq"t');
  EXECUTE format('INSERT INTO %I VALUES (1, %L)', 'dq"t', 'x');
  EXECUTE format('CREATE TABLE dq_col (id integer PRIMARY KEY, %I text, ok text)', 'x"y');
  EXECUTE format('INSERT INTO dq_col VALUES (1, %L, %L)', 'x', 'ok');
  -- reserved / internal looking names
  EXECUTE 'CREATE TABLE _hidden (id integer PRIMARY KEY, v text)';
  EXECUTE 'INSERT INTO _hidden VALUES (1, ''x'')';
  EXECUTE 'CREATE TABLE _plan (id integer PRIMARY KEY, v text)';
  EXECUTE 'INSERT INTO _plan VALUES (1, ''x'')';
  EXECUTE 'CREATE TABLE _sync_state (id integer PRIMARY KEY, v text)';
  EXECUTE 'INSERT INTO _sync_state VALUES (1, ''x'')';
  -- @ is unsupported
  EXECUTE format('CREATE TABLE %I (id integer PRIMARY KEY, v text)', 'at@sign');
  EXECUTE format('INSERT INTO %I VALUES (1, %L)', 'at@sign', 'x');
  EXECUTE format('CREATE TABLE at_col (id integer PRIMARY KEY, %I text, ok text)', 'a@b');
  EXECUTE format('INSERT INTO at_col VALUES (1, %L, %L)', 'x', 'ok');
  -- 63 character names (the Postgres maximum)
  EXECUTE format('CREATE TABLE %I (id integer PRIMARY KEY, %I text)', long63, col63);
  EXECUTE format('INSERT INTO %I VALUES (1, %L)', long63, 'long');
  -- 131 columns
  FOR i IN 1..130 LOOP
    wide := wide || format(', c%s integer', i);
    vals := vals || format(', g * %s', i);
  END LOOP;
  EXECUTE 'CREATE TABLE wide (id integer PRIMARY KEY' || wide || ')';
  EXECUTE 'INSERT INTO wide SELECT g' || vals || ' FROM generate_series(1, 20) g';
  -- ClickHouse keywords as column names
  EXECUTE 'CREATE TABLE kw (id integer PRIMARY KEY, "select" text, "order" integer, "key" text, "index" integer, "limit" integer,
             "from" text, "table" text, "group" text, "where" text, "default" text, "null" text, "insert" text)';
  EXECUTE 'INSERT INTO kw VALUES (1, ''s'', 2, ''k'', 4, 5, ''f'', ''t'', ''g'', ''w'', ''d'', ''n'', ''i''),
                                 (2, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL)';
  -- unicode, dot, spaces
  EXECUTE format('CREATE TABLE %I (id integer PRIMARY KEY, %I text, %I text)', '表格', '列', 'naïve');
  EXECUTE format('INSERT INTO %I VALUES (1, %L, %L)', '表格', '值', 'é');
  EXECUTE format('CREATE TABLE %I (id integer PRIMARY KEY, %I text)', 'dot.name', 'a.b');
  EXECUTE format('INSERT INTO %I VALUES (1, %L)', 'dot.name', 'x');
  EXECUTE format('CREATE TABLE %I (id integer PRIMARY KEY, %I text)', 'two  spaces ', ' lead');
  EXECUTE format('INSERT INTO %I VALUES (1, %L)', 'two  spaces ', 'x');
  -- control characters (unsupported)
  EXECUTE format('CREATE TABLE %I (id integer PRIMARY KEY, v text)', E'line\nbreak');
  EXECUTE format('INSERT INTO %I VALUES (1, %L)', E'line\nbreak', 'x');
  EXECUTE format('CREATE TABLE nl_col (id integer PRIMARY KEY, %I text, ok text)', E'c\nd');
  EXECUTE format('INSERT INTO nl_col VALUES (1, %L, %L)', 'x', 'ok');
END $$;
