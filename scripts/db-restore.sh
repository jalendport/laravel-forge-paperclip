#!/usr/bin/env bash
#
# Restore the Paperclip PostgreSQL database from a gzipped (or plain) SQL dump
# produced by db-backup.sh.
#
# DESTRUCTIVE: the dump is applied with --clean, dropping and recreating
# objects. Paperclip is stopped during the restore and restarted afterwards
# (even if the restore fails).

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

FILE="${1:-}"
if [ -z "$FILE" ]; then
    echo "Usage: $0 backups/db/paperclip_db_backup_YYYYMMDD_HHMMSS.sql.gz" >&2
    exit 1
fi
if [ ! -f "$FILE" ]; then
    echo "Error: file not found: $FILE" >&2
    exit 1
fi

echo "WARNING: restoring the database from $FILE is destructive."
echo "Stopping Paperclip during the restore..."
docker compose stop paperclip
trap 'echo "Restarting Paperclip..."; docker compose start paperclip' EXIT

emit() {
    if [[ "$FILE" == *.gz ]]; then gunzip -c "$FILE"; else cat "$FILE"; fi
}

# ON_ERROR_STOP=1 fails the restore on a bad/partial dump instead of silently
# leaving you with a half-loaded database.
echo "Loading dump (ON_ERROR_STOP=1)..."
emit | docker compose exec -T db psql -v ON_ERROR_STOP=1 -U paperclip -d paperclip

echo "Database restore complete."
