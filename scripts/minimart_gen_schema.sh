#!/usr/bin/env bash
# The introspection generator of the minimart mirror. It does NOT touch ClickHouse or
# Postgres: it only PRINTS SQL, which scripts/minimart_sync.sh runs. The SQL it prints
# is a "planner" query that ClickHouse executes against the catalog of the minimart
# Postgres database (pg_catalog + information_schema, read through the SELECT-only role
# minimart_ro and the named collection pg_minimart) and that returns, per table, the
# generated DDL and sync SQL.
#
#   scripts/minimart_gen_schema.sh --tables           planner, one row per table
#   scripts/minimart_gen_schema.sh --cols             planner, one row per column
#   scripts/minimart_gen_schema.sh --summary          planner, one single-line row per table (for --print)
#   scripts/minimart_gen_schema.sh --sql [table]      the generated statements as text (for --print)
#   scripts/minimart_gen_schema.sh --skipped          objects that are never mirrored (views, other schemas)
#   scripts/minimart_gen_schema.sh --install PLAN_ID  INSERTs that store the plan in minimart._plan*
#   scripts/minimart_gen_schema.sh --drift            live catalog vs the stored plan (schema drift)
#   scripts/minimart_gen_schema.sh --grant-args       allow_cols=/deny_cols= lines (psql -v variables of
#                                                     db/minimart_ro_grants.sql) from the overrides file
#   scripts/minimart_gen_schema.sh --check-overrides  validate the overrides file only
#   scripts/minimart_gen_schema.sh -h
#
# Environment (all optional)
#   MINIMART_OVERRIDES    overrides file, default <repo>/minimart_sync_overrides.conf (may be absent)
#   MINIMART_SMALL_ROWS   row estimate below which a table is a snapshot (default 100000)
#
# ── THE STRATEGY RULE (per table, first match wins) ──────────────────────────────────
#   0. override `exclude`, no mirrorable column, reserved name (leading underscore) -> not mirrored
#   1. override `snapshot`                                      -> snapshot
#   2. no primary key, or a key column is excluded               -> snapshot, ORDER BY tuple() (key-less)
#   3. override `incremental <table> <column> [updated|created]` -> incremental on that column
#   4. estimated rows < MINIMART_SMALL_ROWS (default 100000)    -> snapshot
#   5. primary key + an updated_at-like column                   -> incremental_updated
#   6. primary key + a created_at-like column (append-only)      -> incremental_created
#   7. otherwise                                                 -> snapshot
#   "snapshot" = full copy swapped in with EXCHANGE TABLES every run (exact: updates and
#   deletes propagate). "incremental_*" = only rows newer than the watermark minus a 60 min
#   overlap, plus the nightly --full. Row estimate = pg_class.reltuples (-1 = never
#   analysed counts as 0 -> snapshot).
#   updated_at-like (timestamp/timestamptz, in this priority order): updated_at updated_on
#   update_at updatedat updated update_time updated_time updated_date updated_ts last_updated
#   last_updated_at last_update last_modified last_modified_at modified_at modified_on modified
#   modified_time modified_date modified_ts date_modified date_updated changed_at last_changed
#   created_at-like: created_at created_on create_at createdat created create_time created_time
#   creation_time created_date created_ts date_created inserted_at insert_time inserted_on
#   added_at received_at logged_at recorded_at occurred_at
#
# ── COLUMN EXCLUSIONS (a column that is excluded is never selected) ─────────────────
#   * the column cannot be read by minimart_ro (no SELECT privilege: this is how the
#     column-level grants of db/minimart_ro_grants.sql keep secrets out)
#   * its name looks sensitive (DENY_SUBSTR / DENY_WORD below; the SAME two regexes are
#     \set deny_substr / deny_word at the top of db/minimart_ro_grants.sql: change both)
#   * bytea (binary, no analytic value, can be huge): `allow-column` mirrors it as hex text
#   * override `exclude-column`; names with control characters or @ are unsupported
#
# ── TYPE MAPPING (Postgres -> source type declared on _src_<t> -> mirror type) ───────
#   int2/int4/int8        Int16/Int32/Int64              same
#   float4/float8         Float32/Float64                same
#   numeric(p,s) p<=76    Decimal(p,s)                   Decimal(p,s)   (exact)
#   numeric (no p,s)      String                         Float64 = toFloat64(text)  (the value can exceed
#                                                        any Decimal; nearest double, as for hauling)
#   boolean               UInt8                          Bool
#   uuid                  UUID                           UUID
#   date                  String                         Date32 = toDate32(text)
#   timestamp[tz]         String                         DateTime64(6,'UTC') = parseDateTime64BestEffort(text)
#                         (minimart_ro is pinned to timezone=UTC: the text is UTC, and an offset in it is
#                          applied anyway; a naive `timestamp` keeps its wall clock, labelled UTC)
#   enum (and domains)    String                         LowCardinality(String)
#   text/varchar/char/name String                        String
#   arrays (1-3 dims)     Array(Nullable(T)) T in the int/float/uuid/numeric(p,s) types above,
#                         else String elements. A NULL array becomes [] (ClickHouse arrays are not nullable).
#                         Arrays whose dimensions Postgres does not record: whole literal as String.
#   anything else         String (the Postgres text form): json/jsonb, time, timetz, interval, inet, cidr,
#   (incl. unknown types)  macaddr, money, bit, xml, range types, geometric types, tsvector, extension types...
#   NOT NULL in Postgres -> not Nullable here.
#
# Names this file prints and fixed names: ClickHouse database `minimart`, tables
# minimart.<table>, minimart._src_<table> (source), minimart._new_<table> (staging).
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATES="$REPO_DIR/db/minimart_sync.sql"
OVERRIDES="${MINIMART_OVERRIDES:-$REPO_DIR/minimart_sync_overrides.conf}"
SMALL_ROWS="${MINIMART_SMALL_ROWS:-100000}"

