#!/usr/bin/env bash
# Move the minimart database from its own container (minimart-postgres-1) into the
# shared central server (mmi-postgres, database `minimart`).
#
#   scripts/minimart_migrate.sh --inspect        read-only report of the OLD database
#   scripts/minimart_migrate.sh --backup-old     custom dump + schema dump + globals + per-table counts
#                                                of the OLD database -> /opt/backups/minimart/pre_migration_<ts>/
#   scripts/minimart_migrate.sh --rehearse       dump OLD -> restore into scratch DB `minimart_rehearsal`
#                                                on mmi-postgres -> verify -> drop it; prints timing
#   scripts/minimart_migrate.sh --cutover        the real thing (guarded: the app must be stopped)
#   scripts/minimart_migrate.sh --verify         OLD vs NEW: row counts, numeric sums, min/max of every
#                                                time column, per-table row-content checksum, sequences,
#                                                object inventory. Exit 1 on any mismatch.
#   scripts/minimart_migrate.sh --rollback-info  print the exact manual rollback
#   scripts/minimart_migrate.sh -h
#
# Nothing here knows a table or column name: everything is read from pg_catalog /
# information_schema of the live database at run time. Both servers are reached with
# `docker exec` (no passwords pass through this script; the old container and mmi-postgres
# accept the superuser on their local socket). The old database is only ever READ
# (sessions are forced read-only). mmi-postgres is only touched in database `minimart`
# and the scratch database `minimart_rehearsal` (its own roles are created by
# db/minimart_setup.sql, which must have been run first).
#
# Environment (all optional; detected at run time when unset):
#   MINIMART_OLD_CONTAINER   default minimart-postgres-1
#   MINIMART_OLD_PGUSER      default: POSTGRES_USER from the old container's env, else postgres
#   MINIMART_OLD_DB          default: POSTGRES_DB from the old container's env, else the user name
#   MINIMART_NEW_CONTAINER   default mmi-postgres
#   MINIMART_NEW_PGUSER      default postgres
#   MINIMART_NEW_DB          default minimart
#   MINIMART_REHEARSAL_DB    default minimart_rehearsal
#   MINIMART_BACKUP_ROOT     default /opt/backups/minimart
#   MINIMART_LOCAL_TZ        default Asia/Bangkok (only used by --inspect's time-column report)
#   MINIMART_LC_COLLATE / MINIMART_LC_CTYPE   locale for a database this script has to (re)create
#                            (default: copy the existing `minimart` database, else server default)
#   MINIMART_VERIFY_CONTENT  1 (default) = also compare a checksum of every row's text form;
#                            0 = skip it (counts, sums and min/max only) for a very large database
#   MINIMART_KEEP_REHEARSAL  1 = do not drop the scratch database after --rehearse
#   MINIMART_DOCKER          docker command (default docker; the tests substitute a wrapper)
#   MINIMART_MIGRATE_LOG     default /var/log/minimart-migration.log (best effort)
#   MINIMART_MIGRATE_LOCK    default /var/lock/minimart-migrate.lock (one mutating run at a time)
#   MINIMART_CMD_TIMEOUT     seconds per short call (default 600)
#   MINIMART_DUMP_TIMEOUT    seconds per dump/restore (default 7200)
#   MINIMART_VERIFY_TIMEOUT  seconds per verification scan (default 3600)
#
# Exit codes: 0 ok, 1 failure/mismatch, 2 usage, 3 guard refused (app still connected, order of
# phases not followed, target not empty ...). Nothing is changed when a guard refuses.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETUP_SQL="$REPO_DIR/db/minimart_setup.sql"

OLD_CONTAINER="${MINIMART_OLD_CONTAINER:-minimart-postgres-1}"
NEW_CONTAINER="${MINIMART_NEW_CONTAINER:-mmi-postgres}"
NEW_PGUSER="${MINIMART_NEW_PGUSER:-postgres}"
NEW_DB="${MINIMART_NEW_DB:-minimart}"
REHEARSAL_DB="${MINIMART_REHEARSAL_DB:-minimart_rehearsal}"
BACKUP_ROOT="${MINIMART_BACKUP_ROOT:-/opt/backups/minimart}"
LOCAL_TZ="${MINIMART_LOCAL_TZ:-Asia/Bangkok}"
VERIFY_CONTENT="${MINIMART_VERIFY_CONTENT:-1}"
DOCKER="${MINIMART_DOCKER:-docker}"
LOG_FILE="${MINIMART_MIGRATE_LOG:-/var/log/minimart-migration.log}"
CMD_TIMEOUT="${MINIMART_CMD_TIMEOUT:-600}"
DUMP_TIMEOUT="${MINIMART_DUMP_TIMEOUT:-7200}"
OWNER_ROLE=minimart_owner
TS="$(date +%Y%m%d_%H%M%S)"
ROLE_CHECK="minimart_owner minimart_app minimart_ro"

MODE=
case "${1:-}" in
  --inspect)       MODE=inspect ;;
  --backup-old)    MODE=backup ;;
  --rehearse)      MODE=rehearse ;;
  --cutover)       MODE=cutover ;;
  --verify)        MODE=verify ;;
  --rollback-info) MODE=rollback ;;
  -h|--help)       sed -n '2,48p' "$0"; exit 0 ;;
  *) echo "usage: $0 --inspect|--backup-old|--rehearse|--cutover|--verify|--rollback-info|-h" >&2; exit 2 ;;
esac
[ "$#" -le 1 ] || { echo "usage: $0 --inspect|--backup-old|--rehearse|--cutover|--verify|--rollback-info|-h" >&2; exit 2; }

touch "$LOG_FILE" 2>/dev/null || LOG_FILE=/dev/null
say()  { echo "$*"; }
log()  { echo "$(date '+%Y-%m-%d %H:%M:%S %z') [$MODE] $*" >> "$LOG_FILE"; }
info() { say "$*"; log "$*"; }
warn() { say "WARNING: $*"; log "WARNING: $*"; }
die()  { say "FAILED: $1" >&2; log "FAILED: $1"; exit "${2:-1}"; }
hdr()  { say ""; say "== $* =="; }

# Run a command with a time limit (GNU timeout, Homebrew gtimeout, or perl's alarm).
run_timeout() {
  local secs=$1; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$secs" "$@"
  else perl -e 'alarm shift @ARGV; exec @ARGV or die "exec failed: $!\n"' "$secs" "$@"; fi
}

# One mutating run at a time (a second paste of the same command must not race the first).
LOCK_FILE="${MINIMART_MIGRATE_LOCK:-/var/lock/minimart-migrate.lock}"
case "$MODE" in
  backup|rehearse|cutover)
    if ! { exec 9>"$LOCK_FILE"; } 2>/dev/null; then die "cannot open lock file $LOCK_FILE"; fi
    if command -v flock >/dev/null 2>&1; then
      flock -n 9 && lock_rc=0 || lock_rc=$?
    else  # macOS has no flock(1); perl's flock on the inherited fd 9 is equivalent
      perl -MFcntl=:flock -e 'open(my $f, ">&=", 9) or exit 2; flock($f, LOCK_EX | LOCK_NB) or exit 1' && lock_rc=0 || lock_rc=$?
    fi
    [ "$lock_rc" -eq 0 ] || die "another minimart_migrate.sh run (--backup-old/--rehearse/--cutover) is active (lock $LOCK_FILE). Wait for it to finish; nothing changed." 3
    ;;
esac

command -v "$DOCKER" >/dev/null 2>&1 || die "'$DOCKER' not found. Run this on the server (as root)."

# ── docker exec wrappers ─────────────────────────────────────────────────────
# oexec/nexec: docker exec into the old / new container. The old database is read-only
# for every session this script opens (PGOPTIONS). stdin: callers redirect explicitly.
oexec() { run_timeout "$CMD_TIMEOUT" "$DOCKER" exec -i -e "PGOPTIONS=-c default_transaction_read_only=on" "$OLD_CONTAINER" "$@"; }
nexec() { run_timeout "$CMD_TIMEOUT" "$DOCKER" exec -i "$NEW_CONTAINER" "$@"; }
# psql wrappers. q_*: one statement/script given as an argument, tuples-only unaligned.
# f_*: SQL script on stdin (same output style). p_*: pretty aligned output of a stdin script.
q_old()  { oexec psql -U "$OLD_PGUSER" -d "$OLD_DB" -X -q -At -v ON_ERROR_STOP=1 -c "$1" < /dev/null; }
f_old()  { oexec psql -U "$OLD_PGUSER" -d "$OLD_DB" -X -q -At -v ON_ERROR_STOP=1 -f -; }
p_old()  { oexec psql -U "$OLD_PGUSER" -d "$OLD_DB" -X -q -v ON_ERROR_STOP=1 -f -; }
q_new()  { local db=$1; shift; nexec psql -U "$NEW_PGUSER" -d "$db" -X -q -At -v ON_ERROR_STOP=1 -c "$1" < /dev/null; }
f_new()  { local db=$1; shift; nexec psql -U "$NEW_PGUSER" -d "$db" -X -q -At -v ON_ERROR_STOP=1 "$@" -f -; }
p_new()  { local db=$1; shift; nexec psql -U "$NEW_PGUSER" -d "$db" -X -q -v ON_ERROR_STOP=1 "$@" -f -; }

