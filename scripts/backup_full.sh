#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
set -a; source "${ROOT_DIR}/.env"; set +a

DUMPS_DIR="${ROOT_DIR}/data/wp/_migracion/db_dumps"
WP_DIR="${ROOT_DIR}/data/wp"
BACKUPS_DIR="${ROOT_DIR}/exports/backups"
STAMP="$(date +%Y%m%d-%H%M%S)"
ARCHIVE="${BACKUPS_DIR}/wp-full-${STAMP}.tar.gz"

die(){ echo "ERROR: $*" >&2; exit 1; }
msg(){ echo "[backup] $*"; }

[ -d "${WP_DIR}" ] || die "Missing ${WP_DIR}. Run sync first."

# 1) Fresh local DB dump (reuses your dump_local_db.sh logic)
if [ -x "${SCRIPT_DIR}/dump_local_db.sh" ]; then
  msg "Dumping local DB…"
  "${SCRIPT_DIR}/dump_local_db.sh"
else
  die "scripts/dump_local_db.sh not found or not executable."
fi

# 2) Create backups dir (+ hardening .htaccess)
mkdir -p "${BACKUPS_DIR}"
HT="${BACKUPS_DIR}/.htaccess"
if [ ! -f "$HT" ]; then
  cat > "$HT" <<'HTACC'
# Forbid direct HTTP access to this folder (Apache 2.4+)
Require all denied
Options -Indexes
HTACC
  msg "Created ${HT}"
fi

# 3) Tar+gzip the whole WordPress tree as a single archive
#    Archive will contain a top-level "wp/" folder.
msg "Archiving ${WP_DIR} → ${ARCHIVE}"
# Portable tar (macOS/BSD/GNU): use -C to control top-level dir
tar -czf "${ARCHIVE}" -C "${ROOT_DIR}/data" wp

# Sanity check
[ -s "${ARCHIVE}" ] || die "Archive is empty: ${ARCHIVE}"
msg "Full backup created: ${ARCHIVE}"
