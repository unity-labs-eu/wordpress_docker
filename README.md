# WordPress → Docker (local) → Simply Static → Publish

A reproducible way to mirror a hosted WordPress site locally (Docker), export static HTML via **Simply Static** (from WP Admin), create safety backups, and publish to a remote server with `rsync`.

> ✅ No Pro license required for the core flow.
> 🧩 Optional sections note where **Simply Static Pro** + WP-CLI can automate exports later.

---

## What you get

* **Docker Compose** stack: WordPress + MariaDB + WP-CLI (+ optional phpMyAdmin).
* **One canonical local URL**: `http://wp.local` on port 80 (fixed self-request checks).
* **rsync sync** from hosting → local (`./data/wp`).
* **DB auto-import** on first run (if dumps exist).
* **Manual static export** (WP Admin → Simply Static) into `./exports`.
* **Safe publishing** (rsync) with:

  * pre-publish **DB dump**,
  * a full **tar.gz** of `./data/wp`,
  * and a locked-down `./exports/backups/.htaccess`.
* **Makefile** targets to run the entire flow.

---

## Repository structure

```
.
├─ .env                         # project settings (edit)
├─ docker-compose.yml
├─ Makefile                     # handy tasks (see below)
├─ config/
│  └─ wp-config-local.php       # local overrides (loaded by wp-config.php)
├─ data/
│  ├─ db/                       # MariaDB volume (auto-created)
│  └─ wp/                       # WordPress files (rsynced from hosting)
│     └─ _migracion/
│        └─ db_dumps/           # SQL dumps (.sql / .sql.gz)
├─ exports/                     # Simply Static output
│  └─ backups/                  # full backups created before publish
└─ scripts/
   ├─ remote_dump.sh            # create dump on hosting
   ├─ sync_files.sh             # rsync hosting → ./data/wp
   ├─ db_import_entrypoint.sh   # auto-import latest dump on first run
   ├─ dump_local_db.sh          # dump the local DB into db_dumps/
   ├─ backup_full.sh            # DB dump + tar.gz of ./data/wp → ./exports/backups
   └─ publish_static.sh         # rsync deploy (direct/atomic), with backups
```

---

## Prerequisites

* Docker Desktop (macOS/Windows) or Docker Engine (Linux).
* Shell tools: `ssh`, `rsync`, `tar`, `gzip`.
* SSH access to your hosting.
* macOS note: The stock `rsync` is old. The scripts autodetect flags, but you can install a newer version:

  * `brew install rsync` then set `RSYNC_BIN=/opt/homebrew/bin/rsync` in your shell or `.env`.

---

## 1) Configure `.env`

Copy the sample below and adjust to your environment:

```ini
PROJECT_NAME=wp-local
LOCAL_DOMAIN=wp.local

# Database (local compose)
WORDPRESS_DB_NAME=wordpress
WORDPRESS_DB_USER=wordpress
WORDPRESS_DB_PASSWORD=wordpress
MYSQL_ROOT_PASSWORD=supersecure

# Hosting access
REMOTE_HOST=your-host.com
REMOTE_USER=youruser
REMOTE_PORT=22
REMOTE_WP_PATH=/home/youruser/public_html

# (optional) for search-replace scripts if you add them later
PROD_URL=https://www.example.com

# Publishing
PUBLISH_MODE=direct                 # direct | atomic_symlink
PUBLISH_REMOTE_STATIC_PATH=/home/youruser/public_html_static
PUBLISH_SSH_PORT=22
PUBLISH_EXCLUDES=".DS_Store,Thumbs.db"

# Backups before publish (1=on, 0=off)
PUBLISH_BACKUP_BEFORE=1

# (Optional) If you install rsync via Homebrew:
# RSYNC_BIN=/opt/homebrew/bin/rsync
```

> If you pick `atomic_symlink`, your webserver’s **DocumentRoot** must point to `${PUBLISH_REMOTE_STATIC_PATH}/current`. Otherwise, use `direct`.

---

## 2) One-time host mapping

Add this line to your host `/etc/hosts` so the browser and containers share one canonical name:

```
127.0.0.1   wp.local
```

---

## 3) First-time migration (from hosting to local)

```bash
# 1) Create a DB dump on the hosting (saved next to the WP files there)
make dump

# 2) Sync the entire WordPress tree into ./data/wp (includes the dump)
make sync

# 3) Start the stack
make up

# 4) Set WordPress URL to the local canonical domain (once)
make urls

# 5) Open WP Admin at http://wp.local and log in
open http://wp.local
```

### Important: wp-config link to local overrides

Ensure your `./data/wp/wp-config.php` has this near the top (right after `<?php`):

```php
// Load local overrides as early as possible.
if (file_exists(__DIR__ . '/wp-config-local.php')) {
    require __DIR__ . '/wp-config-local.php';
}
```

…and that `config/wp-config-local.php` points to your local DB:

```php
<?php
define('DB_NAME',     getenv('WORDPRESS_DB_NAME')     ?: 'wordpress');
define('DB_USER',     getenv('WORDPRESS_DB_USER')     ?: 'wordpress');
define('DB_PASSWORD', getenv('WORDPRESS_DB_PASSWORD') ?: 'wordpress');
define('DB_HOST',     getenv('WORDPRESS_DB_HOST')     ?: 'db:3306');

if (getenv('WP_HOME'))    define('WP_HOME',    getenv('WP_HOME'));
if (getenv('WP_SITEURL')) define('WP_SITEURL', getenv('WP_SITEURL'));

define('WP_DEBUG', true);
define('WP_DEBUG_LOG', true);
define('FS_METHOD', 'direct');
```

