#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Take a single photo or video down, leaving the rest of the album alone.
#
#   make unpublish-photo SLUG=2024-my-event ID=ab12cd34ef56 DRY=1   REQUIRED FIRST
#   make unpublish-photo SLUG=2024-my-event ID=ab12cd34ef56
#
# ID is the item's "id" in web/albums/<slug>.json -- the first 12 characters of
# the derivative's content hash, which is also its filename.
#
# Same gates as `make unpublish`: a dry run within the last 10 minutes, a
# printed object count, and typed confirmation. Objects are deleted one at a
# time by explicit path; no purge, no sync.
#
# The SOURCE original is removed too. Without that, the next `make publish`
# rebuilds the photo from inbox/ and puts it straight back.

set -euo pipefail
cd "$(dirname "$0")/.."

SLUG="${SLUG:-}"
ID="${ID:-}"
DRY="${DRY:-0}"
MARKER_DIR=".unpublish"
MARKER_MAX_AGE=600

die()  { echo "unpublish-photo: error: $*" >&2; exit 1; }
info() { echo "==> $*"; }
warn() { echo "unpublish-photo: warning: $*" >&2; }

[ -n "$SLUG" ] || die 'SLUG is required'
[ -n "$ID" ]   || die 'ID is required -- the item id from web/albums/<slug>.json'
case "$SLUG" in */*|.*|"") die "invalid SLUG: $SLUG" ;; esac
case "$ID"   in */*|.*|"") die "invalid ID: $ID" ;; esac
[ -f .env ] || die ".env not found"
[ -f "web/albums/${SLUG}.json" ] || die "no such album: web/albums/${SLUG}.json"

BUCKET="$(grep -E '^B2_BUCKET=' .env | head -1 | cut -d= -f2-)"
MARKER="${MARKER_DIR}/${SLUG}.${ID}.dryrun"
mkdir -p "$MARKER_DIR"

info "item ${ID} in ${SLUG}"
REPORT="$(docker compose --profile tools run --rm -T tools -lc \
  "python3 pipeline/remove_item.py '${SLUG}' '${ID}'" 2>&1 | tr -d '\r')" \
  || die "could not read the item:
$REPORT"
echo "$REPORT" | grep -E '^(OBJECT|ITEM|LOCAL|SOURCE|COUNT)' | sed 's/^/    /'
mapfile -t OBJECTS < <(echo "$REPORT" | sed -n 's/^OBJECT //p')
[ "${#OBJECTS[@]}" -gt 0 ] || die "the item lists no B2 objects -- nothing to delete"

if [ "$DRY" = "1" ]; then
  touch "$MARKER"
  echo
  info "would delete ${#OBJECTS[@]} B2 object(s) under events/${SLUG}/:"
  for o in "${OBJECTS[@]}"; do echo "      $o"; done
  info "DRY RUN -- nothing was deleted"
  info "to proceed within $((MARKER_MAX_AGE / 60)) minutes:"
  info "    make unpublish-photo SLUG=${SLUG} ID=${ID}"
  exit 0
fi

[ -f "$MARKER" ] || die "no dry run recorded for ${SLUG}/${ID}.
  Run: make unpublish-photo SLUG=${SLUG} ID=${ID} DRY=1"
AGE=$(( $(date +%s) - $(stat -c %Y "$MARKER") ))
[ "$AGE" -le "$MARKER_MAX_AGE" ] || die "that dry run was ${AGE}s ago (limit ${MARKER_MAX_AGE}s); re-run it"

DIRTY="$(git status --porcelain -- . ':(exclude)web/albums' 2>/dev/null || true)"
[ -z "$DIRTY" ] || die "uncommitted changes outside web/albums/; commit or stash first"
[ -t 0 ] || die "refusing to run non-interactively; this deletes ${#OBJECTS[@]} B2 object(s)"

echo
echo "  This permanently deletes ${#OBJECTS[@]} B2 object(s), removes the item from"
echo "  the album and deletes the local original, then commits, pushes and purges."
echo
read -r -p "  Type the slug (${SLUG}) to confirm: " CONFIRM
[ "$CONFIRM" = "$SLUG" ] || die "confirmation did not match; nothing was deleted"
echo

for o in "${OBJECTS[@]}"; do
  info "deleting b2:${BUCKET}/events/${SLUG}/${o}"
  docker compose --profile tools run --rm -T tools -lc \
    "rclone deletefile \"b2:\$B2_BUCKET/events/${SLUG}/${o}\"" >/dev/null 2>&1 \
    || warn "could not delete ${o} (already gone?)"
done

info "removing the item from the manifest, build cache and sources"
docker compose --profile tools run --rm -T tools -lc \
  "python3 pipeline/remove_item.py '${SLUG}' '${ID}' --apply" 2>&1 \
  | grep -E '^APPLY' | sed 's/^/    /'

info "rebuilding the album index"
docker compose --profile tools run --rm -T tools -lc 'python3 pipeline/update_index.py'

info "mirroring album JSON to b2:${BUCKET}/_site/albums/"
docker compose --profile tools run --rm -T tools -lc \
  'rclone copy web/albums "b2:$B2_BUCKET/_site/albums/" --transfers 4 --stats-one-line --stats-log-level NOTICE'

git add -A -- web/albums
if git diff --cached --quiet -- web/albums; then
  warn "web/albums/ unchanged; nothing to commit"
else
  git commit -q -m "unpublish: ${SLUG} item ${ID}" -- web/albums
  info "committed: $(git log -1 --oneline)"
  git remote get-url origin >/dev/null 2>&1 && { git push origin main && info "pushed" || warn "push failed"; }
fi

for o in "${OBJECTS[@]}"; do
  PREFIX="events/${SLUG}/${o}" ./pipeline/cache_purge.sh
done

rm -f "$MARKER"
echo
info "unpublished item ${ID} from ${SLUG}"
info "note: browsers that already loaded it may keep it for up to a year."
