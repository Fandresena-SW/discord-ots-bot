#!/usr/bin/env bash
# Sync the challonge-sync Edge Function into the self-hosted stack
# (RFC-015 §3.5) — the self-hosted analogue of `supabase functions deploy`.
#
# Usage:
#   deploy/supabase/sync-functions.sh                 # on the VPS, as root
#   deploy/supabase/sync-functions.sh root@<vps-ip>   # from a workstation
#
# Copies every *.ts except tests. No restart is needed: edge-runtime starts a
# fresh worker per request, so the next trigger runs the new code.
set -euo pipefail

SRC="$(cd "$(dirname "$0")/../../supabase/functions/challonge-sync" && pwd)"
DEST="/opt/supabase/volumes/functions/challonge-sync"

files=()
for f in "$SRC"/*.ts; do
  case "$f" in *_test.ts) continue ;; esac
  files+=("$f")
done
[ "${#files[@]}" -gt 0 ] || { echo "no sources found in $SRC" >&2; exit 1; }

if [ "$#" -ge 1 ]; then
  ssh "$1" "mkdir -p '$DEST'"
  scp -q "${files[@]}" "$1:$DEST/"
else
  mkdir -p "$DEST"
  cp "${files[@]}" "$DEST/"
fi
echo "synced ${#files[@]} file(s) to ${1:+$1:}$DEST"
