Awesome—let’s turn your working setup into a clean, copy-pasteable **tutorial**. I’ll use the approach that ended up working for you:

* **Manual edit of `wp-config.php`** (recommended; scripts are optional).
* **Canonical local domain `http://wp.local` on port 80** so both host and containers can self-request (Simply Static passes diagnostics).
* A robust **db importer** that pulls the latest dump automatically.

---

# From shared LAMP to local Docker + Simply Static (WordPress)

## What you’ll get

A reproducible local environment that mirrors your live WordPress, imports a DB dump automatically, and lets you **export static HTML** with Simply Static.

* `docker-compose` (WordPress + MariaDB + wp-cli + optional phpMyAdmin)
* `rsync` from hosting → local
* DB **auto-import** on first run
* One canonical local URL: **[http://wp.local](http://wp.local)**

---

## Prerequisites

* macOS / Windows / Linux with **Docker** and **docker compose**
* SSH access to your hosting (CLI `ssh`, `rsync`, `mysqldump`)
* A terminal and basic shell utilities

---

## Project layout

```bash
wp-migration/
├─ .env
├─ docker-compose.yml
├─ config/
│  └─ wp-config-local.php
├─ data/
│  ├─ db/                           # MariaDB data (created on first run)
│  └─ wp/                           # full WordPress tree (from hosting)
│     └─ _migracion/
│        └─ db_dumps/               # SQL dumps (rsynced in)
├─ exports/                         # Simply Static output
└─ scripts/
   ├─ remote_dump.sh                # create DB dump on hosting
   ├─ sync_files.sh                 # rsync hosting → ./data/wp
   └─ db_import_entrypoint.sh       # robust auto-import on container start
```

Create folders:

```bash
mkdir -p wp-migration/{config,data/wp/_migracion/db_dumps,exports,scripts}
cd wp-migration
```

---

## 1) Environment variables (`.env`)

```ini
PROJECT_NAME=wp-local
LOCAL_DOMAIN=wp.local

# WordPress <-> DB
WORDPRESS_DB_NAME=wordpress
WORDPRESS_DB_USER=wordpress
WORDPRESS_DB_PASSWORD=wordpress
MYSQL_ROOT_PASSWORD=supersecure

# Hosting access
REMOTE_HOST=your-host.com
REMOTE_USER=youruser
REMOTE_PORT=22
REMOTE_WP_PATH=/home/youruser/public_html

# (optional) production URL (for search-replace later)
PROD_URL=https://www.yoursite.com
```

---

## 2) `docker-compose.yml`

* WordPress exposed on **port 80**.
* Network alias **wp.local** so containers can resolve that name.
* A small **db-importer** service runs once to import dumps.

```yaml
version: "3.9"

services:
  db:
    image: mariadb:10.11
    container_name: ${PROJECT_NAME}-db
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD}
      MYSQL_DATABASE: ${WORDPRESS_DB_NAME}
      MYSQL_USER: ${WORDPRESS_DB_USER}
      MYSQL_PASSWORD: ${WORDPRESS_DB_PASSWORD}
    volumes:
      - ./data/db:/var/lib/mysql
    healthcheck:
      test: ["CMD-SHELL", "mysqladmin ping -h localhost -p${MYSQL_ROOT_PASSWORD} --silent"]
      interval: 5s
      timeout: 3s
      retries: 40

  db-importer:
    image: mariadb:10.11
    container_name: ${PROJECT_NAME}-db-importer
    depends_on:
      db:
        condition: service_healthy
    environment:
      MYSQL_HOST: db
      MYSQL_PORT: 3306
      MYSQL_DATABASE: ${WORDPRESS_DB_NAME}
      MYSQL_USER: ${WORDPRESS_DB_USER}
      MYSQL_PASSWORD: ${WORDPRESS_DB_PASSWORD}
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD}
    volumes:
      - ./data/wp/_migracion/db_dumps:/dumps:ro
      - ./scripts/db_import_entrypoint.sh:/import.sh:ro
    entrypoint: ["sh","/import.sh"]

  wordpress:
    image: wordpress:6.6-php8.2-apache
    container_name: ${PROJECT_NAME}-wp
    depends_on:
      db:
        condition: service_healthy
      db-importer:
        condition: service_completed_successfully
    restart: unless-stopped
    ports:
      - "80:80"                       # canonical local port
    networks:
      default:
        aliases:
          - ${LOCAL_DOMAIN}           # containers resolve wp.local → wordpress
    environment:
      WORDPRESS_DB_HOST: db:3306
      WORDPRESS_DB_NAME: ${WORDPRESS_DB_NAME}
      WORDPRESS_DB_USER: ${WORDPRESS_DB_USER}
      WORDPRESS_DB_PASSWORD: ${WORDPRESS_DB_PASSWORD}
      WP_HOME:    http://${LOCAL_DOMAIN}
      WP_SITEURL: http://${LOCAL_DOMAIN}
    volumes:
      - ./data/wp:/var/www/html
      - ./config/wp-config-local.php:/var/www/html/wp-config-local.php:ro
      - ./exports:/var/www/html/simply-static-exports

  wp-cli:
    image: wordpress:cli-php8.2
    container_name: ${PROJECT_NAME}-wpcli
    depends_on:
      wordpress:
        condition: service_started
    working_dir: /var/www/html
    user: "33:33"                     # www-data
    environment:
      WORDPRESS_DB_HOST: db:3306
      WORDPRESS_DB_NAME: ${WORDPRESS_DB_NAME}
      WORDPRESS_DB_USER: ${WORDPRESS_DB_USER}
      WORDPRESS_DB_PASSWORD: ${WORDPRESS_DB_PASSWORD}
      WP_HOME:    http://${LOCAL_DOMAIN}
      WP_SITEURL: http://${LOCAL_DOMAIN}
    volumes:
      - ./data/wp:/var/www/html

  phpmyadmin:
    image: phpmyadmin:5
    container_name: ${PROJECT_NAME}-pma
    depends_on:
      db:
        condition: service_healthy
    ports:
      - "8081:80"
    environment:
      PMA_HOST: db
      PMA_USER: ${WORDPRESS_DB_USER}
      PMA_PASSWORD: ${WORDPRESS_DB_PASSWORD}
```

> On macOS, ensure `http://wp.local` resolves:
> Add this to `/etc/hosts`:
>
> ```
> 127.0.0.1  wp.local
> ```

---

## 3) Scripts

### `scripts/remote_dump.sh` — create DB dump **on the hosting**

```bash
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
```

### `scripts/sync_files.sh` — rsync hosting → local

```bash
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
```

### `scripts/db_import_entrypoint.sh` — robust auto-import (runs once)

```sh
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
```

Make them executable:

```bash
chmod +x scripts/*.sh
```

---

## 4) **Manual** `wp-config.php` change (recommended)

Because auto-patching can be flaky on macOS, do this **once** in the file you rsynced to `./data/wp/wp-config.php`:

**a) Add this include near the very top (right after `<?php`):**

