#!/usr/bin/env bash
# Nightly pg_dump of the `procurement` database ONLY, from the shared
# mmi-postgres container. Other databases on that server (hauling_tracker)
# are not read, locked or dumped — they have their own backups.
#
#   scripts/pg_backup.sh          → /opt/backups/procurement/procurement_YYYYMMDD_HHMMSS.dump
#
# Cron (/etc/cron.d/procurement-pg-backup, see RUNBOOK_POSTGRES_CUTOVER.md):
#   30 2 * * * root /opt/purchasing_data/scripts/pg_backup.sh >> /var/log/procurement-pg-backup.log 2>&1
#
# Custom format (-Fc): compressed, and pg_restore can restore one table.
# Restore into a scratch database to check a dump:
#   docker exec mmi-postgres createdb -U postgres procurement_restore_test
#   docker exec -i mmi-postgres pg_restore -U postgres -d procurement_restore_test --no-owner < FILE.dump
#   docker exec mmi-postgres dropdb -U postgres procurement_restore_test
# Restore over the live database: RUNBOOK_POSTGRES_CUTOVER.md, "Restoring a backup".
#
# pg_dump takes only ACCESS SHARE locks (the app keeps working) and reads
# one consistent snapshot. Exits non-zero, and keeps no file, on any failure.
set -euo pipefail

BACKUP_DIR="${PG_BACKUP_DIR:-/opt/backups/procurement}"
RETENTION_DAYS="${PG_BACKUP_RETENTION_DAYS:-14}"
CONTAINER="${PG_CONTAINER:-mmi-postgres}"
DB="${PG_BACKUP_DB:-procurement}"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S %z') $*"; }

umask 077
mkdir -p "$BACKUP_DIR"

out="$BACKUP_DIR/procurement_$(date +%Y%m%d_%H%M%S).dump"
tmp="$out.partial"
trap 'rm -f "$tmp"' EXIT

if ! docker exec "$CONTAINER" pg_dump -U postgres -d "$DB" -Fc > "$tmp"; then
  log "FAILED: pg_dump of $DB exited non-zero"
  exit 1
fi

# A dump pg_restore cannot list is not a backup.
if ! entries="$(docker exec -i "$CONTAINER" pg_restore --list < "$tmp" | grep -c ' TABLE DATA ')"; then
  log "FAILED: pg_restore cannot read $tmp"
  exit 1
fi
if [ "$entries" -lt 10 ]; then
  log "FAILED: dump has only $entries TABLE DATA entries (expected 16)"
  exit 1
fi

mv "$tmp" "$out"
trap - EXIT
log "OK $out ($(du -h "$out" | cut -f1), $entries tables)"

# Retention: delete dumps older than RETENTION_DAYS days. Never touches
# anything but this script's own files.
find "$BACKUP_DIR" -maxdepth 1 -type f -name 'procurement_*.dump' -mtime +"$RETENTION_DAYS" -print -delete \
  | sed "s/^/$(date '+%Y-%m-%d %H:%M:%S %z') removed /"
find "$BACKUP_DIR" -maxdepth 1 -type f -name 'procurement_*.dump.partial' -mmin +120 -delete