# Keep in step with db/minimart_ro_grants.sql (same two constants). Applied to
# lower(camelCase -> camel_Case) of the column name.
DENY_SUBSTR='(password|passwd|passphrase|secret|token|hash|api[^a-z0-9]?key|credential|private[^a-z0-9]?key|card[^a-z0-9]?(no|num)|pincode)'
DENY_WORD='(^|[^a-z0-9])(otp|pin|pwd|salt|cvv|cvc|card)([^a-z0-9]|$)'
UPDATED_NAMES='updated_at updated_on update_at updatedat updated update_time updated_time updated_date updated_ts last_updated last_updated_at last_update last_modified last_modified_at modified_at modified_on modified modified_time modified_date modified_ts date_modified date_updated changed_at last_changed'
CREATED_NAMES='created_at created_on create_at createdat created create_time created_time creation_time created_date created_ts date_created inserted_at insert_time inserted_on added_at received_at logged_at recorded_at occurred_at'

usage() { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; }

[[ "$SMALL_ROWS" =~ ^[0-9]+$ ]] || { echo "MINIMART_SMALL_ROWS must be a number, got '$SMALL_ROWS'" >&2; exit 2; }

# ── helpers ─────────────────────────────────────────────────────────────────────────
# Escape a string for a ClickHouse single-quoted literal (no surrounding quotes).
esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e "s/'/\\\\'/g"; }
# SQL array literal of quoted names from a space-separated list.
names_array() { local out="" n; for n in $1; do out="$out${out:+, }'$n'"; done; printf '[%s]' "$out"; }

# Extract one template section of db/minimart_sync.sql.
template() { # template name
  [ -r "$TEMPLATES" ] || { echo "cannot read $TEMPLATES" >&2; exit 1; }
  awk -v name="$1" '
    $0 == "-- @@TEMPLATE " name { on = 1; next }
    /^-- @@END[ \t]*$/          { on = 0; next }
    on                          { print }' "$TEMPLATES"
}

# ── overrides file -> rows of a VALUES() table (kind, table, column, arg), or grant args ──
# Syntax (one directive per line, # starts a comment, names with spaces or capitals in "double quotes"):
#   exclude <table>
#   snapshot <table>
#   incremental <table> <column> [updated|created]
#   exclude-column <table>.<column>      allow-column <table>.<column>      string-column <table>.<column>
# overrides_parse rows   -> the SQL rows (stderr + exit 1 on a syntax error)
# overrides_parse grants -> the two psql variables for db/minimart_ro_grants.sql
overrides_parse() { # overrides_parse rows|grants
  if [ ! -r "$OVERRIDES" ]; then
    if [ "$1" = rows ]; then printf "('none', '', '', '')"; else printf 'allow_cols=\ndeny_cols=\n'; fi
    return 0
  fi
  awk -v out="$1" '
    function fail(msg) { printf "overrides file %s line %d: %s\n", FILENAME, NR, msg > "/dev/stderr"; bad = 1; err = 1 }
    function q(s) { gsub(/\\/, "\\\\", s); gsub(/\047/, "\\\047", s); return "\047" s "\047" }
    # read one name starting at pos of line; sets TOK and pos. Quoted: "..." with "" for a quote.
    function name(    c) {
      TOK = ""; c = substr(line, pos, 1)
      if (c == "\"") {
        pos++
        while (1) {
          if (pos > length(line)) return 0
          c = substr(line, pos, 1)
          if (c == "\"") { if (substr(line, pos + 1, 1) == "\"") { TOK = TOK "\""; pos += 2; continue } pos++; return 1 }
          TOK = TOK c; pos++
        }
      }
      while (pos <= length(line)) { c = substr(line, pos, 1); if (c ~ /[ \t.]/) break; TOK = TOK c; pos++ }
      return TOK != ""
    }
    function skipws() { while (substr(line, pos, 1) ~ /[ \t]/) pos++ }
    function more() { return pos <= length(line) && substr(line, pos, 1) != "#" }
    # (no `next` inside functions: BSD awk rejects it; errors are flagged in `err` and checked below)
    {
      err = 0
      line = $0; sub(/\r$/, "", line)
      pos = 1; skipws()
      if (pos > length(line) || substr(line, pos, 1) == "#") next
      kind = ""
      while (pos <= length(line) && substr(line, pos, 1) !~ /[ \t]/) { kind = kind substr(line, pos, 1); pos++ }
      skipws()
      t = ""; c = ""; a = ""
      if (kind == "exclude" || kind == "snapshot") {
        if (!name()) fail("expected a table name after " kind); t = TOK; skipws()
        if (!err && more()) fail("unexpected text after the table name")
      } else if (kind == "incremental") {
        if (!name()) fail("expected a table name"); t = TOK; skipws()
        if (!err && !name()) fail("expected a column name"); c = TOK; skipws()
        a = "updated"
        if (!err && more()) {
          if (!name()) fail("expected updated or created"); a = TOK; skipws()
          if (!err && a != "updated" && a != "created") fail("the last word must be updated or created, not " a)
          if (!err && more()) fail("unexpected text at the end")
        }
      } else if (kind == "exclude-column" || kind == "allow-column" || kind == "string-column") {
        if (!name()) fail("expected <table>.<column>"); t = TOK
        if (!err && substr(line, pos, 1) != ".") fail("expected <table>.<column>: a dot between them, names with spaces in double quotes")
        if (!err) { pos++
          if (!name()) fail("expected a column name after the dot"); c = TOK; skipws() }
        if (!err && more()) fail("unexpected text at the end")
        if (!err && out == "grants") {
          if (kind == "allow-column") allow = allow (allow == "" ? "" : ",") t "." c
          if (kind == "exclude-column") deny = deny (deny == "" ? "" : ",") t "." c
        }
      } else fail("unknown directive \"" kind "\" (valid: exclude, snapshot, incremental, exclude-column, allow-column, string-column)")
      if (err) next
      rows[++n] = "(" q(kind) ", " q(t) ", " q(c) ", " q(a) ")"
    }
    END {
      if (bad) exit 1
      if (out == "grants") { printf "allow_cols=%s\ndeny_cols=%s\n", allow, deny; exit 0 }
      if (n == 0) { printf "(\047none\047, \047\047, \047\047, \047\047)"; exit 0 }
      for (i = 1; i <= n; i++) printf "%s%s", (i > 1 ? ", " : ""), rows[i]
    }' "$OVERRIDES"
}

