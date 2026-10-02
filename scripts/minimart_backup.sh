#!/usr/bin/env bash
# Nightly pg_dump of the `minimart` database ONLY, from the shared mmi-postgres container.
# Other databases on that server (procurement, hauling_tracker) are not read, locked or dumped.
#
#   scripts/minimart_backup.sh     -> /opt/backups/minimart/minimart_YYYYMMDD_HHMMSS.dump
#
# Cron (/etc/cron.d/minimart-pg-backup, see RUNBOOK_MINIMART_MIGRATION.md, phase 6):
#   45 2 * * * root /opt/purchasing_data/scripts/minimart_backup.sh >> /var/log/minimart-pg-backup.log 2>&1
# The log always ends each run with exactly one line: `... OK <file> (...)` or `... FAILED: <why>`.
#
# Custom format (-Fc): compressed, and pg_restore can restore one table.
# Restore into a scratch database to check a dump:
#   docker exec mmi-postgres createdb -U postgres minimart_restore_test
#   docker exec -i mmi-postgres pg_restore -U postgres -d minimart_restore_test --no-owner --no-acl < FILE.dump
#   docker exec mmi-postgres dropdb -U postgres minimart_restore_test
#
# pg_dump takes only ACCESS SHARE locks (the app keeps working) and reads one consistent
# snapshot. Exits non-zero, and keeps no file, on any failure. Only files named
# minimart_*.dump directly in the backup directory are ever deleted by the retention step:
# the pre_migration_*, cutover_* and rehearsal_* directories written by
# scripts/minimart_migrate.sh are never touched.
#
# Environment (all optional):
#   MINIMART_BACKUP_DIR             default /opt/backups/minimart
#   MINIMART_BACKUP_RETENTION_DAYS  default 14
#   MINIMART_PG_CONTAINER           default mmi-postgres
#   MINIMART_BACKUP_DB              default minimart
#   MINIMART_PG_USER                default postgres
#   MINIMART_DOCKER                 docker command (tests substitute a wrapper)
#   MINIMART_BACKUP_TIMEOUT         seconds allowed for the dump (default 3600)
set -uo pipefail

BACKUP_DIR="${MINIMART_BACKUP_DIR:-/opt/backups/minimart}"
RETENTION_DAYS="${MINIMART_BACKUP_RETENTION_DAYS:-14}"
CONTAINER="${MINIMART_PG_CONTAINER:-mmi-postgres}"
DB="${MINIMART_BACKUP_DB:-minimart}"
PGUSER_="${MINIMART_PG_USER:-postgres}"
DOCKER="${MINIMART_DOCKER:-docker}"
TIMEOUT="${MINIMART_BACKUP_TIMEOUT:-3600}"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S %z') $*"; }
die() { log "FAILED: $*"; exit 1; }

case "$RETENTION_DAYS" in ''|*[!0-9]*) die "MINIMART_BACKUP_RETENTION_DAYS must be a number, got '$RETENTION_DAYS'" ;; esac

run_timeout() {
  local secs=$1; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$secs" "$@"
  else perl -e 'alarm shift @ARGV; exec @ARGV or die "exec failed: $!\n"' "$secs" "$@"; fi
}

umask 077
mkdir -p "$BACKUP_DIR" 2>/dev/null || die "cannot create $BACKUP_DIR"
[ -d "$BACKUP_DIR" ] && [ -w "$BACKUP_DIR" ] || die "$BACKUP_DIR is not a writable directory"

out="$BACKUP_DIR/minimart_$(date +%Y%m%d_%H%M%S).dump"
tmp="$out.partial"
trap 'rm -f "$tmp" "$tmp.err"' EXIT

# The database must exist and have tables (an empty dump is not a backup).
want="$(run_timeout 120 "$DOCKER" exec "$CONTAINER" psql -U "$PGUSER_" -d "$DB" -X -q -At -v ON_ERROR_STOP=1 \
        -c "select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
             where c.relkind = 'r' and c.relpersistence = 'p' and n.nspname !~ '^pg_' and n.nspname <> 'information_schema'
               and not exists (select 1 from pg_depend d where d.classid = 'pg_class'::regclass and d.objid = c.oid and d.deptype = 'e')" < /dev/null 2>"$tmp.err")" \
  || die "cannot query database $DB in container $CONTAINER: $(tr '\n' ' ' < "$tmp.err" | cut -c1-200)"
rm -f "$tmp.err"
want="$(printf '%s\n' "$want" | tail -n 1)"
case "$want" in ''|*[!0-9]*) die "unexpected answer counting tables in $DB: $(echo "$want" | cut -c1-100)" ;; esac
[ "$want" -gt 0 ] || die "database $DB has no tables: refusing to write an empty backup"

if ! run_timeout "$TIMEOUT" "$DOCKER" exec "$CONTAINER" pg_dump -U "$PGUSER_" -d "$DB" -Fc > "$tmp" < /dev/null; then
  die "pg_dump of $DB exited non-zero"
fi
[ -s "$tmp" ] || die "pg_dump of $DB produced an empty file"

# A dump pg_restore cannot read to the end is not a backup (--list alone accepts a truncated file:
# the table of contents sits at the front), so read the whole archive too.
if ! run_timeout 900 "$DOCKER" exec -i "$CONTAINER" pg_restore -f /dev/null < "$tmp" 2>/dev/null; then
  die "pg_restore cannot read the whole of $tmp (truncated or corrupt)"
fi
if ! lst="$(run_timeout 300 "$DOCKER" exec -i "$CONTAINER" pg_restore --list < "$tmp")"; then
  die "pg_restore cannot list $tmp"
fi
entries="$(printf '%s\n' "$lst" | grep -c ' TABLE DATA ')"
if [ "$entries" -lt "$want" ]; then
  die "dump has only $entries TABLE DATA entries, the database has $want tables"
fi

mv "$tmp" "$out" || die "cannot move the dump into place"
trap - EXIT

# Retention BEFORE the final line, so the log always ends with the OK line. Only runs after a
# verified dump; deletes only this script's own files directly inside the backup directory.
find "$BACKUP_DIR" -maxdepth 1 -type f -name 'minimart_*.dump' -mtime +"$RETENTION_DAYS" -print -delete \
  | sed "s/^/$(date '+%Y-%m-%d %H:%M:%S %z') removed /"
find "$BACKUP_DIR" -maxdepth 1 -type f -name 'minimart_*.dump.partial' -mmin +120 -delete
log "OK $out ($(du -h "$out" | cut -f1), $entries tables)"
exit 0
