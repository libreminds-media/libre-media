#!/bin/sh
# Runs as root from the stock nginx entrypoint, before nginx starts.
#
# /var/cache/nginx/media is a bind mount from ./cache-data on the host, so it
# arrives owned by whoever created it. nginx only chowns cache directories it
# creates itself, so an existing bind mount would be unwritable by the
# unprivileged worker. Fix it here rather than requiring a host-side chown.
set -e
dir=/var/cache/nginx/media
mkdir -p "$dir"
chown -R nginx:nginx "$dir" 2>/dev/null || \
  echo "05-cache-perms.sh: WARNING could not chown $dir; cache may be read-only" >&2