```php
// Load local overrides as early as possible.
if (file_exists(__DIR__ . '/wp-config-local.php')) {
    require __DIR__ . '/wp-config-local.php';
}
```

**b) Ensure your DB constants end up pointing to the local DB.**
Easiest: keep the original `define('DB_…')` lines, but let the include override them (or convert them to conditional defines). The key is: when WordPress loads, **DB\_HOST must be `db:3306`** and the user must match your `.env`.

**`config/wp-config-local.php`** (create this file):

```php
<?php
// Local DB credentials (override production)
define('DB_NAME',     getenv('WORDPRESS_DB_NAME')     ?: 'wordpress');
define('DB_USER',     getenv('WORDPRESS_DB_USER')     ?: 'wordpress');
define('DB_PASSWORD', getenv('WORDPRESS_DB_PASSWORD') ?: 'wordpress');
define('DB_HOST',     getenv('WORDPRESS_DB_HOST')     ?: 'db:3306');

// Local URLs (match compose)
if (getenv('WP_HOME'))    define('WP_HOME',    getenv('WP_HOME'));
if (getenv('WP_SITEURL')) define('WP_SITEURL', getenv('WP_SITEURL'));

// Local dev toggles
define('WP_DEBUG', true);
define('WP_DEBUG_LOG', true);
define('FS_METHOD', 'direct');
```

> If you prefer not to change the original constants, you can *comment them out* in `wp-config.php` and rely solely on the local include for development.

---

## 5) Bootstrap: dump, sync, up, post-import

1. **Create dump on the hosting**

```bash
bash scripts/remote_dump.sh
```

2. **Sync the whole site to local**

```bash
bash scripts/sync_files.sh
```

3. **Host mapping (macOS)**

