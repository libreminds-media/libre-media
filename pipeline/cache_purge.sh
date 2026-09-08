#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Evict cached media from the local nginx proxy cache.
#
#   make cache-purge PREFIX=events/2024-kcd-kerala
#   make cache-purge PREFIX=events/2024-kcd-kerala/display/ab12cd34ef56.jpg
#   make cache-purge PREFIX=events/2024-kcd-kerala DRY=1
#
# Deleting an object from B2 does NOT take it off the site: our cache holds it
# for CACHE_INACTIVE (30 days) and serves it with `immutable`. Anything removed
# for consent or copyright reasons has to be purged here too.
#
# WHAT THE CACHE KEY ACTUALLY IS
# cache/nginx.conf.template rewrites /media/<path> to /file/<bucket>/<path>
# BEFORE proxy_cache_key is evaluated, so the key nginx stores is the upstream
# path, not the browser-facing one:
#
#     browser  /media/events/2025-test/display/ab12.jpg
#     KEY:     /file/libreminds-media/events/2025-test/display/ab12.jpg
#
# PREFIX is given in browser terms (without /media/) and translated here. Match
# on the wrong one and you silently purge nothing, which looks identical to
# success -- hence the count in the output.
#
# Runs as root inside the cache container via docker exec: cache-data is owned
# by the container's unprivileged nginx user (uid 101), which does not exist on
# the host, so the host account cannot remove those files.

set -euo pipefail
cd "$(dirname "$0")/.."

PREFIX="${PREFIX:-}"
DRY="${DRY:-0}"
CONTAINER="libre-media-cache"

die()  { echo "cache-purge: error: $*" >&2; exit 1; }
info() { echo "==> $*"; }

[ -n "$PREFIX" ] || die 'PREFIX is required, e.g. PREFIX=events/2024-kcd-kerala'
case "$PREFIX" in
  /media/*) PREFIX="${PREFIX#/media/}" ;;   # tolerate the browser-facing form
  /*)       PREFIX="${PREFIX#/}" ;;
esac
case "$PREFIX" in
  *..*) die "PREFIX must not contain '..': $PREFIX" ;;
esac

[ -f .env ] || die ".env not found"
BUCKET="$(grep -E '^B2_BUCKET=' .env | head -1 | cut -d= -f2-)"
[ -n "$BUCKET" ] || die "B2_BUCKET not set in .env"

docker inspect "$CONTAINER" >/dev/null 2>&1 \
  || die "$CONTAINER is not running -- start it with: make up"

KEY_PREFIX="/file/${BUCKET}/${PREFIX}"
info "purging cache entries with KEY starting: ${KEY_PREFIX}"

# -i is essential: without it docker exec does not attach stdin, the heredoc
# below is never delivered, and the command silently does nothing while
# reporting success -- which is indistinguishable from "nothing to purge".
docker exec -i -e KP="$KEY_PREFIX" -e DRYRUN="$DRY" "$CONTAINER" sh -s <<'INNER'
set -eu
DIR=/var/cache/nginx/media
# -a: cache files are binary. -l: names only. -F: KEY_PREFIX contains dots and
# other regex metacharacters, so match it literally.
files="$(grep -rlaF "KEY: ${KP}" "$DIR" 2>/dev/null || true)"
n=0
for f in $files; do
  [ -f "$f" ] || continue
  n=$((n + 1))
  if [ "$DRYRUN" = "1" ]; then
    key="$(head -c 512 "$f" | strings | grep -m1 '^KEY:' || echo 'KEY: <unreadable>')"
    printf '    would purge  %s\n' "$key"
  else
    rm -f "$f"
  fi
done
if [ "$DRYRUN" = "1" ]; then
  printf '    %s cache file(s) would be purged\n' "$n"
else
  printf '    %s cache file(s) purged\n' "$n"
fi
INNER
