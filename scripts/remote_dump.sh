#!/usr/bin/env bash
set -euo pipefail
set -a; source "$(dirname "$0")/../.env"; set +a

REM="${REMOTE_USER}@${REMOTE_HOST}"
PORT="${REMOTE_PORT:-22}"
PATH_WP="${REMOTE_WP_PATH}"
REMOTE_DUMPS_DIR="${PATH_WP}/_migracion/db_dumps"
STAMP=$(date +%Y%m%d-%H%M%S)
REMOTE_SQL="${REMOTE_DUMPS_DIR}/db-${STAMP}.sql.gz"

ssh -p "$PORT" "$REM" "set -e
  mkdir -p '$REMOTE_DUMPS_DIR'
  cd '$PATH_WP'
  php -r 'include \"wp-config.php\"; echo DB_NAME, \"\\n\", DB_USER, \"\\n\", DB_PASSWORD, \"\\n\", DB_HOST;' > .dbinfo || true
  DB_NAME=\$(sed -n '1p' .dbinfo); DB_USER=\$(sed -n '2p' .dbinfo); DB_PASS=\$(sed -n '3p' .dbinfo); DB_HOST=\$(sed -n '4p' .dbinfo)
  mysqldump -h \"\$DB_HOST\" -u\"\$DB_USER\" -p\"\$DB_PASS\" --single-transaction --quick --routines --triggers \"\$DB_NAME\" \
    | gzip -9 > \"$REMOTE_SQL\"
  echo \"Dump creado: $REMOTE_SQL\"
"
echo "OK. Dump is on the server at: $REMOTE_SQL"