> If you previously had production constants hard-coded, update them or comment them out. The key is that inside containers **`DB_HOST` must be `db:3306`**.

---

## 4) Daily workflow

### A) Update local mirror from hosting

```bash
make dump       # refresh DB dump on hosting
make sync       # rsync latest files into ./data/wp
make up         # ensure stack is running
```

### B) Generate static site (manual, no Pro)

From **WP Admin** → **Simply Static**:

* General → **Site URL**: `http://wp.local`
* Destination → **Local Directory**: `/var/www/html/simply-static-exports`

Run the export. Files appear under `./exports`.

> If you later install **Simply Static Pro**, you can add a CLI export step to the Makefile; see “Optional: WP-CLI export” below.

### C) Publish (with backups)

```bash
make publish-safe
```

This will:

1. **Dump the local DB** to `./data/wp/_migracion/db_dumps/local-*.sql.gz`.
2. **Archive** your entire `./data/wp` into `./exports/backups/wp-full-*.tar.gz` (with access denied via `.htaccess`).
3. **Deploy** `./exports/` to your server via `rsync` (mode = `direct` or `atomic_symlink`).

---

## 5) Make targets

Common targets (see the Makefile for the full list):

```bash
make help              # list targets
make dump              # create DB dump on hosting
make sync              # rsync hosting → ./data/wp
make up                # docker compose up -d (site at http://wp.local)
make down              # docker compose down
make urls              # set home/siteurl to http://wp.local
make selftest          # DB check + container self-request to http://wp.local
make dump-local        # dump local DB to db_dumps/
make backup-full       # DB dump + tar.gz of ./data/wp to ./exports/backups
make publish           # publish (respects PUBLISH_BACKUP_BEFORE flag)
make publish-safe      # force backup + publish
make reseed-from-latest# destroy local DB and re-seed from latest dump
make clean-db          # remove local DB volume
make clean-all         # remove DB + containers
```

---

## 6) Publishing modes

* **direct**: rsync `./exports/` → `${PUBLISH_REMOTE_STATIC_PATH}/` (with `--delete`).
* **atomic\_symlink**: rsync into `${PUBLISH_REMOTE_STATIC_PATH}/.releases/<timestamp>/` and atomically update `${PUBLISH_REMOTE_STATIC_PATH}/current` symlink.
  Set your vhost/subdomain DocumentRoot to `/current` to enable zero-downtime swaps.

Backups (`./exports/backups/`) are **never** uploaded (auto-excluded).

---

## 7) Restore / re-seed

If you want to wipe the local DB and re-import the latest dump:

```bash
make reseed-from-latest
```

On first boot, the importer looks into `./data/wp/_migracion/db_dumps/` and restores the **newest** `.sql`/`.sql.gz`.

---

## 8) Troubleshooting

* **WP-CLI says TLS cert not trusted / connects to remote DB**
  Your config still points to production. From inside the container:

  ```bash
  docker compose run --rm wp-cli php -r 'include "wp-config.php"; echo DB_HOST,"\n";'
  ```

  Ensure it prints `db:3306`.

* **Simply Static “self-request” check fails**
  Don’t use `localhost:8080` as site URL. Use the canonical **`http://wp.local` on port 80**.

* **Port 80 already in use on macOS**
  `sudo lsof -i :80` (AirPlay Receiver is a common culprit). Disable or change its port.

* **macOS rsync flags unsupported**
  The scripts detect features. To use newer flags, install rsync via Homebrew and set `RSYNC_BIN`.

* **Permissions when reading dumps on macOS**
  If needed: `chmod -R a+r ./data/wp/_migracion/db_dumps`.

---

## 9) Optional: WP-CLI export (Simply Static Pro)

If/when you install **Simply Static Pro**, you can automate exports before publishing:

* Set in `.env`:

  ```ini
  SS_ENABLE_WPCLI=1
  SS_EXPORT_ARGS=
  SS_LICENSE_KEY=    # optional
  ```
* Use:

  ```bash
  make publish-safe  # will run export → backup → deploy
  ```

(For now, with the free plugin, keep exporting from WP Admin.)

---

## 10) Security & Git hygiene

* **Never commit secrets** in `.env`.
* Consider `.gitignore` entries like:

  ```
  .env
  data/db/
  data/wp/_migracion/db_dumps/
  exports/backups/
  ```
* The backup folder ships a `.htaccess` with `Require all denied` for safety if ever hosted by mistake.

---

## FAQ

**Q: Can I use a different local domain or port?**
Yes. Update `LOCAL_DOMAIN` and the compose `ports` mapping. If you keep a non-80 port, you can also use `host.docker.internal:PORT` inside containers. Using port 80 with `wp.local` is the simplest for diagnostics.

**Q: My host doesn’t allow symlinks or custom docroots.**
Use `PUBLISH_MODE=direct`.

**Q: How do I re-sync only uploads?**
Add excludes in `scripts/sync_files.sh` or run your own `rsync` to `./data/wp/wp-content/uploads/`.

---

## Credits

Built with ❤️ on top of official Docker images for WordPress, MariaDB, and phpMyAdmin; Simply Static by Patrick Posner.

