-- ============================================================
-- minimart (Postgres) -> ClickHouse database `minimart`: SQL TEMPLATES
--
-- Not run directly. scripts/minimart_gen_schema.sh puts these templates into the
-- planner query; `scripts/minimart_sync.sh --init` runs that query against the
-- Postgres catalog (through the read-only role minimart_ro) and stores one filled-in
-- copy per table in minimart._plan. A sync run then only substitutes the run-time
-- placeholders and pipes the stored script into clickhouse-client --multiquery.
--
-- READ-ONLY towards Postgres: the only thing ever done there is SELECT, through
-- the ENGINE = PostgreSQL tables minimart._src_<table> (named collection
-- pg_minimart, db/clickhouse-config.d/50-pg-minimart.xml). Nothing here writes to
-- the minimart database.
--
-- WHY THE SOURCE TABLE IS CREATED AND DROPPED INSIDE EVERY SCRIPT. An ENGINE = PostgreSQL table keeps its
-- connection to Postgres open for as long as the table exists (ClickHouse pools it per table and never
-- closes it), and minimart_ro has CONNECTION LIMIT 20: with one permanent source table per mirrored
-- table the 21st table would be locked out. Created at the start of a table's script and dropped
-- before its watermark is written, at most one source connection is open at a time. (A table
-- function, postgresql(...), closes its connection with the query, but cannot be given column
-- types, and an unconstrained numeric needs String: see the type mapping in the generator.)
--
-- Syntax of this file: a template starts at `-- @@TEMPLATE <name>` and ends at
-- `-- @@END`. Lines outside templates are comments. Placeholders are @NAME@.
--
-- Filled in at plan time (by --init, from the catalog; fixed in the stored plan)
--   @T@           the mirror table, back-quoted           `orders`
--   @NEW@         its staging copy                        `_new_orders`
--   @SRC@         the ENGINE = PostgreSQL source table    `_src_orders`
--   @SRC_DDL@     CREATE OR REPLACE TABLE minimart.`_src_orders` (...) ENGINE = PostgreSQL(...)
--   @T_LIT@       the table name as a string literal      'orders'
--   @DEST_COLS@   `col` Type, ...      (the mirror's columns)
--   @COLS@        `col`, ...           (mirrored columns, Postgres order)
--   @EXPRS@       one conversion expression per column, reading from alias s
--   @ENGINE@      MergeTree | ReplacingMergeTree[(`version col`)]
--   @ORDER_BY@    (`pk1`, `pk2`) or tuple()
--   @CHG@         the change column of an incremental table, back-quoted
--   @SINCE_VAR@  becomes @SINCE@ (timestamptz change column) or @SINCE_PAD@ (naive timestamp)
--   @OR_NULL@     ` OR s.`chg` IS NULL` when the change column is nullable, else empty
--   @PK_EXPRS@    the key's conversion expressions (left side of the anti-join)
--   @PK_COLS@     the key's back-quoted mirror columns (right side of the anti-join)
--   @PLAN_HASH@   hash of everything above; a changed plan forces a full reload
-- Filled in at run time (by scripts/minimart_sync.sh)
--   @RUN_START@   this run's start in UTC 'YYYY-MM-DD hh:mm:ss.fff', the new watermark
--   @MODE@        'full' or 'incremental'
--   @SINCE@       the table's watermark minus the overlap (default 60 min), UTC
--   @SINCE_PAD@   the same minus one more day (naive `timestamp` columns whose
--                 time zone is unknown: see the strategy notes below)
--   @MAX_EXEC@    seconds a statement may run (the script's per-call timeout)
--   @HASH_MAX_ROWS@  only in verify: size cap for the content hash
--
-- STRATEGIES (chosen per table by --init, rule in scripts/minimart_gen_schema.sh)
--   snapshot             _new copy loaded from Postgres, then EXCHANGE TABLES (atomic),
--                        then the old copy is dropped. All loading happens before the
--                        swap, so a failed load leaves the live table untouched; updates
--                        and deletes propagate. Used for small tables, tables without a
--                        usable primary key or change column, and by --full for every table.
--   incremental_updated  primary key + an updated_at-like column. Rows whose column is newer
--                        than @SINCE@ are inserted into a ReplacingMergeTree (version = the
--                        column when it is NOT NULL, else last insert wins). A re-sent row
--                        collapses on merge; query with FINAL. Hard deletes arrive only with
--                        the nightly --full.
--   incremental_created  primary key + an append-only created_at-like column. Same, but a row
--                        whose key is already in the mirror is not sent again (anti-join), so
--                        the table holds each row once physically. Updates and deletes arrive
--                        only with the nightly --full.
--
-- The window compares the RAW Postgres column through the pushed-down WHERE (the string
-- literal is cast by Postgres itself in the UTC-pinned session of minimart_ro, so no
-- ClickHouse time zone is involved). Wrapping the column in a function would stop the
-- push-down and make every run read the whole table: keep it a plain comparison.
-- ============================================================

-- @@TEMPLATE snapshot
SET max_execution_time = @MAX_EXEC@;
@SRC_DDL@;
DROP TABLE IF EXISTS minimart.@NEW@ SYNC;
CREATE TABLE minimart.@NEW@ (@DEST_COLS@) ENGINE = @ENGINE@ ORDER BY @ORDER_BY@;
INSERT INTO minimart.@NEW@ (@COLS@)
SELECT @EXPRS@
FROM minimart.@SRC@ AS s;
CREATE TABLE IF NOT EXISTS minimart.@T@ (@DEST_COLS@) ENGINE = @ENGINE@ ORDER BY @ORDER_BY@;
EXCHANGE TABLES minimart.@NEW@ AND minimart.@T@;
DROP TABLE IF EXISTS minimart.@NEW@ SYNC;
DROP TABLE IF EXISTS minimart.@SRC@ SYNC;
INSERT INTO minimart._sync_state (table_name, run_at, synced_through, mode, plan_hash)
VALUES (@T_LIT@, now64(3, 'UTC'), toDateTime64('@RUN_START@', 3, 'UTC'), '@MODE@', '@PLAN_HASH@');
-- @@END

-- @@TEMPLATE incremental_updated
SET max_execution_time = @MAX_EXEC@;
@SRC_DDL@;
CREATE TABLE IF NOT EXISTS minimart.@T@ (@DEST_COLS@) ENGINE = @ENGINE@ ORDER BY @ORDER_BY@;
INSERT INTO minimart.@T@ (@COLS@)
SELECT @EXPRS@
FROM minimart.@SRC@ AS s
WHERE (s.@CHG@ > '@SINCE_VAR@'@OR_NULL@);
DROP TABLE IF EXISTS minimart.@SRC@ SYNC;
INSERT INTO minimart._sync_state (table_name, run_at, synced_through, mode, plan_hash)
VALUES (@T_LIT@, now64(3, 'UTC'), toDateTime64('@RUN_START@', 3, 'UTC'), '@MODE@', '@PLAN_HASH@');
-- @@END

-- @@TEMPLATE incremental_created
SET max_execution_time = @MAX_EXEC@;
@SRC_DDL@;
CREATE TABLE IF NOT EXISTS minimart.@T@ (@DEST_COLS@) ENGINE = @ENGINE@ ORDER BY @ORDER_BY@;
INSERT INTO minimart.@T@ (@COLS@)
SELECT @EXPRS@
FROM minimart.@SRC@ AS s
WHERE (s.@CHG@ > '@SINCE_VAR@'@OR_NULL@)
  AND (@PK_EXPRS@) NOT IN (SELECT @PK_COLS@ FROM minimart.@T@
                            WHERE @CHG@ > toDateTime64('@SINCE_VAR@', 6, 'UTC') - INTERVAL 1 DAY);
DROP TABLE IF EXISTS minimart.@SRC@ SYNC;
INSERT INTO minimart._sync_state (table_name, run_at, synced_through, mode, plan_hash)
VALUES (@T_LIT@, now64(3, 'UTC'), toDateTime64('@RUN_START@', 3, 'UTC'), '@MODE@', '@PLAN_HASH@');
-- @@END

-- Verification: one SELECT per table that yields one row per metric,
-- (tbl, metric, pg, ch, kind). Both sides are computed by ClickHouse, with the SAME
-- conversion expressions as the sync: pg from the ENGINE = PostgreSQL source (a live read of
-- Postgres), ch from the mirror table. kind 'float' is compared with a relative tolerance
-- (the summation order differs), everything else must be identical text.
--   @TBL_LIT@  table name literal      @METRIC_NAMES@  Array(String)    @METRIC_KINDS@  Array(String)
--   @PG_VALS@  Array(String) of toString(aggregate) over the source (alias s)
--   @CH_VALS@  the same aggregates over the mirror (@CH_FROM@ = `t` or `t` FINAL)
-- @@TEMPLATE verify
SELECT @TBL_LIT@ AS tbl, m.1 AS metric, m.2 AS pg, m.3 AS ch, m.4 AS kind
FROM (SELECT p.v AS pv, c.v AS cv
      FROM (SELECT @PG_VALS@ AS v FROM minimart.@SRC@ AS s) AS p
      CROSS JOIN (SELECT @CH_VALS@ AS v FROM minimart.@CH_FROM@) AS c)
ARRAY JOIN arrayZip(@METRIC_NAMES@, pv, cv, @METRIC_KINDS@) AS m
-- @@END