```
sudo sh -c 'echo "127.0.0.1  wp.local" >> /etc/hosts'
```

4. **Start containers**

```bash
docker compose up -d
```

5. **Set WordPress URLs to the canonical local domain**

```bash
docker compose run --rm wp-cli wp option update home    'http://wp.local'
docker compose run --rm wp-cli wp option update siteurl 'http://wp.local'
```

6. **(Optional) Install & activate Simply Static**

```bash
docker compose run --rm wp-cli wp plugin install simply-static --activate
```

7. **Verify DB + self-request**

```bash
docker compose run --rm wp-cli wp db check --skip-plugins --skip-themes && echo "DB OK"
docker compose run --rm wp-cli sh -lc 'wget -qO- -S http://wp.local >/dev/null && echo "Self-request OK"'
```

---

## 6) Configure Simply Static

In WP Admin → **Simply Static**:

* **General** → *Site URL*: `http://wp.local`
* **Destination** → *Local Directory*: `/var/www/html/simply-static-exports`
  (mapped to `./exports` on your machine)

Run an export; files will appear under `./exports`.

*Tip:* For portable output, enable **relative URLs** in Simply Static.

---

## Troubleshooting

### “Error establishing a database connection”

Your WordPress is still using **production DB constants**. Ensure:

```bash
docker compose run --rm wp-cli php -r 'include "wp-config.php"; echo "DB_HOST=",DB_HOST,"\nDB_USER=",DB_USER,"\n";'
# Expect: DB_HOST=db:3306 and DB_USER=wordpress (or your local user)
```

If not: fix `wp-config.php` so the **local include loads early** and sets DB constants.

---

### `mariadb-check … TLS/SSL error: Certificate is NOT trusted`

WP-CLI is connecting to your **hosted** DB (TLS cert) instead of the local one. Same fix as above: make sure `DB_HOST=db:3306` inside containers.

---

### MariaDB log: `Access denied for user 'root' ... (using password: NO)`

Some process is trying to log in as root with no password—usually a bad fallback when `DB_USER` is wrong. Verify from wp-cli:

```bash
docker compose run --rm wp-cli php -r 'include "wp-config.php"; echo DB_USER,":", (DB_PASSWORD!==""?"set":"EMPTY"),"\n";'
```

---

### Simply Static: “WordPress can make requests to itself” → **KO**

Don’t use `localhost:8080` for `home/siteurl`. Use `http://wp.local` on **port 80** (or, alternatively, inside containers use `host.docker.internal:8080` and browse with `localhost:8080`, but `wp.local` is cleaner).

---

### Port 80 is busy on macOS

Check and free it:

```bash
sudo lsof -i :80
# Common culprit: AirPlay Receiver (disable in System Settings → AirPlay & Handoff)
```

Or keep 8080 and use the `host.docker.internal` approach **inside containers only**.

---

### Permissions on macOS

If containers can’t read your dumps:

```bash
chmod -R a+r ./data/wp/_migracion/db_dumps
```

---

## Reset / re-import cleanly

If you want to wipe the DB and re-import from the latest dump:

```bash
docker compose down
rm -rf ./data/db/*
docker compose up -d
```

---

## Optional: use `host.docker.internal:8080` instead of `wp.local`

Keep your browser on `http://localhost:8080` but set inside containers:

* `WP_HOME` / `WP_SITEURL` = `http://host.docker.internal:8080`
* Update the two options with wp-cli accordingly.
* (On Linux, add `extra_hosts: ["host.docker.internal:host-gateway"]` to the `wordpress` and `wp-cli` services.)

This makes self-requests pass, but your browser may be redirected to `host.docker.internal`. The `wp.local` method avoids that.

---

## What to publish (TL;DR for your post)

1. Why: static export from a hosted WP → local Docker for reproducible builds.
2. Compose file (as above), environment, and directory layout.
3. Manual `wp-config.php` include at top + local overrides file.
4. `remote_dump.sh` + `sync_files.sh` + `db_import_entrypoint.sh`.
5. Canonical URL `http://wp.local` on port 80 (+ `/etc/hosts`).
6. `wp option update` for URLs, plugin install, export to `./exports`.
7. Troubleshooting cheatsheet (DB constants, TLS, self-request, permissions, port 80).

If you want, I can package this into a single **gist-ready** README with all code blocks and a minimal **Makefile** (`make dump`, `make sync`, `make up`, `make export`) so readers can copy it as a template.