container_running() { [ "$("$DOCKER" inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = "true" ]; }

# ── detect the old database's login ──────────────────────────────────────────
OLD_PGUSER="${MINIMART_OLD_PGUSER:-}"
OLD_DB="${MINIMART_OLD_DB:-}"
detect_old() {
  container_running "$OLD_CONTAINER" || die "container $OLD_CONTAINER is not running (docker ps -a | grep minimart)"
  local v
  if [ -z "$OLD_PGUSER" ]; then
    v="$(run_timeout 60 "$DOCKER" exec "$OLD_CONTAINER" printenv POSTGRES_USER 2>/dev/null </dev/null | tr -d '\r\n')" || v=
    OLD_PGUSER="${v:-postgres}"
  fi
  if [ -z "$OLD_DB" ]; then
    v="$(run_timeout 60 "$DOCKER" exec "$OLD_CONTAINER" printenv POSTGRES_DB 2>/dev/null </dev/null | tr -d '\r\n')" || v=
    OLD_DB="${v:-$OLD_PGUSER}"
  fi
  if ! q_old "select 1" >/dev/null 2>&1; then
    die "cannot connect to old database '$OLD_DB' as '$OLD_PGUSER' inside $OLD_CONTAINER.
       Find the right names with:  docker exec $OLD_CONTAINER printenv | grep -i postgres
       then re-run with MINIMART_OLD_PGUSER=... MINIMART_OLD_DB=... in front of the command."
  fi
  OLD_VER_NUM="$(q_old "show server_version_num")" || die "cannot read the old server version"
  OLD_VER="$(q_old "show server_version")"
  OLD_SUPER="$(q_old "select rolsuper from pg_roles where rolname = current_user")"
}

detect_new() {
  container_running "$NEW_CONTAINER" || die "container $NEW_CONTAINER is not running"
  q_new postgres "select 1" >/dev/null 2>&1 || die "cannot connect to $NEW_CONTAINER as $NEW_PGUSER (database postgres)"
  NEW_VER_NUM="$(q_new postgres "show server_version_num")" || die "cannot read the new server version"
  NEW_VER="$(q_new postgres "show server_version")"
}

# ─────────────────────────────────────────────────────────────────────────────
# SQL building blocks. All catalog-driven. Identical on old and new servers.
# ─────────────────────────────────────────────────────────────────────────────

# Session settings that make text output identical on both servers.
SQL_SESSION="SET timezone='UTC'; SET datestyle='ISO, YMD'; SET extra_float_digits=1; SET intervalstyle='postgres'; SET bytea_output='hex'; SET lc_monetary='C'; SET lc_numeric='C'; SET lc_time='C'; SET search_path = pg_catalog;"

# Relations to compare: ordinary + partitioned tables of user schemas that do not belong to an
# extension. Materialised views are NOT compared row by row: pg_restore refreshes them, so a
# stale one legitimately differs; the inventory compares their number and populated state.
read -r -d '' SQL_RELS <<'SQL'
SELECT c.oid, n.nspname AS sch, c.relname AS rel, c.relkind
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE c.relkind IN ('r','p')
   AND n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'
   AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_class'::regclass AND d.objid = c.oid AND d.deptype = 'e')
SQL

# Sequence -> column dependencies: serial/owned-by ('a'), identity ('i'), and plain
# nextval() defaults. Integer columns only.
read -r -d '' SQL_SEQ_DEPS <<'SQL'
SELECT DISTINCT sn.nspname AS seq_sch, s.relname AS seq, tn.nspname AS tbl_sch, t.relname AS tbl, a.attname AS col
  FROM pg_class s
  JOIN pg_namespace sn ON sn.oid = s.relnamespace
  JOIN pg_depend d ON d.classid = 'pg_class'::regclass AND d.objid = s.oid AND d.refclassid = 'pg_class'::regclass AND d.deptype IN ('a','i')
  JOIN pg_class t ON t.oid = d.refobjid
  JOIN pg_namespace tn ON tn.oid = t.relnamespace
  JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = d.refobjsubid AND NOT a.attisdropped
 WHERE s.relkind = 'S' AND a.atttypid IN ('int2'::regtype, 'int4'::regtype, 'int8'::regtype)
UNION
SELECT sn.nspname, s.relname, tn.nspname, t.relname, a.attname
  FROM pg_depend d
  JOIN pg_attrdef ad ON d.classid = 'pg_attrdef'::regclass AND d.objid = ad.oid
  JOIN pg_class s ON s.oid = d.refobjid AND d.refclassid = 'pg_class'::regclass AND s.relkind = 'S'
  JOIN pg_namespace sn ON sn.oid = s.relnamespace
  JOIN pg_class t ON t.oid = ad.adrelid
  JOIN pg_namespace tn ON tn.oid = t.relnamespace
  JOIN pg_attribute a ON a.attrelid = ad.adrelid AND a.attnum = ad.adnum
 WHERE a.atttypid IN ('int2'::regtype, 'int4'::regtype, 'int8'::regtype)
   AND t.relkind IN ('r','p')
SQL

# ── per-table fingerprint generator: prints one SELECT per relation ──
# Output line of each SELECT:  schema.rel|rows=N|sum:col=V|...|min:col=V|max:col=V|hash=H
gen_fingerprint_sql() {
  local content="$VERIFY_CONTENT"
  cat <<SQL
WITH rels AS ($SQL_RELS),
cols AS (
  SELECT r.oid, r.sch, r.rel, a.attnum, a.attname,
         CASE WHEN ty.typtype = 'd' THEN ty.typbasetype ELSE ty.oid END AS atttypid   -- domains: use the base type
    FROM rels r JOIN pg_attribute a ON a.attrelid = r.oid AND a.attnum > 0 AND NOT a.attisdropped
                JOIN pg_type ty ON ty.oid = a.atttypid
),
parts AS (
  SELECT oid, sch, rel, attnum, 1 AS ord,
         CASE
           WHEN atttypid IN ('int2'::regtype,'int4'::regtype,'int8'::regtype,'numeric'::regtype) THEN
             format('%L || coalesce(sum(t.%I::numeric)::text, ''~'')', '|sum:' || attname || '=', attname)
           WHEN atttypid IN ('float4'::regtype,'float8'::regtype) THEN
             format('%L || coalesce(sum(CASE WHEN t.%I::text IN (''NaN'',''Infinity'',''-Infinity'') THEN NULL ELSE t.%I::numeric END)::text, ''~'') || %L || count(*) FILTER (WHERE t.%I::text IN (''NaN'',''Infinity'',''-Infinity''))',
                    '|sum:' || attname || '=', attname, attname, '/nonfinite=', attname)
           WHEN atttypid = 'money'::regtype THEN
             format('%L || coalesce(sum(t.%I::numeric)::text, ''~'')', '|sum:' || attname || '=', attname)
           WHEN atttypid IN ('timestamptz'::regtype,'timestamp'::regtype,'date'::regtype,'time'::regtype,'timetz'::regtype) THEN
             format('%L || coalesce(min(t.%I)::text, ''~'') || %L || coalesce(max(t.%I)::text, ''~'')',
                    '|min:' || attname || '=', attname, '|max:' || attname || '=', attname)
         END AS expr
    FROM cols
),
stmts AS (
  SELECT c.sch, c.rel,
         format('SELECT %L || ''|rows='' || count(*)%s%s FROM %I.%I t;',
                c.sch || '.' || c.rel,
                COALESCE((SELECT ' || ' || string_agg(p.expr, ' || ' ORDER BY p.attnum)
                            FROM parts p WHERE p.oid = c.oid AND p.expr IS NOT NULL), ''),
                CASE WHEN $content = 1
                     THEN ' || ''|hash='' || coalesce(sum((''x'' || substr(md5((t.*)::text), 1, 15))::bit(60)::bigint::numeric)::text, ''~'')'
                     ELSE '' END,
                c.sch, c.rel) AS stmt
    FROM rels c
)
SELECT stmt FROM stmts ORDER BY sch, rel;
SQL
}

# Catalog inventory (counts and a digest of the column layout). Same on both servers if
# the restore was faithful.
read -r -d '' SQL_INVENTORY <<'SQL'
WITH ns AS (SELECT oid, nspname FROM pg_namespace WHERE nspname !~ '^pg_' AND nspname <> 'information_schema'),
ext AS (SELECT classid, objid FROM pg_depend WHERE deptype = 'e')
SELECT 'inv|schemas|' || count(*) FROM ns
UNION ALL SELECT 'inv|tables|' || count(*) FROM pg_class c JOIN ns ON ns.oid = c.relnamespace WHERE c.relkind IN ('r','p')
UNION ALL SELECT 'inv|views|' || count(*) FROM pg_class c JOIN ns ON ns.oid = c.relnamespace WHERE c.relkind = 'v'
UNION ALL SELECT 'inv|matviews|' || count(*) || '|populated=' || count(*) FILTER (WHERE c.relispopulated) FROM pg_class c JOIN ns ON ns.oid = c.relnamespace WHERE c.relkind = 'm'
UNION ALL SELECT 'inv|sequences|' || count(*) FROM pg_class c JOIN ns ON ns.oid = c.relnamespace WHERE c.relkind = 'S'
UNION ALL SELECT 'inv|indexes|' || count(*) FROM pg_class c JOIN ns ON ns.oid = c.relnamespace WHERE c.relkind IN ('i','I')
UNION ALL SELECT 'inv|constraints|' || coalesce(string_agg(contype::text || '=' || n, ',' ORDER BY contype), '')
  FROM (SELECT contype, count(*) n FROM pg_constraint k JOIN ns ON ns.oid = k.connamespace GROUP BY contype) x
UNION ALL SELECT 'inv|triggers|' || count(*) FROM pg_trigger tg JOIN pg_class c ON c.oid = tg.tgrelid JOIN ns ON ns.oid = c.relnamespace WHERE NOT tg.tgisinternal
UNION ALL SELECT 'inv|functions|' || count(*) FROM pg_proc p JOIN ns ON ns.oid = p.pronamespace
   WHERE NOT EXISTS (SELECT 1 FROM ext e WHERE e.classid = 'pg_proc'::regclass AND e.objid = p.oid)
UNION ALL SELECT 'inv|types|' || count(*) FROM pg_type t JOIN ns ON ns.oid = t.typnamespace
   WHERE t.typtype IN ('e','d','r') OR (t.typtype = 'c' AND t.typrelid IN (SELECT oid FROM pg_class WHERE relkind = 'c'))
UNION ALL SELECT 'inv|extensions|' || coalesce(string_agg(extname, ',' ORDER BY extname), '') FROM pg_extension WHERE extname <> 'plpgsql'
UNION ALL SELECT 'inv|columns|' || count(*) || '|' || coalesce(md5(string_agg(
       n.nspname || '.' || c.relname || '.' || a.attname || ':' || format_type(a.atttypid, a.atttypmod) || ':' || a.attnotnull::text
       || ':' || a.attidentity::text || ':' || a.attgenerated::text || ':' || coalesce(pg_get_expr(d.adbin, d.adrelid), ''),
       ';' ORDER BY n.nspname, c.relname, a.attnum)), '')
  FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid JOIN ns n ON n.oid = c.relnamespace
  LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
 WHERE c.relkind IN ('r','p','v','m') AND a.attnum > 0 AND NOT a.attisdropped
UNION ALL SELECT 'inv|largeobjects|' || (SELECT count(*) FROM pg_largeobject_metadata) || '|'
       || coalesce((SELECT md5(string_agg(loid::text || ':' || pageno || ':' || md5(data), ',' ORDER BY loid, pageno)) FROM pg_largeobject), '')
ORDER BY 1;
SQL

# Object ownership: every object of the database owned by a role other than minimart_owner
# (extension members excepted). Reads the catalogs directly: pg_shdepend omits objects owned
# by the bootstrap superuser (postgres), which is exactly who owns a freshly restored object.
# Prints "class|object|owner" per offender.
read -r -d '' SQL_NOT_OWNED <<'SQL'
WITH own AS (SELECT oid FROM pg_roles WHERE rolname = 'minimart_owner'),
ext AS (SELECT classid, objid FROM pg_depend WHERE deptype = 'e')
SELECT 'schema|' || nspname || '|' || pg_get_userbyid(nspowner) FROM pg_namespace n
 WHERE nspname !~ '^pg_' AND nspname <> 'information_schema' AND nspowner <> (SELECT oid FROM own)
   AND NOT EXISTS (SELECT 1 FROM ext e WHERE e.classid = 'pg_namespace'::regclass AND e.objid = n.oid)
UNION ALL
SELECT 'relation(' || c.relkind::text || ')|' || n.nspname || '.' || c.relname || '|' || pg_get_userbyid(c.relowner)
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE c.relkind IN ('r','p','v','m','S','f') AND c.relowner <> (SELECT oid FROM own)
   AND n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'
   AND NOT EXISTS (SELECT 1 FROM ext e WHERE e.classid = 'pg_class'::regclass AND e.objid = c.oid)
UNION ALL
SELECT 'type|' || n.nspname || '.' || t.typname || '|' || pg_get_userbyid(t.typowner)
  FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
 WHERE t.typowner <> (SELECT oid FROM own) AND n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'
   AND (t.typtype IN ('e','d','r') OR (t.typtype = 'c' AND t.typrelid IN (SELECT oid FROM pg_class WHERE relkind = 'c')))
   AND NOT EXISTS (SELECT 1 FROM ext e WHERE e.classid = 'pg_type'::regclass AND e.objid = t.oid)
UNION ALL
SELECT 'function|' || n.nspname || '.' || p.proname || '|' || pg_get_userbyid(p.proowner)
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE p.proowner <> (SELECT oid FROM own) AND n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'
   AND NOT EXISTS (SELECT 1 FROM ext e WHERE e.classid = 'pg_proc'::regclass AND e.objid = p.oid)
UNION ALL
SELECT 'largeobject|' || oid::text || '|' || pg_get_userbyid(lomowner) FROM pg_largeobject_metadata WHERE lomowner <> (SELECT oid FROM own)
UNION ALL
SELECT 'collation|' || n.nspname || '.' || c.collname || '|' || pg_get_userbyid(c.collowner)
  FROM pg_collation c JOIN pg_namespace n ON n.oid = c.collnamespace
 WHERE c.collowner <> (SELECT oid FROM own) AND n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'
   AND NOT EXISTS (SELECT 1 FROM ext e WHERE e.classid = 'pg_collation'::regclass AND e.objid = c.oid)
UNION ALL
SELECT 'operator|' || n.nspname || '.' || o.oprname || '|' || pg_get_userbyid(o.oprowner)
  FROM pg_operator o JOIN pg_namespace n ON n.oid = o.oprnamespace
 WHERE o.oprowner <> (SELECT oid FROM own) AND n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'
   AND NOT EXISTS (SELECT 1 FROM ext e WHERE e.classid = 'pg_operator'::regclass AND e.objid = o.oid)
UNION ALL
SELECT 'event trigger|' || evtname || '|' || pg_get_userbyid(evtowner) FROM pg_event_trigger WHERE evtowner <> (SELECT oid FROM own)
ORDER BY 1;
SQL

# ── post-restore SQL ─────────────────────────────────────────────────────────
read -r -d '' SQL_FIX_OWNERS <<'SQL'
SET client_min_messages = notice;
DO $$
DECLARE r record; n int := 0; own oid := (SELECT oid FROM pg_roles WHERE rolname = 'minimart_owner');
BEGIN
  IF own IS NULL THEN RAISE EXCEPTION 'role minimart_owner does not exist: run db/minimart_setup.sql first'; END IF;
  FOR r IN
    -- schemas
    SELECT 1 AS o, 'SCHEMA' AS kind, quote_ident(nspname) AS obj FROM pg_namespace
     WHERE nspname !~ '^pg_' AND nspname <> 'information_schema' AND nspowner <> own
       AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_namespace'::regclass AND d.objid = pg_namespace.oid AND d.deptype = 'e')
    UNION ALL
    -- tables, views, materialised views, foreign tables, standalone sequences
    SELECT 2, CASE c.relkind WHEN 'v' THEN 'VIEW' WHEN 'm' THEN 'MATERIALIZED VIEW' WHEN 'S' THEN 'SEQUENCE'
                             WHEN 'f' THEN 'FOREIGN TABLE' ELSE 'TABLE' END,
           format('%I.%I', n.nspname, c.relname)
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE c.relkind IN ('r','p','v','m','f','S') AND c.relowner <> own
       AND n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'
       AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_class'::regclass AND d.objid = c.oid AND d.deptype = 'e')
       -- serial / identity sequences follow their table automatically (ALTER would error)
       AND NOT (c.relkind = 'S' AND EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_class'::regclass AND d.objid = c.oid AND d.deptype IN ('a','i')))
    UNION ALL
    -- enums, domains, ranges, standalone composite types
    SELECT 3, 'TYPE', format('%I.%I', n.nspname, t.typname)
      FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
     WHERE t.typowner <> own AND n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'
       AND (t.typtype IN ('e','r') OR (t.typtype = 'c' AND t.typrelid IN (SELECT oid FROM pg_class WHERE relkind = 'c')))
       AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_type'::regclass AND d.objid = t.oid AND d.deptype = 'e')
    UNION ALL
    SELECT 3, 'DOMAIN', format('%I.%I', n.nspname, t.typname)
      FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
     WHERE t.typowner <> own AND t.typtype = 'd' AND n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'
       AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_type'::regclass AND d.objid = t.oid AND d.deptype = 'e')
    UNION ALL
    -- functions, procedures, aggregates
    SELECT 4, CASE p.prokind WHEN 'p' THEN 'PROCEDURE' WHEN 'a' THEN 'AGGREGATE' ELSE 'FUNCTION' END,
           format('%I.%I(%s)', n.nspname, p.proname, CASE WHEN p.prokind = 'a' AND p.pronargs = 0 THEN '*' ELSE pg_get_function_identity_arguments(p.oid) END)
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE p.proowner <> own AND n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'
       AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_proc'::regclass AND d.objid = p.oid AND d.deptype = 'e')
    ORDER BY 1
  LOOP
    -- a domain is also typtype 'e'-excluded above, so the DOMAIN branch is the only one for it
    EXECUTE format('ALTER %s %s OWNER TO minimart_owner', r.kind, r.obj);
    n := n + 1;
  END LOOP;
  FOR r IN SELECT oid FROM pg_largeobject_metadata WHERE lomowner <> own LOOP
    EXECUTE format('ALTER LARGE OBJECT %s OWNER TO minimart_owner', r.oid);
    n := n + 1;
  END LOOP;
  RAISE NOTICE 'ownership: % object(s) changed to minimart_owner', n;
END $$;
SQL

read -r -d '' SQL_RESET_SEQS_HEAD <<'SQL'
SET client_min_messages = notice;
DO $$
DECLARE r record; mx numeric; lv numeric; inc numeric; mn numeric; mxv numeric; st numeric; nxt numeric; n int := 0; seen int := 0;
BEGIN
  FOR r IN
SQL
read -r -d '' SQL_RESET_SEQS_TAIL <<'SQL'
    ORDER BY 1, 2, 5
  LOOP
    seen := seen + 1;
    SELECT increment_by, last_value, min_value, max_value, start_value INTO inc, lv, mn, mxv, st
      FROM pg_sequences WHERE schemaname = r.seq_sch AND sequencename = r.seq;
    IF inc IS NULL THEN CONTINUE; END IF;
    IF inc < 0 THEN
      RAISE NOTICE 'sequence %.% has a negative increment: not reset', r.seq_sch, r.seq;
      CONTINUE;
    END IF;
    EXECUTE format('SELECT max(%I)::numeric FROM %I.%I', r.col, r.tbl_sch, r.tbl) INTO mx;
    -- the value the sequence hands out next (NULL last_value = never used yet)
    nxt := coalesce(lv + inc, st);
    IF mx IS NOT NULL AND mx >= nxt THEN
      IF mx > mxv THEN
        RAISE WARNING 'sequence %.% cannot be moved above the data (max %, sequence maximum %): fix by hand', r.seq_sch, r.seq, mx, mxv;
        CONTINUE;
      END IF;
      PERFORM setval(format('%I.%I', r.seq_sch, r.seq)::regclass, mx::bigint, true);
      RAISE NOTICE 'sequence %.% reset from % to % (max of %.%.%)', r.seq_sch, r.seq, coalesce(lv::text, 'unused'), mx, r.tbl_sch, r.tbl, r.col;
      n := n + 1;
    END IF;
  END LOOP;
  RAISE NOTICE 'sequences: % checked, % reset above the data', seen, n;
END $$;
SQL

# Print what the old server holds, per table. Used by --backup-old (counts.tsv) and verify.
gen_counts_sql() {
  cat <<SQL
WITH rels AS ($SQL_RELS)
SELECT format('SELECT %L || E''\t'' || count(*) FROM %I.%I;', sch || '.' || rel, sch, rel) FROM rels ORDER BY sch, rel;
SQL
}

# ── marker on the new database: state of the migration ──────────────────────
marker_get() { q_new postgres "select coalesce(shobj_description(oid, 'pg_database'), '') from pg_database where datname = '$NEW_DB'" 2>/dev/null; }
marker_set() { q_new postgres "COMMENT ON DATABASE \"$NEW_DB\" IS 'minimart-migration: $1 $(date -u +%Y-%m-%dT%H:%M:%SZ)'" >/dev/null 2>&1; }

# Refuse to migrate an old database with no tables (wrong MINIMART_OLD_DB / POSTGRES_DB unset).
require_old_tables() {
  local n dbs
  n="$(q_old "WITH rels AS ($SQL_RELS) SELECT count(*) FROM rels")" || die "cannot count the tables of the old database"
  info "old database $OLD_DB holds $n table(s)"
  if [ "${n:-0}" -eq 0 ] && [ "${MINIMART_ALLOW_EMPTY:-0}" != 1 ]; then
    dbs="$(q_old "select string_agg(datname, ', ') from pg_database where not datistemplate")"
    die "old database '$OLD_DB' has NO tables: wrong database? Databases on the old server: $dbs. Re-run with MINIMART_OLD_DB=<the right one> (see how the app connects, runbook phase 0). Nothing changed." 3
  fi
}

# Settings stored on the old database / its roles are not part of a dump. Show them with
# ready-to-paste commands, and warn if the two servers' time zone defaults differ.
warn_db_settings() {
  local rows otz ntz
  rows="$(q_old "select format('ALTER DATABASE %I SET %s TO %s;', '$NEW_DB', split_part(c, '=', 1), CASE WHEN split_part(c, '=', 1) IN ('search_path', 'temp_tablespaces', 'session_preload_libraries', 'local_preload_libraries') THEN substr(c, position('=' in c) + 1) ELSE quote_literal(substr(c, position('=' in c) + 1)) END) from pg_db_role_setting s join pg_database d on d.oid = s.setdatabase, unnest(s.setconfig) c where d.datname = current_database() and s.setrole = 0
           union all select format('ALTER ROLE %I IN DATABASE %I SET %s TO %s;', r.rolname, '$NEW_DB', split_part(c, '=', 1), CASE WHEN split_part(c, '=', 1) IN ('search_path', 'temp_tablespaces', 'session_preload_libraries', 'local_preload_libraries') THEN substr(c, position('=' in c) + 1) ELSE quote_literal(substr(c, position('=' in c) + 1)) END) from pg_db_role_setting s join pg_database d on d.oid = s.setdatabase join pg_roles r on r.oid = s.setrole, unnest(s.setconfig) c where d.datname = current_database()")" || rows=
  if [ -n "$rows" ]; then
    warn "the old database has settings stored on it that a dump does NOT carry (search_path, time zone, ...). If the app relies on them, run after the cutover as postgres on $NEW_CONTAINER (db/minimart_setup.sql resets nothing of this):"
    echo "$rows" | sed 's/^/    /'
  fi
  otz="$(q_old "show timezone")"; ntz="$(q_new "$NEW_DB" "show timezone" 2>/dev/null || q_new postgres "show timezone")"
  if [ "$otz" != "$ntz" ]; then
    warn "default time zone differs: old server $otz, $NEW_CONTAINER $ntz. Columns 'timestamp without time zone' with DEFAULT now() would get a different wall clock for NEW rows (existing data is copied unchanged). To keep the old behaviour re-run db/minimart_setup.sql with -v db_timezone=$otz (runbook phase 2), or set it as above."
  fi
}

# ── preflight shared by --rehearse and --cutover ─────────────────────────────
preflight() {
  hdr "Preflight"
  detect_old; detect_new
  info "old: $OLD_CONTAINER  db=$OLD_DB user=$OLD_PGUSER  PostgreSQL $OLD_VER"
  info "new: $NEW_CONTAINER  user=$NEW_PGUSER  PostgreSQL $NEW_VER"
  [ "$(( OLD_VER_NUM / 10000 ))" -le "$(( NEW_VER_NUM / 10000 ))" ] \
    || die "old server (major $((OLD_VER_NUM/10000))) is NEWER than the central server (major $((NEW_VER_NUM/10000))): pg_restore cannot load it. Nothing changed."
  [ "$OLD_SUPER" = "t" ] || warn "login $OLD_PGUSER on the old server is not a superuser: large objects / globals may not be readable"
  require_old_tables
  warn_db_settings

  # roles from db/minimart_setup.sql
  local missing
  missing="$(q_new postgres "select string_agg(r, ' ') from unnest(string_to_array('$ROLE_CHECK', ' ')) r where not exists (select 1 from pg_roles where rolname = r)")" || die "cannot query roles on $NEW_CONTAINER"
  [ -z "$missing" ] || die "role(s) missing on $NEW_CONTAINER: $missing. Run db/minimart_setup.sql first (runbook phase 2, step 2.3). Nothing changed." 3

  # extensions the old DB uses must exist on the new server
  local exts noext
  exts="$(q_old "select extname || ' ' || extversion from pg_extension where extname <> 'plpgsql' order by 1")" || die "cannot read old extensions"
  noext=
  while read -r e v; do
    [ -n "$e" ] || continue
    if [ "$(q_new postgres "select count(*) from pg_available_extensions where name = '$e'")" = "0" ]; then noext="$noext $e"; fi
  done <<< "$exts"
  [ -z "$noext" ] || die "extension(s) used by the old database are NOT available on $NEW_CONTAINER:$noext. The restore would fail. Nothing changed. Options: choose an image/extension for mmi-postgres that has them (that needs a decision: it changes the shared server), or drop the unused extension in the old database first."
  info "extensions in old database: ${exts:-none}  (all available on the new server)"

  # collations the columns use must exist on the new server
  local colls nocoll
  colls="$(q_old "select distinct collname from pg_attribute a join pg_collation c on c.oid = a.attcollation join pg_class t on t.oid = a.attrelid join pg_namespace n on n.oid = t.relnamespace where a.attcollation <> 100 and n.nspname !~ '^pg_' and n.nspname <> 'information_schema' and collname not in ('default','C','POSIX')")" || die "cannot read old collations"
  nocoll=
  for c in $colls; do
    if [ "$(q_new postgres "select count(*) from pg_collation where collname = '$c'")" = "0" ]; then nocoll="$nocoll $c"; fi
  done
  [ -z "$nocoll" ] || die "column collation(s) not available on $NEW_CONTAINER:$nocoll. Nothing changed."

  # encoding / locale
  local oenc ocol octy ncol nenc
  IFS='|' read -r oenc ocol octy <<< "$(q_old "select pg_encoding_to_char(encoding) || '|' || datcollate || '|' || datctype from pg_database where datname = current_database()")"
  info "old database: encoding=$oenc collate=$ocol ctype=$octy"
  [ "$oenc" = "UTF8" ] || warn "old encoding is $oenc, the new database is UTF8: the restore stops (cleanly) on any byte sequence that is not valid UTF-8"
  IFS='|' read -r nenc ncol <<< "$(q_new postgres "select pg_encoding_to_char(encoding) || '|' || datcollate from pg_database where datname = '$NEW_DB'")"
  # What matters is how text SORTS, not the collation's name: postgres:alpine reports en_US.utf8
  # but musl sorts by byte value, while the same name on Debian (glibc) sorts linguistically.
  local sortsql osort nsort sortdb
  sortsql="select ('a' < 'B')::int::text || (chr(233) < 'z')::int::text || ('B' < 'a')::int::text"
  sortdb="$NEW_DB"; [ -n "${ncol:-}" ] || sortdb=postgres
  osort="$(q_old "$sortsql")"; nsort="$(q_new "$sortdb" "$sortsql")"
  if [ "$osort" != "$nsort" ]; then
    warn "text SORT ORDER differs: the old database sorts '${osort}' (a<B, e-acute<z, B<a), the new one '${nsort}' (old collate=$ocol, new=${ncol:-server default}). Data is not affected and indexes are rebuilt, but ORDER BY on text can return rows in another order (e.g. all capitals before lower case in byte order). To keep the old order, create the database with -v lc_collate=C (runbook phase 2, step 2.4, only while minimart is empty)."
  elif [ -n "${ncol:-}" ] && [ "$ncol" != "$ocol" ]; then
    say "  note: collation names differ (old=$ocol, new=$ncol) but both sort text identically"
  fi

  # disk space for the dump
  local need free
  need="$(q_old "select pg_database_size(current_database())/1024")" || need=0
  free="$(df -Pk "$BACKUP_ROOT_PARENT" 2>/dev/null | awk 'NR==2{print $4}')" || free=
  if [ -n "$free" ] && [ "$free" -gt 0 ] 2>/dev/null; then
    if [ "$free" -lt "$((need * 2))" ]; then die "not enough disk space under $BACKUP_ROOT_PARENT: ${free} KB free, old database is ${need} KB (a dump needs up to that, twice for safety)"; fi
    info "disk: ${free} KB free under $BACKUP_ROOT_PARENT, database ${need} KB"
  fi

  # disk space on the central server: a restore needs about the size of the data plus indexes (shared with other systems!)
  local nfree
  nfree="$(nexec df -Pk /var/lib/postgresql/data 2>/dev/null < /dev/null | awk 'NR==2{print $4}')"
  if [ -n "$nfree" ] && [ "$nfree" -gt 0 ] 2>/dev/null; then
    local dbk; dbk="$(q_old "select pg_database_size(current_database())/1024")"
    if [ "$nfree" -lt "$((dbk * 3))" ]; then die "not enough free space for the restore on $NEW_CONTAINER: ${nfree} KB free in /var/lib/postgresql/data, need about 3x the old database (${dbk} KB). The data volume is shared with other systems. Nothing changed." 3; fi
    info "disk on $NEW_CONTAINER: ${nfree} KB free, old database ${dbk} KB"
  else
    warn "could not read free space on $NEW_CONTAINER (df failed): check it by hand before the cutover"
  fi

  # row level security policies naming roles that do not exist on the new server abort the restore
  local pol
  pol="$(q_old "select string_agg(distinct r.rolname, ', ') from pg_policy p, unnest(p.polroles) as x(oid) join pg_roles r on r.oid = x.oid where x.oid <> 0")" || pol=
  if [ -n "$pol" ]; then
    local pmiss=""
    for r in $(echo "$pol" | tr ',' ' '); do [ "$(q_new postgres "select count(*) from pg_roles where rolname = '$r'")" = 0 ] && pmiss="$pmiss $r"; done
    [ -z "$pmiss" ] || die "row level security policies in the old database reference role(s) missing on the new server:$pmiss. The restore would fail. Nothing changed." 3
  fi
}
BACKUP_ROOT_PARENT="$BACKUP_ROOT"
while [ ! -d "$BACKUP_ROOT_PARENT" ] && [ "$BACKUP_ROOT_PARENT" != "/" ]; do BACKUP_ROOT_PARENT="$(dirname "$BACKUP_ROOT_PARENT")"; done

# ── dump / restore primitives ────────────────────────────────────────────────
# dump_old FILE: custom-format dump of the old database, streamed to the host.
dump_old() {
  local out=$1
  run_timeout "$DUMP_TIMEOUT" "$DOCKER" exec -e "PGOPTIONS=-c default_transaction_read_only=on" "$OLD_CONTAINER" \
      pg_dump -U "$OLD_PGUSER" -d "$OLD_DB" -Fc > "$out.partial" < /dev/null \
    || { rm -f "$out.partial"; die "pg_dump of the old database failed"; }
  [ -s "$out.partial" ] || { rm -f "$out.partial"; die "pg_dump produced an empty file"; }
  local lst
  lst="$(run_timeout "$CMD_TIMEOUT" "$DOCKER" exec -i "$OLD_CONTAINER" pg_restore --list < "$out.partial")" \
    || { rm -f "$out.partial"; die "pg_restore cannot read the dump just taken (corrupt file?)"; }
  DUMP_TABLES="$(printf '%s\n' "$lst" | grep -c ' TABLE DATA ')"
  mv "$out.partial" "$out"
}

# restore_into DB FILE: single transaction, strict, no owners, no ACLs. DB must be empty.
restore_into() {
  local db=$1 file=$2
  run_timeout "$DUMP_TIMEOUT" "$DOCKER" exec -i "$NEW_CONTAINER" \
      pg_restore -U "$NEW_PGUSER" -d "$db" --no-owner --no-acl --no-tablespaces --single-transaction --exit-on-error < "$file" 2> "$file.restore.err"
  local rc=$?
  if [ $rc -ne 0 ]; then
    say "pg_restore stderr (first lines):"; head -n 15 "$file.restore.err" | sed 's/^/    /'
    return 1
  fi
  rm -f "$file.restore.err"
}

# post_restore DB: owners -> minimart_owner, grants, sequences, ANALYZE.
post_restore() {
  local db=$1 out
  hdr "Post-restore on $db"
  out="$(printf '%s\n' "$SQL_FIX_OWNERS" | f_new "$db" 2>&1)" || { say "$out"; return 1; }
  echo "$out" | sed 's/^/  /'
  # grants for every existing table/sequence (setup file, no passwords => passwords untouched)
  out="$(f_new postgres -v "dbname=$db" -v ON_ERROR_STOP=1 < "$SETUP_SQL" 2>&1)" || { say "$out"; return 1; }
  say "  grants for minimart_app refreshed (db/minimart_setup.sql)"
  out="$({ printf '%s\n' "$SQL_RESET_SEQS_HEAD"; printf '%s\n' "$SQL_SEQ_DEPS"; printf '%s\n' "$SQL_RESET_SEQS_TAIL"; } | f_new "$db" 2>&1)" || { say "$out"; return 1; }
  echo "$out" | sed 's/^/  /'
  q_new "$db" "ANALYZE" >/dev/null || { say "ANALYZE failed"; return 1; }
  say "  ANALYZE done"
  # ownership must now be clean
  out="$(printf '%s\n' "$SQL_NOT_OWNED" | f_new "$db" 2>&1)" || { say "$out"; return 1; }
  if [ -n "$out" ]; then say "objects NOT owned by minimart_owner:"; echo "$out" | head -20 | sed 's/^/    /'; return 1; fi
  say "  every object is owned by minimart_owner"
}

# ── verify: old vs DB ────────────────────────────────────────────────────────
VFAIL=0
vfail() { VFAIL=$((VFAIL + 1)); say "  FAIL  $*"; }
vpass() { say "  PASS  $*"; }

verify_against() {
  local db=$1 tmp stmts
  local CMD_TIMEOUT="${MINIMART_VERIFY_TIMEOUT:-3600}"   # scanning every row of a big table takes a while
  VFAIL=0
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/minimart_verify.XXXXXX")"
  hdr "Verify: old ($OLD_DB@$OLD_CONTAINER) vs new ($db@$NEW_CONTAINER)"
  # 1. fingerprints
  stmts="$tmp/stmts.sql"
  { printf '%s\n' "$SQL_SESSION"; gen_fingerprint_sql | f_old; } > "$stmts" || { VFAIL=$((VFAIL+1)); say "  FAIL  cannot generate the fingerprint queries on the old database"; rm -rf "$tmp"; return 1; }
  f_old < "$stmts" > "$tmp/old.fp" 2> "$tmp/old.err" || { vfail "fingerprint query failed on old: $(head -n 3 "$tmp/old.err")"; }
  # table-by-table errors on the new side must not hide the rest: do not stop on error
  nexec psql -U "$NEW_PGUSER" -d "$db" -X -q -At -v ON_ERROR_STOP=0 -f - < "$stmts" > "$tmp/new.fp" 2> "$tmp/new.err"
  local nold nnew
  nold="$(grep -c . "$tmp/old.fp")"; nnew="$(grep -c . "$tmp/new.fp")"
  awk '
    function key(l,   i) { i = index(l, "|rows="); return i ? substr(l, 1, i - 1) : l }
    FILENAME==ARGV[1] { k=key($0); old[k]=$0; order[++n]=k; next }
    { new[key($0)]=$0 }
    END {
      for (i=1;i<=n;i++) { k=order[i]
        if (!(k in new)) { printf "FAIL\t%s\tmissing in new database\n", k; continue }
        if (old[k]==new[k]) { r=substr(old[k], length(k)+2); sub(/\|.*/, "", r); printf "PASS\t%s\t%s\n", k, r; continue }
        na=split(substr(old[k], length(k)+2), a, "|"); split(substr(new[k], length(k)+2), b, "|"); d=""
        for (j=1;j<=na;j++) if (a[j]!=b[j]) d=d " [" a[j] " <> " b[j] "]"
        printf "FAIL\t%s\tdiffers:%s\n", k, d }
      for (k in new) if (!(k in old)) printf "FAIL\t%s\textra table in new database\n", k
    }' "$tmp/old.fp" "$tmp/new.fp" > "$tmp/fp.cmp"
  local line st
  while IFS=$'\t' read -r st k rest; do
    if [ "$st" = PASS ]; then vpass "$k  $rest"; else vfail "$k  $rest"; fi
  done < "$tmp/fp.cmp"
  # relations that exist only in the new database
  printf '%s\n' "WITH rels AS ($SQL_RELS) SELECT sch || '.' || rel FROM rels ORDER BY 1;" | f_new "$db" > "$tmp/new.rels" 2>/dev/null || vfail "cannot list the relations of the new database"
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    grep -qxF -- "$r" <(sed 's/|rows=.*//' "$tmp/old.fp") || vfail "$r  extra table in new database"
  done < "$tmp/new.rels"
  if [ -s "$tmp/new.err" ]; then say "  (errors reported by the new database while counting:)"; head -n 5 "$tmp/new.err" | sed 's/^/    /'; fi
  [ "$nold" -gt 0 ] || say "  (the old database has no tables: nothing to compare per table)"

  # 2. inventory
  printf '%s\n' "$SQL_SESSION" "$SQL_INVENTORY" | f_old > "$tmp/old.inv" 2>"$tmp/old.inv.err" || vfail "inventory query failed on old: $(head -n 2 "$tmp/old.inv.err" | tr '\n' ' ')"
  printf '%s\n' "$SQL_SESSION" "$SQL_INVENTORY" | f_new "$db" > "$tmp/new.inv" 2>"$tmp/new.inv.err" || vfail "inventory query failed on new: $(head -n 2 "$tmp/new.inv.err" | tr '\n' ' ')"
  if diff "$tmp/old.inv" "$tmp/new.inv" > "$tmp/inv.diff"; then vpass "catalog inventory identical ($(grep -c . "$tmp/old.inv") lines: schemas, tables, indexes, constraints, triggers, functions, types, extensions, column layout, large objects)"
  else vfail "catalog inventory differs (< old, > new):"; head -n 12 "$tmp/inv.diff" | sed 's/^/        /'; fi

  # 3. sequences: same set; new position >= old position; always above the data
  {
    echo "SET timezone='UTC';"
    echo "SELECT 'seqset|' || coalesce(string_agg(schemaname || '.' || sequencename, ',' ORDER BY schemaname, sequencename), '') FROM pg_sequences WHERE schemaname !~ '^pg_' AND schemaname <> 'information_schema';"
    echo "SELECT 'seqpos|' || schemaname || '.' || sequencename || '|' || coalesce(last_value::text, '~') || '|' || increment_by FROM pg_sequences WHERE schemaname !~ '^pg_' AND schemaname <> 'information_schema' ORDER BY 1;"
  } > "$tmp/seq.sql"
  f_old < "$tmp/seq.sql" > "$tmp/old.seq" 2>/dev/null || vfail "sequence query failed on old"
  f_new "$db" < "$tmp/seq.sql" > "$tmp/new.seq" 2>/dev/null || vfail "sequence query failed on new"
  if [ "$(grep '^seqset|' "$tmp/old.seq")" = "$(grep '^seqset|' "$tmp/new.seq")" ]; then vpass "same set of sequences"; else vfail "sequence set differs"; fi
  awk -F'|' '
    FILENAME==ARGV[1] { if ($1=="seqpos") old[$2]=$3; next }
    $1=="seqpos" { k=$2; n=$3; inc=$4+0;
      o=old[k];
      # ascending sequences must not move back, descending ones must not move up
      if (o=="~" || (n!="~" && (inc >= 0 ? n+0 >= o+0 : n+0 <= o+0))) print "PASS|" k "|last_value " n " (old " o ")"; else print "FAIL|" k "|new last_value " n " is BEHIND old " o }' \
    "$tmp/old.seq" "$tmp/new.seq" > "$tmp/seq.cmp"
  while IFS='|' read -r st k rest; do
    if [ "$st" = PASS ]; then :; else vfail "sequence $k  $rest"; fi
  done < "$tmp/seq.cmp"
  vpass "$(grep -c '^PASS' "$tmp/seq.cmp") sequence position(s) not behind the old server"
  # next value must be above the data of every column fed by a sequence
  {
    printf '%s\n' "SET client_min_messages = warning;"
    printf '%s\n' "WITH deps AS ($SQL_SEQ_DEPS)"
    printf '%s\n' "SELECT format('SELECT %L || ''|'' || CASE WHEN s.increment_by < 0 THEN ''skip'' WHEN m.mx IS NULL THEN ''ok'' WHEN s.last_value IS NOT NULL AND s.last_value >= m.mx THEN ''ok'' WHEN s.last_value IS NULL AND s.start_value > m.mx THEN ''ok'' ELSE ''bad'' END || ''|max in data '' || coalesce(m.mx::text, ''none'') || '', sequence at '' || coalesce(s.last_value::text, ''unused'') FROM (SELECT max(%I)::numeric AS mx FROM %I.%I) m, pg_sequences s WHERE s.schemaname = %L AND s.sequencename = %L;',"
    printf '%s\n' "  seq_sch || '.' || seq || '(' || tbl || '.' || col || ')', col, tbl_sch, tbl, seq_sch, seq) FROM deps ORDER BY 1;"
  } > "$tmp/seqgen.sql"
  f_new "$db" < "$tmp/seqgen.sql" 2>/dev/null > "$tmp/seqchk.sql" || vfail "cannot build the sequence-vs-data check"
  f_new "$db" < "$tmp/seqchk.sql" 2>/dev/null | awk -F'|' '
      $2=="ok" { ok++ }
      $2=="skip" { skipped++ }
      $2=="bad" { bad++; print "FAIL|" $1 "|" $3 }
      END { print "SUMMARY|" ok+0 "|" bad+0 }' > "$tmp/seqchk.out"
  while IFS='|' read -r st a b; do
    case "$st" in FAIL) vfail "sequence collision: $a  $b" ;; SUMMARY) [ "${b:-0}" = 0 ] && vpass "$a sequence/column pair(s): next value is above the largest stored value" ;; esac
  done < "$tmp/seqchk.out"

  # 4. ownership
  local nown
  nown="$(printf '%s\n' "$SQL_NOT_OWNED" | f_new "$db" 2>&1)" || { vfail "ownership query failed"; nown=; }
  if [ -n "$nown" ]; then vfail "objects not owned by minimart_owner:"; echo "$nown" | head -n 10 | sed 's/^/        /'; else vpass "every object is owned by minimart_owner"; fi

  rm -rf "$tmp"
  if [ "$VFAIL" -eq 0 ]; then
    say "VERIFY OK: all checks passed"; log "verify against $db OK"; return 0
  fi
  say "VERIFY FAILED: $VFAIL check(s) failed"; log "verify against $db FAILED ($VFAIL)"; return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# MODES
# ─────────────────────────────────────────────────────────────────────────────

# connections to the old database other than ours
old_connections() {
  q_old "select usename || '|' || coalesce(nullif(application_name, ''), '-') || '|' || coalesce(client_addr::text, 'local') || '|' || state || '|' || pid
           from pg_stat_activity
          where datname = current_database() and pid <> pg_backend_pid() and backend_type = 'client backend'
          order by usename, pid"
}

mode_inspect() {
  detect_old
  hdr "Old database"
  say "container=$OLD_CONTAINER  login=$OLD_PGUSER  database=$OLD_DB  (every session of this report is read-only)"
  {
    cat <<SQL
\\set ON_ERROR_STOP off
\\pset footer off
\\pset null '-'
\\echo '== Server =='
SELECT version() AS version;
SELECT current_database() AS database, pg_encoding_to_char(encoding) AS encoding, datcollate AS collate, datctype AS ctype,
       pg_size_pretty(pg_database_size(oid)) AS size, current_setting('timezone') AS server_timezone,
       current_setting('max_connections') AS max_connections
  FROM pg_database WHERE datname = current_database();
\\echo '-- databases on this server'
SELECT datname, pg_size_pretty(pg_database_size(oid)) AS size, datallowconn AS allow_conn FROM pg_database WHERE NOT datistemplate ORDER BY 1;
\\echo '-- settings stored on the database / roles (pg_db_role_setting)'
SELECT coalesce(d.datname, '(all)') AS database, coalesce(r.rolname, '(all)') AS role, s.setconfig
  FROM pg_db_role_setting s LEFT JOIN pg_database d ON d.oid = s.setdatabase LEFT JOIN pg_roles r ON r.oid = s.setrole;
\\echo ''
\\echo '== Tables (exact row counts) =='
WITH rels AS ($SQL_RELS)
SELECT string_agg(format('SELECT %L AS "table", %L AS kind, count(*) AS rows, pg_size_pretty(pg_total_relation_size(%L::regclass)) AS total_size FROM %I.%I',
                  sch || '.' || rel, CASE relkind WHEN 'm' THEN 'matview' WHEN 'p' THEN 'partitioned' ELSE 'table' END,
                  format('%I.%I', sch, rel), sch, rel), E'\nUNION ALL\n' ORDER BY sch, rel) || E'\nORDER BY 1' FROM rels \\gexec
\\echo ''
\\echo '== Totals =='
SELECT (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE c.relkind IN ('r','p') AND n.nspname !~ '^pg_' AND n.nspname <> 'information_schema') AS tables,
       (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE c.relkind = 'v' AND n.nspname !~ '^pg_' AND n.nspname <> 'information_schema') AS views,
       (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE c.relkind = 'm' AND n.nspname !~ '^pg_' AND n.nspname <> 'information_schema') AS matviews,
       (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE c.relkind = 'S' AND n.nspname !~ '^pg_' AND n.nspname <> 'information_schema') AS sequences,
       (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname !~ '^pg_' AND n.nspname <> 'information_schema') AS functions,
       (SELECT count(*) FROM pg_trigger WHERE NOT tgisinternal) AS triggers,
       (SELECT count(*) FROM pg_namespace WHERE nspname !~ '^pg_' AND nspname <> 'information_schema') AS schemas;
\\echo '-- schemas'
SELECT nspname AS schema, pg_get_userbyid(nspowner) AS owner FROM pg_namespace WHERE nspname !~ '^pg_' AND nspname <> 'information_schema' ORDER BY 1;
\\echo '-- tables WITHOUT a primary key'
SELECT n.nspname || '.' || c.relname AS table_without_pk FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE c.relkind IN ('r','p') AND n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'
   AND NOT EXISTS (SELECT 1 FROM pg_constraint k WHERE k.conrelid = c.oid AND k.contype = 'p') ORDER BY 1;
\\echo '-- unlogged / partitioned / inherited / foreign tables (need attention if any)'
SELECT n.nspname || '.' || c.relname AS "table", CASE WHEN c.relpersistence = 'u' THEN 'UNLOGGED (not in a pg_dump? it is, but data is lost on crash)' WHEN c.relkind = 'p' THEN 'partitioned' WHEN c.relkind = 'f' THEN 'foreign table' WHEN c.relispartition THEN 'partition' ELSE 'inherits' END AS note
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'
   AND (c.relpersistence = 'u' OR c.relkind IN ('p','f') OR c.relispartition OR EXISTS (SELECT 1 FROM pg_inherits i WHERE i.inhrelid = c.oid)) ORDER BY 1;
\\echo ''
\\echo '== Extensions (must exist on the central server) =='
SELECT extname, extversion, n.nspname AS schema FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace ORDER BY 1;
\\echo ''
\\echo '== Sequences (and what they feed) =='
SELECT s.schemaname || '.' || s.sequencename AS sequence, s.data_type, s.last_value, s.increment_by, d.tbl_sch || '.' || d.tbl || '.' || d.col AS feeds
  FROM pg_sequences s LEFT JOIN ($SQL_SEQ_DEPS) d ON d.seq_sch = s.schemaname AND d.seq = s.sequencename
 WHERE s.schemaname !~ '^pg_' AND s.schemaname <> 'information_schema' ORDER BY 1;
\\echo ''
\\echo '== Large objects =='
SELECT count(*) AS large_objects, coalesce(pg_size_pretty(sum(octet_length(data))), '0 bytes') AS size FROM pg_largeobject;
\\echo ''
\\echo '== Other objects that a restore must reproduce =='
SELECT 'event triggers' AS what, count(*) FROM pg_event_trigger
UNION ALL SELECT 'publications', count(*) FROM pg_publication
UNION ALL SELECT 'subscriptions (cluster-wide)', count(*) FROM pg_subscription
UNION ALL SELECT 'foreign servers', count(*) FROM pg_foreign_server
UNION ALL SELECT 'replication slots', count(*) FROM pg_replication_slots
UNION ALL SELECT 'custom collations', count(*) FROM pg_collation c JOIN pg_namespace n ON n.oid = c.collnamespace WHERE n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'
UNION ALL SELECT 'columns using a non-default collation', count(*) FROM pg_attribute a JOIN pg_class t ON t.oid = a.attrelid JOIN pg_namespace n ON n.oid = t.relnamespace WHERE a.attcollation NOT IN (0, 100) AND n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'
UNION ALL SELECT 'row level security policies', count(*) FROM pg_policy;
\\echo ''
\\echo '== Roles (cluster-wide; the new server gets only minimart_owner/app/ro) =='
SELECT rolname, rolsuper AS superuser, rolcanlogin AS login, rolreplication AS replication,
       (SELECT count(*) FROM pg_class c WHERE c.relowner = r.oid AND c.relkind IN ('r','p','v','m','S')) AS owns_relations
  FROM pg_roles r WHERE rolname !~ '^pg_' ORDER BY 1;
\\echo '-- role membership'
SELECT pg_get_userbyid(roleid) AS role, pg_get_userbyid(member) AS member FROM pg_auth_members WHERE pg_get_userbyid(roleid) !~ '^pg_';
\\echo '-- object privileges granted to roles other than the owner (will NOT be carried over, --no-acl)'
SELECT n.nspname || '.' || c.relname AS relation, c.relacl::text AS acl FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE c.relacl IS NOT NULL AND c.relkind IN ('r','p','v','m','S') AND n.nspname !~ '^pg_' AND n.nspname <> 'information_schema' ORDER BY 1 LIMIT 40;
\\echo ''
\\echo '== Columns that look sensitive (candidates, by name) =='
SELECT n.nspname || '.' || c.relname AS "table", a.attname AS "column", format_type(a.atttypid, a.atttypmod) AS type
  FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE a.attnum > 0 AND NOT a.attisdropped AND c.relkind IN ('r','p','m') AND n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'
   AND a.attname ~* '(password|passwd|pwd|hash|token|secret|api_?key|otp|(^|_)pin($|_)|card|cvv|iban|ssn|salt)' ORDER BY 1, 2;
\\echo ''
\\echo '== Time columns: kind, default, and what the latest value suggests =='
\\echo 'timestamptz = absolute time, safe. "timestamp" (no time zone) holds a wall clock: UTC or local? Compare the latest value with NOW.'
\\echo 'This is a REPORT only: nothing is changed. (Procurement had UTC wall-clock times stored in local columns.)'
\\set local_tz '$LOCAL_TZ'
SELECT string_agg(
  format('SELECT %L AS "table", %L AS "column", %L AS kind, %L AS "default", min(%I)::text AS min_value, max(%I)::text AS max_value, %s AS verdict FROM %I.%I',
     c.relname_q, a.attname, format_type(a.atttypid, a.atttypmod), coalesce(pg_get_expr(d.adbin, d.adrelid), '-'), a.attname, a.attname,
     CASE WHEN a.atttypid = 'timestamp'::regtype THEN
       format('CASE WHEN max(%I) IS NULL THEN ''no data''
                    WHEN max(%I) < (now() AT TIME ZONE ''UTC'') - interval ''2 days'' THEN ''inconclusive: latest value is older than 2 days''
                    WHEN abs(extract(epoch FROM max(%I) - (now() AT TIME ZONE ''UTC''))) < 7200 AND abs(extract(epoch FROM max(%I) - (now() AT TIME ZONE %L))) >= 7200 THEN ''looks like UTC wall clock''
                    WHEN abs(extract(epoch FROM max(%I) - (now() AT TIME ZONE %L))) < 7200 AND abs(extract(epoch FROM max(%I) - (now() AT TIME ZONE ''UTC''))) >= 7200 THEN ''looks like LOCAL (%s) wall clock''
                    ELSE ''ambiguous'' END', a.attname, a.attname, a.attname, a.attname, :'local_tz', a.attname, :'local_tz', a.attname, :'local_tz')
          WHEN a.atttypid = 'timestamptz'::regtype THEN '''absolute time (fine)'''
          ELSE '''date/time without zone (no shift possible)''' END,
     c.nspname, c.relname),
  E'\nUNION ALL\n' ORDER BY c.nspname, c.relname, a.attnum) || E'\nORDER BY 1, 2'
  FROM pg_attribute a
  JOIN (SELECT c.oid, n.nspname, c.relname, format('%I.%I', n.nspname, c.relname) AS relname_q FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE c.relkind IN ('r','p','m') AND n.nspname !~ '^pg_' AND n.nspname <> 'information_schema') c ON c.oid = a.attrelid
  LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
 WHERE a.attnum > 0 AND NOT a.attisdropped AND a.atttypid IN ('timestamptz'::regtype, 'timestamp'::regtype, 'date'::regtype, 'time'::regtype, 'timetz'::regtype) \\gexec
\\echo ''
\\echo '== Who is connected to this database right now =='
SELECT usename, coalesce(nullif(application_name, ''), '-') AS application, coalesce(client_addr::text, 'local socket') AS from_addr, state, count(*) AS connections,
       max(now() - backend_start)::interval(0) AS oldest
  FROM pg_stat_activity WHERE datname = current_database() AND pid <> pg_backend_pid() AND backend_type = 'client backend'
 GROUP BY 1, 2, 3, 4 ORDER BY 1, 2;
\\echo '-- connections to the whole server (all databases)'
SELECT coalesce(datname, '(none)') AS database, count(*) FROM pg_stat_activity WHERE backend_type = 'client backend' GROUP BY 1 ORDER BY 1;
SQL
  } | p_old
  local rc=$?
  [ $rc -eq 0 ] || die "inspect failed (psql exit $rc)"
  hdr "Read next"
  say "  * extensions: every one must be available on $NEW_CONTAINER (the cutover checks and stops before restoring)."
  say "  * collate: Alpine images sort ORDER BY in byte order; mmi-postgres is Debian. See the runbook phase 2, steps 2.2 and 2.4 (lc_collate)."
  say "  * time columns: only a report. Do not change data during the migration."
}

mode_backup() {
  detect_old
  local dir="$BACKUP_ROOT/pre_migration_$TS" n
  require_old_tables
  umask 077
  mkdir -p "$dir" || die "cannot create $dir"
  chmod 700 "$BACKUP_ROOT" "$dir" 2>/dev/null
  hdr "Backup of the OLD database -> $dir"
  info "database $OLD_DB on $OLD_CONTAINER (PostgreSQL $OLD_VER)"
  # 1. custom-format dump
  dump_old "$dir/old.dump" || exit 1
  info "old.dump: $(du -h "$dir/old.dump" | cut -f1), $DUMP_TABLES table data entries"
  # 2. schema only, plain SQL
  run_timeout "$DUMP_TIMEOUT" "$DOCKER" exec -e "PGOPTIONS=-c default_transaction_read_only=on" "$OLD_CONTAINER" \
      pg_dump -U "$OLD_PGUSER" -d "$OLD_DB" -s > "$dir/schema.sql" < /dev/null || die "schema dump failed"
  [ -s "$dir/schema.sql" ] || die "schema dump is empty"
  info "schema.sql: $(wc -l < "$dir/schema.sql" | tr -d ' ') lines"
  # 3. roles of the old server (globals; contains password hashes -> mode 600)
  if run_timeout "$DUMP_TIMEOUT" "$DOCKER" exec -e "PGOPTIONS=-c default_transaction_read_only=on" "$OLD_CONTAINER" \
        pg_dumpall -U "$OLD_PGUSER" --globals-only > "$dir/globals.sql" < /dev/null 2>"$dir/globals.err"; then
    rm -f "$dir/globals.err"; info "globals.sql: roles of the old server saved"
  else
    warn "pg_dumpall --globals-only failed (see $dir/globals.err); the data dump is unaffected"
  fi
  # 4. exact per-table counts
  local gen
  gen="$(gen_counts_sql | f_old)" || die "cannot generate the count queries"
  if [ -n "$gen" ]; then printf '%s\n' "$gen" | f_old > "$dir/counts.tsv" || die "counting rows failed"; else : > "$dir/counts.tsv"; fi
  info "counts.tsv: $(grep -c . "$dir/counts.tsv") table(s), $(awk -F'\t' '{s+=$2} END{print s+0}' "$dir/counts.tsv") rows"
  # 5. manifest + checksums
  {
    echo "created=$(date -u +%Y-%m-%dT%H:%M:%SZ)"; echo "old_container=$OLD_CONTAINER"; echo "old_db=$OLD_DB"; echo "old_user=$OLD_PGUSER"; echo "old_server=$OLD_VER"
    echo "table_data_entries=$DUMP_TABLES"
  } > "$dir/MANIFEST"
  ( cd "$dir" && { sha256sum old.dump schema.sql counts.tsv 2>/dev/null || shasum -a 256 old.dump schema.sql counts.tsv; } > SHA256SUMS )
  date -u +%Y-%m-%dT%H:%M:%SZ > "$dir/COMPLETE"
  info "OK $dir ($(du -sh "$dir" | cut -f1))"
}

mode_rehearse() {
  BACKUP_ROOT_PARENT="$BACKUP_ROOT"; while [ ! -d "$BACKUP_ROOT_PARENT" ] && [ "$BACKUP_ROOT_PARENT" != "/" ]; do BACKUP_ROOT_PARENT="$(dirname "$BACKUP_ROOT_PARENT")"; done
  preflight
  [ "$REHEARSAL_DB" != "$NEW_DB" ] || die "refusing: the rehearsal database must not be $NEW_DB" 3
  umask 077
  mkdir -p "$BACKUP_ROOT/rehearsal_$TS" || die "cannot create $BACKUP_ROOT/rehearsal_$TS"
  local dir="$BACKUP_ROOT/rehearsal_$TS" t0 t1 t2 t3 t4 t5 rc
  created=0
  cleanup_rehearsal() {
    if [ "$created" = 1 ] && [ "${MINIMART_KEEP_REHEARSAL:-0}" != 1 ]; then
      q_new postgres "select pg_terminate_backend(pid) from pg_stat_activity where datname = '$REHEARSAL_DB' and pid <> pg_backend_pid()" >/dev/null 2>&1
      q_new postgres "drop database if exists \"$REHEARSAL_DB\"" >/dev/null 2>&1 && say "  scratch database $REHEARSAL_DB dropped"
    fi
  }
  trap cleanup_rehearsal EXIT
  hdr "Rehearsal into $REHEARSAL_DB (the real $NEW_DB is not touched)"
  # a leftover from an earlier failed rehearsal is ours: remove it
  if [ "$(q_new postgres "select count(*) from pg_database where datname = '$REHEARSAL_DB'")" != 0 ]; then
    # only a scratch database made by this script may be dropped (a typo in MINIMART_REHEARSAL_DB must never hit a real one)
    [ "$(q_new postgres "select coalesce(shobj_description(oid, 'pg_database'), '') from pg_database where datname = '$REHEARSAL_DB'")" = "minimart-rehearsal-scratch" ] \
      || die "database $REHEARSAL_DB exists and is not a rehearsal scratch database made by this script: refusing to drop it. Nothing changed." 3
    warn "$REHEARSAL_DB exists from an earlier run: dropping it first"
    q_new postgres "select pg_terminate_backend(pid) from pg_stat_activity where datname = '$REHEARSAL_DB' and pid <> pg_backend_pid()" >/dev/null
    q_new postgres "drop database \"$REHEARSAL_DB\"" >/dev/null || die "cannot drop the old $REHEARSAL_DB"
  fi
  t0=$SECONDS
  dump_old "$dir/old.dump" || exit 1
  t1=$SECONDS
  info "dump: $((t1 - t0)) s, $(du -h "$dir/old.dump" | cut -f1), $DUMP_TABLES table data entries"
  local coll
  coll="$(collation_clause)"
  q_new postgres "create database \"$REHEARSAL_DB\" owner $OWNER_ROLE encoding 'UTF8' $coll template template0" >/dev/null || die "cannot create $REHEARSAL_DB"
  created=1
  q_new postgres "comment on database \"$REHEARSAL_DB\" is 'minimart-rehearsal-scratch'" >/dev/null || die "cannot mark $REHEARSAL_DB"
  # same privileges layout as the real DB (public schema owned by minimart_owner)
  q_new "$REHEARSAL_DB" "alter schema public owner to $OWNER_ROLE" >/dev/null || die "cannot prepare $REHEARSAL_DB"
  restore_into "$REHEARSAL_DB" "$dir/old.dump" || { say "restore FAILED (dump kept in $dir)"; exit 1; }
  t2=$SECONDS
  info "restore: $((t2 - t1)) s"
  post_restore "$REHEARSAL_DB" || { say "post-restore FAILED"; exit 1; }
  t3=$SECONDS
  info "post-restore (owners, grants, sequences, analyze): $((t3 - t2)) s"
  verify_against "$REHEARSAL_DB"; rc=$?
  t4=$SECONDS
  info "verify: $((t4 - t3)) s"
  local oc; oc="$(old_connections)"
  if [ -n "$oc" ] && [ "$rc" -ne 0 ]; then
    warn "the old database had $(echo "$oc" | grep -c .) live connection(s) during this rehearsal: rows written by the app since the dump show up as mismatches. That is expected while the app runs; the real test is --cutover with the app stopped."
  fi
  hdr "Timing"
  say "  dump $((t1 - t0)) s + restore $((t2 - t1)) s + post-restore $((t3 - t2)) s + verify $((t4 - t3)) s = $((t4 - t0)) s"
  say "  expected cutover downtime: about $(( (t4 - t0 + 59) / 60 )) minute(s) of database work, plus stopping/starting the app and the browser test."
  if [ "$rc" -eq 0 ]; then
    rm -rf "$dir"
    info "REHEARSAL OK ($((t4 - t0)) s total). The scratch dump was deleted."
    return 0
  fi
  say "REHEARSAL FAILED: do not cut over. Dump kept in $dir"
  return 1
}

# locale clause for CREATE DATABASE: explicit env, else copy the existing real DB, else server default
collation_clause() {
  local c ct
  c="${MINIMART_LC_COLLATE:-}"; ct="${MINIMART_LC_CTYPE:-$c}"
  if [ -z "$c" ]; then
    IFS='|' read -r c ct <<< "$(q_new postgres "select datcollate || '|' || datctype from pg_database where datname = '$NEW_DB'")"
  fi
  if [ -n "$c" ]; then printf "lc_collate '%s' lc_ctype '%s'" "$c" "$ct"; fi
}

mode_cutover() {
  preflight
  hdr "Cutover guards"
  [ "$OLD_SUPER" = "t" ] || die "the cutover needs a SUPERUSER login on the old server (a normal login cannot see other users' connections, so the 'app is stopped' check would be blind). Use MINIMART_OLD_PGUSER=<superuser>. Nothing changed." 3
  # order of phases: a backup of the old database must exist
  local bk
  bk="$(ls -1d "$BACKUP_ROOT"/pre_migration_*/ 2>/dev/null | while read -r d; do [ -f "${d}COMPLETE" ] && [ -s "${d}old.dump" ] && echo "$d"; done | tail -n 1)"
  [ -n "$bk" ] || die "no completed backup in $BACKUP_ROOT/pre_migration_*/ . Run: scripts/minimart_migrate.sh --backup-old   (phase 1). Nothing changed." 3
  info "backup of the old database found: $bk"

  # the target must be empty (or a failed earlier attempt of ours)
  local exists marker ntab
  exists="$(q_new postgres "select count(*) from pg_database where datname = '$NEW_DB'")"
  [ "$exists" = 1 ] || die "database $NEW_DB does not exist on $NEW_CONTAINER. Run db/minimart_setup.sql first (runbook phase 2, step 2.3). Nothing changed." 3
  marker="$(marker_get)"
  ntab="$(q_new "$NEW_DB" "select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.relkind in ('r','p','v','m','S','f') and n.nspname !~ '^pg_' and n.nspname <> 'information_schema'")"
  local reset=0
  case "$marker" in
    *"cutover-complete"*) die "the cutover into $NEW_DB was already completed ($marker). Refusing to touch it: the app may have written to it since. To redo it deliberately, see the runbook (rollback)." 3 ;;
    *"restored-unverified"*|*"restoring"*) say "  $NEW_DB holds an earlier attempt that was never verified ($marker): it will be dropped and rebuilt"; reset=1 ;;
    *) if [ "$ntab" != 0 ]; then die "$NEW_DB is not empty ($ntab relation(s)) and was not written by this script: refusing to touch it. Nothing changed." 3; fi ;;
  esac

  # the app must be stopped: no other connection to the old database
  local conns
  conns="$(old_connections)" || die "cannot read connections of the old database"
  if [ -n "$conns" ]; then
    say "The old database still has connections (user|application|from|state|pid):"
    echo "$conns" | sed 's/^/    /'
    die "stop the minimart app first (runbook phase 3, step 3.1), wait a few seconds and run this again. Nothing changed." 3
  fi
  info "old database has no other connections: app is stopped"

  umask 077
  local dir="$BACKUP_ROOT/cutover_$TS" t0 t1 t2 t3 t4 coll
  mkdir -p "$dir" || die "cannot create $dir"
  t0=$SECONDS
  hdr "Final dump of the old database -> $dir/final.dump"
  dump_old "$dir/final.dump" || exit 1
  t1=$SECONDS
  info "dump: $((t1 - t0)) s, $(du -h "$dir/final.dump" | cut -f1), $DUMP_TABLES table data entries"
  conns="$(old_connections)"
  [ -z "$conns" ] || { echo "$conns" | sed 's/^/    /'; die "someone connected to the old database during the dump: its data may have changed. Nothing was restored. Stop whatever connects (the app restarting by itself?) and run again." 3; }

  if [ "$reset" = 1 ]; then
    hdr "Rebuilding $NEW_DB (earlier attempt)"
    local live
    live="$(q_new postgres "select coalesce(string_agg(usename || '@' || coalesce(client_addr::text, 'local'), ', '), '') from pg_stat_activity where datname = '$NEW_DB' and usename in ('minimart_app', 'minimart_ro')")"
    [ -z "$live" ] || die "refusing to rebuild $NEW_DB: the application roles are connected to it ($live). If the app has been started on this database it may hold newer data. Nothing changed." 3
    coll="$(collation_clause)"
    local keep_tz
    keep_tz="$(q_new postgres "select substring(c from 10) from pg_db_role_setting s join pg_database d on d.oid = s.setdatabase, unnest(s.setconfig) c where d.datname = '$NEW_DB' and s.setrole = 0 and c ilike 'timezone=%'")"
    q_new postgres "select pg_terminate_backend(pid) from pg_stat_activity where datname = '$NEW_DB' and pid <> pg_backend_pid()" >/dev/null
    q_new postgres "drop database \"$NEW_DB\"" >/dev/null || die "cannot drop $NEW_DB"
    local cl_c cl_t
    cl_c="$(printf '%s' "$coll" | sed -n "s/.*lc_collate '\\([^']*\\)'.*/\\1/p")"; cl_t="$(printf '%s' "$coll" | sed -n "s/.*lc_ctype '\\([^']*\\)'.*/\\1/p")"
    local sv=(-v "dbname=$NEW_DB"); [ -n "$cl_c" ] && sv+=(-v "lc_collate=$cl_c" -v "lc_ctype=$cl_t")
    [ -n "$keep_tz" ] && sv+=(-v "db_timezone=$keep_tz")
    f_new postgres "${sv[@]}" < "$SETUP_SQL" > /dev/null 2>&1 || die "cannot recreate $NEW_DB with db/minimart_setup.sql"
  fi

  hdr "Restore into $NEW_DB"
  marker_set restoring
  restore_into "$NEW_DB" "$dir/final.dump" || die "restore failed (single transaction: nothing was applied). Dump kept in $dir. Fix the error shown above and run again; the old database is untouched."
  marker_set restored-unverified
  t2=$SECONDS
  info "restore: $((t2 - t1)) s"
  post_restore "$NEW_DB" || die "post-restore step failed. $NEW_DB is marked unverified; running --cutover again rebuilds it. The old database is untouched."
  t3=$SECONDS
  verify_against "$NEW_DB" || die "verification FAILED: do NOT start the app on the new database. The old database is untouched; running --cutover again rebuilds $NEW_DB."
  conns="$(old_connections)"
  [ -z "$conns" ] || { echo "$conns" | sed 's/^/    /'; die "the old database got a connection after the dump: data may differ. Do not use $NEW_DB; stop the old container and run --cutover again." 3; }
  t4=$SECONDS
  marker_set cutover-complete || die "the data is verified, but the completion marker could not be written. Do NOT run --cutover again (it would rebuild $NEW_DB). Set it by hand: docker exec $NEW_CONTAINER psql -U $NEW_PGUSER -X -c \"COMMENT ON DATABASE $NEW_DB IS 'minimart-migration: cutover-complete manual'\"" 
  hdr "Cutover data move complete"
  say "  dump $((t1 - t0)) s, restore $((t2 - t1)) s, post-restore $((t3 - t2)) s, verify $((t4 - t3)) s"
  say "  final dump kept at $dir/final.dump"
  say "  Next: point the app at $NEW_CONTAINER / $NEW_DB as minimart_app (runbook phase 3), start it, test in the browser."
  say "  The old container is still running and untouched: it is the rollback."
  info "CUTOVER OK $NEW_DB from $OLD_DB@$OLD_CONTAINER ($((t4 - t0)) s)"
}

mode_verify() {
  detect_old; detect_new
  [ "$(q_new postgres "select count(*) from pg_database where datname = '$NEW_DB'")" = 1 ] || die "database $NEW_DB does not exist on $NEW_CONTAINER"
  local conns; conns="$(old_connections)"
  [ -z "$conns" ] || warn "the old database has $(echo "$conns" | grep -c .) connection(s): rows written by the app since the dump will show as mismatches"
  verify_against "$NEW_DB"
}

mode_rollback() {
  local bk dir
  dir="$(ls -1d "$BACKUP_ROOT"/cutover_*/ 2>/dev/null | tail -n 1)"; bk="$(ls -1d "$BACKUP_ROOT"/pre_migration_*/ 2>/dev/null | tail -n 1)"
  cat <<EOF
Manual rollback of the minimart migration. Nothing below runs automatically.
Read this first: ANY data the app wrote to mmi-postgres / $NEW_DB after the cutover is NOT in the
old container. Going back means going back to the data as of the final dump${dir:+ ($dir)}.

Situation A: the old container is still running (phase 4 not done yet)
  1. Stop the minimart app.
  2. Put the app's connection settings back (the backup of the file made in phase 3):
       cp -p <the .bak you made in phase 3> <the original file>     (the runbook names both paths)
  3. Start the app. The old database is unchanged since the final dump.

Situation B: the old container was stopped (phase 4 done)
  1. Stop the minimart app.
  2. docker start $OLD_CONTAINER
  3. Wait until it accepts connections:  docker exec $OLD_CONTAINER pg_isready
  4. Restore the app's connection settings from the .bak made in phase 3, start the app.

Situation C: the old container's data is damaged or gone (it is never deleted by this runbook)
  The newest dumps on the host:
    ${bk:-<no pre_migration_* directory found under $BACKUP_ROOT>}  (old.dump, schema.sql, globals.sql, counts.tsv)
    ${dir:-<no cutover_* directory found under $BACKUP_ROOT>}  (final.dump = state at cutover)
  Restore into a NEW empty database of a fresh postgres container with:
    docker exec -i <container> pg_restore -U <user> -d <db> --no-owner --exit-on-error < <dump file>

Undoing the new side is optional and never needed for the app to work again: $NEW_DB on
$NEW_CONTAINER can stay where it is. To remove it (only after the old setup works again):
    docker exec $NEW_CONTAINER psql -U $NEW_PGUSER -X -c 'DROP DATABASE $NEW_DB'
Never restart or remove $NEW_CONTAINER: other systems use it.
EOF
}

case "$MODE" in
  inspect)  mode_inspect ;;
  backup)   mode_backup ;;
  rehearse) mode_rehearse ;;
  cutover)  mode_cutover ;;
  verify)   mode_verify ;;
  rollback) mode_rollback ;;
esac