# Nested replaceAll(...) chain over an SQL expression: fill_chain <template-expr> <ph|expr>...
# (each pair is a placeholder and the SQL expression that replaces it)
fill_chain() {
  local tpl="$1" i out="" pair
  shift
  for ((i = 0; i < $#; i++)); do out="${out}replaceAll("; done
  out="$out$tpl"
  for pair in "$@"; do out="${out}, '${pair%%|*}', ${pair#*|})"; done
  printf '%s' "$out"
}

PLAN_PAIRS=(
  '@T_LIT@|lit(tbl)' '@NEW@|q_new' '@SRC_DDL@|src_ddl' '@SRC@|q_src' '@T@|q' '@DEST_COLS@|dest_cols' '@COLS@|cols'
  '@EXPRS@|exprs' '@ENGINE@|engine' '@ORDER_BY@|order_by' '@PLAN_HASH@|plan_hash'
  '@CHG@|bq(chg_col)' '@SINCE_VAR@|since_var' '@OR_NULL@|or_null' '@PK_EXPRS@|pk_exprs' '@PK_COLS@|pk_cols')

# ── the planner: a WITH list ending in the CTEs `cf` (per column) and `tp` (per table) ──
planner_with_raw() {
  local ovr tpl_snap tpl_iu tpl_ic tpl_ver full_expr incr_expr ver_expr hash_expr
  ovr="$(overrides_parse rows)" || exit 2
  tpl_snap="$(template snapshot)"; tpl_iu="$(template incremental_updated)"
  tpl_ic="$(template incremental_created)"; tpl_ver="$(template verify)"
  [ -n "$tpl_snap" ] && [ -n "$tpl_iu" ] && [ -n "$tpl_ic" ] && [ -n "$tpl_ver" ] \
    || { echo "a template is missing in $TEMPLATES" >&2; exit 1; }
  full_expr="$(fill_chain tpl_snap "${PLAN_PAIRS[@]}")"
  incr_expr="$(fill_chain incr_tpl "${PLAN_PAIRS[@]}")"
  ver_expr="$(fill_chain tpl_ver "@TBL_LIT@|lit(tbl)" "@SRC@|q_src" "@CH_FROM@|ch_from" \
    "@PG_VALS@|concat('[', arrayStringConcat(m_pg, ', '), ']')" "@CH_VALS@|concat('[', arrayStringConcat(m_ch, ', '), ']')" \
    "@METRIC_NAMES@|concat('[', arrayStringConcat(arrayMap(n -> lit(n), m_names), ', '), ']')" \
    "@METRIC_KINDS@|concat('[', arrayStringConcat(arrayMap(n -> lit(n), m_kinds), ', '), ']')")"
  hash_expr="$(fill_chain tpl_ver "@TBL_LIT@|lit(tbl)" "@SRC@|q_src" "@CH_FROM@|ch_from" \
    "@PG_VALS@|concat('[ifNull(toString(sum(cityHash64(', exprs, '))), \'0\')]')" "@CH_VALS@|concat('[ifNull(toString(sum(cityHash64(', cols, '))), \'0\')]')" \
    "@METRIC_NAMES@|'[\\'content hash\\']'" "@METRIC_KINDS@|'[\\'exact\\']'")"
  printf 'WITH\n'
  printf '  toUInt64(%s) AS small_rows,\n' "$SMALL_ROWS"
  printf "  '%s' AS deny_substr,\n  '%s' AS deny_word,\n" "$(esc "$DENY_SUBSTR")" "$(esc "$DENY_WORD")"
  printf '  %s AS upd_names,\n  %s AS crt_names,\n' "$(names_array "$UPDATED_NAMES")" "$(names_array "$CREATED_NAMES")"
  printf "  '%s' AS tpl_snap,\n  '%s' AS tpl_iu,\n  '%s' AS tpl_ic,\n  '%s' AS tpl_ver,\n" \
    "$(esc "$tpl_snap")" "$(esc "$tpl_iu")" "$(esc "$tpl_ic")" "$(esc "$tpl_ver")"
  printf "  ovr AS (SELECT kind, t, c, a FROM values('kind String, t String, c String, a String', %s)),\n" "$ovr"
  cat <<'SQL'
  typ AS (
    SELECT oid, typname, typtype, typcategory, typbasetype, typtypmod, typelem
    FROM postgresql(pg_minimart, schema = 'pg_catalog', table = 'pg_type')),
  rel AS (
    SELECT c.oid AS oid, c.relname AS tbl, toFloat64(c.reltuples) AS reltuples
    FROM postgresql(pg_minimart, schema = 'pg_catalog', table = 'pg_class') AS c
    INNER JOIN postgresql(pg_minimart, schema = 'pg_catalog', table = 'pg_namespace') AS n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p') AND NOT c.relispartition),
  rdbl AS (
    SELECT table_name AS tbl, column_name AS col
    FROM postgresql(pg_minimart, schema = 'information_schema', table = 'columns')
    WHERE table_schema = 'public'),
  pkc AS (
    SELECT r.tbl AS ptbl, arrayMap(x -> toInt16(x), splitByChar(' ', i.indkey)) AS pkeys
    FROM postgresql(pg_minimart, schema = 'pg_catalog', table = 'pg_index') AS i
    INNER JOIN rel AS r ON r.oid = i.indrelid
    WHERE i.indisprimary),
  att AS (
    SELECT r.tbl AS tbl, r.reltuples AS reltuples, a.attnum AS pos, a.attname AS col,
           a.attnotnull AS notnull, a.attndims AS ndims,
           t.typname AS t_name, t.typtype AS t_type, t.typcategory AS t_cat, t.typbasetype AS t_base,
           t.typtypmod AS t_tmod, t.typelem AS t_elem, a.atttypmod AS a_tmod
    FROM postgresql(pg_minimart, schema = 'pg_catalog', table = 'pg_attribute') AS a
    INNER JOIN rel AS r ON r.oid = a.attrelid
    INNER JOIN typ AS t ON t.oid = a.atttypid
    WHERE a.attnum > 0 AND NOT a.attisdropped),
  att_b AS (
    SELECT x.*, b.typname AS bt_name, b.typtype AS bt_type, b.typcategory AS bt_cat, b.typelem AS bt_elem
    FROM att AS x LEFT JOIN typ AS b ON b.oid = x.t_base),
  eff AS (
    SELECT tbl, reltuples, pos, col, notnull, ndims, t_name,
           if(t_type = 'd', bt_name, t_name) AS b_name,
           if(t_type = 'd', bt_type, t_type) AS b_type,
           if(t_type = 'd', bt_cat, t_cat) AS b_cat,
           if(t_type = 'd', bt_elem, t_elem) AS b_elem,
           if(t_type = 'd', t_tmod, a_tmod) AS tmod
    FROM att_b),
  att_e AS (
    SELECT x.*, e.typname AS e_name, e.typtype AS e_type, indexOf(k.pkeys, x.pos) AS pk_pos
    FROM eff AS x
    LEFT JOIN typ AS e ON e.oid = x.b_elem
    LEFT JOIN pkc AS k ON k.ptbl = x.tbl),
  -- family of the Postgres type, numeric precision/scale
  ft AS (
    SELECT *,
      bitAnd(bitShiftRight(toUInt32(greatest(tmod - 4, 0)), 16), 65535) AS num_p,
      bitAnd(toUInt32(greatest(tmod - 4, 0)), 2047) AS num_s,
      (tmod >= 65540 AND num_p BETWEEN 1 AND 76 AND num_s < 1024 AND num_s <= num_p) AS dec_ok,
      multiIf(
        b_cat = 'A', if(ndims BETWEEN 1 AND 3 AND e_type != 'd', 'array', 'text'),
        b_type = 'e', 'enum',
        b_name = 'int2', 'int2', b_name = 'int4', 'int4', b_name = 'int8', 'int8',
        b_name = 'float4', 'float4', b_name = 'float8', 'float8',
        b_name = 'bool', 'bool',
        b_name = 'numeric', if(dec_ok, 'dec', 'numf'),
        b_name = 'uuid', 'uuid', b_name = 'date', 'date',
        b_name IN ('timestamp', 'timestamptz'), 'ts',
        b_name = 'bytea', 'bytea',
        'text') AS f0
    FROM att_e),
  -- per column: classification, declared types, conversion expression, verify metric
  cf AS (
    /*LAM*/ SELECT x.*,
      lower(replaceRegexpAll(x.col, '([a-z0-9])([A-Z])', '\\1_\\2')) AS nrm,
      (match(nrm, deny_substr) OR match(nrm, deny_word)) AS sens_rule,
      ((x.tbl, x.col) IN (SELECT t, c FROM ovr WHERE kind = 'allow-column')) AS allowed,
      ((x.tbl, x.col) IN (SELECT tbl, col FROM rdbl)) AS readable,
      if((x.tbl, x.col) IN (SELECT t, c FROM ovr WHERE kind = 'string-column'), 'text', x.f0) AS fam,
      concat(x.t_name, if(x.t_name != x.b_name, concat('=', x.b_name), ''),
             if(x.f0 = 'dec', concat('(', toString(x.num_p), ',', toString(x.num_s), ')'), ''),
             if(x.b_cat = 'A', concat('[', toString(x.ndims), ']'), '')) AS pgtype,
      multiIf(
        match(x.col, '[\\x00-\\x1f\\x7f@]') OR match(x.tbl, '[\\x00-\\x1f\\x7f@]'), 'unsupported name',
        (x.tbl, x.col) IN (SELECT t, c FROM ovr WHERE kind = 'exclude-column'), 'override: exclude-column',
        sens_rule AND NOT allowed, 'sensitive name',
        NOT readable, 'no SELECT privilege for minimart_ro',
        x.f0 = 'bytea' AND NOT allowed, 'binary (bytea); allow-column mirrors it as hex text',
        '') AS reason,
      -- element type of an array, wrapped in Nullable and then in the dimensions
      concat(repeat('Array(', toUInt8(x.ndims)), 'Nullable(',
        multiIf(x.e_name = 'int2', 'Int16', x.e_name = 'int4', 'Int32', x.e_name = 'int8', 'Int64',
                x.e_name = 'float4', 'Float32', x.e_name = 'float8', 'Float64', x.e_name = 'uuid', 'UUID',
                x.e_name = 'numeric' AND x.dec_ok, concat('Decimal(', toString(x.num_p), ', ', toString(x.num_s), ')'),
                'String'),
        ')', repeat(')', toUInt8(x.ndims))) AS arr_decl,
      multiIf(fam = 'int2', 'Int16', fam = 'int4', 'Int32', fam = 'int8', 'Int64',
              fam = 'float4', 'Float32', fam = 'float8', 'Float64', fam = 'bool', 'UInt8', fam = 'uuid', 'UUID',
              fam = 'dec', concat('Decimal(', toString(x.num_p), ', ', toString(x.num_s), ')'),
              'String') AS src_base,
      multiIf(fam = 'bool', 'Bool', fam = 'numf', 'Float64', fam = 'date', 'Date32',
              fam = 'ts', 'DateTime64(6, \'UTC\')', fam = 'enum', 'LowCardinality(String)', src_base) AS dst_base,
      -- NOT NULL columns are not Nullable; arrays never are
      multiIf(fam = 'array', arr_decl, x.notnull = 1, src_base, concat('Nullable(', src_base, ')')) AS src_decl,
      multiIf(fam = 'array', arr_decl, x.notnull = 1, dst_base,
              fam = 'enum', 'LowCardinality(Nullable(String))', concat('Nullable(', dst_base, ')')) AS dst_decl,
      concat('s.', bq(x.col)) AS raw,
      -- A conversion function applied to the NULL rows of a Nullable column would see the placeholder ''
      -- and fail to parse it (short-circuit evaluation cannot be relied on inside aggregates): the NULLs are
      -- replaced by a valid dummy value first and put back afterwards.
      if(x.notnull = 1, raw, concat('ifNull(', raw, ', \'', multiIf(fam = 'numf', '0', fam = 'date', '1970-01-01', '1970-01-01 00:00:00'), '\')')) AS conv_arg,
      multiIf(fam = 'bool', concat('CAST(', raw, ' AS ', if(x.notnull = 1, 'Bool', 'Nullable(Bool)'), ')'),
              fam = 'numf', concat('toFloat64(', conv_arg, ')'),
              fam = 'date', concat('toDate32(', conv_arg, ')'),
              fam = 'ts', concat('parseDateTime64BestEffort(', conv_arg, ', 6, \'UTC\')'),
              raw) AS expr0,
      if(x.notnull = 0 AND fam IN ('numf', 'date', 'ts'), concat('if(isNull(', raw, '), NULL, ', expr0, ')'), expr0) AS expr,
      if(fam = 'ts', indexOf(upd_names, lower(x.col)), 0) AS upd_rank,
      if(fam = 'ts', indexOf(crt_names, lower(x.col)), 0) AS crt_rank,
      -- verify metric: name, expression on the source (alias s), expression on the mirror, comparison kind
      multiIf(fam IN ('int2', 'int4', 'int8', 'dec', 'float4', 'float8', 'numf'), concat('sum(', x.col, ')'),
              fam = 'bool', concat('count true(', x.col, ')'),
              fam IN ('date', 'ts'), concat('max(', x.col, ')'), '') AS v_name,
      multiIf(fam IN ('int2', 'int4', 'int8'), concat('ifNull(toString(sum(toInt256(', expr, '))), \'0\')'),
              fam = 'dec', concat('ifNull(toString(sum(toDecimal256(', expr, ', ', toString(x.num_s), '))), \'0\')'),
              fam IN ('float4', 'float8', 'numf'), concat('ifNull(toString(sum(toFloat64(', expr, '))), \'0\')'),
              fam = 'bool', concat('toString(countIf(ifNull(', expr, ', false)))'),
              fam IN ('date', 'ts'), concat('ifNull(toString(max(', expr, ')), \'none\')'), '') AS v_pg,
      multiIf(fam IN ('int2', 'int4', 'int8'), concat('ifNull(toString(sum(toInt256(', bq(x.col), '))), \'0\')'),
              fam = 'dec', concat('ifNull(toString(sum(toDecimal256(', bq(x.col), ', ', toString(x.num_s), '))), \'0\')'),
              fam IN ('float4', 'float8', 'numf'), concat('ifNull(toString(sum(toFloat64(', bq(x.col), '))), \'0\')'),
              fam = 'bool', concat('toString(countIf(ifNull(', bq(x.col), ', false)))'),
              fam IN ('date', 'ts'), concat('ifNull(toString(max(', bq(x.col), ')), \'none\')'), '') AS v_ch,
      if(fam IN ('float4', 'float8', 'numf'), 'float', 'exact') AS v_kind
    FROM ft AS x),
  -- per table
  tp0 AS (
    SELECT tbl, any(reltuples) AS est0,
      arraySort(groupArrayIf((pos, col, src_decl, dst_decl, expr, v_name, v_pg, v_ch, v_kind), reason = '')) AS mc,
      arraySort(groupArrayIf((pk_pos, col), pk_pos > 0)) AS pkl,
      groupArrayIf((col, notnull, b_name), reason = '' AND fam IN ('ts', 'date')) AS tsl,
      argMinIf(col, upd_rank, upd_rank > 0 AND reason = '') AS upd_col,
      argMinIf(col, crt_rank, crt_rank > 0 AND reason = '') AS crt_col,
      groupArrayIf(concat(col, ' (', reason, ')'), reason != '') AS excl_cols,
      countIf(reason = '') AS n_mir
    FROM cf GROUP BY tbl),
  tp1 AS (
    SELECT p.*, o.ex AS ov_ex, o.snap AS ov_snap, o.inc_col AS ov_inc_col, o.inc_kind AS ov_inc_kind,
      arrayMap(x -> x.2, p.mc) AS mir_names,
      arrayMap(x -> x.2, p.pkl) AS pk_names,
      (length(p.pkl) > 0 AND arrayAll(c -> has(mir_names, c), pk_names)) AS pk_ok,
      arrayFirst(x -> x.1 = o.inc_col, p.tsl) AS inc_pick,
      (o.inc_col != '' AND tupleElement(inc_pick, 1) != '') AS inc_valid,
      if(o.inc_kind = 'created', 'created', 'updated') AS ov_kind,
      greatest(p.est0, 0) AS est,
      multiIf(startsWith(p.tbl, '_'), 'excluded', o.ex = 1, 'excluded', p.n_mir = 0, 'excluded',
              o.snap = 1, 'snapshot', NOT pk_ok, 'snapshot',
              inc_valid, concat('incremental_', ov_kind),
              est < small_rows, 'snapshot',
              p.upd_col != '', 'incremental_updated',
              p.crt_col != '', 'incremental_created',
              'snapshot') AS strategy,
      multiIf(startsWith(p.tbl, '_'), 'reserved name (leading underscore)',
              o.ex = 1, 'override: exclude',
              p.n_mir = 0, 'no mirrorable column (see the excluded columns)',
              o.snap = 1, 'override: snapshot',
              NOT pk_ok, concat(if(length(p.pkl) = 0, 'no primary key', 'primary key includes an excluded column'),
                                if(o.inc_col != '', ' (override incremental ignored)', '')),
              inc_valid, concat('override: incremental on ', o.inc_col, ' (', ov_kind, ')'),
              est < small_rows, concat('small table (', toString(toInt64(est)), ' rows < ', toString(small_rows), ')'),
              p.upd_col != '', concat('primary key + ', p.upd_col),
              p.crt_col != '', concat('primary key + append-only ', p.crt_col),
              'no usable change column') AS reason,
      multiIf(inc_valid AND pk_ok, o.inc_col, p.upd_col != '', p.upd_col, p.crt_col) AS chg_col
    FROM tp0 AS p
    LEFT JOIN (SELECT t AS tbl, max(kind = 'exclude') AS ex, max(kind = 'snapshot') AS snap,
                      argMaxIf(c, 1, kind = 'incremental') AS inc_col, argMaxIf(a, 1, kind = 'incremental') AS inc_kind
               FROM ovr WHERE kind IN ('exclude', 'snapshot', 'incremental') GROUP BY t) AS o ON o.tbl = p.tbl),
  tp2 AS (
    /*LAM*/ SELECT *,
      arrayFirst(x -> x.1 = chg_col, tsl) AS chg_pick,
      -- naive `timestamp` (time zone unknown) or `date` (day granularity): the window gets a one-day pad
      if(tupleElement(chg_pick, 3) IN ('timestamp', 'date'), '@SINCE_PAD@', '@SINCE@') AS since_var,
      if(tupleElement(chg_pick, 2) = 1, '', concat(' OR s.', bq(chg_col), ' IS NULL')) AS or_null,
      bq(tbl) AS q, bq(concat('_src_', tbl)) AS q_src, bq(concat('_new_', tbl)) AS q_new,
      arrayStringConcat(arrayMap(x -> concat(bq(x.2), ' ', x.4), mc), ', ') AS dest_cols,
      arrayStringConcat(arrayMap(x -> concat(bq(x.2), ' ', x.3), mc), ', ') AS src_cols,
      arrayStringConcat(arrayMap(x -> bq(x.2), mc), ', ') AS cols,
      arrayStringConcat(arrayMap(x -> x.5, mc), ', ') AS exprs,
      multiIf(strategy = 'incremental_updated' AND tupleElement(chg_pick, 2) = 1, concat('ReplacingMergeTree(', bq(chg_col), ')'),
              startsWith(strategy, 'incremental'), 'ReplacingMergeTree', 'MergeTree') AS engine,
      if(pk_ok, concat('(', arrayStringConcat(arrayMap(c -> bq(c), pk_names), ', '), ')'), 'tuple()') AS order_by,
      arrayStringConcat(arrayMap(c -> bq(c), pk_names), ', ') AS pk_cols,
      arrayStringConcat(arrayMap(c -> tupleElement(arrayFirst(x -> x.2 = c, mc), 5), pk_names), ', ') AS pk_exprs
    FROM tp1),
  tp3 AS (
    /*LAM*/ SELECT *,
      concat('CREATE OR REPLACE TABLE minimart.', q_src, ' (', src_cols, ') ENGINE = PostgreSQL(pg_minimart, table = ', lit(tbl), ')') AS src_ddl,
      concat('CREATE TABLE IF NOT EXISTS minimart.', q, ' (', dest_cols, ') ENGINE = ', engine, ' ORDER BY ', order_by) AS dest_ddl,
      lower(hex(cityHash64(concat(strategy, '|', chg_col, '|', since_var, '|', src_cols, '|', dest_cols, '|', exprs, '|', engine, '|', order_by)))) AS plan_hash,
      multiIf(strategy = 'incremental_updated', tpl_iu, strategy = 'incremental_created', tpl_ic, '') AS incr_tpl,
      arrayConcat(['rows'], arrayFilter(n -> n != '', arrayMap(x -> x.6, mc))) AS m_names,
      arrayConcat(['exact'], arrayFilter((k, n) -> n != '', arrayMap(x -> x.9, mc), arrayMap(x -> x.6, mc))) AS m_kinds,
      arrayConcat(['toString(count())'], arrayFilter((v, n) -> n != '', arrayMap(x -> x.7, mc), arrayMap(x -> x.6, mc))) AS m_pg,
      arrayConcat(['toString(count())'], arrayFilter((v, n) -> n != '', arrayMap(x -> x.8, mc), arrayMap(x -> x.6, mc))) AS m_ch,
      if(startsWith(strategy, 'incremental'), concat(q, ' FINAL'), q) AS ch_from
    FROM tp2),
  tp AS (
    /*LAM*/ SELECT *,
      -- every plan-time placeholder is filled in here; the run-time ones (@SINCE@, @SINCE_PAD@,
      -- @RUN_START@, @MODE@, @MAX_EXEC@) stay in the stored text
SQL
  printf '      %s AS full_sql,\n' "$full_expr"
  printf "      if(incr_tpl = '', full_sql, %s) AS incr_sql,\n" "$incr_expr"
  printf '      %s AS verify_sql,\n      %s AS verify_hash_sql\n    FROM tp3)\n' "$ver_expr" "$hash_expr"
}

# Identifier / string-literal quoting as SQL lambdas. ClickHouse 24.8 cannot see a lambda alias of the
# outermost WITH from inside a CTE, so they are declared at the top of every CTE that uses them
# (the /*LAM*/ marker in the planner text).
read -r -d '' LAM_TEXT <<'LAM' || true
WITH (x -> concat('`', replaceAll(replaceAll(x, '\\', '\\\\'), '`', '\\`'), '`')) AS bq, (x -> concat('\'', replaceAll(replaceAll(x, '\\', '\\\\'), '\'', '\\\''), '\'')) AS lit
LAM
planner_with() {
  local out
  out="$(planner_with_raw)" || exit 2
  printf '%s\n' "${out//\/\*LAM\*\//$LAM_TEXT}"
}

TABLE_COLS='tbl AS table_name, strategy, reason, toInt64(est) AS est_rows, pk_names AS pk,
       if(startsWith(strategy, '"'incremental'"'), chg_col, '"''"') AS change_col, mir_names AS mirrored_cols, excl_cols AS excluded_cols,
       src_ddl, dest_ddl, full_sql, incr_sql, verify_sql, verify_hash_sql, plan_hash'

# ── modes ───────────────────────────────────────────────────────────────────────────
mode="${1:-}"
case "$mode" in
  -h|--help) usage; exit 0 ;;
  "") usage; exit 2 ;;
  --check-overrides)
    overrides_parse rows >/dev/null || exit 2
    if [ -r "$OVERRIDES" ]; then echo "overrides file $OVERRIDES: OK"; else echo "no overrides file ($OVERRIDES): nothing to check"; fi ;;
  --tables)
    planner_with
    printf 'SELECT %s\nFROM tp ORDER BY tbl\n' "$TABLE_COLS" ;;
  --skipped)
    # Tables of other schemas and views / materialized views of public: listed for the human, never mirrored.
    # Only the catalog, no plan involved (4 connections at most).
    cat <<'SQL'
