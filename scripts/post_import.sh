#!/usr/bin/env bash
set -euo pipefail
set -a; source "$(dirname "$0")/../.env"; set +a

# Detecta URL original (siteurl) desde la BD importada
OLD_URL=$(docker compose run --rm wp-cli wp option get siteurl --skip-plugins --skip-themes | tr -d '\r')
echo "URL original detectada: ${OLD_URL}"

NEW_URL="http://${LOCAL_DOMAIN}/"

# Establece home + siteurl a la URL local
docker compose run --rm wp-cli wp option update home    "$NEW_URL"
docker compose run --rm wp-cli wp option update siteurl "$NEW_URL"

# Search-replace de TODO el contenido (maneja serializados). Omitimos GUID.
# Si tienes PROD_URL en .env la usamos, si no usamos OLD_URL detectada.
FROM_URL="${PROD_URL:-$OLD_URL}"
if [ -n "$FROM_URL" ] && [ "$FROM_URL" != "$NEW_URL" ]; then
  docker compose run --rm wp-cli wp search-replace "$FROM_URL" "$NEW_URL" --all-tables --precise --recurse-objects --skip-columns=guid
fi

# Flush de reglas de enlaces permanentes (por si acaso)
docker compose run --rm wp-cli wp rewrite structure '/%postname%/'
docker compose run --rm wp-cli wp rewrite flush --hard

# Instala y activa Simply Static
docker compose run --rm wp-cli wp plugin install simply-static --activate

echo "Post-import listo. Accede a ${NEW_URL}"
