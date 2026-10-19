#!/usr/bin/env bash
# Nightly logical backup of the self-hosted Supabase database (RFC-015 §3.6).
#
# Dumps the `public` schema (the whole app) and `supabase_migrations` (the
# ledger) as a custom-format archive, checks the archive is readable, then
# rotates anything older than KEEP_DAYS. Written to a directory OUTSIDE the
# Docker volume so a `docker compose down -v` cannot take the backups with it;
# the VPS provider's auto-backups then capture that directory off-disk.
#
# A snapshot of a running Postgres is only crash-consistent. This dump is the
# artifact that is guaranteed restorable — see RFC-015 §3.6 for why both exist.
set -euo pipefail

DEST="${BACKUP_DIR:-/var/backups/supabase}"
KEEP_DAYS="${KEEP_DAYS:-14}"
CONTAINER="${DB_CONTAINER:-supabase-db}"

umask 077
mkdir -p "$DEST"

ts="$(date -u +%Y%m%dT%H%M%SZ)"
tmp="$DEST/.ots-$ts.dump.tmp"
out="$DEST/ots-$ts.dump"
trap 'rm -f "$tmp"' EXIT

docker exec "$CONTAINER" pg_dump -U postgres -d postgres -Fc \
  -n public -n supabase_migrations > "$tmp"

[ -s "$tmp" ] || { echo "backup FAILED: empty dump" >&2; exit 1; }
docker exec -i "$CONTAINER" pg_restore --list < "$tmp" > /dev/null \
  || { echo "backup FAILED: archive is not readable" >&2; exit 1; }

mv "$tmp" "$out"
find "$DEST" -maxdepth 1 -name 'ots-*.dump' -mtime +"$KEEP_DAYS" -delete

echo "backup ok: $out ($(du -h "$out" | cut -f1)); $(find "$DEST" -maxdepth 1 -name 'ots-*.dump' | wc -l) kept"
