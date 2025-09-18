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
