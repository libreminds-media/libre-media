# libre-media — LibreMinds event photo & video gallery
#
# Everything in this project is driven from here. Run `make` for the list.
#
# NOTE ON DRY RUNS: use `DRY=1`, never `--dry-run`. `--dry-run` is GNU make's
# own flag (an alias for -n) and would stop make from running anything at all.
#
#     make publish SLUG=2025-kcd-bengaluru DRY=1     <- correct
#     make publish SLUG=2025-kcd-bengaluru --dry-run <- does nothing useful

SHELL := /bin/bash
.DEFAULT_GOAL := help

COMPOSE := docker compose
NGINX_IMAGE := nginx:alpine
SLUG ?=
SRC ?=
DRY ?= 0
TARGET ?= .
LG ?= 2.9.0

# Run the tools container as whoever runs make, so files it writes into
# web/albums/ and inbox/ are not root-owned. An explicit PUID in .env wins.
ifeq ($(shell grep -cs '^PUID=' .env),0)
export PUID := $(shell id -u)
export PGID := $(shell id -g)
endif

# ---------------------------------------------------------------------------

.PHONY: help up down restart logs check build publish publish-dry index \
        backup restore cache-stats cache-clear migrate-check shell \
        vendor-lightgallery tree env-check import import-dry onedrive-ls

help:
	@echo "libre-media — make targets"
	@echo
	@echo "  Running"
	@echo "    make check            validate compose + both nginx configs (no containers)"
	@echo "    make up               start web + cache (runs check first)"
	@echo "    make down             stop web + cache"
	@echo "    make restart          down then up"
	@echo "    make logs             follow container logs"
	@echo
	@echo "  Publishing"
	@echo "    make build            build the tools image"
	@echo "    make publish SLUG=2025-my-event        build, upload, install, commit"
	@echo "    make publish-dry SLUG=2025-my-event    same, but change nothing"
	@echo "    make index            rebuild web/albums/index.json from the album JSON"
	@echo
	@echo "  Importing from OneDrive"
	@echo "    make import SLUG=2025-my-event SRC=\"Photos/My Event\"   download originals"
	@echo "    make import-dry SLUG=... SRC=\"...\"                     show what would download"
	@echo "    make onedrive-ls [SRC=\"Photos\"]                        list OneDrive folders"
	@echo
	@echo "  Operations"
	@echo "    make backup           album metadata -> B2 (_site/)"
	@echo "    make restore          B2 (_site/) -> here"
	@echo "    make restore TARGET=.restore-check     restore into a scratch dir"
	@echo "    make cache-stats      media cache size and disk headroom"
	@echo "    make cache-clear      empty the media cache (safe; it refills from B2)"
	@echo "    make migrate-check    can this project move to a new server today?"
	@echo "    make shell            a shell in the tools container"
	@echo
	@echo "  Add DRY=1 to publish, backup or restore to change nothing."

# --- guards ----------------------------------------------------------------

env-check:
	@test -f .env || { \
		echo "make: .env not found."; \
		echo "      cp .env.example .env && chmod 600 .env, then fill it in."; \
		exit 1; }

# --- validation ------------------------------------------------------------

# Validates BOTH nginx configs by rendering them with the real .env inside a
# throwaway nginx container. Deliberately uses plain `docker run` rather than
# `docker compose run`: a compose one-off would inherit the service's caddy
# labels and briefly show up as a duplicate site to caddy-docker-proxy.
# --network none guarantees this can touch nothing.
check: env-check
	@echo "==> docker compose config"
	@$(COMPOSE) config -q && echo "    compose OK"
	@echo "==> nginx -t (cache)"
	@docker run --rm --network none --env-file .env \
		-e NGINX_ENVSUBST_FILTER='^(B2_|CACHE_|MEDIA_|RESOLVER)' \
		-v "$(CURDIR)/cache/nginx.conf.template:/etc/nginx/templates/default.conf.template:ro" \
		$(NGINX_IMAGE) nginx -t 2>&1 | sed 's/^/    /'
	@echo "==> nginx -t (web)"
	@docker run --rm --network none --env-file .env \
		-e NGINX_ENVSUBST_FILTER='^(WEB_|SITE_)' \
		-v "$(CURDIR)/webconf/default.conf.template:/etc/nginx/templates/default.conf.template:ro" \
		-v "$(CURDIR)/web:/usr/share/nginx/html:ro" \
		$(NGINX_IMAGE) nginx -t 2>&1 | sed 's/^/    /'

