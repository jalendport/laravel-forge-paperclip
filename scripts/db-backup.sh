#!/usr/bin/env bash
#
# Back up the Paperclip PostgreSQL database to backups/db/ as a gzipped SQL
# dump. Safe to run from cron (no TTY required). Old backups beyond
# CONFIG_KEEP_BACKUPS are pruned.

set -euo pipefail

CONFIG_KEEP_BACKUPS=20

# Resolve paths relative to this script so cron's CWD doesn't matter.
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BACKUP_DIR="$PROJECT_DIR/backups/db"
mkdir -p "$BACKUP_DIR"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="$BACKUP_DIR/paperclip_db_backup_$TIMESTAMP.sql"

cd "$PROJECT_DIR"

# Remove a partial dump if anything below fails.
cleanup() { rm -f "$BACKUP_FILE" "$BACKUP_FILE.gz"; }
trap 'cleanup' ERR

echo "Creating database backup..."
# -T disables TTY allocation: required under cron, and prevents \r corruption
# of the SQL stream when stdout is redirected. --clean --if-exists makes the
# dump self-contained for a drop-and-recreate restore.
docker compose exec -T db pg_dump -U paperclip -d paperclip --clean --if-exists > "$BACKUP_FILE"

# Guard against a "successful" but empty dump.
if [ ! -s "$BACKUP_FILE" ]; then
    echo "Error: backup file is empty" >&2
    exit 1
fi

gzip "$BACKUP_FILE"
echo "Backup created: $BACKUP_FILE.gz"

# Prune old backups, keeping the newest CONFIG_KEEP_BACKUPS.
ls -1t "$BACKUP_DIR"/paperclip_db_backup_*.sql.gz 2>/dev/null \
    | tail -n +$((CONFIG_KEEP_BACKUPS + 1)) | xargs -r rm -f

echo "Pruned old database backups; keeping newest $CONFIG_KEEP_BACKUPS."
