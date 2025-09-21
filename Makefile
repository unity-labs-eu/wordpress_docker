SHELL := /bin/bash

.PHONY: help dump sync up down urls selftest cli pma publish clean-db clean-all dump-local reseed-from-latest list-dumps backup-full publish-safe

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
	bash scripts/post_import.sh

selftest:
	docker compose run --rm wp-cli wp db check --skip-plugins --skip-themes
	docker compose run --rm wp-cli sh -lc 'wget -qO- -S http://wp.local >/dev/null && echo "Self-request OK"'

cli:
	docker compose run --rm wp-cli bash

pma:
	@echo "phpMyAdmin -> http://localhost:8081"

backup-full:
	bash scripts/backup_full.sh

# Publish with automatic DB+files backup beforehand
publish-safe:
	PUBLISH_BACKUP_BEFORE=1 bash scripts/publish_static.sh

# (Keep your existing `publish:` if you want the plain one)
publish:
	bash scripts/publish_static.sh

clean-db:
	docker compose down
	rm -rf ./data/db/*

clean-all:
	docker compose down -v
	rm -rf ./data/db/*

# Dump the running local DB into ./data/wp/_migracion/db_dumps/local-<timestamp>.sql.gz
dump-local:
	bash scripts/dump_local_db.sh

# Destroy local DB volume and re-seed from the most recent dump in db_dumps/
reseed-from-latest:
	docker compose down
	rm -rf ./data/db/*
	docker compose up -d

# Show available dumps (newest first)
list-dumps:
	@ls -lt ./data/wp/_migracion/db_dumps | awk '{print $$6, $$7, $$8, $$9}'