SELECT n.nspname AS schema_name, c.relname AS name,
       multiIf(c.relkind IN ('r', 'p'), 'table in another schema', c.relkind = 'v', 'view', c.relkind = 'm', 'materialized view', 'foreign table') AS what
FROM postgresql(pg_minimart, schema = 'pg_catalog', table = 'pg_class') AS c
INNER JOIN postgresql(pg_minimart, schema = 'pg_catalog', table = 'pg_namespace') AS n ON n.oid = c.relnamespace
WHERE ((c.relkind IN ('r', 'p', 'f') AND n.nspname != 'public' AND NOT c.relispartition) OR (c.relkind IN ('v', 'm', 'f') AND n.nspname = 'public'))
  AND n.nspname NOT IN ('pg_catalog', 'information_schema') AND NOT startsWith(n.nspname, 'pg_toast') AND NOT startsWith(n.nspname, 'pg_temp')
ORDER BY n.nspname, c.relname
SQL
    ;;
  --summary)
    # one single-line row per table, for the human-readable plan
    planner_with
    printf "SELECT tbl AS table_name, strategy, reason, toInt64(est) AS est_rows, arrayStringConcat(pk_names, ', ') AS pk,\n"
    printf "       if(startsWith(strategy, 'incremental'), chg_col, '') AS change_col, plan_hash\nFROM tp ORDER BY tbl\n" ;;
  --sql)
    # the generated statements as one text block per table; with a table name, also the full-load and verify SQL
    planner_with
    only="${2:-}"
    printf "SELECT arrayStringConcat(groupArray(block), '\\n\\n') FROM (SELECT concat('-- ', tbl, ' [', strategy, ': ', reason, ']\\n',\n"
    printf "  if(strategy = 'snapshot', '-- every run (and --full): snapshot copy\\n', '-- incremental run:\\n'), incr_sql,\n"
    if [ -n "$only" ]; then
      printf "  if(strategy = 'snapshot', '', concat('\\n-- --full (and the first run): snapshot copy\\n', full_sql)),\n"
      printf "  '\\n-- --verify:\\n', verify_sql, ';\\n', verify_hash_sql, ';') AS block\n"
      printf "  FROM tp WHERE strategy != 'excluded' AND tbl = '%s' ORDER BY tbl)\n" "$(esc "$only")"
    else
      printf "  '') AS block\n  FROM tp WHERE strategy != 'excluded' ORDER BY tbl)\n"
    fi ;;
  --cols)
    planner_with
    cat <<'SQL'
