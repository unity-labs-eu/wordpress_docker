#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
set -a; source "${ROOT_DIR}/.env"; set +a

EXPORT_DIR="${ROOT_DIR}/exports"
REM="${REMOTE_USER}@${REMOTE_HOST}"
PORT="${PUBLISH_SSH_PORT:-${REMOTE_PORT:-22}}"
TARGET="${PUBLISH_REMOTE_STATIC_PATH:?PUBLISH_REMOTE_STATIC_PATH required}"
MODE="${PUBLISH_MODE:-direct}"

RSYNC_BIN="${RSYNC_BIN:-rsync}"

die(){ echo "ERROR: $*" >&2; exit 1; }
msg(){ echo "[publish] $*"; }

[ -d "$EXPORT_DIR" ] || die "Missing $EXPORT_DIR. Run Simply Static export first."
[ -n "$(find "$EXPORT_DIR" -mindepth 1 -maxdepth 1 -print -quit)" ] || die "$EXPORT_DIR is empty."

# >>> NEW: backup before publishing (toggle via PUBLISH_BACKUP_BEFORE)
if [ "${PUBLISH_BACKUP_BEFORE:-1}" = "1" ]; then
  msg "Running full backup (DB + wp files) before publish…"
  bash "${SCRIPT_DIR}/backup_full.sh"
else
  msg "Skipping backup (PUBLISH_BACKUP_BEFORE=0)."
fi
# <<<

# Build rsync options compatibly
RSYNC_OPTS=(-az --delete --human-readable)
if "$RSYNC_BIN" --help 2>&1 | grep -q -- '--info='; then
  RSYNC_OPTS+=(--info=stats2)
else
  RSYNC_OPTS+=(--stats)
fi
[ "${VERBOSE:-0}" = "1" ] && RSYNC_OPTS+=(-vv)
[ "${DRYRUN:-0}" = "1" ] && RSYNC_OPTS+=(--dry-run)

# Default .htaccess at export root (optional)
HTACCESS_DEFAULT="${EXPORT_DIR}/.htaccess"
if [ ! -f "$HTACCESS_DEFAULT" ]; then
  cat > "$HTACCESS_DEFAULT" <<'HT'
ErrorDocument 404 /404/
Options -Indexes
HT
  msg "Created default .htaccess in export root."
fi

## Ensure backups are NEVER uploaded
## Add 'backups/' to excludes automatically (plus user-defined excludes)
#RSYNC_OPTS+=(--exclude="backups/")
#if [ -n "${PUBLISH_EXCLUDES:-}" ]; then
#  IFS=',' read -r -a EXC_ARR <<< "${PUBLISH_EXCLUDES}"
#  for e in "${EXC_ARR[@]}"; do e="$(echo "$e" | xargs)"; [ -n "$e" ] && RSYNC_OPTS+=(--exclude="$e"); done
#fi

# SSH check
ssh -p "$PORT" -o BatchMode=yes -o ConnectTimeout=10 "$REM" 'echo ok' >/dev/null || die "Cannot SSH to ${REM}:${PORT}"

STAMP="$(date +%Y%m%d-%H%M%S)"
case "$MODE" in
  direct)
    ssh -p "$PORT" "$REM" "mkdir -p '$TARGET'"
    msg "Deploying in DIRECT mode to ${REM}:${TARGET}/"
    "$RSYNC_BIN" "${RSYNC_OPTS[@]}" -e "ssh -p ${PORT}" "${EXPORT_DIR}/" "${REM}:${TARGET}/"
    ;;
  atomic_symlink)
    RELEASES="${TARGET}/.releases"
    NEWREL="${RELEASES}/${STAMP}"
    ssh -p "$PORT" "$REM" "mkdir -p '$RELEASES' '$TARGET'"
    msg "Deploying in ATOMIC_SYMLINK mode (releases at ${RELEASES}, current -> ${NEWREL})"
    "$RSYNC_BIN" "${RSYNC_OPTS[@]}" -e "ssh -p ${PORT}" "${EXPORT_DIR}/" "${REM}:${NEWREL}/"
    ssh -p "$PORT" "$REM" "ln -sfn '${NEWREL}' '${TARGET}/current' && echo 'current -> ${NEWREL}'"
    ;;
  *) die "Unknown PUBLISH_MODE=$MODE (use direct | atomic_symlink)" ;;
esac

msg "Publish complete."
