#!/usr/bin/env bash
set -euo pipefail
set -a; source "$(dirname "$0")/../.env"; set +a

REM="${REMOTE_USER}@${REMOTE_HOST}"
PORT="${REMOTE_PORT:-22}"
mkdir -p ./data/wp

rsync -avz --delete -e "ssh -p ${PORT}" \
  --exclude='.well-known' --exclude='error_log' --exclude='logs' \
  --exclude='cache' --exclude='cgi-bin' --exclude='tmp' \
  "${REM}:${REMOTE_WP_PATH}/" ./data/wp/

echo "Synced to ./data/wp"