SELECT tbl AS table_name, col, toInt32(pos) AS pos, pgtype, 1 - notnull AS nullable, readable,
       (sens_rule AND NOT allowed) AS sensitive, reason = '' AS mirrored, reason, dst_decl, pk_pos
FROM cf ORDER BY tbl, pos
SQL
    ;;
  --install)
    pid="${2:-}"; [[ "$pid" =~ ^[A-Za-z0-9_-]{4,64}$ ]] || { echo "usage: $0 --install PLAN_ID" >&2; exit 2; }
    printf 'INSERT INTO minimart._plan (plan_id, table_name, strategy, reason, est_rows, pk, change_col, mirrored_cols, excluded_cols, src_ddl, dest_ddl, full_sql, incr_sql, verify_sql, verify_hash_sql, plan_hash)\n'
    planner_with
    printf "SELECT '%s' AS plan_id, table_name, strategy, reason, est_rows, pk, change_col, mirrored_cols, excluded_cols, src_ddl, dest_ddl, full_sql, incr_sql, verify_sql, verify_hash_sql, plan_hash\n" "$pid"
    printf "FROM (SELECT %s FROM tp WHERE strategy != 'excluded');\n\n" "$TABLE_COLS"
    printf 'INSERT INTO minimart._plan_cols (plan_id, table_name, col, pos, pg_type, nullable, readable, sensitive, mirrored, reason, sig)\n'
    planner_with
    printf "SELECT '%s', tbl, col, toInt32(pos), pgtype, 1 - notnull, readable, (sens_rule AND NOT allowed), reason = '', reason,\n" "$pid"
    printf "       concat(pgtype, '|', toString(notnull), '|', if(reason IN ('', 'no SELECT privilege for minimart_ro'), toString(readable), '-'), '|', toString(pk_pos)) FROM cf;\n\n"
    printf "INSERT INTO minimart._plan_current (plan_id, planned_at, tables) SELECT '%s', now64(3, 'UTC'), count() FROM minimart._plan WHERE plan_id = '%s';\n" "$pid" "$pid" ;;
  --drift)
    # minimart_ro may open 20 connections and every reference of a CTE reads the catalog again (one
    # connection per table function), so the live catalog (`cf`) is referenced exactly ONCE below.
    planner_with
    cat <<'SQL'
  , cur AS (SELECT argMax(plan_id, planned_at) AS id FROM minimart._plan_current),
  stored AS (SELECT table_name AS tbl, col, sig FROM minimart._plan_cols WHERE plan_id = (SELECT id FROM cur)),
  stored_tbls AS (SELECT DISTINCT tbl FROM stored),
  live_tbls AS (SELECT tbl FROM rel),
  live AS (SELECT tbl, col, concat(pgtype, '|', toString(notnull), '|', if(reason IN ('', 'no SELECT privilege for minimart_ro'), toString(readable), '-'), '|', toString(pk_pos)) AS sig,
                  (sens_rule AND NOT allowed) AS sens, readable FROM cf),
  skip_tbl AS (SELECT t AS tbl FROM ovr WHERE kind = 'exclude')
