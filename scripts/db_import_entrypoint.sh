#!/bin/sh
set -eu

HOST="${MYSQL_HOST:-db}"
PORT="${MYSQL_PORT:-3306}"
DB="${MYSQL_DATABASE:-wordpress}"

log() { printf "[db-importer] %s\n" "$*"; }

wait_for_mysql() {
  log "Waiting for MySQL at ${HOST}:${PORT} ..."
  i=0
  while ! mysqladmin ping -h "$HOST" -P "$PORT" --silent >/dev/null 2>&1; do
    i=$((i+1)); [ "$i" -lt 300 ] || { log "Timeout waiting for MySQL"; exit 2; }
    sleep 1
  done
  log "MySQL is up."
}

can_query() {
  MYSQL_PWD="$2" mysql -h "$HOST" -P "$PORT" -u "$1" -e "SELECT 1" >/dev/null 2>&1
}

mysql_q() {
  MYSQL_PWD="$2" mysql -N -s -h "$HOST" -P "$PORT" -u "$1" -e "$3"
}

import_file() {
  user="$1"; pass="$2"; file="$3"
  case "$file" in
    *.gz) gunzip -c "$file" | MYSQL_PWD="$pass" mysql -h "$HOST" -P "$PORT" -u "$user" "$DB" ;;
    *.sql) MYSQL_PWD="$pass" mysql -h "$HOST" -P "$PORT" -u "$user" "$DB" < "$file" ;;
    *) log "Ignored $file" ;;
  esac
}

wait_for_mysql

USER="${MYSQL_USER:-wordpress}"
PASS="${MYSQL_PASSWORD:-wordpress}"

if can_query "$USER" "$PASS"; then
  log "Auth OK with app user ($USER)."
elif [ -n "${MYSQL_ROOT_PASSWORD:-}" ] && can_query "root" "$MYSQL_ROOT_PASSWORD"; then
  USER="root"; PASS="$MYSQL_ROOT_PASSWORD"
  log "App user failed; using root fallback."
else
  log "Cannot auth with app user or root. Check credentials or reset ./data/db."
  exit 2
fi

COUNT="$(mysql_q "$USER" "$PASS" "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${DB}';" || echo ERR)"
[ "$COUNT" != "ERR" ] || { log "Error counting tables"; exit 2; }

if [ "$COUNT" -gt 0 ]; then
  log "DB '${DB}' already has $COUNT tables. Skipping import."
  exit 0
fi

[ -d /dumps ] || { log "No /dumps mount. Nothing to import."; exit 0; }
LATEST="$(ls -1t /dumps/*.sql.gz /dumps/*.sql 2>/dev/null | head -n1 || true)"
[ -n "$LATEST" ] || { log "No dumps found. Nothing to import."; exit 0; }

log "Importing ${LATEST} into '${DB}' ..."
import_file "$USER" "$PASS" "$LATEST" || { log "Import failed"; exit 2; }
log "Import completed."
