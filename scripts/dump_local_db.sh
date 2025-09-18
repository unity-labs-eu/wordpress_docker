#!/usr/bin/env bash
set -euo pipefail

# Paths
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DUMPS_DIR="${ROOT_DIR}/data/wp/_migracion/db_dumps"

# Load env
set -a; source "${ROOT_DIR}/.env"; set +a

DB_SVC="db"
DB_NAME="${WORDPRESS_DB_NAME:-wordpress}"
APP_USER="${WORDPRESS_DB_USER:-wordpress}"
APP_PASS="${WORDPRESS_DB_PASSWORD:-wordpress}"
ROOT_PASS="${MYSQL_ROOT_PASSWORD:-}"

STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="${DUMPS_DIR}/local-${STAMP}.sql.gz"

mkdir -p "${DUMPS_DIR}"

die(){ echo "ERROR: $*" >&2; exit 1; }
msg(){ echo "[dump-local] $*"; }

# Ensure DB container exists
docker compose ps -q "${DB_SVC}" >/dev/null || die "DB service '${DB_SVC}' not found. Run 'docker compose up -d' first."

try_mysql() {
  local user="$1" pass="$2"
  docker compose exec -T "${DB_SVC}" sh -lc '
    MYSQL_PWD="$2" mysql -h 127.0.0.1 -u "$1" -e "SELECT 1" >/dev/null
  ' sh "$user" "$pass"
}

# Choose credentials (app, else root)
DUMP_USER="" ; DUMP_PASS=""
if try_mysql "${APP_USER}" "${APP_PASS}"; then
  DUMP_USER="${APP_USER}"; DUMP_PASS="${APP_PASS}"
  msg "Using application credentials (${DUMP_USER})."
elif [ -n "${ROOT_PASS}" ] && try_mysql "root" "${ROOT_PASS}"; then
  DUMP_USER="root"; DUMP_PASS="${ROOT_PASS}"
  msg "Application user failed; using root."
else
  die "Cannot connect with application user or root. Check .env and DB status."
fi

msg "Dumping database '${DB_NAME}' to ${OUT} ..."
docker compose exec -T "${DB_SVC}" sh -lc '
  set -e

  DUMP_BIN="$(command -v mariadb-dump || command -v mysqldump)"
  [ -n "$DUMP_BIN" ] || { echo "No dump client found"; exit 2; }

  VER_STR="$($DUMP_BIN --version 2>&1 | tr "[:upper:]" "[:lower:]")"
  GTID_FLAG=""
  COLSTAT_FLAG=""
  NOTBSP_FLAG=""

  case "$VER_STR" in
    *mariadb* )
      # mariadb-dump: DO NOT pass --set-gtid-purged (unsupported)
      ;;
    * )
      # mysqldump (MySQL): safe to disable GTID & problematic column stats
      GTID_FLAG="--set-gtid-purged=OFF"
      $DUMP_BIN --help 2>/dev/null | grep -q -- "--column-statistics" && COLSTAT_FLAG="--column-statistics=0"
      $DUMP_BIN --help 2>/dev/null | grep -q -- "--no-tablespaces"     && NOTBSP_FLAG="--no-tablespaces"
      ;;
  esac

  MYSQL_PWD="$2" "$DUMP_BIN" \
    -h 127.0.0.1 -u "$1" \
    --single-transaction --quick \
    --routines --triggers --events \
    --default-character-set=utf8mb4 \
    --add-drop-table $GTID_FLAG $COLSTAT_FLAG $NOTBSP_FLAG \
    "$3"
' sh "${DUMP_USER}" "${DUMP_PASS}" "${DB_NAME}" | gzip -9 > "${OUT}"

[ -s "${OUT}" ] || die "Dump file is empty: ${OUT}"
ln -sfn "$(basename "${OUT}")" "${DUMPS_DIR}/latest.sql.gz"

msg "Done:"
echo "  ${OUT}"
echo "  ${DUMPS_DIR}/latest.sql.gz -> $(basename "${OUT}")"
msg "To re-seed: remove ./data/db/* and run 'docker compose up -d' (the importer picks the latest dump)."