SELECT kind, tbl, if(kind IN ('new_table', 'dropped_table'), '', c_name) AS col,
       if(kind = 'new_table',
          if(max(is_readable) = 0, 'not readable by minimart_ro: run db/minimart_ro_grants.sql, then --init',
             'not in the mirror yet: run --init to adopt it'),
          any(detail)) AS detail
FROM (
  SELECT j.1 AS kind, j.2 AS detail, if(l_tbl != '', l_tbl, s_tbl) AS tbl, if(l_tbl != '', l_col, s_col) AS c_name, l_readable AS is_readable
  FROM (
    SELECT l.tbl AS l_tbl, l.col AS l_col, l.sig AS l_sig, l.sens AS l_sens, l.readable AS l_readable,
           s.tbl AS s_tbl, s.col AS s_col, s.sig AS s_sig,
           arrayConcat(
             if(l_tbl != '' AND s_tbl = '' AND l_tbl NOT IN (SELECT tbl FROM stored_tbls) AND l_tbl NOT IN (SELECT tbl FROM skip_tbl)
                  AND NOT startsWith(l_tbl, '_'), [('new_table', '')], []),
             if(l_tbl != '' AND s_tbl = '' AND l_tbl IN (SELECT tbl FROM stored_tbls),
                [('new_column', 'added in Postgres, not mirrored until --init is re-run')], []),
             if(l_tbl = '' AND s_tbl != '' AND s_tbl IN (SELECT tbl FROM live_tbls),
                [('dropped_column', 'dropped in Postgres: this table is skipped until --init is re-run')], []),
             if(l_tbl = '' AND s_tbl != '' AND s_tbl NOT IN (SELECT tbl FROM live_tbls),
                [('dropped_table', 'no longer in Postgres (the mirror table is kept; DROP it by hand when sure)')], []),
             if(l_tbl != '' AND s_tbl != '' AND l_sig != s_sig,
                [('changed_column', concat('type, nullability, key or privilege changed (', s_sig, ' -> ', l_sig, '): this table is skipped until --init is re-run'))], []),
             if(l_tbl != '' AND l_sens AND l_readable,
                [('sensitive_readable', 'minimart_ro can read a column with a sensitive name (it is NOT mirrored): re-run db/minimart_ro_grants.sql')], [])
           ) AS findings
    FROM live AS l FULL OUTER JOIN stored AS s ON l.tbl = s.tbl AND l.col = s.col
  )
  ARRAY JOIN findings AS j
)
GROUP BY kind, tbl, col
ORDER BY kind, tbl, col
SQL
    ;;
  --grant-args)
    overrides_parse grants || exit 2 ;;
  *) usage; exit 2 ;;
esac
