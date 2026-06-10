#!/usr/bin/env bash
#
# Back up the Paperclip data volume (/paperclip) to backups/data/ as a gzipped
# tarball: uploaded attachments, instance config, and agent workspaces/memory
# (SOUL.md, MEMORY.md, sessions). Safe to run from cron (no TTY). Old backups
# beyond CONFIG_KEEP_BACKUPS are pruned.
#
# This is a HOT copy — the app keeps running. Uploads and config are
# effectively static; an agent workspace mid-write is recoverable. For a
# guaranteed-consistent snapshot, `docker compose stop paperclip` first.
#
# The encryption master key is NOT in this volume (it lives in .env as
# PAPERCLIP_SECRETS_MASTER_KEY) — back that up separately in a password manager.

set -euo pipefail

CONFIG_KEEP_BACKUPS=20

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BACKUP_DIR="$PROJECT_DIR/backups/data"
mkdir -p "$BACKUP_DIR"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="$BACKUP_DIR/paperclip_data_backup_$TIMESTAMP.tar.gz"

cd "$PROJECT_DIR"

echo "Creating data-volume backup..."
# Stream the tarball out of the container so we don't need to know the
# project-prefixed volume name. tar exit code 1 means "files changed while
# reading" (expected on a hot copy) and is tolerated; 2+ is a real failure.
set +e
docker compose exec -T paperclip tar -czf - -C /paperclip . > "$BACKUP_FILE"
rc=$?
set -e
if [ "$rc" -gt 1 ]; then
    echo "Error: tar failed (exit $rc)" >&2
    rm -f "$BACKUP_FILE"
    exit 1
fi

# Guard against a "successful" but empty archive.
if [ ! -s "$BACKUP_FILE" ]; then
    echo "Error: backup file is empty" >&2
    rm -f "$BACKUP_FILE"
    exit 1
fi

echo "Backup created: $BACKUP_FILE"

# Prune old backups, keeping the newest CONFIG_KEEP_BACKUPS.
ls -1t "$BACKUP_DIR"/paperclip_data_backup_*.tar.gz 2>/dev/null \
    | tail -n +$((CONFIG_KEEP_BACKUPS + 1)) | xargs -r rm -f

echo "Pruned old data backups; keeping newest $CONFIG_KEEP_BACKUPS."
