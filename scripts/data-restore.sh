#!/usr/bin/env bash
#
# Restore the Paperclip data volume (/paperclip) from a tarball produced by
# data-backup.sh.
#
# DESTRUCTIVE: replaces the current contents of /paperclip. Paperclip is stopped
# during the restore and restarted afterwards (even if the restore fails).

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

FILE="${1:-}"
if [ -z "$FILE" ]; then
    echo "Usage: $0 backups/data/paperclip_data_backup_YYYYMMDD_HHMMSS.tar.gz" >&2
    exit 1
fi
if [ ! -f "$FILE" ]; then
    echo "Error: file not found: $FILE" >&2
    exit 1
fi

# Absolute path for the bind mount below (compose run resolves it from CWD).
ARCHIVE="$(cd "$(dirname "$FILE")" && pwd)/$(basename "$FILE")"

echo "WARNING: restoring the data volume from $FILE is destructive."
echo "Stopping Paperclip during the restore..."
docker compose stop paperclip
trap 'echo "Restarting Paperclip..."; docker compose start paperclip' EXIT

# A one-off container mounts the same data volume (via the paperclip service
# definition) to wipe and re-extract. --no-deps avoids starting the db.
echo "Wiping and restoring /paperclip..."
docker compose run --rm --no-deps -T \
    -v "$ARCHIVE:/restore/archive.tar.gz:ro" \
    paperclip \
    sh -c 'set -e; find /paperclip -mindepth 1 -delete; tar -xzf /restore/archive.tar.gz -C /paperclip'

echo "Data restore complete."
