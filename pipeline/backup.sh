#!/usr/bin/env bash
#
# Back up the only state that lives on this server.
#
#   make backup           real
#   make backup DRY=1     show what would be transferred
#
# Media bytes already live in B2 and cache-data/ is disposable, so the entire
# backup is:
#     web/albums/*.json        the site's album metadata (also tracked in git)
#     inbox/*/album.yaml       volunteer-authored album metadata (NOT in git)
#
# Destination: b2:<bucket>/_site/   Uses `copy`, never `sync` -- this command
# can add and update, but can never delete (CLAUDE.md §7).
#
# NOTE: plain `copy`, with NO --immutable. These files change every time an
# album is edited, so --immutable would make every nightly backup after the
# first one fail. --immutable belongs only on the events/ media upload in
# publish.sh, where filenames are content hashes and really never change.

set -euo pipefail

DRY="${DRY:-0}"
info() { echo "==> $*"; }
die()  { echo "backup: error: $*" >&2; exit 1; }

if [ "$DRY" = "1" ]; then
  RCLONE_DRY=(--dry-run)
  info "DRY RUN -- nothing will be uploaded"
else
  RCLONE_DRY=()
fi

# --- inner pass: inside the tools container --------------------------------
if [ "${IN_TOOLS:-0}" = "1" ]; then
  : "${B2_BUCKET:?B2_BUCKET not set in the container environment}"

  info "web/albums/ -> b2:${B2_BUCKET}/_site/albums/"
  rclone copy web/albums "b2:${B2_BUCKET}/_site/albums/" \
    "${RCLONE_DRY[@]}" --transfers 4 --stats-one-line --verbose

  info "inbox/*/album.yaml -> b2:${B2_BUCKET}/_site/inbox/"
  # --include with a leading pattern keeps the <slug>/ directory structure.
  rclone copy inbox "b2:${B2_BUCKET}/_site/inbox/" \
    "${RCLONE_DRY[@]}" \
    --include "*/album.yaml" \
    --transfers 4 --stats-one-line --verbose

  info "backup complete"
  exit 0
fi

# --- outer pass: on the host -----------------------------------------------
cd "$(dirname "$0")/.."
[ -f .env ] || die ".env not found"

TTY_FLAG=()
[ -t 1 ] || TTY_FLAG=(-T)

docker compose --profile tools run --rm "${TTY_FLAG[@]}" \
  -e IN_TOOLS=1 -e DRY="$DRY" \
  tools pipeline/backup.sh
