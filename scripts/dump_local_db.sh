#!/usr/bin/env bash
set -euo pipefail

# Paths
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DUMPS_DIR="${ROOT_DIR}/data/wp/_migracion/db_dumps"

# Load env
set -a; source "${ROOT_DIR}/.env"; set +a

# Compose service names (if you changed them in compose, update these)
DB_SVC="db"

# DB params
DB_NAME="${WORDPRESS_DB_NAME:-wordpress}"
APP_USER="${WORDPRESS_DB_USER:-wordpress}"
APP_PASS="${WORDPRESS_DB_PASSWORD:-wordpress}"
ROOT_PASS="${MYSQL_ROOT_PASSWORD:-}"

STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="${DUMPS_DIR}/local-${STAMP}.sql.gz"

mkdir -p "${DUMPS_DIR}"

die(){ echo "ERROR: $*" >&2; exit 1; }
msg(){ echo "[dump-local] $*"; }

# Ensure DB container is up
if ! docker compose ps -q "${DB_SVC}" >/dev/null; then
  die "Database service '${DB_SVC}' not found. Are you in the project folder? Did you run 'docker compose up -d'?"
fi

# Which credentials will we use? Try app user first, then root as fallback
try_mysql() {
  local user="$1" pass="$2"
  docker compose exec -T "${DB_SVC}" sh -lc \
    'MYSQL_PWD="$2" mysql -h 127.0.0.1 -u "$1" -e "SELECT 1" >/dev/null' \
    sh "$user" "$pass"
}

DUMP_USER="" ; DUMP_PASS=""

msg "Probing DB connectivity (application user)..."
if try_mysql "${APP_USER}" "${APP_PASS}"; then
  DUMP_USER="${APP_USER}"; DUMP_PASS="${APP_PASS}"
  msg "Using application credentials (${DUMP_USER})."
elif [ -n "${ROOT_PASS}" ] && try_mysql "root" "${ROOT_PASS}"; then
  DUMP_USER="root"; DUMP_PASS="${ROOT_PASS}"
  msg "Application user failed; using root."
else
  die "Cannot connect with application user or root. Check .env and that the DB is running."
fi

# Perform dump inside the DB container; stream to host and gzip
msg "Dumping database '${DB_NAME}' to ${OUT} ..."
docker compose exec -T "${DB_SVC}" sh -lc '
  set -e
  # Prefer mariadb-dump if present (MariaDB), else mysqldump (MySQL)
  DUMP_BIN="$(command -v mariadb-dump || command -v mysqldump)"
  [ -n "$DUMP_BIN" ] || { echo "No dump client found in container"; exit 2; }
  MYSQL_PWD="$2" "$DUMP_BIN" \
    -h 127.0.0.1 \
    -u "$1" \
    --single-transaction --quick \
    --routines --triggers --events \
    --default-character-set=utf8mb4 \
    --add-drop-table \
    --set-gtid-purged=OFF \
    "$3"
' sh "${DUMP_USER}" "${DUMP_PASS}" "${DB_NAME}" | gzip -9 > "${OUT}"

# Basic sanity: file exists and not empty
if [ ! -s "${OUT}" ]; then
  die "Dump file is empty: ${OUT}"
fi

# Optional: keep a 'latest' symlink for convenience
ln -sfn "$(basename "${OUT}")" "${DUMPS_DIR}/latest.sql.gz"

msg "Done. Created:"
echo "  ${OUT}"
echo "  ${DUMPS_DIR}/latest.sql.gz -> $(basename "${OUT}")"

msg "Tip: To re-seed from this dump, remove ./data/db/* and do 'docker compose up -d'. The importer picks the latest *.sql(.gz)."