# --- lifecycle -------------------------------------------------------------

up: check
	$(COMPOSE) up -d
	@echo
	@echo "==> caddy-docker-proxy log (watching for label errors)"
	@sleep 3
	@docker logs --since 15s caddy-proxy 2>&1 | tail -20 | sed 's/^/    /' || \
		echo "    (could not read caddy-proxy logs)"
	@echo
	@echo "    https://$$(grep -E '^SITE_HOST=' .env | cut -d= -f2-)/"

down:
	$(COMPOSE) down

restart: down up

logs:
	$(COMPOSE) logs -f --tail=100

# --- publishing ------------------------------------------------------------

build: env-check
	$(COMPOSE) --profile tools build tools

publish: env-check
	@test -n "$(SLUG)" || { echo "make: SLUG is required, e.g. make publish SLUG=2025-my-event"; exit 1; }
	SLUG="$(SLUG)" DRY="$(DRY)" ./pipeline/publish.sh

publish-dry: env-check
	@test -n "$(SLUG)" || { echo "make: SLUG is required, e.g. make publish-dry SLUG=2025-my-event"; exit 1; }
	SLUG="$(SLUG)" DRY=1 ./pipeline/publish.sh

index: env-check
	$(COMPOSE) --profile tools run --rm -T tools pipeline/update_index.py

# --- OneDrive import -------------------------------------------------------

import: env-check
	@test -n "$(SLUG)" || { echo "make: SLUG is required, e.g. make import SLUG=2025-my-event SRC=\"Photos/My Event\""; exit 1; }
	@test -n "$(SRC)"  || { echo "make: SRC is required: the folder path inside the OneDrive account"; exit 1; }
	SLUG="$(SLUG)" SRC="$(SRC)" DRY="$(DRY)" ./pipeline/import.sh

import-dry: env-check
	@test -n "$(SLUG)" || { echo "make: SLUG is required"; exit 1; }
	@test -n "$(SRC)"  || { echo "make: SRC is required"; exit 1; }
	SLUG="$(SLUG)" SRC="$(SRC)" DRY=1 ./pipeline/import.sh

# Browse the OneDrive account so you can find the right SRC path.
onedrive-ls: env-check
	$(COMPOSE) --profile tools run --rm -T tools -lc \
	  'rclone lsd "onedrive:$(SRC)" 2>&1 | sed "s/^/  /"'

# --- operations ------------------------------------------------------------

backup: env-check
	DRY="$(DRY)" ./pipeline/backup.sh

restore: env-check
	DRY="$(DRY)" TARGET="$(TARGET)" ./pipeline/restore.sh

cache-stats:
	@echo "==> media cache"
	@printf '    size      %s\n' "$$(du -sh cache-data 2>/dev/null | cut -f1 || echo 0)"
	@printf '    objects   %s\n' "$$(find cache-data -type f 2>/dev/null | wc -l)"
	@printf '    limit     %s (min_free %s)\n' \
		"$$(grep -E '^CACHE_MAX_SIZE=' .env 2>/dev/null | cut -d= -f2-)" \
		"$$(grep -E '^CACHE_MIN_FREE=' .env 2>/dev/null | cut -d= -f2-)"
	@echo "==> filesystem"
	@df -h . | sed '1d;s/^/    /'

cache-clear:
	@echo "This deletes every cached media object in cache-data/."
	@echo "Nothing is lost: the cache refills from B2 on the next request."
	@read -r -p "Type 'yes' to continue: " a; [ "$$a" = yes ] || { echo "aborted"; exit 1; }
	$(COMPOSE) stop cache
	find cache-data -mindepth 1 -delete
	$(COMPOSE) start cache
	@echo "cache cleared"

migrate-check:
	@./pipeline/migrate_check.sh

shell: env-check
	$(COMPOSE) --profile tools run --rm tools

# --- maintenance -----------------------------------------------------------

# Re-download the vendored copy of lightGallery. Build-time only; the site
# itself never talks to a CDN.
vendor-lightgallery:
	@./pipeline/vendor_lightgallery.sh "$(LG)"

tree:
	@git ls-files | sed 's|[^/]*/|  |g' | head -100
