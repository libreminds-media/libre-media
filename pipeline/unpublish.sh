#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Take a whole album down: B2, the site, the sources, git, and the cache.
#
#   make unpublish SLUG=2024-my-event DRY=1     REQUIRED FIRST -- inventory only
#   make unpublish SLUG=2024-my-event           the real thing
#
# This is the one destructive path in the project, so it is deliberately
# awkward:
#
#   * DRY=1 must have been run for THIS slug within the last 10 minutes.
#   * The object count is printed before anything is deleted.
#   * You must type the slug to confirm, at a terminal.
#   * Objects are deleted by EXPLICIT LISTING -- the list is captured first and
#     handed to rclone as --files-from. `rclone purge` and `rclone sync` are
#     never used anywhere in this project; a prefix typo with purge would take
#     out a neighbouring album with no listing to audit afterwards.
#
# Order matters. The cache is purged LAST, because purging before the B2 delete
# would just re-fetch and re-cache the objects you are trying to remove.

set -euo pipefail
cd "$(dirname "$0")/.."

SLUG="${SLUG:-}"
DRY="${DRY:-0}"
MARKER_DIR=".unpublish"
MARKER_MAX_AGE=600          # seconds

die()  { echo "unpublish: error: $*" >&2; exit 1; }
info() { echo "==> $*"; }
warn() { echo "unpublish: warning: $*" >&2; }

