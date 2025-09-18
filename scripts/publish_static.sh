#!/usr/bin/env bash
set -euo pipefail

# Load environment
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
set -a; source "${ROOT_DIR}/.env"; set +a

EXPORT_DIR="${ROOT_DIR}/exports"
REM="${REMOTE_USER}@${REMOTE_HOST}"
PORT="${PUBLISH_SSH_PORT:-${REMOTE_PORT:-22}}"
TARGET="${PUBLISH_REMOTE_STATIC_PATH:?PUBLISH_REMOTE_STATIC_PATH required}"
MODE="${PUBLISH_MODE:-direct}"

# Allow overriding which rsync to use (e.g. RSYNC_BIN=/opt/homebrew/bin/rsync)
RSYNC_BIN="${RSYNC_BIN:-rsync}"

die(){ echo "ERROR: $*" >&2; exit 1; }
msg(){ echo "[publish] $*"; }

[ -d "$EXPORT_DIR" ] || die "Missing $EXPORT_DIR. Run Simply Static export first."
[ -n "$(find "$EXPORT_DIR" -mindepth 1 -maxdepth 1 -print -quit)" ] || die "$EXPORT_DIR is empty."

# Build rsync options compatibly
RSYNC_OPTS=(-az --delete --human-readable)
# macOS rsync lacks --info=... ; fall back to --stats
if "$RSYNC_BIN" --help 2>&1 | grep -q -- '--info='; then
  RSYNC_OPTS+=(--info=stats2)
else
  RSYNC_OPTS+=(--stats)
fi
# Optional verbosity & dry-run
[ "${VERBOSE:-0}" = "1" ] && RSYNC_OPTS+=(-vv)
[ "${DRYRUN:-0}" = "1" ] && RSYNC_OPTS+=(--dry-run)

# Default .htaccess (optional): caching + compression
HTACCESS_DEFAULT="${EXPORT_DIR}/.htaccess"
if [ ! -f "$HTACCESS_DEFAULT" ]; then
  cat > "$HTACCESS_DEFAULT" <<'HT'
# Basic caching & compression for static exports
<IfModule mod_expires.c>
  ExpiresActive On
  ExpiresByType text/html "access plus 2h"
  ExpiresByType text/css "access plus 7d"
  ExpiresByType application/javascript "access plus 7d"
  ExpiresByType image/svg+xml "access plus 30d"
  ExpiresByType image/png "access plus 30d"
  ExpiresByType image/jpeg "access plus 30d"
  ExpiresByType image/webp "access plus 30d"
</IfModule>
<IfModule mod_deflate.c>
  AddOutputFilterByType DEFLATE text/html text/css application/javascript application/json image/svg+xml
</IfModule>
Options -Indexes
HT
  msg "Created default .htaccess in export (you can customize it)."
fi

# Test SSH connectivity
ssh -p "$PORT" -o BatchMode=yes -o ConnectTimeout=10 "$REM" 'echo ok' >/dev/null || die "Cannot SSH to ${REM}:${PORT}"

# Pre-create target dirs (compat for rsync without --mkpath)
STAMP="$(date +%Y%m%d-%H%M%S)"
case "$MODE" in
  direct)
    ssh -p "$PORT" "$REM" "mkdir -p '$TARGET'" ;;
  atomic_symlink)
    RELEASES="${TARGET}/.releases"
    NEWREL="${RELEASES}/${STAMP}"
    ssh -p "$PORT" "$REM" "mkdir -p '$RELEASES' '$TARGET'" ;;
  *) die "Unknown PUBLISH_MODE=$MODE (use direct | atomic_symlink)" ;;
esac

# Compose excludes
EXCLUDES_RAW="${PUBLISH_EXCLUDES:-}"
if [ -n "$EXCLUDES_RAW" ]; then
  IFS=',' read -r -a EXC_ARR <<< "$EXCLUDES_RAW"
  for e in "${EXC_ARR[@]}"; do
    e="$(echo "$e" | xargs)"; [ -n "$e" ] && RSYNC_OPTS+=(--exclude="$e")
  done
fi

# Sync
if [ "$MODE" = "direct" ]; then
  msg "Deploying in DIRECT mode to ${REM}:${TARGET}/"
  "$RSYNC_BIN" "${RSYNC_OPTS[@]}" -e "ssh -p ${PORT}" "${EXPORT_DIR}/" "${REM}:${TARGET}/"
else
  RELEASES="${TARGET}/.releases"
  NEWREL="${RELEASES}/${STAMP}"
  msg "Deploying in ATOMIC_SYMLINK mode (releases at ${RELEASES}, current -> ${NEWREL})"
  "$RSYNC_BIN" "${RSYNC_OPTS[@]}" -e "ssh -p ${PORT}" "${EXPORT_DIR}/" "${REM}:${NEWREL}/"
  ssh -p "$PORT" "$REM" "ln -sfn '${NEWREL}' '${TARGET}/current' && echo 'current -> ${NEWREL}'"
fi

msg "Publish complete."
