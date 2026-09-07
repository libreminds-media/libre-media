#!/usr/bin/env bash
#
# Reverse of backup.sh: pull album metadata back out of B2.
#
#   make restore                      restore in place (web/albums/, inbox/)
#   make restore TARGET=.restore-check  restore into a scratch dir to verify
#   make restore DRY=1                show what would be downloaded
#
# TARGET must be a path INSIDE this repository, because the tools container
# only has the repository mounted (at /work).
#
# On a new server this is step 4 of the migration -- see MIGRATE.md.

set -euo pipefail

DRY="${DRY:-0}"
TARGET="${TARGET:-.}"
info() { echo "==> $*"; }
die()  { echo "restore: error: $*" >&2; exit 1; }

case "$TARGET" in
  /*|*..*) die "TARGET must be a relative path inside the repo, got: $TARGET" ;;
esac

if [ "$DRY" = "1" ]; then
  RCLONE_DRY=(--dry-run)
  info "DRY RUN -- nothing will be written"
else
  RCLONE_DRY=()
fi

# --- inner pass: inside the tools container --------------------------------
if [ "${IN_TOOLS:-0}" = "1" ]; then
  : "${B2_BUCKET:?B2_BUCKET not set in the container environment}"

  mkdir -p "${TARGET}/web/albums" "${TARGET}/inbox"

  info "b2:${B2_BUCKET}/_site/albums/ -> ${TARGET}/web/albums/"
  rclone copy "b2:${B2_BUCKET}/_site/albums/" "${TARGET}/web/albums" \
    "${RCLONE_DRY[@]}" --transfers 4 --stats-one-line --verbose

  info "b2:${B2_BUCKET}/_site/inbox/ -> ${TARGET}/inbox/"
  rclone copy "b2:${B2_BUCKET}/_site/inbox/" "${TARGET}/inbox" \
    "${RCLONE_DRY[@]}" --transfers 4 --stats-one-line --verbose

  info "restore complete into ${TARGET}"
  exit 0
fi

# --- outer pass: on the host -----------------------------------------------
cd "$(dirname "$0")/.."
[ -f .env ] || die ".env not found"

if [ "$TARGET" = "." ] && [ "$DRY" != "1" ]; then
  info "restoring IN PLACE over web/albums/ and inbox/"
fi

# The tools container runs as PUID:PGID (non-root) and so cannot create a new
# directory at the repository root, which is root-owned. Create TARGET here on
# the host, where we have the rights, and hand it over with the ownership the
# container needs. Without this, `make restore TARGET=<newdir>` fails with
# "mkdir: cannot create directory: Permission denied".
if [ "$DRY" != "1" ]; then
  mkdir -p "${TARGET}/web/albums" "${TARGET}/inbox"
  PUID_V="$(grep -E '^PUID=' .env | head -1 | cut -d= -f2-)"
  PGID_V="$(grep -E '^PGID=' .env | head -1 | cut -d= -f2-)"
  if [ "$(id -u)" = "0" ] && [ -n "$PUID_V" ] && [ -n "$PGID_V" ]; then
    chown -R "${PUID_V}:${PGID_V}" "${TARGET}"
  fi
fi

TTY_FLAG=()
[ -t 1 ] || TTY_FLAG=(-T)

docker compose --profile tools run --rm "${TTY_FLAG[@]}" \
  -e IN_TOOLS=1 -e DRY="$DRY" -e TARGET="$TARGET" \
  tools pipeline/restore.sh
