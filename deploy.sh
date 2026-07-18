#!/usr/bin/env bash
# Pull the latest code and restart the bot service on the production VM.
# Run this from an SSH session on the server (see knowledge/DEPLOYMENT.md).
#
# Usage: ./deploy.sh

set -euo pipefail

SERVICE_NAME="discord-ots-bot"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cd "$REPO_DIR"

echo "==> Pulling latest changes in $REPO_DIR"
git pull

echo "==> Installing/updating dependencies"
source venv/bin/activate
pip install -q -r requirements.txt
deactivate

echo "==> Restarting $SERVICE_NAME"
sudo systemctl restart "$SERVICE_NAME"

echo "==> Status"
sudo systemctl status "$SERVICE_NAME" --no-pager -l

echo "==> Recent logs (Ctrl+C to stop following)"
journalctl -u "$SERVICE_NAME" -n 20 -f