[ -n "$SLUG" ] || die 'SLUG is required, e.g. make unpublish SLUG=2024-my-event DRY=1'
case "$SLUG" in */*|.*|"") die "invalid SLUG: $SLUG" ;; esac
[ -f .env ] || die ".env not found"

BUCKET="$(grep -E '^B2_BUCKET=' .env | head -1 | cut -d= -f2-)"
TTY_FLAG=(); [ -t 1 ] || TTY_FLAG=(-T)
tools() { docker compose --profile tools run --rm "${TTY_FLAG[@]}" -e SLUG="$SLUG" tools -lc "$1"; }

# --- inventory (both modes) -------------------------------------------------
info "inventory for ${SLUG}"
LIST=".unpublish/${SLUG}.objects"
mkdir -p "$MARKER_DIR"
tools 'rclone lsf -R --files-only "b2:$B2_BUCKET/events/'"$SLUG"'/" 2>/dev/null' \
  | tr -d '\r' | grep -v '^$' > "$LIST" || true
N_MEDIA=$(grep -c . "$LIST" || echo 0)

SITE_JSON="web/albums/${SLUG}.json"
N_LOCAL_SRC=$(find "inbox/${SLUG}" -type f 2>/dev/null | wc -l)
LOCAL_BYTES=$(du -sh "inbox/${SLUG}" 2>/dev/null | cut -f1 || echo 0)

echo "    B2 events/${SLUG}/            ${N_MEDIA} object(s)"
N_SITE_JSON=$(tools 'rclone lsf "b2:$B2_BUCKET/_site/albums/'"$SLUG"'.json" 2>/dev/null' | tr -d '\r' | grep -c . || true)
N_SITE_YAML=$(tools 'rclone lsf -R --files-only "b2:$B2_BUCKET/_site/inbox/'"$SLUG"'/" 2>/dev/null' | tr -d '\r' | grep -c . || true)
echo "    B2 _site/albums/${SLUG}.json  ${N_SITE_JSON:-0} object(s)"
echo "    B2 _site/inbox/${SLUG}/       ${N_SITE_YAML:-0} object(s)"
echo "    local ${SITE_JSON}            $([ -f "$SITE_JSON" ] && echo present || echo absent)"
echo "    local inbox/${SLUG}/          ${N_LOCAL_SRC} file(s), ${LOCAL_BYTES}"

# --- dry run ends here, leaving the marker ---------------------------------
if [ "$DRY" = "1" ]; then
  touch "${MARKER_DIR}/${SLUG}.dryrun"
  echo
  info "DRY RUN -- nothing was deleted"
  info "object listing written to ${LIST}"
  info "to proceed within the next $((MARKER_MAX_AGE / 60)) minutes:"
  info "    make unpublish SLUG=${SLUG}"
  exit 0
fi

# --- gates ------------------------------------------------------------------
MARKER="${MARKER_DIR}/${SLUG}.dryrun"
[ -f "$MARKER" ] || die "no dry run recorded for ${SLUG}.
  Run this first, read what it lists, then re-run without DRY=1:
      make unpublish SLUG=${SLUG} DRY=1"
AGE=$(( $(date +%s) - $(stat -c %Y "$MARKER") ))
[ "$AGE" -le "$MARKER_MAX_AGE" ] || die "the dry run for ${SLUG} was ${AGE}s ago, older than ${MARKER_MAX_AGE}s.
  Re-run it so you are deciding on a current inventory:
      make unpublish SLUG=${SLUG} DRY=1"

DIRTY="$(git status --porcelain -- . ':(exclude)web/albums' 2>/dev/null || true)"
[ -z "$DIRTY" ] || die "the working tree has uncommitted changes outside web/albums/.
  Commit or stash them first -- this command makes a commit."

[ -t 0 ] || die "refusing to run non-interactively: this deletes ${N_MEDIA} B2 objects
  and requires typed confirmation. Run it from a terminal."

echo
echo "  This permanently deletes ${N_MEDIA} media object(s) from B2, removes the"
echo "  album from the site and from ${N_LOCAL_SRC} local source file(s), commits,"
echo "  pushes, and purges the cache. B2 deletion is not reversible from here."
echo
read -r -p "  Type the slug (${SLUG}) to confirm: " CONFIRM
[ "$CONFIRM" = "$SLUG" ] || die "confirmation did not match; nothing was deleted"
echo

# --- 1. B2 media, by explicit listing --------------------------------------
if [ "$N_MEDIA" -gt 0 ]; then
  info "deleting ${N_MEDIA} object(s) from b2:${BUCKET}/events/${SLUG}/"
  tools 'rclone delete "b2:$B2_BUCKET/events/'"$SLUG"'/" --files-from "'"$LIST"'" --stats-log-level NOTICE -v 2>&1 | grep -ciE "Deleted$" || true' \
    | tr -d '\r' | sed 's/^/    deleted: /'
else
  warn "no media objects found under events/${SLUG}/ -- nothing to delete there"
fi

# --- 2. the two _site objects ----------------------------------------------
info "deleting the mirrored album JSON and backed-up album.yaml"
tools 'rclone deletefile "b2:$B2_BUCKET/_site/albums/'"$SLUG"'.json" 2>&1 || true' >/dev/null 2>&1 || true
tools 'rclone delete "b2:$B2_BUCKET/_site/inbox/'"$SLUG"'/" 2>&1 || true' >/dev/null 2>&1 || true

# --- 3/4. local state -------------------------------------------------------
info "removing ${SITE_JSON} and inbox/${SLUG}/"
rm -f "$SITE_JSON"
rm -rf "inbox/${SLUG}"

# --- 5. index ---------------------------------------------------------------
info "rebuilding the album index"
docker compose --profile tools run --rm -T tools -lc 'python3 pipeline/update_index.py'

# --- 6. mirror --------------------------------------------------------------
info "mirroring album JSON to b2:${BUCKET}/_site/albums/"
docker compose --profile tools run --rm -T tools -lc \
  'rclone copy web/albums "b2:$B2_BUCKET/_site/albums/" --transfers 4 --stats-one-line --stats-log-level NOTICE'

# --- 7. commit and push -----------------------------------------------------
info "committing"
git add -A -- web/albums
if git diff --cached --quiet -- web/albums; then
  warn "web/albums/ unchanged; nothing to commit"
else
  git commit -q -m "unpublish: ${SLUG}" -- web/albums
  info "committed: $(git log -1 --oneline)"
  if git remote get-url origin >/dev/null 2>&1; then
    git push origin main && info "pushed" || warn "push failed -- run: git push origin main"
  fi
fi

# --- 8. cache, last ---------------------------------------------------------
info "purging the local cache"
PREFIX="events/${SLUG}" ./pipeline/cache_purge.sh

rm -f "$MARKER" "$LIST"
echo
info "unpublished: ${SLUG}"
info "note: browsers that already loaded these images may keep them for up to a"
info "      year (max-age=31536000). See README \"Taking content down\"."