______________


Love it — let’s “close the loop” with a **publish** script and wire it into a **Makefile** so the whole workflow is one command away.

Below you’ll get:

* A flexible `publish_static.sh` that uploads `./exports/` to your hosting via `rsync` over SSH.
* Two deployment modes:

  * `direct` (simple `rsync --delete` to the docroot).
  * `atomic_symlink` (zero-downtime: upload to timestamped `/.releases/…` and flip a `current` symlink).
* A small, safe default `.htaccess` for caching/compression (optional).
* A Makefile with handy targets: `dump`, `sync`, `up`, `urls`, `selftest`, `publish`, etc.

You said manual `wp-config.php` edits are fine — we’ll keep it that way.

---

# 1) New `.env` entries (add to your existing file)

```ini
# --- Publishing (adjust to your hosting) ---
PUBLISH_MODE=direct            # direct | atomic_symlink
PUBLISH_REMOTE_STATIC_PATH=/home/youruser/public_html_static   # docroot for static site (or subdomain root)
PUBLISH_SSH_PORT=22            # usually same as REMOTE_PORT
PUBLISH_EXCLUDES=".DS_Store,Thumbs.db"   # comma-separated
```

> Tip: On cPanel, point a subdomain (e.g. `static.example.com`) to `public_html_static`.
> If you want atomic symlink deploys, the *webserver’s DocumentRoot* must be set to `${PUBLISH_REMOTE_STATIC_PATH}/current` (one-time setup). If you can’t change it, keep `PUBLISH_MODE=direct`.

---

# 2) `scripts/publish_static.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail

# Load environment
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
set -a; source "${ROOT_DIR}/.env"; set +a

# Config
EXPORT_DIR="${ROOT_DIR}/exports"
REM="${REMOTE_USER}@${REMOTE_HOST}"
PORT="${PUBLISH_SSH_PORT:-${REMOTE_PORT:-22}}"
TARGET="${PUBLISH_REMOTE_STATIC_PATH:?PUBLISH_REMOTE_STATIC_PATH required}"
MODE="${PUBLISH_MODE:-direct}"

# Flags
DRYRUN=${DRYRUN:-0}     # DRYRUN=1 ./scripts/publish_static.sh
VERBOSE=${VERBOSE:-0}   # VERBOSE=1 ...

die(){ echo "ERROR: $*" >&2; exit 1; }
msg(){ echo "[publish] $*"; }

[ -d "$EXPORT_DIR" ] || die "Missing $EXPORT_DIR. Run Simply Static export first."
[ -n "$(find "$EXPORT_DIR" -mindepth 1 -maxdepth 1 -print -quit)" ] || die "$EXPORT_DIR is empty."

# Compose rsync options
RSYNC_OPTS=(-az --delete --compress-level=9 --human-readable --mkpath)
[ "$VERBOSE" = "1" ] && RSYNC_OPTS+=(-vv) || RSYNC_OPTS+=(--info=stats2)
[ "$DRYRUN" = "1" ] && RSYNC_OPTS+=(--dry-run)

# Excludes
IFS=',' read -r -a EXC_ARR <<< "${PUBLISH_EXCLUDES:-}"
for e in "${EXC_ARR[@]}"; do
  e="$(echo "$e" | xargs)" ; [ -n "$e" ] && RSYNC_OPTS+=(--exclude="$e")
done

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

# Quick sanity: index.html exists somewhere?
if ! find "$EXPORT_DIR" -name index.html -print -quit | grep -q . ; then
  msg "Warning: no index.html found in ${EXPORT_DIR}/ (ensure Simply Static exported correctly)."
fi

# Test SSH connectivity
ssh -p "$PORT" -o BatchMode=yes -o ConnectTimeout=10 "$REM" 'echo ok' >/dev/null || die "Cannot SSH to ${REM}:${PORT}"

STAMP="$(date +%Y%m%d-%H%M%S)"

case "$MODE" in
  direct)
    msg "Deploying in DIRECT mode to ${REM}:${TARGET}/"
    rsync "${RSYNC_OPTS[@]}" -e "ssh -p ${PORT}" "${EXPORT_DIR}/" "${REM}:${TARGET}/"
    ;;

  atomic_symlink)
    # Requires webserver DocumentRoot = ${TARGET}/current
    RELEASES="${TARGET}/.releases"
    NEWREL="${RELEASES}/${STAMP}"
    msg "Deploying in ATOMIC_SYMLINK mode (releases at ${RELEASES}, current -> ${NEWREL})"
    ssh -p "$PORT" "$REM" "mkdir -p '${RELEASES}'"

    # Upload to new release dir
    rsync "${RSYNC_OPTS[@]}" -e "ssh -p ${PORT}" "${EXPORT_DIR}/" "${REM}:${NEWREL}/"

    # Flip symlink atomically
    ssh -p "$PORT" "$REM" "ln -sfn '${NEWREL}' '${TARGET}/current' && echo 'current -> ${NEWREL}'"
    ;;

  *)
    die "Unknown PUBLISH_MODE=$MODE (use direct | atomic_symlink)"
    ;;
esac

msg "Publish complete."
```

```bash
chmod +x scripts/publish_static.sh
```

**How it works**

* `direct`: mirrors `./exports/` straight into `${PUBLISH_REMOTE_STATIC_PATH}` with `--delete`.
* `atomic_symlink`: uploads to `…/.releases/<timestamp>/` then atomically points `current` to it.
  One-time requirement: set your vhost/subdomain’s **DocumentRoot** to `${PUBLISH_REMOTE_STATIC_PATH}/current`.

Dry-run example:

```bash
DRYRUN=1 VERBOSE=1 ./scripts/publish_static.sh
```

---

# 3) Makefile (end-to-end workflow)

Save as `Makefile` at project root:

```makefile
SHELL := /bin/bash

.PHONY: help dump sync up down urls selftest cli pma publish clean-db clean-all

help:
	@echo "Targets:"
	@echo "  dump       - Create DB dump on hosting (remote_dump.sh)"
	@echo "  sync       - Rsync hosting -> ./data/wp"
	@echo "  up         - docker compose up -d (WP at http://wp.local)"
	@echo "  down       - docker compose down"
	@echo "  urls       - Set WordPress home/siteurl to http://wp.local"
	@echo "  selftest   - Check DB and self-request from container"
	@echo "  cli        - Open WP-CLI shell"
	@echo "  pma        - phpMyAdmin at http://localhost:8081"
	@echo "  publish    - Rsync ./exports to hosting (direct/atomic)"
	@echo "  clean-db   - Remove local DB volume (forces reimport)"
	@echo "  clean-all  - Remove DB + containers"

dump:
	bash scripts/remote_dump.sh

sync:
	bash scripts/sync_files.sh

up:
	docker compose up -d

down:
	docker compose down

urls:
	docker compose run --rm wp-cli wp option update home    'http://wp.local'
	docker compose run --rm wp-cli wp option update siteurl 'http://wp.local'

selftest:
	docker compose run --rm wp-cli wp db check --skip-plugins --skip-themes
	docker compose run --rm wp-cli sh -lc 'wget -qO- -S http://wp.local >/dev/null && echo "Self-request OK"'

cli:
	docker compose run --rm wp-cli bash

pma:
	@echo "phpMyAdmin -> http://localhost:8081"

publish:
	bash scripts/publish_static.sh

clean-db:
	docker compose down
	rm -rf ./data/db/*

clean-all:
	docker compose down -v
	rm -rf ./data/db/*
```

> Export step: run the Simply Static export from WP Admin (Destination: `/var/www/html/simply-static-exports`), then `make publish`.

---

## Usage (full cycle)

```bash
make dump        # 1) create dump on hosting
make sync        # 2) mirror WP files locally
make up          # 3) start stack (http://wp.local)
make urls        # 4) set home/siteurl to http://wp.local (once)

# In WP Admin: run Simply Static export (outputs to ./exports)

make selftest    # optional: DB + self-request checks
make publish     # 5) upload ./exports to your hosting
```

**Dry-run publish** (see what would change without touching the server):

```bash
DRYRUN=1 VERBOSE=1 make publish
```

---

## Notes & tips

* If your host doesn’t allow symlinks as docroot, stick to `PUBLISH_MODE=direct`.
* If you want per-file caching rules, keep the default `.htaccess` (edit as needed).
* To re-import DB cleanly: `make clean-db && make up`.
* For multiple sites, duplicate this project folder; each keeps its own `.env`.

If you want, I can also add a **GitHub Pages / S3** variant of `publish_static.sh` (using `gh-pages` or `aws s3 sync`)—but for classic LAMP hosts, the script above is the simplest and most robust.
